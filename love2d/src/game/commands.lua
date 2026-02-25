-- Command execution boundary for gameplay mutations.
--
-- This module is the first step toward an authoritative simulation model:
-- UI/input layers submit commands, this module validates and executes.

local actions = require("src.game.actions")
local cards = require("src.game.cards")
local abilities = require("src.game.abilities")
local combat = require("src.game.combat")
local game_state = require("src.game.state")
local spell_cast = require("src.game.spell_cast")
local unit_stats = require("src.game.unit_stats")

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

local append_resolve_result_events

local function finalize_terminal_state(g, events)
  local terminal = game_state.compute_terminal_result(g)
  if not terminal then
    return
  end

  if not g.is_terminal then
    game_state.set_terminal(g, terminal)
    events[#events + 1] = {
      type = "match_ended",
      winner = g.winner,
      reason = g.reason,
      ended_at_turn = g.ended_at_turn,
    }
  end
end

local function succeed(g, meta, events)
  local out_events = events or {}
  if type(meta) == "table" and type(append_resolve_result_events) == "function" then
    append_resolve_result_events(out_events, meta)
  end
  finalize_terminal_state(g, out_events)

  -- Keep the centralized derived/continuous stat cache warm after successful
  -- state mutations; lazy signature checks remain as a safety net during
  -- multi-step command resolution/combat.
  if g then
    g._derived_stats_cache_token = (g._derived_stats_cache_token or 0) + 1
    unit_stats.recompute_derived_stats(g)
  end

  if g and g.is_terminal then
    meta = meta or {}
    meta.is_terminal = true
    meta.winner = g.winner
    meta.reason = g.reason
    meta.ended_at_turn = g.ended_at_turn
  end

  return ok(meta, out_events)
end

local function has_subtype(card_def, subtype)
  if not card_def or not card_def.subtypes then return false end
  for _, st in ipairs(card_def.subtypes) do
    if st == subtype then return true end
  end
  return false
end

local function required_upgrade_subtypes(effect_args)
  local args = effect_args or {}
  if type(args.subtypes) == "table" and #args.subtypes > 0 then
    return args.subtypes
  end
  return { "Warrior" }
end

local function has_any_subtype(card_def, subtype_list)
  if not card_def or type(card_def.subtypes) ~= "table" then return false end
  for _, req in ipairs(subtype_list or {}) do
    if has_subtype(card_def, req) then return true end
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

-- Returns true when command.fast_ability is set and we're in the DECLARED
-- blocker window, meaning the active-player / MAIN-phase gate is bypassed.
local function fast_in_blocker_window(g, player_index, command)
  if not command.fast_ability then return false end
  local c = g.pendingCombat
  return c ~= nil and c.stage == "DECLARED"
    and (player_index == c.attacker or player_index == c.defender)
end

append_resolve_result_events = function(out_events, meta)
  if type(out_events) ~= "table" or type(meta) ~= "table" then return end
  local resolve_result = meta.resolve_result
  if type(resolve_result) ~= "table" or type(resolve_result.events) ~= "table" then return end

  for _, ev in ipairs(resolve_result.events) do
    if type(ev) == "table" and type(ev.type) == "string" then
      out_events[#out_events + 1] = {
        type = "resolve_effect_event",
        effect = resolve_result.effect,
        resolve_event_type = ev.type,
        resolve_event = copy_table(ev),
        source_type = meta.source_type,
        ability_index = meta.ability_index,
        card_id = meta.card_id,
      }
    end
  end
end

local function synthetic_resolve_result(effect, source, event_list)
  if type(effect) ~= "string" then return nil end
  local result = abilities.new_resolve_result({ effect = effect }, { source = source })
  result.handler_found = true
  result.resolved = true
  for _, ev in ipairs(event_list or {}) do
    if type(ev) == "table" then
      abilities.result_add_event(result, copy_table(ev))
    end
  end
  return result
end

local function activated_ability_used_this_turn(g, player_index, source_key, source, ability_index)
  return abilities.is_activated_ability_used_this_turn(g, player_index, source_key, source, ability_index)
end

local function set_activated_ability_used_this_turn(g, player_index, source_key, source, ability_index, used)
  abilities.set_activated_ability_used_this_turn(g, player_index, source_key, source, ability_index, used)
end

local function append_board_entry(g, player, entry)
  abilities.ensure_board_entry_instance_id(g, entry)
  player.board[#player.board + 1] = entry
  return entry
end

local function can_activate(g, player_index, card_def, source_key, ability_index, source)
  if not card_def or not card_def.abilities then return false end

  local ab = card_def.abilities[ability_index]
  if not ab or ab.type ~= "activated" then return false end

  -- Fast abilities may be used during the blocker window (DECLARED stage) by
  -- either the attacker or the defender, bypassing the normal MAIN-phase gate.
  local c = g.pendingCombat
  local in_blocker_window = ab.fast == true and c and c.stage == "DECLARED"
    and (player_index == c.attacker or player_index == c.defender)

  if not in_blocker_window then
    if g.phase ~= "MAIN" then return false end
    if player_index ~= g.activePlayer then return false end
  end

  if ab.once_per_turn and activated_ability_used_this_turn(g, player_index, source_key, source, ability_index) then
    return false
  end

  local p = g.players[player_index + 1]
  local source_entry = nil
  if type(source) == "table" and source.type == "board" and type(source.index) == "number" then
    source_entry = p.board[source.index]
  end
  local can_pay, _ = abilities.can_pay_activated_ability_costs(p.resources, ab, {
    require_variable_min = true,
    source_entry = source_entry,
  })
  if not can_pay then return false end

  local sel_info = abilities.collect_activated_selection_cost_targets(g, player_index, ab)
  if sel_info and sel_info.requires_selection and not sel_info.has_any_target then
    return false
  end

  return true
end

local function resolve_activated_source_def(player, source, ability_index)
  if type(player) ~= "table" or type(source) ~= "table" then
    return nil, nil, nil, "invalid_source_type"
  end

  if source.type == "base" then
    return cards.get_card_def(player.baseId), "base:" .. ability_index, nil, nil
  end

  if source.type == "board" then
    local entry = player.board[source.index]
    if not entry then
      return nil, nil, nil, "missing_board_entry"
    end
    return cards.get_card_def(entry.card_id), "board:" .. source.index .. ":" .. ability_index, entry, nil
  end

  return nil, nil, nil, "invalid_source_type"
end

local function ability_effect_matches(allowed_effects, effect)
  if type(allowed_effects) == "string" then
    return effect == allowed_effects
  end
  if type(allowed_effects) ~= "table" then
    return true
  end
  for _, allowed in ipairs(allowed_effects) do
    if effect == allowed then return true end
  end
  return false
end

local function resolve_command_activated_ability(g, player_index, player, source, ability_index, opts)
  opts = opts or {}

  if opts.require_board_source and (type(source) ~= "table" or source.type ~= "board") then
    return nil, "invalid_source_type"
  end

  local card_def, source_key, source_entry, source_err =
    resolve_activated_source_def(player, source, ability_index)
  if source_err then
    return nil, source_err
  end
  if not card_def or not card_def.abilities then
    return nil, "no_abilities"
  end

  local ab = card_def.abilities[ability_index]
  if not ab or ab.type ~= "activated" then
    return nil, (opts.invalid_effect_reason or "not_activated_ability")
  end

  if opts.allowed_effects and not ability_effect_matches(opts.allowed_effects, ab.effect) then
    return nil, (opts.invalid_effect_reason or "wrong_ability_effect")
  end

  if opts.require_can_activate and not can_activate(g, player_index, card_def, source_key, ability_index, source) then
    return nil, "ability_not_activatable"
  end

  return {
    card_def = card_def,
    source_key = source_key,
    source_entry = source_entry,
    ability = ab,
  }, nil
end

local function resolve_command_board_activated_ability(g, player_index, player, source, ability_index, opts)
  local inner_opts = copy_table(opts or {})
  inner_opts.require_board_source = true
  local actx, reason = resolve_command_activated_ability(g, player_index, player, source, ability_index, inner_opts)
  if not actx and reason == "missing_board_entry" then
    return nil, (inner_opts.missing_board_entry_reason or "missing_source_entry")
  end
  return actx, reason
end

local function precheck_command_activated_costs(g, player_index, player, source, ability_index, source_key, ability, cost_opts)
  if ability.once_per_turn and activated_ability_used_this_turn(g, player_index, source_key, source, ability_index) then
    return false, "ability_already_used"
  end
  local can_pay_ab, can_pay_reason = abilities.can_pay_activated_ability_costs(
    player.resources, ability, cost_opts or {}
  )
  if not can_pay_ab then
    return false, can_pay_reason or "insufficient_resources"
  end
  return true, nil
end

local function pay_and_mark_command_activated_costs(g, player_index, player, source, ability_index, source_key, ability, cost_opts)
  local paid_ab, pay_reason = abilities.pay_activated_ability_costs(player.resources, ability, cost_opts or {})
  if not paid_ab then
    return false, pay_reason or "insufficient_resources"
  end
  if ability.once_per_turn then
    set_activated_ability_used_this_turn(g, player_index, source_key, source, ability_index, true)
  end
  return true, nil
end

local function succeed_activated_command(g, player_index, source, ability_index, opts)
  opts = opts or {}
  local meta = copy_table(opts.meta or {})
  if opts.include_source_meta ~= false and type(source) == "table" and source.type ~= nil then
    meta.source_type = source.type
  end
  if opts.include_ability_meta ~= false and type(ability_index) == "number" then
    meta.ability_index = ability_index
  end

  local event = copy_table(opts.event or {})
  if type(opts.event_type) == "string" then
    event.type = opts.event_type
  end
  event.player_index = player_index
  if opts.include_source_event and type(source) == "table" and source.type ~= nil then
    event.source_type = source.type
  end
  if opts.include_ability_event and type(ability_index) == "number" then
    event.ability_index = ability_index
  end

  return succeed(g, meta, { event })
end

local function list_has_number(values, wanted)
  for _, value in ipairs(values or {}) do
    if value == wanted then return true end
  end
  return false
end

local function load_hand_card_def(player, hand_index, invalid_reason)
  if type(player) ~= "table" or type(player.hand) ~= "table" then
    return nil, nil, "invalid_player"
  end
  if type(hand_index) ~= "number" or hand_index < 1 or hand_index > #player.hand then
    return nil, nil, "invalid_hand_index"
  end
  local card_id = player.hand[hand_index]
  local ok, card_def = pcall(cards.get_card_def, card_id)
  if not ok or not card_def then
    return nil, nil, invalid_reason or "invalid_card"
  end
  return card_id, card_def, nil
end

local function validate_direct_spell_hand_selection(player, hand_index)
  local card_id, card_def, err = load_hand_card_def(player, hand_index, "invalid_card")
  if err then return nil, nil, err end
  if card_def.kind ~= "Spell" then
    return nil, nil, "not_a_spell"
  end
  return card_id, card_def, nil
end

local function validate_ability_spell_hand_selection(player, hand_index, effect_args)
  if type(player) ~= "table" or type(player.hand) ~= "table" then
    return nil, nil, "invalid_player"
  end
  if type(hand_index) ~= "number" or hand_index < 1 or hand_index > #player.hand then
    return nil, nil, "invalid_hand_index"
  end
  local eligible = abilities.find_matching_spell_hand_indices(player, effect_args)
  if not list_has_number(eligible, hand_index) then
    return nil, nil, "hand_card_not_eligible"
  end
  local card_id, card_def, err = load_hand_card_def(player, hand_index, "invalid_spell_card")
  if err then return nil, nil, err end
  if card_def.kind ~= "Spell" then
    return nil, nil, "invalid_spell_card"
  end
  return card_id, card_def, nil
end

local function execute_validated_spell_cast_command(g, opts)
  opts = opts or {}
  local pi = opts.player_index
  local p = opts.player
  local spell_id = opts.spell_id
  local spell_def = opts.spell_def
  local target_player_index = opts.target_player_index
  local target_board_index = opts.target_board_index
  local cast_action = opts.cast_action

  if type(pi) ~= "number" or type(p) ~= "table" or type(spell_def) ~= "table" or type(cast_action) ~= "function" then
    return fail("invalid_spell_cast_command")
  end

  local cast_ok, cast_reason, cast_info, failure_stage = spell_cast.perform_validated_cast(g, {
    caster_player = p,
    caster_index = pi,
    spell_def = spell_def,
    target_player_index = target_player_index,
    target_board_index = target_board_index,
    cast_action = cast_action,
  })
  if not cast_ok then
    if failure_stage == "target_validation" then
      return fail(cast_reason or opts.invalid_target_reason or "invalid_spell_target")
    end
    return fail(cast_reason or opts.cast_fail_reason or "spell_cast_failed")
  end

  local resolve_result = type(cast_info) == "table" and cast_info.resolve_result or nil
  local cast_spell_id = type(cast_info) == "table" and cast_info.spell_id or spell_id

  local meta = type(opts.success_meta) == "table" and copy_table(opts.success_meta) or {}
  meta.card_id = cast_spell_id
  meta.resolve_result = resolve_result

  local event = type(opts.success_event) == "table" and copy_table(opts.success_event) or {}
  event.type = event.type or "spell_cast"
  event.player_index = pi
  event.card_id = cast_spell_id

  if type(opts.source) == "table" and type(opts.ability_index) == "number" then
    return succeed_activated_command(g, pi, opts.source, opts.ability_index, {
      meta = meta,
      event = event,
      event_type = event.type,
      include_source_event = opts.include_source_event == true,
      include_ability_event = opts.include_ability_event == true,
    })
  end

  return succeed(g, meta, { event })
end

function commands.execute(g, command)
  if not command or not command.type then
    return fail("missing_command_type")
  end
  if g and g.is_terminal then
    return fail("game_over")
  end
  if g then
    -- Mark the derived stat cache as unstable while this command mutates state;
    -- `succeed()` restores a warmed stable cache on success.
    g._derived_stats_cache_token = nil
  end

  if command.type == "START_TURN" then
    if type(command.player_index) ~= "number" then
      return fail("missing_player_index")
    end
    if command.player_index ~= g.activePlayer then
      return fail("not_active_player")
    end
    actions.start_turn(g)
    return succeed(g,
      { active_player = g.activePlayer, turn_number = g.turnNumber },
      { { type = "turn_started", player_index = g.activePlayer, turn_number = g.turnNumber } }
    )
  end

  if command.type == "END_TURN" then
    if type(command.player_index) ~= "number" then
      return fail("missing_player_index")
    end
    if command.player_index ~= g.activePlayer then
      return fail("not_active_player")
    end

    local ending_player = g.activePlayer
    actions.end_turn(g)
    return succeed(g,
      { active_player = g.activePlayer, turn_number = g.turnNumber },
      { { type = "turn_ended", player_index = ending_player }, { type = "active_player_changed", player_index = g.activePlayer } }
    )
  end

  if command.type == "DECLARE_ATTACKERS" then
    local ok_decl, reason = combat.declare_attackers(g, command.player_index, command.declarations)
    if not ok_decl then return fail(reason) end
    return succeed(g,nil, { { type = "attackers_declared", player_index = command.player_index } })
  end

  if command.type == "ASSIGN_ATTACK_TRIGGER_TARGETS" then
    local ok_targets, reason = combat.assign_attack_trigger_targets(g, command.player_index, command.targets)
    if not ok_targets then return fail(reason) end
    return succeed(g,nil, { { type = "attack_trigger_targets_assigned", player_index = command.player_index } })
  end

  if command.type == "ASSIGN_BLOCKERS" then
    local ok_blk, reason = combat.assign_blockers(g, command.player_index, command.assignments)
    if not ok_blk then return fail(reason) end
    return succeed(g,nil, { { type = "blockers_assigned", player_index = command.player_index } })
  end

  if command.type == "RESOLVE_COMBAT" then
    local ok_res, reason = combat.resolve(g)
    if not ok_res then return fail(reason) end
    return succeed(g,nil, { { type = "combat_resolved" } })
  end

  if command.type == "ASSIGN_DAMAGE_ORDER" then
    local ok_ord, reason = combat.assign_damage_order(g, command.player_index, command.orders)
    if not ok_ord then return fail(reason) end
    return succeed(g,nil, { { type = "damage_order_assigned", player_index = command.player_index } })
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
    return succeed(g,
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
    return succeed(g,nil, { { type = "worker_assigned", player_index = pi, resource = resource } })
  end

  if command.type == "UNASSIGN_WORKER" then
    local pi = command.player_index
    local resource = command.resource
    if not VALID_RESOURCES[resource] then return fail("invalid_resource") end
    if pi ~= g.activePlayer then return fail("not_active_player") end

    local p = g.players[pi + 1]
    if p.workersOn[resource] <= 0 then return fail("no_worker_on_resource") end

    actions.unassign_worker_from_resource(g, pi, resource)
    return succeed(g,nil, { { type = "worker_unassigned", player_index = pi, resource = resource } })
  end

  if command.type == "BUILD_STRUCTURE" then
    local built, build_reason, resolve_result = actions.build_structure(g, command.player_index, command.card_id)
    if not built then return fail("build_not_allowed") end
    return succeed(g,
      { card_id = command.card_id, resolve_result = resolve_result },
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

    local card_def, source_key, _, source_err = resolve_activated_source_def(p, source, ability_index)
    if source_err then return fail(source_err) end

    if not can_activate(g, pi, card_def, source_key, ability_index, source) then
      return fail("ability_not_activatable")
    end

    local activated, activate_reason, resolve_result = actions.activate_ability(g, pi, card_def, source_key, ability_index, source)
    if not activated then
      return fail(activate_reason or "activate_failed")
    end
    return succeed_activated_command(g, pi, source, ability_index, {
      meta = { resolve_result = resolve_result },
      event_type = "ability_activated",
      include_source_event = true,
      include_ability_event = true,
    })
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
    if not fast_in_blocker_window(g, pi, command) then
      if pi ~= g.activePlayer then return fail("not_active_player") end
      if g.phase ~= "MAIN" then return fail("wrong_phase") end
    end

    local actx, actx_reason = resolve_command_activated_ability(g, pi, p, source, ability_index, {
      allowed_effects = "play_unit",
      invalid_effect_reason = "not_play_unit_ability",
      require_can_activate = true,
    })
    if not actx then return fail(actx_reason) end
    local card_def = actx.card_def
    local source_key = actx.source_key
    local ab = actx.ability

    if hand_index < 1 or hand_index > #p.hand then return fail("invalid_hand_index") end
    local matching = abilities.find_matching_hand_indices(p, ab.effect_args)
    local is_eligible = false
    for _, idx in ipairs(matching) do
      if idx == hand_index then is_eligible = true; break end
    end
    if not is_eligible then return fail("hand_card_not_eligible") end

    local card_id = p.hand[hand_index]
    local played, play_reason, resolve_result = actions.play_unit_from_hand(g, pi, card_def, source_key, ability_index, hand_index)
    if not played then
      return fail(play_reason or "play_failed")
    end
    return succeed_activated_command(g, pi, source, ability_index, {
      meta = { card_id = card_id, hand_index = hand_index, resolve_result = resolve_result },
      event_type = "unit_played_from_hand",
      event = { card_id = card_id },
      include_source_event = true,
      include_ability_event = true,
    })
  end

  if command.type == "PLAY_SPELL_VIA_ABILITY" then
    local pi = command.player_index
    local source = command.source
    local ability_index = command.ability_index
    local hand_index = command.hand_index
    local sacrifice_target_board_index = command.sacrifice_target_board_index
    local target_player_index = command.target_player_index
    local target_board_index = command.target_board_index
    local p = g.players[pi + 1]

    if not p or not source or not ability_index or not hand_index then
      return fail("invalid_payload")
    end
    if not fast_in_blocker_window(g, pi, command) then
      if pi ~= g.activePlayer then return fail("not_active_player") end
      if g.phase ~= "MAIN" then return fail("wrong_phase") end
    end

    -- Resolve source ability
    local actx, actx_reason = resolve_command_activated_ability(g, pi, p, source, ability_index, {
      allowed_effects = { "play_spell", "sacrifice_cast_spell" },
      invalid_effect_reason = "not_play_spell_ability",
      require_can_activate = true,
    })
    if not actx then return fail(actx_reason) end
    local src_card_def = actx.card_def
    local source_key = actx.source_key
    local ab = actx.ability
    local is_play_spell = (ab.effect == "play_spell")
    local is_sac_cast_spell = (ab.effect == "sacrifice_cast_spell")

    local spell_id, spell_def, spell_sel_reason =
      validate_ability_spell_hand_selection(p, hand_index, ab.effect_args)
    if spell_sel_reason then return fail(spell_sel_reason) end

    if is_sac_cast_spell then
      if type(sacrifice_target_board_index) ~= "number" then
        return fail("missing_sacrifice_target")
      end
      local sac_ok, _ = abilities.validate_activated_selection_cost(g, pi, ab, {
        target_board_index = sacrifice_target_board_index,
      })
      if not sac_ok then return fail("invalid_sacrifice_target") end
    end

    return execute_validated_spell_cast_command(g, {
      player_index = pi,
      player = p,
      source = source,
      ability_index = ability_index,
      spell_id = spell_id,
      spell_def = spell_def,
      target_player_index = target_player_index,
      target_board_index = target_board_index,
      cast_fail_reason = "play_spell_via_ability_failed",
      success_meta = { ability_index = ability_index },
      success_event = { type = "spell_cast_via_ability" },
      cast_action = function(resolve_on_cast)
        return actions.activate_play_spell_via_ability(
          g, pi, src_card_def, source_key, ability_index, source, hand_index, {
            expected_spell_id = spell_id,
            spell_def = spell_def,
            sacrifice_target_board_index = sacrifice_target_board_index,
            resolve_on_cast = resolve_on_cast,
          })
      end,
    })
  end

  if command.type == "ASSIGN_STRUCTURE_WORKER" then
    local pi = command.player_index
    local board_index = command.board_index
    if pi ~= g.activePlayer then return fail("not_active_player") end
    local assigned, assign_reason, assigned_board_index = actions.assign_worker_to_structure(g, pi, board_index)
    if not assigned then
      return fail(assign_reason or "assign_failed")
    end
    return succeed(g,nil, {
      { type = "structure_worker_assigned", player_index = pi, board_index = assigned_board_index or board_index },
    })
  end

  if command.type == "UNASSIGN_STRUCTURE_WORKER" then
    local pi = command.player_index
    local board_index = command.board_index
    if pi ~= g.activePlayer then return fail("not_active_player") end
    local unassigned, unassign_reason = actions.unassign_worker_from_structure(g, pi, board_index)
    if not unassigned then
      return fail(unassign_reason or "unassign_failed")
    end
    return succeed(g,nil, { { type = "structure_worker_unassigned", player_index = pi, board_index = board_index } })
  end

  if command.type == "DEPLOY_WORKER_TO_UNIT_ROW" then
    local pi = command.player_index
    if pi ~= g.activePlayer then return fail("not_active_player") end

    local deployed = actions.deploy_worker_to_unit_row(g, pi)
    if not deployed then return fail("deploy_worker_failed") end

    return succeed(g,nil, { { type = "worker_deployed_to_unit_row", player_index = pi } })
  end

  if command.type == "RECLAIM_WORKER_FROM_UNIT_ROW" then
    local pi = command.player_index
    local board_index = command.board_index
    if pi ~= g.activePlayer then return fail("not_active_player") end
    if not board_index then return fail("missing_board_index") end

    local reclaimed = actions.reclaim_worker_from_unit_row(g, pi, board_index)
    if not reclaimed then return fail("reclaim_worker_failed") end

    return succeed(g,nil, { { type = "worker_reclaimed_from_unit_row", player_index = pi, board_index = board_index } })
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

    local sac_ab = abilities.find_static_effect_ability(card_def, "play_cost_sacrifice")
    if not sac_ab then return fail("card_not_playable") end
    local sac_ok, sac_reason = abilities.validate_card_play_cost_selection(g, pi, card_def, {
      sacrifice_targets = sacrifice_targets,
    })
    if not sac_ok then return fail(sac_reason or "invalid_sacrifice_targets") end

    local played = actions.play_from_hand(g, pi, hand_index, sacrifice_targets)
    if not played then return fail("play_failed") end
    return succeed(g,
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
    local sac_ab = abilities.find_static_effect_ability(card_def, "play_cost_sacrifice")
    if not sac_ab then return fail("card_not_playable") end
    local sac_ok, sac_reason = abilities.validate_card_play_cost_selection(g, pi, card_def, {
      available_unassigned_workers = actions.count_unassigned_workers(p),
    })
    if not sac_ok then return fail(sac_reason or "not_enough_workers") end
    local played = actions.play_from_hand(g, pi, hand_index)
    if not played then return fail("play_failed") end
    return succeed(g,
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
    return succeed(g,nil, { { type = "special_worker_assigned", player_index = pi, sw_index = sw_index, target = target } })
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
    return succeed(g,nil, { { type = "special_worker_unassigned", player_index = pi, sw_index = sw_index } })
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

    local actx, actx_reason = resolve_command_activated_ability(g, pi, p, source, ability_index, {
      require_board_source = true,
      allowed_effects = "sacrifice_upgrade",
      invalid_effect_reason = "not_sacrifice_upgrade_ability",
      require_can_activate = true,
    })
    if not actx then return fail(actx_reason) end
    local card_def = actx.card_def
    local source_key = actx.source_key
    local ab = actx.ability
    local sel_ok, sel_reason = abilities.validate_activated_selection_cost(g, pi, ab, {
      target_board_index = target_board_index,
      target_worker = target_worker,
      target_worker_extra = target_worker_extra,
    })
    if not sel_ok then return fail(sel_reason or "invalid_sacrifice_target") end
    local upgrade_subtypes = required_upgrade_subtypes(ab.effect_args)

    local sacrificed_tier = 0
    if target_board_index then
      local entry = p.board[target_board_index]
      if not entry then return fail("invalid_sacrifice_target") end
      local ok_t, tdef = pcall(cards.get_card_def, entry.card_id)
      if not ok_t or not tdef or tdef.kind == "Structure" or tdef.kind == "Artifact" or not has_any_subtype(tdef, upgrade_subtypes) then
        return fail("invalid_sacrifice_target")
      end
      sacrificed_tier = tdef.tier or 0
    else
      sacrificed_tier = 0
    end

    if hand_index < 1 or hand_index > #p.hand then return fail("invalid_hand_index") end
    local hand_id = p.hand[hand_index]
    local ok_h, hdef = pcall(cards.get_card_def, hand_id)
    if not ok_h or not hdef or not has_any_subtype(hdef, upgrade_subtypes) or (hdef.tier or 0) ~= (sacrificed_tier + 1) then
      return fail("hand_card_not_eligible")
    end

    local ok_apply, apply_reason, upgrade_info = actions.activate_sacrifice_upgrade_play(
      g, pi, card_def, source_key, ability_index, source, hand_index, {
      target_board_index = target_board_index,
      target_worker = target_worker,
      target_worker_extra = target_worker_extra,
    })
    if not ok_apply then
      return fail(apply_reason or "upgrade_failed")
    end
    local resolve_result = type(upgrade_info) == "table" and upgrade_info.resolve_result or nil
    local played_card_id = (type(upgrade_info) == "table" and upgrade_info.card_id) or hand_id

    return succeed_activated_command(g, pi, source, ability_index, {
      meta = { card_id = played_card_id, resolve_result = resolve_result },
      event_type = "unit_played_from_sacrifice_upgrade",
      event = { card_id = played_card_id },
    })
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

    local actx, actx_reason = resolve_command_activated_ability(g, pi, p, source, ability_index, {
      allowed_effects = "sacrifice_produce",
      invalid_effect_reason = "not_sacrifice_ability",
      require_can_activate = true,
    })
    if not actx then return fail(actx_reason) end
    local card_def = actx.card_def
    local source_key = actx.source_key
    local ab = actx.ability

    local sel_ok, sel_reason = abilities.validate_activated_selection_cost(g, pi, ab, {
      target_board_index = target_board_index,
      target_worker = target_worker,
      target_worker_extra = command.target_worker_extra,
    })
    if not sel_ok then
      return fail(sel_reason or "invalid_sacrifice_target")
    end

    local sacrificed, sacrifice_reason, exec_info =
      actions.activate_sacrifice_produce(g, pi, card_def, source_key, ability_index, {
        source = source,
        target_board_index = target_board_index,
        target_worker = target_worker,
        target_worker_extra = command.target_worker_extra,
      })
    if not sacrificed then
      return fail(sacrifice_reason or "sacrifice_failed")
    end

    local payment = type(exec_info) == "table" and exec_info.payment or nil
    if payment and payment.sacrificed_kind == "Worker" then
      return succeed_activated_command(g, pi, source, ability_index, {
        meta = { target_worker = true },
        event_type = "worker_sacrificed",
      })
    end

    local sacrificed_id = payment and payment.sacrificed_card_id or nil
    local sacrificed_board_index = payment and payment.target_board_index or target_board_index
    return succeed_activated_command(g, pi, source, ability_index, {
      meta = { target_board_index = sacrificed_board_index, card_id = sacrificed_id },
      event_type = "unit_sacrificed",
      event = { target_board_index = sacrificed_board_index },
    })
  end

  if command.type == "RETURN_FROM_GRAVEYARD" then
    local pi = command.player_index
    local source = command.source
    local ability_index = command.ability_index
    local selected = command.selected_graveyard_indices
    local p = g.players[pi + 1]

    if not p or not source or not ability_index then return fail("invalid_payload") end
    if pi ~= g.activePlayer then return fail("not_active_player") end
    if g.phase ~= "MAIN" then return fail("wrong_phase") end
    local actx, actx_reason = resolve_command_activated_ability(g, pi, p, source, ability_index, {
      require_board_source = true,
      allowed_effects = "return_from_graveyard",
      invalid_effect_reason = "not_return_ability",
    })
    if not actx then return fail(actx_reason) end
    local entry = actx.source_entry
    local card_def = actx.card_def
    local ab = actx.ability
    local source_key = actx.source_key
    local pre_ok, pre_reason = precheck_command_activated_costs(g, pi, p, source, ability_index, source_key, ab)
    if not pre_ok then return fail(pre_reason) end

    if type(selected) ~= "table" or #selected == 0 then return fail("no_cards_selected") end
    local args = ab.effect_args or {}
    local max_count = args.count or 1
    if #selected > max_count then return fail("too_many_selected") end

    local req_tier = args.tier
    local req_subtypes = args.subtypes
    local req_target = args.target
    local function card_matches(cdef)
      if not cdef then return false end
      if req_tier ~= nil and (cdef.tier or 0) ~= req_tier then return false end
      if req_target == "unit" and cdef.kind ~= "Unit" and cdef.kind ~= "Worker" then return false end
      if req_subtypes and #req_subtypes > 0 then
        if not cdef.subtypes then return false end
        local found = false
        for _, req in ipairs(req_subtypes) do
          for _, got in ipairs(cdef.subtypes) do
            if req == got then found = true; break end
          end
          if found then break end
        end
        if not found then return false end
      end
      return true
    end

    -- Validate each selected index
    local to_return = {}
    local seen = {}
    for _, gi in ipairs(selected) do
      if type(gi) ~= "number" or gi < 1 or gi > #p.graveyard or seen[gi] then
        return fail("invalid_graveyard_index")
      end
      seen[gi] = true
      local gentry = p.graveyard[gi]
      local ok_g, gdef = pcall(cards.get_card_def, gentry.card_id)
      if not ok_g or not gdef or not card_matches(gdef) then
        return fail("invalid_graveyard_card")
      end
      to_return[#to_return + 1] = { gi = gi, card_id = gentry.card_id }
    end

    -- Pay cost and mark used
    local paid_ok, paid_reason = pay_and_mark_command_activated_costs(g, pi, p, source, ability_index, source_key, ab)
    if not paid_ok then return fail(paid_reason) end

    -- Remove from graveyard highest-index first, then add to board or hand
    table.sort(to_return, function(a, b) return a.gi > b.gi end)
    local returned = {}
    for _, etr in ipairs(to_return) do
      table.remove(p.graveyard, etr.gi)
      if args.return_to == "hand" then
        p.hand[#p.hand + 1] = etr.card_id
      else
        append_board_entry(g, p, {
          card_id = etr.card_id,
          state = { rested = false, summoned_turn = g.turnNumber },
        })
      end
      returned[#returned + 1] = etr.card_id
    end

    local destination = (args.return_to == "hand") and "hand" or "board"
    local resolve_result = synthetic_resolve_result(ab.effect, source, {
      {
        type = "cards_returned_from_graveyard",
        count = #returned,
        destination = destination,
        card_ids = copy_table(returned),
      },
    })

    return succeed_activated_command(g, pi, source, ability_index, {
      meta = {
        summoned = returned,
        returned_count = #returned,
        resolve_result = resolve_result,
        card_id = entry.card_id,
      },
      event_type = "units_returned_from_graveyard",
      event = { count = #returned },
    })
  end

  if command.type == "PLAY_MONUMENT_FROM_HAND" then
    local pi = command.player_index
    local hand_index = command.hand_index
    local monument_board_index = command.monument_board_index
    if pi ~= g.activePlayer then return fail("not_active_player") end
    if g.phase ~= "MAIN" then return fail("wrong_phase") end
    local p = g.players[pi + 1]
    if not hand_index or hand_index < 1 or hand_index > #p.hand then return fail("invalid_hand_index") end
    if not monument_board_index then return fail("missing_monument_board_index") end

    local card_id = p.hand[hand_index]
    local card_ok, card_def = pcall(cards.get_card_def, card_id)
    if not card_ok or not card_def then return fail("invalid_card") end

    local mon_ab = abilities.find_static_effect_ability(card_def, "monument_cost")
    if not mon_ab then return fail("card_not_monument_playable") end

    local played, play_reason, resolve_result = actions.play_monument_card(g, pi, hand_index, monument_board_index)
    if not played then return fail("play_monument_failed") end
    return succeed(g,
      { card_id = card_id, resolve_result = resolve_result },
      { { type = "monument_card_played", player_index = pi, card_id = card_id } }
    )
  end

  if command.type == "DEAL_DAMAGE_TO_TARGET" then
    local pi = command.player_index
    local source = command.source
    local ability_index = command.ability_index
    local target_player_index = command.target_player_index
    local target_board_index = command.target_board_index
    local p = g.players[pi + 1]

    if not p or not source or not ability_index then return fail("invalid_payload") end
    if not fast_in_blocker_window(g, pi, command) then
      if pi ~= g.activePlayer then return fail("not_active_player") end
      if g.phase ~= "MAIN" then return fail("wrong_phase") end
    end
    local actx, actx_reason = resolve_command_board_activated_ability(g, pi, p, source, ability_index, {
      allowed_effects = "deal_damage",
      invalid_effect_reason = "not_deal_damage_ability",
    })
    if not actx then return fail(actx_reason) end
    local source_entry = actx.source_entry
    local card_def = actx.card_def
    local ab = actx.ability
    local source_key = actx.source_key

    local pre_ok, pre_reason = precheck_command_activated_costs(g, pi, p, source, ability_index, source_key, ab, {
      source_entry = source_entry,
    })
    if not pre_ok then return fail(pre_reason) end

    local args = ab.effect_args or {}
    local damage = args.damage or 0

    local is_base_target = (command.target_is_base == true)
    if is_base_target then
      local target_ok, target_reason = abilities.validate_effect_target_selection(
        g, pi, ab.effect, args, target_player_index, nil, { target_is_base = true }
      )
      if not target_ok then return fail(target_reason or "invalid_target") end
    else
      local target_ok, target_reason = abilities.validate_effect_target_selection(
        g, pi, ab.effect, args, target_player_index, target_board_index, { target_is_base = false }
      )
      if not target_ok then return fail(target_reason or "invalid_target") end
    end

    -- Pay costs
    local paid_ok, paid_reason = pay_and_mark_command_activated_costs(g, pi, p, source, ability_index, source_key, ab, {
      source_entry = source_entry,
    })
    if not paid_ok then return fail(paid_reason) end

    if args.sacrifice_self and source.type == "board" then
      actions.destroy_board_entry_any(g, pi, source.index)
    end

    if is_base_target then
      local tp = g.players[target_player_index + 1]
      tp.life = math.max(0, (tp.life or 0) - damage)
      local resolve_result = synthetic_resolve_result(ab.effect, source, {
        {
          type = "damage_dealt",
          damage = damage,
          target_player_index = target_player_index,
          target_is_base = true,
        },
      })
      return succeed_activated_command(g, pi, source, ability_index, {
        meta = {
          damage = damage,
          target_player_index = target_player_index,
          target_is_base = true,
          resolve_result = resolve_result,
          card_id = source_entry.card_id,
        },
        event_type = "damage_dealt",
        event = { damage = damage },
      })
    end

    actions.apply_damage_to_unit(g, target_player_index, target_board_index, damage)
    local resolve_result = synthetic_resolve_result(ab.effect, source, {
      {
        type = "damage_dealt",
        damage = damage,
        target_player_index = target_player_index,
        target_board_index = target_board_index,
      },
    })

    return succeed_activated_command(g, pi, source, ability_index, {
      meta = {
        damage = damage,
        target_player_index = target_player_index,
        target_board_index = target_board_index,
        resolve_result = resolve_result,
        card_id = source_entry.card_id,
      },
      event_type = "damage_dealt",
      event = { damage = damage },
    })
  end

  if command.type == "PLACE_COUNTER_ON_TARGET" then
    local pi = command.player_index
    local source = command.source
    local ability_index = command.ability_index
    local target_board_index = command.target_board_index
    local p = g.players[pi + 1]

    if not p or not source or not ability_index then return fail("invalid_payload") end
    if not fast_in_blocker_window(g, pi, command) then
      if pi ~= g.activePlayer then return fail("not_active_player") end
      if g.phase ~= "MAIN" then return fail("wrong_phase") end
    end
    local actx, actx_reason = resolve_command_board_activated_ability(g, pi, p, source, ability_index, {
      allowed_effects = "place_counter_on_target",
      invalid_effect_reason = "not_place_counter_ability",
    })
    if not actx then return fail(actx_reason) end
    local source_entry = actx.source_entry
    local card_def = actx.card_def
    local ab = actx.ability
    local source_key = actx.source_key

    local pre_ok, pre_reason = precheck_command_activated_costs(g, pi, p, source, ability_index, source_key, ab, {
      source_entry = source_entry,
    })
    if not pre_ok then return fail(pre_reason) end

    local target_ok, target_reason = abilities.validate_effect_target_selection(
      g, pi, ab.effect, ab.effect_args or {}, pi, target_board_index, { target_is_base = false }
    )
    if not target_ok then return fail(target_reason or "invalid_target") end
    local target_entry = p.board[target_board_index]

    -- Pay costs
    local paid_ok, paid_reason = pay_and_mark_command_activated_costs(g, pi, p, source, ability_index, source_key, ab, {
      source_entry = source_entry,
    })
    if not paid_ok then return fail(paid_reason) end

    -- Apply effect
    local resolve_result = abilities.resolve(ab, p, g, {
      source = source,
      source_entry = source_entry,
      target_entry = target_entry,
      source_key = source_key,
      ability_index = ability_index,
      player_index = pi,
    })

    return succeed_activated_command(g, pi, source, ability_index, {
      meta = { target_board_index = target_board_index, resolve_result = resolve_result },
      event_type = "counter_placed_on_target",
      event = { target_board_index = target_board_index },
    })
  end

  if command.type == "PLAY_SPELL_FROM_HAND" then
    local pi = command.player_index
    local hand_index = command.hand_index
    if pi ~= g.activePlayer then return fail("not_active_player") end
    if g.phase ~= "MAIN" then return fail("wrong_phase") end
    local p = g.players[pi + 1]
    local card_id, card_def, spell_sel_reason = validate_direct_spell_hand_selection(p, hand_index)
    if spell_sel_reason then return fail(spell_sel_reason) end

    -- Check for monument cost ability (overrides resource cost)
    local mon_cost_ab = abilities.find_static_effect_ability(card_def, "monument_cost")
    local monument_board_index = command.monument_board_index
    if mon_cost_ab then
      local monument_ok, monument_reason = abilities.validate_card_play_cost_selection(g, pi, card_def, {
        monument_board_index = monument_board_index,
      })
      if not monument_ok then return fail(monument_reason or "invalid_monument_cost") end
    else
      if not abilities.can_pay_cost(p.resources, card_def.costs) then return fail("insufficient_resources") end
    end

    -- Validate target requirements for targeted on_cast abilities
    local target_player_index = command.target_player_index
    local target_board_index = command.target_board_index

    return execute_validated_spell_cast_command(g, {
      player_index = pi,
      player = p,
      spell_id = card_id,
      spell_def = card_def,
      target_player_index = target_player_index,
      target_board_index = target_board_index,
      cast_fail_reason = "spell_cast_failed",
      success_event = { type = "spell_cast" },
      cast_action = function(resolve_on_cast)
        return actions.play_spell_from_hand(g, pi, hand_index, {
          expected_spell_id = card_id,
          spell_def = card_def,
          monument_board_index = monument_board_index,
          resolve_on_cast = resolve_on_cast,
        })
      end,
    })
  end

  if command.type == "DEAL_DAMAGE_X_TO_TARGET" then
    local pi = command.player_index
    local source = command.source
    local ability_index = command.ability_index
    local target_player_index = command.target_player_index
    local target_board_index = command.target_board_index
    local x_amount = command.x_amount
    local p = g.players[pi + 1]

    if not p or not source or not ability_index then return fail("invalid_payload") end
    if not fast_in_blocker_window(g, pi, command) then
      if pi ~= g.activePlayer then return fail("not_active_player") end
      if g.phase ~= "MAIN" then return fail("wrong_phase") end
    end
    if type(x_amount) ~= "number" or x_amount < 1 then return fail("invalid_x_amount") end

    local actx, actx_reason = resolve_command_board_activated_ability(g, pi, p, source, ability_index, {
      allowed_effects = "deal_damage_x",
      invalid_effect_reason = "not_deal_damage_x_ability",
    })
    if not actx then return fail(actx_reason) end
    local source_entry = actx.source_entry
    local card_def = actx.card_def
    local ab = actx.ability
    local source_key = actx.source_key
    local args = ab.effect_args or {}
    local resource = args.resource or "stone"

    local pre_ok, pre_reason = precheck_command_activated_costs(g, pi, p, source, ability_index, source_key, ab, {
      x_amount = x_amount,
      source_entry = source_entry,
    })
    if not pre_ok then return fail(pre_reason) end

    local target_ok, target_reason = abilities.validate_effect_target_selection(
      g, pi, ab.effect, args, target_player_index, target_board_index, { target_is_base = false }
    )
    if not target_ok then return fail(target_reason or "invalid_target") end

    -- Pay costs
    local paid_ok, paid_reason = pay_and_mark_command_activated_costs(g, pi, p, source, ability_index, source_key, ab, {
      x_amount = x_amount,
      source_entry = source_entry,
    })
    if not paid_ok then return fail(paid_reason) end

    actions.apply_damage_to_unit(g, target_player_index, target_board_index, x_amount)
    local resolve_result = synthetic_resolve_result(ab.effect, source, {
      {
        type = "damage_dealt",
        damage = x_amount,
        target_player_index = target_player_index,
        target_board_index = target_board_index,
      },
    })

    return succeed_activated_command(g, pi, source, ability_index, {
      meta = {
        damage = x_amount,
        target_player_index = target_player_index,
        target_board_index = target_board_index,
        resolve_result = resolve_result,
        card_id = source_entry.card_id,
      },
      event_type = "damage_dealt",
      event = { damage = x_amount },
    })
  end

  if command.type == "DISCARD_DRAW_HAND" then
    local pi = command.player_index
    local source = command.source
    local ability_index = command.ability_index
    local hand_indices = command.hand_indices
    local p = g.players[pi + 1]

    if not p or not source or not ability_index or type(hand_indices) ~= "table" then
      return fail("invalid_discard_draw_payload")
    end
    if pi ~= g.activePlayer then return fail("not_active_player") end
    if g.phase ~= "MAIN" then return fail("wrong_phase") end

    local actx, actx_reason = resolve_command_activated_ability(g, pi, p, source, ability_index, {
      allowed_effects = "discard_draw",
      invalid_effect_reason = "not_discard_draw_ability",
      require_can_activate = true,
    })
    if not actx then return fail(actx_reason) end
    local card_def = actx.card_def
    local source_key = actx.source_key
    local source_entry_for_cost = actx.source_entry
    local ab = actx.ability

    local args = ab.effect_args or {}
    local required_discard = args.discard or 2
    local draw_amount = args.draw or 1

    if #hand_indices ~= required_discard then return fail("wrong_discard_count") end

    local seen = {}
    for _, hi in ipairs(hand_indices) do
      if type(hi) ~= "number" or hi < 1 or hi > #p.hand then return fail("invalid_hand_index") end
      if seen[hi] then return fail("duplicate_hand_index") end
      seen[hi] = true
    end

    -- Pay cost and mark used
    local paid_ok, paid_reason = pay_and_mark_command_activated_costs(g, pi, p, source, ability_index, source_key, ab, {
      source_entry = source_entry_for_cost,
    })
    if not paid_ok then return fail(paid_reason) end

    -- Discard in descending index order so earlier indices stay valid
    local sorted = {}
    for _, hi in ipairs(hand_indices) do sorted[#sorted + 1] = hi end
    table.sort(sorted, function(a, b) return a > b end)
    for _, hi in ipairs(sorted) do
      table.remove(p.hand, hi)
    end

    -- Draw
    local actual_draw_count = 0
    for _ = 1, draw_amount do
      if #p.deck > 0 then
        p.hand[#p.hand + 1] = table.remove(p.deck)
        actual_draw_count = actual_draw_count + 1
      end
    end

    local resolve_result = synthetic_resolve_result(ab.effect, source, {
      {
        type = "discard_draw_resolved",
        discard_count = required_discard,
        draw_count = actual_draw_count,
        requested_draw_count = draw_amount,
      },
    })

    return succeed_activated_command(g, pi, source, ability_index, {
      meta = {
        discard_count = required_discard,
        draw_count = draw_amount,
        resolve_result = resolve_result,
        card_id = card_def.id,
      },
      event_type = "discard_draw_resolved",
      event = { discard_count = required_discard, draw_count = draw_amount },
    })
  end

  return fail("unknown_command")
end

return commands
