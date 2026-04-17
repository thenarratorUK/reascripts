-- @description Ultra-Fast Peak Detection & Cleanup
-- @version 1.0
-- @author David Winter
--[[
ReaScript Name: Ultra-Fast Peak Detection & Cleanup
Description: Processes all items in the selected track, colors those with peaks between -18dB and -35dB orange, and deletes all others.
]]--

-- Define dB range
local PEAK_MIN = -32
local PEAK_MAX = -16
local ORANGE_COLOR = reaper.ColorToNative(255, 165, 0) | 0x1000000

-- Get the selected track
local track = reaper.GetSelectedTrack(0, 0)
if not track then return end  -- Exit if no track is selected

-- Count the total number of items in the selected track
local num_items = reaper.CountTrackMediaItems(track)
if num_items == 0 then return end  -- Exit if there are no items

-- Disable UI updates for performance
reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- Store items to delete
local items_to_delete = {}

-- Process each item in the track
for i = num_items - 1, 0, -1 do  -- Loop backwards to avoid indexing issues when deleting items
    local item = reaper.GetTrackMediaItem(track, i)
    local take = reaper.GetActiveTake(item)

    if take and not reaper.TakeIsMIDI(take) then
        -- Create an Audio Accessor
        local accessor = reaper.CreateTakeAudioAccessor(take)
        local source = reaper.GetMediaItemTake_Source(take)
        local sample_rate = reaper.GetMediaSourceSampleRate(source)

        -- Get item length and total samples
        local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local num_samples = math.floor(sample_rate * item_length)
        local buffer = reaper.new_array(num_samples)

        -- Read samples from the audio source
        reaper.GetAudioAccessorSamples(accessor, sample_rate, 1, 0, num_samples, buffer)

        -- Destroy accessor to free memory
        reaper.DestroyAudioAccessor(accessor)

        -- Calculate peak
        local peak_db = -100  -- Default to a very low value
        for j = 1, num_samples do
            local sample = buffer[j] or 0
            local sample_db = sample == 0 and -100 or (20 * math.log(math.abs(sample)) / math.log(10))
            if sample_db > peak_db then
                peak_db = sample_db
            end
        end

        -- Check item duration (in seconds, so 0.15 = 150ms)
        local MIN_DURATION = 0.12
        if peak_db >= PEAK_MIN and peak_db <= PEAK_MAX and item_length >= MIN_DURATION then
            reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", ORANGE_COLOR)
        else
            table.insert(items_to_delete, item)  -- Mark item for deletion
        end
    end
end

-- Delete all items that were not colored orange
for _, item in ipairs(items_to_delete) do
    reaper.DeleteTrackMediaItem(track, item)
end

-- Re-enable UI updates
reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Ultra-Fast Peak Detection & Cleanup", -1)
reaper.UpdateArrange()
