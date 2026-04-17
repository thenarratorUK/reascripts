-- @description Auto Split & Adjust Pre-FX Volume for Breaths
-- @version 1.0
-- @author David Winter
--[[
ReaScript Name: Auto Split & Adjust Pre-FX Volume for Breaths
Author: David Winter
Version: 1.0
Description:
    This script processes all items on the "Breath" (or "Breaths") track,
    splits the "Recording" (or "Recordings" or "Lorin") track at matching breath locations,
    measures the peak of each corresponding recording segment, 
    and applies a pre-FX volume envelope reduction to target -57 dB peak.

    - Skips applying volume reduction if the peak is already below -57 dB.
    - Deselects items between iterations to avoid selection errors.
    - Matches tracks by name, not position.

Instructions:
    - Ensure your project contains tracks named "Recording" / "Recordings" / "Lorin" and "Breath" / "Breaths".
    - Run the script. It processes all breath items and adjusts the recording track accordingly.
]]

local TARGET_PEAK = -43  -- Target peak level in dB

-- ✅ Function to find a track by name (case-insensitive matching)
local function find_track_by_name(allowed_names)
    local num_tracks = reaper.CountTracks(0)
    for i = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        local _, name = reaper.GetTrackName(track)
        name = name:lower()
        for _, allowed in ipairs(allowed_names) do
            if name == allowed:lower() then
                return track
            end
        end
    end
    return nil
end

-- ✅ Locate the required tracks
local recording_track = find_track_by_name({"recording", "Lorin", "recordings"})
local breath_track = find_track_by_name({"breath", "breaths"})

if not recording_track or not breath_track then
    reaper.ShowMessageBox("Could not find both 'Recording(s)/Lorin' and 'Breath(s)' tracks!", "Error", 0)
    return
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- ✅ Deselect everything to avoid context issues
reaper.Main_OnCommand(40289, 0)  -- Unselect all items

-- ✅ Process all breath items
local num_breath_items = reaper.CountTrackMediaItems(breath_track)

for i = 0, num_breath_items - 1 do
    local breath_item = reaper.GetTrackMediaItem(breath_track, i)
    if not breath_item then break end

    -- ✅ Get breath item position and length
    local start_time = reaper.GetMediaItemInfo_Value(breath_item, "D_POSITION")
    local end_time = start_time + reaper.GetMediaItemInfo_Value(breath_item, "D_LENGTH")

    -- ✅ Split the recording track at the start of the breath
    reaper.SetOnlyTrackSelected(recording_track)
    reaper.SetEditCurPos(start_time, false, false)
    reaper.Main_OnCommand(40757, 0) -- Split item at cursor

    -- ✅ Move cursor to breath end and split again
    reaper.SetEditCurPos(end_time, false, false)
    reaper.Main_OnCommand(43178, 0)  -- Select item left of cursor (the breath-matching split)

    -- ✅ Grab the selected recording item
    local sel_item = reaper.GetSelectedMediaItem(0, 0)
    if sel_item then
        local item_start = reaper.GetMediaItemInfo_Value(sel_item, "D_POSITION")
        local item_end = item_start + reaper.GetMediaItemInfo_Value(sel_item, "D_LENGTH")
        reaper.GetSet_LoopTimeRange(true, false, item_start, item_end, false)

        -- ✅ Activate the Volume (Pre-FX) Envelope on the recording track
        reaper.Main_OnCommand(41865, 0) -- Show/Select pre-FX volume envelope

        -- ✅ Insert 4 envelope points around the time selection
        reaper.Main_OnCommand(40726, 0) -- Insert 4 points (outer 2 original, inner 2 adjustable)

        -- ✅ Measure the peak of the recording segment
        local peak_db = reaper.NF_GetMediaItemMaxPeak(sel_item)

        -- ✅ Only apply volume reduction if peak is above target
        if peak_db > TARGET_PEAK then
            local difference = TARGET_PEAK - peak_db
            local rounded = difference >= 0 and math.floor(difference + 0.5) or math.ceil(difference - 0.5)

            -- ✅ Apply the volume nudge once per dB of reduction needed
            for n = 1, math.abs(rounded) do
                reaper.Main_OnCommand(41181, 0) -- Nudge envelope down a little bit
            end
        end
    end

    -- ✅ Clear selection before moving to the next item
    reaper.Main_OnCommand(40289, 0)  -- Unselect all items
end

reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Auto Adjust Pre-FX Volume for Breaths", -1)
reaper.UpdateArrange()
