-- Draw a single card frame (mirror of web CardFrame)

local util = require("src.ui.util")
local card_art = require("src.ui.card_art")
local factions = require("src.data.factions")

local card_frame = {}

local CARD_W = 160
local CARD_H = 220

-- Get faction strip color (RGBA) from centralized data
local function get_strip_color(faction)
  local f = factions[faction or "Neutral"]
  if f and f.color then
    return { f.color[1], f.color[2], f.color[3], 1.0 }
  end
  return { 0.55, 0.56, 0.83, 1.0 }
end

local function cost_string(cost)
  local t, n = cost.type, cost.amount
  local letter = (t == "food") and "F" or (t == "wood") and "W" or (t == "stone") and "S" or (t == "cash") and "$" or (t == "metal") and "M" or "B"
  return tostring(n) .. letter
end

local function icon_for_kind(kind, is_base)
  if is_base then return "BASE" end
  if kind == "Structure" then return "STR" end
  if kind == "Unit" then return "UNT" end
  if kind == "Worker" then return "WRK" end
  if kind == "ResourceNode" then return "RES" end
  return "???"
end

-- params: title, faction, kind, typeLine, text, costs (table), attack, health, population, is_base
function card_frame.draw(x, y, params)
  local w, h = params.w or CARD_W, params.h or CARD_H
  local title = params.title or "?"
  local faction = params.faction or "Neutral"
  local kind = params.kind or "Structure"
  local type_line = params.typeLine or ""
  local text = params.text or ""
  local costs = params.costs or {}
  local attack = params.attack
  local health = params.health
  local population = params.population
  local is_base = params.is_base or false
  local activated_ability = params.activated_ability
  local ability_used_this_turn = params.ability_used_this_turn
  local ability_can_activate = params.ability_can_activate ~= false

  local strip_color = get_strip_color(faction)
  local bg_dark = { 0.08, 0.09, 0.13, 1.0 }
  local bg_card = { 0.17, 0.19, 0.25, 1.0 }
  local border = { 0.16, 0.18, 0.22, 1.0 }
  local gold_border = { 0.96, 0.78, 0.42, 1.0 }
  local text_color = { 0.82, 0.83, 0.88, 1.0 }
  local muted = { 0.64, 0.66, 0.72, 1.0 }
  local art_bg = { 0.1, 0.11, 0.15, 1.0 }

  -- Card shadow
  if is_base then
    -- Warmer gold-tinted shadow for base cards
    love.graphics.setColor(0.15, 0.12, 0.05, 0.4)
    love.graphics.rectangle("fill", x + 4, y + 5, w + 2, h + 2, 8, 8)
  else
    love.graphics.setColor(0, 0, 0, 0.35)
    love.graphics.rectangle("fill", x + 3, y + 4, w, h, 8, 8)
  end

  -- Card background + border
  love.graphics.setColor(bg_card)
  love.graphics.rectangle("fill", x, y, w, h, 6, 6)
  if is_base then
    love.graphics.setColor(gold_border)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x, y, w, h, 6, 6)
  else
    love.graphics.setColor(border)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", x, y, w, h, 6, 6)
  end

  local pad = 6
  local cx, cy = x + pad, y + pad

  -- Header: faction strip (4px) + title + costs
  love.graphics.setColor(strip_color)
  love.graphics.rectangle("fill", cx, cy, 4, 22, 2, 2)
  love.graphics.setColor(text_color)
  love.graphics.setFont(util.get_font(12))
  love.graphics.print(title, cx + 8, cy + 2)
  local cost_str = ""
  for _, c in ipairs(costs) do
    cost_str = cost_str .. cost_string(c) .. " "
  end
  if cost_str ~= "" then
    love.graphics.setColor(muted)
    love.graphics.setFont(util.get_font(10))
    love.graphics.print(cost_str, cx + w - pad - pad - 40, cy + 4)
  end

  cy = cy + 24
  love.graphics.setColor(muted)
  love.graphics.setFont(util.get_font(10))
  love.graphics.print(type_line, cx, cy)
  if population then
    love.graphics.print("Max " .. population .. " per deck", cx, cy + 12)
    cy = cy + 14
  else
    cy = cy + 14
  end

  -- Art box
  local art_h = 70
  local art_w = w - pad * 2
  love.graphics.setColor(art_bg)
  love.graphics.rectangle("fill", cx, cy, art_w, art_h, 4, 4)
  love.graphics.setColor(border)
  love.graphics.rectangle("line", cx, cy, art_w, art_h, 4, 4)
  card_art.draw_card_art(cx, cy, art_w, art_h, kind, is_base, title or faction)
  cy = cy + art_h + 4
  -- Text (wrap not implemented for MVP; single line or clip)
  -- If there is an activated ability, draw its icon just before the rules text,
  -- so it appears below the art, inline with and before \"Once per turn ...\".
  local text_x = cx
  if activated_ability then
    local icon_size = card_frame.ACTIVATE_ICON_SIZE or 22
    local ix = cx
    local iy = cy - 2
    local used = ability_used_this_turn and activated_ability.once_per_turn
    local can_act = ability_can_activate and not used
    if can_act then
      love.graphics.setColor(0.35, 0.6, 1.0, 1.0)
    else
      love.graphics.setColor(0.35, 0.35, 0.4, 0.8)
    end
    love.graphics.rectangle("fill", ix, iy, icon_size, icon_size, 4, 4)
    love.graphics.setColor(0.15, 0.16, 0.2, 1.0)
    love.graphics.rectangle("line", ix, iy, icon_size, icon_size, 4, 4)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(util.get_font(10))
    if activated_ability.once_per_turn then
      love.graphics.print("1", ix + icon_size/2 - 3, iy + icon_size/2 - 5)
    else
      love.graphics.print("A", ix + icon_size/2 - 4, iy + icon_size/2 - 5)
    end
    text_x = cx + icon_size + 4
  end
  love.graphics.setColor(text_color)
  love.graphics.setFont(util.get_font(10))
  love.graphics.printf(text, text_x, cy, w - pad * 2 - (text_x - cx), "left")

  -- Stats bar at bottom: fixed positions — ATK left, HP right; only draw a box when value is non-nil
  local stat_y = y + h - 28
  local stat_h = 22
  local bar_w = w - pad * 2
  local sw = bar_w / 3  -- same third-width slots as before so HP stays bottom right
  local left_x, right_x = cx, cx + sw * 2

  if attack ~= nil then
    love.graphics.setColor(bg_dark)
    love.graphics.rectangle("fill", left_x, stat_y, sw - 2, stat_h, 3, 3)
    love.graphics.setColor(muted)
    love.graphics.setFont(util.get_font(9))
    love.graphics.print("ATK", left_x + sw/2 - 8, stat_y + 2)
    love.graphics.setColor(text_color)
    love.graphics.setFont(util.get_font(11))
    love.graphics.print(tostring(attack), left_x + sw/2 - 4, stat_y + 12)
  end
  if health ~= nil then
    love.graphics.setColor(bg_dark)
    love.graphics.rectangle("fill", right_x, stat_y, sw - 2, stat_h, 3, 3)
    -- HP label and value aligned horizontally inside the box (e.g. \"HP 30\")
    love.graphics.setColor(text_color)
    love.graphics.setFont(util.get_font(10))
    local hp_text = "HP " .. tostring(health)
    love.graphics.printf(hp_text, right_x, stat_y + stat_h/2 - 6, sw - 2, "center")
  end
end

-- Resource node: full-art card (entire face is art); workers are drawn on top by the board
local RESOURCE_NODE_W = 120
local RESOURCE_NODE_H = 90
local RESOURCE_TITLE_BAR_H = 18  -- thin bar at bottom for name only

function card_frame.draw_resource_node(x, y, title, faction)
  local w, h = RESOURCE_NODE_W, RESOURCE_NODE_H
  local strip_color = get_strip_color(faction)
  local border = { 0.16, 0.18, 0.22, 1.0 }
  local text_color = { 0.82, 0.83, 0.88, 1.0 }
  local art_bg = { 0.12, 0.13, 0.18, 1.0 }

  -- Shadow
  love.graphics.setColor(0, 0, 0, 0.3)
  love.graphics.rectangle("fill", x + 3, y + 3, w, h, 6, 6)

  -- Full-art area: entire card is the art (no separate title strip at top)
  local art_h = h - RESOURCE_TITLE_BAR_H
  love.graphics.setColor(art_bg)
  love.graphics.rectangle("fill", x, y, w, h, 5, 5)
  love.graphics.setColor(border)
  love.graphics.rectangle("line", x, y, w, h, 5, 5)
  card_art.draw_resource_art(x, y, w, art_h, title)

  -- Minimal title bar at bottom only (workers sit on top of the art above this)
  local bar_y = y + h - RESOURCE_TITLE_BAR_H
  love.graphics.setColor(0.08, 0.09, 0.12, 0.95)
  love.graphics.rectangle("fill", x, bar_y, w, RESOURCE_TITLE_BAR_H)
  love.graphics.setColor(strip_color)
  love.graphics.rectangle("fill", x, bar_y, 3, RESOURCE_TITLE_BAR_H)
  love.graphics.setColor(text_color)
  love.graphics.setFont(util.get_font(10))
  love.graphics.print(title or "?", x + 10, bar_y + 4)
end

-- Rect for the activate-ability icon (for hit-test). Same position as drawn: top-right of card.
card_frame.ACTIVATE_ICON_SIZE = 22
function card_frame.activate_icon_rect(card_x, card_y, card_w, card_h)
  -- Icon is drawn just before the rules text: below the art, inline with text.
  local pad = 6
  local header_h = 24
  local type_line_h = 14
  local art_h = 70
  local sz = card_frame.ACTIVATE_ICON_SIZE
  local text_y = card_y + pad + header_h + type_line_h + art_h + 4
  local ix = card_x + pad
  local iy = text_y - 2
  return ix, iy, sz, sz
end

card_frame.CARD_W = CARD_W
card_frame.CARD_H = CARD_H
card_frame.RESOURCE_NODE_W = RESOURCE_NODE_W
card_frame.RESOURCE_NODE_H = RESOURCE_NODE_H

return card_frame
