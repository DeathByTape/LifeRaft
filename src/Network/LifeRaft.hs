{-# LANGUAGE OverloadedStrings, DeriveGeneric, DefaultSignatures #-}
---------------------------------------------------------
-- Module      : Network.LifeRaft
-- Copyright   : (c) 2015 Yahoo, Inc.
-- License     : BSD3
-- Maintainer  : Dennis J. McWherter, Jr. (dennis@deathbytape.com)
-- Stability   : Experimental
-- Portability : non-portable
--
-- Raft (https://raft.github.io) is a protocol for solving consensus in
-- distributed systems. LifeRaft is an implementation of this algorithm
-- for the real world.
---------------------------------------------------------

module Network.LifeRaft (
  -- * LifeRaft
    LifeRaft(..)
  , createLifeRaft
  , runLifeRaft
  -- * Raft utils
  , initNode
  , NodeStateT(..)
) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.Thread.Delay
import Control.Exception
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.State.Lazy
import qualified Data.ByteString.Char8 as B
import Data.List (isPrefixOf, (\\))
import Data.List.Split (splitOn)
import Data.Maybe
import qualified Data.Serialize as Ser
import Data.Tuple
import GHC.Generics
import Network.BSD
import Network.Socket hiding (send, sendTo, recv, recvFrom)
import Network.Socket.ByteString
import Network.LifeRaft.Raft
import System.IO
import System.Timeout

-- TODO: Need to use monad-logger over putStrLn statements

-- | Structure holding LifeRaft state
--
data LifeRaft a b s m r = LifeRaft { pendingRequests :: TVar [(Socket, Int)]
                                   , serverConnections :: TVar [(SockAddr, Socket)]
                                   , activeServers :: TVar [SockAddr]
                                   , ourSockAddr :: SockAddr
                                   , node :: TVar (Node a s m r)
                                   , stateQuery :: (b -> StateT s (NodeStateT a s m r) r)
                                   }

-- Serialization for SockAddr for sending server connection request (indexed by server root SockAddrs)
instance Ser.Serialize SockAddr where
  put saddr = case saddr of
               SockAddrInet (PortNum port) host -> Ser.putWord16be port >> Ser.putWord32be host
               _ -> fail "Unsupported."
  get = Ser.getWord16be >>= \port -> Ser.getWord32be >>= \host -> return $ SockAddrInet (PortNum port) host

-- | Request/Response types
--
data LifeRaftMsg a = Action (RaftAction a)
                   | RequestFromClient a
                   | ServerConnReq (SockAddr)
                   | ServerConnAccept
                   | ServerConnReject
                   | StateQuery deriving (Generic, Show)
-- NOTE: This protocol is a bit wasteful, but currently setting large enough to flush the send buffer
instance (Ser.Serialize a) => Ser.Serialize (LifeRaftMsg a) where
  put msg = case msg of
              Action act -> Ser.putWord32be 0 >> Ser.putByteString (Ser.encode act)
              RequestFromClient req -> Ser.putWord32be 1 >> Ser.putByteString (Ser.encode req)
              ServerConnReq addr -> Ser.putWord32be 2 >> Ser.putByteString (Ser.encode addr)
              ServerConnAccept -> Ser.putWord32be 3
              ServerConnReject -> Ser.putWord32be 4
              StateQuery -> Ser.putWord32be 5

-- | Create a LifeRaft instance
--
createLifeRaft :: (Monad m, MonadIO m, Ser.Serialize a, Ser.Serialize b, Ser.Serialize r)
               => Node a s m r -- ^ Raft node to control
               -> (b -> StateT s (NodeStateT a s m r) r) -- ^ Mechanism to query current state
               -> m (LifeRaft a b s m r)
createLifeRaft node query = do
    pReqs <- newTVarM []
    sConns <- newTVarM []
    aServers <- newTVarM []
    tNode <- newTVarM node
    let nodeId = node ^. getId
    ourSaddr <- liftIO $ getSockAddr nodeId >>= maybe (fail "Could not get sockaddr.") return
    return $ LifeRaft pReqs sConns aServers ourSaddr tNode query
  where newTVarM = liftIO . newTVarIO

-- | Execute a LifeRaft server
--
runLifeRaft :: (Monad m, Ser.Serialize a, Ser.Serialize b, Ser.Serialize r) => String -> LifeRaft a b s m r -> IO ()
runLifeRaft clientAddr state = newSock >>= \nSock -> newSock >>= \cSock -> startAndRun nSock cSock >> sClose nSock >> sClose cSock
  where startAndRun nSock cSock = startListener sAddr nSock >> startListener cAddr cSock >> lifeRaftMainLoop nSock cSock state
        serverComps = (readTVarIO $ node state) >>= getSockAddr . (view getId)
        sAddr = serverComps >>= maybe (fail "Could not get sockAddr for host.") return
        cAddr = getSockAddr clientAddr >>= maybe (fail "Could not get client host sockAddr.") return
        newSock = socket AF_INET Stream defaultProtocol >>= \sock -> setSocketOption sock NoDelay 1 >> setSocketOption sock ReuseAddr 1 >> return sock
        startListener addr sock = addr >>= bind sock >> listen sock 5

-- | Main context in which LifeRaft executes
--
-- TODO: May eventually want to track thread id's for graceful exits.
lifeRaftMainLoop :: (Monad m, Ser.Serialize a, Ser.Serialize b, Ser.Serialize r) => Socket -> Socket -> LifeRaft a b s m r -> IO ()
lifeRaftMainLoop nodeSock clientSock liferaft = serverMonitor >> nodeHandler >> clientHandler
  where clientHandler = serverLoop clientSock handleClientConnection
        nodeHandler = forkIO $ serverLoop nodeSock handleServerConnection
        serverMonitor = forkIO $ connectToServers liferaft
        serverLoop sock handler = sequence_ (repeat $ accept sock >>= forkIO . handler liferaft . swap)

-- | Manager in charge of keeping server connections alive
--
-- Reconnects as necessary and removes dead servers
--
connectToServers :: (Monad m, Ser.Serialize a) => LifeRaft a b s m r -> IO ()
connectToServers liferaft = forever $ do
    servers <- (liftM (foldl (\result saddr -> maybe result (:result) saddr) [])) resolveNames
    curConns <- readTVarIO $ serverConnections liferaft
    let connSaddrs = fmap fst curConns
        unconnected = filter (`notElem`connSaddrs) servers
    if not $ null unconnected then do
      putStrLn $ "Attempting to connect to: " ++ show unconnected
      connectTo unconnected
      updatedConnections <- currentConnections
      putStrLn $ "Connected to: " ++ show updatedConnections
      putStrLn "Done with connection attempts. Waiting 3 seconds before next attempt."
    else putStrLn "Connected to all servers."
    delay 3000000
    -- TODO: Cleanup connections to servers that are no longer active
  where resolveNames = (readTVarIO $ node liferaft) >>= sequence . fmap getSockAddr . (view getServerList)
        currentConnections = readTVarIO $ serverConnections liferaft
        connectTo = sequence . fmap tryConnect
        tryConnect saddr = newSocket >>= (\sock -> (initConn saddr sock) `catch` (\e -> (putStrLn $ "Exception: " ++ show (e :: SomeException)) >> sClose sock))
        newSocket = socket AF_INET Stream defaultProtocol >>= \sock -> setSocketOption sock NoDelay 1 >> return sock
        initConn saddr sock = connect sock saddr >> identifyAsServer liferaft (saddr, sock) >>= \identified -> if identified then return () else (sClose sock)

-- | Handle server connection requests
--
-- First establishes that this is truly a server request (else it is forwared to client connection)
-- and then handles requests appropriately
--
handleServerConnection :: (Monad m, Ser.Serialize a, Ser.Serialize b, Ser.Serialize r)
                       => LifeRaft a b s m r
                       -> (SockAddr, Socket)
                       -> IO ()
handleServerConnection liferaft conn@(_, sock) = getMsg liferaft sock >>= maybe (sClose sock) initRequest
  where initRequest request = do
          putStrLn "Handling server connection request."
          case request of
           ServerConnReq id -> addServerConnection liferaft (id, sock) >>= \x -> if x then handler else sClose sock
           _ -> putStrLn "Received bad server handshake." >> sClose sock
        handler = return ()

-- | Handle client connection request
--
-- Handle requests made by client
--
handleClientConnection :: (Monad m, Ser.Serialize a, Ser.Serialize b, Ser.Serialize r)
                       => LifeRaft a b s m r
                       -> (SockAddr, Socket)
                       -> IO ()
handleClientConnection liferaft (saddr, sock) = do
  putStrLn "Client connected."
  return ()

-- | Server id
--
-- Perform simple server identification
--
identifyAsServer :: (Ser.Serialize a) => LifeRaft a b s m r -> (SockAddr, Socket) -> IO Bool
identifyAsServer liferaft conn@(_, sock) = sendMsg liferaft sock (ServerConnReq sId) >> getMsg liferaft sock >>= handleResp
  where sId = ourSockAddr liferaft
        handleResp res = do
          case res of
           Nothing -> putStrLn "Could not deserialize response." >> return False
           Just v -> case v of
             ServerConnAccept -> addServerConnection liferaft conn
             ServerConnReject -> putStrLn "Server already connected from this address." >> return False
             _ -> putStrLn "Invalid server identification response." >> return False

-- Additional Helpers

addServerConnection :: LifeRaft a b s m r -> (SockAddr, Socket) -> IO Bool
addServerConnection liferaft conn@(saddr, _) = atomically $ do
    servers <- readTVar conns
    active <- readTVar activeList
    let connected = fmap fst servers
    if saddr `notElem` active || saddr `elem` connected then
      return False
    else do
      writeTVar conns (conn : servers)
      return True
  where conns = serverConnections liferaft
        activeList = activeServers liferaft

-- NOTE: Currently assuming IPv4
getSockAddr :: String -> IO (Maybe SockAddr)
getSockAddr serverId = do
  let val = splitOn ":" serverId
  if length val /= 2 then
    return Nothing
  else do
    hAddr <- getHostByName $ val !! 0
    return $ Just $ SockAddrInet (fromInteger ((read $ val !! 1) :: Integer)) (hostAddress hAddr)
     
getActiveServers :: LifeRaft a b s m r -> IO [SockAddr]
getActiveServers liferaft = readTVarIO $ activeServers liferaft

--
-- Extra info for type inference
--
sendMsg :: (Ser.Serialize a) => LifeRaft a b s m r -> Socket -> LifeRaftMsg a -> IO ()
sendMsg _ sock msg = sendWithLen sock $! Ser.encode msg

getMsg :: (Ser.Serialize a) => LifeRaft a b s m r -> Socket -> IO (Maybe (LifeRaftMsg a))
getMsg _ sock = do
  putStrLn "Receiving message..."
  -- 5s timeout
  -- TODO: Should be configurable
  final <- timeout 5000000 $ do
    msg <- recvWithLen sock
    case Ser.decode msg of
     Left e -> putStrLn ("Could not decode message: " ++ show e) >> return Nothing
     Right result -> putStrLn "Message received." >> (return $ Just result)
  maybe (putStrLn "Receive timed out." >> return Nothing) (return . id) final

--
-- The following methods are network helpers
-- some of them are being reproduced from places like Network.Transport.TCP
--
-- The goal is to move to Network.Transport if the team is willing to maintain a
-- standard protocol for connections such that foreign clients can connect properly.
--
-- TODO: Need to get in touch with the CloudHaskell team about this.
--

-- TODO: Should account for endianess. That is, everything should be sent/received in network byte order
--       (i.e. big endian) and converted appropriately.

recvWithLen :: Socket -> IO B.ByteString
recvWithLen sock = recvInt32 sock >>= recvAll sock

recvInt32 :: Socket -> IO Int
recvInt32 sock = recvAll sock 4 >>= return . maybe (-1) fst . B.readInt

recvAll :: Socket -> Int -> IO B.ByteString
recvAll sock total = if total > 0 then recvAll' (return B.empty) else return B.empty
  where recvAll' bs = do
          rcvd <- bs
          let len = B.length rcvd
          putStrLn $ "Receiving: " ++ show rcvd  ++ " == " ++ show len ++ " of " ++ show total
          if len == total then bs else recv sock (total - len) >>= recvAll' . return . (B.append rcvd)

sendWithLen :: Socket -> B.ByteString -> IO ()
sendWithLen sock msg = (sendAll sock $! (B.pack $ show $ B.length msg)) >> sendAll sock msg >> (putStrLn $ "Sent: " ++ show msg)

