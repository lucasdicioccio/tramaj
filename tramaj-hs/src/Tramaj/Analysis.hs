-- | Static analysis: what a program depends on, what it can emit, and what it
-- still needs -- all answered by walking the AST, without evaluating it,
-- without a context, and without running any host code.
--
-- @../specs/laws.md@ asks for exactly three things under "static analysis":
-- the set and precedence of imports, the set of possible actions, and bubbled
-- up context holes. Each is one function below. They are cheap by
-- construction, because the language puts the identifying half of every such
-- construct in a static position: an import's name, an action's key, an
-- adaptation's prefix and a @ctx(...)@ parameter's path are all 'Text' in the
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
  , contextReads
  , unsuppliedParams
  , constraintKinds
  , deepConstraintKinds
  , symbolSites
  , symbolDemands
  , deepSymbolDemands
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

-- | Every path this program declares as a hole with @ctx(path)@ -- the values
-- its own context must carry for its imports to be wired up.
--
-- These are reads from /this/ program's @$ctx@, performed where each import is
-- written. What makes them worth a function of their own is that the author
-- marked them: 'contextReads' finds every context read, 'contextHoles' finds
-- the ones written as holes, and only the second is a promise about what feeds
-- an import.
contextHoles :: Program -> Set [Text]
contextHoles = everywhereIn $ \case
  Import _ params -> Set.fromList [path | (_, PFromContext path) <- params]
  _ -> Set.empty

-- | Context holes of this program and of every library it imports -- the
-- "bubbled up" view: what the whole dependency tree declares as holes.
--
-- Note that a hole in an imported library is a hole in /that library's/
-- context, which is the parameter object its importer hands it -- not a path
-- in this program's context. The paths are reported as written, and it is the
-- import that wires the library up which decides where each is filled from.
deepContextHoles :: Map Text Program -> Program -> Set [Text]
deepContextHoles libs prog =
  contextHoles prog
    <> foldMap (maybe Set.empty contextHoles . flip Map.lookup libs) (transitiveImportNames libs prog)

-- | Every path this program reads out of its own context, however it is
-- written: @$ctx.a.b@ and a @ctx(a.b)@ import parameter both count.
--
-- For a library, this is the shape of the parameter object it expects, since a
-- library's @$ctx@ /is/ its parameters -- which is what makes
-- 'unsuppliedParams' possible.
--
-- A bare @$ctx@, with no path, reads the whole context and contributes the
-- empty path.
contextReads :: Program -> Set [Text]
contextReads = everywhereIn $ \case
  Path "ctx" fields -> Set.singleton fields
  Import _ params -> Set.fromList [path | (_, PFromContext path) <- params]
  _ -> Set.empty

-- | For each import in this program, the paths its library reads from its
-- context that the import does not supply -- the parameters that still have to
-- be saturated by calling the import value before a field is read off it.
--
-- One entry per import site, in traversal order, so two imports of the same
-- library with different parameters are reported separately. An import whose
-- library is missing from the table contributes an empty set: what it needs is
-- unknowable, not nothing, and 'staticImportNames' is where an unresolvable
-- dependency is reported.
--
-- Two deliberate imprecisions, both in the safe direction for a caller asking
-- "what have I forgotten?":
--
-- * It over-reports, like 'deepActionKeys': a path a library reads only in a
--   @branch@ arm that never fires still counts as needed.
-- * It stops at the library's own reads and does not follow that library's
--   imports, whose parameters that library supplies itself.
--
-- A read is attributed to a parameter by its first segment, so a library
-- reading @$ctx.spec.replicas@ needs the parameter @spec@; the whole path is
-- reported, because the shape wanted is more useful than the name alone. A
-- bare @$ctx@ read names no parameter and is skipped.
unsuppliedParams :: Map Text Program -> Program -> [(Text, Set [Text])]
unsuppliedParams libs = everywhereIn $ \case
  Import name params -> [(name, missingFor name params)]
  _ -> []
  where
    missingFor name params =
      Set.filter (unsupplied (Set.fromList (map fst params))) $
        maybe Set.empty contextReads (Map.lookup name libs)
    unsupplied _ [] = False
    unsupplied supplied (root : _) = not (Set.member root supplied)

-- Constraints -------------------------------------------------------------------

-- | Every constraint name this program can emit from its own AST
-- (v3-symbols \S7). Answerable statically because a @constraint(...)@'s name
-- is a static string, like an action's event and key.
constraintKinds :: Program -> Set Text
constraintKinds = everywhereIn $ \case
  Constrain name _ -> Set.singleton name
  _ -> Set.empty

-- | Every constraint name this program can emit, following imports -- the
-- question a host actually wants answered before it decides whether it
-- supports a template (v3-symbols \S7: "lets a host decide ... before
-- running it"). Over-approximates like 'deepActionKeys': a kind emitted only
-- under a 'Branch' arm no context will select is still reported, and a
-- missing library contributes nothing rather than failing.
deepConstraintKinds :: Map Text Program -> Program -> Set Text
deepConstraintKinds libs prog = go Set.empty (programRoot prog)
  where
    go seen (Import name params)
      | Set.member name seen = fromParams
      | otherwise = fromParams <> maybe Set.empty (go (Set.insert name seen) . programRoot) (Map.lookup name libs)
      where
        fromParams = foldMap (go seen) [e | (_, PExpr e) <- params]
    go seen e = ownKind e <> foldMap (go seen) (subExprs e)
      where
        ownKind (Constrain name _) = Set.singleton name
        ownKind _ = Set.empty

-- Symbols -------------------------------------------------------------------

-- | The @?(k)@ allocation sites this program contains (v3-symbols \S7) --
-- sites, not keys, since the number of symbols a site produces is a runtime
-- fact (one per @map@ iteration, say) but the number of sites is not.
--
-- This is also the static counterpart of 'AllocationInLibrary' (\S6): a
-- program with a non-empty 'symbolSites' cannot serve as a library, which is
-- exactly the check 'Tramaj.Eval.runLibrary' makes before evaluating one.
symbolSites :: Program -> Set Int
symbolSites = everywhereIn $ \case
  Alloc site _ -> Set.singleton site
  _ -> Set.empty

-- | Every context path this program declares symbolic with @?ctx.…@ (\S7),
-- directly -- the demand form's counterpart of 'contextHoles'.
symbolDemands :: Program -> Set [Text]
symbolDemands = everywhereIn $ \case
  Demand path -> Set.singleton path
  _ -> Set.empty

-- | Demands bubbled up through every library this program imports, the way
-- 'deepContextHoles' bubbles up @ctx(...)@ holes -- the counterpart of
-- ref \S9's @unsuppliedParams@ for this feature (\S7): since only the root
-- may allocate, knowing which paths the libraries beneath will discuss
-- symbolically /is/ the whole planning problem, answered without running
-- anything.
deepSymbolDemands :: Map Text Program -> Program -> Set [Text]
deepSymbolDemands libs prog =
  symbolDemands prog
    <> foldMap (maybe Set.empty symbolDemands . flip Map.lookup libs) (transitiveImportNames libs prog)
