-- @description Regions from Additional Cast Items
-- @version 1.0
-- @author David Winter
 -- Create parent-named blue regions for child tracks whose grandparent is "Additional Cast"
 -- Merges adjacent/overlapping items on the same track into a single region.
 
 local GRANDPARENT_NAME = "Additional Cast"
 
 local function trim(s)
   return (s:gsub("^%s+", ""):gsub("%s+$", ""))
 end
 
 local function get_track_name(tr)
   local ok, name = reaper.GetTrackName(tr)
   if not ok then return "" end
   return trim(name or "")
 end
 
 local function merge_intervals(intervals)
   if #intervals == 0 then return {} end
   table.sort(intervals, function(a, b)
     if a.s == b.s then return a.e < b.e end
     return a.s < b.s
   end)
 
   local merged = {}
   local eps = 1e-9
 
   local cur_s = intervals[1].s
   local cur_e = intervals[1].e
 
   for i = 2, #intervals do
     local s = intervals[i].s
     local e = intervals[i].e
     if s <= cur_e + eps then
       if e > cur_e then cur_e = e end
     else
       merged[#merged+1] = { s = cur_s, e = cur_e }
       cur_s, cur_e = s, e
     end
   end
 
   merged[#merged+1] = { s = cur_s, e = cur_e }
   return merged
 end
 
 reaper.Undo_BeginBlock()
 
 local proj = 0
 local blue = reaper.ColorToNative(0, 0, 255) | 0x1000000
 
 local track_count = reaper.CountTracks(proj)
 for i = 0, track_count - 1 do
   local tr = reaper.GetTrack(proj, i)
   if tr then
     local parent = reaper.GetParentTrack(tr)
     if parent then
       local grandparent = reaper.GetParentTrack(parent)
       if grandparent then
         local gp_name = get_track_name(grandparent)
         if gp_name == GRANDPARENT_NAME then
           local region_name = get_track_name(parent)
 
           local item_count = reaper.CountTrackMediaItems(tr)
           if item_count > 0 then
             local intervals = {}
 
             for j = 0, item_count - 1 do
               local item = reaper.GetTrackMediaItem(tr, j)
               if item then
                 local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                 local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                 local s = pos
                 local e = pos + len
                 if len > 0 then
                   intervals[#intervals+1] = { s = s, e = e }
                 end
               end
             end
 
             local merged = merge_intervals(intervals)
             for k = 1, #merged do
               reaper.AddProjectMarker2(proj, true, merged[k].s, merged[k].e, region_name, -1, blue)
             end
           end
         end
       end
     end
   end
 end
 
 reaper.UpdateArrange()
 reaper.Undo_EndBlock("Create blue parent-named regions for Additional Cast grandchildren (merged items)", -1)
