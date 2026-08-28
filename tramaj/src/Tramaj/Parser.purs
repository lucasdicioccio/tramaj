-- | Surface syntax to core AST. Everything the surface offers beyond
-- | `Tramaj.Ast`'s constructors is desugared here rather than represented:
-- |
-- | * `@name=expr` binding lines become nested `Let`s;
-- | * string interpolation becomes `Concat` over the `str` builtin;
-- | * `branch(fallback, p1, v1, ...)` becomes nested `Branch`;
-- | * object shorthand `{foo}` becomes `{"foo": $foo}`;
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
-- |   eval time.
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
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Data.String.CodePoints as SCP
import Data.String.CodeUnits as SCU
import Data.Tuple (Tuple(..), uncurry)
import Parsing (ParseError, Parser, fail, runParser)
import Parsing.Combinators (lookAhead, many, many1, optionMaybe, sepEndBy, skipMany, try)
import Parsing.String (anyChar, char, eof, satisfy, string)
import Parsing.String.Basic (alphaNum, digit, hexDigit, letter)
import Parsing.String.Basic as Basic
import Tramaj.Ast (ActionAdaptation(..), Attribute(..), Expr(..), ParamValue(..), Program(..), Stmt(..), numberAllocs, stmts)

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
  lineComment = string "--" *> skipMany (satisfy (_ /= '\n'))

lexeme :: forall a. P a -> P a
lexeme p = p <* skipSpaces

symbol :: String -> P String
symbol s = lexeme (string s)

charsToString :: Array Char -> String
charsToString = SCU.fromCharArray

manyChars :: P Char -> P String
manyChars p = charsToString <<< Array.fromFoldable <$> many p

many1Chars :: P Char -> P String
many1Chars p = charsToString <<< NEA.toArray <$> (NEA.fromFoldable1 <$> many1 p)

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
  _ <- char '"'
  s <- manyChars (satisfy (\c -> c /= '"' && c /= '`'))
  _ <- char '"' <|> interpolationRefused
  pure s
  where
  interpolationRefused =
    fail "this position must be a literal string, so it cannot contain an interpolation"

-- Strings ---------------------------------------------------------------

-- | A string literal: escape sequences plus backtick interpolation of an
-- | arbitrary expression.
stringLit :: P Expr
stringLit = lexeme do
  _ <- char '"'
  parts <- many (defer \_ -> stringPart)
  _ <- char '"'
  pure (desugarString (Array.fromFoldable parts))
  where
  stringPart :: P StringPart
  stringPart = interpPart <|> (SLit <$> litChunk)

  interpPart :: P StringPart
  interpPart = SInterp <$> (char '`' *> defer (\_ -> expr) <* char '`')

  -- | A run of ordinary characters, with escape sequences resolved as they
  -- | are read. Stops at a closing quote or an interpolation's backtick;
  -- | either can still be written escaped.
  litChunk :: P String
  litChunk = Array.fold <<< Array.fromFoldable <$> many1 (escapeSeq <|> plainRun)

  plainRun :: P String
  plainRun = many1Chars (satisfy (\c -> c /= '"' && c /= '`' && c /= '\\'))

escapeSeq :: P String
escapeSeq = char '\\' *> (unicodeEscape <|> simpleEscape)
  where
  simpleEscape :: P String
  simpleEscape = do
    c <- anyChar
    case c of
      'n' -> pure "\n"
      't' -> pure "\t"
      'r' -> pure "\r"
      '\\' -> pure "\\"
      '"' -> pure "\""
      '`' -> pure "`"
      '0' -> pure "\x0"
      _ -> fail ("unknown escape sequence: \\" <> SCU.singleton c)

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
    _ <- char '{'
    digits <- many1Chars hexDigit
    _ <- char '}'
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

numberLit :: P Expr
numberLit = lexeme $ try do
  intPart <- many1Chars digit
  fracPart <- optionMaybe (try (char '.' *> many1Chars digit))
  let
    fullStr = case fracPart of
      Nothing -> intPart
      Just frac -> intPart <> "." <> frac
  case Number.fromString fullStr of
    Just n -> pure (NumberLit n)
    Nothing -> fail ("invalid number literal: " <> fullStr)

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
  _ <- symbol "["
  elems <- sepEndBy (defer \_ -> expr) (symbol ",")
  _ <- symbol "]"
  pure (ArrayLit (Array.fromFoldable elems))

-- | Object keys may be quoted or bare, and a bare key on its own is
-- | shorthand for reading the binding of the same name:
-- | `{foo, bar: $baz}`.
objectLit :: P Expr
objectLit = lexeme do
  _ <- symbol "{"
  entries <- sepEndBy (defer \_ -> objEntry) (symbol ",")
  _ <- symbol "}"
  pure (ObjectLit (Array.fromFoldable entries))
  where
  objEntry :: P (Tuple String Expr)
  objEntry = try explicitEntry <|> shorthandEntry

  explicitEntry :: P (Tuple String Expr)
  explicitEntry = do
    k <- objectKey
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

-- | `"$sym"` and `"$type"` are reserved across the value domain
-- | (v3-symbols §5.3, v4-types §0): the tag a symbolic or typed envelope
-- | uses to mark a value that is not an ordinary object. An object literal
-- | spelling either as a key is a parse error in every profile, not just the
-- | symbolic one, so a program's legality never depends on which profile
-- | runs it.
reservedKeyRefused :: String -> P Unit
reservedKeyRefused k
  | k == "$sym" || k == "$type" =
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
allocExpr = try do
  _ <- char '?'
  _ <- symbol "("
  keyExpr <- defer \_ -> expr
  _ <- char ')'
  segs <- fieldAccessSuffix
  skipSpaces
  pure (applyFieldAccess (Alloc 0 keyExpr) segs)

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
call = try do
  _ <- optionMaybe (char '$')
  p <- pathTail
  _ <- symbol "("
  args <- sepEndBy (defer \_ -> expr) (symbol ",")
  _ <- char ')'
  segs <- fieldAccessSuffix
  skipSpaces
  pure (applyFieldAccess (Call (Path p.root p.fields) (Array.fromFoldable args)) segs)

lambdaExpr :: P Expr
lambdaExpr = try do
  _ <- symbol "("
  params <- sepEndBy identifier (symbol ",")
  _ <- symbol ")"
  _ <- symbol "=>"
  body <- defer \_ -> expr
  pure (Lambda (Array.fromFoldable params) body)

-- | Grouping, for readability where `Concat` chains get long. Not a
-- | semantic construct: the parse tree it produces is the same as the inner
-- | expression's.
parenExpr :: P Expr
parenExpr = try do
  _ <- symbol "("
  e <- defer \_ -> expr
  _ <- symbol ")"
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
    if Array.elem n [ "map", "filter", "scan", "fold", "branch", "import", "adapt-actions", "constraint" ] then pure n
    else fail "not a special form"
  base <- case name of
    "map" -> binaryShape Map
    "filter" -> binaryShape Filter
    "scan" -> ternaryShape Scan
    "fold" -> ternaryShape Fold
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
    _ <- symbol "("
    a <- defer \_ -> expr
    _ <- symbol ","
    b <- defer \_ -> expr
    _ <- char ')'
    pure (ctor a b)

  ternaryShape :: (Expr -> Expr -> Expr -> Expr) -> P Expr
  ternaryShape ctor = do
    _ <- symbol "("
    a <- defer \_ -> expr
    _ <- symbol ","
    b <- defer \_ -> expr
    _ <- symbol ","
    c <- defer \_ -> expr
    _ <- char ')'
    pure (ctor a b c)

  -- | `branch(fallback, p1, v1, p2, v2, ...)` reads "if p1 then v1, else if
  -- | p2 then v2, ..., else fallback" and lowers to nested `Branch`, so the
  -- | laziness is the core constructor's rather than a rule of its own.
  branchShape :: P Expr
  branchShape = do
    _ <- symbol "("
    fallback <- defer \_ -> expr
    arms <- many (try (symbol "," *> arm))
    _ <- optionMaybe (symbol ",")
    _ <- char ')'
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
    _ <- symbol "("
    name <- staticString
    args <- many (try (symbol "," *> defer \_ -> expr))
    _ <- optionMaybe (symbol ",")
    _ <- char ')'
    pure (Constrain name (Array.fromFoldable args))

  -- | `import("name", {param: expr, other: ctx(path)})`. The name is a
  -- | static literal, and the parameters are a dedicated production rather
  -- | than an ordinary object expression, because `ctx(...)` means
  -- | something only here.
  importShape :: P Expr
  importShape = do
    _ <- symbol "("
    name <- staticString
    _ <- symbol ","
    params <- importParams
    _ <- char ')'
    pure (Import name params)

  importParams :: P (Array (Tuple String ParamValue))
  importParams = do
    _ <- symbol "{"
    entries <- sepEndBy (defer \_ -> paramEntry) (symbol ",")
    _ <- symbol "}"
    pure (Array.fromFoldable entries)

  paramEntry :: P (Tuple String ParamValue)
  paramEntry = try explicitParam <|> shorthandParam

  explicitParam :: P (Tuple String ParamValue)
  explicitParam = do
    k <- objectKey
    _ <- symbol ":"
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
  paramValue = fromContext <|> (PExpr <$> defer \_ -> expr)

  fromContext :: P ParamValue
  fromContext = do
    _ <- try do
      n <- identifier
      _ <- lookAhead (char '(')
      if n == "ctx" then pure n else fail "not a ctx(...) parameter"
    _ <- symbol "("
    p <- pathTail
    skipSpaces
    _ <- char ')'
    skipSpaces
    pure (PFromContext (Array.cons p.root p.fields))

  -- | `adapt-actions(node, prefix("ns:"))`, optionally with a closure for
  -- | the event type and payload.
  adaptActionsShape :: P Expr
  adaptActionsShape = do
    _ <- symbol "("
    target <- defer \_ -> expr
    _ <- symbol ","
    adaptation <- adaptationShape
    fn <- optionMaybe (try (symbol "," *> defer \_ -> expr))
    _ <- optionMaybe (symbol ",")
    _ <- char ')'
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
        _ <- symbol "("
        p <- staticString
        _ <- char ')'
        skipSpaces
        pure (Prefix p)
      _ -> fail "an action adaptation must be identity or prefix(\"...\")"

-- Documents ---------------------------------------------------------------

-- | `.tag(...)` is an element; `.(...)` is a fragment — a tagless element,
-- | introducing siblings with no wrapper.
documentExpr :: P Expr
documentExpr = try do
  _ <- char '.'
  fragmentShape <|> elementShape
  where
  fragmentShape :: P Expr
  fragmentShape = do
    _ <- symbol "("
    children <- sepEndBy (defer \_ -> expr) (symbol ",")
    _ <- symbol ")"
    pure (Fragment (Array.fromFoldable children))

  elementShape :: P Expr
  elementShape = do
    tag <- rawIdent
    skipSpaces
    _ <- symbol "("
    args <- sepEndBy (defer \_ -> elementArg) (symbol ",")
    _ <- symbol ")"
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
    <|> (EArgAttr <$> try namedArg)
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
  _ <- symbol "("
  event <- staticString
  _ <- symbol ","
  key <- staticString
  _ <- symbol ","
  payload <- defer \_ -> expr
  _ <- symbol ")"
  pure (ActionAttr event key payload)

-- | `value(expr)` fills the element's value slot — see `Tramaj.Node` for
-- | what a host does with it.
valueShape :: P Expr
valueShape = do
  _ <- symbol "("
  v <- defer \_ -> expr
  _ <- symbol ")"
  pure v

namedArg :: P Attribute
namedArg = do
  name <- objectKey
  _ <- symbol ":"
  Attr name <$> defer \_ -> expr

-- Precedence ---------------------------------------------------------------

-- | `a <> b`, left-associative and the lowest precedence in the language —
-- | the only infix operator there is.
expr :: P Expr
expr = do
  first <- defer \_ -> operand
  rest <- many (try (symbol "<>" *> defer \_ -> operand))
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
    <|> demandExpr
    <|> documentExpr
    <|> stringLit
    <|> numberLit
    <|> arrayLit
    <|> objectLit

-- Programs -----------------------------------------------------------------

-- | `@name=expr`, one per line. `@` leads a binding definition, mirroring
-- | `$` leading a binding read.
binding :: P (Tuple String Expr)
binding = try do
  _ <- char '@'
  name <- identifier
  _ <- symbol "="
  e <- defer \_ -> expr
  pure (Tuple name e)

-- | `!expr` (v3-symbols §2.2): the fourth statement leader, joining `.`,
-- | `$` and `@`. A statement position only — it may not appear inside an
-- | expression, so there is no operand form for it.
emission :: P Expr
emission = try do
  _ <- char '!'
  defer \_ -> expr

-- | One statement of the surface grammar: a binding or an emission, in the
-- | order the source wrote them — what `Ast.stmts` rebuilds into the
-- | `Let`/`Emit` chain.
statement :: P Stmt
statement = (uncurry SLet <$> binding) <|> (SEmit <$> emission)

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
    let programBody = numberAllocs (stmts (Array.fromFoldable statements) root)
    pure case root of
      Element _ _ _ _ -> DocumentProgram programBody
      Fragment _ -> DocumentProgram programBody
      _ -> ExpressionProgram programBody

parseExpr :: String -> Either ParseError Expr
parseExpr input = numberAllocs <$> runParser input (skipSpaces *> expr <* eof)
