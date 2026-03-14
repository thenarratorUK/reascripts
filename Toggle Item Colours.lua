-- @description Toggle Custom Colors for Selected Items (None, Orange, Green)
-- @version 1.0
-- @author David Winter
-- @changelog Initial release

reaper.Undo_BeginBlock()  -- Start undo block

-- Define colors using ColorToNative function
  local orange = reaper.ColorToNative(255, 165, 0) | 0x1000000  -- Orange
  local green = reaper.ColorToNative(0, 255, 0) | 0x1000000     -- Green
  local yellow = reaper.ColorToNative(255, 255, 0) | 0x1000000   -- Yellow
  local blue   = reaper.ColorToNative(0, 0, 255)   | 0x1000000   -- Blue

local num_items = reaper.CountSelectedMediaItems(0)

if num_items == 0 then
    reaper.ShowMessageBox("No items selected!", "Error", 0)
    reaper.Undo_EndBlock("Toggle Custom Colors for Selected Items", -1)
    return
end

for i = 0, num_items - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local current_color = reaper.GetMediaItemInfo_Value(item, "I_CUSTOMCOLOR")

    if current_color == 0 then
        -- If no custom color, set to blue
        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", blue)
    elseif current_color == blue then
        -- If blue, set to yellow
        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", yellow)
    elseif current_color == yellow then
        -- If yellow, set to orange
        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", orange)
    elseif current_color == orange then
        -- If orange, set to green
        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", green)
    elseif current_color == green then
        -- If green, remove custom color
        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", 0)
    else
        -- If another color, treat it as no custom color and set to orange
        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", blue)
    end
end

reaper.UpdateArrange()  -- Refresh the UI
reaper.Undo_EndBlock("Toggle Custom Colors for Selected Items", -1)
