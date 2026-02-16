-- Smoke test for websocket_transport skipping relay control frames.
-- Run from repo root:
--   lua love2d/scripts/websocket_transport_relay_control_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local websocket_transport = require("src.net.websocket_transport")
local json = require("src.net.json_codec")

local function fail(msg)
  io.stderr:write(msg .. "\n")
  os.exit(1)
end

local sent = {}
local frames = {
  json.encode({ type = "joined", room = "ABC123" }),
  json.encode({ ok = true, message = { kind = "connected", player_index = 2 } }),
}

local client = {
  send = function(_self, frame)
    sent[#sent + 1] = frame
    return true
  end,
  receive = function(_self, _timeout_ms)
    if #frames == 0 then
      return nil
    end
    local next_frame = frames[1]
    table.remove(frames, 1)
    return next_frame
  end,
}

local transport = websocket_transport.new({
  client = client,
  encode = json.encode,
  decode = json.decode,
  timeout_ms = 100,
})

local out = transport:connect({ player_name = "Tester" })
if type(out) ~= "table" or out.kind ~= "connected" then
  fail("expected protocol connected message after skipping relay control frame")
end

if #sent ~= 1 then
  fail("expected exactly one request frame sent")
end

print("Websocket transport relay control smoke test passed")
