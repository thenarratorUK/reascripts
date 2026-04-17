-- @description Create Retail Sample Region
-- @version 1.2
-- @author David Winter
--[[
  Auto-Create Retail Sample Region (by time match)
  Author: David Winter
  Version: 1.2

  Description:
  - Creates a region from the current time selection
  - Automatically renames it to "99 Retail_Sample"
  - Identifies the region by matching the exact time selection
]]

-- Get time selection range
local timeStart, timeEnd = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)

-- If no time selection, do nothing
if timeEnd - timeStart <= 0 then return end

-- Insert region from time selection
reaper.Main_OnCommand(40174, 0)

-- Search for a region that exactly matches the time selection
local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
for i = 0, num_markers + num_regions - 1 do
  local retval, isrgn, pos, rgnend, name, idx = reaper.EnumProjectMarkers(i)
  if isrgn and math.abs(pos - timeStart) < 0.0001 and math.abs(rgnend - timeEnd) < 0.0001 then
    reaper.SetProjectMarker(idx, true, pos, rgnend, "99 Retail_Sample")
    break
  end
end
