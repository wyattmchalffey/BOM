-- Load and cache deck card back images. Place blueprint_back.png and unit_back.png
-- in the love2d folder (or the folder that contains main.lua when running).

local deck_assets = {}

local blueprint_back, unit_back

local function load_image(...)
  for _, path in ipairs({...}) do
    local ok, img = pcall(love.graphics.newImage, path)
    if ok and img then return img end
  end
  return nil
end

function deck_assets.get_blueprint_back()
  if blueprint_back == nil then
    blueprint_back = load_image(
      "blueprint_back.png",
      "assets/blueprint_back.png",
      "Siegecraft - Blueprints.png",
      "assets/Siegecraft - Blueprints.png"
    ) or false
  end
  return blueprint_back ~= false and blueprint_back or nil
end

function deck_assets.get_unit_back()
  if unit_back == nil then
    unit_back = load_image(
      "unit_back.png",
      "assets/unit_back.png",
      "Siegecraft - Creatures.png",
      "assets/Siegecraft - Creatures.png"
    ) or false
  end
  return unit_back ~= false and unit_back or nil
end

-- Draw image scaled to fit (rx, ry, rw, rh), with rounded clip if desired.
function deck_assets.draw_card_back(img, rx, ry, rw, rh, corner_r)
  if not img then return end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(img, rx, ry, 0, rw / img:getWidth(), rh / img:getHeight())
  if corner_r and corner_r > 0 then
    love.graphics.setColor(0.2, 0.22, 0.28, 1.0)
    love.graphics.rectangle("line", rx, ry, rw, rh, corner_r, corner_r)
  end
end

return deck_assets
