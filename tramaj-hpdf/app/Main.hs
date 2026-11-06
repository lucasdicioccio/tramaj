-- | @tramaj-hpdf TEMPLATE CONTEXT.json OUT.pdf@ evaluates a template against
-- a JSON context (concrete mode, no libraries) and writes the document as a
-- PDF.
--
-- @tramaj-hpdf --node NODE.json OUT.pdf@ reads an already-evaluated node in
-- the normative Node JSON representation (@specs/node-json.md@), e.g. what
-- another implementation's CLI printed.
module Main (main) where

import qualified Data.Map.Strict as Map
import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Text.Megaparsec (errorBundlePretty)
import Tramaj.Eval (Mode (..), Output (..), evalProgram)
import Tramaj.Hpdf (defaultOptions, renderPdfToFile)
import Tramaj.Json (jsonParser)
import Tramaj.Node (Node, nodeFromJson)
import Tramaj.Parser (parseProgram)

main :: IO ()
main =
  getArgs >>= \case
    ["--node", nodePath, out] -> do
      src <- TIO.readFile nodePath
      node <- orDie nodePath (jsonParser src >>= nodeFromJson)
      renderPdfToFile out defaultOptions node
    [tmplPath, ctxPath, out] -> do
      tmpl <- TIO.readFile tmplPath
      ctxSrc <- TIO.readFile ctxPath
      prog <- either (die' . errorBundlePretty) pure (parseProgram tmpl)
      ctx <- orDie ctxPath (jsonParser ctxSrc)
      node <- case evalProgram Concrete Map.empty ctx prog of
        Left err -> die' (show err)
        Right (ONode n) -> pure n
        Right (OValue _) -> die' "the template evaluates to a value, not a document"
      renderPdfToFile out defaultOptions (node :: Node)
    _ -> die' "usage: tramaj-hpdf TEMPLATE CONTEXT.json OUT.pdf\n       tramaj-hpdf --node NODE.json OUT.pdf"
  where
    orDie what = either (\e -> die' (what <> ": " <> e)) pure
    die' msg = hPutStrLn stderr msg >> exitFailure
