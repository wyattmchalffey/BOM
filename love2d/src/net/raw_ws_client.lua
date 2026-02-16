-- Minimal ws:// websocket client used as a fallback when the external websocket
-- module fails due to strict/case-sensitive handshake checks.
--
-- Supports text frames only (sufficient for relay traffic).

local raw_ws_client = {}


local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parse_ws_url(url)
  local host_port, path = url:match("^ws://([^/]+)(/.*)$")
  if not host_port then
    host_port = url:match("^ws://([^/]+)$")
    path = "/"
  end
  if not host_port then
    return nil, "unsupported_url"
  end

  local host, port = host_port:match("^%[([^%]]+)%]:(%d+)$")
  if not host then
    host, port = host_port:match("^([^:]+):(%d+)$")
  end
  if not host then
    host = host_port
    port = "80"
  end

  return {
    host = host,
    port = tonumber(port) or 80,
    path = path,
  }
end

local function pick_bxor()
  local ok_bit, bit = pcall(require, "bit")
  if ok_bit and bit and bit.bxor then return bit.bxor end
  local ok_bit32, bit32 = pcall(require, "bit32")
  if ok_bit32 and bit32 and bit32.bxor then return bit32.bxor end

  return function(a, b)
    local out, bitv = 0, 1
    while a > 0 or b > 0 do
      local aa = a % 2
      local bb = b % 2
      if aa ~= bb then out = out + bitv end
      a = math.floor(a / 2)
      b = math.floor(b / 2)
      bitv = bitv * 2
    end
    return out
  end
end

local bxor = pick_bxor()

local function random_bytes(n)
  local t = {}
  for i = 1, n do
    t[i] = string.char(math.random(0, 255))
  end
  return table.concat(t)
end

local function mask_payload(payload, mask)
  local out = {}
  for i = 1, #payload do
    local p = payload:byte(i)
    local m = mask:byte(((i - 1) % 4) + 1)
    out[i] = string.char(bxor(p, m))
  end
  return table.concat(out)
end

local function encode_client_text_frame(text)
  local payload = tostring(text or "")
  local len = #payload
  local mask = random_bytes(4)

  local first = string.char(0x81) -- FIN + text opcode
  local second
  local ext = ""

  if len < 126 then
    second = string.char(0x80 + len)
  elseif len < 65536 then
    second = string.char(0x80 + 126)
    local hi = math.floor(len / 256)
    local lo = len % 256
    ext = string.char(hi, lo)
  else
    second = string.char(0x80 + 127)
    local n = len
    local bytes = {}
    for i = 8, 1, -1 do
      bytes[i] = string.char(n % 256)
      n = math.floor(n / 256)
    end
    ext = table.concat(bytes)
  end

  return first .. second .. ext .. mask .. mask_payload(payload, mask)
end

local function decode_server_frame(sock)
  local b1 = sock:receive(1)
  if not b1 then return nil end
  local b2 = sock:receive(1)
  if not b2 then return nil end

  local v1 = b1:byte(1)
  local v2 = b2:byte(1)

  local opcode = v1 % 16
  local masked = v2 >= 128
  local len = v2 % 128

  if len == 126 then
    local ext = sock:receive(2)
    if not ext then return nil end
    len = ext:byte(1) * 256 + ext:byte(2)
  elseif len == 127 then
    local ext = sock:receive(8)
    if not ext then return nil end
    len = 0
    for i = 1, 8 do len = len * 256 + ext:byte(i) end
  end

  local mask = nil
  if masked then
    mask = sock:receive(4)
    if not mask then return nil end
  end

  local payload = len > 0 and sock:receive(len) or ""
  if not payload then return nil end

  if masked and mask then
    payload = mask_payload(payload, mask)
  end

  -- Close frame
  if opcode == 0x8 then
    return nil
  end

  -- Ping frame -> ignore, caller may poll again
  if opcode == 0x9 then
    return ""
  end

  -- Text/binary are passed through as raw payload
  return payload
end

function raw_ws_client.connect(url, opts)
  opts = opts or {}
  local parsed, parse_err = parse_ws_url(url)
  if not parsed then
    return nil, parse_err
  end

  local ok_socket, socket = pcall(require, "socket")
  if not ok_socket or not socket then
    return nil, "socket_module_not_found"
  end

  local ok_mime, mime = pcall(require, "mime")
  if not ok_mime or not mime then
    return nil, "mime_module_not_found"
  end

  local timeout_s = (opts.timeout_ms and (opts.timeout_ms / 1000)) or 5
  local tcp, create_err = socket.tcp()
  if not tcp then
    return nil, create_err or "tcp_create_failed"
  end

  tcp:settimeout(timeout_s)
  local ok_conn, conn_err = tcp:connect(parsed.host, parsed.port)
  if not ok_conn then
    return nil, conn_err or "tcp_connect_failed"
  end

  local key = mime.b64(random_bytes(16))
  local req = table.concat({
    "GET " .. parsed.path .. " HTTP/1.1",
    "Host: " .. parsed.host .. ":" .. tostring(parsed.port),
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Version: 13",
    "Sec-WebSocket-Key: " .. key,
    "",
    "",
  }, "\r\n")

  local ok_send, send_err = tcp:send(req)
  if not ok_send then
    return nil, send_err or "handshake_send_failed"
  end

  local status_line = tcp:receive("*l")
  if not status_line then
    return nil, "handshake_no_status"
  end
  if not status_line:match("^HTTP/%d%.%d%s+101") then
    return nil, "handshake_rejected: " .. tostring(status_line)
  end

  -- Drain headers; we intentionally do not enforce exact accept-header casing.
  while true do
    local line = tcp:receive("*l")
    if not line then return nil, "handshake_incomplete" end
    line = trim(line)
    if line == "" then break end
  end

  local conn = {}

  function conn:send(message)
    local frame = encode_client_text_frame(message)
    local ok, err = tcp:send(frame)
    if not ok then return nil, err end
    return true
  end

  function conn:receive(timeout_ms)
    local timeout_s2 = timeout_ms and (timeout_ms / 1000) or 0
    if timeout_s2 < 0 then timeout_s2 = 0 end
    tcp:settimeout(timeout_s2)
    local payload, err = decode_server_frame(tcp)
    if payload == nil then
      if err == "timeout" then
        return nil
      end
      return nil
    end
    if payload == "" then
      return nil
    end
    return payload
  end

  function conn:close()
    pcall(tcp.close, tcp)
  end

  return conn
end

return raw_ws_client
