-- Concrete websocket client wrapper used by websocket_transport.
--
-- Expects an injected provider implementing:
--   provider.connect(url, opts) -> connection
--
-- Connection is expected to provide either:
--   send(message) / receive(timeout_ms)
-- or
--   send_text(message) / receive_text(timeout_ms)

local client = {}
client.__index = client

local function call_send(conn, message)
  if conn.send then return conn:send(message) end
  if conn.send_text then return conn:send_text(message) end
  error("missing_send_method")
end

local function call_receive(conn, timeout_ms)
  if conn.receive then return conn:receive(timeout_ms) end
  if conn.receive_text then return conn:receive_text(timeout_ms) end
  error("missing_receive_method")
end

function client.new(opts)
  opts = opts or {}
  assert(opts.provider, "websocket_client requires provider")
  assert(type(opts.url) == "string" and opts.url ~= "", "websocket_client requires url")

  local conn = opts.provider.connect(opts.url, opts.connect_opts or {})
  assert(conn, "websocket provider failed to connect")

  return setmetatable({
    connection = conn,
  }, client)
end

function client:send(frame)
  return call_send(self.connection, frame)
end

function client:receive(timeout_ms)
  return call_receive(self.connection, timeout_ms)
end

return client
