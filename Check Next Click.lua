-- @description Check Next Click
-- @version 1.0
-- @author David Winter
--[[
ReaScript Name: Check Next Click
Author: David Winter
Version: 1.0

Description:
  - Intended for use when the currently auditioned click marker is either:
      * not a real click, or
      * has already been fixed (e.g. via Click Reduction (Silence))
  - Deletes the current click marker item.
  - Updates a single checkpoint marker: "Clicks detected up to here" (removes any previous one).
  - Selects the next click marker item and auditions it (1.0s before to 0.25s after).
  - Stops playback at the correct time, then returns the edit cursor to the next click start.
  - If no next click item is found, zooms out to show the whole project.
]]

-- Track names considered valid for click detection
local VALID_CLICK_NAMES = {
  ["click"]  = true,
  ["clicks"] = true
}

local PLAY_BEFORE = 1.0
local PLAY_AFTER  = 0.25

-- Checkpoint marker
local CHECKPOINT_MARKER_NAME  = "Clicks detected up to here"
local CHECKPOINT_MARKER_COLOR = reaper.ColorToNative(160, 210, 255) | 0x1000000

-- Action IDs
local ACTION_TRANSPORT_PLAY   = 1007
local ACTION_TRANSPORT_STOP   = 1016
local ACTION_ZOOM_TO_PROJECT  = 40295

local function getClicksTrack()
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if name and VALID_CLICK_NAMES[name:lower()] then
      return tr
    end
  end
  return nil
end

local function selectOnlyItem(item)
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
end

local function getSelectedClickItem()
  if reaper.CountSelectedMediaItems(0) ~= 1 then return nil end
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then return nil end

  local tr = reaper.GetMediaItem_Track(item)
  if not tr then return nil end

  local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  if name and VALID_CLICK_NAMES[name:lower()] then
    return item
  end

  return nil
end

local function getNextItemAfterTime(track, t)
  local best_item = nil
  local best_pos = nil

  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    if pos > t then
      if not best_pos or pos < best_pos then
        best_pos = pos
        best_item = item
      end
    end
  end

  return best_item
end

local function deleteCheckpointMarkers()
  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = num_markers + num_regions
  local to_delete = {}

  for i = 0, total - 1 do
    local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers3(0, i)
    if retval and (not isrgn) and name == CHECKPOINT_MARKER_NAME then
      table.insert(to_delete, markrgnindexnumber)
    end
  end

  for i = #to_delete, 1, -1 do
    reaper.DeleteProjectMarker(0, to_delete[i], false)
  end
end

local function setCheckpointAt(pos)
  deleteCheckpointMarkers()
  reaper.AddProjectMarker2(0, false, pos, 0, CHECKPOINT_MARKER_NAME, -1, CHECKPOINT_MARKER_COLOR)
end

local function stopPlaybackAndResetCursorAt(stop_pos, reset_pos)
  local function check()
    if reaper.GetPlayPosition() >= stop_pos then
      reaper.Main_OnCommand(ACTION_TRANSPORT_STOP, 0)
      reaper.SetEditCurPos(reset_pos, true, false)
    else
      reaper.defer(check)
    end
  end
  check()
end

local function run()
  reaper.Undo_BeginBlock()

  local clicksTrack = getClicksTrack()
  if not clicksTrack then
    reaper.ShowMessageBox("No valid Clicks track found.", "Error", 0)
    reaper.Undo_EndBlock("Check Next Click", -1)
    return
  end

  local cursor_pos = reaper.GetCursorPosition()

  -- Prefer the currently selected click marker item (this should be the one just auditioned)
  local current = getSelectedClickItem()
  if not current then
    -- Fallback: take the next click marker item at/after the cursor as the current one
    -- (useful if something cleared selection unexpectedly)
    for i = 0, reaper.CountTrackMediaItems(clicksTrack) - 1 do
      local it = reaper.GetTrackMediaItem(clicksTrack, i)
      local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      if pos >= cursor_pos then
        current = it
        break
      end
    end
  end

  if not current then
    reaper.Main_OnCommand(ACTION_ZOOM_TO_PROJECT, 0)
    reaper.Undo_EndBlock("Check Next Click", -1)
    return
  end

  local current_pos = reaper.GetMediaItemInfo_Value(current, "D_POSITION")

  -- Update checkpoint before deleting the marker
  setCheckpointAt(current_pos)

  -- Delete current click marker item
  reaper.DeleteTrackMediaItem(clicksTrack, current)

  -- Find next click marker item and audition it
  local nextClick = getNextItemAfterTime(clicksTrack, current_pos + 1e-9)
  if not nextClick then
    reaper.Main_OnCommand(ACTION_ZOOM_TO_PROJECT, 0)
    reaper.Undo_EndBlock("Check Next Click", -1)
    return
  end

  selectOnlyItem(nextClick)

  local item_pos = reaper.GetMediaItemInfo_Value(nextClick, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(nextClick, "D_LENGTH")

  local play_start = math.max(0, item_pos - PLAY_BEFORE)
  local play_end = item_pos + item_len + PLAY_AFTER

  reaper.GetSet_LoopTimeRange(true, false, play_start, play_end, false)
  reaper.SetEditCurPos(play_start, false, false)
  reaper.Main_OnCommand(ACTION_TRANSPORT_PLAY, 0)

  stopPlaybackAndResetCursorAt(play_end, item_pos)

  reaper.Undo_EndBlock("Check Next Click", -1)
end

run()
