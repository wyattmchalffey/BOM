-- Smoke test for relay_host_bridge local TLS fallback behavior.
-- Run from repo root:
--   lua love2d/scripts/relay_host_bridge_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local relay_host_bridge = require("src.net.relay_host_bridge")

local function fail(msg)
  io.stderr:write(msg .. "\n")
  os.exit(1)
end

local connect_calls = {}
local fake_conn = {
  receive = function(_self, _timeout_ms)
    return '{"type":"room_created","room":"ABC123"}'
  end,
  send = function(_self, _frame)
    return true
  end,
}

local provider = {
  connect = function(url, _opts)
    connect_calls[#connect_calls + 1] = url
    if url:match("^wss://") then
      error("Websocket Handshake failed: Invalid Sec-Websocket-Accept (expected X= got nil)")
    end
    return fake_conn
  end,
}

local result = relay_host_bridge.connect({
  relay_url = "wss://localhost:8080",
  provider = provider,
  service = {
    handle_frame = function(_self, _frame)
      return nil
    end,
  },
})

if not result.ok then
  fail("expected successful fallback connection")
end

if connect_calls[1] ~= "wss://localhost:8080/host" then
  fail("unexpected initial relay url: " .. tostring(connect_calls[1]))
end
if connect_calls[2] ~= "ws://localhost:8080/host" then
  fail("expected ws fallback relay url, got: " .. tostring(connect_calls[2]))
end

print("Relay host bridge smoke test passed")
