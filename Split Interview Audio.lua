-- @description Mutually exclusive comp: mute Track 1 wherever Track 2 has items
-- @version 1.1
-- @author David Winter
-- ReaScript Name: Mutually exclusive comp: mute Track 1 wherever Track 2 has items
-- Description:
--   1) Collects all item intervals on Track 2 (merging overlaps/touches)
--   2) Splits Track 1 items at every start/end boundary of those intervals
--   3) Mutes the Track 1 segments that lie within those intervals (no deletions)
-- Author: David Winter
-- Version: 1.1

-- Optional: set true to unmute all Track 1 items before applying mutes
local RESET_MUTES_ON_TRACK1 = false

local EPS = 1e-9

local function get_track(idx0based)
  return reaper.GetTrack(0, idx0based)
end

local function get_item_bounds(item)
  local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return pos, pos + len
end

-- Gather and merge intervals from Track 2 items
local function collect_merged_intervals_from_track(track)
  local intervals = {}
  local cnt = reaper.CountTrackMediaItems(track)
  for i = 0, cnt-1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local s, e = get_item_bounds(it)
    intervals[#intervals+1] = {s=s, e=e}
  end
  table.sort(intervals, function(a,b) return a.s < b.s end)
  local merged = {}
  for _, iv in ipairs(intervals) do
    if #merged == 0 then
      merged[1] = {s = iv.s, e = iv.e}
    else
      local last = merged[#merged]
      if iv.s <= last.e + EPS then
        if iv.e > last.e then last.e = iv.e end
      else
        merged[#merged+1] = {s = iv.s, e = iv.e}
      end
    end
  end
  return merged
end

-- Split all items on a track at time t
local function split_track_items_at_time(track, t)
  local n = reaper.CountTrackMediaItems(track)
  for i = n-1, 0, -1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local s, e = get_item_bounds(it)
    if s + EPS < t and e - EPS > t then
      reaper.SplitMediaItem(it, t)
    end
  end
end

local function make_boundaries(intervals)
  local b = {}
  for _, iv in ipairs(intervals) do
    b[#b+1] = iv.s
    b[#b+1] = iv.e
  end
  table.sort(b)
  return b
end

local function within_any_interval(s, e, intervals)
  for _, iv in ipairs(intervals) do
    if s >= iv.s - EPS and e <= iv.e + EPS then
      return true
    end
    if iv.s > e + EPS then
      return false
    end
  end
  return false
end

-- MAIN
reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local track1 = get_track(0)  -- Track 1 (0-based)
local track2 = get_track(1)  -- Track 2 (0-based)

if not track1 or not track2 then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Mute Track 1 where Track 2 has items (ABORT: missing tracks)", -1)
  reaper.ShowMessageBox("This script expects Track 1 and Track 2 to exist.", "Error", 0)
  return
end

-- 1) Intervals from Track 2
local intervals = collect_merged_intervals_from_track(track2)
if #intervals == 0 then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Mute Track 1 where Track 2 has items (no items on Track 2)", -1)
  return
end

-- 2) Split Track 1 at all interval boundaries
local boundaries = make_boundaries(intervals)
for _, t in ipairs(boundaries) do
  split_track_items_at_time(track1, t)
end

-- Optional reset: unmute all Track 1 items first
if RESET_MUTES_ON_TRACK1 then
  local n = reaper.CountTrackMediaItems(track1)
  for i = 0, n-1 do
    local it = reaper.GetTrackMediaItem(track1, i)
    reaper.SetMediaItemInfo_Value(it, "B_MUTE", 0)
  end
end

-- 3) Mute Track 1 segments that lie fully inside any Track 2 interval
local n1 = reaper.CountTrackMediaItems(track1)
for i = 0, n1-1 do
  local it = reaper.GetTrackMediaItem(track1, i)
  local s, e = get_item_bounds(it)
  if within_any_interval(s, e, intervals) then
    reaper.SetMediaItemInfo_Value(it, "B_MUTE", 1) -- mute item
  end
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Mute Track 1 where Track 2 has items", -1)
