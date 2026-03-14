--[[
ReaScript Name: Track Item / Rejected / Active Take Summary
Author: David Winter (generated with ChatGPT)
Version: 1.0

What it does (per track):
(A) Track name
(B) Total media items
(C) Items with a custom item colour set (treated as "rejected")
(D) Among the remainder (uncoloured), how many have Take 1 active
(E) Among the remainder (uncoloured), how many have Take 2 active

Notes:
- "Coloured" means the item has a custom colour (I_CUSTOMCOLOR ~= 0).
- If an item has only one take, it will count as Take 1 active.
- Items with active takes beyond Take 2 are ignored for D/E (as requested).
]]

local function msg(s)
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
end

reaper.ClearConsole()

local proj = 0
local track_count = reaper.CountTracks(proj)

if track_count == 0 then
  msg("No tracks in project.")
  return
end

reaper.PreventUIRefresh(1)

for t = 0, track_count - 1 do
  local track = reaper.GetTrack(proj, t)

  local _, track_name = reaper.GetTrackName(track, "")
  if not track_name or track_name == "" then
    track_name = ("Track %d"):format(t + 1)
  end

  local total_items = 0
  local coloured_items = 0
  local take1_used = 0
  local take2_used = 0

  local item_count = reaper.CountTrackMediaItems(track)

  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    total_items = total_items + 1

    local custom_col = reaper.GetMediaItemInfo_Value(item, "I_CUSTOMCOLOR")

    if custom_col ~= 0 then
      -- Treated as "rejected"
      coloured_items = coloured_items + 1
    else
      -- Remainder: count active take 1 / take 2
      local active_take = reaper.GetActiveTake(item)
      if active_take then
        local num_takes = reaper.GetMediaItemNumTakes(item)

        -- Determine active take index by pointer equality
        local active_idx = -1
        for k = 0, num_takes - 1 do
          local tk = reaper.GetMediaItemTake(item, k)
          if tk == active_take then
            active_idx = k
            break
          end
        end

        if active_idx == 0 then
          take1_used = take1_used + 1
        elseif active_idx == 1 then
          take2_used = take2_used + 1
        end
      end
    end
  end

  msg(("%s - Total Items: %d, of which %d rejected. Take 1 used: %d; Take 2 used: %d.")
    :format(track_name, total_items, coloured_items, take1_used, take2_used))
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
