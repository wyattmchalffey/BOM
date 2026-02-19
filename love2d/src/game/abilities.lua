-- Ability helpers: cost checking, effect resolution.
-- Abilities are now structured data defined in data/cards.lua.
-- This module provides the dispatch table for resolving effects.

local cards = require("src.game.cards")

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
  local args = ability.effect_args or {}
  local amount = args.amount or 1
  for _ = 1, amount do
    if not player.deck or #player.deck == 0 then break end
    local card_id = table.remove(player.deck)
    player.hand[#player.hand + 1] = card_id
  end
end

effect_handlers.discard_random = function(ability, player, g)
  local args = ability.effect_args or {}
  local amount = args.amount or 1
  for _ = 1, amount do
    if #player.hand == 0 then break end
    local idx = math.random(1, #player.hand)
    table.remove(player.hand, idx)
  end
end

effect_handlers.play_unit = function(ability, player, g)
  local args = ability.effect_args or {}
  -- If a specific hand index was provided (two-step selection flow), use it directly
  local hand_index = args._hand_index
  if hand_index then
    local card_id = player.hand[hand_index]
    if card_id then
      table.remove(player.hand, hand_index)
      player.board[#player.board + 1] = { card_id = card_id }
    end
    return
  end
  -- Fallback: auto-pick first matching Unit card from hand
  for i, card_id in ipairs(player.hand) do
    local ok, card_def = pcall(cards.get_card_def, card_id)
    if ok and card_def and card_def.kind == "Unit" then
      local match = true
      if args.faction and card_def.faction ~= args.faction then match = false end
      if args.tier and (card_def.tier or 0) ~= args.tier then match = false end
      if args.subtypes and card_def.subtypes then
        local has_subtype = false
        for _, req_sub in ipairs(args.subtypes) do
          for _, card_sub in ipairs(card_def.subtypes) do
            if req_sub == card_sub then has_subtype = true; break end
          end
          if has_subtype then break end
        end
        if not has_subtype then match = false end
      elseif args.subtypes then
        match = false
      end
      if match then
        table.remove(player.hand, i)
        player.board[#player.board + 1] = { card_id = card_id }
        return
      end
    end
  end
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
  -- Static production abilities are handled by the turn system.
  -- Triggered/activated produce should resolve immediately.
  if ability.type == "static" then return end
  local args = ability.effect_args or {}
  local res = args.resource
  local amount = args.amount or 0
  if res and amount > 0 and player.resources[res] ~= nil then
    player.resources[res] = player.resources[res] + amount
  end
end

effect_handlers.skip_draw = function(ability, player, g)
  -- Handled as a flag check during draw phase
end

-- Return indices of hand cards matching a play_unit ability's criteria.
function abilities.find_matching_hand_indices(player, effect_args)
  local args = effect_args or {}
  local indices = {}
  for i, card_id in ipairs(player.hand) do
    local ok, card_def = pcall(cards.get_card_def, card_id)
    if ok and card_def and card_def.kind == "Unit" then
      local match = true
      if args.faction and card_def.faction ~= args.faction then match = false end
      if args.tier and (card_def.tier or 0) ~= args.tier then match = false end
      if args.subtypes and card_def.subtypes then
        local has_subtype = false
        for _, req in ipairs(args.subtypes) do
          for _, got in ipairs(card_def.subtypes) do
            if req == got then has_subtype = true; break end
          end
          if has_subtype then break end
        end
        if not has_subtype then match = false end
      elseif args.subtypes then
        match = false
      end
      if match then indices[#indices + 1] = i end
    end
  end
  return indices
end

-- Return board indices of non-Structure entries eligible for sacrifice (non-Undead units/workers).
function abilities.find_sacrifice_targets(player, effect_args)
  local args = effect_args or {}
  local indices = {}
  for si, entry in ipairs(player.board) do
    local ok, card_def = pcall(cards.get_card_def, entry.card_id)
    if ok and card_def and card_def.kind ~= "Structure" then
      local excluded = false
      if args.condition == "non_undead" then
        if card_def.subtypes then
          for _, st in ipairs(card_def.subtypes) do
            if st == "Undead" then excluded = true; break end
          end
        end
      end
      if not excluded then
        indices[#indices + 1] = si
      end
    end
  end
  return indices
end

-- Resolve an ability's effect using the dispatch table.
function abilities.resolve(ability, player, game_state)
  local handler = effect_handlers[ability.effect]
  if handler then
    handler(ability, player, game_state)
  end
end

return abilities
