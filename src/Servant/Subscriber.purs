module Servant.Subscriber (
    Config
  , module Internal
  , makeSubscriber
  , subscribe
  , unsubscribe
  , close
  ) where

import Control.Bind ((<=<))
import Control.Monad.Eff.Ref (modifyRef, readRef, writeRef, newRef)
import Control.Monad.Eff.Ref as Ref
import Data.Lens (_Just, (.~))
import Data.Lens.At (at)
import Data.Maybe (Maybe(Nothing, Just))
import Data.StrMap as StrMap
import Prelude (Unit, bind, unit, pure, (<<<), ($))
import Servant.Subscriber.Request (HttpRequest, Request(Subscribe, Unsubscribe))
import Servant.Subscriber.Types (Path)
import WebSocket (Code(Code), Connection(Connection))
import WebSocket as WS

import Servant.Subscriber.Internal
import Servant.Subscriber.Internal ( Subscriber
                                   , SubscriberEff
                                   , ResourceEvent (..)
                                   , SignalEvent (..)
                                   ) as Internal

type Config = {
    url    :: String
  , notify :: forall eff. ResourceEvent        -> SubscriberEff eff Unit
  , signal :: forall eff. SignalEvent          -> SubscriberEff eff Unit
  }


makeSubscriber :: forall eff. Config -> SubscriberEff eff Subscriber
makeSubscriber c = do
      connRef <- newRef Nothing
      subscriptions <- Ref.newRef StrMap.empty
      pure $ Subscriber {
                    subscriptions : subscriptions
                  , url : WS.URL c.url
                  , notify : coerceEffects <<< c.notify
                  , signal : coerceEffects <<< c.signal
                  , connection : connRef
                  }

-- | Drop all subscriptions and close connection.
close :: forall eff. Subscriber -> SubscriberEff eff Unit
close (Subscriber impl) = do
      writeRef impl.subscriptions StrMap.empty
      mConn <- readRef impl.connection
      case mConn of
        Nothing -> pure unit
        Just (Connection conn) -> conn.close' (Code 1000) Nothing

subscribe :: forall eff. HttpRequest -> Subscriber -> SubscriberEff eff Unit
subscribe request (Subscriber impl) = do
      modifyRef impl.subscriptions $ at (reqToKey request) .~ Just { state : Ordered, req : Subscribe request }
      tryRealize impl

unsubscribe :: forall eff. Path -> Subscriber -> SubscriberEff eff Unit
unsubscribe p (Subscriber impl) = do
      mc <- readRef impl.connection
      case mc of
        Nothing -> modifyRef impl.subscriptions $ StrMap.delete (pathToKey p)
        Just c -> do
          modifyRef impl.subscriptions $ at (pathToKey p) <<< _Just .~ { req : Unsubscribe p, state : Ordered }
          tryRealize impl

