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
      close = conn.close and function(_)
        return conn:close()
      end or nil,
    }
  end

  return nil, "unsupported_connection_contract"
end

local function is_local_host(url)
  local host = type(url) == "string" and url:match("^wss?://([^/:]+)") or nil
  if not host then
    return false
  end

  host = host:lower()
  return host == "localhost" or host == "127.0.0.1" or host == "::1" or host == "[::1]"
end

local function should_try_raw_ws(url, err)
  if type(url) ~= "string" or not url:match("^ws://") then
    return false
  end

  local message = tostring(err or "")
  if message:find("Invalid Sec%-Websocket%-Accept", 1, false) then
    return true
  end
  if message:find("Websocket Handshake failed", 1, true) then
    return true
  end
  return false
end

local function should_retry_secure(url, err)
  if type(url) ~= "string" or not url:match("^ws://") then
    return false
  end

  if is_local_host(url) then
    return false
  end

  local message = tostring(err or "")
  if message:find("HTTP/1%.1 301", 1, false) then
    return true
  end
  if message:find("Moved Permanently", 1, true) then
    return true
  end

  return false
end

local function looks_like_ssl_runtime_error(err)
  local message = tostring(err or "")
  if message:find("attempt to index upvalue 'ssl'", 1, true) then
    return true
  end
  if message:find("module 'ssl' not found", 1, true) then
    return true
  end
  return false
end

local function try_raw_ws_fallback(url, opts, original_err)
  if not should_try_raw_ws(url, original_err) then
    return nil, nil
  end

  local ok_raw, raw_ws_client = pcall(require, "src.net.raw_ws_client")
  if not ok_raw or not raw_ws_client or type(raw_ws_client.connect) ~= "function" then
    return nil, nil
  end

  local conn, raw_err = raw_ws_client.connect(url, opts)
  if not conn then
    return nil, raw_err or "raw_ws_connect_failed"
  end

  return conn, nil
end

local default_ssl_params = {
  mode = "client",
  protocol = "any",
  options = {"all", "no_sslv2", "no_sslv3", "no_tlsv1"},
  verify = "none",
}

local function from_websocket_module(websocket)
  if not websocket or not websocket.client or not websocket.client.sync then
    return nil, "unsupported_websocket_module"
  end

  return {
    connect = function(url, opts)
      local conn = websocket.client.sync()
      local ok_connect, err = conn:connect(url, nil, default_ssl_params)
      if not ok_connect then
        local raw_conn, raw_err = try_raw_ws_fallback(url, opts, err)
        if raw_conn then
          local normalized_raw, normalize_raw_err = normalize_connection(raw_conn)
          if not normalized_raw then
            error(normalize_raw_err)
          end
          return normalized_raw
        end

        if should_retry_secure(url, err) then
          local secure_url = url:gsub("^ws://", "wss://", 1)
          local secure_conn = websocket.client.sync()
          local ok_secure, secure_err = secure_conn:connect(secure_url, nil, default_ssl_params)
          if ok_secure then
            local normalized_secure, normalize_secure_err = normalize_connection({
              send_text = function(_, message) return secure_conn:send(message) end,
              receive_text = function(_, timeout_ms)
                -- websocket.client.sync receive() is blocking; ignore timeout here.
                return secure_conn:receive()
              end,
              close = function(_) return secure_conn:close() end,
            })
            if not normalized_secure then
              error(normalize_secure_err)
            end
            return normalized_secure
          end

          if looks_like_ssl_runtime_error(secure_err) then
            error("secure_websocket_unavailable: install LuaSec/ssl for wss:// support (" .. tostring(secure_err) .. ")")
          end

          error(tostring(err or "websocket_connect_failed") .. " (secure_retry_failed: " .. tostring(secure_err) .. ")")
        end

        if raw_err then
          error(tostring(err or "websocket_connect_failed") .. " (raw_fallback_failed: " .. tostring(raw_err) .. ")")
        end

        if looks_like_ssl_runtime_error(err) then
          error("secure_websocket_unavailable: install LuaSec/ssl for wss:// support (" .. tostring(err) .. ")")
        end

        error(err or "websocket_connect_failed")
      end

      local normalized, normalize_err = normalize_connection({
        send_text = function(_, message) return conn:send(message) end,
        receive_text = function(_, _timeout_ms) return conn:receive() end,
        close = function(_) return conn:close() end,
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
