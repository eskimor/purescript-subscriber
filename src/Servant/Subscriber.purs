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
import WebSocket as WS
import WebSocket as WS
import Control.Bind ((<=<))
import Control.Monad.Eff.Ref (modifyRef, readRef, writeRef, newRef)
import Data.Lens (_Just, (.~))
import Data.Lens.At (at)
import Data.Maybe (Maybe(Nothing, Just))
import Data.StrMap (StrMap)
import Prelude (Unit, bind, unit, pure, (<<<), ($))
import Servant.Subscriber.Internal (Connection, SubscriberEff, Notification(..)) as Internal
import Servant.Subscriber.Request (HttpRequest, Request(Subscribe, Unsubscribe))
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

subscribe :: forall eff a. HttpRequest -> ToUserType a -> Connection eff a -> SubscriberEff eff Unit
subscribe request parseResponse impl = do
      modifyRef impl.orders $ at (makeOrderKey request) .~ Just { state : Ordered
                                                                   , req : Subscribe request
                                                                   , parseResponse : parseResponse
                                                                   }
      tryRealize impl

unsubscribe :: forall eff a. HttpRequest -> Connection eff a -> SubscriberEff eff Unit
unsubscribe req' impl = do
      mc <- readRef impl.connection
      case mc of
        Nothing -> modifyRef impl.orders $ StrMap.delete (makeOrderKey req')
        Just c -> do
          let key = makeOrderKey req'
          modifyRef impl.orders $ StrMap.update (Just <<< _ { req = Unsubscribe req', state = Ordered}) key 
          tryRealize impl

