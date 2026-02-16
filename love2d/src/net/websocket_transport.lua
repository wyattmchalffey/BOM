-- Websocket-ready transport adapter.
--
-- This module is transport-client agnostic. It expects an injected `client`
-- object implementing:
--   client:send(frame)
--   client:receive(timeout_ms) -> frame
--
-- By default, frames are Lua tables (identity codec). For real websocket
-- clients, provide encode/decode functions (for example JSON text codec).

local protocol = require("src.net.protocol")

local transport = {}
transport.__index = transport

local function identity(v)
  return v
end

local RELAY_CONTROL_TYPES = {
  room_created = true,
  peer_joined = true,
  peer_disconnected = true,
  joined = true,
  error = true,
}

local function is_relay_control_message(decoded)
  return type(decoded) == "table"
    and type(decoded.type) == "string"
    and RELAY_CONTROL_TYPES[decoded.type] == true
end

function transport.new(opts)
  opts = opts or {}
  return setmetatable({
    client = opts.client,
    encode = opts.encode or identity,
    decode = opts.decode or identity,
    timeout_ms = opts.timeout_ms or 2000,
  }, transport)
end

function transport:_error(match_id, reason, meta)
  return protocol.error_message(match_id, reason, meta or {})
end

function transport:_request(op, payload, player_index)
  local match_id = payload and payload.match_id

  if not self.client then
    return self:_error(match_id, "missing_transport_client")
  end

  local request = {
    op = op,
    payload = payload,
    player_index = player_index,
  }

  local encode_ok, framed = pcall(self.encode, request)
  if not encode_ok then
    return self:_error(match_id, "transport_encode_failed", { error_message = tostring(framed) })
  end

  local send_ok, send_err = pcall(self.client.send, self.client, framed)
  if not send_ok then
    return self:_error(match_id, "transport_send_failed", { error_message = tostring(send_err) })
  end

  local response = nil
  for _ = 1, 8 do
    local receive_ok, raw_response = pcall(self.client.receive, self.client, self.timeout_ms)
    if not receive_ok then
      return self:_error(match_id, "transport_receive_failed", { error_message = tostring(raw_response) })
    end
    if raw_response == nil then
      return self:_error(match_id, "transport_timeout")
    end

    local decode_ok, decoded = pcall(self.decode, raw_response)
    if not decode_ok then
      return self:_error(match_id, "transport_decode_failed", { error_message = tostring(decoded) })
    end

    if is_relay_control_message(decoded) then
      -- Relay may send control envelopes (for example "joined") before the
      -- host's protocol response; skip and wait for the next frame.
      response = nil
    else
      response = decoded
      break
    end
  end

  if response == nil then
    return self:_error(match_id, "transport_no_protocol_response")
  end

  if type(response) ~= "table" then
    return self:_error(match_id, "invalid_transport_response")
  end

  if not response.ok then
    return self:_error(match_id, response.reason or "transport_error", response.meta or {})
  end

  if type(response.message) ~= "table" then
    return self:_error(match_id, "missing_transport_message")
  end

  return response.message
end

function transport:connect(handshake_payload)
  return self:_request("connect", handshake_payload)
end

function transport:reconnect(reconnect_payload)
  return self:_request("reconnect", reconnect_payload)
end

function transport:send_submit(player_index, envelope)
  return self:_request("submit", envelope, player_index)
end

function transport:request_snapshot()
  return self:_request("snapshot", nil)
end

return transport
