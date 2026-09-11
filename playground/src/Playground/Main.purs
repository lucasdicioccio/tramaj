-- | A standalone browser playground for the tramaj language: a set of
-- | named tabs, each a freeform textarea holding one program, plus a
-- | shared JSON context. The active tab is parsed/evaluated live and shown
-- | three ways — the result as JSON, the same result folded to real
-- | Halogen HTML, and a log of every `action(...)` click that HTML
-- | dispatches. Every tab (including the active one) is also exposed to
-- | `import` as a library, keyed by its tab name — see
-- | `buildLibraryTable`.
-- |
-- | v2 removed this playground's mode switch, since a program's kind
-- | (document vs. value) is decided by its own root. v3 brings a mode
-- | switch back for a different axis — concrete vs. symbolic
-- | (v3-symbols §5) — which is a genuine host choice, not something the
-- | template's own text decides: a "Symbolic mode" checkbox next to the
-- | JSON context. Symbolic mode adds the envelope's `"symbols"`/
-- | `"constraints"` tables below; the document/value panels are otherwise
-- | unchanged, since `Tramaj.Halogen.renderScalar` already renders a
-- | symbol placeholder wherever a concrete scalar used to be.
-- |
-- | It exists to exercise the whole pipeline end to end in one place:
-- | `Tramaj.Parser` -> `Tramaj.Eval` -> `Tramaj.Halogen`'s
-- | `validateAttrNames`/`foldToHalogen`. Everything runs in the browser;
-- | there is no server side.
-- |
-- | The dispatcher below is also the worked example of what an
-- | *interactive* host looks like. A read-only host passes
-- | `const Nothing` to `foldToHalogen` and no click does anything; this
-- | one turns every `action(...)` into a real Halogen action.
module Playground.Main (main) where

import Prelude

import Data.Argonaut.Core (Json, stringify, stringifyWithIndent, toArray, toObject, toString)
import Data.Argonaut.Parser (jsonParser)
import Data.Array (null, reverse)
import Data.Array as Array
import Data.Either (Either(..), either)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (joinWith)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff)
import Foreign.Object as Object
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)
import Tramaj.Analysis.Card (programCard)
import Tramaj.Ast (Program)
import Tramaj.Eval (LibraryTable, Mode(..), Output(..), evalProgram, runProgram)
import Tramaj.Halogen (foldToHalogen, renderCard, renderConstraintTable, renderSymbolTable, renderTypeConstraintTable, renderTypesTable, validateAttrNames)
import Tramaj.Node (Node, nodeFromJson, nodeToJson)
import Tramaj.Parser (parseProgram)

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  runUI component unit body

-- | One editor pane: a name (the key other tabs `import` it by) and its
-- | source text. Independent of every other tab — switching/editing one
-- | never touches another's draft.
type Tab =
  { name :: String
  , source :: String
  }

type State =
  { tabs :: Array Tab
  , activeTab :: Int
  -- ^ Index into `tabs` — which one is shown/evaluated as the root
  -- program on the right. Every tab, including this one, is still
  -- available to `import(...)` (see `buildLibraryTable`); a
  -- tab importing itself is handled by the language's own cycle guard,
  -- not excluded here.
  , jsonInput :: String
  -- ^ The shared `$ctx` for whichever tab is active — *not* passed to
  -- library tabs, which each get their own fresh `$ctx` from whatever
  -- `params` the active tab's `import(...)` call supplies.
  , actionLog :: Array { key :: String, payload :: Json }
  -- ^ Appended to by 'dispatchAction' on every `action(...)` click in the
  -- rendered output; newest last, rendered newest-first. Only a program
  -- that produced a document can dispatch anything, since only a document
  -- is folded to Halogen HTML.
  , mode :: Mode
  -- ^ Concrete (default) or symbolic (v3-symbols §5) — a host choice, not
  -- read off the template. Only affects the active tab's own evaluation;
  -- a library can never allocate regardless of mode, so imported tabs are
  -- unaffected either way.
  }

data Action
  = SetActiveTab Int
  | SetTabSource Int String
  | SetTabName Int String
  | AddTab
  | RemoveTab Int
  | SetJsonInput String
  | SetMode Mode
  | ActionFired String Json
  | ClearActionLog

component :: forall query input output. H.Component query input output Aff
component =
  H.mkComponent
    { initialState: \_ -> initialState
    , render
    , eval: H.mkEval H.defaultEval { handleAction = handleAction }
    }

initialState :: State
initialState =
  { tabs:
      [ { name: "main"
        , source:
            """@item-count=cardinality($ctx.items)
-- a parameter given as an expression, evaluated right here
@greeting=import("greeting", {"name": "World"})
-- kind: a hole read from this program's own $ctx, marked so the analyses
-- can see it; title: not listed, so each row supplies its own below
@row=import("row", {kind: ctx(row-kind)})
@namespaced=adapt-actions($row, prefix("main:"))
@header=.(
  $greeting.rendered,
  .p("there are `$item-count` `$greeting.vals.magic` item(s)")
)
.div(
  "data-count": $item-count,
  $header,
  .ul(map($ctx.items, (item) => $namespaced({"title": $item.title}).rendered))
)"""
        }
      , { name: "greeting"
        , source:
            """@magic="magic"
.p("hello, `$ctx.name`!")
"""
        }
      , { name: "row"
        , source:
            """-- a library's $ctx is the parameters it was given, however they
-- arrived: kind came from the importer's context, title from the call
.li(
  .span("`$ctx.title` (`$ctx.kind`)"),
  .button(action("on-click", "select-item", {"title": $ctx.title}), "Select")
)
"""
        }
      , { name: "value-demo"
        , source:
            """@item-count=cardinality($ctx.items)
{"count": $item-count, "titles": map($ctx.items, (item) => $item.title)}"""
        }
      , { name: "constraints-demo"
        , source:
            """-- Turn on "Symbolic mode" (top right) to see this tab's holes and
-- facts listed in the Symbols/Constraints tables below, instead of plain
-- values. In concrete mode ?("replicas") has nothing to become, so this
-- errors with SymbolsUnavailable -- that's the language saying the
-- template needs a solver (or a seeded value), not a plain render.
@replicas=?("replicas")
!constraint("gte", $replicas, 1)
!constraint("lte", $replicas, 10)
-- ?ctx.zone reads $ctx.zone like an ordinary path when it's supplied (see
-- "zone" in the shared JSON context) -- only an UNSUPPLIED demand mints a
-- symbol, and only at the root. Try deleting "zone" from the context
-- while symbolic mode is on: this becomes its own allocated symbol too.
@zone=?ctx.zone
!constraint("allowed-zone", $zone, "eu")
!constraint("allowed-zone", $zone, "us")
-- $replicas is an ordinary value being passed here, so it crosses into
-- "sized" with its identity intact -- the library's own !constraint below
-- is collected only once .rendered is actually read off $sizing.
@sizing=import("sized", {count: $replicas})
.div(
  "data-replicas": $replicas,
  .p("Deploy ", $replicas, " replicas in zone ", $zone),
  $sizing.rendered
)"""
        }
      , { name: "sized"
        , source:
            """-- A library's $ctx is the parameters it was given -- here, whatever
-- constraints-demo passed as "count", symbol or concrete. This constraint
-- is emitted (and, in symbolic mode, collected) only when a field is read
-- off this library's import -- .rendered here, .vals would do it too.
!constraint("multiple-of", $ctx.count, 5)
.p("(sized in steps of 5)")
"""
        }
      , { name: "types-demo"
        , source:
            """-- v4-types: "type X = ..." declares a nominal type; "@x : T = e" is
-- sugar for "@x=e" plus a has-type constraint, erased before evaluation
-- (specs/v4-types.md \x00A77). Switch on "Symbolic mode" to see the Types
-- and Type constraints tables below fill in -- in concrete mode a typed
-- program is byte-identical to the same program with every "type"
-- declaration and ":" annotation deleted.

-- An ordinary nominal declaration, structural in its own body. "Zone" is
-- an enum: a union whose arms carry no payload.
type Deployment = { replicas : number, zone : Zone }
type Zone = | Eu | Us

-- "message" is parameterised over a type: %ctx.payload inside it is a
-- type-level hole, read like a value parameter but marked "%" because
-- it's a type, not a value (v4-types \x00A72). Supplying it with
-- %$json.types.Value resolves that hole to json's own declared type --
-- forwarding it instead (%ctx.payload) would leave it a hole for our own
-- importer to fill.
@json=import("json", {})
@msg=import("message", {payload: %$json.types.Value})

-- A type-level fact about a type this program does not itself define --
-- the sibling of !constraint(...), but resolved statically rather than
-- evaluated (v4-types \x00A75).
!type-constraint("has-default", %$json.types.Value)

-- Annotating a binding erases to a has-type constraint plus a "types"
-- table entry for the annotation's type, closed over any arguments.
@d : Deployment           = {"replicas": 3, "zone": "eu"}
@m : $msg.types.Envelope  = {"to": "ops", "payload": true}

.div(
  .p("deployment: `$d.zone`, `$d.replicas` replicas"),
  .p("message to: `$m.to`")
)"""
        }
      , { name: "message"
        , source:
            """-- A library exporting a type parameterised over its own $ctx, the same
-- way it would be parameterised over a value (v4-types \x00A72). Its
-- importer supplies "payload" as a type argument, not a value one.
type Envelope = { to : string, payload : %ctx.payload }
!type-constraint("has-default", %ctx.payload)
.p("(message library body -- imported here for its types, not rendered)")
"""
        }
      , { name: "json"
        , source:
            """-- A trivial library whose only purpose is to export a nominal type
-- ("Value") for other tabs to reference by $lib.types.Name.
type Value = document
.p("(json library body -- imported here for its types, not rendered)")
"""
        }
      ]
  , activeTab: 0
  , jsonInput:
      -- Carries what every default tab reads, not just the active one, so
      -- selecting a library tab shows it rendering instead of a
      -- PathNotFound for the parameter its importer would have supplied.
      -- row-kind is the one the main tab actually reads, through ctx(...);
      -- zone is the one constraints-demo reads, through ?ctx.zone.
      """{"items": [{"title": "Alpha"}, {"title": "Beta"}], "name": "World", "title": "Alpha", "kind": "item", "row-kind": "item", "zone": "eu"}"""
  , actionLog: []
  , mode: Concrete
  }

handleAction :: forall output. Action -> H.HalogenM State Action () output Aff Unit
handleAction = case _ of
  SetActiveTab i -> H.modify_ _ { activeTab = i }
  SetTabSource i source -> modifyTab i _ { source = source }
  SetTabName i name -> modifyTab i _ { name = name }
  AddTab -> H.modify_ \s ->
    s
      { tabs = Array.snoc s.tabs { name: "tab-" <> show (Array.length s.tabs + 1), source: "" }
      , activeTab = Array.length s.tabs
      }
  RemoveTab i -> H.modify_ \s ->
    if Array.length s.tabs <= 1 then s
    else
      s
        { tabs = fromMaybe s.tabs (Array.deleteAt i s.tabs)
        , activeTab = clampActive (Array.length s.tabs - 1) (if i <= s.activeTab then s.activeTab - 1 else s.activeTab)
        }
  SetJsonInput json -> H.modify_ _ { jsonInput = json }
  SetMode mode -> H.modify_ _ { mode = mode }
  ActionFired key payload -> H.modify_ \s -> s { actionLog = s.actionLog <> [ { key, payload } ] }
  ClearActionLog -> H.modify_ _ { actionLog = [] }
  where
  modifyTab :: Int -> (Tab -> Tab) -> H.HalogenM State Action () output Aff Unit
  modifyTab i f = H.modify_ \s -> s { tabs = fromMaybe s.tabs (Array.modifyAt i f s.tabs) }

  clampActive :: Int -> Int -> Int
  clampActive maxIdx i = max 0 (min maxIdx i)

-- | Every tab — including the active one — parsed as a library keyed by
-- | its name. A tab that fails to parse is simply left out of the map (the
-- | tab bar flags it separately) rather than surfacing here — importing a
-- | dropped tab just fails as the language's own `UnknownLibrary`, no
-- | different from naming a library that never existed.
buildLibraryTable :: Array Tab -> LibraryTable
buildLibraryTable tabs = Map.fromFoldable (Array.mapMaybe entry tabs)
  where
  entry :: Tab -> Maybe (Tuple String Program)
  entry tab = either (const Nothing) (\p -> Just (Tuple tab.name p)) (tabProgram tab)

tabProgram :: Tab -> Either String Program
tabProgram tab = either (\e -> Left (show e)) Right (parseProgram tab.source)

activeTabOf :: State -> Tab
activeTabOf state = fromMaybe { name: "", source: "" } (Array.index state.tabs state.activeTab)

render :: State -> H.ComponentHTML Action () Aff
render state =
  HH.div [ HP.class_ (HH.ClassName "wrap") ]
    [ HH.h1_ [ HH.text "tramaj playground" ]
    , HH.p [ HP.class_ (HH.ClassName "hint") ]
        [ HH.text "Renders a tramaj template against a JSON context, entirely in the browser. See specs/reference.md for the full language; the reference below is the short version." ]
    , HH.details [ HP.class_ (HH.ClassName "card") ]
        [ HH.summary_ [ HH.text "Language reference" ]
        , HH.pre [ HP.class_ (HH.ClassName "ref" ) ] [ HH.text referenceText ]
        ]
    , HH.div [ HP.class_ (HH.ClassName "cols") ]
        [ HH.div [ HP.class_ (HH.ClassName "card") ]
            [ HH.div [ HP.class_ (HH.ClassName "row") ]
                [ HH.h2_ [ HH.text "Template" ] ]
            , renderTabBar state
            , HH.p [ HP.class_ (HH.ClassName "hint") ]
                [ HH.text "Every tab is available to import(...) by its name, including the active one — switch tabs above to edit a library." ]
            , kindHint state
            , HH.textarea
                [ HP.class_ (HH.ClassName "input")
                , HP.rows 16
                , HP.spellcheck false
                , HP.value (activeTabOf state).source
                , HE.onValueInput (SetTabSource state.activeTab)
                ]
            ]
        , HH.div [ HP.class_ (HH.ClassName "card") ]
            [ HH.div [ HP.class_ (HH.ClassName "row") ]
                [ HH.h2_ [ HH.text "JSON context" ]
                , HH.label_
                    [ HH.input
                        [ HP.type_ HP.InputCheckbox
                        , HP.checked (state.mode == Symbolic)
                        , HE.onChecked \checked -> SetMode (if checked then Symbolic else Concrete)
                        ]
                    , HH.text " Symbolic mode"
                    ]
                ]
            , HH.p [ HP.class_ (HH.ClassName "hint") ]
                [ HH.text "Symbolic mode wraps the result in the v3-symbols envelope and lists its symbols/constraints below. To try a symbol concretely, edit this context by hand and switch back — there is no in-place hole filling here." ]
            , HH.textarea
                [ HP.class_ (HH.ClassName "input")
                , HP.rows 16
                , HP.spellcheck false
                , HP.value state.jsonInput
                , HE.onValueInput SetJsonInput
                ]
            ]
        ]
    , HH.div [ HP.class_ (HH.ClassName "card") ]
        [ HH.h2_ [ HH.text "Program card" ]
        , HH.p [ HP.class_ (HH.ClassName "hint") ]
            [ HH.text "What the active tab needs, reaches, and can emit — computed statically from its AST and the other tabs offered as imports, without evaluating it or the JSON context on the left. The same five fields "
            , HH.code_ [ HH.text "tramaj-cli analyze card" ]
            , HH.text " prints as JSON."
            ]
        , renderProgramCard state
        ]
    , HH.div [ HP.class_ (HH.ClassName "cols") ]
        [ HH.div [ HP.class_ (HH.ClassName "card") ]
            [ HH.h2_ [ HH.text "AST" ]
            , HH.p [ HP.class_ (HH.ClassName "hint") ]
                [ HH.text "The result in the normative specs/node-json.md representation — the same value foldToHalogen is folding on the right, shown before that fold happens. A program that produced an ordinary value is shown as that value." ]
            , renderAst state
            ]
        , HH.div [ HP.class_ (HH.ClassName "card") ]
            [ HH.h2_ [ HH.text "Rendered" ]
            , HH.div [ HP.class_ (HH.ClassName "rendered") ] (renderOutput state)
            ]
        ]
    , HH.div [ HP.class_ (HH.ClassName "cols") ]
        [ HH.div [ HP.class_ (HH.ClassName "card") ]
            [ HH.h2_ [ HH.text "Symbols" ]
            , HH.p [ HP.class_ (HH.ClassName "hint") ]
                [ HH.text "The symbol table from the v3-symbols §5.2 envelope — always empty in concrete mode." ]
            , renderSymbols state
            ]
        , HH.div [ HP.class_ (HH.ClassName "card") ]
            [ HH.h2_ [ HH.text "Constraints" ]
            , HH.p [ HP.class_ (HH.ClassName "hint") ]
                [ HH.text "Every constraint the program emitted, deduplicated — always empty in concrete mode." ]
            , renderConstraints state
            ]
        ]
    , HH.div [ HP.class_ (HH.ClassName "cols") ]
        [ HH.div [ HP.class_ (HH.ClassName "card") ]
            [ HH.h2_ [ HH.text "Types" ]
            , HH.p [ HP.class_ (HH.ClassName "hint") ]
                [ HH.text "The v4-types \x00A7 8 type table — every type this program's root closes over, cut at declaration boundaries. Always empty in concrete mode." ]
            , renderTypes state
            ]
        , HH.div [ HP.class_ (HH.ClassName "card") ]
            [ HH.h2_ [ HH.text "Type constraints" ]
            , HH.p [ HP.class_ (HH.ClassName "hint") ]
                [ HH.text "Every !type-constraint(...) the program emitted, resolved and deduplicated — always empty in concrete mode." ]
            , renderTypeConstraints state
            ]
        ]
    , HH.div [ HP.class_ (HH.ClassName "card") ]
        [ HH.div [ HP.class_ (HH.ClassName "row") ]
            [ HH.h2_ [ HH.text "Action log" ]
            , HH.button
                [ HP.class_ (HH.ClassName "btn")
                , HP.disabled (null state.actionLog)
                , HE.onClick \_ -> ClearActionLog
                ]
                [ HH.text "Clear" ]
            ]
        , HH.p [ HP.class_ (HH.ClassName "hint") ]
            [ HH.text "Every action(...) click in the rendered output is dispatched here — real Halogen actions, appended by the demo handler passed to foldToHalogen." ]
        , renderActionLog state
        ]
    ]

-- | One chip per tab (click activates it; an inline name field renames
-- | it; a "×" removes it, disabled when it's the only tab left), plus a
-- | trailing "+ tab" button. A tab whose source doesn't parse
-- | gets `tab-error` so a broken library is visible without switching to
-- | it first.
renderTabBar :: State -> H.ComponentHTML Action () Aff
renderTabBar state =
  HH.div [ HP.class_ (HH.ClassName "tabs") ]
    ( Array.mapWithIndex renderTab state.tabs
        <> [ HH.button
              [ HP.class_ (HH.ClassName "btn")
              , HE.onClick \_ -> AddTab
              ]
              [ HH.text "+ tab" ]
          ]
    )
  where
  renderTab :: Int -> Tab -> H.ComponentHTML Action () Aff
  renderTab i tab =
    HH.div
      [ HP.class_
          ( HH.ClassName
              ( "tab"
                  <> (if i == state.activeTab then " tab-active" else "")
                  <> (if either (const true) (const false) (tabProgram tab) then " tab-error" else "")
              )
          )
      ]
      [ HH.input
          [ HP.class_ (HH.ClassName "tab-name")
          , HP.value tab.name
          , HE.onClick \_ -> SetActiveTab i
          , HE.onValueInput (SetTabName i)
          ]
      , HH.button
          [ HP.class_ (HH.ClassName "tab-close")
          , HP.disabled (Array.length state.tabs <= 1)
          , HE.onClick \_ -> RemoveTab i
          ]
          [ HH.text "\x00D7" ]
      ]

-- | Reports which kind of program the active tab currently *is*, rather
-- | than offering a switch. v1 made this a per-tab setting the reader had
-- | to keep in sync with what they had written; v2 reads it off the root,
-- | so there is nothing to set and nothing to get wrong.
kindHint :: State -> H.ComponentHTML Action () Aff
kindHint state =
  HH.p [ HP.class_ (HH.ClassName "hint") ]
    [ HH.text case computeResult state of
        Right { output: ResultNode _ } ->
          "This program's root is a document — folded to real Halogen HTML on the right."
        Right { output: ResultValue _ } ->
          "This program's root is an ordinary expression — it evaluates to a JSON value, with no document tree involved."
        Left _ ->
          "A program's kind follows from its root: write .tag(...) or .(...) for a document, anything else for a plain value."
    ]

-- | The two possible outcomes — `ResultNode` folds to real Halogen HTML
-- | (`renderOutput`) and to the normative node JSON (`renderAst`);
-- | `ResultValue` has no document tree to fold, so it is shown the same
-- | prettified way in both panels.
data EvalResult
  = ResultNode Node
  | ResultValue Json

-- | `computeResult`'s full outcome: the root result plus whatever the
-- | envelope carried alongside it — `[]` for both in concrete mode, since
-- | that mode discards emissions entirely (v3-symbols §5.1).
type EnvelopeResult =
  { output :: EvalResult
  , symbols :: Array Json
  , constraints :: Array Json
  , types :: Array Json
  , typeConstraints :: Array Json
  }

-- | Shared by 'renderOutput', 'renderAst', 'renderSymbols' and
-- | 'renderConstraints' so every panel reflects one parse/eval result
-- | rather than each re-running the pipeline and risking disagreement
-- | mid-edit.
-- |
-- | Simple implementation, deliberately: this re-decodes the envelope's
-- | own JSON wire format (`Data.Argonaut` lookups + `nodeFromJson`) rather
-- | than consuming typed data, because `Tramaj.Eval` does not currently
-- | export its `Emissions`/`SymbolEntry` types. Given more time, the
-- | better shape is for `Tramaj.Eval` to export those (or a function
-- | returning `{ output :: Output, symbols :: Array SymbolEntry,
-- | constraints :: Array Value }` directly), so a host consumes typed
-- | data instead of re-parsing the JSON it just produced — this module
-- | would then only need to convert `SymbolEntry`/`Value` to `Json` for
-- | display, not guess at the envelope's shape.
computeResult :: State -> Either String EnvelopeResult
computeResult state = case jsonParser state.jsonInput of
  Left err -> Left ("Invalid JSON: " <> err)
  Right ctx ->
    let
      activeTab = activeTabOf state
      libs = buildLibraryTable state.tabs
    in
      case parseProgram activeTab.source of
        Left err -> Left ("Template parse error: " <> show err)
        Right program -> case state.mode of
          Concrete -> case evalProgram Concrete libs ctx program of
            Left err -> Left ("Template eval error: " <> show err)
            Right (ONode node) -> Right { output: ResultNode node, symbols: [], constraints: [], types: [], typeConstraints: [] }
            Right (OValue value) -> Right { output: ResultValue value, symbols: [], constraints: [], types: [], typeConstraints: [] }
          Symbolic -> case runProgram Symbolic libs ctx program of
            Left err -> Left ("Template eval error: " <> show err)
            Right envelope -> decodeEnvelope envelope

  where
  decodeEnvelope :: Json -> Either String EnvelopeResult
  decodeEnvelope envelope = case toObject envelope of
    Nothing -> Left "Malformed symbolic envelope: not an object"
    Just obj ->
      let
        symbols = fromMaybe [] (Object.lookup "symbols" obj >>= toArray)
        constraints = fromMaybe [] (Object.lookup "constraints" obj >>= toArray)
        types = fromMaybe [] (Object.lookup "types" obj >>= toArray)
        typeConstraints = fromMaybe [] (Object.lookup "type-constraints" obj >>= toArray)
      in
        case Object.lookup "kind" obj >>= toString, Object.lookup "root" obj of
          Just "document", Just root -> case nodeFromJson root of
            Left err -> Left ("Malformed symbolic envelope root: " <> err)
            Right node -> Right { output: ResultNode node, symbols, constraints, types, typeConstraints }
          Just "expression", Just root -> Right { output: ResultValue root, symbols, constraints, types, typeConstraints }
          _, _ -> Left "Malformed symbolic envelope: missing \"kind\"/\"root\""

-- | Returns an `Array` because `foldToHalogen` does: a document rooted at
-- | a fragment is several siblings with no wrapper, and inventing one here
-- | would contradict the point of fragments.
renderOutput :: State -> Array (H.ComponentHTML Action () Aff)
renderOutput state = case computeResult state of
  Left err -> [ renderError err ]
  Right { output: ResultNode node } -> case validateAttrNames node of
    [] -> foldToHalogen dispatchAction node
    invalid ->
      [ renderError
          ( "Invalid attribute name(s): "
              <> joinWith ", " invalid
              <> " — attribute keys may only contain letters, digits, '-' and '_'"
          )
      ]
  -- A plain value has no document tree to fold: its "rendered" form is
  -- just the value, pretty-printed and wrapped in a `<code>` tag (inside a
  -- `<pre>` so the indentation survives HTML's whitespace collapsing).
  Right { output: ResultValue value } ->
    [ HH.pre [ HP.class_ (HH.ClassName "ref") ]
        [ HH.code_ [ HH.text (stringifyWithIndent 2 value) ] ]
    ]

-- | The active tab's static card — parsed and analyzed on its own, deep
-- | over every other tab as its offered `LibraryTable`, entirely
-- | independent of `computeResult`: it needs no JSON context and does not
-- | care whether evaluation would succeed, since every field it shows is
-- | answered by walking the AST.
renderProgramCard :: State -> H.ComponentHTML Action () Aff
renderProgramCard state = case parseProgram (activeTabOf state).source of
  Left err -> renderError ("Template parse error: " <> show err)
  Right program -> renderCard (programCard (buildLibraryTable state.tabs) program)

renderAst :: State -> H.ComponentHTML Action () Aff
renderAst state = case computeResult state of
  Left err -> renderError err
  Right { output: ResultNode node } -> HH.pre [ HP.class_ (HH.ClassName "ref") ] [ HH.text (stringifyWithIndent 2 (nodeToJson node)) ]
  Right { output: ResultValue value } -> HH.pre [ HP.class_ (HH.ClassName "ref") ] [ HH.text (stringifyWithIndent 2 value) ]

renderSymbols :: State -> H.ComponentHTML Action () Aff
renderSymbols state = case computeResult state of
  Left _ -> HH.p [ HP.class_ (HH.ClassName "empty") ] [ HH.text "N/A — see the error above." ]
  Right { symbols } -> renderSymbolTable symbols

renderConstraints :: State -> H.ComponentHTML Action () Aff
renderConstraints state = case computeResult state of
  Left _ -> HH.p [ HP.class_ (HH.ClassName "empty") ] [ HH.text "N/A — see the error above." ]
  Right { constraints } -> renderConstraintTable constraints

renderTypes :: State -> H.ComponentHTML Action () Aff
renderTypes state = case computeResult state of
  Left _ -> HH.p [ HP.class_ (HH.ClassName "empty") ] [ HH.text "N/A — see the error above." ]
  Right { types } -> renderTypesTable types

renderTypeConstraints :: State -> H.ComponentHTML Action () Aff
renderTypeConstraints state = case computeResult state of
  Left _ -> HH.p [ HP.class_ (HH.ClassName "empty") ] [ HH.text "N/A — see the error above." ]
  Right { typeConstraints } -> renderTypeConstraintTable typeConstraints

-- | The demo dispatcher: every `action(...)` click becomes a real
-- | Halogen action appended to the log. A read-only host would pass
-- | `const Nothing` here instead — see 'Tramaj.Halogen'.
dispatchAction :: String -> String -> Json -> Maybe Action
dispatchAction _event key payload = Just (ActionFired key payload)

renderError :: String -> H.ComponentHTML Action () Aff
renderError msg = HH.p [ HP.class_ (HH.ClassName "err") ] [ HH.text msg ]

renderActionLog :: State -> H.ComponentHTML Action () Aff
renderActionLog state
  | null state.actionLog =
      HH.p [ HP.class_ (HH.ClassName "empty") ] [ HH.text "No actions fired yet — click a button in the rendered output." ]
  | otherwise =
      HH.ul [ HP.class_ (HH.ClassName "log") ] (map renderLogEntry (reverse state.actionLog))

renderLogEntry :: { key :: String, payload :: Json } -> H.ComponentHTML Action () Aff
renderLogEntry entry =
  HH.li_
    [ HH.span [ HP.class_ (HH.ClassName "log-key") ] [ HH.text entry.key ]
    , HH.span [ HP.class_ (HH.ClassName "log-payload") ] [ HH.text (stringify entry.payload) ]
    ]

-- | Static short-form language reference, mirroring
-- | `specs/reference.md`'s structure closely
-- | enough to be useful without opening that file.
-- | The in-app language reference. Kept in step with `specs/reference.md`,
-- | condensed to what fits in a panel — same facts, same order, including
-- | the ones a reader is most likely to trip over (no arithmetic, no
-- | negative literals).
referenceText :: String
referenceText =
  """THREE LEADER CHARACTERS
  .    builds a document: .tag(...) an element, .(...) a fragment
  $    reads a bound name, or a path into one
  @    defines a binding (one per line, above the root): @name=expr

DOCUMENTS ARE VALUES
  One expression language, and a document is an ordinary value: bind it,
  pass it to a lambda, return one from a lambda, put it in an array. A
  program's kind follows from its root — write a document and you get a
  document, write anything else and you get a plain JSON value.

    @kids=.(.p("one"), .p("two"))
    @panel=(title, children) => .section(.h2($title), $children)
    .main($panel("Deployment", $kids))

PRIMITIVES
  $name              a bound name, or a $ctx-rooted field path
  $name.field.field2 dotted path — no spaces around the "."
  "literal text"     a string. Escapes: \n \t \r \\ \" \` \0 \u{1F600}
                     Interpolate any expr with backticks:
                     "count: `$n`", "n: `$cardinality($xs)`"
  123 / 123.45       a number. NO leading "-" and NO exponent: -1 and 1e5
                     are parse errors, and with no arithmetic in the
                     language such a value has to come from $ctx
  true / false       a boolean
  null               the null literal
  fn(arg, ...)       a call — $fn(...) means the same thing. The callee may
  $fn(arg, ...)      be a path: $lib.vals.fn(1)
  f(x).rendered      field access on a call's result. NOTE the reverse is
                     not available: f(x)(y) is a parse error, so bind an
                     import or adapt-actions result before calling it
  [expr, ...]        an array
  {"key": expr, ...} an object. Keys may be bare (count: $n), and a bare
  {foo, bar}         key alone is shorthand for {"foo": $foo, "bar": $bar}
  a <> b             concat — the only infix operator, left-associative,
                     lowest precedence
  (p1, ...) => expr  a lambda
  (expr)             grouping
  -- comment         a comment, from "--" to the end of the line. Single-line
                     only; legal wherever a space is; "--" inside a string
                     literal is ordinary text
  Names start with a letter and may contain digits, "_" and internal "-".
  INTERNAL is enforced: a name never ends in "-", so $x-- note reads as $x
  followed by a comment.
  Whitespace is insignificant except as a separator.

LAMBDAS — bindable, not just inline
  Write one inline as an argument (map(arr, (x) => ...)) or bind it —
  @is-big=(x) => gt($x, 10) — and call it later: $is-big(5). A bound
  lambda can be passed by reference: map($ctx.items, $is-big). So can a
  builtin: map($ctx.flags, $not). Closures capture the environment where
  they were written, so a body sees outer bindings, and a closure can be
  passed on: @apply=(f, x) => $f($x).
  Two hard limits: NO RECURSION (a binding's value is not in scope while
  that value is being evaluated, so a lambda cannot call itself by name),
  and a closure used where a plain value is expected is an error — call it
  first.

BINDINGS
  @name=expr, one per line, above the root. Evaluated in order; each may
  reference $ctx and any earlier binding, never a later one. They are
  ordinary nested lexical bindings, and an imported program exposes its own
  as .vals.

ELEMENTS
  .tag(arg, arg, ...)
  Everything in attribute position comes before any child; a child first is
  a parse error. Each arg is one of:
    key: value          an attribute — key bare or quoted, value any expr.
    "key": value        The value stays a value: count: 3 is the number 3
    action("event", "key", payloadExpr)
                        an action — see ACTIONS. Any number per element
    value(expr)         the element's value slot, for targets that attach a
                        body value to a tagged node. Defaults to null; at
                        most one per element
    anything else       a child: "text", $path, 3, a nested .tag(...), a
                        fragment, a map(...), a branch(...), a call
  CHILD RULES. A scalar child keeps its type — .td($ctx.count) yields the
  number 3, and the host decides how to render it. An ARRAY child
  contributes each element as a sibling, which is how map(...) repeats
  children — so an array wanted as data belongs in an attribute or the
  value slot, not in child position.

FRAGMENTS
  .(child, child, ...)
  Sibling nodes with no wrapper element. A real node in the output — bind
  one, pass it as a component's children, return one from a lambda.

BRANCH
  branch(fallback, pred1, val1, pred2, val2, ...)
  "if pred1 then val1, else if pred2 then val2, ..., else fallback."
  ONLY the selected arm is ever evaluated, in every position — so an
  unreached arm's errors never surface. One form, whether it picks a
  document or a plain value. The condition must be a boolean.

IMPORTS
  import("name", {param: expr, other: ctx(path)})
  The name is a literal, never computed. A parameter arrives in one of
  three ways:
    param: expr        any expression, evaluated here
    other: ctx(path)   this program's $ctx.path, read here
    (not listed)       supplied later, by calling the import
  ctx(path) means exactly what $ctx.path means and is interchangeable with
  it at runtime. It exists so the hole sits in a STATIC position, where the
  analyses can enumerate it without evaluating anything — writing ctx(...)
  says "this is a hole, count it", at the cost of not being able to compute
  the value.
  An import RUNS when you read a field off it — .rendered (whatever its
  root evaluated to) or .vals (its top-level bindings) — never where it is
  written. Until then it just accumulates parameters, right-biased:
    @p=import("panel", {})
    @half=$p({"name": "web"})
    $half({"replicas": 2}).rendered
  which is what lets one import serve a whole map, each iteration adding
  its own parameter. A library reads its parameters as its own $ctx, so a
  parameter nobody supplied is that library's own PathNotFound, reported as
  InLibrary "panel" (PathNotFound ["ctx", "replicas"]).

ACTIONS
  action("event-type", "key", payloadExpr)
  The event type and key are literals; only the payload is computed. The
  language assigns meaning to neither — the event vocabulary is the host's.
  The key is a literal so the set of actions a program can emit is knowable
  without running it. This playground logs every action; a read-only host
  would ignore them all.

  adapt-actions(node, prefix("ns:"))
  adapt-actions(node, identity)
  adapt-actions(node, prefix("ns:"), fn)
  Prefixes every action key in a subtree, reaching through imported
  programs and supplied fragments. Adaptations compose: "a:" then "b:"
  gives b:a:key. The operation is only ever identity-or-prefix, never an
  arbitrary rewriting function. The optional fn sees each already-prefixed
  action and may change its eventType and payload only; a key it returns is
  ignored. Applied to an import that has not run, it is queued and runs
  on that import's result.

SYMBOLS AND CONSTRAINTS (v3, symbolic mode only — see the checkbox above
the JSON context)
  ?(key)             allocates a symbol: opaque data standing in for a
                     value neither you nor the host has yet. key is any
                     expression and must itself be concrete; it is what
                     distinguishes this symbol from its neighbors —
                     ?("replicas") for one, (s) => ?($s.name) for one per
                     service in a map.
  ?ctx.path          reads $ctx.path exactly like an ordinary read WHEN
                     SUPPLIED. Only an UNSUPPLIED demand mints a symbol,
                     and only at the program's root — the same read inside
                     an imported tab, left unsupplied, is that tab's own
                     PathNotFound, same as $ctx.path would be.
  A symbol may be bound, passed around, put in an array/object, an
  attribute, a payload, a value slot or a text child, and projected with
  $s.field (which never fails — the field is a question for whoever owns
  the symbol's meaning, not the language). It may NOT be used anywhere the
  language would need to know something about it: a branch condition,
  map/filter/scan/fold's collection, string interpolation, eq/lt/lte/
  gt/gte, cardinality/has/lookup, <>, or another allocation's key. Each of
  those is NotConcrete instead of an answer.

  constraint(name, arg, ...)
                     builds a fact: a static name plus any number of
                     ordinary expressions (unbounded arity, so a global
                     constraint over a whole array is exactly as
                     expressible as a binary one). The language assigns no
                     meaning to name — that's host vocabulary, exactly
                     like an action's event type.
  !expr              emits: collects constraint(...) values out of expr
                     into the program's constraint list. An array
                     collects each element recursively, so !map(...) reads
                     naturally. A statement leader, like @ — legal only
                     above the root, never inside an expression.
  Two constraints with the same name and equal arguments are one fact,
  kept at its first position. In concrete mode, ! still evaluates its
  expression but discards the result — a constraint-annotated library
  works as an ordinary one there. In symbolic mode this playground lists
  every symbol allocated and every constraint emitted, deduplicated, in
  the tables below the rendered output; a symbol appearing in the
  rendered tree or an argument shows as its id with any projected path,
  e.g. #0:"replicas".zone.

  A library's own ! statements are collected exactly like the root's, but
  only once a field (.rendered or .vals) is actually read off its import
  — see constraints-demo importing "sized" for a library emitting a fact
  about a symbol passed in from its caller, unchanged identity and all.

  Mode is a host choice (the checkbox above), never a template property:
  concrete mode has no way to represent a symbol at all, so allocating or
  minting one there is SymbolsUnavailable rather than a value.

TYPES (v4, static -- see the Types/Type constraints tables below the
rendered output, in either mode)
  type Name = TypeExpr
                     a nominal declaration, one per line, above the root
                     alongside @/! statements. Legal wherever a statement
                     is. Six TypeExpr shapes, closed:
                       string / number / bool / null / document   a primitive
                       [T]                                        an array
                       { a : T, b : U }                           a record
                       | A T | B | C U                            a union --
                                        an arm may carry a payload or not
                       Name / $lib.types.Name                     a reference
                                        to another declaration, own or a
                                        library's
                       %ctx.path                                  a type hole,
                                        filled by this program's importer
                     A declaration is nominal, not an alias: type UserId =
                     string is a new type, distinct from string and from
                     any other declaration with the same body. Two
                     declarations with the same NAME (library, name) are
                     the same type; identical bodies under different names
                     are two. A self-recursive body (type Tree = | Leaf |
                     Node { l : Tree, r : Tree }) terminates: a reference to
                     another declaration is never expanded, so recursion is
                     compared by name, never by walking the body forever.

  %ctx.path          a type hole INSIDE a declaration's own body -- the
                     type-level counterpart of a value parameter, read from
                     this library's own $ctx. An importer fills it exactly
                     like a value parameter, marked "%" for "this is a
                     type, not a value":
                       import("message", {payload: %Json})     -- supply:
                                        the hole is gone
                       import("inner", {payload: %ctx.payload})  -- forward:
                                        still a hole, now the caller's
                     A type left partial (still containing %ctx.path
                     somewhere) is perfectly legal in a library -- that is
                     what a parameterised library exports -- and a
                     PartialType error at the PROGRAM ROOT: unlike a value
                     symbol, a type may never reach the output with a hole
                     still in it.

  $lib.types.Name    a library's declared type, read the same way $lib.vals
                     reads a binding -- except this is resolved statically,
                     at analysis time, not at evaluation time. lib must be
                     bound directly to an import(...) in an enclosing
                     binding; one reached through a lambda, an array, or a
                     later saturating call cannot be resolved.

  @x : T = e         an annotated binding -- sugar for @x=e plus
                     !constraint("has-type", $x, {"$type": "<T's id>"}).
                     The type is erased before evaluation into that inert
                     tagged object, so a typed program's concrete-mode
                     output is byte-identical to the same program with
                     every ": T" deleted, and $x is an ordinary value
                     afterwards -- never computed on, branched on, or built
                     at runtime.

  !type-constraint(name, arg, ...)
                     the type realm's sibling of !constraint(...) (see
                     SYMBOLS AND CONSTRAINTS above): a static name plus any
                     number of arguments, each either a %-marked type
                     expression or a plain scalar. Resolved by the
                     analyser, never evaluated -- it lives in the
                     "type-constraints" list, not "constraints", and takes
                     no value-realm hole with it.

  Two types are the same type iff their canonical id strings are equal --
  no unifier, no subsumption, just string equality. A type reference is
  ALWAYS rendered as its bare name in that id, never expanded to its body
  (the same rule a self-recursive declaration relies on to terminate), so
  a host looks up each id it cares about in the "types" table rather than
  inlining one long string. Tramaj checks nothing about these facts or
  declarations against the values that flow through the program -- it only
  resolves references, normalises expressions, and refuses to leave a type
  hole unfilled at the root. A checker, if you want one, runs downstream on
  the concrete output.

STRINGS AND str
  Interpolation lowers to concat over str(...), so str decides what lands
  in the output:
    string   itself, raw
    null     ""
    boolean  true / false
    number   as JavaScript renders it: 3, 1.5, 0.05, 100000000000,
             1e+21, 1e-7
    array /  compact JSON with SORTED keys — key order is not
    object   semantically significant, so it is not observable here either

CONCAT
  a <> b, over three types, with no coercion:
    string <> string    array <> array    object <> object (right-biased)
  Mixed types are an error. Identities: "" [] {}

FUNCTIONS (the fixed builtin set — NO arithmetic: a template compares and
selects, it does not compute)
  cardinality(x) / count(x)   number of elements in an array/object
  str(x)                      as above
  not(b)                      negation
  and(a, b, ...)              conjunction, any number of args (and() = true)
  or(a, b, ...)               disjunction, any number of args (or() = false)
  eq(a, b)                    deep equality, no coercion: eq(1, "1") is false
  lt(a, b) / lte(a, b)        numeric comparison — numbers only
  gt(a, b) / gte(a, b)
  has(container, key)         tolerant: a missing field, out-of-range index
                              or wrong-shaped container answers false
  lookup(container, key,      dynamic access by a computed key/index. The
         fallback)            fallback is mandatory, so this never errors
  map(arr, fn)                a new array, fn applied to each element
  filter(arr, fn)             keeps the elements where fn is true
  scan(arr, init, fn)         [init, f(init,x1), f(f(init,x1),x2), ...] —
                              always one longer than arr. fn is (acc, item)
  fold(arr, init, fn)         same step and order, only the final accumulator
  concat(a, b, ...)           joins arrays; every argument must be an array
  append(arr, item)           adds one element at the end — an array item is
                              added whole, not spliced (use concat for that)
  branch is not here: it must leave an arm unevaluated, which no builtin
  can do, so it is part of the language itself.

ERRORS you may see
  UnboundName      a name that is not bound and not a builtin
  PathNotFound     a field the value does not have; shows the path as written
  TypeMismatch     wrong type or arity, a non-callable callee, or a value
                   that cannot cross a JSON boundary (a document used as an
                   attribute value, a closure used as a value)
  ConcatMismatch   <> over two different types
  UnknownLibrary   an import name with no tab of that name
  ImportCycle      a tab importing itself, directly or through another
  NotConcrete      a symbol where the language needs to know something
                   concrete about it (see SYMBOLS AND CONSTRAINTS above)
  AllocationInLibrary  a tab used as a library contains ?(key) itself —
                   only the root may allocate
  SymbolsUnavailable  a symbol would have to be minted in concrete mode —
                   switch on "Symbolic mode" instead
  UnresolvedType   a type name that resolves to no declaration and no
                   primitive
  PartialType      the root ships a type that still contains a %ctx.path
                   hole (see TYPES above) — supply it or move the
                   annotation into a library instead
  TypeParamCollision  one import params key read both as $ctx.k and %ctx.k
  NotStaticallyResolvable  $lib.types.X where lib is not bound directly to
                   an import(...) in an enclosing binding
  TypeCycle        a type declaration's ARGUMENTS cycle through each other
                   (a recursive body, like type Tree above, does not)

Full reference: specs/reference.md. Output format: specs/node-json.md."""
