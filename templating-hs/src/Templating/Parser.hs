-- | Parser combinators (built on @megaparsec@) for the grammar in
-- @../specs/templating-language.md@ -- ported from
-- @../templating/src/Templating/Parser.purs@ (built on
-- @purescript-parsing@); same grammar, same three-leader-character
-- convention (@.@ element, @$@ getter, @@@ setter), same precedence order
-- in 'expr'/'node'. See that file's Haddock comments for the full grammar
-- rationale -- comments here only cover Haskell-specific differences.
--
-- One structural difference from the PureScript parser: @purescript-parsing@
-- backtracks on failure by default (a failed alternative doesn't consume
-- input unless explicitly committed via its own internal logic), so the
-- PureScript source sprinkles explicit @try@ only where one alternative's
-- prefix overlaps another's. @megaparsec@ defaults the other way --
-- 'Text.Megaparsec.<|>' only tries the next alternative if the first
-- failed *without consuming input* -- so this port wraps every alternative
-- in 'try' consistently in the ambiguous @expr@\/@node@\/@templateSpecialForm@
-- productions, rather than replicating the PureScript source's exact
-- placement one-for-one.
module Templating.Parser
  ( parseProgram
  , parseJsonProgram
  , parseExpr
  , parseTemplateNode
  ) where

import Data.Char (isAlphaNum, isLetter)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (Void)
import Templating.Ast
import Text.Megaparsec
import Text.Megaparsec.Char

type P = Parsec Void Text

-- | One parsed node-arg, before it's bucketed into 'TElement'\'s attrs\/
-- action\/children.
data NodeArg
  = NArgNamed (Text, Expr)
  | NArgAction TAction
  | NArgChild TemplateNode

-- Lexing --------------------------------------------------------------

skipSpaces :: P ()
skipSpaces = space

lexeme :: P a -> P a
lexeme p = p <* skipSpaces

symbol :: Text -> P Text
symbol s = lexeme (string s)

-- | Identifier with no trailing whitespace consumed -- used inside paths
-- (@ctx.items@, no space around @.@) and node tags (@.tr@, no space after
-- @.@). Allows internal hyphens (kebab-case) as well as the usual
-- alphanumeric\/underscore run, as long as the first character is a letter.
rawIdent :: P Text
rawIdent = do
  c0 <- satisfy isLetter
  cs <- takeWhileP Nothing (\c -> isAlphaNum c || c == '_' || c == '-')
  pure (T.cons c0 cs)

identifier :: P Text
identifier = lexeme rawIdent

pathTail :: P [Text]
pathTail = do
  first <- rawIdent
  rest <- many (char '.' *> rawIdent)
  pure (first : rest)

-- | A double-quoted key with no interpolation -- used for attribute keys
-- that aren't valid bare identifiers, and for JSON-object-literal keys.
quotedKey :: P Text
quotedKey = lexeme (char '"' *> takeWhileP Nothing (/= '"') <* char '"')

attrKey :: P Text
attrKey = identifier <|> quotedKey

-- Computation-phase expressions ----------------------------------------

pathExpr :: P Expr
pathExpr = lexeme (Path <$> (char '$' *> pathTail))

numberLit :: P Expr
numberLit = lexeme $ try $ do
  intPart <- takeWhile1P (Just "digit") (`elem` ['0' .. '9'])
  fracPart <- optional (char '.' *> takeWhile1P (Just "digit") (`elem` ['0' .. '9']))
  let fullStr = case fracPart of
        Nothing -> intPart
        Just frac -> intPart <> "." <> frac
  case reads (T.unpack fullStr) :: [(Double, String)] of
    [(n, "")] -> pure (NumberLit n)
    _ -> fail ("invalid number literal: " <> T.unpack fullStr)

-- | @true@\/@false@ as whole identifiers, not just the literal text -- so a
-- longer name that merely starts with one (like @truest@) isn't chopped
-- into a bogus bool-literal-plus-leftover.
boolLit :: P Expr
boolLit = try $ do
  name <- identifier
  case name of
    "true" -> pure (BoolLit True)
    "false" -> pure (BoolLit False)
    _ -> fail "not a boolean literal"

{- | A backtick-delimited interpolation holds an arbitrary 'expr'.

TODO: no escape sequences -- 'litPart' stops at @\"@ and at a backtick, so
neither character can appear in a string at all. That makes generating quoted
output (an HTML attribute, a @\<script\>@ block, JSON inside JSON) awkward,
which server-side hosts emitting text hit sooner than a DOM-building one. See
the TODO in @specs/llm.md@ §3.2; a fix has to land in both parsers at once.
-}
stringLit :: P Expr
stringLit = lexeme $ do
  _ <- char '"'
  parts <- many stringPart
  _ <- char '"'
  pure (StringLit parts)
  where
    stringPart :: P StringPart
    stringPart = interpPart <|> litPart

    interpPart :: P StringPart
    interpPart = try $ do
      _ <- char '`'
      e <- expr
      _ <- char '`'
      pure (Interp e)

    litPart :: P StringPart
    litPart = Lit <$> takeWhile1P Nothing (\c -> c /= '"' && c /= '`')

-- | A function call -- @name(args)@ or @$name(args)@. Both spellings mean
-- the same thing: look up @name@ in the environment and apply it.
call :: P Expr
call = try $ do
  _ <- optional (char '$')
  name <- identifier
  _ <- symbol "("
  args <- sepEndBy expr (symbol ",")
  _ <- symbol ")"
  pure (Call [name] args)

arrayLit :: P Expr
arrayLit = lexeme $ do
  _ <- symbol "["
  elems <- sepEndBy expr (symbol ",")
  _ <- symbol "]"
  pure (ArrayLit elems)

objectLit :: P Expr
objectLit = lexeme $ do
  _ <- symbol "{"
  entries <- sepEndBy objEntry (symbol ",")
  _ <- symbol "}"
  pure (ObjectLit entries)
  where
    objEntry :: P (Text, Expr)
    objEntry = do
      k <- quotedKey
      _ <- symbol ":"
      v <- expr
      pure (k, v)

-- | @(p1, p2, ...) => body@ -- a lambda *value*, not tied to any particular
-- call site.
lambdaExpr :: P Expr
lambdaExpr = try $ do
  _ <- symbol "("
  params <- sepEndBy identifier (symbol ",")
  _ <- symbol ")"
  _ <- symbol "=>"
  body <- expr
  pure (LambdaExpr params body)

-- | The functional array primitives -- @map(arr, fn)@, @filter(arr, fn)@,
-- @scan(arr, init, fn)@, @fold(arr, init, fn)@ -- parsed as their own
-- dedicated shapes (not through the generic 'call' production) since
-- @arr@\'s elements need binding into @fn@\'s closure environment fresh per
-- element, which the uniform eagerly-evaluate-every-argument 'Call'
-- dispatch can't express.
specialFormExpr :: P Expr
specialFormExpr = try $ do
  _ <- optional (char '$')
  name <- identifier
  case name of
    "map" -> mapShape
    "filter" -> filterShape
    "scan" -> scanShape
    "fold" -> foldShape
    _ -> fail "not a map/filter/scan/fold special form"
  where
    mapShape :: P Expr
    mapShape = do
      _ <- symbol "("
      arr <- expr
      _ <- symbol ","
      fn <- expr
      _ <- symbol ")"
      pure (MapExpr arr fn)

    filterShape :: P Expr
    filterShape = do
      _ <- symbol "("
      arr <- expr
      _ <- symbol ","
      fn <- expr
      _ <- symbol ")"
      pure (FilterExpr arr fn)

    scanShape :: P Expr
    scanShape = do
      _ <- symbol "("
      arr <- expr
      _ <- symbol ","
      initE <- expr
      _ <- symbol ","
      fn <- expr
      _ <- symbol ")"
      pure (ScanExpr arr initE fn)

    foldShape :: P Expr
    foldShape = do
      _ <- symbol "("
      arr <- expr
      _ <- symbol ","
      initE <- expr
      _ <- symbol ","
      fn <- expr
      _ <- symbol ")"
      pure (FoldExpr arr initE fn)

-- | @expr := bool-lit | lambda-expr | map\/filter\/scan-special-form | call
-- | path | string-lit | number-lit | array-lit | object-lit@. Every
-- alternative is tried in order via megaparsec's backtracking @<|>@; each
-- alternative that shares a leading token with another (identifiers,
-- mainly) wraps itself in its own 'try' so a mismatch backtracks cleanly
-- to the next alternative.
expr :: P Expr
expr =
  boolLit
    <|> lambdaExpr
    <|> specialFormExpr
    <|> call
    <|> pathExpr
    <|> stringLit
    <|> numberLit
    <|> arrayLit
    <|> objectLit

-- | @\@@ leads a binding *definition* (a setter -- @\@foo=$bar@ defines
-- @foo@), symmetric with @$@ leading a binding *read* (a getter).
binding :: P (Text, Expr)
binding = try $ do
  _ <- char '@'
  name <- identifier
  _ <- symbol "="
  e <- expr
  pure (name, e)

compBlock :: P [(Text, Expr)]
compBlock = many (try binding)

-- Template-phase nodes ---------------------------------------------------

namedArg :: P (Text, Expr)
namedArg = try $ do
  name <- attrKey
  _ <- symbol ":"
  v <- expr
  pure (name, v)

-- | @action(eventTypeExpr, keyExpr, payloadExpr)@ -- appears directly among
-- a node's arguments, not as @key: value@.
actionArg :: P TAction
actionArg = try $ do
  name <- identifier
  if name /= "action"
    then fail "not an action(...) form"
    else do
      _ <- symbol "("
      eventTypeE <- expr
      _ <- symbol ","
      keyE <- expr
      _ <- symbol ","
      payloadE <- expr
      _ <- symbol ")"
      pure (TAction eventTypeE keyE payloadE)

-- | Any @$@-prefixed child form that isn't @map(...)@\/@branch(...)@: a
-- bare path (@$ctx.title@) or a call (@$foo("123")@).
pathOrCallChild :: P TemplateNode
pathOrCallChild = lexeme $ try $ do
  segs <- char '$' *> pathTail
  hasParen <- optional (symbol "(")
  case hasParen of
    Nothing -> pure (TValue (Path segs))
    Just _ -> do
      args <- sepEndBy expr (symbol ",")
      _ <- symbol ")"
      pure (TValue (Call segs args))

-- | The template-block counterparts of 'specialFormExpr': @map(arrExpr,
-- (item) => node)@ produces a 'TMap' child; @branch(fallbackNode, pred1,
-- node1, pred2, node2, ...)@ produces a 'TBranch' child, selecting exactly
-- one node.
templateSpecialForm :: P TemplateNode
templateSpecialForm = try $ do
  _ <- optional (char '$')
  name <- identifier
  case name of
    "map" -> mapNodeShape
    "branch" -> branchNodeShape
    _ -> fail "not a map/branch special form"
  where
    mapNodeShape :: P TemplateNode
    mapNodeShape = do
      _ <- symbol "("
      arr <- expr
      _ <- symbol ","
      _ <- symbol "("
      itemName <- identifier
      _ <- symbol ")"
      _ <- symbol "=>"
      body <- node
      _ <- symbol ")"
      pure (TMap arr itemName body)

    branchNodeShape :: P TemplateNode
    branchNodeShape = do
      _ <- symbol "("
      fallback <- node
      pairs <- many (try (symbol "," *> pairP))
      _ <- optional (symbol ",")
      _ <- symbol ")"
      pure (TBranch fallback pairs)

    pairP :: P (Expr, TemplateNode)
    pairP = do
      p <- expr
      _ <- symbol ","
      n <- node
      pure (p, n)

-- | @node@, @childArg@, @nodeArg@ and (via the lambda\/branch bodies above)
-- even @templateSpecialForm@ form one mutually recursive family.
childArg :: P TemplateNode
childArg =
  node
    <|> templateSpecialForm
    <|> pathOrCallChild
    <|> (TValue <$> stringLit)

nodeArg :: P NodeArg
nodeArg =
  (NArgAction <$> try actionArg)
    <|> (NArgNamed <$> try namedArg)
    <|> (NArgChild <$> childArg)

node :: P TemplateNode
node = lexeme $ try $ do
  _ <- char '.'
  tag <- rawIdent
  skipSpaces
  _ <- symbol "("
  argsList <- sepEndBy nodeArg (symbol ",")
  _ <- symbol ")"
  ensureAttrsBeforeChildren argsList
  action <- extractSingleAction argsList
  let attrs = [t | NArgNamed t <- argsList]
      children = [c | NArgChild c <- argsList]
  pure (TElement tag attrs action children)
  where
    -- | Hard-enforces "all attributes/action before sibling nodes": once a
    -- @child-arg@ has been seen in the list, a further @named-arg@ or
    -- @action(...)@ is a parse error rather than silently
    -- accepted-but-reordered.
    ensureAttrsBeforeChildren :: [NodeArg] -> P ()
    ensureAttrsBeforeChildren argsList =
      if fst (foldl step (True, False) argsList)
        then pure ()
        else fail "attributes and action(...) must all come before sibling child nodes in a node's argument list"
      where
        step (ok, seenChild) arg = case arg of
          NArgNamed _ -> (ok && not seenChild, seenChild)
          NArgAction _ -> (ok && not seenChild, seenChild)
          NArgChild _ -> (ok, True)

    -- | A node may have at most one @action(...)@.
    extractSingleAction :: [NodeArg] -> P (Maybe TAction)
    extractSingleAction argsList = case [a | NArgAction a <- argsList] of
      [] -> pure Nothing
      [a] -> pure (Just a)
      _ -> fail "a node can have at most one action(...)"

-- Program ----------------------------------------------------------------

program :: P Program
program = do
  skipSpaces
  bindings <- compBlock
  root <- node
  skipSpaces
  eof
  pure (Program bindings root)

parseProgram :: Text -> Either (ParseErrorBundle Text Void) Program
parseProgram input = runParser program "" input

-- | Same computation block as 'program', but the root is an 'expr' rather
-- than a 'node' -- the parser half of the JSON-producing mode (see
-- 'Templating.Eval.evalJsonProgram'). The two roots can never be confused:
-- an element root always starts with @.@, which no expression form does.
jsonProgram :: P JsonProgram
jsonProgram = do
  skipSpaces
  bindings <- compBlock
  root <- expr
  skipSpaces
  eof
  pure (JsonProgram bindings root)

parseJsonProgram :: Text -> Either (ParseErrorBundle Text Void) JsonProgram
parseJsonProgram input = runParser jsonProgram "" input

parseExpr :: Text -> Either (ParseErrorBundle Text Void) Expr
parseExpr input = runParser (skipSpaces *> expr <* eof) "" input

parseTemplateNode :: Text -> Either (ParseErrorBundle Text Void) TemplateNode
parseTemplateNode input = runParser (skipSpaces *> node <* eof) "" input
