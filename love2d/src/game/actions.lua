-- Game actions: start turn, end turn, assign/unassign workers, activate abilities, draw cards.
-- Uses data/config.lua for production rates and other constants.

local config = require("src.data.config")
local cards = require("src.game.cards")
local abilities = require("src.game.abilities")
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

local function is_undead(card_def)
  if not card_def or not card_def.subtypes then return false end
  for _, st in ipairs(card_def.subtypes) do
    if st == "Undead" then return true end
  end
  return false
end

local function fire_on_ally_death_triggers(player, game_state, dead_card_def)
  for _, entry in ipairs(player.board) do
    local ok, card_def = pcall(cards.get_card_def, entry.card_id)
    if ok and card_def and card_def.abilities then
      for _, ab in ipairs(card_def.abilities) do
        if ab.type == "triggered" and ab.trigger == "on_ally_death" then
          local args = ab.effect_args or {}
          local blocked = false
          if args.condition == "non_undead" and is_undead(dead_card_def) then
            blocked = true
          elseif args.condition == "non_undead_orc" then
            if is_undead(dead_card_def) or (dead_card_def and dead_card_def.faction ~= "Orc") then
              blocked = true
            end
          end
          if not blocked then
            abilities.resolve(ab, player, game_state, { source_entry = entry })
          end
        end
      end
    end
  end
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
  local ok, def = pcall(cards.get_card_def, played_card_id)
  if ok and def and def.abilities then
    for _, ab in ipairs(def.abilities) do
      if ab.type == "triggered" and (ab.trigger == "on_play" or ab.trigger == "on_construct") then
        abilities.resolve(ab, player, game_state)
      end
    end
  end
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
  if t_ok and t_def and t_def.abilities then
    for _, ab in ipairs(t_def.abilities) do
      if ab.type == "triggered" and ab.trigger == "on_destroyed" then
        abilities.resolve(ab, player, game_state)
      end
    end
  end
  if t_ok and t_def then
    fire_on_ally_death_triggers(player, game_state, t_def)
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
  if not card_def or not card_def.abilities then return nil end
  for _, ab in ipairs(card_def.abilities) do
    if ab.type == "static" and ab.effect == "monument_cost" then return ab end
  end
  return nil
end

-- Get the play_cost_sacrifice ability from a card def (returns ability or nil)
local function get_sacrifice_ability(card_def)
  if not card_def or not card_def.abilities then return nil end
  for _, ab in ipairs(card_def.abilities) do
    if ab.type == "static" and ab.effect == "play_cost_sacrifice" then return ab end
  end
  return nil
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

  local key = tostring(player_index) .. ":" .. source_key
  if ability.once_per_turn and g.activatedUsedThisTurn[key] then return false, "ability_already_used" end
  if not abilities.can_pay_cost(p.resources, ability.cost) then return false, "insufficient_resources" end

  -- Check rest cost
  if ability.rest and source_entry and source_entry.state and source_entry.state.rested then
    return false, "unit_is_rested"
  end

  -- Pay resource costs
  for _, c in ipairs(ability.cost or {}) do
    p.resources[c.type] = (p.resources[c.type] or 0) - c.amount
  end
  g.activatedUsedThisTurn[key] = true

  -- Pay rest cost
  if ability.rest and source_entry then
    source_entry.state = source_entry.state or {}
    source_entry.state.rested = true
  end

  -- Resolve effect
  abilities.resolve(ability, p, g, {
    source = source,
    source_entry = source_entry,
    source_key = source_key,
    ability_index = ability_index,
    player_index = player_index,
  })

  return true
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

  local key = tostring(player_index) .. ":" .. source_key
  if ability.once_per_turn and g.activatedUsedThisTurn[key] then return false, "ability_already_used" end
  if not abilities.can_pay_cost(p.resources, ability.cost) then return false, "insufficient_resources" end

  -- Validate hand_index
  if not hand_index or hand_index < 1 or hand_index > #p.hand then return false, "invalid_hand_index" end
  local matching = abilities.find_matching_hand_indices(p, ability.effect_args)
  local is_eligible = false
  for _, idx in ipairs(matching) do
    if idx == hand_index then is_eligible = true; break end
  end
  if not is_eligible then return false, "hand_card_not_eligible" end

  -- Pay cost
  for _, c in ipairs(ability.cost or {}) do
    p.resources[c.type] = (p.resources[c.type] or 0) - c.amount
  end
  g.activatedUsedThisTurn[key] = true

  -- Remove card from hand and place on board
  local card_id = p.hand[hand_index]
  table.remove(p.hand, hand_index)
  local played_def = nil
  local ok_played, maybe_played = pcall(cards.get_card_def, card_id)
  if ok_played then
    played_def = maybe_played
  end
  p.board[#p.board + 1] = {
    card_id = card_id,
    state = entering_board_state(g, played_def, {}),
  }

  -- Fire on_play triggered abilities
  fire_on_play_triggers(p, g, card_id)

  return true
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
  p.board[#p.board + 1] = { card_id = worker_def.id, state = final_state }
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
  fire_on_play_triggers(p, g, card_id)
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
  for _, c in ipairs(card_def.costs) do
    p.resources[c.type] = (p.resources[c.type] or 0) - c.amount
  end

  -- Consume one copy from blueprint deck.
  table.remove(p.blueprintDeck, blueprint_index)

  -- Place on board
  p.board[#p.board + 1] = { card_id = card_id, workers = 0, state = { rested = false } }

  -- Fire on_play triggered abilities
  if card_def.abilities then
    for _, ab in ipairs(card_def.abilities) do
      if ab.type == "triggered" and (ab.trigger == "on_play" or ab.trigger == "on_construct") then
        abilities.resolve(ab, p, g)
      end
    end
  end

  return true
end

-- Sacrifice a worker token to produce a resource.
-- worker_kind: "worker_unassigned", "worker_left", "worker_right", "structure_worker", "unassigned_pool"
-- worker_extra: board_index for structure_worker, nil otherwise
function actions.sacrifice_worker(g, player_index, card_def, source_key, ability_index, worker_kind, worker_extra)
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

  local key = tostring(player_index) .. ":" .. source_key
  if ability.once_per_turn and g.activatedUsedThisTurn[key] then return false, "ability_already_used" end

  if not consume_worker_target(p, worker_kind, worker_extra) then
    return false, "invalid_sacrifice_worker_target"
  end

  local worker_def = get_faction_worker_def(p.faction)
  if worker_def then
    fire_on_ally_death_triggers(p, g, worker_def)
  end

  local args = ability.effect_args or {}
  local res = args.resource
  local amount = args.amount or 1
  if res then
    p.resources[res] = (p.resources[res] or 0) + amount
  end

  g.activatedUsedThisTurn[key] = true
  return true
end

function actions.sacrifice_board_entry(g, player_index, target_board_index)
  if g.phase ~= "MAIN" or player_index ~= g.activePlayer then return false end
  local p = g.players[player_index + 1]
  return destroy_board_entry(p, g, target_board_index)
end

-- Sacrifice a board entry to produce a resource
function actions.sacrifice_unit(g, player_index, card_def, source_key, ability_index, target_board_index)
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

  local key = tostring(player_index) .. ":" .. source_key
  if ability.once_per_turn and g.activatedUsedThisTurn[key] then return false, "ability_already_used" end

  local removed = actions.sacrifice_board_entry(g, player_index, target_board_index)
  if not removed then return false, "invalid_sacrifice_target" end

  -- Produce the resource
  local args = ability.effect_args or {}
  local res = args.resource
  local amount = args.amount or 1
  if res then
    p.resources[res] = (p.resources[res] or 0) + amount
  end

  g.activatedUsedThisTurn[key] = true
  return true
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

-- Play a card from hand that has play_cost_sacrifice ability
function actions.play_from_hand(g, player_index, hand_index, sacrifice_targets)
  if g.phase ~= "MAIN" or player_index ~= g.activePlayer then return false end
  local p = g.players[player_index + 1]
  if hand_index < 1 or hand_index > #p.hand then return false end

  local card_id = p.hand[hand_index]
  local card_def = cards.get_card_def(card_id)
  local sac_ab = get_sacrifice_ability(card_def)
  if not sac_ab then return false end

  local sacrifice_count = sac_ab.effect_args and sac_ab.effect_args.sacrifice_count or 2

  if sacrifice_targets then
    if #sacrifice_targets ~= sacrifice_count then return false end

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
    for k, v in pairs(p.resources) do
      snapshot.resources[k] = v
    end
    for bi, entry in ipairs(p.board) do
      snapshot.board_workers[bi] = entry.workers or 0
    end

    for _, t in ipairs(sacrifice_targets) do
      if type(t) ~= "table" or not actions.sacrifice_worker_token(g, player_index, t.kind, t.extra) then
        p.totalWorkers = snapshot.totalWorkers
        p.workersOn.food = snapshot.workersOn.food
        p.workersOn.wood = snapshot.workersOn.wood
        p.workersOn.stone = snapshot.workersOn.stone
        for k, v in pairs(snapshot.resources) do
          p.resources[k] = v
        end
        for bi, workers in pairs(snapshot.board_workers) do
          if p.board[bi] then p.board[bi].workers = workers end
        end
        return false
      end
    end
  else
    if actions.count_unassigned_workers(p) < sacrifice_count then return false end
    p.totalWorkers = p.totalWorkers - sacrifice_count
    local worker_def = get_faction_worker_def(p.faction)
    if worker_def then
      for _ = 1, sacrifice_count do
        fire_on_ally_death_triggers(p, g, worker_def)
      end
    end
  end

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
    p.board[#p.board + 1] = { card_id = sw.card_id, special_worker_index = sw_index, state = field_state }
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
  local min_counters = mon_ab.effect_args and mon_ab.effect_args.min_counters or 1

  local monument_entry = p.board[monument_board_index]
  if not monument_entry then return false end
  local ok_mon, mon_def = pcall(cards.get_card_def, monument_entry.card_id)
  if not ok_mon or not mon_def then return false end
  if not has_keyword(mon_def, "monument") then return false end

  monument_entry.state = monument_entry.state or {}
  if unit_stats.counter_count(monument_entry.state, "wonder") < min_counters then return false end

  -- Remove 1 wonder counter from the monument
  unit_stats.remove_counter(monument_entry.state, "wonder", 1)

  -- Remove from hand and place on board
  table.remove(p.hand, hand_index)
  p.board[#p.board + 1] = {
    card_id = card_id,
    state = entering_board_state(g, card_def, {}),
  }
  fire_on_play_triggers(p, g, card_id)

  return true
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
    local effective_hp = unit_stats.effective_health(card_def, entry.state)
    if effective_hp - (entry.state.damage or 0) <= 0 then
      destroy_board_entry(p, g, board_index)
    end
  end
  return true
end

return actions
