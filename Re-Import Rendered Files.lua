-- DW – Rebuild Breaths Track From Renders
--
-- Behaviour:
--  - Saves current ripple-edit state and turns ripple off.
--  - Finds track named "Breaths".
--  - Finds region "00 Opening Credits" and processes all regions after it.
--  - Phase 1: For each later region, if there are no items on "Breaths"
--             overlapping that region, inserts the corresponding render
--             (preferring .wav, else .mp3) from the project's Renders folder.
--  - Asks: "Replace Previously Analysed Breath Regions?"
--  - If Yes: For each later region with >1 item on "Breaths", deletes those
--            items and re-imports the region render as a single item.
--  - Restores ripple-edit state and exits.

-----------------------------------------
-- CONFIG
-----------------------------------------

local BREATHS_TRACK_NAME   = "Breaths"
local OPENING_REGION_NAME  = "00 Opening Credits"
local RENDERS_SUBFOLDER    = "Renders"  -- relative to project directory

-----------------------------------------
-- HELPERS: RIPPLE EDIT
-----------------------------------------

local function save_and_disable_ripple()
    local ripple_all = reaper.GetToggleCommandState(40311) -- ripple all tracks
    local ripple_per = reaper.GetToggleCommandState(40310) -- ripple per-track

    -- Turn ripple off (if any variant is active)
    if ripple_all == 1 then
        reaper.Main_OnCommand(40311, 0)
    end
    if ripple_per == 1 then
        reaper.Main_OnCommand(40310, 0)
    end

    return ripple_all, ripple_per
end

local function restore_ripple(ripple_all, ripple_per)
    if ripple_all == 1 then
        reaper.Main_OnCommand(40311, 0) -- toggle back on
    end
    if ripple_per == 1 then
        reaper.Main_OnCommand(40310, 0) -- toggle back on
    end
end

-----------------------------------------
-- HELPERS: TRACK / REGIONS
-----------------------------------------

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

local function get_regions_after_opening(opening_name)
    local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
    local total = num_markers + num_regions

    local opening_pos = nil
    local all_regions = {}

    for i = 0, total - 1 do
        local retval, isrgn, pos, rgnend, name, idx = reaper.EnumProjectMarkers3(0, i)
        if retval then
            if isrgn then
                if name == opening_name then
                    opening_pos = pos
                end
                all_regions[#all_regions+1] = { start = pos, fin = rgnend, name = name }
            end
        end
    end

    if not opening_pos then
        return nil, "Region '" .. opening_name .. "' not found."
    end

    local regions = {}
    for _, r in ipairs(all_regions) do
        if r.start > opening_pos then
            regions[#regions+1] = r
        end
    end

    table.sort(regions, function(a, b) return a.start < b.start end)

    return regions, nil
end

local function get_items_on_track_in_range(track, r_start, r_end)
    local items = {}
    local cnt = reaper.CountTrackMediaItems(track)
    for i = 0, cnt - 1 do
        local it = reaper.GetTrackMediaItem(track, i)
        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
        local it_start = pos
        local it_end   = pos + len
        if it_end > r_start and it_start < r_end then
            items[#items+1] = it
        end
    end
    return items
end

-----------------------------------------
-- HELPERS: PROJECT PATH / RENDERS
-----------------------------------------

local function get_project_directory()
    local _, proj_fn = reaper.EnumProjects(-1, "")
    if not proj_fn or proj_fn == "" then
        return nil, "Project must be saved before running this script."
    end
    local dir = proj_fn:match("^(.*[\\/])")
    if not dir then
        return nil, "Unable to determine project directory."
    end
    return dir, nil
end

-- Normalise a name for fuzzy matching:
--  - lowercase
--  - remove extension (if you pass a full filename)
--  - replace punctuation with spaces
--  - collapse repeated spaces
--  - trim
local function normalize_for_match(s)
    s = s or ""
    s = s:lower()
    -- strip extension if present (e.g. ".wav", ".mp3", ".flac")
    s = s:gsub("%.%w+$", "")
    -- replace punctuation and control chars with spaces
    s = s:gsub("[%p%c]+", " ")
    -- collapse multiple spaces
    s = s:gsub("%s+", " ")
    -- trim
    s = s:match("^%s*(.-)%s*$") or s
    return s
end

local function find_render_file_for_region(renders_dir, region_name)
    -- Normalised key for the region
    local region_norm = normalize_for_match(region_name)

    local best_wav = nil
    local best_mp3 = nil

    local i = 0
    while true do
        local fname = reaper.EnumerateFiles(renders_dir, i)
        if not fname then break end

        local lower = fname:lower()
        local base_norm = normalize_for_match(fname)

        -- Basic heuristic: either the region norm appears in the filename norm
        -- or vice versa (handles cases where one is shorter)
        if base_norm:find(region_norm, 1, true) or region_norm:find(base_norm, 1, true) then
            if lower:sub(-4) == ".wav" then
                best_wav = fname
            elseif lower:sub(-4) == ".mp3" and not best_mp3 then
                best_mp3 = fname
            end
        end

        i = i + 1
    end

    if best_wav then
        return renders_dir .. best_wav
    elseif best_mp3 then
        return renders_dir .. best_mp3
    else
        return nil
    end
end

local function insert_render_item_for_region(track, r_start, r_end, src_path)
    local src = reaper.PCM_Source_CreateFromFile(src_path)
    if not src then
        return false, "Could not create source from file:\n" .. src_path
    end

    local item = reaper.AddMediaItemToTrack(track)
    if not item then
        return false, "Failed to create media item on Breaths track."
    end

    reaper.SetMediaItemInfo_Value(item, "D_POSITION", r_start)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", r_end - r_start)

    local take = reaper.AddTakeToMediaItem(item)
    if not take then
        return false, "Failed to create take on media item."
    end

    reaper.SetMediaItemTake_Source(take, src)
    reaper.UpdateItemInProject(item)

    return true, nil
end

-----------------------------------------
-- MAIN LOGIC
-----------------------------------------

local function main()
    -- Save and disable ripple
    local ripple_all, ripple_per = save_and_disable_ripple()

    -- Ensure ripple is restored even on error
    local function finalize()
        restore_ripple(ripple_all, ripple_per)
        reaper.UpdateArrange()
    end

    local ok, err = pcall(function()

        reaper.Undo_BeginBlock()
        reaper.PreventUIRefresh(1)

        -- Find Breaths track
        local breaths_track = find_track_by_name(BREATHS_TRACK_NAME)
        if not breaths_track then
            reaper.PreventUIRefresh(-1)
            reaper.Undo_EndBlock("Rebuild Breaths Track From Renders (failed: track not found)", -1)
            reaper.ShowMessageBox("Track '" .. BREATHS_TRACK_NAME .. "' not found.", "Rebuild Breaths", 0)
            return
        end

        -- Get project directory and Renders folder
        local proj_dir, perr = get_project_directory()
        if not proj_dir then
            reaper.PreventUIRefresh(-1)
            reaper.Undo_EndBlock("Rebuild Breaths Track From Renders (failed: no project dir)", -1)
            reaper.ShowMessageBox(perr, "Rebuild Breaths", 0)
            return
        end

        local renders_dir = proj_dir .. RENDERS_SUBFOLDER .. "/"

        -- Get regions after "00 Opening Credits"
        local regions, rerr = get_regions_after_opening(OPENING_REGION_NAME)
        if not regions then
            reaper.PreventUIRefresh(-1)
            reaper.Undo_EndBlock("Rebuild Breaths Track From Renders (failed: opening region)", -1)
            reaper.ShowMessageBox(rerr, "Rebuild Breaths", 0)
            return
        end

        -- Phase 1: For each later region, if Breaths track has no items, import render
        local missing_count = 0
        for _, r in ipairs(regions) do
            local items = get_items_on_track_in_range(breaths_track, r.start, r.fin)
            if #items == 0 then
                local src_path = find_render_file_for_region(renders_dir, r.name)
                if src_path then
                    local ok_insert, ierr = insert_render_item_for_region(breaths_track, r.start, r.fin, src_path)
                    if not ok_insert then
                        reaper.ShowMessageBox(ierr, "Rebuild Breaths", 0)
                    else
                        missing_count = missing_count + 1
                    end
                else
                    reaper.ShowMessageBox(
                        "No render file found in:\n" .. renders_dir ..
                        "\nfor region name:\n" .. r.name,
                        "Rebuild Breaths", 0
                    )
                end
            end
        end

        -- Ask about replacing previously analysed regions
        local answer = reaper.ShowMessageBox(
            "Replace Previously Analysed Breath Regions?\n\n" ..
            "(This will delete regions on '" .. BREATHS_TRACK_NAME ..
            "' that have been split into multiple items\n" ..
            "and re-import the original rendered file for those regions.)",
            "Rebuild Breaths – Second Pass",
            4 -- Yes/No
        )

        if answer == 6 then  -- Yes
            for _, r in ipairs(regions) do
                local items = get_items_on_track_in_range(breaths_track, r.start, r.fin)
                if #items > 1 then
                    -- Delete all items in this region
                    for i = #items, 1, -1 do
                        reaper.DeleteTrackMediaItem(breaths_track, items[i])
                    end

                    -- Re-import region render
                    local src_path = find_render_file_for_region(renders_dir, r.name)
                    if src_path then
                        local ok_insert, ierr = insert_render_item_for_region(breaths_track, r.start, r.fin, src_path)
                        if not ok_insert then
                            reaper.ShowMessageBox(ierr, "Rebuild Breaths", 0)
                        end
                    else
                        reaper.ShowMessageBox(
                            "No render file found in:\n" .. renders_dir ..
                            "\nfor region name:\n" .. r.name,
                            "Rebuild Breaths", 0
                        )
                    end
                end
            end
        end

        reaper.PreventUIRefresh(-1)
        reaper.Undo_EndBlock("Rebuild Breaths Track From Renders", -1)
    end)

    finalize()

    if not ok then
        reaper.ShowMessageBox("Error in script:\n\n" .. tostring(err), "Rebuild Breaths", 0)
    end
end

main()
