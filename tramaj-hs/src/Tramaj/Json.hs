-- | JSON as Tramaj reads and writes it: like any JSON value, except that a
-- number is an integer or a float, decided by its text (@reference.md@ \S3,
-- @node-json.md@ /Numbers/, @decisions.md@ \S18).
--
-- This module exists because aeson's 'Aeson.Value' cannot carry that
-- difference: it holds every number as a 'Scientific', where @3@, @3.0@ and
-- @3e0@ are one value, and its encoder writes all three as @3@. Everything
-- Tramaj takes in or hands out as JSON (the context, a @Node@'s payloads, an
-- expression program's result, the symbolic envelope) is therefore this
-- 'Json', read by 'jsonParser' and written by 'stringify'.
--
-- 'fromAeson' and 'toAeson' bridge to an aeson value, and say what each
-- direction costs.
--
-- __Integer range.__ This implementation has the signed 64-bit range,
-- @-2^63@ to @2^63 - 1@ (@reference.md@ \S13): the evaluator holds an integer
-- in an 'Int64'.
module Tramaj.Json
  ( Json (..)

    -- * Reading and writing
  , jsonParser
  , stringify
  , formatInteger
  , formatFloat
  , quoteString

    -- * The number rules of a decoding boundary
  , minInteger
  , maxInteger
  , inIntegerRange
  , normalizeInteger
  , normalizeFloat
  , normalizeNumbers

    -- * Bridging to aeson
  , fromAeson
  , toAeson
  ) where

import qualified Data.Aeson as Aeson
import Data.Aeson.Decoding.Text (textToTokens)
import Data.Aeson.Decoding.Tokens (Lit (..), Number (..), TkArray (..), TkRecord (..), Tokens (..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Char (intToDigit)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Scientific (fromFloatDigits, toBoundedInteger, toRealFloat)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import qualified Data.Vector as V
import Numeric (floatToDigits)

-- | A JSON value whose numbers keep their type.
--
-- A value Tramaj produced always holds a 'JInt' inside the integer range and
-- a 'JFloat' that is finite and not a negative zero. 'jsonParser' is more
-- lenient on purpose, so that refusing a number is left to whoever decodes
-- the value (see 'normalizeNumbers'): it reads an integer-form number of any
-- size exactly, which is why 'JInt' holds an 'Integer', and a float too
-- large for a double as an infinity.
--
-- Equality is structural, with object keys unordered. An integer and a float
-- are never equal, whatever they hold: @3@ and @3.0@ are two values.
data Json
  = JNull
  | JBool Bool
  | JInt Integer
  | JFloat Double
  | JString Text
  | JArray [Json]
  | JObject (Map Text Json)
  deriving stock (Eq, Show)

-- Reading -------------------------------------------------------------------

-- | Reads JSON text, typing each number by its text (@reference.md@ \S3): one
-- with neither a fraction nor an exponent is a 'JInt', one with either is a
-- 'JFloat', so @3@ is an integer and @3.0@ and @3e0@ are floats.
--
-- No number is refused here. An integer keeps every digit, and a float is the
-- double nearest to its decimal value, which is an infinity when the value is
-- too large for a double; 'normalizeNumbers' is what refuses.
--
-- The tokens come from aeson's own decoder, which is the layer that still
-- knows which of the three forms a number was written in; 'Aeson.Value' is
-- one step too late.
jsonParser :: Text -> Either String Json
jsonParser src = value (textToTokens src) $ \v rest ->
  if T.all isJsonSpace rest
    then Right v
    else Left "Unexpected trailing input after the JSON value"
  where
    isJsonSpace c = c == ' ' || c == '\n' || c == '\r' || c == '\t'

value :: Tokens k String -> (Json -> k -> Either String r) -> Either String r
value (TkLit LitNull k) kont = kont JNull k
value (TkLit LitTrue k) kont = kont (JBool True) k
value (TkLit LitFalse k) kont = kont (JBool False) k
value (TkText t k) kont = kont (JString t) k
value (TkNumber n k) kont = kont (number n) k
value (TkArrayOpen items) kont = array [] items kont
value (TkRecordOpen pairs) kont = record [] pairs kont
value (TkErr e) _ = Left e

array :: [Json] -> TkArray k String -> (Json -> k -> Either String r) -> Either String r
array acc (TkItem tokens) kont = value tokens (\v rest -> array (v : acc) rest kont)
array acc (TkArrayEnd k) kont = kont (JArray (reverse acc)) k
array _ (TkArrayErr e) _ = Left e

-- | A repeated key keeps its last value, as aeson's own decoder does.
record :: [(Text, Json)] -> TkRecord k String -> (Json -> k -> Either String r) -> Either String r
record acc (TkPair key tokens) kont = value tokens (\v rest -> record ((Key.toText key, v) : acc) rest kont)
record acc (TkRecordEnd k) kont = kont (JObject (Map.fromList (reverse acc))) k
record _ (TkRecordErr e) _ = Left e

number :: Number -> Json
number (NumInteger n) = JInt n
number (NumDecimal s) = JFloat (toRealFloat s)
number (NumScientific s) = JFloat (toRealFloat s)

-- Writing -------------------------------------------------------------------

-- | Compact JSON, with object keys in sorted order and a number written by
-- its type (@node-json.md@, /Numbers/): an integer as its digits, a float
-- always with a fraction or an exponent.
--
-- This is also @str@'s rendering of an array or an object and v3-symbols
-- \S1.4's canon, which is why the key order is fixed: object key order is
-- not semantically significant, so it must not be observable there.
stringify :: Json -> Text
stringify JNull = "null"
stringify (JBool b) = if b then "true" else "false"
stringify (JInt n) = formatInteger n
stringify (JFloat d) = formatFloat d
stringify (JString s) = quoteString s
stringify (JArray xs) = "[" <> T.intercalate "," (map stringify xs) <> "]"
stringify (JObject o) = "{" <> T.intercalate "," (map entry (Map.toAscList o)) <> "}"
  where
    entry (k, v) = quoteString k <> ":" <> stringify v

-- | A JSON string literal, escaped by aeson itself so this does not grow a
-- second, subtly different escaping table.
quoteString :: Text -> Text
quoteString = TL.toStrict . TLE.decodeUtf8 . Aeson.encode . Aeson.String

-- | An integer as its decimal digits, with a @-@ when negative: no fraction
-- and no exponent, whatever its size.
formatInteger :: Integer -> Text
formatInteger = T.pack . show

-- | A float as the shortest round-trip text of ECMAScript's
-- @Number::toString@, with @.0@ appended when that text has neither a
-- fraction nor an exponent: @1.0@, @0.1@, @100000000000.0@, @1e+21@,
-- @1e-7@. A float therefore never reads back as an integer.
formatFloat :: Double -> Text
formatFloat d
  | isNaN d || isInfinite d = shortest
  | T.any (\c -> c == '.' || c == 'e') shortest = shortest
  | otherwise = shortest <> ".0"
  where
    shortest = formatDouble d

-- | Formats a double exactly as ECMAScript's @Number::toString@ does.
--
-- Matching that specific algorithm is the point: the PureScript
-- implementation runs on a JavaScript host, where this is simply what a
-- number's text /is/. Haskell's own 'show' picks different thresholds for
-- scientific notation -- @0.05@ prints as @5.0e-2@, @1e11@ as @1.0e11@ --
-- so leaving it to 'show' would make the two implementations disagree on
-- something as ordinary as interpolating a price.
--
-- NaN and infinities are not values (@reference.md@ \S3); they are written
-- as ECMAScript names them only so that a 'Json' nobody normalized still
-- shows what it holds.
formatDouble :: Double -> Text
formatDouble d
  | isNaN d = "NaN"
  | isInfinite d = if d < 0 then "-Infinity" else "Infinity"
  | d == 0 = "0"
  | d < 0 = "-" <> formatPositive (negate d)
  | otherwise = formatPositive d

-- | The digit-placement rules of ECMA-262's @Number::toString@, given the
-- shortest round-tripping digit sequence @ds@ and exponent @n@ for which
-- the value is @0.ds * 10^n@ -- which is exactly what 'floatToDigits'
-- returns.
formatPositive :: Double -> Text
formatPositive d
  | n >= k && n <= 21 = digits <> T.replicate (n - k) "0"
  | n > 0 && n <= 21 = T.take n digits <> "." <> T.drop n digits
  | n > (-6) && n <= 0 = "0." <> T.replicate (negate n) "0" <> digits
  | otherwise = mantissa <> "e" <> sign <> T.pack (show (abs e))
  where
    (ds, n) = floatToDigits 10 d
    k = length ds
    digits = T.pack (map intToDigit ds)
    e = n - 1
    mantissa = if k == 1 then digits else T.take 1 digits <> "." <> T.drop 1 digits
    sign = if e >= 0 then "+" else "-" :: Text

-- The number rules of a decoding boundary ------------------------------------

-- | The bottom of this implementation's integer range, @-2^63@.
minInteger :: Integer
minInteger = toInteger (minBound :: Int64)

-- | The top of this implementation's integer range, @2^63 - 1@.
maxInteger :: Integer
maxInteger = toInteger (maxBound :: Int64)

inIntegerRange :: Integer -> Bool
inIntegerRange n = n >= minInteger && n <= maxInteger

-- | An integer-form number as the value it denotes: one outside the integer
-- range is refused, never rounded (@reference.md@ \S3, \S13).
normalizeInteger :: Integer -> Either String Int64
normalizeInteger n
  | inIntegerRange n = Right (fromInteger n)
  | otherwise = Left ("the integer " <> show n <> " is outside the signed 64-bit range")

-- | A float-form number as the value it denotes. One too large for a double
-- is refused, as the literal @1e400@ is a parse error; a negative zero is
-- zero, as the literal @-0.0@ evaluates to @0.0@.
normalizeFloat :: Double -> Either String Double
normalizeFloat d
  | isNaN d || isInfinite d = Left "a float is too large for a double"
  | d == 0 = Right 0
  | otherwise = Right d

-- | What a decoder does to the numbers of a JSON value it is about to treat
-- as a Tramaj value, at any depth: 'normalizeInteger' for each integer and
-- 'normalizeFloat' for each float. The context decoder and
-- 'Tramaj.Node.nodeFromJson' both go through here, so these three functions
-- are the one place that decides which numbers a boundary refuses and which
-- it rewrites.
normalizeNumbers :: Json -> Either String Json
normalizeNumbers (JInt n) = JInt . toInteger <$> normalizeInteger n
normalizeNumbers (JFloat d) = JFloat <$> normalizeFloat d
normalizeNumbers (JArray xs) = JArray <$> traverse normalizeNumbers xs
normalizeNumbers (JObject o) = JObject <$> traverse normalizeNumbers o
normalizeNumbers scalar = Right scalar

-- Bridging to aeson ----------------------------------------------------------

-- | From an aeson value, which has one number type and so cannot say which
-- of the two a number is. A whole number in the integer range becomes an
-- integer and any other number a float, so a host that means the float
-- @3.0@ must build a 'JFloat' itself, or read its JSON text with
-- 'jsonParser' instead of aeson's decoder.
fromAeson :: Aeson.Value -> Json
fromAeson Aeson.Null = JNull
fromAeson (Aeson.Bool b) = JBool b
fromAeson (Aeson.Number s) = case toBoundedInteger s :: Maybe Int64 of
  Just n -> JInt (toInteger n)
  Nothing -> JFloat (toRealFloat s)
fromAeson (Aeson.String s) = JString s
fromAeson (Aeson.Array xs) = JArray (map fromAeson (V.toList xs))
fromAeson (Aeson.Object o) = JObject (Map.fromList (map (\(k, v) -> (Key.toText k, fromAeson v)) (KeyMap.toList o)))

-- | To an aeson value, giving the number type up: @1@ and @1.0@ become the
-- same 'Aeson.Number', and aeson's encoder writes both as @1@. Use
-- 'stringify' to write a value whose numbers must keep their type.
toAeson :: Json -> Aeson.Value
toAeson JNull = Aeson.Null
toAeson (JBool b) = Aeson.Bool b
toAeson (JInt n) = Aeson.Number (fromInteger n)
toAeson (JFloat d) = Aeson.Number (fromFloatDigits d)
toAeson (JString s) = Aeson.String s
toAeson (JArray xs) = Aeson.Array (V.fromList (map toAeson xs))
toAeson (JObject o) = Aeson.Object (KeyMap.fromList (map (\(k, v) -> (Key.fromText k, toAeson v)) (Map.toList o)))
