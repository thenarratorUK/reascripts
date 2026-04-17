-- @description Copy Parent Automation from Selected Child Item to All Later Items on That Child (Using 4-Point Block, Midpoint Sampling)
-- @version 1.0
-- @author David Winter
--[[
ReaScript Name: Copy Parent Automation from Selected Child Item to All Later Items on That Child (Using 4-Point Block, Midpoint Sampling)
Author: David Winter
Version: 1.0
Description:
  - You select ONE item on a CHILD track (inside a folder).
  - The script finds that track's PARENT (the folder track).
  - It reads all ACTIVE envelopes on the PARENT, samples their value at the MIDPOINT
    of the selected item, and treats those as the "character template" values.
  - Then, on the SAME CHILD TRACK, it finds ALL LATER items, groups adjacent/overlapping
    items into segments, and for EACH segment:
        * On EVERY active envelope on the PARENT, it writes a 4-point "block":
              outer-before  (just before segment start) at current value
              inner-start   (at segment start)          at template value
              inner-end     (at segment end)            at template value
              outer-after   (just after segment end)    at current value
  - Result: the parent’s automation behaves like your reference item’s automation
    for every later item on that child track, without touching other tracks.

Requirements / Assumptions:
  - The selected item MUST be on a child track that has a folder parent (your “Special 2”).
  - You want all active envelopes on the parent to be treated as “character” envelopes.
  - You use ripple editing ALL (so parent automation stays aligned with items when you ripple).
  - You are not using the parent’s envelopes for scene-level/global automation.

Usage:
  - Select ONE item on the relevant child track whose parent already has the correct
    automation for that character over that item.
  - Run the script.
  - It will apply that character’s template to all later items on that same child track.
]]--

---------------------------------------
-- Helper: print to console (debug)
---------------------------------------
local function msg(str)
  reaper.ShowConsoleMsg(tostring(str) .. "\n")
end

---------------------------------------
-- Helper: get selected media item (exactly one)
---------------------------------------
local function get_single_selected_item()
  local sel_count = reaper.CountSelectedMediaItems(0)
  if sel_count ~= 1 then
    return nil, "Please select exactly ONE media item on a child track."
  end
  local item = reaper.GetSelectedMediaItem(0, 0)
  return item, nil
end

---------------------------------------
-- Helper: find parent (folder) track of a given track
-- Returns parent track or nil if none
---------------------------------------
local function get_parent_track(child_track)
  if not child_track then return nil end

  -- REAPER folder logic:
  -- A track is a folder parent if I_FOLDERDEPTH > 0
  -- Child tracks follow until a track whose I_FOLDERDEPTH < 0 closes the folder.
  -- For a given child track, its parent is usually the nearest track above
  -- whose folder depth is > 0 and still "open" when we reach the child.
  -- We reconstruct folder hierarchy by walking from the top.

  local proj = 0
  local num_tracks = reaper.CountTracks(proj)
  local target_index = reaper.GetMediaTrackInfo_Value(child_track, "IP_TRACKNUMBER") - 1 -- 0-based

  local current_parent = nil
  local folder_depth = 0

  for i = 0, num_tracks - 1 do
    local tr = reaper.GetTrack(proj, i)
    local depth = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")

    -- When we hit a track, if folder_depth > 0, that means we're inside a folder.
    -- The most recent track with depth > 0 (that increased folder_depth) is the current parent.
    if reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") > 0 then
      -- This track starts a new folder
      current_parent = tr
      folder_depth = folder_depth + 1
    else
      folder_depth = folder_depth + depth
      if folder_depth < 0 then
        -- reset when we exit all folders
        folder_depth = 0
        current_parent = nil
      end
    end

    if i == target_index then
      -- child_track is at index i
      return current_parent
    end
  end

  return nil
end

---------------------------------------
-- Helper: enumerate all active envelopes on a track
-- Returns array of TrackEnvelope
---------------------------------------
local function get_active_envelopes(track)
  local envs = {}
  if not track then return envs end

  local env_count = reaper.CountTrackEnvelopes(track)
  for i = 0, env_count - 1 do
    local env = reaper.GetTrackEnvelope(track, i)
    if env then
      -- We treat all envelopes as "active" to match your current behaviour.
      -- If you later want to filter by visibility or name, this is the place.
      table.insert(envs, env)
    end
  end
  return envs
end

---------------------------------------
-- Helper: evaluate envelope at a given time
-- Returns value (number) or nil if failed
---------------------------------------
local function eval_env_at_time(env, time)
  if not env then return nil end
  -- retval, value, dVdS, ddVdSddS, ok = Envelope_Evaluate( env, time, samplerate, samples_requested )
  local ok_ret, val, _, _, _ = reaper.Envelope_Evaluate(env, time, 0, 0)
  if not ok_ret then return nil end
  return val
end

---------------------------------------
-- Helper: insert 4-point block on parent envelope for [seg_start, seg_end]
--  - outer-before = current value at seg_start - eps
--  - inner-start  = template value at seg_start
--  - inner-end    = template value at seg_end
--  - outer-after  = current value at seg_end + eps
---------------------------------------
local function apply_four_point_block(env, seg_start, seg_end, template_value)
  if seg_end <= seg_start then return end

  local eps = 0.0001  -- fractional second just outside segment

  local before_time = seg_start - eps
  local after_time  = seg_end   + eps

  -- Get current values at just outside the segment
  local before_val = eval_env_at_time(env, before_time)
  local after_val  = eval_env_at_time(env, after_time)

  if before_val == nil or after_val == nil then
    -- If evaluation fails for any reason, bail on this envelope
    return
  end

  -- We do NOT delete the existing envelope segment.
  -- We simply inject four points. If you want to fully overwrite
  -- existing automation in [seg_start, seg_end], you could add
  -- DeleteEnvelopePointRange(env, seg_start, seg_end) before insertion.

  -- Outer-before
  reaper.InsertEnvelopePoint(env, before_time, before_val, 0, 0, false, true)
  -- Inner-start
  reaper.InsertEnvelopePoint(env, seg_start, template_value, 0, 0, false, true)
  -- Inner-end
  reaper.InsertEnvelopePoint(env, seg_end, template_value, 0, 0, false, true)
  -- Outer-after
  reaper.InsertEnvelopePoint(env, after_time, after_val, 0, 0, false, true)

  -- Sort points
  reaper.Envelope_SortPoints(env)
end

---------------------------------------
-- Helper: get all items on a track sorted by start time
---------------------------------------
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
      -- tie-break by length just to be deterministic
      local la = reaper.GetMediaItemInfo_Value(a, "D_LENGTH")
      local lb = reaper.GetMediaItemInfo_Value(b, "D_LENGTH")
      return la < lb
    end
    return sa < sb
  end)

  return items
end

---------------------------------------
-- Helper: find index of a specific item in an item-list
---------------------------------------
local function find_item_index(list, item)
  for i = 0, #list - 1 do
    if list[i+1] == item then
      return i
    end
  end
  return -1
end

---------------------------------------
-- Helper: build list of segments from items AFTER a given index
-- A "segment" is a continuous span of adjacent or overlapping items
-- on the same child track.
---------------------------------------
local function build_segments_from_items(items, start_index)
  local segments = {}
  if start_index < 0 or start_index >= #items - 1 then
    return segments
  end

  local EPS_MERGE = 0.0000001  -- treat tiny gaps as adjacency

  local i = start_index + 1   -- start from the item AFTER the reference one
  while i < #items do
    local it = items[i+1]
    local seg_start = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local seg_end   = seg_start + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")

    -- Expand segment to include adjacent/overlapping items
    local j = i + 1
    while j < #items do
      local it_next = items[j+1]
      local next_start = reaper.GetMediaItemInfo_Value(it_next, "D_POSITION")
      local next_end   = next_start + reaper.GetMediaItemInfo_Value(it_next, "D_LENGTH")

      -- If next item starts before or exactly at (seg_end + EPS_MERGE), treat as part of same segment
      if next_start <= seg_end + EPS_MERGE then
        if next_end > seg_end then
          seg_end = next_end
        end
        j = j + 1
      else
        break
      end
    end

    table.insert(segments, {start = seg_start, stop = seg_end})

    i = j
  end

  return segments
end

---------------------------------------
-- MAIN
---------------------------------------
reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local item, err = get_single_selected_item()
if not item then
  reaper.ShowMessageBox(err or "Error: no selected item.", "Error", 0)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Copy parent automation from selected child to later items", -1)
  return
end

local child_track = reaper.GetMediaItem_Track(item)
if not child_track then
  reaper.ShowMessageBox("Selected item has no track.", "Error", 0)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Copy parent automation from selected child to later items", -1)
  return
end

local parent_track = get_parent_track(child_track)
if not parent_track then
  reaper.ShowMessageBox("Track of selected item has no folder parent.\n\nThis script expects the item to be on a CHILD track inside a folder (parent).", "Error", 0)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Copy parent automation from selected child to later items", -1)
  return
end

-- Get reference item time range
local src_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
local src_len   = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
local src_end   = src_start + src_len
local src_mid   = src_start + (src_len * 0.5)

-- Fetch all parent envelopes and sample midpoint values as template
local parent_envs = get_active_envelopes(parent_track)
if #parent_envs == 0 then
  reaper.ShowMessageBox("Parent track has no envelopes to copy.", "Error", 0)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Copy parent automation from selected child to later items", -1)
  return
end

local template_values = {}
for _, env in ipairs(parent_envs) do
  local v = eval_env_at_time(env, src_mid)
  if v == nil then
    -- If evaluation fails, we skip this envelope
  else
    template_values[env] = v
  end
end

-- Get all items on the same child track, sorted
local all_items_on_child = get_sorted_items_on_track(child_track)
if #all_items_on_child == 0 then
  reaper.ShowMessageBox("Child track has no items (unexpected).", "Error", 0)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Copy parent automation from selected child to later items", -1)
  return
end

-- Find index of selected item
local src_index = find_item_index(all_items_on_child, item)
if src_index < 0 then
  reaper.ShowMessageBox("Could not find selected item in internal list.\nThis should not happen.", "Error", 0)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Copy parent automation from selected child to later items", -1)
  return
end

-- Build segments from items AFTER the reference index
local segments = build_segments_from_items(all_items_on_child, src_index)
if #segments == 0 then
  -- Nothing to do; no later items
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Copy parent automation from selected child to later items", -1)
  return
end

-- Apply 4-point block for each segment, for each template envelope
for _, seg in ipairs(segments) do
  local seg_start = seg.start
  local seg_end   = seg.stop

  for _, env in ipairs(parent_envs) do
    local tpl_val = template_values[env]
    if tpl_val ~= nil then
      apply_four_point_block(env, seg_start, seg_end, tpl_val)
    end
  end
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Copy parent automation from selected child to later items", -1)
