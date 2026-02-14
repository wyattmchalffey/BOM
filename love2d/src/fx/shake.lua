-- Screen shake: brief camera jolt for impactful events.

local shake = {}

local _timer = 0
local _duration = 0
local _magnitude = 0
local _offset_x = 0
local _offset_y = 0

function shake.trigger(mag, dur)
  if _timer > 0 and mag <= _magnitude then return end
  _magnitude = mag
  _duration = dur
  _timer = dur
end

function shake.update(dt)
  if _timer > 0 then
    _timer = _timer - dt
    if _timer <= 0 then
      _timer = 0
      _offset_x = 0
      _offset_y = 0
    else
      local progress = 1 - (_timer / _duration)
      local decay = 1 - progress
      _offset_x = math.sin(_timer * 30) * _magnitude * decay
      _offset_y = math.cos(_timer * 23) * _magnitude * decay * 0.8
    end
  end
end

function shake.apply()
  love.graphics.push()
  love.graphics.translate(_offset_x, _offset_y)
end

function shake.release()
  love.graphics.pop()
end

return shake
