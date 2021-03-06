{-# LANGUAGE CPP, BangPatterns #-}

module Main where

import Control.Monad

import Data.Int
import qualified Data.Serialize as Ser
import Data.Word (Word8)
import Network.Socket
  ( AddrInfoFlag (AI_PASSIVE), HostName, ServiceName, Socket
  , SocketType (Stream), SocketOption (ReuseAddr)
  , accept, addrAddress, addrFlags, addrFamily, bindSocket, defaultProtocol
  , defaultHints
  , getAddrInfo, listen, setSocketOption, socket, sClose, withSocketsDo )
import System.Environment (getArgs, withArgs)
import Data.Time (getCurrentTime, diffUTCTime, NominalDiffTime)
import System.IO (withFile, IOMode(..), hPutStrLn, Handle)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, putMVar)

import qualified Network.Socket as N

import Debug.Trace

#ifndef LAZY
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (pack)
import qualified Data.ByteString as BS
import qualified Network.Socket.ByteString as NBS
encode = Ser.encode
decode = Ser.decode
#else
import Data.ByteString.Lazy (ByteString, pack)
import qualified Network.Socket.ByteString.Lazy as NBS
encode = Ser.encodeLazy
decode = Ser.decodeLazy
#endif
{-# INLINE encode #-}
{-# INLINE decode #-}
encode :: Ser.Serialize a => a -> ByteString
decode :: Ser.Serialize a => ByteString -> Either String a

-- | This performs a ping benchmark on a TCP connection created by
-- Network.Socket. To compile this file, you might use:
--
--    ghc --make -idistributed-process/src -inetwork-transport/src -O2 benchmarks/PingTCP.hs
--
-- To use the compiled binary, first set up the server on the current machine:
--
--     ./benchmarks/PingTCP server 8080
--
-- Next, perform the benchmark on a client using the server address, where
-- each mark is 1000 pings:
--
--    ./benchmarks/PingTCP client 0.0.0.0 8080 1000
--
-- The server must be restarted between benchmarks.
main :: IO ()
main = do
  [pingsStr] <- getArgs
  serverReady <- newEmptyMVar

  -- Start the server
  forkIO $ do
    putStrLn "server: creating TCP connection"
    serverAddrs <- getAddrInfo 
      (Just (defaultHints { addrFlags = [AI_PASSIVE] } ))
      Nothing
      (Just "8080")
    let serverAddr = head serverAddrs
    sock <- socket (addrFamily serverAddr) Stream defaultProtocol
    setSocketOption sock ReuseAddr 1
    bindSocket sock (addrAddress serverAddr)

    putStrLn "server: awaiting client connection"
    putMVar serverReady ()
    listen sock 1
    (clientSock, clientAddr) <- accept sock

    putStrLn "server: listening for pings"
    pong clientSock

  -- Client
  takeMVar serverReady
  let pings = read pingsStr
  serverAddrs <- getAddrInfo 
    Nothing
    (Just "127.0.0.1")
    (Just "8080")
  let serverAddr = head serverAddrs
  sock <- socket (addrFamily serverAddr) Stream defaultProtocol

  N.connect sock (addrAddress serverAddr)

  ping sock pings

pingMessage :: ByteString
pingMessage = pack "ping123"

ping :: Socket -> Int -> IO () 
ping sock pings = go [] pings
  where
    go :: [Double] -> Int -> IO ()
    go rtl 0 = do 
      withFile "round-trip-latency-tcp.data" WriteMode (writeData rtl) 
      putStrLn $ "client did " ++ show pings ++ " pings"
    go rtl !i = do
      before <- getCurrentTime
      send sock pingMessage 
      bs <- recv sock 8
      after <- getCurrentTime
      let latency = (1e6 :: Double) * realToFrac (diffUTCTime after before)
      latency `seq` go (latency : rtl) (i - 1)
    writeData :: [Double] -> Handle -> IO ()
    writeData rtl h = forM_ (zip [0..] rtl) (writeDataLine h)
    writeDataLine :: Handle -> (Int, Double) -> IO ()
    writeDataLine h (i, latency) = hPutStrLn h $ (show i) ++ " " ++ (show latency)

pong :: Socket -> IO ()
pong sock = do
  bs <- recv sock 8
  when (BS.length bs > 0) $ do
    send sock bs
    pong sock

-- | Wrapper around NBS.recv (for profiling) 
recv :: Socket -> Int -> IO ByteString
recv = NBS.recv

-- | Wrapper around NBS.send (for profiling)
send :: Socket -> ByteString -> IO Int
send = NBS.send
