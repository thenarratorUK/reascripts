-- @description Multicast TIghten Tail before Punch
-- @version 1.0
-- @author David Winter
-- Multicast Tighten Tail before Punch
-- Tightens the tail of the previous spoken item before a punch,
-- removing excess silence but leaving a small safety margin.
-- Author: David Winter

--------------------------------------
-- USER SETTINGS
--------------------------------------

local THRESHOLD_DB        = -38     -- Level above which we consider "real audio"
local SAFETY_MS           = 100     -- Leave this much after the last loud sample
local LOOKBACK_MS         = 3000    -- Only analyse this much before item end
local SEARCH_WINDOW       = 0.05    -- Only consider items whose end is within this many seconds before the cursor
local ROOM_TONE_NAME      = "Room Tone" -- Skip this track
local TOL                 = 1e-4    -- Time tolerance when comparing ends to cursor

local ZC_MAX_ADVANCE_MS   = 10      -- Snap trim point forward by up to this many ms to hit a zero crossing
local FADEOUT_S           = 0.025   -- 25 ms fade-out to suppress end clicks

local CONTIG_TOL_S        = 0.002   -- 2 ms tolerance for "contiguous" items
local FADEIN_S            = 0.020   -- 20 ms fade-in at the start of the contiguous series
--------------------------------------
-- HELPERS
--------------------------------------

local function db_to_amp(db)
    return 10 ^ (db / 20.0)
end

-- Find the item that ends closest to, but not after, `time`,
-- and not earlier than SEARCH_WINDOW seconds before `time`,
-- on any non-"Room Tone" track.
local function find_previous_item_ending_near(time)
    local proj       = 0
    local item_count = reaper.CountMediaItems(proj)
    local best_item  = nil
    local best_end   = -math.huge

    for i = 0, item_count - 1 do
        local item = reaper.GetMediaItem(proj, i)
        if item then
            local track = reaper.GetMediaItem_Track(item)
            if track then
                local _, track_name = reaper.GetTrackName(track, "")
                local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                local item_end = pos + len

                if item_end <= time + TOL and item_end >= time - SEARCH_WINDOW then
                    if track_name ~= ROOM_TONE_NAME then
                        if item_end > best_end then
                            best_end  = item_end
                            best_item = item
                        end
                    end
                end
            end
        end
    end

    return best_item, best_end
end

-- Snap a time forward to the first zero crossing within a small window.
-- If no sign change occurs, fall back to the lowest absolute amplitude sample in the window.
local function snap_time_to_zero_crossing(accessor, sr, t, t_max, max_advance_s)
    if not accessor or not sr or sr <= 0 then return t end
    if not t or not t_max then return t end
    if max_advance_s <= 0 then return t end

    local end_t = t + max_advance_s
    if end_t > t_max then end_t = t_max end
    if end_t <= t + (1 / sr) then
        return t
    end

    -- +2 to ensure at least one adjacent pair for sign-change testing
    local num = math.floor((end_t - t) * sr + 0.5) + 2
    if num < 3 then num = 3 end

    local buf = reaper.new_array(num)
    buf.clear()

    local ok = reaper.GetAudioAccessorSamples(
        accessor,
        sr,
        1,     -- mono
        t,
        num,
        buf
    )

    if not ok then
        return t
    end

    local prev = buf[1] or 0.0
    local best_i = 1
    local best_abs = math.abs(prev)

    for i = 2, num do
        local cur = buf[i] or 0.0
        local a = math.abs(cur)
        if a < best_abs then
            best_abs = a
            best_i = i
        end

        -- Detect a zero crossing between prev and cur (sign change or touching zero)
        if (prev <= 0 and cur >= 0) or (prev >= 0 and cur <= 0) then
            local denom = (cur - prev)
            local frac = 0.0
            if denom ~= 0 then
                frac = (-prev) / denom  -- linear interpolation between the two samples
            end
            if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end

            local crossing_time = t + ((i - 2) + frac) / sr
            if crossing_time < t then crossing_time = t end
            if crossing_time > end_t then crossing_time = end_t end
            return crossing_time
        end

        prev = cur
    end

    -- No sign change found: use the lowest-|amp| sample as "closest to zero"
    local best_time = t + (best_i - 1) / sr
    if best_time > end_t then best_time = end_t end
    return best_time
end

-- Use a TRACK audio accessor (project time) to scan backwards from item_end
-- (limited by LOOKBACK_MS) and find the last time signal exceeds THRESHOLD_DB.
-- Then apply SAFETY_MS and snap trim point to a near zero crossing.
local function find_last_loud_time_on_track(track, item_start, item_end)
    if not track then return nil end

    local proj = 0
    local proj_sr = reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", 0, false)
    local sr = (proj_sr > 0) and proj_sr or 48000

    local threshold_amp = db_to_amp(THRESHOLD_DB)

    local accessor = reaper.CreateTrackAudioAccessor(track)
    if not accessor then
        return nil
    end

    local block = math.floor(sr * 0.01 + 0.5)  -- ~10ms block
    if block < 1 then block = 1 end

    local max_lookback = LOOKBACK_MS / 1000.0
    local min_pos = math.max(item_start, item_end - max_lookback)

    local buffer = reaper.new_array(block)  -- 1 channel
    local pos_end = item_end

    while pos_end > min_pos do
        local block_start = pos_end - (block / sr)
        if block_start < min_pos then
            block_start = min_pos
        end

        local num_samples = math.floor((pos_end - block_start) * sr + 0.5)
        if num_samples <= 0 then
            break
        end
        if num_samples > block then
            num_samples = block
        end

        buffer.clear()
        local ok = reaper.GetAudioAccessorSamples(
            accessor,
            sr,
            1,
            block_start,
            num_samples,
            buffer
        )

        if ok then
            for s = num_samples - 1, 0, -1 do
                local idx = s + 1
                local amp = math.abs(buffer[idx] or 0.0)

                if amp >= threshold_amp then
                    local t = block_start + (s / sr)

                    local safety = SAFETY_MS / 1000.0
                    local trim_start = t + safety
                    if trim_start > item_end then
                        trim_start = item_end
                    end

                    local zc_window = ZC_MAX_ADVANCE_MS / 1000.0
                    trim_start = snap_time_to_zero_crossing(accessor, sr, trim_start, item_end, zc_window)

                    reaper.DestroyAudioAccessor(accessor)
                    return trim_start
                end
            end
        end

        pos_end = block_start
    end

    reaper.DestroyAudioAccessor(accessor)
    return nil
end

local function apply_fadeout(item, fade_s)
    if not item or not fade_s or fade_s <= 0 then return end

    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local fade_in  = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN")
    local max_fade = math.max(0, item_len - fade_in)
    local target   = math.min(fade_s, max_fade)

    local cur = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
    if cur < target then
        reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", target)
        reaper.UpdateItemInProject(item)
    end
end

local function apply_fadein(item, fade_s)
    if not item or not fade_s or fade_s <= 0 then return end

    local item_len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local fade_out  = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
    local max_fade  = math.max(0, item_len - fade_out)
    local target    = math.min(fade_s, max_fade)

    local cur = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN")
    if cur < target then
        reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", target)
        reaper.UpdateItemInProject(item)
    end
end

-- Given an item on a track, walk backwards across items whose end touches this item's start.
-- Returns the first item in the contiguous series (could be the original item).
local function find_first_item_in_contiguous_series(item, tol_s)
    if not item then return nil end
    local tr = reaper.GetMediaItem_Track(item)
    if not tr then return item end

    local tol = tol_s or 0.0
    local first = item

    while true do
        local first_pos = reaper.GetMediaItemInfo_Value(first, "D_POSITION")

        local best_prev = nil
        local best_prev_end = -math.huge

        local cnt = reaper.CountTrackMediaItems(tr)
        for i = 0, cnt - 1 do
            local it = reaper.GetTrackMediaItem(tr, i)
            if it and it ~= first then
                local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
                local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
                local it_end = pos + len

                -- Must end at/very near the start of 'first'
                if math.abs(it_end - first_pos) <= tol then
                    -- Prefer the one that ends closest (handles edge cases)
                    if it_end > best_prev_end then
                        best_prev_end = it_end
                        best_prev = it
                    end
                end
            end
        end

        if best_prev then
            first = best_prev
        else
            break
        end
    end

    return first
end

--------------------------------------
-- MAIN
--------------------------------------

local function main()
    local cursor = reaper.GetCursorPosition()

    local item, item_end = find_previous_item_ending_near(cursor)
    if not item or not item_end then
        return
    end

    local track = reaper.GetMediaItem_Track(item)
    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")

    local trim_start = find_last_loud_time_on_track(track, item_start, item_end)
    if not trim_start then
        return
    end

    if trim_start >= item_end - TOL then
        return
    end

    local first_item = find_first_item_in_contiguous_series(item, CONTIG_TOL_S)

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    reaper.GetSet_LoopTimeRange(true, false, trim_start, item_end, false)
    reaper.Main_OnCommand(40201, 0)  -- Remove contents of time selection (moving later items)
    apply_fadeout(item, FADEOUT_S)
    apply_fadein(first_item, FADEIN_S)
    reaper.Main_OnCommand(40026, 0)  -- Save the project (for backup purposes)
    reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)

    reaper.SetEditCurPos(trim_start, false, false)

    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Multicast Tighten Tail before Punch", -1)
end

main()
