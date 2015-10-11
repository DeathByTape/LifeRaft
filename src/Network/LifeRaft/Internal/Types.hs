---------------------------------------------------------
-- Module      : Network.LifeRaft.Internal.Types
-- Copyright   : (c) 2015 Yahoo, Inc.
-- License     : BSD3
-- Maintainer  : Dennis J. McWherter, Jr. (dennis@deathbytape.com)
-- Stability   : Experimental
-- Portability : non-portable
--
-- Data types for LifeRaft.
--
---------------------------------------------------------

module Network.LifeRaft.Internal.Types (
    LifeRaft(..)
  , LifeRaftMsg(..)
  ) where

import Control.Concurrent.STM
import Control.Monad
import Control.Monad.Trans.State.Lazy
import qualified Data.ByteString as B
import Data.Serialize
import Network.LifeRaft.Raft.Internal.Types
import Network.Socket (SockAddr(..), Socket(..))

-- | Structure holding LifeRaft state
data LifeRaft a b s m r =
  LifeRaft { pendingRequests :: TVar [(Socket, Int)]
           , serverConnections :: TVar [(SockAddr, Socket)]
           , activeServers :: TVar [SockAddr]
           , ourSockAddr :: SockAddr
           , node :: TVar (Node a s m r)
           , stateQuery :: b -> StateT s (NodeStateT a s m r) r
           }

-- Serialization for SockAddr for sending server connection request (indexed by server root SockAddrs)
instance Serialize SockAddr where
 put saddr = case saddr of
              SockAddrInet port host -> putWord16be (fromIntegral port) >> putWord32be host
              _ -> fail "Unsupported."
 get = getWord16be >>= \port -> getWord32be >>= \host -> return $ SockAddrInet (fromIntegral port) host

-- | Request/Response types
data LifeRaftMsg a = Action (RaftAction a)
                    | RequestFromClient a
                    | ServerConnReq (SockAddr)
                    | ServerConnAccept
                    | ServerConnReject
                    | StateQuery deriving (Eq, Show)

-- NOTE: This protocol is a bit wasteful. Can probably tweak it later
instance (Serialize a) => Serialize (LifeRaftMsg a) where
  put msg = case msg of
              Action act -> putWord32be 0 >> putValue act
              RequestFromClient req -> putWord32be 1 >> putValue req
              ServerConnReq addr -> putWord32be 2 >> putValue addr
              ServerConnAccept -> putWord32be 3
              ServerConnReject -> putWord32be 4
              StateQuery -> putWord32be 5
    where putValue val = let bs = encode val in putWord32be (fromIntegral $ B.length bs) >> putByteString bs
  get = getWord32be >>= \cmd -> case cmd of
      0 -> Action <$> getValue
      1 -> RequestFromClient <$> getValue
      2 -> ServerConnReq <$> getValue
      3 -> return ServerConnAccept
      4 -> return ServerConnReject
      5 -> return StateQuery
      _ -> fail "Bad deserialization request"
    where getValue :: (Serialize a) => Get a
          getValue = getWord32be >>= getByteString . fromIntegral >>= either (fail "Could not deserialize") return . decode
