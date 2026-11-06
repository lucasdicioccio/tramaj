-- | Folds an evaluated tramaj 'Node' into a PDF document with HPDF.
--
-- > fonts <- loadFonts
-- > BL.writeFile "out.pdf" (renderPdf fonts defaultOptions node)
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

    -- * Drawing a layout
  , layoutNode
  , drawPages
  ) where

import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import Graphics.PDF
  ( AnyFont
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
import Tramaj.Node (Node)

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
    }

data Options = Options
  { optPage :: PageSpec
  , optTitle :: Text
  , optAuthor :: Text
  , optCompressed :: Bool
  -- ^ compress page streams (HPDF's default); turn off to read the
  -- content streams in a text editor
  }

defaultOptions :: Options
defaultOptions = Options a4 "" "" True

-- | The pages a node lays out to with these fonts.
layoutNode :: Fonts -> PageSpec -> Node -> [[Placed]]
layoutNode fonts spec = layoutPages (fontMetrics fonts) spec . nodeBlocks

-- | Draws laid-out pages, one PDF page each.
drawPages :: Fonts -> PageSpec -> [[Placed]] -> PDF ()
drawPages fonts spec = mapM_ $ \items -> do
  page <- addPage (Just (PDFRect 0 0 (pageWidth spec) (pageHeight spec)))
  drawWithPage page (mapM_ (drawPlaced fonts) items)

drawPlaced :: Fonts -> Placed -> Draw ()
drawPlaced fonts = \case
  PlacedText st x y t -> drawText (text (pdfFont fonts st) x y t)
  PlacedRule x0 x1 y -> stroke (Line x0 y x1 y)

renderPdf :: Fonts -> Options -> Node -> BL.ByteString
renderPdf fonts opts node =
  pdfByteString info rect (drawPages fonts spec (layoutNode fonts spec node))
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
  BL.writeFile path (renderPdf fonts opts node)
