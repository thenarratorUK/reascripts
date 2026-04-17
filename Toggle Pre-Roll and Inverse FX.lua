-- @description Toggle Pre-roll and Handle FX on Track 1 and Any Track Named "Live"
-- @version 1.7
-- @author David Winter
--[[
  ReaScript Name: Toggle Pre-roll and Handle FX on Track 1 and Any Track Named "Live"
  Author: David Winter
  Version: 1.7
  Description: Toggles Pre-roll on Record. If off, enables Pre-roll and bypasses FX on Track 1 and any track named "Live" except "pureLimit", "smartLimit", or "ReaLimit". If on, disables Pre-roll and un-bypasses all FX on Track 1 and any track named "Live".
]]

-- Step 1: Get the current state of Pre-roll on Record
local pre_roll_state = reaper.GetToggleCommandState(41819) -- 41819: Pre-roll: Toggle Pre-roll on record

-- Step 2: Define a function to process FX on a specific track
local function process_fx_on_track(track, bypass, exceptions)
    if not track then return end -- Exit if the track is invalid

    -- Loop through all FX on the track
    local num_fx = reaper.TrackFX_GetCount(track)
    for i = 0, num_fx - 1 do
        -- Get the FX name
        local retval, fx_name = reaper.TrackFX_GetFXName(track, i, "")
        
        if fx_name ~= nil then
            if bypass then
                -- If bypassing FX, check if FX is NOT in the exception list
                if not (
                    fx_name:find(exceptions[1]) or
                    fx_name:find(exceptions[2]) or
                    fx_name:find(exceptions[3])
                ) then
                    reaper.TrackFX_SetEnabled(track, i, false) -- Disable FX
                end
            else
                -- If un-bypassing FX, enable all FX
                reaper.TrackFX_SetEnabled(track, i, true) -- Enable FX
            end
        end
    end
end

-- Step 3: Define the list of exceptions
local exceptions = {"pureLimit", "smartLimit", "ReaLimit"}

-- Step 4: Toggle Pre-roll and process tracks
if pre_roll_state == 0 then
    -- If Pre-roll is off
    reaper.Main_OnCommand(41819, 0) -- Enable Pre-roll on record
    
    -- Process Track 1 to bypass FX (with exceptions)
    local track1 = reaper.GetTrack(0, 0) -- Track 1 (0-based index)
    process_fx_on_track(track1, true, exceptions)
    
    -- Process any track named "Live"
    local num_tracks = reaper.CountTracks(0) -- Get total number of tracks
    for i = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        if track then
            local retval, track_name = reaper.GetTrackName(track, "")
            if retval and track_name == "Live" then
                process_fx_on_track(track, true, exceptions)
            end
        end
    end
else
    -- If Pre-roll is on
    reaper.Main_OnCommand(41819, 0) -- Disable Pre-roll on record
    
    -- Process Track 1 to un-bypass all FX
    local track1 = reaper.GetTrack(0, 0) -- Track 1 (0-based index)
    process_fx_on_track(track1, false, exceptions)
    
    -- Process any track named "Live"
    local num_tracks = reaper.CountTracks(0) -- Get total number of tracks
    for i = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        if track then
            local retval, track_name = reaper.GetTrackName(track, "")
            if retval and track_name == "Live" then
                process_fx_on_track(track, false, exceptions)
            end
        end
    end
end

