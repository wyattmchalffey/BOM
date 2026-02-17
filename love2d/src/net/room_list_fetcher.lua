-- Room list fetcher: uses a love.thread to make blocking HTTP(S) GET
-- requests to the relay's /rooms endpoint without blocking the main thread.
--
-- Usage:
--   local fetcher = room_list_fetcher.new("https://bom-hbfv.onrender.com/rooms")
--   fetcher:refresh()           -- trigger a fetch
--   -- In update(dt):
--   fetcher:poll(dt)            -- checks for results, auto-refreshes
--   -- fetcher.rooms = list of { code, hostName, createdAt }
--   -- fetcher.error = error string or nil
--   -- fetcher.loading = true while a fetch is in progress

local json = require("src.net.json_codec")

local THREAD_CODE = [[
require("love.filesystem")

-- Native DLLs (ssl.dll) sit next to the exe
local exe_dir = love.filesystem.getSourceBaseDirectory():gsub("\\", "/")
package.cpath = package.cpath .. ";" .. exe_dir .. "/?.dll"

local request_ch = love.thread.getChannel("roomlist_request")
local result_ch  = love.thread.getChannel("roomlist_result")
local quit_ch    = love.thread.getChannel("roomlist_quit")

local socket = require("socket")
local ssl = require("ssl")

-- Minimal HTTPS GET using raw socket + ssl (no ssl.https needed)
local function https_get(url)
    local host, path = url:match("^https://([^/]+)(.*)")
    if not host then return nil, "invalid URL" end
    if path == "" then path = "/" end

    local sock = socket.tcp()
    sock:settimeout(10)
    local ok, err = sock:connect(host, 443)
    if not ok then
        sock:close()
        return nil, "connect: " .. tostring(err)
    end

    local wrapped, wrap_err = ssl.wrap(sock, {
        mode = "client",
        protocol = "any",
        verify = "none",
        options = {"all", "no_sslv2", "no_sslv3", "no_tlsv1"},
    })
    if not wrapped then
        sock:close()
        return nil, "ssl wrap: " .. tostring(wrap_err)
    end

    -- Set SNI hostname (required by most modern HTTPS servers)
    if wrapped.sni then
        wrapped:sni(host)
    end

    local hs_ok, hs_err = wrapped:dohandshake()
    if not hs_ok then
        wrapped:close()
        return nil, "ssl handshake: " .. tostring(hs_err)
    end

    wrapped:send(
        "GET " .. path .. " HTTP/1.1\r\n" ..
        "Host: " .. host .. "\r\n" ..
        "Connection: close\r\n" ..
        "Accept: application/json\r\n\r\n"
    )

    local chunks = {}
    while true do
        local data, read_err, partial = wrapped:receive("*a")
        if data then
            table.insert(chunks, data)
        elseif partial and #partial > 0 then
            table.insert(chunks, partial)
        end
        if read_err == "closed" or (read_err and read_err ~= "timeout") then
            break
        end
    end
    wrapped:close()

    local response = table.concat(chunks)
    -- Parse status line
    local status_code = tonumber(response:match("^HTTP/%d%.%d (%d+)"))
    -- Split headers and body
    local header_block, raw_body = response:match("^(.-)\r\n\r\n(.*)")
    if not raw_body then return nil, "malformed response" end

    -- Decode chunked transfer encoding if present
    if header_block:lower():find("transfer%-encoding:%s*chunked") then
        local decoded = {}
        local pos = 1
        while pos <= #raw_body do
            local hex_end = raw_body:find("\r\n", pos)
            if not hex_end then break end
            local chunk_size = tonumber(raw_body:sub(pos, hex_end - 1), 16)
            if not chunk_size or chunk_size == 0 then break end
            local chunk_data = raw_body:sub(hex_end + 2, hex_end + 1 + chunk_size)
            table.insert(decoded, chunk_data)
            pos = hex_end + 2 + chunk_size + 2  -- skip data + trailing \r\n
        end
        raw_body = table.concat(decoded)
    end

    return raw_body, nil, status_code
end

while true do
    -- Wait for a request (blocks until one arrives or check quit)
    local url = request_ch:demand(0.5)

    if quit_ch:pop() then break end

    if url and url ~= "" then
        local body, err, status_code = https_get(url)
        if err then
            result_ch:push('{"error":' .. string.format("%q", err) .. '}')
        elseif status_code ~= 200 then
            result_ch:push('{"error":"HTTP ' .. tostring(status_code) .. '"}')
        elseif body then
            result_ch:push(body)
        else
            result_ch:push('{"error":"empty response"}')
        end
    end

    if quit_ch:pop() then break end
end
]]

local room_list_fetcher = {}
room_list_fetcher.__index = room_list_fetcher

local AUTO_REFRESH_INTERVAL = 3.0

function room_list_fetcher.new(url)
    local self = setmetatable({
        url = url,
        rooms = {},
        error = nil,
        loading = false,
        _thread = nil,
        _request_ch = love.thread.getChannel("roomlist_request"),
        _result_ch = love.thread.getChannel("roomlist_result"),
        _quit_ch = love.thread.getChannel("roomlist_quit"),
        _refresh_timer = AUTO_REFRESH_INTERVAL, -- trigger immediate first fetch
    }, room_list_fetcher)

    -- Clear channels
    self._request_ch:clear()
    self._result_ch:clear()
    self._quit_ch:clear()

    -- Start background thread
    self._thread = love.thread.newThread(THREAD_CODE)
    self._thread:start()

    return self
end

function room_list_fetcher:refresh()
    self._request_ch:push(self.url)
    self.loading = true
end

function room_list_fetcher:poll(dt)
    -- Auto-refresh timer
    self._refresh_timer = self._refresh_timer + dt
    if self._refresh_timer >= AUTO_REFRESH_INTERVAL then
        self._refresh_timer = 0
        self:refresh()
    end

    -- Check for results
    local result_json = self._result_ch:pop()
    if result_json then
        self.loading = false
        local ok, decoded = pcall(json.decode, result_json)
        if ok and type(decoded) == "table" then
            if decoded.error then
                self.error = decoded.error
            else
                self.rooms = decoded
                self.error = nil
            end
        else
            self.error = "Failed to parse room list"
        end
    end

    -- Check thread health
    if self._thread then
        local thread_err = self._thread:getError()
        if thread_err then
            self.error = "Thread error: " .. tostring(thread_err)
            self.loading = false
        end
    end
end

function room_list_fetcher:cleanup()
    self._quit_ch:push(true)
    -- Push a dummy request to unblock demand()
    self._request_ch:push("")
end

return room_list_fetcher
