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
import Data.Maybe (Maybe(..))
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
import Tramaj.Eval (LibraryTable, Output(..), evalProgram)
import Tramaj.Node (nodeToJson)
import Tramaj.Parser (parseProgram)

corpusRoot :: String
corpusRoot = "corpus/cases"

runCorpus :: Effect Unit
runCorpus = do
  names <- sort <$> readdir corpusRoot
  dirs <- Array.filterA (\n -> isDirectory <$> stat (corpusRoot <> "/" <> n)) names
  traverse_ runCase dirs
  log ("ok - " <> show (Array.length dirs) <> " shared corpus cases")

runCase :: String -> Effect Unit
runCase name = do
  let dir = corpusRoot <> "/" <> name
  meta <- mustParseJsonFile (name <> "/meta.json") (dir <> "/meta.json")
  kind <- field meta "kind"
  mode <- field meta "mode"
  when (mode /= "concrete") $ throw (name <> ": unsupported mode " <> mode <> " (only \"concrete\" has a runner so far)")
  templateSrc <- readTextFile UTF8 (dir <> "/template.tramaj")
  ctx <- mustParseJsonFile (name <> "/ctx.json") (dir <> "/ctx.json")
  expected <- mustParseJsonFile (name <> "/expected.json") (dir <> "/expected.json")
  libs <- readLibs dir
  program <- mustParse name templateSrc
  case evalProgram libs ctx program of
    Left err -> throw (name <> ": eval failed: " <> show err)
    Right output -> do
      actual <- case output, kind of
        ONode n, "document" -> pure (nodeToJson n)
        OValue v, "expression" -> pure v
        ONode _, "expression" -> throw (name <> ": expected a value, got a document")
        OValue v, "document" -> throw (name <> ": expected a document, got the value " <> stringify v)
        _, other -> throw (name <> ": unknown kind " <> other)
      if actual == expected then pure unit
      else
        throw
          ( name <> ": mismatch\n  expected: " <> stringify expected
              <> "\n  actual:   "
              <> stringify actual
          )

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
