module Servant.Subscriber.Subscriptions (
    Subscriptions
  , makeSubscriptions
  , diffSubscriptions
  , toList
  ) where

import Prelude

import Data.StrMap as StrMap
import Data.StrMap.ST as SM
import Control.Monad.Eff (Eff)
import Control.Monad.ST (ST)
import Data.Function.Uncurried (runFn4)
import Data.Generic (gShow)
import Data.List (List(Nil, Cons))
import Data.Monoid (class Monoid)
import Data.StrMap (StrMap, foldM)
import Data.StrMap.ST (STStrMap)
import Servant.Subscriber.Internal (_lookup, mutate, ToUserType, Subscription)
import Servant.Subscriber.Request (HttpRequest)

newtype Subscriptions a = Subscriptions (StrMap (Subscription a))

makeSubscriptions :: forall a. HttpRequest -> ToUserType a -> Subscriptions a
makeSubscriptions req' parser = Subscriptions $ StrMap.singleton (gShow req')
    {
      req : req'
    , parseResponses : Cons parser Nil
    }

toList :: forall a. Subscriptions a -> List (Subscription a)
toList (Subscriptions a) = StrMap.values a

mergeParsers :: forall a. Subscription a -> Subscription a -> Subscription a
mergeParsers subA subB = subA {
    parseResponses = subA.parseResponses <> subB.parseResponses
  }

mergeStrMap :: forall a. StrMap (Subscription a) -> StrMap (Subscription a) -> StrMap (Subscription a)
mergeStrMap m1 m2 = mutate (\s1 -> foldM (\s2 k v2 -> SM.poke s2 k (runFn4 _lookup v2 (\v1 -> mergeParsers v1 v2) k m2)) s1 m1) m2


instance semigroupSubscriptions :: Semigroup (Subscriptions a) where
  append (Subscriptions a) (Subscriptions b) = Subscriptions $ mergeStrMap a b

instance monoidSubscriptions :: Monoid (Subscriptions a) where
  mempty = Subscriptions $ StrMap.empty

instance functorSubscriptions :: Functor Subscriptions where
  map f (Subscriptions a) = Subscriptions $ map (mapSubscription f) a

-- | Calculates the items which are in the first map but not in the second.
--   In other words: All elements present in the second map will be removed from the first.
diffSubscriptions :: forall a. Subscriptions a -> Subscriptions a -> Subscriptions a
diffSubscriptions (Subscriptions a) (Subscriptions b) = Subscriptions $ diffMaps a b

-- | Calculates the items which are in the first map but not in the second.
--   In other words: All elements present in the second map will be removed from the first.
diffMaps :: forall a. StrMap a -> StrMap a -> StrMap a
diffMaps a b = (mutate (\a' -> StrMap.foldM deleteItem a' b)) a
  where
    deleteItem :: forall x h r. STStrMap h x -> String -> x -> Eff (st :: ST h | r) (STStrMap h x)
    deleteItem m key _ = SM.delete m key

mapSubscription :: forall a b. (a -> b) -> Subscription a -> Subscription b
mapSubscription f orig = orig {  parseResponses  = map (map f) <$> orig.parseResponses }
