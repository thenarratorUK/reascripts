-- @description Import multiple CSV marker files, align them to their corresponding regions, set project start time, and apply marker colors
-- @version 3.4 (cleaned, flexible region matching)
-- @author David Winter
-- @about This script reads CSV marker files, finds the corresponding region based on the filename, sets the edit cursor and project start time to the region start, and then imports markers with the proper color and relative positions.

-----------------------------------------------------------
-- Utility Functions
-----------------------------------------------------------

local function trim(s)
  return (s:gsub('^%s*"', ''):gsub('"%s*$', ''):gsub('^%s*', ''):gsub('%s*$', ''))
end

local function titleCase(str)
  return (str:gsub("(%S+)", function(word)
    return word:sub(1,1):upper() .. word:sub(2):lower()
  end))
end

-- Convert a hex color string (e.g., "FF0000" or "#FF0000") into a native integer color.
local function hexToNativeColor(hex)
  if not hex or hex == "" then 
    return 0 
  end
  hex = hex:gsub("#", "")
  if #hex < 6 then 
    return 0 
  end
  local r = tonumber(hex:sub(1,2), 16)
  local g = tonumber(hex:sub(3,4), 16)
  local b = tonumber(hex:sub(5,6), 16)
  if not (r and g and b) then
    return 0
  end
  return reaper.ColorToNative(r, g, b)
end

-----------------------------------------------------------
-- File & CSV Functions
-----------------------------------------------------------

local function readCSVFile(filepath)
    local lines = {}
    local f = io.open(filepath, "r")
    if not f then return nil end
    for line in f:lines() do
        table.insert(lines, line)
    end
    f:close()
    return lines
end

-- CSV parser that handles quoted fields.
local function parseCSVLine(text)
  local res = {}
  local pos = 1
  local len = #text
  while pos <= len do
    if text:sub(pos, pos) == '"' then
      local c = pos + 1
      local quoted = ""
      while c <= len do
        local char = text:sub(c, c)
        if char == '"' then
          if text:sub(c+1, c+1) == '"' then
            quoted = quoted .. '"'
            c = c + 2
          else
            c = c + 1
            break
          end
        else
          quoted = quoted .. char
          c = c + 1
        end
      end
      table.insert(res, quoted)
      if text:sub(c, c) == "," then c = c + 1 end
      pos = c
    else
      local startPos = pos
      local commaPos = text:find(",", pos)
      if commaPos then
        table.insert(res, text:sub(startPos, commaPos - 1))
        pos = commaPos + 1
      else
        table.insert(res, text:sub(startPos))
        break
      end
    end
  end
  return res
end

local function timeToSeconds(timeStr)
    if not timeStr or timeStr == "" then return nil end
    timeStr = timeStr:gsub(":(%d)([,%.])", ":0%1%2")
    local minutes, seconds = timeStr:match("(%d+):(%d+%.?%d*)")
    if minutes and seconds then
        return tonumber(minutes) * 60 + tonumber(seconds)
    end
    local minOnly, secOnly = timeStr:match("(%d+):(%d+)")
    if minOnly and secOnly then
        return tonumber(minOnly) * 60 + tonumber(secOnly)
    end
    return tonumber(timeStr)
end

-----------------------------------------------------------
-- Region-Related Functions
-----------------------------------------------------------

local function convertFilenameToRegionName(filename)
    local name = filename:gsub("%.csv$", "")
    name = name:gsub("%-?pozotron%-markers$", "")
    -- Replace underscore with colon
    name = name:gsub("_", ":")
    -- Ensure that any colon is followed by a space if it isn't already
    name = name:gsub(":(%S)", ": %1")
    -- Replace remaining hyphens with spaces
    name = name:gsub("%-", " ")
    -- Collapse extra spaces and trim.
    name = name:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return titleCase(name)
end

-- Normalize region names for matching: remove spaces, hyphens, and commas; convert to lower-case.
local function normalizeRegionName(name)
    return name:lower():gsub("[%W_]", "")
end

local function findRegionByName(regionName)
    local normRegion = normalizeRegionName(regionName)
    local idx = 0
    while true do
        local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers(idx)
        if not retval then break end
        if isrgn and normalizeRegionName(name) == normRegion then
            return pos, rgnend
        end
        idx = idx + 1
    end
    return nil, nil
end

-----------------------------------------------------------
-- Marker Import Function
-----------------------------------------------------------

local function importMarkersFromCSV(filepath, regionStart)
    local lines = readCSVFile(filepath)
    if not lines then return end

    for i, line in ipairs(lines) do
        if i > 1 then -- Skip header row
            local fields = parseCSVLine(line)
            
            local name = fields[2] or "Unnamed Marker"
            local rel_pos = timeToSeconds(fields[3])
            local rel_pos_end = timeToSeconds(fields[4])
            local csvColor = trim(fields[6] or "")
            if csvColor:upper() == "FF0000" then
                csvColor = "990000"
            end
            local color = hexToNativeColor(csvColor) | 0x1000000

            if rel_pos then
                local pos = regionStart + rel_pos
                local pos_end = regionStart + (rel_pos_end or 0)
                local isRegion = (rel_pos_end and rel_pos_end > rel_pos)
                local markerIndex = reaper.AddProjectMarker2(0, isRegion, pos, pos_end, name, -1, color)
                if isRegion and markerIndex >= 0 then
                    reaper.SetProjectMarker(markerIndex, isRegion, pos, pos_end, name, color)
                end
            end
        end
    end
end

-----------------------------------------------------------
-- Main Processing Logic
-----------------------------------------------------------

local function processCSVFiles(directory)
    local i = 0
    while true do
        local file = reaper.EnumerateFiles(directory, i)
        if not file then break end
        
        if file:match("%.csv$") then
            local filepath = directory .. "/" .. file
            local regionName = convertFilenameToRegionName(file)
            local regionStart, regionEnd = findRegionByName(regionName)
            if regionStart then
                reaper.SetEditCurPos(regionStart, false, false)
                reaper.SNM_SetDoubleConfigVar("projtimeoffs", -regionStart)
                reaper.PreventUIRefresh(1)
                importMarkersFromCSV(filepath, regionStart)
                reaper.PreventUIRefresh(-1)
                reaper.UpdateTimeline()
            end
        end
        i = i + 1
    end
end

local function deleteCSVFiles(directory)
  local i = 0
  while true do
    local file = reaper.EnumerateFiles(directory, i)
    if not file then break end
    if file:match("%.csv$") then
      os.remove(directory .. "/" .. file)
    end
    i = i + 1
  end
end

-----------------------------------------------------------
-- Script Entry Point
-----------------------------------------------------------

local projectPath = reaper.GetProjectPath(0, "")
-- Remove "/./Media" if present
projectPath = projectPath:gsub("/%./Media", "")
local directory = projectPath .. "/Pozotron"
processCSVFiles(directory)
deleteCSVFiles(directory)
