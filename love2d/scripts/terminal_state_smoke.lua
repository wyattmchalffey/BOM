-- Smoke test for terminal match state and post-game command blocking.
-- Run from repo root:
--   lua love2d/scripts/terminal_state_smoke.lua

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

local function has_match_ended_event(events)
  for _, event in ipairs(events or {}) do
    if event.type == "match_ended" then
      return true
    end
  end
  return false
end

local g = game_state.create_initial_game_state({ first_player = 0 })

assert_ok(commands.execute(g, { type = "START_TURN", player_index = 0 }), "start turn")

-- Force a near-lethal board state so one combat resolve ends the match.
g.players[2].life = 1
g.players[1].board = {
  { card_id = "HUMAN_UNIT_SOLDIER", state = { rested = false } },
}

assert_ok(commands.execute(g, {
  type = "DECLARE_ATTACKERS",
  player_index = 0,
  declarations = {
    { attacker_board_index = 1, target = { type = "base" } },
  },
}), "declare attackers")

local resolved = commands.execute(g, { type = "RESOLVE_COMBAT", player_index = 0 })
assert_ok(resolved, "resolve combat")

if not g.is_terminal then
  fail("expected terminal state after lethal base damage")
end
if g.winner ~= 0 then
  fail("expected winner to be player 0")
end
if g.reason ~= "base_destroyed" then
  fail("expected terminal reason base_destroyed")
end
if type(g.ended_at_turn) ~= "number" or g.ended_at_turn < 1 then
  fail("expected ended_at_turn to be set")
end
if not (resolved.meta and resolved.meta.is_terminal) then
  fail("expected resolve meta to include is_terminal")
end
if not has_match_ended_event(resolved.events) then
  fail("expected resolve events to include match_ended")
end

local blocked = commands.execute(g, { type = "END_TURN", player_index = 0 })
if blocked.ok or blocked.reason ~= "game_over" then
  fail("expected commands to be blocked after game end")
end

print("Terminal state smoke test passed")
