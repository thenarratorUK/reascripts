--[[
  DW_Index Track Roles (Project Startup)
  Purpose:
    Cache key track GUIDs (Narration, Dialogue 1, Dialogue 2) into the project file
    so the selector scripts can find them instantly, even after track reordering.

  Intended usage:
    Set this script as the SWS "Project startup action" for your template-based projects.
]]

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------

local VERBOSE = false  -- set true to print detailed indexing + cache verification to the console
local QUIET   = true   -- set false if you want missing-role popups (in addition to console output)

------------------------------------------------------------
-- INTERNALS
------------------------------------------------------------

local SECTION = "DW_TRACK_ROLE_CACHE_V1"

local function log(fmt, ...)
  if not VERBOSE then return end
  if reaper and reaper.ShowConsoleMsg then
    if fmt == nil then return end
    local msg = (select("#", ...) > 0) and string.format(tostring(fmt), ...) or tostring(fmt)
    reaper.ShowConsoleMsg(msg .. "\n")
  end
end

local function is_function(name)
  return type(reaper[name]) == "function"
end

local function get_track_name(tr)
  local ok, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  if ok then return name or "" end
  return ""
end

local function normalize(s)
  return (s or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
end

local function get_track_guid(tr)
  if is_function("GetTrackGUID") then
    return reaper.GetTrackGUID(tr)
  end
  -- Fallback: try REAPER string accessor
  if is_function("GetSetMediaTrackInfo_String") then
    local ok, guid = reaper.GetSetMediaTrackInfo_String(tr, "GUID", "", false)
    if ok and guid and guid ~= "" then return guid end
  end
  return nil
end

local function find_track_by_names(names)
  if not names or #names == 0 then return nil end
  local wanted = {}
  for _, n in ipairs(names) do
    wanted[normalize(n)] = true
  end
  local tr_count = reaper.CountTracks(0)
  for i = 0, tr_count - 1 do
    local tr = reaper.GetTrack(0, i)
    local nm = normalize(get_track_name(tr))
    if wanted[nm] then
      return tr
    end
  end
  return nil
end

local function get_cached_guid(key)
  if not is_function("GetProjExtState") then return nil end
  local rv, val = reaper.GetProjExtState(0, SECTION, key)
  if rv == 1 and val and val ~= "" then return val end
  return nil
end

local function set_cached_guid(key, guid)
  if not is_function("SetProjExtState") then return false end
  local rv = reaper.SetProjExtState(0, SECTION, key, guid or "")
  -- SetProjExtState returns an integer result in REAPER, but we only need a truthy signal.
  return rv ~= nil
end

-- Configure the canonical track names / aliases in your template:
local ROLE_NAMES = {
  Narration = { "Narration" },
  Dialogue1 = { "Dialogue 1", "Dialogue1", "Dialogue" },
  Dialogue2 = { "Dialogue 2", "Dialogue2" },
}

-- Cache keys (in project extstate section)
local ROLE_KEYS = {
  Narration = "NarrationGUID",
  Dialogue1 = "Dialogue1GUID",
  Dialogue2 = "Dialogue2GUID",
}

local function index_one(role)
  local aliases = ROLE_NAMES[role] or {}
  log("Index role: %s | aliases: %s", role, table.concat(aliases, " | "))

  local tr = find_track_by_names(aliases)
  if not tr then
    log("  FAIL: track not found by name for role '%s'", role)
    return false, "Track not found by name: " .. role
  end

  local tname = get_track_name(tr)
  local guid = get_track_guid(tr)
  if not guid then
    log("  FAIL: could not read GUID for role '%s' (track '%s')", role, tname)
    return false, "Could not get GUID for: " .. role
  end

  local key = ROLE_KEYS[role]
  if not key then
    log("  FAIL: no cache key configured for role '%s'", role)
    return false, "No cache key configured for: " .. role
  end

  log("  Found track: '%s' | GUID: %s", tname, guid)

  local wrote = set_cached_guid(key, guid)
  log("  Write cache: section='%s' key='%s' -> %s", SECTION, key, wrote and "OK" or "FAILED")

  -- Verify by reading back immediately (only in verbose mode)
  if VERBOSE then
    local readback = get_cached_guid(key)
    if readback == guid then
      log("  Verify cache: OK (readback matches)")
    else
      log("  Verify cache: MISMATCH (readback=%s)", tostring(readback))
    end
  end

  return true, nil
end

------------------------------------------------------------
-- RUN
------------------------------------------------------------

if VERBOSE then
  reaper.ClearConsole()
  log("=== DW_Index Track Roles (Project Startup) ===")
  log("Section: %s", SECTION)
end

reaper.Undo_BeginBlock()

local missing = {}
for _, role in ipairs({ "Narration", "Dialogue1", "Dialogue2" }) do
  local ok, err = index_one(role)
  if not ok then
    table.insert(missing, err)
  end
end

reaper.Undo_EndBlock("DW: Index Track Roles (GUID cache)", 0)

if VERBOSE then
  if #missing == 0 then
    log("Result: OK (all roles cached)")
  else
    log("Result: WARN (%d role(s) not cached):", #missing)
    for i = 1, #missing do
      log("  - %s", missing[i])
    end
  end
  log("=== End ===")
end

if (not QUIET) and #missing > 0 then
  reaper.ShowMessageBox(table.concat(missing, "\n"), "DW Track Role Indexer", 0)
end
