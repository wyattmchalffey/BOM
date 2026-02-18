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
  if type(value) ~= "table" then
    return value
  end

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

  local self = setmetatable({
    match_id = opts.match_id or "local-match",
    state = nil,
    game_started = false,
    lobby_players = {},
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
    _host_session_token = nil,
  }, host)

  -- Pre-register host player 0 if host_player info provided (deferred game mode)
  if opts.host_player then
    local player_index = 0
    self.lobby_players[player_index] = {
      name = opts.host_player.name or "Player",
      faction = opts.host_player.faction,
      deck = opts.host_player.deck,
    }
    local token = self:_next_session_token(player_index)
    self.slots[player_index] = {
      player_name = opts.host_player.name or "Player",
      session_token = token,
    }
    self.session_tokens[token] = player_index
    self.last_seq_by_player[player_index] = 0
    self.next_player_index = 1
    self._host_session_token = token
  else
    -- Immediate start mode (local game / backward compat)
    self.state = game_state.create_initial_game_state(opts.setup)
    self.game_started = true
    commands.execute(self.state, { type = "START_TURN", player_index = self.state.activePlayer })
  end

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
  local meta = {
    match_id = self.match_id,
    player_index = player_index,
    session_token = self.slots[player_index].session_token,
    next_expected_seq = (self.last_seq_by_player[player_index] or 0) + 1,
  }
  if self.state then
    meta.active_player = self.state.activePlayer
    meta.turn_number = self.state.turnNumber
    meta.checksum = checksum.game_state(self.state)
  end
  return meta
end

function host:join(client_payload)
  local validation = protocol.validate_handshake({
    rules_version = self.rules_version,
    content_version = self.content_version,
  }, client_payload)

  if not validation.ok then
    return fail(validation.reason)
  end

  if self.next_player_index >= self.max_players then
    return fail("match_full")
  end

  local player_index = self.next_player_index
  self.next_player_index = self.next_player_index + 1

  -- Store lobby info (faction/deck) for deferred game creation
  self.lobby_players[player_index] = {
    name = client_payload.player_name or ("Player " .. tostring(player_index + 1)),
    faction = client_payload.faction,
    deck = client_payload.deck,
  }

  local token = self:_next_session_token(player_index)
  self.slots[player_index] = {
    player_name = client_payload.player_name or ("Player " .. tostring(player_index + 1)),
    session_token = token,
  }
  self.session_tokens[token] = player_index
  self.last_seq_by_player[player_index] = 0

  -- Auto-start game when lobby is full
  if not self.game_started and self.next_player_index >= self.max_players then
    self:_start_game()
  end

  return ok(self:_build_session_meta(player_index))
end

function host:_start_game()
  -- Randomize who goes first
  local first_player = math.random(0, self.max_players - 1)

  -- Build setup table from lobby_players
  -- First player gets 3 workers, second player gets 4
  local player_setups = {}
  for i = 0, self.max_players - 1 do
    local lp = self.lobby_players[i] or {}
    player_setups[i + 1] = {
      faction = lp.faction,
      deck = lp.deck,
      starting_workers = (i == first_player) and 2 or 3,
    }
  end

  self.state = game_state.create_initial_game_state({
    first_player = first_player,
    players = player_setups,
  })
  self.game_started = true
  commands.execute(self.state, { type = "START_TURN", player_index = self.state.activePlayer })
end

function host:is_game_started()
  return self.game_started
end

function host:reconnect(reconnect_payload)
  local validation = protocol.validate_reconnect(reconnect_payload)
  if not validation.ok then
    return fail(validation.reason)
  end

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
  if not self.game_started then
    return fail("game_not_started")
  end
  if not self.slots[player_index] then
    return fail("player_not_joined")
  end

  local validation = protocol.validate_submit_command(envelope)
  if not validation.ok then
    return fail(validation.reason)
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

  -- After a successful END_TURN, automatically execute START_TURN for the new
  -- active player so clients don't need to send it (the host would stamp the
  -- wrong player_index on a client-sent START_TURN).
  if command.type == "END_TURN" then
    local start_cmd = { type = "START_TURN", player_index = self.state.activePlayer }
    local start_result = commands.execute(self.state, start_cmd)
    replay.append(self.replay_log, start_cmd, start_result, self.state)
    if start_result.ok then
      local events = result.events or {}
      if start_result.events then
        for _, e in ipairs(start_result.events) do
          events[#events + 1] = e
        end
      end
      result = { ok = true, meta = result.meta, events = events }
    end
  end

  self.last_seq_by_player[player_index] = envelope.seq

  return ok({
    seq = envelope.seq,
    active_player = self.state.activePlayer,
    turn_number = self.state.turnNumber,
    events = result.events or {},
    checksum = checksum.game_state(self.state),
    next_expected_seq = self.last_seq_by_player[player_index] + 1,
    state = deep_copy(self.state),
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
  if not self.game_started then return nil end
  return deep_copy(self.state)
end

function host:get_state_snapshot_message()
  if not self.game_started then
    return protocol.error_message(self.match_id, "game_not_started")
  end
  local payload = {
    active_player = self.state.activePlayer,
    turn_number = self.state.turnNumber,
    checksum = checksum.game_state(self.state),
    state = self:get_state_snapshot(),
  }

  return protocol.state_snapshot(self.match_id, payload)
end

function host:generate_state_push()
  if not self.game_started then return nil end
  local payload = {
    active_player = self.state.activePlayer,
    turn_number = self.state.turnNumber,
    checksum = checksum.game_state(self.state),
    state = self:get_state_snapshot(),
  }
  return protocol.state_push(self.match_id, payload)
end

function host:get_replay_snapshot()
  return replay.snapshot(self.replay_log)
end

return host