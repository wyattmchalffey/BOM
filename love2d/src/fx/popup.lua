-- Floating text popups: rise upward and fade out.

local popup = {}
local util = require("src.ui.util")

local _popups = {}

function popup.create(text, x, y, color, opts)
  opts = opts or {}
  local vy = opts.vy or -45
  local lifetime = opts.lifetime or 1.2
  local font_size = opts.font_size or 14
  -- Slight random X offset for variety
  local jitter = (math.random() - 0.5) * 12
  _popups[#_popups + 1] = {
    text = text,
    x = x + jitter,
    y = y,
    color = color or { 0.9, 0.9, 0.95 },
    lifetime = lifetime,
    max_lifetime = lifetime,
    vy = vy,
    scale = opts.scale or 1.2,
    font_size = font_size,
  }
end

function popup.update(dt)
  for i = #_popups, 1, -1 do
    local p = _popups[i]
    p.lifetime = p.lifetime - dt
    p.y = p.y + p.vy * dt
    p.vy = p.vy * 0.97
    -- Scale settles toward 1.0
    if p.scale > 1.0 then
      p.scale = math.max(1.0, p.scale - dt * 2)
    end
    if p.lifetime <= 0 then
      table.remove(_popups, i)
    end
  end
end

function popup.draw()
  for _, p in ipairs(_popups) do
    local progress = p.lifetime / p.max_lifetime
    local alpha = (progress > 0.3) and 1.0 or (progress / 0.3)
    local r, g, b = p.color[1], p.color[2], p.color[3]
    love.graphics.setColor(r, g, b, alpha)
    local font = util.get_font(p.font_size)
    love.graphics.setFont(font)
    local tw = font:getWidth(p.text)
    local th = font:getHeight()
    -- Shadow for readability
    love.graphics.setColor(0, 0, 0, alpha * 0.5)
    love.graphics.print(p.text, p.x - tw/2 + 1, p.y - th/2 + 1)
    love.graphics.setColor(r, g, b, alpha)
    love.graphics.push()
    love.graphics.translate(p.x, p.y)
    love.graphics.scale(p.scale)
    love.graphics.print(p.text, -tw/2, -th/2)
    love.graphics.pop()
  end
end

return popup
