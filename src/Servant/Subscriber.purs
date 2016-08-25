module Servant.Subscriber (
    Config
  , module Internal
  , makeConnection
  , subscribe
  , unsubscribe
  , close
  ) where

import Servant.Subscriber.Internal
import Control.Monad.Eff.Ref as Ref
import Data.StrMap as StrMap
import Servant.Subscriber.Subscriptions as Subscriptions
import WebSocket as WS
import WebSocket as WS
import Control.Bind ((<=<))
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Ref (modifyRef, readRef, writeRef, newRef)
import Control.Monad.ST (ST)
import Data.Lens (_Just, (.~))
import Data.Lens.At (at)
import Data.List (List(Cons, Nil))
import Data.Maybe (Maybe(Nothing, Just))
import Data.StrMap (StrMap)
import Data.StrMap.ST (STStrMap)
import Prelude (Unit, bind, unit, pure, (<<<), ($))
import Servant.Subscriber.Internal (Connection, SubscriberEff, Notification(..)) as Internal
import Servant.Subscriber.Request (HttpRequest, Request(Subscribe, Unsubscribe))
import Servant.Subscriber.Subscriptions (Subscriptions)
import Servant.Subscriber.Types (Path)
import WebSocket (Code(Code))
import Data.StrMap.ST as SM
import Data.List as List

type Config eff a = {
    url    :: String
  , callback ::  a -> SubscriberEff eff Unit
  , notify ::  Notification -> SubscriberEff eff Unit
  }


makeConnection :: forall eff a. Config eff a -> SubscriberEff eff (Connection eff a)
makeConnection c = do
      connRef <- newRef Nothing
      orders <-  Ref.newRef StrMap.empty
      pure $ {
          orders : orders
        , url : WS.URL c.url
        , callback :  c.callback
        , notify :  c.notify
        , connection : connRef
        }

-- | Drop all subscriptions and close connection.
close :: forall eff a. Connection eff a -> SubscriberEff eff Unit
close impl = do
      writeRef impl.orders StrMap.empty
      mConn <- readRef impl.connection
      case mConn of
        Nothing -> pure unit
        Just (WS.Connection conn) -> conn.close' (Code 1000) Nothing

subscribe :: forall eff a. Subscription a -> Connection eff a -> SubscriberEff eff Unit
subscribe sub impl = do
      modifyRef impl.orders
        $ StrMap.alter (Just <<< updateOrder sub) (makeOrderKey sub.req)
      tryRealize impl

subscribeAll :: forall eff a. Subscriptions a -> Connection eff a -> SubscriberEff eff Unit
subscribeAll subs impl = do
    let subsList = Subscriptions.toList subs
    modifyRef impl.orders $ insertSubscriptions subsList
  where
    insertSubscriptions :: List (Subscription a) -> Orders a -> Orders a
    insertSubscriptions subs = mutate $ \ orders' -> List.foldM mutSubscribe orders' subs

mutSubscribe :: forall a h r. STStrMap h (Order a) -> Subscription a -> Eff (st :: ST h | r) (STStrMap h (Order a))
mutSubscribe orders sub = do
  old <- SM.peek orders $ makeOrderKey sub.req
  let new = updateOrder sub old
  SM.poke orders (makeOrderKey sub.req) new

unsubscribe :: forall eff a. HttpRequest -> Connection eff a -> SubscriberEff eff Unit
unsubscribe req' impl = do
      mc <- readRef impl.connection
      case mc of
        Nothing -> modifyRef impl.orders $ StrMap.delete (makeOrderKey req')
        Just c -> do
          let key = makeOrderKey req'
          modifyRef impl.orders $ StrMap.update (Just <<< _ { req = Unsubscribe req', state = Ordered}) key
          tryRealize impl


updateOrder :: forall a. Subscription a -> Maybe (Order a) -> Order a
updateOrder sub orig = case orig of
    Nothing -> {
        state : Ordered
      , req : Subscribe sub.req
      , parseResponses : sub.parseResponses
      }
    Just o -> o { parseResponses = sub.parseResponses }
