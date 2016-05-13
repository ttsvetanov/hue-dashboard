
{-# LANGUAGE RecordWildCards, LambdaCase #-}

module Main (main) where

import Data.Monoid
import Data.Maybe
import Data.Aeson
import qualified Data.ByteString.Lazy as BS
import qualified Data.HashMap.Strict as HM
import Control.Lens
import Control.Exception
import Control.Concurrent.STM
import qualified Codec.Picture as JP
import Text.Read
import Control.Concurrent.Async

import Util
import Trace
import App
import AppDefs
--import HueREST
--import HueSetup
import PersistConfig
import CmdLineOptions
import BackgroundProcessing

main :: IO ()
main = do
    -- Command line options
    flags <- parseCmdLineOpt
    -- Setup tracing
    let traceFn  = foldr (\f r -> case f of FlagTraceFile fn -> Just fn; _ -> r) Nothing flags
        mkTrcOpt = \case "n" -> TLNone; "e" -> TLError; "w" -> TLWarn; "i" -> TLInfo; _ -> TLInfo
        traceLvl = foldr (\f r -> case f of (FlagTraceLevel lvl) -> mkTrcOpt lvl; _ -> r)
                         TLInfo flags
    withTrace traceFn
            (not $ FlagTraceNoEcho       `elem` flags)
            (      FlagTraceAppend       `elem` flags)
            (not $ FlagTraceDisableColor `elem` flags)
            traceLvl
            $ do
      -- Load configuration (might not be there)
      mbCfg <- loadConfig configFilePath
      -- Bridge connection and user ID
      bridgeIP <- return $ IPAddress "192.168.1.155"--discoverBridgeIP    $ view pcBridgeIP     <$> mbCfg
      userID   <- return $ BridgeUserID "123"--createUser bridgeIP $ view pcBridgeUserID <$> mbCfg
      -- We have everything setup, build and store configuration
      let newCfg = (fromMaybe defaultPersistConfig mbCfg)
                       & pcBridgeIP     .~ bridgeIP
                       & pcBridgeUserID .~ userID
      _aePC <- atomically . newTVar $ newCfg
      -- Write configuration data on exit
      --
      -- TODO: Couldn't get this to work reliably on any thread but the main one.
      --       Shouldn't interfere with the pcWriterThread as it should already be
      --       terminated when we run the handler. Still a risk of data corruption
      --       when being interrupted twice
      --
      -- TODO: This doesn't seem to trigger when we run with daemontools and do 'svc -d'
      --
      flip finally
        ( do currentCfg <- atomically $ readTVar _aePC
             traceS TLInfo "Exiting, persisting configuration data..."
             storeConfig configFilePath currentCfg
        ) $
        -- Launch persistent configuration writer thread
        withAsync (pcWriterThread _aePC) $ \_ ->
        -- Launch schedule watcher thread
        withAsync (scheduleWatcher _aePC) $ \_ -> do
          -- Request full bridge configuration
          traceS TLInfo $ "Trying to obtain full bridge configuration..."
          _aeBC <- fromJust . decode <$> BS.readFile "mock/config.json"--bridgeRequestRetryTrace MethodGET bridgeIP noBody userID "config"
          traceS TLInfo $ "Success, full bridge configuration:\n" <> show _aeBC
          -- Request all scenes (TODO: Maybe do this on every new connection, not once per server?)
          -- http://www.developers.meethue.com/documentation/scenes-api#41_get_all_scenes
          traceS TLInfo $ "Trying to obtain list of bridge scenes..."
          _aeBridgeScenes <- fromJust . decode <$> BS.readFile "mock/scenes.json"--bridgeRequestRetryTrace MethodGET bridgeIP noBody userID "scenes"
          traceS TLInfo $ "Success, number of scenes received: " <> show (length _aeBridgeScenes)
          -- TVars for sharing light / group state across threads
          _aeLights      <- atomically . newTVar $ HM.empty
          _aeLightGroups <- atomically . newTVar $ HM.empty
          -- TChan for propagating light updates
          _aeBroadcast <- atomically $ newBroadcastTChan
          -- Load color picker image
          _aeColorPickerImg <- JP.readPng "static/color_picker.png" >>= \case
              Right (JP.ImageRGB8 image) -> do traceS TLInfo $ "Loaded color picker image"
                                               return image
              Right _                    -> traceAndThrow $ "Color picker image wrong format"
              Left err                   -> traceAndThrow $ "Can't load color picker image: " <> err
          -- Command line options passed on to the rest of the program
          let _aeCmdLineOpts = CmdLineOpts
                  { _cloPort          =
                        foldr (\f r -> case f of
                                 FlagPort port -> fromMaybe defPort $ readMaybe port; _ -> r)
                              defPort
                              flags
                  , _cloOnlyLocalhost = FlagLocalhost `elem` flags
                  , _cloPollInterval  =
                         foldr (\f r -> case f of
                                 FlagPollInterval interval ->
                                   fromMaybe defPollInterval $ readMaybe interval;
                                 _ -> r)
                               defPollInterval
                               flags
                  , _cloTraceHTTP     =  FlagTraceHTTP `elem` flags
                  }
          -- Launch application
          run AppEnv { .. }

