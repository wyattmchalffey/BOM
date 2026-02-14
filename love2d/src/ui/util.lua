local util = {}

-- Font cache: avoids creating a new font object every frame
local _font_cache = {}
function util.get_font(size)
  if not _font_cache[size] then
    _font_cache[size] = love.graphics.newFont(size)
  end
  return _font_cache[size]
end

-- Title font (MedievalSharp): used for card titles, player names, banners
local _title_font_cache = {}
local _title_font_path = "assets/MedievalSharp.ttf"
local _title_font_available = nil -- nil = not checked yet

local function _check_title_font()
  if _title_font_available == nil then
    local info = love.filesystem.getInfo(_title_font_path)
    _title_font_available = (info ~= nil)
  end
  return _title_font_available
end

function util.get_title_font(size)
  if not _title_font_cache[size] then
    if _check_title_font() then
      _title_font_cache[size] = love.graphics.newFont(_title_font_path, size)
    else
      _title_font_cache[size] = love.graphics.newFont(size) -- fallback
    end
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
