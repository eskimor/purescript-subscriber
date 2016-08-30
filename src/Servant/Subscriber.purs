-- | High level declarative interface for servant-subscriber.
module Servant.Subscriber (
  Subscriber
  , makeSubscriber
  , deploy
  , getConnection
  , module Exports )where


import Prelude


import Servant.Subscriber.Subscriptions as Subs
import Control.Monad.Eff.Ref (newRef, writeRef, readRef, Ref)
import Data.Monoid (mempty)
import Servant.Subscriber.Connection (SubscriberEff, Connection, Config, realize, subscribeAll, unsubscribeAll, makeConnection)
import Servant.Subscriber.Connection (Config) as Exports
import Servant.Subscriber.Internal (ToUserType, SubscriberEff) as Exports
import Servant.Subscriber.Subscriptions (Subscriptions, diffSubscriptions)
import Servant.Subscriber.Subscriptions (Subscriptions, makeSubscriptions) as Exports

newtype Subscriber eff a = Subscriber (SubscriberImpl eff a)

type SubscriberImpl eff a = {
    connection :: Connection eff a
  , old :: Ref (Subscriptions a)
  }

makeSubscriber :: forall eff a. Config eff a -> SubscriberEff eff (Subscriber eff a)
makeSubscriber c = do
  conn <- makeConnection c
  old' <- newRef mempty
  pure $ Subscriber {
    connection : conn
  , old : old'
  }

-- | Get access to the low-level Connection.
getConnection :: forall eff a. Subscriber eff a -> Connection eff a
getConnection (Subscriber impl) = impl.connection


-- | Deploy a given set of Subscriptions.
--
--   This function takes care of unsubscribing subscriptions which are no longer present adds any new ones, updates
--   already existing ones and also calls realize for actually sending Subscribe/Unsubscribe commands to the server.
deploy :: forall eff a. Subscriptions a -> Subscriber eff a -> SubscriberEff eff Unit
deploy subs (Subscriber impl)= do
  old' <- readRef impl.old
  let
    forUnsubscribe = map (_.req) <<< Subs.toList $ diffSubscriptions old' subs
  unsubscribeAll forUnsubscribe impl.connection
  subscribeAll (Subs.toList subs) impl.connection
  realize impl.connection
  writeRef impl.old subs
