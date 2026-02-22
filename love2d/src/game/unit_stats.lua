-- Unit stat helpers for runtime modifiers.
-- Supports both persistent bonuses (attack_bonus/health_bonus)
-- and temporary end-of-turn bonuses (temp_attack_bonus/temp_health_bonus).

local unit_stats = {}

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

function unit_stats.effective_attack(card_def, state)
  local base = num(card_def and card_def.attack)
  local total = base + unit_stats.attack_bonus(state)
  if total < 0 then total = 0 end
  return total
end

function unit_stats.effective_health(card_def, state)
  local base = num(card_def and card_def.health)
  local total = base + unit_stats.health_bonus(state)
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
