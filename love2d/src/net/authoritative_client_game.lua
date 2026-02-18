-- Client-side authoritative game adapter.
--
-- Bridges `client_session` command submission to an authoritative host by
-- pulling snapshots after accepted commands.

local adapter = {}
adapter.__index = adapter

local function fail(reason, meta)
  return { ok = false, reason = reason, meta = meta or {} }
end

local function ok(meta)
  return { ok = true, reason = "ok", meta = meta or {} }
end

local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deep_copy(v)
  end
  return out
end

function adapter.new(opts)
  opts = opts or {}
  return setmetatable({
    session = opts.session,
    state = nil,
    connected = false,
  }, adapter)
end

function adapter:connect()
  if self.connected then
    return ok({
      player_index = self.session and self.session.player_index,
      match_id = self.session and self.session.match_id,
      checksum = self.session and self.session.last_checksum,
    })
  end

  if not self.session then return fail("missing_session") end

  local connected = self.session:connect()
  if not connected.ok then
    return fail(connected.reason, connected.meta)
  end

  local snap = self:sync_snapshot()
  if not snap.ok then
    return fail("connect_snapshot_failed", {
      connect_reason = connected.reason,
      snapshot_reason = snap.reason,
    })
  end

  self.connected = true
  return ok({
    player_index = connected.meta.player_index,
    match_id = connected.meta.match_id,
    checksum = snap.meta.checksum,
  })
end

function adapter:reconnect()
  if not self.session then return fail("missing_session") end

  local reconnected = self.session:reconnect()
  if not reconnected.ok then
    return fail(reconnected.reason, reconnected.meta)
  end

  local snap = self:sync_snapshot()
  if not snap.ok then
    return fail("reconnect_snapshot_failed", {
      reconnect_reason = reconnected.reason,
      snapshot_reason = snap.reason,
    })
  end

  self.connected = true
  return ok({
    player_index = reconnected.meta.player_index,
    match_id = reconnected.meta.match_id,
    checksum = snap.meta.checksum,
  })
end

function adapter:sync_snapshot()
  if not self.session then return fail("missing_session") end
  local snap = self.session:request_snapshot()
  if not snap.ok then
    return fail(snap.reason, snap.meta)
  end

  self.state = deep_copy(snap.meta and snap.meta.state or nil)
  if not self.state then
    return fail("missing_snapshot_state")
  end

  return ok({
    checksum = snap.meta.checksum,
    active_player = snap.meta.active_player,
    turn_number = snap.meta.turn_number,
  })
end

function adapter:submit(command)
  if not self.session then return fail("missing_session") end
  if not self.connected then return fail("not_connected") end

  local submitted = self.session:submit_with_resync(command)
  if not submitted.ok and submitted.reason ~= "resynced_retry_required" then
    return fail(submitted.reason, submitted.meta)
  end

  if submitted.reason == "resynced_retry_required" then
    return fail(submitted.reason, submitted.meta)
  end

  -- Use state from submit response if available (avoids a second round-trip)
  if submitted.meta and submitted.meta.state then
    self.state = deep_copy(submitted.meta.state)
    return ok({
      checksum = submitted.meta.checksum,
      active_player = submitted.meta.active_player,
      turn_number = submitted.meta.turn_number,
    })
  end

  -- Fallback: fetch snapshot separately
  local snap = self:sync_snapshot()
  if not snap.ok then
    return fail("post_submit_snapshot_failed", {
      submit_reason = submitted.reason,
      snapshot_reason = snap.reason,
    })
  end

  return ok({
    checksum = snap.meta.checksum,
    active_player = snap.meta.active_player,
    turn_number = snap.meta.turn_number,
  })
end

function adapter:get_state()
  return deep_copy(self.state)
end

return adapter
