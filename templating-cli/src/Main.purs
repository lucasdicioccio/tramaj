-- | Standalone CLI over the `templating` package's parser/eval core
-- | takes a template file and a JSON context file, prints the resulting
-- | AST (`Templating.Ast.nodeToJson`) to stdout, or a parse/eval error to
-- | stderr with a non-zero exit code.
-- |
-- | Deliberately depends on `templating` only, not `templating-halogen` —
-- | this never folds to real Halogen output, so it doesn't need a DOM/
-- | browser runtime at all, just Node's `fs`.
module Main (main) where

import Prelude

import Data.Argonaut.Core (stringify)
import Data.Argonaut.Parser (jsonParser)
import Data.Array (drop)
import Data.Either (Either(..))
import Effect (Effect)
import Effect.Class.Console (log, error)
import Node.Encoding (Encoding(UTF8))
import Node.FS.Sync (readTextFile)
import Node.Process (argv, exit')
import Templating.Ast (nodeToJson)
import Templating.Eval (evalProgram)
import Templating.Parser (parseProgram)

main :: Effect Unit
main = do
  args <- drop 2 <$> argv
  case args of
    [ templatePath, ctxPath ] -> run templatePath ctxPath
    _ -> die "usage: templating-cli <template-file> <context-json-file>"

run :: String -> String -> Effect Unit
run templatePath ctxPath = do
  templateSrc <- readTextFile UTF8 templatePath
  ctxSrc <- readTextFile UTF8 ctxPath
  case jsonParser ctxSrc of
    Left err -> die ("invalid JSON context (" <> ctxPath <> "): " <> err)
    Right ctxJson -> case parseProgram templateSrc of
      Left err -> die ("parse error (" <> templatePath <> "): " <> show err)
      Right program -> case evalProgram ctxJson program of
        Left err -> die ("eval error: " <> show err)
        Right node -> log (stringify (nodeToJson node))

die :: forall a. String -> Effect a
die msg = do
  error msg
  exit' 1
