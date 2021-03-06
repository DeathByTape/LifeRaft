{-# LANGUAGE OverloadedStrings #-}
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
import qualified Data.Serialize as Ser
import Data.Tuple (swap)
import Network.Socket hiding (recvAll)

import Network.LifeRaft.Internal.Communications
import Network.LifeRaft.Internal.NetworkHelper
import Network.LifeRaft.Internal.Types
import Network.LifeRaft.Raft

-- TODO: Need to use monad-logger over putStrLn statements

-- | Create a LifeRaft instance
--
createLifeRaft :: (Monad m, MonadIO m, Ser.Serialize a, Ser.Serialize b, Ser.Serialize r)
               => Node a s m r -- ^ Raft node to control
               -> (b -> StateT s (NodeStateT a s m r) r) -- ^ Mechanism to query current state
               -> m (LifeRaft a b s m r)
createLifeRaft node query = do
    pReqs <- newTVarM []
    sConns <- newTVarM []
    aSaddrs <- liftIO $ sequence $ fmap (getSockAddr >=> maybe (fail "Could not get sock addr for initial server.") return) $ node ^. getServerList
    aServers <- newTVarM aSaddrs
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
        serverComps = readTVarIO (node state) >>= getSockAddr . view getId
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
    servers <- liftM (foldl (\result saddr -> maybe result (:result) saddr) []) resolveNames
    updateActiveServers servers
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
    -- TODO: Should we kick out servers that are no longer in our active list but maybe still connected?
  where resolveNames = readTVarIO (node liferaft) >>= sequence . fmap getSockAddr . view getServerList
        updateActiveServers = atomically . writeTVar (activeServers liferaft)
        currentConnections = readTVarIO $ serverConnections liferaft
        connectTo = sequence . fmap tryConnect
        tryConnect saddr = newSocket >>= (\sock -> initConn saddr sock `catch` (\e -> putStrLn $ "Exception: " ++ show (e :: SomeException)) >> sClose sock)
        newSocket = socket AF_INET Stream defaultProtocol >>= \sock -> setSocketOption sock NoDelay 1 >> return sock
        initConn saddr sock = connect sock saddr >> identifyAsServer liferaft (saddr, sock) >>= \identified -> unless identified $ sClose sock

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
           ServerConnReq id -> addServerConnection liferaft (id, sock) >>= \x -> if x then acceptReq >> serverHandler liferaft conn else rejectReq >> sClose sock
           _ -> putStrLn "Received bad server handshake." >> sClose sock
        acceptReq = sendMsg liferaft sock ServerConnAccept
        rejectReq = sendMsg liferaft sock ServerConnReject

-- | Method actually handling logic for server requests
--
-- Generic handler function regardless of whether the server connected from or connected to.
--
serverHandler :: (Ser.Serialize a)
              => LifeRaft a b s m r
              -> (SockAddr, Socket)
              -> IO ()
serverHandler liferaft (saddr, sock) = do
  putStrLn "Handling! Immediately disconnecting... TODO"
  sClose sock
  removeServerConnection liferaft saddr

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
        handleResp res = case res of
           Nothing -> putStrLn "Could not deserialize response." >> return False
           Just v -> case v of
             ServerConnAccept -> addServerConnection liferaft conn >>= \x -> putStrLn "Connected to server" >> (forkIO $! serverHandler liferaft conn) >> return x
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

removeServerConnection :: LifeRaft a b s m r -> SockAddr -> IO ()
removeServerConnection liferaft saddr = atomically $ do
  connected <- readTVar $ serverConnections liferaft
  writeTVar (serverConnections liferaft) (filter ((/=saddr).fst) connected)

getActiveServers :: LifeRaft a b s m r -> IO [SockAddr]
getActiveServers liferaft = readTVarIO $ activeServers liferaft
