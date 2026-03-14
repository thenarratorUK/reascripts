-- @description Play/Pause; if pausing while playing, move "Proofed up to here" marker to play cursor
-- @version 1.0
-- @author David
-- @about
--   If stopped/paused: toggles Play/Pause (command 40073).
--   If playing: toggles Play/Pause, deletes any markers named "Proofed up to here",
--   then adds a dark-blue marker with that name at the play cursor position.

local PROJ = 0
local MARKER_NAME = "Proofed up to here"

local function is_playing()
  local state = reaper.GetPlayState() -- 1=playing, 2=paused, 4=recording
  return (state & 1) == 1
end

local function delete_named_markers(name_to_delete)
  local _, num_markers, num_regions = reaper.CountProjectMarkers(PROJ)
  local total = num_markers + num_regions
  local ids_to_delete = {}

  for i = 0, total - 1 do
    local retval, isrgn, _, _, name, markrgnindexnumber = reaper.EnumProjectMarkers3(PROJ, i)
    if retval and (not isrgn) and name == name_to_delete then
      ids_to_delete[#ids_to_delete + 1] = markrgnindexnumber
    end
  end

  for i = 1, #ids_to_delete do
    reaper.DeleteProjectMarker(PROJ, ids_to_delete[i], false)
  end
end

local function add_marker_at_pos(name, pos)
  -- Dark blue (approx): RGB(0,0,139)
  local native = reaper.ColorToNative(0, 0, 139) | 0x1000000
  reaper.AddProjectMarker2(PROJ, false, pos, 0, name, -1, native)
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

if not is_playing() then
  reaper.Main_OnCommand(40328, 0) -- Transport: Play/Stop (Moves Edit Cursor on Stop)
else
  reaper.Main_OnCommand(40328, 0)     -- Transport: Play/Stop (Moves Edit Cursor on Stop)
  local pos = reaper.GetPlayPosition() -- play cursor position at trigger time
  delete_named_markers(MARKER_NAME)
  add_marker_at_pos(MARKER_NAME, pos)
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock('Play/Pause; update "Proofed up to here" marker', -1)
