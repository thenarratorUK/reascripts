-- @description ReaGate Threshold: 4-point dip via actions (+ slow start/end on points 1 and 3)
-- @author David Winter

local UNDO_NAME = "ReaGate Threshold: 4-point dip via actions"

local function msg_box(s)
  reaper.ShowMessageBox(tostring(s), "ReaScript", 0)
end

local function bail(err)
  reaper.Undo_EndBlock(UNDO_NAME, -1)
  reaper.PreventUIRefresh(-1)
  if err and err ~= "" then msg_box(err) end
end

local function get_first_selected_track()
  return reaper.GetSelectedTrack(0, 0)
end

local function find_track_by_name_ci(target)
  local n = reaper.CountTracks(0)
  local tgt = target:lower()
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, name = reaper.GetTrackName(tr, "")
    if ok and name and name:lower():find(tgt, 1, true) then
      return tr, name
    end
  end
  return nil, nil
end

local function find_fx_by_name(track, fx_substring)
  local fx_count = reaper.TrackFX_GetCount(track)
  for i = 0, fx_count - 1 do
    local ok, fx_name = reaper.TrackFX_GetFXName(track, i, "")
    if ok and fx_name and fx_name:find(fx_substring) then
      return i, fx_name
    end
  end
  return -1, nil
end

local function find_param_by_name_ci(track, fx_index, param_substring)
  local nparams = reaper.TrackFX_GetNumParams(track, fx_index)
  local tgt = param_substring:lower()
  for p = 0, nparams - 1 do
    local ok, pname = reaper.TrackFX_GetParamName(track, fx_index, p, "")
    if ok and pname and pname:lower():find(tgt, 1, true) then
      return p, pname
    end
  end
  return -1, nil
end

local function get_point(env, idx)
  local ok, t, v, sh, te, sel = reaper.GetEnvelopePoint(env, idx)
  if not ok then return nil end
  return {i=idx, t=t, v=v, sh=sh, te=te, sel=sel}
end

local function set_point_selected(env, idx, selected)
  local p = get_point(env, idx)
  if not p then return false end
  reaper.SetEnvelopePoint(env, idx, p.t, p.v, p.sh, p.te, selected and true or false, true)
  return true
end

local function find_selected_points(env)
  local n = reaper.CountEnvelopePoints(env)
  local sel = {}
  for i = 0, n - 1 do
    local p = get_point(env, i)
    if p and p.sel then sel[#sel+1] = p end
  end
  table.sort(sel, function(a,b) return a.t < b.t end)
  return sel
end

local function find_point_index_before_time(env, t)
  -- Find the point immediately before time t (strictly < t)
  local n = reaper.CountEnvelopePoints(env)
  if n <= 0 then return -1 end

  -- GetEnvelopePointByTime usually returns the point at/before t.
  local idx = reaper.GetEnvelopePointByTime(env, t)
  if idx < 0 then return -1 end

  -- Ensure strictly before.
  local p = get_point(env, idx)
  if p and p.t < t then return idx end

  -- Otherwise check earlier indices.
  for i = idx - 1, 0, -1 do
    p = get_point(env, i)
    if p and p.t < t then return i end
  end
  return -1
end

-- =========================
-- Main
-- =========================

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- Must have time selection
local ts, te = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
if not ts or not te or te <= ts then
  return bail("No time selection found.")
end

-- Selected track
local track = get_first_selected_track()
if not track then
  return bail("No track selected.")
end

-- Find ReaGate on selected track, else AllFX / All FX
local fx_index, fx_name = find_fx_by_name(track, "ReaGate")
local track_used_name

if fx_index < 0 then
  local allfx, allfx_name = find_track_by_name_ci("AllFX")
  if not allfx then allfx, allfx_name = find_track_by_name_ci("All FX") end
  if not allfx then
    return bail("No ReaGate on selected track, and no track named 'AllFX' or 'All FX' found.")
  end
  track = allfx
  track_used_name = allfx_name
  fx_index, fx_name = find_fx_by_name(track, "ReaGate")
  if fx_index < 0 then
    return bail("Track '" .. tostring(allfx_name) .. "' found, but it has no ReaGate.")
  end
else
  local ok, nm = reaper.GetTrackName(track, "")
  track_used_name = ok and nm or "(unknown)"
end

-- Threshold param
local thr_param, thr_name = find_param_by_name_ci(track, fx_index, "Threshold")
if thr_param < 0 then
  return bail("ReaGate found, but couldn't locate a parameter containing 'Threshold'.")
end

-- Get/create envelope
local env = reaper.GetFXEnvelope(track, fx_index, thr_param, true)
if not env then
  return bail("Failed to get/create the Threshold envelope.")
end

-- Ensure actions apply to this envelope
if not reaper.SetCursorContext then
  return bail("SetCursorContext() is not available in this REAPER build; cannot reliably target the envelope for actions.")
end
reaper.SetCursorContext(2, env)

-- 1) Insert 4 points at time selection (centre two should be selected)
reaper.Main_OnCommand(40726, 0)

-- 2) Instead of "down a tiny bit", set the currently selected (centre) points to exactly (current dB - 2.0 dB)

-- Helper: parse first numeric token from formatted strings like "-38.0 dB", also handle "-inf"
local function parse_db(s)
  if not s or s == "" then return nil end
  local lower = s:lower()
  if lower:find("-inf", 1, true) or lower:find("-∞", 1, true) then return -1e12 end
  if lower:find("inf", 1, true) or lower:find("∞", 1, true) then return  1e12 end
  local num = lower:match("[-+]?%d+%.?%d*") or lower:match("[-+]?%d*%.%d+")
  return num and tonumber(num) or nil
end

-- Helper: get displayed dB for a given normalized value (0..1) without changing anything
local function db_from_norm(track_, fx_, param_, norm_)
  local ok, buf = reaper.TrackFX_FormatParamValueNormalized(track_, fx_, param_, norm_, "")
  if not ok then return nil end
  return parse_db(buf)
end

-- Helper: find normalized value that corresponds to target_db (best effort)
local function norm_for_target_db(track_, fx_, param_, target_db_)
  local db0 = db_from_norm(track_, fx_, param_, 0.0)
  local db1 = db_from_norm(track_, fx_, param_, 1.0)
  if db0 == nil or db1 == nil then return nil end

  local increasing = (db1 > db0)

  -- Clamp to reachable range
  local min_db = math.min(db0, db1)
  local max_db = math.max(db0, db1)
  if target_db_ < min_db then target_db_ = min_db end
  if target_db_ > max_db then target_db_ = max_db end

  local lo, hi = 0.0, 1.0
  local best = 0.5
  local best_err = 1e18

  for _ = 1, 60 do
    local mid = (lo + hi) * 0.5
    local dbm = db_from_norm(track_, fx_, param_, mid)
    if dbm == nil then break end

    local err = math.abs(dbm - target_db_)
    if err < best_err then
      best_err = err
      best = mid
    end

    if increasing then
      if dbm < target_db_ then lo = mid else hi = mid end
    else
      if dbm > target_db_ then lo = mid else hi = mid end
    end
  end

  return best
end

-- Get the currently selected points (should be the centre two after 40726)
local sel_now = find_selected_points(env)
if #sel_now < 2 then
  return bail("Expected at least 2 selected envelope points after 40726, but found " .. tostring(#sel_now) .. ".")
end

-- Use earlier+later selected as the two "centre" points (robust if more happen to be selected)
local inner_left  = sel_now[1]
local inner_right = sel_now[#sel_now]

-- Measure current value from the selected centre points (they should match; take the left)
local current_norm = inner_left.v

-- Convert to dB, subtract 2 dB, convert back to normalized value
local current_db = db_from_norm(track, fx_index, thr_param, current_norm)
if current_db == nil or math.abs(current_db) > 1e11 then
  return bail("Could not read a usable Threshold dB value from the selected points.")
end

local target_db = current_db - 2.0
local target_norm = norm_for_target_db(track, fx_index, thr_param, target_db)
if not target_norm then
  return bail("Could not compute target value for (current - 2.0 dB).")
end

-- Set both selected centre points to target_norm, keeping their times/shapes/tensions
do
  local p = get_point(env, inner_left.i)
  if p then
    reaper.SetEnvelopePoint(env, p.i, p.t, target_norm, p.sh, p.te, true, true)
  end
end

do
  local p = get_point(env, inner_right.i)
  if p then
    reaper.SetEnvelopePoint(env, p.i, p.t, target_norm, p.sh, p.te, true, true)
  end
end

-- 3) Deselect the earlier of the two selected centre points, select the point immediately before it
local sel = find_selected_points(env)
if #sel < 2 then
  return bail("Expected at least 2 selected envelope points after 40726, but found " .. tostring(#sel) .. ".")
end

-- Earlier selected point (by time)
local earlier = sel[1]
local earlier_idx = earlier.i

-- Point immediately before it (outer-left point inserted by 40726)
local prev_idx = find_point_index_before_time(env, earlier.t)
if prev_idx < 0 then
  return bail("Could not find a point before the earlier selected point to swap selection.")
end

-- Apply selection swap: earlier selected off, previous point on
set_point_selected(env, earlier_idx, false)
set_point_selected(env, prev_idx, true)

-- 4) Set shape of selected points to slow start/end
reaper.Main_OnCommand(40424, 0)

-- Optional: sort points (generally safe)
reaper.Envelope_SortPoints(env)

-- Optional: hide FX envelopes for selected tracks if SWS action exists
local hide_cmd = reaper.NamedCommandLookup("_BR_HIDE_FX_ENV_SEL_TRACK")
if hide_cmd and hide_cmd ~= 0 then
  reaper.Main_OnCommand(hide_cmd, 0)
end

reaper.Undo_EndBlock(UNDO_NAME, -1)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
