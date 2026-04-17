-- @description ADR Script Import
-- @version 1.0
-- @author David Winter
--[[
CSV format (per line, after header):
Col1, Col2, Col3, Col4, ...
Region name will be: [Col1] - [Col4]
Start time = Col2, End time = Col3 (parsed with reaper.parse_timestr_pos using current time display format)
]]

local function msg(m) reaper.ShowMessageBox(m, "ADR Region Import", 0) end

-- Simple CSV parser with quoted-field support
local function parse_csv_line(line)
  local res, field, in_quotes = {}, "", false
  local i = 1
  while i <= #line do
    local c = line:sub(i,i)
    if in_quotes then
      if c == '"' then
        local nextc = line:sub(i+1,i+1)
        if nextc == '"' then
          field = field .. '"'
          i = i + 1
        else
          in_quotes = false
        end
      else
        field = field .. c
      end
    else
      if c == ',' then
        table.insert(res, field)
        field = ""
      elseif c == '"' then
        in_quotes = true
      else
        field = field .. c
      end
    end
    i = i + 1
  end
  table.insert(res, field)
  return res
end

local function trim(s) return (s:gsub("^%s+",""):gsub("%s+$","")) end

-- Determine CSV path one folder up from the project dir
local sep = package.config:sub(1,1)
local proj_dir = reaper.GetProjectPath("") or ""
-- remove trailing slash if any
if proj_dir:sub(-1) == sep then proj_dir = proj_dir:sub(1, -2) end
-- get parent folder
local parent_dir = proj_dir:match("^(.*)" .. sep)
local csv_path = parent_dir .. sep .. "ADR" .. sep .. "Import.csv"

reaper.Undo_BeginBlock()

-- 1) Read CSV and create regions
do
  local f = io.open(csv_path, "r")
  if not f then
    reaper.Undo_EndBlock("ADR: Import regions from CSV and create items", -1)
    return msg("Could not open CSV:\n" .. csv_path)
  end

  -- Skip header row
  local header = f:read("*l")

  local line_num = 1
  for line in f:lines() do
    line_num = line_num + 1
    if line and line ~= "" then
      local cols = parse_csv_line(line)
      if #cols >= 4 then
        local c1 = trim(cols[1] or "")
        local c2 = trim(cols[2] or "")
        local c3 = trim(cols[3] or "")
        local c4 = trim(cols[4] or "")

        local start_pos = reaper.parse_timestr_pos(c2, 0)
        local end_pos   = reaper.parse_timestr_pos(c3, 0)

        if start_pos and end_pos and end_pos > start_pos then
          local rgn_name = string.format("%s - %s", c1, c4)
          reaper.AddProjectMarker2(0, true, start_pos, end_pos, rgn_name, -1, 0)
        end
      end
    end
  end

  f:close()
end

-- 2) Create empty items for each region on the first track
do
  local num_markers, num_regions = reaper.CountProjectMarkers(0)

  local track = reaper.GetTrack(0, 0)
  if not track then
    reaper.InsertTrackAtIndex(0, true)
    reaper.TrackList_AdjustWindows(false)
    track = reaper.GetTrack(0, 0)
  end

  for i = 0, num_markers + num_regions - 1 do
    local retval, is_region, pos, rgn_end, name = reaper.EnumProjectMarkers3(0, i)
    if retval and is_region then
      local item = reaper.AddMediaItemToTrack(track)
      reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", rgn_end - pos)
      reaper.AddTakeToMediaItem(item)
      reaper.ULT_SetMediaItemNote(item, name or "")
    end
  end
end

reaper.UpdateArrange()
reaper.Undo_EndBlock("ADR: Import regions from CSV and create items from regions", -1)
