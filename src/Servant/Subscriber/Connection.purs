-- | Low level interface for communicating with Subscriber. 
--
--   For a high-level declarative interface see "Servant.Subscriber".
module Servant.Subscriber.Connection (
    Config
  , module Exports
  , makeConnection
  , subscribe
  , subscribeAll
  , unsubscribe
  , unsubscribeAll
  , close
  ) where

import Prelude
import Control.Monad.Eff.Ref as Ref
import Data.List as List
import Data.StrMap as StrMap
import Data.StrMap.ST as SM
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
import Data.Maybe (isJust, Maybe(Nothing, Just))
import Data.StrMap (StrMap)
import Data.StrMap.ST (STStrMap)
import Prelude (unit, Unit, bind, pure, (<<<), ($))
import Servant.Subscriber.Internal (SubscriptionState(Ordered), getHttpReq, OrderKey, Order, mutate, Orders, makeOrderKey, Subscription, Notification, Connection, SubscriberEff)
import Servant.Subscriber.Internal (Connection, SubscriberEff, Notification(..), realize, ToUserType) as Exports
import Servant.Subscriber.Request (HttpRequest, Request(Unsubscribe, Subscribe))
import Servant.Subscriber.Subscriptions (Subscriptions)
import Servant.Subscriber.Types (Path)
import WebSocket (Code(Code))

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

-- | Add a single subscription to orders.
--
-- For actually sending requests to the server call `realize`.
subscribe :: forall eff a. Subscription a -> Connection eff a -> SubscriberEff eff Unit
subscribe sub impl = do
      modifyRef impl.orders
        $ StrMap.alter (Just <<< updateOrder sub) (makeOrderKey sub.req)

-- | Add all given subscriptions to orders for being subscribed. 
--
-- For actually sending requests to the server call `realize`.
subscribeAll :: forall eff a. List (Subscription a) -> Connection eff a -> SubscriberEff eff Unit
subscribeAll subsList impl = do
    modifyRef impl.orders $ insertSubscriptions subsList
  where
    insertSubscriptions :: List (Subscription a) -> Orders a -> Orders a
    insertSubscriptions subs = mutate (\ orders' -> List.foldM mutSubscribe orders' subs)

-- | Internal function used by subscribeAll for efficiently adding many subscriptions.
mutSubscribe :: forall a h. STStrMap h (Order a) -> Subscription a -> Eff (st :: ST h) (STStrMap h (Order a))
mutSubscribe orders sub = do
  old <- SM.peek orders $ makeOrderKey sub.req
  let new = updateOrder sub old
  SM.poke orders (makeOrderKey sub.req) new

-- | Unsubscribe all given requests.
--
-- For actually sending requests to the server call `realize`.
unsubscribeAll :: forall eff a. List HttpRequest -> Connection eff a -> SubscriberEff eff Unit
unsubscribeAll reqs impl = do
  let
    keys = map makeOrderKey reqs
  mc <- readRef impl.connection
  modifyRef impl.orders $ deleteSubscriptions (isJust mc) keys
  where
    deleteSubscriptions :: Boolean -> List OrderKey -> Orders a -> Orders a
    deleteSubscriptions isActive keys = mutate (\orders' -> List.foldM (mutUnsubscribe isActive) orders' keys)

-- | Internal function used by unsubscribeAll for efficiently removing many subscriptions.
mutUnsubscribe :: forall a h. Boolean -> STStrMap h (Order a) -> OrderKey -> Eff (st :: ST h) (STStrMap h (Order a))
mutUnsubscribe connActive orders key = if connActive
                                        then do
                                          mOrder' <- SM.peek orders key
                                          case mOrder' of
                                            Nothing -> pure orders
                                            Just order' -> SM.poke orders key $ order' {
                                                req = Unsubscribe $ getHttpReq order'.req
                                              , state = Ordered
                                              }
                                        else SM.delete orders key

-- | Unsubscribe a given request.
--
-- For actually sending requests to the server call `realize`.
unsubscribe :: forall eff a. HttpRequest -> Connection eff a -> SubscriberEff eff Unit
unsubscribe req' impl = do
      mc <- readRef impl.connection
      case mc of
        Nothing -> modifyRef impl.orders $ StrMap.delete (makeOrderKey req')
        Just c -> do
          let key = makeOrderKey req'
          modifyRef impl.orders $ StrMap.update (Just <<< _ { req = Unsubscribe req', state = Ordered}) key


updateOrder :: forall a. Subscription a -> Maybe (Order a) -> Order a
updateOrder sub orig = case orig of
    Nothing -> {
        state : Ordered
      , req : Subscribe sub.req
      , parseResponses : sub.parseResponses
      }
    Just o -> o { parseResponses = sub.parseResponses }
