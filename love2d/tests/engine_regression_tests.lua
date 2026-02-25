-- Lightweight engine regression tests (plain Lua, no external framework).
-- Run from repo root:
--   lua love2d/tests/engine_regression_tests.lua

package.path = table.concat({
  "./love2d/?.lua",
  "./love2d/?/init.lua",
  "./love2d/src/?.lua",
  "./love2d/src/?/init.lua",
  package.path or "",
}, ";")

local abilities = require("src.game.abilities")
local actions = require("src.game.actions")
local cards = require("src.game.cards")
local checksum = require("src.game.checksum")
local commands = require("src.game.commands")
local deck_validation = require("src.game.deck_validation")
local effect_specs = require("src.game.effect_specs")
local game_events = require("src.game.events")
local game_state = require("src.game.state")
local host_mod = require("src.net.host")
local replay = require("src.game.replay")
local unit_stats = require("src.game.unit_stats")

local tests = {}

local function add_test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local function fail(msg, level)
  error(msg or "assertion failed", (level or 1) + 1)
end

local function assert_true(v, msg)
  if v ~= true then fail(msg or ("expected true, got " .. tostring(v)), 2) end
end

local function assert_false(v, msg)
  if v ~= false then fail(msg or ("expected false, got " .. tostring(v)), 2) end
end

local function assert_equal(actual, expected, msg)
  if actual ~= expected then
    fail((msg or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local function assert_match(s, pattern, msg)
  if type(s) ~= "string" or not string.find(s, pattern) then
    fail((msg or "string mismatch") .. ": " .. tostring(s), 2)
  end
end

local function has_subtype(card_def, subtype)
  if type(card_def) ~= "table" or type(card_def.subtypes) ~= "table" then return false end
  for _, st in ipairs(card_def.subtypes) do
    if st == subtype then return true end
  end
  return false
end

local function matches_global_buff_target(target_def, args)
  if type(target_def) ~= "table" or type(args) ~= "table" then return false end
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

local function has_static_effect(card_def, effect_name)
  for _, ab in ipairs(card_def.abilities or {}) do
    if ab.type == "static" and ab.effect == effect_name then
      return true
    end
  end
  return false
end

local function find_global_buff_fixture()
  for _, src_def in ipairs(cards.CARD_DEFS) do
    for _, ab in ipairs(src_def.abilities or {}) do
      if ab.type == "static" and ab.effect == "global_buff" then
        local args = ab.effect_args or {}
        local atk = tonumber(args.attack) or 0
        local hp = tonumber(args.health) or 0
        if atk ~= 0 or hp ~= 0 then
          for _, target_def in ipairs(cards.CARD_DEFS) do
            if (target_def.kind == "Unit" or target_def.kind == "Worker")
              and not has_static_effect(target_def, "global_buff")
              and matches_global_buff_target(target_def, args) then
              return {
                source_def = src_def,
                ability = ab,
                target_def = target_def,
                attack_bonus = atk,
                health_bonus = hp,
              }
            end
          end
        end
      end
    end
  end
  return nil
end

local function find_card_with_support_warning()
  for _, def in ipairs(cards.CARD_DEFS) do
    local warnings = cards.get_support_warnings(def.id)
    if #warnings > 0 then
      return def, warnings
    end
  end
  return nil, nil
end

add_test("effect_specs accepts valid deal_damage args", function()
  local err = effect_specs.validate_effect_args("deal_damage", { damage = 3, target = "unit" })
  assert_equal(err, nil, "expected valid deal_damage args")
end)

add_test("effect_specs rejects missing required args", function()
  local err = effect_specs.validate_effect_args("deal_damage", { target = "unit" })
  assert_true(type(err) == "string", "expected validation error")
  assert_match(err, "effect_args%.damage", "expected missing damage error")
end)

add_test("effect_specs rejects malformed search_deck criteria", function()
  local err = effect_specs.validate_effect_args("search_deck", {
    search_criteria = {
      { kind = "Spell", nope = true },
    },
  })
  assert_true(type(err) == "string", "expected validation error")
  assert_match(err, "not supported", "expected unsupported search criteria field")
end)

add_test("effect_specs exposes support level metadata", function()
  assert_equal(effect_specs.get_support_level("deal_damage"), "implemented", "deal_damage should be fully supported")
  assert_equal(effect_specs.get_support_level("opt"), "partial", "opt should be marked partial")
end)

add_test("abilities collects declarative global damage targets across both boards and bases", function()
  local g = {
    players = {
      { board = { { card_id = "HUMAN_UNIT_CATAPULT", state = {} } } },
      { board = { { card_id = "HUMAN_UNIT_PHILOSOPHER", state = {} } } },
    },
  }

  local info, reason = abilities.collect_effect_target_candidates(g, 0, "deal_damage", {
    damage = 2,
    target = "global",
  })

  assert_equal(reason, nil, "unexpected target collection error")
  assert_true(type(info) == "table", "expected target candidate info")
  assert_true(info.requires_target == true, "expected target selection to be required")
  assert_true(type(info.eligible_board_indices_by_player) == "table", "expected per-player board target lists")
  assert_equal(#(info.eligible_board_indices_by_player[0] or {}), 1, "expected own-board target for global damage")
  assert_equal(#(info.eligible_board_indices_by_player[1] or {}), 1, "expected opponent-board target for global damage")
  assert_true(type(info.eligible_base_player_indices) == "table", "expected base target eligibility")
  assert_true(info.eligible_base_player_indices[0] == true, "expected own base to be eligible")
  assert_true(info.eligible_base_player_indices[1] == true, "expected opponent base to be eligible")
end)

add_test("abilities declarative activated x-cost helpers validate and pay x resource costs", function()
  local ability = {
    type = "activated",
    effect = "deal_damage_x",
    cost = { { type = "gold", amount = 1 } },
    effect_args = { resource = "stone", target = "unit" },
  }
  local resources = { gold = 1, stone = 3 }

  local max_x, resource_name, max_err = abilities.max_activated_variable_cost_amount(resources, ability)
  assert_equal(max_err, nil, "unexpected max-x error")
  assert_equal(resource_name, "stone", "unexpected x-cost resource")
  assert_equal(max_x, 3, "unexpected max x")

  local can_pay_min = abilities.can_pay_activated_ability_cost(resources, ability, { require_variable_min = true })
  assert_true(can_pay_min == true, "expected x-ability min-cost check to pass")
  local can_pay_two = abilities.can_pay_activated_ability_cost(resources, ability, { x_amount = 2 })
  assert_true(can_pay_two == true, "expected x=2 to be payable")
  local can_pay_four, reason_four = abilities.can_pay_activated_ability_cost(resources, ability, { x_amount = 4 })
  assert_false(can_pay_four, "expected x=4 to fail")
  assert_equal(reason_four, "insufficient_resources", "unexpected x-cost failure reason")

  local paid, pay_reason = abilities.pay_activated_ability_cost(resources, ability, { x_amount = 2 })
  assert_true(paid == true, "expected x-cost payment to succeed")
  assert_equal(pay_reason, nil, "unexpected x-cost pay error")
  assert_equal(resources.gold, 0, "expected fixed cost to be paid")
  assert_equal(resources.stone, 1, "expected x resource cost to be paid")
end)

add_test("abilities full activated cost helper enforces and applies rest cost", function()
  local ability = {
    type = "activated",
    effect = "deal_damage",
    rest = true,
    cost = { { type = "gold", amount = 1 } },
    effect_args = { damage = 2, target = "unit" },
  }

  local source_entry = { state = { rested = false } }
  local resources = { gold = 1 }

  local ok_ready, err_ready = abilities.can_pay_activated_ability_costs(resources, ability, {
    source_entry = source_entry,
  })
  assert_true(ok_ready == true, "expected ready source to satisfy full activated costs")
  assert_equal(err_ready, nil, "unexpected full-cost ready error")

  local paid, pay_reason = abilities.pay_activated_ability_costs(resources, ability, {
    source_entry = source_entry,
  })
  assert_true(paid == true, "expected full activated cost payment to succeed")
  assert_equal(pay_reason, nil, "unexpected full-cost payment error")
  assert_equal(resources.gold, 0, "expected resource cost to be paid")
  assert_true(source_entry.state.rested == true, "expected rest cost to mark source rested")

  local blocked, blocked_reason = abilities.can_pay_activated_ability_costs({ gold = 1 }, ability, {
    source_entry = source_entry,
  })
  assert_false(blocked, "expected rested source to fail rest cost check")
  assert_equal(blocked_reason, "unit_is_rested", "unexpected rest-cost failure reason")
end)

add_test("abilities full activated cost helper enforces and applies counter removal cost", function()
  local ability = {
    type = "activated",
    effect = "remove_counter_draw",
    cost = {},
    effect_args = { counter = "knowledge", remove = 2, draw = 1 },
  }
  local source_entry = { state = { counters = { knowledge = 1 } } }

  local ok_insufficient, reason_insufficient = abilities.can_pay_activated_ability_costs({}, ability, {
    source_entry = source_entry,
  })
  assert_false(ok_insufficient, "expected insufficient counters to fail")
  assert_equal(reason_insufficient, "insufficient_counters", "unexpected insufficient counter reason")

  source_entry.state.counters.knowledge = 3
  local ok_now, reason_now = abilities.can_pay_activated_ability_costs({}, ability, {
    source_entry = source_entry,
  })
  assert_true(ok_now == true, "expected sufficient counters to pass")
  assert_equal(reason_now, nil, "unexpected counter-cost validation error")

  local paid, pay_reason = abilities.pay_activated_ability_costs({}, ability, {
    source_entry = source_entry,
  })
  assert_true(paid == true, "expected counter cost payment to succeed")
  assert_equal(pay_reason, nil, "unexpected counter cost payment error")
  assert_equal(unit_stats.counter_count(source_entry.state, "knowledge"), 1, "expected counters to be removed")
end)

add_test("commands ACTIVATE_ABILITY with remove_counter_draw pays counter cost once and resolves effect", function()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      { faction = "Human" },
      { faction = "Orc" },
    },
  })
  g.activePlayer = 0
  g.phase = "MAIN"

  local p = g.players[1]
  p.hand = {}
  p.deck = { "HUMAN_UNIT_CATAPULT" }
  p.board = {
    {
      card_id = "HUMAN_UNIT_PHILOSOPHER",
      state = { counters = { knowledge = 1 } },
    },
  }

  local res = commands.execute(g, {
    type = "ACTIVATE_ABILITY",
    player_index = 0,
    source = { type = "board", index = 1 },
    ability_index = 1,
  })

  assert_true(type(res) == "table" and res.ok == true, "expected ACTIVATE_ABILITY to succeed")
  assert_equal(#p.hand, 1, "expected draw effect to resolve")
  assert_equal(unit_stats.counter_count(p.board[1].state, "knowledge"), 0, "expected one knowledge counter to be spent")
end)

add_test("abilities collects declarative monument play-cost targets", function()
  local g = {
    players = {
      {
        board = {
          { card_id = "ORC_UNIT_GARGOYLE", state = { counters = { wonder = 2 } } },
          { card_id = "HUMAN_UNIT_PHILOSOPHER", state = {} },
        },
      },
      { board = {} },
    },
  }
  local stone_toss = cards.get_card_def("ORC_SPELL_STONE_TOSS")
  local info, err = abilities.collect_card_play_cost_targets(g, 0, stone_toss)
  assert_equal(err, nil, "unexpected monument target collection error")
  assert_true(type(info) == "table", "expected monument play-cost target info")
  assert_equal(info.effect, "monument_cost", "unexpected play-cost effect")
  assert_equal(info.min_counters, 2, "unexpected monument min counter requirement")
  assert_equal(#(info.eligible_board_indices or {}), 1, "expected one eligible monument")
  assert_equal(info.eligible_board_indices[1], 1, "expected gargoyle to be eligible monument")
end)

add_test("commands PLAY_SPELL_FROM_HAND supports declarative monument cost", function()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      { faction = "Orc" },
      { faction = "Human" },
    },
  })
  g.activePlayer = 0
  g.phase = "MAIN"

  local p1 = g.players[1]
  local p2 = g.players[2]
  p1.hand = { "ORC_SPELL_STONE_TOSS" }
  p1.deck = {}
  p1.graveyard = {}
  p1.board = {
    { card_id = "ORC_UNIT_GARGOYLE", state = { counters = { wonder = 2 } } },
  }
  p2.board = {
    { card_id = "HUMAN_UNIT_PRINCE_OF_REASON", state = {} },
  }

  local res = commands.execute(g, {
    type = "PLAY_SPELL_FROM_HAND",
    player_index = 0,
    hand_index = 1,
    monument_board_index = 1,
    target_player_index = 1,
    target_board_index = 1,
  })

  assert_true(type(res) == "table" and res.ok == true, "expected PLAY_SPELL_FROM_HAND to succeed via monument cost")
  assert_equal(#p1.hand, 0, "expected spell removed from hand")
  assert_equal(#p1.graveyard, 1, "expected spell moved to graveyard")
  assert_equal(p1.graveyard[1].card_id, "ORC_SPELL_STONE_TOSS", "unexpected graveyard spell")
  assert_equal(unit_stats.counter_count(p1.board[1].state, "wonder"), 1, "expected one wonder counter to be spent")
end)

add_test("commands PLAY_SPELL_FROM_HAND uses shared direct spell-cast action path", function()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      { faction = "Orc" },
      { faction = "Human" },
    },
  })
  g.activePlayer = 0
  g.phase = "MAIN"

  local p1 = g.players[1]
  local p2 = g.players[2]
  p1.hand = { "ORC_SPELL_MORTAL_COIL" }
  p1.graveyard = {}
  p2.board = {
    { card_id = "HUMAN_UNIT_PHILOSOPHER", state = {} },
  }

  local res = commands.execute(g, {
    type = "PLAY_SPELL_FROM_HAND",
    player_index = 0,
    hand_index = 1,
    target_player_index = 1,
    target_board_index = 1,
  })

  assert_true(type(res) == "table" and res.ok == true, "expected PLAY_SPELL_FROM_HAND to succeed")
  assert_equal(res.events[1] and res.events[1].type, "spell_cast", "unexpected command event type")
  assert_equal(#p1.hand, 0, "expected spell removed from hand")
  assert_equal(#p1.graveyard, 1, "expected spell moved to graveyard")
  assert_equal(p1.graveyard[1].card_id, "ORC_SPELL_MORTAL_COIL", "unexpected graveyard spell")
  assert_equal(#p2.board, 0, "expected mortal coil to destroy enemy target")
  assert_true(type(res.meta) == "table" and type(res.meta.resolve_result) == "table", "expected resolve_result metadata")
end)

add_test("abilities collects declarative worker sacrifice play-cost metadata", function()
  local g = { players = { { board = {} }, { board = {} } } }
  local family = cards.get_card_def("HUMAN_WORKER_LOVING_FAMILY")
  local info, err = abilities.collect_card_play_cost_targets(g, 0, family)
  assert_equal(err, nil, "unexpected worker-sacrifice play-cost collection error")
  assert_true(type(info) == "table", "expected worker-sacrifice play-cost info")
  assert_equal(info.effect, "play_cost_sacrifice", "unexpected play-cost effect")
  assert_equal(info.required_count, 2, "unexpected worker sacrifice count")
end)

add_test("abilities collects declarative activated sacrifice selection targets", function()
  local g = {
    players = {
      {
        totalWorkers = 1,
        board = {
          { card_id = "ORC_UNIT_BRITTLE_SKELETON", state = {} },
          { card_id = "HUMAN_UNIT_PHILOSOPHER", state = {} },
        },
      },
      { totalWorkers = 0, board = {} },
    },
  }
  local altar = cards.get_card_def("ORC_STRUCTURE_SACRIFICIAL_ALTAR")
  local ability = altar.abilities[1]

  local info, err = abilities.collect_activated_selection_cost_targets(g, 0, ability)
  assert_equal(err, nil, "unexpected selection-cost collection error")
  assert_true(type(info) == "table", "expected selection-cost info")
  assert_true(info.requires_selection == true, "expected selection requirement")
  assert_equal(info.kind, "sacrifice_target", "unexpected selection-cost kind")
  assert_true(info.allow_worker_tokens == true, "expected worker tokens to be allowed")
  assert_true(info.has_worker_tokens == true, "expected worker token availability")
  assert_equal(#(info.eligible_board_indices or {}), 1, "expected one non-undead sacrifice target")
  assert_equal(info.eligible_board_indices[1], 2, "expected non-undead target to be eligible")
end)

add_test("abilities validates declarative activated sacrifice selection restrictions", function()
  local g = {
    players = {
      {
        totalWorkers = 2,
        board = {
          { card_id = "HUMAN_UNIT_PHILOSOPHER", state = {} },
        },
      },
      { totalWorkers = 0, board = {} },
    },
  }
  local necromancer = cards.get_card_def("ORC_UNIT_NECROMANCER")
  local ability = necromancer.abilities[1]

  local ok_board, err_board = abilities.validate_activated_selection_cost(g, 0, ability, {
    target_board_index = 1,
  })
  assert_true(ok_board == true, "expected board sacrifice target to be valid")
  assert_equal(err_board, nil, "unexpected board selection-cost error")

  local ok_worker, err_worker = abilities.validate_activated_selection_cost(g, 0, ability, {
    target_worker = "worker_left",
  })
  assert_false(ok_worker, "expected worker sacrifice to be rejected for sacrifice_cast_spell")
  assert_equal(err_worker, "worker_sacrifice_not_allowed", "unexpected worker selection-cost error")
end)

add_test("abilities collects declarative upgrade sacrifice selection targets", function()
  local g = {
    players = {
      {
        totalWorkers = 1,
        hand = { "ORC_UNIT_BONE_DADDY" }, -- T1 Warrior
        board = {
          { card_id = "ORC_WORKER_GRUNT", state = {} },      -- T0 Warrior -> eligible (has T1 in hand)
          { card_id = "ORC_UNIT_BONE_DADDY", state = {} },   -- T1 Warrior -> ineligible (no T2 Warrior in hand)
          { card_id = "HUMAN_UNIT_PHILOSOPHER", state = {} } -- non-Warrior
        },
      },
      { totalWorkers = 0, hand = {}, board = {} },
    },
  }
  local pits = cards.get_card_def("ORC_STRUCTURE_FIGHTING_PITS")
  local ability = pits.abilities[1]

  local info, err = abilities.collect_activated_selection_cost_targets(g, 0, ability)
  assert_equal(err, nil, "unexpected upgrade selection-cost collection error")
  assert_true(type(info) == "table", "expected upgrade selection-cost info")
  assert_equal(info.kind, "upgrade_sacrifice_target", "unexpected selection-cost kind")
  assert_equal(#(info.eligible_board_indices or {}), 1, "expected only one eligible upgrade sacrifice target")
  assert_equal(info.eligible_board_indices[1], 1, "expected T0 Warrior board unit to be eligible")
  assert_true(info.allow_worker_tokens == true, "expected upgrade to allow worker token sacrifices")
  assert_true(info.has_worker_tokens == true, "expected worker sacrifice option with T1 follow-up in hand")
end)

add_test("abilities validates declarative upgrade sacrifice selection targets", function()
  local g = {
    players = {
      {
        totalWorkers = 1,
        hand = { "ORC_UNIT_BONE_DADDY" }, -- T1 Warrior only
        board = {
          { card_id = "ORC_WORKER_GRUNT", state = {} },
          { card_id = "ORC_UNIT_BONE_DADDY", state = {} },
        },
      },
      { totalWorkers = 0, hand = {}, board = {} },
    },
  }
  local pits = cards.get_card_def("ORC_STRUCTURE_FIGHTING_PITS")
  local ability = pits.abilities[1]

  local ok_worker, err_worker = abilities.validate_activated_selection_cost(g, 0, ability, {
    target_worker = "worker_left",
  })
  assert_true(ok_worker == true, "expected worker upgrade sacrifice target to be valid")
  assert_equal(err_worker, nil, "unexpected worker upgrade selection-cost error")

  local ok_board, err_board = abilities.validate_activated_selection_cost(g, 0, ability, {
    target_board_index = 1,
  })
  assert_true(ok_board == true, "expected T0 Warrior board target to be valid")
  assert_equal(err_board, nil, "unexpected board upgrade selection-cost error")

  local bad_board, bad_reason = abilities.validate_activated_selection_cost(g, 0, ability, {
    target_board_index = 2,
  })
  assert_false(bad_board, "expected T1 Warrior without T2 follow-up to be invalid")
  assert_equal(bad_reason, "invalid_sacrifice_target", "unexpected invalid upgrade target reason")
end)

add_test("actions pays activated declarative sacrifice selection cost for board targets", function()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      { faction = "Orc" },
      { faction = "Human" },
    },
  })
  g.activePlayer = 0
  g.phase = "MAIN"

  local p = g.players[1]
  p.board = {
    { card_id = "HUMAN_UNIT_PHILOSOPHER", state = {} },
  }
  p.graveyard = {}

  local necromancer = cards.get_card_def("ORC_UNIT_NECROMANCER")
  local ability = necromancer.abilities[1] -- sacrifice_cast_spell

  local paid, reason, payment_info = actions.pay_activated_selection_cost(g, 0, ability, {
    target_board_index = 1,
  })

  assert_true(paid == true, "expected board sacrifice payment to succeed")
  assert_equal(reason, nil, "unexpected board sacrifice payment error")
  assert_true(type(payment_info) == "table", "expected payment metadata")
  assert_equal(payment_info.sacrificed_card_id, "HUMAN_UNIT_PHILOSOPHER", "unexpected sacrificed card id")
  assert_equal(payment_info.sacrificed_kind, "Unit", "unexpected sacrificed card kind")
  assert_equal(#p.board, 0, "expected board target to be removed")
end)

add_test("actions pays activated declarative upgrade selection cost for worker targets", function()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      { faction = "Orc" },
      { faction = "Human" },
    },
  })
  g.activePlayer = 0
  g.phase = "MAIN"

  local p = g.players[1]
  p.hand = { "ORC_UNIT_BONE_DADDY" } -- T1 Warrior enables worker-as-T0 upgrade path
  p.totalWorkers = 1
  p.workersOn = { food = 1, wood = 0, stone = 0 }
  p.board = {}

  local pits = cards.get_card_def("ORC_STRUCTURE_FIGHTING_PITS")
  local ability = pits.abilities[1]

  local paid, reason, payment_info = actions.pay_activated_selection_cost(g, 0, ability, {
    target_worker = "worker_left",
  })

  assert_true(paid == true, "expected worker upgrade sacrifice payment to succeed")
  assert_equal(reason, nil, "unexpected worker upgrade payment error")
  assert_equal(p.totalWorkers, 0, "expected worker to be consumed")
  assert_equal(p.workersOn.food, 0, "expected left worker slot to be consumed for Orc")
  assert_true(type(payment_info) == "table", "expected payment metadata")
  assert_equal(payment_info.sacrificed_tier, 0, "expected worker sacrifices to count as tier 0")
  assert_equal(payment_info.sacrificed_kind, "Worker", "expected worker sacrifice metadata kind")
end)

add_test("commands SACRIFICE_UPGRADE_PLAY uses shared declarative selection-cost payment", function()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      { faction = "Orc" },
      { faction = "Human" },
    },
  })
  g.activePlayer = 0
  g.phase = "MAIN"

  local p = g.players[1]
  p.board = {
    { card_id = "ORC_STRUCTURE_FIGHTING_PITS", state = {} },
  }
  p.hand = { "ORC_UNIT_BONE_DADDY" }
  p.totalWorkers = 1
  p.workersOn = { food = 1, wood = 0, stone = 0 }

  local res = commands.execute(g, {
    type = "SACRIFICE_UPGRADE_PLAY",
    player_index = 0,
    source = { type = "board", index = 1 },
    ability_index = 1,
    hand_index = 1,
    target_worker = "worker_left",
  })

  assert_true(type(res) == "table" and res.ok == true, "expected SACRIFICE_UPGRADE_PLAY to succeed")
  assert_equal(#p.hand, 0, "expected upgraded unit removed from hand")
  assert_equal(p.totalWorkers, 0, "expected worker sacrifice to be paid")
  assert_equal(p.workersOn.food, 0, "expected left worker slot to be consumed")
  assert_equal(#p.board, 2, "expected source structure plus upgraded unit on board")
  assert_equal(p.board[2].card_id, "ORC_UNIT_BONE_DADDY", "unexpected upgraded unit played")
end)

add_test("commands SACRIFICE_UNIT worker target uses shared sacrifice_produce action path", function()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      { faction = "Orc" },
      { faction = "Human" },
    },
  })
  g.activePlayer = 0
  g.phase = "MAIN"

  local p = g.players[1]
  p.board = {
    { card_id = "ORC_STRUCTURE_SACRIFICIAL_ALTAR", state = {} },
  }
  p.totalWorkers = 1
  p.workersOn = { food = 1, wood = 0, stone = 0 }
  local before_blood = p.resources.blood or 0

  local res = commands.execute(g, {
    type = "SACRIFICE_UNIT",
    player_index = 0,
    source = { type = "board", index = 1 },
    ability_index = 1,
    target_worker = "worker_left",
  })

  assert_true(type(res) == "table" and res.ok == true, "expected SACRIFICE_UNIT worker path to succeed")
  assert_equal(p.totalWorkers, 0, "expected worker to be consumed")
  assert_equal(p.workersOn.food, 0, "expected left worker slot to be consumed for Orc")
  assert_equal((p.resources.blood or 0), before_blood + 1, "expected sacrifice_produce to grant blood")
  assert_equal(res.events[1] and res.events[1].type, "worker_sacrificed", "unexpected command event type")
end)

add_test("commands SACRIFICE_UNIT board target uses shared sacrifice_produce action path", function()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      { faction = "Orc" },
      { faction = "Human" },
    },
  })
  g.activePlayer = 0
  g.phase = "MAIN"

  local p = g.players[1]
  p.board = {
    { card_id = "ORC_STRUCTURE_SACRIFICIAL_ALTAR", state = {} },
    { card_id = "HUMAN_UNIT_PHILOSOPHER", state = {} },
  }
  local before_blood = p.resources.blood or 0

  local res = commands.execute(g, {
    type = "SACRIFICE_UNIT",
    player_index = 0,
    source = { type = "board", index = 1 },
    ability_index = 1,
    target_board_index = 2,
  })

  assert_true(type(res) == "table" and res.ok == true, "expected SACRIFICE_UNIT board path to succeed")
  assert_equal(#p.board, 1, "expected sacrificed board target to be removed")
  assert_equal(p.board[1].card_id, "ORC_STRUCTURE_SACRIFICIAL_ALTAR", "expected altar to remain on board")
  assert_equal((p.resources.blood or 0), before_blood + 1, "expected sacrifice_produce to grant blood")
  assert_equal(res.events[1] and res.events[1].type, "unit_sacrificed", "unexpected command event type")
  assert_equal(res.meta and res.meta.card_id, "HUMAN_UNIT_PHILOSOPHER", "expected sacrificed unit id in meta")
end)

add_test("commands PLAY_SPELL_VIA_ABILITY uses shared spell-via-ability action path", function()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      { faction = "Orc" },
      { faction = "Human" },
    },
  })
  g.activePlayer = 0
  g.phase = "MAIN"

  local p1 = g.players[1]
  local p2 = g.players[2]
  p1.board = {
    { card_id = "ORC_UNIT_NECROMANCER", state = {} },
    { card_id = "HUMAN_UNIT_PHILOSOPHER", state = {} }, -- sacrifice target
  }
  p1.hand = { "ORC_SPELL_MORTAL_COIL" }
  p1.graveyard = {}
  p2.board = {
    { card_id = "HUMAN_UNIT_PHILOSOPHER", state = {} }, -- valid non-Undead target
  }

  local res = commands.execute(g, {
    type = "PLAY_SPELL_VIA_ABILITY",
    player_index = 0,
    source = { type = "board", index = 1 },
    ability_index = 1,
    hand_index = 1,
    sacrifice_target_board_index = 2,
    target_player_index = 1,
    target_board_index = 1,
  })

  assert_true(type(res) == "table" and res.ok == true, "expected PLAY_SPELL_VIA_ABILITY to succeed")
  assert_equal(res.events[1] and res.events[1].type, "spell_cast_via_ability", "unexpected command event type")
  assert_equal(#p1.hand, 0, "expected spell removed from hand")
  assert_equal(#p1.graveyard, 2, "expected sacrificed unit and spell in graveyard")
  local found_spell = false
  for _, gentry in ipairs(p1.graveyard) do
    if gentry.card_id == "ORC_SPELL_MORTAL_COIL" then
      found_spell = true
      break
    end
  end
  assert_true(found_spell, "expected mortal coil in graveyard")
  assert_equal(#p1.board, 1, "expected sacrifice target to be removed from caster board")
  assert_equal(p1.board[1].card_id, "ORC_UNIT_NECROMANCER", "expected necromancer to remain")
  assert_true((p1.board[1].state or {}).rested == true, "expected rest cost to rest necromancer")
  assert_equal(#p2.board, 0, "expected mortal coil to destroy enemy target")
  assert_true(type(res.meta) == "table" and type(res.meta.resolve_result) == "table", "expected resolve_result metadata")
end)

add_test("commands PLAY_FROM_HAND uses declarative worker sacrifice play-cost validation", function()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      { faction = "Human" },
      { faction = "Orc" },
    },
  })
  g.activePlayer = 0
  g.phase = "MAIN"

  local p = g.players[1]
  p.hand = { "HUMAN_WORKER_LOVING_FAMILY" }
  p.totalWorkers = 3
  p.workersOn = { food = 0, wood = 0, stone = 0 }
  p.board = {}
  p.specialWorkers = {}

  local res = commands.execute(g, {
    type = "PLAY_FROM_HAND",
    player_index = 0,
    hand_index = 1,
  })

  assert_true(type(res) == "table" and res.ok == true, "expected PLAY_FROM_HAND to succeed")
  assert_equal(#p.hand, 0, "expected card removed from hand")
  assert_equal(p.totalWorkers, 1, "expected two workers to be sacrificed")
  assert_true(type(p.specialWorkers) == "table" and #p.specialWorkers == 1, "expected special worker card to be created")
  assert_equal(p.specialWorkers[1].card_id, "HUMAN_WORKER_LOVING_FAMILY", "unexpected special worker card")
end)

add_test("commands PLAY_FROM_HAND_WITH_SACRIFICES pays explicit worker targets via shared play-cost helper", function()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      { faction = "Human" },
      { faction = "Orc" },
    },
  })
  g.activePlayer = 0
  g.phase = "MAIN"

  local p = g.players[1]
  p.hand = { "HUMAN_WORKER_LOVING_FAMILY" }
  p.totalWorkers = 2
  p.workersOn = { food = 0, wood = 1, stone = 1 }
  p.board = {}
  p.specialWorkers = {}

  local res = commands.execute(g, {
    type = "PLAY_FROM_HAND_WITH_SACRIFICES",
    player_index = 0,
    hand_index = 1,
    sacrifice_targets = {
      { kind = "worker_left" },
      { kind = "worker_right" },
    },
  })

  assert_true(type(res) == "table" and res.ok == true, "expected PLAY_FROM_HAND_WITH_SACRIFICES to succeed")
  assert_equal(#p.hand, 0, "expected card removed from hand")
  assert_equal(p.totalWorkers, 0, "expected explicit sacrifices to consume both workers")
  assert_equal(p.workersOn.wood, 0, "expected left worker slot to be consumed")
  assert_equal(p.workersOn.stone, 0, "expected right worker slot to be consumed")
  assert_true(type(p.specialWorkers) == "table" and #p.specialWorkers == 1, "expected special worker card to be created")
end)

add_test("abilities.resolve returns structured result with events", function()
  local player = {
    deck = { "A", "B", "C" },
    hand = {},
  }
  local result = abilities.resolve({
    effect = "draw_cards",
    effect_args = { amount = 2 },
  }, player, nil, {})

  assert_true(type(result) == "table", "expected resolve result table")
  assert_equal(result.effect, "draw_cards", "unexpected effect name")
  assert_true(result.handler_found == true, "expected handler_found")
  assert_true(result.resolved == true, "expected resolved flag")
  assert_true(type(result.events) == "table", "expected events list")
  assert_true(type(result.followups) == "table", "expected followups list")
  assert_true(type(result.prompts) == "table", "expected prompts list")
  assert_equal(#player.hand, 2, "draw_cards should mutate player hand")
  assert_true(#result.events >= 1, "expected draw event")
  assert_equal(result.events[1].type, "cards_drawn", "unexpected resolve event type")
  assert_equal(result.events[1].amount, 2, "unexpected drawn amount in event")
end)

add_test("abilities.resolve handles unknown effects with structured result", function()
  local result = abilities.resolve({ effect = "not_a_real_effect" }, {}, nil, nil)
  assert_true(type(result) == "table", "expected resolve result table")
  assert_equal(result.effect, "not_a_real_effect", "unexpected effect name")
  assert_false(result.handler_found, "unknown effect should not have handler")
  assert_false(result.resolved, "unknown effect should not mark resolved")
  assert_equal(#result.events, 0, "unknown effect should not emit events")
end)

add_test("events.emit returns aggregated resolve result from trigger handlers", function()
  local player = {
    deck = { "X", "Y" },
    hand = {},
    board = {},
  }
  local fake_card_def = {
    id = "TEST_TRIGGER_CARD",
    name = "Test Trigger Card",
    abilities = {
      {
        type = "triggered",
        trigger = "on_play",
        effect = "draw_cards",
        effect_args = { amount = 1 },
      },
    },
  }

  local ok, reason, result = game_events.emit(nil, {
    type = "card_played",
    player = player,
    card_def = fake_card_def,
    triggers = { "on_play" },
  })

  assert_true(ok == true, "expected handled event")
  assert_equal(reason, nil, "expected nil reason on handled event")
  assert_true(type(result) == "table", "expected aggregate result")
  assert_equal(result.event_type, "card_played", "unexpected event_type on aggregate result")
  assert_true(#player.hand == 1, "trigger should draw a card")
  assert_true(#result.events >= 1, "expected nested resolve event")
  assert_equal(result.events[1].type, "cards_drawn", "unexpected nested event type")
end)

add_test("commands ACTIVATE_ABILITY exposes resolve_result metadata", function()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      { faction = "Human" },
      { faction = "Orc" },
    },
  })
  g.players[1].resources.food = 3

  local res = commands.execute(g, {
    type = "ACTIVATE_ABILITY",
    player_index = 0,
    source = { type = "base" },
    ability_index = 1,
  })

  assert_true(type(res) == "table" and res.ok == true, "expected ACTIVATE_ABILITY success")
  assert_true(type(res.meta) == "table", "expected command meta")
  assert_true(type(res.meta.resolve_result) == "table", "expected resolve_result in command meta")
  assert_equal(res.meta.resolve_result.effect, "summon_worker", "unexpected resolved effect")
  assert_true(#(res.meta.resolve_result.events or {}) >= 1, "expected resolve events in command meta")
  assert_equal(res.meta.resolve_result.events[1].type, "workers_summoned", "unexpected command resolve event type")
  local found_normalized = false
  for _, ev in ipairs(res.events or {}) do
    if ev.type == "resolve_effect_event" and ev.resolve_event_type == "workers_summoned" then
      found_normalized = true
      break
    end
  end
  assert_true(found_normalized, "expected normalized resolve_effect_event in command events")
end)

add_test("commands DEAL_DAMAGE_TO_TARGET emits normalized resolve event", function()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      { faction = "Human" },
      { faction = "Orc" },
    },
  })
  g.activePlayer = 0
  g.phase = "MAIN"

  local p1 = g.players[1]
  local p2 = g.players[2]
  p1.resources.stone = 5
  p1.board = {
    { card_id = "HUMAN_UNIT_CATAPULT", state = {} },
  }
  p2.board = {
    { card_id = "HUMAN_UNIT_PHILOSOPHER", state = {} },
  }

  local res = commands.execute(g, {
    type = "DEAL_DAMAGE_TO_TARGET",
    player_index = 0,
    source = { type = "board", index = 1 },
    ability_index = 1,
    target_player_index = 1,
    target_board_index = 1,
  })

  assert_true(type(res) == "table" and res.ok == true, "expected DEAL_DAMAGE_TO_TARGET success")
  assert_true(type(res.meta) == "table", "expected command meta")
  assert_true(type(res.meta.resolve_result) == "table", "expected resolve_result in command meta")
  assert_equal(res.meta.resolve_result.effect, "deal_damage", "unexpected resolve effect")
  assert_equal((p2.board[1].state and p2.board[1].state.damage) or 0, 2, "expected target damage to be applied")

  local found = nil
  for _, ev in ipairs(res.events or {}) do
    if ev.type == "resolve_effect_event" and ev.resolve_event_type == "damage_dealt" then
      found = ev
      break
    end
  end
  assert_true(type(found) == "table", "expected normalized resolve_effect_event for damage")
  assert_equal(found.resolve_event.damage, 2, "unexpected normalized damage")
  assert_equal(found.resolve_event.target_player_index, 1, "unexpected normalized target player")
  assert_equal(found.resolve_event.target_board_index, 1, "unexpected normalized target board index")
end)

add_test("commands BUILD_STRUCTURE exposes resolve_result metadata", function()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      { faction = "Human" },
      { faction = "Orc" },
    },
  })
  local p = g.players[1]
  for k in pairs(p.resources) do
    p.resources[k] = 99
  end
  local card_id = p.blueprintDeck[1]
  assert_true(type(card_id) == "string", "expected blueprint deck entry")

  local res = commands.execute(g, {
    type = "BUILD_STRUCTURE",
    player_index = 0,
    card_id = card_id,
  })

  assert_true(type(res) == "table" and res.ok == true, "expected BUILD_STRUCTURE success")
  assert_true(type(res.meta) == "table", "expected command meta")
  assert_equal(res.meta.card_id, card_id, "unexpected built card id")
  assert_true(type(res.meta.resolve_result) == "table", "expected resolve_result in command meta")
end)

add_test("cards expose support warnings for partial mechanics", function()
  local def, warnings = find_card_with_support_warning()
  assert_true(type(def) == "table", "expected at least one card with support warnings")
  assert_true(type(warnings) == "table" and #warnings > 0, "expected warning list")
  assert_true(warnings[1].level == "partial" or warnings[1].level == "ui_missing", "unexpected warning level")
end)

add_test("activated once-per-turn usage survives board index shift", function()
  local g = {
    players = {
      { board = { { card_id = "A" }, { card_id = "B" } } },
    },
    activatedUsedThisTurn = {},
  }

  abilities.set_activated_ability_used_this_turn(g, 0, "board:2:1", { type = "board", index = 2 }, 1, true)
  assert_true(
    abilities.is_activated_ability_used_this_turn(g, 0, "board:2:1", { type = "board", index = 2 }, 1),
    "expected ability to be marked used before shift"
  )

  table.remove(g.players[1].board, 1)

  assert_true(
    abilities.is_activated_ability_used_this_turn(g, 0, "board:1:1", { type = "board", index = 1 }, 1),
    "expected ability to remain used after index shift"
  )
end)

add_test("trigger once-per-turn usage survives board index shift", function()
  local source_entry = { card_id = "B" }
  local g = {
    players = {
      { board = { { card_id = "A" }, source_entry } },
    },
    activatedUsedThisTurn = {},
  }

  abilities.mark_trigger_fired_once_per_turn(g, 0, 2, source_entry, 1, "on_attack", true)
  assert_false(
    abilities.can_fire_trigger_once_per_turn(g, 0, 2, source_entry, 1, "on_attack", true),
    "expected trigger to be blocked before shift"
  )

  table.remove(g.players[1].board, 1)

  assert_false(
    abilities.can_fire_trigger_once_per_turn(g, 0, 1, source_entry, 1, "on_attack", true),
    "expected trigger to remain blocked after index shift"
  )
end)

add_test("actions deploy_worker_to_unit_row assigns board instance_id", function()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      { faction = "Human" },
      { faction = "Orc" },
    },
  })

  local ok = actions.deploy_worker_to_unit_row(g, g.activePlayer)
  assert_true(ok == true, "expected deploy_worker_to_unit_row to succeed")
  local entry = g.players[g.activePlayer + 1].board[1]
  assert_true(type(entry) == "table", "expected worker board entry")
  assert_true(type(entry.instance_id) == "number", "expected numeric instance_id")
end)

add_test("deck validation surfaces support warnings without failing legality", function()
  local def = nil
  for _, card_def in ipairs(cards.CARD_DEFS) do
    local warnings = cards.get_support_warnings(card_def.id)
    if #warnings > 0 and (card_def.kind ~= "Base" and card_def.kind ~= "ResourceNode") then
      local deck_res = deck_validation.validate_decklist(card_def.faction, { card_def.id })
      if deck_res.ok then
        def = card_def
        assert_true(deck_res.meta.support_warning_count > 0, "expected support warnings in deck meta")
        assert_true(deck_res.meta.support_level == "partial" or deck_res.meta.support_level == "ui_missing", "unexpected deck support level")
        assert_true(type(deck_res.meta.support_warnings) == "table", "expected support warning list in deck meta")
        return
      end
    end
  end
  fail("could not find a valid deck card with support warnings")
end)

add_test("continuous global_buff recalculates after board composition changes", function()
  local fixture = find_global_buff_fixture()
  assert_true(type(fixture) == "table", "could not find a global_buff test fixture in card data")

  local target_state = {}
  local g = {
    players = {
      {
        board = {
          { card_id = fixture.source_def.id, state = {} },
          { card_id = fixture.target_def.id, state = target_state },
        },
      },
      { board = {} },
    },
    activatedUsedThisTurn = {},
  }

  local base_atk = tonumber(fixture.target_def.attack) or 0
  local base_hp = tonumber(fixture.target_def.health) or 0

  local atk_with_buff = unit_stats.effective_attack(fixture.target_def, target_state, g, 0)
  local hp_with_buff = unit_stats.effective_health(fixture.target_def, target_state, g, 0)
  assert_equal(atk_with_buff, math.max(0, base_atk + fixture.attack_bonus), "unexpected buffed attack")
  assert_equal(hp_with_buff, math.max(0, base_hp + fixture.health_bonus), "unexpected buffed health")

  table.remove(g.players[1].board, 1)

  local atk_after_remove = unit_stats.effective_attack(fixture.target_def, target_state, g, 0)
  local hp_after_remove = unit_stats.effective_health(fixture.target_def, target_state, g, 0)
  assert_equal(atk_after_remove, math.max(0, base_atk), "expected attack buff to disappear after source removed")
  assert_equal(hp_after_remove, math.max(0, base_hp), "expected health buff to disappear after source removed")
end)

add_test("checksum.game_state is deterministic and ignores private keys", function()
  local a = {
    turnNumber = 3,
    activePlayer = 1,
    _derived_stats_cache_token = 10,
    players = {
      {
        life = 20,
        resources = { food = 1, wood = 2, stone = 3 },
        board = {
          { card_id = "X", state = { rested = false, _cache = 1 } },
        },
      },
      {
        life = 18,
        resources = { food = 0, wood = 0, stone = 1 },
        board = {},
      },
    },
  }
  local b = {
    players = {
      {
        board = {
          { state = { _cache = 999, rested = false }, card_id = "X" },
        },
        resources = { stone = 3, food = 1, wood = 2 },
        life = 20,
      },
      {
        board = {},
        resources = { wood = 0, food = 0, stone = 1 },
        life = 18,
      },
    },
    activePlayer = 1,
    turnNumber = 3,
    _derived_stats_cache_token = 99,
  }

  local ha = checksum.game_state(a)
  local hb = checksum.game_state(b)
  assert_true(type(ha) == "string" and #ha > 0, "expected checksum string")
  assert_equal(ha, hb, "checksums should match for equivalent state")

  b.players[1].resources.food = 9
  local hc = checksum.game_state(b)
  assert_true(hc ~= ha, "checksum should change when visible state changes")
end)

add_test("replay append records post-state hash telemetry", function()
  local log = replay.new_log({ rules_version = "t", content_version = "t" })
  assert_equal(log.format_version, 2, "expected replay format bump")
  assert_equal(log.state_hash_algorithm, checksum.ALGORITHM, "expected replay hash algorithm metadata")
  assert_equal(log.state_hash_version, checksum.VERSION, "expected replay hash version metadata")

  local state = {
    activePlayer = 1,
    turnNumber = 2,
    players = {
      { life = 20, hand = { "A" }, deck = { "B" } },
      { life = 19, hand = { "__HIDDEN_CARD__" }, deck = { "__HIDDEN_CARD__" } },
    },
  }
  local post_hash = checksum.game_state(state)
  local entry = replay.append(log, { type = "TEST_CMD" }, {
    ok = true,
    reason = "ok",
    meta = {
      checksum = post_hash,
      state_seq = 7,
      checksum_algo = checksum.ALGORITHM,
      checksum_version = checksum.VERSION,
    },
    events = {},
  }, state, {
    post_state_hash_scope = "client_visible",
    post_state_viewer_player_index = 0,
    visible_state_hashes_by_player = { [0] = post_hash },
    host_state_seq = 7,
  })

  assert_equal(entry.post_state_hash, post_hash, "expected replay post-state hash")
  assert_equal(entry.post_state_hash_scope, "client_visible", "unexpected replay hash scope")
  assert_equal(entry.post_state_viewer_player_index, 0, "unexpected viewer index")
  assert_equal(entry.authoritative_checksum, post_hash, "expected authoritative checksum telemetry")
  assert_equal(entry.authoritative_state_seq, 7, "expected authoritative state_seq telemetry")
  assert_true(entry.post_state_hash_matches_authoritative == true, "expected hash match telemetry")
  assert_equal(entry.visible_state_hashes_by_player[0], post_hash, "expected visible hash telemetry copy")
end)

add_test("host submit returns per-player checksum and increments state_seq", function()
  local h = host_mod.new({
    match_id = "test-desync-hash",
    host_player = { name = "Host", faction = "Human" },
    max_players = 2,
  })

  local join = h:join({
    type = "join_match",
    protocol_version = 2,
    rules_version = require("src.data.config").rules_version,
    content_version = require("src.data.config").content_version,
    player_name = "Guest",
    faction = "Orc",
  })
  assert_true(join.ok == true, "expected join to succeed")
  assert_true(h.game_started == true, "expected game to start")

  local p0_meta = h:_build_session_meta(0)
  assert_true(type(p0_meta.checksum) == "string", "expected session checksum")
  assert_true(type(p0_meta.state_seq) == "number", "expected session state_seq")

  local before_seq = p0_meta.state_seq
  local submit_res = h:submit({
    type = "submit_command",
    protocol_version = 2,
    match_id = h.match_id,
    seq = 1,
    command = { type = "DEBUG_ADD_RESOURCE", resource = "food", amount = 1 },
    client_checksum = p0_meta.checksum,
    session_token = h._host_session_token,
  })
  assert_true(submit_res.ok == true, "expected host submit to succeed")
  assert_true(type(submit_res.meta.checksum) == "string", "expected submit checksum")
  assert_equal(submit_res.meta.state_seq, before_seq + 1, "expected state_seq increment after submit")

  local visible_state = submit_res.meta.state
  assert_true(type(visible_state) == "table", "expected visible state snapshot in submit meta")
  assert_equal(submit_res.meta.checksum, checksum.game_state(visible_state), "submit checksum should hash returned visible snapshot")
end)

local passed, failed = 0, 0
for i, t in ipairs(tests) do
  local ok, err = pcall(t.fn)
  if ok then
    io.write(string.format("[PASS] %02d %s\n", i, t.name))
    passed = passed + 1
  else
    io.write(string.format("[FAIL] %02d %s\n  %s\n", i, t.name, tostring(err)))
    failed = failed + 1
  end
end

io.write(string.format("\nEngine regression tests: %d passed, %d failed\n", passed, failed))
if failed > 0 then
  os.exit(1)
end
