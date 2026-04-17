-- @description Check Gaps Between Items
-- @version 1.0
-- @author David Winter
--[[
Check Long Pauses Between Items (Non-Excluded Tracks Only)
Implements the A–J pseudo-code exactly as described.

Exclusions (tracks skipped):
- Room Tone
- Breaths
- Clicks
- Renders
]]

local THRESHOLD_DB           = -45.0
local TARGET_MS              = 1400.0
local TARGET_SEC             = TARGET_MS / 1000.0
local GAP_THRESHOLD_SEC      = 0.0005  -- 0.5 ms
local OVERLAP_THRESHOLD_SEC  = 0.050   -- 50 ms
local PAUSE_DIFF_TOL         = 0.050   -- 50 ms
local SPECIAL_SUM_MIN        = 2.15
local SPECIAL_SUM_MAX        = 2.35
local ROOM_TONE_NAME         = "Room Tone"
local BREATHS_NAME           = "Breaths"
local CLICKS_NAME            = "Clicks"
local RENDERS_NAME           = "Renders"
local MARKER_TOL             = 0.0005  -- time tolerance for duplicate-marker check
local STEP_SEC               = 0.005   -- step for audio accessor scans (5 ms)

-- Progress marker (used to resume processing only on regions not yet checked)
local PROGRESS_MARKER_NAME   = "Gaps checked up to here"
local PROGRESS_MARKER_R      = 160
local PROGRESS_MARKER_G      = 32
local PROGRESS_MARKER_B      = 240

local function db_to_amp(db)
    return 10 ^ (db / 20.0)
end

local THRESHOLD_AMP = db_to_amp(THRESHOLD_DB)

------------------------------------------------------------
-- Utilities
------------------------------------------------------------

local function track_name_equals(track, target_name)
    if not track then return false end
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    return name == target_name
end

local function is_room_tone_track(track) return track_name_equals(track, ROOM_TONE_NAME) end
local function is_breaths_track(track)   return track_name_equals(track, BREATHS_NAME)   end
local function is_clicks_track(track)    return track_name_equals(track, CLICKS_NAME)    end
local function is_renders_track(track)   return track_name_equals(track, RENDERS_NAME)   end

local function is_excluded_track(track)
    return is_room_tone_track(track)
        or is_breaths_track(track)
        or is_clicks_track(track)
        or is_renders_track(track)
end

local function marker_exists_at(time_pos, tol, needle)
    -- Returns true if a *marker* (not a region) exists within tol of time_pos.
    -- If needle is provided, only returns true if the marker name contains needle (plain substring match).
    local total, num_markers, num_regions = reaper.CountProjectMarkers(0)
    for i = 0, total - 1 do
        local retval, isrgn, pos, rgnend, name, markrgnindexnumber =
            reaper.EnumProjectMarkers(i)

        if retval and (not isrgn) then
            if math.abs(pos - time_pos) <= tol then
                if needle == nil then
                    return true
                end

                name = name or ""
                if name:find(needle, 1, true) then
                    return true
                end
            end
        end
    end
    return false
end

local function get_progress_marker_pos()
    -- Returns the rightmost position of any existing progress marker with the exact name.
    local total = select(1, reaper.CountProjectMarkers(0))
    local best_pos = nil

    for i = 0, total - 1 do
        local retval, isrgn, pos, rgnend, name, markrgnindexnumber =
            reaper.EnumProjectMarkers(i)

        if retval and (not isrgn) then
            if (name or "") == PROGRESS_MARKER_NAME then
                if (not best_pos) or pos > best_pos then
                    best_pos = pos
                end
            end
        end
    end

    return best_pos
end

local function delete_progress_markers()
    -- Deletes all markers (not regions) whose name matches PROGRESS_MARKER_NAME exactly.
    local total = select(1, reaper.CountProjectMarkers(0))
    local ids = {}

    for i = 0, total - 1 do
        local retval, isrgn, pos, rgnend, name, markrgnindexnumber =
            reaper.EnumProjectMarkers(i)

        if retval and (not isrgn) then
            if (name or "") == PROGRESS_MARKER_NAME then
                ids[#ids + 1] = markrgnindexnumber
            end
        end
    end

    for _, id in ipairs(ids) do
        reaper.DeleteProjectMarker(0, id, false)
    end
end

local function add_progress_marker(pos)
    local color = reaper.ColorToNative(PROGRESS_MARKER_R, PROGRESS_MARKER_G, PROGRESS_MARKER_B) | 0x1000000
    reaper.AddProjectMarker2(0, false, pos, 0, PROGRESS_MARKER_NAME, -1, color)
end

local function find_first_item_in_region(region_start, region_end)
    local item_count = reaper.CountMediaItems(0)
    local best_item  = nil
    local best_start = nil

    for i = 0, item_count - 1 do
        local item  = reaper.GetMediaItem(0, i)
        local track = reaper.GetMediaItem_Track(item)

        if not is_excluded_track(track) then
            local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            if pos >= region_start and pos < region_end then
                if not best_item or pos < best_start then
                    best_item  = item
                    best_start = pos
                end
            end
        end
    end

    return best_item
end

-- Find the next non-excluded item after the current item, ignoring items
-- that are fully contained within the current item’s [start, end] span.
local function find_next_item_in_region(current_item_start, current_item_end, region_end)
    local item_count = reaper.CountMediaItems(0)
    local best_item  = nil
    local best_start = nil

    for i = 0, item_count - 1 do
        local item  = reaper.GetMediaItem(0, i)
        local track = reaper.GetMediaItem_Track(item)

        if not is_excluded_track(track) then
            local pos   = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local len   = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            local i_end = pos + len

            if pos > current_item_start and pos < region_end then
                -- NESTED EDGE CASE: if the candidate is fully within the current item, skip it.
                if not (pos >= current_item_start and i_end <= current_item_end) then
                    if not best_item or pos < best_start then
                        best_item  = item
                        best_start = pos
                    end
                end
            end
        end
    end

    return best_item
end

------------------------------------------------------------
-- Audio accessor helpers (TRACK-BASED)
------------------------------------------------------------

local function find_last_loud_in_item(item, item_start, item_end, threshold_amp)
    local track = reaper.GetMediaItem_Track(item)
    if not track then
        return false, item_start
    end

    local sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
    if sr <= 0 then sr = 44100 end

    local numch    = 2
    local accessor = reaper.CreateTrackAudioAccessor(track)
    if not accessor then
        return false, item_start
    end

    local samples_per_step = math.max(1, math.floor(STEP_SEC * sr + 0.5))
    local buf = reaper.new_array(numch * samples_per_step)

    local t            = item_end
    local found        = false
    local trigger_time = item_start

    while t > item_start do
        local read_start = t - STEP_SEC
        if read_start < item_start then
            read_start = item_start
        end

        buf.clear()
        local ok = reaper.GetAudioAccessorSamples(
            accessor,
            sr,
            numch,
            read_start,
            samples_per_step,
            buf
        )

        local maxamp = 0.0
        if ok then
            for i = 1, numch * samples_per_step do
                local v = math.abs(buf[i])
                if v > maxamp then maxamp = v end
            end
        else
            maxamp = 0.0
        end

        if maxamp > 0 and math.abs(maxamp - 1024.0) < 1.0 then
            maxamp = maxamp - 1024.0
            if maxamp < 0 then maxamp = -maxamp end
        end

        if maxamp ~= maxamp or maxamp == math.huge or maxamp == -math.huge or maxamp > 2.0 then
            maxamp = 0.0
        end

        if maxamp > threshold_amp then
            trigger_time = t
            found        = true
            break
        end

        t = t - STEP_SEC
    end

    reaper.DestroyAudioAccessor(accessor)

    if not found then
        return false, item_start
    else
        return true, trigger_time
    end
end

local function find_first_loud_in_item(item, item_start, item_end, threshold_amp)
    local track = reaper.GetMediaItem_Track(item)
    if not track then
        return false, item_end
    end

    local sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
    if sr <= 0 then sr = 44100 end

    local numch    = 2
    local accessor = reaper.CreateTrackAudioAccessor(track)
    if not accessor then
        return false, item_end
    end

    local samples_per_step = math.max(1, math.floor(STEP_SEC * sr + 0.5))
    local buf = reaper.new_array(numch * samples_per_step)

    local t            = item_start
    local found        = false
    local trigger_time = item_end

    while t < item_end do
        local read_start = t
        if read_start + STEP_SEC > item_end then
            read_start = item_end - STEP_SEC
            if read_start < item_start then
                read_start = item_start
            end
        end

        buf.clear()
        local ok = reaper.GetAudioAccessorSamples(
            accessor,
            sr,
            numch,
            read_start,
            samples_per_step,
            buf
        )

        local maxamp = 0.0
        if ok then
            for i = 1, numch * samples_per_step do
                local v = math.abs(buf[i])
                if v > maxamp then maxamp = v end
            end
        else
            maxamp = 0.0
        end

        if maxamp > 0 and math.abs(maxamp - 1024.0) < 1.0 then
            maxamp = maxamp - 1024.0
            if maxamp < 0 then maxamp = -maxamp end
        end

        if maxamp ~= maxamp or maxamp == math.huge or maxamp == -math.huge or maxamp > 2.0 then
            maxamp = 0.0
        end

        if maxamp > threshold_amp then
            trigger_time = t
            found        = true
            break
        end

        t = t + STEP_SEC
    end

    reaper.DestroyAudioAccessor(accessor)

    if not found then
        return false, item_end
    else
        return true, trigger_time
    end
end

------------------------------------------------------------
-- Main per-region processing (D–J)
------------------------------------------------------------

local function process_region(region_start, region_end, region_name)
    -- D: First item on any track that isn’t excluded = current_item
    local current_item = find_first_item_in_region(region_start, region_end)
    if not current_item then
        return
    end

    while true do
        local current_item_start = reaper.GetMediaItemInfo_Value(current_item, "D_POSITION")
        local current_item_end   = current_item_start + reaper.GetMediaItemInfo_Value(current_item, "D_LENGTH")

        local next_item = find_next_item_in_region(current_item_start, current_item_end, region_end)
        if not next_item then
            return
        end

        local next_item_start = reaper.GetMediaItemInfo_Value(next_item, "D_POSITION")
        local next_item_end   = next_item_start + reaper.GetMediaItemInfo_Value(next_item, "D_LENGTH")

        local diff = next_item_start - current_item_end

        if diff > GAP_THRESHOLD_SEC then
            if not marker_exists_at(next_item_start, MARKER_TOL, "Gap") then
                reaper.AddProjectMarker(0, false, next_item_start, 0, "Gap", -1)
            end
            current_item = next_item
            goto continue_region_items
        end

        if diff < -OVERLAP_THRESHOLD_SEC then
            if not marker_exists_at(next_item_start, MARKER_TOL, "Overlap") then
                reaper.AddProjectMarker(0, false, next_item_start, 0, "Overlap", -1)
            end
            current_item = next_item
            goto continue_region_items
        end

        local current_found, current_item_trigger = find_last_loud_in_item(
            current_item,
            current_item_start,
            current_item_end,
            THRESHOLD_AMP
        )
        local next_found, next_item_trigger = find_first_loud_in_item(
            next_item,
            next_item_start,
            next_item_end,
            THRESHOLD_AMP
        )

        local next_item_pause    = next_item_trigger    - next_item_start
        local current_item_pause = current_item_end     - current_item_trigger

        local pause_diff = current_item_pause - next_item_pause
        local pause_sum  = current_item_pause + next_item_pause

        if pause_diff < PAUSE_DIFF_TOL and pause_diff > -PAUSE_DIFF_TOL then
            if pause_sum > SPECIAL_SUM_MIN and pause_sum < SPECIAL_SUM_MAX then
                current_item = next_item
                goto continue_region_items
            end
        end

        local skip_long_pause_marker = false

        if (not next_found) and current_found then
            local after_next = find_next_item_in_region(next_item_start, next_item_end, region_end)
            if not after_next then
                skip_long_pause_marker = true
            end
        end

        if pause_sum > TARGET_SEC then
            if not skip_long_pause_marker then
                if not marker_exists_at(current_item_end, MARKER_TOL, "Long Pause") then
                    reaper.AddProjectMarker(0, false, current_item_end, 0, "Long Pause?", -1)
                end
            end
            current_item = next_item
            goto continue_region_items
        else
            current_item = next_item
            goto continue_region_items
        end

        ::continue_region_items::
    end
end

------------------------------------------------------------
-- Top-level region loop (A–C)
------------------------------------------------------------

local function main()
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    local prior_progress_pos = get_progress_marker_pos()
    local last_checked_pos = prior_progress_pos
    if last_checked_pos == nil then
        -- No progress marker yet: process from the beginning.
        last_checked_pos = -1e15
    end

    local total, num_markers, num_regions = reaper.CountProjectMarkers(0)
    local regions = {}

    for i = 0, total - 1 do
        local retval, isrgn, rgn_start, rgn_end, name, markrgnindexnumber =
            reaper.EnumProjectMarkers(i)

        if retval and isrgn then
            local region_name   = name or ""
            local region_start  = rgn_start
            local region_end    = rgn_end
            local region_length = region_end - region_start

            if region_length >= 30.0
               and not region_name:find("15-Minute Checkpoint", 1, true)
               and not region_name:find("Voice Reference", 1, true)
            then
                regions[#regions + 1] = {
                    start  = region_start,
                    finish = region_end,
                    name   = region_name,
                }
            end
        end
    end

    table.sort(regions, function(a, b)
        return a.start < b.start
    end)

    local new_progress_pos = prior_progress_pos
    local processed_any = false

    for _, r in ipairs(regions) do
        -- Only process regions that extend beyond the last checked point.
        -- (Using region end, so a region whose finish equals the marker is considered checked.)
        if r.finish > (last_checked_pos + MARKER_TOL) then
            process_region(r.start, r.finish, r.name)
            new_progress_pos = r.finish
            processed_any = true
        end
    end

    -- Replace the existing progress marker with one at the end of the last checked region.
    delete_progress_markers()
    if new_progress_pos ~= nil then
        add_progress_marker(new_progress_pos)
    end

    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Check long pauses between non-excluded items", -1)
end

main()
