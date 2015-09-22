{-# LANGUAGE TemplateHaskell, DefaultSignatures, DeriveGeneric #-}
---------------------------------------------------------
-- Module      : Network.LifeRaft.Raft
-- Copyright   : (c) 2015 Yahoo, Inc.
-- License     : BSD3
-- Maintainer  : Dennis J. McWherter, Jr. (dennis@deathbytape.com)
-- Stability   : Experimental
-- Portability : non-portable
--
-- A Haskell Raft implementation for real-life.
--
-- For more details on Raft, see: http://ramcloud.stanford.edu/raft.pdf
--
---------------------------------------------------------

module Network.LifeRaft.Raft (
    initNode
  , Node(..)
  , NodeStatus(..)
  , NodeStateT
  -- * Algorithm control
  , RaftAction(..)
  , RaftResult(..)
  , stepRaft
  -- * RPCs and state-machine
  , appendEntries
  , requestVote
  , applyChanges
  -- * Type aliases
  , Id
  , Term
  , TimeoutInterval
  -- * Accessors
  , getCommitIndex
  , getCurrentLeader
  , getCurrentState
  , getCurrentTerm
  , getId
  , getLastApplied
  , getLog
  , getServerList
  , getVotedFor
  , getVotesReceived
  , getNodeStatus
) where

import Control.Lens
import Control.Monad.Trans.Class
import Control.Monad.Trans.State.Lazy
import qualified Data.HashMap.Lazy as HM
import Data.List
import qualified Data.Serialize as Ser
import GHC.Generics

type TimeoutInterval = (Int, Int)
type Term = Int
type Id = String

data NodeStatus = Leader | Follower | Candidate deriving (Eq, Show)

data NodeState a = NodeState { -- Persistent state (i.e. stored to disk)
                               _currentTerm :: Term
                             , _votedFor :: Maybe Id
                               -- TODO: Log entry should have UUID associated with it?
                             , _logEntries :: [(Term, a)]
                               -- Volatile state
                             , _commitIndex :: Int
                             , _lastApplied :: Int
                             , _nextIndex :: HM.HashMap Id Int
                             , _matchIndex :: HM.HashMap Id Int
                             , _nodeStatus :: NodeStatus
                             } deriving (Show, Generic)
-- TODO: Eventually a feature for checkpointing may be useful
makeLenses ''NodeState

type NodeStateT a s m r = StateT (Node a s m r) m

data Node a s m r = Node { _nodeState :: NodeState a
                         , _votesReceived :: [Id]
                         , _currentLeader :: Id
                         , _serverList :: [Id]
                         , _nodeId :: Id
                         , _stateSnapshot :: (r, s)
                         , _stateMachine :: (a -> StateT s (NodeStateT a s m r) r)
                         , _electionTimeout :: TimeoutInterval
                         }
makeLenses ''Node

-- | Action to execute
--
data RaftAction a =   RequestVote (Term, Id, Int, Term)
                    | AppendEntries (Term, Id, Int, Term, [(Term, a)], Int)
                    | AppendEntriesResult (Id, Int, Bool)
                    | DiscoverNode Id
                    | ElectionTimeout
                    | VoteReceived Id
                    | ClientRequest a
                      deriving (Show, Generic)
instance (Ser.Serialize a) => Ser.Serialize (RaftAction a)

-- | Result from state machine
--
data RaftResult a =  Elected
                   | ElectionStarted
                   | AppendEntriesSuccess (Id, Int)
                   | AppendEntriesFailure Id
                   | VoteGranted Id
                   | RejectVote Term
                   | RedirectToLeader Id
                   | HeartBeat [(Id, (Term, Id, Int, Term, [(Term, a)], Int))]
                   | Noop
                    deriving (Eq, Show)

type RaftState a s m r = StateT (Node a s m r) m (RaftResult a)

-- | Initialize a new node
--
-- Create a new node to be used in the Raft algorithm
--
initNode :: Monad m
         => [Id] -- ^ List of known server id's at startup
         -> Id -- ^ This node's id (format "server:port")
         -> (r, s) -- ^ Initial state of the state machine
         -> (a -> StateT s (NodeStateT a s m r) r) -- ^ State machine manipulation
         -> TimeoutInterval -- ^ Timeout interval in milliseconds
         -> Node a s m r
initNode serverList = Node (NodeState 0 Nothing [] (-1) (-1) (initMap 0) (initMap (-1)) Follower) [] "" serverList
  where initMap initialValue = foldl (\r v -> HM.insert v initialValue r) HM.empty serverList

-- | Advance the Raft algorithm
--
-- Advances the state of the Raft algorithm given input.
-- It returns a list of intermediate states from any applications to the
-- state machine in the most recent step.
--
stepRaft :: Monad m => RaftAction a -> StateT (Node a s m r) m (RaftResult a, [r])
stepRaft action = do
  result <- get >>= handleAction action
  updates <- applyChanges
  return (result, updates)
 where
   handleAction action node = do
     let status = node ^. getNodeStatus
     case action of
      ElectionTimeout -> startElection
      ClientRequest req -> handleClientRequest req status
      DiscoverNode id -> membershipChange id
      RequestVote voteData@(_, id, _, _) -> check (known id) $ voteRequestResponse voteData
      AppendEntries entryData@(_, id, _, _, _, _) -> check (known id) $ updateLog entryData
      VoteReceived id -> check isCandidate $ tallyVote id status
      AppendEntriesResult info@(id, _, True) -> check (known id && isLeader) $ receiveSuccess status info
      AppendEntriesResult info@(id, _, False) -> check (known id && isLeader) $ receiveFailure status info
    where isLeader = checkStatus Leader node
          isCandidate = checkStatus Candidate node
          isFollower = checkStatus Follower node
          known = isKnownServer node
          ignore :: Monad m => StateT (Node a s m r) m (RaftResult a)
          ignore = return Noop
          check pred res = if pred then res else ignore

-- | Respond to vote request
--
-- Invokes the requestVote RPC and updates state accordingly.
--
voteRequestResponse :: Monad m => (Term, Id, Int, Term) -> RaftState a s m r
voteRequestResponse (term, id, llIdx, llTerm) = do
    voted <- requestVote term id llIdx llTerm
    (votedFor, term) <- get >>= \x -> return (x ^. getVotedFor, x ^. getCurrentTerm)
    return $ maybe (checkVote votedFor term) RejectVote voted
  where
    checkVote votedFor term = maybe (RejectVote term) VoteGranted votedFor

-- | Update log entries
--
-- Invokes appendEntries RPC and updates state accordingly.
--
updateLog :: Monad m => (Term, Id, Int, Term, [(Term, a)], Int) -> RaftState a s m r
updateLog (term, id, pLogIdx, pLogTm, entries, commit) = do
    appended <- appendEntries term id pLogIdx pLogTm entries commit
    node <- get
    let nodeId = node ^. getId
        log = node ^. getLog
    if appended then do
      put $ (node & getNodeStatus .~ Follower) & currentLeader .~ id
      return $ AppendEntriesSuccess (nodeId, length log - 1)
    else
      return $ AppendEntriesFailure nodeId

-- | Tally votes
--
-- Counts votes while in candidate state and updates state.
--
tallyVote :: Monad m => Id -> NodeStatus -> RaftState a s m r
tallyVote id status = do
    node <- get
    let rcvd = node ^. getVotesReceived
        sList = node ^. getServerList
        updated = if id `notElem` rcvd && id `elem` sList then (node & getVotesReceived .~ (id : rcvd)) else node
        hasMajority = ((fromIntegral $ length (updated ^. getVotesReceived)) / (fromIntegral $ length sList + 1)) > 0.5
    if hasMajority then do
      put $ updated & getNodeStatus .~ Leader
      return Elected
    else do
      put updated
      return Noop

-- | Handle a successful log replication response
--
-- Keeps track of successful log replications and updates commit index
-- as majority replication occurs.
--
receiveSuccess :: Monad m => NodeStatus -> (Id, Int, Bool) -> RaftState a s m r
receiveSuccess status (id, idx, _) = do
    node <- get
    let commitIdx = node ^. getCommitIndex
        matchIdxMap = HM.insert id idx $ node ^. nodeState . matchIndex
        nextIdxMap  = HM.insert id (idx + 1) $ node ^. nodeState . nextIndex
        updated = (node & nodeState . matchIndex .~ matchIdxMap) & nodeState . nextIndex .~ nextIdxMap
        majority = calcMajorityIndex matchIdxMap
        result = if majority > commitIdx then (updated & getCommitIndex .~ majority) else updated
    put result
    return Noop

-- | Handle a failed log replication response
--
-- Keeps track of failed log replication requests, updates state, and retries.
--
receiveFailure status (id, _, _) = do
    node <- get
    let idx = HM.lookupDefault (length (node ^. getLog)) id (node ^. nodeState . nextIndex)
        nextIdxMap = HM.insert id (idx - 1) $ node ^. nodeState . nextIndex
        updated = node & nodeState . nextIndex .~ nextIdxMap
    put updated
    return $ heartbeat updated

-- | Start leader election process
--
startElection :: Monad m => StateT (Node a s m r) m (RaftResult a)
startElection = get >>= \node -> do
  put $ (((node & getVotedFor .~ Nothing) & getNodeStatus .~ Candidate) & getVotesReceived .~ [node ^. getId]) & getCurrentTerm .~ ((node ^. getCurrentTerm) + 1)
  return ElectionStarted

-- | Handle client request or forward to leader
--
-- Handles a client request if leader otherwise hints to redirect to the
-- current leader.
--
handleClientRequest req status = do
  node <- get
  if status == Leader then do
    let term = node ^. getCurrentTerm
        log = node ^. getLog
        updated = node & getLog .~ (log ++ [(term, req)])
    put updated
    return $ heartbeat updated
  else
    return $ RedirectToLeader (node ^. currentLeader)

-- TODO: Log compaction

-- | Update cluster membership
--
-- TODO: Make this work
--
membershipChange id = do
  -- TODO: Update membership and init 2-phase process
  node <- get
  let sList = node ^. serverList
  if elem id sList then return () else put $ node & serverList .~ (id : sList)
  return Noop

-- | Generate heartbeat
--
heartbeat :: Node a s m r -> RaftResult a
heartbeat node = HeartBeat $ foldl prepHB [] servers
  where nodeId = node ^. getId
        term = node ^. getCurrentTerm
        commitIdx = node ^. getCommitIndex
        nextIdx = node ^. nodeState . nextIndex
        servers = node ^. serverList
        log = node ^. getLog
        prepHB res id = (id, request next plIdx plTerm entries) : res
          where next = HM.lookupDefault (length log) id nextIdx
                plIdx = if next > 0 then (next - 1) else 0
                plTerm = if null log then 0 else fst $ log !! plIdx
                entries = drop plIdx log
        request idx plIdx plTerm entries = (term, nodeId, plIdx, plTerm, entries, commitIdx)

-- | Calculate highest index for majority
--
calcMajorityIndex matchIdxMap = minimum $ take count $ (reverse . sort) $ HM.elems matchIdxMap
  where count = ceiling $ (fromIntegral $ HM.size matchIdxMap) / 2

-- Access control functions

-- | Check whether or not this is a known server
--
isKnownServer :: Node a s m r -> Id -> Bool
isKnownServer node id = id `elem` (node ^. serverList)

-- | Check status of the node
--
checkStatus :: NodeStatus -> Node a s m r -> Bool
checkStatus status node = (node ^. getNodeStatus) == status

-- | Apply log changes to a node's state machine
--
-- This will apply changes to a state machine from (lastApplied, commitIdx] when
-- the commit index is updated.
--
applyChanges :: Monad m => StateT (Node a s m r) m [r]
applyChanges = applyChanges' []
  where
    applyChanges' results = do
      currentNode <- get
      let commitIdx = currentNode ^. getCommitIndex
          lastApplied = currentNode ^. getLastApplied
          sLog = currentNode ^. getLog
      if lastApplied < commitIdx && commitIdx < length sLog then do
        let nextToApply = lastApplied + 1
            logApplication = (currentNode ^. stateMachine) (snd $ sLog !! nextToApply)
        newState <- runStateT logApplication (snd $ currentNode ^. stateSnapshot)
        put $ (currentNode & getLastApplied .~ nextToApply) & stateSnapshot .~ newState
        applyChanges' ((fst newState) : results)
      else
        return results

-- | Append new entries to a node's log
--
-- Appends new entries to a node's log. Returns True if log entries properly appended
-- and false otherwise (i.e. reject request to append).
--
-- NOTE: This method does not actually *commit* any changes to the state machine.
--
appendEntries :: Monad m => Term -> Id -> Int -> Term -> [(Term, a)] -> Int -> StateT (Node a s m r) m Bool
appendEntries term leaderId prevLogIdx prevLogTerm entries leaderCommit = do
  currentNode <- get
  let sLog = currentNode ^. getLog
      curTerm = currentNode ^. getCurrentTerm
      prevIdxTerm = if length sLog <= prevLogIdx then 0 else (fst $ sLog !! prevLogIdx)
  if term < curTerm || prevLogTerm /= prevIdxTerm then
    return False
  else do
    -- Update the log: take all entries up to and including prevLogIdx and drop the rest. Append the remaining entries
    let updatedLog = (take (prevLogIdx + 1) sLog) ++ entries
    -- Update the commit index if necessary and step through machine
        commitIdx = currentNode ^. getCommitIndex
        updatedCI = if leaderCommit > commitIdx then (min leaderCommit ((length updatedLog) - 1)) else commitIdx
    put $ ((currentNode & getLog .~ updatedLog) & getCurrentTerm .~ term) & getCommitIndex .~ updatedCI
    return True

-- | Request vote RPC
--
-- A request vote call used in leader election.
-- Method returns Nothing if vote is granted, otherwise it returns the current term.
--
requestVote :: (Monad m) => Term -> Id -> Int -> Term -> StateT (Node a s m r) m (Maybe Term)
requestVote term candidateId lastLogIdx lastLogTerm = do
  currentNode <- get
  let currentTerm = currentNode ^. getCurrentTerm
      votedFor = currentNode ^. getVotedFor
  if term < currentTerm || maybe False (/=(currentNode ^. getId)) votedFor then
    return $ Just currentTerm
  else do
    let logs = currentNode ^. getLog
        grantVote = maybe True (\id -> lastLogIdx == ((length logs) - 1) && ((fst . last) logs) <= lastLogTerm) votedFor
    if grantVote then do
      put $ currentNode & getVotedFor .~ (Just candidateId)
      return Nothing
    else
      return $ Just currentTerm

-- Accessors
getLog :: Lens' (Node a s m r) [(Term, a)]
getLog = nodeState . logEntries

getCurrentTerm :: Lens' (Node a s m r) Term
getCurrentTerm = nodeState . currentTerm

getCommitIndex :: Lens' (Node a s m r) Int
getCommitIndex = nodeState . commitIndex

getLastApplied :: Lens' (Node a s m r) Int
getLastApplied = nodeState . lastApplied

getVotedFor :: Lens' (Node a s m r) (Maybe Id)
getVotedFor = nodeState . votedFor

getNodeStatus :: Lens' (Node a s m r) NodeStatus
getNodeStatus = nodeState . nodeStatus

getVotesReceived :: Lens' (Node a s m r) [Id]
getVotesReceived = votesReceived

getCurrentState :: Lens' (Node a s m r) (r, s)
getCurrentState = stateSnapshot

getId :: Lens' (Node a s m r) Id
getId = nodeId

getServerList :: Lens' (Node a s m r) [Id]
getServerList = serverList

getCurrentLeader :: Lens' (Node a s m r) Id
getCurrentLeader = currentLeader

