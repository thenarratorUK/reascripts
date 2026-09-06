-- @description Ripple Punch-In
-- @version 1.1
-- @author David Winter
-- Smart Ripple Insert Toggle
-- Replaces a cycle action for starting/stopping ripple inserts
-- Author: David Winter

local function resolve_reascript(filename)
  local sep = package.config:sub(1, 1)
  local resource_path = reaper.GetResourcePath()
  local _, caller_path = reaper.get_action_context()
  local caller_dir = caller_path and caller_path:match("^(.*[\\/])") or ""
  local candidates = {}

  if caller_dir ~= "" then candidates[#candidates + 1] = caller_dir .. filename end
  candidates[#candidates + 1] = resource_path .. sep .. "Scripts" .. sep .. filename
  candidates[#candidates + 1] = resource_path .. sep .. "Scripts" .. sep ..
    "thenarratorUK ReaScripts" .. sep .. "Scripts" .. sep .. filename
  candidates[#candidates + 1] = resource_path .. sep .. "Scripts" .. sep ..
    "thenarratorUK ReaScripts" .. sep .. filename

  local seen = {}
  for _, path in ipairs(candidates) do
    if path and not seen[path] then
      seen[path] = true
      if reaper.file_exists(path) then
        local command_id = reaper.AddRemoveReaScript(true, 0, path, true)
        if command_id ~= 0 then return command_id end
      end
    end
  end

  return 0
end

local function run_reascript(filename)
  local command_id = resolve_reascript(filename)
  if command_id == 0 then
    reaper.MB("Could not locate or register companion script:\n\n" .. filename,
      "Ripple Punch-In", 0)
    return false
  end
  reaper.Main_OnCommand(command_id, 0)
  return true
end

local playState = reaper.GetPlayState()

if playState > 0 then
  -- Transport is playing or recording → End Ripple Insert
  run_reascript("Ripple Insert End.lua")
else
  -- Transport is stopped or paused → Start Ripple Insert
  run_reascript("Ripple Insert Start.lua")
end
