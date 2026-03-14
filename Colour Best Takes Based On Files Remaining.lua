--[[
Recolour regions based on rendered MP3 filenames in a ./Renders folder.

Tweaks:
  - Uses a medium/dark green (not bright green).
  - Reports the filenames of MP3s that matched the naming rule but did not find a region.

Expected filenames:
  Commercial-Line1.8.mp3
  Narration-Line12.3.mp3

Rules:
  - Narration-*  -> search regions numbered 1..269
  - Commercial-* -> search regions numbered 270..608
  - Extract the region name by taking everything after "Line" up to ".mp3"
      e.g. "Commercial-Line1.8.mp3" -> "1.8"
  - Find region(s) with that exact name in the relevant range and recolour them green.
--]]

local function path_sep()
  return package.config:sub(1, 1)
end

local function join_path(a, b)
  local sep = path_sep()
  if a:sub(-1) == sep then return a .. b end
  return a .. sep .. b
end

local function dir_exists(p)
  local ok, _, code = os.rename(p, p)
  if ok then return true end
  if code == 13 then return true end
  return false
end

local function get_project_dir()
  local _, rpp_path = reaper.EnumProjects(-1, "")
  if not rpp_path or rpp_path == "" then return nil end
  return rpp_path:match("^(.*)[/\\].-$")
end

local function enumerate_files(dir)
  local files = {}
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    files[#files + 1] = f
    i = i + 1
  end
  return files
end

local function build_region_maps()
  local narration = {}  -- name -> array of region records
  local commercial = {} -- name -> array of region records

  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = num_markers + num_regions

  for i = 0, total - 1 do
    local retval, isrgn, pos, rgnend, name, marknum, color = reaper.EnumProjectMarkers3(0, i)
    if retval and isrgn then
      local rec = { num = marknum, pos = pos, rgnend = rgnend, name = name }

      if marknum >= 1 and marknum <= 269 then
        narration[name] = narration[name] or {}
        table.insert(narration[name], rec)
      elseif marknum >= 270 and marknum <= 608 then
        commercial[name] = commercial[name] or {}
        table.insert(commercial[name], rec)
      end
    end
  end

  return narration, commercial
end

local function parse_render_filename(filename)
  -- Returns: kind ("Narration"|"Commercial"|nil), region_name (string|nil)
  -- Match: "<Kind>-Line<regionname>.mp3"
  local kind, region_part = filename:match("^(%a+)%-%s*Line(.+)%.mp3$")
  if not kind or not region_part then return nil, nil end
  if kind ~= "Narration" and kind ~= "Commercial" then return nil, nil end
  return kind, region_part
end

-- ---------------- main ----------------

local proj_dir = get_project_dir()
if not proj_dir then
  reaper.ShowMessageBox("Project must be saved so its folder can be determined.", "Recolour Regions from Renders", 0)
  return
end

local renders1 = join_path(proj_dir, "Renders")
local renders2 = join_path(join_path(proj_dir, ".."), "Renders")

local renders_dir = nil
if dir_exists(renders1) then
  renders_dir = renders1
elseif dir_exists(renders2) then
  renders_dir = renders2
end

if not renders_dir then
  reaper.ShowMessageBox(
    "Could not find a Renders folder at:\n\n" .. renders1 .. "\n\nor:\n\n" .. renders2,
    "Recolour Regions from Renders",
    0
  )
  return
end

local files = enumerate_files(renders_dir)
if #files == 0 then
  reaper.ShowMessageBox("No files found in:\n\n" .. renders_dir, "Recolour Regions from Renders", 0)
  return
end

local narration_map, commercial_map = build_region_maps()

-- Medium/dark green (RGB 0,128,0). Adjust if you want darker/lighter.
local green = reaper.ColorToNative(0, 128, 0) | 0x1000000

local processed = 0
local recoloured = 0
local not_found = 0
local skipped = 0
local not_found_files = {}

reaper.Undo_BeginBlock()

for _, f in ipairs(files) do
  if f:lower():match("%.mp3$") then
    local kind, region_name = parse_render_filename(f)
    if kind and region_name then
      processed = processed + 1
      local map = (kind == "Narration") and narration_map or commercial_map
      local matches = map[region_name]

      if matches and #matches > 0 then
        for _, r in ipairs(matches) do
          reaper.SetProjectMarker3(0, r.num, true, r.pos, r.rgnend, r.name, green)
          recoloured = recoloured + 1
        end
      else
        not_found = not_found + 1
        not_found_files[#not_found_files + 1] = f
      end
    else
      skipped = skipped + 1
    end
  else
    skipped = skipped + 1
  end
end

reaper.Undo_EndBlock("Recolour regions from rendered MP3 filenames", -1)
reaper.UpdateArrange()

local report = ""
if #not_found_files > 0 then
  report = "\n\nUnmatched MP3s (naming matched, region not found):\n" .. table.concat(not_found_files, "\n")
end

reaper.ShowMessageBox(
  "Renders folder:\n" .. renders_dir ..
  "\n\nMP3s processed (matched naming rule): " .. processed ..
  "\nRegions recoloured: " .. recoloured ..
  "\nMP3s with no matching region: " .. not_found ..
  "\nFiles skipped (non-matching name / non-mp3): " .. skipped ..
  report,
  "Recolour Regions from Renders",
  0
)
