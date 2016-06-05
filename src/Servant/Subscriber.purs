module Servant.Subscriber where

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
import DOM.Event.Types (Event, MessageEvent)
import Data.Argonaut.Aeson (gAesonEncodeJson, gAesonDecodeJson)
import Data.Argonaut.Parser (jsonParser)
import Data.Argonaut.Printer (printJson)
import Data.Bifunctor (rmap)
import Data.Either (Either(Right, Left))
import Data.Foldable (sequence_, intercalate)
import Data.Generic (class Generic)
import Data.Lens (prism, (.~), _Just)
import Data.Lens.At (at)
import Data.Lens.Lens (lens)
import Data.Lens.Types (PrismP, LensP)
import Data.Maybe (Maybe(Nothing, Just))
import Data.StrMap (StrMap)
import Servant.Subscriber.Request (HttpRequest(HttpRequest), Request(Subscribe))
import Servant.Subscriber.Response (Response)
import Servant.Subscriber.Types (Path(Path))
import Unsafe.Coerce (unsafeCoerce)
import WebSocket (WEBSOCKET, Connection(..), newWebSocket, Message(..))


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
    | WebSocketError Event
    | WebSocketClosed Event

derive instance genericNotifyEvent :: Generic NotifyEvent

type Subscriptions = StrMap Subscription

type Subscription = {
    req :: HttpRequest
  , state :: SubscriptionState
  }

req :: forall r a. LensP ({ req :: a | r}) a
req = lens _.req (\r -> r { req = _ })

state :: forall r a. LensP ({ state :: a | r}) a
state = lens _.state (\r -> r { state = _ })


data SubscriptionState = Requested | Sent | Subscribed | Unsubscribed

derive instance eqSubscriptionState :: Eq SubscriptionState

coerceEffects :: forall eff0 eff1 a. Eff eff0 a -> Eff eff1 a
coerceEffects = unsafeCoerce

mkSubscriber :: forall eff. String -> (NotifyEvent -> SubscriberEff eff Unit) -> SubscriberEff eff Subscriber
mkSubscriber url h = do
      connRef <- newRef Nothing
      subscriptions <- Ref.newRef StrMap.empty
      return $ Subscriber {
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
        Nothing -> return unit
        Just (Connection conn) -> conn.close (Just 1000) Nothing

subscribe :: forall eff. HttpRequest -> Subscriber -> SubscriberEff eff Unit
subscribe request (Subscriber impl) = do
      modifyRef impl.subscriptions $ at (reqToKey request) .~ Just { state : Requested, req : request }
      tryRealize impl

unsubscribe :: forall eff. Path -> Subscriber -> SubscriberEff eff Unit
unsubscribe p (Subscriber impl) = do
      mc <- readRef impl.connection
      case mc of
        Nothing -> modifyRef impl.subscriptions $ at (pathToKey p) .~ (Nothing :: Subscription)
        Just c -> do
          modifyRef impl.subscriptions $ at (pathToKey p) <<< _Just <<< state .~ Unsubscribed
          realize c impl


tryRealize :: forall eff. SubscriberImpl -> SubscriberEff eff Unit
tryRealize impl = do
      mc <- readRef impl.connection
      case mc of
          Nothing -> return unit
          Just c -> realize c impl

-- | Takes care of actually subscribing stuff.
realize :: forall eff. Connection -> SubscriberImpl -> SubscriberEff eff Unit
realize (Connection conn) impl = do
      requested <- List.filter ((_ == Requested) <<< _.state) <<< StrMap.values <$> Ref.readRef impl.subscriptions
      let mkMsg = Message <<< printJson <<< gAesonEncodeJson <<< Subscribe
      let msgs = map (mkMsg <<< _.req) requested
      sequence_ $ map (coerceEffects <<< conn.send) msgs
    --  modifyRef impl.subscriptions $ over (mapped <<< state <<< match Requested) (const Sent) -- Does not work currently.
      modifyRef impl.subscriptions $ map (\sub -> if sub.state == Requested then sub { state = Sent } else sub)

initConnection :: forall eff. SubscriberImpl -> SubscriberEff eff Unit
initConnection impl = do
      mConn <- readRef impl.connection
      case mConn of
        Nothing -> makeConnection impl
        Just _ -> return unit


makeConnection :: forall eff. SubscriberImpl -> SubscriberEff eff Unit
makeConnection impl = do
      conn <- newWebSocket impl.url []
      Var.set conn.onclose   $ closeHandler impl
      Var.set conn.onmessage $ messageHandler impl
      Var.set conn.onerror   $ errorHandler impl
      Var.set conn.onopen    $ openHandler conn impl

openHandler :: forall eff. Connection -> SubscriberImpl -> Event -> SubscriberEff eff Unit
openHandler conn impl _ = do
      writeRef impl.connection $ Just conn
      realize impl

closeHandler :: forall eff. SubscriberImpl -> CloseEvent -> SubscriberEff eff Unit
closeHandler impl ev = do
      writeRef impl.connection Nothing
      subs <- readRef impl.subscriptions
      if StrMap.isEmpty subs
        then return unit
        else do
          modifyRef impl.subscriptions $ map ( _ { state = Requested })
          makeConnection impl
      impl.notify $ WebSocketClose ev

errorHandler :: forall eff. SubscriberImpl -> Event -> SubscriberEff eff Unit
errorHandler impl ev = do
      impl.notify $ WebSocketError ev
      tryRealize impl -- Something went wrong - retry. (TODO: Probably better with some timeout!)


messageHandler :: forall eff. SubscriberImpl -> MessageEvent -> SubscriberEff eff Unit
messageHandler impl msgEvent =  do
      let msg = WS.runMessage <<< WS.runMessageEvent $ msgEvent
      let eDecoded = gAesonDecodeJson <=< jsonParser $ msg
      case eDecoded of
        Left err -> impl.notify $ ParseError err
        Right resp -> do
            modifyRef impl.subscriptions $ case resp of
                Resp.Subscribed path   -> at (pathToKey path) <<< _Just <<< state .~ Subscribed
                Resp.Deleted path      -> at (pathToKey path) .~ (Nothing :: Maybe Subscription)
                Resp.Unsubscribed path -> at (pathToKey path) .~ (Nothing :: Maybe Subscription)
                Resp.Modified _ _      -> id
                Resp.ParseError        -> id
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
try action = catchException (return <<< Left) (map Right action)
