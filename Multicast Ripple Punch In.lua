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
    - Call your RIPPLE INSERT START script (which splits and inserts space).
    - After ~0.1s, restore the original pre-roll state.

  WHEN RECORDING:
    - Call your RIPPLE INSERT END script.
      (This closes the inserted gap, fixes room tone, and leaves the cursor
       at the end of the just-recorded item.)
    - Let record_end = current edit cursor position.
    - Find the item that starts at record_end (within tolerance),
      on ANY track. Select the track that item is on.
    - On that track, find the first time there is no item when moving
      forward from record_end (treat overlapping/adjacent items as a run).
    - Create a time selection [record_end .. no_item_pos] and run:
          40201 = Time selection: Remove contents of time selection
                  (moving later items).
    - Then find the next item starting at/after record_end on a DIFFERENT
      track and select that track.
]]

------------------------------------------------------------
-- CONFIG: Update these with your actual custom action IDs
------------------------------------------------------------
local RIPPLE_INSERT_START_ID = "_RS65a3b3b1e39ff25c5c9bd0d1967b3892461cff42"
local RIPPLE_INSERT_END_ID   = "_RS6cca0e2eccfc3cbd563bf061c39b9a4e540c0382"

-- Pre-roll (measures) to use during Ripple Insert Start
local PREROLLMEAS_DURING_INSERT = 0.175

------------------------------------------------------------
-- Constants
------------------------------------------------------------
-- Toggle: set to false if you want to disable per-segment FX automation updates
local FX_UPDATE = true
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
-- Helper: get the last recorded track from ExtState
------------------------------------------------------------
local function get_last_recorded_track()
    local guid_str = reaper.GetExtState(PH_SECTION, PH_KEY_LAST_TRACK_GUID)
    if not guid_str or guid_str == "" then
        return nil
    end

    local proj = 0
    local track_count = reaper.CountTracks(proj)
    for i = 0, track_count - 1 do
        local tr = reaper.GetTrack(proj, i)
        local tr_guid = reaper.GetTrackGUID(tr)
        if tr_guid == guid_str then
            return tr
        end
    end

    return nil
end

-----------------------------------------------------------------------
-- Helper: find_next_no_item_pos(track, cursor_pos)
-----------------------------------------------------------------------
local function find_next_no_item_pos(track, cursor_pos)
    if not track then return nil end

    local item_count = reaper.CountTrackMediaItems(track)
    if item_count == 0 then
        return cursor_pos
    end

    local run_idx = nil

    -- Decide where the next run of items begins
    for i = 0, item_count - 1 do
        local it  = reaper.GetTrackMediaItem(track, i)
        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
        local it_end = pos + len

        if cursor_pos >= pos - TOL and cursor_pos < it_end - TOL then
            -- Cursor inside this item ⇒ run starts here
            run_idx = i
            break
        elseif pos > cursor_pos + TOL then
            -- Cursor in gap before a later item ⇒ run starts there
            run_idx = i
            break
        end
    end

    -- If nothing found, cursor is after all items
    if not run_idx then
        return cursor_pos
    end

    -- Walk forward through contiguous/overlapping items
    local it  = reaper.GetTrackMediaItem(track, run_idx)
    local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    local group_end = pos + len

    for i = run_idx + 1, item_count - 1 do
        local it2    = reaper.GetTrackMediaItem(track, i)
        local pos2   = reaper.GetMediaItemInfo_Value(it2, "D_POSITION")
        local len2   = reaper.GetMediaItemInfo_Value(it2, "D_LENGTH")
        local it2end = pos2 + len2

        if pos2 <= group_end + TOL then
            if it2end > group_end then
                group_end = it2end
            end
        else
            break
        end
    end

    return group_end
end

------------------------------------------------------------
-- Helper: select only a given track
------------------------------------------------------------
local function select_only_track(track)
    if not track then return end
    local ct = reaper.CountTracks(0)
    for i = 0, ct - 1 do
        local tr = reaper.GetTrack(0, i)
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
    if name == "room tone" then return true end
    if name:find("room tone", 1, true) then return true end

    return false
end

------------------------------------------------------------
-- Helper: find the earliest item at or after a given time
-- (skipping Room Tone), preferring lower track index.
------------------------------------------------------------
local function find_item_starting_at(time_pos)
    local item_count = reaper.CountMediaItems(0)
    local best_item, best_pos, best_track_index = nil, nil, nil

    -- Slightly looser tolerance for "at ref time"
    local SEARCH_TOL = 1e-4

    for i = 0, item_count - 1 do
        local it  = reaper.GetMediaItem(0, i)
        local tr  = reaper.GetMediaItem_Track(it)
        if not is_room_tone_track(tr) then
            local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
            -- Accept items starting a tiny bit before ref time (due to rounding),
            -- but overall choose the earliest item at/after time_pos.
            if pos >= time_pos - SEARCH_TOL then
                local idx = reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") or 0
                if not best_item
                   or pos < best_pos - TOL
                   or (math.abs(pos - best_pos) <= TOL and idx < best_track_index)
                then
                    best_item       = it
                    best_pos        = pos
                    best_track_index = idx
                end
            end
        end
    end

    return best_item
end

------------------------------------------------------------
-- Helper: find the next item at/after ref_pos on a DIFFERENT track
------------------------------------------------------------
local function find_next_item_on_different_track(excluded_track, ref_pos)
    local item_count = reaper.CountMediaItems(0)
    local best_item, best_pos = nil, nil

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
            if take ~= nil then
                -- Found non-empty item in this range
                return false
            end
        end
    end

    return true
end

------------------------------------------------------------
-- Automation helper: update parent automation for one segment
-- Derived directly from "Copy Parent Automation..." logic
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

local function auto_get_parent_track(child_track)
    if not child_track then return nil end

    local proj = 0
    local num_tracks = reaper.CountTracks(proj)

    -- IP_TRACKNUMBER is 1-based; convert to 0-based
    local target_index = reaper.GetMediaTrackInfo_Value(child_track, "IP_TRACKNUMBER")
    if not target_index then return nil end
    target_index = math.floor(target_index + 0.5) - 1

    local current_parent = nil
    local folder_depth   = 0

    for i = 0, num_tracks - 1 do
        -- IMPORTANT: stop BEFORE processing the target track’s depth.
        -- A folder with I_FOLDERDEPTH = -1 is still the parent of this track;
        -- it closes AFTER the last child, not before.
        if i == target_index then
            break
        end

        local tr    = reaper.GetTrack(proj, i)
        local depth = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")

        if depth > 0 then
            folder_depth  = folder_depth + depth
            current_parent = tr
        elseif depth < 0 then
            folder_depth = folder_depth + depth
            if folder_depth <= 0 then
                current_parent = nil
            end
        end
    end

    return current_parent
end

local function auto_resolve_parent_or_self(track)
    if not track then return nil end

    local depth_sel = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") or 0

    -- If this track is itself a folder parent, treat it as the automation parent
    if depth_sel > 0 then
        return track
    end

    -- Otherwise, try to find a folder parent above
    local parent = auto_get_parent_track(track)
    if parent then
        return parent
    end

    -- No folder parent found -> standalone track; automation lives here
    return track
end

-- All FX / Parent FX helpers
local function auto_get_track_name(tr)
    if not tr then return "" end
    local _, name = reaper.GetTrackName(tr, "")
    return name or ""
end

local function auto_get_track_by_exact_name(name)
    if not name or name == "" then return nil end
    local proj = 0
    local track_count = reaper.CountTracks(proj)
    for i = 0, track_count - 1 do
        local tr = reaper.GetTrack(proj, i)
        local _, n = reaper.GetTrackName(tr, "")
        if n == name then
            return tr
        end
    end
    return nil
end

local function auto_find_allfx_track()
    -- Support both "All FX" and "AllFX"
    local tr = auto_get_track_by_exact_name("All FX")
    if tr then return tr end
    return auto_get_track_by_exact_name("AllFX")
end

local function auto_get_parent_fx_track(parent_track)
    if not parent_track then return nil end
    local name = auto_get_track_name(parent_track)
    if name == "" then return nil end
    local fx_name = name .. " FX"
    return auto_get_track_by_exact_name(fx_name)
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

-- Direct copy of compute_first_region (max_time not needed here, so pass nil)
local function auto_compute_first_region(items)
    if not items or #items == 0 then
        return nil, nil, 0
    end

    local EPS = 0.0000001

    local first = items[1]
    local region_start = reaper.GetMediaItemInfo_Value(first, "D_POSITION")
    local region_end   = region_start + reaper.GetMediaItemInfo_Value(first, "D_LENGTH")
    local last_idx     = 1

    for idx = 2, #items do
        local it = items[idx]
        local s  = reaper.GetMediaItemInfo_Value(it, "D_POSITION")

        if s <= region_end + EPS then
            local e = s + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
            if e > region_end then region_end = e end
            last_idx = idx
        else
            break
        end
    end

    return region_start, region_end, last_idx
end

-- Direct copy of build_segments_from_items, used to define segments after first region
local function auto_build_segments_from_items(items, last_ref_idx)
    local segments = {}
    if not items or #items <= last_ref_idx then
        return segments
    end

    local EPS = 0.0000001
    local i = last_ref_idx + 1

    while i <= #items do
        local it = items[i]
        local seg_start = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        local seg_end   = seg_start + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")

        local j = i + 1
        while j <= #items do
            local it_next = items[j]
            local next_start = reaper.GetMediaItemInfo_Value(it_next, "D_POSITION")
            local next_end   = next_start + reaper.GetMediaItemInfo_Value(it_next, "D_LENGTH")

            if next_start <= seg_end + EPS then
                if next_end > seg_end then
                    seg_end = next_end
                end
                j = j + 1
            else
                break
            end
        end

        table.insert(segments, { start = seg_start, stop = seg_end })
        i = j
    end

    return segments
end

local function auto_apply_four_point_block(env, seg_start, seg_end, template_val)
    if not env then return end

    local EPS = 0.0000001

    -- Times:
    --  P1: seg_start - EPS              (outer, pre-segment value)
    --  P2: seg_start                    (inner, template value)
    --  P3: seg_end - 2*EPS              (inner, template value, further inside)
    --  P4: seg_end - EPS                (outer, return to baseline, just before segment end)
    --
    -- We still sample the "after" value slightly after seg_end, but we no longer
    -- place a point exactly at seg_end; the last point is now just before it.
    local before_time       = seg_start - EPS
    local inner_start       = seg_start
    local inner_end         = seg_end - 2*EPS
    if inner_end <= inner_start then
        inner_end = inner_start
    end
    local outer_end         = seg_end - EPS
    local sample_after_time = seg_end + EPS

    local before_val = auto_eval_env_at_time(env, before_time)
    local after_val  = auto_eval_env_at_time(env, sample_after_time)
    if before_val == nil or after_val == nil then
        return
    end

    -- Insert 4 points: outer-before, inner-start, inner-end, outer-end
    reaper.InsertEnvelopePoint(env, before_time, before_val,    0, 0, false, true)
    reaper.InsertEnvelopePoint(env, inner_start, template_val,  0, 0, false, true)
    reaper.InsertEnvelopePoint(env, inner_end,   template_val,  0, 0, false, true)

    -- Force the last point back to the same baseline as P1
    reaper.InsertEnvelopePoint(env, outer_end,   before_val,    0, 0, false, true)

    reaper.Envelope_SortPoints(env)
end

------------------------------------------------------------
-- Helper: wipe relevant envelopes from just before a time onward
--  - On the automation track for the currently selected track:
--      * Parent track, or "<Parent Name> FX" if AllFX exists
------------------------------------------------------------
local function auto_wipe_all_track_envelopes_from_time(start_time)
    local proj = 0
    local BIG  = 10e9

    -- Nudge deletion a tiny amount earlier than the cursor position
    local EPS          = 1e-5
    local delete_start = start_time - EPS
    if delete_start < 0 then
        delete_start = 0
    end

    -- 1) Get the currently selected track
    local sel_track = reaper.GetSelectedTrack(proj, 0)
    if not sel_track then
        return
    end

    -- 2) Resolve its parent/automation parent
    local parent_track = auto_get_parent_track(sel_track)
    if not parent_track then
        parent_track = sel_track  -- standalone case
    end

    -- 3) Detect AllFX and Parent FX
    local all_fx_tr        = auto_find_allfx_track()
    local automation_track = parent_track
    local parent_fx_tr     = nil

    if all_fx_tr then
        parent_fx_tr = auto_get_parent_fx_track(parent_track)
        if parent_fx_tr then
            automation_track = parent_fx_tr
        else
            -- AllFX exists but no "<Parent Name> FX" track:
            -- safer to bail than to wipe the wrong place.
            return
        end
    end

    -- 4) Wipe all envelopes on the automation track from delete_start onward
    local env_count = reaper.CountTrackEnvelopes(automation_track)
    for e = 0, env_count - 1 do
        local env = reaper.GetTrackEnvelope(automation_track, e)
        if env then
            reaper.DeleteEnvelopePointRange(env, delete_start, BIG)
        end
    end
end

-- New: update only the segment that contains ref_time, using the folder-aware template
local function auto_update_parent_automation_for_segment(child_track, ref_time)
    if not child_track or not ref_time then return end

    -- 1) Resolve parent (folder) track exactly as in the working script
    local parent_track = auto_get_parent_track(child_track)
    if not parent_track then
        parent_track = child_track
    end

    local parent_envs = auto_get_active_envelopes(parent_track)
    if #parent_envs == 0 then
        return
    end

    -- 2) Items and first region on THIS child track
    local items = auto_get_sorted_items_on_track(child_track)
    if #items == 0 then
        return
    end

    local region_start, region_end, last_idx = auto_compute_first_region(items)
    if not region_start or last_idx == 0 then
        return
    end

    local src_mid = (region_start + region_end) * 0.5

    -- 3) Template values from midpoint of the child's first region
    local template_values = {}
    for _, env in ipairs(parent_envs) do
        local v = auto_eval_env_at_time(env, src_mid)
        if v ~= nil then
            template_values[env] = v
        end
    end

    -- 4) Build all later segments (as in the full script)
    local segments = auto_build_segments_from_items(items, last_idx)
    if #segments == 0 then
        -- No later segments: nothing to update
        return
    end

    -- 5) Pick the segment that contains (or is just before) ref_time
    local EPS = 0.0000001
    local chosen = nil

    for _, seg in ipairs(segments) do
        if ref_time >= seg.start - EPS and ref_time <= seg.stop + EPS then
            chosen = seg
            break
        end
        -- optimisation: if ref_time is before this segment, we can stop
        if ref_time < seg.start - EPS then
            break
        end
    end

    if not chosen then
        -- Fallback: if ref_time is after all segments, use the last one
        if ref_time > segments[#segments].stop + EPS then
            chosen = segments[#segments]
        else
            return
        end
    end

    -- 6) Apply the 4-point block ONLY on this chosen segment
    for _, env in ipairs(parent_envs) do
        local tpl = template_values[env]
        if tpl ~= nil then
            auto_apply_four_point_block(env, chosen.start, chosen.stop, tpl)
        end
    end
end

------------------------------------------------------------
-- Update parent automation for the segment just trimmed
-- cursor_pos = position where the trim started (and new record will start)
------------------------------------------------------------
local function auto_update_parent_automation_for_trimmed_segment(cursor_pos)
    local proj = 0
    local item_count = reaper.CountMediaItems(proj)
    local EPS = 1e-6

    -- 1) Find the item (with audio) whose END is at cursor_pos, skipping Room Tone
    local trimmed_item = nil
    for i = 0, item_count - 1 do
        local it  = reaper.GetMediaItem(proj, i)
        local tr  = reaper.GetMediaItem_Track(it)
        if not is_room_tone_track(tr) then
            local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
            local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
            local it_end = pos + len

            if math.abs(it_end - cursor_pos) <= EPS then
                local take = reaper.GetActiveTake(it)
                if take ~= nil then
                    trimmed_item = it
                    break
                end
            end
        end
    end

    if not trimmed_item then
        return
    end

    -- 2) Child track is the track that item lives on
    local child_track = reaper.GetMediaItem_Track(trimmed_item)
    if not child_track then return end

    -- 3) Collect all items on that child track, sorted (same as Copy Automation)
    local items = auto_get_sorted_items_on_track(child_track)
    if #items == 0 then return end

    -- Find index of trimmed_item in the sorted list
    local trimmed_index = nil
    for idx, it in ipairs(items) do
        if it == trimmed_item then
            trimmed_index = idx
            break
        end
    end
    if not trimmed_index then return end

    -- 4) Build the contiguous segment ending at cursor_pos by walking backwards
    local seg_end = cursor_pos
    local seg_start = reaper.GetMediaItemInfo_Value(trimmed_item, "D_POSITION")

    local j = trimmed_index - 1
    while j >= 1 do
        local it_prev = items[j]
        local s = reaper.GetMediaItemInfo_Value(it_prev, "D_POSITION")
        local e = s + reaper.GetMediaItemInfo_Value(it_prev, "D_LENGTH")

        -- Treat as contiguous/overlapping if the previous item ends at or after
        -- the current seg_start (with small epsilon)
        if e >= seg_start - EPS then
            if s < seg_start then
                seg_start = s
            end
            j = j - 1
        else
            break
        end
    end

    -- 5) Determine the parent automation track (folder parent if present,
    --    otherwise this track itself if standalone / folder-parent)
    local parent_track = auto_resolve_parent_or_self(child_track)
    if not parent_track then
        return
    end

    -- Detect All FX / Parent FX architecture. By default we write automation
    -- directly on the parent track, but if an All FX/AllFX bus exists we
    -- instead use "<Parent Name> FX" as the automation track.
    local automation_track = parent_track
    local all_fx_tr        = auto_find_allfx_track()
    local parent_fx_tr     = nil

    if all_fx_tr then
        parent_fx_tr = auto_get_parent_fx_track(parent_track)
        if not parent_fx_tr then
            local parent_name = auto_get_track_name(parent_track)
            reaper.ShowMessageBox(
                "Multicast Ripple Punch In: Found an All FX track but no matching '"
                .. parent_name .. " FX' track for automation.\n\n"
                .. "Please run your Build Character FX Tracks and Sends script or fix the track layout.",
                "Multicast Ripple Punch In",
                0
            )
            return
        end
        automation_track = parent_fx_tr
    end

    local parent_envs = auto_get_active_envelopes(automation_track)
    if #parent_envs == 0 then
        return
    end

    -- 6) Compute the "first region" on this child track (same as full script)
    local region_start, region_end, _ = auto_compute_first_region(items)
    if not region_start or not region_end then
        return
    end

    -- Midpoint of the first region is where we sample template values
    local src_mid = (region_start + region_end) * 0.5

    local template_values = {}
    for _, env in ipairs(parent_envs) do
        local v = auto_eval_env_at_time(env, src_mid)
        if v ~= nil then
            template_values[env] = v
        end
    end

    -- 7) Apply the 4-point block over [seg_start .. seg_end] on all parent envelopes
    for _, env in ipairs(parent_envs) do
        local tpl = template_values[env]
        if tpl ~= nil then
            auto_apply_four_point_block(env, seg_start, seg_end, tpl)
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
        -- contains only empty items (placeholders). If any have audio,
        -- play that region once and then jump to the next placeholder.
        if boundary_pos > cursor_pos + TOL then
            if not range_is_all_empty_on_track(sel_track, cursor_pos, boundary_pos) then

                local play_start = cursor_pos
                local play_end   = boundary_pos
                local duration   = play_end - play_start

                -- If we somehow get a non-positive duration, just fall back
                -- to directly jumping to the next line.
                if duration <= 0 then
                    local next_item = find_item_starting_at(boundary_pos)
                    if next_item then
                        local next_track = reaper.GetMediaItem_Track(next_item)
                        if next_track then
                            select_only_track(next_track)
                            local next_pos = reaper.GetMediaItemInfo_Value(next_item, "D_POSITION")
                            reaper.SetEditCurPos(next_pos, true, false)
                            reaper.Main_OnCommand(40913, 0)  -- Track: Vertical scroll selected tracks into view
                        end
                    end
                    return
                end

                -- Prepare and start playback of the existing audio from cursor_pos
                select_only_track(sel_track)
                reaper.SetEditCurPos(play_start, true, false)
                reaper.Main_OnCommand(40913, 0)   -- Track: Vertical scroll selected tracks into view
                reaper.Main_OnCommand(1007, 0)    -- Transport: Play

                local t0 = reaper.time_precise()

                local function after_play()
                    -- Wait approximately for the item-length duration
                    if reaper.time_precise() - t0 < duration then
                        reaper.defer(after_play)
                        return
                    end

                    -- Stop playback and move cursor to the end of the played region
                    reaper.Main_OnCommand(1016, 0)  -- Transport: Stop
                    reaper.SetEditCurPos(play_end, true, false)

                    -- Now behave as if we'd just "skipped" that line:
                    -- select the next placeholder at/after boundary_pos
                    local next_item = find_item_starting_at(boundary_pos)
                    if next_item then
                        local next_track = reaper.GetMediaItem_Track(next_item)
                        if next_track then
                            select_only_track(next_track)
                            local next_pos = reaper.GetMediaItemInfo_Value(next_item, "D_POSITION")
                            reaper.SetEditCurPos(next_pos, true, false)
                            reaper.Main_OnCommand(40913, 0)  -- Track: Vertical scroll selected tracks into view
                        end
                    end
                end

                reaper.defer(after_play)
                return
            end
        end
        reaper.Undo_BeginBlock()
        reaper.PreventUIRefresh(1)
        
        -- Cursor position at which we are starting the new punch
        local cursor_pos = reaper.GetCursorPosition()

        -- NEW: wipe all automation points on all tracks from this point onward
        -- (this avoids stale automation surviving into future segments)
        auto_wipe_all_track_envelopes_from_time(cursor_pos)
        
        -- Tighten tail of previous item before enabling pre-roll / starting punch
        local tighten_cmd = reaper.NamedCommandLookup("_RScc7a2992f12cbb80648c30e818cf748a1aed74b1")
        if tighten_cmd ~= 0 then
            reaper.Main_OnCommand(tighten_cmd, 0)
        end

        --------------------------------------------------------------------
        -- NEW: Run Global Reset (time-selection-only) for send mutes ONLY,
        -- handing off send-mute rebuilding to the reset script.
        --------------------------------------------------------------------

        do
            -- a) Save existing time selection, edit cursor, and selected track
            local saved_ts_start, saved_ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
            local saved_cursor = reaper.GetCursorPosition()
            local saved_track  = reaper.GetSelectedTrack(0, 0)

            -- Also preserve the prior ExtState value so we can restore it
            local TS_EXTSTATE_SECTION = "DW_RESET_CHAR_FX_SENDS"
            local TS_EXTSTATE_KEY     = "TIME_SELECTION_ONLY"
            local saved_ext = reaper.GetExtState(TS_EXTSTATE_SECTION, TS_EXTSTATE_KEY) or ""

            -- b) Determine the “last recorded item” (the item that now ends at the cursor),
            -- prefer the currently selected item if it matches; otherwise search globally.
            local function is_room_tone_track_local(track)
                if not track then return false end
                local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
                name = (name or ""):lower()
                if name == "room tone" then return true end
                if name:find("room tone", 1, true) then return true end
                return false
            end

            local function get_selected_item_if_valid(target_end, eps)
                local it = reaper.GetSelectedMediaItem(0, 0)
                if not it then return nil end
                if reaper.CountSelectedMediaItems(0) ~= 1 then return nil end

                local tr = reaper.GetMediaItem_Track(it)
                if is_room_tone_track_local(tr) then return nil end

                local take = reaper.GetActiveTake(it)
                if not take then return nil end

                local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
                local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
                local it_end = pos + len

                if math.abs(it_end - target_end) <= eps then
                    return it
                end
                return nil
            end

            local function find_item_ending_at(target_end, eps)
                local item_count = reaper.CountMediaItems(0)
                for i = 0, item_count - 1 do
                    local it = reaper.GetMediaItem(0, i)
                    local tr = reaper.GetMediaItem_Track(it)
                    if not is_room_tone_track_local(tr) then
                        local take = reaper.GetActiveTake(it)
                        if take then
                            local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
                            local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
                            local it_end = pos + len
                            if math.abs(it_end - target_end) <= eps then
                                return it
                            end
                        end
                    end
                end
                return nil
            end

            local EPS_END = 1e-6
            local cursor_now = reaper.GetCursorPosition()

            local target_item = get_selected_item_if_valid(cursor_now, EPS_END)
            if not target_item then
                target_item = find_item_ending_at(cursor_now, EPS_END)
            end

            if target_item then
                -- Select the item + its track (so the reset script has a clear context)
                reaper.Main_OnCommand(40289, 0) -- Unselect all items
                reaper.SetMediaItemSelected(target_item, true)

                local item_track = reaper.GetMediaItem_Track(target_item)
                if item_track then
                    select_only_track(item_track)
                end

        -- Create a time selection over the item (padded)
        local it_pos = reaper.GetMediaItemInfo_Value(target_item, "D_POSITION")
        local it_len = reaper.GetMediaItemInfo_Value(target_item, "D_LENGTH")
        local it_end = it_pos + it_len
        
        local PAD = 0.005 -- 5ms each side (adjust as needed)
        
        if it_end > it_pos + TOL then
          local ts_start = it_pos - PAD
          if ts_start < 0 then ts_start = 0 end
        
          local ts_end = it_end + PAD
          if ts_end <= ts_start + TOL then
            ts_end = ts_start + TOL
          end
        
          reaper.GetSet_LoopTimeRange(true, false, ts_start, ts_end, false)

                    -- c) Force reset script into time-selection-only mode via ExtState
                    reaper.SetExtState(TS_EXTSTATE_SECTION, TS_EXTSTATE_KEY, "1", false)

                    -- d) Run the reset script
                    local reset_cmd = reaper.NamedCommandLookup("_RS717452610c79955f32bf0f877f52250c83b69757")
                    if reset_cmd ~= 0 then
                        reaper.Main_OnCommand(reset_cmd, 0)
                    end
                end
            end

            -- e) Restore saved state (ExtState, time selection, cursor, selected track)
            reaper.SetExtState(TS_EXTSTATE_SECTION, TS_EXTSTATE_KEY, saved_ext, false)

            if saved_ts_end and saved_ts_start and (saved_ts_end > saved_ts_start + TOL) then
                reaper.GetSet_LoopTimeRange(true, false, saved_ts_start, saved_ts_end, false)
            else
                reaper.GetSet_LoopTimeRange(true, false, 0, 0, false)
            end

            reaper.SetEditCurPos(saved_cursor, false, false)

            if saved_track then
                select_only_track(saved_track)
            end
        end

        -- Immediately after tightening, update automation for the segment that just ended
        if FX_UPDATE then
            local cursor_pos = reaper.GetCursorPosition()
            auto_update_parent_automation_for_trimmed_segment(cursor_pos)
        end

        -- Temporarily enable pre-roll if it was off
        local need_restore_preroll = false
        if preRollOrig == 0 then
            reaper.Main_OnCommand(41819, 0)  -- Toggle pre-roll ON
            need_restore_preroll = true
        end

    -- Save current pre-roll value, set temporary value for Ripple Insert Start
    local saved_prerollmeas = nil
    if type(reaper.get_config_var_string) == "function" then
      local ok, s = reaper.get_config_var_string("prerollmeas")
      if ok then saved_prerollmeas = tonumber(s) end
    end
    
    if saved_prerollmeas ~= nil and type(reaper.SNM_SetDoubleConfigVar) == "function" then
      reaper.SNM_SetDoubleConfigVar("prerollmeas", PREROLLMEAS_DURING_INSERT)
    end
    
    -- Call Ripple Insert Start (splits, inserts space, and starts recording)
    local start_cmd = reaper.NamedCommandLookup(RIPPLE_INSERT_START_ID)
    if start_cmd ~= 0 then
      reaper.Main_OnCommand(start_cmd, 0)
    end
    
    -- Restore original pre-roll value immediately after Ripple Insert Start is called
    if saved_prerollmeas ~= nil and type(reaper.SNM_SetDoubleConfigVar) == "function" then
      reaper.SNM_SetDoubleConfigVar("prerollmeas", saved_prerollmeas)
    end

        -- Defer restoration of pre-roll so it remains on briefly
        if need_restore_preroll then
            local t0 = reaper.time_precise()
            local function restore_preroll()
                if reaper.time_precise() - t0 < 0.1 then
                    reaper.defer(restore_preroll)
                else
                    reaper.Main_OnCommand(41819, 0)  -- Toggle pre-roll back OFF
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
                                -- Different (or missing) speaker prefix:
                                -- end deletion at this item's start.
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

        -- Did we shorten no_item_pos compared to the original run end?
        local used_speaker_tweak = false
        if orig_no_item_pos and no_item_pos
           and no_item_pos < orig_no_item_pos - TOL then
            used_speaker_tweak = true
        end

        if used_speaker_tweak then
            -- We deliberately stopped at the next speaker on the SAME track.
            -- Keep this track selected, and just scroll it into view.
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
