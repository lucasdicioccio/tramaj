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
  , Stmt(..)
  , programRoot
  , stmts
  , unlets
  , letBindings
  , adaptKey
  , subExprs
  , attributeExprs
  , numberAllocs
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
  | -- | `constraint(name, arg1, arg2, ...)` (v3-symbols §2.1): a static
    -- | string name, like an action's event and key, plus any number of
    -- | ordinary expressions. Unbounded arity is the point — a global
    -- | constraint over a whole collection is exactly as expressible as a
    -- | binary comparison.
    Constrain String (Array Expr)
  | -- | `!expr` (v3-symbols §2.2, §3): a statement, not a value-producing
    -- | form. Nests into the same chain `Let` does, which is what lets
    -- | "earlier bindings only" fall out of ordinary lexical scoping rather
    -- | than needing separate statement machinery. Evaluating it collects
    -- | from the constraint expression's value by the same coercion table
    -- | `Element` children already use, then continues into the body.
    Emit Expr Expr
  | -- | `?(key)` (v3-symbols §1.2): allocates a symbol. `key` is an ordinary
    -- | expression, evaluated where it is written. The `Int` is the site:
    -- | the n-th `?(...)` in the program's source, in source order — part
    -- | of the symbol's identity (§1.4), so it belongs to the core AST
    -- | rather than being derived some other way. Assigned by
    -- | `numberAllocs` after parsing, not by the parser itself, so that
    -- | agreement between implementations rests on one small pure function
    -- | over the AST rather than on two parsers' internal traversal order.
    Alloc Int Expr
  | -- | `?ctx.a.b` (§1.3): declares a context read symbolic. The path MUST
    -- | be rooted at `ctx`, which is why it is not just a `Path` — unlike
    -- | an ordinary read, an unsupplied demand at the root allocates
    -- | instead of failing.
    Demand (Array String)

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
  show (Constrain name args) = "Constrain " <> show name <> " " <> show args
  show (Emit constraint body) = "Emit (" <> show constraint <> ") (" <> show body <> ")"
  show (Alloc site key) = "Alloc " <> show site <> " (" <> show key <> ")"
  show (Demand path) = "Demand " <> show path

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

-- | One statement of the surface program grammar (v3-symbols §2.2), after
-- | lowering: a binding or an emission. Both nest into the same
-- | `Let`/`Emit` chain; this is only `unlets`' view of it.
data Stmt
  = SLet String Expr
  | SEmit Expr

derive instance eqStmt :: Eq Stmt

instance showStmt :: Show Stmt where
  show (SLet name value) = "SLet " <> show name <> " (" <> show value <> ")"
  show (SEmit e) = "SEmit (" <> show e <> ")"

-- | Nests a sequence of statements around a body, innermost last — the
-- | lowering the surface `statement* expr` program grammar uses
-- | (v3-symbols §2.2): a binding becomes a `Let`, an emission an `Emit`,
-- | each wrapping everything that follows it.
stmts :: Array Stmt -> Expr -> Expr
stmts statements body = Array.foldr wrap body statements
  where
  wrap (SLet name value) acc = Let name value acc
  wrap (SEmit constraint) acc = Emit constraint acc

-- | Peels the outermost `Let`/`Emit` chain back off, inverting `stmts`.
-- |
-- | Nothing but a program's surface statement block can put a `Let` or
-- | `Emit` outermost, so this recovers exactly that block, in order.
-- | Keeping statements as ordinary nested constructors in the AST, and
-- | recovering the block when it is needed, avoids a second binding
-- | construct whose scoping would have to be specified separately.
-- |
-- | Stopping at the first `Let` alone — as this once did, before `Emit`
-- | existed — silently truncates a binding block that has a `!` statement
-- | threaded through it: `@a=1; !c; @b=2; root` would report only `a`.
-- | `runLibrary` is the caller this matters to, since it is what exposes
-- | `.vals` and is also the one place a library's own emissions must be
-- | evaluated.
unlets :: Expr -> { statements :: Array Stmt, root :: Expr }
unlets (Let name value body) =
  let
    rest = unlets body
  in
    { statements: Array.cons (SLet name value) rest.statements, root: rest.root }
unlets (Emit constraint body) =
  let
    rest = unlets body
  in
    { statements: Array.cons (SEmit constraint) rest.statements, root: rest.root }
unlets e = { statements: [], root: e }

-- | Just the named bindings of a statement block, in order — what an
-- | import exposes as `.vals`. Discards emissions positionally; a caller
-- | that must also evaluate them (running a library) should fold over
-- | `unlets`' full result instead.
letBindings :: Array Stmt -> Array (Tuple String Expr)
letBindings = Array.mapMaybe case _ of
  SLet n e -> Just (Tuple n e)
  SEmit _ -> Nothing

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
subExprs (Constrain _ args) = args
subExprs (Emit constraint body) = [ constraint, body ]
subExprs (Alloc _ key) = [ key ]
subExprs (Demand _) = []

-- | The computed expressions in a list of attributes — an ordinary
-- | attribute's value or an action's payload. An action's event and key
-- | are static text, so they are not expressions to walk into.
attributeExprs :: Array Attribute -> Array Expr
attributeExprs = map case _ of
  Attr _ e -> e
  ActionAttr _ _ e -> e

-- | Assigns each `Alloc` in a program the index of its `?(...)` among all
-- | of them, in source order (v3-symbols §1.4) — a plain pre-order,
-- | left-to-right walk over the freshly parsed tree, numbering as it goes.
-- |
-- | Done as a rewrite after parsing, rather than by a counter threaded
-- | through the parser itself, so that two independently written parsers
-- | agree on site numbers by construction: both run this same function
-- | over what they parsed, rather than having to agree on a
-- | parser-internal traversal order. It relies on one property of every
-- | constructor below: each rebuilds a node from the *same* immediate
-- | subexpressions `subExprs` would report, in the same order, which is
-- | what makes a left-to-right pre-order walk here land on exactly "the
-- | n-th `?` in the source" for every shape the grammar produces —
-- | attributes before value before children in an `Element`, condition
-- | before either arm in a `Branch`, and so on.
numberAllocs :: Expr -> Expr
numberAllocs e = (go 0 e).expr
  where
  go :: Int -> Expr -> { next :: Int, expr :: Expr }
  go n (Alloc _ key) =
    let r = go (n + 1) key in { next: r.next, expr: Alloc n r.expr }
  go n e'@(Path _ _) = { next: n, expr: e' }
  go n (FieldAccess target fields) =
    let r = go n target in { next: r.next, expr: FieldAccess r.expr fields }
  go n (Call fn args) =
    let r1 = go n fn
        r2 = goArray r1.next args
    in { next: r2.next, expr: Call r1.expr r2.arr }
  go n (Lambda params body) = let r = go n body in { next: r.next, expr: Lambda params r.expr }
  go n (Let name value body) =
    let r1 = go n value
        r2 = go r1.next body
    in { next: r2.next, expr: Let name r1.expr r2.expr }
  go n e'@(StringLit _) = { next: n, expr: e' }
  go n e'@(NumberLit _) = { next: n, expr: e' }
  go n e'@(BoolLit _) = { next: n, expr: e' }
  go n NullLit = { next: n, expr: NullLit }
  go n (ArrayLit elems) = let r = goArray n elems in { next: r.next, expr: ArrayLit r.arr }
  go n (ObjectLit entries) = let r = goPairs n entries in { next: r.next, expr: ObjectLit r.arr }
  go n (Element tag attrs val children) =
    let r1 = goAttrs n attrs
        r2 = go r1.next val
        r3 = goArray r2.next children
    in { next: r3.next, expr: Element tag r1.arr r2.expr r3.arr }
  go n (Fragment children) = let r = goArray n children in { next: r.next, expr: Fragment r.arr }
  go n (Branch c t e') =
    let r1 = go n c
        r2 = go r1.next t
        r3 = go r2.next e'
    in { next: r3.next, expr: Branch r1.expr r2.expr r3.expr }
  go n (Map coll fn) =
    let r1 = go n coll
        r2 = go r1.next fn
    in { next: r2.next, expr: Map r1.expr r2.expr }
  go n (Filter coll fn) =
    let r1 = go n coll
        r2 = go r1.next fn
    in { next: r2.next, expr: Filter r1.expr r2.expr }
  go n (Scan coll initial fn) =
    let r1 = go n coll
        r2 = go r1.next initial
        r3 = go r2.next fn
    in { next: r3.next, expr: Scan r1.expr r2.expr r3.expr }
  go n (Fold coll initial fn) =
    let r1 = go n coll
        r2 = go r1.next initial
        r3 = go r2.next fn
    in { next: r3.next, expr: Fold r1.expr r2.expr r3.expr }
  go n (Concat l r) =
    let r1 = go n l
        r2 = go r1.next r
    in { next: r2.next, expr: Concat r1.expr r2.expr }
  go n (Import name params) = let r = goParams n params in { next: r.next, expr: Import name r.arr }
  go n (AdaptActions target adaptation fn) =
    let r1 = go n target
    in case fn of
      Nothing -> { next: r1.next, expr: AdaptActions r1.expr adaptation Nothing }
      Just f ->
        let r2 = go r1.next f
        in { next: r2.next, expr: AdaptActions r1.expr adaptation (Just r2.expr) }
  go n (Constrain name args) = let r = goArray n args in { next: r.next, expr: Constrain name r.arr }
  go n (Emit constraint body) =
    let r1 = go n constraint
        r2 = go r1.next body
    in { next: r2.next, expr: Emit r1.expr r2.expr }
  go n e'@(Demand _) = { next: n, expr: e' }

  goArray :: Int -> Array Expr -> { next :: Int, arr :: Array Expr }
  goArray n xs = case Array.uncons xs of
    Nothing -> { next: n, arr: [] }
    Just { head, tail } ->
      let r1 = go n head
          r2 = goArray r1.next tail
      in { next: r2.next, arr: Array.cons r1.expr r2.arr }

  goPairs :: Int -> Array (Tuple String Expr) -> { next :: Int, arr :: Array (Tuple String Expr) }
  goPairs n xs = case Array.uncons xs of
    Nothing -> { next: n, arr: [] }
    Just { head: Tuple k x, tail } ->
      let r1 = go n x
          r2 = goPairs r1.next tail
      in { next: r2.next, arr: Array.cons (Tuple k r1.expr) r2.arr }

  goAttrs :: Int -> Array Attribute -> { next :: Int, arr :: Array Attribute }
  goAttrs n xs = case Array.uncons xs of
    Nothing -> { next: n, arr: [] }
    Just { head: Attr name x, tail } ->
      let r1 = go n x
          r2 = goAttrs r1.next tail
      in { next: r2.next, arr: Array.cons (Attr name r1.expr) r2.arr }
    Just { head: ActionAttr ev key x, tail } ->
      let r1 = go n x
          r2 = goAttrs r1.next tail
      in { next: r2.next, arr: Array.cons (ActionAttr ev key r1.expr) r2.arr }

  goParams :: Int -> Array (Tuple String ParamValue) -> { next :: Int, arr :: Array (Tuple String ParamValue) }
  goParams n xs = case Array.uncons xs of
    Nothing -> { next: n, arr: [] }
    Just { head: Tuple k (PExpr x), tail } ->
      let r1 = go n x
          r2 = goParams r1.next tail
      in { next: r2.next, arr: Array.cons (Tuple k (PExpr r1.expr)) r2.arr }
    Just { head: p@(Tuple _ (PFromContext _)), tail } ->
      let r1 = goParams n tail
      in { next: r1.next, arr: Array.cons p r1.arr }
