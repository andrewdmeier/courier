-----------------------------------------------------------------------------
-- |
-- Module      :  Network.Transport.Sockets.UDP
-- Copyright   :  (c) Phil Hargett 2015
-- License     :  MIT (see LICENSE file)
--
-- Maintainer  :  phil@haphazardhouse.net
-- Stability   :  experimental
-- Portability :  non-portable (requires STM)
--
-- UDP transport.
--
-----------------------------------------------------------------------------
module Network.Transport.Sockets.UDP (
  newUDPTransport4,
  newUDPTransport6,

  udpSocketResolver4,
  udpSocketResolver6,

  module Network.Transport
) where

-- local imports

import Network.Endpoints
import Network.Transport
import Network.Transport.Sockets

-- external imports

import Control.Concurrent.Async
import Control.Concurrent.Mailbox
import Control.Concurrent.STM
import Control.Exception
import Control.Monad

import qualified Data.Map as M

import qualified Network.Socket as NS
import qualified Network.Socket.ByteString as NSB

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
type SocketConnections = TVar (M.Map NS.SockAddr Connection)

newUDPTransport :: NS.Family -> Resolver -> IO Transport
newUDPTransport family resolver = do
  socket <- NS.socket family NS.Datagram NS.defaultProtocol
  atomically $ do
    vPeers <- newTVar M.empty
    mailboxes <- newTVar M.empty
    vSocket <- newTMVar socket
    return Transport {
      bind = udpBind family resolver,
      dispatch = udpDispatcher vSocket resolver,
      connect = udpConnect mailboxes family resolver,
      shutdown = udpShutdown vPeers
    }

{-|
Create a 'Transport' for exchanging 'Message's between endpoints via UDP over IP
-}
newUDPTransport4 :: Resolver -> IO Transport
newUDPTransport4 = newUDPTransport NS.AF_INET

{-|
Create a 'Transport' for exchanging 'Message's between endpoints via UDP over IPv6
-}
newUDPTransport6 :: Resolver -> IO Transport
newUDPTransport6 = newUDPTransport NS.AF_INET6

{-|
Create a 'Resolve' for resolving 'Name's for use with UDP over IP.
-}
udpSocketResolver4 :: Name -> IO [NS.SockAddr]
udpSocketResolver4 = socketResolver4 NS.Datagram

{-|
Create a 'Resolve' for resolving 'Name's for use with UDP over IPv6.
-}
udpSocketResolver6 :: Name -> IO [NS.SockAddr]
udpSocketResolver6 = socketResolver6 NS.Datagram

udpBind :: NS.Family -> Resolver -> Endpoint -> Name -> IO Binding
udpBind family resolver endpoint name = do
  socket <- NS.socket family NS.Datagram NS.defaultProtocol
  address <- resolve1 resolver name
  NS.setSocketOption socket NS.ReuseAddr 1
  when (NS.isSupportedSocketOption NS.ReusePort)
    $ NS.setSocketOption socket NS.ReusePort 1
  NS.bind socket address
  listener <- async $
    finally (receiver socket)
      (udpUnbind socket)
  return Binding {
    bindingName = name,
    unbind = cancel listener
  }
  where
    receiver socket = do
      msg <- udpReceive socket
      -- TODO consider a way of using a message to identify the name of
      -- the endpoint on the other end of the connection
      atomically $ postMessage endpoint msg
      receiver socket

udpDispatcher :: TMVar NS.Socket -> Resolver -> Endpoint -> IO Dispatcher
udpDispatcher vSocket resolver endpoint = do
  d <- async disp
  return Dispatcher {
    stop = cancel d
  }
  where
    disp = do
      (socket,name,msg) <- atomically $ do
        envelope <- readMailbox $ endpointOutbound endpoint
        let name = messageDestination envelope
            msg = envelopeMessage envelope
        socket <- readTMVar vSocket
        return (socket,name,msg)
      address <- resolve1 resolver name
      udpSend socket address msg
      disp

udpUnbind :: NS.Socket -> IO ()
udpUnbind = NS.close

udpConnect :: Mailboxes -> NS.Family -> Resolver -> Endpoint -> Name -> IO Connection
udpConnect mailboxes family resolver _ name = do
  socket <- NS.socket family NS.Datagram NS.defaultProtocol
  address <- resolve1 resolver name
  sender <- async $ finally (writer socket address) (udpDisconnect socket)
  return Connection {
    disconnect = cancel sender
  }
  where
    writer socket address = do
      msg <- atomically $ pullMessage mailboxes name
      udpSend socket address msg
      writer socket address

udpSend :: NS.Socket -> NS.SockAddr -> Message -> IO ()
udpSend socket address message = NSB.sendAllTo socket message address

udpReceive :: NS.Socket -> IO Message
udpReceive socket = do
  (msg,_) <- NSB.recvFrom socket 512
  return msg

udpDisconnect :: NS.Socket -> IO ()
udpDisconnect = NS.close

udpShutdown :: SocketConnections -> IO ()
udpShutdown vPeers = do
  peers <- atomically $ readTVar vPeers
  -- this is how we disconnect incoming connections
  -- we don't have to disconnect  outbound connectinos, because
  -- they should already be disconnected before here
  forM_ (M.elems peers) disconnect
  return ()
