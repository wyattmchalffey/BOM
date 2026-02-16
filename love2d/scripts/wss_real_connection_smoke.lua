-- Real wss:// connection smoke test against Render relay server.
-- Run from repo root:
--   lua love2d/scripts/wss_real_connection_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  "C:/Program Files (x86)/Lua/5.1/lua/?.lua",
  "C:/Program Files (x86)/Lua/5.1/lua/?/init.lua",
  package.path,
}, ";")
package.cpath = package.cpath .. ";C:/Program Files (x86)/Lua/5.1/clibs/?.dll"

local websocket_provider = require("src.net.websocket_provider")

print("Resolving websocket provider...")
local resolved = websocket_provider.resolve()
if not resolved.ok then
  io.stderr:write("FAIL: provider did not resolve: " .. tostring(resolved.reason) .. "\n")
  os.exit(1)
end
print("  provider resolved via: " .. tostring(resolved.source))

-- Try wss:// directly (Render does TLS termination)
local url = "wss://bom-hbfv.onrender.com/host"
print("Connecting to " .. url .. " ...")

local ok, result_or_err = pcall(function()
  return resolved.provider.connect(url, {})
end)

if not ok then
  -- Also try the ws:// -> wss:// redirect path
  print("  direct wss:// failed: " .. tostring(result_or_err))
  print("")
  print("Trying ws:// (expecting 301 redirect to wss://) ...")
  local ws_url = "ws://bom-hbfv.onrender.com/host"
  local ok2, result_or_err2 = pcall(function()
    return resolved.provider.connect(ws_url, {})
  end)
  if not ok2 then
    io.stderr:write("FAIL: both wss:// and ws:// connection failed\n")
    io.stderr:write("  wss error: " .. tostring(result_or_err) .. "\n")
    io.stderr:write("  ws  error: " .. tostring(result_or_err2) .. "\n")
    os.exit(1)
  end
  print("  connected via ws:// redirect path!")
  result_or_err = result_or_err2
end

local conn = result_or_err
print("SUCCESS: wss:// connection established!")
print("  send method: " .. type(conn.send))
print("  receive method: " .. type(conn.receive))

-- Try to receive the room_created message from the relay
print("Waiting for relay room_created message (5s timeout)...")
local msg_ok, msg = pcall(function()
  return conn.receive(conn, 5000)
end)
if msg_ok and msg then
  print("  received: " .. tostring(msg))
else
  print("  no message or timeout (this is OK for connection test)")
end

if conn.close then
  pcall(function() conn.close(conn) end)
end

print("")
print("WSS real connection smoke test PASSED")
