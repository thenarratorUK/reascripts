-- @description Toggle Mute for Tracks Named "Live"
-- @version 1.0
-- @author David Winter
--[[
  ReaScript Name: Toggle Mute for Tracks Named "Live"
  Author: David Winter
  Version: 1.0
  Description: Toggles the mute state for any track named "Live".
]]

-- Step 1: Loop through all tracks in the project
local num_tracks = reaper.CountTracks(0) -- Get the total number of tracks

for i = 0, num_tracks - 1 do
    local track = reaper.GetTrack(0, i) -- Get track by index
    if track then
        -- Step 2: Check if the track name is "Live"
        local retval, track_name = reaper.GetTrackName(track, "")
        if retval and track_name == "Live" then
            -- Step 3: Toggle mute state
            local mute_state = reaper.GetMediaTrackInfo_Value(track, "B_MUTE") -- Get current mute state
            reaper.SetMediaTrackInfo_Value(track, "B_MUTE", mute_state == 0 and 1 or 0) -- Toggle mute
        end
    end
end

