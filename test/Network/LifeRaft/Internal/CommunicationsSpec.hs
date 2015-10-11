{-# LANGUAGE OverloadedStrings #-}
-----------------------------------------------------------
---- Module      : Network.LifeRaft.Internal.CommunicationsSpec
---- Copyright   : (c) 2015 Yahoo, Inc.
---- License     : BSD3
---- Maintainer  : Dennis J. McWherter, Jr. (dennis@deathbytape.com)
---- Stability   : Experimental
---- Portability : non-portable
----
---- Test for Communications internal module.
----
-----------------------------------------------------------

module Network.LifeRaft.Internal.CommunicationsSpec (spec) where

import Network.LifeRaft
import Network.LifeRaft.Internal.Communications
import Network.LifeRaft.Internal.Types
import Network.LifeRaft.Internal.TestHelpers
import Network.LifeRaft.Raft.Internal.Types

import Control.Monad.Trans.State.Lazy
import qualified Data.ByteString.Char8 as B
import Data.Maybe
import Network.Socket hiding (send, sendTo, recv, recvFrom, recvAll)
import Network.Socket.ByteString

import Test.Hspec
import Test.QuickCheck

liferaft :: IO (LifeRaft Int Int Int IO Int)
liferaft = createLifeRaft node queryMachine
  where node = initNode [] "127.0.0.1:1337" (0 :: Int, 0 :: Int) stateMachine (10, 20)
        stateMachine _ = return 0 -- Does nothing
        queryMachine _ = return 0 -- Does nothing

spec :: Spec
spec = do
    describe "sending/serializing a LifeRaft message" $ do
      context "for an Action" $ do
        it "succeeds to receive a RequestVote" $ do
          r <- withLifeRaft $ \raft (l ,r) -> sendMsg raft l (Action (RequestVote (1, "abc", 1, 1)))
          isJust r `shouldBe` True
        it "succeeds to receive a AppendEntries" $ do
          r <- withLifeRaft $ \raft (l ,r) -> sendMsg raft l (Action (AppendEntries (1, "abc", 1, 1, [], 1)))
          isJust r `shouldBe` True
        it "succeeds to receive a AppendEntriesResult" $ do
          r <- withLifeRaft $ \raft (l ,r) -> sendMsg raft l (Action (AppendEntriesResult ("abc", 1, False)))
          isJust r `shouldBe` True
        it "succeeds to receive a DiscoverNode" $ do
          r <- withLifeRaft $ \raft (l ,r) -> sendMsg raft l (Action (DiscoverNode "abc"))
          isJust r `shouldBe` True
        it "succeeds to receive a ElectionTimeout" $ do
          r <- withLifeRaft $ \raft (l ,r) -> sendMsg raft l (Action ElectionTimeout)
          isJust r `shouldBe` True
        it "succeeds to receive a VoteReceived" $ do
          r <- withLifeRaft $ \raft (l ,r) -> sendMsg raft l (Action (VoteReceived "abc"))
          isJust r `shouldBe` True
        it "succeeds to receive a ClientRequest" $ do
          r <- withLifeRaft $ \raft (l ,r) -> sendMsg raft l (Action (ClientRequest 5))
          isJust r `shouldBe` True
      context "for a RequestFromClient" $
        it "succeeds in sending request" $ do
          r <- withLifeRaft $ \raft (l, r) -> sendMsg raft l (RequestFromClient 2)
          isJust r `shouldBe` True
      context "for a ServerConnReq" $
        it "succeeds in sending request" $ do
          r <- withLifeRaft $ \raft (l, r) -> sendMsg raft l (ServerConnReq $ SockAddrInet 2 1)
          isJust r `shouldBe` True
      context "for a ServerConnAccept" $
        it "succeeds in sending request" $ do
          r <- withLifeRaft $ \raft (l, r) -> sendMsg raft l ServerConnAccept
          isJust r `shouldBe` True
      context "for a ServerConnReject" $
        it "succeeds in sending request" $ do
          r <- withLifeRaft $ \raft (l, r) -> sendMsg raft l ServerConnReject
          isJust r `shouldBe` True
      context "succeeds to receive a StateQuery" $
        it "succeeds in sending request" $ do
          r <- withLifeRaft $ \raft (l, r) -> sendMsg raft l StateQuery
          isJust r `shouldBe` True
    describe "receiving/deserializing a LifeRaft message" $ do
      context "for an Action" $ do
        it "succeeds to receive a RequestVote" $ do
          r <- withLifeRaft $ checkResult $ Action (RequestVote (1, "abc", 1, 1))
          isJust r `shouldBe` True
        it "succeeds to receive a AppendEntries" $ do
          r <- withLifeRaft $ checkResult $ Action (AppendEntries (1, "abc", 1, 1, [], 1))
          isJust r `shouldBe` True
        it "succeeds to receive a AppendEntriesResult" $ do
          r <- withLifeRaft $ checkResult $ Action (AppendEntriesResult ("abc", 1, False))
          isJust r `shouldBe` True
        it "succeeds to receive a DiscoverNode" $ do
          r <- withLifeRaft $ checkResult $ Action (DiscoverNode "abc")
          isJust r `shouldBe` True
        it "succeeds to receive a ElectionTimeout" $ do
          r <- withLifeRaft $ checkResult $ Action ElectionTimeout
          isJust r `shouldBe` True
        it "succeeds to receive a VoteReceived" $ do
          r <- withLifeRaft $ checkResult $ Action (VoteReceived "abc")
          isJust r `shouldBe` True
        it "succeeds to receive a ClientRequest" $ do
          r <- withLifeRaft $ checkResult $ Action (ClientRequest 5)
          isJust r `shouldBe` True
      context "for a RequestFromClient" $
        it "succeeds in sending/receiving request" $ do
          r <- withLifeRaft $ checkResult $ RequestFromClient 2
          isJust r `shouldBe` True
      context "for a ServerConnReq" $
        it "succeeds in sending/receiving request" $ do
          r <- withLifeRaft $ checkResult $ ServerConnReq $ SockAddrInet 2 1
          isJust r `shouldBe` True
      context "for a ServerConnAccept" $
        it "succeeds in sending/receiving request" $ do
          r <- withLifeRaft $ checkResult ServerConnAccept
          isJust r `shouldBe` True
      context "for a ServerConnReject" $
        it "succeeds in sending/receiving request" $ do
          r <- withLifeRaft $ checkResult ServerConnReject
          isJust r `shouldBe` True
      context "succeeds to receive a StateQuery" $
        it "succeeds in sending/receiving request" $ do
          r <- withLifeRaft $ checkResult StateQuery
          isJust r `shouldBe` True

withLifeRaft :: (LifeRaft Int Int Int IO Int -> (Socket, Socket) -> IO ()) -> IO (Maybe ())
withLifeRaft f = liferaft >>= withConnectedSockets . f

checkResult :: LifeRaftMsg Int -> LifeRaft Int Int Int IO Int -> (Socket, Socket) -> IO ()
checkResult msg raft (l, r) = sendMsg raft l msg >> getMsg raft r >>= shouldBe msg . fromJust
