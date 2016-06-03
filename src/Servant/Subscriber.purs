module Servant.Subscriber where

import Prelude
import Servant.Subscriber.Request
import Servant.Subscriber.Response
import Servant.Subscriber.Types
import Control.Bind
import Control.Monad
import Control.Monad.Eff
import Data.Argonaut.Parser
import Data.Bifunctor
import Data.Either
import Data.Foldable
import Data.Maybe
import Data.Lens.Types
import Data.Lens.Lens
import Data.Lens
import Data.Lens.At
import Control.Monad.Eff.Ref as Ref
import Control.Monad.Eff.Var as Var
import Data.List as List
import Data.StrMap as StrMap
import Servant.Subscriber.Response as Resp
import WebSocket as WS
import Control.Monad.Eff.Exception (EXCEPTION, Error)
import Control.Monad.Eff.Ref (writeRef, Ref, REF, newRef, modifyRef, modifyRef')
import Control.Monad.Maybe.Trans (runMaybeT)
import DOM.Event.Types (domTransactionEventToEvent, offlineAudioCompletionEventToEvent)
import DOM.Event.Types (Event, MessageEvent, CloseEvent)
import Data.Argonaut.Aeson (gAesonEncodeJson, gAesonDecodeJson)
import Data.Argonaut.Printer (printJson)
import Data.Generic (class Generic)
import Data.StrMap (StrMap)
import WebSocket (WEBSOCKET, Connection(..), newWebSocket, Message(..))


type SubscriberEff eff = Eff (ref :: REF, ws :: WEBSOCKET | eff)


newtype SubscriberImpl = SubscriberImpl {
    subscriptions :: Ref Subscriptions
  , url :: WS.URL
  , notify :: forall eff. NotifyEvent -> SubscriberEff eff Unit
  , connection :: Ref (Maybe Connection)
  }

data NotifyEvent = NotifyEvent Response
    | ParseError String -- We could not parse the server's response
    | JSException Error -- Some JavaScript exception occurred

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

mkSubscriber :: forall eff. String -> (NotifyEvent -> SubscriberEff eff Unit) -> SubscriberEff eff SubscriberImpl
mkSubscriber url h = do
  connRef <- newRef Nothing
  subscriptions <- Ref.newRef StrMap.empty
  return $ SubscriberImpl {
                subscriptions : subscriptions
              , url : WS.URL url
              , notify : h
              , connection : connRef
              }

subscribe :: forall eff. HttpRequest -> SubscriberImpl -> SubscriberEff eff Unit
subscribe request impl'@(SubscriberImpl impl) = do
  modifyRef impl.subscriptions $ at (reqToKey req) .~ Just { state : Requested, req : request }
  realize impl'

-- | Takes care of actually subscribing stuff.
realize :: forall eff. SubscriberImpl -> SubscriberEff eff Unit
realize (SubscriberImpl impl) = do
      subscriptions <- Ref.readRef impl.subscriptions
      let requested = List.filter (_.state == Requested) <<< StrMap.values $ subscriptions
      let mkMsg = Message <<< printJson <<< gAesonEncodeJson <<< Subscribe
      let msgs = map (mkMsg <<< _.req) requested
      traversed impl.connection.send msgs
      modifyRef impl.subscriptions $ over (traversed.state) (match Requested .~ Sent)

initConnection :: forall eff eff1. SubscriberImpl -> Connection -> (NotifyEvent -> Eff eff Unit) -> SubscriberEff eff1 Unit
initConnection impl'@(SubscriberImpl impl) conn'@(Connection conn) h = do
      Var.set conn.onclose closeHandler
  where
    openConnection :: forall eff. SubscriberEff eff Unit
    openConnection = do
      conn <- newWebSocket impl.url []
      connRef <- newRef conn
      initConnection impl' conn' h
      writeRef impl.connection connRef

    closeHandler :: forall eff. CloseEvent -> SubscriberEff Unit
    closeHandler _ = do
      modifyRef impl.subscriptions $ over (traversed.state) (_ .~ Requested)
      writeRef impl.connection Nothing

    openHandler :: forall eff. Event -> SubscriberEff Unit
    openHandler _ = realize impl'

ourHandler :: forall eff. SubscriberImpl -> (NotifyEvent -> SubscriberEff eff Unit) -> MessageEvent -> SubscriberEff eff Unit
ourHandler (SubscriberImpl impl) h msgEvent =  do
    let msg = WS.runMessage <<< WS.runMessageEvent $ msgEvent
    let eDecoded = gAesonDecodeJson <=< jsonParser $ msg
    case eDecoded of
      Left err -> h $ ParseError err
      Right resp -> do
          case resp of
            Resp.Subscribed path   -> modifyRef impl.subscriptions $ at (pathToKey path) <<< _Just <<< state .~ Subscribed
      --      Resp.Deleted path      -> modifyRef impl.subscriptions $ at (pathToKey path) .~ Nothing
      --      Resp.Unsubscribed path -> modifyRef impl.subscriptions $ at (pathToKey path) .~ Nothing
            Resp.Modified _ _      -> return unit
            Resp.ParseError        -> return unit
            Resp.RequestError _    -> return unit
          h $ NotifyEvent resp

reqToPath :: HttpRequest -> Path
reqToPath (HttpRequest req) = req.httpPath

reqToKey :: HttpRequest -> String
reqToKey = pathToKey <<< reqToPath

pathToKey :: Path -> String
pathToKey (Path p) = intercalate "/" p

-- | Prism for only setting a value if it is equal to a.
match :: forall a. Eq a => a -> PrismP a a
match a = prism id $ \b -> if a == b then Right a else Left b
