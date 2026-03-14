--[[
  Threshold Split + RMS Cull + Overlap Cull + Colour + Cleanup (Clicks/Renders)
  + Apply Track/Take FX to Clicks items (mono) via action 40361

  Modes:
    A) USE_TIME_SELECTION_ONLY = true
       - Operates only within the current time selection.
       - After splitting Clicks at selection start/end, selects the item(s) fully inside the range
         and runs: Item: Apply track/take FX to items (mono output) [40361]

    B) USE_TIME_SELECTION_ONLY = false
       - Before processing, selects ALL Clicks items >= CHAPTER_MIN_LEN_SEC and runs [40361].
       - Then operates “chapter-by-chapter” automatically:
         * Finds items >= CHAPTER_MIN_LEN_SEC on BOTH tracks with matching start+end times (within MATCH_TOL_SEC).
         * For each matched pair, runs the pipeline as if time-selected that chapter.

  Pipeline per range:
    [Pre] Split items at range start/end on both tracks
    [1] Clicks: threshold-split + RMS cull (remove silent)
    [2] Renders: threshold-split + RMS cull (remove quiet)
    [3] Delete Clicks items that overlap any Renders item
    [4] Colour remaining Clicks items red
    [5] Delete remaining Renders items (only after colouring Clicks)
    [Post] Dump remaining item times on both tracks for debug

  Assumptions:
    - Tracks named "Clicks" and "Renders" (case-insensitive match below).
]]

-- =========================
-- USER CONFIG
-- =========================
local USE_TIME_SELECTION_ONLY = false


-- 0 = silent, 1 = console output
local debug = 0
local CLICKS_TRACK_NAME  = "Clicks"
local RENDERS_TRACK_NAME = "Renders"


local BREATHS_TRACK_NAME = "Breaths"

-- Delete Clicks items whose bounds are fully within a Breaths item
local WITHIN_BREATH_TOL_SEC = 0.0005
local SOURCE_TRACK_NAMES = {
  "Recording", "Recordings",
  "Narration", "Dialogue 1", "Dialogue 2",
  "Internal", "System",
  "Special 1", "Special 2"
}

-- Chapter auto-detection (only used when USE_TIME_SELECTION_ONLY=false)
local CHAPTER_MIN_LEN_SEC = 5.0
local MATCH_TOL_SEC       = 0.001  -- match chapter start/end within 1ms

-- Threshold split (peak-based, per 1ms step)
local HYSTERESIS_DB = 6.0
local CLICKS_THRESH_DB   = -55.0
local RENDERS_THRESH_DB  = -45.0

-- RMS cull (per resulting segment)
local CLICKS_RMS_MIN_DB  = -60.0  -- delete click segments whose RMS is below this
local RENDERS_RMS_CUT_DB = -35.0  -- delete render segments whose RMS is below this (keeps non-quiet)

-- Source-RMS filter (post overlap-cull): delete Clicks where source RMS is ABOVE this
local SOURCE_RMS_MAX_DB = -50.0

-- Scanning resolution
local STEP_SEC = 0.001

-- Overlap tolerance (for culling Clicks vs Renders)
local OVERLAP_TOL_SEC = 0.0005 -- 0.5 ms

-- Colour for remaining clicks (red)
local REMAINING_CLICKS_TURN_RED = true
local DELETE_REMAINING_RENDERS  = true

-- =========================
-- Helpers
-- =========================
local function msg(s)
  if debug == 1 then
    reaper.ShowConsoleMsg(tostring(s) .. "")
  end
end
local function fmt_time(t) return reaper.format_timestr_pos(t, "", 0) end

local function db_from_amp(a)
  if not a or a <= 0 then return -150.0 end
  return 20.0 * (math.log(a, 10))
end

local function get_ripple_mode()
  if reaper.GetToggleCommandState(40311) == 1 then return 2 end -- all tracks
  if reaper.GetToggleCommandState(40310) == 1 then return 1 end -- per-track
  return 0
end

local function set_ripple_mode(mode)
  if mode == 2 then
    reaper.Main_OnCommand(40311, 0)
  elseif mode == 1 then
    reaper.Main_OnCommand(40310, 0)
  else
    reaper.Main_OnCommand(40309, 0) -- off
  end
end

local function get_time_selection()
  local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if not ts_start or not ts_end or ts_end <= ts_start then return nil end
  return ts_start, ts_end
end

local function find_track_by_name(name)
  local want = (name or ""):lower():gsub("^%s+",""):gsub("%s+$","")
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, tn = reaper.GetTrackName(tr, "")
    tn = (tn or ""):lower():gsub("^%s+",""):gsub("%s+$","")
    if tn == want then return tr end
  end
  return nil
end

local function item_time(item)
  local p = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local l = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return p, p + l
end

local function item_len(item)
  local _, e = item_time(item)
  local s = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  return e - s
end

local function split_items_at_time_on_track(track, t)
  if not track then return 0 end
  local splits = 0
  local n = reaper.CountTrackMediaItems(track)
  for i = n - 1, 0, -1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local a, b = item_time(it)
    if t > a and t < b then
      local right = reaper.SplitMediaItem(it, t)
      if right then splits = splits + 1 end
    end
  end
  return splits
end

local function dump_track_items(track, label, range_start, range_end)
  msg(("--- Remaining items on %s (within range) ---"):format(label))
  local n = reaper.CountTrackMediaItems(track)
  local rows = {}
  for i = 0, n - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local a, b = item_time(it)
    if b > range_start and a < range_end then
      rows[#rows+1] = {s=a, e=b}
    end
  end
  table.sort(rows, function(x,y)
    if x.s == y.s then return x.e < y.e end
    return x.s < y.s
  end)
  msg(("Count: %d"):format(#rows))
  for i, r in ipairs(rows) do
    msg(("[%03d] %.6f (%s) -> %.6f (%s) (%.1f ms)"):format(
      i, r.s, fmt_time(r.s), r.e, fmt_time(r.e), (r.e - r.s) * 1000.0
    ))
  end
end

-- =========================
-- Selection + Apply FX helper (40361)
-- =========================
local function get_selected_items()
  local out = {}
  local n = reaper.CountSelectedMediaItems(0)
  for i = 0, n - 1 do
    out[#out+1] = reaper.GetSelectedMediaItem(0, i)
  end
  return out
end

local function set_selected_items(items)
  reaper.SelectAllMediaItems(0, false)
  for _, it in ipairs(items) do
    if it then reaper.SetMediaItemSelected(it, true) end
  end
end

local function apply_track_take_fx_mono_on_selected_items()
  -- Item: Apply track/take FX to items (mono output)
  reaper.Main_OnCommand(40361, 0)
end

local function collect_track_items_in_range_fully_inside(track, range_s, range_e, tol)
  tol = tol or 0.0
  local out = {}
  local n = reaper.CountTrackMediaItems(track)
  for i = 0, n - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local a, b = item_time(it)
    if a >= (range_s - tol) and b <= (range_e + tol) then
      out[#out+1] = it
    end
  end
  return out
end

local function collect_track_items_len_ge(track, min_len)
  local out = {}
  local n = reaper.CountTrackMediaItems(track)
  for i = 0, n - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local a, b = item_time(it)
    if (b - a) >= min_len then
      out[#out+1] = it
    end
  end
  return out
end

-- =========================
-- Audio measurement helpers
-- =========================
local function peak_db_at(accessor, t, sr, numch, buf, step_samples)
  buf.clear()
  local ok = reaper.GetAudioAccessorSamples(accessor, sr, numch, t, step_samples, buf)
  if not ok then return -150.0 end

  local peak = 0.0
  local n = numch * step_samples
  for i = 1, n do
    local v = math.abs(buf[i])
    if v > peak then peak = v end
  end

  if peak > 0 and math.abs(peak - 1024.0) < 1.0 then
    peak = math.abs(peak - 1024.0)
  end
  if peak ~= peak or peak == math.huge or peak == -math.huge or peak > 2.0 then
    peak = 0.0
  end

  return db_from_amp(peak)
end

local function rms_db_in_range(accessor, t0, t1, sr, numch)
  if t1 <= t0 then return -150.0 end

  local block = 4096
  local buf = reaper.new_array(block * numch)

  local total_sq = 0.0
  local total_n  = 0

  local dur = t1 - t0
  local total_samples = math.max(1, math.floor(dur * sr + 0.5))

  local read = 0
  while read < total_samples do
    local remain = total_samples - read
    local ns = (remain > block) and block or remain

    buf.resize(ns * numch)
    buf.clear()

    local t = t0 + (read / sr)
    local ok = reaper.GetAudioAccessorSamples(accessor, sr, numch, t, ns, buf)
    if not ok then break end

    local n = ns * numch
    for i = 1, n do
      local v = buf[i]
      total_sq = total_sq + (v * v)
    end
    total_n = total_n + n

    read = read + ns
  end

  if total_n <= 0 then return -150.0 end
  local rms = math.sqrt(total_sq / total_n)
  return db_from_amp(math.abs(rms))
end

local function find_tracks_by_names(names)
  local out = {}
  for _, n in ipairs(names or {}) do
    local tr = find_track_by_name(n)
    if tr then out[#out+1] = tr end
  end
  return out
end

local function create_track_accessor_cache(tracks)
  local cache = {}
  for i = 1, #tracks do
    local tr = tracks[i]
    local acc = reaper.CreateTrackAudioAccessor(tr)
    if acc then cache[#cache+1] = acc end
  end
  return cache
end

local function destroy_track_accessor_cache(cache)
  for i = 1, #cache do
    reaper.DestroyAudioAccessor(cache[i])
  end
end

local function max_source_rms_db(cache, t0, t1, sr, numch)
  local max_db = -150.0
  for i = 1, #cache do
    local db = rms_db_in_range(cache[i], t0, t1, sr, numch)
    if db > max_db then max_db = db end
  end
  return max_db
end

-- =========================
-- Core: split by threshold/hysteresis, then delete by RMS
-- =========================
local function process_track(track, range_start, range_end, thresh_db, hyst_db, rms_rule_db, mode_label)
  local sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
  if (not sr) or (sr <= 0) then sr = 48000 end
  sr = math.floor(sr + 0.5)

  local numch = 2
  local step_samples = math.max(1, math.floor(STEP_SEC * sr + 0.5))
  local buf = reaper.new_array(numch * step_samples)

  local accessor = reaper.CreateTrackAudioAccessor(track)
  if not accessor then
    msg("ERROR: could not create track audio accessor for " .. mode_label)
    return 0
  end

  local thresh_on  = thresh_db
  local thresh_off = thresh_db - hyst_db

  -- Collect items on this track that overlap range
  local items = {}
  local n = reaper.CountTrackMediaItems(track)
  for i = 0, n - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local a, b = item_time(it)
    if b > range_start and a < range_end then
      items[#items+1] = it
    end
  end

  -- Step 1: split each item at threshold transitions
  for _, item in ipairs(items) do
    local it_start, it_end = item_time(item)
    local scan0 = math.max(it_start, range_start)
    local scan1 = math.min(it_end, range_end)
    if scan1 > scan0 then
      local splits = {}
      local t = scan0
      local first_db = peak_db_at(accessor, t, sr, numch, buf, step_samples)
      local state_high = (first_db >= thresh_on)

      while t < scan1 do
        local dbv = peak_db_at(accessor, t, sr, numch, buf, step_samples)
        if (not state_high) and (dbv >= thresh_on) then
          splits[#splits+1] = t
          state_high = true
        elseif state_high and (dbv <= thresh_off) then
          splits[#splits+1] = t
          state_high = false
        end
        t = t + STEP_SEC
      end

      table.sort(splits)

      local cur = item
      local cur_start, cur_end = item_time(cur)
      for _, st in ipairs(splits) do
        if st > cur_start and st < cur_end then
          local right = reaper.SplitMediaItem(cur, st)
          if right then
            cur = right
            cur_start, cur_end = item_time(cur)
          end
        end
      end
    end
  end

  -- Step 2: RMS scan each resulting segment and delete according to mode
  local to_delete = {}
  local n2 = reaper.CountTrackMediaItems(track)
  for i = 0, n2 - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local a, b = item_time(it)
    local w0 = math.max(a, range_start)
    local w1 = math.min(b, range_end)
    if w1 > w0 then
      local rms_db = rms_db_in_range(accessor, w0, w1, sr, numch)

      if mode_label == "REMOVE_SILENT" then
        if rms_db < rms_rule_db then
          to_delete[#to_delete+1] = it
        end
      else
        -- delete QUIET render segments (keep non-quiet)
        if rms_db < rms_rule_db then
          to_delete[#to_delete+1] = it
        end
      end
    end
  end

  for _, it in ipairs(to_delete) do
    reaper.DeleteTrackMediaItem(track, it)
  end

  reaper.DestroyAudioAccessor(accessor)
  return #to_delete
end

-- =========================
-- Overlap-cull: delete Clicks items that overlap any Renders item
-- =========================
local function overlaps(a0, a1, b0, b1, tol)
  return (a1 > (b0 + tol)) and (b1 > (a0 + tol))
end

local function get_items_on_track_in_range(track, range_s, range_e)
  local out = {}
  local n = reaper.CountTrackMediaItems(track)
  for i = 0, n - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local a, b = item_time(it)
    if b > range_s and a < range_e then
      out[#out+1] = { item = it, s = a, e = b }
    end
  end
  table.sort(out, function(x,y)
    if x.s == y.s then return x.e < y.e end
    return x.s < y.s
  end)
  return out
end

local function overlap_cull_clicks_vs_renders(clicks_tr, renders_tr, range_s, range_e)
  local clicks  = get_items_on_track_in_range(clicks_tr,  range_s, range_e)
  local renders = get_items_on_track_in_range(renders_tr, range_s, range_e)

  local r_idx = 1
  local deleted = 0

  for _, c in ipairs(clicks) do
    while r_idx <= #renders and renders[r_idx].e <= (c.s + OVERLAP_TOL_SEC) do
      r_idx = r_idx + 1
    end

    local hit = false
    for j = r_idx, math.min(#renders, r_idx + 24) do
      local r = renders[j]
      if overlaps(c.s, c.e, r.s, r.e, OVERLAP_TOL_SEC) then
        hit = true
        break
      end
      if r.s >= (c.e - OVERLAP_TOL_SEC) then
        break
      end
    end

    if hit then
      reaper.DeleteTrackMediaItem(clicks_tr, c.item)
      deleted = deleted + 1
    end
  end

  return deleted
end

-- =========================
-- Within-cull: delete Clicks items fully within any Breaths item
-- =========================
local function fully_within(a0, a1, b0, b1, tol)
  return (a0 >= (b0 - tol)) and (a1 <= (b1 + tol))
end

local function within_cull_clicks_within_breaths(clicks_tr, breaths_tr, range_s, range_e)
  if (not clicks_tr) or (not breaths_tr) then return 0 end

  local clicks  = get_items_on_track_in_range(clicks_tr,  range_s, range_e)
  local breaths = get_items_on_track_in_range(breaths_tr, range_s, range_e)

  local b_idx = 1
  local deleted = 0

  for _, c in ipairs(clicks) do
    while b_idx <= #breaths and breaths[b_idx].e < (c.s - WITHIN_BREATH_TOL_SEC) do
      b_idx = b_idx + 1
    end

    local hit = false
    for j = b_idx, math.min(#breaths, b_idx + 24) do
      local b = breaths[j]
      if fully_within(c.s, c.e, b.s, b.e, WITHIN_BREATH_TOL_SEC) then
        hit = true
        break
      end
      if b.s > (c.e + WITHIN_BREATH_TOL_SEC) then
        break
      end
    end

    if hit then
      reaper.DeleteTrackMediaItem(clicks_tr, c.item)
      deleted = deleted + 1
    end
  end

  return deleted
end

local function source_rms_cull_clicks(clicks_tr, source_tracks, range_s, range_e, source_rms_max_db)
  if not source_tracks or #source_tracks == 0 then
    msg("[SourceRMS] WARNING: no source tracks found; skipping Source-RMS cull.")
    return 0
  end

  local sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
  if (not sr) or (sr <= 0) then sr = 48000 end
  sr = math.floor(sr + 0.5)

  local numch = 2
  local cache = create_track_accessor_cache(source_tracks)

  local clicks = get_items_on_track_in_range(clicks_tr, range_s, range_e)
  local to_delete = {}

  for _, c in ipairs(clicks) do
    local a, b = item_time(c.item)
    local w0 = math.max(a, range_s)
    local w1 = math.min(b, range_e)
    if w1 > w0 then
      local src_max = max_source_rms_db(cache, w0, w1, sr, numch)
      if src_max > source_rms_max_db then
        to_delete[#to_delete+1] = c.item
      end
    end
  end

  for _, it in ipairs(to_delete) do
    reaper.DeleteTrackMediaItem(clicks_tr, it)
  end

  destroy_track_accessor_cache(cache)
  return #to_delete
end

-- =========================
-- Colour + delete helpers
-- =========================
local function set_item_red(item)
  local native = reaper.ColorToNative(255, 0, 0)
  reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", native | 0x1000000)
end

local function colour_remaining_clicks_red(clicks_tr, range_s, range_e)
  local clicks = get_items_on_track_in_range(clicks_tr, range_s, range_e)
  for _, c in ipairs(clicks) do
    set_item_red(c.item)
  end
  return #clicks
end

local function delete_remaining_renders(renders_tr, range_s, range_e)
  local renders = get_items_on_track_in_range(renders_tr, range_s, range_e)
  for _, r in ipairs(renders) do
    reaper.DeleteTrackMediaItem(renders_tr, r.item)
  end
  return #renders
end

-- =========================
-- Chapter range detection (when USE_TIME_SELECTION_ONLY=false)
-- =========================
local function collect_chapter_candidates(track, min_len)
  local cand = {}
  local n = reaper.CountTrackMediaItems(track)
  for i = 0, n - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    local s, e = item_time(it)
    local len = e - s
    if len >= min_len then
      cand[#cand+1] = { item=it, s=s, e=e }
    end
  end
  table.sort(cand, function(a,b)
    if a.s == b.s then return a.e < b.e end
    return a.s < b.s
  end)
  return cand
end

local function chapter_ranges_from_matching_items(clicks_tr, renders_tr, min_len, tol)
  local clicks  = collect_chapter_candidates(clicks_tr,  min_len)
  local renders = collect_chapter_candidates(renders_tr, min_len)

  local used_r = {}
  local ranges = {}

  local r_idx = 1
  for _, c in ipairs(clicks) do
    while r_idx <= #renders and (renders[r_idx].e < (c.s - tol)) do
      r_idx = r_idx + 1
    end

    local match_j = nil
    for j = r_idx, math.min(#renders, r_idx + 32) do
      if not used_r[j] then
        local r = renders[j]
        if math.abs(r.s - c.s) <= tol and math.abs(r.e - c.e) <= tol then
          match_j = j
          break
        end
        if r.s > (c.s + tol) then
          break
        end
      end
    end

    if match_j then
      used_r[match_j] = true
      ranges[#ranges+1] = { s = c.s, e = c.e }
    end
  end

  table.sort(ranges, function(a,b)
    if a.s == b.s then return a.e < b.e end
    return a.s < b.s
  end)

  local out = {}
  local last_s, last_e = nil, nil
  for _, r in ipairs(ranges) do
    if (not last_s) or math.abs(r.s - last_s) > tol or math.abs(r.e - last_e) > tol then
      out[#out+1] = r
      last_s, last_e = r.s, r.e
    end
  end

  return out
end

-- =========================
-- Apply FX step (as requested)
-- =========================
local function apply_fx_to_clicks_for_time_selection(clicks_tr, range_start, range_end)
  -- After Clicks has been split at range boundaries:
  -- select the item(s) fully inside the range and apply track/take FX (mono)
  local sel_before = get_selected_items()

  local items = collect_track_items_in_range_fully_inside(clicks_tr, range_start, range_end, 0.000001)
  if #items > 0 then
    set_selected_items(items)
    msg(("[FX] Applying track/take FX (mono) to Clicks items in range: %d"):format(#items))
    apply_track_take_fx_mono_on_selected_items()
  else
    msg("[FX] No Clicks items fully inside the range to apply FX to.")
  end

  set_selected_items(sel_before)
end

local function apply_fx_to_clicks_for_whole_project(clicks_tr)
  -- Select all Clicks items >= CHAPTER_MIN_LEN_SEC and apply FX (mono)
  local sel_before = get_selected_items()

  local items = collect_track_items_len_ge(clicks_tr, CHAPTER_MIN_LEN_SEC)
  if #items > 0 then
    set_selected_items(items)
    msg(("[FX] Applying track/take FX (mono) to Clicks chapter items (len>=%.1fs): %d"):format(
      CHAPTER_MIN_LEN_SEC, #items
    ))
    apply_track_take_fx_mono_on_selected_items()
  else
    msg("[FX] No Clicks items >= chapter length to apply FX to.")
  end

  set_selected_items(sel_before)
end

-- =========================
-- Process one range
-- =========================
local function process_range(clicks_tr, renders_tr, breaths_tr, source_tracks, range_start, range_end, label, do_fx_after_pre_splits)
  msg("")
  msg(("=== %s ==="):format(label))
  msg(("Range: %.6f (%s) -> %.6f (%s) (%.1f ms)"):format(
    range_start, fmt_time(range_start), range_end, fmt_time(range_end), (range_end - range_start) * 1000.0
  ))

  msg("[Pre] Splitting items at range boundaries on both tracks...")
  local c1 = split_items_at_time_on_track(clicks_tr,  range_start)
  local c2 = split_items_at_time_on_track(clicks_tr,  range_end)
  local r1 = split_items_at_time_on_track(renders_tr, range_start)
  local r2 = split_items_at_time_on_track(renders_tr, range_end)
  msg(("[Pre] Splits: Clicks @start=%d @end=%d | Renders @start=%d @end=%d"):format(c1, c2, r1, r2))

  if do_fx_after_pre_splits then
    apply_fx_to_clicks_for_time_selection(clicks_tr, range_start, range_end)
  end

  local del_c = process_track(clicks_tr,  range_start, range_end, CLICKS_THRESH_DB,  HYSTERESIS_DB, CLICKS_RMS_MIN_DB,  "REMOVE_SILENT")
  msg(("Processed Clicks: deleted %d segments."):format(del_c))

  local del_r = process_track(renders_tr, range_start, range_end, RENDERS_THRESH_DB, HYSTERESIS_DB, RENDERS_RMS_CUT_DB, "REMOVE_NONSILENT")
  msg(("Processed Renders: deleted %d segments."):format(del_r))

  msg("[Step 3] Overlap-cull Clicks vs Renders...")
  local del_clicks = overlap_cull_clicks_vs_renders(clicks_tr, renders_tr, range_start, range_end)
  msg(("Deleted Clicks due to overlap: %d"):format(del_clicks))

  msg("[Step 3b] Source-RMS cull (delete Clicks where source RMS is above threshold)...")
  local del_src = source_rms_cull_clicks(clicks_tr, source_tracks, range_start, range_end, SOURCE_RMS_MAX_DB)
  msg(("Deleted Clicks due to source RMS > %.1f dB: %d"):format(SOURCE_RMS_MAX_DB, del_src))

  msg("[Step 4] Colour remaining Clicks red...")
  local red_count = 0
  if REMAINING_CLICKS_TURN_RED then
    red_count = colour_remaining_clicks_red(clicks_tr, range_start, range_end)
  end
  msg(("Coloured Clicks red: %d"):format(red_count))

  msg("[Step 5] Delete remaining Renders items...")
  local del_renders = 0
  if DELETE_REMAINING_RENDERS then
    del_renders = delete_remaining_renders(renders_tr, range_start, range_end)
  end
  msg(("Deleted Renders items: %d"):format(del_renders))

  if breaths_tr then
    msg("[Step 6] Delete Clicks fully within Breaths items...")
    local del_within = within_cull_clicks_within_breaths(clicks_tr, breaths_tr, range_start, range_end)
    msg(("Deleted Clicks fully within Breaths: %d"):format(del_within))
  else
    msg("[Step 6] Breaths track not found; skipping within-Breaths cull.")
  end

  msg("")
  dump_track_items(clicks_tr,  "Clicks",  range_start, range_end)
  dump_track_items(renders_tr, "Renders", range_start, range_end)
end


-- =========================
-- Main
-- =========================
if debug == 1 then reaper.ClearConsole() end
msg("=== Threshold Split + RMS Cull + Overlap Cull + Colour + Cleanup ===")

local clicks_tr  = find_track_by_name(CLICKS_TRACK_NAME)
local renders_tr = find_track_by_name(RENDERS_TRACK_NAME)
local breaths_tr = find_track_by_name(BREATHS_TRACK_NAME)
local source_tracks = find_tracks_by_names(SOURCE_TRACK_NAMES)

if not clicks_tr then
  reaper.ShowMessageBox('Track not found: "' .. CLICKS_TRACK_NAME .. '"', "Click Cull", 0)
  return
end
if not renders_tr then
  reaper.ShowMessageBox('Track not found: "' .. RENDERS_TRACK_NAME .. '"', "Click Cull", 0)
  return
end
if #source_tracks == 0 then
  msg("[SourceRMS] WARNING: none of the SOURCE_TRACK_NAMES were found; Source-RMS cull will be skipped.")
end

local ripple_before = get_ripple_mode()

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)
set_ripple_mode(0)

if USE_TIME_SELECTION_ONLY then
  local ts_start, ts_end = get_time_selection()
  if not ts_start then
    set_ripple_mode(ripple_before)
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Click cull workflow (Clicks/Renders)", -1)
    reaper.ShowMessageBox("Time selection required (time selection, not loop points).", "Click Cull", 0)
    return
  end

  process_range(clicks_tr, renders_tr, breaths_tr, source_tracks, ts_start, ts_end, "Time Selection", true)
else
  -- Apply FX (mono) to all chapter items on Clicks first (as requested)
  apply_fx_to_clicks_for_whole_project(clicks_tr)

  local ranges = chapter_ranges_from_matching_items(
    clicks_tr, renders_tr,
    CHAPTER_MIN_LEN_SEC, MATCH_TOL_SEC
  )

  if #ranges == 0 then
    msg("No matching chapter-length items found on both tracks.")
  else
    msg(("Auto-detected chapter ranges: %d"):format(#ranges))
    for i, r in ipairs(ranges) do
      process_range(clicks_tr, renders_tr, breaths_tr, source_tracks, r.s, r.e, ("Chapter %02d"):format(i), false)
    end
  end
end

set_ripple_mode(ripple_before)
reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Click cull workflow (Clicks/Renders)", -1)

msg("")
msg("DONE.")
