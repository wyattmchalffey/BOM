-- Simple procedural art for cards and resource nodes (no image files).
-- All drawing uses (x, y, w, h) as the art box; shapes are scaled to fit.

local card_art = {}

local function fill(r, g, b, a) love.graphics.setColor(r, g, b, a or 1) end

-- Draw art inside box (ax, ay, aw, ah). name_id: "Castle", "Encampment", "Wood", "Stone", "Food", or kind "Structure"/"Unit".
function card_art.draw_card_art(ax, ay, aw, ah, kind, is_base, name_or_faction)
  local cx, cy = ax + aw/2, ay + ah/2
  if is_base then
    if name_or_faction == "Human" or (name_or_faction or ""):lower():match("castle") then
      card_art._draw_castle(ax, ay, aw, ah)
    else
      card_art._draw_encampment(ax, ay, aw, ah)
    end
    return
  end
  if kind == "Structure" or kind == "Artifact" then
    card_art._draw_structure(ax, ay, aw, ah)
  elseif kind == "Unit" then
    card_art._draw_unit(ax, ay, aw, ah)
  else
    card_art._draw_generic(ax, ay, aw, ah, kind)
  end
end

function card_art._draw_castle(ax, ay, aw, ah)
  local cx = ax + aw/2

  -- Sky gradient
  for i = 0, math.floor(ah * 0.45) do
    local f = i / (ah * 0.45)
    fill(0.08 + f*0.06, 0.1 + f*0.08, 0.2 + f*0.05, 1)
    love.graphics.rectangle("fill", ax, ay + i, aw, 1)
  end

  -- Ground
  fill(0.18, 0.2, 0.14, 1)
  love.graphics.rectangle("fill", ax, ay + ah*0.82, aw, ah*0.18)
  fill(0.15, 0.17, 0.12, 1)
  love.graphics.rectangle("fill", ax, ay + ah*0.82, aw, ah*0.03)

  -- Castle wall (wide base behind towers)
  fill(0.32, 0.33, 0.38, 1)
  love.graphics.rectangle("fill", ax + aw*0.18, ay + ah*0.48, aw*0.64, ah*0.34)
  -- Wall shading (darker bottom)
  for i = 0, math.floor(ah*0.34) do
    local f = i / (ah*0.34)
    fill(0, 0, 0, f * 0.15)
    love.graphics.rectangle("fill", ax + aw*0.18, ay + ah*0.48 + i, aw*0.64, 1)
  end
  -- Wall battlements
  fill(0.35, 0.36, 0.42, 1)
  for i = 0, 5 do
    local bx = ax + aw*0.2 + i * aw*0.1
    love.graphics.rectangle("fill", bx, ay + ah*0.44, aw*0.06, ah*0.06)
  end

  -- Left tower
  fill(0.38, 0.38, 0.44, 1)
  love.graphics.rectangle("fill", ax + aw*0.12, ay + ah*0.28, aw*0.2, ah*0.54)
  -- Tower shading (left lit, right shadow)
  for i = 0, math.floor(aw*0.2) do
    local f = i / (aw*0.2)
    fill(0, 0, 0, f * 0.2)
    love.graphics.rectangle("fill", ax + aw*0.12 + i, ay + ah*0.28, 1, ah*0.54)
  end
  -- Left tower top (conical roof)
  fill(0.3, 0.22, 0.18, 1)
  love.graphics.polygon("fill",
    ax + aw*0.22, ay + ah*0.15,
    ax + aw*0.1, ay + ah*0.3,
    ax + aw*0.34, ay + ah*0.3)
  fill(0.25, 0.18, 0.14, 1)
  love.graphics.polygon("line",
    ax + aw*0.22, ay + ah*0.15,
    ax + aw*0.1, ay + ah*0.3,
    ax + aw*0.34, ay + ah*0.3)
  -- Left tower battlements
  fill(0.42, 0.42, 0.48, 1)
  for i = 0, 2 do
    love.graphics.rectangle("fill", ax + aw*0.12 + i*aw*0.065, ay + ah*0.26, aw*0.05, ah*0.04)
  end
  -- Left tower window
  fill(0.15, 0.18, 0.28, 1)
  love.graphics.rectangle("fill", ax + aw*0.19, ay + ah*0.42, aw*0.06, ah*0.08)
  fill(0.6, 0.55, 0.3, 0.4)
  love.graphics.rectangle("fill", ax + aw*0.19, ay + ah*0.42, aw*0.03, ah*0.08)

  -- Right tower
  fill(0.36, 0.36, 0.42, 1)
  love.graphics.rectangle("fill", ax + aw*0.68, ay + ah*0.28, aw*0.2, ah*0.54)
  for i = 0, math.floor(aw*0.2) do
    local f = i / (aw*0.2)
    fill(0, 0, 0, f * 0.2)
    love.graphics.rectangle("fill", ax + aw*0.68 + i, ay + ah*0.28, 1, ah*0.54)
  end
  -- Right tower top
  fill(0.3, 0.22, 0.18, 1)
  love.graphics.polygon("fill",
    ax + aw*0.78, ay + ah*0.15,
    ax + aw*0.66, ay + ah*0.3,
    ax + aw*0.9, ay + ah*0.3)
  fill(0.25, 0.18, 0.14, 1)
  love.graphics.polygon("line",
    ax + aw*0.78, ay + ah*0.15,
    ax + aw*0.66, ay + ah*0.3,
    ax + aw*0.9, ay + ah*0.3)
  -- Right tower battlements
  fill(0.4, 0.4, 0.46, 1)
  for i = 0, 2 do
    love.graphics.rectangle("fill", ax + aw*0.68 + i*aw*0.065, ay + ah*0.26, aw*0.05, ah*0.04)
  end
  -- Right tower window
  fill(0.15, 0.18, 0.28, 1)
  love.graphics.rectangle("fill", ax + aw*0.75, ay + ah*0.42, aw*0.06, ah*0.08)
  fill(0.6, 0.55, 0.3, 0.4)
  love.graphics.rectangle("fill", ax + aw*0.75, ay + ah*0.42, aw*0.03, ah*0.08)

  -- Central keep (taller, behind gate)
  fill(0.34, 0.35, 0.4, 1)
  love.graphics.rectangle("fill", ax + aw*0.35, ay + ah*0.32, aw*0.3, ah*0.5)
  -- Keep roof peak
  fill(0.28, 0.2, 0.16, 1)
  love.graphics.polygon("fill",
    cx, ay + ah*0.2,
    ax + aw*0.33, ay + ah*0.34,
    ax + aw*0.67, ay + ah*0.34)
  fill(0.22, 0.16, 0.12, 1)
  love.graphics.polygon("line",
    cx, ay + ah*0.2,
    ax + aw*0.33, ay + ah*0.34,
    ax + aw*0.67, ay + ah*0.34)

  -- Gate arch
  fill(0.12, 0.13, 0.18, 1)
  love.graphics.rectangle("fill", ax + aw*0.42, ay + ah*0.58, aw*0.16, ah*0.24)
  -- Arch top (semicircle)
  love.graphics.arc("fill", cx, ay + ah*0.58, aw*0.08, math.pi, 0)
  -- Portcullis lines
  fill(0.25, 0.22, 0.18, 0.6)
  for i = 0, 3 do
    local gx = ax + aw*0.43 + i * aw*0.04
    love.graphics.rectangle("fill", gx, ay + ah*0.52, aw*0.008, ah*0.3)
  end
  for i = 0, 2 do
    local gy = ay + ah*0.6 + i * ah*0.06
    love.graphics.rectangle("fill", ax + aw*0.42, gy, aw*0.16, ah*0.008)
  end

  -- Banner on keep
  fill(0.2, 0.25, 0.6, 1)
  love.graphics.rectangle("fill", cx - aw*0.02, ay + ah*0.36, aw*0.04, ah*0.12)
  fill(0.8, 0.75, 0.4, 1)
  love.graphics.rectangle("fill", cx - aw*0.015, ay + ah*0.38, aw*0.03, ah*0.03)

  -- Subtle wall highlight (top edge)
  fill(1, 1, 1, 0.08)
  love.graphics.rectangle("fill", ax + aw*0.18, ay + ah*0.48, aw*0.64, 1)
end

function card_art._draw_encampment(ax, ay, aw, ah)
  local cx = ax + aw/2

  -- Dusky sky gradient
  for i = 0, math.floor(ah * 0.5) do
    local f = i / (ah * 0.5)
    fill(0.15 + f*0.06, 0.08 + f*0.06, 0.06 + f*0.08, 1)
    love.graphics.rectangle("fill", ax, ay + i, aw, 1)
  end

  -- Dusty ground
  fill(0.22, 0.18, 0.13, 1)
  love.graphics.rectangle("fill", ax, ay + ah*0.78, aw, ah*0.22)
  -- Ground texture lines
  fill(0.18, 0.15, 0.1, 0.5)
  love.graphics.rectangle("fill", ax, ay + ah*0.78, aw, ah*0.02)
  fill(0.25, 0.2, 0.15, 0.3)
  love.graphics.rectangle("fill", ax + aw*0.1, ay + ah*0.88, aw*0.3, ah*0.01)
  love.graphics.rectangle("fill", ax + aw*0.55, ay + ah*0.92, aw*0.25, ah*0.01)

  -- Wooden palisade wall (behind tents)
  fill(0.3, 0.22, 0.14, 1)
  love.graphics.rectangle("fill", ax + aw*0.05, ay + ah*0.52, aw*0.9, ah*0.28)
  -- Palisade stakes (pointed tops)
  for i = 0, 8 do
    local sx = ax + aw*0.07 + i * aw*0.1
    local sw = aw*0.08
    fill(0.32, 0.24, 0.16, 1)
    love.graphics.rectangle("fill", sx, ay + ah*0.45, sw, ah*0.35)
    -- Pointed top
    fill(0.35, 0.26, 0.17, 1)
    love.graphics.polygon("fill",
      sx, ay + ah*0.45,
      sx + sw, ay + ah*0.45,
      sx + sw/2, ay + ah*0.38)
    -- Wood grain lines
    fill(0.25, 0.18, 0.12, 0.4)
    love.graphics.rectangle("fill", sx + sw*0.3, ay + ah*0.48, sw*0.1, ah*0.3)
    love.graphics.rectangle("fill", sx + sw*0.6, ay + ah*0.46, sw*0.1, ah*0.32)
  end

  -- Main tent (large, center)
  -- Tent shadow on ground
  fill(0, 0, 0, 0.2)
  love.graphics.ellipse("fill", cx, ay + ah*0.82, aw*0.28, ah*0.04)
  -- Tent body
  fill(0.6, 0.32, 0.2, 1)
  love.graphics.polygon("fill",
    cx, ay + ah*0.3,
    ax + aw*0.25, ay + ah*0.78,
    ax + aw*0.75, ay + ah*0.78)
  -- Tent highlight (left face lit by fire)
  fill(0.7, 0.4, 0.25, 1)
  love.graphics.polygon("fill",
    cx, ay + ah*0.3,
    ax + aw*0.25, ay + ah*0.78,
    cx, ay + ah*0.78)
  -- Tent shadow (right face)
  fill(0.45, 0.24, 0.15, 1)
  love.graphics.polygon("fill",
    cx, ay + ah*0.3,
    cx, ay + ah*0.78,
    ax + aw*0.75, ay + ah*0.78)
  -- Tent outline
  fill(0.35, 0.2, 0.12, 1)
  love.graphics.polygon("line",
    cx, ay + ah*0.3,
    ax + aw*0.25, ay + ah*0.78,
    ax + aw*0.75, ay + ah*0.78)
  -- Tent entrance flap
  fill(0.12, 0.1, 0.08, 0.8)
  love.graphics.polygon("fill",
    cx - aw*0.06, ay + ah*0.55,
    cx + aw*0.06, ay + ah*0.55,
    cx + aw*0.1, ay + ah*0.78,
    cx - aw*0.1, ay + ah*0.78)
  -- Tent pole tip
  fill(0.45, 0.35, 0.25, 1)
  love.graphics.rectangle("fill", cx - aw*0.01, ay + ah*0.26, aw*0.02, ah*0.06)

  -- Orc war banner (left of tent)
  fill(0.3, 0.22, 0.15, 1)
  love.graphics.rectangle("fill", ax + aw*0.15, ay + ah*0.35, aw*0.02, ah*0.45)
  fill(0.7, 0.2, 0.15, 1)
  love.graphics.polygon("fill",
    ax + aw*0.17, ay + ah*0.36,
    ax + aw*0.3, ay + ah*0.42,
    ax + aw*0.17, ay + ah*0.48)
  -- Skull emblem on banner
  fill(0.85, 0.8, 0.7, 0.7)
  love.graphics.circle("fill", ax + aw*0.22, ay + ah*0.42, aw*0.025)

  -- Small campfire (right of tent, foreground)
  -- Fire glow on ground
  fill(0.5, 0.25, 0.05, 0.25)
  love.graphics.circle("fill", ax + aw*0.78, ay + ah*0.78, aw*0.1)
  -- Logs
  fill(0.25, 0.18, 0.1, 1)
  love.graphics.rectangle("fill", ax + aw*0.73, ay + ah*0.76, aw*0.1, ah*0.03)
  love.graphics.rectangle("fill", ax + aw*0.75, ay + ah*0.74, aw*0.08, ah*0.03)
  -- Flames
  fill(0.9, 0.55, 0.1, 0.9)
  love.graphics.polygon("fill",
    ax + aw*0.76, ay + ah*0.74,
    ax + aw*0.78, ay + ah*0.65,
    ax + aw*0.8, ay + ah*0.74)
  fill(0.95, 0.8, 0.2, 0.8)
  love.graphics.polygon("fill",
    ax + aw*0.77, ay + ah*0.74,
    ax + aw*0.785, ay + ah*0.68,
    ax + aw*0.8, ay + ah*0.74)

  -- Weapon rack (right side)
  fill(0.3, 0.22, 0.15, 1)
  love.graphics.rectangle("fill", ax + aw*0.85, ay + ah*0.5, aw*0.02, ah*0.3)
  love.graphics.rectangle("fill", ax + aw*0.9, ay + ah*0.5, aw*0.02, ah*0.3)
  love.graphics.rectangle("fill", ax + aw*0.84, ay + ah*0.52, aw*0.1, ah*0.02)
  -- Spears leaning
  fill(0.4, 0.38, 0.35, 0.8)
  love.graphics.rectangle("fill", ax + aw*0.86, ay + ah*0.35, aw*0.012, ah*0.35)
  love.graphics.rectangle("fill", ax + aw*0.89, ay + ah*0.38, aw*0.012, ah*0.32)
end

function card_art._draw_structure(ax, ay, aw, ah)
  local cx = ax + aw/2
  fill(0.4, 0.35, 0.3, 1)
  love.graphics.rectangle("fill", ax + aw*0.25, ay + ah*0.45, aw*0.5, ah*0.4)
  fill(0.28, 0.25, 0.22, 1)
  love.graphics.rectangle("line", ax + aw*0.25, ay + ah*0.45, aw*0.5, ah*0.4)
  -- Roof
  fill(0.5, 0.32, 0.28, 1)
  love.graphics.polygon("fill", ax + aw*0.2, ay + ah*0.45, cx, ay + ah*0.28, ax + aw*0.8, ay + ah*0.45)
  fill(0.35, 0.22, 0.18, 1)
  love.graphics.polygon("line", ax + aw*0.2, ay + ah*0.45, cx, ay + ah*0.28, ax + aw*0.8, ay + ah*0.45)
  -- Door
  fill(0.25, 0.22, 0.2, 1)
  love.graphics.rectangle("fill", ax + aw*0.42, ay + ah*0.62, aw*0.16, ah*0.23)
end

function card_art._draw_unit(ax, ay, aw, ah)
  local cx = ax + aw/2
  -- Shield / figure silhouette
  fill(0.38, 0.4, 0.45, 1)
  love.graphics.ellipse("fill", cx, ay + ah*0.58, aw*0.28, ah*0.38)
  fill(0.25, 0.26, 0.3, 1)
  love.graphics.ellipse("line", cx, ay + ah*0.58, aw*0.28, ah*0.38)
  -- Helmet / top
  fill(0.35, 0.35, 0.4, 1)
  love.graphics.rectangle("fill", ax + aw*0.38, ay + ah*0.32, aw*0.24, ah*0.12)
  love.graphics.rectangle("fill", ax + aw*0.4, ay + ah*0.25, aw*0.2, ah*0.1)
end

function card_art._draw_generic(ax, ay, aw, ah, kind)
  local cx, cy = ax + aw/2, ay + ah/2
  fill(0.28, 0.3, 0.35, 1)
  love.graphics.rectangle("fill", ax + aw*0.3, ay + ah*0.3, aw*0.4, ah*0.4)
  fill(0.2, 0.22, 0.28, 1)
  love.graphics.rectangle("line", ax + aw*0.3, ay + ah*0.3, aw*0.4, ah*0.4)
end

-- Resource node art: Wood/Forest, Stone, Food
function card_art.draw_resource_art(ax, ay, aw, ah, title)
  local t = (title or ""):lower()
  if t:match("wood") or t:match("forest") then
    card_art._draw_forest(ax, ay, aw, ah)
  elseif t:match("stone") or t:match("quarry") then
    card_art._draw_quarry(ax, ay, aw, ah)
  else
    card_art._draw_food(ax, ay, aw, ah)
  end
end

function card_art._draw_forest(ax, ay, aw, ah)
  -- Two simple trees
  local cx = ax + aw/2
  -- Left tree
  fill(0.35, 0.28, 0.2, 1)
  love.graphics.rectangle("fill", ax + aw*0.22, ay + ah*0.45, aw*0.12, ah*0.4)
  fill(0.22, 0.5, 0.28, 1)
  love.graphics.circle("fill", ax + aw*0.28, ay + ah*0.38, aw*0.14)
  -- Right tree
  fill(0.35, 0.28, 0.2, 1)
  love.graphics.rectangle("fill", ax + aw*0.66, ay + ah*0.5, aw*0.1, ah*0.35)
  fill(0.18, 0.42, 0.22, 1)
  love.graphics.circle("fill", ax + aw*0.71, ay + ah*0.42, aw*0.12)
end

function card_art._draw_quarry(ax, ay, aw, ah)
  -- Rock pile (overlapping circles/rounded shapes)
  fill(0.45, 0.44, 0.42, 1)
  love.graphics.circle("fill", ax + aw*0.35, ay + ah*0.6, aw*0.18)
  love.graphics.circle("fill", ax + aw*0.6, ay + ah*0.58, aw*0.2)
  love.graphics.circle("fill", ax + aw*0.48, ay + ah*0.45, aw*0.15)
  fill(0.35, 0.34, 0.32, 1)
  love.graphics.circle("line", ax + aw*0.35, ay + ah*0.6, aw*0.18)
  love.graphics.circle("line", ax + aw*0.6, ay + ah*0.58, aw*0.2)
  love.graphics.circle("line", ax + aw*0.48, ay + ah*0.45, aw*0.15)
end

function card_art._draw_food(ax, ay, aw, ah)
  -- Wheat / grain sheaf (simple stalks and head)
  local cx = ax + aw/2
  fill(0.6, 0.52, 0.25, 1)
  for i = -2, 2 do
    local ox = i * aw * 0.08
    love.graphics.rectangle("fill", cx + ox - aw*0.02, ay + ah*0.35, aw*0.04, ah*0.45)
  end
  fill(0.72, 0.62, 0.28, 1)
  love.graphics.ellipse("fill", cx, ay + ah*0.38, aw*0.22, ah*0.18)
  fill(0.55, 0.48, 0.2, 1)
  love.graphics.ellipse("line", cx, ay + ah*0.38, aw*0.22, ah*0.18)
end

return card_art
