-- Smoke test for websocket_provider raw ws fallback path.
-- Run from repo root:
--   lua love2d/scripts/websocket_provider_raw_fallback_smoke.lua

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
local saved_loaded_raw = package.loaded["src.net.raw_ws_client"]
local saved_preload_raw = package.preload["src.net.raw_ws_client"]

package.loaded.websocket = nil
package.preload.websocket = function()
  return {
    client = {
      sync = function()
        return {
          connect = function(_self, _url)
            return nil, "Websocket Handshake failed: Invalid Sec-Websocket-Accept (expected X= got nil)"
          end,
        }
      end,
    },
  }
end

package.loaded["src.net.raw_ws_client"] = nil
package.preload["src.net.raw_ws_client"] = function()
  return {
    connect = function(url, _opts)
      if url ~= "ws://localhost:8080/host" then
        return nil, "unexpected_url"
      end
      return {
        send = function(_self, _message) return true end,
        receive = function(_self, _timeout_ms) return "{}" end,
      }
    end,
  }
end

local resolved = websocket_provider.resolve()
if not resolved.ok then
  fail("expected websocket provider to resolve")
end

local conn = resolved.provider.connect("ws://localhost:8080/host", {})
if not conn or type(conn.send) ~= "function" or type(conn.receive) ~= "function" then
  fail("expected normalized raw fallback connection")
end

package.loaded.websocket = saved_loaded_websocket
package.preload.websocket = saved_preload_websocket
package.loaded["src.net.raw_ws_client"] = saved_loaded_raw
package.preload["src.net.raw_ws_client"] = saved_preload_raw

print("Websocket provider raw fallback smoke test passed")
