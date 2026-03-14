function Rename_Track_To_Breaths()
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then return end

  local retval, current_name = reaper.GetTrackName(track, "")
  
  if current_name ~= "Room Tone" and current_name ~= "Recording" and current_name ~= "Live" then
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "Breaths", true)
  end
end

Rename_Track_To_Breaths()
