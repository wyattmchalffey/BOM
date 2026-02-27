-- Main menu state: title screen with Local / Host / Join options.
-- Internal state machine: "main", "browse", "connecting"

local util = require("src.ui.util")
local card_frame = require("src.ui.card_frame")
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
local cards = require("src.game.cards")
local game_state = require("src.game.state")
local deck_validation = require("src.game.deck_validation")
local deck_profiles = require("src.game.deck_profiles")

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
local DISCORD_INVITE_URL = "https://discord.gg/eSHFbDcXqZ"
local RELAY_HOST = "bom-hbfv.onrender.com"
local RELAY_HTTP_BASE_URL = "https://" .. RELAY_HOST
local RELAY_WS_BASE_URL = "wss://" .. RELAY_HOST
local RELAY_ROOMS_URL = RELAY_HTTP_BASE_URL .. "/rooms"
local DISCORD_BUTTON_HOVER = -3
local DISCORD_BUTTON_SIZE = 56
local DISCORD_BUTTON_PAD = 18
local _discord_icon_image = nil
local _discord_icon_image_loaded = false

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
    deckbuilder_faction = nil,
    deckbuilder_cards = {},
    deckbuilder_counts = {},
    deckbuilder_tab = "main",
    deckbuilder_scroll = 0,
    deckbuilder_dragging_scrollbar = false,
    deckbuilder_scrollbar_drag_offset = 0,
    deckbuilder_search_text = "",
    deckbuilder_search_focused = false,
    deckbuilder_filters = { main = "All", blueprints = "All" },
    deckbuilder_total = 0,
    deckbuilder_main_total = 0,
    deckbuilder_blueprint_total = 0,
    deckbuilder_min = 0,
    deckbuilder_max = nil,
    deckbuilder_error = nil,

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

  deck_profiles.ensure_defaults()
  self.deckbuilder_faction = settings.values.faction
  self:refresh_deckbuilder_state()
  return self
end

-- Button definitions per screen
local function main_buttons()
  return {
    { label = "Play Online",  color = BUTTON_COLORS[1] },
    { label = "Deck Builder", color = { 0.15, 0.35, 0.65 } },
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

local function discord_button_rect()
  local gh = love.graphics.getHeight()
  return {
    x = DISCORD_BUTTON_PAD,
    y = gh - DISCORD_BUTTON_PAD - DISCORD_BUTTON_SIZE,
    w = DISCORD_BUTTON_SIZE,
    h = DISCORD_BUTTON_SIZE,
  }
end

local function get_discord_icon_image()
  if _discord_icon_image_loaded then
    return _discord_icon_image
  end
  _discord_icon_image_loaded = true
  local ok_img, img_or_err = pcall(love.graphics.newImage, "assets/discord.png")
  if ok_img and img_or_err then
    _discord_icon_image = img_or_err
    if _discord_icon_image.setFilter then
      _discord_icon_image:setFilter("linear", "linear")
    end
  else
    _discord_icon_image = nil
  end
  return _discord_icon_image
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

local function draw_discord_icon_button(hovered)
  local r = discord_button_rect()
  local fill = hovered and { 0.28, 0.33, 0.72, 0.98 } or { 0.2, 0.23, 0.36, 0.9 }
  local border = hovered and { 0.78, 0.84, 1.0, 0.95 } or { 1, 1, 1, 0.16 }
  love.graphics.setColor(fill[1], fill[2], fill[3], fill[4])
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 12, 12)
  love.graphics.setColor(border[1], border[2], border[3], border[4])
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", r.x, r.y, r.w, r.h, 12, 12)
  love.graphics.setLineWidth(1)

  local icon = get_discord_icon_image()
  if icon then
    local iw, ih = icon:getDimensions()
    if iw > 0 and ih > 0 then
      local pad = 10
      local scale = math.min((r.w - pad * 2) / iw, (r.h - pad * 2) / ih)
      local dw = iw * scale
      local dh = ih * scale
      local dx = r.x + (r.w - dw) / 2
      local dy = r.y + (r.h - dh) / 2
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.draw(icon, dx, dy, 0, scale, scale)
    end
  else
    love.graphics.setFont(util.get_title_font(22))
    love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 1)
    love.graphics.printf("D", r.x, r.y + 15, r.w, "center")
  end

  if hovered then
    local tip_font = util.get_font(12)
    love.graphics.setFont(tip_font)
    local tip = "Join Discord"
    local tip_w = math.max(90, tip_font:getWidth(tip) + 16)
    local tip_h = tip_font:getHeight() + 8
    local tx = r.x + r.w + 10
    local ty = r.y + r.h - tip_h
    love.graphics.setColor(0.06, 0.07, 0.1, 0.95)
    love.graphics.rectangle("fill", tx, ty, tip_w, tip_h, 6, 6)
    love.graphics.setColor(1, 1, 1, 0.18)
    love.graphics.rectangle("line", tx, ty, tip_w, tip_h, 6, 6)
    love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 0.95)
    love.graphics.printf(tip, tx, ty + 4, tip_w, "center")
  end
end

local function try_open_discord_invite()
  local ok_open, opened_or_err = pcall(function()
    if love.system and love.system.openURL then
      return love.system.openURL(DISCORD_INVITE_URL)
    end
    error("openURL unavailable")
  end)
  if ok_open and opened_or_err ~= false then
    return true, nil
  end
  return false, opened_or_err
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
local DECK_CARD_W = 200
local DECK_CARD_H = 118
local DECK_CARD_GAP = 22
local DECK_CARD_Y = 108
local DECK_FACTION_PRESET_BTN_W = 62
local DECK_FACTION_PRESET_BTN_H = 20
local DECK_FACTION_PRESET_BTN_PAD = 8
local DECK_FACTION_PRESET_HOVER_BASE = 5000
local DECK_LIST_X_PAD = 120
local DECK_TAB_H = 24
local DECK_TAB_GAP = 6
local DECK_TAB_WIDTH = 124
local DECK_TAB_TOP = 252
local DECK_SEARCH_H = 28
local DECK_SEARCH_TOP = DECK_TAB_TOP + DECK_TAB_H + 6
local DECK_FILTER_TOP = DECK_SEARCH_TOP + DECK_SEARCH_H + 6
local DECK_FILTER_H = 22
local DECK_STATUS_TOP = DECK_FILTER_TOP + DECK_FILTER_H + 6
local DECK_LIST_TOP = DECK_STATUS_TOP + 50
local DECK_TAB_DEFS = {
  { id = "main", label = "Main Deck" },
  { id = "blueprints", label = "Blueprints" },
}
local DECK_FILTER_DEFS = {
  main = {
    { id = "All", label = "All" },
    { id = "Unit", label = "Unit" },
    { id = "Worker", label = "Worker" },
    { id = "Spell", label = "Spell" },
    { id = "Technology", label = "Tech" },
    { id = "Item", label = "Item" },
  },
  blueprints = {
    { id = "All", label = "All" },
    { id = "Structure", label = "Structure" },
    { id = "Artifact", label = "Artifact" },
  },
}
local DECK_FACTION_TILES = {
  { id = "Human", label = "Human" },
  { id = "Orc", label = "Orc" },
  { id = "Elf", label = "Elves", coming_soon = true },
  { id = "Gnome", label = "Gnomes", coming_soon = true },
}
local DECK_SELECTOR_CARD_W = card_frame.CARD_W
local DECK_SELECTOR_CARD_H = card_frame.CARD_H
local DECK_SELECTOR_COL_GAP = 14
local DECK_SELECTOR_ROW_GAP = 18
local DECK_SELECTOR_COUNT_Y_GAP = 6
local DECK_SELECTOR_COUNT_H = 24
local DECK_SELECTOR_BTN_W = 28
local DECK_SELECTOR_BTN_H = 22
local DECK_SELECTOR_CELL_H = DECK_SELECTOR_CARD_H + DECK_SELECTOR_COUNT_Y_GAP + DECK_SELECTOR_COUNT_H
local DECK_SELECTOR_SCROLLBAR_W = 12
local DECK_SELECTOR_SCROLLBAR_PAD = 10
local DECK_SELECTOR_SCROLLBAR_MIN_THUMB_H = 28

local function supported_deck_factions()
  local out = game_state.supported_player_factions()
  if #out == 0 then
    out = { settings.values.faction or "Human" }
  end
  return out
end

local function deckbuilder_faction_tiles()
  local supported = game_state.supported_player_faction_set()
  local tiles = {}
  local seen = {}
  for _, spec in ipairs(DECK_FACTION_TILES) do
    local fdata = factions_data[spec.id]
    if fdata then
      local coming_soon = spec.coming_soon == true
      tiles[#tiles + 1] = {
        id = spec.id,
        label = spec.label or spec.id,
        coming_soon = coming_soon,
        selectable = (not coming_soon) and (supported[spec.id] == true),
      }
      seen[spec.id] = true
    end
  end

  -- Keep any additional supported factions visible if they are added later.
  for _, faction in ipairs(supported_deck_factions()) do
    if not seen[faction] then
      tiles[#tiles + 1] = {
        id = faction,
        label = faction,
        coming_soon = false,
        selectable = true,
      }
    end
  end

  return tiles
end

local function deckbuilder_faction_layout(gw)
  local tiles = deckbuilder_faction_tiles()
  local total_w = #tiles * DECK_CARD_W + (#tiles - 1) * DECK_CARD_GAP
  local start_x = (gw - total_w) / 2
  return tiles, start_x, DECK_CARD_Y
end

local function deckbuilder_faction_preset_button_rect(card_x, card_y)
  return {
    x = card_x + DECK_CARD_W - DECK_FACTION_PRESET_BTN_W - DECK_FACTION_PRESET_BTN_PAD,
    y = card_y + DECK_FACTION_PRESET_BTN_PAD,
    w = DECK_FACTION_PRESET_BTN_W,
    h = DECK_FACTION_PRESET_BTN_H,
  }
end

local function safe_card_def(card_id)
  local ok, def = pcall(cards.get_card_def, card_id)
  if ok and type(def) == "table" then
    return def
  end
  return nil
end

local function is_blueprint_entry(entry)
  return entry and (entry.kind == "Structure" or entry.kind == "Artifact")
end

local function clamp_number(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function deckbuilder_count_breakdown(entries, counts)
  local main_total = 0
  local blueprint_total = 0
  for _, entry in ipairs(entries or {}) do
    local count = math.floor(tonumber(type(counts) == "table" and counts[entry.card_id]) or 0)
    if count > 0 then
      if is_blueprint_entry(entry) then
        blueprint_total = blueprint_total + count
      else
        main_total = main_total + count
      end
    end
  end
  return main_total, blueprint_total
end

local function deckbuilder_filter_defs_for_tab(tab_id)
  if tab_id == "blueprints" then
    return DECK_FILTER_DEFS.blueprints or {}
  end
  return DECK_FILTER_DEFS.main or {}
end

local function deckbuilder_filter_id_supported(tab_id, filter_id)
  for _, spec in ipairs(deckbuilder_filter_defs_for_tab(tab_id)) do
    if spec.id == filter_id then
      return true
    end
  end
  return false
end

local function deckbuilder_kind_matches_filter(kind, filter_id)
  if filter_id == nil or filter_id == "All" then
    return true
  end
  kind = tostring(kind or "")
  if kind == filter_id then
    return true
  end
  if filter_id == "Technology" and kind == "Tech" then
    return true
  end
  if filter_id == "Tech" and kind == "Technology" then
    return true
  end
  return false
end

local function deckbuilder_text_matches_search(value, needle_lower)
  if needle_lower == nil or needle_lower == "" then
    return true
  end
  if value == nil then
    return false
  end
  return string.find(string.lower(tostring(value)), needle_lower, 1, true) ~= nil
end

function MenuState:_refresh_deckbuilder_count_totals()
  local main_total, blueprint_total = deckbuilder_count_breakdown(self.deckbuilder_cards, self.deckbuilder_counts)
  self.deckbuilder_main_total = main_total
  self.deckbuilder_blueprint_total = blueprint_total
  self.deckbuilder_total = main_total + blueprint_total
end

function MenuState:_set_deckbuilder_scroll(value, max_scroll)
  max_scroll = math.max(0, tonumber(max_scroll) or 0)
  self.deckbuilder_scroll = clamp_number(tonumber(value) or 0, 0, max_scroll)
end

function MenuState:deckbuilder_search_rect()
  local gw = love.graphics.getWidth()
  return {
    x = DECK_LIST_X_PAD,
    y = DECK_SEARCH_TOP - (self.deckbuilder_scroll or 0),
    w = gw - DECK_LIST_X_PAD * 2,
    h = DECK_SEARCH_H,
  }
end

function MenuState:deckbuilder_filter_tab_rects()
  local rects = {}
  local defs = deckbuilder_filter_defs_for_tab(self.deckbuilder_tab)
  local font = util.get_font(11)
  local x = DECK_LIST_X_PAD
  for i, spec in ipairs(defs) do
    local w = font:getWidth(spec.label) + 16
    rects[i] = {
      index = i,
      id = spec.id,
      label = spec.label,
      x = x,
      y = DECK_FILTER_TOP - (self.deckbuilder_scroll or 0),
      w = w,
      h = DECK_FILTER_H,
    }
    x = x + w + 6
  end
  return rects
end

function MenuState:deckbuilder_scroll_viewport_rect()
  local gw, gh = love.graphics.getDimensions()
  local top = DECK_CARD_Y
  local bottom = gh - 24
  return {
    x = 0,
    y = top,
    w = gw,
    h = math.max(1, bottom - top),
    bottom = bottom,
  }
end

function MenuState:deckbuilder_active_filter_id()
  local tab_id = (self.deckbuilder_tab == "blueprints") and "blueprints" or "main"
  self.deckbuilder_filters = self.deckbuilder_filters or {}
  local filter_id = self.deckbuilder_filters[tab_id]
  if not deckbuilder_filter_id_supported(tab_id, filter_id) then
    filter_id = "All"
    self.deckbuilder_filters[tab_id] = filter_id
  end
  return filter_id
end

function MenuState:_set_deckbuilder_active_filter(filter_id)
  local tab_id = (self.deckbuilder_tab == "blueprints") and "blueprints" or "main"
  if not deckbuilder_filter_id_supported(tab_id, filter_id) then
    filter_id = "All"
  end
  self.deckbuilder_filters = self.deckbuilder_filters or {}
  self.deckbuilder_filters[tab_id] = filter_id
end

function MenuState:deckbuilder_scrollbar_rects(layout)
  if type(layout) ~= "table" or type(layout.scrollbar_track) ~= "table" then
    return nil
  end
  local track = layout.scrollbar_track
  local content_h = math.max(tonumber(layout.content_h) or 0, tonumber(layout.total_h) or 0)
  if layout.max_scroll <= 0 or content_h <= layout.list_h then
    return { track_r = track, thumb_r = nil }
  end

  local visible_ratio = layout.list_h / math.max(content_h, 1)
  local thumb_h = math.floor(math.max(DECK_SELECTOR_SCROLLBAR_MIN_THUMB_H, track.h * visible_ratio))
  if thumb_h > track.h then thumb_h = track.h end
  local travel = math.max(0, track.h - thumb_h)
  local scroll_ratio = (self.deckbuilder_scroll or 0) / math.max(layout.max_scroll, 1)
  local thumb_y = track.y + math.floor(travel * scroll_ratio + 0.5)
  return {
    track_r = track,
    thumb_r = { x = track.x, y = thumb_y, w = track.w, h = thumb_h },
  }
end

function MenuState:_set_deckbuilder_scroll_from_scrollbar_mouse(y, layout, drag_offset)
  local rects = self:deckbuilder_scrollbar_rects(layout)
  if not rects or not rects.thumb_r then
    self:_set_deckbuilder_scroll(0, layout and layout.max_scroll or 0)
    return
  end
  local track = rects.track_r
  local thumb = rects.thumb_r
  local travel = math.max(0, track.h - thumb.h)
  if travel <= 0 then
    self:_set_deckbuilder_scroll(0, layout.max_scroll)
    return
  end
  local top = (tonumber(y) or track.y) - (tonumber(drag_offset) or 0)
  local ratio = (top - track.y) / travel
  ratio = clamp_number(ratio, 0, 1)
  self:_set_deckbuilder_scroll(ratio * layout.max_scroll, layout.max_scroll)
end

function MenuState:deckbuilder_visible_cards()
  local visible = {}
  local want_blueprints = (self.deckbuilder_tab == "blueprints")
  local active_filter = self:deckbuilder_active_filter_id()
  local search_text = tostring(self.deckbuilder_search_text or "")
  local search_lower = string.lower((search_text:gsub("^%s+", ""):gsub("%s+$", "")))
  local use_search = #search_lower > 0
  for _, entry in ipairs(self.deckbuilder_cards or {}) do
    local is_blueprint = is_blueprint_entry(entry)
    local include = (want_blueprints and is_blueprint) or ((not want_blueprints) and (not is_blueprint))
    if include and (active_filter ~= "All") then
      include = deckbuilder_kind_matches_filter(entry.kind, active_filter)
    end
    if include and use_search then
      include = false
      if deckbuilder_text_matches_search(entry.name, search_lower)
        or deckbuilder_text_matches_search(entry.card_id, search_lower)
        or deckbuilder_text_matches_search(entry.kind, search_lower)
      then
        include = true
      else
        local def = safe_card_def(entry.card_id)
        if def then
          if deckbuilder_text_matches_search(def.name, search_lower)
            or deckbuilder_text_matches_search(def.kind, search_lower)
            or deckbuilder_text_matches_search(def.text, search_lower)
          then
            include = true
          elseif type(def.subtypes) == "table" then
            for _, subtype in ipairs(def.subtypes) do
              if deckbuilder_text_matches_search(subtype, search_lower) then
                include = true
                break
              end
            end
          end
        end
      end
    end
    if include then
      visible[#visible + 1] = entry
    end
  end
  return visible
end

function MenuState:deckbuilder_selector_layout(visible_cards)
  local card_count = type(visible_cards) == "number" and visible_cards or #visible_cards
  local gw, gh = love.graphics.getDimensions()
  local viewport_top = DECK_CARD_Y
  local viewport_bottom = gh - 24
  local viewport_h = math.max(1, viewport_bottom - viewport_top)
  local list_x = DECK_LIST_X_PAD
  local list_w = gw - DECK_LIST_X_PAD * 2
  local grid_top = DECK_LIST_TOP + (self.deckbuilder_error and 18 or 0)

  local scrollbar_gutter = DECK_SELECTOR_SCROLLBAR_W + DECK_SELECTOR_SCROLLBAR_PAD
  local content_x = list_x
  local content_w = math.max(DECK_SELECTOR_CARD_W, list_w - scrollbar_gutter)
  local cols = math.max(1, math.floor((content_w + DECK_SELECTOR_COL_GAP) / (DECK_SELECTOR_CARD_W + DECK_SELECTOR_COL_GAP)))
  local grid_w = cols * DECK_SELECTOR_CARD_W + (cols - 1) * DECK_SELECTOR_COL_GAP
  local grid_x = content_x + math.floor((content_w - grid_w) / 2)

  -- Compute per-row max card heights from actual card content
  local rows = math.ceil(card_count / cols)
  local row_heights = {}
  for r = 0, rows - 1 do
    local max_h = DECK_SELECTOR_CARD_H
    for c = 0, cols - 1 do
      local idx = r * cols + c + 1
      if type(visible_cards) == "table" and idx <= #visible_cards then
        local entry = visible_cards[idx]
        local def = safe_card_def(entry.card_id)
        if def then
          local needed = card_frame.measure_full_height({
            w = DECK_SELECTOR_CARD_W, faction = def.faction,
            upkeep = def.upkeep, abilities_list = def.abilities, text = def.text,
          })
          if needed > max_h then max_h = needed end
        end
      end
    end
    row_heights[r + 1] = max_h
  end

  -- Total height using per-row sizes
  local total_h = 0
  for r = 1, rows do
    total_h = total_h + row_heights[r] + DECK_SELECTOR_COUNT_Y_GAP + DECK_SELECTOR_COUNT_H
    if r < rows then total_h = total_h + DECK_SELECTOR_ROW_GAP end
  end

  local content_h = math.max(0, grid_top - viewport_top) + total_h
  local max_scroll = math.max(0, content_h - viewport_h)
  self:_set_deckbuilder_scroll(self.deckbuilder_scroll or 0, max_scroll)

  return {
    list_x = list_x,
    list_w = list_w,
    list_top = viewport_top,
    list_bottom = viewport_bottom,
    list_h = viewport_h,
    viewport_top = viewport_top,
    viewport_bottom = viewport_bottom,
    grid_top = grid_top,
    content_x = content_x,
    content_w = content_w,
    cols = cols,
    grid_x = grid_x,
    total_h = total_h,
    content_h = content_h,
    max_scroll = max_scroll,
    row_heights = row_heights,
    scrollbar_track = {
      x = list_x + list_w - DECK_SELECTOR_SCROLLBAR_W,
      y = viewport_top,
      w = DECK_SELECTOR_SCROLLBAR_W,
      h = viewport_h,
    },
  }
end

function MenuState:deckbuilder_selector_items(visible_cards)
  local layout = self:deckbuilder_selector_layout(visible_cards)
  local items = {}

  -- Compute cumulative y offsets per row
  local row_y = {}
  local cum_y = 0
  for r = 1, #layout.row_heights do
    row_y[r] = cum_y
    local cell_h = layout.row_heights[r] + DECK_SELECTOR_COUNT_Y_GAP + DECK_SELECTOR_COUNT_H
    cum_y = cum_y + cell_h + DECK_SELECTOR_ROW_GAP
  end

  for i, entry in ipairs(visible_cards) do
    local col = (i - 1) % layout.cols
    local row = math.floor((i - 1) / layout.cols) + 1  -- 1-indexed
    local card_h = layout.row_heights[row] or DECK_SELECTOR_CARD_H
    local card_x = layout.grid_x + col * (DECK_SELECTOR_CARD_W + DECK_SELECTOR_COL_GAP)
    local card_y = layout.grid_top + row_y[row] - self.deckbuilder_scroll
    local cell_h = card_h + DECK_SELECTOR_COUNT_Y_GAP + DECK_SELECTOR_COUNT_H
    local controls_y = card_y + card_h + DECK_SELECTOR_COUNT_Y_GAP
    local btn_y = controls_y + math.floor((DECK_SELECTOR_COUNT_H - DECK_SELECTOR_BTN_H) / 2)
    local minus_r = { x = card_x + 12, y = btn_y, w = DECK_SELECTOR_BTN_W, h = DECK_SELECTOR_BTN_H }
    local plus_r = { x = card_x + DECK_SELECTOR_CARD_W - 12 - DECK_SELECTOR_BTN_W, y = btn_y, w = DECK_SELECTOR_BTN_W, h = DECK_SELECTOR_BTN_H }
    local count_r = {
      x = minus_r.x + minus_r.w + 8,
      y = controls_y,
      w = plus_r.x - (minus_r.x + minus_r.w) - 8,
      h = DECK_SELECTOR_COUNT_H,
    }
    items[#items + 1] = {
      index = i,
      entry = entry,
      card_r = { x = card_x, y = card_y, w = DECK_SELECTOR_CARD_W, h = card_h },
      cell_r = { x = card_x, y = card_y, w = DECK_SELECTOR_CARD_W, h = cell_h },
      minus_r = minus_r,
      plus_r = plus_r,
      count_r = count_r,
    }
  end
  return layout, items
end

local function deckbuilder_tab_rects(scroll_y)
  local rects = {}
  local x = DECK_LIST_X_PAD
  local y = DECK_TAB_TOP - (tonumber(scroll_y) or 0)
  for i, tab in ipairs(DECK_TAB_DEFS) do
    rects[i] = {
      id = tab.id,
      label = tab.label,
      x = x,
      y = y,
      w = DECK_TAB_WIDTH,
      h = DECK_TAB_H,
    }
    x = x + DECK_TAB_WIDTH + DECK_TAB_GAP
  end
  return rects
end

function MenuState:refresh_deckbuilder_state()
  local available = supported_deck_factions()
  local faction = self.deckbuilder_faction
  if not game_state.is_supported_player_faction(faction) then
    faction = available[1]
  end
  self.deckbuilder_faction = faction
  settings.values.faction = faction

  self.deckbuilder_cards = deck_validation.deck_entries_for_faction(faction)
  local deck = deck_profiles.get_deck(faction) or {}
  self.deckbuilder_counts = deck_profiles.build_counts(faction, deck)
  self.deckbuilder_filters = self.deckbuilder_filters or { main = "All", blueprints = "All" }
  if not deckbuilder_filter_id_supported("main", self.deckbuilder_filters.main) then
    self.deckbuilder_filters.main = "All"
  end
  if not deckbuilder_filter_id_supported("blueprints", self.deckbuilder_filters.blueprints) then
    self.deckbuilder_filters.blueprints = "All"
  end
  self.deckbuilder_search_text = tostring(self.deckbuilder_search_text or "")
  self.deckbuilder_search_focused = false
  if self.deckbuilder_tab ~= "main" and self.deckbuilder_tab ~= "blueprints" then
    self.deckbuilder_tab = "main"
  end
  local validated = deck_validation.validate_decklist(faction, deck)
  local meta = validated.meta or {}
  self.deckbuilder_total = meta.deck_size or #deck
  self.deckbuilder_min = meta.min_size or 0
  self.deckbuilder_max = meta.max_size
  self.deckbuilder_scroll = 0
  self.deckbuilder_dragging_scrollbar = false
  self.deckbuilder_scrollbar_drag_offset = 0
  self:_refresh_deckbuilder_count_totals()
  self.deckbuilder_error = nil
end

function MenuState:_set_deck_count(card_id, value)
  local count = math.floor(tonumber(value) or 0)
  if count < 0 then count = 0 end

  for _, entry in ipairs(self.deckbuilder_cards) do
    if entry.card_id == card_id then
      if entry.max_copies and count > entry.max_copies then
        count = entry.max_copies
      end
      break
    end
  end

  self.deckbuilder_counts[card_id] = count
  local deck = deck_profiles.build_deck_from_counts(self.deckbuilder_faction, self.deckbuilder_counts)
  local saved = deck_profiles.set_deck(self.deckbuilder_faction, deck)
  if saved.ok then
    self.deckbuilder_total = saved.meta and saved.meta.deck_size or #deck
    self.deckbuilder_min = saved.meta and saved.meta.min_size or self.deckbuilder_min
    self.deckbuilder_max = saved.meta and saved.meta.max_size
    self:_refresh_deckbuilder_count_totals()
    self.deckbuilder_error = nil
  else
    self.deckbuilder_total = #deck
    self:_refresh_deckbuilder_count_totals()
    self.deckbuilder_error = saved.reason
  end
end

function MenuState:_apply_recommended_deck_for_faction(faction)
  local applied = deck_profiles.apply_recommended_deck(faction)
  self.deckbuilder_faction = faction
  settings.values.faction = faction
  self:refresh_deckbuilder_state()
  if applied and applied.ok then
    self.deckbuilder_error = nil
  else
    self.deckbuilder_error = "recommended_" .. tostring(applied and applied.reason or "error")
  end
  settings.save()
  return applied
end

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
  love.graphics.printf("Choose faction and tune card counts", 0, 70, gw, "center")

  local deck_viewport = self:deckbuilder_scroll_viewport_rect()
  love.graphics.setScissor(deck_viewport.x, deck_viewport.y, deck_viewport.w, deck_viewport.h)

  -- Faction cards
  local faction_tiles, start_x, card_y = deckbuilder_faction_layout(gw)
  card_y = card_y - (self.deckbuilder_scroll or 0)
  local label_font = util.get_title_font(21)
  local detail_font = util.get_font(13)
  local soon_font = util.get_title_font(16)
  local preset_font = util.get_font(11)

  for i, tile in ipairs(faction_tiles) do
    local fdata = factions_data[tile.id]
    local cx = start_x + (i - 1) * (DECK_CARD_W + DECK_CARD_GAP)
    local selected = tile.selectable and (self.deckbuilder_faction == tile.id)
    local preset_hovered = (self.deckbuilder_hover == (DECK_FACTION_PRESET_HOVER_BASE + i))
    local hovered = (self.deckbuilder_hover == i) or preset_hovered
    local faded = tile.coming_soon
    local has_recommended = tile.selectable and deck_profiles.has_recommended_deck(tile.id)

    -- Card background
    if selected then
      love.graphics.setColor(fdata.color[1] * 0.35, fdata.color[2] * 0.35, fdata.color[3] * 0.35, 1)
    elseif faded then
      love.graphics.setColor(0.12, 0.12, 0.16, hovered and 0.94 or 0.85)
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
    elseif faded then
      love.graphics.setColor(1, 1, 1, 0.08)
      love.graphics.setLineWidth(2)
    else
      love.graphics.setColor(1, 1, 1, hovered and 0.25 or 0.1)
      love.graphics.setLineWidth(2)
    end
    love.graphics.rectangle("line", cx, card_y, DECK_CARD_W, DECK_CARD_H, 10, 10)
    love.graphics.setLineWidth(1)

    -- Faction name
    love.graphics.setFont(label_font)
    love.graphics.setColor(fdata.color[1], fdata.color[2], fdata.color[3], faded and 0.72 or 1)
    love.graphics.printf(tile.label, cx, card_y + 16, DECK_CARD_W, "center")

    -- Stats
    love.graphics.setFont(detail_font)
    love.graphics.setColor(DIM[1], DIM[2], DIM[3], faded and 0.82 or 1)
    love.graphics.printf("Max Workers: " .. (fdata.default_max_workers or 8), cx, card_y + 49, DECK_CARD_W, "center")

    if tile.selectable then
      local preset_r = deckbuilder_faction_preset_button_rect(cx, card_y)
      if has_recommended then
        if preset_hovered then
          love.graphics.setColor(fdata.color[1] * 0.36, fdata.color[2] * 0.36, fdata.color[3] * 0.36, 0.98)
        else
          love.graphics.setColor(0.09, 0.1, 0.14, 0.92)
        end
      else
        love.graphics.setColor(0.12, 0.12, 0.16, 0.65)
      end
      love.graphics.rectangle("fill", preset_r.x, preset_r.y, preset_r.w, preset_r.h, 5, 5)

      if has_recommended then
        local line_alpha = preset_hovered and 0.95 or 0.65
        love.graphics.setColor(fdata.color[1], fdata.color[2], fdata.color[3], line_alpha)
      else
        love.graphics.setColor(1, 1, 1, 0.12)
      end
      love.graphics.rectangle("line", preset_r.x, preset_r.y, preset_r.w, preset_r.h, 5, 5)

      love.graphics.setFont(preset_font)
      if has_recommended then
        love.graphics.setColor(0.94, 0.95, 0.98, 1)
      else
        love.graphics.setColor(0.55, 0.56, 0.62, 0.85)
      end
      love.graphics.printf("Preset", preset_r.x, preset_r.y + 4, preset_r.w, "center")
    end

    -- Selected indicator
    if selected then
      love.graphics.setFont(detail_font)
      love.graphics.setColor(fdata.color[1], fdata.color[2], fdata.color[3], 0.9)
      love.graphics.printf("Selected", cx, card_y + DECK_CARD_H - 24, DECK_CARD_W, "center")
    elseif tile.coming_soon then
      local badge_w = DECK_CARD_W - 26
      local badge_h = 24
      local badge_x = cx + (DECK_CARD_W - badge_w) / 2
      local badge_y = card_y + DECK_CARD_H - badge_h - 14
      love.graphics.setColor(0.08, 0.08, 0.12, 0.92)
      love.graphics.rectangle("fill", badge_x, badge_y, badge_w, badge_h, 6, 6)
      love.graphics.setColor(0.95, 0.74, 0.36, 0.95)
      love.graphics.rectangle("line", badge_x, badge_y, badge_w, badge_h, 6, 6)
      love.graphics.setFont(soon_font)
      love.graphics.setColor(1, 0.9, 0.78, 1)
      love.graphics.printf("Coming Soon", badge_x, badge_y + 3, badge_w, "center")
    end
  end

  local tab_rects = deckbuilder_tab_rects(self.deckbuilder_scroll or 0)
  local tab_font = util.get_font(12)
  for i, tab in ipairs(tab_rects) do
    local selected = (self.deckbuilder_tab == tab.id)
    local hovered = (self.deckbuilder_hover == (400 + i))
    if selected then
      love.graphics.setColor(0.2, 0.28, 0.42, 0.95)
    elseif hovered then
      love.graphics.setColor(0.18, 0.2, 0.28, 0.9)
    else
      love.graphics.setColor(0.14, 0.15, 0.22, 0.78)
    end
    love.graphics.rectangle("fill", tab.x, tab.y, tab.w, tab.h, 6, 6)
    love.graphics.setColor(selected and 0.5 or 0.25, selected and 0.62 or 0.3, selected and 0.85 or 0.4, selected and 0.9 or 0.5)
    love.graphics.rectangle("line", tab.x, tab.y, tab.w, tab.h, 6, 6)
    love.graphics.setFont(tab_font)
    love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], selected and 1 or 0.85)
    love.graphics.printf(tab.label, tab.x, tab.y + math.floor((tab.h - tab_font:getHeight()) / 2), tab.w, "center")
  end

  local search_r = self:deckbuilder_search_rect()
  local search_hovered = (self.deckbuilder_hover == 600)
  love.graphics.setColor(0.07, 0.08, 0.11, 1)
  love.graphics.rectangle("fill", search_r.x, search_r.y, search_r.w, search_r.h, 5, 5)
  if self.deckbuilder_search_focused then
    love.graphics.setColor(0.35, 0.5, 0.9, 0.75)
  elseif search_hovered then
    love.graphics.setColor(0.28, 0.34, 0.44, 0.95)
  else
    love.graphics.setColor(0.2, 0.22, 0.28, 1)
  end
  love.graphics.rectangle("line", search_r.x, search_r.y, search_r.w, search_r.h, 5, 5)
  local search_label_font = util.get_font(12)
  local search_value_font = util.get_font(13)
  love.graphics.setFont(search_label_font)
  love.graphics.setColor(0.45, 0.47, 0.55, 1)
  love.graphics.print("Search:", search_r.x + 8, search_r.y + 7)
  local search_text_x = search_r.x + 64
  local raw_search = tostring(self.deckbuilder_search_text or "")
  local display_search = raw_search
  love.graphics.setFont(search_value_font)
  if #display_search == 0 and not self.deckbuilder_search_focused then
    love.graphics.setColor(0.4, 0.42, 0.5, 0.7)
    display_search = "Type to filter cards..."
  else
    love.graphics.setColor(0.9, 0.91, 0.95, 1)
  end
  love.graphics.printf(display_search, search_text_x, search_r.y + 7, search_r.w - (search_text_x - search_r.x) - 10, "left")
  if self.deckbuilder_search_focused and (math.floor(self.cursor_blink * 2) % 2 == 0) then
    local cursor_x = search_text_x + search_value_font:getWidth(raw_search)
    local max_cursor_x = search_r.x + search_r.w - 10
    if cursor_x < max_cursor_x then
      love.graphics.setColor(0.8, 0.85, 1, 0.9)
      love.graphics.rectangle("fill", cursor_x + 1, search_r.y + 6, 1, search_r.h - 12)
    end
  end

  local active_filter_id = self:deckbuilder_active_filter_id()
  local filter_font = util.get_font(11)
  for i, fr in ipairs(self:deckbuilder_filter_tab_rects()) do
    local is_active = (fr.id == active_filter_id)
    local is_hovered = (self.deckbuilder_hover == (700 + i))
    if is_active then
      love.graphics.setColor(0.24, 0.34, 0.52, 0.4)
    elseif is_hovered then
      love.graphics.setColor(0.2, 0.22, 0.28, 1)
    else
      love.graphics.setColor(0.12, 0.13, 0.17, 1)
    end
    love.graphics.rectangle("fill", fr.x, fr.y, fr.w, fr.h, 4, 4)
    if is_active then
      love.graphics.setColor(0.5, 0.62, 0.85, 0.8)
    else
      love.graphics.setColor(0.25, 0.27, 0.33, 1)
    end
    love.graphics.rectangle("line", fr.x, fr.y, fr.w, fr.h, 4, 4)
    love.graphics.setFont(filter_font)
    love.graphics.setColor(0.85, 0.86, 0.92, is_active and 1 or 0.75)
    love.graphics.printf(fr.label, fr.x, fr.y + math.floor((fr.h - filter_font:getHeight()) / 2), fr.w, "center")
  end

  local visible_cards = self:deckbuilder_visible_cards()
  local info_font = util.get_font(13)
  local status_y = DECK_STATUS_TOP - (self.deckbuilder_scroll or 0)
  local tab_label = (self.deckbuilder_tab == "blueprints") and "Blueprints" or "Main Deck"
  local counts_text = string.format(
    "Main: %d  |  Blueprints: %d  |  Total: %d",
    self.deckbuilder_main_total or 0,
    self.deckbuilder_blueprint_total or 0,
    self.deckbuilder_total or 0
  )
  local viewing_text = string.format(
    "Viewing: %s  |  Filter: %s  |  Showing: %d cards%s",
    tab_label,
    active_filter_id,
    #visible_cards,
    (#raw_search > 0) and ('  |  Search: "' .. raw_search .. '"') or ""
  )
  love.graphics.setFont(info_font)
  love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 0.95)
  love.graphics.printf(counts_text, DECK_LIST_X_PAD, status_y, gw - DECK_LIST_X_PAD * 2, "left")
  love.graphics.setColor(DIM[1], DIM[2], DIM[3], 0.95)
  love.graphics.printf(viewing_text, DECK_LIST_X_PAD, status_y + 15, gw - DECK_LIST_X_PAD * 2, "left")
  if self.deckbuilder_error then
    love.graphics.setColor(ERROR_COLOR[1], ERROR_COLOR[2], ERROR_COLOR[3], 0.95)
    love.graphics.printf("Deck invalid: " .. tostring(self.deckbuilder_error), DECK_LIST_X_PAD, status_y + 30, gw - DECK_LIST_X_PAD * 2, "left")
  end

  local selector_layout, selector_items = self:deckbuilder_selector_items(visible_cards)
  local count_font = util.get_font(13)
  local btn_font = util.get_title_font(16)

  love.graphics.setScissor(
    selector_layout.content_x,
    selector_layout.list_top,
    selector_layout.content_w,
    selector_layout.list_h
  )
  for _, item in ipairs(selector_items) do
    local cell = item.cell_r
    if cell.y + cell.h >= selector_layout.list_top and cell.y <= selector_layout.list_bottom then
      local entry = item.entry
      local def = safe_card_def(entry.card_id)
      if def then
        card_frame.draw(item.card_r.x, item.card_r.y, {
          w = item.card_r.w,
          h = item.card_r.h,
          title = def.name or entry.name,
          faction = def.faction,
          kind = def.kind,
          subtypes = def.subtypes or {},
          text = def.text,
          costs = def.costs,
          upkeep = def.upkeep,
          attack = def.attack,
          health = def.health or def.baseHealth,
          tier = def.tier,
          abilities_list = def.abilities,
          show_ability_text = true,
        })
      else
        love.graphics.setColor(0.12, 0.12, 0.18, 0.95)
        love.graphics.rectangle("fill", item.card_r.x, item.card_r.y, item.card_r.w, item.card_r.h, 6, 6)
        love.graphics.setColor(1, 1, 1, 0.2)
        love.graphics.rectangle("line", item.card_r.x, item.card_r.y, item.card_r.w, item.card_r.h, 6, 6)
        love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 1)
        love.graphics.setFont(count_font)
        love.graphics.printf(entry.name or entry.card_id, item.card_r.x + 8, item.card_r.y + 10, item.card_r.w - 16, "center")
      end

      if self.deckbuilder_hover == (100 + item.index) then
        love.graphics.setColor(0.25, 0.72, 0.98, 0.55)
        love.graphics.setLineWidth(3)
        love.graphics.rectangle("line", item.card_r.x - 2, item.card_r.y - 2, item.card_r.w + 4, item.card_r.h + 4, 7, 7)
        love.graphics.setLineWidth(1)
      end

      local count = self.deckbuilder_counts[entry.card_id] or 0
      local limit_label = entry.max_copies and tostring(entry.max_copies) or "inf"

      love.graphics.setColor(0.09, 0.1, 0.15, 0.9)
      love.graphics.rectangle("fill", item.count_r.x, item.count_r.y, item.count_r.w, item.count_r.h, 5, 5)
      love.graphics.setColor(1, 1, 1, 0.14)
      love.graphics.rectangle("line", item.count_r.x, item.count_r.y, item.count_r.w, item.count_r.h, 5, 5)

      local minus_hover = self.deckbuilder_hover == (200 + item.index)
      local plus_hover = self.deckbuilder_hover == (300 + item.index)
      love.graphics.setColor(0.2, 0.22, 0.32, minus_hover and 1 or 0.85)
      love.graphics.rectangle("fill", item.minus_r.x, item.minus_r.y, item.minus_r.w, item.minus_r.h, 4, 4)
      love.graphics.setColor(0.2, 0.22, 0.32, plus_hover and 1 or 0.85)
      love.graphics.rectangle("fill", item.plus_r.x, item.plus_r.y, item.plus_r.w, item.plus_r.h, 4, 4)
      love.graphics.setColor(1, 1, 1, 0.12)
      love.graphics.rectangle("line", item.minus_r.x, item.minus_r.y, item.minus_r.w, item.minus_r.h, 4, 4)
      love.graphics.rectangle("line", item.plus_r.x, item.plus_r.y, item.plus_r.w, item.plus_r.h, 4, 4)

      love.graphics.setFont(btn_font)
      love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 0.95)
      love.graphics.printf("-", item.minus_r.x, item.minus_r.y + 1, item.minus_r.w, "center")
      love.graphics.printf("+", item.plus_r.x, item.plus_r.y + 1, item.plus_r.w, "center")

      love.graphics.setFont(count_font)
      love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 1)
      love.graphics.printf(tostring(count) .. " / " .. limit_label, item.count_r.x, item.count_r.y + 4, item.count_r.w, "center")
    end
  end
  love.graphics.setScissor()

  local sb = self:deckbuilder_scrollbar_rects(selector_layout)
  if sb and sb.track_r then
    local track = sb.track_r
    local track_hover = (self.deckbuilder_hover == 500 or self.deckbuilder_hover == 501)
    love.graphics.setColor(0.1, 0.11, 0.16, 0.9)
    love.graphics.rectangle("fill", track.x, track.y, track.w, track.h, 6, 6)
    love.graphics.setColor(1, 1, 1, track_hover and 0.22 or 0.1)
    love.graphics.rectangle("line", track.x, track.y, track.w, track.h, 6, 6)

    if sb.thumb_r then
      local thumb = sb.thumb_r
      local thumb_hover = (self.deckbuilder_hover == 501) or self.deckbuilder_dragging_scrollbar
      if self.deckbuilder_dragging_scrollbar then
        love.graphics.setColor(0.34, 0.74, 0.98, 0.92)
      elseif thumb_hover then
        love.graphics.setColor(0.28, 0.64, 0.9, 0.88)
      else
        love.graphics.setColor(0.22, 0.5, 0.72, 0.78)
      end
      love.graphics.rectangle("fill", thumb.x + 1, thumb.y + 1, thumb.w - 2, thumb.h - 2, 6, 6)
      love.graphics.setColor(1, 1, 1, thumb_hover and 0.28 or 0.14)
      love.graphics.rectangle("line", thumb.x + 1, thumb.y + 1, thumb.w - 2, thumb.h - 2, 6, 6)
    end
  end
end

-- Screen drawing

function MenuState:draw_main()
  local gw = love.graphics.getWidth()
  local title_font = util.get_title_font(48)
  love.graphics.setFont(title_font)
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], 1)
  love.graphics.printf("Siegecraft", 0, 100, gw, "center")

  local subtitle_font = util.get_font(14)
  love.graphics.setFont(subtitle_font)
  love.graphics.setColor(DIM[1], DIM[2], DIM[3], 1)
  love.graphics.printf("A strategic card game of workers and warfare", 0, 155, gw, "center")

  local btns = main_buttons()
  local rects = button_rects(btns)
  for i, btn in ipairs(btns) do
    draw_button(rects[i], btn.label, btn.color, self.hover_button == i)
  end
  draw_discord_icon_button(self.hover_button == DISCORD_BUTTON_HOVER)
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

  draw_back_button(self.hover_button == -1)

  local font = util.get_title_font(24)
  love.graphics.setFont(font)
  love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 1)

  if self._host_room_code then
    -- Host is waiting for opponent
    love.graphics.printf("Waiting for opponent...", 0, gh / 2 - 50, gw, "center")

    local code_font = util.get_title_font(32)
    love.graphics.setFont(code_font)
    love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], 1)
    love.graphics.printf(self._host_room_code, 0, gh / 2, gw, "center")

    love.graphics.setFont(util.get_font(13))
    love.graphics.setColor(DIM[1], DIM[2], DIM[3], 1)
    love.graphics.printf("Share this room code with your opponent", 0, gh / 2 + 45, gw, "center")
  else
    love.graphics.printf("Connecting...", 0, gh / 2 - 20, gw, "center")
  end

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
  self._host_room_code = nil
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
  self._room_fetcher = room_list_fetcher.new(RELAY_ROOMS_URL)
end

function MenuState:do_play_online()
  self.screen = "connecting"
  self.connect_error = nil
  self._host_room_code = nil

  -- Start threaded connection (non-blocking)
  self._relay = threaded_relay.start(RELAY_WS_BASE_URL, self:get_player_name())

  -- Create headless host service with host player pre-registered as player 0
  self._relay_service = headless_host_service.new({
    host_player = {
      name = self:get_player_name(),
      faction = settings.values.faction,
      deck = deck_profiles.get_deck(settings.values.faction),
    },
  })
  self._relay:attach_service(self._relay_service)
end

function MenuState:do_browse_join(room_code)
  local url = RELAY_WS_BASE_URL .. "/join/" .. room_code
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
    faction = settings.values.faction,
    deck = deck_profiles.get_deck(settings.values.faction),
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
    -- Store room code for display
    if not self._host_room_code then
      self._host_room_code = self._relay.room_code
    end

    -- Wait for the game to start (joiner connected and game state created)
    if not self._relay_service:is_game_started() then
      return
    end

    -- Game started! Build in-process adapter for the host player using reconnect.
    local HeadlessFrameClient = {}
    HeadlessFrameClient.__index = HeadlessFrameClient
    function HeadlessFrameClient.new(svc)
      return setmetatable({ service = svc, _last = nil }, HeadlessFrameClient)
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

    -- Use reconnect with the pre-registered host session token
    local session = client_session.new({
      transport = transport,
      player_name = self:get_player_name(),
    })
    session.match_id = self._relay_service:get_match_id()
    session.session_token = self._relay_service:get_host_session_token()
    local reconnect_result = session:reconnect()
    if not reconnect_result.ok then
      self:enter_browse()
      self.connect_error = "Host reconnect failed: " .. tostring(reconnect_result.reason)
      return
    end

    local adapter = authoritative_client_game.new({ session = session })
    local snap = adapter:sync_snapshot()
    if not snap.ok then
      self:enter_browse()
      self.connect_error = "Host snapshot failed: " .. tostring(snap.reason)
      return
    end
    adapter.connected = true

    local relay = self._relay
    local function step_fn()
      relay:poll()
    end
    local function cleanup_fn()
      relay:cleanup()
    end

    self._relay = nil
    self._relay_service = nil
    self._host_room_code = nil

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
    self._host_room_code = nil
    -- Go back to browse screen (re-start fetcher) so user sees the error
    self:enter_browse()
    self.connect_error = err
  end
end

function MenuState:mousepressed(x, y, button, istouch, presses)
  if button ~= 1 then return end

  if self.screen == "main" then
    if point_in_rect(x, y, discord_button_rect()) then
      local ok_open, open_err = try_open_discord_invite()
      if ok_open then
        sound.play("click")
      else
        self.connect_error = "Could not open Discord invite: " .. tostring(open_err)
        sound.play("error")
      end
      return
    end

    local btns = main_buttons()
    local rects = button_rects(btns)
    for i = 1, #btns do
      if point_in_rect(x, y, rects[i]) then
        if i == 1 then
          self:enter_browse()
        elseif i == 2 then
          self.screen = "deckbuilder"
          self:refresh_deckbuilder_state()
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
    local deck_viewport = self:deckbuilder_scroll_viewport_rect()
    if not point_in_rect(x, y, deck_viewport) then
      self.deckbuilder_search_focused = false
      return
    end
    -- Faction cards
    local gw = love.graphics.getWidth()
    local faction_tiles, start_x, card_y = deckbuilder_faction_layout(gw)
    card_y = card_y - (self.deckbuilder_scroll or 0)
    for i, tile in ipairs(faction_tiles) do
      local cx = start_x + (i - 1) * (DECK_CARD_W + DECK_CARD_GAP)
      if tile.selectable and deck_profiles.has_recommended_deck(tile.id) then
        local preset_r = deckbuilder_faction_preset_button_rect(cx, card_y)
        if point_in_rect(x, y, preset_r) then
          self:_apply_recommended_deck_for_faction(tile.id)
          return
        end
      end
      local r = { x = cx, y = card_y, w = DECK_CARD_W, h = DECK_CARD_H }
      if point_in_rect(x, y, r) then
        if tile.selectable then
          settings.values.faction = tile.id
          self.deckbuilder_faction = tile.id
          self:refresh_deckbuilder_state()
          settings.save()
        end
        return
      end
    end

    -- Deck tabs
    for _, tab in ipairs(deckbuilder_tab_rects(self.deckbuilder_scroll or 0)) do
      if point_in_rect(x, y, tab) then
        self.deckbuilder_tab = tab.id
        self.deckbuilder_scroll = 0
        self.deckbuilder_dragging_scrollbar = false
        self.deckbuilder_search_focused = false
        return
      end
    end

    local search_r = self:deckbuilder_search_rect()
    if point_in_rect(x, y, search_r) then
      self.deckbuilder_search_focused = true
      self.deckbuilder_hover = 600
      self.hover_button = -2
      return
    end
    self.deckbuilder_search_focused = false

    for _, fr in ipairs(self:deckbuilder_filter_tab_rects()) do
      if point_in_rect(x, y, fr) then
        self:_set_deckbuilder_active_filter(fr.id)
        self.deckbuilder_scroll = 0
        self.deckbuilder_dragging_scrollbar = false
        return
      end
    end

    local visible_cards = self:deckbuilder_visible_cards()
    local selector_layout, selector_items = self:deckbuilder_selector_items(visible_cards)
    local sb = self:deckbuilder_scrollbar_rects(selector_layout)
    if sb and sb.track_r and point_in_rect(x, y, sb.track_r) then
      if sb.thumb_r and point_in_rect(x, y, sb.thumb_r) then
        self.deckbuilder_dragging_scrollbar = true
        self.deckbuilder_scrollbar_drag_offset = y - sb.thumb_r.y
        self.deckbuilder_hover = 501
        self.hover_button = -2
      elseif sb.thumb_r then
        self:_set_deckbuilder_scroll_from_scrollbar_mouse(y, selector_layout, sb.thumb_r.h / 2)
        local sb_after = self:deckbuilder_scrollbar_rects(selector_layout)
        local thumb_after = sb_after and sb_after.thumb_r or nil
        self.deckbuilder_dragging_scrollbar = thumb_after ~= nil
        self.deckbuilder_scrollbar_drag_offset = thumb_after and (y - thumb_after.y) or 0
        self.deckbuilder_hover = thumb_after and 501 or 500
        self.hover_button = -2
      else
        self.deckbuilder_hover = 500
        self.hover_button = -2
      end
      return
    end
    for _, item in ipairs(selector_items) do
      local cell = item.cell_r
      if cell.y + cell.h >= selector_layout.list_top and cell.y <= selector_layout.list_bottom then
        if point_in_rect(x, y, item.minus_r) then
          local entry = item.entry
          self:_set_deck_count(entry.card_id, (self.deckbuilder_counts[entry.card_id] or 0) - 1)
          return
        end
        if point_in_rect(x, y, item.plus_r) then
          local entry = item.entry
          self:_set_deck_count(entry.card_id, (self.deckbuilder_counts[entry.card_id] or 0) + 1)
          return
        end
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

  elseif self.screen == "connecting" then
    -- Back button
    if point_in_rect(x, y, back_button_rect()) then
      self:go_back()
      return
    end

  end
end

function MenuState:mousereleased(x, y, button, istouch, presses)
  if button == 1 and self.deckbuilder_dragging_scrollbar then
    self.deckbuilder_dragging_scrollbar = false
  end
  if self.settings_dragging_slider then
    self.settings_dragging_slider = false
  end
end

function MenuState:mousemoved(x, y, dx, dy, istouch)
  self.hover_button = nil

  if self.screen == "main" then
    if point_in_rect(x, y, discord_button_rect()) then
      self.hover_button = DISCORD_BUTTON_HOVER
      return
    end
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
    if self.deckbuilder_dragging_scrollbar then
      local visible_cards = self:deckbuilder_visible_cards()
      local selector_layout = self:deckbuilder_selector_layout(visible_cards)
      self:_set_deckbuilder_scroll_from_scrollbar_mouse(y, selector_layout, self.deckbuilder_scrollbar_drag_offset or 0)
      self.deckbuilder_hover = 501
      self.hover_button = -2
      return
    end
    if point_in_rect(x, y, back_button_rect()) then
      self.hover_button = -1
      return
    end
    local deck_viewport = self:deckbuilder_scroll_viewport_rect()
    if not point_in_rect(x, y, deck_viewport) then
      return
    end
    local gw = love.graphics.getWidth()
    local faction_tiles, start_x, card_y = deckbuilder_faction_layout(gw)
    card_y = card_y - (self.deckbuilder_scroll or 0)
    for i, tile in ipairs(faction_tiles) do
      local cx = start_x + (i - 1) * (DECK_CARD_W + DECK_CARD_GAP)
      if tile.selectable and deck_profiles.has_recommended_deck(tile.id) then
        local preset_r = deckbuilder_faction_preset_button_rect(cx, card_y)
        if point_in_rect(x, y, preset_r) then
          self.deckbuilder_hover = DECK_FACTION_PRESET_HOVER_BASE + i
          self.hover_button = -2
          return
        end
      end
      if point_in_rect(x, y, { x = cx, y = card_y, w = DECK_CARD_W, h = DECK_CARD_H }) then
        self.deckbuilder_hover = i
        if tile.selectable then
          self.hover_button = -2
        end
        return
      end
    end

    for i, tab in ipairs(deckbuilder_tab_rects(self.deckbuilder_scroll or 0)) do
      if point_in_rect(x, y, tab) then
        self.deckbuilder_hover = 400 + i
        self.hover_button = -2
        return
      end
    end

    local search_r = self:deckbuilder_search_rect()
    if point_in_rect(x, y, search_r) then
      self.deckbuilder_hover = 600
      self.hover_button = -2
      return
    end

    for i, fr in ipairs(self:deckbuilder_filter_tab_rects()) do
      if point_in_rect(x, y, fr) then
        self.deckbuilder_hover = 700 + i
        self.hover_button = -2
        return
      end
    end

    local visible_cards = self:deckbuilder_visible_cards()
    local selector_layout, selector_items = self:deckbuilder_selector_items(visible_cards)
    local sb = self:deckbuilder_scrollbar_rects(selector_layout)
    if sb and sb.track_r and point_in_rect(x, y, sb.track_r) then
      self.deckbuilder_hover = (sb.thumb_r and point_in_rect(x, y, sb.thumb_r)) and 501 or 500
      self.hover_button = -2
      return
    end
    for _, item in ipairs(selector_items) do
      local cell = item.cell_r
      if cell.y + cell.h >= selector_layout.list_top and cell.y <= selector_layout.list_bottom then
        if point_in_rect(x, y, item.minus_r) then
          self.deckbuilder_hover = 200 + item.index
          self.hover_button = -2
          return
        end
        if point_in_rect(x, y, item.plus_r) then
          self.deckbuilder_hover = 300 + item.index
          self.hover_button = -2
          return
        end
        if point_in_rect(x, y, item.card_r) then
          self.deckbuilder_hover = 100 + item.index
          self.hover_button = -2
          return
        end
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

  elseif self.screen == "connecting" then
    if point_in_rect(x, y, back_button_rect()) then
      self.hover_button = -1
      return
    end

  end
end

function MenuState:keypressed(key, scancode, isrepeat)
  if (self.screen == "browse" or self.screen == "connecting") and key == "escape" then
    self:go_back()
  elseif self.screen == "deckbuilder" then
    if key == "escape" then
      self.deckbuilder_search_focused = false
      self.screen = "main"
      self.hover_button = nil
    elseif self.deckbuilder_search_focused then
      if key == "backspace" then
        if #self.deckbuilder_search_text > 0 then
          self.deckbuilder_search_text = self.deckbuilder_search_text:sub(1, -2)
          self.deckbuilder_scroll = 0
        end
      elseif key == "return" or key == "kpenter" then
        self.deckbuilder_search_focused = false
      end
    end
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
  elseif self.screen == "deckbuilder" then
    local visible_cards = self:deckbuilder_visible_cards()
    local selector_layout = self:deckbuilder_selector_layout(visible_cards)
    local max_scroll = selector_layout.max_scroll
    self:_set_deckbuilder_scroll((self.deckbuilder_scroll or 0) - y * 30, max_scroll)
  end
end

function MenuState:textinput(text)
  if self.screen == "settings" then
    if #self.player_name < 20 then
      self.player_name = self.player_name .. text
    end
  elseif self.screen == "deckbuilder" and self.deckbuilder_search_focused then
    if #self.deckbuilder_search_text < 80 then
      self.deckbuilder_search_text = self.deckbuilder_search_text .. text
      self.deckbuilder_scroll = 0
    end
  end
end

return MenuState
