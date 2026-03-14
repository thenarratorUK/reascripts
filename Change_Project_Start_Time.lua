local pos = reaper.GetCursorPosition()
reaper.SNM_SetDoubleConfigVar("projtimeoffs", -pos)
reaper.UpdateTimeline()