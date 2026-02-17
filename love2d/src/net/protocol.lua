-- Multiplayer protocol helpers.
--
-- This is transport-agnostic scaffolding for future socket/websocket layers.

local protocol = {}

protocol.VERSION = 1

local function fail(reason)
  return { ok = false, reason = reason }
end

local function ok(meta)
  return { ok = true, reason = "ok", meta = meta }
end

function protocol.handshake(client)
  if not client then return nil end
  return {
    type = "join_match",
    protocol_version = protocol.VERSION,
    rules_version = client.rules_version,
    content_version = client.content_version,
    player_name = client.player_name,
  }
end

function protocol.validate_handshake(server, payload)
  if not payload or payload.type ~= "join_match" then
    return fail("invalid_handshake_payload")
  end
  if payload.protocol_version ~= protocol.VERSION then
    return fail("protocol_version_mismatch")
  end
  if payload.rules_version ~= server.rules_version then
    return fail("rules_version_mismatch")
  end
  if payload.content_version ~= server.content_version then
    return fail("content_version_mismatch")
  end
  return ok({ accepted = true })
end

function protocol.reconnect(match_id, session_token)
  return {
    type = "reconnect_match",
    protocol_version = protocol.VERSION,
    match_id = match_id,
    session_token = session_token,
  }
end

function protocol.validate_reconnect(payload)
  if not payload or payload.type ~= "reconnect_match" then
    return fail("invalid_reconnect_payload")
  end
  if payload.protocol_version ~= protocol.VERSION then
    return fail("protocol_version_mismatch")
  end
  if type(payload.match_id) ~= "string" or payload.match_id == "" then
    return fail("invalid_match_id")
  end
  if type(payload.session_token) ~= "string" or payload.session_token == "" then
    return fail("invalid_session_token")
  end
  return ok({ accepted = true })
end

function protocol.submit_command(match_id, seq, command, client_checksum)
  return {
    type = "submit_command",
    protocol_version = protocol.VERSION,
    match_id = match_id,
    seq = seq,
    command = command,
    client_checksum = client_checksum,
  }
end

function protocol.validate_submit_command(payload)
  if not payload or payload.type ~= "submit_command" then
    return fail("invalid_submit_payload")
  end
  if payload.protocol_version ~= protocol.VERSION then
    return fail("protocol_version_mismatch")
  end
  if type(payload.match_id) ~= "string" or payload.match_id == "" then
    return fail("invalid_match_id")
  end
  if type(payload.seq) ~= "number" or payload.seq < 1 then
    return fail("invalid_sequence")
  end
  if type(payload.command) ~= "table" or type(payload.command.type) ~= "string" then
    return fail("invalid_command_payload")
  end
  if payload.client_checksum ~= nil and type(payload.client_checksum) ~= "string" then
    return fail("invalid_client_checksum")
  end
  return ok({ accepted = true })
end

function protocol.command_ack(match_id, seq, payload)
  return {
    type = "command_ack",
    protocol_version = protocol.VERSION,
    match_id = match_id,
    seq = seq,
    payload = payload,
  }
end

function protocol.state_snapshot(match_id, payload)
  return {
    type = "state_snapshot",
    protocol_version = protocol.VERSION,
    match_id = match_id,
    payload = payload,
  }
end

function protocol.resync_required(match_id, payload)
  return {
    type = "resync_required",
    protocol_version = protocol.VERSION,
    match_id = match_id,
    payload = payload,
  }
end

function protocol.state_push(match_id, payload)
  return {
    type = "state_push",
    protocol_version = protocol.VERSION,
    match_id = match_id,
    payload = payload,
  }
end

function protocol.error_message(match_id, reason, payload)
  return {
    type = "error",
    protocol_version = protocol.VERSION,
    match_id = match_id,
    reason = reason,
    payload = payload or {},
  }
end

return protocol