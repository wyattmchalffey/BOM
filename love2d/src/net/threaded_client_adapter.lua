-- Threaded client adapter: runs the entire blocking websocket client stack
-- inside a love.thread so the main thread never blocks on I/O.
--
-- Implements the same interface as authoritative_client_game (connect, submit,
-- sync_snapshot, get_state) but delegates all network I/O to a background thread.
--
-- Usage:
--   local adapter = threaded_client_adapter.start({ url = url, player_name = name })
--   -- In update(): adapter:poll()
--   -- adapter.connected / adapter.connect_error / adapter.state_changed

local json = require("src.net.json_codec")

local THREAD_CODE = [[
require("love.filesystem")
require("love.timer")

-- Custom loader for modules inside the .love archive
local searchers = package.loaders or package.searchers
table.insert(searchers, 2, function(modname)
    local path = modname:gsub("%.", "/") .. ".lua"
    if love.filesystem.getInfo(path) then
        return load(love.filesystem.read(path), "@" .. path)
    end
    path = modname:gsub("%.", "/") .. "/init.lua"
    if love.filesystem.getInfo(path) then
        return load(love.filesystem.read(path), "@" .. path)
    end
end)

-- Native DLLs (ssl.dll) sit next to the exe
local exe_dir = love.filesystem.getSourceBaseDirectory():gsub("\\", "/")
package.cpath = package.cpath .. ";" .. exe_dir .. "/?.dll"

local json = require("src.net.json_codec")
local websocket_transport = require("src.net.websocket_transport")
local client_session = require("src.net.client_session")
local socket = require("socket")

local args_ch     = love.thread.getChannel("tclient_args")
local result_ch   = love.thread.getChannel("tclient_result")
local cmd_ch      = love.thread.getChannel("tclient_cmd")
local response_ch = love.thread.getChannel("tclient_response")
local push_ch     = love.thread.getChannel("tclient_push")
local quit_ch     = love.thread.getChannel("tclient_quit")

-- Read connection args: { url, player_name, faction, deck }
local args_json = args_ch:demand()
local args = json.decode(args_json)
local url = args.url
local player_name = args.player_name or "Player"
local faction = args.faction
local deck = args.deck

-- Create sync websocket client directly (not via provider abstraction)
-- so we have access to the raw socket for non-blocking receives.
local ok_wsmod, websocket = pcall(require, "websocket")
if not ok_wsmod or not websocket or not websocket.client or not websocket.client.sync then
    result_ch:push(json.encode({ ok = false, reason = "websocket module not found" }))
    return
end

local ssl_params = {
    mode = "client",
    protocol = "any",
    options = {"all", "no_sslv2", "no_sslv3", "no_tlsv1"},
    verify = "none",
}

local conn = websocket.client.sync()
local ok_connect, connect_err = conn:connect(url, nil, ssl_params)
if not ok_connect then
    result_ch:push(json.encode({ ok = false, reason = "ws_connect_failed: " .. tostring(connect_err) }))
    return
end

-- Wrap the sync client for the transport layer (send/receive interface)
local ws_client = {
    connection = conn,  -- expose raw sync client (has .sock)
    send = function(self, frame) return conn:send(frame) end,
    receive = function(self, timeout_ms)
        -- The sync client's receive() is blocking and ignores timeout,
        -- so we set the socket timeout before each receive.
        if conn.sock and conn.sock.settimeout then
            conn.sock:settimeout((timeout_ms or 2000) / 1000)
        end
        return conn:receive()
    end,
}

local transport = websocket_transport.new({
    client = ws_client,
    encode = json.encode,
    decode = json.decode,
})

local session = client_session.new({
    transport = transport,
    player_name = player_name,
    faction = faction,
    deck = deck,
})

-- Connect (blocking handshake)
local connect_result = session:connect()
if not connect_result.ok then
    result_ch:push(json.encode({ ok = false, reason = connect_result.reason }))
    return
end

-- Request initial snapshot (blocking)
local snap = session:request_snapshot()
if not snap.ok then
    result_ch:push(json.encode({ ok = false, reason = "snapshot_failed: " .. snap.reason }))
    return
end

-- Push connection success + initial state to main thread
result_ch:push(json.encode({
    ok = true,
    player_index = connect_result.meta.player_index,
    match_id = connect_result.meta.match_id,
    state = snap.meta.state,
    checksum = snap.meta.checksum,
}))

-- Access raw socket for non-blocking receive in push-listening loop
local raw_sock = conn.sock
local use_select = raw_sock ~= nil
if use_select then
    local sel_ok = pcall(socket.select, {raw_sock}, nil, 0)
    if not sel_ok then use_select = false end
end

local fallback_poll_timer = 0
local FALLBACK_POLL_INTERVAL = 5.0

-- Main loop
while true do
    -- Check quit signal
    if quit_ch:pop() then break end

    -- Check for commands from main thread
    local cmd_json = cmd_ch:pop()
    if cmd_json then
        local ok_cmd, cmd_err = pcall(function()
            local cmd = json.decode(cmd_json)
            local submit_result = session:submit_with_resync(cmd)

            if not submit_result.ok and submit_result.reason == "resynced_retry_required" then
                submit_result = session:submit_with_resync(cmd)
            end

            response_ch:push(json.encode({
                ok = submit_result.ok,
                reason = submit_result.reason,
                checksum = submit_result.meta and submit_result.meta.checksum,
            }))
        end)
        if not ok_cmd then
            result_ch:push(json.encode({ ok = false, reason = "receive_error: " .. tostring(cmd_err) }))
            return
        end
        fallback_poll_timer = 0
    end

    -- Try to receive unsolicited messages (state_push) from server
    local received_push = false
    if use_select then
        local ok_sel, readable_or_err = pcall(function()
            return socket.select({raw_sock}, nil, 0.05)
        end)
        if not ok_sel then
            result_ch:push(json.encode({ ok = false, reason = "receive_error: select failed - " .. tostring(readable_or_err) }))
            return
        end
        local readable = readable_or_err
        if readable and #readable > 0 then
            if raw_sock.settimeout then raw_sock:settimeout(0.1) end
            local ok_recv, frame_or_err = pcall(function() return conn:receive() end)
            if ok_recv and frame_or_err then
                local ok_dec, decoded = pcall(json.decode, frame_or_err)
                if ok_dec and type(decoded) == "table" and decoded.type == "state_push" then
                    push_ch:push(frame_or_err)
                    received_push = true
                end
            elseif not ok_recv and not tostring(frame_or_err):find("timeout") then
                result_ch:push(json.encode({ ok = false, reason = "receive_error: " .. tostring(frame_or_err) }))
                return
            end
        end
    else
        if raw_sock and raw_sock.settimeout then
            raw_sock:settimeout(0.05)
        end
        local ok_recv, frame_or_err = pcall(function() return conn:receive() end)
        if ok_recv and frame_or_err then
            local ok_dec, decoded = pcall(json.decode, frame_or_err)
            if ok_dec and type(decoded) == "table" and decoded.type == "state_push" then
                push_ch:push(frame_or_err)
                received_push = true
            end
        elseif not ok_recv and not tostring(frame_or_err):find("timeout") then
            result_ch:push(json.encode({ ok = false, reason = "receive_error: " .. tostring(frame_or_err) }))
            return
        else
            love.timer.sleep(0.05)
        end
    end

    -- Fallback snapshot poll every 5s if no pushes received
    if not received_push then
        fallback_poll_timer = fallback_poll_timer + 0.05
        if fallback_poll_timer >= FALLBACK_POLL_INTERVAL then
            fallback_poll_timer = 0
            local ok_snap, poll_snap = pcall(function() return session:request_snapshot() end)
            if ok_snap and poll_snap.ok and poll_snap.meta and poll_snap.meta.state then
                push_ch:push(json.encode({
                    type = "state_push",
                    payload = {
                        state = poll_snap.meta.state,
                        checksum = poll_snap.meta.checksum,
                        active_player = poll_snap.meta.active_player,
                        turn_number = poll_snap.meta.turn_number,
                    },
                }))
            elseif not ok_snap then
                result_ch:push(json.encode({ ok = false, reason = "receive_error: snapshot failed - " .. tostring(poll_snap) }))
                return
            end
        end
    else
        fallback_poll_timer = 0
    end
end

-- Cleanup
pcall(function()
    if conn.close then conn:close() end
end)
]]

local threaded_client_adapter = {}
threaded_client_adapter.__index = threaded_client_adapter

local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deep_copy(v)
  end
  return out
end

function threaded_client_adapter.start(opts)
  opts = opts or {}
  assert(type(opts.url) == "string" and opts.url ~= "", "threaded_client_adapter requires url")

  local self = setmetatable({
    -- Public state
    connected = false,
    connect_error = nil,
    state_changed = false,
    local_player_index = nil,
    match_id = nil,

    -- Internal
    _state = nil,
    _checksum = nil,
    _thread = nil,
    _args_ch = love.thread.getChannel("tclient_args"),
    _result_ch = love.thread.getChannel("tclient_result"),
    _cmd_ch = love.thread.getChannel("tclient_cmd"),
    _response_ch = love.thread.getChannel("tclient_response"),
    _push_ch = love.thread.getChannel("tclient_push"),
    _quit_ch = love.thread.getChannel("tclient_quit"),
  }, threaded_client_adapter)

  -- Clear channels from any previous use
  self._args_ch:clear()
  self._result_ch:clear()
  self._cmd_ch:clear()
  self._response_ch:clear()
  self._push_ch:clear()
  self._quit_ch:clear()

  -- Start thread
  self._thread = love.thread.newThread(THREAD_CODE)
  self._args_ch:push(json.encode({
    url = opts.url,
    player_name = opts.player_name or "Player",
    faction = opts.faction,
    deck = opts.deck,
  }))
  self._thread:start()

  return self
end

-- Call from update() every frame to drain push and result channels (non-blocking)
function threaded_client_adapter:poll()
  -- Check for connection result
  if not self.connected and not self.connect_error then
    local result_json = self._result_ch:pop()
    if result_json then
      local ok_dec, result = pcall(json.decode, result_json)
      if ok_dec and result.ok then
        self.connected = true
        self.local_player_index = result.player_index
        self.match_id = result.match_id
        self._state = result.state
        self._checksum = result.checksum
        self.state_changed = true
      elseif ok_dec then
        self.connect_error = result.reason or "unknown_error"
      else
        self.connect_error = "decode_error"
      end
    end

    -- Check thread errors
    if self._thread then
      local thread_err = self._thread:getError()
      if thread_err then
        self.connect_error = "Thread error: " .. tostring(thread_err)
      end
    end
  end

  -- Drain push channel (state updates from server)
  while true do
    local push_json = self._push_ch:pop()
    if not push_json then break end

    local ok_dec, push = pcall(json.decode, push_json)
    if ok_dec and push.type == "state_push" and push.payload then
      if push.payload.state then
        self._state = push.payload.state
        self._checksum = push.payload.checksum
        self.state_changed = true
      end
    end
  end

  -- Drain response channel (submit results arrive here asynchronously)
  if self.connected then
    while true do
      local resp_json = self._response_ch:pop()
      if not resp_json then break end

      local ok_dec, resp = pcall(json.decode, resp_json)
      if ok_dec then
        -- Update state from successful submit response
        if resp.state then
          self._state = resp.state
          self._checksum = resp.checksum
          self.state_changed = true
        end
        if not resp.ok then
          print("[threaded_client_adapter] submit error: " .. tostring(resp.reason))
        end
      end
    end
  end

  -- Check for async errors from the thread and detect disconnection
  if self.connected then
    local err_json = self._result_ch:pop()
    if err_json then
      local ok_dec, err_msg = pcall(json.decode, err_json)
      if ok_dec and not err_msg.ok then
        print("[threaded_client_adapter] async error: " .. tostring(err_msg.reason))
        -- Receive errors mean the connection is dead
        if tostring(err_msg.reason):find("receive_error") then
          self.connected = false
          self._disconnected = true
          print("[threaded_client_adapter] connection lost, marking disconnected")
        end
      end
    end

    if self._thread then
      local thread_err = self._thread:getError()
      if thread_err then
        print("[threaded_client_adapter] thread error: " .. tostring(thread_err))
        self.connected = false
        self._disconnected = true
      end
      -- If the thread has stopped running, the connection is dead
      if not self._thread:isRunning() and not self._disconnected then
        print("[threaded_client_adapter] thread stopped, marking disconnected")
        self.connected = false
        self._disconnected = true
      end
    end
  end
end

-- Returns cached connection result (call after poll() shows connected == true)
function threaded_client_adapter:connect()
  if self.connected then
    return {
      ok = true,
      reason = "ok",
      meta = {
        player_index = self.local_player_index,
        match_id = self.match_id,
        checksum = self._checksum,
      },
    }
  end
  return {
    ok = false,
    reason = self.connect_error or "not_connected_yet",
    meta = {},
  }
end

-- Submit a command: non-blocking, pushes to cmd channel and returns immediately.
-- The actual state update arrives via state_push through poll().
function threaded_client_adapter:submit(command)
  if not self.connected then
    return { ok = false, reason = "not_connected", meta = {} }
  end

  self._cmd_ch:push(json.encode(command))

  -- Return optimistic success; real state arrives via state_push
  return { ok = true, reason = "ok", meta = { checksum = self._checksum } }
end

-- No-op for threaded adapter: state is kept fresh via pushes
function threaded_client_adapter:sync_snapshot()
  return { ok = true, reason = "ok", meta = { checksum = self._checksum } }
end

-- Return deep copy of cached state
function threaded_client_adapter:get_state()
  return deep_copy(self._state)
end

-- Reconnect stub (thread handles connection lifecycle)
function threaded_client_adapter:reconnect()
  return { ok = false, reason = "threaded_reconnect_not_supported", meta = {} }
end

-- Shutdown the background thread
function threaded_client_adapter:cleanup()
  self._quit_ch:push(true)
end

return threaded_client_adapter
