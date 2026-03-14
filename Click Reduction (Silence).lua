--[[
ReaScript Name: Click Reduction A (Envelope)
Author: David Winter
Version: 1.0
Description:
  - Requires exactly one selected item on the Clicks track (named Click or Clicks).
  - Uses the selected click-marker item's position/length as the processing window.
  - Finds the overlapping source track (excluding Room Tone), splits the source item at:
      * window start (action 40757)
      * window end (action 43178 = Split and select item left of cursor)
    and then applies a pre-FX volume envelope reduction to target a peak of TARGET_PEAK dB.
  - Auditions from 1.0s before to 0.25s after the click window, then selects the next click item.

Notes:
  - Requires SWS (NF_GetMediaItemMaxPeak).
]]

-- Track names considered valid for click markers (case-insensitive)
local VALID_CLICK_NAMES = {
  ["click"]  = true,
  ["clicks"] = true
}

-- Tracks whose names contain this substring are excluded when searching for source audio
local ROOM_TONE_NAME_SUBSTR = "room tone"

-- Target peak level for the isolated click segment (dB)
local TARGET_PEAK = -80

-- Audition range (seconds)
local PLAY_BEFORE = 1.0
local PLAY_AFTER  = 0.25

-- Action IDs (REAPER)
local ACTION_UNSELECT_ALL_ITEMS         = 40289
local ACTION_SPLIT_AT_CURSOR            = 40757
local ACTION_SPLIT_SELECT_LEFT_ITEM     = 43178 -- Split and select item left of cursor
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

local function isClicksTrack(track)
  local name = getTrackName(track):lower()
  return VALID_CLICK_NAMES[name] == true
end

local function isRoomToneTrack(track)
  local name = getTrackName(track):lower()
  return name:find(ROOM_TONE_NAME_SUBSTR, 1, true) ~= nil
end

local function getSelectedClickItem()
  if reaper.CountSelectedMediaItems(0) ~= 1 then
    return nil, "Select exactly one click marker item on the Clicks track."
  end

  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    return nil, "No selected item."
  end

  local tr = reaper.GetMediaItem_Track(item)
  if not tr or not isClicksTrack(tr) then
    return nil, "Selected item is not on the Clicks track."
  end

  return item, nil
end

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

local function findSourceTrackForWindow(t0, t1, clicksTrack)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if tr ~= clicksTrack and not isRoomToneTrack(tr) then
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        if overlaps(it, t0, t1) then
          return tr
        end
      end
    end
  end
  return nil
end

-- Envelope helpers (same pattern as Breath Reduction.lua)
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

local function ensurePoint(env, t)
  local idx = findPointAtTime(env, t)
  if idx then return idx end
  local v = envValAt(env, t)
  reaper.InsertEnvelopePoint(env, t, v, 0, 0, false, true)
  return findPointAtTime(env, t)
end

local function ensure4PointSelection(env, itemStart, itemEnd)
  local itemLen = itemEnd - itemStart
  local t1 = itemStart
  local t2 = itemStart + 0.10 * itemLen
  local t3 = itemStart + 0.90 * itemLen
  local t4 = itemEnd

  local idx2 = ensurePoint(env, t2)
  local idx3 = ensurePoint(env, t3)
  ensurePoint(env, t1)
  ensurePoint(env, t4)

  local total = reaper.CountEnvelopePoints(env)
  for p = 0, total - 1 do
    setPointProps(env, p, nil, false)
  end
  if idx2 then setPointProps(env, idx2, nil, true) end
  if idx3 then setPointProps(env, idx3, nil, true) end

  reaper.Envelope_SortPoints(env)
end

local function selectOnlyItem(item)
  reaper.Main_OnCommand(ACTION_UNSELECT_ALL_ITEMS, 0)
  reaper.SetMediaItemSelected(item, true)
end

local function getNextClickItem(clicksTrack, afterTime)
  local bestItem, bestPos = nil, nil
  for i = 0, reaper.CountTrackMediaItems(clicksTrack) - 1 do
    local it = reaper.GetTrackMediaItem(clicksTrack, i)
    local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    if pos >= afterTime then
      if not bestPos or pos < bestPos then
        bestPos = pos
        bestItem = it
      end
    end
  end
  return bestItem
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

  local clickItem, err = getSelectedClickItem()
  if not clickItem then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Click Reduction A (Envelope)", -1)
    reaper.ShowMessageBox(err or "Invalid selection.", "Error", 0)
    return
  end

  local clicksTrack = reaper.GetMediaItem_Track(clickItem)
  local clickStart, clickEnd = itemBounds(clickItem)

  local sourceTrack = findSourceTrackForWindow(clickStart, clickEnd, clicksTrack)
  if not sourceTrack then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Click Reduction A (Envelope)", -1)
    reaper.ShowMessageBox("No overlapping source audio found for this click.", "Error", 0)
    return
  end

  -- Split/select segment using actions (same approach as Breath Reduction.lua)
  reaper.SetOnlyTrackSelected(sourceTrack)

  reaper.SetEditCurPos(clickStart, false, false)
  reaper.Main_OnCommand(ACTION_SPLIT_AT_CURSOR, 0)

  reaper.SetEditCurPos(clickEnd, false, false)
  reaper.Main_OnCommand(ACTION_SPLIT_SELECT_LEFT_ITEM, 0)

  local segItem = reaper.GetSelectedMediaItem(0, 0)
  if not segItem then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Click Reduction A (Envelope)", -1)
    reaper.ShowMessageBox("Failed to select the isolated click segment.", "Error", 0)
    return
  end

  local segStart, segEnd = itemBounds(segItem)
  reaper.GetSet_LoopTimeRange(true, false, segStart, segEnd, false)

  -- Show/activate pre-FX volume envelope
  reaper.Main_OnCommand(ACTION_SHOW_PREFX_VOLUME_ENVELOPE, 0)

  local env = reaper.GetSelectedEnvelope(0)
  if env then
    ensure4PointSelection(env, segStart, segEnd)
  end

  if not reaper.NF_GetMediaItemMaxPeak then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Click Reduction A (Envelope)", -1)
    reaper.ShowMessageBox("SWS is required (NF_GetMediaItemMaxPeak missing).", "Error", 0)
    return
  end

  local peakDb = reaper.NF_GetMediaItemMaxPeak(segItem)
  if peakDb > TARGET_PEAK then
    local needed = peakDb - TARGET_PEAK
    local rounded = math.floor(needed + 0.5)
    local nudgeCount = math.min(math.abs(rounded), MAX_NUDGES)
    for _ = 1, nudgeCount do
      reaper.Main_OnCommand(ACTION_NUDGE_ENV_DOWN, 0)
    end
  end

  -- Audition then advance selection to next click
  local playStart = math.max(0, clickStart - PLAY_BEFORE)
  local playEnd   = clickEnd + PLAY_AFTER
  -- NOTE: Do not automatically advance to the next click from this script.
  reaper.GetSet_LoopTimeRange(true, false, playStart, playEnd, false)
  reaper.SetEditCurPos(playStart, false, false)
  reaper.Main_OnCommand(ACTION_TRANSPORT_PLAY, 0)
  stopPlaybackAndResetCursorAt(playEnd, clickStart)

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Click Reduction A (Envelope)", -1)
  reaper.UpdateArrange()
end

run()
