-- @description Export Command IDs
-- @version 1.0
-- @author David Winter
-- Export all Reaper actions in the Main section to a CSV file

local sep = ","
local output = "Command ID,Action Name,Shortcut(s)\n"
local section = 0 -- 0 = Main section
local action_count = reaper.CountActions(section)

for i = 0, action_count - 1 do
  local cmd_id = reaper.GetActionID(section, i)
  local name = reaper.CF_GetCommandText(section, cmd_id) or "(Unnamed Action)"

  local shortcut = ""
  local shortcut_count = reaper.CountActionShortcuts(section, cmd_id)

  if shortcut_count > 0 then
    for j = 0, shortcut_count - 1 do
      local ok, desc = reaper.GetActionShortcutDesc(section, cmd_id, j)
      if ok and desc then
        shortcut = shortcut .. (shortcut ~= "" and " | " or "") .. desc
      end
    end
  end

  -- Clean commas
  name = name:gsub(",", " ")
  shortcut = shortcut:gsub(",", " ")

  output = output .. tostring(cmd_id) .. sep .. name .. sep .. shortcut .. "\n"
end

-- Save to file
local out_path = reaper.GetResourcePath() .. "/All_Actions_With_Shortcuts.csv"
local out = io.open(out_path, "w")
out:write(output)
out:close()

reaper.ShowMessageBox("Export complete!\nSaved to:\n" .. out_path, "Done", 0)
