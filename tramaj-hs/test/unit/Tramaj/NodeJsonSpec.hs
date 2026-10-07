-- | Round-trip and shape checks for the normative Node JSON representation
-- specified in @../specs/node-json.md@. The round-trip property is the one
-- that matters: it is what lets an independent implementation decode what
-- this one encodes, so it is checked over trees covering all three node
-- constructors, both attribute kinds, non-empty annotations, and scalar
-- values of every JSON type.
module Tramaj.NodeJsonSpec (spec) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Test.Hspec
import Tramaj.Json (Json (..))
import Tramaj.Node
import Tramaj.TestJson (ToJ, object, (.=))

spec :: Spec
spec = describe "Tramaj.Node JSON representation" $ do
  roundTripSpec
  shapeSpec
  rejectionSpec
  mapActionsSpec

-- | Every sample below must survive @nodeFromJson . nodeToJson@ unchanged.
samples :: [(String, Node)]
samples =
  [ ("text holding a string", NText (JString "hello") noAnnotations)
  , ("text holding a number", NText (JInt 3) noAnnotations)
  , ("text holding null", NText JNull noAnnotations)
  , ("text holding a boolean", NText (JBool True) noAnnotations)
  , ("text holding an object", NText (object ["a" .= (1 :: Int)]) noAnnotations)
  , ("empty element", NElement "div" [] JNull [] noAnnotations)
  , ("element with an ordinary attribute", NElement "div" [NAttr "class" (JString "panel")] JNull [] noAnnotations)
  ,
    ( "element with several actions and attributes interleaved"
    , NElement
        "button"
        [ NAttr "class" (JString "primary")
        , NAction "on-click" "save" (object ["id" .= (1 :: Int)])
        , NAttr "data-n" (JInt 2)
        , NAction "on-double-click" "open" JNull
        ]
        JNull
        [NText (JString "Save") noAnnotations]
        noAnnotations
    )
  , ("element with a value slot", NElement "Replicas" [] (JInt 3) [] noAnnotations)
  , ("fragment", NFragment [NText (JString "one") noAnnotations, NText (JString "two") noAnnotations] noAnnotations)
  , ("empty fragment", NFragment [] noAnnotations)
  ,
    ( "annotations at every level, including ones the core does not understand"
    , NElement
        "section"
        [NAttr "id" (JString "x")]
        JNull
        [NFragment [NText (JString "deep") (Map.fromList [("origin", JString "lib")])] (Map.fromList [("flattenable", JBool True)])]
        (Map.fromList [("type", JString "Section"), ("domain", object ["min" .= (1 :: Int)])])
    )
  , ("repeated attribute names are preserved, not deduplicated", NElement "div" [NAttr "class" (JString "a"), NAttr "class" (JString "b")] JNull [] noAnnotations)
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
    nodeToJson (NText (JInt 3) noAnnotations)
      `shouldBe` object ["type" .= ("text" :: Text), "value" .= (3 :: Int), "annotations" .= object []]

  it "an element always emits tag, attributes, value, children and annotations" $
    nodeToJson (NElement "p" [] JNull [] noAnnotations)
      `shouldBe` object
        [ "type" .= ("element" :: Text)
        , "tag" .= ("p" :: Text)
        , "attributes" .= ([] :: [Json])
        , "value" .= JNull
        , "children" .= ([] :: [Json])
        , "annotations" .= object []
        ]

  it "attributes and actions are discriminated by \"kind\" in one ordered list" $
    nodeToJson (NElement "b" [NAttr "class" (JString "c"), NAction "on-click" "save" JNull] JNull [] noAnnotations)
      `shouldBe` object
        [ "type" .= ("element" :: Text)
        , "tag" .= ("b" :: Text)
        , "attributes"
            .= [ object ["kind" .= ("attribute" :: Text), "name" .= ("class" :: Text), "value" .= ("c" :: Text)]
               , object ["kind" .= ("action" :: Text), "event" .= ("on-click" :: Text), "key" .= ("save" :: Text), "payload" .= JNull]
               ]
        , "value" .= JNull
        , "children" .= ([] :: [Json])
        , "annotations" .= object []
        ]

  it "a fragment emits no tag, attributes or value" $
    nodeToJson (NFragment [] noAnnotations)
      `shouldBe` object ["type" .= ("fragment" :: Text), "children" .= ([] :: [Json]), "annotations" .= object []]

-- | @specs/node-json.md@, "Decoding": a decoder must reject rather than
-- default, so that a malformed document is reported where it is read.
-- Malformed documents are built as 'Json's directly rather than parsed from
-- JSON text, so each one differs from a well-formed node in exactly the one
-- way its name describes.
rejectionSpec :: Spec
rejectionSpec = describe "rejects malformed documents rather than defaulting" $ do
  let rejects name js = it name (nodeFromJson js `shouldSatisfy` either (const True) (const False))

  rejects "a node with no type" $
    object ["value" .= (1 :: Int), "annotations" .= object []]
  rejects "an unknown node type" $
    object ["type" .= ("comment" :: Text), "annotations" .= object []]
  rejects "a text node with no value" $
    object ["type" .= ("text" :: Text), "annotations" .= object []]
  rejects "a node with no annotations" $
    object ["type" .= ("text" :: Text), "value" .= (1 :: Int)]
  rejects "an element with no value slot" $
    object
      [ "type" .= ("element" :: Text)
      , "tag" .= ("p" :: Text)
      , "attributes" .= ([] :: [Json])
      , "children" .= ([] :: [Json])
      , "annotations" .= object []
      ]
  rejects "an element with a non-string tag" $
    element (JInt 1) ([] :: [Json]) ([] :: [Json])
  rejects "an element whose children are not an array" $
    element (JString "p") ([] :: [Json]) (object [])
  rejects "an element whose attributes are not an array" $
    element (JString "p") (object []) ([] :: [Json])
  rejects "annotations that are not an object" $
    object ["type" .= ("fragment" :: Text), "children" .= ([] :: [Json]), "annotations" .= ([] :: [Json])]
  rejects "an attribute with no kind" $
    element (JString "p") [object ["name" .= ("a" :: Text), "value" .= (1 :: Int)]] ([] :: [Json])
  rejects "an unknown attribute kind" $
    element (JString "p") [object ["kind" .= ("listener" :: Text)]] ([] :: [Json])
  rejects "an action with no key" $
    element (JString "p") [object ["kind" .= ("action" :: Text), "event" .= ("e" :: Text), "payload" .= JNull]] ([] :: [Json])
  rejects "an attribute with a non-string name" $
    element (JString "p") [object ["kind" .= ("attribute" :: Text), "name" .= (1 :: Int), "value" .= JNull]] ([] :: [Json])
  rejects "a malformed node nested deep in a child" $
    object
      [ "type" .= ("fragment" :: Text)
      , "children" .= [object ["type" .= ("text" :: Text)]]
      , "annotations" .= object []
      ]
  rejects "a bare scalar where a node was expected" $ JInt 42
  rejects "an attribute that is not an object" $
    element (JString "p") [JString "class"] ([] :: [Json])
  where
    -- | A well-formed element apart from whichever of its three variable
    -- parts the caller deliberately breaks.
    element :: (ToJ a, ToJ b) => Json -> a -> b -> Json
    element tag attrs children =
      object
        [ "type" .= ("element" :: Text)
        , "tag" .= tag
        , "attributes" .= attrs
        , "value" .= JNull
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
          JNull
          [NFragment [NElement "b" [NAction "on-click" "save" JNull] JNull [] noAnnotations] noAnnotations]
          noAnnotations
      )
      `shouldBe` Right
        ( NElement
            "div"
            []
            JNull
            [NFragment [NElement "b" [NAction "on-click" "ns:save" JNull] JNull [] noAnnotations] noAnnotations]
            noAnnotations
        )

  it "leaves ordinary attributes, value slots and annotations untouched" $
    let anns = Map.fromList [("origin", JString "lib")]
        n = NElement "div" [NAttr "class" (JString "c"), NAction "on-click" "save" JNull] (JInt 1) [] anns
     in prefix "ns:" n
          `shouldBe` Right (NElement "div" [NAttr "class" (JString "c"), NAction "on-click" "ns:save" JNull] (JInt 1) [] anns)

  it "propagates a failing rewrite instead of dropping it" $
    mapActions (\_ _ _ -> Left "boom") (NElement "b" [NAction "on-click" "save" JNull] JNull [] noAnnotations)
      `shouldBe` (Left "boom" :: Either String Node)
