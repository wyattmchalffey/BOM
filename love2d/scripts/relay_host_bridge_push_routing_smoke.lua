-- Smoke test for relay_host_bridge push routing.
-- Ensures only pushes for the joiner are forwarded over the relay route.
-- Run from repo root:
--   lua love2d/scripts/relay_host_bridge_push_routing_smoke.lua

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

local sent_frames = {}
local receive_queue = {
  '{"type":"room_created","room":"ABC123"}',
  '{"op":"connect","payload":{"protocol_version":1}}',
}

local fake_conn = {
  receive = function(_self, _timeout_ms)
    if #receive_queue == 0 then
      return nil
    end
    local frame = receive_queue[1]
    table.remove(receive_queue, 1)
    return frame
  end,
  send = function(_self, frame)
    sent_frames[#sent_frames + 1] = frame
    return true
  end,
}

local provider = {
  connect = function(_url, _opts)
    return fake_conn
  end,
}

local pending_pushes = {
  [1] = { '{"type":"state_push","payload":{"tag":"joiner"}}' },
  [0] = { '{"type":"state_push","payload":{"tag":"host"}}' },
}
local pop_calls = {}

local service = {
  handle_frame = function(_self, _frame)
    return '{"ok":true,"message":{"type":"command_ack","payload":{"player_index":1}}}'
  end,
  pop_pushes = function(_self, player_index)
    pop_calls[#pop_calls + 1] = (player_index == nil) and "__nil__" or tostring(player_index)
    if player_index == nil then
      local out = {}
      for _, pushes in pairs(pending_pushes) do
        for _, frame in ipairs(pushes) do
          out[#out + 1] = frame
        end
      end
      pending_pushes = {}
      return out
    end

    local out = pending_pushes[player_index] or {}
    pending_pushes[player_index] = nil
    return out
  end,
}

local result = relay_host_bridge.connect({
  relay_url = "ws://localhost:8080",
  provider = provider,
  service = service,
})

if not result.ok then
  fail("expected successful relay host bridge connection")
end

result.step_fn()

if #sent_frames < 2 then
  fail("expected response frame and one routed push")
end

if not sent_frames[1]:find('"player_index":1', 1, true) then
  fail("expected connect ack with joiner player_index")
end

if sent_frames[2] ~= '{"type":"state_push","payload":{"tag":"joiner"}}' then
  fail("expected joiner-targeted push to be forwarded")
end

for _, frame in ipairs(sent_frames) do
  if frame == '{"type":"state_push","payload":{"tag":"host"}}' then
    fail("host-targeted push should not be forwarded to joiner")
  end
end

if #pop_calls < 2 or pop_calls[1] ~= "1" or pop_calls[2] ~= "__nil__" then
  fail("expected targeted pop_pushes call followed by drain call")
end

print("Relay host bridge push routing smoke test passed")
