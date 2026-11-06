-- | @tramaj-hpdf TEMPLATE CONTEXT.json OUT.pdf@ evaluates a template against
-- a JSON context (concrete mode, no libraries) and writes the document as a
-- PDF.
--
-- @tramaj-hpdf --node NODE.json OUT.pdf@ reads an already-evaluated node in
-- the normative Node JSON representation (@specs/node-json.md@), e.g. what
-- another implementation's CLI printed.
--
-- A relative @img src@ is read from the directory of the template (or of
-- the node file).
--
-- Options, before the arguments:
--
-- * @--fonts DIR@: a Noto Sans directory to embed the fonts from, instead
--   of the ones bundled with the library.
-- * @--missing-glyphs warn|error@: a character the fonts have no glyph for
--   is drawn as a replacement character and listed on stderr (@warn@, the
--   default), or makes the command fail without writing the PDF (@error@).
module Main (main) where

import qualified Data.Map.Strict as Map
import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.IO.Error (catchIOError, ioeGetErrorString, isUserError)
import Text.Megaparsec (errorBundlePretty)
import Tramaj.Eval (Mode (..), Output (..), evalProgram)
import System.FilePath (takeDirectory)
import Tramaj.Hpdf (MissingGlyphs (..), Options (..), defaultOptions, renderPdfToFile)
import Tramaj.Json (jsonParser)
import Tramaj.Node (Node, nodeFromJson)
import Tramaj.Parser (parseProgram)

main :: IO ()
main = do
  (opts, rest) <- either die' pure . options defaultOptions =<< getArgs
  case rest of
    ["--node", nodePath, out] -> do
      src <- TIO.readFile nodePath
      node <- orDie nodePath (jsonParser src >>= nodeFromJson)
      render out opts {optBaseDir = takeDirectory nodePath} node
    [tmplPath, ctxPath, out] -> do
      tmpl <- TIO.readFile tmplPath
      ctxSrc <- TIO.readFile ctxPath
      prog <- either (die' . errorBundlePretty) pure (parseProgram tmpl)
      ctx <- orDie ctxPath (jsonParser ctxSrc)
      node <- case evalProgram Concrete Map.empty ctx prog of
        Left err -> die' (show err)
        Right (ONode n) -> pure n
        Right (OValue _) -> die' "the template evaluates to a value, not a document"
      render out opts {optBaseDir = takeDirectory tmplPath} (node :: Node)
    _ -> die' usage
  where
    options o = \case
      "--fonts" : dir : more -> options o {optFontDir = Just dir} more
      "--missing-glyphs" : "warn" : more -> options o {optMissingGlyphs = WarnMissingGlyphs} more
      "--missing-glyphs" : "error" : more -> options o {optMissingGlyphs = FailOnMissingGlyphs} more
      "--missing-glyphs" : _ -> Left "--missing-glyphs takes warn or error"
      more -> Right (o, more)
    usage =
      "usage: tramaj-hpdf [--fonts NOTO_DIR] [--missing-glyphs warn|error] TEMPLATE CONTEXT.json OUT.pdf\n\
      \       tramaj-hpdf [--fonts NOTO_DIR] [--missing-glyphs warn|error] --node NODE.json OUT.pdf"

    -- 'renderPdfToFile' fails with a message of its own; print it alone.
    render out o n = renderPdfToFile out o n `catchIOError` \e ->
      die' (if isUserError e then ioeGetErrorString e else show e)
    orDie what = either (\e -> die' (what <> ": " <> e)) pure
    die' msg = hPutStrLn stderr msg >> exitFailure
