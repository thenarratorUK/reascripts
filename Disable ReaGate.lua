-- @description Disable ReaGate
-- @version 1.0
-- @author David Winter

-- Begin undo block
reaper.Undo_BeginBlock()

-- Get the selected track
local track = reaper.GetSelectedTrack(0, 0)
if not track then return end

-- Find the ReaGate plugin
local fx_index = -1
for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    local success, fx_name = reaper.TrackFX_GetFXName(track, i, "")
    if success and fx_name and fx_name:match("ReaGate") then
        fx_index = i
        break
    end
end

-- If ReaGate is found, find the "Dry" parameter by checking its name
if fx_index >= 0 then
    local dry_param_index = -1
    for param = 0, reaper.TrackFX_GetNumParams(track, fx_index) - 1 do
        local retval, param_name = reaper.TrackFX_GetParamName(track, fx_index, param, "")
        if retval and param_name and param_name:match("Dry") then
            dry_param_index = param
            break
        end
    end

    if dry_param_index >= 0 then
        -- Touch the 'Dry' parameter to update its envelope
        local current_dry_value = reaper.TrackFX_GetParam(track, fx_index, dry_param_index)
        reaper.TrackFX_SetParam(track, fx_index, dry_param_index, current_dry_value)
        
        local envelope = reaper.GetFXEnvelope(track, fx_index, dry_param_index, true)
--        if envelope then
--            reaper.SetEnvelopeInfo_Value(envelope, "VIS", 1)
--        end
    -- Run the custom action by its command ID (41983) to show the envelope for the last touched parameter
    reaper.Main_OnCommand(41983, 0)
    
    -- Run command 41872 (Select FX envelope 01) to select the envelope
    reaper.Main_OnCommand(41872, 0)
    
    -- Run command 40726 (Insert 4 envelope points at time selection)
    reaper.Main_OnCommand(40726, 0)
    
    -- Run command 40415 (Reset selected points to zero/center)
    reaper.Main_OnCommand(40415, 0)
end
end

-- Hide all FX envelopes for selected tracks using the SWS/BR action (command ID)
reaper.Main_OnCommand(reaper.NamedCommandLookup("_BR_HIDE_FX_ENV_SEL_TRACK"), 0)

-- End undo block
reaper.Undo_EndBlock("Touch Dry and Modify Envelope", -1)
