-- Headless authoritative match host.
--
-- Keeps simulation authority in one place and processes validated command
-- envelopes from clients.

local game_state = require("src.game.state")
local deck_validation = require("src.game.deck_validation")
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

local function extract_submit_envelope(player_index_or_envelope, maybe_envelope)
  if type(player_index_or_envelope) == "table" and maybe_envelope == nil then
    return player_index_or_envelope
  end
  return maybe_envelope
end

local function build_replay_append_opts(self)
  local opts = {
    post_state_hash_scope = "host_full",
    host_state_seq = self.state_seq or 0,
  }
  if not self.game_started then
    return opts
  end

  local visible_hashes = {}
  for player_index, _ in pairs(self.slots or {}) do
    if type(player_index) == "number" then
      local ok_state, visible_state = pcall(function()
        return self:get_state_snapshot_for_player(player_index)
      end)
      if ok_state and type(visible_state) == "table" then
        local ok_hash, visible_hash = pcall(checksum.game_state, visible_state)
        if ok_hash and type(visible_hash) == "string" then
          visible_hashes[player_index] = visible_hash
        end
      end
    end
  end
  opts.visible_state_hashes_by_player = visible_hashes
  return opts
end

local HIDDEN_CARD_TOKEN = "__HIDDEN_CARD__"

local function build_hidden_zone(count)
  local out = {}
  for i = 1, (count or 0) do
    out[i] = HIDDEN_CARD_TOKEN
  end
  return out
end

local function normalize_allowed_factions(allowed_factions)
  local out = {}
  if type(allowed_factions) == "table" then
    for faction, enabled in pairs(allowed_factions) do
      if type(faction) == "string" and enabled == true then
        out[faction] = true
      end
    end
    for _, faction in ipairs(allowed_factions) do
      if type(faction) == "string" then
        out[faction] = true
      end
    end
  end

  local has_entries = false
  for _, enabled in pairs(out) do
    if enabled == true then
      has_entries = true
      break
    end
  end
  if not has_entries then
    return game_state.supported_player_faction_set()
  end
  return out
end

local function validate_loadout(faction, deck_payload)
  if deck_payload == nil then
    return { ok = true, reason = "ok", faction = faction, deck = nil, meta = {} }
  end

  if type(faction) ~= "string" or faction == "" then
    return { ok = false, reason = "missing_faction_for_deck", meta = {} }
  end

  local validated = deck_validation.validate_decklist(faction, deck_payload)
  if not validated.ok then
    return validated
  end

  return {
    ok = true,
    reason = "ok",
    faction = faction,
    deck = validated.deck,
    meta = validated.meta or {},
  }
end

function host.new(opts)
  opts = opts or {}

  local allowed_factions = normalize_allowed_factions(opts.allowed_factions)

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
    state_seq = 0,
    _token_counter = 0,
    _host_session_token = nil,
    allowed_factions = allowed_factions,
  }, host)

  -- Pre-register host player 0 if host_player info provided (deferred game mode)
  if opts.host_player then
    local player_index = 0
    local host_faction = opts.host_player.faction
    if not self.allowed_factions[host_faction] then
      host_faction = nil
    end
    local host_loadout = validate_loadout(host_faction, opts.host_player.deck)
    self.lobby_players[player_index] = {
      name = opts.host_player.name or "Player",
      faction = host_faction,
      deck = host_loadout.ok and host_loadout.deck or nil,
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
    self.state_seq = self.state_seq + 1
  end

  return self
end

function host:_next_session_token(player_index)
  self._token_counter = self._token_counter + 1
  return table.concat({ self.match_id, tostring(player_index), tostring(self._token_counter) }, ":")
end

function host:_resync_payload(extra, player_index)
  local sync_checksum = nil
  if player_index ~= nil then
    local sync_state = self:get_state_snapshot_for_player(player_index)
    sync_checksum = checksum.game_state(sync_state)
  elseif self.state then
    sync_checksum = checksum.game_state(self.state)
  end
  local payload = {
    active_player = self.state.activePlayer,
    turn_number = self.state.turnNumber,
    checksum = sync_checksum,
    state_seq = self.state_seq or 0,
    checksum_algo = checksum.ALGORITHM,
    checksum_version = checksum.VERSION,
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
    local sync_state = self:get_state_snapshot_for_player(player_index)
    meta.active_player = self.state.activePlayer
    meta.turn_number = self.state.turnNumber
    meta.checksum = checksum.game_state(sync_state)
    meta.state_seq = self.state_seq or 0
    meta.checksum_algo = checksum.ALGORITHM
    meta.checksum_version = checksum.VERSION
  end
  return meta
end

function host:join(client_payload)
  local validation = protocol.validate_handshake({
    rules_version = self.rules_version,
    content_version = self.content_version,
    allowed_factions = self.allowed_factions,
  }, client_payload)

  if not validation.ok then
    return fail(validation.reason, validation.meta)
  end

  local requested_faction = client_payload and client_payload.faction
  if requested_faction ~= nil and not self.allowed_factions[requested_faction] then
    return fail("unsupported_faction", { faction = requested_faction })
  end

  local loadout = validate_loadout(requested_faction, client_payload and client_payload.deck)
  if not loadout.ok then
    return fail(loadout.reason, loadout.meta)
  end

  if self.next_player_index >= self.max_players then
    return fail("match_full")
  end

  local player_index = self.next_player_index
  self.next_player_index = self.next_player_index + 1

  -- Store lobby info (faction/deck) for deferred game creation
  self.lobby_players[player_index] = {
    name = client_payload.player_name or ("Player " .. tostring(player_index + 1)),
    faction = requested_faction,
    deck = loadout.deck,
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
    local started, start_err = pcall(function()
      self:_start_game()
    end)
    if not started then
      -- Roll back the reserved slot so a bad payload cannot poison the lobby.
      self.lobby_players[player_index] = nil
      self.slots[player_index] = nil
      self.session_tokens[token] = nil
      self.last_seq_by_player[player_index] = nil
      self.next_player_index = player_index
      return fail("match_start_failed", { error_message = tostring(start_err) })
    end
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
  self.state_seq = self.state_seq + 1
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

function host:player_index_for_session_token(session_token)
  if type(session_token) ~= "string" or session_token == "" then
    return nil
  end

  local player_index = self.session_tokens[session_token]
  if player_index == nil or not self.slots[player_index] then
    return nil
  end

  return player_index
end

function host:get_joined_player_indices()
  local out = {}
  for player_index, _ in pairs(self.slots) do
    out[#out + 1] = player_index
  end
  table.sort(out)
  return out
end

function host:get_state_snapshot_for_player(player_index)
  if not self.game_started then return nil end

  local state = deep_copy(self.state)
  if type(player_index) ~= "number" then
    return state
  end

  for i, player in ipairs(state.players or {}) do
    local state_player_index = i - 1
    if state_player_index ~= player_index and type(player) == "table" then
      player.hand = build_hidden_zone(#(player.hand or {}))
      player.deck = build_hidden_zone(#(player.deck or {}))
    end
  end

  return state
end

function host:submit(player_index_or_envelope, maybe_envelope)
  local envelope = extract_submit_envelope(player_index_or_envelope, maybe_envelope)

  if not self.game_started then
    return fail("game_not_started")
  end
  if type(envelope) ~= "table" then
    return fail("invalid_submit_payload")
  end

  local validation = protocol.validate_submit_command(envelope)
  if not validation.ok then
    return fail(validation.reason)
  end

  if envelope.match_id ~= self.match_id then
    return fail("match_id_mismatch")
  end

  local player_index = self:player_index_for_session_token(envelope.session_token)
  if player_index == nil then
    return fail("session_not_found")
  end

  local sync_state_before = self:get_state_snapshot_for_player(player_index)
  local host_checksum_before = checksum.game_state(sync_state_before)
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

  if command.type == "START_TURN" then
    return fail("command_not_allowed", {
      command_type = command.type,
      expected = "host_internal_only",
    })
  end

  local result = commands.execute(self.state, command)
  replay.append(self.replay_log, command, result, self.state, build_replay_append_opts(self))

  if not result.ok then
    return fail(result.reason, self:_resync_payload({
      seq = envelope.seq,
      events = result.events or {},
    }, player_index))
  end

  -- After a successful END_TURN, automatically execute START_TURN for the new
  -- active player so clients don't need to send it (the host would stamp the
  -- wrong player_index on a client-sent START_TURN).
  if command.type == "END_TURN" and not self.state.is_terminal then
    local start_cmd = { type = "START_TURN", player_index = self.state.activePlayer }
    local start_result = commands.execute(self.state, start_cmd)
    replay.append(self.replay_log, start_cmd, start_result, self.state, build_replay_append_opts(self))
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
  self.state_seq = (self.state_seq or 0) + 1
  local sync_state_after = self:get_state_snapshot_for_player(player_index)
  local sync_checksum_after = checksum.game_state(sync_state_after)

  return ok({
    seq = envelope.seq,
    active_player = self.state.activePlayer,
    turn_number = self.state.turnNumber,
    events = result.events or {},
    checksum = sync_checksum_after,
    state_seq = self.state_seq,
    checksum_algo = checksum.ALGORITHM,
    checksum_version = checksum.VERSION,
    next_expected_seq = self.last_seq_by_player[player_index] + 1,
    state = sync_state_after,
  })
end

function host:submit_message(player_index_or_envelope, maybe_envelope)
  local envelope = extract_submit_envelope(player_index_or_envelope, maybe_envelope)
  if type(envelope) ~= "table" then
    return protocol.error_message(self.match_id, "invalid_submit_payload")
  end

  local result = self:submit(envelope)
  local seq = envelope.seq or 0
  if result.ok then
    return protocol.command_ack(self.match_id, seq, result.meta)
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

function host:get_state_snapshot_message(snapshot_payload)
  if not self.game_started then
    return protocol.error_message(self.match_id, "game_not_started")
  end

  local validation = protocol.validate_snapshot_request(snapshot_payload)
  if not validation.ok then
    return protocol.error_message(self.match_id, validation.reason)
  end
  if snapshot_payload.match_id ~= self.match_id then
    return protocol.error_message(self.match_id, "match_id_mismatch")
  end

  local player_index = self:player_index_for_session_token(snapshot_payload.session_token)
  if player_index == nil then
    return protocol.error_message(self.match_id, "session_not_found")
  end

  local visible_state = self:get_state_snapshot_for_player(player_index)
  local payload = {
    active_player = self.state.activePlayer,
    turn_number = self.state.turnNumber,
    checksum = checksum.game_state(visible_state),
    state_seq = self.state_seq or 0,
    checksum_algo = checksum.ALGORITHM,
    checksum_version = checksum.VERSION,
    state = visible_state,
  }

  return protocol.state_snapshot(self.match_id, payload)
end

function host:generate_state_push(player_index)
  if not self.game_started then return nil end
  if type(player_index) ~= "number" or not self.slots[player_index] then
    return nil
  end

  local visible_state = self:get_state_snapshot_for_player(player_index)
  local payload = {
    active_player = self.state.activePlayer,
    turn_number = self.state.turnNumber,
    checksum = checksum.game_state(visible_state),
    state_seq = self.state_seq or 0,
    checksum_algo = checksum.ALGORITHM,
    checksum_version = checksum.VERSION,
    state = visible_state,
  }
  return protocol.state_push(self.match_id, payload)
end

function host:get_replay_snapshot()
  return replay.snapshot(self.replay_log)
end

return host
