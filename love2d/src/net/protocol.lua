-- Multiplayer protocol helpers.
--
-- This is transport-agnostic scaffolding for future socket/websocket layers.

local protocol = {}

protocol.VERSION = 2

local function fail(reason, meta)
  return { ok = false, reason = reason, meta = meta }
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
    faction = client.faction,
    deck = client.deck,
  }
end

local function is_allowed_faction(allowed_factions, faction)
  if type(allowed_factions) ~= "table" then
    return true
  end

  if allowed_factions[faction] == true then
    return true
  end

  local has_entries = false
  for _, allowed in ipairs(allowed_factions) do
    has_entries = true
    if allowed == faction then
      return true
    end
  end

  -- Empty allow-list means "no explicit restriction".
  if not has_entries then
    for _, _ in pairs(allowed_factions) do
      has_entries = true
      break
    end
  end
  return not has_entries
end

local function validate_deck_schema(deck_payload)
  if type(deck_payload) ~= "table" then
    return false, "invalid_deck_payload"
  end

  local cards_list = deck_payload
  if deck_payload.cards ~= nil then
    if type(deck_payload.cards) ~= "table" then
      return false, "invalid_deck_payload"
    end
    cards_list = deck_payload.cards
  end

  local seen = 0
  local max_index = 0
  for k, card_id in pairs(cards_list) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
      return false, "invalid_deck_payload"
    end
    if type(card_id) ~= "string" or card_id == "" then
      return false, "invalid_deck_card_id"
    end
    seen = seen + 1
    if k > max_index then
      max_index = k
    end
  end

  if seen <= 0 then
    return false, "empty_deck"
  end
  if max_index ~= seen then
    return false, "invalid_deck_payload"
  end
  if seen > 120 then
    return false, "deck_too_large"
  end

  return true, nil
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
  if payload.player_name ~= nil and type(payload.player_name) ~= "string" then
    return fail("invalid_player_name")
  end

  if payload.faction ~= nil then
    if type(payload.faction) ~= "string" or payload.faction == "" then
      return fail("invalid_faction")
    end
    if not is_allowed_faction(server and server.allowed_factions, payload.faction) then
      return fail("unsupported_faction")
    end
  end

  if payload.deck ~= nil then
    local deck_ok, deck_reason = validate_deck_schema(payload.deck)
    if not deck_ok then
      return fail(deck_reason)
    end
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

function protocol.submit_command(match_id, seq, command, client_checksum, session_token)
  return {
    type = "submit_command",
    protocol_version = protocol.VERSION,
    match_id = match_id,
    seq = seq,
    command = command,
    client_checksum = client_checksum,
    session_token = session_token,
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
  if type(payload.session_token) ~= "string" or payload.session_token == "" then
    return fail("invalid_session_token")
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

function protocol.request_snapshot(match_id, session_token)
  return {
    type = "request_snapshot",
    protocol_version = protocol.VERSION,
    match_id = match_id,
    session_token = session_token,
  }
end

function protocol.validate_snapshot_request(payload)
  if not payload or payload.type ~= "request_snapshot" then
    return fail("invalid_snapshot_payload")
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
