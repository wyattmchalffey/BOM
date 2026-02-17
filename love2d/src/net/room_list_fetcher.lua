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

local request_ch = love.thread.getChannel("roomlist_request")
local result_ch  = love.thread.getChannel("roomlist_result")
local quit_ch    = love.thread.getChannel("roomlist_quit")

-- We need https support
local ok_https, https = pcall(require, "ssl.https")
if not ok_https then
    -- Try luasec directly
    ok_https, https = pcall(function()
        local ssl = require("ssl")
        return require("ssl.https")
    end)
end

-- Fallback to plain http if https not available
local ok_http, http = pcall(require, "socket.http")
local ltn12 = require("ltn12")

while true do
    -- Wait for a request (blocks until one arrives or check quit)
    local url = request_ch:demand(0.5)

    if quit_ch:pop() then break end

    if url then
        local chunks = {}
        local ok, status_code, headers
        if url:match("^https://") and ok_https then
            ok, status_code, headers = https.request({
                url = url,
                sink = ltn12.sink.table(chunks),
                protocol = "any",
                options = {"all", "no_sslv2", "no_sslv3", "no_tlsv1"},
                verify = "none",
            })
        elseif ok_http then
            ok, status_code, headers = http.request({
                url = url,
                sink = ltn12.sink.table(chunks),
            })
        else
            result_ch:push('{"error":"no http library available"}')
            goto continue
        end

        if not ok then
            result_ch:push('{"error":' .. ("%q"):format(tostring(status_code)) .. '}')
        elseif status_code ~= 200 then
            result_ch:push('{"error":"HTTP ' .. tostring(status_code) .. '"}')
        else
            local body = table.concat(chunks)
            result_ch:push(body)
        end

        ::continue::
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
