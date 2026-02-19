-- Smoke test for end-of-turn unit upkeep.
-- Run with Lua from repo root:
--   lua love2d/scripts/upkeep_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local actions = require("src.game.actions")
local game_state = require("src.game.state")

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    io.stderr:write((message or "assertion failed") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual) .. "\n")
    os.exit(1)
  end
end

local g = game_state.create_initial_game_state({
  first_player = 0,
  players = {
    [1] = { faction = "Orc", starting_resources = { food = 1, wood = 0, stone = 0, metal = 0, gold = 0, bones = 0, blood = 0, ectoplasm = 0, crystal = 0, fire = 0, water = 0 } },
    [2] = { faction = "Human" },
  },
})

local p1 = g.players[1]
p1.board[#p1.board + 1] = { card_id = "ORC_UNIT_BONE_MUNCHER" }
p1.board[#p1.board + 1] = { card_id = "ORC_UNIT_BONE_MUNCHER" }

actions.end_turn(g)

assert_eq(p1.resources.food, 0, "Bone Muncher upkeep should consume 1 food")
assert_eq(#p1.board, 1, "one Bone Muncher should die when second upkeep cannot be paid")
assert_eq(#p1.graveyard, 1, "dead Bone Muncher should move to graveyard")

print("Upkeep smoke test passed")
