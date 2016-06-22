-- TODO: ON ERROR: RECONNECT!
module Servant.Subscriber (
    makeSubscriber
  , subscribe
  , unsubscribe
  , close
  , Subscriber
  , NotifyEvent (..)
  , SubscriberEff
  ) where

import Prelude
import Control.Monad.Eff.Ref as Ref
import Control.Monad.Eff.Var as Var
import Data.List as List
import Data.StrMap as StrMap
import Servant.Subscriber.Response as Resp
import WebSocket as WS
import Control.Bind ((<=<))
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Exception (Error, EXCEPTION, catchException)
import Control.Monad.Eff.Ref (Ref, REF, modifyRef, writeRef, newRef, readRef)
import DOM.Event.Types (Event)
import DOM.Websocket.Event.Types (CloseEvent, MessageEvent)
import DOM.Websocket.Event.CloseEvent as CloseEvent
import DOM.HTML.Event.ErrorEvent as ErrorEvent
import Data.Argonaut.Generic.Aeson (encodeJson, decodeJson)
import Data.Argonaut.Parser (jsonParser)
import Data.Argonaut.Printer (printJson)
import Data.Either (Either(Right, Left))
import Data.Foldable (sequence_, intercalate, foldl)
import Data.Generic (class Generic)
import Data.Lens (view, prism, (.~), _Just, _2)
import Data.Lens.At (at)
import Data.Lens.Lens (lens)
import Data.Lens.Types (PrismP, LensP)
import Data.Maybe (Maybe(Nothing, Just))
import Data.StrMap (StrMap)
import Data.Tuple (fst)
import Servant.Subscriber.Request (HttpRequest(HttpRequest), Request(Subscribe, Unsubscribe))
import Servant.Subscriber.Response (Response)
import Servant.Subscriber.Types (Path(Path))
import Unsafe.Coerce (unsafeCoerce)
import WebSocket (ReadyState(Open), Code(Code), WEBSOCKET, Connection(..), newWebSocket, Message(..))


type SubscriberEff eff = Eff (ref :: REF, ws :: WEBSOCKET, err :: EXCEPTION | eff)


type SubscriberImpl = {
    subscriptions :: Ref Subscriptions
  , url :: WS.URL
  , notify :: forall eff. NotifyEvent -> SubscriberEff eff Unit
  , connection :: Ref (Maybe Connection)
  }


newtype Subscriber = Subscriber SubscriberImpl

data NotifyEvent = NotifyEvent Response
    | ParseError String -- We could not parse the server's response
    | WebSocketError String
    | WebSocketClosed String

derive instance genericNotifyEvent :: Generic NotifyEvent

type Subscriptions = StrMap Subscription

type Subscription = {
    req :: Request
  , state :: SubscriptionState
  }

req :: forall r a. LensP ({ req :: a | r}) a
req = lens _.req (\r -> r { req = _ })

state :: forall r a. LensP ({ state :: a | r}) a
state = lens _.state (\r -> r { state = _ })


data SubscriptionState = Ordered | Sent | Confirmed

derive instance eqSubscriptionState :: Eq SubscriptionState

coerceEffects :: forall eff0 eff1 a. Eff eff0 a -> Eff eff1 a
coerceEffects = unsafeCoerce

makeSubscriber :: forall eff. String -> (NotifyEvent -> SubscriberEff eff Unit) -> SubscriberEff eff Subscriber
makeSubscriber url h = do
      connRef <- newRef Nothing
      subscriptions <- Ref.newRef StrMap.empty
      pure $ Subscriber {
                    subscriptions : subscriptions
                  , url : WS.URL url
                  , notify : coerceEffects <<< h
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


tryRealize :: forall eff. SubscriberImpl -> SubscriberEff eff Unit
tryRealize impl = do
      mc <- readRef impl.connection
      case mc of
          Nothing -> makeConnection impl
          Just c'@(Connection c) -> do
            rdy <- Var.get c.readyState
            case rdy of
              Open -> realize c' impl
              _    -> pure unit

-- | Takes care of actually subscribing stuff.
realize :: forall eff. Connection -> SubscriberImpl -> SubscriberEff eff Unit
realize (Connection conn) impl = do
      ordered <- List.filter ((_ == Ordered) <<< _.state) <<< StrMap.values <$> Ref.readRef impl.subscriptions
      let mkMsg = Message <<< printJson <<< encodeJson
      let msgs = map (mkMsg <<< _.req) ordered
      sequence_ $ map (coerceEffects <<< conn.send) msgs
    --  modifyRef impl.subscriptions $ over (mapped <<< state <<< match Requested) (const Sent) -- Does not work currently.
    --  modifyRef impl.subscriptions $ traverse <<< state <<< filtered (_ == Ordered) .~ Sent -- Does not work currently
      modifyRef impl.subscriptions $ map (\sub -> if sub.state == Ordered then sub { state = Sent } else sub)

initConnection :: forall eff. SubscriberImpl -> SubscriberEff eff Unit
initConnection impl = do
      mConn <- readRef impl.connection
      case mConn of
        Nothing -> makeConnection impl
        Just _ -> pure unit


makeConnection :: forall eff. SubscriberImpl -> SubscriberEff eff Unit
makeConnection impl = do
      Connection conn <- newWebSocket impl.url []
      Var.set conn.onclose   $ closeHandler impl
      Var.set conn.onmessage $ messageHandler impl
      Var.set conn.onerror   $ errorHandler impl
      Var.set conn.onopen    $ openHandler (Connection conn) impl
      writeRef impl.connection $ Just (Connection conn)


openHandler :: forall eff. Connection -> SubscriberImpl -> Event -> SubscriberEff eff Unit
openHandler conn impl _ = realize conn impl

closeHandler :: forall eff. SubscriberImpl -> CloseEvent -> SubscriberEff eff Unit
closeHandler impl ev = do
      writeRef impl.connection Nothing
      subs <- readRef impl.subscriptions
      if StrMap.isEmpty subs
        then pure unit
        else do
          modifyRef impl.subscriptions $ updateSubscriptions
          makeConnection impl
      impl.notify $ WebSocketClosed ("code: " <> (show <<< CloseEvent.code) ev <> ", reason: " <> CloseEvent.reason ev)
  where
    isUnsubscribe :: Request -> Boolean
    isUnsubscribe (Unsubscribe _) = true
    isUnsubscribe _ = false

    updateSubscriptions :: Subscriptions -> Subscriptions
    updateSubscriptions subs = let
          forRemoval = map fst <<< List.filter (isUnsubscribe <<< view (_2 <<< req)) <<< StrMap.toList $ subs
          cleanedSubs = foldl (flip StrMap.delete) subs forRemoval
        in
          map ( _ { state = Ordered } ) cleanedSubs

errorHandler :: forall eff. SubscriberImpl -> Event -> SubscriberEff eff Unit
errorHandler impl ev = do
      impl.notify $ WebSocketError ((ErrorEvent.message <<< unsafeCoerce) ev)
      tryRealize impl -- Something went wrong - retry. (TODO: Probably better with some timeout!)


messageHandler :: forall eff. SubscriberImpl -> MessageEvent -> SubscriberEff eff Unit
messageHandler impl msgEvent =  do
      let msg = WS.runMessage <<< WS.runMessageEvent $ msgEvent
      let eDecoded = decodeJson <=< jsonParser $ msg
      case eDecoded of
        Left err -> impl.notify $ ParseError (err <> ", input: '" <> msg <> "'")
        Right resp -> do
            modifyRef impl.subscriptions $ case resp of
                Resp.Subscribed path   -> at (pathToKey path) <<< _Just <<< state .~ Confirmed
                Resp.Deleted path      -> at (pathToKey path) .~ (Nothing :: Maybe Subscription)
                Resp.Unsubscribed path -> at (pathToKey path) .~ (Nothing :: Maybe Subscription)
                Resp.Modified _ _      -> id
                Resp.RequestError _    -> id
            impl.notify $ NotifyEvent resp

reqToPath :: HttpRequest -> Path
reqToPath (HttpRequest r) = r.httpPath

reqToKey :: HttpRequest -> String
reqToKey = pathToKey <<< reqToPath

pathToKey :: Path -> String
pathToKey (Path p) = intercalate "/" p

-- | Prism for only setting a value if it is equal to a.
match :: forall a. Eq a => a -> PrismP a a
match a = prism id $ \b -> if a == b then Right a else Left b


try :: forall a eff. Eff (err :: EXCEPTION | eff) a -> Eff eff (Either Error a)
try action = catchException (pure <<< Left) (map Right action)

