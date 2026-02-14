-- Smoke test for authoritative_client_game adapter.
-- Run from repo root:
--   lua love2d/scripts/authoritative_client_game_smoke.lua

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
local authoritative_game = require("src.net.authoritative_client_game")
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

local service = service_mod.new({ match_id = "authoritative-client-smoke" })

local function make_adapter(name)
  local transport = websocket_transport.new({
    client = FrameClient.new(service),
    encode = json.encode,
    decode = json.decode,
  })
  local session = client_session.new({ transport = transport, player_name = name })
  return authoritative_game.new({ session = session })
end

local client_a = make_adapter("Alice")
local client_b = make_adapter("Bob")

assert_ok(client_a:connect(), "client_a connect")
assert_ok(client_b:connect(), "client_b connect")

local state_a = client_a:get_state()
if not state_a or state_a.activePlayer ~= 0 then
  io.stderr:write("expected initial active player 0 for client_a\n")
  os.exit(1)
end

assert_ok(client_a:submit({ type = "ASSIGN_WORKER", resource = "wood" }), "client_a assign")
assert_ok(client_a:submit({ type = "END_TURN" }), "client_a end turn")

assert_ok(client_b:sync_snapshot(), "client_b sync after opponent move")
local state_b = client_b:get_state()

if not state_b or state_b.activePlayer ~= 1 then
  io.stderr:write("expected active player 1 after client_a end turn\n")
  os.exit(1)
end

-- trigger resync-required path
client_b.session.last_checksum = "bad-checksum"
local resync = client_b:submit({ type = "END_TURN" })
if resync.ok or resync.reason ~= "resynced_retry_required" then
  io.stderr:write("expected resynced_retry_required in authoritative adapter\n")
  os.exit(1)
end

assert_ok(client_b:submit({ type = "END_TURN" }), "client_b retry after resync")

print("Authoritative client game smoke test passed")
