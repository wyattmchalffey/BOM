-- Websocket provider resolution/normalization for runtime multiplayer builds.
--
-- The returned provider implements:
--   provider.connect(url, opts) -> connection
-- where connection supports one of:
--   send/receive
--   send_text/receive_text

local websocket_provider = {}

local function normalize_connection(conn)
  if type(conn) ~= "table" then
    return nil, "invalid_connection"
  end

  if conn.send and conn.receive then
    return conn
  end

  if conn.send_text and conn.receive_text then
    return {
      send = function(_, message) return conn:send_text(message) end,
      receive = function(_, timeout_ms) return conn:receive_text(timeout_ms) end,
    }
  end

  return nil, "unsupported_connection_contract"
end

local function from_websocket_module(websocket)
  if not websocket or not websocket.client or not websocket.client.sync then
    return nil, "unsupported_websocket_module"
  end

  return {
    connect = function(url, _opts)
      local conn = websocket.client.sync()
      local ok_connect, err = conn:connect(url)
      if not ok_connect then
        error(err or "websocket_connect_failed")
      end

      local normalized, normalize_err = normalize_connection({
        send_text = function(_, message) return conn:send(message) end,
        receive_text = function(_, _timeout_ms) return conn:receive() end,
      })
      if not normalized then
        error(normalize_err)
      end

      return normalized
    end,
  }
end

local function from_prebuilt_provider(provider)
  if type(provider) ~= "table" or type(provider.connect) ~= "function" then
    return nil, "invalid_provider"
  end

  return {
    connect = function(url, opts)
      local conn = provider.connect(url, opts)
      local normalized, normalize_err = normalize_connection(conn)
      if not normalized then
        error(normalize_err)
      end
      return normalized
    end,
  }
end

function websocket_provider.resolve(opts)
  opts = opts or {}

  if opts.provider then
    local provider, err = from_prebuilt_provider(opts.provider)
    if not provider then
      return { ok = false, reason = err }
    end
    return { ok = true, provider = provider, source = "injected" }
  end

  local ok_websocket, websocket = pcall(require, "websocket")
  if ok_websocket then
    local provider, err = from_websocket_module(websocket)
    if provider then
      return { ok = true, provider = provider, source = "module:websocket" }
    end
    return { ok = false, reason = err }
  end

  return { ok = false, reason = "websocket_module_not_found" }
end

return websocket_provider
