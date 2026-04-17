-- @description Breath Detection Part 1 (Dynamic Split)
-- @version 1.0
-- @author David Winter
--[[
  Dynamic 2-Pass Split for Breaths
  Pass 1: Remove silences (imitate Dynamic Split pass 1)
  Pass 2: Gate-based slicing (imitate Dynamic Split pass 2)

  All analysis is done in ITEM-LOCAL time (0..item_len).
  AudioAccessor is fed item-local time; project time is only used
  when actually splitting / deleting items.
--]]

------------------------------------------------------------
-- GLOBAL CONFIG
------------------------------------------------------------

-- Pass 1: silence detection & removal
local P1_WINDOW_S        = 0.005   -- 5 ms analysis window
local P1_THRESH_DB       = -40.0   -- silence threshold (<= is "quiet")
local P1_MIN_SILENCE_S   = 0.020   -- minimum silence length
local P1_PAD_S           = 0.002   -- pad kept at each edge of removed silence

-- Pass 2: gate-based split
local P2_WINDOW_S        = 0.005   -- 5 ms window
local P2_OPEN_DB         = -12.0   -- gate opens above this
local P2_CLOSE_DB        = -35.0   -- gate closes below this (threshold + hysteresis)
local P2_MIN_SLICE_S     = 0.150   -- minimum audible slice length
local P2_MIN_SILENCE_S   = 0.020   -- mini­mum silence between slices

local AMP_EPS            = 1e-12

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------

local function amp_to_db(amp)
    if amp < AMP_EPS then amp = AMP_EPS end
    return 20.0 * math.log(amp, 10) -- log10
end

local function new_accessor_for_item(item)
    local take = reaper.GetActiveTake(item)
    if not take or reaper.TakeIsMIDI(take) then
        return nil, nil, nil
    end

    local src = reaper.GetMediaItemTake_Source(take)
    local samplerate = reaper.GetMediaSourceSampleRate(src)
    if samplerate <= 0 then samplerate = 44100 end

    local accessor = reaper.CreateTakeAudioAccessor(take)
    if not accessor then return nil, nil, nil end

    return accessor, samplerate, 1 -- mono
end

------------------------------------------------------------
-- PASS 1: SILENCE DETECTION -> REMOVAL INTERVALS
-- Returns array of {start = local_start, ["end"] = local_end}
-- where times are seconds relative to item start.
------------------------------------------------------------

local function pass1_collect_silence_intervals(item)
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if item_len <= 0 then return {} end

    local accessor, samplerate, num_channels = new_accessor_for_item(item)
    if not accessor then return {} end

    local window_samples = math.max(1, math.floor(P1_WINDOW_S * samplerate + 0.5))
    local item_end_local = item_len

    local buffer = reaper.new_array(window_samples)

    local intervals = {}

    local have_candidate = false
    local quiet_start_loc = nil
    local quiet_dur = 0.0

    local t_local = 0.0

    while t_local + P1_WINDOW_S <= item_end_local do
        buffer.clear()
        local ok = reaper.GetAudioAccessorSamples(
            accessor,
            samplerate,
            num_channels,
            t_local,        -- ITEM-LOCAL time
            window_samples,
            buffer
        )
        if ok ~= 1 then break end

        local peak_amp = 0.0
        for i = 1, window_samples do
            local a = math.abs(buffer[i] or 0.0)
            if a > peak_amp then peak_amp = a end
        end

        local peak_db = amp_to_db(peak_amp)
        local is_quiet = (peak_db <= P1_THRESH_DB)

        if is_quiet then
            if not have_candidate then
                have_candidate = true
                quiet_start_loc = t_local
                quiet_dur = P1_WINDOW_S
            else
                quiet_dur = quiet_dur + P1_WINDOW_S
            end
        else
            if have_candidate and quiet_dur >= P1_MIN_SILENCE_S then
                local rs = quiet_start_loc + P1_PAD_S
                local re = t_local - P1_PAD_S
                if re > rs then
                    intervals[#intervals+1] = { start = rs, ["end"] = re }
                end
            end
            have_candidate = false
            quiet_start_loc = nil
            quiet_dur = 0.0
        end

        t_local = t_local + P1_WINDOW_S
    end

    -- trailing silence
    if have_candidate and quiet_dur >= P1_MIN_SILENCE_S then
        local rs = quiet_start_loc + P1_PAD_S
        local re = item_end_local - P1_PAD_S
        if re > rs then
            intervals[#intervals+1] = { start = rs, ["end"] = re }
        end
    end

    reaper.DestroyAudioAccessor(accessor)

    return intervals
end

------------------------------------------------------------
-- PASS 1: APPLY SILENCE REMOVAL (split + delete)
------------------------------------------------------------

local function pass1_apply_silence_removal(item, intervals_local)
    if #intervals_local == 0 then return end

    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_len   = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end   = item_start + item_len

    -- Convert intervals to project time and collect split boundaries
    local boundaries = {}
    local seen = {}

    local function add_boundary(t)
        if t <= item_start or t >= item_end then return end
        local key = math.floor(t * 1000 + 0.5) -- ms quantisation
        if not seen[key] then
            seen[key] = true
            boundaries[#boundaries+1] = t
        end
    end

    local removal_intervals_project = {}
    for _, iv in ipairs(intervals_local) do
        local rs = item_start + iv.start
        local re = item_start + iv["end"]
        if re > rs then
            removal_intervals_project[#removal_intervals_project+1] = { start = rs, ["end"] = re }
            add_boundary(rs)
            add_boundary(re)
        end
    end

    if #boundaries == 0 then return end

    table.sort(boundaries, function(a,b) return a < b end)

    -- Split from right to left
    for i = #boundaries, 1, -1 do
        reaper.SplitMediaItem(item, boundaries[i])
    end

    -- Delete items whose centres lie inside any removal interval
    local track = reaper.GetMediaItem_Track(item)
    local track_item_count = reaper.CountTrackMediaItems(track)

    local function centre_in_removal(c)
        for _, iv in ipairs(removal_intervals_project) do
            if c >= iv.start and c <= iv["end"] then
                return true
            end
        end
        return false
    end

    for i = track_item_count - 1, 0, -1 do
        local it = reaper.GetTrackMediaItem(track, i)
        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
        local centre = pos + 0.5 * len

        if centre >= item_start and centre <= item_end then
            if centre_in_removal(centre) then
                reaper.DeleteTrackMediaItem(track, it)
            end
        end
    end
end

------------------------------------------------------------
-- PASS 2: GATE-BASED SPLIT ON REMAINING ITEMS
-- Adds splits whenever the gate OPENS or CLOSES.
-- Returns array of split times (item-local) for one item.
------------------------------------------------------------

local function pass2_collect_split_points(item)
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if item_len <= 0 then return {} end

    local accessor, samplerate, num_channels = new_accessor_for_item(item)
    if not accessor then return {} end

    local window_samples = math.max(1, math.floor(P2_WINDOW_S * samplerate + 0.5))
    local item_end_local = item_len

    local buffer = reaper.new_array(window_samples)

    local split_local = {}

    -- Gate state with hysteresis
    -- QUIET: waiting for > P2_OPEN_DB
    -- LOUD : waiting for < P2_CLOSE_DB
    local state = "QUIET"

    local t_local = 0.0

    while t_local + P2_WINDOW_S <= item_end_local do
        buffer.clear()
        local ok = reaper.GetAudioAccessorSamples(
            accessor,
            samplerate,
            num_channels,
            t_local,         -- ITEM-LOCAL time
            window_samples,
            buffer
        )
        if ok ~= 1 then break end

        local peak_amp = 0.0
        for i = 1, window_samples do
            local a = math.abs(buffer[i] or 0.0)
            if a > peak_amp then peak_amp = a end
        end

        local peak_db = amp_to_db(peak_amp)
        local new_state = state

        if state == "QUIET" then
            if peak_db > P2_OPEN_DB then
                new_state = "LOUD"
            end
        else -- state == "LOUD"
            if peak_db < P2_CLOSE_DB then
                new_state = "QUIET"
            end
        end

        if new_state ~= state then
            -- Gate just changed state: add a split here
            if t_local > 0.0 and t_local < item_end_local then
                split_local[#split_local+1] = t_local
            end
            state = new_state
        end

        t_local = t_local + P2_WINDOW_S
    end

    reaper.DestroyAudioAccessor(accessor)

    -- Sort & de-duplicate very close points
    table.sort(split_local, function(a,b) return a < b end)
    local unique = {}
    local last = nil
    for _, t_loc in ipairs(split_local) do
        if not last or math.abs(t_loc - last) > (P2_WINDOW_S * 0.25) then
            unique[#unique+1] = t_loc
            last = t_loc
        end
    end

    return unique
end

------------------------------------------------------------
-- PASS 2: APPLY SPLITS (no deletion)
------------------------------------------------------------

local function pass2_apply_splits(item, split_points_local)
    if #split_points_local == 0 then return end

    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")

    for i = #split_points_local, 1, -1 do
        local t_proj = item_start + split_points_local[i]
        reaper.SplitMediaItem(item, t_proj)
    end
end

------------------------------------------------------------
-- MAIN
------------------------------------------------------------

local function main()
    -- Use the FIRST selected track
    local track = reaper.GetSelectedTrack(0, 0)
    if not track then
        reaper.ShowMessageBox(
            "Select a track.",
            "2-Pass Dynamic Split",
            0
        )
        return
    end

    -- Record ranges (project) for each item on that track
    local ranges = {}
    local items  = {}

    local track_item_count = reaper.CountTrackMediaItems(track)
    if track_item_count == 0 then
        reaper.ShowMessageBox(
            "Selected track has no items.",
            "2-Pass Dynamic Split",
            0
        )
        return
    end

    for i = 0, track_item_count - 1 do
        local it = reaper.GetTrackMediaItem(track, i)
        if it then
            items[#items+1] = it
            local s = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
            local e = s + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
            ranges[#ranges+1] = { track = track, start = s, ["end"] = e }
        end
    end

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    --------------------------------------------------------
    -- PASS 1: silence removal on each originally-selected item
    --------------------------------------------------------
    for _, it in ipairs(items) do
        local intervals = pass1_collect_silence_intervals(it)
        pass1_apply_silence_removal(it, intervals)
    end

    --------------------------------------------------------
    -- PASS 2: gate-based split on remaining items in each range
    --------------------------------------------------------
    for _, r in ipairs(ranges) do
        local tr = r.track
        local tr_count = reaper.CountTrackMediaItems(tr)
        for i = 0, tr_count - 1 do
            local it = reaper.GetTrackMediaItem(tr, i)
            local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
            local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
            local it_start = pos
            local it_end   = pos + len

            -- overlap with original range?
            if it_end > r.start and it_start < r["end"] then
                local splits_local = pass2_collect_split_points(it)
                pass2_apply_splits(it, splits_local)
            end
        end
    end

    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("2-Pass Dynamic Split (silence removal + gate)", -1)
end

main()
