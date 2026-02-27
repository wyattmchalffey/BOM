-- Ability helpers: cost checking, effect resolution.
-- Abilities are now structured data defined in data/cards.lua.
-- This module provides the dispatch table for resolving effects.

local cards = require("src.game.cards")
local effect_specs = require("src.game.effect_specs")
local unit_stats = require("src.game.unit_stats")

local abilities = {}

local function active_resolve_result(context)
  if type(context) ~= "table" then return nil end
  local result = context._resolve_result
  if type(result) ~= "table" then return nil end
  return result
end

local function append_result_item(result, bucket, item)
  if type(result) ~= "table" or type(bucket) ~= "string" or item == nil then return end
  result[bucket] = result[bucket] or {}
  result[bucket][#result[bucket] + 1] = item
end

local function record_resolve_event(context, event)
  append_result_item(active_resolve_result(context), "events", event)
end

local function record_resolve_followup(context, followup)
  append_result_item(active_resolve_result(context), "followups", followup)
end

local function record_resolve_prompt(context, prompt)
  append_result_item(active_resolve_result(context), "prompts", prompt)
end

function abilities.new_resolve_result(ability, context)
  local effect = nil
  if type(ability) == "table" then
    effect = ability.effect
  end
  return {
    effect = effect,
    handler_found = false,
    resolved = false,
    events = {},
    followups = {},
    prompts = {},
    source = (type(context) == "table" and context.source) or nil,
  }
end

function abilities.merge_resolve_result(into, other)
  if type(into) ~= "table" or type(other) ~= "table" then return into end
  if other.handler_found then into.handler_found = true end
  if other.resolved then into.resolved = true end
  if into.effect == nil and other.effect ~= nil then
    into.effect = other.effect
  end
  for _, bucket in ipairs({ "events", "followups", "prompts" }) do
    if type(other[bucket]) == "table" then
      into[bucket] = into[bucket] or {}
      for i = 1, #other[bucket] do
        into[bucket][#into[bucket] + 1] = other[bucket][i]
      end
    end
  end
  return into
end

function abilities.result_add_event(result, event)
  append_result_item(result, "events", event)
end

function abilities.result_add_followup(result, followup)
  append_result_item(result, "followups", followup)
end

function abilities.result_add_prompt(result, prompt)
  append_result_item(result, "prompts", prompt)
end

local function next_board_instance_id(g)
  if type(g) ~= "table" then return nil end
  local next_id = (g._next_board_instance_id or 0) + 1
  g._next_board_instance_id = next_id
  return next_id
end

local function ensure_board_entry_instance_id_internal(g, entry)
  if type(entry) ~= "table" then return nil end
  if entry.instance_id ~= nil then
    return entry.instance_id
  end
  local next_id = next_board_instance_id(g)
  if next_id == nil then return nil end
  entry.instance_id = next_id
  return next_id
end

function abilities.ensure_board_entry_instance_id(g, entry)
  return ensure_board_entry_instance_id_internal(g, entry)
end

local function legacy_activated_once_key(player_index, source_key)
  if source_key == nil then return nil end
  return tostring(player_index) .. ":" .. tostring(source_key)
end

local function stable_activated_once_key(g, player_index, source, ability_index, source_key)
  if type(player_index) ~= "number" then return nil end
  if type(ability_index) ~= "number" and type(source_key) ~= "string" then return nil end
  if type(source) ~= "table" and type(source_key) == "string" then
    local bi_s, ai_s = string.match(source_key, "^board:(%d+):(%d+)$")
    if bi_s and ai_s then
      source = { type = "board", index = tonumber(bi_s) }
      if type(ability_index) ~= "number" then ability_index = tonumber(ai_s) end
    elseif string.match(source_key, "^base:?%d*$") then
      source = { type = "base" }
    end
  end
  if type(ability_index) ~= "number" then return nil end
  if type(source) ~= "table" then return nil end
  if source.type == "base" then
    return tostring(player_index) .. ":base:" .. tostring(ability_index)
  end
  if source.type ~= "board" or type(source.index) ~= "number" then return nil end
  if type(g) ~= "table" or type(g.players) ~= "table" then return nil end
  local p = g.players[player_index + 1]
  if type(p) ~= "table" or type(p.board) ~= "table" then return nil end
  local entry = p.board[source.index]
  if type(entry) ~= "table" then return nil end
  local instance_id = ensure_board_entry_instance_id_internal(g, entry)
  if instance_id == nil then return nil end
  return tostring(player_index) .. ":board_inst:" .. tostring(instance_id) .. ":" .. tostring(ability_index)
end

function abilities.get_activated_once_keys(g, player_index, source_key, source, ability_index)
  local stable = stable_activated_once_key(g, player_index, source, ability_index, source_key)
  local legacy = legacy_activated_once_key(player_index, source_key)
  return stable or legacy, legacy
end

function abilities.is_activated_ability_used_this_turn(g, player_index, source_key, source, ability_index)
  if type(g) ~= "table" then return false end
  g.activatedUsedThisTurn = g.activatedUsedThisTurn or {}
  local primary, legacy = abilities.get_activated_once_keys(g, player_index, source_key, source, ability_index)
  if primary and g.activatedUsedThisTurn[primary] then return true end
  if legacy and legacy ~= primary and g.activatedUsedThisTurn[legacy] then return true end
  return false
end

function abilities.set_activated_ability_used_this_turn(g, player_index, source_key, source, ability_index, used)
  if type(g) ~= "table" then return end
  g.activatedUsedThisTurn = g.activatedUsedThisTurn or {}
  local primary, legacy = abilities.get_activated_once_keys(g, player_index, source_key, source, ability_index)
  local value = used and true or nil
  if primary then g.activatedUsedThisTurn[primary] = value end
  if legacy and legacy ~= primary then g.activatedUsedThisTurn[legacy] = value end
end

-- Return whether player can pay the ability cost.
function abilities.can_pay_cost(player_resources, cost_list)
  if not cost_list or #cost_list == 0 then return true end
  for _, c in ipairs(cost_list) do
    local have = player_resources[c.type] or 0
    if have < c.amount then return false end
  end
  return true
end

function abilities.pay_cost(player_resources, cost_list)
  if type(player_resources) ~= "table" then return false, "invalid_player_resources" end
  if not abilities.can_pay_cost(player_resources, cost_list) then
    return false, "insufficient_resources"
  end
  for _, c in ipairs(cost_list or {}) do
    player_resources[c.type] = (player_resources[c.type] or 0) - (c.amount or 0)
  end
  return true
end

local function activated_cost_spec(ability)
  if type(ability) ~= "table" or type(ability.effect) ~= "string" then
    return { kind = "resource_list" }
  end
  local spec = effect_specs.get_activation_cost(ability.effect)
  if type(spec) ~= "table" then
    return { kind = "resource_list" }
  end
  return spec
end

local function activated_counter_cost_spec(ability)
  if type(ability) ~= "table" or type(ability.effect) ~= "string" then
    return nil
  end
  local spec = effect_specs.get_counter_cost(ability.effect)
  if type(spec) ~= "table" then
    return nil
  end
  return spec
end

local function activated_selection_cost_spec(ability)
  if type(ability) ~= "table" or type(ability.effect) ~= "string" then
    return nil
  end
  local spec = effect_specs.get_selection_cost(ability.effect)
  if type(spec) ~= "table" then
    return nil
  end
  return spec
end

local function card_has_any_subtype_local(card_def, required_subtypes)
  if type(card_def) ~= "table" or type(card_def.subtypes) ~= "table" then
    return false
  end
  for _, req in ipairs(required_subtypes or {}) do
    for _, got in ipairs(card_def.subtypes or {}) do
      if req == got then
        return true
      end
    end
  end
  return false
end

local function upgrade_required_subtypes_local(effect_args)
  local args = effect_args or {}
  if type(args.subtypes) == "table" and #args.subtypes > 0 then
    return args.subtypes
  end
  return { "Warrior" }
end

local function collect_upgrade_followup_hand_tiers(player, required_subtypes)
  local tiers = {}
  for _, card_id in ipairs((player and player.hand) or {}) do
    local ok_h, hdef = pcall(cards.get_card_def, card_id)
    if ok_h and hdef and card_has_any_subtype_local(hdef, required_subtypes) then
      local tier = tonumber(hdef.tier) or 0
      tiers[tier] = (tiers[tier] or 0) + 1
    end
  end
  return tiers
end

local function activated_variable_cost_resource(ability, cost_spec)
  if type(ability) ~= "table" or type(cost_spec) ~= "table" then return nil end
  if cost_spec.kind ~= "resource_x_from_args" then return nil end
  local args = ability.effect_args or {}
  local field = cost_spec.resource_arg or "resource"
  local resource = args[field]
  if type(resource) ~= "string" or resource == "" then
    return nil
  end
  return resource
end

function abilities.max_activated_variable_cost_amount(player_resources, ability)
  if type(player_resources) ~= "table" then return nil, nil, "invalid_player_resources" end
  local cost_spec = activated_cost_spec(ability)
  if cost_spec.kind ~= "resource_x_from_args" then
    return nil, nil, nil
  end
  local resource = activated_variable_cost_resource(ability, cost_spec)
  if not resource then
    return nil, nil, "invalid_cost_resource"
  end
  local available = tonumber(player_resources[resource]) or 0
  return math.max(0, available), resource, nil
end

function abilities.can_pay_activated_ability_cost(player_resources, ability, opts)
  opts = opts or {}
  if type(ability) ~= "table" then return false, "invalid_ability" end
  if not abilities.can_pay_cost(player_resources, ability.cost) then
    return false, "insufficient_resources"
  end

  local cost_spec = activated_cost_spec(ability)
  if cost_spec.kind ~= "resource_x_from_args" then
    return true, nil
  end

  local max_amount, _, max_err = abilities.max_activated_variable_cost_amount(player_resources, ability)
  if max_err then return false, max_err end
  if type(opts.x_amount) == "number" then
    if opts.x_amount ~= math.floor(opts.x_amount) or opts.x_amount < 0 then
      return false, "invalid_x_amount"
    end
    local min_required = tonumber(cost_spec.min) or 0
    if opts.x_amount < min_required then
      return false, "invalid_x_amount"
    end
    if opts.x_amount > max_amount then
      return false, "insufficient_resources"
    end
  elseif opts.require_variable_min then
    local min_required = tonumber(cost_spec.min) or 0
    if max_amount < min_required then
      return false, "insufficient_resources"
    end
  end
  return true, nil
end

function abilities.pay_activated_ability_cost(player_resources, ability, opts)
  opts = opts or {}
  local ok_cost, reason = abilities.can_pay_activated_ability_cost(player_resources, ability, opts)
  if not ok_cost then return false, reason end

  local ok_pay, pay_reason = abilities.pay_cost(player_resources, ability.cost)
  if not ok_pay then return false, pay_reason end

  local cost_spec = activated_cost_spec(ability)
  if cost_spec.kind == "resource_x_from_args" then
    local x_amount = opts.x_amount
    if type(x_amount) == "number" and x_amount > 0 then
      local resource = activated_variable_cost_resource(ability, cost_spec)
      if not resource then return false, "invalid_cost_resource" end
      player_resources[resource] = (player_resources[resource] or 0) - x_amount
    end
  end
  return true, nil
end

function abilities.can_pay_activated_ability_costs(player_resources, ability, opts)
  opts = opts or {}
  local ok_cost, reason = abilities.can_pay_activated_ability_cost(player_resources, ability, opts)
  if not ok_cost then return false, reason end
  local counter_cost = activated_counter_cost_spec(ability)
  if counter_cost and counter_cost.kind == "remove_from_source" then
    local source_entry = opts.source_entry
    if type(source_entry) ~= "table" then
      return false, "missing_source_entry"
    end
    local args = (type(ability) == "table" and ability.effect_args) or {}
    local counter_name = type(args) == "table" and args[counter_cost.counter_arg] or nil
    if type(counter_name) ~= "string" or counter_name == "" then
      return false, "invalid_counter_cost"
    end
    local amount = (type(args) == "table" and args[counter_cost.amount_arg]) or nil
    if amount == nil then amount = counter_cost.default_amount or 1 end
    if type(amount) ~= "number" or amount ~= math.floor(amount) or amount < 0 then
      return false, "invalid_counter_cost"
    end
    local st = source_entry.state or {}
    if unit_stats.counter_count(st, counter_name) < amount then
      return false, "insufficient_counters"
    end
  end
  if type(ability) == "table" and ability.rest then
    local source_entry = opts.source_entry
    if type(source_entry) == "table" and type(source_entry.state) == "table" and source_entry.state.rested then
      return false, "unit_is_rested"
    end
  end
  return true, nil
end

function abilities.pay_activated_ability_costs(player_resources, ability, opts)
  opts = opts or {}
  local ok_costs, reason = abilities.can_pay_activated_ability_costs(player_resources, ability, opts)
  if not ok_costs then return false, reason end
  local ok_pay, pay_reason = abilities.pay_activated_ability_cost(player_resources, ability, opts)
  if not ok_pay then return false, pay_reason end
  local counter_cost = activated_counter_cost_spec(ability)
  if counter_cost and counter_cost.kind == "remove_from_source" then
    local source_entry = opts.source_entry
    local args = (type(ability) == "table" and ability.effect_args) or {}
    local counter_name = type(args) == "table" and args[counter_cost.counter_arg] or nil
    local amount = (type(args) == "table" and args[counter_cost.amount_arg]) or nil
    if amount == nil then amount = counter_cost.default_amount or 1 end
    if type(source_entry) ~= "table" or type(counter_name) ~= "string" or counter_name == "" then
      return false, "invalid_counter_cost"
    end
    source_entry.state = source_entry.state or {}
    if not unit_stats.remove_counter(source_entry.state, counter_name, amount) then
      return false, "insufficient_counters"
    end
  end
  if type(ability) == "table" and ability.rest then
    local source_entry = opts.source_entry
    if type(source_entry) == "table" then
      source_entry.state = source_entry.state or {}
      source_entry.state.rested = true
    end
  end
  return true, nil
end

function abilities.collect_activated_selection_cost_targets(g, player_index, ability, opts)
  opts = opts or {}
  local selection_cost = activated_selection_cost_spec(ability)
  if not selection_cost then
    return {
      requires_selection = false,
      has_any_target = true,
    }, nil
  end

  if type(g) ~= "table" or type(g.players) ~= "table" then
    return nil, "invalid_game_state"
  end
  if type(player_index) ~= "number" then
    return nil, "invalid_player"
  end
  local p = g.players[player_index + 1]
  if type(p) ~= "table" then
    return nil, "invalid_player"
  end

  if selection_cost.kind == "sacrifice_target" then
    local eligible_board_indices = abilities.find_sacrifice_targets(p, (type(ability) == "table" and ability.effect_args) or {})
    local allow_worker_tokens = selection_cost.allow_worker_tokens == true
    local has_worker_tokens = allow_worker_tokens and (tonumber(p.totalWorkers) or 0) > 0 or false
    local out = {
      requires_selection = true,
      selection_cost = selection_cost,
      kind = selection_cost.kind,
      effect = ability and ability.effect or nil,
      eligible_board_indices = eligible_board_indices,
      allow_worker_tokens = allow_worker_tokens,
      has_worker_tokens = has_worker_tokens,
      has_any_target = (#eligible_board_indices > 0) or has_worker_tokens,
    }
    if opts.include_worker_target_kinds ~= false and allow_worker_tokens then
      out.worker_target_kinds = {
        "worker_unassigned",
        "worker_left",
        "worker_right",
        "structure_worker",
      }
    end
    return out, nil
  end

  if selection_cost.kind == "upgrade_sacrifice_target" then
    local required_subtypes = upgrade_required_subtypes_local((type(ability) == "table" and ability.effect_args) or {})
    local hand_tiers = collect_upgrade_followup_hand_tiers(p, required_subtypes)
    local eligible_board_indices = {}
    for si, entry in ipairs(p.board or {}) do
      local ok_t, tdef = pcall(cards.get_card_def, entry.card_id)
      if ok_t and tdef and tdef.kind ~= "Structure" and tdef.kind ~= "Artifact"
        and card_has_any_subtype_local(tdef, required_subtypes) then
        local next_tier = (tonumber(tdef.tier) or 0) + 1
        if (hand_tiers[next_tier] or 0) > 0 then
          eligible_board_indices[#eligible_board_indices + 1] = si
        end
      end
    end
    local allow_worker_tokens = selection_cost.allow_worker_tokens == true
    local has_worker_tokens = false
    if allow_worker_tokens then
      local total_workers = tonumber(p.totalWorkers) or 0
      has_worker_tokens = total_workers > 0 and (hand_tiers[1] or 0) > 0
    end
    return {
      requires_selection = true,
      selection_cost = selection_cost,
      kind = selection_cost.kind,
      effect = ability and ability.effect or nil,
      eligible_board_indices = eligible_board_indices,
      allow_worker_tokens = allow_worker_tokens,
      has_worker_tokens = has_worker_tokens,
      required_subtypes = required_subtypes,
      has_any_target = (#eligible_board_indices > 0) or has_worker_tokens,
    }, nil
  end

  return nil, "unsupported_selection_cost"
end

function abilities.validate_activated_selection_cost(g, player_index, ability, opts)
  opts = opts or {}
  local info, info_err = abilities.collect_activated_selection_cost_targets(g, player_index, ability)
  if not info then return false, info_err end
  if info.requires_selection == false then
    return true, nil, info
  end

  if info.kind == "sacrifice_target" then
    local target_board_index = opts.target_board_index
    local target_worker = opts.target_worker
    if target_board_index ~= nil then
      if type(target_board_index) ~= "number" then return false, "invalid_sacrifice_target", info end
      for _, idx in ipairs(info.eligible_board_indices or {}) do
        if idx == target_board_index then
          return true, nil, info
        end
      end
      return false, "target_not_eligible", info
    end

    if target_worker ~= nil then
      if not info.allow_worker_tokens then
        return false, "worker_sacrifice_not_allowed", info
      end
      if not info.has_worker_tokens then
        return false, "no_workers", info
      end
      if type(target_worker) ~= "string" or target_worker == "" then
        return false, "invalid_sacrifice_worker_target", info
      end
      local allowed = {
        worker_unassigned = true,
        worker_left = true,
        worker_right = true,
        structure_worker = true,
        unassigned_pool = true,
      }
      if not allowed[target_worker] then
        return false, "invalid_sacrifice_worker_target", info
      end
      return true, nil, info
    end

    return false, "missing_sacrifice_target", info
  end

  if info.kind == "upgrade_sacrifice_target" then
    local target_board_index = opts.target_board_index
    local target_worker = opts.target_worker
    if target_board_index ~= nil then
      if type(target_board_index) ~= "number" then return false, "invalid_sacrifice_target", info end
      for _, idx in ipairs(info.eligible_board_indices or {}) do
        if idx == target_board_index then
          return true, nil, info
        end
      end
      return false, "invalid_sacrifice_target", info
    end
    if target_worker ~= nil then
      if not info.allow_worker_tokens then
        return false, "worker_sacrifice_not_allowed", info
      end
      if not info.has_worker_tokens then
        return false, "no_workers", info
      end
      local allowed = {
        worker_unassigned = true,
        worker_left = true,
        worker_right = true,
        structure_worker = true,
        unassigned_pool = true,
      }
      if type(target_worker) ~= "string" or not allowed[target_worker] then
        return false, "invalid_sacrifice_worker_target", info
      end
      return true, nil, info
    end
    return false, "missing_sacrifice_target", info
  end

  return false, "unsupported_selection_cost", info
end

local function has_keyword_static(card_def, keyword)
  if type(card_def) ~= "table" or type(keyword) ~= "string" or keyword == "" then return false end
  for _, kw in ipairs(card_def.keywords or {}) do
    if kw == keyword then return true end
  end
  return false
end

function abilities.find_static_effect_ability(card_def, effect_name)
  if type(card_def) ~= "table" or type(card_def.abilities) ~= "table" then return nil end
  for _, ab in ipairs(card_def.abilities) do
    if type(ab) == "table" and ab.type == "static" and ab.effect == effect_name then
      return ab
    end
  end
  return nil
end

local function card_play_cost_spec(card_def)
  if type(card_def) ~= "table" or type(card_def.abilities) ~= "table" then return nil, nil end
  for _, ab in ipairs(card_def.abilities) do
    if type(ab) == "table" and ab.type == "static" and type(ab.effect) == "string" then
      local play_cost = effect_specs.get_play_cost(ab.effect)
      if type(play_cost) == "table" then
        return ab, play_cost
      end
    end
  end
  return nil, nil
end

function abilities.get_card_play_cost_ability(card_def)
  local ab, play_cost = card_play_cost_spec(card_def)
  if not ab then return nil end
  return ab, play_cost
end

function abilities.collect_card_play_cost_targets(g, player_index, card_def)
  local ab, play_cost = card_play_cost_spec(card_def)
  if not ab or not play_cost then return nil, nil end
  if play_cost.kind == "monument_counter" then
    local p = g and g.players and g.players[player_index + 1]
    if not p or type(p.board) ~= "table" then
      return nil, "invalid_player"
    end
    local args = ab.effect_args or {}
    local min_field = play_cost.min_arg or "min_counters"
    local min_counters = tonumber(args[min_field]) or 1
    local counter_name = play_cost.counter or "wonder"
    local required_keyword = play_cost.keyword or "monument"
    local eligible = {}
    for si, entry in ipairs(p.board) do
      local ok_def, mon_def = pcall(cards.get_card_def, entry.card_id)
      if ok_def and mon_def and has_keyword_static(mon_def, required_keyword) then
        local count = unit_stats.counter_count(entry.state or {}, counter_name)
        if count >= min_counters then
          eligible[#eligible + 1] = si
        end
      end
    end
    return {
      ability = ab,
      effect = ab.effect,
      play_cost = play_cost,
      eligible_board_indices = eligible,
      min_counters = min_counters,
      counter = counter_name,
      spend = tonumber(play_cost.spend) or 1,
      keyword = required_keyword,
    }, nil
  end
  if play_cost.kind == "worker_sacrifice" then
    local args = ab.effect_args or {}
    local count_field = play_cost.count_arg or "sacrifice_count"
    local required_count = tonumber(args[count_field]) or tonumber(play_cost.default_count) or 2
    return {
      ability = ab,
      effect = ab.effect,
      play_cost = play_cost,
      required_count = required_count,
      worker_sacrifice = true,
    }, nil
  end
  return nil, "unsupported_play_cost"
end

function abilities.validate_card_play_cost_selection(g, player_index, card_def, opts)
  opts = opts or {}
  local info, info_err = abilities.collect_card_play_cost_targets(g, player_index, card_def)
  if not info then return false, info_err end
  if info.play_cost.kind == "monument_counter" then
    local monument_board_index = opts.monument_board_index
    if type(monument_board_index) ~= "number" then return false, "missing_monument_board_index" end
    local p = g and g.players and g.players[player_index + 1]
    if not p then return false, "invalid_player" end
    local entry = p.board[monument_board_index]
    if not entry then return false, "invalid_monument" end
    local ok_def, mon_def = pcall(cards.get_card_def, entry.card_id)
    if not ok_def or not mon_def then return false, "invalid_monument_card" end
    if not has_keyword_static(mon_def, info.keyword) then return false, "not_a_monument" end
    local count = unit_stats.counter_count(entry.state or {}, info.counter)
    if count < info.min_counters then return false, "insufficient_monument_counters" end
    return true, nil, info, entry
  end
  if info.play_cost.kind == "worker_sacrifice" then
    local required_count = tonumber(info.required_count) or 0
    if opts.sacrifice_targets ~= nil then
      if type(opts.sacrifice_targets) ~= "table" or #opts.sacrifice_targets ~= required_count then
        return false, "invalid_sacrifice_targets"
      end
      return true, nil, info
    end
    if opts.available_unassigned_workers ~= nil then
      local available = tonumber(opts.available_unassigned_workers) or 0
      if available < required_count then
        return false, "not_enough_workers"
      end
      return true, nil, info
    end
    return false, "missing_sacrifice_payment_mode"
  end
  return false, "unsupported_play_cost"
end

function abilities.pay_card_play_cost(g, player_index, card_def, opts)
  local ok_sel, reason, info, selected_entry = abilities.validate_card_play_cost_selection(g, player_index, card_def, opts)
  if not ok_sel then return false, reason end
  if info.play_cost.kind == "monument_counter" then
    if type(selected_entry) ~= "table" then return false, "invalid_monument" end
    selected_entry.state = selected_entry.state or {}
    if not unit_stats.remove_counter(selected_entry.state, info.counter, info.spend) then
      return false, "insufficient_monument_counters"
    end
    return true, nil, info
  end
  if info.play_cost.kind == "worker_sacrifice" then
    return false, "worker_sacrifice_pay_not_supported"
  end
  return false, "unsupported_play_cost"
end

---------------------------------------------------------
-- Effect dispatch table
-- Each handler: function(ability, player, game_state)
-- Add new effects by adding entries to this table.
---------------------------------------------------------
local effect_handlers = {}

local function has_subtype(card_def, subtype)
  if not card_def or type(card_def.subtypes) ~= "table" or type(subtype) ~= "string" then
    return false
  end
  for _, st in ipairs(card_def.subtypes) do
    if st == subtype then return true end
  end
  return false
end

local function is_unit_like(card_def)
  return card_def and (card_def.kind == "Unit" or card_def.kind == "Worker")
end

local function count_owned_copies_on_board(player, card_id)
  if type(player) ~= "table" or type(player.board) ~= "table" then return 0 end
  if type(card_id) ~= "string" or card_id == "" then return 0 end
  local owned = 0
  for _, entry in ipairs(player.board) do
    if type(entry) == "table" and entry.card_id == card_id then
      owned = owned + 1
    end
  end
  return owned
end

local function effective_card_tier_for_player(player, card_def)
  local base_tier = tonumber(card_def and card_def.tier) or 0
  if type(card_def) ~= "table" then
    return base_tier
  end
  if card_def.dynamic_tier_mode == "owned_plus_one" then
    return count_owned_copies_on_board(player, card_def.id) + 1
  end
  return base_tier
end

local function card_matches_filter(player, card_def, args, default_kind)
  if type(card_def) ~= "table" then return false end
  args = args or {}
  local target_kind = args.kind or default_kind
  if target_kind and card_def.kind ~= target_kind then return false end
  if args.faction and card_def.faction ~= args.faction then return false end
  if args.tier ~= nil and effective_card_tier_for_player(player, card_def) ~= args.tier then
    return false
  end
  if args.subtypes and card_def.subtypes then
    local has_any = false
    for _, req in ipairs(args.subtypes) do
      for _, got in ipairs(card_def.subtypes) do
        if req == got then
          has_any = true
          break
        end
      end
      if has_any then break end
    end
    if not has_any then return false end
  elseif args.subtypes then
    return false
  end
  return true
end

local function trigger_once_key(player_index, source_ref, ability_index, trigger_name)
  return tostring(player_index) .. ":trigger:" .. tostring(source_ref) .. ":" .. tostring(ability_index) .. ":" .. tostring(trigger_name)
end

local function trigger_source_ref(g, source_board_index, source_entry)
  local instance_id = ensure_board_entry_instance_id_internal(g, source_entry)
  if instance_id ~= nil then
    return "inst:" .. tostring(instance_id)
  end
  return "board:" .. tostring(source_board_index)
end

local function count_allied_subtype_on_board(player, subtype)
  if not player or type(player.board) ~= "table" then return 0 end
  local count = 0
  for _, entry in ipairs(player.board) do
    local ok, def = pcall(cards.get_card_def, entry.card_id)
    if ok and def and has_subtype(def, subtype) then
      count = count + 1
    end
  end
  return count
end

effect_handlers.summon_worker = function(ability, player, g, context)
  local amount = (ability.effect_args and ability.effect_args.amount) or 1
  local before = tonumber(player.totalWorkers) or 0
  player.totalWorkers = math.min(before + amount, player.maxWorkers or 99)
  local added = (tonumber(player.totalWorkers) or 0) - before
  if added > 0 then
    record_resolve_event(context, {
      type = "workers_summoned",
      amount = added,
      requested_amount = amount,
    })
  end
end

effect_handlers.draw_cards = function(ability, player, g, context)
  local args = ability.effect_args or {}
  local amount = args.amount or 1
  local drawn = 0
  for _ = 1, amount do
    if not player.deck or #player.deck == 0 then break end
    local card_id = table.remove(player.deck)
    player.hand[#player.hand + 1] = card_id
    drawn = drawn + 1
  end
  if drawn > 0 then
    record_resolve_event(context, {
      type = "cards_drawn",
      amount = drawn,
      requested_amount = amount,
    })
  end
end

effect_handlers.discard_draw = function(ability, player, g)
  -- Handled by the two-step DISCARD_DRAW_HAND command; nothing to do here.
end

effect_handlers.discard_random = function(ability, player, g, context)
  local args = ability.effect_args or {}
  local amount = args.amount or 1
  local discarded = 0
  for _ = 1, amount do
    if #player.hand == 0 then break end
    local idx = math.random(1, #player.hand)
    table.remove(player.hand, idx)
    discarded = discarded + 1
  end
  if discarded > 0 then
    record_resolve_event(context, {
      type = "cards_discarded_random",
      amount = discarded,
      requested_amount = amount,
    })
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
      local new_entry = { card_id = card_id, state = summoned_state() }
      ensure_board_entry_instance_id_internal(g, new_entry)
      player.board[#player.board + 1] = new_entry
    end
    return
  end
  -- Fallback: auto-pick first matching card from hand.
  local indices = abilities.find_matching_hand_indices(player, args)
  if #indices > 0 then
    local i = indices[1]
    local card_id = player.hand[i]
    if card_id then
      table.remove(player.hand, i)
      local new_entry = { card_id = card_id, state = summoned_state() }
      ensure_board_entry_instance_id_internal(g, new_entry)
      player.board[#player.board + 1] = new_entry
    end
  end
end

effect_handlers.research = function(ability, player, g)
  local args = ability.effect_args or {}
  local tier = args.tier
  if type(player.deck) ~= "table" then return end

  for i, card_id in ipairs(player.deck) do
    local ok, def = pcall(cards.get_card_def, card_id)
    if ok and def and def.kind == "Technology" then
      if tier == nil or (def.tier or 0) == tier then
        table.remove(player.deck, i)
        local new_entry = {
          card_id = card_id,
          state = { rested = false },
        }
        ensure_board_entry_instance_id_internal(g, new_entry)
        player.board[#player.board + 1] = new_entry
        return
      end
    end
  end
end

effect_handlers.convert_resource = function(ability, player, g, context)
  local args = ability.effect_args or {}
  local output = args.output
  local amount = args.amount or 1
  if output and player.resources[output] ~= nil then
    player.resources[output] = player.resources[output] + amount
    record_resolve_event(context, {
      type = "resource_gained",
      resource = output,
      amount = amount,
      effect = "convert_resource",
    })
  end
end

effect_handlers.produce_multiple = function(ability, player, g, context)
  local args = ability.effect_args or {}
  local applied = {}
  for _, entry in ipairs(args) do
    local res = entry.resource
    local amount = entry.amount or 0
    if res and player.resources[res] ~= nil then
      player.resources[res] = player.resources[res] + amount
      if amount ~= 0 then
        applied[#applied + 1] = { resource = res, amount = amount }
      end
    end
  end
  if #applied > 0 then
    record_resolve_event(context, {
      type = "resources_gained",
      entries = applied,
      effect = "produce_multiple",
    })
  end
end

effect_handlers.produce = function(ability, player, g, context)
  -- Static production abilities are handled by the turn system.
  -- Triggered/activated produce should resolve immediately.
  if ability.type == "static" then return end
  local args = ability.effect_args or {}
  local res = args.resource
  local amount = args.amount or 0
  if res and amount > 0 and player.resources[res] ~= nil then
    player.resources[res] = player.resources[res] + amount
    record_resolve_event(context, {
      type = "resource_gained",
      resource = res,
      amount = amount,
      effect = "produce",
    })
  end
end

effect_handlers.bonus_production = function(ability, player, g)
  -- Static bonus production is resolved in actions.start_turn where worker
  -- assignment counts are available across resource nodes and structures.
end

effect_handlers.prevent_rot = function(ability, player, g)
  -- Resource rot is not modeled in the current rules engine.
end

effect_handlers.skip_draw = function(ability, player, g)
  -- Handled as a flag check during draw phase
end

effect_handlers.buff_ally_attacker = function(ability, player, g, context)
  -- Primary resolution is handled inline by combat.assign_attack_trigger_targets.
  -- This stub exists for completeness.
end

effect_handlers.buff_warriors_per_scholar = function(ability, player, g, context)
  local args = ability.effect_args or {}
  local combat_state = context and context.combat_state
  if type(combat_state) ~= "table" or type(player) ~= "table" then return end

  local per = tonumber(args.attack_per_scholar) or 0
  if per == 0 then return end
  local scholars = count_allied_subtype_on_board(player, "Scholar")
  local buff = scholars * per
  if buff == 0 then return end

  for _, attacker in ipairs(combat_state.attackers or {}) do
    if not attacker.invalidated then
      local entry = player.board[attacker.board_index]
      if entry then
        local ok, def = pcall(cards.get_card_def, entry.card_id)
        if ok and def and has_subtype(def, "Warrior") then
          entry.state = entry.state or {}
          entry.state.temp_attack_bonus = (entry.state.temp_attack_bonus or 0) + buff
        end
      end
    end
  end
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
    st.perm_keywords = st.perm_keywords or {}
    st.perm_keywords[string.lower(keyword)] = true
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

-- Spell on-cast AOE resolution is handled in spell command handlers.
effect_handlers.deal_damage_aoe = function(ability, player, g, context) end

-- Spell on-cast targeted destroy is handled in spell command handlers.
effect_handlers.destroy_unit = function(ability, player, g, context) end

-- Variable sacrifice-based spell damage is handled by dedicated UI/command flow.
effect_handlers.sacrifice_x_damage = function(ability, player, g, context) end

-- Sacrifice+cast composite ability is handled by a dedicated command flow.
effect_handlers.sacrifice_cast_spell = function(ability, player, g, context) end

effect_handlers.place_counter_on_target = function(ability, player, g, context)
  local args = ability.effect_args or {}
  local counter_name = args.counter
  if type(counter_name) ~= "string" or counter_name == "" then return end
  local target_entry = (context and context.target_entry) or (context and context.source_entry)
  if type(target_entry) ~= "table" then return end
  target_entry.state = target_entry.state or {}
  local amount = args.amount or 1
  unit_stats.add_counter(target_entry.state, counter_name, amount, false)
  record_resolve_event(context, {
    type = "counter_added",
    counter = counter_name,
    amount = amount,
    temporary = false,
    target = (context and context.target_entry and "target_entry") or "source_entry",
  })
end

effect_handlers.unrest_target = function(ability, player, g, context)
  local target_entry = context and context.target_entry
  if type(target_entry) ~= "table" then return end
  target_entry.state = target_entry.state or {}
  target_entry.state.rested = false
  local args = ability.effect_args or {}
  if args.reset_attacked_turn then
    target_entry.state.attacked_turn = nil
  end
  record_resolve_event(context, {
    type = "unit_unrested",
    reset_attacked_turn = args.reset_attacked_turn == true,
  })
end

effect_handlers.mass_unrest = function(ability, player, g, context)
  if not player or type(player.board) ~= "table" then return end
  local args = ability.effect_args or {}
  local reset_attack = (args.reset_attacked_turn ~= false)
  local affected = 0
  for _, entry in ipairs(player.board) do
    local ok, def = pcall(cards.get_card_def, entry.card_id)
    if ok and def and (def.kind == "Unit" or def.kind == "Worker") then
      entry.state = entry.state or {}
      entry.state.rested = false
      if reset_attack then
        entry.state.attacked_turn = nil
      end
      affected = affected + 1
    end
  end
  if affected > 0 then
    record_resolve_event(context, {
      type = "mass_unrest_applied",
      affected = affected,
      reset_attacked_turn = reset_attack,
    })
  end
end

effect_handlers.opt = function(ability, player, g, context)
  -- Temporary deterministic fallback until a choose/reorder UI exists:
  -- "Opt N" draws the current top card when N > 0.
  if not player or type(player.deck) ~= "table" or type(player.hand) ~= "table" then return end
  local args = ability.effect_args or {}
  local amount = tonumber(args.amount) or tonumber(args.base) or 0
  if args.per_subtype then
    amount = amount + count_allied_subtype_on_board(player, args.per_subtype) * (tonumber(args.per_subtype_amount) or 1)
  end
  if amount <= 0 or #player.deck == 0 then return end
  player.hand[#player.hand + 1] = table.remove(player.deck)
end

effect_handlers.steal_resource = function(ability, player, g, context)
  local opponent = context and context.opponent_player
  if type(player) ~= "table" or type(opponent) ~= "table" then return end
  if type(player.resources) ~= "table" or type(opponent.resources) ~= "table" then return end

  local args = ability.effect_args or {}
  local amount = tonumber(args.amount) or 1
  if amount <= 0 then return end

  local priority = {
    "food", "wood", "stone", "gold", "metal", "blood", "bones", "water", "fire", "crystal"
  }
  local seen = {}
  local ordered = {}
  for _, r in ipairs(priority) do
    ordered[#ordered + 1] = r
    seen[r] = true
  end
  local extras = {}
  for r, _ in pairs(opponent.resources) do
    if not seen[r] then extras[#extras + 1] = r end
  end
  table.sort(extras)
  for _, r in ipairs(extras) do
    ordered[#ordered + 1] = r
  end

  local stolen_total = 0
  local stolen_by_resource = {}
  for _ = 1, amount do
    local stolen = false
    for _, res in ipairs(ordered) do
      local have = opponent.resources[res] or 0
      if have > 0 then
        opponent.resources[res] = have - 1
        player.resources[res] = (player.resources[res] or 0) + 1
        stolen_total = stolen_total + 1
        stolen_by_resource[res] = (stolen_by_resource[res] or 0) + 1
        stolen = true
        break
      end
    end
    if not stolen then break end
  end
  if stolen_total > 0 then
    record_resolve_event(context, {
      type = "resources_stolen",
      amount = stolen_total,
      requested_amount = amount,
      by_resource = stolen_by_resource,
    })
  end
end

effect_handlers.search_deck = function(ability, player, g, context)
  local args = ability.effect_args or {}
  local criteria = args.search_criteria or {}
  if type(player) ~= "table" or type(player.deck) ~= "table" or type(player.hand) ~= "table" then
    return
  end
  if type(criteria) ~= "table" then
    criteria = {}
  end
  local function matches_criterion(card_def, crit)
    if type(card_def) ~= "table" or type(crit) ~= "table" then return false end
    if crit.kind and card_def.kind ~= crit.kind then return false end
    if crit.faction and card_def.faction ~= crit.faction then return false end
    if crit.subtypes then
      if type(crit.subtypes) ~= "table" or type(card_def.subtypes) ~= "table" then return false end
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
          record_resolve_event(context, {
            type = "deck_search_hit",
            card_id = card_id,
          })
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
  local amount = args.amount or 1
  local is_temporary = (args.duration == "end_of_turn")
  unit_stats.add_counter(source_entry.state, counter_name, amount, is_temporary)
  record_resolve_event(context, {
    type = "counter_added",
    counter = counter_name,
    amount = amount,
    temporary = is_temporary,
    target = "source_entry",
  })
end

effect_handlers.remove_counter_draw = function(ability, player, g, context)
  local args = ability.effect_args or {}
  local source_entry = context and context.source_entry
  if type(source_entry) ~= "table" then return end
  source_entry.state = source_entry.state or {}
  if not (context and context.activated_costs_paid) then
    if not unit_stats.remove_counter(source_entry.state, args.counter, args.remove or 1) then return end
  end
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
  if not (context and context.activated_costs_paid) then
    if not unit_stats.remove_counter(source_entry.state, args.counter, args.remove or 1) then return end
  end
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
    local new_entry = {
      card_id = card_id,
      state = { rested = false, summoned_turn = g and g.turnNumber or nil },
    }
    ensure_board_entry_instance_id_internal(g, new_entry)
    player.board[#player.board + 1] = new_entry
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
    local new_entry = {
      card_id = gentry.card_id,
      state = { rested = false, summoned_turn = g and g.turnNumber or nil },
    }
    ensure_board_entry_instance_id_internal(g, new_entry)
    player.board[#player.board + 1] = new_entry
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
    if ok and card_def and card_matches_filter(player, card_def, args, "Unit") then
      indices[#indices + 1] = i
    end
  end
  return indices
end

function abilities.effective_tier_for_card(player, card_def)
  return effective_card_tier_for_player(player, card_def)
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

function abilities.get_effect_spec(effect_name)
  return effect_specs.get(effect_name)
end

function abilities.has_subtype(card_def, subtype)
  return has_subtype(card_def, subtype)
end

function abilities.is_unit_like(card_def)
  return is_unit_like(card_def)
end

local function resolve_effect_target_rule(effect_name, effect_args)
  local targeting = effect_specs.get_targeting(effect_name)
  if type(targeting) ~= "table" then
    return nil
  end
  local args = effect_args or {}

  local function build_rule_from(source, target_key)
    if type(source) ~= "table" then
      return nil, "invalid_target_rule"
    end
    local mode = source.selection_mode
    if type(mode) ~= "string" or mode == "" then
      return nil, "invalid_target_rule"
    end
    return {
      effect = effect_name,
      target_key = target_key,
      selection_mode = mode,
      player_scope = source.player_scope,
      card_predicate = source.card_predicate,
      allow_base = (source.allow_base == true),
      selector = targeting.selector,
      targeting_kind = targeting.kind,
    }, nil
  end

  if type(targeting.selection_cases) == "table" then
    local arg_name = targeting.selection_arg
    local target_key = (type(arg_name) == "string" and args[arg_name]) or nil
    if target_key == nil then target_key = targeting.selection_default end
    local case_spec = targeting.selection_cases[target_key]
    if case_spec == nil then
      return nil, "invalid_target_mode"
    end
    return build_rule_from(case_spec, target_key)
  end

  return build_rule_from(targeting, nil)
end

local function target_player_scope_allows(source_player_index, target_player_index, player_scope)
  if type(target_player_index) ~= "number" then return false end
  if player_scope == "ally" then
    return type(source_player_index) == "number" and target_player_index == source_player_index
  end
  if player_scope == "opponent" then
    return type(source_player_index) == "number" and target_player_index == (1 - source_player_index)
  end
  if player_scope == "either" then
    return target_player_index == 0 or target_player_index == 1
  end
  return false
end

local function target_scope_player_list(source_player_index, player_scope)
  if player_scope == "ally" and type(source_player_index) == "number" then
    return { source_player_index }
  end
  if player_scope == "opponent" and type(source_player_index) == "number" then
    return { 1 - source_player_index }
  end
  if player_scope == "either" then
    return { 0, 1 }
  end
  return nil
end

local function validate_target_card_predicate(effect_name, args, predicate, target_def)
  if predicate == nil or predicate == "any_board_entry" then
    return true
  end
  if predicate == "unit_like" then
    if not is_unit_like(target_def) then
      if effect_name == "destroy_unit" then
        return false, "invalid_destroy_target"
      end
      return false, "target_not_a_unit"
    end
    return true
  end
  if predicate == "destroy_unit" then
    if not is_unit_like(target_def) then
      return false, "invalid_destroy_target"
    end
    if type(args) == "table" and args.condition == "non_undead" and has_subtype(target_def, "Undead") then
      return false, "invalid_destroy_target"
    end
    return true
  end
  return false, "invalid_target"
end

function abilities.get_effect_target_rule(effect_name, effect_args)
  return resolve_effect_target_rule(effect_name, effect_args)
end

function abilities.effect_requires_target_selection(effect_name, effect_args)
  local rule = resolve_effect_target_rule(effect_name, effect_args)
  return type(rule) == "table" and rule.selection_mode ~= "none"
end

function abilities.collect_effect_target_candidates(game_state, source_player_index, effect_name, effect_args)
  local rule, reason = resolve_effect_target_rule(effect_name, effect_args)
  if not rule then return nil, reason end
  if rule.selection_mode == "none" then
    return {
      effect = effect_name,
      target_rule = rule,
      requires_target = false,
    }, nil
  end

  local players = target_scope_player_list(source_player_index, rule.player_scope)
  if type(players) ~= "table" or #players == 0 then
    return nil, "invalid_target_scope"
  end

  local by_player = {}
  local total_board_targets = 0
  for _, pi in ipairs(players) do
    local tp = game_state and game_state.players and game_state.players[pi + 1]
    local eligible = {}
    for si, entry in ipairs((tp and tp.board) or {}) do
      local ok_d, target_def = pcall(cards.get_card_def, entry.card_id)
      if ok_d and target_def then
        local ok_target = validate_target_card_predicate(effect_name, effect_args or {}, rule.card_predicate, target_def)
        if ok_target then
          eligible[#eligible + 1] = si
        end
      end
    end
    by_player[pi] = eligible
    total_board_targets = total_board_targets + #eligible
  end

  local out = {
    effect = effect_name,
    target_rule = rule,
    requires_target = true,
    total_board_targets = total_board_targets,
  }
  if #players == 1 then
    out.eligible_player_index = players[1]
    out.eligible_board_indices = by_player[players[1]] or {}
  else
    out.eligible_board_indices_by_player = by_player
  end
  if rule.allow_base then
    out.eligible_base_player_indices = {}
    for _, pi in ipairs(players) do
      out.eligible_base_player_indices[pi] = true
    end
  end
  return out, nil
end

function abilities.validate_effect_target_selection(g, source_player_index, effect_name, effect_args, target_player_index, target_board_index, opts)
  opts = opts or {}
  local rule, reason = resolve_effect_target_rule(effect_name, effect_args)
  if not rule then
    return false, reason or "invalid_target_rule"
  end
  if rule.selection_mode == "none" then
    return true
  end
  if type(target_player_index) ~= "number" then return false, "missing_target_player" end
  local tp = g and g.players and g.players[target_player_index + 1]
  if not tp then return false, "invalid_target_player" end
  if not target_player_scope_allows(source_player_index, target_player_index, rule.player_scope) then
    return false, "invalid_target_player"
  end

  if opts.target_is_base then
    if rule.allow_base then
      return true
    end
    return false, "invalid_target"
  end

  if not target_board_index then return false, "missing_target" end
  local target_entry = tp.board[target_board_index]
  if not target_entry then return false, "invalid_target" end
  local ok_t, target_def = pcall(cards.get_card_def, target_entry.card_id)
  if not ok_t or not target_def then return false, "invalid_target_card" end
  return validate_target_card_predicate(effect_name, effect_args or {}, rule.card_predicate, target_def)
end

local function validate_effect_target_card(effect_name, args, target_def)
  local rule = resolve_effect_target_rule(effect_name, args)
  if not rule then return true end
  return validate_target_card_predicate(effect_name, args or {}, rule.card_predicate, target_def)
end

function abilities.find_targeted_spell_on_cast_ability(spell_def)
  if not spell_def then return nil end
  for _, ab in ipairs(spell_def.abilities or {}) do
    if ab.trigger == "on_cast" then
      local spec = effect_specs.get(ab.effect)
      local targeting = spec and spec.targeting
      if targeting and abilities.effect_requires_target_selection(ab.effect, ab.effect_args or {}) then
        return ab
      end
    end
  end
  return nil
end

function abilities.collect_spell_target_candidates(game_state, caster_player_index, spell_def)
  local targeted_ab = abilities.find_targeted_spell_on_cast_ability(spell_def)
  if not targeted_ab then return nil end

  local info = abilities.collect_effect_target_candidates(
    game_state,
    caster_player_index,
    targeted_ab.effect,
    targeted_ab.effect_args or {}
  )
  if not info or not info.requires_target then return nil end
  if type(info.eligible_player_index) ~= "number" or type(info.eligible_board_indices) ~= "table" then
    -- Current spell-target UI supports only a single target player and board targets.
    return nil
  end
  return {
    ability = targeted_ab,
    target_player_index = info.eligible_player_index,
    eligible_board_indices = info.eligible_board_indices,
  }
end

function abilities.validate_spell_on_cast_targets(g, spell_def, target_player_index, target_board_index, caster_player_index, opts)
  opts = opts or {}
  for _, ab in ipairs(spell_def.abilities or {}) do
    if ab.trigger == "on_cast" then
      local spec = effect_specs.get(ab.effect)
      local targeting = spec and spec.targeting
      if targeting and abilities.effect_requires_target_selection(ab.effect, ab.effect_args or {}) then
        local ok_target, target_reason = abilities.validate_effect_target_selection(
          g,
          caster_player_index,
          ab.effect,
          ab.effect_args or {},
          target_player_index,
          target_board_index,
          opts
        )
        if not ok_target then return false, target_reason end
      end
    end
  end
  return true
end

function abilities.can_fire_trigger_once_per_turn(g, player_index, source_board_index, source_entry, ability_index, trigger_name, once_per_turn)
  if not once_per_turn then return true end
  g.activatedUsedThisTurn = g.activatedUsedThisTurn or {}
  local source_ref = trigger_source_ref(g, source_board_index, source_entry)
  return not g.activatedUsedThisTurn[trigger_once_key(player_index, source_ref, ability_index, trigger_name)]
end

function abilities.mark_trigger_fired_once_per_turn(g, player_index, source_board_index, source_entry, ability_index, trigger_name, once_per_turn)
  if not once_per_turn then return end
  g.activatedUsedThisTurn = g.activatedUsedThisTurn or {}
  local source_ref = trigger_source_ref(g, source_board_index, source_entry)
  g.activatedUsedThisTurn[trigger_once_key(player_index, source_ref, ability_index, trigger_name)] = true
end

function abilities.dispatch_card_triggers(card_def, player, game_state, trigger_names, context)
  local aggregate = abilities.new_resolve_result(nil, context)
  if not card_def or type(card_def.abilities) ~= "table" then return aggregate end
  local wanted = {}
  if type(trigger_names) == "string" then
    wanted[trigger_names] = true
  else
    for _, t in ipairs(trigger_names or {}) do wanted[t] = true end
  end

  for _, ab in ipairs(card_def.abilities) do
    if ab.type == "triggered" and wanted[ab.trigger] then
      abilities.merge_resolve_result(aggregate, abilities.resolve(ab, player, game_state, context))
    end
  end
  return aggregate
end

function abilities.dispatch_board_trigger_event(player, game_state, opts)
  local aggregate = abilities.new_resolve_result(nil, (opts and opts.context) or nil)
  opts = opts or {}
  local trigger_name = opts.trigger
  if type(trigger_name) ~= "string" or not player or type(player.board) ~= "table" then
    return aggregate
  end
  local player_index = opts.player_index

  for si, entry in ipairs(player.board) do
    local ok_def, card_def = pcall(cards.get_card_def, entry.card_id)
    if ok_def and card_def and type(card_def.abilities) == "table" then
      for ai, ab in ipairs(card_def.abilities) do
        if ab.type == "triggered" and ab.trigger == trigger_name then
          local should_resolve = true
          if type(opts.should_resolve) == "function" then
            should_resolve = opts.should_resolve(entry, card_def, ab, si, ai) ~= false
          end
          if should_resolve and type(player_index) == "number" then
            should_resolve = abilities.can_fire_trigger_once_per_turn(game_state, player_index, si, entry, ai, trigger_name, ab.once_per_turn)
          end
          if should_resolve then
            local context = opts.context or {}
            if type(opts.build_context) == "function" then
              context = opts.build_context(entry, card_def, ab, si, ai) or context
            end
            if type(context) ~= "table" then context = {} end
            if context.source_entry == nil then context.source_entry = entry end
            if context.source_board_index == nil then context.source_board_index = si end

            local did_resolve = true
            if type(opts.resolve) == "function" then
              local custom_ret = opts.resolve(ab, entry, card_def, si, ai, context)
              if type(custom_ret) == "table" then
                abilities.merge_resolve_result(aggregate, custom_ret)
              end
              did_resolve = custom_ret ~= false
            else
              abilities.merge_resolve_result(aggregate, abilities.resolve(ab, player, game_state, context))
            end

            if did_resolve and type(player_index) == "number" then
              abilities.mark_trigger_fired_once_per_turn(game_state, player_index, si, entry, ai, trigger_name, ab.once_per_turn)
            end
          end
        end
      end
    end
  end
  return aggregate
end

-- Check if an ability's counter cost can be paid by the source entry.
function abilities.can_pay_counter_cost(ability, source_entry)
  local counter_cost = activated_counter_cost_spec(ability)
  if not counter_cost then
    return true
  end
  if counter_cost.kind == "remove_from_source" then
    if type(source_entry) ~= "table" then return false end
    local args = ability and ability.effect_args or {}
    local counter_name = type(args) == "table" and args[counter_cost.counter_arg] or nil
    local amount = type(args) == "table" and args[counter_cost.amount_arg] or nil
    if amount == nil then amount = counter_cost.default_amount or 1 end
    if type(counter_name) ~= "string" or counter_name == "" then return false end
    if type(amount) ~= "number" or amount ~= math.floor(amount) or amount < 0 then return false end
    local st = source_entry.state or {}
    return unit_stats.counter_count(st, counter_name) >= amount
  end
  return true
end

-- Resolve an ability's effect using the dispatch table.
function abilities.resolve(ability, player, game_state, context)
  local ctx = (type(context) == "table") and context or {}
  local prior_result = ctx._resolve_result
  local owns_result = false
  local result = prior_result
  if type(result) ~= "table" then
    result = abilities.new_resolve_result(ability, ctx)
    ctx._resolve_result = result
    owns_result = true
  end

  result.effect = (type(ability) == "table" and ability.effect) or result.effect
  local effect_name = type(ability) == "table" and ability.effect or nil
  local handler = effect_name and effect_handlers[effect_name] or nil
  result.handler_found = (type(handler) == "function")

  if type(handler) == "function" then
    result.resolved = true
    local handler_ret = handler(ability, player, game_state, ctx)
    if type(handler_ret) == "table" and handler_ret ~= result then
      abilities.merge_resolve_result(result, handler_ret)
    end
  end

  if owns_result then
    ctx._resolve_result = prior_result
  end
  return result
end

return abilities
