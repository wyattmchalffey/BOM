-- Smoke test for runtime multiplayer wiring helpers.
-- Run from repo root:
--   lua love2d/scripts/runtime_multiplayer_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local runtime_multiplayer = require("src.net.runtime_multiplayer")

local function assert_ok(result, label)
  if not result.ok then
    io.stderr:write(label .. " failed: " .. tostring(result.reason) .. "\n")
    os.exit(1)
  end
end

local built = runtime_multiplayer.build({
  mode = "headless",
  player_name = "Smoke",
  match_id = "runtime-smoke",
})
assert_ok(built, "build")

local adapter = built.adapter
assert_ok(adapter:connect(), "connect")

assert_ok(adapter:submit({ type = "ASSIGN_WORKER", resource = "wood" }), "assign worker")

local state = adapter:get_state()
if not state or not state.players or not state.players[1] then
  io.stderr:write("expected adapter state snapshot after submit\n")
  os.exit(1)
end

print("Runtime multiplayer smoke test passed")
