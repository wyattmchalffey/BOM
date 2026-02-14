-- Smoke test for command replay determinism.
-- Run with Lua from repo root:
--   lua love2d/scripts/replay_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local game_state = require("src.game.state")
local commands = require("src.game.commands")
local replay = require("src.game.replay")
local config = require("src.data.config")

local function checksum(g)
  local p1 = g.players[1]
  local p2 = g.players[2]
  local parts = {
    tostring(g.turnNumber),
    tostring(g.activePlayer),
    tostring(p1.totalWorkers),
    tostring(p2.totalWorkers),
    tostring(p1.resources.food),
    tostring(p1.resources.wood),
    tostring(p1.resources.stone),
    tostring(p2.resources.food),
    tostring(p2.resources.wood),
    tostring(p2.resources.stone),
  }
  return table.concat(parts, "|")
end

local g = game_state.create_initial_game_state()
local log = replay.new_log({
  command_schema_version = commands.SCHEMA_VERSION,
  rules_version = config.rules_version,
  content_version = config.content_version,
})

local sequence = {
  { type = "START_TURN", player_index = 0 },
  { type = "ASSIGN_WORKER", player_index = 0, resource = "wood" },
  { type = "END_TURN" },
  { type = "START_TURN" },
}

for _, cmd in ipairs(sequence) do
  local result = commands.execute(g, cmd)
  replay.append(log, cmd, result, g)
  if not result.ok then
    io.stderr:write("Command failed: " .. tostring(result.reason) .. "\n")
    os.exit(1)
  end
end

local baseline = checksum(g)

local g2 = game_state.create_initial_game_state()
local replay_result = replay.replay_commands(g2, log, commands.execute)
if not replay_result.ok then
  io.stderr:write("Replay failed at command " .. tostring(replay_result.failed_at) .. ": " .. tostring(replay_result.reason) .. "\n")
  os.exit(1)
end

local replayed = checksum(g2)
if replayed ~= baseline then
  io.stderr:write("Replay mismatch\n")
  io.stderr:write("Expected: " .. baseline .. "\n")
  io.stderr:write("Actual:   " .. replayed .. "\n")
  os.exit(1)
end

print("Replay smoke test passed")
