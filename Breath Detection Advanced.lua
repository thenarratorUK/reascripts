-- @description Breath Detection Advanced
-- @version 1.0
-- @author David Winter
-- Breath Preparation and Detection (Multi-Gate + ZCR/Envelope + Source-Track Classifier)
-- Runs on the track named "Breaths".
--
-- Pipeline:
--   1) Pass 1: Silence removal (true near-silence) around P1_THRESH_DB.
--   2) Pass 2: Gate 1 (-35 / -40 dB) – splits at transitions between deep silence and any audible audio.
--   3) Pass 3: Gate 2 (-12 / -16 dB) – further splits loud speech cores; breaths (never that loud) remain intact.
--   4) Classifier:
--        - ZCR in [ZCR_THRESHOLD, ZCR_MAX_THRESHOLD]
--        - Item length >= MIN_BREATH_LEN
--        - Global peak in [PEAK_MIN_DB, PEAK_MAX_DB]
--        - Start & end edge peaks in [EDGE_BREATH_MIN_DB, EDGE_BREATH_MAX_DB]
--        - (NEW) RMS >= RMS_MIN_DB
--        - (NEW) Source track name is in ALLOWED_SOURCE_TRACKS
--      Breath candidates are coloured; others are deleted in the region.

------------------------------------------------------------
-- GLOBAL / USER SETTINGS
------------------------------------------------------------

-- Dynamic split: Pass 1 (silence detection & removal)
local P1_WINDOW_S        = 0.005   -- 5 ms analysis window
local P1_THRESH_DB       = -40.0   -- silence threshold (<= is "quiet")
local P1_MIN_SILENCE_S   = 0.020   -- minimum silence length
local P1_PAD_S           = 0.002   -- pad kept at each edge of removed silence

-- Dynamic split: Gate 1 (Pass 2) – "audible vs deep silence"
local G1_WINDOW_S        = 0.005   -- 5 ms window
local G1_OPEN_DB         = -35.0   -- gate opens above this (audible)
local G1_CLOSE_DB        = -40.0   -- gate closes below this (back to deep quiet)

-- Dynamic split: Gate 2 (Pass 3) – "loud cores vs mid-level"
local G2_WINDOW_S        = 0.005   -- 5 ms window
local G2_OPEN_DB         = -12.0   -- gate opens above this (strong speech)
local G2_CLOSE_DB        = -16.0   -- gate closes below this

-- Only items longer than this are treated as "source" to process
local MIN_SOURCE_ITEM_LEN = 5.0    -- seconds

-- Breath detection (after dynamic splits)
local WINDOW_S            = 0.002   -- 2 ms windows for ZCR and RMS
local ZCR_THRESHOLD       = 5000.0  -- zero-crossings per second (lower bound)
local ZCR_MAX_THRESHOLD   = 16000.0 -- upper bound on ZCR to reject ultra-hissy noise
local MIN_BREATH_LEN      = 0.050   -- 50 ms minimum length for final breaths

-- Envelope and peak constraints for breaths
local EDGE_WINDOW_S       = 0.010   -- 10 ms at start & end for edge peak checks
local EDGE_BREATH_MIN_DB  = -120.0  -- breath edges should be between -120 and -30 dB
local EDGE_BREATH_MAX_DB  = -30.0
local PEAK_MIN_DB         = -33.0   -- tightened: global peak between -33 and -16 dB
local PEAK_MAX_DB         = -16.0
local RMS_MIN_DB          = -45.0   -- breaths must be at least this loud in RMS

local COLOR_BREATH        = reaper.ColorToNative(255,165,0) | 0x1000000 -- orange
local AMP_EPS             = 1e-12
local GLUE_EPS            = 0.0005  -- 0.5 ms tolerance for adjacency when gluing

-- Source-track filtering
local USE_SOURCE_TRACK_FILTER = true

local ALLOWED_SOURCE_TRACKS = {
    "Narration",
    "Narrative",
    "Dialogue 1",
    "Dialogue 2",
    "Recording",
    "Recordings",
}

local IGNORE_SOURCE_TRACKS = {
    "Room Tone",
    "RoomTone",
    "Breaths",      -- defensive; we also skip the Breaths track by pointer
}

-- Console stats
local PRINT_STATS         = false   -- set to true to print final item stats

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------

local stats_header_printed = false

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

local function find_track_by_name(name)
    local track_count = reaper.CountTracks(0)
    for i = 0, track_count - 1 do
        local tr = reaper.GetTrack(0, i)
        local retval, tr_name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
        if retval and tr_name == name then
            return tr
        end
    end
    return nil
end

local function ranges_overlap(a_start, a_end, b_start, b_end)
    return (a_end > b_start) and (a_start < b_end)
end

local function name_in_list(name, list)
    if not name then return false end
    local lname = string.lower(name)
    for _, n in ipairs(list) do
        if lname == string.lower(n) then
            return true
        end
    end
    return false
end

-- Find the "source" track for a Breaths item by maximum time overlap.
-- Skips the Breaths track itself and any track whose name is in IGNORE_SOURCE_TRACKS.
local function find_source_track_for_breath_item(breath_item, breaths_track)
    local breath_pos = reaper.GetMediaItemInfo_Value(breath_item, "D_POSITION")
    local breath_len = reaper.GetMediaItemInfo_Value(breath_item, "D_LENGTH")
    local breath_end = breath_pos + breath_len

    local best_track   = nil
    local best_name    = nil
    local best_overlap = 0.0

    local track_count = reaper.CountTracks(0)
    for t = 0, track_count - 1 do
        local tr = reaper.GetTrack(0, t)
        if tr ~= breaths_track then
            local _, tr_name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
            if not name_in_list(tr_name, IGNORE_SOURCE_TRACKS) then
                local item_count = reaper.CountTrackMediaItems(tr)
                for i = 0, item_count - 1 do
                    local it = reaper.GetTrackMediaItem(tr, i)
                    local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
                    local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
                    local it_start = pos
                    local it_end   = pos + len

                    if ranges_overlap(it_start, it_end, breath_pos, breath_end) then
                        local overlap_start = math.max(it_start, breath_pos)
                        local overlap_end   = math.min(it_end,   breath_end)
                        local overlap_len   = overlap_end - overlap_start
                        if overlap_len > best_overlap then
                            best_overlap = overlap_len
                            best_track   = tr
                            best_name    = tr_name
                        end
                    end
                end
            end
        end
    end

    return best_track, best_name, best_overlap
end

------------------------------------------------------------
-- PASS 1: SILENCE DETECTION -> REMOVAL INTERVALS
-- Returns array of {start = local_start, ["end"] = local_end}
-- times are seconds relative to item start.
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
            t_local,
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
                local re_ = t_local - P1_PAD_S
                if re_ > rs then
                    intervals[#intervals+1] = { start = rs, ["end"] = re_ }
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
        local re_ = item_end_local - P1_PAD_S
        if re_ > rs then
            intervals[#intervals+1] = { start = rs, ["end"] = re_ }
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
        local re_ = item_start + iv["end"]
        if re_ > rs then
            removal_intervals_project[#removal_intervals_project+1] = { start = rs, ["end"] = re_ }
            add_boundary(rs)
            add_boundary(re_)
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
-- GENERIC GATE-BASED SPLIT ON A SINGLE ITEM
-- Adds splits whenever the gate OPENS or CLOSES.
-- If refine_edges is true, adjusts split times around A/B
-- using a ±100 ms local search based on level changes.
-- Returns array of split times (item-local).
------------------------------------------------------------

local function gate_collect_split_points(item, window_s, open_db, close_db, refine_edges)
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if item_len <= 0 then return {} end

    local accessor, samplerate, num_channels = new_accessor_for_item(item)
    if not accessor then return {} end

    local window_samples = math.max(1, math.floor(window_s * samplerate + 0.5))
    local item_end_local = item_len

    local buffer = reaper.new_array(window_samples)

    -- Store per-window time and level for later refinement
    local times = {}
    local dbs   = {}

    -- Store gate transitions as { idx = k, kind = "OPEN"/"CLOSE" }
    local events = {}

    local state = "QUIET"
    local t_local = 0.0

    while t_local + window_s <= item_end_local do
        buffer.clear()
        local ok = reaper.GetAudioAccessorSamples(
            accessor,
            samplerate,
            num_channels,
            t_local,
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

        times[#times+1] = t_local
        dbs[#dbs+1]     = peak_db
        local idx = #times

        local new_state = state
        if state == "QUIET" then
            if peak_db > open_db then
                new_state = "LOUD"
            end
        else -- state == "LOUD"
            if peak_db < close_db then
                new_state = "QUIET"
            end
        end

        if new_state ~= state then
            local kind = (state == "QUIET" and new_state == "LOUD") and "OPEN" or "CLOSE"
            events[#events+1] = { idx = idx, kind = kind }
            state = new_state
        end

        t_local = t_local + window_s
    end

    reaper.DestroyAudioAccessor(accessor)

    local splits_local = {}

    local function clamp(v, lo, hi)
        if v < lo then return lo end
        if v > hi then return hi end
        return v
    end

    if refine_edges then
        local SEARCH_WIN = 0.100  -- 100 ms

        for _, ev in ipairs(events) do
            local idx = ev.idx
            local t_gate = times[idx]
            local t_split = t_gate

            if ev.kind == "OPEN" then
                -- Search backwards up to 100 ms for first point
                -- where level increases when moving backwards:
                -- i.e. db[j] > db[j+1]
                local found = false
                for j = idx - 1, 1, -1 do
                    if (times[idx] - times[j]) > SEARCH_WIN then
                        break
                    end
                    if dbs[j] > dbs[j+1] then
                        t_split = times[j]
                        found = true
                        break
                    end
                end
                if not found then
                    t_split = clamp(t_gate - SEARCH_WIN, 0.0, item_len)
                end
            else -- ev.kind == "CLOSE"
                -- Search forwards up to 100 ms for first point
                -- where level increases when moving forwards:
                -- i.e. db[j] > db[j-1]
                local found = false
                for j = idx + 1, #times do
                    if (times[j] - times[idx]) > SEARCH_WIN then
                        break
                    end
                    if dbs[j] > dbs[j-1] then
                        t_split = times[j]
                        found = true
                        break
                    end
                end
                if not found then
                    t_split = clamp(t_gate + SEARCH_WIN, 0.0, item_len)
                end
            end

            -- Avoid splits exactly at item edges
            if t_split > 0.0 and t_split < item_len then
                splits_local[#splits_local+1] = t_split
            end
        end
    else
        -- Original behaviour: split exactly at gate transition times
        for _, ev in ipairs(events) do
            local t_gate = times[ev.idx]
            if t_gate > 0.0 and t_gate < item_len then
                splits_local[#splits_local+1] = t_gate
            end
        end
    end

    -- Sort & de-duplicate very close points
    table.sort(splits_local, function(a,b) return a < b end)
    local unique = {}
    local last = nil
    for _, t_loc in ipairs(splits_local) do
        if (not last) or math.abs(t_loc - last) > (window_s * 0.25) then
            unique[#unique+1] = t_loc
            last = t_loc
        end
    end

    return unique
end

local function apply_splits_for_item(item, split_points_local)
    if #split_points_local == 0 then return end

    local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")

    for i = #split_points_local, 1, -1 do
        local t_proj = item_start + split_points_local[i]
        reaper.SplitMediaItem(item, t_proj)
    end
end

------------------------------------------------------------
-- RANGE-LIMITED BREATH FEATURE CALCULATION
------------------------------------------------------------

local function compute_item_features(item)
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if item_len <= 0 then
        return 0.0, -120.0, -120.0
    end

    local accessor, samplerate, num_channels = new_accessor_for_item(item)
    if not accessor then
        return 0.0, -120.0, -120.0
    end

    local window_samples = math.max(1, math.floor(WINDOW_S * samplerate + 0.5))
    local buffer = reaper.new_array(window_samples)

    local total_zc = 0
    local prev_sign = nil
    local peak_amp_global = 0.0
    local sum_sq = 0.0
    local total_samples = 0

    local t_local = 0.0
    local item_end_local = item_len

    while t_local + WINDOW_S <= item_end_local do
        buffer.clear()
        local ok = reaper.GetAudioAccessorSamples(
            accessor,
            samplerate,
            num_channels,
            t_local,
            window_samples,
            buffer
        )
        if ok ~= 1 then break end

        for i = 1, window_samples do
            local s = buffer[i] or 0.0

            -- ZCR
            local sign = (s >= 0.0) and 1 or -1
            if prev_sign and (sign ~= prev_sign) then
                total_zc = total_zc + 1
            end
            prev_sign = sign

            -- Peak
            local a = math.abs(s)
            if a > peak_amp_global then
                peak_amp_global = a
            end

            -- RMS
            sum_sq = sum_sq + s * s
            total_samples = total_samples + 1
        end

        t_local = t_local + WINDOW_S
    end

    -- Normalise ZCR by actual analysed time
    local zcr_per_second = 0.0
    local rms_db = -120.0
    local peak_db = amp_to_db(peak_amp_global)

    if total_samples > 0 and samplerate > 0 then
        local time_analyzed = total_samples / samplerate
        if time_analyzed > 0.0 then
            zcr_per_second = total_zc / time_analyzed
        end

        local rms_amp = math.sqrt(sum_sq / total_samples)
        rms_db = amp_to_db(rms_amp)
    end

    reaper.DestroyAudioAccessor(accessor)

    return zcr_per_second, peak_db, rms_db
end

local function compute_edge_peaks(item)
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if item_len <= 0 then
        return -120.0, -120.0
    end

    local accessor, samplerate, num_channels = new_accessor_for_item(item)
    if not accessor then
        return -120.0, -120.0
    end

    local edge_samples = math.max(1, math.floor(EDGE_WINDOW_S * samplerate + 0.5))
    local buffer = reaper.new_array(edge_samples)

    -- Start edge
    buffer.clear()
    local ok_start = reaper.GetAudioAccessorSamples(
        accessor,
        samplerate,
        num_channels,
        0.0,
        edge_samples,
        buffer
    )
    local start_peak_amp = 0.0
    if ok_start == 1 then
        for i = 1, edge_samples do
            local a = math.abs(buffer[i] or 0.0)
            if a > start_peak_amp then
                start_peak_amp = a
            end
        end
    end

    -- End edge
    local t_start_end = item_len - EDGE_WINDOW_S
    if t_start_end < 0.0 then t_start_end = 0.0 end

    buffer.clear()
    local ok_end = reaper.GetAudioAccessorSamples(
        accessor,
        samplerate,
        num_channels,
        t_start_end,
        edge_samples,
        buffer
    )
    local end_peak_amp = 0.0
    if ok_end == 1 then
        for i = 1, edge_samples do
            local a = math.abs(buffer[i] or 0.0)
            if a > end_peak_amp then
                end_peak_amp = a
            end
        end
    end

    reaper.DestroyAudioAccessor(accessor)

    local start_db = amp_to_db(start_peak_amp)
    local end_db   = amp_to_db(end_peak_amp)

    return start_db, end_db
end

------------------------------------------------------------
-- RANGE-LIMITED BREATH STEPS
------------------------------------------------------------

local function classify_items_in_range(track, r_start, r_end, breaths_track)
    local count = reaper.CountTrackMediaItems(track)
    for i = 0, count - 1 do
        local it = reaper.GetTrackMediaItem(track, i)
        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
        local it_start = pos
        local it_end   = pos + len

        if ranges_overlap(it_start, it_end, r_start, r_end) then
            local zcr, peak_db, rms_db = compute_item_features(it)
            local edge_start_db, edge_end_db = compute_edge_peaks(it)

            -- Source track filter
            local source_ok = true
            if USE_SOURCE_TRACK_FILTER then
                local src_tr, src_name = find_source_track_for_breath_item(it, breaths_track)
                if not src_tr or not name_in_list(src_name, ALLOWED_SOURCE_TRACKS) then
                    source_ok = false
                end
            end

            local is_breath =
                source_ok and
                (len >= MIN_BREATH_LEN) and
                (zcr >= ZCR_THRESHOLD) and
                (zcr <= ZCR_MAX_THRESHOLD) and
                (rms_db >= RMS_MIN_DB) and
                (peak_db >= PEAK_MIN_DB) and
                (peak_db <= PEAK_MAX_DB) and
                (edge_start_db >= EDGE_BREATH_MIN_DB) and
                (edge_start_db <= EDGE_BREATH_MAX_DB) and
                (edge_end_db   >= EDGE_BREATH_MIN_DB) and
                (edge_end_db   <= EDGE_BREATH_MAX_DB)

            if is_breath then
                reaper.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", COLOR_BREATH)
            else
                reaper.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", 0)
            end
        end
    end
end

local function glue_adjacent_breaths_in_range(track, r_start, r_end)
    local count = reaper.CountTrackMediaItems(track)
    if count == 0 then return end

    local breath_items = {}

    for i = 0, count - 1 do
        local it = reaper.GetTrackMediaItem(track, i)
        local col = reaper.GetMediaItemInfo_Value(it, "I_CUSTOMCOLOR")
        if col == COLOR_BREATH then
            local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
            local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
            local it_start = pos
            local it_end   = pos + len
            if ranges_overlap(it_start, it_end, r_start, r_end) then
                breath_items[#breath_items+1] = { item = it, pos = pos, len = len }
            end
        end
    end

    if #breath_items <= 1 then return end

    table.sort(breath_items, function(a, b) return a.pos < b.pos end)

    local groups = {}
    local current_group = { breath_items[1].item }
    local prev_end = breath_items[1].pos + breath_items[1].len

    for i = 2, #breath_items do
        local bi = breath_items[i]
        local start = bi.pos
        local this_end = bi.pos + bi.len

        if math.abs(start - prev_end) <= GLUE_EPS then
            current_group[#current_group+1] = bi.item
            prev_end = this_end
        else
            if #current_group > 1 then
                groups[#groups+1] = current_group
            end
            current_group = { bi.item }
            prev_end = this_end
        end
    end
    if #current_group > 1 then
        groups[#groups+1] = current_group
    end

    for _, group in ipairs(groups) do
        reaper.SelectAllMediaItems(0, false)
        for _, it in ipairs(group) do
            reaper.SetMediaItemSelected(it, true)
        end

        reaper.Main_OnCommand(41588, 0) -- Item: Glue items

        local glued = reaper.GetSelectedMediaItem(0, 0)
        if glued then
            reaper.SetMediaItemInfo_Value(glued, "I_CUSTOMCOLOR", COLOR_BREATH)
        end
    end

    reaper.SelectAllMediaItems(0, false)
end

local function prune_short_breaths_in_range(track, r_start, r_end)
    local count = reaper.CountTrackMediaItems(track)
    for i = 0, count - 1 do
        local it = reaper.GetTrackMediaItem(track, i)
        local col = reaper.GetMediaItemInfo_Value(it, "I_CUSTOMCOLOR")
        if col == COLOR_BREATH then
            local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
            local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
            local it_start = pos
            local it_end   = pos + len

            if ranges_overlap(it_start, it_end, r_start, r_end) then
                if len < MIN_BREATH_LEN then
                    reaper.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", 0)
                end
            end
        end
    end
end

local function delete_non_breath_items_in_range(track, r_start, r_end)
    local count = reaper.CountTrackMediaItems(track)
    for i = count - 1, 0, -1 do
        local it = reaper.GetTrackMediaItem(track, i)
        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
        local it_start = pos
        local it_end   = pos + len

        if ranges_overlap(it_start, it_end, r_start, r_end) then
            local col = reaper.GetMediaItemInfo_Value(it, "I_CUSTOMCOLOR")
            if col ~= COLOR_BREATH then
                reaper.DeleteTrackMediaItem(track, it)
            end
        end
    end
end

local function print_breath_item_stats_in_range(track, r_start, r_end)
    if not PRINT_STATS then return end

    if not stats_header_printed then
        reaper.ClearConsole()
        reaper.ShowConsoleMsg("Final Breath Candidates (ZCR/sec, Peak dB, RMS dB):\n\n")
        stats_header_printed = true
    end

    local count = reaper.CountTrackMediaItems(track)
    local index = 1
    for i = 0, count - 1 do
        local it = reaper.GetTrackMediaItem(track, i)
        local col = reaper.GetMediaItemInfo_Value(it, "I_CUSTOMCOLOR")
        if col == COLOR_BREATH then
            local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
            local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
            local it_start = pos
            local it_end   = pos + len

            if ranges_overlap(it_start, it_end, r_start, r_end) then
                local zcr, peak_db, rms_db = compute_item_features(it)
                local msg = string.format(
                    "Item %d: start=%.3f s, len=%.3f s, ZCR/sec=%.2f, Peak=%.2f dB, RMS=%.2f dB\n",
                    index, pos, len, zcr, peak_db, rms_db
                )
                reaper.ShowConsoleMsg(msg)
                index = index + 1
            end
        end
    end
end

------------------------------------------------------------
-- MAIN PER-ITEM PIPELINE (>5 s items only)
------------------------------------------------------------

local function process_long_items_on_breaths_track(track)
    local i = 0

    while true do
        local item_count = reaper.CountTrackMediaItems(track)
        if i >= item_count then break end

        local it = reaper.GetTrackMediaItem(track, i)
        if not it then break end

        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")

        if len <= MIN_SOURCE_ITEM_LEN then
            -- Already-processed or short item: skip entirely
            i = i + 1
        else
            -- This is a source item to process
            local r_start = pos
            local r_end   = pos + len

            -- PASS 1: silence removal on this item
            local intervals = pass1_collect_silence_intervals(it)
            pass1_apply_silence_removal(it, intervals)

            -- PASS 2: Gate 1 on all items overlapping [r_start, r_end] (with edge refinement)
            local current_count = reaper.CountTrackMediaItems(track)
            for j = 0, current_count - 1 do
                local it2 = reaper.GetTrackMediaItem(track, j)
                local pos2 = reaper.GetMediaItemInfo_Value(it2, "D_POSITION")
                local len2 = reaper.GetMediaItemInfo_Value(it2, "D_LENGTH")
                local it2_start = pos2
                local it2_end   = pos2 + len2

                if ranges_overlap(it2_start, it2_end, r_start, r_end) then
                    local splits_local = gate_collect_split_points(
                        it2,
                        G1_WINDOW_S,
                        G1_OPEN_DB,
                        G1_CLOSE_DB,
                        true          -- refine_edges: adjust A/B by up to 100 ms
                    )
                    apply_splits_for_item(it2, splits_local)
                end
            end

            -- PASS 3: Gate 2 (loud-core split) on all items overlapping [r_start, r_end]
            current_count = reaper.CountTrackMediaItems(track)
            for j = 0, current_count - 1 do
                local it3 = reaper.GetTrackMediaItem(track, j)
                local pos3 = reaper.GetMediaItemInfo_Value(it3, "D_POSITION")
                local len3 = reaper.GetMediaItemInfo_Value(it3, "D_LENGTH")
                local it3_start = pos3
                local it3_end   = pos3 + len3

                if ranges_overlap(it3_start, it3_end, r_start, r_end) then
                    local splits_local2 = gate_collect_split_points(
                        it3,
                        G2_WINDOW_S,
                        G2_OPEN_DB,
                        G2_CLOSE_DB,
                        false         -- no refinement for Gate 2 (keep simple)
                    )
                    apply_splits_for_item(it3, splits_local2)
                end
            end

            -- BREATH DETECTION PIPELINE on items within [r_start, r_end]
            classify_items_in_range(track, r_start, r_end, track)
            glue_adjacent_breaths_in_range(track, r_start, r_end)
            prune_short_breaths_in_range(track, r_start, r_end)
            delete_non_breath_items_in_range(track, r_start, r_end)
            print_breath_item_stats_in_range(track, r_start, r_end)

            -- Move index to first item at or after r_end (to avoid reprocessing)
            local new_count = reaper.CountTrackMediaItems(track)
            local next_index = new_count
            for j = 0, new_count - 1 do
                local it2 = reaper.GetTrackMediaItem(track, j)
                local pos2 = reaper.GetMediaItemInfo_Value(it2, "D_POSITION")
                if pos2 >= (r_end - 0.0005) then
                    next_index = j
                    break
                end
            end
            i = next_index
        end
    end
end

------------------------------------------------------------
-- MAIN
------------------------------------------------------------

local function main()
    local track = find_track_by_name("Breaths")
    if not track then
        reaper.ShowMessageBox("Track named 'Breaths' not found.", "Breath Detector", 0)
        return
    end

    local count = reaper.CountTrackMediaItems(track)
    if count == 0 then
        reaper.ShowMessageBox("Track 'Breaths' has no items.", "Breath Detector", 0)
        return
    end

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    process_long_items_on_breaths_track(track)

    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Breath Preparation and Detection (Multi-Gate + Filters)", -1)
end

main()
