--[[
  Close Gaps in Room Tone Track

  Behaviour:
    - Find the "Room Tone" track by name (case-insensitive, trimmed).
    - If no such track exists, fall back to the first selected track.
    - On that track only:
        (A) Close any positive gap at the very start by shifting all items left
            so the first item starts at 0.0.
        (B) Close any positive gaps between items by pulling later items left so
            each item starts exactly where the previous one ends.
    - Does not affect any other tracks.
]]

local ROOM_TONE_TRACK_NAME = "Room Tone"  -- Change if your track has a different name.
local GAP_THRESHOLD = 0.0005             -- Ignore tiny gaps smaller than this (seconds).

---------------------------------------------------------------------
-- Utility: trim whitespace
---------------------------------------------------------------------
local function trim(s)
  if not s then return "" end
  return s:match("^%s*(.-)%s*$") or ""
end

---------------------------------------------------------------------
-- Find the room tone track:
--   1) By exact name (case-insensitive, trimmed)
--   2) Fallback: first selected track
---------------------------------------------------------------------
local function get_room_tone_track()
  local target = trim(ROOM_TONE_TRACK_NAME):lower()
  local project = 0
  local tr_count = reaper.CountTracks(project)

  if target ~= "" then
    for i = 0, tr_count - 1 do
      local tr = reaper.GetTrack(project, i)
      local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
      name = trim(name):lower()
      if name ~= "" and name == target then
        return tr
      end
    end
  end

  -- Fallback: first selected track, if any
  local sel_count = reaper.CountSelectedTracks(project)
  if sel_count > 0 then
    return reaper.GetSelectedTrack(project, 0)
  end

  return nil
end

---------------------------------------------------------------------
-- Close gaps on a single track by shifting later items left
-- so that each item begins at the end of the previous one.
---------------------------------------------------------------------
local function close_gaps_on_track(tr)
  if not tr then return end

  local item_count = reaper.CountTrackMediaItems(tr)
  if item_count < 1 then return end

  -- NEW: close any positive gap right at the start (before the first item)
  do
    local first_item = reaper.GetTrackMediaItem(tr, 0)
    if first_item then
      local first_pos = reaper.GetMediaItemInfo_Value(first_item, "D_POSITION")
      if first_pos > GAP_THRESHOLD then
        for j = 0, item_count - 1 do
          local it = reaper.GetTrackMediaItem(tr, j)
          local p  = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
          reaper.SetMediaItemInfo_Value(it, "D_POSITION", p - first_pos)
        end
      end
    end
  end

  if item_count < 2 then return end

  -- Items on a track are iterated in track order.
  for i = 0, item_count - 2 do
    local prev_item = reaper.GetTrackMediaItem(tr, i)
    local next_item = reaper.GetTrackMediaItem(tr, i + 1)

    if prev_item and next_item then
      local prev_pos = reaper.GetMediaItemInfo_Value(prev_item, "D_POSITION")
      local prev_len = reaper.GetMediaItemInfo_Value(prev_item, "D_LENGTH")
      local prev_end = prev_pos + prev_len

      local next_pos = reaper.GetMediaItemInfo_Value(next_item, "D_POSITION")
      local gap = next_pos - prev_end

      if gap > GAP_THRESHOLD then
        for j = i + 1, item_count - 1 do
          local it2 = reaper.GetTrackMediaItem(tr, j)
          local p   = reaper.GetMediaItemInfo_Value(it2, "D_POSITION")
          reaper.SetMediaItemInfo_Value(it2, "D_POSITION", p - gap)
        end
      end
    end
  end
end

---------------------------------------------------------------------
-- Main
---------------------------------------------------------------------
reaper.Undo_BeginBlock()

local tr = get_room_tone_track()
if not tr then
  reaper.ShowMessageBox(
    "No track named '" .. ROOM_TONE_TRACK_NAME .. "' found, and no track selected.\n\n" ..
    "Cannot close room tone gaps.",
    "Close Gaps in Room Tone",
    0
  )
  reaper.Undo_EndBlock("Close gaps in Room Tone track (failed: no track)", -1)
  return
end

close_gaps_on_track(tr)

reaper.UpdateArrange()
reaper.Undo_EndBlock("Close gaps in Room Tone track", -1)
