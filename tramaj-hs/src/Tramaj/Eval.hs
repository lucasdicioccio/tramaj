-- | Evaluates a "Tramaj.Ast" 'Program' against an input context, producing
-- either a "Tramaj.Node" document or an ordinary JSON value.
--
-- There is one evaluator. v1 had two -- an expression evaluator and a
-- template-node evaluator -- because it had two ASTs; now that documents are
-- expressions, 'evalExpr' handles everything, and the only rule the document
-- side adds is how a child value becomes children ('childNodes').
--
-- 'Value'' is the language's full value domain, not JSON with extras bolted
-- on: an array or object may contain document nodes, which is what makes the
-- JSX-children pattern -- passing a fragment to a component as an ordinary
-- parameter -- work without a separate template-value category. JSON is what
-- you get at the boundaries ('toJson'), where a node would be meaningless: an
-- attribute value, an action payload, an element's value slot.
--
-- Evaluation is eager and deterministic everywhere except 'Branch', which
-- evaluates only the arm it selects.
module Tramaj.Eval
  ( EvalError (..)
  , Output (..)
  , LibraryTable
  , evalProgram
  , evalExprWith
  , builtinNames
  ) where

import Data.Aeson (Value (..), encode)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Char (intToDigit)
import Data.List (foldl', sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Scientific (Scientific, toRealFloat)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import qualified Data.Vector as V
import Numeric (floatToDigits)
import Tramaj.Ast
import Tramaj.Node

data EvalError
  = UnboundName Text
  | PathNotFound [Text]
  | TypeMismatch Text
  | UnknownLibrary Text
  | ImportCycle Text
  | -- | @a \<\> b@ where the two sides are not the same concatenable type.
    ConcatMismatch Text Text
  deriving stock (Eq, Show)

-- | What a program produced. Which one it is follows from the value the root
-- actually evaluated to, not from how the root was written: a program whose
-- root is @$header@ yields a document if that binding holds one.
data Output
  = ONode Node
  | OValue Value
  deriving stock (Eq, Show)

-- | Host-supplied library store. Where a library came from -- a file, an
-- embedded string, a fetch -- is entirely the host's business; the evaluator
-- only ever sees an already-parsed 'Program'.
type LibraryTable = Map Text Program

-- | The language's value domain.
--
-- 'VArray'\/'VObject' hold 'Value'', not JSON, so a document node can travel
-- inside a structure like any other value. 'VEnv' is an import's
-- @{rendered, vals}@ result. 'VPartial' is an import still waiting on context.
--
-- There is no recursion: 'Let' inserts a binding only after evaluating its
-- right-hand side, so a closure cannot see its own name.
data Value'
  = VNull
  | VBool Bool
  | VNumber Scientific
  | VString Text
  | VArray [Value']
  | VObject (Map Text Value')
  | VNode' Node
  | VClosure [Text] Expr Env
  | VBuiltin Text
  | VEnv Env
  | VPartial Partial

type Env = Map Text Value'

-- | An import whose parameters are not all supplied yet.
--
-- @pDeferred@ holds the parameters still wired to a completion context, with
-- the path each reads from -- declared in the source by @ctx(path)@, never
-- inferred. @pQueued@ holds adaptations applied to the partial before it was
-- completed; they run once completion actually produces something with
-- actions in it.
data Partial = Partial
  { pName :: Text
  , pResolved :: [(Text, Value')]
  , pDeferred :: [(Text, [Text])]
  , pQueued :: [(ActionAdaptation, Maybe Value')]
  }

-- Entry points ---------------------------------------------------------------

evalProgram :: LibraryTable -> Value -> Program -> Either EvalError Output
evalProgram libs input prog = do
  v <- evalExprWith libs (fromJson input) (programRoot prog)
  case v of
    VNode' n -> Right (ONode n)
    other -> OValue <$> toJson other

-- | Evaluates one expression against a context value, with the builtins in
-- scope -- the shared path 'evalProgram' and library evaluation both take.
evalExprWith :: LibraryTable -> Value' -> Expr -> Either EvalError Value'
evalExprWith libs ctx = evalExpr libs Set.empty (initialEnv ctx)

initialEnv :: Value' -> Env
initialEnv ctx = Map.insert "ctx" ctx (Map.fromList [(n, VBuiltin n) | n <- builtinNames])

-- | The fixed builtin vocabulary. Builtins are ordinary values in the initial
-- environment rather than a separate call form, so @cardinality($xs)@,
-- @$f($x)@ and @map($xs, $not)@ all go through 'Call'.
builtinNames :: [Text]
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

-- Core evaluation ------------------------------------------------------------

evalExpr :: LibraryTable -> Set Text -> Env -> Expr -> Either EvalError Value'
evalExpr _ _ env (Path root fields) = case Map.lookup root env of
  Nothing -> Left (UnboundName root)
  Just v -> walkFields (root : fields) v fields
evalExpr libs inProgress env (FieldAccess target fields) = do
  v <- evalExpr libs inProgress env target
  walkFields fields v fields
evalExpr libs inProgress env (Call fnExpr argExprs) = do
  fnVal <- evalExpr libs inProgress env fnExpr
  argVals <- traverse (evalExpr libs inProgress env) argExprs
  apply libs inProgress (describeCallee fnExpr) fnVal argVals
evalExpr _ _ env (Lambda params body) = Right (VClosure params body env)
evalExpr libs inProgress env (Let name valueExpr body) = do
  v <- evalExpr libs inProgress env valueExpr
  evalExpr libs inProgress (Map.insert name v env) body
evalExpr _ _ _ (StringLit s) = Right (VString s)
evalExpr _ _ _ (NumberLit n) = Right (VNumber (realToFrac n))
evalExpr _ _ _ (BoolLit b) = Right (VBool b)
evalExpr _ _ _ NullLit = Right VNull
evalExpr libs inProgress env (ArrayLit elems) =
  VArray <$> traverse (evalExpr libs inProgress env) elems
evalExpr libs inProgress env (ObjectLit entries) =
  VObject . Map.fromList <$> traverse (\(k, e) -> (,) k <$> evalExpr libs inProgress env e) entries
evalExpr libs inProgress env (Element tag attrs valExpr children) = do
  attrs' <- traverse (evalAttribute libs inProgress env) attrs
  val <- evalExpr libs inProgress env valExpr >>= toJson
  children' <- evalChildren libs inProgress env children
  pure (VNode' (NElement tag attrs' val children' noAnnotations))
evalExpr libs inProgress env (Fragment children) =
  VNode' . flip NFragment noAnnotations <$> evalChildren libs inProgress env children
-- | The one non-eager form in the language: the arm not selected is never
-- evaluated, so an error inside it never surfaces.
evalExpr libs inProgress env (Branch condExpr thenExpr elseExpr) = do
  cond <- evalExpr libs inProgress env condExpr >>= requireBool "a branch condition"
  evalExpr libs inProgress env (if cond then thenExpr else elseExpr)
evalExpr libs inProgress env (Map collExpr fnExpr) = do
  items <- evalCollection libs inProgress env "map" collExpr
  fnVal <- evalExpr libs inProgress env fnExpr
  VArray <$> traverse (\item -> apply libs inProgress "map" fnVal [item]) items
evalExpr libs inProgress env (Filter collExpr fnExpr) = do
  items <- evalCollection libs inProgress env "filter" collExpr
  fnVal <- evalExpr libs inProgress env fnExpr
  kept <- traverse (\item -> (,) item <$> (apply libs inProgress "filter" fnVal [item] >>= requireBool "a filter predicate")) items
  pure (VArray [item | (item, True) <- kept])
evalExpr libs inProgress env (Scan collExpr initExpr fnExpr) = do
  items <- evalCollection libs inProgress env "scan" collExpr
  acc0 <- evalExpr libs inProgress env initExpr
  fnVal <- evalExpr libs inProgress env fnExpr
  VArray <$> scanSteps libs inProgress fnVal acc0 items
evalExpr libs inProgress env (Fold collExpr initExpr fnExpr) = do
  items <- evalCollection libs inProgress env "fold" collExpr
  acc0 <- evalExpr libs inProgress env initExpr
  fnVal <- evalExpr libs inProgress env fnExpr
  foldSteps libs inProgress fnVal acc0 items
evalExpr libs inProgress env (Concat leftExpr rightExpr) = do
  l <- evalExpr libs inProgress env leftExpr
  r <- evalExpr libs inProgress env rightExpr
  concatValues l r
evalExpr libs inProgress env (Import name params) = do
  resolved <- traverse resolveParam params
  let deferred = [(k, path) | (k, PFromContext path) <- params]
  completeOrSuspend libs inProgress (Partial name [(k, v) | (k, Just v) <- resolved] deferred [])
  where
    resolveParam (k, PExpr e) = (,) k . Just <$> evalExpr libs inProgress env e
    resolveParam (k, PFromContext _) = Right (k, Nothing)
evalExpr libs inProgress env (AdaptActions targetExpr adaptation fnExpr) = do
  target <- evalExpr libs inProgress env targetExpr
  fnVal <- traverse (evalExpr libs inProgress env) fnExpr
  adaptValue libs inProgress adaptation fnVal target

-- | Only for error messages: what the source called, as written.
describeCallee :: Expr -> Text
describeCallee (Path root fields) = T.intercalate "." (root : fields)
describeCallee _ = "a call"

-- Documents -------------------------------------------------------------------

evalAttribute :: LibraryTable -> Set Text -> Env -> Attribute -> Either EvalError NodeAttribute
evalAttribute libs inProgress env (Attr name e) = NAttr name <$> (evalExpr libs inProgress env e >>= toJson)
evalAttribute libs inProgress env (ActionAttr event key payloadExpr) =
  NAction event key <$> (evalExpr libs inProgress env payloadExpr >>= toJson)

evalChildren :: LibraryTable -> Set Text -> Env -> [Expr] -> Either EvalError [Node]
evalChildren libs inProgress env children =
  concat <$> traverse (\e -> evalExpr libs inProgress env e >>= childNodes) children

-- | How a value becomes children. A node is itself one child; an array
-- contributes each of its elements, which is how @map(...)@ produces repeated
-- siblings without a document-specific map form; anything else becomes a text
-- node carrying that value unconverted, so a number child stays a number.
--
-- A closure or an unfinished import has no rendering, and 'toJson' says so.
childNodes :: Value' -> Either EvalError [Node]
childNodes (VNode' n) = Right [n]
childNodes (VArray xs) = concat <$> traverse childNodes xs
childNodes v = (\j -> [NText j noAnnotations]) <$> toJson v

-- Application ------------------------------------------------------------------

apply :: LibraryTable -> Set Text -> Text -> Value' -> [Value'] -> Either EvalError Value'
apply libs inProgress _ (VClosure params body closureEnv) args
  | length params /= length args =
      Left (TypeMismatch ("closure expects " <> tshow (length params) <> " argument(s), got " <> tshow (length args)))
  | otherwise =
      evalExpr libs inProgress (foldl' (\e (p, v) -> Map.insert p v e) closureEnv (zip params args)) body
apply _ _ _ (VBuiltin name) args = evalBuiltin name args
-- | Completing an import: each still-deferred parameter reads its declared
-- path out of the supplied context. Ones the context does not carry stay
-- deferred, so a partial can be completed progressively rather than all at
-- once.
apply libs inProgress who (VPartial partial) args = case args of
  [ctxVal] -> do
    (nowResolved, stillDeferred) <- resolveDeferred ctxVal (pDeferred partial)
    completeOrSuspend
      libs
      inProgress
      partial {pResolved = pResolved partial <> nowResolved, pDeferred = stillDeferred}
  _ -> Left (TypeMismatch (who <> ": completing the partial import of " <> tshow (pName partial) <> " expects exactly 1 argument, the completion context"))
apply _ _ who v _ = Left (TypeMismatch (who <> " is not callable: " <> describeValue v))

-- | @scan@'s output is @[init, f(init, x1), f(f(init, x1), x2), ...]@ --
-- @scanl@, not @scanl1@.
scanSteps :: LibraryTable -> Set Text -> Value' -> Value' -> [Value'] -> Either EvalError [Value']
scanSteps _ _ _ acc [] = Right [acc]
scanSteps libs inProgress fnVal acc (item : rest) = do
  next <- apply libs inProgress "scan" fnVal [acc, item]
  (acc :) <$> scanSteps libs inProgress fnVal next rest

-- | The same steps as 'scanSteps', keeping only the final accumulator.
foldSteps :: LibraryTable -> Set Text -> Value' -> Value' -> [Value'] -> Either EvalError Value'
foldSteps _ _ _ acc [] = Right acc
foldSteps libs inProgress fnVal acc (item : rest) = do
  next <- apply libs inProgress "fold" fnVal [acc, item]
  foldSteps libs inProgress fnVal next rest

evalCollection :: LibraryTable -> Set Text -> Env -> Text -> Expr -> Either EvalError [Value']
evalCollection libs inProgress env who e =
  evalExpr libs inProgress env e >>= \case
    VArray xs -> Right xs
    other -> Left (TypeMismatch (who <> " expects an array as its first argument, got " <> describeValue other))

-- Concat -------------------------------------------------------------------------

-- | The monoid operation over the three types that have one. Mixed types are
-- an error rather than a coercion, and objects merge right-biased.
concatValues :: Value' -> Value' -> Either EvalError Value'
concatValues (VString a) (VString b) = Right (VString (a <> b))
concatValues (VArray a) (VArray b) = Right (VArray (a <> b))
concatValues (VObject a) (VObject b) = Right (VObject (Map.union b a))
concatValues l r = Left (ConcatMismatch (describeValue l) (describeValue r))

-- Imports --------------------------------------------------------------------------

-- | Runs an import if every parameter is supplied, and suspends it if any is
-- still wired to a completion context.
--
-- Partiality is decided here, by looking at the parameter list -- never by
-- running the library and interpreting a failure, which is how v1 decided it.
completeOrSuspend :: LibraryTable -> Set Text -> Partial -> Either EvalError Value'
completeOrSuspend libs inProgress partial
  | not (null (pDeferred partial)) = Right (VPartial partial)
  | otherwise = do
      result <- runLibrary libs inProgress (pName partial) (VObject (Map.fromList (pResolved partial)))
      applyQueued libs inProgress (pQueued partial) result

-- | Reads each deferred parameter's declared path out of a completion
-- context, keeping the ones that context does not carry deferred.
resolveDeferred :: Value' -> [(Text, [Text])] -> Either EvalError ([(Text, Value')], [(Text, [Text])])
resolveDeferred ctxVal = foldr step (Right ([], []))
  where
    step (name, path) acc = do
      (resolved, deferred) <- acc
      case lookupPath ctxVal path of
        Just v -> Right ((name, v) : resolved, deferred)
        Nothing -> Right (resolved, (name, path) : deferred)

-- | A total path lookup: absence is an answer here, not an error, because a
-- context that lacks a path just leaves that parameter deferred.
lookupPath :: Value' -> [Text] -> Maybe Value'
lookupPath v [] = Just v
lookupPath (VObject o) (field : rest) = Map.lookup field o >>= \v -> lookupPath v rest
lookupPath (VEnv e) (field : rest) = Map.lookup field e >>= \v -> lookupPath v rest
lookupPath _ _ = Nothing

-- | Evaluates a library against its own fresh @$ctx@ -- the parameters it was
-- given -- and exposes @{rendered, vals}@. @inProgress@ carries the libraries
-- already being evaluated on this chain, so re-entering one is reported as a
-- cycle instead of running forever.
runLibrary :: LibraryTable -> Set Text -> Text -> Value' -> Either EvalError Value'
runLibrary libs inProgress name ctxVal
  | Set.member name inProgress = Left (ImportCycle name)
  | otherwise = do
      prog <- maybe (Left (UnknownLibrary name)) Right (Map.lookup name libs)
      let inProgress' = Set.insert name inProgress
          (bindings, root) = unlets (programRoot prog)
      libEnv <- foldlEither (bindStep inProgress') (initialEnv ctxVal) bindings
      rendered <- evalExpr libs inProgress' libEnv root
      pure (VEnv (Map.fromList [("rendered", rendered), ("vals", VEnv (Map.fromList (map (\(n, _) -> (n, libEnv Map.! n)) bindings)))]))
  where
    bindStep inProgress' env (n, e) = do
      v <- evalExpr libs inProgress' env e
      pure (Map.insert n v env)

foldlEither :: (b -> a -> Either e b) -> b -> [a] -> Either e b
foldlEither f = go
  where
    go acc [] = Right acc
    go acc (x : xs) = f acc x >>= \acc' -> go acc' xs

-- Action adaptation -------------------------------------------------------------------

-- | Applies an adaptation everywhere it can reach: through a node's whole
-- tree, through every value of an import result (not just @rendered@), and
-- through arrays. A partial import has no actions yet, so the adaptation is
-- queued and runs when the import is completed. Anything else has no actions
-- and passes through untouched.
adaptValue :: LibraryTable -> Set Text -> ActionAdaptation -> Maybe Value' -> Value' -> Either EvalError Value'
adaptValue libs inProgress adaptation fnVal = go
  where
    go (VNode' n) = VNode' <$> mapActions (adaptAction libs inProgress adaptation fnVal) n
    go (VEnv e) = VEnv <$> traverse go e
    go (VArray xs) = VArray <$> traverse go xs
    go (VObject o) = VObject <$> traverse go o
    go (VPartial partial) = Right (VPartial partial {pQueued = pQueued partial <> [(adaptation, fnVal)]})
    go v = Right v

applyQueued :: LibraryTable -> Set Text -> [(ActionAdaptation, Maybe Value')] -> Value' -> Either EvalError Value'
applyQueued libs inProgress queued v0 =
  foldlEither (\v (adaptation, fnVal) -> adaptValue libs inProgress adaptation fnVal v) v0 queued

-- | One action, adapted. The key is rewritten first, unconditionally, by the
-- static adaptation; the optional closure then sees the already-adapted action
-- and may change only its event type and payload. A @key@ in the closure's
-- result is ignored -- letting it win would put the action vocabulary back
-- beyond static reach, which is the whole point of restricting adaptation.
adaptAction :: LibraryTable -> Set Text -> ActionAdaptation -> Maybe Value' -> Text -> Text -> Value -> Either EvalError NodeAttribute
adaptAction libs inProgress adaptation fnVal event key payload =
  case fnVal of
    Nothing -> Right (NAction event key' payload)
    Just fn -> do
      result <- apply libs inProgress "adapt-actions" fn [actionAsValue] >>= toJson
      case result of
        Object obj -> do
          event' <- case KeyMap.lookup (Key.fromText "eventType") obj of
            Just (String s) -> Right s
            _ -> Left (TypeMismatch "adapt-actions: the function's result needs a string \"eventType\" field")
          let payload' = maybe Null id (KeyMap.lookup (Key.fromText "payload") obj)
          Right (NAction event' key' payload')
        _ -> Left (TypeMismatch "adapt-actions: the function must return an object with an eventType field")
  where
    key' = adaptKey adaptation key
    actionAsValue =
      VObject
        (Map.fromList [("eventType", VString event), ("key", VString key'), ("payload", fromJson payload)])

-- Paths and fields -----------------------------------------------------------------------

-- | Walks named segments into a value. @context@ is the full path as written,
-- for error messages only.
walkFields :: [Text] -> Value' -> [Text] -> Either EvalError Value'
walkFields _ v [] = Right v
walkFields context v (field : rest) = case v of
  VObject o -> case Map.lookup field o of
    Nothing -> Left (PathNotFound context)
    Just v' -> walkFields context v' rest
  VEnv e -> case Map.lookup field e of
    Nothing -> Left (PathNotFound context)
    Just v' -> walkFields context v' rest
  other ->
    Left
      ( TypeMismatch
          ("cannot read field " <> tshow field <> " of " <> describeValue other <> " in path " <> tshow (T.intercalate "." context))
      )

-- Conversion ------------------------------------------------------------------------------

-- | Down to JSON, at the boundaries where only JSON is meaningful: an
-- attribute value, an action payload, an element's value slot, an expression
-- program's result.
--
-- The values that cannot cross say why. A node is deliberately included:
-- documents nest as children, not as attribute values, and silently
-- serializing one here would hide a mistake rather than report it.
toJson :: Value' -> Either EvalError Value
toJson VNull = Right Null
toJson (VBool b) = Right (Bool b)
toJson (VNumber n) = Right (Number n)
toJson (VString s) = Right (String s)
toJson (VArray xs) = Array . V.fromList <$> traverse toJson xs
toJson (VObject o) = Object . KeyMap.fromList <$> traverse (\(k, v) -> (,) (Key.fromText k) <$> toJson v) (Map.toList o)
toJson (VNode' _) = Left (TypeMismatch "a document node is not a plain value -- nest it as a child rather than using it where a value is expected")
toJson (VClosure _ _ _) = Left (TypeMismatch "expected a value, got a function -- call it first, e.g. $my-fn(...)")
toJson (VBuiltin name) = Left (TypeMismatch ("expected a value, got the builtin " <> tshow name <> " -- call it first"))
toJson (VEnv _) = Left (TypeMismatch "expected a value, got an import result -- read .rendered, .vals, or a binding name from it first")
toJson (VPartial partial) =
  Left
    ( TypeMismatch
        ( "expected a value, got the import of "
            <> tshow (pName partial)
            <> " still waiting on "
            <> tshow (map fst (pDeferred partial))
            <> " -- complete it first"
        )
    )

fromJson :: Value -> Value'
fromJson Null = VNull
fromJson (Bool b) = VBool b
fromJson (Number n) = VNumber n
fromJson (String s) = VString s
fromJson (Array arr) = VArray (map fromJson (V.toList arr))
fromJson (Object obj) = VObject (Map.fromList (map (\(k, v) -> (Key.toText k, fromJson v)) (KeyMap.toList obj)))

describeValue :: Value' -> Text
describeValue VNull = "null"
describeValue (VBool _) = "a boolean"
describeValue (VNumber _) = "a number"
describeValue (VString _) = "a string"
describeValue (VArray _) = "an array"
describeValue (VObject _) = "an object"
describeValue (VNode' _) = "a document node"
describeValue (VClosure _ _ _) = "a function"
describeValue (VBuiltin name) = "the builtin " <> tshow name
describeValue (VEnv _) = "an import result"
describeValue (VPartial partial) = "an incomplete import of " <> tshow (pName partial)

requireBool :: Text -> Value' -> Either EvalError Bool
requireBool _ (VBool b) = Right b
requireBool who other = Left (TypeMismatch (who <> " must be a boolean, got " <> describeValue other))

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- Builtins ------------------------------------------------------------------------------------

-- | A fixed vocabulary, grown only on real demand. @branch@ is absent
-- deliberately: it has to leave an arm unevaluated, which no builtin can do,
-- so it is a core constructor instead.
evalBuiltin :: Text -> [Value'] -> Either EvalError Value'
evalBuiltin name args = case name of
  "cardinality" -> cardinality
  "count" -> cardinality
  "str" -> arity1 (fmap (VString . displayString) . toJson)
  "not" -> arity1 (fmap (VBool . not) . asBool)
  "and" -> variadicBool (&&) True
  "or" -> variadicBool (||) False
  "eq" -> binary (\a b -> VBool <$> ((==) <$> toJson a <*> toJson b))
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
    arity1 :: (Value' -> Either EvalError a) -> Either EvalError a
    arity1 f = case args of
      [a] -> f a
      _ -> Left (TypeMismatch (name <> " expects exactly 1 argument, got " <> tshow (length args)))

    binary :: (Value' -> Value' -> Either EvalError Value') -> Either EvalError Value'
    binary f = case args of
      [a, b] -> f a b
      _ -> Left (TypeMismatch (name <> " expects exactly 2 arguments, got " <> tshow (length args)))

    ternary :: (Value' -> Value' -> Value' -> Either EvalError Value') -> Either EvalError Value'
    ternary f = case args of
      [a, b, c] -> f a b c
      _ -> Left (TypeMismatch (name <> " expects exactly 3 arguments, got " <> tshow (length args)))

    cardinality :: Either EvalError Value'
    cardinality = arity1 $ \case
      VArray xs -> Right (VNumber (fromIntegral (length xs)))
      VObject o -> Right (VNumber (fromIntegral (Map.size o)))
      other -> Left (TypeMismatch (name <> " expects an array or object, got " <> describeValue other))

    asBool :: Value' -> Either EvalError Bool
    asBool (VBool b) = Right b
    asBool other = Left (TypeMismatch (name <> " expects a boolean argument, got " <> describeValue other))

    asNumber :: Value' -> Either EvalError Scientific
    asNumber (VNumber n) = Right n
    asNumber other = Left (TypeMismatch (name <> " expects a number argument, got " <> describeValue other))

    asArray :: Value' -> Either EvalError [Value']
    asArray (VArray xs) = Right xs
    asArray other = Left (TypeMismatch (name <> " expects an array argument, got " <> describeValue other))

    -- | @and@\/@or@ fold over however many arguments they are given, zero
    -- included (vacuously), rather than fixing an arity.
    variadicBool :: (Bool -> Bool -> Bool) -> Bool -> Either EvalError Value'
    variadicBool op identityVal = VBool . foldl' op identityVal <$> traverse asBool args

    comparison :: (Scientific -> Scientific -> Bool) -> Either EvalError Value'
    comparison op = binary $ \a b -> VBool <$> (op <$> asNumber a <*> asNumber b)

    -- | Deliberately tolerant: a missing key, an out-of-range index, or a
    -- container of the wrong shape all answer @false@ rather than erroring.
    hasImpl :: Value' -> Value' -> Either EvalError Value'
    hasImpl container key = Right . VBool $ case (container, key) of
      (VObject o, VString k) -> Map.member k o
      (VArray xs, VNumber n) -> maybe False (\i -> i >= 0 && i < length xs) (asIndex n)
      _ -> False

    -- | Dynamic access by a computed key or index -- the counterpart to a
    -- static path segment. The third argument is the mandatory fallback.
    lookupImpl :: Value' -> Value' -> Value' -> Either EvalError Value'
    lookupImpl container key fallback = Right $ case (container, key) of
      (VObject o, VString k) -> maybe fallback id (Map.lookup k o)
      (VArray xs, VNumber n) -> maybe fallback id (asIndex n >>= atIndex xs)
      _ -> fallback

    atIndex :: [Value'] -> Int -> Maybe Value'
    atIndex xs i
      | i >= 0 && i < length xs = Just (xs !! i)
      | otherwise = Nothing

    -- | An index must be a non-negative whole number: @2.5@ and @-1@ are not
    -- indices.
    asIndex :: Scientific -> Maybe Int
    asIndex n =
      let d = toRealFloat n :: Double
          i = round d :: Int
       in if fromIntegral i == d && i >= 0 then Just i else Nothing

    -- | Variadic array join, preserving order. @concat()@ is @[]@; a
    -- non-array argument anywhere is an error rather than being wrapped.
    concatImpl :: Either EvalError Value'
    concatImpl = VArray . concat <$> traverse asArray args

    -- | @append(arr, item)@ adds one element at the end. An array item is
    -- appended as a single element, not spliced -- @concat@ splices.
    appendImpl :: Value' -> Value' -> Either EvalError Value'
    appendImpl arr item = (\xs -> VArray (xs <> [item])) <$> asArray arr

-- | How a value reads when it is rendered into a string by @str@ (and so by
-- string interpolation): a string is itself, @null@ is empty, and anything
-- structured is compact JSON.
--
-- This is a normative rendering, not a debugging one, so it must agree
-- across implementations character for character -- it is what a template
-- interpolates into its output. See @../specs/reference.md@.
displayString :: Value -> Text
displayString Null = ""
displayString (Bool b) = if b then "true" else "false"
displayString (Number n) = formatNumber n
displayString (String s) = s
displayString v = compactJson v

-- | Compact JSON, with object keys in sorted order and numbers formatted by
-- 'formatNumber'.
--
-- Deliberately not aeson's own 'encode': that writes every number through
-- its 'Scientific' representation (@1.0@, @1.0e11@) where a JavaScript host
-- writes @1@ and @100000000000@, so using it here would leave two
-- conforming implementations rendering the same value differently. Keys are
-- sorted for the same reason -- object key order is not semantically
-- significant, so it must not be observable through @str@ either.
compactJson :: Value -> Text
compactJson Null = "null"
compactJson (Bool b) = if b then "true" else "false"
compactJson (Number n) = formatNumber n
compactJson (String s) = quoteString s
compactJson (Array xs) = "[" <> T.intercalate "," (map compactJson (V.toList xs)) <> "]"
compactJson (Object o) =
  "{" <> T.intercalate "," (map entry (sortOn fst (map (\(k, v) -> (Key.toText k, v)) (KeyMap.toList o)))) <> "}"
  where
    entry (k, v) = quoteString k <> ":" <> compactJson v

-- | A JSON string literal, escaped by aeson itself so this does not grow a
-- second, subtly different escaping table.
quoteString :: Text -> Text
quoteString = TL.toStrict . TLE.decodeUtf8 . encode . String

formatNumber :: Scientific -> Text
formatNumber = formatDouble . toRealFloat

-- | Formats a double exactly as ECMAScript's @Number::toString@ does.
--
-- Matching that specific algorithm is the point: the PureScript
-- implementation runs on a JavaScript host, where this is simply what a
-- number's text /is/. Haskell's own 'show' picks different thresholds for
-- scientific notation -- @0.05@ prints as @5.0e-2@, @1e11@ as @1.0e11@ --
-- so leaving it to 'show' would make the two implementations disagree on
-- something as ordinary as interpolating a price or a count.
--
-- NaN and infinities cannot reach here: JSON has no way to express them.
formatDouble :: Double -> Text
formatDouble d
  | isNaN d = "NaN"
  | isInfinite d = if d < 0 then "-Infinity" else "Infinity"
  | d == 0 = "0"
  | d < 0 = "-" <> formatPositive (negate d)
  | otherwise = formatPositive d

-- | The digit-placement rules of ECMA-262's @Number::toString@, given the
-- shortest round-tripping digit sequence @ds@ and exponent @n@ for which
-- the value is @0.ds * 10^n@ -- which is exactly what 'floatToDigits'
-- returns.
formatPositive :: Double -> Text
formatPositive d
  | n >= k && n <= 21 = digits <> T.replicate (n - k) "0"
  | n > 0 && n <= 21 = T.take n digits <> "." <> T.drop n digits
  | n > (-6) && n <= 0 = "0." <> T.replicate (negate n) "0" <> digits
  | otherwise = mantissa <> "e" <> sign <> tshow (abs e)
  where
    (ds, n) = floatToDigits 10 d
    k = length ds
    digits = T.pack (map intToDigit ds)
    e = n - 1
    mantissa = if k == 1 then digits else T.take 1 digits <> "." <> T.drop 1 digits
    sign = if e >= 0 then "+" else "-" :: Text
