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
end

return unit_stats
