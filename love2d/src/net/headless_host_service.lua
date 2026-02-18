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
    host_player = opts.host_player,
    rules_version = opts.rules_version,
    content_version = opts.content_version,
    max_players = opts.max_players,
  })

  return setmetatable({
    _host = host,
    gateway = host_gateway.new(host),
    _pending_pushes = {},
  }, service)
end

function service:is_game_started()
  return self._host.game_started
end

function service:get_host_session_token()
  return self._host._host_session_token
end

function service:get_match_id()
  return self._host.match_id
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

  -- Queue a state push after successful submit
  if response and response.ok and request.op == "submit" then
    local push_msg = self._host:generate_state_push()
    if push_msg then
      local ok_push_encode, push_frame = pcall(json.encode, push_msg)
      if ok_push_encode then
        self._pending_pushes[#self._pending_pushes + 1] = push_frame
      end
    end
  end

  local ok_encode, out = pcall(json.encode, response)
  if not ok_encode then
    return safe_error("service_encode_failure", { error_message = tostring(out) })
  end

  return out
end

function service:pop_pushes()
  local pushes = self._pending_pushes
  self._pending_pushes = {}
  return pushes
end

return service
