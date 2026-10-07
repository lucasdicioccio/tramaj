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

import Data.Bifunctor (first)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Tramaj.Json (Json (..), normalizeNumbers)

-- | Arbitrary host\/tooling metadata hung off any node. The core language
-- assigns no meaning to any key; unknown annotations must not affect
-- semantics, and every node-to-node transformation must carry them through
-- unchanged. This is where a future type\/domain\/constraint pass puts what
-- it derives, without the 'Node' constructors having to change.
type Annotations = Map Text Json

noAnnotations :: Annotations
noAnnotations = Map.empty

-- | Three constructors, with enough expressivity inside them to carry
-- scalars losslessly -- see @../specs/decisions.md@ #5.
--
-- 'NText' holds a 'Json' value, not a 'Text': @.p($ctx.count)@ with
-- @count = 3@ keeps the integer @3@ rather than stringifying it, and the
-- float @3.0@ stays a float (@../specs/node-json.md@, /Numbers/). Rendering a scalar to
-- characters is a host decision, so the interchange format declines to make
-- it.
--
-- 'NElement' holds a @value@ slot alongside its children, for targets that
-- attach a body value to a tagged node (a YAML\/HCL scalar leaf, a config
-- value); it is 'JNull' unless a template sets one. Its attributes are an
-- ordered list rather than a map: an element may carry any number of
-- attributes /and/ any number of actions, and source order is preserved.
--
-- 'NFragment' is a real node here -- an ordered sibling sequence with no
-- wrapper element. A host may flatten fragments when folding; evaluation
-- does not.
data Node
  = NText Json Annotations
  | NElement Text [NodeAttribute] Json [Node] Annotations
  | NFragment [Node] Annotations
  deriving stock (Eq, Show)

-- | Both attribute-position constructs, sharing one list. An action's
-- @event@ and @key@ are plain 'Text' because both are static in the source
-- AST (see "Tramaj.Ast"); only the payload is computed.
data NodeAttribute
  = NAttr Text Json
  | NAction Text Text Json
  deriving stock (Eq, Show)

-- Serialization -----------------------------------------------------------

-- | Encodes to the normative representation. Every field is always emitted,
-- including an empty @annotations@ and a @null@ element @value@ -- see
-- @../specs/node-json.md@, "Decoding": on the wire a missing field is a bug,
-- not a default.
nodeToJson :: Node -> Json
nodeToJson (NText v anns) =
  object [("type", JString "text"), ("value", v), ("annotations", JObject anns)]
nodeToJson (NElement tag attrs val children anns) =
  object
    [ ("type", JString "element")
    , ("tag", JString tag)
    , ("attributes", JArray (map nodeAttributeToJson attrs))
    , ("value", val)
    , ("children", JArray (map nodeToJson children))
    , ("annotations", JObject anns)
    ]
nodeToJson (NFragment children anns) =
  object
    [ ("type", JString "fragment")
    , ("children", JArray (map nodeToJson children))
    , ("annotations", JObject anns)
    ]

nodeAttributeToJson :: NodeAttribute -> Json
nodeAttributeToJson (NAttr name val) =
  object [("kind", JString "attribute"), ("name", JString name), ("value", val)]
nodeAttributeToJson (NAction event key payload) =
  object [("kind", JString "action"), ("event", JString event), ("key", JString key), ("payload", payload)]

object :: [(Text, Json)] -> Json
object = JObject . Map.fromList

-- | Decodes the normative representation, strictly: a missing or
-- ill-typed field is an error rather than a silently-defaulted value, so
-- @nodeFromJson . nodeToJson@ round-trips and a malformed document is
-- reported where it is read rather than where it later misbehaves. The
-- 'Left' carries a human-readable path-ish description of what was wrong.
--
-- A number in a @Value@ follows /Numbers/ and /Decoding/ there: an
-- integer-form number outside the integer range or a float too large for a
-- double is refused rather than rounded, at any depth, and a negative zero
-- decodes as zero ('reqValue'). Annotations are arbitrary JSON, not a
-- @Value@, and are kept as they were read.
nodeFromJson :: Json -> Either String Node
nodeFromJson (JObject obj) = do
  ty <- reqString "node" "type" obj
  case ty of
    "text" -> do
      v <- reqValue "text node" "value" obj
      anns <- reqAnnotations obj
      pure (NText v anns)
    "element" -> do
      tag <- reqString "element node" "tag" obj
      attrs <- reqArray "element node" "attributes" obj >>= traverse nodeAttributeFromJson
      val <- reqValue "element node" "value" obj
      children <- reqArray "element node" "children" obj >>= traverse nodeFromJson
      anns <- reqAnnotations obj
      pure (NElement tag attrs val children anns)
    "fragment" -> do
      children <- reqArray "fragment node" "children" obj >>= traverse nodeFromJson
      anns <- reqAnnotations obj
      pure (NFragment children anns)
    other -> Left ("unknown node type: " <> show other)
nodeFromJson _ = Left "expected a JSON object for a node"

nodeAttributeFromJson :: Json -> Either String NodeAttribute
nodeAttributeFromJson (JObject obj) = do
  kind <- reqString "node attribute" "kind" obj
  case kind of
    "attribute" -> NAttr <$> reqString "attribute" "name" obj <*> reqValue "attribute" "value" obj
    "action" ->
      NAction
        <$> reqString "action" "event" obj
        <*> reqString "action" "key" obj
        <*> reqValue "action" "payload" obj
    other -> Left ("unknown node attribute kind: " <> show other)
nodeAttributeFromJson _ = Left "expected a JSON object for a node attribute"

req :: String -> Text -> Map Text Json -> Either String Json
req what field obj = case Map.lookup field obj of
  Nothing -> Left (what <> ": missing required field " <> show field)
  Just v -> Right v

-- | A field holding a @Value@, with its numbers checked ('normalizeNumbers').
reqValue :: String -> Text -> Map Text Json -> Either String Json
reqValue what field obj = do
  v <- req what field obj
  first (\why -> what <> ": field " <> show field <> ": " <> why) (normalizeNumbers v)

reqString :: String -> Text -> Map Text Json -> Either String Text
reqString what field obj =
  req what field obj >>= \case
    JString s -> Right s
    _ -> Left (what <> ": field " <> show field <> " must be a string")

reqArray :: String -> Text -> Map Text Json -> Either String [Json]
reqArray what field obj =
  req what field obj >>= \case
    JArray arr -> Right arr
    _ -> Left (what <> ": field " <> show field <> " must be an array")

reqAnnotations :: Map Text Json -> Either String Annotations
reqAnnotations obj =
  req "node" "annotations" obj >>= \case
    JObject anns -> Right anns
    _ -> Left "node: field \"annotations\" must be an object"

-- Transformation -----------------------------------------------------------

-- | Rewrites every action reachable in a tree, leaving everything else --
-- tags, ordinary attributes, element value slots, child order, and every
-- annotation map -- untouched. Polymorphic in the applicative so a caller
-- that only fails ('Either') and one that also accumulates something
-- alongside its result (v3-symbols constraint emission) can share this one
-- traversal.
mapActions :: (Applicative f) => (Text -> Text -> Json -> f NodeAttribute) -> Node -> f Node
mapActions _ n@(NText _ _) = pure n
mapActions f (NElement tag attrs val children anns) =
  NElement tag <$> traverse step attrs <*> pure val <*> traverse (mapActions f) children <*> pure anns
  where
    step a@(NAttr _ _) = pure a
    step (NAction event key payload) = f event key payload
mapActions f (NFragment children anns) =
  NFragment <$> traverse (mapActions f) children <*> pure anns
