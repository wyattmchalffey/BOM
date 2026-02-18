-- Command execution boundary for gameplay mutations.
--
-- This module is the first step toward an authoritative simulation model:
-- UI/input layers submit commands, this module validates and executes.

local actions = require("src.game.actions")
local cards = require("src.game.cards")
local abilities = require("src.game.abilities")

local commands = {}

commands.SCHEMA_VERSION = 1

local VALID_RESOURCES = {
  food = true,
  wood = true,
  stone = true,
}

local function fail(reason, events)
  return { ok = false, reason = reason, events = events or {} }
end

local function ok(meta, events)
  return { ok = true, reason = "ok", meta = meta, events = events or {} }
end

local function can_activate(g, player_index, card_def, source_key, ability_index)
  if g.phase ~= "MAIN" then return false end
  if player_index ~= g.activePlayer then return false end
  if not card_def or not card_def.abilities then return false end

  local ab = card_def.abilities[ability_index]
  if not ab or ab.type ~= "activated" then return false end

  local key = tostring(player_index) .. ":" .. source_key
  if ab.once_per_turn and g.activatedUsedThisTurn[key] then return false end

  local p = g.players[player_index + 1]
  if not abilities.can_pay_cost(p.resources, ab.cost) then return false end

  return true
end

function commands.execute(g, command)
  if not command or not command.type then
    return fail("missing_command_type")
  end

  if command.type == "START_TURN" then
    if command.player_index ~= nil and command.player_index ~= g.activePlayer then
      return fail("not_active_player")
    end
    actions.start_turn(g)
    return ok(
      { active_player = g.activePlayer, turn_number = g.turnNumber },
      { { type = "turn_started", player_index = g.activePlayer, turn_number = g.turnNumber } }
    )
  end

  if command.type == "END_TURN" then
    local ending_player = g.activePlayer
    actions.end_turn(g)
    return ok(
      { active_player = g.activePlayer, turn_number = g.turnNumber },
      { { type = "turn_ended", player_index = ending_player }, { type = "active_player_changed", player_index = g.activePlayer } }
    )
  end

  if command.type == "ASSIGN_WORKER" then
    local pi = command.player_index
    local resource = command.resource
    if not VALID_RESOURCES[resource] then return fail("invalid_resource") end
    if pi ~= g.activePlayer then return fail("not_active_player") end

    local p = g.players[pi + 1]
    local assigned = p.workersOn.food + p.workersOn.wood + p.workersOn.stone + actions.count_structure_workers(p)
    if p.totalWorkers - assigned <= 0 then return fail("no_unassigned_workers") end

    actions.assign_worker_to_resource(g, pi, resource)
    return ok(nil, { { type = "worker_assigned", player_index = pi, resource = resource } })
  end

  if command.type == "UNASSIGN_WORKER" then
    local pi = command.player_index
    local resource = command.resource
    if not VALID_RESOURCES[resource] then return fail("invalid_resource") end
    if pi ~= g.activePlayer then return fail("not_active_player") end

    local p = g.players[pi + 1]
    if p.workersOn[resource] <= 0 then return fail("no_worker_on_resource") end

    actions.unassign_worker_from_resource(g, pi, resource)
    return ok(nil, { { type = "worker_unassigned", player_index = pi, resource = resource } })
  end

  if command.type == "BUILD_STRUCTURE" then
    local built = actions.build_structure(g, command.player_index, command.card_id)
    if not built then return fail("build_not_allowed") end
    return ok(
      { card_id = command.card_id },
      { { type = "structure_built", player_index = command.player_index, card_id = command.card_id } }
    )
  end

  if command.type == "ACTIVATE_ABILITY" then
    local pi = command.player_index
    local source = command.source
    local ability_index = command.ability_index
    local p = g.players[pi + 1]

    if not p or not source or not ability_index then
      return fail("invalid_activate_payload")
    end

    local card_def
    local source_key
    if source.type == "base" then
      card_def = cards.get_card_def(p.baseId)
      source_key = "base:" .. ability_index
    elseif source.type == "board" then
      local entry = p.board[source.index]
      if not entry then return fail("missing_board_entry") end
      card_def = cards.get_card_def(entry.card_id)
      source_key = "board:" .. source.index .. ":" .. ability_index
    else
      return fail("invalid_source_type")
    end

    if not can_activate(g, pi, card_def, source_key, ability_index) then
      return fail("ability_not_activatable")
    end

    actions.activate_ability(g, pi, card_def, source_key, ability_index)
    return ok(
      { source_type = source.type, ability_index = ability_index },
      { { type = "ability_activated", player_index = pi, source_type = source.type, ability_index = ability_index } }
    )
  end

  if command.type == "ASSIGN_STRUCTURE_WORKER" then
    local pi = command.player_index
    local board_index = command.board_index
    if pi ~= g.activePlayer then return fail("not_active_player") end
    local p = g.players[pi + 1]
    local assigned = p.workersOn.food + p.workersOn.wood + p.workersOn.stone + actions.count_structure_workers(p)
    if p.totalWorkers - assigned <= 0 then return fail("no_unassigned_workers") end
    actions.assign_worker_to_structure(g, pi, board_index)
    return ok(nil, { { type = "structure_worker_assigned", player_index = pi, board_index = board_index } })
  end

  if command.type == "UNASSIGN_STRUCTURE_WORKER" then
    local pi = command.player_index
    local board_index = command.board_index
    if pi ~= g.activePlayer then return fail("not_active_player") end
    actions.unassign_worker_from_structure(g, pi, board_index)
    return ok(nil, { { type = "structure_worker_unassigned", player_index = pi, board_index = board_index } })
  end

  return fail("unknown_command")
end

return commands
