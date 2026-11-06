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
import Tramaj.Json (Json (..), jsonParser)
import Tramaj.Node (Node (..), NodeAttribute (..), nodeFromJson)

el :: Text -> [Node] -> Node
el tag cs = NElement tag [] JNull cs Map.empty

txt :: Text -> Node
txt t = NText (JString t) Map.empty

frag :: [Node] -> Node
frag cs = NFragment cs Map.empty

runs :: Block -> [Inline]
runs = \case
  Para {paraRuns = rs} -> rs
  Rule _ -> []

-- | Every character is half its point size wide, and only ASCII shows.
monoMetrics :: Metrics
monoMetrics =
  Metrics
    { textWidth = \st t -> fromIntegral (T.length t) * fromIntegral (styleSize st) / 2
    , encodable = \_ c -> c < '\x80'
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
          pages = length (layoutNode fonts a4 node)
          pdf = BL.toStrict (renderPdf fonts defaultOptions {optCompressed = False} node)
      pages `shouldSatisfy` (> 1)
      BC.take 5 pdf `shouldBe` "%PDF-"
      count "/Type /Page" pdf - count "/Type /Pages" pdf `shouldBe` pages
      -- HPDF writes glyph codes in hex: "120" is <313230>.
      BC.isInfixOf "<313230> Tj" pdf `shouldBe` True

  describe "the conformance corpus" $
    it "folds every expected document to a PDF" $ do
      cases <- listDirectory corpusDir
      expected <- filterM doesFileExist [corpusDir </> c </> "expected.json" | c <- cases]
      nodes <- rights <$> mapM (fmap (\s -> jsonParser s >>= nodeFromJson) . TIO.readFile) expected
      -- Most expected files are values, errors or symbolic envelopes, not nodes.
      length nodes `shouldSatisfy` (>= 20)
      fonts <- loadFonts
      forM_ nodes $ \n ->
        BL.take 5 (renderPdf fonts defaultOptions n) `shouldBe` "%PDF-"
