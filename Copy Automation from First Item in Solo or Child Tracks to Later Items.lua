--[[
ReaScript Name: Copy Parent Automation from First Region to Later Items (Track-based, Folder-aware)
Author: David Winter
Version: 1.3

Behaviour summary
-----------------
Run this script with exactly ONE track selected.

1) Standalone track (no folder parent, not a folder parent):
   - Treat the selected track as both "parent" and "child".
   - Find all items on that track, sorted by time.
   - Build a "first region" starting at the earliest item and extending
     through any immediately adjacent/overlapping items.
   - Let X = end of that first region.
   - Wipe all envelopes on this track AFTER X.
   - Sample all envelopes at the midpoint of the first region.
   - For all items AFTER that region, build contiguous segments and write
     4-point automation blocks on this track's envelopes.

2) Folder mode (you select either a folder parent OR any of its children):
   - Determine the folder parent; this is the automation "parent" track.
   - Gather all child tracks under that folder.
   - For each child track with items:
       * Find its earliest item (first item).
   - Among those earliest items, find the one that starts LAST.
     Let X = END time of that earliest item.
   - On the parent track, WIPE automation AFTER X on all envelopes.
   - For each child track:
       * Build a "first region" starting from that track's earliest item and
         extending through any adjacent/overlapping items whose start is < X.
       * Sample parent envelopes at the midpoint of this whole first region.
       * For all items AFTER that first region on that child track, build
         contiguous segments and apply 4-point automation blocks on the parent:
             - outer-before  (just before segment) at current env value
             - inner-start   (at segment start)    at template value
             - inner-end     (at segment end)      at template value
             - outer-after   (just after segment)  at current env value

Notes / assumptions
-------------------
- "Adjacent" means the next item's start time is <= previous region end
  (with a tiny epsilon).
- You stated there should be no case where, BEFORE X, a child track has
  multiple non-adjacent items. This script assumes that.
- Envelopes: ALL track envelopes on the parent are treated as active.
]]

local alerts = true  -- set false to silence certain non-fatal warnings

--------------------------------------------------
-- Utility: debug print
--------------------------------------------------
local function Msg(str)
  reaper.ShowConsoleMsg(tostring(str) .. "\n")
end

--------------------------------------------------
-- Helper: get Parent FX track
-- Assumes naming convention: "<Parent Name> FX"
--------------------------------------------------
local function get_parent_fx_track(parent_track)
  if not parent_track then return nil end

  local ok, parent_name = reaper.GetTrackName(parent_track, "")
  if not ok or not parent_name or parent_name == "" then
    return nil
  end

  local target_name = parent_name .. " FX"

  local proj = 0
  local num_tracks = reaper.CountTracks(proj)
  for i = 0, num_tracks - 1 do
    local tr = reaper.GetTrack(proj, i)
    local _, name = reaper.GetTrackName(tr, "")
    if name == target_name then
      return tr
    end
  end

  return nil
end

--------------------------------------------------
-- Helper: does the project contain an "AllFX" track?
-- (Also accepts "All FX" as an alternative hard-coded name)
--------------------------------------------------
local function project_has_allfx_track()
  local proj = 0
  local track_count = reaper.CountTracks(proj)

  for i = 0, track_count - 1 do
    local tr = reaper.GetTrack(proj, i)
    local _, name = reaper.GetTrackName(tr, "")
    if name == "AllFX" or name == "All FX" then
      return true
    end
  end

  return false
end

--------------------------------------------------
-- Helper: evaluate an envelope at a given time
--------------------------------------------------
local function eval_env_at_time(env, time)
  if not env then return nil end
  local ok, val = reaper.Envelope_Evaluate(env, time, 0, 0)
  if not ok then return nil end
  return val
end

--------------------------------------------------
-- Helper: get all envelopes on a track
--------------------------------------------------
local function get_active_envelopes(track)
  local envs = {}
  if not track then return envs end

  local env_count = reaper.CountTrackEnvelopes(track)
  for i = 0, env_count - 1 do
    local env = reaper.GetTrackEnvelope(track, i)
    if env then
      table.insert(envs, env)
    end
  end
  return envs
end

--------------------------------------------------
-- Helper: get parent (folder) track of a given track
--------------------------------------------------
local function get_parent_track(child_track)
  if not child_track then return nil end

  local proj = 0
  local num_tracks = reaper.CountTracks(proj)
  local target_index = reaper.GetMediaTrackInfo_Value(child_track, "IP_TRACKNUMBER") - 1

  local current_parent = nil
  local folder_depth = 0

  for i = 0, num_tracks - 1 do
    local tr = reaper.GetTrack(proj, i)
    local depth = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")

    if depth > 0 then
      folder_depth = folder_depth + depth
      current_parent = tr
    elseif depth < 0 then
      folder_depth = folder_depth + depth
      if folder_depth <= 0 then
        current_parent = nil
      end
    end

    if i == target_index then
      break
    end
  end

  return current_parent
end

--------------------------------------------------
-- Helper: get all items on a track, sorted
--------------------------------------------------
local function get_sorted_items_on_track(track)
  local items = {}
  local proj = 0
  local total_items = reaper.CountMediaItems(proj)

  for i = 0, total_items - 1 do
    local it = reaper.GetMediaItem(proj, i)
    if reaper.GetMediaItem_Track(it) == track then
      table.insert(items, it)
    end
  end

  table.sort(items, function(a, b)
    local sa = reaper.GetMediaItemInfo_Value(a, "D_POSITION")
    local sb = reaper.GetMediaItemInfo_Value(b, "D_POSITION")
    if sa == sb then
      local la = reaper.GetMediaItemInfo_Value(a, "D_LENGTH")
      local lb = reaper.GetMediaItemInfo_Value(b, "D_LENGTH")
      return la < lb
    end
    return sa < sb
  end)

  return items
end

--------------------------------------------------
-- Helper: compute "first region" from sorted items
--   items    : array of MediaItem*, sorted by time
--   max_time : if non-nil, do NOT extend region into items
--              whose start >= max_time (used in folder mode)
-- Returns:
--   region_start, region_end, last_index_in_region
--   or nil, nil, 0 if no items
--------------------------------------------------
local function compute_first_region(items, max_time)
  if not items or #items == 0 then
    return nil, nil, 0
  end

  local EPS = 0.0000001

  local first = items[1]
  local region_start = reaper.GetMediaItemInfo_Value(first, "D_POSITION")
  local region_end   = region_start + reaper.GetMediaItemInfo_Value(first, "D_LENGTH")
  local last_idx     = 1

  for idx = 2, #items do
    local it = items[idx]
    local s  = reaper.GetMediaItemInfo_Value(it, "D_POSITION")

    if max_time and s >= max_time then
      break
    end

    if s <= region_end + EPS then
      local e = s + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      if e > region_end then region_end = e end
      last_idx = idx
    else
      break
    end
  end

  return region_start, region_end, last_idx
end

--------------------------------------------------
-- Helper: build segments from items AFTER a given index
--   items        : sorted items
--   last_ref_idx : last index that belongs to the "first region".
--                  Segments begin from last_ref_idx + 1.
-- Returns array of { start = number, stop = number }
--------------------------------------------------
local function build_segments_from_items(items, last_ref_idx)
  local segments = {}
  if not items or #items <= last_ref_idx then
    return segments
  end

  local EPS = 0.0000001
  local i = last_ref_idx + 1

  while i <= #items do
    local it = items[i]
    local seg_start = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local seg_end   = seg_start + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")

    local j = i + 1
    while j <= #items do
      local it_next = items[j]
      local next_start = reaper.GetMediaItemInfo_Value(it_next, "D_POSITION")
      local next_end   = next_start + reaper.GetMediaItemInfo_Value(it_next, "D_LENGTH")

      if next_start <= seg_end + EPS then
        if next_end > seg_end then
          seg_end = next_end
        end
        j = j + 1
      else
        break
      end
    end

    table.insert(segments, { start = seg_start, stop = seg_end })
    i = j
  end

  return segments
end

--------------------------------------------------
-- Helper: apply 4-point automation block on env for a segment
--------------------------------------------------
local function apply_four_point_block(env, seg_start, seg_end, template_val)
  if not env then return end

  local EPS = 0.0000001
  local before_time = seg_start - EPS
  local after_time  = seg_end   + EPS

  local before_val = eval_env_at_time(env, before_time)
  local after_val  = eval_env_at_time(env, after_time)
  if before_val == nil or after_val == nil then
    return
  end

  reaper.InsertEnvelopePoint(env, before_time, before_val, 0, 0, false, true)
  reaper.InsertEnvelopePoint(env, seg_start,   template_val, 0, 0, false, true)
  reaper.InsertEnvelopePoint(env, seg_end,     template_val, 0, 0, false, true)
  reaper.InsertEnvelopePoint(env, after_time,  after_val,    0, 0, false, true)

  reaper.Envelope_SortPoints(env)
end

--------------------------------------------------
-- Helper: get track index (0-based)
--------------------------------------------------
local function get_track_index(track)
  if not track then return -1 end
  local idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
  if not idx then return -1 end
  return math.floor(idx + 0.5) - 1
end

--------------------------------------------------
-- Helper: collect child tracks of a folder parent
--------------------------------------------------
local function get_child_tracks_of_parent(parent_track)
  local children = {}
  if not parent_track then return children end

  local proj = 0
  local num_tracks = reaper.CountTracks(proj)
  local parent_index = get_track_index(parent_track)
  if parent_index < 0 then return children end

  local folder_depth = reaper.GetMediaTrackInfo_Value(parent_track, "I_FOLDERDEPTH")
  if folder_depth <= 0 then
    return children
  end

  local idx = parent_index + 1
  while idx < num_tracks and folder_depth > 0 do
    local tr = reaper.GetTrack(proj, idx)
    table.insert(children, tr)
    local d = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
    folder_depth = folder_depth + d
    idx = idx + 1
  end

  return children
end

--------------------------------------------------
-- Helper: wipe automation AFTER a time on all envelopes
--------------------------------------------------
local function wipe_envelopes_after_time(envs, time_pos)
  local EPS = 0.0000001
  local BIG = 10e9

  for _, env in ipairs(envs) do
    reaper.DeleteEnvelopePointRange(env, time_pos + EPS, BIG)
  end
end

--------------------------------------------------
-- MAIN
--------------------------------------------------
reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local proj = 0
local sel_tr_count = reaper.CountSelectedTracks(proj)

if sel_tr_count == 0 then
  reaper.ShowMessageBox("Please select a track (standalone or folder parent/child).", "Error", 0)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Copy parent automation from first region to later items", -1)
  return
elseif sel_tr_count > 1 then
  reaper.ShowMessageBox("Please select ONLY ONE track.", "Error", 0)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Copy parent automation from first region to later items", -1)
  return
end

local selected_track = reaper.GetSelectedTrack(proj, 0)
if not selected_track then
  reaper.ShowMessageBox("Internal error: could not get selected track.", "Error", 0)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Copy parent automation from first region to later items", -1)
  return
end

-- Decide mode: standalone vs folder
local depth_sel = reaper.GetMediaTrackInfo_Value(selected_track, "I_FOLDERDEPTH")
local parent_of_selected = get_parent_track(selected_track)

local parent_track
local mode

if depth_sel > 0 then
  -- Selected track is a folder parent
  parent_track = selected_track
  mode = "folder"
else
  if parent_of_selected then
    -- Selected track is a child of some folder
    parent_track = parent_of_selected
    mode = "folder"
  else
    -- Standalone track
    parent_track = selected_track
    mode = "standalone"
  end
end

-- Decide whether to use Parent FX track or the original parent track
local automation_track

if project_has_allfx_track() then
  -- Special-case: if the parent is the "Character FX" folder, skip attempting to
  -- resolve "Character FX FX" and operate on the parent track for this one case.
  local _, parent_name = reaper.GetTrackName(parent_track, "")
  if parent_name == "Character FX" then
    -- Quietly use the parent track (do not attempt to resolve "Character FX FX")
    automation_track = parent_track
  else
    -- Normal AllFX behaviour: require a "<ParentName> FX" track
    local fx_tr = get_parent_fx_track(parent_track)
    if not fx_tr then
      reaper.ShowMessageBox(
        "AllFX/All FX track detected, but no matching Parent FX track found.\n\n" ..
        "Expected a track named: \"" .. (parent_name or "") .. " FX\".\n\n" ..
        "Please create that track (or remove/rename AllFX) before running this script.",
        "Parent FX Track Not Found",
        0
      )
      reaper.PreventUIRefresh(-1)
      reaper.Undo_EndBlock("Copy parent automation from first region to later items", -1)
      return
    end
    automation_track = fx_tr
  end
else
  -- OLD behaviour: no AllFX track => operate directly on the parent track
  automation_track = parent_track
end

-- Collect envelopes from the chosen automation track
local parent_envs = get_active_envelopes(automation_track)
if #parent_envs == 0 then
  if alerts then
    reaper.ShowMessageBox("Selected/parent track has no envelopes to copy.", "Error", 0)
  end
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Copy parent automation from first region to later items", -1)
  return
end

--------------------------------------------------
-- STANDALONE MODE
--------------------------------------------------
if mode == "standalone" then
  local items = get_sorted_items_on_track(parent_track)
  if #items == 0 then
    reaper.ShowMessageBox("Selected track has no items.", "Error", 0)
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Copy parent automation from first region to later items", -1)
    return
  end

  local region_start, region_end, last_idx = compute_first_region(items, nil)
  if not region_start then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Copy parent automation from first region to later items", -1)
    return
  end

  -- X = end of the first region
  local X = region_end

  -- Wipe automation AFTER X on this track
  wipe_envelopes_after_time(parent_envs, X)

  local src_mid = (region_start + region_end) * 0.5

  local template_values = {}
  for _, env in ipairs(parent_envs) do
    local v = eval_env_at_time(env, src_mid)
    if v ~= nil then
      template_values[env] = v
    end
  end

  local segments = build_segments_from_items(items, last_idx)
  if #segments == 0 then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Copy parent automation from first region to later items", -1)
    return
  end

  for _, seg in ipairs(segments) do
    for _, env in ipairs(parent_envs) do
      local tpl = template_values[env]
      if tpl ~= nil then
        apply_four_point_block(env, seg.start, seg.stop, tpl)
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Copy parent automation from first region to later items", -1)
  return
end

--------------------------------------------------
-- FOLDER MODE
--------------------------------------------------
local child_tracks = get_child_tracks_of_parent(parent_track)
if #child_tracks == 0 then
  reaper.ShowMessageBox("Folder parent has no child tracks.", "Error", 0)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Copy parent automation from first region to later items", -1)
  return
end

-- Step 1: gather earliest item info for each child
local child_infos = {} -- { track, items, first_start, first_end }

for _, ch_tr in ipairs(child_tracks) do
  local items = get_sorted_items_on_track(ch_tr)
  if #items > 0 then
    local first = items[1]
    local s = reaper.GetMediaItemInfo_Value(first, "D_POSITION")
    local l = reaper.GetMediaItemInfo_Value(first, "D_LENGTH")
    local e = s + l

    table.insert(child_infos, {
      track       = ch_tr,
      items       = items,
      first_start = s,
      first_end   = e
    })
  end
end

if #child_infos == 0 then
  reaper.ShowMessageBox("No child tracks with items were found under the selected parent.", "Error", 0)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Copy parent automation from first region to later items", -1)
  return
end

-- Step 2: compute X as "end of the last-starting earliest item"
local idx_last = 1
local max_first_start = child_infos[1].first_start
for i = 2, #child_infos do
  if child_infos[i].first_start > max_first_start then
    max_first_start = child_infos[i].first_start
    idx_last = i
  end
end

local X = child_infos[idx_last].first_end

-- Step 3: wipe parent automation AFTER X
wipe_envelopes_after_time(parent_envs, X)

-- Step 4: per-child processing with 2b semantics
for _, info in ipairs(child_infos) do
  local items = info.items

  local region_start, region_end, last_idx = compute_first_region(items, X)
  if region_start and last_idx > 0 then
    local src_mid = (region_start + region_end) * 0.5

    local template_values = {}
    for _, env in ipairs(parent_envs) do
      local v = eval_env_at_time(env, src_mid)
      if v ~= nil then
        template_values[env] = v
      end
    end

    local segments = build_segments_from_items(items, last_idx)
    for _, seg in ipairs(segments) do
      for _, env in ipairs(parent_envs) do
        local tpl = template_values[env]
        if tpl ~= nil then
          apply_four_point_block(env, seg.start, seg.stop, tpl)
        end
      end
    end
  end
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Copy parent automation from first region to later items", -1)
