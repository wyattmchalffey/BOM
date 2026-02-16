-- Smoke test for websocket_provider secure-retry path when ws:// endpoints
-- redirect with HTTP 301 and wss:// then fails due missing ssl runtime.
--
-- Run from repo root:
--   lua love2d/scripts/websocket_provider_secure_retry_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local websocket_provider = require("src.net.websocket_provider")

local function fail(msg)
  io.stderr:write(msg .. "\n")
  os.exit(1)
end

local saved_loaded_websocket = package.loaded.websocket
local saved_preload_websocket = package.preload.websocket

local connect_calls = {}
package.loaded.websocket = nil
package.preload.websocket = function()
  return {
    client = {
      sync = function()
        return {
          connect = function(_self, url)
            connect_calls[#connect_calls + 1] = url
            if url:match("^ws://") then
              return nil, "Websocket Handshake failed: HTTP/1.1 301 Moved Permanently"
            end
            return nil, "C:/Program Files (x86)/Lua/5.1/lua/websocket/sync.lua:133: attempt to index upvalue 'ssl' (a nil value)"
          end,
          send = function() return true end,
          receive = function() return "{}" end,
          close = function() return true end,
        }
      end,
    },
  }
end

local resolved = websocket_provider.resolve()
if not resolved.ok then
  fail("expected websocket provider to resolve")
end

local ok, err = pcall(function()
  resolved.provider.connect("ws://bom-hbfv.onrender.com/host", {})
end)

if ok then
  fail("expected connection to fail with SSL guidance")
end

if not tostring(err):find("secure_websocket_unavailable", 1, true) then
  fail("expected secure_websocket_unavailable error, got: " .. tostring(err))
end

if not tostring(err):find("LuaSec/ssl", 1, true) then
  fail("expected LuaSec/ssl guidance in error, got: " .. tostring(err))
end

if #connect_calls ~= 2 or connect_calls[1] ~= "ws://bom-hbfv.onrender.com/host" or connect_calls[2] ~= "wss://bom-hbfv.onrender.com/host" then
  fail("expected ws then wss connect attempts")
end

package.loaded.websocket = saved_loaded_websocket
package.preload.websocket = saved_preload_websocket

print("Websocket provider secure retry smoke test passed")
