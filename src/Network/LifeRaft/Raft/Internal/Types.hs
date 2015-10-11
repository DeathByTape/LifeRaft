{-# LANGUAGE DefaultSignatures, DeriveGeneric #-}
---------------------------------------------------------
-- Module      : Network.LifeRaft.Raft.Internal.Types
-- Copyright   : (c) 2015 Yahoo, Inc.
-- License     : BSD3
-- Maintainer  : Dennis J. McWherter, Jr. (dennis@deathbytape.com)
-- Stability   : Experimental
-- Portability : non-portable
--
-- Data types for Raft.
--
---------------------------------------------------------

module Network.LifeRaft.Raft.Internal.Types (
  -- * Node types
    Node(..)
  , NodeStatus(..)
  , NodeState(..)
  , NodeStateT
  -- * Algorithm types
  , RaftAction(..)
  , RaftResult(..)
  , RaftState
  -- * Type aliases
  , Id
  , Term
  , TimeoutInterval
  ) where

import Control.Monad.Trans.State.Lazy
import Data.HashMap.Lazy
import Data.Serialize
import GHC.Generics

-- | Interval for timeout in ms
-- Format of (start, end)
type TimeoutInterval = (Int, Int)

-- | Current Raft Term
type Term = Int

-- | Node id
-- Formatted string of: "hostname:port"
type Id = String

-- | Node status
-- The valid status of a node
data NodeStatus = Leader | Follower | Candidate deriving (Eq, Show)

-- | Node State
-- State for any given node in the Raft protocol
data NodeState a =
  NodeState { -- Persistent state (i.e. stored to disk)
              _currentTerm :: Term
            , _votedFor :: Maybe Id
            -- TODO: Log entry should have UUID associated with it?
            , _logEntries :: [(Term, a)]
            -- Volatile state
            , _commitIndex :: Int
            , _lastApplied :: Int
            , _nextIndex :: HashMap Id Int
            , _matchIndex :: HashMap Id Int
            , _nodeStatus :: NodeStatus
            } deriving (Show, Generic)

-- | Node state type
-- State type alias to encapsulate node changes
type NodeStateT a s m r = StateT (Node a s m r) m

-- | Node
-- State representing a top-level node attributes
data Node a s m r =
  Node { _nodeState :: NodeState a
       , _votesReceived :: [Id]
       , _currentLeader :: Id
       , _serverList :: [Id]
       , _nodeId :: Id
       , _stateSnapshot :: (r, s)
       , _stateMachine :: a -> StateT s (NodeStateT a s m r) r
       , _electionTimeout :: TimeoutInterval
       }

-- | Action to execute
data RaftAction a =   RequestVote (Term, Id, Int, Term)
                     | AppendEntries (Term, Id, Int, Term, [(Term, a)], Int)
                     | AppendEntriesResult (Id, Int, Bool)
                     | DiscoverNode Id
                     | ElectionTimeout
                     | VoteReceived Id
                     | ClientRequest a
                     deriving (Show, Generic)
-- Default serialization instance
instance (Serialize a) => Serialize (RaftAction a)

-- | Result from state machine
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

-- | Type alias for modifying RaftState
type RaftState a s m r = StateT (Node a s m r) m (RaftResult a)
