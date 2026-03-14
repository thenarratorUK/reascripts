-- @description Ripple Insert End
-- @version 3.2
-- @author David Winter

------------------------------------------------------------
-- Config
------------------------------------------------------------

local ROOM_TONE_NAME = "Room Tone"  -- exact track name to use

------------------------------------------------------------
-- Section A: Setup and transport control
------------------------------------------------------------

-- Begin undo block
reaper.Undo_BeginBlock()

-- Pause and stop transport
reaper.Main_OnCommand(1008, 0)  -- Transport: Pause
reaper.Main_OnCommand(1016, 0)  -- Transport: Stop

-- Store current ripple edit state
local ripple_off_state = reaper.GetToggleCommandState(40309)
local ripple_one_state = reaper.GetToggleCommandState(40310)
local ripple_all_state = reaper.GetToggleCommandState(40311)

------------------------------------------------------------
-- Section B: Determine end of the just-recorded item
------------------------------------------------------------

local cursor_pos = reaper.GetCursorPosition()
local sel_track  = reaper.GetSelectedTrack(0, 0)

if not sel_track then
  reaper.ShowMessageBox("No track selected for Ripple Insert End.", "Error", 0)
  reaper.Undo_EndBlock("Ripple Insert End (All Armed Tracks)", -1)
  return
end

-- Find the item on the selected track whose end is the latest
-- but still <= cursor_pos
local num_items_on_sel = reaper.CountTrackMediaItems(sel_track)
local record_end = nil

for i = 0, num_items_on_sel - 1 do
  local item   = reaper.GetTrackMediaItem(sel_track, i)
  local pos    = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len    = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local endPos = pos + len

  if endPos <= cursor_pos and (not record_end or endPos > record_end) then
    record_end = endPos
  end
end

-- Fallback: if no such item is found, use the cursor position
if not record_end then
  record_end = cursor_pos
end

------------------------------------------------------------
-- Section C: Basic safety – ensure at least one armed track
------------------------------------------------------------

local armed_tracks = {}
local num_tracks = reaper.CountTracks(0)
for i = 0, num_tracks - 1 do
  local tr = reaper.GetTrack(0, i)
  if reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 then
    table.insert(armed_tracks, tr)
  end
end

if #armed_tracks == 0 then
  reaper.ShowMessageBox("No armed tracks found.", "Error", 0)
  reaper.Undo_EndBlock("Ripple Insert End (All Armed Tracks)", -1)
  return
end

------------------------------------------------------------
-- Section D: Close the gap to the next item using 40201
------------------------------------------------------------

-- Find the first item on ANY track that starts after record_end
local next_item_start = nil
local total_items = reaper.CountMediaItems(0)

for i = 0, total_items - 1 do
  local item = reaper.GetMediaItem(0, i)
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")

  if item_start > record_end then
    if not next_item_start or item_start < next_item_start then
      next_item_start = item_start
    end
  end
end

-- If we found a later item, remove the time in between on all tracks
if next_item_start and next_item_start > record_end then
  -- Time selection [record_end, next_item_start]
  reaper.GetSet_LoopTimeRange(true, false, record_end, next_item_start, false)

  -- Time selection: Remove contents of time selection (moving later items)
  reaper.Main_OnCommand(40201, 0)
end

------------------------------------------------------------
-- Section E: Close the room tone gap between insert start and record_end
------------------------------------------------------------

-- Clear time selection for this section
reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)

-- Recover insert start from Ripple Insert Start
local start_pos_str = reaper.GetExtState("RippleInsert", "InsertStartCursorPos")
local insert_start_pos = tonumber(start_pos_str or "")

if insert_start_pos and record_end and record_end > insert_start_pos then
  -- Find the Room Tone track by name
  local room_tone_track = nil
  for i = 0, num_tracks - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if name == ROOM_TONE_NAME then
      room_tone_track = tr
      break
    end
  end

  if room_tone_track then
    -- Set ripple editing to one track (we'll restore global state later)
    reaper.Main_OnCommand(40310, 0)  -- Ripple: One track

    -- Select only the Room Tone track
    for i = 0, num_tracks - 1 do
      local tr = reaper.GetTrack(0, i)
      reaper.SetTrackSelected(tr, tr == room_tone_track)
    end

    -- Define time selection for room tone span we want to close
    local rt_start = insert_start_pos
    local rt_end   = record_end

    reaper.GetSet_LoopTimeRange(true, false, rt_start, rt_end, false)

    -- Create an empty item covering [rt_start, rt_end] on the room tone track
    local rt_item = reaper.AddMediaItemToTrack(room_tone_track)
    if rt_item then
      reaper.SetMediaItemInfo_Value(rt_item, "D_POSITION", rt_start)
      reaper.SetMediaItemInfo_Value(rt_item, "D_LENGTH",  rt_end - rt_start)

      -- Deselect all items, then select just this item
      reaper.Main_OnCommand(40289, 0)  -- Deselect all items
      reaper.SetMediaItemSelected(rt_item, true)

      -- Delete the empty item with ripple-one-track, closing the gap
      reaper.Main_OnCommand(40006, 0)  -- Item: Remove items
    end
  end
end

------------------------------------------------------------
-- Section F: Cursor, track selection, time selection and ripple restore
------------------------------------------------------------

-- Move the edit cursor to the end of the just-recorded item
reaper.SetEditCurPos(record_end, true, false)  -- move view, do not seek playback

-- Clear time selection
reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)

-- Reselect the originally recorded track
if sel_track then
  for i = 0, num_tracks - 1 do
    local tr = reaper.GetTrack(0, i)
    reaper.SetTrackSelected(tr, tr == sel_track)
  end
end

-- Restore ripple edit state
if ripple_off_state == 1 then
  reaper.Main_OnCommand(40309, 0)  -- Ripple off
elseif ripple_one_state == 1 then
  reaper.Main_OnCommand(40310, 0)  -- Ripple one-track
elseif ripple_all_state == 1 then
  reaper.Main_OnCommand(40311, 0)  -- Ripple all tracks
end

------------------------------------------------------------
-- Section G: Store punch-out position and end undo block
------------------------------------------------------------

-- Store current edit cursor position as punch-out marker
reaper.SetExtState("RippleInsert", "InsertEndCursorPos", tostring(reaper.GetCursorPosition()), false)

-- End undo block (name preserved)
reaper.Undo_EndBlock("Ripple Insert End (All Armed Tracks)", -1)
