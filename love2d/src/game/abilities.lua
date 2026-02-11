-- Ability helpers: cost checking, effect resolution.
-- Abilities are now structured data defined in data/cards.lua.
-- This module provides the dispatch table for resolving effects.

local abilities = {}

-- Return whether player can pay the ability cost.
function abilities.can_pay_cost(player_resources, cost_list)
  if not cost_list or #cost_list == 0 then return true end
  for _, c in ipairs(cost_list) do
    local have = player_resources[c.type] or 0
    if have < c.amount then return false end
  end
  return true
end

---------------------------------------------------------
-- Effect dispatch table
-- Each handler: function(ability, player, game_state)
-- Add new effects by adding entries to this table.
---------------------------------------------------------
local effect_handlers = {}

effect_handlers.summon_worker = function(ability, player, g)
  local amount = (ability.effect_args and ability.effect_args.amount) or 1
  player.totalWorkers = math.min(player.totalWorkers + amount, player.maxWorkers or 99)
end

effect_handlers.draw_cards = function(ability, player, g)
  -- TODO: implement when hand/draw system exists
end

effect_handlers.discard_random = function(ability, player, g)
  -- TODO: implement when hand system exists
end

effect_handlers.play_unit = function(ability, player, g)
  -- TODO: implement when unit playing exists
end

effect_handlers.research = function(ability, player, g)
  -- TODO: implement when tech tree exists
end

effect_handlers.convert_resource = function(ability, player, g)
  local args = ability.effect_args or {}
  local output = args.output
  local amount = args.amount or 1
  if output and player.resources[output] ~= nil then
    player.resources[output] = player.resources[output] + amount
  end
end

effect_handlers.produce_multiple = function(ability, player, g)
  local args = ability.effect_args or {}
  for _, entry in ipairs(args) do
    local res = entry.resource
    local amount = entry.amount or 0
    if res and player.resources[res] ~= nil then
      player.resources[res] = player.resources[res] + amount
    end
  end
end

effect_handlers.produce = function(ability, player, g)
  -- Static production abilities are handled by the turn system, not activated
end

effect_handlers.skip_draw = function(ability, player, g)
  -- Handled as a flag check during draw phase
end

-- Resolve an ability's effect using the dispatch table.
function abilities.resolve(ability, player, game_state)
  local handler = effect_handlers[ability.effect]
  if handler then
    handler(ability, player, game_state)
  end
end

return abilities
