-- Smoke test for websocket-ready transport adapter + host gateway.
-- Run from repo root:
--   lua love2d/scripts/websocket_transport_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local host_mod = require("src.net.host")
local host_gateway = require("src.net.host_gateway")
local websocket_transport = require("src.net.websocket_transport")
local client_session = require("src.net.client_session")

local function assert_ok(result, label)
  if not result.ok then
    io.stderr:write(label .. " failed: " .. tostring(result.reason) .. "\n")
    os.exit(1)
  end
end

-- In-memory websocket-like client using identity codec and request/response turns.
local FakeSocketClient = {}
FakeSocketClient.__index = FakeSocketClient

function FakeSocketClient.new(gateway)
  return setmetatable({
    gateway = gateway,
    last_request = nil,
  }, FakeSocketClient)
end

function FakeSocketClient:send(frame)
  self.last_request = frame
end

function FakeSocketClient:receive(_timeout_ms)
  return self.gateway:handle(self.last_request)
end

local host = host_mod.new({ match_id = "ws-smoke" })
local gateway = host_gateway.new(host)

local function make_session(name)
  local socket = FakeSocketClient.new(gateway)
  local transport = websocket_transport.new({ client = socket })
  return client_session.new({ transport = transport, player_name = name })
end

local client_a = make_session("Alice")
local client_b = make_session("Bob")

assert_ok(client_a:connect(), "client_a connect")
assert_ok(client_b:connect(), "client_b connect")
assert_ok(client_a:submit({ type = "ASSIGN_WORKER", resource = "wood" }), "client_a assign")
assert_ok(client_a:submit({ type = "END_TURN" }), "client_a end turn")

client_b.last_checksum = "bad-checksum"
local resync = client_b:submit_with_resync({ type = "END_TURN" })
if resync.ok or resync.reason ~= "resynced_retry_required" then
  io.stderr:write("expected resynced_retry_required in websocket transport flow\n")
  os.exit(1)
end

assert_ok(client_b:submit({ type = "END_TURN" }), "client_b retry after resync")

print("Websocket transport smoke test passed")
