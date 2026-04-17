-- @description Ripple Punch-In (Placeholder-Aware Toggle)
-- @version 1.6
-- @author David Winter
--[[
  ReaScript Name : Ripple Punch-In (Placeholder-Aware Toggle)
  Author         : David Winter
  Version        : 1.6

  Behaviour
  ---------

  WHEN NOT RECORDING:
    - On the first selected track:
        * From the edit cursor, locate the next run of items on that track
          and compute the end of that run (first empty point after it).
        * SAFETY: Between the cursor position and that run end, all items
          on the selected track must be empty (no active take). If not,
          abort with a warning.
    - Temporarily enable pre-roll (if currently off).
    - Invoke a custom "Ripple Insert Start" action that:
        * Splits any items at the cursor on the selected track only.
        * Inserts gap from the cursor to the next placeholder boundary.
        * Starts recording at the cursor.
    - Defer a tiny function to restore pre-roll to its original state
      after the action has run.

  WHEN RECORDING:
    - Call the corresponding custom "Ripple Insert End" action that:
        * Stops recording.
        * Ends the ripple insert (pulls later items to close the gap).
    - Optionally update parent automation envelopes to ensure that the
      newly recorded line will have appropriate FX in future passes.
    - Move selection to the track containing the next placeholder item
      in time, if any, skipping:
        * Room tone track(s)
        * Any tracks without items at that time

  IMPORTANT: This script relies on two custom actions:

    1)  RIPPLE_INSERT_START_ID
        A custom action that:
          - Splits item(s) at cursor on the selected track
          - Inserts space from cursor to "next placeholder boundary"
          - Starts recording

    2)  RIPPLE_INSERT_END_ID
        A custom action that:
          - Ends recording
          - Ends the ripple insert (closing the gap)

  You should create those custom actions yourself, with the appropriate
  commands and assign them to action IDs. Then update the NamedCommandLookup
  hashes below with the correct command IDs (or use your own _RS... IDs).

--]]

------------------------------------------------------------
-- User-configurable IDs for the custom actions
------------------------------------------------------------

-- "Ripple Insert Start" custom action (as a NamedCommandLookup string)
local RIPPLE_INSERT_START_ID = "_RSd1c489a0d9b9421ebd3b96989f5db52e33996b54" -- UPDATE IF NEEDED

-- "Ripple Insert End" custom action (as a NamedCommandLookup string)
local RIPPLE_INSERT_END_ID   = "_RS6cfebbb60815f52c4988a51ff317e3e26cf6a7cd" -- UPDATE IF NEEDED

------------------------------------------------------------
-- Constants
------------------------------------------------------------
-- Toggle: set to false if you want to disable per-segment FX automation updates
local FX_UPDATE = true
local NAME_ALL_FX = "All FX"


local TOL = 1e-6

------------------------------------------------------------
-- Pre-roll state (captured at script start)
------------------------------------------------------------
local preRollOrig = reaper.GetToggleCommandStateEx(0, 41819)  -- Transport: Toggle pre-roll

-- ExtState used to remember the track we recorded ON
-- before this script switches selection to the next track.
local PH_SECTION = "DW_RippleInsertPlaceholder"
local PH_KEY_LAST_TRACK_GUID = "LastRecordedTrackGUID"

------------------------------------------------------------
-- Helper: select only one track
------------------------------------------------------------
local function select_only_track(track)
    if not track then return end
    local proj = 0
    local ct = reaper.CountTracks(proj)
    for i = 0, ct - 1 do
        local tr = reaper.GetTrack(proj, i)
        reaper.SetTrackSelected(tr, tr == track)
    end
end

------------------------------------------------------------
-- Helper: extract speaker prefix from item notes ("Jeff:" -> "Jeff")
------------------------------------------------------------
local function get_item_speaker_prefix(item)
    if not item then return nil end
    local ok, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
    if not ok then return nil end
    if not notes or notes == "" then return nil end

    -- Trim whitespace
    notes = notes:match("^%s*(.-)%s*$") or notes

    -- Take text before the first colon
    local speaker = notes:match("^([^:]+):")
    if not speaker then return nil end

    -- Trim spaces around the speaker name
    speaker = speaker:match("^%s*(.-)%s*$") or speaker
    if speaker == "" then return nil end

    return speaker
end

------------------------------------------------------------
-- Helper: identify the Room Tone track by name
------------------------------------------------------------
local function is_room_tone_track(track)
    if not track then return false end

    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if not name or name == "" then return false end

    name = name:lower()

    -- Adjust this if your room tone track uses a different naming convention
    if name:find("room") and name:find("tone") then
        return true
    end

    return false
end

------------------------------------------------------------
-- Helper: find the earliest item that starts at exactly `time_pos`
-- (within tolerance), preferring the lowest track index
-- and skipping room tone tracks.
------------------------------------------------------------
local function find_item_starting_at(time_pos)
    local item_count = reaper.CountMediaItems(0)
    local best_item, best_track_index = nil, nil

        for i = 0, item_count - 1 do
        local it  = reaper.GetMediaItem(0, i)
        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        if math.abs(pos - time_pos) <= TOL then
            local tr = reaper.GetMediaItem_Track(it)

            -- Skip Room Tone track entirely
            if not is_room_tone_track(tr) then
                local idx = reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") or 0
                if not best_item or idx < best_track_index then
                    best_item = it
                    best_track_index = idx
                end
            end
        end
    end

    return best_item
end

------------------------------------------------------------
-- Helper: find the next placeholder item on ANY track after
-- a given reference position, skipping:
--   - room tone tracks
--   - the specified excluded_track
--
-- Returns that item or nil.
------------------------------------------------------------
local function find_next_item_on_different_track(excluded_track, ref_pos)
    local item_count = reaper.CountMediaItems(0)
    local best_item = nil
    local best_pos  = nil

    for i = 0, item_count - 1 do
        local it  = reaper.GetMediaItem(0, i)
        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
                local tr  = reaper.GetMediaItem_Track(it)

        if tr ~= excluded_track
           and not is_room_tone_track(tr)
           and pos >= ref_pos - TOL then
            if not best_item or pos < best_pos then
                best_item = it
                best_pos  = pos
            end
        end
    end

    return best_item
end

------------------------------------------------------------
-- Helper: safety check for placeholder-only deletion on a TRACK
--
-- Returns true if EVERY item on `track` overlapping [start_pos .. end_pos)
-- has NO active take (i.e. empty item). If any item has an active take,
-- returns false.
------------------------------------------------------------
local function range_is_all_empty_on_track(track, start_pos, end_pos)
    if not track then return true end

    local item_count = reaper.CountTrackMediaItems(track)

    for i = 0, item_count - 1 do
        local it  = reaper.GetTrackMediaItem(track, i)
        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
        local it_end = pos + len

        -- Check overlap with [start_pos, end_pos)
        if it_end > start_pos + TOL and pos < end_pos - TOL then
            local take = reaper.GetActiveTake(it)
            if take and not reaper.TakeIsMIDI(take) then
                -- Non-empty audio take
                return false
            end
        end
    end

    return true
end

------------------------------------------------------------
-- Helpers for parent track detection & item regions
------------------------------------------------------------
local function auto_get_parent_track(child_track)
    if not child_track then return nil end

    local proj = 0
    local num_tracks = reaper.CountTracks(proj)
    local target_index = reaper.GetMediaTrackInfo_Value(child_track, "IP_TRACKNUMBER") - 1

    local current_parent = nil
    local folder_depth = 0

    for i = 0, num_tracks - 1 do
        local tr = reaper.GetTrack(proj, i)
        local depth = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")

        if depth > 0 then
            folder_depth = folder_depth + depth
            current_parent = tr
        elseif depth < 0 then
            folder_depth = folder_depth + depth
            if depth == -1 then
                current_parent = nil
            end
        end

        if i == target_index then
            return current_parent
        end
    end

    return current_parent
end

local function auto_get_sorted_items_on_track(track)
    local items = {}
    local proj = 0
    local total_items = reaper.CountMediaItems(proj)

    for i = 0, total_items - 1 do
        local it = reaper.GetMediaItem(proj, i)
        if reaper.GetMediaItem_Track(it) == track then
            table.insert(items, it)
        end
    end

    table.sort(items, function(a, b)
        local sa = reaper.GetMediaItemInfo_Value(a, "D_POSITION")
        local sb = reaper.GetMediaItemInfo_Value(b, "D_POSITION")
        if sa == sb then
            local la = reaper.GetMediaItemInfo_Value(a, "D_LENGTH")
            local lb = reaper.GetMediaItemInfo_Value(b, "D_LENGTH")
            return la < lb
        end
        return sa < sb
    end)

    return items
end

local function auto_compute_first_region(items)
    if not items or #items == 0 then
        return nil, nil
    end

    local EPS = 0.0000001

    local first = items[1]
    local region_start = reaper.GetMediaItemInfo_Value(first, "D_POSITION")
    local region_end   = region_start + reaper.GetMediaItemInfo_Value(first, "D_LENGTH")

    for idx = 2, #items do
        local it = items[idx]
        local s  = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        if s <= region_end + EPS then
            local e = s + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
            if e > region_end then region_end = e end
        else
            break
        end
    end

    return region_start, region_end
end

local function auto_find_segment_for_time(items, ref_time)
    if not items or #items == 0 then
        return nil, nil
    end

    local EPS = 0.0000001

    local hit_idx = nil
    for i, it in ipairs(items) do
        local s = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        local e = s + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
        if ref_time >= s - EPS and ref_time < e + EPS then
            hit_idx = i
            break
        end
    end

    if not hit_idx then
        return nil, nil
    end

    local seg_start = reaper.GetMediaItemInfo_Value(items[hit_idx], "D_POSITION")
    local seg_end   = seg_start + reaper.GetMediaItemInfo_Value(items[hit_idx], "D_LENGTH")

    -- Expand backwards to include adjacent/overlapping items
    local j = hit_idx - 1
    while j >= 1 do
        local it_prev = items[j]
        local s_prev  = reaper.GetMediaItemInfo_Value(it_prev, "D_POSITION")
        local e_prev  = s_prev + reaper.GetMediaItemInfo_Value(it_prev, "D_LENGTH")

        if e_prev >= seg_start - EPS then
            if s_prev < seg_start then seg_start = s_prev end
            if e_prev > seg_end then seg_end = e_prev end
            j = j - 1
        else
            break
        end
    end

    -- Expand forwards to include adjacent/overlapping items
    j = hit_idx + 1
    while j <= #items do
        local it_next   = items[j]
        local s_next    = reaper.GetMediaItemInfo_Value(it_next, "D_POSITION")
        local e_next    = s_next + reaper.GetMediaItemInfo_Value(it_next, "D_LENGTH")

        if s_next <= seg_end + EPS then
            if e_next > seg_end then seg_end = e_next end
            j = j + 1
        else
            break
        end
    end

    return seg_start, seg_end
end

------------------------------------------------------------
-- Automation helper: update per-segment send mute envelopes
------------------------------------------------------------

local function auto_eval_env_at_time(env, time)
    if not env then return nil end
    local ok, val = reaper.Envelope_Evaluate(env, time, 0, 0)
    if not ok then return nil end
    return val
end

local function auto_get_active_envelopes(track)
    local envs = {}
    if not track then return envs end

    local env_count = reaper.CountTrackEnvelopes(track)
    for i = 0, env_count - 1 do
        local env = reaper.GetTrackEnvelope(track, i)
        if env then
            table.insert(envs, env)
        end
    end
    return envs
end

local function auto_apply_four_point_block(env, seg_start, seg_end, template_val)
    if not env then return end

    local EPS = 0.0000001
    local before_time = seg_start - EPS
    local after_time  = seg_end   + EPS

    local before_val = auto_eval_env_at_time(env, before_time)
    local after_val  = auto_eval_env_at_time(env, after_time)
    if before_val == nil or after_val == nil then
        return
    end

    reaper.InsertEnvelopePoint(env, before_time, before_val, 0, 0, false, true)
    reaper.InsertEnvelopePoint(env, seg_start,   template_val, 0, 0, false, true)
    reaper.InsertEnvelopePoint(env, seg_end,     template_val, 0, 0, false, true)
    reaper.InsertEnvelopePoint(env, after_time,  after_val,    0, 0, false, true)

    reaper.Envelope_SortPoints(env)
end

-- Send-routing helpers for per-segment FX send mute updates
local function get_track_name(tr)
    if not tr then return nil end
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    return name
end

local function get_track_by_name(name)
    local proj = 0
    local track_count = reaper.CountTracks(proj)
    for i = 0, track_count - 1 do
        local tr = reaper.GetTrack(proj, i)
        local _, tr_name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
        if tr_name == name then
            return tr
        end
    end
    return nil
end

local function get_track_index(tr)
    if not tr then return nil end
    local num = reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")
    if not num or num <= 0 then return nil end
    return math.floor(num - 1 + 0.5)
end

local function ends_with_fx(name)
    return name:sub(-3) == " FX"
end

local function get_send_index(src_tr, dst_tr)
    if not src_tr or not dst_tr then return -1 end
    local category = 0 -- sends
    local num_sends = reaper.GetTrackNumSends(src_tr, category)
    for i = 0, num_sends - 1 do
        local dest_ptr = reaper.GetTrackSendInfo_Value(src_tr, category, i, "P_DESTTRACK")
        if dest_ptr == dst_tr then
            return i
        end
    end
    return -1
end

local function get_send_mute_envelope(src_tr, send_idx, dest_name)
    if not src_tr or not dest_name then return nil end
    if send_idx < 0 then return nil end

    local env_name1 = "Send mute: " .. dest_name
    local env = reaper.GetTrackEnvelopeByName(src_tr, env_name1)
    if env then return env end

    local env_name2 = "Send mute " .. tostring(send_idx + 1)
    env = reaper.GetTrackEnvelopeByName(src_tr, env_name2)
    if env then return env end

    return nil
end

local function auto_update_parent_automation_for_segment(child_track, ref_time)
    if not child_track or not ref_time then return end

    -- Resolve core tracks
    local all_fx_tr = get_track_by_name(NAME_ALL_FX)
    if not all_fx_tr then return end

    local child_name = get_track_name(child_track)
    if not child_name or child_name == "" then return end

    local all_fx_idx = get_track_index(all_fx_tr)
    local child_idx  = get_track_index(child_track)
    if not all_fx_idx or not child_idx then return end
    if child_idx >= all_fx_idx then
        -- Not a character track in the pre-All FX section
        return
    end

    -- Determine whether this is a child of a character parent (folder)
    local parent_src_tr   = auto_get_parent_track(child_track)
    local parent_src_name = nil

    if parent_src_tr then
        parent_src_name = get_track_name(parent_src_tr)
        if not parent_src_name or parent_src_name == "" then
            parent_src_tr = nil
        elseif ends_with_fx(parent_src_name) then
            -- Parent is an FX track, not a character parent
            parent_src_tr = nil
        else
            local parent_idx = get_track_index(parent_src_tr)
            if not parent_idx or parent_idx >= all_fx_idx then
                -- Parent is not in the character section
                parent_src_tr = nil
            end
        end
    end

    -- Find the just-recorded segment on the child track
    local items = auto_get_sorted_items_on_track(child_track)
    if #items == 0 then return end

    local seg_start, seg_end = auto_find_segment_for_time(items, ref_time)
    if not seg_start then return end

    -- Unmute the relevant send(s) across this segment (0 = unmuted, 1 = muted)
    if parent_src_tr then
        --------------------------------------------------------
        -- Child of a parent character track
        --   All FX   -> Parent FX
        --   Parent FX -> Child FX
        --------------------------------------------------------
        local parent_fx_name = parent_src_name .. " FX"
        local parent_fx_tr   = get_track_by_name(parent_fx_name)

        if parent_fx_tr then
            local send_idx = get_send_index(all_fx_tr, parent_fx_tr)
            if send_idx >= 0 then
                local env = get_send_mute_envelope(all_fx_tr, send_idx, parent_fx_name)
                if env then
                    auto_apply_four_point_block(env, seg_start, seg_end, 0.0)
                end
            end
        end

        local child_fx_name = child_name .. " FX"
        local child_fx_tr   = get_track_by_name(child_fx_name)

        if parent_fx_tr and child_fx_tr then
            local send_idx2 = get_send_index(parent_fx_tr, child_fx_tr)
            if send_idx2 >= 0 then
                local env2 = get_send_mute_envelope(parent_fx_tr, send_idx2, child_fx_name)
                if env2 then
                    auto_apply_four_point_block(env2, seg_start, seg_end, 0.0)
                end
            end
        end
    else
        --------------------------------------------------------
        -- Standalone character track (no character parent)
        --   All FX -> Child FX
        --------------------------------------------------------
        local child_fx_name = child_name .. " FX"
        local child_fx_tr   = get_track_by_name(child_fx_name)
        if child_fx_tr then
            local send_idx = get_send_index(all_fx_tr, child_fx_tr)
            if send_idx >= 0 then
                local env = get_send_mute_envelope(all_fx_tr, send_idx, child_fx_name)
                if env then
                    auto_apply_four_point_block(env, seg_start, seg_end, 0.0)
                end
            end
        end
    end
end

------------------------------------------------------------
-- MAIN
------------------------------------------------------------
local function main()
    local play_state = reaper.GetPlayState()
    local is_recording = (play_state & 4) ~= 0

    if not is_recording then
        ------------------------------------------------------
        -- PHASE 1: PRE-RECORD (START)
        ------------------------------------------------------
        local sel_track = reaper.GetSelectedTrack(0, 0)

        if not sel_track then
            -- Fallback: just call Ripple Insert Start as-is
            local start_cmd = reaper.NamedCommandLookup(RIPPLE_INSERT_START_ID)
            if start_cmd ~= 0 then reaper.Main_OnCommand(start_cmd, 0) end
            return
        end

        local cursor_pos = reaper.GetCursorPosition()
        local boundary_pos = find_next_no_item_pos(sel_track, cursor_pos)
        if not boundary_pos then
            -- Fallback: behave like plain Ripple Insert Start
            local start_cmd = reaper.NamedCommandLookup(RIPPLE_INSERT_START_ID)
            if start_cmd ~= 0 then reaper.Main_OnCommand(start_cmd, 0) end
            return
        end

        -- SAFETY: ensure [cursor_pos .. boundary_pos] on the CURRENT track
        -- contains only empty items (placeholders). If any have audio, abort.
        if boundary_pos > cursor_pos + TOL then
            if not range_is_all_empty_on_track(sel_track, cursor_pos, boundary_pos) then
                reaper.ShowMessageBox(
                    "Ripple Punch-In aborted: non-placeholder material found between the cursor and the next placeholder run.\n\nNo changes were made.",
                    "Ripple Punch-In Safety",
                    0
                )
                return
            end
        end

        reaper.Undo_BeginBlock()
        reaper.PreventUIRefresh(1)
        
        -- Tighten tail of previous item before enabling pre-roll / starting punch
                local tighten_cmd = reaper.NamedCommandLookup("_RScc7a2992f12cbb80648c30e818cf748a1aed74b1")
                if tighten_cmd ~= 0 then
                    reaper.Main_OnCommand(tighten_cmd, 0)
                end

        -- Temporarily enable pre-roll if it was off
        local need_restore_preroll = false
        if preRollOrig == 0 then
            reaper.Main_OnCommand(41819, 0)  -- Toggle pre-roll ON
            need_restore_preroll = true
        end

        -- Call Ripple Insert Start (splits, inserts space, and starts recording)
        local start_cmd = reaper.NamedCommandLookup(RIPPLE_INSERT_START_ID)
        if start_cmd ~= 0 then
            reaper.Main_OnCommand(start_cmd, 0)
        end

        -- Defer restoration of pre-roll so it remains on briefly
        if need_restore_preroll then
            local t0 = reaper.time_precise()
            local function restore_preroll()
                if reaper.time_precise() - t0 < 0.1 then
                    reaper.defer(restore_preroll)
                else
                    reaper.Main_OnCommand(41819, 0)  -- Toggle pre-roll OFF
                end
            end
            reaper.defer(restore_preroll)
        end

        reaper.PreventUIRefresh(-1)
        reaper.Undo_EndBlock("Ripple Punch-In Placeholder Start", -1)
        return
    end

    ------------------------------------------------------
    -- PHASE 2: POST-RECORD (END)
    ------------------------------------------------------
    local track_before_end = reaper.GetSelectedTrack(0, 0)
    
    -- Store the GUID of the track we are *ending from* so that
        -- Smart Ripple Insert can later restore selection to this
        -- track when fixing a mistake after a placeholder pass.
        if track_before_end then
            local guid = reaper.GetTrackGUID(track_before_end)
            if guid then
                reaper.SetExtState(PH_SECTION, PH_KEY_LAST_TRACK_GUID, guid, false)
            end
        end
        
    -- End Ripple Insert (cursor ends at record_end)
    local end_cmd = reaper.NamedCommandLookup(RIPPLE_INSERT_END_ID)
    if end_cmd ~= 0 then
        reaper.Main_OnCommand(end_cmd, 0)
    end

    local record_end = reaper.GetCursorPosition()

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)
   
    -- Optional: update parent automation so future pre-roll plays this line with correct FX
    if FX_UPDATE and track_before_end then
        auto_update_parent_automation_for_segment(track_before_end, record_end)
    end

    -- 1) Find the item that starts at record_end (within tolerance)
    local next_item = find_item_starting_at(record_end)
    if next_item then
        local next_track = reaper.GetMediaItem_Track(next_item)

        -- Select the track of this "next item"
        select_only_track(next_track)

        -- 2) On that track, find the first time there is no item
        local no_item_pos = find_next_no_item_pos(next_track, record_end)
        local orig_no_item_pos = no_item_pos

        -- Speaker-aware tweak:
        -- if this item has a "Speaker:" prefix in notes, and there is
        -- another item on the same track with a *different* prefix
        -- before the first gap, end the deletion at that item's start.
        do
            local speaker = get_item_speaker_prefix(next_item)
            if speaker and no_item_pos then
                local item_count = reaper.CountTrackMediaItems(next_track)
                local start_index = nil

                -- Find index of next_item on this track
                for i = 0, item_count - 1 do
                    local it = reaper.GetTrackMediaItem(next_track, i)
                    if it == next_item then
                        start_index = i
                        break
                    end
                end

                if start_index then
                    for i = start_index + 1, item_count - 1 do
                        local it = reaper.GetTrackMediaItem(next_track, i)
                        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")

                        -- Only care about items in the same contiguous run
                        -- (before the first gap we already found)
                        if pos >= record_end - TOL and pos < no_item_pos - TOL then
                            local sp = get_item_speaker_prefix(it)
                            if (not sp) or (sp ~= speaker) then
                                no_item_pos = pos
                                break
                            end
                        end
                    end
                end
            end
        end

        if no_item_pos and no_item_pos > record_end + TOL then
            -- 3) Remove contents [record_end .. no_item_pos] across ALL tracks
            reaper.GetSet_LoopTimeRange(true, false, record_end, no_item_pos, false)
            reaper.Main_OnCommand(40201, 0)  -- Time selection: Remove contents (moving later items)
            reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)
        end

                -- 4) After ripple, decide whether to stay on this track or move to another

        local stay_on_same_track = false
        do
            local speaker = get_item_speaker_prefix(next_item)
            if speaker then
                local item_count = reaper.CountTrackMediaItems(next_track)
                local has_same_speaker = false

                for i = 0, item_count - 1 do
                    local it = reaper.GetTrackMediaItem(next_track, i)
                    local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
                    if pos >= record_end - TOL and pos < (orig_no_item_pos or (record_end + 999999)) then
                        local sp = get_item_speaker_prefix(it)
                        if sp == speaker then
                            has_same_speaker = true
                            break
                        end
                    end
                end

                stay_on_same_track = has_same_speaker
            end
        end

        if stay_on_same_track then
            -- Keep selection on next_track
            select_only_track(next_track)
            reaper.Main_OnCommand(40913, 0)  -- Track: Vertical scroll selected tracks into view
        else
            -- Original behaviour: jump to the next placeholder on a DIFFERENT track
            local another_item = find_next_item_on_different_track(next_track, record_end)
            if another_item then
                local another_track = reaper.GetMediaItem_Track(another_item)
                select_only_track(another_track)
                reaper.Main_OnCommand(40913, 0)  -- Track: Vertical scroll selected tracks into view
            end
        end
    end

    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Ripple Punch-In Placeholder End", -1)
end

main()