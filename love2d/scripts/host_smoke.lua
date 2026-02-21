-- Smoke test for authoritative host command flow.
-- Run from repo root:
--   lua love2d/scripts/host_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local protocol = require("src.net.protocol")
local host_mod = require("src.net.host")
local config = require("src.data.config")

local function assert_ok(result, label)
  if not result.ok then
    io.stderr:write(label .. " failed: " .. tostring(result.reason) .. "\n")
    os.exit(1)
  end
end

local host = host_mod.new({ match_id = "smoke-1" })

local bad_faction = host:join(protocol.handshake({
  rules_version = config.rules_version,
  content_version = config.content_version,
  player_name = "Invalid Faction",
  faction = "Neutral",
}))
if bad_faction.ok or bad_faction.reason ~= "unsupported_faction" then
  io.stderr:write("invalid faction should be rejected\n")
  os.exit(1)
end

local bad_deck = host:join(protocol.handshake({
  rules_version = config.rules_version,
  content_version = config.content_version,
  player_name = "Invalid Deck",
  deck = "not-a-deck",
}))
if bad_deck.ok or bad_deck.reason ~= "invalid_deck_payload" then
  io.stderr:write("invalid deck payload should be rejected\n")
  os.exit(1)
end

local join1 = host:join(protocol.handshake({
  rules_version = config.rules_version,
  content_version = config.content_version,
  player_name = "Alice",
}))
assert_ok(join1, "join1")
if join1.meta.player_index ~= 0 then
  io.stderr:write("invalid joins should not reserve slot 0\n")
  os.exit(1)
end

local join2 = host:join(protocol.handshake({
  rules_version = config.rules_version,
  content_version = config.content_version,
  player_name = "Bob",
}))
assert_ok(join2, "join2")

local alice_token = join1.meta and join1.meta.session_token
if type(alice_token) ~= "string" or alice_token == "" then
  io.stderr:write("join1 missing session token\n")
  os.exit(1)
end

local s1 = host:submit(protocol.submit_command("smoke-1", 1, {
  type = "ASSIGN_WORKER",
  resource = "wood",
}, nil, alice_token))
assert_ok(s1, "submit1")

local s2 = host:submit(protocol.submit_command("smoke-1", 2, {
  type = "END_TURN",
}, nil, alice_token))
assert_ok(s2, "submit2")

local blocked_start_turn = host:submit(protocol.submit_command("smoke-1", 3, {
  type = "START_TURN",
}, nil, alice_token))
if blocked_start_turn.ok or blocked_start_turn.reason ~= "command_not_allowed" then
  io.stderr:write("client START_TURN should be rejected\n")
  os.exit(1)
end

local wrong_player_end = host:submit(protocol.submit_command("smoke-1", 3, {
  type = "END_TURN",
}, nil, alice_token))
if wrong_player_end.ok or wrong_player_end.reason ~= "not_active_player" then
  io.stderr:write("non-active END_TURN should be rejected\n")
  os.exit(1)
end

local state = host:get_state_snapshot()
local replay = host:get_replay_snapshot()

if state.turnNumber < 2 then
  io.stderr:write("turn number did not advance\n")
  os.exit(1)
end

if #(replay.entries or {}) < 2 then
  io.stderr:write("replay log missing entries\n")
  os.exit(1)
end

print("Host smoke test passed")
