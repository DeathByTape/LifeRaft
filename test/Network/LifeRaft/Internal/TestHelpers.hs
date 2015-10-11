{-# LANGUAGE OverloadedStrings #-}
-----------------------------------------------------------
---- Module      : Network.LifeRaft.Internal.TestHelpers
---- Copyright   : (c) 2015 Yahoo, Inc.
---- License     : BSD3
---- Maintainer  : Dennis J. McWherter, Jr. (dennis@deathbytape.com)
---- Stability   : Experimental
---- Portability : non-portable
----
---- Common helper methods for tests
----
-----------------------------------------------------------

module Network.LifeRaft.Internal.TestHelpers (
    withConnectedSockets
  ) where

import Control.Concurrent.Async
import Network.Socket
import Network.Socket.ByteString
import System.Timeout

import Network.LifeRaft.Internal.NetworkHelper

-- | Run a computation with connected sockets
--
withConnectedSockets :: ((Socket, Socket) -> IO ()) -> IO (Maybe ())
withConnectedSockets f = withSocketsDo $ timeout 5000000 $ do
  p <- getConnectedSockets
  f p
  closeSockets p

-- | Get a pair of sockets in connected state (to each other)
--
getConnectedSockets :: IO (Socket, Socket)
getConnectedSockets = do
  listener <- socket AF_INET Stream defaultProtocol
  rightSock <- socket AF_INET Stream defaultProtocol
  hAddr <- getSockAddr "localhost:1" >>= \saddr -> case saddr of
    Nothing -> fail "Could not get SockAddr for localhost."
    Just (SockAddrInet _ host) -> return host
    _ -> fail "Returned unexpected SockAddr type."
  bind listener $ SockAddrInet aNY_PORT hAddr
  listen listener 5
  port <- socketPort listener
  -- Start server asynchronously
  serverFuture <- async $ do
    (sock, _) <- accept listener
    return sock
  -- Make the connection
  connect rightSock $ SockAddrInet port hAddr
  leftSock <- wait serverFuture
  sClose listener
  return (leftSock, rightSock)

-- | Close a pair of sockets
--
closeSockets :: (Socket, Socket) -> IO ()
closeSockets (l, r) = sClose l >> sClose r
