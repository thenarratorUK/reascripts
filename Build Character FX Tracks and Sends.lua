-- @description Build Character FX Tracks and Sends
-- @version 1.0
-- @author David Winter
-- Build Character FX Tracks and Sends (idempotent, reverb inheritance, bus-only FX, fixed folder layout + ordered FX)
--
-- Assumptions:
--   - Tracks named "All FX", "Dialogue Bus", and "Reverb Bus" already exist.
--
-- Behaviour:
--   - Ensures there is a "Character FX" track immediately AFTER "All FX".
--   - Treats as source tracks:
--       * all tracks ABOVE "All FX"
--       * whose names do NOT end with " FX".
--   - For each source "Name":
--       * Looks for a child track under Character FX named "Name FX".
--       * If found (within the contiguous FX block just after Character FX), reuses it.
--       * If not found, creates "Name FX" under Character FX.
--       * FX tracks are ordered to mirror the source order, including children:
--           Parent FX, then its Child FX tracks immediately after.
--       * "Name FX" inherits:
--            - colour (I_CUSTOMCOLOR)
--            - TCP layout (forced to FORCE_TCP_LAYOUT if set)
--            - MCP layout (forced to FORCE_MCP_LAYOUT if set)
--            - monitoring OFF (I_RECMON = 0)
--            - no master/parent send (B_MAINSEND = 0)
--
--   Parent/child logic (source side):
--     - If a source track has a parent track that is also a source:
--         => child source.
--     - If a source has children that are sources:
--         => parent source.
--
-- Reverb inheritance:
--   - Each FX track can have a "template" for reverb send level to Reverb Bus.
--   - The template is taken from the FX track's existing send to Reverb Bus (if any)
--     and stored in a track extstate so it survives later promotion/demotion.
--   - Parent FX templates are cloned to child FX tracks:
--       * If parent FX had a reverb send, children get sends at the same level.
--       * If parent FX had NO reverb send, children have NO reverb sends.
--
-- Routing rules:
--   Standalone source "Name" (no source parent track):
--     All FX  --(muted send)-->  Name FX  --> Dialogue Bus
--   and, if Name FX has a reverb template:
--     Name FX  --> Reverb Bus (at template level)
--
--   Parent source "Parent" (folder parent of other source tracks):
--     Parent   --> All FX   (you must create this send yourself)
--     All FX   --(muted send)--> Parent FX   (no Dialogue/Reverb sends)
--     (any existing Parent FX -> Dialogue/Reverb sends are removed when promoted)
--
--   Child source "Child" under parent "Parent":
--     Parent FX --(muted send)--> Child FX  --> Dialogue Bus
--   and, if Parent FX has a reverb template:
--     Child FX  --> Reverb Bus (at parent's template level)
--   else:
--     Child FX: no reverb send.
--
-- Notes:
--   - Safe to run repeatedly; it will not recreate existing "* FX" tracks.
--   - FX buses (All FX, Character FX, Name FX) are bus-only: no master/parent send.
--   - Character FX folder includes ONLY the contiguous block of "… FX" tracks directly below it.
--   - FX tracks appear under Character FX in source order, with children directly under their parent FX.

------------------------------------
-- USER-CONFIGURABLE CONSTANTS
------------------------------------

local NAME_ALL_FX           = "All FX"
local NAME_DIALOGUE_BUS     = "Dialogue Bus"
local NAME_REVERB_BUS       = "Reverb Bus"
local NAME_CHAR_FX_PARENT   = "Character FX"

-- Forced layouts for Character FX and all "... FX" tracks
-- Leave as "" to not force a layout.
local FORCE_TCP_LAYOUT      = "75%_B"
local FORCE_MCP_LAYOUT      = ""

-- Key used in P_EXT to store template reverb level (linear scalar)
local REVERB_TEMPLATE_KEY   = "DW_ReverbTemplate"

------------------------------------
-- HELPERS
------------------------------------
local function msg(s)
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
end

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
  return math.floor(num - 1 + 0.5)  -- 0-based
end

local function ends_with_fx(name)
  return name:sub(-3) == " FX"
end

-- Ensure an audio send exists: src -> dst.
-- Optionally set mute state and volume (linear).
-- Returns the send index (0-based).
local function ensure_send(src_tr, dst_tr, muted, vol_linear)
  local category = 0 -- sends
  local num_sends = reaper.GetTrackNumSends(src_tr, category)

  for i = 0, num_sends - 1 do
    local dest_ptr = reaper.GetTrackSendInfo_Value(src_tr, category, i, "P_DESTTRACK")
    if dest_ptr == dst_tr then
      if muted ~= nil then
        reaper.SetTrackSendInfo_Value(src_tr, category, i, "B_MUTE", muted and 1 or 0)
      end
      if vol_linear ~= nil then
        reaper.SetTrackSendInfo_Value(src_tr, category, i, "D_VOL", vol_linear)
      end
      return i
    end
  end

  local new_idx = reaper.CreateTrackSend(src_tr, dst_tr)
  if new_idx >= 0 then
    if muted ~= nil then
      reaper.SetTrackSendInfo_Value(src_tr, category, new_idx, "B_MUTE", muted and 1 or 0)
    end
    if vol_linear ~= nil then
      reaper.SetTrackSendInfo_Value(src_tr, category, new_idx, "D_VOL", vol_linear)
    end
  end
  return new_idx
end

-- Remove any send(s) from src_tr to dst_tr.
local function remove_send_if_exists(src_tr, dst_tr)
  local category = 0
  local num_sends = reaper.GetTrackNumSends(src_tr, category)
  for i = num_sends - 1, 0, -1 do
    local dest_ptr = reaper.GetTrackSendInfo_Value(src_tr, category, i, "P_DESTTRACK")
    if dest_ptr == dst_tr then
      reaper.RemoveTrackSend(src_tr, category, i)
    end
  end
end

-- Find an FX child under Character FX by name within the contiguous FX block.
local function find_child_fx(char_fx_tr, child_name)
  local proj = 0
  local char_idx = get_track_index(char_fx_tr)
  if not char_idx then return nil end

  local track_count = reaper.CountTracks(proj)
  for i = char_idx + 1, track_count - 1 do
    local tr   = reaper.GetTrack(proj, i)
    local name = get_track_name(tr)
    if not name or name == "" or not ends_with_fx(name) then
      -- first non-"… FX" track after the FX block: stop
      break
    end
    if name == child_name then
      return tr
    end
  end
  return nil
end

-- Common setup for FX tracks (new or reused)
local function setup_fx_track_common(fx_tr)
  if not fx_tr then return end
  -- monitoring OFF
  reaper.SetMediaTrackInfo_Value(fx_tr, "I_RECMON", 0)
  -- disable master/parent send
  reaper.SetMediaTrackInfo_Value(fx_tr, "B_MAINSEND", 0)
  -- force layouts if configured
  if FORCE_TCP_LAYOUT ~= "" then
    reaper.GetSetMediaTrackInfo_String(fx_tr, "P_TCP_LAYOUT", FORCE_TCP_LAYOUT, true)
  end
  if FORCE_MCP_LAYOUT ~= "" then
    reaper.GetSetMediaTrackInfo_String(fx_tr, "P_MCP_LAYOUT", FORCE_MCP_LAYOUT, true)
  end
end

-- Get or establish a "reverb template" for an FX track.
-- Returns: has_template (bool), vol_linear (number or nil).
local function get_reverb_template_for_fx(fx_tr, reverb_bus_tr)
  if not fx_tr or not reverb_bus_tr then
    return false, nil
  end

  -- 1) Try extstate
  local _, ext = reaper.GetSetMediaTrackInfo_String(
    fx_tr,
    "P_EXT:" .. REVERB_TEMPLATE_KEY,
    "",
    false
  )
  if ext ~= "" then
    local v = tonumber(ext)
    if v then
      return true, v
    end
  end

  -- 2) Try to read an existing send to Reverb Bus
  local category = 0
  local num_sends = reaper.GetTrackNumSends(fx_tr, category)
  for i = 0, num_sends - 1 do
    local dest_ptr = reaper.GetTrackSendInfo_Value(fx_tr, category, i, "P_DESTTRACK")
    if dest_ptr == reverb_bus_tr then
      local vol = reaper.GetTrackSendInfo_Value(fx_tr, category, i, "D_VOL")
      if vol and vol > 0 then
        local vol_str = string.format("%.12f", vol)
        reaper.GetSetMediaTrackInfo_String(
          fx_tr,
          "P_EXT:" .. REVERB_TEMPLATE_KEY,
          vol_str,
          true
        )
        return true, vol
      else
        -- Explicit zero/very low could be treated as "no reverb"
        return false, nil
      end
    end
  end

  -- No extstate and no current send => no template (e.g. Internal FX).
  return false, nil
end

local function rebuild_char_fx_folder(char_fx_tr)
  local proj = 0
  local char_idx = get_track_index(char_fx_tr)
  if not char_idx then return end

  local track_count = reaper.CountTracks(proj)
  local fx_block_idxs = {}

  -- Collect contiguous "... FX" tracks immediately after Character FX
  for i = char_idx + 1, track_count - 1 do
    local tr   = reaper.GetTrack(proj, i)
    local name = get_track_name(tr)
    if name and ends_with_fx(name) then
      table.insert(fx_block_idxs, i)
    else
      -- First non-"... FX" track: stop the block
      break
    end
  end

  if #fx_block_idxs == 0 then
    -- No FX children: Character FX is not a folder
    reaper.SetMediaTrackInfo_Value(char_fx_tr, "I_FOLDERDEPTH", 0)
    return
  end

  -- Character FX is folder start
  reaper.SetMediaTrackInfo_Value(char_fx_tr, "I_FOLDERDEPTH", 1)

  -- All but last child: depth 0
  for n = 1, #fx_block_idxs do
    local tr = reaper.GetTrack(proj, fx_block_idxs[n])
    local depth = (n == #fx_block_idxs) and -1 or 0
    reaper.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", depth)
  end
end

------------------------------------
-- MAIN
------------------------------------

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local proj = 0

-- Anchor tracks
local all_fx_tr     = get_track_by_name(NAME_ALL_FX)
local dialog_bus_tr = get_track_by_name(NAME_DIALOGUE_BUS)
local reverb_bus_tr = get_track_by_name(NAME_REVERB_BUS)

if not all_fx_tr or not dialog_bus_tr or not reverb_bus_tr then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Build Character FX Tracks and Sends (FAILED - missing anchors)", -1)
  local missing = {}
  if not all_fx_tr     then table.insert(missing, NAME_ALL_FX) end
  if not dialog_bus_tr then table.insert(missing, NAME_DIALOGUE_BUS) end
  if not reverb_bus_tr then table.insert(missing, NAME_REVERB_BUS) end
  reaper.ShowMessageBox(
    "Missing required tracks:\n" .. table.concat(missing, "\n"),
    "Build Character FX Tracks and Sends",
    0
  )
  return
end

-- Ensure All FX is bus-only
reaper.SetMediaTrackInfo_Value(all_fx_tr, "B_MAINSEND", 0)

local all_fx_idx = get_track_index(all_fx_tr)
if not all_fx_idx then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Build Character FX Tracks and Sends (FAILED - cannot index All FX)", -1)
  return
end

-- 1) Ensure Character FX track exists immediately after All FX
local char_fx_tr = get_track_by_name(NAME_CHAR_FX_PARENT)
if not char_fx_tr then
  local char_fx_insert_idx = all_fx_idx + 1
  reaper.InsertTrackAtIndex(char_fx_insert_idx, true)
  reaper.TrackList_AdjustWindows(false)

  char_fx_tr = reaper.GetTrack(proj, char_fx_insert_idx)
  reaper.GetSetMediaTrackInfo_String(char_fx_tr, "P_NAME", NAME_CHAR_FX_PARENT, true)
end

local char_fx_idx = get_track_index(char_fx_tr)
if not char_fx_idx then
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Build Character FX Tracks and Sends (FAILED - cannot index Character FX)", -1)
  return
end

-- If Character FX is not immediately after All FX, move it there (simple case: no existing FX children).
if char_fx_idx ~= all_fx_idx + 1 then
  reaper.SetOnlyTrackSelected(char_fx_tr)
  reaper.ReorderSelectedTracks(all_fx_idx + 1, 0)
  char_fx_tr = get_track_by_name(NAME_CHAR_FX_PARENT)
  char_fx_idx = get_track_index(char_fx_tr)
end

-- Ensure Character FX is bus-only, monitoring off, and layout forced
reaper.SetMediaTrackInfo_Value(char_fx_tr, "I_RECMON", 0)
reaper.SetMediaTrackInfo_Value(char_fx_tr, "B_MAINSEND", 0)
if FORCE_TCP_LAYOUT ~= "" then
  reaper.GetSetMediaTrackInfo_String(char_fx_tr, "P_TCP_LAYOUT", FORCE_TCP_LAYOUT, true)
end
if FORCE_MCP_LAYOUT ~= "" then
  reaper.GetSetMediaTrackInfo_String(char_fx_tr, "P_MCP_LAYOUT", FORCE_MCP_LAYOUT, true)
end

-- 2) Collect source tracks above All FX whose names do NOT end with " FX"
local sources      = {}
local source_by_tr = {}

local track_count = reaper.CountTracks(proj)
for i = 0, track_count - 1 do
  local tr = reaper.GetTrack(proj, i)
  if tr == all_fx_tr then
    break
  end

  local name = get_track_name(tr)
  if name ~= "" and not ends_with_fx(name) then
    local entry = {
      track               = tr,
      name                = name,
      idx                 = i,
      parent              = nil,
      is_parent           = false,
      is_child            = false,
      fx_track            = nil,
      has_reverb_template = false,
      reverb_vol          = nil,
    }
    table.insert(sources, entry)
    source_by_tr[tr] = entry
  end
end

-- 2b) Detect duplicate source names (problematic for Name -> Name FX mapping)
local name_seen = {}
for _, entry in ipairs(sources) do
  if name_seen[entry.name] then
    msg("WARNING: Duplicate source name '" .. entry.name ..
        "' found above '" .. NAME_ALL_FX ..
        "'. Routing assumes unique names; please rename one of these tracks.")
  else
    name_seen[entry.name] = true
  end
end

-- 3) Classify parent vs child using REAPER's parent track relationship
for _, entry in ipairs(sources) do
  local tr        = entry.track
  local parent_tr = reaper.GetParentTrack(tr)
  if parent_tr then
    local parent_entry = source_by_tr[parent_tr]
    if parent_entry then
      entry.parent            = parent_entry
      entry.is_child          = true
      parent_entry.is_parent  = true
    end
  end
end

-- 4) For each source, find or create its FX track under Character FX
--    FX tracks are ordered to mirror source order, with children directly after their parent's FX.
local families_last_fx = {}  -- key: parent-entry-or-standalone-entry -> last FX track in that family

for _, entry in ipairs(sources) do
  local fx_name = entry.name .. " FX"

  -- Try to find existing FX child immediately under Character FX
  local fx_tr = find_child_fx(char_fx_tr, fx_name)

  if not fx_tr then
    -- Determine where to insert this FX track
    local insert_after_tr

    if entry.is_child and entry.parent and entry.parent.fx_track then
      -- Child: insert after the last FX in the parent's family (parent FX or last child FX)
      local parent_entry = entry.parent
      local last_in_family = families_last_fx[parent_entry] or parent_entry.fx_track
      insert_after_tr = last_in_family or char_fx_tr
    else
      -- Standalone or parent without an FX yet: insert after the last FX in the entire FX block
      local proj = 0
      local char_idx = get_track_index(char_fx_tr)
      local track_count = reaper.CountTracks(proj)
      local last_fx_tr = nil

      for i = char_idx + 1, track_count - 1 do
        local tr   = reaper.GetTrack(proj, i)
        local name = get_track_name(tr)
        if name and ends_with_fx(name) then
          last_fx_tr = tr
        else
          break
        end
      end

      insert_after_tr = last_fx_tr or char_fx_tr
    end

    local insert_idx = get_track_index(insert_after_tr) + 1
    reaper.InsertTrackAtIndex(insert_idx, true)
    reaper.TrackList_AdjustWindows(false)

    fx_tr = reaper.GetTrack(proj, insert_idx)
    reaper.GetSetMediaTrackInfo_String(fx_tr, "P_NAME", fx_name, true)
  end

  -- Common FX track setup (monitoring off, bus-only, forced layout)
  setup_fx_track_common(fx_tr)

  -- Inherit colour (only) from source track; layout now forced
  local src_tr  = entry.track
  local src_col = reaper.GetMediaTrackInfo_Value(src_tr, "I_CUSTOMCOLOR")
  reaper.SetMediaTrackInfo_Value(fx_tr, "I_CUSTOMCOLOR", src_col)

  entry.fx_track = fx_tr

  -- Update family "last FX" pointer
  if entry.is_child and entry.parent then
    families_last_fx[entry.parent] = fx_tr
  else
    families_last_fx[entry] = fx_tr
  end
end

-- 5) Rebuild Character FX folder structure from contiguous FX block
rebuild_char_fx_folder(char_fx_tr)

-- 6) Precompute reverb templates for all FX tracks
for _, entry in ipairs(sources) do
  if entry.fx_track then
    local has_t, vol = get_reverb_template_for_fx(entry.fx_track, reverb_bus_tr)
    entry.has_reverb_template = has_t
    entry.reverb_vol          = vol
  end
end

-- 7) Build routing: sends between All FX / Parent FX / Child FX / Dialogue / Reverb
for _, entry in ipairs(sources) do
  local fx_tr = entry.fx_track

  if entry.is_child then
    -- Child source: Parent FX -> Child FX (muted), Child FX -> Dialogue + inherited Reverb
    local parent_entry = entry.parent
    if parent_entry and parent_entry.fx_track then
      local parent_fx_tr = parent_entry.fx_track

      -- Parent FX -> Child FX (muted)
      ensure_send(parent_fx_tr, fx_tr, true, nil)

      -- Child FX -> Dialogue Bus (unmuted)
      ensure_send(fx_tr, dialog_bus_tr, false, nil)

      -- Child FX -> Reverb Bus (inherits parent template)
      if parent_entry.has_reverb_template and parent_entry.reverb_vol then
        ensure_send(fx_tr, reverb_bus_tr, false, parent_entry.reverb_vol)
      else
        -- Parent explicitly has no reverb => remove any reverb send on child
        remove_send_if_exists(fx_tr, reverb_bus_tr)
      end
    else
      -- Fallback: treat as standalone if parent FX missing
      ensure_send(all_fx_tr, fx_tr, true, nil)
      ensure_send(fx_tr, dialog_bus_tr, false, nil)

      if entry.has_reverb_template and entry.reverb_vol then
        ensure_send(fx_tr, reverb_bus_tr, false, entry.reverb_vol)
      else
        remove_send_if_exists(fx_tr, reverb_bus_tr)
      end
    end

  elseif entry.is_parent then
    -- Parent source: All FX -> Parent FX (muted), no Dialogue/Reverb sends.
    ensure_send(all_fx_tr, fx_tr, true, nil)

    -- Remove any old Parent FX -> Dialogue/Reverb sends from standalone days
    remove_send_if_exists(fx_tr, dialog_bus_tr)
    remove_send_if_exists(fx_tr, reverb_bus_tr)

  else
    -- Standalone source: All FX -> Name FX (muted), Name FX -> Dialogue/Reverb (if template)
    ensure_send(all_fx_tr, fx_tr, true, nil)
    ensure_send(fx_tr, dialog_bus_tr, false, nil)

    if entry.has_reverb_template and entry.reverb_vol then
      ensure_send(fx_tr, reverb_bus_tr, false, entry.reverb_vol)
    else
      -- Explicitly no reverb template => no reverb send
      remove_send_if_exists(fx_tr, reverb_bus_tr)
    end
  end
end

reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Build Character FX Tracks and Sends (idempotent, reverb inheritance, bus-only FX, fixed folder layout + ordered FX)", -1)
