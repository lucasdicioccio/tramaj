-- | Standalone CLI over the `tramaj` package's parser/eval core — takes a
-- | template file and a JSON context file, prints the result to stdout, or
-- | a parse/eval error to stderr with a non-zero exit code. Any number of
-- | `--lib name=path` flags register a host-supplied `LibraryTable`,
-- | letting the template use `import(name, ...)` against files on disk.
-- |
-- | A document-rooted program prints the normative `specs/node-json.md`
-- | representation; an expression-rooted one prints the plain JSON value it
-- | evaluated to. Which it is follows from what the program's root produced,
-- | so there is no mode flag — and libraries need no mode detection either,
-- | since v2 has one `parseProgram` covering both.
-- |
-- | Deliberately depends on `tramaj` only, not `tramaj-halogen` —
-- | this never folds to real Halogen output, so it doesn't need a DOM/
-- | browser runtime at all, just Node's `fs`.
module Main (main) where

import Prelude

import Data.Argonaut.Core (stringify)
import Data.Argonaut.Parser (jsonParser)
import Data.Array (drop, uncons)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), drop, indexOf, take) as Str
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Class.Console (log, error)
import Node.Encoding (Encoding(UTF8))
import Node.FS.Sync (readTextFile)
import Node.Process (argv, exit')
import Tramaj.Eval (LibraryTable, Mode(Concrete), Output(..), evalProgram)
import Tramaj.Ast (Program)
import Tramaj.Node (nodeToJson)
import Tramaj.Parser (parseProgram)

usage :: String
usage = "usage: tramaj-cli [--lib name=path ...] <template-file> <context-json-file>"

main :: Effect Unit
main = do
  args <- drop 2 <$> argv
  case parseArgs args of
    Left err -> die (err <> "\n" <> usage)
    Right { libSpecs, positional } -> case positional of
      [ templatePath, ctxPath ] -> run libSpecs templatePath ctxPath
      _ -> die usage

-- | Splits `argv` into `--lib name=path` pairs (order preserved, repeatable)
-- | and every other token, which must be exactly the two positional
-- | arguments (template file, context JSON file) once every `--lib` pair is
-- | removed.
parseArgs :: Array String -> Either String { libSpecs :: Array (Tuple String String), positional :: Array String }
parseArgs = go { libSpecs: [], positional: [] }
  where
  go acc argsList = case uncons argsList of
    Nothing -> Right acc
    Just { head: "--lib", tail: rest } -> case uncons rest of
      Nothing -> Left "--lib expects a following name=path argument"
      Just { head: spec, tail: rest' } -> case splitOnFirst "=" spec of
        Nothing -> Left ("--lib expects name=path, got: " <> spec)
        Just (Tuple name path) -> go (acc { libSpecs = Array.snoc acc.libSpecs (Tuple name path) }) rest'
    Just { head, tail: rest } -> go (acc { positional = Array.snoc acc.positional head }) rest

  splitOnFirst :: String -> String -> Maybe (Tuple String String)
  splitOnFirst sep s = case Str.indexOf (Str.Pattern sep) s of
    Nothing -> Nothing
    Just i -> Just (Tuple (Str.take i s) (Str.drop (i + 1) s))

run :: Array (Tuple String String) -> String -> String -> Effect Unit
run libSpecs templatePath ctxPath = do
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
          Right program -> case evalProgram Concrete libs ctxJson program of
            Left err -> die ("eval error: " <> show err)
            Right (ONode node) -> log (stringify (nodeToJson node))
            Right (OValue value) -> log (stringify value)

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
        Right prog -> go rest (Map.insert name prog acc)

  parseLibrarySource :: String -> Either String Program
  parseLibrarySource src = case parseProgram src of
    Right p -> Right p
    Left err -> Left (show err)

die :: forall a. String -> Effect a
die msg = do
  error msg
  exit' 1
