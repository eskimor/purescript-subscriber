module Main where

import Prelude
import Data.StrMap as StrMap
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Console (log, CONSOLE)
import Data.Lens (_Just)
import Data.Lens.At (at)
import Data.Maybe (Maybe(Just, Nothing))
import Data.Tuple (Tuple(Tuple))
import Optic.Internal.Setter (class Settable)
import Optic.Setter (mapped, over)

mover = over mapped

main :: forall e. Eff (console :: CONSOLE | e) Unit
main = do
  let myMap = StrMap.fromFoldable [Tuple "huhu" (Nothing :: Maybe Int), Tuple "haha" (Just 9)]
  -- let secondMap = at "huhu" .~ (Nothing :: Maybe Int) $ myMap
  --  modifyRef impl.subscriptions $ over (mapped <<< state <<< match Requested) (const Sent)
  let thirdMap = over (mapped) (const $ Just 2) myMap
  log "Hello sailor!"
