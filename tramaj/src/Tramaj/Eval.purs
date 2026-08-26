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
module Tramaj.Eval
  ( EvalError(..)
  , LibraryTable
  , LibrarySource(..)
  , evalProgram
  , evalJsonProgram
  ) where

import Prelude

import Data.Argonaut.Core (Json, caseJson, fromArray, fromBoolean, fromNumber, fromObject, fromString, jsonNull, stringify, toArray, toBoolean, toNumber, toObject, toString)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldM, foldl)
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign.Object as Object
import Tramaj.Ast (ActionPayload, Expr(..), JsonProgram, Node(..), Program, StringPart(..), TAction(..), TemplateNode(..), actionPayloadToJson, nodeToJson)

data EvalError
  = UnboundName String
  | UnknownFunction String
  | PathNotFound (Array String)
  | TypeMismatch String
  | UnknownLibrary String
  | ImportCycle String

derive instance eqEvalError :: Eq EvalError

instance showEvalError :: Show EvalError where
  show (UnboundName name) = "UnboundName " <> show name
  show (UnknownFunction name) = "UnknownFunction " <> show name
  show (PathNotFound segs) = "PathNotFound " <> show segs
  show (TypeMismatch msg) = "TypeMismatch " <> show msg
  show (UnknownLibrary name) = "UnknownLibrary " <> show name
  show (ImportCycle name) = "ImportCycle " <> show name

-- | A library can be rooted either way a top-level program can: an
-- | element (`Program`, same as `evalProgram`) or an expression
-- | (`JsonProgram`, same as `evalJsonProgram`). There's no principled
-- | reason to force every library through the element-rooted grammar —
-- | `.rendered` is just "whatever the root evaluated to," and an `Expr`
-- | can already produce a `VNode` itself (e.g. a bare path to something
-- | bound from a nested `import`), the same way a `map(...)` lambda body
-- | already can. See `runLibrary`.
data LibrarySource
  = ProgramSource Program
  | JsonSource JsonProgram

-- | Host-supplied library store: a library name (as used in
-- | `import(name, params)`/`partial-import(name, params)`) resolves to an
-- | already-parsed `LibrarySource`. Where that source came from (a file, an
-- | embedded string, a remote fetch) is entirely a host concern — the
-- | evaluator only ever sees the parsed result, same posture as the `Json`
-- | `input` argument it already takes.
type LibraryTable = Map String LibrarySource

-- | Everything a name in the environment (or an evaluated `expr`) can be:
-- | an ordinary `Json` value, a closure — a `LambdaExpr`'s parameter names
-- | and body, paired with the environment captured at the moment it was
-- | evaluated (lexical scoping, so a closure's body can still see whatever
-- | was in scope where it was *written*, not just its own parameters) —
-- | or one of three values `import`/`partial-import` introduce:
-- |
-- | * `VNode` — a fully-evaluated document `Node`, e.g. an imported
-- |   library's rendered output. Spliced directly as a child when it
-- |   appears in a `TValue` child position (see `evalTemplate`); reduces to
-- |   `Json` via `nodeToJson` (see `requireJson`) anywhere a scalar value
-- |   is required instead (a string interpolation, a builtin argument,
-- |   JSON-mode output).
-- | * `VEnv` — a named bag of `Value`s, e.g. an `import` result's
-- |   `{ rendered, vals }` record, or a library's `vals` themselves. Plain
-- |   field access (`.rendered`, `.vals`, or a binding name inside `vals`)
-- |   walks it exactly like the top-level `Env`, via `resolvePath`.
-- | * `VPartial` — a suspended `partial-import`: the library name plus
-- |   whatever params were given so far. Not itself reducible to `Json`;
-- |   calling it with one more params object (`applyFunctionValue`) either
-- |   completes the import (same result `import` would have produced with
-- |   the merged params) or suspends again. See `tryPartial`.
-- | * `VRemapPartial` — a `VPartial` with one or more `remap-actions`
-- |   functions already queued up (`remap-actions($partial, fn)`, before
-- |   `$partial` is complete): the library name, params so far, and the
-- |   fns to apply, in order, once completion actually produces a node/env
-- |   to remap. Lets a `remap-actions` wrapping be attached once to a
-- |   partial import in the computation block, before the per-item value
-- |   that completes it is even in scope (e.g. inside a `map(...)` body),
-- |   instead of having to re-wrap `remap-actions(...)` around every call
-- |   site that completes it. See `applyRemapChain`.
-- |
-- | **No recursion**: `evalBindings` inserts a binding's value only
-- | *after* evaluating its right-hand side, so a closure's captured
-- | environment never includes its own not-yet-inserted name — a lambda
-- | can't call itself by name from within its own body.
data Value
  = VJson Json
  | VClosure (Array String) Expr Env
  | VNode Node
  | VEnv Env
  | VPartial String Json
  | VRemapPartial String Json (Array Value)

type Env = Map String Value

-- | Both `eventType` and `key` must reduce to strings, and that is the
-- | whole check — an event type is handed to the host verbatim, whatever
-- | it says. `eventType` stopped being a parse-time keyword a while ago
-- | (see `Tramaj.Ast`'s `TAction`) and no longer has a fixed
-- | vocabulary at eval time either: the language isn't Halogen-only, so
-- | which event/hook names mean something is the host's concern. A DOM
-- | host knows `on-click`; an email or static-site renderer has no DOM
-- | events at all and may want names of its own, possibly computed
-- | (`action($ctx.eventName, ...)`).
-- |
-- | Consequence for hosts: a dispatcher must branch on `eventType`, not
-- | assume it. `Tramaj.Halogen.foldToHalogen` wires `HE.onClick` for
-- | any present action, so a Halogen host that starts using a second
-- | event type has to return `Nothing` from `dispatch` for the ones it
-- | does not want wired to a click.
evalAction :: LibraryTable -> Set String -> Env -> TAction -> Either EvalError ActionPayload
evalAction libs inProgress env (TAction eventTypeExpr keyExpr payloadExpr) = do
  eventTypeJson <- evalExprAsJson libs inProgress env eventTypeExpr
  eventType <- maybe (Left (TypeMismatch "action(...): the event type (1st argument) must be a string")) Right (toString eventTypeJson)
  keyJson <- evalExprAsJson libs inProgress env keyExpr
  key <- maybe (Left (TypeMismatch "action(...): the key (2nd argument) must be a string")) Right (toString keyJson)
  payload <- evalExprAsJson libs inProgress env payloadExpr
  pure { eventType, key, payload }

evalProgram :: LibraryTable -> Json -> Program -> Either EvalError Node
evalProgram libs input program = do
  env <- evalBindings libs Set.empty input program.bindings
  evalTemplate libs Set.empty env program.root

-- | Evaluates a `JsonProgram`: the same computation block as `evalProgram`
-- | (same order, same closures, same no-recursion rule) but the root is an
-- | `Expr`, so the result is a `Json` value rather than a document `Node`.
-- | Nothing here is stringified through `jsonToDisplayString` -- numbers
-- | stay numbers and nested objects stay objects, which is precisely what a
-- | host generating a JSON payload (rather than a document) needs.
evalJsonProgram :: LibraryTable -> Json -> JsonProgram -> Either EvalError Json
evalJsonProgram libs input program = do
  env <- evalBindings libs Set.empty input program.bindings
  evalExprAsJson libs Set.empty env program.root

-- | Run every `comp-block` binding once, in declaration order, against an
-- | environment that starts as just `{ ctx: input }` and accumulates one
-- | more entry per binding — later bindings can reference earlier ones
-- | (and `$ctx`), never the reverse, matching the "small expression
-- | language, no recursion" scope decision (see `Value`'s note on why
-- | that applies to closures too, not just plain values).
evalBindings :: LibraryTable -> Set String -> Json -> Array (Tuple String Expr) -> Either EvalError Env
evalBindings libs inProgress input = foldM step (Map.singleton "ctx" (VJson input))
  where
  step :: Env -> Tuple String Expr -> Either EvalError Env
  step env (Tuple name e) = do
    v <- evalExpr libs inProgress env e
    pure (Map.insert name v env)

-- | A `Value` used where a `Json` is required (an attribute, interpolated
-- | text, an array/object literal element, a builtin's argument) must
-- | actually reduce to one. A closure can't (call it first, e.g.
-- | `$my-fn(...)`); a `VNode` reduces via `nodeToJson` (the same
-- | debug-inspection shape `Tramaj.Ast` already exposes); a `VEnv`/
-- | `VPartial` can't either (access a field, or finish applying the
-- | partial import, first).
requireJson :: Value -> Either EvalError Json
requireJson (VJson j) = Right j
requireJson (VClosure _ _ _) = Left (TypeMismatch "expected a value, got a function — call it first, e.g. $my-fn(...), instead of using it directly")
requireJson (VNode n) = Right (nodeToJson n)
requireJson (VEnv _) = Left (TypeMismatch "expected a value, got a library/env value — access .rendered, .vals, or a binding name first")
requireJson (VPartial name _) = Left (TypeMismatch ("expected a value, got a partial import of " <> show name <> " still waiting on params — call it with the missing params first"))
requireJson (VRemapPartial name _ _) = Left (TypeMismatch ("expected a value, got a partial import of " <> show name <> " still waiting on params — call it with the missing params first"))

evalExprAsJson :: LibraryTable -> Set String -> Env -> Expr -> Either EvalError Json
evalExprAsJson libs inProgress env e = evalExpr libs inProgress env e >>= requireJson

requireBoolean :: Value -> Either EvalError Boolean
requireBoolean v = do
  j <- requireJson v
  maybe (Left (TypeMismatch "expected a boolean")) Right (toBoolean j)

-- | Applies a function `Value` (a closure, from an inline `LambdaExpr` or
-- | a bound name; or a suspended partial import) to already-evaluated
-- | argument `Value`s — shared by `Call`-on-a-bound-closure and by
-- | `map`/`filter`/`scan`'s transform argument.
-- |
-- | Completing a `VPartial` shallow-merges its one Json-object argument
-- | into the params already given (new keys win on conflict — supplying a
-- | value for an already-given key behaves the same as if it had been
-- | given that way from the start) and retries via `tryPartial`, so a
-- | still-incomplete merge suspends again and a complete one runs through
-- | exactly the same `runLibrary` path `import` uses — the result is
-- | structurally identical to calling `import` with the fully-merged
-- | params up front, not an incremental approximation of it.
applyFunctionValue :: LibraryTable -> Set String -> String -> Value -> Array Value -> Either EvalError Value
applyFunctionValue libs inProgress _ (VClosure params body closureEnv) argVals = applyClosure libs inProgress params body closureEnv argVals
applyFunctionValue libs inProgress who (VPartial name given) argVals = case argVals of
  [ VJson extraJson ] -> do
    merged <- mergeParamObjects who given extraJson
    tryPartial libs inProgress name merged
  _ -> Left (TypeMismatch (who <> ": completing a partial import expects exactly 1 object argument"))
applyFunctionValue libs inProgress who (VRemapPartial name given fns) argVals = case argVals of
  [ VJson extraJson ] -> do
    merged <- mergeParamObjects who given extraJson
    completed <- tryPartial libs inProgress name merged
    applyRemapChain libs inProgress fns completed
  _ -> Left (TypeMismatch (who <> ": completing a partial import expects exactly 1 object argument"))
applyFunctionValue _ _ who (VJson _) _ = Left (TypeMismatch (who <> " expects a function value (a lambda, or a name bound to one)"))
applyFunctionValue _ _ who (VNode _) _ = Left (TypeMismatch (who <> " expects a function value, got a rendered node"))
applyFunctionValue _ _ who (VEnv _) _ = Left (TypeMismatch (who <> " expects a function value, got a library/env value"))

applyClosure :: LibraryTable -> Set String -> Array String -> Expr -> Env -> Array Value -> Either EvalError Value
applyClosure libs inProgress params body closureEnv argVals =
  if Array.length params /= Array.length argVals then
    Left (TypeMismatch ("closure expects " <> show (Array.length params) <> " argument(s), got " <> show (Array.length argVals)))
  else
    evalExpr libs inProgress (Array.foldl (\e (Tuple p v) -> Map.insert p v e) closureEnv (Array.zip params argVals)) body

evalExpr :: LibraryTable -> Set String -> Env -> Expr -> Either EvalError Value
evalExpr _ _ env (Path segs) = resolvePath env segs
evalExpr libs inProgress env (Call segs argExprs) = case segs of
  [ name ] -> case Map.lookup name env of
    Just boundVal@(VClosure _ _ _) -> do
      argVals <- traverse (evalExpr libs inProgress env) argExprs
      applyFunctionValue libs inProgress name boundVal argVals
    Just boundVal@(VPartial _ _) -> do
      argVals <- traverse (evalExpr libs inProgress env) argExprs
      applyFunctionValue libs inProgress name boundVal argVals
    Just boundVal@(VRemapPartial _ _ _) -> do
      argVals <- traverse (evalExpr libs inProgress env) argExprs
      applyFunctionValue libs inProgress name boundVal argVals
    Just (VNode _) -> Left (TypeMismatch (name <> " is bound to a rendered node, not a function"))
    Just (VEnv _) -> Left (TypeMismatch (name <> " is bound to a library/env value, not a function — access a field first"))
    _ -> do
      argJsons <- traverse (evalExprAsJson libs inProgress env) argExprs
      VJson <$> evalBuiltin name argJsons
  _ -> Left (TypeMismatch ("cannot call " <> show segs <> " — only a single bound/builtin name can be called, e.g. $cardinality(...), not a dotted path"))
evalExpr libs inProgress env (StringLit parts) = VJson <<< fromString <$> evalStringParts libs inProgress env parts
evalExpr _ _ _ (NumberLit n) = pure (VJson (fromNumber n))
evalExpr _ _ _ (BoolLit b) = pure (VJson (fromBoolean b))
evalExpr libs inProgress env (ArrayLit elems) = VJson <<< fromArray <$> traverse (evalExprAsJson libs inProgress env) elems
evalExpr libs inProgress env (ObjectLit entries) =
  VJson <<< fromObject <<< Object.fromFoldable <$> traverse (\(Tuple k e) -> Tuple k <$> evalExprAsJson libs inProgress env e) entries
evalExpr _ _ env (LambdaExpr params body) = pure (VClosure params body env)
evalExpr libs inProgress env (MapExpr arrExpr fnExpr) = do
  items <- evalArrayExpr libs inProgress "map" env arrExpr
  fnVal <- evalExpr libs inProgress env fnExpr
  results <- traverse (\item -> applyFunctionValue libs inProgress "map" fnVal [ VJson item ] >>= requireJson) items
  pure (VJson (fromArray results))
evalExpr libs inProgress env (FilterExpr arrExpr fnExpr) = do
  items <- evalArrayExpr libs inProgress "filter" env arrExpr
  fnVal <- evalExpr libs inProgress env fnExpr
  kept <- traverse (\item -> keepIf item <$> (applyFunctionValue libs inProgress "filter" fnVal [ VJson item ] >>= requireBoolean)) items
  pure (VJson (fromArray (Array.catMaybes kept)))
  where
  keepIf :: Json -> Boolean -> Maybe Json
  keepIf item true = Just item
  keepIf _ false = Nothing
evalExpr libs inProgress env (ScanExpr arrExpr initExpr fnExpr) = do
  items <- evalArrayExpr libs inProgress "scan" env arrExpr
  initAcc <- evalExprAsJson libs inProgress env initExpr
  fnVal <- evalExpr libs inProgress env fnExpr
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
      nextAcc <- applyFunctionValue libs inProgress "scan" fnVal [ VJson acc, VJson item ] >>= requireJson
      restAccs <- scanSteps fnVal nextAcc rest
      pure (Array.cons acc restAccs)
evalExpr libs inProgress env (FoldExpr arrExpr initExpr fnExpr) = do
  items <- evalArrayExpr libs inProgress "fold" env arrExpr
  initAcc <- evalExprAsJson libs inProgress env initExpr
  fnVal <- evalExpr libs inProgress env fnExpr
  VJson <$> foldSteps fnVal initAcc items
  where
  -- | Same `(acc, item)` step and `scanl` iteration order as `scan`, but
  -- | only the final accumulator is kept — no intermediate array.
  foldSteps :: Value -> Json -> Array Json -> Either EvalError Json
  foldSteps fnVal acc items = case Array.uncons items of
    Nothing -> Right acc
    Just { head: item, tail: rest } -> do
      nextAcc <- applyFunctionValue libs inProgress "fold" fnVal [ VJson acc, VJson item ] >>= requireJson
      foldSteps fnVal nextAcc rest
evalExpr libs inProgress env (ImportExpr nameExpr paramsExpr) = do
  name <- evalExprAsJson libs inProgress env nameExpr >>= expectLibName
  paramsJson <- evalExprAsJson libs inProgress env paramsExpr
  runLibrary libs inProgress name paramsJson
evalExpr libs inProgress env (PartialImportExpr nameExpr paramsExpr) = do
  name <- evalExprAsJson libs inProgress env nameExpr >>= expectLibName
  paramsJson <- evalExprAsJson libs inProgress env paramsExpr
  tryPartial libs inProgress name paramsJson
evalExpr libs inProgress env (FieldAccess baseExpr segs) = do
  v <- evalExpr libs inProgress env baseExpr
  walkFields segs v segs
evalExpr libs inProgress env (RemapActionsExpr nodeExpr fnExpr) = do
  v <- evalExpr libs inProgress env nodeExpr
  fnVal <- evalExpr libs inProgress env fnExpr
  case v of
    VNode _ -> remapActionsInValue libs inProgress fnVal v
    VEnv _ -> remapActionsInValue libs inProgress fnVal v
    VPartial _ _ -> remapActionsInValue libs inProgress fnVal v
    VRemapPartial _ _ _ -> remapActionsInValue libs inProgress fnVal v
    _ -> Left (TypeMismatch "remap-actions expects a rendered node, an import/partial-import result, or a still-suspended partial-import, e.g. $lib, $lib.rendered, or $partial")

-- | Recursively remaps every rendered `Node` reachable from `v` — a bare
-- | node remaps directly, and a `VEnv` (an import/partial-import result)
-- | descends into *every* one of its values, not just `"rendered"`: a
-- | binding under `.vals` can itself be a sub-import (another `VEnv`) with
-- | its own `.rendered` and actions, and those should be remapped too in
-- | case the caller reaches them via `.vals...rendered` instead of the
-- | outer `.rendered`. A still-suspended `VPartial`/`VRemapPartial` has
-- | nothing to remap yet — `fn` is queued onto it (see `VRemapPartial`,
-- | `applyRemapChain`) and applied once completion actually produces a
-- | node/env. Anything else (plain Json, a closure) has no actions to
-- | remap and is passed through unchanged — so a `VEnv` with no node
-- | anywhere inside it is simply a no-op, same as a node with no
-- | `action(...)` anywhere.
remapActionsInValue :: LibraryTable -> Set String -> Value -> Value -> Either EvalError Value
remapActionsInValue libs inProgress fnVal (VNode n) =
  VNode <$> remapActionsInNode (applyRemapFn libs inProgress fnVal) n
remapActionsInValue libs inProgress fnVal (VEnv e) =
  VEnv <$> traverse (remapActionsInValue libs inProgress fnVal) e
remapActionsInValue _ _ fnVal (VPartial name given) = Right (VRemapPartial name given [ fnVal ])
remapActionsInValue _ _ fnVal (VRemapPartial name given fns) = Right (VRemapPartial name given (fns <> [ fnVal ]))
remapActionsInValue _ _ _ v = Right v

-- | Applies each queued `remap-actions` function, in order, to a value a
-- | `VRemapPartial` just finished completing (via `remapActionsInValue`) —
-- | if completion is itself still incomplete (another `VPartial`), the
-- | remaining queue stays attached rather than being lost, so currying a
-- | remapped partial one param at a time still applies every queued fn
-- | once it's finally complete.
applyRemapChain :: LibraryTable -> Set String -> Array Value -> Value -> Either EvalError Value
applyRemapChain libs inProgress fns v = foldl step (Right v) fns
  where
  step acc fn = acc >>= remapActionsInValue libs inProgress fn

-- | Contramaps every `action(...)` found anywhere in a rendered `Node`
-- | (recursively through children, not just the node's own root) through
-- | `fn` — a closure taking/returning the `{eventType, key, payload}` shape
-- | `Tramaj.Ast.actionPayloadToJson` produces. Lets a template that
-- | imports a library rewrite (namespace a key, transform a payload)
-- | whatever actions that library's own template fires before they're
-- | visible to the host, without needing a new `Value` — the result is
-- | still an ordinary `Node`, just with different `action` fields.
remapActionsInNode :: (ActionPayload -> Either EvalError ActionPayload) -> Node -> Either EvalError Node
remapActionsInNode _ n@(NText _) = Right n
remapActionsInNode f (NElement r) = do
  action' <- traverse f r.action
  children' <- traverse (remapActionsInNode f) r.children
  pure (NElement (r { action = action', children = children' }))

-- | Applies a `remap-actions` closure to one `ActionPayload`: out to
-- | `Json` (reusing `actionPayloadToJson`, the same shape `nodeToJson`
-- | shows for an action), through the closure like any other function
-- | value (a `VClosure`, or a `VPartial` completed by this one call — the
-- | common case is an inline lambda, but nothing else about
-- | `applyFunctionValue` is specific to that), then validated back into an
-- | `ActionPayload` by `actionPayloadFromJson`.
applyRemapFn :: LibraryTable -> Set String -> Value -> ActionPayload -> Either EvalError ActionPayload
applyRemapFn libs inProgress fnVal action = do
  resultVal <- applyFunctionValue libs inProgress "remap-actions" fnVal [ VJson (actionPayloadToJson action) ]
  resultJson <- requireJson resultVal
  actionPayloadFromJson resultJson

-- | The inverse of `Tramaj.Ast.actionPayloadToJson` — what a
-- | `remap-actions` closure's return value must look like: an object with
-- | string `eventType`/`key` fields (the same requirement a literal
-- | `action(...)` is held to by `evalAction`) and any `payload` (absent
-- | defaults to `null`, so a remap fn that only cares about the key isn't
-- | forced to echo `payload` back explicitly).
actionPayloadFromJson :: Json -> Either EvalError ActionPayload
actionPayloadFromJson j = do
  obj <- maybe (Left (TypeMismatch "remap-actions: the function must return an object with eventType/key/payload fields")) Right (toObject j)
  eventType <- fieldAsString obj "eventType"
  key <- fieldAsString obj "key"
  let payload = fromMaybe jsonNull (Object.lookup "payload" obj)
  pure { eventType, key, payload }
  where
  fieldAsString :: Object.Object Json -> String -> Either EvalError String
  fieldAsString obj field = case Object.lookup field obj >>= toString of
    Just s -> Right s
    Nothing -> Left (TypeMismatch ("remap-actions: the function's result is missing a string \"" <> field <> "\" field"))

expectLibName :: Json -> Either EvalError String
expectLibName j = maybe (Left (TypeMismatch "import(...)/partial-import(...): the library name (1st argument) must be a string")) Right (toString j)

-- | Evaluates a library by name against its own fresh `$ctx = paramsJson`,
-- | producing a `VEnv { rendered, vals: VEnv libEnv }` — the shared path
-- | both `import` and (via `tryPartial`) `partial-import` run through, so a
-- | completed partial import and a direct `import` call with the same
-- | merged params are guaranteed to produce the same result: they run the
-- | exact same code, not two independently-written evaluators.
-- | `inProgress` is the set of library names already being imported on
-- | this call chain — re-entering one of them is a cycle, not recursion.
-- |
-- | `rendered` is whatever the library's root actually evaluated to, not
-- | unconditionally a `VNode`: an element-rooted (`ProgramSource`) library
-- | evaluates its `TemplateNode` root and wraps the resulting `Node` in
-- | `VNode` (as before), but an expression-rooted (`JsonSource`) library
-- | just keeps the `Value` its `Expr` root produced — a `VJson` scalar/
-- | array/object ordinarily, but a `VNode` too if that expression happens
-- | to evaluate to one (e.g. a bare path to something bound from a nested
-- | `import`). Every downstream consumer of `rendered` (`TValue`'s splice-
-- | or-stringify, `requireJson`'s `nodeToJson` reduction) already handles
-- | any `Value` uniformly, so which shape a given library used never
-- | matters past this function.
runLibrary :: LibraryTable -> Set String -> String -> Json -> Either EvalError Value
runLibrary libs inProgress name paramsJson
  | Set.member name inProgress = Left (ImportCycle name)
  | otherwise = do
      src <- maybe (Left (UnknownLibrary name)) Right (Map.lookup name libs)
      let inProgress' = Set.insert name inProgress
      case src of
        ProgramSource libProgram -> do
          libEnv <- evalBindings libs inProgress' paramsJson libProgram.bindings
          renderedNode <- evalTemplate libs inProgress' libEnv libProgram.root
          pure (VEnv (Map.fromFoldable [ Tuple "rendered" (VNode renderedNode), Tuple "vals" (VEnv libEnv) ]))
        JsonSource libProgram -> do
          libEnv <- evalBindings libs inProgress' paramsJson libProgram.bindings
          renderedVal <- evalExpr libs inProgress' libEnv libProgram.root
          pure (VEnv (Map.fromFoldable [ Tuple "rendered" renderedVal, Tuple "vals" (VEnv libEnv) ]))

-- | `partial-import`'s core: try the library for real, and downgrade to a
-- | suspended `VPartial` only when the *specific* reason it failed is a
-- | `$ctx.<field>` access landing on a key `paramsJson` doesn't have (a
-- | `PathNotFound` whose path starts at `"ctx"`) — any other failure
-- | (unknown library, an import cycle, a real bug in the library) still
-- | propagates as a hard error, same as plain `import`.
-- |
-- | Known limitation: if the library itself does a nested plain `import`
-- | with incomplete params, that nested failure's path also starts at
-- | `"ctx"` (the nested library's own, freshly-bound one) and is
-- | indistinguishable here from this call's own missing params — the
-- | outer partial import would suspend but supplying more of *its* params
-- | can never actually complete it, since the missing field belongs to the
-- | nested import instead. Not solved here; host-authored libraries are
-- | expected to keep nested imports fully applied.
tryPartial :: LibraryTable -> Set String -> String -> Json -> Either EvalError Value
tryPartial libs inProgress name paramsJson = case runLibrary libs inProgress name paramsJson of
  Left (PathNotFound segs) | Array.head segs == Just "ctx" -> Right (VPartial name paramsJson)
  other -> other

-- | Shallow-merges two `Json` objects for completing a partial import —
-- | `extra`'s keys/values win over `given`'s on conflict, so supplying a
-- | value for an already-given key behaves the same as if it had been
-- | given that way originally. Both arguments must be objects.
mergeParamObjects :: String -> Json -> Json -> Either EvalError Json
mergeParamObjects who given extra = case toObject given, toObject extra of
  Just givenObj, Just extraObj -> Right (fromObject (Object.union extraObj givenObj))
  _, _ -> Left (TypeMismatch (who <> ": completing a partial import expects an object argument"))

-- | Shared by `map`/`filter`/`scan`/`fold`: evaluate the array-producing
-- | argument and require it actually be a `Json` array.
evalArrayExpr :: LibraryTable -> Set String -> String -> Env -> Expr -> Either EvalError (Array Json)
evalArrayExpr libs inProgress who env arrExpr = do
  j <- evalExprAsJson libs inProgress env arrExpr
  maybe (Left (TypeMismatch (who <> " expects an array as its first argument"))) Right (toArray j)

evalStringParts :: LibraryTable -> Set String -> Env -> Array StringPart -> Either EvalError String
evalStringParts libs inProgress env parts = Array.fold <$> traverse resolvePart parts
  where
  resolvePart :: StringPart -> Either EvalError String
  resolvePart (Lit s) = pure s
  resolvePart (Interp e) = jsonToDisplayString <$> evalExprAsJson libs inProgress env e

resolvePath :: Env -> Array String -> Either EvalError Value
resolvePath env segs = case Array.uncons segs of
  Nothing -> Left (PathNotFound segs)
  Just { head, tail } -> case Map.lookup head env of
    Nothing -> Left (UnboundName head)
    Just v -> walkFields segs v tail

-- | Field-walks a `Value` by successive named segments — shared by `Path`
-- | (`resolvePath` above, which has already consumed the leading bound
-- | name before calling this) and `FieldAccess` (below, where `baseExpr`
-- | is evaluated first and *every* segment is a field-walk, none consumed
-- | by an environment lookup). `context` is only for error messages —
-- | `resolvePath` passes the *original* full segment list (so a missing
-- | `$ctx.arg0` still reports/detects as `PathNotFound ["ctx","arg0"]`,
-- | load-bearing for `tryPartial`'s "was this just a missing ctx field"
-- | check); `FieldAccess` has no such "original path" to report, so it
-- | just passes its own field list.
walkFields :: Array String -> Value -> Array String -> Either EvalError Value
walkFields _ v [] = Right v
walkFields context v fields = case Array.uncons fields of
  Nothing -> Right v
  Just { head: field, tail: rest } -> case v of
    VClosure _ _ _ -> Left (TypeMismatch ("cannot access field " <> field <> " on a function value in path " <> show context))
    VNode _ -> Left (TypeMismatch ("cannot access field " <> field <> " on a rendered node in path " <> show context))
    VPartial _ _ -> Left (TypeMismatch ("cannot access field " <> field <> " on a partial import in path " <> show context))
    VRemapPartial _ _ _ -> Left (TypeMismatch ("cannot access field " <> field <> " on a partial import in path " <> show context))
    VEnv e -> case Map.lookup field e of
      Nothing -> Left (PathNotFound context)
      Just v' -> walkFields context v' rest
    VJson j -> case toObject j of
      Nothing -> Left (TypeMismatch ("expected an object to look up field " <> field <> " in path " <> show context))
      Just obj -> case Object.lookup field obj of
        Nothing -> Left (PathNotFound context)
        Just v' -> walkFields context (VJson v') rest

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
  -- | `branch(...)` for selecting a node instead — see `Tramaj.Ast`'s
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

evalTemplate :: LibraryTable -> Set String -> Env -> TemplateNode -> Either EvalError Node
evalTemplate libs inProgress env (TElement tag attrExprs actionExpr children) = do
  attrs <- Map.fromFoldable <$> traverse (\(Tuple k e) -> Tuple k <<< jsonToDisplayString <$> evalExprAsJson libs inProgress env e) attrExprs
  action <- traverse (evalAction libs inProgress env) actionExpr
  childNodes <- evalChildren libs inProgress env children
  pure (NElement { tag, attrs, action, children: childNodes })
-- | A bare child value doesn't force `Json` unconditionally: a `VNode`
-- | (typically `$someImport.rendered`) is spliced directly as this child
-- | — tag/attrs/children intact — instead of being stringified; every
-- | other `Value` still reduces through `requireJson`/`jsonToDisplayString`
-- | exactly as before.
evalTemplate libs inProgress env (TValue e) = do
  v <- evalExpr libs inProgress env e
  case v of
    VNode n -> pure n
    _ -> NText <<< jsonToDisplayString <$> requireJson v
evalTemplate _ _ _ (TMap _ _ _) =
  Left (TypeMismatch "a `map(...)` cannot be evaluated as a standalone node — it only ever appears as a parent's child, never as a template's root")
evalTemplate libs inProgress env (TBranch fallback pairs) = do
  chosen <- pickBranch libs inProgress env fallback pairs
  evalTemplate libs inProgress env chosen

-- | Selects which node a `branch(...)` child evaluates to — only the
-- | *chosen* `TemplateNode` is ever passed to `evalTemplate`, so an
-- | unreached branch's own errors never surface (see `Tramaj.Ast`'s
-- | note on why this is unlike the expr-level `branch` builtin, whose
-- | arguments are all eagerly pre-evaluated `Json` values).
pickBranch :: LibraryTable -> Set String -> Env -> TemplateNode -> Array (Tuple Expr TemplateNode) -> Either EvalError TemplateNode
pickBranch libs inProgress env fallback pairs = case Array.uncons pairs of
  Nothing -> Right fallback
  Just { head: Tuple predExpr node, tail: rest } -> do
    p <- evalExprAsJson libs inProgress env predExpr >>= \j -> maybe (Left (TypeMismatch "branch predicate must evaluate to a boolean")) Right (toBoolean j)
    if p then Right node else pickBranch libs inProgress env fallback rest

-- | A `TMap` child expands to zero-or-more `Node`s (one per array item,
-- | flattened into the parent's children); every other child produces
-- | exactly one. Kept separate from `evalTemplate` because `evalTemplate`
-- | always returns a single `Node`, which a `map(...)` can't honor in
-- | general.
evalChildren :: LibraryTable -> Set String -> Env -> Array TemplateNode -> Either EvalError (Array Node)
evalChildren libs inProgress env children = Array.concat <$> traverse (evalChild env) children
  where
  evalChild :: Env -> TemplateNode -> Either EvalError (Array Node)
  evalChild env' (TMap arrExpr bindName body) = do
    items <- evalArrayExpr libs inProgress "map" env' arrExpr
    traverse (\item -> evalTemplate libs inProgress (Map.insert bindName (VJson item) env') body) items
  evalChild env' tn = Array.singleton <$> evalTemplate libs inProgress env' tn
