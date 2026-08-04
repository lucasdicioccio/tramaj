-- | A standalone browser playground for the templating language: a
-- | template and a JSON context, both freeform textarea input, parsed and
-- | evaluated live and shown three ways — the evaluated `Node` tree as
-- | JSON, the same tree folded to real Halogen HTML, and a log of every
-- | `action(...)` click that HTML dispatches.
-- |
-- | It exists to exercise the whole pipeline end to end in one place:
-- | `Templating.Parser` -> `Templating.Eval` -> `Templating.Halogen`'s
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
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String (joinWith)
import Effect (Effect)
import Effect.Aff (Aff)
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)
import Templating.Ast (ActionPayload, Node, nodeToJson)
import Templating.Eval (evalProgram)
import Templating.Halogen (foldToHalogen, validateAttrNames)
import Templating.Parser (parseProgram)

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  runUI component unit body

type State =
  { templateInput :: String
  , jsonInput :: String
  , actionLog :: Array { key :: String, payload :: Json }
  -- ^ Appended to by 'dispatchAction' on every `action(...)` click in the
  -- rendered output; newest last, rendered newest-first.
  }

data Action
  = SetTemplateInput String
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
  { templateInput:
      """@item-count=$cardinality($ctx.items)
.div(
  "data-count": $item-count,
  .p("there are `$item-count` item(s)"),
  .ul(map($ctx.items, (item) =>
    .li(
      .span($item.title),
      .button(action("on-click", "select-item", {"title": $item.title}), "Select")
    )
  ))
)"""
  , jsonInput:
      """{"items": [{"title": "Alpha"}, {"title": "Beta"}]}"""
  , actionLog: []
  }

handleAction :: forall output. Action -> H.HalogenM State Action () output Aff Unit
handleAction = case _ of
  SetTemplateInput template -> H.modify_ _ { templateInput = template }
  SetJsonInput json -> H.modify_ _ { jsonInput = json }
  ActionFired key payload -> H.modify_ \s -> s { actionLog = s.actionLog <> [ { key, payload } ] }
  ClearActionLog -> H.modify_ _ { actionLog = [] }

render :: State -> H.ComponentHTML Action () Aff
render state =
  HH.div [ HP.class_ (HH.ClassName "wrap") ]
    [ HH.h1_ [ HH.text "Templating playground" ]
    , HH.p [ HP.class_ (HH.ClassName "hint") ]
        [ HH.text "Renders a templating-language template against a JSON context, entirely in the browser. See specs/templating-language.md for the full grammar; the reference below is the short version." ]
    , HH.details [ HP.class_ (HH.ClassName "card") ]
        [ HH.summary_ [ HH.text "Language reference" ]
        , HH.pre [ HP.class_ (HH.ClassName "ref" ) ] [ HH.text referenceText ]
        ]
    , HH.div [ HP.class_ (HH.ClassName "cols") ]
        [ HH.div [ HP.class_ (HH.ClassName "card") ]
            [ HH.h2_ [ HH.text "Template" ]
            , HH.textarea
                [ HP.class_ (HH.ClassName "input")
                , HP.rows 16
                , HP.spellcheck false
                , HP.value state.templateInput
                , HE.onValueInput SetTemplateInput
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
                [ HH.text "The evaluated Templating.Ast.Node tree — the same value foldToHalogen is folding on the right, shown as plain JSON before that fold happens." ]
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
            [ HH.text "Every action(...) click in the rendered output is dispatched here — real Halogen actions, appended by the demo handler passed to foldToHalogen." ]
        , renderActionLog state
        ]
    ]

-- | Shared by 'renderOutput' and 'renderAst' so both panels reflect one
-- | parse/eval result rather than each re-running the pipeline and
-- | risking disagreement mid-edit.
computeNode :: State -> Either String Node
computeNode state = case jsonParser state.jsonInput of
  Left err -> Left ("Invalid JSON: " <> err)
  Right ctx -> case parseProgram state.templateInput of
    Left err -> Left ("Template parse error: " <> show err)
    Right program -> case evalProgram ctx program of
      Left err -> Left ("Template eval error: " <> show err)
      Right node -> Right node

renderOutput :: State -> H.ComponentHTML Action () Aff
renderOutput state = case computeNode state of
  Left err -> renderError err
  Right node -> case validateAttrNames node of
    [] -> foldToHalogen dispatchAction node
    invalid -> renderError
      ( "Invalid attribute name(s): "
          <> joinWith ", " invalid
          <> " — attribute keys may only contain letters, digits, '-' and '_'"
      )

renderAst :: State -> H.ComponentHTML Action () Aff
renderAst state = case computeNode state of
  Left err -> renderError err
  Right node -> HH.pre [ HP.class_ (HH.ClassName "ref") ] [ HH.text (stringifyWithIndent 2 (nodeToJson node)) ]

-- | The demo dispatcher: every `action(...)` click becomes a real
-- | Halogen action appended to the log. A read-only host would pass
-- | `const Nothing` here instead — see 'Templating.Halogen'.
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
                              (acc, item) => ..."""
