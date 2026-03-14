-- Move edit cursor to next COLOURED item that is NOT orange,
-- excluding items on specific tracks OR any of their descendant tracks.
-- Scans all tracks in the current project.

-- ========== CONFIG ==========
local ORANGE_MODE = "hsv"  -- "hsv" or "rgb"

-- If ORANGE_MODE == "rgb":
local ORANGE_RGB = {255, 128, 0}   -- change to your "orange"
local ORANGE_RGB_TOL = 30          -- larger = more forgiving

-- If ORANGE_MODE == "hsv":
local ORANGE_HUE_MIN = 15          -- degrees
local ORANGE_HUE_MAX = 55          -- degrees
local ORANGE_SAT_MIN = 0.20        -- 0..1
local ORANGE_VAL_MIN = 0.10        -- 0..1

-- Track names to exclude (case-insensitive, trimmed)
local EXCLUDED_TRACK_NAMES = {
  "Narration",
  "Internal",
  "System",
  "Special 1",
  "Special 2",
  "Dialogue 1",
  "Dialogue 2",
  "Room Tone",
}
-- ============================

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function build_excluded_set(names)
  local set = {}
  for _, n in ipairs(names) do
    set[trim(n):lower()] = true
  end
  return set
end

local EXCLUDED = build_excluded_set(EXCLUDED_TRACK_NAMES)

local function get_track_name(track)
  local _, name = reaper.GetTrackName(track, "")
  name = name or ""
  return trim(name)
end

-- Prefer native GetParentTrack if available; fall back to P_PARTRACK.
local function get_parent_track(track)
  if reaper.GetParentTrack then
    local p = reaper.GetParentTrack(track)
    if p and p ~= 0 then return p end
  end
  local p = reaper.GetMediaTrackInfo_Value(track, "P_PARTRACK")
  if p and p ~= 0 then return p end
  return nil
end

-- Exclude if this track OR any ancestor is in EXCLUDED.
local function is_track_excluded_or_descendant(track)
  local t = track
  while t do
    local name = get_track_name(t):lower()
    if EXCLUDED[name] then return true end
    t = get_parent_track(t)
  end
  return false
end

local function rgb_to_hsv(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local mx = math.max(r, g, b)
  local mn = math.min(r, g, b)
  local d = mx - mn

  local h = 0
  if d ~= 0 then
    if mx == r then
      h = ((g - b) / d) % 6
    elseif mx == g then
      h = ((b - r) / d) + 2
    else
      h = ((r - g) / d) + 4
    end
    h = h * 60
  end

  local s = (mx == 0) and 0 or (d / mx)
  local v = mx
  return h, s, v
end

local function is_orange_rgb(r, g, b)
  local dr = r - ORANGE_RGB[1]
  local dg = g - ORANGE_RGB[2]
  local db = b - ORANGE_RGB[3]
  local dist = math.sqrt(dr*dr + dg*dg + db*db)
  return dist <= ORANGE_RGB_TOL
end

local function is_orange_hsv(r, g, b)
  local h, s, v = rgb_to_hsv(r, g, b)
  if s < ORANGE_SAT_MIN or v < ORANGE_VAL_MIN then return false end
  if ORANGE_HUE_MIN <= ORANGE_HUE_MAX then
    return (h >= ORANGE_HUE_MIN and h <= ORANGE_HUE_MAX)
  else
    return (h >= ORANGE_HUE_MIN or h <= ORANGE_HUE_MAX)
  end
end

local function is_orange(r, g, b)
  if ORANGE_MODE == "rgb" then
    return is_orange_rgb(r, g, b)
  else
    return is_orange_hsv(r, g, b)
  end
end

local function move_to_next_coloured_non_orange_item_excluding_tracks()
  local proj = 0
  local cursor_pos = reaper.GetCursorPosition()
  local item_count = reaper.CountMediaItems(proj)

  local best_item = nil
  local best_pos  = math.huge
  local epsilon   = 1e-9

  for i = 0, item_count - 1 do
    local item = reaper.GetMediaItem(proj, i)
    if item then
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      if pos > cursor_pos + epsilon and pos < best_pos then
        local track = reaper.GetMediaItem_Track(item)
        if track and not is_track_excluded_or_descendant(track) then
          -- 0 means "no color"
          local native_col = reaper.GetDisplayedMediaItemColor(item)
          if native_col ~= 0 then
            local r, g, b = reaper.ColorFromNative(native_col)
            if r and not is_orange(r, g, b) then
              best_item = item
              best_pos  = pos
            end
          end
        end
      end
    end
  end

  if best_item then
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    local track = reaper.GetMediaItem_Track(best_item)
    if track then
      reaper.Main_OnCommand(40297, 0) -- Track: Unselect all tracks
      reaper.SetTrackSelected(track, true)
    end

    reaper.Main_OnCommand(40289, 0) -- Item: Unselect all items
    reaper.SetMediaItemSelected(best_item, true)

    reaper.SetEditCurPos(best_pos, true, false)

    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Move cursor to next coloured non-orange item (excluding tracks)", -1)
  end
end

move_to_next_coloured_non_orange_item_excluding_tracks()
