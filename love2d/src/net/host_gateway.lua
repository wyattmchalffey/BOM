-- Host gateway that maps transport requests to host message handlers.
--
-- Request shape:
--   {
--     op = "connect" | "reconnect" | "submit" | "snapshot",
--     payload = <protocol payload>,
--     player_index = <number, only for submit>
--   }
--
-- Response shape:
--   { ok = true, message = <protocol message> }
--   { ok = false, reason = <string>, meta = <table> }

local gateway = {}
gateway.__index = gateway

local function fail(reason, meta)
  return { ok = false, reason = reason, meta = meta or {} }
end

local function ok(message)
  return { ok = true, message = message }
end

function gateway.new(host_instance)
  return setmetatable({
    host = host_instance,
  }, gateway)
end

function gateway:handle(request)
  if type(request) ~= "table" then
    return fail("invalid_request")
  end

  if request.op == "connect" then
    return ok(self.host:connect_message(request.payload))
  end

  if request.op == "reconnect" then
    return ok(self.host:reconnect_message(request.payload))
  end

  if request.op == "submit" then
    if type(request.player_index) ~= "number" then
      return fail("missing_player_index")
    end
    return ok(self.host:submit_message(request.player_index, request.payload))
  end

  if request.op == "snapshot" then
    return ok(self.host:get_state_snapshot_message())
  end

  return fail("unsupported_op", { op = request.op })
end

return gateway
