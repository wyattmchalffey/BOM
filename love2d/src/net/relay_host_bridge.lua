-- Relay host bridge: connects the headless host service to a relay server
-- as an outbound websocket client. The relay pairs host and joiner by room code;
-- this bridge forwards game frames between the relay (joiner) and the local
-- headless host service.
--
-- relay_host_bridge.connect(opts) -> { ok, room_code, step_fn, cleanup_fn, reason }

local websocket_provider = require("src.net.websocket_provider")
local json = require("src.net.json_codec")

local relay_host_bridge = {}

-- Relay control message types (not game frames)
local RELAY_TYPES = {
  room_created = true,
  peer_joined = true,
  peer_disconnected = true,
  joined = true,
  error = true,
}

local function is_relay_control(frame)
  -- Quick check: relay control messages are JSON with a "type" field
  -- whose value is one of the known relay types.
  local ok, msg = pcall(json.decode, frame)
  if not ok or type(msg) ~= "table" then return false, nil end
  if msg.type and RELAY_TYPES[msg.type] then
    return true, msg
  end
  return false, nil
end

function relay_host_bridge.connect(opts)
  opts = opts or {}
  assert(opts.relay_url, "relay_host_bridge requires relay_url")
  assert(opts.service, "relay_host_bridge requires headless host service")

  local relay_url = opts.relay_url
  -- Ensure the URL ends with /host
  if not relay_url:match("/host$") then
    if relay_url:sub(-1) == "/" then
      relay_url = relay_url .. "host"
    else
      relay_url = relay_url .. "/host"
    end
  end

  -- Resolve websocket provider
  local resolved = websocket_provider.resolve(opts)
  if not resolved.ok then
    return { ok = false, reason = "websocket_unavailable: " .. tostring(resolved.reason) }
  end

  -- Connect to relay
  local ok_connect, conn = pcall(resolved.provider.connect, relay_url, {})
  if not ok_connect or not conn then
    return { ok = false, reason = "relay_connect_failed: " .. tostring(conn) }
  end

  -- Read the first message: should be room_created
  local first_frame = conn:receive(5000)
  if not first_frame then
    return { ok = false, reason = "relay_no_room_code" }
  end

  local is_ctrl, ctrl_msg = is_relay_control(first_frame)
  if not is_ctrl or ctrl_msg.type ~= "room_created" then
    return { ok = false, reason = "relay_unexpected_response: " .. tostring(first_frame) }
  end

  local room_code = ctrl_msg.room
  local service = opts.service
  local connected = true
  local peer_joined = false

  -- Non-blocking poll: check for incoming frames from relay
  local function step_fn()
    if not connected then return end

    -- Poll with 0 timeout (non-blocking)
    local frame = conn:receive(0)
    if not frame then return end

    local is_ctrl2, ctrl2 = is_relay_control(frame)
    if is_ctrl2 then
      if ctrl2.type == "peer_joined" then
        peer_joined = true
        print("[relay_host_bridge] peer joined room " .. room_code)
      elseif ctrl2.type == "peer_disconnected" then
        print("[relay_host_bridge] peer disconnected from room " .. room_code)
        peer_joined = false
      elseif ctrl2.type == "error" then
        print("[relay_host_bridge] relay error: " .. tostring(ctrl2.message))
        connected = false
      end
      return
    end

    -- Game frame from joiner — handle via headless host service
    local response = service:handle_frame(frame)
    if response and connected then
      pcall(conn.send, conn, response)
    end
  end

  local function cleanup_fn()
    connected = false
    pcall(conn.send, conn, "")  -- trigger close
    -- The websocket library may have a close method
    if conn.close then
      pcall(conn.close, conn)
    end
  end

  return {
    ok = true,
    room_code = room_code,
    step_fn = step_fn,
    cleanup_fn = cleanup_fn,
  }
end

return relay_host_bridge
