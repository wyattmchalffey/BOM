-- Draw a single card frame (mirror of web CardFrame)

local util = require("src.ui.util")
local card_art = require("src.ui.card_art")
local factions = require("src.data.factions")
local res_registry = require("src.data.resources")
local textures = require("src.fx.textures")
local res_icons = require("src.ui.res_icons")

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

---------------------------------------------------------
-- Shared: draw a cost cluster (icon + number pairs)
-- Returns total width drawn.
---------------------------------------------------------
local function draw_cost_cluster(cost_list, x, y, icon_size, alpha)
  if not cost_list or #cost_list == 0 then return 0 end
  alpha = alpha or 1
  local start_x = x
  local font = util.get_font(10)
  for _, c in ipairs(cost_list) do
    res_icons.draw(c.type, x, y, icon_size, alpha)
    x = x + icon_size + 1
    love.graphics.setColor(0.85, 0.87, 0.95, alpha)
    love.graphics.setFont(font)
    love.graphics.print(tostring(c.amount), x, y + 1)
    x = x + font:getWidth(tostring(c.amount)) + 4
  end
  return x - start_x
end

-- Measure cost cluster width without drawing
local function measure_cost_cluster(cost_list, icon_size)
  if not cost_list or #cost_list == 0 then return 0 end
  local w = 0
  local font = util.get_font(10)
  for _, c in ipairs(cost_list) do
    w = w + icon_size + 1 + font:getWidth(tostring(c.amount)) + 4
  end
  return w
end

---------------------------------------------------------
-- Draw a standardized activated ability line:
--   [cost icons] : [effect description]
-- Returns the height consumed.
---------------------------------------------------------
local function draw_ability_line(ab, ab_x, ab_y, max_w, opts)
  opts = opts or {}
  local can_activate = opts.can_activate ~= false
  local is_used = opts.is_used or false
  local alpha = (can_activate and not is_used) and 1.0 or 0.45
  local line_h = 20
  local icon_s = 12
  local font = util.get_font(9)

  -- Background bar for the ability
  local bar_alpha = (can_activate and not is_used) and 0.2 or 0.08
  love.graphics.setColor(0.2, 0.25, 0.4, bar_alpha)
  love.graphics.rectangle("fill", ab_x, ab_y, max_w, line_h, 3, 3)
  -- Left accent mark
  love.graphics.setColor(0.35, 0.6, 1.0, (can_activate and not is_used) and 0.7 or 0.2)
  love.graphics.rectangle("fill", ab_x, ab_y, 2, line_h, 1, 1)

  local cx = ab_x + 5
  local cy = ab_y + (line_h - icon_s) / 2

  -- Draw cost icons
  local cost_w = draw_cost_cluster(ab.cost, cx, cy, icon_s, alpha)
  cx = cx + cost_w

  -- Colon separator
  love.graphics.setColor(0.7, 0.72, 0.82, alpha)
  love.graphics.setFont(font)
  love.graphics.print(":", cx, ab_y + 4)
  cx = cx + font:getWidth(":") + 4

  -- Effect text (short description)
  local effect_text = opts.effect_text or ab.effect or "?"
  love.graphics.setColor(0.82, 0.83, 0.88, alpha)
  love.graphics.setFont(font)
  local remaining_w = max_w - (cx - ab_x) - 4
  love.graphics.printf(effect_text, cx, ab_y + 4, math.max(remaining_w, 20), "left")

  -- "Used" overlay
  if is_used then
    love.graphics.setColor(0, 0, 0, 0.3)
    love.graphics.rectangle("fill", ab_x, ab_y, max_w, line_h, 3, 3)
    love.graphics.setColor(0.6, 0.3, 0.3, 0.7)
    love.graphics.setFont(util.get_font(8))
    love.graphics.printf("USED", ab_x, ab_y + 5, max_w, "center")
  end

  return line_h + 2
end

---------------------------------------------------------
-- Generate a short effect description from ability data
---------------------------------------------------------
local function ability_effect_text(ab)
  local e = ab.effect
  local args = ab.effect_args or {}
  if e == "summon_worker" then
    return "Summon " .. (args.amount or 1) .. " Worker"
  elseif e == "draw_cards" then
    return "Draw " .. (args.amount or 1) .. " Card" .. ((args.amount or 1) > 1 and "s" or "")
  elseif e == "play_unit" then
    local sub = args.subtypes and table.concat(args.subtypes, "/") or "Unit"
    return "Play T" .. (args.tier or "?") .. " " .. sub
  elseif e == "research" then
    return "Research T" .. (args.tier or "?")
  elseif e == "convert_resource" then
    return "Create " .. (args.amount or 1) .. " " .. (args.output or "?")
  elseif e == "buff_attack" then
    return "+" .. (args.amount or 0) .. " ATK"
  elseif e == "place_counter" then
    return (args.amount or 1) .. " " .. (args.counter or "?") .. " counters"
  elseif e == "heal" then
    return "Heal " .. (args.amount or 0)
  elseif e == "deal_damage" then
    return "Deal " .. (args.amount or 0) .. " dmg"
  end
  return e or "?"
end

---------------------------------------------------------
-- Main card draw
-- params: title, faction, kind, typeLine, text, costs,
--         attack, health, population, tier, is_base,
--         abilities_list, used_abilities, can_activate_abilities
---------------------------------------------------------
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
  local tier = params.tier
  local is_base = params.is_base or false
  -- New: full abilities list for standardized rendering
  local abilities_list = params.abilities_list  -- array of ability defs
  local used_abilities = params.used_abilities or {}  -- { [ability_index] = true }
  local can_activate_abilities = params.can_activate_abilities or {}  -- { [ability_index] = true }
  -- Legacy compat (single activated ability)
  local activated_ability = params.activated_ability
  local ability_used_this_turn = params.ability_used_this_turn
  local ability_can_activate = params.ability_can_activate ~= false

  local strip_color = get_strip_color(faction)
  local bg_dark = { 0.08, 0.09, 0.13, 1.0 }
  local bg_card = { 0.15, 0.17, 0.22, 1.0 }
  local border = { 0.22, 0.24, 0.3, 1.0 }
  local gold_border = { 0.96, 0.78, 0.42, 1.0 }
  local text_color = { 0.82, 0.83, 0.88, 1.0 }
  local muted = { 0.58, 0.6, 0.68, 1.0 }
  local art_bg = { 0.1, 0.11, 0.15, 1.0 }

  local pad = 6

  -- ===================== CARD SHADOW =====================
  if is_base then
    -- Warm golden shadow for bases
    love.graphics.setColor(0.2, 0.15, 0.05, 0.45)
    love.graphics.rectangle("fill", x + 4, y + 5, w + 2, h + 2, 8, 8)
  else
    love.graphics.setColor(0, 0, 0, 0.45)
    love.graphics.rectangle("fill", x + 3, y + 4, w, h, 8, 8)
  end

  -- ===================== CARD BODY =====================
  love.graphics.setColor(bg_card)
  love.graphics.rectangle("fill", x, y, w, h, 6, 6)

  -- Parchment texture overlay
  love.graphics.setScissor(x, y, w, h)
  textures.draw_tiled(textures.card, x, y, w, h, 0.06)
  love.graphics.setScissor()

  -- Subtle inner glow at top
  love.graphics.setColor(1, 1, 1, 0.04)
  love.graphics.rectangle("fill", x + 3, y + 2, w - 6, 2)

  -- ===================== BORDER =====================
  love.graphics.setLineWidth(2)
  if is_base then
    -- Double border for bases: outer gold, inner dark
    love.graphics.setColor(gold_border[1], gold_border[2], gold_border[3], 0.5)
    love.graphics.rectangle("line", x - 1, y - 1, w + 2, h + 2, 7, 7)
    love.graphics.setColor(gold_border)
    love.graphics.rectangle("line", x, y, w, h, 6, 6)
  else
    love.graphics.setColor(border)
    love.graphics.rectangle("line", x, y, w, h, 6, 6)
  end
  love.graphics.setLineWidth(1)

  -- ===================== FACTION STRIP (left edge) =====================
  for i = 0, 3 do
    local a = 0.5 * (1 - i / 4)
    love.graphics.setColor(strip_color[1], strip_color[2], strip_color[3], a)
    love.graphics.rectangle("fill", x + i + 1, y + 6, 1, h - 12)
  end

  local cx, cy = x + pad, y + pad

  -- ===================== HEADER =====================
  local header_h = 22
  local header_w = w - pad * 2

  -- Header background (dark recessed bar)
  love.graphics.setColor(0.06, 0.07, 0.1, 0.8)
  love.graphics.rectangle("fill", cx, cy, header_w, header_h, 3, 3)
  -- Faction-colored top edge on header
  love.graphics.setColor(strip_color[1], strip_color[2], strip_color[3], 0.6)
  love.graphics.rectangle("fill", cx + 2, cy, header_w - 4, 2, 1, 1)

  -- Title text
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(util.get_title_font(12))
  love.graphics.print(title, cx + 5, cy + 4)

  -- Build cost icons (right-aligned in header)
  if #costs > 0 then
    local icon_s = 12
    local cost_w = measure_cost_cluster(costs, icon_s)
    local cost_x = cx + header_w - cost_w - 4
    local cost_y = cy + (header_h - icon_s) / 2
    draw_cost_cluster(costs, cost_x, cost_y, icon_s)
  end

  cy = cy + header_h + 3

  -- ===================== TYPE LINE + TIER =====================
  love.graphics.setColor(muted)
  love.graphics.setFont(util.get_font(9))
  love.graphics.print(type_line, cx + 2, cy)
  -- Tier badge (right-aligned)
  if tier and tier > 0 then
    local tier_font = util.get_font(9)
    local tier_label = "T" .. tostring(tier)
    local tw_text = tier_font:getWidth(tier_label)
    -- Small pill badge
    local pill_w = tw_text + 8
    local pill_h = 12
    local pill_x = cx + header_w - pill_w - 1
    local pill_y = cy
    love.graphics.setColor(strip_color[1], strip_color[2], strip_color[3], 0.2)
    love.graphics.rectangle("fill", pill_x, pill_y, pill_w, pill_h, 3, 3)
    love.graphics.setColor(strip_color[1], strip_color[2], strip_color[3], 0.8)
    love.graphics.setFont(tier_font)
    love.graphics.printf(tier_label, pill_x, pill_y + 1, pill_w, "center")
  end
  cy = cy + 13

  -- Population line
  if population then
    love.graphics.setColor(muted[1], muted[2], muted[3], 0.7)
    love.graphics.setFont(util.get_font(8))
    love.graphics.print("Pop " .. population, cx + 2, cy)
    cy = cy + 10
  else
    cy = cy + 2
  end

  -- ===================== ART BOX =====================
  local art_h = 62
  local art_w = header_w
  -- Art background
  love.graphics.setColor(art_bg)
  love.graphics.rectangle("fill", cx, cy, art_w, art_h, 4, 4)
  -- Art content (with scissor to clip to art box)
  love.graphics.setScissor(cx, cy, art_w, art_h)
  card_art.draw_card_art(cx, cy, art_w, art_h, kind, is_base, title or faction)
  love.graphics.setScissor()  -- Clear scissor immediately after art
  -- Inner shadow on art box
  textures.draw_inner_shadow(cx, cy, art_w, art_h, 3, 0.25)
  -- Art border
  love.graphics.setColor(0.15, 0.16, 0.2, 1)
  love.graphics.rectangle("line", cx, cy, art_w, art_h, 4, 4)
  cy = cy + art_h + 4

  -- ===================== DIVIDER =====================
  love.graphics.setColor(strip_color[1], strip_color[2], strip_color[3], 0.25)
  love.graphics.rectangle("fill", cx + 4, cy - 2, art_w - 8, 1)

  -- ===================== ABILITIES / TEXT AREA =====================
  -- Calculate how much vertical space we have before the stat bar
  local stat_bar_h = ((attack ~= nil or health ~= nil) and 24 or 0)
  local text_area_bottom = y + h - pad - stat_bar_h - 2
  local text_area_h = math.max(1, text_area_bottom - cy)  -- Ensure positive height

  -- Note: Scissor clipping disabled for scaled cards (hand) as it uses screen coords
  -- Content will render without clipping - text overflow is handled by printf width limit

  -- Draw standardized ability lines (new system)
  local ab_y = cy
  local has_activated_abilities = false
  
  if abilities_list and #abilities_list > 0 then
    for ai, ab in ipairs(abilities_list) do
      if ab.type == "activated" then
        has_activated_abilities = true
        local is_used = used_abilities[ai] or false
        local can_act = can_activate_abilities[ai] or false
        local effect_text = ability_effect_text(ab)
        if ab.once_per_turn then
          effect_text = effect_text .. " (1/turn)"
        end
        local consumed = draw_ability_line(ab, cx, ab_y, art_w, {
          can_activate = can_act,
          is_used = is_used,
          effect_text = effect_text,
        })
        ab_y = ab_y + consumed
      end
    end
  elseif activated_ability then
    -- Legacy: single activated ability rendering
    has_activated_abilities = true
    local is_used = ability_used_this_turn and activated_ability.once_per_turn
    local can_act = ability_can_activate and not is_used
    local effect_text = ability_effect_text(activated_ability)
    if activated_ability.once_per_turn then
      effect_text = effect_text .. " (1/turn)"
    end
    local consumed = draw_ability_line(activated_ability, cx, ab_y, art_w, {
      can_activate = can_act,
      is_used = is_used,
      effect_text = effect_text,
    })
    ab_y = ab_y + consumed
  end

  -- Always draw rules text if present (below abilities if any, otherwise at top of text area)
  if text and text ~= "" then
    love.graphics.setColor(text_color[1], text_color[2], text_color[3], 0.9)
    love.graphics.setFont(util.get_font(9))
    local text_y = has_activated_abilities and (ab_y + 2) or (cy + 1)
    -- Ensure text doesn't go below the stat bar
    local max_text_y = y + h - pad - stat_bar_h - 20
    if text_y < max_text_y then
      love.graphics.printf(text, cx + 2, text_y, art_w - 4, "left")
    end
  end

  -- Always clear scissor at end of text area
  love.graphics.setScissor()

  -- ===================== STAT BAR =====================
  if attack ~= nil or health ~= nil then
    local stat_y = y + h - pad - stat_bar_h
    local stat_h = 20

    if attack ~= nil then
      -- ATK badge (left)
      local sw = (art_w - 4) / 2
      love.graphics.setColor(0.5, 0.2, 0.2, 0.35)
      love.graphics.rectangle("fill", cx, stat_y, sw, stat_h, 3, 3)
      love.graphics.setColor(0.7, 0.3, 0.3, 0.5)
      love.graphics.rectangle("line", cx, stat_y, sw, stat_h, 3, 3)
      -- Bevel
      love.graphics.setColor(1, 1, 1, 0.05)
      love.graphics.rectangle("fill", cx + 1, stat_y + 1, sw - 2, 1)
      love.graphics.setColor(text_color)
      love.graphics.setFont(util.get_font(10))
      love.graphics.printf("ATK " .. tostring(attack), cx, stat_y + stat_h/2 - 6, sw, "center")
    end

    if health ~= nil then
      -- HP badge (right)
      local sw = (art_w - 4) / 2
      local right_x = cx + art_w - sw
      love.graphics.setColor(0.2, 0.35, 0.2, 0.35)
      love.graphics.rectangle("fill", right_x, stat_y, sw, stat_h, 3, 3)
      love.graphics.setColor(0.3, 0.55, 0.3, 0.5)
      love.graphics.rectangle("line", right_x, stat_y, sw, stat_h, 3, 3)
      -- Bevel
      love.graphics.setColor(1, 1, 1, 0.05)
      love.graphics.rectangle("fill", right_x + 1, stat_y + 1, sw - 2, 1)
      love.graphics.setColor(text_color)
      love.graphics.setFont(util.get_font(10))
      love.graphics.printf("HP " .. tostring(health), right_x, stat_y + stat_h/2 - 6, sw, "center")
    end
  end
end

---------------------------------------------------------
-- Resource node card (compact, full-art style)
---------------------------------------------------------
local RESOURCE_NODE_W = 120
local RESOURCE_NODE_H = 90
local RESOURCE_TITLE_BAR_H = 18

function card_frame.draw_resource_node(x, y, title, faction)
  local w, h = RESOURCE_NODE_W, RESOURCE_NODE_H
  local strip_color = get_strip_color(faction)
  local border = { 0.16, 0.18, 0.22, 1.0 }
  local text_color = { 0.82, 0.83, 0.88, 1.0 }
  local art_bg = { 0.12, 0.13, 0.18, 1.0 }

  -- Shadow
  love.graphics.setColor(0, 0, 0, 0.3)
  love.graphics.rectangle("fill", x + 3, y + 3, w, h, 6, 6)

  -- Background
  local art_h = h - RESOURCE_TITLE_BAR_H
  love.graphics.setColor(art_bg)
  love.graphics.rectangle("fill", x, y, w, h, 5, 5)
  love.graphics.setColor(border)
  love.graphics.rectangle("line", x, y, w, h, 5, 5)

  -- Draw the resource icon centered in the art area
  local t = (title or ""):lower()
  local res_type = "food"
  if t:match("wood") or t:match("forest") then res_type = "wood"
  elseif t:match("stone") or t:match("quarry") then res_type = "stone" end

  local icon_size = math.min(art_h - 12, w - 24)
  local icon_x = x + (w - icon_size) / 2
  local icon_y = y + (art_h - icon_size) / 2
  if not res_icons.draw(res_type, icon_x, icon_y, icon_size, 0.9) then
    local card_art_mod = require("src.ui.card_art")
    card_art_mod.draw_resource_art(x, y, w, art_h, title)
  end

  -- Minimal title bar at bottom
  local bar_y = y + h - RESOURCE_TITLE_BAR_H
  love.graphics.setColor(0.08, 0.09, 0.12, 0.95)
  love.graphics.rectangle("fill", x, bar_y, w, RESOURCE_TITLE_BAR_H)
  love.graphics.setColor(strip_color)
  love.graphics.rectangle("fill", x, bar_y, 3, RESOURCE_TITLE_BAR_H)
  love.graphics.setColor(text_color)
  love.graphics.setFont(util.get_font(10))
  love.graphics.print(title or "?", x + 10, bar_y + 4)
end

---------------------------------------------------------
-- Ability activation hit-test rectangles
-- Returns an array of { x, y, w, h, ability_index } for
-- all activated abilities on a card at (card_x, card_y).
---------------------------------------------------------
card_frame.ACTIVATE_ICON_SIZE = 22  -- kept for legacy compat

function card_frame.get_ability_rects(card_x, card_y, card_w, card_h, abilities_list)
  if not abilities_list then return {} end
  local rects = {}
  local pad = 6
  local header_h = 22 + 3  -- header + gap
  local type_h = 13 + 2    -- type line + pop line estimate
  local art_h = 62 + 4     -- art + gap
  local ab_y = card_y + pad + header_h + type_h + art_h
  local ab_w = card_w - pad * 2
  local line_h = 22  -- ability line height + gap

  for ai, ab in ipairs(abilities_list) do
    if ab.type == "activated" then
      rects[#rects + 1] = { x = card_x + pad, y = ab_y, w = ab_w, h = 20, ability_index = ai }
      ab_y = ab_y + line_h
    end
  end
  return rects
end

-- Legacy: rect for single activate icon (for base cards using old system)
function card_frame.activate_icon_rect(card_x, card_y, card_w, card_h)
  local pad = 6
  local header_h = 22 + 3
  local type_h = 13 + 2
  local art_h = 62 + 4
  local ab_y = card_y + pad + header_h + type_h + art_h
  local ab_w = card_w - pad * 2
  return card_x + pad, ab_y, ab_w, 20
end

card_frame.CARD_W = CARD_W
card_frame.CARD_H = CARD_H
card_frame.RESOURCE_NODE_W = RESOURCE_NODE_W
card_frame.RESOURCE_NODE_H = RESOURCE_NODE_H

-- Exported helpers for external use
card_frame.ability_effect_text = ability_effect_text
card_frame.draw_cost_cluster = draw_cost_cluster

return card_frame
