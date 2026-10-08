-- | Builders for 'Json' fixtures, so a spec can spell an object as a list of
-- @key .= value@ pairs. A Haskell 'Int' becomes an integer and a 'Double' a
-- float, which is the host binding these specs use throughout.
module Tramaj.TestJson
  ( ToJ (..)
  , object
  , (.=)
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Tramaj.Json (Json (..))

class ToJ a where
  toJ :: a -> Json

instance ToJ Json where
  toJ = id

instance ToJ Int where
  toJ = JInt . toInteger

instance ToJ Double where
  toJ = JFloat

instance ToJ Bool where
  toJ = JBool

instance ToJ Text where
  toJ = JString

instance (ToJ a) => ToJ [a] where
  toJ = JArray . map toJ

object :: [(Text, Json)] -> Json
object = JObject . Map.fromList

infixr 8 .=

(.=) :: (ToJ a) => Text -> a -> (Text, Json)
k .= v = (k, toJ v)
