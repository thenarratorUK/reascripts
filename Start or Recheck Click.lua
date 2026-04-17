-- @description Start or Recheck Click
-- @version 1.1
-- @author David Winter
--[[
ReaScript Name: Start or Recheck Click
Author: David Winter
Version: 1.1

Description:
  - Finds the next item on the Clicks track (named Click or Clicks).
  - If a checkpoint marker exists ("Clicks detected up to here"), starts from that position unless the cursor is later.
  - If the edit cursor is currently on a click-marker item, rechecks that item.
  - Selects that click-marker item.
  - Plays from 1 second before to 0.25 seconds after the item.
  - Stops playback at the correct time.
  - Then returns the edit cursor to the item's start.
  - If no next item is found, zooms out to show the entire project.
]]

-- Track names considered valid for click detection
local VALID_CLICK_NAMES = {
  ["click"]  = true,
  ["clicks"] = true
}

local PLAY_BEFORE = 1.0
local PLAY_AFTER  = 0.25

-- Action IDs
local ACTION_TRANSPORT_PLAY  = 1007
local ACTION_TRANSPORT_STOP  = 1016
local ACTION_ZOOM_TO_PROJECT = 40295

-- Click progress checkpoint marker helpers (optional)
local CHECKPOINT_MARKER_NAME = "Clicks detected up to here"

local function getClickCheckpointPos()
  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = num_markers + num_regions
  local best_pos = nil

  for i = 0, total - 1 do
    local retval, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers3(0, i)
    if retval and (not isrgn) and name == CHECKPOINT_MARKER_NAME then
      if (best_pos == nil) or (pos > best_pos) then
        best_pos = pos
      end
    end
  end

  return best_pos
end

local function getClicksTrack()
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local retval, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if name and VALID_CLICK_NAMES[name:lower()] then
      return track
    end
  end
  return nil
end

local function getNextItemAfterCursor(track, cursor_pos)
  local best_item = nil
  local best_pos = nil

  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")

    if item_pos >= cursor_pos then
      if (not best_pos) or (item_pos < best_pos) then
        best_pos = item_pos
        best_item = item
      end
    end
  end

  return best_item
end

-- If the cursor is currently inside an item on the clicks track, return that item (recheck behavior).
local function getItemUnderCursor(track, cursor_pos)
  local best_item = nil
  local best_start = nil

  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = item_pos + item_len

    if cursor_pos >= item_pos and cursor_pos <= item_end then
      -- If overlaps exist, prefer the one with the latest start <= cursor (most "specific" under cursor).
      if (not best_start) or (item_pos > best_start) then
        best_start = item_pos
        best_item = item
      end
    end
  end

  return best_item
end

local function selectOnlyItem(item)
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
end

local function stopPlaybackAndResetCursorAt(stop_pos, reset_pos, keep_selected_item)
  local function check()
    if reaper.GetPlayPosition() >= stop_pos then
      reaper.Main_OnCommand(ACTION_TRANSPORT_STOP, 0)
      if reset_pos then
        reaper.SetEditCurPos(reset_pos, true, false)
      end
      if keep_selected_item then
        selectOnlyItem(keep_selected_item)
      end
    else
      reaper.defer(check)
    end
  end
  check()
end

local function startOrRecheck()
  reaper.Undo_BeginBlock()

  local clicksTrack = getClicksTrack()
  if not clicksTrack then
    reaper.ShowMessageBox("No valid Clicks track found.", "Error", 0)
    reaper.Undo_EndBlock("Start or Recheck Click", -1)
    return
  end

  local original_cursor_pos = reaper.GetCursorPosition()

  -- First priority: if cursor is currently on a click item, recheck that item.
  local clickItem = getItemUnderCursor(clicksTrack, original_cursor_pos)

  -- Otherwise: find next item, respecting checkpoint marker.
  if not clickItem then
    local cursor_pos = original_cursor_pos

    local checkpoint_pos = getClickCheckpointPos()
    if checkpoint_pos and (cursor_pos < checkpoint_pos) then
      cursor_pos = checkpoint_pos
    end

    clickItem = getNextItemAfterCursor(clicksTrack, cursor_pos)
  end

  if not clickItem then
    reaper.Main_OnCommand(ACTION_ZOOM_TO_PROJECT, 0)
    reaper.Undo_EndBlock("Start or Recheck Click", -1)
    return
  end

  selectOnlyItem(clickItem)

  local item_pos = reaper.GetMediaItemInfo_Value(clickItem, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(clickItem, "D_LENGTH")

  local play_start = math.max(0, item_pos - PLAY_BEFORE)
  local play_end = item_pos + item_len + PLAY_AFTER

  reaper.GetSet_LoopTimeRange(true, false, play_start, play_end, false)
  reaper.SetEditCurPos(play_start, false, false)
  reaper.Main_OnCommand(ACTION_TRANSPORT_PLAY, 0)

  stopPlaybackAndResetCursorAt(play_end, item_pos, clickItem)

  reaper.Undo_EndBlock("Start or Recheck Click", -1)
end

startOrRecheck()
