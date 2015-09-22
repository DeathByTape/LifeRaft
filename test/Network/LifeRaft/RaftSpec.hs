---------------------------------------------------------                                                                                                                                                                                                                           ------ Module      : Network.LifeRaft.Raft
---- Copyright   : (c) 2015 Yahoo, Inc.
---- License     : BSD3
---- Maintainer  : Dennis J. McWherter, Jr. (dennis@deathbytape.com)
---- Stability   : Experimental
---- Portability : non-portable
----
---- An example key-value store using LifeRaft.
----
-----------------------------------------------------------

module Network.LifeRaft.RaftSpec (spec) where

import Network.LifeRaft.Raft

import Test.Hspec
import Test.QuickCheck

import Control.Monad
import Control.Monad.Trans.State.Lazy
import Control.Lens
import Data.Maybe

testMachine :: (Monad m) => Int -> StateT Int (NodeStateT Int Int m Int) Int
testMachine storeVal = put storeVal >> get

spec :: Spec
spec = do
    -- Append entries RPC
    describe "appendEntries RPC" $ do
      it "appends entries to nodes under conditions specified by Raft algorithm" $ do
        -- First proper advance
        (r1, n1) <- runStateT (appendEntries 1 "1" 0 0 [(1,1)] 1) startNode
        checkNodeVals' [(1,1)] 0 1 n1
        r1 `shouldBe` True
        -- Bad advance on new node (term)
        (r2, n2) <- runStateT (appendEntries 0 "1" 0 1 [(1,2)] 1) startNode
        checkNodeVals' [] (-1) 0 n2
        r2 `shouldBe` False
        -- Bad advance on continuation (term)
        (r3, n3) <- runStateT (appendEntries 0 "1" 0 1 [(1,2)] 1) n1
        checkNodeVals' [(1,1)] 0 1 n3
        r3 `shouldBe` False
        -- Good advance on proper continuation
        (r4, n4) <- runStateT (appendEntries 2 "1" 0 1 [(2,1),(2,2)] 1) n1
        checkNodeVals' [(1,1),(2,1),(2,2)] 1 2 n4
        r4 `shouldBe` True
        -- Bad advance on continuation (bad prev term)
        (r5, n5) <- runStateT (appendEntries 2 "1" 1 1 [(2,5)] 1) n4
        checkNodeVals' [(1,1),(2,1),(2,2)] 1 2 n5
        r5 `shouldBe` False
        -- Replace entry advance on continuation
        (r6, n6) <- runStateT (appendEntries 2 "1" 1 2 [(2,5)] 1) n5
        checkNodeVals' [(1,1),(2,1),(2,5)] 1 2 n6
        r6 `shouldBe` True

    -- Request vote RPC
    describe "requestVote RPC" $ do
      it "responds to voting requests under conditions specified by Raft algorithm" $ do
        -- Valid request number one (initial node)
        (r1, n1) <- runStateT (requestVote 1 "first" 0 0) startNode
        r1 `shouldBe` Nothing
        checkNodeVals'' (Just "first") [] (-1) 0 n1
        -- Add some state
        (r2, n2) <- runStateT (appendEntries 1 "1" 0 0 [(1,2)] 1) startNode
        r2 `shouldBe` True
        checkNodeVals' [(1,2)] 0 1 n2
        -- Valid request on given state
        (r3, n3) <- runStateT (requestVote 2 "second" 1 1) n2
        r3 `shouldBe` Nothing
        checkNodeVals'' (Just "second") [(1,2)] 0 1 n3
        -- Ensure we don't reissue votes after having voted
        (r4, n4) <- runStateT (requestVote 3 "third" 1 1) n3
        r4 `shouldBe` (Just 1)
        checkNodeVals'' (Just "second") [(1,2)] 0 1 n4
        -- Issue bad request on unvoted node
        (r5, n5) <- runStateT (requestVote 0 "third" 1 1) n2
        r5 `shouldBe` (Just 1)
        checkNodeVals' [(1,2)] 0 1 n5
        
    -- Apply changes mechanism
    describe "applyChanges" $ do
      context "when applied with a valid term" $ do
        it "applies changes to state machine" $ smApplication 1 verifyNodeApp
      context "when applied with an invalid term" $ do
        it "applies no changes to the state machine" $ smApplication (-1) verifyNoNodeApp

    -- Macro-level Raft algorithm controller
    describe "stepRaft" $ do
      context "when it receives a membership change" $ do
        it "adds new server that doesn't exist yet" $ do
          (r1, n1) <- runStateT (stepRaft (DiscoverNode "testNode")) startNode
          r1 `shouldBe` (Noop, [])
          checkNodeVals (-1) Nothing ["testNode"] [] (-1) 0 n1
        it "adds unique servers to an existing list" $ do
          (r1, n1) <- runStateT (stepRaft (DiscoverNode "testNode")) startNodeServers
          r1 `shouldBe` (Noop, [])
          checkNodeVals (-1) Nothing ["testNode", "testServer"] [] (-1) 0 n1
        it "does not add duplicates to the list" $ do
          (r1, n1) <- runStateT (stepRaft (DiscoverNode "testServer")) startNodeServers
          r1 `shouldBe` (Noop, [])
          checkNodeVals (-1) Nothing ["testServer"] [] (-1) 0 n1
      context "when it receives a request vote" $ do
        it "does not accept votes with lower terms" $ do
          (r1, n1) <- runStateT (stepRaft (RequestVote ((-1), "testServer", 0, 0))) startNodeServers
          r1 `shouldBe` (RejectVote 0, [])
          checkNodeVals (-1) Nothing ["testServer"] [] (-1) 0 n1
        it "does not accept votes from unknown servers and ignores the request" $ do
          (r1, n1) <- runStateT (stepRaft (RequestVote (1, "unknown", 0, 0))) startNodeServers
          r1 `shouldBe` (Noop, [])
          checkNodeVals (-1) Nothing ["testServer"] [] (-1) 0 n1
        it "accepts requests from valid servers" $ do
          (r1, n1) <- runStateT (stepRaft (RequestVote (1, "testServer", 0, 0))) startNodeServers
          r1 `shouldBe` (VoteGranted "testServer", [])
          checkNodeVals (-1) (Just "testServer") ["testServer"] [] (-1) 0 n1
      context "when it receives an append entries request" $ do
        it "appends new entries to its log from a valid term and commits from leader" $ do
          (r1, n1) <- runStateT (stepRaft (AppendEntries (1, "testServer", 0, 0, [(1, 1),(1,2)], 0))) startNodeServers
          r1 `shouldBe` (AppendEntriesSuccess ("somehost:port", 1), [1])
          checkNodeVals 0 Nothing ["testServer"] [(1,1),(1,2)] 0 1 n1
          let (val, _) = (n1 ^. getCurrentState)
          val `shouldBe` 1
        it "ignores requests from unknown servers" $ do
          (r1, n1) <- runStateT (stepRaft (AppendEntries(1, "unknown", 0, 0, [(1,1)], 0))) startNodeServers
          r1 `shouldBe` (Noop, [])
          checkNodeVals (-1) Nothing ["testServer"] [] (-1) 0 n1
        it "fails for older terms" $ do
          (r1, n1) <- runStateT (stepRaft (AppendEntries((-1), "testServer", 0, 0, [(1,1)], 0))) startNodeServers
          r1 `shouldBe` (AppendEntriesFailure "somehost:port", [])
          checkNodeVals (-1) Nothing ["testServer"] [] (-1) 0 n1
      context "when it receives an election timeout" $ do
        it "starts a new election and updates its status" $ do
          (r1, n1) <- runStateT (stepRaft ElectionTimeout) startNodeMultiServers
          r1 `shouldBe` (ElectionStarted, [])
          checkNodeVals (-1) Nothing ["s1","s2","s3"] [] (-1) 1 n1
          checkNodeStatus n1 Candidate
          checkNodeVotesRcvd n1 ["s0"]
      context "when it receives a vote received" $ do
        it "ignores votes when not in candidate state" $ do
          (r1, n1) <- runStateT (stepRaft (VoteReceived "s1")) startNodeMultiServers
          r1 `shouldBe` (Noop, [])
          checkNodeVals (-1) Nothing ["s1","s2","s3"] [] (-1) 0 n1
          checkNodeVotesRcvd n1 []
        it "accepts votes from valid servers but does not elect before majority received" $ do
          (rCandidate, candidate) <- runStateT (stepRaft (ElectionTimeout)) startNodeMultiServers
          rCandidate `shouldBe` (ElectionStarted, [])
          checkNodeStatus candidate Candidate
          (r1, n1) <- runStateT (stepRaft (VoteReceived "s1")) candidate
          r1 `shouldBe` (Noop, [])
          checkNodeVals (-1) Nothing ["s1","s2","s3"] [] (-1) 1 n1
          checkNodeVotesRcvd n1 ["s1", "s0"]
        it "completes election and updates status when receiving majority vote" $ do
          (rCandidate, candidate) <- runStateT (stepRaft (ElectionTimeout)) startNodeMultiServers
          rCandidate `shouldBe` (ElectionStarted, [])
          checkNodeStatus candidate Candidate
          (r1, n1) <- runStateT (stepRaft (VoteReceived "s1")) candidate
          (r2, n2) <- runStateT (stepRaft (VoteReceived "unknown")) n1
          r2 `shouldBe` (Noop, [])
          (r3, n3) <- runStateT (stepRaft (VoteReceived "s3")) n2
          r3 `shouldBe` (Elected, [])
          checkNodeVals (-1) Nothing ["s1","s2","s3"] [] (-1) 1 n3
          checkNodeVotesRcvd n3 ["s3","s1","s0"]
          checkNodeStatus n3 Leader
      context "when it receives a client request" $ do
        it "redirects request if not leader" $ do
          (ri, initial) <- runStateT (stepRaft (AppendEntries (1, "s1", 0, 0, [(1,1)], 0))) startNodeMultiServers
          (r1, n1) <- runStateT (stepRaft (ClientRequest 1)) initial
          r1 `shouldBe` (RedirectToLeader "s1", [])
          checkNodeVals 0 Nothing ["s1", "s2", "s3"] [(1,1)] 0 1 n1
        it "does not respond to request if not replicated on majority" $ do
          leader <- getLeaderNode
          (r1, n1) <- runStateT (stepRaft (ClientRequest 1)) leader
          r1 `shouldBe` (HeartBeat [("testServer",(1,"somehost:port",0,1,[(1,1)],(-1)))], [])
          checkNodeVals (-1) Nothing ["testServer"] [(1,1)] (-1) 1 n1
        it "responds to request when replicated on majority" $ do
          leader <- getLeaderNode
          (r1, n1) <- runStateT (stepRaft (ClientRequest 1)) leader
          r1 `shouldBe` (HeartBeat [("testServer",(1,"somehost:port",0,1,[(1,1)],(-1)))], [])
          checkNodeVals (-1) Nothing ["testServer"] [(1,1)] (-1) 1 n1
          (r2, n2) <- runStateT (stepRaft (AppendEntriesResult ("testServer", 0, True))) n1
          r2 `shouldBe` (Noop, [1])
          checkNodeVals 0 Nothing ["testServer"] [(1,1)] 0 1 n2
      context "when it receives a replicated log result" $ do
        it "ignores the request if it's not a leader" $ do
          (r1, n1) <- runStateT (stepRaft (AppendEntriesResult ("testServer", 0, True))) startNodeMultiServers
          r1 `shouldBe` (Noop, [])
          -- TODO: Should check inner state here?
        it "ignores the request from unknown servers" $ do
          l1 <- getLeaderNode' startNodeMultiServers
          (_, leader) <- runStateT (stepRaft (ClientRequest 1)) l1
          (r1, n1) <- runStateT (stepRaft (AppendEntriesResult ("unknown", 0, True))) leader
          r1 `shouldBe` (Noop, [])
          -- TODO: Inner-state?
        it "accepts requests from valid servers" $ do
          l1 <- getLeaderNode' startNodeMultiServers
          (_, leader) <- runStateT (stepRaft (ClientRequest 1)) l1
          (r1, n1) <- runStateT (stepRaft (AppendEntriesResult ("s1", 0, True))) leader
          r1 `shouldBe` (Noop, [])
          -- TODO: Inner-state
        it "it updates commit index when replicated by majority" $ do
          l1 <- getLeaderNode
          (_, leader) <- runStateT (stepRaft (ClientRequest 1)) l1
          (r1, n1) <- runStateT (stepRaft (AppendEntriesResult ("testServer", 0, True))) leader
          r1 `shouldBe` (Noop, [1])
          checkNodeVals 0 Nothing ["testServer"] [(1,1)] 0 1 n1
        it "decrements node index when node fails to replicate log" $ do
          l1 <- getLeaderNode
          (_, leader) <- runStateT (stepRaft (ClientRequest 1)) l1
          (r1, n1) <- runStateT (stepRaft (AppendEntriesResult ("testServer", 0, False))) leader
          r1 `shouldBe` (HeartBeat [("testServer",(1,"somehost:port",0,1,[(1,1)],-1))],[])
  where
    -- Initial node in IO monad
    startNode = initNode [] "localhost:noport" (0, 0) testMachine (10, 20)
    -- Inital node in Maybe monad
    startNodeMb = initNode [] "localhost:noport" (0, -1) testMachine (10, 20)
    -- Initial node with servers
    startNodeServers = initNode ["testServer"] "somehost:port" (0, 0) testMachine (10, 20)
    -- Initial node with a couple servers
    startNodeMultiServers = initNode ["s1","s2","s3"] "s0" (0, 0) testMachine (10, 20)
    -- Leader node
    getLeaderNode = getLeaderNode' startNodeServers
    getLeaderNode' node = do
      (_, l1) <- runStateT (stepRaft ElectionTimeout) node
      (_, l2) <- runStateT (stepRaft (VoteReceived "s1")) l1
      (_, l3) <- runStateT (stepRaft (VoteReceived "s2")) l2
      (_, leader) <- runStateT (stepRaft (VoteReceived "testServer")) l3
      checkNodeStatus leader Leader
      return leader
    -- Node verification methods
    checkNodeVals lastApplied votedFor serverList logEntries commitIndex term node = do
      (node ^. getLog) `shouldBe` logEntries
      (node ^. getCommitIndex) `shouldBe` commitIndex
      (node ^. getCurrentTerm) `shouldBe` term
      (node ^. getLastApplied) `shouldBe` lastApplied
      (node ^. getVotedFor) `shouldBe` votedFor
      (node ^. getServerList) `shouldBe` serverList
    checkNodeVals' = checkNodeVals'' Nothing
    checkNodeVals'' votedFor = checkNodeVals (-1) votedFor []
    checkNodeStatus node = shouldBe (node ^. getNodeStatus)
    checkNodeVotesRcvd node = shouldBe (node ^. getVotesReceived)
    -- Node application helper
    smApplication term verifyFn = property $ \x ->
      let logs = zip (repeat term) (take 5 $ [(x :: Int)..]) in
      let initState = runStateT (appendEntries term "1" 0 0 logs 4) startNodeMb in
      maybe False (\(_, node) ->
                    let compState = runStateT applyChanges node in
                    maybe False (verifyFn logs) compState)
        initState    
    -- Verify node after application
    verifyNodeApp logEntries (r, node) =(not $ null logEntries)
                                         && ((snd $ node ^. getCurrentState) == ((snd . last) logEntries))
                                         && ((node ^. getLog) == logEntries)
                                         && (reverse r == fmap snd logEntries)
    verifyNoNodeApp logEntries (r, node) = (not $ null logEntries)
                                           && (null $ node ^. getLog)
                                           && ((snd $ node ^. getCurrentState) == -1)
                                           
