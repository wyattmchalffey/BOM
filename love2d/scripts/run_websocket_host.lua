-- Run authoritative host service over websocket frames.
--
-- Usage:
--   BOM_HOST=0.0.0.0 BOM_PORT=8080 lua love2d/scripts/run_websocket_host.lua
--
-- Supported websocket host backends:
--   1) `websocket.server.sync` (preferred, step/poll style)
--   2) `websocket.server_copas` + `copas` (lua-websockets fallback)

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

local function resolve_sync_provider()
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

local function run_sync_host(service, host, port)
  local provider, provider_err = resolve_sync_provider()
  if not provider then
    return { ok = false, reason = provider_err }
  end

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
    return { ok = false, reason = started.reason }
  end

  print(string.format("websocket host listening on %s:%d (backend=websocket.server.sync)", host, port))

  local connection_count = 0
  while true do
    local prev_count = connection_count
    local step = server:step(100)
    if server.connections then
      connection_count = #server.connections
    end
    if connection_count ~= prev_count then
      print(string.format("[host] active connections: %d", connection_count))
    end
    if step.meta and step.meta.handled then
      print("[host] frame handled")
    end
    if not step.ok then
      io.stderr:write("host service step error: " .. tostring(step.reason) .. "\n")
    end
  end
end

local function run_copas_host(service, host, port)
  local ok_server, ws_server = pcall(require, "websocket.server_copas")
  if not ok_server or not ws_server or type(ws_server.listen) ~= "function" then
    return { ok = false, reason = "websocket_server_copas_module_not_found" }
  end

  local ok_copas, copas = pcall(require, "copas")
  if not ok_copas or not copas then
    return { ok = false, reason = "copas_module_not_found" }
  end

  local _, ws_frame = pcall(require, "websocket.frame")

  local server = ws_server.listen({
    interface = host,
    port = port,
    default = function(client)
      while true do
        local data, opcode = client:receive()
        if not data then
          break
        end

        if ws_frame and opcode == ws_frame.TEXT then
          local response = service:handle_frame(data)
          if response then
            client:send(response)
          end
        end
      end
    end,
    on_error = function(msg)
      io.stderr:write("websocket host error: " .. tostring(msg) .. "\n")
    end,
  })

  if not server then
    return { ok = false, reason = "server_listen_failed" }
  end

  print(string.format("websocket host listening on %s:%d (backend=websocket.server_copas)", host, port))
  copas.loop()

  return { ok = true }
end

local host = getenv("BOM_HOST", "0.0.0.0")
local port = tonumber(getenv("BOM_PORT", "8080")) or 8080

local service = headless_host_service.new({
  match_id = getenv("BOM_MATCH_ID", "headless-match"),
})

local sync_result = run_sync_host(service, host, port)
if sync_result and sync_result.ok then
  os.exit(0)
end

local copas_result = run_copas_host(service, host, port)
if copas_result and copas_result.ok then
  os.exit(0)
end

local sync_reason = sync_result and sync_result.reason or "sync_backend_failed"
local copas_reason = copas_result and copas_result.reason or "copas_backend_failed"

if sync_reason == "websocket_server_module_not_found"
  and (copas_reason == "websocket_server_copas_module_not_found" or copas_reason == "copas_module_not_found") then
  io.stderr:write("failed to start websocket host: websocket_server_module_not_found\n")
  os.exit(1)
end

io.stderr:write("failed to start websocket host: " .. tostring(sync_reason) .. "; " .. tostring(copas_reason) .. "\n")
os.exit(1)
