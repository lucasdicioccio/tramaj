-- | A standalone browser playground for the tramaj language: a set of
-- | named tabs, each a freeform textarea holding either an element-rooted
-- | template or an expression-rooted JSON-mode program, plus a shared JSON
-- | context. The active tab is parsed/evaluated live and shown three ways
-- | — the evaluated `Node`/`Json` result as JSON, the same tree folded to
-- | real Halogen HTML (template mode only), and a log of every
-- | `action(...)` click that HTML dispatches. Every tab (including the
-- | active one) is also exposed to `import`/`partial-import` as a library,
-- | keyed by its tab name — see `buildLibraryTable`.
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

import Data.Argonaut.Core (Json, stringify, stringifyWithIndent)
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
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)
import Tramaj.Ast (ActionPayload, Node, nodeToJson)
import Tramaj.Eval (LibrarySource(..), LibraryTable, evalJsonProgram, evalProgram)
import Tramaj.Halogen (foldToHalogen, validateAttrNames)
import Tramaj.Parser (parseJsonProgram, parseProgram)

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  runUI component unit body

-- | Which of the two program roots (see `specs/llm.md` §5.1b) a tab is
-- | currently parsed as: an element (`Tramaj.Parser.parseProgram`,
-- | folded to Halogen HTML when active) or an expression
-- | (`parseJsonProgram`, evaluated straight to `Json` — no Halogen fold
-- | applies when active, since there's no `Node` to fold). Also which
-- | `LibrarySource` shape a tab contributes as a library for every other
-- | tab's `import`/`partial-import` calls — see `tabLibrarySource`.
data Mode = TemplateMode | JsonMode

derive instance eqMode :: Eq Mode

-- | One editor pane: a name (the key other tabs `import` it by), its own
-- | mode, and its own source text. Independent of every other tab —
-- | switching/editing one never touches another's draft.
type Tab =
  { name :: String
  , mode :: Mode
  , source :: String
  }

type State =
  { tabs :: Array Tab
  , activeTab :: Int
  -- ^ Index into `tabs` — which one is shown/evaluated as the root
  -- program on the right. Every tab, including this one, is still
  -- available to `import`/`partial-import` (see `buildLibraryTable`); a
  -- tab importing itself is handled by the language's own cycle guard,
  -- not excluded here.
  , jsonInput :: String
  -- ^ The shared `$ctx` for whichever tab is active — *not* passed to
  -- library tabs, which each get their own fresh `$ctx` from whatever
  -- `params` the active tab's `import(...)` call supplies.
  , actionLog :: Array { key :: String, payload :: Json }
  -- ^ Appended to by 'dispatchAction' on every `action(...)` click in the
  -- rendered output; newest last, rendered newest-first. Template-mode
  -- only — JSON mode never folds to Halogen HTML, so nothing can click.
  }

data Action
  = SetActiveTab Int
  | SetTabMode Int Mode
  | SetTabSource Int String
  | SetTabName Int String
  | AddTab
  | RemoveTab Int
  | SetJsonInput String
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
        , mode: TemplateMode
        , source:
            """@item-count=$cardinality($ctx.items)
@greeting=import("greeting", {"name": "World"})
@fgreet=partial-import("greeting", {})
@g=$fgreet({"name": "World"})
@btn=partial-import("btn", {})
@btn2=remap-actions($btn, prefix("main-"), (a) => {"eventType": $a.eventType, "payload": $a.payload})
.div(
  "data-count": $item-count,
  $greeting.rendered,
  $g.rendered,
  .p("there are `$item-count` `$g.vals.magic` item(s)"),
  .ul(map($ctx.items, (item) =>
    .li(
      .span($item.title),
      $btn2({"title": $item.title}).rendered
    )
  ))
)"""
        }
      , { name: "greeting"
        , mode: TemplateMode
        , source:
            """@magic="magic"
.p("hello, `$ctx.name`!")
"""
        }
      , { name: "btn"
        , mode: TemplateMode
        , source:
            """.button(action("on-click", "select-item", {"title": $ctx.title}), "Select")
"""
        }
      , { name: "json-demo"
        , mode: JsonMode
        , source:
            """@item-count=$cardinality($ctx.items)
{"count": $item-count, "titles": map($ctx.items, (item) => $item.title)}"""
        }
      ]
  , activeTab: 0
  , jsonInput:
      """{"items": [{"title": "Alpha"}, {"title": "Beta"}]}"""
  , actionLog: []
  }

handleAction :: forall output. Action -> H.HalogenM State Action () output Aff Unit
handleAction = case _ of
  SetActiveTab i -> H.modify_ _ { activeTab = i }
  SetTabMode i mode -> modifyTab i _ { mode = mode }
  SetTabSource i source -> modifyTab i _ { source = source }
  SetTabName i name -> modifyTab i _ { name = name }
  AddTab -> H.modify_ \s ->
    s
      { tabs = Array.snoc s.tabs { name: "tab-" <> show (Array.length s.tabs + 1), mode: TemplateMode, source: "" }
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
  ActionFired key payload -> H.modify_ \s -> s { actionLog = s.actionLog <> [ { key, payload } ] }
  ClearActionLog -> H.modify_ _ { actionLog = [] }
  where
  modifyTab :: Int -> (Tab -> Tab) -> H.HalogenM State Action () output Aff Unit
  modifyTab i f = H.modify_ \s -> s { tabs = fromMaybe s.tabs (Array.modifyAt i f s.tabs) }

  clampActive :: Int -> Int -> Int
  clampActive maxIdx i = max 0 (min maxIdx i)

-- | Every tab — including the active one — parsed as a `LibrarySource`
-- | keyed by its name, per that tab's own `mode`. A tab that fails to
-- | parse is simply left out of the map (see `tabParseError`, used
-- | separately by the tab bar to flag it) rather than surfacing here —
-- | importing a dropped tab just fails as the language's own
-- | `UnknownLibrary`, no different from naming a library that never
-- | existed.
buildLibraryTable :: Array Tab -> LibraryTable
buildLibraryTable tabs = Map.fromFoldable (Array.mapMaybe entry tabs)
  where
  entry :: Tab -> Maybe (Tuple String LibrarySource)
  entry tab = either (const Nothing) (\src -> Just (Tuple tab.name src)) (tabLibrarySource tab)

tabLibrarySource :: Tab -> Either String LibrarySource
tabLibrarySource tab = case tab.mode of
  TemplateMode -> bimapEither ProgramSource (parseProgram tab.source)
  JsonMode -> bimapEither JsonSource (parseJsonProgram tab.source)
  where
  bimapEither :: forall a b e. Show e => (a -> b) -> Either e a -> Either String b
  bimapEither f = either (\e -> Left (show e)) (Right <<< f)

activeTabOf :: State -> Tab
activeTabOf state = fromMaybe { name: "", mode: TemplateMode, source: "" } (Array.index state.tabs state.activeTab)

render :: State -> H.ComponentHTML Action () Aff
render state =
  HH.div [ HP.class_ (HH.ClassName "wrap") ]
    [ HH.h1_ [ HH.text "tramaj playground" ]
    , HH.p [ HP.class_ (HH.ClassName "hint") ]
        [ HH.text "Renders a tramaj template against a JSON context, entirely in the browser. See specs/templating-language.md for the full grammar; the reference below is the short version." ]
    , HH.details [ HP.class_ (HH.ClassName "card") ]
        [ HH.summary_ [ HH.text "Language reference" ]
        , HH.pre [ HP.class_ (HH.ClassName "ref" ) ] [ HH.text referenceText ]
        ]
    , HH.div [ HP.class_ (HH.ClassName "cols") ]
        [ HH.div [ HP.class_ (HH.ClassName "card") ]
            [ HH.div [ HP.class_ (HH.ClassName "row") ]
                [ HH.h2_ [ HH.text "Template" ]
                , renderModeToggle state.activeTab activeTab.mode
                ]
            , renderTabBar state
            , HH.p [ HP.class_ (HH.ClassName "hint") ]
                [ HH.text "Every tab is available to import(...)/partial-import(...) by its name, including the active one — switch tabs above to edit a library." ]
            , modeHint activeTab.mode
            , HH.textarea
                [ HP.class_ (HH.ClassName "input")
                , HP.rows 16
                , HP.spellcheck false
                , HP.value activeTab.source
                , HE.onValueInput (SetTabSource state.activeTab)
                ]
            ]
        , HH.div [ HP.class_ (HH.ClassName "card") ]
            [ HH.h2_ [ HH.text "JSON context" ]
            , HH.textarea
                [ HP.class_ (HH.ClassName "input")
                , HP.rows 16
                , HP.spellcheck false
                , HP.value state.jsonInput
                , HE.onValueInput SetJsonInput
                ]
            ]
        ]
    , HH.div [ HP.class_ (HH.ClassName "cols") ]
        [ HH.div [ HP.class_ (HH.ClassName "card") ]
            [ HH.h2_ [ HH.text "AST" ]
            , HH.p [ HP.class_ (HH.ClassName "hint") ]
                [ HH.text case activeTab.mode of
                    TemplateMode -> "The evaluated Tramaj.Ast.Node tree — the same value foldToHalogen is folding on the right, shown as plain JSON before that fold happens."
                    JsonMode -> "The evaluated JSON value, before it's pretty-printed on the right — for JSON mode this is the same value, just stringified with no indentation."
                ]
            , renderAst state
            ]
        , HH.div [ HP.class_ (HH.ClassName "card") ]
            [ HH.h2_ [ HH.text "Rendered" ]
            , HH.div [ HP.class_ (HH.ClassName "rendered") ] [ renderOutput state ]
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
            [ HH.text case activeTab.mode of
                TemplateMode -> "Every action(...) click in the rendered output is dispatched here — real Halogen actions, appended by the demo handler passed to foldToHalogen."
                JsonMode -> "JSON mode has no Node tree to fold to Halogen HTML, so nothing here can dispatch an action(...) click — switch to Template mode to try that."
            ]
        , renderActionLog state
        ]
    ]
  where
  activeTab = activeTabOf state

-- | One chip per tab (click activates it; an inline name field renames
-- | it; a "×" removes it, disabled when it's the only tab left), plus a
-- | trailing "+ tab" button. A tab whose `tabLibrarySource` doesn't parse
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
                  <> (if either (const true) (const false) (tabLibrarySource tab) then " tab-error" else "")
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

-- | Two buttons switching the active tab's `mode` — deliberately not a
-- | `<select>`, since there are only ever these two roots (see `Mode`'s
-- | note on why element vs. expression can never be ambiguous either).
renderModeToggle :: Int -> Mode -> H.ComponentHTML Action () Aff
renderModeToggle activeIdx mode =
  HH.div [ HP.class_ (HH.ClassName "mode-toggle") ]
    [ modeButton TemplateMode "Template"
    , modeButton JsonMode "JSON"
    ]
  where
  modeButton :: Mode -> String -> H.ComponentHTML Action () Aff
  modeButton m label =
    HH.button
      [ HP.class_ (HH.ClassName (if mode == m then "btn btn-active" else "btn"))
      , HE.onClick \_ -> SetTabMode activeIdx m
      ]
      [ HH.text label ]

modeHint :: Mode -> H.ComponentHTML Action () Aff
modeHint mode =
  HH.p [ HP.class_ (HH.ClassName "hint") ]
    [ HH.text case mode of
        TemplateMode -> "Rooted at an element (parseProgram/evalProgram) — folded to real Halogen HTML on the right."
        JsonMode -> "Rooted at an expression (parseJsonProgram/evalJsonProgram) — evaluates straight to a JSON value, no document tree involved."
    ]

-- | The two possible parse/eval outcomes, one per `Mode` — `ResultNode`
-- | folds to real Halogen HTML (`renderOutput`) and to `Node`'s own JSON
-- | shape (`renderAst`, via `nodeToJson`); `ResultJson` has no document
-- | tree to fold, so it's shown the same prettified way in both panels.
data EvalResult
  = ResultNode Node
  | ResultJson Json

-- | Shared by 'renderOutput' and 'renderAst' so both panels reflect one
-- | parse/eval result rather than each re-running the pipeline and
-- | risking disagreement mid-edit.
computeResult :: State -> Either String EvalResult
computeResult state = case jsonParser state.jsonInput of
  Left err -> Left ("Invalid JSON: " <> err)
  Right ctx ->
    let
      activeTab = activeTabOf state
      libs = buildLibraryTable state.tabs
    in
      case activeTab.mode of
        TemplateMode -> case parseProgram activeTab.source of
          Left err -> Left ("Template parse error: " <> show err)
          Right program -> case evalProgram libs ctx program of
            Left err -> Left ("Template eval error: " <> show err)
            Right node -> Right (ResultNode node)
        JsonMode -> case parseJsonProgram activeTab.source of
          Left err -> Left ("Template parse error: " <> show err)
          Right program -> case evalJsonProgram libs ctx program of
            Left err -> Left ("Template eval error: " <> show err)
            Right json -> Right (ResultJson json)

renderOutput :: State -> H.ComponentHTML Action () Aff
renderOutput state = case computeResult state of
  Left err -> renderError err
  Right (ResultNode node) -> case validateAttrNames node of
    [] -> foldToHalogen dispatchAction node
    invalid -> renderError
      ( "Invalid attribute name(s): "
          <> joinWith ", " invalid
          <> " — attribute keys may only contain letters, digits, '-' and '_'"
      )
  -- | JSON mode has no `Node` tree to fold to Halogen HTML — the
  -- | "rendered" form of a JSON value is just the value itself,
  -- | pretty-printed and wrapped in a `<code>` tag (inside a `<pre>` so
  -- | the indentation survives HTML's whitespace collapsing).
  Right (ResultJson json) ->
    HH.pre [ HP.class_ (HH.ClassName "ref") ]
      [ HH.code_ [ HH.text (stringifyWithIndent 2 json) ] ]

renderAst :: State -> H.ComponentHTML Action () Aff
renderAst state = case computeResult state of
  Left err -> renderError err
  Right (ResultNode node) -> HH.pre [ HP.class_ (HH.ClassName "ref") ] [ HH.text (stringifyWithIndent 2 (nodeToJson node)) ]
  Right (ResultJson json) -> HH.pre [ HP.class_ (HH.ClassName "ref") ] [ HH.text (stringifyWithIndent 2 json) ]

-- | The demo dispatcher: every `action(...)` click becomes a real
-- | Halogen action appended to the log. A read-only host would pass
-- | `const Nothing` here instead — see 'Tramaj.Halogen'.
dispatchAction :: ActionPayload -> Maybe Action
dispatchAction ap = Just (ActionFired ap.key ap.payload)

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
-- | `specs/templating-language.md`'s grammar/builtin summary closely
-- | enough to be useful without opening that file.
referenceText :: String
referenceText =
    """LEADER CHARACTERS — one job each
  .    starts an element:            .tag(...)
  $    reads a bound name/$ctx path:  $name, $name.field, $cardinality(x)
  @    defines a binding (computation block only): @name=expr

PRIMITIVES
  $name              a bound name, or a `$ctx`-rooted JSON field path
  $name.field.field2 dotted path — object field access, one segment per "."
  "literal text"     a string literal; embed `$a.path` (or any expr,
                     e.g. `$cardinality($nums)`) anywhere inside via
                     backticks to interpolate it, e.g. "count: `$n`"
  123 / 123.45       a number literal
  true / false       a boolean literal
  fn(arg, ...)       a call to a fixed builtin (see FUNCTIONS below) —
  $fn(arg, ...)      `$fn(...)` is an accepted alternative spelling of
                     the same call, since `$` always means "look this
                     up," and a builtin name resolves the same way
  [expr, expr, ...]  a JSON-like array literal, e.g. [1, 2, 3]
  {"key": expr, ...} a JSON-like object literal — keys are always
                     quoted, e.g. {"items": $ctx.items}
  (p1, p2, ...) => expr
                     a lambda *value* — see LAMBDAS below
  Names (binding names, path segments, tags, bare attribute keys,
  builtin names) may contain internal hyphens: my-var, foo-bar.

LAMBDAS — bindable, not just inline
  (p1, p2, ...) => expr
  A real value: write it inline as a call argument (map(arr, (x) =>
  ...)) *or* bind it — @my-fn=(x) => $gt($x, 10) — and call it later
  by name: $my-fn(5). A bound lambda can also be passed BY REFERENCE
  instead of written inline: map($ctx.items, $my-fn). Closures capture
  the environment where they were written (lexical scoping), so a
  lambda's body can see outer bindings, not just its own parameters —
  and a closure can itself be passed as an argument to another
  function (higher-order), e.g. @apply=(f, x) => $f($x). Two hard
  limits: no recursion (a closure's captured environment is snapshot
  *before* its own binding exists, so it can't call itself by name from
  inside its own body), and a closure used where a plain value is
  expected (interpolated into a string, stored in an array/object
  literal, passed to a fixed builtin) is a clear error — call it first.

COMPUTATION BLOCK (optional, above the template)
  @name=expr
  One binding per line, evaluated once against $ctx before the template
  runs. A binding may reference $ctx and any earlier binding, never a
  later one. Read back later via `$name`, e.g.
  @count=$cardinality($ctx.items) is later read via `$count`.

TEMPLATE BLOCK
  .tag(arg, arg, ...)
  One element. Named attrs must all come before any child in the
  argument list (a child before an attr is a parse error). Each
  comma-separated arg is one of:
    key: value          a named attribute — key is a bare identifier or
    "key-or-str": value a quoted string; value is any expr (a string, a
                        path, a call, a number, or an array/object
                        literal)
    "text" / $a.path    a bare value, rendered as a text child
    .tag(...)           a nested element, as a child
    map(arr, (item) => .tag(...))
                        repeats the body once per array item; `item` is
                        bound (read via `$item`) inside that body only.
                        `arr` is any expr, not just a bare path — e.g.
                        map(filter(...), (x) => ...) is fine
    branch(fallbackNode, pred1, node1, pred2, node2, ...)
                        picks exactly one node — "if pred1, node1; else
                        if pred2, node2; ...; else fallbackNode" — as a
                        child, not a value (see the expr-level branch(...)
                        in FUNCTIONS below for picking a *value*
                        conditionally instead). Only the chosen node is
                        ever evaluated — unlike expr-level branch, an
                        unreached node's own errors don't surface
    action(eventTypeExpr, keyExpr, payloadExpr)
                        wires a real DOM event to a host dispatcher —
                        see ACTIONS below. Counts as attr-like for
                        ordering (must come before children); a node
                        can have at most one.

ACTIONS — dispatched to a real Halogen handler
  action(eventTypeExpr, keyExpr, payloadExpr)
  All three are ordinary exprs, not keywords — eventTypeExpr/keyExpr
  are each any expr that evaluates to a string (a literal like
  "on-click", or something computed like $ctx.eventName);
  payloadExpr is any expr, typically an object literal. This host
  (the Halogen fold) currently only recognizes "on-click" as
  eventType (an unrecognized one is an eval-time error) — other hosts
  (e.g. a future email/static-site renderer) may recognize a
  different vocabulary, since eventType is just a runtime string, not
  a fixed keyword baked into the parser. When clicked, the host's
  dispatcher function receives the whole { eventType, key, payload }
  — structured, not a string to parse. THIS PLAYGROUND wires a real
  dispatcher: every action click is appended to the "Action log"
  panel below the rendered output below, showing exactly the
  key/payload the click carried.

IMPORTS — reusing another tab as a library
  import(name, paramsExpr)
  partial-import(name, paramsExpr)
  `name` is a bare quoted-string literal naming a tab in this
  playground (every tab, including the active one, is available —
  see the tab bar above); `paramsExpr` is that tab's own `$ctx`.
  The result exposes `.rendered` (whatever the library's root
  evaluated to — an element-rooted tab's `Node`, spliced as a child
  when used as one, or an expression-rooted tab's plain JSON value)
  and `.vals` (its own top-level bindings, dotted-path accessible,
  e.g. `$lib.vals.something`). `partial-import` tolerates an
  incomplete `paramsExpr`: instead of erroring on a missing `$ctx`
  field, it suspends into a value you can call with the rest of the
  params later (`$partial({"more": "params"})`), completing to
  exactly the same result a direct `import` with the merged params
  would have produced — and since a call's result can itself be
  field-accessed directly (`.field` chains after a closing `)`, not
  just after a bound `$name`), that completion and reading `.rendered`
  off it can be written in one expression with no intermediate
  binding: `$partial({"more": "params"}).rendered`.

  remap-actions(nodeExpr, prefix(prefixExpr), fnExpr)
  Contramaps every `action(...)` found anywhere in `nodeExpr`'s
  rendered `Node` (recursively through its children, not just its own
  root): the action's `key` is rewritten by `prefix(prefixExpr)` —
  prepends `prefixExpr`'s string value to the original key; `prefixExpr`
  may itself be computed/dynamic, just not the *operation*, which is
  fixed to prefixing (a small closed set of key-rewriting operations is
  meant to grow here, e.g. a future `replace(...)`, rather than
  arbitrary rewriting) — and `eventType`/`payload` are passed through
  `fn`, a closure taking the `{"eventType": ..., "key": ..., "payload":
  ...}` shape a node's own `action` field prints as (with `key` already
  prefixed) and returning `{"eventType": ..., "payload": ...}`; `fn` can
  no longer set `key` itself. Lets a template that imports a library
  rewrite what that library's own actions look like before they reach
  the host's dispatcher — namespace a key, or transform a payload as a
  function of the (already-prefixed) key/original payload — without the
  library itself knowing anything about who imported it. `nodeExpr` may
  be a rendered node directly (e.g. `$lib.rendered`), an import/partial-
  import result itself (`$lib`, or a just-completed `$partial({...})`),
  or a still-*incomplete* `partial-import(...)` — in every case
  `remap-actions` descends into *every* value reachable from it: a
  `.vals` binding can itself be a sub-import with its own rendered node
  and actions (those get remapped too, in case they're reached via
  `.vals...rendered` rather than the outer `.rendered`), and wrapping a
  still-incomplete partial just queues the `(prefix, fn)` operation to
  run once the partial is finally completed — including across currying
  it one param at a time — rather than requiring it. That means
  `remap-actions(...)` can be attached once, in the computation block,
  directly to a `partial-import(...)` before the value that completes it
  is even in scope (e.g. a per-item value only available inside a
  `map(...)` body):
  `@btn2=remap-actions($btn, prefix("form:"), fn)` ...
  `map($ctx.items, (item) => $btn2({"title": $item.title}).rendered)` —
  no inline `remap-actions(...)` wrapping needed at every call site.
  `fn`'s result must have a string `eventType` field, same as a literal
  `action(...)`; anything with no actions anywhere (a node, or an import
  result) is left unchanged (`fn` is never called).

FUNCTIONS (fixed set — no custom functions)
  cardinality(x) / count(x)   number of elements in an array, or number
                              of keys in an object (the two names are
                              aliases for the same function)
  not(a)                      boolean negation
  and(a, b, ...)              conjunction over any number of arguments
  or(a, b, ...)               disjunction over any number of arguments
  eq(a, b)                    deep equality between two values
  lt(a, b) / lte(a, b)        numeric comparison (both arguments must
  gt(a, b) / gte(a, b)        be numbers)
  has(container, key)         presence/absence — never errors; a missing
                              field, out-of-range index, or wrong-shaped
                              container/key just answers false
  lookup(container, key,      dynamic object-field/array-index access by
         fallback)            a computed key/index (the counterpart to a
                              static $ctx.field path) — the 3rd argument
                              is a mandatory fallback for a missing
                              field/out-of-range index, so like has this
                              never errors either
  branch(fallback,            "if pred1, val1; else if pred2, val2; ...;
         pred1, val1,         else fallback" as one *value* expression —
         pred2, val2, ...)    contrast the template-block branch(...)
                              above, which picks a node instead. CAUTION:
                              every argument here (every predicate and
                              value, taken or not) is evaluated eagerly
                              first — there is no short-circuiting, so
                              every value must be safe to evaluate no
                              matter which predicate wins
  map(arr, fn)                 transforms each array element, producing
                              a new array — the value-producing
                              counterpart to the template-block map(...)
                              above. `fn` is any expr that evaluates to
                              a lambda — inline (item) => ... or a name
                              bound to one, e.g. $my-fn (see LAMBDAS)
  filter(arr, fn)               keeps only the elements where fn is true
  scan(arr, init, fn)           an accumulative fold: [init, step(init,
                              x1), step(step(init, x1), x2), ...] — the
                              output array is always one longer than arr
                              (the seed comes first). fn takes 2 args:
                              (acc, item) => ...
  fold(arr, init, fn)           same (acc, item) step and seed-first order
                              as scan, but returns only the final
                              accumulator instead of the whole array —
                              init unchanged if arr is empty
  concat(a, b, ...)             joins any number of arrays (0 or more)
                              into one, preserving order — each argument
                              must itself be an array
  append(arr, item)             a new array with item added at the end;
                              item can be anything, including an array/
                              object (added as one element — use concat
                              to splice arrays together instead)"""
