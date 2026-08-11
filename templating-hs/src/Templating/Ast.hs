-- | Core types for the templating language: unevaluated computation-phase
-- expressions ('Expr'), unevaluated template-phase nodes ('TemplateNode'),
-- and the evaluated output AST ('Node') a host folds into its own render
-- target (Halogen HTML for the PureScript sibling; here, just 'nodeToJson'
-- for a JSON preview). Deliberately kept in lockstep with
-- @../templating/src/Templating/Ast.purs@ -- see that file's Haddock-style
-- comments for the full grammar rationale; comments here only cover
-- Haskell-specific differences (aeson 'Value' instead of argonaut 'Json',
-- 'HashMap'/'Map' instead of 'Foreign.Object'/'Data.Map').
module Templating.Ast
  ( Expr (..)
  , StringPart (..)
  , TAction (..)
  , ActionPayload (..)
  , TemplateNode (..)
  , Node (..)
  , Program (..)
  , JsonProgram (..)
  , nodeToJson
  ) where

import Data.Aeson (Value (..), object, (.=))
import Data.Map.Strict (Map)
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
  deriving stock (Eq, Show)

-- | One piece of a double-quoted string literal: either literal text or a
-- backtick-delimited interpolation of an arbitrary 'Expr'.
data StringPart
  = Lit Text
  | Interp Expr
  deriving stock (Eq, Show)

-- | @action(eventType, keyExpr, payloadExpr)@ -- see the PureScript
-- sibling's 'TAction' Haddock for why all three positions are ordinary
-- 'Expr's, not a fixed keyword.
data TAction = TAction Expr Expr Expr
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
-- 'Templating.Eval.evalJsonProgram'). For hosts that want the data half of
-- the language on its own: generating a JSON payload, not a document.
--
-- Haskell-only for now; @../templating@ has no counterpart.
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
    , "action" .= maybe Null actionToJson neAction
    , "children" .= V.fromList (map nodeToJson neChildren)
    ]
  where
    actionToJson :: ActionPayload -> Value
    actionToJson (ActionPayload {apEventType, apKey, apPayload}) =
      object ["eventType" .= apEventType, "key" .= apKey, "payload" .= apPayload]
