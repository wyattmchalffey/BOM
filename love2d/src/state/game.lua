-- In-game screen: game state, board, blueprint modal, drag-drop, End turn button, hand UI

local game_state_module = require("src.game.state")
local commands = require("src.game.commands")
local replay = require("src.game.replay")
local board = require("src.ui.board")
local blueprint_modal = require("src.ui.blueprint_modal")
local deck_viewer = require("src.ui.deck_viewer")
local util = require("src.ui.util")
local tween = require("src.fx.tween")
local popup = require("src.fx.popup")
local shake = require("src.fx.shake")
local sound = require("src.fx.sound")
local cards = require("src.game.cards")
local abilities = require("src.game.abilities")
local card_frame = require("src.ui.card_frame")
local textures = require("src.fx.textures")
local particles = require("src.fx.particles")
local factions_data = require("src.data.factions")
local config = require("src.data.config")
local res_registry = require("src.data.resources")

local GameState = {}
GameState.__index = GameState

function GameState.new(opts)
  opts = opts or {}
  local setup = opts.setup or nil
  if not setup then
    local settings = require("src.settings")
    setup = { players = { [1] = { faction = settings.values.faction } } }
  end
  local initial_state = game_state_module.create_initial_game_state(setup)
  local self = setmetatable({
    game_state = initial_state,
    show_blueprint_for_player = nil, -- 0 or 1 when modal open
    drag = nil, -- { player_index, from } where from = "unassigned" | "left" | "right"
    hover = nil, -- { kind, pi, idx } updated every mousemoved
    mouse_down = false, -- true while left button held
    turn_banner_timer = 0, -- countdown for "Player N's Turn" banner
    turn_banner_text = "",
    -- Feature 1: Display resources (smooth count-up) — copies all resource types
    display_resources = {
      {}, {},
    },
    -- Feature 2: Returning workers (snap-back animation)
    returning_workers = {},  -- { {x, y, target_x, target_y, progress, duration} ... }
    -- Feature 4: Cursor state
    _cursor_hand = nil,  -- cached hand cursor
    _current_cursor = "arrow",
    -- Feature 5: Tooltip hover delay
    tooltip_timer = 0,
    tooltip_target = nil, -- { pi, idx } of structure being hovered
    -- Hand UI state
    hand_hover_index = nil,      -- which hand card the mouse is over (1-based)
    hand_selected_index = nil,   -- which hand card is "selected" (clicked)
    hand_y_offsets = {},          -- per-card animated y offset (negative = raised)
    command_log = replay.new_log({
      command_schema_version = commands.SCHEMA_VERSION,
      rules_version = config.rules_version,
      content_version = config.content_version,
    }), -- deterministic command stream for replay/network migration
    return_to_menu = opts.return_to_menu,
    authoritative_adapter = opts.authoritative_adapter,
    server_step = opts.server_step,         -- optional: pump websocket server each frame
    server_cleanup = opts.server_cleanup,   -- optional: stop server on exit
    room_code = opts.room_code,             -- relay room code (nil for LAN/local)
    multiplayer_error = nil,
    multiplayer_status = nil,
    reconnect_pending = false,
    reconnect_attempts = 0,
    reconnect_timer = 0,
    sync_poll_timer = 0,
    sync_poll_interval = 1.0,
  }, GameState)
  -- Cache the hand cursor once
  self._cursor_hand = love.mouse.getSystemCursor("hand")

  if self.authoritative_adapter then
    print("[multiplayer] attempting adapter:connect()...")
    local connected = self.authoritative_adapter:connect()
    print("[multiplayer] connect result: ok=" .. tostring(connected.ok) .. " reason=" .. tostring(connected.reason))
    if connected.meta then
      for k,v in pairs(connected.meta) do
        print("[multiplayer]   meta." .. tostring(k) .. "=" .. tostring(v))
      end
    end
    if connected.ok then
      self.local_player_index = connected.meta and connected.meta.player_index or 0
      local remote_state = self.authoritative_adapter:get_state()
      if remote_state then
        self.game_state = remote_state
      end
      self.multiplayer_status = "Connected (authoritative)"
    else
      self.multiplayer_error = connected.reason
      self.multiplayer_status = "Multiplayer unavailable: " .. tostring(connected.reason)
      self.authoritative_adapter = nil
    end
  end

  self.local_player_index = self.local_player_index or 0

  if not self.authoritative_adapter then
    self:dispatch_command({ type = "START_TURN", player_index = 0 }) -- Player 1's turn starts immediately
    if not self.multiplayer_status then
      self.multiplayer_status = "Local mode"
    end
  end

  -- Init display_resources from actual values for all resource types
  for pi = 1, 2 do
    for _, key in ipairs(config.resource_types) do
      self.display_resources[pi][key] = self.game_state.players[pi].resources[key] or 0
    end
  end
  -- Init hand y_offsets for local player's starting hand
  for i = 1, #self.game_state.players[self.local_player_index + 1].hand do
    self.hand_y_offsets[i] = 0
  end
  return self
end


function GameState:panel_to_player(panel)
  return self.local_player_index == 0 and panel or (1 - panel)
end

function GameState:player_to_panel(pi)
  return self.local_player_index == 0 and pi or (1 - pi)
end

local function should_trigger_reconnect(reason)
  return reason == "not_connected"
    or reason == "missing_transport"
    or reason == "transport_send_failed"
    or reason == "transport_receive_failed"
    or reason == "transport_decode_failed"
    or reason == "transport_encode_failed"
    or reason == "transport_error"
end

function GameState:_queue_reconnect(reason)
  if not self.authoritative_adapter then return end
  if self.reconnect_pending then return end
  self.reconnect_pending = true
  self.reconnect_attempts = 0
  self.reconnect_timer = 0
  self.multiplayer_error = reason
  self.multiplayer_status = "Reconnecting: " .. tostring(reason)
end

function GameState:_attempt_reconnect()
  if not self.authoritative_adapter then return false end

  local reconnected = self.authoritative_adapter:reconnect()
  if reconnected.ok then
    local remote_state = self.authoritative_adapter:get_state()
    if remote_state then
      self.game_state = remote_state
    end
    self.reconnect_pending = false
    self.reconnect_attempts = 0
    self.reconnect_timer = 0
    self.multiplayer_error = nil
    self.multiplayer_status = "Connected (authoritative)"
    return true
  end

  self.reconnect_attempts = self.reconnect_attempts + 1
  local wait = math.min(6, 0.5 * (2 ^ math.min(self.reconnect_attempts, 4)))
  self.reconnect_timer = wait
  self.multiplayer_error = reconnected.reason
  self.multiplayer_status = "Reconnect failed (retrying): " .. tostring(reconnected.reason)
  return false
end

function GameState:_handle_disconnect(message)
  print("[game] disconnect: " .. tostring(message))
  -- Clean up server if hosting
  if self.server_cleanup then
    pcall(self.server_cleanup)
    self.server_step = nil
    self.server_cleanup = nil
  end
  -- Clean up adapter
  if self.authoritative_adapter and self.authoritative_adapter.cleanup then
    pcall(function() self.authoritative_adapter:cleanup() end)
  end
  self.authoritative_adapter = nil
  self.reconnect_pending = false
  -- Show popup and return to menu after a moment
  self._disconnect_message = message
  self._disconnect_timer = 3.0
end

function GameState:dispatch_command(command)
  -- Don't process commands during disconnect
  if self._disconnect_timer then return { ok = false, reason = "disconnected" } end

  local result

  if self.authoritative_adapter then
    local ok_submit, submit_result = pcall(function() return self.authoritative_adapter:submit(command) end)
    if not ok_submit then
      self:_handle_disconnect("Connection lost")
      return { ok = false, reason = "disconnected" }
    end
    result = submit_result

    if not result.ok and result.reason == "resynced_retry_required" then
      result = self.authoritative_adapter:submit(command)
    end

    if result.ok then
      if self.authoritative_adapter.poll then
        -- Threaded adapter (joiner): apply command locally for instant feedback.
        -- The authoritative state arrives via state_push shortly after.
        result = commands.execute(self.game_state, command)
      else
        -- In-process adapter (host): state is already updated server-side.
        local remote_state = self.authoritative_adapter:get_state()
        if remote_state then
          self.game_state = remote_state
        end
      end
      self.multiplayer_status = "Connected (authoritative)"
    else
      self.multiplayer_status = "Multiplayer warning: " .. tostring(result.reason)
      if should_trigger_reconnect(result.reason) then
        self:_queue_reconnect(result.reason)
      end
    end
  else
    result = commands.execute(self.game_state, command)
  end

  replay.append(self.command_log, command, result, self.game_state)
  if not result.ok then
    sound.play("error")
  end
  return result
end

function GameState:get_command_log_snapshot()
  return replay.snapshot(self.command_log)
end

function GameState:update(dt)
  tween.update(dt)
  popup.update(dt)
  shake.update(dt)
  particles.update(dt)

  -- Smooth glide for dragged worker (Balatro-style)
  if self.drag then
    local mx, my = love.mouse.getPosition()
    local speed = 18
    local t = 1 - math.exp(-dt * speed)
    self.drag.display_x = self.drag.display_x + (mx - self.drag.display_x) * t
    self.drag.display_y = self.drag.display_y + (my - self.drag.display_y) * t
  end

  -- Feature 1: Smooth resource count-up (lerp display toward actual)
  for pi = 1, 2 do
    local dr = self.display_resources[pi]
    local actual = self.game_state.players[pi].resources
    for _, key in ipairs(config.resource_types) do
      local cur = dr[key] or 0
      local target = actual[key] or 0
      local diff = target - cur
      if math.abs(diff) < 0.05 then
        dr[key] = target
      else
        dr[key] = cur + diff * (1 - math.exp(-dt * 12))
      end
    end
  end

  -- Feature 2: Update returning workers
  for i = #self.returning_workers, 1, -1 do
    local rw = self.returning_workers[i]
    rw.progress = rw.progress + dt / rw.duration
    if rw.progress >= 1 then
      table.remove(self.returning_workers, i)
    else
      -- Ease out cubic
      local t = rw.progress
      local eased = 1 - (1 - t) * (1 - t) * (1 - t)
      rw.x = rw.start_x + (rw.target_x - rw.start_x) * eased
      rw.y = rw.start_y + (rw.target_y - rw.start_y) * eased
      rw.alpha = 1 - t * 0.5  -- fade slightly as it returns
      rw.scale = 1.2 - 0.2 * eased  -- shrink back to normal size
    end
  end

  -- Hand card hover animation: smoothly lerp y_offsets toward target
  local hand = self.game_state.players[self.local_player_index + 1].hand
  local hover_rise = board.HAND_HOVER_RISE
  local anim_speed = 14  -- fast, snappy response
  -- Ensure y_offsets array matches hand size
  while #self.hand_y_offsets < #hand do
    self.hand_y_offsets[#self.hand_y_offsets + 1] = 0
  end
  while #self.hand_y_offsets > #hand do
    table.remove(self.hand_y_offsets)
  end
  for i = 1, #hand do
    local target_y = 0
    if i == self.hand_hover_index then
      target_y = -hover_rise  -- rise up
    elseif self.hand_hover_index then
      -- Neighbors rise slightly for a "fan out" feel
      local dist = math.abs(i - self.hand_hover_index)
      if dist == 1 then
        target_y = -hover_rise * 0.15
      end
    end
    local cur = self.hand_y_offsets[i] or 0
    local diff = target_y - cur
    if math.abs(diff) < 0.3 then
      self.hand_y_offsets[i] = target_y
    else
      self.hand_y_offsets[i] = cur + diff * (1 - math.exp(-dt * anim_speed))
    end
  end

  -- Feature 4: Cursor management
  local want_hand = false
  if self.hover and not self.drag then
    local k = self.hover.kind
    if k == "blueprint" or k == "end_turn" or k == "pass" or k == "activate_base"
       or k == "activate_ability" or k == "ability_hover"
       or k == "worker_unassigned" or k == "worker_left" or k == "worker_right"
       or k == "structure" or k == "structure_worker" or k == "hand_card" or k == "unit_deck" then
      want_hand = true
    end
  end
  if self.drag then want_hand = true end
  local desired = want_hand and "hand" or "arrow"
  if desired ~= self._current_cursor then
    if desired == "hand" then
      love.mouse.setCursor(self._cursor_hand)
    else
      love.mouse.setCursor()
    end
    self._current_cursor = desired
  end

  -- Feature 5: Tooltip hover delay (structures + unit deck + ability buttons)
  if self.hover and (self.hover.kind == "structure" or self.hover.kind == "unit_deck"
      or self.hover.kind == "ability_hover" or self.hover.kind == "activate_ability") and not deck_viewer.is_open() then
    local target_key
    if (self.hover.kind == "ability_hover" or self.hover.kind == "activate_ability") and type(self.hover.idx) == "table" then
      local info = self.hover.idx
      target_key = "ability:" .. self.hover.pi .. ":" .. (info.source or "") .. ":" .. (info.board_index or 0) .. ":" .. (info.ability_index or 0)
    else
      target_key = self.hover.kind .. ":" .. self.hover.pi .. ":" .. (self.hover.idx or 0)
    end
    if self.tooltip_target == target_key then
      self.tooltip_timer = self.tooltip_timer + dt
    else
      self.tooltip_target = target_key
      self.tooltip_timer = 0
    end
  else
    self.tooltip_target = nil
    self.tooltip_timer = 0
  end

  -- Poll adapter for push-based state updates (threaded adapters)
  if self.authoritative_adapter and self.authoritative_adapter.poll then
    local ok_poll, poll_err = pcall(function() self.authoritative_adapter:poll() end)
    if not ok_poll then
      print("[game] poll error: " .. tostring(poll_err))
      self:_handle_disconnect("Connection lost")
    elseif self.authoritative_adapter._disconnected then
      self:_handle_disconnect("Opponent disconnected")
    else
      if self.authoritative_adapter.state_changed then
        self.authoritative_adapter.state_changed = false
        local remote_state = self.authoritative_adapter:get_state()
        if remote_state then
          self.game_state = remote_state
        end
      end
    end
  elseif self.authoritative_adapter and not self.reconnect_pending then
    -- Fallback sync poll for in-process adapters (host side)
    self.sync_poll_timer = self.sync_poll_timer - dt
    if self.sync_poll_timer <= 0 then
      self.sync_poll_timer = self.sync_poll_interval
      local ok_sync, snap = pcall(function() return self.authoritative_adapter:sync_snapshot() end)
      if not ok_sync then
        print("[game] sync_snapshot error: " .. tostring(snap))
        self:_handle_disconnect("Connection lost")
      elseif snap.ok then
        local remote_state = self.authoritative_adapter:get_state()
        if remote_state then
          self.game_state = remote_state
        end
      elseif should_trigger_reconnect(snap.reason) then
        self:_queue_reconnect(snap.reason)
      end
    end
  end

  if self.reconnect_pending and self.authoritative_adapter then
    self.reconnect_timer = self.reconnect_timer - dt
    if self.reconnect_timer <= 0 then
      self:_attempt_reconnect()
    end
  end

  -- Disconnect countdown: show message then return to menu
  if self._disconnect_timer then
    self._disconnect_timer = self._disconnect_timer - dt
    if self._disconnect_timer <= 0 then
      self._disconnect_timer = nil
      self._disconnect_message = nil
      if self.return_to_menu then
        self.return_to_menu()
        return
      end
    end
  end

  -- Pump websocket server to accept connections and handle remote frames
  if self.server_step then
    local ok_step, step_err = pcall(self.server_step)
    if not ok_step then
      print("[hosted_game] server step error: " .. tostring(step_err))
    end
  end

  if self.turn_banner_timer > 0 then
    self.turn_banner_timer = self.turn_banner_timer - dt
    if self.turn_banner_timer < 0 then self.turn_banner_timer = 0 end
  end
end

function GameState:draw()
  shake.apply()

  -- Build hand_state for board.draw
  local hand_state = {
    hover_index = self.hand_hover_index,
    selected_index = self.hand_selected_index,
    y_offsets = self.hand_y_offsets,
  }
  board.draw(self.game_state, self.drag, self.hover, self.mouse_down, self.display_resources, hand_state, self.local_player_index)

  -- Ambient particles (drawn on top of panels but below UI overlays)
  local active_player = self.game_state.players[self.game_state.activePlayer + 1]
  local faction_info = factions_data[active_player.faction]
  local accent_color = faction_info and faction_info.color or nil
  particles.draw(accent_color)

  -- Feature 2: Draw returning workers (snap-back animation)
  for _, rw in ipairs(self.returning_workers) do
    local r = board.WORKER_R
    local draw_r = r * (rw.scale or 1)
    local a = rw.alpha or 1
    love.graphics.setColor(0, 0, 0, 0.35 * a)
    love.graphics.circle("fill", rw.x + 2, rw.y + 3, draw_r + 2)
    love.graphics.setColor(0.9, 0.9, 1.0, a)
    love.graphics.circle("fill", rw.x, rw.y, draw_r)
    love.graphics.setColor(0.5, 0.55, 1.0, a * 0.8)
    love.graphics.setLineWidth(1.5)
    love.graphics.circle("line", rw.x, rw.y, draw_r)
    love.graphics.setLineWidth(1)
  end

  -- Dragged worker follows cursor (drawn on top so it's always visible)
  if self.drag then
    local dx, dy = self.drag.display_x, self.drag.display_y
    local r = board.WORKER_R
    local drag_r = r * 1.2
    -- Soft shadow (offset) for a lifted look
    love.graphics.setColor(0, 0, 0, 0.45)
    love.graphics.circle("fill", dx + 3, dy + 5, drag_r + 3)
    -- Main fill (slightly brighter when dragging)
    love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
    love.graphics.circle("fill", dx, dy, drag_r)
    -- Outline
    love.graphics.setColor(0.5, 0.55, 1.0, 1.0)
    love.graphics.setLineWidth(2)
    love.graphics.circle("line", dx, dy, drag_r)
    love.graphics.setLineWidth(1)
  end

  if deck_viewer.is_open() then
    deck_viewer.draw()
  end
  shake.release()

  if not deck_viewer.is_open() then
    popup.draw()

    -- Structure tooltip (Feature 5: only show after 0.3s hover delay)
    if self.hover and self.hover.kind == "structure" and self.tooltip_timer >= 0.3 then
      local pi = self.hover.pi
      local si = self.hover.idx
      local player = self.game_state.players[pi + 1]
      local entry = player and player.board[si]
      if entry then
        local ok, def = pcall(cards.get_card_def, entry.card_id)
        if ok and def then
          local mx, my = love.mouse.getPosition()
          local gw, gh = love.graphics.getDimensions()
          -- Enlarged preview with ability text
          local tw, th = 200, 280
          local n_activated = 0
          if def.abilities then
            for _, ab in ipairs(def.abilities) do
              if ab.type == "activated" then n_activated = n_activated + 1 end
            end
          end
          if n_activated > 0 then th = th + n_activated * 12 end

          local tx = mx + 16
          local ty = my - th / 2
          if tx + tw > gw - 10 then tx = mx - tw - 16 end
          if ty < 10 then ty = 10 end
          if ty + th > gh - 10 then ty = gh - th - 10 end

          -- Build ability state for the tooltip
          local used_abs, can_act_abs = {}, {}
          if def.abilities then
            for ai, ab in ipairs(def.abilities) do
              if ab.type == "activated" then
                local key = tostring(pi) .. ":board:" .. si .. ":" .. ai
                local used = self.game_state.activatedUsedThisTurn and self.game_state.activatedUsedThisTurn[key]
                used_abs[ai] = used or false
                can_act_abs[ai] = (not used or not ab.once_per_turn) and abilities.can_pay_cost(player.resources, ab.cost) and pi == self.game_state.activePlayer
              end
            end
          end

          -- Fade in over 0.15s after the delay
          local fade_in = math.min(1, (self.tooltip_timer - 0.3) / 0.15)
          love.graphics.setColor(0, 0, 0, 0.6 * fade_in)
          love.graphics.rectangle("fill", tx - 4, ty - 4, tw + 8, th + 8, 8, 8)
          love.graphics.push()
          love.graphics.setColor(1, 1, 1, fade_in)
          card_frame.draw(tx, ty, {
            w = tw,
            h = th,
            title = def.name,
            faction = def.faction,
            kind = def.kind,
            typeLine = def.faction .. " — " .. def.kind,
            text = def.text,
            costs = def.costs,
            tier = def.tier,
            abilities_list = def.abilities,
            used_abilities = used_abs,
            can_activate_abilities = can_act_abs,
            show_ability_text = true,
          })
          love.graphics.pop()
        end
      end
    end

    -- Ability button tooltip (compact: effect description + cost + once-per-turn note)
    if self.hover and (self.hover.kind == "ability_hover" or self.hover.kind == "activate_ability")
       and type(self.hover.idx) == "table" and self.tooltip_timer >= 0.3 then
      local pi = self.hover.pi
      local info = self.hover.idx
      local player = self.game_state.players[pi + 1]
      -- Resolve the ability from either a board structure or the base
      local ab = nil
      if player and info.source == "board" then
        local entry = player.board[info.board_index]
        if entry then
          local ok_d, def = pcall(cards.get_card_def, entry.card_id)
          if ok_d and def and def.abilities then
            ab = def.abilities[info.ability_index]
          end
        end
      elseif player and info.source == "base" then
        local ok_d, def = pcall(cards.get_card_def, player.baseId)
        if ok_d and def and def.abilities then
          ab = def.abilities[info.ability_index]
        end
      end
      if ab then
        local mx, my = love.mouse.getPosition()
        local gw, gh = love.graphics.getDimensions()
        local effect_text = card_frame.ability_effect_text(ab)
        local cost_parts = {}
        for _, c in ipairs(ab.cost or {}) do
          local rdef = res_registry[c.type]
          local letter = rdef and rdef.letter or "?"
          cost_parts[#cost_parts + 1] = c.amount .. letter
        end
        local cost_str = #cost_parts > 0 and ("Cost: " .. table.concat(cost_parts, " + ")) or "Free"
        local lines = { effect_text, cost_str }
        if ab.once_per_turn then
          lines[#lines + 1] = "Once per turn"
        end
        local font = util.get_font(10)
        local max_line_w = 0
        for _, line in ipairs(lines) do
          max_line_w = math.max(max_line_w, font:getWidth(line))
        end
        local pad_x, pad_y = 10, 6
        local tw = max_line_w + pad_x * 2
        local line_h = font:getHeight() + 2
        local th = #lines * line_h + pad_y * 2
        local tx = mx + 16
        local ty = my - th - 4
        if tx + tw > gw - 10 then tx = mx - tw - 16 end
        if ty < 10 then ty = 10 end

        local fade_in = math.min(1, (self.tooltip_timer - 0.3) / 0.15)
        -- Dark rounded-rect background
        love.graphics.setColor(0.06, 0.07, 0.1, 0.92 * fade_in)
        love.graphics.rectangle("fill", tx, ty, tw, th, 5, 5)
        love.graphics.setColor(0.3, 0.35, 0.5, 0.5 * fade_in)
        love.graphics.rectangle("line", tx, ty, tw, th, 5, 5)
        -- Lines
        love.graphics.setFont(font)
        for li, line in ipairs(lines) do
          if li == 1 then
            love.graphics.setColor(0.9, 0.92, 1.0, fade_in)
          else
            love.graphics.setColor(0.65, 0.67, 0.75, fade_in)
          end
          love.graphics.print(line, tx + pad_x, ty + pad_y + (li - 1) * line_h)
        end
      end
    end

    -- Unit deck tooltip (shows deck count on hover)
    if self.hover and self.hover.kind == "unit_deck" and self.tooltip_timer >= 0.3 then
      local pi = self.hover.pi
      local player = self.game_state.players[pi + 1]
      if player then
        local deck_count = #(player.deck or {})
        local mx, my = love.mouse.getPosition()
        local gw, gh = love.graphics.getDimensions()
        local label = "Cards in deck: " .. tostring(deck_count)
        local font = util.get_font(11)
        local text_w = font:getWidth(label)
        local pad_x, pad_y = 12, 8
        local tw = text_w + pad_x * 2
        local th = font:getHeight() + pad_y * 2
        local tx = mx + 16
        local ty = my - th - 4
        if tx + tw > gw - 10 then tx = mx - tw - 16 end
        if ty < 10 then ty = 10 end
        -- Fade in over 0.15s after the delay
        local fade_in = math.min(1, (self.tooltip_timer - 0.3) / 0.15)
        love.graphics.setColor(0.08, 0.09, 0.13, 0.92 * fade_in)
        love.graphics.rectangle("fill", tx, ty, tw, th, 6, 6)
        love.graphics.setColor(0.35, 0.37, 0.5, 0.5 * fade_in)
        love.graphics.rectangle("line", tx, ty, tw, th, 6, 6)
        love.graphics.setFont(font)
        love.graphics.setColor(0.85, 0.87, 0.95, fade_in)
        love.graphics.printf(label, tx, ty + pad_y, tw, "center")
      end
    end

    -- (Status bar removed -- player info visible from board layout)
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
    -- Banner text (title font)
    love.graphics.setFont(util.get_title_font(28))
    love.graphics.setColor(1, 1, 1, alpha)
    love.graphics.printf(self.turn_banner_text, 0, gh / 2 - 16, gw, "center")
  end

  -- Disconnect banner overlay
  if self._disconnect_message then
    local gw, gh = love.graphics.getDimensions()
    local alpha = math.min(1, (3.0 - (self._disconnect_timer or 0)) / 0.3)
    -- Dark overlay
    love.graphics.setColor(0, 0, 0, 0.65 * alpha)
    love.graphics.rectangle("fill", 0, gh / 2 - 50, gw, 100)
    -- Red accent line
    love.graphics.setColor(0.8, 0.2, 0.2, 0.8 * alpha)
    love.graphics.rectangle("fill", 0, gh / 2 - 50, gw, 3)
    -- Message
    love.graphics.setFont(util.get_title_font(24))
    love.graphics.setColor(1, 0.3, 0.3, alpha)
    love.graphics.printf(self._disconnect_message, 0, gh / 2 - 20, gw, "center")
    -- Subtitle
    love.graphics.setFont(util.get_font(12))
    love.graphics.setColor(0.7, 0.7, 0.8, alpha * 0.8)
    love.graphics.printf("Returning to menu...", 0, gh / 2 + 14, gw, "center")
  end

  if self.multiplayer_status then
    local status_font = util.get_font(11)
    local status_text = self.multiplayer_status
    if self.room_code then
      status_text = status_text .. "  |  Room: " .. self.room_code
    end
    local text_w = status_font:getWidth(status_text)
    local pad_x, pad_y = 10, 6
    local box_w = math.min(420, text_w + pad_x * 2)
    local box_h = status_font:getHeight() + pad_y * 2
    love.graphics.setColor(0.08, 0.09, 0.13, 0.7)
    love.graphics.rectangle("fill", 12, 12, box_w, box_h, 6, 6)
    love.graphics.setColor(1, 1, 1, 0.92)
    love.graphics.setFont(status_font)
    love.graphics.printf(status_text, 12 + pad_x, 12 + pad_y, box_w - pad_x * 2, "left")
  end

  -- Vignette: drawn last, on top of everything
  textures.draw_vignette()
end

function GameState:mousepressed(x, y, button, istouch, presses)
  if button ~= 1 then return end -- left click only
  self.mouse_down = true

  if deck_viewer.is_open() then
    -- Try building a card if clicking on one in the blueprint viewer
    if self.show_blueprint_for_player ~= nil and self.show_blueprint_for_player == self.game_state.activePlayer then
      local def = deck_viewer.hit_test_card(x, y)
      if def then
        local cfg = deck_viewer.get_config()
        local can_click = cfg and cfg.can_click_fn and cfg.can_click_fn(def)
        if can_click then
          local built_res = self:dispatch_command({
            type = "BUILD_STRUCTURE",
            player_index = self.show_blueprint_for_player,
            card_id = def.id,
          })
          local built = built_res.ok
          if built then
            sound.play("build")
            shake.trigger(3, 0.12)
            local px, py, pw, ph = board.panel_rect(self:player_to_panel(self.show_blueprint_for_player))
            local cost_str = ""
            for _, c in ipairs(def.costs or {}) do
              local rdef = res_registry[c.type]
              local letter = rdef and rdef.letter or "?"
              cost_str = cost_str .. "-" .. c.amount .. letter .. " "
            end
            if cost_str ~= "" then
              popup.create(cost_str, px + pw * 0.5, py + 8, { 1.0, 0.5, 0.25 })
            end
            local sax, say = board.structures_area_rect(px, py, pw, ph)
            local tile_count = #self.game_state.players[self.show_blueprint_for_player + 1].board
            popup.create("Built!", sax + (tile_count - 1) * 98 + 45, say + 20, { 0.4, 0.9, 1.0 })
            local entry = self.game_state.players[self.show_blueprint_for_player + 1].board[tile_count]
            entry.scale = 0
            tween.to(entry, 0.25, { scale = 1 }):ease("backout")
            deck_viewer.close()
            self.show_blueprint_for_player = nil
            return
          else
            sound.play("error")
          end
        else
          sound.play("error")
        end
        return
      end
    end
    -- Let deck_viewer handle close/search/filter/scroll clicks
    local was_open = deck_viewer.is_open()
    deck_viewer.mousepressed(x, y, button)
    if was_open and not deck_viewer.is_open() then
      self.show_blueprint_for_player = nil
    end
    return
  end

  local kind, pi, extra = board.hit_test(x, y, self.game_state, self.hand_y_offsets, self.local_player_index)
  local idx = extra  -- backwards compat: numeric index for hand_card, structure, etc.
  if not kind then
    -- Clicked on empty space: deselect hand card
    if self.hand_selected_index then
      self.hand_selected_index = nil
      sound.play("click")
    end
    return
  end

  -- Hand card click: toggle selection
  if kind == "hand_card" then
    if self.hand_selected_index == idx then
      -- Deselect
      self.hand_selected_index = nil
      sound.play("click")
    else
      -- Select
      self.hand_selected_index = idx
      sound.play("click")
    end
    return
  end

  -- End turn: in multiplayer, only the local player can end their own turn
  if kind == "end_turn" then
    if self.authoritative_adapter and pi ~= self.local_player_index then return end
    if pi ~= self.game_state.activePlayer then return end
    sound.play("whoosh")
    -- Feature 3: Capture resources before/after start_turn for production popups
    local before = {}
    local after = {}
    local new_active
    local p
    if self.authoritative_adapter then
      -- In multiplayer, the host executes START_TURN automatically after END_TURN.
      -- Capture the next player's resources before dispatch.
      local next_pi = 1 - self.game_state.activePlayer
      p = self.game_state.players[next_pi + 1]
      for _, key in ipairs(config.resource_types) do
        before[key] = p.resources[key] or 0
      end
      self:dispatch_command({ type = "END_TURN" })
      -- State now includes START_TURN effects from the host
      new_active = self.game_state.activePlayer
      p = self.game_state.players[new_active + 1]
      for _, key in ipairs(config.resource_types) do
        after[key] = p.resources[key] or 0
      end
    else
      -- Local mode: send END_TURN and START_TURN separately
      self:dispatch_command({ type = "END_TURN" })
      new_active = self.game_state.activePlayer
      p = self.game_state.players[new_active + 1]
      for _, key in ipairs(config.resource_types) do
        before[key] = p.resources[key] or 0
      end
      self:dispatch_command({ type = "START_TURN" })
      for _, key in ipairs(config.resource_types) do
        after[key] = p.resources[key] or 0
      end
    end
    -- Spawn production popups near the resource bar
    local new_panel = self:player_to_panel(new_active)
    local rbx, rby, rbw, rbh = board.resource_bar_rect(new_panel)
    local badge_offset = 0
    for _, key in ipairs(config.resource_types) do
      local gained = after[key] - before[key]
      local rdef = res_registry[key]
      if gained > 0 and rdef then
        local letter = rdef.letter
        local color = rdef.color or {0.3, 0.9, 0.4}
        popup.create("+" .. gained .. letter, rbx + 8 + badge_offset + 25, rby - 4, color, { font_size = 12, lifetime = 1.0, vy = -25 })
        sound.play("coin", 0.4)
      end
      -- Advance offset only for resources the player actually has (matching the badge display)
      if p.resources[key] and p.resources[key] > 0 then
        badge_offset = badge_offset + 54
      end
    end
    -- Clear hand selection on turn change
    self.hand_selected_index = nil
    -- Show turn banner
    self.turn_banner_timer = 1.2
    self.turn_banner_text = (self.game_state.activePlayer == self.local_player_index) and "Your Turn" or "Opponent's Turn"
    return
  end

  if kind == "pass" then
    -- Placeholder for priority passing (no-op for now)
    return
  end

  if kind == "activate_ability" and pi == self.game_state.activePlayer then
    local info = extra  -- { source = "base"|"board", board_index = N, ability_index = N }
    local p = self.game_state.players[pi + 1]
    local card_def
    if info.source == "base" then
      card_def = cards.get_card_def(p.baseId)
    elseif info.source == "board" then
      local entry = p.board[info.board_index]
      if entry then
        card_def = cards.get_card_def(entry.card_id)
      end
    end
    if card_def and card_def.abilities then
      local ab = card_def.abilities[info.ability_index]
      if ab and ab.type == "activated" then
        local before_workers = p.totalWorkers
        local before_res = {}
        for k, v in pairs(p.resources) do before_res[k] = v end

        self:dispatch_command({
          type = "ACTIVATE_ABILITY",
          player_index = pi,
          source = {
            type = info.source,
            index = info.board_index,
          },
          ability_index = info.ability_index,
        })

        -- Visual feedback
        sound.play("coin")
        local pi_panel = self:player_to_panel(pi)
        local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
        -- Show cost deduction popups
        for _, c in ipairs(ab.cost) do
          if before_res[c.type] and p.resources[c.type] < before_res[c.type] then
            local rb_x, rb_y = board.resource_bar_rect(pi_panel)
            popup.create("-" .. c.amount .. string.upper(string.sub(c.type, 1, 1)), rb_x + 25, rb_y - 4, { 1.0, 0.5, 0.25 })
          end
        end
        -- Show effect popup
        if p.totalWorkers > before_workers then
          popup.create("+1 Worker", px_b + pw_b / 2, py_b + ph_b - 80, { 0.3, 0.9, 0.4 })
        end
      end
    end
    return
  end

  -- Legacy compat: activate_base (shouldn't be hit anymore but just in case)
  if kind == "activate_base" and pi == self.game_state.activePlayer then
    local before_workers = self.game_state.players[pi + 1].totalWorkers
    self:dispatch_command({ type = "ACTIVATE_ABILITY", player_index = pi, source = { type = "base" }, ability_index = 1 })
    local after_workers = self.game_state.players[pi + 1].totalWorkers
    if after_workers > before_workers then
      sound.play("coin")
      local ab_panel = self:player_to_panel(pi)
      local px, py, pw, ph = board.panel_rect(ab_panel)
      popup.create("+1 Worker", px + pw / 2, py + ph - 80, { 0.3, 0.9, 0.4 })
      local rb_x, rb_y = board.resource_bar_rect(ab_panel)
      popup.create("-3F", rb_x + 25, rb_y - 4, { 1.0, 0.5, 0.25 })
    end
    return
  end

  if kind == "blueprint" then
    sound.play("click")
    self.show_blueprint_for_player = pi
    blueprint_modal.open(pi, self.game_state)
    return
  end

  -- Only the local player can move workers, and only on their turn
  if self.authoritative_adapter and pi ~= self.local_player_index then return end
  if pi ~= self.game_state.activePlayer then return end

  if kind == "worker_unassigned" or kind == "worker_left" or kind == "worker_right" or kind == "structure_worker" then
    sound.play("pop")
    local from
    if kind == "worker_unassigned" then from = "unassigned"
    elseif kind == "worker_left" then from = "left"
    elseif kind == "worker_right" then from = "right"
    elseif kind == "structure_worker" then from = "structure"
    end
    local mx, my = love.mouse.getPosition()
    self.drag = { player_index = pi, from = from, display_x = mx, display_y = my, board_index = idx }
  end
end

-- Helper: get the origin screen position for a worker based on where it was dragged from
function GameState:_get_worker_origin(pi, from)
  local panel = self:player_to_panel(pi)
  local px, py, pw, ph = board.panel_rect(panel)
  local player = self.game_state.players[pi + 1]
  if from == "unassigned" then
    local uax, uay, uaw, uah = board.unassigned_pool_rect(px, py, pw, ph, player)
    return uax + uaw / 2, uay + uah / 2
  elseif from == "left" then
    local count = player.workersOn[(player.faction == "Human") and "wood" or "food"]
    local cx, cy = board.worker_circle_center(px, py, pw, ph, "left", math.max(1, count), math.max(1, count), panel)
    return cx, cy
  elseif from == "right" then
    local count = player.workersOn.stone
    local cx, cy = board.worker_circle_center(px, py, pw, ph, "right", math.max(1, count), math.max(1, count), panel)
    return cx, cy
  elseif from == "structure" then
    -- Snap back to the structure tile center
    local sax, say, _, _ = board.structures_area_rect(px, py, pw, ph)
    return sax + 45, say + 30
  end
  return px + pw / 2, py + ph / 2
end

-- Spawn a snap-back animation from current drag position to origin
function GameState:_spawn_snap_back()
  if not self.drag then return end
  local origin_x, origin_y = self:_get_worker_origin(self.drag.player_index, self.drag.from)
  self.returning_workers[#self.returning_workers + 1] = {
    x = self.drag.display_x,
    y = self.drag.display_y,
    start_x = self.drag.display_x,
    start_y = self.drag.display_y,
    target_x = origin_x,
    target_y = origin_y,
    progress = 0,
    duration = 0.25,
    alpha = 1,
    scale = 1.2,
  }
end

function GameState:mousereleased(x, y, button, istouch, presses)
  if button ~= 1 then return end
  self.mouse_down = false

  if deck_viewer.is_open() then return end

  if not self.drag then return end
  local kind, pi, drop_extra = board.hit_test(x, y, self.game_state, self.hand_y_offsets, self.local_player_index)

  -- Feature 2: Invalid drop zone -> snap back
  if not kind or pi ~= self.drag.player_index then
    self:_spawn_snap_back()
    self.drag = nil
    return
  end

  local from = self.drag.from
  local res_left = (self.game_state.players[pi + 1].faction == "Human") and "wood" or "food"
  local did_drop = false

  -- Drop target (unassigned pool or clicking an unassigned worker = same zone)
  if kind == "unassigned_pool" or kind == "worker_unassigned" then
    if from == "left" then
      did_drop = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = res_left }).ok
    elseif from == "right" then
      did_drop = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = "stone" }).ok
    elseif from == "structure" then
      did_drop = self:dispatch_command({ type = "UNASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = self.drag.board_index }).ok
    end
  elseif kind == "resource_left" then
    if from == "unassigned" then
      did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = res_left }).ok
    elseif from == "right" then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = "stone" })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = res_left }).ok
      end
    elseif from == "structure" then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = self.drag.board_index })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = res_left }).ok
      end
    end
  elseif kind == "resource_right" then
    if from == "unassigned" then
      did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = "stone" }).ok
    elseif from == "left" then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = res_left })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = "stone" }).ok
      end
    elseif from == "structure" then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = self.drag.board_index })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = "stone" }).ok
      end
    end
  elseif kind == "structure" or kind == "structure_worker" then
    -- Dropping onto a structure tile
    local drop_si = drop_extra
    if from == "unassigned" and drop_si then
      did_drop = self:dispatch_command({ type = "ASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = drop_si }).ok
    elseif from == "left" and drop_si then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = res_left })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = drop_si }).ok
      end
    elseif from == "right" and drop_si then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = "stone" })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = drop_si }).ok
      end
    elseif from == "structure" and drop_si then
      -- Moving worker between structures
      if self.drag.board_index ~= drop_si then
        local unassign_res = self:dispatch_command({ type = "UNASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = self.drag.board_index })
        if unassign_res.ok then
          did_drop = self:dispatch_command({ type = "ASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = drop_si }).ok
        end
      end
    end
  end

  if did_drop then
    sound.play("pop")
  else
    -- Dropped on a non-matching zone (e.g. same zone it came from) -> snap back
    self:_spawn_snap_back()
  end
  self.drag = nil
end

function GameState:mousemoved(x, y, dx, dy, istouch)
  -- Update hover state for UI highlights
  local kind, pi, idx = board.hit_test(x, y, self.game_state, self.hand_y_offsets, self.local_player_index)
  if kind then
    self.hover = { kind = kind, pi = pi, idx = idx }
  else
    self.hover = nil
  end

  -- Track hand hover index for animation
  if kind == "hand_card" then
    self.hand_hover_index = idx
  else
    self.hand_hover_index = nil
  end
end

function GameState:keypressed(key, scancode, isrepeat)
  if deck_viewer.is_open() then
    local was_open = deck_viewer.is_open()
    deck_viewer.keypressed(key)
    if was_open and not deck_viewer.is_open() then
      self.show_blueprint_for_player = nil
    end
    return
  end
  -- Escape to deselect hand card, or return to menu
  if key == "escape" then
    if self.hand_selected_index then
      self.hand_selected_index = nil
      return
    end
    if self.return_to_menu then
      if self.server_cleanup then
        pcall(self.server_cleanup)
        self.server_step = nil
        self.server_cleanup = nil
      end
      self.return_to_menu()
      return
    end
  end
end

function GameState:wheelmoved(dx, dy)
  if deck_viewer.is_open() then
    deck_viewer.wheelmoved(dx, dy)
    return
  end
end

function GameState:textinput(text)
  if deck_viewer.is_open() then
    deck_viewer.textinput(text)
    return
  end
end

return GameState
