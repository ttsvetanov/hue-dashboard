
{-# LANGUAGE OverloadedStrings, RecordWildCards, RankNTypes, LambdaCase #-}

module WebUITileBuildingSchedules ( addSchedulesTile
                                  , addScheduleTile
                                  ) where

import Text.Printf
import Text.Read (readMaybe)
import qualified Data.Text as T
import Data.Monoid
import Data.List
import Data.Maybe
import Data.Aeson
import qualified Data.Function (on)
import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet as HS
import Control.Concurrent.STM
import Control.Lens hiding ((#), set, (<.>), element)
import Control.Monad
import Control.Monad.Reader
import qualified Graphics.UI.Threepenny as UI
import Graphics.UI.Threepenny.Core
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

import Util
import Trace
import HueJSON
import AppDefs
import PersistConfig
import WebUIHelpers
import WebUIREST

-- Code for building the schedule tiles

-- We give this CSS class to all schedule tile elements we want
-- to hide / show as part of the 'Schedules' group
scheduleTilesClass :: String
scheduleTilesClass = "schedule-tiles-hide-show"

-- Overwrite or create schedule
createSchedule :: TVar PersistConfig -> ScheduleName -> SceneName -> Int -> Int -> [Bool] -> IO ()
createSchedule tvPC scheduleName _sScene _sHour _sMinute _sDays =
    atomically $ modifyTVar' tvPC (pcSchedules . at scheduleName ?~ Schedule { .. })

-- TODO: Schedule creation and deletion currently requires a page reload

-- Build the head tile for toggling visibility and creation of schedules. Return if the
-- 'Schedules' group is visible and subsequent elements should be added hidden or not
addSchedulesTile :: [SceneName] -> CookieUserID -> Window -> PageBuilder Bool
addSchedulesTile sceneNames userID window = do
  AppEnv { .. } <- ask
  let scheduleCreatorID                    = "schedule-creator-dialog-container"  :: String
      scheduleCreatorNameID                = "schedule-creator-dialog-name"       :: String
      scheduleCreatorBtnID                 = "schedule-creator-dialog-btn"        :: String
      scheduleCreatorHourID                = "schedule-creator-dialog-hour"       :: String
      scheduleCreatorMinuteID              = "schedule-creator-dialog-minute"     :: String
      scheduleCreatorSceneID               = "schedule-creator-dialog-scene"      :: String
      scheduleCreatorDayID day             = "schedule-creator-dialog-day" <> day :: String
      schedulesTileHideShowBtnID           = "schedules-tile-hide-show-btn"       :: String
      schedulesTileGroupName               = GroupName "<SchedulesTileGroup>"
      days                                 = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
      queryGroupShown                      =
        queryUserData _aePC userID (udVisibleGroupNames . to (HS.member schedulesTileGroupName))
  grpShown <- liftIO (atomically queryGroupShown)
  -- Tile
  addPageTile $
    H.div H.! A.class_ "thumbnail" $ do
      -- Caption and scene icon
      H.div H.! A.class_ "light-caption light-caption-group-header small"
            H.! A.style "cursor: default;"
            $ "Schedules"
      H.img H.! A.class_ "img-rounded"
            H.! A.src "static/svg/clock.svg"
            H.! A.style "cursor: default;"
      -- Schedule creation dialog
      H.div H.! A.style "display: none;"
            H.! A.id (H.toValue scheduleCreatorID) $ do
        H.div H.! A.class_ "color-picker-curtain"
              H.! A.onclick "this.parentNode.style.display = 'none'"
              $ return ()
        H.div H.! A.class_ "scene-creator-frame" $ do
          H.div H.! A.class_ "small" $ do
            void $ "at "
            H.select H.! A.id (H.toValue scheduleCreatorHourID) $
              forM_ ([0..23] :: [Int]) $ \h ->
                if  h == 16 -- Default
                then H.option H.! A.value "16" H.! A.selected "selected" $ void "16"
                else H.option H.! A.value (H.toValue . show $ h) $ H.toHtml (show h)
            void $ " hour "
            H.select H.! A.id (H.toValue scheduleCreatorMinuteID) $
              forM_ ([0..59] :: [Int]) $ \m ->
                if  m == 30 -- Default
                then H.option H.! A.value "30" H.! A.selected "selected" $ void "30"
                else H.option H.! A.value (H.toValue . show $ m) $ H.toHtml (show m)
            void $ " minutes"
            H.br >> H.br
            void $ "activate scene "
            H.select H.! A.id (H.toValue scheduleCreatorSceneID) $
              forM_ sceneNames $ \s ->
                H.option H.! A.value (H.toValue s) $ H.toHtml s
            void $ " on"
            H.br >> H.br
            forM_ days $ \day -> do
              H.input H.! A.type_ "checkbox"
                      H.! A.id (H.toValue $ scheduleCreatorDayID day)
                      H.! A.checked "checked"
              H.toHtml $ day <> " "
          H.br
          H.div H.! A.class_ "input-group" $ do -- Name & 'Create' button
            H.input H.! A.type_ "text"
                    H.! A.class_ "form-control input-sm"
                    H.! A.maxlength "30"
                    H.! A.placeholder "Name"
                    H.! A.id (H.toValue scheduleCreatorNameID)
            H.span H.! A.class_ "input-group-btn" $
              H.button H.! A.class_ "btn btn-sm btn-info"
                       H.! A.id (H.toValue scheduleCreatorBtnID)
                       $ "Create"
      -- Group show / hide widget and 'New' button
      H.div H.! A.class_ "text-center" $
        H.div H.! A.class_ "btn-group-vertical btn-group-sm"
              H.! A.style "margin-top: 9px;" $ do
          H.button H.! A.type_ "button"
                   H.! A.class_ "btn btn-info"
                   H.! A.id (H.toValue schedulesTileHideShowBtnID)
                   $ H.toHtml (if grpShown then grpShownCaption else grpHiddenCaption)
          H.button H.! A.type_ "button"
                   H.! A.class_ "btn btn-info"
                   H.! A.onclick
                     ( H.toValue $
                         "getElementById('" <> scheduleCreatorID <>"').style.display = 'block'"
                     )
                   $ "New"
  addPageUIAction $ do
      -- Create a new scene
      getElementByIdSafe window scheduleCreatorBtnID >>= \btn ->
          on UI.click btn $ \_ -> do
              -- Schedule name
              scheduleName <- -- Trim, autocorrect adds spaces
                              T.unpack . T.strip . T.pack <$>
                                  (get value =<< getElementByIdSafe window scheduleCreatorNameID)
              -- Scene name
              sceneName    <- get value =<< getElementByIdSafe window scheduleCreatorSceneID
              -- Hour
              hour         <- fromMaybe 16 . readMaybe <$>
                                  (get value =<< getElementByIdSafe window scheduleCreatorHourID)
              -- Minute
              minute       <- fromMaybe 30 . readMaybe <$>
                                  (get value =<< getElementByIdSafe window scheduleCreatorMinuteID)
              -- Active days
              daysActive <- forM days $ \day ->do
                  get UI.checked =<< getElementByIdSafe window (scheduleCreatorDayID day)
              -- Don't bother creating schedules without name or active days
              -- TODO: Show an error message to indicate what the problem is
              unless (null scheduleName || or daysActive == False) $ do
                  liftIO $ createSchedule _aePC
                                          scheduleName
                                          sceneName
                                          hour
                                          minute
                                          daysActive
                  traceS TLInfo $ printf
                      "Created new schedule '%s' triggering at %i:%i scene '%s' on %s"
                      scheduleName
                      hour
                      minute
                      sceneName
                      ( concatMap (\(i, active) -> if   active
                                                   then days !! i
                                                   else ""
                                  ) $ zip [0..] daysActive
                      )
                  reloadPage
      -- Show / hide schedules
      getElementByIdSafe window schedulesTileHideShowBtnID >>= \btn ->
          on UI.click btn $ \_ -> do
              -- Start a transaction, flip the shown state of the group by adding /
              -- removing it from the visible list and return a list of UI actions to
              -- update the UI with the changes
              uiActions <- liftIO . atomically $ do
                  pc <- readTVar _aePC
                  let grpShownNow = pc
                                  ^. pcUserData
                                   . at userID
                                   . non defaultUserData
                                   . udVisibleGroupNames
                                   . to (HS.member schedulesTileGroupName)
                  writeTVar _aePC
                      $  pc
                         -- Careful not to use 'non' here, would otherwise remove the
                         -- entire user when removing the last HS entry, confusing...
                      &  pcUserData . at userID . _Just . udVisibleGroupNames
                      %~ ( if   grpShownNow
                           then HS.delete schedulesTileGroupName
                           else HS.insert schedulesTileGroupName
                         )
                  return $
                      ( if   grpShownNow
                        then [ void $ element btn & set UI.text grpHiddenCaption ]
                        else [ void $ element btn & set UI.text grpShownCaption  ]
                      ) <>
                      -- Hide or show all members of the schedule group. We do this by
                      -- identifying them by a special CSS class instead of just setting
                      -- them from names in our schedule database. This ensures we don't try
                      -- to set a non-existing element in case another users has created
                      -- a schedule not yet present in our DOM as a tile
                      ( [ getElementsByClassName window scheduleTilesClass >>= \elems ->
                            forM_ elems $ \e ->
                              element e & set style
                                [ if   grpShownNow
                                  then ("display", "none" )
                                  else ("display", "block")
                                ]
                        ]
                      )
              sequence_ uiActions
  return grpShown

-- Add a tile for an individual schedule
--
-- TODO: Provide a way to edit or update schedules
-- TODO: It should be possible to pause / disable schedules
--
addScheduleTile :: ScheduleName -> Schedule -> Bool -> Window -> PageBuilder ()
addScheduleTile scheduleName schedule shown window = do
  AppEnv { .. } <- ask
  return ()
  {-
  let deleteConfirmDivID = "scene-" <> sceneName <> "-confirm-div"
      deleteConfirmBtnID = "scene-" <> sceneName <> "-confirm-btn"
      circleContainerID  = "scene-" <> sceneName <> "-circle-container"
      lightsOn           = sum . flip map scene $ \(_, lgtSt) ->
                               maybe 0 (\case (Bool True) -> 1; _ -> 0) $
                                   HM.lookup "on" lgtSt
      lightsOff          = length scene - lightsOn
      styleCircleNoExist = "background: white; border-color: lightgrey;" :: String
  -- Get relevant bridge information, assume it won't change over the lifetime of the connection
  bridgeIP     <- liftIO . atomically $ (^. pcBridgeIP    ) <$> readTVar _aePC
  bridgeUserID <- liftIO . atomically $ (^. pcBridgeUserID) <$> readTVar _aePC
  -- Tile
  addPageTile $
    H.div H.! A.class_ (H.toValue $ "thumbnail " <> sceneTilesClass)
          H.! A.style  ( H.toValue $ ( if   shown
                                       then "display: block;"
                                       else "display: none;"
                                       :: String
                                     )
                       )
          $ do
      -- Caption
      H.div H.! A.class_ "light-caption small"
            H.! A.style "cursor: default;"
            $ H.toHtml sceneName
      -- Scene light preview (TODO: Maybe use actual light icons instead of circles?)
      H.div H.! A.class_ "circle-container"
            H.! A.id (H.toValue circleContainerID) $ do
        forM_ (take 9 $ scene) $ \(_, lgSt) ->
          let col :: String
              col | HM.lookup "on" lgSt == Just (Bool False) = "background: black;"
                  | Just (Array vXY)         <- HM.lookup "xy" lgSt,
                    [Number xXY, Number yXY] <- V.toList vXY =
                      printf "background: %s;" . htmlColorFromLightState $
                        -- Build mock LightState
                        LightState True
                                   Nothing
                                   Nothing
                                   Nothing
                                   ((\(String t) -> T.unpack t) <$> HM.lookup "effect" lgSt)
                                   (Just [realToFrac xXY, realToFrac yXY])
                                   Nothing
                                   "none"
                                   Nothing
                                   True
                  | otherwise = "background: white;"
          in  H.div H.! A.class_ "circle"
                    H.! A.style (H.toValue col)
                    $ return ()
        forM_ [0..8 - length scene] $ \_ -> -- Fill remainder with grey circles
          H.div H.! A.class_ "circle"
                H.! A.style (H.toValue styleCircleNoExist)
                $ return ()
      -- Light count
      H.div H.! A.class_ "text-center" $ do
        H.h6 $
          H.small $
            H.toHtml $ (printf "%i On, %i Off" lightsOn lightsOff :: String)
        -- Delete button
        H.div H.! A.id (H.toValue deleteConfirmDivID)
              H.! A.style "display: none;" $
          H.button H.! A.type_ "button"
                   H.! A.id (H.toValue deleteConfirmBtnID)
                   H.! A.class_ "btn btn-danger btn-sm"
                   $ "Confirm"
        H.button H.! A.type_ "button"
                 H.! A.class_ "btn btn-danger btn-sm"
                 H.! A.onclick ( H.toValue $ "this.style.display = 'none'; getElementById('"
                                             <> deleteConfirmDivID <> "').style.display = 'block';"
                               )
                 $ "Delete"
  addPageUIAction $ do
      -- Activate
      --
      -- TODO: Maybe add a rate limiter for this? Spamming the activate button for a scene
      --       with lots of lights can really overwhelm the bridge
      --
      getElementByIdSafe window circleContainerID >>= \btn ->
          on UI.click btn $ \_ ->
              lightsSetScene bridgeIP bridgeUserID scene
      -- Delete
      getElementByIdSafe window deleteConfirmBtnID >>= \btn ->
          on UI.click btn $ \_ -> do
              liftIO . atomically $ do
                  pc <- readTVar _aePC
                  writeTVar _aePC $ pc & pcScenes . iat sceneName #~ Nothing
              reloadPage
    -}
