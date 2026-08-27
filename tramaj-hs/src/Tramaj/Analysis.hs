-- | Static analysis: what a program depends on, what it can emit, and what it
-- still needs -- all answered by walking the AST, without evaluating it,
-- without a context, and without running any host code.
--
-- @../specs/laws.md@ asks for exactly three things under "static analysis":
-- the set and precedence of imports, the set of possible actions, and bubbled
-- up context holes. Each is one function below. They are cheap by
-- construction, because the language puts the identifying half of every such
-- construct in a static position: an import's name, an action's key, an
-- adaptation's prefix and a deferred parameter's path are all 'Text' in the
-- AST, never expressions.
--
-- Each analysis comes in two depths. The shallow one reads a single program.
-- The deep one follows imports through a 'LibraryTable', which is what a host
-- actually wants -- "which actions can this page dispatch?" is a question
-- about a program /and everything it imports/ -- and is cycle-safe, returning
-- what it could reach rather than looping.
module Tramaj.Analysis
  ( staticImportNames
  , transitiveImportNames
  , staticActionKeys
  , deepActionKeys
  , contextHoles
  , deepContextHoles
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Tramaj.Ast

-- | Collects from an expression and every expression inside it.
everywhere :: (Monoid m) => (Expr -> m) -> Expr -> m
everywhere f e = f e <> foldMap (everywhere f) (subExprs e)

everywhereIn :: (Monoid m) => (Expr -> m) -> Program -> m
everywhereIn f = everywhere f . programRoot

-- Imports ---------------------------------------------------------------------

-- | Every library this program imports directly.
staticImportNames :: Program -> Set Text
staticImportNames = everywhereIn $ \case
  Import name _ -> Set.singleton name
  _ -> Set.empty

-- | Every library reachable from this program, directly or through another
-- import. A name that is imported but missing from the table is still
-- reported -- an unresolvable dependency is exactly what a caller wants to
-- hear about -- and a cycle terminates instead of looping.
transitiveImportNames :: Map Text Program -> Program -> Set Text
transitiveImportNames libs = go Set.empty . staticImportNames
  where
    go seen frontier = case Set.minView (frontier `Set.difference` seen) of
      Nothing -> seen
      Just (name, _) ->
        let seen' = Set.insert name seen
            next = maybe Set.empty staticImportNames (Map.lookup name libs)
         in go seen' (Set.union (frontier `Set.difference` seen') next)

-- Actions -----------------------------------------------------------------------

-- | Every action key this program can emit from its own AST.
--
-- Adaptation is applied rather than ignored: @adapt-actions(x, prefix("user:"))@
-- over a subtree whose keys are @{save, delete}@ contributes
-- @{user:save, user:delete}@, using the very same 'adaptKey' the evaluator
-- will. This is the payoff of restricting adaptation to identity-or-prefix.
--
-- Keys living inside an imported library are /not/ included -- this function
-- sees one program. Use 'deepActionKeys' to follow imports.
staticActionKeys :: Program -> Set Text
staticActionKeys = actionKeysIn . programRoot

actionKeysIn :: Expr -> Set Text
actionKeysIn (AdaptActions target adaptation fn) =
  Set.map (adaptKey adaptation) (actionKeysIn target) <> foldMap actionKeysIn fn
actionKeysIn e = ownKeys e <> foldMap actionKeysIn (subExprs e)
  where
    ownKeys (Element _ attrs _ _) = Set.fromList [k | ActionAttr _ k _ <- attrs]
    ownKeys _ = Set.empty

-- | Every action key this program can emit, following imports.
--
-- An import contributes its library's own keys, adapted by any
-- @adapt-actions@ wrapping it -- so @adapt-actions(import("button", ...),
-- prefix("deployment:"))@ over a library emitting @deploy@ yields
-- @deployment:deploy@ without either program being run.
--
-- This is an over-approximation on purpose: it reports what the program
-- /could/ emit, including keys under a 'Branch' arm that a given context will
-- never select. A missing library contributes nothing, and a cycle is cut.
deepActionKeys :: Map Text Program -> Program -> Set Text
deepActionKeys libs prog = go Set.empty (programRoot prog)
  where
    go seen (AdaptActions target adaptation fn) =
      Set.map (adaptKey adaptation) (go seen target) <> foldMap (go seen) fn
    go seen (Import name params)
      | Set.member name seen = fromParams
      | otherwise = fromParams <> maybe Set.empty (go (Set.insert name seen) . programRoot) (Map.lookup name libs)
      where
        fromParams = foldMap (go seen) [e | (_, PExpr e) <- params]
    go seen e = ownKeys e <> foldMap (go seen) (subExprs e)
      where
        ownKeys (Element _ attrs _ _) = Set.fromList [k | ActionAttr _ k _ <- attrs]
        ownKeys _ = Set.empty

-- Context holes ---------------------------------------------------------------------

-- | Every context path this program's own imports defer -- the values a caller
-- must supply to complete them.
--
-- This is only answerable because @ctx(path)@ states provenance in the source.
-- Under a design where partiality is discovered by running an import and
-- watching what fails, there is nothing to read here at all.
contextHoles :: Program -> Set [Text]
contextHoles = everywhereIn $ \case
  Import _ params -> Set.fromList [path | (_, PFromContext path) <- params]
  _ -> Set.empty

-- | Context holes of this program and of every library it imports -- the
-- "bubbled up" view: what the whole dependency tree still needs.
--
-- Note that a hole in an imported library is a hole in /that library's/
-- completion context, not in this program's; the paths are reported as
-- written, and it is the caller wiring the import that decides where each is
-- filled from.
deepContextHoles :: Map Text Program -> Program -> Set [Text]
deepContextHoles libs prog =
  contextHoles prog
    <> foldMap (maybe Set.empty contextHoles . flip Map.lookup libs) (transitiveImportNames libs prog)
