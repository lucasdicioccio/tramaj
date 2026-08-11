-- | Parser combinators (built on `purescript-parsing`) for the grammar in
-- | `specs/templating-language.md` (main repo): a computation block of
-- | `@name=expr` bindings, followed by one HAML-like template-block node.
-- | Whitespace (including newlines) is insignificant everywhere except as
-- | a token separator — the "blank line" between blocks in the original
-- | sketch is not load-bearing here, since bindings and the template root
-- | are unambiguous by their leading token (`@` vs `.`).
-- |
-- | Three leader characters, one job each: `.` starts an HTML-ish element
-- | (`.tag(...)`), `$` reads a bound name/`$ctx`-path (a "getter"), `@`
-- | defines one in the computation block (a "setter" — `@foo=$bar`). A
-- | bare `name(args)` (no sigil) is the one narrow exception: it's always
-- | a call to one of the fixed builtins, never a binding reference — `$`
-- | is also accepted there (`$name(args)`) since a trailing `(` already
-- | disambiguates a call from a plain value reference either way.
module Templating.Parser
  ( parseProgram
  , parseExpr
  , parseTemplateNode
  ) where

import Prelude

import Control.Alt ((<|>))
import Control.Lazy (defer)
import Data.Array as Array
import Data.Either (Either)
import Data.Maybe (Maybe(..))
import Data.Number as Number
import Data.String.CodeUnits as SCU
import Data.Tuple (Tuple(..), fst)
import Parsing (ParseError, Parser, fail, runParser)
import Parsing.Combinators (many, many1, optionMaybe, sepEndBy, try)
import Parsing.String (char, eof, satisfy, string)
import Parsing.String.Basic (alphaNum, digit, letter, skipSpaces)
import Templating.Ast (Expr(..), Program, StringPart(..), TAction(..), TemplateNode(..))

type P a = Parser String a

-- | One parsed node-arg, before it's bucketed into `TElement`'s attrs/
-- | action/children (see `Templating.Ast`'s note on why the surface
-- | syntax is heterogeneous but the AST splits it in three).
data NodeArg
  = NArgNamed (Tuple String Expr)
  | NArgAction TAction
  | NArgChild TemplateNode

-- Lexing --------------------------------------------------------------

lexeme :: forall a. P a -> P a
lexeme p = p <* skipSpaces

symbol :: String -> P String
symbol s = lexeme (string s)

charsToString :: Array Char -> String
charsToString = SCU.fromCharArray

manyChars :: P Char -> P String
manyChars p = charsToString <<< Array.fromFoldable <$> many p

many1Chars :: P Char -> P String
many1Chars p = charsToString <<< Array.fromFoldable <$> many1 p

-- | Identifier with no trailing whitespace consumed — used inside paths
-- | (`ctx.items`, no space around `.`) and node tags (`.tr`, no space
-- | after `.`). Allows internal hyphens (kebab-case, e.g. `my-var`,
-- | `attr-kebab-case`) as well as the usual alphanumeric/underscore run,
-- | as long as the first character is a letter — never a hyphen or digit,
-- | so there's no ambiguity with a future signed-number literal.
-- | `identifier` below is the lexeme-wrapped version for standalone
-- | tokens (binding names, function names, attr keys).
rawIdent :: P String
rawIdent = do
  c0 <- letter
  cs <- manyChars (alphaNum <|> char '_' <|> char '-')
  pure (SCU.singleton c0 <> cs)

identifier :: P String
identifier = lexeme rawIdent

pathTail :: P (Array String)
pathTail = do
  first <- rawIdent
  rest <- many (char '.' *> rawIdent)
  pure (Array.cons first (Array.fromFoldable rest))

-- | A double-quoted key with no interpolation (unlike `stringLit` below,
-- | which allows backtick interpolation for values) — used for attribute
-- | keys that aren't valid bare identifiers (e.g. `"attr-kebab-case"`,
-- | though `rawIdent` already accepts plain kebab-case; quoting is for
-- | keys with characters `rawIdent` can't represent at all, like spaces)
-- | and for JSON-object-literal keys, which are conventionally quoted.
quotedKey :: P String
quotedKey = lexeme (char '"' *> manyChars (satisfy (\c -> c /= '"')) <* char '"')

-- | An attribute key: a bare identifier or a quoted string — see
-- | `quotedKey` above for why both are accepted.
attrKey :: P String
attrKey = identifier <|> quotedKey

-- Computation-phase expressions ----------------------------------------

pathExpr :: P Expr
pathExpr = lexeme (Path <$> (char '$' *> pathTail))

numberLit :: P Expr
numberLit = lexeme do
  intPart <- many1Chars digit
  fracPart <- optionMaybe (Tuple <$> char '.' <*> many1Chars digit)
  let
    fullStr = case fracPart of
      Nothing -> intPart
      Just (Tuple _ frac) -> intPart <> "." <> frac
  case Number.fromString fullStr of
    Just n -> pure (NumberLit n)
    Nothing -> fail ("invalid number literal: " <> fullStr)

-- | `true`/`false` as whole identifiers — parsed as a full `identifier`
-- | (not just the literal text `"true"`/`"false"`) so a longer name that
-- | merely starts with one, like `truest`, isn't chopped into a bogus
-- | bool-literal-plus-leftover; `try` backtracks cleanly to `call` (the
-- | next alternative in `expr`) for every other identifier.
boolLit :: P Expr
boolLit = try do
  name <- identifier
  case name of
    "true" -> pure (BoolLit true)
    "false" -> pure (BoolLit false)
    _ -> fail "not a boolean literal"

-- | A backtick-delimited interpolation holds an arbitrary `expr` — not
-- | just a bare path, so `` `$cardinality($nums)` `` works — which makes
-- | `stringLit` (via `interpPart`) and `expr` (which has `stringLit` as
-- | an alternative) mutually recursive CAFs; both directions need a
-- | `defer`-guard, same lesson as `expr`/`call` above.
-- |
-- | TODO: no escape sequences — `litPart` stops at `"` and at a backtick, so
-- | neither character can appear in a string at all. See the TODO in
-- | `specs/llm.md` §3.2; a fix has to land in both parsers at once.
stringLit :: P Expr
stringLit = lexeme do
  _ <- char '"'
  parts <- many stringPart
  _ <- char '"'
  pure (StringLit (Array.fromFoldable parts))
  where
  stringPart :: P StringPart
  stringPart = interpPart <|> litPart

  interpPart :: P StringPart
  interpPart = try do
    _ <- char '`'
    e <- defer \_ -> expr
    _ <- char '`'
    pure (Interp e)

  litPart :: P StringPart
  litPart = Lit <$> many1Chars (satisfy (\c -> c /= '"' && c /= '`'))

-- | A function call — `name(args)` or `$name(args)`. Both spellings mean
-- | the same thing: look up `name` in the environment (bound computation
-- | names unioned with the fixed builtins — there's no user-bindable
-- | *function* value yet, only `Json` ones, so only a builtin name
-- | actually resolves to something callable) and apply it. The leading
-- | `$` is accepted-but-optional here specifically because a call is
-- | already unambiguous once its trailing `(` is seen, unlike a bare
-- | value reference (which needs the `$` to not be mistaken for, say, a
-- | tag name).
call :: P Expr
call = try do
  _ <- optionMaybe (char '$')
  name <- identifier
  _ <- symbol "("
  args <- sepEndBy (defer \_ -> expr) (symbol ",")
  _ <- symbol ")"
  pure (Call [ name ] (Array.fromFoldable args))

arrayLit :: P Expr
arrayLit = lexeme do
  _ <- symbol "["
  elems <- sepEndBy (defer \_ -> expr) (symbol ",")
  _ <- symbol "]"
  pure (ArrayLit (Array.fromFoldable elems))

objectLit :: P Expr
objectLit = lexeme do
  _ <- symbol "{"
  entries <- sepEndBy (defer \_ -> objEntry) (symbol ",")
  _ <- symbol "}"
  pure (ObjectLit (Array.fromFoldable entries))
  where
  objEntry :: P (Tuple String Expr)
  objEntry = do
    k <- quotedKey
    _ <- symbol ":"
    v <- defer \_ -> expr
    pure (Tuple k v)

-- | `(p1, p2, ...) => body` — a lambda *value*, not tied to any
-- | particular call site. Zero or more comma-separated parameter names,
-- | then `=>`, then the body `expr`. Nothing else in `expr` starts with a
-- | bare `(`, so no ambiguity/`try` is needed to pick this alternative —
-- | though the body itself can of course fail to parse, same as any
-- | other `expr`.
lambdaExpr :: P Expr
lambdaExpr = do
  _ <- symbol "("
  params <- sepEndBy identifier (symbol ",")
  _ <- symbol ")"
  _ <- symbol "=>"
  body <- defer \_ -> expr
  pure (LambdaExpr (Array.fromFoldable params) body)

-- | The functional array primitives — `map(arr, fn)`, `filter(arr, fn)`,
-- | `scan(arr, init, fn)`, where `fn` is any `expr` expected to evaluate
-- | to a closure at eval time (an inline `lambdaExpr`, or a `$name`
-- | referencing a previously bound one — both are just `expr`, so no
-- | special-casing is needed here beyond parsing `fn` as one). Parsed as
-- | their own dedicated shapes (not through the generic `call`
-- | production) because `arr`'s elements need binding into `fn`'s
-- | closure environment fresh per element, which the uniform
-- | eagerly-evaluate-every-argument `Call` dispatch can't express — see
-- | `Templating.Ast`'s note on `MapExpr`/`FilterExpr`/`ScanExpr`. Tried
-- | as a whole name (`identifier`, not a literal string match) so e.g.
-- | `mapper(...)` isn't chopped into a bogus `map` plus leftover
-- | `per(...)` — any name other than the three recognized ones
-- | backtracks (via the outer `try`) to `call`.
specialFormExpr :: P Expr
specialFormExpr = try do
  _ <- optionMaybe (char '$')
  name <- identifier
  case name of
    "map" -> mapShape
    "filter" -> filterShape
    "scan" -> scanShape
    _ -> fail "not a map/filter/scan special form"
  where
  mapShape :: P Expr
  mapShape = do
    _ <- symbol "("
    arr <- defer \_ -> expr
    _ <- symbol ","
    fn <- defer \_ -> expr
    _ <- symbol ")"
    pure (MapExpr arr fn)

  filterShape :: P Expr
  filterShape = do
    _ <- symbol "("
    arr <- defer \_ -> expr
    _ <- symbol ","
    fn <- defer \_ -> expr
    _ <- symbol ")"
    pure (FilterExpr arr fn)

  scanShape :: P Expr
  scanShape = do
    _ <- symbol "("
    arr <- defer \_ -> expr
    _ <- symbol ","
    initE <- defer \_ -> expr
    _ <- symbol ","
    fn <- defer \_ -> expr
    _ <- symbol ")"
    pure (ScanExpr arr initE fn)

-- | `expr := bool-lit | lambda-expr | map/filter/scan-special-form |
-- | call | path | string-lit | number-lit | array-lit | object-lit`.
-- | `boolLit` and `specialFormExpr` are tried before `call` since all
-- | three start with a bare identifier — each backtracks cleanly (via
-- | its own internal `try`) for any name/shape it doesn't recognize,
-- | letting the next alternative have a turn. `lambdaExpr` starts with a
-- | bare `(`, unique among these alternatives, so no backtracking
-- | concern there. `lambdaExpr`/`call`/`arrayLit`/`objectLit`/
-- | `specialFormExpr` are mutually recursive CAFs with `expr` (their
-- | contents are made of `expr`s; `expr` has them as alternatives) —
-- | PureScript is strict, so every cross-reference in that cycle needs a
-- | `defer`-guard (from `Control.Lazy`, which `Parser` has an instance
-- | for), not just one direction; see `Templating.Parser` git
-- | history/`node`'s own such cycle below for the same lesson learned
-- | earlier.
expr :: P Expr
expr = boolLit
  <|> defer (\_ -> lambdaExpr)
  <|> defer (\_ -> specialFormExpr)
  <|> try (defer \_ -> call)
  <|> pathExpr
  <|> defer (\_ -> stringLit)
  <|> numberLit
  <|> defer (\_ -> arrayLit)
  <|> defer (\_ -> objectLit)

-- | `@` leads a binding *definition* (a setter — `@foo=$bar` defines
-- | `foo`), symmetric with `$` leading a binding *read* (a getter). No
-- | whitespace is allowed between `@` and the name, same convention as
-- | `$name`.
binding :: P (Tuple String Expr)
binding = try do
  _ <- char '@'
  name <- identifier
  _ <- symbol "="
  e <- expr
  pure (Tuple name e)

compBlock :: P (Array (Tuple String Expr))
compBlock = Array.fromFoldable <$> many (try binding)

-- Template-phase nodes ---------------------------------------------------

namedArg :: P (Tuple String Expr)
namedArg = try do
  name <- attrKey
  _ <- symbol ":"
  v <- expr
  pure (Tuple name v)

-- | `action(eventTypeExpr, keyExpr, payloadExpr)` — appears directly
-- | among a node's arguments, not as `key: value`. All three positions
-- | are ordinary `expr`s (`eventTypeExpr`/`keyExpr` are required to
-- | evaluate to a string, see `Templating.Eval`'s `evalAction`) — unlike
-- | the original bare-identifier `eventType`, this lets it be a plain
-- | string literal (`"on-click"`), a computed `$ctx.eventName`, or
-- | anything else an `expr` can produce, since a host other than the
-- | Halogen fold may have its own event/hook vocabulary that isn't known
-- | to this parser at all. Tried as a whole `identifier` (not a literal
-- | string match) for the leading `action` keyword itself, same
-- | reasoning as `specialFormExpr`/`templateSpecialForm` — a name other
-- | than exactly `"action"` backtracks to `namedArg`/`childArg`.
actionArg :: P TAction
actionArg = try do
  name <- identifier
  if name /= "action" then fail "not an action(...) form"
  else do
    _ <- symbol "("
    eventTypeE <- defer \_ -> expr
    _ <- symbol ","
    keyE <- defer \_ -> expr
    _ <- symbol ","
    payloadE <- defer \_ -> expr
    _ <- symbol ")"
    pure (TAction eventTypeE keyE payloadE)

-- | Any `$`-prefixed child form that isn't `map(...)`/`branch(...)`
-- | (those are handled by `templateSpecialForm` below, tried first): a
-- | bare path (`$ctx.title`) or a call (`$foo("123")`) — `$`, a dotted
-- | path, then an optional parenthesized call-args suffix. No trailing
-- | `(` at all means a bare path; a trailing `(` means a generic call,
-- | with the whole dotted path as the callee (in practice always a
-- | single segment in today's fixed builtin set, same restriction as
-- | `call` above).
pathOrCallChild :: P TemplateNode
pathOrCallChild = lexeme do
  segs <- char '$' *> pathTail
  hasParen <- optionMaybe (symbol "(")
  case hasParen of
    Nothing -> pure (TValue (Path segs))
    Just _ -> do
      args <- sepEndBy (defer \_ -> expr) (symbol ",")
      _ <- symbol ")"
      pure (TValue (Call segs (Array.fromFoldable args)))

-- | The template-block counterparts of `specialFormExpr` above:
-- | `map(arrExpr, (item) => node)` produces a `TMap` child (repeats
-- | `node` once per array element, `item` bound fresh each time — this
-- | is the *functional* replacement for the older `$ctx.items.map((item)
-- | => ...)` OOP-suffix syntax, which no longer parses at all: the array
-- | being mapped is now the call's first argument, not a path a `.map`
-- | is suffixed onto, so it can be any `expr`, not only a bare path).
-- | `branch(fallbackNode, pred1, node1, pred2, node2, ...)` produces a
-- | `TBranch` child, selecting exactly one node — see `Templating.Ast`'s
-- | note on why only the chosen node is ever evaluated, unlike the
-- | expr-level `branch` builtin. Tried as a whole `identifier` (not a
-- | literal string), same reasoning as `specialFormExpr`.
templateSpecialForm :: P TemplateNode
templateSpecialForm = try do
  _ <- optionMaybe (char '$')
  name <- identifier
  case name of
    "map" -> mapNodeShape
    "branch" -> branchNodeShape
    _ -> fail "not a map/branch special form"
  where
  mapNodeShape :: P TemplateNode
  mapNodeShape = do
    _ <- symbol "("
    arr <- defer \_ -> expr
    _ <- symbol ","
    _ <- symbol "("
    itemName <- identifier
    _ <- symbol ")"
    _ <- symbol "=>"
    body <- defer \_ -> node
    _ <- symbol ")"
    pure (TMap arr itemName body)

  branchNodeShape :: P TemplateNode
  branchNodeShape = do
    _ <- symbol "("
    fallback <- defer \_ -> node
    pairs <- many (try (symbol "," *> pairP))
    _ <- optionMaybe (symbol ",")
    _ <- symbol ")"
    pure (TBranch fallback (Array.fromFoldable pairs))

  pairP :: P (Tuple Expr TemplateNode)
  pairP = do
    p <- defer \_ -> expr
    _ <- symbol ","
    n <- defer \_ -> node
    pure (Tuple p n)

-- | `node`, `childArg`, `nodeArg` and (via the lambda/branch bodies
-- | above) even `templateSpecialForm` form one mutually recursive family
-- | (`.td(.a(...))` nests a node in a node; `map(..., (item) =>
-- | .tr(...))`/`branch(...)`'s node arguments nest one too). Purs's cycle
-- | checker flags the whole binding group if *any* cross-reference within
-- | it is unguarded, regardless of how deep the offending reference is
-- | nested — so every edge in the family gets a `defer`, not just the
-- | first one found.
childArg :: P TemplateNode
childArg = defer (\_ -> node)
  <|> defer (\_ -> templateSpecialForm)
  <|> defer (\_ -> pathOrCallChild)
  <|> (TValue <$> stringLit)

nodeArg :: P NodeArg
nodeArg = (NArgAction <$> try actionArg) <|> (NArgNamed <$> try namedArg) <|> (NArgChild <$> defer (\_ -> childArg))

node :: P TemplateNode
node = lexeme do
  _ <- char '.'
  tag <- rawIdent
  skipSpaces
  _ <- symbol "("
  args <- sepEndBy (defer \_ -> nodeArg) (symbol ",")
  _ <- symbol ")"
  let argsArr = Array.fromFoldable args
  ensureAttrsBeforeChildren argsArr
  action <- extractSingleAction argsArr
  let
    attrs = Array.mapMaybe asNamed argsArr
    children = Array.mapMaybe asChild argsArr
  pure (TElement tag attrs action children)
  where
  asNamed :: NodeArg -> Maybe (Tuple String Expr)
  asNamed (NArgNamed t) = Just t
  asNamed _ = Nothing

  asAction :: NodeArg -> Maybe TAction
  asAction (NArgAction a) = Just a
  asAction _ = Nothing

  asChild :: NodeArg -> Maybe TemplateNode
  asChild (NArgChild c) = Just c
  asChild _ = Nothing

  -- | Hard-enforces "all attributes/action before sibling nodes": once a
  -- | `child-arg` has been seen in the list, a further `named-arg` or
  -- | `action(...)` is a parse error rather than silently
  -- | accepted-but-reordered. Folding over the already-parsed list
  -- | (rather than shaping the grammar production itself as
  -- | `(named-arg | action)* child-arg*`) keeps the single
  -- | comma-separated `nodeArg` parse above unchanged and just rejects
  -- | the invalid orderings after the fact.
  ensureAttrsBeforeChildren :: Array NodeArg -> P Unit
  ensureAttrsBeforeChildren argsArr =
    if fst (Array.foldl step (Tuple true false) argsArr) then pure unit
    else fail "attributes and action(...) must all come before sibling child nodes in a node's argument list"
    where
    step (Tuple ok seenChild) arg = case arg of
      NArgNamed _ -> Tuple (ok && not seenChild) seenChild
      NArgAction _ -> Tuple (ok && not seenChild) seenChild
      NArgChild _ -> Tuple ok true

  -- | A node may have at most one `action(...)` — more than one is a
  -- | parse error (which action would even wire up if there were two?).
  extractSingleAction :: Array NodeArg -> P (Maybe TAction)
  extractSingleAction argsArr = case Array.mapMaybe asAction argsArr of
    [] -> pure Nothing
    [ a ] -> pure (Just a)
    _ -> fail "a node can have at most one action(...)"

-- Program ----------------------------------------------------------------

program :: P Program
program = do
  skipSpaces
  bindings <- compBlock
  root <- node
  skipSpaces
  eof
  pure { bindings, root }

parseProgram :: String -> Either ParseError Program
parseProgram input = runParser input program

parseExpr :: String -> Either ParseError Expr
parseExpr input = runParser input (skipSpaces *> expr <* eof)

parseTemplateNode :: String -> Either ParseError TemplateNode
parseTemplateNode input = runParser input (skipSpaces *> node <* eof)
