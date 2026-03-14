--[[
  List Take FX on Items of Selected Track (Alphabetical, With Counts)

  Behaviour:
    - Uses the FIRST selected track in the project.
    - Looks at every media item on that track.
    - For each item:
        * Gets the active take.
        * Reads all Take FX on that take (if any).
    - Collects FX names, deduplicates them, and prints them
      alphabetically to the ReaScript console, with usage counts.
]]

local function msg(s)
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
end

-- Get first selected track
local track = reaper.GetSelectedTrack(0, 0)
if not track then
  reaper.ShowMessageBox("No track selected.\n\nPlease select the track and run again.", "Error", 0)
  return
end

local item_count = reaper.CountTrackMediaItems(track)
if item_count == 0 then
  reaper.ShowMessageBox("Selected track has no items.", "Info", 0)
  return
end

-- Collect FX names and counts
local fx_counts = {}
local total_fx_instances = 0
local total_items_with_fx = 0

for i = 0, item_count - 1 do
  local item = reaper.GetTrackMediaItem(track, i)
  if item then
    local take = reaper.GetActiveTake(item)
    if take then
      local fx_count = reaper.TakeFX_GetCount(take)
      if fx_count > 0 then
        total_items_with_fx = total_items_with_fx + 1
      end

      for fx = 0, fx_count - 1 do
        local _, fx_name = reaper.TakeFX_GetFXName(take, fx, "")
        if fx_name and fx_name ~= "" then
          -- Normalise name a bit (optional)
          fx_name = fx_name:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

          fx_counts[fx_name] = (fx_counts[fx_name] or 0) + 1
          total_fx_instances = total_fx_instances + 1
        end
      end
    end
  end
end

-- Prepare sorted list of names
local names = {}
for name, _ in pairs(fx_counts) do
  table.insert(names, name)
end
table.sort(names, function(a, b)
  return a:lower() < b:lower()
end)

-- Output to console
reaper.ShowConsoleMsg("") -- clear console
msg("Take FX on items of first selected track (alphabetical):")
msg("------------------------------------------------------")
msg(string.format("Items on track:           %d", item_count))
msg(string.format("Items with at least 1 FX: %d", total_items_with_fx))
msg(string.format("Total FX instances:       %d", total_fx_instances))
msg(string.format("Unique FX names:          %d", #names))
msg("")

if #names == 0 then
  msg("No take FX found on any items of the selected track.")
else
  for _, name in ipairs(names) do
    local count = fx_counts[name] or 0
    msg(string.format("%s  (x%d)", name, count))
  end
end
