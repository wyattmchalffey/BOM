-- Battles of Masadoria — Entry point
-- Delegates load/update/draw/input to current screen state.

local GameState = require("src.state.game")

local current_state

function love.load()
  current_state = GameState.new()
end

function love.update(dt)
  if current_state and current_state.update then
    current_state:update(dt)
  end
end

function love.draw()
  if current_state and current_state.draw then
    current_state:draw()
  end
end

function love.mousepressed(x, y, button, istouch, presses)
  if current_state and current_state.mousepressed then
    current_state:mousepressed(x, y, button, istouch, presses)
  end
end

function love.mousereleased(x, y, button, istouch, presses)
  if current_state and current_state.mousereleased then
    current_state:mousereleased(x, y, button, istouch, presses)
  end
end

function love.mousemoved(x, y, dx, dy, istouch)
  if current_state and current_state.mousemoved then
    current_state:mousemoved(x, y, dx, dy, istouch)
  end
end

function love.keypressed(key, scancode, isrepeat)
  if current_state and current_state.keypressed then
    current_state:keypressed(key, scancode, isrepeat)
  end
end
