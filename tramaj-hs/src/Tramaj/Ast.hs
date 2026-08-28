-- | The core semantic AST: what a Tramaj program means, after the parser has
-- desugared everything the surface syntax offers on top of it.
--
-- This is a /semantic/ representation, not a parser representation: no source
-- locations, no comments, no formatting, no recovery nodes. Surface
-- conveniences -- string interpolation, object shorthand, @\@name=expr@
-- binding lines, the multi-armed @branch(...)@ form -- have no constructors
-- here; "Tramaj.Parser" lowers them into the constructors below.
--
-- The defining change from v1: **documents are expressions**. 'Element' and
-- 'Fragment' are ordinary 'Expr' constructors, so a document node is a value
-- that can be bound, passed to a lambda, returned from one, or stored in an
-- array like any other. v1's separate template-phase AST -- and with it the
-- duplicated template-phase @map@\/@branch@\/value forms -- is gone.
--
-- Where an invalid program can be made unrepresentable, it is: an import
-- name, an action's event and key, and an action adaptation's prefix are all
-- 'Text' rather than 'Expr', because the language's static-analysis
-- guarantees (see "Tramaj.Analysis") depend on them being knowable without
-- evaluating anything.
--
-- See @../specs/reference.md@ for the language, and @../specs/decisions.md@
-- for which reading of the (now archived) design drafts won where they
-- disagreed.
module Tramaj.Ast
  ( Program (..)
  , Expr (..)
  , Attribute (..)
  , ParamValue (..)
  , ActionAdaptation (..)
  , Stmt (..)
  , programRoot
  , stmts
  , unlets
  , letBindings
  , adaptKey
  , subExprs
  , attributeExprs
  , numberAllocs
  ) where

import Data.Text (Text)

-- | A whole program, distinguished by what its root produces rather than by
-- what it may contain -- both halves share one expression language.
--
-- A 'DocumentProgram' evaluates to a "Tramaj.Node" document; an
-- 'ExpressionProgram' evaluates to an ordinary JSON value, for hosts that
-- want the data half of the language on its own. The parser tells them apart
-- syntactically: a root beginning with @.@ is a document.
data Program
  = DocumentProgram Expr
  | ExpressionProgram Expr
  deriving stock (Eq, Show)

programRoot :: Program -> Expr
programRoot (DocumentProgram e) = e
programRoot (ExpressionProgram e) = e

data Expr
  = -- | A name in the environment plus static field segments: @$ctx.user.name@
    -- is @Path "ctx" ["user", "name"]@. Dynamic access goes through the
    -- @lookup@ builtin instead.
    Path Text [Text]
  | -- | Field access on an arbitrary expression, which a 'Path' cannot
    -- express because its root must be a name: @import("x", {}).vals.button@.
    FieldAccess Expr [Text]
  | -- | Application. The function is an 'Expr', not a name, because builtins
    -- are ordinary values in the initial environment -- so @cardinality($xs)@,
    -- @$f($x)@ and @map($xs, $not)@ all travel the same path.
    Call Expr [Expr]
  | -- | A closure over the environment where it is evaluated. Multiple
    -- parameters, since @fold@\/@scan@ need @(acc, item)@ and the language
    -- has no currying. There is no recursion: a binding's value is not in
    -- scope while that value is being evaluated.
    Lambda [Text] Expr
  | -- | One lexical binding. The surface @\@name=expr@ block lowers to nested
    -- 'Let's, which is why a binding may reference earlier ones but not later
    -- ones.
    Let Text Expr Expr
  | StringLit Text
  | NumberLit Double
  | BoolLit Bool
  | NullLit
  | ArrayLit [Expr]
  | ObjectLit [(Text, Expr)]
  | -- | A document element: tag, attributes (ordinary and action, in source
    -- order), a value slot, and children. The value slot is 'NullLit' unless
    -- the template sets one -- see "Tramaj.Node" for what it is for.
    Element Text [Attribute] Expr [Expr]
  | -- | Sibling nodes with no wrapper element -- the JSX-children case,
    -- expressible as an ordinary value because documents are expressions.
    Fragment [Expr]
  | -- | Evaluates its condition, then /only/ the arm it selects. This is the
    -- one place the language departs from evaluating arguments eagerly, and
    -- it is why 'Branch' is a constructor rather than a builtin: errors in an
    -- unreached arm must not surface. The surface's multi-armed
    -- @branch(fallback, p1, v1, ...)@ lowers to nested 'Branch'.
    Branch Expr Expr Expr
  | Map Expr Expr
  | Filter Expr Expr
  | Scan Expr Expr Expr
  | Fold Expr Expr Expr
  | -- | The monoid operation @a \<\> b@, over @String@, @Array@ or @Object@ --
    -- same type on both sides, right-biased on object key collisions.
    Concat Expr Expr
  | -- | A statically named dependency and the parameters supplied to it
    -- /here/ -- not necessarily all of them. An import that omits a parameter
    -- its library reads is saturated later, by calling the import value with
    -- more parameters; there is deliberately no partial-import constructor,
    -- because partiality is not a property of the syntax at all, only of
    -- which names have arrived by the time the library runs.
    Import Text [(Text, ParamValue)]
  | -- | Prefixes every action key in a document subtree, with an optional
    -- closure for the event type and payload. The prefix is static so the
    -- action vocabulary stays enumerable without evaluation.
    AdaptActions Expr ActionAdaptation (Maybe Expr)
  | -- | @constraint(name, arg1, arg2, ...)@ (v3-symbols \S2.1): a static string
    -- name, like an action's event and key, plus any number of ordinary
    -- expressions. Unbounded arity is the point -- a global constraint over a
    -- whole collection is exactly as expressible as a binary comparison.
    Constrain Text [Expr]
  | -- | @!expr@ (v3-symbols \S2.2, \S3): a statement, not a value-producing
    -- form. Nests into the same chain 'Let' does, which is what lets
    -- "earlier bindings only" fall out of ordinary lexical scoping rather
    -- than needing separate statement machinery. Evaluating it collects from
    -- the constraint expression's value by the same coercion table 'Element'
    -- children already use, then continues into the body.
    Emit Expr Expr
  | -- | @?(key)@ (v3-symbols \S1.2): allocates a symbol. @key@ is an ordinary
    -- expression, evaluated where it is written. The 'Int' is the site: the
    -- n-th @?(...)@ in the program's source, in source order -- part of the
    -- symbol's identity (\S1.4), so it belongs to the core AST rather than
    -- being derived some other way. Assigned by 'numberAllocs' after
    -- parsing, not by the parser itself, so that agreement between
    -- implementations rests on one small pure function over the AST rather
    -- than on two parsers' internal traversal order.
    Alloc Int Expr
  | -- | @?ctx.a.b@ (\S1.3): declares a context read symbolic. The path MUST
    -- be rooted at @ctx@, which is why it is not just a 'Path' -- unlike an
    -- ordinary read, an unsupplied demand at the root allocates instead of
    -- failing.
    Demand [Text]
  deriving stock (Eq, Show)

-- | How one import parameter gets its value. There are three ways to supply
-- one and only two of them are here -- the third is leaving it out (see
-- 'Import').
--
-- 'PExpr' is any expression, evaluated where the import is written.
--
-- @PFromContext path@ is @ctx(spec.replicas)@: the value comes from the
-- /importing/ program's own context, read where the import is written. It
-- means what @$ctx.spec.replicas@ means and evaluates identically -- the point
-- of the separate node is entirely static. A path sitting in the AST is a hole
-- "Tramaj.Analysis" can enumerate directly, whereas the same read spelled
-- @$ctx.spec.replicas@ is an ordinary 'Path' buried in an arbitrary
-- expression, indistinguishable from every other read. Writing @ctx(...)@ is
-- how an author says "this is a hole, count it".
data ParamValue
  = PExpr Expr
  | PFromContext [Text]
  deriving stock (Eq, Show)

-- | Both attribute-position constructs. An action's event and key are 'Text',
-- not 'Expr': the payload stays fully dynamic, but the identifying half is
-- static, which is what makes the set of actions a program can emit
-- computable ahead of time.
data Attribute
  = Attr Text Expr
  | ActionAttr Text Text Expr
  deriving stock (Eq, Show)

-- | Restricted on purpose to two forms rather than an arbitrary key-rewriting
-- function. Adaptations compose the obvious way: prefixing @a:@ and then
-- @b:@ gives @b:a:key@, needing no "already adapted" state.
data ActionAdaptation
  = Identity
  | Prefix Text
  deriving stock (Eq, Show)

-- | Nests a sequence of statements around a body, innermost last -- the
-- lowering the surface @statement* expr@ program grammar uses (v3-symbols
-- \S2.2): a binding becomes a 'Let', an emission an 'Emit', each wrapping
-- everything that follows it.
stmts :: [Stmt] -> Expr -> Expr
stmts statements body = foldr wrap body statements
  where
    wrap (SLet name value) acc = Let name value acc
    wrap (SEmit constraint) acc = Emit constraint acc

-- | How an adaptation rewrites one action key. Shared by evaluation and by
-- static analysis, which is the point of restricting adaptation to these two
-- forms: the analysis can apply the very same function the evaluator will,
-- without evaluating anything.
adaptKey :: ActionAdaptation -> Text -> Text
adaptKey Identity key = key
adaptKey (Prefix p) key = p <> key

-- | The immediately-contained expressions of an expression, in source order.
--
-- Written once here so that the analyses in "Tramaj.Analysis" are a few lines
-- each rather than a 20-case fold apiece -- and, more importantly, so that
-- adding a constructor to 'Expr' has exactly one place to be taught about
-- instead of one per traversal.
subExprs :: Expr -> [Expr]
subExprs (Path _ _) = []
subExprs (FieldAccess target _) = [target]
subExprs (Call fn args) = fn : args
subExprs (Lambda _ body) = [body]
subExprs (Let _ value body) = [value, body]
subExprs (StringLit _) = []
subExprs (NumberLit _) = []
subExprs (BoolLit _) = []
subExprs NullLit = []
subExprs (ArrayLit elems) = elems
subExprs (ObjectLit entries) = map snd entries
subExprs (Element _ attrs val children) = attributeExprs attrs <> (val : children)
subExprs (Fragment children) = children
subExprs (Branch c t e) = [c, t, e]
subExprs (Map coll fn) = [coll, fn]
subExprs (Filter coll fn) = [coll, fn]
subExprs (Scan coll initial fn) = [coll, initial, fn]
subExprs (Fold coll initial fn) = [coll, initial, fn]
subExprs (Concat l r) = [l, r]
subExprs (Import _ params) = [e | (_, PExpr e) <- params]
subExprs (AdaptActions target _ fn) = target : maybe [] pure fn
subExprs (Constrain _ args) = args
subExprs (Emit constraint body) = [constraint, body]
subExprs (Alloc _ key) = [key]
subExprs (Demand _) = []

-- | The computed expressions in a list of attributes -- an ordinary
-- attribute's value or an action's payload. An action's event and key are
-- static text, so they are not expressions to walk into.
attributeExprs :: [Attribute] -> [Expr]
attributeExprs attrs = [e | attr <- attrs, e <- case attr of Attr _ e -> [e]; ActionAttr _ _ e -> [e]]

-- | One statement of the surface program grammar (v3-symbols \S2.2), after
-- lowering: a binding or an emission. Both nest into the same 'Let'\/'Emit'
-- chain; this is only 'unlets'\' view of it.
data Stmt
  = SLet Text Expr
  | SEmit Expr
  deriving stock (Eq, Show)

-- | Peels the outermost 'Let'\/'Emit' chain back off, inverting 'lets'.
--
-- Nothing but a program's surface statement block can put a 'Let' or 'Emit'
-- outermost, so this recovers exactly that block, in order. Keeping
-- statements as ordinary nested constructors in the AST, and recovering the
-- block when it is needed, avoids a second binding construct whose scoping
-- would have to be specified separately.
--
-- Stopping at the first 'Let' alone -- as this once did, before 'Emit'
-- existed -- silently truncates a binding block that has a @!@ statement
-- threaded through it: @\@a=1; !c; \@b=2; root@ would report only @a@.
-- 'runLibrary' is the caller this matters to, since it is what exposes
-- @.vals@ and is also the one place a library's own emissions must be
-- evaluated.
unlets :: Expr -> ([Stmt], Expr)
unlets (Let name value body) = let (stmts, root) = unlets body in (SLet name value : stmts, root)
unlets (Emit constraint body) = let (stmts, root) = unlets body in (SEmit constraint : stmts, root)
unlets e = ([], e)

-- | Just the named bindings of a statement block, in order -- what an
-- import exposes as @.vals@. Discards emissions positionally; a caller that
-- must also evaluate them (running a library) should fold over 'unlets'\'
-- full result instead.
letBindings :: [Stmt] -> [(Text, Expr)]
letBindings stmts = [(n, e) | SLet n e <- stmts]

-- | Assigns each 'Alloc' in a program the index of its @?(...)@ among all of
-- them, in source order (v3-symbols \S1.4) -- a plain pre-order, left-to-right
-- walk over the freshly parsed tree, numbering as it goes.
--
-- Done as a rewrite after parsing, rather than by a counter threaded through
-- the parser itself, so that two independently written parsers agree on site
-- numbers by construction: both run this same function over what they
-- parsed, rather than having to agree on a parser-internal traversal order.
-- It relies on one property of every constructor below: each rebuilds a node
-- from the *same* immediate subexpressions 'subExprs' would report, in the
-- same order, which is what makes a left-to-right pre-order walk here land
-- on exactly "the n-th @?@ in the source" for every shape the grammar
-- produces -- attributes before value before children in an 'Element',
-- condition before either arm in a 'Branch', and so on.
numberAllocs :: Expr -> Expr
numberAllocs e = snd (go 0 e)
  where
    go :: Int -> Expr -> (Int, Expr)
    go n (Alloc _ key) =
      let (n', key') = go (n + 1) key
       in (n', Alloc n key')
    go n e'@(Path _ _) = (n, e')
    go n (FieldAccess target fields) =
      let (n', target') = go n target in (n', FieldAccess target' fields)
    go n (Call fn args) =
      let (n1, fn') = go n fn
          (n2, args') = goList n1 args
       in (n2, Call fn' args')
    go n (Lambda params body) = let (n', body') = go n body in (n', Lambda params body')
    go n (Let name value body) =
      let (n1, value') = go n value
          (n2, body') = go n1 body
       in (n2, Let name value' body')
    go n e'@(StringLit _) = (n, e')
    go n e'@(NumberLit _) = (n, e')
    go n e'@(BoolLit _) = (n, e')
    go n NullLit = (n, NullLit)
    go n (ArrayLit elems) = let (n', elems') = goList n elems in (n', ArrayLit elems')
    go n (ObjectLit entries) =
      let (n', entries') = goPairs n entries in (n', ObjectLit entries')
    go n (Element tag attrs val children) =
      let (n1, attrs') = goAttrs n attrs
          (n2, val') = go n1 val
          (n3, children') = goList n2 children
       in (n3, Element tag attrs' val' children')
    go n (Fragment children) = let (n', children') = goList n children in (n', Fragment children')
    go n (Branch c t e') =
      let (n1, c') = go n c
          (n2, t') = go n1 t
          (n3, e'') = go n2 e'
       in (n3, Branch c' t' e'')
    go n (Map coll fn) =
      let (n1, coll') = go n coll
          (n2, fn') = go n1 fn
       in (n2, Map coll' fn')
    go n (Filter coll fn) =
      let (n1, coll') = go n coll
          (n2, fn') = go n1 fn
       in (n2, Filter coll' fn')
    go n (Scan coll initial fn) =
      let (n1, coll') = go n coll
          (n2, initial') = go n1 initial
          (n3, fn') = go n2 fn
       in (n3, Scan coll' initial' fn')
    go n (Fold coll initial fn) =
      let (n1, coll') = go n coll
          (n2, initial') = go n1 initial
          (n3, fn') = go n2 fn
       in (n3, Fold coll' initial' fn')
    go n (Concat l r) =
      let (n1, l') = go n l
          (n2, r') = go n1 r
       in (n2, Concat l' r')
    go n (Import name params) =
      let (n', params') = goParams n params in (n', Import name params')
    go n (AdaptActions target adaptation fn) =
      let (n1, target') = go n target
          (n2, fn') = case fn of
            Nothing -> (n1, Nothing)
            Just f -> let (n', f') = go n1 f in (n', Just f')
       in (n2, AdaptActions target' adaptation fn')
    go n (Constrain name args) = let (n', args') = goList n args in (n', Constrain name args')
    go n (Emit constraint body) =
      let (n1, constraint') = go n constraint
          (n2, body') = go n1 body
       in (n2, Emit constraint' body')
    go n e'@(Demand _) = (n, e')

    goList :: Int -> [Expr] -> (Int, [Expr])
    goList n [] = (n, [])
    goList n (x : xs) =
      let (n1, x') = go n x
          (n2, xs') = goList n1 xs
       in (n2, x' : xs')

    goPairs :: Int -> [(Text, Expr)] -> (Int, [(Text, Expr)])
    goPairs n [] = (n, [])
    goPairs n ((k, x) : xs) =
      let (n1, x') = go n x
          (n2, xs') = goPairs n1 xs
       in (n2, (k, x') : xs')

    goAttrs :: Int -> [Attribute] -> (Int, [Attribute])
    goAttrs n [] = (n, [])
    goAttrs n (Attr name x : xs) =
      let (n1, x') = go n x
          (n2, xs') = goAttrs n1 xs
       in (n2, Attr name x' : xs')
    goAttrs n (ActionAttr ev key x : xs) =
      let (n1, x') = go n x
          (n2, xs') = goAttrs n1 xs
       in (n2, ActionAttr ev key x' : xs')

    goParams :: Int -> [(Text, ParamValue)] -> (Int, [(Text, ParamValue)])
    goParams n [] = (n, [])
    goParams n ((k, PExpr x) : xs) =
      let (n1, x') = go n x
          (n2, xs') = goParams n1 xs
       in (n2, (k, PExpr x') : xs')
    goParams n ((k, p@(PFromContext _)) : xs) =
      let (n1, xs') = goParams n xs in (n1, (k, p) : xs')
