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
  g.phase = "TURN_START"
  g.priorityPlayer = g.activePlayer
  return g
end

function actions.assign_worker_to_resource(g, player_index, resource)
  if player_index ~= g.activePlayer then return g end
  local p = g.players[player_index + 1]
  local assigned = p.workersOn.food + p.workersOn.wood + p.workersOn.stone
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
  p.board[#p.board + 1] = { card_id = card_id }

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

return actions
