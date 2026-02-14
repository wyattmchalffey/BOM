-- Smoke test for headless host service boundary + websocket transport/client session.
-- Run from repo root:
--   lua love2d/scripts/headless_host_service_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local service_mod = require("src.net.headless_host_service")
local websocket_transport = require("src.net.websocket_transport")
local client_session = require("src.net.client_session")
local json = require("src.net.json_codec")

local function assert_ok(result, label)
  if not result.ok then
    io.stderr:write(label .. " failed: " .. tostring(result.reason) .. "\n")
    os.exit(1)
  end
end

local FrameClient = {}
FrameClient.__index = FrameClient

function FrameClient.new(service)
  return setmetatable({ service = service, last = nil }, FrameClient)
end

function FrameClient:send(frame)
  self.last = frame
end

function FrameClient:receive(_timeout_ms)
  return self.service:handle_frame(self.last)
end

local service = service_mod.new({ match_id = "headless-smoke" })

local function make_session(name)
  local transport = websocket_transport.new({
    client = FrameClient.new(service),
    encode = json.encode,
    decode = json.decode,
  })
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
  io.stderr:write("expected resynced_retry_required in headless service flow\n")
  os.exit(1)
end

assert_ok(client_b:submit({ type = "END_TURN" }), "client_b retry after resync")

print("Headless host service smoke test passed")
