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
  if kind == "Structure" then
    card_art._draw_structure(ax, ay, aw, ah)
  elseif kind == "Unit" then
    card_art._draw_unit(ax, ay, aw, ah)
  else
    card_art._draw_generic(ax, ay, aw, ah, kind)
  end
end

function card_art._draw_castle(ax, ay, aw, ah)
  local cx, cy = ax + aw/2, ay + ah/2
  fill(0.35, 0.35, 0.4, 1)
  -- Left tower
  love.graphics.rectangle("fill", ax + aw*0.15, ay + ah*0.35, aw*0.22, ah*0.5)
  fill(0.25, 0.26, 0.3, 1)
  love.graphics.rectangle("line", ax + aw*0.15, ay + ah*0.35, aw*0.22, ah*0.5)
  -- Battlements
  for i = 0, 2 do
    love.graphics.rectangle("fill", ax + aw*0.15 + i*aw*0.07, ay + ah*0.32, aw*0.06, ah*0.05)
  end
  -- Right tower
  fill(0.35, 0.35, 0.4, 1)
  love.graphics.rectangle("fill", ax + aw*0.63, ay + ah*0.35, aw*0.22, ah*0.5)
  fill(0.25, 0.26, 0.3, 1)
  love.graphics.rectangle("line", ax + aw*0.63, ay + ah*0.35, aw*0.22, ah*0.5)
  for i = 0, 2 do
    love.graphics.rectangle("fill", ax + aw*0.63 + i*aw*0.07, ay + ah*0.32, aw*0.06, ah*0.05)
  end
  -- Center gate
  fill(0.28, 0.3, 0.36, 1)
  love.graphics.rectangle("fill", ax + aw*0.38, ay + ah*0.5, aw*0.24, ah*0.35)
  fill(0.5, 0.45, 0.35, 1)
  love.graphics.rectangle("fill", ax + aw*0.43, ay + ah*0.58, aw*0.14, ah*0.27)
  fill(0.2, 0.22, 0.26, 1)
  love.graphics.rectangle("line", ax + aw*0.38, ay + ah*0.5, aw*0.24, ah*0.35)
end

function card_art._draw_encampment(ax, ay, aw, ah)
  local cx, cy = ax + aw/2, ay + ah/2
  -- Tent body (triangle)
  fill(0.55, 0.35, 0.25, 1)
  love.graphics.polygon("fill",
    cx, ay + ah*0.5,
    ax + aw*0.2, ay + ah*0.92,
    ax + aw*0.8, ay + ah*0.92)
  fill(0.4, 0.28, 0.18, 1)
  love.graphics.polygon("line",
    cx, ay + ah*0.5,
    ax + aw*0.2, ay + ah*0.92,
    ax + aw*0.8, ay + ah*0.92)
  -- Tent stripe
  fill(0.45, 0.3, 0.2, 1)
  love.graphics.polygon("fill", cx, ay + ah*0.55, ax + aw*0.35, ay + ah*0.9, ax + aw*0.65, ay + ah*0.9)
  -- Spikes / posts
  fill(0.3, 0.28, 0.25, 1)
  love.graphics.rectangle("fill", ax + aw*0.12, ay + ah*0.7, aw*0.04, ah*0.22)
  love.graphics.rectangle("fill", ax + aw*0.84, ay + ah*0.7, aw*0.04, ah*0.22)
  fill(0.7, 0.35, 0.2, 1)
  love.graphics.rectangle("fill", ax + aw*0.1, ay + ah*0.65, aw*0.08, ah*0.06)
  love.graphics.rectangle("fill", ax + aw*0.82, ay + ah*0.65, aw*0.08, ah*0.06)
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
