-- @description SubRegions from SubProjects
-- @version 1.0
-- @author David Winter
-- Add Subregions from Selected Subprojects via Tabs (Name-Safe Deletion + Dark Red)
-- Author: David Winter

-- Colour for subregions (dark red)
local region_color = reaper.ColorToNative(128, 0, 0) | 0x1000000

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

-- Loop through only selected items on Track 1
local item_count = reaper.CountTrackMediaItems(track)

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
      filepath = filepath:gsub("%.rpp%-prox$", ".rpp")
      local subproj_name = get_clean_name(filepath)

      -- Step 1: Delete existing regions fully within this item range,
      -- except for regions whose name exactly matches the subproject
      local _, num_markers, num_regions = reaper.CountProjectMarkers(master_proj)
      for j = num_markers + num_regions - 1, 0, -1 do
        local _, isrgn, rgn_start, rgn_end, name, idx = reaper.EnumProjectMarkers(j)
        if isrgn and name ~= subproj_name then
          if rgn_start >= item_pos and rgn_end <= item_end then
            reaper.DeleteProjectMarker(master_proj, idx, true)
          end
        end
      end

      -- Step 2: Open in new tab
      reaper.Main_OnCommand(40859, 0) -- New tab
      reaper.Main_openProject(filepath)

      -- Step 3: Parse subregions
      local sub_proj, _ = reaper.EnumProjects(-1, "")
      if sub_proj then
        local subregions = {}
        local _, _, num_markers = reaper.CountProjectMarkers(sub_proj)
        for j = 0, num_markers + 20 do
          local retval, isrgn, rgn_start, rgn_end, name = reaper.EnumProjectMarkers3(sub_proj, j)
          if retval and isrgn and name and name ~= "" then
            table.insert(subregions, {
              start = rgn_start,
              endt = rgn_end,
              name = name
            })
          end
        end

        -- Step 4: Add regions to master
        reaper.SelectProjectInstance(master_proj)
        for _, r in ipairs(subregions) do
          reaper.AddProjectMarker2(0, true, item_pos + r.start, item_pos + r.endt, r.name, -1, region_color)
        end

        -- Step 5: Close subproject tab
        reaper.SelectProjectInstance(sub_proj)
        reaper.Main_OnCommand(40860, 0) -- Close current project tab
        reaper.SelectProjectInstance(master_proj)
      end
    end
  end
end

reaper.UpdateArrange()
