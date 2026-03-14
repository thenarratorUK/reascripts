-- @description Build Duo Pairing Blocks From ../Sources (multi-narrator, auto-skip completed pairings)
-- @version 2.0
-- @author David Winter (The Narrator)
-- @about
--   Scans ../Sources/ (relative to current project folder) to discover narrators:
--     - Female narrators: have [Name]_Jane_1.wav
--     - Male narrators:   have [Name]_John_1.wav
--   Errors if any narrator has BOTH markers.
--
--   For every valid (Female, Male) pairing not already completed (region "Female and Male" exists),
--   appends a new timed block 30s after the last region end, inserts the required items onto the
--   corresponding narrator tracks (creating tracks if needed), and creates 3 regions:
--     1) "Female with Male" : block start (Pause_Pre before first item) -> start of John_1
--     2) "Male with Female" : end of Jane_8 (start of Pause_Scene)      -> end of John_9 + Pause_Post
--     3) "Female and Male"  : block start                               -> end of John_9 + Pause_Post
--
--   Room Tone track must exist exactly once and is never modified.

-----------------------------------------
-- CONFIG
-----------------------------------------
local Pause_Pre   = 0.60   -- seconds before the first item in each pairing block
local Pause_Mid   = 0.30   -- seconds between consecutive items (except between Jane_8 and John_1)
local Pause_Scene = 2.25   -- seconds between Jane_8 and John_1 (no extra Pause_Mid added there)
local Pause_Post  = 3.00   -- seconds after John_9 to end regions 2 & 3
local PairingGap  = 30.0   -- seconds to the right of the last region end before starting the next pairing block

local ROOM_TONE_TRACK_NAME = "Room Tone"

local find_track_exact

-- ------------------------------
-- NAME DISPLAY RULES
-- ------------------------------

local function starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

-- Insert spaces before capitals in CamelCase-ish strings:
-- "JohnDoe" -> "John Doe", "GenAm" -> "Gen Am", "TraditionalRP" -> "Traditional RP"
local function split_camel(s)
  -- space before an uppercase letter that follows a lowercase letter or digit
  s = s:gsub("(%l)(%u)", "%1 %2")
  s = s:gsub("(%d)(%u)", "%1 %2")
  return s
end

-- Special: DavidWinter[Accent] (no underscore inside accent part)
local function derive_display_from_raw(raw)
  -- DavidWinterGenAm -> David Winter (Gen Am)
  local accent = raw:match("^DavidWinter([A-Za-z0-9]+)$")
  if accent and accent ~= "" then
    return "David Winter (" .. split_camel(accent) .. ")"
  end

  -- Three leading capitals => first two are initials: DJWinter -> DJ Winter
  if raw:match("^[A-Z][A-Z][A-Z]") then
    local initials = raw:sub(1,2)
    local rest = raw:sub(3)
    return initials .. " " .. split_camel(rest)
  end

  -- Two leading capitals => first is initial: DWinter -> D Winter
  if raw:match("^[A-Z][A-Z]") then
    local initial = raw:sub(1,1)
    local rest = raw:sub(2)
    return initial .. " " .. split_camel(rest)
  end

  -- "JohnDoe" -> "John Doe" (two words, no space, each starts with a capital)
  if raw:match("^[A-Z][a-z]+[A-Z]") then
    return split_camel(raw)
  end

  -- single word (Mina) stays Mina
  return raw
end

-- Find a track whose name starts with the raw name (e.g. "Mina Fairlow" starts with "Mina")
local function find_track_starting_with(prefix)
  local n = reaper.CountTracks(0)
  for i = 0, n-1 do
    local tr = reaper.GetTrack(0, i)
    local _, tr_name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if starts_with(tr_name, prefix) then
      return tr, i, tr_name
    end
  end
  return nil, -1, nil
end

-- Decide what the display name should be for this narrator raw name:
-- If there's already a track starting with raw (e.g. "Mina Fairlow"), use that exact track name.
-- Otherwise derive from raw using the rules above.
local function resolve_display_name_from_tracks_or_rules(raw)
  -- Only apply the "track starting with raw" override for single-word raw names (as requested)
  if not raw:find("%s") and not raw:find("[^%w]") then
    local tr, _, tr_name = find_track_starting_with(raw)
    if tr and tr_name and tr_name ~= "" then
      return tr_name
    end
  end
  return derive_display_from_raw(raw)
end

-- Upgrade existing region names: replace raw with display if raw appears as a whole word
-- and the region name doesn't already contain the full display.
local function upgrade_region_names_for_narrator(raw, display)
  if raw == display then return end

  -- Only do the "Mina" -> "Mina Fairlow" upgrade when display starts with raw (your spec)
  if not starts_with(display, raw) then return end

  local idx = 0
  while true do
    local rv, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers(idx)
    if rv == 0 then break end

    if isrgn and name and name ~= "" then
      if not name:find(display, 1, true) then
        -- Replace raw only when it's a separate word (frontier patterns)
        -- This avoids replacing "Mina" inside "MinaFairlow" etc.
        local new_name = name:gsub("(%f[%w])" .. raw .. "(%f[%W])", "%1" .. display .. "%2")
        if new_name ~= name then
          reaper.SetProjectMarker2(0, markrgnindexnumber, true, pos, rgnend, new_name)
        end
      end
    end

    idx = idx + 1
  end
end

-- Find an existing narrator track for a given raw/display:
-- Prefer exact display name, else exact raw, else (for single-word raw) "starts with raw".
local function find_narrator_track(raw, display)
  local tr = select(1, find_track_exact(display))
  if tr then return tr end
  tr = select(1, find_track_exact(raw))
  if tr then return tr end
  if not raw:find("%s") then
    local tr2 = select(1, find_track_starting_with(raw))
    if tr2 then return tr2 end
  end
  return nil
end

-----------------------------------------
-- UTIL
-----------------------------------------
local function join_path(a, b)
  if not a or a == "" then return b end
  local sep = package.config:sub(1,1)
  if a:sub(-1) == "/" or a:sub(-1) == "\\" then return a .. b end
  return a .. sep .. b
end

local function norm_slashes(p)
  local sep = package.config:sub(1,1)
  if sep == "\\" then return (p:gsub("/", "\\")) end
  return (p:gsub("\\", "/"))
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function enum_files(dir)
  local files = {}
  local i = 0
  while true do
    local fn = reaper.EnumerateFiles(dir, i)
    if not fn then break end
    files[#files+1] = fn
    i = i + 1
  end
  return files
end

find_track_exact = function(name)
  local n = reaper.CountTracks(0)
  for i = 0, n-1 do
    local tr = reaper.GetTrack(0, i)
    local _, tr_name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if tr_name == name then return tr, i end
  end
  return nil, -1
end

local function count_tracks_named_exact(name)
  local count = 0
  local n = reaper.CountTracks(0)
  for i = 0, n-1 do
    local tr = reaper.GetTrack(0, i)
    local _, tr_name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if tr_name == name then count = count + 1 end
  end
  return count
end

local function insert_track_at(index0)
  reaper.InsertTrackAtIndex(index0, true)
  return reaper.GetTrack(0, index0)
end

local function set_only_track_selected(track)
  reaper.SetOnlyTrackSelected(track) -- guarantees exactly one selected track
end

local function set_edit_cursor(time)
  reaper.SetEditCurPos(time, false, false)
end

local function get_first_item_source_dir(track)
  local item_count = reaper.CountTrackMediaItems(track)
  for i = 0, item_count-1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local take = reaper.GetActiveTake(it)
    if take then
      local src = reaper.GetMediaItemTake_Source(take)
      if src then
        local buf = ""
        local ok, path = reaper.GetMediaSourceFileName(src, buf)
        if ok and path and path ~= "" then
          path = norm_slashes(path)
          local dir = path:match("^(.*)[/\\][^/\\]+$") or ""
          if dir ~= "" then return dir end
        end
      end
    end
  end
  return nil
end

local function insert_media_on_track(track, filepath, timepos)
  -- Create a new item and take explicitly (avoids InsertMedia prefs, add-takes, selection issues)
  local src = reaper.PCM_Source_CreateFromFile(filepath)
  if not src then
    return nil, "PCM_Source_CreateFromFile failed for: " .. filepath
  end

  local item = reaper.AddMediaItemToTrack(track)
  if not item then
    return nil, "AddMediaItemToTrack failed for: " .. filepath
  end

  reaper.SetMediaItemInfo_Value(item, "D_POSITION", timepos)

  local take = reaper.AddTakeToMediaItem(item)
  if not take then
    reaper.DeleteTrackMediaItem(track, item)
    return nil, "AddTakeToMediaItem failed for: " .. filepath
  end

  reaper.SetMediaItemTake_Source(take, src)

  local src_len, is_qn = reaper.GetMediaSourceLength(src)
  if not src_len or src_len <= 0 then
    -- Fallback: keep item, but you won't get correct spacing; better to error.
    reaper.DeleteTrackMediaItem(track, item)
    return nil, "Could not determine source length for: " .. filepath
  end

  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", src_len)

  return item, nil, timepos, src_len
end

local function add_region(start_time, end_time, name)
  reaper.AddProjectMarker2(0, true, start_time, end_time, name or "", -1, 0)
end

local function region_exists_by_name(name)
  local i = 0
  while true do
    local rv, isrgn, pos, rgnend, rgnname, markrgnindexnumber = reaper.EnumProjectMarkers(i)
    if rv == 0 then break end
    if isrgn and rgnname == name then return true end
    i = i + 1
  end
  return false
end

local function get_last_region_end()
  local last_end = 0.0
  local i = 0
  while true do
    local rv, isrgn, pos, rgnend, rgnname = reaper.EnumProjectMarkers(i)
    if rv == 0 then break end
    if isrgn and rgnend and rgnend > last_end then last_end = rgnend end
    i = i + 1
  end
  return last_end
end

local function ensure_narrator_track(raw_name, display_name, room_tone_track, room_tone_idx)
  -- Try to find an existing track by display/raw/startswith(raw)
  local tr = find_narrator_track(raw_name, display_name)
  if tr then
    local items = reaper.CountTrackMediaItems(tr)
    if items == 0 then
      return nil, "Track '" .. (display_name or raw_name) .. "' exists but has no items. This likely indicates a broken/partial setup."
    end
    return tr, nil
  end

  -- Create new narrator track immediately above Room Tone
  local insert_idx = room_tone_idx
  local new_tr = insert_track_at(insert_idx)
  reaper.GetSetMediaTrackInfo_String(new_tr, "P_NAME", display_name, true)
  return new_tr, nil
end

local function ensure_track_channels_at_least(track, min_ch)
  local cur = reaper.GetMediaTrackInfo_Value(track, "I_NCHAN")
  if cur < min_ch then
    reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", min_ch)
  end
end

local function track_has_roomtone_send_src12_to_dst34(src_tr, room_tone_tr)
  local send_count = reaper.GetTrackNumSends(src_tr, 0) -- 0 = sends
  for s = 0, send_count-1 do
    local dest = reaper.GetTrackSendInfo_Value(src_tr, 0, s, "P_DESTTRACK")
    if dest == room_tone_tr then
      local srcchan = reaper.GetTrackSendInfo_Value(src_tr, 0, s, "I_SRCCHAN")
      local dstchan = reaper.GetTrackSendInfo_Value(src_tr, 0, s, "I_DSTCHAN")
      if srcchan == 0 and dstchan == 2 then
        return true
      end
    end
  end
  return false
end

local function ensure_roomtone_send_src12_to_dst34(src_tr, room_tone_tr)
  if track_has_roomtone_send_src12_to_dst34(src_tr, room_tone_tr) then return end

  local send_idx = reaper.CreateTrackSend(src_tr, room_tone_tr)
  if send_idx >= 0 then
    reaper.SetTrackSendInfo_Value(src_tr, 0, send_idx, "I_SRCCHAN", 0) -- 1/2
    reaper.SetTrackSendInfo_Value(src_tr, 0, send_idx, "I_DSTCHAN", 2) -- 3/4
  end
end

-----------------------------------------
-- DISCOVERY / VALIDATION
-----------------------------------------
local function error_box(title, body)
  reaper.ShowMessageBox(body, title, 0)
end

local function get_project_dir_or_error()
  local _, proj_path = reaper.EnumProjects(-1, "")
  proj_path = norm_slashes(proj_path or "")
  local proj_dir = proj_path:match("^(.*)[/\\][^/\\]+$") or ""
  if proj_dir == "" then
    return nil, "Could not determine project folder (project may not be saved). Please save the project and try again."
  end
  return proj_dir, nil
end

local function discover_narrators(sources_dir)
  local files = enum_files(sources_dir)
  if #files == 0 then return nil, nil, "No files found in:\n" .. sources_dir end

  local female = {}  -- set: name -> true
  local male   = {}  -- set: name -> true

  for _, fn in ipairs(files) do
    local f = fn:match("^(.*)_Jane_1%.wav$")
    if f and f ~= "" then female[f] = true end

    local m = fn:match("^(.*)_John_1%.wav$")
    if m and m ~= "" then male[m] = true end
  end

  -- Error if any name appears in both
  local both = {}
  for name, _ in pairs(female) do
    if male[name] then both[#both+1] = name end
  end
  if #both > 0 then
    table.sort(both)
    return nil, nil, "Error: narrator(s) have BOTH _Jane_1 and _John_1 marker files:\n  " .. table.concat(both, "\n  ")
  end

  -- Convert sets to sorted arrays
  local female_list, male_list = {}, {}
  for name, _ in pairs(female) do female_list[#female_list+1] = name end
  for name, _ in pairs(male) do male_list[#male_list+1] = name end
  table.sort(female_list)
  table.sort(male_list)

  if #female_list == 0 then return nil, nil, "No female narrators discovered (no *_Jane_1.wav files found) in:\n" .. sources_dir end
  if #male_list == 0 then return nil, nil, "No male narrators discovered (no *_John_1.wav files found) in:\n" .. sources_dir end

  return female_list, male_list, nil
end

local REQUIRED_ORDER = {
  -- Jane block
  {suffix="Jane_1", who="F"},
  {suffix="Jane_2", who="F"},
  {suffix="Jane_3", who="F"},
  {suffix="Jane_4", who="M"},
  {suffix="Jane_5", who="F"},
  {suffix="Jane_6", who="F"},
  {suffix="Jane_7", who="F"},
  {suffix="Jane_8", who="M"},
  -- John block
  {suffix="John_1", who="M"},
  {suffix="John_2", who="F"},
  {suffix="John_3", who="M"},
  {suffix="John_4", who="F"},
  {suffix="John_5", who="M"},
  {suffix="John_6", who="M"},
  {suffix="John_7", who="F"},
  {suffix="John_8", who="M"},
  {suffix="John_9", who="M"},
  {suffix="John_10", who="M"},
  {suffix="John_11", who="M"},
}

local function validate_pairing_files_or_error(sources_dir, female_name, male_name)
  local missing = {}
  for _, entry in ipairs(REQUIRED_ORDER) do
    local prefix = (entry.who == "F") and female_name or male_name
    local fn = prefix .. "_" .. entry.suffix .. ".wav"
    local full = norm_slashes(join_path(sources_dir, fn))
    if not file_exists(full) then missing[#missing+1] = fn end
  end

  if #missing > 0 then
    table.sort(missing)
    return false, "Missing required file(s) for pairing:\n  " .. female_name .. " + " .. male_name ..
                 "\n\nIn folder:\n  " .. sources_dir .. "\n\nMissing:\n  " .. table.concat(missing, "\n  ")
  end

  return true, nil
end

local function resolve_source_path_for_narrator_file(sources_dir, narrator_name, narrator_track, filename)
  -- If narrator track already has items, prefer the directory where their existing sources live (avoids re-copy).
  local existing_dir = get_first_item_source_dir(narrator_track)
  if existing_dir then
    local candidate = norm_slashes(join_path(existing_dir, filename))
    if file_exists(candidate) then return candidate, nil end
    -- If this fails, fall back to Sources (still correct, but may create extra copies depending on settings).
  end

  local from_sources = norm_slashes(join_path(sources_dir, filename))
  if file_exists(from_sources) then return from_sources, nil end

  return nil, "Could not resolve a usable path for:\n  " .. filename ..
              "\nTried:\n  " .. (existing_dir and norm_slashes(join_path(existing_dir, filename)) or "(no existing media dir)") ..
              "\n  " .. from_sources
end

-----------------------------------------
-- MAIN
-----------------------------------------
reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- Room Tone must exist exactly once
local rt_count = count_tracks_named_exact(ROOM_TONE_TRACK_NAME)
if rt_count == 0 then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Build Duo Pairing Blocks From ../Sources", -1)
  error_box("Build Duo Pairings", "Error: No track named exactly '" .. ROOM_TONE_TRACK_NAME .. "' exists.\n\nStopping.")
  return
elseif rt_count > 1 then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Build Duo Pairing Blocks From ../Sources", -1)
  error_box("Build Duo Pairings", "Error: More than one track named exactly '" .. ROOM_TONE_TRACK_NAME .. "' exists.\n\nPlease keep exactly one and try again.")
  return
end

local room_tone_track, room_tone_idx = find_track_exact(ROOM_TONE_TRACK_NAME)
if not room_tone_track then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Build Duo Pairing Blocks From ../Sources", -1)
  error_box("Build Duo Pairings", "Error: Room Tone track not found unexpectedly.\n\nStopping.")
  return
end

-- Project directory and Sources folder
local proj_dir, perr = get_project_dir_or_error()
if not proj_dir then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Build Duo Pairing Blocks From ../Sources", -1)
  error_box("Build Duo Pairings", "Error: " .. perr)
  return
end

local sources_dir = norm_slashes(join_path(proj_dir, "Sources"))

-- Discover narrators
local females, males, derr = discover_narrators(sources_dir)
if not females then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Build Duo Pairing Blocks From ../Sources", -1)
  error_box("Build Duo Pairings", derr or "Error: narrator discovery failed.")
  return
end

-- Build display name mapping for discovered narrators
local female_display = {}
local male_display = {}

for _, raw in ipairs(females) do
  female_display[raw] = resolve_display_name_from_tracks_or_rules(raw)
end
for _, raw in ipairs(males) do
  male_display[raw] = resolve_display_name_from_tracks_or_rules(raw)
end

-- Upgrade existing region names (e.g. Mina -> Mina Fairlow) before we check "already done"
for raw, disp in pairs(female_display) do
  upgrade_region_names_for_narrator(raw, disp)
end
for raw, disp in pairs(male_display) do
  upgrade_region_names_for_narrator(raw, disp)
end

-- Process all pairings, skipping ones already done.
local created_blocks = 0

for _, fname in ipairs(females) do
  for _, mname in ipairs(males) do
    local fdisp = female_display[fname] or fname
    local mdisp = male_display[mname] or mname

    local pairing_region_name = fdisp .. " and " .. mdisp
    if region_exists_by_name(pairing_region_name) then
      -- Pairing already completed; skip.
    else
      -- Validate file completeness for this pairing (terminate on any missing)
      local ok, verr = validate_pairing_files_or_error(sources_dir, fname, mname)
      if not ok then
        reaper.PreventUIRefresh(-1)
        reaper.Undo_EndBlock("Build Duo Pairing Blocks From ../Sources", -1)
        error_box("Build Duo Pairings", "Error: " .. verr)
        return
      end

      -- Re-fetch Room Tone track/index (track list may change as we create narrator tracks)
      room_tone_track, room_tone_idx = find_track_exact(ROOM_TONE_TRACK_NAME)
      if not room_tone_track then
        reaper.PreventUIRefresh(-1)
        reaper.Undo_EndBlock("Build Duo Pairing Blocks From ../Sources", -1)
        error_box("Build Duo Pairings", "Error: Room Tone track not found unexpectedly.\n\nStopping.")
        return
      end

      -- Ensure narrator tracks exist (never delete anything)
      local female_track, ferr = ensure_narrator_track(fname, fdisp, room_tone_track, room_tone_idx)
      if not female_track then
        reaper.PreventUIRefresh(-1)
        reaper.Undo_EndBlock("Build Duo Pairing Blocks From ../Sources", -1)
        error_box("Build Duo Pairings", "Error: " .. ferr)
        return
      end

      -- Room Tone index may have shifted after inserting female track
      room_tone_track, room_tone_idx = find_track_exact(ROOM_TONE_TRACK_NAME)
      local male_track, merr = ensure_narrator_track(mname, mdisp, room_tone_track, room_tone_idx)
      if not male_track then
        reaper.PreventUIRefresh(-1)
        reaper.Undo_EndBlock("Build Duo Pairing Blocks From ../Sources", -1)
        error_box("Build Duo Pairings", "Error: " .. merr)
        return
      end

      -- Determine block origin based on last region end
      local last_end = get_last_region_end()
      local block_origin = 0.0
      if last_end > 0.0 then block_origin = last_end + (PairingGap or 0.0) end

      -- Insert items
      local cursor = block_origin + (Pause_Pre or 0.0)

      local john1_start = nil
      local jane8_end   = nil
      local john_last_end = nil

      for _, entry in ipairs(REQUIRED_ORDER) do
        local narrator_name = (entry.who == "F") and fname or mname
        local narrator_track = (entry.who == "F") and female_track or male_track

        local filename = narrator_name .. "_" .. entry.suffix .. ".wav"

        local src_path, rerr = resolve_source_path_for_narrator_file(sources_dir, narrator_name, narrator_track, filename)
        if not src_path then
          reaper.PreventUIRefresh(-1)
          reaper.Undo_EndBlock("Build Duo Pairing Blocks From ../Sources", -1)
          error_box("Build Duo Pairings", "Error: " .. rerr)
          return
        end

        local item, ierr, pos, len = insert_media_on_track(narrator_track, src_path, cursor)
        if not item then
          reaper.PreventUIRefresh(-1)
          reaper.Undo_EndBlock("Build Duo Pairing Blocks From ../Sources", -1)
          error_box("Build Duo Pairings", "Error: " .. (ierr or ("Insert failed: " .. src_path)))
          return
        end

        local item_start = pos or cursor
        local item_end   = item_start + (len or 0.0)

        if entry.suffix == "John_1" then john1_start = item_start end
        if entry.suffix == "Jane_8" then jane8_end   = item_end   end
        if entry.suffix:match("^John_%d+$") 
          then john_last_end = item_end 
        end

        -- Cursor advance: after Jane_8 use Pause_Scene only; otherwise Pause_Mid
        if entry.suffix == "Jane_8" then
          cursor = item_end + (Pause_Scene or 0.0)
        else
          cursor = item_end + (Pause_Mid or 0.0)
        end
      end

      if not john1_start or not jane8_end or not john_last_end then
        reaper.PreventUIRefresh(-1)
        reaper.Undo_EndBlock("Build Duo Pairing Blocks From ../Sources", -1)
        error_box("Build Duo Pairings", "Error: Could not determine John_1 start / Jane_8 end / John_9 end.\n\nStopping.")
        return
      end

      local region_end_full = john_last_end + (Pause_Post or 0.0)

      -- Regions:
      -- 1) Female with Male: block origin -> start of John_1 (includes Pause_Scene gap)
      add_region(block_origin, john1_start, fdisp .. " with " .. mdisp)

      -- 2) Male with Female: end of Jane_8 -> end of John_9 + Pause_Post
      add_region(jane8_end, region_end_full, mdisp .. " with " .. fdisp)

      -- 3) Female and Male: block origin -> end of John_9 + Pause_Post
      add_region(block_origin, region_end_full, fdisp .. " and " .. mdisp)

      created_blocks = created_blocks + 1
    end
  end
end

-- Ensure Room Tone has at least 4 channels (needed for destination 3/4)
ensure_track_channels_at_least(room_tone_track, 4)

-- Ensure every non-Room Tone track sends 1/2 -> Room Tone 3/4
do
  local n = reaper.CountTracks(0)
  for i = 0, n-1 do
    local tr = reaper.GetTrack(0, i)
    local _, tr_name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if tr ~= room_tone_track and tr_name ~= ROOM_TONE_TRACK_NAME then
      ensure_roomtone_send_src12_to_dst34(tr, room_tone_track)
    end
  end
end

reaper.UpdateArrange()
reaper.Main_OnCommand(40048, 0) -- Peaks: Rebuild all peaks
reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Build Duo Pairing Blocks From ../Sources", -1)

if created_blocks == 0 then
  reaper.ShowMessageBox("No new pairings were created.\n\nAll discovered female/male pairings already have a region named 'Female and Male'.", "Build Duo Pairings", 0)
end
