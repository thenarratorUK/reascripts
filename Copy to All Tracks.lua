-- Duplicate all items from the first track to all other existing tracks
reaper.Undo_BeginBlock()

local first_track = reaper.GetTrack(0, 0)
if not first_track then
  reaper.ShowMessageBox("There are no tracks in the project.", "Error", 0)
  return
end

local num_tracks = reaper.CountTracks(0)
local num_items = reaper.CountTrackMediaItems(first_track)

-- Collect all item data from first track
local item_data = {}
for i = 0, num_items - 1 do
  local item = reaper.GetTrackMediaItem(first_track, i)
  local take = reaper.GetActiveTake(item)
  if take and not reaper.TakeIsMIDI(take) then
    local src = reaper.GetMediaItemTake_Source(take)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    table.insert(item_data, {src = src, pos = pos, len = len, offset = offset})
  end
end

-- Place those items on all other tracks
for t = 1, num_tracks - 1 do
  local dest_track = reaper.GetTrack(0, t)
  for _, data in ipairs(item_data) do
    local new_item = reaper.AddMediaItemToTrack(dest_track)
    reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", data.pos)
    reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", data.len)

    local new_take = reaper.AddTakeToMediaItem(new_item)
    reaper.SetMediaItemTake_Source(new_take, data.src)
    reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", data.offset)

    reaper.SetMediaItemInfo_Value(new_item, "B_LOOPSRC", 1)
    reaper.SetMediaItemSelected(new_item, false)
  end
end

reaper.UpdateArrange()
reaper.Undo_EndBlock("Duplicate items from Track 1 to all other tracks", -1)
