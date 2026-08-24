-- | Evaluates a parsed `Program` against an input `Json` context,
-- | producing the generic `Node` output AST. Two phases, matching
-- | `specs/templating-language.md`: run computation-block bindings once
-- | (in declaration order, each may reference earlier ones) to build an
-- | environment, then walk the template-block root resolving every
-- | `Path`/interpolation against that environment.
-- |
-- | The environment (`Env`) holds `Value`s, not bare `Json` — a binding
-- | can now hold a closure (`@my-fn=(x) => ...`), not just a `Json`
-- | scalar, which is what makes lambdas genuinely *bindable*: written
-- | once, called by name (`$my-fn(...)`), passed to another function, or
-- | passed to `map`/`filter`/`scan` by reference, same as an inline
-- | lambda literal. See `Value`/`applyClosure` below.
module Templating.Eval
  ( EvalError(..)
  , evalProgram
  , evalJsonProgram
  ) where

import Prelude

import Data.Argonaut.Core (Json, caseJson, fromArray, fromBoolean, fromNumber, fromObject, fromString, stringify, toArray, toBoolean, toNumber, toObject, toString)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldM)
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign.Object as Object
import Templating.Ast (ActionPayload, Expr(..), JsonProgram, Node(..), Program, StringPart(..), TAction(..), TemplateNode(..))

data EvalError
  = UnboundName String
  | UnknownFunction String
  | PathNotFound (Array String)
  | TypeMismatch String

derive instance eqEvalError :: Eq EvalError

instance showEvalError :: Show EvalError where
  show (UnboundName name) = "UnboundName " <> show name
  show (UnknownFunction name) = "UnknownFunction " <> show name
  show (PathNotFound segs) = "PathNotFound " <> show segs
  show (TypeMismatch msg) = "TypeMismatch " <> show msg

-- | Everything a name in the environment (or an evaluated `expr`) can be:
-- | an ordinary `Json` value, or a closure — a `LambdaExpr`'s parameter
-- | names and body, paired with the environment captured at the moment
-- | it was evaluated (lexical scoping, so a closure's body can still see
-- | whatever was in scope where it was *written*, not just its own
-- | parameters). **No recursion**: `evalBindings` inserts a binding's
-- | value only *after* evaluating its right-hand side, so a closure's
-- | captured environment never includes its own not-yet-inserted name —
-- | a lambda can't call itself by name from within its own body.
data Value
  = VJson Json
  | VClosure (Array String) Expr Env

type Env = Map String Value

-- | Both `eventType` and `key` must reduce to strings, and that is the
-- | whole check — an event type is handed to the host verbatim, whatever
-- | it says. `eventType` stopped being a parse-time keyword a while ago
-- | (see `Templating.Ast`'s `TAction`) and no longer has a fixed
-- | vocabulary at eval time either: the language isn't Halogen-only, so
-- | which event/hook names mean something is the host's concern. A DOM
-- | host knows `on-click`; an email or static-site renderer has no DOM
-- | events at all and may want names of its own, possibly computed
-- | (`action($ctx.eventName, ...)`).
-- |
-- | Consequence for hosts: a dispatcher must branch on `eventType`, not
-- | assume it. `Templating.Halogen.foldToHalogen` wires `HE.onClick` for
-- | any present action, so a Halogen host that starts using a second
-- | event type has to return `Nothing` from `dispatch` for the ones it
-- | does not want wired to a click.
evalAction :: Env -> TAction -> Either EvalError ActionPayload
evalAction env (TAction eventTypeExpr keyExpr payloadExpr) = do
  eventTypeJson <- evalExprAsJson env eventTypeExpr
  eventType <- maybe (Left (TypeMismatch "action(...): the event type (1st argument) must be a string")) Right (toString eventTypeJson)
  keyJson <- evalExprAsJson env keyExpr
  key <- maybe (Left (TypeMismatch "action(...): the key (2nd argument) must be a string")) Right (toString keyJson)
  payload <- evalExprAsJson env payloadExpr
  pure { eventType, key, payload }

evalProgram :: Json -> Program -> Either EvalError Node
evalProgram input program = do
  env <- evalBindings input program.bindings
  evalTemplate env program.root

-- | Evaluates a `JsonProgram`: the same computation block as `evalProgram`
-- | (same order, same closures, same no-recursion rule) but the root is an
-- | `Expr`, so the result is a `Json` value rather than a document `Node`.
-- | Nothing here is stringified through `jsonToDisplayString` -- numbers
-- | stay numbers and nested objects stay objects, which is precisely what a
-- | host generating a JSON payload (rather than a document) needs.
evalJsonProgram :: Json -> JsonProgram -> Either EvalError Json
evalJsonProgram input program = do
  env <- evalBindings input program.bindings
  evalExprAsJson env program.root

-- | Run every `comp-block` binding once, in declaration order, against an
-- | environment that starts as just `{ ctx: input }` and accumulates one
-- | more entry per binding — later bindings can reference earlier ones
-- | (and `$ctx`), never the reverse, matching the "small expression
-- | language, no recursion" scope decision (see `Value`'s note on why
-- | that applies to closures too, not just plain values).
evalBindings :: Json -> Array (Tuple String Expr) -> Either EvalError Env
evalBindings input = foldM step (Map.singleton "ctx" (VJson input))
  where
  step :: Env -> Tuple String Expr -> Either EvalError Env
  step env (Tuple name e) = do
    v <- evalExpr env e
    pure (Map.insert name v env)

-- | A `Value` used where a `Json` is required (an attribute, interpolated
-- | text, an array/object literal element, a builtin's argument) must
-- | actually be one — a closure can't be stringified, stored inside a
-- | JSON array, or passed to a fixed builtin. Call it (`$my-fn(...)`)
-- | first if you need its result.
requireJson :: Value -> Either EvalError Json
requireJson (VJson j) = Right j
requireJson (VClosure _ _ _) = Left (TypeMismatch "expected a value, got a function — call it first, e.g. $my-fn(...), instead of using it directly")

evalExprAsJson :: Env -> Expr -> Either EvalError Json
evalExprAsJson env e = evalExpr env e >>= requireJson

requireBoolean :: Value -> Either EvalError Boolean
requireBoolean v = do
  j <- requireJson v
  maybe (Left (TypeMismatch "expected a boolean")) Right (toBoolean j)

-- | Applies a function `Value` (a closure, from an inline `LambdaExpr` or
-- | a bound name) to already-evaluated argument `Value`s — shared by
-- | `Call`-on-a-bound-closure and by `map`/`filter`/`scan`'s transform
-- | argument.
applyFunctionValue :: String -> Value -> Array Value -> Either EvalError Value
applyFunctionValue _ (VClosure params body closureEnv) argVals = applyClosure params body closureEnv argVals
applyFunctionValue who (VJson _) _ = Left (TypeMismatch (who <> " expects a function value (a lambda, or a name bound to one)"))

applyClosure :: Array String -> Expr -> Env -> Array Value -> Either EvalError Value
applyClosure params body closureEnv argVals =
  if Array.length params /= Array.length argVals then
    Left (TypeMismatch ("closure expects " <> show (Array.length params) <> " argument(s), got " <> show (Array.length argVals)))
  else
    evalExpr (Array.foldl (\e (Tuple p v) -> Map.insert p v e) closureEnv (Array.zip params argVals)) body

evalExpr :: Env -> Expr -> Either EvalError Value
evalExpr env (Path segs) = resolvePath env segs
evalExpr env (Call segs argExprs) = case segs of
  [ name ] -> case Map.lookup name env of
    Just (VClosure params body closureEnv) -> do
      argVals <- traverse (evalExpr env) argExprs
      applyClosure params body closureEnv argVals
    _ -> do
      argJsons <- traverse (evalExprAsJson env) argExprs
      VJson <$> evalBuiltin name argJsons
  _ -> Left (TypeMismatch ("cannot call " <> show segs <> " — only a single bound/builtin name can be called, e.g. $cardinality(...), not a dotted path"))
evalExpr env (StringLit parts) = VJson <<< fromString <$> evalStringParts env parts
evalExpr _ (NumberLit n) = pure (VJson (fromNumber n))
evalExpr _ (BoolLit b) = pure (VJson (fromBoolean b))
evalExpr env (ArrayLit elems) = VJson <<< fromArray <$> traverse (evalExprAsJson env) elems
evalExpr env (ObjectLit entries) =
  VJson <<< fromObject <<< Object.fromFoldable <$> traverse (\(Tuple k e) -> Tuple k <$> evalExprAsJson env e) entries
evalExpr env (LambdaExpr params body) = pure (VClosure params body env)
evalExpr env (MapExpr arrExpr fnExpr) = do
  items <- evalArrayExpr "map" env arrExpr
  fnVal <- evalExpr env fnExpr
  results <- traverse (\item -> applyFunctionValue "map" fnVal [ VJson item ] >>= requireJson) items
  pure (VJson (fromArray results))
evalExpr env (FilterExpr arrExpr fnExpr) = do
  items <- evalArrayExpr "filter" env arrExpr
  fnVal <- evalExpr env fnExpr
  kept <- traverse (\item -> keepIf item <$> (applyFunctionValue "filter" fnVal [ VJson item ] >>= requireBoolean)) items
  pure (VJson (fromArray (Array.catMaybes kept)))
  where
  keepIf :: Json -> Boolean -> Maybe Json
  keepIf item true = Just item
  keepIf _ false = Nothing
evalExpr env (ScanExpr arrExpr initExpr fnExpr) = do
  items <- evalArrayExpr "scan" env arrExpr
  initAcc <- evalExprAsJson env initExpr
  fnVal <- evalExpr env fnExpr
  results <- scanSteps fnVal initAcc items
  pure (VJson (fromArray results))
  where
  -- | `scan`'s output is `[init, step(init, x1), step(step(init, x1),
  -- | x2), ...]` — the seed is the first element, so the result array is
  -- | always one longer than the input array (standard `scanl`
  -- | semantics, not `scanl1`).
  scanSteps :: Value -> Json -> Array Json -> Either EvalError (Array Json)
  scanSteps fnVal acc items = case Array.uncons items of
    Nothing -> Right [ acc ]
    Just { head: item, tail: rest } -> do
      nextAcc <- applyFunctionValue "scan" fnVal [ VJson acc, VJson item ] >>= requireJson
      restAccs <- scanSteps fnVal nextAcc rest
      pure (Array.cons acc restAccs)
evalExpr env (FoldExpr arrExpr initExpr fnExpr) = do
  items <- evalArrayExpr "fold" env arrExpr
  initAcc <- evalExprAsJson env initExpr
  fnVal <- evalExpr env fnExpr
  VJson <$> foldSteps fnVal initAcc items
  where
  -- | Same `(acc, item)` step and `scanl` iteration order as `scan`, but
  -- | only the final accumulator is kept — no intermediate array.
  foldSteps :: Value -> Json -> Array Json -> Either EvalError Json
  foldSteps fnVal acc items = case Array.uncons items of
    Nothing -> Right acc
    Just { head: item, tail: rest } -> do
      nextAcc <- applyFunctionValue "fold" fnVal [ VJson acc, VJson item ] >>= requireJson
      foldSteps fnVal nextAcc rest

-- | Shared by `map`/`filter`/`scan`/`fold`: evaluate the array-producing
-- | argument and require it actually be a `Json` array.
evalArrayExpr :: String -> Env -> Expr -> Either EvalError (Array Json)
evalArrayExpr who env arrExpr = do
  j <- evalExprAsJson env arrExpr
  maybe (Left (TypeMismatch (who <> " expects an array as its first argument"))) Right (toArray j)

evalStringParts :: Env -> Array StringPart -> Either EvalError String
evalStringParts env parts = Array.fold <$> traverse resolvePart parts
  where
  resolvePart :: StringPart -> Either EvalError String
  resolvePart (Lit s) = pure s
  resolvePart (Interp e) = jsonToDisplayString <$> evalExprAsJson env e

resolvePath :: Env -> Array String -> Either EvalError Value
resolvePath env segs = case Array.uncons segs of
  Nothing -> Left (PathNotFound segs)
  Just { head, tail } -> case Map.lookup head env of
    Nothing -> Left (UnboundName head)
    Just v -> walkFields v tail
  where
  walkFields :: Value -> Array String -> Either EvalError Value
  walkFields v [] = Right v
  walkFields v fields = case Array.uncons fields of
    Nothing -> Right v
    Just { head: field, tail: rest } -> case v of
      VClosure _ _ _ -> Left (TypeMismatch ("cannot access field " <> field <> " on a function value in path " <> show segs))
      VJson j -> case toObject j of
        Nothing -> Left (TypeMismatch ("expected an object to look up field " <> field <> " in path " <> show segs))
        Just obj -> case Object.lookup field obj of
          Nothing -> Left (PathNotFound segs)
          Just v' -> walkFields (VJson v') rest

-- | Fixed builtin set — grown only on real demand, per the scope
-- | decision against an extension registry. `map` is deliberately absent
-- | here: it produces nodes, not a scalar `Json` value, so it's handled
-- | structurally via `TMap` in `evalChildren`, not as a `Call`. Only
-- | reached once `Call`'s evaluation has already checked the name isn't
-- | bound to a user closure.
evalBuiltin :: String -> Array Json -> Either EvalError Json
evalBuiltin name args = case name of
  "cardinality" -> cardinality
  "count" -> cardinality
  "not" -> unaryBool
  "and" -> variadicBool (&&) true
  "or" -> variadicBool (||) false
  "eq" -> binary \a b -> Right (fromBoolean (a == b))
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
  arity1 :: forall a. (Json -> Either EvalError a) -> Either EvalError a
  arity1 f = case args of
    [ a ] -> f a
    _ -> Left (TypeMismatch (name <> " expects exactly 1 argument, got " <> show (Array.length args)))

  binary :: (Json -> Json -> Either EvalError Json) -> Either EvalError Json
  binary f = case args of
    [ a, b ] -> f a b
    _ -> Left (TypeMismatch (name <> " expects exactly 2 arguments, got " <> show (Array.length args)))

  ternary :: (Json -> Json -> Json -> Either EvalError Json) -> Either EvalError Json
  ternary f = case args of
    [ a, b, c ] -> f a b c
    _ -> Left (TypeMismatch (name <> " expects exactly 3 arguments, got " <> show (Array.length args)))

  cardinality :: Either EvalError Json
  cardinality = arity1 \j -> caseJson
    (\_ -> Left (TypeMismatch (name <> " expects an array or object, got null")))
    (\_ -> Left (TypeMismatch (name <> " expects an array or object, got a boolean")))
    (\_ -> Left (TypeMismatch (name <> " expects an array or object, got a number")))
    (\_ -> Left (TypeMismatch (name <> " expects an array or object, got a string")))
    (\arr -> Right (fromNumber (Int.toNumber (Array.length arr))))
    (\obj -> Right (fromNumber (Int.toNumber (Object.size obj))))
    j

  asBoolean :: Json -> Either EvalError Boolean
  asBoolean j = maybe (Left (TypeMismatch (name <> " expects a boolean argument"))) Right (toBoolean j)

  asNumber :: Json -> Either EvalError Number
  asNumber j = maybe (Left (TypeMismatch (name <> " expects a number argument"))) Right (toNumber j)

  unaryBool :: Either EvalError Json
  unaryBool = arity1 \j -> fromBoolean <<< not <$> asBoolean j

  -- | `and`/`or` fold over however many arguments are given (including
  -- | zero, vacuously — `and()` is `true`, `or()` is `false`, same as an
  -- | empty conjunction/disjunction mathematically) rather than requiring
  -- | a fixed arity, since "conjunction/disjunction of multiple clauses"
  -- | is naturally variadic.
  variadicBool :: (Boolean -> Boolean -> Boolean) -> Boolean -> Either EvalError Json
  variadicBool op identityVal = do
    bools <- traverse asBoolean args
    pure (fromBoolean (Array.foldl op identityVal bools))

  numericComparison :: (Number -> Number -> Boolean) -> Either EvalError Json
  numericComparison op = binary \a b -> do
    na <- asNumber a
    nb <- asNumber b
    pure (fromBoolean (op na nb))

  -- | Presence/absence predicate — deliberately tolerant: a missing key,
  -- | an out-of-range index, or even a container/key of the wrong shape
  -- | all just answer `false` rather than erroring. `has` exists
  -- | specifically so a template can test for something without already
  -- | knowing it's there; making it throw on exactly the cases it's
  -- | meant to detect would defeat the purpose. `lookup` below shares
  -- | this same tolerant posture (via its mandatory fallback argument),
  -- | unlike static `$path` resolution, which does error on a missing
  -- | field.
  hasImpl :: Json -> Json -> Either EvalError Json
  hasImpl container key = Right (fromBoolean containsKey)
    where
    containsKey = case toObject container, toString key of
      Just obj, Just k -> Object.member k obj
      _, _ -> case toArray container, arrayIndex key of
        Just arr, Just i -> i >= 0 && i < Array.length arr
        _, _ -> false

  -- | Dynamic object/array access by a computed key/index — the dynamic
  -- | counterpart to a static `$path` segment (which only ever names a
  -- | fixed object field). Takes a mandatory third argument, the
  -- | fallback value returned for a missing field, an out-of-range
  -- | index, or a container/key of the wrong shape entirely — `lookup`
  -- | never errors, same tolerant posture as `has` above, just returning
  -- | a value instead of a boolean. The fallback is an ordinary `expr`
  -- | like the other two arguments, so it's evaluated eagerly regardless
  -- | of whether it's actually used, same as every other builtin call —
  -- | this language has no short-circuiting/laziness anywhere.
  lookupImpl :: Json -> Json -> Json -> Either EvalError Json
  lookupImpl container key fallback = Right case toObject container, toString key of
    Just obj, Just k -> fromMaybe fallback (Object.lookup k obj)
    _, _ -> case toArray container, arrayIndex key of
      Just arr, Just i -> fromMaybe fallback (Array.index arr i)
      _, _ -> fallback

  -- | A `Json` number used as an array index must be a non-negative
  -- | integer — `2.5` or `-1` aren't valid indices.
  arrayIndex :: Json -> Maybe Int
  arrayIndex j = do
    n <- toNumber j
    let i = Int.round n
    if Int.toNumber i == n && i >= 0 then Just i else Nothing

  -- | `branch(fallback, pred1, val1, pred2, val2, ...)` — "if pred1,
  -- | val1; else if pred2, val2; ...; else fallback." An `if`/`elif`/
  -- | `else` chain expressed as one builtin call rather than new
  -- | template-block syntax (there's a *separate* template-block
  -- | `branch(...)` for selecting a node instead — see `Templating.Ast`'s
  -- | `TBranch`).
  -- |
  -- | Important limitation, inherited from how every builtin call is
  -- | evaluated: all arguments (every predicate *and* every value,
  -- | taken or not, plus the fallback) are evaluated eagerly before
  -- | `branch` ever runs, same as `lookup`'s fallback above — there is no
  -- | short-circuiting anywhere in this language. A `val2` that would
  -- | itself error (e.g. a `lookup` with no matching fallback, or a
  -- | `cardinality` on the wrong shape) fails the whole `branch` call
  -- | even if `pred1` already matched and `val2` was never "the answer."
  -- | Every value in the chain must be safe to evaluate regardless of
  -- | which predicate wins.
  branchImpl :: Either EvalError Json
  branchImpl = case Array.uncons args of
    Nothing -> Left (TypeMismatch "branch expects at least 1 argument (a fallback value)")
    Just { head: fallback, tail: rest } -> go fallback rest
    where
    go :: Json -> Array Json -> Either EvalError Json
    go fallback rest = case Array.uncons rest of
      Nothing -> Right fallback
      Just { head: predJson, tail: rest1 } -> case Array.uncons rest1 of
        Nothing -> Left (TypeMismatch "branch expects fallback followed by predicate/value pairs — got a trailing predicate with no matching value")
        Just { head: valJson, tail: rest2 } -> do
          p <- asBoolean predJson
          if p then Right valJson else go fallback rest2

  -- | `concat(a, b, ...)` — variadic, joins any number of arrays (0 or
  -- | more, `concat()` is `[]`) into one, preserving order. Each argument
  -- | must itself be an array; a non-array argument anywhere in the list
  -- | is a `TypeMismatch`, not silently skipped or wrapped.
  concatImpl :: Either EvalError Json
  concatImpl = do
    arrs <- traverse asArray args
    pure (fromArray (Array.concat arrs))

  -- | `append(arr, item)` — a new array with `item` added at the end.
  -- | `item` can be any `Json` value, including another array or object
  -- | (appended as a single element, not spliced in — use `concat` for
  -- | that).
  appendImpl :: Json -> Json -> Either EvalError Json
  appendImpl arr item = do
    a <- asArray arr
    pure (fromArray (Array.snoc a item))

  asArray :: Json -> Either EvalError (Array Json)
  asArray j = maybe (Left (TypeMismatch (name <> " expects an array argument"))) Right (toArray j)

-- | How a resolved `Json` value renders when interpolated into template
-- | output (backtick interpolation, or a bare `value` used as a
-- | `child-arg`): strings render raw (no surrounding quotes), numbers
-- | drop a trailing `.0` when integral, everything else falls back to
-- | `stringify`.
jsonToDisplayString :: Json -> String
jsonToDisplayString j = caseJson
  (\_ -> "")
  (\b -> if b then "true" else "false")
  formatNumber
  identity
  (\_ -> stringify j)
  (\_ -> stringify j)
  j
  where
  formatNumber :: Number -> String
  formatNumber n =
    let rounded = Int.round n
    in if Int.toNumber rounded == n then show rounded else show n

evalTemplate :: Env -> TemplateNode -> Either EvalError Node
evalTemplate env (TElement tag attrExprs actionExpr children) = do
  attrs <- Map.fromFoldable <$> traverse (\(Tuple k e) -> Tuple k <<< jsonToDisplayString <$> evalExprAsJson env e) attrExprs
  action <- traverse (evalAction env) actionExpr
  childNodes <- evalChildren env children
  pure (NElement { tag, attrs, action, children: childNodes })
evalTemplate env (TValue e) = NText <<< jsonToDisplayString <$> evalExprAsJson env e
evalTemplate _ (TMap _ _ _) =
  Left (TypeMismatch "a `map(...)` cannot be evaluated as a standalone node — it only ever appears as a parent's child, never as a template's root")
evalTemplate env (TBranch fallback pairs) = do
  chosen <- pickBranch env fallback pairs
  evalTemplate env chosen

-- | Selects which node a `branch(...)` child evaluates to — only the
-- | *chosen* `TemplateNode` is ever passed to `evalTemplate`, so an
-- | unreached branch's own errors never surface (see `Templating.Ast`'s
-- | note on why this is unlike the expr-level `branch` builtin, whose
-- | arguments are all eagerly pre-evaluated `Json` values).
pickBranch :: Env -> TemplateNode -> Array (Tuple Expr TemplateNode) -> Either EvalError TemplateNode
pickBranch env fallback pairs = case Array.uncons pairs of
  Nothing -> Right fallback
  Just { head: Tuple predExpr node, tail: rest } -> do
    p <- evalExprAsJson env predExpr >>= \j -> maybe (Left (TypeMismatch "branch predicate must evaluate to a boolean")) Right (toBoolean j)
    if p then Right node else pickBranch env fallback rest

-- | A `TMap` child expands to zero-or-more `Node`s (one per array item,
-- | flattened into the parent's children); every other child produces
-- | exactly one. Kept separate from `evalTemplate` because `evalTemplate`
-- | always returns a single `Node`, which a `map(...)` can't honor in
-- | general.
evalChildren :: Env -> Array TemplateNode -> Either EvalError (Array Node)
evalChildren env children = Array.concat <$> traverse (evalChild env) children
  where
  evalChild :: Env -> TemplateNode -> Either EvalError (Array Node)
  evalChild env' (TMap arrExpr bindName body) = do
    items <- evalArrayExpr "map" env' arrExpr
    traverse (\item -> evalTemplate (Map.insert bindName (VJson item) env') body) items
  evalChild env' tn = Array.singleton <$> evalTemplate env' tn
