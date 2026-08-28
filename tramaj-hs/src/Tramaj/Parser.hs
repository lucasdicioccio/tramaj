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
      _ <- reservedKeyRefused k
      _ <- symbol ":"
      v <- expr
      pure (k, v)

    shorthandEntry :: P (Text, Expr)
    shorthandEntry = do
      k <- identifier
      pure (k, Path k [])

objectKey :: P Text
objectKey = staticString <|> identifier

-- | @"$sym"@ and @"$type"@ are reserved across the value domain (v3-symbols
-- \S5.3, v4-types \S0): the tag a symbolic or typed envelope uses to mark a
-- value that is not an ordinary object. An object literal spelling either as
-- a key is a parse error in every profile, not just the symbolic one, so a
-- program's legality never depends on which profile runs it.
reservedKeyRefused :: Text -> P ()
reservedKeyRefused k
  | k `elem` (["$sym", "$type"] :: [Text]) =
      fail ("\"" <> T.unpack k <> "\" is a reserved key and cannot be used as an object key")
  | otherwise = pure ()

-- Expressions ------------------------------------------------------------

pathExpr :: P Expr
pathExpr = lexeme $ do
  _ <- char '$'
  (root, fields) <- pathTail
  pure (Path root fields)

-- | @?(key)@ (v3-symbols \S1.2): allocates a symbol. The site is a placeholder
-- here -- 'Tramaj.Ast.numberAllocs' assigns the real one once the whole
-- program has been parsed, so it does not depend on this parser's own
-- traversal order. A projection following it, as in @?(key).field@, is an
-- ordinary field-access suffix, the same mechanism a call result uses.
allocExpr :: P Expr
allocExpr = try $ do
  _ <- char '?'
  _ <- symbol "("
  keyExpr <- expr
  _ <- char ')'
  segs <- fieldAccessSuffix
  skipSpaces
  pure (applyFieldAccess (Alloc 0 keyExpr) segs)

-- | @?ctx.a.b@ (\S1.3): the path MUST be rooted at @ctx@ -- unlike an
-- ordinary read, an unsupplied demand allocates at the root rather than
-- failing, so the language needs to tell the two apart before evaluating
-- anything.
demandExpr :: P Expr
demandExpr = lexeme $ try $ do
  _ <- char '?'
  root <- rawIdent
  if root == "ctx"
    then Demand <$> many (char '.' *> rawIdent)
    else fail "a demand must be rooted at ctx, as in ?ctx.path"

-- | @name(args)@ or @$name(args)@ -- the two spellings mean the same thing.
-- The callee may be a dotted path, so a function reached through an import's
-- values (@$lib.vals.fn(1)@) or an import being given more parameters
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
    if n `elem` (["map", "filter", "scan", "fold", "branch", "import", "adapt-actions", "constraint"] :: [Text])
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
    "constraint" -> constraintShape
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

    -- | @constraint(name, arg1, arg2, ...)@ (v3-symbols \S2.1): a static
    -- string name, like an action's event and key, followed by any number of
    -- ordinary expressions -- zero included, since the language fixes no
    -- signature for any name.
    constraintShape :: P Expr
    constraintShape = do
      _ <- symbol "("
      name <- staticString
      args <- many (try (symbol "," *> expr))
      _ <- optional (symbol ",")
      _ <- char ')'
      pure (Constrain name args)

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

    -- | @ctx(spec.replicas)@ reads this program's own @$ctx.spec.replicas@,
    -- and means exactly that. The separate form exists so the path lands in a
    -- static position the analyses can read; see "Tramaj.Ast"'s 'ParamValue'.
    paramValue :: P ParamValue
    paramValue = (PType <$> markedTypeExpr) <|> fromContext <|> (PExpr <$> expr)

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

-- Types ---------------------------------------------------------------------

-- | The five value-domain shapes v4-types \S1 reserves as type primitives.
-- Fixed and closed, so recognized here rather than left for a later
-- resolution pass to classify.
primNames :: [Text]
primNames = ["string", "number", "bool", "null", "document"]

-- | A type expression (v4-types \S1), in the position a full 'TypeExpr' may
-- appear: a declaration's right-hand side, a record field's type, an array's
-- element type. 'typeUnion' and 'typePrimOrRef' are included here but
-- deliberately excluded from 'typeExprPayload', which is what a union arm's
-- own payload parses with -- see that function for why.
typeExpr :: P TypeExpr
typeExpr = typeVar <|> typeUnion <|> typeArray <|> typeRecord <|> typePrimOrRef

-- | Everything a union arm's payload may be. Deliberately narrower than
-- 'typeExpr': a nested union has no bracketing in the surface grammar, and a
-- bare name (a 'TPrim' or 'TName') is excluded because nothing marks where a
-- nullary arm ends -- @| Dev | Staging@ must parse as two nullary arms, not
-- @Dev@ with a payload named @Staging@, and the same trap would swallow a
-- following statement's root expression whenever it starts with a bare
-- identifier (@true@, or a special form written without its leading @$@).
-- Every constructor kept here starts with a token -- @%@, @[@, @{@ -- that
-- cannot otherwise begin whatever follows a union declaration, so no such
-- ambiguity exists for them.
typeExprPayload :: P TypeExpr
typeExprPayload = typeVar <|> typeArray <|> typeRecord

-- | @%ctx.a.b@ (v4-types \S1): a type hole. The path MUST be rooted at @ctx@,
-- mirroring 'demandExpr' on the value side.
typeVar :: P TypeExpr
typeVar = lexeme $ try $ do
  _ <- char '%'
  root <- rawIdent
  if root == "ctx"
    then TVar <$> many (char '.' *> rawIdent)
    else fail "a type hole must be rooted at ctx, as in %ctx.path"

-- | A @%@-marked type argument, in the two positions v4-types \S2 and \S5
-- both use it: an import parameter's value, and a @!type-constraint@
-- argument. Unlike 'typeVar', the leading @%@ here does not require what
-- follows to be @ctx@ -- @%Json@ (\S2's supply) and @%ctx.payload@ (\S6's
-- forward) are both legal, told apart only after the @%@ itself is seen, so
-- this cannot simply be @char \'%\' *> typeExpr@: that would need a second
-- @%@ before the @ctx@ case. 'typeUnion'\/'typeArray'\/'typeRecord'\/
-- 'typePrimOrRef' need no such adjustment, since none of them themselves
-- start with @%@.
markedTypeExpr :: P TypeExpr
markedTypeExpr = try $ do
  _ <- char '%'
  ctxForward <|> typeUnion <|> typeArray <|> typeRecord <|> typePrimOrRef
  where
    ctxForward :: P TypeExpr
    ctxForward = lexeme $ try $ do
      root <- rawIdent
      if root == ("ctx" :: Text)
        then TVar <$> many (char '.' *> rawIdent)
        else fail "a %-marked value must be ctx.path or a type expression"

typeArray :: P TypeExpr
typeArray = do
  _ <- symbol "["
  t <- typeExpr
  _ <- symbol "]"
  pure (TArray t)

typeRecord :: P TypeExpr
typeRecord = do
  _ <- symbol "{"
  fields <- sepEndBy typeField (symbol ",")
  _ <- symbol "}"
  pure (TRecord fields)
  where
    -- | Unlike an ordinary object literal's 'objectKey', a field name here is
    -- always a bare 'identifier', never a quoted string (v4-types \S1.1's
    -- examples never show one either). This is what keeps a canonical id
    -- (v4-types \S3, "Tramaj.Types") injective: the id grammar uses @:@,
    -- @,@, @[@, @]@ and @|@ as its own delimiters, and an identifier can
    -- never contain any of them, so inserting a field name raw can never be
    -- confused with the surrounding structure. A quoted key could.
    typeField :: P (Text, TypeExpr)
    typeField = do
      k <- identifier
      _ <- symbol ":"
      t <- typeExpr
      pure (k, t)

-- | @| A T | B U | C@ (v4-types \S1.1): one or more arms, each a name with an
-- optional payload -- a nullary arm is an enum case, not a payload-carrying
-- one with an empty payload.
typeUnion :: P TypeExpr
typeUnion = TUnion <$> some (symbol "|" *> unionArm)
  where
    unionArm :: P (Text, Maybe TypeExpr)
    unionArm = do
      name <- identifier
      payload <- optional typeExprPayload
      pure (name, payload)

-- | A bare name (a primitive keyword or a declaration reference) or a
-- library-qualified one, @$lib.types.Name@ (v4-types \S1.1's @\@m :
-- $msg.types.Envelope@). Which of 'TName' and 'TLibRef' applies is a purely
-- syntactic distinction here; resolving either to a primitive, a
-- declaration, or 'UnresolvedType' is a later pass's job (v4-types \S9, not
-- yet implemented).
typePrimOrRef :: P TypeExpr
typePrimOrRef = libRef <|> nameOrPrim
  where
    libRef :: P TypeExpr
    libRef = lexeme $ try $ do
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
      pure (if name `elem` primNames then TPrim name else TName name)

-- | One argument to @!type-constraint@ (v4-types \S5): a @%@-marked type
-- expression, or a literal scalar -- reusing the same primitive literal
-- parsers 'numberLit'\/'keywordLit' use, unwrapped to the scalar the
-- argument actually carries, since it is never wrapped as an evaluable
-- 'Expr' here. A string scalar is 'staticString', not 'stringLit': like a
-- constraint's own name, this position is never computed.
typeConstraintArg :: P TypeConstraintArg
typeConstraintArg = (TCType <$> markedTypeExpr) <|> scalarArg
  where
    scalarArg :: P TypeConstraintArg
    scalarArg =
      (TCScalarStr <$> staticString)
        <|> (asScalar <$> numberLit)
        <|> (asScalar <$> keywordLit)

    asScalar :: Expr -> TypeConstraintArg
    asScalar (NumberLit n) = TCScalarNum n
    asScalar (BoolLit b) = TCScalarBool b
    asScalar NullLit = TCScalarNull
    asScalar (StringLit s) = TCScalarStr s
    asScalar _ = TCScalarNull -- unreachable: 'numberLit'/'keywordLit' only ever produce the cases above

-- | @!type-constraint(name, args...)@ (v4-types \S5, roadmap Phase 12): tried
-- before the general @!expr@ 'emission', since both share the @!@ leader and
-- @type-constraint(...)@ would otherwise parse as an ordinary call to an
-- unbound name.
typeEmission :: P Stmt
typeEmission = try $ do
  _ <- char '!'
  kw <- identifier
  if kw /= ("type-constraint" :: Text) then fail "not a !type-constraint" else pure ()
  _ <- symbol "("
  name <- staticString
  args <- many (try (symbol "," *> typeConstraintArg))
  _ <- optional (symbol ",")
  _ <- char ')'
  skipSpaces
  pure (STypeEmit name args)

-- | @type Name = TypeExpr@ (v4-types \S1.1): the fifth statement leader.
-- Unlike @\@@\/@!@\/@.\@$@ it is a whole keyword rather than a single
-- character, so it is recognized by parsing a full identifier and checking
-- it -- the same device 'keywordLit' uses -- which is what keeps @typeface =
-- ...@ from being chopped into the keyword @type@ plus leftovers.
typeDeclStmt :: P Stmt
typeDeclStmt = try $ do
  kw <- identifier
  if kw /= "type" then fail "not a type declaration" else pure ()
  name <- identifier
  _ <- symbol "="
  STypeDecl name <$> typeExpr

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
    <|> allocExpr
    <|> demandExpr
    <|> documentExpr
    <|> stringLit
    <|> numberLit
    <|> arrayLit
    <|> objectLit

-- Programs -----------------------------------------------------------------

-- | @\@name=expr@ or @\@name : T = expr@ (v4-types \S7), one per line. @\@@
-- leads a binding definition, mirroring @$@ leading a binding read; the
-- optional @: T@ is what tells 'SLet' and 'SAnnotate' apart.
binding :: P Stmt
binding = try $ do
  _ <- char '@'
  name <- identifier
  annot <- optional (try (symbol ":" *> typeExpr))
  _ <- symbol "="
  e <- expr
  pure (maybe (SLet name e) (\t -> SAnnotate name t e) annot)

-- | @!expr@ (v3-symbols \S2.2): the fourth statement leader, joining @.@,
-- @$@ and @\@@. A statement position only -- it may not appear inside an
-- expression, so there is no operand form for it.
emission :: P Expr
emission = try $ do
  _ <- char '!'
  expr

-- | One statement of the surface grammar: a binding (plain or annotated), an
-- emission (value or type), or a type declaration, in the order the source
-- wrote them -- what 'Ast.stmts' rebuilds into the core chain. 'typeEmission'
-- is tried ahead of 'emission' since both share the @!@ leader.
statement :: P Stmt
statement = binding <|> typeEmission <|> (SEmit <$> emission) <|> typeDeclStmt

-- | A program is a sequence of statements and a root expression. Which kind
-- of program it is follows from the root's own form -- a document root is
-- exactly one written as a document -- so there is no mode to declare and no
-- separate entry point to pick.
parseProgram :: Text -> Either (ParseErrorBundle Text Void) Program
parseProgram = runParser program ""
  where
    program :: P Program
    program = do
      skipSpaces
      statements <- many statement
      root <- expr
      skipSpaces
      eof
      let programBody = numberAllocs (stmts statements root)
      pure $ case root of
        Element {} -> DocumentProgram programBody
        Fragment {} -> DocumentProgram programBody
        _ -> ExpressionProgram programBody

parseExpr :: Text -> Either (ParseErrorBundle Text Void) Expr
parseExpr = runParser (numberAllocs <$> (skipSpaces *> expr <* eof)) ""
