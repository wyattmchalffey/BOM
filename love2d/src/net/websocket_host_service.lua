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

local function fail(reason, meta)
  return { ok = false, reason = reason, meta = meta or {} }
end

local function ok(meta)
  return { ok = true, reason = "ok", meta = meta or {} }
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
        -- Send any queued state pushes to all OTHER connections
        if self.push_source then
          local pushes = self.push_source:pop_pushes()
          for _, push in ipairs(pushes) do
            for j, other in ipairs(self.connections) do
              if j ~= i then
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

  -- Flush any pending state pushes (e.g. from host's own moves) to ALL connections
  if self.push_source and #self.connections > 0 then
    local pushes = self.push_source:pop_pushes()
    for _, push in ipairs(pushes) do
      for _, c in ipairs(self.connections) do
        pcall(c.send_text, c, push)
      end
    end
  end

  return ok({ handled = handled, idle = not handled })
end

return host_service
