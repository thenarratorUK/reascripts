-- @description DW_Bake All FX To Selected Items (Take FX) Then Glue Individually
-- @version 1.0
-- @author David Winter

-- =========================
-- USER SETTINGS
-- =========================
local ALL_FX_TRACK_NAME = "All FX"

-- If true, removes all existing take FX on the item before copying All FX over.
local CLEAR_EXISTING_TAKE_FX = true

-- If true, glues each selected item individually (recommended).
local GLUE_EACH_ITEM_INDIVIDUALLY = true

-- Native action ID (REAPER default) commonly used for: Item: Glue items
-- If your install differs, change this to the correct command ID.
local GLUE_COMMAND_ID = 41588

-- =========================
-- HELPERS
-- =========================
local function msg(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

local function find_track_by_name(name)
  local n = reaper.CountTracks(0)
  for i = 0, n-1 do
    local tr = reaper.GetTrack(0, i)
    local ok, tr_name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if ok and tr_name == name then return tr end
  end
  return nil
end

local function get_selected_items()
  local t = {}
  local n = reaper.CountSelectedMediaItems(0)
  for i = 0, n-1 do
    t[#t+1] = reaper.GetSelectedMediaItem(0, i)
  end
  return t
end

local function unselect_all_items()
  reaper.Main_OnCommand(40289, 0) -- Item: Unselect (clear selection of) all items
end

local function select_only_item(item)
  unselect_all_items()
  reaper.SetMediaItemSelected(item, true)
end

local function clear_take_fx(take)
  local fx_count = reaper.TakeFX_GetCount(take)
  for fx = fx_count-1, 0, -1 do
    reaper.TakeFX_Delete(take, fx)
  end
end

local function copy_allfx_track_fx_to_take(all_fx_tr, take)
  local track_fx_count = reaper.TrackFX_GetCount(all_fx_tr)
  for fx = 0, track_fx_count-1 do
    local dest_idx = reaper.TakeFX_GetCount(take) -- append
    -- is_move = false (copy, don’t remove from source)
    reaper.TrackFX_CopyToTake(all_fx_tr, fx, take, dest_idx, false)
  end
end

-- =========================
-- MAIN
-- =========================
local items = get_selected_items()
if #items == 0 then
  reaper.MB("No items selected.", "Bake All FX -> Take FX", 0)
  return
end

local all_fx_tr = find_track_by_name(ALL_FX_TRACK_NAME)
if not all_fx_tr then
  reaper.MB("Track not found: " .. ALL_FX_TRACK_NAME, "Bake All FX -> Take FX", 0)
  return
end

-- Save time selection + cursor (so this script is minimally disruptive)
local ts_ok, ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
local cur_pos = reaper.GetCursorPosition()

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

-- We will process based on the items captured at start (so glue replacement doesn’t break iteration).
for i = 1, #items do
  local item = items[i]
  if item then
    local take = reaper.GetActiveTake(item)
    if take then
      if CLEAR_EXISTING_TAKE_FX then
        clear_take_fx(take)
      end
      copy_allfx_track_fx_to_take(all_fx_tr, take)

      if GLUE_EACH_ITEM_INDIVIDUALLY then
        select_only_item(item)
        reaper.Main_OnCommand(GLUE_COMMAND_ID, 0)
      end
    end
  end
end

-- Restore cursor + time selection (best effort)
reaper.SetEditCurPos(cur_pos, false, false)
reaper.GetSet_LoopTimeRange(true, false, ts_start, ts_end, false)

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.TrackList_AdjustWindows(false)

reaper.Undo_EndBlock("Bake 'All FX' track FX to selected items as Take FX, then glue", -1)
