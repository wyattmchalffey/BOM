-- Battles of Masadoria — Entry point
-- Delegates load/update/draw/input to current screen state.
--
-- Resolution-independent scaling: the entire game operates in a 1280x720
-- logical coordinate space. A global transform scales it up to fill the
-- actual window, with letterboxing if the aspect ratio doesn't match.
-- love.graphics.getWidth/Height and love.mouse.getPosition are overridden
-- so all game code transparently uses logical coordinates.

local GameState = require("src.state.game")
local runtime_multiplayer = require("src.net.runtime_multiplayer")
local websocket_provider = require("src.net.websocket_provider")

local current_state

local function getenv(name)
  if love.system and love.system.getOS then
    -- love.system.getOS guard keeps this path explicit for runtime portability.
  end
  return os.getenv(name)
end

local function build_authoritative_adapter_from_env()
  local mode = getenv("BOM_MULTIPLAYER_MODE")
  local player_name = getenv("BOM_PLAYER_NAME") or "Player"

  if not mode or mode == "" then
    return nil
  end

  local opts = {
    mode = mode,
    player_name = player_name,
    match_id = getenv("BOM_MATCH_ID"),
  }

  if mode == "websocket" then
    opts.url = getenv("BOM_MULTIPLAYER_URL")
    local resolved = websocket_provider.resolve()
    if resolved.ok then
      opts.websocket_provider = resolved.provider
    else
      return nil, resolved.reason
    end
  end

  local built = runtime_multiplayer.build(opts)
  if not built.ok then
    return nil, built.reason
  end

  return built.adapter, nil
end

-- Base (design) resolution — all game code uses these logical dimensions
local BASE_W = 1280
local BASE_H = 720

-- Computed each frame
local ui_scale = 1
local ui_offset_x = 0
local ui_offset_y = 0

-- Keep references to the real (screen-space) functions
local _real_gfx_getWidth = love.graphics.getWidth
local _real_gfx_getHeight = love.graphics.getHeight
local _real_gfx_getDimensions = love.graphics.getDimensions
local _real_mouse_getPosition = love.mouse.getPosition

-- Convert screen coordinates to logical coordinates
local function screen_to_logical(sx, sy)
  return (sx - ui_offset_x) / ui_scale, (sy - ui_offset_y) / ui_scale
end

-- Recompute scale factor
local function update_scale()
  local w, h = _real_gfx_getDimensions()
  ui_scale = math.min(w / BASE_W, h / BASE_H)
  ui_offset_x = (w - BASE_W * ui_scale) / 2
  ui_offset_y = (h - BASE_H * ui_scale) / 2
end

-- Override Love2D functions so all game code uses logical coordinates
love.graphics.getWidth = function() return BASE_W end
love.graphics.getHeight = function() return BASE_H end
love.graphics.getDimensions = function() return BASE_W, BASE_H end
love.mouse.getPosition = function()
  local sx, sy = _real_mouse_getPosition()
  return screen_to_logical(sx, sy)
end

function love.load()
  math.randomseed(os.time())
  local adapter, err = build_authoritative_adapter_from_env()
  current_state = GameState.new({ authoritative_adapter = adapter })
  if err then
    print("[multiplayer] disabled: " .. tostring(err))
  end
  update_scale()
end

function love.resize(w, h)
  update_scale()
end

function love.update(dt)
  if current_state and current_state.update then
    current_state:update(dt)
  end
end

function love.draw()
  update_scale()

  -- Clear letterbox bars to black
  love.graphics.setColor(0, 0, 0, 1)
  love.graphics.rectangle("fill", 0, 0, _real_gfx_getWidth(), _real_gfx_getHeight())

  -- Apply scaling transform: all subsequent drawing uses 1280x720 coordinates
  love.graphics.push()
  love.graphics.translate(ui_offset_x, ui_offset_y)
  love.graphics.scale(ui_scale)

  if current_state and current_state.draw then
    current_state:draw()
  end

  love.graphics.pop()
end

-- All input coordinates are converted to logical space
function love.mousepressed(x, y, button, istouch, presses)
  local lx, ly = screen_to_logical(x, y)
  if current_state and current_state.mousepressed then
    current_state:mousepressed(lx, ly, button, istouch, presses)
  end
end

function love.mousereleased(x, y, button, istouch, presses)
  local lx, ly = screen_to_logical(x, y)
  if current_state and current_state.mousereleased then
    current_state:mousereleased(lx, ly, button, istouch, presses)
  end
end

function love.mousemoved(x, y, dx, dy, istouch)
  local lx, ly = screen_to_logical(x, y)
  local ldx, ldy = dx / ui_scale, dy / ui_scale
  if current_state and current_state.mousemoved then
    current_state:mousemoved(lx, ly, ldx, ldy, istouch)
  end
end

function love.keypressed(key, scancode, isrepeat)
  if current_state and current_state.keypressed then
    current_state:keypressed(key, scancode, isrepeat)
  end
end

function love.wheelmoved(x, y)
  if current_state and current_state.wheelmoved then
    current_state:wheelmoved(x, y)
  end
end

function love.textinput(text)
  if current_state and current_state.textinput then
    current_state:textinput(text)
  end
end
