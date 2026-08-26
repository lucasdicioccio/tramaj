-- | Standalone CLI over the `tramaj` package's parser/eval core —
-- | takes a template file and a JSON context file, prints the resulting
-- | AST (`Tramaj.Ast.nodeToJson`) to stdout, or a parse/eval error to
-- | stderr with a non-zero exit code. Any number of `--lib name=path` flags
-- | register a host-supplied `LibraryTable`, letting the template use
-- | `import(name, ...)`/`partial-import(name, ...)` against files on disk.
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
import Tramaj.Ast (nodeToJson)
import Tramaj.Eval (LibrarySource(..), LibraryTable, evalProgram)
import Tramaj.Parser (parseJsonProgram, parseProgram)

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
          Right program -> case evalProgram libs ctxJson program of
            Left err -> die ("eval error: " <> show err)
            Right node -> log (stringify (nodeToJson node))

-- | Reads and parses each `--lib name=path` file into a `LibraryTable`.
-- | Auto-detects a library's mode by trying `parseProgram` (element-rooted,
-- | template mode) first, falling back to `parseJsonProgram` (expr-rooted,
-- | JSON mode) on failure — unambiguous, since an element root always
-- | starts with `.`, which no `expr` alternative does (the same fact the
-- | parser itself relies on to disambiguate the two top-level modes).
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
        Right libSrc -> go rest (Map.insert name libSrc acc)

  parseLibrarySource :: String -> Either String LibrarySource
  parseLibrarySource src = case parseProgram src of
    Right p -> Right (ProgramSource p)
    Left progErr -> case parseJsonProgram src of
      Right jp -> Right (JsonSource jp)
      Left jsonErr -> Left ("failed to parse as a template (" <> show progErr <> ") or as JSON-mode (" <> show jsonErr <> ")")

die :: forall a. String -> Effect a
die msg = do
  error msg
  exit' 1
