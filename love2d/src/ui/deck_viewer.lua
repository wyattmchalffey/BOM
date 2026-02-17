-- Generic scrollable deck viewer with search and filter tabs.
-- Opened with a config table; can be reused for any card list.

local card_frame = require("src.ui.card_frame")
local util = require("src.ui.util")
local textures = require("src.fx.textures")

local viewer = {}

-- Layout constants
local PAD = 24
local CARD_W = card_frame.CARD_W
local CARD_H = card_frame.CARD_H
local GRID_PAD = 14
local HEADER_H = 36
local SEARCH_H = 30
local FILTER_H = 28
local CLOSE_BTN_W = 80
local CLOSE_BTN_H = 30
local SCROLL_SPEED = 50

-- Internal state
local _config = nil       -- current config table (nil = closed)
local _scroll_y = 0
local _search_text = ""
local _active_filter = 1  -- 1-based index into config.filters
local _search_focused = false
local _card_rects = {}    -- rebuilt each frame for hit testing
local _cursor_blink = 0

-- Box geometry (recalculated each draw)
local _box = { x = 0, y = 0, w = 0, h = 0 }

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

function viewer.open(config)
  _config = config
  _scroll_y = 0
  _search_text = ""
  _active_filter = 1
  _search_focused = false
  _card_rects = {}
end

function viewer.close()
  _config = nil
  _card_rects = {}
end

function viewer.is_open()
  return _config ~= nil
end

function viewer.get_config()
  return _config
end

--------------------------------------------------------------------------
-- Filtering helpers
--------------------------------------------------------------------------

local function get_visible_cards()
  if not _config then return {} end
  local out = {}
  local search_lower = string.lower(_search_text)
  for _, def in ipairs(_config.cards) do
    -- Text search
    local haystack = string.lower((def.name or "") .. " " .. (def.text or ""))
    local passes_search = (#search_lower == 0) or string.find(haystack, search_lower, 1, true)
    -- Filter tab
    local passes_filter = true
    if passes_search and _config.filters and _config.filter_fn then
      local filter_name = _config.filters[_active_filter]
      if filter_name and filter_name ~= "All" then
        passes_filter = _config.filter_fn(def, filter_name)
      end
    end
    if passes_search and passes_filter then
      out[#out + 1] = def
    end
  end
  return out
end

--------------------------------------------------------------------------
-- Box geometry
--------------------------------------------------------------------------

local function calc_box()
  local gw, gh = love.graphics.getDimensions()
  local w = math.min(780, gw - 60)
  local h = math.min(580, gh - 60)
  _box.x = math.floor((gw - w) / 2)
  _box.y = math.floor((gh - h) / 2)
  _box.w = w
  _box.h = h
end

local function grid_area()
  local top = HEADER_H + SEARCH_H + 8
  if _config and _config.filters and #_config.filters > 0 then
    top = top + FILTER_H + 6
  end
  local bottom = CLOSE_BTN_H + 16
  return _box.x + PAD, _box.y + top, _box.w - PAD * 2, _box.h - top - bottom
end

--------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------

local function draw_search_bar()
  local sx = _box.x + PAD
  local sy = _box.y + HEADER_H + 4
  local sw = _box.w - PAD * 2
  local sh = SEARCH_H

  -- Background
  love.graphics.setColor(0.07, 0.08, 0.11, 1)
  love.graphics.rectangle("fill", sx, sy, sw, sh, 5, 5)
  -- Border (highlight when focused)
  if _search_focused then
    love.graphics.setColor(0.35, 0.5, 0.9, 0.7)
  else
    love.graphics.setColor(0.2, 0.22, 0.28, 1)
  end
  love.graphics.rectangle("line", sx, sy, sw, sh, 5, 5)

  -- Search icon (magnifying glass placeholder)
  love.graphics.setColor(0.45, 0.47, 0.55, 1)
  love.graphics.setFont(util.get_font(12))
  love.graphics.print("Search:", sx + 8, sy + 7)

  -- Text content
  local text_x = sx + 64
  love.graphics.setColor(0.9, 0.91, 0.95, 1)
  love.graphics.setFont(util.get_font(13))
  local display_text = _search_text
  if #display_text == 0 and not _search_focused then
    love.graphics.setColor(0.4, 0.42, 0.5, 0.7)
    display_text = "Type to filter cards..."
  end
  love.graphics.print(display_text, text_x, sy + 7)

  -- Cursor blink when focused
  if _search_focused then
    _cursor_blink = (_cursor_blink + love.timer.getDelta() * 3) % 2
    if _cursor_blink < 1 then
      local tw = util.get_font(13):getWidth(_search_text)
      love.graphics.setColor(0.8, 0.85, 1, 0.9)
      love.graphics.rectangle("fill", text_x + tw + 1, sy + 6, 1, sh - 12)
    end
  end

  return sx, sy, sw, sh
end

local function draw_filter_tabs()
  if not _config or not _config.filters or #_config.filters == 0 then return end
  local accent = _config.accent or { 0.5, 0.5, 0.7 }
  local ty = _box.y + HEADER_H + SEARCH_H + 10
  local tx = _box.x + PAD
  local mx, my = love.mouse.getPosition()

  for i, label in ipairs(_config.filters) do
    local font = util.get_font(11)
    local tw = font:getWidth(label) + 16
    local th = FILTER_H - 4
    local is_active = (i == _active_filter)
    local is_hov = util.point_in_rect(mx, my, tx, ty, tw, th)

    if is_active then
      love.graphics.setColor(accent[1], accent[2], accent[3], 0.35)
    elseif is_hov then
      love.graphics.setColor(0.2, 0.22, 0.28, 1)
    else
      love.graphics.setColor(0.12, 0.13, 0.17, 1)
    end
    love.graphics.rectangle("fill", tx, ty, tw, th, 4, 4)

    if is_active then
      love.graphics.setColor(accent[1], accent[2], accent[3], 0.7)
    else
      love.graphics.setColor(0.25, 0.27, 0.33, 1)
    end
    love.graphics.rectangle("line", tx, ty, tw, th, 4, 4)

    love.graphics.setColor(0.85, 0.86, 0.92, is_active and 1 or 0.7)
    love.graphics.setFont(font)
    love.graphics.print(label, tx + 8, ty + 3)
    tx = tx + tw + 6
  end
end

function viewer.draw()
  if not _config then return end
  textures.init()

  local gw, gh = love.graphics.getDimensions()
  calc_box()
  local accent = _config.accent or { 0.5, 0.5, 0.7 }
  local mx, my = love.mouse.getPosition()

  -- Backdrop
  love.graphics.setColor(0, 0, 0, 0.82)
  love.graphics.rectangle("fill", 0, 0, gw, gh)

  -- Modal shadow
  love.graphics.setColor(0, 0, 0, 0.5)
  love.graphics.rectangle("fill", _box.x + 5, _box.y + 7, _box.w, _box.h, 10, 10)

  -- Modal box
  love.graphics.setColor(0.10, 0.11, 0.14, 1)
  love.graphics.rectangle("fill", _box.x, _box.y, _box.w, _box.h, 8, 8)

  -- Texture overlay on modal
  love.graphics.setScissor(_box.x, _box.y, _box.w, _box.h)
  textures.draw_tiled(textures.panel, _box.x, _box.y, _box.w, _box.h, 0.04)
  love.graphics.setScissor()

  -- Inner shadow
  textures.draw_inner_shadow(_box.x, _box.y, _box.w, _box.h, 4, 0.15)

  -- Border
  love.graphics.setColor(0.2, 0.22, 0.28, 1)
  love.graphics.rectangle("line", _box.x, _box.y, _box.w, _box.h, 8, 8)

  -- Header bar
  love.graphics.setColor(0.06, 0.07, 0.09, 0.9)
  love.graphics.rectangle("fill", _box.x + 1, _box.y + 1, _box.w - 2, HEADER_H - 2, 7, 7)
  love.graphics.setColor(accent[1], accent[2], accent[3], 0.5)
  love.graphics.rectangle("fill", _box.x + 4, _box.y + HEADER_H - 1, _box.w - 8, 1)

  -- Title
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(util.get_title_font(16))
  love.graphics.print(_config.title or "Deck Viewer", _box.x + PAD, _box.y + 9)

  -- Hint text (if provided)
  if _config.hint then
    local title_w = util.get_title_font(16):getWidth(_config.title or "Deck Viewer")
    love.graphics.setColor(0.5, 0.7, 1.0, 0.7)
    love.graphics.setFont(util.get_font(11))
    love.graphics.print(_config.hint, _box.x + PAD + title_w + 16, _box.y + 13)
  end

  -- Close X button (top right of header)
  local cx_btn_x = _box.x + _box.w - 36
  local cx_btn_y = _box.y + 6
  local cx_btn_s = 24
  local close_x_hov = util.point_in_rect(mx, my, cx_btn_x, cx_btn_y, cx_btn_s, cx_btn_s)
  if close_x_hov then
    love.graphics.setColor(0.4, 0.15, 0.15, 0.8)
    love.graphics.rectangle("fill", cx_btn_x, cx_btn_y, cx_btn_s, cx_btn_s, 4, 4)
  end
  love.graphics.setColor(0.7, 0.72, 0.8, close_x_hov and 1 or 0.6)
  love.graphics.setFont(util.get_font(14))
  love.graphics.print("X", cx_btn_x + 7, cx_btn_y + 4)

  -- Search bar
  draw_search_bar()

  -- Filter tabs
  draw_filter_tabs()

  -- Card grid (scrollable)
  local gx, gy, gw_area, gh_area = grid_area()
  local visible = get_visible_cards()
  local cols = math.max(1, math.floor((gw_area + GRID_PAD) / (CARD_W + GRID_PAD)))
  local rows = math.ceil(#visible / cols)
  local content_h = rows * (CARD_H + GRID_PAD) - GRID_PAD
  local max_scroll = math.max(0, content_h - gh_area)
  _scroll_y = math.max(0, math.min(_scroll_y, max_scroll))

  -- Reset card rects
  _card_rects = {}

  -- Scissor to clip cards within grid area
  love.graphics.setScissor(gx, gy, gw_area, gh_area)

  for idx, def in ipairs(visible) do
    local col = (idx - 1) % cols
    local row = math.floor((idx - 1) / cols)
    local card_x = gx + col * (CARD_W + GRID_PAD)
    local card_y = gy + row * (CARD_H + GRID_PAD) - _scroll_y

    -- Skip cards entirely off-screen
    if card_y + CARD_H >= gy and card_y <= gy + gh_area then
      -- Store rect for hit testing
      _card_rects[#_card_rects + 1] = {
        def = def,
        x = card_x, y = card_y,
        w = CARD_W, h = CARD_H,
      }

      -- Draw the card
      card_frame.draw(card_x, card_y, {
        title = def.name,
        faction = def.faction,
        kind = def.kind,
        typeLine = (def.faction or "") .. " — " .. (def.kind or ""),
        text = def.text,
        costs = def.costs,
        tier = def.tier,
        abilities_list = def.abilities,
        show_ability_text = true,
      })

      -- Card overlay (caller-provided: dim, badges, highlights)
      if _config.card_overlay_fn then
        _config.card_overlay_fn(def, card_x, card_y, CARD_W, CARD_H)
      end

      -- Hover highlight for clickable cards
      if _config.can_click_fn and _config.can_click_fn(def) then
        local card_hov = util.point_in_rect(mx, my, card_x, card_y, CARD_W, CARD_H)
        if card_hov then
          love.graphics.setColor(0.2, 0.8, 0.4, 0.45)
          love.graphics.setLineWidth(3)
          love.graphics.rectangle("line", card_x - 2, card_y - 2, CARD_W + 4, CARD_H + 4, 7, 7)
          love.graphics.setLineWidth(1)
        end
      end
    end
  end

  love.graphics.setScissor()

  -- Scroll bar indicator (if content overflows)
  if max_scroll > 0 then
    local bar_x = gx + gw_area - 4
    local bar_track_h = gh_area
    local bar_h = math.max(20, bar_track_h * (gh_area / content_h))
    local bar_y = gy + (_scroll_y / max_scroll) * (bar_track_h - bar_h)
    love.graphics.setColor(1, 1, 1, 0.12)
    love.graphics.rectangle("fill", bar_x, gy, 4, bar_track_h, 2, 2)
    love.graphics.setColor(1, 1, 1, 0.35)
    love.graphics.rectangle("fill", bar_x, bar_y, 4, bar_h, 2, 2)
  end

  -- "No results" message
  if #visible == 0 then
    love.graphics.setColor(0.5, 0.52, 0.6, 0.8)
    love.graphics.setFont(util.get_font(13))
    love.graphics.printf("No cards match your search.", gx, gy + gh_area / 2 - 10, gw_area, "center")
  end

  -- Card count
  love.graphics.setColor(0.45, 0.47, 0.55, 0.8)
  love.graphics.setFont(util.get_font(10))
  love.graphics.print(#visible .. " / " .. #_config.cards .. " cards", _box.x + PAD, _box.y + _box.h - 20)
end

--------------------------------------------------------------------------
-- Input handling
--------------------------------------------------------------------------

function viewer.mousepressed(x, y, button)
  if not _config or button ~= 1 then return false end
  calc_box()

  -- Close X button
  local cx_btn_x = _box.x + _box.w - 36
  local cx_btn_y = _box.y + 6
  if util.point_in_rect(x, y, cx_btn_x, cx_btn_y, 24, 24) then
    viewer.close()
    return true
  end

  -- Backdrop click (outside box)
  if not util.point_in_rect(x, y, _box.x, _box.y, _box.w, _box.h) then
    viewer.close()
    return true
  end

  -- Search bar focus
  local search_x = _box.x + PAD
  local search_y = _box.y + HEADER_H + 4
  local search_w = _box.w - PAD * 2
  if util.point_in_rect(x, y, search_x, search_y, search_w, SEARCH_H) then
    _search_focused = true
    return true
  else
    _search_focused = false
  end

  -- Filter tabs
  if _config.filters and #_config.filters > 0 then
    local ty = _box.y + HEADER_H + SEARCH_H + 10
    local tx = _box.x + PAD
    for i, label in ipairs(_config.filters) do
      local tw = util.get_font(11):getWidth(label) + 16
      local th = FILTER_H - 4
      if util.point_in_rect(x, y, tx, ty, tw, th) then
        _active_filter = i
        _scroll_y = 0  -- reset scroll when filter changes
        return true
      end
      tx = tx + tw + 6
    end
  end

  -- Card click
  for _, rect in ipairs(_card_rects) do
    if util.point_in_rect(x, y, rect.x, rect.y, rect.w, rect.h) then
      -- Check if in grid area (not clipped)
      local gx, gy, gw_a, gh_a = grid_area()
      if y >= gy and y <= gy + gh_a then
        if _config.on_click then
          _config.on_click(rect.def)
        end
        return true
      end
    end
  end

  return true  -- consume click (we're inside the modal)
end

function viewer.wheelmoved(dx, dy)
  if not _config then return false end
  _scroll_y = _scroll_y - dy * SCROLL_SPEED
  -- Clamping happens in draw
  return true
end

function viewer.keypressed(key)
  if not _config then return false end
  if key == "escape" then
    viewer.close()
    return true
  end
  if _search_focused then
    if key == "backspace" then
      _search_text = string.sub(_search_text, 1, math.max(0, #_search_text - 1))
      _scroll_y = 0
      return true
    end
  end
  return false
end

function viewer.textinput(text)
  if not _config then return false end
  if _search_focused then
    _search_text = _search_text .. text
    _scroll_y = 0
    return true
  end
  return false
end

-- Hit test: returns card def if mouse is over a visible card, nil otherwise
function viewer.hit_test_card(mx, my)
  for _, rect in ipairs(_card_rects) do
    if util.point_in_rect(mx, my, rect.x, rect.y, rect.w, rect.h) then
      local gx, gy, gw_a, gh_a = grid_area()
      if my >= gy and my <= gy + gh_a then
        return rect.def
      end
    end
  end
  return nil
end

-- Expose card rects for external use
function viewer.get_card_rects()
  return _card_rects
end

return viewer
