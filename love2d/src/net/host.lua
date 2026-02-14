-- Headless authoritative match host.
--
-- Keeps simulation authority in one place and processes validated command
-- envelopes from clients.

local game_state = require("src.game.state")
local commands = require("src.game.commands")
local replay = require("src.game.replay")
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
    max_players = opts.max_players or 2,
    next_player_index = 0,
    last_seq_by_player = {},
  }, host)

  -- Mirror current local game startup behavior.
  commands.execute(self.state, { type = "START_TURN", player_index = self.state.activePlayer })

  return self
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
  self.slots[player_index] = {
    player_name = client_payload.player_name or ("Player " .. tostring(player_index + 1)),
  }
  self.last_seq_by_player[player_index] = 0

  return ok({
    match_id = self.match_id,
    player_index = player_index,
    active_player = self.state.activePlayer,
    turn_number = self.state.turnNumber,
  })
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

  local expected_seq = (self.last_seq_by_player[player_index] or 0) + 1
  if envelope.seq ~= expected_seq then
    return fail("sequence_out_of_order", {
      expected_seq = expected_seq,
      received_seq = envelope.seq,
    })
  end

  local command = deep_copy(envelope.command)
  command.player_index = player_index

  local result = commands.execute(self.state, command)
  replay.append(self.replay_log, command, result, self.state)

  if not result.ok then
    return fail(result.reason, {
      seq = envelope.seq,
      active_player = self.state.activePlayer,
      turn_number = self.state.turnNumber,
      events = result.events or {},
    })
  end

  self.last_seq_by_player[player_index] = envelope.seq

  return ok({
    seq = envelope.seq,
    active_player = self.state.activePlayer,
    turn_number = self.state.turnNumber,
    events = result.events or {},
  })
end

function host:get_state_snapshot()
  return deep_copy(self.state)
end

function host:get_replay_snapshot()
  return replay.snapshot(self.replay_log)
end

return host
