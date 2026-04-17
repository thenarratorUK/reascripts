-- @description Decrease Peak Display
-- @version 1.0
-- @author David Winter
function Decrease_Peak_Display ()

  Gain = 1 -- db You can put your own value here (Not more than 36db)
  GetGain = reaper.SNM_GetDoubleConfigVar('projpeaksgain', 0) --Get displayed gain
  Gain_Db_log = math.exp( Gain * 0.115129254 ) -- Translate Gain var to Log Scale thanx Xraym blog
    if(GetGain < Gain_Db_log) -- new gain can't be less then 0db
    then
    NEWgain = 1 --0db log
    else
    NEWgain = GetGain / Gain_Db_log -- subtract desired gain
    end
  dB =  reaper.SNM_SetDoubleConfigVar('projpeaksgain', NEWgain)
  reaper.UpdateArrange()
--reaper.ShowConsoleMsg(NEWgain.."\n") -- Use it to check log scale

end

Decrease_Peak_Display ()
