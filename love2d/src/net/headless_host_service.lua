-- Headless host service boundary.
--
-- Accepts framed JSON requests and returns framed JSON responses.
-- This provides a process/network-friendly interface around host+gateway.

local host_mod = require("src.net.host")
local host_gateway = require("src.net.host_gateway")
local json = require("src.net.json_codec")

local service = {}
service.__index = service

local function safe_error(reason, meta)
  return json.encode({ ok = false, reason = reason, meta = meta or {} })
end

function service.new(opts)
  opts = opts or {}
  local host = host_mod.new({
    match_id = opts.match_id,
    setup = opts.setup,
    rules_version = opts.rules_version,
    content_version = opts.content_version,
    max_players = opts.max_players,
  })

  return setmetatable({
    gateway = host_gateway.new(host),
  }, service)
end

function service:handle_frame(frame)
  local ok_decode, request = pcall(json.decode, frame)
  if not ok_decode then
    return safe_error("invalid_json_frame", { error_message = tostring(request) })
  end

  local ok_route, response = pcall(self.gateway.handle, self.gateway, request)
  if not ok_route then
    return safe_error("service_gateway_failure", { error_message = tostring(response) })
  end

  local ok_encode, out = pcall(json.encode, response)
  if not ok_encode then
    return safe_error("service_encode_failure", { error_message = tostring(out) })
  end

  return out
end

return service
