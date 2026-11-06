-- | Folds an evaluated tramaj 'Node' into a PDF document with HPDF.
--
-- > fonts <- loadFonts
-- > BL.writeFile "out.pdf" (renderPdf fonts noImages defaultOptions node)
--
-- The layout itself is "Tramaj.Hpdf.Layout" (pure, and testable without a
-- PDF reader); this module supplies HPDF's font metrics to it and draws the
-- result.
--
-- __What upstream HPDF limits.__ Text is set in the PDF standard 14 fonts
-- (Helvetica, Courier), which a viewer supplies, so no font is embedded.
-- HPDF writes them with a single-byte encoding (MacRoman), so a character
-- outside it (most of Unicode beyond Western European Latin) is drawn as
-- @?@. The output is not PDF\/A, which requires embedded fonts and XMP
-- metadata. See the package README for what a fork of HPDF would need.
module Tramaj.Hpdf
  ( -- * Rendering
    Options (..)
  , defaultOptions
  , renderPdf
  , renderPdfE
  , renderPdfToFile

    -- * PDF/A and Factur-X
  , Archive (..)
  , facturX
  , srgbProfile

    -- * Fonts
  , Fonts
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
  , pdfByteStringE
  , standardDocInfo
  , AFRelationship (..)
  , AssociatedFile (..)
  , PDFA (..)
  , XMPExtension
  , associatedFile
  , embedAssociatedFile
  , facturXExtension
  , pdfa3b
  , setPDFA
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
  -- directory ('notoSans') instead of using the standard 14 fonts
  , optArchive :: Maybe Archive
  -- ^ write PDF\/A-3b, with these files attached ('facturX'); needs
  -- embedded (TrueType) fonts
  }

defaultOptions :: Options
defaultOptions = Options a4 "" "" True "." Nothing Nothing

-- | PDF\/A-3b output: the output intent's ICC profile (RGB), the files
-- attached to the document, and the XMP properties to declare.
data Archive = Archive
  { archiveIcc :: BL.ByteString
  , archiveFiles :: [AssociatedFile]
  , archiveXmp :: [XMPExtension]
  }

-- | A Factur-X invoice: PDF\/A-3b with the CII XML attached as
-- @factur-x.xml@ (relationship @Alternative@, the visual and the XML being
-- the same invoice) and the Factur-X XMP properties at this conformance
-- level (@MINIMUM@, @BASIC WL@, @BASIC@, @EN 16931@, @EXTENDED@).
facturX :: BL.ByteString -> Text -> BL.ByteString -> Archive
facturX icc level xml =
  Archive
    { archiveIcc = icc
    , archiveFiles =
        [ (associatedFile "factur-x.xml" "text/xml" xml)
            { afRelationship = Alternative
            , afDescription = "Factur-X invoice"
            }
        ]
    , archiveXmp = [facturXExtension level]
    }

-- | Where Debian and Ubuntu install colord's sRGB profile (package
-- @colord-data@, CC0-1.0).
srgbProfile :: FilePath
srgbProfile = "/usr/share/color/icc/colord/sRGB.icc"

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

-- | The document. A PDF\/A problem (a standard 14 font in a document
-- with 'optArchive') is not reported: see 'renderPdfE'.
renderPdf :: Fonts -> Images -> Options -> Node -> BL.ByteString
renderPdf fonts imgs opts node =
  pdfByteString (docInfo opts) (pageRect opts) (documentPdf fonts imgs opts node)

-- | The document, or why it is not the PDF\/A it was asked to be.
renderPdfE :: Fonts -> Images -> Options -> Node -> Either [String] BL.ByteString
renderPdfE fonts imgs opts node =
  pdfByteStringE (docInfo opts) (pageRect opts) (documentPdf fonts imgs opts node)

documentPdf :: Fonts -> Images -> Options -> Node -> PDF ()
documentPdf fonts imgs opts node = do
  case optArchive opts of
    Nothing -> pure ()
    Just a -> do
      setPDFA (pdfa3b (archiveIcc a)) {pdfaTitle = optTitle opts, pdfaExtensions = archiveXmp a}
      mapM_ embedAssociatedFile (archiveFiles a)
  drawPages fonts imgs spec (layoutNode fonts imgs spec node)
  where
    spec = optPage opts

pageRect :: Options -> PDFRect
pageRect opts = PDFRect 0 0 (pageWidth (optPage opts)) (pageHeight (optPage opts))

docInfo :: Options -> PDFDocumentInfo
docInfo opts =
  standardDocInfo
    { author = optAuthor opts
    , subject = optTitle opts
    , compressed = optCompressed opts
    }

renderPdfToFile :: FilePath -> Options -> Node -> IO ()
renderPdfToFile path opts node = do
  fonts <- maybe loadFonts (loadTrueTypeFonts . notoSans) (optFontDir opts)
  imgs <- loadImages (optBaseDir opts) node >>= either (fail . ("tramaj-hpdf: " <>)) pure
  case renderPdfE fonts imgs opts node of
    Left problems -> fail ("tramaj-hpdf: " <> unwords problems)
    Right bytes -> BL.writeFile path bytes
