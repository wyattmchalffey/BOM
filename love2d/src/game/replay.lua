-- Replay and command-log helpers for deterministic simulation workflows.
--
-- This module intentionally has no Love2D dependencies so it can be shared
-- between client and future headless host processes.

local replay = {}
local checksum = require("src.game.checksum")

replay.FORMAT_VERSION = 2

local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do
    out[deep_copy(k)] = deep_copy(v)
  end
  return out
end

local function iso_utc_now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function replay.new_log(opts)
  opts = opts or {}
  return {
    format_version = replay.FORMAT_VERSION,
    command_schema_version = opts.command_schema_version or 1,
    rules_version = opts.rules_version or "dev",
    content_version = opts.content_version or "dev",
    created_at = opts.created_at or iso_utc_now(),
    state_hash_algorithm = checksum.ALGORITHM,
    state_hash_version = checksum.VERSION,
    entries = {},
  }
end

local function build_replay_hash_telemetry(result, game_state, opts)
  opts = opts or {}
  local telemetry = {
    post_state_hash = nil,
    post_state_hash_algo = checksum.ALGORITHM,
    post_state_hash_version = checksum.VERSION,
    post_state_hash_scope = opts.post_state_hash_scope or "unknown",
    post_state_viewer_player_index = opts.post_state_viewer_player_index,
  }

  if game_state ~= nil then
    local ok_hash, hash_or_err = pcall(checksum.game_state, game_state)
    if ok_hash then
      telemetry.post_state_hash = hash_or_err
    else
      telemetry.post_state_hash_error = tostring(hash_or_err)
    end
  end

  local meta = result and result.meta or nil
  if type(meta) == "table" then
    if type(meta.checksum) == "string" then
      telemetry.authoritative_checksum = meta.checksum
    end
    if type(meta.state_seq) == "number" then
      telemetry.authoritative_state_seq = meta.state_seq
    end
    if type(meta.checksum_algo) == "string" then
      telemetry.authoritative_checksum_algo = meta.checksum_algo
    end
    if type(meta.checksum_version) == "number" then
      telemetry.authoritative_checksum_version = meta.checksum_version
    end
  end

  if type(telemetry.post_state_hash) == "string"
    and type(telemetry.authoritative_checksum) == "string"
  then
    telemetry.post_state_hash_matches_authoritative =
      (telemetry.post_state_hash == telemetry.authoritative_checksum)
  end

  if type(opts.visible_state_hashes_by_player) == "table" then
    telemetry.visible_state_hashes_by_player = deep_copy(opts.visible_state_hashes_by_player)
  end

  if type(opts.host_state_seq) == "number" then
    telemetry.host_state_seq = opts.host_state_seq
  end

  return telemetry
end

function replay.append(log, command, result, game_state, opts)
  local entries = log.entries
  local entry = {
    seq = #entries + 1,
    command = deep_copy(command),
    command_type = command and command.type or nil,
    ok = result and result.ok or false,
    reason = result and result.reason or "unknown",
    meta = deep_copy(result and result.meta or nil),
    events = deep_copy(result and result.events or {}),
    turn_number = game_state and game_state.turnNumber or nil,
    active_player = game_state and game_state.activePlayer or nil,
  }
  local telemetry = build_replay_hash_telemetry(result, game_state, opts)
  for k, v in pairs(telemetry) do
    entry[k] = v
  end
  entries[#entries + 1] = entry
  return entry
end

function replay.snapshot(log)
  return deep_copy(log)
end

function replay.replay_commands(initial_state, log, execute_fn)
  local results = {}
  for i, entry in ipairs(log.entries or {}) do
    local command = entry.command
    local result = execute_fn(initial_state, command)
    results[#results + 1] = result
    if not result.ok then
      return {
        ok = false,
        failed_at = i,
        reason = result.reason,
        results = results,
      }
    end
  end
  return {
    ok = true,
    failed_at = nil,
    reason = "ok",
    results = results,
  }
end

return replay
