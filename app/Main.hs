---------------------------------------------------------
-- Module      : Network.LifeRaft.Raft
-- Copyright   : (c) 2015 Yahoo, Inc.
-- License     : BSD3
-- Maintainer  : Dennis J. McWherter, Jr. (dennis@deathbytape.com)
-- Stability   : Experimental
-- Portability : non-portable
--
-- An example key-value store using LifeRaft.
--
---------------------------------------------------------

module Main where

import Control.Monad.Trans.State.Lazy
import qualified Data.HashMap.Lazy as HM
import Data.List
import Network.LifeRaft
import Network.Socket
import System.Environment

servers :: [String]
servers = ["127.0.0.1:1337", "127.0.0.1:31337", "127.0.0.1:1024"]

main :: IO ()
main = withSocketsDo $ do
    putStrLn "Starting LifeRaft key-value store example..."
    serverId <- getServer
    liferaft <- createLifeRaft (getNode serverId (remainingServers serverId)) lookupKey
    putStrLn "Started."
    runLifeRaft (clientAddress serverId) liferaft
  where getNode server servers = initNode servers server ("", HM.empty) storeKeyValue (20, 40)
        getServer = do
          args <- getArgs
          let this = args !! 0
          if length args <= 0 || this `notElem` servers then
            fail $ "Please provide a server from list: " ++ show servers
          else
            return this
        remainingServers server = servers \\ [server]

clientAddress :: String -> String
clientAddress server
  | server == "127.0.0.1:1337" = "127.0.0.1:10000"
  | server == "127.0.0.1:31337" = "127.0.0.1:10001"
  | server == "127.0.0.1:1024" = "127.0.0.1:10002"
  | otherwise = ""

storeKeyValue :: Monad m => (String, String) -> StateT (HM.HashMap String String) (NodeStateT a s m r) String
storeKeyValue (key, value) = get >>= return . (HM.insert key value) >>= put >> return value

lookupKey :: Monad m => String -> StateT (HM.HashMap String String) (NodeStateT a s m r) String
lookupKey key = get >>= return . (HM.lookupDefault "" key)


