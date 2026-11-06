module Main (main) where

import Control.Monad (filterM, forM_)
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import Data.Either (rights)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, listDirectory)
import System.FilePath ((</>))
import Test.Hspec
import Tramaj.Hpdf
import Tramaj.Hpdf.Layout
import Tramaj.Hpdf.Xml (renderXml, renderXmlFragment)
import Tramaj.Eval (Mode (..), Output (..), evalProgram)
import Tramaj.Parser (parseProgram)
import Codec.Picture (PixelRGBA8 (..), generateImage, writePng)
import System.Directory (getTemporaryDirectory)
import Tramaj.Json (Json (..), jsonParser)
import Tramaj.Node (Node (..), NodeAttribute (..), nodeFromJson)

notoDir :: FilePath
notoDir = "/usr/share/fonts/truetype/noto"

el :: Text -> [Node] -> Node
el tag cs = NElement tag [] JNull cs Map.empty

txt :: Text -> Node
txt t = NText (JString t) Map.empty

frag :: [Node] -> Node
frag cs = NFragment cs Map.empty

runs :: Block -> [Inline]
runs = \case
  Para {paraRuns = rs} -> rs
  _ -> []

elA :: Text -> [(Text, Json)] -> [Node] -> Node
elA tag as cs = NElement tag [NAttr k v | (k, v) <- as] JNull cs Map.empty

num :: Int -> Node
num i = NText (JInt (fromIntegral i)) Map.empty

cellTexts :: [Cell] -> [Text]
cellTexts = map (T.concat . map (\(Inline _ t) -> t) . cellRuns)

hlines :: [Placed] -> [(Double, Double)]
hlines ps = [(w, y) | PlacedHLine w _ _ _ y <- ps]

-- | Every character is half its point size wide, and only ASCII shows.
monoMetrics :: Metrics
monoMetrics =
  Metrics
    { textWidth = \st t -> fromIntegral (T.length t) * fromIntegral (styleSize st) / 2
    , encodable = \_ c -> c < '\x80'
    , imageSize = \case
        "wide.png" -> Just (200, 100)
        _ -> Nothing
    }

-- | 100pt by 100pt of room: 18 characters of 11pt text per line.
narrow :: PageSpec
narrow = PageSpec 120 120 10

texts :: [Placed] -> [Text]
texts ps = [t | PlacedText _ _ _ t <- ps]

count :: BC.ByteString -> BC.ByteString -> Int
count needle = go
  where
    go s = case BC.breakSubstring needle s of
      (_, rest)
        | BC.null rest -> 0
        | otherwise -> 1 + go (BC.drop 1 rest)

corpusDir :: FilePath
corpusDir = "../corpus/cases"

main :: IO ()
main = hspec $ do
  describe "renderScalar" $ do
    it "keeps the number type" $ do
      renderScalar (JInt 3) `shouldBe` "3"
      renderScalar (JFloat 3) `shouldBe` "3.0"
    it "renders null as nothing and booleans as words" $ do
      renderScalar JNull `shouldBe` ""
      renderScalar (JBool True) `shouldBe` "true"
    it "renders structure as compact JSON" $
      renderScalar (JArray [JInt 1, JString "a"]) `shouldBe` "[1,\"a\"]"

  describe "nodeBlocks" $ do
    it "gathers inline siblings into one paragraph, styled by their tags" $
      map runs (nodeBlocks (el "p" [txt "a ", el "strong" [txt "b"], el "em" [el "code" [txt "c"]]]))
        `shouldBe` [[Inline bodyStyle "a ", Inline (Style Bold 11) "b", Inline (Style Mono 11) "c"]]
    it "flattens fragments and treats an unknown tag as a container" $
      map runs (nodeBlocks (frag [el "section" [el "p" [txt "x"]], frag [el "p" [txt "y"]]]))
        `shouldBe` [[Inline bodyStyle "x"], [Inline bodyStyle "y"]]
    it "splits text around a block child" $
      map runs (nodeBlocks (el "div" [txt "a", el "p" [txt "b"], txt "c"]))
        `shouldBe` [[Inline bodyStyle "a"], [Inline bodyStyle "b"], [Inline bodyStyle "c"]]
    it "sets headings in bold at their size" $
      map runs (nodeBlocks (el "h2" [txt "T"])) `shouldBe` [[Inline (Style Bold 18) "T"]]
    it "numbers ordered list items through a fragment, as map builds them" $
      [m | Para {paraMarker = Just (Inline _ m)} <- nodeBlocks (el "ol" [frag [el "li" [txt "a"], el "li" [txt "b"]], el "li" [txt "c"]])]
        `shouldBe` ["1.", "2.", "3."]
    it "indents nested lists" $
      [paraIndent p | p@Para {} <- nodeBlocks (el "ul" [el "li" [txt "a", el "ul" [el "li" [txt "b"]]]])]
        `shouldBe` [18, 36]
    it "shows an element's value slot when it has no children" $
      map runs (nodeBlocks (NElement "p" [] (JInt 7) [] Map.empty)) `shouldBe` [[Inline bodyStyle "7"]]
    it "turns br into a forced line break and ignores attributes and actions" $
      map runs (nodeBlocks (NElement "p" [NAttr "class" (JString "x"), NAction "on-click" "k" JNull] JNull [txt "a", el "br" [], txt "b"] Map.empty))
        `shouldBe` [[Inline bodyStyle "a", Inline bodyStyle "\n", Inline bodyStyle "b"]]
    it "drops whitespace-only text between blocks" $
      length (nodeBlocks (el "div" [txt "  ", el "p" [txt "x"], txt "\t"])) `shouldBe` 1
    it "renders hr as a rule" $
      nodeBlocks (el "hr" []) `shouldBe` [Rule 0]

  describe "tables" $ do
    let table = nodeBlocks
        tbl n = [(h, b) | Table _ h b <- table n]
    it "reads thead rows as the header and tbody rows as the body" $
      [(map cellTexts h, map cellTexts b) | (h, b) <- tbl (el "table" [el "thead" [el "tr" [el "th" [txt "a"]]], el "tbody" [frag [el "tr" [el "td" [txt "1"]], el "tr" [el "td" [txt "2"]]]]])]
        `shouldBe` [([["a"]], [["1"], ["2"]])]
    it "takes leading all-th rows as the header when there is no thead" $
      [(length h, length b) | (h, b) <- tbl (el "table" [el "tr" [el "th" [txt "a"], el "th" [txt "b"]], el "tr" [el "th" [txt "x"], el "td" [txt "1"]]])]
        `shouldBe` [(1, 1)]
    it "sets th in bold" $
      [cellRuns c | (h, _) <- tbl (el "table" [el "tr" [el "th" [txt "a"]]]), c <- concat h]
        `shouldBe` [[Inline (Style Bold 11) "a"]]
    it "right-aligns a number and honours the align attribute" $
      [map cellAlign r | (_, b) <- tbl (el "table" [el "tr" [el "td" [num 3], elA "td" [("align", JString "center")] [txt "x"], el "td" [txt "y"]]]), r <- b]
        `shouldBe` [[Just AlignRight, Just AlignCenter, Nothing]]
    it "lays a caption out above the table" $
      case table (el "table" [el "caption" [txt "Cap"], el "tr" [el "td" [txt "1"]]]) of
        [Para {paraRuns = [Inline _ "Cap"]}, Table {}] -> pure ()
        other -> expectationFailure (show other)
    it "sizes columns to their content when the table fits" $
      -- 6pt per character at 11pt is 5.5; 10pt padding per column.
      columnWidths monoMetrics 1000 [[Cell Nothing [Inline bodyStyle "ab"], Cell Nothing [Inline bodyStyle "abcd"]]]
        `shouldBe` [21, 32]
    it "shares the room by need when it does not, never below the longest word" $ do
      let ws = columnWidths monoMetrics 100 [[Cell Nothing [Inline bodyStyle "a"], Cell Nothing [Inline bodyStyle "aaaa bbbb cccc dddd eeee"]]]
      sum ws `shouldSatisfy` (\t -> abs (t - 100) < 1e-9)
      take 1 ws `shouldBe` [15.5]
    it "places a row's cells side by side on one baseline and wraps within a cell" $ do
      let ps = concat (layoutPages monoMetrics (PageSpec 200 200 10) (nodeBlocks (el "table" [el "tr" [el "td" [txt "k"], el "td" [txt (T.unwords (replicate 8 "word"))]]])))
          placed = [(x, y, t) | PlacedText _ x y t <- ps]
      case placed of
        (x1, y1, "k") : (x2, y2, _) : rest -> do
          y2 `shouldBe` y1
          x2 `shouldSatisfy` (> x1)
          length rest `shouldSatisfy` (>= 1) -- the long cell wrapped
          [y | (_, y, _) <- rest] `shouldSatisfy` all (< y1)
        other -> expectationFailure (show other)
    it "draws heavy rules around the header and light ones between body rows" $ do
      let node = el "table" [el "tr" [el "th" [txt "h"]], el "tr" [el "td" [txt "1"]], el "tr" [el "td" [txt "2"]]]
          ws = map fst (hlines (concat (layoutPages monoMetrics (PageSpec 200 200 10) (nodeBlocks node))))
      ws `shouldBe` [0.8, 0.8, 0.4, 0.8]
    it "breaks between rows and repeats the header on the next page" $ do
      let node = el "table" (el "tr" [el "th" [txt "head"]] : [el "tr" [el "td" [txt (T.pack (show i))]] | i <- [1 .. 12 :: Int]])
          pages = layoutPages monoMetrics narrow (nodeBlocks node)
      length pages `shouldSatisfy` (> 1)
      map (take 1 . texts) pages `shouldSatisfy` all (== ["head"])
      concatMap (filter (/= "head") . texts) pages `shouldBe` [T.pack (show i) | i <- [1 .. 12 :: Int]]

  describe "images" $ do
    let lay spec = concat . layoutPages monoMetrics spec . nodeBlocks
        imgs spec n = [(x, y, w, h) | PlacedImage _ x y w h <- lay spec n]
    it "reads src, width, height, align and alt" $
      nodeBlocks (elA "img" [("src", JString "a.png"), ("width", JInt 72), ("height", JString "36pt"), ("align", JString "right"), ("alt", JString "A")] [])
        `shouldBe` [Image 0 "a.png" (Just 72) (Just 36) AlignRight "A"]
    it "scales to the given width, keeping the aspect ratio" $
      imgs (PageSpec 400 400 10) (elA "img" [("src", JString "wide.png"), ("width", JInt 60)] [])
        `shouldBe` [(10, 390 - 30, 60, 30)]
    it "fits the text width when it has no size" $
      [(w, h) | (_, _, w, h) <- imgs narrow (elA "img" [("src", JString "wide.png")] [])] `shouldBe` [(100, 50)]
    it "centers and right-aligns" $
      [x | (x, _, _, _) <- imgs (PageSpec 400 400 10) (frag [elA "img" [("src", JString "wide.png"), ("width", JInt 80), ("align", JString a)] [] | a <- ["center", "right"]])]
        `shouldBe` [10 + 150, 10 + 300]
    it "shows the alt text, or the src, for an image it has no size for" $
      texts (lay narrow (frag [elA "img" [("src", JString "x.png"), ("alt", JString "logo")] [], elA "img" [("src", JString "y.png")] []]))
        `shouldBe` ["logo", "[image: y.png]"]
    it "embeds a PNG, flattening transparency onto white" $ do
      tmp <- getTemporaryDirectory
      let png = tmp </> "tramaj-hpdf-test.png"
          px x _ = if x == 0 then PixelRGBA8 255 0 0 0 else PixelRGBA8 10 20 30 255
      writePng png (generateImage px 2 1)
      let node = elA "img" [("src", JString "tramaj-hpdf-test.png")] []
      imageSources node `shouldBe` ["tramaj-hpdf-test.png"]
      Right images <- loadImages tmp node
      fonts <- loadFonts
      let pdf = BL.toStrict (renderPdf fonts images defaultOptions {optCompressed = False} node)
      BC.isInfixOf "/Subtype /Image" pdf `shouldBe` True
      BC.isInfixOf (BC.pack "\255\255\255\10\20\30") pdf `shouldBe` True
    it "fails naming an image it cannot read" $ do
      r <- loadImages "/nonexistent" (elA "img" [("src", JString "missing.png")] [])
      either id (const "") r `shouldSatisfy` T.isInfixOf "missing.png" . T.pack

  describe "layoutPages" $ do
    let lay = layoutPages monoMetrics narrow . nodeBlocks
    it "lays out nothing as one empty page" $
      layoutPages monoMetrics narrow [] `shouldBe` [[]]
    it "wraps greedily at spaces within the text width" $
      map texts (lay (el "p" [txt "aaaa bbbb cccc dddd eeee"]))
        `shouldBe` [["aaaa bbbb cccc", "dddd eeee"]]
    it "cuts a word wider than a line by character" $
      map texts (lay (el "p" [txt (T.replicate 20 "x")]))
        `shouldBe` [[T.replicate 18 "x", "xx"]]
    it "keeps spaces and breaks only at newlines in pre" $
      map texts (lay (el "pre" [txt "a  b\n  c"])) `shouldBe` [["a  b", "  c"]]
    it "breaks lines at br" $
      map texts (lay (el "p" [txt "a", el "br" [], txt "b"])) `shouldBe` [["a", "b"]]
    it "starts a new page when a line does not fit" $
      -- 13.75pt lines in 100pt: 7 per page.
      map length (lay (frag [el "div" [txt (T.pack (show i))] | i <- [1 .. 10 :: Int]])) `shouldBe` [7, 3]
    it "places lines top-down, the first baseline below the top margin" $
      case lay (el "div" [txt "a", el "br" [], txt "b"]) of
        [[PlacedText _ x1 y1 _, PlacedText _ _ y2 _]] -> do
          x1 `shouldBe` 10
          y1 `shouldSatisfy` (< 110)
          y2 `shouldSatisfy` (< y1)
        other -> expectationFailure (show other)
    it "sets list markers left of the item's indent" $
      case lay (el "ul" [el "li" [txt "a"]]) of
        [[PlacedText _ mx _ m, PlacedText _ x _ t]] -> do
          (m, t) `shouldBe` ("?", "a") -- the bullet is not ASCII
          mx `shouldSatisfy` (< x)
        other -> expectationFailure (show other)
    it "replaces characters the font cannot show" $
      map texts (lay (el "p" [txt "caf\233"])) `shouldBe` [["caf?"]]

  describe "with HPDF's standard fonts" $ do
    it "can show Latin-1 accents and the bullet, not CJK" $ do
      fonts <- loadFonts
      let ok = encodable (fontMetrics fonts) bodyStyle
      (ok '\233', ok '\x2022', ok '\x65E5') `shouldBe` (True, True, False)
    it "measures with the fonts' widths" $ do
      fonts <- loadFonts
      let w = textWidth (fontMetrics fonts)
      w bodyStyle "iiii" `shouldSatisfy` (< w bodyStyle "MMMM")
      w (Style Mono 10) "iiii" `shouldBe` w (Style Mono 10) "MMMM"
    it "writes one PDF page per laid-out page" $ do
      fonts <- loadFonts
      let node = frag [el "p" [txt (T.pack (show i))] | i <- [1 .. 120 :: Int]]
          pages = length (layoutNode fonts noImages a4 node)
          pdf = BL.toStrict (renderPdf fonts noImages defaultOptions {optCompressed = False} node)
      pages `shouldSatisfy` (> 1)
      BC.take 5 pdf `shouldBe` "%PDF-"
      count "/Type /Page" pdf - count "/Type /Pages" pdf `shouldBe` pages
      -- HPDF writes glyph codes in hex: "120" is <313230>.
      BC.isInfixOf "<313230> Tj" pdf `shouldBe` True

  describe "with embedded TrueType fonts (the HPDF fork)" $ do
    -- Uses the system's Noto Sans; skipped where it is not installed.
    let withNoto act = do
          have <- doesFileExist (notoSans notoDir Regular)
          if have then loadTrueTypeFonts (notoSans notoDir) >>= act else pendingWith ("no Noto Sans in " <> notoDir)
    it "can show Cyrillic and accents, not CJK" $ withNoto $ \fonts -> do
      let ok = encodable (fontMetrics fonts) bodyStyle
      (ok '\x416', ok '\x491', ok '\x153', ok '\x65E5') `shouldBe` (True, True, True, False)
    it "measures with the fonts' widths" $ withNoto $ \fonts -> do
      let w = textWidth (fontMetrics fonts)
      w bodyStyle "\x456\x456\x456" `shouldSatisfy` (< w bodyStyle "\x416\x416\x416")
      w (Style Mono 10) "\x456\x456" `shouldBe` w (Style Mono 10) "\x416\x416"
    it "embeds the faces it uses, with two-byte glyph ids and a ToUnicode map" $ withNoto $ \fonts -> do
      let node = el "p" [txt "\x416\x443\x43A"]
          pdf = BL.toStrict (renderPdf fonts noImages defaultOptions {optCompressed = False} node)
      count "/Subtype /Type0" pdf `shouldBe` 1
      count "/FontFile2" pdf `shouldBe` 1
      count "/ToUnicode" pdf `shouldBe` 1
      BC.isInfixOf "/Encoding /Identity-H" pdf `shouldBe` True
      -- three characters, three glyph ids of four hex digits each
      let shown = BC.takeWhileEnd (/= '<') (fst (BC.breakSubstring "> Tj" pdf))
      BC.length shown `shouldBe` 12
    it "writes a Factur-X PDF/A-3b with the XML attached" $ withNoto $ \fonts -> do
      let xml = "<?xml version=\"1.0\"?><x/>"
          opts = defaultOptions {optCompressed = False, optTitle = "Invoice 1", optArchive = Just (facturX "icc" "BASIC" xml)}
          Right pdf = BL.toStrict <$> renderPdfE fonts noImages opts (el "p" [txt "Facture \x20AC"])
      BC.isPrefixOf "%PDF-1.7\n" pdf `shouldBe` True
      forM_
        [ "<pdfaid:part>3</pdfaid:part>", "<fx:ConformanceLevel>BASIC</fx:ConformanceLevel>"
        , "/AFRelationship /Alternative", "/Subtype /text#2Fxml", "/UF (factur-x.xml)"
        , "/OutputIntents", "/Title (Invoice 1)", "<x/>" ]
        $ \needle -> (needle, BC.isInfixOf needle pdf) `shouldBe` (needle, True)

  describe "PDF/A with the standard 14 fonts" $
    it "is refused: they are not embedded" $ do
      fonts <- loadFonts
      let opts = defaultOptions {optArchive = Just (facturX "icc" "BASIC" "<x/>")}
      either (const True) (const False) (renderPdfE fonts noImages opts (el "p" [txt "x"])) `shouldBe` True

  describe "XML (Tramaj.Hpdf.Xml)" $ do
    let ns = ("xmlns:ram", JString "urn:ram")
    it "writes declared prefixes with a colon, and escapes text and attributes" $
      renderXml (elA "ram-Doc" [ns] [elA "ram-ID" [("schemeID", JString "a\"b")] [txt "1 < 2 & 3"], elA "other-Tag" [] []])
        `shouldBe` Right "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ram:Doc xmlns:ram=\"urn:ram\">\n  <ram:ID schemeID=\"a&quot;b\">1 &lt; 2 &amp; 3</ram:ID>\n  <other-Tag/>\n</ram:Doc>\n"
    it "writes numbers as str does, and looks through fragments" $
      renderXmlFragment (el "a" [frag [num 3, txt " ", NText (JFloat 2) Map.empty]]) `shouldBe` Right "<a>3 2.0</a>"
    it "refuses actions and structured values" $ do
      renderXmlFragment (NElement "a" [NAction "click" "k" JNull] JNull [] Map.empty) `shouldSatisfy` either (const True) (const False)
      renderXmlFragment (el "a" [NText (JArray []) Map.empty]) `shouldSatisfy` either (const True) (const False)
    it "needs one root element" $
      renderXml (frag [el "a" [], el "b" []]) `shouldSatisfy` either (const True) (const False)
    it "renders the example Factur-X template" $ do
      tmpl <- TIO.readFile "examples/invoice/factur-x.tramaj"
      ctxSrc <- TIO.readFile "examples/invoice/invoice.json"
      let Right prog = parseProgram tmpl
          Right ctx = jsonParser ctxSrc
          Right (ONode node) = evalProgram Concrete Map.empty ctx prog
          Right xml = renderXml node
      forM_
        [ "<rsm:CrossIndustryInvoice xmlns:rsm=", "<ram:ID>urn:cen.eu:en16931:2017#compliant#urn:factur-x.eu:1p0:basic</ram:ID>"
        , "<udt:DateTimeString format=\"102\">20261106</udt:DateTimeString>"
        , "<ram:TaxTotalAmount currencyID=\"EUR\">362.00</ram:TaxTotalAmount>"
        , "<ram:BilledQuantity unitCode=\"HUR\">6.0000</ram:BilledQuantity>" ]
        $ \needle -> (needle, T.isInfixOf needle xml) `shouldBe` (needle, True)

  describe "the conformance corpus" $
    it "folds every expected document to a PDF" $ do
      cases <- listDirectory corpusDir
      expected <- filterM doesFileExist [corpusDir </> c </> "expected.json" | c <- cases]
      nodes <- rights <$> mapM (fmap (\s -> jsonParser s >>= nodeFromJson) . TIO.readFile) expected
      -- Most expected files are values, errors or symbolic envelopes, not nodes.
      length nodes `shouldSatisfy` (>= 20)
      fonts <- loadFonts
      forM_ nodes $ \n ->
        BL.take 5 (renderPdf fonts noImages defaultOptions n) `shouldBe` "%PDF-"
