-- Command execution boundary for gameplay mutations.
--
-- This module is the first step toward an authoritative simulation model:
-- UI/input layers submit commands, this module validates and executes.

local actions = require("src.game.actions")
local cards = require("src.game.cards")
local abilities = require("src.game.abilities")
local combat = require("src.game.combat")

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

local function has_subtype(card_def, subtype)
  if not card_def or not card_def.subtypes then return false end
  for _, st in ipairs(card_def.subtypes) do
    if st == subtype then return true end
  end
  return false
end

local function copy_table(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do
    if type(v) == "table" then
      out[k] = copy_table(v)
    else
      out[k] = v
    end
  end
  return out
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

  if command.type == "DECLARE_ATTACKERS" then
    local ok_decl, reason = combat.declare_attackers(g, command.player_index, command.declarations)
    if not ok_decl then return fail(reason) end
    return ok(nil, { { type = "attackers_declared", player_index = command.player_index } })
  end

  if command.type == "ASSIGN_BLOCKERS" then
    local ok_blk, reason = combat.assign_blockers(g, command.player_index, command.assignments)
    if not ok_blk then return fail(reason) end
    return ok(nil, { { type = "blockers_assigned", player_index = command.player_index } })
  end

  if command.type == "RESOLVE_COMBAT" then
    local ok_res, reason = combat.resolve(g)
    if not ok_res then return fail(reason) end
    return ok(nil, { { type = "combat_resolved" } })
  end

  if command.type == "DEBUG_ADD_RESOURCE" then
    local pi = command.player_index
    local resource = command.resource
    local amount = command.amount or 0

    local p = g.players[(pi or -1) + 1]
    if not p then return fail("invalid_player") end
    if type(resource) ~= "string" or p.resources[resource] == nil then return fail("invalid_resource") end
    if type(amount) ~= "number" or amount == 0 then return fail("invalid_amount") end

    p.resources[resource] = math.max(0, p.resources[resource] + amount)
    return ok(
      { player_index = pi, resource = resource, amount = amount, total = p.resources[resource] },
      { { type = "resource_debug_added", player_index = pi, resource = resource, amount = amount } }
    )
  end

  if command.type == "ASSIGN_WORKER" then
    local pi = command.player_index
    local resource = command.resource
    if not VALID_RESOURCES[resource] then return fail("invalid_resource") end
    if pi ~= g.activePlayer then return fail("not_active_player") end

    local p = g.players[pi + 1]
    if actions.count_unassigned_workers(p) <= 0 then return fail("no_unassigned_workers") end

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

  if command.type == "PLAY_UNIT_FROM_HAND" then
    local pi = command.player_index
    local source = command.source
    local ability_index = command.ability_index
    local hand_index = command.hand_index
    local p = g.players[pi + 1]

    if not p or not source or not ability_index or not hand_index then
      return fail("invalid_play_unit_payload")
    end
    if pi ~= g.activePlayer then return fail("not_active_player") end
    if g.phase ~= "MAIN" then return fail("wrong_phase") end

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

    if not card_def or not card_def.abilities then return fail("no_abilities") end
    local ab = card_def.abilities[ability_index]
    if not ab or ab.type ~= "activated" or ab.effect ~= "play_unit" then
      return fail("not_play_unit_ability")
    end

    if not can_activate(g, pi, card_def, source_key, ability_index) then
      return fail("ability_not_activatable")
    end

    if hand_index < 1 or hand_index > #p.hand then return fail("invalid_hand_index") end
    local matching = abilities.find_matching_hand_indices(p, ab.effect_args)
    local is_eligible = false
    for _, idx in ipairs(matching) do
      if idx == hand_index then is_eligible = true; break end
    end
    if not is_eligible then return fail("hand_card_not_eligible") end

    local card_id = p.hand[hand_index]
    actions.play_unit_from_hand(g, pi, card_def, source_key, ability_index, hand_index)
    return ok(
      { source_type = source.type, ability_index = ability_index, card_id = card_id, hand_index = hand_index },
      { { type = "unit_played_from_hand", player_index = pi, source_type = source.type, ability_index = ability_index, card_id = card_id } }
    )
  end

  if command.type == "ASSIGN_STRUCTURE_WORKER" then
    local pi = command.player_index
    local board_index = command.board_index
    if pi ~= g.activePlayer then return fail("not_active_player") end
    local p = g.players[pi + 1]
    if actions.count_unassigned_workers(p) <= 0 then return fail("no_unassigned_workers") end
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

  if command.type == "DEPLOY_WORKER_TO_UNIT_ROW" then
    local pi = command.player_index
    if pi ~= g.activePlayer then return fail("not_active_player") end

    local deployed = actions.deploy_worker_to_unit_row(g, pi)
    if not deployed then return fail("deploy_worker_failed") end

    return ok(nil, { { type = "worker_deployed_to_unit_row", player_index = pi } })
  end

  if command.type == "RECLAIM_WORKER_FROM_UNIT_ROW" then
    local pi = command.player_index
    local board_index = command.board_index
    if pi ~= g.activePlayer then return fail("not_active_player") end
    if not board_index then return fail("missing_board_index") end

    local reclaimed = actions.reclaim_worker_from_unit_row(g, pi, board_index)
    if not reclaimed then return fail("reclaim_worker_failed") end

    return ok(nil, { { type = "worker_reclaimed_from_unit_row", player_index = pi, board_index = board_index } })
  end


  if command.type == "PLAY_FROM_HAND_WITH_SACRIFICES" then
    local pi = command.player_index
    local hand_index = command.hand_index
    local sacrifice_targets = command.sacrifice_targets
    if pi ~= g.activePlayer then return fail("not_active_player") end
    if g.phase ~= "MAIN" then return fail("wrong_phase") end
    local p = g.players[pi + 1]
    if not hand_index or hand_index < 1 or hand_index > #p.hand then return fail("invalid_hand_index") end
    local card_id = p.hand[hand_index]
    local card_ok, card_def = pcall(cards.get_card_def, card_id)
    if not card_ok or not card_def then return fail("invalid_card") end

    local sac_ab = nil
    if card_def.abilities then
      for _, ab in ipairs(card_def.abilities) do
        if ab.type == "static" and ab.effect == "play_cost_sacrifice" then sac_ab = ab; break end
      end
    end
    if not sac_ab then return fail("card_not_playable") end
    local sacrifice_count = sac_ab.effect_args and sac_ab.effect_args.sacrifice_count or 2
    if type(sacrifice_targets) ~= "table" or #sacrifice_targets ~= sacrifice_count then
      return fail("invalid_sacrifice_targets")
    end

    local played = actions.play_from_hand(g, pi, hand_index, sacrifice_targets)
    if not played then return fail("play_failed") end
    return ok(
      { card_id = card_id },
      { { type = "card_played_from_hand", player_index = pi, card_id = card_id } }
    )
  end

  if command.type == "PLAY_FROM_HAND" then
    local pi = command.player_index
    local hand_index = command.hand_index
    if pi ~= g.activePlayer then return fail("not_active_player") end
    if g.phase ~= "MAIN" then return fail("wrong_phase") end
    local p = g.players[pi + 1]
    if not hand_index or hand_index < 1 or hand_index > #p.hand then return fail("invalid_hand_index") end
    local card_id = p.hand[hand_index]
    local card_ok, card_def = pcall(cards.get_card_def, card_id)
    if not card_ok or not card_def then return fail("invalid_card") end
    -- Check card has sacrifice ability
    local sac_ab = nil
    if card_def.abilities then
      for _, ab in ipairs(card_def.abilities) do
        if ab.type == "static" and ab.effect == "play_cost_sacrifice" then sac_ab = ab; break end
      end
    end
    if not sac_ab then return fail("card_not_playable") end
    local sacrifice_count = sac_ab.effect_args and sac_ab.effect_args.sacrifice_count or 2
    if actions.count_unassigned_workers(p) < sacrifice_count then return fail("not_enough_workers") end
    local played = actions.play_from_hand(g, pi, hand_index)
    if not played then return fail("play_failed") end
    return ok(
      { card_id = card_id },
      { { type = "card_played_from_hand", player_index = pi, card_id = card_id } }
    )
  end

  if command.type == "ASSIGN_SPECIAL_WORKER" then
    local pi = command.player_index
    local sw_index = command.sw_index
    local target = command.target
    if pi ~= g.activePlayer then return fail("not_active_player") end
    local p = g.players[pi + 1]
    if not sw_index or not p.specialWorkers[sw_index] then return fail("invalid_sw_index") end
    if p.specialWorkers[sw_index].assigned_to ~= nil then return fail("sw_already_assigned") end
    local assigned = actions.assign_special_worker(g, pi, sw_index, target)
    if not assigned then return fail("assign_failed") end
    return ok(nil, { { type = "special_worker_assigned", player_index = pi, sw_index = sw_index, target = target } })
  end

  if command.type == "UNASSIGN_SPECIAL_WORKER" then
    local pi = command.player_index
    local sw_index = command.sw_index
    if pi ~= g.activePlayer then return fail("not_active_player") end
    local p = g.players[pi + 1]
    if not sw_index or not p.specialWorkers[sw_index] then return fail("invalid_sw_index") end
    if p.specialWorkers[sw_index].assigned_to == nil then return fail("sw_not_assigned") end
    local unassigned = actions.unassign_special_worker(g, pi, sw_index)
    if not unassigned then return fail("unassign_failed") end
    return ok(nil, { { type = "special_worker_unassigned", player_index = pi, sw_index = sw_index } })
  end

  if command.type == "SACRIFICE_UPGRADE_PLAY" then
    local pi = command.player_index
    local source = command.source
    local ability_index = command.ability_index
    local hand_index = command.hand_index
    local target_board_index = command.target_board_index
    local target_worker = command.target_worker
    local target_worker_extra = command.target_worker_extra
    local p = g.players[pi + 1]

    if not p or not source or not ability_index or not hand_index then return fail("invalid_upgrade_payload") end
    if not target_board_index and not target_worker then return fail("invalid_upgrade_payload") end
    if pi ~= g.activePlayer then return fail("not_active_player") end
    if g.phase ~= "MAIN" then return fail("wrong_phase") end

    local card_def
    local source_key
    if source.type == "board" then
      local entry = p.board[source.index]
      if not entry then return fail("missing_board_entry") end
      card_def = cards.get_card_def(entry.card_id)
      source_key = "board:" .. source.index .. ":" .. ability_index
    else
      return fail("invalid_source_type")
    end

    if not card_def or not card_def.abilities then return fail("no_abilities") end
    local ab = card_def.abilities[ability_index]
    if not ab or ab.type ~= "activated" or ab.effect ~= "sacrifice_upgrade" then return fail("not_sacrifice_upgrade_ability") end
    if not can_activate(g, pi, card_def, source_key, ability_index) then return fail("ability_not_activatable") end

    local sacrificed_tier = 0
    if target_board_index then
      local entry = p.board[target_board_index]
      if not entry then return fail("invalid_sacrifice_target") end
      local ok_t, tdef = pcall(cards.get_card_def, entry.card_id)
      if not ok_t or not tdef or tdef.kind == "Structure" or not has_subtype(tdef, "Warrior") then
        return fail("invalid_sacrifice_target")
      end
      sacrificed_tier = tdef.tier or 0
    else
      sacrificed_tier = 0
    end

    if hand_index < 1 or hand_index > #p.hand then return fail("invalid_hand_index") end
    local hand_id = p.hand[hand_index]
    local ok_h, hdef = pcall(cards.get_card_def, hand_id)
    if not ok_h or not hdef or not has_subtype(hdef, "Warrior") or (hdef.tier or 0) ~= (sacrificed_tier + 1) then
      return fail("hand_card_not_eligible")
    end

    local snapshot = {
      totalWorkers = p.totalWorkers,
      workersOn = { food = p.workersOn.food, wood = p.workersOn.wood, stone = p.workersOn.stone },
      resources = {},
      board = {},
      specialWorkers = {},
      activated = g.activatedUsedThisTurn[tostring(pi) .. ":" .. source_key],
    }
    for k, v in pairs(p.resources) do snapshot.resources[k] = v end
    for i, e in ipairs(p.board) do snapshot.board[i] = copy_table(e) end
    for i, sw in ipairs(p.specialWorkers) do snapshot.specialWorkers[i] = copy_table(sw) end
    snapshot.workerStatePool = copy_table(p.workerStatePool or {})

    local ok_apply = true
    if target_board_index then
      ok_apply = actions.sacrifice_board_entry(g, pi, target_board_index)
    else
      ok_apply = actions.sacrifice_worker_token(g, pi, target_worker, target_worker_extra)
    end

    if ok_apply then
      if hand_index < 1 or hand_index > #p.hand then ok_apply = false end
    end
    if ok_apply then
      g.activatedUsedThisTurn[tostring(pi) .. ":" .. source_key] = true
      table.remove(p.hand, hand_index)
      p.board[#p.board + 1] = { card_id = hand_id, state = {} }
      actions.resolve_on_play_triggers(g, pi, hand_id)
    end

    if not ok_apply then
      p.totalWorkers = snapshot.totalWorkers
      p.workersOn.food = snapshot.workersOn.food
      p.workersOn.wood = snapshot.workersOn.wood
      p.workersOn.stone = snapshot.workersOn.stone
      for k, v in pairs(snapshot.resources) do p.resources[k] = v end
      p.board = {}
      for i, e in ipairs(snapshot.board) do p.board[i] = copy_table(e) end
      p.specialWorkers = {}
      for i, sw in ipairs(snapshot.specialWorkers) do p.specialWorkers[i] = copy_table(sw) end
      p.workerStatePool = copy_table(snapshot.workerStatePool or {})
      if snapshot.activated then
        g.activatedUsedThisTurn[tostring(pi) .. ":" .. source_key] = snapshot.activated
      else
        g.activatedUsedThisTurn[tostring(pi) .. ":" .. source_key] = nil
      end
      return fail("upgrade_failed")
    end

    return ok(
      { card_id = hand_id, source_type = source.type, ability_index = ability_index },
      { { type = "unit_played_from_sacrifice_upgrade", player_index = pi, card_id = hand_id } }
    )
  end

  if command.type == "SACRIFICE_UNIT" then
    local pi = command.player_index
    local source = command.source
    local ability_index = command.ability_index
    local target_board_index = command.target_board_index
    local target_worker = command.target_worker
    local p = g.players[pi + 1]

    if not p or not source or not ability_index then
      return fail("invalid_sacrifice_payload")
    end
    if not target_board_index and not target_worker then
      return fail("invalid_sacrifice_payload")
    end
    if pi ~= g.activePlayer then return fail("not_active_player") end
    if g.phase ~= "MAIN" then return fail("wrong_phase") end

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

    if not card_def or not card_def.abilities then return fail("no_abilities") end
    local ab = card_def.abilities[ability_index]
    if not ab or ab.type ~= "activated" or ab.effect ~= "sacrifice_produce" then
      return fail("not_sacrifice_ability")
    end

    if not can_activate(g, pi, card_def, source_key, ability_index) then
      return fail("ability_not_activatable")
    end

    if target_worker then
      -- Sacrificing a worker token
      if p.totalWorkers <= 0 then return fail("no_workers") end
      local worker_extra = command.target_worker_extra
      actions.sacrifice_worker(g, pi, card_def, source_key, ability_index, target_worker, worker_extra)
      return ok(
        { source_type = source.type, ability_index = ability_index, target_worker = true },
        { { type = "worker_sacrificed", player_index = pi } }
      )
    else
      -- Sacrificing a board entry
      local eligible = abilities.find_sacrifice_targets(p, ab.effect_args)
      local is_eligible = false
      for _, idx in ipairs(eligible) do
        if idx == target_board_index then is_eligible = true; break end
      end
      if not is_eligible then return fail("target_not_eligible") end

      actions.sacrifice_unit(g, pi, card_def, source_key, ability_index, target_board_index)
      local sacrificed_entry = p.board[target_board_index]
      local sacrificed_id = sacrificed_entry and sacrificed_entry.card_id
      return ok(
        { source_type = source.type, ability_index = ability_index, target_board_index = target_board_index, card_id = sacrificed_id },
        { { type = "unit_sacrificed", player_index = pi, target_board_index = target_board_index } }
      )
    end
  end

  return fail("unknown_command")
end

return commands
