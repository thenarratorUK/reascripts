-- @description Pay Calculator
-- @version 1.0
-- @author David Winter
--[[
Ridiculously Complicated Pay Calculator from Selected Tracks

For all currently selected tracks:
  - Collect all take source filenames matching Number_Name_Take#.wav
  - Normalise them to Number_Name_TakeX.wav and deduplicate
  - Count:
      Lines   = number of unique normalised filenames
      Words   = sum of word counts from CSV column 2
                where CSV column 3 == normalised filename
      Duration (seconds) = sum of the length of the first item
                           using Number_Name_Take1.wav
                           for each normalised filename
  - Compute pay based on Word, Line and PFH rates
  - Print everything in the console

Author: David Winter
Language: Lua (ReaScript)
]]--

--------------------------------------
-- USER SETTINGS
--------------------------------------

-- Rates in USD (dollars.cents)
local Word_Rate  = 0.10     -- pay per word
local Line_Rate  = 2.00     -- pay per line
local PFH_Rate   = 235.00   -- pay per finished hour

--------------------------------------
-- HELPER FUNCTIONS
--------------------------------------

local function msg(s)
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
end

-- Trim leading/trailing whitespace
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Extract base filename (no path)
local function basename(path)
  return path:match("([^/\\]+)$") or path
end

-- Normalise filename:
--  "01234_Bob_Take1.wav" -> "01234_Bob_TakeX.wav"
-- Returns nil if not matching the pattern.
local function normalise_take_filename(fname)
  -- Expect: Number_Name_Take#.wav
  -- Example: 01234_Bob_Take1.wav
  local prefix, num = fname:match("^(%d+_.-_Take)(%d+)%.wav$")
  if prefix and num then
    return prefix .. "X.wav"
  end
  return nil
end

-- Check if filename is a Take1 variant
-- Returns true if it is exactly Number_Name_Take1.wav
local function is_take1_filename(fname)
  return fname:match("^(%d+_.-_Take)1%.wav$") ~= nil
end

-- Normalise a CSV column-3 value (which may not include .wav)
-- into the same canonical form as normalized_list (Number_Name_TakeX.wav)
local function normalise_csv_filename(col3_raw)
  if not col3_raw or col3_raw == "" then return nil end

  local base3 = basename(trim(col3_raw))
  if base3 == "" then return nil end

  -- Ensure it ends with .wav (case-insensitive); if not, pretend it does
  if not base3:lower():match("%.wav$") then
    base3 = base3 .. ".wav"
  end

  -- If it's already Number_Name_TakeX.wav, accept as-is
  if base3:match("^(%d+_.-_Take)X%.wav$") then
    -- normalise extension to lower-case .wav
    return base3:gsub("%.WAV$", ".wav")
  end

  -- Otherwise, if it's Number_Name_TakeN.wav (digit), normalise via existing helper
  local norm = normalise_take_filename(base3)
  if norm then
    return norm
  end

  -- If nothing matches, give up (this row won't be used)
  return nil
end

-- Simple CSV line parser with quote support:
-- - Comma-separated
-- - Double quotes around fields allowed
-- - Double-double-quotes inside quoted fields -> one literal quote
local function parse_csv_line(line)
  local res = {}
  local field = ""
  local in_quotes = false
  local i = 1
  local len = #line

  while i <= len do
    local c = line:sub(i, i)

    if c == '"' then
      if in_quotes and i < len and line:sub(i + 1, i + 1) == '"' then
        -- Escaped double quote
        field = field .. '"'
        i = i + 1
      else
        in_quotes = not in_quotes
      end

    elseif c == ',' and not in_quotes then
      table.insert(res, field)
      field = ""

    else
      field = field .. c
    end

    i = i + 1
  end

  table.insert(res, field)
  return res
end

-- Build full path: project_path + sep + "../Sources"
local function get_sources_folder()
  local proj_path = reaper.GetProjectPath("") or ""
  proj_path = trim(proj_path)

  if proj_path == "" then
    return nil
  end

  -- package.config: first char is directory separator on this OS
  local sep = package.config:sub(1, 1)
  local folder = proj_path .. sep .. "../Sources"
  return folder, sep
end

-- Find the sole CSV file in the Sources folder
local function find_sources_csv(sources_folder)
  local csv_name = nil
  local i = 0

  while true do
    local fname = reaper.EnumerateFiles(sources_folder, i)
    if not fname then break end

    if fname:lower():sub(-4) == ".csv" then
      if not csv_name then
        csv_name = fname
      else
        -- Second CSV found; still use the first, but you could warn here
      end
    end
    i = i + 1
  end

  return csv_name
end

--------------------------------------
-- MAIN
--------------------------------------

reaper.ClearConsole()

-- Collect normalised filenames and map Take1 durations
local normalized_list = {}           -- list of unique normalised filenames
local normalized_seen = {}           -- set for dedupe
local take1_durations = {}           -- key: "01234_Bob_Take1.wav" -> first item length (seconds)

do
  local proj = 0
  local track_count = reaper.CountTracks(proj)

  for ti = 0, track_count - 1 do
    local tr = reaper.GetTrack(proj, ti)
    if tr and reaper.IsTrackSelected(tr) then
      local item_count = reaper.CountTrackMediaItems(tr)
      for ii = 0, item_count - 1 do
        -- Get item directly from this track
        local item = reaper.GetTrackMediaItem(tr, ii)
        if item then
          local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

          local take_count = reaper.CountTakes(item)
          for tii = 0, take_count - 1 do
            local take = reaper.GetMediaItemTake(item, tii)
            if take then
              local src = reaper.GetMediaItemTake_Source(take)
              if src then
                local path = reaper.GetMediaSourceFileName(src, "")
                if path and path ~= "" then
                  local base = basename(path)

                  -- Step 1: build the normalised list from all takes
                  local normalized = normalise_take_filename(base)
                  if normalized then
                    if not normalized_seen[normalized] then
                      normalized_seen[normalized] = true
                      table.insert(normalized_list, normalized)
                    end
                  end

                  -- Step 2: map Take1 filenames to first encountered item length
                  if is_take1_filename(base) and take1_durations[base] == nil then
                    take1_durations[base] = item_len
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

local Lines = #normalized_list

-- If there are no matching filenames, we can still output zeros
if Lines == 0 then
  msg("No matching Number_Name_Take#.wav filenames found on selected tracks.")
end

-- Locate Sources CSV
local sources_folder, sep = get_sources_folder()
if not sources_folder then
  msg("ERROR: Could not determine project path; cannot locate ../Sources/ folder.")
  return
end

local csv_file_name = find_sources_csv(sources_folder)
if not csv_file_name then
  msg("ERROR: No CSV file found in " .. sources_folder)
  return
end

local csv_path = sources_folder .. sep .. csv_file_name

-- Build a map from normalised filename -> column2 text
-- Key format: Number_Name_TakeX.wav
local csv_map = {}

do
  local f = io.open(csv_path, "r")
  if not f then
    msg("ERROR: Could not open CSV file: " .. csv_path)
    return
  end

  for line in f:lines() do
    if line ~= "" then
      local cols = parse_csv_line(line)
      -- We need at least 3 columns
      if #cols >= 3 then
        local col2 = trim(cols[2] or "")
        local col3_raw = trim(cols[3] or "")

        if col3_raw ~= "" then
          -- Normalise CSV filename to canonical form
          local key = normalise_csv_filename(col3_raw)

          if key and key ~= "" then
            -- Store first occurrence; ignore duplicates
            if not csv_map[key] then
              csv_map[key] = col2
            end
          end
        end
      end
    end
  end

  f:close()
end

-- Now, compute Words and Duration based on the normalised list
local Words = 0
local Duration = 0.0

for _, normalized in ipairs(normalized_list) do
  -- 1) Word count from CSV
  local text = csv_map[normalized]
  if text and text ~= "" then
    local wcount = 0
    for _ in text:gmatch("%S+") do
      wcount = wcount + 1
    end
    Words = Words + wcount
  end

  -- 2) Duration using Take1
  --    Replace "X.wav" with "1.wav" at the end
  local take1_name = normalized:gsub("X%.wav$", "1.wav")
  local len = take1_durations[take1_name]
  if len then
    Duration = Duration + len
  end
end

-- Derived rates and pays
local Duration_Rate = PFH_Rate / (60 * 60)

local Word_Based_Pay     = Words   * Word_Rate
local Line_Based_Pay     = Lines   * Line_Rate
local Duration_Based_Pay = Duration * Duration_Rate

--------------------------------------
-- OUTPUT
--------------------------------------

reaper.ClearConsole()

msg(string.format("Words = %d words", Words))
msg(string.format("Word_Rate = %.2f (USD)", Word_Rate))
msg(string.format("Word_Based_Pay = %.2f (USD)", Word_Based_Pay))
msg("")

msg(string.format("Lines = %d lines", Lines))
msg(string.format("Line_Rate = %.2f (USD)", Line_Rate))
msg(string.format("Line_Based_Pay = %.2f (USD)", Line_Based_Pay))
msg("")

msg(string.format("Duration = %.3f seconds", Duration))
msg(string.format("Duration_Rate = %.6f (USD)", Duration_Rate))
msg(string.format("Duration_Based_Pay = %.2f (USD)", Duration_Based_Pay))
