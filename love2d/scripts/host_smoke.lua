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

local join1 = host:join(protocol.handshake({
  rules_version = config.rules_version,
  content_version = config.content_version,
  player_name = "Alice",
}))
assert_ok(join1, "join1")

local join2 = host:join(protocol.handshake({
  rules_version = config.rules_version,
  content_version = config.content_version,
  player_name = "Bob",
}))
assert_ok(join2, "join2")

local s1 = host:submit(0, protocol.submit_command("smoke-1", 1, {
  type = "ASSIGN_WORKER",
  resource = "wood",
}))
assert_ok(s1, "submit1")

local s2 = host:submit(0, protocol.submit_command("smoke-1", 2, {
  type = "END_TURN",
}))
assert_ok(s2, "submit2")

local bad_seq = host:submit(0, protocol.submit_command("smoke-1", 2, {
  type = "START_TURN",
}))
if bad_seq.ok then
  io.stderr:write("bad_seq should have failed\n")
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
