-- | Runs the shared cross-implementation corpus at `corpus/cases` (see
-- | `corpus/README.md`), the counterpart of
-- | `tramaj-hs/test/unit/Tramaj/CorpusSpec.hs`. A case here is
-- | byte-equality between two independently written implementations, not
-- | merely "this implementation agrees with itself" -- see
-- | `roadmap-to-v4` Phase 0.
module Test.Corpus (runCorpus) where

import Prelude

import Data.Argonaut.Core (Json, stringify, toObject, toString)
import Data.Argonaut.Parser (jsonParser)
import Data.Array (sort)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (traverse_)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
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
import Tramaj.Ast (Program)
import Tramaj.Eval (EvalError, LibraryTable, Mode(..), evalProgram, runProgram)
import Tramaj.Parser (parseProgram)

corpusRoot :: String
corpusRoot = "corpus/cases"

runCorpus :: Effect Unit
runCorpus = do
  names <- sort <$> readdir corpusRoot
  dirs <- Array.filterA (\n -> isDirectory <$> stat (corpusRoot <> "/" <> n)) names
  traverse_ runCase dirs
  log ("ok - " <> show (Array.length dirs) <> " shared corpus cases")

modeFromField :: String -> String -> Effect Mode
modeFromField name m = case m of
  "concrete" -> pure Concrete
  "symbolic" -> pure Symbolic
  other -> throw (name <> ": unknown mode " <> other)

-- | `"kind"` is part of the format (corpus/README.md) but not read here: a
-- successful run's shape is checked by comparing against `expected.json`
-- wholesale, via `runProgram`, which already reflects the mode and (once §4
-- lands) the kind in what it produces.
runCase :: String -> Effect Unit
runCase name = do
  let dir = corpusRoot <> "/" <> name
  meta <- mustParseJsonFile (name <> "/meta.json") (dir <> "/meta.json")
  modeField <- field meta "mode"
  mode <- modeFromField name modeField
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
      case evalProgram mode libs ctx program of
        Right _ -> throw (name <> ": expected eval error " <> errorKind <> ", but evaluation succeeded")
        Left err ->
          let actualKind = errorConstructor err
          in if actualKind == errorKind then pure unit
             else throw (name <> ": expected eval error " <> errorKind <> ", got " <> actualKind <> " (" <> show err <> ")")
    "success" -> do
      ctx <- mustParseJsonFile (name <> "/ctx.json") (dir <> "/ctx.json")
      expected <- mustParseJsonFile (name <> "/expected.json") (dir <> "/expected.json")
      program <- mustParse name templateSrc
      case runProgram mode libs ctx program of
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

optionalField :: Json -> String -> Effect (Maybe String)
optionalField j key = pure (toObject j >>= Object.lookup key >>= toString)

mustParse :: String -> String -> Effect Program
mustParse label src = case parseProgram src of
  Left err -> throw (label <> ": parse failed: " <> show err)
  Right p -> pure p

mustParseJsonFile :: String -> String -> Effect Json
mustParseJsonFile label path = do
  src <- readTextFile UTF8 path
  case jsonParser src of
    Left err -> throw (label <> ": not valid JSON: " <> err)
    Right j -> pure j
