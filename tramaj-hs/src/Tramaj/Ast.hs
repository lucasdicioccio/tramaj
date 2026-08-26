-- | Core types for the tramaj language: unevaluated computation-phase
-- expressions ('Expr'), unevaluated template-phase nodes ('TemplateNode'),
-- and the evaluated output AST ('Node') a host folds into its own render
-- target (Halogen HTML for the PureScript sibling; here, just 'nodeToJson'
-- for a JSON preview). Deliberately kept in lockstep with
-- @../tramaj/src/Tramaj/Ast.purs@ -- see that file's Haddock-style
-- comments for the full grammar rationale; comments here only cover
-- Haskell-specific differences (aeson 'Value' instead of argonaut 'Json',
-- 'HashMap'/'Map' instead of 'Foreign.Object'/'Data.Map').
module Tramaj.Ast
  ( Expr (..)
  , KeySpec (..)
  , StringPart (..)
  , TAction (..)
  , ActionPayload (..)
  , TemplateNode (..)
  , Node (..)
  , Program (..)
  , JsonProgram (..)
  , nodeToJson
  , actionPayloadToJson
  , staticImportNames
  , staticActionKeys
  ) where

import Data.Aeson (Value (..), object, (.=))
import Data.Map.Strict (Map)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Vector as V

-- | A dotted path, e.g. @$ctx.items@ is @Path ["ctx", "items"]@ and a bound
-- computation name @$count@ is @Path ["count"]@. See the PureScript
-- sibling's Haddock for the full 'Call'/'LambdaExpr'/'MapExpr'/'FilterExpr'/
-- 'ScanExpr' rationale -- unchanged here.
data Expr
  = Path [Text]
  | Call [Text] [Expr]
  | StringLit [StringPart]
  | NumberLit Double
  | BoolLit Bool
  | ArrayLit [Expr]
  | ObjectLit [(Text, Expr)]
  | LambdaExpr [Text] Expr
  | MapExpr Expr Expr
  | FilterExpr Expr Expr
  | ScanExpr Expr Expr Expr
  | FoldExpr Expr Expr Expr
  | ImportExpr Text Expr
  | PartialImportExpr Text Expr
  | FieldAccess Expr [Text]
  | RemapActionsExpr Expr KeySpec Expr
  deriving stock (Eq, Show)

-- | The key-rewriting operation @remap-actions(...)@'s second argument
-- names -- currently just @prefix(prefixExpr)@. See the PureScript
-- sibling's Haddock on 'Tramaj.Ast.RemapActionsExpr' for the rationale.
newtype KeySpec = KeyPrefix Expr
  deriving stock (Eq, Show)

-- | One piece of a double-quoted string literal: either literal text or a
-- backtick-delimited interpolation of an arbitrary 'Expr'.
data StringPart
  = Lit Text
  | Interp Expr
  deriving stock (Eq, Show)

-- | @action(eventType, key, payloadExpr)@ -- see the PureScript sibling's
-- 'TAction' Haddock for why @eventType@\/@payload@ are ordinary 'Expr's
-- (not a fixed keyword) while @key@ is a bare 'Text', not an 'Expr' --
-- same static-literal treatment as 'ImportExpr'\/'PartialImportExpr'\'s
-- name.
data TAction = TAction Expr Text Expr
  deriving stock (Eq, Show)

-- | The evaluated result of a 'TAction'. Structured, not an opaque string --
-- a host dispatcher can pattern-match 'key' and use 'payload' directly.
data ActionPayload = ActionPayload
  { apEventType :: Text
  , apKey :: Text
  , apPayload :: Value
  }
  deriving stock (Eq, Show)

-- | Unevaluated template-phase AST -- see the PureScript sibling's
-- 'TemplateNode' Haddock for the full attrs/action/children splitting
-- rationale and 'TMap'/'TBranch' semantics.
data TemplateNode
  = TElement Text [(Text, Expr)] (Maybe TAction) [TemplateNode]
  | TValue Expr
  | TMap Expr Text TemplateNode
  | TBranch TemplateNode [(Expr, TemplateNode)]
  deriving stock (Eq, Show)

-- | Evaluated output -- no 'Expr'/paths left, and no host-rendering
-- dependency (no Halogen here, since this package never renders to a
-- browser DOM -- see 'nodeToJson').
data Node
  = NElement
      { neTag :: Text
      , neAttrs :: Map Text Text
      , neAction :: Maybe ActionPayload
      , neChildren :: [Node]
      }
  | NText Text
  deriving stock (Eq, Show)

-- | A parsed program: computation-block bindings evaluated once in
-- declaration order, plus the single template-block root node.
data Program = Program
  { progBindings :: [(Text, Expr)]
  , progRoot :: TemplateNode
  }
  deriving stock (Eq, Show)

-- | A parsed program whose root is an ordinary 'Expr' rather than a
-- 'TemplateNode' -- same computation block, same expression language, but it
-- evaluates to a JSON 'Value' instead of a document tree (see
-- 'Tramaj.Eval.evalJsonProgram'). For hosts that want the data half of
-- the language on its own: generating a JSON payload, not a document.
--
-- Haskell-only for now; @../tramaj@ has no counterpart.
data JsonProgram = JsonProgram
  { jpBindings :: [(Text, Expr)]
  , jpRoot :: Expr
  }
  deriving stock (Eq, Show)

-- | Renders the evaluated 'Node' tree as plain JSON 'Value' -- the preview
-- format an LLM/agent integrator gets back from the render-template
-- endpoint (see @ControlPlane.API.Handlers.handleRenderTemplate@), mirroring
-- the PureScript sibling's own debugging/inspection @nodeToJson@ exactly
-- (same three-key element shape, same @null@-when-absent action). Actually
-- *dispatching* an action (deciding what a click does) is a host concern
-- this package never performs -- an endpoint calling this only needs to
-- hand back the structured 'ActionPayload' verbatim, not interpret it.
nodeToJson :: Node -> Value
nodeToJson (NText s) =
  object ["type" .= ("text" :: Text), "text" .= s]
nodeToJson (NElement {neTag, neAttrs, neAction, neChildren}) =
  object
    [ "type" .= ("element" :: Text)
    , "tag" .= neTag
    , "attrs" .= neAttrs
    , "action" .= maybe Null actionPayloadToJson neAction
    , "children" .= V.fromList (map nodeToJson neChildren)
    ]

-- | The @{eventType, key, payload}@ shape an 'ActionPayload' takes as JSON --
-- used both by 'nodeToJson' above and by 'Tramaj.Eval'\'s
-- @remap-actions@ (where a template-level closure receives\/returns exactly
-- this shape to rewrite an imported node's actions before they bubble up).
actionPayloadToJson :: ActionPayload -> Value
actionPayloadToJson (ActionPayload {apEventType, apKey, apPayload}) =
  object ["eventType" .= apEventType, "key" .= apKey, "payload" .= apPayload]

-- | Every import\/partial-import name statically referenced anywhere in a
-- parsed program -- the computation-block bindings and the template-block
-- root, recursively through every nested 'Expr'\/'TemplateNode' -- without
-- evaluating anything. Mirrors the PureScript sibling's
-- @Tramaj.Ast.staticImportNames@ exactly.
staticImportNames :: Program -> Set Text
staticImportNames (Program {progBindings, progRoot}) =
  foldMap (importNamesInExpr . snd) progBindings <> importNamesInNode progRoot

importNamesInExpr :: Expr -> Set Text
importNamesInExpr (Path _) = Set.empty
importNamesInExpr (Call _ args) = foldMap importNamesInExpr args
importNamesInExpr (StringLit parts) = foldMap importNamesInStringPart parts
importNamesInExpr (NumberLit _) = Set.empty
importNamesInExpr (BoolLit _) = Set.empty
importNamesInExpr (ArrayLit elems) = foldMap importNamesInExpr elems
importNamesInExpr (ObjectLit entries) = foldMap (importNamesInExpr . snd) entries
importNamesInExpr (LambdaExpr _ body) = importNamesInExpr body
importNamesInExpr (MapExpr arr fn) = importNamesInExpr arr <> importNamesInExpr fn
importNamesInExpr (FilterExpr arr fn) = importNamesInExpr arr <> importNamesInExpr fn
importNamesInExpr (ScanExpr arr initE fn) = importNamesInExpr arr <> importNamesInExpr initE <> importNamesInExpr fn
importNamesInExpr (FoldExpr arr initE fn) = importNamesInExpr arr <> importNamesInExpr initE <> importNamesInExpr fn
importNamesInExpr (ImportExpr name paramsE) = Set.insert name (importNamesInExpr paramsE)
importNamesInExpr (PartialImportExpr name paramsE) = Set.insert name (importNamesInExpr paramsE)
importNamesInExpr (FieldAccess baseE _) = importNamesInExpr baseE
importNamesInExpr (RemapActionsExpr nodeE keySpec fnE) = importNamesInExpr nodeE <> importNamesInKeySpec keySpec <> importNamesInExpr fnE

importNamesInKeySpec :: KeySpec -> Set Text
importNamesInKeySpec (KeyPrefix e) = importNamesInExpr e

importNamesInStringPart :: StringPart -> Set Text
importNamesInStringPart (Lit _) = Set.empty
importNamesInStringPart (Interp e) = importNamesInExpr e

importNamesInNode :: TemplateNode -> Set Text
importNamesInNode (TElement _ attrs action children) =
  foldMap (importNamesInExpr . snd) attrs
    <> foldMap importNamesInTAction action
    <> foldMap importNamesInNode children
importNamesInNode (TValue e) = importNamesInExpr e
importNamesInNode (TMap arr _ body) = importNamesInExpr arr <> importNamesInNode body
importNamesInNode (TBranch fallback pairs) =
  importNamesInNode fallback
    <> foldMap (\(predE, node) -> importNamesInExpr predE <> importNamesInNode node) pairs

importNamesInTAction :: TAction -> Set Text
importNamesInTAction (TAction eventTypeExpr _key payloadExpr) =
  importNamesInExpr eventTypeExpr <> importNamesInExpr payloadExpr

-- | Every @action(...)@ key statically referenced anywhere in a parsed
-- program. Mirrors the PureScript sibling's
-- @Tramaj.Ast.staticActionKeys@ exactly.
staticActionKeys :: Program -> Set Text
staticActionKeys (Program {progBindings, progRoot}) =
  foldMap (actionKeysInExpr . snd) progBindings <> actionKeysInNode progRoot

actionKeysInExpr :: Expr -> Set Text
actionKeysInExpr (Path _) = Set.empty
actionKeysInExpr (Call _ args) = foldMap actionKeysInExpr args
actionKeysInExpr (StringLit parts) = foldMap actionKeysInStringPart parts
actionKeysInExpr (NumberLit _) = Set.empty
actionKeysInExpr (BoolLit _) = Set.empty
actionKeysInExpr (ArrayLit elems) = foldMap actionKeysInExpr elems
actionKeysInExpr (ObjectLit entries) = foldMap (actionKeysInExpr . snd) entries
actionKeysInExpr (LambdaExpr _ body) = actionKeysInExpr body
actionKeysInExpr (MapExpr arr fn) = actionKeysInExpr arr <> actionKeysInExpr fn
actionKeysInExpr (FilterExpr arr fn) = actionKeysInExpr arr <> actionKeysInExpr fn
actionKeysInExpr (ScanExpr arr initE fn) = actionKeysInExpr arr <> actionKeysInExpr initE <> actionKeysInExpr fn
actionKeysInExpr (FoldExpr arr initE fn) = actionKeysInExpr arr <> actionKeysInExpr initE <> actionKeysInExpr fn
actionKeysInExpr (ImportExpr _name paramsE) = actionKeysInExpr paramsE
actionKeysInExpr (PartialImportExpr _name paramsE) = actionKeysInExpr paramsE
actionKeysInExpr (FieldAccess baseE _) = actionKeysInExpr baseE
actionKeysInExpr (RemapActionsExpr nodeE keySpec fnE) = actionKeysInExpr nodeE <> actionKeysInKeySpec keySpec <> actionKeysInExpr fnE

actionKeysInKeySpec :: KeySpec -> Set Text
actionKeysInKeySpec (KeyPrefix e) = actionKeysInExpr e

actionKeysInStringPart :: StringPart -> Set Text
actionKeysInStringPart (Lit _) = Set.empty
actionKeysInStringPart (Interp e) = actionKeysInExpr e

actionKeysInNode :: TemplateNode -> Set Text
actionKeysInNode (TElement _ attrs action children) =
  foldMap (actionKeysInExpr . snd) attrs
    <> foldMap actionKeysInTAction action
    <> foldMap actionKeysInNode children
actionKeysInNode (TValue e) = actionKeysInExpr e
actionKeysInNode (TMap arr _ body) = actionKeysInExpr arr <> actionKeysInNode body
actionKeysInNode (TBranch fallback pairs) =
  actionKeysInNode fallback
    <> foldMap (\(predE, node) -> actionKeysInExpr predE <> actionKeysInNode node) pairs

actionKeysInTAction :: TAction -> Set Text
actionKeysInTAction (TAction eventTypeExpr key payloadExpr) =
  Set.insert key (actionKeysInExpr eventTypeExpr <> actionKeysInExpr payloadExpr)
