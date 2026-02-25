-- Client-side session adapter for multiplayer command submission.
--
-- Works with transport objects that implement:
--   connect(handshake_payload)
--   reconnect(reconnect_payload)
--   send_submit(envelope)
--   request_snapshot(snapshot_payload)

local protocol = require("src.net.protocol")
local config = require("src.data.config")

local client_session = {}
client_session.__index = client_session

local function fail(reason, meta)
  return { ok = false, reason = reason, meta = meta or {} }
end

local function ok(meta)
  return { ok = true, reason = "ok", meta = meta or {} }
end

function client_session.new(opts)
  opts = opts or {}
  return setmetatable({
    transport = opts.transport,
    match_id = nil,
    player_index = nil,
    session_token = nil,
    next_seq = 1,
    last_checksum = nil,
    last_state_seq = 0,
    connected = false,
    player_name = opts.player_name or "Player",
    faction = opts.faction,
    deck = opts.deck,
  }, client_session)
end

function client_session:connect()
  if not self.transport then return fail("missing_transport") end

  local handshake = protocol.handshake({
    rules_version = config.rules_version,
    content_version = config.content_version,
    player_name = self.player_name,
    faction = self.faction,
    deck = self.deck,
  })

  local response = self.transport:connect(handshake)
  if response.type == "error" then
    return fail(response.reason, response.payload)
  end
  if response.type ~= "command_ack" or not response.payload then
    return fail("invalid_connect_response")
  end

  self.match_id = response.payload.match_id
  self.player_index = response.payload.player_index
  self.session_token = response.payload.session_token
  if type(self.session_token) ~= "string" or self.session_token == "" then
    return fail("missing_session_token")
  end
  self.last_checksum = response.payload.checksum
  self.last_state_seq = tonumber(response.payload.state_seq) or self.last_state_seq or 0
  self.next_seq = response.payload.next_expected_seq or 1
  self.connected = true

  return ok({ player_index = self.player_index, match_id = self.match_id })
end

function client_session:disconnect_local()
  self.connected = false
  return ok({ disconnected = true })
end

function client_session:reconnect()
  if not self.transport then return fail("missing_transport") end
  if not self.match_id or not self.session_token then return fail("missing_session") end

  local payload = protocol.reconnect(self.match_id, self.session_token)
  local response = self.transport:reconnect(payload)

  if response.type == "error" then
    return fail(response.reason, response.payload)
  end
  if response.type ~= "command_ack" or not response.payload then
    return fail("invalid_reconnect_response")
  end

  self.player_index = response.payload.player_index
  self.last_checksum = response.payload.checksum
  self.last_state_seq = tonumber(response.payload.state_seq) or self.last_state_seq or 0
  self.next_seq = response.payload.next_expected_seq or self.next_seq
  if type(response.payload.session_token) == "string" and response.payload.session_token ~= "" then
    self.session_token = response.payload.session_token
  end
  self.connected = true

  return ok({ player_index = self.player_index, match_id = self.match_id })
end

function client_session:submit(command)
  if not self.connected then return fail("not_connected") end
  if type(self.session_token) ~= "string" or self.session_token == "" then
    return fail("missing_session_token")
  end

  local envelope = protocol.submit_command(
    self.match_id,
    self.next_seq,
    command,
    self.last_checksum,
    self.session_token
  )
  local response = self.transport:send_submit(envelope)

  if response.type == "command_ack" then
    self.next_seq = (response.payload and response.payload.next_expected_seq) or (self.next_seq + 1)
    self.last_checksum = response.payload and response.payload.checksum or self.last_checksum
    self.last_state_seq = tonumber(response.payload and response.payload.state_seq) or self.last_state_seq or 0
    return ok(response.payload)
  end

  if response.type == "resync_required" then
    self.last_checksum = nil
    self.last_state_seq = tonumber(response.payload and response.payload.state_seq) or self.last_state_seq or 0
    if response.payload and response.payload.next_expected_seq then
      self.next_seq = response.payload.next_expected_seq
    end
    return fail("resync_required", response.payload)
  end

  if response.type == "error" then
    return fail(response.reason, response.payload)
  end

  return fail("unknown_response_type", { response_type = response.type })
end

function client_session:submit_with_resync(command)
  local result = self:submit(command)
  if result.ok then return result end
  if result.reason ~= "resync_required" then return result end

  local snap = self:request_snapshot()
  if not snap.ok then
    return fail("resync_failed", {
      submit_reason = result.reason,
      snapshot_reason = snap.reason,
    })
  end

  return fail("resynced_retry_required", {
    checksum = self.last_checksum,
    state_seq = self.last_state_seq,
    active_player = snap.meta.active_player,
    turn_number = snap.meta.turn_number,
  })
end

function client_session:request_snapshot()
  if not self.connected then return fail("not_connected") end
  if not self.match_id or not self.session_token then return fail("missing_session") end

  local snapshot_request = protocol.request_snapshot(self.match_id, self.session_token)
  local response = self.transport:request_snapshot(snapshot_request)
  if response.type ~= "state_snapshot" then
    return fail("invalid_snapshot_response")
  end
  self.last_checksum = response.payload and response.payload.checksum or self.last_checksum
  self.last_state_seq = tonumber(response.payload and response.payload.state_seq) or self.last_state_seq or 0
  return ok(response.payload)
end

return client_session
