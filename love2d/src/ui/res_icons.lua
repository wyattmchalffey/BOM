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

--- Get the loaded image for a resource type (or nil).
function res_icons.get(res_type)
  ensure_loaded()
  return _images[res_type]
end

return res_icons
