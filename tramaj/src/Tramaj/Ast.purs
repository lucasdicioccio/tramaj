-- | Core types for the tramaj language: unevaluated computation-phase
-- expressions (`Expr`), unevaluated template-phase nodes (`TemplateNode`),
-- and the evaluated output AST (`Node`) that `Tramaj.Halogen` folds
-- into real Halogen HTML. See `specs/templating-language.md` for the
-- grammar and design rationale.
module Tramaj.Ast
  ( Expr(..)
  , KeySpec(..)
  , StringPart(..)
  , TAction(..)
  , ActionPayload
  , TemplateNode(..)
  , Node(..)
  , Program
  , JsonProgram
  , nodeToJson
  , actionPayloadToJson
  , staticImportNames
  ) where

import Prelude

import Data.Argonaut.Core (Json, fromArray, fromObject, fromString, jsonNull, stringify)
import Data.Foldable (foldMap)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.Tuple (Tuple(..), snd)
import Foreign.Object as Object

-- | A dotted path, e.g. `$ctx.items` is `Path [ "ctx", "items" ]` and a
-- | bound computation name `$count` is `Path [ "count" ]`. `$` always
-- | means "look up a name in the environment" (bound computation names
-- | unioned with `$ctx`); `Call` is that same lookup immediately applied
-- | — `$cardinality($ctx.items)` is `Call [ "cardinality" ] [ Path [
-- | "ctx", "items" ] ]`. A `Call`'s callee resolves against the
-- | environment first (a name bound to a `LambdaExpr`-produced closure —
-- | see below — is called directly) and only falls back to the fixed
-- | builtin table if the name isn't bound to anything (see
-- | `Tramaj.Eval`).
-- |
-- | `LambdaExpr params body` — `(p1, p2, ...) => body` — is a genuine
-- | first-class value: it can be written inline as a call argument
-- | (`map(arr, (item) => ...)`) *or* bound via `@name=(p1, ...) =>
-- | body` and called later via `$name(...)`, passed to another
-- | function, or passed to `map`/`filter`/`scan` by reference. Evaluating
-- | a `LambdaExpr` captures the environment at that point (lexical
-- | scoping/closures) — see `Tramaj.Eval`'s `Value`/`VClosure`.
-- | **No recursion**: a closure's captured environment is snapshotted
-- | *before* its own binding is inserted, so a lambda can't call itself
-- | by name from within its own body.
-- |
-- | `MapExpr`/`FilterExpr`/`ScanExpr`/`FoldExpr` are the functional-style
-- | array primitives: `map(arr, fn)`, `filter(arr, fn)`, `scan(arr, init,
-- | fn)`, `fold(arr, init, fn)`, where `fn` is any `expr` that evaluates
-- | to a closure — an inline `LambdaExpr` or a `Path` to a previously
-- | bound one. These aren't ordinary `Call`s: `arr`'s elements need
-- | binding into `fn`'s closure environment fresh per element (and, for
-- | `scan`/`fold`, per accumulator step too), which the uniform
-- | "evaluate every argument to a `Json` value up front" `Call` dispatch
-- | can't express (see `Tramaj.Eval`). `fold` shares `scan`'s
-- | `(acc, item)` step signature and `scanl` iteration order, but returns
-- | only the final accumulator instead of every intermediate step.
-- |
-- | `ImportExpr name paramsExpr` — `import(name, params)` — evaluates a
-- | library (a `Program` looked up by name in a host-supplied table, not
-- | anything reachable from `$ctx`) with `params` as that library's own
-- | `$ctx`, producing a value exposing `.rendered` (its evaluated template,
-- | a document `Node`) and `.vals` (its top-level bindings). `PartialImportExpr`
-- | is the same but tolerates an incomplete `params`: see
-- | `Tramaj.Eval`'s `tryPartial`/`VPartial`.
-- |
-- | `name` is a bare `String`, not an `Expr` — the parser only ever accepts
-- | a plain quoted literal (no `` `interp` ``) in this position, so a
-- | template's import names are knowable by walking the parsed AST, without
-- | evaluating it (see `staticImportNames` below). This matches
-- | `specs/position.md`'s "imports are statically identifiable" claim.
-- |
-- | `FieldAccess baseExpr segs` — `<expr>.field1.field2...` — the postfix
-- | counterpart to `Path`'s prefix dotted chain: `Path` only ever starts
-- | from a bound name (`$name.field`), so it can't express field access on
-- | the *result* of a call, e.g. completing a `partial-import` and reading
-- | `.rendered` off it in one expression — `$btn({"title": $x}).rendered`
-- | — without an intermediate `@`-binding. `baseExpr` is evaluated first,
-- | then each segment walks it exactly like `Path`'s own field-walking
-- | (see `Tramaj.Eval`'s `walkFields`, shared by both).
-- |
-- | `RemapActionsExpr nodeExpr keySpec fnExpr` —
-- | `remap-actions(node, prefix(prefixExpr), fn)` — contramaps every
-- | `action(...)` found anywhere in `nodeExpr`'s rendered `Node`
-- | (recursively through its children, not just its own root): the action's
-- | `key` is rewritten by `keySpec` (currently only `prefix(prefixExpr)` —
-- | prepends `prefixExpr`'s string value to the original key; `prefixExpr`
-- | may itself be a computed/dynamic expr, just not the *operation*, which
-- | is fixed to prefixing), and `eventType`/`payload` are passed through
-- | `fn`: a closure taking the `{eventType, key, payload}` shape
-- | `actionPayloadToJson` produces (with `key` already prefixed) and
-- | returning `{eventType, payload}` — `fn` can no longer set `key` itself,
-- | since `keySpec` is now the sole, statically-identifiable source of key
-- | rewriting (`specs/position.md` §12; `prefix` is the first of what's
-- | meant to grow into a small closed set of key operations, e.g. a future
-- | `replace(...)`). Lets a template that imports a library rewrite
-- | (namespace a key, transform a payload) whatever actions that library's
-- | own template fires before they're visible to the host — the tramaj
-- | counterpart to remapping a child component's output actions before
-- | they bubble up to a parent. See `Tramaj.Eval`'s `remapActionsInNode`.
data Expr
  = Path (Array String)
  | Call (Array String) (Array Expr)
  | StringLit (Array StringPart)
  | NumberLit Number
  | BoolLit Boolean
  | ArrayLit (Array Expr)
  | ObjectLit (Array (Tuple String Expr))
  | LambdaExpr (Array String) Expr
  | MapExpr Expr Expr
  | FilterExpr Expr Expr
  | ScanExpr Expr Expr Expr
  | FoldExpr Expr Expr Expr
  | ImportExpr String Expr
  | PartialImportExpr String Expr
  | FieldAccess Expr (Array String)
  | RemapActionsExpr Expr KeySpec Expr

-- | The key-rewriting operation a `remap-actions(...)` call's second
-- | argument names — currently just `prefix(prefixExpr)`, deliberately a
-- | small closed set (not an arbitrary closure) so a key rewrite stays a
-- | statically-identifiable *operation* even though `prefixExpr` itself may
-- | be dynamic. See the `RemapActionsExpr` note above.
data KeySpec = KeyPrefix Expr

derive instance eqKeySpec :: Eq KeySpec

instance showKeySpec :: Show KeySpec where
  show (KeyPrefix e) = "KeyPrefix (" <> show e <> ")"

derive instance eqExpr :: Eq Expr

instance showExpr :: Show Expr where
  show (Path segs) = "Path " <> show segs
  show (Call segs args) = "Call " <> show segs <> " " <> show args
  show (StringLit parts) = "StringLit " <> show parts
  show (NumberLit n) = "NumberLit " <> show n
  show (BoolLit b) = "BoolLit " <> show b
  show (ArrayLit elems) = "ArrayLit " <> show elems
  show (ObjectLit entries) = "ObjectLit " <> show entries
  show (LambdaExpr params body) = "LambdaExpr " <> show params <> " (" <> show body <> ")"
  show (MapExpr arr fn) = "MapExpr (" <> show arr <> ") (" <> show fn <> ")"
  show (FilterExpr arr fn) = "FilterExpr (" <> show arr <> ") (" <> show fn <> ")"
  show (ScanExpr arr initE fn) = "ScanExpr (" <> show arr <> ") (" <> show initE <> ") (" <> show fn <> ")"
  show (FoldExpr arr initE fn) = "FoldExpr (" <> show arr <> ") (" <> show initE <> ") (" <> show fn <> ")"
  show (ImportExpr name paramsE) = "ImportExpr " <> show name <> " (" <> show paramsE <> ")"
  show (PartialImportExpr name paramsE) = "PartialImportExpr " <> show name <> " (" <> show paramsE <> ")"
  show (FieldAccess baseE segs) = "FieldAccess (" <> show baseE <> ") " <> show segs
  show (RemapActionsExpr nodeE keySpec fnE) = "RemapActionsExpr (" <> show nodeE <> ") (" <> show keySpec <> ") (" <> show fnE <> ")"

-- | One piece of a double-quoted string literal: either literal text or a
-- | backtick-delimited interpolation of an arbitrary `Expr` (not just a
-- | bare path — `` `$cardinality($nums)` `` is a valid interpolation),
-- | e.g. `"there are `$count` item(s)"` parses to `[ Lit "there are ",
-- | Interp (Path [ "count" ]), Lit " item(s)" ]`.
data StringPart
  = Lit String
  | Interp Expr

derive instance eqStringPart :: Eq StringPart

instance showStringPart :: Show StringPart where
  show (Lit s) = "Lit " <> show s
  show (Interp e) = "Interp (" <> show e <> ")"

-- | `action(eventType, keyExpr, payloadExpr)` — appears directly among a
-- | node's arguments (`.button("Select", action("on-click", "select",
-- | {"itemId": $itemId}))`), not nested under an `action:` attribute
-- | key the way the original opaque-string design worked. All three
-- | positions are ordinary `expr`s, each evaluated to a `Json` value at
-- | eval time (`eventType`/`key` are required to reduce to a string,
-- | `payload` can be anything) — see `ActionPayload`. `eventType` used to
-- | be a bare identifier from a fixed keyword set, but the tramaj
-- | language isn't Halogen-only (a future email/static-site renderer has
-- | no DOM events at all), so it needs to be able to name whatever
-- | event/hook concept a given host defines, possibly even computed
-- | (`$ctx.eventName`) rather than a static literal — a bare-identifier
-- | keyword can't express that. `Tramaj.Eval` does not validate it
-- | against a fixed set either: it requires a string and passes whatever
-- | that string says to the host untouched, so naming the vocabulary is
-- | entirely a host concern.
data TAction = TAction Expr Expr Expr

derive instance eqTAction :: Eq TAction

instance showTAction :: Show TAction where
  show (TAction eventTypeExpr keyExpr payloadExpr) =
    "TAction (" <> show eventTypeExpr <> ") (" <> show keyExpr <> ") (" <> show payloadExpr <> ")"

-- | The evaluated result of a `TAction` — what a `Node`'s `action` field
-- | holds, and what the host's dispatcher function
-- | (`Tramaj.Halogen.foldToHalogen`) receives. Structured, not an
-- | opaque string: the host can pattern-match `key` and use `payload`
-- | directly, no string-parsing required on its side.
type ActionPayload =
  { eventType :: String
  , key :: String
  , payload :: Json
  }

-- | Unevaluated template-phase AST — still holds `Expr`/paths, not
-- | resolved values.
-- |
-- | A node's parenthesized argument list is heterogeneous in the surface
-- | syntax (`.button("Select", action("on-click", "select", {...}))`
-- | mixes a positional value and an `action(...)` form in one list) but
-- | splits cleanly into three roles: named `key: value` args become HTML
-- | attributes (`attrs`, a plain `Tuple String Expr` — one constructor's
-- | worth of ceremony wasn't worth a dedicated sum type once positional
-- | args turned out to be children, not attrs); at most one
-- | `action(...)` becomes `TElement`'s `Maybe TAction`; everything else
-- | in the list — a bare value (`TValue`), a nested node, `map(...)`, or
-- | `branch(...)` — becomes a child, in argument order.
-- |
-- | `TMap`'s array is a general `Expr` (not just a static path) — the
-- | functional `map(arrExpr, (item) => body)` surface syntax makes this
-- | natural: `arrExpr` can be any expression that evaluates to a `Json`
-- | array (a nested `filter(...)`, a `lookup(...)` call, a plain path,
-- | ...), not only a bare `$ctx.items`-style path like the older
-- | `$ctx.items.map(...)` OOP-style syntax required.
-- |
-- | `TBranch fallback pairs` mirrors the expr-level `branch` builtin
-- | (`specs/templating-language.md`) but selects a whole *node*, not a
-- | value — `branch(fallbackNode, pred1, node1, pred2, node2, ...)`.
-- | Unlike the expr-level `branch` (whose arguments are all eagerly
-- | evaluated `Json` values before dispatch, so every branch must be
-- | error-free regardless of which one wins), only the *chosen*
-- | `TemplateNode` is ever evaluated here — the others are plain
-- | unevaluated AST until `pickBranch` decides, so an unreachable
-- | branch's own errors never surface.
data TemplateNode
  = TElement String (Array (Tuple String Expr)) (Maybe TAction) (Array TemplateNode)
  | TValue Expr
  | TMap Expr String TemplateNode
  | TBranch TemplateNode (Array (Tuple Expr TemplateNode))

derive instance eqTemplateNode :: Eq TemplateNode

instance showTemplateNode :: Show TemplateNode where
  show (TElement tag attrs action children) =
    "TElement " <> show tag <> " " <> show attrs <> " " <> show action <> " " <> show children
  show (TValue e) = "TValue " <> show e
  show (TMap arr binding body) =
    "TMap (" <> show arr <> ") " <> show binding <> " (" <> show body <> ")"
  show (TBranch fallback pairs) =
    "TBranch (" <> show fallback <> ") " <> show pairs

-- | Evaluated output — no `Expr`/paths left, and no Halogen dependency.
-- | `NElement`'s `action`, when present, is the structured
-- | `ActionPayload` the host's dispatcher (`ActionPayload -> Maybe
-- | action`) interprets — `Tramaj.Eval`/`Tramaj.Parser` never
-- | interpret its `eventType`/`key`/`payload` contents themselves, only
-- | require that the first two reduce to strings.
data Node
  = NElement
      { tag :: String
      , attrs :: Map String String
      , action :: Maybe ActionPayload
      , children :: Array Node
      }
  | NText String

derive instance eqNode :: Eq Node

instance showNode :: Show Node where
  show (NElement r) =
    "NElement { tag: " <> show r.tag
      <> ", attrs: "
      <> show r.attrs
      <> ", action: "
      <> showAction r.action
      <> ", children: "
      <> show r.children
      <> " }"
  show (NText s) = "NText " <> show s

-- | `Json` has no `Show` instance (`argonaut-core` only derives `Eq`),
-- | so `ActionPayload`'s `payload` field can't ride along on a derived
-- | `Show` — `stringify` it explicitly instead.
showAction :: Maybe ActionPayload -> String
showAction Nothing = "Nothing"
showAction (Just a) =
  "Just { eventType: " <> show a.eventType
    <> ", key: "
    <> show a.key
    <> ", payload: "
    <> stringify a.payload
    <> " }"

-- | A parsed program: computation-block bindings evaluated once in
-- | declaration order (each may reference earlier ones, not later ones),
-- | plus the single template-block root node.
type Program =
  { bindings :: Array (Tuple String Expr)
  , root :: TemplateNode
  }

-- | A parsed program whose root is an ordinary `Expr` rather than a
-- | `TemplateNode` -- same computation block, same expression language, but
-- | it evaluates to a `Json` value instead of a document tree (see
-- | `Tramaj.Eval.evalJsonProgram`). For a host that wants the data half
-- | of the language on its own: generating a JSON payload, not a document.
-- | Ported from the Haskell-only `Tramaj.Ast.JsonProgram`.
type JsonProgram =
  { bindings :: Array (Tuple String Expr)
  , root :: Expr
  }

-- | Renders the evaluated `Node` tree as plain `Json` — a debugging/
-- | inspection aid (`tramaj-cli` prints exactly this, and a host can
-- | show it next to the rendered output), not a wire format this package
-- | reads back in anywhere. The Haskell port's `Tramaj.Ast.nodeToJson`
-- | emits the same shape.
nodeToJson :: Node -> Json
nodeToJson (NText s) =
  fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString s) ])
nodeToJson (NElement r) =
  fromObject
    ( Object.fromFoldable
        [ Tuple "type" (fromString "element")
        , Tuple "tag" (fromString r.tag)
        , Tuple "attrs" (fromObject (Object.fromFoldable (map (\(Tuple k v) -> Tuple k (fromString v)) (Map.toUnfoldable r.attrs :: Array (Tuple String String)))))
        , Tuple "action" (maybe jsonNull actionPayloadToJson r.action)
        , Tuple "children" (fromArray (map nodeToJson r.children))
        ]
    )

-- | The `{eventType, key, payload}` shape an `ActionPayload` takes as
-- | `Json` — used both by `nodeToJson` above (debug/inspection output) and
-- | by `Tramaj.Eval`'s `remap-actions` (where a template-level closure
-- | receives/returns exactly this shape to rewrite an imported node's
-- | actions before they bubble up). One definition, so both stay in sync.
actionPayloadToJson :: ActionPayload -> Json
actionPayloadToJson a =
  fromObject
    ( Object.fromFoldable
        [ Tuple "eventType" (fromString a.eventType)
        , Tuple "key" (fromString a.key)
        , Tuple "payload" a.payload
        ]
    )

-- | Every `import`/`partial-import` name statically referenced anywhere in
-- | a parsed program — the computation-block bindings and the
-- | template-block root, recursively through every nested `Expr`/
-- | `TemplateNode` — without evaluating anything. Exhaustive because the
-- | name position of `ImportExpr`/`PartialImportExpr` is a bare `String` in
-- | the AST, never a computed `Expr`: a template's whole set of library
-- | dependencies is knowable up front, matching `specs/position.md` §1/§9.
staticImportNames :: Program -> Set String
staticImportNames program =
  foldMap (importNamesInExpr <<< snd) program.bindings
    <> importNamesInNode program.root

importNamesInExpr :: Expr -> Set String
importNamesInExpr (Path _) = Set.empty
importNamesInExpr (Call _ args) = foldMap importNamesInExpr args
importNamesInExpr (StringLit parts) = foldMap importNamesInStringPart parts
importNamesInExpr (NumberLit _) = Set.empty
importNamesInExpr (BoolLit _) = Set.empty
importNamesInExpr (ArrayLit elems) = foldMap importNamesInExpr elems
importNamesInExpr (ObjectLit entries) = foldMap (importNamesInExpr <<< snd) entries
importNamesInExpr (LambdaExpr _ body) = importNamesInExpr body
importNamesInExpr (MapExpr arr fn) = importNamesInExpr arr <> importNamesInExpr fn
importNamesInExpr (FilterExpr arr fn) = importNamesInExpr arr <> importNamesInExpr fn
importNamesInExpr (ScanExpr arr initE fn) = importNamesInExpr arr <> importNamesInExpr initE <> importNamesInExpr fn
importNamesInExpr (FoldExpr arr initE fn) = importNamesInExpr arr <> importNamesInExpr initE <> importNamesInExpr fn
importNamesInExpr (ImportExpr name paramsE) = Set.insert name (importNamesInExpr paramsE)
importNamesInExpr (PartialImportExpr name paramsE) = Set.insert name (importNamesInExpr paramsE)
importNamesInExpr (FieldAccess baseE _) = importNamesInExpr baseE
importNamesInExpr (RemapActionsExpr nodeE keySpec fnE) = importNamesInExpr nodeE <> importNamesInKeySpec keySpec <> importNamesInExpr fnE

importNamesInKeySpec :: KeySpec -> Set String
importNamesInKeySpec (KeyPrefix e) = importNamesInExpr e

importNamesInStringPart :: StringPart -> Set String
importNamesInStringPart (Lit _) = Set.empty
importNamesInStringPart (Interp e) = importNamesInExpr e

importNamesInNode :: TemplateNode -> Set String
importNamesInNode (TElement _ attrs action children) =
  foldMap (importNamesInExpr <<< snd) attrs
    <> foldMap importNamesInTAction action
    <> foldMap importNamesInNode children
importNamesInNode (TValue e) = importNamesInExpr e
importNamesInNode (TMap arr _ body) = importNamesInExpr arr <> importNamesInNode body
importNamesInNode (TBranch fallback pairs) =
  importNamesInNode fallback
    <> foldMap (\(Tuple predE node) -> importNamesInExpr predE <> importNamesInNode node) pairs

importNamesInTAction :: TAction -> Set String
importNamesInTAction (TAction eventTypeExpr keyExpr payloadExpr) =
  importNamesInExpr eventTypeExpr <> importNamesInExpr keyExpr <> importNamesInExpr payloadExpr
