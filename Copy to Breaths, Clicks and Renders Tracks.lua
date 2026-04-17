-- @description Copy to Breaths, Clicks and Renders Tracks
-- @version 1.0
-- @author David Winter
--[[
  DW_Copy Track Items to Breaths/Clicks/Renders + Delete Source Track

  Behaviour:
    - Requires exactly one selected item.
    - Uses the track that selected item is on as the SOURCE track.
    - For every media item on SOURCE track:
        - Copies (duplicates) the item to tracks named:
            "Breaths", "Clicks", "Renders"
          (creates those tracks if missing)
    - After all items are copied, deletes the SOURCE track.

  Notes:
    - If the SOURCE track is itself one of the destination tracks, that destination is skipped.
    - Copies items via state chunk (keeps position/length/takes/source/fades/vol/pan/etc).
    - Strips item/take GUID lines so duplicates don’t share GUIDs.
]]

local DEST_TRACK_NAMES = { "Breaths", "Clicks", "Renders" }

-- ---------------- Helpers ----------------

local function normalize_name(s)
  s = tostring(s or "")
  s = s:lower()
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

local function get_track_name(tr)
  if not tr then return "" end
  local ok, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  if ok then return name or "" end
  return ""
end

local function find_track_by_name(name_exact)
  local target = normalize_name(name_exact)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    if normalize_name(get_track_name(tr)) == target then
      return tr
    end
  end
  return nil
end

local function create_track_named(name_exact)
  local idx = reaper.CountTracks(0) -- append at end
  reaper.InsertTrackAtIndex(idx, true)
  local tr = reaper.GetTrack(0, idx)
  if tr then
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name_exact, true)
  end
  return tr
end

local function find_or_create_track(name_exact)
  local tr = find_track_by_name(name_exact)
  if tr then return tr end
  return create_track_named(name_exact)
end

local function strip_guids_from_item_chunk(chunk)
  -- Remove item GUID line(s) and take GUID line(s) to avoid duplicate GUIDs after cloning.
  -- These typically look like:
  --   IGUID {....}
  --   GUID {....}
  if not chunk or chunk == "" then return chunk end
  chunk = chunk:gsub("\nIGUID%s+%b{}\n", "\n")
  chunk = chunk:gsub("\nGUID%s+%b{}\n", "\n")
  return chunk
end

local function clone_item_to_track(src_item, dest_track)
  if not (src_item and dest_track) then return nil end

  local ok, chunk = reaper.GetItemStateChunk(src_item, "", false)
  if not ok then return nil end

  chunk = strip_guids_from_item_chunk(chunk)

  local new_item = reaper.AddMediaItemToTrack(dest_track)
  if not new_item then return nil end

  reaper.SetItemStateChunk(new_item, chunk, false)
  reaper.UpdateItemInProject(new_item)
  return new_item
end

-- ---------------- Main ----------------

local sel_item = reaper.GetSelectedMediaItem(0, 0)
if not sel_item or reaper.CountSelectedMediaItems(0) ~= 1 then
  reaper.ShowMessageBox("Select exactly ONE item on the source track, then run the script.", "DW Script", 0)
  return
end

local src_track = reaper.GetMediaItemTrack(sel_item)
if not src_track then
  reaper.ShowMessageBox("Could not determine the source track from the selected item.", "DW Script", 0)
  return
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- Ensure destination tracks exist
local dest_tracks = {}
for i = 1, #DEST_TRACK_NAMES do
  dest_tracks[i] = find_or_create_track(DEST_TRACK_NAMES[i])
end

-- Copy all items from source track
local item_count = reaper.CountTrackMediaItems(src_track)
for i = 0, item_count - 1 do
  local it = reaper.GetTrackMediaItem(src_track, i)
  if it then
    for d = 1, #dest_tracks do
      local dt = dest_tracks[d]
      -- Skip copying onto the same track (if source track matches a destination track)
      if dt and dt ~= src_track then
        clone_item_to_track(it, dt)
      end
    end
  end
end

-- Delete the source track
reaper.DeleteTrack(src_track)

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Copy source track items to Breaths/Clicks/Renders, then delete source track", -1)
