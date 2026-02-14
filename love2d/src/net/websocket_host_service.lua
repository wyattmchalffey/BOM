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
    host = opts.host or "0.0.0.0",
    port = opts.port or 8080,
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

  local conn = self.listener:accept(timeout_ms)
  if not conn then
    return ok({ idle = true })
  end

  local frame = conn:receive_text(timeout_ms)
  if not frame then
    if conn.close then conn:close() end
    return fail("connection_receive_failed")
  end

  local response = self.frame_handler(frame)
  local send_ok = conn:send_text(response)
  if send_ok == false then
    if conn.close then conn:close() end
    return fail("connection_send_failed")
  end

  if conn.close then conn:close() end
  return ok({ handled = true })
end

return host_service
