-- In-process loopback transport for local multiplayer integration tests.
--
-- This simulates a network transport boundary without external sockets.

local transport = {}
transport.__index = transport

function transport.new(host_instance)
  return setmetatable({
    host = host_instance,
  }, transport)
end

function transport:connect(handshake_payload)
  return self.host:connect_message(handshake_payload)
end

function transport:reconnect(reconnect_payload)
  return self.host:reconnect_message(reconnect_payload)
end

function transport:send_submit(envelope)
  return self.host:submit_message(envelope)
end

function transport:request_snapshot(snapshot_payload)
  return self.host:get_state_snapshot_message(snapshot_payload)
end

return transport
