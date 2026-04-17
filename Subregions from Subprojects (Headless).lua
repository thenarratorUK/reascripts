-- @description Subregions from Subprojects (Headless)
-- @version 1.0
-- @author David Winter
-- Headless Subregion Extractor (with Subregion Deletion + RULERLANE handling)
-- Author: David Winter
-- Works without RULERLANE (legacy logic preserved)
-- If RULERLANE exists: only uses regions from lowest visible lane (by lane index)
-- Deletes previous subregions (excluding wrapper unless >1)
-- Adds dark red subregions in master project

local region_color = reaper.ColorToNative(120, 0, 0) | 0x1000000 -- dark red

local function get_rpp_path(filepath)
  return filepath:gsub("%.rpp%-prox$", ".rpp")
end

local function get_clean_name(filepath)
  local name = filepath:match("[^/\\]+$") or filepath
  return name:gsub("%.rpp%-prox$", ""):gsub("%.rpp$", "")
end

local function extract_regions_from_rpp(path)
  local regions = {}
  local file = io.open(path, "r")
  if not file then return regions end

  local lines = {}
  local has_rulerlane = false

  for line in file:lines() do
    if line:match("^%s*RULERLANE") then
      has_rulerlane = true
    end
    table.insert(lines, line)
  end
  file:close()

  -- === Legacy fallback ===
  if not has_rulerlane then
    local prev_marker = nil
    for _, line in ipairs(lines) do
      local mtype, pos_str, name = line:match('^%s*MARKER%s+(%d+)%s+([%d%.%-]+)%s+"(.-)"')
      if not mtype then
        mtype, pos_str, name = line:match('^%s*MARKER%s+(%d+)%s+([%d%.%-]+)%s+(%S+)')
      end
      if mtype and pos_str then
        local pos = tonumber(pos_str)
        name = name:gsub('"', ''):match("^%s*(.-)%s*$")
        if name ~= "" then
          prev_marker = { type = mtype, pos = pos, name = name }
        elseif prev_marker and prev_marker.type == mtype then
          table.insert(regions, {
            start = prev_marker.pos,
            endt = pos,
            name = prev_marker.name
          })
          prev_marker = nil
        end
      end
    end
    return regions
  end

  -- === RULERLANE mode: lane-aware start, simple next-line end ===

  -- Step 1: collect all visible lane indices
  local visible_lanes = {}
  visible_lanes[0] = true  -- Lane 0 is always visible
  for _, line in ipairs(lines) do
    local idx1, vis = line:match("^%s*RULERLANE%s+(%d+)%s+(%d+)")
    if idx1 and vis and tonumber(vis) == 1 then
      visible_lanes[tonumber(idx1)] = true
    end
  end

  -- Step 2: find the lowest visible lane
  local lowest_lane = nil
  for lane in pairs(visible_lanes) do
    if not lowest_lane or lane < lowest_lane then
      lowest_lane = lane
    end
  end

  -- Step 3: parse region pairs from valid starts
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local id, pos_str, name, lane_str = line:match('^%s*MARKER%s+(%d+)%s+([%d%.%-]+)%s+"(.-)"%s+%d+%s+%d+%s+%d+%s+%w+%s+%b{}%s+%d+%s+(%d+)')
    if id and pos_str and name and lane_str then
      local lane = tonumber(lane_str)
      if lane == lowest_lane then
        local start_pos = tonumber(pos_str)
        name = name:match("^%s*(.-)%s*$")
        local next_line = lines[i + 1]
        local end_pos = tonumber(next_line and next_line:match('^%s*MARKER%s+%d+%s+([%d%.%-]+)'))

        if end_pos then
          table.insert(regions, {
            start = start_pos,
            endt = end_pos,
            name = name
          })
        end

        i = i + 2
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  return regions
end

-- Start Undo Block
reaper.Undo_BeginBlock()

local master_proj, _ = reaper.EnumProjects(-1, "")
local track = reaper.GetTrack(0, 0)
if not track then
  reaper.ShowMessageBox("Track 1 not found", "Error", 0)
  return
end

local item_count = reaper.CountTrackMediaItems(track)
local _, num_markers, num_regions = reaper.CountProjectMarkers(master_proj)

for i = 0, item_count - 1 do
  local item = reaper.GetTrackMediaItem(track, i)
  if reaper.IsMediaItemSelected(item) then
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = item_pos + item_len

    local take = reaper.GetActiveTake(item)
    if take then
      local source = reaper.GetMediaItemTake_Source(take)
      local filepath = reaper.GetMediaSourceFileName(source, "")
      local rpp_path = get_rpp_path(filepath)
      local subproject_name = get_clean_name(filepath)

      -- Delete subregions inside bounds, keeping longest if multiple match subproject name
      local region_candidates = {}
      for j = num_markers + num_regions - 1, 0, -1 do
        local _, isrgn, rgn_start, rgn_end, rgn_name, rgn_idx = reaper.EnumProjectMarkers(j)
        if isrgn and rgn_end > item_pos and rgn_start < item_end then
          rgn_name = rgn_name or ""
          region_candidates[rgn_name] = region_candidates[rgn_name] or {}
          table.insert(region_candidates[rgn_name], {
            idx = rgn_idx,
            start = rgn_start,
            endt = rgn_end,
            len = rgn_end - rgn_start
          })
        end
      end

      for name, list in pairs(region_candidates) do
        if #list == 1 then
          if name ~= subproject_name then
            reaper.DeleteProjectMarker(master_proj, list[1].idx, true)
          end
        else
          table.sort(list, function(a, b) return a.len > b.len end)
          for i = 2, #list do
            reaper.DeleteProjectMarker(master_proj, list[i].idx, true)
          end
        end
      end

      -- Extract and add subregions
      local regions = extract_regions_from_rpp(rpp_path)
      for _, r in ipairs(regions) do
        local region_name = tostring(r.name or ""):match("^%s*(.-)%s*$")
        reaper.AddProjectMarker2(0, true, item_pos + r.start, item_pos + r.endt, region_name, -1, region_color)
      end
    end
  end
end

reaper.UpdateArrange()
reaper.Undo_EndBlock("Update subregions from subprojects", -1)
