-- Procedural texture system: generates reusable canvases at load time.
-- No external image files needed.

local textures = {}

local NOISE_SIZE = 128   -- tile size for noise textures
local VIGNETTE_W = 1280
local VIGNETTE_H = 720

-- Generate a noise ImageData (grayscale, tileable)
local function gen_noise_image(w, h, scale)
  scale = scale or 1.0
  local data = love.image.newImageData(w, h)
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local v = math.random() * scale
      data:setPixel(x, y, v, v, v, 1)
    end
  end
  return data
end

-- Create a tileable noise Image
local function make_noise_image(w, h, scale)
  local data = gen_noise_image(w, h, scale)
  local img = love.graphics.newImage(data)
  img:setWrap("repeat", "repeat")
  return img
end

-- Generate vignette image (radial gradient: transparent center, dark edges)
-- Uses ImageData to set pixels directly -- avoids alpha-blending accumulation bugs.
local function make_vignette(w, h)
  local data = love.image.newImageData(w, h)
  local cx, cy = w / 2, h / 2
  local max_dist = math.sqrt(cx * cx + cy * cy)
  for py = 0, h - 1 do
    for px = 0, w - 1 do
      local dx, dy = px - cx, py - cy
      local dist = math.sqrt(dx * dx + dy * dy)
      local t = dist / max_dist  -- 0 at center, 1 at corners
      local alpha = 0
      if t > 0.35 then
        alpha = ((t - 0.35) / 0.65) ^ 1.8 * 0.6
      end
      data:setPixel(px, py, 0, 0, 0, alpha)
    end
  end
  local img = love.graphics.newImage(data)
  return img
end

-- Generate panel texture canvas (dark subtle noise)
local function make_panel_texture()
  local img = make_noise_image(NOISE_SIZE, NOISE_SIZE, 0.4)
  return img
end

-- Generate card parchment texture (warmer tint)
local function make_card_texture()
  local w, h = NOISE_SIZE, NOISE_SIZE
  local data = love.image.newImageData(w, h)
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local v = math.random() * 0.35
      -- Warm tint: slightly more red/green than blue
      data:setPixel(x, y, v * 1.1, v * 1.0, v * 0.8, 1)
    end
  end
  local img = love.graphics.newImage(data)
  img:setWrap("repeat", "repeat")
  return img
end

local _initialized = false

function textures.init()
  if _initialized then return end
  _initialized = true
  textures.noise = make_noise_image(NOISE_SIZE, NOISE_SIZE, 0.3)
  textures.panel = make_panel_texture()
  textures.card = make_card_texture()
  textures.vignette = make_vignette(VIGNETTE_W, VIGNETTE_H)
  -- Reset graphics state to clean defaults
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setBlendMode("alpha")
  love.graphics.setScissor()
end

-- Ensure textures are ready (called lazily on first draw)
local function ensure_init()
  if not _initialized then textures.init() end
end

-- Draw a texture tiled across a rectangular area with given alpha
function textures.draw_tiled(img, x, y, w, h, alpha, tint_r, tint_g, tint_b)
  ensure_init()
  tint_r = tint_r or 1
  tint_g = tint_g or 1
  tint_b = tint_b or 1
  alpha = alpha or 0.06
  local iw, ih = img:getDimensions()
  local quad = love.graphics.newQuad(0, 0, w, h, iw, ih)
  love.graphics.setColor(tint_r, tint_g, tint_b, alpha)
  love.graphics.draw(img, quad, x, y)
end

-- Draw vignette scaled to current window size
function textures.draw_vignette()
  ensure_init()
  local gw, gh = love.graphics.getDimensions()
  local vw, vh = textures.vignette:getDimensions()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(textures.vignette, 0, 0, 0, gw / vw, gh / vh)
end

-- Draw inner shadow on a rectangle (darker edges fading inward)
function textures.draw_inner_shadow(x, y, w, h, depth, alpha)
  depth = depth or 6
  alpha = alpha or 0.3
  for i = 0, depth - 1 do
    local a = alpha * (1 - i / depth)
    love.graphics.setColor(0, 0, 0, a)
    -- Top edge
    love.graphics.rectangle("fill", x + i, y + i, w - i * 2, 1)
    -- Bottom edge
    love.graphics.rectangle("fill", x + i, y + h - 1 - i, w - i * 2, 1)
    -- Left edge
    love.graphics.rectangle("fill", x + i, y + i, 1, h - i * 2)
    -- Right edge
    love.graphics.rectangle("fill", x + w - 1 - i, y + i, 1, h - i * 2)
  end
end

return textures
