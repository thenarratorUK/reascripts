-- Global Reset of Send Mute Envelopes for Character Routing
--
-- Behaviour:
--   - Auto-creates send-mute envelopes using SWS action
--       _BR_SHOW_SEND_ENV_MUTE_SEL_TRACK
--     on:
--       * All FX
--       * Each parent FX bus (e.g. System FX, Special 1 FX, Special 2 FX)
--   - Then rebuilds those envelopes based on item regions using
--     the 4-point pattern per merged segment:
--       before: muted
--       start : unmuted
--       end   : unmuted
--       after : muted
--
-- Assumes:
--   "All FX"       : common upstream FX bus
--   "Dialogue Bus" : dialogue master bus (not modified here)
--   "Reverb Bus"   : reverb bus (not modified here)
--   "Character FX" : parent for all "<Name> FX" tracks
--
-- Source character tracks:
--   - All tracks above "All FX"
--   - Whose names do NOT end with " FX"
--
-- FX tracks:
--   - "<Name> FX" for each source "<Name>"

------------------------------------
-- CONFIG
------------------------------------

local NAME_ALL_FX         = "All FX"
local NAME_DIALOGUE_BUS   = "Dialogue Bus"
local NAME_REVERB_BUS     = "Reverb Bus"
local NAME_CHAR_FX_PARENT = "Character FX"

-- EPS for comparing times (contiguity / overlap)
local EPS = 1e-9

-- Time-selection-only mode
--  - If TIME_SELECTION_ONLY is true, the script will operate ONLY inside the current time selection.
--  - You can also force this behaviour by setting ExtState DW_RESET_CHAR_FX_SENDS / TIME_SELECTION_ONLY to 1.
--    (Other scripts can set it, run this script, then clear it.)
local TIME_SELECTION_ONLY = false
local TS_EXTSTATE_SECTION = "DW_RESET_CHAR_FX_SENDS"
local TS_EXTSTATE_KEY     = "TIME_SELECTION_ONLY"

------------------------------------
-- HELPERS
------------------------------------

local function msg(s)
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
end

local function get_track_name(tr)
  if not tr then return nil end
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  return name
end

local function get_track_by_name(name)
  local proj = 0
  local track_count = reaper.CountTracks(proj)
  for i = 0, track_count - 1 do
    local tr = reaper.GetTrack(proj, i)
    local _, tr_name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if tr_name == name then
      return tr
    end
  end
  return nil
end

local function ends_with_fx(name)
  return name:sub(-3) == " FX"
end

local function get_track_index(tr)
  local num = reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")
  if not num or num <= 0 then return nil end
  return math.floor(num - 1 + 0.5)
end

-- Gather raw segments [start, end] from all items on a track
local function collect_segments_for_track(tr)
  local segments = {}
  local item_count = reaper.CountTrackMediaItems(tr)
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(tr, i)
    local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local s    = pos
    local e    = pos + len
    if e > s then
      table.insert(segments, {start = s, endt = e})
    end
  end
  return segments
end

-- Gather raw segments [start, end] from items fully within the time selection on a track
local function collect_segments_for_track_time_sel(tr, ts_start, ts_end)
  local segments = {}
  if not tr then return segments end
  if not ts_start or not ts_end or ts_end <= ts_start + EPS then return segments end

  local item_count = reaper.CountTrackMediaItems(tr)
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(tr, i)
    local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local s    = pos
    local e    = pos + len

    -- Fully within time selection (with tiny tolerance)
    if e > s and s >= (ts_start - EPS) and e <= (ts_end + EPS) then
      table.insert(segments, { start = s, endt = e })
    end
  end

  return segments
end

-- Merge overlapping and contiguous segments
local function merge_segments(segments)
  if #segments == 0 then return {} end

  table.sort(segments, function(a, b)
    if a.start == b.start then
      return a.endt < b.endt
    end
    return a.start < b.start
  end)

  local merged = {}
  local cur = {start = segments[1].start, endt = segments[1].endt}

  for i = 2, #segments do
    local s = segments[i]
    if math.abs(s.start - cur.endt) <= EPS or s.start <= cur.endt then
      -- contiguous or overlapping: extend
      if s.endt > cur.endt then
        cur.endt = s.endt
      end
    else
      table.insert(merged, cur)
      cur = {start = s.start, endt = s.endt}
    end
  end

  table.insert(merged, cur)
  return merged
end

-- Find track with exact name "<name> FX"
local function get_fx_track_for_name(name)
  local fx_name = name .. " FX"
  return get_track_by_name(fx_name)
end

-- Get send index for src -> dst, or -1 if not found
local function get_send_index(src_tr, dst_tr)
  local category = 0 -- sends
  local num_sends = reaper.GetTrackNumSends(src_tr, category)
  for i = 0, num_sends - 1 do
    local dest_ptr = reaper.GetTrackSendInfo_Value(src_tr, category, i, "P_DESTTRACK")
    if dest_ptr == dst_tr then
      return i
    end
  end
  return -1
end

-- After building routing: force all sends to READ and UNMUTE them once
local function prime_all_sends_projectwide()
  local proj = 0
  local track_count = reaper.CountTracks(proj)
  for ti = 0, track_count-1 do
    local tr = reaper.GetTrack(proj, ti)
    local num = reaper.GetTrackNumSends(tr, 0)
    for si = 0, num-1 do
      reaper.SetTrackSendInfo_Value(tr, 0, si, "I_AUTOMODE", 1) -- Read
      reaper.SetTrackSendInfo_Value(tr, 0, si, "B_MUTE", 0)     -- Unmute
    end
  end
end

-- Activate all send-mute envelopes on a track (no creation, just ACT=1)
local function activate_all_send_mute_envelopes(src_tr)
  if not src_tr then return end
  local env_count = reaper.CountTrackEnvelopes(src_tr)
  for i = 0, env_count - 1 do
    local env = reaper.GetTrackEnvelope(src_tr, i)
    local _, name = reaper.GetEnvelopeName(env, "")
    name = name or ""
    local lname = name:lower()
    if lname:find("send", 1, true)
       and lname:find("mute", 1, true)
       and not lname:find("hw", 1, true) then
      reaper.GetSetEnvelopeInfo_String(env, "ACT", "1", true)
    end
  end
end

-- Return the mute envelope for a given send on a track.
-- src_tr   : source track (e.g. All FX, Special 1 FX)
-- send_idx : 0-based send index (from GetTrackSendInfo_Value / GetTrackSendName)
-- dest_name: destination track name, e.g. "Demon FX"
local function get_send_mute_envelope(src_tr, send_idx, dest_name)
  if not src_tr or send_idx < 0 then return nil end

  -- 1) Try decorated name if present (e.g. "Send mute: Narration FX")
  local env_name1 = "Send mute: " .. dest_name
  local env = reaper.GetTrackEnvelopeByName(src_tr, env_name1)
  if env then
    return env
  end

  -- 2) Fallback: map send index -> Nth "Send Mute" envelope on this track.
  local env_count = reaper.CountTrackEnvelopes(src_tr)
  local send_mute_envs = {}

  for i = 0, env_count - 1 do
    local e = reaper.GetTrackEnvelope(src_tr, i)
    local _, name = reaper.GetEnvelopeName(e, "")
    name = name or ""
    local lname = name:lower()

    if lname:find("send", 1, true)
       and lname:find("mute", 1, true)
       and not lname:find("hw", 1, true) then
      table.insert(send_mute_envs, e)
    end
  end

  if #send_mute_envs > send_idx then
    return send_mute_envs[send_idx + 1]
  end

  -- Last-resort debug for truly missing envelopes
  local ok, send_label = reaper.GetTrackSendName(src_tr, send_idx, "")
  if not ok or send_label == "" then send_label = dest_name end
  local track_label = get_track_name(src_tr) or "(unnamed)"

  msg("WARNING: No send-mute envelope found for track '" .. track_label ..
      "', send index " .. tostring(send_idx) ..
      " -> '" .. tostring(send_label) .. "'.")

  return nil
end

-- Ensure the mute envelope for a given send exists AND is active.
local function ensure_send_mute_envelope(src_tr, send_idx, dest_name)
  -- Make all send-mute envelopes on this track active
  activate_all_send_mute_envelopes(src_tr)

  -- Then resolve the specific envelope for this send
  local env = get_send_mute_envelope(src_tr, send_idx, dest_name)
  if env then
    reaper.GetSetEnvelopeInfo_String(env, "ACT", "1", true)
  end
  return env
end

-- Rebuild a mute envelope from scratch:
--   segments: array of {start, endt} with no overlaps (already merged)
-- Values here are:
--   0.0 = muted, 1.0 = unmuted  (based on your observed behaviour)
local function rebuild_mute_envelope(env, segments)
  if not env then return end

  local proj_len = reaper.GetProjectLength(0)

  -- Clear all points in the main lane
  reaper.DeleteEnvelopePointRangeEx(env, -1, 0, proj_len + 1)

  -- No segments => write a tiny "fake item" at project start:
  -- mute, unmute, unmute, mute (using your send-mute envelope polarity: 0=mute, 1=unmute)
  if #segments == 0 then
    local EPS = 0.000001 -- 1 µs; can increase if REAPER collapses points at same time
    local t0 = 0.0
    local t1 = t0 + EPS
    local t2 = t0 + (2 * EPS)
    local t3 = t0 + (3 * EPS)
  
    reaper.InsertEnvelopePointEx(env, -1, t0, 0.0, 0, 0, false, true) -- mute
    reaper.InsertEnvelopePointEx(env, -1, t1, 1.0, 0, 0, false, true) -- unmute
    reaper.InsertEnvelopePointEx(env, -1, t2, 1.0, 0, 0, false, true) -- unmute
    reaper.InsertEnvelopePointEx(env, -1, t3, 0.0, 0, 0, false, true) -- mute
  
    reaper.Envelope_SortPoints(env)
    return
  end

  -- Ensure segments merged & sorted
  segments = merge_segments(segments)

  -- Small offset to create "just before/after" points
  local EPS_TIME = 0.000001

  -- Start fully muted from t=0
  reaper.InsertEnvelopePointEx(env, -1, 0.0, 0.0, 0, 0, false, true)

  for _, seg in ipairs(segments) do
    local s = seg.start
    local e = seg.endt

    -- Clamp to >= 0 just in case
    local before = math.max(0, s - EPS_TIME)
    local after  = e + EPS_TIME

    -- Just before start: muted (0.0)
    reaper.InsertEnvelopePointEx(env, -1, before, 0.0, 0, 0, false, true)
    -- At start: unmuted (1.0)
    reaper.InsertEnvelopePointEx(env, -1, s,      1.0, 0, 0, false, true)
    -- At end: still unmuted (1.0)
    reaper.InsertEnvelopePointEx(env, -1, e,      1.0, 0, 0, false, true)
    -- Just after end: muted again (0.0)
    reaper.InsertEnvelopePointEx(env, -1, after,  0.0, 0, 0, false, true)
  end

  reaper.Envelope_SortPoints(env)
end

-- Rebuild a mute envelope only within the time selection window:
--   - Deletes points only inside [ts_start, ts_end]
--   - Preserves continuity at window edges
--   - Within the window, baseline is muted (0.0) except for the provided segments (unmuted 1.0)
local function rebuild_mute_envelope_time_sel(env, segments, ts_start, ts_end)
  if not env then return end

  -- If no valid time selection, fall back to full rebuild
  if not ts_start or not ts_end or ts_end <= ts_start + EPS then
    rebuild_mute_envelope(env, segments)
    return
  end

  segments = merge_segments(segments or {})

  local EPS_TIME = 0.000001

  local win_start = ts_start
  local win_end   = ts_end

  local inner_start = win_start + EPS_TIME
  local inner_end   = win_end   - EPS_TIME
  if inner_end <= inner_start then
    -- Window too small to do anything safely
    return
  end

  local function env_eval(t)
    local ok, val = reaper.Envelope_Evaluate(env, t, 0, 0)
    if ok then return val end
    return 0.0
  end

  local left_t  = math.max(0, win_start - EPS_TIME)
  local right_t = win_end + EPS_TIME

  local left_val  = env_eval(left_t)
  local right_val = env_eval(right_t)

  -- Delete only inside the window (with padding)
  reaper.DeleteEnvelopePointRangeEx(env, -1, win_start - EPS_TIME, win_end + EPS_TIME)

  -- Anchor the boundary values so outside behaviour remains continuous
  reaper.InsertEnvelopePointEx(env, -1, win_start, left_val,  0, 0, false, true)
  reaper.InsertEnvelopePointEx(env, -1, win_end,   right_val, 0, 0, false, true)

  -- Baseline inside the window: muted
  reaper.InsertEnvelopePointEx(env, -1, inner_start, 0.0, 0, 0, false, true)
  reaper.InsertEnvelopePointEx(env, -1, inner_end,   0.0, 0, 0, false, true)

  -- Apply the 4-point pattern for segments fully inside the time selection
  for _, seg in ipairs(segments) do
    local s = seg.start
    local e = seg.endt

    if e > s and s >= (win_start - EPS) and e <= (win_end + EPS) then
      local before = s - EPS_TIME
      local after  = e + EPS_TIME

      -- Clamp all pattern points to the safe interior (avoid colliding with boundary anchors)
      local b = math.min(math.max(before, inner_start), inner_end)
      local ss = math.min(math.max(s,      inner_start), inner_end)
      local ee = math.min(math.max(e,      inner_start), inner_end)
      local a = math.min(math.max(after,  inner_start), inner_end)

      if ss <= ee then
        if b < ss then
          reaper.InsertEnvelopePointEx(env, -1, b,  0.0, 0, 0, false, true)
        end

        reaper.InsertEnvelopePointEx(env, -1, ss, 1.0, 0, 0, false, true)
        reaper.InsertEnvelopePointEx(env, -1, ee, 1.0, 0, 0, false, true)

        if a > ee then
          reaper.InsertEnvelopePointEx(env, -1, a,  0.0, 0, 0, false, true)
        end
      end
    end
  end

  reaper.Envelope_SortPoints(env)
end
------------------------------------
-- CLASSIFY SOURCES
------------------------------------

local function build_source_table(all_fx_tr)
  local proj = 0
  local all_fx_idx = get_track_index(all_fx_tr)
  local track_count = reaper.CountTracks(proj)

  local sources = {}
  local source_by_tr = {}

  for i = 0, track_count - 1 do
    local tr = reaper.GetTrack(proj, i)
    if tr == all_fx_tr then
      break -- stop at All FX
    end

    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if name ~= "" and not ends_with_fx(name) then
      local entry = {
        track      = tr,
        name       = name,
        idx        = i,
        parent     = nil,
        is_parent  = false,
        is_child   = false,
        fx_track   = nil,
        children   = {},  -- will fill later
      }
      table.insert(sources, entry)
      source_by_tr[tr] = entry
    end
  end

  -- Determine parent/child relationships
  for _, entry in ipairs(sources) do
    local tr = entry.track
    local parent_tr = reaper.GetParentTrack(tr)
    if parent_tr then
      local parent_entry = source_by_tr[parent_tr]
      if parent_entry then
        entry.parent = parent_entry
        entry.is_child = true
        parent_entry.is_parent = true
        table.insert(parent_entry.children, entry)
      end
    end
  end

  -- Resolve FX tracks for each source
  for _, entry in ipairs(sources) do
    local fx_tr = get_fx_track_for_name(entry.name)
    entry.fx_track = fx_tr
  end

  return sources
end

local function build_source_table_time_sel(all_fx_tr)
  -- Get current time selection
  local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)

  -- If there is no meaningful time selection, fall back to full-table behaviour
  if not ts_start or not ts_end or ts_end <= ts_start + EPS then
    return build_source_table(all_fx_tr)
  end

  -- Local helper: collect ONLY items fully within the time selection
  local function collect_segments_for_track_time_sel_local(tr, t0, t1)
    local segments = {}
    local item_count = reaper.CountTrackMediaItems(tr)
    for i = 0, item_count - 1 do
      local item = reaper.GetTrackMediaItem(tr, i)
      local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local s    = pos
      local e    = pos + len

      -- “Fully within” with a tiny tolerance
      if e > s and s >= (t0 - EPS) and e <= (t1 + EPS) then
        table.insert(segments, { start = s, endt = e })
      end
    end
    return segments
  end

  -- Build the same sources table as normal
  local proj = 0
  local track_count = reaper.CountTracks(proj)

  local sources = {}
  local source_by_tr = {}

  for i = 0, track_count - 1 do
    local tr = reaper.GetTrack(proj, i)
    if tr == all_fx_tr then
      break -- stop at All FX
    end

    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if name ~= "" and not ends_with_fx(name) then
      local entry = {
        track      = tr,
        name       = name,
        idx        = i,
        parent     = nil,
        is_parent  = false,
        is_child   = false,
        fx_track   = nil,
        children   = {},

        -- time-selection bookkeeping (optional for later use)
        ts_start   = ts_start,
        ts_end     = ts_end,
        ts_segments = nil,
        ts_merged   = nil,
      }
      table.insert(sources, entry)
      source_by_tr[tr] = entry
    end
  end

  -- Determine parent/child relationships
  for _, entry in ipairs(sources) do
    local tr = entry.track
    local parent_tr = reaper.GetParentTrack(tr)
    if parent_tr then
      local parent_entry = source_by_tr[parent_tr]
      if parent_entry then
        entry.parent = parent_entry
        entry.is_child = true
        parent_entry.is_parent = true
        table.insert(parent_entry.children, entry)
      end
    end
  end

  -- Resolve FX tracks and precompute time-selection segments for each source track
  for _, entry in ipairs(sources) do
    entry.fx_track = get_fx_track_for_name(entry.name)

    local segs = collect_segments_for_track_time_sel_local(entry.track, ts_start, ts_end)
    entry.ts_segments = segs
    entry.ts_merged   = merge_segments(segs)
  end

  return sources
end

------------------------------------
-- CREATE SEND-MUTE ENVS VIA SWS
------------------------------------
local function ensure_all_send_mute_envs_exist(all_fx_tr, sources)
  local cmd_show = reaper.NamedCommandLookup("_BR_SHOW_SEND_ENV_MUTE_SEL_TRACK")
  if cmd_show == 0 then
    msg("WARNING: SWS action _BR_SHOW_SEND_ENV_SEL_NUTE_TRACK not found. Cannot auto-create send mute envelopes.")
    return
  end

  local proj = 0
  local track_count = reaper.CountTracks(proj)

  -- Save current track selection
  local sel = {}
  for i = 0, track_count - 1 do
    local t = reaper.GetTrack(proj, i)
    sel[i] = reaper.IsTrackSelected(t)
  end

  local function run_on_track(tr)
    if not tr then return end
    reaper.SetOnlyTrackSelected(tr)
    -- Show (this creates the send-mute envelopes if they don't exist)
    reaper.Main_OnCommand(cmd_show, 0)
    end


  -- 1) All FX: create send mute envelopes for all its sends
  run_on_track(all_fx_tr)

  -- 2) Each parent FX bus: System FX, Special 1 FX, Special 2 FX, etc.
  local visited = {}
  for _, entry in ipairs(sources) do
    if entry.is_parent and entry.fx_track and not visited[entry.fx_track] then
      run_on_track(entry.fx_track)
      visited[entry.fx_track] = true
    end
  end

  -- Restore original selection
  for i = 0, track_count - 1 do
    local t = reaper.GetTrack(proj, i)
    reaper.SetTrackSelected(t, sel[i] and true or false)
  end
end

-- Hide all send-mute envelopes for All FX and parent FX buses
local function hide_all_send_mute_envs(all_fx_tr, sources)
  -- NOTE: If your SWS action name is slightly different, update this string
  local cmd_hide = reaper.NamedCommandLookup("_BR_HIDE_SEND_ENV_SEL_NUTE_TRACK")
  if cmd_hide == 0 then
    msg("WARNING: SWS action _BR_HIDE_SEND_ENV_SEL_NUTE_TRACK not found. Cannot auto-hide send mute envelopes.")
    return
  end

  local proj        = 0
  local track_count = reaper.CountTracks(proj)

  -- Save current track selection
  local sel = {}
  for i = 0, track_count - 1 do
    local t = reaper.GetTrack(proj, i)
    sel[i] = reaper.IsTrackSelected(t)
  end

  local function run_on_track(tr)
    if not tr then return end
    reaper.SetOnlyTrackSelected(tr)
    reaper.Main_OnCommand(cmd_hide, 0)
  end

  -- 1) All FX
  run_on_track(all_fx_tr)

  -- 2) Each parent FX bus (System FX, Special 1 FX, Special 2 FX, etc.)
  local visited = {}
  for _, entry in ipairs(sources) do
    if entry.is_parent and entry.fx_track and not visited[entry.fx_track] then
      run_on_track(entry.fx_track)
      visited[entry.fx_track] = true
    end
  end

  -- Restore original selection
  for i = 0, track_count - 1 do
    local t = reaper.GetTrack(proj, i)
    reaper.SetTrackSelected(t, sel[i] and true or false)
  end
end
------------------------------------
-- MAIN
------------------------------------

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)
reaper.ClearConsole()

local all_fx_tr = get_track_by_name(NAME_ALL_FX)
local dialog_tr = get_track_by_name(NAME_DIALOGUE_BUS)
local reverb_tr = get_track_by_name(NAME_REVERB_BUS)
local char_fx_parent_tr = get_track_by_name(NAME_CHAR_FX_PARENT)

if not all_fx_tr or not dialog_tr or not reverb_tr or not char_fx_parent_tr then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Global Reset Send Mute Envelopes (FAILED - missing anchors)", -1)
  local missing = {}
  if not all_fx_tr         then table.insert(missing, NAME_ALL_FX) end
  if not dialog_tr         then table.insert(missing, NAME_DIALOGUE_BUS) end
  if not reverb_tr         then table.insert(missing, NAME_REVERB_BUS) end
  if not char_fx_parent_tr then table.insert(missing, NAME_CHAR_FX_PARENT) end
  reaper.ShowMessageBox("Missing required tracks:\n" .. table.concat(missing, "\n"), "Global Reset Send Mute Envelopes", 0)
  return
end
	
local ext = reaper.GetExtState(TS_EXTSTATE_SECTION, TS_EXTSTATE_KEY)
local time_selection_only = TIME_SELECTION_ONLY or (ext == "1")

local sources
local ts_start, ts_end = nil, nil

if time_selection_only then
  ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  sources = build_source_table_time_sel(all_fx_tr)
else
  sources = build_source_table(all_fx_tr)
end

-- Auto-create send-mute envelopes using SWS on All FX and parent FX buses
ensure_all_send_mute_envs_exist(all_fx_tr, sources)

-- Quick sanity: any source with no FX track?
for _, entry in ipairs(sources) do
  local src_name = entry.name
  local fx_tr    = entry.fx_track
  if not fx_tr then
    msg("WARNING: No FX track found for source '" .. src_name .. "'. Skipping all envelopes for this source.")
  end
end

-- 1) Standalone sources: All FX -> Name FX
for _, entry in ipairs(sources) do
  if (not entry.is_child) and (not entry.is_parent) and entry.fx_track then
    local src_name = entry.name
    local fx_tr    = entry.fx_track

    local send_idx = get_send_index(all_fx_tr, fx_tr)
    if send_idx < 0 then
      msg("WARNING: No send All FX -> '" .. src_name .. " FX' found. Skipping.")
    else
      local env = ensure_send_mute_envelope(all_fx_tr, send_idx, src_name .. " FX")
      if not env then
        msg("WARNING: No send-mute envelope for All FX -> '" .. src_name .. " FX'. Skipping.")
      else
		local segs
		if time_selection_only then
		  segs = collect_segments_for_track_time_sel(entry.track, ts_start, ts_end)
		else
		  segs = collect_segments_for_track(entry.track)
		end
		
		local merged = merge_segments(segs)
		if time_selection_only then
		  rebuild_mute_envelope_time_sel(env, merged, ts_start, ts_end)
		else
		  rebuild_mute_envelope(env, merged)
		end
      end
    end
  end
end

-- 2) Parent sources: All FX -> Parent FX (union of parent + children items)
for _, parent in ipairs(sources) do
  if parent.is_parent and parent.fx_track then
    local parent_name  = parent.name
    local parent_fx_tr = parent.fx_track

    local send_idx = get_send_index(all_fx_tr, parent_fx_tr)
    if send_idx < 0 then
      msg("WARNING: No send All FX -> '" .. parent_name .. " FX' found. Skipping.")
    else
      local env = ensure_send_mute_envelope(all_fx_tr, send_idx, parent_name .. " FX")
      if not env then
        msg("WARNING: No send-mute envelope for All FX -> '" .. parent_name .. " FX'. Skipping.")
      else
        local all_segs = {}

        -- Parent's own items (likely none, but include for robustness)
		local parent_segs
		if time_selection_only then
		  parent_segs = collect_segments_for_track_time_sel(parent.track, ts_start, ts_end)
		else
		  parent_segs = collect_segments_for_track(parent.track)
		end
        for _, seg in ipairs(parent_segs) do
          table.insert(all_segs, {start = seg.start, endt = seg.endt})
        end

        -- Children items
        for _, child in ipairs(parent.children) do
		  local child_segs
		  if time_selection_only then
		    child_segs = collect_segments_for_track_time_sel(child.track, ts_start, ts_end)
		  else
		    child_segs = collect_segments_for_track(child.track)
		  end
          for _, seg in ipairs(child_segs) do
            table.insert(all_segs, {start = seg.start, endt = seg.endt})
          end
        end

        local merged = merge_segments(all_segs)
		if time_selection_only then
		  rebuild_mute_envelope_time_sel(env, merged, ts_start, ts_end)
		else
		  rebuild_mute_envelope(env, merged)
		end
      end
    end
  end
end

-- 3) Child sources: Parent FX -> Child FX (per child)
for _, child in ipairs(sources) do
  if child.is_child and child.fx_track then
    local parent = child.parent
    if parent and parent.fx_track then
      local parent_fx_tr = parent.fx_track
      local child_fx_tr  = child.fx_track
      local child_name   = child.name

      local send_idx = get_send_index(parent_fx_tr, child_fx_tr)
      if send_idx < 0 then
        msg("WARNING: No send '" .. parent.name .. " FX' -> '" .. child_name .. " FX'. Skipping.")
      else
        local env = ensure_send_mute_envelope(parent_fx_tr, send_idx, child_name .. " FX")
        if not env then
          msg("WARNING: No send-mute envelope for '" .. parent.name .. " FX' -> '" .. child_name .. " FX'. Skipping.")
        else
		  local segs
		  if time_selection_only then
		    segs = collect_segments_for_track_time_sel(child.track, ts_start, ts_end)
		  else
		    segs = collect_segments_for_track(child.track)
		  end
		
		  local merged = merge_segments(segs)
		  if time_selection_only then
		    rebuild_mute_envelope_time_sel(env, merged, ts_start, ts_end)
		  else
		    rebuild_mute_envelope(env, merged)
		  end
        end
      end
    elseif not parent then
      msg("WARNING: Child '" .. child.name .. "' has no parent entry. Skipping child-layer envelope.")
    else
      msg("WARNING: FX track missing for parent or child of '" .. child.name .. "'. Skipping child-layer envelope.")
    end
  end
end

if not time_selection_only then
  prime_all_sends_projectwide()
end
-- Hide all send-mute envelopes now that they are created and rebuilt
hide_all_send_mute_envs(all_fx_tr, sources)

reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Global Reset Send Mute Envelopes for Character Routing", -1)
