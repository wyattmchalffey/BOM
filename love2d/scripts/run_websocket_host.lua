-- Run authoritative host service over websocket frames.
--
-- Usage:
--   BOM_HOST=0.0.0.0 BOM_PORT=8080 lua love2d/scripts/run_websocket_host.lua
--
-- Requires a Lua websocket server module. This script currently supports
-- `websocket.server.sync` style providers.

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local headless_host_service = require("src.net.headless_host_service")
local websocket_host_service = require("src.net.websocket_host_service")

local function getenv(name, default)
  local value = os.getenv(name)
  if value == nil or value == "" then return default end
  return value
end

local function resolve_server_provider()
  local ok_sync, ws_sync = pcall(require, "websocket.server.sync")
  if not ok_sync or not ws_sync or type(ws_sync.listen) ~= "function" then
    return nil, "websocket_server_module_not_found"
  end

  return {
    listen = function(opts)
      local server = ws_sync.listen(opts.host, opts.port)
      if not server then return nil end

      return {
        accept = function(_, timeout_ms)
          if server.settimeout then
            server:settimeout((timeout_ms or 0) / 1000)
          end
          local conn = server:accept()
          if not conn then return nil end

          return {
            receive_text = function(_, _timeout)
              if conn.settimeout then
                conn:settimeout((_timeout or 0) / 1000)
              end
              if conn.receive then return conn:receive() end
              return nil
            end,
            send_text = function(_, frame)
              if conn.send then return conn:send(frame) end
              return false
            end,
            close = function()
              if conn.close then conn:close() end
            end,
          }
        end,
      }
    end,
  }, nil
end

local host = getenv("BOM_HOST", "0.0.0.0")
local port = tonumber(getenv("BOM_PORT", "8080")) or 8080

local provider, provider_err = resolve_server_provider()
if not provider then
  io.stderr:write("failed to start websocket host: " .. tostring(provider_err) .. "\n")
  os.exit(1)
end

local service = headless_host_service.new({
  match_id = getenv("BOM_MATCH_ID", "headless-match"),
})

local server = websocket_host_service.new({
  frame_handler = function(frame)
    return service:handle_frame(frame)
  end,
  server_provider = provider,
  host = host,
  port = port,
})

local started = server:start()
if not started.ok then
  io.stderr:write("failed to start websocket host: " .. tostring(started.reason) .. "\n")
  os.exit(1)
end

print(string.format("websocket host listening on %s:%d", host, port))

while true do
  local step = server:step(100)
  if not step.ok and step.reason ~= "connection_receive_failed" then
    io.stderr:write("host service step error: " .. tostring(step.reason) .. "\n")
  end
end
