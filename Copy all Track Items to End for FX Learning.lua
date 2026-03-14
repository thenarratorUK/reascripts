-- @description Append selected tracks' items sequentially after project end (excluding Room Tone)
-- @author David Winter
-- @version 1.1
-- @about
--   Finds the last item in the project that is not on the Room Tone track,
--   uses its end as X, then for each selected track:
--     - Adds a 20s gap to X
--     - Copies all that track's items, placing them sequentially from X
--     - Updates X to the end of the last copied item
--   Stops when no selected tracks remain.

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local proj = 0

local function msg(m)
  -- Uncomment for debugging
  -- reaper.ShowConsoleMsg(tostring(m) .. "\n")
end

-- Find Room Tone track by name (contains "room tone" or "roomtone", case-insensitive)
local function find_room_tone_track()
  local track_count = reaper.CountTracks(proj)
  for i = 0, track_count - 1 do
    local tr = reaper.GetTrack(proj, i)
    local _, name = reaper.GetTrackName(tr, "")
    local lname = name:lower()
    if lname:find("room tone") or lname:find("roomtone") then
      return tr
    end
  end
  return nil
end

-- Find the latest end time of any item not on the Room Tone track
local function find_last_item_end_excluding_roomtone(room_tone_tr)
  local item_count = reaper.CountMediaItems(proj)
  local last_end = 0.0

  for i = 0, item_count - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local tr = reaper.GetMediaItem_Track(it)
    if tr ~= room_tone_tr then
      local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      local e = pos + len
      if e > last_end then
        last_end = e
      end
    end
  end

  return last_end
end

-- Count selected tracks in the project
local function count_selected_tracks()
  return reaper.CountSelectedTracks(proj)
end

-- Get the first selected track in track order
local function get_first_selected_track()
  local track_count = reaper.CountTracks(proj)
  for i = 0, track_count - 1 do
    local tr = reaper.GetTrack(proj, i)
    if reaper.IsTrackSelected(tr) then
      return tr
    end
  end
  return nil
end

-- Collect all items on a track, sorted by their original position
local function collect_track_items_sorted(track)
  local items = {}
  local cnt = reaper.CountTrackMediaItems(track)
  for i = 0, cnt - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    items[#items + 1] = { item = it, pos = pos }
  end

  table.sort(items, function(a, b) return a.pos < b.pos end)
  return items
end

-- Clone one item to dest_track at new_pos, preserving everything else via chunk
local function clone_item_to_track_at_pos(src_item, dest_track, new_pos)
  -- Create a new empty item on destination track
  local new_item = reaper.AddMediaItemToTrack(dest_track)

  -- Get full item state chunk from source
  local ok, chunk = reaper.GetItemStateChunk(src_item, "", false)
  if not ok or not chunk or chunk == "" then
    return nil
  end

  -- Replace POSITION in the chunk (first occurrence only)
  chunk = chunk:gsub("POSITION%s+[%-%d%.]+", "POSITION " .. tostring(new_pos), 1)

  -- Remove the GUID line so REAPER assigns a new one automatically
  -- (we strip the token `{...}`; the newline is left intact, which is fine)
  chunk = chunk:gsub("GUID%s+{.-}", "")

  -- Apply chunk to the new item
  reaper.SetItemStateChunk(new_item, chunk, true)

  return new_item
end

------------------------------------------------------------
-- Main
------------------------------------------------------------

local function main()
  local room_tone_tr = find_room_tone_track()
  local X = find_last_item_end_excluding_roomtone(room_tone_tr)

  local gap = 20.0  -- seconds of silence between groups

  while count_selected_tracks() > 0 do
    local track = get_first_selected_track()
    if not track then
      break
    end

    -- Advance X by gap before starting this track's block
    X = X + gap

    -- Collect items on this track in time order
    local items = collect_track_items_sorted(track)

    -- If there are no items, just deselect and continue
    if #items == 0 then
      reaper.SetTrackSelected(track, false)
      goto continue
    end

    local cur_pos = X

    -- Duplicate each item sequentially, with no gaps
    for _, entry in ipairs(items) do
      local src_item = entry.item
      local len = reaper.GetMediaItemInfo_Value(src_item, "D_LENGTH")

      local new_item = clone_item_to_track_at_pos(src_item, track, cur_pos)
      if new_item then
        cur_pos = cur_pos + len
      end
    end

    -- Update X to the end of the last copied item
    X = cur_pos

    -- Deselect this track so we don't process it again
    reaper.SetTrackSelected(track, false)

    ::continue::
  end
end

------------------------------------------------------------
-- Run with undo and UI wrapping
------------------------------------------------------------

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

main()

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Append selected tracks' items after project end (excluding Room Tone)", -1)
