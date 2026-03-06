local util = {}

-- Font DPI scale: set from main.lua when the window is resized so fonts are
-- rasterized at the actual screen resolution while reporting logical metrics.
local _font_dpi = 1
local _font_cache = {}
local _title_font_cache = {}

function util.set_font_dpi(ui_scale)
  local new_dpi = math.max(1, math.ceil(ui_scale * 2) / 2)  -- round up to nearest 0.5
  if new_dpi ~= _font_dpi then
    _font_dpi = new_dpi
    _font_cache = {}
    _title_font_cache = {}
  end
end

function util.get_font(size)
  if not _font_cache[size] then
    _font_cache[size] = love.graphics.newFont(size, "normal", _font_dpi)
  end
  return _font_cache[size]
end

function util.get_title_font(size)
  if not _title_font_cache[size] then
    _title_font_cache[size] = love.graphics.newFont(size, "normal", _font_dpi)
  end
  return _title_font_cache[size]
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
