-- | Folds the normative `Tramaj.Node` AST into real Halogen output. The
-- | only module in this repository that depends on `halogen` —
-- | `Tramaj.Ast`/`Parser`/`Eval`/`Node` have no Halogen dependency at all,
-- | so the same evaluated tree can be folded to something else entirely.
-- |
-- | Three v2 changes shape this module. A node is no longer guaranteed to
-- | be a single element, because fragments are real nodes, so the fold
-- | returns an `Array`. An element may carry any number of actions rather
-- | than at most one. And attribute values, text values and the element
-- | value slot are arbitrary JSON rather than pre-stringified text —
-- | evaluation deliberately stops short of deciding how a number renders,
-- | which makes it this module's decision (`renderScalar`).
-- |
-- | v3-symbols support: a value anywhere in the tree may be the §5.3 wire
-- | tag `{"$sym": <id>, "path": [...]}` rather than an ordinary scalar, and
-- | `renderScalar` recognizes it unconditionally rather than behind a mode
-- | flag — that shape cannot arise honestly from concrete-mode output,
-- | since `"$sym"` as a literal object key is a parse error, so seeing the
-- | shape already tells the whole story. `renderSymbolTable` and
-- | `renderConstraintTable` render the envelope's `"symbols"`/
-- | `"constraints"` arrays the same way; `renderTypesTable` and
-- | `renderTypeConstraintTable` do the same for v4-types \S8's `"types"`/
-- | `"type-constraints"` arrays. This module is an example host,
-- | not a normative one, so treat the table layout and origin formatting
-- | below as a starting point, not a contract.
module Tramaj.Halogen
  ( foldToHalogen
  , renderScalar
  , isValidAttrName
  , validateAttrNames
  , renderSymbolTable
  , renderConstraintTable
  , renderTypesTable
  , renderTypeConstraintTable
  ) where

import Prelude

import Data.Argonaut.Core (Json, isNull, stringify, toArray, toBoolean, toNumber, toObject, toString)
import Data.Array as Array
import Data.Foldable (foldMap)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (joinWith)
import Data.String.CodeUnits (toCharArray)
import Data.Traversable (traverse)
import Foreign.Object as Object
import Halogen.HTML (ComponentHTML, ElemName(..))
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Tramaj.Node (Node(..), NodeAttribute(..))
import Web.HTML.Common (AttrName(..))

-- | `dispatch` maps an action — its event type, its key, and its JSON
-- | payload — onto a real Halogen action; a host that wants purely
-- | read-only rendering supplies `\_ _ _ -> Nothing`. An action that maps
-- | to `Nothing` attaches no handler at all.
-- |
-- | Every action `dispatch` accepts is wired to `HE.onClick`, without this
-- | module looking at the event type: evaluation does not restrict that
-- | string to any vocabulary, so `dispatch` is the only place that can tell
-- | `"on-click"` from anything else and must return `Nothing` for event
-- | types it does not want turned into a click. Continuous-input handling
-- | is out of scope.
-- |
-- | Returns an `Array` because a `Tramaj.Node` need not be a single
-- | element: a fragment contributes its children with no wrapper, which is
-- | the whole point of it. A host rendering a document root splices the
-- | result into whatever container it already has.
-- |
-- | `foldToHalogen` trusts that attribute names are legal DOM attribute
-- | names and passes them to `HP.attr`. The language does not restrict
-- | them, so a template can produce a name the DOM rejects, throwing
-- | mid-render. Call `validateAttrNames` first and handle a non-empty
-- | result rather than folding straight through.
foldToHalogen
  :: forall action slots m
   . (String -> String -> Json -> Maybe action)
  -> Node
  -> Array (ComponentHTML action slots m)
foldToHalogen _ (NText value _) = [ renderTextValue value ]
foldToHalogen dispatch (NElement tag attrs value children _) =
  [ HH.element (ElemName tag) (attrProps <> actionProps) childNodes ]
  where
  attrProps = Array.mapMaybe attrProp attrs

  attrProp (NAttr name v) = Just (HP.attr (AttrName name) (renderScalar v))
  attrProp _ = Nothing

  actionProps = Array.mapMaybe actionProp attrs

  actionProp (NAction event key payload) = case dispatch event key payload of
    Just a -> Just (HE.onClick \_ -> a)
    Nothing -> Nothing
  actionProp _ = Nothing

  folded = Array.concatMap (foldToHalogen dispatch) children

  -- An element with a value slot and no children renders that value as its
  -- text content: in a DOM host there is nowhere else for it to go, and
  -- dropping it would silently lose what the template said. An element with
  -- both keeps its children and leaves the value to `nodeToJson` consumers.
  childNodes =
    if Array.null folded && not (isNull value) then [ renderTextValue value ]
    else folded
foldToHalogen dispatch (NFragment children _) =
  Array.concatMap (foldToHalogen dispatch) children

-- | A text-position value (a text child, or an element's value slot
-- | rendered as text): a symbol renders in `<code>`, set apart from
-- | ordinary text, so a reader can tell a hole from a string that happens
-- | to look like one; anything else is `renderScalar`, unchanged.
renderTextValue :: forall action slots m. Json -> ComponentHTML action slots m
renderTextValue j = case symbolLabel j of
  Just label -> HH.code_ [ HH.text label ]
  Nothing -> HH.text (renderScalar j)

-- | How this host renders a JSON value as DOM text. A symbol (v3-symbols
-- | §5.3's `{"$sym": ..., "path": [...]}` tag) renders as its id with its
-- | path dotted on, e.g. `#0:"d".replicas`. Otherwise: a string is itself,
-- | a whole number drops its trailing `.0`, `null` renders as nothing, and
-- | anything structured falls back to compact JSON.
-- |
-- | Deliberately this module's decision rather than the evaluator's: a
-- | different host targeting YAML or a UI model would render the same
-- | values differently, and v2's `Node` keeps them unconverted precisely so
-- | that it can.
renderScalar :: Json -> String
renderScalar j = case symbolLabel j of
  Just label -> label
  Nothing -> case toString j of
    Just s -> s
    Nothing -> case toNumber j of
      Just n -> case Int.fromNumber n of
        Just i -> show i
        Nothing -> show n
      Nothing -> case toBoolean j of
        Just b -> if b then "true" else "false"
        Nothing -> if isNull j then "" else stringify j

-- | Recognizes the v3-symbols §5.3 wire tag `{"$sym": <id>, "path": [...]}`
-- | and renders it as `<id>` with its path dotted on. This shape cannot
-- | arise honestly in concrete-mode output — `"$sym"` as a literal object
-- | key is a parse error — so detecting it needs no mode flag: seeing the
-- | shape *is* the mode.
symbolLabel :: Json -> Maybe String
symbolLabel j = do
  o <- toObject j
  sid <- Object.lookup "$sym" o >>= toString
  pathArr <- Object.lookup "path" o >>= toArray
  path <- traverse toString pathArr
  pure (sid <> foldMap ("." <> _) path)

-- | A DOM attribute name this module is willing to set: alphanumeric plus
-- | `-`/`_` only (no spaces, colons, quotes) — deliberately stricter than
-- | HTML itself permits, since the only names templates should need are
-- | kebab-case/snake_case identifiers like `data-count`.
isValidAttrName :: String -> Boolean
isValidAttrName s = s /= "" && Array.all isValidAttrChar (toCharArray s)
  where
  isValidAttrChar c =
    (c >= 'a' && c <= 'z')
      || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9')
      || c == '-'
      || c == '_'

-- | Every invalid attribute name found anywhere in the tree (deduplicated,
-- | tree order), or `[]` if `node` is safe to fold with `foldToHalogen`.
validateAttrNames :: Node -> Array String
validateAttrNames = Array.nub <<< go
  where
  go (NText _ _) = []
  go (NElement _ attrs _ children _) =
    Array.filter (not <<< isValidAttrName) (Array.mapMaybe attrName attrs)
      <> Array.concatMap go children
  go (NFragment children _) = Array.concatMap go children

  attrName (NAttr name _) = Just name
  attrName _ = Nothing

-- Symbolic envelope --------------------------------------------------------

-- | Renders a v3-symbols §5.2 `"symbols"` array (the envelope's symbol
-- | table) as an HTML table: id, origin (an allocation's site and key, or
-- | a demand's path), and the binding it was read into, if any. An entry
-- | that doesn't match the expected shape renders as a `"?"` row rather
-- | than being dropped or throwing — this is reading a JSON contract, not
-- | typed data.
renderSymbolTable :: forall action slots m. Array Json -> ComponentHTML action slots m
renderSymbolTable [] = HH.p_ [ HH.text "No symbols." ]
renderSymbolTable entries =
  HH.table_
    [ HH.thead_
        [ HH.tr_ [ HH.th_ [ HH.text "id" ], HH.th_ [ HH.text "origin" ], HH.th_ [ HH.text "binding" ] ] ]
    , HH.tbody_ (map renderRow entries)
    ]
  where
  renderRow entry =
    HH.tr_
      [ HH.td_ [ HH.code_ [ HH.text (fromMaybe "?" (field "id" entry >>= toString)) ] ]
      , HH.td_ [ HH.text (originText entry) ]
      , HH.td_ [ bindingCell entry ]
      ]

  field name entry = toObject entry >>= Object.lookup name

  bindingCell entry = case field "binding" entry >>= toString of
    Just name -> HH.code_ [ HH.text name ]
    Nothing -> HH.text "\x2014"

  originText entry = fromMaybe "?" do
    origin <- field "origin" entry >>= toObject
    kind <- Object.lookup "kind" origin >>= toString
    case kind of
      "alloc" -> do
        site <- Object.lookup "site" origin >>= toNumber >>= Int.fromNumber
        key <- Object.lookup "key" origin
        pure ("alloc @" <> show site <> " " <> renderScalar key)
      "demand" -> do
        pathArr <- Object.lookup "path" origin >>= toArray
        path <- traverse toString pathArr
        pure ("demand ctx." <> joinWith "." path)
      _ -> Nothing

-- | Renders a v3-symbols §5.2 `"constraints"` array as an HTML table:
-- | name and arguments, each argument shown with `renderScalar` — so a
-- | symbol argument renders the same placeholder text
-- | `renderSymbolTable`'s rows and the document tree use.
renderConstraintTable :: forall action slots m. Array Json -> ComponentHTML action slots m
renderConstraintTable [] = HH.p_ [ HH.text "No constraints." ]
renderConstraintTable entries =
  HH.table_
    [ HH.thead_ [ HH.tr_ [ HH.th_ [ HH.text "name" ], HH.th_ [ HH.text "arguments" ] ] ]
    , HH.tbody_ (map renderRow entries)
    ]
  where
  renderRow entry =
    HH.tr_
      [ HH.td_ [ HH.code_ [ HH.text (fromMaybe "?" (field "name" entry >>= toString)) ] ]
      , HH.td_ [ HH.text (joinWith ", " (map renderScalar (fromMaybe [] (field "arguments" entry >>= toArray)))) ]
      ]

  field name entry = toObject entry >>= Object.lookup name

-- | Renders a v4-types \S8 `"types"` array (the envelope's type table) as
-- | an HTML table: canonical id, and its definition rendered to short text
-- | by `resolvedTypeText`. Declaration boundaries stay boundaries here too
-- | — a `ref` definition shows only the id it points at, never the
-- | pointee's own definition inlined, since that entry is its own row.
renderTypesTable :: forall action slots m. Array Json -> ComponentHTML action slots m
renderTypesTable [] = HH.p_ [ HH.text "No types." ]
renderTypesTable entries =
  HH.table_
    [ HH.thead_ [ HH.tr_ [ HH.th_ [ HH.text "id" ], HH.th_ [ HH.text "definition" ] ] ]
    , HH.tbody_ (map renderRow entries)
    ]
  where
  renderRow entry =
    HH.tr_
      [ HH.td_ [ HH.code_ [ HH.text (fromMaybe "?" (field "id" entry >>= toString)) ] ]
      , HH.td_ [ HH.code_ [ HH.text (maybe "?" resolvedTypeText (field "definition" entry)) ] ]
      ]

  field name entry = toObject entry >>= Object.lookup name

  maybe d f = case _ of
    Just x -> f x
    Nothing -> d

-- | Renders one `ResolvedType` JSON value (v4-types \S8's tagged union,
-- | `"kind"` \[?\] prim/array/record/union/ref/var) to a short one-line
-- | text form -- deliberately terse, since this is a table cell, not the
-- | canonical id itself.
resolvedTypeText :: Json -> String
resolvedTypeText j = fromMaybe "?" do
  o <- toObject j
  kind <- Object.lookup "kind" o >>= toString
  case kind of
    "prim" -> Object.lookup "name" o >>= toString
    "array" -> (\t -> "[" <> t <> "]") <$> (Object.lookup "element" o >>= (Just <<< resolvedTypeText))
    "record" -> do
      fieldsArr <- Object.lookup "fields" o >>= toArray
      pure ("{" <> joinWith ", " (map recordField fieldsArr) <> "}")
    "union" -> do
      armsArr <- Object.lookup "arms" o >>= toArray
      pure (joinWith " | " (map unionArm armsArr))
    "ref" -> Object.lookup "id" o >>= toString
    "var" -> do
      pathArr <- Object.lookup "path" o >>= toArray
      path <- traverse toString pathArr
      pure ("%ctx." <> joinWith "." path)
    _ -> Nothing
  where
  recordField f = fromMaybe "?" do
    fo <- toObject f
    name <- Object.lookup "name" fo >>= toString
    ty <- Object.lookup "type" fo
    pure (name <> ": " <> resolvedTypeText ty)

  unionArm a = fromMaybe "?" do
    ao <- toObject a
    name <- Object.lookup "name" ao >>= toString
    pure case Object.lookup "payload" ao of
      Just payload -> name <> "(" <> resolvedTypeText payload <> ")"
      Nothing -> name

-- | Renders a v4-types \S8 `"type-constraints"` array — same shape as
-- | `renderConstraintTable`'s `"constraints"` (`name`/`arguments`), except
-- | a type argument is the erased `{"$type": ...}` tag \S7 reserves rather
-- | than a plain scalar, so it needs its own argument formatter.
renderTypeConstraintTable :: forall action slots m. Array Json -> ComponentHTML action slots m
renderTypeConstraintTable [] = HH.p_ [ HH.text "No type constraints." ]
renderTypeConstraintTable entries =
  HH.table_
    [ HH.thead_ [ HH.tr_ [ HH.th_ [ HH.text "name" ], HH.th_ [ HH.text "arguments" ] ] ]
    , HH.tbody_ (map renderRow entries)
    ]
  where
  renderRow entry =
    HH.tr_
      [ HH.td_ [ HH.code_ [ HH.text (fromMaybe "?" (field "name" entry >>= toString)) ] ]
      , HH.td_ [ HH.text (joinWith ", " (map typeConstraintArgText (fromMaybe [] (field "arguments" entry >>= toArray)))) ]
      ]

  field name entry = toObject entry >>= Object.lookup name

  typeConstraintArgText a = case toObject a >>= Object.lookup "$type" >>= toString of
    Just tid -> tid
    Nothing -> renderScalar a
