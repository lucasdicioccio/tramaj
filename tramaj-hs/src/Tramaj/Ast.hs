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
  , programRoot
  , lets
  , unlets
  , adaptKey
  , subExprs
  , attributeExprs
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

-- | Nests a sequence of bindings around a body, innermost last -- the
-- lowering the surface @\@name=expr@ block uses, shared with any other
-- construct that introduces bindings in order.
lets :: [(Text, Expr)] -> Expr -> Expr
lets bindings body = foldr (\(name, value) acc -> Let name value acc) body bindings

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

-- | The computed expressions in a list of attributes -- an ordinary
-- attribute's value or an action's payload. An action's event and key are
-- static text, so they are not expressions to walk into.
attributeExprs :: [Attribute] -> [Expr]
attributeExprs attrs = [e | attr <- attrs, e <- case attr of Attr _ e -> [e]; ActionAttr _ _ e -> [e]]

-- | Peels the outermost 'Let' chain back off, inverting 'lets'.
--
-- Nothing but a program's surface binding block can put a 'Let' outermost, so
-- this recovers exactly the top-level bindings that block declared -- which is
-- what an import exposes as @.vals@. Keeping bindings as ordinary nested
-- 'Let's in the AST, and recovering the block when it is needed, avoids a
-- second binding construct whose scoping would have to be specified
-- separately.
unlets :: Expr -> ([(Text, Expr)], Expr)
unlets (Let name value body) = let (rest, root) = unlets body in ((name, value) : rest, root)
unlets e = ([], e)
