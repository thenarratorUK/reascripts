-- @description Regions from SubProjects
-- @version 1.0
-- @author David Winter
-- Add Top-Level Regions for All Subprojects on Track 1
-- Deletes any region with matching name (or longest if >1)
-- Author: David Winter

-- Helper: Extract clean name from path
local function get_clean_name(filepath)
  local name = filepath:match("[^/\\]+$") or filepath
  return name:gsub("%.rpp%-prox$", ""):gsub("%.rpp$", "")
end

-- Save reference to master project
local master_proj, _ = reaper.EnumProjects(-1, "")

-- Get Track 1
local track = reaper.GetTrack(0, 0)
if not track then
  reaper.ShowMessageBox("Track 1 not found", "Error", 0)
  return
end

-- Collect all regions upfront
local all_regions = {}
local _, num_markers, num_regions = reaper.CountProjectMarkers(master_proj)
for j = 0, num_markers + num_regions - 1 do
  local _, isrgn, rgn_start, rgn_end, name, idx = reaper.EnumProjectMarkers(j)
  if isrgn and name ~= "" then
    table.insert(all_regions, {
      name = name,
      start = rgn_start,
      endt = rgn_end,
      len = rgn_end - rgn_start,
      idx = idx
    })
  end
end

-- Loop through ALL media items on Track 1
local item_count = reaper.CountTrackMediaItems(track)

for i = 0, item_count - 1 do
  local item = reaper.GetTrackMediaItem(track, i)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end = item_pos + item_len
  local take = reaper.GetActiveTake(item)

  if take then
    local source = reaper.GetMediaItemTake_Source(take)
    local filepath = reaper.GetMediaSourceFileName(source, "")
    local base_name = get_clean_name(filepath)

    -- Step 1: Find all regions with this name
    local matching = {}
    for _, r in ipairs(all_regions) do
      if r.name == base_name then
        table.insert(matching, r)
      end
    end

    -- Step 2: Delete either all of them (if 1), or longest one(s) (if >1)
    if #matching == 1 then
      reaper.DeleteProjectMarker(master_proj, matching[1].idx, true)
    elseif #matching > 1 then
      local max_len = 0
      for _, r in ipairs(matching) do
        if r.len > max_len then max_len = r.len end
      end
      for _, r in ipairs(matching) do
        if math.abs(r.len - max_len) < 0.0001 then
          reaper.DeleteProjectMarker(master_proj, r.idx, true)
        end
      end
    end

    -- Step 3: Add new wrapper region
    reaper.AddProjectMarker2(0, true, item_pos, item_end, base_name, -1, 0)
  end
end

reaper.UpdateArrange()
