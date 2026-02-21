-- Websocket host service runner for authoritative host frames.
--
-- Expects:
--   frame_handler(frame_text) -> response_frame_text
--   server_provider.listen(opts) -> listener
--   listener:accept(timeout_ms) -> conn|nil
--   conn:receive_text(timeout_ms) -> frame|nil
--   conn:send_text(frame)
--   conn:close() (optional)

local host_service = {}
host_service.__index = host_service

local ok_json, json_codec = pcall(require, "src.net.json_codec")
if not ok_json then
  json_codec = nil
end

local function fail(reason, meta)
  return { ok = false, reason = reason, meta = meta or {} }
end

local function ok(meta)
  return { ok = true, reason = "ok", meta = meta or {} }
end

local function extract_player_index_from_response(response_frame)
  if not json_codec or type(response_frame) ~= "string" then
    return nil
  end

  local ok_decode, decoded = pcall(json_codec.decode, response_frame)
  if not ok_decode or type(decoded) ~= "table" or not decoded.ok then
    return nil
  end

  local message = decoded.message
  if type(message) ~= "table" or message.type ~= "command_ack" then
    return nil
  end

  local payload = message.payload
  if type(payload) ~= "table" then
    return nil
  end

  local player_index = payload.player_index
  if type(player_index) ~= "number" then
    return nil
  end

  return player_index
end

function host_service.new(opts)
  opts = opts or {}
  return setmetatable({
    frame_handler = opts.frame_handler,
    provider = opts.server_provider,
    push_source = opts.push_source,
    host = opts.host or "0.0.0.0",
    port = opts.port or 8080,
    connections = {},
  }, host_service)
end

function host_service:start()
  if type(self.frame_handler) ~= "function" then
    return fail("missing_frame_handler")
  end
  if not self.provider or type(self.provider.listen) ~= "function" then
    return fail("missing_server_provider")
  end

  local listener = self.provider.listen({ host = self.host, port = self.port })
  if not listener then
    return fail("listen_failed")
  end

  self.listener = listener
  return ok({ host = self.host, port = self.port })
end

function host_service:step(timeout_ms)
  if not self.listener then
    return fail("service_not_started")
  end

  -- Use short accept timeout when we already have connections to poll,
  -- otherwise block for the full timeout waiting for the first connection.
  local accept_timeout = (#self.connections > 0) and 0 or timeout_ms
  local conn = self.listener:accept(accept_timeout)
  if conn then
    table.insert(self.connections, conn)
  end

  -- Poll existing connections for incoming frames
  local handled = false
  local i = 1
  while i <= #self.connections do
    local c = self.connections[i]
    local recv_ok, frame = pcall(c.receive_text, c, 0)

    if not recv_ok then
      -- Connection errored — remove it
      if c.close then pcall(c.close, c) end
      table.remove(self.connections, i)
    elseif frame then
      local response = self.frame_handler(frame)
      local send_ok, _ = pcall(c.send_text, c, response)
      if not send_ok then
        if c.close then pcall(c.close, c) end
        table.remove(self.connections, i)
      else
        local assigned_player_index = extract_player_index_from_response(response)
        if assigned_player_index ~= nil then
          c.player_index = assigned_player_index
        end

        -- Send any queued state pushes to all OTHER authenticated connections.
        if self.push_source then
          for j, other in ipairs(self.connections) do
            if j ~= i and type(other.player_index) == "number" then
              local pushes = self.push_source:pop_pushes(other.player_index)
              for _, push in ipairs(pushes) do
                pcall(other.send_text, other, push)
              end
            end
          end
        end
        handled = true
        i = i + 1
      end
    else
      -- No data yet, keep connection alive
      i = i + 1
    end
  end

  -- Flush any pending state pushes (e.g. from host's own moves) to authenticated
  -- connections by player identity.
  if self.push_source and #self.connections > 0 then
    for _, c in ipairs(self.connections) do
      if type(c.player_index) == "number" then
        local pushes = self.push_source:pop_pushes(c.player_index)
        for _, push in ipairs(pushes) do
          pcall(c.send_text, c, push)
        end
      end
    end
  end

  return ok({ handled = handled, idle = not handled })
end

return host_service
