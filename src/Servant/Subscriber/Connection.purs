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
  , setPongRequest
  , setCloseRequest
  , close
  , getUrl
  ) where

import Prelude
import Control.Monad.Eff.Ref as Ref
import Data.List as List
import Data.StrMap as StrMap
import Data.StrMap.ST as SM
import WebSocket as WS
import Control.Bind ((<=<))
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Ref (modifyRef, readRef, writeRef, newRef)
import Control.Monad.ST (ST)
import Data.List (List)
import Data.Maybe (isJust, Maybe(Nothing, Just), fromMaybe)
import Data.StrMap.ST (STStrMap)
import Servant.Subscriber.Internal (Connection, SubscriberEff, Notification(..), realize, ToUserType) as Exports
import Servant.Subscriber.Internal (makeOrderKey, SubscriptionState(Ordered), getHttpReq, OrderKey, Order, mutate, Orders, Subscription, Notification, Connection, SubscriberEff)
import Servant.Subscriber.Request (HttpRequest, Request(Unsubscribe, Subscribe, SetPongRequest, SetCloseRequest))
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
      pongRequest <- Ref.newRef Nothing
      closeRequest <- Ref.newRef Nothing
      pure $ {
          orders : orders
        , url : WS.URL c.url
        , callback :  c.callback
        , notify :  c.notify
        , connection : connRef
        , pongRequest : pongRequest
        , closeRequest : closeRequest
        }

-- | Which url is this subscriber connected to?
getUrl :: forall eff a. Connection eff a -> String
getUrl conn = case conn.url of
  WS.URL url' -> url'

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

-- | Set a request which will be issued by the server on every websocket pong event.
-- |
-- | Currently a pong request can not be unset, once set it is there for eternity
-- | you can only change it to something else. This of course can be fixed when needed!
-- |
-- | WARNING: Don't ever subscribe a request and also call setPongRequest on it, this might not work as expected.
-- |          (The Subscribed response is used in both cases, so one of the two requests might never get confirmed)
-- |          Also never call setPongRequest and setCloseRequest on the same request. This restriction is mostly
-- |          because of laziness and can of course also be fixed!.
-- |
-- | WARNING (another one): You have to call realize after calling this function, otherwise nothing will happen!
setPongRequest :: forall eff a. HttpRequest -> Connection eff a -> SubscriberEff eff Unit
setPongRequest req' impl = do
      let newKey = makeOrderKey req'
      prevKey <- readRef impl.pongRequest
      when (Just newKey /= prevKey) $ do -- | Nothing new - no need to do anything.
        modifyRef impl.orders $
          deletePrevious prevKey
          >>> StrMap.insert newKey { req : SetPongRequest req'
                                   , parseResponses : List.Nil
                                   , state : Ordered
                                   }
        writeRef impl.pongRequest $ Just newKey

-- | Set a request which will be issued by the server when the websocket connection closes for any reason.
-- |
-- | Currently a close request can not be unset, once set it is there for eternity
-- | you can only change it to something else. This of course can be fixed when needed!
-- |
-- | WARNING: Don't ever subscribe a request and also call setCloseRequest on it, this might not work as expected.
-- |          (The `Subscribed` response is used in both cases, so one of the two requests might never get confirmed)
-- |          Also never call `setPongRequest` and `setCloseRequest` on the same request. This restriction is mostly
-- |          because of my laziness and can of course also be fixed!.
setCloseRequest :: forall eff a. HttpRequest -> Connection eff a -> SubscriberEff eff Unit
setCloseRequest req' impl = do
      let newKey = makeOrderKey req'
      prevKey <- readRef impl.closeRequest
      when (Just newKey /= prevKey) $ do -- | Nothing new - no need to do anything.
        modifyRef impl.orders $
          deletePrevious prevKey
          >>> StrMap.insert newKey { req : SetCloseRequest req'
                                   , parseResponses : List.Nil
                                   , state : Ordered
                                   }
        writeRef impl.closeRequest $ Just newKey

-- | Add all given subscriptions to orders for being subscribed.
-- |
-- | For actually sending requests to the server call `realize`.
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
-- |
-- | For actually sending requests to the server call `realize`.
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



updateOrder :: forall a. Subscription a -> Maybe (Order a) -> Order a
updateOrder sub orig = case orig of
    Nothing -> {
        state : Ordered
      , req : Subscribe sub.req
      , parseResponses : sub.parseResponses
      }
    Just o -> o { parseResponses = sub.parseResponses }


-- | Helper function for setPongRequest and setCloseRequest.
deletePrevious :: forall a. Maybe OrderKey -> Orders a -> Orders a
deletePrevious mKey = fromMaybe id (StrMap.delete <$> mKey)
