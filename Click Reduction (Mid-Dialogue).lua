-- @description Click Reduction B (RX De-click Take FX)
-- @version 1.1
-- @author David Winter
--[[
ReaScript Name: Click Reduction B (RX De-click Take FX)
Author: David Winter
Version: 1.1
Description:
  - Requires exactly one selected item on the Clicks track (named Click or Clicks).
  - Uses the selected click-marker item's position/length as the click window.
  - Finds the overlapping source track (excluding Room Tone), and isolates a padded window by:
      * split at (start - PAD_SECONDS) using action 40757
      * split and select item left of cursor at (end + PAD_SECONDS) using action 43178
  - Applies Take FX: RX 11 De-click, preset: "Click Reduction" to the isolated padded segment.
  - Adds a region named "Check Click" (light blue), covering the ORIGINAL click window.
    If an identical region already exists (same name + start + end), it is not duplicated.
  - Creates the region, deletes the current click marker item, then auditions the next click item (selected).

Notes:
  - RX_FX_NAME must match the plug-in name in the REAPER FX browser on this system.
  - The preset name must be available via REAPER's preset system for that plug-in.
]]

-- Track names considered valid for click markers (case-insensitive)
local VALID_CLICK_NAMES = {
  ["click"]  = true,
  ["clicks"] = true
}

-- Tracks whose names contain this substring are excluded when searching for source audio
local ROOM_TONE_NAME_SUBSTR = "room tone"

-- Padding applied to the processing window (seconds)
local PAD_SECONDS = 0.00 -- 100ms on each side

-- Take FX configuration
local RX_FX_NAME     = "RX 11 De-click"
local RX_PRESET_NAME = "Click Reduction"

-- Region configuration
local REGION_NAME = "Check Click"
local REGION_R, REGION_G, REGION_B = 160, 210, 255 -- light blue

-- Audition range (seconds)
local PLAY_BEFORE = 1.0
local PLAY_AFTER  = 0.25

-- Action IDs (REAPER)
local ACTION_UNSELECT_ALL_ITEMS     = 40289
local ACTION_SPLIT_SELECT_RIGHT_ITEM = 40759
local ACTION_SPLIT_SELECT_LEFT_ITEM = 43178 -- Split and select item left of cursor
local ACTION_TRANSPORT_PLAY         = 1007
local ACTION_TRANSPORT_STOP         = 1016

-- Helpers
local function getTrackName(track)
  local retval, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if retval and name then return name end
  return ""
end

local function isClicksTrack(track)
  local name = getTrackName(track):lower()
  return VALID_CLICK_NAMES[name] == true
end

local function isRoomToneTrack(track)
  local name = getTrackName(track):lower()
  return name:find(ROOM_TONE_NAME_SUBSTR, 1, true) ~= nil
end

local function getSelectedClickItem()
  if reaper.CountSelectedMediaItems(0) ~= 1 then
    return nil, "Select exactly one click marker item on the Clicks track."
  end

  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    return nil, "No selected item."
  end

  local tr = reaper.GetMediaItem_Track(item)
  if not tr or not isClicksTrack(tr) then
    return nil, "Selected item is not on the Clicks track."
  end

  return item, nil
end

local function itemBounds(item)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return pos, pos + len
end

local function overlaps(item, t0, t1)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local e = pos + len
  return (e > t0) and (pos < t1)
end

local function findSourceItemForWindow(t0, t1, clicksTrack)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if tr ~= clicksTrack and not isRoomToneTrack(tr) then
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        if overlaps(it, t0, t1) then
          return tr, it
        end
      end
    end
  end
  return nil, nil
end

local function selectOnlyItem(item)
  reaper.Main_OnCommand(ACTION_UNSELECT_ALL_ITEMS, 0)
  reaper.SetMediaItemSelected(item, true)
end

local function getNextClickItem(clicksTrack, afterTime)
  local bestItem, bestPos = nil, nil
  for i = 0, reaper.CountTrackMediaItems(clicksTrack) - 1 do
    local it = reaper.GetTrackMediaItem(clicksTrack, i)
    local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    if pos >= afterTime then
      if not bestPos or pos < bestPos then
        bestPos = pos
        bestItem = it
      end
    end
  end
  return bestItem
end

local function stopPlaybackAndAdvanceAt(playEnd, nextClickItem)
  local function check()
    if reaper.GetPlayPosition() >= playEnd then
      reaper.Main_OnCommand(ACTION_TRANSPORT_STOP, 0)
      if nextClickItem then
        selectOnlyItem(nextClickItem)
        local npos = reaper.GetMediaItemInfo_Value(nextClickItem, "D_POSITION")
        reaper.SetEditCurPos(npos, true, false)
      end
    else
      reaper.defer(check)
    end
  end
  check()
end

local function stopPlaybackAndResetCursorAt(stopPos, resetPos)
  local function check()
    if reaper.GetPlayPosition() >= stopPos then
      reaper.Main_OnCommand(ACTION_TRANSPORT_STOP, 0)
      reaper.SetEditCurPos(resetPos, true, false)
    else
      reaper.defer(check)
    end
  end
  check()
end

local function regionColor()
  local c = reaper.ColorToNative(REGION_R, REGION_G, REGION_B)
  return c | 0x1000000
end

local function floatsEqual(a, b, eps)
  eps = eps or 1e-6
  return math.abs(a - b) <= eps
end

local function regionExists(name, startPos, endPos)
  local _, numMarkers, numRegions = reaper.CountProjectMarkers(0)
  local total = numMarkers + numRegions
  for i = 0, total - 1 do
    local retval, isrgn, pos, rgnend, rname = reaper.EnumProjectMarkers3(0, i)
    if retval and isrgn then
      if rname == name and floatsEqual(pos, startPos) and floatsEqual(rgnend, endPos) then
        return true
      end
    end
  end
  return false
end

local function addRegionDedup(name, startPos, endPos)
  if regionExists(name, startPos, endPos) then return end
  reaper.AddProjectMarker2(0, true, startPos, endPos, name, -1, regionColor())
end

local function applyRxTakeFx(item)
  local take = reaper.GetActiveTake(item)
  if not take then return false, "No active take on the isolated segment." end

  local fx = reaper.TakeFX_AddByName(take, RX_FX_NAME, 1)
  if fx < 0 then
    return false, "Could not add take FX '" .. RX_FX_NAME .. "'. Check RX_FX_NAME."
  end

  local ok = reaper.TakeFX_SetPreset(take, fx, RX_PRESET_NAME)
  if not ok then
    return false, "Could not set preset '" .. RX_PRESET_NAME .. "'."
  end

  return true
end

-- Main
local function run()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local clickItem, err = getSelectedClickItem()
  if not clickItem then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Click Reduction B (RX Take FX)", -1)
    reaper.ShowMessageBox(err or "Invalid selection.", "Error", 0)
    return
  end

  local clicksTrack = reaper.GetMediaItem_Track(clickItem)
  local clickStart, clickEnd = itemBounds(clickItem)

  local sourceTrack, sourceItem = findSourceItemForWindow(clickStart, clickEnd, clicksTrack)
  if not sourceItem then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Click Reduction B (RX Take FX)", -1)
    reaper.ShowMessageBox("No overlapping source audio found for this click.", "Error", 0)
    return
  end

  local procStart = math.max(0, clickStart - PAD_SECONDS)
  local procEnd   = clickEnd + PAD_SECONDS

  -- Split/select segment using actions (same approach as Breath Reduction.lua)
  reaper.Main_OnCommand(ACTION_UNSELECT_ALL_ITEMS, 0)
  reaper.SetOnlyTrackSelected(sourceTrack)
  reaper.SetMediaItemSelected(sourceItem, true)
  
  reaper.SetEditCurPos(procStart, false, false)
  reaper.Main_OnCommand(ACTION_SPLIT_SELECT_RIGHT_ITEM, 0)
  
  reaper.SetEditCurPos(procEnd, false, false)
  reaper.Main_OnCommand(ACTION_SPLIT_SELECT_LEFT_ITEM, 0)

  local segItem = reaper.GetSelectedMediaItem(0, 0)
  if not segItem then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Click Reduction B (RX Take FX)", -1)
    reaper.ShowMessageBox("Failed to select the isolated click segment.", "Error", 0)
    return
  end

  local ok, fxErr = applyRxTakeFx(segItem)
  if not ok then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Click Reduction B (RX Take FX)", -1)
    reaper.ShowMessageBox(fxErr or "Failed to apply RX take FX.", "Error", 0)
    return
  end

  -- Region over the original click window (not padded), deduped
  addRegionDedup(REGION_NAME, clickStart, clickEnd)

  -- Determine the next click BEFORE deleting the current click marker item
  local nextClick = getNextClickItem(clicksTrack, clickEnd + 1e-6)

  -- Delete the current click marker item once the region has been created
  reaper.DeleteTrackMediaItem(clicksTrack, clickItem)

  -- If there's no next click, finish without auditioning
  if not nextClick then
    reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)
    reaper.SetEditCurPos(clickEnd, true, false)
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Click Reduction B (RX Take FX)", -1)
    reaper.UpdateArrange()
    return
  end

  -- Audition the NEXT click (and keep it selected afterwards)
  selectOnlyItem(nextClick)
  local nextStart, nextEnd = itemBounds(nextClick)

  local playStart = math.max(0, nextStart - PLAY_BEFORE)
  local playEnd   = nextEnd + PLAY_AFTER

  reaper.GetSet_LoopTimeRange(true, false, playStart, playEnd, false)
  reaper.SetEditCurPos(playStart, false, false)
  reaper.Main_OnCommand(ACTION_TRANSPORT_PLAY, 0)
  stopPlaybackAndResetCursorAt(playEnd, nextStart)

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Click Reduction B (RX Take FX)", -1)
  reaper.UpdateArrange()
end

run()
