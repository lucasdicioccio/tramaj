-- | Surface syntax to core AST. Everything the surface offers beyond
-- "Tramaj.Ast"'s constructors is desugared here rather than represented:
--
-- * @\@name=expr@ binding lines become nested 'Let's;
-- * string interpolation becomes 'Concat' over the @str@ builtin;
-- * @branch(fallback, p1, v1, ...)@ becomes nested 'Branch';
-- * object shorthand @{foo}@ becomes @{"foo": $foo}@;
-- * escape sequences are resolved into the 'StringLit' they denote.
--
-- The grammar keeps three leader characters from v1: @.@ introduces a
-- document, @$@ reads a binding, @\@@ defines one. What changed is that
-- there is now a single expression grammar -- v1's separate template-phase
-- productions (@node@, @nodeArg@, @childArg@, @templateSpecialForm@,
-- @pathOrCallChild@) are gone, because documents are expressions.
--
-- A fourth character is lexical rather than grammatical: @--@ begins a
-- comment that runs to the end of the line. It is discarded by 'skipSpaces'
-- along with whitespace, so it never reaches the AST and there is nothing to
-- desugar.
--
-- Two conventions are load-bearing and carried over deliberately:
--
-- * A special form's 'try' covers /name recognition only/. Once @import@ or
--   @map@ has matched, its shape is parsed without backtracking, so a
--   malformed one is a hard parse error instead of silently falling through
--   to a meaningless 'Call' that would only fail much later at eval time.
-- * A field-access suffix is parsed with no whitespace skipped before it, so
--   @f().rendered@ is a field access while @f()@ followed by a newline and
--   @.div(...)@ is two separate things.
module Tramaj.Parser
  ( parseProgram
  , parseExpr
  ) where

import Data.Char (chr, isAlphaNum, isDigit, isHexDigit, isLetter)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (Void)
import Numeric (readHex)
import Text.Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L
import Tramaj.Ast

type P = Parsec Void Text

-- | One argument of an element, before the arguments are bucketed into
-- attributes, the value slot, and children -- and before the
-- attributes-before-children rule is checked, which needs to see them in
-- source order.
data ElementArg
  = EArgAttr Attribute
  | EArgValue Expr
  | EArgChild Expr

-- | One piece of a double-quoted string, before 'desugarString' folds the
-- pieces into core constructors. Not part of the AST: core.md is explicit
-- that interpolation needs no node of its own.
data StringPart
  = SLit Text
  | SInterp Expr

-- Lexing --------------------------------------------------------------

-- | Whitespace and comments -- everything between two tokens that carries no
-- meaning. Run after every token by 'lexeme', and once before the first one,
-- so a comment is legal anywhere a space is.
--
-- A comment is @--@ to the end of the line. Single-line only: there is no
-- block form, so there is no nesting rule to get wrong and no way to leave one
-- unterminated. @--@ inside a string literal is ordinary text, because string
-- bodies are read character by character and never come through here.
--
-- This is also why 'rawIdent' refuses a trailing hyphen: it is what keeps
-- @$x-- note@ from lexing as a name @x--@ instead of @$x@ and a comment.
skipSpaces :: P ()
skipSpaces = L.space space1 (L.skipLineComment "--") empty

lexeme :: P a -> P a
lexeme p = p <* skipSpaces

symbol :: Text -> P Text
symbol s = lexeme (string s)

-- | An identifier with no trailing whitespace consumed -- used where the
-- following character is significant: inside dotted paths and after an
-- element's @.@. Internal hyphens are allowed (kebab-case), so @$my-var@ and
-- @.my-tag@ are one token each.
--
-- /Internal/ is enforced, not merely documented: a hyphen is part of the name
-- only when another name character follows it. Without that, a name would
-- swallow the @--@ of a comment written directly after it, and @$x-- note@
-- would read as the name @x--@.
rawIdent :: P Text
rawIdent = do
  c0 <- satisfy isLetter
  cs <- many identRest
  pure (T.pack (c0 : cs))
  where
    identRest :: P Char
    identRest = identChar <|> try (char '-' <* lookAhead identChar)

    identChar :: P Char
    identChar = satisfy (\c -> isAlphaNum c || c == '_')

identifier :: P Text
identifier = lexeme rawIdent

pathTail :: P (Text, [Text])
pathTail = do
  root <- rawIdent
  rest <- many (char '.' *> rawIdent)
  pure (root, rest)

-- | Zero or more @.field@ segments directly after a closing @)@. Deliberately
-- runs before any whitespace is skipped -- see the module header.
fieldAccessSuffix :: P [Text]
fieldAccessSuffix = many (try (char '.' *> rawIdent))

applyFieldAccess :: Expr -> [Text] -> Expr
applyFieldAccess base [] = base
applyFieldAccess base segs = FieldAccess base segs

-- | A double-quoted string with no interpolation: every statically-required
-- position uses this, so what the source says is what the analysis sees.
-- Import names, action events and keys, adaptation prefixes and object keys
-- are all parsed with it.
--
-- A backtick here is an error rather than a literal backtick. Someone writing
-- @import("lib-`$x`")@ means interpolation, and silently handing them a
-- library named @lib-`$x`@ would answer a question they did not ask -- the
-- whole point of the position being static is that it cannot be computed.
staticString :: P Text
staticString = lexeme $ do
  _ <- char '"'
  s <- takeWhileP Nothing (\c -> c /= '"' && c /= '`')
  _ <- char '"' <|> interpolationRefused
  pure s
  where
    interpolationRefused =
      fail "this position must be a literal string, so it cannot contain an interpolation"

-- Strings ---------------------------------------------------------------

-- | A string literal: escape sequences plus backtick interpolation of an
-- arbitrary expression.
stringLit :: P Expr
stringLit = lexeme $ do
  _ <- char '"'
  parts <- many stringPart
  _ <- char '"'
  pure (desugarString parts)
  where
    stringPart :: P StringPart
    stringPart = interpPart <|> (SLit <$> litChunk)

    interpPart :: P StringPart
    interpPart = SInterp <$> (char '`' *> expr <* char '`')

    -- | A run of ordinary characters, with escape sequences resolved as they
    -- are read. Stops at a closing quote or an interpolation's backtick;
    -- either can still be written escaped.
    litChunk :: P Text
    litChunk = T.concat <$> some (escapeSeq <|> plainRun)

    plainRun :: P Text
    plainRun = takeWhile1P Nothing (\c -> c /= '"' && c /= '`' && c /= '\\')

escapeSeq :: P Text
escapeSeq = char '\\' *> (unicodeEscape <|> simpleEscape)
  where
    simpleEscape :: P Text
    simpleEscape = do
      c <- anySingle
      case c of
        'n' -> pure "\n"
        't' -> pure "\t"
        'r' -> pure "\r"
        '\\' -> pure "\\"
        '"' -> pure "\""
        '`' -> pure "`"
        '0' -> pure "\0"
        _ -> fail ("unknown escape sequence: \\" <> [c])

    -- | @\\u{1F600}@ -- braced so it is not limited to four hex digits and
    -- does not need surrogate pairs.
    unicodeEscape :: P Text
    unicodeEscape = do
      _ <- char 'u'
      _ <- char '{'
      digits <- takeWhile1P (Just "hex digit") isHexDigit
      _ <- char '}'
      case readHex (T.unpack digits) of
        [(n, "")] | n <= 0x10FFFF -> pure (T.singleton (chr n))
        _ -> fail ("invalid unicode escape: \\u{" <> T.unpack digits <> "}")

-- | Folds string pieces into core constructors. A string with no
-- interpolation is a plain 'StringLit'; otherwise each interpolated
-- expression is rendered through the @str@ builtin and the pieces are joined
-- with 'Concat', which is exactly what @"a `$x` b"@ means.
desugarString :: [StringPart] -> Expr
desugarString parts = case map partExpr (coalesce parts) of
  [] -> StringLit ""
  (e : es) -> foldl Concat e es
  where
    partExpr (SLit t) = StringLit t
    partExpr (SInterp e) = Call (Path "str" []) [e]

    -- | Adjacent literal chunks (an escape sequence splits one in two) are
    -- merged, so an escape does not leave a stray 'Concat' in the AST.
    coalesce (SLit a : SLit b : rest) = coalesce (SLit (a <> b) : rest)
    coalesce (p : rest) = p : coalesce rest
    coalesce [] = []

-- Literals ---------------------------------------------------------------

numberLit :: P Expr
numberLit = lexeme $ try $ do
  intPart <- takeWhile1P (Just "digit") isDigit
  fracPart <- optional (try (char '.' *> takeWhile1P (Just "digit") isDigit))
  let fullStr = maybe intPart (\frac -> intPart <> "." <> frac) fracPart
  case reads (T.unpack fullStr) :: [(Double, String)] of
    [(n, "")] -> pure (NumberLit n)
    _ -> fail ("invalid number literal: " <> T.unpack fullStr)

-- | @true@\/@false@\/@null@ matched as whole identifiers, so a longer name
-- merely starting with one (@truest@, @nullable@) is not chopped into a
-- literal plus leftovers.
keywordLit :: P Expr
keywordLit = try $ do
  name <- identifier
  case name of
    "true" -> pure (BoolLit True)
    "false" -> pure (BoolLit False)
    "null" -> pure NullLit
    _ -> fail "not a literal keyword"

arrayLit :: P Expr
arrayLit = lexeme $ do
  _ <- symbol "["
  elems <- sepEndBy expr (symbol ",")
  _ <- symbol "]"
  pure (ArrayLit elems)

-- | Object keys may be quoted or bare, and a bare key on its own is shorthand
-- for reading the binding of the same name: @{foo, bar: $baz}@.
objectLit :: P Expr
objectLit = lexeme $ do
  _ <- symbol "{"
  entries <- sepEndBy objEntry (symbol ",")
  _ <- symbol "}"
  pure (ObjectLit entries)
  where
    objEntry :: P (Text, Expr)
    objEntry = try explicitEntry <|> shorthandEntry

    explicitEntry :: P (Text, Expr)
    explicitEntry = do
      k <- objectKey
      _ <- symbol ":"
      v <- expr
      pure (k, v)

    shorthandEntry :: P (Text, Expr)
    shorthandEntry = do
      k <- identifier
      pure (k, Path k [])

objectKey :: P Text
objectKey = staticString <|> identifier

-- Expressions ------------------------------------------------------------

pathExpr :: P Expr
pathExpr = lexeme $ do
  _ <- char '$'
  (root, fields) <- pathTail
  pure (Path root fields)

-- | @name(args)@ or @$name(args)@ -- the two spellings mean the same thing.
-- The callee may be a dotted path, so a function reached through an import's
-- values (@$lib.vals.fn(1)@) or a partial import awaiting completion
-- (@$deployment({...})@) is callable directly.
call :: P Expr
call = try $ do
  _ <- optional (char '$')
  (root, fields) <- pathTail
  _ <- symbol "("
  args <- sepEndBy expr (symbol ",")
  _ <- char ')'
  segs <- fieldAccessSuffix
  skipSpaces
  pure (applyFieldAccess (Call (Path root fields) args) segs)

lambdaExpr :: P Expr
lambdaExpr = try $ do
  _ <- symbol "("
  params <- sepEndBy identifier (symbol ",")
  _ <- symbol ")"
  _ <- symbol "=>"
  Lambda params <$> expr

-- | Grouping, for readability where 'Concat' chains get long. Not a semantic
-- construct: the parse tree it produces is the same as the inner expression's.
parenExpr :: P Expr
parenExpr = try $ do
  _ <- symbol "("
  e <- expr
  _ <- symbol ")"
  pure e

-- | The forms whose evaluation the language defines itself, rather than
-- leaving to a builtin: the array primitives (whose function argument needs a
-- fresh binding per element), 'Branch' (which must not evaluate the arm it
-- does not select), imports, and action adaptation.
--
-- The 'try' covers name recognition only -- see the module header.
specialForm :: P Expr
specialForm = do
  name <- try $ do
    _ <- optional (char '$')
    n <- identifier
    if n `elem` (["map", "filter", "scan", "fold", "branch", "import", "adapt-actions"] :: [Text])
      then pure n
      else fail "not a special form"
  base <- case name of
    "map" -> binaryShape Map
    "filter" -> binaryShape Filter
    "scan" -> ternaryShape Scan
    "fold" -> ternaryShape Fold
    "branch" -> branchShape
    "import" -> importShape
    "adapt-actions" -> adaptActionsShape
    _ -> fail "unreachable: name already checked against the recognized special-form set"
  segs <- fieldAccessSuffix
  skipSpaces
  pure (applyFieldAccess base segs)
  where
    binaryShape :: (Expr -> Expr -> Expr) -> P Expr
    binaryShape ctor = do
      _ <- symbol "("
      a <- expr
      _ <- symbol ","
      b <- expr
      _ <- char ')'
      pure (ctor a b)

    ternaryShape :: (Expr -> Expr -> Expr -> Expr) -> P Expr
    ternaryShape ctor = do
      _ <- symbol "("
      a <- expr
      _ <- symbol ","
      b <- expr
      _ <- symbol ","
      c <- expr
      _ <- char ')'
      pure (ctor a b c)

    -- | @branch(fallback, p1, v1, p2, v2, ...)@ reads "if p1 then v1, else if
    -- p2 then v2, ..., else fallback" and lowers to nested 'Branch', so the
    -- laziness is the core constructor's rather than a rule of its own.
    branchShape :: P Expr
    branchShape = do
      _ <- symbol "("
      fallback <- expr
      arms <- many (try (symbol "," *> arm))
      _ <- optional (symbol ",")
      _ <- char ')'
      pure (foldr (\(p, v) acc -> Branch p v acc) fallback arms)

    arm :: P (Expr, Expr)
    arm = do
      p <- expr
      _ <- symbol ","
      v <- expr
      pure (p, v)

    -- | @import("name", {param: expr, other: ctx(path)})@. The name is a
    -- static literal, and the parameters are a dedicated production rather
    -- than an ordinary object expression, because @ctx(...)@ means something
    -- only here.
    importShape :: P Expr
    importShape = do
      _ <- symbol "("
      name <- staticString
      _ <- symbol ","
      params <- importParams
      _ <- char ')'
      pure (Import name params)

    importParams :: P [(Text, ParamValue)]
    importParams = do
      _ <- symbol "{"
      entries <- sepEndBy paramEntry (symbol ",")
      _ <- symbol "}"
      pure entries

    paramEntry :: P (Text, ParamValue)
    paramEntry = try explicitParam <|> shorthandParam

    explicitParam :: P (Text, ParamValue)
    explicitParam = do
      k <- objectKey
      _ <- symbol ":"
      v <- paramValue
      pure (k, v)

    shorthandParam :: P (Text, ParamValue)
    shorthandParam = do
      k <- identifier
      pure (k, PExpr (Path k []))

    -- | @ctx(spec.replicas)@ declares that this parameter comes from the
    -- context supplied when the import is completed -- deliberately distinct
    -- from @$ctx.spec.replicas@, which reads the /current/ context now.
    paramValue :: P ParamValue
    paramValue = fromContext <|> (PExpr <$> expr)

    fromContext :: P ParamValue
    fromContext = do
      _ <- try $ do
        n <- identifier
        _ <- lookAhead (char '(')
        if n == ("ctx" :: Text) then pure n else fail "not a ctx(...) parameter"
      _ <- symbol "("
      (root, fields) <- pathTail
      skipSpaces
      _ <- char ')'
      skipSpaces
      pure (PFromContext (root : fields))

    -- | @adapt-actions(node, prefix("ns:"))@, optionally with a closure for
    -- the event type and payload.
    adaptActionsShape :: P Expr
    adaptActionsShape = do
      _ <- symbol "("
      target <- expr
      _ <- symbol ","
      adaptation <- adaptationShape
      fn <- optional (try (symbol "," *> expr))
      _ <- optional (symbol ",")
      _ <- char ')'
      pure (AdaptActions target adaptation fn)

    -- | Two forms only, never an arbitrary rewriting function: this is what
    -- keeps the set of action keys a program can emit enumerable without
    -- evaluating it.
    adaptationShape :: P ActionAdaptation
    adaptationShape = do
      name <- identifier
      case name of
        "identity" -> pure Identity
        "prefix" -> do
          _ <- symbol "("
          p <- staticString
          _ <- char ')'
          skipSpaces
          pure (Prefix p)
        _ -> fail "an action adaptation must be identity or prefix(\"...\")"

-- Documents ---------------------------------------------------------------

-- | @.tag(...)@ is an element; @.(...)@ is a fragment -- a tagless element,
-- introducing siblings with no wrapper.
documentExpr :: P Expr
documentExpr = try $ do
  _ <- char '.'
  choice [fragmentShape, elementShape]
  where
    fragmentShape :: P Expr
    fragmentShape = do
      _ <- symbol "("
      children <- sepEndBy expr (symbol ",")
      _ <- symbol ")"
      pure (Fragment children)

    elementShape :: P Expr
    elementShape = do
      tag <- rawIdent
      skipSpaces
      _ <- symbol "("
      args <- sepEndBy elementArg (symbol ",")
      _ <- symbol ")"
      buildElement tag args

-- | Buckets an element's arguments and enforces the one ordering rule:
-- everything in attribute position comes before any child.
buildElement :: Text -> [ElementArg] -> P Expr
buildElement tag args = do
  ensureAttrsBeforeChildren
  val <- singleValueSlot
  pure (Element tag [a | EArgAttr a <- args] val [c | EArgChild c <- args])
  where
    ensureAttrsBeforeChildren :: P ()
    ensureAttrsBeforeChildren
      | fst (foldl step (True, False) args) = pure ()
      | otherwise = fail "attributes, action(...) and value(...) must all come before an element's children"
      where
        step (ok, seenChild) arg = case arg of
          EArgChild _ -> (ok, True)
          _ -> (ok && not seenChild, seenChild)

    singleValueSlot :: P Expr
    singleValueSlot = case [v | EArgValue v <- args] of
      [] -> pure NullLit
      [v] -> pure v
      _ -> fail "an element can have at most one value(...)"

elementArg :: P ElementArg
elementArg =
  attributePositionArg
    <|> (EArgAttr <$> try namedArg)
    <|> (EArgChild <$> expr)

-- | @action(...)@ and @value(...)@, the two forms that mean something only in
-- an element's argument list.
--
-- As with 'specialForm', the 'try' covers name recognition only: once
-- @action@ has been seen applied to arguments, a malformed one is a parse
-- error. Letting it backtrack would leave @action("on-click", $computed, {})@
-- parsing happily as a call to an unbound function named @action@, and the
-- static-key restriction would be enforced by nothing at all.
--
-- Recognition needs the following @(@, so @action@ and @value@ remain usable
-- as ordinary attribute names: @value: 1@ is an attribute, @value(1)@ is the
-- value slot.
attributePositionArg :: P ElementArg
attributePositionArg = do
  name <- try $ do
    n <- identifier
    _ <- lookAhead (char '(')
    if n `elem` (["action", "value"] :: [Text])
      then pure n
      else fail "not an action(...) or value(...) form"
  case name of
    "action" -> EArgAttr <$> actionShape
    _ -> EArgValue <$> valueShape

-- | @action("on-click", "save", payloadExpr)@. Both the event and the key are
-- static literals; only the payload is computed. The host still owns the
-- event vocabulary -- what is fixed is the position, not the words allowed in
-- it.
actionShape :: P Attribute
actionShape = do
  _ <- symbol "("
  event <- staticString
  _ <- symbol ","
  key <- staticString
  _ <- symbol ","
  payload <- expr
  _ <- symbol ")"
  pure (ActionAttr event key payload)

-- | @value(expr)@ fills the element's value slot -- see "Tramaj.Node" for
-- what a host does with it.
valueShape :: P Expr
valueShape = do
  _ <- symbol "("
  v <- expr
  _ <- symbol ")"
  pure v

namedArg :: P Attribute
namedArg = do
  name <- objectKey
  _ <- symbol ":"
  Attr name <$> expr

-- Precedence ---------------------------------------------------------------

-- | @a \<\> b@, left-associative and the lowest precedence in the language --
-- the only infix operator there is.
expr :: P Expr
expr = do
  first <- operand
  rest <- many (try (symbol "<>" *> operand))
  pure (foldl Concat first rest)

-- | Alternatives are ordered so that a longer form is tried before a prefix of
-- it: keyword literals before paths and calls, special forms before ordinary
-- calls, lambdas before parenthesized expressions.
operand :: P Expr
operand =
  keywordLit
    <|> lambdaExpr
    <|> parenExpr
    <|> specialForm
    <|> call
    <|> pathExpr
    <|> documentExpr
    <|> stringLit
    <|> numberLit
    <|> arrayLit
    <|> objectLit

-- Programs -----------------------------------------------------------------

-- | @\@name=expr@, one per line. @\@@ leads a binding definition, mirroring
-- @$@ leading a binding read.
binding :: P (Text, Expr)
binding = try $ do
  _ <- char '@'
  name <- identifier
  _ <- symbol "="
  e <- expr
  pure (name, e)

-- | A program is a sequence of bindings and a root expression. Which kind of
-- program it is follows from the root's own form -- a document root is
-- exactly one written as a document -- so there is no mode to declare and no
-- separate entry point to pick.
parseProgram :: Text -> Either (ParseErrorBundle Text Void) Program
parseProgram = runParser program ""
  where
    program :: P Program
    program = do
      skipSpaces
      bindings <- many binding
      root <- expr
      skipSpaces
      eof
      let body = lets bindings root
      pure $ case root of
        Element {} -> DocumentProgram body
        Fragment {} -> DocumentProgram body
        _ -> ExpressionProgram body

parseExpr :: Text -> Either (ParseErrorBundle Text Void) Expr
parseExpr = runParser (skipSpaces *> expr <* eof) ""
