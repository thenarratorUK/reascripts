-- @description Check for Empty Tracks in 15-Minute Checkpoint (list FX items)
-- @version 1.2
-- @author David Winter
--[[
ReaScript Name: Check for Empty Tracks in 15-Minute Checkpoint (list FX items)
Description:
  - Operates only inside project regions (e.g. the 15-minute checkpoint region).
  - Ignores tracks by name: "Live", "Reverb Bus", "Dialogue Bus".
  - Ignores tracks by number: 37–50 (editable section below).
  - For each non-ignored track:
      * If it's a folder parent: it passes if at least one child has content.
      * Otherwise: it passes if the track itself has content.
    "Content" means:
      * At least one item overlapping a region, OR
      * At least one such item that has take/item FX.
  - Outputs:
      1) Tracks that fail the content check.
      2) A separate list of all items (within regions) that have take/item FX.
Author: David Winter
Version: 1.2
]]

local function msg(s)
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
end

reaper.ClearConsole()

local proj = 0

------------------------------------------------------------
-- 1. Collect regions
------------------------------------------------------------
local num_markers, num_regions = reaper.CountProjectMarkers(proj)
local regions = {}

for i = 0, num_markers + num_regions - 1 do
  local _, isrgn, pos, rgnend = reaper.EnumProjectMarkers(i)
  if isrgn then
    regions[#regions + 1] = { start = pos, finish = rgnend }
  end
end

if #regions == 0 then
  msg("No regions found. Aborting.")
  return
end

------------------------------------------------------------
-- 2. Helpers
------------------------------------------------------------

-- Does this item overlap at least one region?
local function item_overlaps_regions(item)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local endpos = pos + len

  for _, r in ipairs(regions) do
    if (pos < r.finish) and (endpos > r.start) then
      return true
    end
  end
  return false
end

-- Does this item have any take/item FX on any take?
local function item_has_fx(item)
  local take_cnt = reaper.CountTakes(item)
  for t = 0, take_cnt - 1 do
    local take = reaper.GetTake(item, t)
    if take then
      local fx_count = reaper.TakeFX_GetCount(take)
      if fx_count > 0 then
        return true
      end
    end
  end
  return false
end

------------------------------------------------------------
-- 3. Track info and ignore rules
------------------------------------------------------------
local num_tracks = reaper.CountTracks(proj)

-- Ignore by name
local ignored_track_names = {
  ["Live"]         = true,
  ["Reverb Bus"]   = true,
  ["Dialogue Bus"] = true
}

-- Ignore by track number (1-based)
-- Pre-filled with 37–50 as requested.
local ignored_track_numbers = {}
for n = 37, 50 do
  ignored_track_numbers[n] = true
end
-- You can manually edit/add/remove track numbers above.

local track_info = {}
for i = 0, num_tracks - 1 do
  local tr = reaper.GetTrack(proj, i)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  local num1 = i + 1

  track_info[i] = {
    track     = tr,
    name      = name or "",
    number    = num1,
    is_parent = false,
    children  = {},
    ignored   = (ignored_track_names[name] == true) or (ignored_track_numbers[num1] == true)
  }
end

-- Build parent/children mapping using folder depth
for i = 0, num_tracks - 1 do
  local tr = track_info[i].track
  local depth = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")

  if depth == 1 then
    track_info[i].is_parent = true

    local folder_depth = 1
    local j = i + 1
    while j < num_tracks and folder_depth > 0 do
      table.insert(track_info[i].children, j)
      local child_tr = track_info[j].track
      local child_depth = reaper.GetMediaTrackInfo_Value(child_tr, "I_FOLDERDEPTH")
      folder_depth = folder_depth + child_depth
      j = j + 1
    end
  end
end

------------------------------------------------------------
-- 4. Scan items: track content flags + FX item collection
------------------------------------------------------------
local track_has_content = {}
for i = 0, num_tracks - 1 do
  track_has_content[i] = false
end

-- For listing exact items with FX (within regions)
local fx_items = {}

local num_items = reaper.CountMediaItems(proj)

for i = 0, num_items - 1 do
  local item = reaper.GetMediaItem(proj, i)
  local overlaps = item_overlaps_regions(item)
  local has_fx   = item_has_fx(item)

  -- Only consider items that overlap regions for track content + FX listing
  if overlaps then
    local tr = reaper.GetMediaItem_Track(item)
    if tr then
      local idx = reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") - 1
      if idx >= 0 and idx < num_tracks then
        if overlaps or has_fx then
          track_has_content[idx] = true
        end

        if has_fx then
          local _, tname = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
          local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
          local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

          table.insert(fx_items, {
            track_index = idx,
            track_name  = tname or "",
            track_num   = idx + 1,
            position    = pos,
            length      = len
          })
        end
      end
    end
  end
end

------------------------------------------------------------
-- 5. Evaluate track content vs rules
------------------------------------------------------------
local empty_tracks = {}

for i = 0, num_tracks - 1 do
  local info = track_info[i]

  if not info.ignored then
    local ok = false

    if info.is_parent and #info.children > 0 then
      -- Parent: OK if at least one child has content
      for _, child_idx in ipairs(info.children) do
        if track_has_content[child_idx] then
          ok = true
          break
        end
      end
    else
      -- Non-parent or child: OK if it has content itself
      if track_has_content[i] then
        ok = true
      end
    end

    if not ok then
      table.insert(empty_tracks, info)
    end
  end
end

------------------------------------------------------------
-- 6. Output
------------------------------------------------------------
if #empty_tracks == 0 then
  msg("All non-ignored tracks have content (items and/or FX) within regions.")
else
  msg("Tracks WITHOUT items/FX content within regions (non-ignored):")
  msg("-------------------------------------------------------------")
  for _, info in ipairs(empty_tracks) do
    local name = (info.name ~= "" and info.name) or "[Unnamed Track]"
    msg(string.format("Track %d: %s", info.number, name))
  end
end

msg("")
msg("Items with take/item FX within regions:")
msg("----------------------------------------")

if #fx_items == 0 then
  msg("None.")
else
  for _, it in ipairs(fx_items) do
    local name = (it.track_name ~= "" and it.track_name) or "[Unnamed Track]"
    msg(string.format(
      "Track %d: %s | Pos: %.3f s | Len: %.3f s",
      it.track_num, name, it.position, it.length
    ))
  end
end
