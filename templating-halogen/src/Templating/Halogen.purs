-- | Folds the generic `Node` AST into real Halogen output. Kept as the
-- | only module in this package depending on `halogen` — `Templating.Ast`
-- | /`Parser`/`Eval` have no Halogen dependency at all, so the
-- | parser/evaluator core could in principle fold to something else
-- | later (see `specs/templating-language.md`).
module Templating.Halogen
  ( foldToHalogen
  , isValidAttrName
  , validateAttrNames
  ) where

import Prelude

import Data.Array as Array
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.String.CodeUnits (toCharArray)
import Data.Tuple (Tuple(..), fst)
import Halogen.HTML (ComponentHTML, ElemName(..))
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Templating.Ast (ActionPayload, Node(..))
import Web.HTML.Common (AttrName(..))

-- | `dispatch` maps a structured `action(...)` payload (event type, key,
-- | JSON payload — see `Templating.Ast`'s `ActionPayload`, attached in
-- | the template via `action("on-click", "some-key", {...})`) onto a real
-- | Halogen action; a host that wants purely read-only rendering just
-- | supplies `const Nothing`. A payload that maps to `Nothing` —
-- | including every payload, for a read-only host — attaches no click
-- | handler at all, matching the "fire-once action" scope. `eventType`
-- | is always `"on-click"` today (the only value `Templating.Eval`
-- | accepts — see `supportedActionEventTypes`), so this always wires
-- | `HE.onClick` when an action is present; continuous-input handling
-- | (`HE.onValueInput`-style) is explicitly out of scope, see the spec.
-- | `foldToHalogen` trusts `r.attrs`'s keys are legal DOM attribute names
-- | and passes them straight to `HP.attr`/`Element.setAttribute` — but
-- | `Templating.Parser`'s `quotedKey` accepts arbitrary text for attribute
-- | keys (it's shared with JSON-object-literal keys, which have no such
-- | restriction), so a template can produce a `Node` whose attrs map has a
-- | key the real DOM rejects, throwing an uncaught `Element.setAttribute:
-- | Invalid attribute name` `DOMException` mid-render. Call
-- | `validateAttrNames` on the evaluated `Node` first and handle a
-- | non-empty result (e.g. render an error instead) rather than folding
-- | straight through.
foldToHalogen :: forall action slots m. (ActionPayload -> Maybe action) -> Node -> ComponentHTML action slots m
foldToHalogen _ (NText s) = HH.text s
foldToHalogen dispatch (NElement r) =
  HH.element (ElemName r.tag) (attrProps <> actionProp) children
  where
  attrProps = map (\(Tuple k v) -> HP.attr (AttrName k) v) (Map.toUnfoldable r.attrs)

  actionProp = case r.action >>= dispatch of
    Just a -> [ HE.onClick \_ -> a ]
    Nothing -> []

  children = map (foldToHalogen dispatch) r.children

-- | A DOM attribute name we're willing to set: alphanumeric plus `-`/`_`
-- | only (no spaces, colons, quotes, ...) — deliberately stricter than
-- | what HTML itself permits, since the only names templates should ever
-- | need are kebab-case/snake_case identifiers like `data-count`.
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
validateAttrNames (NText _) = []
validateAttrNames (NElement r) =
  Array.nub (invalidHere <> Array.concatMap validateAttrNames r.children)
  where
  invalidHere = Array.filter (not <<< isValidAttrName) (map fst (Map.toUnfoldable r.attrs :: Array (Tuple String String)))
