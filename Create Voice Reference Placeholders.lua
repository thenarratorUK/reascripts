-- @description Voice Reference Setup (Gap via Ripple + 40119), then Insert Placeholders
-- @version 2.0

------------------------------------------------------------
-- USER SETTINGS
------------------------------------------------------------
local SHIFT_MODE = "auto"          -- "auto" or "none"
local NARRATION_TRACK_NAME = "Narration"  -- case-insensitive match

local INCLUDE_NARRATION_AS_CHARACTER = false  -- usually false

local NAME_PLACEHOLDER_SECONDS = 1.00
local SECONDS_PER_WORD = 0.35
local MIN_DIALOGUE_SECONDS = 1.00
local GAP_SECONDS = 0.00

local REQUIRE_COLON_IN_TEXT = true

local IGNORE_TRACK_NAME_CONTAINS = { "room tone", "roomtone" }

-- Gap creation uses:
-- 40311 = ripple all tracks
-- 40309 = ripple off
-- 40119 = item edit: move items/envelope points right (uses your nudge settings)
local ACTION_RIPPLE_ALL = 40311
local ACTION_RIPPLE_OFF = 40309
local ACTION_NUDGE_RIGHT = 40119

local MAX_NUDGES = 200000  -- safety cap

-- After creating the gap, run your room-tone gap closer:
local RUN_ROOMTONE_CLOSE_GAPS = true
local ROOMTONE_CLOSE_GAPS_CMD = "_RS28f8949146665d34f1478d8e6e233cb2d2e64719"

local DEBUG_TO_CONSOLE = false

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local function msg(s)
  if DEBUG_TO_CONSOLE then reaper.ShowConsoleMsg(tostring(s) .. "\n") end
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function lower(s) return (s and s:lower()) or "" end

local function count_words(s)
  s = trim(s or "")
  if s == "" then return 0 end
  local n = 0
  for _ in s:gmatch("%S+") do n = n + 1 end
  return n
end

local function get_track_name(track)
  local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  return name or ""
end

local function should_ignore_track(track)
  local name = lower(get_track_name(track))
  for _, frag in ipairs(IGNORE_TRACK_NAME_CONTAINS) do
    if name:find(lower(frag), 1, true) then return true end
  end
  return false
end

local function find_track_by_name_ci(name)
  local target = lower(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if lower(get_track_name(tr)) == target then return tr end
  end
  return nil
end

local function get_item_text(item)
  local _, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
  notes = notes or ""
  if trim(notes) ~= "" then return notes end

  local take = reaper.GetActiveTake(item)
  if take then
    local _, tkname = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    return tkname or ""
  end
  return ""
end

local function strip_bracket_suffix(s)
  s = (s or ""):gsub("%s%[.*$", "")
  return trim(s)
end

local function extract_dialogue_after_colon(text)
  text = trim(text or "")
  if text == "" then return nil end
  if REQUIRE_COLON_IN_TEXT and not text:find(":") then return nil end
  local _, after = text:match("^(.-):(.*)$")
  if not after then return nil end
  after = strip_bracket_suffix(after)
  if after == "" then return nil end
  return after
end

local function extract_speaker_and_dialogue(text)
  text = trim(text or "")
  if text == "" then return nil, nil end
  if REQUIRE_COLON_IN_TEXT and not text:find(":") then return nil, nil end
  local speaker, after = text:match("^(.-):(.*)$")
  if not speaker or not after then return nil, nil end
  speaker = trim(speaker)
  after = strip_bracket_suffix(after)
  if speaker == "" or after == "" then return nil, nil end
  return speaker, after
end

local function add_placeholder(track, pos, len, label)
  local item = reaper.AddMediaItemToTrack(track) -- creates a new media item  [oai_citation:7‡Reaper](https://www.reaper.fm/sdk/reascript/reascripthelp.html) (no citation in code)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH",   len)
  reaper.GetSetMediaItemInfo_String(item, "P_NOTES", label, true) -- item note text  [oai_citation:8‡Reaper](https://www.reaper.fm/sdk/reascript/reascripthelp.html)
  return item
end

------------------------------------------------------------
-- SELECTION SAVE/RESTORE
------------------------------------------------------------
local function save_selected_items()
  local t = {}
  local n = reaper.CountSelectedMediaItems(0)
  for i = 0, n - 1 do
    t[#t + 1] = reaper.GetSelectedMediaItem(0, i)
  end
  return t
end

local function restore_selected_items(saved)
  -- clear all selections first
  for ti = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, ti)
    for ii = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, ii)
      reaper.SetMediaItemSelected(it, false)
    end
  end
  -- restore
  for _, it in ipairs(saved) do
    if reaper.ValidatePtr(it, "MediaItem*") then
      reaper.SetMediaItemSelected(it, true)
    end
  end
end

local function select_items_except_ignored_tracks()
  -- clear
  for ti = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, ti)
    for ii = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, ii)
      reaper.SetMediaItemSelected(it, false)
    end
  end
  -- select all except ignored tracks
  for ti = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, ti)
    if not should_ignore_track(tr) then
      for ii = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, ii)
        reaper.SetMediaItemSelected(it, true)
      end
    end
  end
end

local function earliest_selected_item_pos()
  local earliest = nil
  local n = reaper.CountSelectedMediaItems(0)
  for i = 0, n - 1 do
    local it = reaper.GetSelectedMediaItem(0, i)
    local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    if earliest == nil or pos < earliest then earliest = pos end
  end
  return earliest
end

local function earliest_item_pos_ignoring()
  local earliest = nil
  for ti = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, ti)
    if not should_ignore_track(tr) then
      for ii = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, ii)
        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        if earliest == nil or pos < earliest then earliest = pos end
      end
    end
  end
  return earliest or 0
end

------------------------------------------------------------
-- CHARACTER MAP (child + parent/multi-speaker)
------------------------------------------------------------
local function build_character_map(narration_tr)
  local map = {}
  local running_depth = 0

  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if not should_ignore_track(tr) then
      local tr_name = get_track_name(tr)
      local depth_change = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") or 0)
      local inside_folder = (running_depth > 0)
      local is_child = inside_folder and (depth_change <= 0)
      local is_narration_track = (tr == narration_tr)

      local items = {}
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        local txt = get_item_text(it)
        if txt and trim(txt) ~= "" then
          items[#items + 1] = { pos = pos, text = txt }
        end
      end
      table.sort(items, function(a,b) return a.pos < b.pos end)

      if is_narration_track and not INCLUDE_NARRATION_AS_CHARACTER then
        -- skip as source of characters
      else
        if is_child and trim(tr_name) ~= "" and (not is_narration_track) then
          -- CHILD: one character per track; keep ordering by first parseable line,
          -- but prefer the first >=3-word dialogue if possible.
          local char_name = tr_name
          for _, rec in ipairs(items) do
            local dlg = extract_dialogue_after_colon(rec.text)
            if dlg then
              local entry = map[char_name]
              if not entry then
                entry = { first_pos = rec.pos, track = tr, any_dialogue = nil, long_dialogue = nil }
                map[char_name] = entry
              end
              if not entry.any_dialogue then entry.any_dialogue = dlg end
              if not entry.long_dialogue and count_words(dlg) >= 3 then
                entry.long_dialogue = dlg
                break
              end
            end
          end

        else
          -- PARENT/multi-speaker: many characters on one track
          for _, rec in ipairs(items) do
            local speaker, dlg = extract_speaker_and_dialogue(rec.text)
            if speaker and dlg then
              local entry = map[speaker]
              if not entry then
                entry = { first_pos = rec.pos, track = tr, any_dialogue = nil, long_dialogue = nil }
                map[speaker] = entry
              end
              if not entry.any_dialogue then entry.any_dialogue = dlg end
              if not entry.long_dialogue and count_words(dlg) >= 3 then
                entry.long_dialogue = dlg
              end
            end
          end
        end
      end

      running_depth = running_depth + depth_change
      if running_depth < 0 then running_depth = 0 end
    end
  end

  return map
end

------------------------------------------------------------
-- GAP CREATION (AUTO): ripple all + repeated 40119
------------------------------------------------------------
local function create_gap_by_nudging(needed_seconds)
  if needed_seconds <= 0 then return true end

  local saved_sel = save_selected_items()

  -- select everything except room tone (etc)
  select_items_except_ignored_tracks()

  local e0 = earliest_selected_item_pos()
  if not e0 then
    restore_selected_items(saved_sel)
    return false, "No items selected after ignoring Room Tone tracks."
  end

  -- ensure ripple all is on while nudging, so markers/regions follow
  reaper.Main_OnCommand(ACTION_RIPPLE_ALL, 0)

  local nudges = 0
  local last = e0

  while last < needed_seconds and nudges < MAX_NUDGES do
    reaper.Main_OnCommand(ACTION_NUDGE_RIGHT, 0)
    nudges = nudges + 1

    local now = earliest_selected_item_pos()
    if not now or now == last then
      break
    end
    last = now
  end

  -- turn ripple off for the insertion phase
  reaper.Main_OnCommand(ACTION_RIPPLE_OFF, 0)

  restore_selected_items(saved_sel)

  local earliest_after = earliest_item_pos_ignoring()
  if earliest_after + 0.0005 < needed_seconds then
    return false, ("Gap creation incomplete. Needed %.3fs, earliest non-ignored item now at %.3fs (nudges=%d)."):format(needed_seconds, earliest_after, nudges)
  end

  return true, ("Gap created. Needed %.3fs, earliest non-ignored item now at %.3fs (nudges=%d)."):format(needed_seconds, earliest_after, nudges)
end

------------------------------------------------------------
-- MAIN
------------------------------------------------------------
local function main()
  if DEBUG_TO_CONSOLE then reaper.ShowConsoleMsg("") end

  local narration_tr = find_track_by_name_ci(NARRATION_TRACK_NAME)
  if not narration_tr then
    reaper.MB("Could not find a track named '" .. NARRATION_TRACK_NAME .. "'.", "Voice Reference Setup", 0)
    return
  end

  local cmap = build_character_map(narration_tr)

  local list = {}
  for name, entry in pairs(cmap) do
    local dlg = entry.long_dialogue or entry.any_dialogue
    if dlg and trim(dlg) ~= "" then
      list[#list + 1] = { name = name, first_pos = entry.first_pos, track = entry.track, dialogue = dlg }
    end
  end

  if #list == 0 then
    reaper.MB("No characters found.\n\nExpected item notes (or take names) like: Name: dialogue [id]", "Voice Reference Setup", 0)
    return
  end

  table.sort(list, function(a,b) return a.first_pos < b.first_pos end)

  local needed = 0
  for _, rec in ipairs(list) do
    local dlg_len = math.max(MIN_DIALOGUE_SECONDS, count_words(rec.dialogue) * SECONDS_PER_WORD)
    needed = needed + NAME_PLACEHOLDER_SECONDS + GAP_SECONDS + dlg_len + GAP_SECONDS
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Ensure ripple is OFF for placeholder insertion itself
  reaper.Main_OnCommand(ACTION_RIPPLE_OFF, 0)

  if SHIFT_MODE == "auto" then
    local ok, why = create_gap_by_nudging(needed)
    if DEBUG_TO_CONSOLE then msg(why) end
    if not ok then
      reaper.PreventUIRefresh(-1)
      reaper.Undo_EndBlock("Voice reference: aborted (auto gap failed)", -1)
      reaper.MB(why, "Voice Reference Setup", 0)
      return
    end
  else
    local earliest = earliest_item_pos_ignoring()
    if earliest < needed then
      reaper.PreventUIRefresh(-1)
      reaper.Undo_EndBlock("Voice reference: aborted (not enough manual gap)", -1)
      reaper.MB(
        ("Not enough space at project start (ignoring Room Tone tracks).\n\nNeeded: %.3fs\nEarliest non-ignored item starts at: %.3fs")
          :format(needed, earliest),
        "Voice Reference Setup",
        0
      )
      return
    end
  end

  -- Insert placeholders at start of project, without shifting anything
  local t = 0
  for _, rec in ipairs(list) do
    add_placeholder(narration_tr, t, NAME_PLACEHOLDER_SECONDS, rec.name)
    t = t + NAME_PLACEHOLDER_SECONDS + GAP_SECONDS

    local dlg_len = math.max(MIN_DIALOGUE_SECONDS, count_words(rec.dialogue) * SECONDS_PER_WORD)
    add_placeholder(rec.track, t, dlg_len, (rec.name .. ": " .. rec.dialogue))
    t = t + dlg_len + GAP_SECONDS
  end

  -- Run your room tone close-gaps script (optional)
  if SHIFT_MODE == "auto" and RUN_ROOMTONE_CLOSE_GAPS then
    local cmd = reaper.NamedCommandLookup(ROOMTONE_CLOSE_GAPS_CMD)
    if cmd and cmd ~= 0 then
      reaper.Main_OnCommand(cmd, 0)
    else
      reaper.MB("Could not find the room-tone close-gaps script:\n" .. ROOMTONE_CLOSE_GAPS_CMD, "Voice Reference Setup", 0)
    end
  end

  reaper.UpdateArrange()
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Voice reference: create prep block", -1)
end

main()
