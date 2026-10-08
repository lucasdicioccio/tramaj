-- | The typed JSON reader and writer, and what the number split asks of the
-- boundaries around them (@specs/reference.md@ \S3, @specs/node-json.md@
-- /Numbers/, @specs/decisions.md@ \S18). The shared corpus covers the
-- language-level behaviour; what is here is this port's own: the reader, the
-- writer, the aeson bridge and the 64-bit range.
module Tramaj.JsonSpec (spec) where

import qualified Data.Aeson as Aeson
import Data.Either (isLeft)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec
import Tramaj.Ast (Expr (..))
import Tramaj.Eval
import Tramaj.Json
import Tramaj.Node
import Tramaj.Parser (parseExpr, parseProgram)
import Tramaj.TestJson (object, (.=))

spec :: Spec
spec = describe "Tramaj.Json" $ do
  readerSpec
  writerSpec
  normalizeSpec
  bridgeSpec
  literalSpec
  contextSpec
  nodeSpec

readerSpec :: Spec
readerSpec = describe "jsonParser" $ do
  let reads' :: Text -> Json -> Spec
      reads' src expected = it (T.unpack src) (jsonParser src `shouldBe` Right expected)
      refuses :: Text -> Spec
      refuses src = it ("refuses " <> show src) (jsonParser src `shouldSatisfy` isLeft)

  describe "types a number by its text" $ do
    reads' "3" (JInt 3)
    reads' "-7" (JInt (-7))
    reads' "0" (JInt 0)
    reads' "-0" (JInt 0)
    reads' "3.0" (JFloat 3)
    reads' "3e0" (JFloat 3)
    reads' "3E0" (JFloat 3)
    reads' "1.5e3" (JFloat 1500)
    reads' "1e-7" (JFloat 1.0e-7)
    reads' "0.1" (JFloat 0.1)

  describe "keeps the digits of an integer, whatever its size" $ do
    reads' "9007199254740993" (JInt 9007199254740993)
    reads' "9223372036854775807" (JInt 9223372036854775807)
    reads' "-9223372036854775808" (JInt (-9223372036854775808))
    reads' "9223372036854775808" (JInt 9223372036854775808)
    reads' "123456789012345678901234567890" (JInt 123456789012345678901234567890)

  it "reads a float too large for a double as an infinity, for a decoder to refuse" $
    jsonParser "1e400" `shouldSatisfy` \case
      Right (JFloat d) -> isInfinite d
      _ -> False

  it "reads a float too small for a double as zero" $
    jsonParser "1e-400" `shouldBe` Right (JFloat 0)

  describe "reads every other JSON value" $ do
    reads' "null" JNull
    reads' "true" (JBool True)
    reads' " [1, 1.0, \"a\", null] " (JArray [JInt 1, JFloat 1, JString "a", JNull])
    reads' "{\"b\": {\"c\": 2.5}, \"a\": []}" (object ["a" .= ([] :: [Json]), "b" .= object ["c" .= (2.5 :: Double)]])
    reads' "\"a\\n\\u00e9\\ud83d\\ude00\"" (JString "a\n\233\128512")

  describe "refuses malformed JSON" $ do
    refuses ""
    refuses "[1,]"
    refuses "{\"a\": 1,}"
    refuses "01"
    refuses "1."
    refuses ".5"
    refuses "+1"
    refuses "1 2"
    refuses "nul"
    refuses "{\"a\" 1}"

writerSpec :: Spec
writerSpec = describe "stringify" $ do
  let writes :: Json -> Text -> Spec
      writes v expected = it (T.unpack expected) (stringify v `shouldBe` expected)

  describe "writes an integer as its digits" $ do
    writes (JInt 3) "3"
    writes (JInt (-7)) "-7"
    writes (JInt 100000000000) "100000000000"
    writes (JInt 9223372036854775807) "9223372036854775807"
    writes (JInt (-9223372036854775808)) "-9223372036854775808"

  describe "writes a float with a fraction or an exponent" $ do
    writes (JFloat 1) "1.0"
    writes (JFloat 0) "0.0"
    writes (JFloat (-2)) "-2.0"
    writes (JFloat 1.5) "1.5"
    writes (JFloat 0.1) "0.1"
    writes (JFloat 0.05) "0.05"
    writes (JFloat 100000000000) "100000000000.0"
    writes (JFloat 1.0e21) "1e+21"
    writes (JFloat 1.0e-7) "1e-7"
    writes (JFloat 1.5e-7) "1.5e-7"
    writes (JFloat 9.223372036854776e18) "9223372036854776000.0"

  describe "writes structures compactly, keys sorted" $ do
    writes (object ["b" .= (2 :: Int), "a" .= [JInt 1, JFloat 1, JNull, JBool False]]) "{\"a\":[1,1.0,null,false],\"b\":2}"
    writes (JString "a\"b\n") "\"a\\\"b\\n\""

  it "round-trips what it writes, type included" $
    let v = object ["n" .= (1 :: Int), "x" .= (1 :: Double), "big" .= JInt 9223372036854775807, "xs" .= [JFloat 1.0e21, JFloat 1.0e-7]]
     in jsonParser (stringify v) `shouldBe` Right v

normalizeSpec :: Spec
normalizeSpec = describe "normalizeNumbers" $ do
  it "keeps the two ends of the signed 64-bit range" $ do
    normalizeNumbers (JInt 9223372036854775807) `shouldBe` Right (JInt 9223372036854775807)
    normalizeNumbers (JInt (-9223372036854775808)) `shouldBe` Right (JInt (-9223372036854775808))

  it "refuses an integer one past either end, at any depth" $ do
    normalizeNumbers (JInt 9223372036854775808) `shouldSatisfy` isLeft
    normalizeNumbers (JInt (-9223372036854775809)) `shouldSatisfy` isLeft
    normalizeNumbers (object ["a" .= [object ["b" .= JInt 9223372036854775808]]]) `shouldSatisfy` isLeft

  it "refuses a float that is not finite" $ do
    normalizeNumbers (JFloat (1 / 0)) `shouldSatisfy` isLeft
    normalizeNumbers (JArray [JFloat (-1 / 0)]) `shouldSatisfy` isLeft

  it "turns a negative zero into zero" $
    fmap stringify (normalizeNumbers (JFloat (-0.0))) `shouldBe` Right "0.0"

  it "leaves a float beyond the integer range alone: it is a float by its text" $
    normalizeNumbers (JFloat 1.0e19) `shouldBe` Right (JFloat 1.0e19)

bridgeSpec :: Spec
bridgeSpec = describe "the aeson bridge" $ do
  it "reads a whole number in the integer range as an integer, any other as a float" $ do
    fromAeson (Aeson.Number 3) `shouldBe` JInt 3
    fromAeson (Aeson.Number 3.0) `shouldBe` JInt 3
    fromAeson (Aeson.Number 1.5) `shouldBe` JFloat 1.5
    fromAeson (Aeson.Number 9223372036854775807) `shouldBe` JInt 9223372036854775807
    fromAeson (Aeson.Number 9223372036854775808) `shouldBe` JFloat 9.223372036854775808e18

  it "gives the number type up on the way out" $ do
    toAeson (JInt 1) `shouldBe` Aeson.Number 1
    toAeson (JFloat 1) `shouldBe` Aeson.Number 1
    toAeson (object ["a" .= [JFloat 1.5]]) `shouldBe` Aeson.object ["a" Aeson..= [1.5 :: Double]]

literalSpec :: Spec
literalSpec = describe "number literals" $ do
  it "types a literal by its form" $ do
    parseExpr "1" `shouldBe` Right (IntLit 1)
    parseExpr "-7" `shouldBe` Right (IntLit (-7))
    parseExpr "1_000_000" `shouldBe` Right (IntLit 1000000)
    parseExpr "1.0" `shouldBe` Right (FloatLit 1)
    parseExpr "1e5" `shouldBe` Right (FloatLit 100000)
    parseExpr "-1.5" `shouldBe` Right (FloatLit (-1.5))

  it "accepts both ends of the signed 64-bit range" $ do
    parseExpr "9223372036854775807" `shouldBe` Right (IntLit maxBound)
    parseExpr "-9223372036854775808" `shouldBe` Right (IntLit minBound)

  it "refuses an integer literal one past either end" $ do
    parseExpr "9223372036854775808" `shouldSatisfy` isLeft
    parseExpr "-9223372036854775809" `shouldSatisfy` isLeft

  it "has no negative zero" $ do
    parseExpr "-0" `shouldBe` Right (IntLit 0)
    fmap show (parseExpr "-0.0") `shouldBe` Right (show (FloatLit 0))

contextSpec :: Spec
contextSpec = describe "the context boundary" $ do
  let run :: Mode -> Text -> Text -> Either String Text
      run mode src ctxText = do
        ctx <- jsonParser ctxText
        prog <- either (Left . show) Right (parseProgram src)
        either (Left . show) (Right . stringify) (runProgram mode Map.empty ctx prog)
      mismatch :: Mode -> Text -> Text -> Expectation
      mismatch mode src ctxText = do
        ctx <- either (\e -> fail ("fixture is not JSON: " <> e)) pure (jsonParser ctxText)
        prog <- either (\e -> fail ("fixture does not parse: " <> show e)) pure (parseProgram src)
        runProgram mode Map.empty ctx prog `shouldSatisfy` \case
          Left (TypeMismatch _) -> True
          _ -> False

  it "keeps the type each number was written with, through to the output" $
    run Concrete "[$ctx.a, $ctx.b, $ctx.c]" "{\"a\": 2, \"b\": 2.0, \"c\": 2e0}" `shouldBe` Right "[2,2.0,2.0]"

  it "holds a 64-bit integer exactly" $
    run Concrete "[$ctx.top, $ctx.bottom, str($ctx.top)]" "{\"top\": 9223372036854775807, \"bottom\": -9223372036854775808}"
      `shouldBe` Right "[9223372036854775807,-9223372036854775808,\"9223372036854775807\"]"

  it "refuses an integer outside the range, in both modes, read or not" $ do
    mismatch Concrete "$ctx.n" "{\"n\": 9223372036854775808}"
    mismatch Symbolic "$ctx.n" "{\"n\": -9223372036854775809}"
    mismatch Concrete "1" "{\"deep\": [{\"n\": 9223372036854775808}]}"

  it "refuses a float too large for a double, read or not" $ do
    mismatch Concrete "$ctx.x" "{\"x\": 1e400}"
    mismatch Symbolic "1" "{\"x\": -1e400}"

  it "reads a negative zero as the zero of its type" $
    run Concrete "[$ctx.a, $ctx.b, $ctx.c]" "{\"a\": -0, \"b\": -0.0, \"c\": -1e-400}" `shouldBe` Right "[0,0.0,0.0]"

  it "does not equate or compare an integer with a float" $ do
    run Concrete "[eq($ctx.a, $ctx.b), eq($ctx.a, 2), eq($ctx.b, 2.0)]" "{\"a\": 2, \"b\": 2.0}" `shouldBe` Right "[false,true,true]"
    mismatch Concrete "lt($ctx.a, $ctx.b)" "{\"a\": 2, \"b\": 2.5}"

  it "takes an integer as an index, never a float" $
    run Concrete "[lookup($ctx.xs, 1, \"d\"), lookup($ctx.xs, 1.0, \"d\"), has($ctx.xs, 1), has($ctx.xs, 1.0)]" "{\"xs\": [10, 20]}"
      `shouldBe` Right "[20,\"d\",true,false]"

  it "writes a float allocation key with its fraction in the symbol id" $
    run Symbolic "[?(1), ?(1.0)]" "null"
      `shouldSatisfy` either (const False) (\out -> "\"id\":\"#0:1\"" `T.isInfixOf` out && "\"id\":\"#1:1.0\"" `T.isInfixOf` out)

nodeSpec :: Spec
nodeSpec = describe "numbers in a Node" $ do
  let text v = object ["type" .= ("text" :: Text), "value" .= v, "annotations" .= object []]

  it "encodes an integer and a float as two different nodes" $ do
    stringify (nodeToJson (NText (JInt 3) noAnnotations)) `shouldBe` "{\"annotations\":{},\"type\":\"text\",\"value\":3}"
    stringify (nodeToJson (NText (JFloat 3) noAnnotations)) `shouldBe` "{\"annotations\":{},\"type\":\"text\",\"value\":3.0}"

  it "decodes each back as what it was" $ do
    (jsonParser "{\"type\":\"text\",\"value\":3,\"annotations\":{}}" >>= nodeFromJson) `shouldBe` Right (NText (JInt 3) noAnnotations)
    (jsonParser "{\"type\":\"text\",\"value\":3e0,\"annotations\":{}}" >>= nodeFromJson) `shouldBe` Right (NText (JFloat 3) noAnnotations)

  it "refuses an integer outside the range in a value, at any depth" $ do
    nodeFromJson (text (JInt 9223372036854775808)) `shouldSatisfy` isLeft
    nodeFromJson (text (object ["a" .= [JInt (-9223372036854775809)]])) `shouldSatisfy` isLeft

  it "keeps a 64-bit integer through a round trip" $
    let n = NElement "n" [NAttr "top" (JInt 9223372036854775807)] (JInt (-9223372036854775808)) [] noAnnotations
     in (jsonParser (stringify (nodeToJson n)) >>= nodeFromJson) `shouldBe` Right n
