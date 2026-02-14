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

function transport:send_submit(player_index, envelope)
  return self.host:submit_message(player_index, envelope)
end

function transport:request_snapshot()
  return self.host:get_state_snapshot_message()
end

return transport
