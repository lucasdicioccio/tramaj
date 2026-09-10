-- | Standalone CLI over the `tramaj` package's parser/eval core. Two
-- | commands are supported:
-- |
-- | * `tramaj-cli [evaluate] [--lib name=path ...] [--mode concrete|symbolic]
-- |   <template-file> <context-json-file>` — the original behaviour, unchanged.
-- |
-- | * `tramaj-cli analyze <subcommand> <template-file> [--lib name=path ...]`
-- |   — static analysis of a template without evaluating it and without a
-- |   context file. Each subcommand prints JSON to stdout; type-level
-- |   analyses can fail with a type error on stderr and a non-zero exit.
-- |
-- | Any number of `--lib name=path` flags register a host-supplied
-- | `LibraryTable`, letting the template use `import(name, ...)` against files
-- | on disk. A library can never allocate regardless of mode (v3-symbols §1.4).
-- |
-- | Deliberately depends on `tramaj` only, not `tramaj-halogen` —
-- | this never folds to real Halogen output, so it doesn't need a DOM/
-- | browser runtime at all, just Node's `fs`.
module Main (main, Command(..), AnalyzeSubcommand(..), analyzeToJson) where

import Prelude

import Data.Argonaut.Core (Json, fromArray, fromBoolean, fromNumber, fromObject, fromString, jsonNull, stringify)
import Data.Argonaut.Parser (jsonParser)
import Data.Array (drop, uncons, zipWith)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int as Int
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.String (Pattern(..), drop, indexOf, take) as Str
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Class.Console (log, error)
import Foreign.Object as Object
import Node.Encoding (Encoding(UTF8))
import Node.FS.Sync (readTextFile)
import Node.Process (argv, exit')
import Tramaj.Analysis (deepActionKeys, deepConstraintKinds, deepContextHoles, deepSymbolDemands, symbolSites, transitiveImportNames, typeDeclarations, typeParams, unsuppliedParams, unsuppliedTypeParams)
import Tramaj.Ast (Program)
import Tramaj.Eval (LibraryTable, Mode(..), runProgram)
import Tramaj.Parser (parseProgram)
import Tramaj.Types (ResolvedConstraintArg(..), TypeError, canonicalId, checkTypeParamCollisions, deepTypeConstraints, deepTypeReferences)

data Command
  = Evaluate { libSpecs :: Array (Tuple String String), mode :: Mode, templatePath :: String, contextPath :: String }
  | Analyze { libSpecs :: Array (Tuple String String), subcommand :: AnalyzeSubcommand, templatePath :: String }

data AnalyzeSubcommand
  = AnalyzeImports
  | AnalyzeActions
  | AnalyzeHoles
  | AnalyzeUnsupplied
  | AnalyzeConstraints
  | AnalyzeSymbols
  | AnalyzeTypes
  | AnalyzeAll

derive instance eqAnalyzeSubcommand :: Eq AnalyzeSubcommand

usage :: String
usage = "usage: tramaj-cli [evaluate] [--lib name=path ...] [--mode concrete|symbolic] <template-file> <context-json-file>\n       tramaj-cli analyze <imports|actions|holes|unsupplied|constraints|symbols|types|all> <template-file> [--lib name=path ...]"

main :: Effect Unit
main = do
  args <- drop 2 <$> argv
  case parseArgs args of
    Left err -> die (err <> "\n" <> usage)
    Right (Evaluate r) -> runEvaluate r.libSpecs r.mode r.templatePath r.contextPath
    Right (Analyze r) -> runAnalyze r.libSpecs r.subcommand r.templatePath

-- | Splits `argv` into an optional command (`evaluate` or `analyze`), any
-- | number of `--lib name=path` pairs, an optional `--mode`, and the remaining
-- | positional arguments. The bare legacy form (no command word) is still
-- | accepted and means `evaluate`.
parseArgs :: Array String -> Either String Command
parseArgs args = case uncons args of
  Just { head: "analyze", tail: rest } -> parseAnalyze rest
  Just { head: "evaluate", tail: rest } -> parseEvaluate rest
  _ -> parseEvaluate args

parseEvaluate :: Array String -> Either String Command
parseEvaluate args = do
  { libSpecs, mode, positional } <- parseGlobalOptions true args
  case positional of
    [ templatePath, ctxPath ] -> Right (Evaluate { libSpecs, mode, templatePath, contextPath: ctxPath })
    _ -> Left ("evaluate expects <template-file> <context-json-file>, got: " <> show (Array.length positional) <> " positional argument(s)")

parseAnalyze :: Array String -> Either String Command
parseAnalyze args = do
  { libSpecs, positional } <- parseGlobalOptions false args
  case positional of
    [ sub, templatePath ] -> do
      subcommand <- parseSubcommand sub
      Right (Analyze { libSpecs, subcommand, templatePath })
    _ -> Left ("analyze expects <subcommand> <template-file>, got: " <> show (Array.length positional) <> " positional argument(s)")

parseSubcommand :: String -> Either String AnalyzeSubcommand
parseSubcommand "imports" = Right AnalyzeImports
parseSubcommand "actions" = Right AnalyzeActions
parseSubcommand "holes" = Right AnalyzeHoles
parseSubcommand "unsupplied" = Right AnalyzeUnsupplied
parseSubcommand "constraints" = Right AnalyzeConstraints
parseSubcommand "symbols" = Right AnalyzeSymbols
parseSubcommand "types" = Right AnalyzeTypes
parseSubcommand "all" = Right AnalyzeAll
parseSubcommand other = Left ("unknown analyze subcommand: " <> other)

type GlobalParseResult = { libSpecs :: Array (Tuple String String), mode :: Mode, positional :: Array String }

-- | Parses `--lib name=path` pairs, an optional `--mode` (only when
-- | `modeAllowed` is true), and collects every other token as positional.
parseGlobalOptions :: Boolean -> Array String -> Either String GlobalParseResult
parseGlobalOptions modeAllowed = go { libSpecs: [], mode: Concrete, positional: [] }
  where
  go :: GlobalParseResult -> Array String -> Either String GlobalParseResult
  go acc argsList = case uncons argsList of
    Nothing -> Right acc
    Just { head: "--lib", tail: rest } -> case uncons rest of
      Nothing -> Left "--lib expects a following name=path argument"
      Just { head: spec, tail: rest' } -> case splitOnFirst "=" spec of
        Nothing -> Left ("--lib expects name=path, got: " <> spec)
        Just (Tuple name path) -> go (acc { libSpecs = Array.snoc acc.libSpecs (Tuple name path) }) rest'
    Just { head: "--mode", tail: rest }
      | not modeAllowed -> Left "--mode is not valid for the analyze command"
      | otherwise -> case uncons rest of
          Nothing -> Left "--mode expects a following concrete|symbolic argument"
          Just { head: "concrete", tail: rest' } -> go (acc { mode = Concrete }) rest'
          Just { head: "symbolic", tail: rest' } -> go (acc { mode = Symbolic }) rest'
          Just { head: other, tail: _ } -> Left ("--mode expects concrete|symbolic, got: " <> other)
    Just { head, tail: rest } -> go (acc { positional = Array.snoc acc.positional head }) rest

  splitOnFirst :: String -> String -> Maybe (Tuple String String)
  splitOnFirst sep s = case Str.indexOf (Str.Pattern sep) s of
    Nothing -> Nothing
    Just i -> Just (Tuple (Str.take i s) (Str.drop (i + 1) s))

runEvaluate :: Array (Tuple String String) -> Mode -> String -> String -> Effect Unit
runEvaluate libSpecs mode templatePath ctxPath = do
  libsResult <- loadLibraries libSpecs
  case libsResult of
    Left err -> die err
    Right libs -> do
      templateSrc <- readTextFile UTF8 templatePath
      ctxSrc <- readTextFile UTF8 ctxPath
      case jsonParser ctxSrc of
        Left err -> die ("invalid JSON context (" <> ctxPath <> "): " <> err)
        Right ctxJson -> case parseProgram templateSrc of
          Left err -> die ("parse error (" <> templatePath <> "): " <> show err)
          Right program -> case runProgram mode libs ctxJson program of
            Left err -> die ("eval error: " <> show err)
            Right result -> log (stringify result)

runAnalyze :: Array (Tuple String String) -> AnalyzeSubcommand -> String -> Effect Unit
runAnalyze libSpecs subcommand templatePath = do
  libsResult <- loadLibraries libSpecs
  case libsResult of
    Left err -> die err
    Right libs -> do
      templateSrc <- readTextFile UTF8 templatePath
      case parseProgram templateSrc of
        Left err -> die ("parse error (" <> templatePath <> "): " <> show err)
        Right program -> case checkTypeParamCollisions program of
          Left collisionErr -> die ("type error: " <> show collisionErr)
          Right _ -> case analyzeToJson libs program subcommand of
            Left typeErr -> die ("type error: " <> show typeErr)
            Right result -> log (stringify result)

analyzeToJson :: LibraryTable -> Program -> AnalyzeSubcommand -> Either TypeError Json
analyzeToJson libs prog AnalyzeImports = Right (stringSetToJson (transitiveImportNames libs prog))
analyzeToJson libs prog AnalyzeActions = Right (stringSetToJson (deepActionKeys libs prog))
analyzeToJson libs prog AnalyzeHoles = Right (pathSetToJson (deepContextHoles libs prog))
analyzeToJson libs prog AnalyzeUnsupplied = Right (unsuppliedToJson (unsuppliedParams libs prog) (unsuppliedTypeParams libs prog))
analyzeToJson libs prog AnalyzeConstraints = do
  let kinds = stringSetToJson (deepConstraintKinds libs prog)
  constraints <- typeConstraintsToJson <$> deepTypeConstraints libs prog
  Right (fromObject (Object.fromFoldable [ Tuple "kinds" kinds, Tuple "typeConstraints" constraints ]))
analyzeToJson libs prog AnalyzeSymbols = Right
  ( fromObject
      ( Object.fromFoldable
          [ Tuple "sites" (intSetToJson (symbolSites prog))
          , Tuple "demands" (pathSetToJson (deepSymbolDemands libs prog))
          ]
      )
  )
analyzeToJson libs prog AnalyzeTypes = do
  references <- stringSetToJson <$> deepTypeReferences libs prog
  constraints <- typeConstraintsToJson <$> deepTypeConstraints libs prog
  Right
    ( fromObject
        ( Object.fromFoldable
            [ Tuple "declarations" (stringSetToJson (typeDeclarations prog))
            , Tuple "params" (pathSetToJson (typeParams prog))
            , Tuple "references" references
            , Tuple "constraints" constraints
            ]
        )
    )
analyzeToJson libs prog AnalyzeAll = do
  constraintsBlock <- analyzeToJson libs prog AnalyzeConstraints
  typesBlock <- analyzeToJson libs prog AnalyzeTypes
  Right
    ( fromObject
        ( Object.fromFoldable
            [ Tuple "imports" (stringSetToJson (transitiveImportNames libs prog))
            , Tuple "actions" (stringSetToJson (deepActionKeys libs prog))
            , Tuple "holes" (pathSetToJson (deepContextHoles libs prog))
            , Tuple "unsupplied" (unsuppliedToJson (unsuppliedParams libs prog) (unsuppliedTypeParams libs prog))
            , Tuple "constraints" constraintsBlock
            , Tuple "symbols"
                ( fromObject
                    ( Object.fromFoldable
                        [ Tuple "sites" (intSetToJson (symbolSites prog))
                        , Tuple "demands" (pathSetToJson (deepSymbolDemands libs prog))
                        ]
                    )
                )
            , Tuple "types" typesBlock
            ]
        )
    )

-- | Reads and parses each `--lib name=path` file into a `LibraryTable`.
-- | No mode detection: v1 had to try the element-rooted parser and fall
-- | back to the expression-rooted one, but v2 has a single `parseProgram`
-- | that decides which kind of program it read from the root's own form.
loadLibraries :: Array (Tuple String String) -> Effect (Either String LibraryTable)
loadLibraries specs = go specs Map.empty
  where
  go :: Array (Tuple String String) -> LibraryTable -> Effect (Either String LibraryTable)
  go remaining acc = case uncons remaining of
    Nothing -> pure (Right acc)
    Just { head: Tuple name path, tail: rest } -> do
      src <- readTextFile UTF8 path
      case parseLibrarySource src of
        Left err -> pure (Left ("library \"" <> name <> "\" (" <> path <> "): " <> err))
        Right libProg -> go rest (Map.insert name libProg acc)

  parseLibrarySource :: String -> Either String Program
  parseLibrarySource src = case parseProgram src of
    Right p -> Right p
    Left err -> Left (show err)

-- JSON helpers ---------------------------------------------------------------
stringSetToJson :: Set String -> Json
stringSetToJson = fromArray <<< map fromString <<< Set.toUnfoldable

pathSetToJson :: Set (Array String) -> Json
pathSetToJson = fromArray <<< map (fromArray <<< map fromString) <<< Set.toUnfoldable

intSetToJson :: Set Int -> Json
intSetToJson = fromArray <<< map (fromNumber <<< Int.toNumber) <<< Set.toUnfoldable
unsuppliedToJson :: Array (Tuple String (Set (Array String))) -> Array (Tuple String (Set (Array String))) -> Json
unsuppliedToJson valueParams typeParams' = fromArray (zipWith entry valueParams typeParams')
  where
  entry (Tuple name vMissing) (Tuple _ tMissing) =
    fromObject
      ( Object.fromFoldable
          [ Tuple "name" (fromString name)
          , Tuple "valueParams" (pathSetToJson vMissing)
          , Tuple "typeParams" (pathSetToJson tMissing)
          ]
      )

typeConstraintsToJson :: Array (Tuple String (Array ResolvedConstraintArg)) -> Json
typeConstraintsToJson = fromArray <<< map constraintEntry
  where
  constraintEntry (Tuple name args) =
    fromObject
      ( Object.fromFoldable
          [ Tuple "name" (fromString name)
          , Tuple "arguments" (fromArray (map resolvedConstraintArgToJson args))
          ]
      )

resolvedConstraintArgToJson :: ResolvedConstraintArg -> Json
resolvedConstraintArgToJson (RCType rt) = fromObject (Object.fromFoldable [ Tuple "$type" (fromString (canonicalId rt)) ])
resolvedConstraintArgToJson (RCScalarStr s) = fromString s
resolvedConstraintArgToJson (RCScalarNum n) = fromNumber n
resolvedConstraintArgToJson (RCScalarBool b) = fromBoolean b
resolvedConstraintArgToJson RCScalarNull = jsonNull

die :: forall a. String -> Effect a
die msg = do
  error msg
  exit' 1
