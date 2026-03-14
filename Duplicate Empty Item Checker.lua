--[[
ReaScript Name: List duplicate item notes across project
Description:
  - Scans all items in the current project.
  - Finds item notes that appear on two or more items.
  - Prints the note text and a list of items sharing it
    (track number, start position, length).
Author: David Winter
Version: 1.0
]]

local function msg(s)
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
end

reaper.ClearConsole()

local proj = 0 -- current project
local num_items = reaper.CountMediaItems(proj)

-- Map: note_text -> { item1, item2, ... }
local note_map = {}

for i = 0, num_items - 1 do
  local item = reaper.GetMediaItem(proj, i)
  if item then
    -- Get item notes
    local _, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
    if notes and notes ~= "" then
      if not note_map[notes] then
        note_map[notes] = {}
      end
      table.insert(note_map[notes], item)
    end
  end
end

local found_any = false

for notes, items in pairs(note_map) do
  if #items >= 2 then
    found_any = true
    msg("==================================================")
    msg("Duplicate item notes (used " .. #items .. " times):")
    msg(notes)
    msg("Items with these notes:")

    for _, item in ipairs(items) do
      local pos   = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local len   = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local track = reaper.GetMediaItem_Track(item)
      local track_idx = track and reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or -1

      msg(string.format("  Track %d | Start: %.3f s | Length: %.3f s",
                        track_idx, pos, len))
    end

    msg("") -- blank line between groups
  end
end

if not found_any then
  msg("No duplicate item notes found (no note text shared by two or more items).")
end
