-- Hosted game: combines headless host + websocket server + local in-process adapter.
--
-- hosted_game.start(opts) -> { ok, adapter, step_fn, cleanup_fn, port, reason }
--
-- The host player uses the in-process adapter (HeadlessFrameClient) for zero-latency
-- gameplay. Remote players connect via websocket to the same headless host service.
-- Each love.update() frame, call step_fn() to poll for incoming websocket connections
-- and handle remote player frames.

local headless_host_service = require("src.net.headless_host_service")
local websocket_host_service = require("src.net.websocket_host_service")
local authoritative_client_game = require("src.net.authoritative_client_game")
local client_session = require("src.net.client_session")
local websocket_transport = require("src.net.websocket_transport")
local json = require("src.net.json_codec")
local relay_host_bridge = require("src.net.relay_host_bridge")

local hosted_game = {}

-- In-process frame client (same as runtime_multiplayer.HeadlessFrameClient)
local HeadlessFrameClient = {}
HeadlessFrameClient.__index = HeadlessFrameClient

function HeadlessFrameClient.new(service)
  return setmetatable({ service = service, _last = nil }, HeadlessFrameClient)
end

function HeadlessFrameClient:send(frame)
  self._last = frame
end

function HeadlessFrameClient:receive(_timeout_ms)
  return self.service:handle_frame(self._last)
end

-- Resolve sync websocket server provider (same pattern as scripts/run_websocket_host.lua)
local function resolve_sync_provider()
  local ok_sync, ws_sync = pcall(require, "websocket.server.sync")
  if not ok_sync or not ws_sync or type(ws_sync.listen) ~= "function" then
    return nil, "websocket.server.sync module not found"
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

-- Try to start websocket server with copas backend
local function try_copas_server(service, host, port)
  local ok_server, ws_server = pcall(require, "websocket.server_copas")
  if not ok_server or not ws_server or type(ws_server.listen) ~= "function" then
    return nil, "websocket.server_copas module not found"
  end

  local ok_copas, copas = pcall(require, "copas")
  if not ok_copas or not copas then
    return nil, "copas module not found"
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
      print("[hosted_game] websocket error: " .. tostring(msg))
    end,
  })

  if not server then
    return nil, "copas server listen failed"
  end

  -- Return step function that does non-blocking copas poll
  local function step_fn()
    pcall(copas.step, 0)
  end

  local function cleanup_fn()
    -- copas doesn't expose a clean shutdown, but we stop polling
  end

  return { step_fn = step_fn, cleanup_fn = cleanup_fn, backend = "copas" }, nil
end

-- Try to start websocket server with sync backend
local function try_sync_server(service, host, port)
  local provider, err = resolve_sync_provider()
  if not provider then
    return nil, err
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
    return nil, "sync server start failed: " .. tostring(started.reason)
  end

  -- Return step function that does non-blocking poll
  local function step_fn()
    server:step(0)
  end

  local function cleanup_fn()
    -- Close all connections
    if server.connections then
      for _, c in ipairs(server.connections) do
        if c.close then pcall(c.close, c) end
      end
      server.connections = {}
    end
  end

  return { step_fn = step_fn, cleanup_fn = cleanup_fn, backend = "sync" }, nil
end

function hosted_game.start(opts)
  opts = opts or {}
  local player_name = opts.player_name or "Host"
  local port = tonumber(opts.port) or 12345
  local host = opts.host or "0.0.0.0"
  local relay_url = opts.relay_url  -- nil = LAN mode, string = relay mode

  -- 1. Create headless host service (game logic authority)
  local service = headless_host_service.new({
    match_id = opts.match_id,
    rules_version = opts.rules_version,
    content_version = opts.content_version,
    max_players = opts.max_players,
  })

  local ws_result, ws_err
  local room_code = nil

  if relay_url and relay_url ~= "" then
    -- Relay mode: connect outbound to relay server
    local relay_result = relay_host_bridge.connect({
      relay_url = relay_url,
      service = service,
    })
    if not relay_result.ok then
      return { ok = false, reason = "relay_failed: " .. tostring(relay_result.reason) }
    end
    room_code = relay_result.room_code
    ws_result = {
      step_fn = relay_result.step_fn,
      cleanup_fn = relay_result.cleanup_fn,
      backend = "relay",
    }
    print(string.format("[hosted_game] connected to relay, room code: %s", room_code))
  else
    -- LAN mode: try to start websocket server (sync first, then copas)
    ws_result, ws_err = try_sync_server(service, host, port)
    if not ws_result then
      local sync_err = ws_err
      ws_result, ws_err = try_copas_server(service, host, port)
      if not ws_result then
        print("[hosted_game] no websocket server available:")
        print("  sync: " .. tostring(sync_err))
        print("  copas: " .. tostring(ws_err))
        -- Still allow hosting in local-only mode (no remote players)
      end
    end

    if ws_result then
      print(string.format("[hosted_game] websocket host listening on %s:%d (backend=%s)", host, port, ws_result.backend))
    end
  end

  -- 3. Build in-process adapter for the host player
  local transport = websocket_transport.new({
    client = HeadlessFrameClient.new(service),
    encode = json.encode,
    decode = json.decode,
  })

  local session = client_session.new({
    transport = transport,
    player_name = player_name,
  })

  local adapter = authoritative_client_game.new({ session = session })

  -- 4. Return adapter + server controls
  return {
    ok = true,
    adapter = adapter,
    step_fn = ws_result and ws_result.step_fn or nil,
    cleanup_fn = ws_result and ws_result.cleanup_fn or nil,
    port = port,
    ws_available = ws_result ~= nil,
    backend = ws_result and ws_result.backend or nil,
    room_code = room_code,
  }
end

return hosted_game
