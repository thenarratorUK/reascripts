-- @description Increase Peak Display
-- @version 1.0
-- @author David Winter
function Add_Peak_Display ()

  Gain = 1 -- db You can put your own value here (Not more than 36db)
  GetGain = reaper.SNM_GetDoubleConfigVar('projpeaksgain', 0) --Get displayed gain
  Gain_Db_log = math.exp( Gain * 0.115129254 ) -- Translate Gain var to Log Scale thanx Xraym blog
  Max_Db_Display = math.exp( (36 - Gain) * 0.115129254 )
    if(GetGain > Max_Db_Display) -- new gain can't be more then 36db
    then
    NEWgain = 63.095732972255 -- Log scale number for 36db
    else
    NEWgain = GetGain * Gain_Db_log --Add gain
    end
  dB =  reaper.SNM_SetDoubleConfigVar('projpeaksgain', NEWgain)
  reaper.UpdateArrange()
--reaper.ShowConsoleMsg(NEWgain.."\n") -- Use it to check log scale

end

Add_Peak_Display ()
