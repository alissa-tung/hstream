{-# LANGUAGE FlexibleInstances #-}

module HStream.Admin.Server.Command.ServerSql
  ( HStreamQuery
  , newHStreamQuery

  , serverSqlRepl
  ) where

import           Control.Monad.IO.Class     (liftIO)
import           Data.Char                  (toLower, toUpper)
import           Data.List                  (isPrefixOf)
import           Data.Word                  (Word8)
import           Foreign.ForeignPtr
import           Foreign.Ptr                (FunPtr, Ptr)
import qualified System.Console.Haskeline   as H
import qualified Z.Data.Builder             as ZBuilder
import           Z.Data.CBytes              (CBytes)
import qualified Z.Data.CBytes              as CB
import           Z.IO.Network               (PortNumber)

import           HStream.Admin.Server.Types
import qualified HStream.Common.Query       as Query


serverSqlRepl :: CliOpts -> ServerSqlCmdOpts -> IO ()
serverSqlRepl CliOpts{..} ServerSqlCmdOpts{..} = do
  query <- newHStreamQuery optServerHost optServerPort
  case serverSqlCmdRepl of
    Just sql -> runSql query sql
    Nothing  -> runRepl query
  where
    runRepl query = do
      complete <- getCompletionFun query
      let setting  = (H.defaultSettings :: H.Settings IO) {H.complete = complete}
      H.runInputT setting loop where
        loop = H.withInterrupt . H.handleInterrupt loop $ do
          H.getInputLine "sql> " >>= \case
            Nothing  -> pure ()
            Just str -> liftIO (runSql query str) >> loop

runSql :: HStreamQuery -> String -> IO ()
runSql q str =
  case words (map toLower str) of
    [] -> return ()
    ["show", "tables"]      -> putStrLn =<< Query.showTables q
    ["show", "tables", ";"] -> putStrLn =<< Query.showTables q
    ["show", "tables;"]     -> putStrLn =<< Query.showTables q
    ["describe", name_]     -> if last name_ == ';'
                                  then putStrLn =<< Query.showTableColumns q (CB.pack $ init name_)
                                  else putStrLn =<< Query.showTableColumns q (CB.pack name_)
    ["describe", name, ";"] -> putStrLn =<< Query.showTableColumns q (CB.pack name)
    "select" : _ -> either putStrLn (mapM_ putStrLn) =<< Query.runQuery q (CB.pack str)
    _            -> putStrLn $ "unknown command: " <> str <> "\n\n" <> helpMsg

getCompletionFun :: HStreamQuery -> IO (H.CompletionFunc IO)
getCompletionFun query = do
  let commands = ["show", "describe", "select"]
  tables <- map (CB.unpack . fst) <$> Query.getTables query
  return $ H.completeWordWithPrev Nothing " \t" $ \leftStr str -> do
    let leftWord = if null (words leftStr)
                      then ""
                      else reverse . head $ words leftStr
    let wordList = case leftWord of
                     ""         -> commands ++ (map toUpper <$> commands)
                     "show"     -> ["tables"]; "SHOW" -> ["TABLES"]
                     "describe" -> tables; "DESCRIBE" -> tables
                     "from"     -> tables; "FROM"     -> tables
                     _          -> []
    return $ map H.simpleCompletion $ filter (str `isPrefixOf`) wordList

helpMsg :: String
helpMsg = "Commands: \n"
       <> "- show tables: Shows a list of the supported tables\n"
       <> "- describle <table name>: to get detailed information about that table\n"
       <> "- select: a sql query interface for the tier, use `show tables` to get information about the tables available for query"

-------------------------------------------------------------------------------

data C_HStreamQuery
type HStreamQuery = ForeignPtr C_HStreamQuery

instance Query.QueryBaseRep HStreamQuery where
  eqQueryBaseRep = castForeignPtr

newHStreamQuery' :: CBytes -> IO HStreamQuery
newHStreamQuery' addr = CB.withCBytes addr $ \addr' -> do
   ldq_ptr <- new_hstream_query addr'
   newForeignPtr delete_hstream_query_fun ldq_ptr

newHStreamQuery :: CBytes -> PortNumber -> IO HStreamQuery
newHStreamQuery host port = newHStreamQuery' (host <> ":" <> CB.buildCBytes (ZBuilder.int port))

foreign import ccall safe "new_hstream_query"
  new_hstream_query :: Ptr Word8 -> IO (Ptr C_HStreamQuery)

foreign import ccall unsafe "&delete_hstream_query"
  delete_hstream_query_fun :: FunPtr (Ptr C_HStreamQuery -> IO ())
