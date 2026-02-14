-- Smoke test for websocket provider resolution/normalization.
-- Run from repo root:
--   lua love2d/scripts/websocket_provider_smoke.lua

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

local injected = websocket_provider.resolve({
  provider = {
    connect = function(_url, _opts)
      return {
        send_text = function(_self, _message) return true end,
        receive_text = function(_self, _timeout_ms) return "ok" end,
      }
    end,
  },
})
if not injected.ok then
  fail("expected injected provider resolution")
end

local conn = injected.provider.connect("ws://local", {})
if not conn.send or not conn.receive then
  fail("expected normalized send/receive methods")
end

local saved_loaded = package.loaded.websocket
local saved_preload = package.preload.websocket

package.loaded.websocket = nil
package.preload.websocket = function()
  return {
    client = {
      sync = function()
        return {
          connect = function(_self, _url) return true end,
          send = function(_self, _msg) return true end,
          receive = function(_self) return "{}" end,
        }
      end,
    },
  }
end

local resolved = websocket_provider.resolve()
if not resolved.ok then
  fail("expected module websocket resolution")
end

-- restore package state
package.loaded.websocket = saved_loaded
package.preload.websocket = saved_preload

print("Websocket provider smoke test passed")
