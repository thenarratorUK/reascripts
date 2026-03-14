-- Voice Reference Preview from Placeholder
-- Uses region or marker names derived from placeholder text.
-- Placeholder string must contain [number_name], e.g. [06053_Bob]
-- The script extracts "Bob" and looks for a region named "Bob".
-- If no such region exists, it falls back to markers.
--
-- Author: David Winter

-----------------------------------------
-- INTERNAL STATE
-----------------------------------------

local g_restore_cursor_pos  = nil
local g_restore_track       = nil
local g_restore_tsel_start  = nil
local g_restore_tsel_end    = nil
local g_seg_end             = nil   -- project time where reference should end
local g_reference_active    = false
local g_do_nudge            = false

local g_nudging             = false
local g_nudge_end_time      = nil   -- absolute time_precise() for end of nudge

local nudge_timer, start_nudge_timer, restore_state, playback_timer

-- Tracks whose FX should be bypassed during voice reference playback
local VOICE_REF_TRACKS = {
    ["Narration"]  = true,
    ["Internal"]   = true,
    ["System"]     = true,
    ["Special 1"]  = true,
    ["Special 2"]  = true,
    ["Dialogue 1"] = true,
    ["Dialogue 2"] = true,
}

-- Remember original FX enabled state so we can restore it exactly
-- Each entry: { guid = <track_guid_string>, fx = <index>, enabled = <bool> }
local g_fx_state = {}

-----------------------------------------
-- HELPERS
-----------------------------------------

local function clear_state()
    g_restore_cursor_pos  = nil
    g_restore_track       = nil
    g_restore_tsel_start  = nil
    g_restore_tsel_end    = nil
    g_seg_end             = nil
    g_reference_active    = false
    g_do_nudge            = false
    g_nudging             = false
    g_nudge_end_time      = nil
    g_fx_state            = {}
end

local function msg(s)
    reaper.ShowMessageBox(tostring(s), "Voice Reference Preview", 0)
end

local function set_only_track_selected(track)
    reaper.Main_OnCommand(40297, 0) -- Track: Unselect all tracks
    if track and reaper.ValidatePtr(track, "MediaTrack*") then
        reaper.SetTrackSelected(track, true)
    end
end

local function get_item_on_track_at_pos(track, pos)
    if not track then return nil end

    local item_count = reaper.CountTrackMediaItems(track)
    local start_tol  = 1e-6  -- ~1 microsecond tolerance
    local inside_tol = 1e-9

    local best_inside = nil

    for i = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        if item then
            local it_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local it_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            local it_end = it_pos + it_len

            -- 1) If cursor is (essentially) exactly at an item start, prefer that item.
            if math.abs(pos - it_pos) <= start_tol then
                return item
            end

            -- 2) Otherwise: treat end as exclusive to avoid “end item wins at boundary”.
            if (pos >= it_pos - inside_tol) and (pos < it_end - inside_tol) then
                best_inside = item
            end
        end
    end

    return best_inside
end

-- Get the placeholder string:
-- 1) item notes (for empty/text placeholders)
-- 2) active take name
-- 3) active take source filename
local function get_placeholder_string(item)
    if not item then return nil end

    -- First preference: item notes
    local _, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
    if notes and notes ~= "" then
        return notes
    end

    -- Fallback: active take name or source filename
    local take = reaper.GetActiveTake(item)
    if take then
        local ok, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        if ok and name and name ~= "" then
            return name
        end

        local src = reaper.GetMediaItemTake_Source(take)
        if src then
            local buf = reaper.GetMediaSourceFileName(src, "")
            if buf and buf ~= "" then
                return buf
            end
        end
    end

    return nil
end

local function extract_name_from_take_string(take_str)
    if not take_str then return nil end

    -- Primary behaviour:
    -- take everything from the start of the string up to (but not including) the first colon.
    -- e.g. "Florida Man: This is what I say [00234_FloridaMan]" -> "Florida Man"
    local name = take_str:match("^%s*(.-)%s*:")
    if name and name ~= "" then
        return name
    end

    -- Fallback behaviour for older notes that only use [number_name]
    -- Find content inside [ ... ]
    local bracket_content = take_str:match("%[(.-)%]")
    if not bracket_content or bracket_content == "" then
        return nil
    end

    -- Expect something like number_name (e.g. 06053_Bob)
    local num, bracket_name = bracket_content:match("([^_]+)_(.+)")
    if bracket_name and bracket_name ~= "" then
        return bracket_name
    end

    -- Fallback: if no underscore, treat the whole bracket content as name
    return bracket_content
end

local function find_marker_by_name(name)
    if not name or name == "" then return nil, nil end

    local target = name:lower()
    local retval = reaper.CountProjectMarkers(0)
    if retval == 0 then return nil, nil end

    local match_pos = nil

    for i = 0, retval - 1 do
        local _, isrgn, pos, rgnend, mark_name, mark_idx =
            reaper.EnumProjectMarkers3(0, i)
        if not isrgn and mark_name and mark_name:lower() == target then
            if not match_pos or pos < match_pos then
                match_pos = pos
            end
        end
    end

    if not match_pos then
        return nil, nil
    end

    -- Find next marker after match_pos
    local next_pos = nil
    for i = 0, retval - 1 do
        local _, isrgn, pos, rgnend, mark_name, mark_idx =
            reaper.EnumProjectMarkers3(0, i)
        if not isrgn and pos > match_pos then
            if not next_pos or pos < next_pos then
                next_pos = pos
            end
        end
    end

    return match_pos, next_pos -- next_pos may be nil (handled in caller)
end

-- Find the (innermost) region that contains a given position
local function find_region_containing_pos(pos)
    local retval = reaper.CountProjectMarkers(0)
    if retval == 0 then return nil, nil end

    local best_start, best_end = nil, nil

    for i = 0, retval - 1 do
        local _, isrgn, rgn_start, rgn_end, name, idx =
            reaper.EnumProjectMarkers3(0, i)
        if isrgn and rgn_start <= pos and rgn_end > pos then
            if not best_start or (rgn_end - rgn_start) < (best_end - best_start) then
                best_start, best_end = rgn_start, rgn_end
            end
        end
    end

    return best_start, best_end
end

local function find_region_by_name(name)
    if not name or name == "" then return nil, nil end

    local target = name:lower()
    local retval = reaper.CountProjectMarkers(0)
    if retval == 0 then return nil, nil end

    local best_start, best_end = nil, nil

    for i = 0, retval - 1 do
        local _, isrgn, pos, rgnend, rgn_name, rgn_idx =
            reaper.EnumProjectMarkers3(0, i)
        if isrgn and rgn_name and rgn_name:lower() == target then
            if not best_start or pos < best_start then
                best_start = pos
                best_end   = rgnend
            end
        end
    end

    return best_start, best_end -- either or both can be nil
end

local function find_track_by_guid(guid_str)
    if not guid_str then return nil end
    local track_count = reaper.CountTracks(0)
    for i = 0, track_count - 1 do
        local tr = reaper.GetTrack(0, i)
        if tr then
            local g = reaper.GetTrackGUID(tr)
            if g == guid_str then
                return tr
            end
        end
    end
    return nil
end

-- Bypass FX on voice-reference tracks and remember original enabled state
-- If an AllFX / All FX track exists, also bypass all tracks whose name ends
-- with " FX" (including the space), except the AllFX/All FX track itself.
local function bypass_fx_for_voice_tracks()
    g_fx_state = {}

    local proj        = 0
    local track_count = reaper.CountTracks(proj)

    -- First pass: detect whether there is an AllFX / All FX track
    local has_allfx = false
    for i = 0, track_count - 1 do
        local tr = reaper.GetTrack(proj, i)
        if tr then
            local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
            if name == "AllFX" or name == "All FX" then
                has_allfx = true
                break
            end
        end
    end

    -- Second pass: decide which tracks to bypass and store/modify FX state
    for i = 0, track_count - 1 do
        local tr = reaper.GetTrack(proj, i)
        if tr then
            local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)

            local should_bypass = false

            -- Original behaviour: always bypass the core voice-reference tracks
            if name and VOICE_REF_TRACKS[name] then
                should_bypass = true
            end

            -- New behaviour: when AllFX / All FX exists, also bypass any track
            -- whose name ends with " FX" (including the space) EXCEPT AllFX/All FX.
            if has_allfx and name and name ~= "AllFX" and name ~= "All FX" then
                if #name >= 3 and name:sub(-3) == " FX" then
                    should_bypass = true
                end
            end

            if should_bypass then
                local fx_count = reaper.TrackFX_GetCount(tr)
                if fx_count > 0 then
                    local guid = reaper.GetTrackGUID(tr)
                    for fx = 0, fx_count - 1 do
                        local enabled = reaper.TrackFX_GetEnabled(tr, fx)
                        g_fx_state[#g_fx_state + 1] = {
                            guid    = guid,
                            fx      = fx,
                            enabled = enabled,
                        }
                        -- Bypass for the reference playback
                        if enabled then
                            reaper.TrackFX_SetEnabled(tr, fx, false)
                        end
                    end
                end
            end
        end
    end
end

-- Restore FX enabled state exactly as it was
local function restore_fx_for_voice_tracks()
    if not g_fx_state or #g_fx_state == 0 then
        return
    end

    for i = 1, #g_fx_state do
        local entry = g_fx_state[i]
        local tr = find_track_by_guid(entry.guid)
        if tr then
            reaper.TrackFX_SetEnabled(tr, entry.fx, entry.enabled)
        end
    end

    g_fx_state = {}
end

-----------------------------------------
-- VIEW NUDGE (PLAY/STOP AT PLACEHOLDER)
-----------------------------------------

nudge_timer = function()
    if not g_nudging then return end
    local now = reaper.time_precise()
    if now >= g_nudge_end_time then
        -- Stop the tiny nudge playback
        reaper.CSurf_OnStop()
        -- Ensure cursor is exactly back on the placeholder
        if g_restore_cursor_pos then
            reaper.SetEditCurPos(g_restore_cursor_pos, false, false)
        end
        reaper.UpdateArrange()
        clear_state()
        return
    end
    reaper.defer(nudge_timer)
end

start_nudge_timer = function()
    g_nudging = true
    g_nudge_end_time = reaper.time_precise() + 0.05  -- ~50 ms nudge
    reaper.CSurf_OnPlay()
    reaper.defer(nudge_timer)
end

-----------------------------------------
-- RESTORE STATE AFTER REFERENCE
-----------------------------------------

restore_state = function()
    -- Stop playback if still running
    local play_state = reaper.GetPlayState()
    if (play_state & 1) ~= 0 or (play_state & 2) ~= 0 then
        reaper.CSurf_OnStop()
    end

    -- Restore time selection
    if g_restore_tsel_start and g_restore_tsel_end then
        reaper.GetSet_LoopTimeRange2(
            0, true, false,
            g_restore_tsel_start,
            g_restore_tsel_end,
            false
        )
    end

    -- Restore cursor
    if g_restore_cursor_pos then
        reaper.SetEditCurPos(g_restore_cursor_pos, false, false)
    end

    -- Restore track selection
    if g_restore_track and reaper.ValidatePtr(g_restore_track, "MediaTrack*") then
        set_only_track_selected(g_restore_track)
    end

    -- Restore FX enabled/bypassed state on voice-reference tracks
    restore_fx_for_voice_tracks()

    if g_do_nudge and g_restore_cursor_pos then
        -- Let the nudge_timer clear state
        start_nudge_timer()
    else
        reaper.UpdateArrange()
        clear_state()
    end
end

-----------------------------------------
-- PLAYBACK TIMER (REFERENCE SEGMENT)
-----------------------------------------

playback_timer = function()
    if not g_reference_active then return end

    local play_state = reaper.GetPlayState()
    local playing = (play_state & 1) ~= 0
    local paused  = (play_state & 2) ~= 0

    -- If user stopped manually, restore without nudge
    if not playing and not paused then
        g_reference_active = false
        g_do_nudge = false
        restore_state()
        return
    end

    -- Use play position to decide when we've reached seg_end
    local play_pos = reaper.GetPlayPosition()
    if g_seg_end and play_pos >= g_seg_end - 1e-6 then
        g_reference_active = false
        g_do_nudge = true      -- trigger view nudge after restore
        restore_state()
        return
    end

    reaper.defer(playback_timer)
end

-----------------------------------------
-- MAIN
-----------------------------------------

local function main()
    -- If a voice reference playback or nudge is currently running,
    -- treat this call as "finish now": stop and restore state as if it ended naturally.
    if g_reference_active or g_nudging then
        -- Simulate the normal completion path (end of segment):
        -- playback_timer would do:
        --   g_reference_active = false
        --   g_do_nudge = true
        --   restore_state()
        g_reference_active = false
        g_do_nudge = true
        restore_state()
        return
    end

    -- Basic guard: don't start a new reference while normal playback is running
    local play_state = reaper.GetPlayState()
    if (play_state & 1) ~= 0 or (play_state & 2) ~= 0 then
        msg("Please stop playback before running this script.")
        return
    end

    clear_state()

    local proj = 0
    local cur_pos = reaper.GetCursorPosition()
    local sel_track = reaper.GetSelectedTrack(proj, 0)
    if not sel_track then
        msg("No track selected. Please select the track containing the placeholder item.")
        return
    end

    local item = get_item_on_track_at_pos(sel_track, cur_pos)
    if not item then
        msg("No item found at the edit cursor on the selected track.\n\n" ..
            "Make sure the cursor is at the start of the placeholder you want to record.")
        return
    end

    local placeholder_str = get_placeholder_string(item)
    if not placeholder_str or placeholder_str == "" then
        msg("Could not find placeholder text to parse.\n\n" ..
            "Make sure the item notes or take name/source contain [number_name].")
        return
    end

    local name = extract_name_from_take_string(placeholder_str)
    if not name or name == "" then
        msg("Could not extract [number_name] from placeholder text.\n\n" ..
            "Text was:\n" .. tostring(placeholder_str or "(nil)"))
        return
    end

    -- Determine segment start/end:
    -- 1) Prefer region with that name
    -- 2) If none, use marker with that name, and if last marker, use enclosing region end
    local seg_start, seg_end = nil, nil

    -- Try region first
    seg_start, seg_end = find_region_by_name(name)
    if seg_start and seg_end and seg_end > seg_start then
        -- Region found and valid
    else
        -- No valid region; fall back to marker logic
        seg_start, seg_end = find_marker_by_name(name)
        if not seg_start then
            msg("No region or marker found with name: " .. name)
            return
        end

        -- If the marker is inside a region, never let the segment run past that region end.
        -- Otherwise, fall back to the next marker (global), and error if neither exists.
        local r_start, r_end = find_region_containing_pos(seg_start)
        
        if r_end and r_end > seg_start then
            -- Region exists: end at the earlier of (next marker) or (region end).
            if (not seg_end) or (seg_end <= seg_start) or (seg_end > r_end) then
                seg_end = r_end
            end
        else
            -- No enclosing region: we require a next marker to define an end.
            if (not seg_end) or (seg_end <= seg_start) then
                msg("No subsequent marker after \"" .. name ..
                    "\" and no enclosing region to define an end point.")
                return
            end
        end
    end

    local duration = seg_end - seg_start
    if duration <= 0 then
        msg("Segment duration is not positive. Start: " .. tostring(seg_start) ..
            ", End: " .. tostring(seg_end))
        return
    end

    -- Bypass FX on voice-reference tracks while we play the reference
    bypass_fx_for_voice_tracks()

    -- Store state for restore and playback control
    local tsel_start, tsel_end =
        reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
    g_restore_cursor_pos  = cur_pos
    g_restore_track       = sel_track
    g_restore_tsel_start  = tsel_start
    g_restore_tsel_end    = tsel_end
    g_seg_end             = seg_end
    g_reference_active    = true
    g_do_nudge            = false

    -- Set time selection to segment (visual cue)
    reaper.GetSet_LoopTimeRange2(proj, true, false, seg_start, seg_end, false)

    -- Move cursor to segment start and start playback
    reaper.SetEditCurPos(seg_start, false, false)
    reaper.CSurf_OnPlay()

    -- Start position-based playback timer
    reaper.defer(playback_timer)
end

-----------------------------------------
-- EXECUTE
-----------------------------------------

reaper.Undo_BeginBlock2(0)
main()
reaper.Undo_EndBlock2(0, "Preview voice reference from placeholder (timed, clean, with view nudge)", -1)
