-- Ability helpers: cost checking, effect resolution.
-- Abilities are now structured data defined in data/cards.lua.
-- This module provides the dispatch table for resolving effects.

local cards = require("src.game.cards")
local unit_stats = require("src.game.unit_stats")

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

effect_handlers.discard_draw = function(ability, player, g)
  -- Handled by the two-step DISCARD_DRAW_HAND command; nothing to do here.
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
  local function summoned_state()
    return {
      rested = false,
      summoned_turn = g and g.turnNumber or nil,
    }
  end
  -- If a specific hand index was provided (two-step selection flow), use it directly
  local hand_index = args._hand_index
  if hand_index then
    local card_id = player.hand[hand_index]
    if card_id then
      table.remove(player.hand, hand_index)
      player.board[#player.board + 1] = { card_id = card_id, state = summoned_state() }
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
        player.board[#player.board + 1] = { card_id = card_id, state = summoned_state() }
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

effect_handlers.buff_ally_attacker = function(ability, player, g, context)
  -- Primary resolution is handled inline by combat.assign_attack_trigger_targets.
  -- This stub exists for completeness.
end

effect_handlers.gain_keyword = function(ability, player, g, context)
  local args = ability.effect_args or {}
  local source_entry = context and context.source_entry
  if type(source_entry) ~= "table" then return end

  local keyword = args.keyword
  if type(keyword) ~= "string" or keyword == "" then return end

  source_entry.state = source_entry.state or {}
  local st = source_entry.state

  if args.duration == "end_of_turn" then
    st.temp_keywords = st.temp_keywords or {}
    st.temp_keywords[string.lower(keyword)] = true
  else
    -- Permanent grant — check card_def keywords
    local ok, card_def = pcall(cards.get_card_def, source_entry.card_id)
    if ok and card_def then
      card_def.keywords = card_def.keywords or {}
      local have = false
      for _, kw in ipairs(card_def.keywords) do
        if string.lower(kw) == string.lower(keyword) then
          have = true
          break
        end
      end
      if not have then
        card_def.keywords[#card_def.keywords + 1] = keyword
      end
    end
  end
end

effect_handlers.buff_self = function(ability, player, g, context)
  local args = ability.effect_args or {}
  local source_entry = context and context.source_entry
  if type(source_entry) ~= "table" then
    return
  end

  source_entry.state = source_entry.state or {}
  local st = source_entry.state

  local attack_delta = tonumber(args.attack or args.amount) or 0
  local health_delta = tonumber(args.health) or 0
  local duration = args.duration or "end_of_turn"

  if duration == "end_of_turn" then
    if attack_delta ~= 0 then
      st.temp_attack_bonus = (st.temp_attack_bonus or 0) + attack_delta
    end
    if health_delta ~= 0 then
      st.temp_health_bonus = (st.temp_health_bonus or 0) + health_delta
    end
  else
    if attack_delta ~= 0 then
      st.attack_bonus = (st.attack_bonus or 0) + attack_delta
    end
    if health_delta ~= 0 then
      st.health_bonus = (st.health_bonus or 0) + health_delta
    end
  end

  -- Activating from a stack should split this unit out for clear board state.
  st.stack_id = nil

  -- Keep values normalized if a buff ends up net-zero.
  if unit_stats.attack_bonus(st) == 0 then
    st.attack_bonus = nil
    st.temp_attack_bonus = nil
  end
  if unit_stats.health_bonus(st) == 0 then
    st.health_bonus = nil
    st.temp_health_bonus = nil
  end
end

-- Targeted damage is resolved in the DEAL_DAMAGE_TO_TARGET command handler.
effect_handlers.deal_damage = function(ability, player, g, context) end

-- Variable damage is resolved in the DEAL_DAMAGE_X_TO_TARGET command handler.
effect_handlers.deal_damage_x = function(ability, player, g, context) end

-- Spell play is resolved via the PLAY_SPELL_VIA_ABILITY command handler.
effect_handlers.play_spell = function(ability, player, g, context) end

effect_handlers.place_counter_on_target = function(ability, player, g, context)
  local args = ability.effect_args or {}
  local counter_name = args.counter
  if type(counter_name) ~= "string" or counter_name == "" then return end
  local target_entry = (context and context.target_entry) or (context and context.source_entry)
  if type(target_entry) ~= "table" then return end
  target_entry.state = target_entry.state or {}
  unit_stats.add_counter(target_entry.state, counter_name, args.amount or 1, false)
end

effect_handlers.search_deck = function(ability, player, g)
  local args = ability.effect_args or {}
  local criteria = args.search_criteria or {}
  local function matches_criterion(card_def, crit)
    if crit.kind and card_def.kind ~= crit.kind then return false end
    if crit.faction and card_def.faction ~= crit.faction then return false end
    if crit.subtypes then
      if not card_def.subtypes then return false end
      local found = false
      for _, req in ipairs(crit.subtypes) do
        for _, got in ipairs(card_def.subtypes) do
          if req == got then found = true; break end
        end
        if found then break end
      end
      if not found then return false end
    end
    return true
  end
  for i, card_id in ipairs(player.deck) do
    local ok, card_def = pcall(cards.get_card_def, card_id)
    if ok and card_def then
      for _, crit in ipairs(criteria) do
        if matches_criterion(card_def, crit) then
          table.remove(player.deck, i)
          player.hand[#player.hand + 1] = card_id
          return
        end
      end
    end
  end
end

effect_handlers.place_counter = function(ability, player, g, context)
  local args = ability.effect_args or {}
  local counter_name = args.counter
  if type(counter_name) ~= "string" or counter_name == "" then return end
  local source_entry = context and context.source_entry
  if type(source_entry) ~= "table" then return end
  source_entry.state = source_entry.state or {}
  unit_stats.add_counter(source_entry.state, counter_name, args.amount or 1, args.duration == "end_of_turn")
end

effect_handlers.remove_counter_draw = function(ability, player, g, context)
  local args = ability.effect_args or {}
  local source_entry = context and context.source_entry
  if type(source_entry) ~= "table" then return end
  source_entry.state = source_entry.state or {}
  if not unit_stats.remove_counter(source_entry.state, args.counter, args.remove or 1) then return end
  for _ = 1, (args.draw or 1) do
    if not player.deck or #player.deck == 0 then break end
    player.hand[#player.hand + 1] = table.remove(player.deck)
  end
end

effect_handlers.remove_counter_play = function(ability, player, g, context)
  local args = ability.effect_args or {}
  local source_entry = context and context.source_entry
  if type(source_entry) ~= "table" then return end
  source_entry.state = source_entry.state or {}
  if not unit_stats.remove_counter(source_entry.state, args.counter, args.remove or 1) then return end
  -- Play a matching unit from hand (reuses play_unit matching logic)
  local play_args = {
    subtypes = args.subtypes,
    tier = args.tier,
    faction = args.faction,
  }
  local indices = abilities.find_matching_hand_indices(player, play_args)
  if #indices > 0 then
    local card_id = player.hand[indices[1]]
    table.remove(player.hand, indices[1])
    player.board[#player.board + 1] = {
      card_id = card_id,
      state = { rested = false, summoned_turn = g and g.turnNumber or nil },
    }
  end
end

effect_handlers.return_from_graveyard = function(ability, player, g)
  local args = ability.effect_args or {}
  local max_count = args.count or 1
  local req_tier = args.tier        -- nil = any tier
  local req_subtypes = args.subtypes -- nil = any subtype

  local function card_matches(card_def)
    if not card_def then return false end
    if req_tier ~= nil and (card_def.tier or 0) ~= req_tier then return false end
    if req_subtypes and #req_subtypes > 0 then
      if not card_def.subtypes then return false end
      local found = false
      for _, req in ipairs(req_subtypes) do
        for _, got in ipairs(card_def.subtypes) do
          if req == got then found = true; break end
        end
        if found then break end
      end
      if not found then return false end
    end
    return true
  end

  local function count_on_board(card_id)
    local n = 0
    for _, entry in ipairs(player.board) do
      if entry.card_id == card_id then n = n + 1 end
    end
    return n
  end

  -- Collect eligible graveyard indices newest-first; track pending adds per card_id
  -- so population limits are respected across multiple picks of the same card.
  local eligible = {}
  local pending_add = {}
  for i = #player.graveyard, 1, -1 do
    if #eligible >= max_count then break end
    local gentry = player.graveyard[i]
    local ok, card_def = pcall(cards.get_card_def, gentry.card_id)
    if ok and card_def and card_matches(card_def) then
      local pending = pending_add[gentry.card_id] or 0
      local pop = card_def.population
      if not pop or (count_on_board(gentry.card_id) + pending) < pop then
        eligible[#eligible + 1] = i
        pending_add[gentry.card_id] = pending + 1
      end
    end
  end

  -- Remove from graveyard in descending index order (so earlier indices stay valid).
  for _, gi in ipairs(eligible) do
    local gentry = player.graveyard[gi]
    table.remove(player.graveyard, gi)
    player.board[#player.board + 1] = {
      card_id = gentry.card_id,
      state = { rested = false, summoned_turn = g and g.turnNumber or nil },
    }
  end
end

-- Return indices of hand Spell cards matching a play_spell ability's criteria.
function abilities.find_matching_spell_hand_indices(player, effect_args)
  local args = effect_args or {}
  local indices = {}
  for i, card_id in ipairs(player.hand) do
    local ok, card_def = pcall(cards.get_card_def, card_id)
    if ok and card_def and card_def.kind == "Spell" then
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
    if ok and card_def and card_def.kind ~= "Structure" and card_def.kind ~= "Artifact" then
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

-- Check if an ability's counter cost can be paid by the source entry.
function abilities.can_pay_counter_cost(ability, source_entry)
  if not ability or not source_entry then return true end
  local effect = ability.effect
  local args = ability.effect_args or {}
  if effect == "remove_counter_draw" or effect == "remove_counter_play" then
    local counter_name = args.counter
    local remove_count = args.remove or 1
    if counter_name and remove_count > 0 then
      local st = source_entry.state or {}
      return unit_stats.counter_count(st, counter_name) >= remove_count
    end
  end
  return true
end

-- Resolve an ability's effect using the dispatch table.
function abilities.resolve(ability, player, game_state, context)
  local handler = effect_handlers[ability.effect]
  if handler then
    handler(ability, player, game_state, context)
  end
end

return abilities
