-- Smoke test for command result semantics:
-- commands that don't mutate state must fail with explicit reasons.
-- Run from repo root:
--   lua love2d/scripts/command_result_semantics_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local game_state = require("src.game.state")
local commands = require("src.game.commands")

local function fail(msg)
  io.stderr:write(msg .. "\n")
  os.exit(1)
end

local function assert_ok(result, label)
  if not result.ok then
    fail(label .. " failed: " .. tostring(result.reason))
  end
end

local function assert_fail(result, expected_reason, label)
  if result.ok then
    fail(label .. " should have failed")
  end
  if expected_reason and result.reason ~= expected_reason then
    fail(label .. " wrong reason: expected " .. expected_reason .. ", got " .. tostring(result.reason))
  end
end

-- Case 1: Structure worker assignment/unassignment must fail when no mutation occurs.
local g1 = game_state.create_initial_game_state({ first_player = 0 })
g1.players[1].resources.stone = 2

assert_ok(commands.execute(g1, {
  type = "BUILD_STRUCTURE",
  player_index = 0,
  card_id = "HUMAN_STRUCTURE_BARRACKS",
}), "build barracks")

assert_fail(commands.execute(g1, {
  type = "ASSIGN_STRUCTURE_WORKER",
  player_index = 0,
  board_index = 1,
}), "structure_not_worker_assignable", "assign worker to non-producer structure")

assert_fail(commands.execute(g1, {
  type = "UNASSIGN_STRUCTURE_WORKER",
  player_index = 0,
  board_index = 1,
}), "no_structure_worker_on_entry", "unassign worker from empty structure")

-- Case 2: Sacrifice worker flow must fail when target can't be consumed.
local g2 = game_state.create_initial_game_state({
  first_player = 0,
  players = {
    [1] = { faction = "Orc" },
  },
})
g2.players[1].resources.stone = 2

assert_ok(commands.execute(g2, {
  type = "BUILD_STRUCTURE",
  player_index = 0,
  card_id = "ORC_STRUCTURE_SACRIFICIAL_ALTAR",
}), "build sacrificial altar")

assert_fail(commands.execute(g2, {
  type = "SACRIFICE_UNIT",
  player_index = 0,
  source = { type = "board", index = 1 },
  ability_index = 1,
  target_worker = "worker_left",
}), "invalid_sacrifice_worker_target", "sacrifice worker without valid target")

assert_ok(commands.execute(g2, {
  type = "ASSIGN_WORKER",
  player_index = 0,
  resource = "food",
}), "assign worker to food")

assert_ok(commands.execute(g2, {
  type = "SACRIFICE_UNIT",
  player_index = 0,
  source = { type = "board", index = 1 },
  ability_index = 1,
  target_worker = "worker_left",
}), "sacrifice assigned worker")

print("Command result semantics smoke test passed")
