--[[
DW – Shortcut Menu (Two Columns, Sectioned)

Two-column GUI with section titles and buttons that trigger other actions/scripts.

Column layout:
  - Column 1: PROJECT SETUP, POSTPRODUCTION UTILITIES
  - Column 2: PICKUP UTILITIES, MULTICAST/TAKE UTILITIES, SPECIAL UTILITIES

Edit CLOSE_AFTER_CLICK if you want the window to close after clicking a button.
]]--

-----------------------------------------
-- USER CONFIG
-----------------------------------------

local CLOSE_AFTER_CLICK = false

-- Window / layout constants
local WIN_W            = 820
local HEADER_H         = 28
local SECTION_TITLE_H  = 22
local BTN_H            = 26
local BTN_MARGIN       = 10
local DIVIDER_H        = 10
local COL_GAP          = 14

-----------------------------------------
-- COMMANDS (Numbered Mapping 1–31)
-----------------------------------------

local cmd = {
  [1]  = { label = "Build and Update from Sources",                   id = "_RS6c83380bf908d77d0d351592df3d53349f9b7b34" },
  [2]  = { label = "Build Character FX and Sends",                    id = "_RSc344cde3f52297f51ee9fe2a2ca4ba95db05d512" },
  [3]  = { label = "Move from Parent to Child based on tag",          id = "_RS13225a4f6318ac93e9815aa1804cc9d0887a71f5" },
  [4]  = { label = "Check for Duplicate Empty Items",                 id = "_RS15e6c446ab6b1d5f98f4515f10f235583c480504" },
  [5]  = { label = "Validate Items are on Correct Tracks",            id = "_RS1a38f250486897ee41d143f11ad71c7a3c57024b" },
  [6]  = { label = "Check for Empty Tracks in 15 Min Checkpoint",     id = "_RS56d56acea7b817eee4a512000a3fc2b0b2050364" },
  [7]  = { label = "Copy Track Items to End for FX Learning",         id = "_RSb007e248312e31dc3c4670c751253c605fc644a9" },
  [8]  = { label = "Copy Automation from First Item(s) to All Items", id = "_RS694b14720aff383b3efa2aab05f97f31cfc88b63" },
  [9]  = { label = "Turn All MultiTake Items Red",                    id = "_RS50c552b20e5acc42f991b1e35ef5d3572a6621af" },
  [10] = { label = "Find Next Item with Multiple Takes",              id = "_RS90dd430705d1ea60abe968344a5ac33f25d6ded0" },
  [11] = { label = "Check Gaps Between Items",                        id = "_RS1596b8dcc05875d10519f809e4fb2f9d2bb47a7d" },
  [12] = { label = "List TakeFX On Track",                            id = "_RSd0158d8a172b9ab9e5e0d05323cd74dbdfc8341b" },
  [13] = { label = "Close Gaps in Room Tone",                         id = "_RS28f8949146665d34f1478d8e6e233cb2d2e64719" },
  [14] = { label = "Re-Import Rendered Items",                        id = "_RS2692fcda6cae7353ade67aeb44afc9b73328f57e" },
  [15] = { label = "Pay Calculator",                                  id = "_RS83ba7f4ed4a9ccf810e6db7a67ec19eaf23cd87e" },

  [16] = { label = "ADR Script Import",                               id = "_RS2a2fc6a2760fe6db880f72dc9f71597f388ee234" },
  [17] = { label = "Breath Detection Advanced",                       id = "_RS32e55a4ca2c6cfc54f0c4cd23aba82d923c6a827" },
  [18] = { label = "Breath Reduction",                                id = "_RS80b723419362d256b40aadc4ed4b89201162f44e" },
  [19] = { label = "Bulk Convert Streamlit to Pozotron Pickups",       id = "_RSd2fc64071d2f97735467152051d713588aff5f30" },
  [20] = { label = "Bulk Import Pozotron Pickups",                    id = "_RS549a29ad612b8ca51827813ed1ac2f7c3dd5b9a7" },
  [21] = { label = "Character Take Report",                           id = "_RS1d389332e9ca52c715cb5cb665d99b4435fed472" },
  [22] = { label = "Click Detection",                                 id = "_RSafb1da874543ff4672c8a0c4ed686eac06915782" },
  [23] = { label = "Regions from Additional Cast Items",              id = "_RSae3187bc3d6a33ab5f0faa9841e0e955384112592" },
  [24] = { label = "Reset Character FX Tracks and Sends",             id = "_RS717452610c79955f32bf0f877f52250c83b69757" },
  [25] = { label = "Simultaneous Speaker FX Baking",                   id = "_RSbf35b002d38636236651e324f6cbafdc4af74311" },
  [26] = { label = "Copy to Breaths, Clicks and Renders Tracks",       id = "_RSa059d5516de094928da5a3d35ff023efa91e787e" },
  [27] = { label = "Create Voice Reference Placeholders",             id = "_RS4b20c49a1708b9b1966b1b695a760bc405ba6e58" },
  [28] = { label = "Game Build and Update from Sources",              id = "_RS6eed47b9f7583c7b4a183ca4fa43e591b422b99e" },
  [29] = { label = "Line Region Maker",                               id = "_RS70f1dd65bcab07a376849b904aea2450c1cd0a87" },
  [30] = { label = "Mic Comparison Test Prep",                        id = "_RS3988212f9accf0298486e4b13e565e4e89761d8d" },
  [31] = { label = "Move Items to Named Track",                       id = "_RSc376951fffd90e277988cde3d949389efe5c62d4" },
}

-----------------------------------------
-- SECTIONS (Two Columns)
-----------------------------------------

local left_sections = {
  {
    title = "PROJECT SETUP:",
    order = { 1, 2, 3, 4, 5, 27, 6, 16, 31 }
  },
  {
    title = "POSTPRODUCTION UTILITIES",
    order = { 8, 24, 25, 11, 13, 14, 26, 17, 22, 18 }
  },
}

local right_sections = {
  {
    title = "PICKUP UTILITIES",
    order = { 19, 20 }
  },
  {
    title = "MULTICAST/TAKE UTILITIES",
    order = { 7, 9, 10, 12, 15, 23 }
  },
  {
    title = "SPECIAL UTILITIES",
    order = { 30, 28, 29, 21 }
  },
}

-----------------------------------------
-- INTERNALS
-----------------------------------------

local last_mouse_cap = 0
local running        = true

local function lookup_command(cmd_str)
  if type(cmd_str) == "string" and cmd_str:sub(1,1) == "_" then
    local id = reaper.NamedCommandLookup(cmd_str)
    if id == 0 then
      reaper.MB("Could not resolve command ID:\n\n" .. cmd_str, "Launcher error", 0)
      return nil
    end
    return id
  end
  reaper.MB("Invalid command ID:\n\n" .. tostring(cmd_str), "Launcher error", 0)
  return nil
end

local function run_entry(entry)
  local cmdID = lookup_command(entry.id)
  if not cmdID then return end

  reaper.Undo_BeginBlock()
  reaper.Main_OnCommand(cmdID, 0)
  reaper.Undo_EndBlock("Launcher: " .. (entry.label or "Run action"), -1)

  if CLOSE_AFTER_CLICK then
    running = false
  end
end

local function point_in_rect(px, py, x, y, w, h)
  return (px >= x and px <= x + w and py >= y and py <= y + h)
end

local function draw_button(x, y, w, h, label, hover)
  if hover then
    gfx.set(0.30, 0.30, 0.36, 1)
  else
    gfx.set(0.22, 0.22, 0.26, 1)
  end
  gfx.roundrect(x, y, w, h, 4, 1)

  gfx.set(0.12, 0.12, 0.15, 1)
  gfx.roundrect(x, y, w, h, 4, 0)

  gfx.set(1, 1, 1, 1)
  gfx.x = x + 8
  gfx.y = y + (h - gfx.texth) / 2
  gfx.drawstr(label or "")
end

local function compute_column_height(sections)
  local h = 0
  for s, sec in ipairs(sections) do
    h = h + SECTION_TITLE_H
    h = h + #sec.order * (BTN_H + BTN_MARGIN)
    if s < #sections then
      h = h + DIVIDER_H + BTN_MARGIN
    end
  end
  return h
end

local function compute_height()
  local col1_h = compute_column_height(left_sections)
  local col2_h = compute_column_height(right_sections)
  local content_h = math.max(col1_h, col2_h)
  return HEADER_H + BTN_MARGIN + content_h + BTN_MARGIN
end

local function draw_divider(x, y, w)
  gfx.set(0.35, 0.35, 0.40, 1)
  gfx.rect(x, y, w, 1, 1)
end

local function draw_column(sections, x0, col_w, y0, mx, my, mouse_released)
  local y = y0
  for s, sec in ipairs(sections) do
    -- Section title
    gfx.set(0.85, 0.85, 0.90, 1)
    gfx.x = x0
    gfx.y = y
    gfx.drawstr(sec.title or "")
    y = y + SECTION_TITLE_H

    -- Buttons
    for _, n in ipairs(sec.order) do
      local entry = cmd[n]
      if entry then
        local bx, by, bw, bh = x0, y, col_w, BTN_H
        local hover = point_in_rect(mx, my, bx, by, bw, bh)
        draw_button(bx, by, bw, bh, entry.label, hover)

        if hover and mouse_released then
          run_entry(entry)
        end
      end
      y = y + BTN_H + BTN_MARGIN
    end

    -- Divider
    if s < #sections then
      local dy = y + DIVIDER_H / 2
      draw_divider(x0, dy, col_w)
      y = y + DIVIDER_H + BTN_MARGIN
    end
  end
  return y
end

local function main_loop()
  if not running then
    gfx.quit()
    return
  end

  local ch = gfx.getchar()
  if ch < 0 or ch == 27 then
    gfx.quit()
    return
  end

  local mx, my         = gfx.mouse_x, gfx.mouse_y
  local mouse_cap      = gfx.mouse_cap
  local mouse_down     = (mouse_cap & 1) == 1
  local last_down      = (last_mouse_cap & 1) == 1
  local mouse_released = last_down and not mouse_down

  -- Background
  gfx.set(0.15, 0.15, 0.18, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)

  -- Header
  gfx.set(1, 1, 1, 1)
  gfx.x = BTN_MARGIN
  gfx.y = 6
  gfx.drawstr("Shortcut Menu")

  -- Column geometry
  local x_left  = BTN_MARGIN
  local col_w   = (gfx.w - (BTN_MARGIN * 2) - COL_GAP) / 2
  local x_right = x_left + col_w + COL_GAP
  local y_top   = HEADER_H + BTN_MARGIN

  -- Draw columns
  draw_column(left_sections,  x_left,  col_w, y_top, mx, my, mouse_released)
  draw_column(right_sections, x_right, col_w, y_top, mx, my, mouse_released)

  last_mouse_cap = mouse_cap
  gfx.update()
  reaper.defer(main_loop)
end

local function init_window()
  local h = compute_height()
  gfx.init("Shortcut Menu", WIN_W, h, 0, 200, 200)
  gfx.setfont(1, "Arial", 15)
end

init_window()
main_loop()
