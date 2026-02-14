-- Runtime multiplayer wiring helpers.
--
-- Builds an authoritative client adapter for either:
-- - websocket transport (remote host)
-- - in-process headless host service (local host boundary)

local authoritative_client_game = require("src.net.authoritative_client_game")
local client_session = require("src.net.client_session")
local websocket_transport = require("src.net.websocket_transport")
local websocket_client = require("src.net.websocket_client")
local headless_host_service = require("src.net.headless_host_service")
local json = require("src.net.json_codec")

local runtime_multiplayer = {}

local function fail(reason, meta)
  return { ok = false, reason = reason, meta = meta or {} }
end

local function ok(adapter)
  return { ok = true, adapter = adapter }
end

local HeadlessFrameClient = {}
HeadlessFrameClient.__index = HeadlessFrameClient

function HeadlessFrameClient.new(service)
  return setmetatable({ service = service, _last = nil }, HeadlessFrameClient)
end

function HeadlessFrameClient:send(frame)
  self._last = frame
end

function HeadlessFrameClient:receive(_timeout_ms)
  return self.service:handle_frame(self._last)
end

function runtime_multiplayer.build(opts)
  opts = opts or {}

  if opts.mode == nil or opts.mode == "" or opts.mode == "off" then
    return fail("multiplayer_disabled")
  end

  local transport
  if opts.mode == "headless" then
    local service = headless_host_service.new({
      match_id = opts.match_id,
      rules_version = opts.rules_version,
      content_version = opts.content_version,
      max_players = opts.max_players,
    })

    transport = websocket_transport.new({
      client = HeadlessFrameClient.new(service),
      encode = json.encode,
      decode = json.decode,
    })
  elseif opts.mode == "websocket" then
    if not opts.websocket_provider then
      return fail("missing_websocket_provider")
    end
    if type(opts.url) ~= "string" or opts.url == "" then
      return fail("missing_websocket_url")
    end

    local socket = websocket_client.new({
      provider = opts.websocket_provider,
      url = opts.url,
      connect_opts = opts.connect_opts,
    })

    transport = websocket_transport.new({
      client = socket,
      encode = json.encode,
      decode = json.decode,
    })
  else
    return fail("unsupported_multiplayer_mode", { mode = opts.mode })
  end

  local session = client_session.new({
    transport = transport,
    player_name = opts.player_name,
  })

  return ok(authoritative_client_game.new({ session = session }))
end

return runtime_multiplayer
