--[[
ReaScript Name: Mark Breath (Create Check Breath region)
Author: David Winter
Version: 1.0

Description:
  - Intended for use when a breath reduction goes wrong and you want to:
      * remove the breath marker item (so it won't be batch-processed later), BUT
      * leave a "Check Breath" region for returning to during editing.
  - Finds the current breath item (prefer item whose start is at the edit cursor; falls back to item containing cursor).
  - Creates a deduped region named "Check Breath" spanning the original breath item window.
  - Deletes the current breath item.
  - Updates a single checkpoint marker: "Breaths checked up to here" (removes any previous one).
  - Auditions the next breath item (1.0s before to 0.25s after), then stops and returns cursor to the next breath start.
  - If no next breath item is found, zooms out to show the whole project.
]]

local VALID_BREATH_NAMES = {
  ["breath"]   = true,
  ["breaths"]  = true,
  ["breathe"]  = true,
  ["breathes"] = true
}

-- Playback (seconds)
local PLAY_BEFORE = 1.0
local PLAY_AFTER  = 0.25

-- Checkpoint marker
local CHECKPOINT_MARKER_NAME  = "Breaths checked up to here"
local CHECKPOINT_MARKER_COLOR = reaper.ColorToNative(0, 255, 0) | 0x1000000

-- Region configuration
local REGION_NAME = "Check Breath"
local REGION_R, REGION_G, REGION_B = 160, 210, 255 -- light blue (matches Check Click)

-- Action IDs
local ACTION_TRANSPORT_PLAY  = 1007
local ACTION_TRANSPORT_STOP  = 1016
local ACTION_ZOOM_OUT        = 40042

-- Helpers
local function getBreathTrack()
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    name = (name or ""):lower()
    if VALID_BREATH_NAMES[name] then return tr end
  end
  return nil
end

local function floatsEqual(a, b, eps)
  eps = eps or 1e-6
  return math.abs(a - b) <= eps
end

local function regionColor()
  local c = reaper.ColorToNative(REGION_R, REGION_G, REGION_B)
  return c | 0x1000000
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

local function deleteBreathCheckpointMarkers()
  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = num_markers + num_regions
  local to_delete = {}

  for i = 0, total - 1 do
    local retval, isrgn, pos, rgnend, name, idx = reaper.EnumProjectMarkers3(0, i)
    if retval and (not isrgn) and name == CHECKPOINT_MARKER_NAME then
      table.insert(to_delete, idx)
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

local function itemBounds(item)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return pos, pos + len
end

local function getBreathItemAtOrContainingCursor(track, cursor_pos)
  local tol = 0.0005
  local item_count = reaper.CountTrackMediaItems(track)

  -- Prefer an item that STARTS at cursor (matches existing breath scripts)
  for i = 0, item_count - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    if math.abs(p - cursor_pos) < tol then
      return it
    end
  end

  -- Fallback: item that contains cursor
  for i = 0, item_count - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local l = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    local e = p + l
    if (cursor_pos >= p - tol) and (cursor_pos < e - tol) then
      return it
    end
  end

  return nil
end

local function getNextBreathItemAfterPos(track, pos)
  local best_item = nil
  local best_pos  = nil

  local item_count = reaper.CountTrackMediaItems(track)
  for i = 0, item_count - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    if p >= pos then
      if (best_pos == nil) or (p < best_pos) then
        best_pos  = p
        best_item = it
      end
    end
  end

  return best_item
end

local function stopPlaybackAndResetCursorAt(target_time, reset_pos)
  local function check()
    if reaper.GetPlayPosition() >= target_time then
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
  reaper.PreventUIRefresh(1)

  local breathTrack = getBreathTrack()
  if not breathTrack then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Mark Breath", -1)
    reaper.ShowMessageBox("No valid Breath track found.", "Error", 0)
    return
  end

  local cursor_pos = reaper.GetCursorPosition()
  local breathItem = getBreathItemAtOrContainingCursor(breathTrack, cursor_pos)
  if not breathItem then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Mark Breath", -1)
    reaper.ShowMessageBox("No breath item found at (or containing) the edit cursor.", "Error", 0)
    return
  end

  local breathStart, breathEnd = itemBounds(breathItem)

  -- Create the "Check Breath" region first (deduped)
  addRegionDedup(REGION_NAME, breathStart, breathEnd)

  -- Delete the breath item
  reaper.DeleteTrackMediaItem(breathTrack, breathItem)

  -- Update checkpoint at the breath you just processed
  setBreathCheckpointAt(breathStart)

  -- Find and audition the next breath
  local next_item = getNextBreathItemAfterPos(breathTrack, cursor_pos)
  if not next_item then
    reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)
    reaper.Main_OnCommand(ACTION_ZOOM_OUT, 0)
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Mark Breath", -1)
    reaper.UpdateArrange()
    return
  end

  local next_start, next_end = itemBounds(next_item)
  local play_start = math.max(0, next_start - PLAY_BEFORE)
  local play_end   = next_end + PLAY_AFTER

  reaper.GetSet_LoopTimeRange(true, false, play_start, play_end, false)
  reaper.SetEditCurPos(play_start, false, false)
  reaper.Main_OnCommand(ACTION_TRANSPORT_PLAY, 0)
  stopPlaybackAndResetCursorAt(play_end, next_start)

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Mark Breath", -1)
  reaper.UpdateArrange()
end

run()
