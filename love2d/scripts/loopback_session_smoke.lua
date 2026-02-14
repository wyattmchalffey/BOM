-- Smoke test for client session + loopback transport + host integration.
-- Run from repo root:
--   lua love2d/scripts/loopback_session_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local host_mod = require("src.net.host")
local transport_mod = require("src.net.loopback_transport")
local client_session = require("src.net.client_session")

local function assert_ok(result, label)
  if not result.ok then
    io.stderr:write(label .. " failed: " .. tostring(result.reason) .. "\n")
    os.exit(1)
  end
end

local host = host_mod.new({ match_id = "loopback-1" })
local transport = transport_mod.new(host)

local client_a = client_session.new({ transport = transport, player_name = "Alice" })
local client_b = client_session.new({ transport = transport, player_name = "Bob" })

assert_ok(client_a:connect(), "client_a connect")
assert_ok(client_b:connect(), "client_b connect")

-- Simulate disconnect/reconnect flow using session token.
assert_ok(client_b:disconnect_local(), "client_b local disconnect")
assert_ok(client_b:reconnect(), "client_b reconnect")

assert_ok(client_a:submit({ type = "ASSIGN_WORKER", resource = "wood" }), "client_a assign")
assert_ok(client_a:submit({ type = "END_TURN" }), "client_a end turn")

local blocked = client_a:submit({ type = "ASSIGN_WORKER", resource = "wood" })
if blocked.ok then
  io.stderr:write("expected blocked command after turn pass\n")
  os.exit(1)
end

local snap = client_b:request_snapshot()
assert_ok(snap, "client_b snapshot")

if type(snap.meta.checksum) ~= "string" or snap.meta.checksum == "" then
  io.stderr:write("expected checksum in snapshot\n")
  os.exit(1)
end


-- Force checksum mismatch and ensure resync path is exercised.
client_b.last_checksum = "bad-checksum"
local mismatch = client_b:submit({ type = "END_TURN" })
if mismatch.ok or mismatch.reason ~= "resync_required" then
  io.stderr:write("expected resync_required on checksum mismatch\n")
  os.exit(1)
end

local after_resync = client_b:submit_with_resync({ type = "END_TURN" })
if after_resync.ok or after_resync.reason ~= "resynced_retry_required" then
  io.stderr:write("expected resynced_retry_required after auto snapshot\n")
  os.exit(1)
end

-- Retry after resync should now pass.
assert_ok(client_b:submit({ type = "END_TURN" }), "client_b retry after resync")

print("Loopback session smoke test passed")
