-- | v4-types resolution, normalisation, canonical identity, and the closure
-- | and constraint machinery output needs (roadmap-to-v4 Phases 9, 10, 13,
-- | 14). Kept as its own module, the way `Tramaj.Analysis` is kept apart
-- | from `Tramaj.Eval`: this is a static pass over parsed programs,
-- | evaluates nothing, and its only dependencies are `Tramaj.Ast` and
-- | `Tramaj.Analysis`.
-- |
-- | Scope, precisely: v4-types §9 says resolution and identity are the whole
-- | of what a type-aware analysis does before evaluation, and §3 fixes the
-- | one property every implementation must agree on — two spellings of the
-- | same type must produce the *same string*, and two different types must
-- | never collide.
-- |
-- | __Type parameters (roadmap Phase 10).__ A `Ref`'s `arguments` (v4-types
-- | §1) come from nowhere in the surface syntax at the reference site —
-- | `$msg.types.Envelope` carries no bracketed application. They come
-- | instead from *how `msg` was imported* (§2): `resolveLibBinding` now
-- | returns the import's own params alongside its key and program, and a
-- | `TLibRef` resolves its `RRef`'s `arguments` by intersecting those
-- | params' `%`-marked entries with the target library's own `typeParams`
-- | — the set `Tramaj.Analysis.typeParams` already computes without
-- | resolving anything. Each supplied argument is itself resolved under
-- | the *importing* program's own substitution, which is what makes
-- | forwarding (`%ctx.payload`, still a hole) and supplying (`%Json`, a
-- | closed argument) both fall out of the same code path.
-- |
-- | __Canonical ids and the library segment.__ v4-types §3's grammar renders
-- | a `Ref` as `library ":" name` with `library` inserted directly, and its
-- | worked examples (`message:Envelope`) do exactly that. But a library key
-- | is an arbitrary `staticString` (see `Tramaj.Parser`), and §3 requires
-- | injectivity: two distinct types must never render to the same string.
-- | Inserting an arbitrary key raw is safe on one side, because a `name` is
-- | always a colon-free identifier (see `Tramaj.Parser`'s `typeField`) —
-- | reconstructing `library` and `name` from `library <> ":" <> name` is
-- | therefore unambiguous however many colons `library` itself contains. The
-- | side that is *not* safe is the program being resolved itself: a
-- | declaration with no importing library at all (an ordinary `type X = ...`
-- | at the root) needs some token for "no library", and no plain word is
-- | safe for that — a library can legally be named `"root"`, or even `""`,
-- | since `staticString` forbids only a literal `"` or a backtick.
-- |
-- | The fix follows from that one forbidden character: `renderLibrary` wraps
-- | every real library key in a literal pair of quotes (safe, and injective,
-- | precisely because a key can never itself contain one), and reserves the
-- | bare, unquoted word `root` for "this program, not a library" — a token
-- | no quoted key can ever equal, because a quoted key always begins with
-- | `"`. This is a deliberate departure from §3's unquoted worked examples,
-- | which never exercise a program that is not itself an importable
-- | library; nothing in the grammar there rules quoting out, and nothing
-- | else in it is injective without it.
-- |
-- | Kept in lockstep with `../tramaj-hs/src/Tramaj/Types.hs`.
module Tramaj.Types
  ( ResolvedType(..)
  , ResolvedConstraintArg(..)
  , TypeError(..)
  , resolveTypeExpr
  , canonicalId
  , programTypeDecls
  , requireClosed
  , checkTypeParamCollisions
  , typeClosure
  , eraseTypes
  , typeReferences
  , deepTypeReferences
  , typeConstraints
  , deepTypeConstraints
  , programTypeRoots
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst, snd)
import Partial.Unsafe (unsafeCrashWith)
import Tramaj.Analysis (everywhereIn, transitiveImportNames, typeExprsIn, typeParamCollisions, typeParams)
import Tramaj.Ast (Attribute(..), Expr(..), ParamValue(..), Program(..), Stmt(..), TypeConstraintArg(..), TypeExpr(..), programRoot, typeDecls, unlets)

-- | The normal form a `TypeExpr` resolves to (v4-types §3). Structurally the
-- | same six shapes as `TypeExpr`, but every reference is now a genuine
-- | `(library, name)` pair rather than a name that might not exist, record
-- | fields and union arms are sorted by name, a `RRef` carries its resolved
-- | type *arguments* (roadmap Phase 10) rather than none, and a `RRef`
-- | never carries its referent's expansion — only `resolveTypeExpr` ever
-- | looks a name up, and it looks up only whether the name exists, never
-- | what it means.
-- |
-- | `Nothing` as a `RRef` library means "declared in the program being
-- | resolved, not reached through an import" — see the module header for
-- | why this needs a real `Maybe` here rather than folding straight to a
-- | string: the encoding decision belongs to `canonicalId` alone, so a
-- | `ResolvedType` can be compared with `==` before any string is ever
-- | built.
data ResolvedType
  = RPrim String
  | RArray ResolvedType
  | RRecord (Array (Tuple String ResolvedType))
  | RUnion (Array (Tuple String (Maybe ResolvedType)))
  | RRef (Maybe String) String (Array (Tuple String ResolvedType))
  | RVar (Array String)

derive instance eqResolvedType :: Eq ResolvedType
derive instance ordResolvedType :: Ord ResolvedType

instance showResolvedType :: Show ResolvedType where
  show (RPrim name) = "RPrim " <> show name
  show (RArray t) = "RArray (" <> show t <> ")"
  show (RRecord fields) = "RRecord " <> show fields
  show (RUnion arms) = "RUnion " <> show arms
  show (RRef lib name args) = "RRef " <> show lib <> " " <> show name <> " " <> show args
  show (RVar path) = "RVar " <> show path

-- | v4-types §10's analysis errors.
data TypeError
  = -- | A name resolved to neither a primitive (the parser already
    -- | classifies those as `TPrim`) nor a declaration in the scope it was
    -- | looked up in.
    UnresolvedType String
  | -- | `$lib.types.X` where `lib` is not bound directly to an
    -- | `import(...)` in the enclosing chain — reached through a lambda, an
    -- | array, a later saturating call, or not bound at all — or where that
    -- | import names a library the table given to `resolveTypeExpr` does not
    -- | contain.
    NotStaticallyResolvable String
  | -- | The root ships a type whose normal form still contains a variable
    -- | (v4-types §4): the resolved id, and the first unresolved path found
    -- | in it.
    PartialType String (Array String)
  | -- | A params key is read both as `$ctx.k` and as `%ctx.k` (v4-types
    -- | §10, roadmap Phase 10).
    TypeParamCollision String
  | -- | A declaration's *arguments* cycle through an import chain that never
    -- | bottoms out — a recursive body alone is never this (v4-types §10).
    TypeCycle String

derive instance eqTypeError :: Eq TypeError

instance showTypeError :: Show TypeError where
  show (UnresolvedType name) = "UnresolvedType " <> show name
  show (NotStaticallyResolvable name) = "NotStaticallyResolvable " <> show name
  show (PartialType tid path) = "PartialType " <> show tid <> " " <> show path
  show (TypeParamCollision k) = "TypeParamCollision " <> show k
  show (TypeCycle k) = "TypeCycle " <> show k

-- | Just the type declarations at the top of a program's own statement chain
-- | (v4-types §1.1), as a lookup table. This is `typeDecls` plus `unlets`
-- | plus `programRoot`, named once because every entry point below needs it
-- | and because a caller resolving several declarations from the same
-- | program should not repeat the walk.
programTypeDecls :: Program -> Map String TypeExpr
programTypeDecls = Map.fromFoldable <<< typeDecls <<< _.statements <<< unlets <<< programRoot

-- | Resolves a `TypeExpr` written somewhere in `prog`'s own statement chain
-- | against `prog`'s own scope: its own declarations for a bare `TName`,
-- | and the libraries in `libs`, reached through `prog`'s own direct
-- | `import(...)` bindings, for a `TLibRef` (v4-types §9's `$lib.types.X`
-- | rule). No library in `libs` is evaluated — this walks parsed programs
-- | only, exactly as `Tramaj.Analysis`'s deep analyses do.
-- |
-- | Structural shapes (`TArray`, `TRecord`, `TUnion`) recurse; `TVar` passes
-- | through unchanged, since `prog`'s own declarations carry no
-- | substitution of their own — only a *reference* to a parameterised
-- | library's declaration, resolved from the referencing side, ever
-- | supplies one (see `resolveWith` below). A `TName` or `TLibRef` resolves
-- | to a `RRef` that carries no expansion of the declaration it names —
-- | v4-types §3's "stop at declaration boundaries" clause, which is what
-- | keeps resolving a self-recursive declaration's own body from looping: a
-- | `TName` occurring inside `Tree`'s own definition, referring to `Tree`
-- | itself, is checked for existence and rendered as a reference, never
-- | expanded.
resolveTypeExpr :: Map String Program -> Program -> TypeExpr -> Either TypeError ResolvedType
resolveTypeExpr libs prog = resolveWith libs prog Map.empty Set.empty

-- | As `resolveTypeExpr`, but under a substitution (`subst`, keyed by a
-- | single-segment `%ctx` variable's name) and a set of library keys
-- | (`visiting`) already being expanded on this chain, for `TypeCycle` to
-- | check against before expanding another. A supplied entry substitutes
-- | structurally — v4-types §6's "supply" — while an unmatched `TVar` stays
-- | a hole, exactly what "forward" (§6) needs when the substitution itself
-- | came from another `%ctx.*` read.
-- |
-- | Only a single-segment path is ever substituted: v4-types has no notion
-- | of projecting into a type parameter, so a longer path is left as a
-- | `RVar` rather than guessing at a meaning the spec does not give it.
resolveWith :: Map String Program -> Program -> Map String ResolvedType -> Set String -> TypeExpr -> Either TypeError ResolvedType
resolveWith libs prog subst visiting = go
  where
  ownDecls :: Map String TypeExpr
  ownDecls = programTypeDecls prog

  ownStmts :: Array Stmt
  ownStmts = (unlets (programRoot prog)).statements

  go :: TypeExpr -> Either TypeError ResolvedType
  go (TPrim name) = Right (RPrim name)
  go (TArray t) = RArray <$> go t
  go (TRecord fields) = RRecord <<< sortByFst <$> traverse resolveField fields
  go (TUnion arms) = RUnion <<< sortByFst <$> traverse resolveArm arms
  go (TVar path) = case path of
    [ k ] -> Right (maybe (RVar path) identity (Map.lookup k subst))
    _ -> Right (RVar path)
  go (TName name)
    | Map.member name ownDecls = Right (RRef Nothing name [])
    | otherwise = Left (UnresolvedType name)
  go (TLibRef libBinding name) = do
    Tuple key (Tuple libProg params) <- resolveLibBinding libs ownStmts libBinding
    if not (Map.member name (programTypeDecls libProg)) then Left (UnresolvedType name)
    else if Set.member key visiting then Left (TypeCycle key)
    else do
      let
        visiting' = Set.insert key visiting
        wanted = Set.map (\path -> maybe "" identity (Array.head path)) (typeParams libProg)
        suppliedTypes = Map.fromFoldable (Array.mapMaybe onlyType params)
        -- Every type parameter the target library has, not only the ones
        -- this import happens to supply: an unsupplied one still needs a
        -- slot in `args`, rendered as its own `RVar`, so a caller
        -- resolving the reference sees the same hole v4-types §3's own
        -- worked example does (`payload=%ctx.p`) rather than the argument
        -- silently vanishing.
        argFor k = case Map.lookup k suppliedTypes of
          Just te -> resolveWith libs prog subst visiting' te
          Nothing -> Right (RVar [ k ])
      args <- sortByFst <$> traverse (\k -> Tuple k <$> argFor k) (Array.fromFoldable wanted)
      pure (RRef (Just key) name args)

  onlyType (Tuple k (PType te)) = Just (Tuple k te)
  onlyType _ = Nothing

  resolveField :: Tuple String TypeExpr -> Either TypeError (Tuple String ResolvedType)
  resolveField (Tuple name t) = Tuple name <$> go t

  resolveArm :: Tuple String (Maybe TypeExpr) -> Either TypeError (Tuple String (Maybe ResolvedType))
  resolveArm (Tuple name mt) = Tuple name <$> traverse go mt

  sortByFst :: forall a. Array (Tuple String a) -> Array (Tuple String a)
  sortByFst = Array.sortWith fst

-- | `lib` must be bound, in `stmts`, directly to an `import("key", ...)` —
-- | not to anything that merely evaluates to one — and `key` must be present
-- | in `libs`. Takes the *last* such binding if `lib` is somehow bound more
-- | than once: an ordinary program never rebinds an import's name, so this
-- | is a simplification rather than a real scoping rule, and nothing here
-- | needs the precise lexical-shadowing behaviour `Let` itself has.
-- |
-- | Returns the resolved `key` and the import's own params alongside the
-- | library's `Program` — roadmap Phase 10 needs the params to build a
-- | `RRef`'s `arguments`, and returning the key rather than just the
-- | `Program` is what keeps a caller from reaching for the wrong identity
-- | (v4-types §1.1: a reference's identity is the import's *table key*, not
-- | the local name `lib` happens to bind it to).
resolveLibBinding :: Map String Program -> Array Stmt -> String -> Either TypeError (Tuple String (Tuple Program (Array (Tuple String ParamValue))))
resolveLibBinding libs stmts lib = case directImportBinding stmts lib of
  Nothing -> Left (NotStaticallyResolvable lib)
  Just (Tuple key params) -> case Map.lookup key libs of
    Nothing -> Left (NotStaticallyResolvable lib)
    Just libProg -> Right (Tuple key (Tuple libProg params))

directImportBinding :: Array Stmt -> String -> Maybe (Tuple String (Array (Tuple String ParamValue)))
directImportBinding stmts lib = Array.last (Array.mapMaybe matching stmts)
  where
  matching (SLet n (Import key params)) | n == lib = Just (Tuple key params)
  matching _ = Nothing

-- | v4-types §3's grammar, rendered. Assumes its argument is already
-- | normalised the way `resolveTypeExpr` produces it — fields, arms and
-- | arguments sorted by name — since this function only renders the order
-- | it is given; it does not sort.
canonicalId :: ResolvedType -> String
canonicalId (RPrim name) = name
canonicalId (RArray t) = "[" <> canonicalId t <> "]"
canonicalId (RRecord fields) = "{" <> intercalateA "," (map renderField fields) <> "}"
  where
  renderField (Tuple name t) = name <> ":" <> canonicalId t
canonicalId (RUnion arms) = intercalateA "" (map renderArm arms)
  where
  renderArm (Tuple name Nothing) = "|" <> name
  renderArm (Tuple name (Just t)) = "|" <> name <> " " <> canonicalId t
canonicalId (RRef lib name args) =
  renderLibrary lib <> ":" <> name <> if Array.null args then "" else "[" <> intercalateA "," (map renderArg args) <> "]"
  where
  renderArg (Tuple k t) = k <> "=" <> canonicalId t
-- | `RVar`'s path, like `Demand`'s, excludes the leading `ctx` segment it is
-- | always rooted at -- `Tramaj.Ast`'s `Demand` and `Tramaj.Eval`'s
-- | `evalDemand`'s `sid = "#ctx" <> ...` are the value-domain precedent this
-- | mirrors, with `%` standing in for `#` since this is the type realm, not
-- | the symbol one -- so it is reinserted here to render v4-types §3's
-- | `var ::= "%" path`, whose own worked example (`payload=%ctx.p`) spells
-- | it out in full.
canonicalId (RVar path) = "%ctx" <> Array.foldl (\acc s -> acc <> "." <> s) "" path

intercalateA :: String -> Array String -> String
intercalateA sep = Array.foldl step ""
  where
  step "" s = s
  step acc s = acc <> sep <> s

-- | See the module header for why a real library is quoted and "no library"
-- | is the one bareword no quoted key can equal.
renderLibrary :: Maybe String -> String
renderLibrary Nothing = "root"
renderLibrary (Just key) = "\"" <> key <> "\""

-- | Whether a normal form still contains a `RVar` anywhere — inside a
-- | `RRef`'s own arguments included, since an unfilled argument is exactly
-- | as partial as a bare hole (v4-types §4).
containsVar :: ResolvedType -> Boolean
containsVar (RVar _) = true
containsVar (RArray t) = containsVar t
containsVar (RRecord fields) = Array.any (containsVar <<< snd) fields
containsVar (RUnion arms) = Array.any (maybe false containsVar <<< snd) arms
containsVar (RRef _ _ args) = Array.any (containsVar <<< snd) args
containsVar (RPrim _) = false

-- | The path of the first `RVar` found, left-to-right — what `PartialType`
-- | reports alongside the id, so the error names a concrete hole rather
-- | than only the type that has one. Partial: only ever called on a type
-- | `containsVar` has already confirmed has one.
firstVarPath :: ResolvedType -> Array String
firstVarPath (RVar path) = path
firstVarPath (RArray t) = firstVarPath t
firstVarPath (RRecord fields) = case Array.filter (containsVar <<< snd) fields of
  entries -> case Array.head entries of
    Just (Tuple _ t) -> firstVarPath t
    Nothing -> unreachable unit
firstVarPath (RUnion arms) = case Array.head (Array.mapMaybe onlyVarArm arms) of
  Just t -> firstVarPath t
  Nothing -> unreachable unit
  where
  onlyVarArm (Tuple _ (Just t)) | containsVar t = Just t
  onlyVarArm _ = Nothing
firstVarPath (RRef _ _ args) = case Array.head (Array.filter (containsVar <<< snd) args) of
  Just (Tuple _ t) -> firstVarPath t
  Nothing -> unreachable unit
firstVarPath (RPrim _) = unreachable unit

-- | Takes a `Unit` argument, unlike Haskell's lazily-thunked `error`,
-- | because PureScript evaluates a nullary top-level binding eagerly, at
-- | module load -- so a bare `unreachable = unsafeCrashWith ...` would
-- | crash on import, unconditionally, rather than only when actually
-- | reached.
unreachable :: forall a. Unit -> a
unreachable _ = unsafeCrashWith "unreachable: firstVarPath called on a type with no variable"

-- | v4-types §4: a type reaching the root — an annotation (roadmap Phase
-- | 11), the closure of a program's own output (Phase 13) — must be closed.
-- | Everything else may stay partial; only a caller at the root need ever
-- | call this.
requireClosed :: ResolvedType -> Either TypeError ResolvedType
requireClosed rt
  | containsVar rt = Left (PartialType (canonicalId rt) (firstVarPath rt))
  | otherwise = Right rt

-- | v4-types §10's `TypeParamCollision`, surfaced as a proper `TypeError`
-- | from `Tramaj.Analysis.typeParamCollisions`' plain `Data.Set.Set`.
-- | Reports the first colliding key found, the way every other check here
-- | reports one concrete failure rather than the whole set.
checkTypeParamCollisions :: Program -> Either TypeError Unit
checkTypeParamCollisions prog = case Array.head (Array.fromFoldable (typeParamCollisions prog)) of
  Just k -> Left (TypeParamCollision k)
  Nothing -> Right unit

-- Output: the transitive closure of referenced types (v4-types §8, roadmap
-- Phase 13) --------------------------------------------------------------

-- | Every `RRef` reachable from a resolved type, including inside another
-- | `RRef`'s own arguments — what a caller must expand to build the
-- | `"types"` table's next layer.
collectRefs :: ResolvedType -> Array ResolvedType
collectRefs r@(RRef _ _ args) = Array.cons r (Array.concatMap (collectRefs <<< snd) args)
collectRefs (RArray t) = collectRefs t
collectRefs (RRecord fields) = Array.concatMap (collectRefs <<< snd) fields
collectRefs (RUnion arms) = Array.concatMap (maybe [] collectRefs <<< snd) arms
collectRefs (RPrim _) = []
collectRefs (RVar _) = []

-- | The program and raw declaration body a `RRef` names — `Nothing` means
-- | `prog` itself (v4-types §1.1); `Just key` means whatever program `key`
-- | names in `libs`, exactly as `resolveLibBinding` would have found it,
-- | but starting from the resolved reference rather than the syntax that
-- | produced it.
lookupDecl :: Map String Program -> Program -> Maybe String -> String -> Either TypeError (Tuple Program TypeExpr)
lookupDecl _ prog Nothing name =
  maybe (Left (UnresolvedType name)) (\t -> Right (Tuple prog t)) (Map.lookup name (programTypeDecls prog))
lookupDecl libs _ (Just key) name = case Map.lookup key libs of
  Nothing -> Left (NotStaticallyResolvable key)
  Just libProg -> maybe (Left (UnresolvedType name)) (\t -> Right (Tuple libProg t)) (Map.lookup name (programTypeDecls libProg))

-- | The transitive closure of every type referenced from `roots` (v4-types
-- | §8): a record's field types, a union's payloads, and theirs, cut by id
-- | so a cycle terminates. Each `RRef` found is expanded exactly once — its
-- | declaration's own body, resolved under the substitution its arguments
-- | supply — which is the one place in this module a declaration boundary
-- | *is* crossed, because the output table is precisely where a host needs
-- | the definition behind an id, not merely the id.
-- |
-- | Keyed by canonical id rather than by `(library, name)`: two
-- | applications of the same generic library at different arguments are
-- | two different entries, exactly as §3 says they are two different
-- | types.
typeClosure :: Map String Program -> Program -> Array ResolvedType -> Either TypeError (Map String ResolvedType)
typeClosure libs prog roots = go Map.empty (Array.concatMap collectRefs roots)
  where
  go :: Map String ResolvedType -> Array ResolvedType -> Either TypeError (Map String ResolvedType)
  go acc rs = case Array.uncons rs of
    Nothing -> Right acc
    Just { head: r@(RRef libKey name args), tail: rest }
      | Map.member (canonicalId r) acc -> go acc rest
      | otherwise -> do
          Tuple declProg declBody <- lookupDecl libs prog libKey name
          def <- resolveWith libs declProg (Map.fromFoldable args) Set.empty declBody
          go (Map.insert (canonicalId r) def acc) (rest <> collectRefs def)
    Just { tail: rest } -> go acc rest

-- Erasure (v4-types §7, roadmap Phase 11) --------------------------------

-- | Rewrites every `TypeAnnotate` in `prog` into the `Let` plus `Emit` §7
-- | specifies, resolving and closing its type first (an annotation whose
-- | type is partial is `PartialType`, per §7's own note that this is what
-- | makes erasure safe). Everything else is rebuilt unchanged; a
-- | `TypeDecl` and a resolved `TypeEmit` are left in place rather than
-- | stripped, since both are already inert to `Tramaj.Eval.evalExpr` —
-- | only `TypeAnnotate` produces something the evaluator cannot already
-- | ignore on its own.
-- |
-- | Run once, up front, by every one of `Tramaj.Eval`'s entry points
-- | (including a library, the moment it loads) rather than baked into
-- | evaluation itself — this is what keeps `Value` free of a type
-- | constructor and the whole §1.5 `NotConcrete` table untouched: by the
-- | time `Tramaj.Eval.evalExpr` runs, there is no `TypeAnnotate` left for
-- | it to match, and the byte-identical-to-annotations-deleted invariant
-- | §8 asks for follows from erasure alone, nothing evaluation-specific.
eraseTypes :: Map String Program -> Program -> Either TypeError Program
eraseTypes libs prog = do
  root' <- eraseExpr libs prog (programRoot prog)
  pure case prog of
    DocumentProgram _ -> DocumentProgram root'
    ExpressionProgram _ -> ExpressionProgram root'

eraseExpr :: Map String Program -> Program -> Expr -> Either TypeError Expr
eraseExpr libs prog = go
  where
  go :: Expr -> Either TypeError Expr
  go e@(Path _ _) = pure e
  go (FieldAccess target fields) = (\t -> FieldAccess t fields) <$> go target
  go (Call fn args) = Call <$> go fn <*> traverse go args
  go (Lambda params body) = Lambda params <$> go body
  go (Let name value body) = Let name <$> go value <*> go body
  go e@(StringLit _) = pure e
  go e@(NumberLit _) = pure e
  go e@(BoolLit _) = pure e
  go NullLit = pure NullLit
  go (ArrayLit elems) = ArrayLit <$> traverse go elems
  go (ObjectLit entries) = ObjectLit <$> traverse (\(Tuple k e) -> Tuple k <$> go e) entries
  go (Element tag attrs val children) =
    Element tag <$> traverse goAttr attrs <*> go val <*> traverse go children
  go (Fragment children) = Fragment <$> traverse go children
  go (Branch c t e) = Branch <$> go c <*> go t <*> go e
  go (Map coll fn) = Map <$> go coll <*> go fn
  go (Filter coll fn) = Filter <$> go coll <*> go fn
  go (Scan coll initial fn) = Scan <$> go coll <*> go initial <*> go fn
  go (Fold coll initial fn) = Fold <$> go coll <*> go initial <*> go fn
  go (Concat l r) = Concat <$> go l <*> go r
  go (Import name params) = Import name <$> traverse goParam params
  go (AdaptActions target adaptation fn) = AdaptActions <$> go target <*> pure adaptation <*> traverse go fn
  go (Constrain name args) = Constrain name <$> traverse go args
  go (Emit constraint body) = Emit <$> go constraint <*> go body
  go (Alloc site keyExpr) = Alloc site <$> go keyExpr
  go e@(Demand _) = pure e
  go (TypeDecl name t body) = TypeDecl name t <$> go body
  go (TypeAnnotate name t valueExpr body) = do
    rt <- resolveTypeExpr libs prog t >>= requireClosed
    value' <- go valueExpr
    body' <- go body
    let hasType = Constrain "has-type" [ Path name [], ObjectLit [ Tuple "$type" (StringLit (canonicalId rt)) ] ]
    pure (Let name value' (Emit hasType body'))
  go (TypeEmit _ _ body) = go body

  goAttr (Attr name e) = Attr name <$> go e
  goAttr (ActionAttr event key e) = ActionAttr event key <$> go e

  goParam (Tuple k (PExpr e)) = Tuple k <<< PExpr <$> go e
  goParam kv@(Tuple _ (PFromContext _)) = pure kv
  goParam kv@(Tuple _ (PType _)) = pure kv

-- Type constraints (v4-types §5, roadmap Phase 12) -----------------------

-- | A resolved `!type-constraint` argument: a type, or one of the four
-- | scalar shapes §5 allows — the type-realm counterpart of the
-- | already-evaluated `Value` a v3 constraint's argument becomes.
data ResolvedConstraintArg
  = RCType ResolvedType
  | RCScalarStr String
  | RCScalarNum Number
  | RCScalarBool Boolean
  | RCScalarNull

derive instance eqResolvedConstraintArg :: Eq ResolvedConstraintArg
derive instance ordResolvedConstraintArg :: Ord ResolvedConstraintArg

instance showResolvedConstraintArg :: Show ResolvedConstraintArg where
  show (RCType t) = "RCType (" <> show t <> ")"
  show (RCScalarStr s) = "RCScalarStr " <> show s
  show (RCScalarNum n) = "RCScalarNum " <> show n
  show (RCScalarBool b) = "RCScalarBool " <> show b
  show RCScalarNull = "RCScalarNull"

resolveConstraintArg :: Map String Program -> Program -> TypeConstraintArg -> Either TypeError ResolvedConstraintArg
resolveConstraintArg libs prog (TCType t) = RCType <$> resolveTypeExpr libs prog t
resolveConstraintArg _ _ (TCScalarStr s) = Right (RCScalarStr s)
resolveConstraintArg _ _ (TCScalarNum n) = Right (RCScalarNum n)
resolveConstraintArg _ _ (TCScalarBool b) = Right (RCScalarBool b)
resolveConstraintArg _ _ TCScalarNull = Right RCScalarNull

-- | Every `!type-constraint` this program's own statement chain collects
-- | (v4-types §5), each argument resolved, deduplicated by name and
-- | already-resolved arguments — the same "first position kept" rule v3
-- | §4 uses for value constraints, applied here because instantiation
-- | (substitution through a supplied argument) can make two differently
-- | written constraints collide the same way two differently written value
-- | constraints can.
typeConstraints :: Map String Program -> Program -> Either TypeError (Array (Tuple String (Array ResolvedConstraintArg)))
typeConstraints libs prog = do
  raw <- traverse resolveOne (everywhereIn collectTypeEmits prog)
  pure (dedupeFirst raw)
  where
  collectTypeEmits (TypeEmit name args _) = [ Tuple name args ]
  collectTypeEmits _ = []
  resolveOne (Tuple name args) = Tuple name <$> traverse (resolveConstraintArg libs prog) args

-- | `typeConstraints`, over-approximated by following every transitively
-- | imported library (roadmap Phase 12/14) — the type-constraint analogue
-- | of `Tramaj.Analysis.deepConstraintKinds`: a constraint written inside a
-- | library that this program imports is reported whether or not the
-- | program's own evaluation would ever force that library, since a
-- | `!type-constraint` is never evaluated in the first place and so has no
-- | notion of "reached" to restrict it by.
deepTypeConstraints :: Map String Program -> Program -> Either TypeError (Array (Tuple String (Array ResolvedConstraintArg)))
deepTypeConstraints libs prog = do
  own <- typeConstraints libs prog
  fromLibs <- Array.concat <$> traverse fromLib (Array.fromFoldable (transitiveImportNames libs prog))
  pure (dedupeFirst (own <> fromLibs))
  where
  fromLib name = maybe (Right []) (typeConstraints libs) (Map.lookup name libs)

dedupeFirst :: forall a. Eq a => Array a -> Array a
dedupeFirst = go []
  where
  go seen xs = case Array.uncons xs of
    Nothing -> []
    Just { head, tail }
      | Array.any (_ == head) seen -> go seen tail
      | otherwise -> Array.cons head (go (Array.cons head seen) tail)

-- Type references (v4-types §9, roadmap Phase 14) ------------------------

-- | Every type this program's own statement chain refers to, normalised to
-- | its canonical id (v4-types §9: "which it refers to, normalised") —
-- | every declaration, annotation and type-constraint argument's own type,
-- | resolved. An unresolvable reference is reported rather than skipped
-- | (§9's closing rule), which is exactly what `resolveTypeExpr` already
-- | does by returning an `Either`.
typeReferences :: Map String Program -> Program -> Either TypeError (Set String)
typeReferences libs prog = Set.fromFoldable <<< map canonicalId <$> programTypeRoots libs prog

-- | Every `TypeExpr` sitting in a type-bearing position of `prog`'s own
-- | syntax — a declaration's body, an annotation's type, a type
-- | constraint's type-marked arguments, an import's `%`-marked param
-- | (v4-types §2, §5, §7, §9) — resolved. This is `typeReferences` before
-- | the last step that throws the structure away down to a set of ids;
-- | `Tramaj.Eval` needs the structure itself to build the `"types"` output
-- | table's closure (v4-types §8, roadmap Phase 13), and `typeReferences`
-- | needs only the ids.
programTypeRoots :: Map String Program -> Program -> Either TypeError (Array ResolvedType)
programTypeRoots libs prog = traverse (resolveTypeExpr libs prog) (everywhereIn typeExprsIn prog)

-- | `typeReferences`, following every transitively imported library — the
-- | type-realm analogue of `Tramaj.Analysis.deepContextHoles`.
deepTypeReferences :: Map String Program -> Program -> Either TypeError (Set String)
deepTypeReferences libs prog = do
  own <- typeReferences libs prog
  fromLibs <- traverse fromLib (Array.fromFoldable (transitiveImportNames libs prog))
  pure (Set.unions (Array.cons own fromLibs))
  where
  fromLib name = maybe (Right Set.empty) (typeReferences libs) (Map.lookup name libs)
