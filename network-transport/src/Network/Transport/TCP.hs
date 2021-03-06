-- | TCP implementation of the transport layer. 
-- 
-- The TCP implementation guarantees that only a single TCP connection (socket)
-- will be used between endpoints, provided that the addresses specified are
-- canonical. If /A/ connects to /B/ and reports its address as
-- @192.168.0.1:8080@ and /B/ subsequently connects tries to connect to /A/ as
-- @client1.local:http-alt@ then the transport layer will not realize that the
-- TCP connection can be reused. 
--
-- Applications that use the TCP transport should use
-- 'Network.Socket.withSocketsDo' in their main function for Windows
-- compatibility (see "Network.Socket").
module Network.Transport.TCP ( -- * Main API
                               createTransport
                               -- * Internals (exposed for unit tests) 
                             , createTransportExposeInternals 
                             , TransportInternals(..)
                             , EndPointId
                             , encodeEndPointAddress
                             , decodeEndPointAddress
                             , ControlHeader(..)
                             , ConnectionRequestResponse(..)
                             , firstNonReservedConnectionId
                             , socketToEndPoint 
                               -- * Design notes
                               -- $design
                             ) where

import Prelude hiding (catch, mapM_)
import Network.Transport
import Network.Transport.Internal.TCP ( forkServer
                                      , recvWithLength
                                      , recvInt32
                                      , tryCloseSocket
                                      )
import Network.Transport.Internal ( encodeInt32
                                  , decodeInt32
                                  , prependLength
                                  , mapIOException
                                  , tryIO
                                  , tryToEnum
                                  , void
                                  )
import qualified Network.Socket as N ( HostName
                                     , ServiceName
                                     , Socket
                                     , getAddrInfo
                                     , socket
                                     , addrFamily
                                     , addrAddress
                                     , SocketType(Stream)
                                     , defaultProtocol
                                     , setSocketOption
                                     , SocketOption(ReuseAddr) 
                                     , connect
                                     , sOMAXCONN
                                     , AddrInfo
                                     )
import Network.Socket.ByteString (sendMany)
import Control.Concurrent (forkIO, ThreadId, killThread, myThreadId)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar ( MVar
                               , newMVar
                               , modifyMVar
                               , modifyMVar_
                               , readMVar
                               , takeMVar
                               , putMVar
                               , newEmptyMVar
                               , withMVar
                               , tryPutMVar
                               )
import Control.Category ((>>>))
import Control.Applicative ((<$>))
import Control.Monad (when, unless)
import Control.Exception ( IOException
                         , SomeException
                         , handle
                         , throw
                         , throwIO
                         , try
                         , bracketOnError
                         , mask
                         , mask_
                         , onException
                         , fromException
                         )
import Data.IORef (IORef, newIORef, writeIORef, readIORef)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (concat)
import qualified Data.ByteString.Char8 as BSC (pack, unpack, split)
import Data.Int (Int32)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap (empty)
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet ( empty
                                       , insert
                                       , elems
                                       , singleton
                                       , null
                                       , delete
                                       , member
                                       )
import Data.Map (Map)
import qualified Data.Map as Map (empty)
import Data.Accessor (Accessor, accessor, (^.), (^=), (^:)) 
import qualified Data.Accessor.Container as DAC (mapMaybe, intMapMaybe)
import Data.Foldable (forM_, mapM_)
import Data.Maybe (isNothing)

-- $design 
--
-- [Goals]
--
-- The TCP transport maps multiple logical connections between /A/ and /B/ (in
-- either direction) to a single TCP connection:
--
-- > +-------+                          +-------+
-- > | A     |==========================| B     |
-- > |       |>~~~~~~~~~~~~~~~~~~~~~~~~~|~~~\   |
-- > |   Q   |>~~~~~~~~~~~~~~~~~~~~~~~~~|~~~Q   |
-- > |   \~~~|~~~~~~~~~~~~~~~~~~~~~~~~~<|       |
-- > |       |==========================|       |
-- > +-------+                          +-------+
-- 
-- Ignoring the complications detailed below, the TCP connection is set up is
-- when the first lightweight connection is created (in either direction), and
-- torn down when the last lightweight connection (in either direction) is
-- closed.
--
-- [Connecting]
--
-- Let /A/, /B/ be two endpoints without any connections. When /A/ wants to
-- connect to /B/, it locally records that it is trying to connect to /B/ and
-- sends a request to /B/. As part of the request /A/ sends its own endpoint
-- address to /B/ (so that /B/ can reuse the connection in the other direction).
--
-- When /B/ receives the connection request it first checks if it did not
-- already initiate a connection request to /A/. If not it will acknowledge the
-- connection request by sending 'ConnectionRequestAccepted' to /A/ and record
-- that it has a TCP connection to /A/.
--
-- The tricky case arises when /A/ sends a connection request to /B/ and /B/
-- finds that it had already sent a connection request to /A/. In this case /B/
-- will accept the connection request from /A/ if /A/s endpoint address is
-- smaller (lexicographically) than /B/s, and reject it otherwise. If it rejects
-- it, it sends a 'ConnectionRequestCrossed' message to /A/. (The
-- lexicographical ordering is an arbitrary but convenient way to break the
-- tie.)
--
-- When it receives a 'ConnectionRequestCrossed' message the /A/ thread that
-- initiated the request just needs to wait until the /A/ thread that is dealing
-- with /B/'s connection request completes.
--
-- [Disconnecting]
-- 
-- The TCP connection is created as soon as the first logical connection from
-- /A/ to /B/ (or /B/ to /A/) is established. At this point a thread (@#@) is
-- spawned that listens for incoming connections from /B/:
--
-- > +-------+                          +-------+
-- > | A     |==========================| B     |
-- > |       |>~~~~~~~~~~~~~~~~~~~~~~~~~|~~~\   |
-- > |       |                          |   Q   |
-- > |      #|                          |       |
-- > |       |==========================|       |
-- > +-------+                          +-------+
--
-- The question is when the TCP connection can be closed again.  Conceptually,
-- we want to do reference counting: when there are no logical connections left
-- between /A/ and /B/ we want to close the socket (possibly after some
-- timeout). 
--
-- However, /A/ and /B/ need to agree that the refcount has reached zero.  It
-- might happen that /B/ sends a connection request over the existing socket at
-- the same time that /A/ closes its logical connection to /B/ and closes the
-- socket. This will cause a failure in /B/ (which will have to retry) which is
-- not caused by a network failure, which is unfortunate. (Note that the
-- connection request from /B/ might succeed even if /A/ closes the socket.) 
--
-- Instead, when /A/ is ready to close the socket it sends a 'CloseSocket'
-- request to /B/ and records that its connection to /B/ is closing. If /A/
-- receives a new connection request from /B/ after having sent the
-- 'CloseSocket' request it simply forgets that it sent a 'CloseSocket' request
-- and increments the reference count of the connection again.
-- 
-- When /B/ receives a 'CloseSocket' message and it too is ready to close the
-- connection, it will respond with a reciprocal 'CloseSocket' request to /A/
-- and then actually close the socket. /A/ meanwhile will not send any more
-- requests to /B/ after having sent a 'CloseSocket' request, and will actually
-- close its end of the socket only when receiving the 'CloseSocket' message
-- from /B/. (Since /A/ recorded that its connection to /B/ is in closing state
-- after sending a 'CloseSocket' request to /B/, it knows not to reciprocate /B/
-- reciprocal 'CloseSocket' message.)
-- 
-- If there is a concurrent thread in /A/ waiting to connect to /B/ after /A/
-- has sent a 'CloseSocket' request then this thread will block until /A/ knows
-- whether to reuse the old socket (if /B/ sends a new connection request
-- instead of acknowledging the 'CloseSocket') or to set up a new socket. 

--------------------------------------------------------------------------------
-- Internal datatypes                                                         --
--------------------------------------------------------------------------------

-- We use underscores for fields that we might update (using accessores)
--
-- All data types follow the same structure:
-- 
-- * A top-level data type describing static properties (TCPTransport,
--   LocalEndPoint, RemoteEndPoint)
-- * The 'static' properties include an MVar containing a data structure for
--   the dynamic properties (TransportState, LocalEndPointState,
--   RemoteEndPointState). The state could be invalid/valid/closed,/etc.  
-- * For the case of "valid" we use third data structure to give more details
--   about the state (ValidTransportState, ValidLocalEndPointState,
--   ValidRemoteEndPointState).

data TCPTransport = TCPTransport 
  { transportHost  :: N.HostName
  , transportPort  :: N.ServiceName
  , transportState :: MVar TransportState 
  }

data TransportState = 
    TransportValid ValidTransportState
  | TransportClosed

data ValidTransportState = ValidTransportState 
  { _localEndPoints :: Map EndPointAddress LocalEndPoint 
  , _nextEndPointId :: EndPointId 
  }

data LocalEndPoint = LocalEndPoint
  { localAddress :: EndPointAddress
  , localChannel :: Chan Event
  , localState   :: MVar LocalEndPointState 
  }

data LocalEndPointState = 
    LocalEndPointValid ValidLocalEndPointState
  | LocalEndPointClosed

data ValidLocalEndPointState = ValidLocalEndPointState 
  { _nextConnectionId    :: !ConnectionId 
  , _pendingCtrlRequests :: IntMap (MVar [ByteString])
  , _nextCtrlRequestId   :: !ControlRequestId 
  , _localConnections    :: Map EndPointAddress RemoteEndPoint 
  , _internalThreads     :: [ThreadId]
  , _nextRemoteId        :: !Int
  }

-- REMOTE ENDPOINTS 
--
-- Remote endpoints (basically, TCP connections) have the following lifecycle:
--
--   Init ----+---> Invalid
--            |
--            |       /----------------\
--            |       |                |
--            |       v                |
--            +---> Valid ----+---> Closing
--            |               |        |
--            |               |        v 
--            \---------------+---> Closed
--
-- Init: There are two places where we create new remote endpoints: in
--   requestConnectionTo (in response to an API 'connect' call) and in
--   handleConnectionRequest (when a remote node tries to connect to us).
--   'Init' carries an MVar () 'resolved' which concurrent threads can use to
--   wait for the remote endpoint to finish initialization.
--
-- Invalid: We put the remote endpoint in invalid state only during
--   requestConnectionTo when we fail to connect.
--
-- Valid: This is the "normal" state for a working remote endpoint.
-- 
-- Closing: When we detect that a remote endpoint is no longer used, we send a
--   CloseSocket request across the connection and put the remote endpoint in
--   closing state. As with Init, 'Closing' carries an MVar () 'resolved' which
--   concurrent threads can use to wait for the remote endpoint to either be
--   closed fully (if the communication parnet responds with another
--   CloseSocket) or be put back in 'Valid' state if the remote endpoint denies
--   the request.
--
-- Closed: The endpoint is put in Closed state after a successful garbage
--   collection, when the endpoint (or the whole transport) is closed manually,
--   or when an IO exception occurs during communication.
--
-- Invariants for dealing with remote endpoints:
--
-- INV-SEND: Whenever we send data the remote endpoint must be locked (to avoid
--   interleaving bits of payload).
--
-- INV-CLOSE: Local endpoints should never point to remote endpoint in closed
--   state.  Whenever we put an endpoint in closed state we remove that
--   endpoint from localConnections first, so that if a concurrent thread reads
--   the MVar, finds RemoteEndPointClosed, and then looks up the endpoint in
--   localConnections it is guaranteed to either find a different remote
--   endpoint, or else none at all (if we don't insist in this order some
--   threads might start spinning).
-- 
-- INV-RESOLVE: We should only signal on 'resolved' while the remote endpoint is
--   locked, and the remote endpoint must be in Valid or Closed state once
--   unlocked. This guarantees that there will not be two threads attempting to
--   both signal on 'resolved'. 
--
-- INV-LOST: If a send or recv fails, or a socket is closed unexpectedly, we
--   first put the remote endpoint in Closed state, and then send a
--   EventConnectionLost event. This guarantees that we only send this event
--   once.  
--
-- INV-CLOSING: An endpoint in closing state is for all intents and purposes
--   closed; that is, we shouldn't do any 'send's on it (although 'recv' is
--   acceptable, of course -- as we are waiting for the remote endpoint to
--   confirm or deny the request).
--
-- INV-LOCK-ORDER: Remote endpoint must be locked before their local endpoints.
--   In other words: it is okay to call modifyMVar on a local endpoint inside a
--   modifyMVar on a remote endpoint, but not the other way around. In
--   particular, it is okay to call removeRemoteEndPoint inside
--   modifyRemoteState.

data RemoteEndPoint = RemoteEndPoint 
  { remoteAddress :: EndPointAddress
  , remoteState   :: MVar RemoteState
  , remoteId      :: Int
  }

data Origin = Local | Remote

data RemoteState =
    RemoteEndPointInvalid (TransportError ConnectErrorCode)
  | RemoteEndPointInit (MVar ()) Origin
  | RemoteEndPointValid ValidRemoteEndPointState 
  | RemoteEndPointClosing (MVar ()) ValidRemoteEndPointState
  | RemoteEndPointClosed

data ValidRemoteEndPointState = ValidRemoteEndPointState 
  { _remoteOutgoing :: !Int
  , _remoteIncoming :: IntSet
  ,  remoteSocket   :: N.Socket
  ,  sendOn         :: [ByteString] -> IO ()
  }

type EndPointId       = Int32
type ControlRequestId = Int32
type EndPointPair     = (LocalEndPoint, RemoteEndPoint)

-- | Control headers 
data ControlHeader = 
    -- | Request a new connection ID from the remote endpoint
    RequestConnectionId 
    -- | Tell the remote endpoint we will no longer be using a connection
  | CloseConnection     
    -- | Respond to a control request /from/ the remote endpoint
  | ControlResponse     
    -- | Request to close the connection (see module description)
  | CloseSocket         
  deriving (Enum, Bounded, Show)

-- Response sent by /B/ to /A/ when /A/ tries to connect
data ConnectionRequestResponse =
    -- | /B/ accepts the connection
    ConnectionRequestAccepted        
    -- | /A/ requested an invalid endpoint
  | ConnectionRequestInvalid 
    -- | /A/s request crossed with a request from /B/ (see protocols)
  | ConnectionRequestCrossed         
  deriving (Enum, Bounded, Show)

-- Internal functionality we expose for unit testing
data TransportInternals = TransportInternals 
  { -- | The ID of the thread that listens for new incoming connections
    transportThread :: ThreadId
    -- | Find the socket between a local and a remote endpoint
  , socketBetween :: EndPointAddress 
                  -> EndPointAddress 
                  -> IO N.Socket 
  }

--------------------------------------------------------------------------------
-- Top-level functionality                                                    --
--------------------------------------------------------------------------------

-- | Create a TCP transport
createTransport :: N.HostName 
                -> N.ServiceName 
                -> IO (Either IOException Transport)
createTransport host port = 
  either Left (Right . fst) <$> createTransportExposeInternals host port 

-- | You should probably not use this function (used for unit testing only)
createTransportExposeInternals 
  :: N.HostName 
  -> N.ServiceName 
  -> IO (Either IOException (Transport, TransportInternals)) 
createTransportExposeInternals host port = do 
    state <- newMVar . TransportValid $ ValidTransportState 
      { _localEndPoints = Map.empty 
      , _nextEndPointId = 0 
      }
    let transport = TCPTransport { transportState = state
                                 , transportHost  = host
                                 , transportPort  = port
                                 }
    tryIO $ do 
      tid <- forkServer host port N.sOMAXCONN 
               (terminationHandler transport) 
               (handleConnectionRequest transport) 
      return 
        ( Transport 
            { newEndPoint    = apiNewEndPoint transport 
            , closeTransport = let evs = [ EndPointClosed
                                         , throw $ userError "Transport closed"
                                         ] in
                               apiCloseTransport transport (Just tid) evs 
            } 
        , TransportInternals 
            { transportThread = tid
            , socketBetween   = internalSocketBetween transport
            }
        )
  where
    terminationHandler :: TCPTransport -> SomeException -> IO ()
    terminationHandler transport ex = do 
      let evs = [ ErrorEvent (TransportError EventTransportFailed (show ex))
                , throw $ userError "Transport closed" 
                ]
      apiCloseTransport transport Nothing evs 

--------------------------------------------------------------------------------
-- API functions                                                              --
--------------------------------------------------------------------------------

-- | Close the transport
apiCloseTransport :: TCPTransport -> Maybe ThreadId -> [Event] -> IO ()
apiCloseTransport transport mTransportThread evs = do 
  mTSt <- modifyMVar (transportState transport) $ \st -> case st of
    TransportValid vst -> return (TransportClosed, Just vst)
    TransportClosed    -> return (TransportClosed, Nothing)
  forM_ mTSt $ mapM_ (apiCloseEndPoint transport evs) . (^. localEndPoints) 
  -- This will invoke the termination handler, which in turn will call
  -- apiCloseTransport again, but then the transport will already be closed and
  -- we won't be passed a transport thread, so we terminate immmediate
  forM_ mTransportThread killThread 
     
-- | Create a new endpoint 
apiNewEndPoint :: TCPTransport 
               -> IO (Either (TransportError NewEndPointErrorCode) EndPoint)
apiNewEndPoint transport = try $ do
  ourEndPoint <- createLocalEndPoint transport
  return EndPoint 
    { receive       = readChan (localChannel ourEndPoint)
    , address       = localAddress ourEndPoint
    , connect       = apiConnect ourEndPoint 
    , closeEndPoint = let evs = [ EndPointClosed
                                , throw $ userError "Endpoint closed" 
                                ] in
                      apiCloseEndPoint transport evs ourEndPoint
    , newMulticastGroup     = return . Left $ newMulticastGroupError 
    , resolveMulticastGroup = return . Left . const resolveMulticastGroupError
    }
  where
    newMulticastGroupError = 
      TransportError NewMulticastGroupUnsupported "Multicast not supported" 
    resolveMulticastGroupError = 
      TransportError ResolveMulticastGroupUnsupported "Multicast not supported" 

-- | Connnect to an endpoint
apiConnect :: LocalEndPoint    -- ^ Local end point
           -> EndPointAddress  -- ^ Remote address
           -> Reliability      -- ^ Reliability (ignored)
           -> ConnectHints     -- ^ Hints (ignored for now)
           -> IO (Either (TransportError ConnectErrorCode) Connection)
apiConnect ourEndPoint theirAddress _reliability _hints = 
  if localAddress ourEndPoint == theirAddress 
    then connectToSelf ourEndPoint  
    else try $ do
      (theirEndPoint, connId) <- requestConnectionTo ourEndPoint theirAddress
      -- connAlive can be an IORef rather than an MVar because it is protected
      -- by the remoteState MVar. We don't need the overhead of locking twice.
      connAlive <- newIORef True
      return Connection 
        { send  = apiSend  (ourEndPoint, theirEndPoint) connId connAlive 
        , close = apiClose (ourEndPoint, theirEndPoint) connId connAlive 
        }

-- | Close a connection
apiClose :: EndPointPair -> ConnectionId -> IORef Bool -> IO ()
apiClose (ourEndPoint, theirEndPoint) connId connAlive = void . tryIO $ do 
  modifyRemoteState_ (ourEndPoint, theirEndPoint) remoteStateIdentity  
    { caseValid = \vst -> do
        alive <- readIORef connAlive
        if alive 
          then do
            writeIORef connAlive False
            sendOn vst [encodeInt32 CloseConnection, encodeInt32 connId] 
            return ( RemoteEndPointValid 
                   . (remoteOutgoing ^: (\x -> x - 1)) 
                   $ vst
                   )
          else
            return (RemoteEndPointValid vst)
    }
  closeIfUnused (ourEndPoint, theirEndPoint)

-- | Send data across a connection
apiSend :: EndPointPair  -- ^ Local and remote endpoint 
        -> ConnectionId  -- ^ Connection ID (supplied by remote endpoint)
        -> IORef Bool    -- ^ Is the connection still alive?
        -> [ByteString]  -- ^ Payload
        -> IO (Either (TransportError SendErrorCode) ())
apiSend (ourEndPoint, theirEndPoint) connId connAlive payload =  
    try . mapIOException sendFailed $ 
      withRemoteState (ourEndPoint, theirEndPoint) RemoteStatePatternMatch
        { caseInvalid = \_ -> 
            relyViolation (ourEndPoint, theirEndPoint) "apiSend"
        , caseInit = \_ _ ->
            relyViolation (ourEndPoint, theirEndPoint) "apiSend"
        , caseValid = \vst -> do
            alive <- readIORef connAlive
            if alive 
              then sendOn vst (encodeInt32 connId : prependLength payload)
              else throwIO $ TransportError SendClosed "Connection closed"
        , caseClosing = \_ _ -> do
            alive <- readIORef connAlive
            if alive 
              then throwIO $ TransportError SendFailed "Connection lost"
              else throwIO $ TransportError SendClosed "Connection closed"
        , caseClosed = do
            alive <- readIORef connAlive
            if alive 
              then throwIO $ TransportError SendFailed "Connection lost"
              else throwIO $ TransportError SendClosed "Connection closed"
        }
  where
    sendFailed = TransportError SendFailed . show

-- | Force-close the endpoint
apiCloseEndPoint :: TCPTransport    -- ^ Transport 
                 -> [Event]         -- ^ Events used to report closure 
                 -> LocalEndPoint   -- ^ Local endpoint
                 -> IO ()
apiCloseEndPoint transport evs ourEndPoint = do
  -- Remove the reference from the transport state
  removeLocalEndPoint transport ourEndPoint
  -- Close the local endpoint 
  mOurState <- modifyMVar (localState ourEndPoint) $ \st ->
    case st of
      LocalEndPointValid vst -> 
        return (LocalEndPointClosed, Just vst)
      LocalEndPointClosed ->
        return (LocalEndPointClosed, Nothing)
  forM_ mOurState $ \vst -> do
    -- Close all endpoints and kill all threads  
    forM_ (vst ^. localConnections) tryCloseRemoteSocket
    forM_ (vst ^. internalThreads) killThread
    forM_ evs $ writeChan (localChannel ourEndPoint) 
  where
    -- Close the remote socket and return the set of all incoming connections
    tryCloseRemoteSocket :: RemoteEndPoint -> IO () 
    tryCloseRemoteSocket theirEndPoint = 
      -- We make an attempt to close the connection nicely 
      -- (by sending a CloseSocket first)
      modifyMVar_ (remoteState theirEndPoint) $ \st ->
        case st of
          RemoteEndPointInvalid _ -> 
            return st
          RemoteEndPointInit resolved _ -> do
            putMVar resolved ()
            return RemoteEndPointClosed
          RemoteEndPointValid conn -> do 
            tryIO $ sendOn conn [encodeInt32 CloseSocket]
            tryCloseSocket (remoteSocket conn)
            return RemoteEndPointClosed
          RemoteEndPointClosing resolved conn -> do 
            putMVar resolved ()
            tryCloseSocket (remoteSocket conn)
            return RemoteEndPointClosed
          RemoteEndPointClosed ->
            return RemoteEndPointClosed

-- | Special case of 'apiConnect': connect an endpoint to itself
connectToSelf :: LocalEndPoint 
              -> IO (Either (TransportError ConnectErrorCode) Connection)
connectToSelf ourEndPoint = try . mapIOException connectFailed $ do  
    connAlive <- newIORef True  -- Protected by the local endpoint lock
    connId    <- getNextConnectionId ourEndPoint 
    writeChan ourChan $
      ConnectionOpened connId ReliableOrdered (localAddress ourEndPoint)
    return Connection 
      { send  = selfSend connAlive connId 
      , close = selfClose connAlive connId
      }
  where
    selfSend :: IORef Bool 
             -> ConnectionId 
             -> [ByteString] 
             -> IO (Either (TransportError SendErrorCode) ())
    selfSend connAlive connId msg = 
      try . withMVar ourState $ \st -> case st of
        LocalEndPointValid _ -> do
          alive <- readIORef connAlive
          if alive
            then writeChan ourChan (Received connId msg)
            else throwIO $ TransportError SendClosed "Connection closed"
        LocalEndPointClosed ->
          throwIO $ TransportError SendFailed "Endpoint closed"

    selfClose :: IORef Bool -> ConnectionId -> IO ()
    selfClose connAlive connId = 
      withMVar ourState $ \st -> case st of
        LocalEndPointValid _ -> do
          alive <- readIORef connAlive
          when alive $ do
            writeChan ourChan (ConnectionClosed connId) 
            writeIORef connAlive False
        LocalEndPointClosed ->
          return () 

    ourChan  = localChannel ourEndPoint
    ourState = localState ourEndPoint
    connectFailed = TransportError ConnectFailed . show 

--------------------------------------------------------------------------------
-- Functions from TransportInternals                                          --
--------------------------------------------------------------------------------

-- Find a socket between two endpoints
-- 
-- Throws an IO exception if the socket could not be found.
internalSocketBetween :: TCPTransport    -- ^ Transport 
                      -> EndPointAddress -- ^ Local endpoint
                      -> EndPointAddress -- ^ Remote endpoint
                      -> IO N.Socket 
internalSocketBetween transport ourAddress theirAddress = do
  ourEndPoint <- withMVar (transportState transport) $ \st -> case st of
      TransportClosed -> 
        throwIO $ userError "Transport closed" 
      TransportValid vst -> 
        case vst ^. localEndPointAt ourAddress of
          Nothing -> throwIO $ userError "Local endpoint not found"
          Just ep -> return ep
  theirEndPoint <- withMVar (localState ourEndPoint) $ \st -> case st of
      LocalEndPointClosed ->
        throwIO $ userError "Local endpoint closed"
      LocalEndPointValid vst -> 
        case vst ^. localConnectionTo theirAddress of
          Nothing -> throwIO $ userError "Remote endpoint not found"
          Just ep -> return ep
  withMVar (remoteState theirEndPoint) $ \st -> case st of
    RemoteEndPointInit _ _ ->
      throwIO $ userError "Remote endpoint not yet initialized"
    RemoteEndPointValid vst -> 
      return $ remoteSocket vst
    RemoteEndPointClosing _ vst ->
      return $ remoteSocket vst 
    RemoteEndPointClosed ->
      throwIO $ userError "Remote endpoint closed"
    RemoteEndPointInvalid _ ->
      throwIO $ userError "Remote endpoint invalid"

--------------------------------------------------------------------------------
-- Lower level functionality                                                  --
--------------------------------------------------------------------------------

-- | Create a new local endpoint
-- 
-- May throw a TransportError NewEndPointErrorCode exception if the transport
-- is closed.
createLocalEndPoint :: TCPTransport -> IO LocalEndPoint
createLocalEndPoint transport = do 
    chan  <- newChan
    state <- newMVar . LocalEndPointValid $ ValidLocalEndPointState 
      { _nextConnectionId    = firstNonReservedConnectionId 
      , _pendingCtrlRequests = IntMap.empty
      , _nextCtrlRequestId   = 0
      , _localConnections    = Map.empty
      , _internalThreads     = []
      , _nextRemoteId        = 0
      }
    modifyMVar (transportState transport) $ \st -> case st of
      TransportValid vst -> do
        let ix   = vst ^. nextEndPointId
        let addr = encodeEndPointAddress (transportHost transport) 
                                         (transportPort transport)
                                         ix 
        let localEndPoint = LocalEndPoint { localAddress  = addr
                                          , localChannel  = chan
                                          , localState    = state
                                          }
        return ( TransportValid 
               . (localEndPointAt addr ^= Just localEndPoint) 
               . (nextEndPointId ^= ix + 1) 
               $ vst
               , localEndPoint
               )
      TransportClosed ->
        throwIO (TransportError NewEndPointFailed "Transport closed")

-- | Request a connection to a remote endpoint
--
-- This will block until we get a connection ID from the remote endpoint; if
-- the remote endpoint was in 'RemoteEndPointClosing' state then we will
-- additionally block until that is resolved. 
--
-- May throw a TransportError ConnectErrorCode exception.
requestConnectionTo :: LocalEndPoint 
                    -> EndPointAddress 
                    -> IO (RemoteEndPoint, ConnectionId)
requestConnectionTo ourEndPoint theirAddress = do
    (theirEndPoint, isNew) <- mapIOException connectFailed $
      findRemoteEndPoint ourEndPoint theirAddress Local 

    -- If this is a new endpoint, start the initialization process and wait
    forM_ isNew $ \resolved -> do
      void . forkEndPointThread ourEndPoint $ do
        let outgoing = 1 
        setupRemoteEndPoint (ourEndPoint, theirEndPoint) outgoing 
      readMVar resolved

    reply <- mapIOException connectFailed $ 
      doRemoteRequest (ourEndPoint, theirEndPoint) RequestConnectionId 
    return (theirEndPoint, decodeInt32 . BS.concat $ reply)
  where
    connectFailed = TransportError ConnectFailed . show

-- | Set up a remote endpoint
setupRemoteEndPoint :: EndPointPair -- ^ Local endpoint, remote endpoint 
                    -> Int          -- ^ Initial (outgoing) refcount
                    -> IO ()
setupRemoteEndPoint (ourEndPoint, theirEndPoint) outgoing = do
    didAccept <- bracketOnError (socketToEndPoint ourAddress theirAddress)
                                onError $ \result ->
      case result of
        Right (sock, ConnectionRequestAccepted) -> do 
          let vst = ValidRemoteEndPointState 
                      {  remoteSocket   = sock
                      , _remoteOutgoing = outgoing 
                      , _remoteIncoming = IntSet.empty
                      ,  sendOn         = sendMany sock 
                      }
          resolveInit (ourEndPoint, theirEndPoint) (RemoteEndPointValid vst)
          return True
        Right (sock, ConnectionRequestInvalid) -> do
          -- We remove the endpoint from our local state again because the next
          -- call to 'connect' might give a different result. Threads that were
          -- waiting on the result of this call to connect will get the
          -- RemoteEndPointInvalid; subsequent threads will initiate a new
          -- connection requests. 
          removeRemoteEndPoint (ourEndPoint, theirEndPoint)
          let err = invalidAddress "Invalid endpoint"
          resolveInit (ourEndPoint, theirEndPoint) (RemoteEndPointInvalid err)
          tryCloseSocket sock
          return False
        Right (sock, ConnectionRequestCrossed) -> do
          -- We leave the endpoint in Init state, handleConnectionRequest will
          -- take care of it
          tryCloseSocket sock
          return False
        Left err -> do 
          removeRemoteEndPoint (ourEndPoint, theirEndPoint) -- See comment above 
          resolveInit (ourEndPoint, theirEndPoint) (RemoteEndPointInvalid err)
          return False
   
    -- If we get to this point without an exception, then
    --
    -- if didAccept is False the socket has already been closed
    -- if didAccept is True, the socket has been stored as part of the remote
    --   state so we no longer need to worry about closing it when an
    --   asynchronous exception occurs
    when didAccept $ handleIncomingMessages (ourEndPoint, theirEndPoint)
  where
    -- If an asynchronous exception occurs while we set up the remote endpoint
    -- we need to make sure to close the socket. It is also useful to
    -- initialize the remote state (to "invalid") so that concurrent threads
    -- that are blocked on reading the remote state are unblocked. It is
    -- possible, however, that the exception occurred after we already
    -- initialized the remote state, which is why we use tryPutMVar here.
    onError :: Either (TransportError ConnectErrorCode) 
                      (N.Socket, ConnectionRequestResponse)
            -> IO ()
    onError result = do
      removeRemoteEndPoint (ourEndPoint, theirEndPoint)
      case result of
        Left err -> 
          void $ tryPutMVar theirState (RemoteEndPointInvalid err)
        Right (sock, _) -> do
          let err = failed "setupRemoteEndPoint failed"
          tryPutMVar theirState (RemoteEndPointInvalid err)
          tryCloseSocket sock

    failed          = TransportError ConnectFailed 
    ourAddress      = localAddress ourEndPoint
    theirAddress    = remoteAddress theirEndPoint
    theirState      = remoteState theirEndPoint
    invalidAddress  = TransportError ConnectNotFound

resolveInit :: EndPointPair -> RemoteState -> IO ()
resolveInit (ourEndPoint, theirEndPoint) newState = 
   modifyMVar_ (remoteState theirEndPoint) $ \st -> case st of
    RemoteEndPointInvalid _ ->
      relyViolation (ourEndPoint, theirEndPoint) "resolveInit (invalid)" 
    RemoteEndPointInit resolved _ -> do
      putMVar resolved ()
      return newState
    RemoteEndPointClosed ->
      throwIO $ userError "Remote endpoint closed"
    RemoteEndPointClosing _ _ ->
      relyViolation (ourEndPoint, theirEndPoint) "resolveInit (closing)"
    RemoteEndPointValid _ ->
      relyViolation (ourEndPoint, theirEndPoint) "resolveInit (valid)"
  
-- | Establish a connection to a remote endpoint
socketToEndPoint :: EndPointAddress -- ^ Our address 
                 -> EndPointAddress -- ^ Their address
                 -> IO (Either (TransportError ConnectErrorCode) 
                               (N.Socket, ConnectionRequestResponse)) 
socketToEndPoint (EndPointAddress ourAddress) theirAddress = try $ do 
    (host, port, theirEndPointId) <- case decodeEndPointAddress theirAddress of 
      Nothing  -> throwIO (failed . userError $ "Could not parse")
      Just dec -> return dec
    addr:_ <- mapIOException invalidAddress $ 
      N.getAddrInfo Nothing (Just host) (Just port)
    bracketOnError (createSocket addr) tryCloseSocket $ \sock -> do
      mapIOException failed $ N.setSocketOption sock N.ReuseAddr 1
      mapIOException invalidAddress $ N.connect sock (N.addrAddress addr) 
      response <- mapIOException failed $ do
        sendMany sock (encodeInt32 theirEndPointId : prependLength [ourAddress]) 
        recvInt32 sock
      case tryToEnum response of
        Nothing -> throwIO (failed . userError $ "Unexpected response")
        Just r  -> return (sock, r)
  where
    createSocket :: N.AddrInfo -> IO N.Socket
    createSocket addr = mapIOException insufficientResources $ 
      N.socket (N.addrFamily addr) N.Stream N.defaultProtocol

    invalidAddress        = TransportError ConnectNotFound . show 
    insufficientResources = TransportError ConnectInsufficientResources . show 
    failed                = TransportError ConnectFailed . show

-- | Remove reference to a remote endpoint from a local endpoint
--
-- If the local endpoint is closed, do nothing
removeRemoteEndPoint :: EndPointPair -> IO ()
removeRemoteEndPoint (ourEndPoint, theirEndPoint) =
    modifyMVar_ ourState $ \st -> case st of
      LocalEndPointValid vst ->
        case vst ^. localConnectionTo theirAddress of
          Nothing -> 
            return st
          Just remoteEndPoint' ->
            if remoteId remoteEndPoint' == remoteId theirEndPoint 
              then return 
                ( LocalEndPointValid 
                . (localConnectionTo (remoteAddress theirEndPoint) ^= Nothing) 
                $ vst
                )
              else return st
      LocalEndPointClosed ->
        return LocalEndPointClosed
  where
    ourState     = localState ourEndPoint
    theirAddress = remoteAddress theirEndPoint

-- | Remove reference to a local endpoint from the transport state
--
-- Does nothing if the transport is closed
removeLocalEndPoint :: TCPTransport -> LocalEndPoint -> IO ()
removeLocalEndPoint transport ourEndPoint = 
  modifyMVar_ (transportState transport) $ \st -> case st of 
    TransportValid vst ->
      return ( TransportValid 
             . (localEndPointAt (localAddress ourEndPoint) ^= Nothing) 
             $ vst
             )
    TransportClosed ->
      return TransportClosed

-- | Encode end point address
encodeEndPointAddress :: N.HostName 
                      -> N.ServiceName 
                      -> EndPointId 
                      -> EndPointAddress
encodeEndPointAddress host port ix = EndPointAddress . BSC.pack $
  host ++ ":" ++ port ++ ":" ++ show ix 

-- | Decode end point address
decodeEndPointAddress :: EndPointAddress 
                      -> Maybe (N.HostName, N.ServiceName, EndPointId)
decodeEndPointAddress (EndPointAddress bs) = 
  case map BSC.unpack $ BSC.split ':' bs of
    [host, port, endPointIdStr] -> 
      case reads endPointIdStr of 
        [(endPointId, "")] -> Just (host, port, endPointId)
        _                  -> Nothing
    _ ->
      Nothing

-- | Do a (blocking) remote request 
-- 
-- May throw IO (user) exception if the local or the remote endpoint is closed,
-- or if the send fails.
doRemoteRequest :: EndPointPair -> ControlHeader -> IO [ByteString]
doRemoteRequest (ourEndPoint, theirEndPoint) header = do 
  reply <- newEmptyMVar
  reqId <- modifyMVar (localState ourEndPoint) $ \st -> case st of
    LocalEndPointValid vst -> do
      let reqId = vst ^. nextCtrlRequestId
      return ( LocalEndPointValid 
             . (nextCtrlRequestId ^: (+ 1)) 
             . (pendingCtrlRequestsAt reqId ^= Just reply) 
             $ vst
             , reqId
             )
    LocalEndPointClosed ->
      throwIO (userError "Local endpoint closed")
  withRemoteState (ourEndPoint, theirEndPoint) RemoteStatePatternMatch 
    { caseInvalid = throwIO 
    , caseInit    = \_ _ -> relyViolation (ourEndPoint, theirEndPoint) "doRemoteRequest (init)"
    , caseValid   = \vst -> sendOn vst [encodeInt32 header, encodeInt32 reqId]
    , caseClosing = \_ _ -> relyViolation (ourEndPoint, theirEndPoint) "doRemoteRequest (closing)" 
    , caseClosed  = throwIO $ userError "Remote endpoint closed"
    }
  takeMVar reply 

-- | Send a CloseSocket request if the remote endpoint is unused
closeIfUnused :: EndPointPair -> IO ()
closeIfUnused (ourEndPoint, theirEndPoint) =
  modifyRemoteState_ (ourEndPoint, theirEndPoint) remoteStateIdentity 
    { caseValid = \vst -> 
        if vst ^. remoteOutgoing == 0 && IntSet.null (vst ^. remoteIncoming) 
          then do 
            sendOn vst [encodeInt32 CloseSocket]
            resolved <- newEmptyMVar
            return $ RemoteEndPointClosing resolved vst 
          else 
            return $ RemoteEndPointValid vst
    }

-- | Fork a new thread and store its ID as part of the transport state
-- 
-- If the local end point is closed this function does nothing (no thread is
-- spawned). Returns whether or not a thread was spawned.
forkEndPointThread :: LocalEndPoint -> IO () -> IO Bool 
forkEndPointThread ourEndPoint p = 
    -- We use an explicit mask_ because we don't want to be interrupted until
    -- we have registered the thread. In particular, modifyMVar is not good
    -- enough because if we get an asynchronous exception after the fork but
    -- before the argument to modifyMVar returns we don't want to simply put
    -- the old value of the mvar back.
    mask_ $ do
      st <- takeMVar ourState
      case st of
        LocalEndPointValid vst -> do
          threadRegistered <- newEmptyMVar
          tid <- forkIO (takeMVar threadRegistered >> p >> removeThread) 
          putMVar ourState ( LocalEndPointValid 
                           . (internalThreads ^: (tid :))
                           $ vst
                           )
          putMVar threadRegistered ()
          return True
        LocalEndPointClosed -> do
          putMVar ourState st
          return False 
  where
    removeThread :: IO ()
    removeThread = do
      tid <- myThreadId
      modifyMVar_ ourState $ \st -> case st of
        LocalEndPointValid vst ->
          return ( LocalEndPointValid 
                 . (internalThreads ^: filter (/= tid)) 
                 $ vst
                 )
        LocalEndPointClosed ->
          return LocalEndPointClosed

    ourState :: MVar LocalEndPointState
    ourState = localState ourEndPoint

--------------------------------------------------------------------------------
-- As soon as a remote connection fails, we want to put notify our endpoint   -- 
-- and put it into a closed state. Since this may happen in many places, we   --
-- provide some abstractions.                                                 --
--------------------------------------------------------------------------------

data RemoteStatePatternMatch a = RemoteStatePatternMatch 
  { caseInvalid :: TransportError ConnectErrorCode -> IO a
  , caseInit    :: MVar () -> Origin -> IO a
  , caseValid   :: ValidRemoteEndPointState -> IO a
  , caseClosing :: MVar () -> ValidRemoteEndPointState -> IO a
  , caseClosed  :: IO a
  }

remoteStateIdentity :: RemoteStatePatternMatch RemoteState
remoteStateIdentity =
  RemoteStatePatternMatch 
    { caseInvalid = return . RemoteEndPointInvalid
    , caseInit    = (return .) . RemoteEndPointInit
    , caseValid   = return . RemoteEndPointValid
    , caseClosing = (return .) . RemoteEndPointClosing 
    , caseClosed  = return RemoteEndPointClosed
    }

-- | Like modifyMVar, but if an I/O exception occurs don't restore the remote
-- endpoint to its original value but close it instead 
modifyRemoteState :: EndPointPair 
                  -> RemoteStatePatternMatch (RemoteState, a) 
                  -> IO a
modifyRemoteState (ourEndPoint, theirEndPoint) match = 
    mask $ \restore -> do
      st <- takeMVar theirState
      case st of
        RemoteEndPointValid vst -> do
          mResult <- try $ restore (caseValid match vst) 
          case mResult of
            Right (st', a) -> do
              putMVar theirState st'
              return a
            Left ex -> do
              case fromException ex of
                Just ioEx -> handleIOException ioEx vst 
                Nothing   -> putMVar theirState st 
              throwIO ex
        -- The other cases are less interesting, because unless the endpoint is
        -- in Valid state we're not supposed to do any IO on it
        RemoteEndPointInit resolved origin -> do
          (st', a) <- onException (restore $ caseInit match resolved origin)
                                  (putMVar theirState st)
          putMVar theirState st'
          return a
        RemoteEndPointClosing resolved vst -> do 
          (st', a) <- onException (restore $ caseClosing match resolved vst)
                                  (putMVar theirState st)
          putMVar theirState st'
          return a
        RemoteEndPointInvalid err -> do
          (st', a) <- onException (restore $ caseInvalid match err)
                                  (putMVar theirState st)
          putMVar theirState st'
          return a
        RemoteEndPointClosed -> do
          (st', a) <- onException (restore $ caseClosed match)
                                  (putMVar theirState st)
          putMVar theirState st'
          return a
  where
    theirState :: MVar RemoteState
    theirState = remoteState theirEndPoint

    handleIOException :: IOException -> ValidRemoteEndPointState -> IO () 
    handleIOException ex vst = do
      tryCloseSocket (remoteSocket vst)
      removeRemoteEndPoint (ourEndPoint, theirEndPoint)
      putMVar theirState RemoteEndPointClosed
      let incoming = IntSet.elems $ vst ^. remoteIncoming
          code     = EventConnectionLost (remoteAddress theirEndPoint) incoming
          err      = TransportError code (show ex)
      writeChan (localChannel ourEndPoint) $ ErrorEvent err 

-- | Like 'modifyRemoteState' but without a return value
modifyRemoteState_ :: EndPointPair
                   -> RemoteStatePatternMatch RemoteState 
                   -> IO ()
modifyRemoteState_ (ourEndPoint, theirEndPoint) match =
    modifyRemoteState (ourEndPoint, theirEndPoint) 
      RemoteStatePatternMatch 
        { caseInvalid = u . caseInvalid match
        , caseInit    = \resolved origin -> u $ caseInit match resolved origin
        , caseValid   = u . caseValid match
        , caseClosing = \resolved vst -> u $ caseClosing match resolved vst
        , caseClosed  = u $ caseClosed match
        }
  where
    u :: IO a -> IO (a, ())
    u p = p >>= \a -> return (a, ())

-- | Like 'modifyRemoteState' but without the ability to change the state
withRemoteState :: EndPointPair
                -> RemoteStatePatternMatch a
                -> IO a 
withRemoteState (ourEndPoint, theirEndPoint) match =
  modifyRemoteState (ourEndPoint, theirEndPoint)
    RemoteStatePatternMatch 
      { caseInvalid = \err -> do
          a <- caseInvalid match err
          return (RemoteEndPointInvalid err, a)
      , caseInit = \resolved origin -> do
          a <- caseInit match resolved origin
          return (RemoteEndPointInit resolved origin, a)
      , caseValid = \vst -> do
          a <- caseValid match vst
          return (RemoteEndPointValid vst, a)
      , caseClosing = \resolved vst -> do 
          a <- caseClosing match resolved vst
          return (RemoteEndPointClosing resolved vst, a)
      , caseClosed = do 
          a <- caseClosed match
          return (RemoteEndPointClosed, a)
      }

--------------------------------------------------------------------------------
-- Incoming requests                                                          --
--------------------------------------------------------------------------------

-- | Handle a connection request (that is, a remote endpoint that is trying to
-- establish a TCP connection with us)
--
-- 'handleConnectionRequest' runs in the context of the transport thread, which
-- can be killed asynchronously by 'closeTransport'. We fork a separate thread
-- as soon as we have located the lcoal endpoint that the remote endpoint is
-- interested in. We cannot fork any sooner because then we have no way of
-- storing the thread ID and hence no way of killing the thread when we take
-- the transport down. We must be careful to close the socket when a (possibly
-- asynchronous, ThreadKilled) exception occurs. (If an exception escapes from
-- handleConnectionRequest the transport will be shut down.)
handleConnectionRequest :: TCPTransport -> N.Socket -> IO () 
handleConnectionRequest transport sock = handle handleException $ do 
    ourEndPointId <- recvInt32 sock
    theirAddress  <- EndPointAddress . BS.concat <$> recvWithLength sock 
    let ourAddress = encodeEndPointAddress (transportHost transport) 
                                           (transportPort transport)
                                           ourEndPointId
    ourEndPoint <- withMVar (transportState transport) $ \st -> case st of
      TransportValid vst ->
        case vst ^. localEndPointAt ourAddress of
          Nothing -> do
            sendMany sock [encodeInt32 ConnectionRequestInvalid]
            throwIO $ userError "Invalid endpoint"
          Just ourEndPoint ->
            return ourEndPoint
      TransportClosed -> 
        throwIO $ userError "Transport closed"
    void . forkEndPointThread ourEndPoint $ go ourEndPoint theirAddress
  where
    go :: LocalEndPoint -> EndPointAddress -> IO ()
    go ourEndPoint theirAddress = do 
      mEndPoint <- handle ((>> return Nothing) . invalidEndPoint) $ do 
        (theirEndPoint, isNew) <- 
          findRemoteEndPoint ourEndPoint theirAddress Remote

        let ourAddress = localAddress ourEndPoint
            crossed    = isNothing isNew && ourAddress < theirAddress

        if crossed 
          then do
            tryIO $ sendMany sock [encodeInt32 ConnectionRequestCrossed]
            tryCloseSocket sock
            return Nothing 
          else do
            let vst = ValidRemoteEndPointState 
                        {  remoteSocket   = sock
                        , _remoteOutgoing = 0
                        , _remoteIncoming = IntSet.empty
                        , sendOn          = sendMany sock
                        }
            sendMany sock [encodeInt32 ConnectionRequestAccepted]
            resolveInit (ourEndPoint, theirEndPoint) (RemoteEndPointValid vst)
            return (Just theirEndPoint)
      -- If we left the scope of the exception handler with a return value of
      -- Nothing then the socket is already closed; otherwise, the socket has
      -- been recorded as part of the remote endpoint. Either way, we no longer
      -- have to worry about closing the socket on receiving an asynchronous
      -- exception from this point forward. 
      forM_ mEndPoint $ handleIncomingMessages . (,) ourEndPoint

    handleException :: IOException -> IO ()
    handleException _ = tryCloseSocket sock 

    invalidEndPoint :: IOException -> IO () 
    invalidEndPoint _ = do
      tryIO $ sendMany sock [encodeInt32 ConnectionRequestInvalid]
      tryCloseSocket sock 

-- | Find a remote endpoint. If the remote endpoint does not yet exist we
-- create it in Init state and return the corresponding 'resolved' MVar.
findRemoteEndPoint 
  :: LocalEndPoint
  -> EndPointAddress
  -> Origin 
  -> IO (RemoteEndPoint, Maybe (MVar ())) 
findRemoteEndPoint ourEndPoint theirAddress findOrigin = go
  where
    go = do
      (theirEndPoint, isNew) <- modifyMVar ourState $ \st -> case st of
        LocalEndPointValid vst -> case vst ^. localConnectionTo theirAddress of
          Just theirEndPoint ->
            return (st, (theirEndPoint, Nothing))
          Nothing -> do
            resolved <- newEmptyMVar
            theirState <- newMVar (RemoteEndPointInit resolved findOrigin)
            let theirEndPoint = RemoteEndPoint
                                  { remoteAddress = theirAddress
                                  , remoteState   = theirState
                                  , remoteId      = vst ^. nextRemoteId
                                  }
            return ( LocalEndPointValid 
                   . (localConnectionTo theirAddress ^= Just theirEndPoint) 
                   . (nextRemoteId ^: (+ 1)) 
                   $ vst
                   , (theirEndPoint, Just resolved)
                   )
        LocalEndPointClosed ->
          throwIO $ userError "Local endpoint closed"

      case isNew of
        Just resolved -> 
          return (theirEndPoint, Just resolved)
        Nothing -> do
          let theirState = remoteState theirEndPoint
          snapshot <- modifyMVar theirState $ \st -> case st of
            RemoteEndPointValid vst -> 
              case findOrigin of
                Local -> do
                  let st' = RemoteEndPointValid 
                          . (remoteOutgoing ^: (+ 1)) 
                          $ vst 
                  return (st', st')
                Remote ->
                  throwIO $ userError "Already connected" 
            _ ->
              return (st, st)
          -- The snapshot may no longer be up to date at this point, but if we
          -- increased the refcount then it can only either be valid or closed
          -- (after an explicit call to 'closeEndPoint' or 'closeTransport') 
          case snapshot of
            RemoteEndPointInvalid err ->
              throwIO err
            RemoteEndPointInit resolved initOrigin ->
              case (findOrigin, initOrigin) of
                (Local, Local)   -> readMVar resolved >> go 
                (Local, Remote)  -> readMVar resolved >> go
                (Remote, Local)  -> return (theirEndPoint, Nothing)
                (Remote, Remote) -> throwIO $ userError "Already connected"
            RemoteEndPointValid _ ->
              return (theirEndPoint, Nothing)
            RemoteEndPointClosing resolved _ ->
              readMVar resolved >> go
            RemoteEndPointClosed ->
              go
          
    ourState = localState ourEndPoint 

-- | Handle requests from a remote endpoint.
-- 
-- Returns only if the remote party closes the socket or if an error occurs.
handleIncomingMessages :: EndPointPair -> IO () 
handleIncomingMessages (ourEndPoint, theirEndPoint) = do
    mSock <- withMVar theirState $ \st ->
      case st of
        RemoteEndPointInvalid _ ->
          relyViolation (ourEndPoint, theirEndPoint) "handleIncomingMessages" 
        RemoteEndPointInit _ _ ->
          relyViolation (ourEndPoint, theirEndPoint) "handleIncomingMessages"
        RemoteEndPointValid ep ->
          return . Just $ remoteSocket ep
        RemoteEndPointClosing _ ep ->
          return . Just $ remoteSocket ep
        RemoteEndPointClosed ->
          -- The remote endpoint got closed before we got a chance to start
          -- dealing with incoming messages
          return Nothing
    
    forM_ mSock $ \sock -> 
      tryIO (go sock) >>= either (prematureExit sock) return
  where
    -- Dispatch 
    --
    -- If a recv throws an exception this will be caught top-level and
    -- 'prematureExit' will be invoked. The same will happen if the remote
    -- endpoint is put into a Closed (or Closing) state by a concurrent thread
    -- (because a 'send' failed) -- the individual handlers below will throw a
    -- user exception which is then caught and handled the same way as an
    -- exception thrown by 'recv'.
    --
    -- Note: modifyRemoteState closes the socket before putting the remote
    -- endpoint in closing state, so it is not possible that modifyRemoteState
    -- puts the remote endpoint in Closing state only for it to be reset to
    -- Valid by the RequestConnectionId handler below.
    go :: N.Socket -> IO ()
    go sock = do
      connId <- recvInt32 sock 
      if connId >= firstNonReservedConnectionId 
        then do
          readMessage sock connId
          go sock
        else 
          case tryToEnum (fromIntegral connId) of
            Just RequestConnectionId -> do
              recvInt32 sock >>= createNewConnection 
              go sock 
            Just ControlResponse -> do 
              recvInt32 sock >>= readControlResponse sock 
              go sock
            Just CloseConnection -> do
              recvInt32 sock >>= closeConnection 
              go sock
            Just CloseSocket -> do 
              didClose <- closeSocket sock 
              unless didClose $ go sock
            Nothing ->
              throwIO $ userError "Invalid control request"
        
    -- Create a new connection
    createNewConnection :: ControlRequestId -> IO () 
    createNewConnection reqId = do 
      -- getNextConnectionId throws an exception if ourEndPoint is closed; but
      -- if this endpoint is closed, this thread will soon die anyway
      newId <- getNextConnectionId ourEndPoint
      modifyMVar_ theirState $ \st -> do
        vst <- case st of
          RemoteEndPointInvalid _ ->
            relyViolation (ourEndPoint, theirEndPoint) "handleIncomingMessages:createNewConnection"
          RemoteEndPointInit _ _ ->
            relyViolation (ourEndPoint, theirEndPoint) "handleIncomingMessages:createNewConnection"
          RemoteEndPointValid vst ->
            return (remoteIncoming ^: IntSet.insert newId $ vst)
          RemoteEndPointClosing resolved vst -> do
            -- If the endpoint is in closing state that means we send a
            -- CloseSocket request to the remote endpoint. If the remote
            -- endpoint replies with the request to create a new connection, it
            -- either ignored our request or it sent the request before it got
            -- ours.  Either way, at this point we simply restore the endpoint
            -- to RemoteEndPointValid
            putMVar resolved ()
            return (remoteIncoming ^= IntSet.singleton newId $ vst)
          RemoteEndPointClosed -> 
            throwIO $ userError "Remote endpoint closed"
        sendOn vst ( encodeInt32 ControlResponse 
                   : encodeInt32 reqId 
                   : prependLength [encodeInt32 newId] 
                   )
        -- We add the new connection ID to the list of open connections only
        -- once the endpoint has been notified of the new connection (sendOn
        -- may fail)
        return (RemoteEndPointValid vst)
      writeChan ourChannel (ConnectionOpened newId ReliableOrdered theirAddr) 

    -- Read a control response 
    readControlResponse :: N.Socket -> ControlRequestId -> IO () 
    readControlResponse sock reqId = do
      response <- recvWithLength sock
      mmvar    <- modifyMVar ourState $ \st -> case st of
        LocalEndPointValid vst ->
          return ( LocalEndPointValid 
                 . (pendingCtrlRequestsAt reqId ^= Nothing) 
                 $ vst
                 , vst ^. pendingCtrlRequestsAt reqId
                 )
        LocalEndPointClosed ->
          throwIO $ userError "Local endpoint closed"
      case mmvar of
        Nothing -> 
          throwIO $ userError "Invalid request ID"
        Just mvar -> 
          putMVar mvar response

    -- Close a connection 
    -- It is important that we verify that the connection is in fact open,
    -- because otherwise we should not decrement the reference count
    closeConnection :: ConnectionId -> IO () 
    closeConnection cid = do
      modifyMVar_ theirState $ \st -> case st of
        RemoteEndPointInvalid _ ->
          relyViolation (ourEndPoint, theirEndPoint) "closeConnection"
        RemoteEndPointInit _ _ ->
          relyViolation (ourEndPoint, theirEndPoint) "closeConnection"
        RemoteEndPointValid vst -> do 
          unless (IntSet.member cid (vst ^. remoteIncoming)) $ 
            throwIO $ userError "Invalid CloseConnection"
          return ( RemoteEndPointValid 
                 . (remoteIncoming ^: IntSet.delete cid) 
                 $ vst
                 )
        RemoteEndPointClosing _ _ ->
          -- If the remote endpoint is in Closing state, that means that are as
          -- far as we are concerned there are no incoming connections. This
          -- means that a CloseConnection request at this point is invalid.
          throwIO $ userError "Invalid CloseConnection request" 
        RemoteEndPointClosed ->
          throwIO $ userError "Remote endpoint closed"
      writeChan ourChannel (ConnectionClosed cid)
      closeIfUnused (ourEndPoint, theirEndPoint)

    -- Close the socket (if we don't have any outgoing connections)
    closeSocket :: N.Socket -> IO Bool 
    closeSocket sock =
      modifyMVar theirState $ \st ->
        case st of
          RemoteEndPointInvalid _ ->
            relyViolation (ourEndPoint, theirEndPoint) "handleIncomingMessages:closeSocket"
          RemoteEndPointInit _ _ ->
            relyViolation (ourEndPoint, theirEndPoint) "handleIncomingMessages:closeSocket"
          RemoteEndPointValid vst -> do
            -- We regard a CloseSocket message as an (optimized) way for the
            -- remote endpoint to indicate that all its connections to us are
            -- now properly closed
            forM_ (IntSet.elems $ vst ^. remoteIncoming) $ 
              writeChan ourChannel . ConnectionClosed 
            let vst' = remoteIncoming ^= IntSet.empty $ vst 
            -- Check if we agree that the connection should be closed
            if vst' ^. remoteOutgoing == 0 
              then do 
                removeRemoteEndPoint (ourEndPoint, theirEndPoint)
                -- Attempt to reply (but don't insist)
                tryIO $ sendOn vst' [encodeInt32 CloseSocket]
                tryCloseSocket sock 
                return (RemoteEndPointClosed, True)
              else 
                return (RemoteEndPointValid vst', False)
          RemoteEndPointClosing resolved  _ -> do
            removeRemoteEndPoint (ourEndPoint, theirEndPoint)
            tryCloseSocket sock 
            putMVar resolved ()
            return (RemoteEndPointClosed, True)
          RemoteEndPointClosed ->
            throwIO $ userError "Remote endpoint closed"
            
    -- Read a message and output it on the endPoint's channel By rights we
    -- should verify that the connection ID is valid, but this is unnecessary
    -- overhead
    readMessage :: N.Socket -> ConnectionId -> IO () 
    readMessage sock connId = 
      recvWithLength sock >>= writeChan ourChannel . Received connId

    -- Arguments
    ourChannel  = localChannel ourEndPoint 
    ourState    = localState ourEndPoint 
    theirState  = remoteState theirEndPoint
    theirAddr   = remoteAddress theirEndPoint

    -- Deal with a premature exit
    prematureExit :: N.Socket -> IOException -> IO ()
    prematureExit sock err = do
      removeRemoteEndPoint (ourEndPoint, theirEndPoint)
      tryCloseSocket sock
      modifyMVar_ theirState $ \st ->
        case st of
          RemoteEndPointInvalid _ ->
            relyViolation (ourEndPoint, theirEndPoint) "handleIncomingMessages:prematureExit"
          RemoteEndPointInit _ _ ->
            relyViolation (ourEndPoint, theirEndPoint) "handleIncomingMessages:prematureExit"
          RemoteEndPointValid vst -> do
            let code = EventConnectionLost 
                         (remoteAddress theirEndPoint) 
                         (IntSet.elems $ vst ^. remoteIncoming)
            writeChan ourChannel . ErrorEvent $ TransportError code (show err)
            return RemoteEndPointClosed
          RemoteEndPointClosing resolved _ -> do
            putMVar resolved ()
            return RemoteEndPointClosed
          RemoteEndPointClosed ->
            return RemoteEndPointClosed 

-- | Get the next connection ID
-- 
-- Throws an IO exception when the endpoint is closed.
getNextConnectionId :: LocalEndPoint -> IO ConnectionId
getNextConnectionId ourEndpoint = 
  modifyMVar (localState ourEndpoint) $ \st -> case st of
    LocalEndPointValid vst -> do
      let connId = vst ^. nextConnectionId 
      return ( LocalEndPointValid 
             . (nextConnectionId ^= connId + 1) 
             $ vst
             , connId)
    LocalEndPointClosed ->
      throwIO $ userError "Local endpoint closed"

--------------------------------------------------------------------------------
-- Constants                                                                  --
--------------------------------------------------------------------------------

-- | We reserve a bunch of connection IDs for control messages
firstNonReservedConnectionId :: ConnectionId
firstNonReservedConnectionId = 1024

--------------------------------------------------------------------------------
-- Accessor definitions                                                       --
--------------------------------------------------------------------------------

localEndPoints :: Accessor ValidTransportState (Map EndPointAddress LocalEndPoint)
localEndPoints = accessor _localEndPoints (\es st -> st { _localEndPoints = es })

nextEndPointId :: Accessor ValidTransportState EndPointId
nextEndPointId = accessor _nextEndPointId (\eid st -> st { _nextEndPointId = eid })

pendingCtrlRequests :: Accessor ValidLocalEndPointState (IntMap (MVar [ByteString]))
pendingCtrlRequests = accessor _pendingCtrlRequests (\rep st -> st { _pendingCtrlRequests = rep })

nextCtrlRequestId :: Accessor ValidLocalEndPointState ControlRequestId 
nextCtrlRequestId = accessor _nextCtrlRequestId (\cid st -> st { _nextCtrlRequestId = cid })

nextConnectionId :: Accessor ValidLocalEndPointState ConnectionId
nextConnectionId = accessor _nextConnectionId (\cix st -> st { _nextConnectionId = cix })

localConnections :: Accessor ValidLocalEndPointState (Map EndPointAddress RemoteEndPoint)
localConnections = accessor _localConnections (\es st -> st { _localConnections = es })

internalThreads :: Accessor ValidLocalEndPointState [ThreadId]
internalThreads = accessor _internalThreads (\ts st -> st { _internalThreads = ts })

nextRemoteId :: Accessor ValidLocalEndPointState Int
nextRemoteId = accessor _nextRemoteId (\rid st -> st { _nextRemoteId = rid })

remoteOutgoing :: Accessor ValidRemoteEndPointState Int
remoteOutgoing = accessor _remoteOutgoing (\cs conn -> conn { _remoteOutgoing = cs })

remoteIncoming :: Accessor ValidRemoteEndPointState IntSet
remoteIncoming = accessor _remoteIncoming (\cs conn -> conn { _remoteIncoming = cs })

localEndPointAt :: EndPointAddress -> Accessor ValidTransportState (Maybe LocalEndPoint)
localEndPointAt addr = localEndPoints >>> DAC.mapMaybe addr 

pendingCtrlRequestsAt :: ControlRequestId -> Accessor ValidLocalEndPointState (Maybe (MVar [ByteString]))
pendingCtrlRequestsAt ix = pendingCtrlRequests >>> DAC.intMapMaybe (fromIntegral ix)

localConnectionTo :: EndPointAddress 
                  -> Accessor ValidLocalEndPointState (Maybe RemoteEndPoint)
localConnectionTo addr = localConnections >>> DAC.mapMaybe addr 

-------------------------------------------------------------------------------
-- Debugging                                                                 --
-------------------------------------------------------------------------------

relyViolation :: EndPointPair -> String -> IO a
relyViolation (ourEndPoint, theirEndPoint) str = do
  elog (ourEndPoint, theirEndPoint) (str ++ " RELY violation")  
  fail (str ++ " RELY violation")

elog :: EndPointPair -> String -> IO ()
elog (ourEndPoint, theirEndPoint) msg = do
  tid <- myThreadId
  putStrLn $ show (localAddress ourEndPoint) ++ "/" ++ show (remoteAddress theirEndPoint) ++ "/" ++ show tid ++ ": " ++ msg
