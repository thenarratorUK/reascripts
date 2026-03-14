-- @description Split AllFX and Dialogue Bus into one-plugin-per-track chains
-- @version 1.1
-- @author David Winter
-- @about
--   AllFX / All FX:
--     - Uses the named source track as the canonical editable chain
--     - Creates/extends managed child tracks: AllFX1, AllFX2... or All FX 1, All FX 2...
--     - Copies any ONLINE source FX slots to the corresponding managed tracks, then sets those source FX offline
--     - Re-routes any sends targeting the source track so they target the first managed child
--
--   Dialogue Bus:
--     - Uses "Dialogue Bus" as the canonical editable chain
--     - Creates/extends managed tracks immediately after it:
--         Dialogue Bus 1, Dialogue Bus 2, ... Dialogue Bus Final
--     - Copies any ONLINE source FX slots to the corresponding managed tracks, then sets those source FX offline
--     - Routes Dialogue Bus -> Dialogue Bus 1 -> ... -> Dialogue Bus Final
--     - Re-routes non-chain sends from Dialogue Bus to the actual final stage
--
--   General behaviour:
--     - Source chain length is counted including offline FX
--     - If a source FX slot is offline, the corresponding managed track is left untouched
--     - If a source FX slot is online, the corresponding managed track is overwritten from source
--     - If there are more managed tracks than source FX slots, FX on the extras are cleared, but routing is left alone
--     - Aborts if any FX parameter automation is found on the source or managed tracks involved

local r = reaper

------------------------------------------------------------
-- Utilities
------------------------------------------------------------

local function show_message(text)
  r.ShowMessageBox(text, "Split FX Chain", 0)
end

local function fail(text)
  error(text, 0)
end

local function get_track_name(track)
  local _, name = r.GetTrackName(track, "")
  return name or ""
end

local function set_track_name(track, name)
  r.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
end

local function count_tracks()
  return r.CountTracks(0)
end

local function get_track(i)
  return r.GetTrack(0, i)
end

local function get_track_index(track)
  local n = count_tracks()
  for i = 0, n - 1 do
    if get_track(i) == track then
      return i
    end
  end
  return -1
end

local function lower(s)
  return (s or ""):lower()
end

local function copy_track_channel_count(src, dest)
  local nch = r.GetMediaTrackInfo_Value(src, "I_NCHAN")
  if nch < 2 then nch = 2 end
  r.SetMediaTrackInfo_Value(dest, "I_NCHAN", nch)
end

local function clear_track_fx(track)
  for fx = r.TrackFX_GetCount(track) - 1, 0, -1 do
    r.TrackFX_Delete(track, fx)
  end
end

local function fx_name(track, fx)
  local _, name = r.TrackFX_GetFXName(track, fx, "")
  return name or ("FX " .. tostring(fx + 1))
end

------------------------------------------------------------
-- Track finding
------------------------------------------------------------

local function find_unique_track_by_names(names)
  local matches = {}
  local n = count_tracks()

  for i = 0, n - 1 do
    local track = get_track(i)
    local trackname = lower(get_track_name(track))

    for _, wanted in ipairs(names) do
      if trackname == lower(wanted) then
        matches[#matches + 1] = track
        break
      end
    end
  end

  if #matches == 0 then
    return nil, "No track found named: " .. table.concat(names, " / ")
  end

  if #matches > 1 then
    return nil, "Multiple matching tracks found for: " .. table.concat(names, " / ")
  end

  return matches[1], nil
end

------------------------------------------------------------
-- FX automation detection
------------------------------------------------------------

local function has_fx_automation_on_track(track)
  local fxcount = r.TrackFX_GetCount(track)
  local tname = get_track_name(track)

  for fx = 0, fxcount - 1 do
    local pcount = r.TrackFX_GetNumParams(track, fx)
    for p = 0, pcount - 1 do
      local env = r.GetFXEnvelope(track, fx, p, false)
      if env ~= nil then
        return true, tname, fx_name(track, fx)
      end
    end
  end

  return false, nil, nil
end

local function assert_no_fx_automation(tracks)
  for _, track in ipairs(tracks) do
    local has, tname, fname = has_fx_automation_on_track(track)
    if has then
      fail('Aborted: FX automation detected on track "' .. tname .. '" for plug-in "' .. fname .. '".')
    end
  end
end

------------------------------------------------------------
-- Send helpers
------------------------------------------------------------

local SEND_PARMS = {
  "B_MUTE",
  "B_PHASE",
  "B_MONO",
  "D_VOL",
  "D_PAN",
  "D_PANLAW",
  "I_SENDMODE",
  "I_AUTOMODE",
  "I_SRCCHAN",
  "I_DSTCHAN",
  "I_MIDIFLAGS"
}

local function get_send_dest(src_track, sendidx)
  return r.GetTrackSendInfo_Value(src_track, 0, sendidx, "P_DESTTRACK")
end

local function capture_send(src_track, sendidx)
  local data = {}
  for _, parm in ipairs(SEND_PARMS) do
    data[parm] = r.GetTrackSendInfo_Value(src_track, 0, sendidx, parm)
  end
  return data
end

local function apply_send(src_track, sendidx, data)
  for _, parm in ipairs(SEND_PARMS) do
    if data[parm] ~= nil then
      r.SetTrackSendInfo_Value(src_track, 0, sendidx, parm, data[parm])
    end
  end
end

local function clone_send_to_dest(src_track, sendidx, new_dest_track)
  local data = capture_send(src_track, sendidx)
  local newidx = r.CreateTrackSend(src_track, new_dest_track)
  if newidx >= 0 then
    apply_send(src_track, newidx, data)
  end
  return newidx
end

local function reroute_matching_sends(src_track, matcher_fn, new_dest_track)
  for sendidx = r.GetTrackNumSends(src_track, 0) - 1, 0, -1 do
    local dest = get_send_dest(src_track, sendidx)
    if dest ~= nil and dest ~= new_dest_track and matcher_fn(dest, sendidx) then
      clone_send_to_dest(src_track, sendidx, new_dest_track)
      r.RemoveTrackSend(src_track, 0, sendidx)
    end
  end
end

local function find_send_index(src_track, dest_track)
  for sendidx = 0, r.GetTrackNumSends(src_track, 0) - 1 do
    if get_send_dest(src_track, sendidx) == dest_track then
      return sendidx
    end
  end
  return -1
end

local function ensure_chain_send(src_track, dest_track)
  local sendidx = find_send_index(src_track, dest_track)
  if sendidx < 0 then
    sendidx = r.CreateTrackSend(src_track, dest_track)
  end

  if sendidx >= 0 then
    r.SetTrackSendInfo_Value(src_track, 0, sendidx, "B_MUTE", 0)
    r.SetTrackSendInfo_Value(src_track, 0, sendidx, "B_PHASE", 0)
    r.SetTrackSendInfo_Value(src_track, 0, sendidx, "B_MONO", 0)
    r.SetTrackSendInfo_Value(src_track, 0, sendidx, "D_VOL", 1.0)
    r.SetTrackSendInfo_Value(src_track, 0, sendidx, "D_PAN", 0.0)
    r.SetTrackSendInfo_Value(src_track, 0, sendidx, "I_SENDMODE", 3) -- post-fader (post-FX)
    r.SetTrackSendInfo_Value(src_track, 0, sendidx, "I_SRCCHAN", 0)  -- 1/2 stereo
    r.SetTrackSendInfo_Value(src_track, 0, sendidx, "I_DSTCHAN", 0)  -- 1/2 stereo
  end

  return sendidx
end

------------------------------------------------------------
-- AllFX helpers
------------------------------------------------------------

local function allfx_style_from_name(actual_name)
  if lower(actual_name) == "all fx" then
    return {
      child_name = function(i) return "All FX " .. tostring(i) end
    }
  end

  return {
    child_name = function(i) return "AllFX" .. tostring(i) end
  }
end

local function collect_allfx_managed_children(parent, style)
  local children = {}
  local parent_idx = get_track_index(parent)
  local parent_depth = r.GetTrackDepth(parent)
  local expected = 1
  local n = count_tracks()
  local i = parent_idx + 1

  while i < n do
    local track = get_track(i)
    if r.GetTrackDepth(track) <= parent_depth then
      break
    end

    if get_track_name(track) ~= style.child_name(expected) then
      break
    end

    children[#children + 1] = track
    expected = expected + 1
    i = i + 1
  end

  return children
end

local function extend_allfx_children(parent, style, children, needed_count)
  local existing = #children
  if existing >= needed_count then
    return children
  end

  local parent_idx = get_track_index(parent)
  local parent_depth = r.GetTrackDepth(parent)
  local insert_idx = parent_idx + 1 + existing
  local total_before = count_tracks()
  local folder_continues = false

  if insert_idx < total_before then
    local next_track = get_track(insert_idx)
    if next_track and r.GetTrackDepth(next_track) > parent_depth then
      folder_continues = true
    end
  end

  local parent_folderdepth = r.GetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH")
  if parent_folderdepth < 1 then
    r.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", 1)
  end

  if existing > 0 and not folder_continues then
    local old_last = children[existing]
    local d = r.GetMediaTrackInfo_Value(old_last, "I_FOLDERDEPTH")
    if d < 0 then
      r.SetMediaTrackInfo_Value(old_last, "I_FOLDERDEPTH", d + 1)
    end
  end

  for i = existing + 1, needed_count do
    r.InsertTrackAtIndex(insert_idx, false)
    local track = get_track(insert_idx)
    set_track_name(track, style.child_name(i))
    copy_track_channel_count(parent, track)
    r.SetMediaTrackInfo_Value(track, "B_MAINSEND", 0)
    r.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", 0)
    children[#children + 1] = track
    insert_idx = insert_idx + 1
  end

  if not folder_continues then
    local last = children[#children]
    local d = r.GetMediaTrackInfo_Value(last, "I_FOLDERDEPTH")
    if d >= 0 then
      r.SetMediaTrackInfo_Value(last, "I_FOLDERDEPTH", d - 1)
    end
  end

  if existing == 0 then
    for i = 1, #children - 1 do
      r.SetMediaTrackInfo_Value(children[i], "B_MAINSEND", 0)
      ensure_chain_send(children[i], children[i + 1])
    end
    r.SetMediaTrackInfo_Value(children[#children], "B_MAINSEND", 1)
  else
    local old_last = children[existing]
    r.SetMediaTrackInfo_Value(old_last, "B_MAINSEND", 0)
    ensure_chain_send(old_last, children[existing + 1])

    for i = existing + 1, #children - 1 do
      r.SetMediaTrackInfo_Value(children[i], "B_MAINSEND", 0)
      ensure_chain_send(children[i], children[i + 1])
    end

    r.SetMediaTrackInfo_Value(children[#children], "B_MAINSEND", 1)
  end

  return children
end

------------------------------------------------------------
-- Dialogue Bus helpers
------------------------------------------------------------

local function dialogue_name_for_position(pos, total)
  if pos == total then
    return "Dialogue Bus Final"
  end
  return "Dialogue Bus " .. tostring(pos)
end

local function collect_dialogue_managed_tracks(dialogue_bus)
  local tracks = {}
  local src_idx = get_track_index(dialogue_bus)
  local n = count_tracks()
  local expected_num = 1
  local i = src_idx + 1

  while i < n do
    local track = get_track(i)
    local name = get_track_name(track)

    if name == ("Dialogue Bus " .. tostring(expected_num)) then
      tracks[#tracks + 1] = track
      expected_num = expected_num + 1
      i = i + 1
    elseif name == "Dialogue Bus Final" then
      tracks[#tracks + 1] = track
      break
    else
      break
    end
  end

  return tracks
end

local function extend_dialogue_tracks(dialogue_bus, managed, needed_count)
  local existing = #managed
  if existing >= needed_count then
    return managed
  end

  -- Rename the existing final if it is no longer final
  for i = 1, existing do
    set_track_name(managed[i], dialogue_name_for_position(i, needed_count))
  end

  local insert_idx = get_track_index(dialogue_bus) + 1 + existing

  for i = existing + 1, needed_count do
    r.InsertTrackAtIndex(insert_idx, false)
    local track = get_track(insert_idx)
    set_track_name(track, dialogue_name_for_position(i, needed_count))
    copy_track_channel_count(dialogue_bus, track)
    r.SetMediaTrackInfo_Value(track, "B_MAINSEND", 0)
    managed[#managed + 1] = track
    insert_idx = insert_idx + 1
  end

  return managed
end

------------------------------------------------------------
-- Part 1: AllFX / All FX
------------------------------------------------------------

local function process_allfx()
  local source, err = find_unique_track_by_names({ "AllFX", "All FX" })
  if not source then
    fail(err)
  end

  local style = allfx_style_from_name(get_track_name(source))
  local managed = collect_allfx_managed_children(source, style)

  local check_tracks = { source }
  for _, tr in ipairs(managed) do
    check_tracks[#check_tracks + 1] = tr
  end
  assert_no_fx_automation(check_tracks)

  local fxcount = r.TrackFX_GetCount(source)
  if fxcount <= 1 then
    return "AllFX: 0 or 1 source FX, no changes."
  end

  if #managed < fxcount then
    managed = extend_allfx_children(source, style, managed, fxcount)
  end

  local first_child = managed[1]

  -- Re-route any sends that target the source AllFX track to the first managed child
  local n = count_tracks()
  for i = 0, n - 1 do
    local track = get_track(i)
    reroute_matching_sends(track, function(dest)
      return dest == source
    end, first_child)
  end

  -- Refresh managed tracks from ONLINE source slots only
  for slot = 1, fxcount do
    local src_fx = slot - 1
    local dest_track = managed[slot]

    if not r.TrackFX_GetOffline(source, src_fx) then
      clear_track_fx(dest_track)
      r.TrackFX_CopyToTrack(source, src_fx, dest_track, -1, false)
      r.TrackFX_SetOffline(source, src_fx, true)
    end
  end

  -- Clear FX on any extra managed tracks, but leave routing alone
  for i = fxcount + 1, #managed do
    clear_track_fx(managed[i])
  end

  return "AllFX processed."
end

------------------------------------------------------------
-- Part 2: Dialogue Bus
------------------------------------------------------------

local function process_dialogue_bus()
  local source, err = find_unique_track_by_names({ "Dialogue Bus" })
  if not source then
    fail(err)
  end

  local managed = collect_dialogue_managed_tracks(source)

  local check_tracks = { source }
  for _, tr in ipairs(managed) do
    check_tracks[#check_tracks + 1] = tr
  end
  assert_no_fx_automation(check_tracks)

  local fxcount = r.TrackFX_GetCount(source)
  if fxcount <= 1 then
    return "Dialogue Bus: 0 or 1 source FX, no changes."
  end

  local existing_count = #managed
  local old_final = nil
  if existing_count > 0 then
    old_final = managed[existing_count]
  end

  if existing_count < fxcount then
    managed = extend_dialogue_tracks(source, managed, fxcount)
  end

  local actual_final = managed[#managed]

  -- If the chain was extended, move external sends from the old final to the new final
  if old_final ~= nil and old_final ~= actual_final then
    local next_chain_dest = managed[existing_count + 1]
    reroute_matching_sends(old_final, function(dest)
      return dest ~= next_chain_dest
    end, actual_final)
  end

  -- Ensure the chain routing exists
  r.SetMediaTrackInfo_Value(source, "B_MAINSEND", 0)
  ensure_chain_send(source, managed[1])

  for i = 1, #managed - 1 do
    r.SetMediaTrackInfo_Value(managed[i], "B_MAINSEND", 0)
    ensure_chain_send(managed[i], managed[i + 1])
  end

  r.SetMediaTrackInfo_Value(managed[#managed], "B_MAINSEND", 1)

  -- Move any non-chain sends from Dialogue Bus itself to the actual final stage
  reroute_matching_sends(source, function(dest)
    return dest ~= managed[1]
  end, actual_final)

  -- Refresh managed tracks from ONLINE source slots only
  for slot = 1, fxcount do
    local src_fx = slot - 1
    local dest_track = managed[slot]

    if not r.TrackFX_GetOffline(source, src_fx) then
      clear_track_fx(dest_track)
      r.TrackFX_CopyToTrack(source, src_fx, dest_track, -1, false)
      r.TrackFX_SetOffline(source, src_fx, true)
    end
  end

  -- Clear FX on any extra managed tracks, but leave routing alone
  for i = fxcount + 1, #managed do
    clear_track_fx(managed[i])
  end

  return "Dialogue Bus processed."
end

------------------------------------------------------------
-- Main
------------------------------------------------------------

local function main()
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local ok, err = pcall(function()
    local res1 = process_allfx()
    local res2 = process_dialogue_bus()

    r.TrackList_AdjustWindows(false)
    r.UpdateArrange()
    show_message(res1 .. "\n" .. res2)
  end)

  r.PreventUIRefresh(-1)

  if ok then
    r.Undo_EndBlock("Split AllFX and Dialogue Bus into one-plugin-per-track chains", -1)
  else
    r.Undo_EndBlock("Split AllFX and Dialogue Bus into one-plugin-per-track chains", -1)
    show_message(err)
  end
end

main()
