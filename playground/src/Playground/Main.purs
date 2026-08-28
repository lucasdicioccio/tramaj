-- | A standalone browser playground for the tramaj language: a set of
-- | named tabs, each a freeform textarea holding one program, plus a
-- | shared JSON context. The active tab is parsed/evaluated live and shown
-- | three ways — the result as JSON, the same result folded to real
-- | Halogen HTML, and a log of every `action(...)` click that HTML
-- | dispatches. Every tab (including the active one) is also exposed to
-- | `import` as a library, keyed by its tab name — see
-- | `buildLibraryTable`.
-- |
-- | v2 removed this playground's mode switch. A program's kind is decided
-- | by its own root — a document if it is written as one — so there was
-- | nothing left for the reader to choose, and a tab that used to be
-- | mis-set is now simply impossible.
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
import Tramaj.Ast (Program)
import Tramaj.Eval (LibraryTable, Mode(Concrete), Output(..), evalProgram)
import Tramaj.Halogen (foldToHalogen, validateAttrNames)
import Tramaj.Node (Node, nodeToJson)
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
  }

data Action
  = SetActiveTab Int
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
      ]
  , activeTab: 0
  , jsonInput:
      -- Carries what every default tab reads, not just the active one, so
      -- selecting a library tab shows it rendering instead of a
      -- PathNotFound for the parameter its importer would have supplied.
      -- row-kind is the one the main tab actually reads, through ctx(...).
      """{"items": [{"title": "Alpha"}, {"title": "Beta"}], "name": "World", "title": "Alpha", "kind": "item", "row-kind": "item"}"""
  , actionLog: []
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
                [ HH.text "The result in the normative specs/node-json.md representation — the same value foldToHalogen is folding on the right, shown before that fold happens. A program that produced an ordinary value is shown as that value." ]
            , renderAst state
            ]
        , HH.div [ HP.class_ (HH.ClassName "card") ]
            [ HH.h2_ [ HH.text "Rendered" ]
            , HH.div [ HP.class_ (HH.ClassName "rendered") ] (renderOutput state)
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
        Right (ResultNode _) ->
          "This program's root is a document — folded to real Halogen HTML on the right."
        Right (ResultValue _) ->
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
      case parseProgram activeTab.source of
        Left err -> Left ("Template parse error: " <> show err)
        Right program -> case evalProgram Concrete libs ctx program of
          Left err -> Left ("Template eval error: " <> show err)
          Right (ONode node) -> Right (ResultNode node)
          Right (OValue value) -> Right (ResultValue value)

-- | Returns an `Array` because `foldToHalogen` does: a document rooted at
-- | a fragment is several siblings with no wrapper, and inventing one here
-- | would contradict the point of fragments.
renderOutput :: State -> Array (H.ComponentHTML Action () Aff)
renderOutput state = case computeResult state of
  Left err -> [ renderError err ]
  Right (ResultNode node) -> case validateAttrNames node of
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
  Right (ResultValue value) ->
    [ HH.pre [ HP.class_ (HH.ClassName "ref") ]
        [ HH.code_ [ HH.text (stringifyWithIndent 2 value) ] ]
    ]

renderAst :: State -> H.ComponentHTML Action () Aff
renderAst state = case computeResult state of
  Left err -> renderError err
  Right (ResultNode node) -> HH.pre [ HP.class_ (HH.ClassName "ref") ] [ HH.text (stringifyWithIndent 2 (nodeToJson node)) ]
  Right (ResultValue value) -> HH.pre [ HP.class_ (HH.ClassName "ref") ] [ HH.text (stringifyWithIndent 2 value) ]

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

Full reference: specs/reference.md. Output format: specs/node-json.md."""
