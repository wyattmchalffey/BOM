-- Smoke test for websocket_transport + json_codec + websocket_client wrapper.
-- Run from repo root:
--   lua love2d/scripts/websocket_json_client_smoke.lua

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
local websocket_client = require("src.net.websocket_client")
local json = require("src.net.json_codec")
local client_session = require("src.net.client_session")

local function assert_ok(result, label)
  if not result.ok then
    io.stderr:write(label .. " failed: " .. tostring(result.reason) .. "\n")
    os.exit(1)
  end
end

-- Fake provider that behaves like a websocket lib provider.
local FakeProvider = {}

function FakeProvider.connect(_url, opts)
  local gateway = opts.gateway
  return {
    send_text = function(_, text)
      opts.last_sent = text
    end,
    receive_text = function(_, _timeout_ms)
      local request = json.decode(opts.last_sent)
      local response = gateway:handle(request)
      return json.encode(response)
    end,
  }
end

local host = host_mod.new({ match_id = "ws-json-smoke" })
local gateway = host_gateway.new(host)

local function make_session(name)
  local provider_opts = { gateway = gateway, last_sent = nil }
  local socket = websocket_client.new({
    provider = FakeProvider,
    url = "ws://local/fake",
    connect_opts = provider_opts,
  })
  local transport = websocket_transport.new({
    client = socket,
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
  io.stderr:write("expected resynced_retry_required in websocket json flow\n")
  os.exit(1)
end

assert_ok(client_b:submit({ type = "END_TURN" }), "client_b retry after resync")

print("Websocket JSON client smoke test passed")
