{-# LANGUAGE OverloadedStrings #-}
-----------------------------------------------------------
---- Module      : Network.LifeRaft.Internal.NetworkHelper
---- Copyright   : (c) 2015 Yahoo, Inc.
---- License     : BSD3
---- Maintainer  : Dennis J. McWherter, Jr. (dennis@deathbytape.com)
---- Stability   : Experimental
---- Portability : non-portable
----
---- Test for NetworkHelper internal module.
----
-----------------------------------------------------------

module Network.LifeRaft.Internal.NetworkHelperSpec (spec) where

import Network.LifeRaft.Internal.NetworkHelper

import Control.Concurrent.Async
import qualified Data.ByteString.Char8 as B
import Data.Maybe
import Network.Socket hiding (send, sendTo, recv, recvFrom, recvAll)
import Network.Socket.ByteString
import System.Timeout

import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = do
    describe "retrieving a SockAddr" $ do
      context "for an ID string containing IP" $ do
        it "fails for a bad IP" $ do
          r <- getSockAddr "111.9999.9.9:1337"
          r `shouldBe` Nothing
        it "fails for an invalid port" $ do
          r <- getSockAddr "127.0.0.1:70000"
          r' <- getSockAddr "127.0.0.1:0"
          r `shouldBe` Nothing
          r' `shouldBe` Nothing
        it "succeeds for valid port and IP" $ do
          r <- getSockAddr "127.0.0.1:1337"
          (isJust r) `shouldBe` True
      context "for an ID string containing a hostname" $ do
        it "fails for a bad hostname" $ do
          r <- getSockAddr "ooogabooga.w00t:1225"
          r `shouldBe` Nothing
        it "fails for an invalid port" $ do
          r <- getSockAddr "yahoo.com:0"
          r' <- getSockAddr "google.com:70000"
          r `shouldBe` Nothing
          r' `shouldBe` Nothing
        it "succeeds for a valid host and port" $ do
          r <- getSockAddr "yahoo.com:443"
          r' <- getSockAddr "localhost:1024"
          (isJust r) `shouldBe` True
          (isJust r') `shouldBe` True
    describe "receiving an Int32" $ do
      it "transmits and receives the correct integer" $ do
        r <- withConnectedSockets $ \(l, r) -> do
          send l "abcd"
          res <- recvInt32 r
          res `shouldBe` 0x61626364
        (isJust r) `shouldBe` True
    describe "receiving with length" $ do
      it "receives the entire set of data" $ do
        r <- withConnectedSockets $ \(l, r) -> do
          -- Hmm... We really need to pay attention to endianess here.
          send l "\x00\x00\x00\x05"
          send l "hello"
          d <- recvWithLen r
          d `shouldBe` "hello"
        (isJust r) `shouldBe` True
    describe "receiving all bytes up to a length" $ do
      it "receives all specified bytes" $ do
        r <- withConnectedSockets $ \(l, r) -> do
          send l alphabet
          r <- recvAll r abLen
          r `shouldBe` alphabet
        (isJust r) `shouldBe` True
      it "should not receive more bytes than specified even if more are sent" $ do
        r <- withConnectedSockets $ \(l, r) -> do
          send l alphabet
          r <- recvAll r (abLen - 2)
          r `shouldBe` (B.take (abLen - 2) alphabet)
        (isJust r) `shouldBe` True
    describe "sending with length" $ do
      it "sends the entire set of data preceeded by its length" $ do
        r <- withConnectedSockets $ \(l, r) -> do
          let msg = "this is a test message!"
          sendWithLen l msg
          numBytes <- recvInt32 r
          numBytes `shouldBe` B.length msg
          r <- recvAll r numBytes
          r `shouldBe` msg
        (isJust r) `shouldBe` True
    describe "receiving with length" $ do
      it "receives a number of bytes preceeded by the data size" $ do
        r <- withConnectedSockets $ \(l, r) -> do
          let msg = "some sample"
          -- TODO: Again, another endianess thing..
          send l "\x00\x00\x00\x0b"
          send l msg
          r <- recvWithLen r
          r `shouldBe` msg
        (isJust r) `shouldBe` True
  where alphabet = B.pack ['a'..'z']
        abLen = B.length alphabet

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

