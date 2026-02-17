-- Main menu state: title screen with Local / Host / Join options.
-- Internal state machine: "main", "browse", "connecting"

local util = require("src.ui.util")
local runtime_multiplayer = require("src.net.runtime_multiplayer")
local threaded_relay = require("src.net.threaded_relay")
local headless_host_service = require("src.net.headless_host_service")
local authoritative_client_game = require("src.net.authoritative_client_game")
local client_session = require("src.net.client_session")
local websocket_transport = require("src.net.websocket_transport")
local json = require("src.net.json_codec")
local textures = require("src.fx.textures")
local room_list_fetcher = require("src.net.room_list_fetcher")
local sound = require("src.fx.sound")
local settings = require("src.settings")
local factions_data = require("src.data.factions")

local MenuState = {}
MenuState.__index = MenuState

-- Colors
local BG = { 0.08, 0.08, 0.12 }
local GOLD = { 0.92, 0.78, 0.35 }
local WHITE = { 0.92, 0.92, 0.96 }
local DIM = { 0.55, 0.55, 0.65 }
local ERROR_COLOR = { 0.95, 0.35, 0.35 }
local BUTTON_COLORS = {
  { 0.15, 0.55, 0.25 },  -- green (Play Online)
  { 0.30, 0.33, 0.45 },  -- gray-blue (Settings)
}
local BUTTON_HOVER = 0.15

local BUTTON_W = 360
local BUTTON_H = 60

function MenuState.new(callbacks)
  callbacks = callbacks or {}
  local self = setmetatable({
    start_game = callbacks.start_game,
    return_to_menu = callbacks.return_to_menu,

    screen = "main",          -- "main" | "browse" | "connecting"
    hover_button = nil,
    cursor_hand = love.mouse.getSystemCursor("hand"),
    current_cursor = "arrow",

    player_name = callbacks.player_name or "Player",
    cursor_blink = 0,

    -- Settings screen state
    settings_volume = settings.values.sfx_volume,
    settings_fullscreen = settings.values.fullscreen,
    settings_dragging_slider = false,

    -- Deck builder screen state
    deckbuilder_hover = nil,

    -- Connection state
    connect_error = nil,

    -- Threaded relay for Play Online (host)
    _relay = nil,
    _relay_service = nil,

    -- Threaded joiner adapter for Join Game
    _joiner_adapter = nil,

    -- Browse screen
    _room_fetcher = nil,
    browse_scroll = 0,
    browse_hover_join = nil,
    browse_hover_host = false,
  }, MenuState)
  return self
end

-- Button definitions per screen
local function main_buttons()
  return {
    { label = "Play Online",  color = BUTTON_COLORS[1] },
    { label = "Deck Builder", color = BUTTON_COLORS[2] },
    { label = "Settings",     color = BUTTON_COLORS[2] },
    { label = "Quit",         color = { 0.55, 0.15, 0.15 } },
  }
end

-- Layout helpers
local function center_x(w)
  return (love.graphics.getWidth() - w) / 2
end

local function buttons_start_y(count)
  local gh = love.graphics.getHeight()
  return gh / 2 - (count * (BUTTON_H + 16) - 16) / 2 + 40
end

local function button_rects(buttons)
  local rects = {}
  local sy = buttons_start_y(#buttons)
  for i = 1, #buttons do
    rects[i] = {
      x = center_x(BUTTON_W),
      y = sy + (i - 1) * (BUTTON_H + 16),
      w = BUTTON_W,
      h = BUTTON_H,
    }
  end
  return rects
end

local function back_button_rect()
  return { x = 20, y = 20, w = 80, h = 36 }
end

local function point_in_rect(px, py, r)
  return px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h
end

-- Drawing helpers
local function draw_button(r, label, color, hovered, disabled)
  local c = color or BUTTON_COLORS[1]
  if disabled then
    love.graphics.setColor(0.2, 0.2, 0.25, 0.6)
  elseif hovered then
    love.graphics.setColor(c[1] + BUTTON_HOVER, c[2] + BUTTON_HOVER, c[3] + BUTTON_HOVER, 1)
  else
    love.graphics.setColor(c[1], c[2], c[3], 1)
  end
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 8, 8)

  -- Border
  if hovered and not disabled then
    love.graphics.setColor(1, 1, 1, 0.4)
  else
    love.graphics.setColor(1, 1, 1, 0.12)
  end
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", r.x, r.y, r.w, r.h, 8, 8)
  love.graphics.setLineWidth(1)

  -- Label
  local font = util.get_title_font(22)
  love.graphics.setFont(font)
  if disabled then
    love.graphics.setColor(0.5, 0.5, 0.55, 0.6)
  else
    love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 1)
  end
  love.graphics.printf(label, r.x, r.y + (r.h - font:getHeight()) / 2, r.w, "center")
end

local function draw_back_button(hovered)
  local r = back_button_rect()
  if hovered then
    love.graphics.setColor(0.3, 0.3, 0.4, 0.8)
  else
    love.graphics.setColor(0.2, 0.2, 0.28, 0.6)
  end
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 6, 6)
  love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], hovered and 1 or 0.7)
  local font = util.get_font(14)
  love.graphics.setFont(font)
  love.graphics.printf("< Back", r.x, r.y + (r.h - font:getHeight()) / 2, r.w, "center")
end

-- Settings screen layout constants
local SETTINGS_LEFT = 340
local SETTINGS_LABEL_W = 160
local SETTINGS_INPUT_X = SETTINGS_LEFT + SETTINGS_LABEL_W + 20
local SETTINGS_ROW_Y_START = 180
local SETTINGS_ROW_H = 60
local SETTINGS_NAME_W = 300
local SETTINGS_NAME_H = 40
local SETTINGS_SLIDER_W = 300
local SETTINGS_SLIDER_H = 8
local SETTINGS_KNOB_R = 12
local SETTINGS_TOGGLE_W = 80
local SETTINGS_TOGGLE_H = 36

function MenuState:settings_slider_rect()
  local y = SETTINGS_ROW_Y_START + SETTINGS_ROW_H + (SETTINGS_ROW_H - SETTINGS_SLIDER_H) / 2
  return { x = SETTINGS_INPUT_X, y = y, w = SETTINGS_SLIDER_W, h = SETTINGS_SLIDER_H }
end

function MenuState:draw_settings()
  local gw = love.graphics.getWidth()
  draw_back_button(self.hover_button == -1)

  -- Title
  local title_font = util.get_title_font(32)
  love.graphics.setFont(title_font)
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], 1)
  love.graphics.printf("Settings", 0, 30, gw, "center")

  local label_font = util.get_title_font(20)
  local value_font = util.get_font(16)

  -- Row 1: Player Name
  local row_y = SETTINGS_ROW_Y_START
  love.graphics.setFont(label_font)
  love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 1)
  love.graphics.print("Player Name", SETTINGS_LEFT, row_y + (SETTINGS_NAME_H - label_font:getHeight()) / 2)

  -- Name input box
  local name_r = { x = SETTINGS_INPUT_X, y = row_y, w = SETTINGS_NAME_W, h = SETTINGS_NAME_H }
  love.graphics.setColor(0.12, 0.12, 0.18, 1)
  love.graphics.rectangle("fill", name_r.x, name_r.y, name_r.w, name_r.h, 6, 6)
  love.graphics.setColor(1, 1, 1, 0.2)
  love.graphics.rectangle("line", name_r.x, name_r.y, name_r.w, name_r.h, 6, 6)

  love.graphics.setFont(value_font)
  love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 1)
  local display_name = self.player_name
  -- Blinking cursor
  local show_cursor = (math.floor(self.cursor_blink * 2) % 2 == 0)
  if show_cursor then
    display_name = display_name .. "|"
  end
  love.graphics.print(display_name, name_r.x + 10, name_r.y + (name_r.h - value_font:getHeight()) / 2)

  -- Row 2: SFX Volume
  row_y = SETTINGS_ROW_Y_START + SETTINGS_ROW_H
  love.graphics.setFont(label_font)
  love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 1)
  love.graphics.print("SFX Volume", SETTINGS_LEFT, row_y + (SETTINGS_ROW_H - label_font:getHeight()) / 2)

  -- Slider track
  local sr = self:settings_slider_rect()
  love.graphics.setColor(0.2, 0.2, 0.28, 1)
  love.graphics.rectangle("fill", sr.x, sr.y, sr.w, sr.h, 4, 4)

  -- Filled portion
  local fill_w = sr.w * self.settings_volume
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], 0.8)
  love.graphics.rectangle("fill", sr.x, sr.y, fill_w, sr.h, 4, 4)

  -- Knob
  local knob_x = sr.x + fill_w
  local knob_y = sr.y + sr.h / 2
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], 1)
  love.graphics.circle("fill", knob_x, knob_y, SETTINGS_KNOB_R)
  love.graphics.setColor(1, 1, 1, 0.3)
  love.graphics.circle("line", knob_x, knob_y, SETTINGS_KNOB_R)

  -- Volume percentage
  love.graphics.setFont(value_font)
  love.graphics.setColor(DIM[1], DIM[2], DIM[3], 1)
  love.graphics.print(math.floor(self.settings_volume * 100 + 0.5) .. "%", sr.x + sr.w + 16, sr.y - 6)

  -- Row 3: Fullscreen
  row_y = SETTINGS_ROW_Y_START + SETTINGS_ROW_H * 2
  love.graphics.setFont(label_font)
  love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 1)
  love.graphics.print("Fullscreen", SETTINGS_LEFT, row_y + (SETTINGS_TOGGLE_H - label_font:getHeight()) / 2)

  -- Toggle button
  local tog_r = { x = SETTINGS_INPUT_X, y = row_y, w = SETTINGS_TOGGLE_W, h = SETTINGS_TOGGLE_H }
  if self.settings_fullscreen then
    love.graphics.setColor(0.15, 0.55, 0.25, 1)
  else
    love.graphics.setColor(0.25, 0.25, 0.32, 1)
  end
  love.graphics.rectangle("fill", tog_r.x, tog_r.y, tog_r.w, tog_r.h, 6, 6)
  love.graphics.setColor(1, 1, 1, 0.2)
  love.graphics.rectangle("line", tog_r.x, tog_r.y, tog_r.w, tog_r.h, 6, 6)

  love.graphics.setFont(value_font)
  love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 1)
  love.graphics.printf(self.settings_fullscreen and "On" or "Off", tog_r.x, tog_r.y + (tog_r.h - value_font:getHeight()) / 2, tog_r.w, "center")
end

-- Deck builder constants
local DECK_FACTIONS = { "Human", "Orc" }
local DECK_CARD_W = 260
local DECK_CARD_H = 160
local DECK_CARD_GAP = 40

function MenuState:draw_deckbuilder()
  local gw = love.graphics.getWidth()
  draw_back_button(self.hover_button == -1)

  -- Title
  local title_font = util.get_title_font(32)
  love.graphics.setFont(title_font)
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], 1)
  love.graphics.printf("Deck Builder", 0, 30, gw, "center")

  -- Subtitle
  local sub_font = util.get_font(14)
  love.graphics.setFont(sub_font)
  love.graphics.setColor(DIM[1], DIM[2], DIM[3], 1)
  love.graphics.printf("Choose your faction", 0, 70, gw, "center")

  -- Faction cards
  local total_w = #DECK_FACTIONS * DECK_CARD_W + (#DECK_FACTIONS - 1) * DECK_CARD_GAP
  local start_x = (gw - total_w) / 2
  local card_y = 140

  local label_font = util.get_title_font(26)
  local detail_font = util.get_font(13)

  for i, fname in ipairs(DECK_FACTIONS) do
    local fdata = factions_data[fname]
    local cx = start_x + (i - 1) * (DECK_CARD_W + DECK_CARD_GAP)
    local selected = (settings.values.faction == fname)
    local hovered = (self.deckbuilder_hover == i)

    -- Card background
    if selected then
      love.graphics.setColor(fdata.color[1] * 0.35, fdata.color[2] * 0.35, fdata.color[3] * 0.35, 1)
    elseif hovered then
      love.graphics.setColor(0.18, 0.18, 0.28, 0.9)
    else
      love.graphics.setColor(0.14, 0.14, 0.22, 0.7)
    end
    love.graphics.rectangle("fill", cx, card_y, DECK_CARD_W, DECK_CARD_H, 10, 10)

    -- Border (faction color if selected, subtle otherwise)
    if selected then
      love.graphics.setColor(fdata.color[1], fdata.color[2], fdata.color[3], 0.9)
      love.graphics.setLineWidth(3)
    else
      love.graphics.setColor(1, 1, 1, hovered and 0.25 or 0.1)
      love.graphics.setLineWidth(2)
    end
    love.graphics.rectangle("line", cx, card_y, DECK_CARD_W, DECK_CARD_H, 10, 10)
    love.graphics.setLineWidth(1)

    -- Faction name
    love.graphics.setFont(label_font)
    love.graphics.setColor(fdata.color[1], fdata.color[2], fdata.color[3], 1)
    love.graphics.printf(fname, cx, card_y + 30, DECK_CARD_W, "center")

    -- Stats
    love.graphics.setFont(detail_font)
    love.graphics.setColor(DIM[1], DIM[2], DIM[3], 1)
    love.graphics.printf(
      "Workers: " .. (fdata.default_starting_workers or 2) .. "/" .. (fdata.default_max_workers or 8),
      cx, card_y + 75, DECK_CARD_W, "center"
    )

    -- Selected indicator
    if selected then
      love.graphics.setFont(detail_font)
      love.graphics.setColor(fdata.color[1], fdata.color[2], fdata.color[3], 0.9)
      love.graphics.printf("Selected", cx, card_y + DECK_CARD_H - 30, DECK_CARD_W, "center")
    end
  end
end

-- Screen drawing

function MenuState:draw_main()
  local gw = love.graphics.getWidth()
  local title_font = util.get_title_font(48)
  love.graphics.setFont(title_font)
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], 1)
  love.graphics.printf("Battles of Masadoria", 0, 100, gw, "center")

  local subtitle_font = util.get_font(14)
  love.graphics.setFont(subtitle_font)
  love.graphics.setColor(DIM[1], DIM[2], DIM[3], 1)
  love.graphics.printf("A strategic card game of workers and warfare", 0, 155, gw, "center")

  local btns = main_buttons()
  local rects = button_rects(btns)
  for i, btn in ipairs(btns) do
    draw_button(rects[i], btn.label, btn.color, self.hover_button == i)
  end
end

-- Browse screen constants
local BROWSE_ROW_H = 56
local BROWSE_ROW_PAD = 8
local BROWSE_LIST_X_PAD = 60
local BROWSE_JOIN_W = 100
local BROWSE_JOIN_H = 36
local BROWSE_HOST_COLOR = { 0.15, 0.55, 0.25 }

function MenuState:draw_browse()
  local gw = love.graphics.getWidth()
  local gh = love.graphics.getHeight()
  draw_back_button(self.hover_button == -1)

  -- Title
  local title_font = util.get_title_font(32)
  love.graphics.setFont(title_font)
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], 1)
  love.graphics.printf("Browse Games", 0, 30, gw, "center")

  -- "Host Game" button (top area)
  local host_btn = {
    x = center_x(BUTTON_W),
    y = 80,
    w = BUTTON_W,
    h = BUTTON_H,
  }
  draw_button(host_btn, "Host Game", BROWSE_HOST_COLOR, self.browse_hover_host)

  -- Room list area
  local list_top = 160
  local list_bottom = gh - 40
  local list_h = list_bottom - list_top
  local list_x = BROWSE_LIST_X_PAD
  local list_w = gw - BROWSE_LIST_X_PAD * 2

  -- Status / error text
  local status_font = util.get_font(13)
  love.graphics.setFont(status_font)

  if self.connect_error then
    love.graphics.setColor(ERROR_COLOR[1], ERROR_COLOR[2], ERROR_COLOR[3], 1)
    love.graphics.printf(self.connect_error, 0, list_top, gw, "center")
    return
  end

  local rooms = self._room_fetcher and self._room_fetcher.rooms or {}
  local fetcher_error = self._room_fetcher and self._room_fetcher.error

  if fetcher_error then
    love.graphics.setColor(ERROR_COLOR[1], ERROR_COLOR[2], ERROR_COLOR[3], 0.8)
    love.graphics.printf("Error: " .. tostring(fetcher_error), 0, list_bottom + 4, gw, "center")
  end

  if #rooms == 0 then
    love.graphics.setColor(DIM[1], DIM[2], DIM[3], 1)
    local msg = "No games found"
    if self._room_fetcher and self._room_fetcher.loading then
      msg = "Searching for games..."
    end
    love.graphics.printf(msg, 0, list_top + list_h / 2 - 10, gw, "center")
    return
  end

  -- Clamp scroll
  local total_h = #rooms * (BROWSE_ROW_H + BROWSE_ROW_PAD)
  local max_scroll = math.max(0, total_h - list_h)
  self.browse_scroll = math.max(0, math.min(self.browse_scroll, max_scroll))

  -- Draw room rows with scissor clipping
  love.graphics.setScissor(list_x, list_top, list_w, list_h)

  local row_font = util.get_title_font(20)
  local small_font = util.get_font(12)

  for i, room in ipairs(rooms) do
    local ry = list_top + (i - 1) * (BROWSE_ROW_H + BROWSE_ROW_PAD) - self.browse_scroll

    -- Skip if off-screen
    if ry + BROWSE_ROW_H >= list_top and ry <= list_bottom then
      -- Row background
      local hovered = self.browse_hover_join == i
      if hovered then
        love.graphics.setColor(0.18, 0.18, 0.28, 0.9)
      else
        love.graphics.setColor(0.14, 0.14, 0.22, 0.7)
      end
      love.graphics.rectangle("fill", list_x, ry, list_w, BROWSE_ROW_H, 8, 8)

      -- Row border
      love.graphics.setColor(1, 1, 1, 0.08)
      love.graphics.setLineWidth(1)
      love.graphics.rectangle("line", list_x, ry, list_w, BROWSE_ROW_H, 8, 8)

      -- Host name
      love.graphics.setFont(row_font)
      love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 1)
      love.graphics.print(room.hostName or "Player", list_x + 16, ry + (BROWSE_ROW_H - row_font:getHeight()) / 2)

      -- Join button
      local join_x = list_x + list_w - BROWSE_JOIN_W - 12
      local join_y = ry + (BROWSE_ROW_H - BROWSE_JOIN_H) / 2
      local join_hovered = hovered
      if join_hovered then
        love.graphics.setColor(0.2, 0.58, 0.35, 1)
      else
        love.graphics.setColor(0.18, 0.50, 0.28, 1)
      end
      love.graphics.rectangle("fill", join_x, join_y, BROWSE_JOIN_W, BROWSE_JOIN_H, 6, 6)
      love.graphics.setColor(1, 1, 1, 0.3)
      love.graphics.rectangle("line", join_x, join_y, BROWSE_JOIN_W, BROWSE_JOIN_H, 6, 6)

      love.graphics.setFont(small_font)
      love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 1)
      love.graphics.printf("Join", join_x, join_y + (BROWSE_JOIN_H - small_font:getHeight()) / 2, BROWSE_JOIN_W, "center")
    end
  end

  love.graphics.setScissor()

  -- Loading indicator
  if self._room_fetcher and self._room_fetcher.loading then
    love.graphics.setFont(small_font)
    love.graphics.setColor(DIM[1], DIM[2], DIM[3], 0.7)
    love.graphics.printf("Refreshing...", 0, list_bottom + 4, gw, "center")
  end
end

function MenuState:draw_connecting()
  local gw = love.graphics.getWidth()
  local gh = love.graphics.getHeight()

  local font = util.get_title_font(24)
  love.graphics.setFont(font)
  love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 1)
  love.graphics.printf("Connecting...", 0, gh / 2 - 20, gw, "center")

  if self.connect_error then
    love.graphics.setFont(util.get_font(13))
    love.graphics.setColor(ERROR_COLOR[1], ERROR_COLOR[2], ERROR_COLOR[3], 1)
    love.graphics.printf(self.connect_error, center_x(BUTTON_W), gh / 2 + 20, BUTTON_W, "center")
  end
end

function MenuState:draw()
  -- Background
  love.graphics.setColor(BG[1], BG[2], BG[3], 1)
  love.graphics.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())

  if self.screen == "main" then
    self:draw_main()
  elseif self.screen == "browse" then
    self:draw_browse()
  elseif self.screen == "connecting" then
    self:draw_connecting()
  elseif self.screen == "settings" then
    self:draw_settings()
  elseif self.screen == "deckbuilder" then
    self:draw_deckbuilder()
  end

  -- Version text
  local gw = love.graphics.getWidth()
  local gh = love.graphics.getHeight()
  local version_font = util.get_font(11)
  love.graphics.setFont(version_font)
  love.graphics.setColor(DIM[1], DIM[2], DIM[3], 0.6)
  love.graphics.printf("v0.1.0", gw - 80, gh - 24, 70, "right")

  textures.draw_vignette()
end

function MenuState:poll_joiner()
  if not self._joiner_adapter then return end

  self._joiner_adapter:poll()

  if self._joiner_adapter.connected then
    local adapter = self._joiner_adapter
    self._joiner_adapter = nil

    self.start_game({
      authoritative_adapter = adapter,
    })
  elseif self._joiner_adapter.connect_error then
    local err = self._joiner_adapter.connect_error
    self._joiner_adapter:cleanup()
    self._joiner_adapter = nil
    self:enter_browse()
    self.connect_error = err
  end
end

function MenuState:update(dt)
  self.cursor_blink = self.cursor_blink + dt

  -- Poll threaded relay connection
  self:poll_relay()

  -- Poll threaded joiner connection
  self:poll_joiner()

  -- Poll room list fetcher
  if self.screen == "browse" and self._room_fetcher then
    self._room_fetcher:poll(dt)
  end

  -- Update cursor
  local want_hand = self.hover_button ~= nil
  local desired = want_hand and "hand" or "arrow"
  if desired ~= self.current_cursor then
    if desired == "hand" then
      love.mouse.setCursor(self.cursor_hand)
    else
      love.mouse.setCursor()
    end
    self.current_cursor = desired
  end
end

function MenuState:go_back()
  self.connect_error = nil
  self.screen = "main"
  self.hover_button = nil
  -- Clean up any in-progress relay connection
  if self._relay then
    self._relay:cleanup()
    self._relay = nil
    self._relay_service = nil
  end
  -- Clean up any in-progress joiner connection
  if self._joiner_adapter then
    self._joiner_adapter:cleanup()
    self._joiner_adapter = nil
  end
  -- Clean up room fetcher
  if self._room_fetcher then
    self._room_fetcher:cleanup()
    self._room_fetcher = nil
  end
end

-- Get effective player name (default if empty)
function MenuState:get_player_name()
  local name = self.player_name
  if name == "" then name = "Player" end
  return name
end

function MenuState:save_settings_and_back()
  settings.values.player_name = self.player_name ~= "" and self.player_name or "Player"
  settings.values.sfx_volume = self.settings_volume
  settings.values.fullscreen = self.settings_fullscreen
  settings.save()
  self.screen = "main"
  self.hover_button = nil
  self.settings_dragging_slider = false
end

function MenuState:enter_browse()
  self.screen = "browse"
  self.connect_error = nil
  self.browse_scroll = 0
  self.browse_hover_join = nil
  self.browse_hover_host = false
  self.hover_button = nil

  -- Start fetching room list
  if self._room_fetcher then
    self._room_fetcher:cleanup()
  end
  self._room_fetcher = room_list_fetcher.new("https://bom-hbfv.onrender.com/rooms")
end

function MenuState:do_play_online()
  self.screen = "connecting"
  self.connect_error = nil

  -- Start threaded connection (non-blocking)
  self._relay = threaded_relay.start("wss://bom-hbfv.onrender.com", self:get_player_name())

  -- Create headless host service (local game logic authority)
  self._relay_service = headless_host_service.new({})
  self._relay:attach_service(self._relay_service)
end

function MenuState:do_browse_join(room_code)
  local url = "wss://bom-hbfv.onrender.com/join/" .. room_code
  local name = self:get_player_name()

  -- Clean up fetcher
  if self._room_fetcher then
    self._room_fetcher:cleanup()
    self._room_fetcher = nil
  end

  local ok_call, built = pcall(runtime_multiplayer.build, {
    mode = "threaded_websocket",
    url = url,
    player_name = name,
  })

  if not ok_call then
    self.connect_error = "Connection failed: " .. tostring(built)
    return
  end
  if built.ok then
    self._joiner_adapter = built.adapter
    self.screen = "connecting"
    self.connect_error = nil
  else
    self.connect_error = "Connection failed: " .. tostring(built.reason)
  end
end

-- Called from update() when relay is active
function MenuState:poll_relay()
  if not self._relay then return end

  self._relay:poll()

  if self._relay.state == "connected" then
    -- Build in-process adapter for the host player
    local HeadlessFrameClient = {}
    HeadlessFrameClient.__index = HeadlessFrameClient
    function HeadlessFrameClient.new(service)
      return setmetatable({ service = service, _last = nil }, HeadlessFrameClient)
    end
    function HeadlessFrameClient:send(frame)
      self._last = frame
    end
    function HeadlessFrameClient:receive(_timeout_ms)
      return self.service:handle_frame(self._last)
    end

    local transport = websocket_transport.new({
      client = HeadlessFrameClient.new(self._relay_service),
      encode = json.encode,
      decode = json.decode,
    })

    local session = client_session.new({
      transport = transport,
      player_name = self:get_player_name(),
    })

    local adapter = authoritative_client_game.new({ session = session })

    local relay = self._relay
    local function step_fn()
      relay:poll()
    end
    local function cleanup_fn()
      relay:cleanup()
    end

    self._relay = nil
    self._relay_service = nil

    self.start_game({
      authoritative_adapter = adapter,
      server_step = step_fn,
      server_cleanup = cleanup_fn,
      room_code = relay.room_code,
    })
  elseif self._relay.state == "error" then
    local err = self._relay.error_msg
    self._relay = nil
    self._relay_service = nil
    -- Go back to browse screen (re-start fetcher) so user sees the error
    self:enter_browse()
    self.connect_error = err
  end
end

function MenuState:mousepressed(x, y, button, istouch, presses)
  if button ~= 1 then return end

  if self.screen == "main" then
    local btns = main_buttons()
    local rects = button_rects(btns)
    for i = 1, #btns do
      if point_in_rect(x, y, rects[i]) then
        if i == 1 then
          self:enter_browse()
        elseif i == 2 then
          self.screen = "deckbuilder"
          self.hover_button = nil
        elseif i == 3 then
          self.screen = "settings"
          self.hover_button = nil
        elseif i == 4 then
          love.event.quit()
        end
        return
      end
    end

  elseif self.screen == "deckbuilder" then
    -- Back button
    if point_in_rect(x, y, back_button_rect()) then
      self.screen = "main"
      self.hover_button = nil
      return
    end
    -- Faction cards
    local gw = love.graphics.getWidth()
    local total_w = #DECK_FACTIONS * DECK_CARD_W + (#DECK_FACTIONS - 1) * DECK_CARD_GAP
    local start_x = (gw - total_w) / 2
    local card_y = 140
    for i, fname in ipairs(DECK_FACTIONS) do
      local cx = start_x + (i - 1) * (DECK_CARD_W + DECK_CARD_GAP)
      local r = { x = cx, y = card_y, w = DECK_CARD_W, h = DECK_CARD_H }
      if point_in_rect(x, y, r) then
        settings.values.faction = fname
        settings.save()
        return
      end
    end

  elseif self.screen == "settings" then
    -- Back button
    if point_in_rect(x, y, back_button_rect()) then
      self:save_settings_and_back()
      return
    end
    -- Volume slider
    local sr = self:settings_slider_rect()
    local slider_hit = { x = sr.x - SETTINGS_KNOB_R, y = sr.y - SETTINGS_KNOB_R, w = sr.w + SETTINGS_KNOB_R * 2, h = sr.h + SETTINGS_KNOB_R * 2 }
    if point_in_rect(x, y, slider_hit) then
      self.settings_dragging_slider = true
      local pct = math.max(0, math.min(1, (x - sr.x) / sr.w))
      self.settings_volume = pct
      sound.set_master_volume(pct)
      return
    end
    -- Fullscreen toggle
    local row_y = SETTINGS_ROW_Y_START + SETTINGS_ROW_H * 2
    local tog_r = { x = SETTINGS_INPUT_X, y = row_y, w = SETTINGS_TOGGLE_W, h = SETTINGS_TOGGLE_H }
    if point_in_rect(x, y, tog_r) then
      self.settings_fullscreen = not self.settings_fullscreen
      love.window.setFullscreen(self.settings_fullscreen)
      return
    end

  elseif self.screen == "browse" then
    -- Back button
    if point_in_rect(x, y, back_button_rect()) then
      self:go_back()
      return
    end
    -- Host Game button
    local host_btn = {
      x = center_x(BUTTON_W),
      y = 80,
      w = BUTTON_W,
      h = BUTTON_H,
    }
    if point_in_rect(x, y, host_btn) then
      if self._room_fetcher then
        self._room_fetcher:cleanup()
        self._room_fetcher = nil
      end
      self:do_play_online()
      return
    end
    -- Room list join clicks
    local rooms = self._room_fetcher and self._room_fetcher.rooms or {}
    local list_top = 160
    local list_bottom = love.graphics.getHeight() - 40
    local list_x = BROWSE_LIST_X_PAD
    local list_w = love.graphics.getWidth() - BROWSE_LIST_X_PAD * 2
    for i, room in ipairs(rooms) do
      local ry = list_top + (i - 1) * (BROWSE_ROW_H + BROWSE_ROW_PAD) - self.browse_scroll
      if ry + BROWSE_ROW_H >= list_top and ry <= list_bottom then
        local join_x = list_x + list_w - BROWSE_JOIN_W - 12
        local join_y = ry + (BROWSE_ROW_H - BROWSE_JOIN_H) / 2
        if point_in_rect(x, y, { x = join_x, y = join_y, w = BROWSE_JOIN_W, h = BROWSE_JOIN_H }) then
          self:do_browse_join(room.code)
          return
        end
      end
    end

  end
end

function MenuState:mousereleased(x, y, button, istouch, presses)
  if self.settings_dragging_slider then
    self.settings_dragging_slider = false
  end
end

function MenuState:mousemoved(x, y, dx, dy, istouch)
  self.hover_button = nil

  if self.screen == "main" then
    local btns = main_buttons()
    local rects = button_rects(btns)
    for i = 1, #btns do
      if point_in_rect(x, y, rects[i]) then
        self.hover_button = i
        return
      end
    end

  elseif self.screen == "deckbuilder" then
    self.deckbuilder_hover = nil
    if point_in_rect(x, y, back_button_rect()) then
      self.hover_button = -1
      return
    end
    local gw = love.graphics.getWidth()
    local total_w = #DECK_FACTIONS * DECK_CARD_W + (#DECK_FACTIONS - 1) * DECK_CARD_GAP
    local start_x = (gw - total_w) / 2
    local card_y = 140
    for i, fname in ipairs(DECK_FACTIONS) do
      local cx = start_x + (i - 1) * (DECK_CARD_W + DECK_CARD_GAP)
      if point_in_rect(x, y, { x = cx, y = card_y, w = DECK_CARD_W, h = DECK_CARD_H }) then
        self.deckbuilder_hover = i
        self.hover_button = -2
        return
      end
    end

  elseif self.screen == "settings" then
    -- Slider drag
    if self.settings_dragging_slider then
      local sr = self:settings_slider_rect()
      local pct = math.max(0, math.min(1, (x - sr.x) / sr.w))
      self.settings_volume = pct
      sound.set_master_volume(pct)
    end
    -- Back button hover
    if point_in_rect(x, y, back_button_rect()) then
      self.hover_button = -1
      return
    end
    -- Slider/toggle hover for hand cursor
    local sr = self:settings_slider_rect()
    local slider_hit = { x = sr.x - SETTINGS_KNOB_R, y = sr.y - SETTINGS_KNOB_R, w = sr.w + SETTINGS_KNOB_R * 2, h = sr.h + SETTINGS_KNOB_R * 2 }
    if point_in_rect(x, y, slider_hit) then
      self.hover_button = -2
      return
    end
    local row_y = SETTINGS_ROW_Y_START + SETTINGS_ROW_H * 2
    local tog_r = { x = SETTINGS_INPUT_X, y = row_y, w = SETTINGS_TOGGLE_W, h = SETTINGS_TOGGLE_H }
    if point_in_rect(x, y, tog_r) then
      self.hover_button = -2
      return
    end

  elseif self.screen == "browse" then
    self.browse_hover_join = nil
    self.browse_hover_host = false
    if point_in_rect(x, y, back_button_rect()) then
      self.hover_button = -1
      return
    end
    -- Host Game button
    local host_btn = {
      x = center_x(BUTTON_W),
      y = 80,
      w = BUTTON_W,
      h = BUTTON_H,
    }
    if point_in_rect(x, y, host_btn) then
      self.browse_hover_host = true
      self.hover_button = -2  -- set to non-nil so cursor becomes hand
      return
    end
    -- Room list rows
    local rooms = self._room_fetcher and self._room_fetcher.rooms or {}
    local list_top = 160
    local list_bottom = love.graphics.getHeight() - 40
    local list_x = BROWSE_LIST_X_PAD
    local list_w = love.graphics.getWidth() - BROWSE_LIST_X_PAD * 2
    for i, room in ipairs(rooms) do
      local ry = list_top + (i - 1) * (BROWSE_ROW_H + BROWSE_ROW_PAD) - self.browse_scroll
      if ry + BROWSE_ROW_H >= list_top and ry <= list_bottom then
        if point_in_rect(x, y, { x = list_x, y = ry, w = list_w, h = BROWSE_ROW_H }) then
          self.browse_hover_join = i
          self.hover_button = -2
          return
        end
      end
    end

  end
end

function MenuState:keypressed(key, scancode, isrepeat)
  if (self.screen == "browse" or self.screen == "connecting") and key == "escape" then
    self:go_back()
  elseif self.screen == "deckbuilder" and key == "escape" then
    self.screen = "main"
    self.hover_button = nil
  elseif self.screen == "settings" then
    if key == "escape" then
      self:save_settings_and_back()
    elseif key == "backspace" then
      if #self.player_name > 0 then
        self.player_name = self.player_name:sub(1, -2)
      end
    end
  end
end

function MenuState:wheelmoved(x, y)
  if self.screen == "browse" then
    self.browse_scroll = self.browse_scroll - y * 30
    if self.browse_scroll < 0 then self.browse_scroll = 0 end
  end
end

function MenuState:textinput(text)
  if self.screen == "settings" then
    if #self.player_name < 20 then
      self.player_name = self.player_name .. text
    end
  end
end

return MenuState
