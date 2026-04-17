-- @description Pre-FX Peak Dip Automation (Follow Exact Action Steps).lua
-- @version 3.2
-- @author David Winter
--[[
ReaScript Name  : Pre-FX Peak Dip Automation (Follow Exact Action Steps).lua
Author          : (for David Winter)
Version         : 3.2

Adds one extra step at the end:
- Move the 2nd point (by time order) to 10% through the time selection
- Move the 4th point (by time order) to 90% through the time selection

Workflow (action-driven):
1) 41865  Track: Select pre-FX volume envelope
2) 40726  Create 4 envelope points at time selection
3) 41181  Move selected points down a little bit
4) 41181  Move selected points down a little bit
5) Deselect envelope points
6) AudioAccessor: find X = highest peak time in time selection on selected track
7) Save edit cursor position
8) Move edit cursor to X (ensure pre-FX envelope is still selected)
9) 40106  Insert new point at current position (do not remove nearby points)
10) 41181 x3 move selected point down a little bit
11) Select all points in an area slightly wider than the time selection (get 5 points)
12) Move point #2 to 10% and point #4 to 90% (by time order among the 5 points)
13) Deselect the 5th point (rightmost by time)
14) 40424 Set shape of selected points to slow start/end
15) Restore saved edit cursor position
--]]

local function err(s) reaper.ShowMessageBox(tostring(s), "ReaScript", 0) end

local function clamp(x, a, b)
  if x < a then return a end
  if x > b then return b end
  return x
end

local function get_time_selection()
  local t0, t1 = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  if not t0 or not t1 or t1 <= t0 then return nil end
  return t0, t1
end

local function get_project_srate()
  local sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
  if not sr or sr < 8000 then sr = 44100 end
  return sr
end

local function save_selected_tracks()
  local out = {}
  local n = reaper.CountSelectedTracks(0)
  for i = 0, n - 1 do out[#out + 1] = reaper.GetSelectedTrack(0, i) end
  return out
end

local function restore_selected_tracks(list)
  reaper.Main_OnCommand(40297, 0) -- Unselect all tracks
  for i = 1, #list do reaper.SetTrackSelected(list[i], true) end
end

local function get_prefx_env(track)
  local env = reaper.GetTrackEnvelopeByName(track, "Volume (Pre-FX)")
  if env then return env end
  env = reaper.GetTrackEnvelopeByName(track, "Volume (pre-FX)")
  if env then return env end
  return nil
end

local function deselect_all_env_points(env)
  local n = reaper.CountEnvelopePointsEx(env, -1)
  for i = 0, n - 1 do
    local ok, t, v, shape, tens, sel = reaper.GetEnvelopePointEx(env, -1, i)
    if ok and sel then
      reaper.SetEnvelopePointEx(env, -1, i, t, v, shape, tens, false, true)
    end
  end
  reaper.Envelope_SortPointsEx(env, -1)
end

local function select_points_in_range(env, left, right)
  local picked = {}
  local n = reaper.CountEnvelopePointsEx(env, -1)
  for i = 0, n - 1 do
    local ok, t, v, shape, tens, sel = reaper.GetEnvelopePointEx(env, -1, i)
    if ok and t >= left and t <= right then
      reaper.SetEnvelopePointEx(env, -1, i, t, v, shape, tens, true, true)
      picked[#picked+1] = {idx=i, t=t}
    end
  end
  reaper.Envelope_SortPointsEx(env, -1)
  table.sort(picked, function(a,b) return a.t < b.t end)
  return picked
end

local function deselect_point(env, idx)
  local ok, t, v, shape, tens, sel = reaper.GetEnvelopePointEx(env, -1, idx)
  if not ok then return end
  reaper.SetEnvelopePointEx(env, -1, idx, t, v, shape, tens, false, true)
end

local function set_point_time(env, idx, new_t, noSort)
  local ok, t, v, shape, tens, sel = reaper.GetEnvelopePointEx(env, -1, idx)
  if not ok then return false end
  reaper.SetEnvelopePointEx(env, -1, idx, new_t, v, shape, tens, sel, noSort == true)
  return true
end

local function refresh_picked_times(env, picked)
  for i = 1, #picked do
    local ok, t = reaper.GetEnvelopePointEx(env, -1, picked[i].idx)
    picked[i].t = ok and t or picked[i].t
  end
  table.sort(picked, function(a,b) return a.t < b.t end)
  return picked
end

local function keep_five_closest_to_targets(env, picked, targets)
  if #picked <= 5 then return picked end

  local scored = {}
  for i = 1, #picked do
    local t = picked[i].t
    local best = math.huge
    for k = 1, #targets do
      local d = math.abs(t - targets[k])
      if d < best then best = d end
    end
    scored[#scored+1] = {idx=picked[i].idx, t=t, score=best}
  end

  table.sort(scored, function(a,b)
    if a.score == b.score then return a.t < b.t end
    return a.score < b.score
  end)

  local keep = {}
  for i = 1, 5 do keep[scored[i].idx] = true end

  local kept = {}
  for i = 1, #picked do
    local p = picked[i]
    if keep[p.idx] then
      kept[#kept+1] = p
    else
      deselect_point(env, p.idx)
    end
  end

  table.sort(kept, function(a,b) return a.t < b.t end)
  reaper.Envelope_SortPointsEx(env, -1)
  return kept
end

local function find_peak_time_on_track(track, t0, t1)
  local sr = get_project_srate()
  local nchan = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_NCHAN") or 2)
  if nchan < 1 then nchan = 2 end
  if nchan > 64 then nchan = 64 end

  local acc = reaper.CreateTrackAudioAccessor(track)
  if not acc then return t0 end

  local block = 4096
  local buf = reaper.new_array(block * nchan)

  local best_abs = -1.0
  local best_t = t0

  local cur = t0
  while cur < t1 do
    local remain = t1 - cur
    local want = math.floor(remain * sr + 0.5)
    if want <= 0 then break end
    if want > block then want = block end

    buf.clear()
    local ok = reaper.GetAudioAccessorSamples(acc, sr, nchan, cur, want, buf)
    if not ok then break end

    local data = buf.table()
    for i = 0, want - 1 do
      local base = i * nchan
      for ch = 1, nchan do
        local s = data[base + ch] or 0.0
        local a = math.abs(s)
        if a > best_abs then
          best_abs = a
          best_t = cur + (i / sr)
        end
      end
    end

    cur = cur + (want / sr)
  end

  reaper.DestroyAudioAccessor(acc)
  return clamp(best_t, t0, t1)
end

-- -------------------- main --------------------

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local track = reaper.GetSelectedTrack(0, 0)
if not track then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Pre-FX peak dip automation (actions)", -1)
  err("Select a track first.")
  return
end

local t0, t1 = get_time_selection()
if not t0 then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Pre-FX peak dip automation (actions)", -1)
  err("Set a non-empty time selection first.")
  return
end

local saved_tracks = save_selected_tracks()
reaper.SetOnlyTrackSelected(track)

-- Step 1: select pre-FX volume envelope
reaper.Main_OnCommand(41865, 0)

local env = get_prefx_env(track)
if not env then
  reaper.Main_OnCommand(40050, 0) -- Track: Toggle track pre-FX volume envelope active
  reaper.Main_OnCommand(41865, 0)
  env = get_prefx_env(track)
end

if not env then
  restore_selected_tracks(saved_tracks)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Pre-FX peak dip automation (actions)", -1)
  err("Couldn't access 'Volume (Pre-FX)' envelope.")
  return
end

-- Ensure envelope actions target this envelope
reaper.SetCursorContext(2, env)

-- Step 2: create 4 points
reaper.Main_OnCommand(40726, 0)

-- Step 3-4: move selected points down twice (central two are expected selected)
reaper.Main_OnCommand(41181, 0)
reaper.Main_OnCommand(41181, 0)

-- Step 5: deselect envelope points
deselect_all_env_points(env)

-- Step 6: find X via audio accessor
local tx = find_peak_time_on_track(track, t0, t1)

-- Step 7: save edit cursor
local saved_cursor = reaper.GetCursorPosition()

-- Step 8: move cursor to X, ensure pre-FX env selected
reaper.SetEditCurPos(tx, false, false)
reaper.Main_OnCommand(41865, 0)
reaper.SetCursorContext(2, env)

-- Step 9: insert new point at cursor
reaper.Main_OnCommand(40106, 0)

-- Step 10: move selected (the new point) down a little bit 3 times
reaper.Main_OnCommand(41181, 0)
reaper.Main_OnCommand(41181, 0)
reaper.Main_OnCommand(41181, 0)

-- Step 11: select all points in an area slightly wider than the time selection
deselect_all_env_points(env)

local len = t1 - t0
local margin = math.max(0.02, len * 0.05)
local left = t0 - margin
local right = t1 + margin

local picked = select_points_in_range(env, left, right)

-- If more than 5 points were caught (existing points nearby), keep the 5 closest to expected target times
local t10 = t0 + 0.10 * len
local t90 = t0 + 0.90 * len
local targets = { t0, t10, tx, t90, t1 }
if #picked > 5 then
  picked = keep_five_closest_to_targets(env, picked, targets)
end

if #picked < 5 then
  reaper.SetEditCurPos(saved_cursor, false, false)
  restore_selected_tracks(saved_tracks)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Pre-FX peak dip automation (actions)", -1)
  err("Expected 5 envelope points in the widened selection window, but found " .. tostring(#picked) .. ".")
  return
end

-- Step 12: move the 2nd point to 10% and the 4th point to 90% (by time order)
picked = refresh_picked_times(env, picked)

local idx2 = picked[2].idx
local idx4 = picked[4].idx

set_point_time(env, idx2, t10, true)
set_point_time(env, idx4, t90, true)
reaper.Envelope_SortPointsEx(env, -1)

picked = refresh_picked_times(env, picked)

-- Step 13: deselect the 5th point (rightmost by time)
local rightmost = picked[#picked]
deselect_point(env, rightmost.idx)
reaper.Envelope_SortPointsEx(env, -1)

-- Step 14: set shape of selected points to slow start/end
reaper.SetCursorContext(2, env)
reaper.Main_OnCommand(40424, 0)

-- Step 15: restore cursor position
reaper.SetEditCurPos(saved_cursor, false, false)

restore_selected_tracks(saved_tracks)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Pre-FX peak dip automation (actions)", -1)
