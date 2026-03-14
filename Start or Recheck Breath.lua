--[[
  Start or Recheck Breath Script for REAPER
  Author: David Winter
  Version: 1.2

  Description:
  - Finds the next item on the "Breath" track (named Breath, Breaths, Breathe, or Breathes)
  - Moves the edit cursor to its start
  - Plays from 1 second before to 1 second after the item
  - Stops playback at the correct time
  - Then returns the edit cursor to the item’s start
  - If a checkpoint marker exists ("Breaths checked up to here"), start from that position unless the cursor is later
  - If no next item is found
    - Zooms out to show the entire project

  Intended for use when starting breath-checking, or rechecking the current breath.
]]

-- Find Breath track by acceptable names (case-insensitive)
local ACCEPTED_BREATH_NAMES = {
  ["breath"] = true,
  ["breaths"] = true,
  ["breathe"] = true,
  ["breathes"] = true
}

local function getBreathTrack()
  local trackCount = reaper.CountTracks(0)
  for i = 0, trackCount - 1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(track)
    name = (name or ""):match("^%s*(.-)%s*$")
    if name and ACCEPTED_BREATH_NAMES[name:lower()] then
      return track
    end
  end
  return nil
end

-- Breath progress checkpoint marker helpers (optional)
local UPDATE_CHECKPOINT_ON_START_OR_RECHECK = false  -- set true if you want this script to update the checkpoint marker
local CHECKPOINT_MARKER_NAME = "Breaths checked up to here"
local CHECKPOINT_MARKER_COLOR = reaper.ColorToNative(0, 255, 0) | 0x1000000

local function deleteBreathCheckpointMarkers()
  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = num_markers + num_regions
  local to_delete = {}
  for i = 0, total - 1 do
    local retval, isrgn, pos, rgnend, name, markrgnindexnumber, color = reaper.EnumProjectMarkers3(0, i)
    if retval and (not isrgn) and name == CHECKPOINT_MARKER_NAME then
      table.insert(to_delete, markrgnindexnumber)
    end
  end
  for i = #to_delete, 1, -1 do
    reaper.DeleteProjectMarker(0, to_delete[i], false)
  end
end

local function setBreathCheckpointAt(pos)
  deleteBreathCheckpointMarkers()
  reaper.AddProjectMarker2(0, false, pos, 0, CHECKPOINT_MARKER_NAME, -1, CHECKPOINT_MARKER_COLOR)
end

local function getBreathCheckpointPos()
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

-- Find the next item at or after the cursor (>= cursor_pos)
local function getNextItemAfterCursor(track, cursor_pos)
  local item_count = reaper.CountTrackMediaItems(track)
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    if item_pos >= cursor_pos then
      return item
    end
  end
  return nil
end

local function stopPlaybackAndResetCursorAt(target_time, reset_pos)
  local function check()
    if reaper.GetPlayPosition() >= target_time then
      reaper.Main_OnCommand(1016, 0) -- Stop
      reaper.SetEditCurPos(reset_pos, true, false)
      return
    end
    reaper.defer(check)
  end
  reaper.defer(check)
end

local function startOrRecheck()
  reaper.Undo_BeginBlock()

  local breathTrack = getBreathTrack()
  if not breathTrack then
    reaper.ShowMessageBox("No valid Breath track found.", "Error", 0)
    return
  end

  local cursor_pos = reaper.GetCursorPosition()

  -- If a checkpoint marker exists, don't start earlier than it.
  local checkpoint_pos = getBreathCheckpointPos()
  if checkpoint_pos and (cursor_pos < checkpoint_pos) then
    cursor_pos = checkpoint_pos
  end

  local item = getNextItemAfterCursor(breathTrack, cursor_pos)

  if not item then
    -- No more items – zoom out
    reaper.Main_OnCommand(40042, 0)
    return
  end

  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  if UPDATE_CHECKPOINT_ON_START_OR_RECHECK then
    setBreathCheckpointAt(item_pos)
  end

  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local play_start = math.max(0, item_pos - 1)
  local play_end = item_pos + item_len + 0.25

  -- Set time selection
  reaper.GetSet_LoopTimeRange(true, false, play_start, play_end, false)

  -- Move play cursor and begin playback
  reaper.SetEditCurPos(play_start, false, false)
  reaper.Main_OnCommand(1007, 0) -- Play

  -- Schedule stop and reset
  stopPlaybackAndResetCursorAt(play_end, item_pos)

  reaper.Undo_EndBlock("Start or Recheck Breath", -1)
end

startOrRecheck()