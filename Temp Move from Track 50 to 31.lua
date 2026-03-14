-- @description Move all items from track 50 to track 31
-- @author David Winter
-- @version 1.0

local proj = 0

-- User-configurable track numbers (as shown in REAPER, 1-based)
local SRC_TRACK_NUM  = 50
local DEST_TRACK_NUM = 31

-- Convert to 0-based indices for ReaScript API
local src_idx  = SRC_TRACK_NUM  - 1
local dest_idx = DEST_TRACK_NUM - 1

local src_track  = reaper.GetTrack(proj, src_idx)
local dest_track = reaper.GetTrack(proj, dest_idx)

if not src_track or not dest_track then
  reaper.ShowMessageBox(
    "Source or destination track does not exist.\n" ..
    "Source track: " .. tostring(SRC_TRACK_NUM) .. "\n" ..
    "Destination track: " .. tostring(DEST_TRACK_NUM),
    "Move Items Between Tracks",
    0
  )
  return
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- Count items on source track once at the start
local item_count = reaper.CountTrackMediaItems(src_track)

-- Iterate backwards so index remains valid when moving items
for i = item_count - 1, 0, -1 do
  local item = reaper.GetTrackMediaItem(src_track, i)
  if item then
    reaper.MoveMediaItemToTrack(item, dest_track)
  end
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Move all items from track " .. SRC_TRACK_NUM .. " to track " .. DEST_TRACK_NUM, -1)
