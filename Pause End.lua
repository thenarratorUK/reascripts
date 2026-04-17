-- @description Split item at start & end of time selection, then every 1ms, analyze peaks, save cursor position as "Pause_End", add a split, create a time selection between Pause_Start and Pause_End, enable Ripple Editing (All Tracks), remove contents of the time selection, restore the previous Ripple Editing state, and forget stored Pause_Start and Pause_End locations
-- @version 1.9
-- @author David Winter
-- @changelog Now removes the contents of the time selection (moving later items) instead of deleting individual items

reaper.Undo_BeginBlock()

reaper.SetExtState("MyScript", "Pause_End", "", false)

-- Store the current ripple editing state
local ripple_off_state = reaper.GetToggleCommandState(40309) -- Ripple Editing Off
local ripple_one_state = reaper.GetToggleCommandState(40310) -- Ripple Editing Per Track
local ripple_all_state = reaper.GetToggleCommandState(40311) -- Ripple Editing All Tracks

-- Get the selected track
local track = reaper.GetSelectedTrack(0, 0)
if not track then
    reaper.ShowMessageBox("No track selected!", "Error", 0)
    reaper.Undo_EndBlock("Failed to create Pause Region", -1)
    return
end

-- Get the time selection range
local start_time, end_time = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
if start_time == end_time then
    reaper.ShowMessageBox("No time selection found!", "Error", 0)
    reaper.Undo_EndBlock("Failed to create Pause Region", -1)
    return
end

-- Deselect all items before proceeding
reaper.Main_OnCommand(40289, 0) -- Unselect all items

local item_count = reaper.CountTrackMediaItems(track)
local middle_item = nil

-- First, split at the start and end
for i = item_count - 1, 0, -1 do  
    local item = reaper.GetTrackMediaItem(track, i)
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = item_start + item_length

    -- Check if the item overlaps with the time selection
    if item_end > start_time and item_start < end_time then
        -- Split at the end time
        if item_start < end_time and item_end > end_time then
            reaper.SplitMediaItem(item, end_time)
        end

        -- Split at the start time
        if item_start < start_time and item_end > start_time then
            middle_item = reaper.SplitMediaItem(item, start_time)
        end
    end
end

-- Ensure we have the middle section to work with
if middle_item then
    reaper.SetMediaItemSelected(middle_item, true)

    local current_pos = start_time + 0.001 -- Start 1ms after the start time
    local split_items = {}

    -- Track the last split item (since each split creates a new item)
    local last_split_item = middle_item

    -- Move forward in 1ms increments and split
    while current_pos < end_time do
        local new_item = reaper.SplitMediaItem(last_split_item, current_pos)
        if new_item then
            table.insert(split_items, new_item)
            last_split_item = new_item -- Update reference to the newly created item
        end
        current_pos = current_pos + 0.001 -- Move forward by 1ms
    end

    -- Measure peak levels and check for 10 consecutive peaks > -50dB
    local consecutive_count = 0
    local first_of_ten_pos = nil

    for _, item in ipairs(split_items) do
        local peak_db = reaper.NF_GetMediaItemMaxPeak(item)
        local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")

        -- Check if the peak is greater than -50 dB
        if peak_db > -50 then
            consecutive_count = consecutive_count + 1
            -- Store the first peak's time in the 10-peak sequence
            if consecutive_count == 1 then
                first_of_ten_pos = item_start
            end
        else
            consecutive_count = 0 -- Reset counter if there's an interruption
            first_of_ten_pos = nil -- Reset first peak time
        end

        -- If we reach 10 consecutive times, move the cursor to the first peak
        if consecutive_count >= 10 then
            break
        end
    end

    -- Move edit cursor if a valid position is found
    if first_of_ten_pos then
        local adjusted_cursor_position = first_of_ten_pos -- Cursor does not move

        -- Undo all splits (restoring original item)
        reaper.Undo_EndBlock("Undo All Splits", -1) 
        reaper.Undo_DoUndo2(0) -- Perform undo to remove all splits

        -- Save the cursor position as "Pause_End"
        reaper.SetExtState("MyScript", "Pause_End", tostring(adjusted_cursor_position), true)

        -- Add a split at the detected position
        for i = 0, reaper.CountTrackMediaItems(track) - 1 do
            local item = reaper.GetTrackMediaItem(track, i)
            local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local item_end = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

            -- Split at the detected position if within item range
            if item_start < adjusted_cursor_position and item_end > adjusted_cursor_position then
                reaper.SplitMediaItem(item, adjusted_cursor_position)
            end
        end

        -- Retrieve "Pause_Start" position
        local pause_start_pos = reaper.GetExtState("MyScript", "Pause_Start")
        if pause_start_pos == "" then
            reaper.ShowMessageBox("Pause_Start position not found. Cannot create time selection.", "Error", 0)
            return
        end

        -- Convert to number and create time selection
        local pause_start_num = tonumber(pause_start_pos)
        reaper.GetSet_LoopTimeRange(true, false, pause_start_num, adjusted_cursor_position, false)

        -- Enable Ripple Editing (All Tracks)
        reaper.Main_OnCommand(40311, 0)

        -- Ensure the current track is selected
        reaper.SetTrackSelected(track, true)

        -- Run command 40201: Remove contents of the time selection (moving later items)
        reaper.Main_OnCommand(40201, 0)

        -- Restore the saved Ripple Editing state
        if ripple_off_state == 1 then
            reaper.Main_OnCommand(40309, 0) -- Turn off Ripple Editing
        elseif ripple_one_state == 1 then
            reaper.Main_OnCommand(40310, 0) -- Set Ripple Editing to One Track
        elseif ripple_all_state == 1 then
            reaper.Main_OnCommand(40311, 0) -- Set Ripple Editing to All Tracks
        end

        -- Forget stored Pause_Start and Pause_End locations
        reaper.SetExtState("MyScript", "Pause_Start", "", false)
        reaper.SetExtState("MyScript", "Pause_End", "", false)

    else
        -- Undo all splits even if no valid section was found
        reaper.Undo_EndBlock("Undo All Splits", -1) 
        reaper.Undo_DoUndo2(0) 

        -- Show error if no valid peak sequence was found
        reaper.ShowMessageBox("No valid section with 10 consecutive peaks > -50dB found.", "Error", 0)
    end

else
    reaper.ShowMessageBox("No valid item found between the splits.", "Error", 0)
end

reaper.Undo_EndBlock("Split, Analyze, Save Pause_End, Create Selection, Enable Ripple, Remove Time Selection Contents, Restore Ripple, and Forget Pause Locations", -1)

