-- @description Ripple Insert Start
-- @version 1.6
-- @author David Winter
--[[
  ReaScript Name: Ripple Insert Start
  Author: David Winter
  Version: 1.6
  Description: Splits the item under the edit cursor, inserts extended empty space from that position, clears the time selection, and begins recording. Also stores the insert start position in ExtState.
]]

-- Clear any placeholder previous-track context
do
  local PH_SECTION = "DW_RippleInsertPlaceholder"
  local PH_KEY_LAST_TRACK_GUID = "LastRecordedTrackGUID"
  reaper.DeleteExtState(PH_SECTION, PH_KEY_LAST_TRACK_GUID, false)
end

-- Begin undo block
reaper.Undo_BeginBlock()

-- Step 1: Split the item under the edit cursor
reaper.Main_OnCommand(40757, 0) -- Split item under edit cursor

-- Step 2: Capture current edit cursor position
local edit_cursor_pos = reaper.GetCursorPosition()

-- Save start position to ExtState for use in Ripple Insert End
reaper.SetExtState("RippleInsert", "InsertStartCursorPos", tostring(edit_cursor_pos), false)

-- Step 3: Define long-duration time selection for space insertion
local time_selection_end = edit_cursor_pos + 600 -- 10 minutes buffer
reaper.GetSet_LoopTimeRange(true, false, edit_cursor_pos, time_selection_end, false)

-- Step 4: Insert empty space across all tracks for the selection
reaper.Main_OnCommand(40200, 0)

-- Step 5: Clear time selection
reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)

-- Step 6: Begin recording
reaper.Main_OnCommand(1013, 0) -- Start recording

-- End undo block
reaper.Undo_EndBlock("Ripple Insert Start", -1)
