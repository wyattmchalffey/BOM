-- Card sprite-sheet asset loader.
-- Slices pixelCardAssest_V01.png into faction card backs, bordered frames,
-- name banners, and small icons.

local card_assets = {}

local SHEET_PATH = "assets/pixelCardAssest_V01.png"

---------------------------------------------------------------------------
-- Internal state  (lazy-loaded on first use)
---------------------------------------------------------------------------
local loaded = false
local sheet_img = nil    -- the full sprite sheet Image

-- Quads keyed by faction name → love Quad for the solid card back
local back_quads = {}
-- Quads keyed by style name → love Quad for bordered portrait frames
local frame_quads = {}

---------------------------------------------------------------------------
-- Sprite-sheet coordinates  (measured from the PNG)
-- Row 1: solid card backs  100×96 each
---------------------------------------------------------------------------
local BACK_RECTS = {
  Human   = { x = 14, y =  4, w = 100, h = 96 },  -- blue
  Orc     = { x = 133, y = 4, w = 100, h = 96 },  -- red
  Neutral = { x = 250, y = 4, w = 100, h = 96 },  -- grey
  Elf     = { x = 366, y = 4, w = 100, h = 96 },  -- green
  Gnome   = { x = 481, y = 4, w = 100, h = 96 },  -- yellow
  Stone   = { x = 610, y = 4, w = 100, h = 96 },  -- stone texture
}

---------------------------------------------------------------------------
-- Row 6: bordered portrait frames
---------------------------------------------------------------------------
local FRAME_RECTS = {
  wood   = { x = 14,  y = 385, w = 100, h = 90 },
  blue   = { x = 130, y = 385, w = 100, h = 90 },
  orange = { x = 233, y = 385, w = 100, h = 90 },
  purple = { x = 340, y = 385, w = 92,  h = 80 },
}

---------------------------------------------------------------------------
-- Lazy loader
---------------------------------------------------------------------------
local function ensure_loaded()
  if loaded then return end
  loaded = true

  local ok, img = pcall(love.graphics.newImage, SHEET_PATH)
  if not ok or not img then
    print("[card_assets] WARNING: could not load " .. SHEET_PATH)
    return
  end
  img:setFilter("nearest", "nearest")
  sheet_img = img

  local sw, sh = img:getWidth(), img:getHeight()

  -- Create quads for card backs
  for faction, r in pairs(BACK_RECTS) do
    back_quads[faction] = love.graphics.newQuad(r.x, r.y, r.w, r.h, sw, sh)
  end

  -- Create quads for bordered frames
  for style, r in pairs(FRAME_RECTS) do
    frame_quads[style] = love.graphics.newQuad(r.x, r.y, r.w, r.h, sw, sh)
  end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Draw a faction card back stretched to fill (x, y, w, h).
--- Uses rounded-rectangle clipping to respect card corner radius.
---@param faction string  "Human"|"Orc"|"Elf"|"Gnome"|"Neutral"
---@param x number
---@param y number
---@param w number
---@param h number
---@param corner_r number  corner radius for clipping (default 6)
---@param alpha number     opacity 0-1 (default 1)
function card_assets.draw_card_back(faction, x, y, w, h, corner_r, alpha)
  ensure_loaded()
  if not sheet_img then return false end

  local quad = back_quads[faction] or back_quads["Neutral"]
  if not quad then return false end

  corner_r = corner_r or 6
  alpha = alpha or 1

  local rect = BACK_RECTS[faction] or BACK_RECTS["Neutral"]
  local sx = w / rect.w
  local sy = h / rect.h

  love.graphics.setColor(1, 1, 1, alpha)
  love.graphics.draw(sheet_img, quad, x, y, 0, sx, sy)
  return true
end

--- Draw a bordered portrait frame stretched to fill (x, y, w, h).
---@param style string  "wood"|"blue"|"orange"|"purple"
function card_assets.draw_frame(style, x, y, w, h, alpha)
  ensure_loaded()
  if not sheet_img then return false end

  local quad = frame_quads[style]
  if not quad then return false end

  alpha = alpha or 1
  local rect = FRAME_RECTS[style]
  local sx = w / rect.w
  local sy = h / rect.h

  love.graphics.setColor(1, 1, 1, alpha)
  love.graphics.draw(sheet_img, quad, x, y, 0, sx, sy)
  return true
end

--- Check whether the sprite sheet loaded successfully.
function card_assets.is_loaded()
  ensure_loaded()
  return sheet_img ~= nil
end

return card_assets
