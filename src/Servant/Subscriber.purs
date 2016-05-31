module Servant.Subscriber where

import Prelude
import Servant.Subscriber.Request
import Servant.Subscriber.Response
import Servant.Subscriber.Types
import Control.Monad.Eff
import Control.Monad.Eff.Ref as Ref
import Data.StrMap as StrMap
import WebSocket as WS
import Control.Monad.Eff.Exception (EXCEPTION)
import Control.Monad.Eff.Ref (Ref, REF)
import Data.Argonaut.Aeson (gAesonEncodeJson, gAesonDecodeJson)
import Data.Argonaut.Printer (printJson)
import Data.Generic (class Generic)
import Data.StrMap (StrMap)
import WebSocket (newWebSocket, Connection, WEBSOCKET)

type SubscriberEff eff = Eff (ref :: REF, websocket :: WEBSOCKET | eff)


newtype SubscriberImpl = SubscriberImpl {
    subscriptions :: Ref (StrMap HttpRequest)
  , url :: WS.URL
  , connection :: Ref Connection
  }

data NotifyEvent = ResourceModified Path HttpResponse
    | ResourceDeleted
    | ServerParseError -- Server could not parse our request.
    | ParseError String -- We could not parse the server's response
    | ServerError HttpRequest HttpResponse -- ReceivedMessage can also be an error, but this message means that the subscription failed.
    | JSError Error

derive instance genericNotifyEvent :: Generic NotifyEvent

type Subscription = HttpRequest

data Event = Event Path HttpResponse

mkSubscriber :: forall eff. String -> (NotifyEvent -> Eff eff Unit) -> SubscriberEff eff SubscriberImpl
mkSubscriber url handler = do
  conn <- newWebSocket (WS.URL url) []

  connRef <- newRef conn
  subscriptions <- Ref.newRef StrMap.empty
  return $ SubscriberImpl {
              subscriptions : subscriptions
            , url : WS.URL url
            , connection : conn
            }

subscribe :: forall eff. HttpRequest -> Subscriber -> SubscriberEff eff Unit
subscribe req subs = do
  let msg = Message <<< printJson <<< gAesonEncodeJson $ Subscribe req
  connection.send msg
  modifyRef subs.subscriptions $ StrMap.insert req


newtype DeclarativeSubscriber = DeclarativeSubscriber {
    subscriptions :: StrMap HttpRequest
  , handlers :: forall eff. StrMap (NotifyEvent -> Eff eff Unit)
  }

ourHandler :: forall eff eff1. SubscriberImpl -> (NotifyEvent -> Eff eff1 Unit) -> MessageEvent -> SubscriberEff eff Unit
ourHandler (SubscriberImpl impl) h (Message msg) =  do
    eDecoded = gAesonDecodeJson <=< jsonParser $ msg
    case eDecoded of
      Left err -> return $ ParseError err
      Right resp -> do

      h $ translateResponse resp
  where
    getResponse (Modified path resp) = Just $ ResourceModified path resp) id
    getResponse (Deleted path)       = Just $ ResourceDeleted path
    getResponse (Unsubscribed path)  = Nothing
    getResponse ParseError           = Just ServerParseError
    getResponse (RequestError req err) = ServerError req err

    getTransform (Modified _ _)      = id
    getTransform (Deleted path)      = StrMap.delete path
    getTransform (Unsubscribed _)    = id
    getTransform ParseError          = id
    getTransform (RequestError (HttpRequestFailed req _))  = StrMap.delete $ reqToPath req

reqToPath :: HttpRequest -> Path
reqToPath (HttpRequest req) = req.httpPath
