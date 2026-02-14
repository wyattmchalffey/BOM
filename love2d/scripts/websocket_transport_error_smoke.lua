-- Smoke test for websocket transport error normalization.
-- Run from repo root:
--   lua love2d/scripts/websocket_transport_error_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local websocket_transport = require("src.net.websocket_transport")

local function assert_reason(msg, reason, label)
  if type(msg) ~= "table" or msg.type ~= "error" or msg.reason ~= reason then
    io.stderr:write(label .. " expected error reason " .. reason .. "\n")
    os.exit(1)
  end
end

-- Missing client.
local t_missing = websocket_transport.new({})
assert_reason(t_missing:connect({ match_id = "m1" }), "missing_transport_client", "missing client")

-- Encode fails.
local t_encode = websocket_transport.new({
  client = { send = function() end, receive = function() return {} end },
  encode = function() error("encode boom") end,
})
assert_reason(t_encode:connect({ match_id = "m2" }), "transport_encode_failed", "encode failure")

-- Send fails.
local t_send = websocket_transport.new({
  client = {
    send = function() error("send boom") end,
    receive = function() return {} end,
  },
})
assert_reason(t_send:connect({ match_id = "m3" }), "transport_send_failed", "send failure")

-- Receive fails.
local t_receive = websocket_transport.new({
  client = {
    send = function() end,
    receive = function() error("receive boom") end,
  },
})
assert_reason(t_receive:connect({ match_id = "m4" }), "transport_receive_failed", "receive failure")

-- Decode fails.
local t_decode = websocket_transport.new({
  client = {
    send = function() end,
    receive = function() return "bad" end,
  },
  decode = function() error("decode boom") end,
})
assert_reason(t_decode:connect({ match_id = "m5" }), "transport_decode_failed", "decode failure")

print("Websocket transport error smoke test passed")
