-- | Writes an evaluated tramaj 'Node' as an XML document, so the same
-- template language that lays out a PDF can produce the XML attached to it
-- (a Factur-X invoice's @factur-x.xml@).
--
-- A tramaj tag is a name of letters, digits, @_@ and inner @-@, so it has
-- no @:@. Namespace prefixes are written with a @-@ instead: a tag
-- @rsm-CrossIndustryInvoice@ is written @rsm:CrossIndustryInvoice@ when an
-- @xmlns:rsm@ attribute is in scope (on the element or an ancestor). A tag
-- whose part before the first @-@ is not a declared prefix is written as it
-- is. Attribute names are any string (@"xmlns:rsm": "urn:…"@).
--
-- Text and attribute values are written as @str@ writes them (as the PDF
-- does): a string is itself, an integer its digits, a float always with a
-- fraction, @null@ nothing. A fragment contributes its children. An
-- element with a value slot and no children shows the value. An action, or
-- a structured value (array, object) in text or attribute position, is an
-- error naming it: XML has no place for either.
module Tramaj.Hpdf.Xml
  ( renderXml
  , renderXmlFragment
  , xmlName
  ) where

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Tramaj.Hpdf.Layout (renderScalar)
import Tramaj.Json (Json (..))
import Tramaj.Node (Node (..), NodeAttribute (..))

-- | An XML document (UTF-8 declaration, then the root element), or the
-- first construct XML cannot carry. The root must be one element (a
-- fragment of one element, possibly between whitespace, is fine).
renderXml :: Node -> Either Text Text
renderXml node = case [n | n <- flatten [node], not (blankText n)] of
  [root@NElement {}] -> do
    body <- renderXmlFragment root
    pure ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" <> body <> "\n")
  _ -> Left "an XML document needs exactly one root element"

-- | The XML of a node, without a declaration.
renderXmlFragment :: Node -> Either Text Text
renderXmlFragment = go Set.empty 0
  where
    go :: Set Text -> Int -> Node -> Either Text Text
    go scope depth = \case
      NText v _ -> escapeText <$> scalar "text" v
      NFragment cs _ -> T.concat <$> traverse (go scope depth) cs
      NElement tag attrs val cs _ -> do
        as <- traverse (attribute tag) attrs
        let scope' = scope <> Set.fromList [p | (n, _) <- as, Just p <- [T.stripPrefix "xmlns:" n]]
            name = xmlName scope' tag
            open = "<" <> name <> T.concat [" " <> n <> "=\"" <> escapeAttr v <> "\"" | (n, v) <- as]
            children = flatten cs
        body <-
          if null children
            then case val of
              JNull -> pure Nothing
              v -> Just . escapeText <$> scalar ("the value of " <> tag) v
            else Just <$> content scope' depth children
        pure $ case body of
          Nothing -> open <> "/>"
          Just b -> open <> ">" <> b <> "</" <> name <> ">"

    -- Children that are all elements are indented one per line; mixed
    -- content is written as it is, so its text keeps its spaces.
    content scope depth children
      | all isElementOrBlank children = do
          let elements = filter (not . blankText) children
              pad = "\n" <> T.replicate (depth + 1) "  "
          parts <- traverse (go scope (depth + 1)) elements
          pure (T.concat (map (pad <>) parts) <> "\n" <> T.replicate depth "  ")
      | otherwise = T.concat <$> traverse (go scope depth) children

    attribute tag = \case
      NAttr n v -> (n,) <$> scalar ("the attribute " <> n <> " of " <> tag) v
      NAction event _ _ -> Left ("the action " <> event <> " on " <> tag <> ": XML has no actions")

    scalar what = \case
      JArray _ -> Left (what <> " is an array, which XML cannot hold")
      JObject _ -> Left (what <> " is an object, which XML cannot hold")
      v -> Right (renderScalar v)

-- | The XML name of a tag: @p-Local@ becomes @p:Local@ when @p@ is one of
-- the declared prefixes.
xmlName :: Set Text -> Text -> Text
xmlName scope tag = case T.breakOn "-" tag of
  (p, rest) | not (T.null rest), p `Set.member` scope -> p <> ":" <> T.drop 1 rest
  _ -> tag

flatten :: [Node] -> [Node]
flatten = concatMap $ \case
  NFragment cs _ -> flatten cs
  n -> [n]

isElementOrBlank :: Node -> Bool
isElementOrBlank = \case
  NElement {} -> True
  n -> blankText n

blankText :: Node -> Bool
blankText = \case
  NText (JString s) _ -> T.all (`elem` [' ', '\t', '\r', '\n']) s
  NText JNull _ -> True
  _ -> False

escapeText :: Text -> Text
escapeText = T.concatMap $ \case
  '<' -> "&lt;"
  '>' -> "&gt;"
  '&' -> "&amp;"
  c -> T.singleton c

escapeAttr :: Text -> Text
escapeAttr = T.concatMap $ \case
  '<' -> "&lt;"
  '&' -> "&amp;"
  '"' -> "&quot;"
  '\n' -> "&#10;"
  c -> T.singleton c
