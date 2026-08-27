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
module Tramaj.Halogen
  ( foldToHalogen
  , renderScalar
  , isValidAttrName
  , validateAttrNames
  ) where

import Prelude

import Data.Argonaut.Core (Json, isNull, stringify, toBoolean, toNumber, toString)
import Data.Array as Array
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.String.CodeUnits (toCharArray)
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
foldToHalogen _ (NText value _) = [ HH.text (renderScalar value) ]
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
    if Array.null folded && not (isNull value) then [ HH.text (renderScalar value) ]
    else folded
foldToHalogen dispatch (NFragment children _) =
  Array.concatMap (foldToHalogen dispatch) children

-- | How this host renders a JSON value as DOM text. A string is itself, a
-- | whole number drops its trailing `.0`, `null` renders as nothing, and
-- | anything structured falls back to compact JSON.
-- |
-- | Deliberately this module's decision rather than the evaluator's: a
-- | different host targeting YAML or a UI model would render the same
-- | values differently, and v2's `Node` keeps them unconverted precisely so
-- | that it can.
renderScalar :: Json -> String
renderScalar j = case toString j of
  Just s -> s
  Nothing -> case toNumber j of
    Just n -> case Int.fromNumber n of
      Just i -> show i
      Nothing -> show n
    Nothing -> case toBoolean j of
      Just b -> if b then "true" else "false"
      Nothing -> if isNull j then "" else stringify j

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
