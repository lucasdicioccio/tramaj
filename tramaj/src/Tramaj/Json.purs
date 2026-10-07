-- | JSON as Tramaj reads and writes it: like any JSON value, except that a
-- | number is an integer or a float, decided by its text (`reference.md` §3,
-- | `node-json.md` *Numbers*, `decisions.md` §18).
-- |
-- | This module exists because the host's own JSON cannot carry that
-- | difference. `JSON.parse` reads `3` and `3.0` as the same `number`, and
-- | `JSON.stringify` writes both as `3`, so `Data.Argonaut.Core.Json`, which
-- | is that host value, has nowhere to keep the type. Everything Tramaj
-- | takes in or hands out as JSON (the context, a `Node`'s payloads, an
-- | expression program's result, the symbolic envelope) is therefore this
-- | `Json`, read by `jsonParser` and written by `stringify`.
-- |
-- | The names follow `Data.Argonaut.Core` and `Data.Argonaut.Parser` where
-- | they mean the same thing, so that moving a caller over is mostly a
-- | change of import. `fromArgonaut` and `toArgonaut` bridge to a host
-- | value, and say what each direction costs.
-- |
-- | **Integer range.** This implementation has the guaranteed range only,
-- | `-(2^53 - 1)` to `2^53 - 1` (`reference.md` §13): an integer is held in
-- | a double, which is exact there and nowhere beyond.
module Tramaj.Json
  ( Json(..)
  , jsonNull
  , fromBoolean
  , fromInt
  , fromFloat
  , fromString
  , fromArray
  , fromObject
  , isNull
  , toBoolean
  , toNumber
  , toString
  , toArray
  , toObject
  , jsonParser
  , stringify
  , stringifyWithIndent
  , formatInteger
  , formatFloat
  , inIntegerRange
  , normalizeNumbers
  , fromArgonaut
  , toArgonaut
  ) where

import Prelude

import Control.Alt ((<|>))
import Control.Lazy (defer)
import Data.Argonaut.Core as A
import Data.Array as Array
import Data.Bifunctor (lmap)
import Data.Char (fromCharCode)
import Data.Either (Either(..))
import Data.Enum (fromEnum)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.Number as Number
import Data.String (Pattern(..), codePointFromChar, stripSuffix)
import Data.String.CodeUnits as SCU
import Data.String.Common (joinWith)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as Object
import Parsing (Parser, fail, parseErrorMessage, runParser)
import Parsing.Combinators (many, optionMaybe, sepBy)
import Parsing.String (char, eof, string)
import Parsing.String.Basic (hexDigit, takeWhile, takeWhile1)

-- | A JSON value whose numbers keep their type.
-- |
-- | `JInt` and `JFloat` both hold a double. A `JInt` is a whole number, and
-- | a value Tramaj produced is always inside the integer range, finite and
-- | not a negative zero. `jsonParser` is more lenient on purpose, so that
-- | refusing a number is left to whoever decodes the value (see
-- | `normalizeNumbers`): it reads an integer-form number beyond the range
-- | as the `JInt` of the nearest double, and a float too large for a
-- | double as a `JFloat` infinity.
data Json
  = JNull
  | JBool Boolean
  | JInt Number
  | JFloat Number
  | JString String
  | JArray (Array Json)
  | JObject (Object Json)

-- | Structural, with object keys unordered. An integer and a float are
-- | never equal, whatever they hold: `3` and `3.0` are two values.
derive instance eqJson :: Eq Json

instance showJson :: Show Json where
  show = stringify

-- Construction ------------------------------------------------------------

jsonNull :: Json
jsonNull = JNull

fromBoolean :: Boolean -> Json
fromBoolean = JBool

-- | An integer, from the host's 32-bit one.
fromInt :: Int -> Json
fromInt = JInt <<< Int.toNumber

fromFloat :: Number -> Json
fromFloat = JFloat

fromString :: String -> Json
fromString = JString

fromArray :: Array Json -> Json
fromArray = JArray

fromObject :: Object Json -> Json
fromObject = JObject

-- Inspection --------------------------------------------------------------

isNull :: Json -> Boolean
isNull JNull = true
isNull _ = false

toBoolean :: Json -> Maybe Boolean
toBoolean (JBool b) = Just b
toBoolean _ = Nothing

-- | The value of a number of either type. Match on `JInt`/`JFloat` to tell
-- | them apart.
toNumber :: Json -> Maybe Number
toNumber (JInt n) = Just n
toNumber (JFloat n) = Just n
toNumber _ = Nothing

toString :: Json -> Maybe String
toString (JString s) = Just s
toString _ = Nothing

toArray :: Json -> Maybe (Array Json)
toArray (JArray xs) = Just xs
toArray _ = Nothing

toObject :: Json -> Maybe (Object Json)
toObject (JObject o) = Just o
toObject _ = Nothing

-- Numbers -----------------------------------------------------------------

-- | Whether a double is an integer this implementation holds exactly: a
-- | whole number in the guaranteed range, `Number.isSafeInteger`.
inIntegerRange :: Number -> Boolean
inIntegerRange n = Number.isFinite n && Number.floor n == n && Number.abs n <= 9007199254740991.0

-- | An integer as its decimal digits. ECMAScript's `Number::toString`
-- | writes every whole number below `1e21` that way, which covers the
-- | integer range; `show` is that text with `.0` appended.
formatInteger :: Number -> String
formatInteger n = fromMaybe shown (stripSuffix (Pattern ".0") shown)
  where
  shown = show n

-- | A float as the shortest round-trip text of ECMAScript's
-- | `Number::toString`, with `.0` appended when that text has neither a
-- | fraction nor an exponent: `1.0`, `0.1`, `100000000000.0`, `1e+21`.
-- | That is exactly what PureScript's `show` gives a `Number`.
-- |
-- | An infinity has no JSON text. It is written as a float no double
-- | holds, which reads back as the same infinity.
formatFloat :: Number -> String
formatFloat n
  | Number.isFinite n = show n
  | n < 0.0 = "-1e400"
  | otherwise = "1e400"

-- | The numbers of a JSON value as Tramaj values, at any depth, or why one
-- | of them cannot be one. This is the one place that decides what a JSON
-- | number outside the value domain becomes (`reference.md` §3,
-- | `node-json.md` *Decoding*):
-- |
-- | * an integer-form number outside the integer range is refused, not
-- |   rounded;
-- | * a float too large for a double is refused, not read as an infinity;
-- | * a negative zero is zero: `-0.0` is `0.0` and `-0` is `0`.
normalizeNumbers :: Json -> Either String Json
normalizeNumbers = case _ of
  JInt n
    | not (inIntegerRange n) -> Left "an integer is outside the integer range, -(2^53 - 1) to 2^53 - 1"
    | otherwise -> Right (JInt (positiveZero n))
  JFloat n
    | not (Number.isFinite n) -> Left "a float is too large for a double"
    | otherwise -> Right (JFloat (positiveZero n))
  JArray xs -> JArray <$> traverse normalizeNumbers xs
  JObject o -> JObject <$> traverse normalizeNumbers o
  other -> Right other
  where
  -- `-0.0 == 0.0`, so this replaces a zero of either sign by `0.0`.
  positiveZero n = if n == 0.0 then 0.0 else n

-- Writing -----------------------------------------------------------------

-- | Compact JSON, object keys in the order the object holds them, numbers
-- | by `formatInteger` and `formatFloat`.
stringify :: Json -> String
stringify = case _ of
  JNull -> "null"
  JBool b -> if b then "true" else "false"
  JInt n -> formatInteger n
  JFloat n -> formatFloat n
  JString s -> quoteString s
  JArray xs -> "[" <> joinWith "," (map stringify xs) <> "]"
  JObject o -> "{" <> joinWith "," (map (\(Tuple k v) -> quoteString k <> ":" <> stringify v) (entries o)) <> "}"

-- | As `stringify`, on several lines, each level indented by the given
-- | number of spaces. An empty array or object stays on one line.
stringifyWithIndent :: Int -> Json -> String
stringifyWithIndent width = go ""
  where
  step = joinWith "" (Array.replicate width " ")

  go pad = case _ of
    JArray xs | not (Array.null xs) -> block pad "[" "]" (map (go (pad <> step)) xs)
    JObject o | not (Object.isEmpty o) ->
      block pad "{" "}" (map (\(Tuple k v) -> quoteString k <> ": " <> go (pad <> step) v) (entries o))
    other -> stringify other

  block pad open close items =
    open <> "\n" <> joinWith ",\n" (map ((pad <> step) <> _) items) <> "\n" <> pad <> close

entries :: Object Json -> Array (Tuple String Json)
entries = Object.toUnfoldable

-- | A JSON string literal, escaped by the host's own encoder so this does
-- | not grow a second, subtly different escaping table.
quoteString :: String -> String
quoteString = A.stringify <<< A.fromString

-- Reading -----------------------------------------------------------------

-- | Parses JSON text (RFC 8259), typing each number by its text: one with
-- | neither a fraction nor an exponent is an integer, one with either is a
-- | float, so `3` is an integer and `3.0` and `3e0` are floats.
-- |
-- | No number is refused here: see `Json` for what a number beyond the
-- | value domain is read as, and `normalizeNumbers` for where it is
-- | refused. Of two equal keys in one object, the last wins.
jsonParser :: String -> Either String Json
jsonParser src = lmap parseErrorMessage (runParser src (ws *> value <* eof))

type P a = Parser String a

ws :: P Unit
ws = void (takeWhile (\c -> c == codePointFromChar ' ' || c == codePointFromChar '\n' || c == codePointFromChar '\r' || c == codePointFromChar '\t'))

token :: forall a. P a -> P a
token p = p <* ws

value :: P Json
value = defer \_ -> token
  ( (JNull <$ string "null")
      <|> (JBool true <$ string "true")
      <|> (JBool false <$ string "false")
      <|> (JString <$> stringLit)
      <|> number
      <|> array unit
      <|> object unit
  )

array :: Unit -> P Json
array _ = JArray <<< Array.fromFoldable <$> (token (char '[') *> sepBy value (token (char ',')) <* char ']')

object :: Unit -> P Json
object _ = JObject <<< Object.fromFoldable <$> (token (char '{') *> sepBy member (token (char ',')) <* char '}')
  where
  member = Tuple <$> token stringLit <* token (char ':') <*> value

-- | `["-"] int ["." digits] [("e"|"E") ["+"|"-"] digits]`, where `int` is
-- | `0` or starts with a non-zero digit.
number :: P Json
number = do
  sign <- maybe "" (const "-") <$> optionMaybe (char '-')
  intPart <- string "0" <|> digits
  fracPart <- optionMaybe (char '.' *> digits)
  expPart <- optionMaybe do
    _ <- char 'e' <|> char 'E'
    expSign <- optionMaybe (char '+' <|> char '-')
    expDigits <- digits
    pure (if expSign == Just '-' then "-" <> expDigits else expDigits)
  let
    isFloat = isJust fracPart || isJust expPart
    text = sign <> intPart <> maybe "" ("." <> _) fracPart <> maybe "" ("e" <> _) expPart
    -- `Number.fromString` answers `Nothing` for a text whose value is not
    -- finite, which for this grammar means too large for a double.
    n = fromMaybe (if sign == "-" then -Number.infinity else Number.infinity) (Number.fromString text)
  pure (if isFloat then JFloat n else JInt n)
  where
  digits = takeWhile1 (\c -> c >= codePointFromChar '0' && c <= codePointFromChar '9')

stringLit :: P String
stringLit = char '"' *> (joinWith "" <<< Array.fromFoldable <$> many piece) <* char '"'
  where
  piece = takeWhile1 plain <|> (char '\\' *> escape)

  -- Anything but the two characters that end a run and the control
  -- characters JSON does not allow unescaped.
  plain c = c /= codePointFromChar '"' && c /= codePointFromChar '\\' && fromEnum c >= 0x20

  escape =
    ("\"" <$ char '"')
      <|> ("\\" <$ char '\\')
      <|> ("/" <$ char '/')
      <|> ("\x8" <$ char 'b')
      <|> ("\xC" <$ char 'f')
      <|> ("\n" <$ char 'n')
      <|> ("\r" <$ char 'r')
      <|> ("\t" <$ char 't')
      <|> (char 'u' *> unicodeEscape)

  -- | `\uXXXX` is one UTF-16 code unit, which is what a `Char` is here, so
  -- | a surrogate pair written as two escapes becomes one astral character
  -- | by plain concatenation.
  unicodeEscape = do
    hex <- SCU.fromCharArray <$> traverse (const hexDigit) [ 1, 2, 3, 4 ]
    case Int.fromStringAs Int.hexadecimal hex >>= fromCharCode of
      Just c -> pure (SCU.singleton c)
      Nothing -> fail ("invalid unicode escape: \\u" <> hex)

-- The host's JSON -------------------------------------------------------------

-- | A host JSON value, as `JSON.parse` or a host program built it. A host
-- | `number` has no type of its own, so this is where this implementation
-- | classifies one: a whole number in the integer range is an integer, and
-- | any other number is a float. A float that happens to be whole (`3.0`)
-- | therefore arrives as the integer `3`; a host that must pass it as a
-- | float builds a `JFloat`, or reads its JSON text with `jsonParser`.
fromArgonaut :: A.Json -> Json
fromArgonaut j =
  A.caseJson
    (const JNull)
    JBool
    (\n -> if inIntegerRange n then JInt n else JFloat n)
    JString
    (JArray <<< map fromArgonaut)
    (JObject <<< map fromArgonaut)
    j

-- | Down to a host JSON value, where the two number types become one
-- | again: `JSON.stringify` of the result writes the float `3.0` as `3`.
-- | Use `stringify` to write JSON text that keeps the type.
toArgonaut :: Json -> A.Json
toArgonaut = case _ of
  JNull -> A.jsonNull
  JBool b -> A.fromBoolean b
  JInt n -> A.fromNumber n
  JFloat n -> A.fromNumber n
  JString s -> A.fromString s
  JArray xs -> A.fromArray (map toArgonaut xs)
  JObject o -> A.fromObject (map toArgonaut o)
