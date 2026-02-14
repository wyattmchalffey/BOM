-- Headless authoritative match host.
--
-- Keeps simulation authority in one place and processes validated command
-- envelopes from clients.

local game_state = require("src.game.state")
local commands = require("src.game.commands")
local replay = require("src.game.replay")
local checksum = require("src.game.checksum")
local protocol = require("src.net.protocol")
local config = require("src.data.config")

local host = {}
host.__index = host

local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deep_copy(v)
  end
  return out
end

local function fail(reason, meta)
  return { ok = false, reason = reason, meta = meta or {} }
end

local function ok(meta)
  return { ok = true, reason = "ok", meta = meta or {} }
end

function host.new(opts)
  opts = opts or {}
  local g = game_state.create_initial_game_state(opts.setup)
  local self = setmetatable({
    match_id = opts.match_id or "local-match",
    state = g,
    rules_version = opts.rules_version or config.rules_version,
    content_version = opts.content_version or config.content_version,
    replay_log = replay.new_log({
      command_schema_version = commands.SCHEMA_VERSION,
      rules_version = opts.rules_version or config.rules_version,
      content_version = opts.content_version or config.content_version,
    }),
    slots = {},
    session_tokens = {},
    max_players = opts.max_players or 2,
    next_player_index = 0,
    last_seq_by_player = {},
    _token_counter = 0,
  }, host)

  -- Mirror current local game startup behavior.
  commands.execute(self.state, { type = "START_TURN", player_index = self.state.activePlayer })

  return self
end

function host:_next_session_token(player_index)
  self._token_counter = self._token_counter + 1
  return table.concat({ self.match_id, tostring(player_index), tostring(self._token_counter) }, ":")
end

function host:_resync_payload(extra, player_index)
  local payload = {
    active_player = self.state.activePlayer,
    turn_number = self.state.turnNumber,
    checksum = checksum.game_state(self.state),
  }
  if player_index ~= nil then
    payload.next_expected_seq = (self.last_seq_by_player[player_index] or 0) + 1
  end
  if extra then
    for k, v in pairs(extra) do
      payload[k] = v
    end
  end
  return payload
end

function host:_build_session_meta(player_index)
  return {
    match_id = self.match_id,
    player_index = player_index,
    active_player = self.state.activePlayer,
    turn_number = self.state.turnNumber,
    checksum = checksum.game_state(self.state),
    session_token = self.slots[player_index].session_token,
    next_expected_seq = (self.last_seq_by_player[player_index] or 0) + 1,
  }
end

function host:join(client_payload)
  local v = protocol.validate_handshake({
    rules_version = self.rules_version,
    content_version = self.content_version,
  }, client_payload)
  if not v.ok then
    return fail(v.reason)
  end

  if self.next_player_index >= self.max_players then
    return fail("match_full")
  end

  local player_index = self.next_player_index
  self.next_player_index = self.next_player_index + 1

  local token = self:_next_session_token(player_index)
  self.slots[player_index] = {
    player_name = client_payload.player_name or ("Player " .. tostring(player_index + 1)),
    session_token = token,
  }
  self.session_tokens[token] = player_index
  self.last_seq_by_player[player_index] = 0

  return ok(self:_build_session_meta(player_index))
end

function host:reconnect(reconnect_payload)
  local v = protocol.validate_reconnect(reconnect_payload)
  if not v.ok then return fail(v.reason) end
  if reconnect_payload.match_id ~= self.match_id then
    return fail("match_id_mismatch")
  end

  local player_index = self.session_tokens[reconnect_payload.session_token]
  if player_index == nil or not self.slots[player_index] then
    return fail("session_not_found")
  end

  return ok(self:_build_session_meta(player_index))
end

function host:submit(player_index, envelope)
  if not self.slots[player_index] then
    return fail("player_not_joined")
  end

  local pv = protocol.validate_submit_command(envelope)
  if not pv.ok then
    return fail(pv.reason)
  end

  if envelope.match_id ~= self.match_id then
    return fail("match_id_mismatch")
  end

  local host_checksum_before = checksum.game_state(self.state)
  if envelope.client_checksum ~= nil and envelope.client_checksum ~= host_checksum_before then
    return fail("checksum_mismatch", self:_resync_payload({
      received_checksum = envelope.client_checksum,
    }, player_index))
  end

  local expected_seq = (self.last_seq_by_player[player_index] or 0) + 1
  if envelope.seq ~= expected_seq then
    return fail("sequence_out_of_order", self:_resync_payload({
      expected_seq = expected_seq,
      received_seq = envelope.seq,
    }, player_index))
  end

  local command = deep_copy(envelope.command)
  command.player_index = player_index

  local result = commands.execute(self.state, command)
  replay.append(self.replay_log, command, result, self.state)

  if not result.ok then
    return fail(result.reason, self:_resync_payload({
      seq = envelope.seq,
      events = result.events or {},
    }, player_index))
  end

  self.last_seq_by_player[player_index] = envelope.seq

  return ok({
    seq = envelope.seq,
    active_player = self.state.activePlayer,
    turn_number = self.state.turnNumber,
    events = result.events or {},
    checksum = checksum.game_state(self.state),
    next_expected_seq = self.last_seq_by_player[player_index] + 1,
  })
end

function host:submit_message(player_index, envelope)
  local result = self:submit(player_index, envelope)
  if result.ok then
    return protocol.command_ack(self.match_id, envelope.seq, result.meta)
  end

  if result.reason == "sequence_out_of_order" or result.reason == "checksum_mismatch" then
    return protocol.resync_required(self.match_id, result.meta)
  end

  return protocol.error_message(self.match_id, result.reason, result.meta)
end

function host:connect_message(handshake_payload)
  local join_result = self:join(handshake_payload)
  if join_result.ok then
    return protocol.command_ack(self.match_id, 0, join_result.meta)
  end
  return protocol.error_message(self.match_id, join_result.reason, join_result.meta)
end

function host:reconnect_message(reconnect_payload)
  local reconnect_result = self:reconnect(reconnect_payload)
  if reconnect_result.ok then
    return protocol.command_ack(self.match_id, 0, reconnect_result.meta)
  end
  return protocol.error_message(self.match_id, reconnect_result.reason, reconnect_result.meta)
end

function host:get_state_snapshot()
  return deep_copy(self.state)
end

function host:get_state_snapshot_message()
  local payload = {
    active_player = self.state.activePlayer,
    turn_number = self.state.turnNumber,
    checksum = checksum.game_state(self.state),
    state = self:get_state_snapshot(),
  }
  return protocol.state_snapshot(self.match_id, payload)
end

function host:get_replay_snapshot()
  return replay.snapshot(self.replay_log)
end

return host
