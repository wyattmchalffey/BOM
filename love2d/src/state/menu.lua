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
    deckbuilder_total = 0,
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
local DECK_CARD_W = 200
local DECK_CARD_H = 118
local DECK_CARD_GAP = 22
local DECK_CARD_Y = 108
local DECK_LIST_X_PAD = 120
local DECK_LIST_TOP = 340
local DECK_TAB_TOP = DECK_LIST_TOP - 58
local DECK_TAB_H = 26
local DECK_TAB_GAP = 8
local DECK_TAB_WIDTH = 140
local DECK_TAB_DEFS = {
  { id = "main", label = "Main Deck" },
  { id = "blueprints", label = "Blueprints" },
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

function MenuState:deckbuilder_visible_cards()
  local visible = {}
  local want_blueprints = (self.deckbuilder_tab == "blueprints")
  for _, entry in ipairs(self.deckbuilder_cards or {}) do
    local is_blueprint = is_blueprint_entry(entry)
    if (want_blueprints and is_blueprint) or ((not want_blueprints) and (not is_blueprint)) then
      visible[#visible + 1] = entry
    end
  end
  return visible
end

function MenuState:deckbuilder_selector_layout(card_count)
  local gw, gh = love.graphics.getDimensions()
  local list_x = DECK_LIST_X_PAD
  local list_w = gw - DECK_LIST_X_PAD * 2
  local list_top = DECK_LIST_TOP
  local list_bottom = gh - 24
  local list_h = list_bottom - list_top

  local cols = math.max(1, math.floor((list_w + DECK_SELECTOR_COL_GAP) / (DECK_SELECTOR_CARD_W + DECK_SELECTOR_COL_GAP)))
  local grid_w = cols * DECK_SELECTOR_CARD_W + (cols - 1) * DECK_SELECTOR_COL_GAP
  local grid_x = list_x + math.floor((list_w - grid_w) / 2)

  local rows = math.ceil((card_count or 0) / cols)
  local total_h = 0
  if rows > 0 then
    total_h = rows * DECK_SELECTOR_CELL_H + (rows - 1) * DECK_SELECTOR_ROW_GAP
  end
  local max_scroll = math.max(0, total_h - list_h)
  self.deckbuilder_scroll = math.max(0, math.min(self.deckbuilder_scroll or 0, max_scroll))

  return {
    list_x = list_x,
    list_w = list_w,
    list_top = list_top,
    list_bottom = list_bottom,
    list_h = list_h,
    cols = cols,
    grid_x = grid_x,
    total_h = total_h,
    max_scroll = max_scroll,
  }
end

function MenuState:deckbuilder_selector_items(visible_cards)
  local layout = self:deckbuilder_selector_layout(#visible_cards)
  local items = {}
  for i, entry in ipairs(visible_cards) do
    local col = (i - 1) % layout.cols
    local row = math.floor((i - 1) / layout.cols)
    local card_x = layout.grid_x + col * (DECK_SELECTOR_CARD_W + DECK_SELECTOR_COL_GAP)
    local card_y = layout.list_top + row * (DECK_SELECTOR_CELL_H + DECK_SELECTOR_ROW_GAP) - self.deckbuilder_scroll
    local controls_y = card_y + DECK_SELECTOR_CARD_H + DECK_SELECTOR_COUNT_Y_GAP
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
      card_r = { x = card_x, y = card_y, w = DECK_SELECTOR_CARD_W, h = DECK_SELECTOR_CARD_H },
      cell_r = { x = card_x, y = card_y, w = DECK_SELECTOR_CARD_W, h = DECK_SELECTOR_CELL_H },
      minus_r = minus_r,
      plus_r = plus_r,
      count_r = count_r,
    }
  end
  return layout, items
end

local function deckbuilder_tab_rects()
  local rects = {}
  local x = DECK_LIST_X_PAD
  for i, tab in ipairs(DECK_TAB_DEFS) do
    rects[i] = {
      id = tab.id,
      label = tab.label,
      x = x,
      y = DECK_TAB_TOP,
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
  if self.deckbuilder_tab ~= "main" and self.deckbuilder_tab ~= "blueprints" then
    self.deckbuilder_tab = "main"
  end
  local validated = deck_validation.validate_decklist(faction, deck)
  local meta = validated.meta or {}
  self.deckbuilder_total = meta.deck_size or #deck
  self.deckbuilder_min = meta.min_size or 0
  self.deckbuilder_max = meta.max_size
  self.deckbuilder_scroll = 0
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
    self.deckbuilder_error = nil
  else
    self.deckbuilder_total = #deck
    self.deckbuilder_error = saved.reason
  end
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

  -- Faction cards
  local faction_tiles, start_x, card_y = deckbuilder_faction_layout(gw)
  local label_font = util.get_title_font(21)
  local detail_font = util.get_font(13)
  local soon_font = util.get_title_font(16)

  for i, tile in ipairs(faction_tiles) do
    local fdata = factions_data[tile.id]
    local cx = start_x + (i - 1) * (DECK_CARD_W + DECK_CARD_GAP)
    local selected = tile.selectable and (self.deckbuilder_faction == tile.id)
    local hovered = (self.deckbuilder_hover == i)
    local faded = tile.coming_soon

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

  local tab_rects = deckbuilder_tab_rects()
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
    love.graphics.printf(tab.label, tab.x, tab.y + 5, tab.w, "center")
  end

  local info_font = util.get_font(13)
  local status_y = DECK_LIST_TOP - 26
  local tab_label = (self.deckbuilder_tab == "blueprints") and "Blueprints" or "Main Deck"
  local status_text = string.format("Deck Size: %d  |  Viewing: %s", self.deckbuilder_total or 0, tab_label)
  love.graphics.setFont(info_font)
  love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 0.95)
  love.graphics.printf(status_text, DECK_LIST_X_PAD, status_y, gw - DECK_LIST_X_PAD * 2, "left")
  if self.deckbuilder_error then
    love.graphics.setColor(ERROR_COLOR[1], ERROR_COLOR[2], ERROR_COLOR[3], 0.95)
    love.graphics.printf("Deck invalid: " .. tostring(self.deckbuilder_error), DECK_LIST_X_PAD, status_y + 16, gw - DECK_LIST_X_PAD * 2, "left")
  end

  local visible_cards = self:deckbuilder_visible_cards()
  local selector_layout, selector_items = self:deckbuilder_selector_items(visible_cards)
  local count_font = util.get_font(13)
  local btn_font = util.get_title_font(16)

  love.graphics.setScissor(
    selector_layout.list_x,
    selector_layout.list_top,
    selector_layout.list_w,
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
          typeLine = (def.faction or "") .. " - " .. (def.kind or ""),
          text = def.text,
          costs = def.costs,
          upkeep = def.upkeep,
          attack = def.attack,
          health = def.health,
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
  self._room_fetcher = room_list_fetcher.new("https://bom-hbfv.onrender.com/rooms")
end

function MenuState:do_play_online()
  self.screen = "connecting"
  self.connect_error = nil
  self._host_room_code = nil

  -- Start threaded connection (non-blocking)
  self._relay = threaded_relay.start("wss://bom-hbfv.onrender.com", self:get_player_name())

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
    -- Faction cards
    local gw = love.graphics.getWidth()
    local faction_tiles, start_x, card_y = deckbuilder_faction_layout(gw)
    for i, tile in ipairs(faction_tiles) do
      local cx = start_x + (i - 1) * (DECK_CARD_W + DECK_CARD_GAP)
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
    for _, tab in ipairs(deckbuilder_tab_rects()) do
      if point_in_rect(x, y, tab) then
        self.deckbuilder_tab = tab.id
        self.deckbuilder_scroll = 0
        return
      end
    end

    local visible_cards = self:deckbuilder_visible_cards()
    local selector_layout, selector_items = self:deckbuilder_selector_items(visible_cards)
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
    local faction_tiles, start_x, card_y = deckbuilder_faction_layout(gw)
    for i, tile in ipairs(faction_tiles) do
      local cx = start_x + (i - 1) * (DECK_CARD_W + DECK_CARD_GAP)
      if point_in_rect(x, y, { x = cx, y = card_y, w = DECK_CARD_W, h = DECK_CARD_H }) then
        self.deckbuilder_hover = i
        if tile.selectable then
          self.hover_button = -2
        end
        return
      end
    end

    for i, tab in ipairs(deckbuilder_tab_rects()) do
      if point_in_rect(x, y, tab) then
        self.deckbuilder_hover = 400 + i
        self.hover_button = -2
        return
      end
    end

    local visible_cards = self:deckbuilder_visible_cards()
    local selector_layout, selector_items = self:deckbuilder_selector_items(visible_cards)
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
  elseif self.screen == "deckbuilder" then
    local visible_cards = self:deckbuilder_visible_cards()
    local selector_layout = self:deckbuilder_selector_layout(#visible_cards)
    local max_scroll = selector_layout.max_scroll
    self.deckbuilder_scroll = (self.deckbuilder_scroll or 0) - y * 30
    if self.deckbuilder_scroll < 0 then self.deckbuilder_scroll = 0 end
    if self.deckbuilder_scroll > max_scroll then self.deckbuilder_scroll = max_scroll end
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
