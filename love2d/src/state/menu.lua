-- Main menu state: title screen with Local / Host / Join options.
-- Internal state machine: "main", "host_setup", "join_setup", "connecting"

local util = require("src.ui.util")
local runtime_multiplayer = require("src.net.runtime_multiplayer")
local hosted_game = require("src.net.hosted_game")
local websocket_provider = require("src.net.websocket_provider")
local threaded_relay = require("src.net.threaded_relay")
local headless_host_service = require("src.net.headless_host_service")
local authoritative_client_game = require("src.net.authoritative_client_game")
local client_session = require("src.net.client_session")
local websocket_transport = require("src.net.websocket_transport")
local json = require("src.net.json_codec")
local textures = require("src.fx.textures")

local MenuState = {}
MenuState.__index = MenuState

-- Colors
local BG = { 0.08, 0.08, 0.12 }
local GOLD = { 0.92, 0.78, 0.35 }
local WHITE = { 0.92, 0.92, 0.96 }
local DIM = { 0.55, 0.55, 0.65 }
local ERROR_COLOR = { 0.95, 0.35, 0.35 }
local INPUT_BG = { 0.12, 0.12, 0.18 }
local INPUT_BORDER = { 0.3, 0.3, 0.4 }
local INPUT_ACTIVE_BORDER = { 0.5, 0.65, 1.0 }

local BUTTON_COLORS = {
  { 0.22, 0.35, 0.65 },  -- blue  (Local)
  { 0.55, 0.18, 0.18 },  -- red   (Host)
  { 0.18, 0.50, 0.28 },  -- green (Join)
  { 0.15, 0.55, 0.25 },  -- bright green (Play Online)
}
local BUTTON_HOVER = 0.15

local BUTTON_W = 360
local BUTTON_H = 60
local INPUT_W = 400
local INPUT_H = 40

function MenuState.new(callbacks)
  callbacks = callbacks or {}
  local self = setmetatable({
    start_game = callbacks.start_game,
    return_to_menu = callbacks.return_to_menu,

    screen = "main",          -- "main" | "host_setup" | "join_setup" | "connecting"
    hover_button = nil,       -- index of hovered button (1-based)
    cursor_hand = love.mouse.getSystemCursor("hand"),
    current_cursor = "arrow",

    -- Input fields
    player_name = "Player",
    host_port = "12345",
    relay_url = "",           -- empty = LAN mode
    server_url = "wss://bom-hbfv.onrender.com",
    room_code_input = "",     -- join screen: room code for relay
    active_field = "name",    -- "name" | "port" | "relay" | "url" | "room_code"
    cursor_blink = 0,

    -- Host status
    host_status = nil,        -- nil | "listening" | "local_only" | "error"
    host_status_msg = nil,
    host_room_code = nil,     -- room code from relay (displayed on host screen)

    -- Websocket availability
    ws_available = nil,       -- nil = not checked, true/false
    ws_reason = nil,

    -- Connection state
    connect_error = nil,

    -- Threaded relay for Play Online
    _relay = nil,
    _relay_service = nil,
  }, MenuState)
  return self
end

-- Button definitions per screen
local function main_buttons()
  return {
    { label = "Play Online",  color = BUTTON_COLORS[4] },
    { label = "Local Game",   color = BUTTON_COLORS[1] },
    { label = "Host Game",    color = BUTTON_COLORS[2] },
    { label = "Join Game",    color = BUTTON_COLORS[3] },
  }
end

local function host_buttons()
  return {
    { label = "Start Hosting", color = BUTTON_COLORS[2] },
  }
end

local function join_buttons(ws_ok)
  return {
    { label = "Connect", color = BUTTON_COLORS[3], disabled = not ws_ok },
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

local function input_rect(index)
  local gw = love.graphics.getWidth()
  local gh = love.graphics.getHeight()
  local x = (gw - INPUT_W) / 2
  local base_y = gh / 2 - 60
  return {
    x = x,
    y = base_y + (index - 1) * (INPUT_H + 40),
    w = INPUT_W,
    h = INPUT_H,
  }
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

local function draw_input_field(r, label, value, active, cursor_visible)
  local font = util.get_font(14)
  love.graphics.setFont(font)

  -- Label above
  love.graphics.setColor(DIM[1], DIM[2], DIM[3], 1)
  love.graphics.print(label, r.x, r.y - 22)

  -- Background
  love.graphics.setColor(INPUT_BG[1], INPUT_BG[2], INPUT_BG[3], 1)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 6, 6)

  -- Border
  if active then
    love.graphics.setColor(INPUT_ACTIVE_BORDER[1], INPUT_ACTIVE_BORDER[2], INPUT_ACTIVE_BORDER[3], 1)
  else
    love.graphics.setColor(INPUT_BORDER[1], INPUT_BORDER[2], INPUT_BORDER[3], 1)
  end
  love.graphics.setLineWidth(active and 2 or 1)
  love.graphics.rectangle("line", r.x, r.y, r.w, r.h, 6, 6)
  love.graphics.setLineWidth(1)

  -- Text
  love.graphics.setColor(WHITE[1], WHITE[2], WHITE[3], 1)
  local pad = 10
  love.graphics.setScissor(r.x + pad, r.y, r.w - pad * 2, r.h)
  love.graphics.print(value, r.x + pad, r.y + (r.h - font:getHeight()) / 2)
  love.graphics.setScissor()

  -- Blinking cursor
  if active and cursor_visible then
    local text_w = font:getWidth(value)
    local cx = r.x + pad + text_w + 1
    local cy = r.y + 6
    love.graphics.setColor(INPUT_ACTIVE_BORDER[1], INPUT_ACTIVE_BORDER[2], INPUT_ACTIVE_BORDER[3], 1)
    love.graphics.rectangle("fill", cx, cy, 2, r.h - 12)
  end
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

function MenuState:draw_host_setup()
  local gw = love.graphics.getWidth()
  draw_back_button(self.hover_button == -1)

  local title_font = util.get_title_font(32)
  love.graphics.setFont(title_font)
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], 1)
  love.graphics.printf("Host Game", 0, 80, gw, "center")

  local cursor_visible = math.floor(self.cursor_blink * 2) % 2 == 0
  local r1 = input_rect(1)
  local r2 = input_rect(2)
  local r3 = input_rect(3)
  draw_input_field(r1, "Player Name", self.player_name, self.active_field == "name", cursor_visible)
  draw_input_field(r2, "Port (LAN mode)", self.host_port, self.active_field == "port", cursor_visible)
  draw_input_field(r3, "Relay URL (empty = LAN only)", self.relay_url, self.active_field == "relay", cursor_visible)

  -- Host status message
  local status_y = r3.y + r3.h + 8
  if self.host_status_msg then
    local status_font = util.get_font(12)
    love.graphics.setFont(status_font)
    if self.host_status == "error" then
      love.graphics.setColor(ERROR_COLOR[1], ERROR_COLOR[2], ERROR_COLOR[3], 1)
    else
      love.graphics.setColor(0.3, 0.85, 0.4, 1)
    end
    love.graphics.printf(self.host_status_msg, 0, status_y, gw, "center")
    status_y = status_y + 18
  end

  -- Room code display
  if self.host_room_code then
    local code_font = util.get_title_font(28)
    love.graphics.setFont(code_font)
    love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], 1)
    love.graphics.printf("Room Code: " .. self.host_room_code, 0, status_y, gw, "center")
    status_y = status_y + 36
  end

  local btns = host_buttons()
  local rects = button_rects(btns)
  rects[1].y = r3.y + r3.h + 40
  for i, btn in ipairs(btns) do
    draw_button(rects[i], btn.label, btn.color, self.hover_button == i)
  end

  -- Error message
  if self.connect_error then
    love.graphics.setFont(util.get_font(13))
    love.graphics.setColor(ERROR_COLOR[1], ERROR_COLOR[2], ERROR_COLOR[3], 1)
    love.graphics.printf(self.connect_error, center_x(INPUT_W), rects[1].y + rects[1].h + 16, INPUT_W, "center")
  end
end

function MenuState:draw_join_setup()
  local gw = love.graphics.getWidth()
  draw_back_button(self.hover_button == -1)

  local title_font = util.get_title_font(32)
  love.graphics.setFont(title_font)
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], 1)
  love.graphics.printf("Join Game", 0, 80, gw, "center")

  -- Websocket status
  local status_font = util.get_font(12)
  love.graphics.setFont(status_font)
  if self.ws_available == true then
    love.graphics.setColor(0.3, 0.85, 0.4, 1)
    love.graphics.printf("Websocket module available", 0, 120, gw, "center")
  elseif self.ws_available == false then
    love.graphics.setColor(ERROR_COLOR[1], ERROR_COLOR[2], ERROR_COLOR[3], 1)
    love.graphics.printf("Websocket module not found: " .. tostring(self.ws_reason), 0, 120, gw, "center")
  end

  local cursor_visible = math.floor(self.cursor_blink * 2) % 2 == 0
  local r1 = input_rect(1)
  local r2 = input_rect(2)
  local r3 = input_rect(3)
  draw_input_field(r1, "Player Name", self.player_name, self.active_field == "name", cursor_visible)
  draw_input_field(r2, "Server URL (LAN) or Relay URL", self.server_url, self.active_field == "url", cursor_visible)
  draw_input_field(r3, "Room Code (relay only, leave empty for LAN)", self.room_code_input, self.active_field == "room_code", cursor_visible)

  local btns = join_buttons(self.ws_available)
  local rects = button_rects(btns)
  rects[1].y = r3.y + r3.h + 40
  for i, btn in ipairs(btns) do
    draw_button(rects[i], btn.label, btn.color, self.hover_button == i, btn.disabled)
  end

  -- Error message
  if self.connect_error then
    love.graphics.setFont(util.get_font(13))
    love.graphics.setColor(ERROR_COLOR[1], ERROR_COLOR[2], ERROR_COLOR[3], 1)
    love.graphics.printf(self.connect_error, center_x(INPUT_W), rects[1].y + rects[1].h + 16, INPUT_W, "center")
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
    love.graphics.printf(self.connect_error, center_x(INPUT_W), gh / 2 + 20, INPUT_W, "center")
  end
end

function MenuState:draw()
  -- Background
  love.graphics.setColor(BG[1], BG[2], BG[3], 1)
  love.graphics.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())

  if self.screen == "main" then
    self:draw_main()
  elseif self.screen == "host_setup" then
    self:draw_host_setup()
  elseif self.screen == "join_setup" then
    self:draw_join_setup()
  elseif self.screen == "connecting" then
    self:draw_connecting()
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

function MenuState:update(dt)
  self.cursor_blink = self.cursor_blink + dt

  -- Poll threaded relay connection
  self:poll_relay()

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
  self.host_room_code = nil
  self.host_status = nil
  self.host_status_msg = nil
  self.screen = "main"
  self.hover_button = nil
  -- Clean up any in-progress relay connection
  if self._relay then
    self._relay:cleanup()
    self._relay = nil
    self._relay_service = nil
  end
end

-- Get effective player name (default if empty)
function MenuState:get_player_name()
  local name = self.player_name
  if name == "" then name = "Player" end
  return name
end

-- Validate ws:// or wss:// prefix
local function validate_ws_url(url)
  return url:match("^wss?://") ~= nil
end

function MenuState:do_play_online()
  self.screen = "connecting"
  self.connect_error = nil

  -- Start threaded connection (non-blocking)
  self._relay = threaded_relay.start("wss://bom-hbfv.onrender.com")

  -- Create headless host service (local game logic authority)
  self._relay_service = headless_host_service.new({})
  self._relay:attach_service(self._relay_service)
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
    self.connect_error = self._relay.error_msg
    self._relay = nil
    self._relay_service = nil
    self.screen = "main"
  end
end

function MenuState:do_host()
  local name = self:get_player_name()
  local port = tonumber(self.host_port)
  local relay = self.relay_url ~= "" and self.relay_url or nil

  if not relay then
    if not port or port < 1 or port > 65535 then
      self.connect_error = "Invalid port number"
      return
    end
  end

  local ok_call, result = pcall(hosted_game.start, {
    player_name = name,
    port = port,
    relay_url = relay,
  })
  if not ok_call then
    self.connect_error = "Failed to create host: " .. tostring(result)
    return
  end
  if result.ok then
    if result.room_code then
      self.host_status = "listening"
      self.host_status_msg = "Connected to relay (room " .. result.room_code .. ")"
      self.host_room_code = result.room_code
    elseif result.ws_available then
      self.host_status = "listening"
      self.host_status_msg = "Listening on port " .. tostring(result.port) .. " (" .. tostring(result.backend) .. ")"
    else
      self.host_status = "local_only"
      self.host_status_msg = "Websocket server unavailable — local only"
    end
    self.start_game({
      authoritative_adapter = result.adapter,
      server_step = result.step_fn,
      server_cleanup = result.cleanup_fn,
      room_code = result.room_code,
    })
  else
    self.connect_error = "Failed to create host: " .. tostring(result.reason)
  end
end

function MenuState:do_join()
  local url = self.server_url
  local room_code = self.room_code_input:match("^%s*(.-)%s*$")  -- trim

  -- If room code is provided, construct relay join URL
  if room_code ~= "" then
    if not validate_ws_url(url) then
      self.connect_error = "URL must start with ws:// or wss://"
      return
    end
    -- Strip trailing slash and append /join/<CODE>
    local base = url:gsub("/$", "")
    url = base .. "/join/" .. room_code:upper()
  else
    if not validate_ws_url(url) then
      self.connect_error = "URL must start with ws:// or wss://"
      return
    end
  end

  local name = self:get_player_name()

  -- Resolve websocket provider
  local resolved = websocket_provider.resolve()
  if not resolved.ok then
    self.connect_error = "Websocket unavailable: " .. tostring(resolved.reason)
    return
  end

  local ok_call, built = pcall(runtime_multiplayer.build, {
    mode = "websocket",
    url = url,
    player_name = name,
    websocket_provider = resolved.provider,
  })

  if not ok_call then
    self.connect_error = "Connection failed: " .. tostring(built)
    return
  end
  if built.ok then
    self.start_game({ authoritative_adapter = built.adapter })
  else
    self.connect_error = "Connection failed: " .. tostring(built.reason)
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
          -- Play Online
          self:do_play_online()
        elseif i == 2 then
          -- Local Game
          self.start_game({ authoritative_adapter = nil })
        elseif i == 3 then
          -- Host Game
          self.screen = "host_setup"
          self.active_field = "name"
          self.connect_error = nil
        elseif i == 4 then
          -- Join Game
          self.screen = "join_setup"
          self.active_field = "name"
          self.connect_error = nil
          -- Check websocket availability
          local resolved = websocket_provider.resolve()
          self.ws_available = resolved.ok
          self.ws_reason = resolved.reason
        end
        return
      end
    end

  elseif self.screen == "host_setup" then
    -- Back button
    if point_in_rect(x, y, back_button_rect()) then
      self:go_back()
      return
    end
    -- Name input click
    local r1 = input_rect(1)
    if point_in_rect(x, y, r1) then
      self.active_field = "name"
      return
    end
    -- Port input click
    local r2 = input_rect(2)
    if point_in_rect(x, y, r2) then
      self.active_field = "port"
      return
    end
    -- Relay URL input click
    local r3 = input_rect(3)
    if point_in_rect(x, y, r3) then
      self.active_field = "relay"
      return
    end
    -- Start Hosting button
    local btns = host_buttons()
    local rects = button_rects(btns)
    rects[1].y = r3.y + r3.h + 40
    if point_in_rect(x, y, rects[1]) then
      self:do_host()
      return
    end

  elseif self.screen == "join_setup" then
    -- Back button
    if point_in_rect(x, y, back_button_rect()) then
      self:go_back()
      return
    end
    -- Input field clicks
    local r1 = input_rect(1)
    local r2 = input_rect(2)
    local r3 = input_rect(3)
    if point_in_rect(x, y, r1) then
      self.active_field = "name"
      return
    end
    if point_in_rect(x, y, r2) then
      self.active_field = "url"
      return
    end
    if point_in_rect(x, y, r3) then
      self.active_field = "room_code"
      return
    end
    -- Connect button
    local btns = join_buttons(self.ws_available)
    local rects = button_rects(btns)
    rects[1].y = r3.y + r3.h + 40
    if point_in_rect(x, y, rects[1]) and not btns[1].disabled then
      self:do_join()
      return
    end
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

  elseif self.screen == "host_setup" then
    if point_in_rect(x, y, back_button_rect()) then
      self.hover_button = -1
      return
    end
    local r3 = input_rect(3)
    local btns = host_buttons()
    local rects = button_rects(btns)
    rects[1].y = r3.y + r3.h + 40
    for i = 1, #btns do
      if point_in_rect(x, y, rects[i]) then
        self.hover_button = i
        return
      end
    end

  elseif self.screen == "join_setup" then
    if point_in_rect(x, y, back_button_rect()) then
      self.hover_button = -1
      return
    end
    local r3 = input_rect(3)
    local btns = join_buttons(self.ws_available)
    local rects = button_rects(btns)
    rects[1].y = r3.y + r3.h + 40
    for i = 1, #btns do
      if point_in_rect(x, y, rects[i]) and not btns[i].disabled then
        self.hover_button = i
        return
      end
    end
  end
end

function MenuState:keypressed(key, scancode, isrepeat)
  if self.screen ~= "main" and self.screen ~= "connecting" then
    if key == "escape" then
      self:go_back()
      return
    end

    if key == "backspace" then
      if self.active_field == "name" and #self.player_name > 0 then
        self.player_name = self.player_name:sub(1, -2)
      elseif self.active_field == "port" and #self.host_port > 0 then
        self.host_port = self.host_port:sub(1, -2)
      elseif self.active_field == "relay" and #self.relay_url > 0 then
        self.relay_url = self.relay_url:sub(1, -2)
      elseif self.active_field == "url" and #self.server_url > 0 then
        self.server_url = self.server_url:sub(1, -2)
      elseif self.active_field == "room_code" and #self.room_code_input > 0 then
        self.room_code_input = self.room_code_input:sub(1, -2)
      end
      self.cursor_blink = 0
      return
    end

    if key == "tab" then
      if self.screen == "host_setup" then
        local cycle = { name = "port", port = "relay", relay = "name" }
        self.active_field = cycle[self.active_field] or "name"
        self.cursor_blink = 0
      elseif self.screen == "join_setup" then
        local cycle = { name = "url", url = "room_code", room_code = "name" }
        self.active_field = cycle[self.active_field] or "name"
        self.cursor_blink = 0
      end
      return
    end

    if key == "return" or key == "kpenter" then
      if self.screen == "host_setup" then
        self:do_host()
      elseif self.screen == "join_setup" and self.ws_available then
        self:do_join()
      end
      return
    end
  end

  if self.screen == "connecting" and key == "escape" then
    self:go_back()
  end
end

function MenuState:textinput(text)
  if self.screen == "host_setup" or self.screen == "join_setup" then
    if self.active_field == "name" and #self.player_name < 20 then
      self.player_name = self.player_name .. text
    elseif self.active_field == "port" and #self.host_port < 5 then
      -- Only allow digits for port
      if text:match("^%d+$") then
        self.host_port = self.host_port .. text
      end
    elseif self.active_field == "relay" and #self.relay_url < 100 then
      self.relay_url = self.relay_url .. text
    elseif self.active_field == "url" and #self.server_url < 100 then
      self.server_url = self.server_url .. text
    elseif self.active_field == "room_code" and #self.room_code_input < 6 then
      -- Only allow alphanumeric for room codes
      if text:match("^%w+$") then
        self.room_code_input = self.room_code_input .. text:upper()
      end
    end
    self.cursor_blink = 0
  end
end

return MenuState
