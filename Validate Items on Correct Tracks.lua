--[[
ReaScript Name: Validate and optionally fix bracket name vs track assignment
Description:
  1) Gather list of all track names.
  2) For each EMPTY item:
       - Find [...] in item notes.
       - Extract text AFTER first underscore, e.g. [06646_Klaarg] -> "Klaarg".
       - If that name matches a track name AND the item is not on that track,
         report as mismatch.
  3) If mismatches exist, prompt:
       "Fix locations? Yes/No"
     - If Yes: move each mismatching item to its intended track.
Author: David Winter
Version: 1.1
]]

local function msg(s)
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
end

reaper.ClearConsole()

local proj = 0

------------------------------------------------------------
-- 1) Collect track names into lookup: name -> track pointer
------------------------------------------------------------
local num_tracks = reaper.CountTracks(proj)
local track_names = {}

for i = 0, num_tracks - 1 do
  local tr = reaper.GetTrack(proj, i)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  if name and name ~= "" then
    -- If multiple tracks share the same name, the last one wins.
    track_names[name] = tr
  end
end

------------------------------------------------------------
-- 2) Iterate items and detect mismatches
------------------------------------------------------------
local num_items = reaper.CountMediaItems(proj)
local mismatches = {}
local mismatch_count = 0

for i = 0, num_items - 1 do
  local item = reaper.GetMediaItem(proj, i)

  -- Only evaluate EMPTY items (no takes)
  if reaper.CountTakes(item) == 0 then
    local _, notes = reaper.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)

    if notes and notes ~= "" then
      -- Extract content inside first pair of brackets: [ .... ]
      local bracket_content = notes:match("%[(.-)%]")
      if bracket_content then
        -- Extract part AFTER the first underscore
        -- Example: "06646_Klaarg" -> "Klaarg"
        local after_underscore = bracket_content:match("^[^_]+_(.+)$")

        if after_underscore and after_underscore ~= "" then
          local tr = reaper.GetMediaItem_Track(item)
          local actual_track_name = ""
          if tr then
            actual_track_name = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false))
          end

          local intended_track_name = after_underscore
          local target_track = track_names[intended_track_name]

          -- Only care if:
          --  - The extracted name matches a known track name
          --  - The item is NOT already on that track
          if target_track and intended_track_name ~= actual_track_name then
            mismatch_count = mismatch_count + 1

            -- Store for optional fixing
            table.insert(mismatches, {
              item          = item,
              target_track  = target_track,
              intended_name = intended_track_name,
              actual_name   = actual_track_name
            })

            -- Log details
            msg("--------------------------------------------------")
            msg("MISMATCH FOUND")
            msg("Item Notes: " .. notes)
            msg("Extracted Name: " .. intended_track_name)
            msg("Actual Track: " .. (actual_track_name ~= "" and actual_track_name or "[Unnamed Track]"))

            local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            msg(string.format("Item Position: %.3f  Length: %.3f", pos, len))
          end
        end
      end
    end
  end
end

------------------------------------------------------------
-- 3) No mismatches -> message and exit
------------------------------------------------------------
if mismatch_count == 0 then
  msg("No mismatching items detected.")
  return
end

msg("")
msg("Total mismatching items: " .. mismatch_count)
msg("")

------------------------------------------------------------
-- 4) Ask whether to fix locations
------------------------------------------------------------
local ret = reaper.ShowMessageBox(
  "Detected " .. mismatch_count .. " item(s) whose bracket name matches a track\n"
  .. "but which are on a different track.\n\n"
  .. "Fix locations now (move items to matching tracks)?",
  "Fix Locations?",
  4 -- YES / NO
)

-- ShowMessageBox returns:
-- 6 = Yes, 7 = No
if ret ~= 6 then
  -- User chose No -> do nothing further
  return
end

------------------------------------------------------------
-- 5) Move mismatching items to their intended tracks
------------------------------------------------------------
reaper.Undo_BeginBlock2(proj)

for _, m in ipairs(mismatches) do
  if m.target_track and m.item then
    reaper.MoveMediaItemToTrack(m.item, m.target_track)
  end
end

reaper.Undo_EndBlock2(proj, "Fix mismatched items by bracket track name", -1)
reaper.UpdateArrange()
reaper.UpdateTimeline()
