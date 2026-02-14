-- Smoke test for websocket_host_service provider contract.
-- Run from repo root:
--   lua love2d/scripts/websocket_host_service_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local websocket_host_service = require("src.net.websocket_host_service")

local function assert_ok(result, label)
  if not result.ok then
    io.stderr:write(label .. " failed: " .. tostring(result.reason) .. "\n")
    os.exit(1)
  end
end

local responses = {}

local FakeConnection = {}
FakeConnection.__index = FakeConnection
function FakeConnection.new(frame)
  return setmetatable({ frame = frame, closed = false }, FakeConnection)
end
function FakeConnection:receive_text(_timeout_ms)
  return self.frame
end
function FakeConnection:send_text(frame)
  responses[#responses + 1] = frame
  return true
end
function FakeConnection:close()
  self.closed = true
end

local FakeListener = {}
FakeListener.__index = FakeListener
function FakeListener.new(frame)
  return setmetatable({ frame = frame, served = false }, FakeListener)
end
function FakeListener:accept(_timeout_ms)
  if self.served then return nil end
  self.served = true
  return FakeConnection.new(self.frame)
end

local provider = {
  listen = function(_opts)
    return FakeListener.new('{"hello":"world"}')
  end,
}

local service = websocket_host_service.new({
  server_provider = provider,
  frame_handler = function(frame)
    return string.upper(frame)
  end,
})

assert_ok(service:start(), "start")
assert_ok(service:step(5), "step handled")
assert_ok(service:step(5), "step idle")

if responses[1] ~= '{"HELLO":"WORLD"}' then
  io.stderr:write("unexpected websocket host response frame\n")
  os.exit(1)
end

print("Websocket host service smoke test passed")
