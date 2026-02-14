-- Ambient floating particles: dust motes / embers that drift across the screen.

local particles = {}

local _particles = {}
local PARTICLE_COUNT = 25
local gw, gh = 1280, 720  -- updated each frame

local function spawn_particle(i)
  return {
    x = math.random() * gw,
    y = math.random() * gh,
    vx = (math.random() - 0.5) * 12,
    vy = -8 - math.random() * 10,
    size = 1.5 + math.random() * 2,
    alpha = 0.04 + math.random() * 0.08,
    phase = math.random() * math.pi * 2,  -- for sine wobble
    speed = 0.5 + math.random() * 1.0,
  }
end

function particles.init()
  _particles = {}
  for i = 1, PARTICLE_COUNT do
    _particles[i] = spawn_particle(i)
  end
end

function particles.update(dt)
  gw, gh = love.graphics.getDimensions()
  for _, p in ipairs(_particles) do
    p.x = p.x + (p.vx + math.sin(love.timer.getTime() * p.speed + p.phase) * 6) * dt
    p.y = p.y + p.vy * dt
    -- Wrap around edges
    if p.y < -10 then p.y = gh + 10 end
    if p.y > gh + 10 then p.y = -10 end
    if p.x < -10 then p.x = gw + 10 end
    if p.x > gw + 10 then p.x = -10 end
  end
end

function particles.draw(accent_color)
  local r, g, b = 0.6, 0.65, 0.8
  if accent_color then
    r = (r + accent_color[1]) * 0.5
    g = (g + accent_color[2]) * 0.5
    b = (b + accent_color[3]) * 0.5
  end
  for _, p in ipairs(_particles) do
    love.graphics.setColor(r, g, b, p.alpha)
    love.graphics.circle("fill", p.x, p.y, p.size)
  end
end

-- Initialize on require
particles.init()

return particles
