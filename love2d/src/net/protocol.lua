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

function protocol.submit_command(match_id, seq, command)
  return {
    type = "submit_command",
    protocol_version = protocol.VERSION,
    match_id = match_id,
    seq = seq,
    command = command,
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
  return ok({ accepted = true })
end

return protocol
