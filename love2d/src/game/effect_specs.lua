-- Shared effect metadata and effect_args validation.
-- Kept separate from abilities.lua so cards.lua can validate content without
-- creating a cards <-> abilities require cycle.

local effect_specs = {}
local SUPPORT_LEVELS = {
  implemented = true,
  partial = true,
  ui_missing = true,
}

local function is_integer(n)
  return type(n) == "number" and n == math.floor(n)
end

local function is_dense_array(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
      return false
    end
    n = n + 1
  end
  return #t == n
end

local function err(path, msg)
  return tostring(path) .. " " .. tostring(msg)
end

local function validate_string_array(value, path, opts)
  opts = opts or {}
  if type(value) ~= "table" then
    return err(path, "must be a table array of strings")
  end
  if not is_dense_array(value) then
    return err(path, "must be a dense array")
  end
  if not opts.allow_empty and #value == 0 then
    return err(path, "must not be empty")
  end
  for i, item in ipairs(value) do
    if type(item) ~= "string" or item == "" then
      return err(path .. "[" .. tostring(i) .. "]", "must be a non-empty string")
    end
  end
  return nil
end

local function validate_search_criteria(value, path)
  if type(value) ~= "table" then
    return err(path, "must be a table array")
  end
  if not is_dense_array(value) then
    return err(path, "must be a dense array")
  end
  if #value == 0 then
    return err(path, "must not be empty")
  end
  for i, crit in ipairs(value) do
    local cpath = path .. "[" .. tostring(i) .. "]"
    if type(crit) ~= "table" then
      return err(cpath, "must be a table")
    end
    for k, v in pairs(crit) do
      if k == "kind" or k == "faction" then
        if type(v) ~= "string" or v == "" then
          return err(cpath .. "." .. tostring(k), "must be a non-empty string")
        end
      elseif k == "subtypes" then
        local sub_err = validate_string_array(v, cpath .. ".subtypes", { allow_empty = false })
        if sub_err then return sub_err end
      else
        return err(cpath .. "." .. tostring(k), "is not supported by search_deck")
      end
    end
  end
  return nil
end

local function validate_resource_amount_entry(value, path)
  if type(value) ~= "table" then
    return err(path, "must be a table")
  end
  if type(value.resource) ~= "string" or value.resource == "" then
    return err(path .. ".resource", "must be a non-empty string")
  end
  if value.amount ~= nil then
    if not is_integer(value.amount) or value.amount < 0 then
      return err(path .. ".amount", "must be a non-negative integer")
    end
  end
  for k in pairs(value) do
    if k ~= "resource" and k ~= "amount" then
      return err(path .. "." .. tostring(k), "is not allowed")
    end
  end
  return nil
end

local FIELD_VALIDATORS = {
  nonempty_string = function(value, path)
    if type(value) ~= "string" or value == "" then
      return err(path, "must be a non-empty string")
    end
  end,
  boolean = function(value, path)
    if type(value) ~= "boolean" then
      return err(path, "must be a boolean")
    end
  end,
  integer = function(value, path)
    if not is_integer(value) then
      return err(path, "must be an integer")
    end
  end,
  nonneg_integer = function(value, path)
    if not is_integer(value) or value < 0 then
      return err(path, "must be a non-negative integer")
    end
  end,
  positive_integer = function(value, path)
    if not is_integer(value) or value <= 0 then
      return err(path, "must be a positive integer")
    end
  end,
  string_array = function(value, path)
    return validate_string_array(value, path, { allow_empty = false })
  end,
  search_criteria = function(value, path)
    return validate_search_criteria(value, path)
  end,
}

local function enum_values_text(values)
  local out = {}
  for i, v in ipairs(values or {}) do out[i] = tostring(v) end
  return table.concat(out, ", ")
end

local function validate_field(value, path, field_spec)
  if field_spec.kind == "enum" then
    if type(value) ~= "string" or value == "" then
      return err(path, "must be a non-empty string")
    end
    for _, allowed in ipairs(field_spec.values or {}) do
      if value == allowed then return nil end
    end
    return err(path, "must be one of: " .. enum_values_text(field_spec.values))
  end
  local validator = FIELD_VALIDATORS[field_spec.kind]
  if not validator then
    return err(path, "uses unknown validator kind '" .. tostring(field_spec.kind) .. "'")
  end
  return validator(value, path)
end

local function validate_map_args(effect_name, args, schema)
  local path = "effect_args"
  if args == nil then
    if schema.allow_nil == false then
      return err(path, "is required for effect '" .. tostring(effect_name) .. "'")
    end
    return nil
  end
  if type(args) ~= "table" then
    return err(path, "must be a table for effect '" .. tostring(effect_name) .. "'")
  end

  local fields = schema.fields or {}
  for field_name, field_spec in pairs(fields) do
    local value = args[field_name]
    if value == nil then
      if field_spec.required then
        return err(path .. "." .. tostring(field_name), "is required")
      end
    else
      local field_err = validate_field(value, path .. "." .. tostring(field_name), field_spec)
      if field_err then return field_err end
    end
  end

  if schema.allow_extra == false then
    for k in pairs(args) do
      if fields[k] == nil then
        return err(path .. "." .. tostring(k), "is not allowed for effect '" .. tostring(effect_name) .. "'")
      end
    end
  end

  if type(schema.post_validate) == "function" then
    local post_err = schema.post_validate(args, path)
    if post_err then return post_err end
  end
  return nil
end

local function validate_array_args(effect_name, args, schema)
  local path = "effect_args"
  if args == nil then
    if schema.allow_nil == false then
      return err(path, "is required for effect '" .. tostring(effect_name) .. "'")
    end
    return nil
  end
  if type(args) ~= "table" then
    return err(path, "must be a table array for effect '" .. tostring(effect_name) .. "'")
  end
  if not is_dense_array(args) then
    return err(path, "must be a dense array for effect '" .. tostring(effect_name) .. "'")
  end
  if schema.allow_empty == false and #args == 0 then
    return err(path, "must not be empty")
  end
  for i, item in ipairs(args) do
    local item_err = schema.item_validate(item, path .. "[" .. tostring(i) .. "]")
    if item_err then return item_err end
  end
  return nil
end

local function validate_args_by_schema(effect_name, args, schema)
  if not schema then
    if args ~= nil and type(args) ~= "table" then
      return err("effect_args", "must be a table for effect '" .. tostring(effect_name) .. "'")
    end
    return nil
  end
  if schema.shape == "array" then
    return validate_array_args(effect_name, args, schema)
  end
  return validate_map_args(effect_name, args, schema)
end

local function map_schema(fields, opts)
  opts = opts or {}
  return {
    allow_nil = (opts.allow_nil ~= false),
    allow_extra = (opts.allow_extra ~= false),
    fields = fields or {},
    post_validate = opts.post_validate,
  }
end

local function no_args_schema()
  return map_schema({}, { allow_nil = true, allow_extra = false })
end

local FILTER_FIELDS = {
  kind = { kind = "nonempty_string" },
  faction = { kind = "nonempty_string" },
  tier = { kind = "nonneg_integer" },
  subtypes = { kind = "string_array" },
}

local TARGET_ENUM_DAMAGE = { "self", "unit", "any", "global" }
local TARGET_ENUM_DAMAGE_X = { "unit", "any", "global" }
local TARGET_ENUM_RETURN = { "unit", "any" }
local TARGET_SELECTION_MODES = {
  none = true,
  board = true,
  board_or_base = true,
}
local TARGET_PLAYER_SCOPES = {
  ally = true,
  opponent = true,
  either = true,
}
local TARGET_CARD_PREDICATES = {
  any_board_entry = true,
  unit_like = true,
  destroy_unit = true,
}
local ACTIVATION_COST_KINDS = {
  resource_list = true,
  resource_x_from_args = true,
}
local COUNTER_COST_KINDS = {
  remove_from_source = true,
}
local PLAY_COST_KINDS = {
  monument_counter = true,
  worker_sacrifice = true,
}
local SELECTION_COST_KINDS = {
  sacrifice_target = true,
  upgrade_sacrifice_target = true,
}

local function require_any_field(field_names, label)
  return function(args, path)
    for _, name in ipairs(field_names) do
      if args[name] ~= nil then return nil end
    end
    return err(path, "must include " .. tostring(label))
  end
end

local function validate_damage_x_relation(args, path)
  local x_amount = args.x_amount
  local max_x = args.max_x
  if x_amount ~= nil and max_x ~= nil and x_amount > max_x then
    return err(path .. ".x_amount", "must be <= effect_args.max_x")
  end
  return nil
end

local function validate_filter_only_search_criteria(args, path)
  local _ = args
  local _p = path
  return nil
end

local by_effect = {
  summon_worker = {
    args_schema = map_schema({
      amount = { kind = "positive_integer" },
    }, { allow_extra = false }),
  },
  draw_cards = {
    args_schema = map_schema({
      amount = { kind = "positive_integer" },
    }, { allow_extra = false }),
  },
  discard_draw = {
    args_schema = map_schema({
      discard = { kind = "positive_integer" },
      draw = { kind = "positive_integer" },
    }, { allow_extra = false }),
  },
  discard_random = {
    args_schema = map_schema({
      amount = { kind = "positive_integer" },
    }, { allow_extra = false }),
  },
  play_unit = {
    args_schema = map_schema(FILTER_FIELDS, { allow_extra = false }),
  },
  research = {
    args_schema = map_schema({
      tier = { kind = "nonneg_integer" },
    }, { allow_extra = false }),
  },
  convert_resource = {
    args_schema = map_schema({
      output = { kind = "nonempty_string", required = true },
      amount = { kind = "positive_integer" },
    }, { allow_extra = false }),
  },
  produce_multiple = {
    args_schema = {
      shape = "array",
      allow_nil = true,
      allow_empty = false,
      item_validate = validate_resource_amount_entry,
    },
  },
  produce = {
    args_schema = map_schema({
      resource = { kind = "nonempty_string", required = true },
      amount = { kind = "nonneg_integer" },
      per_worker = { kind = "nonneg_integer" },
      max_workers = { kind = "positive_integer" },
      condition = { kind = "nonempty_string" },
    }, {
      allow_extra = false,
      post_validate = require_any_field({ "amount", "per_worker" }, "at least one of amount/per_worker"),
    }),
  },
  bonus_production = {
    args_schema = map_schema({
      per_workers = { kind = "positive_integer", required = true },
      bonus = { kind = "integer", required = true },
    }, { allow_extra = false }),
  },
  prevent_rot = {
    args_schema = map_schema({
      resource = { kind = "nonempty_string", required = true },
      amount = { kind = "nonneg_integer", required = true },
    }, { allow_extra = false }),
  },
  skip_draw = {
    args_schema = no_args_schema(),
  },
  buff_ally_attacker = {
    args_schema = map_schema({
      attack = { kind = "integer" },
      health = { kind = "integer" },
      count = { kind = "positive_integer" },
    }, {
      allow_extra = false,
      post_validate = require_any_field({ "attack", "health" }, "an attack or health buff field"),
    }),
  },
  buff_warriors_per_scholar = {
    args_schema = map_schema({
      attack_per_scholar = { kind = "integer", required = true },
    }, { allow_extra = false }),
  },
  gain_keyword = {
    args_schema = map_schema({
      keyword = { kind = "nonempty_string", required = true },
      duration = { kind = "nonempty_string" },
    }, { allow_extra = false }),
  },
  grant_keyword = {
    args_schema = map_schema({
      keyword = { kind = "nonempty_string", required = true },
      duration = { kind = "nonempty_string" },
    }, { allow_extra = false }),
  },
  buff_self = {
    args_schema = map_schema({
      attack = { kind = "integer" },
      amount = { kind = "integer" },
      health = { kind = "integer" },
      duration = { kind = "nonempty_string" },
    }, {
      allow_extra = false,
      post_validate = require_any_field({ "attack", "amount", "health" }, "at least one of attack/amount/health"),
    }),
  },
  deal_damage = {
    targeting = {
      kind = "board",
      selector = "damage",
      selection_arg = "target",
      selection_default = "self",
      selection_cases = {
        self = { selection_mode = "none" },
        unit = { selection_mode = "board", player_scope = "opponent", card_predicate = "unit_like" },
        any = { selection_mode = "board", player_scope = "opponent", card_predicate = "any_board_entry" },
        global = { selection_mode = "board_or_base", player_scope = "either", card_predicate = "any_board_entry", allow_base = true },
      },
    },
    activation_cost = { kind = "resource_list" },
    resolved_by = "command",
    args_schema = map_schema({
      damage = { kind = "positive_integer", required = true },
      target = { kind = "enum", values = TARGET_ENUM_DAMAGE },
      sacrifice_self = { kind = "boolean" },
    }, { allow_extra = false }),
  },
  deal_damage_x = {
    targeting = {
      kind = "board",
      selector = "damage",
      selection_arg = "target",
      selection_cases = {
        unit = { selection_mode = "board", player_scope = "opponent", card_predicate = "unit_like" },
        any = { selection_mode = "board", player_scope = "opponent", card_predicate = "any_board_entry" },
        global = { selection_mode = "board", player_scope = "opponent", card_predicate = "any_board_entry" },
      },
    },
    activation_cost = { kind = "resource_x_from_args", resource_arg = "resource", amount_param = "x_amount", min = 1 },
    resolved_by = "command",
    args_schema = map_schema({
      resource = { kind = "nonempty_string", required = true },
      target = { kind = "enum", values = TARGET_ENUM_DAMAGE_X },
      x_amount = { kind = "nonneg_integer" },
      max_x = { kind = "nonneg_integer" },
    }, {
      allow_extra = false,
      post_validate = validate_damage_x_relation,
    }),
  },
  destroy_unit = {
    targeting = {
      kind = "board",
      selector = "destroy_unit",
      selection_mode = "board",
      player_scope = "opponent",
      card_predicate = "destroy_unit",
    },
    activation_cost = { kind = "resource_list" },
    resolved_by = "command",
    args_schema = map_schema({
      condition = { kind = "nonempty_string" },
    }, { allow_extra = false }),
  },
  deal_damage_aoe = {
    resolved_by = "command",
    args_schema = map_schema({
      damage = { kind = "positive_integer", required = true },
      target = { kind = "enum", values = { "attacking_units" }, required = true },
    }, { allow_extra = false }),
  },
  play_spell = {
    ui_flow = "select_spell",
    resolved_by = "command",
    args_schema = map_schema(FILTER_FIELDS, { allow_extra = false }),
  },
  sacrifice_cast_spell = {
    ui_flow = "sacrifice_then_select_spell",
    resolved_by = "command",
    selection_cost = {
      kind = "sacrifice_target",
      allow_worker_tokens = false,
    },
    args_schema = map_schema(FILTER_FIELDS, { allow_extra = false }),
  },
  sacrifice_produce = {
    selection_cost = {
      kind = "sacrifice_target",
      allow_worker_tokens = true,
    },
    args_schema = map_schema({
      resource = { kind = "nonempty_string", required = true },
      amount = { kind = "positive_integer", required = true },
      condition = { kind = "nonempty_string" },
    }, { allow_extra = false }),
  },
  sacrifice_upgrade = {
    selection_cost = {
      kind = "upgrade_sacrifice_target",
      allow_worker_tokens = true,
    },
    args_schema = map_schema({
      subtypes = { kind = "string_array" },
    }, { allow_extra = false }),
  },
  sacrifice_x_damage = {
    resolved_by = "command",
    args_schema = map_schema({
      faction = { kind = "nonempty_string" },
      sacrifice_kind = { kind = "nonempty_string" },
      target = { kind = "enum", values = TARGET_ENUM_DAMAGE_X },
    }, { allow_extra = false }),
  },
  place_counter_on_target = {
    targeting = {
      kind = "ally_board",
      selector = "unit_like",
      selection_mode = "board",
      player_scope = "ally",
      card_predicate = "unit_like",
    },
    activation_cost = { kind = "resource_list" },
    args_schema = map_schema({
      counter = { kind = "nonempty_string", required = true },
      amount = { kind = "positive_integer" },
    }, { allow_extra = false }),
  },
  unrest_target = {
    args_schema = map_schema({
      min_attackers = { kind = "positive_integer" },
      reset_attacked_turn = { kind = "boolean" },
    }, { allow_extra = false }),
  },
  mass_unrest = {
    args_schema = map_schema({
      reset_attacked_turn = { kind = "boolean" },
    }, { allow_extra = false }),
  },
  opt = {
    args_schema = map_schema({
      amount = { kind = "nonneg_integer" },
      base = { kind = "nonneg_integer" },
      per_subtype = { kind = "nonempty_string" },
      per_subtype_amount = { kind = "integer" },
    }, { allow_extra = false }),
  },
  steal_resource = {
    args_schema = map_schema({
      amount = { kind = "positive_integer" },
    }, { allow_extra = false }),
  },
  search_deck = {
    args_schema = map_schema({
      search_criteria = { kind = "search_criteria", required = true },
    }, { allow_extra = false, post_validate = validate_filter_only_search_criteria }),
  },
  place_counter = {
    args_schema = map_schema({
      counter = { kind = "nonempty_string", required = true },
      amount = { kind = "positive_integer" },
      duration = { kind = "nonempty_string" },
      condition = { kind = "nonempty_string" },
    }, { allow_extra = false }),
  },
  remove_counter_draw = {
    counter_cost = {
      kind = "remove_from_source",
      counter_arg = "counter",
      amount_arg = "remove",
      default_amount = 1,
    },
    args_schema = map_schema({
      counter = { kind = "nonempty_string", required = true },
      remove = { kind = "positive_integer" },
      draw = { kind = "positive_integer" },
    }, { allow_extra = false }),
  },
  remove_counter_play = {
    counter_cost = {
      kind = "remove_from_source",
      counter_arg = "counter",
      amount_arg = "remove",
      default_amount = 1,
    },
    args_schema = map_schema({
      counter = { kind = "nonempty_string", required = true },
      remove = { kind = "positive_integer" },
      faction = { kind = "nonempty_string" },
      tier = { kind = "nonneg_integer" },
      subtypes = { kind = "string_array" },
    }, { allow_extra = false }),
  },
  return_from_graveyard = {
    args_schema = map_schema({
      count = { kind = "positive_integer" },
      tier = { kind = "nonneg_integer" },
      subtypes = { kind = "string_array" },
      target = { kind = "enum", values = TARGET_ENUM_RETURN },
      return_to = { kind = "enum", values = { "hand" } },
    }, { allow_extra = false }),
  },
  conditional_damage = {
    args_schema = map_schema({
      condition = { kind = "nonempty_string", required = true },
      damage = { kind = "positive_integer", required = true },
      target = { kind = "enum", values = { "unit", "unit_row" }, required = true },
    }, { allow_extra = false }),
  },
  global_buff = {
    args_schema = map_schema({
      attack = { kind = "integer" },
      health = { kind = "integer" },
      kind = { kind = "nonempty_string" },
      faction = { kind = "nonempty_string" },
      subtypes = { kind = "string_array" },
    }, {
      allow_extra = false,
      post_validate = require_any_field({ "attack", "health" }, "at least one of attack/health"),
    }),
  },
  monument_cost = {
    play_cost = {
      kind = "monument_counter",
      counter = "wonder",
      min_arg = "min_counters",
      spend = 1,
      keyword = "monument",
    },
    args_schema = map_schema({
      min_counters = { kind = "positive_integer" },
    }, { allow_extra = false }),
  },
  play_cost_sacrifice = {
    play_cost = {
      kind = "worker_sacrifice",
      count_arg = "sacrifice_count",
      default_count = 2,
    },
    args_schema = map_schema({
      sacrifice_count = { kind = "positive_integer" },
    }, { allow_extra = false }),
  },
  double_production = {
    args_schema = no_args_schema(),
  },
}

local effect_support = {
  prevent_rot = {
    level = "partial",
    note = "Resource rot is not modeled in the current engine, so this effect is a no-op.",
  },
  opt = {
    level = "partial",
    note = "Uses a deterministic fallback (top-card draw) instead of a choose/reorder UI.",
  },
  sacrifice_x_damage = {
    level = "ui_missing",
    note = "Interactive X worker-sacrifice targeting flow is not implemented yet.",
  },
}

local function shallow_copy_table(t)
  if type(t) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

local function validate_support_registry()
  for effect_name, support in pairs(effect_support) do
    if by_effect[effect_name] == nil then
      error("Effect support registry references unknown effect '" .. tostring(effect_name) .. "'")
    end
    if type(support) ~= "table" then
      error("Effect support entry for '" .. tostring(effect_name) .. "' must be a table")
    end
    if not SUPPORT_LEVELS[support.level] then
      error("Effect support entry for '" .. tostring(effect_name) .. "' has invalid level '" .. tostring(support.level) .. "'")
    end
    if support.note ~= nil and type(support.note) ~= "string" then
      error("Effect support entry for '" .. tostring(effect_name) .. "' note must be a string")
    end
  end
end

local function validate_targeting_metadata(effect_name, targeting)
  if targeting == nil then return end
  if type(targeting) ~= "table" then
    error("Effect '" .. tostring(effect_name) .. "' targeting metadata must be a table")
  end
  if targeting.selection_cases ~= nil then
    if type(targeting.selection_arg) ~= "string" or targeting.selection_arg == "" then
      error("Effect '" .. tostring(effect_name) .. "' targeting.selection_arg must be a non-empty string when selection_cases are used")
    end
    if type(targeting.selection_cases) ~= "table" then
      error("Effect '" .. tostring(effect_name) .. "' targeting.selection_cases must be a table")
    end
    for case_name, case_spec in pairs(targeting.selection_cases) do
      if type(case_name) ~= "string" or case_name == "" then
        error("Effect '" .. tostring(effect_name) .. "' targeting.selection_cases keys must be non-empty strings")
      end
      if type(case_spec) ~= "table" then
        error("Effect '" .. tostring(effect_name) .. "' targeting case '" .. tostring(case_name) .. "' must be a table")
      end
      local mode = case_spec.selection_mode
      if not TARGET_SELECTION_MODES[mode] then
        error("Effect '" .. tostring(effect_name) .. "' targeting case '" .. tostring(case_name) .. "' has invalid selection_mode")
      end
      if mode ~= "none" then
        if not TARGET_PLAYER_SCOPES[case_spec.player_scope] then
          error("Effect '" .. tostring(effect_name) .. "' targeting case '" .. tostring(case_name) .. "' has invalid player_scope")
        end
        if not TARGET_CARD_PREDICATES[case_spec.card_predicate] then
          error("Effect '" .. tostring(effect_name) .. "' targeting case '" .. tostring(case_name) .. "' has invalid card_predicate")
        end
      end
      if case_spec.allow_base ~= nil and type(case_spec.allow_base) ~= "boolean" then
        error("Effect '" .. tostring(effect_name) .. "' targeting case '" .. tostring(case_name) .. "' allow_base must be boolean")
      end
    end
    if targeting.selection_default ~= nil and targeting.selection_cases[targeting.selection_default] == nil then
      error("Effect '" .. tostring(effect_name) .. "' targeting.selection_default must reference a valid selection case")
    end
    return
  end

  if targeting.selection_mode ~= nil then
    if not TARGET_SELECTION_MODES[targeting.selection_mode] then
      error("Effect '" .. tostring(effect_name) .. "' targeting.selection_mode is invalid")
    end
    if targeting.selection_mode ~= "none" then
      if not TARGET_PLAYER_SCOPES[targeting.player_scope] then
        error("Effect '" .. tostring(effect_name) .. "' targeting.player_scope is invalid")
      end
      if not TARGET_CARD_PREDICATES[targeting.card_predicate] then
        error("Effect '" .. tostring(effect_name) .. "' targeting.card_predicate is invalid")
      end
    end
  end
end

local function validate_activation_cost_metadata(effect_name, activation_cost)
  if activation_cost == nil then return end
  if type(activation_cost) ~= "table" then
    error("Effect '" .. tostring(effect_name) .. "' activation_cost metadata must be a table")
  end
  if not ACTIVATION_COST_KINDS[activation_cost.kind] then
    error("Effect '" .. tostring(effect_name) .. "' activation_cost.kind is invalid")
  end
  if activation_cost.kind == "resource_x_from_args" then
    if type(activation_cost.resource_arg) ~= "string" or activation_cost.resource_arg == "" then
      error("Effect '" .. tostring(effect_name) .. "' activation_cost.resource_arg must be a non-empty string")
    end
    if activation_cost.amount_param ~= nil and (type(activation_cost.amount_param) ~= "string" or activation_cost.amount_param == "") then
      error("Effect '" .. tostring(effect_name) .. "' activation_cost.amount_param must be a non-empty string")
    end
    if activation_cost.min ~= nil and (not is_integer(activation_cost.min) or activation_cost.min < 0) then
      error("Effect '" .. tostring(effect_name) .. "' activation_cost.min must be a non-negative integer")
    end
  end
end

local function validate_counter_cost_metadata(effect_name, counter_cost)
  if counter_cost == nil then return end
  if type(counter_cost) ~= "table" then
    error("Effect '" .. tostring(effect_name) .. "' counter_cost metadata must be a table")
  end
  if not COUNTER_COST_KINDS[counter_cost.kind] then
    error("Effect '" .. tostring(effect_name) .. "' counter_cost.kind is invalid")
  end
  if counter_cost.kind == "remove_from_source" then
    if type(counter_cost.counter_arg) ~= "string" or counter_cost.counter_arg == "" then
      error("Effect '" .. tostring(effect_name) .. "' counter_cost.counter_arg must be a non-empty string")
    end
    if counter_cost.amount_arg ~= nil and (type(counter_cost.amount_arg) ~= "string" or counter_cost.amount_arg == "") then
      error("Effect '" .. tostring(effect_name) .. "' counter_cost.amount_arg must be a non-empty string")
    end
    if counter_cost.default_amount ~= nil and (not is_integer(counter_cost.default_amount) or counter_cost.default_amount < 0) then
      error("Effect '" .. tostring(effect_name) .. "' counter_cost.default_amount must be a non-negative integer")
    end
  end
end

local function validate_play_cost_metadata(effect_name, play_cost)
  if play_cost == nil then return end
  if type(play_cost) ~= "table" then
    error("Effect '" .. tostring(effect_name) .. "' play_cost metadata must be a table")
  end
  if not PLAY_COST_KINDS[play_cost.kind] then
    error("Effect '" .. tostring(effect_name) .. "' play_cost.kind is invalid")
  end
  if play_cost.kind == "monument_counter" then
    if type(play_cost.counter) ~= "string" or play_cost.counter == "" then
      error("Effect '" .. tostring(effect_name) .. "' play_cost.counter must be a non-empty string")
    end
    if type(play_cost.min_arg) ~= "string" or play_cost.min_arg == "" then
      error("Effect '" .. tostring(effect_name) .. "' play_cost.min_arg must be a non-empty string")
    end
    if play_cost.spend ~= nil and (not is_integer(play_cost.spend) or play_cost.spend < 0) then
      error("Effect '" .. tostring(effect_name) .. "' play_cost.spend must be a non-negative integer")
    end
    if play_cost.keyword ~= nil and (type(play_cost.keyword) ~= "string" or play_cost.keyword == "") then
      error("Effect '" .. tostring(effect_name) .. "' play_cost.keyword must be a non-empty string")
    end
  elseif play_cost.kind == "worker_sacrifice" then
    if type(play_cost.count_arg) ~= "string" or play_cost.count_arg == "" then
      error("Effect '" .. tostring(effect_name) .. "' play_cost.count_arg must be a non-empty string")
    end
    if play_cost.default_count ~= nil and (not is_integer(play_cost.default_count) or play_cost.default_count < 0) then
      error("Effect '" .. tostring(effect_name) .. "' play_cost.default_count must be a non-negative integer")
    end
  end
end

local function validate_selection_cost_metadata(effect_name, selection_cost)
  if selection_cost == nil then return end
  if type(selection_cost) ~= "table" then
    error("Effect '" .. tostring(effect_name) .. "' selection_cost metadata must be a table")
  end
  if not SELECTION_COST_KINDS[selection_cost.kind] then
    error("Effect '" .. tostring(effect_name) .. "' selection_cost.kind is invalid")
  end
  if selection_cost.kind == "sacrifice_target" then
    if selection_cost.allow_worker_tokens ~= nil and type(selection_cost.allow_worker_tokens) ~= "boolean" then
      error("Effect '" .. tostring(effect_name) .. "' selection_cost.allow_worker_tokens must be a boolean")
    end
  elseif selection_cost.kind == "upgrade_sacrifice_target" then
    if selection_cost.allow_worker_tokens ~= nil and type(selection_cost.allow_worker_tokens) ~= "boolean" then
      error("Effect '" .. tostring(effect_name) .. "' selection_cost.allow_worker_tokens must be a boolean")
    end
  end
end

local function validate_effect_metadata_registry()
  for effect_name, spec in pairs(by_effect) do
    if type(spec) ~= "table" then
      error("Effect spec for '" .. tostring(effect_name) .. "' must be a table")
    end
    validate_targeting_metadata(effect_name, spec.targeting)
    validate_activation_cost_metadata(effect_name, spec.activation_cost)
    validate_counter_cost_metadata(effect_name, spec.counter_cost)
    validate_play_cost_metadata(effect_name, spec.play_cost)
    validate_selection_cost_metadata(effect_name, spec.selection_cost)
  end
end

validate_support_registry()
validate_effect_metadata_registry()

effect_specs.by_effect = by_effect
effect_specs.SUPPORT_LEVELS = shallow_copy_table(SUPPORT_LEVELS)

function effect_specs.get(effect_name)
  return by_effect[effect_name]
end

function effect_specs.get_targeting(effect_name)
  local spec = by_effect[effect_name]
  return spec and spec.targeting or nil
end

function effect_specs.get_activation_cost(effect_name)
  local spec = by_effect[effect_name]
  return spec and spec.activation_cost or nil
end

function effect_specs.get_counter_cost(effect_name)
  local spec = by_effect[effect_name]
  return spec and spec.counter_cost or nil
end

function effect_specs.get_play_cost(effect_name)
  local spec = by_effect[effect_name]
  return spec and spec.play_cost or nil
end

function effect_specs.get_selection_cost(effect_name)
  local spec = by_effect[effect_name]
  return spec and spec.selection_cost or nil
end

function effect_specs.is_known(effect_name)
  return by_effect[effect_name] ~= nil
end

function effect_specs.validate_effect_args(effect_name, effect_args)
  local spec = by_effect[effect_name]
  if not spec then
    return "unknown effect '" .. tostring(effect_name) .. "'"
  end
  return validate_args_by_schema(effect_name, effect_args, spec.args_schema)
end

function effect_specs.get_support(effect_name)
  if by_effect[effect_name] == nil then return nil end
  local support = effect_support[effect_name]
  if not support then
    return { level = "implemented" }
  end
  return {
    level = support.level or "implemented",
    note = support.note,
  }
end

function effect_specs.get_support_level(effect_name)
  local support = effect_specs.get_support(effect_name)
  return support and support.level or nil
end

function effect_specs.support_severity(level)
  if level == "ui_missing" then return 2 end
  if level == "partial" then return 1 end
  if level == "implemented" then return 0 end
  return -1
end

function effect_specs.collect_card_support_warnings(card_def)
  local out = {}
  if type(card_def) ~= "table" or type(card_def.abilities) ~= "table" then
    return out
  end
  for ai, ab in ipairs(card_def.abilities) do
    if type(ab) == "table" and type(ab.effect) == "string" then
      local support = effect_specs.get_support(ab.effect)
      if support and support.level and support.level ~= "implemented" then
        out[#out + 1] = {
          kind = "mechanic_support",
          card_id = card_def.id,
          card_name = card_def.name,
          ability_index = ai,
          effect = ab.effect,
          level = support.level,
          note = support.note,
        }
      end
    end
  end
  return out
end

return effect_specs
