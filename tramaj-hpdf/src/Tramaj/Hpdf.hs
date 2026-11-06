{-# LANGUAGE TemplateHaskell #-}

-- | Folds an evaluated tramaj 'Node' into a PDF document with HPDF.
--
-- > fonts <- loadDefaultFonts
-- > BL.writeFile "out.pdf" (renderPdf fonts noImages defaultOptions node)
--
-- The layout itself is "Tramaj.Hpdf.Layout" (pure, and testable without a
-- PDF reader); this module supplies HPDF's font metrics to it and draws the
-- result.
--
-- __Fonts.__ By default text is set in Noto Sans and Noto Sans Mono, bundled
-- in this library (SIL Open Font License 1.1, see @fonts/OFL.txt@) and
-- embedded in the PDF as subsets, so Latin, Greek and Cyrillic render and
-- copy out as Unicode. This needs the HPDF fork with TrueType support
-- (https://github.com/lucasdicioccio/HPDF, branch @unicode-truetype@),
-- which @cabal.project@ pins. 'loadFonts' still gives the PDF standard 14
-- fonts (nothing embedded, MacRoman only). A character the face has no
-- glyph for is drawn as a visible replacement ('replacementChar'), and
-- 'renderPdfToFile' warns or fails ('MissingGlyphs').
module Tramaj.Hpdf
  ( -- * Rendering
    Options (..)
  , MissingGlyphs (..)
  , defaultOptions
  , renderPdf
  , renderPdfToFile
  , missingGlyphsIn
  , describeMissingGlyphs

    -- * Fonts
  , Fonts
  , loadDefaultFonts
  , defaultFontFiles
  , loadFonts
  , loadTrueTypeFonts
  , notoSans
  , fontMetrics

    -- * Images
  , Images
  , noImages
  , LoadedImage
  , loadedSize
  , loadImage
  , loadImages
  , imageSources
  , addImage
  , metrics

    -- * Drawing a layout
  , layoutNode
  , drawPages
  ) where

import Codec.Picture (DynamicImage, PixelRGB8 (..), PixelRGBA8 (..), convertRGBA8, decodeImage, pixelMap)
import qualified Codec.Picture as JP
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Char (isPrint, ord)
import Data.FileEmbed (embedFile, makeRelativeToProject)
import Data.List (intercalate)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)
import Data.Complex (Complex (..))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector.Storable as VS
import Data.Word (Word8)
import System.FilePath (isAbsolute, (</>))
import Graphics.PDF
  ( AnyFont
  , Color (..)
  , JpegFile
  , PDFFilter (NoFilter)
  , PDFJpeg
  , PDFReference
  , RawImage
  , applyMatrix
  , createPDFJpeg
  , createPDFRawImageFromByteString
  , drawXObject
  , jpegBounds
  , readJpegFile
  , scale
  , setWidth
  , strokeColor
  , translate
  , withNewContext
  , Draw
  , FontName (..)
  , IsFont (charGlyph, glyphWidth)
  , TrueTypeFontData
  , mkTrueTypeFont
  , parseTrueTypeFont
  , readTrueTypeFont
  , Line (..)
  , PDF
  , PDFDocumentInfo (..)
  , PDFFont (..)
  , PDFRect (..)
  , addPage
  , drawText
  , drawWithPage
  , mkStdFont
  , pdfByteString
  , standardDocInfo
  , stroke
  , text
  )
import qualified Graphics.PDF as Pdf
import Tramaj.Hpdf.Layout
import Tramaj.Node (Node (..), NodeAttribute (..))
import Tramaj.Json (Json (..))

-- | The fonts the six 'Face's are drawn in: the PDF standard 14 fonts
-- (not embedded, single-byte encoding), or TrueType fonts, embedded and
-- written with Unicode glyph ids (the HPDF fork).
data Fonts
  = StandardFonts (Face -> AnyFont)
  | TrueTypeFonts (Face -> TrueTypeFontData)

-- | Loads the font metrics HPDF ships for the standard 14 fonts. Fails only
-- if HPDF's own embedded metric files do not parse.
loadFonts :: IO Fonts
loadFonts = do
  regular <- std Helvetica
  bold <- std Helvetica_Bold
  italic <- std Helvetica_Oblique
  boldItalic <- std Helvetica_BoldOblique
  mono <- std Courier
  monoBold <- std Courier_Bold
  pure . StandardFonts $ \case
    Regular -> regular
    Bold -> bold
    Italic -> italic
    BoldItalic -> boldItalic
    Mono -> mono
    MonoBold -> monoBold
  where
    std name = mkStdFont name >>= either (fail . (("tramaj-hpdf: font " <> show name <> ": ") <>) . show) pure

-- | Reads one TrueType font file per face. The fonts are embedded in the
-- document (only the faces it uses), so any script they cover renders and
-- copies out as Unicode. Fails naming the first file that cannot be read.
loadTrueTypeFonts :: (Face -> FilePath) -> IO Fonts
loadTrueTypeFonts path = do
  loaded <- traverse (\face -> (face,) <$> load (path face)) [minBound .. maxBound]
  let m = Map.fromList loaded
  pure (TrueTypeFonts (m Map.!))
  where
    load p = readTrueTypeFont p >>= either (\e -> fail ("tramaj-hpdf: font " <> p <> ": " <> e)) pure

-- | The TrueType files bundled with this library, by face: Noto Sans
-- (Regular, Bold, Italic, BoldItalic) and Noto Sans Mono (Regular, Bold),
-- under the SIL Open Font License 1.1 (@fonts/OFL.txt@ in the package).
defaultFontFiles :: Face -> B.ByteString
defaultFontFiles = \case
  Regular -> $(makeRelativeToProject "fonts/NotoSans-Regular.ttf" >>= embedFile)
  Bold -> $(makeRelativeToProject "fonts/NotoSans-Bold.ttf" >>= embedFile)
  Italic -> $(makeRelativeToProject "fonts/NotoSans-Italic.ttf" >>= embedFile)
  BoldItalic -> $(makeRelativeToProject "fonts/NotoSans-BoldItalic.ttf" >>= embedFile)
  Mono -> $(makeRelativeToProject "fonts/NotoSansMono-Regular.ttf" >>= embedFile)
  MonoBold -> $(makeRelativeToProject "fonts/NotoSansMono-Bold.ttf" >>= embedFile)

-- | The bundled Noto Sans fonts ('defaultFontFiles'), embedded in the
-- document as subsets. Needs no file at run time.
loadDefaultFonts :: IO Fonts
loadDefaultFonts =
  either fail pure $ do
    loaded <- traverse (\face -> (face,) <$> parse face) [minBound .. maxBound]
    let m = Map.fromList loaded
    pure (TrueTypeFonts (m Map.!))
  where
    parse face = either (\e -> Left ("tramaj-hpdf: bundled font " <> show face <> ": " <> e)) Right (parseTrueTypeFont (defaultFontFiles face))

-- | The Noto Sans family files in a directory (e.g.
-- @/usr/share/fonts/truetype/noto@).
notoSans :: FilePath -> Face -> FilePath
notoSans dir face = dir </> case face of
  Regular -> "NotoSans-Regular.ttf"
  Bold -> "NotoSans-Bold.ttf"
  Italic -> "NotoSans-Italic.ttf"
  BoldItalic -> "NotoSans-BoldItalic.ttf"
  Mono -> "NotoSansMono-Regular.ttf"
  MonoBold -> "NotoSansMono-Bold.ttf"

-- | The fonts of the faces a layout uses, embedded in the document (a
-- standard 14 font needs nothing embedded).
placeFonts :: Fonts -> [Face] -> PDF (Face -> AnyFont)
placeFonts (StandardFonts f) _ = pure f
placeFonts (TrueTypeFonts f) faces = do
  m <- Map.fromList <$> traverse (\face -> (face,) <$> mkTrueTypeFont (f face)) faces
  pure (m Map.!)

-- | Widths from the fonts' metrics. A character is encodable when the
-- font gives it a glyph: for the standard 14 fonts, a code in their
-- encoding (HPDF maps any other to code 0); for a TrueType font, a glyph in
-- its @cmap@ (glyph 0 is @.notdef@).
fontMetrics :: Fonts -> Metrics
fontMetrics = \case
  StandardFonts f ->
    Metrics
      { textWidth = \(Style face size) t -> Pdf.textWidth (PDFFont (f face) size) t
      , encodable = \(Style face _) c -> c == ' ' || charGlyph (f face) c /= 0
      , imageSize = const Nothing
      }
  TrueTypeFonts f ->
    Metrics
      { textWidth = \(Style face size) t ->
          let ttf = f face in sum [glyphWidth ttf size (charGlyph ttf c) | c <- T.unpack t]
      , encodable = \(Style face _) c -> charGlyph (f face) c /= 0
      , imageSize = const Nothing
      }

-- | The fonts' metrics, and the sizes of these images.
metrics :: Fonts -> Images -> Metrics
metrics fonts (Images imgs) = (fontMetrics fonts) {imageSize = fmap loadedSize . (`Map.lookup` imgs)}

-- Images ---------------------------------------------------------------------

-- | A decoded image, ready to embed. A JPEG is embedded as it is; any other
-- format JuicyPixels reads (PNG, GIF, BMP, TIFF…) is decoded to 8-bit RGB,
-- with transparency flattened onto white, and compressed with the page
-- streams.
data LoadedImage = LoadedImage Int Int ImageData

data ImageData = JpegData JpegFile | RgbData BL.ByteString

loadedSize :: LoadedImage -> (Int, Int)
loadedSize (LoadedImage w h _) = (w, h)

-- | Images by the @src@ an @img@ names them with.
newtype Images = Images (Map Text LoadedImage)

noImages :: Images
noImages = Images Map.empty

addImage :: Text -> LoadedImage -> Images -> Images
addImage src img (Images m) = Images (Map.insert src img m)

-- | Reads a JPEG (kept compressed as it is) or another image format
-- (decoded).
loadImage :: FilePath -> IO (Either String LoadedImage)
loadImage path = (try (B.readFile path) :: IO (Either IOException B.ByteString)) >>= \case
  Left e -> pure (Left (show e))
  Right bytes
    | B.take 2 bytes == B.pack [0xFF, 0xD8] ->
        fmap (\j -> let (w, h) = jpegBounds j in LoadedImage w h (JpegData j)) <$> readJpegFile path
    | otherwise -> pure (fromDynamic <$> decodeImage bytes)

fromDynamic :: DynamicImage -> LoadedImage
fromDynamic dyn =
  let rgba = convertRGBA8 dyn
      JP.Image w h px = pixelMap flatten rgba
   in LoadedImage w h (RgbData (BL.fromStrict (B.pack (VS.toList px))))
  where
    flatten (PixelRGBA8 r g b a) = PixelRGB8 (over r a) (over g a) (over b a)
    over :: Word8 -> Word8 -> Word8
    over c a =
      let c' = fromIntegral c :: Int
          a' = fromIntegral a
       in fromIntegral ((c' * a' + 255 * (255 - a') + 127) `div` 255)

-- | The @src@ of every @img@ in a tree, in document order, without repeats.
imageSources :: Node -> [Text]
imageSources = Map.keys . Map.fromList . map (,()) . go
  where
    go = \case
      NText {} -> []
      NFragment cs _ -> concatMap go cs
      NElement tag as _ cs _ ->
        [s | tag == "img", JString s : _ <- [[v | NAttr "src" v <- as]]] ++ concatMap go cs

-- | Loads every image a tree names, a relative @src@ against the base
-- directory. Fails naming the first image that cannot be read: only files
-- are read, not URLs.
loadImages :: FilePath -> Node -> IO (Either String Images)
loadImages base node = go noImages (imageSources node)
  where
    go acc [] = pure (Right acc)
    go acc (src : rest)
      | "://" `T.isInfixOf` src || "data:" `T.isPrefixOf` src =
          pure (Left ("img src " <> show src <> ": only image files are supported, not URLs"))
      | otherwise = do
          let p = T.unpack src
          r <- loadImage (if isAbsolute p then p else base </> p)
          case r of
            Left e -> pure (Left ("img src " <> show src <> ": " <> e))
            Right img -> go (addImage src img acc) rest

data ImageRef = JpegRef (PDFReference PDFJpeg) | RawRef (PDFReference RawImage)

embedImages :: Images -> PDF (Map Text (Int, Int, ImageRef))
embedImages (Images m) = traverse embed m
  where
    embed (LoadedImage w h d) = (w,h,) <$> case d of
      JpegData j -> JpegRef <$> createPDFJpeg j
      RgbData px -> RawRef <$> createPDFRawImageFromByteString w h True NoFilter px

data Options = Options
  { optPage :: PageSpec
  , optTitle :: Text
  , optAuthor :: Text
  , optCompressed :: Bool
  -- ^ compress page streams (HPDF's default); turn off to read the
  -- content streams in a text editor
  , optBaseDir :: FilePath
  -- ^ where 'renderPdfToFile' resolves a relative @img src@
  , optFontDir :: Maybe FilePath
  -- ^ for 'renderPdfToFile': embed the Noto Sans fonts from this
  -- directory ('notoSans') instead of the bundled ones
  , optMissingGlyphs :: MissingGlyphs
  -- ^ for 'renderPdfToFile': what to do about characters the fonts cannot
  -- show
  }

-- | What 'renderPdfToFile' does when the document holds characters its
-- fonts have no glyph for. Either way nothing is dropped silently: such a
-- character is drawn as 'replacementChar' (U+FFFD, or @?@ in the standard
-- 14 fonts).
data MissingGlyphs
  = -- | Write the PDF with the replacements, and list the characters on
    -- stderr.
    WarnMissingGlyphs
  | -- | Write nothing and fail, listing the characters.
    FailOnMissingGlyphs
  deriving stock (Eq, Show)

defaultOptions :: Options
defaultOptions = Options a4 "" "" True "." Nothing WarnMissingGlyphs

-- | The pages a node lays out to with these fonts.
layoutNode :: Fonts -> Images -> PageSpec -> Node -> [[Placed]]
layoutNode fonts imgs spec = layoutPages (metrics fonts imgs) spec . nodeBlocks

-- | Draws laid-out pages, one PDF page each. Each image is embedded once,
-- however many times it is drawn.
drawPages :: Fonts -> Images -> PageSpec -> [[Placed]] -> PDF ()
drawPages fonts imgs spec pages = do
  refs <- embedImages imgs
  faceFont <- placeFonts fonts (Map.keys (Map.fromList [(styleFace st, ()) | PlacedText st _ _ _ <- concat pages]))
  mapM_ (page faceFont refs) pages
  where
    page faceFont refs items = do
      p <- addPage (Just (PDFRect 0 0 (pageWidth spec) (pageHeight spec)))
      drawWithPage p (mapM_ (drawPlaced faceFont refs) items)

drawPlaced :: (Face -> AnyFont) -> Map Text (Int, Int, ImageRef) -> Placed -> Draw ()
drawPlaced faceFont refs = \case
  PlacedText (Style face size) x y t -> drawText (text (PDFFont (faceFont face) size) x y t)
  PlacedRule x0 x1 y -> stroke (Line x0 y x1 y)
  PlacedHLine w g x0 x1 y -> withNewContext $ do
    setWidth w
    strokeColor (Rgb g g g)
    stroke (Line x0 y x1 y)
  PlacedImage src x y w h -> case Map.lookup src refs of
    Nothing -> pure ()
    Just (pw, ph, ref) -> withNewContext $ do
      applyMatrix (translate (x :+ y))
      applyMatrix (scale (w / fromIntegral pw) (h / fromIntegral ph))
      case ref of
        JpegRef r -> drawXObject r
        RawRef r -> drawXObject r

renderPdf :: Fonts -> Images -> Options -> Node -> BL.ByteString
renderPdf fonts imgs opts node =
  pdfByteString info rect (drawPages fonts imgs spec (layoutNode fonts imgs spec node))
  where
    spec = optPage opts
    rect = PDFRect 0 0 (pageWidth spec) (pageHeight spec)
    info =
      standardDocInfo
        { author = optAuthor opts
        , subject = optTitle opts
        , compressed = optCompressed opts
        }

-- | The characters of a node its fonts have no glyph for, by face (see
-- 'missingGlyphs').
missingGlyphsIn :: Fonts -> Images -> Node -> [(Face, Char)]
missingGlyphsIn fonts imgs = missingGlyphs (metrics fonts imgs) . nodeBlocks

-- | One line naming each missing character once, as @U+XXXX 'c'@, with
-- the faces that lack it.
describeMissingGlyphs :: [(Face, Char)] -> String
describeMissingGlyphs missing =
  "no glyph for "
    <> intercalate ", " [showChar' c <> " (" <> intercalate ", " (map show faces) <> ")" | (c, faces) <- Map.toList byChar]
  where
    byChar = Map.fromListWith (flip (<>)) [(c, [f]) | (f, c) <- missing]
    showChar' c
      | isPrint c = printf "U+%04X '%c'" (ord c) c
      | otherwise = printf "U+%04X" (ord c)

-- | Renders with the bundled Noto Sans fonts ('loadDefaultFonts'), or
-- those in 'optFontDir', reading the images the node names. A character
-- the fonts lack is reported as 'optMissingGlyphs' says.
renderPdfToFile :: FilePath -> Options -> Node -> IO ()
renderPdfToFile path opts node = do
  fonts <- maybe loadDefaultFonts (loadTrueTypeFonts . notoSans) (optFontDir opts)
  imgs <- loadImages (optBaseDir opts) node >>= either (fail . ("tramaj-hpdf: " <>)) pure
  let missing = missingGlyphsIn fonts imgs node
  unless (null missing) $ case optMissingGlyphs opts of
    WarnMissingGlyphs -> hPutStrLn stderr ("tramaj-hpdf: warning: " <> describeMissingGlyphs missing <> "; drawn as a replacement character")
    FailOnMissingGlyphs -> fail ("tramaj-hpdf: " <> describeMissingGlyphs missing)
  BL.writeFile path (renderPdf fonts imgs opts node)
