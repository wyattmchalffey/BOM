-- Unit stat helpers for runtime modifiers.
-- Supports both persistent bonuses (attack_bonus/health_bonus)
-- and temporary end-of-turn bonuses (temp_attack_bonus/temp_health_bonus).

local cards = require("src.game.cards")

local unit_stats = {}
local continuous_cache_by_state = setmetatable({}, { __mode = "k" })
local continuous_effect_collectors = {}

local function num(v)
  if type(v) == "number" then return v end
  local n = tonumber(v)
  return n or 0
end

function unit_stats.attack_bonus(state)
  if type(state) ~= "table" then return 0 end
  return num(state.attack_bonus) + num(state.temp_attack_bonus)
end

function unit_stats.health_bonus(state)
  if type(state) ~= "table" then return 0 end
  return num(state.health_bonus) + num(state.temp_health_bonus)
end

local function has_subtype(card_def, subtype)
  if not card_def or type(card_def.subtypes) ~= "table" then return false end
  for _, st in ipairs(card_def.subtypes) do
    if st == subtype then return true end
  end
  return false
end

local function matches_global_buff_target(target_def, args)
  if not target_def or type(args) ~= "table" then return false end
  if args.kind and target_def.kind ~= args.kind then return false end
  if args.faction and target_def.faction ~= args.faction then return false end
  if type(args.subtypes) == "table" and #args.subtypes > 0 then
    local found = false
    for _, req in ipairs(args.subtypes) do
      if has_subtype(target_def, req) then
        found = true
        break
      end
    end
    if not found then return false end
  end
  return true
end

local function shallow_array_copy(t)
  if type(t) ~= "table" then return nil end
  local out = {}
  for i, v in ipairs(t) do
    out[i] = v
  end
  return out
end

local function continuous_signature(g)
  if type(g) ~= "table" or type(g.players) ~= "table" then return "no_game" end
  -- Current continuous effects (global_buff) depend on board composition/card defs,
  -- not entry runtime state, so the signature only tracks card IDs on board.
  local parts = { "continuous:v2:board_cards" }
  for pi = 1, #g.players do
    local p = g.players[pi]
    parts[#parts + 1] = "|p"
    parts[#parts + 1] = tostring(pi)
    local board = p and p.board
    if type(board) ~= "table" then
      parts[#parts + 1] = ":no_board"
    else
      for bi, entry in ipairs(board) do
        parts[#parts + 1] = "|b"
        parts[#parts + 1] = tostring(bi)
        parts[#parts + 1] = ":"
        parts[#parts + 1] = tostring(entry and entry.card_id or "")
      end
    end
  end
  return table.concat(parts)
end

continuous_effect_collectors.global_buff = function(out, src_def, ab, entry, player_index, g)
  local _ = src_def
  local _e = entry
  local _pi = player_index
  local _g = g
  local args = ab.effect_args or {}
  local atk = num(args.attack)
  local hp = num(args.health)
  if atk == 0 and hp == 0 then
    return
  end
  out.stat_effects[#out.stat_effects + 1] = {
    effect = "global_buff",
    attack = atk,
    health = hp,
    target = {
      kind = args.kind,
      faction = args.faction,
      subtypes = shallow_array_copy(args.subtypes),
    },
    target_state_sensitive = false,
  }
end

local function collect_continuous_effects_for_player(g, player_index)
  local p = g.players and g.players[player_index + 1]
  local out = {
    stat_effects = {},
    memo_by_card = {},
    has_state_sensitive_targets = false,
  }
  if type(p) ~= "table" or type(p.board) ~= "table" then
    return out
  end

  for _, entry in ipairs(p.board) do
    local ok, src_def = pcall(cards.get_card_def, entry.card_id)
    if ok and src_def and type(src_def.abilities) == "table" then
      for _, ab in ipairs(src_def.abilities) do
        if ab.type == "static" and type(ab.effect) == "string" then
          local collector = continuous_effect_collectors[ab.effect]
          if type(collector) == "function" then
            collector(out, src_def, ab, entry, player_index, g)
          end
        end
      end
    end
  end

  return out
end

local function build_continuous_cache(g)
  local cache = {
    signature = continuous_signature(g),
    players = {},
  }
  local player_count = (type(g) == "table" and type(g.players) == "table") and #g.players or 0
  for pi = 0, player_count - 1 do
    cache.players[pi + 1] = collect_continuous_effects_for_player(g, pi)
  end
  return cache
end

function unit_stats.invalidate_continuous_effects(g)
  if type(g) ~= "table" then return end
  g._derived_stats_cache_token = nil
  continuous_cache_by_state[g] = nil
end

function unit_stats.recompute_continuous_effects(g)
  if type(g) ~= "table" then return nil end
  local cache = build_continuous_cache(g)
  cache.stable_token = g._derived_stats_cache_token
  continuous_cache_by_state[g] = cache
  return cache
end

function unit_stats.ensure_continuous_effects(g)
  if type(g) ~= "table" then return nil end
  local cache = continuous_cache_by_state[g]
  if type(cache) == "table" and cache.stable_token ~= nil and cache.stable_token == g._derived_stats_cache_token then
    return cache
  end
  local sig = continuous_signature(g)
  if type(cache) ~= "table" or cache.signature ~= sig then
    cache = build_continuous_cache(g)
    cache.stable_token = g._derived_stats_cache_token
    continuous_cache_by_state[g] = cache
  else
    cache.stable_token = g._derived_stats_cache_token
  end
  return cache
end

-- Alias for future broader derived-stat recompute work.
unit_stats.recompute_derived_stats = unit_stats.recompute_continuous_effects
unit_stats.invalidate_derived_stats = unit_stats.invalidate_continuous_effects

local function continuous_stat_bonus(card_def, state, g, player_index)
  local _ = state -- reserved for future state-sensitive target filters
  if type(g) ~= "table" or type(player_index) ~= "number" or not card_def then
    return 0, 0
  end

  local cache = unit_stats.ensure_continuous_effects(g)
  local player_cache = cache and cache.players and cache.players[player_index + 1] or nil
  if type(player_cache) ~= "table" then
    return 0, 0
  end

  local memo_key = nil
  if not player_cache.has_state_sensitive_targets then
    memo_key = (type(card_def) == "table" and card_def.id) or tostring(card_def)
    local memo = player_cache.memo_by_card[memo_key]
    if memo then
      return memo.attack or 0, memo.health or 0
    end
  end

  local atk, hp = 0, 0
  for _, eff in ipairs(player_cache.stat_effects or {}) do
    if eff.effect == "global_buff" and matches_global_buff_target(card_def, eff.target) then
      atk = atk + num(eff.attack)
      hp = hp + num(eff.health)
    end
  end

  if memo_key ~= nil then
    player_cache.memo_by_card[memo_key] = { attack = atk, health = hp }
  end
  return atk, hp
end

function unit_stats.effective_attack(card_def, state, g, player_index)
  local base = num(card_def and card_def.attack)
  local global_atk = 0
  if g ~= nil and player_index ~= nil then
    global_atk = select(1, continuous_stat_bonus(card_def, state, g, player_index))
  end
  local total = base + unit_stats.attack_bonus(state) + global_atk
  if total < 0 then total = 0 end
  return total
end

function unit_stats.effective_health(card_def, state, g, player_index)
  local base = num(card_def and card_def.health)
  local global_hp = 0
  if g ~= nil and player_index ~= nil then
    global_hp = select(2, continuous_stat_bonus(card_def, state, g, player_index))
  end
  local total = base + unit_stats.health_bonus(state) + global_hp
  if total < 0 then total = 0 end
  return total
end

function unit_stats.has_stat_modifiers(state)
  return unit_stats.attack_bonus(state) ~= 0 or unit_stats.health_bonus(state) ~= 0
end

function unit_stats.clear_end_of_turn(state)
  if type(state) ~= "table" then return end
  state.temp_attack_bonus = nil
  state.temp_health_bonus = nil
  state.temp_keywords = nil
  state.temp_counters = nil
end

---------------------------------------------------------
-- Counter helpers
---------------------------------------------------------

-- Get total count of a specific counter (permanent + temporary).
function unit_stats.counter_count(state, counter_name)
  if type(state) ~= "table" then return 0 end
  local perm = type(state.counters) == "table" and (state.counters[counter_name] or 0) or 0
  local temp = type(state.temp_counters) == "table" and (state.temp_counters[counter_name] or 0) or 0
  return perm + temp
end

-- Get all counters as a merged table { name = count }. Returns nil if none.
function unit_stats.all_counters(state)
  if type(state) ~= "table" then return nil end
  local perm = state.counters
  local temp = state.temp_counters
  if not perm and not temp then return nil end
  local merged = {}
  local any = false
  if type(perm) == "table" then
    for k, v in pairs(perm) do
      if v > 0 then merged[k] = v; any = true end
    end
  end
  if type(temp) == "table" then
    for k, v in pairs(temp) do
      if v > 0 then merged[k] = (merged[k] or 0) + v; any = true end
    end
  end
  return any and merged or nil
end

-- Check if a state has any counters at all (fast check for UI).
function unit_stats.has_counters(state)
  if type(state) ~= "table" then return false end
  if type(state.counters) == "table" then
    for _, v in pairs(state.counters) do
      if v > 0 then return true end
    end
  end
  if type(state.temp_counters) == "table" then
    for _, v in pairs(state.temp_counters) do
      if v > 0 then return true end
    end
  end
  return false
end

-- Add counters to a state.
function unit_stats.add_counter(state, counter_name, amount, is_temporary)
  if type(state) ~= "table" then return end
  local key = is_temporary and "temp_counters" or "counters"
  state[key] = state[key] or {}
  state[key][counter_name] = (state[key][counter_name] or 0) + (amount or 1)
end

-- Remove counters from a state. Returns true if sufficient counters existed.
-- Removes from permanent first, then temporary.
function unit_stats.remove_counter(state, counter_name, amount)
  if type(state) ~= "table" then return false end
  amount = amount or 1
  local current = unit_stats.counter_count(state, counter_name)
  if current < amount then return false end
  local remaining = amount
  if type(state.counters) == "table" and (state.counters[counter_name] or 0) > 0 then
    local perm = state.counters[counter_name]
    local take = math.min(perm, remaining)
    state.counters[counter_name] = perm - take
    if state.counters[counter_name] <= 0 then state.counters[counter_name] = nil end
    remaining = remaining - take
  end
  if remaining > 0 and type(state.temp_counters) == "table" then
    local temp = state.temp_counters[counter_name] or 0
    state.temp_counters[counter_name] = temp - remaining
    if state.temp_counters[counter_name] <= 0 then state.temp_counters[counter_name] = nil end
  end
  return true
end

return unit_stats
