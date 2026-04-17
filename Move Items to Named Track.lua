-- @description Move Items to Named Track
-- @version 1.0
-- @author David Winter
--[[
  Move selected items to a track by typed name (exact match, case-insensitive).
  - Remembers last-used destination name via ExtState.
  - If track not found, prompts to create it (Yes/No).
--]]

local EXT_SECTION = "DW_MoveItemsToNamedTrack"
local EXT_KEY_LAST = "LastTrackName"

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function norm(s)
  s = trim(s or "")
  return s:lower()
end

local function get_track_name(tr)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  return name or ""
end

local function find_track_by_name_exact_ci(name)
  local target = norm(name)
  if target == "" then return nil end

  local track_count = reaper.CountTracks(0)
  for i = 0, track_count - 1 do
    local tr = reaper.GetTrack(0, i)
    local tr_name = get_track_name(tr)
    if norm(tr_name) == target then
      return tr
    end
  end
  return nil
end

local function create_track_at_end_with_name(name)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local tr = reaper.GetTrack(0, idx)
  if tr then
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  end
  return tr
end

local function move_selected_items_to_track(dest_tr)
  local sel_count = reaper.CountSelectedMediaItems(0)
  for i = 0, sel_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    if item then
      reaper.MoveMediaItemToTrack(item, dest_tr)
    end
  end
end

-- Main
local sel_items = reaper.CountSelectedMediaItems(0)
if sel_items == 0 then
  reaper.MB("No items selected.", "Move Items To Track", 0)
  return
end

local last = reaper.GetExtState(EXT_SECTION, EXT_KEY_LAST)
last = last or ""

local ok, input = reaper.GetUserInputs("Move Items To Track", 1, "Destination track name:", last)
if not ok then return end

input = trim(input or "")
if input == "" then return end

-- Store last-used destination immediately on valid input
reaper.SetExtState(EXT_SECTION, EXT_KEY_LAST, input, true)

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local dest = find_track_by_name_exact_ci(input)
if not dest then
  local resp = reaper.MB(
    'Track not found:\n\n"' .. input .. '"\n\nCreate new track?',
    "Move Items To Track",
    4 -- Yes/No
  )

  if resp == 6 then -- Yes
    dest = create_track_at_end_with_name(input)
  else
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Move selected items to named track", -1)
    return
  end
end

if dest then
  move_selected_items_to_track(dest)
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Move selected items to named track", -1)
