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
  , Mode(..)
  , LibraryTable
  , evalProgram
  , runProgram
  , builtinNames
  ) where

import Prelude

import Data.Argonaut.Core (Json, caseJson, fromArray, fromBoolean, fromNumber, fromObject, fromString, jsonNull, stringify, toArray, toBoolean, toNumber, toObject, toString)
import Data.Array as Array
import Data.Bifunctor (lmap)
import Data.Either (Either(..), either, note)
import Data.Foldable (and, any, foldMap, foldl, traverse_)
import Data.Int as Int
import Data.Map (Map)
import Data.Map as Map
import Data.Set as Set
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.String (Pattern(..), stripSuffix)
import Data.String.Common (joinWith)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst, snd)
import Foreign.Object (Object)
import Foreign.Object as Object
import Tramaj.Analysis (symbolSites)
import Tramaj.Ast (ActionAdaptation, Attribute(..), Expr(..), ParamValue(..), Program, Stmt(..), adaptKey, letBindings, programRoot, unlets)
import Tramaj.Node (Node(..), NodeAttribute(..), mapActions, nodeToJson, noAnnotations)
import Tramaj.Types (ResolvedConstraintArg(..), ResolvedType(..), TypeError, canonicalId, deepTypeConstraints, eraseTypes, programTypeRoots, typeClosure)

data EvalError
  = UnboundName String
  | PathNotFound (Array String)
  | TypeMismatch String
  | UnknownLibrary String
  | ImportCycle String
  -- | `a <> b` where the two sides are not the same concatenable type.
  | ConcatMismatch String String
  -- | Whatever went wrong inside an imported library, tagged with which
  -- | library it was. Nests, so a failure three imports deep reads as the
  -- | chain that reached it. This matters most for the parameter a library
  -- | needs and the import never supplied: that surfaces as this library's
  -- | own `PathNotFound ["ctx", ...]`, and without the tag there would be
  -- | nothing on it to say whose context was short.
  | InLibrary String EvalError
  -- | A symbol would have to be minted in concrete mode: an allocation
  -- | (`?(k)`, v3-symbols §4) or an unsupplied `?ctx.path` demand at the
  -- | root (§1.3). Concrete mode has no way to represent either. Symbolic
  -- | mode never raises it: that is the one mode where a symbol is
  -- | representable.
  | SymbolsUnavailable
  -- | A symbolic value where the language requires a concrete one (§1.5's
  -- | table, and a symbol used as an allocation key).
  | NotConcrete String
  -- | A program containing `?(k)` is loaded as a library (§1.4): only the
  -- | root may allocate, because the root runs exactly once and a library
  -- | does not. Lexical, not data-flow — raised because the library's own
  -- | source contains an allocation site, whether or not evaluation would
  -- | ever reach it.
  | AllocationInLibrary String
  -- | A static v4-types failure (v4-types §10), surfaced from either the
  -- | erasure pass every entry point below runs before evaluating anything
  -- | (§7, roadmap Phase 11) or from building the symbolic envelope's
  -- | `"types"`/`"type-constraints"` lists (§8, Phase 13). Not a new
  -- | evaluation failure mode — nothing here is raised *during* evaluation
  -- | — but `Tramaj.Types.TypeError` still needs a home in the one error
  -- | type every entry point already returns.
  | TypeErr TypeError

derive instance eqEvalError :: Eq EvalError

instance showEvalError :: Show EvalError where
  show (UnboundName name) = "UnboundName " <> show name
  show (PathNotFound segs) = "PathNotFound " <> show segs
  show (TypeMismatch msg) = "TypeMismatch " <> show msg
  show (UnknownLibrary name) = "UnknownLibrary " <> show name
  show (ImportCycle name) = "ImportCycle " <> show name
  show (ConcatMismatch l r) = "ConcatMismatch " <> show l <> " " <> show r
  show (InLibrary name err) = "InLibrary " <> show name <> " (" <> show err <> ")"
  show SymbolsUnavailable = "SymbolsUnavailable"
  show (NotConcrete who) = "NotConcrete " <> show who
  show (AllocationInLibrary name) = "AllocationInLibrary " <> show name
  show (TypeErr e) = "TypeErr (" <> show e <> ")"

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

-- | A host parameter, not a property of the program (v3-symbols §5): what an
-- | interpreter is willing to read back out, not anything the template
-- | itself declares. `Concrete` is `reference.md` exactly — Node JSON or a
-- | plain value, byte for byte. `Symbolic` wraps the same evaluation in the
-- | v3 envelope (§5.2); until §3/§4 land, that envelope's `"symbols"` and
-- | `"constraints"` are always empty, because nothing yet produces either.
data Mode = Concrete | Symbolic

derive instance eqMode :: Eq Mode

instance showMode :: Show Mode where
  show Concrete = "Concrete"
  show Symbolic = "Symbolic"

-- | Host-supplied library store. Where a library came from — a file, an
-- | embedded string, a fetch — is entirely the host's business; the
-- | evaluator only ever sees an already-parsed `Program`.
type LibraryTable = Map String Program

-- | The language's value domain.
-- |
-- | `VArray`/`VObject` hold `Value`, not JSON, so a document node can
-- | travel inside a structure like any other value. `VEnv` is an import's
-- | `{rendered, vals}` result. `VImport` is an import that has been wired
-- | up but not run — reading a field off it is what runs it.
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
  | VImport PendingImport
  | -- | `constraint(name, args...)` (v3-symbols §2.1): a value like any
    -- | other, so it can be bound, passed around and collected into an
    -- | array, right up until it tries to cross a JSON boundary (`toJson`
    -- | refuses it) or is left unreached by any `!`.
    VConstraint String (Array Value)
  | -- | A symbol (§1.1): opaque data, identified by a `SymbolId` and a
    -- | projection path extended one segment at a time by field access
    -- | (§1.6). An allocation (`?(k)`) starts with an empty path; so does a
    -- | demand (`?ctx.path`) once minted — its own path is baked into the
    -- | id, not carried here.
    VSymbol SymbolId (Array String)

type Env = Map String Value

-- | A symbol's identity (§1.4): a string, identical in every conforming
-- | implementation for the same program and key.
type SymbolId = String

-- | An entry in the symbol table (§5.2). Only allocations appear there —
-- | which includes an unsupplied demand minted at the root (§1.3), since
-- | that too is the root allocating — and a symbol the host seeded (§5.4)
-- | is never listed, because the language has nothing to add about one it
-- | did not mint.
newtype SymbolEntry = SymbolEntry
  { id :: SymbolId
  , origin :: SymbolOrigin
  , binding :: Maybe String
  }

-- | Where a symbol table entry came from: an `?(k)` at a given site, with
-- | the key it was allocated with already reduced to JSON; or an
-- | unsupplied `?ctx.path` demand, minted at the root.
data SymbolOrigin
  = OAlloc Int Json
  | ODemand (Array String)

-- | An import that has been named and wired up, and has not run.
-- |
-- | `params` is everything supplied so far, however it arrived: an
-- | expression, a `ctx(path)` read out of the importing program's own
-- | context at the wiring site, or a later call adding more. Nothing here
-- | records what is still *missing*, because nothing here knows: the
-- | library decides that when it runs and reads its `$ctx`. That is the
-- | whole point of the design — an omitted parameter is what defers an
-- | import, so partiality needs no declaration and no bookkeeping.
-- |
-- | `queued` holds adaptations applied before the import ran; they run on
-- | the result, once there are actions for them to reach.
newtype PendingImport = PendingImport
  { name :: String
  , params :: Map String Value
  , queued :: Array (Tuple ActionAdaptation (Maybe Value))
  }

-- | The set of libraries already being evaluated on this call chain.
-- | `Map String Unit` rather than a `Set` only because that is what is
-- | already imported here.
type InProgress = Map String Unit

-- | Everything evaluation needs to know about that is not the local
-- | environment: the library table, the set of libraries already being
-- | evaluated on this chain (cycle detection), the mode (v3-symbols §5),
-- | and whether this is the root program or somewhere inside a library
-- | (§1.3, §1.4) — bundled so that adding one more such fact, as §1.4's
-- | did, touches this record instead of every function's argument list.
type EvalCtx =
  { libs :: LibraryTable
  , inProgress :: InProgress
  , mode :: Mode
  , isRoot :: Boolean
  }

-- | Enters a library: adds it to the in-progress set (so re-entering it is
-- | a cycle, not a loop) and clears `isRoot` — a library never allocates or
-- | mints (§1.3, §1.4), no matter how deep the chain that reached it.
enterLibrary :: String -> EvalCtx -> EvalCtx
enterLibrary name ctx = ctx { inProgress = Map.insert name unit ctx.inProgress, isRoot = false }

-- | What evaluation accumulates alongside its result (v3-symbols §4):
-- | emitted constraints and allocated symbol-table entries, each in
-- | evaluation order and each deduplicated only once, globally, at the top
-- | (§4 — "first position kept") rather than on every append.
newtype Emissions = Emissions { constraints :: Array Value, symbols :: Array SymbolEntry }

instance semigroupEmissions :: Semigroup Emissions where
  append (Emissions a) (Emissions b) =
    Emissions { constraints: a.constraints <> b.constraints, symbols: a.symbols <> b.symbols }

instance monoidEmissions :: Monoid Emissions where
  mempty = Emissions { constraints: [], symbols: [] }

-- The evaluation monad -------------------------------------------------------

-- | Evaluation threads two things besides the value it produces: it can
-- | fail with an `EvalError`, and it accumulates `Emissions` monoidally —
-- | appended in evaluation order, never mutated in place, so `Branch`
-- | evaluating only its selected arm gives exactly the right emission set
-- | for free, with no separate mechanism.
newtype Eval a = Eval (Either EvalError (Tuple a Emissions))

runEval :: forall a. Eval a -> Either EvalError (Tuple a Emissions)
runEval (Eval e) = e

instance functorEval :: Functor Eval where
  map f (Eval e) = Eval (map (\(Tuple a w) -> Tuple (f a) w) e)

instance applyEval :: Apply Eval where
  apply (Eval mf) (Eval ma) = Eval do
    Tuple f w1 <- mf
    Tuple a w2 <- ma
    pure (Tuple (f a) (w1 <> w2))

instance applicativeEval :: Applicative Eval where
  pure a = Eval (Right (Tuple a mempty))

instance bindEval :: Bind Eval where
  bind (Eval ma) f = Eval do
    Tuple a w1 <- ma
    Tuple b w2 <- runEval (f a)
    pure (Tuple b (w1 <> w2))

instance monadEval :: Monad Eval

evalError :: forall a. EvalError -> Eval a
evalError e = Eval (Left e)

-- | Brings a pure, non-emitting computation into `Eval` — every helper that
-- | only inspects already-evaluated `Value`s (no `Expr` to evaluate, so
-- | nothing it could emit) stays plain `Either` and is lifted at the call
-- | site.
liftEither :: forall a. Either EvalError a -> Eval a
liftEither = Eval <<< map (\a -> Tuple a mempty)

-- | Records constraints reached by a `!` (v3-symbols §2.2), in the order
-- | given.
tellConstraints :: Array Value -> Eval Unit
tellConstraints vs = Eval (Right (Tuple unit (Emissions { constraints: vs, symbols: [] })))

-- | Records one symbol-table entry, minted by an allocation or an
-- | unsupplied demand at the root (§1.3, §5.2).
tellSymbol :: SymbolEntry -> Eval Unit
tellSymbol entry = Eval (Right (Tuple unit (Emissions { constraints: [], symbols: [ entry ] })))

-- | Runs an `Eval` computation and reports whether it failed, without
-- | discarding whatever it had already accumulated on success. Used only
-- | to look past a `PathNotFound` that might mean "allocate instead" —
-- | every other error still propagates once inspected.
tryEval :: forall a. Eval a -> Eval (Either EvalError a)
tryEval (Eval e) = Eval case e of
  Left err -> Right (Tuple (Left err) mempty)
  Right (Tuple a w) -> Right (Tuple (Right a) w)

-- | Maps over the error only, leaving any emissions already accumulated
-- | alone — `InLibrary`'s tag, applied the same way `Data.Bifunctor.lmap`
-- | tags a plain `Either`.
mapEvalError :: forall a. (EvalError -> EvalError) -> Eval a -> Eval a
mapEvalError f (Eval e) = Eval (lmap f e)

foldMEval :: forall a b. (b -> a -> Eval b) -> b -> Array a -> Eval b
foldMEval f acc xs = case Array.uncons xs of
  Nothing -> pure acc
  Just { head, tail } -> f acc head >>= \acc' -> foldMEval f acc' tail

-- Entry points ---------------------------------------------------------------

-- | Evaluation now depends on the mode (v3-symbols §5): an allocation or an
-- | unsupplied root demand mints a symbol in symbolic mode and raises
-- | `SymbolsUnavailable` in concrete mode. There is no mode-independent
-- | evaluation any more, so every entry point takes one.
evalProgram :: Mode -> LibraryTable -> Json -> Program -> Either EvalError Output
evalProgram mode libs input prog = map fst (evalProgramWithEmissions mode libs input prog)

-- | As `evalProgram`, but also returns the deduplicated `Emissions`
-- | (v3-symbols §4) — empty for any program that emits or allocates
-- | nothing, and always empty in what concrete mode goes on to serialize,
-- | since concrete mode discards them (§5.1) and cannot produce a symbol
-- | at all.
evalProgramWithEmissions :: Mode -> LibraryTable -> Json -> Program -> Either EvalError (Tuple Output Emissions)
evalProgramWithEmissions mode libs input prog = do
  erased <- lmap TypeErr (eraseTypes libs prog)
  Tuple v emitted <- runEval do
    ctx <- liftEither (checkedFromJson mode input)
    let evalCtx = { libs, inProgress: Map.empty, mode, isRoot: true }
    evalExpr evalCtx (initialEnv ctx) (programRoot erased)
  output <- case v of
    VNode n -> Right (ONode n)
    other -> OValue <$> toJson other
  pure (Tuple output (dedupe emitted))

-- | Two constraints with the same name and equal arguments are one
-- | constraint, and two symbol-table entries with the same id are one
-- | entry — each kept at the position of the first (v3-symbols §4).
-- | Constraint equality is on the already-evaluated `Value`, which is why
-- | this must run after evaluation rather than being folded into
-- | `tellConstraints` — two constraints built from different expressions
-- | can still evaluate to the same fact.
dedupe :: Emissions -> Emissions
dedupe (Emissions { constraints, symbols }) =
  Emissions
    { constraints: dedupeBy constraintEq constraints
    , symbols: dedupeBy (\(SymbolEntry a) (SymbolEntry b) -> a.id == b.id) symbols
    }
  where
  dedupeBy :: forall a. (a -> a -> Boolean) -> Array a -> Array a
  dedupeBy eq = go []
    where
    go seen vs = case Array.uncons vs of
      Nothing -> []
      Just { head, tail }
        | Array.any (eq head) seen -> go seen tail
        | otherwise -> Array.cons head (go (Array.cons head seen) tail)

-- | Structural equality restricted to what a constraint's identity is made
-- | of: its name and its arguments, each compared as the JSON they will
-- | render as. Two constraints are the same fact regardless of which
-- | expressions produced them.
constraintEq :: Value -> Value -> Boolean
constraintEq (VConstraint n1 as1) (VConstraint n2 as2) =
  n1 == n2 && Array.length as1 == Array.length as2 && and (Array.zipWith argEq as1 as2)
  where
  argEq a b = case toJson a, toJson b of
    Right ja, Right jb -> ja == jb
    _, _ -> false
constraintEq _ _ = false

-- | The mode-aware entry point: what a host actually serializes. Concrete
-- | mode is `evalProgram` unchanged, projected down to plain JSON — Node
-- | JSON for a document, the value itself for an expression, with any
-- | emissions discarded (v3-symbols §5.1). Symbolic mode wraps the same
-- | `Output` in the v3 envelope (§5.2), including the deduplicated symbol
-- | table and constraint list.
runProgram :: Mode -> LibraryTable -> Json -> Program -> Either EvalError Json
runProgram mode libs input prog = do
  result <- evalProgramWithEmissions mode libs input prog
  typesInfo <- case mode of
    Concrete -> Right (Tuple Map.empty [])
    Symbolic -> lmap TypeErr (buildTypesInfo libs prog)
  pure (renderOutput mode typesInfo result)

-- | The `"types"` table's entries and the deduplicated `"type-constraints"`
-- | list (v4-types §8, roadmap Phase 13), computed from `prog` *before*
-- | erasure — unlike evaluation, which never needs a `TypeAnnotate` or
-- | `TypeEmit` once erasure has run, this is the one place they still
-- | matter: the envelope is exactly where a host needs the definitions and
-- | constraints those nodes named. Concrete mode never calls this
-- | (`runProgram` short-circuits it), matching §8's promise that a v3
-- | consumer reading a v4 envelope sees nothing new.
buildTypesInfo :: LibraryTable -> Program -> Either TypeError (Tuple (Map String ResolvedType) (Array (Tuple String (Array ResolvedConstraintArg))))
buildTypesInfo libs prog = do
  roots <- programTypeRoots libs prog
  closure <- typeClosure libs prog roots
  tcs <- deepTypeConstraints libs prog
  pure (Tuple closure tcs)

renderOutput :: Mode -> Tuple (Map String ResolvedType) (Array (Tuple String (Array ResolvedConstraintArg))) -> Tuple Output Emissions -> Json
renderOutput Concrete _ (Tuple output _) = case output of
  ONode n -> nodeToJson n
  OValue v -> v
renderOutput Symbolic (Tuple typesTable typeConstraintsList) (Tuple output (Emissions { constraints, symbols })) =
  fromObject
    ( Object.fromFoldable
        [ Tuple "format" (fromString "tramaj/symbolic/1")
        , Tuple "kind" (fromString kind)
        , Tuple "root" root
        , Tuple "symbols" (fromArray (map symbolEntryToJson symbols))
        , Tuple "constraints" (fromArray (map constraintToJson constraints))
        , Tuple "types" (fromArray (map typeEntryToJson (Map.toUnfoldable typesTable)))
        , Tuple "type-constraints" (fromArray (map typeConstraintToJson typeConstraintsList))
        ]
    )
  where
  Tuple kind root = case output of
    ONode n -> Tuple "document" (nodeToJson n)
    OValue v -> Tuple "expression" v

-- | One `"types"` table entry (v4-types §8): the id, and the definition
-- | behind it, rendered by `resolvedTypeToJson`.
typeEntryToJson :: Tuple String ResolvedType -> Json
typeEntryToJson (Tuple tid rt) =
  fromObject (Object.fromFoldable [ Tuple "id" (fromString tid), Tuple "definition" (resolvedTypeToJson rt) ])

-- | A `ResolvedType`'s `"definition"` shape (v4-types §8's example): a
-- | tagged union whose `kind` names which of the six algebra shapes it is.
-- | A `RRef` renders as a pointer only — its own definition is a separate
-- | entry in the table, not inlined here — which is §3's "stop at
-- | declaration boundaries" clause, still honoured at the JSON boundary.
resolvedTypeToJson :: ResolvedType -> Json
resolvedTypeToJson (RPrim name) = fromObject (Object.fromFoldable [ Tuple "kind" (fromString "prim"), Tuple "name" (fromString name) ])
resolvedTypeToJson (RArray t) = fromObject (Object.fromFoldable [ Tuple "kind" (fromString "array"), Tuple "element" (resolvedTypeToJson t) ])
resolvedTypeToJson (RRecord fields) =
  fromObject (Object.fromFoldable [ Tuple "kind" (fromString "record"), Tuple "fields" (fromArray (map field fields)) ])
  where
  field (Tuple name t) = fromObject (Object.fromFoldable [ Tuple "name" (fromString name), Tuple "type" (resolvedTypeToJson t) ])
resolvedTypeToJson (RUnion arms) =
  fromObject (Object.fromFoldable [ Tuple "kind" (fromString "union"), Tuple "arms" (fromArray (map arm arms)) ])
  where
  arm (Tuple name mt) =
    fromObject (Object.fromFoldable (Array.cons (Tuple "name" (fromString name)) (maybe [] (\t -> [ Tuple "payload" (resolvedTypeToJson t) ]) mt)))
resolvedTypeToJson r@(RRef _ _ _) = fromObject (Object.fromFoldable [ Tuple "kind" (fromString "ref"), Tuple "id" (fromString (canonicalId r)) ])
resolvedTypeToJson (RVar path) = fromObject (Object.fromFoldable [ Tuple "kind" (fromString "var"), Tuple "path" (fromArray (map fromString path)) ])

-- | A `"type-constraints"` entry (v4-types §8): a name and its resolved
-- | arguments, a type argument rendered as the erased `{"$type": ...}` tag
-- | §7 already reserves so a host reads both lists the same way, a scalar
-- | argument as the plain JSON it already is.
typeConstraintToJson :: Tuple String (Array ResolvedConstraintArg) -> Json
typeConstraintToJson (Tuple name args) =
  fromObject (Object.fromFoldable [ Tuple "name" (fromString name), Tuple "arguments" (fromArray (map arg args)) ])
  where
  arg (RCType rt) = fromObject (Object.fromFoldable [ Tuple "$type" (fromString (canonicalId rt)) ])
  arg (RCScalarStr s) = fromString s
  arg (RCScalarNum n) = fromNumber n
  arg (RCScalarBool b) = fromBoolean b
  arg RCScalarNull = jsonNull

-- | A constraint's envelope rendering (v3-symbols §5.2): its name and its
-- | arguments, each already-evaluated to plain JSON, an argument that is
-- | itself a symbol rendering as §5.3's `{"$sym": ..., "path": [...]}` tag
-- | via `toJson`.
constraintToJson :: Value -> Json
constraintToJson (VConstraint name args) =
  fromObject
    ( Object.fromFoldable
        [ Tuple "name" (fromString name)
        , Tuple "arguments" (fromArray (map (either (const jsonNull) identity <<< toJson) args))
        ]
    )
constraintToJson other = either (const jsonNull) identity (toJson other)

-- | A symbol table entry's envelope rendering (§5.2): id, origin (the
-- | structured form of the id, so a host never has to parse it) and
-- | binding.
symbolEntryToJson :: SymbolEntry -> Json
symbolEntryToJson (SymbolEntry { id, origin, binding }) =
  fromObject
    ( Object.fromFoldable
        [ Tuple "id" (fromString id)
        , Tuple "origin" (originToJson origin)
        , Tuple "binding" (maybe jsonNull fromString binding)
        ]
    )
  where
  originToJson (OAlloc site key) =
    fromObject (Object.fromFoldable [ Tuple "kind" (fromString "alloc"), Tuple "site" (fromNumber (Int.toNumber site)), Tuple "key" key ])
  originToJson (ODemand path) =
    fromObject (Object.fromFoldable [ Tuple "kind" (fromString "demand"), Tuple "path" (fromArray (map fromString path)) ])

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

-- Core evaluation ------------------------------------------------------------

evalExpr :: EvalCtx -> Env -> Expr -> Eval Value
evalExpr ctx env = case _ of
  Path root fields -> case Map.lookup root env of
    Nothing -> evalError (UnboundName root)
    Just v -> walkFields ctx (Array.cons root fields) v fields

  FieldAccess target fields -> do
    v <- evalExpr ctx env target
    walkFields ctx fields v fields

  Call fnExpr argExprs -> do
    fnVal <- evalExpr ctx env fnExpr
    argVals <- traverse (evalExpr ctx env) argExprs
    applyValue ctx (describeCallee fnExpr) fnVal argVals

  Lambda params body -> pure (VClosure params body env)

  -- `@name=?(k)` or `@name=?ctx.path` binds the allocation/demand directly
  -- to a name, which is what the symbol table's `"binding"` field (§5.2)
  -- reports; anything else evaluates exactly as it always has. Routed
  -- through `evalBindable` rather than special-cased here so a standalone
  -- `Alloc`/`Demand` (used inline, with no binding) shares the same
  -- minting logic.
  Let name valueExpr body -> do
    v <- evalBindable ctx env (Just name) valueExpr
    evalExpr ctx (Map.insert name v env) body

  StringLit s -> pure (VString s)
  NumberLit n -> pure (VNumber n)
  BoolLit b -> pure (VBool b)
  NullLit -> pure VNull

  ArrayLit elems -> VArray <$> traverse (evalExpr ctx env) elems

  ObjectLit entries ->
    VObject <<< Map.fromFoldable
      <$> traverse (\(Tuple k e) -> Tuple k <$> evalExpr ctx env e) entries

  Element tag attrs valueExpr children -> do
    attrs' <- traverse (evalAttribute ctx env) attrs
    value <- evalExpr ctx env valueExpr >>= liftEither <<< toJson
    children' <- evalChildren ctx env children
    pure (VNode (NElement tag attrs' value children' noAnnotations))

  Fragment children ->
    (\ns -> VNode (NFragment ns noAnnotations)) <$> evalChildren ctx env children

  -- The one non-eager form in the language: the arm not selected is never
  -- evaluated, so an error inside it never surfaces.
  Branch condExpr thenExpr elseExpr -> do
    cond <- evalExpr ctx env condExpr >>= liftEither <<< requireBool "a branch condition"
    evalExpr ctx env (if cond then thenExpr else elseExpr)

  Map collExpr fnExpr -> do
    items <- evalCollection ctx env "map" collExpr
    fnVal <- evalExpr ctx env fnExpr
    VArray <$> traverse (\item -> applyValue ctx "map" fnVal [ item ]) items

  Filter collExpr fnExpr -> do
    items <- evalCollection ctx env "filter" collExpr
    fnVal <- evalExpr ctx env fnExpr
    kept <- traverse
      (\item -> Tuple item <$> (applyValue ctx "filter" fnVal [ item ] >>= liftEither <<< requireBool "a filter predicate"))
      items
    pure (VArray (map fst (Array.filter snd kept)))

  Scan collExpr initExpr fnExpr -> do
    items <- evalCollection ctx env "scan" collExpr
    acc0 <- evalExpr ctx env initExpr
    fnVal <- evalExpr ctx env fnExpr
    VArray <$> scanSteps ctx fnVal acc0 items

  Fold collExpr initExpr fnExpr -> do
    items <- evalCollection ctx env "fold" collExpr
    acc0 <- evalExpr ctx env initExpr
    fnVal <- evalExpr ctx env fnExpr
    foldSteps ctx fnVal acc0 items

  Concat leftExpr rightExpr -> do
    l <- evalExpr ctx env leftExpr
    r <- evalExpr ctx env rightExpr
    liftEither (concatValues l r)

  -- Wiring up an import evaluates its parameters and stops there. The
  -- library itself runs later, when a field is read off the result, so
  -- parameters can keep arriving in between.
  -- A `%`-marked entry (v4-types §2) supplies a type, not a value, so it
  -- never reaches the library's own `$ctx` — `resolveParam` drops it, the
  -- same way `params` never has a slot for it, rather than passing some
  -- inert placeholder through: the two channels sharing one params record
  -- share no runtime representation at all, one being erased entirely
  -- before evaluation (§7).
  Import name params -> do
    supplied <- Array.catMaybes <$> traverse (resolveParam ctx env) params
    pure (VImport (PendingImport { name, params: Map.fromFoldable supplied, queued: [] }))

  AdaptActions targetExpr adaptation fnExpr -> do
    target <- evalExpr ctx env targetExpr
    fnVal <- traverse (evalExpr ctx env) fnExpr
    adaptValue ctx adaptation fnVal target

  -- `constraint(name, args...)` (v3-symbols §2.1). Each argument must be
  -- something that can cross a JSON boundary — the same rule `toJson`
  -- already enforces everywhere else — checked here and not deferred,
  -- since a constraint carrying a closure would otherwise sit unnoticed
  -- until whatever `!` eventually reaches it, or never surface at all if
  -- none does.
  Constrain name argExprs -> do
    argVals <- traverse (evalExpr ctx env) argExprs
    liftEither (traverse_ toJson argVals)
    pure (VConstraint name argVals)

  Alloc site keyExpr -> evalBindable ctx env Nothing (Alloc site keyExpr)
  Demand path -> evalBindable ctx env Nothing (Demand path)

  -- `!expr` (§2.2): evaluates the constraint expression, collects from its
  -- value by the coercion table `collectConstraints` encodes, records what
  -- it collected, then continues into the body — the same "earlier
  -- bindings only" shape `Let` already has, since both nest into one
  -- chain.
  Emit constraintExpr body -> do
    cv <- evalExpr ctx env constraintExpr
    collected <- liftEither (collectConstraints cv)
    tellConstraints collected
    evalExpr ctx env body

  -- `type Name = TypeExpr` (v4-types §1.1, roadmap Phase 8): means nothing
  -- to evaluation — resolution is a static pass (v4-types §9) — so this
  -- simply continues into the body.
  TypeDecl _ _ body -> evalExpr ctx env body

  -- Every entry point below (`evalProgramWithEmissions`, `runLibrary`) runs
  -- `Tramaj.Types`'s erasure pass before ever calling `evalExpr`, which
  -- rewrites every `TypeAnnotate` into the `Let`/`Emit` pair v4-types §7
  -- specifies — so this case is not the normal path. It is kept total
  -- anyway, exactly as `TypeDecl`'s case is total on purpose: matching what
  -- erasure would have produced, minus the emission, keeps `evalExpr`
  -- correct even if a caller somehow reaches it pre-erasure, rather than
  -- leaving a partial match for that case to crash on.
  TypeAnnotate name _ valueExpr body -> evalExpr ctx env (Let name valueExpr body)

  -- `!type-constraint(...)` (v4-types §5, roadmap Phase 12): resolved by
  -- the analyser, never evaluated — §5.1 is explicit that the evaluator's
  -- statement fold skips this, exactly as it skips `TypeDecl`.
  TypeEmit _ _ body -> evalExpr ctx env body

-- | `Alloc` and `Demand` are the two forms whose symbol-table entry
-- | records the name they were bound to, or `Nothing` when used inline
-- | (v3-symbols §5.2's `"binding"` field) — everything else evaluates
-- | through plain `evalExpr`, unaffected by whether it happens to sit on a
-- | `Let`'s right-hand side.
evalBindable :: EvalCtx -> Env -> Maybe String -> Expr -> Eval Value
evalBindable ctx env binding (Alloc site keyExpr) = evalAlloc ctx env binding site keyExpr
evalBindable ctx env binding (Demand path) = evalDemand ctx env binding path
evalBindable ctx env _ other = evalExpr ctx env other

-- | `?(key)` (§1.2, §4): the key is evaluated first, in both modes alike
-- | — so an error inside it surfaces the same way regardless of mode —
-- | and only *minting* depends on the mode (§5.1): concrete mode has no
-- | way to represent the result, symbolic mode allocates and records the
-- | entry.
evalAlloc :: EvalCtx -> Env -> Maybe String -> Int -> Expr -> Eval Value
evalAlloc ctx env binding site keyExpr = do
  keyVal <- evalExpr ctx env keyExpr
  keyJson <- liftEither (requireConcrete "?(...)" keyVal)
  case ctx.mode of
    Concrete -> evalError SymbolsUnavailable
    Symbolic -> do
      let sid = "#" <> show site <> ":" <> canon keyJson
      tellSymbol (SymbolEntry { id: sid, origin: OAlloc site keyJson, binding })
      pure (VSymbol sid [])

-- | `?ctx.a.b` (§1.3): reads exactly as `$ctx.a.b` would when the path is
-- | supplied, in either mode — `tryEval` only ever looks past a
-- | `PathNotFound` it raises. Unsupplied, it allocates at the root (mode
-- | permitting) and is an ordinary unsupplied read anywhere else, which
-- | `mapEvalError` in `runLibrary` already tags with `InLibrary`.
evalDemand :: EvalCtx -> Env -> Maybe String -> Array String -> Eval Value
evalDemand ctx env binding path = do
  attempt <- tryEval (evalExpr ctx env (Path "ctx" path))
  case attempt of
    Right v -> pure v
    Left (PathNotFound _) | ctx.isRoot -> case ctx.mode of
      Concrete -> evalError SymbolsUnavailable
      Symbolic -> do
        let sid = "#ctx" <> foldMap ("." <> _) path
        tellSymbol (SymbolEntry { id: sid, origin: ODemand path, binding })
        pure (VSymbol sid [])
    Left e -> evalError e

-- | The coercion table a `!` collects by (v3-symbols §2.2): a constraint
-- | contributes itself; an array contributes each element, recursively,
-- | which is why `!map(...)` and `!$cs` (a binding holding an array built
-- | earlier) both read naturally; anything else is a `TypeMismatch`.
collectConstraints :: Value -> Either EvalError (Array Value)
collectConstraints v@(VConstraint _ _) = Right [ v ]
collectConstraints (VArray xs) = Array.concat <$> traverse collectConstraints xs
collectConstraints other = Left (TypeMismatch ("! expects a constraint or an array of them, got " <> describeValue other))

-- | One parameter, resolved where the import is written.
-- |
-- | `ctx(path)` is substituted here, from the *importing* program's own
-- | context — exactly what `$ctx.path` would read, including the same
-- | `PathNotFound` when it is absent, which is why it evaluates as that
-- | very expression. It is a distinct AST node purely so
-- | `Tramaj.Analysis` can read every hole off the source without
-- | evaluating anything; the evaluator gains nothing from the
-- | distinction and deliberately makes no other use of it.
resolveParam
  :: EvalCtx
  -> Env
  -> Tuple String ParamValue
  -> Eval (Maybe (Tuple String Value))
resolveParam ctx env (Tuple k (PExpr e)) =
  Just <<< Tuple k <$> evalExpr ctx env e
resolveParam ctx env (Tuple k (PFromContext path)) =
  Just <<< Tuple k <$> evalExpr ctx env (Path "ctx" path)
resolveParam _ _ (Tuple _ (PType _)) = pure Nothing

-- | Only for error messages: what the source called, as written.
describeCallee :: Expr -> String
describeCallee (Path root fields) = Array.intercalate "." (Array.cons root fields)
describeCallee _ = "a call"

-- Documents -------------------------------------------------------------------

evalAttribute :: EvalCtx -> Env -> Attribute -> Eval NodeAttribute
evalAttribute ctx env (Attr name e) =
  NAttr name <$> (evalExpr ctx env e >>= liftEither <<< toJson)
evalAttribute ctx env (ActionAttr event key payloadExpr) =
  NAction event key <$> (evalExpr ctx env payloadExpr >>= liftEither <<< toJson)

evalChildren :: EvalCtx -> Env -> Array Expr -> Eval (Array Node)
evalChildren ctx env children =
  Array.concat <$> traverse (\e -> evalExpr ctx env e >>= liftEither <<< childNodes) children

-- | How a value becomes children. A node is itself one child; an array
-- | contributes each of its elements, which is how `map(...)` produces
-- | repeated siblings without a document-specific map form; anything else
-- | becomes a text node carrying that value unconverted, so a number child
-- | stays a number.
-- |
-- | A closure, an unfinished import or a constraint has no rendering, and
-- | `toJson` says so — a `VConstraint` reaching here is exactly §2.1's rule
-- | that a constraint MUST NOT cross a JSON boundary, including as a child.
childNodes :: Value -> Either EvalError (Array Node)
childNodes (VNode n) = Right [ n ]
childNodes (VArray xs) = Array.concat <$> traverse childNodes xs
childNodes v = (\j -> [ NText j noAnnotations ]) <$> toJson v

-- Application ------------------------------------------------------------------

applyValue :: EvalCtx -> String -> Value -> Array Value -> Eval Value
applyValue ctx who fnVal args = case fnVal of
  VClosure params body closureEnv ->
    if Array.length params /= Array.length args then
      evalError
        ( TypeMismatch
            ( "closure expects " <> show (Array.length params) <> " argument(s), got "
                <> show (Array.length args)
            )
        )
    else
      evalExpr ctx
        (foldl (\e (Tuple p v) -> Map.insert p v e) closureEnv (Array.zip params args))
        body

  VBuiltin name -> liftEither (evalBuiltin name args)

  -- Saturating an import: the argument is more parameters, merged over
  -- what it already has. Right-biased, like `<>` on objects, so a later
  -- call overrides an earlier value for the same name — which is what
  -- makes one wired-up import reusable across a `map`, each iteration
  -- supplying its own.
  VImport (PendingImport p) -> case args of
    [ VObject more ] -> pure (VImport (PendingImport (p { params = Map.union more p.params })))
    [ other ] ->
      evalError
        ( TypeMismatch
            ( who <> ": the import of " <> show p.name
                <> " takes an object of parameters, got " <> describeValue other
            )
        )
    _ ->
      evalError
        ( TypeMismatch
            ( who <> ": the import of " <> show p.name
                <> " expects exactly 1 argument, the parameters to add"
            )
        )

  v -> evalError (TypeMismatch (who <> " is not callable: " <> describeValue v))

-- | `scan`'s output is `[init, f(init, x1), f(f(init, x1), x2), ...]` —
-- | `scanl`, not `scanl1`.
scanSteps :: EvalCtx -> Value -> Value -> Array Value -> Eval (Array Value)
scanSteps ctx fnVal acc items = case Array.uncons items of
  Nothing -> pure [ acc ]
  Just { head, tail } -> do
    next <- applyValue ctx "scan" fnVal [ acc, head ]
    Array.cons acc <$> scanSteps ctx fnVal next tail

-- | The same steps as `scanSteps`, keeping only the final accumulator.
foldSteps :: EvalCtx -> Value -> Value -> Array Value -> Eval Value
foldSteps ctx fnVal acc items = case Array.uncons items of
  Nothing -> pure acc
  Just { head, tail } -> do
    next <- applyValue ctx "fold" fnVal [ acc, head ]
    foldSteps ctx fnVal next tail

evalCollection :: EvalCtx -> Env -> String -> Expr -> Eval (Array Value)
evalCollection ctx env who e = do
  v <- evalExpr ctx env e
  case v of
    VArray xs -> pure xs
    VSymbol _ _ -> evalError (NotConcrete who)
    other -> evalError (TypeMismatch (who <> " expects an array as its first argument, got " <> describeValue other))

-- Concat -------------------------------------------------------------------------

-- | The monoid operation over the three types that have one. Mixed types
-- | are an error rather than a coercion, and objects merge right-biased.
-- | Either side being a symbol is `NotConcrete` (v3-symbols §1.5), ahead of
-- | the generic mismatch: the spine of a concatenation must be known,
-- | unlike an element it might merely carry.
concatValues :: Value -> Value -> Either EvalError Value
concatValues (VSymbol _ _) _ = Left (NotConcrete "<>")
concatValues _ (VSymbol _ _) = Left (NotConcrete "<>")
concatValues (VString a) (VString b) = Right (VString (a <> b))
concatValues (VArray a) (VArray b) = Right (VArray (a <> b))
concatValues (VObject a) (VObject b) = Right (VObject (Map.union b a))
concatValues l r = Left (ConcatMismatch (describeValue l) (describeValue r))

-- Imports --------------------------------------------------------------------------

-- | Runs the library behind an import, against the parameters it has
-- | accumulated, and applies whatever adaptations were queued on it.
-- |
-- | This is the only place a library runs, and `walkFields` is the only
-- | caller: an import runs when a field is read off it, never where it is
-- | written. Nothing checks first whether the parameters are enough —
-- | there is no list of what "enough" would be. A library that reads a
-- | `$ctx` path nobody supplied fails with its own `PathNotFound`, tagged
-- | by `runLibrary` with the library's name.
forceImport :: EvalCtx -> PendingImport -> Eval Value
forceImport ctx (PendingImport p) = do
  result <- runLibrary ctx p.name (VObject p.params)
  applyQueued ctx p.queued result

-- | Evaluates a library against its own fresh `$ctx` — the parameters it
-- | was given — and exposes `{rendered, vals}`. `inProgress` carries the
-- | libraries already being evaluated on this chain, so re-entering one is
-- | reported as a cycle instead of running forever.
-- |
-- | Bindings are replayed by hand, via `foldMEval` over `bindStep`, rather
-- | than letting a single `evalExpr` over the whole chain produce
-- | `rendered`: that is what exposes each binding's own value for `.vals`
-- | without a separate environment-inspection mechanism. Any `!` interleaved
-- | among the bindings (v3-symbols §2.3 — "a library's emissions are
-- | collected ... when a field is read off its import") is replayed the
-- | same way, in the same pass, so its constraints are collected exactly
-- | once, at its position in the chain — this is the fix for the `unlets`
-- | trap: the old version simply stopped at the first non-`Let`, which
-- | silently dropped both the bindings after a `!` and the `!`'s own
-- | constraint.
runLibrary :: EvalCtx -> String -> Value -> Eval Value
runLibrary ctx name ctxVal =
  if isJust (Map.lookup name ctx.inProgress) then evalError (ImportCycle name)
  else do
    rawProg <- liftEither (note (UnknownLibrary name) (Map.lookup name ctx.libs))
    liftEither (if Set.isEmpty (symbolSites rawProg) then Right unit else Left (AllocationInLibrary name))
    prog <- liftEither (lmap TypeErr (eraseTypes ctx.libs rawProg))
    mapEvalError (InLibrary name) do
      let
        ctx' = enterLibrary name ctx
        peeled = unlets (programRoot prog)
      libEnv <- foldMEval (bindStep ctx') (initialEnv ctxVal) peeled.statements
      rendered <- evalExpr ctx' libEnv peeled.root
      let
        bindings = letBindings peeled.statements
        vals = Array.mapMaybe (\(Tuple n _) -> Tuple n <$> Map.lookup n libEnv) bindings
      pure (VEnv (Map.fromFoldable [ Tuple "rendered" rendered, Tuple "vals" (VEnv (Map.fromFoldable vals)) ]))
  where
  bindStep ctx' env (SLet n e) = do
    v <- evalExpr ctx' env e
    pure (Map.insert n v env)
  bindStep ctx' env (SEmit e) = do
    cv <- evalExpr ctx' env e
    collected <- liftEither (collectConstraints cv)
    tellConstraints collected
    pure env
  -- A type declaration means nothing to the evaluator (v4-types, roadmap
  -- Phase 8) — it exists for static resolution alone, so replaying it here
  -- is a no-op on the environment.
  bindStep _ env (STypeDecl _ _) = pure env
  -- See `evalExpr`'s `TypeAnnotate` case: erasure has already turned this
  -- into a `SLet` plus `SEmit` by the time a library's own chain gets here,
  -- so this branch, like that one, only guards totality.
  bindStep ctx' env (SAnnotate n _ e) = do
    v <- evalExpr ctx' env e
    pure (Map.insert n v env)
  -- See `evalExpr`'s `TypeEmit` case: never evaluated.
  bindStep _ env (STypeEmit _ _) = pure env

-- Action adaptation -------------------------------------------------------------------

-- | Applies an adaptation everywhere it can reach: through a node's whole
-- | tree, through every value of an import result (not just `rendered`),
-- | and through arrays. An import that has not run has no actions yet, so
-- | the adaptation is queued and runs on its result. Anything else has no
-- | actions and passes through untouched.
adaptValue :: EvalCtx -> ActionAdaptation -> Maybe Value -> Value -> Eval Value
adaptValue ctx adaptation fnVal = go
  where
  go (VNode n) = VNode <$> mapActions (adaptAction ctx adaptation fnVal) n
  go (VEnv e) = VEnv <$> traverse go e
  go (VArray xs) = VArray <$> traverse go xs
  go (VObject o) = VObject <$> traverse go o
  go (VImport (PendingImport p)) =
    pure (VImport (PendingImport (p { queued = Array.snoc p.queued (Tuple adaptation fnVal) })))
  go v = pure v

applyQueued
  :: EvalCtx
  -> Array (Tuple ActionAdaptation (Maybe Value))
  -> Value
  -> Eval Value
applyQueued ctx queued v0 =
  foldMEval (\v (Tuple adaptation fnVal) -> adaptValue ctx adaptation fnVal v) v0 queued

-- | One action, adapted. The key is rewritten first, unconditionally, by
-- | the static adaptation; the optional closure then sees the
-- | already-adapted action and may change only its event type and payload.
-- | A `key` in the closure's result is ignored — letting it win would put
-- | the action vocabulary back beyond static reach, which is the whole
-- | point of restricting adaptation.
adaptAction
  :: EvalCtx
  -> ActionAdaptation
  -> Maybe Value
  -> String
  -> String
  -> Json
  -> Eval NodeAttribute
adaptAction ctx adaptation fnVal event key payload = case fnVal of
  Nothing -> pure (NAction event key' payload)
  Just fn -> do
    result <- applyValue ctx "adapt-actions" fn [ actionAsValue ] >>= liftEither <<< toJson
    fields <- liftEither $ note
      (TypeMismatch "adapt-actions: the function must return an object with an eventType field")
      (toObject result)
    event' <- liftEither $ note
      (TypeMismatch "adapt-actions: the function's result needs a string \"eventType\" field")
      (Object.lookup "eventType" fields >>= toString)
    let
      payload' = fromMaybe jsonNull (Object.lookup "payload" fields)
    pure (NAction event' key' payload')
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
walkFields :: EvalCtx -> Array String -> Value -> Array String -> Eval Value
walkFields ctx context v fields = case Array.uncons fields of
  Nothing -> pure v
  Just { head, tail } -> case v of
    VObject o -> case Map.lookup head o of
      Nothing -> evalError (PathNotFound context)
      Just v' -> walkFields ctx context v' tail
    VEnv e -> case Map.lookup head e of
      Nothing -> evalError (PathNotFound context)
      Just v' -> walkFields ctx context v' tail
    -- Reading a field off an import is what runs it — `.rendered` and
    -- `.vals` are fields of the result, so the same segment is then walked
    -- into that result rather than consumed here.
    VImport pending -> do
      result <- forceImport ctx pending
      walkFields ctx context result fields
    -- Projection (v3-symbols §1.6): reads nothing, and is never rejected
    -- — whether the thing a symbol stands for has this field is a
    -- question for whoever owns its meaning, not the language. Consumes
    -- every remaining segment at once, since a projection just extends
    -- the path.
    VSymbol sid path -> pure (VSymbol sid (path <> fields))
    other ->
      evalError
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
toJson (VConstraint name _) =
  Left (TypeMismatch ("a constraint (" <> show name <> ") cannot cross a JSON boundary -- only \"!\" may consume it"))
-- | A symbol may sit in an attribute, a payload, a value slot or a text
-- | child (v3-symbols §1.5), so this always succeeds — it is
-- | `requireConcrete` that refuses one, for the handful of forms that need
-- | to. §5.3's tagged shape: both fields required, matching what the
-- | decoder in `checkedFromJson` accepts back.
toJson (VSymbol sid path) =
  Right (fromObject (Object.fromFoldable [ Tuple "$sym" (fromString sid), Tuple "path" (fromArray (map fromString path)) ]))
toJson (VClosure _ _ _) =
  Left (TypeMismatch "expected a value, got a function -- call it first, e.g. $my-fn(...)")
toJson (VBuiltin name) =
  Left (TypeMismatch ("expected a value, got the builtin " <> show name <> " -- call it first"))
toJson (VEnv _) =
  Left (TypeMismatch "expected a value, got an import result -- read .rendered, .vals, or a binding name from it first")
toJson (VImport (PendingImport p)) =
  Left
    ( TypeMismatch
        ( "expected a value, got the import of " <> show p.name
            <> " -- read .rendered or .vals from it to run it first"
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

-- | The input context's boundary: as `fromJson`, but recursively refusing
-- | `"$sym"` and `"$type"` as ordinary object keys (v3-symbols §5.3). In
-- | concrete mode either key is refused unconditionally. In symbolic mode,
-- | seeding (§5.4) accepts a well-formed `{"$sym": ..., "path": [...]}`
-- | back as an actual symbol — anything else carrying `"$sym"`, or
-- | `"$type"` at all (v3 has no valid shape for it yet), is still refused.
checkedFromJson :: Mode -> Json -> Either EvalError Value
checkedFromJson mode j =
  case toString j of
    Just s -> Right (VString s)
    Nothing -> case toNumber j of
      Just n -> Right (VNumber n)
      Nothing -> case toBoolean j of
        Just b -> Right (VBool b)
        Nothing -> case toArray j of
          Just xs -> VArray <$> traverse (checkedFromJson mode) xs
          Nothing -> case toObject j of
            Just o -> decodeObject o
            Nothing -> Right VNull
  where
  decodeObject o
    | isJust (Object.lookup "$type" o) =
        Left (TypeMismatch "the context carries the reserved key \"$type\", which only a typed envelope may use")
    | Just symVal <- Object.lookup "$sym" o =
        case mode of
          Concrete -> Left (TypeMismatch "the context carries the reserved key \"$sym\", which only a symbolic envelope may use")
          Symbolic -> case toString symVal, Object.toUnfoldable (Object.delete "$sym" o) :: Array (Tuple String Json) of
            Just sid, [ Tuple "path" pathJson ] -> case toArray pathJson of
              Just pathArr -> VSymbol sid <$> traverse expectString pathArr
              Nothing -> Left (TypeMismatch "a symbol reference's \"path\" must be an array of strings")
            _, _ -> Left (TypeMismatch "a \"$sym\" object must be exactly {\"$sym\": <id>, \"path\": [<segment>, ...]}")
    | otherwise =
        VObject <<< Map.fromFoldable
          <$> traverse (\(Tuple k v) -> Tuple k <$> checkedFromJson mode v) (Object.toUnfoldable o :: Array (Tuple String Json))

  expectString j' = note (TypeMismatch "a symbol reference's \"path\" must be an array of strings") (toString j')

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
describeValue (VImport (PendingImport p)) = "the not-yet-run import of " <> show p.name
describeValue (VConstraint name _) = "a constraint (" <> show name <> ")"
describeValue (VSymbol _ _) = "a symbol"

-- | Control flow must be concrete (v3-symbols §1.5): a symbolic condition
-- | is `NotConcrete`, not merely the wrong type.
requireBool :: String -> Value -> Either EvalError Boolean
requireBool _ (VBool b) = Right b
requireBool who (VSymbol _ _) = Left (NotConcrete who)
requireBool who other = Left (TypeMismatch (who <> " must be a boolean, got " <> describeValue other))

-- | Whether a value is, or contains, a symbol — what makes a value
-- | concrete's negation (§1.5, §1.7): a structure built of concrete pieces
-- | is itself concrete and every structural operation on it works as
-- | normal; only a symbol itself, wherever it sits, makes the whole not
-- | concrete.
containsSymbol :: Value -> Boolean
containsSymbol (VSymbol _ _) = true
containsSymbol (VArray xs) = Array.any containsSymbol xs
containsSymbol (VObject o) = any containsSymbol o
containsSymbol _ = false

-- | Requires a value with no symbol anywhere in it, for the handful of
-- | operations §1.5 lists as needing to *know* something about their
-- | argument rather than merely carry it: `str`, `eq`, and an allocation
-- | key. Everything else about crossing a JSON boundary is `toJson`'s
-- | ordinary business, which this defers to once a symbol is ruled out.
requireConcrete :: String -> Value -> Either EvalError Json
requireConcrete who v
  | containsSymbol v = Left (NotConcrete who)
  | otherwise = toJson v

-- | v3-symbols §1.4: compact JSON with keys sorted, agreeing with `str` on
-- | arrays and objects and differing at the top level for strings, where
-- | `str` renders raw and this quotes — the difference that makes it
-- | injective. This is exactly `compactJson`, which already quotes a
-- | string unconditionally; the two are one function under two names
-- | because they serve the same requirement for the same reason.
canon :: Json -> String
canon = compactJson

-- Builtins ------------------------------------------------------------------------------------

-- | A fixed vocabulary, grown only on real demand. `branch` is absent
-- | deliberately: it has to leave an arm unevaluated, which no builtin can
-- | do, so it is a core constructor instead.
evalBuiltin :: String -> Array Value -> Either EvalError Value
evalBuiltin name args = case name of
  "cardinality" -> cardinality
  "count" -> cardinality
  "str" -> arity1 (\v -> VString <<< displayString <$> requireConcrete name v)
  "not" -> arity1 (\v -> VBool <<< not <$> asBool v)
  "and" -> variadicBool (&&) true
  "or" -> variadicBool (||) false
  "eq" -> binary (\a b -> (\ja jb -> VBool (ja == jb)) <$> requireConcrete name a <*> requireConcrete name b)
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
    VSymbol _ _ -> Left (NotConcrete name)
    other -> Left (TypeMismatch (name <> " expects an array or object, got " <> describeValue other))

  asBool :: Value -> Either EvalError Boolean
  asBool (VBool b) = Right b
  asBool other = Left (TypeMismatch (name <> " expects a boolean argument, got " <> describeValue other))

  asNumber :: Value -> Either EvalError Number
  asNumber (VNumber n) = Right n
  asNumber (VSymbol _ _) = Left (NotConcrete name)
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
  -- | container of the wrong shape all answer `false` rather than
  -- | erroring — except a symbolic container, which is `NotConcrete`
  -- | rather than a lie (v3-symbols §1.5): the tolerant `false` would
  -- | claim to know something about a container the language cannot see
  -- | into.
  hasImpl :: Value -> Value -> Either EvalError Value
  hasImpl (VSymbol _ _) _ = Left (NotConcrete name)
  hasImpl container key = Right (VBool present)
    where
    present = case container, key of
      VObject o, VString k -> isJust (Map.lookup k o)
      VArray xs, VNumber n -> maybe false (\i -> isJust (Array.index xs i)) (asIndex n)
      _, _ -> false

  -- | Dynamic access by a computed key or index — the counterpart to a
  -- | static path segment. The third argument is the mandatory fallback.
  -- | A symbolic container is `NotConcrete` rather than falling back,
  -- | which would silently discard the symbol (§1.5).
  lookupImpl :: Value -> Value -> Value -> Either EvalError Value
  lookupImpl (VSymbol _ _) _ _ = Left (NotConcrete name)
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
