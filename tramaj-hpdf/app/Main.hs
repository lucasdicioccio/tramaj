-- | @tramaj-hpdf [FLAGS] TEMPLATE CONTEXT.json OUT.pdf@ evaluates a template
-- against a JSON context (concrete mode, no libraries) and writes the
-- document as a PDF.
--
-- @tramaj-hpdf [FLAGS] --node NODE.json OUT.pdf@ reads an already-evaluated
-- node in the normative Node JSON representation (@specs/node-json.md@),
-- e.g. what another implementation's CLI printed.
--
-- @tramaj-hpdf --xml TEMPLATE CONTEXT.json OUT.xml@ writes the evaluated
-- template as XML ("Tramaj.Hpdf.Xml").
--
-- A relative @img src@ is read from the directory of the template (or of
-- the node file).
--
-- Flags, before the arguments:
--
-- * @--fonts DIR@: a Noto Sans directory to embed the fonts from, instead
--   of the ones bundled with the library.
-- * @--missing-glyphs warn|error@: a character the fonts have no glyph for
--   is drawn as a replacement character and listed on stderr (@warn@, the
--   default), or makes the command fail without writing the PDF (@error@).
-- * @--title TEXT@, @--author TEXT@: the document's metadata.
-- * @--factur-x XML_TEMPLATE@: write a Factur-X invoice, PDF\/A-3b with
--   the template evaluated against the same context, as XML, attached as
--   @factur-x.xml@. @--factur-x-xml FILE@ attaches an XML file as it is
--   instead. @--factur-x-level LEVEL@ (default @BASIC@), @--icc FILE@
--   (default colord's sRGB profile) and @--xml-out FILE@ (also write the
--   attached XML there) go with it.
module Main (main) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)
import System.IO (hPutStrLn, stderr)
import System.IO.Error (catchIOError, ioeGetErrorString, isUserError)
import Text.Megaparsec (errorBundlePretty)
import Tramaj.Eval (Mode (..), Output (..), evalProgram)
import Tramaj.Hpdf (MissingGlyphs (..), Options (..), defaultOptions, facturX, renderPdfToFile, srgbProfile)
import Tramaj.Hpdf.Xml (renderXml)
import Tramaj.Json (Json, jsonParser)
import Tramaj.Node (Node, nodeFromJson)
import Tramaj.Parser (parseProgram)

data Flags = Flags
  { fFonts :: Maybe FilePath
  , fMissingGlyphs :: MissingGlyphs
  , fTitle :: Text
  , fAuthor :: Text
  , fFacturX :: Maybe (Either FilePath FilePath)
  -- ^ Left: an XML template; Right: an XML file
  , fLevel :: Text
  , fIcc :: FilePath
  , fXmlOut :: Maybe FilePath
  }

noFlags :: Flags
noFlags = Flags Nothing WarnMissingGlyphs "" "" Nothing "BASIC" srgbProfile Nothing

parseFlags :: Flags -> [String] -> Either String (Flags, [String])
parseFlags f = \case
  "--fonts" : v : more -> parseFlags f {fFonts = Just v} more
  "--missing-glyphs" : "warn" : more -> parseFlags f {fMissingGlyphs = WarnMissingGlyphs} more
  "--missing-glyphs" : "error" : more -> parseFlags f {fMissingGlyphs = FailOnMissingGlyphs} more
  "--missing-glyphs" : _ -> Left "--missing-glyphs takes warn or error"
  "--title" : v : more -> parseFlags f {fTitle = T.pack v} more
  "--author" : v : more -> parseFlags f {fAuthor = T.pack v} more
  "--factur-x" : v : more -> parseFlags f {fFacturX = Just (Left v)} more
  "--factur-x-xml" : v : more -> parseFlags f {fFacturX = Just (Right v)} more
  "--factur-x-level" : v : more -> parseFlags f {fLevel = T.pack v} more
  "--icc" : v : more -> parseFlags f {fIcc = v} more
  "--xml-out" : v : more -> parseFlags f {fXmlOut = Just v} more
  flag : _ | take 2 flag == "--" && flag /= "--node" && flag /= "--xml" -> Left ("unknown flag " <> flag)
  rest -> Right (f, rest)

main :: IO ()
main = do
  args <- getArgs
  (flags, rest) <- either die' pure (parseFlags noFlags args)
  let opts =
        defaultOptions
          { optFontDir = fFonts flags
          , optMissingGlyphs = fMissingGlyphs flags
          , optTitle = fTitle flags
          , optAuthor = fAuthor flags
          }
  case rest of
    ["--xml", tmplPath, ctxPath, out] -> do
      ctx <- readContext ctxPath
      xml <- evalTemplate tmplPath ctx >>= toXml tmplPath
      TIO.writeFile out xml
    ["--node", nodePath, out] -> do
      src <- TIO.readFile nodePath
      node <- orDie nodePath (jsonParser src >>= nodeFromJson)
      archive <- archiveFor flags Nothing
      render out opts {optBaseDir = takeDirectory nodePath, optArchive = archive} node
    [tmplPath, ctxPath, out] -> do
      ctx <- readContext ctxPath
      node <- evalTemplate tmplPath ctx
      archive <- archiveFor flags (Just ctx)
      render out opts {optBaseDir = takeDirectory tmplPath, optArchive = archive} node
    _ ->
      die' . unlines $
        [ "usage: tramaj-hpdf [FLAGS] TEMPLATE CONTEXT.json OUT.pdf"
        , "       tramaj-hpdf [FLAGS] --node NODE.json OUT.pdf"
        , "       tramaj-hpdf --xml TEMPLATE CONTEXT.json OUT.xml"
        , "flags: --fonts NOTO_DIR, --missing-glyphs warn|error, --title TEXT, --author TEXT,"
        , "       --factur-x XML_TEMPLATE | --factur-x-xml FILE.xml,"
        , "       --factur-x-level LEVEL (BASIC), --icc FILE (" <> srgbProfile <> "), --xml-out FILE.xml"
        ]
  where
    readContext ctxPath = TIO.readFile ctxPath >>= orDie ctxPath . jsonParser

    archiveFor flags mctx = case fFacturX flags of
      Nothing -> pure Nothing
      Just source -> do
        xml <- case (source, mctx) of
          (Right file, _) -> BL.readFile file
          (Left tmpl, Just ctx) -> BL.fromStrict . TE.encodeUtf8 <$> (evalTemplate tmpl ctx >>= toXml tmpl)
          (Left _, Nothing) -> die' "--factur-x needs a template and a context; with --node, use --factur-x-xml"
        mapM_ (`BL.writeFile` xml) (fXmlOut flags)
        icc <- BL.readFile (fIcc flags)
        pure (Just (facturX icc (fLevel flags) xml))

    evalTemplate :: FilePath -> Json -> IO Node
    evalTemplate tmplPath ctx = do
      tmpl <- TIO.readFile tmplPath
      prog <- either (die' . errorBundlePretty) pure (parseProgram tmpl)
      case evalProgram Concrete Map.empty ctx prog of
        Left err -> die' (tmplPath <> ": " <> show err)
        Right (ONode n) -> pure n
        Right (OValue _) -> die' (tmplPath <> ": the template evaluates to a value, not a document")

    toXml what node = either (die' . ((what <> ": ") <>) . T.unpack) pure (renderXml node)

    -- 'renderPdfToFile' fails with a message of its own; print it alone.
    render out o n = renderPdfToFile out o n `catchIOError` \e ->
      die' (if isUserError e then ioeGetErrorString e else show e)

    orDie what = either (\e -> die' (what <> ": " <> e)) pure
    die' :: String -> IO a
    die' msg = hPutStrLn stderr msg >> exitFailure
