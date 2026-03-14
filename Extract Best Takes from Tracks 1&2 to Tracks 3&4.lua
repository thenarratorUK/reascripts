--[[
Green-region extractor + assembler

Pass 1:
  - Regions R1..R269
Pass 2:
  - Regions R270..R608

For each pass:
  1) Find all *green* regions in the range
  2) Sort by region name: 1.x, 2.x, ... 16a.x, 16b.x, ... 42.x
  3) For each region in order:
       - Set time selection to region
       - Split items on Tracks 1 and 2 at region start and end
       - Copy the resulting items that lie inside the region to Tracks 3 and 4,
         starting at point A (initially project start for pass 1),
         preserving offsets within the region.
       - Label the copied items (and their active take) with the region name
       - Advance A by region length
  4) After finishing the pass, set A = 10 seconds after the last item end on Tracks 3/4

Assumptions:
  - Tracks 1..4 exist.
  - Regions are correctly named (e.g. "16a.2") and coloured green.
  - "Green" is detected by RGB dominance (works for medium/dark green as well as bright green).

--]]

local EPS = 1e-9

local function msg(title, text)
  reaper.ShowMessageBox(text, title, 0)
end

local function get_track_1based(n)
  return reaper.GetTrack(0, n - 1)
end

local function is_green_region(color)
  -- Only treat custom-coloured regions as candidates
  if not color or color == 0 then return false end
  if (color & 0x1000000) == 0 then return false end

  local native = color & 0xFFFFFF
  local r, g, b = reaper.ColorFromNative(native)

  -- "Green" heuristic: green must dominate clearly.
  -- Works for (0,128,0), (0,255,0), etc.
  if not r or not g or not b then return false end
  return (g >= 80) and (g >= r + 40) and (g >= b + 40)
end

local function parse_region_name_for_sort(name)
  -- Expected: "16a.7" or "16b.1" or "12.3"
  -- Returns a tuple used for sorting.
  -- Unknown formats are pushed to the end, then by name.
  local line, letter, take = name:match("^(%d+)([a-z]?)%.(%d+)$")
  if not line then
    return { 1e9, 1e9, 1e9, tostring(name) }
  end

  line = tonumber(line)
  take = tonumber(take)

  local letter_order
  if letter == "" then
    letter_order = 0
  elseif letter == "a" then
    letter_order = 1
  elseif letter == "b" then
    letter_order = 2
  else
    letter_order = 9
  end

  return { line, letter_order, take, tostring(name) }
end

local function sort_regions(regions)
  table.sort(regions, function(a, b)
    local ka = a.sortkey
    local kb = b.sortkey
    for i = 1, 4 do
      if ka[i] ~= kb[i] then
        return ka[i] < kb[i]
      end
    end
    return a.name < b.name
  end)
end

local function get_regions_in_range(range_start, range_end)
  local regions = {}
  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = num_markers + num_regions

  for i = 0, total - 1 do
    local ok, isrgn, pos, rgnend, name, marknum, color = reaper.EnumProjectMarkers3(0, i)
    if ok and isrgn and marknum >= range_start and marknum <= range_end then
      if is_green_region(color) then
        regions[#regions + 1] = {
          num = marknum,
          pos = pos,
          rgnend = rgnend,
          name = name,
          color = color,
          sortkey = parse_region_name_for_sort(name)
        }
      end
    end
  end

  sort_regions(regions)
  return regions
end

local function set_time_selection(start_time, end_time)
  reaper.GetSet_LoopTimeRange(true, false, start_time, end_time, false)
end

local function clear_item_selection()
  reaper.Main_OnCommand(40289, 0) -- Unselect all items
end

local function split_items_on_track_at(track, t)
  -- Split any item that straddles time t.
  local item_count = reaper.GetTrackNumMediaItems(track)
  for i = item_count - 1, 0, -1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local fin = pos + len

    if (pos + EPS) < t and t < (fin - EPS) then
      reaper.SplitMediaItem(item, t)
    end
  end
end

local function split_items_on_track_to_region(track, start_time, end_time)
  split_items_on_track_at(track, start_time)
  split_items_on_track_at(track, end_time)
end

local function get_items_fully_within(track, start_time, end_time)
  local items = {}
  local item_count = reaper.GetTrackNumMediaItems(track)

  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local fin = pos + len

    if (pos >= start_time - EPS) and (fin <= end_time + EPS) and (len > EPS) then
      -- Only include items that actually intersect the region span
      if pos < end_time - EPS and fin > start_time + EPS then
        items[#items + 1] = item
      end
    end
  end

  return items
end

local function copy_item_to_track_at(item, dest_track, dest_pos, region_name)
  local src_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local src_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  local new_item = reaper.AddMediaItemToTrack(dest_track)
  reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", dest_pos)
  reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", src_len)

  -- Copy fades (harmless if zero)
  reaper.SetMediaItemInfo_Value(new_item, "D_FADEINLEN",  reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN"))
  reaper.SetMediaItemInfo_Value(new_item, "D_FADEOUTLEN", reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"))
  reaper.SetMediaItemInfo_Value(new_item, "D_FADEINDIR",  reaper.GetMediaItemInfo_Value(item, "D_FADEINDIR"))
  reaper.SetMediaItemInfo_Value(new_item, "D_FADEOUTDIR", reaper.GetMediaItemInfo_Value(item, "D_FADEOUTDIR"))

  -- Source take -> new take
  local src_take = reaper.GetActiveTake(item)
  if src_take then
    local src_source = reaper.GetMediaItemTake_Source(src_take)

    local new_take = reaper.AddTakeToMediaItem(new_item)
    reaper.SetActiveTake(new_take)
    reaper.SetMediaItemTake_Source(new_take, src_source)

    -- Copy take offset + rate (enough to preserve the exact audio segment)
    reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", reaper.GetMediaItemTakeInfo_Value(src_take, "D_STARTOFFS"))
    reaper.SetMediaItemTakeInfo_Value(new_take, "D_PLAYRATE",  reaper.GetMediaItemTakeInfo_Value(src_take, "D_PLAYRATE"))

    -- Label take
    reaper.GetSetMediaItemTakeInfo_String(new_take, "P_NAME", region_name, true)
  end

  -- Label item as well (useful for item lanes / tooltips)
  reaper.GetSetMediaItemInfo_String(new_item, "P_NAME", region_name, true)

  return new_item, src_pos, src_len
end

local function get_track_max_end(track)
  local max_end = 0.0
  local item_count = reaper.GetTrackNumMediaItems(track)
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local fin = pos + len
    if fin > max_end then max_end = fin end
  end
  return max_end
end

local function process_region_list(regions, A_start)
  local t1 = get_track_1based(1)
  local t2 = get_track_1based(2)
  local t3 = get_track_1based(3)
  local t4 = get_track_1based(4)

  if not (t1 and t2 and t3 and t4) then
    msg("Assemble Green Regions", "Tracks 1..4 must exist.")
    return A_start, { "ERROR: missing Track 1..4" }
  end

  local A = A_start
  local log = {}

  for _, r in ipairs(regions) do
    local r_start = r.pos
    local r_end   = r.rgnend
    local r_len   = r_end - r_start

    if r_len <= EPS then
      log[#log + 1] = ("Skipped region '%s' (zero/negative length)"):format(r.name)
      goto continue_region
    end

    set_time_selection(r_start, r_end)

    -- Ensure hard boundaries on Tracks 1 & 2
    split_items_on_track_to_region(t1, r_start, r_end)
    split_items_on_track_to_region(t2, r_start, r_end)

    -- Collect items fully within the region on Tracks 1 & 2
    local items1 = get_items_fully_within(t1, r_start, r_end)
    local items2 = get_items_fully_within(t2, r_start, r_end)

    if (#items1 == 0) and (#items2 == 0) then
      log[#log + 1] = ("No items found in region '%s' on Tracks 1/2"):format(r.name)
      A = A + r_len
      goto continue_region
    end

    -- Copy, preserving offsets within the region:
    -- dest_pos = A + (src_item_pos - region_start)
    for _, it in ipairs(items1) do
      local src_pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local dest_pos = A + (src_pos - r_start)
      copy_item_to_track_at(it, t3, dest_pos, r.name)
    end

    for _, it in ipairs(items2) do
      local src_pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local dest_pos = A + (src_pos - r_start)
      copy_item_to_track_at(it, t4, dest_pos, r.name)
    end

    -- Advance A to the end of this region block
    A = A + r_len

    ::continue_region::
  end

  -- After the pass, set A to 10 seconds after the last item end on Tracks 3/4
  local end3 = get_track_max_end(get_track_1based(3))
  local end4 = get_track_max_end(get_track_1based(4))
  local max_end = (end3 > end4) and end3 or end4
  A = max_end + 10.0

  return A, log
end

-- ---------------- Main ----------------

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

clear_item_selection()

local A = 0.0 -- Point A starts at project start for the first pass

-- Pass 1: R1..R269
local regions_1 = get_regions_in_range(1, 269)
A, log1 = process_region_list(regions_1, A)

-- Pass 2: R270..R608
local regions_2 = get_regions_in_range(270, 608)
A, log2 = process_region_list(regions_2, A)

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Assemble green regions from Tracks 1/2 onto Tracks 3/4", -1)

local function summarise(regions, log, label)
  local lines = {}
  lines[#lines + 1] = label .. ":"
  lines[#lines + 1] = "  Green regions found: " .. tostring(#regions)
  if log and #log > 0 then
    lines[#lines + 1] = "  Notes:"
    for _, s in ipairs(log) do
      lines[#lines + 1] = "    - " .. s
    end
  end
  return table.concat(lines, "\n")
end

local report =
  summarise(regions_1, log1, "Pass 1 (R1..R269)") ..
  "\n\n" ..
  summarise(regions_2, log2, "Pass 2 (R270..R608)") ..
  "\n\nDone."

msg("Assemble Green Regions", report)
