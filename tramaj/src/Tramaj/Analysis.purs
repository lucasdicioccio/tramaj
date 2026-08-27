-- | Static analysis: what a program depends on, what it can emit, and what
-- | it still needs — all answered by walking the AST, without evaluating
-- | it, without a context, and without running any host code.
-- |
-- | `specs/laws.md` asks for exactly three things under "static analysis":
-- | the set and precedence of imports, the set of possible actions, and
-- | bubbled up context holes. Each is one function below. They are cheap by
-- | construction, because the language puts the identifying half of every
-- | such construct in a static position: an import's name, an action's key,
-- | an adaptation's prefix and a deferred parameter's path are all `String`
-- | in the AST, never expressions.
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
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (foldMap)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.Tuple (Tuple(..))
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

-- | Every context path this program's own imports defer — the values a
-- | caller must supply to complete them.
-- |
-- | This is only answerable because `ctx(path)` states provenance in the
-- | source. Under a design where partiality is discovered by running an
-- | import and watching what fails, there is nothing to read here at all.
contextHoles :: Program -> Set (Array String)
contextHoles = everywhereIn case _ of
  Import _ params -> Set.fromFoldable (Array.mapMaybe deferredPath params)
  _ -> Set.empty
  where
  deferredPath (Tuple _ (PFromContext path)) = Just path
  deferredPath _ = Nothing

-- | Context holes of this program and of every library it imports — the
-- | "bubbled up" view: what the whole dependency tree still needs.
-- |
-- | Note that a hole in an imported library is a hole in *that library's*
-- | completion context, not in this program's; the paths are reported as
-- | written, and it is the caller wiring the import that decides where each
-- | is filled from.
deepContextHoles :: Map String Program -> Program -> Set (Array String)
deepContextHoles libs prog =
  contextHoles prog
    <> foldMap (maybe Set.empty contextHoles <<< flip Map.lookup libs) (transitiveImportNames libs prog)
