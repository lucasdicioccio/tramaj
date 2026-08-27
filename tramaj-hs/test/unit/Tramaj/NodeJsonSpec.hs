-- | Round-trip and shape checks for the normative Node JSON representation
-- specified in @../specs/node-json.md@. The round-trip property is the one
-- that matters: it is what lets an independent implementation decode what
-- this one encodes, so it is checked over trees covering all three node
-- constructors, both attribute kinds, non-empty annotations, and scalar
-- values of every JSON type.
module Tramaj.NodeJsonSpec (spec) where

import Data.Aeson (ToJSON, Value (..), object, (.=))
import qualified Data.Map.Strict as Map
import Test.Hspec
import Tramaj.Node

spec :: Spec
spec = describe "Tramaj.Node JSON representation" $ do
  roundTripSpec
  shapeSpec
  rejectionSpec
  mapActionsSpec

-- | Every sample below must survive @nodeFromJson . nodeToJson@ unchanged.
samples :: [(String, Node)]
samples =
  [ ("text holding a string", NText (String "hello") noAnnotations)
  , ("text holding a number", NText (Number 3) noAnnotations)
  , ("text holding null", NText Null noAnnotations)
  , ("text holding a boolean", NText (Bool True) noAnnotations)
  , ("text holding an object", NText (object ["a" .= (1 :: Int)]) noAnnotations)
  , ("empty element", NElement "div" [] Null [] noAnnotations)
  , ("element with an ordinary attribute", NElement "div" [NAttr "class" (String "panel")] Null [] noAnnotations)
  ,
    ( "element with several actions and attributes interleaved"
    , NElement
        "button"
        [ NAttr "class" (String "primary")
        , NAction "on-click" "save" (object ["id" .= (1 :: Int)])
        , NAttr "data-n" (Number 2)
        , NAction "on-double-click" "open" Null
        ]
        Null
        [NText (String "Save") noAnnotations]
        noAnnotations
    )
  , ("element with a value slot", NElement "Replicas" [] (Number 3) [] noAnnotations)
  , ("fragment", NFragment [NText (String "one") noAnnotations, NText (String "two") noAnnotations] noAnnotations)
  , ("empty fragment", NFragment [] noAnnotations)
  ,
    ( "annotations at every level, including ones the core does not understand"
    , NElement
        "section"
        [NAttr "id" (String "x")]
        Null
        [NFragment [NText (String "deep") (Map.fromList [("origin", String "lib")])] (Map.fromList [("flattenable", Bool True)])]
        (Map.fromList [("type", String "Section"), ("domain", object ["min" .= (1 :: Int)])])
    )
  , ("repeated attribute names are preserved, not deduplicated", NElement "div" [NAttr "class" (String "a"), NAttr "class" (String "b")] Null [] noAnnotations)
  ]

roundTripSpec :: Spec
roundTripSpec = describe "round-trips through the normative representation" $
  mapM_ (\(name, n) -> it name (nodeFromJson (nodeToJson n) `shouldBe` Right n)) samples

-- | The exact bytes matter as much as the round-trip: another implementation
-- reads these keys, so a rename would be a silent wire-format break that a
-- round-trip test alone would not catch.
shapeSpec :: Spec
shapeSpec = describe "encodes the shape specs/node-json.md documents" $ do
  it "a text node carries its value unconverted, plus annotations" $
    nodeToJson (NText (Number 3) noAnnotations)
      `shouldBe` object ["type" .= ("text" :: String), "value" .= (3 :: Int), "annotations" .= object []]

  it "an element always emits tag, attributes, value, children and annotations" $
    nodeToJson (NElement "p" [] Null [] noAnnotations)
      `shouldBe` object
        [ "type" .= ("element" :: String)
        , "tag" .= ("p" :: String)
        , "attributes" .= ([] :: [Value])
        , "value" .= Null
        , "children" .= ([] :: [Value])
        , "annotations" .= object []
        ]

  it "attributes and actions are discriminated by \"kind\" in one ordered list" $
    nodeToJson (NElement "b" [NAttr "class" (String "c"), NAction "on-click" "save" Null] Null [] noAnnotations)
      `shouldBe` object
        [ "type" .= ("element" :: String)
        , "tag" .= ("b" :: String)
        , "attributes"
            .= [ object ["kind" .= ("attribute" :: String), "name" .= ("class" :: String), "value" .= ("c" :: String)]
               , object ["kind" .= ("action" :: String), "event" .= ("on-click" :: String), "key" .= ("save" :: String), "payload" .= Null]
               ]
        , "value" .= Null
        , "children" .= ([] :: [Value])
        , "annotations" .= object []
        ]

  it "a fragment emits no tag, attributes or value" $
    nodeToJson (NFragment [] noAnnotations)
      `shouldBe` object ["type" .= ("fragment" :: String), "children" .= ([] :: [Value]), "annotations" .= object []]

-- | @specs/node-json.md@, "Decoding": a decoder must reject rather than
-- default, so that a malformed document is reported where it is read.
-- Malformed documents are built as 'Value's directly rather than parsed from
-- JSON text, so each one differs from a well-formed node in exactly the one
-- way its name describes.
rejectionSpec :: Spec
rejectionSpec = describe "rejects malformed documents rather than defaulting" $ do
  let rejects name js = it name (nodeFromJson js `shouldSatisfy` either (const True) (const False))

  rejects "a node with no type" $
    object ["value" .= (1 :: Int), "annotations" .= object []]
  rejects "an unknown node type" $
    object ["type" .= ("comment" :: String), "annotations" .= object []]
  rejects "a text node with no value" $
    object ["type" .= ("text" :: String), "annotations" .= object []]
  rejects "a node with no annotations" $
    object ["type" .= ("text" :: String), "value" .= (1 :: Int)]
  rejects "an element with no value slot" $
    object
      [ "type" .= ("element" :: String)
      , "tag" .= ("p" :: String)
      , "attributes" .= ([] :: [Value])
      , "children" .= ([] :: [Value])
      , "annotations" .= object []
      ]
  rejects "an element with a non-string tag" $
    element (Number 1) ([] :: [Value]) ([] :: [Value])
  rejects "an element whose children are not an array" $
    element (String "p") ([] :: [Value]) (object [])
  rejects "an element whose attributes are not an array" $
    element (String "p") (object []) ([] :: [Value])
  rejects "annotations that are not an object" $
    object ["type" .= ("fragment" :: String), "children" .= ([] :: [Value]), "annotations" .= ([] :: [Value])]
  rejects "an attribute with no kind" $
    element (String "p") [object ["name" .= ("a" :: String), "value" .= (1 :: Int)]] ([] :: [Value])
  rejects "an unknown attribute kind" $
    element (String "p") [object ["kind" .= ("listener" :: String)]] ([] :: [Value])
  rejects "an action with no key" $
    element (String "p") [object ["kind" .= ("action" :: String), "event" .= ("e" :: String), "payload" .= Null]] ([] :: [Value])
  rejects "an attribute with a non-string name" $
    element (String "p") [object ["kind" .= ("attribute" :: String), "name" .= (1 :: Int), "value" .= Null]] ([] :: [Value])
  rejects "a malformed node nested deep in a child" $
    object
      [ "type" .= ("fragment" :: String)
      , "children" .= [object ["type" .= ("text" :: String)]]
      , "annotations" .= object []
      ]
  rejects "a bare scalar where a node was expected" $ Number 42
  rejects "an attribute that is not an object" $
    element (String "p") [String "class"] ([] :: [Value])
  where
    -- | A well-formed element apart from whichever of its three variable
    -- parts the caller deliberately breaks.
    element :: (ToJSON a, ToJSON b) => Value -> a -> b -> Value
    element tag attrs children =
      object
        [ "type" .= ("element" :: String)
        , "tag" .= tag
        , "attributes" .= attrs
        , "value" .= Null
        , "children" .= children
        , "annotations" .= object []
        ]

-- | @adapt-actions@ leans on this: it must reach actions at every depth and
-- leave everything else -- annotations especially -- exactly as it found it.
mapActionsSpec :: Spec
mapActionsSpec = describe "mapActions" $ do
  let prefixKey p (NAction e k pl) = NAction e (p <> k) pl
      prefixKey _ a = a
      prefix p = mapActions (\e k pl -> Right (prefixKey p (NAction e k pl))) :: Node -> Either () Node

  it "rewrites actions nested under children and fragments" $
    prefix "ns:"
      ( NElement
          "div"
          []
          Null
          [NFragment [NElement "b" [NAction "on-click" "save" Null] Null [] noAnnotations] noAnnotations]
          noAnnotations
      )
      `shouldBe` Right
        ( NElement
            "div"
            []
            Null
            [NFragment [NElement "b" [NAction "on-click" "ns:save" Null] Null [] noAnnotations] noAnnotations]
            noAnnotations
        )

  it "leaves ordinary attributes, value slots and annotations untouched" $
    let anns = Map.fromList [("origin", String "lib")]
        n = NElement "div" [NAttr "class" (String "c"), NAction "on-click" "save" Null] (Number 1) [] anns
     in prefix "ns:" n
          `shouldBe` Right (NElement "div" [NAttr "class" (String "c"), NAction "on-click" "ns:save" Null] (Number 1) [] anns)

  it "propagates a failing rewrite instead of dropping it" $
    mapActions (\_ _ _ -> Left "boom") (NElement "b" [NAction "on-click" "save" Null] Null [] noAnnotations)
      `shouldBe` (Left "boom" :: Either String Node)
