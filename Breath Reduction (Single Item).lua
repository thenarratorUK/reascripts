--[[
ReaScript Name: Breath Reduction (Single Item)
Author: David Winter
Version: 1.0

Description:
  - Intended for use when a breath is too loud and needs reducing immediately, before moving on.
  - Finds the breath-marker item at the edit cursor (falls back to item containing cursor) on the "Breath(s)" track.
  - Uses that breath item's position/length as the processing window.
  - Finds the overlapping source track (excluding Room Tone), splits the source item at:
      * window start (action 40757)
      * window end   (action 43178 = Split and select item left of cursor)
  - Applies a pre-FX volume envelope reduction to target a peak of TARGET_PEAK dB on that isolated segment.
  - Auditions from 1.0s before to 0.25s after the breath window.
  - Does NOT delete the breath-marker item and does NOT advance to the next breath.

Notes:
  - Requires SWS (NF_GetMediaItemMaxPeak).
]]

-- Breath marker track names considered valid (case-insensitive)
local VALID_BREATH_NAMES = {
  ["breath"]   = true,
  ["breaths"]  = true,
  ["breathe"]  = true,
  ["breathes"] = true
}

-- Tracks whose names contain this substring are excluded when searching for source audio
local ROOM_TONE_NAME_SUBSTR = "room tone"

-- Target peak for the isolated breath segment (dB)
local TARGET_PEAK = -57

-- Audition range (seconds)
local PLAY_BEFORE = 1.0
local PLAY_AFTER  = 0.25

-- Action IDs
local ACTION_SPLIT_AT_CURSOR            = 40757
local ACTION_SPLIT_SELECT_LEFT_ITEM     = 43178
local ACTION_SHOW_PREFX_VOLUME_ENVELOPE = 41865
local ACTION_NUDGE_ENV_DOWN             = 41181
local ACTION_TRANSPORT_PLAY             = 1007
local ACTION_TRANSPORT_STOP             = 1016

-- Safety
local MAX_NUDGES = 500

-- Helpers
local function getTrackName(track)
  local retval, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if retval and name then return name end
  return ""
end

local function isBreathsTrack(track)
  local name = getTrackName(track):lower()
  return VALID_BREATH_NAMES[name] == true
end

local function isRoomToneTrack(track)
  local name = getTrackName(track):lower()
  return name:find(ROOM_TONE_NAME_SUBSTR, 1, true) ~= nil
end

local function getBreathsTrack()
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if isBreathsTrack(tr) then return tr end
  end
  return nil
end

local function findTrackByName(allowed_names)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local name = getTrackName(tr):lower()
    for _, allowed in ipairs(allowed_names) do
      if name == tostring(allowed):lower() then
        return tr
      end
    end
  end
  return nil
end

local default_recording_track = findTrackByName({"recording", "recordings", "david", "narration"})

local function itemBounds(item)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return pos, pos + len
end

local function overlaps(item, t0, t1)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local e = pos + len
  return (e > t0) and (pos < t1)
end

local function findSourceTrackForWindow(t0, t1, breathsTrack)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if tr ~= breathsTrack and not isRoomToneTrack(tr) then
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        if overlaps(it, t0, t1) then
          return tr
        end
      end
    end
  end
  return default_recording_track
end

local function getBreathItemAtOrContainingCursor(track, cursor_pos)
  local tol = 0.0005
  local item_count = reaper.CountTrackMediaItems(track)

  -- Prefer an item that STARTS at cursor (matches existing breath scripts)
  for i = 0, item_count - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    if math.abs(p - cursor_pos) < tol then
      return it
    end
  end

  -- Fallback: item that contains cursor
  for i = 0, item_count - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local l = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    local e = p + l
    if (cursor_pos >= p - tol) and (cursor_pos < e - tol) then
      return it
    end
  end

  return nil
end

-- Envelope helpers (mirrors Breath Reduction.lua logic)
local function envValAt(env, t)
  local _, value = reaper.Envelope_Evaluate(env, t, 0, 0)
  return value
end

local function findPointAtTime(env, t)
  local cnt = reaper.CountEnvelopePoints(env)
  local eps = 1e-7
  for i = 0, cnt - 1 do
    local ok, time = reaper.GetEnvelopePoint(env, i)
    if ok and math.abs(time - t) < eps then
      return i
    end
  end
  return nil
end

local function setPointProps(env, idx, shape, selected)
  local ok, time, value, oldShape, tension, oldSel = reaper.GetEnvelopePoint(env, idx)
  if ok then
    if shape == nil then shape = oldShape end
    if selected == nil then selected = oldSel end
    reaper.SetEnvelopePoint(env, idx, time, value, shape, tension, selected, true)
  end
end

local function ensurePoint(env, t, shape)
  local idx = findPointAtTime(env, t)
  if idx then return idx end
  local v = envValAt(env, t)
  reaper.InsertEnvelopePoint(env, t, v, shape or 0, 0, false, true)
  return findPointAtTime(env, t)
end

local function ensureBreathPointSelection(env, itemStart, itemEnd)
  local itemLen = itemEnd - itemStart
  if itemLen <= 0 then return end

  -- 0%, 10%, 90%, 100% (with slight outer padding like the batch script)
  local t1 = math.max(0, itemStart - 0.05 * itemLen)
  local t2 = itemStart + 0.10 * itemLen
  local t3 = itemStart + 0.90 * itemLen
  local t4 = itemEnd + 0.05 * itemLen

  ensurePoint(env, t1, 2) -- shape=2
  local idx2 = ensurePoint(env, t2, 0)
  local idx3 = ensurePoint(env, t3, 2) -- shape=2
  ensurePoint(env, t4, 0)

  -- Deselect all points, then select only the two middle points (10% and 90%)
  local total = reaper.CountEnvelopePoints(env)
  for p = 0, total - 1 do
    setPointProps(env, p, nil, false)
  end

  if idx2 then setPointProps(env, idx2, nil, true) end
  if idx3 then setPointProps(env, idx3, nil, true) end

  reaper.Envelope_SortPoints(env)
end

local function stopPlaybackAndResetCursorAt(playEnd, resetPos)
  local function check()
    if reaper.GetPlayPosition() >= playEnd then
      reaper.Main_OnCommand(ACTION_TRANSPORT_STOP, 0)
      if resetPos then
        reaper.SetEditCurPos(resetPos, true, false)
      end
    else
      reaper.defer(check)
    end
  end
  check()
end

-- Main
local function run()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local breathsTrack = getBreathsTrack()
  if not breathsTrack then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Breath Reduction (Single Item)", -1)
    reaper.ShowMessageBox("Could not find a 'Breath(s)' track.", "Error", 0)
    return
  end

  local cursor_pos = reaper.GetCursorPosition()
  local breathItem = getBreathItemAtOrContainingCursor(breathsTrack, cursor_pos)
  if not breathItem then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Breath Reduction (Single Item)", -1)
    reaper.ShowMessageBox("No breath item found at (or containing) the edit cursor.", "Error", 0)
    return
  end

  local breathStart, breathEnd = itemBounds(breathItem)
  if breathEnd <= breathStart then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Breath Reduction (Single Item)", -1)
    reaper.ShowMessageBox("Breath item has zero length.", "Error", 0)
    return
  end

  local sourceTrack = findSourceTrackForWindow(breathStart, breathEnd, breathsTrack)
  if not sourceTrack then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Breath Reduction (Single Item)", -1)
    reaper.ShowMessageBox("No overlapping source audio found for this breath.", "Error", 0)
    return
  end

  -- Split/select the corresponding segment on the source track
  reaper.SetOnlyTrackSelected(sourceTrack)

  reaper.SetEditCurPos(breathStart, false, false)
  reaper.Main_OnCommand(ACTION_SPLIT_AT_CURSOR, 0)

  reaper.SetEditCurPos(breathEnd, false, false)
  reaper.Main_OnCommand(ACTION_SPLIT_SELECT_LEFT_ITEM, 0)

  local segItem = reaper.GetSelectedMediaItem(0, 0)
  if not segItem then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Breath Reduction (Single Item)", -1)
    reaper.ShowMessageBox("Failed to select the isolated breath segment.", "Error", 0)
    return
  end

  local segStart, segEnd = itemBounds(segItem)
  reaper.GetSet_LoopTimeRange(true, false, segStart, segEnd, false)

  -- Activate the Volume (Pre-FX) Envelope on the selected track
  reaper.Main_OnCommand(ACTION_SHOW_PREFX_VOLUME_ENVELOPE, 0)

  local env = reaper.GetSelectedEnvelope(0)
  if env then
    ensureBreathPointSelection(env, segStart, segEnd)
  end

  if not reaper.NF_GetMediaItemMaxPeak then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Breath Reduction (Single Item)", -1)
    reaper.ShowMessageBox("SWS is required (NF_GetMediaItemMaxPeak missing).", "Error", 0)
    return
  end

  -- Measure and reduce
  local peakDb = reaper.NF_GetMediaItemMaxPeak(segItem)
  if peakDb > TARGET_PEAK then
    local needed = peakDb - TARGET_PEAK
    local rounded = math.floor(needed + 0.5)
    local nudgeCount = math.min(math.abs(rounded), MAX_NUDGES)
    for _ = 1, nudgeCount do
      reaper.Main_OnCommand(ACTION_NUDGE_ENV_DOWN, 0)
    end
  end

  -- Audition around the breath window
  local playStart = math.max(0, breathStart - PLAY_BEFORE)
  local playEnd   = breathEnd + PLAY_AFTER
  reaper.GetSet_LoopTimeRange(true, false, playStart, playEnd, false)
  reaper.SetEditCurPos(playStart, false, false)
  reaper.Main_OnCommand(ACTION_TRANSPORT_PLAY, 0)
  stopPlaybackAndResetCursorAt(playEnd, breathStart)

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Breath Reduction (Single Item)", -1)
  reaper.UpdateArrange()
end

run()
