-- In-game screen: game state, board, blueprint modal, drag-drop, End turn button, hand UI

local game_state_module = require("src.game.state")
local game_checksum = require("src.game.checksum")
local commands = require("src.game.commands")
local replay = require("src.game.replay")
local json = require("src.net.json_codec")
local settings_store = require("src.settings")
local board = require("src.ui.board")
local blueprint_modal = require("src.ui.blueprint_modal")
local deck_viewer = require("src.ui.deck_viewer")
local util = require("src.ui.util")
local tween = require("src.fx.tween")
local popup = require("src.fx.popup")
local shake = require("src.fx.shake")
local sound = require("src.fx.sound")
local cards = require("src.game.cards")
local unit_stats = require("src.game.unit_stats")
local abilities = require("src.game.abilities")
local card_frame = require("src.ui.card_frame")
local textures = require("src.fx.textures")
local particles = require("src.fx.particles")
local factions_data = require("src.data.factions")
local config = require("src.data.config")
local res_registry = require("src.data.resources")
local deck_profiles = require("src.game.deck_profiles")

local GameState = {}
GameState.__index = GameState
local validate_prompt_defs_static
local validate_prompt_metadata_runtime
local PROMPT_PAYLOAD_FIELD_SCHEMAS
local prompt_metadata_runtime_validated = false
local IN_GAME_BUG_REPORT_FIELDS = {
  { id = "summary", label = "Summary", multiline = false, height = 34, placeholder = "Short title (e.g. Prince of Reason deck search desync)" },
  { id = "what_happened", label = "What Happened", multiline = true, height = 82, placeholder = "Describe what happened..." },
  { id = "expected", label = "Expected Behavior", multiline = true, height = 64, placeholder = "Describe what should have happened..." },
  { id = "steps", label = "Steps To Reproduce", multiline = true, height = 96, placeholder = "1. ...\n2. ...\n3. ..." },
}

function GameState.new(opts)
  opts = opts or {}
  if not prompt_metadata_runtime_validated and type(validate_prompt_metadata_runtime) == "function" then
    validate_prompt_metadata_runtime(GameState)
    prompt_metadata_runtime_validated = true
  end
  local setup = opts.setup or nil
  if not setup then
    local settings = require("src.settings")
    setup = {
      players = {
        [1] = {
          faction = settings.values.faction,
          deck = deck_profiles.get_deck(settings.values.faction),
        },
      },
    }
  end
  local initial_state = game_state_module.create_initial_game_state(setup)
  local self = setmetatable({
    game_state = initial_state,
    show_blueprint_for_player = nil, -- 0 or 1 when modal open
    drag = nil, -- { player_index, from } where from = "unassigned" | "left" | "right"
    hover = nil, -- { kind, pi, idx } updated every mousemoved
    mouse_down = false, -- true while left button held
    turn_banner_timer = 0, -- countdown for "Player N's Turn" banner
    turn_banner_text = "",
    -- Feature 1: Display resources (smooth count-up) — copies all resource types
    display_resources = {
      {}, {},
    },
    -- Feature 2: Returning workers (snap-back animation)
    returning_workers = {},  -- { {x, y, target_x, target_y, progress, duration} ... }
    -- Feature 4: Cursor state
    _cursor_hand = nil,  -- cached hand cursor
    _current_cursor = "arrow",
    -- Feature 5: Tooltip hover delay
    tooltip_timer = 0,
    tooltip_target = nil, -- { pi, idx } of structure being hovered
    -- Hand UI state
    hand_hover_index = nil,      -- which hand card the mouse is over (1-based)
    hand_selected_index = nil,   -- which hand card is "selected" (clicked)
    pending_play_unit = nil,      -- { source, ability_index, effect_args, eligible_indices }
    pending_sacrifice = nil,      -- { source, ability_index, effect_args, eligible_board_indices }
    pending_hand_sacrifice = nil, -- { hand_index, required_count, selected_targets }
    pending_monument = nil,        -- { hand_index, min_counters, eligible_indices }
    pending_graveyard_return = nil, -- { source, ability_index, max_count, effect_args, selected_graveyard_indices }
    pending_discard_draw = nil,     -- { source, ability_index, required_count, draw_count, selected_set }
    pending_upgrade = nil, -- { source, ability_index, stage, sacrifice_target, eligible_hand_indices, eligible_board_indices, eligible_worker_sacrifice }
    pending_counter_placement = nil, -- { source, ability_index, eligible_board_indices }
    pending_damage_target = nil,     -- { source, ability_index, effect_args, eligible_player_index, eligible_board_indices }
    pending_damage_x = nil,          -- { source, ability_index, effect_args, eligible_player_index, eligible_board_indices, x_amount, max_x }
    pending_spell_target = nil,      -- { hand_index, effect_args, eligible_player_index, eligible_board_indices, monument_board_index?, via_ability_source?, via_ability_ability_index? }
    pending_play_spell = nil,        -- { source, ability_index, cost, effect_args, eligible_indices }
    prompt_stack = {},               -- generic interaction prompts (phase 2 migration; legacy pending_* aliases preserved)
    hand_y_offsets = {},          -- per-card animated y offset (negative = raised)
    command_log = replay.new_log({
      command_schema_version = commands.SCHEMA_VERSION,
      rules_version = config.rules_version,
      content_version = config.content_version,
    }), -- deterministic command stream for replay/network migration
    return_to_menu = opts.return_to_menu,
    authoritative_adapter = opts.authoritative_adapter,
    server_step = opts.server_step,         -- optional: pump websocket server each frame
    server_cleanup = opts.server_cleanup,   -- optional: stop server on exit
    room_code = opts.room_code,             -- relay room code (nil for LAN/local)
    multiplayer_error = nil,
    multiplayer_status = nil,
    reconnect_pending = false,
    reconnect_reason = nil,
    reconnect_attempts = 0,
    reconnect_timer = 0,
    pending_attack_declarations = {}, -- { { attacker_board_index, target={type="base"|"board", index?} } }
    pending_attack_trigger_targets = {}, -- { { attacker_board_index, ability_index, target_board_index?, activate? } }
    pending_block_assignments = {}, -- { { blocker_board_index, attacker_board_index } }
    pending_damage_orders = {}, -- map attacker_board_index -> ordered blocker board indices
    sync_poll_timer = 0,
    sync_poll_interval = 1.0,
    _terminal_announced = false,
    _last_desync_report = nil,
    in_game_settings_open = false,
    in_game_settings_status = nil,
    in_game_settings_status_kind = "info",
    in_game_settings_dragging_slider = false,
    in_game_settings_settings_dirty = false,
    in_game_settings_last_replay_export_path = nil,
    in_game_bug_report_open = false,
    in_game_bug_report_active_field = "summary",
    in_game_bug_report_status = nil,
    in_game_bug_report_status_kind = "info",
    in_game_bug_report_fields = {
      summary = "",
      what_happened = "",
      expected = "",
      steps = "",
    },
  }, GameState)
  -- Cache the hand cursor once
  self._cursor_hand = love.mouse.getSystemCursor("hand")

  if self.authoritative_adapter then
    print("[multiplayer] attempting adapter:connect()...")
    local connected = self.authoritative_adapter:connect()
    print("[multiplayer] connect result: ok=" .. tostring(connected.ok) .. " reason=" .. tostring(connected.reason))
    if connected.meta then
      for k,v in pairs(connected.meta) do
        print("[multiplayer]   meta." .. tostring(k) .. "=" .. tostring(v))
      end
    end
    if connected.ok then
      self.local_player_index = connected.meta and connected.meta.player_index or 0
      local remote_state = self.authoritative_adapter:get_state()
      if remote_state then
        self.game_state = remote_state
      end
      self.multiplayer_status = "Connected"
    else
      self.multiplayer_error = connected.reason
      self.multiplayer_status = "Multiplayer unavailable: " .. tostring(connected.reason)
      self.authoritative_adapter = nil
    end
  end

  self.local_player_index = self.local_player_index or 0

  if not self.authoritative_adapter then
    self:dispatch_command({ type = "START_TURN", player_index = 0 }) -- Player 1's turn starts immediately
    if not self.multiplayer_status then
      self.multiplayer_status = "Local mode"
    end
  end

  -- Init display_resources from actual values for all resource types
  for pi = 1, 2 do
    for _, key in ipairs(config.resource_types) do
      self.display_resources[pi][key] = self.game_state.players[pi].resources[key] or 0
    end
  end
  -- Init hand y_offsets for local player's starting hand
  for i = 1, #self.game_state.players[self.local_player_index + 1].hand do
    self.hand_y_offsets[i] = 0
  end
  return self
end


function GameState:panel_to_player(panel)
  return self.local_player_index == 0 and panel or (1 - panel)
end

function GameState:player_to_panel(pi)
  return self.local_player_index == 0 and pi or (1 - pi)
end

local PROMPT_DEFS = {
  play_unit = {
    alias_field = "pending_play_unit",
    cancel = { empty_click = true, escape = true },
    hand_card_click_method = "_handle_prompt_play_unit_hand_click",
    payload_normalize_method = "_normalize_prompt_play_unit_payload",
    payload_validate_method = "_validate_prompt_play_unit_payload",
    payload_schema = {
      { op = "required_source", field = "source" },
      { op = "required_ability_index", field = "ability_index" },
      { op = "optional_table", field = "effect_args" },
      { normalize = "index_list", op = "required_index_list", field = "eligible_indices" },
      { op = "optional_cost", field = "cost" },
      { op = "optional_bool", field = "fast" },
    },
    activated_start_method = "_start_activated_play_unit_prompt",
    activated_start_effects = { "play_unit" },
    board_draw = {
      eligible_hand_indices = { order = 1, field = "eligible_indices" },
    },
  },
  sacrifice = {
    alias_field = "pending_sacrifice",
    cancel = { empty_click = true, escape = true },
    worker_click_method = "_handle_prompt_sacrifice_worker_click",
    structure_click_method = "_handle_prompt_sacrifice_structure_click",
    payload_normalize_method = "_normalize_prompt_sacrifice_payload",
    payload_validate_method = "_validate_prompt_sacrifice_payload",
    payload_schema = {
      { op = "required_source", field = "source" },
      { op = "required_ability_index", field = "ability_index" },
      { op = "optional_table", field = "effect_args" },
      { normalize = "index_list", op = "required_index_list", field = "eligible_board_indices" },
      { op = "optional_string", field = "next" },
      { normalize = "index_list", op = "optional_index_list", field = "spell_eligible_indices" },
      { op = "optional_cost", field = "spell_cost" },
      { op = "optional_bool", field = "fast" },
      { op = "optional_bool", field = "allow_worker_tokens" },
    },
    activated_start_method = "_start_activated_sacrifice_produce_prompt",
    activated_start_effects = { "sacrifice_produce" },
    board_draw = {
      sacrifice_eligible_indices = { order = 1, field = "eligible_board_indices" },
    },
  },
  upgrade = {
    alias_field = "pending_upgrade",
    cancel = { empty_click = true, escape = true },
    payload_normalize_method = "_normalize_prompt_upgrade_payload",
    payload_validate_method = "_validate_prompt_upgrade_payload",
    payload_schema = {
      { op = "required_source", field = "source" },
      { op = "required_ability_index", field = "ability_index" },
      { op = "optional_table", field = "effect_args" },
      { normalize = "index_list", op = "optional_index_list", field = "eligible_hand_indices" },
      { normalize = "index_list", op = "optional_index_list", field = "eligible_board_indices" },
      { op = "optional_bool", field = "eligible_worker_sacrifice" },
      post_validate = "_post_validate_prompt_upgrade_payload",
    },
    activated_start_method = "_start_activated_sacrifice_upgrade_prompt",
    activated_start_effects = { "sacrifice_upgrade" },
    board_draw = {
      eligible_hand_indices = { order = 2, when = function(p) return p.stage == "hand" end, field = "eligible_hand_indices" },
      sacrifice_eligible_indices = { order = 2, when = function(p) return p.stage == "sacrifice" end, field = "eligible_board_indices" },
    },
  },
  hand_sacrifice = {
    alias_field = "pending_hand_sacrifice",
    cancel = { empty_click = true, escape = true },
    overlay = { order = 1, method = "_draw_pending_hand_sacrifice_overlay" },
    worker_click_method = "_handle_prompt_hand_sacrifice_worker_click",
    payload_validate_method = "_validate_prompt_hand_sacrifice_payload",
    payload_schema = {
      { op = "required_index", field = "hand_index" },
      { op = "required_count", field = "required_count" },
      post_validate = "_post_validate_prompt_hand_sacrifice_payload",
    },
    board_draw = {
      sacrifice_eligible_indices = { order = 3, value = function() return {} end },
    },
  },
  monument = {
    alias_field = "pending_monument",
    cancel = { empty_click = true, escape = true },
    overlay = { order = 2, method = "_draw_pending_monument_overlay" },
    structure_click_method = "_handle_prompt_monument_structure_click",
    payload_normalize_method = "_normalize_prompt_monument_payload",
    payload_validate_method = "_validate_prompt_monument_payload",
    payload_schema = {
      { op = "required_index", field = "hand_index" },
      { op = "required_count", field = "min_counters" },
      { normalize = "index_list", op = "required_index_list", field = "eligible_indices" },
    },
    board_draw = {
      monument_eligible_indices = { order = 1, field = "eligible_indices" },
    },
  },
  graveyard_return = {
    alias_field = "pending_graveyard_return",
    -- managed mostly via deck_viewer callbacks
    payload_normalize_method = "_normalize_prompt_graveyard_return_payload",
    payload_validate_method = "_validate_prompt_graveyard_return_payload",
    payload_schema = {
      { op = "required_source", field = "source" },
      { op = "required_ability_index", field = "ability_index" },
      { op = "required_count", field = "max_count" },
      { op = "optional_table", field = "effect_args" },
      { normalize = "index_list", op = "required_index_list", field = "selected_graveyard_indices" },
    },
    activated_start_method = "_start_activated_graveyard_return_prompt",
    activated_start_effects = { "return_from_graveyard" },
  },
  discard_draw = {
    alias_field = "pending_discard_draw",
    cancel = { empty_click = true, escape = true },
    overlay = { order = 5, method = "_draw_pending_discard_draw_overlay" },
    hand_card_click_method = "_handle_prompt_discard_draw_hand_click",
    payload_normalize_method = "_normalize_prompt_discard_draw_payload",
    payload_validate_method = "_validate_prompt_discard_draw_payload",
    payload_schema = {
      { op = "required_source", field = "source" },
      { op = "required_ability_index", field = "ability_index" },
      { op = "required_count", field = "required_count" },
      { op = "required_count", field = "draw_count" },
      { normalize = "int_keyed_set", op = "required_int_keyed_set", field = "selected_set" },
    },
    activated_start_method = "_start_activated_discard_draw_prompt",
    activated_start_effects = { "discard_draw" },
    board_draw = {
      discard_selected_set = { order = 1, field = "selected_set" },
    },
  },
  play_spell = {
    alias_field = "pending_play_spell",
    cancel = { empty_click = true },
    hand_card_click_method = "_handle_prompt_play_spell_hand_click",
    payload_normalize_method = "_normalize_prompt_play_spell_payload",
    payload_validate_method = "_validate_prompt_play_spell_payload",
    payload_schema = {
      { op = "required_source", field = "source" },
      { op = "required_ability_index", field = "ability_index" },
      { op = "optional_cost", field = "cost" },
      { op = "optional_table", field = "effect_args" },
      { normalize = "index_list", op = "required_index_list", field = "eligible_indices" },
      { op = "optional_bool", field = "fast" },
      { op = "optional_index", field = "sacrifice_target_board_index" },
    },
    activated_start_method = "_start_activated_play_spell_prompt",
    activated_start_effects = { "play_spell", "sacrifice_cast_spell" },
    board_draw = {
      eligible_hand_indices = { order = 3, field = "eligible_indices" },
    },
  },
  spell_target = {
    alias_field = "pending_spell_target",
    cancel = {
      empty_click = true,
      on_cancel = function(self)
        self.hand_selected_index = nil
      end,
    },
    overlay = { order = 4, method = "_draw_pending_spell_target_prompt" },
    structure_click_method = "_handle_prompt_spell_target_structure_click",
    payload_normalize_method = "_normalize_prompt_spell_target_payload",
    payload_validate_method = "_validate_prompt_spell_target_payload",
    payload_schema = {
      { op = "required_index", field = "hand_index" },
      { op = "optional_table", field = "effect_args" },
      { op = "optional_player_index", field = "eligible_player_index" },
      { normalize = "index_list", op = "required_index_list", field = "eligible_board_indices" },
      { op = "optional_index", field = "monument_board_index" },
      { op = "optional_index", field = "sacrifice_target_board_index" },
      { op = "optional_source_ref", field = "via_ability_source" },
      { op = "optional_index", field = "via_ability_ability_index" },
      { op = "optional_bool", field = "fast" },
    },
    board_draw = {
      damage_target_eligible_player_index = { order = 3, field = "eligible_player_index" },
      damage_target_eligible_indices = { order = 3, field = "eligible_board_indices" },
    },
  },
  damage_target = {
    alias_field = "pending_damage_target",
    cancel = { empty_click = true },
    structure_click_method = "_handle_prompt_damage_target_structure_click",
    payload_normalize_method = "_normalize_prompt_damage_target_payload",
    payload_validate_method = "_validate_prompt_damage_target_payload",
    payload_schema = {
      { op = "required_source", field = "source" },
      { op = "required_ability_index", field = "ability_index" },
      { op = "optional_table", field = "effect_args" },
      { op = "optional_bool", field = "fast" },
      { op = "optional_player_index", field = "eligible_player_index" },
      { normalize = "index_list", op = "optional_index_list", field = "eligible_board_indices" },
      { normalize = "player_indexed_index_lists", op = "optional_player_indexed_index_lists", field = "eligible_board_indices_by_player" },
      { normalize = "player_bool_set", op = "optional_player_bool_set", field = "eligible_base_player_indices" },
      post_validate = "_post_validate_prompt_damage_target_payload",
    },
    activated_start_method = "_start_activated_deal_damage_prompt",
    activated_start_effects = { "deal_damage" },
    board_draw = {
      damage_target_eligible_player_index = { order = 1, field = "eligible_player_index" },
      damage_target_eligible_indices = { order = 1, field = "eligible_board_indices" },
      damage_target_board_indices_by_player = { order = 1, field = "eligible_board_indices_by_player" },
      damage_target_base_player_indices = { order = 1, field = "eligible_base_player_indices" },
    },
  },
  damage_x = {
    alias_field = "pending_damage_x",
    cancel = { empty_click = true },
    overlay = { order = 3, method = "_draw_pending_damage_x_overlay" },
    structure_click_method = "_handle_prompt_damage_x_structure_click",
    pre_hit_test_click_method = "_handle_prompt_damage_x_pre_hit_test_click",
    payload_normalize_method = "_normalize_prompt_damage_x_payload",
    payload_validate_method = "_validate_prompt_damage_x_payload",
    payload_schema = {
      { op = "required_source", field = "source" },
      { op = "required_ability_index", field = "ability_index" },
      { op = "optional_table", field = "effect_args" },
      { op = "optional_bool", field = "fast" },
      { op = "optional_player_index", field = "eligible_player_index" },
      { normalize = "index_list", op = "optional_index_list", field = "eligible_board_indices" },
      { normalize = "player_indexed_index_lists", op = "optional_player_indexed_index_lists", field = "eligible_board_indices_by_player" },
      { normalize = "player_bool_set", op = "optional_player_bool_set", field = "eligible_base_player_indices" },
      { normalize = "nonnegative_int", op = "required_count", field = "x_amount" },
      { normalize = "nonnegative_int", op = "required_count", field = "max_x" },
      post_normalize = "_post_normalize_prompt_damage_x_payload",
      post_validate = "_post_validate_prompt_damage_x_payload",
    },
    activated_start_method = "_start_activated_damage_x_prompt",
    activated_start_effects = { "deal_damage_x" },
    board_draw = {
      damage_target_eligible_player_index = { order = 2, field = "eligible_player_index" },
      damage_target_eligible_indices = { order = 2, field = "eligible_board_indices" },
    },
  },
  counter_placement = {
    alias_field = "pending_counter_placement",
    cancel = { empty_click = true },
    structure_click_method = "_handle_prompt_counter_placement_structure_click",
    payload_normalize_method = "_normalize_prompt_counter_placement_payload",
    payload_validate_method = "_validate_prompt_counter_placement_payload",
    payload_schema = {
      { op = "required_source", field = "source" },
      { op = "required_ability_index", field = "ability_index" },
      { op = "optional_table", field = "effect_args" },
      { normalize = "index_list", op = "required_index_list", field = "eligible_board_indices" },
      { op = "optional_bool", field = "fast" },
    },
    activated_start_method = "_start_activated_counter_placement_prompt",
    activated_start_effects = { "place_counter_on_target" },
    board_draw = {
      counter_target_eligible_indices = { order = 1, field = "eligible_board_indices" },
    },
  },
}

local function is_prompt_method_name(value)
  return type(value) == "string" and value:match("^_[%a_][%w_]*$") ~= nil
end

validate_prompt_defs_static = function(prompt_defs)
  if type(prompt_defs) ~= "table" then
    error("PROMPT_DEFS must be a table")
  end
  local direct_method_keys = {
    "hand_card_click_method",
    "worker_click_method",
    "structure_click_method",
    "pre_hit_test_click_method",
    "payload_normalize_method",
    "payload_validate_method",
    "activated_start_method",
  }
  for kind, def in pairs(prompt_defs) do
    if type(kind) ~= "string" or kind == "" then
      error("invalid prompt kind in PROMPT_DEFS")
    end
    if type(def) ~= "table" then
      error("PROMPT_DEFS[" .. kind .. "] must be a table")
    end

    if def.alias_field ~= nil then
      if type(def.alias_field) ~= "string" or def.alias_field == "" then
        error("PROMPT_DEFS[" .. kind .. "].alias_field must be a non-empty string")
      end
      if not def.alias_field:match("^pending_[%w_]+$") then
        error("PROMPT_DEFS[" .. kind .. "].alias_field must look like pending_*")
      end
    end

    if def.cancel ~= nil then
      if type(def.cancel) ~= "table" then
        error("PROMPT_DEFS[" .. kind .. "].cancel must be a table")
      end
      if def.cancel.empty_click ~= nil and type(def.cancel.empty_click) ~= "boolean" then
        error("PROMPT_DEFS[" .. kind .. "].cancel.empty_click must be boolean")
      end
      if def.cancel.escape ~= nil and type(def.cancel.escape) ~= "boolean" then
        error("PROMPT_DEFS[" .. kind .. "].cancel.escape must be boolean")
      end
      if def.cancel.on_cancel ~= nil and type(def.cancel.on_cancel) ~= "function" then
        error("PROMPT_DEFS[" .. kind .. "].cancel.on_cancel must be a function")
      end
    end

    if def.overlay ~= nil then
      if type(def.overlay) ~= "table" then
        error("PROMPT_DEFS[" .. kind .. "].overlay must be a table")
      end
      if not is_prompt_method_name(def.overlay.method) then
        error("PROMPT_DEFS[" .. kind .. "].overlay.method must be a private method name string")
      end
      if def.overlay.order ~= nil and tonumber(def.overlay.order) == nil then
        error("PROMPT_DEFS[" .. kind .. "].overlay.order must be numeric")
      end
    end

    for _, key in ipairs(direct_method_keys) do
      local method_name = def[key]
      if method_name ~= nil and not is_prompt_method_name(method_name) then
        error("PROMPT_DEFS[" .. kind .. "]." .. key .. " must be a private method name string")
      end
    end

    local has_start_method = def.activated_start_method ~= nil
    local has_start_effects = def.activated_start_effects ~= nil
    if has_start_method ~= has_start_effects then
      error("PROMPT_DEFS[" .. kind .. "] activated_start_method/effects must be defined together")
    end
    if has_start_effects then
      if type(def.activated_start_effects) ~= "table" then
        error("PROMPT_DEFS[" .. kind .. "].activated_start_effects must be a table")
      end
      for i, effect in ipairs(def.activated_start_effects) do
        if type(effect) ~= "string" or effect == "" then
          error("PROMPT_DEFS[" .. kind .. "].activated_start_effects[" .. i .. "] must be a non-empty string")
        end
      end
    end

    if def.board_draw ~= nil then
      if type(def.board_draw) ~= "table" then
        error("PROMPT_DEFS[" .. kind .. "].board_draw must be a table")
      end
      for field_name, spec in pairs(def.board_draw) do
        if type(field_name) ~= "string" or field_name == "" then
          error("PROMPT_DEFS[" .. kind .. "].board_draw has invalid field name")
        end
        if type(spec) ~= "table" then
          error("PROMPT_DEFS[" .. kind .. "].board_draw[" .. field_name .. "] must be a table")
        end
        local has_field = spec.field ~= nil
        local has_value = spec.value ~= nil
        if not has_field and not has_value then
          error("PROMPT_DEFS[" .. kind .. "].board_draw[" .. field_name .. "] must define field or value")
        end
        if has_field and (type(spec.field) ~= "string" or spec.field == "") then
          error("PROMPT_DEFS[" .. kind .. "].board_draw[" .. field_name .. "].field must be a non-empty string")
        end
        if has_value and type(spec.value) ~= "function" then
          error("PROMPT_DEFS[" .. kind .. "].board_draw[" .. field_name .. "].value must be a function")
        end
        if spec.when ~= nil and type(spec.when) ~= "function" then
          error("PROMPT_DEFS[" .. kind .. "].board_draw[" .. field_name .. "].when must be a function")
        end
        if spec.order ~= nil and tonumber(spec.order) == nil then
          error("PROMPT_DEFS[" .. kind .. "].board_draw[" .. field_name .. "].order must be numeric")
        end
      end
    end
  end
end

validate_prompt_metadata_runtime = function(game_state_class)
  if type(game_state_class) ~= "table" then
    error("validate_prompt_metadata_runtime requires GameState table")
  end
  local missing = {}
  local function require_method(kind, key_name, method_name)
    if type(method_name) == "string" and type(game_state_class[method_name]) ~= "function" then
      missing[#missing + 1] = "PROMPT_DEFS[" .. kind .. "]." .. key_name .. " -> " .. method_name
    end
  end
  for kind, def in pairs(PROMPT_DEFS) do
    require_method(kind, "hand_card_click_method", def.hand_card_click_method)
    require_method(kind, "worker_click_method", def.worker_click_method)
    require_method(kind, "structure_click_method", def.structure_click_method)
    require_method(kind, "pre_hit_test_click_method", def.pre_hit_test_click_method)
    require_method(kind, "payload_normalize_method", def.payload_normalize_method)
    require_method(kind, "payload_validate_method", def.payload_validate_method)
    require_method(kind, "activated_start_method", def.activated_start_method)
    if type(def.overlay) == "table" then
      require_method(kind, "overlay.method", def.overlay.method)
    end
  end
  for kind, def in pairs(PROMPT_DEFS) do
    local schema = type(def) == "table" and def.payload_schema or nil
    if type(schema) == "table" then
      if type(schema.post_normalize) == "string" and type(game_state_class[schema.post_normalize]) ~= "function" then
        missing[#missing + 1] = "PROMPT_DEFS[" .. kind .. "].payload_schema.post_normalize -> " .. schema.post_normalize
      end
      if type(schema.post_validate) == "string" and type(game_state_class[schema.post_validate]) ~= "function" then
        missing[#missing + 1] = "PROMPT_DEFS[" .. kind .. "].payload_schema.post_validate -> " .. schema.post_validate
      end
    end
  end
  if #missing > 0 then
    table.sort(missing)
    error("missing prompt handler methods:\n  " .. table.concat(missing, "\n  "))
  end
end

local function build_prompt_alias_fields(prompt_defs)
  local out = {}
  local seen_fields = {}
  for kind, def in pairs(prompt_defs) do
    local field = type(def) == "table" and def.alias_field or nil
    if type(field) == "string" and field ~= "" then
      local prev_kind = seen_fields[field]
      if prev_kind and prev_kind ~= kind then
        error("duplicate prompt alias field mapping for field: " .. field)
      end
      seen_fields[field] = kind
      out[kind] = field
    end
  end
  return out
end

local function build_prompt_cancel_behavior(prompt_defs)
  local out = {}
  for kind, def in pairs(prompt_defs) do
    if type(def) == "table" and type(def.cancel) == "table" then
      out[kind] = def.cancel
    end
  end
  return out
end

local function build_prompt_overlay_tables(prompt_defs)
  local order_entries = {}
  local methods = {}
  for kind, def in pairs(prompt_defs) do
    local overlay = type(def) == "table" and def.overlay or nil
    if type(overlay) == "table" and type(overlay.method) == "string" then
      methods[kind] = overlay.method
      order_entries[#order_entries + 1] = {
        kind = kind,
        order = tonumber(overlay.order) or math.huge,
      }
    end
  end
  table.sort(order_entries, function(a, b)
    if a.order == b.order then
      return a.kind < b.kind
    end
    return a.order < b.order
  end)
  local order = {}
  for i, item in ipairs(order_entries) do
    order[i] = item.kind
  end
  return order, methods
end

local function build_prompt_click_method_map(prompt_defs, key_name)
  local out = {}
  for kind, def in pairs(prompt_defs) do
    local method_name = type(def) == "table" and def[key_name] or nil
    if type(method_name) == "string" then
      out[kind] = method_name
    end
  end
  return out
end

local function build_prompt_board_draw_field_specs(prompt_defs)
  local out = {}
  for kind, def in pairs(prompt_defs) do
    local board_draw = type(def) == "table" and def.board_draw or nil
    if type(board_draw) == "table" then
      for field_name, spec in pairs(board_draw) do
        if type(spec) == "table" then
          local list = out[field_name]
          if not list then
            list = {}
            out[field_name] = list
          end
          list[#list + 1] = {
            kind = kind,
            field = spec.field,
            when = spec.when,
            value = spec.value,
            order = tonumber(spec.order) or math.huge,
          }
        end
      end
    end
  end
  for _, list in pairs(out) do
    table.sort(list, function(a, b)
      if a.order == b.order then
        return a.kind < b.kind
      end
      return a.order < b.order
    end)
  end
  return out
end

local function build_activated_prompt_start_methods(prompt_defs)
  local out = {}
  for _, def in pairs(prompt_defs) do
    local method_name = type(def) == "table" and def.activated_start_method or nil
    local effects = type(def) == "table" and def.activated_start_effects or nil
    if type(method_name) == "string" and type(effects) == "table" then
      for _, effect in ipairs(effects) do
        if type(effect) == "string" then
          local prev = out[effect]
          if prev and prev ~= method_name then
            error("duplicate activated prompt start mapping for effect: " .. effect)
          end
          out[effect] = method_name
        end
      end
    end
  end
  return out
end

validate_prompt_defs_static(PROMPT_DEFS)
local PROMPT_ALIAS_FIELDS = build_prompt_alias_fields(PROMPT_DEFS)
local PROMPT_CANCEL_BEHAVIOR = build_prompt_cancel_behavior(PROMPT_DEFS)
local PROMPT_OVERLAY_DRAW_ORDER, PROMPT_OVERLAY_DRAW_METHODS = build_prompt_overlay_tables(PROMPT_DEFS)
local PROMPT_HAND_CARD_CLICK_METHODS = build_prompt_click_method_map(PROMPT_DEFS, "hand_card_click_method")
local PROMPT_WORKER_CLICK_METHODS = build_prompt_click_method_map(PROMPT_DEFS, "worker_click_method")
local PROMPT_STRUCTURE_CLICK_METHODS = build_prompt_click_method_map(PROMPT_DEFS, "structure_click_method")
local PROMPT_PRE_HIT_TEST_CLICK_METHODS = build_prompt_click_method_map(PROMPT_DEFS, "pre_hit_test_click_method")
local PROMPT_PAYLOAD_NORMALIZE_METHODS = build_prompt_click_method_map(PROMPT_DEFS, "payload_normalize_method")
local PROMPT_PAYLOAD_VALIDATE_METHODS = build_prompt_click_method_map(PROMPT_DEFS, "payload_validate_method")
local PROMPT_BOARD_DRAW_FIELD_SPECS = build_prompt_board_draw_field_specs(PROMPT_DEFS)
local ACTIVATED_PROMPT_START_METHODS = build_activated_prompt_start_methods(PROMPT_DEFS)

local function resolve_prompt_board_draw_field(self, field_specs)
  if type(field_specs) ~= "table" then return nil end
  for _, spec in ipairs(field_specs) do
    local payload = self:_prompt_payload(spec.kind)
    if payload ~= nil and (not spec.when or spec.when(payload)) then
      local value
      if type(spec.value) == "function" then
        value = spec.value(payload, self)
      elseif type(spec.field) == "string" then
        value = payload[spec.field]
      else
        value = payload
      end
      if value ~= nil then
        return value
      end
    end
  end
  return nil
end

function GameState:_prompt_stack_ensure()
  if type(self.prompt_stack) ~= "table" then
    self.prompt_stack = {}
  end
end

function GameState:_prompt_index(kind)
  self:_prompt_stack_ensure()
  for i = #self.prompt_stack, 1, -1 do
    local item = self.prompt_stack[i]
    if type(item) == "table" and item.kind == kind then
      return i, item
    end
  end
  return nil, nil
end

function GameState:_prompt_payload(kind)
  local _, item = self:_prompt_index(kind)
  return item and item.payload or nil
end

function GameState:_top_prompt()
  self:_prompt_stack_ensure()
  local item = self.prompt_stack[#self.prompt_stack]
  if type(item) ~= "table" then return nil, nil end
  if type(item.kind) ~= "string" or item.kind == "" then return nil, nil end
  return item.kind, item.payload
end

function GameState:_dispatch_prompt_click_from_top(method_map, ...)
  if type(method_map) ~= "table" then return false end
  local prompt_kind = self:_top_prompt()
  if type(prompt_kind) ~= "string" then return false end
  local method_name = method_map[prompt_kind]
  local method = method_name and self[method_name] or nil
  if type(method) ~= "function" then return false end
  return method(self, ...)
end

local function prompt_validate_error(msg)
  return false, msg
end

local function is_integer_number(value)
  return type(value) == "number" and value == math.floor(value)
end

local function is_positive_index(value)
  return is_integer_number(value) and value >= 1
end

local function is_nonnegative_integer(value)
  return is_integer_number(value) and value >= 0
end

local function is_bool(value)
  return type(value) == "boolean"
end

local function is_array_of_positive_indices(value)
  if type(value) ~= "table" then return false end
  for i, v in ipairs(value) do
    if not is_positive_index(v) then
      return false, "entry " .. tostring(i) .. " must be a positive integer index"
    end
  end
  return true
end

local function is_cost_list(value)
  if value == nil then return true end
  if type(value) ~= "table" then return false, "cost must be a table" end
  for i, c in ipairs(value) do
    if type(c) ~= "table" then
      return false, "cost[" .. tostring(i) .. "] must be a table"
    end
    if type(c.type) ~= "string" or c.type == "" then
      return false, "cost[" .. tostring(i) .. "].type must be a non-empty string"
    end
    if not is_nonnegative_integer(c.amount or 0) then
      return false, "cost[" .. tostring(i) .. "].amount must be a non-negative integer"
    end
  end
  return true
end

local function is_source_ref(value)
  if type(value) ~= "table" then return false, "source must be a table" end
  if value.type ~= "base" and value.type ~= "board" then
    return false, "source.type must be 'base' or 'board'"
  end
  if value.type == "board" and not is_positive_index(value.index) then
    return false, "source.index must be a positive integer for board sources"
  end
  if value.type == "base" and value.index ~= nil and not is_positive_index(value.index) then
    return false, "source.index must be nil or a positive integer for base sources"
  end
  return true
end

local function is_int_keyed_set(value)
  if type(value) ~= "table" then return false, "must be a table" end
  for k, v in pairs(value) do
    if not is_positive_index(k) then
      return false, "set key must be a positive integer index"
    end
    if v ~= nil and not is_bool(v) and v ~= 0 and v ~= 1 then
      return false, "set values must be boolean-like"
    end
  end
  return true
end

local function is_player_bool_set(value)
  if type(value) ~= "table" then return false, "must be a table" end
  for k, v in pairs(value) do
    if k ~= 0 and k ~= 1 then
      return false, "player set keys must be 0 or 1"
    end
    if v ~= nil and not is_bool(v) and v ~= 0 and v ~= 1 then
      return false, "player set values must be boolean-like"
    end
  end
  return true
end

local function is_player_indexed_index_lists(value)
  if type(value) ~= "table" then return false, "must be a table" end
  for k, list in pairs(value) do
    if k ~= 0 and k ~= 1 then
      return false, "player map keys must be 0 or 1"
    end
    local ok, err = is_array_of_positive_indices(list)
    if not ok then
      return false, "player " .. tostring(k) .. " list invalid: " .. tostring(err)
    end
  end
  return true
end

local function validate_prompt_payload_table(payload)
  if type(payload) ~= "table" then
    return prompt_validate_error("payload must be a table")
  end
  return true
end

local function validate_required_index(payload, field_name)
  if not is_positive_index(payload[field_name]) then
    return prompt_validate_error(field_name .. " must be a positive integer index")
  end
  return true
end

local function validate_required_count(payload, field_name)
  if not is_nonnegative_integer(payload[field_name]) then
    return prompt_validate_error(field_name .. " must be a non-negative integer")
  end
  return true
end

local function validate_optional_bool(payload, field_name)
  local v = payload[field_name]
  if v ~= nil and not is_bool(v) then
    return prompt_validate_error(field_name .. " must be a boolean")
  end
  return true
end

local function validate_optional_string(payload, field_name)
  local v = payload[field_name]
  if v ~= nil and (type(v) ~= "string" or v == "") then
    return prompt_validate_error(field_name .. " must be a non-empty string")
  end
  return true
end

local function validate_optional_table(payload, field_name)
  local v = payload[field_name]
  if v ~= nil and type(v) ~= "table" then
    return prompt_validate_error(field_name .. " must be a table")
  end
  return true
end

local function validate_optional_index(payload, field_name)
  local v = payload[field_name]
  if v ~= nil and not is_positive_index(v) then
    return prompt_validate_error(field_name .. " must be a positive integer index")
  end
  return true
end

local function validate_optional_index_list(payload, field_name)
  local v = payload[field_name]
  if v ~= nil then
    local ok, err = is_array_of_positive_indices(v)
    if not ok then
      return prompt_validate_error(field_name .. " must be an index list (" .. tostring(err) .. ")")
    end
  end
  return true
end

local function validate_required_index_list(payload, field_name)
  local v = payload[field_name]
  local ok, err = is_array_of_positive_indices(v)
  if not ok then
    return prompt_validate_error(field_name .. " must be an index list (" .. tostring(err) .. ")")
  end
  return true
end

local function validate_required_source(payload)
  local ok, err = is_source_ref(payload.source)
  if not ok then
    return prompt_validate_error(err)
  end
  return true
end

local function validate_required_ability_index(payload)
  return validate_required_index(payload, "ability_index")
end

local function validate_optional_cost(payload, field_name)
  local ok, err = is_cost_list(payload[field_name])
  if not ok then
    return prompt_validate_error(err)
  end
  return true
end

local function validate_optional_player_index(payload, field_name)
  local v = payload[field_name]
  if v ~= nil and v ~= 0 and v ~= 1 then
    return prompt_validate_error(field_name .. " must be 0 or 1")
  end
  return true
end

local function validate_optional_source_ref(payload, field_name)
  local v = payload[field_name]
  if v ~= nil then
    local ok, err = is_source_ref(v)
    if not ok then
      return prompt_validate_error(field_name .. " invalid (" .. tostring(err) .. ")")
    end
  end
  return true
end

local function validate_optional_player_indexed_index_lists(payload, field_name)
  local v = payload[field_name]
  if v ~= nil then
    local ok, err = is_player_indexed_index_lists(v)
    if not ok then
      return prompt_validate_error(field_name .. " invalid (" .. tostring(err) .. ")")
    end
  end
  return true
end

local function validate_optional_player_bool_set(payload, field_name)
  local v = payload[field_name]
  if v ~= nil then
    local ok, err = is_player_bool_set(v)
    if not ok then
      return prompt_validate_error(field_name .. " invalid (" .. tostring(err) .. ")")
    end
  end
  return true
end

local function validate_required_int_keyed_set(payload, field_name)
  local set_ok, set_err = is_int_keyed_set(payload[field_name])
  if not set_ok then
    return prompt_validate_error(field_name .. " invalid (" .. tostring(set_err) .. ")")
  end
  return true
end

local function normalize_unique_sorted_positive_indices_in_place(list)
  if type(list) ~= "table" then return list end
  local seen = {}
  local out = {}
  for _, v in ipairs(list) do
    if is_positive_index(v) and not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  table.sort(out)
  for i = #list, 1, -1 do
    list[i] = nil
  end
  for i, v in ipairs(out) do
    list[i] = v
  end
  return list
end

local function normalize_index_list_field(payload, field_name)
  if type(payload) ~= "table" then return payload end
  if payload[field_name] ~= nil then
    normalize_unique_sorted_positive_indices_in_place(payload[field_name])
  end
  return payload
end

local function normalize_player_index_list_map_field(payload, field_name)
  if type(payload) ~= "table" then return payload end
  local map = payload[field_name]
  if type(map) ~= "table" then return payload end
  for _, list in pairs(map) do
    if type(list) == "table" then
      normalize_unique_sorted_positive_indices_in_place(list)
    end
  end
  return payload
end

local function normalize_player_bool_set_field(payload, field_name)
  if type(payload) ~= "table" then return payload end
  local set = payload[field_name]
  if type(set) ~= "table" then return payload end
  local normalized = {}
  for k, v in pairs(set) do
    if (k == 0 or k == 1) and (v == true or v == 1) then
      normalized[k] = true
    end
  end
  payload[field_name] = normalized
  return payload
end

local function normalize_int_keyed_set_field(payload, field_name)
  if type(payload) ~= "table" then return payload end
  local set = payload[field_name]
  if type(set) ~= "table" then return payload end
  local normalized = {}
  for k, v in pairs(set) do
    if is_positive_index(k) and (v == true or v == 1) then
      normalized[k] = true
    end
  end
  payload[field_name] = normalized
  return payload
end

local function clamp_nonnegative_integer_field(payload, field_name)
  if type(payload) ~= "table" then return payload end
  local v = payload[field_name]
  if type(v) ~= "number" then return payload end
  if v < 0 then
    payload[field_name] = 0
    return payload
  end
  payload[field_name] = math.floor(v)
  return payload
end

local function clamp_min_max_fields(payload, min_field, max_field)
  if type(payload) ~= "table" then return payload end
  local min_v = payload[min_field]
  local max_v = payload[max_field]
  if type(min_v) == "number" and type(max_v) == "number" then
    if min_v > max_v then
      payload[min_field] = max_v
    end
  end
  return payload
end

local PROMPT_PAYLOAD_FIELD_NORMALIZE_OPS = {
  index_list = normalize_index_list_field,
  player_indexed_index_lists = normalize_player_index_list_map_field,
  player_bool_set = normalize_player_bool_set_field,
  int_keyed_set = normalize_int_keyed_set_field,
  nonnegative_int = clamp_nonnegative_integer_field,
}

local PROMPT_PAYLOAD_FIELD_VALIDATE_OPS = {
  required_index = validate_required_index,
  required_count = validate_required_count,
  required_index_list = validate_required_index_list,
  required_source = function(payload, _field_name)
    return validate_required_source(payload)
  end,
  required_ability_index = function(payload, _field_name)
    return validate_required_ability_index(payload)
  end,
  required_int_keyed_set = validate_required_int_keyed_set,
  optional_index = validate_optional_index,
  optional_bool = validate_optional_bool,
  optional_string = validate_optional_string,
  optional_table = validate_optional_table,
  optional_index_list = validate_optional_index_list,
  optional_cost = validate_optional_cost,
  optional_player_index = validate_optional_player_index,
  optional_source_ref = validate_optional_source_ref,
  optional_player_indexed_index_lists = validate_optional_player_indexed_index_lists,
  optional_player_bool_set = validate_optional_player_bool_set,
}

local function validate_prompt_payload_field_schemas_static(prompt_defs, schemas, normalize_ops, validate_ops)
  if type(prompt_defs) ~= "table" then
    error("PROMPT_DEFS must be a table for schema validation")
  end
  if type(schemas) ~= "table" then
    error("PROMPT_PAYLOAD_FIELD_SCHEMAS must be a table")
  end
  if type(normalize_ops) ~= "table" then
    error("PROMPT_PAYLOAD_FIELD_NORMALIZE_OPS must be a table")
  end
  if type(validate_ops) ~= "table" then
    error("PROMPT_PAYLOAD_FIELD_VALIDATE_OPS must be a table")
  end

  for kind, schema in pairs(schemas) do
    if type(kind) ~= "string" or kind == "" then
      error("PROMPT_PAYLOAD_FIELD_SCHEMAS has invalid prompt kind key")
    end
    if type(prompt_defs[kind]) ~= "table" then
      error("PROMPT_PAYLOAD_FIELD_SCHEMAS[" .. kind .. "] has no matching PROMPT_DEFS entry")
    end
    if type(schema) ~= "table" then
      error("PROMPT_PAYLOAD_FIELD_SCHEMAS[" .. kind .. "] must be a table")
    end

    local seq_count = 0
    for i, spec in ipairs(schema) do
      seq_count = i
      if type(spec) ~= "table" then
        error("PROMPT_PAYLOAD_FIELD_SCHEMAS[" .. kind .. "][" .. i .. "] must be a table")
      end
      if type(spec.field) ~= "string" or spec.field == "" then
        error("PROMPT_PAYLOAD_FIELD_SCHEMAS[" .. kind .. "][" .. i .. "].field must be a non-empty string")
      end
      if type(spec.op) ~= "string" or spec.op == "" then
        error("PROMPT_PAYLOAD_FIELD_SCHEMAS[" .. kind .. "][" .. i .. "].op must be a non-empty string")
      end
      if type(validate_ops[spec.op]) ~= "function" then
        error("PROMPT_PAYLOAD_FIELD_SCHEMAS[" .. kind .. "][" .. i .. "] unknown validate op: " .. tostring(spec.op))
      end
      if spec.normalize ~= nil then
        if type(spec.normalize) ~= "string" or spec.normalize == "" then
          error("PROMPT_PAYLOAD_FIELD_SCHEMAS[" .. kind .. "][" .. i .. "].normalize must be a non-empty string")
        end
        if type(normalize_ops[spec.normalize]) ~= "function" then
          error("PROMPT_PAYLOAD_FIELD_SCHEMAS[" .. kind .. "][" .. i .. "] unknown normalize op: " .. tostring(spec.normalize))
        end
      end
      for key, _ in pairs(spec) do
        if key ~= "field" and key ~= "op" and key ~= "normalize" then
          error("PROMPT_PAYLOAD_FIELD_SCHEMAS[" .. kind .. "][" .. i .. "] has unsupported key: " .. tostring(key))
        end
      end
    end

    if schema.post_normalize ~= nil then
      if not is_prompt_method_name(schema.post_normalize) then
        error("PROMPT_PAYLOAD_FIELD_SCHEMAS[" .. kind .. "].post_normalize must be a private method name string")
      end
    end
    if schema.post_validate ~= nil then
      if not is_prompt_method_name(schema.post_validate) then
        error("PROMPT_PAYLOAD_FIELD_SCHEMAS[" .. kind .. "].post_validate must be a private method name string")
      end
    end

    for key, _ in pairs(schema) do
      if key ~= "post_normalize" and key ~= "post_validate" then
        if type(key) ~= "number" or key < 1 or key > seq_count or key ~= math.floor(key) then
          error("PROMPT_PAYLOAD_FIELD_SCHEMAS[" .. kind .. "] must be a dense array")
        end
      end
    end
  end
end

local function build_prompt_payload_field_schemas(prompt_defs)
  local out = {}
  if type(prompt_defs) ~= "table" then return out end
  for kind, def in pairs(prompt_defs) do
    local schema = type(def) == "table" and def.payload_schema or nil
    if type(schema) == "table" then
      out[kind] = schema
    end
  end
  return out
end

local function normalize_prompt_payload_by_schema(payload, schema, self)
  if type(payload) ~= "table" or type(schema) ~= "table" then return payload end
  for _, spec in ipairs(schema) do
    if type(spec) == "table" and type(spec.normalize) == "string" and type(spec.field) == "string" then
      local fn = PROMPT_PAYLOAD_FIELD_NORMALIZE_OPS[spec.normalize]
      if fn then
        fn(payload, spec.field)
      end
    end
  end
  if type(self) == "table" and type(schema.post_normalize) == "string" then
    local hook = self[schema.post_normalize]
    if type(hook) == "function" then
      local out_payload, out_err = hook(self, payload, schema)
      if out_payload ~= nil then
        payload = out_payload
      elseif out_err ~= nil then
        return nil, out_err
      end
    end
  end
  return payload
end

local function validate_prompt_payload_by_schema(payload, schema, self)
  local ok, err = validate_prompt_payload_table(payload)
  if not ok then return ok, err end
  if type(schema) ~= "table" then return true end
  for _, spec in ipairs(schema) do
    if type(spec) == "table" and type(spec.op) == "string" then
      local fn = PROMPT_PAYLOAD_FIELD_VALIDATE_OPS[spec.op]
      if type(fn) ~= "function" then
        return prompt_validate_error("unknown payload field validation op: " .. spec.op)
      end
      ok, err = fn(payload, spec.field)
      if not ok then return ok, err end
    end
  end
  if type(self) == "table" and type(schema.post_validate) == "string" then
    local hook = self[schema.post_validate]
    if type(hook) == "function" then
      ok, err = hook(self, payload, schema)
      if not ok then return ok, err end
    end
  end
  return true
end

PROMPT_PAYLOAD_FIELD_SCHEMAS = build_prompt_payload_field_schemas(PROMPT_DEFS)
validate_prompt_payload_field_schemas_static(
  PROMPT_DEFS,
  PROMPT_PAYLOAD_FIELD_SCHEMAS,
  PROMPT_PAYLOAD_FIELD_NORMALIZE_OPS,
  PROMPT_PAYLOAD_FIELD_VALIDATE_OPS
)

local PROMPT_PAYLOAD_SCHEMA_CUSTOM_NORMALIZE_KINDS = {}

local PROMPT_PAYLOAD_SCHEMA_CUSTOM_VALIDATE_KINDS = {}

local function install_schema_prompt_payload_methods(game_state_class, prompt_defs, schemas)
  if type(game_state_class) ~= "table" or type(prompt_defs) ~= "table" or type(schemas) ~= "table" then
    return
  end
  for kind, def in pairs(prompt_defs) do
    local schema = (type(def) == "table" and def.payload_schema) or schemas[kind]
    if type(def) == "table" and type(schema) == "table" then
      local normalize_method_name = def.payload_normalize_method
      if type(normalize_method_name) == "string" and not PROMPT_PAYLOAD_SCHEMA_CUSTOM_NORMALIZE_KINDS[kind] then
        if type(game_state_class[normalize_method_name]) ~= "function" then
          local schema_ref = schema
          game_state_class[normalize_method_name] = function(state_self, prompt_payload)
            return normalize_prompt_payload_by_schema(prompt_payload, schema_ref, state_self)
          end
        end
      end

      local validate_method_name = def.payload_validate_method
      if type(validate_method_name) == "string" and not PROMPT_PAYLOAD_SCHEMA_CUSTOM_VALIDATE_KINDS[kind] then
        if type(game_state_class[validate_method_name]) ~= "function" then
          local schema_ref = schema
          game_state_class[validate_method_name] = function(state_self, prompt_payload)
            return validate_prompt_payload_by_schema(prompt_payload, schema_ref, state_self)
          end
        end
      end
    end
  end
end

install_schema_prompt_payload_methods(GameState, PROMPT_DEFS, PROMPT_PAYLOAD_FIELD_SCHEMAS)

function GameState:_post_normalize_prompt_damage_x_payload(payload)
  clamp_min_max_fields(payload, "x_amount", "max_x")
  return payload
end

function GameState:_post_validate_prompt_upgrade_payload(payload)
  if payload.stage ~= "sacrifice" and payload.stage ~= "hand" then
    return prompt_validate_error("stage must be 'sacrifice' or 'hand'")
  end
  if payload.sacrifice_target ~= nil and type(payload.sacrifice_target) ~= "table" then
    return prompt_validate_error("sacrifice_target must be a table when present")
  end
  return true
end

function GameState:_post_validate_prompt_hand_sacrifice_payload(payload)
  if type(payload.selected_targets) ~= "table" then
    return prompt_validate_error("selected_targets must be a table")
  end
  for i, target in ipairs(payload.selected_targets) do
    if type(target) ~= "table" then
      return prompt_validate_error("selected_targets[" .. tostring(i) .. "] must be a table")
    end
    if target.kind ~= "worker_left" and target.kind ~= "worker_right" then
      return prompt_validate_error("selected_targets[" .. tostring(i) .. "].kind must be worker_left/worker_right")
    end
    if not is_positive_index(target.extra) then
      return prompt_validate_error("selected_targets[" .. tostring(i) .. "].extra must be a positive integer index")
    end
  end
  return true
end

function GameState:_post_validate_prompt_damage_target_payload(payload)
  local has_single = payload.eligible_player_index ~= nil and type(payload.eligible_board_indices) == "table"
  local has_global = payload.eligible_board_indices_by_player ~= nil or payload.eligible_base_player_indices ~= nil
  if not has_single and not has_global then
    return prompt_validate_error("payload must define either single-target or global target eligibility fields")
  end
  return true
end

function GameState:_post_validate_prompt_damage_x_payload(payload)
  local ok, err = self:_post_validate_prompt_damage_target_payload(payload)
  if not ok then return ok, err end
  if payload.x_amount > payload.max_x then
    return prompt_validate_error("x_amount cannot exceed max_x")
  end
  return true
end

function GameState:_sync_prompt_aliases()
  for kind, field in pairs(PROMPT_ALIAS_FIELDS) do
    self[field] = self:_prompt_payload(kind)
  end
end

function GameState:_set_prompt(kind, payload)
  if type(kind) ~= "string" or kind == "" then return nil end
  local normalizer_name = PROMPT_PAYLOAD_NORMALIZE_METHODS[kind]
  if type(normalizer_name) == "string" then
    local normalizer = self[normalizer_name]
    if type(normalizer) == "function" then
      local normalized_payload, norm_err = normalizer(self, payload)
      if normalized_payload ~= nil then
        payload = normalized_payload
      elseif norm_err ~= nil then
        error("failed to normalize prompt payload for '" .. kind .. "': " .. tostring(norm_err))
      end
    end
  end
  local validator_name = PROMPT_PAYLOAD_VALIDATE_METHODS[kind]
  if type(validator_name) == "string" then
    local validator = self[validator_name]
    if type(validator) == "function" then
      local ok, err = validator(self, payload)
      if not ok then
        error("invalid prompt payload for '" .. kind .. "': " .. tostring(err or "validation failed"))
      end
    end
  end
  self:_prompt_stack_ensure()
  for i = #self.prompt_stack, 1, -1 do
    local item = self.prompt_stack[i]
    if type(item) == "table" and item.kind == kind then
      table.remove(self.prompt_stack, i)
    end
  end
  self.prompt_stack[#self.prompt_stack + 1] = {
    kind = kind,
    payload = payload,
  }
  self:_sync_prompt_aliases()
  return payload
end

function GameState:_clear_prompt(kind)
  if type(kind) ~= "string" or kind == "" then return end
  self:_prompt_stack_ensure()
  local changed = false
  for i = #self.prompt_stack, 1, -1 do
    local item = self.prompt_stack[i]
    if type(item) == "table" and item.kind == kind then
      table.remove(self.prompt_stack, i)
      changed = true
    end
  end
  if changed then
    self:_sync_prompt_aliases()
  end
end

function GameState:_clear_prompt_stack()
  self.prompt_stack = {}
  self:_sync_prompt_aliases()
end

function GameState:_cancel_prompt(kind, reason)
  if type(kind) ~= "string" or kind == "" then return false end
  local payload = self:_prompt_payload(kind)
  if payload == nil then return false end
  local behavior = PROMPT_CANCEL_BEHAVIOR[kind]
  self:_clear_prompt(kind)
  if behavior and type(behavior.on_cancel) == "function" then
    behavior.on_cancel(self, payload, reason)
  end
  return true
end

function GameState:_cancel_top_prompt_for_context(context)
  if type(context) ~= "string" or context == "" then return nil end
  self:_prompt_stack_ensure()
  for i = #self.prompt_stack, 1, -1 do
    local item = self.prompt_stack[i]
    local kind = type(item) == "table" and item.kind or nil
    if type(kind) == "string" then
      local behavior = PROMPT_CANCEL_BEHAVIOR[kind]
      if behavior and behavior[context] == true then
        if self:_cancel_prompt(kind, context) then
          return kind
        end
      end
    end
  end
  return nil
end

function GameState:_draw_prompt_overlays()
  for _, kind in ipairs(PROMPT_OVERLAY_DRAW_ORDER) do
    if self:_prompt_payload(kind) ~= nil then
      local method_name = PROMPT_OVERLAY_DRAW_METHODS[kind]
      local method = method_name and self[method_name] or nil
      if type(method) == "function" then
        method(self)
      end
    end
  end
end

function GameState:_build_prompt_board_draw_fields()
  local upgrade = self:_prompt_payload("upgrade")
  local pending_upgrade_sacrifice = (upgrade and upgrade.stage == "sacrifice") and upgrade or nil

  local sacrifice = self:_prompt_payload("sacrifice")
  local hand_sacrifice = self:_prompt_payload("hand_sacrifice")

  local sacrifice_allow_workers = nil
  if sacrifice or hand_sacrifice then
    sacrifice_allow_workers = true
  elseif pending_upgrade_sacrifice then
    sacrifice_allow_workers = pending_upgrade_sacrifice.eligible_worker_sacrifice == true
  end

  local fields = {
    sacrifice_allow_workers = sacrifice_allow_workers,
  }
  for field_name, field_specs in pairs(PROMPT_BOARD_DRAW_FIELD_SPECS) do
    fields[field_name] = resolve_prompt_board_draw_field(self, field_specs)
  end
  return fields
end

local function should_trigger_reconnect(reason)
  if type(reason) ~= "string" then
    return false
  end

  if reason == "not_connected"
    or reason == "missing_transport"
    or reason == "transport_send_failed"
    or reason == "transport_receive_failed"
    or reason == "transport_decode_failed"
    or reason == "transport_encode_failed"
    or reason == "transport_error"
    or reason == "transport_timeout"
    or reason == "transport_no_protocol_response"
    or reason == "thread_stopped"
  then
    return true
  end

  local lowered = string.lower(reason)
  if lowered:find("transport_", 1, true) then return true end
  if lowered:find("receive_error", 1, true) then return true end
  if lowered:find("connection lost", 1, true) then return true end
  if lowered:find("ws_connect_failed", 1, true) then return true end
  if lowered:find("thread error", 1, true) then return true end
  return false
end

function GameState:_queue_reconnect(reason)
  if not self.authoritative_adapter then return end
  if self.reconnect_pending then return end
  local cause = tostring(reason or "unknown")
  self.reconnect_pending = true
  self.reconnect_attempts = 0
  self.reconnect_timer = 0
  self.reconnect_reason = cause
  self.multiplayer_error = cause
  self.multiplayer_status = "Reconnecting...\nCause: " .. cause
end

function GameState:_attempt_reconnect()
  if not self.authoritative_adapter then return false end
  if self.authoritative_adapter.connected then
    local remote_state = self.authoritative_adapter:get_state()
    if remote_state then
      self.game_state = remote_state
    end
    self.reconnect_pending = false
    self.reconnect_attempts = 0
    self.reconnect_timer = 0
    self.reconnect_reason = nil
    self.multiplayer_error = nil
    self.multiplayer_status = "Connected"
    return true
  end

  local ok_reconnect, reconnected = pcall(function()
    return self.authoritative_adapter:reconnect()
  end)
  if not ok_reconnect then
    reconnected = { ok = false, reason = tostring(reconnected), meta = {} }
  end

  if reconnected.ok then
    if reconnected.meta and reconnected.meta.pending then
      self.reconnect_timer = 0.25
      local cause = tostring(self.reconnect_reason or self.multiplayer_error or "unknown")
      self.multiplayer_status = "Reconnecting...\nCause: " .. cause
      return false
    end

    local remote_state = self.authoritative_adapter:get_state()
    if remote_state then
      self.game_state = remote_state
    end
    self.reconnect_pending = false
    self.reconnect_attempts = 0
    self.reconnect_timer = 0
    self.reconnect_reason = nil
    self.multiplayer_error = nil
    self.multiplayer_status = "Connected"
    return true
  end

  self.reconnect_attempts = self.reconnect_attempts + 1
  local wait = math.min(6, 0.5 * (2 ^ math.min(self.reconnect_attempts, 4)))
  self.reconnect_timer = wait
  self.multiplayer_error = tostring(reconnected.reason or "unknown")
  local cause = tostring(self.reconnect_reason or self.multiplayer_error or "unknown")
  self.multiplayer_status = "Reconnect failed (retrying): " .. self.multiplayer_error
  if cause ~= self.multiplayer_error then
    self.multiplayer_status = self.multiplayer_status .. "\nCause: " .. cause
  end
  return false
end

function GameState:_handle_disconnect(message)
  print("[game] disconnect: " .. tostring(message))
  -- Clean up server if hosting
  if self.server_cleanup then
    pcall(self.server_cleanup)
    self.server_step = nil
    self.server_cleanup = nil
  end
  -- Clean up adapter
  if self.authoritative_adapter and self.authoritative_adapter.cleanup then
    pcall(function() self.authoritative_adapter:cleanup() end)
  end
  self.authoritative_adapter = nil
  self.reconnect_pending = false
  self.reconnect_reason = nil
  self:_clear_prompt_stack()
  -- Show popup and return to menu after a moment
  self._disconnect_message = message
  self._disconnect_timer = 3.0
end

local function terminal_title_for_player(g, local_player_index)
  if not g or not g.is_terminal then
    return nil
  end
  if g.winner == nil then
    return "Draw"
  end
  if g.winner == local_player_index then
    return "Victory"
  end
  return "Defeat"
end

local function graveyard_cards_for_player(player)
  local out = {}
  if not player or type(player.graveyard) ~= "table" then
    return out
  end

  -- Show newest cards first.
  for i = #player.graveyard, 1, -1 do
    local entry = player.graveyard[i]
    local card_id = (type(entry) == "table") and entry.card_id or entry
    if type(card_id) == "string" and card_id ~= "" then
      local ok_def, def = pcall(cards.get_card_def, card_id)
      if ok_def and def then
        out[#out + 1] = def
      end
    end
  end

  return out
end

-- Build the graveyard card list for selection mode (newest-first, includes graveyard_index metadata).
-- Only includes cards matching the return_from_graveyard effect_args filter.
local function graveyard_cards_for_selection(player, effect_args)
  local args = effect_args or {}
  local req_tier = args.tier
  local req_subtypes = args.subtypes
  local out = {}
  if not player or type(player.graveyard) ~= "table" then return out end

  for i = #player.graveyard, 1, -1 do
    local entry = player.graveyard[i]
    local card_id = (type(entry) == "table") and entry.card_id or entry
    if type(card_id) == "string" and card_id ~= "" then
      local ok_def, def = pcall(cards.get_card_def, card_id)
      if ok_def and def then
        local eligible = true
        if req_tier ~= nil and (def.tier or 0) ~= req_tier then eligible = false end
        if eligible and args.target == "unit" and def.kind ~= "Unit" and def.kind ~= "Worker" then eligible = false end
        if eligible and req_subtypes and #req_subtypes > 0 then
          if not def.subtypes then
            eligible = false
          else
            local found = false
            for _, req in ipairs(req_subtypes) do
              for _, got in ipairs(def.subtypes) do
                if req == got then found = true; break end
              end
              if found then break end
            end
            if not found then eligible = false end
          end
        end
        -- Shallow-copy the def and attach graveyard_index so on_click can identify it
        local entry_def = {}
        for k, v in pairs(def) do entry_def[k] = v end
        entry_def.graveyard_index = i
        entry_def.graveyard_eligible = eligible
        out[#out + 1] = entry_def
      end
    end
  end
  return out
end

function GameState:open_graveyard_view(player_index)
  local player = self.game_state.players[player_index + 1]
  if not player then
    return
  end

  local faction_info = factions_data[player.faction]
  local accent = faction_info and faction_info.color or { 0.5, 0.5, 0.7 }
  local is_local = player_index == self.local_player_index

  deck_viewer.open({
    title = is_local and "Your Graveyard" or "Opponent Graveyard",
    hint = "Newest first",
    cards = graveyard_cards_for_player(player),
    accent = accent,
    filters = { "All", "Unit", "Worker", "Structure", "Spell", "Technology", "Item", "Artifact" },
    filter_fn = function(def, filter_name)
      return def.kind == filter_name
    end,
  })
  self.show_blueprint_for_player = nil
end

function GameState:_sync_terminal_state()
  local g = self.game_state
  local is_terminal = g and g.is_terminal == true
  if not is_terminal then
    self._terminal_announced = false
    return
  end

  if self._terminal_announced then
    return
  end
  self._terminal_announced = true

  -- Clear mutable UI state when match ends.
  self.drag = nil
  self.hand_selected_index = nil
  self:_clear_prompt("play_unit")
  self:_clear_prompt("sacrifice")
  self:_clear_prompt("upgrade")
  self:_clear_prompt("hand_sacrifice")
  self:_clear_prompt("monument")
  self:_clear_prompt("graveyard_return")
  self:_clear_prompt("counter_placement")
  self:_clear_prompt("damage_target")
  self:_clear_prompt("damage_x")
  self:_clear_prompt("spell_target")
  self:_clear_prompt("play_spell")
  self:_clear_prompt("discard_draw")
  self:_clear_prompt_stack()
  self:_clear_pending_attack_declarations()
  self.pending_attack_trigger_targets = {}
  self.pending_block_assignments = {}
  self.pending_damage_orders = {}

  self.turn_banner_timer = 1.6
  self.turn_banner_text = terminal_title_for_player(g, self.local_player_index) or "Match Ended"
  self.multiplayer_status = "Match ended"
end

function GameState:dispatch_command(command)
  -- Don't process commands during disconnect
  if self._disconnect_timer then return { ok = false, reason = "disconnected" } end
  if self.game_state and self.game_state.is_terminal then return { ok = false, reason = "game_over" } end

  local result

  if self.authoritative_adapter then
    local ok_submit, submit_result = pcall(function() return self.authoritative_adapter:submit(command) end)
    if not ok_submit then
      local submit_reason = tostring(submit_result)
      if should_trigger_reconnect(submit_reason) then
        self:_queue_reconnect(submit_reason)
        return { ok = false, reason = submit_reason, meta = {} }
      end
      self:_handle_disconnect("Connection lost: " .. submit_reason)
      return { ok = false, reason = "disconnected" }
    end
    result = submit_result
    local submit_meta = type(submit_result) == "table" and submit_result.meta or nil

    if not result.ok and result.reason == "resynced_retry_required" then
      result = self.authoritative_adapter:submit(command)
    end

    if result.ok then
      if self.authoritative_adapter.poll then
        -- Threaded adapter (joiner): apply command locally for instant feedback.
        -- The authoritative state arrives via state_push shortly after.
        local ok_local, local_result = pcall(function()
          return commands.execute(self.game_state, command)
        end)
        if ok_local then
          local local_submit_id = submit_meta and submit_meta.local_submit_id
          if type(local_submit_id) == "number"
            and self.authoritative_adapter.record_local_prediction
            and type(self.game_state) == "table"
          then
            local ok_hash, local_hash = pcall(game_checksum.game_state, self.game_state)
            if ok_hash and type(local_hash) == "string" then
              pcall(function()
                self.authoritative_adapter:record_local_prediction(local_submit_id, local_hash, {
                  command_type = command and command.type,
                })
              end)
            else
              print("[game] local prediction hash failed: " .. tostring(local_hash))
            end
          end
          result = local_result
        else
          -- Don't crash the client on optimistic-sim errors; keep the
          -- authoritative submit result and wait for the incoming state_push.
          print("[game] optimistic local apply failed for " .. tostring(command.type) .. ": " .. tostring(local_result))
          self.multiplayer_status = "Connected (syncing after local sim error)"
        end
      else
        -- In-process adapter (host): state is already updated server-side.
        local remote_state = self.authoritative_adapter:get_state()
        if remote_state then
          self.game_state = remote_state
        end
      end
      self.multiplayer_status = "Connected"
    else
      self.multiplayer_status = "Multiplayer warning: " .. tostring(result.reason)
      if should_trigger_reconnect(result.reason) then
        self:_queue_reconnect(result.reason)
      end
    end
  else
    result = commands.execute(self.game_state, command)
  end

  if command and command.type ~= "DECLARE_ATTACKERS" and #self.pending_attack_declarations > 0 then
    self:_clear_pending_attack_declarations()
  end
  if command and command.type ~= "ASSIGN_ATTACK_TRIGGER_TARGETS" and #self.pending_attack_trigger_targets > 0 then
    self.pending_attack_trigger_targets = {}
  end

  self:_sync_terminal_state()
  replay.append(self.command_log, command, result, self.game_state, {
    post_state_hash_scope = self.authoritative_adapter and "client_visible" or "local_full",
    post_state_viewer_player_index = self.local_player_index,
  })
  if not result.ok then
    sound.play("error")
  end
  return result
end

function GameState:get_command_log_snapshot()
  return replay.snapshot(self.command_log)
end

function GameState:update(dt)
  tween.update(dt)
  popup.update(dt)
  shake.update(dt)
  particles.update(dt)

  -- Smooth glide for dragged worker (Balatro-style)
  if self.drag then
    local mx, my = love.mouse.getPosition()
    local speed = 18
    local t = 1 - math.exp(-dt * speed)
    self.drag.display_x = self.drag.display_x + (mx - self.drag.display_x) * t
    self.drag.display_y = self.drag.display_y + (my - self.drag.display_y) * t
  end

  -- Feature 1: Smooth resource count-up (lerp display toward actual)
  for pi = 1, 2 do
    local dr = self.display_resources[pi]
    local actual = self.game_state.players[pi].resources
    for _, key in ipairs(config.resource_types) do
      local cur = dr[key] or 0
      local target = actual[key] or 0
      local diff = target - cur
      if math.abs(diff) < 0.05 then
        dr[key] = target
      else
        dr[key] = cur + diff * (1 - math.exp(-dt * 12))
      end
    end
  end

  -- Feature 2: Update returning workers
  for i = #self.returning_workers, 1, -1 do
    local rw = self.returning_workers[i]
    rw.progress = rw.progress + dt / rw.duration
    if rw.progress >= 1 then
      table.remove(self.returning_workers, i)
    else
      -- Ease out cubic
      local t = rw.progress
      local eased = 1 - (1 - t) * (1 - t) * (1 - t)
      rw.x = rw.start_x + (rw.target_x - rw.start_x) * eased
      rw.y = rw.start_y + (rw.target_y - rw.start_y) * eased
      rw.alpha = 1 - t * 0.5  -- fade slightly as it returns
      rw.scale = 1.2 - 0.2 * eased  -- shrink back to normal size
    end
  end

  -- Hand card hover animation: smoothly lerp y_offsets toward target
  local hand = self.game_state.players[self.local_player_index + 1].hand
  local hover_rise = board.HAND_HOVER_RISE
  local anim_speed = 14  -- fast, snappy response
  -- Ensure y_offsets array matches hand size
  while #self.hand_y_offsets < #hand do
    self.hand_y_offsets[#self.hand_y_offsets + 1] = 0
  end
  while #self.hand_y_offsets > #hand do
    table.remove(self.hand_y_offsets)
  end
  for i = 1, #hand do
    local target_y = 0
    if i == self.hand_hover_index then
      target_y = -hover_rise  -- rise up
    elseif self.hand_hover_index then
      -- Neighbors rise slightly for a "fan out" feel
      local dist = math.abs(i - self.hand_hover_index)
      if dist == 1 then
        target_y = -hover_rise * 0.15
      end
    end
    local cur = self.hand_y_offsets[i] or 0
    local diff = target_y - cur
    if math.abs(diff) < 0.3 then
      self.hand_y_offsets[i] = target_y
    else
      self.hand_y_offsets[i] = cur + diff * (1 - math.exp(-dt * anim_speed))
    end
  end

  -- Feature 4: Cursor management
  local want_hand = false
  if self.hover and not self.drag then
    local k = self.hover.kind
    if k == "blueprint" or k == "end_turn" or k == "pass" or k == "activate_base"
       or k == "activate_ability" or k == "ability_hover"
       or k == "worker_unassigned" or k == "worker_left" or k == "worker_right"
       or k == "structure" or k == "structure_worker" or k == "hand_card" or k == "unit_deck" or k == "graveyard" or k == "unit_row"
       or k == "special_worker_unassigned" or k == "special_worker_resource" or k == "special_worker_structure" then
      want_hand = true
    end
  end
  if self.drag then want_hand = true end
  local desired = want_hand and "hand" or "arrow"
  if desired ~= self._current_cursor then
    if desired == "hand" then
      love.mouse.setCursor(self._cursor_hand)
    else
      love.mouse.setCursor()
    end
    self._current_cursor = desired
  end

  -- Feature 5: Tooltip hover delay (structures + deck/graveyard + ability buttons + workers)
  if self.hover and (self.hover.kind == "structure" or self.hover.kind == "unit_deck" or self.hover.kind == "graveyard"
      or self.hover.kind == "ability_hover" or self.hover.kind == "activate_ability"
      or self.hover.kind == "special_worker_unassigned" or self.hover.kind == "special_worker_resource"
      or self.hover.kind == "special_worker_structure"
      or self.hover.kind == "worker_unassigned" or self.hover.kind == "worker_left"
      or self.hover.kind == "worker_right" or self.hover.kind == "structure_worker") and not deck_viewer.is_open() then
    local target_key
    if (self.hover.kind == "ability_hover" or self.hover.kind == "activate_ability") and type(self.hover.idx) == "table" then
      local info = self.hover.idx
      target_key = "ability:" .. self.hover.pi .. ":" .. (info.source or "") .. ":" .. (info.board_index or 0) .. ":" .. (info.ability_index or 0)
    else
      target_key = self.hover.kind .. ":" .. self.hover.pi .. ":" .. (self.hover.idx or 0)
    end
    if self.tooltip_target == target_key then
      self.tooltip_timer = self.tooltip_timer + dt
    else
      self.tooltip_target = target_key
      self.tooltip_timer = 0
    end
  else
    self.tooltip_target = nil
    self.tooltip_timer = 0
  end

  -- Poll adapter for push-based state updates (threaded adapters)
  if self.authoritative_adapter and self.authoritative_adapter.poll then
    local ok_poll, poll_err = pcall(function() self.authoritative_adapter:poll() end)
    if not ok_poll then
      local poll_reason = tostring(poll_err)
      print("[game] poll error: " .. poll_reason)
      if should_trigger_reconnect(poll_reason) then
        self:_queue_reconnect(poll_reason)
      else
        self:_handle_disconnect("Connection lost: " .. poll_reason)
      end
    elseif self.authoritative_adapter._disconnected then
      local disconnect_reason = tostring(self.authoritative_adapter._disconnect_reason or "transport_receive_failed")
      self.authoritative_adapter._disconnected = false
      self.authoritative_adapter._disconnect_reason = nil
      if should_trigger_reconnect(disconnect_reason) then
        self:_queue_reconnect(disconnect_reason)
      else
        self:_handle_disconnect("Opponent disconnected: " .. disconnect_reason)
      end
    else
      if self.authoritative_adapter.pop_desync_reports then
        local ok_reports, reports = pcall(function() return self.authoritative_adapter:pop_desync_reports() end)
        if ok_reports and type(reports) == "table" then
          for _, report in ipairs(reports) do
            if type(report) == "table" then
              self._last_desync_report = report
              local detail = tostring(report.kind or "hash_mismatch")
              if report.command_type then
                detail = detail .. " (" .. tostring(report.command_type) .. ")"
              end
              if report.state_seq then
                detail = detail .. " seq=" .. tostring(report.state_seq)
              end
              print("[game] desync detected: " .. detail
                .. " local=" .. tostring(report.local_hash)
                .. " host=" .. tostring(report.authoritative_hash))
              if not self.reconnect_pending then
                self.multiplayer_status = "Desync detected (resyncing)..."
                self:_queue_reconnect("desync_hash_mismatch: " .. detail)
              end
              break
            end
          end
        elseif not ok_reports then
          print("[game] pop_desync_reports error: " .. tostring(reports))
        end
      end
      if self.authoritative_adapter.state_changed then
        self.authoritative_adapter.state_changed = false
        local remote_state = self.authoritative_adapter:get_state()
        if remote_state then
          self.game_state = remote_state
        end
      end
    end
  elseif self.authoritative_adapter and not self.reconnect_pending then
    -- Fallback sync poll for in-process adapters (host side)
    self.sync_poll_timer = self.sync_poll_timer - dt
    if self.sync_poll_timer <= 0 then
      self.sync_poll_timer = self.sync_poll_interval
      local ok_sync, snap = pcall(function() return self.authoritative_adapter:sync_snapshot() end)
      if not ok_sync then
        local sync_reason = tostring(snap)
        print("[game] sync_snapshot error: " .. sync_reason)
        if should_trigger_reconnect(sync_reason) then
          self:_queue_reconnect(sync_reason)
        else
          self:_handle_disconnect("Connection lost: " .. sync_reason)
        end
      elseif snap.ok then
        local remote_state = self.authoritative_adapter:get_state()
        if remote_state then
          self.game_state = remote_state
        end
      elseif should_trigger_reconnect(snap.reason) then
        self:_queue_reconnect(snap.reason)
      end
    end
  end

  if self.reconnect_pending and self.authoritative_adapter then
    self.reconnect_timer = self.reconnect_timer - dt
    if self.reconnect_timer <= 0 then
      self:_attempt_reconnect()
    end
  end

  self:_sync_terminal_state()

  local c = self.game_state and self.game_state.pendingCombat
  local in_target_step = c and c.stage == "AWAITING_ATTACK_TARGETS" and c.attacker == self.local_player_index
  if not in_target_step and #self.pending_attack_trigger_targets > 0 then
    self:_clear_pending_attack_trigger_targets()
  end

  -- Disconnect countdown: show message then return to menu
  if self._disconnect_timer then
    self._disconnect_timer = self._disconnect_timer - dt
    if self._disconnect_timer <= 0 then
      self._disconnect_timer = nil
      self._disconnect_message = nil
      if self.return_to_menu then
        self.return_to_menu()
        return
      end
    end
  end

  -- Pump websocket server to accept connections and handle remote frames
  if self.server_step then
    local ok_step, step_err = pcall(self.server_step)
    if not ok_step then
      print("[hosted_game] server step error: " .. tostring(step_err))
    end
  end

  if self.turn_banner_timer > 0 then
    self.turn_banner_timer = self.turn_banner_timer - dt
    if self.turn_banner_timer < 0 then self.turn_banner_timer = 0 end
  end
end



local function can_attack_multiple_times(card_def)
  if not card_def or not card_def.abilities then return false end
  for _, ab in ipairs(card_def.abilities) do
    if ab.type == "static" and (ab.effect == "can_attack_multiple_times" or ab.effect == "can_attack_twice") then
      return true
    end
  end
  return false
end

local function find_targeted_spell_on_cast_ability(spell_def)
  return abilities.find_targeted_spell_on_cast_ability(spell_def)
end

local function collect_targeted_spell_eligible_indices(game_state, caster_pi, targeted_ab)
  local spell_def = { abilities = { targeted_ab } }
  local info = abilities.collect_spell_target_candidates(game_state, caster_pi, spell_def)
  if not info then
    return 1 - caster_pi, {}
  end
  return info.target_player_index, info.eligible_board_indices
end

function GameState:_set_pending_attack(attacker_board_index, target)
  local local_player = self.game_state.players[self.local_player_index + 1]
  local attacker_entry = local_player and local_player.board and local_player.board[attacker_board_index]
  if not attacker_entry then return end

  local ok_def, attacker_def = pcall(cards.get_card_def, attacker_entry.card_id)
  if not ok_def or not attacker_def then return end
  if attacker_def.kind ~= "Unit" and attacker_def.kind ~= "Worker" then return end
  if unit_stats.effective_attack(attacker_def, attacker_entry.state, self.game_state, self.local_player_index) <= 0 then return end

  local ast = attacker_entry.state or {}
  if ast.rested then return end
  if ast.attacked_turn == self.game_state.turnNumber and not can_attack_multiple_times(attacker_def) then
    return
  end

  local replaced = false
  for _, decl in ipairs(self.pending_attack_declarations) do
    if decl.attacker_board_index == attacker_board_index then
      decl.target = target
      replaced = true
      break
    end
  end
  if not replaced then
    self.pending_attack_declarations[#self.pending_attack_declarations + 1] = {
      attacker_board_index = attacker_board_index,
      target = target,
    }
  end
end




function GameState:_clear_pending_attack_declarations()
  self.pending_attack_declarations = {}
end

function GameState:_clear_pending_attack_trigger_targets()
  self.pending_attack_trigger_targets = {}
end

function GameState:_pending_attack_trigger_entry(attacker_board_index, ability_index, create_if_missing)
  for _, item in ipairs(self.pending_attack_trigger_targets or {}) do
    if item.attacker_board_index == attacker_board_index and item.ability_index == ability_index then
      return item
    end
  end

  if not create_if_missing then
    return nil
  end

  local item = {
    attacker_board_index = attacker_board_index,
    ability_index = ability_index,
  }
  self.pending_attack_trigger_targets[#self.pending_attack_trigger_targets + 1] = item
  return item
end

function GameState:_get_pending_attack_trigger_target(attacker_board_index, ability_index)
  local item = self:_pending_attack_trigger_entry(attacker_board_index, ability_index, false)
  return item and item.target_board_index or nil
end

function GameState:_get_pending_attack_trigger_activation(attacker_board_index, ability_index)
  local item = self:_pending_attack_trigger_entry(attacker_board_index, ability_index, false)
  return item and item.activate or nil
end

function GameState:_set_pending_attack_trigger_target(attacker_board_index, ability_index, target_board_index)
  local item = self:_pending_attack_trigger_entry(attacker_board_index, ability_index, true)
  item.target_board_index = target_board_index
end

function GameState:_set_pending_attack_trigger_activation(attacker_board_index, ability_index, activate)
  local item = self:_pending_attack_trigger_entry(attacker_board_index, ability_index, true)
  item.activate = (activate == true) and true or nil
end

function GameState:_is_pending_attack_trigger_target_legal(defender_pi, board_index)
  local player = self.game_state.players[defender_pi + 1]
  local entry = player and player.board and player.board[board_index]
  if not entry then return false end
  local ok_def, def = pcall(cards.get_card_def, entry.card_id)
  return ok_def and def and def.kind ~= "Structure" and def.kind ~= "Artifact"
end

function GameState:_attack_trigger_legal_targets(combat_state)
  local out = {}
  if not combat_state then return out end
  local defender = combat_state.defender
  local player = self.game_state.players[defender + 1]
  if not player then return out end
  for i, entry in ipairs(player.board or {}) do
    local ok_def, def = pcall(cards.get_card_def, entry.card_id)
    if ok_def and def and def.kind ~= "Structure" and def.kind ~= "Artifact" then
      out[#out + 1] = i
    end
  end
  return out
end

function GameState:_active_attack_trigger_for_targeting(combat_state)
  if not combat_state or type(combat_state.attack_triggers) ~= "table" then
    return nil
  end

  for _, trigger in ipairs(combat_state.attack_triggers) do
    if not trigger.resolved and trigger.requires_target then
      local selected = self:_get_pending_attack_trigger_target(trigger.attacker_board_index, trigger.ability_index)
      if selected == nil then
        return trigger
      end
    end
  end

  for _, trigger in ipairs(combat_state.attack_triggers) do
    if not trigger.resolved and trigger.optional_activate then
      local activate = self:_get_pending_attack_trigger_activation(trigger.attacker_board_index, trigger.ability_index)
      if activate ~= true then
        return trigger
      end
    end
  end

  return nil
end

function GameState:_build_attack_trigger_target_payload(combat_state)
  local payload = {}
  if not combat_state or type(combat_state.attack_triggers) ~= "table" then
    return payload
  end
  for _, trigger in ipairs(combat_state.attack_triggers) do
    if not trigger.resolved then
      local selected = self:_get_pending_attack_trigger_target(trigger.attacker_board_index, trigger.ability_index)
      local activate = self:_get_pending_attack_trigger_activation(trigger.attacker_board_index, trigger.ability_index)
      if trigger.requires_target and selected ~= nil then
        payload[#payload + 1] = {
          attacker_board_index = trigger.attacker_board_index,
          ability_index = trigger.ability_index,
          target_board_index = selected,
        }
      elseif trigger.optional_activate and activate == true then
        payload[#payload + 1] = {
          attacker_board_index = trigger.attacker_board_index,
          ability_index = trigger.ability_index,
          activate = true,
        }
      end
    end
  end
  return payload
end

function GameState:_prune_invalid_pending_attacks()
  local player = self.game_state.players[self.local_player_index + 1]
  if not player then
    self.pending_attack_declarations = {}
    return
  end

  local kept = {}
  for _, decl in ipairs(self.pending_attack_declarations or {}) do
    local entry = player.board[decl.attacker_board_index]
    if entry then
      local ok_def, def = pcall(cards.get_card_def, entry.card_id)
      local st = entry.state or {}
      local already_attacked = (st.attacked_turn == self.game_state.turnNumber) and (not can_attack_multiple_times(def))
      if ok_def and def and (def.kind == "Unit" or def.kind == "Worker") and unit_stats.effective_attack(def, st, self.game_state, self.local_player_index) > 0 and not st.rested and not already_attacked then
        kept[#kept + 1] = decl
      end
    end
  end
  self.pending_attack_declarations = kept
end

function GameState:_set_pending_block(blocker_board_index, attacker_board_index)
  local replaced = false
  for _, blk in ipairs(self.pending_block_assignments) do
    if blk.blocker_board_index == blocker_board_index then
      blk.attacker_board_index = attacker_board_index
      replaced = true
      break
    end
  end
  if not replaced then
    self.pending_block_assignments[#self.pending_block_assignments + 1] = {
      blocker_board_index = blocker_board_index,
      attacker_board_index = attacker_board_index,
    }
  end
end

function GameState:_build_default_damage_orders(combat_state)
  local grouped = {}
  for _, blk in ipairs((combat_state and combat_state.blockers) or {}) do
    local attacker_index = blk.attacker_board_index
    grouped[attacker_index] = grouped[attacker_index] or {}
    grouped[attacker_index][#grouped[attacker_index] + 1] = blk.blocker_board_index
  end

  local orders = {}
  for attacker_index, blocker_indices in pairs(grouped) do
    if #blocker_indices > 1 then
      local custom = self.pending_damage_orders[attacker_index]
      local ordered = {}
      local seen = {}
      if type(custom) == "table" then
        for _, bi in ipairs(custom) do
          for _, legal in ipairs(blocker_indices) do
            if bi == legal and not seen[bi] then
              ordered[#ordered + 1] = bi
              seen[bi] = true
              break
            end
          end
        end
      end
      for _, bi in ipairs(blocker_indices) do
        if not seen[bi] then ordered[#ordered + 1] = bi end
      end

      orders[#orders + 1] = {
        attacker_board_index = attacker_index,
        blocker_board_indices = ordered,
      }
    end
  end
  return orders
end

function GameState:_append_pending_damage_order(attacker_board_index, blocker_board_index)
  local list = self.pending_damage_orders[attacker_board_index] or {}
  local filtered = {}
  for _, bi in ipairs(list) do
    if bi ~= blocker_board_index then filtered[#filtered + 1] = bi end
  end
  filtered[#filtered + 1] = blocker_board_index
  self.pending_damage_orders[attacker_board_index] = filtered
end

function GameState:_draw_attack_declaration_arrows()
  local local_attacker = self.local_player_index
  local local_defender = 1 - local_attacker
  local combat_ui = {
    pending_attack_declarations = self.pending_attack_declarations,
    pending_block_assignments = self.pending_block_assignments,
    pending_attack_trigger_targets = self.pending_attack_trigger_targets,
  }

  -- Local staged declarations (before submit)
  for _, decl in ipairs(self.pending_attack_declarations or {}) do
    local ax, ay = board.board_entry_center(self.game_state, local_attacker, decl.attacker_board_index, self.local_player_index, combat_ui)
    local tx, ty
    if decl.target and decl.target.type == "base" then
      tx, ty = board.base_center_for_player(local_defender, self.local_player_index)
    elseif decl.target and decl.target.type == "board" then
      tx, ty = board.board_entry_center(self.game_state, local_defender, decl.target.index, self.local_player_index, combat_ui)
    end
    if ax and ay and tx and ty then
      self:_draw_arrow(ax, ay, tx, ty, { 1.0, 0.3, 0.3, 0.9 })
    end
  end

  -- Committed combat declarations (visible to both players)
  local c = self.game_state.pendingCombat
  local committed = c and c.attackers or nil
  if committed then
    for _, decl in ipairs(committed) do
      local ax, ay = board.board_entry_center(self.game_state, c.attacker, decl.board_index, self.local_player_index, combat_ui)
      local tx, ty
      if decl.target and decl.target.type == "base" then
        tx, ty = board.base_center_for_player(c.defender, self.local_player_index)
      elseif decl.target and decl.target.type == "board" then
        tx, ty = board.board_entry_center(self.game_state, c.defender, decl.target.index, self.local_player_index, combat_ui)
      end
      if ax and ay and tx and ty then
        self:_draw_arrow(ax, ay, tx, ty, { 1.0, 0.45, 0.45, 0.7 })
      end
    end
  end

  if c and c.stage == "DECLARED" and c.defender == self.local_player_index then
    local defender_pi = self.local_player_index
    local attacker_pi2 = c.attacker
    for _, blk in ipairs(self.pending_block_assignments or {}) do
      local bx, by = board.board_entry_center(self.game_state, defender_pi, blk.blocker_board_index, self.local_player_index, combat_ui)
      local ax, ay = board.board_entry_center(self.game_state, attacker_pi2, blk.attacker_board_index, self.local_player_index, combat_ui)
      if bx and by and ax and ay then
        self:_draw_arrow(bx, by, ax, ay, { 0.35, 0.75, 1.0, 0.9 })
      end
    end
  end

  if c and c.blockers and #c.blockers > 0 then
    for _, blk in ipairs(c.blockers) do
      local bx, by = board.board_entry_center(self.game_state, c.defender, blk.blocker_board_index, self.local_player_index, combat_ui)
      local ax, ay = board.board_entry_center(self.game_state, c.attacker, blk.attacker_board_index, self.local_player_index, combat_ui)
      if bx and by and ax and ay then
        self:_draw_arrow(bx, by, ax, ay, { 0.2, 0.65, 0.95, 0.7 })
      end
    end
  end

  if self.drag and self.drag.from == "attack_unit" and self.drag.player_index == self.local_player_index then
    local ax, ay = board.board_entry_center(self.game_state, self.drag.player_index, self.drag.board_index, self.local_player_index, combat_ui)
    if ax and ay then
      self:_draw_arrow(ax, ay, self.drag.display_x, self.drag.display_y, { 1.0, 0.8, 0.2, 0.85 })
    end
  end
  if self.drag and self.drag.from == "block_unit" and self.drag.player_index == self.local_player_index then
    local bx, by = board.board_entry_center(self.game_state, self.drag.player_index, self.drag.board_index, self.local_player_index, combat_ui)
    if bx and by then
      self:_draw_arrow(bx, by, self.drag.display_x, self.drag.display_y, { 0.35, 0.75, 1.0, 0.85 })
    end
  end
  if self.drag and self.drag.from == "order_attacker" and self.drag.player_index == self.local_player_index then
    local ax, ay = board.board_entry_center(self.game_state, self.drag.player_index, self.drag.board_index, self.local_player_index, combat_ui)
    if ax and ay then
      self:_draw_arrow(ax, ay, self.drag.display_x, self.drag.display_y, { 1.0, 0.95, 0.45, 0.85 })
    end
  end
end

function GameState:_draw_top_combat_prompt(prompt_text, border_color, text_color)
  if type(prompt_text) ~= "string" or prompt_text == "" then
    return
  end

  local gw = love.graphics.getWidth()
  local prompt_font = util.get_font(14)
  local prompt_w = prompt_font:getWidth(prompt_text) + 28
  local prompt_h = prompt_font:getHeight() + 12
  local prompt_x = (gw - prompt_w) / 2
  local prompt_y = 8

  border_color = border_color or { 0.65, 0.72, 0.9, 0.75 }
  text_color = text_color or { 0.86, 0.9, 1.0, 1.0 }

  love.graphics.setColor(0.07, 0.08, 0.12, 0.9)
  love.graphics.rectangle("fill", prompt_x, prompt_y, prompt_w, prompt_h, 7, 7)
  love.graphics.setColor(border_color[1], border_color[2], border_color[3], border_color[4] or 0.75)
  love.graphics.rectangle("line", prompt_x, prompt_y, prompt_w, prompt_h, 7, 7)
  love.graphics.setFont(prompt_font)
  love.graphics.setColor(text_color[1], text_color[2], text_color[3], text_color[4] or 1.0)
  love.graphics.printf(prompt_text, prompt_x, prompt_y + 6, prompt_w, "center")
end

function GameState:_draw_attack_trigger_targeting_overlay()
  local c = self.game_state and self.game_state.pendingCombat
  if not c or c.stage ~= "AWAITING_ATTACK_TARGETS" then
    return
  end

  local t = love.timer.getTime()

  if c.attacker == self.local_player_index then
    local combat_ui = {
      pending_attack_declarations = self.pending_attack_declarations,
      pending_block_assignments = self.pending_block_assignments,
      pending_attack_trigger_targets = self.pending_attack_trigger_targets,
    }
    local active_trigger = self:_active_attack_trigger_for_targeting(c)
    local legal_targets = {}
    if active_trigger and active_trigger.requires_target then
      legal_targets = self:_attack_trigger_legal_targets(c)

      for _, target_index in ipairs(legal_targets) do
        local tx, ty = board.board_entry_center(self.game_state, c.defender, target_index, self.local_player_index, combat_ui)
        if tx and ty then
          local glow = 0.5 + 0.25 * math.sin(t * 4)
          local rw = board.BFIELD_TILE_W + 8
          local rh = board.BFIELD_TILE_H + 8
          local rx = tx - rw / 2
          local ry = ty - rh / 2
          love.graphics.setColor(0.22, 0.8, 1.0, glow * 0.55)
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", rx, ry, rw, rh, 7, 7)
          love.graphics.setLineWidth(1)
        end
      end
    end

    for _, trigger in ipairs(c.attack_triggers or {}) do
      if not trigger.resolved then
        local selected = self:_get_pending_attack_trigger_target(trigger.attacker_board_index, trigger.ability_index)
        if selected then
          local sx, sy = board.board_entry_center(self.game_state, c.attacker, trigger.attacker_board_index, self.local_player_index, combat_ui)
          local tx, ty = board.board_entry_center(self.game_state, c.defender, selected, self.local_player_index, combat_ui)
          if sx and sy and tx and ty then
            self:_draw_arrow(sx, sy, tx, ty, { 1.0, 0.85, 0.35, 0.9 })
          end
        end

        if trigger.optional_activate and self:_get_pending_attack_trigger_activation(trigger.attacker_board_index, trigger.ability_index) == true then
          local sx, sy = board.board_entry_center(self.game_state, c.attacker, trigger.attacker_board_index, self.local_player_index, combat_ui)
          if sx and sy then
            local glow = 0.55 + 0.25 * math.sin(t * 4)
            local rw = board.BFIELD_TILE_W + 10
            local rh = board.BFIELD_TILE_H + 10
            local rx = sx - rw / 2
            local ry = sy - rh / 2
            love.graphics.setColor(0.2, 0.85, 0.45, glow * 0.25)
            love.graphics.rectangle("fill", rx, ry, rw, rh, 8, 8)
            love.graphics.setColor(0.3, 1.0, 0.6, glow * 0.9)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", rx, ry, rw, rh, 8, 8)
            love.graphics.setLineWidth(1)
          end
        end
      end
    end

    local function trigger_attacker_name(trigger)
      local attacker_name = "Attacker"
      local atk_player = self.game_state.players[c.attacker + 1]
      local atk_entry = atk_player and atk_player.board and atk_player.board[trigger.attacker_board_index]
      if atk_entry then
        local ok_def, def = pcall(cards.get_card_def, atk_entry.card_id)
        if ok_def and def and def.name then
          attacker_name = def.name
        end
      end
      return attacker_name
    end

    local prompt_text = "On Attack choices set. Press Pass to continue"
    local border_color = { 1.0, 0.78, 0.32, 0.85 }
    local text_color = { 0.96, 0.9, 0.8, 1.0 }
    if active_trigger then
      local attacker_name = trigger_attacker_name(active_trigger)

      local sx, sy = board.board_entry_center(self.game_state, c.attacker, active_trigger.attacker_board_index, self.local_player_index, combat_ui)
      if sx and sy then
        local glow = 0.55 + 0.3 * math.sin(t * 4)
        local rw = board.BFIELD_TILE_W + 10
        local rh = board.BFIELD_TILE_H + 10
        local rx = sx - rw / 2
        local ry = sy - rh / 2

        if active_trigger.requires_target then
          if #legal_targets > 0 then
            prompt_text = attacker_name .. ": select a unit-row target, then Pass"
          else
            prompt_text = attacker_name .. ": no valid unit-row targets. Press Pass"
          end
          love.graphics.setColor(1.0, 0.75, 0.25, glow * 0.35)
          love.graphics.rectangle("fill", rx, ry, rw, rh, 8, 8)
          love.graphics.setColor(1.0, 0.78, 0.32, glow)
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", rx, ry, rw, rh, 8, 8)
          love.graphics.setLineWidth(1)
        elseif active_trigger.optional_activate then
          local selected = self:_get_pending_attack_trigger_activation(active_trigger.attacker_board_index, active_trigger.ability_index) == true
          if selected then
            prompt_text = attacker_name .. ": ability selected. Press Pass to continue"
            border_color = { 0.3, 0.9, 0.55, 0.85 }
            text_color = { 0.9, 1.0, 0.92, 1.0 }
            love.graphics.setColor(0.2, 0.85, 0.45, glow * 0.25)
            love.graphics.rectangle("fill", rx, ry, rw, rh, 8, 8)
            love.graphics.setColor(0.3, 1.0, 0.6, glow * 0.9)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", rx, ry, rw, rh, 8, 8)
            love.graphics.setLineWidth(1)
          else
            prompt_text = attacker_name .. ": click this attacker to activate On Attack, or Pass to skip"
            love.graphics.setColor(1.0, 0.75, 0.25, glow * 0.35)
            love.graphics.rectangle("fill", rx, ry, rw, rh, 8, 8)
            love.graphics.setColor(1.0, 0.78, 0.32, glow)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", rx, ry, rw, rh, 8, 8)
            love.graphics.setLineWidth(1)
          end
        end
      end
    end

    self:_draw_top_combat_prompt(prompt_text, border_color, text_color)
  elseif c.defender == self.local_player_index then
    self:_draw_top_combat_prompt("Waiting for opponent to resolve On Attack choices...", { 0.65, 0.72, 0.9, 0.75 }, { 0.86, 0.9, 1.0, 1.0 })
  end
end

function GameState:_draw_combat_priority_overlay()
  local c = self.game_state and self.game_state.pendingCombat
  if not c or c.stage == "AWAITING_ATTACK_TARGETS" then
    return
  end

  local local_pi = self.local_player_index
  local prompt_text = nil
  local border_color = { 0.65, 0.72, 0.9, 0.75 }
  local text_color = { 0.86, 0.9, 1.0, 1.0 }

  if c.stage == "DECLARED" then
    if c.defender == local_pi then
      if #(self.pending_block_assignments or {}) > 0 then
        prompt_text = "Blockers selected. Press Pass to continue"
      else
        prompt_text = "Declare blockers, then Pass"
      end
      border_color = { 0.35, 0.75, 1.0, 0.85 }
      text_color = { 0.86, 0.94, 1.0, 1.0 }
    elseif c.attacker == local_pi then
      prompt_text = "Waiting for opponent to declare blockers..."
    end
  elseif c.stage == "AWAITING_DAMAGE_ORDER" then
    if c.attacker == local_pi then
      local has_custom_order = false
      for _, order in pairs(self.pending_damage_orders or {}) do
        if type(order) == "table" and #order > 0 then
          has_custom_order = true
          break
        end
      end
      if has_custom_order then
        prompt_text = "Damage order set. Press Pass to continue"
      else
        prompt_text = "Set blocker damage order (optional), then Pass"
      end
      border_color = { 1.0, 0.82, 0.35, 0.85 }
      text_color = { 0.98, 0.92, 0.78, 1.0 }
    elseif c.defender == local_pi then
      prompt_text = "Waiting for opponent to set damage order..."
    end
  elseif c.stage == "BLOCKERS_ASSIGNED" then
    if c.attacker == local_pi then
      prompt_text = "Press Pass to resolve combat"
      border_color = { 0.92, 0.65, 0.3, 0.85 }
      text_color = { 0.98, 0.9, 0.8, 1.0 }
    elseif c.defender == local_pi then
      prompt_text = "Waiting for attacker to resolve combat..."
    end
  end

  self:_draw_top_combat_prompt(prompt_text, border_color, text_color)
end

function GameState:_draw_pending_hand_sacrifice_overlay()
  local pending = self:_prompt_payload("hand_sacrifice") or self.pending_hand_sacrifice
  if not pending then
    return
  end

  local local_p = self.game_state and self.game_state.players and self.game_state.players[self.local_player_index + 1]
  local card_name = "Card"
  if local_p and local_p.hand and pending.hand_index then
    local card_id = local_p.hand[pending.hand_index]
    if card_id then
      local ok_def, def = pcall(cards.get_card_def, card_id)
      if ok_def and def and def.name then
        card_name = def.name
      end
    end
  end

  local required = pending.required_count or 0
  local selected = #(pending.selected_targets or {})
  local prompt_text
  if required > 0 then
    prompt_text = card_name .. ": select workers to sacrifice (" .. selected .. "/" .. required .. ")"
  else
    prompt_text = card_name .. ": select workers to sacrifice"
  end

  self:_draw_top_combat_prompt(prompt_text, { 0.95, 0.78, 0.35, 0.85 }, { 0.98, 0.92, 0.8, 1.0 })
end

function GameState:_draw_pending_monument_overlay()
  local pending = self:_prompt_payload("monument") or self.pending_monument
  if not pending then return end

  local local_p = self.game_state and self.game_state.players and self.game_state.players[self.local_player_index + 1]
  local card_name = "Card"
  if local_p and local_p.hand and pending.hand_index then
    local card_id = local_p.hand[pending.hand_index]
    if card_id then
      local ok_def, def = pcall(cards.get_card_def, card_id)
      if ok_def and def and def.name then card_name = def.name end
    end
  end

  local prompt_text = card_name .. ": select a Monument with " .. pending.min_counters .. "+ Wonder counters"
  self:_draw_top_combat_prompt(prompt_text, { 0.6, 0.5, 0.1, 0.85 }, { 0.98, 0.92, 0.6, 1.0 })
end

function GameState:_draw_pending_damage_x_overlay()
  local pending = self:_prompt_payload("damage_x") or self.pending_damage_x
  if not pending then return end

  local gw = love.graphics.getWidth()
  local btn_w, btn_h = 24, 22
  local prompt_font = util.get_font(14)
  local label_text = "X Stone -> Deal " .. pending.x_amount .. " damage  (max: " .. pending.max_x .. ")"
  local label_w = prompt_font:getWidth(label_text)
  local total_w = btn_w + 8 + label_w + 8 + btn_w + 28
  local total_h = btn_h + 12
  local rx = (gw - total_w) / 2
  local ry = 8

  love.graphics.setColor(0.07, 0.08, 0.12, 0.9)
  love.graphics.rectangle("fill", rx, ry, total_w, total_h, 7, 7)
  love.graphics.setColor(0.95, 0.35, 0.2, 0.75)
  love.graphics.rectangle("line", rx, ry, total_w, total_h, 7, 7)

  local minus_x = rx + 6
  local minus_y = ry + (total_h - btn_h) / 2
  love.graphics.setColor(0.25, 0.25, 0.3, 0.9)
  love.graphics.rectangle("fill", minus_x, minus_y, btn_w, btn_h, 4, 4)
  love.graphics.setColor(0.85, 0.85, 0.95, 1.0)
  love.graphics.setFont(prompt_font)
  love.graphics.printf("-", minus_x, minus_y + 3, btn_w, "center")

  local label_x = minus_x + btn_w + 8
  love.graphics.setColor(0.98, 0.85, 0.7, 1.0)
  love.graphics.printf(label_text, label_x, ry + (total_h - prompt_font:getHeight()) / 2, label_w + 4, "left")

  local plus_x = label_x + label_w + 8
  love.graphics.setColor(0.25, 0.25, 0.3, 0.9)
  love.graphics.rectangle("fill", plus_x, minus_y, btn_w, btn_h, 4, 4)
  love.graphics.setColor(0.85, 0.85, 0.95, 1.0)
  love.graphics.printf("+", plus_x, minus_y + 3, btn_w, "center")

  -- Store button rects for click detection in mousepressed
  pending.minus_btn = { x = minus_x, y = minus_y, w = btn_w, h = btn_h }
  pending.plus_btn  = { x = plus_x,  y = minus_y, w = btn_w, h = btn_h }
end

function GameState:_draw_pending_discard_draw_overlay()
  local pending = self:_prompt_payload("discard_draw") or self.pending_discard_draw
  if not pending then return end
  local selected_count = 0
  for _ in pairs(pending.selected_set) do selected_count = selected_count + 1 end
  local remaining = pending.required_count - selected_count
  local msg
  if remaining > 0 then
    msg = "Select " .. remaining .. " card" .. (remaining == 1 and "" or "s") .. " to discard"
  else
    msg = "Discarding..."
  end
  self:_draw_top_combat_prompt(msg, { 0.9, 0.45, 0.1, 0.85 }, { 1.0, 0.85, 0.6, 1.0 })
end

function GameState:_draw_pending_spell_target_prompt()
  local pending = self:_prompt_payload("spell_target") or self.pending_spell_target
  if not pending then return end
  local p = self.game_state and self.game_state.players[self.local_player_index + 1]
  local spell_name = "Spell"
  if p and p.hand and pending.hand_index then
    local cid = p.hand[pending.hand_index]
    if cid then
      local ok_d, cdef = pcall(cards.get_card_def, cid)
      if ok_d and cdef and cdef.name then spell_name = cdef.name end
    end
  end
  self:_draw_top_combat_prompt(spell_name .. ": select a target", { 0.7, 0.4, 0.9, 0.85 }, { 0.9, 0.8, 1.0, 1.0 })
end

function GameState:_has_in_game_settings_blocker()
  if deck_viewer.is_open() then return true end
  if self.show_blueprint_for_player ~= nil then return true end
  if self.hand_selected_index ~= nil then return true end
  if self.drag ~= nil then return true end
  if type(self.prompt_stack) == "table" and #self.prompt_stack > 0 then return true end
  if #self.pending_attack_declarations > 0 then return true end
  if #self.pending_attack_trigger_targets > 0 then return true end
  if #self.pending_block_assignments > 0 then return true end
  if next(self.pending_damage_orders or {}) ~= nil then return true end
  return false
end

function GameState:_in_game_settings_layout()
  local gw, gh = love.graphics.getDimensions()
  local panel_w = math.max(280, math.min(460, gw - 32))
  local title_font = util.get_title_font(20)
  local body_font = util.get_font(12)
  local status_font = util.get_font(11)
  local value_font = util.get_font(12)
  local save_dir = (love.filesystem.getSaveDirectory and love.filesystem.getSaveDirectory()) or ""
  local default_status = "Replay exports are saved to " .. save_dir .. "/replays/"
  local status_text = tostring(self.in_game_settings_status or default_status)
  local status_wrap_w = math.max(80, panel_w - 28)
  local _, status_lines = status_font:getWrap(status_text, status_wrap_w)
  if #status_lines == 0 then status_lines = { status_text } end

  local volume_pct = util.clamp(tonumber(settings_store.values.sfx_volume) or 1.0, 0, 1)
  local fullscreen_on = settings_store.values.fullscreen == true

  local content_x = 14
  local content_w = panel_w - 28
  local label_w = 104
  local row_h = 34
  local control_y = 52
  local volume_row_y = control_y
  local slider_h = 8
  local slider_knob_r = 10
  local pct_w = 44
  local slider_x = content_x + label_w + 8
  local slider_w = math.max(80, content_w - label_w - 8 - pct_w)
  local slider_y = volume_row_y + math.floor((row_h - slider_h) / 2) + 1
  local slider_hit = {
    x = slider_x - slider_knob_r,
    y = slider_y - slider_knob_r,
    w = slider_w + slider_knob_r * 2,
    h = slider_h + slider_knob_r * 2,
  }

  local fullscreen_row_y = volume_row_y + row_h + 10
  local toggle_w, toggle_h = 84, 30
  local toggle_x = content_x + label_w + 8
  local toggle_y = fullscreen_row_y + math.floor((row_h - toggle_h) / 2)

  local button_h = 34
  local button_gap = 10
  local button_count = self.return_to_menu and 4 or 3
  local buttons_top = fullscreen_row_y + row_h + 14
  local panel_h = buttons_top + button_count * button_h + (button_count - 1) * button_gap + 20
    + 1 + 8 + (#status_lines * (status_font:getHeight() + 1)) + 14
  local panel_x = math.floor((gw - panel_w) / 2)
  local panel_y = math.floor((gh - panel_h) / 2)
  local button_x = panel_x + 14
  local button_w = panel_w - 28
  local button_y = panel_y + buttons_top

  local buttons = {
    report_bug = {
      x = button_x, y = button_y, w = button_w, h = button_h,
      label = "Report a Bug",
    },
  }
  button_y = button_y + button_h + button_gap

  buttons.export_replay = { x = button_x, y = button_y, w = button_w, h = button_h, label = "Export Replay JSON" }
  button_y = button_y + button_h + button_gap

  if self.return_to_menu then
    buttons.return_to_menu = { x = button_x, y = button_y, w = button_w, h = button_h, label = "Return to Menu" }
    button_y = button_y + button_h + button_gap
  end

  buttons.close = { x = button_x, y = button_y, w = button_w, h = button_h, label = "Close" }
  button_y = button_y + button_h

  local status_y = button_y + 14
  return {
    panel = { x = panel_x, y = panel_y, w = panel_w, h = panel_h },
    title_font = title_font,
    body_font = body_font,
    status_font = status_font,
    value_font = value_font,
    controls = {
      volume = {
        label = "SFX Volume",
        row = { x = panel_x + content_x, y = panel_y + volume_row_y, w = content_w, h = row_h },
        slider = { x = panel_x + slider_x, y = panel_y + slider_y, w = slider_w, h = slider_h },
        slider_hit = { x = panel_x + slider_hit.x, y = panel_y + slider_hit.y, w = slider_hit.w, h = slider_hit.h },
        knob_r = slider_knob_r,
        pct = volume_pct,
        pct_text = tostring(math.floor(volume_pct * 100 + 0.5)) .. "%",
        pct_x = panel_x + slider_x + slider_w + 10,
      },
      fullscreen = {
        label = "Fullscreen",
        row = { x = panel_x + content_x, y = panel_y + fullscreen_row_y, w = content_w, h = row_h },
        toggle = { x = panel_x + toggle_x, y = panel_y + toggle_y, w = toggle_w, h = toggle_h },
        value = fullscreen_on,
      },
    },
    buttons = buttons,
    status = {
      x = panel_x + 14,
      y = status_y + 9,
      w = panel_w - 28,
      text = status_text,
      lines = status_lines,
    },
  }
end

function GameState:_set_in_game_settings_status(text, kind)
  self.in_game_settings_status = tostring(text or "")
  self.in_game_settings_status_kind = kind or "info"
end

function GameState:_save_in_game_settings_if_dirty()
  if not self.in_game_settings_settings_dirty then return true end
  local ok_save, save_err = pcall(function() settings_store.save() end)
  if not ok_save then
    self:_set_in_game_settings_status("Settings save failed: " .. tostring(save_err), "error")
    return false
  end
  self.in_game_settings_settings_dirty = false
  return true
end

function GameState:_close_in_game_settings()
  self:_save_in_game_settings_if_dirty()
  self.in_game_settings_open = false
  self.in_game_settings_dragging_slider = false
  self.in_game_bug_report_open = false
end

function GameState:_open_in_game_settings()
  self.in_game_settings_open = true
  self.in_game_settings_dragging_slider = false
  self.in_game_settings_settings_dirty = false
  self.in_game_bug_report_open = false
  self.in_game_settings_status = nil
  self.in_game_settings_status_kind = "info"
end

function GameState:_set_in_game_settings_volume(pct)
  pct = util.clamp(tonumber(pct) or 0, 0, 1)
  settings_store.values.sfx_volume = pct
  sound.set_master_volume(pct)
  self.in_game_settings_settings_dirty = true
end

function GameState:_set_in_game_settings_volume_from_mouse_x(x, layout)
  local slider = layout and layout.controls and layout.controls.volume and layout.controls.volume.slider
  if not slider then return end
  local pct = (x - slider.x) / math.max(1, slider.w)
  self:_set_in_game_settings_volume(pct)
end

function GameState:_toggle_in_game_settings_fullscreen()
  local next_value = not (settings_store.values.fullscreen == true)
  local ok_fs, fs_err = pcall(function() love.window.setFullscreen(next_value) end)
  if not ok_fs then
    self:_set_in_game_settings_status("Fullscreen toggle failed: " .. tostring(fs_err), "error")
    return false
  end
  settings_store.values.fullscreen = next_value
  self.in_game_settings_settings_dirty = true
  self:_save_in_game_settings_if_dirty()
  return true
end

function GameState:_export_replay_json()
  local snapshot = self:get_command_log_snapshot()
  if type(snapshot) ~= "table" then
    self:_set_in_game_settings_status("Export failed: replay snapshot unavailable", "error")
    return false, nil, nil
  end

  local stamp = os.date("!%Y%m%d_%H%M%S")
  local source_tag = self.authoritative_adapter and "client" or "local"
  local filename = string.format("replays/replay_%s_p%d_%s.json", source_tag, tonumber(self.local_player_index) or 0, stamp)

  local ok_dir, dir_err = pcall(function() return love.filesystem.createDirectory("replays") end)
  if not ok_dir then
    self:_set_in_game_settings_status("Export failed: " .. tostring(dir_err), "error")
    return false, nil, nil
  end

  local ok_enc, encoded = pcall(json.encode, snapshot)
  if not ok_enc or type(encoded) ~= "string" then
    self:_set_in_game_settings_status("Export failed: could not encode replay JSON", "error")
    return false, nil, nil
  end

  local ok_write, write_ok_or_err = pcall(function()
    return love.filesystem.write(filename, encoded)
  end)
  if (not ok_write) or not write_ok_or_err then
    self:_set_in_game_settings_status("Export failed: " .. tostring(write_ok_or_err), "error")
    return false, nil, nil
  end

  local save_dir = (love.filesystem.getSaveDirectory and love.filesystem.getSaveDirectory()) or ""
  local full_path = (save_dir ~= "" and (save_dir .. "/" .. filename)) or filename
  self.in_game_settings_last_replay_export_path = full_path
  self:_set_in_game_settings_status("Replay exported: " .. full_path, "ok")
  return true, full_path, filename
end

function GameState:_set_in_game_bug_report_status(text, kind)
  self.in_game_bug_report_status = tostring(text or "")
  self.in_game_bug_report_status_kind = kind or "info"
end

function GameState:_open_in_game_bug_report_form()
  self.in_game_bug_report_open = true
  if type(self.in_game_bug_report_fields) ~= "table" then
    self.in_game_bug_report_fields = {}
  end
  for _, def in ipairs(IN_GAME_BUG_REPORT_FIELDS) do
    if type(self.in_game_bug_report_fields[def.id]) ~= "string" then
      self.in_game_bug_report_fields[def.id] = ""
    end
  end
  if type(self.in_game_bug_report_active_field) ~= "string" then
    self.in_game_bug_report_active_field = IN_GAME_BUG_REPORT_FIELDS[1].id
  end
  self:_set_in_game_bug_report_status("Fill out the form, then copy and paste it into Discord.", "info")
end

function GameState:_close_in_game_bug_report_form()
  self.in_game_bug_report_open = false
end

function GameState:_clear_in_game_bug_report_form()
  if type(self.in_game_bug_report_fields) ~= "table" then return end
  for _, def in ipairs(IN_GAME_BUG_REPORT_FIELDS) do
    self.in_game_bug_report_fields[def.id] = ""
  end
  self.in_game_bug_report_active_field = IN_GAME_BUG_REPORT_FIELDS[1].id
  self:_set_in_game_bug_report_status("Bug report form cleared.", "info")
end

function GameState:_in_game_bug_report_layout()
  local gw, gh = love.graphics.getDimensions()
  local panel_w = math.max(520, math.min(780, gw - 40))
  local title_font = util.get_title_font(20)
  local body_font = util.get_font(12)
  local field_font = util.get_font(12)
  local hint_font = util.get_font(11)
  local status_font = util.get_font(11)
  local button_font = util.get_font(12)

  local instructions_text =
    "Describe the issue, then click Copy Bug Report and paste it into Discord. " ..
    "Use Export Replay if you want to attach a replay JSON."
  local instructions_wrap_w = panel_w - 28
  local _, instruction_lines = hint_font:getWrap(instructions_text, instructions_wrap_w)
  if #instruction_lines == 0 then instruction_lines = { instructions_text } end

  local status_text = tostring(self.in_game_bug_report_status or "")
  local status_wrap_w = panel_w - 28
  local _, status_lines = status_font:getWrap(status_text, status_wrap_w)
  if #status_lines == 0 then status_lines = { status_text } end

  local rel_y = 16
  rel_y = rel_y + title_font:getHeight() + 6
  local instructions_y = rel_y
  rel_y = rel_y + #instruction_lines * (hint_font:getHeight() + 1) + 10

  local fields = {}
  local label_h = body_font:getHeight()
  for _, def in ipairs(IN_GAME_BUG_REPORT_FIELDS) do
    local label_y = rel_y
    local box_y = label_y + label_h + 4
    local box_h = def.height or (def.multiline and 72 or 34)
    fields[def.id] = {
      id = def.id,
      label = def.label,
      multiline = def.multiline == true,
      placeholder = def.placeholder,
      label_r = { x = 14, y = label_y, w = panel_w - 28, h = label_h },
      box_r = { x = 14, y = box_y, w = panel_w - 28, h = box_h },
    }
    rel_y = box_y + box_h + 10
  end

  local button_h = 34
  local button_gap = 10
  local button_count = 4
  local button_w = math.floor((panel_w - 28 - button_gap * (button_count - 1)) / button_count)
  local buttons_y = rel_y + 2
  local buttons = {
    copy = { x = 14, y = buttons_y, w = button_w, h = button_h, label = "Copy Bug Report" },
    export = { x = 14 + (button_w + button_gap), y = buttons_y, w = button_w, h = button_h, label = "Export Replay" },
    clear = { x = 14 + 2 * (button_w + button_gap), y = buttons_y, w = button_w, h = button_h, label = "Clear" },
    close = { x = 14 + 3 * (button_w + button_gap), y = buttons_y, w = button_w, h = button_h, label = "Close" },
  }
  rel_y = buttons_y + button_h + 12
  local status_y = rel_y
  rel_y = rel_y + 1 + 8 + (#status_lines * (status_font:getHeight() + 1)) + 10

  local panel_h = rel_y
  local panel_x = math.floor((gw - panel_w) / 2)
  local panel_y = math.floor((gh - panel_h) / 2)

  local function offset_rect(r)
    return { x = panel_x + r.x, y = panel_y + r.y, w = r.w, h = r.h }
  end
  for _, f in pairs(fields) do
    f.label_r = offset_rect(f.label_r)
    f.box_r = offset_rect(f.box_r)
  end
  for _, b in pairs(buttons) do
    local abs = offset_rect(b)
    b.x, b.y, b.w, b.h = abs.x, abs.y, abs.w, abs.h
  end

  return {
    panel = { x = panel_x, y = panel_y, w = panel_w, h = panel_h },
    title_font = title_font,
    body_font = body_font,
    field_font = field_font,
    hint_font = hint_font,
    status_font = status_font,
    button_font = button_font,
    instructions = {
      x = panel_x + 14,
      y = panel_y + instructions_y,
      w = panel_w - 28,
      text = instructions_text,
      lines = instruction_lines,
    },
    fields = fields,
    buttons = buttons,
    status = {
      x = panel_x + 14,
      y = panel_y + status_y + 9,
      w = panel_w - 28,
      text = status_text,
      lines = status_lines,
    },
  }
end

function GameState:_cycle_in_game_bug_report_field(direction)
  direction = (direction == -1) and -1 or 1
  local current_id = self.in_game_bug_report_active_field
  local idx = 1
  for i, def in ipairs(IN_GAME_BUG_REPORT_FIELDS) do
    if def.id == current_id then idx = i; break end
  end
  idx = idx + direction
  if idx < 1 then idx = #IN_GAME_BUG_REPORT_FIELDS end
  if idx > #IN_GAME_BUG_REPORT_FIELDS then idx = 1 end
  self.in_game_bug_report_active_field = IN_GAME_BUG_REPORT_FIELDS[idx].id
end

function GameState:_append_in_game_bug_report_text(text)
  if type(text) ~= "string" or text == "" then return end
  local field_id = self.in_game_bug_report_active_field
  if type(field_id) ~= "string" then return end
  self.in_game_bug_report_fields = self.in_game_bug_report_fields or {}
  local cur = self.in_game_bug_report_fields[field_id] or ""
  local next_value = cur .. text
  if #next_value > 2000 then
    next_value = next_value:sub(1, 2000)
    self:_set_in_game_bug_report_status("Field text capped at 2000 characters.", "info")
  end
  self.in_game_bug_report_fields[field_id] = next_value
end

function GameState:_backspace_in_game_bug_report_field()
  local field_id = self.in_game_bug_report_active_field
  if type(field_id) ~= "string" then return end
  self.in_game_bug_report_fields = self.in_game_bug_report_fields or {}
  local cur = self.in_game_bug_report_fields[field_id] or ""
  if cur == "" then return end
  self.in_game_bug_report_fields[field_id] = cur:sub(1, #cur - 1)
end

function GameState:_build_copyable_bug_report_text()
  local function trim_line(s)
    s = tostring(s or "")
    s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
    s = s:gsub("[\t]", " ")
    return s
  end
  local function clip_value(value, limit)
    local s = tostring(value == nil and "" or value)
    if #s <= limit then return s end
    return s:sub(1, math.max(0, limit - 3)) .. "..."
  end

  local fields = self.in_game_bug_report_fields or {}
  local summary = trim_line(fields.summary)
  local what_happened = trim_line(fields.what_happened)
  local expected = trim_line(fields.expected)
  local steps = trim_line(fields.steps)

  local mode = "local"
  if self.authoritative_adapter then
    if self.room_code then
      mode = "relay_multiplayer"
    elseif self.authoritative_adapter.poll then
      mode = "threaded_multiplayer"
    else
      mode = "authoritative_multiplayer"
    end
  end
  if self.server_step and not self.authoritative_adapter then
    mode = "local_host"
  end

  local g = self.game_state
  local local_player = g and g.players and g.players[(self.local_player_index or 0) + 1] or nil
  local entries = self.command_log and self.command_log.entries or nil
  local last_entry = (type(entries) == "table" and #entries > 0) and entries[#entries] or nil
  local adapter_checksum = self.authoritative_adapter and (
    self.authoritative_adapter._checksum
    or (self.authoritative_adapter.session and self.authoritative_adapter.session.last_checksum)
  ) or nil
  local adapter_state_seq = self.authoritative_adapter and (
    self.authoritative_adapter._state_seq
    or (self.authoritative_adapter.session and self.authoritative_adapter.session.last_state_seq)
  ) or nil
  local desync = self._last_desync_report

  local out = {
    "Build Version: protocol " .. tostring(config.protocol_version)
      .. " / rules " .. tostring(config.rules_version)
      .. " / content " .. tostring(config.content_version),
    "Mode: " .. mode,
    "Player Name: " .. tostring(settings_store and settings_store.values and settings_store.values.player_name or "Player"),
    "Local Player: P" .. tostring((self.local_player_index or 0) + 1),
    "Faction: " .. tostring(local_player and local_player.faction or "?"),
    "Turn: " .. tostring(g and g.turnNumber or "?"),
    "Active Player: " .. ((g and g.activePlayer ~= nil) and ("P" .. tostring(g.activePlayer + 1)) or "?"),
    "Room Code: " .. tostring(self.room_code or "N/A"),
    "Multiplayer Status: " .. tostring(self.multiplayer_status or "N/A"),
    "Disconnect Cause: " .. tostring(self.reconnect_reason or self._disconnect_message or "N/A"),
    "Authoritative State Seq: " .. tostring(adapter_state_seq or "N/A"),
    "Authoritative Checksum: " .. tostring(adapter_checksum or "N/A"),
    "Replay Export Path: " .. tostring(self.in_game_settings_last_replay_export_path or "N/A"),
  }
  if type(desync) == "table" then
    out[#out + 1] = "Last Desync: " .. tostring(desync.kind or "hash_mismatch")
    out[#out + 1] = "Last Desync Command: " .. tostring(desync.command_type or "N/A")
    out[#out + 1] = "Last Desync Seq: " .. tostring(desync.state_seq or "N/A")
  end
  if type(last_entry) == "table" then
    out[#out + 1] = "Last Command: "
      .. tostring(last_entry.command_type or "?")
      .. " / ok=" .. tostring(last_entry.ok)
      .. " / reason=" .. tostring(last_entry.reason)
      .. " / seq=" .. tostring(last_entry.seq or "?")
    out[#out + 1] = "Last Post-State Hash: " .. tostring(last_entry.post_state_hash or "N/A")
  end

  local function section(label, value)
    value = trim_line(value)
    if value == "" then value = "(not provided)" end
    out[#out + 1] = ""
    out[#out + 1] = label .. ":"
    for line in (value .. "\n"):gmatch("(.-)\n") do
      out[#out + 1] = line
    end
  end

  section("Summary", summary)
  section("What happened", what_happened)
  section("Expected behavior", expected)
  section("Steps to reproduce", steps)

  out[#out + 1] = ""
  out[#out + 1] = "Notes:"
  out[#out + 1] = "- Paste this in Discord and attach the replay JSON if available."

  local text = table.concat(out, "\n")
  if #text > 3800 then
    text = clip_value(text, 3800)
  end
  return text
end

function GameState:_copy_in_game_bug_report_to_clipboard()
  local text = self:_build_copyable_bug_report_text()
  local ok_copy, copy_err = pcall(function()
    if love.system and love.system.setClipboardText then
      return love.system.setClipboardText(text)
    end
    error("Clipboard API unavailable")
  end)
  if not ok_copy then
    self:_set_in_game_bug_report_status("Copy failed: " .. tostring(copy_err), "error")
    return false
  end
  self:_set_in_game_bug_report_status("Bug report copied. Paste it into Discord.", "ok")
  return true
end

function GameState:_draw_in_game_bug_report_overlay()
  if not self.in_game_bug_report_open then return end

  local layout = self:_in_game_bug_report_layout()
  local panel = layout.panel
  local mx, my = love.mouse.getPosition()

  love.graphics.setColor(0, 0, 0, 0.42)
  love.graphics.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())

  love.graphics.setColor(0.07, 0.08, 0.11, 0.98)
  love.graphics.rectangle("fill", panel.x, panel.y, panel.w, panel.h, 10, 10)
  love.graphics.setColor(0.45, 0.5, 0.63, 0.85)
  love.graphics.rectangle("line", panel.x, panel.y, panel.w, panel.h, 10, 10)
  love.graphics.setColor(0.95, 0.35, 0.35, 0.7)
  love.graphics.rectangle("fill", panel.x + 1, panel.y + 1, panel.w - 2, 3, 10, 10)

  love.graphics.setFont(layout.title_font)
  love.graphics.setColor(0.96, 0.97, 1.0, 1)
  love.graphics.print("Bug Report", panel.x + 14, panel.y + 12)

  love.graphics.setFont(layout.hint_font)
  love.graphics.setColor(0.72, 0.77, 0.88, 0.95)
  love.graphics.printf(layout.instructions.text, layout.instructions.x, layout.instructions.y, layout.instructions.w, "left")

  for _, def in ipairs(IN_GAME_BUG_REPORT_FIELDS) do
    local field = layout.fields[def.id]
    local box = field.box_r
    local active = (self.in_game_bug_report_active_field == def.id)
    local hovered = util.point_in_rect(mx, my, box.x, box.y, box.w, box.h)

    love.graphics.setFont(layout.body_font)
    love.graphics.setColor(0.88, 0.9, 0.97, 1)
    love.graphics.print(field.label, field.label_r.x, field.label_r.y)

    love.graphics.setColor(0.12, 0.13, 0.18, 0.98)
    love.graphics.rectangle("fill", box.x, box.y, box.w, box.h, 6, 6)
    if active then
      love.graphics.setColor(0.95, 0.35, 0.35, 0.95)
    elseif hovered then
      love.graphics.setColor(0.55, 0.6, 0.75, 0.8)
    else
      love.graphics.setColor(1, 1, 1, 0.14)
    end
    love.graphics.rectangle("line", box.x, box.y, box.w, box.h, 6, 6)

    local value = (self.in_game_bug_report_fields and self.in_game_bug_report_fields[def.id]) or ""
    local text_x = box.x + 8
    local text_y = box.y + 7
    local text_w = box.w - 16
    local text_h = box.h - 14
    love.graphics.setScissor(box.x + 2, box.y + 2, box.w - 4, box.h - 4)
    love.graphics.setFont(layout.field_font)
    if value == "" then
      love.graphics.setColor(0.55, 0.58, 0.66, 0.75)
      love.graphics.printf(field.placeholder or "", text_x, text_y, text_w, "left")
    else
      love.graphics.setColor(0.93, 0.95, 1.0, 1)
      love.graphics.printf(value, text_x, text_y, text_w, "left")
    end
    if active then
      local blink = (math.floor(love.timer.getTime() * 2) % 2 == 0)
      if blink then
        love.graphics.setColor(0.95, 0.35, 0.35, 0.85)
        love.graphics.rectangle("fill", box.x + 6, box.y + box.h - 4, box.w - 12, 1)
      end
    end
    love.graphics.setScissor()
  end

  local function draw_button(r, accent)
    local hovered = util.point_in_rect(mx, my, r.x, r.y, r.w, r.h)
    local fill = hovered and { accent[1], accent[2], accent[3], 0.24 } or { 0.16, 0.18, 0.24, 0.95 }
    local line = hovered and { accent[1], accent[2], accent[3], 0.95 } or { 0.35, 0.4, 0.52, 0.75 }
    love.graphics.setColor(fill[1], fill[2], fill[3], fill[4])
    love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 7, 7)
    love.graphics.setColor(line[1], line[2], line[3], line[4])
    love.graphics.rectangle("line", r.x, r.y, r.w, r.h, 7, 7)
    love.graphics.setFont(layout.button_font)
    love.graphics.setColor(0.93, 0.95, 1.0, 1)
    love.graphics.printf(r.label, r.x, r.y + 9, r.w, "center")
  end

  draw_button(layout.buttons.copy, { 0.25, 0.75, 0.95 })
  draw_button(layout.buttons.export, { 0.95, 0.7, 0.25 })
  draw_button(layout.buttons.clear, { 0.62, 0.66, 0.78 })
  draw_button(layout.buttons.close, { 0.95, 0.45, 0.45 })

  love.graphics.setColor(1, 1, 1, 0.08)
  love.graphics.rectangle("fill", panel.x + 14, layout.status.y - 8, panel.w - 28, 1)
  local status_color = { 0.74, 0.78, 0.86, 0.95 }
  if self.in_game_bug_report_status_kind == "ok" then
    status_color = { 0.58, 0.95, 0.68, 0.98 }
  elseif self.in_game_bug_report_status_kind == "error" then
    status_color = { 1.0, 0.5, 0.5, 0.98 }
  end
  love.graphics.setFont(layout.status_font)
  love.graphics.setColor(status_color[1], status_color[2], status_color[3], status_color[4])
  love.graphics.printf(layout.status.text, layout.status.x, layout.status.y, layout.status.w, "left")
end

function GameState:_handle_in_game_bug_report_click(x, y)
  if not self.in_game_bug_report_open then return false end
  local layout = self:_in_game_bug_report_layout()
  local panel = layout.panel

  if not util.point_in_rect(x, y, panel.x, panel.y, panel.w, panel.h) then
    self:_close_in_game_bug_report_form()
    sound.play("click")
    return true
  end

  for _, def in ipairs(IN_GAME_BUG_REPORT_FIELDS) do
    local field = layout.fields[def.id]
    local box = field and field.box_r
    if box and util.point_in_rect(x, y, box.x, box.y, box.w, box.h) then
      self.in_game_bug_report_active_field = def.id
      sound.play("click", 0.5)
      return true
    end
  end

  local b = layout.buttons
  if util.point_in_rect(x, y, b.copy.x, b.copy.y, b.copy.w, b.copy.h) then
    if self:_copy_in_game_bug_report_to_clipboard() then
      sound.play("coin")
    else
      sound.play("error")
    end
    return true
  end
  if util.point_in_rect(x, y, b.export.x, b.export.y, b.export.w, b.export.h) then
    local ok_export = self:_export_replay_json()
    if ok_export then
      self:_set_in_game_bug_report_status("Replay exported. You can now copy the report with the replay path included.", "ok")
      sound.play("coin")
    else
      self:_set_in_game_bug_report_status("Replay export failed. You can still copy the report text.", "error")
      sound.play("error")
    end
    return true
  end
  if util.point_in_rect(x, y, b.clear.x, b.clear.y, b.clear.w, b.clear.h) then
    self:_clear_in_game_bug_report_form()
    sound.play("click")
    return true
  end
  if util.point_in_rect(x, y, b.close.x, b.close.y, b.close.w, b.close.h) then
    self:_close_in_game_bug_report_form()
    sound.play("click")
    return true
  end

  return true
end

function GameState:_handle_in_game_bug_report_keypressed(key, scancode, isrepeat)
  if not self.in_game_bug_report_open then return false end

  local ctrl_down = love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")
  local shift_down = love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")
  local active_def = nil
  for _, def in ipairs(IN_GAME_BUG_REPORT_FIELDS) do
    if def.id == self.in_game_bug_report_active_field then
      active_def = def
      break
    end
  end

  if key == "escape" then
    self:_close_in_game_bug_report_form()
    sound.play("click")
    return true
  end
  if key == "tab" then
    self:_cycle_in_game_bug_report_field(shift_down and -1 or 1)
    sound.play("click", 0.5)
    return true
  end
  if key == "backspace" then
    self:_backspace_in_game_bug_report_field()
    return true
  end
  if ctrl_down and key == "v" then
    local ok_clip, clip = pcall(function()
      return love.system and love.system.getClipboardText and love.system.getClipboardText() or ""
    end)
    if ok_clip and type(clip) == "string" and clip ~= "" then
      self:_append_in_game_bug_report_text(clip)
      sound.play("click", 0.4)
    end
    return true
  end
  if ctrl_down and key == "c" then
    if self:_copy_in_game_bug_report_to_clipboard() then
      sound.play("coin")
    else
      sound.play("error")
    end
    return true
  end
  if key == "return" or key == "kpenter" then
    if active_def and active_def.multiline then
      self:_append_in_game_bug_report_text("\n")
    else
      self:_cycle_in_game_bug_report_field(1)
      sound.play("click", 0.4)
    end
    return true
  end

  return true -- swallow other keys while form is open
end

function GameState:_handle_in_game_bug_report_textinput(text)
  if not self.in_game_bug_report_open then return false end
  self:_append_in_game_bug_report_text(text)
  return true
end

function GameState:_draw_in_game_settings_overlay()
  if not self.in_game_settings_open then return end

  local layout = self:_in_game_settings_layout()
  local panel = layout.panel
  local mx, my = love.mouse.getPosition()

  love.graphics.setColor(0, 0, 0, 0.55)
  love.graphics.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())

  love.graphics.setColor(0.08, 0.09, 0.12, 0.97)
  love.graphics.rectangle("fill", panel.x, panel.y, panel.w, panel.h, 10, 10)
  love.graphics.setColor(0.34, 0.38, 0.5, 0.8)
  love.graphics.rectangle("line", panel.x, panel.y, panel.w, panel.h, 10, 10)
  love.graphics.setColor(0.25, 0.75, 0.95, 0.65)
  love.graphics.rectangle("fill", panel.x + 1, panel.y + 1, panel.w - 2, 3, 10, 10)

  love.graphics.setFont(layout.title_font)
  love.graphics.setColor(0.95, 0.97, 1.0, 1)
  love.graphics.print("Settings", panel.x + 14, panel.y + 12)

  love.graphics.setFont(layout.body_font)
  love.graphics.setColor(0.7, 0.74, 0.84, 0.95)
  love.graphics.print("Press Esc to close", panel.x + panel.w - 130, panel.y + 18)

  local controls = layout.controls
  if controls then
    local v = controls.volume
    local f = controls.fullscreen
    love.graphics.setFont(layout.body_font)
    love.graphics.setColor(0.85, 0.88, 0.96, 1)
    love.graphics.print(v.label, v.row.x, v.row.y + 8)
    love.graphics.print(f.label, f.row.x, f.row.y + 8)

    -- Volume slider
    love.graphics.setColor(0.18, 0.2, 0.28, 1)
    love.graphics.rectangle("fill", v.slider.x, v.slider.y, v.slider.w, v.slider.h, 4, 4)
    local fill_w = math.floor(v.slider.w * v.pct + 0.5)
    love.graphics.setColor(0.25, 0.75, 0.95, 0.85)
    love.graphics.rectangle("fill", v.slider.x, v.slider.y, fill_w, v.slider.h, 4, 4)
    local knob_x = v.slider.x + fill_w
    local knob_y = v.slider.y + v.slider.h / 2
    love.graphics.setColor(0.25, 0.75, 0.95, 1)
    love.graphics.circle("fill", knob_x, knob_y, v.knob_r)
    love.graphics.setColor(1, 1, 1, 0.28)
    love.graphics.circle("line", knob_x, knob_y, v.knob_r)
    love.graphics.setFont(layout.value_font)
    love.graphics.setColor(0.73, 0.77, 0.87, 1)
    love.graphics.print(v.pct_text, v.pct_x, v.row.y + 8)

    -- Fullscreen toggle
    if f.value then
      love.graphics.setColor(0.15, 0.55, 0.25, 1)
    else
      love.graphics.setColor(0.25, 0.25, 0.32, 1)
    end
    love.graphics.rectangle("fill", f.toggle.x, f.toggle.y, f.toggle.w, f.toggle.h, 6, 6)
    love.graphics.setColor(1, 1, 1, 0.22)
    love.graphics.rectangle("line", f.toggle.x, f.toggle.y, f.toggle.w, f.toggle.h, 6, 6)
    love.graphics.setFont(layout.value_font)
    love.graphics.setColor(0.95, 0.96, 1.0, 1)
    love.graphics.printf(f.value and "On" or "Off", f.toggle.x, f.toggle.y + 8, f.toggle.w, "center")
  end

  local function draw_button(r, accent)
    local disabled = r.disabled == true
    local hovered = (not disabled) and util.point_in_rect(mx, my, r.x, r.y, r.w, r.h)
    local fill = hovered and { accent[1], accent[2], accent[3], 0.24 } or { 0.16, 0.18, 0.24, 0.95 }
    local line = hovered and { accent[1], accent[2], accent[3], 0.95 } or { 0.35, 0.4, 0.52, 0.75 }
    if disabled then
      fill = { 0.13, 0.14, 0.18, 0.95 }
      line = { 0.24, 0.27, 0.34, 0.85 }
    end
    love.graphics.setColor(fill[1], fill[2], fill[3], fill[4])
    love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 7, 7)
    love.graphics.setColor(line[1], line[2], line[3], line[4])
    love.graphics.rectangle("line", r.x, r.y, r.w, r.h, 7, 7)
    love.graphics.setFont(util.get_font(12))
    if disabled then
      love.graphics.setColor(0.66, 0.7, 0.8, 0.95)
    else
      love.graphics.setColor(0.93, 0.95, 1.0, 1)
    end
    love.graphics.printf(r.label, r.x, r.y + 9, r.w, "center")
  end

  draw_button(layout.buttons.report_bug, { 0.95, 0.33, 0.33 })
  draw_button(layout.buttons.export_replay, { 0.25, 0.75, 0.95 })
  if layout.buttons.return_to_menu then
    draw_button(layout.buttons.return_to_menu, { 0.95, 0.55, 0.28 })
  end
  draw_button(layout.buttons.close, { 0.62, 0.66, 0.78 })

  love.graphics.setColor(1, 1, 1, 0.08)
  love.graphics.rectangle("fill", panel.x + 14, layout.status.y - 8, panel.w - 28, 1)

  local status_color = { 0.74, 0.78, 0.86, 0.95 }
  if self.in_game_settings_status_kind == "ok" then
    status_color = { 0.58, 0.95, 0.68, 0.98 }
  elseif self.in_game_settings_status_kind == "error" then
    status_color = { 1.0, 0.5, 0.5, 0.98 }
  end
  love.graphics.setFont(layout.status_font)
  love.graphics.setColor(status_color[1], status_color[2], status_color[3], status_color[4])
  love.graphics.printf(layout.status.text, layout.status.x, layout.status.y, layout.status.w, "left")

  self:_draw_in_game_bug_report_overlay()
end

function GameState:_handle_in_game_settings_click(x, y)
  if not self.in_game_settings_open then return false end
  if self.in_game_bug_report_open then
    return self:_handle_in_game_bug_report_click(x, y)
  end
  local layout = self:_in_game_settings_layout()
  local panel = layout.panel

  if not util.point_in_rect(x, y, panel.x, panel.y, panel.w, panel.h) then
    self:_close_in_game_settings()
    sound.play("click")
    return true
  end

  local controls = layout.controls
  if controls then
    if util.point_in_rect(
        x, y,
        controls.volume.slider_hit.x, controls.volume.slider_hit.y,
        controls.volume.slider_hit.w, controls.volume.slider_hit.h
      ) then
      self.in_game_settings_dragging_slider = true
      self:_set_in_game_settings_volume_from_mouse_x(x, layout)
      sound.play("click", 0.5)
      return true
    end
    if util.point_in_rect(
        x, y,
        controls.fullscreen.toggle.x, controls.fullscreen.toggle.y,
        controls.fullscreen.toggle.w, controls.fullscreen.toggle.h
      ) then
      if self:_toggle_in_game_settings_fullscreen() then
        sound.play("click")
      else
        sound.play("error")
      end
      return true
    end
  end

  if layout.buttons.report_bug and util.point_in_rect(
      x, y,
      layout.buttons.report_bug.x, layout.buttons.report_bug.y,
      layout.buttons.report_bug.w, layout.buttons.report_bug.h
    ) then
    self:_open_in_game_bug_report_form()
    sound.play("click")
    return true
  end

  if util.point_in_rect(x, y, layout.buttons.export_replay.x, layout.buttons.export_replay.y, layout.buttons.export_replay.w, layout.buttons.export_replay.h) then
    if self:_export_replay_json() then
      sound.play("coin")
    else
      sound.play("error")
    end
    return true
  end

  if layout.buttons.return_to_menu and util.point_in_rect(
      x, y,
      layout.buttons.return_to_menu.x, layout.buttons.return_to_menu.y,
      layout.buttons.return_to_menu.w, layout.buttons.return_to_menu.h
    ) then
    self:_close_in_game_settings()
    if self.server_cleanup then
      pcall(self.server_cleanup)
      self.server_step = nil
      self.server_cleanup = nil
    end
    if self.return_to_menu then
      sound.play("click")
      self.return_to_menu()
    else
      sound.play("error")
    end
    return true
  end

  if util.point_in_rect(x, y, layout.buttons.close.x, layout.buttons.close.y, layout.buttons.close.w, layout.buttons.close.h) then
    self:_close_in_game_settings()
    sound.play("click")
    return true
  end

  return true -- click inside modal, swallow it
end

function GameState:draw()
  shake.apply()

  self:_prune_invalid_pending_attacks()
  local prompt_board_draw = self:_build_prompt_board_draw_fields()

  -- Build hand_state for board.draw
  local hand_state = {
    hover_index = self.hand_hover_index,
    selected_index = self.hand_selected_index,
    y_offsets = self.hand_y_offsets,
    eligible_hand_indices = prompt_board_draw.eligible_hand_indices,
    sacrifice_eligible_indices = prompt_board_draw.sacrifice_eligible_indices,
    sacrifice_allow_workers = prompt_board_draw.sacrifice_allow_workers,
    monument_eligible_indices = prompt_board_draw.monument_eligible_indices,
    counter_target_eligible_indices = prompt_board_draw.counter_target_eligible_indices,
    damage_target_eligible_player_index = prompt_board_draw.damage_target_eligible_player_index,
    damage_target_eligible_indices = prompt_board_draw.damage_target_eligible_indices,
    damage_target_board_indices_by_player = prompt_board_draw.damage_target_board_indices_by_player,
    damage_target_base_player_indices = prompt_board_draw.damage_target_base_player_indices,
    pending_attack_declarations = self.pending_attack_declarations,
    pending_block_assignments = self.pending_block_assignments,
    pending_attack_trigger_targets = self.pending_attack_trigger_targets,
    discard_selected_set = prompt_board_draw.discard_selected_set,
  }
  board.draw(self.game_state, self.drag, self.hover, self.mouse_down, self.display_resources, hand_state, self.local_player_index)
  self:_draw_attack_declaration_arrows()
  self:_draw_attack_trigger_targeting_overlay()
  self:_draw_combat_priority_overlay()
  self:_draw_prompt_overlays()

  -- Ambient particles (drawn on top of panels but below UI overlays)
  local active_player = self.game_state.players[self.game_state.activePlayer + 1]
  local faction_info = factions_data[active_player.faction]
  local accent_color = faction_info and faction_info.color or nil
  particles.draw(accent_color)

  -- Feature 2: Draw returning workers (snap-back animation)
  for _, rw in ipairs(self.returning_workers) do
    local r = board.WORKER_R
    local draw_r = r * (rw.scale or 1)
    local a = rw.alpha or 1
    love.graphics.setColor(0, 0, 0, 0.35 * a)
    love.graphics.circle("fill", rw.x + 2, rw.y + 3, draw_r + 2)
    love.graphics.setColor(0.9, 0.9, 1.0, a)
    love.graphics.circle("fill", rw.x, rw.y, draw_r)
    love.graphics.setColor(0.5, 0.55, 1.0, a * 0.8)
    love.graphics.setLineWidth(1.5)
    love.graphics.circle("line", rw.x, rw.y, draw_r)
    love.graphics.setLineWidth(1)
  end

  -- Dragged worker / unit follows cursor (drawn on top so it's always visible)
  if self.drag and self.drag.from ~= "attack_unit" and self.drag.from ~= "block_unit" and self.drag.from ~= "order_attacker" then
    local dx, dy = self.drag.display_x, self.drag.display_y
    local r = board.WORKER_R
    local drag_r = r * 1.2
    -- Soft shadow (offset) for a lifted look
    love.graphics.setColor(0, 0, 0, 0.45)
    love.graphics.circle("fill", dx + 3, dy + 5, drag_r + 3)
    if self.drag.from == "special" or self.drag.from == "special_field" then
      -- Gold special worker
      love.graphics.setColor(1.0, 0.85, 0.3, 1.0)
      love.graphics.circle("fill", dx, dy, drag_r)
      love.graphics.setColor(0.85, 0.65, 0.1, 1.0)
      love.graphics.setLineWidth(2)
      love.graphics.circle("line", dx, dy, drag_r)
      love.graphics.setLineWidth(1)
    else
      -- Main fill (slightly brighter when dragging)
      love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
      love.graphics.circle("fill", dx, dy, drag_r)
      -- Outline
      love.graphics.setColor(0.5, 0.55, 1.0, 1.0)
      love.graphics.setLineWidth(2)
      love.graphics.circle("line", dx, dy, drag_r)
      love.graphics.setLineWidth(1)
    end
  end

  if deck_viewer.is_open() then
    deck_viewer.draw()
  end
  shake.release()

  if not deck_viewer.is_open() then
    popup.draw()

    -- Structure tooltip (Feature 5: only show after 0.3s hover delay)
    if self.hover and self.hover.kind == "structure" and self.tooltip_timer >= 0.3 then
      local pi = self.hover.pi
      local si = self.hover.idx
      local player = self.game_state.players[pi + 1]
      local entry
      if si == 0 then
        entry = { card_id = player.baseId }
      else
        entry = player and player.board[si]
      end
      if entry then
        local ok, def = pcall(cards.get_card_def, entry.card_id)
        if ok and def then
          local preview_attack = def.attack
          local preview_health = def.health or def.baseHealth
          if si ~= 0 and (def.kind == "Unit" or def.kind == "Worker") then
            local est = entry.state or {}
            preview_attack = unit_stats.effective_attack(def, est, self.game_state, pi)
            preview_health = unit_stats.effective_health(def, est, self.game_state, pi)
          end
          local mx, my = love.mouse.getPosition()
          local gw, gh = love.graphics.getDimensions()
          -- Enlarged preview with ability text
          local aspect = card_frame.FULL_CARD_ASPECT_H_OVER_W or (3.5 / 2.5)
          local max_tw = math.max(80, gw - 20)
          local max_th = math.max(120, gh - 20)
          local tw = math.max(80, math.min(200, max_tw, math.floor(max_th / aspect + 0.5)))
          local th = card_frame.measure_full_height({
            w = tw,
            faction = def.faction,
            upkeep = def.upkeep,
            abilities_list = def.abilities,
            text = def.text,
          })

          local tx = mx + 16
          local ty = my - th / 2
          if tx + tw > gw - 10 then tx = mx - tw - 16 end
          if ty < 10 then ty = 10 end
          if ty + th > gh - 10 then ty = gh - th - 10 end

          -- Build ability state for the tooltip
          local used_abs, can_act_abs = {}, {}
          if def.abilities then
            for ai, ab in ipairs(def.abilities) do
              if ab.type == "activated" then
                local source_key = "board:" .. si .. ":" .. ai
                local used = abilities.is_activated_ability_used_this_turn(
                  self.game_state,
                  pi,
                  source_key,
                  { type = "board", index = si },
                  ai
                )
                used_abs[ai] = used or false
                local board_entry = player.board[si]
                local _cbt_tt = self.game_state.pendingCombat
                local _in_blk_tt = _cbt_tt and _cbt_tt.stage == "DECLARED"
                  and (pi == _cbt_tt.attacker or pi == _cbt_tt.defender)
                local can_pay_ab = abilities.can_pay_activated_ability_costs(player.resources, ab, {
                  source_entry = board_entry,
                  require_variable_min = true,
                })
                local sel_info = abilities.collect_activated_selection_cost_targets(self.game_state, pi, ab)
                local has_sel_targets = true
                if sel_info and sel_info.requires_selection then
                  has_sel_targets = sel_info.has_any_target == true
                end
                can_act_abs[ai] = (not used or not ab.once_per_turn) and can_pay_ab
                  and (pi == self.game_state.activePlayer or (ab.fast and _in_blk_tt))
                  and (ab.effect ~= "discard_draw" or #player.hand >= (ab.effect_args and ab.effect_args.discard or 2))
                  and has_sel_targets
              end
            end
          end

          -- Fade in over 0.15s after the delay
          local fade_in = math.min(1, (self.tooltip_timer - 0.3) / 0.15)
          love.graphics.setColor(0, 0, 0, 0.6 * fade_in)
          love.graphics.rectangle("fill", tx - 4, ty - 4, tw + 8, th + 8, 8, 8)
          love.graphics.push()
          love.graphics.setColor(1, 1, 1, fade_in)
          card_frame.draw(tx, ty, {
            w = tw,
            h = th,
            title = def.name,
            faction = def.faction,
            kind = def.kind,
            subtypes = def.subtypes or {},
            text = def.text,
            costs = def.costs,
            upkeep = def.upkeep,
            attack = preview_attack,
            health = preview_health,
            tier = def.tier,
            abilities_list = def.abilities,
            used_abilities = used_abs,
            can_activate_abilities = can_act_abs,
            show_ability_text = true,
            counters = entry.state and unit_stats.all_counters(entry.state),
          })
          love.graphics.pop()
        end
      end
    end

    -- Regular worker tooltip (show tier 0 worker card for this faction)
    if self.hover and (self.hover.kind == "worker_unassigned" or self.hover.kind == "worker_left"
       or self.hover.kind == "worker_right" or self.hover.kind == "structure_worker") and self.tooltip_timer >= 0.3 then
      local pi = self.hover.pi
      local player = self.game_state.players[pi + 1]
      if player then
        -- Find the tier 0 worker card for this faction
        local worker_defs = cards.filter({ kind = "Worker", faction = player.faction })
        local def = nil
        for _, wd in ipairs(worker_defs) do
          if wd.tier == 0 and not wd.deckable then
            def = wd
            break
          end
        end
        if def then
          local mx, my = love.mouse.getPosition()
          local gw, gh = love.graphics.getDimensions()
          local aspect = card_frame.FULL_CARD_ASPECT_H_OVER_W or (3.5 / 2.5)
          local max_tw = math.max(80, gw - 20)
          local max_th = math.max(120, gh - 20)
          local tw = math.max(80, math.min(200, max_tw, math.floor(max_th / aspect + 0.5)))
          local th = card_frame.measure_full_height({
            w = tw, faction = def.faction, upkeep = def.upkeep,
            abilities_list = def.abilities, text = def.text,
          })
          local tx = mx + 16
          local ty = my - th / 2
          if tx + tw > gw - 10 then tx = mx - tw - 16 end
          if ty < 10 then ty = 10 end
          if ty + th > gh - 10 then ty = gh - th - 10 end

          local fade_in = math.min(1, (self.tooltip_timer - 0.3) / 0.15)
          love.graphics.setColor(0, 0, 0, 0.6 * fade_in)
          love.graphics.rectangle("fill", tx - 4, ty - 4, tw + 8, th + 8, 8, 8)
          love.graphics.push()
          love.graphics.setColor(1, 1, 1, fade_in)
          card_frame.draw(tx, ty, {
            w = tw,
            h = th,
            title = def.name,
            faction = def.faction,
            kind = def.kind,
            subtypes = def.subtypes or {},
            text = def.text,
            costs = def.costs,
            upkeep = def.upkeep,
            attack = def.attack,
            health = def.health or def.baseHealth,
            tier = def.tier,
            abilities_list = def.abilities,
            show_ability_text = true,
          })
          love.graphics.pop()
        end
      end
    end

    -- Special worker tooltip (show card preview on hover)
    if self.hover and (self.hover.kind == "special_worker_unassigned"
       or self.hover.kind == "special_worker_resource"
       or self.hover.kind == "special_worker_structure") and self.tooltip_timer >= 0.3 then
      local pi = self.hover.pi
      local sw_index = self.hover.idx
      local player = self.game_state.players[pi + 1]
      local sw = player and player.specialWorkers and player.specialWorkers[sw_index]
      if sw then
        local ok, def = pcall(cards.get_card_def, sw.card_id)
        if ok and def then
          local mx, my = love.mouse.getPosition()
          local gw, gh = love.graphics.getDimensions()
          local aspect = card_frame.FULL_CARD_ASPECT_H_OVER_W or (3.5 / 2.5)
          local max_tw = math.max(80, gw - 20)
          local max_th = math.max(120, gh - 20)
          local tw = math.max(80, math.min(200, max_tw, math.floor(max_th / aspect + 0.5)))
          local th = card_frame.measure_full_height({
            w = tw, faction = def.faction, upkeep = def.upkeep,
            abilities_list = def.abilities, text = def.text,
          })
          local tx = mx + 16
          local ty = my - th / 2
          if tx + tw > gw - 10 then tx = mx - tw - 16 end
          if ty < 10 then ty = 10 end
          if ty + th > gh - 10 then ty = gh - th - 10 end

          local fade_in = math.min(1, (self.tooltip_timer - 0.3) / 0.15)
          love.graphics.setColor(0, 0, 0, 0.6 * fade_in)
          love.graphics.rectangle("fill", tx - 4, ty - 4, tw + 8, th + 8, 8, 8)
          love.graphics.push()
          love.graphics.setColor(1, 1, 1, fade_in)
          card_frame.draw(tx, ty, {
            w = tw,
            h = th,
            title = def.name,
            faction = def.faction,
            kind = def.kind,
            subtypes = def.subtypes or {},
            text = def.text,
            costs = def.costs,
            upkeep = def.upkeep,
            attack = def.attack,
            health = def.health or def.baseHealth,
            tier = def.tier,
            abilities_list = def.abilities,
            show_ability_text = true,
          })
          love.graphics.pop()
        end
      end
    end

    -- Ability button tooltip (full text panel for activated abilities)
    if self.hover and (self.hover.kind == "ability_hover" or self.hover.kind == "activate_ability")
       and type(self.hover.idx) == "table" and self.tooltip_timer >= 0.3 then
      local pi = self.hover.pi
      local info = self.hover.idx
      local player = self.game_state.players[pi + 1]
      -- Resolve the ability from either a board structure or the base
      local ab = nil
      if player and info.source == "board" then
        local entry = player.board[info.board_index]
        if entry then
          local ok_d, def = pcall(cards.get_card_def, entry.card_id)
          if ok_d and def and def.abilities then
            ab = def.abilities[info.ability_index]
          end
        end
      elseif player and info.source == "base" then
        local ok_d, def = pcall(cards.get_card_def, player.baseId)
        if ok_d and def and def.abilities then
          ab = def.abilities[info.ability_index]
        end
      end
      if ab then
        local mx, my = love.mouse.getPosition()
        local gw, gh = love.graphics.getDimensions()
        local body_text = tostring(ab.text or card_frame.ability_effect_text(ab) or "")
        local header_text = (ab.label and tostring(ab.label) ~= "" and tostring(ab.label)) or "Activated Ability"
        local can_activate_now = (self.hover.kind == "activate_ability")
        local status_text = can_activate_now and "Usable Now" or "Not Usable"

        local function title_case_resource(key)
          key = tostring(key or "?")
          if key == "" then return "?" end
          return key:sub(1, 1):upper() .. key:sub(2)
        end

        local cost_parts = {}
        for _, c in ipairs(ab.cost or {}) do
          cost_parts[#cost_parts + 1] = tostring(c.amount or 0) .. " " .. title_case_resource(c.type)
        end
        local cost_text = (#cost_parts > 0) and ("Cost: " .. table.concat(cost_parts, " + ")) or "Cost: Free"

        local detail_parts = {}
        if ab.fast then detail_parts[#detail_parts + 1] = "Fast" end
        if ab.once_per_turn then detail_parts[#detail_parts + 1] = "Once per turn" end
        if ab.rest then detail_parts[#detail_parts + 1] = "Requires ready unit" end
        local detail_text = (#detail_parts > 0) and table.concat(detail_parts, "  |  ") or nil

        local header_font = util.get_title_font(12)
        local body_font = util.get_font(11)
        local meta_font = util.get_font(9)
        local chip_font = util.get_font(8)

        local pad_x, pad_y = 12, 10
        local inner_w = math.max(200, math.min(340, gw - 36) - pad_x * 2)
        local tw = inner_w + pad_x * 2

        local _, body_lines = body_font:getWrap(body_text, inner_w)
        if #body_lines == 0 then body_lines = { body_text } end
        local _, cost_lines = meta_font:getWrap(cost_text, inner_w)
        if #cost_lines == 0 then cost_lines = { cost_text } end
        local detail_lines = {}
        if detail_text and detail_text ~= "" then
          local _, wrapped = meta_font:getWrap(detail_text, inner_w)
          detail_lines = (#wrapped > 0) and wrapped or { detail_text }
        end

        local header_h = header_font:getHeight()
        local chip_w = chip_font:getWidth(status_text) + 12
        local chip_h = chip_font:getHeight() + 4
        local body_line_h = body_font:getHeight() + 1
        local meta_line_h = meta_font:getHeight() + 1
        local divider_h = 1
        local section_gap = 6

        local body_h = #body_lines * body_line_h
        local meta_h = #cost_lines * meta_line_h
        if #detail_lines > 0 then
          meta_h = meta_h + 3 + (#detail_lines * meta_line_h)
        end

        local th = pad_y
          + math.max(header_h, chip_h)
          + section_gap
          + divider_h
          + section_gap
          + meta_h
          + section_gap
          + divider_h
          + section_gap
          + body_h
          + pad_y

        local tx = mx + 16
        local ty = my - th - 8
        if tx + tw > gw - 10 then tx = mx - tw - 16 end
        if ty < 10 then ty = my + 14 end
        if ty + th > gh - 10 then ty = gh - th - 10 end
        if tx < 10 then tx = 10 end

        local fade_in = math.min(1, (self.tooltip_timer - 0.3) / 0.15)
        local corner = 7
        local accent = can_activate_now and { 0.25, 0.8, 0.45 } or { 0.45, 0.5, 0.62 }

        -- Shadow/backdrop
        love.graphics.setColor(0, 0, 0, 0.45 * fade_in)
        love.graphics.rectangle("fill", tx + 3, ty + 4, tw, th, corner, corner)
        -- Panel body
        love.graphics.setColor(0.06, 0.07, 0.1, 0.95 * fade_in)
        love.graphics.rectangle("fill", tx, ty, tw, th, corner, corner)
        -- Accent strip
        love.graphics.setColor(accent[1], accent[2], accent[3], 0.8 * fade_in)
        love.graphics.rectangle("fill", tx + 1, ty + 1, tw - 2, 3, corner, corner)
        -- Border
        love.graphics.setColor(0.3, 0.35, 0.5, 0.6 * fade_in)
        love.graphics.rectangle("line", tx, ty, tw, th, corner, corner)

        local cy = ty + pad_y

        -- Header row
        love.graphics.setFont(header_font)
        love.graphics.setColor(0.94, 0.96, 1.0, fade_in)
        love.graphics.print(header_text, tx + pad_x, cy)

        local chip_x = tx + tw - pad_x - chip_w
        local chip_y = cy + math.floor((header_h - chip_h) / 2)
        love.graphics.setColor(0, 0, 0, 0.2 * fade_in)
        love.graphics.rectangle("fill", chip_x + 1, chip_y + 1, chip_w, chip_h, 4, 4)
        love.graphics.setColor(accent[1], accent[2], accent[3], (can_activate_now and 0.28 or 0.18) * fade_in + 0.05)
        love.graphics.rectangle("fill", chip_x, chip_y, chip_w, chip_h, 4, 4)
        love.graphics.setColor(accent[1], accent[2], accent[3], 0.85 * fade_in)
        love.graphics.rectangle("line", chip_x, chip_y, chip_w, chip_h, 4, 4)
        love.graphics.setFont(chip_font)
        love.graphics.setColor(1, 1, 1, fade_in)
        love.graphics.printf(status_text, chip_x, chip_y + 2, chip_w, "center")

        cy = cy + math.max(header_h, chip_h) + section_gap

        -- Divider 1
        love.graphics.setColor(accent[1], accent[2], accent[3], 0.22 * fade_in)
        love.graphics.rectangle("fill", tx + pad_x, cy, inner_w, 1)
        cy = cy + divider_h + section_gap

        -- Meta section (cost + traits)
        love.graphics.setFont(meta_font)
        love.graphics.setColor(0.74, 0.77, 0.86, fade_in)
        for _, line in ipairs(cost_lines) do
          love.graphics.print(line, tx + pad_x, cy)
          cy = cy + meta_line_h
        end
        if #detail_lines > 0 then
          cy = cy + 3
          love.graphics.setColor(0.62, 0.66, 0.76, fade_in)
          for _, line in ipairs(detail_lines) do
            love.graphics.print(line, tx + pad_x, cy)
            cy = cy + meta_line_h
          end
        end

        cy = cy + section_gap
        -- Divider 2
        love.graphics.setColor(1, 1, 1, 0.08 * fade_in)
        love.graphics.rectangle("fill", tx + pad_x, cy, inner_w, 1)
        cy = cy + divider_h + section_gap

        -- Body text (full ability text, wrapped)
        love.graphics.setFont(body_font)
        love.graphics.setColor(0.88, 0.9, 0.96, fade_in)
        for _, line in ipairs(body_lines) do
          love.graphics.print(line, tx + pad_x, cy)
          cy = cy + body_line_h
        end
      end
    end

    -- Unit deck / graveyard tooltip (shows zone count on hover)
    if self.hover and (self.hover.kind == "unit_deck" or self.hover.kind == "graveyard") and self.tooltip_timer >= 0.3 then
      local pi = self.hover.pi
      local player = self.game_state.players[pi + 1]
      if player then
        local zone_label
        local zone_count
        if self.hover.kind == "graveyard" then
          zone_label = "Cards in graveyard: "
          zone_count = #(player.graveyard or {})
        else
          zone_label = "Cards in deck: "
          zone_count = #(player.deck or {})
        end
        local mx, my = love.mouse.getPosition()
        local gw, gh = love.graphics.getDimensions()
        local label = zone_label .. tostring(zone_count)
        local font = util.get_font(11)
        local text_w = font:getWidth(label)
        local pad_x, pad_y = 12, 8
        local tw = text_w + pad_x * 2
        local th = font:getHeight() + pad_y * 2
        local tx = mx + 16
        local ty = my - th - 4
        if tx + tw > gw - 10 then tx = mx - tw - 16 end
        if ty < 10 then ty = 10 end
        -- Fade in over 0.15s after the delay
        local fade_in = math.min(1, (self.tooltip_timer - 0.3) / 0.15)
        love.graphics.setColor(0.08, 0.09, 0.13, 0.92 * fade_in)
        love.graphics.rectangle("fill", tx, ty, tw, th, 6, 6)
        love.graphics.setColor(0.35, 0.37, 0.5, 0.5 * fade_in)
        love.graphics.rectangle("line", tx, ty, tw, th, 6, 6)
        love.graphics.setFont(font)
        love.graphics.setColor(0.85, 0.87, 0.95, fade_in)
        love.graphics.printf(label, tx, ty + pad_y, tw, "center")
      end
    end

    -- (Status bar removed -- player info visible from board layout)
  end

  -- Turn transition banner overlay
  if self.turn_banner_timer > 0 then
    local gw, gh = love.graphics.getDimensions()
    local total_duration = 1.2
    local t = self.turn_banner_timer
    -- Fade in first 0.3s, hold, fade out last 0.3s
    local alpha = 1.0
    local elapsed = total_duration - t
    if elapsed < 0.3 then
      alpha = elapsed / 0.3
    elseif t < 0.3 then
      alpha = t / 0.3
    end
    -- Dark overlay
    love.graphics.setColor(0, 0, 0, 0.5 * alpha)
    love.graphics.rectangle("fill", 0, gh / 2 - 40, gw, 80)
    -- Banner text (title font)
    love.graphics.setFont(util.get_title_font(28))
    love.graphics.setColor(1, 1, 1, alpha)
    love.graphics.printf(self.turn_banner_text, 0, gh / 2 - 16, gw, "center")
  end

  -- Disconnect banner overlay
  if self._disconnect_message then
    local gw, gh = love.graphics.getDimensions()
    local alpha = math.min(1, (3.0 - (self._disconnect_timer or 0)) / 0.3)
    -- Dark overlay
    love.graphics.setColor(0, 0, 0, 0.65 * alpha)
    love.graphics.rectangle("fill", 0, gh / 2 - 50, gw, 100)
    -- Red accent line
    love.graphics.setColor(0.8, 0.2, 0.2, 0.8 * alpha)
    love.graphics.rectangle("fill", 0, gh / 2 - 50, gw, 3)
    -- Message
    love.graphics.setFont(util.get_title_font(24))
    love.graphics.setColor(1, 0.3, 0.3, alpha)
    love.graphics.printf(self._disconnect_message, 0, gh / 2 - 20, gw, "center")
    -- Subtitle
    love.graphics.setFont(util.get_font(12))
    love.graphics.setColor(0.7, 0.7, 0.8, alpha * 0.8)
    love.graphics.printf("Returning to menu...", 0, gh / 2 + 14, gw, "center")
  end

  if self.game_state and self.game_state.is_terminal then
    local gw, gh = love.graphics.getDimensions()
    local title = terminal_title_for_player(self.game_state, self.local_player_index) or "Match Ended"
    local title_color = { 0.9, 0.9, 0.95 }
    if title == "Victory" then
      title_color = { 0.45, 1.0, 0.6 }
    elseif title == "Defeat" then
      title_color = { 1.0, 0.35, 0.35 }
    end

    local reason = tostring(self.game_state.reason or "base_destroyed"):gsub("_", " ")
    local subtitle = "Reason: " .. reason
    local hint = self.return_to_menu and "Press Esc for settings (Return to Menu is inside)" or "Match complete"

    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", 0, gh / 2 - 70, gw, 140)
    love.graphics.setFont(util.get_title_font(30))
    love.graphics.setColor(title_color[1], title_color[2], title_color[3], 1)
    love.graphics.printf(title, 0, gh / 2 - 44, gw, "center")
    love.graphics.setFont(util.get_font(13))
    love.graphics.setColor(0.82, 0.84, 0.9, 1)
    love.graphics.printf(subtitle, 0, gh / 2 + 2, gw, "center")
    love.graphics.setColor(0.7, 0.72, 0.8, 0.95)
    love.graphics.printf(hint, 0, gh / 2 + 24, gw, "center")
  end

  if self.multiplayer_status then
    local status_font = util.get_font(11)
    local status_text = self.multiplayer_status
    if self.room_code then
      status_text = status_text .. "  |  Room: " .. self.room_code
    end
    local pad_x, pad_y = 10, 6
    local max_box_w = math.min(460, love.graphics.getWidth() - 24)
    if max_box_w < 180 then max_box_w = love.graphics.getWidth() - 24 end
    local min_box_w = math.min(96, max_box_w)
    local _, wrapped_lines = status_font:getWrap(status_text, math.max(1, max_box_w - pad_x * 2))
    local widest_line = 0
    for _, line in ipairs(wrapped_lines or {}) do
      widest_line = math.max(widest_line, status_font:getWidth(line))
    end
    local box_w = math.min(max_box_w, math.max(min_box_w, widest_line + pad_x * 2))
    local line_count = math.max(1, #(wrapped_lines or {}))
    local box_h = status_font:getHeight() * line_count + pad_y * 2
    local box_x = 12
    local box_y = love.graphics.getHeight() - box_h - 12
    love.graphics.setColor(0.08, 0.09, 0.13, 0.7)
    love.graphics.rectangle("fill", box_x, box_y, box_w, box_h, 6, 6)
    love.graphics.setColor(1, 1, 1, 0.92)
    love.graphics.setFont(status_font)
    love.graphics.printf(status_text, box_x + pad_x, box_y + pad_y, box_w - pad_x * 2, "left")
  end

  -- Vignette: drawn last, on top of everything
  textures.draw_vignette()
  self:_draw_in_game_settings_overlay()
end


local function is_worker_board_entry(game_state, pi, board_index)
  local player = game_state.players[pi + 1]
  local entry = player and player.board and player.board[board_index]
  if not entry then return false end
  local ok, def = pcall(cards.get_card_def, entry.card_id)
  return ok and def and def.kind == "Worker"
end

local function upgrade_required_subtypes(effect_args)
  local args = effect_args or {}
  if type(args.subtypes) == "table" and #args.subtypes > 0 then
    return args.subtypes
  end
  return { "Warrior" }
end

local function has_any_subtype(card_def, required_subtypes)
  if not card_def or type(card_def.subtypes) ~= "table" then
    return false
  end
  for _, req in ipairs(required_subtypes or {}) do
    for _, got in ipairs(card_def.subtypes) do
      if req == got then
        return true
      end
    end
  end
  return false
end

local function find_upgrade_hand_indices(player, effect_args, target_tier)
  local out = {}
  local required_subtypes = upgrade_required_subtypes(effect_args)
  for hi, card_id in ipairs((player and player.hand) or {}) do
    local ok_h, hdef = pcall(cards.get_card_def, card_id)
    if ok_h and hdef and has_any_subtype(hdef, required_subtypes) and (hdef.tier or 0) == (target_tier or 0) then
      out[#out + 1] = hi
    end
  end
  return out
end

local function has_index(values, wanted)
  for _, value in ipairs(values or {}) do
    if value == wanted then return true end
  end
  return false
end

local function find_upgrade_board_sacrifice_indices(player, effect_args)
  local out = {}
  local required_subtypes = upgrade_required_subtypes(effect_args)
  for si, entry in ipairs((player and player.board) or {}) do
    local ok_t, tdef = pcall(cards.get_card_def, entry.card_id)
    if ok_t and tdef and tdef.kind ~= "Structure" and tdef.kind ~= "Artifact" and has_any_subtype(tdef, required_subtypes) then
      local next_tier = (tdef.tier or 0) + 1
      if #find_upgrade_hand_indices(player, effect_args, next_tier) > 0 then
        out[#out + 1] = si
      end
    end
  end
  return out
end

local function pretty_reason(reason)
  if type(reason) ~= "string" or reason == "" then
    return "Action failed"
  end
  local text = reason:gsub("_", " ")
  return text:gsub("^%l", string.upper)
end

local function find_pending_upgrade_target_by_click(game_state, local_player_index, eligible_indices, x, y, combat_ui)
  local nearest_si = nil
  local nearest_d2 = nil
  local pick_radius = math.max(board.BFIELD_TILE_W or 86, board.BFIELD_TILE_H or 74)
  local pick_d2 = pick_radius * pick_radius
  for _, si in ipairs(eligible_indices or {}) do
    local cx, cy = board.board_entry_center(game_state, local_player_index, si, local_player_index, combat_ui)
    if cx and cy then
      local dx = x - cx
      local dy = y - cy
      local d2 = dx * dx + dy * dy
      if d2 <= pick_d2 and (not nearest_d2 or d2 < nearest_d2) then
        nearest_d2 = d2
        nearest_si = si
      end
    end
  end
  return nearest_si
end

local function is_attack_unit_board_entry(game_state, pi, board_index, require_attack)
  local player = game_state.players[pi + 1]
  local entry = player and player.board and player.board[board_index]
  if not entry then return false end
  local ok, def = pcall(cards.get_card_def, entry.card_id)
  if not ok or not def then return false end
  if def.kind ~= "Unit" and def.kind ~= "Worker" then return false end
  if require_attack then
    local st = entry.state or {}
    local immediate_attack = false
    for _, kw in ipairs(def.keywords or {}) do
      local low = string.lower(kw)
      if low == "rush" or low == "haste" then
        immediate_attack = true
        break
      end
    end
    local summoning_sickness = (st.summoned_turn == game_state.turnNumber) and not immediate_attack
    local already_attacked = (st.attacked_turn == game_state.turnNumber) and (not can_attack_multiple_times(def))
    return unit_stats.effective_attack(def, st, game_state, pi) > 0 and not st.rested and not summoning_sickness and not already_attacked
  end
  return true
end

local function has_static_effect(card_def, effect_name)
  if not card_def or not card_def.abilities then return false end
  for _, ab in ipairs(card_def.abilities) do
    if ab.type == "static" and ab.effect == effect_name then
      return true
    end
  end
  return false
end

local function can_stage_attack_target(game_state, attacker_pi, attacker_board_index, target_pi, target_index)
  local atk_player = game_state.players[attacker_pi + 1]
  local def_player = game_state.players[target_pi + 1]
  if not atk_player or not def_player then return false end

  local atk_entry = atk_player.board[attacker_board_index]
  if not atk_entry then return false end
  local atk_ok, atk_def = pcall(cards.get_card_def, atk_entry.card_id)
  if not atk_ok or not atk_def then return false end
  if atk_def.kind ~= "Unit" and atk_def.kind ~= "Worker" then return false end
  local atk_state = atk_entry.state or {}
  if unit_stats.effective_attack(atk_def, atk_state, game_state, attacker_pi) <= 0 then return false end
  if atk_state.rested then return false end
  if atk_state.attacked_turn == game_state.turnNumber and not can_attack_multiple_times(atk_def) then
    return false
  end
  local immediate_attack = false
  for _, kw in ipairs(atk_def.keywords or {}) do
    local low = string.lower(kw)
    if low == "rush" or low == "haste" then
      immediate_attack = true
      break
    end
  end
  if atk_state.summoned_turn == game_state.turnNumber and not immediate_attack then
    return false
  end

  if target_index == 0 then
    return true
  end

  local target_entry = def_player.board[target_index]
  if not target_entry then return false end
  local tgt_ok, tgt_def = pcall(cards.get_card_def, target_entry.card_id)
  if not tgt_ok or not tgt_def then return false end
  if tgt_def.kind ~= "Unit" and tgt_def.kind ~= "Worker" and tgt_def.kind ~= "Structure" and tgt_def.kind ~= "Artifact" then
    return false
  end
  if (tgt_def.kind == "Structure" or tgt_def.kind == "Artifact") and tgt_def.health == nil then
    return false
  end

  if tgt_def.kind == "Unit" or tgt_def.kind == "Worker" then
    local target_state = target_entry.state or {}
    if target_state.rested then return true end
    return has_static_effect(atk_def, "can_attack_non_rested")
  end

  return true
end

function GameState:_draw_arrow(x1, y1, x2, y2, color)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return end
  local ux, uy = dx / len, dy / len
  local nx, ny = -uy, ux
  local head = 12
  local shaft_end_x = x2 - ux * head
  local shaft_end_y = y2 - uy * head

  love.graphics.setColor(color[1], color[2], color[3], color[4] or 1)
  love.graphics.setLineWidth(3)
  love.graphics.line(x1, y1, shaft_end_x, shaft_end_y)
  love.graphics.polygon("fill",
    x2, y2,
    shaft_end_x + nx * 6, shaft_end_y + ny * 6,
    shaft_end_x - nx * 6, shaft_end_y - ny * 6
  )
  love.graphics.setLineWidth(1)
end

local function get_special_field_index(game_state, pi, board_index)
  local player = game_state.players[pi + 1]
  local entry = player and player.board and player.board[board_index]
  if not entry then return nil end
  if entry.special_worker_index and player.specialWorkers and player.specialWorkers[entry.special_worker_index] then
    return entry.special_worker_index
  end
  return nil
end

function GameState:_handle_prompt_play_unit_hand_click(idx)
  local pending = self:_prompt_payload("play_unit")
  if not pending then return false end

  local is_eligible = false
  for _, ei in ipairs(pending.eligible_indices or {}) do
    if ei == idx then is_eligible = true; break end
  end
  if is_eligible then
    local p = self.game_state.players[self.local_player_index + 1]
    local before_res = {}
    for k, v in pairs(p.resources) do before_res[k] = v end
    local result = self:dispatch_command({
      type = "PLAY_UNIT_FROM_HAND",
      player_index = self.local_player_index,
      source = pending.source,
      ability_index = pending.ability_index,
      hand_index = idx,
      fast_ability = pending.fast or false,
    })
    if result.ok then
      sound.play("coin")
      local pi_panel = self:player_to_panel(self.local_player_index)
      local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
      for _, c in ipairs(pending.cost or {}) do
        if before_res[c.type] and p.resources[c.type] < before_res[c.type] then
          local rb_x, rb_y = board.resource_bar_rect(pi_panel)
          popup.create("-" .. c.amount .. string.upper(string.sub(c.type, 1, 1)), rb_x + 25, rb_y - 4, { 1.0, 0.5, 0.25 })
        end
      end
      local card_id = result.meta and result.meta.card_id
      local unit_name = "Unit"
      if card_id then
        local ok_d, udef = pcall(cards.get_card_def, card_id)
        if ok_d and udef then unit_name = udef.name end
      end
      popup.create(unit_name .. " played!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.4, 0.9, 1.0 })
      self.hand_selected_index = nil
      self:_clear_prompt("play_unit")
      while #self.hand_y_offsets > #p.hand do
        table.remove(self.hand_y_offsets)
      end
    else
      sound.play("error")
    end
  else
    sound.play("error")
  end
  return true
end

function GameState:_handle_prompt_play_spell_hand_click(idx)
  local pending = self:_prompt_payload("play_spell")
  if not pending then return false end

  local is_eligible = false
  for _, ei in ipairs(pending.eligible_indices or {}) do
    if ei == idx then is_eligible = true; break end
  end
  if is_eligible then
    local p = self.game_state.players[self.local_player_index + 1]
    local spell_id = p.hand[idx]
    local spell_def = nil
    if spell_id then
      local ok_s, sd = pcall(cards.get_card_def, spell_id)
      if ok_s and sd then spell_def = sd end
    end
    -- Check if this spell has a targeted on_cast ability
    local targeted_ab = find_targeted_spell_on_cast_ability(spell_def)
    if targeted_ab then
      local args = targeted_ab.effect_args or {}
      local opponent_pi, eligible = collect_targeted_spell_eligible_indices(self.game_state, self.local_player_index, targeted_ab)
      if #eligible == 0 then
        sound.play("error")
        return true
      end
      self:_set_prompt("spell_target", {
        hand_index = idx,
        effect_args = args,
        eligible_player_index = opponent_pi,
        eligible_board_indices = eligible,
        via_ability_source = pending.source,
        via_ability_ability_index = pending.ability_index,
        sacrifice_target_board_index = pending.sacrifice_target_board_index,
        fast = pending.fast or false,
      })
      self:_clear_prompt("play_spell")
      sound.play("click")
    else
      -- Non-targeted: cast immediately via ability
      local before_res = {}
      for k, v in pairs(p.resources) do before_res[k] = v end
      local result = self:dispatch_command({
        type = "PLAY_SPELL_VIA_ABILITY",
        player_index = self.local_player_index,
        source = pending.source,
        ability_index = pending.ability_index,
        hand_index = idx,
        sacrifice_target_board_index = pending.sacrifice_target_board_index,
        fast_ability = pending.fast or false,
      })
      if result.ok then
        sound.play("coin")
        local pi_panel = self:player_to_panel(self.local_player_index)
        local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
        for _, c in ipairs(pending.cost or {}) do
          if before_res[c.type] and p.resources[c.type] < before_res[c.type] then
            local rb_x, rb_y = board.resource_bar_rect(pi_panel)
            popup.create("-" .. c.amount .. string.upper(string.sub(c.type, 1, 1)), rb_x + 25, rb_y - 4, { 1.0, 0.5, 0.25 })
          end
        end
        local sname = spell_def and spell_def.name or "Spell"
        popup.create(sname .. "!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.7, 0.85, 1.0 })
        self:_clear_prompt("play_spell")
        while #self.hand_y_offsets > #p.hand do table.remove(self.hand_y_offsets) end
      else
        sound.play("error")
      end
    end
  else
    sound.play("error")
  end
  return true
end

function GameState:_handle_prompt_discard_draw_hand_click(idx)
  local pending = self:_prompt_payload("discard_draw")
  if not pending then return false end

  local selected = pending.selected_set
  -- Toggle selection
  if selected[idx] then
    selected[idx] = nil
    sound.play("click")
  else
    local count = 0
    for _ in pairs(selected) do count = count + 1 end
    if count >= pending.required_count then
      sound.play("error")
    else
      selected[idx] = true
      sound.play("click")
      -- Auto-dispatch when required count reached
      count = count + 1
      if count == pending.required_count then
        local indices = {}
        for hi in pairs(selected) do indices[#indices + 1] = hi end
        local p = self.game_state.players[self.local_player_index + 1]
        local result = self:dispatch_command({
          type = "DISCARD_DRAW_HAND",
          player_index = self.local_player_index,
          source = pending.source,
          ability_index = pending.ability_index,
          hand_indices = indices,
        })
        if result.ok then
          sound.play("coin")
          local pi_panel = self:player_to_panel(self.local_player_index)
          local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
          popup.create("Drew " .. pending.draw_count .. "!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.9, 0.65, 0.3 })
          self:_clear_prompt("discard_draw")
          while #self.hand_y_offsets > #p.hand do
            table.remove(self.hand_y_offsets)
          end
        else
          sound.play("error")
          self:_clear_prompt("discard_draw")
        end
      end
    end
  end
  return true
end

function GameState:_handle_prompt_hand_card_click(idx)
  if type(idx) ~= "number" then return false end
  return self:_dispatch_prompt_click_from_top(PROMPT_HAND_CARD_CLICK_METHODS, idx)
end

local function is_worker_click_kind(kind)
  return kind == "worker_unassigned"
    or kind == "worker_left"
    or kind == "worker_right"
    or kind == "structure_worker"
    or kind == "unassigned_pool"
end

function GameState:_handle_prompt_hand_sacrifice_worker_click(worker_kind, idx)
  local pending = self:_prompt_payload("hand_sacrifice")
  if not pending then return false end

  pending.selected_targets[#pending.selected_targets + 1] = { kind = worker_kind, extra = idx }
  if #pending.selected_targets >= pending.required_count then
    local p = self.game_state.players[self.local_player_index + 1]
    local result = self:dispatch_command({
      type = "PLAY_FROM_HAND_WITH_SACRIFICES",
      player_index = self.local_player_index,
      hand_index = pending.hand_index,
      sacrifice_targets = pending.selected_targets,
    })
    if result.ok then
      sound.play("coin")
      shake.trigger(4, 0.15)
      local pi_panel = self:player_to_panel(self.local_player_index)
      local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
      popup.create("-" .. pending.required_count .. " Workers", px_b + pw_b * 0.5, py_b + ph_b - 80, { 1.0, 0.5, 0.25 })
      popup.create("Loving Family played!", px_b + pw_b * 0.5, py_b + ph_b - 110, { 0.9, 0.8, 0.2 })
      self.hand_selected_index = nil
      self:_clear_prompt("hand_sacrifice")
      while #self.hand_y_offsets > #p.hand do
        table.remove(self.hand_y_offsets)
      end
    else
      self:_clear_prompt("hand_sacrifice")
      sound.play("error")
    end
  else
    sound.play("click")
  end
  return true
end

function GameState:_handle_prompt_sacrifice_worker_click(worker_kind, idx)
  local pending = self:_prompt_payload("sacrifice")
  if not pending then return false end
  if pending.allow_worker_tokens == false then
    sound.play("error")
    return true
  end
  local p = self.game_state.players[self.local_player_index + 1]
  local result = self:dispatch_command({
    type = "SACRIFICE_UNIT",
    player_index = self.local_player_index,
    source = pending.source,
    ability_index = pending.ability_index,
    target_worker = worker_kind,
    target_worker_extra = idx,
  })
  if result.ok then
    sound.play("coin")
    local pi_panel = self:player_to_panel(self.local_player_index)
    local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
    local args = pending.effect_args or {}
    if args.resource then
      popup.create("+" .. (args.amount or 1) .. " " .. args.resource, px_b + pw_b / 2, py_b + 8, { 0.9, 0.2, 0.3 })
    end
    popup.create("Worker sacrificed!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.9, 0.3, 0.3 })
    self:_clear_prompt("sacrifice")
  else
    sound.play("error")
  end
  return true
end

function GameState:_handle_prompt_worker_click(kind, idx)
  if not is_worker_click_kind(kind) then return false end
  return self:_dispatch_prompt_click_from_top(PROMPT_WORKER_CLICK_METHODS, kind, idx)
end

function GameState:_handle_prompt_monument_structure_click(target_pi, target_si)
  local pending = self:_prompt_payload("monument")
  if not pending then return false end
  local _ = target_pi
  local is_eligible = false
  for _, ei in ipairs(pending.eligible_indices or {}) do
    if ei == target_si then is_eligible = true; break end
  end
  if is_eligible then
    local p = self.game_state.players[self.local_player_index + 1]
    local hand_card_id = p.hand[pending.hand_index]
    local hand_card_def = nil
    local card_name = "Card"
    if hand_card_id then
      local ok_c, cdef = pcall(cards.get_card_def, hand_card_id)
      if ok_c and cdef then card_name = cdef.name; hand_card_def = cdef end
    end

    -- If the hand card is a Spell, use the spell cast flow (not board placement)
    if hand_card_def and hand_card_def.kind == "Spell" then
      local targeted_ab = find_targeted_spell_on_cast_ability(hand_card_def)
      if targeted_ab then
        local args = targeted_ab.effect_args or {}
        local opponent_pi, eligible = collect_targeted_spell_eligible_indices(self.game_state, self.local_player_index, targeted_ab)
        if #eligible == 0 then
          sound.play("error")
          return true
        end
        self:_set_prompt("spell_target", {
          hand_index = pending.hand_index,
          effect_args = args,
          eligible_player_index = opponent_pi,
          eligible_board_indices = eligible,
          monument_board_index = target_si,
        })
        self:_clear_prompt("monument")
        sound.play("click")
        return true
      else
        -- Non-targeted monument spell
        local result = self:dispatch_command({
          type = "PLAY_SPELL_FROM_HAND",
          player_index = self.local_player_index,
          hand_index = pending.hand_index,
          monument_board_index = target_si,
        })
        if result.ok then
          sound.play("coin")
          local pi_panel = self:player_to_panel(self.local_player_index)
          local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
          popup.create(card_name .. "!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.7, 0.85, 1.0 })
          self:_clear_prompt("monument")
          self.hand_selected_index = nil
          while #self.hand_y_offsets > #p.hand do table.remove(self.hand_y_offsets) end
        else
          sound.play("error")
        end
        return true
      end
    end

    -- Default: non-spell monument card (place on board)
    local result = self:dispatch_command({
      type = "PLAY_MONUMENT_FROM_HAND",
      player_index = self.local_player_index,
      hand_index = pending.hand_index,
      monument_board_index = target_si,
    })
    if result.ok then
      sound.play("coin")
      local pi_panel = self:player_to_panel(self.local_player_index)
      local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
      popup.create(card_name .. " played!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.95, 0.78, 0.2 })
      self:_clear_prompt("monument")
      self.hand_selected_index = nil
      while #self.hand_y_offsets > #p.hand do
        table.remove(self.hand_y_offsets)
      end
    else
      sound.play("error")
    end
  else
    sound.play("error")
  end
  return true
end

function GameState:_handle_prompt_sacrifice_structure_click(target_pi, target_si)
  local pending = self:_prompt_payload("sacrifice")
  if not pending then return false end
  local _ = target_pi
  local is_eligible = false
  for _, ei in ipairs(pending.eligible_board_indices or {}) do
    if ei == target_si then is_eligible = true; break end
  end
  if is_eligible then
    if pending.next == "play_spell" then
      self:_set_prompt("play_spell", {
        source = pending.source,
        ability_index = pending.ability_index,
        cost = pending.spell_cost or {},
        effect_args = pending.effect_args or {},
        eligible_indices = pending.spell_eligible_indices or {},
        fast = pending.fast or false,
        sacrifice_target_board_index = target_si,
      })
      self:_clear_prompt("sacrifice")
      self.hand_selected_index = nil
      sound.play("click")
      return true
    end
    local p = self.game_state.players[self.local_player_index + 1]
    local sacrificed_entry = p.board[target_si]
    local sacrificed_name = "Unit"
    if sacrificed_entry then
      local s_ok, s_def = pcall(cards.get_card_def, sacrificed_entry.card_id)
      if s_ok and s_def then sacrificed_name = s_def.name end
    end
    local result = self:dispatch_command({
      type = "SACRIFICE_UNIT",
      player_index = self.local_player_index,
      source = pending.source,
      ability_index = pending.ability_index,
      target_board_index = target_si,
    })
    if result.ok then
      sound.play("coin")
      local pi_panel = self:player_to_panel(self.local_player_index)
      local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
      local args = pending.effect_args or {}
      if args.resource then
        popup.create("+" .. (args.amount or 1) .. " " .. args.resource, px_b + pw_b / 2, py_b + 8, { 0.9, 0.2, 0.3 })
      end
      popup.create(sacrificed_name .. " sacrificed!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.9, 0.3, 0.3 })
      self:_clear_prompt("sacrifice")
    else
      sound.play("error")
    end
  else
    sound.play("error")
  end
  return true
end

function GameState:_handle_prompt_counter_placement_structure_click(target_pi, target_si)
  local pending = self:_prompt_payload("counter_placement")
  if not pending then return false end
  local _ = target_pi
  local is_eligible = false
  for _, ei in ipairs(pending.eligible_board_indices or {}) do
    if ei == target_si then is_eligible = true; break end
  end
  if is_eligible then
    local result = self:dispatch_command({
      type = "PLACE_COUNTER_ON_TARGET",
      player_index = self.local_player_index,
      source = pending.source,
      ability_index = pending.ability_index,
      target_board_index = target_si,
      fast_ability = pending.fast or false,
    })
    local cp_args = pending.effect_args or {}
    if result.ok then
      local pi_panel = self:player_to_panel(self.local_player_index)
      local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
      local amount = cp_args.amount or 2
      local cname = cp_args.counter or "knowledge"
      popup.create("+" .. amount .. " " .. cname, px_b + pw_b / 2, py_b + ph_b - 80, { 0.35, 0.55, 0.95 })
      sound.play("coin")
    else
      sound.play("error")
    end
    self:_clear_prompt("counter_placement")
  else
    sound.play("error")
  end
  return true
end

function GameState:_handle_prompt_damage_target_structure_click(target_pi, target_si)
  local pending = self:_prompt_payload("damage_target")
  if not pending then return false end

  local is_global = pending.eligible_board_indices_by_player ~= nil

  local function fire_damage(target_pi2, board_idx, is_base)
    local result = self:dispatch_command({
      type = "DEAL_DAMAGE_TO_TARGET",
      player_index = self.local_player_index,
      source = pending.source,
      ability_index = pending.ability_index,
      target_player_index = target_pi2,
      target_board_index = board_idx,
      target_is_base = is_base or false,
      fast_ability = pending.fast or false,
    })
    if result.ok then
      local damage = (pending.effect_args and pending.effect_args.damage) or 0
      local tgt_panel = self:player_to_panel(target_pi2)
      local px_b, py_b, pw_b, ph_b = board.panel_rect(tgt_panel)
      popup.create("-" .. damage, px_b + pw_b / 2, py_b + ph_b / 2, { 0.95, 0.35, 0.25 })
      sound.play("coin")
    else
      sound.play("error")
    end
    self:_clear_prompt("damage_target")
  end

  -- Base click (idx == 0)
  if target_si == 0 then
    if pending.eligible_base_player_indices and pending.eligible_base_player_indices[target_pi] then
      fire_damage(target_pi, nil, true)
    else
      sound.play("error")
    end
    return true
  end

  -- Board card click
  if is_global then
    local eligible = pending.eligible_board_indices_by_player[target_pi] or {}
    local is_eligible = false
    for _, ei in ipairs(eligible) do
      if ei == target_si then is_eligible = true; break end
    end
    if is_eligible then
      fire_damage(target_pi, target_si, false)
    else
      sound.play("error")
    end
    return true
  end

  -- Legacy single-player targeting; allow fallthrough if wrong player was clicked.
  if target_pi ~= pending.eligible_player_index then
    return false
  end

  local is_eligible = false
  for _, ei in ipairs(pending.eligible_board_indices or {}) do
    if ei == target_si then is_eligible = true; break end
  end
  if is_eligible then
    fire_damage(pending.eligible_player_index, target_si, false)
  else
    sound.play("error")
  end
  return true
end

function GameState:_handle_prompt_spell_target_structure_click(target_pi, target_si)
  local pending = self:_prompt_payload("spell_target")
  if not pending then return false end
  if target_pi ~= pending.eligible_player_index then return false end

  local is_eligible = false
  for _, ei in ipairs(pending.eligible_board_indices or {}) do
    if ei == target_si then is_eligible = true; break end
  end
  if is_eligible then
    local cmd_type = pending.via_ability_source and "PLAY_SPELL_VIA_ABILITY" or "PLAY_SPELL_FROM_HAND"
    local result = self:dispatch_command({
      type = cmd_type,
      player_index = self.local_player_index,
      source = pending.via_ability_source,
      ability_index = pending.via_ability_ability_index,
      hand_index = pending.hand_index,
      target_player_index = pending.eligible_player_index,
      target_board_index = target_si,
      sacrifice_target_board_index = pending.sacrifice_target_board_index,
      monument_board_index = pending.monument_board_index,
      fast_ability = pending.fast or false,
    })
    if result.ok then
      local opp_panel = self:player_to_panel(pending.eligible_player_index)
      local px_b, py_b, pw_b, ph_b = board.panel_rect(opp_panel)
      local damage = pending.effect_args and pending.effect_args.damage
      if damage and damage > 0 then
        popup.create("-" .. damage, px_b + pw_b / 2, py_b + ph_b / 2, { 0.95, 0.35, 0.25 })
      else
        popup.create("Spell!", px_b + pw_b / 2, py_b + ph_b / 2, { 0.85, 0.75, 0.95 })
      end
      sound.play("coin")
    else
      sound.play("error")
    end
    self:_clear_prompt("spell_target")
    self.hand_selected_index = nil
  else
    sound.play("error")
  end
  return true
end

function GameState:_handle_prompt_damage_x_structure_click(target_pi, target_si)
  local pending = self:_prompt_payload("damage_x")
  if not pending then return false end
  if target_pi ~= pending.eligible_player_index then return false end

  local is_eligible = false
  for _, ei in ipairs(pending.eligible_board_indices or {}) do
    if ei == target_si then is_eligible = true; break end
  end
  if is_eligible then
    local result = self:dispatch_command({
      type = "DEAL_DAMAGE_X_TO_TARGET",
      player_index = self.local_player_index,
      source = pending.source,
      ability_index = pending.ability_index,
      target_player_index = pending.eligible_player_index,
      target_board_index = target_si,
      x_amount = pending.x_amount,
      fast_ability = pending.fast or false,
    })
    if result.ok then
      local opp_panel = self:player_to_panel(pending.eligible_player_index)
      local px_b, py_b, pw_b, ph_b = board.panel_rect(opp_panel)
      popup.create("-" .. pending.x_amount, px_b + pw_b / 2, py_b + ph_b / 2, { 0.95, 0.35, 0.25 })
      sound.play("coin")
    else
      sound.play("error")
    end
    self:_clear_prompt("damage_x")
  else
    sound.play("error")
  end
  return true
end

function GameState:_handle_prompt_structure_click(pi, idx)
  if type(idx) ~= "number" then return false end
  return self:_dispatch_prompt_click_from_top(PROMPT_STRUCTURE_CLICK_METHODS, pi, idx)
end

function GameState:_handle_prompt_upgrade_click(kind, pi, idx, extra, x, y)
  local top_kind, pending = self:_top_prompt()
  if top_kind ~= "upgrade" or type(pending) ~= "table" then
    return false
  end

  local p = self.game_state.players[self.local_player_index + 1]
  local required_subtypes = upgrade_required_subtypes(pending.effect_args)
  local function upgrade_error(msg)
    local pi_panel = self:player_to_panel(self.local_player_index)
    local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
    popup.create(msg, px_b + pw_b / 2, py_b + ph_b - 118, { 1.0, 0.45, 0.35 })
    sound.play("error")
  end

  if pending.stage == "sacrifice" and is_worker_click_kind(kind) then
    if pending.eligible_worker_sacrifice ~= true then
      upgrade_error("No worker upgrade available")
      return true
    end
    local eligible = find_upgrade_hand_indices(p, pending.effect_args, 1)
    if #eligible == 0 then
      pending.eligible_worker_sacrifice = false
      upgrade_error("No Tier 1 upgrade in hand")
      return true
    end
    pending.sacrifice_target = { target_worker = kind, target_worker_extra = idx }
    pending.stage = "hand"
    pending.eligible_hand_indices = eligible
    sound.play("click")
    return true
  end

  if pending.stage == "sacrifice" and (kind == "structure" or kind == "activate_ability" or kind == "ability_hover" or kind == "unit_row") then
    local target_si = nil
    if kind == "structure" then
      target_si = idx
    elseif type(extra) == "table" and extra.source == "board" then
      target_si = extra.board_index
    end
    if pi == self.local_player_index then
      local nearest_target = find_pending_upgrade_target_by_click(
        self.game_state,
        self.local_player_index,
        pending.eligible_board_indices,
        x, y,
        {
          pending_attack_declarations = self.pending_attack_declarations,
          pending_block_assignments = self.pending_block_assignments,
          pending_attack_trigger_targets = self.pending_attack_trigger_targets,
        }
      )
      if nearest_target and nearest_target > 0 then
        target_si = nearest_target
      end
    end
    if (not target_si or target_si <= 0) and pi == self.local_player_index then
      target_si = find_pending_upgrade_target_by_click(
        self.game_state,
        self.local_player_index,
        pending.eligible_board_indices,
        x, y,
        {
          pending_attack_declarations = self.pending_attack_declarations,
          pending_block_assignments = self.pending_block_assignments,
          pending_attack_trigger_targets = self.pending_attack_trigger_targets,
        }
      )
    end
    if not target_si or target_si <= 0 then
      upgrade_error("Pick a highlighted ally")
      return true
    end

    local entry = p.board[target_si]
    local ok_t, tdef = false, nil
    if entry then
      ok_t, tdef = pcall(cards.get_card_def, entry.card_id)
    end
    if not ok_t or not tdef or tdef.kind == "Structure" or tdef.kind == "Artifact" or not has_any_subtype(tdef, required_subtypes) then
      local bad_name = "unknown"
      if entry then
        local ok_bad, bad_def = pcall(cards.get_card_def, entry.card_id)
        if ok_bad and bad_def and bad_def.name then bad_name = bad_def.name end
      end
      upgrade_error("Target mismatch: " .. bad_name)
      return true
    end
    local next_tier = (tdef.tier or 0) + 1
    local eligible = find_upgrade_hand_indices(p, pending.effect_args, next_tier)
    if #eligible == 0 then
      upgrade_error("No matching upgrade in hand")
      return true
    end
    if not has_index(pending.eligible_board_indices, target_si) then
      pending.eligible_board_indices[#pending.eligible_board_indices + 1] = target_si
    end
    pending.sacrifice_target = { target_board_index = target_si }
    pending.stage = "hand"
    pending.eligible_hand_indices = eligible
    sound.play("click")
    return true
  end

  if pending.stage == "hand" and kind == "hand_card" then
    local is_eligible = false
    for _, ei in ipairs(pending.eligible_hand_indices or {}) do if ei == idx then is_eligible = true; break end end
    if not is_eligible then sound.play("error"); return true end

    local payload = {
      type = "SACRIFICE_UPGRADE_PLAY",
      player_index = self.local_player_index,
      source = pending.source,
      ability_index = pending.ability_index,
      hand_index = idx,
    }
    if pending.sacrifice_target and pending.sacrifice_target.target_board_index then
      payload.target_board_index = pending.sacrifice_target.target_board_index
    else
      payload.target_worker = pending.sacrifice_target and pending.sacrifice_target.target_worker
      payload.target_worker_extra = pending.sacrifice_target and pending.sacrifice_target.target_worker_extra
    end
    local result = self:dispatch_command(payload)
    if result.ok then
      sound.play("coin")
      local pi_panel = self:player_to_panel(self.local_player_index)
      local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
      popup.create("Fighting Pits upgrade!", px_b + pw_b / 2, py_b + ph_b - 90, { 0.9, 0.3, 0.3 })
      self:_clear_prompt("upgrade")
      self.hand_selected_index = nil
      while #self.hand_y_offsets > #p.hand do table.remove(self.hand_y_offsets) end
    else
      local pi_panel = self:player_to_panel(self.local_player_index)
      local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
      popup.create(pretty_reason(result.reason), px_b + pw_b / 2, py_b + ph_b - 118, { 1.0, 0.45, 0.35 })
      sound.play("error")
    end
    return true
  end

  -- While a sacrifice-upgrade flow is active, non-matching clicks should
  -- not silently fall through into drag/combat handlers.
  if pending.stage == "sacrifice" or pending.stage == "hand" then
    sound.play("error")
    return true
  end

  return false
end

function GameState:_handle_prompt_damage_x_pre_hit_test_click(x, y)
  local pending = self:_prompt_payload("damage_x")
  if not pending then return false end
  local function in_btn(b) return b and x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h end
  if in_btn(pending.minus_btn) then
    pending.x_amount = math.max(1, pending.x_amount - 1)
    return true
  end
  if in_btn(pending.plus_btn) then
    pending.x_amount = math.min(pending.max_x, pending.x_amount + 1)
    return true
  end
  return false
end

function GameState:_handle_prompt_pre_hit_test_click(x, y)
  return self:_dispatch_prompt_click_from_top(PROMPT_PRE_HIT_TEST_CLICK_METHODS, x, y)
end

function GameState:_current_graveyard_return_prompt()
  return self:_prompt_payload("graveyard_return") or self.pending_graveyard_return
end

function GameState:_open_graveyard_return_prompt(source, ability_index, args, cards_for_selection, faction_key)
  self:_set_prompt("graveyard_return", {
    source = source,
    ability_index = ability_index,
    max_count = (args and args.count) or 1,
    effect_args = args or {},
    selected_graveyard_indices = {},
  })

  local faction_info = factions_data[faction_key]
  local accent = faction_info and faction_info.color or { 0.5, 0.5, 0.7 }
  local viewer_title = (args and args.return_to == "hand") and "Return to Hand" or "Return from Graveyard"
  local viewer_hint = "Select up to "
    .. ((args and args.count) or 1)
    .. (((args and args.return_to) == "hand") and " card" or " Undead")
    .. ((((args and args.count) or 1) > 1) and "s" or "")

  deck_viewer.open({
    title = viewer_title,
    hint = viewer_hint,
    cards = cards_for_selection,
    accent = accent,
    can_click_fn = function(def) return def.graveyard_eligible == true end,
    card_overlay_fn = function(def, cx, cy, cw, ch)
      if not def.graveyard_index then return end
      local pending_ref = self:_current_graveyard_return_prompt()
      if not pending_ref then return end
      -- Dim ineligible cards
      if not def.graveyard_eligible then
        love.graphics.setColor(0, 0, 0, 0.55)
        love.graphics.rectangle("fill", cx, cy, cw, ch, 5, 5)
        return
      end
      -- Highlight selected cards
      local selected = pending_ref.selected_graveyard_indices
      for _, gi in ipairs(selected) do
        if gi == def.graveyard_index then
          love.graphics.setColor(0.2, 0.9, 0.35, 0.35)
          love.graphics.rectangle("fill", cx, cy, cw, ch, 5, 5)
          love.graphics.setColor(0.2, 0.9, 0.35, 0.85)
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", cx - 2, cy - 2, cw + 4, ch + 4, 7, 7)
          love.graphics.setLineWidth(1)
          return
        end
      end
    end,
    on_click = function(def)
      if not def.graveyard_eligible or not def.graveyard_index then return end
      local pending_ref = self:_current_graveyard_return_prompt()
      if not pending_ref then return end
      local sel = pending_ref.selected_graveyard_indices
      -- Toggle: deselect if already selected
      for i, gi in ipairs(sel) do
        if gi == def.graveyard_index then
          table.remove(sel, i)
          sound.play("click")
          return
        end
      end
      -- Add if under max
      if #sel < pending_ref.max_count then
        sel[#sel + 1] = def.graveyard_index
        sound.play("click")
      else
        sound.play("error")
      end
    end,
    confirm_label = ((args and args.return_to) == "hand") and "Return to Hand" or "Summon Selected",
    confirm_enabled_fn = function()
      local pending_ref = self:_current_graveyard_return_prompt()
      if not pending_ref then return false end
      return #pending_ref.selected_graveyard_indices > 0
    end,
    confirm_fn = function()
      local pending_ref = self:_current_graveyard_return_prompt()
      if not pending_ref then return end
      local selected = pending_ref.selected_graveyard_indices
      if #selected == 0 then return end
      local result = self:dispatch_command({
        type = "RETURN_FROM_GRAVEYARD",
        player_index = self.local_player_index,
        source = pending_ref.source,
        ability_index = pending_ref.ability_index,
        selected_graveyard_indices = selected,
      })
      if result.ok then
        sound.play("coin")
        local pi_panel = self:player_to_panel(self.local_player_index)
        local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
        local count = result.meta and result.meta.returned_count or 0
        local msg = ((args and args.return_to) == "hand")
          and (count .. " card" .. (count == 1 and "" or "s") .. " returned to hand!")
          or (count .. " Undead summoned!")
        popup.create(msg, px_b + pw_b / 2, py_b + ph_b - 80, { 0.55, 0.9, 0.45 })
      else
        sound.play("error")
      end
      deck_viewer.close()
      self.show_blueprint_for_player = nil
      self:_clear_prompt("graveyard_return")
    end,
  })
  self.show_blueprint_for_player = nil
  sound.play("click")
end

function GameState:_start_activated_play_unit_prompt(pi, p, info, ab)
  local eligible = abilities.find_matching_hand_indices(p, ab.effect_args)
  if #eligible == 0 then
    sound.play("error")
    return true
  elseif #eligible == 1 then
    -- Only one match: auto-play immediately
    local before_res = {}
    for k, v in pairs(p.resources) do before_res[k] = v end
    local result = self:dispatch_command({
      type = "PLAY_UNIT_FROM_HAND",
      player_index = pi,
      source = { type = info.source, index = info.board_index },
      ability_index = info.ability_index,
      hand_index = eligible[1],
      fast_ability = ab.fast or false,
    })
    if result.ok then
      sound.play("coin")
      local pi_panel = self:player_to_panel(pi)
      local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
      for _, c in ipairs(ab.cost or {}) do
        if before_res[c.type] and p.resources[c.type] < before_res[c.type] then
          local rb_x, rb_y = board.resource_bar_rect(pi_panel)
          popup.create("-" .. c.amount .. string.upper(string.sub(c.type, 1, 1)), rb_x + 25, rb_y - 4, { 1.0, 0.5, 0.25 })
        end
      end
      local card_id = result.meta and result.meta.card_id
      local unit_name = "Unit"
      if card_id then
        local ok_d, udef = pcall(cards.get_card_def, card_id)
        if ok_d and udef then unit_name = udef.name end
      end
      popup.create(unit_name .. " played!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.4, 0.9, 1.0 })
      self.hand_selected_index = nil
      self:_clear_prompt("play_unit")
      while #self.hand_y_offsets > #p.hand do
        table.remove(self.hand_y_offsets)
      end
    end
    return true
  else
    -- Multiple matches: enter pending selection mode
    self:_set_prompt("play_unit", {
      source = { type = info.source, index = info.board_index },
      ability_index = info.ability_index,
      effect_args = ab.effect_args,
      eligible_indices = eligible,
      cost = ab.cost,
      fast = ab.fast or false,
    })
    self.hand_selected_index = nil
    sound.play("click")
    return true
  end
end

function GameState:_start_activated_sacrifice_upgrade_prompt(pi, p, info, ab)
  local _ = p
  local sel_info = abilities.collect_activated_selection_cost_targets(self.game_state, pi, ab)
  local warrior_indices = (sel_info and sel_info.eligible_board_indices) or {}
  local can_sac_workers = (sel_info and sel_info.has_worker_tokens) or false
  if #warrior_indices == 0 and not can_sac_workers then
    sound.play("error")
    return true
  end
  self:_set_prompt("upgrade", {
    source = { type = info.source, index = info.board_index },
    ability_index = info.ability_index,
    effect_args = ab.effect_args,
    stage = "sacrifice",
    sacrifice_target = nil,
    eligible_hand_indices = nil,
    eligible_board_indices = warrior_indices,
    eligible_worker_sacrifice = can_sac_workers,
  })
  self.hand_selected_index = nil
  self:_clear_prompt("play_unit")
  self:_clear_prompt("sacrifice")
  sound.play("click")
  return true
end

function GameState:_start_activated_sacrifice_produce_prompt(pi, p, info, ab)
  local sel_info = abilities.collect_activated_selection_cost_targets(self.game_state, pi, ab)
  local eligible = (sel_info and sel_info.eligible_board_indices) or {}
  local has_worker_to_sacrifice = (sel_info and sel_info.has_worker_tokens) or false
  if #eligible == 0 and not has_worker_to_sacrifice then
    sound.play("error")
    return true
  end
  self:_set_prompt("sacrifice", {
    source = { type = info.source, index = info.board_index },
    ability_index = info.ability_index,
    effect_args = ab.effect_args,
    eligible_board_indices = eligible,
    allow_worker_tokens = (sel_info and sel_info.allow_worker_tokens) ~= false,
  })
  self.hand_selected_index = nil
  self:_clear_prompt("play_unit")
  sound.play("click")
  return true
end

function GameState:_start_activated_deal_damage_prompt(pi, p, info, ab)
  local source_entry = info.source == "board" and p.board[info.board_index] or nil
  local can_pay_ab, _ = abilities.can_pay_activated_ability_costs(p.resources, ab, {
    source_entry = source_entry,
  })
  if not can_pay_ab then
    sound.play("error")
    return true
  end
  local source_key = (info.source == "board" and "board:" .. info.board_index or "base") .. ":" .. info.ability_index
  local source_ref = (info.source == "board") and { type = "board", index = info.board_index } or { type = "base" }
  if ab.once_per_turn and abilities.is_activated_ability_used_this_turn(self.game_state, pi, source_key, source_ref, info.ability_index) then
    sound.play("error")
    return true
  end
  local args = ab.effect_args or {}
  local target_info = abilities.collect_effect_target_candidates(self.game_state, pi, ab.effect, args)
  if not target_info or target_info.requires_target == false then
    sound.play("error")
    return true
  end
  local has_board_targets = false
  if type(target_info.eligible_board_indices) == "table" and #target_info.eligible_board_indices > 0 then
    has_board_targets = true
  elseif type(target_info.eligible_board_indices_by_player) == "table" then
    for _, list in pairs(target_info.eligible_board_indices_by_player) do
      if type(list) == "table" and #list > 0 then
        has_board_targets = true
        break
      end
    end
  end
  local has_base_targets = false
  if type(target_info.eligible_base_player_indices) == "table" then
    for _, allowed in pairs(target_info.eligible_base_player_indices) do
      if allowed then has_base_targets = true; break end
    end
  end
  if not has_board_targets and not has_base_targets then
    sound.play("error")
    return true
  end
  self:_set_prompt("damage_target", {
    source = { type = info.source, index = info.board_index },
    ability_index = info.ability_index,
    effect_args = args,
    eligible_player_index = target_info.eligible_player_index,
    eligible_board_indices = target_info.eligible_board_indices,
    eligible_board_indices_by_player = target_info.eligible_board_indices_by_player,
    eligible_base_player_indices = target_info.eligible_base_player_indices,
    fast = ab.fast or false,
  })
  sound.play("click")
  return true
end

function GameState:_start_activated_play_spell_prompt(pi, p, info, ab)
  local eligible = abilities.find_matching_spell_hand_indices(p, ab.effect_args)
  if #eligible == 0 then
    sound.play("error")
    return true
  end

  if ab.effect == "sacrifice_cast_spell" then
    local sel_info = abilities.collect_activated_selection_cost_targets(self.game_state, pi, ab)
    local sac_eligible = (sel_info and sel_info.eligible_board_indices) or {}
    if #sac_eligible == 0 then
      sound.play("error")
      return true
    end
    self:_set_prompt("sacrifice", {
      source = { type = info.source, index = info.board_index },
      ability_index = info.ability_index,
      effect_args = ab.effect_args,
      eligible_board_indices = sac_eligible,
      next = "play_spell",
      spell_eligible_indices = eligible,
      spell_cost = ab.cost,
      fast = ab.fast or false,
      allow_worker_tokens = (sel_info and sel_info.allow_worker_tokens) == true,
    })
    self.hand_selected_index = nil
    sound.play("click")
    return true
  end

  local function do_cast_spell(hand_idx)
    local spell_id = p.hand[hand_idx]
    local spell_def = nil
    if spell_id then
      local ok_s, sd = pcall(cards.get_card_def, spell_id)
      if ok_s and sd then spell_def = sd end
    end
    local targeted_ab = find_targeted_spell_on_cast_ability(spell_def)
    if targeted_ab then
      local args = targeted_ab.effect_args or {}
      local opponent_pi, dmg_eligible = collect_targeted_spell_eligible_indices(self.game_state, pi, targeted_ab)
      if #dmg_eligible == 0 then
        sound.play("error")
        return
      end
      self:_set_prompt("spell_target", {
        hand_index = hand_idx,
        effect_args = args,
        eligible_player_index = opponent_pi,
        eligible_board_indices = dmg_eligible,
        via_ability_source = { type = info.source, index = info.board_index },
        via_ability_ability_index = info.ability_index,
        fast = ab.fast or false,
      })
      self:_clear_prompt("play_spell")
      sound.play("click")
    else
      local before_res = {}
      for k, v in pairs(p.resources) do before_res[k] = v end
      local result = self:dispatch_command({
        type = "PLAY_SPELL_VIA_ABILITY",
        player_index = pi,
        source = { type = info.source, index = info.board_index },
        ability_index = info.ability_index,
        hand_index = hand_idx,
        fast_ability = ab.fast or false,
      })
      if result.ok then
        sound.play("coin")
        local pi_panel = self:player_to_panel(pi)
        local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
        for _, c in ipairs(ab.cost or {}) do
          if before_res[c.type] and p.resources[c.type] < before_res[c.type] then
            local rb_x, rb_y = board.resource_bar_rect(pi_panel)
            popup.create("-" .. c.amount .. string.upper(string.sub(c.type, 1, 1)), rb_x + 25, rb_y - 4, { 1.0, 0.5, 0.25 })
          end
        end
        local sname = spell_def and spell_def.name or "Spell"
        popup.create(sname .. "!", px_b + pw_b / 2, py_b + ph_b - 80, { 0.7, 0.85, 1.0 })
        self:_clear_prompt("play_spell")
        while #self.hand_y_offsets > #p.hand do table.remove(self.hand_y_offsets) end
      else
        sound.play("error")
      end
    end
  end

  if #eligible == 1 then
    do_cast_spell(eligible[1])
  else
    self:_set_prompt("play_spell", {
      source = { type = info.source, index = info.board_index },
      ability_index = info.ability_index,
      cost = ab.cost,
      effect_args = ab.effect_args,
      eligible_indices = eligible,
      fast = ab.fast or false,
    })
    self.hand_selected_index = nil
    sound.play("click")
  end
  return true
end

function GameState:_start_activated_discard_draw_prompt(pi, p, info, ab)
  local _ = pi
  local args = ab.effect_args or {}
  local required_discard = args.discard or 2
  if #p.hand < required_discard then
    sound.play("error")
    return true
  end
  self:_set_prompt("discard_draw", {
    source = { type = info.source, index = info.board_index },
    ability_index = info.ability_index,
    required_count = required_discard,
    draw_count = args.draw or 1,
    selected_set = {},
  })
  self.hand_selected_index = nil
  sound.play("click")
  return true
end

function GameState:_start_activated_damage_x_prompt(pi, p, info, ab)
  local source_entry = info.source == "board" and p.board[info.board_index] or nil
  local can_pay_base_costs, _ = abilities.can_pay_activated_ability_costs(p.resources, ab, {
    source_entry = source_entry,
    require_variable_min = true,
  })
  if not can_pay_base_costs then
    sound.play("error")
    return true
  end
  local available, _, avail_reason = abilities.max_activated_variable_cost_amount(p.resources, ab)
  if avail_reason or type(available) ~= "number" or available < 1 then
    sound.play("error")
    return true
  end
  local args = ab.effect_args or {}
  local target_info = abilities.collect_effect_target_candidates(self.game_state, pi, ab.effect, args)
  if not target_info or target_info.requires_target == false
    or type(target_info.eligible_player_index) ~= "number"
    or type(target_info.eligible_board_indices) ~= "table"
    or #target_info.eligible_board_indices == 0 then
    sound.play("error")
    return true
  end
  self:_set_prompt("damage_x", {
    source = { type = info.source, index = info.board_index },
    ability_index = info.ability_index,
    effect_args = args,
    eligible_player_index = target_info.eligible_player_index,
    eligible_board_indices = target_info.eligible_board_indices,
    x_amount = available,
    max_x = available,
    fast = ab.fast or false,
  })
  sound.play("click")
  return true
end

function GameState:_start_activated_counter_placement_prompt(pi, p, info, ab)
  local source_entry = info.source == "board" and p.board[info.board_index] or nil
  local can_pay_ab, _ = abilities.can_pay_activated_ability_costs(p.resources, ab, {
    source_entry = source_entry,
  })
  if not can_pay_ab then
    sound.play("error")
    return true
  end
  local target_info = abilities.collect_effect_target_candidates(self.game_state, pi, ab.effect, ab.effect_args or {})
  if not target_info or target_info.requires_target == false
    or type(target_info.eligible_board_indices) ~= "table"
    or #target_info.eligible_board_indices == 0 then
    sound.play("error")
    return true
  end
  self:_set_prompt("counter_placement", {
    source = { type = info.source, index = info.board_index },
    ability_index = info.ability_index,
    effect_args = ab.effect_args or {},
    eligible_board_indices = target_info.eligible_board_indices,
    fast = ab.fast or false,
  })
  sound.play("click")
  return true
end

function GameState:_start_activated_graveyard_return_prompt(pi, p, info, ab)
  local source_entry = info.source == "board" and p.board[info.board_index] or nil
  local can_pay_ab, _ = abilities.can_pay_activated_ability_costs(p.resources, ab, {
    source_entry = source_entry,
  })
  if not can_pay_ab then
    sound.play("error")
    return true
  end
  local source_key = (info.source == "board" and "board:" .. info.board_index or "base") .. ":" .. info.ability_index
  local source_ref = (info.source == "board") and { type = "board", index = info.board_index } or { type = "base" }
  if ab.once_per_turn and abilities.is_activated_ability_used_this_turn(self.game_state, pi, source_key, source_ref, info.ability_index) then
    sound.play("error")
    return true
  end
  local args = ab.effect_args or {}
  local cards_for_selection = graveyard_cards_for_selection(p, args)
  local has_eligible = false
  for _, c in ipairs(cards_for_selection) do
    if c.graveyard_eligible then has_eligible = true; break end
  end
  if not has_eligible then
    sound.play("error")
    return true
  end
  self:_open_graveyard_return_prompt(
    { type = info.source, index = info.board_index },
    info.ability_index,
    args,
    cards_for_selection,
    p.faction
  )
  return true
end

function GameState:_try_start_activated_prompt(pi, p, info, ab)
  if type(ab) ~= "table" or type(ab.effect) ~= "string" then return false end
  local method_name = ACTIVATED_PROMPT_START_METHODS[ab.effect]
  local method = method_name and self[method_name] or nil
  if type(method) ~= "function" then return false end
  return method(self, pi, p, info, ab)
end

function GameState:mousepressed(x, y, button, istouch, presses)
  if button ~= 1 then return end -- left click only
  if self.in_game_settings_open then
    self:_handle_in_game_settings_click(x, y)
    return
  end
  if self.game_state and self.game_state.is_terminal then return end
  self.mouse_down = true

  if deck_viewer.is_open() then
    -- Try building a card if clicking on one in the blueprint viewer
    if self.show_blueprint_for_player ~= nil and self.show_blueprint_for_player == self.game_state.activePlayer then
      local def = deck_viewer.hit_test_card(x, y)
      if def then
        local cfg = deck_viewer.get_config()
        local can_click = cfg and cfg.can_click_fn and cfg.can_click_fn(def)
        if can_click then
          local built_res = self:dispatch_command({
            type = "BUILD_STRUCTURE",
            player_index = self.show_blueprint_for_player,
            card_id = def.id,
          })
          local built = built_res.ok
          if built then
            sound.play("build")
            shake.trigger(3, 0.12)
            local px, py, pw, ph = board.panel_rect(self:player_to_panel(self.show_blueprint_for_player))
            local cost_str = ""
            for _, c in ipairs(def.costs or {}) do
              local rdef = res_registry[c.type]
              local letter = rdef and rdef.letter or "?"
              cost_str = cost_str .. "-" .. c.amount .. letter .. " "
            end
            if cost_str ~= "" then
              popup.create(cost_str, px + pw * 0.5, py + 8, { 1.0, 0.5, 0.25 })
            end
            local pi_panel_bp = self:player_to_panel(self.show_blueprint_for_player)
            local sax, say, saw = board.structures_area_rect(px, py, pw, ph, pi_panel_bp)
            local struct_count = 0
            for _, e in ipairs(self.game_state.players[self.show_blueprint_for_player + 1].board) do
              local e_ok, e_def = pcall(cards.get_card_def, e.card_id)
              if e_ok and e_def and (e_def.kind == "Structure" or e_def.kind == "Artifact") then struct_count = struct_count + 1 end
            end
            local tile_step = board.BFIELD_TILE_W + board.BFIELD_GAP
            local start_x = board.centered_row_x(sax, saw, struct_count)
            popup.create("Built!", start_x + (struct_count - 1) * tile_step + board.BFIELD_TILE_W / 2, say + 20, { 0.4, 0.9, 1.0 })
            local board_entries = self.game_state.players[self.show_blueprint_for_player + 1].board
            local entry = board_entries[#board_entries]
            entry.scale = 0
            tween.to(entry, 0.25, { scale = 1 }):ease("backout")
            deck_viewer.close()
            self.show_blueprint_for_player = nil
            return
          else
            sound.play("error")
          end
        else
          sound.play("error")
        end
        return
      end
    end
    -- Let deck_viewer handle close/search/filter/scroll clicks
    local was_open = deck_viewer.is_open()
    deck_viewer.mousepressed(x, y, button)
    if was_open and not deck_viewer.is_open() then
      self.show_blueprint_for_player = nil
      self:_clear_prompt("graveyard_return")
    end
    return
  end

  -- Prompt-owned pre-hit-test UI controls (e.g. damage_x +/- buttons)
  if self:_handle_prompt_pre_hit_test_click(x, y) then
    return
  end

  local kind, pi, extra = board.hit_test(x, y, self.game_state, self.hand_y_offsets, self.local_player_index, {
    pending_attack_declarations = self.pending_attack_declarations,
    pending_block_assignments = self.pending_block_assignments,
    pending_attack_trigger_targets = self.pending_attack_trigger_targets,
  })
  local idx = extra  -- backwards compat: numeric index for hand_card, structure, etc.

  local combat_state = self.game_state.pendingCombat
  if combat_state and combat_state.stage == "AWAITING_ATTACK_TARGETS" then
    if kind ~= "pass" then
      if combat_state.attacker == self.local_player_index then
        local active_trigger = self:_active_attack_trigger_for_targeting(combat_state)
        if active_trigger and active_trigger.requires_target then
          if kind == "structure"
            and pi == combat_state.defender
            and idx and idx > 0
            and self:_is_pending_attack_trigger_target_legal(combat_state.defender, idx) then
            self:_set_pending_attack_trigger_target(active_trigger.attacker_board_index, active_trigger.ability_index, idx)
            sound.play("click")
          else
            sound.play("error")
          end
        elseif active_trigger and active_trigger.optional_activate then
          if kind == "structure"
            and pi == combat_state.attacker
            and idx and idx == active_trigger.attacker_board_index then
            local atk_player = self.game_state.players[combat_state.attacker + 1]
            if atk_player and abilities.can_pay_cost(atk_player.resources, active_trigger.cost or {}) then
              self:_set_pending_attack_trigger_activation(active_trigger.attacker_board_index, active_trigger.ability_index, true)
              sound.play("click")
            else
              sound.play("error")
            end
          else
            sound.play("error")
          end
        else
          sound.play("error")
        end
      end
      return
    end
  end

  -- If attack declarations are staged and player performs another action, clear staged attack arrows.
  if #self.pending_attack_declarations > 0 and kind and kind ~= "pass" and kind ~= "structure" then
    self:_clear_pending_attack_declarations()
  end
  if not kind then
    -- Clicked on empty space: cancel pending selection or deselect hand card
    self:_clear_pending_attack_declarations()
    if self:_cancel_top_prompt_for_context("empty_click") then
      sound.play("click")
      return
    end
    if self.hand_selected_index then
      self.hand_selected_index = nil
      sound.play("click")
    end
    return
  end

  if kind == "hand_card" and self:_handle_prompt_hand_card_click(idx) then
    return
  end

  if self:_handle_prompt_worker_click(kind, idx) then
    return
  end

  if kind == "structure" and self:_handle_prompt_structure_click(pi, idx) then
    return
  end

  if self:_handle_prompt_upgrade_click(kind, pi, idx, extra, x, y) then
    return
  end

  -- Hand card click: toggle selection or play from hand
  if kind == "hand_card" then
    if self.hand_selected_index == idx then
      -- Clicking selected card: check if it can be played from hand (sacrifice ability)
      local local_p = self.game_state.players[pi + 1]
      local card_id = local_p.hand[idx]
      if card_id and pi == self.game_state.activePlayer then
        local card_ok, card_def = pcall(cards.get_card_def, card_id)
        if card_ok and card_def then
          local sac_cost_info = abilities.collect_card_play_cost_targets(self.game_state, pi, card_def)
          if sac_cost_info and sac_cost_info.effect == "play_cost_sacrifice" then
            local sacrifice_count = sac_cost_info.required_count or 2
            if (local_p.totalWorkers or 0) >= sacrifice_count then
              self:_set_prompt("hand_sacrifice", {
                hand_index = idx,
                required_count = sacrifice_count,
                selected_targets = {},
              })
              sound.play("click")
              return
            end
          end
          -- Check for monument cost ability
          local monument_cost_info = abilities.collect_card_play_cost_targets(self.game_state, pi, card_def)
          if monument_cost_info and monument_cost_info.effect == "monument_cost" then
            local eligible = monument_cost_info.eligible_board_indices or {}
            if #eligible > 0 then
              self:_set_prompt("monument", {
                hand_index = idx,
                min_counters = monument_cost_info.min_counters or 1,
                eligible_indices = eligible,
              })
              sound.play("click")
              return
            end
          end
          -- Check for Spell cast
          if card_def.kind == "Spell" then
            if abilities.can_pay_cost(local_p.resources, card_def.costs) then
              -- Find first on_cast ability that needs a target
              local targeted_ab = find_targeted_spell_on_cast_ability(card_def)
              if targeted_ab then
                local args = targeted_ab.effect_args or {}
                local opponent_pi, eligible = collect_targeted_spell_eligible_indices(self.game_state, pi, targeted_ab)
                if #eligible == 0 then
                  sound.play("error")
                  self.hand_selected_index = nil
                  return
                end
                self:_set_prompt("spell_target", {
                  hand_index = idx,
                  effect_args = args,
                  eligible_player_index = opponent_pi,
                  eligible_board_indices = eligible,
                })
                sound.play("click")
                return
              else
                -- Non-targeted: cast immediately
                local result = self:dispatch_command({
                  type = "PLAY_SPELL_FROM_HAND",
                  player_index = pi,
                  hand_index = idx,
                })
                if result.ok then
                  local pi_panel = self:player_to_panel(pi)
                  local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
                  popup.create(card_def.name .. "!", px_b + pw_b / 2, py_b + 40, { 0.7, 0.85, 1.0 })
                  sound.play("coin")
                else
                  sound.play("error")
                end
                self.hand_selected_index = nil
                return
              end
            else
              sound.play("error")
              self.hand_selected_index = nil
              return
            end
          end
        end
      end
      -- Deselect if not playable
      self.hand_selected_index = nil
      sound.play("click")
    else
      -- Select
      self.hand_selected_index = idx
      sound.play("click")
    end
    return
  end

  -- End turn: in multiplayer, only the local player can end their own turn
  if kind == "end_turn" then
    if self.authoritative_adapter and pi ~= self.local_player_index then return end
    if pi ~= self.game_state.activePlayer then return end
    sound.play("whoosh")
    -- Feature 3: Capture resources before/after start_turn for production popups
    local before = {}
    local after = {}
    local new_active
    local p
    if self.authoritative_adapter then
      -- In multiplayer, the host executes START_TURN automatically after END_TURN.
      -- Capture the next player's resources before dispatch.
      local next_pi = 1 - self.game_state.activePlayer
      p = self.game_state.players[next_pi + 1]
      for _, key in ipairs(config.resource_types) do
        before[key] = p.resources[key] or 0
      end
      self:dispatch_command({ type = "END_TURN", player_index = pi })
      -- State now includes START_TURN effects from the host
      new_active = self.game_state.activePlayer
      p = self.game_state.players[new_active + 1]
      for _, key in ipairs(config.resource_types) do
        after[key] = p.resources[key] or 0
      end
    else
      -- Local mode: send END_TURN and START_TURN separately
      self:dispatch_command({ type = "END_TURN", player_index = pi })
      new_active = self.game_state.activePlayer
      p = self.game_state.players[new_active + 1]
      for _, key in ipairs(config.resource_types) do
        before[key] = p.resources[key] or 0
      end
      self:dispatch_command({ type = "START_TURN", player_index = new_active })
      for _, key in ipairs(config.resource_types) do
        after[key] = p.resources[key] or 0
      end
    end
    -- Spawn production popups near the resource bar
    local new_panel = self:player_to_panel(new_active)
    local rbx, rby, rbw, rbh = board.resource_bar_rect(new_panel)
    local badge_offset = 0
    for _, key in ipairs(config.resource_types) do
      local gained = after[key] - before[key]
      local rdef = res_registry[key]
      if gained > 0 and rdef then
        local letter = rdef.letter
        local color = rdef.color or {0.3, 0.9, 0.4}
        popup.create("+" .. gained .. letter, rbx + 8 + badge_offset + 25, rby - 4, color, { font_size = 12, lifetime = 1.0, vy = -25 })
        sound.play("coin", 0.4)
      end
      -- Advance offset only for resources the player actually has (matching the badge display)
      if p.resources[key] and p.resources[key] > 0 then
        badge_offset = badge_offset + 54
      end
    end
    -- Clear hand selection and pending state on turn change
    self.hand_selected_index = nil
    self:_clear_prompt("play_unit")
    self:_clear_prompt("sacrifice")
    self:_clear_prompt("upgrade")
    self:_clear_prompt("monument")
    self:_clear_prompt("graveyard_return")
    self:_clear_prompt("discard_draw")
    self:_clear_pending_attack_declarations()
    self:_clear_pending_attack_trigger_targets()
    self.pending_block_assignments = {}
    self.pending_damage_orders = {}
    -- Show turn banner
    self.turn_banner_timer = 1.2
    self.turn_banner_text = (self.game_state.activePlayer == self.local_player_index) and "Your Turn" or "Opponent's Turn"
    return
  end

  if kind == "pass" then
    self:_prune_invalid_pending_attacks()

    local c = self.game_state.pendingCombat
    if pi == self.game_state.activePlayer and pi == self.local_player_index and #self.pending_attack_declarations > 0 then
      local result = self:dispatch_command({
        type = "DECLARE_ATTACKERS",
        player_index = pi,
        declarations = self.pending_attack_declarations,
      })
      if result.ok then
        self:_clear_pending_attack_declarations()
        self:_clear_pending_attack_trigger_targets()
        self.pending_block_assignments = {}
        self.pending_damage_orders = {}
        sound.play("whoosh")
      else
        sound.play("error")
      end
      return
    end

    if c and c.stage == "AWAITING_ATTACK_TARGETS" and c.attacker == self.local_player_index then
      local target_payload = self:_build_attack_trigger_target_payload(c)
      local result = self:dispatch_command({
        type = "ASSIGN_ATTACK_TRIGGER_TARGETS",
        player_index = self.local_player_index,
        targets = target_payload,
      })
      if result.ok then
        self:_clear_pending_attack_trigger_targets()
        sound.play("whoosh")
      else
        sound.play("error")
      end
      return
    end

    if c and c.stage == "DECLARED" and c.defender == self.local_player_index then
      local result = self:dispatch_command({
        type = "ASSIGN_BLOCKERS",
        player_index = self.local_player_index,
        assignments = self.pending_block_assignments,
      })
      if result.ok then
        self:_clear_pending_attack_trigger_targets()
        self.pending_block_assignments = {}
        self.pending_damage_orders = {}
        local pending = self.game_state.pendingCombat
        if pending and pending.stage == "AWAITING_DAMAGE_ORDER" then
          sound.play("whoosh")
        else
          local resolve_result = self:dispatch_command({ type = "RESOLVE_COMBAT", player_index = c.attacker })
          if resolve_result.ok then
            sound.play("build")
          else
            sound.play("error")
          end
        end
      else
        sound.play("error")
      end
      return
    end

    if c and c.stage == "AWAITING_DAMAGE_ORDER" and c.attacker == self.local_player_index then
      local orders = self:_build_default_damage_orders(c)
      local order_result = self:dispatch_command({
        type = "ASSIGN_DAMAGE_ORDER",
        player_index = self.local_player_index,
        orders = orders,
      })
      if order_result.ok then
        self.pending_damage_orders = {}
        local resolve_result = self:dispatch_command({ type = "RESOLVE_COMBAT", player_index = self.local_player_index })
        if resolve_result.ok then
          sound.play("build")
        else
          sound.play("error")
        end
      else
        sound.play("error")
      end
      return
    end

    if c and c.stage == "BLOCKERS_ASSIGNED" and c.attacker == self.local_player_index then
      local result = self:dispatch_command({ type = "RESOLVE_COMBAT", player_index = self.local_player_index })
      if result.ok then
        self.pending_damage_orders = {}
        sound.play("build")
      else
        sound.play("error")
      end
      return
    end
    return
  end

  local _cbt = self.game_state.pendingCombat
  local _in_blocker_window = _cbt and _cbt.stage == "DECLARED"
    and (pi == _cbt.attacker or pi == _cbt.defender)
  if kind == "activate_ability" and (pi == self.game_state.activePlayer or _in_blocker_window) then
    local info = extra  -- { source = "base"|"board", board_index = N, ability_index = N }
    local p = self.game_state.players[pi + 1]
    local card_def
    if info.source == "base" then
      card_def = cards.get_card_def(p.baseId)
    elseif info.source == "board" then
      local entry = p.board[info.board_index]
      if entry then
        card_def = cards.get_card_def(entry.card_id)
      end
    end
    if card_def and card_def.abilities then
      local ab = card_def.abilities[info.ability_index]
      if ab and ab.type == "activated" then
        -- During the blocker window only Fast abilities are permitted.
        if _in_blocker_window and not (pi == self.game_state.activePlayer) and not ab.fast then
          sound.play("error")
          return
        end
        if self:_try_start_activated_prompt(pi, p, info, ab) then
          return
        end

        local before_workers = p.totalWorkers
        local before_res = {}
        for k, v in pairs(p.resources) do before_res[k] = v end

        self:dispatch_command({
          type = "ACTIVATE_ABILITY",
          player_index = pi,
          source = {
            type = info.source,
            index = info.board_index,
          },
          ability_index = info.ability_index,
        })

        -- Visual feedback
        sound.play("coin")
        local pi_panel = self:player_to_panel(pi)
        local px_b, py_b, pw_b, ph_b = board.panel_rect(pi_panel)
        -- Show cost deduction popups
        for _, c in ipairs(ab.cost) do
          if before_res[c.type] and p.resources[c.type] < before_res[c.type] then
            local rb_x, rb_y = board.resource_bar_rect(pi_panel)
            popup.create("-" .. c.amount .. string.upper(string.sub(c.type, 1, 1)), rb_x + 25, rb_y - 4, { 1.0, 0.5, 0.25 })
          end
        end
        -- Show effect popup
        if p.totalWorkers > before_workers then
          popup.create("+1 Worker", px_b + pw_b / 2, py_b + ph_b - 80, { 0.3, 0.9, 0.4 })
        end
      end
    end
    return
  end

  -- Legacy compat: activate_base (shouldn't be hit anymore but just in case)
  if kind == "activate_base" and pi == self.game_state.activePlayer then
    local before_workers = self.game_state.players[pi + 1].totalWorkers
    self:dispatch_command({ type = "ACTIVATE_ABILITY", player_index = pi, source = { type = "base" }, ability_index = 1 })
    local after_workers = self.game_state.players[pi + 1].totalWorkers
    if after_workers > before_workers then
      sound.play("coin")
      local ab_panel = self:player_to_panel(pi)
      local px, py, pw, ph = board.panel_rect(ab_panel)
      popup.create("+1 Worker", px + pw / 2, py + ph - 80, { 0.3, 0.9, 0.4 })
      local rb_x, rb_y = board.resource_bar_rect(ab_panel)
      popup.create("-3F", rb_x + 25, rb_y - 4, { 1.0, 0.5, 0.25 })
    end
    return
  end

  if kind == "blueprint" then
    sound.play("click")
    self.show_blueprint_for_player = pi
    blueprint_modal.open(pi, self.game_state)
    return
  end

  if kind == "graveyard" then
    sound.play("click")
    self:open_graveyard_view(pi)
    return
  end

  -- Only local player can initiate drag interactions.
  if self.authoritative_adapter and pi ~= self.local_player_index then return end

  local c = self.game_state.pendingCombat
  local can_declare_attack = (pi == self.game_state.activePlayer and pi == self.local_player_index and not c)
  local can_assign_blocks = (c and c.stage == "DECLARED" and c.defender == self.local_player_index and pi == self.local_player_index)
  local can_assign_damage_order = (c and c.stage == "AWAITING_DAMAGE_ORDER" and c.attacker == self.local_player_index and pi == self.local_player_index)
  local can_worker_actions = (pi == self.game_state.activePlayer and pi == self.local_player_index and not c)

  if kind == "structure" and idx and idx > 0 and is_attack_unit_board_entry(self.game_state, pi, idx, true) and not is_worker_board_entry(self.game_state, pi, idx) and can_declare_attack then
    local mx, my = love.mouse.getPosition()
    self.drag = { player_index = pi, from = "attack_unit", display_x = mx, display_y = my, board_index = idx }
    sound.play("whoosh", 0.6)
    return
  end

  if not can_worker_actions and not can_assign_blocks and not can_assign_damage_order then return end

  if can_assign_blocks and kind == "structure" and idx and idx > 0 and is_attack_unit_board_entry(self.game_state, pi, idx, false) then
    local mx, my = love.mouse.getPosition()
    self.drag = { player_index = pi, from = "block_unit", display_x = mx, display_y = my, board_index = idx }
    sound.play("whoosh", 0.55)
    return
  end

  if can_assign_damage_order and kind == "structure" and idx and idx > 0 and is_attack_unit_board_entry(self.game_state, pi, idx, false) then
    local mx, my = love.mouse.getPosition()
    self.drag = { player_index = pi, from = "order_attacker", display_x = mx, display_y = my, board_index = idx }
    sound.play("whoosh", 0.5)
    return
  end

  if kind == "worker_unassigned" or kind == "worker_left" or kind == "worker_right" or kind == "structure_worker" then
    sound.play("pop")
    local from
    if kind == "worker_unassigned" then from = "unassigned"
    elseif kind == "worker_left" then from = "left"
    elseif kind == "worker_right" then from = "right"
    elseif kind == "structure_worker" then from = "structure"
    end
    local mx, my = love.mouse.getPosition()
    self.drag = { player_index = pi, from = from, display_x = mx, display_y = my, board_index = idx }
  elseif kind == "structure" and is_worker_board_entry(self.game_state, pi, idx) then
    sound.play("pop")
    local mx, my = love.mouse.getPosition()
    local sw_index = get_special_field_index(self.game_state, pi, idx)
    if sw_index then
      self.drag = { player_index = pi, from = "special_field", display_x = mx, display_y = my, board_index = idx, sw_index = sw_index }
    else
      self.drag = { player_index = pi, from = "unit_worker_card", display_x = mx, display_y = my, board_index = idx }
    end
  end

  -- Special worker drag
  if kind == "special_worker_unassigned" or kind == "special_worker_resource" or kind == "special_worker_structure" then
    sound.play("pop")
    local mx, my = love.mouse.getPosition()
    self.drag = { player_index = pi, from = "special", display_x = mx, display_y = my, sw_index = idx }
  end
end

-- Helper: get the origin screen position for a worker based on where it was dragged from
function GameState:_get_worker_origin(pi, from)
  local panel = self:player_to_panel(pi)
  local px, py, pw, ph = board.panel_rect(panel)
  local player = self.game_state.players[pi + 1]
  if from == "unassigned" then
    local uax, uay, uaw, uah = board.unassigned_pool_rect(px, py, pw, ph, player, panel)
    return uax + uaw / 2, uay + uah / 2
  elseif from == "left" then
    local count = player.workersOn[(player.faction == "Human") and "wood" or "food"]
    local cx, cy = board.worker_circle_center(px, py, pw, ph, "left", math.max(1, count), math.max(1, count), panel)
    return cx, cy
  elseif from == "right" then
    local count = player.workersOn.stone
    local cx, cy = board.worker_circle_center(px, py, pw, ph, "right", math.max(1, count), math.max(1, count), panel)
    return cx, cy
  elseif from == "structure" then
    -- Snap back to the structure tile center
    local sax, say, _, _ = board.structures_area_rect(px, py, pw, ph)
    return sax + 45, say + 30
  elseif from == "special" then
    -- Snap back to unassigned pool center
    local uax, uay, uaw, uah = board.unassigned_pool_rect(px, py, pw, ph, player, panel)
    return uax + uaw / 2, uay + uah / 2
  elseif from == "unit_worker_card" then
    local fax, fay, faw = board.front_row_rect(px, py, pw, ph, panel)
    return fax + faw / 2, fay + board.BFIELD_TILE_H / 2
  end
  return px + pw / 2, py + ph / 2
end

-- Spawn a snap-back animation from current drag position to origin
function GameState:_spawn_snap_back()
  if not self.drag then return end
  local origin_x, origin_y = self:_get_worker_origin(self.drag.player_index, self.drag.from)
  self.returning_workers[#self.returning_workers + 1] = {
    x = self.drag.display_x,
    y = self.drag.display_y,
    start_x = self.drag.display_x,
    start_y = self.drag.display_y,
    target_x = origin_x,
    target_y = origin_y,
    progress = 0,
    duration = 0.25,
    alpha = 1,
    scale = 1.2,
  }
end

function GameState:mousereleased(x, y, button, istouch, presses)
  if button ~= 1 then return end
  self.mouse_down = false
  if self.in_game_settings_open then
    if self.in_game_bug_report_open then
      self.in_game_settings_dragging_slider = false
      return
    end
    if self.in_game_settings_dragging_slider then
      self.in_game_settings_dragging_slider = false
      self:_save_in_game_settings_if_dirty()
    end
    return
  end
  if self.game_state and self.game_state.is_terminal then
    self.drag = nil
    return
  end

  if deck_viewer.is_open() then return end

  if not self.drag then return end
  local kind, pi, drop_extra = board.hit_test(x, y, self.game_state, self.hand_y_offsets, self.local_player_index, {
    pending_attack_declarations = self.pending_attack_declarations,
    pending_block_assignments = self.pending_block_assignments,
    pending_attack_trigger_targets = self.pending_attack_trigger_targets,
  })

  -- Feature 2: Invalid drop zone -> snap back
  local allow_opponent_drop = (
    self.drag.from == "attack_unit"
    or self.drag.from == "block_unit"
    or self.drag.from == "order_attacker"
    or (self.drag.from == "unit_worker_card" and kind == "structure")
  ) and kind and pi == (1 - self.drag.player_index)
  if not kind or (pi ~= self.drag.player_index and not allow_opponent_drop) then
    if self.drag.from ~= "attack_unit" and self.drag.from ~= "order_attacker" then
      self:_spawn_snap_back()
    end
    self.drag = nil
    return
  end

  local from = self.drag.from
  local res_left = (self.game_state.players[pi + 1].faction == "Human") and "wood" or "food"
  local did_drop = false

  if from == "attack_unit" then
    local defender_pi = 1 - self.drag.player_index
    if pi == defender_pi and kind == "structure" then
      local target
      if drop_extra == 0 then
        target = { type = "base" }
      elseif drop_extra and drop_extra > 0 then
        target = { type = "board", index = drop_extra }
      end
      if target and not can_stage_attack_target(self.game_state, self.drag.player_index, self.drag.board_index, defender_pi, target.index or 0) then
        target = nil
      end
      if target then
        self:_set_pending_attack(self.drag.board_index, target)
        did_drop = true
        sound.play("click")
      end
    end
    if not did_drop then sound.play("error") end
    self.drag = nil
    return
  end

  if from == "unit_worker_card" then
    local defender_pi = 1 - self.drag.player_index
    if pi == defender_pi and kind == "structure" then
      local target
      if drop_extra == 0 then
        target = { type = "base" }
      elseif drop_extra and drop_extra > 0 then
        target = { type = "board", index = drop_extra }
      end
      if target and not can_stage_attack_target(self.game_state, self.drag.player_index, self.drag.board_index, defender_pi, target.index or 0) then
        target = nil
      end
      if target then
        self:_set_pending_attack(self.drag.board_index, target)
        did_drop = true
        sound.play("click")
        self.drag = nil
        return
      end
      sound.play("error")
      self.drag = nil
      return
    end
  end

  if from == "block_unit" then
    local attacker_pi = 1 - self.drag.player_index
    if pi == attacker_pi and kind == "structure" and drop_extra and drop_extra > 0 then
      self:_set_pending_block(self.drag.board_index, drop_extra)
      did_drop = true
      sound.play("click")
    end
    if not did_drop then sound.play("error") end
    self.drag = nil
    return
  end

  if from == "order_attacker" then
    local defender_pi = 1 - self.drag.player_index
    local pending = self.game_state.pendingCombat
    if pi == defender_pi and kind == "structure" and drop_extra and drop_extra > 0 and pending and pending.blockers then
      local is_legal_blocker = false
      for _, blk in ipairs(pending.blockers) do
        if blk.attacker_board_index == self.drag.board_index and blk.blocker_board_index == drop_extra then
          is_legal_blocker = true
          break
        end
      end
      if is_legal_blocker then
        self:_append_pending_damage_order(self.drag.board_index, drop_extra)
        did_drop = true
        sound.play("click")
      end
    end
    if not did_drop then sound.play("error") end
    self.drag = nil
    return
  end

  -- Special worker drop handling
  if from == "special" or from == "special_field" then
    local sw_index = self.drag.sw_index
    local player = self.game_state.players[pi + 1]
    local sw = player.specialWorkers[sw_index]
    if sw then
      local was_assigned = sw.assigned_to ~= nil
      if kind == "unassigned_pool" or kind == "worker_unassigned" or kind == "special_worker_unassigned" then
        -- Drop to unassigned pool
        if was_assigned then
          did_drop = self:dispatch_command({ type = "UNASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index }).ok
        end
      elseif kind == "resource_left" then
        if was_assigned then
          self:dispatch_command({ type = "UNASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index })
        end
        did_drop = self:dispatch_command({ type = "ASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index, target = res_left }).ok
      elseif kind == "resource_right" then
        if was_assigned then
          self:dispatch_command({ type = "UNASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index })
        end
        did_drop = self:dispatch_command({ type = "ASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index, target = "stone" }).ok
      elseif kind == "structure" or kind == "structure_worker" then
        local drop_si = drop_extra
        if drop_si then
          if was_assigned then
            self:dispatch_command({ type = "UNASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index })
          end
          if from == "special_field" and self.drag.board_index and self.drag.board_index < drop_si then
            drop_si = drop_si - 1
          end
          local target_entry = self.game_state.players[pi + 1].board[drop_si]
          local ok_def, target_def = false, nil
          if target_entry then
            ok_def, target_def = pcall(cards.get_card_def, target_entry.card_id)
          end
          if ok_def and target_def and target_def.kind == "Worker" then
            did_drop = self:dispatch_command({ type = "ASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index, target = { type = "field" } }).ok
          else
            did_drop = self:dispatch_command({ type = "ASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index, target = { type = "structure", board_index = drop_si } }).ok
          end
        end
      elseif kind == "unit_row" then
        if was_assigned then
          self:dispatch_command({ type = "UNASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index })
        end
        did_drop = self:dispatch_command({ type = "ASSIGN_SPECIAL_WORKER", player_index = pi, sw_index = sw_index, target = { type = "field" } }).ok
      end
    end
    if did_drop then
      sound.play("pop")
    else
      self:_spawn_snap_back()
    end
    self.drag = nil
    return
  end

  -- Drop target (unassigned pool or clicking an unassigned worker = same zone)
  if kind == "unassigned_pool" or kind == "worker_unassigned" then
    if from == "unit_worker_card" then
      did_drop = self:dispatch_command({ type = "RECLAIM_WORKER_FROM_UNIT_ROW", player_index = pi, board_index = self.drag.board_index }).ok
    elseif from == "left" then
      did_drop = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = res_left }).ok
    elseif from == "right" then
      did_drop = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = "stone" }).ok
    elseif from == "structure" then
      did_drop = self:dispatch_command({ type = "UNASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = self.drag.board_index }).ok
    end
  elseif kind == "resource_left" then
    if from == "unit_worker_card" then
      local reclaim_res = self:dispatch_command({ type = "RECLAIM_WORKER_FROM_UNIT_ROW", player_index = pi, board_index = self.drag.board_index })
      if reclaim_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = res_left }).ok
      end
    elseif from == "unassigned" then
      did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = res_left }).ok
    elseif from == "right" then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = "stone" })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = res_left }).ok
      end
    elseif from == "structure" then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = self.drag.board_index })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = res_left }).ok
      end
    end
  elseif kind == "resource_right" then
    if from == "unit_worker_card" then
      local reclaim_res = self:dispatch_command({ type = "RECLAIM_WORKER_FROM_UNIT_ROW", player_index = pi, board_index = self.drag.board_index })
      if reclaim_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = "stone" }).ok
      end
    elseif from == "unassigned" then
      did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = "stone" }).ok
    elseif from == "left" then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = res_left })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = "stone" }).ok
      end
    elseif from == "structure" then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = self.drag.board_index })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_WORKER", player_index = pi, resource = "stone" }).ok
      end
    end
  elseif kind == "structure" or kind == "structure_worker" then
    -- Dropping onto a structure/unit tile
    local drop_si = drop_extra
    local drop_is_worker_card = drop_si and is_worker_board_entry(self.game_state, pi, drop_si)
    if from == "unit_worker_card" and drop_is_worker_card then
      did_drop = true
    elseif from == "unit_worker_card" and drop_si then
      local reclaim_res = self:dispatch_command({ type = "RECLAIM_WORKER_FROM_UNIT_ROW", player_index = pi, board_index = self.drag.board_index })
      if reclaim_res.ok then
        if self.drag.board_index < drop_si then
          drop_si = drop_si - 1
        end
        did_drop = self:dispatch_command({ type = "ASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = drop_si }).ok
      end
    elseif from ~= "unit_worker_card" and drop_is_worker_card then
      if from == "left" then
        local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = res_left })
        if unassign_res.ok then
          did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
        end
      elseif from == "right" then
        local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = "stone" })
        if unassign_res.ok then
          did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
        end
      elseif from == "structure" then
        local unassign_res = self:dispatch_command({ type = "UNASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = self.drag.board_index })
        if unassign_res.ok then
          did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
        end
      else
        did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
      end
    elseif from == "unassigned" and drop_si then
      did_drop = self:dispatch_command({ type = "ASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = drop_si }).ok
    elseif from == "left" and drop_si then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = res_left })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = drop_si }).ok
      end
    elseif from == "right" and drop_si then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = "stone" })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "ASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = drop_si }).ok
      end
    elseif from == "structure" and drop_si then
      -- Moving worker between structures
      if self.drag.board_index ~= drop_si then
        local unassign_res = self:dispatch_command({ type = "UNASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = self.drag.board_index })
        if unassign_res.ok then
          did_drop = self:dispatch_command({ type = "ASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = drop_si }).ok
        end
      end
    end
  elseif kind == "unit_row" then
    if from == "unit_worker_card" then
      did_drop = true
    elseif from == "left" then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = res_left })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
      end
    elseif from == "right" then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_WORKER", player_index = pi, resource = "stone" })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
      end
    elseif from == "structure" then
      local unassign_res = self:dispatch_command({ type = "UNASSIGN_STRUCTURE_WORKER", player_index = pi, board_index = self.drag.board_index })
      if unassign_res.ok then
        did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
      end
    else
      did_drop = self:dispatch_command({ type = "DEPLOY_WORKER_TO_UNIT_ROW", player_index = pi }).ok
    end
  end

  if did_drop then
    sound.play("pop")
  else
    -- Dropped on a non-matching zone (e.g. same zone it came from) -> snap back
    self:_spawn_snap_back()
  end
  self.drag = nil
end

function GameState:mousemoved(x, y, dx, dy, istouch)
  if self.in_game_settings_open then
    if self.in_game_bug_report_open then
      self.hover = nil
      self.hand_hover_index = nil
      return
    end
    if self.in_game_settings_dragging_slider then
      local layout = self:_in_game_settings_layout()
      self:_set_in_game_settings_volume_from_mouse_x(x, layout)
    end
    self.hover = nil
    self.hand_hover_index = nil
    return
  end
  -- Update hover state for UI highlights
  local kind, pi, idx = board.hit_test(x, y, self.game_state, self.hand_y_offsets, self.local_player_index, {
    pending_attack_declarations = self.pending_attack_declarations,
    pending_block_assignments = self.pending_block_assignments,
    pending_attack_trigger_targets = self.pending_attack_trigger_targets,
  })
  if kind then
    self.hover = { kind = kind, pi = pi, idx = idx }
  else
    self.hover = nil
  end

  -- Track hand hover index for animation
  if kind == "hand_card" then
    self.hand_hover_index = idx
  else
    self.hand_hover_index = nil
  end
end

function GameState:keypressed(key, scancode, isrepeat)
  if self.in_game_settings_open then
    if self.in_game_bug_report_open and self:_handle_in_game_bug_report_keypressed(key, scancode, isrepeat) then
      return
    end
    if key == "escape" then
      self:_close_in_game_settings()
      sound.play("click")
    end
    return
  end

  if key == "f8" then
    local pi = self.local_player_index
    local p = self.game_state.players[pi + 1]
    local gained = 0
    for _, res in ipairs(config.resource_types) do
      if p.resources[res] ~= nil then
        local result = self:dispatch_command({
          type = "DEBUG_ADD_RESOURCE",
          player_index = pi,
          resource = res,
          amount = 5,
        })
        if result.ok then gained = gained + 1 end
      end
    end
    if gained > 0 then
      sound.play("coin")
      local panel = self:player_to_panel(pi)
      local px, py, pw = board.panel_rect(panel)
      popup.create("[DEBUG] +5 all resources", px + pw / 2, py + 8, { 1.0, 0.85, 0.2 })
    else
      sound.play("error")
    end
    return
  end

  if deck_viewer.is_open() then
    local was_open = deck_viewer.is_open()
    deck_viewer.keypressed(key)
    if was_open and not deck_viewer.is_open() then
      self.show_blueprint_for_player = nil
      self:_clear_prompt("graveyard_return")
    end
    return
  end
  -- Escape to cancel pending selection, deselect hand card, or open in-game settings.
  if key == "escape" then
    if self:_cancel_top_prompt_for_context("escape") then
      sound.play("click")
      return
    end
    if #self.pending_attack_trigger_targets > 0 then
      self:_clear_pending_attack_trigger_targets()
      sound.play("click")
      return
    end
    if self.hand_selected_index then
      self.hand_selected_index = nil
      return
    end
    if #self.pending_attack_declarations > 0 then
      self:_clear_pending_attack_declarations()
      sound.play("click")
      return
    end
    if self:_has_in_game_settings_blocker() then
      return
    end
    self:_open_in_game_settings()
    sound.play("click")
    return
  end
end

function GameState:wheelmoved(dx, dy)
  if deck_viewer.is_open() then
    deck_viewer.wheelmoved(dx, dy)
    return
  end
end

function GameState:textinput(text)
  if self.in_game_settings_open and self.in_game_bug_report_open then
    if self:_handle_in_game_bug_report_textinput(text) then
      return
    end
  end
  if deck_viewer.is_open() then
    deck_viewer.textinput(text)
    return
  end
end

return GameState
