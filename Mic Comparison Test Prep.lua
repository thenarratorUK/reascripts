-- @description Mic Comparison Test Prep — pick 20 items (skipping colored), normalize to LUFS-I map, +3 dB compensate, flag peaks >= 0 dBFS
-- @version 1.2
-- @author David Winter
-- @changelog
--   1.2: Apply fixed +3.0 dB post-normalisation compensation to every processed item
--   1.1: Fix SWS NF_AnalyzeTakeLoudness2() call to include required 2nd arg; add API existence checks.
--   1.0: Initial version.

local r = reaper

------------------------------------------------------------
-- Configuration
------------------------------------------------------------
local COMPENSATION_DB = 3.0  -- fixed post-normalisation gain to apply to each processed item

------------------------------------------------------------
-- Guardrails / dependencies
------------------------------------------------------------
local function require_api(name)
  if not r.APIExists(name) then
    r.ShowMessageBox("Required API function is missing: "..name.."\n\nInstall/enable SWS/S&M and REAPER ≥ 6.", "Missing API", 0)
    return false
  end
  return true
end

-- Core REAPER colour helpers exist in REAPER; SWS loudness/peak need SWS.
if not (require_api("ColorToNative") and require_api("SetMediaItemInfo_Value") and require_api("GetDisplayedMediaItemColor2")) then return end
if not (require_api("NF_AnalyzeTakeLoudness2") and require_api("NF_GetMediaItemMaxPeak")) then
  r.ShowMessageBox("SWS functions not found (NF_AnalyzeTakeLoudness2 / NF_GetMediaItemMaxPeak).\nPlease install SWS/S&M.", "SWS required", 0)
  return
end

------------------------------------------------------------
-- Utilities
------------------------------------------------------------

local function db_to_gain(db)
  return 10 ^ (db / 20.0)
end

-- Returns true if item is default/no-colour according to displayed colour.
-- Uses GetDisplayedMediaItemColor2 so it respects user's “use track/take/item colour” preference.
local function item_is_default_color(item)
  local take = r.GetActiveTake(item)
  local col = r.GetDisplayedMediaItemColor2(item, take)
  -- API returns 0 for “no color” (not black). Nonzero values are OS-native|0x01000000.
  return col == 0
end

local function set_item_red(item)
  -- REAPER requires the enable bit 0x1000000 when setting custom colours.
  local col = r.ColorToNative(255, 0, 0) | 0x1000000
  r.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", col)
end

-- Loudness normalisation of the ACTIVE TAKE to a target LUFS-I, then apply fixed +3 dB
local function normalize_item_to_lufsI_plus3dB(item, target_lufs)
  local take = r.GetActiveTake(item)
  if not take then return false, "No active take" end

  -- SWS ≥ 2.13 requires at least two args; 0 = auto/default window.
  local retval, LUFS_I = r.NF_AnalyzeTakeLoudness2(take, 0)
  if not retval or type(LUFS_I) ~= "number" then
    return false, "NF_AnalyzeTakeLoudness2 failed"
  end

  -- First: set to target LUFS-I (per-take domain)
  local diff_db = (target_lufs - LUFS_I)
  local cur_vol = r.GetMediaItemTakeInfo_Value(take, "D_VOL") -- linear
  local new_vol = cur_vol * db_to_gain(diff_db)

  -- Then: apply fixed +3.0 dB compensation (user request)
  new_vol = new_vol * db_to_gain(COMPENSATION_DB)

  r.SetMediaItemTakeInfo_Value(take, "D_VOL", new_vol)
  return true
end

-- Returns max peak in dBFS if available, else nil.
local function get_item_max_peak_db(item)
  local peak_db = r.NF_GetMediaItemMaxPeak(item)
  if type(peak_db) ~= "number" then return nil end
  return peak_db
end

-- Map 1..20 -> target LUFS-I
local function target_for_index(idx)
  if     (idx==2 or idx==5 or idx==8 or idx==9 or idx==12 or idx==15 or idx==18) then return -20
  elseif (idx==1 or idx==17) then return -21
  elseif (idx==3 or idx==11) then return -22
  elseif (idx==4 or idx==6 or idx==7 or idx==13 or idx==16 or idx==20) then return -23
  elseif (idx==10 or idx==14 or idx==19) then return -24
  else return nil end
end

------------------------------------------------------------
-- 1) Build the list of up to 20 items per your rules
------------------------------------------------------------
r.Undo_BeginBlock()
r.PreventUIRefresh(1)

local sel_item = r.GetSelectedMediaItem(0, 0)
if not sel_item then
  r.PreventUIRefresh(-1); r.Undo_EndBlock("Mic Comparison Test Prep", -1)
  r.ShowMessageBox("Select an item on the track to serve as item 1.", "No item selected", 0)
  return
end

local track = r.GetMediaItem_Track(sel_item)
if not track then
  r.PreventUIRefresh(-1); r.Undo_EndBlock("Mic Comparison Test Prep", -1)
  r.ShowMessageBox("Selected item has no track.", "Error", 0)
  return
end

local cnt = r.CountTrackMediaItems(track)
if cnt == 0 then
  r.PreventUIRefresh(-1); r.Undo_EndBlock("Mic Comparison Test Prep", -1)
  r.ShowMessageBox("No items on the selected track.", "Error", 0)
  return
end

-- Locate the selected item’s index on its track
local idx_sel = nil
for i = 0, cnt-1 do
  if r.GetTrackMediaItem(track, i) == sel_item then idx_sel = i; break end
end
if not idx_sel then
  r.PreventUIRefresh(-1); r.Undo_EndBlock("Mic Comparison Test Prep", -1)
  r.ShowMessageBox("Internal error: could not locate selected item on its track.", "Error", 0)
  return
end

-- Build 1..20:
-- item 1 = selected item (always included)
-- items 2..20 = next items that have default/no colour; skip any coloured items
local picked = {}
picked[1] = sel_item
local want = 20
local pcount = 1
local i = idx_sel + 1
while pcount < want and i < cnt do
  local it = r.GetTrackMediaItem(track, i)
  if item_is_default_color(it) then
    pcount = pcount + 1
    picked[pcount] = it
  end
  i = i + 1
end
-- Proceed with however many were found if < 20.

------------------------------------------------------------
-- 2) Normalise selected set to specified LUFS-I targets, then +3 dB
------------------------------------------------------------
for pos = 1, math.min(20, #picked) do
  local it = picked[pos]
  local target = target_for_index(pos)
  if target then
    local ok, err = normalize_item_to_lufsI_plus3dB(it, target)
    if not ok then
      r.ShowConsoleMsg(string.format("[WARN] Item %d: normalize to %0.0f LUFS-I (+3 dB) failed: %s\n", pos, target, tostring(err)))
    end
  end
end

------------------------------------------------------------
-- 3) Flag any item whose max peak >= 0 dBFS by colouring it red
------------------------------------------------------------
for pos = 1, #picked do
  local it = picked[pos]
  local peak_db = get_item_max_peak_db(it)
  if peak_db and peak_db >= 0 then
    set_item_red(it)
  end
end

r.UpdateArrange()
r.PreventUIRefresh(-1)
r.Undo_EndBlock("Mic Comparison Test Prep: pick 20, normalize LUFS-I, +3 dB, flag peaks", -1)
