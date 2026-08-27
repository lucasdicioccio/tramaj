-- | The evaluated document representation -- Tramaj's output domain and its
-- portable interchange boundary. 'nodeToJson'\/'nodeFromJson' implement the
-- normative representation specified in @../specs/node-json.md@; that
-- document, not this module, is the contract other implementations and hosts
-- are held to.
--
-- Deliberately independent of both the expression AST ("Tramaj.Ast") and of
-- any particular render target: a host folds a 'Node' into HTML, a UI tree,
-- YAML, HCL or anything else on its own terms.
module Tramaj.Node
  ( Node (..)
  , NodeAttribute (..)
  , Annotations
  , noAnnotations
  , nodeToJson
  , nodeFromJson
  , nodeAttributeToJson
  , mapActions
  ) where

import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Vector as V

-- | Arbitrary host\/tooling metadata hung off any node. The core language
-- assigns no meaning to any key; unknown annotations must not affect
-- semantics, and every node-to-node transformation must carry them through
-- unchanged. This is where a future type\/domain\/constraint pass puts what
-- it derives, without the 'Node' constructors having to change.
type Annotations = Map Text Value

noAnnotations :: Annotations
noAnnotations = Map.empty

-- | Three constructors, with enough expressivity inside them to carry
-- scalars losslessly -- see @../specs/decisions.md@ #5.
--
-- 'NText' holds a 'Value', not a 'Text': @.p($ctx.count)@ with @count = 3@
-- keeps the number @3@ rather than stringifying it. Rendering a scalar to
-- characters is a host decision, so the interchange format declines to make
-- it.
--
-- 'NElement' holds a @value@ slot alongside its children, for targets that
-- attach a body value to a tagged node (a YAML\/HCL scalar leaf, a config
-- value); it is 'Null' unless a template sets one. Its attributes are an
-- ordered list rather than a map: an element may carry any number of
-- attributes /and/ any number of actions, and source order is preserved.
--
-- 'NFragment' is a real node here -- an ordered sibling sequence with no
-- wrapper element. A host may flatten fragments when folding; evaluation
-- does not.
data Node
  = NText Value Annotations
  | NElement Text [NodeAttribute] Value [Node] Annotations
  | NFragment [Node] Annotations
  deriving stock (Eq, Show)

-- | Both attribute-position constructs, sharing one list. An action's
-- @event@ and @key@ are plain 'Text' because both are static in the source
-- AST (see "Tramaj.Ast"); only the payload is computed.
data NodeAttribute
  = NAttr Text Value
  | NAction Text Text Value
  deriving stock (Eq, Show)

-- Serialization -----------------------------------------------------------

-- | Encodes to the normative representation. Every field is always emitted,
-- including an empty @annotations@ and a @null@ element @value@ -- see
-- @../specs/node-json.md@, "Decoding": on the wire a missing field is a bug,
-- not a default.
nodeToJson :: Node -> Value
nodeToJson (NText v anns) =
  object ["type" .= ("text" :: Text), "value" .= v, "annotations" .= annotationsToJson anns]
nodeToJson (NElement tag attrs val children anns) =
  object
    [ "type" .= ("element" :: Text)
    , "tag" .= tag
    , "attributes" .= V.fromList (map nodeAttributeToJson attrs)
    , "value" .= val
    , "children" .= V.fromList (map nodeToJson children)
    , "annotations" .= annotationsToJson anns
    ]
nodeToJson (NFragment children anns) =
  object
    [ "type" .= ("fragment" :: Text)
    , "children" .= V.fromList (map nodeToJson children)
    , "annotations" .= annotationsToJson anns
    ]

nodeAttributeToJson :: NodeAttribute -> Value
nodeAttributeToJson (NAttr name val) =
  object ["kind" .= ("attribute" :: Text), "name" .= name, "value" .= val]
nodeAttributeToJson (NAction event key payload) =
  object ["kind" .= ("action" :: Text), "event" .= event, "key" .= key, "payload" .= payload]

annotationsToJson :: Annotations -> Value
annotationsToJson = Object . KeyMap.fromList . map (\(k, v) -> (Key.fromText k, v)) . Map.toList

-- | Decodes the normative representation, strictly: a missing or
-- ill-typed field is an error rather than a silently-defaulted value, so
-- @nodeFromJson . nodeToJson@ round-trips and a malformed document is
-- reported where it is read rather than where it later misbehaves. The
-- 'Left' carries a human-readable path-ish description of what was wrong.
nodeFromJson :: Value -> Either String Node
nodeFromJson (Object obj) = do
  ty <- reqString "node" "type" obj
  case ty of
    "text" -> do
      v <- req "text node" "value" obj
      anns <- reqAnnotations obj
      pure (NText v anns)
    "element" -> do
      tag <- reqString "element node" "tag" obj
      attrs <- reqArray "element node" "attributes" obj >>= traverse nodeAttributeFromJson
      val <- req "element node" "value" obj
      children <- reqArray "element node" "children" obj >>= traverse nodeFromJson
      anns <- reqAnnotations obj
      pure (NElement tag attrs val children anns)
    "fragment" -> do
      children <- reqArray "fragment node" "children" obj >>= traverse nodeFromJson
      anns <- reqAnnotations obj
      pure (NFragment children anns)
    other -> Left ("unknown node type: " <> show other)
nodeFromJson _ = Left "expected a JSON object for a node"

nodeAttributeFromJson :: Value -> Either String NodeAttribute
nodeAttributeFromJson (Object obj) = do
  kind <- reqString "node attribute" "kind" obj
  case kind of
    "attribute" -> NAttr <$> reqString "attribute" "name" obj <*> req "attribute" "value" obj
    "action" ->
      NAction
        <$> reqString "action" "event" obj
        <*> reqString "action" "key" obj
        <*> req "action" "payload" obj
    other -> Left ("unknown node attribute kind: " <> show other)
nodeAttributeFromJson _ = Left "expected a JSON object for a node attribute"

req :: String -> Text -> KeyMap.KeyMap Value -> Either String Value
req what field obj = case KeyMap.lookup (Key.fromText field) obj of
  Nothing -> Left (what <> ": missing required field " <> show field)
  Just v -> Right v

reqString :: String -> Text -> KeyMap.KeyMap Value -> Either String Text
reqString what field obj =
  req what field obj >>= \case
    String s -> Right s
    _ -> Left (what <> ": field " <> show field <> " must be a string")

reqArray :: String -> Text -> KeyMap.KeyMap Value -> Either String [Value]
reqArray what field obj =
  req what field obj >>= \case
    Array arr -> Right (V.toList arr)
    _ -> Left (what <> ": field " <> show field <> " must be an array")

reqAnnotations :: KeyMap.KeyMap Value -> Either String Annotations
reqAnnotations obj =
  req "node" "annotations" obj >>= \case
    Object anns -> Right (Map.fromList (map (\(k, v) -> (Key.toText k, v)) (KeyMap.toList anns)))
    _ -> Left "node: field \"annotations\" must be an object"

-- Transformation -----------------------------------------------------------

-- | Rewrites every action reachable in a tree, leaving everything else --
-- tags, ordinary attributes, element value slots, child order, and every
-- annotation map -- untouched. The traversal is effectful in 'Either' so a
-- rewrite that can fail (@adapt-actions@'s optional payload closure) reports
-- where it failed rather than being forced to succeed.
mapActions :: (Text -> Text -> Value -> Either e NodeAttribute) -> Node -> Either e Node
mapActions _ n@(NText _ _) = Right n
mapActions f (NElement tag attrs val children anns) = do
  attrs' <- traverse step attrs
  children' <- traverse (mapActions f) children
  pure (NElement tag attrs' val children' anns)
  where
    step a@(NAttr _ _) = Right a
    step (NAction event key payload) = f event key payload
mapActions f (NFragment children anns) = do
  children' <- traverse (mapActions f) children
  pure (NFragment children' anns)
