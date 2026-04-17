-- @description Distribute Items To Character Subtracks Based On Notes (SWS collapse + ordered child color gradient)
-- @version 1.2
-- @author David Winter
--[[
ReaScript Name: Distribute Items To Character Subtracks Based On Notes (SWS collapse + ordered child color gradient)
Author: David Winter
Version: 1.2

Description:
  - Run this with ONE track selected (your "parent" track).
  - For every item on that track:
      * Read the item notes field.
      * Find the first [...] block (e.g. "[05643_Jeff]").
      * Strip everything up to and including the first "_" inside the brackets,
        so "[05643_Jeff]" -> "Jeff" (the "speaker name").
      * Ensure there is a CHILD track of the selected track named with that speaker.
        If none exists, create it as a subtrack.
      * Move the item from the selected track down to that character’s subtrack.
  - After all items are processed:
      * Child tracks inherit the parent’s colour, with progressively reduced
        brightness in **track order** (top child brightest, next darker, etc.).
      * The selected track is selected and SWS action _SWS_COLLAPSE
        ("SWS: Set selected folder(s) collapsed") is run.

Requirements:
  - SWS extension installed (for _SWS_COLLAPSE).
  - Items on the selected track have notes like "[05643_Speaker Name]" somewhere
    in the notes text.
]]--

---------------------------------------
-- Small helper for console messages (optional)
---------------------------------------
local function msg(s)
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
end

---------------------------------------
-- Helper: get exactly one selected track
---------------------------------------
local function get_single_selected_track()
  local sel_count = reaper.CountSelectedTracks(0)
  if sel_count ~= 1 then
    return nil, "Please select exactly ONE track."
  end
  local track = reaper.GetSelectedTrack(0, 0)
  return track, nil
end

---------------------------------------
-- Helper: trim whitespace
---------------------------------------
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---------------------------------------
-- Helper: get all items on a given track
-- We scan all project items and filter by track.
---------------------------------------
local function get_items_on_track(track)
  local proj = 0
  local total_items = reaper.CountMediaItems(proj)
  local items = {}

  for i = 0, total_items - 1 do
    local it = reaper.GetMediaItem(proj, i)
    if reaper.GetMediaItem_Track(it) == track then
      table.insert(items, it)
    end
  end

  return items
end

---------------------------------------
-- Helper: get speaker name from item notes
-- Looks for first [...] block, then strips leading "xxxxx_"
---------------------------------------
local function get_speaker_from_notes(item)
  local ok, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
  if not ok or not notes or notes == "" then return nil end

  -- Find first [...] non-greedily
  local inside = notes:match("%[(.-)%]")
  if not inside then return nil end

  inside = trim(inside)

  -- Strip everything up to and including first underscore: "05643_Jeff" -> "Jeff"
  local name = inside:match("^[^_]+_(.+)$") or inside
  name = trim(name)

  if name == "" then return nil end
  return name
end

---------------------------------------
-- Helper: find or create a child track for a given speaker name
-- Ensures the selected track behaves as a folder parent.
-- Returns the child track and updated last_child_idx.
---------------------------------------
local function find_or_create_child_track(parent_track, speaker_name, last_child_idx)
  local proj = 0
  local num_tracks = reaper.CountTracks(proj)

  -- Parent index (0-based)
  local parent_idx = math.floor(reaper.GetMediaTrackInfo_Value(parent_track, "IP_TRACKNUMBER") + 0.5) - 1
  local parent_depth = reaper.GetMediaTrackInfo_Value(parent_track, "I_FOLDERDEPTH")

  -- Discover existing children of this parent (if any)
  local children = {}
  last_child_idx = last_child_idx or parent_idx

  if parent_depth > 0 then
    local depth = parent_depth
    local i = parent_idx + 1
    while i < num_tracks and depth > 0 do
      local tr = reaper.GetTrack(proj, i)
      table.insert(children, tr)
      last_child_idx = i
      depth = depth + reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
      i = i + 1
    end
    if #children == 0 then
      parent_depth = 0
      last_child_idx = parent_idx
    end
  end

  -- First, see if a child with this name already exists
  for _, tr in ipairs(children) do
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if name == speaker_name then
      return tr, last_child_idx
    end
  end

  -- Need to create a new child track
  if parent_depth <= 0 then
    -- Parent is not yet a folder: make it a folder start,
    -- and insert a single closing child under it.
    reaper.SetMediaTrackInfo_Value(parent_track, "I_FOLDERDEPTH", 1)

    local insert_idx = parent_idx + 1
    reaper.InsertTrackAtIndex(insert_idx, true)
    local new_tr = reaper.GetTrack(proj, insert_idx)

    reaper.GetSetMediaTrackInfo_String(new_tr, "P_NAME", speaker_name, true)
    -- New child closes the folder
    reaper.SetMediaTrackInfo_Value(new_tr, "I_FOLDERDEPTH", -1)

    last_child_idx = insert_idx
    return new_tr, last_child_idx
  else
    -- Parent is already a folder with children.
    -- Insert new child just before the closing child (last_child_idx).
    local insert_idx = last_child_idx
    reaper.InsertTrackAtIndex(insert_idx, true)
    local new_tr = reaper.GetTrack(proj, insert_idx)

    reaper.GetSetMediaTrackInfo_String(new_tr, "P_NAME", speaker_name, true)
    -- Middle child: depth=0
    reaper.SetMediaTrackInfo_Value(new_tr, "I_FOLDERDEPTH", 0)

    last_child_idx = insert_idx + 1
    return new_tr, last_child_idx
  end
end

---------------------------------------
-- Helper: copy parent colour to child (no gradient)
---------------------------------------
local function copy_parent_color(parent_track, child_track)
  if not parent_track or not child_track then return end
  local parent_col_native = reaper.GetTrackColor(parent_track)
  if parent_col_native == 0 then
    -- Parent has no custom colour; leave child at theme default.
    return
  end
  -- Ensure the high bit is set so REAPER treats it as custom colour.
  local col = parent_col_native | 0x1000000
  reaper.SetTrackColor(child_track, col)
end

---------------------------------------
-- Helper: after all children exist, apply gradient in track order
-- Topmost child = brightest, then darker downwards.
---------------------------------------
local function apply_gradient_to_children_in_track_order(parent_track)
  local proj = 0
  local num_tracks = reaper.CountTracks(proj)
  local parent_idx = math.floor(reaper.GetMediaTrackInfo_Value(parent_track, "IP_TRACKNUMBER") + 0.5) - 1
  local parent_depth = reaper.GetMediaTrackInfo_Value(parent_track, "I_FOLDERDEPTH")

  if parent_depth <= 0 then return end

  local parent_col_native = reaper.GetTrackColor(parent_track)
  if parent_col_native == 0 then
    -- No custom colour on parent, nothing to do.
    return
  end

  local r, g, b = reaper.ColorFromNative(parent_col_native)

  -- Collect child tracks in actual order
  local children = {}
  local depth = parent_depth
  local i = parent_idx + 1
  while i < num_tracks and depth > 0 do
    local tr = reaper.GetTrack(proj, i)
    table.insert(children, tr)
    depth = depth + reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
    i = i + 1
  end

  local child_count = #children
  if child_count == 0 then return end

  for idx, tr in ipairs(children) do
    -- idx = 1..child_count in visual order
    local factor = 1.0 - 0.12 * (idx - 1)
    if factor < 0.4 then factor = 0.4 end

    local cr = math.floor(r * factor + 0.5)
    local cg = math.floor(g * factor + 0.5)
    local cb = math.floor(b * factor + 0.5)

    if cr < 0 then cr = 0 elseif cr > 255 then cr = 255 end
    if cg < 0 then cg = 0 elseif cg > 255 then cg = 255 end
    if cb < 0 then cb = 0 elseif cb > 255 then cb = 255 end

    local child_col = reaper.ColorToNative(cr, cg, cb) | 0x1000000
    reaper.SetTrackColor(tr, child_col)
  end
end

---------------------------------------
-- MAIN
---------------------------------------
reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local parent_track, err = get_single_selected_track()
if not parent_track then
  reaper.ShowMessageBox(err or "Error: no selected track.", "Error", 0)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Distribute items to character subtracks", -1)
  return
end

-- Collect all items currently on the selected (parent) track
local items = get_items_on_track(parent_track)
if #items == 0 then
  reaper.ShowMessageBox("Selected track has no items to process.", "Info", 0)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Distribute items to character subtracks", -1)
  return
end

-- Cache: speaker_name -> child track
local speaker_tracks = {}
local last_child_idx = nil

for _, item in ipairs(items) do
  local speaker = get_speaker_from_notes(item)
  if speaker then
    local child = speaker_tracks[speaker]
    if not child then
      child, last_child_idx = find_or_create_child_track(parent_track, speaker, last_child_idx)
      -- Initially copy parent colour; gradient is applied later.
      copy_parent_color(parent_track, child)
      speaker_tracks[speaker] = child
    end

    -- Move item from the parent to this child's track
    reaper.MoveMediaItemToTrack(item, child)
  else
    -- No valid [xxxxx_Name] tag; item stays on the parent track.
  end
end

-- Apply ordered gradient across all children under this parent
apply_gradient_to_children_in_track_order(parent_track)

-- Reselect only the parent track
local proj = 0
local track_count = reaper.CountTracks(proj)
for i = 0, track_count - 1 do
  local tr = reaper.GetTrack(proj, i)
  reaper.SetTrackSelected(tr, false)
end
reaper.SetTrackSelected(parent_track, true)

-- Use SWS action to collapse the folder: _SWS_COLLAPSE
local collapse_cmd = reaper.NamedCommandLookup("_SWS_COLLAPSE")
if collapse_cmd ~= 0 then
  reaper.Main_OnCommand(collapse_cmd, 0)
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Distribute items to character subtracks", -1)
