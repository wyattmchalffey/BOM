-- Resource icon loader and drawing utility.
-- Loads food/wood/stone PNG icons once and draws them scaled to any size.

local res_icons = {}

local _loaded = false
local _images = {}  -- { food = Image, wood = Image, stone = Image }

-- Lazy-load (must happen after love.graphics is initialized)
local function ensure_loaded()
  if _loaded then return end
  _loaded = true
  local ok_food, img_food = pcall(love.graphics.newImage, "assets/food.png")
  local ok_wood, img_wood = pcall(love.graphics.newImage, "assets/wood.png")
  local ok_stone, img_stone = pcall(love.graphics.newImage, "assets/stone.png")
  if ok_food then
    img_food:setFilter("linear", "linear")
    _images.food = img_food
  end
  if ok_wood then
    img_wood:setFilter("linear", "linear")
    _images.wood = img_wood
  end
  if ok_stone then
    img_stone:setFilter("linear", "linear")
    _images.stone = img_stone
  end
end

--- Draw a resource icon at (x, y) scaled to fit in a size x size box.
--- @param res_type string "food"|"wood"|"stone"
--- @param x number top-left x
--- @param y number top-left y
--- @param size number width and height to draw at
--- @param alpha number optional alpha (default 1)
function res_icons.draw(res_type, x, y, size, alpha)
  ensure_loaded()
  local img = _images[res_type]
  if not img then return false end

  local iw, ih = img:getWidth(), img:getHeight()
  local scale = size / math.max(iw, ih)

  love.graphics.setColor(1, 1, 1, alpha or 1)
  love.graphics.draw(img, x, y, 0, scale, scale)
  return true
end

--- Draw a resource icon with fallback to colored circle + letter abbreviation.
--- Uses PNG when available, otherwise draws a colored circle with res_registry letter.
--- @param res_type string resource key (e.g. "food", "metal", "bones")
--- @param x number top-left x
--- @param y number top-left y
--- @param size number width and height to draw at
--- @param alpha number optional alpha (default 1)
function res_icons.draw_or_fallback(res_type, x, y, size, alpha)
  alpha = alpha or 1
  -- Try PNG first
  if res_icons.draw(res_type, x, y, size, alpha) then
    return true
  end
  -- Fallback: colored circle with letter
  local res_registry = require("src.data.resources")
  local rdef = res_registry[res_type]
  if not rdef then return false end
  local cx = x + size / 2
  local cy = y + size / 2
  local r = size / 2
  -- Filled circle with resource color
  love.graphics.setColor(rdef.color[1], rdef.color[2], rdef.color[3], alpha * 0.7)
  love.graphics.circle("fill", cx, cy, r)
  -- Darker border
  love.graphics.setColor(rdef.color[1] * 0.6, rdef.color[2] * 0.6, rdef.color[3] * 0.6, alpha * 0.9)
  love.graphics.circle("line", cx, cy, r)
  -- White letter centered
  love.graphics.setColor(1, 1, 1, alpha)
  local font = love.graphics.newFont(math.max(7, math.floor(size * 0.55)))
  love.graphics.setFont(font)
  local tw = font:getWidth(rdef.letter)
  local th = font:getHeight()
  love.graphics.print(rdef.letter, cx - tw / 2, cy - th / 2)
  return true
end

--- Get the loaded image for a resource type (or nil).
function res_icons.get(res_type)
  ensure_loaded()
  return _images[res_type]
end

return res_icons
