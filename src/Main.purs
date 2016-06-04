module Main where

import Prelude
import Prelude
import Control.Monad.Eff.Ref as Ref
import Control.Monad.Eff.Var as Var
import Data.List as List
import Data.StrMap as StrMap
import Servant.Subscriber.Response as Resp
import WebSocket as WS
import Control.Bind ((<=<))
import Control.Monad.Eff (Eff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Console (CONSOLE, log)
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
import Data.Tuple (Tuple(Tuple))
import Servant.Subscriber.Request (HttpRequest(HttpRequest), Request(Subscribe))
import Servant.Subscriber.Response (Response)
import Servant.Subscriber.Types (Path(Path))
import Unsafe.Coerce (unsafeCoerce)
import WebSocket (WEBSOCKET, Connection(..), newWebSocket, Message(..))


main :: forall e. Eff (console :: CONSOLE | e) Unit
main = do
  let myMap = StrMap.fromFoldable [Tuple "huhu" 1, Tuple "haha" 2]
  let secondMap = at "huhu" .~ (Nothing :: Maybe Int) $ myMap
  log "Hello sailor!"
