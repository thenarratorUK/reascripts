-- @description Learn Adaptive Phase Rotator from Time Selection
-- @author David Winter
-- @version 0.3.0
-- @provides
--   [effect] Effects/Adaptive Phase Rotator.jsfx
-- @about
--   Analyses the selected track at the input of Adaptive Phase Rotator.
--   The time selection defines the learning duration.
--
--   The script duplicates the selected track, keeps only the FX preceding the
--   rotator, adds a clean analysis instance, and uses the SWS mono stem render
--   action to process the selected range offline. It then writes the learned
--   angle back to the original plug-in and removes all temporary material.
--   If the selected track contains multiple instances, the first instance
--   whose learned angle is zero is used.
--
--   Requirements:
--     - REAPER 7
--     - SWS/S&M extension
--     - Exactly one selected track
--     - A non-empty time selection
--     - Adaptive Phase Rotator on the selected track

local PROJECT = 0
local FX_NAME_FRAGMENT = "Adaptive Phase Rotator"
local SWS_RENDER_COMMAND = "_SWS_AWRENDERMONOSMART"
local DUPLICATE_TRACK_COMMAND = 40062
local TEMP_TRACK_PREFIX = "__APR_LEARN_TEMP__"
local AUTOMATION_SECTION = "AdaptivePhaseRotator"
local ANALYSIS_ARM_DELAY_SECONDS = 0.15
local LEARNING_GMEM = "AdaptivePhaseRotatorLearn"

local saved_selected_tracks = {}
local saved_selected_items = {}
local temporary_tracks = {}
local temporary_media_paths = {}
local ui_refresh_locked = false
local undo_open = false
local silent_automation =
  reaper.GetExtState(AUTOMATION_SECTION, "SilentLearning") == "1"

local function set_automation_result(status, detail, angle, recovered, duration)
  reaper.SetExtState(AUTOMATION_SECTION, "LastStatus", status or "", false)
  reaper.SetExtState(AUTOMATION_SECTION, "LastDetail", detail or "", false)
  reaper.SetExtState(
    AUTOMATION_SECTION, "LastAngle", angle and tostring(angle) or "", false)
  reaper.SetExtState(
    AUTOMATION_SECTION, "LastRecovered",
    recovered and tostring(recovered) or "", false)
  reaper.SetExtState(
    AUTOMATION_SECTION, "LastDuration",
    duration and tostring(duration) or "", false)
end

local function message(text, title)
  reaper.MB(text, title or "Adaptive Phase Rotator", 0)
end

local function track_is_valid(track)
  return track and reaper.ValidatePtr2(PROJECT, track, "MediaTrack*")
end

local function item_is_valid(item)
  return item and reaper.ValidatePtr2(PROJECT, item, "MediaItem*")
end

local function save_selection()
  for i = 0, reaper.CountSelectedTracks(PROJECT) - 1 do
    saved_selected_tracks[#saved_selected_tracks + 1] =
      reaper.GetSelectedTrack(PROJECT, i)
  end

  for i = 0, reaper.CountSelectedMediaItems(PROJECT) - 1 do
    saved_selected_items[#saved_selected_items + 1] =
      reaper.GetSelectedMediaItem(PROJECT, i)
  end
end

local function clear_track_selection()
  for i = 0, reaper.CountTracks(PROJECT) - 1 do
    reaper.SetTrackSelected(reaper.GetTrack(PROJECT, i), false)
  end
end

local function select_only_track(track)
  clear_track_selection()
  reaper.SetTrackSelected(track, true)
end

local function restore_selection()
  clear_track_selection()
  for _, track in ipairs(saved_selected_tracks) do
    if track_is_valid(track) then
      reaper.SetTrackSelected(track, true)
    end
  end

  for i = 0, reaper.CountMediaItems(PROJECT) - 1 do
    reaper.SetMediaItemSelected(reaper.GetMediaItem(PROJECT, i), false)
  end
  for _, item in ipairs(saved_selected_items) do
    if item_is_valid(item) then
      reaper.SetMediaItemSelected(item, true)
    end
  end
end

local function track_guid(track)
  return reaper.GetTrackGUID(track)
end

local function collect_track_guids()
  local guids = {}
  for i = 0, reaper.CountTracks(PROJECT) - 1 do
    guids[track_guid(reaper.GetTrack(PROJECT, i))] = true
  end
  return guids
end

local function find_new_tracks(previous_guids)
  local tracks = {}
  for i = 0, reaper.CountTracks(PROJECT) - 1 do
    local track = reaper.GetTrack(PROJECT, i)
    if not previous_guids[track_guid(track)] then
      tracks[#tracks + 1] = track
    end
  end
  return tracks
end

local function get_fx_name(track, fx)
  local ok, name = reaper.TrackFX_GetFXName(track, fx, "")
  return ok and name or ""
end

local function normalized_param_name(name)
  return name:lower():gsub("^%-", ""):gsub("%s+", " ")
end

local function find_parameter(track, fx, wanted)
  wanted = normalized_param_name(wanted)
  for param = 0, reaper.TrackFX_GetNumParams(track, fx) - 1 do
    local ok, name = reaper.TrackFX_GetParamName(track, fx, param, "")
    if ok and normalized_param_name(name) == wanted then
      return param
    end
  end
  return nil
end

local function get_parameter_value(track, fx, param)
  local value = reaper.TrackFX_GetParam(track, fx, param)
  return value
end

local function find_rotator_fx(track)
  local found = {}

  for fx = 0, reaper.TrackFX_GetCount(track) - 1 do
    if get_fx_name(track, fx):find(FX_NAME_FRAGMENT, 1, true) then
      local learned_param = find_parameter(
        track, fx, "Learned angle (set by Learn action)")
      if not learned_param then
        error(string.format(
          "%s at FX slot %d does not expose its learned-angle parameter.",
          FX_NAME_FRAGMENT, fx + 1))
      end

      local angle = get_parameter_value(track, fx, learned_param)
      found[#found + 1] =
        string.format("slot %d = %.2f degrees", fx + 1, angle)

      -- A zero learned angle marks the next unused learning position.
      if math.abs(angle) < 0.001 then
        return fx
      end
    end
  end

  if #found > 0 then
    error(
      "No Adaptive Phase Rotator with a zero learned angle was found.\n\n" ..
      table.concat(found, "\n"))
  end
  return nil
end

local function set_parameter_value(track, fx, param, value)
  local _, minimum, maximum = reaper.TrackFX_GetParam(track, fx, param)
  if maximum <= minimum then
    error("The plug-in reported an invalid parameter range.")
  end
  local normalized = (value - minimum) / (maximum - minimum)
  normalized = math.max(0, math.min(1, normalized))
  if not reaper.TrackFX_SetParamNormalized(track, fx, param, normalized) then
    error("Could not write a plug-in parameter.")
  end
end

local function add_clean_rotator_instance(track, preferred_name)
  local candidates = {
    preferred_name,
    "JS: " .. FX_NAME_FRAGMENT,
    FX_NAME_FRAGMENT,
    "Effects/Adaptive Phase Rotator.jsfx",
  }

  for _, name in ipairs(candidates) do
    if name and name ~= "" then
      local fx = reaper.TrackFX_AddByName(track, name, false, -1)
      if fx and fx >= 0 then
        return fx
      end
    end
  end

  error("Could not add a clean instance of " .. FX_NAME_FRAGMENT ..
        ". Re-scan JSFX in REAPER and try again.")
end

local function duplicate_analysis_track(source_track, source_fx)
  local duplicate_action_name =
    reaper.kbd_getTextFromCmd(DUPLICATE_TRACK_COMMAND, 0) or ""
  if not duplicate_action_name:lower():find("duplicate track", 1, true) then
    error("REAPER command 40062 is not 'Track: Duplicate tracks' in this install.")
  end

  local guids_before_duplicate = collect_track_guids()
  select_only_track(source_track)
  reaper.Main_OnCommand(DUPLICATE_TRACK_COMMAND, 0)

  local duplicated_tracks = find_new_tracks(guids_before_duplicate)
  for _, track in ipairs(duplicated_tracks) do
    temporary_tracks[#temporary_tracks + 1] = track
  end

  if #duplicated_tracks ~= 1 then
    error("The selected track could not be duplicated as one isolated " ..
          "analysis track. Folder-parent tracks are not supported.")
  end

  local duplicate = duplicated_tracks[1]
  reaper.GetSetMediaTrackInfo_String(
    duplicate, "P_NAME", TEMP_TRACK_PREFIX .. tostring(os.time()), true)

  local source_fx_name = get_fx_name(duplicate, source_fx)

  -- Remove the real rotator and every downstream FX. The clean capture
  -- instance is then placed at exactly the signal point being learned.
  for fx = reaper.TrackFX_GetCount(duplicate) - 1, source_fx, -1 do
    reaper.TrackFX_Delete(duplicate, fx)
  end

  local analysis_fx = add_clean_rotator_instance(duplicate, source_fx_name)
  reaper.TrackFX_SetEnabled(duplicate, analysis_fx, true)
  reaper.TrackFX_SetOffline(duplicate, analysis_fx, false)

  local capture_param = find_parameter(
    duplicate, analysis_fx, "Analysis capture")
  if not capture_param then
    error("The installed JSFX does not expose its analysis-capture parameter.")
  end
  set_parameter_value(duplicate, analysis_fx, capture_param, 1)

  -- A newly inserted JSFX can otherwise be cloned for an immediate offline
  -- render before its first @slider reinitialization has reached the audio
  -- instance. Cycle it once after arming capture so the render clone receives
  -- the armed state.
  reaper.TrackFX_SetEnabled(duplicate, analysis_fx, false)
  reaper.TrackFX_SetEnabled(duplicate, analysis_fx, true)
  reaper.TrackFX_SetOffline(duplicate, analysis_fx, true)
  reaper.TrackFX_SetOffline(duplicate, analysis_fx, false)
  if get_parameter_value(duplicate, analysis_fx, capture_param) < 0.5 then
    error("The analysis instance did not retain its capture state.")
  end

  return duplicate, analysis_fx
end

local function collect_track_media_paths(track)
  for item_index = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, item_index)
    for take_index = 0, reaper.CountTakes(item) - 1 do
      local take = reaper.GetTake(item, take_index)
      if take then
        local source = reaper.GetMediaItemTake_Source(take)
        if source then
          local path = reaper.GetMediaSourceFileName(source, "")
          if path and path ~= "" then
            temporary_media_paths[path] = true
          end
        end
      end
    end
  end
end

local function media_path_still_used(path)
  for item_index = 0, reaper.CountMediaItems(PROJECT) - 1 do
    local item = reaper.GetMediaItem(PROJECT, item_index)
    for take_index = 0, reaper.CountTakes(item) - 1 do
      local take = reaper.GetTake(item, take_index)
      if take then
        local source = reaper.GetMediaItemTake_Source(take)
        if source and reaper.GetMediaSourceFileName(source, "") == path then
          return true
        end
      end
    end
  end
  return false
end

local function cleanup()
  for _, track in ipairs(temporary_tracks) do
    if track_is_valid(track) then
      reaper.DeleteTrack(track)
    end
  end
  temporary_tracks = {}

  for path in pairs(temporary_media_paths) do
    if not media_path_still_used(path) then
      os.remove(path)
      os.remove(path .. ".reapeaks")
    end
  end
  temporary_media_paths = {}

  restore_selection()
  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)
end

local function format_duration(seconds)
  local rounded = math.floor(seconds + 0.5)
  local hours = math.floor(rounded / 3600)
  local minutes = math.floor((rounded % 3600) / 60)
  local secs = rounded % 60
  if hours > 0 then
    return string.format("%d:%02d:%02d", hours, minutes, secs)
  end
  return string.format("%d:%02d", minutes, secs)
end

local function prepare_learning()
  if reaper.CountSelectedTracks(PROJECT) ~= 1 then
    error("Select exactly one track containing " .. FX_NAME_FRAGMENT .. ".")
  end

  local source_track = reaper.GetSelectedTrack(PROJECT, 0)
  local source_fx = find_rotator_fx(source_track)
  if not source_fx then
    error(FX_NAME_FRAGMENT .. " was not found on the selected track.")
  end

  local selection_start, selection_end =
    reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local selection_length = selection_end - selection_start
  if selection_length <= 0 then
    error("Create a time selection containing the material to learn.")
  end

  local render_command = reaper.NamedCommandLookup(SWS_RENDER_COMMAND)
  if not render_command or render_command == 0 then
    error("The required SWS action was not found:\n" ..
          "SWS/AW: Render tracks to mono stem tracks, obeying time selection")
  end

  local learned_param = find_parameter(
    source_track, source_fx, "Learned angle (set by Learn action)")
  local headroom_param = find_parameter(
    source_track, source_fx, "Headroom recovered (dB)")
  if not learned_param then
    error("The installed JSFX does not expose its learned-angle parameter.")
  end

  local analysis_track, analysis_fx =
    duplicate_analysis_track(source_track, source_fx)

  return {
    source_track = source_track,
    source_fx = source_fx,
    learned_param = learned_param,
    headroom_param = headroom_param,
    analysis_track = analysis_track,
    analysis_fx = analysis_fx,
    selection_length = selection_length,
    render_command = render_command,
    render_after =
      reaper.time_precise() + ANALYSIS_ARM_DELAY_SECONDS,
  }
end

local function render_learning(context)
  if not track_is_valid(context.source_track) or
     not track_is_valid(context.analysis_track) then
    error("The source or temporary analysis track is no longer available.")
  end

  local capture_param = find_parameter(
    context.analysis_track, context.analysis_fx, "Analysis capture")
  if not capture_param or get_parameter_value(
      context.analysis_track, context.analysis_fx, capture_param) < 0.5 then
    error("The temporary analyzer was not armed before rendering.")
  end

  reaper.gmem_attach(LEARNING_GMEM)
  reaper.gmem_write(0, 0)
  reaper.gmem_write(1, 0)
  reaper.gmem_write(2, 0)
  reaper.gmem_write(3, 0)

  local guids_before_render = collect_track_guids()
  select_only_track(context.analysis_track)
  reaper.Main_OnCommand(context.render_command, 0)

  local rendered_tracks = find_new_tracks(guids_before_render)
  if #rendered_tracks == 0 then
    error("The SWS render did not create a temporary mono stem.")
  end
  for _, track in ipairs(rendered_tracks) do
    collect_track_media_paths(track)
    temporary_tracks[#temporary_tracks + 1] = track
  end

  local result_sequence = math.floor(reaper.gmem_read(0))
  local learned_angle = reaper.gmem_read(1)
  local recovered = reaper.gmem_read(2)
  local analysed = reaper.gmem_read(3)

  if result_sequence < 1 or
     analysed < math.min(0.1, context.selection_length * 0.5) then
    local capture_value = get_parameter_value(
      context.analysis_track, context.analysis_fx, capture_param)
    error(string.format(
      "The temporary render completed without enough analysis data " ..
      "(shared result %d; analysed %.3fs of %.3fs; capture %.0f; " ..
      "enabled %s; offline %s).",
      result_sequence,
      analysed,
      context.selection_length,
      capture_value,
      tostring(reaper.TrackFX_GetEnabled(
        context.analysis_track, context.analysis_fx)),
      tostring(reaper.TrackFX_GetOffline(
        context.analysis_track, context.analysis_fx))))
  end

  set_parameter_value(
    context.source_track, context.source_fx,
    context.learned_param, learned_angle)
  if context.headroom_param then
    set_parameter_value(
      context.source_track, context.source_fx,
      context.headroom_param, recovered)
  end

  return learned_angle, recovered, context.selection_length
end

save_selection()
reaper.Undo_BeginBlock2(PROJECT)
undo_open = true
reaper.PreventUIRefresh(1)
ui_refresh_locked = true

local finalized = false

local function finalize(ok, angle, recovered, duration)
  if finalized then
    return
  end
  finalized = true

  local cleanup_ok, cleanup_error = xpcall(cleanup, debug.traceback)
  if not cleanup_ok and ok then
    ok = false
    angle = cleanup_error
  end

  if ui_refresh_locked then
    reaper.PreventUIRefresh(-1)
    ui_refresh_locked = false
  end

  if undo_open then
    reaper.Undo_EndBlock2(
      PROJECT, "Learn adaptive phase rotation from time selection", -1)
    undo_open = false
  end

  if not ok then
    local clean_error = tostring(angle):gsub("\nstack traceback:.*", "")
    if silent_automation then
      set_automation_result("error", clean_error)
    else
      message(clean_error, "Adaptive Phase Rotator - Learning Failed")
    end
    return
  end

  if silent_automation then
    set_automation_result("ok", "", angle, recovered, duration)
  else
    message(
      string.format(
        "Learning complete.\n\nRange: %s\nLearned angle: %.2f degrees\n" ..
        "Predicted true-peak reduction: %.2f dB",
        format_duration(duration), angle, recovered),
      "Adaptive Phase Rotator")
  end
end

reaper.atexit(
  function()
    if not finalized then
      finalize(false, "Learning was interrupted before it completed.")
    end
  end)

local prepared, context = xpcall(prepare_learning, debug.traceback)
if not prepared then
  finalize(false, context)
else
  local function render_when_ready()
    if reaper.time_precise() < context.render_after then
      reaper.defer(render_when_ready)
      return
    end

    local ok, angle, recovered, duration =
      xpcall(
        function()
          return render_learning(context)
        end,
        debug.traceback)
    finalize(ok, angle, recovered, duration)
  end

  reaper.defer(render_when_ready)
end
