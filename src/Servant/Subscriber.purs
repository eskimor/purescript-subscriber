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
import DOM.Event.Types (MessageEvent)
import Data.Argonaut.Aeson (gAesonEncodeJson, gAesonDecodeJson)
import Data.Argonaut.Parser (jsonParser)
import Data.Argonaut.Printer (printJson)
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


newtype SubscriberImpl = SubscriberImpl {
    subscriptions :: Ref Subscriptions
  , url :: WS.URL
  , notify :: forall eff. NotifyEvent -> SubscriberEff eff Unit
  , connection :: Ref (Maybe Connection)
  }

data NotifyEvent = NotifyEvent Response
    | ParseError String -- We could not parse the server's response

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


data SubscriptionState = Requested | Sent | Subscribed

derive instance eqSubscriptionState :: Eq SubscriptionState

coerceEffects :: forall eff0 eff1 a. Eff eff0 a -> Eff eff1 a
coerceEffects = unsafeCoerce

mkSubscriber :: forall eff. String -> (NotifyEvent -> SubscriberEff eff Unit) -> SubscriberEff eff SubscriberImpl
mkSubscriber url h = do
  connRef <- newRef Nothing
  subscriptions <- Ref.newRef StrMap.empty
  return $ SubscriberImpl {
                subscriptions : subscriptions
              , url : WS.URL url
              , notify : coerceEffects <<< h
              , connection : connRef
              }

subscribe :: forall eff. HttpRequest -> SubscriberImpl -> SubscriberEff eff Unit
subscribe request impl'@(SubscriberImpl impl) = do
  modifyRef impl.subscriptions $ at (reqToKey request) .~ Just { state : Requested, req : request }
  realize impl'

-- | Takes care of actually subscribing stuff.
realize :: forall eff. SubscriberImpl -> SubscriberEff eff Unit
realize impl'@(SubscriberImpl impl) = do
      requested <- List.filter ((_ == Requested) <<< _.state) <<< StrMap.values <$> Ref.readRef impl.subscriptions
      let mkMsg = Message <<< printJson <<< gAesonEncodeJson <<< Subscribe
      let msgs = map (mkMsg <<< _.req) requested
      Connection conn <- getConnection impl'
      sequence_ $ map (coerceEffects <<< conn.send) msgs
--      modifyRef impl.subscriptions $ over (mapped <<< state <<< match Requested) (const Sent)

getConnection :: forall eff. SubscriberImpl -> SubscriberEff eff Connection
getConnection impl'@(SubscriberImpl impl) = do
    mConn <- readRef impl.connection
    case mConn of
      Nothing -> makeConnection impl'
      Just conn -> return conn


makeConnection :: forall eff. SubscriberImpl -> SubscriberEff eff Connection
makeConnection (SubscriberImpl impl) = do
    conn <- newWebSocket impl.url []
    -- TODO: Configure connection with handlers & stuff & handle exceptions
    writeRef impl.connection $ Just conn
    return conn
{--
initConnection :: forall eff. SubscriberImpl -> Connection -> (NotifyEvent -> SubscriberEff eff Unit) -> SubscriberEff eff Unit
initConnection impl'@(SubscriberImpl impl) conn'@(Connection conn) h = do
      Var.set conn.onclose closeHandler
  where
    openConnection :: SubscriberEff eff Unit
    openConnection = do
      conn <- newWebSocket impl.url []
      connRef <- newRef conn
      initConnection impl' conn' h
      writeRef impl.connection connRef

    closeHandler :: CloseEvent -> SubscriberEff Unit
    closeHandler _ = do
      modifyRef impl.subscriptions $ over (traversed.state) (_ .~ Requested)
      writeRef impl.connection Nothing
--}
ourHandler :: forall eff. SubscriberImpl -> (NotifyEvent -> SubscriberEff eff Unit) -> MessageEvent -> SubscriberEff eff Unit
ourHandler (SubscriberImpl impl) h msgEvent =  do
    let msg = WS.runMessage <<< WS.runMessageEvent $ msgEvent
    let eDecoded = gAesonDecodeJson <=< jsonParser $ msg
    case eDecoded of
      Left err -> h $ ParseError err
      Right resp -> do
          case resp of
            Resp.Subscribed path   -> modifyRef impl.subscriptions $ at (pathToKey path) <<< _Just <<< state .~ Subscribed
            Resp.Deleted path      -> modifyRef impl.subscriptions $ at (pathToKey path) .~ (Nothing :: Maybe Subscription)
            Resp.Unsubscribed path -> modifyRef impl.subscriptions $ at (pathToKey path) .~ (Nothing :: Maybe Subscription)
            Resp.Modified _ _      -> return unit
            Resp.ParseError        -> return unit
            Resp.RequestError _    -> return unit
          h $ NotifyEvent resp

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
