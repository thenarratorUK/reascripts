-- @description Auto Split & Adjust Pre-FX Volume for Breaths
-- @version 1.3
-- @author David Winter
--[[
ReaScript Name: Auto Split & Adjust Pre-FX Volume for Breaths
Author: David Winter
Version: 1.3 (multitrack-aware)
Description:
    This script processes all items on the "Breath" (or "Breaths") track,
    finds the corresponding audio track that actually has material at that time
    (excluding Room Tone), splits that track at matching breath locations,
    measures the peak of each corresponding segment,
    and applies a pre-FX volume envelope reduction to target -57 dB peak.

    - Skips applying volume reduction if the peak is already below -57 dB.
    - Deselects items between iterations to avoid selection errors.
    - Matches the Breaths track by name.
    - For each breath, finds the overlapping audio track; falls back to a
      default "Recording"/"Narration"/"David" track if needed.
]]

local TARGET_PEAK = -57  -- Target peak level in dB

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
local breath_track              = find_track_by_name({"breath", "breaths"})
local default_recording_track   = find_track_by_name({"recording", "david", "recordings", "narration"})

if not breath_track then
    reaper.ShowMessageBox("Could not find 'Breath(s)' track!", "Error", 0)
    return
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- helper: detect Room Tone track(s) so we can ignore them when searching for audio
local function is_room_tone_track(track)
    local _, name = reaper.GetTrackName(track, "")
    name = (name or ""):lower()
    if name:find("room tone") then
        return true
    end
    return false
end

-- helper: find the target audio track for a given breath item
-- looks for any track (except Breaths and Room Tone) that has an item overlapping [start_time, end_time]
-- if none is found, falls back to default_recording_track (if defined)
local function find_target_track_for_breath(start_time, end_time, breaths_track)
    local num_tracks = reaper.CountTracks(0)

    for t = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, t)
        if track ~= breaths_track and not is_room_tone_track(track) then
            local item_count = reaper.CountTrackMediaItems(track)
            for i = 0, item_count - 1 do
                local it = reaper.GetTrackMediaItem(track, i)
                local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
                local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
                local it_start = pos
                local it_end   = pos + len
                -- simple overlap test
                if it_end > start_time and it_start < end_time then
                    return track
                end
            end
        end
    end

    return default_recording_track
end

-- ✅ Deselect everything to avoid context issues
reaper.Main_OnCommand(40289, 0)  -- Unselect all items

-- helper: dB <-> linear (kept in case needed later)
local function dbToVal(db)  return 10^(db/20) end
local function valToDb(val)
    if val <= 0 then return -150 end
    return 20*math.log10(val)
end

-- helper: evaluate envelope value at time
local function envValAt(env, t)
    local _, value = reaper.Envelope_Evaluate(env, t, 0, 0)
    return value
end

-- helper: find index of a point at a given time
local function findPointAtTime(env, t)
    local cnt = reaper.CountEnvelopePoints(env)
    local eps = 1e-7
    for i = 0, cnt - 1 do
        local ok, time = reaper.GetEnvelopePoint(env, i)
        if ok and math.abs(time - t) < eps then
            return i
        end
    end
    return nil
end

-- helper: set shape/selection without moving point
local function setPointProps(env, idx, shape, selected)
    local ok, time, value, oldShape, tension, oldSel = reaper.GetEnvelopePoint(env, idx)
    if ok then
        if shape == nil   then shape   = oldShape end
        if selected == nil then selected = oldSel end
        reaper.SetEnvelopePoint(env, idx, time, value, shape, tension, selected, true)
    end
end

-- ✅ Process all breath items
local num_breath_items = reaper.CountTrackMediaItems(breath_track)

for i = 0, num_breath_items - 1 do
    local breath_item = reaper.GetTrackMediaItem(breath_track, i)
    if not breath_item then break end

    -- ✅ Get breath item position and length
    local start_time = reaper.GetMediaItemInfo_Value(breath_item, "D_POSITION")
    local end_time   = start_time + reaper.GetMediaItemInfo_Value(breath_item, "D_LENGTH")

    -- ✅ Find the target audio track at this time and split it at the start of the breath
    local target_track = find_target_track_for_breath(start_time, end_time, breath_track)
    if target_track then
    reaper.SetOnlyTrackSelected(target_track)
    reaper.SetEditCurPos(start_time, false, false)
    reaper.Main_OnCommand(40757, 0) -- Split item at cursor

    -- ✅ Move cursor to breath end and split again
    reaper.SetEditCurPos(end_time, false, false)
    reaper.Main_OnCommand(43178, 0)  -- Select item left of cursor (the breath-matching split)

    -- ✅ Grab the selected recording item
    local sel_item = reaper.GetSelectedMediaItem(0, 0)
    if sel_item then
        local item_start = reaper.GetMediaItemInfo_Value(sel_item, "D_POSITION")
        local item_end   = item_start + reaper.GetMediaItemInfo_Value(sel_item, "D_LENGTH")
        local item_len   = item_end - item_start

        reaper.GetSet_LoopTimeRange(true, false, item_start, item_end, false)

        -- ✅ Activate the Volume (Pre-FX) Envelope on the selected track
        reaper.Main_OnCommand(41865, 0) -- Show/Select pre-FX volume envelope

        local env = reaper.GetSelectedEnvelope(0)
        if env then
            -- times at 0%, 10%, 90%, 100% of item
            local t1 = item_start - 0.05 * item_len
            local t2 = item_start + 0.10 * item_len
            local t3 = item_start + 0.90 * item_len
            local t4 = item_end + 0.05 * item_len

            -- Ensure there are envelope points at t1, t2, t3, t4
            local idx1 = findPointAtTime(env, t1)
            if not idx1 then
                local v = envValAt(env, t1)
                reaper.InsertEnvelopePoint(env, t1, v, 2, 0, false, true) -- shape=2
                idx1 = findPointAtTime(env, t1)
            end

            local idx2 = findPointAtTime(env, t2)
            if not idx2 then
                local v = envValAt(env, t2)
                reaper.InsertEnvelopePoint(env, t2, v, 0, 0, false, true)
                idx2 = findPointAtTime(env, t2)
            end

            local idx3 = findPointAtTime(env, t3)
            if not idx3 then
                local v = envValAt(env, t3)
                reaper.InsertEnvelopePoint(env, t3, v, 2, 0, false, true) -- shape=2
                idx3 = findPointAtTime(env, t3)
            end

            local idx4 = findPointAtTime(env, t4)
            if not idx4 then
                local v = envValAt(env, t4)
                reaper.InsertEnvelopePoint(env, t4, v, 0, 0, false, true)
                idx4 = findPointAtTime(env, t4)
            end

            -- Deselect all points, then select only the two middle points (10% and 90%)
            local total = reaper.CountEnvelopePoints(env)
            for p = 0, total - 1 do
                setPointProps(env, p, nil, false)
            end

            if idx2 then setPointProps(env, idx2, nil, true) end
            if idx3 then setPointProps(env, idx3, nil, true) end

            reaper.Envelope_SortPoints(env)
        end

        -- ✅ Measure the peak of the recording segment
        local peak_db = reaper.NF_GetMediaItemMaxPeak(sel_item)

        if peak_db > TARGET_PEAK then
            local needed = peak_db - TARGET_PEAK  -- how many dB reduction needed
            local rounded = math.floor(needed + 0.5)

            -- ✅ Apply the volume nudge once per dB of reduction needed
            for n = 1, math.abs(rounded) do
                reaper.Main_OnCommand(41181, 0) -- Nudge envelope down a little bit
            end
        end
    end
    end

    -- ✅ Clear selection before moving to the next item
    reaper.Main_OnCommand(40289, 0)  -- Unselect all items
end

reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Auto Adjust Pre-FX Volume for Breaths", -1)
reaper.UpdateArrange()
