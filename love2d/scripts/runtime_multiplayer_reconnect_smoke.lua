-- Smoke test for runtime multiplayer reconnect flow.
-- Run from repo root:
--   lua love2d/scripts/runtime_multiplayer_reconnect_smoke.lua

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
  player_name = "ReconnectSmoke",
  match_id = "runtime-reconnect-smoke",
})
assert_ok(built, "build")

local adapter = built.adapter
assert_ok(adapter:connect(), "connect")
assert_ok(adapter:submit({ type = "ASSIGN_WORKER", resource = "wood" }), "submit before reconnect")

adapter.session:disconnect_local()
assert_ok(adapter:reconnect(), "reconnect")
assert_ok(adapter:submit({ type = "END_TURN" }), "submit after reconnect")

print("Runtime multiplayer reconnect smoke test passed")
