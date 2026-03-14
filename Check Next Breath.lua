--[[
  Reject Breath Script for REAPER
  Author: David Winter
  Version: 1.1

  Description:
  - Deletes the breath item at the current edit cursor position
  - Finds the next item on the "Breath" track (named Breath, Breaths, Breathe, or Breathes)
  - Moves the edit cursor to its start
  - Plays from 1 second before to 1 second after the item
  - Stops playback at the correct time
  - Then returns the edit cursor to the item’s start
  - If no next item is found, zooms out to show the entire project

  Intended for use when a breath is rejected and should be removed.
]]

local VALID_BREATH_NAMES = {
  ["breath"] = true,
  ["breaths"] = true,
  ["breathe"] = true,
  ["breathes"] = true
}

local function selectOnlyItem(item)
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
end

local function getBreathTrack()
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if name and VALID_BREATH_NAMES[name:lower()] then
      return track
    end
  end
  return nil
end

-- Breath progress checkpoint marker helpers
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

-- Find the item that starts at the current edit cursor (within small tolerance)
local function getItemAtCursor(track, cursor_pos)
  local item_count = reaper.CountTrackMediaItems(track)
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    if math.abs(item_pos - cursor_pos) < 0.0005 then
      return item
    end
  end
  return nil
end

-- Find the next item after the cursor position
local function getNextItemAfterPos(track, pos)
  local item_count = reaper.CountTrackMediaItems(track)
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    if item_pos >= pos then
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
    else
      reaper.defer(check)
    end
  end
  check()
end

-- Main logic
local function rejectBreath()
  reaper.Undo_BeginBlock()

  local breathTrack = getBreathTrack()
  if not breathTrack then
    reaper.ShowMessageBox("No valid Breath track found.", "Error", 0)
    return
  end

  local cursor_pos = reaper.GetCursorPosition()

  -- Try to delete the item at the edit cursor
  local item_to_delete = getItemAtCursor(breathTrack, cursor_pos)
  local deleted_item_pos = nil
  if item_to_delete then
    deleted_item_pos = reaper.GetMediaItemInfo_Value(item_to_delete, 'D_POSITION')
  end

  if item_to_delete then
    reaper.DeleteTrackMediaItem(breathTrack, item_to_delete)
  end

  if deleted_item_pos then
    -- Mark progress at the breath you just processed (and rejected)
    setBreathCheckpointAt(deleted_item_pos)
  end

  -- Find the next breath item after this position
  local next_item = getNextItemAfterPos(breathTrack, cursor_pos)
  if not next_item then
    -- No more breaths – zoom out
    reaper.Main_OnCommand(40042, 0)
    return
  end
  selectOnlyItem(next_item)
  reaper.UpdateArrange()

  local item_pos = reaper.GetMediaItemInfo_Value(next_item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(next_item, "D_LENGTH")
  local play_start = math.max(0, item_pos - 1)
  local play_end = item_pos + item_len + 0.25

  -- Set time selection
  reaper.GetSet_LoopTimeRange(true, false, play_start, play_end, false)

  -- Move play cursor and begin playback
  reaper.SetEditCurPos(play_start, false, false)
  reaper.Main_OnCommand(1007, 0) -- Play

  -- Schedule stop and reset
  stopPlaybackAndResetCursorAt(play_end, item_pos)

  reaper.Undo_EndBlock("Reject Breath", -1)
end

rejectBreath()