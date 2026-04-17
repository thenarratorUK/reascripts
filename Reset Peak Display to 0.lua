-- @description Reset Peak Display to 0
-- @version 1.0
-- @author David Winter
function Reset_Peak_Display ()
  reaper.SNM_SetDoubleConfigVar('projpeaksgain', 1) -- 0 dB in log scale
  reaper.UpdateArrange()
end

Reset_Peak_Display ()
