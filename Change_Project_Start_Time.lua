-- @description Change_Project_Start_Time
-- @version 1.0
-- @author David Winter
local pos = reaper.GetCursorPosition()
reaper.SNM_SetDoubleConfigVar("projtimeoffs", -pos)
reaper.UpdateTimeline()