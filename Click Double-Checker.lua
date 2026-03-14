-- @description Tails Click Check: advance marker to item end and play last 1s (+0.5s)
-- @author David Winter
-- @version 1.1

local PROJ = 0

local MARKER_NAME = "Tails checked up to here"
local REGION_NAME = "00 Opening Credits"

local PRE_ROLL  = 0.50  -- seconds before item end
local POST_ROLL = 0.25  -- seconds after item end

local REPEAT_CMD = 1068 -- Transport: Repeat

local IGNORE_TRACKS = {
  ["clicks"] = true,
  ["breaths"] = true,
  ["renders"] = true,
  ["room tone"] = true,
}

local function msg(s)
  reaper.ShowMessageBox(tostring(s), "Tails Click Check", 0)
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function startswith_nameish(trackLower, keyLower)
  if trackLower == keyLower then return true end
  if trackLower:sub(1, #keyLower) ~= keyLower then return false end
  local nextch = trackLower:sub(#keyLower + 1, #keyLower + 1)
  return nextch == " " or nextch == "-" or nextch == ":" or nextch == "(" or nextch == "[" or nextch == "{"
end

local function is_ignored_track(track)
  if not track then return false end
  local _, name = reaper.GetTrackName(track, "")
  name = trim(tostring(name or "")):lower()
  if name == "" then return false end

  for k,_ in pairs(IGNORE_TRACKS) do
    if startswith_nameish(name, k) then
      return true
    end
  end
  return false
end

local function find_named_marker(name)
  local _, num_markers, num_regions = reaper.CountProjectMarkers(PROJ)
  local total = num_markers + num_regions

  for i = 0, total - 1 do
    local retval, isrgn, pos, rgnend, mname, markrgnindexnumber = reaper.EnumProjectMarkers2(PROJ, i)
    if retval and (not isrgn) and (mname == name) then
      return { pos = pos, idx = markrgnindexnumber }
    end
  end
  return nil
end

local function find_region_start(name)
  local _, num_markers, num_regions = reaper.CountProjectMarkers(PROJ)
  local total = num_markers + num_regions

  for i = 0, total - 1 do
    local retval, isrgn, pos, rgnend, mname = reaper.EnumProjectMarkers2(PROJ, i)
    if retval and isrgn and (mname == name) then
      return pos
    end
  end
  return nil
end

local function get_relevant_item_at_time(t)
  local itemCount = reaper.CountMediaItems(PROJ)
  if itemCount == 0 then return nil end

  local bestNextItem = nil
  local bestNextStart = math.huge
  local bestNextEnd = nil

  for i = 0, itemCount - 1 do
    local item = reaper.GetMediaItem(PROJ, i)
    local track = reaper.GetMediaItem_Track(item)

    if not is_ignored_track(track) then
      local itStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local itLen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local itEnd = itStart + itLen

      -- If t is inside the item, that item is the one.
      -- If t equals item end exactly, treat it as NOT inside (so gaps behave sensibly).
      if (t >= itStart) and (t < itEnd - 1e-12) then
        return item, itStart, itEnd
      end

      -- Otherwise, pick the next item starting at/after t.
      if (itStart >= t) and (itStart < bestNextStart) then
        bestNextItem = item
        bestNextStart = itStart
        bestNextEnd = itEnd
      end
    end
  end

  if bestNextItem then
    return bestNextItem, bestNextStart, bestNextEnd
  end

  return nil
end

local function set_repeat_off()
  if reaper.GetToggleCommandStateEx(0, REPEAT_CMD) == 1 then
    reaper.Main_OnCommand(REPEAT_CMD, 0)
  end
end

local function set_time_selection(a, b)
  if a < 0 then a = 0 end
  if b < 0 then b = 0 end
  if b < a then b = a end
  reaper.GetSet_LoopTimeRange(true, false, a, b, false)
end

local function replace_marker_at_time(oldMarker, t)
  if oldMarker and oldMarker.idx then
    reaper.DeleteProjectMarker(PROJ, oldMarker.idx, false)
  end
  reaper.AddProjectMarker2(PROJ, false, t, 0, MARKER_NAME, -1, 0)
end

local function play_time_selection_and_stop_at_end(tsStart, tsEnd)
  local token = tostring(reaper.time_precise())
  reaper.SetExtState("DW_TailsClickCheck", "token", token, false)

  reaper.SetEditCurPos(tsStart, true, false)
  reaper.OnPlayButton()

  local function monitor()
    if reaper.GetExtState("DW_TailsClickCheck", "token") ~= token then return end

    local playState = reaper.GetPlayState()
    if (playState & 1) == 0 then return end

    local pos = reaper.GetPlayPosition()
    if pos >= tsEnd then
      reaper.OnStopButton()
      return
    end

    reaper.defer(monitor)
  end

  reaper.defer(monitor)
end

local function main()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local existingMarker = find_named_marker(MARKER_NAME)

  local startPos = nil
  if existingMarker then
    startPos = existingMarker.pos
  else
    startPos = find_region_start(REGION_NAME)
    if not startPos then
      reaper.PreventUIRefresh(-1)
      reaper.Undo_EndBlock("Tails Click Check", -1)
      msg('Could not find marker "' .. MARKER_NAME .. '" or region "' .. REGION_NAME .. '".')
      return
    end
  end

  local item, itStart, itEnd = get_relevant_item_at_time(startPos)
  if not item then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Tails Click Check", -1)
    msg("No non-ignored media item found at/after the start point.")
    return
  end

  local X = itEnd
  local tsStart = X - PRE_ROLL
  local tsEnd = X + POST_ROLL

  set_time_selection(tsStart, tsEnd)
  set_repeat_off()
  replace_marker_at_time(existingMarker, X)

  reaper.UpdateArrange()
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Tails Click Check: advance marker + play window", -1)

  play_time_selection_and_stop_at_end(math.max(0, tsStart), tsEnd)
end

main()
