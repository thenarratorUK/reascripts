-- @description Detect Long Pauses Across Selected Tracks
-- @version 1.1
-- @author David Winter
-- @about
--   Select one or more tracks, then run this script.
--
--   The script creates one track AudioAccessor per selected track and treats
--   the tracks as a single combined programme: a frame is silent only when
--   every channel on every selected track is at or below -60 dBFS. It reports
--   every continuous pause lasting more than 1.2 seconds by adding a project
--   marker named "Long Pause?" at the start of the pause.
--
--   If there is a time selection, only that range is analysed. Otherwise the
--   range runs from the earliest item start to the latest item end on the
--   selected tracks. Existing "Long Pause?" markers at the same positions are
--   reused, so running the script again does not create duplicates.
--
--   Track AudioAccessors read the signal immediately before track FX. Item
--   fades, take FX, take/item gain, and overlapping items are represented in
--   the sampled signal, but track FX are not.

local PROJECT = 0
local SILENCE_THRESHOLD_DB = -60.0
local MINIMUM_PAUSE_SECONDS = 1.2
local BLOCK_FRAMES = 32768
local FALLBACK_SAMPLE_RATE = 48000
local MARKER_NAME = "Long Pause?"

local SILENCE_THRESHOLD_AMP = 10 ^ (SILENCE_THRESHOLD_DB / 20.0)

local function show_error(message)
  reaper.ShowMessageBox(message, "Detect Long Pauses", 0)
end

local function get_track_name(track, fallback_index)
  local _, name = reaper.GetTrackName(track)
  if name and name ~= "" then return name end
  return "Track " .. tostring(fallback_index)
end

local function get_selected_tracks()
  local tracks = {}
  for i = 0, reaper.CountSelectedTracks(PROJECT) - 1 do
    local track = reaper.GetSelectedTrack(PROJECT, i)
    tracks[#tracks + 1] = {
      track = track,
      name = get_track_name(track, math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or (i + 1))),
      channels = math.max(1, math.floor(reaper.GetMediaTrackInfo_Value(track, "I_NCHAN") or 2)),
    }
  end
  return tracks
end

local function get_analysis_sample_rate()
  local sample_rate = reaper.GetSetProjectInfo(PROJECT, "PROJECT_SRATE", 0, false)
  if sample_rate and sample_rate > 0 then
    return math.floor(sample_rate + 0.5)
  end

  local ok, device_rate = reaper.GetAudioDeviceInfo("SRATE")
  if ok then
    sample_rate = tonumber(device_rate)
    if sample_rate and sample_rate > 0 then
      return math.floor(sample_rate + 0.5)
    end
  end

  return FALLBACK_SAMPLE_RATE
end

local function get_item_span(tracks)
  local range_start = nil
  local range_end = nil

  for _, context in ipairs(tracks) do
    local item_count = reaper.CountTrackMediaItems(context.track)
    for i = 0, item_count - 1 do
      local item = reaper.GetTrackMediaItem(context.track, i)
      local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local item_end = item_start + item_length

      if item_length > 0 then
        if not range_start or item_start < range_start then range_start = item_start end
        if not range_end or item_end > range_end then range_end = item_end end
      end
    end
  end

  return range_start, range_end
end

local function get_analysis_range(tracks)
  local selection_start, selection_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if selection_end > selection_start then
    return selection_start, selection_end, "time selection"
  end

  local item_start, item_end = get_item_span(tracks)
  if item_start and item_end and item_end > item_start then
    return item_start, item_end, "selected-track item span"
  end

  return nil, nil, nil
end

local function create_accessors(tracks)
  for _, context in ipairs(tracks) do
    context.accessor = reaper.CreateTrackAudioAccessor(context.track)
    if not context.accessor then
      return false, "Could not create an AudioAccessor for " .. context.name .. "."
    end
    context.buffer = reaper.new_array(BLOCK_FRAMES * context.channels)
  end
  return true
end

local function destroy_accessors(tracks)
  for _, context in ipairs(tracks) do
    if context.accessor then
      reaper.DestroyAudioAccessor(context.accessor)
      context.accessor = nil
    end
  end
end

local function detect_pauses(tracks, range_start, range_end, sample_rate)
  local pauses = {}
  local total_frames = math.max(0, math.ceil((range_end - range_start) * sample_rate - 1e-9))
  local processed_frames = 0
  local silent_run_start_frame = nil

  local function finish_silent_run(end_frame)
    if silent_run_start_frame == nil then return end

    local silent_frames = end_frame - silent_run_start_frame
    if silent_frames > (MINIMUM_PAUSE_SECONDS * sample_rate) then
      pauses[#pauses + 1] = {
        start_time = range_start + (silent_run_start_frame / sample_rate),
        end_time = range_start + (end_frame / sample_rate),
        duration = silent_frames / sample_rate,
      }
    end

    silent_run_start_frame = nil
  end

  while processed_frames < total_frames do
    local frames = math.min(BLOCK_FRAMES, total_frames - processed_frames)
    local block_start = range_start + (processed_frames / sample_rate)
    local loud_frames = {}

    for _, context in ipairs(tracks) do
      context.buffer.clear()
      local status = reaper.GetAudioAccessorSamples(
        context.accessor,
        sample_rate,
        context.channels,
        block_start,
        frames,
        context.buffer
      )

      if status == -1 then
        error("GetAudioAccessorSamples failed for " .. context.name .. ".")
      end

      -- status == 0 means that this track contributes silence to the block.
      if status == 1 then
        local samples = context.buffer.table()
        for frame = 0, frames - 1 do
          local frame_index = frame + 1
          if not loud_frames[frame_index] then
            local sample_base = frame * context.channels
            for channel = 1, context.channels do
              local amplitude = math.abs(samples[sample_base + channel] or 0)
              if amplitude > SILENCE_THRESHOLD_AMP then
                loud_frames[frame_index] = true
                break
              end
            end
          end
        end
      end
    end

    for frame = 0, frames - 1 do
      local absolute_frame = processed_frames + frame
      if loud_frames[frame + 1] then
        finish_silent_run(absolute_frame)
      elseif silent_run_start_frame == nil then
        silent_run_start_frame = absolute_frame
      end
    end

    processed_frames = processed_frames + frames
  end

  finish_silent_run(total_frames)
  return pauses
end

local function get_existing_pause_markers()
  local positions = {}
  local marker_count = select(1, reaper.CountProjectMarkers(PROJECT))

  for i = 0, marker_count - 1 do
    local found, is_region, position, _, name = reaper.EnumProjectMarkers(i)
    if found and not is_region and (name or "") == MARKER_NAME then
      positions[#positions + 1] = position
    end
  end

  return positions
end

local function has_marker_at(positions, target, tolerance)
  for _, position in ipairs(positions) do
    if math.abs(position - target) <= tolerance then return true end
  end
  return false
end

local function add_pause_markers(pauses, sample_rate)
  local existing_positions = get_existing_pause_markers()
  local tolerance = (1 / sample_rate) + 1e-9
  local added = 0
  local already_present = 0

  for _, pause in ipairs(pauses) do
    if has_marker_at(existing_positions, pause.start_time, tolerance) then
      already_present = already_present + 1
    else
      if added == 0 then reaper.Undo_BeginBlock() end
      reaper.AddProjectMarker2(PROJECT, false, pause.start_time, 0, MARKER_NAME, -1, 0)
      existing_positions[#existing_positions + 1] = pause.start_time
      added = added + 1
    end
  end

  if added > 0 then
    reaper.Undo_EndBlock("Add Long Pause? markers", -1)
    reaper.UpdateArrange()
  end

  return added, already_present
end

local function main()
  local tracks = get_selected_tracks()
  if #tracks == 0 then
    show_error("Select one or more tracks, then run Detect Long Pauses again.")
    return
  end

  local range_start, range_end = get_analysis_range(tracks)
  if not range_start then
    show_error("The selected tracks contain no positive-length media items, and there is no time selection to analyse.")
    return
  end

  local sample_rate = get_analysis_sample_rate()
  local accessors_ok, accessor_error = create_accessors(tracks)
  if not accessors_ok then
    destroy_accessors(tracks)
    show_error(accessor_error)
    return
  end

  local ok, result = xpcall(function()
    return detect_pauses(tracks, range_start, range_end, sample_rate)
  end, debug.traceback)

  destroy_accessors(tracks)

  if not ok then
    show_error("Analysis failed:\n\n" .. tostring(result))
    return
  end

  local added, already_present = add_pause_markers(result, sample_rate)
  local message
  if #result == 0 then
    message = "No pauses longer than 1.2 seconds were found."
  else
    message = string.format("Added %d %s marker%s.", added, MARKER_NAME, added == 1 and "" or "s")
    if already_present > 0 then
      message = message .. string.format("\n%d matching marker%s already existed.", already_present, already_present == 1 and "" or "s")
    end
  end
  reaper.ShowMessageBox(message, "Detect Long Pauses", 0)
end

main()
