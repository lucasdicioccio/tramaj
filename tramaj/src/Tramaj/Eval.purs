-- | Evaluates a `Tramaj.Ast` `Program` against an input context, producing
-- | either a `Tramaj.Node` document or an ordinary JSON value.
-- |
-- | There is one evaluator. v1 had two — an expression evaluator and a
-- | template-node evaluator — because it had two ASTs; now that documents
-- | are expressions, `evalExpr` handles everything, and the only rule the
-- | document side adds is how a child value becomes children
-- | (`childNodes`).
-- |
-- | `Value` is the language's full value domain, not JSON with extras
-- | bolted on: an array or object may contain document nodes, which is what
-- | makes the JSX-children pattern — passing a fragment to a component as
-- | an ordinary parameter — work without a separate template-value
-- | category. JSON is what you get at the boundaries (`toJson`), where a
-- | node would be meaningless: an attribute value, an action payload, an
-- | element's value slot.
-- |
-- | Evaluation is eager and deterministic everywhere except `Branch`, which
-- | evaluates only the arm it selects.
-- |
-- | Kept in lockstep with `../tramaj-hs/src/Tramaj/Eval.hs`.
module Tramaj.Eval
  ( EvalError(..)
  , Output(..)
  , LibraryTable
  , evalProgram
  , builtinNames
  ) where

import Prelude

import Data.Argonaut.Core (Json, caseJson, fromArray, fromBoolean, fromNumber, fromObject, fromString, jsonNull, stringify, toArray, toBoolean, toNumber, toObject, toString)
import Data.Array as Array
import Data.Either (Either(..), note)
import Data.Foldable (foldl)
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.String (Pattern(..), stripSuffix)
import Data.String.Common (joinWith)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst, snd)
import Foreign.Object (Object)
import Foreign.Object as Object
import Tramaj.Ast (ActionAdaptation, Attribute(..), Expr(..), ParamValue(..), Program, adaptKey, programRoot, unlets)
import Tramaj.Node (Node(..), NodeAttribute(..), mapActions, noAnnotations)

data EvalError
  = UnboundName String
  | PathNotFound (Array String)
  | TypeMismatch String
  | UnknownLibrary String
  | ImportCycle String
  -- | `a <> b` where the two sides are not the same concatenable type.
  | ConcatMismatch String String

derive instance eqEvalError :: Eq EvalError

instance showEvalError :: Show EvalError where
  show (UnboundName name) = "UnboundName " <> show name
  show (PathNotFound segs) = "PathNotFound " <> show segs
  show (TypeMismatch msg) = "TypeMismatch " <> show msg
  show (UnknownLibrary name) = "UnknownLibrary " <> show name
  show (ImportCycle name) = "ImportCycle " <> show name
  show (ConcatMismatch l r) = "ConcatMismatch " <> show l <> " " <> show r

-- | What a program produced. Which one it is follows from the value the
-- | root actually evaluated to, not from how the root was written: a
-- | program whose root is `$header` yields a document if that binding holds
-- | one.
data Output
  = ONode Node
  | OValue Json

derive instance eqOutput :: Eq Output

instance showOutput :: Show Output where
  show (ONode n) = "ONode (" <> show n <> ")"
  show (OValue v) = "OValue " <> stringify v

-- | Host-supplied library store. Where a library came from — a file, an
-- | embedded string, a fetch — is entirely the host's business; the
-- | evaluator only ever sees an already-parsed `Program`.
type LibraryTable = Map String Program

-- | The language's value domain.
-- |
-- | `VArray`/`VObject` hold `Value`, not JSON, so a document node can
-- | travel inside a structure like any other value. `VEnv` is an import's
-- | `{rendered, vals}` result. `VPartial` is an import still waiting on
-- | context.
-- |
-- | There is no recursion: `Let` inserts a binding only after evaluating
-- | its right-hand side, so a closure cannot see its own name.
data Value
  = VNull
  | VBool Boolean
  | VNumber Number
  | VString String
  | VArray (Array Value)
  | VObject (Map String Value)
  | VNode Node
  | VClosure (Array String) Expr Env
  | VBuiltin String
  | VEnv Env
  | VPartial PartialImport

type Env = Map String Value

-- | An import whose parameters are not all supplied yet.
-- |
-- | `deferred` holds the parameters still wired to a completion context,
-- | with the path each reads from — declared in the source by `ctx(path)`,
-- | never inferred. `queued` holds adaptations applied to the partial
-- | before it was completed; they run once completion actually produces
-- | something with actions in it.
newtype PartialImport = PartialImport
  { name :: String
  , resolved :: Array (Tuple String Value)
  , deferred :: Array (Tuple String (Array String))
  , queued :: Array (Tuple ActionAdaptation (Maybe Value))
  }

-- Entry points ---------------------------------------------------------------

evalProgram :: LibraryTable -> Json -> Program -> Either EvalError Output
evalProgram libs input prog = do
  v <- evalExprWith libs (fromJson input) (programRoot prog)
  case v of
    VNode n -> Right (ONode n)
    other -> OValue <$> toJson other

-- | Evaluates one expression against a context value, with the builtins in
-- | scope — the shared path `evalProgram` and library evaluation both take.
evalExprWith :: LibraryTable -> Value -> Expr -> Either EvalError Value
evalExprWith libs ctx = evalExpr libs Map.empty (initialEnv ctx)

initialEnv :: Value -> Env
initialEnv ctx =
  Map.insert "ctx" ctx (Map.fromFoldable (map (\n -> Tuple n (VBuiltin n)) builtinNames))

-- | The fixed builtin vocabulary. Builtins are ordinary values in the
-- | initial environment rather than a separate call form, so
-- | `cardinality($xs)`, `$f($x)` and `map($xs, $not)` all go through
-- | `Call`.
builtinNames :: Array String
builtinNames =
  [ "cardinality"
  , "count"
  , "str"
  , "not"
  , "and"
  , "or"
  , "eq"
  , "lt"
  , "lte"
  , "gt"
  , "gte"
  , "has"
  , "lookup"
  , "concat"
  , "append"
  ]

-- | The set of libraries already being evaluated on this call chain.
-- | `Map String Unit` rather than a `Set` only because that is what is
-- | already imported here.
type InProgress = Map String Unit

-- Core evaluation ------------------------------------------------------------

evalExpr :: LibraryTable -> InProgress -> Env -> Expr -> Either EvalError Value
evalExpr libs inProgress env = case _ of
  Path root fields -> case Map.lookup root env of
    Nothing -> Left (UnboundName root)
    Just v -> walkFields (Array.cons root fields) v fields

  FieldAccess target fields -> do
    v <- evalExpr libs inProgress env target
    walkFields fields v fields

  Call fnExpr argExprs -> do
    fnVal <- evalExpr libs inProgress env fnExpr
    argVals <- traverse (evalExpr libs inProgress env) argExprs
    applyValue libs inProgress (describeCallee fnExpr) fnVal argVals

  Lambda params body -> Right (VClosure params body env)

  Let name valueExpr body -> do
    v <- evalExpr libs inProgress env valueExpr
    evalExpr libs inProgress (Map.insert name v env) body

  StringLit s -> Right (VString s)
  NumberLit n -> Right (VNumber n)
  BoolLit b -> Right (VBool b)
  NullLit -> Right VNull

  ArrayLit elems -> VArray <$> traverse (evalExpr libs inProgress env) elems

  ObjectLit entries ->
    VObject <<< Map.fromFoldable
      <$> traverse (\(Tuple k e) -> Tuple k <$> evalExpr libs inProgress env e) entries

  Element tag attrs valueExpr children -> do
    attrs' <- traverse (evalAttribute libs inProgress env) attrs
    value <- evalExpr libs inProgress env valueExpr >>= toJson
    children' <- evalChildren libs inProgress env children
    pure (VNode (NElement tag attrs' value children' noAnnotations))

  Fragment children ->
    (\ns -> VNode (NFragment ns noAnnotations)) <$> evalChildren libs inProgress env children

  -- The one non-eager form in the language: the arm not selected is never
  -- evaluated, so an error inside it never surfaces.
  Branch condExpr thenExpr elseExpr -> do
    cond <- evalExpr libs inProgress env condExpr >>= requireBool "a branch condition"
    evalExpr libs inProgress env (if cond then thenExpr else elseExpr)

  Map collExpr fnExpr -> do
    items <- evalCollection libs inProgress env "map" collExpr
    fnVal <- evalExpr libs inProgress env fnExpr
    VArray <$> traverse (\item -> applyValue libs inProgress "map" fnVal [ item ]) items

  Filter collExpr fnExpr -> do
    items <- evalCollection libs inProgress env "filter" collExpr
    fnVal <- evalExpr libs inProgress env fnExpr
    kept <- traverse
      (\item -> Tuple item <$> (applyValue libs inProgress "filter" fnVal [ item ] >>= requireBool "a filter predicate"))
      items
    pure (VArray (map fst (Array.filter snd kept)))

  Scan collExpr initExpr fnExpr -> do
    items <- evalCollection libs inProgress env "scan" collExpr
    acc0 <- evalExpr libs inProgress env initExpr
    fnVal <- evalExpr libs inProgress env fnExpr
    VArray <$> scanSteps libs inProgress fnVal acc0 items

  Fold collExpr initExpr fnExpr -> do
    items <- evalCollection libs inProgress env "fold" collExpr
    acc0 <- evalExpr libs inProgress env initExpr
    fnVal <- evalExpr libs inProgress env fnExpr
    foldSteps libs inProgress fnVal acc0 items

  Concat leftExpr rightExpr -> do
    l <- evalExpr libs inProgress env leftExpr
    r <- evalExpr libs inProgress env rightExpr
    concatValues l r

  Import name params -> do
    resolved <- traverse (resolveParam libs inProgress env) params
    let
      deferred = Array.mapMaybe deferredParam params
    completeOrSuspend libs inProgress
      ( PartialImport
          { name
          , resolved: Array.mapMaybe suppliedParam resolved
          , deferred
          , queued: []
          }
      )

  AdaptActions targetExpr adaptation fnExpr -> do
    target <- evalExpr libs inProgress env targetExpr
    fnVal <- traverse (evalExpr libs inProgress env) fnExpr
    adaptValue libs inProgress adaptation fnVal target

resolveParam
  :: LibraryTable
  -> InProgress
  -> Env
  -> Tuple String ParamValue
  -> Either EvalError (Tuple String (Maybe Value))
resolveParam libs inProgress env (Tuple k (PExpr e)) =
  Tuple k <<< Just <$> evalExpr libs inProgress env e
resolveParam _ _ _ (Tuple k (PFromContext _)) = Right (Tuple k Nothing)

suppliedParam :: Tuple String (Maybe Value) -> Maybe (Tuple String Value)
suppliedParam (Tuple k (Just v)) = Just (Tuple k v)
suppliedParam _ = Nothing

deferredParam :: Tuple String ParamValue -> Maybe (Tuple String (Array String))
deferredParam (Tuple k (PFromContext path)) = Just (Tuple k path)
deferredParam _ = Nothing

-- | Only for error messages: what the source called, as written.
describeCallee :: Expr -> String
describeCallee (Path root fields) = Array.intercalate "." (Array.cons root fields)
describeCallee _ = "a call"

-- Documents -------------------------------------------------------------------

evalAttribute :: LibraryTable -> InProgress -> Env -> Attribute -> Either EvalError NodeAttribute
evalAttribute libs inProgress env (Attr name e) =
  NAttr name <$> (evalExpr libs inProgress env e >>= toJson)
evalAttribute libs inProgress env (ActionAttr event key payloadExpr) =
  NAction event key <$> (evalExpr libs inProgress env payloadExpr >>= toJson)

evalChildren :: LibraryTable -> InProgress -> Env -> Array Expr -> Either EvalError (Array Node)
evalChildren libs inProgress env children =
  Array.concat <$> traverse (\e -> evalExpr libs inProgress env e >>= childNodes) children

-- | How a value becomes children. A node is itself one child; an array
-- | contributes each of its elements, which is how `map(...)` produces
-- | repeated siblings without a document-specific map form; anything else
-- | becomes a text node carrying that value unconverted, so a number child
-- | stays a number.
-- |
-- | A closure or an unfinished import has no rendering, and `toJson` says
-- | so.
childNodes :: Value -> Either EvalError (Array Node)
childNodes (VNode n) = Right [ n ]
childNodes (VArray xs) = Array.concat <$> traverse childNodes xs
childNodes v = (\j -> [ NText j noAnnotations ]) <$> toJson v

-- Application ------------------------------------------------------------------

applyValue :: LibraryTable -> InProgress -> String -> Value -> Array Value -> Either EvalError Value
applyValue libs inProgress who fnVal args = case fnVal of
  VClosure params body closureEnv ->
    if Array.length params /= Array.length args then
      Left
        ( TypeMismatch
            ( "closure expects " <> show (Array.length params) <> " argument(s), got "
                <> show (Array.length args)
            )
        )
    else
      evalExpr libs inProgress
        (foldl (\e (Tuple p v) -> Map.insert p v e) closureEnv (Array.zip params args))
        body

  VBuiltin name -> evalBuiltin name args

  -- Completing an import: each still-deferred parameter reads its declared
  -- path out of the supplied context. Ones the context does not carry stay
  -- deferred, so a partial can be completed progressively rather than all
  -- at once.
  VPartial (PartialImport p) -> case args of
    [ ctxVal ] ->
      let
        split = resolveDeferred ctxVal p.deferred
      in
        completeOrSuspend libs inProgress
          (PartialImport (p { resolved = p.resolved <> split.resolved, deferred = split.deferred }))
    _ ->
      Left
        ( TypeMismatch
            ( who <> ": completing the partial import of " <> show p.name
                <> " expects exactly 1 argument, the completion context"
            )
        )

  v -> Left (TypeMismatch (who <> " is not callable: " <> describeValue v))

-- | `scan`'s output is `[init, f(init, x1), f(f(init, x1), x2), ...]` —
-- | `scanl`, not `scanl1`.
scanSteps :: LibraryTable -> InProgress -> Value -> Value -> Array Value -> Either EvalError (Array Value)
scanSteps libs inProgress fnVal acc items = case Array.uncons items of
  Nothing -> Right [ acc ]
  Just { head, tail } -> do
    next <- applyValue libs inProgress "scan" fnVal [ acc, head ]
    Array.cons acc <$> scanSteps libs inProgress fnVal next tail

-- | The same steps as `scanSteps`, keeping only the final accumulator.
foldSteps :: LibraryTable -> InProgress -> Value -> Value -> Array Value -> Either EvalError Value
foldSteps libs inProgress fnVal acc items = case Array.uncons items of
  Nothing -> Right acc
  Just { head, tail } -> do
    next <- applyValue libs inProgress "fold" fnVal [ acc, head ]
    foldSteps libs inProgress fnVal next tail

evalCollection :: LibraryTable -> InProgress -> Env -> String -> Expr -> Either EvalError (Array Value)
evalCollection libs inProgress env who e = do
  v <- evalExpr libs inProgress env e
  case v of
    VArray xs -> Right xs
    other -> Left (TypeMismatch (who <> " expects an array as its first argument, got " <> describeValue other))

-- Concat -------------------------------------------------------------------------

-- | The monoid operation over the three types that have one. Mixed types
-- | are an error rather than a coercion, and objects merge right-biased.
concatValues :: Value -> Value -> Either EvalError Value
concatValues (VString a) (VString b) = Right (VString (a <> b))
concatValues (VArray a) (VArray b) = Right (VArray (a <> b))
concatValues (VObject a) (VObject b) = Right (VObject (Map.union b a))
concatValues l r = Left (ConcatMismatch (describeValue l) (describeValue r))

-- Imports --------------------------------------------------------------------------

-- | Runs an import if every parameter is supplied, and suspends it if any
-- | is still wired to a completion context.
-- |
-- | Partiality is decided here, by looking at the parameter list — never by
-- | running the library and interpreting a failure, which is how v1 decided
-- | it.
completeOrSuspend :: LibraryTable -> InProgress -> PartialImport -> Either EvalError Value
completeOrSuspend libs inProgress partial@(PartialImport p) =
  if not (Array.null p.deferred) then Right (VPartial partial)
  else do
    result <- runLibrary libs inProgress p.name (VObject (Map.fromFoldable p.resolved))
    applyQueued libs inProgress p.queued result

-- | Reads each deferred parameter's declared path out of a completion
-- | context, keeping the ones that context does not carry deferred.
resolveDeferred
  :: Value
  -> Array (Tuple String (Array String))
  -> { resolved :: Array (Tuple String Value), deferred :: Array (Tuple String (Array String)) }
resolveDeferred ctxVal = foldl step { resolved: [], deferred: [] }
  where
  step acc (Tuple name path) = case lookupPath ctxVal path of
    Just v -> acc { resolved = Array.snoc acc.resolved (Tuple name v) }
    Nothing -> acc { deferred = Array.snoc acc.deferred (Tuple name path) }

-- | A total path lookup: absence is an answer here, not an error, because a
-- | context that lacks a path just leaves that parameter deferred.
lookupPath :: Value -> Array String -> Maybe Value
lookupPath v path = case Array.uncons path of
  Nothing -> Just v
  Just { head, tail } -> case v of
    VObject o -> Map.lookup head o >>= \v' -> lookupPath v' tail
    VEnv e -> Map.lookup head e >>= \v' -> lookupPath v' tail
    _ -> Nothing

-- | Evaluates a library against its own fresh `$ctx` — the parameters it
-- | was given — and exposes `{rendered, vals}`. `inProgress` carries the
-- | libraries already being evaluated on this chain, so re-entering one is
-- | reported as a cycle instead of running forever.
runLibrary :: LibraryTable -> InProgress -> String -> Value -> Either EvalError Value
runLibrary libs inProgress name ctxVal =
  if isJust (Map.lookup name inProgress) then Left (ImportCycle name)
  else do
    prog <- note (UnknownLibrary name) (Map.lookup name libs)
    let
      inProgress' = Map.insert name unit inProgress
      peeled = unlets (programRoot prog)
    libEnv <- foldM (bindStep inProgress') (initialEnv ctxVal) peeled.bindings
    rendered <- evalExpr libs inProgress' libEnv peeled.root
    let
      vals = Array.mapMaybe (\(Tuple n _) -> Tuple n <$> Map.lookup n libEnv) peeled.bindings
    pure (VEnv (Map.fromFoldable [ Tuple "rendered" rendered, Tuple "vals" (VEnv (Map.fromFoldable vals)) ]))
  where
  bindStep inProgress' env (Tuple n e) = do
    v <- evalExpr libs inProgress' env e
    pure (Map.insert n v env)

-- | `Data.Foldable.foldM` specialised to `Either`, over an array — spelled
-- | out rather than imported so the error short-circuits in the obvious
-- | place.
foldM :: forall a b. (b -> a -> Either EvalError b) -> b -> Array a -> Either EvalError b
foldM f acc xs = case Array.uncons xs of
  Nothing -> Right acc
  Just { head, tail } -> f acc head >>= \acc' -> foldM f acc' tail

-- Action adaptation -------------------------------------------------------------------

-- | Applies an adaptation everywhere it can reach: through a node's whole
-- | tree, through every value of an import result (not just `rendered`),
-- | and through arrays. A partial import has no actions yet, so the
-- | adaptation is queued and runs when the import is completed. Anything
-- | else has no actions and passes through untouched.
adaptValue :: LibraryTable -> InProgress -> ActionAdaptation -> Maybe Value -> Value -> Either EvalError Value
adaptValue libs inProgress adaptation fnVal = go
  where
  go (VNode n) = VNode <$> mapActions (adaptAction libs inProgress adaptation fnVal) n
  go (VEnv e) = VEnv <$> traverse go e
  go (VArray xs) = VArray <$> traverse go xs
  go (VObject o) = VObject <$> traverse go o
  go (VPartial (PartialImport p)) =
    Right (VPartial (PartialImport (p { queued = Array.snoc p.queued (Tuple adaptation fnVal) })))
  go v = Right v

applyQueued
  :: LibraryTable
  -> InProgress
  -> Array (Tuple ActionAdaptation (Maybe Value))
  -> Value
  -> Either EvalError Value
applyQueued libs inProgress queued v0 =
  foldM (\v (Tuple adaptation fnVal) -> adaptValue libs inProgress adaptation fnVal v) v0 queued

-- | One action, adapted. The key is rewritten first, unconditionally, by
-- | the static adaptation; the optional closure then sees the
-- | already-adapted action and may change only its event type and payload.
-- | A `key` in the closure's result is ignored — letting it win would put
-- | the action vocabulary back beyond static reach, which is the whole
-- | point of restricting adaptation.
adaptAction
  :: LibraryTable
  -> InProgress
  -> ActionAdaptation
  -> Maybe Value
  -> String
  -> String
  -> Json
  -> Either EvalError NodeAttribute
adaptAction libs inProgress adaptation fnVal event key payload = case fnVal of
  Nothing -> Right (NAction event key' payload)
  Just fn -> do
    result <- applyValue libs inProgress "adapt-actions" fn [ actionAsValue ] >>= toJson
    fields <- note
      (TypeMismatch "adapt-actions: the function must return an object with an eventType field")
      (toObject result)
    event' <- note
      (TypeMismatch "adapt-actions: the function's result needs a string \"eventType\" field")
      (Object.lookup "eventType" fields >>= toString)
    let
      payload' = fromMaybe jsonNull (Object.lookup "payload" fields)
    Right (NAction event' key' payload')
  where
  key' = adaptKey adaptation key

  actionAsValue =
    VObject
      ( Map.fromFoldable
          [ Tuple "eventType" (VString event)
          , Tuple "key" (VString key')
          , Tuple "payload" (fromJson payload)
          ]
      )

-- Paths and fields -----------------------------------------------------------------------

-- | Walks named segments into a value. `context` is the full path as
-- | written, for error messages only.
walkFields :: Array String -> Value -> Array String -> Either EvalError Value
walkFields context v fields = case Array.uncons fields of
  Nothing -> Right v
  Just { head, tail } -> case v of
    VObject o -> case Map.lookup head o of
      Nothing -> Left (PathNotFound context)
      Just v' -> walkFields context v' tail
    VEnv e -> case Map.lookup head e of
      Nothing -> Left (PathNotFound context)
      Just v' -> walkFields context v' tail
    other ->
      Left
        ( TypeMismatch
            ( "cannot read field " <> show head <> " of " <> describeValue other <> " in path "
                <> show (Array.intercalate "." context)
            )
        )

-- Conversion ------------------------------------------------------------------------------

-- | Down to JSON, at the boundaries where only JSON is meaningful: an
-- | attribute value, an action payload, an element's value slot, an
-- | expression program's result.
-- |
-- | The values that cannot cross say why. A node is deliberately included:
-- | documents nest as children, not as attribute values, and silently
-- | serializing one here would hide a mistake rather than report it.
toJson :: Value -> Either EvalError Json
toJson VNull = Right jsonNull
toJson (VBool b) = Right (fromBoolean b)
toJson (VNumber n) = Right (fromNumber n)
toJson (VString s) = Right (fromString s)
toJson (VArray xs) = fromArray <$> traverse toJson xs
toJson (VObject o) =
  fromObject <<< Object.fromFoldable
    <$> traverse (\(Tuple k v) -> Tuple k <$> toJson v) (Map.toUnfoldable o :: Array (Tuple String Value))
toJson (VNode _) =
  Left (TypeMismatch "a document node is not a plain value -- nest it as a child rather than using it where a value is expected")
toJson (VClosure _ _ _) =
  Left (TypeMismatch "expected a value, got a function -- call it first, e.g. $my-fn(...)")
toJson (VBuiltin name) =
  Left (TypeMismatch ("expected a value, got the builtin " <> show name <> " -- call it first"))
toJson (VEnv _) =
  Left (TypeMismatch "expected a value, got an import result -- read .rendered, .vals, or a binding name from it first")
toJson (VPartial (PartialImport p)) =
  Left
    ( TypeMismatch
        ( "expected a value, got the import of " <> show p.name <> " still waiting on "
            <> show (map fst p.deferred)
            <> " -- complete it first"
        )
    )

fromJson :: Json -> Value
fromJson j =
  case toString j of
    Just s -> VString s
    Nothing -> case toNumber j of
      Just n -> VNumber n
      Nothing -> case toBoolean j of
        Just b -> VBool b
        Nothing -> case toArray j of
          Just xs -> VArray (map fromJson xs)
          Nothing -> case toObject j of
            Just o -> VObject (Map.fromFoldable (map (\(Tuple k v) -> Tuple k (fromJson v)) (Object.toUnfoldable o :: Array (Tuple String Json))))
            Nothing -> VNull

describeValue :: Value -> String
describeValue VNull = "null"
describeValue (VBool _) = "a boolean"
describeValue (VNumber _) = "a number"
describeValue (VString _) = "a string"
describeValue (VArray _) = "an array"
describeValue (VObject _) = "an object"
describeValue (VNode _) = "a document node"
describeValue (VClosure _ _ _) = "a function"
describeValue (VBuiltin name) = "the builtin " <> show name
describeValue (VEnv _) = "an import result"
describeValue (VPartial (PartialImport p)) = "an incomplete import of " <> show p.name

requireBool :: String -> Value -> Either EvalError Boolean
requireBool _ (VBool b) = Right b
requireBool who other = Left (TypeMismatch (who <> " must be a boolean, got " <> describeValue other))

-- Builtins ------------------------------------------------------------------------------------

-- | A fixed vocabulary, grown only on real demand. `branch` is absent
-- | deliberately: it has to leave an arm unevaluated, which no builtin can
-- | do, so it is a core constructor instead.
evalBuiltin :: String -> Array Value -> Either EvalError Value
evalBuiltin name args = case name of
  "cardinality" -> cardinality
  "count" -> cardinality
  "str" -> arity1 (\v -> VString <<< displayString <$> toJson v)
  "not" -> arity1 (\v -> VBool <<< not <$> asBool v)
  "and" -> variadicBool (&&) true
  "or" -> variadicBool (||) false
  "eq" -> binary (\a b -> (\ja jb -> VBool (ja == jb)) <$> toJson a <*> toJson b)
  "lt" -> comparison (<)
  "lte" -> comparison (<=)
  "gt" -> comparison (>)
  "gte" -> comparison (>=)
  "has" -> binary hasImpl
  "lookup" -> ternary lookupImpl
  "concat" -> concatImpl
  "append" -> binary appendImpl
  _ -> Left (UnboundName name)
  where
  arity1 :: forall a. (Value -> Either EvalError a) -> Either EvalError a
  arity1 f = case args of
    [ a ] -> f a
    _ -> Left (TypeMismatch (name <> " expects exactly 1 argument, got " <> show (Array.length args)))

  binary :: (Value -> Value -> Either EvalError Value) -> Either EvalError Value
  binary f = case args of
    [ a, b ] -> f a b
    _ -> Left (TypeMismatch (name <> " expects exactly 2 arguments, got " <> show (Array.length args)))

  ternary :: (Value -> Value -> Value -> Either EvalError Value) -> Either EvalError Value
  ternary f = case args of
    [ a, b, c ] -> f a b c
    _ -> Left (TypeMismatch (name <> " expects exactly 3 arguments, got " <> show (Array.length args)))

  cardinality :: Either EvalError Value
  cardinality = arity1 case _ of
    VArray xs -> Right (VNumber (Int.toNumber (Array.length xs)))
    VObject o -> Right (VNumber (Int.toNumber (Map.size o)))
    other -> Left (TypeMismatch (name <> " expects an array or object, got " <> describeValue other))

  asBool :: Value -> Either EvalError Boolean
  asBool (VBool b) = Right b
  asBool other = Left (TypeMismatch (name <> " expects a boolean argument, got " <> describeValue other))

  asNumber :: Value -> Either EvalError Number
  asNumber (VNumber n) = Right n
  asNumber other = Left (TypeMismatch (name <> " expects a number argument, got " <> describeValue other))

  asArray :: Value -> Either EvalError (Array Value)
  asArray (VArray xs) = Right xs
  asArray other = Left (TypeMismatch (name <> " expects an array argument, got " <> describeValue other))

  -- | `and`/`or` fold over however many arguments they are given, zero
  -- | included (vacuously), rather than fixing an arity.
  variadicBool :: (Boolean -> Boolean -> Boolean) -> Boolean -> Either EvalError Value
  variadicBool op identityVal = VBool <<< foldl op identityVal <$> traverse asBool args

  comparison :: (Number -> Number -> Boolean) -> Either EvalError Value
  comparison op = binary \a b -> (\na nb -> VBool (op na nb)) <$> asNumber a <*> asNumber b

  -- | Deliberately tolerant: a missing key, an out-of-range index, or a
  -- | container of the wrong shape all answer `false` rather than erroring.
  hasImpl :: Value -> Value -> Either EvalError Value
  hasImpl container key = Right (VBool present)
    where
    present = case container, key of
      VObject o, VString k -> isJust (Map.lookup k o)
      VArray xs, VNumber n -> maybe false (\i -> isJust (Array.index xs i)) (asIndex n)
      _, _ -> false

  -- | Dynamic access by a computed key or index — the counterpart to a
  -- | static path segment. The third argument is the mandatory fallback.
  lookupImpl :: Value -> Value -> Value -> Either EvalError Value
  lookupImpl container key fallback = Right case container, key of
    VObject o, VString k -> fromMaybe fallback (Map.lookup k o)
    VArray xs, VNumber n -> fromMaybe fallback (asIndex n >>= Array.index xs)
    _, _ -> fallback

  -- | An index must be a non-negative whole number: `2.5` and `-1` are not
  -- | indices.
  asIndex :: Number -> Maybe Int
  asIndex n = case Int.fromNumber n of
    Just i | i >= 0 -> Just i
    _ -> Nothing

  -- | Variadic array join, preserving order. `concat()` is `[]`; a
  -- | non-array argument anywhere is an error rather than being wrapped.
  concatImpl :: Either EvalError Value
  concatImpl = VArray <<< Array.concat <$> traverse asArray args

  -- | `append(arr, item)` adds one element at the end. An array item is
  -- | appended as a single element, not spliced — `concat` splices.
  appendImpl :: Value -> Value -> Either EvalError Value
  appendImpl arr item = (\xs -> VArray (Array.snoc xs item)) <$> asArray arr

-- | How a value reads when it is rendered into a string by `str` (and so by
-- | string interpolation): a string is itself, `null` is empty, and
-- | anything structured is compact JSON.
-- |
-- | This is a normative rendering, not a debugging one, so it must agree
-- | across implementations character for character — it is what a template
-- | interpolates into its output. See `specs/reference.md`.
displayString :: Json -> String
displayString j =
  caseJson
    (const "")
    (\b -> if b then "true" else "false")
    formatNumber
    identity
    compactArray
    compactObject
    j

-- | Compact JSON, with object keys in sorted order and numbers formatted by
-- | `formatNumber`.
-- |
-- | Deliberately not argonaut's own `stringify` for the whole value: that
-- | would leave object keys in whatever order the underlying object happens
-- | to hold them, and key order is not semantically significant — so it must
-- | not be observable through `str` either.
compactJson :: Json -> String
compactJson j =
  caseJson
    (const "null")
    (\b -> if b then "true" else "false")
    formatNumber
    quoteString
    compactArray
    compactObject
    j

compactArray :: Array Json -> String
compactArray xs = "[" <> joinWith "," (map compactJson xs) <> "]"

compactObject :: Object Json -> String
compactObject o = "{" <> joinWith "," (map entry sorted) <> "}"
  where
  sorted = Array.sortWith fst (Object.toUnfoldable o :: Array (Tuple String Json))
  entry (Tuple k v) = quoteString k <> ":" <> compactJson v

-- | A JSON string literal, escaped by argonaut itself so this does not grow
-- | a second, subtly different escaping table.
quoteString :: String -> String
quoteString = stringify <<< fromString

-- | A number as ECMAScript's `Number::toString` renders it — which is what
-- | PureScript's own `show` gives, except that `show` appends `.0` to a
-- | value with no fractional part. Stripping that suffix undoes exactly
-- | that: `Number::toString` never produces a trailing `.0` itself.
-- |
-- | v1 tested integrality with `Int.fromNumber`, which quietly failed above
-- | 2^31 and rendered `100000000000` as `100000000000.0`.
formatNumber :: Number -> String
formatNumber n = fromMaybe shown (stripSuffix (Pattern ".0") shown)
  where
  shown = show n
