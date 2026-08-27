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
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (foldMap)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.Tuple (Tuple(..), fst)
import Tramaj.Ast (Attribute(..), Expr(..), ParamValue(..), Program, adaptKey, programRoot, subExprs)

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
