-- @description Convert Streamlit proofing_log.csv into Pozotron marker CSVs (one per audio file)
-- @version 1.1
-- @author David Winter
-- @about
--   Reads a single CSV exported from the Streamlit "Proofing Logger" app and writes multiple
--   Pozotron-style marker CSVs to the project's /Pozotron folder, ready for "Bulk Import Pozotron Pickups.lua".
--
--   Input CSV columns expected (header row):
--     audio_file,time_sec,timecode,label,note,logged_at_epoch
--
--   Output CSV columns:
--     #,Name,Start,End,Length,Color
--
--   Rules:
--   - Each output CSV is per-audio file, grouped by column "audio_file".
--   - Output CSV filename is derived from the audio filename stem, with transformations only:
--       * keep underscores (importer maps "_" -> ":" in region names)
--       * replace spaces with hyphens (importer maps "-" -> space in region names)
--       * no forced "-pozotron-markers" suffix
--       * extension is .csv
--   - Name is "#<Label>" (no numeric index in the Name). If note is non-empty, append ": <note>".
--   - Start is from the logged time; End = Start + 1.000; Length = 1.000.
--   - Times are written as TOTAL_MINUTES:SS.mmm (no hours), because the importer parses mm:ss(.ms).
--   - Color is a 6-hex value; edit DEFAULT_COLOR if desired.

-----------------------------------------------------------
-- Config
-----------------------------------------------------------

local DEFAULT_COLOR = "990000"  -- 6-hex; adjust as desired

-----------------------------------------------------------
-- Utility
-----------------------------------------------------------

local function trim(s)
  s = tostring(s or "")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function fileExists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function readAllLines(filepath)
  local lines = {}
  local f = io.open(filepath, "r")
  if not f then return nil end
  for line in f:lines() do
    lines[#lines+1] = line
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
        local ch = text:sub(c, c)
        if ch == '"' then
          if text:sub(c+1, c+1) == '"' then
            quoted = quoted .. '"'
            c = c + 2
          else
            c = c + 1
            break
          end
        else
          quoted = quoted .. ch
          c = c + 1
        end
      end
      res[#res+1] = quoted
      if text:sub(c, c) == "," then c = c + 1 end
      pos = c
    else
      local startPos = pos
      local commaPos = text:find(",", pos)
      if commaPos then
        res[#res+1] = text:sub(startPos, commaPos - 1)
        pos = commaPos + 1
      else
        res[#res+1] = text:sub(startPos)
        break
      end
    end
  end

  return res
end

local function csvEscape(s)
  s = tostring(s or "")
  if s:find('[,"\n\r]') then
    s = s:gsub('"', '""')
    return '"' .. s .. '"'
  end
  return s
end

local function parseTimecodeToSeconds(timeStr)
  timeStr = trim(timeStr)
  if timeStr == "" then return nil end

  -- HH:MM:SS(.mmm)
  local h, m, s = timeStr:match("^(%d+):(%d+):(%d+%.?%d*)$")
  if h and m and s then
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
  end

  -- MM:SS(.mmm)
  local mm, ss = timeStr:match("^(%d+):(%d+%.?%d*)$")
  if mm and ss then
    return tonumber(mm) * 60 + tonumber(ss)
  end

  -- seconds as number
  return tonumber(timeStr)
end

local function secondsToTotalMinutesString(seconds)
  seconds = tonumber(seconds or 0) or 0
  if seconds < 0 then seconds = 0 end
  local totalMin = math.floor(seconds / 60)
  local sec = seconds - (totalMin * 60)
  -- "M:SS.mmm" with zero-padded seconds
  return string.format("%d:%06.3f", totalMin, sec)
end

local function stemNoExt(filename)
  filename = tostring(filename or ""):gsub("\\", "/")
  filename = filename:match("^.+/(.+)$") or filename
  local stem = filename:gsub("%.[^%.]+$", "")
  return trim(stem)
end

local function makeOutputCSVFilenameFromAudio(audioFile)
  local stem = stemNoExt(audioFile)

  -- Keep underscores (importer maps "_" -> ":"), replace spaces with hyphens (importer maps "-" -> " ")
  stem = stem:gsub("%s+", "-")

  -- Clean up any accidental repeated hyphens
  stem = stem:gsub("%-+", "-")

  -- Guard against empty
  if stem == "" then stem = "Unnamed" end

  return stem .. ".csv"
end

local function sortMarkers(a, b)
  if a.time_sec ~= b.time_sec then
    return a.time_sec < b.time_sec
  end
  return (a.logged_at or 0) < (b.logged_at or 0)
end

-----------------------------------------------------------
-- Main
-----------------------------------------------------------

reaper.Undo_BeginBlock()

local projectPath = reaper.GetProjectPath(0, "")
projectPath = projectPath:gsub("/%./Media", "")

local pickupsDir = projectPath .. "/Pickups"
local pozotronDir = projectPath .. "/Pozotron"
local defaultInput = pickupsDir .. "/proofing_log.csv"

local ok, inputPath = reaper.GetUserFileNameForRead(
  fileExists(defaultInput) and defaultInput or "",
  "Select Streamlit proofing_log CSV",
  "csv"
)

if not ok or not inputPath or inputPath == "" then
  reaper.Undo_EndBlock("Convert Streamlit log to Pozotron CSVs (cancelled)", -1)
  return
end

local lines = readAllLines(inputPath)
if not lines or #lines < 2 then
  reaper.ShowMessageBox("Input CSV is empty (or only header).", "Streamlit -> Pozotron", 0)
  reaper.Undo_EndBlock("Convert Streamlit log to Pozotron CSVs (no-op)", -1)
  return
end

-- Ensure output directory exists.
if reaper.RecursiveCreateDirectory then
  reaper.RecursiveCreateDirectory(pozotronDir, 0)
else
  os.execute(string.format('mkdir "%s"', pozotronDir))
end

-- Map header columns by name (case-insensitive).
local header = parseCSVLine(lines[1])
local col = {}
for i = 1, #header do
  local key = trim(header[i]):lower()
  col[key] = i
end

local idx_audio    = col["audio_file"] or col["audiofile"] or 1
local idx_time_sec = col["time_sec"] or col["timesec"]
local idx_timecode = col["timecode"]
local idx_label    = col["label"]
local idx_note     = col["note"]
local idx_logged   = col["logged_at_epoch"] or col["loggedatepoch"]

-- Group markers by audio_file.
local groups = {}
local totalRows = 0

for i = 2, #lines do
  local fields = parseCSVLine(lines[i])
  local audioFile = trim(fields[idx_audio] or "")
  if audioFile ~= "" then
    local time_sec = nil

    if idx_time_sec then
      time_sec = tonumber(fields[idx_time_sec] or "")
    end
    if not time_sec and idx_timecode then
      time_sec = parseTimecodeToSeconds(fields[idx_timecode] or "")
    end
    time_sec = tonumber(time_sec or 0) or 0

    local label = trim((idx_label and fields[idx_label]) or "")
    local note  = trim((idx_note and fields[idx_note]) or "")
    local logged_at = tonumber((idx_logged and fields[idx_logged]) or "") or 0

    groups[audioFile] = groups[audioFile] or {}
    groups[audioFile][#groups[audioFile] + 1] = {
      time_sec = time_sec,
      label = label,
      note = note,
      logged_at = logged_at,
    }
    totalRows = totalRows + 1
  end
end

if totalRows == 0 then
  reaper.ShowMessageBox("No usable rows found (audio_file column empty).", "Streamlit -> Pozotron", 0)
  reaper.Undo_EndBlock("Convert Streamlit log to Pozotron CSVs (no rows)", -1)
  return
end

local function writeMarkerCSV(outPath, markers)
  table.sort(markers, sortMarkers)

  local f = io.open(outPath, "w")
  if not f then return false end

  f:write("#,Name,Start,End,Length,Color\n")

  for idx = 1, #markers do
    local m = markers[idx]
    local label = (m.label ~= "" and m.label) or "Marker"

    -- Name: "#<Label>" (no numeric prefix). Append note if present.
    local name = "#" .. label
    if m.note ~= "" then
      name = name .. ": " .. m.note
    end

    local startS = m.time_sec
    local endS = startS + 1.0

    local row = {
      tostring(idx),
      csvEscape(name),
      secondsToTotalMinutesString(startS),
      secondsToTotalMinutesString(endS),
      secondsToTotalMinutesString(1.0),
      DEFAULT_COLOR,
    }

    f:write(table.concat(row, ",") .. "\n")
  end

  f:close()
  return true
end

local written = 0
local failed = 0

for audioFile, markers in pairs(groups) do
  local outName = makeOutputCSVFilenameFromAudio(audioFile)
  local outPath = pozotronDir .. "/" .. outName
  if writeMarkerCSV(outPath, markers) then
    written = written + 1
  else
    failed = failed + 1
  end
end

local msg = string.format(
  "Converted %d log row(s) into %d marker CSV file(s).\n\nOutput folder:\n%s",
  totalRows, written, pozotronDir
)

if failed > 0 then
  msg = msg .. string.format("\n\nFailed writes: %d", failed)
end

reaper.ShowMessageBox(msg, "Streamlit -> Pozotron", 0)

reaper.Undo_EndBlock("Convert Streamlit proofing log to Pozotron CSVs", -1)
