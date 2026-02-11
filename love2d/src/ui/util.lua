local util = {}

-- Font cache: avoids creating a new font object every frame
local _font_cache = {}
function util.get_font(size)
  if not _font_cache[size] then
    _font_cache[size] = love.graphics.newFont(size)
  end
  return _font_cache[size]
end

function util.clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

function util.point_in_rect(px, py, x, y, w, h)
  return px >= x and px <= x + w and py >= y and py <= y + h
end

-- Deep copy table (simple, no metatables)
function util.copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do
    out[k] = util.copy(v)
  end
  return out
end

return util
