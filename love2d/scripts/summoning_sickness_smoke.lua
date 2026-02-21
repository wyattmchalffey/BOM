-- Smoke test for summoning sickness + rush/haste bypass.
-- Run from repo root:
--   lua love2d/scripts/summoning_sickness_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local game_state = require("src.game.state")
local commands = require("src.game.commands")
local cards = require("src.game.cards")

local function assert_ok(result, label)
  if not result.ok then
    error(label .. " failed: " .. tostring(result.reason))
  end
end

local function assert_fail_reason(result, reason, label)
  if result.ok then
    error(label .. " should fail with " .. reason)
  end
  if result.reason ~= reason then
    error(label .. " wrong reason: expected " .. reason .. ", got " .. tostring(result.reason))
  end
end

local function setup_human_play_unit(g)
  local p1 = g.players[1]
  p1.faction = "Human"
  p1.resources.wood = 2
  p1.board = {
    { card_id = "HUMAN_STRUCTURE_BARRACKS", state = { rested = false } },
  }
  p1.hand = { "HUMAN_UNIT_SOLDIER" }
end

local function run_without_rush()
  local g = game_state.create_initial_game_state({
    first_player = 0,
    players = {
      [1] = { faction = "Human" },
      [2] = { faction = "Orc" },
    },
  })

  setup_human_play_unit(g)

  assert_ok(commands.execute(g, {
    type = "PLAY_UNIT_FROM_HAND",
    player_index = 0,
    source = { type = "board", index = 1 },
    ability_index = 1,
    hand_index = 1,
  }), "play unit")

  local summoned = g.players[1].board[2]
  if not summoned or not summoned.state or summoned.state.summoned_turn ~= g.turnNumber then
    error("expected summoned unit to store summoned_turn")
  end

  assert_fail_reason(commands.execute(g, {
    type = "DECLARE_ATTACKERS",
    player_index = 0,
    declarations = {
      { attacker_board_index = 2, target = { type = "base" } },
    },
  }), "summoning_sickness", "declare attacker same turn")

  -- Advance to player 0's next turn.
  assert_ok(commands.execute(g, { type = "END_TURN", player_index = 0 }), "end turn p0")
  assert_ok(commands.execute(g, { type = "END_TURN", player_index = 1 }), "end turn p1")

  assert_ok(commands.execute(g, {
    type = "DECLARE_ATTACKERS",
    player_index = 0,
    declarations = {
      { attacker_board_index = 2, target = { type = "base" } },
    },
  }), "declare attacker next own turn")
end

local function run_with_rush()
  local soldier_def = cards.get_card_def("HUMAN_UNIT_SOLDIER")
  local original_keywords = soldier_def.keywords
  soldier_def.keywords = { "rush" }

  local ok_run, err = pcall(function()
    local g = game_state.create_initial_game_state({
      first_player = 0,
      players = {
        [1] = { faction = "Human" },
        [2] = { faction = "Orc" },
      },
    })

    setup_human_play_unit(g)

    assert_ok(commands.execute(g, {
      type = "PLAY_UNIT_FROM_HAND",
      player_index = 0,
      source = { type = "board", index = 1 },
      ability_index = 1,
      hand_index = 1,
    }), "play rush unit")

    assert_ok(commands.execute(g, {
      type = "DECLARE_ATTACKERS",
      player_index = 0,
      declarations = {
        { attacker_board_index = 2, target = { type = "base" } },
      },
    }), "declare rush attacker same turn")
  end)

  soldier_def.keywords = original_keywords
  if not ok_run then
    error(err)
  end
end

local ok, err = pcall(function()
  run_without_rush()
  run_with_rush()
end)

if not ok then
  io.stderr:write(tostring(err) .. "\n")
  os.exit(1)
end

print("Summoning sickness smoke test passed")
