-- | Evaluates a parsed 'Program' against an input JSON context, producing
-- the generic 'Node' output AST. Two phases, matching
-- @../specs/templating-language.md@: run computation-block bindings once
-- (in declaration order, each may reference earlier ones) to build an
-- environment, then walk the template-block root resolving every
-- 'Path'\/interpolation against that environment. Ported from
-- @../tramaj/src/Tramaj/Eval.purs@ -- see that file's Haddock
-- comments for the full semantic rationale (closures, no-recursion
-- guarantee, builtin table, tolerant @has@\/@lookup@, eager-argument
-- @branch@ limitation, import\/partial-import\/remap-actions, etc.); this
-- port preserves that semantics exactly, swapping argonaut 'Json' for
-- aeson 'Value' and 'Foreign.Object' for 'HashMap'.
module Tramaj.Eval
  ( EvalError (..)
  , LibraryTable
  , LibrarySource (..)
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
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Tramaj.Ast

data EvalError
  = UnboundName Text
  | UnknownFunction Text
  | PathNotFound [Text]
  | TypeMismatch Text
  | UnknownLibrary Text
  | ImportCycle Text
  deriving stock (Eq, Show)

-- | A library can be rooted either way a top-level program can: an element
-- ('Program', same as 'evalProgram') or an expression ('JsonProgram', same
-- as 'evalJsonProgram'). See 'runLibrary'.
data LibrarySource
  = ProgramSource Program
  | JsonSource JsonProgram

-- | Host-supplied library store: a library name (as used in
-- @import(name, params)@\/@partial-import(name, params)@) resolves to an
-- already-parsed 'LibrarySource'. Where that source came from (a file, an
-- embedded string, a remote fetch) is entirely a host concern -- the
-- evaluator only ever sees the parsed result.
type LibraryTable = Map Text LibrarySource

-- | Everything a name in the environment (or an evaluated expr) can be: an
-- ordinary JSON value, a closure -- a 'LambdaExpr'\'s parameter names and
-- body, paired with the environment captured at the moment it was
-- evaluated -- or one of three values @import@\/@partial-import@
-- introduce:
--
-- * 'VNode' -- a fully-evaluated document 'Node'.
-- * 'VEnv' -- a named bag of 'Value''s, e.g. an @import@ result's
--   @{ rendered, vals }@ record.
-- * 'VPartial' -- a suspended @partial-import@: the library name plus
--   whatever params were given so far.
-- * 'VRemapPartial' -- a 'VPartial' with one or more @remap-actions@
--   @(prefix, fn)@ operations already queued up.
--
-- **No recursion**: 'evalBindings' inserts a binding's value only *after*
-- evaluating its right-hand side.
data Value'
  = VJson Value
  | VClosure [Text] Expr Env
  | VNode Node
  | VEnv Env
  | VPartial Text Value
  | VRemapPartial Text Value [(Text, Value')]

type Env = Map Text Value'

{- | @eventType@ must reduce to a string; @key@ already is one (a bare 'Text'
in the AST, nothing to evaluate or type-check). An event type is passed
through to the host verbatim, whatever it says. The language has no
vocabulary of its own here -- a DOM host knows about @on-click@, an email or
static-site renderer has no DOM events at all -- so deciding which event
types mean something is the host's job, not evaluation's.
-}
evalAction :: LibraryTable -> Set Text -> Env -> TAction -> Either EvalError ActionPayload
evalAction libs inProgress env (TAction eventTypeExpr key payloadExpr) = do
  eventTypeJson <- evalExprAsJson libs inProgress env eventTypeExpr
  eventType <- requireString "action(...): the event type (1st argument) must be a string" eventTypeJson
  payload <- evalExprAsJson libs inProgress env payloadExpr
  pure ActionPayload {apEventType = eventType, apKey = key, apPayload = payload}
  where
    requireString :: Text -> Value -> Either EvalError Text
    requireString _msg (String s) = Right s
    requireString msg _ = Left (TypeMismatch msg)

evalProgram :: LibraryTable -> Value -> Program -> Either EvalError Node
evalProgram libs input (Program bindings root) = do
  env <- evalBindings libs Set.empty input bindings
  evalTemplate libs Set.empty env root

-- | Evaluates a 'JsonProgram': the same computation block as 'evalProgram'
-- (same order, same closures, same no-recursion rule) but the root is an
-- 'Expr', so the result is a JSON 'Value' rather than a document 'Node'.
evalJsonProgram :: LibraryTable -> Value -> JsonProgram -> Either EvalError Value
evalJsonProgram libs input (JsonProgram bindings root) = do
  env <- evalBindings libs Set.empty input bindings
  evalExprAsJson libs Set.empty env root

-- | Run every comp-block binding once, in declaration order, against an
-- environment that starts as just @{ ctx: input }@ and accumulates one more
-- entry per binding.
evalBindings :: LibraryTable -> Set Text -> Value -> [(Text, Expr)] -> Either EvalError Env
evalBindings libs inProgress input = foldlEither step (Map.singleton "ctx" (VJson input))
  where
    step :: Env -> (Text, Expr) -> Either EvalError Env
    step env (name, e) = do
      v <- evalExpr libs inProgress env e
      pure (Map.insert name v env)

foldlEither :: (b -> a -> Either e b) -> b -> [a] -> Either e b
foldlEither f = go
  where
    go acc [] = Right acc
    go acc (x : xs) = f acc x >>= \acc' -> go acc' xs

-- | A 'Value'' used where a JSON value is required must actually reduce to
-- one. A closure can't (call it first); a 'VNode' reduces via 'nodeToJson';
-- a 'VEnv'\/'VPartial'\/'VRemapPartial' can't either (access a field, or
-- finish applying the partial import, first).
requireJson :: Value' -> Either EvalError Value
requireJson (VJson j) = Right j
requireJson (VClosure _ _ _) = Left (TypeMismatch "expected a value, got a function -- call it first, e.g. $my-fn(...), instead of using it directly")
requireJson (VNode n) = Right (nodeToJson n)
requireJson (VEnv _) = Left (TypeMismatch "expected a value, got a library/env value -- access .rendered, .vals, or a binding name first")
requireJson (VPartial name _) = Left (TypeMismatch ("expected a value, got a partial import of " <> tshow name <> " still waiting on params -- call it with the missing params first"))
requireJson (VRemapPartial name _ _) = Left (TypeMismatch ("expected a value, got a partial import of " <> tshow name <> " still waiting on params -- call it with the missing params first"))

evalExprAsJson :: LibraryTable -> Set Text -> Env -> Expr -> Either EvalError Value
evalExprAsJson libs inProgress env e = evalExpr libs inProgress env e >>= requireJson

requireBoolean :: Value' -> Either EvalError Bool
requireBoolean v = do
  j <- requireJson v
  case j of
    Bool b -> Right b
    _ -> Left (TypeMismatch "expected a boolean")

-- | Applies a function 'Value'' (a closure, from an inline 'LambdaExpr' or a
-- bound name; or a suspended partial import) to already-evaluated argument
-- 'Value''s -- shared by @Call@-on-a-bound-closure and by
-- @map@\/@filter@\/@scan@\'s transform argument.
--
-- Completing a 'VPartial' shallow-merges its one JSON-object argument into
-- the params already given (new keys win on conflict) and retries via
-- 'tryPartial', so a still-incomplete merge suspends again and a complete
-- one runs through exactly the same 'runLibrary' path @import@ uses.
applyFunctionValue :: LibraryTable -> Set Text -> Text -> Value' -> [Value'] -> Either EvalError Value'
applyFunctionValue libs inProgress _ (VClosure params body closureEnv) argVals = applyClosure libs inProgress params body closureEnv argVals
applyFunctionValue libs inProgress who (VPartial name given) argVals = case argVals of
  [VJson extraJson] -> do
    merged <- mergeParamObjects who given extraJson
    tryPartial libs inProgress name merged
  _ -> Left (TypeMismatch (who <> ": completing a partial import expects exactly 1 object argument"))
applyFunctionValue libs inProgress who (VRemapPartial name given ops) argVals = case argVals of
  [VJson extraJson] -> do
    merged <- mergeParamObjects who given extraJson
    completed <- tryPartial libs inProgress name merged
    applyRemapChain libs inProgress ops completed
  _ -> Left (TypeMismatch (who <> ": completing a partial import expects exactly 1 object argument"))
applyFunctionValue _ _ who (VJson _) _ = Left (TypeMismatch (who <> " expects a function value (a lambda, or a name bound to one)"))
applyFunctionValue _ _ who (VNode _) _ = Left (TypeMismatch (who <> " expects a function value, got a rendered node"))
applyFunctionValue _ _ who (VEnv _) _ = Left (TypeMismatch (who <> " expects a function value, got a library/env value"))

applyClosure :: LibraryTable -> Set Text -> [Text] -> Expr -> Env -> [Value'] -> Either EvalError Value'
applyClosure libs inProgress params body closureEnv argVals
  | length params /= length argVals =
      Left (TypeMismatch ("closure expects " <> tshow (length params) <> " argument(s), got " <> tshow (length argVals)))
  | otherwise =
      evalExpr libs inProgress (foldl' (\e (p, v) -> Map.insert p v e) closureEnv (zip params argVals)) body

evalExpr :: LibraryTable -> Set Text -> Env -> Expr -> Either EvalError Value'
evalExpr _ _ env (Path segs) = resolvePath env segs
evalExpr libs inProgress env (Call segs argExprs) = case segs of
  [name] -> case Map.lookup name env of
    Just boundVal@(VClosure _ _ _) -> do
      argVals <- mapM (evalExpr libs inProgress env) argExprs
      applyFunctionValue libs inProgress name boundVal argVals
    Just boundVal@(VPartial _ _) -> do
      argVals <- mapM (evalExpr libs inProgress env) argExprs
      applyFunctionValue libs inProgress name boundVal argVals
    Just boundVal@(VRemapPartial _ _ _) -> do
      argVals <- mapM (evalExpr libs inProgress env) argExprs
      applyFunctionValue libs inProgress name boundVal argVals
    Just (VNode _) -> Left (TypeMismatch (name <> " is bound to a rendered node, not a function"))
    Just (VEnv _) -> Left (TypeMismatch (name <> " is bound to a library/env value, not a function -- access a field first"))
    _ -> do
      argJsons <- mapM (evalExprAsJson libs inProgress env) argExprs
      VJson <$> evalBuiltin name argJsons
  _ -> Left (TypeMismatch ("cannot call " <> tshow segs <> " -- only a single bound/builtin name can be called, e.g. $cardinality(...), not a dotted path"))
evalExpr libs inProgress env (StringLit parts) = VJson . String <$> evalStringParts libs inProgress env parts
evalExpr _ _ _ (NumberLit n) = pure (VJson (Number (realToFrac n)))
evalExpr _ _ _ (BoolLit b) = pure (VJson (Bool b))
evalExpr libs inProgress env (ArrayLit elems) = VJson . Array . V.fromList <$> mapM (evalExprAsJson libs inProgress env) elems
evalExpr libs inProgress env (ObjectLit entries) =
  VJson . Object . KeyMap.fromList <$> mapM (\(k, e) -> (\v -> (Key.fromText k, v)) <$> evalExprAsJson libs inProgress env e) entries
evalExpr _ _ env (LambdaExpr params body) = pure (VClosure params body env)
evalExpr libs inProgress env (MapExpr arrExpr fnExpr) = do
  items <- evalArrayExpr libs inProgress "map" env arrExpr
  fnVal <- evalExpr libs inProgress env fnExpr
  results <- mapM (\item -> applyFunctionValue libs inProgress "map" fnVal [VJson item] >>= requireJson) items
  pure (VJson (Array (V.fromList results)))
evalExpr libs inProgress env (FilterExpr arrExpr fnExpr) = do
  items <- evalArrayExpr libs inProgress "filter" env arrExpr
  fnVal <- evalExpr libs inProgress env fnExpr
  kept <- mapM (\item -> keepIf item <$> (applyFunctionValue libs inProgress "filter" fnVal [VJson item] >>= requireBoolean)) items
  pure (VJson (Array (V.fromList [x | Just x <- kept])))
  where
    keepIf :: Value -> Bool -> Maybe Value
    keepIf item True = Just item
    keepIf _ False = Nothing
evalExpr libs inProgress env (ScanExpr arrExpr initExpr fnExpr) = do
  items <- evalArrayExpr libs inProgress "scan" env arrExpr
  initAcc <- evalExprAsJson libs inProgress env initExpr
  fnVal <- evalExpr libs inProgress env fnExpr
  results <- scanSteps fnVal initAcc items
  pure (VJson (Array (V.fromList results)))
  where
    -- | @scan@\'s output is @[init, step(init, x1), step(step(init, x1),
    -- x2), ...]@ -- standard @scanl@ semantics, not @scanl1@.
    scanSteps :: Value' -> Value -> [Value] -> Either EvalError [Value]
    scanSteps _ acc [] = Right [acc]
    scanSteps fnVal acc (item : rest) = do
      nextAcc <- applyFunctionValue libs inProgress "scan" fnVal [VJson acc, VJson item] >>= requireJson
      restAccs <- scanSteps fnVal nextAcc rest
      pure (acc : restAccs)
evalExpr libs inProgress env (FoldExpr arrExpr initExpr fnExpr) = do
  items <- evalArrayExpr libs inProgress "fold" env arrExpr
  initAcc <- evalExprAsJson libs inProgress env initExpr
  fnVal <- evalExpr libs inProgress env fnExpr
  VJson <$> foldSteps fnVal initAcc items
  where
    -- | Same @(acc, item)@ step and @scanl@ iteration order as 'ScanExpr',
    -- but only the final accumulator is kept -- no intermediate array.
    foldSteps :: Value' -> Value -> [Value] -> Either EvalError Value
    foldSteps _ acc [] = Right acc
    foldSteps fnVal acc (item : rest) = do
      nextAcc <- applyFunctionValue libs inProgress "fold" fnVal [VJson acc, VJson item] >>= requireJson
      foldSteps fnVal nextAcc rest
evalExpr libs inProgress env (ImportExpr name paramsExpr) = do
  paramsJson <- evalExprAsJson libs inProgress env paramsExpr
  runLibrary libs inProgress name paramsJson
evalExpr libs inProgress env (PartialImportExpr name paramsExpr) = do
  paramsJson <- evalExprAsJson libs inProgress env paramsExpr
  tryPartial libs inProgress name paramsJson
evalExpr libs inProgress env (FieldAccess baseExpr segs) = do
  v <- evalExpr libs inProgress env baseExpr
  walkFields segs v segs
evalExpr libs inProgress env (RemapActionsExpr nodeExpr keySpec fnExpr) = do
  v <- evalExpr libs inProgress env nodeExpr
  prefix <- evalKeySpec libs inProgress env keySpec
  fnVal <- evalExpr libs inProgress env fnExpr
  case v of
    VNode _ -> remapActionsInValue libs inProgress prefix fnVal v
    VEnv _ -> remapActionsInValue libs inProgress prefix fnVal v
    VPartial _ _ -> remapActionsInValue libs inProgress prefix fnVal v
    VRemapPartial _ _ _ -> remapActionsInValue libs inProgress prefix fnVal v
    _ -> Left (TypeMismatch "remap-actions expects a rendered node, an import/partial-import result, or a still-suspended partial-import, e.g. $lib, $lib.rendered, or $partial")

-- | Evaluates @remap-actions@'s second argument to the prefix string it
-- names -- @prefix(prefixExpr)@'s only current shape, kept as its own
-- function so a future key-rewriting operation (e.g. @replace(...)@) has
-- somewhere to slot in without touching 'RemapActionsExpr''s eval rule.
evalKeySpec :: LibraryTable -> Set Text -> Env -> KeySpec -> Either EvalError Text
evalKeySpec libs inProgress env (KeyPrefix prefixExpr) = do
  j <- evalExprAsJson libs inProgress env prefixExpr
  case j of
    String s -> Right s
    _ -> Left (TypeMismatch "remap-actions: prefix(...) must evaluate to a string")

-- | Recursively remaps every rendered 'Node' reachable from @v@ -- a bare
-- node remaps directly, and a 'VEnv' (an import\/partial-import result)
-- descends into *every* one of its values, not just @"rendered"@. A still-
-- suspended 'VPartial'\/'VRemapPartial' has nothing to remap yet -- @fn@ is
-- queued onto it and applied once completion actually produces a node\/env.
-- Anything else (plain JSON, a closure) has no actions to remap and is
-- passed through unchanged.
remapActionsInValue :: LibraryTable -> Set Text -> Text -> Value' -> Value' -> Either EvalError Value'
remapActionsInValue libs inProgress prefix fnVal (VNode n) =
  VNode <$> remapActionsInNode (applyRemapOp libs inProgress prefix fnVal) n
remapActionsInValue libs inProgress prefix fnVal (VEnv e) =
  VEnv <$> traverse (remapActionsInValue libs inProgress prefix fnVal) e
remapActionsInValue _ _ prefix fnVal (VPartial name given) = Right (VRemapPartial name given [(prefix, fnVal)])
remapActionsInValue _ _ prefix fnVal (VRemapPartial name given ops) = Right (VRemapPartial name given (ops ++ [(prefix, fnVal)]))
remapActionsInValue _ _ _ _ v = Right v

-- | Applies each queued @(prefix, fn)@ remap-actions operation, in order, to
-- a value a 'VRemapPartial' just finished completing -- if completion is
-- itself still incomplete (another 'VPartial'), the remaining queue stays
-- attached rather than being lost.
applyRemapChain :: LibraryTable -> Set Text -> [(Text, Value')] -> Value' -> Either EvalError Value'
applyRemapChain libs inProgress ops v = foldl step (Right v) ops
  where
    step acc (prefix, fnVal) = acc >>= remapActionsInValue libs inProgress prefix fnVal

-- | Contramaps every @action(...)@ found anywhere in a rendered 'Node'
-- (recursively through children, not just the node's own root) through
-- @f@ -- one @(prefix, fn)@ remap-actions operation, applied via
-- 'applyRemapOp'.
remapActionsInNode :: (ActionPayload -> Either EvalError ActionPayload) -> Node -> Either EvalError Node
remapActionsInNode _ n@(NText _) = Right n
remapActionsInNode f n@(NElement {neAction, neChildren}) = do
  action' <- traverse f neAction
  children' <- traverse (remapActionsInNode f) neChildren
  pure n {neAction = action', neChildren = children'}

-- | Applies one @remap-actions@ @(prefix, fn)@ operation to one
-- 'ActionPayload': the key is rewritten first, by prepending @prefix@ --
-- the operation @keySpec@ names, applied unconditionally rather than left
-- to @fn@ -- then the prefixed action is handed to @fn@ (out to JSON via
-- 'actionPayloadToJson', through the closure like any other function value)
-- for @eventType@\/@payload@ only; @fn@'s result is validated by
-- 'actionPatchFromJson', and its @key@ (if present) is ignored -- the
-- already-prefixed key from this operation is always what's kept.
applyRemapOp :: LibraryTable -> Set Text -> Text -> Value' -> ActionPayload -> Either EvalError ActionPayload
applyRemapOp libs inProgress prefix fnVal action = do
  let prefixedAction = action {apKey = prefix <> apKey action}
  resultVal <- applyFunctionValue libs inProgress "remap-actions" fnVal [VJson (actionPayloadToJson prefixedAction)]
  resultJson <- requireJson resultVal
  patch <- actionPatchFromJson resultJson
  pure ActionPayload {apEventType = patchEventType patch, apKey = apKey prefixedAction, apPayload = patchPayload patch}

-- | What a @remap-actions@ closure's return value must look like now that
-- key-rewriting has moved to @keySpec@\/'applyRemapOp': an object with a
-- string @eventType@ field and any @payload@ (absent defaults to @null@). A
-- @"key"@ field, if present, is simply not read -- see 'applyRemapOp'.
data ActionPatch = ActionPatch {patchEventType :: Text, patchPayload :: Value}

actionPatchFromJson :: Value -> Either EvalError ActionPatch
actionPatchFromJson (Object obj) = do
  eventType <- case KeyMap.lookup (Key.fromText "eventType") obj of
    Just (String s) -> Right s
    _ -> Left (TypeMismatch "remap-actions: the function's result is missing a string \"eventType\" field")
  let payload = maybe Null id (KeyMap.lookup (Key.fromText "payload") obj)
  pure ActionPatch {patchEventType = eventType, patchPayload = payload}
actionPatchFromJson _ = Left (TypeMismatch "remap-actions: the function must return an object with an eventType field")

-- | Evaluates a library by name against its own fresh @$ctx = paramsJson@,
-- producing a 'VEnv' @{ rendered, vals: VEnv libEnv }@ -- the shared path
-- both @import@ and (via 'tryPartial') @partial-import@ run through.
-- @inProgress@ is the set of library names already being imported on this
-- call chain -- re-entering one of them is a cycle, not recursion.
runLibrary :: LibraryTable -> Set Text -> Text -> Value -> Either EvalError Value'
runLibrary libs inProgress name paramsJson
  | Set.member name inProgress = Left (ImportCycle name)
  | otherwise = do
      src <- maybe (Left (UnknownLibrary name)) Right (Map.lookup name libs)
      let inProgress' = Set.insert name inProgress
      case src of
        ProgramSource (Program bindings root) -> do
          libEnv <- evalBindings libs inProgress' paramsJson bindings
          renderedNode <- evalTemplate libs inProgress' libEnv root
          pure (VEnv (Map.fromList [("rendered", VNode renderedNode), ("vals", VEnv libEnv)]))
        JsonSource (JsonProgram bindings root) -> do
          libEnv <- evalBindings libs inProgress' paramsJson bindings
          renderedVal <- evalExpr libs inProgress' libEnv root
          pure (VEnv (Map.fromList [("rendered", renderedVal), ("vals", VEnv libEnv)]))

-- | @partial-import@\'s core: try the library for real, and downgrade to a
-- suspended 'VPartial' only when the *specific* reason it failed is a
-- @$ctx.\<field\>@ access landing on a key @paramsJson@ doesn't have (a
-- 'PathNotFound' whose path starts at @"ctx"@) -- any other failure still
-- propagates as a hard error, same as plain @import@.
tryPartial :: LibraryTable -> Set Text -> Text -> Value -> Either EvalError Value'
tryPartial libs inProgress name paramsJson = case runLibrary libs inProgress name paramsJson of
  Left (PathNotFound ("ctx" : _)) -> Right (VPartial name paramsJson)
  other -> other

-- | Shallow-merges two JSON objects for completing a partial import --
-- @extra@\'s keys\/values win over @given@\'s on conflict. Both arguments
-- must be objects.
mergeParamObjects :: Text -> Value -> Value -> Either EvalError Value
mergeParamObjects who given extra = case (given, extra) of
  (Object givenObj, Object extraObj) -> Right (Object (KeyMap.union extraObj givenObj))
  _ -> Left (TypeMismatch (who <> ": completing a partial import expects an object argument"))

-- | Shared by map\/filter\/scan\/fold: evaluate the array-producing argument and
-- require it actually be a JSON array.
evalArrayExpr :: LibraryTable -> Set Text -> Text -> Env -> Expr -> Either EvalError [Value]
evalArrayExpr libs inProgress who env arrExpr = do
  j <- evalExprAsJson libs inProgress env arrExpr
  case j of
    Array arr -> Right (V.toList arr)
    _ -> Left (TypeMismatch (who <> " expects an array as its first argument"))

evalStringParts :: LibraryTable -> Set Text -> Env -> [StringPart] -> Either EvalError Text
evalStringParts libs inProgress env parts = T.concat <$> mapM resolvePart parts
  where
    resolvePart :: StringPart -> Either EvalError Text
    resolvePart (Lit s) = pure s
    resolvePart (Interp e) = jsonToDisplayString <$> evalExprAsJson libs inProgress env e

resolvePath :: Env -> [Text] -> Either EvalError Value'
resolvePath env segs = case segs of
  [] -> Left (PathNotFound segs)
  (headSeg : tailSegs) -> case Map.lookup headSeg env of
    Nothing -> Left (UnboundName headSeg)
    Just v -> walkFields segs v tailSegs

-- | Field-walks a 'Value'' by successive named segments -- shared by
-- 'Path' ('resolvePath' above, which has already consumed the leading
-- bound name before calling this) and 'FieldAccess' (where every segment
-- is a field-walk, none consumed by an environment lookup). @context@ is
-- only for error messages.
walkFields :: [Text] -> Value' -> [Text] -> Either EvalError Value'
walkFields _ v [] = Right v
walkFields context v (field : rest) = case v of
  VClosure _ _ _ -> Left (TypeMismatch ("cannot access field " <> field <> " on a function value in path " <> tshow context))
  VNode _ -> Left (TypeMismatch ("cannot access field " <> field <> " on a rendered node in path " <> tshow context))
  VPartial _ _ -> Left (TypeMismatch ("cannot access field " <> field <> " on a partial import in path " <> tshow context))
  VRemapPartial _ _ _ -> Left (TypeMismatch ("cannot access field " <> field <> " on a partial import in path " <> tshow context))
  VEnv e -> case Map.lookup field e of
    Nothing -> Left (PathNotFound context)
    Just v' -> walkFields context v' rest
  VJson j -> case j of
    Object obj -> case KeyMap.lookup (Key.fromText field) obj of
      Nothing -> Left (PathNotFound context)
      Just v' -> walkFields context (VJson v') rest
    _ -> Left (TypeMismatch ("expected an object to look up field " <> field <> " in path " <> tshow context))

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
  "concat" -> concatImpl
  "append" -> binary appendImpl
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

    -- | @concat(a, b, ...)@ -- variadic, joins any number of arrays (0 or
    -- more, @concat()@ is @[]@) into one, preserving order. Each argument
    -- must itself be an array; a non-array argument anywhere in the list
    -- is a 'TypeMismatch', not silently skipped or wrapped.
    concatImpl :: Either EvalError Value
    concatImpl = do
      arrs <- mapM asArray args
      pure (Array (V.concat arrs))

    -- | @append(arr, item)@ -- a new array with @item@ added at the end.
    -- @item@ can be any JSON value, including another array or object
    -- (appended as a single element, not spliced in -- use @concat@ for
    -- that).
    appendImpl :: Value -> Value -> Either EvalError Value
    appendImpl arr item = do
      a <- asArray arr
      pure (Array (V.snoc a item))

    asArray :: Value -> Either EvalError (V.Vector Value)
    asArray (Array arr) = Right arr
    asArray _ = Left (TypeMismatch (name <> " expects an array argument"))

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

evalTemplate :: LibraryTable -> Set Text -> Env -> TemplateNode -> Either EvalError Node
evalTemplate libs inProgress env (TElement tag attrExprs actionExpr children) = do
  attrs <- Map.fromList <$> mapM (\(k, e) -> (,) k . jsonToDisplayString <$> evalExprAsJson libs inProgress env e) attrExprs
  action <- traverse (evalAction libs inProgress env) actionExpr
  childNodes <- evalChildren libs inProgress env children
  pure NElement {neTag = tag, neAttrs = attrs, neAction = action, neChildren = childNodes}
-- | A bare child value doesn't force JSON unconditionally: a 'VNode'
-- (typically @$someImport.rendered@) is spliced directly as this child --
-- tag\/attrs\/children intact -- instead of being stringified.
evalTemplate libs inProgress env (TValue e) = do
  v <- evalExpr libs inProgress env e
  case v of
    VNode n -> pure n
    _ -> NText . jsonToDisplayString <$> requireJson v
evalTemplate _ _ _ (TMap _ _ _) =
  Left (TypeMismatch "a `map(...)` cannot be evaluated as a standalone node -- it only ever appears as a parent's child, never as a template's root")
evalTemplate libs inProgress env (TBranch fallback pairs) = do
  chosen <- pickBranch libs inProgress env fallback pairs
  evalTemplate libs inProgress env chosen

-- | Selects which node a @branch(...)@ child evaluates to -- only the
-- *chosen* 'TemplateNode' is ever passed to 'evalTemplate', so an unreached
-- branch's own errors never surface.
pickBranch :: LibraryTable -> Set Text -> Env -> TemplateNode -> [(Expr, TemplateNode)] -> Either EvalError TemplateNode
pickBranch _ _ _ fallback [] = Right fallback
pickBranch libs inProgress env fallback ((predExpr, node) : rest) = do
  predJson <- evalExprAsJson libs inProgress env predExpr
  p <- case predJson of
    Bool b -> Right b
    _ -> Left (TypeMismatch "branch predicate must evaluate to a boolean")
  if p then Right node else pickBranch libs inProgress env fallback rest

-- | A 'TMap' child expands to zero-or-more 'Node's (one per array item,
-- flattened into the parent's children); every other child produces
-- exactly one.
evalChildren :: LibraryTable -> Set Text -> Env -> [TemplateNode] -> Either EvalError [Node]
evalChildren libs inProgress env children = concat <$> mapM (evalChild env) children
  where
    evalChild :: Env -> TemplateNode -> Either EvalError [Node]
    evalChild env' (TMap arrExpr bindName body) = do
      items <- evalArrayExpr libs inProgress "map" env' arrExpr
      mapM (\item -> evalTemplate libs inProgress (Map.insert bindName (VJson item) env') body) items
    evalChild env' tn = (: []) <$> evalTemplate libs inProgress env' tn
