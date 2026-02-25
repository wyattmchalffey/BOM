-- Card registry: loads data/cards.lua and builds fast lookup tables.

local card_data = require("src.data.cards")
local effect_specs = require("src.game.effect_specs")

local cards = {}
local _support_warnings = {}
local _support_warnings_by_card = {}

local function fail_def(msg, def, index)
  local suffix = ""
  if def and def.id then
    suffix = " [" .. tostring(def.id) .. "]"
  elseif index then
    suffix = " [index " .. tostring(index) .. "]"
  end
  error("Card data validation failed: " .. tostring(msg) .. suffix)
end

local function validate_ability_shape(ab, def, ai)
  if type(ab) ~= "table" then
    fail_def("ability is not a table at slot " .. tostring(ai), def)
  end
  if type(ab.type) ~= "string" then
    fail_def("ability missing type at slot " .. tostring(ai), def)
  end
  local t = ab.type
  if t ~= "activated" and t ~= "triggered" and t ~= "static" then
    fail_def("ability has invalid type '" .. tostring(t) .. "' at slot " .. tostring(ai), def)
  end
  if t == "triggered" and type(ab.trigger) ~= "string" then
    fail_def("triggered ability missing trigger at slot " .. tostring(ai), def)
  end
  if type(ab.effect) ~= "string" or ab.effect == "" then
    fail_def("ability missing effect at slot " .. tostring(ai), def)
  end
  if ab.once_per_turn ~= nil and type(ab.once_per_turn) ~= "boolean" then
    fail_def("ability once_per_turn must be boolean at slot " .. tostring(ai), def)
  end
end

local function is_integer(n)
  return type(n) == "number" and n == math.floor(n)
end

local function validate_cost_list(cost_list, label, def)
  if type(cost_list) ~= "table" then
    fail_def(label .. " must be a table", def)
  end
  local count = 0
  for k in pairs(cost_list) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
      fail_def(label .. " must be a dense array", def)
    end
    count = count + 1
  end
  if #cost_list ~= count then
    fail_def(label .. " must be a dense array", def)
  end
  for ci, c in ipairs(cost_list) do
    if type(c) ~= "table" then
      fail_def(label .. " entry is not a table at slot " .. tostring(ci), def)
    end
    if type(c.type) ~= "string" or c.type == "" then
      fail_def(label .. " entry missing type at slot " .. tostring(ci), def)
    end
    if not is_integer(c.amount) or c.amount <= 0 then
      fail_def(label .. " entry amount must be positive integer at slot " .. tostring(ci), def)
    end
  end
end

local function validate_ability_content(ab, def, ai)
  if ab.cost ~= nil then
    validate_cost_list(ab.cost, "ability cost at slot " .. tostring(ai), def)
  end
  if ab.effect_args ~= nil and type(ab.effect_args) ~= "table" then
    fail_def("ability effect_args must be a table at slot " .. tostring(ai), def)
  end
  local effect_err = effect_specs.validate_effect_args(ab.effect, ab.effect_args)
  if effect_err then
    fail_def("ability effect_args invalid at slot " .. tostring(ai) .. ": " .. effect_err, def)
  end
end

local function validate_card_def(def, index)
  if type(def) ~= "table" then
    fail_def("card entry is not a table", nil, index)
  end
  if type(def.id) ~= "string" or def.id == "" then
    fail_def("card missing id", def, index)
  end
  if type(def.name) ~= "string" then
    fail_def("card missing name", def, index)
  end
  if type(def.kind) ~= "string" then
    fail_def("card missing kind", def, index)
  end
  validate_cost_list(def.costs, "card costs", def)
  if def.upkeep ~= nil then
    validate_cost_list(def.upkeep, "card upkeep", def)
  end
  if def.abilities ~= nil and type(def.abilities) ~= "table" then
    fail_def("card abilities must be a table", def, index)
  end
  for ai, ab in ipairs(def.abilities or {}) do
    validate_ability_shape(ab, def, ai)
    validate_ability_content(ab, def, ai)
  end
end

local function shallow_copy_warning(w)
  local out = {}
  for k, v in pairs(w or {}) do
    out[k] = v
  end
  return out
end

local function copy_warning_list(list)
  local out = {}
  for i = 1, #(list or {}) do
    out[i] = shallow_copy_warning(list[i])
  end
  return out
end

local function collect_support_warnings_for_card(def)
  local warnings = effect_specs.collect_card_support_warnings(def)
  if type(warnings) ~= "table" or #warnings == 0 then return end
  _support_warnings_by_card[def.id] = _support_warnings_by_card[def.id] or {}
  for _, w in ipairs(warnings) do
    _support_warnings[#_support_warnings + 1] = shallow_copy_warning(w)
    _support_warnings_by_card[def.id][#_support_warnings_by_card[def.id] + 1] = shallow_copy_warning(w)
  end
end

-- Build ID → def lookup once at load time
local _by_id = {}
for i, def in ipairs(card_data) do
  validate_card_def(def, i)
  if _by_id[def.id] then
    fail_def("duplicate card id", def, i)
  end
  _by_id[def.id] = def
  collect_support_warnings_for_card(def)
end

-- All card definitions (list, for iteration)
cards.CARD_DEFS = card_data
cards.SUPPORT_WARNINGS = _support_warnings

function cards.get_card_def(id)
  local def = _by_id[id]
  if not def then error("Unknown card id: " .. tostring(id)) end
  return def
end

-- List all card defs matching a filter (kind, faction, or both)
function cards.filter(opts)
  local out = {}
  for _, def in ipairs(card_data) do
    local match = true
    if opts.kind and def.kind ~= opts.kind then match = false end
    if opts.faction and def.faction ~= opts.faction then match = false end
    if match then out[#out + 1] = def end
  end
  return out
end

-- Shorthand: structures for a faction (used by blueprint modal)
function cards.structures_for_faction(faction)
  return cards.filter({ kind = "Structure", faction = faction })
end

-- Get the first activated ability on a card (convenience for base/structure activation)
function cards.get_activated_ability(card_def)
  if not card_def.abilities then return nil end
  for _, ab in ipairs(card_def.abilities) do
    if ab.type == "activated" then return ab end
  end
  return nil
end

function cards.get_support_warnings(card_id)
  return copy_warning_list(_support_warnings_by_card[card_id] or {})
end

function cards.list_support_warnings()
  return copy_warning_list(_support_warnings)
end

function cards.get_card_support_level(card_id)
  local warnings = _support_warnings_by_card[card_id]
  if not warnings or #warnings == 0 then
    return "implemented"
  end
  local best_level = "implemented"
  local best_sev = effect_specs.support_severity(best_level)
  for _, w in ipairs(warnings) do
    local sev = effect_specs.support_severity(w.level)
    if sev > best_sev then
      best_sev = sev
      best_level = w.level
    end
  end
  return best_level
end

return cards
