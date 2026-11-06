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
  , renderPdfToFile

    -- * Fonts
  , Fonts
  , loadFonts
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
  , IsFont (charGlyph)
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

-- | The standard 14 fonts the six 'Face's are drawn in.
newtype Fonts = Fonts (Face -> AnyFont)

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
  pure . Fonts $ \case
    Regular -> regular
    Bold -> bold
    Italic -> italic
    BoldItalic -> boldItalic
    Mono -> mono
    MonoBold -> monoBold
  where
    std name = mkStdFont name >>= either (fail . (("tramaj-hpdf: font " <> show name <> ": ") <>) . show) pure

pdfFont :: Fonts -> Style -> PDFFont
pdfFont (Fonts f) (Style face size) = PDFFont (f face) size

-- | Widths from the fonts' metric files. A character is encodable when the
-- font's encoding gives it a glyph code; HPDF maps any other to code 0.
fontMetrics :: Fonts -> Metrics
fontMetrics fonts@(Fonts f) =
  Metrics
    { textWidth = \st t -> Pdf.textWidth (pdfFont fonts st) t
    , encodable = \(Style face _) c -> c == ' ' || charGlyph (f face) c /= 0
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
  }

defaultOptions :: Options
defaultOptions = Options a4 "" "" True "."

-- | The pages a node lays out to with these fonts.
layoutNode :: Fonts -> Images -> PageSpec -> Node -> [[Placed]]
layoutNode fonts imgs spec = layoutPages (metrics fonts imgs) spec . nodeBlocks

-- | Draws laid-out pages, one PDF page each. Each image is embedded once,
-- however many times it is drawn.
drawPages :: Fonts -> Images -> PageSpec -> [[Placed]] -> PDF ()
drawPages fonts imgs spec pages = do
  refs <- embedImages imgs
  mapM_ (page refs) pages
  where
    page refs items = do
      p <- addPage (Just (PDFRect 0 0 (pageWidth spec) (pageHeight spec)))
      drawWithPage p (mapM_ (drawPlaced fonts refs) items)

drawPlaced :: Fonts -> Map Text (Int, Int, ImageRef) -> Placed -> Draw ()
drawPlaced fonts refs = \case
  PlacedText st x y t -> drawText (text (pdfFont fonts st) x y t)
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

renderPdfToFile :: FilePath -> Options -> Node -> IO ()
renderPdfToFile path opts node = do
  fonts <- loadFonts
  imgs <- loadImages (optBaseDir opts) node >>= either (fail . ("tramaj-hpdf: " <>)) pure
  BL.writeFile path (renderPdf fonts imgs opts node)
