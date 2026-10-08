-- | Runs the shared cross-implementation corpus at `corpus/cases` (see
-- | `corpus/README.md`), the counterpart of
-- | `tramaj-hs/test/unit/Tramaj/CorpusSpec.hs`. A case here is
-- | byte-equality between two independently written implementations, not
-- | merely "this implementation agrees with itself" -- see
-- | `roadmap-to-v4` Phase 0.
module Test.Corpus (runCorpus) where

import Prelude

import Data.Array (sort)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (traverse_)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.Set (Set)
import Data.Set as Set
import Data.String (Pattern(..))
import Data.String as String
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Class.Console (log)
import Effect.Exception (throw)
import Foreign.Object as Object
import Node.Encoding (Encoding(UTF8))
import Node.FS.Stats (isDirectory)
import Node.FS.Sync (exists, readTextFile, readdir, stat)
import Tramaj.Analysis (arithmeticOps, contextHoles, contextReads, deepActionKeys, deepArithmeticOps, deepContextHoles, staticActionKeys, staticImportNames, transitiveImportNames)
import Tramaj.Ast (Program)
import Tramaj.Eval (EvalError, LibraryTable, Mode(..), Options, runProgramWith)
import Tramaj.Json (Json, jsonParser, stringify, toArray, toObject, toString)
import Tramaj.Parser (parseProgram)

corpusRoot :: String
corpusRoot = "corpus/cases"

-- | The profiles (`profiles` in `meta.json`, see `corpus/README.md`) this
-- port can provide. A case naming any other one is skipped.
--
-- `base`: the language without any profile, which every port provides.
-- `int-float`: integers and floats are two types (a transition tag, not a
-- profile). `arithmetic`: the arithmetic profile, which is a per-evaluation
-- option here (see `optionsFor`). `int53`: integers have the guaranteed
-- 53-bit range only (`Tramaj.Json`), so not `int64`.
providedProfiles :: Array String
providedProfiles = [ "base", "int-float", "arithmetic", "int53" ]

-- | The options a case runs with. A profile is on for a case only if the
-- case lists it, so a case that does not list `arithmetic` runs without it,
-- and `sum(1, 2)` is an `UnboundName` there.
optionsFor :: Mode -> Json -> Options
optionsFor mode meta = { mode, arithmetic: Array.elem "arithmetic" (profiles meta) }

-- | The result of a static analysis, in the two shapes `analysis.json` holds:
-- a set of names, or a set of paths.
data AnalysisResult
  = Names (Set String)
  | Paths (Set (Array String))

derive instance eqAnalysisResult :: Eq AnalysisResult

-- | The static analyses (reference.md §9) this port provides to an
-- `"expect": "analysis"` case, by the name `analysis.json` gives them. A
-- case naming any other one is skipped.
providedAnalyses :: Map.Map String (LibraryTable -> Program -> AnalysisResult)
providedAnalyses = Map.fromFoldable
  [ Tuple "staticImportNames" (\_ p -> Names (staticImportNames p))
  , Tuple "transitiveImportNames" (\libs p -> Names (transitiveImportNames libs p))
  , Tuple "staticActionKeys" (\_ p -> Names (staticActionKeys p))
  , Tuple "deepActionKeys" (\libs p -> Names (deepActionKeys libs p))
  , Tuple "contextHoles" (\_ p -> Paths (contextHoles p))
  , Tuple "deepContextHoles" (\libs p -> Paths (deepContextHoles libs p))
  , Tuple "contextReads" (\_ p -> Paths (contextReads p))
  , Tuple "arithmeticOps" (\_ p -> Names (arithmeticOps p))
  , Tuple "deepArithmeticOps" (\libs p -> Names (deepArithmeticOps libs p))
  ]

-- | What `runCase` did with a case. A failing case throws instead.
data Outcome
  = Passed
  -- | Not run: the case names these profiles (or, written `analysis <name>`,
  -- these analyses), which this port does not provide.
  | Skipped (Array String)

runCorpus :: Effect Unit
runCorpus = do
  names <- sort <$> readdir corpusRoot
  dirs <- Array.filterA (\n -> isDirectory <$> stat (corpusRoot <> "/" <> n)) names
  outcomes <- traverse (\n -> Tuple n <$> runCase (corpusRoot <> "/" <> n) n) dirs
  let
    skipped = Array.mapMaybe
      ( \(Tuple n o) -> case o of
          Passed -> Nothing
          Skipped missing -> Just (Tuple n missing)
      )
      outcomes
  traverse_ (\(Tuple n missing) -> log ("skip - " <> n <> " (not provided: " <> String.joinWith ", " missing <> ")")) skipped
  log
    ( "ok - " <> show (Array.length dirs - Array.length skipped) <> " shared corpus cases"
        <> if Array.null skipped then "" else ", " <> show (Array.length skipped) <> " skipped"
    )
  checkUnprovidedProfileIsSkipped

-- | `corpus/runner-checks/unsupported-profile` would fail if it ran: its
-- `expected.json` does not match what the template evaluates to.
checkUnprovidedProfileIsSkipped :: Effect Unit
checkUnprovidedProfileIsSkipped = do
  let name = "unsupported-profile"
  outcome <- runCase ("corpus/runner-checks/" <> name) name
  case outcome of
    Skipped [ "never-declared" ] -> log "ok - a case naming a profile this port does not provide is skipped"
    Skipped other -> throw (name <> ": skipped for the wrong profiles: " <> show other)
    Passed -> throw (name <> ": expected the case to be skipped, but it ran")

modeFromField :: String -> String -> Effect Mode
modeFromField name m = case m of
  "concrete" -> pure Concrete
  "symbolic" -> pure Symbolic
  other -> throw (name <> ": unknown mode " <> other)

-- | `"kind"` is part of the format (corpus/README.md) but not read here: a
-- successful run's shape is checked by comparing against `expected.json`
-- wholesale, via `runProgram`, which already reflects the mode and (once §4
-- lands) the kind in what it produces.
runCase :: String -> String -> Effect Outcome
runCase dir name = do
  meta <- mustParseJsonFile (name <> "/meta.json") (dir <> "/meta.json")
  when (isJust (toObject meta >>= Object.lookup "requires"))
    (throw (name <> ": \"requires\" was replaced by \"profiles\" (corpus/README.md)"))
  expect <- fromMaybe "success" <$> optionalField meta "expect"
  let missingProfiles = Array.filter (\r -> not (Array.elem r providedProfiles)) (profiles meta)
  if expect == "analysis" then do
    -- The names are the keys of `analysis.json`, which holds no number, so
    -- reading it before deciding to skip is safe on every port.
    expected <- mustParseJsonFile (name <> "/analysis.json") (dir <> "/analysis.json")
    entries <- case toObject expected of
      Just o -> pure (Object.toUnfoldable o :: Array (Tuple String Json))
      Nothing -> throw (name <> ": analysis.json is not an object")
    let
      missingAnalyses = Array.filter (\(Tuple k _) -> not (Map.member k providedAnalyses)) entries
      missing = missingProfiles <> map (\(Tuple k _) -> "analysis " <> k) missingAnalyses
    if Array.null missing then Passed <$ runAnalysisCase dir name entries
    else pure (Skipped missing)
  else case missingProfiles of
    [] -> Passed <$ runSupportedCase dir name meta
    missing -> pure (Skipped missing)

-- | An `"expect": "analysis"` case: no context and no evaluation. Each named
-- analysis runs over the parsed template (and `libs/`, for a deep variant)
-- and its result is compared, as a set, with the array `analysis.json` gives.
runAnalysisCase :: String -> String -> Array (Tuple String Json) -> Effect Unit
runAnalysisCase dir name entries = do
  templateSrc <- readTextFile UTF8 (dir <> "/template.tramaj")
  libs <- readLibs dir
  program <- mustParse name templateSrc
  traverse_ (checkAnalysis libs program) entries
  where
  checkAnalysis libs program (Tuple key expectedJson) = case Map.lookup key providedAnalyses of
    Nothing -> throw (name <> ": unknown analysis " <> key)
    Just analysis -> do
      let actual = analysis libs program
      expected <- case decodeExpected actual expectedJson of
        Just e -> pure e
        Nothing -> throw (name <> ": analysis.json: " <> key <> " is not an array of distinct " <> shapeName actual)
      if actual == expected then pure unit
      else throw (name <> ": " <> key <> " mismatch\n  expected: " <> stringify expectedJson <> "\n  actual:   " <> showResult actual)

  -- Decoded in the shape of the actual result, since `[]` alone does not say
  -- which of the two it is. A repeated element is refused: the file is a set.
  decodeExpected actual j = do
    xs <- toArray j
    case actual of
      Names _ -> do
        names <- traverse toString xs
        let set = Set.fromFoldable names
        if Set.size set == Array.length names then Just (Names set) else Nothing
      Paths _ -> do
        paths <- traverse (\x -> toArray x >>= traverse toString) xs
        let set = Set.fromFoldable paths
        if Set.size set == Array.length paths then Just (Paths set) else Nothing

  shapeName (Names _) = "strings"
  shapeName (Paths _) = "arrays of strings"

  showResult (Names s) = show (Set.toUnfoldable s :: Array String)
  showResult (Paths s) = show (Set.toUnfoldable s :: Array (Array String))

runSupportedCase :: String -> String -> Json -> Effect Unit
runSupportedCase dir name meta = do
  modeField <- field meta "mode"
  mode <- modeFromField name modeField
  let options = optionsFor mode meta
  expect <- fromMaybe "success" <$> optionalField meta "expect"
  templateSrc <- readTextFile UTF8 (dir <> "/template.tramaj")
  libs <- readLibs dir
  case expect of
    "parse-error" -> case parseProgram templateSrc of
      Left _ -> pure unit
      Right _ -> throw (name <> ": expected a parse error, but the template parsed")
    "eval-error" -> do
      errorKind <- field meta "errorKind"
      ctx <- mustParseJsonFile (name <> "/ctx.json") (dir <> "/ctx.json")
      program <- mustParse name templateSrc
      -- `runProgramWith`, like a success case and as corpus/README.md says
      -- of `mode`: in symbolic mode a static type error can come from
      -- building the envelope's `"types"` table, after an evaluation that
      -- itself succeeds (case 164), and `evalProgramWith` stops before that.
      case runProgramWith options libs ctx program of
        Right _ -> throw (name <> ": expected eval error " <> errorKind <> ", but evaluation succeeded")
        Left err ->
          let actualKind = errorConstructor err
          in if actualKind == errorKind then pure unit
             else throw (name <> ": expected eval error " <> errorKind <> ", got " <> actualKind <> " (" <> show err <> ")")
    "success" -> do
      ctx <- mustParseJsonFile (name <> "/ctx.json") (dir <> "/ctx.json")
      expected <- mustParseJsonFile (name <> "/expected.json") (dir <> "/expected.json")
      program <- mustParse name templateSrc
      case runProgramWith options libs ctx program of
        Left err -> throw (name <> ": eval failed: " <> show err)
        Right actual ->
          if actual == expected then pure unit
          else
            throw
              ( name <> ": mismatch\n  expected: " <> stringify expected
                  <> "\n  actual:   "
                  <> stringify actual
              )
    other -> throw (name <> ": unknown expect " <> other)

-- | The constructor name an `EvalError`'s `Show` instance leads with -- every
-- constructor is written as `Name arg1 arg2 ...`, so the first
-- whitespace-delimited word is unambiguous. Kept to this rather than a
-- dedicated projection so a new `EvalError` constructor needs no matching
-- addition here.
errorConstructor :: EvalError -> String
errorConstructor err = fromMaybe (show err) (Array.head (String.split (Pattern " ") (show err)))

readLibs :: String -> Effect LibraryTable
readLibs dir = do
  let libsDir = dir <> "/libs"
  present <- exists libsDir
  if not present then pure Map.empty
  else do
    names <- readdir libsDir
    let libNames = Array.filter (\n -> String.contains (Pattern ".tramaj") n) names
    entries <- traverse (\n -> do
      src <- readTextFile UTF8 (libsDir <> "/" <> n)
      program <- mustParse (dir <> "/libs/" <> n) src
      pure (Tuple (dropSuffix ".tramaj" n) program)) libNames
    pure (Map.fromFoldable entries)
  where
  dropSuffix suffix s = case String.stripSuffix (Pattern suffix) s of
    Just s' -> s'
    Nothing -> s

field :: Json -> String -> Effect String
field j key = case toObject j >>= Object.lookup key >>= toString of
  Just s -> pure s
  Nothing -> throw ("meta.json: missing or non-string field " <> key)

-- | The optional `profiles` list; absent means the base language alone.
profiles :: Json -> Array String
profiles j = fromMaybe [] (toObject j >>= Object.lookup "profiles" >>= toArray >>= traverse toString)

optionalField :: Json -> String -> Effect (Maybe String)
optionalField j key = pure (toObject j >>= Object.lookup key >>= toString)

mustParse :: String -> String -> Effect Program
mustParse label src = case parseProgram src of
  Left err -> throw (label <> ": parse failed: " <> show err)
  Right p -> pure p

-- | Reads a fixture with `Tramaj.Json.jsonParser`, which types each number
-- by its text, so `3` and `3.0` in `ctx.json` are two contexts and in
-- `expected.json` two expected values (corpus/README.md). `Json` equality
-- never equates an integer with a float, so comparing the parsed
-- `expected.json` with a result is comparing the text of every number, up
-- to the spelling of one value of one type (`1.0`, `1.00` and `1e0` are the
-- same float). The parser refuses no number: an out-of-range one in
-- `ctx.json` reaches the evaluator, whose refusal is what such a case
-- tests.
mustParseJsonFile :: String -> String -> Effect Json
mustParseJsonFile label path = do
  src <- readTextFile UTF8 path
  case jsonParser src of
    Left err -> throw (label <> ": not valid JSON: " <> err)
    Right j -> pure j
