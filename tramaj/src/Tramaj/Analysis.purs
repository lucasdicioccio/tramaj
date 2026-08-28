-- | Static analysis: what a program depends on, what it can emit, and what
-- | it still needs — all answered by walking the AST, without evaluating
-- | it, without a context, and without running any host code.
-- |
-- | `specs/laws.md` asks for exactly three things under "static analysis":
-- | the set and precedence of imports, the set of possible actions, and
-- | bubbled up context holes. Each is one function below. They are cheap by
-- | construction, because the language puts the identifying half of every
-- | such construct in a static position: an import's name, an action's key,
-- | an adaptation's prefix and a `ctx(...)` parameter's path are all
-- | `String` in the AST, never expressions.
-- |
-- | Each analysis comes in two depths. The shallow one reads a single
-- | program. The deep one follows imports through a library table, which is
-- | what a host actually wants — "which actions can this page dispatch?" is
-- | a question about a program *and everything it imports* — and is
-- | cycle-safe, returning what it could reach rather than looping.
-- |
-- | Kept in lockstep with `../tramaj-hs/src/Tramaj/Analysis.hs`.
module Tramaj.Analysis
  ( staticImportNames
  , transitiveImportNames
  , staticActionKeys
  , deepActionKeys
  , contextHoles
  , deepContextHoles
  , contextReads
  , unsuppliedParams
  , constraintKinds
  , deepConstraintKinds
  , symbolSites
  , symbolDemands
  , deepSymbolDemands
  , typeDeclarations
  , typeParams
  , unsuppliedTypeParams
  , typeParamCollisions
  , typeExprsIn
  , everywhere
  , everywhereIn
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (foldMap)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.Tuple (Tuple(..), fst, snd)
import Tramaj.Ast (Attribute(..), Expr(..), ParamValue(..), Program, TypeConstraintArg(..), TypeExpr(..), adaptKey, programRoot, subExprs, typeDecls, unlets)

-- | Collects from an expression and every expression inside it.
everywhere :: forall m. Monoid m => (Expr -> m) -> Expr -> m
everywhere f e = f e <> foldMap (everywhere f) (subExprs e)

everywhereIn :: forall m. Monoid m => (Expr -> m) -> Program -> m
everywhereIn f = everywhere f <<< programRoot

-- Imports ---------------------------------------------------------------------

-- | Every library this program imports directly.
staticImportNames :: Program -> Set String
staticImportNames = everywhereIn case _ of
  Import name _ -> Set.singleton name
  _ -> Set.empty

-- | Every library reachable from this program, directly or through another
-- | import. A name that is imported but missing from the table is still
-- | reported — an unresolvable dependency is exactly what a caller wants to
-- | hear about — and a cycle terminates instead of looping.
transitiveImportNames :: Map String Program -> Program -> Set String
transitiveImportNames libs = go Set.empty <<< staticImportNames
  where
  go seen frontier = case Set.findMin (Set.difference frontier seen) of
    Nothing -> seen
    Just name ->
      let
        seen' = Set.insert name seen
        next = maybe Set.empty staticImportNames (Map.lookup name libs)
      in
        go seen' (Set.union (Set.difference frontier seen') next)

-- Actions -----------------------------------------------------------------------

-- | Every action key this program can emit from its own AST.
-- |
-- | Adaptation is applied rather than ignored:
-- | `adapt-actions(x, prefix("user:"))` over a subtree whose keys are
-- | `{save, delete}` contributes `{user:save, user:delete}`, using the very
-- | same `adaptKey` the evaluator will. This is the payoff of restricting
-- | adaptation to identity-or-prefix.
-- |
-- | Keys living inside an imported library are *not* included — this
-- | function sees one program. Use `deepActionKeys` to follow imports.
staticActionKeys :: Program -> Set String
staticActionKeys = actionKeysIn <<< programRoot

actionKeysIn :: Expr -> Set String
actionKeysIn (AdaptActions target adaptation fn) =
  Set.map (adaptKey adaptation) (actionKeysIn target) <> foldMap actionKeysIn fn
actionKeysIn e = ownActionKeys e <> foldMap actionKeysIn (subExprs e)

ownActionKeys :: Expr -> Set String
ownActionKeys (Element _ attrs _ _) = Set.fromFoldable (Array.mapMaybe actionKey attrs)
  where
  actionKey (ActionAttr _ key _) = Just key
  actionKey _ = Nothing
ownActionKeys _ = Set.empty

-- | Every action key this program can emit, following imports.
-- |
-- | An import contributes its library's own keys, adapted by any
-- | `adapt-actions` wrapping it — so
-- | `adapt-actions(import("button", ...), prefix("deployment:"))` over a
-- | library emitting `deploy` yields `deployment:deploy` without either
-- | program being run.
-- |
-- | This is an over-approximation on purpose: it reports what the program
-- | *could* emit, including keys under a `Branch` arm that a given context
-- | will never select. A missing library contributes nothing, and a cycle
-- | is cut.
deepActionKeys :: Map String Program -> Program -> Set String
deepActionKeys libs prog = go Set.empty (programRoot prog)
  where
  go seen (AdaptActions target adaptation fn) =
    Set.map (adaptKey adaptation) (go seen target) <> foldMap (go seen) fn
  go seen (Import name params) =
    let
      fromParams = foldMap (go seen) (Array.mapMaybe suppliedExpr params)
    in
      if Set.member name seen then fromParams
      else fromParams <> maybe Set.empty (go (Set.insert name seen) <<< programRoot) (Map.lookup name libs)
  go seen e = ownActionKeys e <> foldMap (go seen) (subExprs e)

  suppliedExpr (Tuple _ (PExpr e)) = Just e
  suppliedExpr _ = Nothing

-- Context holes ---------------------------------------------------------------------

-- | Every path this program declares as a hole with `ctx(path)` — the
-- | values its own context must carry for its imports to be wired up.
-- |
-- | These are reads from *this* program's `$ctx`, performed where each
-- | import is written. What makes them worth a function of their own is
-- | that the author marked them: `contextReads` finds every context read,
-- | `contextHoles` finds the ones written as holes, and only the second is
-- | a promise about what feeds an import.
contextHoles :: Program -> Set (Array String)
contextHoles = everywhereIn case _ of
  Import _ params -> Set.fromFoldable (Array.mapMaybe deferredPath params)
  _ -> Set.empty
  where
  deferredPath (Tuple _ (PFromContext path)) = Just path
  deferredPath _ = Nothing

-- | Context holes of this program and of every library it imports — the
-- | "bubbled up" view: what the whole dependency tree declares as holes.
-- |
-- | Note that a hole in an imported library is a hole in *that library's*
-- | context, which is the parameter object its importer hands it — not a
-- | path in this program's context. The paths are reported as written, and
-- | it is the import that wires the library up which decides where each is
-- | filled from.
deepContextHoles :: Map String Program -> Program -> Set (Array String)
deepContextHoles libs prog =
  contextHoles prog
    <> foldMap (maybe Set.empty contextHoles <<< flip Map.lookup libs) (transitiveImportNames libs prog)

-- | Every path this program reads out of its own context, however it is
-- | written: `$ctx.a.b` and a `ctx(a.b)` import parameter both count.
-- |
-- | For a library, this is the shape of the parameter object it expects,
-- | since a library's `$ctx` *is* its parameters — which is what makes
-- | `unsuppliedParams` possible.
-- |
-- | A bare `$ctx`, with no path, reads the whole context and contributes
-- | the empty path.
contextReads :: Program -> Set (Array String)
contextReads = everywhereIn case _ of
  Path "ctx" fields -> Set.singleton fields
  Import _ params -> Set.fromFoldable (Array.mapMaybe holePath params)
  _ -> Set.empty
  where
  holePath (Tuple _ (PFromContext path)) = Just path
  holePath _ = Nothing

-- | For each import in this program, the paths its library reads from its
-- | context that the import does not supply — the parameters that still
-- | have to be saturated by calling the import value before a field is
-- | read off it.
-- |
-- | One entry per import site, in traversal order, so two imports of the
-- | same library with different parameters are reported separately. An
-- | import whose library is missing from the table contributes an empty
-- | set: what it needs is unknowable, not nothing, and `staticImportNames`
-- | is where an unresolvable dependency is reported.
-- |
-- | Two deliberate imprecisions, both in the safe direction for a caller
-- | asking "what have I forgotten?":
-- |
-- | * It over-reports, like `deepActionKeys`: a path a library reads only
-- |   in a `branch` arm that never fires still counts as needed.
-- | * It stops at the library's own reads and does not follow that
-- |   library's imports, whose parameters that library supplies itself.
-- |
-- | A read is attributed to a parameter by its first segment, so a library
-- | reading `$ctx.spec.replicas` needs the parameter `spec`; the whole
-- | path is reported, because the shape wanted is more useful than the
-- | name alone. A bare `$ctx` read names no parameter and is skipped.
unsuppliedParams :: Map String Program -> Program -> Array (Tuple String (Set (Array String)))
unsuppliedParams libs = everywhereIn case _ of
  Import name params -> [ Tuple name (missingFor name params) ]
  _ -> []
  where
  missingFor name params =
    Set.filter (unsupplied (Set.fromFoldable (map fst params)))
      (maybe Set.empty contextReads (Map.lookup name libs))

  unsupplied supplied path = case Array.head path of
    Nothing -> false
    Just root -> not (Set.member root supplied)

-- Constraints -------------------------------------------------------------------

-- | Every constraint name this program can emit from its own AST
-- | (v3-symbols §7). Answerable statically because a `constraint(...)`'s
-- | name is a static string, like an action's event and key.
constraintKinds :: Program -> Set String
constraintKinds = everywhereIn case _ of
  Constrain name _ -> Set.singleton name
  _ -> Set.empty

-- | Every constraint name this program can emit, following imports — the
-- | question a host actually wants answered before it decides whether it
-- | supports a template (v3-symbols §7: "lets a host decide ... before
-- | running it"). Over-approximates like `deepActionKeys`: a kind emitted
-- | only under a `Branch` arm no context will select is still reported, and
-- | a missing library contributes nothing rather than failing.
deepConstraintKinds :: Map String Program -> Program -> Set String
deepConstraintKinds libs prog = go Set.empty (programRoot prog)
  where
  go seen (Import name params) =
    let
      fromParams = foldMap (go seen) (Array.mapMaybe suppliedExpr params)
    in
      if Set.member name seen then fromParams
      else fromParams <> maybe Set.empty (go (Set.insert name seen) <<< programRoot) (Map.lookup name libs)
  go seen e = ownKind e <> foldMap (go seen) (subExprs e)

  ownKind (Constrain name _) = Set.singleton name
  ownKind _ = Set.empty

  suppliedExpr (Tuple _ (PExpr e)) = Just e
  suppliedExpr _ = Nothing

-- Symbols -------------------------------------------------------------------

-- | The `?(k)` allocation sites this program contains (v3-symbols §7) —
-- | sites, not keys, since the number of symbols a site produces is a
-- | runtime fact (one per `map` iteration, say) but the number of sites is
-- | not.
-- |
-- | This is also the static counterpart of `AllocationInLibrary` (§6): a
-- | program with a non-empty `symbolSites` cannot serve as a library, which
-- | is exactly the check `Tramaj.Eval.runLibrary` makes before evaluating
-- | one.
symbolSites :: Program -> Set Int
symbolSites = everywhereIn case _ of
  Alloc site _ -> Set.singleton site
  _ -> Set.empty

-- | Every context path this program declares symbolic with `?ctx.…` (§7),
-- | directly — the demand form's counterpart of `contextHoles`.
symbolDemands :: Program -> Set (Array String)
symbolDemands = everywhereIn case _ of
  Demand path -> Set.singleton path
  _ -> Set.empty

-- | Demands bubbled up through every library this program imports, the way
-- | `deepContextHoles` bubbles up `ctx(...)` holes — the counterpart of
-- | ref §9's `unsuppliedParams` for this feature (§7): since only the root
-- | may allocate, knowing which paths the libraries beneath will discuss
-- | symbolically *is* the whole planning problem, answered without running
-- | anything.
deepSymbolDemands :: Map String Program -> Program -> Set (Array String)
deepSymbolDemands libs prog =
  symbolDemands prog
    <> foldMap (maybe Set.empty symbolDemands <<< flip Map.lookup libs) (transitiveImportNames libs prog)

-- Types -----------------------------------------------------------------------

-- | Every name this program declares with `type ... = ...` (v4-types §9) —
-- | the type-realm counterpart of a program's own let-bound names, and the
-- | source `Tramaj.Types.resolveTypeExpr` consults for a bare `TName`.
typeDeclarations :: Program -> Set String
typeDeclarations prog = Set.fromFoldable (map fst (typeDecls (unlets (programRoot prog)).statements))

-- | The `%ctx.*` paths one `TypeExpr` mentions directly — `TVar` is a leaf,
-- | so this is a plain fold, with no need to stop at a `TName`/`TLibRef` the
-- | way `Tramaj.Types.resolveTypeExpr` must: a reference's own parameters
-- | are not this program's variables, so there is nothing to recurse into
-- | there, and nothing here evaluates or resolves anything.
typeParamsIn :: TypeExpr -> Set (Array String)
typeParamsIn (TPrim _) = Set.empty
typeParamsIn (TArray t) = typeParamsIn t
typeParamsIn (TRecord fields) = foldMap (typeParamsIn <<< snd) fields
typeParamsIn (TUnion arms) = foldMap (maybe Set.empty typeParamsIn <<< snd) arms
typeParamsIn (TName _) = Set.empty
typeParamsIn (TLibRef _ _) = Set.empty
typeParamsIn (TVar path) = Set.singleton path

-- | Every `TypeExpr` sitting in one expression's own syntax, not recursing
-- | into subexpressions — `everywhere` does that part. A declaration's
-- | body, an annotation's type, a type constraint's type-marked arguments,
-- | and an import parameter's `%`-marked value (v4-types §2, roadmap
-- | Phase 10) are the four positions a `TypeExpr` can occur in at all.
typeExprsIn :: Expr -> Array TypeExpr
typeExprsIn (TypeDecl _ t _) = [ t ]
typeExprsIn (TypeAnnotate _ t _ _) = [ t ]
typeExprsIn (TypeEmit _ args _) = Array.mapMaybe onlyType args
  where
  onlyType (TCType t) = Just t
  onlyType _ = Nothing
typeExprsIn (Import _ params) = Array.mapMaybe onlyType params
  where
  onlyType (Tuple _ (PType t)) = Just t
  onlyType _ = Nothing
typeExprsIn _ = []

-- | Every `%ctx.*` path this program mentions in a type-bearing position
-- | (v4-types §9, roadmap Phase 10) — its type-level parameter list, the
-- | way `contextReads` is a program's value-level one. This is what a
-- | library exposes for its importer to supply via a `%`-marked param
-- | (§2), and it must include a forwarding import's own `%ctx.*` params,
-- | not only what a `type ... = ...` declaration mentions directly:
-- | forwarding (`import("inner", {payload: %ctx.payload})`, §2) is exactly
-- | how a library that itself has no annotated declaration still has an
-- | unsaturated parameter its own importer must close.
typeParams :: Program -> Set (Array String)
typeParams = everywhereIn (foldMap typeParamsIn <<< typeExprsIn)

-- | For each import in this program, the type params (`typeParams`) its
-- | library needs that the import's `%`-marked entries do not supply —
-- | `unsuppliedParams`' type-side twin (roadmap Phase 10), sharing the same
-- | first-segment attribution rule and the same stopping condition: a read
-- | is attributed to the parameter its path begins with, and a missing
-- | library contributes nothing rather than failing.
unsuppliedTypeParams :: Map String Program -> Program -> Array (Tuple String (Set (Array String)))
unsuppliedTypeParams libs = everywhereIn case _ of
  Import name params -> [ Tuple name (missingFor name params) ]
  _ -> []
  where
  missingFor name params =
    Set.filter (unsupplied (Set.fromFoldable (Array.mapMaybe onlyTypeKey params)))
      (maybe Set.empty typeParams (Map.lookup name libs))

  onlyTypeKey (Tuple k (PType _)) = Just k
  onlyTypeKey _ = Nothing

  unsupplied supplied path = case Array.head path of
    Nothing -> false
    Just root -> not (Set.member root supplied)

-- | Param keys this program reads both as an ordinary value hole
-- | (`$ctx.k`/`ctx(k)`) and as a type hole (`%ctx.k`) — v4-types §10's
-- | `TypeParamCollision`, keyed by first segment exactly as
-- | `unsuppliedParams` and `unsuppliedTypeParams` both are, since that
-- | segment is the parameter name the two channels of §2.1's one params
-- | record would otherwise share.
typeParamCollisions :: Program -> Set String
typeParamCollisions prog =
  Set.intersection (Set.map firstSegment (contextReads prog)) (Set.map firstSegment (typeParams prog))
  where
  firstSegment path = case Array.head path of
    Nothing -> ""
    Just x -> x
