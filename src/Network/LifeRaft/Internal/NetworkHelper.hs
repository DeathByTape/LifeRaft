---------------------------------------------------------
-- Module      : Network.LifeRaft.Internal.NetworkHelper
-- Copyright   : (c) 2015 Yahoo, Inc.
-- License     : BSD3
-- Maintainer  : Dennis J. McWherter, Jr. (dennis@deathbytape.com)
-- Stability   : Experimental
-- Portability : non-portable
--
-- Internal helper utility functions for easier
-- manipulation of Network data.
---------------------------------------------------------

module Network.LifeRaft.Internal.NetworkHelper (
    recvWithLen
  , recvInt32
  , recvAll
  , sendWithLen
  , getSockAddr
) where

import Prelude hiding (length)
import Data.ByteString.Char8
import Data.Int (Int32)
import qualified Data.List as DL
import Data.List.Split
import Data.Serialize
import Network.BSD
import Network.Socket hiding (send, sendTo, recv, recvFrom)
import Network.Socket.ByteString

--
-- The following methods are network helpers
-- some of them are being reproduced from places like Network.Transport.TCP
--
-- The goal is to move to Network.Transport if the team is willing to maintain a
-- standard protocol for connections such that foreign clients can connect properly.
-- That is, it currently seems as though only 
--
-- TODO: Need to get in touch with the CloudHaskell team about this.
--

-- TODO: Should account for endianess. That is, everything should be sent/received in network byte order
--       (i.e. big endian) and converted appropriately.

-- | Receive a value preceeded by its length
--
-- This function first receives a 32-bit integer (i.e. 4 bytes) which is assumed to be the size
-- of the following byte array. It then proceeds in consuming that many bytes and returns the
-- result as a ByteString.
--
recvWithLen :: Socket -> IO ByteString
recvWithLen sock = recvInt32 sock >>= recvAll sock

-- | Receive a 32-bit integer
--
-- Receives a 32-bit integer from a socket
--
recvInt32 :: Socket -> IO Int
recvInt32 sock = recvAll sock 4 >>= \x -> either (\v -> fail $ "Failed: " ++ v) (return . fromIntegral) ((decode x) :: Either String Int32)

-- | Receive n bytes from a socket
--
-- Reads from a socket until "total" number of bytes is received.
-- Upon this point it returns a ByteString containing the received data.
--
recvAll :: Socket -> Int -> IO ByteString
recvAll sock total = if total > 0 then recvAll' emptyBS else emptyBS
  where emptyBS = return empty
        recvAll' bs = do
          rcvd <- bs
          let len = length rcvd
          if len == total then bs else recv sock (total - len) >>= recvAll' . return . (append rcvd)

-- | Send a full ByteString over a socket
--
-- Send a ByteString over a socket preceeded by its length as a 32-bit integer.
--
sendWithLen :: Socket -> ByteString -> IO ()
sendWithLen sock msg = (sendAll sock $! len) >> sendAll sock msg
  where len = encode $ ((fromIntegral $ length msg) :: Int32)

-- | Get a hostname based on a formatted string
--
-- Converts a formatted id string of "hostname:port" into a valid SockAddr
--
-- NOTE: Currently assumes IPv4.
-- TODO: Update this to properly handle IPv6
--
getSockAddr :: String -> IO (Maybe SockAddr)
getSockAddr serverId = do
  let val = splitOn ":" serverId
  if DL.length val /= 2 then
    return Nothing
  else do
    hAddr <- getHostByName $ val !! 0
    return $ Just $ SockAddrInet (fromInteger ((read $ val !! 1) :: Integer)) (hostAddress hAddr)

