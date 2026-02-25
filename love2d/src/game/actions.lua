-- Game actions: start turn, end turn, assign/unassign workers, activate abilities, draw cards.
-- Uses data/config.lua for production rates and other constants.

local config = require("src.data.config")
local cards = require("src.game.cards")
local abilities = require("src.game.abilities")
local game_events = require("src.game.events")
local game_state = require("src.game.state")
local unit_stats = require("src.game.unit_stats")

local actions = {}


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

local function is_activated_once_used(g, player_index, source_key, source, ability_index)
  return abilities.is_activated_ability_used_this_turn(g, player_index, source_key, source, ability_index)
end

local function set_activated_once_used(g, player_index, source_key, source, ability_index, used)
  abilities.set_activated_ability_used_this_turn(g, player_index, source_key, source, ability_index, used)
end

local function append_board_entry(g, player, entry)
  abilities.ensure_board_entry_instance_id(g, entry)
  player.board[#player.board + 1] = entry
  return entry
end

local function fire_on_ally_death_triggers(player, game_state, dead_card_def)
  local _, _, aggregate = game_events.emit(game_state, {
    type = "ally_died",
    player = player,
    dead_card_def = dead_card_def,
  })
  return aggregate
end

local function get_faction_worker_def(faction)
  local worker_defs = cards.filter({ kind = "Worker", faction = faction })
  for _, wd in ipairs(worker_defs) do
    if wd.tier == 0 and not wd.deckable then
      return wd
    end
  end
  return nil
end

local function consume_worker_target(p, worker_kind, worker_extra)
  if p.totalWorkers <= 0 then return false end

  if worker_kind == "worker_left" then
    local res_left = (p.faction == "Human") and "wood" or "food"
    if (p.workersOn[res_left] or 0) > 0 then
      p.workersOn[res_left] = p.workersOn[res_left] - 1
    else
      return false
    end
  elseif worker_kind == "worker_right" then
    if (p.workersOn.stone or 0) > 0 then
      p.workersOn.stone = p.workersOn.stone - 1
    else
      return false
    end
  elseif worker_kind == "structure_worker" then
    local bi = worker_extra
    if bi and p.board[bi] then
      local entry = p.board[bi]
      entry.workers = entry.workers or 0
      if entry.workers > 0 then
        entry.workers = entry.workers - 1
      else
        return false
      end
    else
      return false
    end
  elseif worker_kind == "worker_unassigned" or worker_kind == "unassigned_pool" then
    local unassigned = actions.count_unassigned_workers(p)
    if unassigned <= 0 then return false end
  else
    return false
  end

  p.totalWorkers = p.totalWorkers - 1
  return true
end

-- Check if a card def has a specific static effect
local function has_static_effect(card_def, effect_name)
  if not card_def or not card_def.abilities then return false end
  for _, ab in ipairs(card_def.abilities) do
    if ab.type == "static" and ab.effect == effect_name then return true end
  end
  return false
end

local function has_keyword(card_def, needle, state)
  if type(state) == "table" then
    local temp = state.temp_keywords
    local perm = state.perm_keywords
    local want_state = string.lower(needle)
    if type(temp) == "table" then
      if temp[want_state] == true or temp[needle] == true then
        return true
      end
      for _, kw in pairs(temp) do
        if type(kw) == "string" and string.lower(kw) == want_state then
          return true
        end
      end
    end
    if type(perm) == "table" then
      if perm[want_state] == true or perm[needle] == true then
        return true
      end
      for _, kw in pairs(perm) do
        if type(kw) == "string" and string.lower(kw) == want_state then
          return true
        end
      end
    end
  end

  if not card_def or not card_def.keywords then return false end
  local want = string.lower(needle)
  for _, kw in ipairs(card_def.keywords) do
    if string.lower(kw) == want then return true end
  end
  return false
end

local function entering_board_state(g, card_def, prior_state)
  local st = copy_table(prior_state or {})
  if st.rested == nil then st.rested = false end

  if card_def and (card_def.kind == "Unit" or card_def.kind == "Worker") then
    st.summoned_turn = g and g.turnNumber or st.summoned_turn
    -- Entering the battlefield creates a fresh combat object for turn-based attack limits.
    st.attacked_turn = nil
  end

  return st
end

local function should_skip_awaken(card_def)
  return has_static_effect(card_def, "cannot_awaken")
    or has_static_effect(card_def, "stay_rested")
    or has_static_effect(card_def, "prevent_awakening")
end

local function awaken_rested_board_combatants(player)
  for _, entry in ipairs(player.board) do
    local ok, card_def = pcall(cards.get_card_def, entry.card_id)
    if ok and card_def and (card_def.kind == "Unit" or card_def.kind == "Worker") then
      entry.state = entry.state or {}
      if entry.state.rested and not should_skip_awaken(card_def) then
        entry.state.rested = false
      end
    end
  end
end

local function special_worker_multiplier(sw_card_id)
  local ok, sw_def = pcall(cards.get_card_def, sw_card_id)
  if not ok or not sw_def then return 1 end
  if has_static_effect(sw_def, "double_production") then return 2 end
  return 1
end

local function fire_on_play_triggers(player, game_state, played_card_id)
  local _, _, aggregate = game_events.emit(game_state, {
    type = "card_played",
    player = player,
    card_id = played_card_id,
    triggers = { "on_play", "on_construct" },
  })
  return aggregate
end

local function destroy_board_entry(player, game_state, board_index)
  local target = player.board[board_index]
  if not target then return false end

  if target.workers and target.workers > 0 then
    target.workers = 0
  end
  for _, sw in ipairs(player.specialWorkers) do
    if sw.assigned_to == board_index then
      sw.assigned_to = nil
    elseif type(sw.assigned_to) == "table" and sw.assigned_to.type == "field" and sw.assigned_to.board_index == board_index then
      sw.assigned_to = nil
    end
  end

  if target.special_worker_index and player.specialWorkers[target.special_worker_index] then
    local ref = player.specialWorkers[target.special_worker_index]
    ref.state = copy_table(target.state or ref.state or {})
    ref.assigned_to = nil
  end

  local t_ok, t_def = pcall(cards.get_card_def, target.card_id)
  if t_ok and t_def then
    game_events.emit(game_state, {
      type = "card_destroyed",
      player = player,
      card_def = t_def,
    })
  end

  player.graveyard[#player.graveyard + 1] = { card_id = target.card_id, state = copy_table(target.state or {}) }
  table.remove(player.board, board_index)
  for _, sw in ipairs(player.specialWorkers) do
    if type(sw.assigned_to) == "number" and sw.assigned_to > board_index then
      sw.assigned_to = sw.assigned_to - 1
    elseif type(sw.assigned_to) == "table" and sw.assigned_to.type == "field" and sw.assigned_to.board_index and sw.assigned_to.board_index > board_index then
      sw.assigned_to.board_index = sw.assigned_to.board_index - 1
    end
  end

  return true
end

local function pay_unit_upkeep(player, game_state)
  local upkeep_board_indices = {}
  for bi, entry in ipairs(player.board) do
    local ok, card_def = pcall(cards.get_card_def, entry.card_id)
    if ok and card_def and card_def.kind == "Unit" and card_def.upkeep and #card_def.upkeep > 0 then
      upkeep_board_indices[#upkeep_board_indices + 1] = bi
    end
  end

  -- Resolve from right to left so table.remove index shifts do not affect pending entries.
  for i = #upkeep_board_indices, 1, -1 do
    local bi = upkeep_board_indices[i]
    local entry = player.board[bi]
    if entry then
      local ok, card_def = pcall(cards.get_card_def, entry.card_id)
      if ok and card_def and card_def.kind == "Unit" then
        if abilities.can_pay_cost(player.resources, card_def.upkeep) then
          for _, cost in ipairs(card_def.upkeep) do
            player.resources[cost.type] = (player.resources[cost.type] or 0) - cost.amount
          end
        else
          destroy_board_entry(player, game_state, bi)
        end
      end
    end
  end
end

local function destroy_decaying_units(player, game_state)
  if not player or type(player.board) ~= "table" then
    return
  end

  local decay_indices = {}
  for bi, entry in ipairs(player.board) do
    local ok, card_def = pcall(cards.get_card_def, entry.card_id)
    if ok and card_def and (card_def.kind == "Unit" or card_def.kind == "Worker") then
      local st = entry.state or {}
      if has_keyword(card_def, "decaying", st) then
        decay_indices[#decay_indices + 1] = bi
      end
    end
  end

  for i = #decay_indices, 1, -1 do
    destroy_board_entry(player, game_state, decay_indices[i])
  end
end

local function clear_end_of_turn_modifiers(player)
  if not player or type(player.board) ~= "table" then
    return
  end
  for _, entry in ipairs(player.board) do
    if type(entry) == "table" and type(entry.state) == "table" then
      unit_stats.clear_end_of_turn(entry.state)
    end
  end
end

-- Get the monument_cost ability from a card def (returns ability or nil)
local function get_monument_cost_ability(card_def)
  return abilities.find_static_effect_ability(card_def, "monument_cost")
end

-- Get the play_cost_sacrifice ability from a card def (returns ability or nil)
local function get_sacrifice_ability(card_def)
  return abilities.find_static_effect_ability(card_def, "play_cost_sacrifice")
end

-- Draw cards from deck to hand
function actions.draw_card(g, player_index, count)
  local p = g.players[player_index + 1]
  return game_state.draw_cards(p, count or 1)
end

function actions.start_turn(g)
  g.activatedUsedThisTurn = {}
  local active = g.activePlayer
  local p = g.players[active + 1]
  awaken_rested_board_combatants(p)
  -- Gain workers
  p.totalWorkers = math.min(p.totalWorkers + config.workers_gained_per_turn, p.maxWorkers or 99)
  -- Produce resources from assigned workers
  p.resources.food  = p.resources.food  + p.workersOn.food  * config.production_per_worker
  p.resources.wood  = p.resources.wood  + p.workersOn.wood  * config.production_per_worker
  p.resources.stone = p.resources.stone + p.workersOn.stone * config.production_per_worker
  -- Produce resources from board structures with static produce abilities
  for _, entry in ipairs(p.board) do
    local ok, card_def = pcall(cards.get_card_def, entry.card_id)
    if ok and card_def and card_def.abilities then
      for _, ab in ipairs(card_def.abilities) do
        if ab.type == "static" and ab.effect == "produce" and ab.effect_args then
          local res = ab.effect_args.resource
          if ab.effect_args.per_worker then
            -- Worker-based production
            local w = entry.workers or 0
            local amount = w * ab.effect_args.per_worker
            if res and amount > 0 and p.resources[res] ~= nil then
              p.resources[res] = p.resources[res] + amount
            end
          else
            -- Passive production (existing behavior)
            local amount = ab.effect_args.amount or 0
            if res and amount > 0 and p.resources[res] ~= nil then
              p.resources[res] = p.resources[res] + amount
            end
          end
        end
      end
    end
  end
  -- Produce resources from special workers (ability-driven multiplier)
  for _, sw in ipairs(p.specialWorkers) do
    if sw.assigned_to ~= nil then
      local mult = special_worker_multiplier(sw.card_id)
      if type(sw.assigned_to) == "string" then
        local res = sw.assigned_to
        if p.resources[res] ~= nil then
          p.resources[res] = p.resources[res] + config.production_per_worker * mult
        end
      elseif type(sw.assigned_to) == "number" then
        local entry = p.board[sw.assigned_to]
        if entry then
          local ok_sw, sw_def = pcall(cards.get_card_def, entry.card_id)
          if ok_sw and sw_def and sw_def.abilities then
            for _, ab in ipairs(sw_def.abilities) do
              if ab.type == "static" and ab.effect == "produce" and ab.effect_args and ab.effect_args.per_worker then
                local res = ab.effect_args.resource
                if res and p.resources[res] ~= nil then
                  p.resources[res] = p.resources[res] + ab.effect_args.per_worker * mult
                end
              end
            end
          end
        end
      end
    end
  end
  -- Fire start_of_turn triggered abilities
  for _, entry in ipairs(p.board) do
    local ok, card_def = pcall(cards.get_card_def, entry.card_id)
    if ok and card_def and card_def.abilities then
      for _, ab in ipairs(card_def.abilities) do
        if ab.type == "triggered" and ab.trigger == "start_of_turn" then
          abilities.resolve(ab, p, g, { source_entry = entry })
        end
      end
    end
  end
  -- Draw a card (unless base has skip_draw, e.g. Orc Encampment)
  local base_def = cards.get_card_def(p.baseId)
  if not has_static_effect(base_def, "skip_draw") then
    actions.draw_card(g, active, 1)
  end
  g.phase = "MAIN"
  g.priorityPlayer = active
  return g
end

function actions.end_turn(g)
  local ending_player = g.players[g.activePlayer + 1]
  pay_unit_upkeep(ending_player, g)
  destroy_decaying_units(g.players[1], g)
  destroy_decaying_units(g.players[2], g)
  clear_end_of_turn_modifiers(ending_player)

  g.activePlayer = (g.activePlayer == 0) and 1 or 0
  g.turnNumber = g.turnNumber + 1
  g.priorityPlayer = g.activePlayer
  return g
end

function actions.count_structure_workers(p)
  local total = 0
  for _, entry in ipairs(p.board) do
    total = total + (entry.workers or 0)
  end
  return total
end

function actions.count_field_worker_cards(p)
  local total = 0
  for _, entry in ipairs(p.board) do
    local ok, def = pcall(cards.get_card_def, entry.card_id)
    if ok and def and def.kind == "Worker" and not entry.special_worker_index then
      total = total + 1
    end
  end
  return total
end

function actions.assign_worker_to_resource(g, player_index, resource)
  if player_index ~= g.activePlayer then return g end
  local p = g.players[player_index + 1]
  local unassigned = actions.count_unassigned_workers(p)
  if unassigned <= 0 then return g end
  p.workersOn[resource] = p.workersOn[resource] + 1
  return g
end

function actions.unassign_worker_from_resource(g, player_index, resource)
  if player_index ~= g.activePlayer then return g end
  local p = g.players[player_index + 1]
  if p.workersOn[resource] <= 0 then return g end
  p.workersOn[resource] = p.workersOn[resource] - 1
  return g
end

function actions.assign_worker_to_structure(g, player_index, board_index)
  if player_index ~= g.activePlayer then return false, "not_active_player" end
  if type(board_index) ~= "number" then return false, "missing_board_index" end

  local p = g.players[player_index + 1]
  if not p then return false, "invalid_player" end

  local entry = p.board[board_index]
  if not entry then return false, "invalid_board_index" end
  local ok, card_def = pcall(cards.get_card_def, entry.card_id)
  if not ok or not card_def then return false, "invalid_structure_card" end
  if card_def.kind ~= "Structure" then return false, "target_not_structure" end

  local max_w = 0
  if card_def.abilities then
    for _, ab in ipairs(card_def.abilities) do
      if ab.type == "static" and ab.effect == "produce" and ab.effect_args and ab.effect_args.per_worker then
        max_w = ab.effect_args.max_workers or 99
      end
    end
  end
  if max_w <= 0 then return false, "structure_not_worker_assignable" end
  if actions.count_unassigned_workers(p) <= 0 then return false, "no_unassigned_workers" end

  -- Try the requested entry first; if full, find another copy of the same card
  local target = entry
  local target_idx = board_index
  target.workers = target.workers or 0
  if target.workers + actions.count_special_on_structure(p, target_idx) >= max_w then
    local found = false
    for si, other in ipairs(p.board) do
      if other.card_id == entry.card_id and si ~= board_index then
        other.workers = other.workers or 0
        if other.workers + actions.count_special_on_structure(p, si) < max_w then
          target = other
          target_idx = si
          found = true
          break
        end
      end
    end
    if not found then return false, "structure_worker_capacity_reached" end
  end

  target.workers = target.workers + 1
  return true, nil, target_idx
end

function actions.unassign_worker_from_structure(g, player_index, board_index)
  if player_index ~= g.activePlayer then return false, "not_active_player" end
  if type(board_index) ~= "number" then return false, "missing_board_index" end

  local p = g.players[player_index + 1]
  if not p then return false, "invalid_player" end

  local entry = p.board[board_index]
  if not entry then return false, "invalid_board_index" end

  entry.workers = entry.workers or 0
  if entry.workers <= 0 then return false, "no_structure_worker_on_entry" end

  entry.workers = entry.workers - 1
  return true
end

-- Activate an ability on a card (base, structure, etc.)
-- source_key: unique string like "base:1" or "board:3:2" for tracking once-per-turn
-- ability_index: optional index into card_def.abilities (defaults to first activated)
function actions.activate_ability(g, player_index, card_def, source_key, ability_index, source)
  if g.phase ~= "MAIN" then return false, "wrong_phase" end
  if player_index ~= g.activePlayer then return false, "not_active_player" end
  local p = g.players[player_index + 1]

  local ability
  if ability_index and card_def.abilities then
    ability = card_def.abilities[ability_index]
  else
    ability = cards.get_activated_ability(card_def)
  end
  if not ability or ability.type ~= "activated" then return false, "invalid_ability" end

  -- Resolve source_entry early so rest cost can be checked.
  local source_entry = nil
  if type(source) == "table" and source.type == "board" and type(source.index) == "number" then
    source_entry = p.board[source.index]
  end

  if ability.once_per_turn and is_activated_once_used(g, player_index, source_key, source, ability_index) then
    return false, "ability_already_used"
  end
  local can_pay, can_pay_reason = abilities.can_pay_activated_ability_costs(p.resources, ability, {
    source_entry = source_entry,
    require_variable_min = true,
  })
  if not can_pay then return false, can_pay_reason or "insufficient_resources" end

  -- Pay activated costs (resources/x + rest)
  local paid, pay_reason = abilities.pay_activated_ability_costs(p.resources, ability, {
    source_entry = source_entry,
  })
  if not paid then return false, pay_reason or "insufficient_resources" end
  set_activated_once_used(g, player_index, source_key, source, ability_index, true)

  -- Resolve effect
  local resolve_result = abilities.resolve(ability, p, g, {
    source = source,
    source_entry = source_entry,
    source_key = source_key,
    ability_index = ability_index,
    player_index = player_index,
    activated_costs_paid = true,
  })

  return true, nil, resolve_result
end

-- Play a specific unit card from hand via a play_unit ability (two-step selection flow).
-- source_key: unique string like "board:3:2" for tracking once-per-turn
function actions.play_unit_from_hand(g, player_index, card_def, source_key, ability_index, hand_index)
  if g.phase ~= "MAIN" then return false, "wrong_phase" end
  if player_index ~= g.activePlayer then return false, "not_active_player" end
  local p = g.players[player_index + 1]

  local ability
  if ability_index and card_def.abilities then
    ability = card_def.abilities[ability_index]
  end
  if not ability or ability.type ~= "activated" or ability.effect ~= "play_unit" then
    return false, "not_play_unit_ability"
  end

  if ability.once_per_turn and is_activated_once_used(g, player_index, source_key, nil, ability_index) then
    return false, "ability_already_used"
  end
  local can_pay, can_pay_reason = abilities.can_pay_activated_ability_cost(p.resources, ability)
  if not can_pay then return false, can_pay_reason or "insufficient_resources" end

  -- Validate hand_index
  if not hand_index or hand_index < 1 or hand_index > #p.hand then return false, "invalid_hand_index" end
  local matching = abilities.find_matching_hand_indices(p, ability.effect_args)
  local is_eligible = false
  for _, idx in ipairs(matching) do
    if idx == hand_index then is_eligible = true; break end
  end
  if not is_eligible then return false, "hand_card_not_eligible" end

  -- Pay cost
  local paid, pay_reason = abilities.pay_activated_ability_cost(p.resources, ability)
  if not paid then return false, pay_reason or "insufficient_resources" end
  set_activated_once_used(g, player_index, source_key, nil, ability_index, true)

  -- Remove card from hand and place on board
  local card_id = p.hand[hand_index]
  table.remove(p.hand, hand_index)
  local played_def = nil
  local ok_played, maybe_played = pcall(cards.get_card_def, card_id)
  if ok_played then
    played_def = maybe_played
  end
  append_board_entry(g, p, {
    card_id = card_id,
    state = entering_board_state(g, played_def, {}),
  })

  -- Fire on_play triggered abilities
  local trigger_result = fire_on_play_triggers(p, g, card_id)

  return true, nil, trigger_result
end

local function load_spell_from_hand_for_cast(player, hand_index, opts)
  opts = opts or {}
  if type(player) ~= "table" then return nil, nil, "invalid_player" end
  if type(hand_index) ~= "number" or hand_index < 1 or hand_index > #(player.hand or {}) then
    return nil, nil, "invalid_hand_index"
  end
  local spell_id = player.hand[hand_index]
  if type(opts.expected_spell_id) == "string" and spell_id ~= opts.expected_spell_id then
    return nil, nil, "spell_hand_changed"
  end

  local spell_def = opts.spell_def
  if type(spell_def) ~= "table" then
    local ok_spell, maybe_spell = pcall(cards.get_card_def, spell_id)
    if not ok_spell or not maybe_spell then return nil, nil, "invalid_spell_card" end
    spell_def = maybe_spell
  end
  return spell_id, spell_def, nil
end

local function finalize_spell_cast_from_hand(player, hand_index, spell_def, spell_id, resolve_on_cast)
  if type(player) ~= "table" then return false, "invalid_player" end
  if type(hand_index) ~= "number" or hand_index < 1 or hand_index > #(player.hand or {}) then
    return false, "invalid_hand_index" end

  table.remove(player.hand, hand_index)

  local resolve_result = nil
  if type(resolve_on_cast) == "function" then
    resolve_result = resolve_on_cast(spell_def, spell_id)
  end

  player.graveyard = player.graveyard or {}
  player.graveyard[#player.graveyard + 1] = { card_id = spell_id }

  return true, nil, {
    spell_id = spell_id,
    spell_def = spell_def,
    resolve_result = resolve_result,
  }
end

-- Execute the mutation portion of casting a spell via an activated ability after
-- command-side target/eligibility validation has already passed.
function actions.activate_play_spell_via_ability(g, player_index, source_card_def, source_key, ability_index, source, hand_index, opts)
  opts = opts or {}
  local p = g and g.players and g.players[player_index + 1]
  if not p then return false, "invalid_player" end
  if type(source_card_def) ~= "table" or type(source_card_def.abilities) ~= "table" then
    return false, "no_abilities"
  end

  local ability = source_card_def.abilities[ability_index]
  local is_play_spell = ability and ability.type == "activated" and ability.effect == "play_spell"
  local is_sac_cast_spell = ability and ability.type == "activated" and ability.effect == "sacrifice_cast_spell"
  if not ability or not (is_play_spell or is_sac_cast_spell) then
    return false, "not_play_spell_ability"
  end

  if ability.once_per_turn and is_activated_once_used(g, player_index, source_key, source, ability_index) then
    return false, "ability_already_used"
  end

  local spell_id, spell_def, spell_err = load_spell_from_hand_for_cast(p, hand_index, opts)
  if spell_err then return false, spell_err end

  local source_entry = nil
  if type(source) == "table" and source.type == "board" and type(source.index) == "number" then
    source_entry = p.board[source.index]
  end

  local paid, pay_reason = abilities.pay_activated_ability_costs(p.resources, ability, {
    source_entry = source_entry,
  })
  if not paid then return false, pay_reason or "insufficient_resources" end
  if ability.once_per_turn then
    set_activated_once_used(g, player_index, source_key, source, ability_index, true)
  end

  local selection_payment = nil
  if is_sac_cast_spell then
    local paid_sel, sel_reason, payment_info =
      actions.pay_activated_selection_cost(g, player_index, ability, {
        target_board_index = opts.sacrifice_target_board_index,
      })
    if not paid_sel then
      return false, sel_reason or "sacrifice_failed"
    end
    selection_payment = payment_info
  end

  local ok_finish, finish_reason, finish_info = finalize_spell_cast_from_hand(
    p,
    hand_index,
    spell_def,
    spell_id,
    function(cast_spell_def, cast_spell_id)
      if type(opts.resolve_on_cast) == "function" then
        return opts.resolve_on_cast(cast_spell_def, cast_spell_id, ability)
      end
      return nil
    end
  )
  if not ok_finish then return false, finish_reason end

  finish_info.selection_payment = selection_payment
  return true, nil, finish_info
end

-- Execute the mutation portion of casting a spell directly from hand after
-- command-side eligibility/target validation has already passed.
function actions.play_spell_from_hand(g, player_index, hand_index, opts)
  opts = opts or {}
  if g.phase ~= "MAIN" then return false, "wrong_phase" end
  if player_index ~= g.activePlayer then return false, "not_active_player" end
  local p = g and g.players and g.players[player_index + 1]
  if not p then return false, "invalid_player" end

  local spell_id, spell_def, spell_err = load_spell_from_hand_for_cast(p, hand_index, opts)
  if spell_err then return false, spell_err end
  if spell_def.kind ~= "Spell" then return false, "not_a_spell" end

  local monument_board_index = opts.monument_board_index
  local mon_cost_ab = abilities.find_static_effect_ability(spell_def, "monument_cost")
  if mon_cost_ab then
    local paid_play_cost, pay_reason = actions.pay_card_play_cost(g, player_index, spell_def, {
      monument_board_index = monument_board_index,
    })
    if not paid_play_cost then return false, pay_reason or "insufficient_monument_counters" end
  else
    local paid_card, pay_reason = abilities.pay_cost(p.resources, spell_def.costs)
    if not paid_card then return false, pay_reason or "insufficient_resources" end
  end

  return finalize_spell_cast_from_hand(p, hand_index, spell_def, spell_id, opts.resolve_on_cast)
end



function actions.deploy_worker_to_unit_row(g, player_index)
  local p = g.players[player_index + 1]
  if not p then return false end
  if player_index ~= g.activePlayer then return false end

  if actions.count_unassigned_workers(p) <= 0 then return false end

  local worker_def = get_faction_worker_def(p.faction)
  if not worker_def then return false end

  p.workerStatePool = p.workerStatePool or {}
  local restored_state = nil
  if #p.workerStatePool > 0 then
    restored_state = table.remove(p.workerStatePool)
  end
  local final_state = entering_board_state(g, worker_def, restored_state or {})
  append_board_entry(g, p, { card_id = worker_def.id, state = final_state })
  return true
end

function actions.reclaim_worker_from_unit_row(g, player_index, board_index)
  local p = g.players[player_index + 1]
  if not p then return false end
  if player_index ~= g.activePlayer then return false end

  local entry = p.board[board_index]
  if not entry then return false end

  local ok_def, card_def = pcall(cards.get_card_def, entry.card_id)
  if not ok_def or not card_def or card_def.kind ~= "Worker" then
    return false
  end

  local est = entry.state or {}
  if est.rested then
    return false
  end

  p.workerStatePool = p.workerStatePool or {}
  p.workerStatePool[#p.workerStatePool + 1] = copy_table(entry.state or {})

  table.remove(p.board, board_index)
  for _, sw in ipairs(p.specialWorkers) do
    if type(sw.assigned_to) == "number" and sw.assigned_to > board_index then
      sw.assigned_to = sw.assigned_to - 1
    elseif type(sw.assigned_to) == "table" and sw.assigned_to.type == "field" and sw.assigned_to.board_index and sw.assigned_to.board_index > board_index then
      sw.assigned_to.board_index = sw.assigned_to.board_index - 1
    end
  end

  return true
end
function actions.resolve_on_play_triggers(g, player_index, card_id)
  local p = g.players[player_index + 1]
  if not p then return end
  return fire_on_play_triggers(p, g, card_id)
end

-- Build a structure from the blueprint deck
function actions.build_structure(g, player_index, card_id)
  if g.phase ~= "MAIN" or player_index ~= g.activePlayer then return false end
  local p = g.players[player_index + 1]

  if type(p.blueprintDeck) ~= "table" then
    p.blueprintDeck = {}
    for _, def in ipairs(cards.structures_for_faction(p.faction)) do
      local copies = def.population or 1
      for _ = 1, copies do
        p.blueprintDeck[#p.blueprintDeck + 1] = def.id
      end
    end
  end

  -- Validate card exists and is a Structure of the player's faction (or Neutral)
  local ok, card_def = pcall(cards.get_card_def, card_id)
  if not ok or not card_def then return false end
  if card_def.kind ~= "Structure" and card_def.kind ~= "Artifact" then return false end
  if card_def.faction ~= p.faction and card_def.faction ~= "Neutral" then return false end

  -- Check resource node requirement (e.g. "wood" means player must have a Wood node)
  if card_def.requires_resource then
    local res = card_def.requires_resource
    local res_left = (p.faction == "Human") and "wood" or "food"
    local has_node = (res == res_left or res == "stone")
    if not has_node then return false end
  end

  local blueprint_index = nil
  for i, blueprint_id in ipairs(p.blueprintDeck) do
    if blueprint_id == card_id then
      blueprint_index = i
      break
    end
  end
  if not blueprint_index then return false end

  -- Check affordability
  if not abilities.can_pay_cost(p.resources, card_def.costs) then return false end

  -- Check population limit
  if card_def.population then
    local count = 0
    for _, entry in ipairs(p.board) do
      if entry.card_id == card_id then count = count + 1 end
    end
    if count >= card_def.population then return false end
  end

  -- Pay costs
  local paid = abilities.pay_cost(p.resources, card_def.costs)
  if not paid then return false end

  -- Consume one copy from blueprint deck.
  table.remove(p.blueprintDeck, blueprint_index)

  -- Place on board
  append_board_entry(g, p, { card_id = card_id, workers = 0, state = { rested = false } })

  -- Fire on_play triggered abilities
  local trigger_result = fire_on_play_triggers(p, g, card_id)

  return true, nil, trigger_result
end

-- Sacrifice a worker token to produce a resource.
-- worker_kind: "worker_unassigned", "worker_left", "worker_right", "structure_worker", "unassigned_pool"
-- worker_extra: board_index for structure_worker, nil otherwise
function actions.activate_sacrifice_produce(g, player_index, card_def, source_key, ability_index, opts)
  opts = opts or {}
  if g.phase ~= "MAIN" then return false, "wrong_phase" end
  if player_index ~= g.activePlayer then return false, "not_active_player" end
  local p = g.players[player_index + 1]

  local ability
  if ability_index and card_def.abilities then
    ability = card_def.abilities[ability_index]
  end
  if not ability or ability.type ~= "activated" or ability.effect ~= "sacrifice_produce" then
    return false, "not_sacrifice_ability"
  end

  local source = opts.source
  if ability.once_per_turn and is_activated_once_used(g, player_index, source_key, source, ability_index) then
    return false, "ability_already_used"
  end

  local paid_sel, sel_reason, payment_info, selection_info = actions.pay_activated_selection_cost(g, player_index, ability, {
    target_board_index = opts.target_board_index,
    target_worker = opts.target_worker,
    target_worker_extra = opts.target_worker_extra,
  })
  if not paid_sel then
    if sel_reason == "target_not_eligible" then
      sel_reason = "invalid_sacrifice_target"
    end
    return false, sel_reason or "sacrifice_failed"
  end

  local args = ability.effect_args or {}
  local res = args.resource
  local amount = args.amount or 1
  if res then
    p.resources[res] = (p.resources[res] or 0) + amount
  end

  set_activated_once_used(g, player_index, source_key, source, ability_index, true)
  return true, nil, {
    payment = payment_info,
    selection = selection_info,
    resource = res,
    amount = amount,
  }
end

function actions.sacrifice_worker(g, player_index, card_def, source_key, ability_index, worker_kind, worker_extra)
  local ok, reason = actions.activate_sacrifice_produce(g, player_index, card_def, source_key, ability_index, {
    target_worker = worker_kind,
    target_worker_extra = worker_extra,
  })
  if not ok then return false, reason end
  return true
end

function actions.sacrifice_board_entry(g, player_index, target_board_index)
  if g.phase ~= "MAIN" or player_index ~= g.activePlayer then return false end
  local p = g.players[player_index + 1]
  return destroy_board_entry(p, g, target_board_index)
end

-- Sacrifice a board entry to produce a resource
function actions.sacrifice_unit(g, player_index, card_def, source_key, ability_index, target_board_index)
  local ok, reason = actions.activate_sacrifice_produce(g, player_index, card_def, source_key, ability_index, {
    target_board_index = target_board_index,
  })
  if not ok then return false, reason end
  return true
end

function actions.activate_sacrifice_upgrade_play(g, player_index, card_def, source_key, ability_index, source, hand_index, opts)
  opts = opts or {}
  if g.phase ~= "MAIN" then return false, "wrong_phase" end
  if player_index ~= g.activePlayer then return false, "not_active_player" end
  local p = g.players[player_index + 1]
  if not p then return false, "invalid_player" end

  local ability
  if ability_index and card_def and card_def.abilities then
    ability = card_def.abilities[ability_index]
  end
  if not ability or ability.type ~= "activated" or ability.effect ~= "sacrifice_upgrade" then
    return false, "not_sacrifice_upgrade_ability"
  end

  if ability.once_per_turn and is_activated_once_used(g, player_index, source_key, source, ability_index) then
    return false, "ability_already_used"
  end

  if type(hand_index) ~= "number" or hand_index < 1 or hand_index > #p.hand then
    return false, "invalid_hand_index"
  end

  local snapshot = {
    totalWorkers = p.totalWorkers,
    workersOn = { food = p.workersOn.food, wood = p.workersOn.wood, stone = p.workersOn.stone },
    resources = {},
    board = {},
    specialWorkers = {},
    activated = is_activated_once_used(g, player_index, source_key, source, ability_index),
  }
  for k, v in pairs(p.resources or {}) do snapshot.resources[k] = v end
  for i, e in ipairs(p.board or {}) do snapshot.board[i] = copy_table(e) end
  for i, sw in ipairs(p.specialWorkers or {}) do snapshot.specialWorkers[i] = copy_table(sw) end
  snapshot.workerStatePool = copy_table(p.workerStatePool or {})

  local ok_apply, apply_reason, payment_info = actions.pay_activated_selection_cost(g, player_index, ability, {
    target_board_index = opts.target_board_index,
    target_worker = opts.target_worker,
    target_worker_extra = opts.target_worker_extra,
  })

  if ok_apply then
    if hand_index < 1 or hand_index > #p.hand then ok_apply = false end
  end
  local resolve_result = nil
  local played_card_id = nil
  if ok_apply then
    set_activated_once_used(g, player_index, source_key, source, ability_index, true)
    played_card_id = p.hand[hand_index]
    table.remove(p.hand, hand_index)
    append_board_entry(g, p, {
      card_id = played_card_id,
      state = { rested = false, summoned_turn = g.turnNumber },
    })
    resolve_result = actions.resolve_on_play_triggers(g, player_index, played_card_id)
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
    set_activated_once_used(g, player_index, source_key, source, ability_index, snapshot.activated)
    return false, apply_reason or "upgrade_failed"
  end

  return true, nil, {
    card_id = played_card_id,
    resolve_result = resolve_result,
    payment = payment_info,
  }
end

-- Convenience: activate the base ability for a player
function actions.activate_base_ability(g, player_index)
  local p = g.players[player_index + 1]
  local base_def = cards.get_card_def(p.baseId)
  return actions.activate_ability(g, player_index, base_def, "base")
end

-- Count unassigned regular workers for a player
function actions.count_unassigned_workers(p)
  local assigned = p.workersOn.food + p.workersOn.wood + p.workersOn.stone
    + actions.count_structure_workers(p)
    + actions.count_field_worker_cards(p)
  return p.totalWorkers - assigned
end

-- Count special workers assigned to a given structure board_index
function actions.count_special_on_structure(p, board_index)
  local count = 0
  for _, sw in ipairs(p.specialWorkers) do
    if sw.assigned_to == board_index then
      count = count + 1
    end
  end
  return count
end

-- Count special workers assigned to a resource node (string key)
function actions.count_special_on_resource(p, resource)
  local count = 0
  for _, sw in ipairs(p.specialWorkers) do
    if sw.assigned_to == resource then
      count = count + 1
    end
  end
  return count
end

function actions.sacrifice_worker_token(g, player_index, worker_kind, worker_extra)
  if g.phase ~= "MAIN" or player_index ~= g.activePlayer then return false end
  local p = g.players[player_index + 1]
  if not consume_worker_target(p, worker_kind, worker_extra) then return false end
  local worker_def = get_faction_worker_def(p.faction)
  if worker_def then
    fire_on_ally_death_triggers(p, g, worker_def)
  end
  return true
end

function actions.pay_activated_selection_cost(g, player_index, ability, opts)
  opts = opts or {}
  local valid, reason, info = abilities.validate_activated_selection_cost(g, player_index, ability, opts)
  if not valid then return false, reason, nil, info end
  if type(info) ~= "table" or info.requires_selection == false then
    return true, nil, { requires_selection = false }, info
  end

  local p = g and g.players and g.players[player_index + 1]
  if type(p) ~= "table" then return false, "invalid_player", nil, info end

  local payment_info = {
    kind = info.kind,
    target_board_index = opts.target_board_index,
    target_worker = opts.target_worker,
    target_worker_extra = opts.target_worker_extra,
  }

  if type(opts.target_board_index) == "number" then
    local entry = p.board and p.board[opts.target_board_index] or nil
    if type(entry) ~= "table" then return false, "invalid_sacrifice_target", nil, info end
    payment_info.sacrificed_card_id = entry.card_id
    local ok_def, card_def = pcall(cards.get_card_def, entry.card_id)
    if ok_def and card_def then
      payment_info.sacrificed_tier = card_def.tier or 0
      payment_info.sacrificed_kind = card_def.kind
    end
    local destroyed = actions.destroy_board_entry_any(g, player_index, opts.target_board_index)
    if not destroyed then return false, "sacrifice_failed", nil, info end
    return true, nil, payment_info, info
  end

  if type(opts.target_worker) == "string" and opts.target_worker ~= "" then
    local sacrificed = actions.sacrifice_worker_token(g, player_index, opts.target_worker, opts.target_worker_extra)
    if not sacrificed then
      return false, "invalid_sacrifice_worker_target", nil, info
    end
    payment_info.sacrificed_tier = 0
    payment_info.sacrificed_kind = "Worker"
    return true, nil, payment_info, info
  end

  return false, "missing_sacrifice_target", nil, info
end

local function snapshot_worker_sacrifice_payment_state(p)
  local snapshot = {
    totalWorkers = p.totalWorkers,
    workersOn = {
      food = p.workersOn.food,
      wood = p.workersOn.wood,
      stone = p.workersOn.stone,
    },
    resources = {},
    board_workers = {},
  }
  for k, v in pairs(p.resources or {}) do
    snapshot.resources[k] = v
  end
  for bi, entry in ipairs(p.board or {}) do
    snapshot.board_workers[bi] = entry.workers or 0
  end
  return snapshot
end

local function restore_worker_sacrifice_payment_state(p, snapshot)
  if type(p) ~= "table" or type(snapshot) ~= "table" then return end
  p.totalWorkers = snapshot.totalWorkers
  p.workersOn.food = snapshot.workersOn.food
  p.workersOn.wood = snapshot.workersOn.wood
  p.workersOn.stone = snapshot.workersOn.stone
  for k, v in pairs(snapshot.resources or {}) do
    p.resources[k] = v
  end
  for bi, workers in pairs(snapshot.board_workers or {}) do
    if p.board[bi] then p.board[bi].workers = workers end
  end
end

function actions.pay_card_play_cost(g, player_index, card_def, opts)
  opts = copy_table(opts or {})

  local info, info_err = abilities.collect_card_play_cost_targets(g, player_index, card_def)
  if not info then return false, info_err end

  if info.play_cost and info.play_cost.kind == "monument_counter" then
    return abilities.pay_card_play_cost(g, player_index, card_def, opts)
  end

  if not info.play_cost or info.play_cost.kind ~= "worker_sacrifice" then
    return false, "unsupported_play_cost"
  end

  local p = g and g.players and g.players[player_index + 1]
  if not p then return false, "invalid_player" end

  if opts.sacrifice_targets == nil and opts.available_unassigned_workers == nil then
    opts.available_unassigned_workers = actions.count_unassigned_workers(p)
  end

  local valid_sac_cost, reason = abilities.validate_card_play_cost_selection(g, player_index, card_def, opts)
  if not valid_sac_cost then return false, reason end

  local sacrifice_targets = opts.sacrifice_targets
  local sacrifice_count = tonumber(info.required_count) or 0
  if sacrifice_targets then
    local snapshot = snapshot_worker_sacrifice_payment_state(p)
    for _, t in ipairs(sacrifice_targets) do
      if type(t) ~= "table" or not actions.sacrifice_worker_token(g, player_index, t.kind, t.extra) then
        restore_worker_sacrifice_payment_state(p, snapshot)
        return false, "sacrifice_payment_failed"
      end
    end
    return true, nil, info
  end

  p.totalWorkers = p.totalWorkers - sacrifice_count
  local worker_def = get_faction_worker_def(p.faction)
  if worker_def then
    for _ = 1, sacrifice_count do
      fire_on_ally_death_triggers(p, g, worker_def)
    end
  end
  return true, nil, info
end

-- Play a card from hand that has play_cost_sacrifice ability
function actions.play_from_hand(g, player_index, hand_index, sacrifice_targets)
  if g.phase ~= "MAIN" or player_index ~= g.activePlayer then return false end
  local p = g.players[player_index + 1]
  if hand_index < 1 or hand_index > #p.hand then return false end

  local card_id = p.hand[hand_index]
  local card_def = cards.get_card_def(card_id)
  local sac_ab = get_sacrifice_ability(card_def)
  if not sac_ab then return false end
  local play_cost_info = abilities.collect_card_play_cost_targets(g, player_index, card_def)
  if not play_cost_info or play_cost_info.effect ~= "play_cost_sacrifice" then return false end
  local paid_cost = actions.pay_card_play_cost(g, player_index, card_def, {
    sacrifice_targets = sacrifice_targets,
  })
  if not paid_cost then return false end

  -- Remove card from hand
  table.remove(p.hand, hand_index)

  -- Add as special worker
  p.specialWorkers[#p.specialWorkers + 1] = { card_id = card_id, assigned_to = nil, state = {} }

  return true
end

-- Assign a special worker to a target
-- target: "food"/"wood"/"stone" for resource nodes, or { type="structure", board_index=N }
function actions.assign_special_worker(g, player_index, sw_index, target)
  if g.phase ~= "MAIN" or player_index ~= g.activePlayer then return false end
  local p = g.players[player_index + 1]
  local sw = p.specialWorkers[sw_index]
  if not sw or sw.assigned_to ~= nil then return false end

  if type(target) == "string" then
    -- Resource node assignment
    if target ~= "food" and target ~= "wood" and target ~= "stone" then return false end
    sw.assigned_to = target
    return true
  elseif type(target) == "table" and target.type == "structure" then
    local bi = target.board_index
    local entry = p.board[bi]
    if not entry then return false end
    local card_def = cards.get_card_def(entry.card_id)
    local max_w = 0
    if card_def and card_def.abilities then
      for _, ab in ipairs(card_def.abilities) do
        if ab.type == "static" and ab.effect == "produce" and ab.effect_args and ab.effect_args.per_worker then
          max_w = ab.effect_args.max_workers or 99
        end
      end
    end
    if max_w <= 0 then return false end
    -- Try requested entry first; if full, find another copy of the same card
    local target_bi = bi
    local current = (entry.workers or 0) + actions.count_special_on_structure(p, bi)
    if current >= max_w then
      local found = false
      for si, other in ipairs(p.board) do
        if other.card_id == entry.card_id and si ~= bi then
          local oc = (other.workers or 0) + actions.count_special_on_structure(p, si)
          if oc < max_w then
            target_bi = si
            found = true
            break
          end
        end
      end
      if not found then return false end
    end
    sw.assigned_to = target_bi
    return true
  elseif type(target) == "table" and target.type == "field" then
    local sw_def = nil
    local ok_sw, maybe_sw = pcall(cards.get_card_def, sw.card_id)
    if ok_sw then
      sw_def = maybe_sw
    end
    local field_state = entering_board_state(g, sw_def, sw.state or {})
    append_board_entry(g, p, { card_id = sw.card_id, special_worker_index = sw_index, state = field_state })
    sw.assigned_to = { type = "field", board_index = #p.board }
    return true
  end
  return false
end

-- Find board indices of monuments on player's board with at least min_counters wonder counters
function actions.find_valid_monuments(p, min_counters)
  local result = {}
  for i, entry in ipairs(p.board) do
    local ok, card_def = pcall(cards.get_card_def, entry.card_id)
    if ok and card_def and has_keyword(card_def, "monument") then
      local count = unit_stats.counter_count(entry.state or {}, "wonder")
      if count >= min_counters then
        result[#result + 1] = i
      end
    end
  end
  return result
end

-- Play a card from hand via the monument mechanic.
-- Removes 1 wonder counter from the monument at monument_board_index, then places card on board.
function actions.play_monument_card(g, player_index, hand_index, monument_board_index)
  if g.phase ~= "MAIN" or player_index ~= g.activePlayer then return false end
  local p = g.players[player_index + 1]
  if hand_index < 1 or hand_index > #p.hand then return false end

  local card_id = p.hand[hand_index]
  local ok, card_def = pcall(cards.get_card_def, card_id)
  if not ok or not card_def then return false end

  local mon_ab = get_monument_cost_ability(card_def)
  if not mon_ab then return false end
  local paid_cost, _ = actions.pay_card_play_cost(g, player_index, card_def, {
    monument_board_index = monument_board_index,
  })
  if not paid_cost then return false end

  -- Remove from hand and place on board
  table.remove(p.hand, hand_index)
  append_board_entry(g, p, {
    card_id = card_id,
    state = entering_board_state(g, card_def, {}),
  })
  local trigger_result = fire_on_play_triggers(p, g, card_id)

  return true, nil, trigger_result
end

-- Unassign a special worker (set assigned_to = nil)
function actions.unassign_special_worker(g, player_index, sw_index)
  if g.phase ~= "MAIN" or player_index ~= g.activePlayer then return false end
  local p = g.players[player_index + 1]
  local sw = p.specialWorkers[sw_index]
  if not sw or sw.assigned_to == nil then return false end
  if type(sw.assigned_to) == "table" and sw.assigned_to.type == "field" then
    local bi = sw.assigned_to.board_index
    if bi and p.board[bi] then
      local field_entry = p.board[bi]
      if field_entry then
        sw.state = copy_table(field_entry.state or sw.state or {})
      end
      table.remove(p.board, bi)
      for _, other in ipairs(p.specialWorkers) do
        if type(other.assigned_to) == "number" and other.assigned_to > bi then
          other.assigned_to = other.assigned_to - 1
        elseif type(other.assigned_to) == "table" and other.assigned_to.type == "field" and other.assigned_to.board_index and other.assigned_to.board_index > bi then
          other.assigned_to.board_index = other.assigned_to.board_index - 1
        end
      end
    end
  end
  sw.assigned_to = nil
  return true
end

-- Apply ability damage to a unit. Kills it if lethal. Works on any player's board.
function actions.apply_damage_to_unit(g, target_player_index, board_index, damage_amount)
  local p = g.players[target_player_index + 1]
  if not p then return false end
  local entry = p.board[board_index]
  if not entry then return false end
  local ok, card_def = pcall(cards.get_card_def, entry.card_id)
  if not ok or not card_def then return false end

  entry.state = entry.state or {}
  entry.state.damage = (entry.state.damage or 0) + damage_amount

  if card_def.health ~= nil then
    local effective_hp = unit_stats.effective_health(card_def, entry.state, g, target_player_index)
    if effective_hp - (entry.state.damage or 0) <= 0 then
      destroy_board_entry(p, g, board_index)
      shift_pending_combat_indices_after_destroy(g, target_player_index, board_index)
    end
  end
  return true
end

local function shift_pending_combat_indices_after_destroy(g, target_player_index, removed_index)
  local c = g and g.pendingCombat
  if not c or type(removed_index) ~= "number" then return end
  local affects_atk = (c.attacker == target_player_index)
  local affects_def = (c.defender == target_player_index)
  if not affects_atk and not affects_def then return end

  for _, attacker in ipairs(c.attackers or {}) do
    if affects_atk and type(attacker.board_index) == "number" then
      if attacker.board_index == removed_index then
        attacker.invalidated = true
        attacker.board_index = -1
      elseif attacker.board_index > removed_index then
        attacker.board_index = attacker.board_index - 1
      end
    end
    if affects_def and attacker.target and attacker.target.type == "board" and type(attacker.target.index) == "number" then
      if attacker.target.index == removed_index then
        attacker.target.index = -1
      elseif attacker.target.index > removed_index then
        attacker.target.index = attacker.target.index - 1
      end
    end
  end

  for _, trig in ipairs(c.attack_triggers or {}) do
    if affects_atk and type(trig.attacker_board_index) == "number" then
      if trig.attacker_board_index == removed_index then
        trig.attacker_board_index = -1
        trig.resolved = true
        trig.activate = false
        trig.target_board_index = nil
      elseif trig.attacker_board_index > removed_index then
        trig.attacker_board_index = trig.attacker_board_index - 1
      end
    end
    if affects_def and type(trig.target_board_index) == "number" and trig.target_board_index > 0 then
      if trig.target_board_index == removed_index then
        trig.target_board_index = -1
      elseif trig.target_board_index > removed_index then
        trig.target_board_index = trig.target_board_index - 1
      end
    end
  end

  for i = #(c.blockers or {}), 1, -1 do
    local blk = c.blockers[i]
    local remove_blk = false
    if affects_def and type(blk.blocker_board_index) == "number" then
      if blk.blocker_board_index == removed_index then
        remove_blk = true
      elseif blk.blocker_board_index > removed_index then
        blk.blocker_board_index = blk.blocker_board_index - 1
      end
    end
    if affects_atk and type(blk.attacker_board_index) == "number" then
      if blk.attacker_board_index == removed_index then
        remove_blk = true
      elseif blk.attacker_board_index > removed_index then
        blk.attacker_board_index = blk.attacker_board_index - 1
      end
    end
    if remove_blk then table.remove(c.blockers, i) end
  end
end

function actions.destroy_board_entry_any(g, target_player_index, board_index)
  local p = g.players[target_player_index + 1]
  if not p or type(board_index) ~= "number" then return false end
  local destroyed = destroy_board_entry(p, g, board_index)
  if destroyed then
    shift_pending_combat_indices_after_destroy(g, target_player_index, board_index)
  end
  return destroyed
end

return actions
