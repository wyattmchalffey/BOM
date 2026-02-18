-- Game actions: start turn, end turn, assign/unassign workers, activate abilities, draw cards.
-- Uses data/config.lua for production rates and other constants.

local config = require("src.data.config")
local cards = require("src.game.cards")
local abilities = require("src.game.abilities")
local game_state = require("src.game.state")

local actions = {}

-- Check if a card def has a specific static effect
local function has_static_effect(card_def, effect_name)
  if not card_def or not card_def.abilities then return false end
  for _, ab in ipairs(card_def.abilities) do
    if ab.type == "static" and ab.effect == effect_name then return true end
  end
  return false
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
  -- Produce resources from special workers (2x rate)
  for _, sw in ipairs(p.specialWorkers) do
    if sw.assigned_to ~= nil then
      if type(sw.assigned_to) == "string" then
        -- On a resource node: 2x production_per_worker
        local res = sw.assigned_to
        if p.resources[res] ~= nil then
          p.resources[res] = p.resources[res] + config.production_per_worker * 2
        end
      elseif type(sw.assigned_to) == "number" then
        -- On a structure: find per_worker rate, apply 2x
        local entry = p.board[sw.assigned_to]
        if entry then
          local ok_sw, sw_def = pcall(cards.get_card_def, entry.card_id)
          if ok_sw and sw_def and sw_def.abilities then
            for _, ab in ipairs(sw_def.abilities) do
              if ab.type == "static" and ab.effect == "produce" and ab.effect_args and ab.effect_args.per_worker then
                local res = ab.effect_args.resource
                if res and p.resources[res] ~= nil then
                  p.resources[res] = p.resources[res] + ab.effect_args.per_worker * 2
                end
              end
            end
          end
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

function actions.assign_worker_to_resource(g, player_index, resource)
  if player_index ~= g.activePlayer then return g end
  local p = g.players[player_index + 1]
  local assigned = p.workersOn.food + p.workersOn.wood + p.workersOn.stone + actions.count_structure_workers(p)
  local unassigned = p.totalWorkers - assigned
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
  local p = g.players[player_index + 1]
  local entry = p.board[board_index]
  if not entry then return g end
  local ok, card_def = pcall(cards.get_card_def, entry.card_id)
  if not ok or not card_def then return g end
  local max_w = 0
  if card_def.abilities then
    for _, ab in ipairs(card_def.abilities) do
      if ab.type == "static" and ab.effect == "produce" and ab.effect_args and ab.effect_args.per_worker then
        max_w = ab.effect_args.max_workers or 99
      end
    end
  end
  if max_w <= 0 then return g end
  local assigned = p.workersOn.food + p.workersOn.wood + p.workersOn.stone + actions.count_structure_workers(p)
  if p.totalWorkers - assigned <= 0 then return g end
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
    if not found then return g end
  end
  target.workers = target.workers + 1
  return g
end

function actions.unassign_worker_from_structure(g, player_index, board_index)
  local p = g.players[player_index + 1]
  local entry = p.board[board_index]
  if not entry then return g end
  entry.workers = entry.workers or 0
  if entry.workers <= 0 then return g end
  entry.workers = entry.workers - 1
  return g
end

-- Activate an ability on a card (base, structure, etc.)
-- source_key: unique string like "base:1" or "board:3:2" for tracking once-per-turn
-- ability_index: optional index into card_def.abilities (defaults to first activated)
function actions.activate_ability(g, player_index, card_def, source_key, ability_index)
  if g.phase ~= "MAIN" or player_index ~= g.activePlayer then return g end
  local p = g.players[player_index + 1]

  local ability
  if ability_index and card_def.abilities then
    ability = card_def.abilities[ability_index]
  else
    ability = cards.get_activated_ability(card_def)
  end
  if not ability or ability.type ~= "activated" then return g end

  local key = tostring(player_index) .. ":" .. source_key
  if ability.once_per_turn and g.activatedUsedThisTurn[key] then return g end
  if not abilities.can_pay_cost(p.resources, ability.cost) then return g end

  -- Pay cost
  for _, c in ipairs(ability.cost) do
    p.resources[c.type] = (p.resources[c.type] or 0) - c.amount
  end
  g.activatedUsedThisTurn[key] = true

  -- Resolve effect
  abilities.resolve(ability, p, g)

  return g
end

-- Play a specific unit card from hand via a play_unit ability (two-step selection flow).
-- source_key: unique string like "board:3:2" for tracking once-per-turn
function actions.play_unit_from_hand(g, player_index, card_def, source_key, ability_index, hand_index)
  if g.phase ~= "MAIN" or player_index ~= g.activePlayer then return g end
  local p = g.players[player_index + 1]

  local ability
  if ability_index and card_def.abilities then
    ability = card_def.abilities[ability_index]
  end
  if not ability or ability.type ~= "activated" or ability.effect ~= "play_unit" then return g end

  local key = tostring(player_index) .. ":" .. source_key
  if ability.once_per_turn and g.activatedUsedThisTurn[key] then return g end
  if not abilities.can_pay_cost(p.resources, ability.cost) then return g end

  -- Validate hand_index
  if not hand_index or hand_index < 1 or hand_index > #p.hand then return g end
  local matching = abilities.find_matching_hand_indices(p, ability.effect_args)
  local is_eligible = false
  for _, idx in ipairs(matching) do
    if idx == hand_index then is_eligible = true; break end
  end
  if not is_eligible then return g end

  -- Pay cost
  for _, c in ipairs(ability.cost) do
    p.resources[c.type] = (p.resources[c.type] or 0) - c.amount
  end
  g.activatedUsedThisTurn[key] = true

  -- Remove card from hand and place on board
  local card_id = p.hand[hand_index]
  table.remove(p.hand, hand_index)
  p.board[#p.board + 1] = { card_id = card_id }

  -- Fire on_construct triggered abilities
  local ok, unit_def = pcall(cards.get_card_def, card_id)
  if ok and unit_def and unit_def.abilities then
    for _, ab in ipairs(unit_def.abilities) do
      if ab.type == "triggered" and ab.trigger == "on_construct" then
        abilities.resolve(ab, p, g)
      end
    end
  end

  return g
end

-- Build a structure from the blueprint deck
function actions.build_structure(g, player_index, card_id)
  if g.phase ~= "MAIN" or player_index ~= g.activePlayer then return false end
  local p = g.players[player_index + 1]

  -- Validate card exists and is a Structure of the player's faction
  local ok, card_def = pcall(cards.get_card_def, card_id)
  if not ok or not card_def then return false end
  if card_def.kind ~= "Structure" then return false end
  if card_def.faction ~= p.faction then return false end

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

  -- Place on board
  p.board[#p.board + 1] = { card_id = card_id, workers = 0 }

  -- Fire on_construct triggered abilities
  if card_def.abilities then
    for _, ab in ipairs(card_def.abilities) do
      if ab.type == "triggered" and ab.trigger == "on_construct" then
        abilities.resolve(ab, p, g)
      end
    end
  end

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
  local assigned = p.workersOn.food + p.workersOn.wood + p.workersOn.stone + actions.count_structure_workers(p)
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

-- Play a card from hand that has play_cost_sacrifice ability
function actions.play_from_hand(g, player_index, hand_index)
  if g.phase ~= "MAIN" or player_index ~= g.activePlayer then return false end
  local p = g.players[player_index + 1]
  if hand_index < 1 or hand_index > #p.hand then return false end

  local card_id = p.hand[hand_index]
  local card_def = cards.get_card_def(card_id)
  local sac_ab = get_sacrifice_ability(card_def)
  if not sac_ab then return false end

  local sacrifice_count = sac_ab.effect_args and sac_ab.effect_args.sacrifice_count or 2
  if actions.count_unassigned_workers(p) < sacrifice_count then return false end

  -- Sacrifice regular workers
  p.totalWorkers = p.totalWorkers - sacrifice_count

  -- Remove card from hand
  table.remove(p.hand, hand_index)

  -- Add as special worker
  p.specialWorkers[#p.specialWorkers + 1] = { card_id = card_id, assigned_to = nil }

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
    -- Find max_workers from produce ability
    local max_w = 0
    if card_def and card_def.abilities then
      for _, ab in ipairs(card_def.abilities) do
        if ab.type == "static" and ab.effect == "produce" and ab.effect_args and ab.effect_args.per_worker then
          max_w = ab.effect_args.max_workers or 99
        end
      end
    end
    if max_w <= 0 then return false end
    -- Check capacity: regular + special workers
    local current = (entry.workers or 0) + actions.count_special_on_structure(p, bi)
    if current >= max_w then return false end
    sw.assigned_to = bi
    return true
  end
  return false
end

-- Unassign a special worker (set assigned_to = nil)
function actions.unassign_special_worker(g, player_index, sw_index)
  if g.phase ~= "MAIN" or player_index ~= g.activePlayer then return false end
  local p = g.players[player_index + 1]
  local sw = p.specialWorkers[sw_index]
  if not sw or sw.assigned_to == nil then return false end
  sw.assigned_to = nil
  return true
end

return actions
