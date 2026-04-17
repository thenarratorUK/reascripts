-- @description Build & Update from ./Sources CSV (fully explained inline; variable placeholders; A/B routes)
-- @version 3.3
-- @author David Winter
--[[
ReaScript Name  : Build & Update from ./Sources CSV (fully explained inline; variable placeholders; A/B routes)
Author          : David Winter
Version         : 3.3 (2025-11-16)

High-level behaviour: 
- Exactly one CSV file must exist in <project>/Sources/. If none or more than one: stop with an error.
- CSV has a header row (ignored). Columns by position:
    1 Speaker (e.g., Narrator, John)
    2 Dialogue (free text)
    3 Filename (ends with _TakeX or _TakeXX; leading line index may be 5–7+ digits)
    4 Track (OPTIONAL): if present and non-empty on that row, use this as the track name; else use Speaker
- For each CSV row, in order:
    • If audio exists for base (= filename without _TakeX and without extension): insert all takes as takes on a single item.
    • If no audio exists yet: insert a placeholder with length = ceil(words * 60 / 155).
- When rerun (Route B):
    • For placeholders (0/empty takes): if audio now exists, DELETE placeholder (ripple-all compacts), then insert real item at same start.
    • For items with takes: search for next take numbers and append any new ones; extend item length if longer.
- Always prefer .wav over .mp3 for a given take index.
- Always enable ripple editing: ALL TRACKS (so timeline compacts correctly on delete+reinsert).

Everything else below is implementation detail: 
]]


------------------------------------------------------------
-- SECTION 1: Basic helpers for paths, files, and messages --
------------------------------------------------------------

-- Tiny helper 'log' to print diagnostic text into REAPER's console.
local function log(s)
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
end

-- Collect names of new take files added in Route B (this run only).
local routeB_new_files = {}
local routeB_new_files_set = {}

-- We need the project to be SAVED so we can calculate the absolute path of './Sources'.
local proj, proj_fn = reaper.EnumProjects(-1, "")
if not proj or proj == 0 then
  reaper.MB(
    "Please save the project first so the ./Sources folder can be resolved.",
    "Project not saved",
    0
  )
  return
end

-- Obtain the project directory path on disk so we can point to '<project>/Sources'.
-- In Lua ReaScript, GetProjectPathEx returns the path as a single string.
local proj_dir = reaper.GetProjectPathEx(proj, "", 4096)

-- Different operating systems use different path separators ('/' vs '\').
local SEP = package.config:sub(1,1)

-- If the project path ends with a trailing separator, strip it so joining paths is clean.
if proj_dir:sub(-1) == SEP then
  proj_dir = proj_dir:sub(1, -2)
end

-- Helper to join two path parts safely using the correct separator.
local function join(a, b)
  return a .. SEP .. b
end

-- Build absolute path to ../Sources (one level up from the media path).
local sources_dir = join(proj_dir, "..")
sources_dir = join(sources_dir, "Sources")

-- Function to test if a given file path exists.
local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

-- Enumerate files in 'sources_dir' and pick out those with '.csv' extension.
local function list_csvs(dir)
  local out = {}
  local i = 0
  while true do
    local name = reaper.EnumerateFiles(dir, i)
    if not name then break end
    if name:lower():sub(-4) == ".csv" then
      table.insert(out, name)
    end
    i = i + 1
  end
  return out
end

-- Trim leading and trailing whitespace from a string.
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Return the length (in seconds) of the longest file in 'files'. 
local function get_longest_source_length(files)
  local longest = 0.0
  for _, path in ipairs(files) do
    local src = reaper.PCM_Source_CreateFromFile(path)
    if src then
      local len = reaper.GetMediaSourceLength(src)
      if len > longest then
        longest = len
      end
    end
  end
  return longest
end

-- Post-check: ensure all relevant audio files in ./Sources exist in the project media folder.
-- Rules:
--   - Consider only .wav and .mp3 files in Sources.
--   - If a .mp3 has a .wav with the same stem in Sources, the .mp3 is allowed to be absent in media.
--   - Otherwise, every audio file in Sources should also exist in the media folder (proj_dir).
local function check_sources_vs_media_folder()
  local wav_stems = {}
  local audio_files = {}

  -- Enumerate all files in Sources
  local i = 0
  while true do
    local name = reaper.EnumerateFiles(sources_dir, i)
    if not name then break end

    local lower = name:lower()

    -- Skip CSV and any other non-audio files
    if lower:sub(-4) == ".wav" then
      local stem = name:sub(1, -5)  -- strip ".wav"
      wav_stems[stem] = true
      table.insert(audio_files, name)
    elseif lower:sub(-4) == ".mp3" then
      table.insert(audio_files, name)
    end

    i = i + 1
  end

  -- Now check each audio file against the media folder
  local missing = {}

  for _, name in ipairs(audio_files) do
    local lower = name:lower()
    local stem  = name:sub(1, -5)  -- strip extension

    local require_in_media = true

    -- If this is an .mp3 and there is a .wav with the same stem in Sources,
    -- we do NOT require the .mp3 to be in the media folder.
    if lower:sub(-4) == ".mp3" and wav_stems[stem] then
      require_in_media = false
    end

    if require_in_media then
      local media_path = join(proj_dir, name)
      if not file_exists(media_path) then
        table.insert(missing, name)
      end
    end
  end

  if #missing > 0 then
      local msg = "The following audio files exist in ./Sources but not in the project media folder:\n\n"
      for _, n in ipairs(missing) do
        msg = msg .. n .. "\n"
      end
      msg = msg ..
        "\nThis usually means at least one file was not copied to the media folder on import,\n" ..
        "or has been moved/renamed outside REAPER.\n\n" ..
        "Note: .mp3 files are allowed to be missing if a .wav with the same stem exists in ./Sources."
  
      reaper.MB(msg, "Sources vs Media Folder Check", 0)
    else
      reaper.MB("All relevant audio files in ./Sources have matching files in the project media folder.", 
                "Sources vs Media Folder Check", 0)
    end
end

-- Ensure a media file is present in the project media folder.
-- Given a full path in Sources, returns the path to use for REAPER:
--   - If a file with the same name already exists in proj_dir, return that.
--   - Otherwise copy the Sources file into proj_dir and return the new path.
local function ensure_media_in_project_folder(src_path)
  if not src_path or src_path == "" then
    return src_path
  end

  -- Extract just the filename
  local name = src_path:match("([^" .. SEP .. "]+)$") or src_path
  local dest_path = join(proj_dir, name)

  -- If already in media folder, use it
  if file_exists(dest_path) then
    return dest_path
  end

  -- Try to copy from Sources to media folder
  local in_f = io.open(src_path, "rb")
  if not in_f then
    -- Fall back to original path if copy fails
    return src_path
  end

  local data = in_f:read("*all")
  in_f:close()

  local out_f = io.open(dest_path, "wb")
  if not out_f then
    -- Fall back to original path if we can't write
    return src_path
  end

  out_f:write(data)
  out_f:close()

  return dest_path
end

--------------------------------------------------------------------
-- SECTION 2: Reading the CSV (header + 3 or 4 columns per row)  --
--------------------------------------------------------------------

-- Split a CSV line into fields, respecting quoted fields and commas inside quotes.
local function csv_split_line(line)
  local res = {}
  local i, len = 1, #line

  while i <= len do
    if line:sub(i,i) == '"' then
      local j = i + 1
      local chunk = ""

      while j <= len do
        local c = line:sub(j,j)
        if c == '"' then
          if j + 1 <= len and line:sub(j+1, j+1) == '"' then
            chunk = chunk .. '"'
            j = j + 2
          else
            j = j + 1
            break
          end
        else
          chunk = chunk .. c
          j = j + 1
        end
      end

      table.insert(res, chunk)
      if j <= len and line:sub(j,j) == "," then
        j = j + 1
      end
      i = j
    else
      local j = line:find(",", i, true) or (len + 1)
      table.insert(res, trim(line:sub(i, j - 1)))
      i = j + 1
    end
  end

  return res
end

-- Count words in a dialogue string (used to size placeholders).
-- Ignores trailing metadata like [01234_Narration] and (optionally) leading "Speaker:" labels.
local function word_count(s)
  if not s or s == "" then return 0 end

  -- If the string contains a bracket tag, we treat it as metadata.
  local had_bracket_tag = (s:find("%b[]") ~= nil)

  -- Remove any balanced [ ... ] blocks (e.g. [01234_Narration]).
  s = s:gsub("%b[]", " ")

  -- If there was a bracket tag, also strip a leading "Speaker: " label.
  -- This avoids counting "Narration:" as a spoken word when the line is actually a note line.
  if had_bracket_tag then
    s = s:gsub("^%s*[^:]+:%s+", "")
  end

  -- Count tokens: letters/digits with optional internal apostrophes or hyphens.
  local cnt = 0
  for _ in s:gmatch("[%a%d]+[%a%d'’%-]*") do
    cnt = cnt + 1
  end
  return cnt
end

-- Read the CSV rows from disk and convert them into a uniform structure.
-- Supports quoted fields that span multiple physical lines. 
-- Ignore header row; each data row => { speaker, dialogue, filename, track_override }
local function parse_csv_rows(csv_path)
  local rows = {}

  local f = io.open(csv_path, "r")
  if not f then
    return rows, "Cannot open CSV: " .. csv_path
  end

  -- Count unescaped double quotes (") in a string, ignoring "" escapes. 
  local function count_unescaped_quotes(s)
    local count = 0
    local i = 1
    while true do
      local pos = s:find('"', i, true)
      if not pos then break end
      local nextc = s:sub(pos + 1, pos + 1)
      if nextc == '"' then
        -- Escaped quote ("") -> skip both
        i = pos + 2
      else
        count = count + 1
        i = pos + 1
      end
    end
    return count
  end

  local logical_line = nil  -- buffer for a full CSV row (may span multiple physical lines)
  local line_num = 0        -- counts logical rows, not physical lines

  for raw in f:lines() do
    if not logical_line then
      logical_line = raw
    else
      -- Append with newline, preserving the fact that the quoted field truly contained a newline. 
      logical_line = logical_line .. "\n" .. raw
    end

    local q = count_unescaped_quotes(logical_line)
    if q % 2 == 1 then
      -- Odd number of quotes so far -> we're inside an open quoted field; keep accumulating.
      -- Do NOT process this yet.
    else
      -- Balanced quotes: we now have a full logical CSV record in 'logical_line'.
      line_num = line_num + 1
      local line = logical_line
      logical_line = nil

      if trim(line) ~= "" then
        if line_num == 1 then
          -- Header row: ignore
        else
          local fields = csv_split_line(line)
          local speaker  = trim(fields[1] or "")
          local dialogue = trim(fields[2] or "")
          local filename = trim(fields[3] or "")
          local trackov  = trim(fields[4] or "")

          if speaker ~= "" and filename ~= "" then
            local track_override = (trackov ~= "" and trackov or nil)
            table.insert(rows, {
              speaker        = speaker,
              dialogue       = dialogue,
              filename       = filename,
              track_override = track_override
            })
          end
        end
      end
    end
  end

  f:close()

  -- If logical_line is not nil here, the file ended while still inside an open quote. 
  if logical_line ~= nil then
    return rows, "CSV appears to end with an unterminated quoted field."
  end

  return rows
end



---------------------------------------------------------------------------------------
-- SECTION 3: Filename / base helpers and discovering available takes for that base  --
---------------------------------------------------------------------------------------

-- From e.g. "00001_Narrator_Take1.wav" -> "00001_Narrator"
local function base_from_filename(fn)
  local no_ext = fn:gsub("%.(wav|mp3)$", "")
  no_ext = no_ext:gsub("_Take%d%d$", "")
  no_ext = no_ext:gsub("_Take%d$", "")
  return no_ext
end

-- (Optional helper) determine leading digit width; not used in logic, but kept for completeness.
local function detect_digit_width(base)
  local digits = base:match("^%d+")
  return digits and #digits or 5
end

-- Map base -> row (speaker, dialogue, filename, track_override) 
local rows_by_base = {}

-- Build the human-readable item note:
--   "Speaker: Dialogue [clean_base]"
-- where clean_base has any "_TakeX" suffix removed for readability and matching. 
local function build_item_note_for_row(base, row)
  local speaker  = row and row.speaker  or ""
  local dialogue = row and row.dialogue or ""
  local note = ""

  -- Front part: "Speaker: Dialogue"
  if speaker ~= "" or dialogue ~= "" then
    note = speaker .. ": " .. dialogue
  end

  -- Clean the base just for display in the square brackets.
  -- So "00006_Narration_TakeX" becomes "00006_Narration".
  local display_base = base or ""
  if display_base ~= "" then
    display_base = display_base:gsub("_TakeX$", "")
  end

  if display_base ~= "" then
    if note ~= "" then
      note = note .. " [" .. display_base .. "]"
    else
      note = display_base
    end
  end

  return note
end

-- Extract the base from an item note.
-- Supports both:
--   "Speaker: Dialogue [00001_Narration]"
-- and the old style:
--   "00001_Narration"
local function extract_base_from_note(note)
  if not note or note == "" then return "" end

  -- New style: take text inside trailing [ ... ]
  local b = note:match("%[(.-)%]%s*$")
  if b and b ~= "" then return b end

  -- Old style: note itself looks like a base ("digits_...")
  if note:match("^%d+_") then
    return note
  end

  return ""
end

-- From a path or name like ".../00001_Narration_Take03.wav" or "00001_Narration_Take3":
--   -> "03" or "3"
local function extract_take_number_from_name(name)
  if not name or name == "" then return "?" end

  local stem = name

  -- Strip path
  stem = stem:gsub("^.+[\\/]", "")

  -- Strip extension
  stem = stem:gsub("%.[Ww][Aa][Vv]$", "")
  stem = stem:gsub("%.[Mm][Pp]3$", "")

  -- Last token after "_"
  local last = stem:match("([^_]+)$") or stem

  local num = last
  local m = last:match("^[Tt]ake(.*)")  -- e.g. "Take03" -> "03"
  if m and m ~= "" then
    num = m
  end

  num = num:gsub("^%s+", ""):gsub("%s+$", "")
  if num == "" then num = last end

  return num
end

-- Helper to add a take marker, but only if the API exists. 
local function add_take_marker_for_row(take, base, file_name_stem)
  if not reaper.SetTakeMarker then return end
  if not base or base == "" then return end

  local row = rows_by_base[base]
  if not row then return end

  local speaker  = row.speaker  or ""
  local dialogue = row.dialogue or ""
  local take_num = extract_take_number_from_name(file_name_stem)

  local text = speaker .. ": (Take " .. take_num .. ") " .. dialogue
  reaper.SetTakeMarker(take, -1, text, 0.0)  -- position 0 = start of take
end

-- Given a base (e.g. "00001_Narrator"), find all available take files in ./Sources.
-- For each take index t starting at 1, accept TakeN or TakeNN; prefer WAV > MP3.
local function collect_takes_for_base(base)
  local files = {}
  local t = 1
  while true do
    local tagA = base .. "_Take" .. tostring(t)
    local tagB = base .. "_Take" .. string.format("%02d", t)

    local cand = {
      join(sources_dir, tagA .. ".wav"),
      join(sources_dir, tagA .. ".mp3"),
      join(sources_dir, tagB .. ".wav"),
      join(sources_dir, tagB .. ".mp3"),
    }

    local chosen = nil
    local wav_first, mp3_first = nil, nil

    for _, p in ipairs(cand) do
      if file_exists(p) then
        if p:lower():sub(-4) == ".wav" then
          wav_first = wav_first or p
        end
        if p:lower():sub(-4) == ".mp3" then
          mp3_first = mp3_first or p
        end
      end
    end

    if     wav_first then chosen = wav_first
    elseif mp3_first then chosen = mp3_first
    end

    if not chosen then
      break
    end

    table.insert(files, chosen)
    t = t + 1
  end

  return files
end


------------------------------------------------------
-- SECTION 3b: SWS item-note shims (for robustness) --
------------------------------------------------------

-- We wrap SWS functions so the script doesn't hard-crash if SWS is missing.
local function set_item_note(item, text)
  if reaper.ULT_SetMediaItemNote then
    reaper.ULT_SetMediaItemNote(item, text or "")
  end
end

local function get_item_note(item)
  if reaper.ULT_GetMediaItemNote then
    return reaper.ULT_GetMediaItemNote(item) or ""
  end
  return ""
end


-------------------------------------------------------------------
-- SECTION 4: Track creation/selection and item/take manipulation --
-------------------------------------------------------------------

-- Ensure 'Ripple Editing' is set to 'All Tracks'.
local function ensure_ripple_all_on()
  local RIPPLE_PER_TRACK = 40310
  local RIPPLE_ALL       = 40311

  if reaper.GetToggleCommandStateEx(0, RIPPLE_PER_TRACK) == 1 then
    reaper.Main_OnCommand(RIPPLE_PER_TRACK, 0)
  end

  if reaper.GetToggleCommandStateEx(0, RIPPLE_ALL) ~= 1 then
    reaper.Main_OnCommand(RIPPLE_ALL, 0)
  end
end

-- Get or create a track by name; select only that track.
local function get_or_create_track(track_name)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, tn = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if tn == track_name then
      reaper.SetOnlyTrackSelected(tr)
      return tr
    end
  end

  reaper.InsertTrackAtIndex(n, true)
  local tr = reaper.GetTrack(0, n)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", track_name, true)
  reaper.SetOnlyTrackSelected(tr)
  return tr
end

-- Create an empty placeholder item at pos with given length; 'note_text' is the full item note.
local function create_placeholder_item(track, pos, length, note_text)
  local item = reaper.AddMediaItemToTrack(track)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH",   length)
  reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN",  0)
  reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", 0)
  set_item_note(item, note_text or "")
  return item
end

-- Insert multiple files as takes on a single item at 'pos' on 'track'.
-- Item length becomes the longest take; item note stores 'base'.
-- IMPORTANT: this now ensures media is copied into the project media folder.
local function insert_takes_for_files(track, pos, files, base)
  local item = nil
  local longest = 0.0

  for _, path in ipairs(files) do
    -- Ensure the file is present in the project media folder
    local media_path = ensure_media_in_project_folder(path)

    local src = reaper.PCM_Source_CreateFromFile(media_path)
    if src then
      local s_len = reaper.GetMediaSourceLength(src)
      if s_len > longest then
        longest = s_len
      end

      if not item then
        item = reaper.AddMediaItemToTrack(track)
        reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH",   s_len)
      else
        local cur_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        if s_len > cur_len then
          reaper.SetMediaItemInfo_Value(item, "D_LENGTH", s_len)
        end
      end

      local take = reaper.AddTakeToMediaItem(item)
      reaper.SetMediaItemTake_Source(take, src)

      -- Do NOT loop the source; if the take is shorter than the item,
      -- we want silence after it, not a repeat. 
      reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)

      local fn = media_path:match("([^"..SEP.."]+)$") or media_path
      fn = fn:gsub("%.(wav|mp3)$", "")
      reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", fn, true)
      
      -- Add a take marker with "Speaker: (Take N) Dialogue", if we have a matching CSV row. 
      add_take_marker_for_row(take, base, fn)

      if item then
        local row = rows_by_base and rows_by_base[base] or nil
        local note_text = build_item_note_for_row(base, row)
        set_item_note(item, note_text)
      end
    end
  end

  if item then
    local row = rows_by_base and rows_by_base[base] or nil
    local note_text = build_item_note_for_row(base, row)
    set_item_note(item, note_text)

    -- Rebuild peaks for this item (all its takes) so waveforms appear immediately. 
    reaper.SetMediaItemSelected(item, true)
    reaper.Main_OnCommand(40441, 0)  -- Peaks: Rebuild peaks for selected items
    reaper.SetMediaItemSelected(item, false)
  end

  return item, longest
end


---------------------------------------------------------
-- SECTION 5: Route A (no tracks) — Build from scratch --
---------------------------------------------------------

local WPM = 167.0  -- 10000/60 

local function route_A(rows)
  ensure_ripple_all_on()

  reaper.SetEditCurPos(0, true, false)
  reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)

  local cursor = 0.0

  for _, row in ipairs(rows) do
    local track_name = row.track_override or row.speaker
    local base = base_from_filename(row.filename)
    local files = collect_takes_for_base(base)
    local track = get_or_create_track(track_name)

    reaper.SetEditCurPos(cursor, true, false)

    if #files > 0 then
      local _, longest = insert_takes_for_files(track, cursor, files, base)
      cursor = cursor + (longest or 0.0)
    else
      local wc = word_count(row.dialogue)

      -- Fractional seconds; avoid per-row rounding overhead.
      local seconds = (wc * 60.0) / WPM
      if seconds < 0.25 then seconds = 0.25 end

      local note_text = build_item_note_for_row(base, row)
      create_placeholder_item(track, cursor, seconds, note_text)
      cursor = cursor + seconds
    end
  end
end


---------------------------------------------------------
-- SECTION 6: Route B (tracks exist) — Update in place --
---------------------------------------------------------

local function debug_item_placeholder_state(item, base)
  local takes = reaper.CountTakes(item)
  log("DEBUG base=" .. tostring(base) .. " | takes=" .. tostring(takes))

  if takes > 0 then
    for ti = 0, takes - 1 do
      local take = reaper.GetMediaItemTake(item, ti)
      local src  = take and reaper.GetMediaItemTake_Source(take)
      local src_len  = src and reaper.GetMediaSourceLength(src) or -1
      local src_type = src and reaper.GetMediaSourceType(src, "") or "nil"
      log(string.format(
        "  take %d: src_type=%s src_len=%.6f",
        ti, tostring(src_type), src_len
      ))
    end
  end
end

local function route_B()
  ensure_ripple_all_on()

  local tr_cnt = reaper.CountTracks(0)

  for ti = 0, tr_cnt - 1 do
    local tr = reaper.GetTrack(0, ti)
    reaper.SetOnlyTrackSelected(tr)

    -- IMPORTANT: iterate items BACKWARDS so deletion doesn't mess up indices. 
    local it_cnt = reaper.CountTrackMediaItems(tr)
    for ii = it_cnt - 1, 0, -1 do
      local item = reaper.GetTrackMediaItem(tr, ii)
      local takes = reaper.CountTakes(item)
      
      -- First try to extract base from the note (new "Speaker: Dialogue [base]" or old "base"). 
      local note = get_item_note(item) or ""
      local base = extract_base_from_note(note)
      
      -- Fallback: if we still don't have a base but there is at least one take, derive from take 1's name.
      if base == "" and takes > 0 then
        local tk = reaper.GetMediaItemTake(item, 0)
        if tk then
          local _, tname = reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)
          if tname and tname ~= "" then
            base = base_from_filename(tname)
            -- Update the note to the full "Speaker: Dialogue [base]" form if we can. 
            local row = rows_by_base and rows_by_base[base] or nil
            local note_text = build_item_note_for_row(base, row)
            set_item_note(item, note_text)
          end
        end
      end

      if base == "" then
        goto continue_item
      end

      local is_placeholder = false
      
      if takes == 0 then
        -- No takes at all: definitely a placeholder
        is_placeholder = true
      elseif takes == 1 then
        -- One take: inspect its source to see if it's effectively empty
        local take = reaper.GetMediaItemTake(item, 0)
        if not take then
          is_placeholder = true
        else
          local src = reaper.GetMediaItemTake_Source(take)
          if not src then
            is_placeholder = true
          else
            local src_len  = reaper.GetMediaSourceLength(src)
            local src_type = reaper.GetMediaSourceType(src, "")
      
            -- Treat EMPTY or zero-length sources as placeholders
            if src_len <= 0.000001 or src_type == "EMPTY" then
              is_placeholder = true
            end
          end
        end
      end
      
      if is_placeholder then
        -- Placeholder: see if audio now exists
        local files = collect_takes_for_base(base)
        if #files > 0 then
          -- Start position of the placeholder (we'll reuse this). 
          local old_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")

          -- 1) Find length of the LONGEST take source we are about to insert. 
          local longest = get_longest_source_length(files)
          if longest <= 0 then
            goto continue_item
          end

          -- 2) Delete the placeholder using the standard remove command
          --    so that ripple editing actually applies. 
          reaper.SelectAllMediaItems(0, false)
          reaper.SetMediaItemSelected(item, true)
          reaper.Main_OnCommand(40006, 0)  -- Item: Remove items

          -- 3) With ripple still on, insert empty space equal to 'longest'
          --    at old_pos, moving later items. 
          local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)  -- save TS
          reaper.GetSet_LoopTimeRange(true, false, old_pos, old_pos + longest, false)
          reaper.Main_OnCommand(40200, 0)  -- Time selection: Insert empty space at time selection (moving later items)
          reaper.GetSet_LoopTimeRange(true, false, ts_start, ts_end, false)  -- restore TS

          -- 4) Now insert the real takes at old_pos using the existing helper. 
          reaper.SetOnlyTrackSelected(tr)
          insert_takes_for_files(tr, old_pos, files, base)
        end
      else
        -- Has takes: look for new higher-numbered takes and append them.
        -- We also extend spacing if any NEW take is longer than the current item. 

        -- Current item bounds (assumed == longest existing take). 
        local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local old_len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local old_end  = item_pos + old_len

        local next_t = takes + 1
        local max_new_len = 0.0
        local new_takes_added = 0

        while true do
          local tagA = base .. "_Take" .. tostring(next_t)
          local tagB = base .. "_Take" .. string.format("%02d", next_t)

          local wavA = join(sources_dir, tagA .. ".wav")
          local mp3A = join(sources_dir, tagA .. ".mp3")
          local wavB = join(sources_dir, tagB .. ".wav")
          local mp3B = join(sources_dir, tagB .. ".mp3")

          local chosen = nil
          if     file_exists(wavA) then chosen = wavA
          elseif file_exists(wavB) then chosen = wavB
          elseif file_exists(mp3A) then chosen = mp3A
          elseif file_exists(mp3B) then chosen = mp3B
          end

          if not chosen then
            break
          end

          -- Ensure we are using a file in the project media folder
          local media_path = ensure_media_in_project_folder(chosen)

          local src = reaper.PCM_Source_CreateFromFile(media_path)
          if not src then break end

          local s_len = reaper.GetMediaSourceLength(src)
          if s_len > max_new_len then
            max_new_len = s_len
          end

          local take = reaper.AddTakeToMediaItem(item)
          reaper.SetMediaItemTake_Source(take, src)

          -- Ensure the item is not looping; shorter takes should not repeat.
          reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)

          local fn = media_path:match("([^"..SEP.."]+)$") or media_path
          fn = fn:gsub("%.(wav|mp3)$", "")
          reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", fn, true)
          
          -- Track this as a newly-added file for Route B summary (unique by name).
          if not routeB_new_files_set[fn] then
            routeB_new_files_set[fn] = true
            routeB_new_files[#routeB_new_files + 1] = fn
          end

          -- Add take marker for this newly-added take (Route B case). 
          add_take_marker_for_row(take, base, fn)

          new_takes_added = new_takes_added + 1
          next_t = next_t + 1
        end

        if new_takes_added > 0 then
          -- If any NEW take is longer than the current item, extend spacing accordingly. 
          local cur_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
          local target_len = cur_len

          if max_new_len > cur_len then
            target_len = max_new_len
            local delta = target_len - cur_len

            -- Insert extra empty space after the OLD item end, moving later items. 
            local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
            reaper.GetSet_LoopTimeRange(true, false, old_end, old_end + delta, false)
            reaper.Main_OnCommand(40200, 0)
            reaper.GetSet_LoopTimeRange(true, false, ts_start, ts_end, false)

            -- Now extend the item so its end meets the new end-of-gap. 
            reaper.SetMediaItemInfo_Value(item, "D_LENGTH", target_len)
          end

          -- Safety: ensure item looping is off. 
          reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
          
          -- Mark this item as having new takes (green).
          local green = reaper.ColorToNative(0, 255, 0) | 0x1000000
          reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", green)

          -- Rebuild peaks for this item (all takes). 
          reaper.SetMediaItemSelected(item, true)
          reaper.Main_OnCommand(40441, 0)
          reaper.SetMediaItemSelected(item, false)
        end
      end

      ::continue_item::
    end
  end
end

-- Count total media items across all tracks in the current project. 
local function count_all_items()
  local total = 0
  local tr_cnt = reaper.CountTracks(0)
  for ti = 0, tr_cnt - 1 do
    local tr = reaper.GetTrack(0, ti)
    total = total + reaper.CountTrackMediaItems(tr)
  end
  return total
end

---------------------------------------------
-- SECTION 7: MAIN — decide Route A or B   --
---------------------------------------------

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local csvs = list_csvs(sources_dir)
if #csvs == 0 then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("ERROR: No CSV found in ./Sources", -1)
  reaper.MB("No CSV found in ./Sources.", "CSV missing", 0)
  return
elseif #csvs > 1 then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("ERROR: Multiple CSV files in ./Sources", -1)
  reaper.MB("Multiple CSV files found in ./Sources. Keep exactly one.", "CSV conflict", 0)
  return
end

local csv_path = join(sources_dir, csvs[1])
local rows, err = parse_csv_rows(csv_path)

if err then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("ERROR: CSV read failed", -1)
  reaper.MB(err, "CSV error", 0)
  return
end

if #rows == 0 then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("No rows to process", -1)
  reaper.MB("CSV contains no usable rows (after header).", "Empty CSV", 0)
  return
end

-- Count items across all tracks at script start
local track_count = reaper.CountTracks(0)
local item_count  = 0
for ti = 0, track_count - 1 do
  local tr = reaper.GetTrack(0, ti)
  item_count = item_count + reaper.CountTrackMediaItems(tr)
end

-- DEBUG: which route are we taking, and how many rows/items?
reaper.MB(
  "Track count at start: " .. tostring(track_count) ..
  "\nTotal items at start: " .. tostring(item_count) ..
  "\nRows parsed: " .. tostring(#rows) ..
  "\n\n(Running Route A if items ≤ 1)",
  "DEBUG: Route decision",
  0
)

-- Build base -> row map for later lookups (notes & take markers). 
rows_by_base = {}
for _, row in ipairs(rows) do
  local b = base_from_filename(row.filename)
  if b and b ~= "" then
    rows_by_base[b] = row
  end
end

-- Decide A vs B
if item_count <= 1 then
  reaper.MB("Running ROUTE A (no real items yet — template item ignored).", "DEBUG: Route A", 0)
  route_A(rows)
else
  reaper.MB("Running ROUTE B (items already exist).", "DEBUG: Route B", 0)
  route_B()

  -- Route B summary of newly-added files (console).
  if #routeB_new_files > 0 then
    log("New files added: " .. tostring(#routeB_new_files))
    if #routeB_new_files <= 50 then
      for i, name in ipairs(routeB_new_files) do
        log("  " .. tostring(name))
      end
    end
  else
    log("New files added: 0")
  end
end

-- DEBUG: what does the project look like afterwards?
local final_tracks = reaper.CountTracks(0)
local final_items  = 0
local msg = "Track count AFTER script: " .. tostring(final_tracks) .. "\n"

if final_tracks > 0 then
  for ti = 0, final_tracks - 1 do
    local tr = reaper.GetTrack(0, ti)
    local _, tn = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    local it_cnt = reaper.CountTrackMediaItems(tr)
    final_items = final_items + it_cnt

    -- Show only first 3 tracks to keep debug short
    if ti <= 2 then
      msg = msg ..
        "\nTrack " .. (ti+1) .. " name: " .. (tn or "") ..
        "\nItems on this track: " .. tostring(it_cnt) .. "\n"
    end
  end
end

msg = msg .. "\nTotal items AFTER script: " .. tostring(final_items)

reaper.MB(msg, "DEBUG: Post-state", 0)

local cmd_id = reaper.NamedCommandLookup("_RS28f8949146665d34f1478d8e6e233cb2d2e64719")  -- replace with your script’s command ID
if cmd_id ~= 0 then
  reaper.Main_OnCommand(cmd_id, 0)
end

-- Sanity check: make sure all relevant audio files in ./Sources
-- are present in the project media folder (proj_dir).
check_sources_vs_media_folder()

reaper.UpdateArrange()
reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Build & Update from ./Sources CSV (A/B)", -1)
