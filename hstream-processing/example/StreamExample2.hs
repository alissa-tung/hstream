{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE StrictData        #-}

import           Data.Aeson
import qualified Data.Binary                                  as B
import           Data.Binary.Get
import qualified Data.ByteString.Builder                      as BB
import qualified Data.ByteString.Lazy                         as BL
import           Data.Maybe
import qualified Data.Text.Lazy                               as TL
import qualified Data.Text.Lazy.Encoding                      as TLE
import           HStream.Processing.Connector
import           HStream.Processing.Encoding
import           HStream.Processing.MockStreamStore
import           HStream.Processing.Processor
import           HStream.Processing.Store
import qualified HStream.Processing.Stream                    as HS
import qualified HStream.Processing.Stream.GroupedStream      as HG
import qualified HStream.Processing.Stream.TimeWindowedStream as HTW
import           HStream.Processing.Stream.TimeWindows
import qualified HStream.Processing.Table                     as HT
import           HStream.Processing.Type
import           HStream.Processing.Util
import qualified Prelude                                      as P
import           RIO
import           System.Random

data R = R
  { temperature :: Int,
    humidity :: Int
  }
  deriving (Generic, Show, Typeable)

instance ToJSON R

instance FromJSON R

main :: IO ()
main = do
  mockStore <- mkMockStreamStore
  sourceConnector1 <- mkMockStoreSourceConnector mockStore
  sourceConnector2 <- mkMockStoreSourceConnector mockStore
  sinkConnector <- mkMockStoreSinkConnector mockStore

  let textSerde =
        Serde
          { serializer = Serializer TLE.encodeUtf8,
            deserializer = Deserializer TLE.decodeUtf8
          } ::
          Serde TL.Text BL.ByteString
  let rSerde =
        Serde
          { serializer = Serializer encode,
            deserializer = Deserializer $ fromJust . decode
          } ::
          Serde R BL.ByteString
  let intSerde =
        Serde
          { serializer = Serializer B.encode,
            deserializer = Deserializer B.decode
          } ::
          Serde Int BL.ByteString
  let timeWindowSerde windowSize =
        Serde
        { serializer = Serializer $ \TimeWindow{..} ->
            let winStartBuilder = BB.int64BE tWindowStart
                blankBuilder = BB.int64BE 0
             in BB.toLazyByteString $ winStartBuilder <> blankBuilder
        , deserializer = Deserializer $ runGet decodeTimeWindow
        }
        where
          decodeTimeWindow = do
            startTs <- getInt64be
            _       <- getInt64be
            return TimeWindow {tWindowStart = startTs, tWindowEnd = startTs + windowSize}

  let streamSourceConfig =
        HS.StreamSourceConfig
          { sscStreamName = "demo-source",
            sscKeySerde = textSerde,
            sscValueSerde = rSerde
          }
  let timeWindowSize = 3000
  let streamSinkConfig =
        HS.StreamSinkConfig
          { sicStreamName = "demo-sink",
            sicKeySerde = timeWindowKeySerde textSerde (timeWindowSerde timeWindowSize) timeWindowSize,
            sicValueSerde = intSerde
          }
  aggStore <- mkInMemoryStateKVStore
  let materialized =
        HS.Materialized
          { mKeySerde = textSerde,
            mValueSerde = intSerde,
            mStateStore = aggStore
          }
  streamBuilder <-
    HS.mkStreamBuilder "demo"
      >>= HS.stream streamSourceConfig
      >>= HS.filter filterR
      >>= HS.groupBy (fromJust . recordKey)
      >>= HG.timeWindowedBy (mkHoppingWindow timeWindowSize 1000)
      >>= HTW.count materialized (timeWindowSerde timeWindowSize) (timeWindowSerde timeWindowSize) intSerde
      >>= HT.toStream
      >>= HS.to streamSinkConfig

  _ <- async $
    forever $
      do
        threadDelay 1000000
        MockMessage {..} <- mkMockData
        writeRecord
          sinkConnector
          SinkRecord
            { snkStream = "demo-source",
              snkKey = mmKey,
              snkValue = mmValue,
              snkTimestamp = mmTimestamp
            }

  _ <- async $
    forever $
      do
        subscribeToStream sourceConnector1 "demo-sink" Earlist
        records <- readRecords sourceConnector1
        forM_ records $ \SourceRecord {..} -> do
          let k = runDeser (timeWindowKeyDeserializer (deserializer textSerde) (deserializer $ timeWindowSerde timeWindowSize) timeWindowSize) (fromJust srcKey)
          P.putStrLn $
            ">>> count: key: "
              ++ show k
              ++ " , value: "
              ++ show (B.decode srcValue :: Int)

  runTask sourceConnector2 sinkConnector (HS.build streamBuilder)

filterR :: Record TL.Text R -> Bool
filterR Record {..} =
  temperature recordValue >= 0
    && humidity recordValue >= 0

mkMockData :: IO MockMessage
mkMockData = do
  k <- getStdRandom (randomR (1, 2)) :: IO Int
  t <- getStdRandom (randomR (0, 100))
  h <- getStdRandom (randomR (0, 100))
  let r = R {temperature = t, humidity = h}
  P.putStrLn $ "gen data: " ++ " key: " ++ show k ++ ", value: " ++ show r
  ts <- getCurrentTimestamp
  return
    MockMessage
      { mmTimestamp = ts,
        mmKey = Just $ TLE.encodeUtf8 $ TL.pack $ show k,
        mmValue = encode $ R {temperature = t, humidity = h}
      }
