-- | Evaluates a parsed 'Program' against an input JSON context, producing
-- the generic 'Node' output AST. Two phases, matching
-- @../specs/templating-language.md@: run computation-block bindings once
-- (in declaration order, each may reference earlier ones) to build an
-- environment, then walk the template-block root resolving every
-- 'Path'\/interpolation against that environment. Ported from
-- @../templating/src/Templating/Eval.purs@ -- see that file's Haddock
-- comments for the full semantic rationale (closures, no-recursion
-- guarantee, builtin table, tolerant @has@\/@lookup@, eager-argument
-- @branch@ limitation, etc.); this port preserves that semantics exactly,
-- swapping argonaut 'Json' for aeson 'Value' and 'Foreign.Object' for
-- 'HashMap'.
module Templating.Eval
  ( EvalError (..)
  , evalProgram
  , evalJsonProgram
  ) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.List (foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Scientific (Scientific, toRealFloat)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Templating.Ast

data EvalError
  = UnboundName Text
  | UnknownFunction Text
  | PathNotFound [Text]
  | TypeMismatch Text
  deriving stock (Eq, Show)

-- | Everything a name in the environment (or an evaluated expr) can be: an
-- ordinary JSON value, or a closure -- a 'LambdaExpr'\'s parameter names and
-- body, paired with the environment captured at the moment it was
-- evaluated. **No recursion**: 'evalBindings' inserts a binding's value
-- only *after* evaluating its right-hand side.
data Value'
  = VJson Value
  | VClosure [Text] Expr Env

type Env = Map Text Value'

{- | Both @eventType@ and @key@ must reduce to strings, and that is the whole
check: an event type is passed through to the host verbatim, whatever it says.
The language has no vocabulary of its own here -- a DOM host knows about
@on-click@, an email or static-site renderer has no DOM events at all -- so
deciding which event types mean something is the host's job, not evaluation's.
-}
evalAction :: Env -> TAction -> Either EvalError ActionPayload
evalAction env (TAction eventTypeExpr keyExpr payloadExpr) = do
  eventTypeJson <- evalExprAsJson env eventTypeExpr
  eventType <- requireString "action(...): the event type (1st argument) must be a string" eventTypeJson
  keyJson <- evalExprAsJson env keyExpr
  key <- requireString "action(...): the key (2nd argument) must be a string" keyJson
  payload <- evalExprAsJson env payloadExpr
  pure ActionPayload {apEventType = eventType, apKey = key, apPayload = payload}
  where
    requireString :: Text -> Value -> Either EvalError Text
    requireString _msg (String s) = Right s
    requireString msg _ = Left (TypeMismatch msg)

evalProgram :: Value -> Program -> Either EvalError Node
evalProgram input (Program bindings root) = do
  env <- evalBindings input bindings
  evalTemplate env root

-- | Evaluates a 'JsonProgram': the same computation block as 'evalProgram'
-- (same order, same closures, same no-recursion rule) but the root is an
-- 'Expr', so the result is a JSON 'Value' rather than a document 'Node'.
-- Nothing here is stringified through 'jsonToDisplayString' -- numbers stay
-- numbers and nested objects stay objects, which is precisely what a host
-- generating a JSON payload (rather than a document) needs.
evalJsonProgram :: Value -> JsonProgram -> Either EvalError Value
evalJsonProgram input (JsonProgram bindings root) = do
  env <- evalBindings input bindings
  evalExprAsJson env root

-- | Run every comp-block binding once, in declaration order, against an
-- environment that starts as just @{ ctx: input }@ and accumulates one more
-- entry per binding.
evalBindings :: Value -> [(Text, Expr)] -> Either EvalError Env
evalBindings input = foldlEither step (Map.singleton "ctx" (VJson input))
  where
    step :: Env -> (Text, Expr) -> Either EvalError Env
    step env (name, e) = do
      v <- evalExpr env e
      pure (Map.insert name v env)

foldlEither :: (b -> a -> Either e b) -> b -> [a] -> Either e b
foldlEither f = go
  where
    go acc [] = Right acc
    go acc (x : xs) = f acc x >>= \acc' -> go acc' xs

-- | A 'Value'' used where a JSON value is required must actually be one --
-- a closure can't be stringified, stored inside a JSON array, or passed to
-- a fixed builtin.
requireJson :: Value' -> Either EvalError Value
requireJson (VJson j) = Right j
requireJson (VClosure _ _ _) = Left (TypeMismatch "expected a value, got a function -- call it first, e.g. $my-fn(...), instead of using it directly")

evalExprAsJson :: Env -> Expr -> Either EvalError Value
evalExprAsJson env e = evalExpr env e >>= requireJson

requireBoolean :: Value' -> Either EvalError Bool
requireBoolean v = do
  j <- requireJson v
  case j of
    Bool b -> Right b
    _ -> Left (TypeMismatch "expected a boolean")

-- | Applies a function 'Value'' (a closure, from an inline 'LambdaExpr' or a
-- bound name) to already-evaluated argument 'Value''s.
applyFunctionValue :: Text -> Value' -> [Value'] -> Either EvalError Value'
applyFunctionValue _ (VClosure params body closureEnv) argVals = applyClosure params body closureEnv argVals
applyFunctionValue who (VJson _) _ = Left (TypeMismatch (who <> " expects a function value (a lambda, or a name bound to one)"))

applyClosure :: [Text] -> Expr -> Env -> [Value'] -> Either EvalError Value'
applyClosure params body closureEnv argVals
  | length params /= length argVals =
      Left (TypeMismatch ("closure expects " <> tshow (length params) <> " argument(s), got " <> tshow (length argVals)))
  | otherwise =
      evalExpr (foldl' (\e (p, v) -> Map.insert p v e) closureEnv (zip params argVals)) body

evalExpr :: Env -> Expr -> Either EvalError Value'
evalExpr env (Path segs) = resolvePath env segs
evalExpr env (Call segs argExprs) = case segs of
  [name] -> case Map.lookup name env of
    Just (VClosure params body closureEnv) -> do
      argVals <- mapM (evalExpr env) argExprs
      applyClosure params body closureEnv argVals
    _ -> do
      argJsons <- mapM (evalExprAsJson env) argExprs
      VJson <$> evalBuiltin name argJsons
  _ -> Left (TypeMismatch ("cannot call " <> tshow segs <> " -- only a single bound/builtin name can be called, e.g. $cardinality(...), not a dotted path"))
evalExpr env (StringLit parts) = VJson . String <$> evalStringParts env parts
evalExpr _ (NumberLit n) = pure (VJson (Number (realToFrac n)))
evalExpr _ (BoolLit b) = pure (VJson (Bool b))
evalExpr env (ArrayLit elems) = VJson . Array . V.fromList <$> mapM (evalExprAsJson env) elems
evalExpr env (ObjectLit entries) =
  VJson . Object . KeyMap.fromList <$> mapM (\(k, e) -> (\v -> (Key.fromText k, v)) <$> evalExprAsJson env e) entries
evalExpr env (LambdaExpr params body) = pure (VClosure params body env)
evalExpr env (MapExpr arrExpr fnExpr) = do
  items <- evalArrayExpr "map" env arrExpr
  fnVal <- evalExpr env fnExpr
  results <- mapM (\item -> applyFunctionValue "map" fnVal [VJson item] >>= requireJson) items
  pure (VJson (Array (V.fromList results)))
evalExpr env (FilterExpr arrExpr fnExpr) = do
  items <- evalArrayExpr "filter" env arrExpr
  fnVal <- evalExpr env fnExpr
  kept <- mapM (\item -> keepIf item <$> (applyFunctionValue "filter" fnVal [VJson item] >>= requireBoolean)) items
  pure (VJson (Array (V.fromList [x | Just x <- kept])))
  where
    keepIf :: Value -> Bool -> Maybe Value
    keepIf item True = Just item
    keepIf _ False = Nothing
evalExpr env (ScanExpr arrExpr initExpr fnExpr) = do
  items <- evalArrayExpr "scan" env arrExpr
  initAcc <- evalExprAsJson env initExpr
  fnVal <- evalExpr env fnExpr
  results <- scanSteps fnVal initAcc items
  pure (VJson (Array (V.fromList results)))
  where
    -- | @scan@\'s output is @[init, step(init, x1), step(step(init, x1),
    -- x2), ...]@ -- standard @scanl@ semantics, not @scanl1@.
    scanSteps :: Value' -> Value -> [Value] -> Either EvalError [Value]
    scanSteps _ acc [] = Right [acc]
    scanSteps fnVal acc (item : rest) = do
      nextAcc <- applyFunctionValue "scan" fnVal [VJson acc, VJson item] >>= requireJson
      restAccs <- scanSteps fnVal nextAcc rest
      pure (acc : restAccs)
evalExpr env (FoldExpr arrExpr initExpr fnExpr) = do
  items <- evalArrayExpr "fold" env arrExpr
  initAcc <- evalExprAsJson env initExpr
  fnVal <- evalExpr env fnExpr
  VJson <$> foldSteps fnVal initAcc items
  where
    -- | Same @(acc, item)@ step and @scanl@ iteration order as 'ScanExpr',
    -- but only the final accumulator is kept -- no intermediate array.
    foldSteps :: Value' -> Value -> [Value] -> Either EvalError Value
    foldSteps _ acc [] = Right acc
    foldSteps fnVal acc (item : rest) = do
      nextAcc <- applyFunctionValue "fold" fnVal [VJson acc, VJson item] >>= requireJson
      foldSteps fnVal nextAcc rest

-- | Shared by map\/filter\/scan\/fold: evaluate the array-producing argument and
-- require it actually be a JSON array.
evalArrayExpr :: Text -> Env -> Expr -> Either EvalError [Value]
evalArrayExpr who env arrExpr = do
  j <- evalExprAsJson env arrExpr
  case j of
    Array arr -> Right (V.toList arr)
    _ -> Left (TypeMismatch (who <> " expects an array as its first argument"))

evalStringParts :: Env -> [StringPart] -> Either EvalError Text
evalStringParts env parts = T.concat <$> mapM resolvePart parts
  where
    resolvePart :: StringPart -> Either EvalError Text
    resolvePart (Lit s) = pure s
    resolvePart (Interp e) = jsonToDisplayString <$> evalExprAsJson env e

resolvePath :: Env -> [Text] -> Either EvalError Value'
resolvePath env segs = case segs of
  [] -> Left (PathNotFound segs)
  (headSeg : tailSegs) -> case Map.lookup headSeg env of
    Nothing -> Left (UnboundName headSeg)
    Just v -> walkFields v tailSegs
  where
    walkFields :: Value' -> [Text] -> Either EvalError Value'
    walkFields v [] = Right v
    walkFields v (field : rest) = case v of
      VClosure _ _ _ -> Left (TypeMismatch ("cannot access field " <> field <> " on a function value in path " <> tshow segs))
      VJson j -> case j of
        Object obj -> case KeyMap.lookup (Key.fromText field) obj of
          Nothing -> Left (PathNotFound segs)
          Just v' -> walkFields (VJson v') rest
        _ -> Left (TypeMismatch ("expected an object to look up field " <> field <> " in path " <> tshow segs))

-- | Fixed builtin set -- grown only on real demand, per the scope decision
-- against an extension registry. @map@ is deliberately absent here: it
-- produces nodes, not a scalar value, so it's handled structurally via
-- 'TMap' in 'evalChildren', not as a 'Call'.
evalBuiltin :: Text -> [Value] -> Either EvalError Value
evalBuiltin name args = case name of
  "cardinality" -> cardinality
  "count" -> cardinality
  "not" -> unaryBool
  "and" -> variadicBool (&&) True
  "or" -> variadicBool (||) False
  "eq" -> binary (\a b -> Right (Bool (a == b)))
  "lt" -> numericComparison (<)
  "lte" -> numericComparison (<=)
  "gt" -> numericComparison (>)
  "gte" -> numericComparison (>=)
  "has" -> binary hasImpl
  "lookup" -> ternary lookupImpl
  "branch" -> branchImpl
  _ -> Left (UnknownFunction name)
  where
    arity1 :: (Value -> Either EvalError a) -> Either EvalError a
    arity1 f = case args of
      [a] -> f a
      _ -> Left (TypeMismatch (name <> " expects exactly 1 argument, got " <> tshow (length args)))

    binary :: (Value -> Value -> Either EvalError Value) -> Either EvalError Value
    binary f = case args of
      [a, b] -> f a b
      _ -> Left (TypeMismatch (name <> " expects exactly 2 arguments, got " <> tshow (length args)))

    ternary :: (Value -> Value -> Value -> Either EvalError Value) -> Either EvalError Value
    ternary f = case args of
      [a, b, c] -> f a b c
      _ -> Left (TypeMismatch (name <> " expects exactly 3 arguments, got " <> tshow (length args)))

    cardinality :: Either EvalError Value
    cardinality = arity1 $ \j -> case j of
      Null -> Left (TypeMismatch (name <> " expects an array or object, got null"))
      Bool _ -> Left (TypeMismatch (name <> " expects an array or object, got a boolean"))
      Number _ -> Left (TypeMismatch (name <> " expects an array or object, got a number"))
      String _ -> Left (TypeMismatch (name <> " expects an array or object, got a string"))
      Array arr -> Right (Number (fromIntegral (V.length arr)))
      Object obj -> Right (Number (fromIntegral (KeyMap.size obj)))

    asBoolean :: Value -> Either EvalError Bool
    asBoolean (Bool b) = Right b
    asBoolean _ = Left (TypeMismatch (name <> " expects a boolean argument"))

    asNumber :: Value -> Either EvalError Scientific
    asNumber (Number n) = Right n
    asNumber _ = Left (TypeMismatch (name <> " expects a number argument"))

    unaryBool :: Either EvalError Value
    unaryBool = arity1 $ \j -> Bool . not <$> asBoolean j

    -- | @and@\/@or@ fold over however many arguments are given (including
    -- zero, vacuously), rather than requiring a fixed arity.
    variadicBool :: (Bool -> Bool -> Bool) -> Bool -> Either EvalError Value
    variadicBool op identityVal = do
      bools <- mapM asBoolean args
      pure (Bool (foldl' op identityVal bools))

    numericComparison :: (Scientific -> Scientific -> Bool) -> Either EvalError Value
    numericComparison op = binary $ \a b -> do
      na <- asNumber a
      nb <- asNumber b
      pure (Bool (op na nb))

    -- | Presence/absence predicate -- deliberately tolerant: a missing key,
    -- an out-of-range index, or even a container/key of the wrong shape all
    -- just answer 'False' rather than erroring.
    hasImpl :: Value -> Value -> Either EvalError Value
    hasImpl container key = Right (Bool containsKey)
      where
        containsKey = case (container, key) of
          (Object obj, String k) -> KeyMap.member (Key.fromText k) obj
          _ -> case (container, arrayIndex key) of
            (Array arr, Just i) -> i >= 0 && i < V.length arr
            _ -> False

    -- | Dynamic object\/array access by a computed key\/index -- the
    -- dynamic counterpart to a static @$path@ segment. Takes a mandatory
    -- third argument, the fallback value.
    lookupImpl :: Value -> Value -> Value -> Either EvalError Value
    lookupImpl container key fallback = Right $ case (container, key) of
      (Object obj, String k) -> maybe fallback id (KeyMap.lookup (Key.fromText k) obj)
      _ -> case (container, arrayIndex key) of
        (Array arr, Just i) -> maybe fallback id (arr V.!? i)
        _ -> fallback

    -- | A JSON number used as an array index must be a non-negative
    -- integer -- @2.5@ or @-1@ aren't valid indices.
    arrayIndex :: Value -> Maybe Int
    arrayIndex (Number n) =
      let d = toRealFloat n :: Double
          i = round d :: Int
       in if fromIntegral i == d && i >= 0 then Just i else Nothing
    arrayIndex _ = Nothing

    -- | @branch(fallback, pred1, val1, pred2, val2, ...)@ -- "if pred1,
    -- val1; else if pred2, val2; ...; else fallback." Every argument
    -- (every predicate *and* every value) is evaluated eagerly before
    -- @branch@ ever runs -- there is no short-circuiting anywhere in this
    -- language.
    branchImpl :: Either EvalError Value
    branchImpl = case args of
      [] -> Left (TypeMismatch "branch expects at least 1 argument (a fallback value)")
      (fallback : rest) -> go fallback rest
      where
        go :: Value -> [Value] -> Either EvalError Value
        go fallback [] = Right fallback
        go _ [_] = Left (TypeMismatch "branch expects fallback followed by predicate/value pairs -- got a trailing predicate with no matching value")
        go fallback (predJson : valJson : rest2) = do
          p <- asBoolean predJson
          if p then Right valJson else go fallback rest2

-- | How a resolved JSON value renders when interpolated into template
-- output: strings render raw (no surrounding quotes), numbers drop a
-- trailing @.0@ when integral, everything else falls back to a compact
-- JSON encoding.
jsonToDisplayString :: Value -> Text
jsonToDisplayString Null = ""
jsonToDisplayString (Bool b) = if b then "true" else "false"
jsonToDisplayString (Number n) = formatNumber n
jsonToDisplayString (String s) = s
jsonToDisplayString j@(Array _) = tshow j
jsonToDisplayString j@(Object _) = tshow j

formatNumber :: Scientific -> Text
formatNumber n =
  let d = toRealFloat n :: Double
      rounded = round d :: Integer
   in if fromIntegral rounded == d then tshow rounded else tshow d

tshow :: (Show a) => a -> Text
tshow = T.pack . show

evalTemplate :: Env -> TemplateNode -> Either EvalError Node
evalTemplate env (TElement tag attrExprs actionExpr children) = do
  attrs <- Map.fromList <$> mapM (\(k, e) -> (,) k . jsonToDisplayString <$> evalExprAsJson env e) attrExprs
  action <- traverse (evalAction env) actionExpr
  childNodes <- evalChildren env children
  pure NElement {neTag = tag, neAttrs = attrs, neAction = action, neChildren = childNodes}
evalTemplate env (TValue e) = NText . jsonToDisplayString <$> evalExprAsJson env e
evalTemplate _ (TMap _ _ _) =
  Left (TypeMismatch "a `map(...)` cannot be evaluated as a standalone node -- it only ever appears as a parent's child, never as a template's root")
evalTemplate env (TBranch fallback pairs) = do
  chosen <- pickBranch env fallback pairs
  evalTemplate env chosen

-- | Selects which node a @branch(...)@ child evaluates to -- only the
-- *chosen* 'TemplateNode' is ever passed to 'evalTemplate', so an unreached
-- branch's own errors never surface.
pickBranch :: Env -> TemplateNode -> [(Expr, TemplateNode)] -> Either EvalError TemplateNode
pickBranch _ fallback [] = Right fallback
pickBranch env fallback ((predExpr, node) : rest) = do
  predJson <- evalExprAsJson env predExpr
  p <- case predJson of
    Bool b -> Right b
    _ -> Left (TypeMismatch "branch predicate must evaluate to a boolean")
  if p then Right node else pickBranch env fallback rest

-- | A 'TMap' child expands to zero-or-more 'Node's (one per array item,
-- flattened into the parent's children); every other child produces
-- exactly one.
evalChildren :: Env -> [TemplateNode] -> Either EvalError [Node]
evalChildren env children = concat <$> mapM (evalChild env) children
  where
    evalChild :: Env -> TemplateNode -> Either EvalError [Node]
    evalChild env' (TMap arrExpr bindName body) = do
      items <- evalArrayExpr "map" env' arrExpr
      mapM (\item -> evalTemplate (Map.insert bindName (VJson item) env') body) items
    evalChild env' tn = (: []) <$> evalTemplate env' tn
