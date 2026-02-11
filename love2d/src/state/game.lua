-- In-game screen: game state, board, blueprint modal, drag-drop, End turn button

local game_state_module = require("src.game.state")
local actions = require("src.game.actions")
local board = require("src.ui.board")
local blueprint_modal = require("src.ui.blueprint_modal")
local util = require("src.ui.util")

local GameState = {}
GameState.__index = GameState

function GameState.new()
  local g = game_state_module.create_initial_game_state()
  actions.start_turn(g) -- Player 1's turn starts immediately
  local self = setmetatable({
    game_state = g,
    show_blueprint_for_player = nil, -- 0 or 1 when modal open
    drag = nil, -- { player_index, from } where from = "unassigned" | "left" | "right"
    hover = nil, -- { kind, pi } updated every mousemoved
    mouse_down = false, -- true while left button held
    turn_banner_timer = 0, -- countdown for "Player N's Turn" banner
    turn_banner_text = "",
  }, GameState)
  return self
end

function GameState:update(dt)
  if self.turn_banner_timer > 0 then
    self.turn_banner_timer = self.turn_banner_timer - dt
    if self.turn_banner_timer < 0 then self.turn_banner_timer = 0 end
  end
end

function GameState:draw()
  board.draw(self.game_state, self.drag, self.hover, self.mouse_down)

  -- Dragged worker follows cursor (drawn on top so it's always visible)
  if self.drag then
    local mx, my = love.mouse.getPosition()
    local r = board.WORKER_R
    local drag_r = r * 1.2
    -- Soft shadow (offset) for a lifted look
    love.graphics.setColor(0, 0, 0, 0.45)
    love.graphics.circle("fill", mx + 3, my + 5, drag_r + 3)
    -- Main fill (slightly brighter when dragging)
    love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
    love.graphics.circle("fill", mx, my, drag_r)
    -- Outline
    love.graphics.setColor(0.5, 0.55, 1.0, 1.0)
    love.graphics.setLineWidth(2)
    love.graphics.circle("line", mx, my, drag_r)
    love.graphics.setLineWidth(1)
  end

  if self.show_blueprint_for_player ~= nil then
    blueprint_modal.draw(self.show_blueprint_for_player, self.game_state, self.hover, self.mouse_down)
  else
    -- Turn label (bottom status bar)
    local gw, gh = love.graphics.getDimensions()
    local margin = 20
    local bar_text = "Active: Player " .. (self.game_state.activePlayer + 1) ..
      "  |  Phase: " .. self.game_state.phase ..
      "  |  Turn " .. self.game_state.turnNumber

    -- Contextual hint when hovering
    local hint = nil
    if self.hover then
      if self.hover.kind == "unassigned_pool" or self.hover.kind == "worker_unassigned" then
        hint = "Drag workers to assign them"
      elseif self.hover.kind == "resource_left" or self.hover.kind == "resource_right" then
        hint = "Drop a worker here to gather resources"
      elseif self.hover.kind == "blueprint" then
        hint = "Click to view blueprint deck"
      elseif self.hover.kind == "end_turn" then
        hint = "Click to end your turn"
      elseif self.hover.kind == "activate_base" then
        hint = "Click to activate base ability"
      elseif self.hover.kind == "structure" then
        hint = "Built structure"
      end
    end

    -- Dark pill background for status bar
    local bar_font = util.get_font(13)
    love.graphics.setFont(bar_font)
    local bar_w = bar_font:getWidth(bar_text) + 24
    if hint then
      bar_w = bar_w + bar_font:getWidth("  |  " .. hint) + 0
    end
    local bar_h = 24
    local bar_x = margin - 8
    local bar_y = gh - bar_h - 6
    love.graphics.setColor(0.06, 0.07, 0.1, 0.85)
    love.graphics.rectangle("fill", bar_x, bar_y, bar_w, bar_h, 6, 6)

    love.graphics.setColor(0.7, 0.72, 0.78, 1.0)
    love.graphics.print(bar_text, bar_x + 12, bar_y + 4)
    if hint then
      local main_w = bar_font:getWidth(bar_text)
      love.graphics.setColor(0.5, 0.7, 1.0, 0.9)
      love.graphics.print("  |  " .. hint, bar_x + 12 + main_w, bar_y + 4)
    end
  end

  -- Turn transition banner overlay
  if self.turn_banner_timer > 0 then
    local gw, gh = love.graphics.getDimensions()
    local total_duration = 1.2
    local t = self.turn_banner_timer
    -- Fade in first 0.3s, hold, fade out last 0.3s
    local alpha = 1.0
    local elapsed = total_duration - t
    if elapsed < 0.3 then
      alpha = elapsed / 0.3
    elseif t < 0.3 then
      alpha = t / 0.3
    end
    -- Dark overlay
    love.graphics.setColor(0, 0, 0, 0.5 * alpha)
    love.graphics.rectangle("fill", 0, gh / 2 - 40, gw, 80)
    -- Banner text
    love.graphics.setFont(util.get_font(28))
    love.graphics.setColor(1, 1, 1, alpha)
    love.graphics.printf(self.turn_banner_text, 0, gh / 2 - 16, gw, "center")
  end
end

function GameState:mousepressed(x, y, button, istouch, presses)
  if button ~= 1 then return end -- left click only
  self.mouse_down = true

  if self.show_blueprint_for_player ~= nil then
    -- Try building a card first (only active player's modal)
    if self.show_blueprint_for_player == self.game_state.activePlayer then
      local card_id = blueprint_modal.hit_test_card(x, y)
      if card_id then
        local built = actions.build_structure(self.game_state, self.show_blueprint_for_player, card_id)
        if built then
          self.show_blueprint_for_player = nil
          return
        end
      end
    end
    if blueprint_modal.hit_test_close(x, y) or blueprint_modal.hit_test_backdrop(x, y) then
      self.show_blueprint_for_player = nil
    end
    return
  end

  local kind, pi, idx = board.hit_test(x, y, self.game_state)
  if not kind then return end

  -- End turn: allow either player to click (for testing)
  if kind == "end_turn" then
    actions.end_turn(self.game_state)
    actions.start_turn(self.game_state)
    -- Show turn banner
    self.turn_banner_timer = 1.2
    self.turn_banner_text = "Player " .. (self.game_state.activePlayer + 1) .. "'s Turn"
    return
  end

  if kind == "pass" then
    -- Placeholder for priority passing (no-op for now)
    return
  end

  if kind == "activate_base" and pi == self.game_state.activePlayer then
    actions.activate_base_ability(self.game_state, pi)
    return
  end

  if kind == "blueprint" then
    self.show_blueprint_for_player = pi
    return
  end

  -- Only active player can move workers
  if pi ~= self.game_state.activePlayer then return end

  if kind == "worker_unassigned" or kind == "worker_left" or kind == "worker_right" then
    local from = (kind == "worker_unassigned") and "unassigned" or (kind == "worker_left") and "left" or "right"
    self.drag = { player_index = pi, from = from }
  end
end

function GameState:mousereleased(x, y, button, istouch, presses)
  if button ~= 1 then return end
  self.mouse_down = false

  if self.show_blueprint_for_player ~= nil then return end

  if not self.drag then return end
  local kind, pi, _ = board.hit_test(x, y, self.game_state)
  if not kind or pi ~= self.drag.player_index then
    self.drag = nil
    return
  end

  local from = self.drag.from
  local res_left = (self.game_state.players[pi + 1].faction == "Human") and "wood" or "food"

  -- Drop target (unassigned pool or clicking an unassigned worker = same zone)
  if kind == "unassigned_pool" or kind == "worker_unassigned" then
    if from == "left" then
      actions.unassign_worker_from_resource(self.game_state, pi, res_left)
    elseif from == "right" then
      actions.unassign_worker_from_resource(self.game_state, pi, "stone")
    end
  elseif kind == "resource_left" then
    if from == "unassigned" then
      actions.assign_worker_to_resource(self.game_state, pi, res_left)
    elseif from == "right" then
      actions.unassign_worker_from_resource(self.game_state, pi, "stone")
      actions.assign_worker_to_resource(self.game_state, pi, res_left)
    end
  elseif kind == "resource_right" then
    if from == "unassigned" then
      actions.assign_worker_to_resource(self.game_state, pi, "stone")
    elseif from == "left" then
      actions.unassign_worker_from_resource(self.game_state, pi, res_left)
      actions.assign_worker_to_resource(self.game_state, pi, "stone")
    end
  end

  self.drag = nil
end

function GameState:mousemoved(x, y, dx, dy, istouch)
  -- Update hover state for UI highlights
  local kind, pi, idx = board.hit_test(x, y, self.game_state)
  if kind then
    self.hover = { kind = kind, pi = pi, idx = idx }
  else
    self.hover = nil
  end
end

function GameState:keypressed(key, scancode, isrepeat)
  if key == "escape" and self.show_blueprint_for_player ~= nil then
    self.show_blueprint_for_player = nil
  end
end

return GameState
