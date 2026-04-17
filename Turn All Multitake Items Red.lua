-- @description Turn All Multitake Items Red
-- @version 1.0
-- @author David Winter (based on earlier helper script)
-- Color all items (on selected tracks) that have more than one take
-- Sets item color to pure red
-- Author: David Winter (based on earlier helper script)

local function color_multi_take_items_on_selected_tracks()
    local proj = 0

    -- Define red color (RGB 255,0,0)
    local r, g, b = 255, 0, 0
    local red_color = reaper.ColorToNative(r, g, b) | 0x1000000

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    local sel_tr_count = reaper.CountSelectedTracks(proj)

    for t = 0, sel_tr_count - 1 do
        local track = reaper.GetSelectedTrack(proj, t)
        if track then
            local item_count = reaper.CountTrackMediaItems(track)
            for i = 0, item_count - 1 do
                local item = reaper.GetTrackMediaItem(track, i)
                if item then
                    local take_count = reaper.CountTakes(item)
                    if take_count and take_count > 1 then
                        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", red_color)
                    end
                end
            end
        end
    end

    reaper.UpdateArrange()
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Color items with multiple takes red (selected tracks only)", -1)
end

color_multi_take_items_on_selected_tracks()
