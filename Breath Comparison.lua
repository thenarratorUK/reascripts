-- @description Breath Comparison
-- @version 1.0
-- @author David Winter
--[[
  Breath Check Snapshot + Comparison (Console Version)
  Author: David Winter
  Version: 1.4

  Description:
  - On first run, saves snapshot of Breath track items ("Before")
  - On second run, saves "After" state, compares to Before, and shows deleted items
  - Uses floating point tolerance for matching item start/length
  - Outputs individual deleted items and full stats to ReaScript console
  - No popups or modals
]]

local EXT_NAMESPACE = "BreathCheck"
local TOLERANCE = 0.0001

local function getBreathTrack()
  local valid = {["breath"]=true,["breaths"]=true,["breathe"]=true,["breathes"]=true}
  for i = 0, reaper.CountTracks(0)-1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if name and valid[name:lower()] then return tr end
  end
  return nil
end

local function getMaxVolume(item)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return -999 end
  local accessor = reaper.CreateTakeAudioAccessor(take)
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local samplerate = 44100
  local samples = math.floor(len * samplerate)
  local buffer = reaper.new_array(samples)
  reaper.GetAudioAccessorSamples(accessor, samplerate, 1, 0, samples, buffer)
  local peak = 0
  for i = 1, samples do peak = math.max(peak, math.abs(buffer[i])) end
  reaper.DestroyAudioAccessor(accessor)
  return peak > 0 and 20 * math.log(peak) / math.log(10) or -999
end

local function collectBreathData(track)
  local data = {}
  for i = 0, reaper.CountTrackMediaItems(track)-1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local dur_ms = math.floor(len * 1000 + 0.5)
    local max_vol = getMaxVolume(item)
    data[#data+1] = {pos=pos, len=len, dur=dur_ms, vol=max_vol}
  end
  return data
end

local function serialize(data)
  local out = {}
  for _, v in ipairs(data) do
    out[#out+1] = string.format("%.8f,%.8f,%d,%.2f", v.pos, v.len, v.dur, v.vol)
  end
  return table.concat(out, "\n")
end

local function deserialize(str)
  local out = {}
  for line in str:gmatch("[^\r\n]+") do
    local pos, len, dur, vol = line:match("([^,]+),([^,]+),([^,]+),([^,]+)")
    out[#out+1] = {pos=tonumber(pos), len=tonumber(len), dur=tonumber(dur), vol=tonumber(vol)}
  end
  return out
end

local function itemsMatch(a, b)
  return math.abs(a.pos - b.pos) < TOLERANCE and math.abs(a.len - b.len) < TOLERANCE
end

local function compareItems(before, after)
  local deleted, kept = {}, {}
  for _, b in ipairs(before) do
    local found = false
    for _, a in ipairs(after) do
      if itemsMatch(a, b) then
        found = true
        break
      end
    end
    if found then
      kept[#kept+1] = b
    else
      deleted[#deleted+1] = b
    end
  end
  return deleted, kept
end

local function calculateStats(list)
  if #list == 0 then
    return {dur_avg=0, dur_min=0, dur_max=0, vol_avg=0, vol_min=0, vol_max=0}
  end

  local dur_sum, vol_sum = 0, 0
  local dur_min, dur_max = list[1].dur, list[1].dur
  local vol_min, vol_max = list[1].vol, list[1].vol

  for _, item in ipairs(list) do
    dur_sum = dur_sum + item.dur
    vol_sum = vol_sum + item.vol
    dur_min = math.min(dur_min, item.dur)
    dur_max = math.max(dur_max, item.dur)
    vol_min = math.min(vol_min, item.vol)
    vol_max = math.max(vol_max, item.vol)
  end

  return {
    dur_avg = dur_sum / #list,
    dur_min = dur_min,
    dur_max = dur_max,
    vol_avg = vol_sum / #list,
    vol_min = vol_min,
    vol_max = vol_max
  }
end

local function showResults(deleted, kept)
  reaper.ClearConsole()
  local function p(msg) reaper.ShowConsoleMsg(msg .. "\n") end

  if #deleted == 0 then
    p("No breaths were removed since the last snapshot.")
  else
    p("Deleted Breath Items: " .. #deleted)
    p("Duration (ms)\tMax Vol (dBFS)")
    p(string.rep("-", 34))
    for _, item in ipairs(deleted) do
      p(string.format("%d\t\t%.2f", item.dur, item.vol))
    end
  end

  p("\nStats for Deleted Breaths:")
  local d = calculateStats(deleted)
  p(string.format("Duration (ms) - Avg: %.1f   Min: %d   Max: %d", d.dur_avg, d.dur_min, d.dur_max))
  p(string.format("Max Volume    - Avg: %.2f   Min: %.2f   Max: %.2f", d.vol_avg, d.vol_min, d.vol_max))

  p("\nStats for Kept Breaths:")
  local k = calculateStats(kept)
  p(string.format("Duration (ms) - Avg: %.1f   Min: %d   Max: %d", k.dur_avg, k.dur_min, k.dur_max))
  p(string.format("Max Volume    - Avg: %.2f   Min: %.2f   Max: %.2f", k.vol_avg, k.vol_min, k.vol_max))
end

-- === MAIN ===

local track = getBreathTrack()
if not track then
  reaper.ShowConsoleMsg("No valid 'Breath' track found.\n")
  return
end

local choice = reaper.MB("Choose Snapshot Type:\n\nYES = Before checking\nNO = After checking", "Breath Check", 3)
if choice == 2 then return end

local label = (choice == 6) and "Before" or "After"
local data = collectBreathData(track)
reaper.SetProjExtState(0, EXT_NAMESPACE, label, serialize(data))

if label == "After" then
  local ok, before_str = reaper.GetProjExtState(0, EXT_NAMESPACE, "Before")
  if ok ~= 1 or before_str == "" then
    reaper.ShowConsoleMsg("No 'Before' snapshot found. Please run this script as 'Before' first.\n")
    return
  end
  local before = deserialize(before_str)
  local deleted, kept = compareItems(before, data)
  showResults(deleted, kept)
else
end
