--[[
ReaScript Name : Reorder Adjacent Items (4 or 6) + Ripple-Remove + Automation + Region (+ Region Render Matrix tick)
Author         : David Winter (requested)
Version        : 1.4

Selection modes:
- If 6 items selected:
    • Use those 6, sorted left-to-right
    • Reorder: 1,4,2,5,3,6  (i.e. A1,A2,B1,B2,C1,C2)
- If 4 items selected:
    • Use those 4, sorted left-to-right
    • Reorder: 1,3,2,4
- If 1 item selected:
    • Find the adjacent run (gap <= MAX_GAP, overlaps allowed) on the same track.
    • If the run contains >=6 items: choose the tightest 6-item window that includes the selected item and do 6-item reorder.
      Else if the run contains >=4 items: choose the tightest 4-item window that includes the selected item and do 4-item reorder.
      Else: error.

After reordering (4 or 6):
- Copies the source items immediately after the rightmost original item, back-to-back, on the same track.
- Copies track automation under each source item time-span to the new location (envelope points + automation items where possible).
- Makes a time selection across the ORIGINAL block and runs:
    40201  Time selection: Remove contents of time selection (moving later items)
  (This pulls the newly created items into the original position, avoiding a gap.)
- Selects the newly reordered items and runs:
    40393  Markers: Insert region from selected items and edit...
- Then ticks the Region Render Matrix for the newly created region:
    • If all selected items are on one track: tick that track
    • If items span multiple tracks: tick the master track

Notes:
- 40201 affects the whole project time selection (all tracks). Usually desirable to preserve sync.
]]

local ACTION_INSERT_REGION_FROM_SELECTED_ITEMS_AND_EDIT = 40393
local ACTION_UNSELECT_ALL_ITEMS                        = 40289
local ACTION_TIMESEL_REMOVE_CONTENTS_MOVE_LATER         = 40201

-- Maximum gap allowed between “adjacent” items when expanding from 1 selected item (seconds).
local MAX_GAP = 2.0

local function msg(s)
  reaper.ShowMessageBox(tostring(s), "Reorder Items", 0)
end

local function get_item_pos_len(item)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return pos, len
end

local function sort_items_by_pos(items)
  table.sort(items, function(a, b)
    local ap = reaper.GetMediaItemInfo_Value(a, "D_POSITION")
    local bp = reaper.GetMediaItemInfo_Value(b, "D_POSITION")
    if ap == bp then return tostring(a) < tostring(b) end
    return ap < bp
  end)
end

local function all_on_same_track(items)
  if #items == 0 then return false end
  local t0 = reaper.GetMediaItemTrack(items[1])
  for i = 2, #items do
    if reaper.GetMediaItemTrack(items[i]) ~= t0 then return false end
  end
  return true
end

-- Adjacent if next starts no later than prev_end + MAX_GAP (also permits overlaps)
local function items_adjacent(prev_item, next_item)
  local ppos, plen = get_item_pos_len(prev_item)
  local npos, _ = get_item_pos_len(next_item)
  local pend = ppos + plen
  return (npos - pend) <= MAX_GAP
end

local function get_track_items_sorted(track)
  local n = reaper.CountTrackMediaItems(track)
  local items = {}
  for i = 0, n - 1 do
    items[#items + 1] = reaper.GetTrackMediaItem(track, i)
  end
  sort_items_by_pos(items)
  return items
end

local function find_item_index(items, target)
  for i = 1, #items do
    if items[i] == target then return i end
  end
  return nil
end

local function pick_best_window(block, sel_index_in_block, window_size)
  local n = #block
  if n < window_size then return nil end
  if n == window_size then return block end

  local best_start = nil
  local best_span  = math.huge

  local min_start = math.max(1, sel_index_in_block - (window_size - 1))
  local max_start = math.min(sel_index_in_block, n - (window_size - 1))

  for s = min_start, max_start do
    local e = s + (window_size - 1)
    local sp, _ = get_item_pos_len(block[s])
    local ep, el = get_item_pos_len(block[e])
    local span = (ep + el) - sp
    if span < best_span then
      best_span = span
      best_start = s
    end
  end

  if not best_start then return nil end
  local out = {}
  for i = best_start, best_start + (window_size - 1) do
    out[#out + 1] = block[i]
  end
  return out
end

-- From 1 selected item: get adjacent block, then choose either 6 or 4 window (preferring 6 if possible)
local function get_adjacent_window(sel_item)
  local track = reaper.GetMediaItemTrack(sel_item)
  local track_items = get_track_items_sorted(track)
  local idx = find_item_index(track_items, sel_item)
  if not idx then return nil, nil end

  local left = idx
  while left > 1 and items_adjacent(track_items[left - 1], track_items[left]) do
    left = left - 1
  end

  local right = idx
  while right < #track_items and items_adjacent(track_items[right], track_items[right + 1]) do
    right = right + 1
  end

  local block = {}
  for i = left, right do
    block[#block + 1] = track_items[i]
  end
  local sel_in_block = (idx - left) + 1

  if #block >= 6 then
    return pick_best_window(block, sel_in_block, 6), 6
  elseif #block >= 4 then
    return pick_best_window(block, sel_in_block, 4), 4
  end

  return nil, nil
end

local function clone_item_to_pos(item, new_pos)
  local track = reaper.GetMediaItemTrack(item)
  local ok, chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok then return nil end

  -- Replace all GUID occurrences to avoid duplicate GUIDs
  chunk = chunk:gsub("GUID %b{}", function()
    return "GUID " .. reaper.genGuid()
  end)

  local new_item = reaper.AddMediaItemToTrack(track)
  if not new_item then return nil end

  reaper.SetItemStateChunk(new_item, chunk, false)
  reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", new_pos)
  return new_item
end

-- Copy track automation within [src_start, src_end) and shift it to start at dest_start.
-- Copies:
--   - normal envelope points
--   - automation items (and their points if unpooled), where API is available
local function copy_track_automation_in_range(track, src_start, src_end, dest_start)
  local env_count = reaper.CountTrackEnvelopes(track)
  if env_count <= 0 then return end

  local can_ai =
    (reaper.CountAutomationItems ~= nil) and
    (reaper.InsertAutomationItem ~= nil) and
    (reaper.GetSetAutomationItemInfo ~= nil)

  for e = 0, env_count - 1 do
    local env = reaper.GetTrackEnvelope(track, e)
    if env then
      -- Envelope points
      local pt_count = reaper.CountEnvelopePoints(env)
      if pt_count > 0 then
        local to_copy = {}
        for p = 0, pt_count - 1 do
          local ok, time, value, shape, tension = reaper.GetEnvelopePoint(env, p)
          if ok and time >= src_start and time < src_end then
            to_copy[#to_copy + 1] = { time = time, value = value, shape = shape, tension = tension }
          end
        end
        for i = 1, #to_copy do
          local new_time = dest_start + (to_copy[i].time - src_start)
          reaper.InsertEnvelopePoint(env, new_time, to_copy[i].value, to_copy[i].shape, to_copy[i].tension, false, true)
        end
      end

      -- Automation items
      if can_ai then
        local ai_count = reaper.CountAutomationItems(env)
        for ai = 0, ai_count - 1 do
          local ai_pos = reaper.GetSetAutomationItemInfo(env, ai, "D_POSITION", 0, false)
          local ai_len = reaper.GetSetAutomationItemInfo(env, ai, "D_LENGTH",   0, false)
          local ai_end = ai_pos + ai_len

          if (ai_pos < src_end) and (ai_end > src_start) then
            local pool_id = reaper.GetSetAutomationItemInfo(env, ai, "D_POOL_ID", 0, false)
            local new_pos = dest_start + (ai_pos - src_start)
            local new_ai  = reaper.InsertAutomationItem(env, pool_id, new_pos, ai_len)

            if new_ai ~= nil then
              local props = { "D_STARTOFFS", "D_PLAYRATE", "D_BASELINE", "D_AMPLITUDE", "D_LOOPSRC" }
              for _, k in ipairs(props) do
                local v = reaper.GetSetAutomationItemInfo(env, ai, k, 0, false)
                reaper.GetSetAutomationItemInfo(env, new_ai, k, v, true)
              end

              -- If unpooled, copy AI points explicitly
              if pool_id < 0 and reaper.CountEnvelopePointsEx and reaper.GetEnvelopePointEx and reaper.InsertEnvelopePointEx then
                local ex_count = reaper.CountEnvelopePointsEx(env, ai)
                for p = 0, ex_count - 1 do
                  local ok, time, value, shape, tension = reaper.GetEnvelopePointEx(env, ai, p)
                  if ok then
                    local new_time = new_pos + (time - ai_pos)
                    reaper.InsertEnvelopePointEx(env, new_ai, new_time, value, shape, tension, false, true)
                  end
                end
                if reaper.Envelope_SortPointsEx then
                  reaper.Envelope_SortPointsEx(env, new_ai)
                end
              end
            end
          end
        end
      end

      reaper.Envelope_SortPoints(env)
    end
  end
end

local function compute_bounds(items)
  local leftmost_start = math.huge
  local rightmost_end  = -math.huge
  for i = 1, #items do
    local pos, len = get_item_pos_len(items[i])
    local e = pos + len
    if pos < leftmost_start then leftmost_start = pos end
    if e > rightmost_end then rightmost_end = e end
  end
  return leftmost_start, rightmost_end
end

-- -------------------------------
-- Region Render Matrix helpers
-- -------------------------------

local function collect_region_ids(proj)
  local _, num_markers, num_regions = reaper.CountProjectMarkers(proj)
  local total = num_markers + num_regions
  local ids = {}
  for i = 0, total - 1 do
    local rv, isrgn, _, _, _, id = reaper.EnumProjectMarkers(i)
    if rv and isrgn then
      ids[id] = true
    end
  end
  return ids
end

local function find_region_by_bounds(proj, start_t, end_t, tol)
  tol = tol or 1e-4
  local _, num_markers, num_regions = reaper.CountProjectMarkers(proj)
  local total = num_markers + num_regions
  for i = 0, total - 1 do
    local rv, isrgn, pos, rgnend, _, id = reaper.EnumProjectMarkers(i)
    if rv and isrgn and math.abs(pos - start_t) <= tol and math.abs(rgnend - end_t) <= tol then
      return id
    end
  end
  return nil
end

local function find_new_region_id(proj, before_ids, start_t, end_t)
  local _, num_markers, num_regions = reaper.CountProjectMarkers(proj)
  local total = num_markers + num_regions
  for i = 0, total - 1 do
    local rv, isrgn, _, _, _, id = reaper.EnumProjectMarkers(i)
    if rv and isrgn and not before_ids[id] then
      return id
    end
  end
  return find_region_by_bounds(proj, start_t, end_t)
end

local function get_region_render_target_track(proj, items)
  local seen = {}
  local distinct = 0
  local only_track = nil

  for i = 1, #items do
    local tr = reaper.GetMediaItemTrack(items[i])
    local k = tostring(tr)
    if not seen[k] then
      seen[k] = true
      distinct = distinct + 1
      only_track = tr
      if distinct > 1 then break end
    end
  end

  if distinct == 1 and only_track then
    return only_track
  end
  return reaper.GetMasterTrack(proj)
end

local function set_region_matrix_checked(proj, region_id, track)
  if not region_id or not track then return false end

  if reaper.SetRegionRenderMatrix then
    reaper.SetRegionRenderMatrix(proj, region_id, track, 1)
    return true
  end

  if reaper.GetSetRegionRenderMatrix then
    reaper.GetSetRegionRenderMatrix(proj, region_id, track, 1)
    return true
  end

  return false
end

local function main()
  local sel_count = reaper.CountSelectedMediaItems(0)
  if sel_count ~= 1 and sel_count ~= 4 and sel_count ~= 6 then
    msg("Select either 1 item (within an adjacent run), or select exactly 4 items, or exactly 6 items.")
    return
  end

  local items = {}
  local mode_n = nil

  if sel_count == 6 or sel_count == 4 then
    for i = 0, sel_count - 1 do
      items[#items + 1] = reaper.GetSelectedMediaItem(0, i)
    end
    sort_items_by_pos(items)
    mode_n = sel_count
  else
    local sel_item = reaper.GetSelectedMediaItem(0, 0)
    local chosen, n = get_adjacent_window(sel_item)
    if not chosen then
      msg("With 1 selected item: could not derive a 4- or 6-item adjacent window. Increase MAX_GAP if needed.")
      return
    end
    items = chosen
    mode_n = n
  end

  if mode_n ~= 4 and mode_n ~= 6 then
    msg("Internal error: unsupported mode.")
    return
  end

  -- Automation copy is only defined per-track; keep the original behaviour:
  -- if items span multiple tracks, bail out rather than partially copying.
  if not all_on_same_track(items) then
    msg("All selected items must be on the same track (automation copy expects one track).")
    return
  end

  local track = reaper.GetMediaItemTrack(items[1])
  local leftmost_start, rightmost_end = compute_bounds(items)

  -- Determine reorder mapping
  local copy_order = {}
  if mode_n == 6 then
    -- time order: 1=A1,2=B1,3=C1,4=A2,5=B2,6=C2
    -- desired: A1,A2,B1,B2,C1,C2  => 1,4,2,5,3,6
    copy_order = { items[1], items[4], items[2], items[5], items[3], items[6] }
  else
    -- desired: 1,3,2,4
    copy_order = { items[1], items[3], items[2], items[4] }
  end

  -- Save existing time selection so it can be restored
  local old_ts_start, old_ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()

  -- Create clones + copy automation back-to-back, starting immediately after rightmost_end
  local new_items = {}
  local cur_pos = rightmost_end

  for i = 1, #copy_order do
    local src = copy_order[i]
    local src_pos, src_len = get_item_pos_len(src)
    local src_end = src_pos + src_len

    local new_item = clone_item_to_pos(src, cur_pos)
    if not new_item then
      reaper.Undo_EndBlock("Reorder items (failed)", -1)
      reaper.PreventUIRefresh(-1)
      msg("Failed while cloning items (state chunk error). No changes committed.")
      return
    end

    new_items[#new_items + 1] = new_item
    copy_track_automation_in_range(track, src_pos, src_end, cur_pos)

    cur_pos = cur_pos + src_len
  end

  -- Ripple-remove the ORIGINAL time span (pulls the new items left into place)
  reaper.GetSet_LoopTimeRange(true, false, leftmost_start, rightmost_end, false)
  reaper.Main_OnCommand(ACTION_TIMESEL_REMOVE_CONTENTS_MOVE_LATER, 0)

  -- Restore previous time selection
  reaper.GetSet_LoopTimeRange(true, false, old_ts_start, old_ts_end, false)

  -- Select the new items (now moved left)
  reaper.Main_OnCommand(ACTION_UNSELECT_ALL_ITEMS, 0)
  for i = 1, #new_items do
    reaper.SetMediaItemSelected(new_items[i], true)
  end

  -- Create/edit region from selected items, then tick Region Render Matrix for the new region
  local proj = 0
  local regions_before = collect_region_ids(proj)
  local r_start, r_end = compute_bounds(new_items)

  reaper.Main_OnCommand(ACTION_INSERT_REGION_FROM_SELECTED_ITEMS_AND_EDIT, 0)

  local new_region_id = find_new_region_id(proj, regions_before, r_start, r_end)
  local target_track = get_region_render_target_track(proj, new_items)
  set_region_matrix_checked(proj, new_region_id, target_track)

  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Reorder items (" .. tostring(mode_n) .. ") + ripple remove + automation + region", -1)
  reaper.PreventUIRefresh(-1)
end

main()
