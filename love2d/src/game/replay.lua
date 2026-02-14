-- Replay and command-log helpers for deterministic simulation workflows.
--
-- This module intentionally has no Love2D dependencies so it can be shared
-- between client and future headless host processes.

local replay = {}

replay.FORMAT_VERSION = 1

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
    entries = {},
  }
end

function replay.append(log, command, result, game_state)
  local entries = log.entries
  entries[#entries + 1] = {
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
  return entries[#entries]
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
