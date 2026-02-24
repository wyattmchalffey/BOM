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
local unit_stats = require("src.game.unit_stats")
local abilities = require("src.game.abilities")
local card_frame = require("src.ui.card_frame")
local textures = require("src.fx.textures")
local particles = require("src.fx.particles")
local factions_data = require("src.data.factions")
local config = require("src.data.config")
local res_registry = require("src.data.resources")
local deck_profiles = require("src.game.deck_profiles")

local GameState = {}
GameState.__index = GameState

function GameState.new(opts)
  opts = opts or {}
  local setup = opts.setup or nil
  if not setup then
    local settings = require("src.settings")
    setup = {
      players = {
        [1] = {
          faction = settings.values.faction,
          deck = deck_profiles.get_deck(settings.values.faction),
        },
      },
    }
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
    pending_play_unit = nil,      -- { source, ability_index, effect_args, eligible_indices }
    pending_sacrifice = nil,      -- { source, ability_index, effect_args, eligible_board_indices }
    pending_hand_sacrifice = nil, -- { hand_index, required_count, selected_targets }
    pending_monument = nil,        -- { hand_index, min_counters, eligible_indices }
    pending_graveyard_return = nil, -- { source, ability_index, max_count, effect_args, selected_graveyard_indices }
    pending_discard_draw = nil,     -- { source, ability_index, required_count, draw_count, selected_set }
    pending_upgrade = nil, -- { source, ability_index, stage, sacrifice_target, eligible_hand_indices, eligible_board_indices, eligible_worker_sacrifice }
    pending_counter_placement = nil, -- { source, ability_index, eligible_board_indices }
    pending_damage_target = nil,     -- { source, ability_index, effect_args, eligible_player_index, eligible_board_indices }
    pending_damage_x = nil,          -- { source, ability_index, effect_args, eligible_player_index, eligible_board_indices, x_amount, max_x }
    pending_spell_target = nil,      -- { hand_index, effect_args, eligible_player_index, eligible_board_indices, monument_board_index?, via_ability_source?, via_ability_ability_index? }
    pending_play_spell = nil,        -- { source, ability_index, cost, effect_args, eligible_indices }
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
    pending_attack_declarations = {}, -- { { attacker_board_index, target={type="base"|"board", index?} } }
    pending_attack_trigger_targets = {}, -- { { attacker_board_index, ability_index, target_board_index?, activate? } }
    pending_block_assignments = {}, -- { { blocker_board_index, attacker_board_index } }
    pending_damage_orders = {}, -- map attacker_board_index -> ordered blocker board indices
    sync_poll_timer = 0,
    sync_poll_interval = 1.0,
    _terminal_announced = false,
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
      self.multiplayer_status = "Connected"
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
  if type(reason) ~= "string" then
    return false
  end

  if reason == "not_connected"
    or reason == "missing_transport"
    or reason == "transport_send_failed"
    or reason == "transport_receive_failed"
    or reason == "transport_decode_failed"
    or reason == "transport_encode_failed"
    or reason == "transport_error"
    or reason == "transport_timeout"
    or reason == "transport_no_protocol_response"
    or reason == "thread_stopped"
  then
    return true
  end

  local lowered = string.lower(reason)
  if lowered:find("transport_", 1, true) then return true end
  if lowered:find("receive_error", 1, true) then return true end
  if lowered:find("connection lost", 1, true) then return true end
  if lowered:find("ws_connect_failed", 1, true) then return true end
  if lowered:find("thread error", 1, true) then return true end
  return false
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
  if self.authoritative_adapter.connected then
    local remote_state = self.authoritative_adapter:get_state()
    if remote_state then
      self.game_state = remote_state
    end
    self.reconnect_pending = false
    self.reconnect_attempts = 0
    self.reconnect_timer = 0
    self.multiplayer_error = nil
    self.multiplayer_status = "Connected"
    return true
  end

  local ok_reconnect, reconnected = pcall(function()
    return self.authoritative_adapter:reconnect()
  end)
  if not ok_reconnect then
    reconnected = { ok = false, reason = tostring(reconnected), meta = {} }
  end

  if reconnected.ok then
    if reconnected.meta and reconnected.meta.pending then
      self.reconnect_timer = 0.25
      self.multiplayer_status = "Reconnecting..."
      return false
    end

    local remote_state = self.authoritative_adapter:get_state()
    if remote_state then
      self.game_state = remote_state
    end
    self.reconnect_pending = false
    self.reconnect_attempts = 0
    self.reconnect_timer = 0
    self.multiplayer_error = nil
    self.multiplayer_status = "Connected"
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

local function terminal_title_for_player(g, local_player_index)
  if not g or not g.is_terminal then
    return nil
  end
  if g.winner == nil then
    return "Draw"
  end
  if g.winner == local_player_index then
    return "Victory"
  end
  return "Defeat"
end

local function graveyard_cards_for_player(player)
  local out = {}
  if not player or type(player.graveyard) ~= "table" then
    return out
  end

  -- Show newest cards first.
  for i = #player.graveyard, 1, -1 do
    local entry = player.graveyard[i]
    local card_id = (type(entry) == "table") and entry.card_id or entry
    if type(card_id) == "string" and card_id ~= "" then
      local ok_def, def = pcall(cards.get_card_def, card_id)
      if ok_def and def then
        out[#out + 1] = def
      end
    end
  end

  return out
end

-- Build the graveyard card list for selection mode (newest-first, includes graveyard_index metadata).
-- Only includes cards matching the return_from_graveyard effect_args filter.
local function graveyard_cards_for_selection(player, effect_args)
  local args = effect_args or {}
  local req_tier = args.tier
  local req_subtypes = args.subtypes
  local out = {}
  if not player or type(player.graveyard) ~= "table" then return out end

  for i = #player.graveyard, 1, -1 do
    local entry = player.graveyard[i]
    local card_id = (type(entry) == "table") and entry.card_id or entry
    if type(card_id) == "string" and card_id ~= "" then
      local ok_def, def = pcall(cards.get_card_def, card_id)
      if ok_def and def then
        local eligible = true
        if req_tier ~= nil and (def.tier or 0) ~= req_tier then eligible = false end
        if eligible and args.target == "unit" and def.kind ~= "Unit" and def.kind ~= "Worker" then eligible = false end
        if eligible and req_subtypes and #req_subtypes > 0 then
          if not def.subtypes then
            eligible = false
          else
            local found = false
            for _, req in ipairs(req_subtypes) do
              for _, got in ipairs(def.subtypes) do
                if req == got then found = true; break end
              end
              if found then break end
            end
            if not found then eligible = false end
          end
        end
        -- Shallow-copy the def and attach graveyard_index so on_click can identify it
        local entry_def = {}
        for k, v in pairs(def) do entry_def[k] = v end
        entry_def.graveyard_index = i
        entry_def.graveyard_eligible = eligible
        out[#out + 1] = entry_def
      end
    end
  end
  return out
end

function GameState:open_graveyard_view(player_index)
  local player = self.game_state.players[player_index + 1]
  if not player then
    return
  end

  local faction_info = factions_data[player.faction]
  local accent = faction_info and faction_info.color or { 0.5, 0.5, 0.7 }
  local is_local = player_index == self.local_player_index

  deck_viewer.open({
    title = is_local and "Your Graveyard" or "Opponent Graveyard",
    hint = "Newest first",
    cards = graveyard_cards_for_player(player),
    accent = accent,
    filters = { "All", "Unit", "Worker", "Structure", "Spell", "Technology", "Item", "Artifact" },
    filter_fn = function(def, filter_name)
      return def.kind == filter_name
    end,
  })
  self.show_blueprint_for_player = nil
end

function GameState:_sync_terminal_state()
  local g = self.game_state
  local is_terminal = g and g.is_terminal == true
  if not is_terminal then
    self._terminal_announced = false
    return
  end

  if self._terminal_announced then
    return
  end
  self._terminal_announced = true

  -- Clear mutable UI state when match ends.
  self.drag = nil
  self.hand_selected_index = nil
  self.pending_play_unit = nil
  self.pending_sacrifice = nil
  self.pending_upgrade = nil
  self.pending_hand_sacrifice = nil
  self.pending_monument = nil
  self.pending_graveyard_return = nil
  self.pending_counter_placement = nil
  self.pending_damage_target = nil
  self.pending_damage_x = nil
  self.pending_spell_target = nil
  self.pending_play_spell = nil
  self.pending_discard_draw = nil
  self:_clear_pending_attack_declarations()
  self.pending_attack_trigger_targets = {}
  self.pending_block_assignments = {}
  self.pending_damage_orders = {}

  self.turn_banner_timer = 1.6
  self.turn_banner_text = terminal_title_for_player(g, self.local_player_index) or "Match Ended"
  self.multiplayer_status = "Match ended"
end

function GameState:dispatch_command(command)
  -- Don't process commands during disconnect
  if self._disconnect_timer then return { ok = false, reason = "disconnected" } end
  if self.game_state and self.game_state.is_terminal then return { ok = false, reason = "game_over" } end

  local result

  if self.authoritative_adapter then
    local ok_submit, submit_result = pcall(function() return self.authoritative_adapter:submit(command) end)
    if not ok_submit then
      local submit_reason = tostring(submit_result)
      if should_trigger_reconnect(submit_reason) then
        self:_queue_reconnect(submit_reason)
        return { ok = false, reason = submit_reason, meta = {} }
      end
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
      self.multiplayer_status = "Connected"
    else
      self.multiplayer_status = "Multiplayer warning: " .. tostring(result.reason)
      if should_trigger_reconnect(result.reason) then
        self:_queue_reconnect(result.reason)
      end
    end
  else
    result = commands.execute(self.game_state, command)
  end

  if command and command.type ~= "DECLARE_ATTACKERS" and #self.pending_attack_declarations > 0 then
    self:_clear_pending_attack_declarations()
  end
  if command and command.type ~= "ASSIGN_ATTACK_TRIGGER_TARGETS" and #self.pending_attack_trigger_targets > 0 then
    self.pending_attack_trigger_targets = {}
  end

  self:_sync_terminal_state()
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
       or k == "structure" or k == "structure_worker" or k == "hand_card" or k == "unit_deck" or k == "graveyard" or k == "unit_row"
       or k == "special_worker_unassigned" or k == "special_worker_resource" or k == "special_worker_structure" then
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

  -- Feature 5: Tooltip hover delay (structures + deck/graveyard + ability buttons + workers)
  if self.hover and (self.hover.kind == "structure" or self.hover.kind == "unit_deck" or self.hover.kind == "graveyard"
      or self.hover.kind == "ability_hover" or self.hover.kind == "activate_ability"
      or self.hover.kind == "special_worker_unassigned" or self.hover.kind == "special_worker_resource"
      or self.hover.kind == "special_worker_structure"
      or self.hover.kind == "worker_unassigned" or self.hover.kind == "worker_left"
      or self.hover.kind == "worker_right" or self.hover.kind == "structure_worker") and not deck_viewer.is_open() then
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
      local poll_reason = tostring(poll_err)
      print("[game] poll error: " .. poll_reason)
      if should_trigger_reconnect(poll_reason) then
        self:_queue_reconnect(poll_reason)
      else
        self:_handle_disconnect("Connection lost")
      end
    elseif self.authoritative_adapter._disconnected then
      local disconnect_reason = tostring(self.authoritative_adapter._disconnect_reason or "transport_receive_failed")
      self.authoritative_adapter._disconnected = false
      self.authoritative_adapter._disconnect_reason = nil
      if should_trigger_reconnect(disconnect_reason) then
        self:_queue_reconnect(disconnect_reason)
      else
        self:_handle_disconnect("Opponent disconnected")
      end
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
        local sync_reason = tostring(snap)
        print("[game] sync_snapshot error: " .. sync_reason)
        if should_trigger_reconnect(sync_reason) then
          self:_queue_reconnect(sync_reason)
        else
          self:_handle_disconnect("Connection lost")
        end
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

  self:_sync_terminal_state()

  local c = self.game_state and self.game_state.pendingCombat
  local in_target_step = c and c.stage == "AWAITING_ATTACK_TARGETS" and c.attacker == self.local_player_index
  if not in_target_step and #self.pending_attack_trigger_targets > 0 then
    self:_clear_pending_attack_trigger_targets()
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



local function can_attack_multiple_times(card_def)
  if not card_def or not card_def.abilities then return false end
  for _, ab in ipairs(card_def.abilities) do
    if ab.type == "static" and (ab.effect == "can_attack_multiple_times" or ab.effect == "can_attack_twice") then
      return true
    end
  end
  return false
end

function GameState:_set_pending_attack(attacker_board_index, target)
  local local_player = self.game_state.players[self.local_player_index + 1]
  local attacker_entry = local_player and local_player.board and local_player.board[attacker_board_index]
  if not attacker_entry then return end

  local ok_def, attacker_def = pcall(cards.get_card_def, attacker_entry.card_id)
  if not ok_def or not attacker_def then return end
  if attacker_def.kind ~= "Unit" and attacker_def.kind ~= "Worker" then return end
  if unit_stats.effective_attack(attacker_def, attacker_entry.state) <= 0 then return end

  local ast = attacker_entry.state or {}
  if ast.rested then return end
  if ast.attacked_turn == self.game_state.turnNumber and not can_attack_multiple_times(attacker_def) then
    return
  end

  local replaced = false
  for _, decl in ipairs(self.pending_attack_declarations) do
    if decl.attacker_board_index == attacker_board_index then
      decl.target = target
      replaced = true
      break
    end
  end
  if not replaced then
    self.pending_attack_declarations[#self.pending_attack_declarations + 1] = {
      attacker_board_index = attacker_board_index,
      target = target,
    }
  end
end




function GameState:_clear_pending_attack_declarations()
  self.pending_attack_declarations = {}
end

function GameState:_clear_pending_attack_trigger_targets()
  self.pending_attack_trigger_targets = {}
end

function GameState:_pending_attack_trigger_entry(attacker_board_index, ability_index, create_if_missing)
  for _, item in ipairs(self.pending_attack_trigger_targets or {}) do
    if item.attacker_board_index == attacker_board_index and item.ability_index == ability_index then
      return item
    end
  end

  if not create_if_missing then
    return nil
  end

  local item = {
    attacker_board_index = attacker_board_index,
    ability_index = ability_index,
  }
  self.pending_attack_trigger_targets[#self.pending_attack_trigger_targets + 1] = item
  return item
end

function GameState:_get_pending_attack_trigger_target(attacker_board_index, ability_index)
  local item = self:_pending_attack_trigger_entry(attacker_board_index, ability_index, false)
  return item and item.target_board_index or nil
end

function GameState:_get_pending_attack_trigger_activation(attacker_board_index, ability_index)
  local item = self:_pending_attack_trigger_entry(attacker_board_index, ability_index, false)
  return item and item.activate or nil
end

function GameState:_set_pending_attack_trigger_target(attacker_board_index, ability_index, target_board_index)
  local item = self:_pending_attack_trigger_entry(attacker_board_index, ability_index, true)
  item.target_board_index = target_board_index
end

function GameState:_set_pending_attack_trigger_activation(attacker_board_index, ability_index, activate)
  local item = self:_pending_attack_trigger_entry(attacker_board_index, ability_index, true)
  item.activate = (activate == true) and true or nil
end

function GameState:_is_pending_attack_trigger_target_legal(defender_pi, board_index)
  local player = self.game_state.players[defender_pi + 1]
  local entry = player and player.board and player.board[board_index]
  if not entry then return false end
  local ok_def, def = pcall(cards.get_card_def, entry.card_id)
  return ok_def and def and def.kind ~= "Structure" and def.kind ~= "Artifact"
end

function GameState:_attack_trigger_legal_targets(combat_state)
  local out = {}
  if not combat_state then return out end
  local defender = combat_state.defender
  local player = self.game_state.players[defender + 1]
  if not player then return out end
  for i, entry in ipairs(player.board or {}) do
    local ok_def, def = pcall(cards.get_card_def, entry.card_id)
    if ok_def and def and def.kind ~= "Structure" and def.kind ~= "Artifact" then
      out[#out + 1] = i
    end
  end
  return out
end

function GameState:_active_attack_trigger_for_targeting(combat_state)
  if not combat_state or type(combat_state.attack_triggers) ~= "table" then
    return nil
  end

  for _, trigger in ipairs(combat_state.attack_triggers) do
    if not trigger.resolved and trigger.requires_target then
      local selected = self:_get_pending_attack_trigger_target(trigger.attacker_board_index, trigger.ability_index)
      if selected == nil then
        return trigger
      end
    end
  end

  for _, trigger in ipairs(combat_state.attack_triggers) do
    if not trigger.resolved and trigger.optional_activate then
      local activate = self:_get_pending_attack_trigger_activation(trigger.attacker_board_index, trigger.ability_index)
      if activate ~= true then
        return trigger
      end
    end
  end

  return nil
end

function GameState:_build_attack_trigger_target_payload(combat_state)
  local payload = {}
  if not combat_state or type(combat_state.attack_triggers) ~= "table" then
    return payload
  end
  for _, trigger in ipairs(combat_state.attack_triggers) do
    if not trigger.resolved then
      local selected = self:_get_pending_attack_trigger_target(trigger.attacker_board_index, trigger.ability_index)
      local activate = self:_get_pending_attack_trigger_activation(trigger.attacker_board_index, trigger.ability_index)
      if trigger.requires_target and selected ~= nil then
        payload[#payload + 1] = {
          attacker_board_index = trigger.attacker_board_index,
          ability_index = trigger.ability_index,
          target_board_index = selected,
        }
      elseif trigger.optional_activate and activate == true then
        payload[#payload + 1] = {
          attacker_board_index = trigger.attacker_board_index,
          ability_index = trigger.ability_index,
          activate = true,
        }
      end
    end
  end
  return payload
end

function GameState:_prune_invalid_pending_attacks()
  local player = self.game_state.players[self.local_player_index + 1]
  if not player then
    self.pending_attack_declarations = {}
    return
  end

  local kept = {}
  for _, decl in ipairs(self.pending_attack_declarations or {}) do
    local entry = player.board[decl.attacker_board_index]
    if entry then
      local ok_def, def = pcall(cards.get_card_def, entry.card_id)
      local st = entry.state or {}
      local already_attacked = (st.attacked_turn == self.game_state.turnNumber) and (not can_attack_multiple_times(def))
      if ok_def and def and (def.kind == "Unit" or def.kind == "Worker") and unit_stats.effective_attack(def, st) > 0 and not st.rested and not already_attacked then
        kept[#kept + 1] = decl
      end
    end
  end
  self.pending_attack_declarations = kept
end

function GameState:_set_pending_block(blocker_board_index, attacker_board_index)
  local replaced = false
  for _, blk in ipairs(self.pending_block_assignments) do
    if blk.blocker_board_index == blocker_board_index then
      blk.attacker_board_index = attacker_board_index
      replaced = true
      break
    end
  end
  if not replaced then
    self.pending_block_assignments[#self.pending_block_assignments + 1] = {
      blocker_board_index = blocker_board_index,
      attacker_board_index = attacker_board_index,
    }
  end
end

function GameState:_build_default_damage_orders(combat_state)
  local grouped = {}
  for _, blk in ipairs((combat_state and combat_state.blockers) or {}) do
    local attacker_index = blk.attacker_board_index
    grouped[attacker_index] = grouped[attacker_index] or {}
    grouped[attacker_index][#grouped[attacker_index] + 1] = blk.blocker_board_index
  end

  local orders = {}
  for attacker_index, blocker_indices in pairs(grouped) do
    if #blocker_indices > 1 then
      local custom = self.pending_damage_orders[attacker_index]
      local ordered = {}
      local seen = {}
      if type(custom) == "table" then
        for _, bi in ipairs(custom) do
          for _, legal in ipairs(blocker_indices) do
            if bi == legal and not seen[bi] then
              ordered[#ordered + 1] = bi
              seen[bi] = true
              break
            end
          end
        end
      end
      for _, bi in ipairs(blocker_indices) do
        if not seen[bi] then ordered[#ordered + 1] = bi end
      end

      orders[#orders + 1] = {
        attacker_board_index = attacker_index,
        blocker_board_indices = ordered,
      }
    end
  end
  return orders
end

function GameState:_append_pending_damage_order(attacker_board_index, blocker_board_index)
  local list = self.pending_damage_orders[attacker_board_index] or {}
  local filtered = {}
  for _, bi in ipairs(list) do
    if bi ~= blocker_board_index then filtered[#filtered + 1] = bi end
  end
  filtered[#filtered + 1] = blocker_board_index
  self.pending_damage_orders[attacker_board_index] = filtered
end

function GameState:_draw_attack_declaration_arrows()
  local local_attacker = self.local_player_index
  local local_defender = 1 - local_attacker
  local combat_ui = {
    pending_attack_declarations = self.pending_attack_declarations,
    pending_block_assignments = self.pending_block_assignments,
    pending_attack_trigger_targets = self.pending_attack_trigger_targets,
  }

  -- Local staged declarations (before submit)
  for _, decl in ipairs(self.pending_attack_declarations or {}) do
    local ax, ay = board.board_entry_center(self.game_state, local_attacker, decl.attacker_board_index, self.local_player_index, combat_ui)
    local tx, ty
    if decl.target and decl.target.type == "base" then
      tx, ty = board.base_center_for_player(local_defender, self.local_player_index)
    elseif decl.target and decl.target.type == "board" then
      tx, ty = board.board_entry_center(self.game_state, local_defender, decl.target.index, self.local_player_index, combat_ui)
    end
    if ax and ay and tx and ty then
      self:_draw_arrow(ax, ay, tx, ty, { 1.0, 0.3, 0.3, 0.9 })
    end
  end

  -- Committed combat declarations (visible to both players)
  local c = self.game_state.pendingCombat
  local committed = c and c.attackers or nil
  if committed then
    for _, decl in ipairs(committed) do
      local ax, ay = board.board_entry_center(self.game_state, c.attacker, decl.board_index, self.local_player_index, combat_ui)
      local tx, ty
      if decl.target and decl.target.type == "base" then
        tx, ty = board.base_center_for_player(c.defender, self.local_player_index)
      elseif decl.target and decl.target.type == "board" then
        tx, ty = board.board_entry_center(self.game_state, c.defender, decl.target.index, self.local_player_index, combat_ui)
      end
      if ax and ay and tx and ty then
        self:_draw_arrow(ax, ay, tx, ty, { 1.0, 0.45, 0.45, 0.7 })
      end
    end
  end

  if c and c.stage == "DECLARED" and c.defender == self.local_player_index then
    local defender_pi = self.local_player_index
    local attacker_pi2 = c.attacker
    for _, blk in ipairs(self.pending_block_assignments or {}) do
      local bx, by = board.board_entry_center(self.game_state, defender_pi, blk.blocker_board_index, self.local_player_index, combat_ui)
      local ax, ay = board.board_entry_center(self.game_state, attacker_pi2, blk.attacker_board_index, self.local_player_index, combat_ui)
      if bx and by and ax and ay then
        self:_draw_arrow(bx, by, ax, ay, { 0.35, 0.75, 1.0, 0.9 })
      end
    end
  end

  if c and c.blockers and #c.blockers > 0 then
    for _, blk in ipairs(c.blockers) do
      local bx, by = board.board_entry_center(self.game_state, c.defender, blk.blocker_board_index, self.local_player_index, combat_ui)
      local ax, ay = board.board_entry_center(self.game_state, c.attacker, blk.attacker_board_index, self.local_player_index, combat_ui)
      if bx and by and ax and ay then
        self:_draw_arrow(bx, by, ax, ay, { 0.2, 0.65, 0.95, 0.7 })
      end
    end
  end

  if self.drag and self.drag.from == "attack_unit" and self.drag.player_index == self.local_player_index then
    local ax, ay = board.board_entry_center(self.game_state, self.drag.player_index, self.drag.board_index, self.local_player_index, combat_ui)
    if ax and ay then
      self:_draw_arrow(ax, ay, self.drag.display_x, self.drag.display_y, { 1.0, 0.8, 0.2, 0.85 })
    end
  end
  if self.drag and self.drag.from == "block_unit" and self.drag.player_index == self.local_player_index then
    local bx, by = board.board_entry_center(self.game_state, self.drag.player_index, self.drag.board_index, self.local_player_index, combat_ui)
    if bx and by then
      self:_draw_arrow(bx, by, self.drag.display_x, self.drag.display_y, { 0.35, 0.75, 1.0, 0.85 })
    end
  end
  if self.drag and self.drag.from == "order_attacker" and self.drag.player_index == self.local_player_index then
    local ax, ay = board.board_entry_center(self.game_state, self.drag.player_index, self.drag.board_index, self.local_player_index, combat_ui)
    if ax and ay then
      self:_draw_arrow(ax, ay, self.drag.display_x, self.drag.display_y, { 1.0, 0.95, 0.45, 0.85 })
    end
  end
end

function GameState:_draw_top_combat_prompt(prompt_text, border_color, text_color)
  if type(prompt_text) ~= "string" or prompt_text == "" then
    return
  end

  local gw = love.graphics.getWidth()
  local prompt_font = util.get_font(14)
  local prompt_w = prompt_font:getWidth(prompt_text) + 28
  local prompt_h = prompt_font:getHeight() + 12
  local prompt_x = (gw - prompt_w) / 2
  local prompt_y = 8

  border_color = border_color or { 0.65, 0.72, 0.9, 0.75 }
  text_color = text_color or { 0.86, 0.9, 1.0, 1.0 }

  love.graphics.setColor(0.07, 0.08, 0.12, 0.9)
  love.graphics.rectangle("fill", prompt_x, prompt_y, prompt_w, prompt_h, 7, 7)
  love.graphics.setColor(border_color[1], border_color[2], border_color[3], border_color[4] or 0.75)
  love.graphics.rectangle("line", prompt_x, prompt_y, prompt_w, prompt_h, 7, 7)
  love.graphics.setFont(prompt_font)
  love.graphics.setColor(text_color[1], text_color[2], text_color[3], text_color[4] or 1.0)
  love.graphics.printf(prompt_text, prompt_x, prompt_y + 6, prompt_w, "center")
end

function GameState:_draw_attack_trigger_targeting_overlay()
  local c = self.game_state and self.game_state.pendingCombat
  if not c or c.stage ~= "AWAITING_ATTACK_TARGETS" then
    return
  end

  local t = love.timer.getTime()

  if c.attacker == self.local_player_index then
    local combat_ui = {
      pending_attack_declarations = self.pending_attack_declarations,
      pending_block_assignments = self.pending_block_assignments,
      pending_attack_trigger_targets = self.pending_attack_trigger_targets,
    }
    local active_trigger = self:_active_attack_trigger_for_targeting(c)
    local legal_targets = {}
    if active_trigger and active_trigger.requires_target then
      legal_targets = self:_attack_trigger_legal_targets(c)

      for _, target_index in ipairs(legal_targets) do
        local tx, ty = board.board_entry_center(self.game_state, c.defender, target_index, self.local_player_index, combat_ui)
        if tx and ty then
          local glow = 0.5 + 0.25 * math.sin(t * 4)
          local rw = board.BFIELD_TILE_W + 8
          local rh = board.BFIELD_TILE_H + 8
          local rx = tx - rw / 2
          local ry = ty - rh / 2
          love.graphics.setColor(0.22, 0.8, 1.0, glow * 0.55)
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", rx, ry, rw, rh, 7, 7)
          love.graphics.setLineWidth(1)
        end
      end
    end

    for _, trigger in ipairs(c.attack_triggers or {}) do
      if not trigger.resolved then
        local selected = self:_get_pending_attack_trigger_target(trigger.attacker_board_index, trigger.ability_index)
        if selected then
          local sx, sy = board.board_entry_center(self.game_state, c.attacker, trigger.attacker_board_index, self.local_player_index, combat_ui)
          local tx, ty = board.board_entry_center(self.game_state, c.defender, selected, self.local_player_index, combat_ui)
          if sx and sy and tx and ty then
            self:_draw_arrow(sx, sy, tx, ty, { 1.0, 0.85, 0.35, 0.9 })
          end
        end

        if trigger.optional_activate and self:_get_pending_attack_trigger_activation(trigger.attacker_board_index, trigger.ability_index) == true then
          local sx, sy = board.board_entry_center(self.game_state, c.attacker, trigger.attacker_board_index, self.local_player_index, combat_ui)
          if sx and sy then
            local glow = 0.55 + 0.25 * math.sin(t * 4)
            local rw = board.BFIELD_TILE_W + 10
            local rh = board.BFIELD_TILE_H + 10
            local rx = sx - rw / 2
            local ry = sy - rh / 2
            love.graphics.setColor(0.2, 0.85, 0.45, glow * 0.25)
            love.graphics.rectangle("fill", rx, ry, rw, rh, 8, 8)
            love.graphics.setColor(0.3, 1.0, 0.6, glow * 0.9)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", rx, ry, rw, rh, 8, 8)
            love.graphics.setLineWidth(1)
          end
        end
      end
    end

    local function trigger_attacker_name(trigger)
      local attacker_name = "Attacker"
      local atk_player = self.game_state.players[c.attacker + 1]
      local atk_entry = atk_player and atk_player.board and atk_player.board[trigger.attacker_board_index]
      if atk_entry then
        local ok_def, def = pcall(cards.get_card_def, atk_entry.card_id)
        if ok_def and def and def.name then
          attacker_name = def.name
        end
      end
      return attacker_name
    end

    local prompt_text = "On Attack choices set. Press Pass to continue"
    local border_color = { 1.0, 0.78, 0.32, 0.85 }
    local text_color = { 0.96, 0.9, 0.8, 1.0 }
    if active_trigger then
      local attacker_name = trigger_attacker_name(active_trigger)

      local sx, sy = board.board_entry_center(self.game_state, c.attacker, active_trigger.attacker_board_index, self.local_player_index, combat_ui)
      if sx and sy then
        local glow = 0.55 + 0.3 * math.sin(t * 4)
        local rw = board.BFIELD_TILE_W + 10
        local rh = board.BFIELD_TILE_H + 10
        local rx = sx - rw / 2
        local ry = sy - rh / 2

        if active_trigger.requires_target then
          if #legal_targets > 0 then
            prompt_text = attacker_name .. ": select a unit-row target, then Pass"
          else
            prompt_text = attacker_name .. ": no valid unit-row targets. Press Pass"
          end
          love.graphics.setColor(1.0, 0.75, 0.25, glow * 0.35)
          love.graphics.rectangle("fill", rx, ry, rw, rh, 8, 8)
          love.graphics.setColor(1.0, 0.78, 0.32, glow)
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", rx, ry, rw, rh, 8, 8)
          love.graphics.setLineWidth(1)
        elseif active_trigger.optional_activate then
          local selected = self:_get_pending_attack_trigger_activation(active_trigger.attacker_board_index, active_trigger.ability_index) == true
          if selected then
            prompt_text = attacker_name .. ": ability selected. Press Pass to continue"
            border_color = { 0.3, 0.9, 0.55, 0.85 }
            text_color = { 0.9, 1.0, 0.92, 1.0 }
            love.graphics.setColor(0.2, 0.85, 0.45, glow * 0.25)
            love.graphics.rectangle("fill", rx, ry, rw, rh, 8, 8)
            love.graphics.setColor(0.3, 1.0, 0.6, glow * 0.9)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", rx, ry, rw, rh, 8, 8)
            love.graphics.setLineWidth(1)
          else
            prompt_text = attacker_name .. ": click this attacker to activate On Attack, or Pass to skip"
            love.graphics.setColor(1.0, 0.75, 0.25, glow * 0.35)
            love.graphics.rectangle("fill", rx, ry, rw, rh, 8, 8)
            love.graphics.setColor(1.0, 0.78, 0.32, glow)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", rx, ry, rw, rh, 8, 8)
            love.graphics.setLineWidth(1)
          end
        end
      end
    end

    self:_draw_top_combat_prompt(prompt_text, border_color, text_color)
  elseif c.defender == self.local_player_index then
    self:_draw_top_combat_prompt("Waiting for opponent to resolve On Attack choices...", { 0.65, 0.72, 0.9, 0.75 }, { 0.86, 0.9, 1.0, 1.0 })
  end
end

function GameState:_draw_combat_priority_overlay()
  local c = self.game_state and self.game_state.pendingCombat
  if not c or c.stage == "AWAITING_ATTACK_TARGETS" then
    return
  end

  local local_pi = self.local_player_index
  local prompt_text = nil
  local border_color = { 0.65, 0.72, 0.9, 0.75 }
  local text_color = { 0.86, 0.9, 1.0, 1.0 }

  if c.stage == "DECLARED" then
    if c.defender == local_pi then
      if #(self.pending_block_assignments or {}) > 0 then
        prompt_text = "Blockers selected. Press Pass to continue"
      else
        prompt_text = "Declare blockers, then Pass"
      end
      border_color = { 0.35, 0.75, 1.0, 0.85 }
      text_color = { 0.86, 0.94, 1.0, 1.0 }
    elseif c.attacker == local_pi then
      prompt_text = "Waiting for opponent to declare blockers..."
    end
  elseif c.stage == "AWAITING_DAMAGE_ORDER" then
    if c.attacker == local_pi then
      local has_custom_order = false
      for _, order in pairs(self.pending_damage_orders or {}) do
        if type(order) == "table" and #order > 0 then
          has_custom_order = true
          break
        end
      end
      if has_custom_order then
        prompt_text = "Damage order set. Press Pass to continue"
      else
        prompt_text = "Set blocker damage order (optional), then Pass"
      end
      border_color = { 1.0, 0.82, 0.35, 0.85 }
      text_color = { 0.98, 0.92, 0.78, 1.0 }
    elseif c.defender == local_pi then
      prompt_text = "Waiting for opponent to set damage order..."
    end
  elseif c.stage == "BLOCKERS_ASSIGNED" then
    if c.attacker == local_pi then
      prompt_text = "Press Pass to resolve combat"
      border_color = { 0.92, 0.65, 0.3, 0.85 }
      text_color = { 0.98, 0.9, 0.8, 1.0 }
    elseif c.defender == local_pi then
      prompt_text = "Waiting for attacker to resolve combat..."
    end
  end

  self:_draw_top_combat_prompt(prompt_text, border_color, text_color)
end

function GameState:_draw_pending_hand_sacrifice_overlay()
  local pending = self.pending_hand_sacrifice
  if not pending then
    return
  end

  local local_p = self.game_state and self.game_state.players and self.game_state.players[self.local_player_index + 1]
  local card_name = "Card"
  if local_p and local_p.hand and pending.hand_index then
    local card_id = local_p.hand[pending.hand_index]
    if card_id then
      local ok_def, def = pcall(cards.get_card_def, card_id)
      if ok_def and def and def.name then
        card_name = def.name
      end
    end
  end

  local required = pending.required_count or 0
  local selected = #(pending.selected_targets or {})
  local prompt_text
  if required > 0 then
    prompt_text = card_name .. ": select workers to sacrifice (" .. selected .. "/" .. required .. ")"
  else
    prompt_text = card_name .. ": select workers to sacrifice"
  end

  self:_draw_top_combat_prompt(prompt_text, { 0.95, 0.78, 0.35, 0.85 }, { 0.98, 0.92, 0.8, 1.0 })
end

function GameState:_draw_pending_monument_overlay()
  local pending = self.pending_monument
  if not pending then return end

  local local_p = self.game_state and self.game_state.players and self.game_state.players[self.local_player_index + 1]
  local card_name = "Card"
  if local_p and local_p.hand and pending.hand_index then
    local card_id = local_p.hand[pending.hand_index]
    if card_id then
      local ok_def, def = pcall(cards.get_card_def, card_id)
      if ok_def and def and def.name then card_name = def.name end
    end
  end

  local prompt_text = card_name .. ": select a Monument with " .. pending.min_counters .. "+ Wonder counters"
  self:_draw_top_combat_prompt(prompt_text, { 0.6, 0.5, 0.1, 0.85 }, { 0.98, 0.92, 0.6, 1.0 })
end

function GameState:_draw_pending_damage_x_overlay()
  local pending = self.pending_damage_x
  if not pending then return end

  local gw = love.graphics.getWidth()
  local btn_w, btn_h = 24, 22
  local prompt_font = util.get_font(14)
  local label_text = "X Stone -> Deal " .. pending.x_amount .. " damage  (max: " .. pending.max_x .. ")"
  local label_w = prompt_font:getWidth(label_text)
  local total_w = btn_w + 8 + label_w + 8 + btn_w + 28
  local total_h = btn_h + 12
  local rx = (gw - total_w) / 2
  local ry = 8

  love.graphics.setColor(0.07, 0.08, 0.12, 0.9)
  love.graphics.rectangle("fill", rx, ry, total_w, total_h, 7, 7)
  love.graphics.setColor(0.95, 0.35, 0.2, 0.75)
  love.graphics.rectangle("line", rx, ry, total_w, total_h, 7, 7)

  local minus_x = rx + 6
  local minus_y = ry + (total_h - btn_h) / 2
  love.graphics.setColor(0.25, 0.25, 0.3, 0.9)
  love.graphics.rectangle("fill", minus_x, minus_y, btn_w, btn_h, 4, 4)
  love.graphics.setColor(0.85, 0.85, 0.95, 1.0)
  love.graphics.setFont(prompt_font)
  love.graphics.printf("-", minus_x, minus_y + 3, btn_w, "center")

  local label_x = minus_x + btn_w + 8
  love.graphics.setColor(0.98, 0.85, 0.7, 1.0)
  love.graphics.printf(label_text, label_x, ry + (total_h - prompt_font:getHeight()) / 2, label_w + 4, "left")

  local plus_x = label_x + label_w + 8
  love.graphics.setColor(0.25, 0.25, 0.3, 0.9)
  love.graphics.rectangle("fill", plus_x, minus_y, btn_w, btn_h, 4, 4)
  love.graphics.setColor(0.85, 0.85, 0.95, 1.0)
  love.graphics.printf("+", plus_x, minus_y + 3, btn_w, "center")

  -- Store button rects for click detection in mousepressed
  pending.minus_btn = { x = minus_x, y = minus_y, w = btn_w, h = btn_h }
  pending.plus_btn  = { x = plus_x,  y = minus_y, w = btn_w, h = btn_h }
end

function GameState:_draw_pending_discard_draw_overlay()
  local pending = self.pending_discard_draw
  if not pending then return end
  local selected_count = 0
  for _ in pairs(pending.selected_set) do selected_count = selected_count + 1 end
  local remaining = pending.required_count - selected_count
  local msg
  if remaining > 0 then
    msg = "Select " .. remaining .. " card" .. (remaining == 1 and "" or "s") .. " to discard"
  else
    msg = "Discarding..."
  end
  self:_draw_top_combat_prompt(msg, { 0.9, 0.45, 0.1, 0.85 }, { 1.0, 0.85, 0.6, 1.0 })
end

function GameState:_draw_pending_spell_target_prompt()
  local pending = self.pending_spell_target
  if not pending then return end
  local p = self.game_state and self.game_state.players[self.local_player_index + 1]
  local spell_name = "Spell"
  if p and p.hand and pending.hand_index then
    local cid = p.hand[pending.hand_index]
    if cid then
      local ok_d, cdef = pcall(cards.get_card_def, cid)
      if ok_d and cdef and cdef.name then spell_name = cdef.name end
    end
  end
  self:_draw_top_combat_prompt(spell_name .. ": select a target", { 0.7, 0.4, 0.9, 0.85 }, { 0.9, 0.8, 1.0, 1.0 })
end

function GameState:draw()
  shake.apply()

  self:_prune_invalid_pending_attacks()

  local pending_upgrade_sacrifice = (self.pending_upgrade and self.pending_upgrade.stage == "sacrifice") and self.pending_upgrade or nil
  local pending_upgrade_hand = (self.pending_upgrade and self.pending_upgrade.stage == "hand") and self.pending_upgrade or nil
  local sacrifice_allow_workers = nil
  if self.pending_sacrifice or self.pending_hand_sacrifice then
    sacrifice_allow_workers = true
  elseif pending_upgrade_sacrifice then
    sacrifice_allow_workers = pending_upgrade_sacrifice.eligible_worker_sacrifice == true
  end

  -- Build hand_state for board.draw
  local hand_state = {
    hover_index = self.hand_hover_index,
    selected_index = self.hand_selected_index,
    y_offsets = self.hand_y_offsets,
    eligible_hand_indices = self.pending_play_unit and self.pending_play_unit.eligible_indices or (pending_upgrade_hand and pending_upgrade_hand.eligible_hand_indices) or (self.pending_play_spell and self.pending_play_spell.eligible_indices) or nil,
    sacrifice_eligible_indices = (self.pending_sacrifice and self.pending_sacrifice.eligible_board_indices) or (pending_upgrade_sacrifice and pending_upgrade_sacrifice.eligible_board_indices) or (self.pending_hand_sacrifice and {}) or nil,
    sacrifice_allow_workers = sacrifice_allow_workers,
    monument_eligible_indices = self.pending_monument and self.pending_monument.eligible_indices or nil,
    counter_target_eligible_indices = self.pending_counter_placement and self.pending_counter_placement.eligible_board_indices or nil,
    damage_target_eligible_player_index = (self.pending_damage_target and self.pending_damage_target.eligible_player_index) or (self.pending_damage_x and self.pending_damage_x.eligible_player_index) or (self.pending_spell_target and self.pending_spell_target.eligible_player_index) or nil,
    damage_target_eligible_indices = (self.pending_damage_target and self.pending_damage_target.eligible_board_indices) or (self.pending_damage_x and self.pending_damage_x.eligible_board_indices) or (self.pending_spell_target and self.pending_spell_target.eligible_board_indices) or nil,
    damage_target_board_indices_by_player = self.pending_damage_target and self.pending_damage_target.eligible_board_indices_by_player or nil,
    damage_target_base_player_indices = self.pending_damage_target and self.pending_damage_target.eligible_base_player_indices or nil,
    pending_attack_declarations = self.pending_attack_declarations,
    pending_block_assignments = self.pending_block_assignments,
    pending_attack_trigger_targets = self.pending_attack_trigger_targets,
    discard_selected_set = self.pending_discard_draw and self.pending_discard_draw.selected_set or nil,
  }
  board.draw(self.game_state, self.drag, self.hover, self.mouse_down, self.display_resources, hand_state, self.local_player_index)
  self:_draw_attack_declaration_arrows()
  self:_draw_attack_trigger_targeting_overlay()
  self:_draw_combat_priority_overlay()
  self:_draw_pending_hand_sacrifice_overlay()
  self:_draw_pending_monument_overlay()
  self:_draw_pending_damage_x_overlay()
  self:_draw_pending_spell_target_prompt()
  self:_draw_pending_discard_draw_overlay()

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

  -- Dragged worker / unit follows cursor (drawn on top so it's always visible)
  if self.drag and self.drag.from ~= "attack_unit" and self.drag.from ~= "block_unit" and self.drag.from ~= "order_attacker" then
    local dx, dy = self.drag.display_x, self.drag.display_y
    local r = board.WORKER_R
    local drag_r = r * 1.2
    -- Soft shadow (offset) for a lifted look
    love.graphics.setColor(0, 0, 0, 0.45)
    love.graphics.circle("fill", dx + 3, dy + 5, drag_r + 3)
    if self.drag.from == "special" or self.drag.from == "special_field" then
      -- Gold special worker
      love.graphics.setColor(1.0, 0.85, 0.3, 1.0)
      love.graphics.circle("fill", dx, dy, drag_r)
      love.graphics.setColor(0.85, 0.65, 0.1, 1.0)
      love.graphics.setLineWidth(2)
      love.graphics.circle("line", dx, dy, drag_r)
      love.graphics.setLineWidth(1)
    else
      -- Main fill (slightly brighter when dragging)
      love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
      love.graphics.circle("fill", dx, dy, drag_r)
      -- Outline
      love.graphics.setColor(0.5, 0.55, 1.0, 1.0)
      love.graphics.setLineWidth(2)
      love.graphics.circle("line", dx, dy, drag_r)
      love.graphics.setLineWidth(1)
    end
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
      local entry
      if si == 0 then
        entry = { card_id = player.baseId }
      else
        entry = player and player.board[si]
      end
      if entry then
        local ok, def = pcall(cards.get_card_def, entry.card_id)
        if ok and def then
          local preview_attack = def.attack
          local preview_health = def.health or def.baseHealth
          if si ~= 0 and (def.kind == "Unit" or def.kind == "Worker") then
            local est = entry.state or {}
            preview_attack = unit_stats.effective_attack(def, est)
            preview_health = unit_stats.effective_health(def, est)
          end
          local mx, my = love.mouse.getPosition()
          local gw, gh = love.graphics.getDimensions()
          -- Enlarged preview with ability text
          local aspect = card_frame.FULL_CARD_ASPECT_H_OVER_W or (3.5 / 2.5)
          local max_tw = math.max(80, gw - 20)
          local max_th = math.max(120, gh - 20)
          local tw = math.max(80, math.min(200, max_tw, math.floor(max_th / aspect + 0.5)))
          local th = card_frame.measure_full_height({
            w = tw,
            faction = def.faction,
            upkeep = def.upkeep,
            abilities_list = def.abilities,
            text = def.text,
          })

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
                local board_entry = player.board[si]
                local _cbt_tt = self.game_state.pendingCombat
                local _in_blk_tt = _cbt_tt and _cbt_tt.stage == "DECLARED"
                  and (pi == _cbt_tt.attacker or pi == _cbt_tt.defender)
                can_act_abs[ai] = (not used or not ab.once_per_turn) and abilities.can_pay_cost(player.resources, ab.cost)
                  and (pi == self.game_state.activePlayer or (ab.fast and _in_blk_tt))
                  and (not ab.rest or not (board_entry and board_entry.state and board_entry.state.rested))
                  and (ab.effect ~= "deal_damage_x" or (player.resources[(ab.effect_args and ab.effect_args.resource) or "stone"] or 0) >= 1)
                  and (ab.effect ~= "discard_draw" or #player.hand >= (ab.effect_args and ab.effect_args.discard or 2))
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
            subtypes = def.subtypes or {},
            text = def.text,
            costs = def.costs,
            upkeep = def.upkeep,
            attack = preview_attack,
            health = preview_health,
            tier = def.tier,
            abilities_list = def.abilities,
            used_abilities = used_abs,
            can_activate_abilities = can_act_abs,
            show_ability_text = true,
            counters = entry.state and unit_stats.all_counters(entry.state),
          })
          love.graphics.pop()
        end
      end
    end

    -- Regular worker tooltip (show tier 0 worker card for this faction)
    if self.hover and (self.hover.kind == "worker_unassigned" or self.hover.kind == "worker_left"
       or self.hover.kind == "worker_right" or self.hover.kind == "structure_worker") and self.tooltip_timer >= 0.3 then
      local pi = self.hover.pi
      local player = self.game_state.players[pi + 1]
      if player then
        -- Find the tier 0 worker card for this faction
        local worker_defs = cards.filter({ kind = "Worker", faction = player.faction })
        local def = nil
        for _, wd in ipairs(worker_defs) do
          if wd.tier == 0 and not wd.deckable then
            def = wd
            break
          end
        end
        if def then
          local mx, my = love.mouse.getPosition()
          local gw, gh = love.graphics.getDimensions()
          local aspect = card_frame.FULL_CARD_ASPECT_H_OVER_W or (3.5 / 2.5)
          local max_tw = math.max(80, gw - 20)
          local max_th = math.max(120, gh - 20)
          local tw = math.max(80, math.min(200, max_tw, math.floor(max_th / aspect + 0.5)))
          local th = card_frame.measure_full_height({
            w = tw, faction = def.faction, upkeep = def.upkeep,
            abilities_list = def.abilities, text = def.text,
          })
          local tx = mx + 16
          local ty = my - th / 2
          if tx + tw > gw - 10 then tx = mx - tw - 16 end
          if ty < 10 then ty = 10 end
          if ty + th > gh - 10 then ty = gh - th - 10 end

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
          love.graphics.pop()
        end
      end
    end

    -- Special worker tooltip (show card preview on hover)
    if self.hover and (self.hover.kind == "special_worker_unassigned"
       or self.hover.kind == "special_worker_resource"
       or self.hover.kind == "special_worker_structure") and self.tooltip_timer >= 0.3 then
      local pi = self.hover.pi
      local sw_index = self.hover.idx
      local player = self.game_state.players[pi + 1]
      local sw = player and player.specialWorkers and player.specialWorkers[sw_index]
      if sw then
        local ok, def = pcall(cards.get_card_def, sw.card_id)
        if ok and def then
          local mx, my = love.mouse.getPosition()
          local gw, gh = love.graphics.getDimensions()
          local aspect = card_frame.FULL_CARD_ASPECT_H_OVER_W or (3.5 / 2.5)
          local max_tw = math.max(80, gw - 20)
          local max_th = math.max(120, gh - 20)
          local tw = math.max(80, math.min(200, max_tw, math.floor(max_th / aspect + 0.5)))
          local th = card_frame.measure_full_height({
            w = tw, faction = def.faction, upkeep = def.upkeep,
            abilities_list = def.abilities, text = def.text,
          })
          local tx = mx + 16
          local ty = my - th / 2
          if tx + tw > gw - 10 then tx = mx - tw - 16 end
          if ty < 10 then ty = 10 end
          if ty + th > gh - 10 then ty = gh - th - 10 end

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
          love.graphics.pop()
        end
      end
    end

    -- Ability button tooltip (full text panel for activated abilities)
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
        local body_text = tostring(ab.text or card_frame.ability_effect_text(ab) or "")
        local header_text = (ab.label and tostring(ab.label) ~= "" and tostring(ab.label)) or "Activated Ability"
        local can_activate_now = (self.hover.kind == "activate_ability")
        local status_text = can_activate_now and "Usable Now" or "Not Usable"

        local function title_case_resource(key)
          key = tostring(key or "?")
          if key == "" then return "?" end
          return key:sub(1, 1):upper() .. key:sub(2)
        end

        local cost_parts = {}
        for _, c in ipairs(ab.cost or {}) do
          cost_parts[#cost_parts + 1] = tostring(c.amount or 0) .. " " .. title_case_resource(c.type)
        end
        local cost_text = (#cost_parts > 0) and ("Cost: " .. table.concat(cost_parts, " + ")) or "Cost: Free"

        local detail_parts = {}
        if ab.fast then detail_parts[#detail_parts + 1] = "Fast" end
        if ab.once_per_turn then detail_parts[#detail_parts + 1] = "Once per turn" end
        if ab.rest then detail_parts[#detail_parts + 1] = "Requires ready unit" end
        local detail_text = (#detail_parts > 0) and table.concat(detail_parts, "  |  ") or nil

        local header_font = util.get_title_font(12)
        local body_font = util.get_font(11)
        local meta_font = util.get_font(9)
        local chip_font = util.get_font(8)

        local pad_x, pad_y = 12, 10
        local inner_w = math.max(200, math.min(340, gw - 36) - pad_x * 2)
        local tw = inner_w + pad_x * 2

        local _, body_lines = body_font:getWrap(body_text, inner_w)
        if #body_lines == 0 then body_lines = { body_text } end
        local _, cost_lines = meta_font:getWrap(cost_text, inner_w)
        if #cost_lines == 0 then cost_lines = { cost_text } end
        local detail_lines = {}
        if detail_text and detail_text ~= "" then
          local _, wrapped = meta_font:getWrap(detail_text, inner_w)
          detail_lines = (#wrapped > 0) and wrapped or { detail_text }
        end

        local header_h = header_font:getHeight()
        local chip_w = chip_font:getWidth(status_text) + 12
        local chip_h = chip_font:getHeight() + 4
        local body_line_h = body_font:getHeight() + 1
        local meta_line_h = meta_font:getHeight() + 1
        local divider_h = 1
        local section_gap = 6

        local body_h = #body_lines * body_line_h
        local meta_h = #cost_lines * meta_line_h
        if #detail_lines > 0 then
          meta_h = meta_h + 3 + (#detail_lines * meta_line_h)
        end

        local th = pad_y
          + math.max(header_h, chip_h)
          + section_gap
          + divider_h
          + section_gap
          + meta_h
          + section_gap
          + divider_h
          + section_gap
          + body_h
          + pad_y

        local tx = mx + 16
        local ty = my - th - 8
        if tx + tw > gw - 10 then tx = mx - tw - 16 end
        if ty < 10 then ty = my + 14 end
        if ty + th > gh - 10 then ty = gh - th - 10 end
        if tx < 10 then tx = 10 end

        local fade_in = math.min(1, (self.tooltip_timer - 0.3) / 0.15)
        local corner = 7
        local accent = can_activate_now and { 0.25, 0.8, 0.45 } or { 0.45, 0.5, 0.62 }

        -- Shadow/backdrop
        love.graphics.setColor(0, 0, 0, 0.45 * fade_in)
        love.graphics.rectangle("fill", tx + 3, ty + 4, tw, th, corner, corner)
        -- Panel body
        love.graphics.setColor(0.06, 0.07, 0.1, 0.95 * fade_in)
        love.graphics.rectangle("fill", tx, ty, tw, th, corner, corner)
        -- Accent strip
        love.graphics.setColor(accent[1], accent[2], accent[3], 0.8 * fade_in)
        love.graphics.rectangle("fill", tx + 1, ty + 1, tw - 2, 3, corner, corner)
        -- Border
        love.graphics.setColor(0.3, 0.35, 0.5, 0.6 * fade_in)
        love.graphics.rectangle("line", tx, ty, tw, th, corner, corner)

        local cy = ty + pad_y

        -- Header row
        love.graphics.setFont(header_font)
        love.graphics.setColor(0.94, 0.96, 1.0, fade_in)
        love.graphics.print(header_text, tx + pad_x, cy)

        local chip_x = tx + tw - pad_x - chip_w
        local chip_y = cy + math.floor((header_h - chip_h) / 2)
        love.graphics.setColor(0, 0, 0, 0.2 * fade_in)
        love.graphics.rectangle("fill", chip_x + 1, chip_y + 1, chip_w, chip_h, 4, 4)
        love.graphics.setColor(accent[1], accent[2], accent[3], (can_activate_now and 0.28 or 0.18) * fade_in + 0.05)
        love.graphics.rectangle("fill", chip_x, chip_y, chip_w, chip_h, 4, 4)
        love.graphics.setColor(accent[1], accent[2], accent[3], 0.85 * fade_in)
        love.graphics.rectangle("line", chip_x, chip_y, chip_w, chip_h, 4, 4)
        love.graphics.setFont(chip_font)
        love.graphics.setColor(1, 1, 1, fade_in)
        love.graphics.printf(status_text, chip_x, chip_y + 2, chip_w, "center")

        cy = cy + math.max(header_h, chip_h) + section_gap

        -- Divider 1
        love.graphics.setColor(accent[1], accent[2], accent[3], 0.22 * fade_in)
        love.graphics.rectangle("fill", tx + pad_x, cy, inner_w, 1)
        cy = cy + divider_h + section_gap

        -- Meta section (cost + traits)
        love.graphics.setFont(meta_font)
        love.graphics.setColor(0.74, 0.77, 0.86, fade_in)
        for _, line in ipairs(cost_lines) do
          love.graphics.print(line, tx + pad_x, cy)
          cy = cy + meta_line_h
        end
        if #detail_lines > 0 then
          cy = cy + 3
          love.graphics.setColor(0.62, 0.66, 0.76, fade_in)
          for _, line in ipairs(detail_lines) do
            love.graphics.print(line, tx + pad_x, cy)
            cy = cy + meta_line_h
          end
        end

        cy = cy + section_gap
        -- Divider 2
        love.graphics.setColor(1, 1, 1, 0.08 * fade_in)
        love.graphics.rectangle("fill", tx + pad_x, cy, inner_w, 1)
        cy = cy + divider_h + section_gap

        -- Body text (full ability text, wrapped)
        love.graphics.setFont(body_font)
        love.graphics.setColor(0.88, 0.9, 0.96, fade_in)
        for _, line in ipairs(body_lines) do
          love.graphics.print(line, tx + pad_x, cy)
          cy = cy + body_line_h
        end
      end
    end

    -- Unit deck / graveyard tooltip (shows zone count on hover)
    if self.hover and (self.hover.kind == "unit_deck" or self.hover.kind == "graveyard") and self.tooltip_timer >= 0.3 then
      local pi = self.hover.pi
      local player = self.game_state.players[pi + 1]
      if player then
        local zone_label
        local zone_count
        if self.hover.kind == "graveyard" then
          zone_label = "Cards in graveyard: "
          zone_count = #(player.graveyard or {})
        else
          zone_label = "Cards in deck: "
          zone_count = #(player.deck or {})
        end
        local mx, my = love.mouse.getPosition()
        local gw, gh = love.graphics.getDimensions()
        local label = zone_label .. tostring(zone_count)
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

  if self.game_state and self.game_state.is_terminal then
    local gw, gh = love.graphics.getDimensions()
    local title = terminal_title_for_player(self.game_state, self.local_player_index) or "Match Ended"
    local title_color = { 0.9, 0.9, 0.95 }
    if title == "Victory" then
      title_color = { 0.45, 1.0, 0.6 }
    elseif title == "Defeat" then
      title_color = { 1.0, 0.35, 0.35 }
    end

    local reason = tostring(self.game_state.reason or "base_destroyed"):gsub("_", " ")
    local subtitle = "Reason: " .. reason
    local hint = self.return_to_menu and "Press Esc to return to menu" or "Match complete"

    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", 0, gh / 2 - 70, gw, 140)
    love.graphics.setFont(util.get_title_font(30))
    love.graphics.setColor(title_color[1], title_color[2], title_color[3], 1)
    love.graphics.printf(title, 0, gh / 2 - 44, gw, "center")
    love.graphics.setFont(util.get_font(13))
    love.graphics.setColor(0.82, 0.84, 0.9, 1)
    love.graphics.printf(subtitle, 0, gh / 2 + 2, gw, "center")
    love.graphics.setColor(0.7, 0.72, 0.8, 0.95)
    love.graphics.printf(hint, 0, gh / 2 + 24, gw, "center")
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
    local box_x = 12
    local box_y = love.graphics.getHeight() - box_h - 12
    love.graphics.setColor(0.08, 0.09, 0.13, 0.7)
    love.graphics.rectangle("fill", box_x, box_y, box_w, box_h, 6, 6)
    love.graphics.setColor(1, 1, 1, 0.92)
    love.graphics.setFont(status_font)
    love.graphics.printf(status_text, box_x + pad_x, box_y + pad_y, box_w - pad_x * 2, "left")
  end

  -- Vignette: drawn last, on top of everything
  textures.draw_vignette()
end


local function is_worker_board_entry(game_state, pi, board_index)
  local player = game_state.players[pi + 1]
  local entry = player and player.board and player.board[board_index]
  if not entry then return false end
  local ok, def = pcall(cards.get_card_def, entry.card_id)
  return ok and def and def.kind == "Worker"
end

local function upgrade_required_subtypes(effect_args)
  local args = effect_args or {}
  if type(args.subtypes) == "table" and #args.subtypes > 0 then
    return args.subtypes
  end
  return { "Warrior" }
end

local function has_any_subtype(card_def, required_subtypes)
  if not card_def or type(card_def.subtypes) ~= "table" then
    return false
  end
  for _, req in ipairs(required_subtypes or {}) do
    for _, got in ipairs(card_def.subtypes) do
      if req == got then
        return true
      end
    end
  end
  return false
end

local function find_upgrade_hand_indices(player, effect_args, target_tier)
  local out = {}
  local required_subtypes = upgrade_required_subtypes(effect_args)
  for hi, card_id in ipairs((player and player.hand) or {}) do
    local ok_h, hdef = pcall(cards.get_card_def, card_id)
    if ok_h and hdef and has_any_subtype(hdef, required_subtypes) and (hdef.tier or 0) == (target_tier or 0) then
      out[#out + 1] = hi
    end
  end
  return out
end

local function has_index(values, wanted)
  for _, value in ipairs(values or {}) do
    if value == wanted then return true end
  end
  return false
end

local function find_upgrade_board_sacrifice_indices(player, effect_args)
  local out = {}
  local required_subtypes = upgrade_required_subtypes(effect_args)
  for si, entry in ipairs((player and player.board) or {}) do
    local ok_t, tdef = pcall(cards.get_card_def, entry.card_id)
    if ok_t and tdef and tdef.kind ~= "Structure" and tdef.kind ~= "Artifact" and has_any_subtype(tdef, required_subtypes) then
      local next_tier = (tdef.tier or 0) + 1
      if #find_upgrade_hand_indices(player, effect_args, next_tier) > 0 then
        out[#out + 1] = si
      end
    end
  end
  return out
end

local function pretty_reason(reason)
  if type(reason) ~= "string" or reason == "" then
    return "Action failed"
  end
  local text = reason:gsub("_", " ")
  return text:gsub("^%l", string.upper)
end

local function find_pending_upgrade_target_by_click(game_state, local_player_index, eligible_indices, x, y, combat_ui)
  local nearest_si = nil
  local nearest_d2 = nil
  local pick_radius = math.max(board.BFIELD_TILE_W or 86, board.BFIELD_TILE_H or 74)
  local pick_d2 = pick_radius * pick_radius
  for _, si in ipairs(eligible_indices or {}) do
    local cx, cy = board.board_entry_center(game_state, local_player_index, si, local_player_index, combat_ui)
    if cx and cy then
      local dx = x - cx
      local dy = y - cy
      local d2 = dx * dx + dy * dy
      if d2 <= pick_d2 and (not nearest_d2 or d2 < nearest_d2) then
        nearest_d2 = d2
        nearest_si = si
      end
    end
  end
  return nearest_si
end

local function is_attack_unit_board_entry(game_state, pi, board_index, require_attack)
  local player = game_state.players[pi + 1]
  local entry = player and player.board and player.board[board_index]
  if not entry then return false end
  local ok, def = pcall(cards.get_card_def, entry.card_id)
  if not ok or not def then return false end
  if def.kind ~= "Unit" and def.kind ~= "Worker" then return false end
  if require_attack then
    local st = entry.state or {}
    local immediate_attack = false
    for _, kw in ipairs(def.keywords or {}) do
      local low = string.lower(kw)
      if low == "rush" or low == "haste" then
        immediate_attack = true
        break
      end
    end
    local summoning_sickness = (st.summoned_turn == game_state.turnNumber) and not immediate_attack
    local already_attacked = (st.attacked_turn == game_state.turnNumber) and (not can_attack_multiple_times(def))
    return unit_stats.effective_attack(def, st) > 0 and not st.rested and not summoning_sickness and not already_attacked
  end
  return true
end

local function has_static_effect(card_def, effect_name)
  if not card_def or not card_def.abilities then return false end
  for _, ab in ipairs(card_def.abilities) do
    if ab.type == "static" and ab.effect == effect_name then
      return true
    end
  end
  return false
end

local function can_stage_attack_target(game_state, attacker_pi, attacker_board_index, target_pi, target_index)
  local atk_player = game_state.players[attacker_pi + 1]
  local def_player = game_state.players[target_pi + 1]
  if not atk_player or not def_player then return false end

  local atk_entry = atk_player.board[attacker_board_index]
  if not atk_entry then return false end
  local atk_ok, atk_def = pcall(cards.get_card_def, atk_entry.card_id)
  if not atk_ok or not atk_def then return false end
  if atk_def.kind ~= "Unit" and atk_def.kind ~= "Worker" then return false end
  local atk_state = atk_entry.state or {}
  if unit_stats.effective_attack(atk_def, atk_state) <= 0 then return false end
  if atk_state.rested then return false end
  if atk_state.attacked_turn == game_state.turnNumber and not can_attack_multiple_times(atk_def) then
    return false
  end
  local immediate_attack = false
  for _, kw in ipairs(atk_def.keywords or {}) do
    local low = string.lower(kw)
    if low == "rush" or low == "haste" then
      immediate_attack = true
      break
    end
  end
  if atk_state.summoned_turn == game_state.turnNumber and not immediate_attack then
    return false
  end

  if target_index == 0 then
    return true
  end

  local target_entry = def_player.board[target_index]
  if not target_entry then return false end
  local tgt_ok, tgt_def = pcall(cards.get_card_def, target_entry.card_id)
  if not tgt_ok or not tgt_def then return false end
  if tgt_def.kind ~= "Unit" and tgt_def.kind ~= "Worker" and tgt_def.kind ~= "Structure" and tgt_def.kind ~= "Artifact" then
    return false
  end
  if (tgt_def.kind == "Structure" or tgt_def.kind == "Artifact") and tgt_def.health == nil then
    return false
  end

  if tgt_def.kind == "Unit" or tgt_def.kind == "Worker" then
    local target_state = target_entry.state or {}
    if target_state.rested then return true end
    return has_static_effect(atk_def, "can_attack_non_rested")
  end

  return true
end

function GameState:_draw_arrow(x1, y1, x2, y2, color)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return end
  local ux, uy = dx / len, dy / len
  local nx, ny = -uy, ux
  local head = 12
  local shaft_end_x = x2 - ux * head
  local shaft_end_y = y2 - uy * head

  love.graphics.setColor(color[1], color[2], color[3], color[4] or 1)
  love.graphics.setLineWidth(3)
  love.graphics.line(x1, y1, shaft_end_x, shaft_end_y)
  love.graphics.polygon("fill",
    x2, y2,
    shaft_end_x + nx * 6, shaft_end_y + ny * 6,
    shaft_end_x - nx * 6, shaft_end_y - ny * 6
  )
  love.graphics.setLineWidth(1)
end

local function get_special_field_index(game_state, pi, board_index)
  local player = game_state.players[pi + 1]
  local entry = player and player.board and player.board[board_index]
  if not entry then return nil end
  if entry.special_worker_index and player.specialWorkers and player.specialWorkers[entry.special_worker_index] then
    return entry.special_worker_index
  end
  return nil
end

function GameState:mousepressed(x, y, button, istouch, presses)
  if button ~= 1 then return end -- left click only
  if self.game_state and self.game_state.is_terminal then return end
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
            local pi_panel_bp = self:player_to_panel(self.show_blueprint_for_player)
            local sax, say, saw = board.structures_area_rect(px, py, pw, ph, pi_panel_bp)
            local struct_count = 0
            for _, e in ipairs(self.game_state.players[self.show_blueprint_for_player + 1].board) do
              local e_ok, e_def = pcall(cards.get_card_def, e.card_id)
              if e_ok and e_def and (e_def.kind == "Structure" or e_def.kind == "Artifact") then struct_count = struct_count + 1 end
            end
            local tile_step = board.BFIELD_TILE_W + board.BFIELD_GAP
            local start_x = board.centered_row_x(sax, saw, struct_count)
            popup.create("Built!", start_x + (struct_count - 1) * tile_step + board.BFIELD_TILE_W / 2, say + 20, { 0.4, 0.9, 1.0 })
            local board_entries = self.game_state.players[self.show_blueprint_for_player + 1].board
            local entry = board_entries[#board_entries]
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
      self.pending_graveyard_return = nil
    end
    return
  end

  -- Handle deal_damage_x +/- button clicks before board hit-test
  if self.pending_damage_x then
    local pdx = self.pending_damage_x
    local function in_btn(b) return b and x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h end
    if in_btn(pdx.minus_btn) then
      pdx.x_amount = math.max(1, pdx.x_amount - 1)
      return
    end
    if in_btn(pdx.plus_btn) then
      pdx.x_amount = math.min(pdx.max_x, pdx.x_amount + 1)
      return
    end
  end

  local kind, pi, extra = board.hit_test(x, y, self.game_state, self.hand_y_offsets, self.local_player_index, {
    pending_attack_declarations = self.pending_attack_declarations,
    pending_block_assignments = self.pending_block_assignments,
    pending_attack_trigger_targets = self.pending_attack_trigger_targets,
  })
  local idx = extra  -- backwards compat: numeric index for hand_card, structure, etc.

  local combat_state = self.game_state.pendingCombat
  if combat_state and combat_state.stage == "AWAITING_ATTACK_TARGETS" then
    if kind ~= "pass" then
      if combat_state.attacker == self.local_player_index then
        local active_trigger = self:_active_attack_trigger_for_targeting(combat_state)
        if active_trigger and active_trigger.requires_target then
          if kind == "structure"
            and pi == combat_state.defender
            and idx and idx > 0
            and self:_is_pending_attack_trigger_target_legal(combat_state.defender, idx) then
            self:_set_pending_attack_trigger_target(active_trigger.attacker_board_index, active_trigger.ability_index, idx)
            sound.play("click")
          else
            sound.play("error")
          end
        elseif active_trigger and active_trigger.optional_activate then
          if kind == "structure"
            and pi == combat_state.attacker
            and idx and idx == active_trigger.attacker_board_index then
            local atk_player = self.game_state.players[combat_state.attacker + 1]
            if atk_player and abilities.can_pay_cost(atk_player.resources, active_trigger.cost or {}) then
              self:_set_pending_attack_trigger_activation(active_trigger.attacker_board_index, active_trigger.ability_index, true)
              sound.play("click")
            else
              sound.play("error")
            end
          else
            sound.play("error")
          end
        else
          sound.play("error")
        end
      end
      return
    end
  end

  -- If attack declarations are staged and player performs another action, clear staged attack arrows.
  if #self.pending_attack_declarations > 0 and kind and kind ~= "pass" and kind ~= "structure" then
    self:_clear_pending_attack_declarations()
  end
  if not kind then
    -- Clicked on empty space: cancel pending selection or deselect hand card
    self:_clear_pending_attack_declarations()
    if self.pending_play_unit then
      self.pending_play_unit = nil
      sound.play("click")
      return
    end
    if self.pending_sacrifice then
      self.pending_sacrifice = nil
      sound.play("click")
      return
    end
    if self.pending_upgrade then
      self.pending_upgrade = nil
      sound.play("click")
      return
    end
    if self.pending_hand_sacrifice then
      self.pending_hand_sacrifice = nil
      sound.play("click")
      return
    end
    if self.pending_monument then
      self.pending_monument = nil
      sound.play("click")
      return
    end
    if self.pending_counter_placement then
      self.pending_counter_placement = nil
      sound.play("click")
      return
    end
    if self.pending_damage_target then
      self.pending_damage_target = nil
      sound.play("click")
      return
    end
    if self.pending_damage_x then
      self.pending_damage_x = nil
      sound.play("click")
      return
    end
    if self.pending_spell_target then
      self.pending_spell_target = nil
      self.hand_selected_index = nil
      sound.play("click")
      return
    end
    if self.pending_play_spell then
      self.pending_play_spell = nil
      sound.play("click")
      return
    end
    if self.pending_discard_draw then
      self.pending_discard_draw = nil
      sound.play("click")
      return
    end
    if self.hand_selected_index then
      self.hand_selected_index = nil
      sound.play("click")
    end
    return
  end

  -- Hand card click during pending play_unit selection
  if kind == "hand_card" and self.pending_play_unit then
    local pending = self.pending_play_unit
    local is_eligible = false
    for _, ei in ipairs(pending.eligible_indices) do
      if ei == idx then is_eligible = true; break end
    end
    if is_eligible then
      local p = self.game_state.players[self.local_player_index + 1]
      local before_res = {}
      for k, v in pairs(p.resources) do before_res[k] = v end
      local result = self:dispatch_command({
        type = "PLAY_UNIT_FROM_HAND",
        player_index = self.local_player_index,
        source = pending.source,
        ability_index = pending.ability_index,
        hand_index = idx,
        fast_ability = pending.fast or false,
      })
      if result.ok then
        sound.play("coin")
        local pi_panel = self:player_to_panel(self.local_player_index)
        local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
        for _, c in ipairs(pending.cost or {}) do
          if before_res[c.type] and p.resources[c.type] < before_res[c.type] then
            local rb_x, rb_y = board.resource_bar_rect(pi_panel)
            popup.create("-" .. c.amount .. string.upper(string.sub(c.type, 1, 1)), rb_x + 25, rb_y - 4, { 1.0, 0.5, 0.25 })
          end
        end
        local card_id = result.meta and result.meta.card_id
        local unit_name = "Unit"
        if card_id then
          local ok_d, udef = pcall(cards.get_card_def, card_id)
          if ok_d and udef then unit_name = udef.name end
        end
        popup.create(unit_name .. " played!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.4, 0.9, 1.0 })
        self.hand_selected_index = nil
        self.pending_play_unit = nil
        while #self.hand_y_offsets > #p.hand do
          table.remove(self.hand_y_offsets)
        end
      else
        sound.play("error")
      end
    else
      sound.play("error")
    end
    return
  end

  -- Hand card click during pending play_spell selection (e.g. Alchemy Table)
  if kind == "hand_card" and self.pending_play_spell then
    local pending = self.pending_play_spell
    local is_eligible = false
    for _, ei in ipairs(pending.eligible_indices) do
      if ei == idx then is_eligible = true; break end
    end
    if is_eligible then
      local p = self.game_state.players[self.local_player_index + 1]
      local spell_id = p.hand[idx]
      local spell_def = nil
      if spell_id then
        local ok_s, sd = pcall(cards.get_card_def, spell_id)
        if ok_s and sd then spell_def = sd end
      end
      -- Check if this spell has a targeted on_cast ability
      local targeted_ab = nil
      if spell_def then
        for _, sab in ipairs(spell_def.abilities or {}) do
          if sab.trigger == "on_cast" and sab.effect == "deal_damage" then targeted_ab = sab; break end
        end
      end
      if targeted_ab then
        local args = targeted_ab.effect_args or {}
        local opponent_pi = 1 - self.local_player_index
        local op = self.game_state.players[opponent_pi + 1]
        local eligible = {}
        for si, entry in ipairs(op.board) do
          local ok_d, edef = pcall(cards.get_card_def, entry.card_id)
          if ok_d and edef then
            if args.target == "unit" and (edef.kind == "Unit" or edef.kind == "Worker") then
              eligible[#eligible + 1] = si
            elseif args.target == "any" then
              eligible[#eligible + 1] = si
            end
          end
        end
        if #eligible == 0 then
          sound.play("error")
          return
        end
        self.pending_spell_target = {
          hand_index = idx,
          effect_args = args,
          eligible_player_index = opponent_pi,
          eligible_board_indices = eligible,
          via_ability_source = pending.source,
          via_ability_ability_index = pending.ability_index,
          fast = pending.fast or false,
        }
        self.pending_play_spell = nil
        sound.play("click")
      else
        -- Non-targeted: cast immediately via ability
        local before_res = {}
        for k, v in pairs(p.resources) do before_res[k] = v end
        local result = self:dispatch_command({
          type = "PLAY_SPELL_VIA_ABILITY",
          player_index = self.local_player_index,
          source = pending.source,
          ability_index = pending.ability_index,
          hand_index = idx,
          fast_ability = pending.fast or false,
        })
        if result.ok then
          sound.play("coin")
          local pi_panel = self:player_to_panel(self.local_player_index)
          local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
          for _, c in ipairs(pending.cost or {}) do
            if before_res[c.type] and p.resources[c.type] < before_res[c.type] then
              local rb_x, rb_y = board.resource_bar_rect(pi_panel)
              popup.create("-" .. c.amount .. string.upper(string.sub(c.type, 1, 1)), rb_x + 25, rb_y - 4, { 1.0, 0.5, 0.25 })
            end
          end
          local sname = spell_def and spell_def.name or "Spell"
          popup.create(sname .. "!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.7, 0.85, 1.0 })
          self.pending_play_spell = nil
          while #self.hand_y_offsets > #p.hand do table.remove(self.hand_y_offsets) end
        else
          sound.play("error")
        end
      end
    else
      sound.play("error")
    end
    return
  end

  -- Hand card click during pending discard_draw selection (e.g. Hospital)
  if kind == "hand_card" and self.pending_discard_draw then
    local pending = self.pending_discard_draw
    local selected = pending.selected_set
    -- Toggle selection
    if selected[idx] then
      selected[idx] = nil
      sound.play("click")
    else
      local count = 0
      for _ in pairs(selected) do count = count + 1 end
      if count >= pending.required_count then
        sound.play("error")
      else
        selected[idx] = true
        sound.play("click")
        -- Auto-dispatch when required count reached
        count = count + 1
        if count == pending.required_count then
          local indices = {}
          for hi in pairs(selected) do indices[#indices + 1] = hi end
          local p = self.game_state.players[self.local_player_index + 1]
          local result = self:dispatch_command({
            type = "DISCARD_DRAW_HAND",
            player_index = self.local_player_index,
            source = pending.source,
            ability_index = pending.ability_index,
            hand_indices = indices,
          })
          if result.ok then
            sound.play("coin")
            local pi_panel = self:player_to_panel(self.local_player_index)
            local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
            popup.create("Drew " .. pending.draw_count .. "!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.9, 0.65, 0.3 })
            self.pending_discard_draw = nil
            while #self.hand_y_offsets > #p.hand do
              table.remove(self.hand_y_offsets)
            end
          else
            sound.play("error")
            self.pending_discard_draw = nil
          end
        end
      end
    end
    return
  end

  -- Worker click during pending hand sacrifice selection (e.g. Loving Family)
  if self.pending_hand_sacrifice and (kind == "worker_unassigned" or kind == "worker_left" or kind == "worker_right" or kind == "structure_worker" or kind == "unassigned_pool") then
    local pending = self.pending_hand_sacrifice
    pending.selected_targets[#pending.selected_targets + 1] = { kind = kind, extra = idx }

    if #pending.selected_targets >= pending.required_count then
      local p = self.game_state.players[self.local_player_index + 1]
      local result = self:dispatch_command({
        type = "PLAY_FROM_HAND_WITH_SACRIFICES",
        player_index = self.local_player_index,
        hand_index = pending.hand_index,
        sacrifice_targets = pending.selected_targets,
      })
      if result.ok then
        sound.play("coin")
        shake.trigger(4, 0.15)
        local pi_panel = self:player_to_panel(self.local_player_index)
        local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
        popup.create("-" .. pending.required_count .. " Workers", px_b + pw_b * 0.5, py_b + ph_b - 80, { 1.0, 0.5, 0.25 })
        popup.create("Loving Family played!", px_b + pw_b * 0.5, py_b + ph_b - 110, { 0.9, 0.8, 0.2 })
        self.hand_selected_index = nil
        self.pending_hand_sacrifice = nil
        while #self.hand_y_offsets > #p.hand do
          table.remove(self.hand_y_offsets)
        end
      else
        self.pending_hand_sacrifice = nil
        sound.play("error")
      end
    else
      sound.play("click")
    end
    return
  end

  -- Worker click during pending sacrifice selection
  if self.pending_sacrifice and (kind == "worker_unassigned" or kind == "worker_left" or kind == "worker_right" or kind == "structure_worker" or kind == "unassigned_pool") then
    local pending = self.pending_sacrifice
    local p = self.game_state.players[self.local_player_index + 1]
    local result = self:dispatch_command({
      type = "SACRIFICE_UNIT",
      player_index = self.local_player_index,
      source = pending.source,
      ability_index = pending.ability_index,
      target_worker = kind,
      target_worker_extra = idx,
    })
    if result.ok then
      sound.play("coin")
      local pi_panel = self:player_to_panel(self.local_player_index)
      local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
      local args = pending.effect_args or {}
      if args.resource then
        popup.create("+" .. (args.amount or 1) .. " " .. args.resource, px_b + pw_b / 2, py_b + 8, { 0.9, 0.2, 0.3 })
      end
      popup.create("Worker sacrificed!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.9, 0.3, 0.3 })
      self.pending_sacrifice = nil
    else
      sound.play("error")
    end
    return
  end

  -- Board tile click during pending monument selection
  if kind == "structure" and self.pending_monument then
    local pending = self.pending_monument
    local target_si = idx
    local is_eligible = false
    for _, ei in ipairs(pending.eligible_indices) do
      if ei == target_si then is_eligible = true; break end
    end
    if is_eligible then
      local p = self.game_state.players[self.local_player_index + 1]
      local hand_card_id = p.hand[pending.hand_index]
      local hand_card_def = nil
      local card_name = "Card"
      if hand_card_id then
        local ok_c, cdef = pcall(cards.get_card_def, hand_card_id)
        if ok_c and cdef then card_name = cdef.name; hand_card_def = cdef end
      end

      -- If the hand card is a Spell, use the spell cast flow (not board placement)
      if hand_card_def and hand_card_def.kind == "Spell" then
        local targeted_ab = nil
        for _, ab in ipairs(hand_card_def.abilities or {}) do
          if ab.trigger == "on_cast" and ab.effect == "deal_damage" then targeted_ab = ab; break end
        end
        if targeted_ab then
          local args = targeted_ab.effect_args or {}
          local opponent_pi = 1 - self.local_player_index
          local op = self.game_state.players[opponent_pi + 1]
          local eligible = {}
          for si, entry in ipairs(op.board) do
            local ok_d, edef = pcall(cards.get_card_def, entry.card_id)
            if ok_d and edef then
              if args.target == "unit" and (edef.kind == "Unit" or edef.kind == "Worker") then
                eligible[#eligible + 1] = si
              elseif args.target == "any" then
                eligible[#eligible + 1] = si
              end
            end
          end
          if #eligible == 0 then
            sound.play("error")
            return
          end
          self.pending_spell_target = {
            hand_index = pending.hand_index,
            effect_args = args,
            eligible_player_index = opponent_pi,
            eligible_board_indices = eligible,
            monument_board_index = target_si,
          }
          self.pending_monument = nil
          sound.play("click")
          return
        else
          -- Non-targeted monument spell
          local result = self:dispatch_command({
            type = "PLAY_SPELL_FROM_HAND",
            player_index = self.local_player_index,
            hand_index = pending.hand_index,
            monument_board_index = target_si,
          })
          if result.ok then
            sound.play("coin")
            local pi_panel = self:player_to_panel(self.local_player_index)
            local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
            popup.create(card_name .. "!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.7, 0.85, 1.0 })
            self.pending_monument = nil
            self.hand_selected_index = nil
            while #self.hand_y_offsets > #p.hand do table.remove(self.hand_y_offsets) end
          else
            sound.play("error")
          end
          return
        end
      end

      -- Default: non-spell monument card (place on board)
      local result = self:dispatch_command({
        type = "PLAY_MONUMENT_FROM_HAND",
        player_index = self.local_player_index,
        hand_index = pending.hand_index,
        monument_board_index = target_si,
      })
      if result.ok then
        sound.play("coin")
        local pi_panel = self:player_to_panel(self.local_player_index)
        local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
        popup.create(card_name .. " played!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.95, 0.78, 0.2 })
        self.pending_monument = nil
        self.hand_selected_index = nil
        while #self.hand_y_offsets > #p.hand do
          table.remove(self.hand_y_offsets)
        end
      else
        sound.play("error")
      end
    else
      sound.play("error")
    end
    return
  end

  -- Board tile click during pending sacrifice selection
  if kind == "structure" and self.pending_sacrifice then
    local pending = self.pending_sacrifice
    local target_si = idx
    local is_eligible = false
    for _, ei in ipairs(pending.eligible_board_indices) do
      if ei == target_si then is_eligible = true; break end
    end
    if is_eligible then
      local p = self.game_state.players[self.local_player_index + 1]
      local sacrificed_entry = p.board[target_si]
      local sacrificed_name = "Unit"
      if sacrificed_entry then
        local s_ok, s_def = pcall(cards.get_card_def, sacrificed_entry.card_id)
        if s_ok and s_def then sacrificed_name = s_def.name end
      end
      local result = self:dispatch_command({
        type = "SACRIFICE_UNIT",
        player_index = self.local_player_index,
        source = pending.source,
        ability_index = pending.ability_index,
        target_board_index = target_si,
      })
      if result.ok then
        sound.play("coin")
        local pi_panel = self:player_to_panel(self.local_player_index)
        local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
        local args = pending.effect_args or {}
        if args.resource then
          popup.create("+" .. (args.amount or 1) .. " " .. args.resource, px_b + pw_b / 2, py_b + 8, { 0.9, 0.2, 0.3 })
        end
        popup.create(sacrificed_name .. " sacrificed!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.9, 0.3, 0.3 })
        self.pending_sacrifice = nil
      else
        sound.play("error")
      end
    else
      sound.play("error")
    end
    return
  end

  -- Board tile click during deal_damage targeting
  if kind == "structure" and self.pending_damage_target then
    local pending = self.pending_damage_target
    local target_si = idx
    local is_global = pending.eligible_board_indices_by_player ~= nil

    local function fire_damage(target_pi, board_idx, is_base)
      local result = self:dispatch_command({
        type = "DEAL_DAMAGE_TO_TARGET",
        player_index = self.local_player_index,
        source = pending.source,
        ability_index = pending.ability_index,
        target_player_index = target_pi,
        target_board_index = board_idx,
        target_is_base = is_base or false,
        fast_ability = pending.fast or false,
      })
      if result.ok then
        local damage = pending.effect_args.damage or 0
        local tgt_panel = self:player_to_panel(target_pi)
        local px_b, py_b, pw_b, ph_b = board.panel_rect(tgt_panel)
        popup.create("-" .. damage, px_b + pw_b / 2, py_b + ph_b / 2, { 0.95, 0.35, 0.25 })
        sound.play("coin")
      else
        sound.play("error")
      end
      self.pending_damage_target = nil
    end

    -- Base click (idx == 0)
    if target_si == 0 then
      if pending.eligible_base_player_indices and pending.eligible_base_player_indices[pi] then
        fire_damage(pi, nil, true)
      else
        sound.play("error")
      end
      return
    end

    -- Board card click
    if is_global then
      local eligible = pending.eligible_board_indices_by_player[pi] or {}
      local is_eligible = false
      for _, ei in ipairs(eligible) do
        if ei == target_si then is_eligible = true; break end
      end
      if is_eligible then
        fire_damage(pi, target_si, false)
      else
        sound.play("error")
      end
      return
    else
      -- Legacy single-player targeting
      if pi == pending.eligible_player_index then
        local is_eligible = false
        for _, ei in ipairs(pending.eligible_board_indices) do
          if ei == target_si then is_eligible = true; break end
        end
        if is_eligible then
          fire_damage(pending.eligible_player_index, target_si, false)
        else
          sound.play("error")
        end
        return
      end
      -- Not the eligible player - fall through to other handlers
    end
  end

  -- Board tile click to resolve a targeted spell
  if kind == "structure" and self.pending_spell_target and pi == self.pending_spell_target.eligible_player_index then
    local pending = self.pending_spell_target
    local target_si = idx
    local is_eligible = false
    for _, ei in ipairs(pending.eligible_board_indices) do
      if ei == target_si then is_eligible = true; break end
    end
    if is_eligible then
      local cmd_type = pending.via_ability_source and "PLAY_SPELL_VIA_ABILITY" or "PLAY_SPELL_FROM_HAND"
      local result = self:dispatch_command({
        type = cmd_type,
        player_index = self.local_player_index,
        source = pending.via_ability_source,
        ability_index = pending.via_ability_ability_index,
        hand_index = pending.hand_index,
        target_player_index = pending.eligible_player_index,
        target_board_index = target_si,
        monument_board_index = pending.monument_board_index,
        fast_ability = pending.fast or false,
      })
      if result.ok then
        local damage = pending.effect_args.damage or 0
        local opp_panel = self:player_to_panel(pending.eligible_player_index)
        local px_b, py_b, pw_b, ph_b = board.panel_rect(opp_panel)
        popup.create("-" .. damage, px_b + pw_b / 2, py_b + ph_b / 2, { 0.95, 0.35, 0.25 })
        sound.play("coin")
      else
        sound.play("error")
      end
      self.pending_spell_target = nil
      self.hand_selected_index = nil
    else
      sound.play("error")
    end
    return
  end

  -- Enemy board tile click during deal_damage_x targeting (Flying Machine)
  if kind == "structure" and self.pending_damage_x and pi == self.pending_damage_x.eligible_player_index then
    local pending = self.pending_damage_x
    local target_si = idx
    local is_eligible = false
    for _, ei in ipairs(pending.eligible_board_indices) do
      if ei == target_si then is_eligible = true; break end
    end
    if is_eligible then
      local result = self:dispatch_command({
        type = "DEAL_DAMAGE_X_TO_TARGET",
        player_index = self.local_player_index,
        source = pending.source,
        ability_index = pending.ability_index,
        target_player_index = pending.eligible_player_index,
        target_board_index = target_si,
        x_amount = pending.x_amount,
        fast_ability = pending.fast or false,
      })
      if result.ok then
        local opp_panel = self:player_to_panel(pending.eligible_player_index)
        local px_b, py_b, pw_b, ph_b = board.panel_rect(opp_panel)
        popup.create("-" .. pending.x_amount, px_b + pw_b / 2, py_b + ph_b / 2, { 0.95, 0.35, 0.25 })
        sound.play("coin")
      else
        sound.play("error")
      end
      self.pending_damage_x = nil
    else
      sound.play("error")
    end
    return
  end

  -- Board tile click during counter placement targeting
  if kind == "structure" and self.pending_counter_placement then
    local pending = self.pending_counter_placement
    local target_si = idx
    local is_eligible = false
    for _, ei in ipairs(pending.eligible_board_indices) do
      if ei == target_si then is_eligible = true; break end
    end
    if is_eligible then
      local result = self:dispatch_command({
        type = "PLACE_COUNTER_ON_TARGET",
        player_index = self.local_player_index,
        source = pending.source,
        ability_index = pending.ability_index,
        target_board_index = target_si,
        fast_ability = pending.fast or false,
      })
      local cp_args = pending.effect_args or {}
      if result.ok then
        local pi_panel = self:player_to_panel(self.local_player_index)
        local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
        local amount = cp_args.amount or 2
        local cname = cp_args.counter or "knowledge"
        popup.create("+" .. amount .. " " .. cname, px_b + pw_b / 2, py_b + ph_b - 80, { 0.35, 0.55, 0.95 })
        sound.play("coin")
      else
        sound.play("error")
      end
      self.pending_counter_placement = nil
    else
      sound.play("error")
    end
    return
  end

  -- Click during Fighting Pits sacrifice-upgrade flow
  if self.pending_upgrade then
    local pending = self.pending_upgrade
    local p = self.game_state.players[self.local_player_index + 1]
    local required_subtypes = upgrade_required_subtypes(pending.effect_args)
    local function upgrade_error(msg)
      local pi_panel = self:player_to_panel(self.local_player_index)
      local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
      popup.create(msg, px_b + pw_b / 2, py_b + ph_b - 118, { 1.0, 0.45, 0.35 })
      sound.play("error")
    end

    if pending.stage == "sacrifice" and (kind == "worker_unassigned" or kind == "worker_left" or kind == "worker_right" or kind == "structure_worker" or kind == "unassigned_pool") then
      if pending.eligible_worker_sacrifice ~= true then
        upgrade_error("No worker upgrade available")
        return
      end
      local eligible = find_upgrade_hand_indices(p, pending.effect_args, 1)
      if #eligible == 0 then
        pending.eligible_worker_sacrifice = false
        upgrade_error("No Tier 1 upgrade in hand")
        return
      end
      pending.sacrifice_target = { target_worker = kind, target_worker_extra = idx }
      pending.stage = "hand"
      pending.eligible_hand_indices = eligible
      sound.play("click")
      return
    end

    if pending.stage == "sacrifice" and (kind == "structure" or kind == "activate_ability" or kind == "ability_hover" or kind == "unit_row") then
      local target_si = nil
      if kind == "structure" then
        target_si = idx
      elseif type(extra) == "table" and extra.source == "board" then
        target_si = extra.board_index
      end
      if pi == self.local_player_index then
        local nearest_target = find_pending_upgrade_target_by_click(
          self.game_state,
          self.local_player_index,
          pending.eligible_board_indices,
          x, y,
          {
            pending_attack_declarations = self.pending_attack_declarations,
            pending_block_assignments = self.pending_block_assignments,
            pending_attack_trigger_targets = self.pending_attack_trigger_targets,
          }
        )
        if nearest_target and nearest_target > 0 then
          target_si = nearest_target
        end
      end
      if (not target_si or target_si <= 0) and pi == self.local_player_index then
        target_si = find_pending_upgrade_target_by_click(
          self.game_state,
          self.local_player_index,
          pending.eligible_board_indices,
          x, y,
          {
            pending_attack_declarations = self.pending_attack_declarations,
            pending_block_assignments = self.pending_block_assignments,
            pending_attack_trigger_targets = self.pending_attack_trigger_targets,
          }
        )
      end
      if not target_si or target_si <= 0 then
        upgrade_error("Pick a highlighted ally")
        return
      end

      local entry = p.board[target_si]
      local ok_t, tdef = false, nil
      if entry then
        ok_t, tdef = pcall(cards.get_card_def, entry.card_id)
      end
      if not ok_t or not tdef or tdef.kind == "Structure" or tdef.kind == "Artifact" or not has_any_subtype(tdef, required_subtypes) then
        local bad_name = "unknown"
        if entry then
          local ok_bad, bad_def = pcall(cards.get_card_def, entry.card_id)
          if ok_bad and bad_def and bad_def.name then bad_name = bad_def.name end
        end
        upgrade_error("Target mismatch: " .. bad_name)
        return
      end
      local next_tier = (tdef.tier or 0) + 1
      local eligible = find_upgrade_hand_indices(p, pending.effect_args, next_tier)
      if #eligible == 0 then
        upgrade_error("No matching upgrade in hand")
        return
      end
      if not has_index(pending.eligible_board_indices, target_si) then
        pending.eligible_board_indices[#pending.eligible_board_indices + 1] = target_si
      end
      pending.sacrifice_target = { target_board_index = target_si }
      pending.stage = "hand"
      pending.eligible_hand_indices = eligible
      sound.play("click")
      return
    end

    if pending.stage == "hand" and kind == "hand_card" then
      local is_eligible = false
      for _, ei in ipairs(pending.eligible_hand_indices or {}) do if ei == idx then is_eligible = true; break end end
      if not is_eligible then sound.play("error"); return end

      local payload = {
        type = "SACRIFICE_UPGRADE_PLAY",
        player_index = self.local_player_index,
        source = pending.source,
        ability_index = pending.ability_index,
        hand_index = idx,
      }
      if pending.sacrifice_target.target_board_index then
        payload.target_board_index = pending.sacrifice_target.target_board_index
      else
        payload.target_worker = pending.sacrifice_target.target_worker
        payload.target_worker_extra = pending.sacrifice_target.target_worker_extra
      end
      local result = self:dispatch_command(payload)
      if result.ok then
        sound.play("coin")
        local pi_panel = self:player_to_panel(self.local_player_index)
        local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
        popup.create("Fighting Pits upgrade!", px_b + pw_b / 2, py_b + ph_b - 90, { 0.9, 0.3, 0.3 })
        self.pending_upgrade = nil
        self.hand_selected_index = nil
        while #self.hand_y_offsets > #p.hand do table.remove(self.hand_y_offsets) end
      else
        local pi_panel = self:player_to_panel(self.local_player_index)
        local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
        popup.create(pretty_reason(result.reason), px_b + pw_b / 2, py_b + ph_b - 118, { 1.0, 0.45, 0.35 })
        sound.play("error")
      end
      return
    end

    -- While a sacrifice-upgrade flow is active, non-matching clicks should
    -- not silently fall through into drag/combat handlers.
    if pending.stage == "sacrifice" or pending.stage == "hand" then
      sound.play("error")
      return
    end
  end

  -- Hand card click: toggle selection or play from hand
  if kind == "hand_card" then
    if self.hand_selected_index == idx then
      -- Clicking selected card: check if it can be played from hand (sacrifice ability)
      local local_p = self.game_state.players[pi + 1]
      local card_id = local_p.hand[idx]
      if card_id and pi == self.game_state.activePlayer then
        local card_ok, card_def = pcall(cards.get_card_def, card_id)
        if card_ok and card_def then
          local sac_ab = nil
          if card_def.abilities then
            for _, ab in ipairs(card_def.abilities) do
              if ab.type == "static" and ab.effect == "play_cost_sacrifice" then sac_ab = ab; break end
            end
          end
          if sac_ab then
            local sacrifice_count = sac_ab.effect_args and sac_ab.effect_args.sacrifice_count or 2
            if (local_p.totalWorkers or 0) >= sacrifice_count then
              self.pending_hand_sacrifice = {
                hand_index = idx,
                required_count = sacrifice_count,
                selected_targets = {},
              }
              sound.play("click")
              return
            end
          end
          -- Check for monument cost ability
          local mon_ab = nil
          if card_def.abilities then
            for _, ab in ipairs(card_def.abilities) do
              if ab.type == "static" and ab.effect == "monument_cost" then mon_ab = ab; break end
            end
          end
          if mon_ab then
            local min_counters = mon_ab.effect_args and mon_ab.effect_args.min_counters or 1
            local eligible = {}
            for i, entry in ipairs(local_p.board) do
              local ok_m, mon_def = pcall(cards.get_card_def, entry.card_id)
              if ok_m and mon_def and mon_def.keywords then
                local is_monument = false
                for _, kw in ipairs(mon_def.keywords) do
                  if kw == "monument" then is_monument = true; break end
                end
                if is_monument and unit_stats.counter_count(entry.state or {}, "wonder") >= min_counters then
                  eligible[#eligible + 1] = i
                end
              end
            end
            if #eligible > 0 then
              self.pending_monument = {
                hand_index = idx,
                min_counters = min_counters,
                eligible_indices = eligible,
              }
              sound.play("click")
              return
            end
          end
          -- Check for Spell cast
          if card_def.kind == "Spell" then
            if abilities.can_pay_cost(local_p.resources, card_def.costs) then
              -- Find first on_cast ability that needs a target
              local targeted_ab = nil
              for _, ab in ipairs(card_def.abilities or {}) do
                if ab.trigger == "on_cast" and ab.effect == "deal_damage" then
                  targeted_ab = ab; break
                end
              end
              if targeted_ab then
                local args = targeted_ab.effect_args or {}
                local opponent_pi = 1 - pi
                local op = self.game_state.players[opponent_pi + 1]
                local eligible = {}
                for si, entry in ipairs(op.board) do
                  local ok_d, edef = pcall(cards.get_card_def, entry.card_id)
                  if ok_d and edef then
                    if args.target == "unit" and (edef.kind == "Unit" or edef.kind == "Worker") then
                      eligible[#eligible + 1] = si
                    elseif args.target == "any" then
                      eligible[#eligible + 1] = si
                    end
                  end
                end
                if #eligible == 0 then
                  sound.play("error")
                  self.hand_selected_index = nil
                  return
                end
                self.pending_spell_target = {
                  hand_index = idx,
                  effect_args = args,
                  eligible_player_index = opponent_pi,
                  eligible_board_indices = eligible,
                }
                sound.play("click")
                return
              else
                -- Non-targeted: cast immediately
                local result = self:dispatch_command({
                  type = "PLAY_SPELL_FROM_HAND",
                  player_index = pi,
                  hand_index = idx,
                })
                if result.ok then
                  local pi_panel = self:player_to_panel(pi)
                  local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
                  popup.create(card_def.name .. "!", px_b + pw_b / 2, py_b + 40, { 0.7, 0.85, 1.0 })
                  sound.play("coin")
                else
                  sound.play("error")
                end
                self.hand_selected_index = nil
                return
              end
            else
              sound.play("error")
              self.hand_selected_index = nil
              return
            end
          end
        end
      end
      -- Deselect if not playable
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
      self:dispatch_command({ type = "END_TURN", player_index = pi })
      -- State now includes START_TURN effects from the host
      new_active = self.game_state.activePlayer
      p = self.game_state.players[new_active + 1]
      for _, key in ipairs(config.resource_types) do
        after[key] = p.resources[key] or 0
      end
    else
      -- Local mode: send END_TURN and START_TURN separately
      self:dispatch_command({ type = "END_TURN", player_index = pi })
      new_active = self.game_state.activePlayer
      p = self.game_state.players[new_active + 1]
      for _, key in ipairs(config.resource_types) do
        before[key] = p.resources[key] or 0
      end
      self:dispatch_command({ type = "START_TURN", player_index = new_active })
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
    -- Clear hand selection and pending state on turn change
    self.hand_selected_index = nil
    self.pending_play_unit = nil
    self.pending_sacrifice = nil
    self.pending_upgrade = nil
    self.pending_monument = nil
    self.pending_graveyard_return = nil
    self.pending_discard_draw = nil
    self:_clear_pending_attack_declarations()
    self:_clear_pending_attack_trigger_targets()
    self.pending_block_assignments = {}
    self.pending_damage_orders = {}
    -- Show turn banner
    self.turn_banner_timer = 1.2
    self.turn_banner_text = (self.game_state.activePlayer == self.local_player_index) and "Your Turn" or "Opponent's Turn"
    return
  end

  if kind == "pass" then
    self:_prune_invalid_pending_attacks()

    local c = self.game_state.pendingCombat
    if pi == self.game_state.activePlayer and pi == self.local_player_index and #self.pending_attack_declarations > 0 then
      local result = self:dispatch_command({
        type = "DECLARE_ATTACKERS",
        player_index = pi,
        declarations = self.pending_attack_declarations,
      })
      if result.ok then
        self:_clear_pending_attack_declarations()
        self:_clear_pending_attack_trigger_targets()
        self.pending_block_assignments = {}
        self.pending_damage_orders = {}
        sound.play("whoosh")
      else
        sound.play("error")
      end
      return
    end

    if c and c.stage == "AWAITING_ATTACK_TARGETS" and c.attacker == self.local_player_index then
      local target_payload = self:_build_attack_trigger_target_payload(c)
      local result = self:dispatch_command({
        type = "ASSIGN_ATTACK_TRIGGER_TARGETS",
        player_index = self.local_player_index,
        targets = target_payload,
      })
      if result.ok then
        self:_clear_pending_attack_trigger_targets()
        sound.play("whoosh")
      else
        sound.play("error")
      end
      return
    end

    if c and c.stage == "DECLARED" and c.defender == self.local_player_index then
      local result = self:dispatch_command({
        type = "ASSIGN_BLOCKERS",
        player_index = self.local_player_index,
        assignments = self.pending_block_assignments,
      })
      if result.ok then
        self:_clear_pending_attack_trigger_targets()
        self.pending_block_assignments = {}
        self.pending_damage_orders = {}
        local pending = self.game_state.pendingCombat
        if pending and pending.stage == "AWAITING_DAMAGE_ORDER" then
          sound.play("whoosh")
        else
          local resolve_result = self:dispatch_command({ type = "RESOLVE_COMBAT", player_index = c.attacker })
          if resolve_result.ok then
            sound.play("build")
          else
            sound.play("error")
          end
        end
      else
        sound.play("error")
      end
      return
    end

    if c and c.stage == "AWAITING_DAMAGE_ORDER" and c.attacker == self.local_player_index then
      local orders = self:_build_default_damage_orders(c)
      local order_result = self:dispatch_command({
        type = "ASSIGN_DAMAGE_ORDER",
        player_index = self.local_player_index,
        orders = orders,
      })
      if order_result.ok then
        self.pending_damage_orders = {}
        local resolve_result = self:dispatch_command({ type = "RESOLVE_COMBAT", player_index = self.local_player_index })
        if resolve_result.ok then
          sound.play("build")
        else
          sound.play("error")
        end
      else
        sound.play("error")
      end
      return
    end

    if c and c.stage == "BLOCKERS_ASSIGNED" and c.attacker == self.local_player_index then
      local result = self:dispatch_command({ type = "RESOLVE_COMBAT", player_index = self.local_player_index })
      if result.ok then
        self.pending_damage_orders = {}
        sound.play("build")
      else
        sound.play("error")
      end
      return
    end
    return
  end

  local _cbt = self.game_state.pendingCombat
  local _in_blocker_window = _cbt and _cbt.stage == "DECLARED"
    and (pi == _cbt.attacker or pi == _cbt.defender)
  if kind == "activate_ability" and (pi == self.game_state.activePlayer or _in_blocker_window) then
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
        -- During the blocker window only Fast abilities are permitted.
        if _in_blocker_window and not (pi == self.game_state.activePlayer) and not ab.fast then
          sound.play("error")
          return
        end
        -- Two-step flow for play_unit abilities
        if ab.effect == "play_unit" then
          local eligible = abilities.find_matching_hand_indices(p, ab.effect_args)
          if #eligible == 0 then
            sound.play("error")
            return
          elseif #eligible == 1 then
            -- Only one match: auto-play immediately
            local before_res = {}
            for k, v in pairs(p.resources) do before_res[k] = v end
            local result = self:dispatch_command({
              type = "PLAY_UNIT_FROM_HAND",
              player_index = pi,
              source = { type = info.source, index = info.board_index },
              ability_index = info.ability_index,
              hand_index = eligible[1],
              fast_ability = ab.fast or false,
            })
            if result.ok then
              sound.play("coin")
              local pi_panel = self:player_to_panel(pi)
              local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
              for _, c in ipairs(ab.cost) do
                if before_res[c.type] and p.resources[c.type] < before_res[c.type] then
                  local rb_x, rb_y = board.resource_bar_rect(pi_panel)
                  popup.create("-" .. c.amount .. string.upper(string.sub(c.type, 1, 1)), rb_x + 25, rb_y - 4, { 1.0, 0.5, 0.25 })
                end
              end
              local card_id = result.meta and result.meta.card_id
              local unit_name = "Unit"
              if card_id then
                local ok_d, udef = pcall(cards.get_card_def, card_id)
                if ok_d and udef then unit_name = udef.name end
              end
              popup.create(unit_name .. " played!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.4, 0.9, 1.0 })
              self.hand_selected_index = nil
              self.pending_play_unit = nil
              while #self.hand_y_offsets > #p.hand do
                table.remove(self.hand_y_offsets)
              end
            end
            return
          else
            -- Multiple matches: enter pending selection mode
            self.pending_play_unit = {
              source = { type = info.source, index = info.board_index },
              ability_index = info.ability_index,
              effect_args = ab.effect_args,
              eligible_indices = eligible,
              cost = ab.cost,
              fast = ab.fast or false,
            }
            self.hand_selected_index = nil
            sound.play("click")
            return
          end
        end

        -- Two-step flow for sacrifice_upgrade abilities (Fighting Pits)
        if ab.effect == "sacrifice_upgrade" then
          local warrior_indices = find_upgrade_board_sacrifice_indices(p, ab.effect_args)
          local has_workers = (p.totalWorkers or 0) > 0
          local can_sac_workers = has_workers and (#find_upgrade_hand_indices(p, ab.effect_args, 1) > 0)
          if #warrior_indices == 0 and not can_sac_workers then
            sound.play("error")
            return
          end
          self.pending_upgrade = {
            source = { type = info.source, index = info.board_index },
            ability_index = info.ability_index,
            effect_args = ab.effect_args,
            stage = "sacrifice",
            sacrifice_target = nil,
            eligible_hand_indices = nil,
            eligible_board_indices = warrior_indices,
            eligible_worker_sacrifice = can_sac_workers,
          }
          self.hand_selected_index = nil
          self.pending_play_unit = nil
          self.pending_sacrifice = nil
          sound.play("click")
          return
        end

        -- Two-step flow for sacrifice_produce abilities
        if ab.effect == "sacrifice_produce" then
          local eligible = abilities.find_sacrifice_targets(p, ab.effect_args)
          local has_worker_to_sacrifice = (p.totalWorkers or 0) > 0
          if #eligible == 0 and not has_worker_to_sacrifice then
            sound.play("error")
            return
          end
          self.pending_sacrifice = {
            source = { type = info.source, index = info.board_index },
            ability_index = info.ability_index,
            effect_args = ab.effect_args,
            eligible_board_indices = eligible,
          }
          self.hand_selected_index = nil
          self.pending_play_unit = nil
          sound.play("click")
          return
        end

        -- Two-step flow for deal_damage abilities (Alchemist)
        if ab.effect == "deal_damage" then
          local source_entry = info.source == "board" and p.board[info.board_index] or nil
          if ab.rest and source_entry and source_entry.state and source_entry.state.rested then
            sound.play("error")
            return
          end
          if not abilities.can_pay_cost(p.resources, ab.cost) then
            sound.play("error")
            return
          end
          local source_key = (info.source == "board" and "board:" .. info.board_index or "base") .. ":" .. info.ability_index
          local used_key = tostring(pi) .. ":" .. source_key
          if ab.once_per_turn and self.game_state.activatedUsedThisTurn[used_key] then
            sound.play("error")
            return
          end
          local args = ab.effect_args or {}
          local opponent_pi = 1 - pi
          local op = self.game_state.players[opponent_pi + 1]
          if args.target == "global" then
            -- Can target any unit/structure on either board, and either base
            local own_eligible, opp_eligible = {}, {}
            for si, entry in ipairs(p.board) do
              local ok_d, edef = pcall(cards.get_card_def, entry.card_id)
              if ok_d and edef then own_eligible[#own_eligible + 1] = si end
            end
            for si, entry in ipairs(op.board) do
              local ok_d, edef = pcall(cards.get_card_def, entry.card_id)
              if ok_d and edef then opp_eligible[#opp_eligible + 1] = si end
            end
            self.pending_damage_target = {
              source = { type = info.source, index = info.board_index },
              ability_index = info.ability_index,
              effect_args = args,
              eligible_board_indices_by_player = { [pi] = own_eligible, [opponent_pi] = opp_eligible },
              eligible_base_player_indices = { [pi] = true, [opponent_pi] = true },
              fast = ab.fast or false,
            }
          else
            local eligible = {}
            for si, entry in ipairs(op.board) do
              local ok_d, edef = pcall(cards.get_card_def, entry.card_id)
              if ok_d and edef then
                if args.target == "unit" and (edef.kind == "Unit" or edef.kind == "Worker") then
                  eligible[#eligible + 1] = si
                elseif args.target == "any" then
                  eligible[#eligible + 1] = si
                end
              end
            end
            if #eligible == 0 then
              sound.play("error")
              return
            end
            self.pending_damage_target = {
              source = { type = info.source, index = info.board_index },
              ability_index = info.ability_index,
              effect_args = args,
              eligible_player_index = opponent_pi,
              eligible_board_indices = eligible,
              fast = ab.fast or false,
            }
          end
          sound.play("click")
          return
        end

        -- Two-step flow for play_spell abilities (Alchemy Table)
        if ab.effect == "play_spell" then
          local eligible = abilities.find_matching_spell_hand_indices(p, ab.effect_args)
          if #eligible == 0 then
            sound.play("error")
            return
          end
          local function do_cast_spell(hand_idx)
            local spell_id = p.hand[hand_idx]
            local spell_def = nil
            if spell_id then
              local ok_s, sd = pcall(cards.get_card_def, spell_id)
              if ok_s and sd then spell_def = sd end
            end
            local targeted_ab = nil
            if spell_def then
              for _, sab in ipairs(spell_def.abilities or {}) do
                if sab.trigger == "on_cast" and sab.effect == "deal_damage" then targeted_ab = sab; break end
              end
            end
            if targeted_ab then
              local args = targeted_ab.effect_args or {}
              local opponent_pi = 1 - pi
              local op = self.game_state.players[opponent_pi + 1]
              local dmg_eligible = {}
              for si, entry in ipairs(op.board) do
                local ok_d, edef = pcall(cards.get_card_def, entry.card_id)
                if ok_d and edef then
                  if args.target == "unit" and (edef.kind == "Unit" or edef.kind == "Worker") then
                    dmg_eligible[#dmg_eligible + 1] = si
                  elseif args.target == "any" then
                    dmg_eligible[#dmg_eligible + 1] = si
                  end
                end
              end
              if #dmg_eligible == 0 then sound.play("error"); return end
              self.pending_spell_target = {
                hand_index = hand_idx,
                effect_args = args,
                eligible_player_index = opponent_pi,
                eligible_board_indices = dmg_eligible,
                via_ability_source = { type = info.source, index = info.board_index },
                via_ability_ability_index = info.ability_index,
                fast = ab.fast or false,
              }
              self.pending_play_spell = nil
              sound.play("click")
            else
              local before_res = {}
              for k, v in pairs(p.resources) do before_res[k] = v end
              local result = self:dispatch_command({
                type = "PLAY_SPELL_VIA_ABILITY",
                player_index = pi,
                source = { type = info.source, index = info.board_index },
                ability_index = info.ability_index,
                hand_index = hand_idx,
                fast_ability = ab.fast or false,
              })
              if result.ok then
                sound.play("coin")
                local pi_panel = self:player_to_panel(pi)
                local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
                for _, c in ipairs(ab.cost or {}) do
                  if before_res[c.type] and p.resources[c.type] < before_res[c.type] then
                    local rb_x, rb_y = board.resource_bar_rect(pi_panel)
                    popup.create("-" .. c.amount .. string.upper(string.sub(c.type, 1, 1)), rb_x + 25, rb_y - 4, { 1.0, 0.5, 0.25 })
                  end
                end
                local sname = spell_def and spell_def.name or "Spell"
                popup.create(sname .. "!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.7, 0.85, 1.0 })
                self.pending_play_spell = nil
                while #self.hand_y_offsets > #p.hand do table.remove(self.hand_y_offsets) end
              else
                sound.play("error")
              end
            end
          end
          if #eligible == 1 then
            do_cast_spell(eligible[1])
          else
            self.pending_play_spell = {
              source = { type = info.source, index = info.board_index },
              ability_index = info.ability_index,
              cost = ab.cost,
              effect_args = ab.effect_args,
              eligible_indices = eligible,
              fast = ab.fast or false,
            }
            self.hand_selected_index = nil
            sound.play("click")
          end
          return
        end

        -- Two-step flow for discard_draw abilities (Hospital)
        if ab.effect == "discard_draw" then
          local args = ab.effect_args or {}
          local required_discard = args.discard or 2
          if #p.hand < required_discard then
            sound.play("error")
            return
          end
          self.pending_discard_draw = {
            source = { type = info.source, index = info.board_index },
            ability_index = info.ability_index,
            required_count = required_discard,
            draw_count = args.draw or 1,
            selected_set = {},
          }
          self.hand_selected_index = nil
          sound.play("click")
          return
        end

        -- Two-step flow for deal_damage_x abilities (Flying Machine)
        if ab.effect == "deal_damage_x" then
          local source_entry = info.source == "board" and p.board[info.board_index] or nil
          if ab.rest and source_entry and source_entry.state and source_entry.state.rested then
            sound.play("error")
            return
          end
          local args = ab.effect_args or {}
          local resource = args.resource or "stone"
          local available = p.resources[resource] or 0
          if available < 1 then
            sound.play("error")
            return
          end
          local opponent_pi = 1 - pi
          local op = self.game_state.players[opponent_pi + 1]
          local eligible = {}
          for si, entry in ipairs(op.board) do
            local ok_d, edef = pcall(cards.get_card_def, entry.card_id)
            if ok_d and edef then
              if args.target == "unit" and (edef.kind == "Unit" or edef.kind == "Worker") then
                eligible[#eligible + 1] = si
              elseif args.target == "any" then
                eligible[#eligible + 1] = si
              end
            end
          end
          if #eligible == 0 then
            sound.play("error")
            return
          end
          self.pending_damage_x = {
            source = { type = info.source, index = info.board_index },
            ability_index = info.ability_index,
            effect_args = args,
            eligible_player_index = opponent_pi,
            eligible_board_indices = eligible,
            x_amount = available,
            max_x = available,
            fast = ab.fast or false,
          }
          sound.play("click")
          return
        end

        -- Two-step flow for place_counter_on_target abilities (Prince of Reason)
        if ab.effect == "place_counter_on_target" then
          local source_entry = info.source == "board" and p.board[info.board_index] or nil
          if ab.rest and source_entry and source_entry.state and source_entry.state.rested then
            sound.play("error")
            return
          end
          if not abilities.can_pay_cost(p.resources, ab.cost) then
            sound.play("error")
            return
          end
          -- Collect eligible ally units/workers
          local eligible = {}
          for si, entry in ipairs(p.board) do
            local ok_d, edef = pcall(cards.get_card_def, entry.card_id)
            if ok_d and edef and (edef.kind == "Unit" or edef.kind == "Worker") then
              eligible[#eligible + 1] = si
            end
          end
          if #eligible == 0 then
            sound.play("error")
            return
          end
          self.pending_counter_placement = {
            source = { type = info.source, index = info.board_index },
            ability_index = info.ability_index,
            effect_args = ab.effect_args or {},
            eligible_board_indices = eligible,
            fast = ab.fast or false,
          }
          sound.play("click")
          return
        end

        -- Two-step flow for return_from_graveyard abilities (Skelieutenant)
        if ab.effect == "return_from_graveyard" then
          if not abilities.can_pay_cost(p.resources, ab.cost) then
            sound.play("error")
            return
          end
          local source_key = (info.source == "board" and "board:" .. info.board_index or "base") .. ":" .. info.ability_index
          local used_key = tostring(pi) .. ":" .. source_key
          if ab.once_per_turn and self.game_state.activatedUsedThisTurn[used_key] then
            sound.play("error")
            return
          end
          local args = ab.effect_args or {}
          local cards_for_selection = graveyard_cards_for_selection(p, args)
          local has_eligible = false
          for _, c in ipairs(cards_for_selection) do
            if c.graveyard_eligible then has_eligible = true; break end
          end
          if not has_eligible then
            sound.play("error")
            return
          end
          self.pending_graveyard_return = {
            source = { type = info.source, index = info.board_index },
            ability_index = info.ability_index,
            max_count = args.count or 1,
            effect_args = args,
            selected_graveyard_indices = {},
          }
          local pending_ref = self.pending_graveyard_return
          local faction_info = factions_data[p.faction]
          local accent = faction_info and faction_info.color or { 0.5, 0.5, 0.7 }
          local viewer_title = (args.return_to == "hand") and "Return to Hand" or "Return from Graveyard"
          local viewer_hint = "Select up to " .. (args.count or 1) .. ((args.return_to == "hand") and " card" or " Undead") .. ((args.count or 1) > 1 and "s" or "")
          deck_viewer.open({
            title = viewer_title,
            hint = viewer_hint,
            cards = cards_for_selection,
            accent = accent,
            can_click_fn = function(def) return def.graveyard_eligible == true end,
            card_overlay_fn = function(def, cx, cy, cw, ch)
              if not def.graveyard_index then return end
              -- Dim ineligible cards
              if not def.graveyard_eligible then
                love.graphics.setColor(0, 0, 0, 0.55)
                love.graphics.rectangle("fill", cx, cy, cw, ch, 5, 5)
                return
              end
              -- Highlight selected cards
              local selected = pending_ref.selected_graveyard_indices
              for _, gi in ipairs(selected) do
                if gi == def.graveyard_index then
                  love.graphics.setColor(0.2, 0.9, 0.35, 0.35)
                  love.graphics.rectangle("fill", cx, cy, cw, ch, 5, 5)
                  love.graphics.setColor(0.2, 0.9, 0.35, 0.85)
                  love.graphics.setLineWidth(2)
                  love.graphics.rectangle("line", cx - 2, cy - 2, cw + 4, ch + 4, 7, 7)
                  love.graphics.setLineWidth(1)
                  return
                end
              end
            end,
            on_click = function(def)
              if not def.graveyard_eligible or not def.graveyard_index then return end
              local sel = pending_ref.selected_graveyard_indices
              -- Toggle: deselect if already selected
              for i, gi in ipairs(sel) do
                if gi == def.graveyard_index then
                  table.remove(sel, i)
                  sound.play("click")
                  return
                end
              end
              -- Add if under max
              if #sel < pending_ref.max_count then
                sel[#sel + 1] = def.graveyard_index
                sound.play("click")
              else
                sound.play("error")
              end
            end,
            confirm_label = (args.return_to == "hand") and "Return to Hand" or "Summon Selected",
            confirm_enabled_fn = function()
              return #pending_ref.selected_graveyard_indices > 0
            end,
            confirm_fn = function()
              local selected = pending_ref.selected_graveyard_indices
              if #selected == 0 then return end
              local result = self:dispatch_command({
                type = "RETURN_FROM_GRAVEYARD",
                player_index = self.local_player_index,
                source = pending_ref.source,
                ability_index = pending_ref.ability_index,
                selected_graveyard_indices = selected,
              })
              if result.ok then
                sound.play("coin")
                local pi_panel = self:player_to_panel(self.local_player_index)
                local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
                local count = result.meta and result.meta.returned_count or 0
                local msg = (args.return_to == "hand") and (count .. " card" .. (count == 1 and "" or "s") .. " returned to hand!") or (count .. " Undead summoned!")
                popup.create(msg, px_b + pw_b / 2, py_b + ph_b - 80, { 0.55, 0.9, 0.45 })
              else
                sound.play("error")
              end
              deck_viewer.close()
              self.show_blueprint_for_player = nil
              self.pending_graveyard_return = nil
            end,
          })
          self.show_blueprint_for_player = nil
          sound.play("click")
          return
        end

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

  if kind == "graveyard" then
    sound.play("click")
    self:open_graveyard_view(pi)
    return
  end

  -- Only local player can initiate drag interactions.
  if self.authoritative_adapter and pi ~= self.local_player_index then return end

  local c = self.game_state.pendingCombat
  local can_declare_attack = (pi == self.game_state.activePlayer and pi == self.local_player_index and not c)
  local can_assign_blocks = (c and c.stage == "DECLARED" and c.defender == self.local_player_index and pi == self.local_player_index)
  local can_assign_damage_order = (c and c.stage == "AWAITING_DAMAGE_ORDER" and c.attacker == self.local_player_index and pi == self.local_player_index)
  local can_worker_actions = (pi == self.game_state.activePlayer and pi == self.local_player_index and not c)

  if kind == "structure" and idx and idx > 0 and is_attack_unit_board_entry(self.game_state, pi, idx, true) and not is_worker_board_entry(self.game_state, pi, idx) and can_declare_attack then
    local mx, my = love.mouse.getPosition()
    self.drag = { player_index = pi, from = "attack_unit", display_x = mx, display_y = my, board_index = idx }
    sound.play("whoosh", 0.6)
    return
  end

  if not can_worker_actions and not can_assign_blocks and not can_assign_damage_order then return end

  if can_assign_blocks and kind == "structure" and idx and idx > 0 and is_attack_unit_board_entry(self.game_state, pi, idx, false) then
    local mx, my = love.mouse.getPosition()
    self.drag = { player_index = pi, from = "block_unit", display_x = mx, display_y = my, board_index = idx }
    sound.play("whoosh", 0.55)
    return
  end

  if can_assign_damage_order and kind == "structure" and idx and idx > 0 and is_attack_unit_board_entry(self.game_state, pi, idx, false) then
    local mx, my = love.mouse.getPosition()
    self.drag = { player_index = pi, from = "order_attacker", display_x = mx, display_y = my, board_index = idx }
    sound.play("whoosh", 0.5)
    return
  end

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
  elseif kind == "structure" and is_worker_board_entry(self.game_state, pi, idx) then
    sound.play("pop")
    local mx, my = love.mouse.getPosition()
    local sw_index = get_special_field_index(self.game_state, pi, idx)
    if sw_index then
      self.drag = { player_index = pi, from = "special_field", display_x = mx, display_y = my, board_index = idx, sw_index = sw_index }
    else
      self.drag = { player_index = pi, from = "unit_worker_card", display_x = mx, display_y = my, board_index = idx }
    end
  end

  -- Special worker drag
  if kind == "special_worker_unassigned" or kind == "special_worker_resource" or kind == "special_worker_structure" then
    sound.play("pop")
    local mx, my = love.mouse.getPosition()
    self.drag = { player_index = pi, from = "special", display_x = mx, display_y = my, sw_index = idx }
  end
end

-- Helper: get the origin screen position for a worker based on where it was dragged from
function GameState:_get_worker_origin(pi, from)
  local panel = self:player_to_panel(pi)
  local px, py, pw, ph = board.panel_rect(panel)
  local player = self.game_state.players[pi + 1]
  if from == "unassigned" then
    local uax, uay, uaw, uah = board.unassigned_pool_rect(px, py, pw, ph, player, panel)
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
  elseif from == "special" then
    -- Snap back to unassigned pool center
    local uax, uay, uaw, uah = board.unassigned_pool_rect(px, py, pw, ph, player, panel)
    return uax + uaw / 2, uay + uah / 2
  elseif from == "unit_worker_card" then
    local fax, fay, faw = board.front_row_rect(px, py, pw, ph, panel)
    return fax + faw / 2, fay + board.BFIELD_TILE_H / 2
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
  if self.game_state and self.game_state.is_terminal then
    self.drag = nil
    return
  end

  if deck_viewer.is_open() then return end

  if not self.drag then return end
  local kind, pi, drop_extra = board.hit_test(x, y, self.game_state, self.hand_y_offsets, self.local_player_index, {
    pending_attack_declarations = self.pending_attack_declarations,
    pending_block_assignments = self.pending_block_assignments,
    pending_attack_trigger_targets = self.pending_attack_trigger_targets,
  })

  -- Feature 2: Invalid drop zone -> snap back
  local allow_opponent_drop = (
    self.drag.from == "attack_unit"
    or self.drag.from == "block_unit"
    or self.drag.from == "order_attacker"
    or (self.drag.from == "unit_worker_card" and kind == "structure")
  ) and kind and pi == (1 - self.drag.player_index)
  if not kind or (pi ~= self.drag.player_index and not allow_opponent_drop) then
    if self.drag.from ~= "attack_unit" and self.drag.from ~= "order_attacker" then
      self:_spawn_snap_back()
    end
    self.drag = nil
    return
  end

  local from = self.drag.from
  local res_left = (self.game_state.players[pi + 1].faction == "Human") and "wood" or "food"
  local did_drop = false

  if from == "attack_unit" then
    local defender_pi = 1 - self.drag.player_index
    if pi == defender_pi and kind == "structure" then
      local target
      if drop_extra == 0 then
        target = { type = "base" }
      elseif drop_extra and drop_extra > 0 then
        target = { type = "board", index = drop_extra }
      end
      if target and not can_stage_attack_target(self.game_state, self.drag.player_index, self.drag.board_index, defender_pi, target.index or 0) then
        target = nil
      end
      if target then
        self:_set_pending_attack(self.drag.board_index, target)
        did_drop = true
        sound.play("click")
      end
    end
    if not did_drop then sound.play("error") end
    self.drag = nil
    return
  end

  if from == "unit_worker_card" then
    local defender_pi = 1 - self.drag.player_index
    if pi == defender_pi and kind == "structure" then
      local target
      if drop_extra == 0 then
        target = { type = "base" }
      elseif drop_extra and drop_extra > 0 then
        target = { type = "board", index = drop_extra }
      end
      if target and not can_stage_attack_target(self.game_state, self.drag.player_index, self.drag.board_index, defender_pi, target.index or 0) then
        target = nil
      end
      if target then
        self:_set_pending_attack(self.drag.board_index, target)
        did_drop = true
        sound.play("click")
        self.drag = nil
        return
      end
      sound.play("error")
      self.drag = nil
      return
    end
  end

  if from == "block_unit" then
    local attacker_pi = 1 - self.drag.player_index
    if pi == attacker_pi and kind == "structure" and drop_extra and drop_extra > 0 then
      self:_set_pending_block(self.drag.board_index, drop_extra)
      did_drop = true
      sound.play("click")
    end
    if not did_drop then sound.play("error") end
    self.drag = nil
    return
  end

  if from == "order_attacker" then
    local defender_pi = 1 - self.drag.player_index
    local pending = self.game_state.pendingCombat
    if pi == defender_pi and kind == "structure" and drop_extra and drop_extra > 0 and pending and pending.blockers then
      local is_legal_blocker = false
      for _, blk in ipairs(pending.blockers) do
        if blk.attacker_board_index == self.drag.board_index and blk.blocker_board_index == drop_extra then
          is_legal_blocker = true
          break
        end
      end
      if is_legal_blocker then
        self:_append_pending_damage_order(self.drag.board_index, drop_extra)
        did_drop = true
        sound.play("click")
      end
    end
    if not did_drop then sound.play("error") end
    self.drag = nil
    return
  end

  -- Special worker drop handling
  if from == "special" or from == "special_field" then
    local sw_index = self.drag.sw_index
    local player = self.game_state.players[pi + 1]
    local sw = player.specialWorkers[sw_index]
    if sw then
      local was_assigned = sw.assigned_to ~= nil
      if kind == "unassigned_pool" or kind == "worker_unassigned" or kind == "special_worker_unassigned" then
        -- Drop to unassigned pool
        if was_assigned then
          did_drop = self:dispatch_command({ type = "UNASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index }).ok
        end
      elseif kind == "resource_left" then
        if was_assigned then
          self:dispatch_command({ type = "UNASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index })
        end
        did_drop = self:dispatch_command({ type = "ASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index, target = res_left }).ok
      elseif kind == "resource_right" then
        if was_assigned then
          self:dispatch_command({ type = "UNASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index })
        end
        did_drop = self:dispatch_command({ type = "ASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index, target = "stone" }).ok
      elseif kind == "structure" or kind == "structure_worker" then
        local drop_si = drop_extra
        if drop_si then
          if was_assigned then
            self:dispatch_command({ type = "UNASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index })
          end
          if from == "special_field" and self.drag.board_index and self.drag.board_index < drop_si then
            drop_si = drop_si - 1
          end
          local target_entry = self.game_state.players[pi + 1].board[drop_si]
          local ok_def, target_def = false, nil
          if target_entry then
            ok_def, target_def = pcall(cards.get_card_def, target_entry.card_id)
          end
          if ok_def and target_def and target_def.kind == "Worker" then
            did_drop = self:dispatch_command({ type = "ASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index, target = { type = "field" } }).ok
          else
            did_drop = self:dispatch_command({ type = "ASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index, target = { type = "structure", board_index = drop_si } }).ok
          end
        end
      elseif kind == "unit_row" then
        if was_assigned then
          self:dispatch_command({ type = "UNASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index })
        end
        did_drop = self:dispatch_command({ type = "ASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index, target = { type = "field" } }).ok
      end
    end
    if did_drop then
      sound.play("pop")
    else
      self:_spawn_snap_back()
    end
    self.drag = nil
    return
  end

  -- Drop target (unassigned pool or clicking an unassigned worker = same zone)
  if kind == "unassigned_pool" or kind == "worker_unassigned" then
    if from == "unit_worker_card" then
      did_drop = self:dispatch_command({ type = "RECLAIM_WORKER_FROM_UNIT_ROW", player_index = pi, board_index = self.drag.board_index }).ok
    elseif from == "left" then
      did_drop = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = res_left }).ok
    elseif from == "right" then
      did_drop = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = "stone" }).ok
    elseif from == "structure" then
      did_drop = self:dispatch_command({ type = "UNASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = self.drag.board_index }).ok
    end
  elseif kind == "resource_left" then
    if from == "unit_worker_card" then
      local reclaim_res = self:dispatch_command({ type = "RECLAIM_WORKER_FROM_UNIT_ROW", player_index = pi, board_index = self.drag.board_index })
      if reclaim_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = res_left }).ok
      end
    elseif from == "unassigned" then
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
    if from == "unit_worker_card" then
      local reclaim_res = self:dispatch_command({ type = "RECLAIM_WORKER_FROM_UNIT_ROW", player_index = pi, board_index = self.drag.board_index })
      if reclaim_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = "stone" }).ok
      end
    elseif from == "unassigned" then
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
    -- Dropping onto a structure/unit tile
    local drop_si = drop_extra
    local drop_is_worker_card = drop_si and is_worker_board_entry(self.game_state, pi, drop_si)
    if from == "unit_worker_card" and drop_is_worker_card then
      did_drop = true
    elseif from == "unit_worker_card" and drop_si then
      local reclaim_res = self:dispatch_command({ type = "RECLAIM_WORKER_FROM_UNIT_ROW", player_index = pi, board_index = self.drag.board_index })
      if reclaim_res.ok then
        if self.drag.board_index < drop_si then
          drop_si = drop_si - 1
        end
        did_drop = self:dispatch_command({ type = "ASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = drop_si }).ok
      end
    elseif from ~= "unit_worker_card" and drop_is_worker_card then
      if from == "left" then
        local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = res_left })
        if unassign_res.ok then
          did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
        end
      elseif from == "right" then
        local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = "stone" })
        if unassign_res.ok then
          did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
        end
      elseif from == "structure" then
        local unassign_res = self:dispatch_command({ type = "UNASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = self.drag.board_index })
        if unassign_res.ok then
          did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
        end
      else
        did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
      end
    elseif from == "unassigned" and drop_si then
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
  elseif kind == "unit_row" then
    if from == "unit_worker_card" then
      did_drop = true
    elseif from == "left" then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = res_left })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
      end
    elseif from == "right" then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = "stone" })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
      end
    elseif from == "structure" then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = self.drag.board_index })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
      end
    else
      did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
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
  local kind, pi, idx = board.hit_test(x, y, self.game_state, self.hand_y_offsets, self.local_player_index, {
    pending_attack_declarations = self.pending_attack_declarations,
    pending_block_assignments = self.pending_block_assignments,
    pending_attack_trigger_targets = self.pending_attack_trigger_targets,
  })
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
  if key == "f8" then
    local pi = self.local_player_index
    local p = self.game_state.players[pi + 1]
    local gained = 0
    for _, res in ipairs(config.resource_types) do
      if p.resources[res] ~= nil then
        local result = self:dispatch_command({
          type = "DEBUG_ADD_RESOURCE",
          player_index = pi,
          resource = res,
          amount = 5,
        })
        if result.ok then gained = gained + 1 end
      end
    end
    if gained > 0 then
      sound.play("coin")
      local panel = self:player_to_panel(pi)
      local px, py, pw = board.panel_rect(panel)
      popup.create("[DEBUG] +5 all resources", px + pw / 2, py + 8, { 1.0, 0.85, 0.2 })
    else
      sound.play("error")
    end
    return
  end

  if deck_viewer.is_open() then
    local was_open = deck_viewer.is_open()
    deck_viewer.keypressed(key)
    if was_open and not deck_viewer.is_open() then
      self.show_blueprint_for_player = nil
      self.pending_graveyard_return = nil
    end
    return
  end
  -- Escape to cancel pending selection, deselect hand card, or return to menu
  if key == "escape" then
    if self.pending_play_unit then
      self.pending_play_unit = nil
      sound.play("click")
      return
    end
    if self.pending_sacrifice then
      self.pending_sacrifice = nil
      sound.play("click")
      return
    end
    if self.pending_upgrade then
      self.pending_upgrade = nil
      sound.play("click")
      return
    end
    if self.pending_hand_sacrifice then
      self.pending_hand_sacrifice = nil
      sound.play("click")
      return
    end
    if self.pending_monument then
      self.pending_monument = nil
      sound.play("click")
      return
    end
    if self.pending_discard_draw then
      self.pending_discard_draw = nil
      sound.play("click")
      return
    end
    if #self.pending_attack_trigger_targets > 0 then
      self:_clear_pending_attack_trigger_targets()
      sound.play("click")
      return
    end
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
