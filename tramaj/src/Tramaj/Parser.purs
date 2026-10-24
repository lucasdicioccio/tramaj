-- | Surface syntax to core AST. Everything the surface offers beyond
-- | `Tramaj.Ast`'s constructors is desugared here rather than represented:
-- |
-- | * `@name=expr` binding lines become nested `Let`s;
-- | * string interpolation becomes `Concat` over the `str` builtin;
-- | * `branch(fallback, p1, v1, ...)` becomes nested `Branch`;
-- | * object shorthand `{foo}` becomes `{"foo": $foo}`;
-- | * `?shape(key, shape)` becomes a `Let` of its key and the shape, each
-- |   `~name` marker in it an `Alloc` at the form's one site;
-- | * escape sequences are resolved into the `StringLit` they denote.
-- |
-- | The grammar keeps three leader characters from v1: `.` introduces a
-- | document, `$` reads a binding, `@` defines one. What changed is that
-- | there is now a single expression grammar — v1's separate template-phase
-- | productions (`node`, `nodeArg`, `childArg`, `templateSpecialForm`,
-- | `pathOrCallChild`) are gone, because documents are expressions.
-- |
-- | A fourth character is lexical rather than grammatical: `--` begins a
-- | comment that runs to the end of the line. It is discarded by
-- | `skipSpaces` along with whitespace, so it never reaches the AST and
-- | there is nothing to desugar.
-- |
-- | Two conventions are load-bearing and carried over deliberately:
-- |
-- | * A special form's `try` covers *name recognition only*. Once `import`
-- |   or `map` has matched, its shape is parsed without backtracking, so a
-- |   malformed one is a hard parse error instead of silently falling
-- |   through to a meaningless `Call` that would only fail much later at
-- |   eval time. The same holds for every form, not only the special ones:
-- |   a `try` covers what tells a form from its alternatives (`name(`,
-- |   `key:`, `(params) =>`) and never the form's body. A `try` around a
-- |   body throws away the error inside it, and the program is then reported
-- |   as wrong at wherever the outermost alternative started — line 1,
-- |   column 1 for an unclosed bracket anywhere in a document. Each closer
-- |   also names its opener and where it is (`closing`).
-- | * A field-access suffix is parsed with no whitespace skipped before it,
-- |   so `f().rendered` is a field access while `f()` followed by a newline
-- |   and `.div(...)` is two separate things.
-- |
-- | Kept in lockstep with `../tramaj-hs/src/Tramaj/Parser.hs`.
module Tramaj.Parser
  ( parseProgram
  , parseExpr
  ) where

import Prelude

import Control.Alt ((<|>))
import Control.Lazy (defer)
import Data.Array as Array
import Data.Array.NonEmpty as NEA
import Data.Enum (toEnum)
import Data.Either (Either)
import Data.Int as Int
import Data.Foldable (foldMap)
import Data.List.NonEmpty as NEL
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.Number as Number
import Data.String.CodePoints (CodePoint)
import Data.String.CodePoints as SCP
import Data.String.CodeUnits as SCU
import Data.Tuple (Tuple(..))
import Parsing (ParseError, Parser, Position(..), fail, position, runParser)
import Parsing.Combinators (lookAhead, many, many1, notFollowedBy, optionMaybe, sepEndBy, sepEndBy1, skipMany, try, (<?>))
import Parsing.String (anyCodePoint, char, eof, satisfyCodePoint, string)
import Parsing.String.Basic (alphaNum, digit, hexDigit, letter)
import Parsing.String.Basic as Basic
import Tramaj.Ast (ActionAdaptation(..), Attribute(..), Expr(..), ParamValue(..), Program(..), Stmt(..), TypeConstraintArg(..), TypeExpr(..), markerSite, numberAllocs, shapeKeyName, stmts, subExprs)
import Tramaj.Json (inIntegerRange)

type P a = Parser String a

-- | One argument of an element, before the arguments are bucketed into
-- | attributes, the value slot, and children — and before the
-- | attributes-before-children rule is checked, which needs to see them in
-- | source order.
data ElementArg
  = EArgAttr Attribute
  | EArgValue Expr
  | EArgChild Expr

-- | One piece of a double-quoted string, before `desugarString` folds the
-- | pieces into core constructors. Not part of the AST: core.md is explicit
-- | that interpolation needs no node of its own.
data StringPart
  = SLit String
  | SInterp Expr

-- Lexing --------------------------------------------------------------

-- | Whitespace and comments — everything between two tokens that carries no
-- | meaning. Run after every token by `lexeme`, and once before the first
-- | one, so a comment is legal anywhere a space is.
-- |
-- | A comment is `--` to the end of the line. Single-line only: there is no
-- | block form, so there is no nesting rule to get wrong and no way to leave
-- | one unterminated. `--` inside a string literal is ordinary text, because
-- | string bodies are read character by character and never come through
-- | here.
-- |
-- | This is also why `rawIdent` refuses a trailing hyphen: it is what keeps
-- | `$x-- note` from lexing as a name `x--` instead of `$x` and a comment.
skipSpaces :: P Unit
skipSpaces = Basic.skipSpaces *> skipMany (lineComment *> Basic.skipSpaces)
  where
  lineComment :: P Unit
  lineComment = string "--" *> skipMany (satisfyCodePoint (_ /= codePoint '\n'))

lexeme :: forall a. P a -> P a
lexeme p = p <* skipSpaces

symbol :: String -> P String
symbol s = lexeme (string s)

-- Unclosed openers ---------------------------------------------------------

-- | An opener that has been read — a bracket, a quote, a backtick — and
-- | where it sits, so the closer that never comes can say which one it was.
-- |
-- | The error for a missing closer is reported where the closer was looked
-- | for (often the end of the input), and names the opener and its
-- | position: `Expected ')' to close the '(' at line 1, column 5`. Without
-- | that, the only position a reader got was wherever the outermost
-- | backtracking alternative started, which for most programs is line 1,
-- | column 1.
data Opened = Opened String Position

-- | Reads an opener with `p`, remembering where it started. `what` is how
-- | the closer's error names it: `the '('`, `the string`, `the
-- | interpolation`.
opening :: forall a. String -> P a -> P Opened
opening what p = do
  pos <- position
  _ <- p
  pure (Opened what pos)

-- | Reads the closer that matches an `Opened`, labelled with it.
closing :: forall a. Opened -> String -> P a -> P a
closing (Opened what (Position pos)) closer p =
  p <?> (closer <> " to close " <> what <> " at line " <> show pos.line <> ", column " <> show pos.column)

-- | The common case: a lexeme opener and its lexeme closer.
openSym :: String -> P Opened
openSym o = opening ("the '" <> o <> "'") (symbol o)

closeSym :: Opened -> String -> P Unit
closeSym opened c = void (closing opened ("'" <> c <> "'") (symbol c))

-- | A closer read with no whitespace skipped after it, for the forms that
-- | read a field-access suffix directly behind their `)`.
closeChar :: Opened -> Char -> P Unit
closeChar opened c = void (closing opened ("'" <> SCU.singleton c <> "'") (char c))

-- | Another item of a comma-separated list: a `,` that is not the trailing
-- | one before the closer `c`. Recognizing the comma this way, rather than
-- | wrapping the comma *and the item* in a `try`, is what keeps an error
-- | inside the item where it happened instead of rewinding to the comma.
nextItem :: Char -> P Unit
nextItem c = void (try (symbol "," <* notFollowedBy (char c)))

charsToString :: Array Char -> String
charsToString = SCU.fromCharArray

manyChars :: P Char -> P String
manyChars p = charsToString <<< Array.fromFoldable <$> many p

many1Chars :: P Char -> P String
many1Chars p = charsToString <<< NEA.toArray <$> (NEA.fromFoldable1 <$> many1 p)

-- | Text read code point by code point, for string bodies and comments.
-- |
-- | Not `satisfy`: its `Char` is a UTF-16 code unit, so `satisfy` refuses
-- | every character above U+FFFF (most emoji), which a JavaScript string
-- | holds as a surrogate pair. A literal `"😀"` used to be a parse error
-- | here while parsing fine in the Haskell sibling, whose `Char` is a code
-- | point. Anything that may hold arbitrary text goes through these.
manyCodePoints :: (CodePoint -> Boolean) -> P String
manyCodePoints f = SCP.fromCodePointArray <<< Array.fromFoldable <$> many (satisfyCodePoint f)

many1CodePoints :: (CodePoint -> Boolean) -> P String
many1CodePoints f = SCP.fromCodePointArray <<< NEA.toArray <$> (NEA.fromFoldable1 <$> many1 (satisfyCodePoint f))

-- | A `Char` literal as a `CodePoint`, for comparing against what
-- | `satisfyCodePoint` reads.
codePoint :: Char -> CodePoint
codePoint = SCP.codePointFromChar

-- | Not one of the given ASCII characters.
noneOfCodePoints :: Array Char -> CodePoint -> Boolean
noneOfCodePoints cs c = not (Array.elem c (map codePoint cs))

-- | An identifier with no trailing whitespace consumed — used where the
-- | following character is significant: inside dotted paths and after an
-- | element's `.`. Internal hyphens are allowed (kebab-case), so `$my-var`
-- | and `.my-tag` are one token each.
-- |
-- | *Internal* is enforced, not merely documented: a hyphen is part of the
-- | name only when another name character follows it. Without that, a name
-- | would swallow the `--` of a comment written directly after it, and
-- | `$x-- note` would read as the name `x--`.
rawIdent :: P String
rawIdent = do
  c0 <- letter
  cs <- manyChars identRest
  pure (SCU.singleton c0 <> cs)
  where
  identRest :: P Char
  identRest = identChar <|> try (char '-' <* lookAhead identChar)

  identChar :: P Char
  identChar = alphaNum <|> char '_'

identifier :: P String
identifier = lexeme rawIdent

pathTail :: P { root :: String, fields :: Array String }
pathTail = do
  root <- rawIdent
  rest <- many (char '.' *> rawIdent)
  pure { root, fields: Array.fromFoldable rest }

-- | Zero or more `.field` segments directly after a closing `)`.
-- | Deliberately runs before any whitespace is skipped — see the module
-- | header.
fieldAccessSuffix :: P (Array String)
fieldAccessSuffix = Array.fromFoldable <$> many (try (char '.' *> rawIdent))

applyFieldAccess :: Expr -> Array String -> Expr
applyFieldAccess base segs = if Array.null segs then base else FieldAccess base segs

-- | A double-quoted string with no interpolation: every
-- | statically-required position uses this, so what the source says is what
-- | the analysis sees. Import names, action events and keys, adaptation
-- | prefixes and object keys are all parsed with it.
-- |
-- | A backtick here is an error rather than a literal backtick. Someone
-- | writing ``import("lib-`$x`")`` means interpolation, and silently
-- | handing them a library named ``lib-`$x` `` would answer a question they
-- | did not ask — the whole point of the position being static is that it
-- | cannot be computed.
staticString :: P String
staticString = lexeme do
  opened <- opening "the string" (char '"')
  s <- manyCodePoints (noneOfCodePoints [ '"', '`' ])
  next <- optionMaybe (lookAhead (char '`'))
  case next of
    Just _ -> interpolationRefused
    Nothing -> void (closing opened "'\"'" (char '"'))
  pure s
  where
  interpolationRefused =
    fail "this position must be a literal string, so it cannot contain an interpolation"

-- Strings ---------------------------------------------------------------

-- | A string literal: escape sequences plus backtick interpolation of an
-- | arbitrary expression.
stringLit :: P Expr
stringLit = lexeme do
  opened <- opening "the string" (char '"')
  parts <- many (defer \_ -> stringPart)
  _ <- closing opened "'\"'" (char '"')
  pure (desugarString (Array.fromFoldable parts))
  where
  stringPart :: P StringPart
  stringPart = interpPart <|> (SLit <$> litChunk)

  interpPart :: P StringPart
  interpPart = do
    opened <- opening "the interpolation" (char '`')
    e <- defer \_ -> expr
    _ <- closing opened "'`'" (char '`')
    pure (SInterp e)

  -- | A run of ordinary characters, with escape sequences resolved as they
  -- | are read. Stops at a closing quote or an interpolation's backtick;
  -- | either can still be written escaped.
  litChunk :: P String
  litChunk = Array.fold <<< Array.fromFoldable <$> many1 (escapeSeq <|> plainRun)

  plainRun :: P String
  plainRun = many1CodePoints (noneOfCodePoints [ '"', '`', '\\' ])

escapeSeq :: P String
escapeSeq = char '\\' *> (unicodeEscape <|> simpleEscape)
  where
  simpleEscape :: P String
  simpleEscape = do
    c <- anyCodePoint
    case SCU.toChar (SCP.singleton c) of
      Just 'n' -> pure "\n"
      Just 't' -> pure "\t"
      Just 'r' -> pure "\r"
      Just '\\' -> pure "\\"
      Just '"' -> pure "\""
      Just '`' -> pure "`"
      Just '0' -> pure "\x0"
      _ -> fail ("unknown escape sequence: \\" <> SCP.singleton c)

  -- | `\u{1F600}` — braced so it is not limited to four hex digits and does
  -- | not need surrogate pairs.
  -- |
  -- | Decoded to a `CodePoint`, not a `Char`: PureScript's `Char` is a
  -- | UTF-16 code unit, so `fromCharCode` rejects everything above U+FFFF
  -- | and every astral escape — emoji included — would fail to parse here
  -- | while parsing fine in the Haskell sibling.
  unicodeEscape :: P String
  unicodeEscape = do
    _ <- char 'u'
    opened <- opening "the '{' of the unicode escape" (char '{')
    digits <- many1Chars hexDigit
    _ <- closing opened "'}'" (char '}')
    case Int.fromStringAs Int.hexadecimal digits >>= toEnum of
      Just cp -> pure (SCP.singleton cp)
      Nothing -> fail ("invalid unicode escape: \\u{" <> digits <> "}")

-- | Folds string pieces into core constructors. A string with no
-- | interpolation is a plain `StringLit`; otherwise each interpolated
-- | expression is rendered through the `str` builtin and the pieces are
-- | joined with `Concat`, which is exactly what ``"a `$x` b"`` means.
desugarString :: Array StringPart -> Expr
desugarString parts = case Array.uncons (map partExpr (coalesce parts)) of
  Nothing -> StringLit ""
  Just { head, tail } -> Array.foldl Concat head tail
  where
  partExpr (SLit t) = StringLit t
  partExpr (SInterp e) = Call (Path "str" []) [ e ]

  -- | Adjacent literal chunks (an escape sequence splits one in two) are
  -- | merged, so an escape does not leave a stray `Concat` in the AST.
  coalesce :: Array StringPart -> Array StringPart
  coalesce ps = case Array.uncons ps of
    Nothing -> []
    Just { head: SLit a, tail } -> case Array.uncons tail of
      Just { head: SLit b, tail: rest } -> coalesce (Array.cons (SLit (a <> b)) rest)
      _ -> Array.cons (SLit a) (coalesce tail)
    Just { head, tail } -> Array.cons head (coalesce tail)

-- Literals ---------------------------------------------------------------

-- | `["-"] digits ["." digits] [("e"|"E") ["+"|"-"] digits]`, where a `_`
-- | may sit between two digits (reference.md §5, *Number literals*). The
-- | fraction and exponent are taken only when complete, so a stray `.`, `e`
-- | or `_` is left for the caller to reject. The underscores are dropped
-- | before the text reaches `Number.fromString`, which already refuses an
-- | overflow to infinity; a zero is normalized so `-0` never escapes.
-- |
-- | The form decides the type: with neither a fraction nor an exponent the
-- | literal is an integer, with either it is a float. An integer outside
-- | the integer range is refused rather than rounded. `Number.fromString`
-- | rounds such a text to a double of magnitude at least `2^53`, which
-- | `inIntegerRange` never accepts, so the test on the double is exact.
numberLit :: P Expr
numberLit = lexeme $ try do
  sign <- optionMaybe (char '-')
  intPart <- digits
  fracPart <- optionMaybe (try (char '.' *> digits))
  expPart <- optionMaybe $ try do
    _ <- char 'e' <|> char 'E'
    expSign <- optionMaybe (char '+' <|> char '-')
    expDigits <- digits
    pure (if expSign == Just '-' then "-" <> expDigits else expDigits)
  let
    fullStr = (if sign == Just '-' then "-" else "")
      <> intPart
      <> maybe "" ("." <> _) fracPart
      <> maybe "" ("e" <> _) expPart
    isFloat = isJust fracPart || isJust expPart
  case Number.fromString fullStr of
    Just n
      | isFloat -> pure (FloatLit (if n == 0.0 then 0.0 else n))
      | inIntegerRange n -> pure (IntLit (if n == 0.0 then 0.0 else n))
    _ -> fail ("number literal out of range: " <> fullStr)
  where
  digits = do
    first <- many1Chars digit
    rest <- many (try (char '_' *> many1Chars digit))
    pure (first <> Array.fold (Array.fromFoldable rest))

-- | `true`/`false`/`null` matched as whole identifiers, so a longer name
-- | merely starting with one (`truest`, `nullable`) is not chopped into a
-- | literal plus leftovers.
keywordLit :: P Expr
keywordLit = try do
  name <- identifier
  case name of
    "true" -> pure (BoolLit true)
    "false" -> pure (BoolLit false)
    "null" -> pure NullLit
    _ -> fail "not a literal keyword"

arrayLit :: P Expr
arrayLit = lexeme do
  opened <- openSym "["
  elems <- sepEndBy (defer \_ -> expr) (symbol ",")
  closeSym opened "]"
  pure (ArrayLit (Array.fromFoldable elems))

-- | Object keys may be quoted or bare, and a bare key on its own is
-- | shorthand for reading the binding of the same name:
-- | `{foo, bar: $baz}`.
objectLit :: P Expr
objectLit = lexeme do
  opened <- openSym "{"
  entries <- sepEndBy (defer \_ -> objEntry) (symbol ",")
  closeSym opened "}"
  pure (ObjectLit (Array.fromFoldable entries))
  where
  objEntry :: P (Tuple String Expr)
  objEntry = explicitEntry <|> markerEntry <|> shorthandEntry

  -- | `{~replicas}` is `{replicas: ~replicas}`, and `{~host($x)}` is
  -- | `{host: ~host($x)}` (v3-symbols §1.2): the shorthand field of a
  -- | marker, expanded here so every other rule sees the long form.
  markerEntry :: P (Tuple String Expr)
  markerEntry = defer \_ -> marker

  -- | The `try` covers `key:` only, which is what tells this from the
  -- | shorthand; an error in the value is reported where it is.
  explicitEntry :: P (Tuple String Expr)
  explicitEntry = do
    k <- try (objectKey <* lookAhead (symbol ":"))
    _ <- reservedKeyRefused k
    _ <- symbol ":"
    v <- defer \_ -> expr
    pure (Tuple k v)

  shorthandEntry :: P (Tuple String Expr)
  shorthandEntry = do
    k <- identifier
    pure (Tuple k (Path k []))

objectKey :: P String
objectKey = staticString <|> identifier

-- | `"$sym"`, `"$type"` and `"$term"` are reserved across the value domain
-- | (v3-symbols §5.3, v4-types §0): the tag a symbolic or typed envelope
-- | uses to mark a value that is not an ordinary object. An object literal
-- | spelling one of them as a key is a parse error in every profile, not just the
-- | symbolic one, so a program's legality never depends on which profile
-- | runs it.
reservedKeyRefused :: String -> P Unit
reservedKeyRefused k
  | k == "$sym" || k == "$type" || k == "$term" =
      fail ("\"" <> k <> "\" is a reserved key and cannot be used as an object key")
  | otherwise = pure unit

-- Expressions ------------------------------------------------------------

pathExpr :: P Expr
pathExpr = lexeme do
  _ <- char '$'
  p <- pathTail
  pure (Path p.root p.fields)

-- | `?(key)` (v3-symbols §1.2): allocates a symbol. The site is a
-- | placeholder here — `Tramaj.Ast.numberAllocs` assigns the real one once
-- | the whole program has been parsed, so it does not depend on this
-- | parser's own traversal order. A projection following it, as in
-- | `?(key).field`, is an ordinary field-access suffix, the same mechanism
-- | a call result uses.
allocExpr :: P Expr
allocExpr = do
  opened <- try do
    _ <- char '?'
    openSym "("
  keyExpr <- defer \_ -> expr
  closeChar opened ')'
  segs <- fieldAccessSuffix
  skipSpaces
  pure (applyFieldAccess (Alloc 0 keyExpr) segs)

-- | `?shape(key, shape)` (v3-symbols §1.2, decisions §19): a structure of
-- | symbols written with one key and one site. It lowers here, so the core
-- | AST is unchanged: the key is bound once to the hidden `shapeKeyName`,
-- | and each marker in the shape is already an `Alloc` over
-- | `[$#shape, "name"]` or `[$#shape, "name", key]` (`marker`).
-- | `numberAllocs` then gives the form one site and its markers that same
-- | site.
-- |
-- | The `try` covers `?shape(` only; past it, the form is exactly two
-- | arguments, and a malformed one is a parse error. So are the marker
-- | rules the shape must keep (`checkShape`) and a marker in the key.
shapeExpr :: P Expr
shapeExpr = do
  opened <- try do
    _ <- char '?'
    n <- rawIdent
    if n == "shape" then pure unit else fail "not a ?shape form"
    openSym "("
  keyExpr <- defer \_ -> expr
  if Array.null (ownMarkers false keyExpr) then pure unit
  else fail "a marker cannot be written in a ?shape's key"
  _ <- symbol ","
  shape <- defer \_ -> expr
  closeChar opened ')'
  checkShape shape
  segs <- fieldAccessSuffix
  skipSpaces
  pure (applyFieldAccess (Let shapeKeyName keyExpr shape) segs)

-- | The rules on a `?shape`'s own markers, all static: at least one, no
-- | name twice (bare or keyed), and a key on every marker that sits under a
-- | lambda inside the shape.
checkShape :: Expr -> P Unit
checkShape shape =
  let
    markers = ownMarkers false shape
    names = map _.name markers
  in
    if Array.null markers then fail "a ?shape's shape must contain at least one marker of its own"
    else if Array.any (\m -> m.underLambda && not m.keyed) markers then
      fail "a marker under a lambda inside a ?shape must carry a key, as in ~name(key)"
    else if Array.length (Array.nub names) /= Array.length names then fail "a marker name appears twice in one ?shape"
    else pure unit

-- | `~name` or `~name(key)`: a symbol marker, as the allocation it lowers
-- | to, at `markerSite` until `numberAllocs` gives it its form's site. The
-- | name follows the `~` directly, and the `(` of a key follows the name
-- | directly. Parsed anywhere an expression is; the enclosing `shapeExpr`
-- | (or, outside any, `noStrayMarker`) decides whether it is legal there.
marker :: P (Tuple String Expr)
marker = lexeme do
  _ <- char '~'
  name <- rawIdent
  key <- optionMaybe do
    opened <- opening "the '('" (char '(')
    skipSpaces
    e <- defer \_ -> expr
    closeChar opened ')'
    pure e
  let keyArgs = maybe [] pure key
  pure (Tuple name (Alloc markerSite (ArrayLit ([ Path shapeKeyName [], StringLit name ] <> keyArgs))))

markerExpr :: P Expr
markerExpr = defer \_ -> map (\(Tuple _ e) -> e) marker

-- | The markers that belong to the form whose shape (or key) this is: every
-- | marker in it but those inside a nested `?shape`'s shape, with whether
-- | each carries a key and whether a lambda written inside it encloses it.
ownMarkers :: Boolean -> Expr -> Array { name :: String, keyed :: Boolean, underLambda :: Boolean }
ownMarkers underLambda e = case e of
  Alloc site (ArrayLit xs)
    | site == markerSite
    , Just (StringLit name) <- Array.index xs 1 ->
        let rest = Array.drop 2 xs
        in Array.cons { name, keyed: not (Array.null rest), underLambda } (Array.concatMap (ownMarkers underLambda) rest)
  Let name value _
    | name == shapeKeyName -> ownMarkers underLambda value
  Lambda _ body -> ownMarkers true body
  _ -> Array.concatMap (ownMarkers underLambda) (subExprs e)

-- | A marker belongs to a `?shape`'s shape; anywhere else it is a parse
-- | error.
noStrayMarker :: Expr -> P Unit
noStrayMarker e
  | Array.null (ownMarkers false e) = pure unit
  | otherwise = fail "a marker ~name may only be written inside a ?shape's shape"

-- | `?ctx.a.b` (§1.3): the path MUST be rooted at `ctx` — unlike an
-- | ordinary read, an unsupplied demand allocates at the root rather than
-- | failing, so the language needs to tell the two apart before evaluating
-- | anything.
demandExpr :: P Expr
demandExpr = lexeme $ try do
  _ <- char '?'
  root <- rawIdent
  if root == "ctx" then Demand <<< Array.fromFoldable <$> many (char '.' *> rawIdent)
  else fail "a demand must be rooted at ctx, as in ?ctx.path"

-- | `name(args)` or `$name(args)` — the two spellings mean the same thing.
-- | The callee may be a dotted path, so a function reached through an
-- | import's values (`$lib.vals.fn(1)`) or an import being given more
-- | parameters (`$deployment({...})`) is callable directly.
call :: P Expr
call = do
  { p, opened } <- try do
    _ <- optionMaybe (char '$')
    p <- pathTail
    opened <- openSym "("
    pure { p, opened }
  args <- sepEndBy (defer \_ -> expr) (symbol ",")
  closeChar opened ')'
  segs <- fieldAccessSuffix
  skipSpaces
  pure (applyFieldAccess (Call (Path p.root p.fields) (Array.fromFoldable args)) segs)

lambdaExpr :: P Expr
lambdaExpr = do
  params <- try do
    _ <- symbol "("
    params <- sepEndBy pattern (symbol ",")
    _ <- symbol ")"
    _ <- symbol "=>"
    pure params
  body <- defer \_ -> expr
  pure (lowerLambda (Array.fromFoldable params) body)

-- Binding patterns (decisions §17) ------------------------------------------

-- | A binding pattern: a name, or an object pattern `{a, b: c, d: {e}}`.
-- | Object patterns only; defaults (`{a = 1}`), rest (`{...r}`) and array
-- | patterns are deliberately not in the grammar, so they are parse errors.
data Pattern
  = PName String
  | PObject (Array (Tuple String Pattern))

pattern :: P Pattern
pattern = defer \_ -> (PName <$> identifier) <|> objectPattern

objectPattern :: P Pattern
objectPattern = do
  opened <- openSym "{"
  fields <- sepEndBy1 patternField (symbol ",")
  closeSym opened "}"
  let
    pat = PObject (Array.fromFoldable (NEL.toList fields))
    names = patternNames pat
  if Array.length (Array.nub names) /= Array.length names then fail "duplicate name in a binding pattern"
  else pure pat

-- | `name` reads that field into a binding of the same name; `name: p`
-- | reads it and binds or destructures it as `p`.
patternField :: P (Tuple String Pattern)
patternField = do
  k <- identifier
  sub <- optionMaybe (symbol ":" *> defer \_ -> pattern)
  pure (Tuple k (fromMaybe (PName k) sub))

patternNames :: Pattern -> Array String
patternNames (PName n) = [ n ]
patternNames (PObject fields) = foldMap (\(Tuple _ p) -> patternNames p) fields

-- | Lowers `pattern = source` to plain bindings, in written order. A source
-- | that is a path is read directly (`$ctx.item.a`), so errors and static
-- | analyses see the reads a hand-written program would make; anything else
-- | is bound once to the hidden name `#src` first. Hidden names start with
-- | `#`, which no surface name can, and are dropped from a symbol's
-- | `"binding"` and from a library's `.vals` (`isHiddenName`).
bindPattern :: Pattern -> Expr -> Array Stmt
bindPattern (PName n) source = [ SLet n source ]
bindPattern (PObject fields) source = case source of
  Path _ _ -> readFields source
  _ -> Array.cons (SLet "#src" source) (readFields (Path "#src" []))
  where
  readFields src = Array.concatMap (\(Tuple k p) -> bindPattern p (readField src k)) fields

  readField (Path root segs) k = Path root (Array.snoc segs k)
  readField other k = FieldAccess other [ k ]

-- | A pattern parameter becomes a hidden parameter `#argN`; the body is
-- | wrapped in the bindings that read the pattern's names out of it.
lowerLambda :: Array Pattern -> Expr -> Expr
lowerLambda params body =
  Lambda (Array.mapWithIndex paramName params) (stmts (Array.concat (Array.mapWithIndex unpack params)) body)
  where
  paramName _ (PName n) = n
  paramName i (PObject _) = "#arg" <> show i

  unpack _ (PName _) = []
  unpack i p@(PObject _) = bindPattern p (Path ("#arg" <> show i) [])

-- | Grouping, for readability where `Concat` chains get long. Not a
-- | semantic construct: the parse tree it produces is the same as the inner
-- | expression's.
-- |
-- | No `try`: `lambdaExpr` is tried first, and nothing else starts with
-- | `(`, so an error inside the parentheses is reported where it is.
parenExpr :: P Expr
parenExpr = do
  opened <- openSym "("
  e <- defer \_ -> expr
  closeSym opened ")"
  pure e

-- | The forms whose evaluation the language defines itself, rather than
-- | leaving to a builtin: the array primitives (whose function argument
-- | needs a fresh binding per element), `Branch` (which must not evaluate
-- | the arm it does not select), imports, and action adaptation.
-- |
-- | The `try` covers name recognition only — see the module header.
specialForm :: P Expr
specialForm = do
  name <- try do
    _ <- optionMaybe (char '$')
    n <- identifier
    if Array.elem n [ "map", "filter", "scan", "fold", "sort-by", "sort-by-descending", "branch", "import", "adapt-actions", "constraint" ] then pure n
    else fail "not a special form"
  base <- case name of
    "map" -> binaryShape Map
    "filter" -> binaryShape Filter
    "scan" -> ternaryShape Scan
    "fold" -> ternaryShape Fold
    "sort-by" -> binaryShape (SortBy false)
    "sort-by-descending" -> binaryShape (SortBy true)
    "branch" -> branchShape
    "import" -> importShape
    "constraint" -> constraintShape
    _ -> adaptActionsShape
  segs <- fieldAccessSuffix
  skipSpaces
  pure (applyFieldAccess base segs)
  where
  binaryShape :: (Expr -> Expr -> Expr) -> P Expr
  binaryShape ctor = do
    opened <- openSym "("
    a <- defer \_ -> expr
    _ <- symbol ","
    b <- defer \_ -> expr
    closeChar opened ')'
    pure (ctor a b)

  ternaryShape :: (Expr -> Expr -> Expr -> Expr) -> P Expr
  ternaryShape ctor = do
    opened <- openSym "("
    a <- defer \_ -> expr
    _ <- symbol ","
    b <- defer \_ -> expr
    _ <- symbol ","
    c <- defer \_ -> expr
    closeChar opened ')'
    pure (ctor a b c)

  -- | `branch(fallback, p1, v1, p2, v2, ...)` reads "if p1 then v1, else if
  -- | p2 then v2, ..., else fallback" and lowers to nested `Branch`, so the
  -- | laziness is the core constructor's rather than a rule of its own.
  branchShape :: P Expr
  branchShape = do
    opened <- openSym "("
    fallback <- defer \_ -> expr
    arms <- many (nextItem ')' *> arm)
    _ <- optionMaybe (symbol ",")
    closeChar opened ')'
    pure (Array.foldr (\(Tuple p v) acc -> Branch p v acc) fallback (Array.fromFoldable arms))

  arm :: P (Tuple Expr Expr)
  arm = do
    p <- defer \_ -> expr
    _ <- symbol ","
    v <- defer \_ -> expr
    pure (Tuple p v)

  -- | `constraint(name, arg1, arg2, ...)` (v3-symbols §2.1): a static
  -- | string name, like an action's event and key, followed by any number
  -- | of ordinary expressions — zero included, since the language fixes no
  -- | signature for any name.
  constraintShape :: P Expr
  constraintShape = do
    opened <- openSym "("
    name <- staticString
    args <- many (nextItem ')' *> defer \_ -> expr)
    _ <- optionMaybe (symbol ",")
    closeChar opened ')'
    pure (Constrain name (Array.fromFoldable args))

  -- | `import("name", {param: expr, other: ctx(path)})`. The name is a
  -- | static literal, and the parameters are a dedicated production rather
  -- | than an ordinary object expression, because `ctx(...)` means
  -- | something only here.
  importShape :: P Expr
  importShape = do
    opened <- openSym "("
    name <- staticString
    _ <- symbol ","
    params <- importParams
    closeChar opened ')'
    pure (Import name params)

  importParams :: P (Array (Tuple String ParamValue))
  importParams = do
    opened <- openSym "{"
    entries <- sepEndBy (defer \_ -> paramEntry) (symbol ",")
    closeSym opened "}"
    pure (Array.fromFoldable entries)

  paramEntry :: P (Tuple String ParamValue)
  paramEntry = explicitParam <|> shorthandParam

  explicitParam :: P (Tuple String ParamValue)
  explicitParam = do
    k <- try (objectKey <* symbol ":")
    v <- paramValue
    pure (Tuple k v)

  shorthandParam :: P (Tuple String ParamValue)
  shorthandParam = do
    k <- identifier
    pure (Tuple k (PExpr (Path k [])))

  -- | `ctx(spec.replicas)` reads this program's own `$ctx.spec.replicas`,
  -- | and means exactly that. The separate form exists so the path lands in
  -- | a static position the analyses can read; see `Tramaj.Ast`'s
  -- | `ParamValue`.
  paramValue :: P ParamValue
  paramValue = (PType <$> markedTypeExpr) <|> fromContext <|> (PExpr <$> defer \_ -> expr)

  fromContext :: P ParamValue
  fromContext = do
    _ <- try do
      n <- identifier
      _ <- lookAhead (char '(')
      if n == "ctx" then pure n else fail "not a ctx(...) parameter"
    opened <- openSym "("
    p <- pathTail
    skipSpaces
    closeChar opened ')'
    skipSpaces
    pure (PFromContext (Array.cons p.root p.fields))

  -- | `adapt-actions(node, prefix("ns:"))`, optionally with a closure for
  -- | the event type and payload.
  adaptActionsShape :: P Expr
  adaptActionsShape = do
    opened <- openSym "("
    target <- defer \_ -> expr
    _ <- symbol ","
    adaptation <- adaptationShape
    fn <- optionMaybe (nextItem ')' *> defer \_ -> expr)
    _ <- optionMaybe (symbol ",")
    closeChar opened ')'
    pure (AdaptActions target adaptation fn)

  -- | Two forms only, never an arbitrary rewriting function: this is what
  -- | keeps the set of action keys a program can emit enumerable without
  -- | evaluating it.
  adaptationShape :: P ActionAdaptation
  adaptationShape = do
    name <- identifier
    case name of
      "identity" -> pure Identity
      "prefix" -> do
        opened <- openSym "("
        p <- staticString
        closeChar opened ')'
        skipSpaces
        pure (Prefix p)
      _ -> fail "an action adaptation must be identity or prefix(\"...\")"

-- Types ---------------------------------------------------------------------

-- | The six value-domain shapes v4-types §1 reserves as type primitives.
-- | Fixed and closed, so recognized here rather than left for a later
-- | resolution pass to classify. `int` and `float` are the two number
-- | types; `number` is not a primitive, so it reads as an ordinary name and
-- | resolves, or fails to, like any other.
primNames :: Array String
primNames = [ "string", "int", "float", "bool", "null", "document" ]

-- | A type expression (v4-types §1), in the position a full `TypeExpr` may
-- | appear: a declaration's right-hand side, a record field's type, an
-- | array's element type. `typeUnion` and `typePrimOrRef` are included here
-- | but deliberately excluded from `typeExprPayload`, which is what a union
-- | arm's own payload parses with — see that function for why.
typeExpr :: P TypeExpr
typeExpr = defer \_ -> typeVar <|> typeUnion <|> typeArray <|> typeRecord <|> typePrimOrRef

-- | Everything a union arm's payload may be. Deliberately narrower than
-- | `typeExpr`: a nested union has no bracketing in the surface grammar, and
-- | a bare name (a `TPrim` or `TName`) is excluded because nothing marks
-- | where a nullary arm ends — `| Dev | Staging` must parse as two nullary
-- | arms, not `Dev` with a payload named `Staging`, and the same trap would
-- | swallow a following statement's root expression whenever it starts with
-- | a bare identifier (`true`, or a special form written without its
-- | leading `$`). Every constructor kept here starts with a token — `%`,
-- | `[`, `{` — that cannot otherwise begin whatever follows a union
-- | declaration, so no such ambiguity exists for them.
typeExprPayload :: P TypeExpr
typeExprPayload = defer \_ -> typeVar <|> typeArray <|> typeRecord

-- | `%ctx.a.b` (v4-types §1): a type hole. The path MUST be rooted at `ctx`,
-- | mirroring `demandExpr` on the value side.
typeVar :: P TypeExpr
typeVar = lexeme $ try do
  _ <- char '%'
  root <- rawIdent
  if root == "ctx" then TVar <<< Array.fromFoldable <$> many (char '.' *> rawIdent)
  else fail "a type hole must be rooted at ctx, as in %ctx.path"

-- | A `%`-marked type argument, in the two positions v4-types §2 and §5
-- | both use it: an import parameter's value, and a `!type-constraint`
-- | argument. Unlike `typeVar`, the leading `%` here does not require what
-- | follows to be `ctx` — `%Json` (§2's supply) and `%ctx.payload` (§6's
-- | forward) are both legal, told apart only after the `%` itself is seen,
-- | so this cannot simply be `char '%' *> typeExpr`: that would need a
-- | second `%` before the `ctx` case. `typeUnion`/`typeArray`/`typeRecord`/
-- | `typePrimOrRef` need no such adjustment, since none of them themselves
-- | start with `%`.
markedTypeExpr :: P TypeExpr
markedTypeExpr = try do
  _ <- char '%'
  ctxForward <|> (defer \_ -> typeUnion <|> typeArray <|> typeRecord <|> typePrimOrRef)
  where
  ctxForward :: P TypeExpr
  ctxForward = lexeme $ try do
    root <- rawIdent
    if root == "ctx" then TVar <<< Array.fromFoldable <$> many (char '.' *> rawIdent)
    else fail "a %-marked value must be ctx.path or a type expression"

typeArray :: P TypeExpr
typeArray = do
  opened <- openSym "["
  t <- defer \_ -> typeExpr
  closeSym opened "]"
  pure (TArray t)

typeRecord :: P TypeExpr
typeRecord = do
  opened <- openSym "{"
  fields <- sepEndBy (defer \_ -> typeField) (symbol ",")
  closeSym opened "}"
  pure (TRecord (Array.fromFoldable fields))
  where
  -- | Unlike an ordinary object literal's `objectKey`, a field name here is
  -- | always a bare `identifier`, never a quoted string (v4-types §1.1's
  -- | examples never show one either). This is what keeps a canonical id
  -- | (v4-types §3, `Tramaj.Types`) injective: the id grammar uses `:`, `,`,
  -- | `[`, `]` and `|` as its own delimiters, and an identifier can never
  -- | contain any of them, so inserting a field name raw can never be
  -- | confused with the surrounding structure. A quoted key could.
  typeField :: P (Tuple String TypeExpr)
  typeField = do
    k <- identifier
    _ <- symbol ":"
    t <- defer \_ -> typeExpr
    pure (Tuple k t)

-- | `| A T | B U | C` (v4-types §1.1): one or more arms, each a name with an
-- | optional payload — a nullary arm is an enum case, not a payload-carrying
-- | one with an empty payload.
typeUnion :: P TypeExpr
typeUnion = TUnion <<< Array.fromFoldable <$> many1 (symbol "|" *> defer \_ -> unionArm)
  where
  unionArm :: P (Tuple String (Maybe TypeExpr))
  unionArm = do
    name <- identifier
    payload <- optionMaybe (defer \_ -> typeExprPayload)
    pure (Tuple name payload)

-- | A bare name (a primitive keyword or a declaration reference) or a
-- | library-qualified one, `$lib.types.Name` (v4-types §1.1's `@m :
-- | $msg.types.Envelope`). Which of `TName` and `TLibRef` applies is a
-- | purely syntactic distinction here; resolving either to a primitive, a
-- | declaration, or `UnresolvedType` is a later pass's job (v4-types §9, not
-- | yet implemented).
typePrimOrRef :: P TypeExpr
typePrimOrRef = libRef <|> nameOrPrim
  where
  libRef :: P TypeExpr
  libRef = lexeme $ try do
    _ <- char '$'
    libName <- rawIdent
    _ <- char '.'
    _ <- string "types"
    _ <- char '.'
    typeName <- rawIdent
    pure (TLibRef libName typeName)

  nameOrPrim :: P TypeExpr
  nameOrPrim = do
    name <- identifier
    pure (if Array.elem name primNames then TPrim name else TName name)

-- | `type Name = TypeExpr` (v4-types §1.1): the fifth statement leader.
-- | Unlike `@`/`!`/`.`/`$` it is a whole keyword rather than a single
-- | character, so it is recognized by parsing a full identifier and
-- | checking it — the same device `keywordLit` uses — which is what keeps
-- | `typeface = ...` from being chopped into the keyword `type` plus
-- | leftovers.
typeDeclStmt :: P Stmt
typeDeclStmt = do
  name <- try do
    kw <- identifier
    if kw /= "type" then fail "not a type declaration" else pure unit
    name <- identifier
    _ <- symbol "="
    pure name
  STypeDecl name <$> defer \_ -> typeExpr

-- | One argument to `!type-constraint` (v4-types §5): a `%`-marked type
-- | expression, or a literal scalar — reusing the same primitive literal
-- | parsers `numberLit`/`keywordLit` use, unwrapped to the scalar the
-- | argument actually carries, since it is never wrapped as an evaluable
-- | `Expr` here. A string scalar is `staticString`, not `stringLit`: like a
-- | constraint's own name, this position is never computed.
typeConstraintArg :: P TypeConstraintArg
typeConstraintArg = (TCType <$> markedTypeExpr) <|> scalarArg
  where
  scalarArg :: P TypeConstraintArg
  scalarArg =
    (TCScalarStr <$> staticString)
      <|> (asScalar <$> numberLit)
      <|> (asScalar <$> keywordLit)

  asScalar :: Expr -> TypeConstraintArg
  asScalar (IntLit n) = TCScalarInt n
  asScalar (FloatLit n) = TCScalarFloat n
  asScalar (BoolLit b) = TCScalarBool b
  asScalar NullLit = TCScalarNull
  asScalar (StringLit s) = TCScalarStr s
  asScalar _ = TCScalarNull -- unreachable: `numberLit`/`keywordLit` only ever produce the cases above

-- | `!type-constraint(name, args...)` (v4-types §5, roadmap Phase 12): tried
-- | before the general `!expr` `emission`, since both share the `!` leader
-- | and `type-constraint(...)` would otherwise parse as an ordinary call to
-- | an unbound name.
typeEmission :: P Stmt
typeEmission = do
  opened <- try do
    _ <- char '!'
    kw <- identifier
    if kw /= "type-constraint" then fail "not a !type-constraint" else pure unit
    openSym "("
  name <- staticString
  args <- many (nextItem ')' *> typeConstraintArg)
  _ <- optionMaybe (symbol ",")
  closeChar opened ')'
  skipSpaces
  pure (STypeEmit name (Array.fromFoldable args))

-- Documents ---------------------------------------------------------------

-- | `.tag(...)` is an element; `.(...)` is a fragment — a tagless element,
-- | introducing siblings with no wrapper.
-- |
-- | No `try`: nothing else an operand can be starts with `.`, so once it is
-- | read this is a document, and an error inside it is reported where it is.
documentExpr :: P Expr
documentExpr = do
  _ <- char '.'
  fragmentShape <|> elementShape
  where
  fragmentShape :: P Expr
  fragmentShape = do
    opened <- openSym "("
    children <- sepEndBy (defer \_ -> expr) (symbol ",")
    closeSym opened ")"
    pure (Fragment (Array.fromFoldable children))

  elementShape :: P Expr
  elementShape = do
    tag <- rawIdent
    skipSpaces
    opened <- opening ("the '(' of ." <> tag) (symbol "(")
    args <- sepEndBy (defer \_ -> elementArg) (symbol ",")
    closeSym opened ")"
    buildElement tag (Array.fromFoldable args)

-- | Buckets an element's arguments and enforces the one ordering rule:
-- | everything in attribute position comes before any child.
buildElement :: String -> Array ElementArg -> P Expr
buildElement tag args = do
  ensureAttrsBeforeChildren
  value <- singleValueSlot
  pure (Element tag (Array.mapMaybe attrOf args) value (Array.mapMaybe childOf args))
  where
  attrOf (EArgAttr a) = Just a
  attrOf _ = Nothing

  childOf (EArgChild c) = Just c
  childOf _ = Nothing

  valueOf (EArgValue v) = Just v
  valueOf _ = Nothing

  ensureAttrsBeforeChildren :: P Unit
  ensureAttrsBeforeChildren =
    if _.ok (Array.foldl step { ok: true, seenChild: false } args) then pure unit
    else fail "attributes, action(...) and value(...) must all come before an element's children"
    where
    step acc (EArgChild _) = acc { seenChild = true }
    step acc _ = acc { ok = acc.ok && not acc.seenChild }

  singleValueSlot :: P Expr
  singleValueSlot = case Array.mapMaybe valueOf args of
    [] -> pure NullLit
    [ v ] -> pure v
    _ -> fail "an element can have at most one value(...)"

-- | `defer` here is not decoration: `elementArg` and everything it can
-- | reach form one mutually recursive binding group, and PureScript is
-- | strict, so without it the group's values reference each other before
-- | any of them exists.
elementArg :: P ElementArg
elementArg = defer \_ ->
  attributePositionArg
    <|> (EArgAttr <$> namedArg)
    <|> (EArgChild <$> expr)

-- | `action(...)` and `value(...)`, the two forms that mean something only
-- | in an element's argument list.
-- |
-- | As with `specialForm`, the `try` covers name recognition only: once
-- | `action` has been seen applied to arguments, a malformed one is a parse
-- | error. Letting it backtrack would leave
-- | `action("on-click", $computed, {})` parsing happily as a call to an
-- | unbound function named `action`, and the static-key restriction would
-- | be enforced by nothing at all.
-- |
-- | Recognition needs the following `(`, so `action` and `value` remain
-- | usable as ordinary attribute names: `value: 1` is an attribute,
-- | `value(1)` is the value slot.
attributePositionArg :: P ElementArg
attributePositionArg = do
  name <- try do
    n <- identifier
    _ <- lookAhead (char '(')
    if n == "action" || n == "value" then pure n
    else fail "not an action(...) or value(...) form"
  if name == "action" then EArgAttr <$> actionShape
  else EArgValue <$> valueShape

-- | `action("on-click", "save", payloadExpr)`. Both the event and the key
-- | are static literals; only the payload is computed. The host still owns
-- | the event vocabulary — what is fixed is the position, not the words
-- | allowed in it.
actionShape :: P Attribute
actionShape = do
  opened <- openSym "("
  event <- staticString
  _ <- symbol ","
  key <- staticString
  _ <- symbol ","
  payload <- defer \_ -> expr
  closeSym opened ")"
  pure (ActionAttr event key payload)

-- | `value(expr)` fills the element's value slot — see `Tramaj.Node` for
-- | what a host does with it.
valueShape :: P Expr
valueShape = do
  opened <- openSym "("
  v <- defer \_ -> expr
  closeSym opened ")"
  pure v

-- | The `try` covers `name:` only, which is what tells an attribute from a
-- | child; an error in its value is reported where it is.
namedArg :: P Attribute
namedArg = do
  name <- try (objectKey <* symbol ":")
  Attr name <$> defer \_ -> expr

-- Precedence ---------------------------------------------------------------

-- | `a <> b`, left-associative and the lowest precedence in the language —
-- | the only infix operator there is.
expr :: P Expr
expr = do
  first <- defer \_ -> operand
  rest <- many (symbol "<>" *> defer \_ -> operand)
  pure (Array.foldl Concat first (Array.fromFoldable rest))

-- | Alternatives are ordered so that a longer form is tried before a prefix
-- | of it: keyword literals before paths and calls, special forms before
-- | ordinary calls, lambdas before parenthesized expressions.
operand :: P Expr
operand = defer \_ ->
  keywordLit
    <|> lambdaExpr
    <|> parenExpr
    <|> specialForm
    <|> call
    <|> pathExpr
    <|> allocExpr
    <|> shapeExpr
    <|> demandExpr
    <|> markerExpr
    <|> documentExpr
    <|> stringLit
    <|> numberLit
    <|> arrayLit
    <|> objectLit

-- Programs -----------------------------------------------------------------

-- | `@name=expr` or `@name : T = expr` (v4-types §7), one per line. `@`
-- | leads a binding definition, mirroring `$` leading a binding read; the
-- | optional `: T` is what tells `SLet` and `SAnnotate` apart.
-- |
-- | No `try`: nothing else starts with `@`, so an error in a binding is
-- | reported where it is rather than at the start of the line.
binding :: P (Array Stmt)
binding = do
  _ <- char '@'
  pat <- pattern
  case pat of
    PObject _ -> do
      -- No annotation on a pattern (decisions §17): a `:` here is a parse error.
      _ <- symbol "="
      e <- defer \_ -> expr
      pure (bindPattern pat e)
    PName name -> do
      annot <- optionMaybe (try (symbol ":" *> defer \_ -> typeExpr))
      _ <- symbol "="
      e <- defer \_ -> expr
      pure case annot of
        Nothing -> [ SLet name e ]
        Just t -> [ SAnnotate name t e ]

-- | `!expr` (v3-symbols §2.2): the fourth statement leader, joining `.`,
-- | `$` and `@`. A statement position only — it may not appear inside an
-- | expression, so there is no operand form for it.
emission :: P Expr
emission = do
  _ <- char '!'
  defer \_ -> expr

-- | One statement of the surface grammar: a binding (plain or annotated),
-- | an emission (value or type), or a type declaration, in the order the
-- | source wrote them — what `Ast.stmts` rebuilds into the core chain.
-- | `typeEmission` is tried ahead of `emission` since both share the `!`
-- | leader.
statement :: P (Array Stmt)
statement = binding <|> (pure <$> typeEmission) <|> (pure <<< SEmit <$> emission) <|> (pure <$> typeDeclStmt)

-- | A program is a sequence of statements and a root expression. Which kind
-- | of program it is follows from the root's own form — a document root is
-- | exactly one written as a document — so there is no mode to declare and
-- | no separate entry point to pick.
parseProgram :: String -> Either ParseError Program
parseProgram input = runParser input program
  where
  program :: P Program
  program = do
    skipSpaces
    statements <- many statement
    root <- expr
    skipSpaces
    eof
    let body = stmts (Array.concat (Array.fromFoldable statements)) root
    noStrayMarker body
    let programBody = numberAllocs body
    pure case root of
      Element _ _ _ _ -> DocumentProgram programBody
      Fragment _ -> DocumentProgram programBody
      _ -> ExpressionProgram programBody

parseExpr :: String -> Either ParseError Expr
parseExpr input = numberAllocs <$> runParser input do
  skipSpaces
  e <- expr
  eof
  noStrayMarker e
  pure e
