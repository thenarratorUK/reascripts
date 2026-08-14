-- @description Script Sync: Add Pickup Region and Focus Track
-- @version 1.3
-- @author David Winter
-- @about Handles pickup-region, click-to-focus, and original-source-time requests from the local Script Sync viewer.

local SECTION = "ScriptSyncPickup"
local REQUEST_KEYS = { "mode", "request_id", "name", "start", "end", "color", "position" }
local DEFAULT_COLOR = "990000"
local DUPLICATE_TOLERANCE_SECONDS = 0.02
local ITEM_EDGE_TOLERANCE_SECONDS = 0.000001
local VERTICAL_SCROLL_SELECTED_TRACKS = 40913

local function getExtStateValue(key)
  local ok, value = reaper.GetProjExtState(0, SECTION, key)
  if ok == 0 then
    return ""
  end
  return value or ""
end

local function setExtStateValue(key, value)
  reaper.SetProjExtState(0, SECTION, key, tostring(value or ""))
end

local function clearRequest()
  for _, key in ipairs(REQUEST_KEYS) do
    setExtStateValue(key, "")
  end
end

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normaliseTrackName(value)
  return trim(value):lower():gsub("%s+", " ")
end

local function getTrackName(track)
  local _, name = reaper.GetTrackName(track)
  return name or ""
end

local function isRoomToneTrack(track)
  return normaliseTrackName(getTrackName(track)) == "room tone"
end

local function audioItemContainsPosition(item, position)
  local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local itemLength = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local itemEnd = itemStart + itemLength
  if position < itemStart - ITEM_EDGE_TOLERANCE_SECONDS
    or position >= itemEnd - ITEM_EDGE_TOLERANCE_SECONDS
  then
    return false
  end

  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    return false
  end
  return reaper.GetMediaItemTake_Source(take) ~= nil
end

local function tracksWithAudioAtPosition(position)
  local tracksByNumber = {}
  for itemIndex = 0, reaper.CountMediaItems(0) - 1 do
    local item = reaper.GetMediaItem(0, itemIndex)
    if item and audioItemContainsPosition(item, position) then
      local track = reaper.GetMediaItem_Track(item)
      if track and not isRoomToneTrack(track) then
        local trackNumber = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") + 0.5)
        tracksByNumber[trackNumber] = track
      end
    end
  end

  local records = {}
  for trackNumber, track in pairs(tracksByNumber) do
    records[#records + 1] = {
      number = trackNumber,
      track = track,
      name = getTrackName(track),
    }
  end
  table.sort(records, function(left, right)
    return left.number < right.number
  end)
  return records
end

local function chooseFocusTrack(records)
  if #records == 0 then
    return nil, "none"
  end
  if #records == 1 then
    return records[1], "single"
  end
  for index = 2, #records do
    if records[index].number ~= records[index - 1].number + 1 then
      return nil, "separated"
    end
  end
  return records[1], "contiguous"
end

local function scrollTrackIntoView(record)
  local selected = {}
  local trackCount = reaper.CountTracks(0)
  reaper.PreventUIRefresh(1)
  for trackIndex = 0, trackCount - 1 do
    local track = reaper.GetTrack(0, trackIndex)
    selected[trackIndex + 1] = reaper.IsTrackSelected(track)
    reaper.SetTrackSelected(track, false)
  end

  reaper.SetTrackSelected(record.track, true)
  reaper.Main_OnCommand(VERTICAL_SCROLL_SELECTED_TRACKS, 0)

  for trackIndex = 0, trackCount - 1 do
    reaper.SetTrackSelected(reaper.GetTrack(0, trackIndex), selected[trackIndex + 1])
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
end

local function hexToNativeColor(hex)
  if not hex or hex == "" then
    return 0
  end
  hex = hex:gsub("#", "")
  if #hex < 6 then
    return 0
  end
  local r = tonumber(hex:sub(1, 2), 16)
  local g = tonumber(hex:sub(3, 4), 16)
  local b = tonumber(hex:sub(5, 6), 16)
  if not (r and g and b) then
    return 0
  end
  return reaper.ColorToNative(r, g, b)
end

local function regionAlreadyExists(name, startPos, endPos)
  local index = 0
  while true do
    local ok, isRegion, existingStart, existingEnd, existingName = reaper.EnumProjectMarkers(index)
    if ok == 0 then
      break
    end
    if isRegion
      and existingName == name
      and math.abs(existingStart - startPos) <= DUPLICATE_TOLERANCE_SECONDS
      and math.abs(existingEnd - endPos) <= DUPLICATE_TOLERANCE_SECONDS
    then
      return true
    end
    index = index + 1
  end
  return false
end

local function showError(message)
  reaper.ShowConsoleMsg("Script Sync: " .. message .. "\n")
end

local function addPickupRegion()
  local name = trim(getExtStateValue("name"):gsub("[\r\n\t]", " "))
  local startPos = tonumber(getExtStateValue("start"))
  local endPos = tonumber(getExtStateValue("end"))
  local colorText = getExtStateValue("color")
  clearRequest()

  if name == "" or not startPos or not endPos then
    showError("Script Sync pickup region request was incomplete.")
    return
  end
  if endPos <= startPos then
    endPos = startPos + 1
  end

  local color = hexToNativeColor(colorText ~= "" and colorText or DEFAULT_COLOR) | 0x1000000
  if not regionAlreadyExists(name, startPos, endPos) then
    local markerIndex = reaper.AddProjectMarker2(0, true, startPos, endPos, name, -1, color)
    if markerIndex >= 0 then
      reaper.SetProjectMarker(markerIndex, true, startPos, endPos, name, color)
    end
  end
  reaper.UpdateTimeline()
end

local function focusTrack()
  local position = tonumber(getExtStateValue("position"))
  clearRequest()
  if not position or position < 0 then
    setExtStateValue("result", "invalid-position")
    return
  end

  local record, reason = chooseFocusTrack(tracksWithAudioAtPosition(position))
  if not record then
    setExtStateValue("result", reason)
    return
  end

  scrollTrackIntoView(record)
  local safeName = record.name:gsub("[\r\n\t|]", " ")
  setExtStateValue("result", string.format("moved|%d|%s|%s", record.number, safeName, reason))
end

local function safeResultField(value)
  return tostring(value or ""):gsub("[\r\n\t|]", " ")
end

local function sourceCandidateForItem(item, position)
  if reaper.GetMediaItemInfo_Value(item, "B_MUTE") >= 0.5 then
    return nil
  end

  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    return nil
  end
  local source = reaper.GetMediaItemTake_Source(take)
  if not source then
    return nil
  end

  local sourcePath = reaper.GetMediaSourceFileName(source, "") or ""
  if sourcePath == "" then
    return nil
  end

  local sectionOffset = 0
  local sourceLength = reaper.GetMediaSourceLength(source)
  local hasSection, sectionStart, sectionLength, sectionReversed = reaper.PCM_Source_GetSectionInfo(source)
  if hasSection then
    if sectionReversed then
      return { unsupported = "reversed-source", path = sourcePath }
    end
    sectionOffset = tonumber(sectionStart) or 0
    if tonumber(sectionLength) and sectionLength > 0 then
      sourceLength = sectionLength
    end
  end

  local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local takeOffset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local playRate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if not playRate or playRate <= 0 then
    return { unsupported = "invalid-playrate", path = sourcePath }
  end

  local sourceTime = takeOffset + (position - itemStart) * playRate
  local loopsSource = reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC") >= 0.5
  if loopsSource and sourceLength and sourceLength > 0 then
    sourceTime = sourceTime % sourceLength
  end
  sourceTime = sourceTime + sectionOffset

  return { time = sourceTime, path = sourcePath, playRate = playRate }
end

local function sourceCandidatesOnTrack(track, position)
  local candidates = {}
  local unsupported = {}
  for itemIndex = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, itemIndex)
    if item and audioItemContainsPosition(item, position) then
      local candidate = sourceCandidateForItem(item, position)
      if candidate then
        if candidate.unsupported then
          unsupported[#unsupported + 1] = candidate
        else
          local duplicate = false
          for _, existing in ipairs(candidates) do
            if existing.path == candidate.path and math.abs(existing.time - candidate.time) <= 0.01 then
              duplicate = true
              break
            end
          end
          if not duplicate then
            candidates[#candidates + 1] = candidate
          end
        end
      end
    end
  end
  return candidates, unsupported
end

local function reportSourceTime()
  local position = tonumber(getExtStateValue("position"))
  clearRequest()
  if not position or position < 0 then
    setExtStateValue("result", "none|invalid-position|||")
    return
  end

  local record, reason = chooseFocusTrack(tracksWithAudioAtPosition(position))
  if not record then
    local status = reason == "separated" and "ambiguous-tracks" or reason
    setExtStateValue("result", "none|" .. safeResultField(status) .. "|||")
    return
  end

  local candidates, unsupported = sourceCandidatesOnTrack(record.track, position)
  local safeTrackName = safeResultField(record.name)
  if #candidates == 1 and #unsupported == 0 then
    local candidate = candidates[1]
    setExtStateValue(
      "result",
      string.format(
        "mapped|%.9f|%d|%s|%s|%.9f",
        candidate.time,
        record.number,
        safeTrackName,
        safeResultField(candidate.path),
        candidate.playRate
      )
    )
    return
  end
  if #candidates == 0 and #unsupported == 1 then
    setExtStateValue(
      "result",
      string.format(
        "none|%s|%d|%s|%s",
        safeResultField(unsupported[1].unsupported),
        record.number,
        safeTrackName,
        safeResultField(unsupported[1].path)
      )
    )
    return
  end

  setExtStateValue(
    "result",
    string.format(
      "ambiguous|%d|%d|%s|",
      #candidates + #unsupported,
      record.number,
      safeTrackName
    )
  )
end

local function main()
  local mode = getExtStateValue("mode")
  if mode == "region" then
    addPickupRegion()
  elseif mode == "focus_track" then
    focusTrack()
  elseif mode == "source_time" then
    reportSourceTime()
  else
    showError("No pending Script Sync request was found.")
  end
end

main()
