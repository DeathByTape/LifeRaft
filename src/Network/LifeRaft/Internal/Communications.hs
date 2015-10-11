---------------------------------------------------------
-- Module      : Network.LifeRaft.Internal.Communications
-- Copyright   : (c) 2015 Yahoo, Inc.
-- License     : BSD3
-- Maintainer  : Dennis J. McWherter, Jr. (dennis@deathbytape.com)
-- Stability   : Experimental
-- Portability : non-portable
--
-- Helper methods for easier higher-level communication
-- related to LifeRaft.
---------------------------------------------------------

module Network.LifeRaft.Internal.Communications (
    sendMsg
  , getMsg
  ) where

import Data.Serialize
import Network.LifeRaft.Internal.NetworkHelper
import Network.LifeRaft.Internal.Types
import Network.Socket (Socket(..))
import System.Timeout

-- | Send a LifeRaft message over a socket
sendMsg :: (Serialize a) => LifeRaft a b s m r -> Socket -> LifeRaftMsg a -> IO ()
sendMsg _ sock msg = sendWithLen sock $! encode msg

-- | Receive a LifeRaft message over a socket
getMsg :: (Serialize a) => LifeRaft a b s m r -> Socket -> IO (Maybe (LifeRaftMsg a))
getMsg _ sock = do
  -- TODO: Support for monad-logger.
  --putStrLn "Receiving message..."
  -- 5s timeout
  -- TODO: Timeout should be configurable
  final <- timeout 5000000 $ do
    msg <- recvWithLen sock
    case decode msg of
     Left e -> putStrLn ("Could not decode message: " ++ show e) >> return Nothing
     Right result -> putStrLn "Message received." >> return (Just result)
  maybe (putStrLn "Receive timed out." >> return Nothing) return final
