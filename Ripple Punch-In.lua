-- @description Ripple Punch-In
-- @version 1.0
-- @author David Winter
-- Smart Ripple Insert Toggle
-- Replaces a cycle action for starting/stopping ripple inserts
-- Author: David Winter


local playState = reaper.GetPlayState()

if playState > 0 then
  -- Transport is playing or recording → End Ripple Insert
  reaper.Main_OnCommand(reaper.NamedCommandLookup("_RS6cca0e2eccfc3cbd563bf061c39b9a4e540c0382"), 0)
else
  -- Transport is stopped or paused → Start Ripple Insert
  reaper.Main_OnCommand(reaper.NamedCommandLookup("_RS65a3b3b1e39ff25c5c9bd0d1967b3892461cff42"), 0)
end
