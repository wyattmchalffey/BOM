-- Threaded relay connection: runs websocket I/O in a love.thread
-- so the main thread never blocks on connect or receive.
--
-- Usage:
--   local relay = threaded_relay.start(relay_url)
--   -- In update():
--   relay:poll()  -- check connection status, pump messages
--   if relay.state == "connected" then ... end
--   if relay.state == "error" then ... relay.error_msg ... end

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

local args_ch   = love.thread.getChannel("relay_args")
local result_ch  = love.thread.getChannel("relay_result")
local inbox_ch   = love.thread.getChannel("relay_inbox")
local outbox_ch  = love.thread.getChannel("relay_outbox")
local quit_ch    = love.thread.getChannel("relay_quit")

local relay_url = args_ch:demand()
local host_name = args_ch:demand(1) or "Player"

-- Simple URL-encode for the name parameter
local function url_encode(str)
    return str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

-- Append /host?name=... if needed
if not relay_url:match("/host") then
    if relay_url:sub(-1) == "/" then
        relay_url = relay_url .. "host"
    else
        relay_url = relay_url .. "/host"
    end
end
relay_url = relay_url .. "?name=" .. url_encode(host_name)

-- Load websocket
local ok_ws, websocket = pcall(require, "websocket")
if not ok_ws then
    result_ch:push("error:websocket module not found: " .. tostring(websocket))
    return
end

local ok_sync, sync_new = pcall(function()
    return websocket.client.sync
end)
if not ok_sync or not sync_new then
    result_ch:push("error:websocket.client.sync not available")
    return
end

local ssl_params = {
    mode = "client",
    protocol = "any",
    options = {"all", "no_sslv2", "no_sslv3", "no_tlsv1"},
    verify = "none",
}

-- Connect
local conn = sync_new()
local ok_connect, err = conn:connect(relay_url, nil, ssl_params)
if not ok_connect then
    result_ch:push("error:connect failed: " .. tostring(err))
    return
end

-- Read room_created (blocking, but we're in a thread so it's fine)
local first_frame = conn:receive()
if not first_frame then
    result_ch:push("error:no response from relay")
    return
end

-- Parse room_created
local room_code = first_frame:match('"room"%s*:%s*"([^"]+)"')
local msg_type = first_frame:match('"type"%s*:%s*"([^"]+)"')
if msg_type ~= "room_created" or not room_code then
    result_ch:push("error:unexpected response: " .. tostring(first_frame))
    return
end

result_ch:push("ok:" .. room_code)

-- Bridge loop: forward between websocket and channels
-- Use socket.select to avoid blocking receive when raw socket is available
local socket = require("socket")
local raw_sock = conn.sock

-- If no raw socket available, fall back to short-timeout blocking receive
local use_select = raw_sock ~= nil
if use_select then
    -- Verify select works with this socket
    local sel_ok, sel_err = pcall(socket.select, {raw_sock}, nil, 0)
    if not sel_ok then
        use_select = false
    end
end

while true do
    -- Check quit signal
    if quit_ch:pop() then break end

    -- Send any outgoing frames first
    while true do
        local outgoing = outbox_ch:pop()
        if not outgoing then break end
        local ok_send, send_err = pcall(function() conn:send(outgoing) end)
        if not ok_send then
            result_ch:push("error:send failed: " .. tostring(send_err))
            return
        end
    end

    if use_select then
        -- Check if data available on socket (non-blocking)
        local readable, _, sel_err = socket.select({raw_sock}, nil, 0.05)
        if readable and #readable > 0 then
            local ok_recv, frame_or_err, opcode = pcall(function() return conn:receive() end)
            if ok_recv and frame_or_err then
                inbox_ch:push(frame_or_err)
            elseif not ok_recv then
                result_ch:push("error:receive failed: " .. tostring(frame_or_err))
                return
            end
        end
    else
        -- Fallback: brief sleep then try non-blocking receive via settimeout
        if conn.sock and conn.sock.settimeout then
            conn.sock:settimeout(0.05)
        end
        local ok_recv, frame_or_err = pcall(function() return conn:receive() end)
        if ok_recv and frame_or_err then
            inbox_ch:push(frame_or_err)
        elseif not ok_recv and not tostring(frame_or_err):find("timeout") then
            result_ch:push("error:receive failed: " .. tostring(frame_or_err))
            return
        else
            -- No data or timeout, just sleep briefly
            love.timer.sleep(0.05)
        end
    end
end

pcall(function() conn:close() end)
]]

local threaded_relay = {}
threaded_relay.__index = threaded_relay

-- Relay control message types
local RELAY_TYPES = {
    room_created = true,
    peer_joined = true,
    peer_disconnected = true,
    joined = true,
    error = true,
}

local function is_relay_control(frame)
    local ok, msg = pcall(json.decode, frame)
    if not ok or type(msg) ~= "table" then return false, nil end
    if msg.type and RELAY_TYPES[msg.type] then
        return true, msg
    end
    return false, nil
end

function threaded_relay.start(relay_url, host_name)
    local self = setmetatable({
        state = "connecting",   -- "connecting" | "connected" | "error"
        room_code = nil,
        error_msg = nil,
        peer_joined = false,
        _thread = nil,
        _args_ch = love.thread.getChannel("relay_args"),
        _result_ch = love.thread.getChannel("relay_result"),
        _inbox_ch = love.thread.getChannel("relay_inbox"),
        _outbox_ch = love.thread.getChannel("relay_outbox"),
        _quit_ch = love.thread.getChannel("relay_quit"),
        _service = nil,
    }, threaded_relay)

    -- Clear channels from any previous use
    self._args_ch:clear()
    self._result_ch:clear()
    self._inbox_ch:clear()
    self._outbox_ch:clear()
    self._quit_ch:clear()

    -- Start thread
    self._thread = love.thread.newThread(THREAD_CODE)
    self._args_ch:push(relay_url)
    self._args_ch:push(host_name or "Player")
    self._thread:start()

    return self
end

function threaded_relay:attach_service(service)
    self._service = service
end

-- Call from update() to check status and pump messages
function threaded_relay:poll()
    -- Check for connection result
    if self.state == "connecting" then
        local result = self._result_ch:pop()
        if result then
            if result:match("^ok:") then
                self.room_code = result:sub(4)
                self.state = "connected"
            elseif result:match("^error:") then
                self.error_msg = result:sub(7)
                self.state = "error"
            end
        end
        -- Also check thread errors
        local thread_err = self._thread:getError()
        if thread_err then
            self.error_msg = "Thread error: " .. tostring(thread_err)
            self.state = "error"
        end
        return
    end

    if self.state ~= "connected" then return end

    -- Check for async errors
    local result = self._result_ch:pop()
    if result and result:match("^error:") then
        self.error_msg = result:sub(7)
        self.state = "error"
        return
    end

    -- Check thread health
    local thread_err = self._thread:getError()
    if thread_err then
        self.error_msg = "Thread error: " .. tostring(thread_err)
        self.state = "error"
        return
    end

    -- Process incoming frames from the websocket thread
    while true do
        local frame = self._inbox_ch:pop()
        if not frame then break end

        local is_ctrl, ctrl = is_relay_control(frame)
        if is_ctrl then
            if ctrl.type == "peer_joined" then
                self.peer_joined = true
                print("[threaded_relay] peer joined room " .. tostring(self.room_code))
            elseif ctrl.type == "peer_disconnected" then
                self.peer_joined = false
                print("[threaded_relay] peer disconnected")
            elseif ctrl.type == "error" then
                print("[threaded_relay] relay error: " .. tostring(ctrl.message))
            end
        elseif self._service then
            -- Game frame from joiner — handle via host service
            local response = self._service:handle_frame(frame)
            if response then
                self._outbox_ch:push(response)
            end
        end
    end

    -- Flush any pending state pushes (from host's own moves OR joiner frames)
    if self._service then
        local pushes = self._service:pop_pushes()
        for _, push in ipairs(pushes) do
            self._outbox_ch:push(push)
        end
    end
end

function threaded_relay:cleanup()
    self._quit_ch:push(true)
end

return threaded_relay
