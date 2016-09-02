module Servant.Subscriber.Internal where

import Prelude
import Control.Monad.Eff.Ref as Ref
import Control.Monad.Eff.Var as Var
import Control.Monad.ST as ST
import DOM.HTML.Event.ErrorEvent as ErrorEvent
import DOM.Websocket.Event.CloseEvent as CloseEvent
import Data.List as List
import Data.StrMap as StrMap
import Data.StrMap.ST as SM
import Servant.Subscriber.Response as Resp
import WebSocket as WS
import Control.Bind ((<=<))
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Exception (Error, EXCEPTION, catchException)
import Control.Monad.Eff.Ref (Ref, REF, modifyRef, readRef, writeRef)
import DOM.Event.Types (keyboardEventToEvent, Event)
import DOM.Websocket.Event.Types (CloseEvent, MessageEvent)
import Data.Argonaut.Core (Json)
import Data.Argonaut.Generic.Aeson (encodeJson, decodeJson)
import Data.Argonaut.Parser (jsonParser)
import Data.Argonaut.Printer (printJson)
import Data.Bifunctor (lmap)
import Data.Either (Either(Right, Left))
import Data.Foldable (traverse_, sequence_, elem, intercalate, foldl)
import Data.Function.Uncurried (Fn4)
import Data.Generic (gShow, gEq, gCompare, class Generic)
import Data.Lens ((^.), view, prism, (.~), _Just, _2)
import Data.Lens.At (at)
import Data.Lens.Lens (lens)
import Data.Lens.Types (PrismP, LensP)
import Data.List (List, filter)
import Data.Maybe (Maybe(Nothing, Just))
import Data.StrMap (thawST, pureST, StrMap)
import Data.StrMap.ST (STStrMap)
import Data.Tuple (Tuple(Tuple), fst)
import Partial.Unsafe (unsafeCrashWith)
import Servant.PureScript.Util (reportError)
import Servant.Subscriber.Request (HttpRequest(HttpRequest), Request(Subscribe, Unsubscribe, SetPongRequest, SetCloseRequest))
import Servant.Subscriber.Response (HttpResponse)
import Servant.Subscriber.Types (Path(Path))
import Unsafe.Coerce (unsafeCoerce)
import WebSocket (WEBSOCKET, Message(Message), ReadyState(Open), newWebSocket)
import Data.StrMap.ST.Unsafe as ST

type SubscriberEff eff = Eff (ref :: REF, ws :: WEBSOCKET, err :: EXCEPTION | eff)

type Orders a = StrMap (Order a)

type Connection eff a = {
    orders       :: Ref (Orders a)
  , url          :: WS.URL
  , callback     ::  a -> SubscriberEff eff Unit
  , notify       ::  Notification -> SubscriberEff eff Unit
  , connection   :: Ref (Maybe WS.Connection)
  , pongRequest  :: Ref (Maybe HttpRequest)
  , closeRequest :: Ref (Maybe HttpRequest)
  }


type OrderKey = String

makeOrderKey :: HttpRequest -> OrderKey
makeOrderKey = gShow

-- | Information about a subscription:
--   What to subscribe and whom to respond to.
type Subscription a = {
    req :: HttpRequest
  , parseResponses :: List (ToUserType a)
  }


data Notification = WebSocketError String
           | WebSocketClosed String
           | HttpRequestFailed HttpRequest HttpResponse
           | ParseError String -- |< Server response could not be parsed/ Server could not parse our request.

derive instance genericNotification :: Generic Notification

-- | Convert a json modified response to a user specified sum type.
--   The given parameter is 'Nothing' on a Deleted event.
type ToUserType a = Maybe Json -> Either String a

data SubscriptionState = Ordered | Sent | Confirmed

derive instance eqSubscriptionState :: Eq SubscriptionState

type Order a = {
    req :: Request
  , parseResponses :: List (ToUserType a)
  , state :: SubscriptionState
  }

req :: forall r a. LensP ({ req :: a | r}) a
req = lens _.req (\r -> r { req = _ })

state :: forall r a. LensP ({ state :: a | r}) a
state = lens _.state (\r -> r { state = _ })



coerceEffects :: forall eff0 eff1 a. Eff eff0 a -> Eff eff1 a
coerceEffects = unsafeCoerce

-- | Call this function to actually send requests to the server.
realize :: forall eff a. Connection eff a -> SubscriberEff eff Unit
realize impl = do
      mc <- readRef impl.connection
      case mc of
          Nothing -> makeConnection impl
          Just c ->  sendRequests c impl

-- | Takes care of actually subscribing stuff.
sendRequests :: forall eff a. WS.Connection -> Connection eff a -> SubscriberEff eff Unit
sendRequests (WS.Connection conn) impl = do
      ordered <- List.filter ((_ == Ordered) <<< _.state) <<< StrMap.values <$> Ref.readRef impl.orders
      let
        mkMsg :: Request -> Message
        mkMsg = Message <<< printJson <<< encodeJson

        msgs = map (mkMsg <<< _.req) ordered

      sequence_ $ map conn.send msgs
    --  modifyRef impl.subscriptions $ over (mapped <<< state <<< match Requested) (const Sent) -- Does not work currently.
    --  modifyRef impl.subscriptions $ traverse <<< state <<< filtered (_ == Ordered) .~ Sent -- Does not work currently
      modifyRef impl.orders $ map (\sub -> if sub.state == Ordered then sub { state = Sent } else sub)

initConnection :: forall eff a. Connection eff a -> SubscriberEff eff Unit
initConnection impl = do
      mConn <- readRef impl.connection
      case mConn of
        Nothing -> makeConnection impl
        Just _ -> pure unit


makeConnection :: forall eff a. Connection eff a -> SubscriberEff eff Unit
makeConnection impl = do
      WS.Connection conn <- newWebSocket impl.url []
      Var.set conn.onclose   $ closeHandler impl
      Var.set conn.onmessage $ messageHandler impl
      Var.set conn.onerror   $ errorHandler impl
      Var.set conn.onopen    $ openHandler (WS.Connection conn) impl


openHandler :: forall eff a. WS.Connection -> Connection eff a -> Event -> SubscriberEff eff Unit
openHandler conn impl _ = do
  writeRef impl.connection $ Just conn
  sendRequests conn impl

closeHandler :: forall eff a. Connection eff a -> CloseEvent -> SubscriberEff eff Unit
closeHandler impl ev = do
      writeRef impl.connection Nothing
      subs <- readRef impl.orders
      if StrMap.isEmpty subs
        then pure unit
        else do
          modifyRef impl.orders $ updateSubscriptions
          makeConnection impl
      impl.notify $ WebSocketClosed ("code: " <> (show <<< CloseEvent.code) ev <> ", reason: " <> CloseEvent.reason ev)
  where
    isUnsubscribe :: Request -> Boolean
    isUnsubscribe (Unsubscribe _) = true
    isUnsubscribe _ = false

    updateSubscriptions :: Orders a -> Orders a
    updateSubscriptions subs = let
          forRemoval = map fst <<< List.filter (isUnsubscribe <<< view (_2 <<< req)) <<< StrMap.toList $ subs
          cleanedSubs = foldl (flip StrMap.delete) subs forRemoval
        in
          map ( _ { state = Ordered } ) cleanedSubs

errorHandler :: forall eff a. Connection eff a -> Event -> SubscriberEff eff Unit
errorHandler impl ev = do
      impl.notify $ WebSocketError ((ErrorEvent.message <<< unsafeCoerce) ev)
      realize impl -- Something went wrong - retry. (TODO: Probably better with some timeout!)


messageHandler :: forall eff a. Connection eff a -> MessageEvent -> SubscriberEff eff Unit
messageHandler impl msgEvent =  do
      let msg = WS.runMessage <<< WS.runMessageEvent $ msgEvent
      let eDecoded = decodeJson <=< jsonParser $ msg
      case eDecoded of
        Left err -> impl.notify $ ParseError (err <> ", input: '" <> msg <> "'")
        Right resp -> do
            modifyRef impl.orders $ case resp of
                Resp.Subscribed req'          -> onlyIfSent req' $ \key -> at key <<< _Just <<< state .~ Confirmed
                Resp.Deleted path             -> handleDelete path
                Resp.Unsubscribed req'        -> onlyIfSent req' $ \key -> at key .~ (Nothing :: Maybe (Order a))
                Resp.Modified _ _             -> id
                Resp.HttpRequestFailed req' _ -> onlyIfSent req' $ \key -> at key .~ (Nothing :: Maybe (Order a))
                Resp.ParseError               -> id
            orders' <- readRef impl.orders
            case resp of
              Resp.Modified req' val            -> doCallback req' (Just val) impl
              Resp.Deleted  path                -> traverse_ (\order' -> doCallback (getHttpReq order'.req) Nothing impl)
                                                   $ getOrdersByPath path orders'
              Resp.HttpRequestFailed req' resp' -> impl.notify $ HttpRequestFailed req' resp'
              Resp.ParseError                   -> impl.notify $ ParseError "Server could not parse our request!"
              Resp.Subscribed _                 -> pure unit
              Resp.Unsubscribed _               -> pure unit

-- | Only update our orders from messageHandler if state is still `Sent` to avoid overriding of more recent user requests.
onlyIfSent :: forall a. HttpRequest -> (OrderKey -> Orders a -> Orders a) -> Orders a -> Orders a
onlyIfSent req' action orders' =
  let
    key = makeOrderKey req'
    order' = orders' ^. at key
  in
   case (_.state) <$> order' of
     Just Sent -> action key orders'
     _    -> orders'

handleDelete :: forall a. Path -> Orders a -> Orders a
handleDelete p = StrMap.fromList <<< filter canStay <<< StrMap.toList
  where
    canStay :: Tuple String (Order a) -> Boolean
    canStay (Tuple _ order) = let req' = runHttpRequest $ getHttpReq order.req
                              in
                               (not <<< eqPath) req'.httpPath p || order.state /= Confirmed -- Only delete if already successfully subscribed!


getOrdersByPath :: forall a. Path -> Orders a -> List (Order a)
getOrdersByPath path = filter (eqPath path <<< getPath <<< _.req) <<< StrMap.values

doCallback :: forall eff a. HttpRequest -> Maybe String -> Connection eff a -> SubscriberEff eff Unit
doCallback req' res impl = do
  orders' <- readRef impl.orders
  let
    order' = case StrMap.lookup (makeOrderKey req') orders' of
      Nothing -> unsafeCrashWith $ "Received a message for an unregistered handler: " <> gShow req'
      Just o -> o
    parsers = order'.parseResponses
    eitherVals :: List (Either String a)
    eitherVals = case res of
      Nothing ->  map (_ $ Nothing) parsers
      Just str -> flip doDecode str <$> parsers
    handleEitherVal :: Either String a -> SubscriberEff eff Unit
    handleEitherVal eitherVal =case eitherVal of
      Right decoded -> impl.callback decoded
      Left err -> impl.notify $ ParseError err
  traverse_ handleEitherVal eitherVals

doDecode :: forall a. ToUserType a -> String -> Either String a
doDecode parser str = do
      jVal <- lmap (reportError id str <<< ("Parsing json response failed: " <> _))
              <<< jsonParser $ str
      parser $ Just jVal

-- | Prism for only setting a value if it is equal to a.
match :: forall a. Eq a => a -> PrismP a a
match a = prism id $ \b -> if a == b then Right a else Left b


try :: forall a eff. Eff (err :: EXCEPTION | eff) a -> Eff eff (Either Error a)
try action = catchException (pure <<< Left) (map Right action)

eqPath :: Path -> Path -> Boolean
eqPath (Path p1) (Path p2) = eq p1 p2

getPath :: Request -> Path
getPath = _.httpPath <<< runHttpRequest <<< getHttpReq

getHttpReq :: Request -> HttpRequest
getHttpReq req' = case req' of
  Subscribe hreq   -> hreq
  Unsubscribe hreq -> hreq
  SetPongRequest hreq -> hreq
  SetCloseRequest hreq -> hreq

runHttpRequest (HttpRequest req') = req'

 -- Copied from Data.StrMap (not exported):
mutate :: forall a b. (forall h . SM.STStrMap h a -> Eff (st :: ST.ST h ) b) -> StrMap a -> StrMap a
mutate f m = ST.pureST (do
  s <- myThawST m
  f s
  ST.unsafeGet s)

foreign import _lookup :: forall a z. Fn4 z (a -> z) String (StrMap a) z

myThawST :: forall a h. StrMap a -> Eff ( st :: ST.ST h) (STStrMap h a)
myThawST = unsafeCoerce thawST
