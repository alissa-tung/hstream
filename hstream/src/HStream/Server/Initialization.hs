{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HStream.Server.Initialization
  ( initializeServer
  -- , initNodePath
  , initializeTlsConfig
  ) where

import           Control.Concurrent               (MVar, newMVar)
import           Control.Concurrent.STM           (TVar, newTVarIO)
import           Control.Exception                (catch)
import           Control.Monad                    (void)
import qualified Data.HashMap.Strict              as HM
import           Data.List                        (find, sort)
import           Network.GRPC.HighLevel           (AuthProcessorResult (AuthProcessorResult),
                                                   AuthProperty (authPropName),
                                                   ProcessMeta,
                                                   ServerSSLConfig (ServerSSLConfig),
                                                   SslClientCertificateRequestType (SslDontRequestClientCertificate, SslRequestAndRequireClientCertificateAndVerify),
                                                   StatusCode (StatusOk),
                                                   getAuthProperties)
import           Text.Printf                      (printf)
import qualified Z.Data.CBytes                    as CB
import           ZooKeeper.Types

import qualified HStream.Admin.Store.API          as AA
import           HStream.Common.ConsistentHashing (HashRing, constructServerMap)
import           HStream.Gossip                   (GossipContext, getMemberList)
import           HStream.Gossip.Types             (GossipContext)
import qualified HStream.IO.Types                 as IO
import qualified HStream.IO.Worker                as IO
import qualified HStream.Logger                   as Log
import           HStream.Server.Config            (ServerOpts (..),
                                                   TlsConfig (..))
import           HStream.Server.Persistence       (ioPath)
import           HStream.Server.ReaderPool        (mkReaderPool)
import           HStream.Server.Types
import           HStream.Stats                    (newServerStatsHolder)
import qualified HStream.Store                    as S
import           HStream.Utils

initializeServer
  :: ServerOpts
  -> GossipContext
  -> ZHandle
  -> MVar ServerState
  -> IO ServerContext
initializeServer opts@ServerOpts{..} gossipContext zk serverState = do
  ldclient <- S.newLDClient _ldConfigPath
  let attrs = S.def{S.logReplicationFactor = S.defAttr1 _ckpRepFactor}
  _ <- catch (void $ S.initCheckpointStoreLogID ldclient attrs)
             (\(_ :: S.EXISTS) -> return ())
  let headerConfig = AA.HeaderConfig _ldAdminHost _ldAdminPort _ldAdminProtocolId _ldAdminConnTimeout _ldAdminSendTimeout _ldAdminRecvTimeout

  statsHolder <- newServerStatsHolder

  runningQs <- newMVar HM.empty
  runningCs <- newMVar HM.empty
  subCtxs <- newTVarIO HM.empty

  hashRing <- initializeHashRing gossipContext

  ioWorker <-
    IO.newWorker
      (IO.ZkKvConfig zk (cBytesToText _zkUri) (cBytesToText ioPath))
      (IO.HStreamConfig (cBytesToText (_serverHost <> ":" <> CB.pack (show _serverPort))))
  let readerNums = 8
  readerPool <- mkReaderPool ldclient readerNums

  return
    ServerContext
      { zkHandle                 = zk
      , scLDClient               = ldclient
      , serverID                 = _serverID
      , scAdvertisedListenersKey = Nothing
      , scDefaultStreamRepFactor = _topicRepFactor
      , scMaxRecordSize          = _maxRecordSize
      , runningQueries           = runningQs
      , runningConnectors        = runningCs
      , scSubscribeContexts      = subCtxs
      , cmpStrategy              = _compression
      , headerConfig             = headerConfig
      , scStatsHolder            = statsHolder
      , loadBalanceHashRing      = hashRing
      , scServerState            = serverState
      , scIOWorker               = ioWorker
      , gossipContext            = gossipContext
      , serverOpts               = opts
      , readerPool               = readerPool
      }

--------------------------------------------------------------------------------

initializeHashRing :: GossipContext -> IO (TVar HashRing)
initializeHashRing gc = do
  serverNodes <- getMemberList gc
  newTVarIO . constructServerMap . sort $ serverNodes

initializeTlsConfig :: TlsConfig -> ServerSSLConfig
initializeTlsConfig TlsConfig {..} = ServerSSLConfig caPath keyPath certPath authType authHandler
  where
    authType = maybe SslDontRequestClientCertificate (const SslRequestAndRequireClientCertificateAndVerify) caPath
    authHandler = fmap (const authProcess) caPath

-- ref: https://github.com/grpc/grpc/blob/master/doc/server_side_auth.md
authProcess :: ProcessMeta
authProcess authCtx _ = do
  prop <- getAuthProperties authCtx
  let cn = find ((== "x509_common_name") . authPropName) prop
  Log.info . Log.buildString . printf "user:[%s] is logging in" $ show cn
  return $ AuthProcessorResult mempty mempty StatusOk ""
