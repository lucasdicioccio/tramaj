-- | The evaluated document representation — Tramaj's output domain and its
-- | portable interchange boundary. `nodeToJson`/`nodeFromJson` implement
-- | the normative representation specified in `specs/node-json.md`; that
-- | document, not this module, is the contract other implementations and
-- | hosts are held to.
-- |
-- | Deliberately independent of both the expression AST (`Tramaj.Ast`) and
-- | of any particular render target — folding a `Node` into Halogen HTML
-- | is `Tramaj.Halogen`'s job, in its own package, and another host may
-- | fold the same tree into YAML, HCL or a UI model instead.
-- |
-- | Kept in lockstep with `../tramaj-hs/src/Tramaj/Node.hs`.
module Tramaj.Node
  ( Node(..)
  , NodeAttribute(..)
  , Annotations
  , noAnnotations
  , nodeToJson
  , nodeFromJson
  , nodeAttributeToJson
  , mapActions
  ) where

import Prelude

import Data.Argonaut.Core (Json, fromArray, fromObject, fromString, stringify, toArray, toObject, toString)
import Data.Either (Either(..), note)
import Data.Map (Map)
import Data.Map as Map
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as Object

-- | Arbitrary host/tooling metadata hung off any node. The core language
-- | assigns no meaning to any key; unknown annotations must not affect
-- | semantics, and every node-to-node transformation must carry them
-- | through unchanged. This is where a future type/domain/constraint pass
-- | puts what it derives, without the `Node` constructors having to
-- | change.
type Annotations = Map String Json

noAnnotations :: Annotations
noAnnotations = Map.empty

-- | Three constructors, with enough expressivity inside them to carry
-- | scalars losslessly — see `specs/decisions.md` #5.
-- |
-- | `NText` holds a `Json`, not a `String`: `.p($ctx.count)` with
-- | `count = 3` keeps the number `3` rather than stringifying it.
-- | Rendering a scalar to characters is a host decision, so the
-- | interchange format declines to make it.
-- |
-- | `NElement` holds a `value` slot alongside its children, for targets
-- | that attach a body value to a tagged node (a YAML/HCL scalar leaf, a
-- | config value); it is `null` unless a template sets one. Its
-- | attributes are an ordered array rather than a map: an element may
-- | carry any number of attributes *and* any number of actions, and
-- | source order is preserved.
-- |
-- | `NFragment` is a real node here — an ordered sibling sequence with no
-- | wrapper element. A host may flatten fragments when folding;
-- | evaluation does not.
data Node
  = NText Json Annotations
  | NElement String (Array NodeAttribute) Json (Array Node) Annotations
  | NFragment (Array Node) Annotations

derive instance eqNode :: Eq Node

-- | `Json` has no `Show` instance, so every payload is `stringify`d
-- | explicitly rather than riding along on a derived one.
instance showNode :: Show Node where
  show (NText value anns) = "NText " <> stringify value <> " " <> showAnnotations anns
  show (NElement tag attrs value children anns) =
    "NElement " <> show tag <> " " <> show attrs <> " " <> stringify value
      <> " "
      <> show children
      <> " "
      <> showAnnotations anns
  show (NFragment children anns) = "NFragment " <> show children <> " " <> showAnnotations anns

showAnnotations :: Annotations -> String
showAnnotations anns =
  show (map (\(Tuple k v) -> Tuple k (stringify v)) (Map.toUnfoldable anns :: Array (Tuple String Json)))

-- | Both attribute-position constructs, sharing one array. An action's
-- | event and key are plain `String` because both are static in the source
-- | AST (see `Tramaj.Ast`); only the payload is computed.
data NodeAttribute
  = NAttr String Json
  | NAction String String Json

derive instance eqNodeAttribute :: Eq NodeAttribute

instance showNodeAttribute :: Show NodeAttribute where
  show (NAttr name value) = "NAttr " <> show name <> " " <> stringify value
  show (NAction event key payload) =
    "NAction " <> show event <> " " <> show key <> " " <> stringify payload

-- Serialization -----------------------------------------------------------

-- | Encodes to the normative representation. Every field is always
-- | emitted, including an empty `annotations` and a `null` element
-- | `value` — see `specs/node-json.md`, "Decoding": on the wire a missing
-- | field is a bug, not a default.
nodeToJson :: Node -> Json
nodeToJson (NText value anns) =
  obj
    [ Tuple "type" (fromString "text")
    , Tuple "value" value
    , Tuple "annotations" (annotationsToJson anns)
    ]
nodeToJson (NElement tag attrs value children anns) =
  obj
    [ Tuple "type" (fromString "element")
    , Tuple "tag" (fromString tag)
    , Tuple "attributes" (fromArray (map nodeAttributeToJson attrs))
    , Tuple "value" value
    , Tuple "children" (fromArray (map nodeToJson children))
    , Tuple "annotations" (annotationsToJson anns)
    ]
nodeToJson (NFragment children anns) =
  obj
    [ Tuple "type" (fromString "fragment")
    , Tuple "children" (fromArray (map nodeToJson children))
    , Tuple "annotations" (annotationsToJson anns)
    ]

nodeAttributeToJson :: NodeAttribute -> Json
nodeAttributeToJson (NAttr name value) =
  obj [ Tuple "kind" (fromString "attribute"), Tuple "name" (fromString name), Tuple "value" value ]
nodeAttributeToJson (NAction event key payload) =
  obj
    [ Tuple "kind" (fromString "action")
    , Tuple "event" (fromString event)
    , Tuple "key" (fromString key)
    , Tuple "payload" payload
    ]

obj :: Array (Tuple String Json) -> Json
obj = fromObject <<< Object.fromFoldable

annotationsToJson :: Annotations -> Json
annotationsToJson anns =
  fromObject (Object.fromFoldable (Map.toUnfoldable anns :: Array (Tuple String Json)))

-- | Decodes the normative representation, strictly: a missing or ill-typed
-- | field is an error rather than a silently-defaulted value, so
-- | `nodeFromJson <<< nodeToJson` round-trips and a malformed document is
-- | reported where it is read rather than where it later misbehaves. The
-- | `Left` carries a human-readable description of what was wrong.
nodeFromJson :: Json -> Either String Node
nodeFromJson json = do
  fields <- note "expected a JSON object for a node" (toObject json)
  ty <- reqString "node" "type" fields
  case ty of
    "text" -> NText <$> req "text node" "value" fields <*> reqAnnotations fields
    "element" ->
      NElement
        <$> reqString "element node" "tag" fields
        <*> (reqArray "element node" "attributes" fields >>= traverse nodeAttributeFromJson)
        <*> req "element node" "value" fields
        <*> (reqArray "element node" "children" fields >>= traverse nodeFromJson)
        <*> reqAnnotations fields
    "fragment" ->
      NFragment
        <$> (reqArray "fragment node" "children" fields >>= traverse nodeFromJson)
        <*> reqAnnotations fields
    other -> Left ("unknown node type: " <> show other)

nodeAttributeFromJson :: Json -> Either String NodeAttribute
nodeAttributeFromJson json = do
  fields <- note "expected a JSON object for a node attribute" (toObject json)
  kind <- reqString "node attribute" "kind" fields
  case kind of
    "attribute" -> NAttr <$> reqString "attribute" "name" fields <*> req "attribute" "value" fields
    "action" ->
      NAction
        <$> reqString "action" "event" fields
        <*> reqString "action" "key" fields
        <*> req "action" "payload" fields
    other -> Left ("unknown node attribute kind: " <> show other)

req :: String -> String -> Object Json -> Either String Json
req what field fields =
  note (what <> ": missing required field " <> show field) (Object.lookup field fields)

reqString :: String -> String -> Object Json -> Either String String
reqString what field fields = do
  v <- req what field fields
  note (what <> ": field " <> show field <> " must be a string") (toString v)

reqArray :: String -> String -> Object Json -> Either String (Array Json)
reqArray what field fields = do
  v <- req what field fields
  note (what <> ": field " <> show field <> " must be an array") (toArray v)

reqAnnotations :: Object Json -> Either String Annotations
reqAnnotations fields = do
  v <- req "node" "annotations" fields
  anns <- note "node: field \"annotations\" must be an object" (toObject v)
  pure (Map.fromFoldable (Object.toUnfoldable anns :: Array (Tuple String Json)))

-- Transformation -----------------------------------------------------------

-- | Rewrites every action reachable in a tree, leaving everything else —
-- | tags, ordinary attributes, element value slots, child order, and every
-- | annotation map — untouched. The traversal is effectful in `Either` so
-- | a rewrite that can fail (`adapt-actions`'s optional payload closure)
-- | reports where it failed rather than being forced to succeed.
mapActions
  :: forall e
   . (String -> String -> Json -> Either e NodeAttribute)
  -> Node
  -> Either e Node
mapActions _ n@(NText _ _) = Right n
mapActions f (NElement tag attrs value children anns) =
  NElement tag <$> traverse step attrs <@> value <*> traverse (mapActions f) children <@> anns
  where
  step a@(NAttr _ _) = Right a
  step (NAction event key payload) = f event key payload
mapActions f (NFragment children anns) =
  NFragment <$> traverse (mapActions f) children <@> anns
