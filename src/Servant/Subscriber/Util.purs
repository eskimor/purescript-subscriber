-- | Utility functions and types needed by servant-purescript code generator.
module Servant.Subscriber.Util where

import Prelude
import Data.Argonaut.Generic.Aeson (decodeJson)
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(Tuple))
import Data.Generic (class Generic)
import Data.Traversable (traverse)
import Servant.PureScript.Settings (gDefaultToURLPiece)
import Data.Array (concatMap)

import Servant.Subscriber (ToUserType)

type TypedToUser a b = Maybe a -> b


toUserType :: forall a b. Generic a => TypedToUser a b -> ToUserType b
toUserType typed = map typed <<< traverse decodeJson


subGenNormalQuery :: forall a . Generic a => String -> a -> Array (Tuple String (Maybe String))
subGenNormalQuery fName val = [ Tuple fName ((Just <<< gDefaultToURLPiece) val) ]

subGenListQuery :: forall a . Generic a => String -> Array a -> Array (Tuple String (Maybe String))
subGenListQuery fName = concatMap (subGenNormalQuery fName)

subGenFlagQuery :: String -> Boolean -> Array (Tuple String (Maybe String))
subGenFlagQuery fName false = []
subGenFlagQuery fName true  = [ Tuple fName Nothing ]
