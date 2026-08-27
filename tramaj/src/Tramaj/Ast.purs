-- | The core semantic AST: what a Tramaj program means, after the parser
-- | has desugared everything the surface syntax offers on top of it.
-- |
-- | This is a *semantic* representation, not a parser representation: no
-- | source locations, no comments, no formatting, no recovery nodes.
-- | Surface conveniences — string interpolation, object shorthand,
-- | `@name=expr` binding lines, the multi-armed `branch(...)` form — have
-- | no constructors here; `Tramaj.Parser` lowers them into the
-- | constructors below.
-- |
-- | The defining change from v1: **documents are expressions**. `Element`
-- | and `Fragment` are ordinary `Expr` constructors, so a document node is
-- | a value that can be bound, passed to a lambda, returned from one, or
-- | stored in an array like any other. v1's separate template-phase AST —
-- | and with it the duplicated template-phase `map`/`branch`/value forms —
-- | is gone.
-- |
-- | Where an invalid program can be made unrepresentable, it is: an import
-- | name, an action's event and key, and an action adaptation's prefix are
-- | all `String` rather than `Expr`, because the language's
-- | static-analysis guarantees (see `Tramaj.Analysis`) depend on them
-- | being knowable without evaluating anything.
-- |
-- | See `specs/reference.md` for the language and `specs/decisions.md` for
-- | which reading of the (now archived) design drafts won where they
-- | disagreed. Kept in lockstep with `../tramaj-hs/src/Tramaj/Ast.hs`.
module Tramaj.Ast
  ( Program(..)
  , Expr(..)
  , Attribute(..)
  , ParamValue(..)
  , ActionAdaptation(..)
  , programRoot
  , lets
  , unlets
  , adaptKey
  , subExprs
  , attributeExprs
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..), snd)

-- | A whole program, distinguished by what its root produces rather than
-- | by what it may contain — both halves share one expression language.
-- |
-- | A `DocumentProgram` evaluates to a `Tramaj.Node` document; an
-- | `ExpressionProgram` evaluates to an ordinary JSON value, for hosts
-- | that want the data half of the language on its own. The parser tells
-- | them apart syntactically: a root beginning with `.` is a document.
data Program
  = DocumentProgram Expr
  | ExpressionProgram Expr

derive instance eqProgram :: Eq Program

instance showProgram :: Show Program where
  show (DocumentProgram e) = "DocumentProgram (" <> show e <> ")"
  show (ExpressionProgram e) = "ExpressionProgram (" <> show e <> ")"

programRoot :: Program -> Expr
programRoot (DocumentProgram e) = e
programRoot (ExpressionProgram e) = e

-- | `Path root fields` — a name in the environment plus static field
-- | segments: `$ctx.user.name` is `Path "ctx" [ "user", "name" ]`. Dynamic
-- | access goes through the `lookup` builtin instead.
-- |
-- | `FieldAccess` is field access on an arbitrary expression, which `Path`
-- | cannot express because its root must be a name:
-- | `import("x", {}).vals.button`.
-- |
-- | `Call`'s function is an `Expr`, not a name, because builtins are
-- | ordinary values in the initial environment — so `cardinality($xs)`,
-- | `$f($x)` and `map($xs, $not)` all travel the same path.
-- |
-- | `Lambda` closes over the environment where it is evaluated. Multiple
-- | parameters, since `fold`/`scan` need `(acc, item)` and the language
-- | has no currying. **No recursion**: a binding's value is not in scope
-- | while that value is being evaluated.
-- |
-- | `Let` is one lexical binding. The surface `@name=expr` block lowers to
-- | nested `Let`s, which is why a binding may reference earlier ones but
-- | not later ones.
-- |
-- | `Element tag attributes value children` — the value slot is `NullLit`
-- | unless the template sets one; see `Tramaj.Node` for what it is for.
-- | `Fragment` is sibling nodes with no wrapper element — the
-- | JSX-children case, expressible as an ordinary value because documents
-- | are expressions.
-- |
-- | `Branch` evaluates its condition, then *only* the arm it selects. This
-- | is the one place the language departs from evaluating arguments
-- | eagerly, and it is why `Branch` is a constructor rather than a
-- | builtin: errors in an unreached arm must not surface. The surface's
-- | multi-armed `branch(fallback, p1, v1, ...)` lowers to nested `Branch`.
-- |
-- | `Concat` is the monoid operation `a <> b` over `String`, `Array` or
-- | `Object` — same type on both sides, right-biased on object key
-- | collisions.
-- |
-- | `Import name parameters` is a statically named dependency and the
-- | parameters supplied to it *here* — not necessarily all of them. An
-- | import that omits a parameter its library reads is saturated later, by
-- | calling the import value with more parameters; there is deliberately
-- | no partial-import constructor, because partiality is not a property of
-- | the syntax at all, only of which names have arrived by the time the
-- | library runs.
-- |
-- | `AdaptActions target adaptation fn` prefixes every action key in a
-- | document subtree, with an optional closure for the event type and
-- | payload. The prefix is static so the action vocabulary stays
-- | enumerable without evaluation.
data Expr
  = Path String (Array String)
  | FieldAccess Expr (Array String)
  | Call Expr (Array Expr)
  | Lambda (Array String) Expr
  | Let String Expr Expr
  | StringLit String
  | NumberLit Number
  | BoolLit Boolean
  | NullLit
  | ArrayLit (Array Expr)
  | ObjectLit (Array (Tuple String Expr))
  | Element String (Array Attribute) Expr (Array Expr)
  | Fragment (Array Expr)
  | Branch Expr Expr Expr
  | Map Expr Expr
  | Filter Expr Expr
  | Scan Expr Expr Expr
  | Fold Expr Expr Expr
  | Concat Expr Expr
  | Import String (Array (Tuple String ParamValue))
  | AdaptActions Expr ActionAdaptation (Maybe Expr)

derive instance eqExpr :: Eq Expr

instance showExpr :: Show Expr where
  show (Path root fields) = "Path " <> show root <> " " <> show fields
  show (FieldAccess target fields) = "FieldAccess (" <> show target <> ") " <> show fields
  show (Call fn args) = "Call (" <> show fn <> ") " <> show args
  show (Lambda params body) = "Lambda " <> show params <> " (" <> show body <> ")"
  show (Let name value body) = "Let " <> show name <> " (" <> show value <> ") (" <> show body <> ")"
  show (StringLit s) = "StringLit " <> show s
  show (NumberLit n) = "NumberLit " <> show n
  show (BoolLit b) = "BoolLit " <> show b
  show NullLit = "NullLit"
  show (ArrayLit elems) = "ArrayLit " <> show elems
  show (ObjectLit entries) = "ObjectLit " <> show entries
  show (Element tag attrs value children) =
    "Element " <> show tag <> " " <> show attrs <> " (" <> show value <> ") " <> show children
  show (Fragment children) = "Fragment " <> show children
  show (Branch c t e) = "Branch (" <> show c <> ") (" <> show t <> ") (" <> show e <> ")"
  show (Map coll fn) = "Map (" <> show coll <> ") (" <> show fn <> ")"
  show (Filter coll fn) = "Filter (" <> show coll <> ") (" <> show fn <> ")"
  show (Scan coll initial fn) = "Scan (" <> show coll <> ") (" <> show initial <> ") (" <> show fn <> ")"
  show (Fold coll initial fn) = "Fold (" <> show coll <> ") (" <> show initial <> ") (" <> show fn <> ")"
  show (Concat l r) = "Concat (" <> show l <> ") (" <> show r <> ")"
  show (Import name params) = "Import " <> show name <> " " <> show params
  show (AdaptActions target adaptation fn) =
    "AdaptActions (" <> show target <> ") (" <> show adaptation <> ") " <> show fn

-- | How one import parameter gets its value. There are three ways to
-- | supply one and only two of them are here — the third is leaving it
-- | out (see `Import`).
-- |
-- | `PExpr` is any expression, evaluated where the import is written.
-- |
-- | `PFromContext path` is `ctx(spec.replicas)`: the value comes from the
-- | *importing* program's own context, read where the import is written.
-- | It means what `$ctx.spec.replicas` means and evaluates identically —
-- | the point of the separate node is entirely static. A path sitting in
-- | the AST is a hole `Tramaj.Analysis` can enumerate directly, whereas
-- | the same read spelled `$ctx.spec.replicas` is an ordinary `Path`
-- | buried in an arbitrary expression, indistinguishable from every other
-- | read. Writing `ctx(...)` is how an author says "this is a hole, count
-- | it".
data ParamValue
  = PExpr Expr
  | PFromContext (Array String)

derive instance eqParamValue :: Eq ParamValue

instance showParamValue :: Show ParamValue where
  show (PExpr e) = "PExpr (" <> show e <> ")"
  show (PFromContext path) = "PFromContext " <> show path

-- | Both attribute-position constructs. An action's event and key are
-- | `String`, not `Expr`: the payload stays fully dynamic, but the
-- | identifying half is static, which is what makes the set of actions a
-- | program can emit computable ahead of time.
data Attribute
  = Attr String Expr
  | ActionAttr String String Expr

derive instance eqAttribute :: Eq Attribute

instance showAttribute :: Show Attribute where
  show (Attr name e) = "Attr " <> show name <> " (" <> show e <> ")"
  show (ActionAttr event key payload) =
    "ActionAttr " <> show event <> " " <> show key <> " (" <> show payload <> ")"

-- | Restricted on purpose to two forms rather than an arbitrary
-- | key-rewriting function. Adaptations compose the obvious way: prefixing
-- | `a:` and then `b:` gives `b:a:key`, needing no "already adapted"
-- | state.
data ActionAdaptation
  = Identity
  | Prefix String

derive instance eqActionAdaptation :: Eq ActionAdaptation

instance showActionAdaptation :: Show ActionAdaptation where
  show Identity = "Identity"
  show (Prefix p) = "Prefix " <> show p

-- | Nests a sequence of bindings around a body, innermost last — the
-- | lowering the surface `@name=expr` block uses.
lets :: Array (Tuple String Expr) -> Expr -> Expr
lets bindings body = Array.foldr (\(Tuple name value) acc -> Let name value acc) body bindings

-- | Peels the outermost `Let` chain back off, inverting `lets`.
-- |
-- | Nothing but a program's surface binding block can put a `Let`
-- | outermost, so this recovers exactly the top-level bindings that block
-- | declared — which is what an import exposes as `.vals`. Keeping
-- | bindings as ordinary nested `Let`s in the AST, and recovering the
-- | block when it is needed, avoids a second binding construct whose
-- | scoping would have to be specified separately.
unlets :: Expr -> { bindings :: Array (Tuple String Expr), root :: Expr }
unlets (Let name value body) =
  let
    rest = unlets body
  in
    { bindings: Array.cons (Tuple name value) rest.bindings, root: rest.root }
unlets e = { bindings: [], root: e }

-- | How an adaptation rewrites one action key. Shared by evaluation and by
-- | static analysis, which is the point of restricting adaptation to these
-- | two forms: the analysis can apply the very same function the evaluator
-- | will, without evaluating anything.
adaptKey :: ActionAdaptation -> String -> String
adaptKey Identity key = key
adaptKey (Prefix p) key = p <> key

-- | The immediately-contained expressions of an expression, in source
-- | order.
-- |
-- | Written once here so that the analyses in `Tramaj.Analysis` are a few
-- | lines each rather than a 20-case fold apiece — and, more importantly,
-- | so that adding a constructor to `Expr` has exactly one place to be
-- | taught about instead of one per traversal.
subExprs :: Expr -> Array Expr
subExprs (Path _ _) = []
subExprs (FieldAccess target _) = [ target ]
subExprs (Call fn args) = Array.cons fn args
subExprs (Lambda _ body) = [ body ]
subExprs (Let _ value body) = [ value, body ]
subExprs (StringLit _) = []
subExprs (NumberLit _) = []
subExprs (BoolLit _) = []
subExprs NullLit = []
subExprs (ArrayLit elems) = elems
subExprs (ObjectLit entries) = map snd entries
subExprs (Element _ attrs value children) = attributeExprs attrs <> Array.cons value children
subExprs (Fragment children) = children
subExprs (Branch c t e) = [ c, t, e ]
subExprs (Map coll fn) = [ coll, fn ]
subExprs (Filter coll fn) = [ coll, fn ]
subExprs (Scan coll initial fn) = [ coll, initial, fn ]
subExprs (Fold coll initial fn) = [ coll, initial, fn ]
subExprs (Concat l r) = [ l, r ]
subExprs (Import _ params) = Array.mapMaybe paramExpr params
  where
  paramExpr (Tuple _ (PExpr e)) = Just e
  paramExpr _ = Nothing
subExprs (AdaptActions target _ fn) = case fn of
  Nothing -> [ target ]
  Just f -> [ target, f ]

-- | The computed expressions in a list of attributes — an ordinary
-- | attribute's value or an action's payload. An action's event and key
-- | are static text, so they are not expressions to walk into.
attributeExprs :: Array Attribute -> Array Expr
attributeExprs = map case _ of
  Attr _ e -> e
  ActionAttr _ _ e -> e
