-- Board layout and drawing: two panels, slots, cards, worker tokens.
-- Exposes LAYOUT and draw(), hit_test() so state/game.lua can use the same geometry.

local card_frame = require("src.ui.card_frame")
local util = require("src.ui.util")
local deck_assets = require("src.ui.deck_assets")
local cards = require("src.game.cards")
local abilities = require("src.game.abilities")
local factions = require("src.data.factions")
local config = require("src.data.config")
local res_registry = require("src.data.resources")
local textures = require("src.fx.textures")
local res_icons = require("src.ui.res_icons")

local board = {}

local MARGIN = 20
local TOP_MARGIN = 10      -- less space above opponent's board
local GAP_BETWEEN_PANELS = 8
local MARGIN_BOTTOM = 115  -- room for resource bar + hand strip below player's board
local CARD_W = card_frame.CARD_W
local CARD_H = card_frame.CARD_H
local RESOURCE_NODE_W = card_frame.RESOURCE_NODE_W
local RESOURCE_NODE_H = card_frame.RESOURCE_NODE_H
local RESOURCE_NODE_GAP = 24
local SLOT_H = 50
local WORKER_R = 12
-- Deck slots drawn as card-shaped (same aspect as CARD_W/CARD_H)
local DECK_CARD_W = 80
local DECK_CARD_H = 110
local DECK_CARD_R = 6
local PASS_BTN_W = 90
local PASS_BTN_H = 32
local END_TURN_BTN_W = 100
local END_TURN_BTN_H = 32
local STRUCT_TILE_W = 90
local STRUCT_TILE_H = 70
local STRUCT_TILE_GAP = 8
local RESOURCE_BAR_H = 26

-- Hand card display constants
local HAND_SCALE = 0.72
local HAND_CARD_W = math.floor(CARD_W * HAND_SCALE)   -- ~115
local HAND_CARD_H = math.floor(CARD_H * HAND_SCALE)   -- ~158
local HAND_VISIBLE_FRAC = 0.55   -- fraction of card height visible at rest
local HAND_HOVER_RISE = 100      -- pixels the hovered card rises above resting position
local HAND_GAP = 6               -- gap between cards when not overlapping
local HAND_MAX_TOTAL_W = 900     -- max total width; cards overlap when exceeding this

-- Faction accent colors (read from centralized data)
local function get_faction_color(faction)
  local f = factions[faction]
  return f and f.color or { 0.5, 0.5, 0.5 }
end

-- Layout: panel 0 = bottom (you), panel 1 = top (opponent). Small gap between; less top/bottom margin.
function board.panel_rect(panel_index)
  local gw = love.graphics.getWidth()
  local gh = love.graphics.getHeight()
  local panel_h = (gh - MARGIN_BOTTOM - TOP_MARGIN - GAP_BETWEEN_PANELS) / 2
  local panel_w = gw - 2 * MARGIN
  if panel_index == 0 then
    return MARGIN, TOP_MARGIN + panel_h + GAP_BETWEEN_PANELS, panel_w, panel_h
  else
    return MARGIN, TOP_MARGIN, panel_w, panel_h
  end
end

-- Within a panel: base and resources. Opponent (panel_index==1) is mirrored: base at top (back of their board).
function board.base_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local x = panel_x + (panel_w - CARD_W) / 2
  local y
  if panel_index == 1 then
    y = panel_y + 20  -- opponent: base at top (back of their board)
  else
    y = panel_y + panel_h - CARD_H - 20  -- you: base at bottom
  end
  return x, y, CARD_W, CARD_H
end

-- Resource nodes: at each player's board edge (front line).
-- Player 0 (you): resources sit at the bottom edge of your panel.
-- Player 1 (opponent): resources sit at the top edge of their panel.
function board.resource_left_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local center_x = panel_x + panel_w * 0.25
  local x = center_x - RESOURCE_NODE_W / 2
  local y
  if panel_index == 1 then
    y = panel_y + 8  -- opponent: top edge
  else
    y = panel_y + panel_h - RESOURCE_NODE_H - 8  -- you: bottom edge
  end
  return x, y, RESOURCE_NODE_W, RESOURCE_NODE_H
end

function board.resource_right_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local center_x = panel_x + panel_w * 0.75
  local x = center_x - RESOURCE_NODE_W / 2
  local y
  if panel_index == 1 then
    y = panel_y + 8  -- opponent: top edge
  else
    y = panel_y + panel_h - RESOURCE_NODE_H - 8  -- you: bottom edge
  end
  return x, y, RESOURCE_NODE_W, RESOURCE_NODE_H
end

function board.blueprint_slot_rect(panel_x, panel_y, panel_w, panel_h)
  -- Slight padding below the player resources line
  return panel_x + 20, panel_y + 8, DECK_CARD_W, DECK_CARD_H
end

function board.worker_slot_rect(panel_x, panel_y, panel_w, panel_h)
  return panel_x + 20, panel_y + 8 + DECK_CARD_H + 8, 120, SLOT_H
end

function board.unit_slot_rect(panel_x, panel_y, panel_w, panel_h)
  return panel_x + panel_w - 20 - DECK_CARD_W, panel_y + 8, DECK_CARD_W, DECK_CARD_H
end

-- Built structures area: horizontal row between the two deck slots in the upper-middle area
function board.structures_area_rect(panel_x, panel_y, panel_w, panel_h)
  local left_edge = panel_x + 20 + DECK_CARD_W + 16  -- right of blueprint deck
  local right_edge = panel_x + panel_w - 20 - DECK_CARD_W - 16  -- left of unit deck
  local area_w = right_edge - left_edge
  local area_h = STRUCT_TILE_H
  local area_y = panel_y + 8 + (DECK_CARD_H - STRUCT_TILE_H) / 2  -- vertically centered with deck slots
  return left_edge, area_y, area_w, area_h
end

-- Get rect for a specific structure tile by index (0-based)
function board.structure_tile_rect(panel_x, panel_y, panel_w, panel_h, tile_index)
  local ax, ay, aw, ah = board.structures_area_rect(panel_x, panel_y, panel_w, panel_h)
  local tx = ax + tile_index * (STRUCT_TILE_W + STRUCT_TILE_GAP)
  return tx, ay, STRUCT_TILE_W, STRUCT_TILE_H
end

-- Resource bar: below the player's panel in the bottom margin area
function board.resource_bar_rect(panel_index)
  local px, py, pw, ph = board.panel_rect(panel_index)
  return px, py + ph + 3, pw, RESOURCE_BAR_H
end

-- Pass button: bottom left of each player's panel (for priority passing)
function board.pass_button_rect(panel_x, panel_y, panel_w, panel_h)
  return panel_x + 20, panel_y + panel_h - PASS_BTN_H - 12, PASS_BTN_W, PASS_BTN_H
end

-- End turn button: bottom right of each player's panel
function board.end_turn_button_rect(panel_x, panel_y, panel_w, panel_h)
  return panel_x + panel_w - END_TURN_BTN_W - 20, panel_y + panel_h - END_TURN_BTN_H - 12, END_TURN_BTN_W, END_TURN_BTN_H
end

-- Unassigned workers pool: bottom left, to the right of the Pass button (small fixed width)
local UNASSIGNED_POOL_W = 100
local UNASSIGNED_POOL_H = 36

function board.unassigned_pool_rect(panel_x, panel_y, panel_w, panel_h, player)
  local pass_x, pass_y, pass_w, pass_h = board.pass_button_rect(panel_x, panel_y, panel_w, panel_h)
  local gap = 8
  local pool_x = panel_x + 20 + PASS_BTN_W + gap
  local pool_y = pass_y + pass_h / 2 - UNASSIGNED_POOL_H / 2
  return pool_x, pool_y, UNASSIGNED_POOL_W, UNASSIGNED_POOL_H
end

-- Worker circles on a resource: centered row on top of the full-art card (bottom of card, above title bar)
function board.worker_circle_center(panel_x, panel_y, panel_w, panel_h, resource_side, index, total_count, panel_index)
  local rx, ry, rw, rh
  if resource_side == "left" then
    rx, ry, rw, rh = board.resource_left_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  else
    rx, ry, rw, rh = board.resource_right_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  end
  local row_y = ry + rh - 22
  local spacing = WORKER_R * 2 + 4
  local n = total_count and math.max(1, total_count) or 1
  local row_w = n * spacing - 4
  local first_x = rx + (rw - row_w) / 2 + (index - 1) * spacing
  return first_x + WORKER_R, row_y + WORKER_R
end

-- Hand card layout: returns array of {x, y, w, h} rects for each card in hand
-- y_offsets: table of per-card animated y offsets (negative = raised); nil = all 0
function board.hand_card_rects(hand_size, y_offsets)
  local gw = love.graphics.getWidth()
  local gh = love.graphics.getHeight()
  if hand_size == 0 then return {} end

  -- Calculate spacing: ideal = full card width + gap; compress if too wide
  local ideal_w = hand_size * (HAND_CARD_W + HAND_GAP) - HAND_GAP
  local actual_w = math.min(ideal_w, HAND_MAX_TOTAL_W)
  local step
  if hand_size > 1 then
    step = (actual_w - HAND_CARD_W) / (hand_size - 1)
  else
    step = 0
  end

  -- Center horizontally
  local start_x = (gw - actual_w) / 2
  if hand_size == 1 then start_x = (gw - HAND_CARD_W) / 2 end

  -- Base y: bottom of screen with VISIBLE_FRAC showing
  local visible_h = math.floor(HAND_CARD_H * HAND_VISIBLE_FRAC)
  local base_y = gh - visible_h

  local rects = {}
  for i = 1, hand_size do
    local x = start_x + (i - 1) * step
    local y = base_y + (y_offsets and y_offsets[i] or 0)
    rects[i] = { x = x, y = y, w = HAND_CARD_W, h = HAND_CARD_H }
  end
  return rects
end

-- Helper: check if hover matches a specific kind+panel
local function is_hovered(hover, kind, pi)
  return hover and hover.kind == kind and hover.pi == pi
end

-- Helper: draw a colored resource badge with PNG icon
local function draw_resource_badge(x, y, res_type, letter, count, r, g, b, display_val)
  local icon_size = 18
  local badge_w = 50
  local badge_h = 22
  local show = display_val or count
  local rolling = display_val and math.abs(display_val - count) > 0.5
  -- Beveled pill background
  love.graphics.setColor(r * 0.15, g * 0.15, b * 0.15, 0.9)
  love.graphics.rectangle("fill", x, y, badge_w, badge_h, 5, 5)
  -- Top highlight
  love.graphics.setColor(r, g, b, rolling and 0.35 or 0.15)
  love.graphics.rectangle("fill", x + 1, y + 1, badge_w - 2, 1)
  -- Bottom shadow
  love.graphics.setColor(0, 0, 0, 0.3)
  love.graphics.rectangle("fill", x + 1, y + badge_h - 2, badge_w - 2, 1)
  -- Border
  love.graphics.setColor(r, g, b, rolling and 0.7 or 0.4)
  love.graphics.rectangle("line", x, y, badge_w, badge_h, 5, 5)
  -- PNG icon (centered vertically in badge)
  local icon_y = y + (badge_h - icon_size) / 2
  res_icons.draw(res_type, x + 2, icon_y, icon_size)
  -- Number text
  love.graphics.setFont(util.get_font(13))
  love.graphics.setColor(r, g, b, 1.0)
  love.graphics.print(tostring(math.floor(show + 0.5)), x + icon_size + 5, y + 3)
  return badge_w + 4
end

-- Helper: draw a worker count badge with icon
local function draw_worker_badge(x, y, current, max_w)
  local badge_w = 56
  local badge_h = 22
  -- Background
  love.graphics.setColor(0.08, 0.08, 0.12, 0.9)
  love.graphics.rectangle("fill", x, y, badge_w, badge_h, 5, 5)
  love.graphics.setColor(0.5, 0.5, 0.7, 0.12)
  love.graphics.rectangle("fill", x + 1, y + 1, badge_w - 2, 1)
  love.graphics.setColor(0, 0, 0, 0.3)
  love.graphics.rectangle("fill", x + 1, y + badge_h - 2, badge_w - 2, 1)
  love.graphics.setColor(0.5, 0.5, 0.65, 0.4)
  love.graphics.rectangle("line", x, y, badge_w, badge_h, 5, 5)
  -- Worker icon: small circle person
  love.graphics.setColor(0.7, 0.72, 0.85, 0.9)
  love.graphics.circle("fill", x + 10, y + 8, 3.5)
  love.graphics.rectangle("fill", x + 7, y + 12, 6, 5, 1, 1)
  -- Text
  love.graphics.setFont(util.get_font(12))
  love.graphics.setColor(0.75, 0.76, 0.88, 1.0)
  love.graphics.print(current .. "/" .. max_w, x + 20, y + 4)
  return badge_w + 4
end

-- Helper: draw pulsing drop zone glow around a rect
local function draw_drop_zone_glow(x, y, w, h, t)
  local pulse = 0.4 + 0.3 * math.sin(t * 4)
  love.graphics.setColor(0.3, 0.6, 1.0, pulse)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", x - 3, y - 3, w + 6, h + 6, 6, 6)
  love.graphics.setLineWidth(1)
end

-- Draw worker token with 3D sphere shading, shadow, optional glow
local function draw_worker_circle(cx, cy, is_active_panel, is_draggable, is_hovered_worker)
  local t = love.timer.getTime()
  local r = WORKER_R
  if is_draggable then
    r = WORKER_R + 0.8 * math.sin(t * 3)
  end
  local alpha = is_active_panel and 1.0 or 0.7
  -- Drop shadow
  love.graphics.setColor(0, 0, 0, 0.4 * alpha)
  love.graphics.circle("fill", cx + 2, cy + 3, r + 1)
  -- Hover glow
  if is_hovered_worker and is_active_panel then
    love.graphics.setColor(0.4, 0.5, 1.0, 0.25 + 0.1 * math.sin(t * 4))
    love.graphics.circle("fill", cx, cy, r + 4)
  end
  -- Radial gradient: draw 4 concentric fills lighter -> darker
  local layers = 4
  for i = layers, 1, -1 do
    local frac = i / layers
    local lr = r * frac
    -- Shift highlight toward top-left
    local offx = -r * 0.15 * (1 - frac)
    local offy = -r * 0.2 * (1 - frac)
    local brightness
    if is_active_panel then
      brightness = 0.55 + 0.45 * (1 - frac)
    else
      brightness = 0.4 + 0.3 * (1 - frac)
    end
    love.graphics.setColor(brightness * 0.9, brightness * 0.9, brightness * 1.1, alpha)
    love.graphics.circle("fill", cx + offx, cy + offy, lr)
  end
  -- Specular highlight (small bright spot top-left)
  love.graphics.setColor(1, 1, 1, 0.35 * alpha)
  love.graphics.circle("fill", cx - r * 0.25, cy - r * 0.25, r * 0.3)
  -- Rim outline
  if is_active_panel then
    love.graphics.setColor(0.45, 0.5, 0.9, 0.7)
  else
    love.graphics.setColor(0.35, 0.38, 0.55, 0.5)
  end
  love.graphics.circle("line", cx, cy, r)
end

-- Helper: draw a beveled button (gradient fill, top/bottom edge highlights, hover glow, press offset)
local function draw_button(bx, by, bw, bh, label, is_hov, is_press, accent_r, accent_g, accent_b)
  local t = love.timer.getTime()
  local press_offset = is_press and 1 or 0
  local dy = by + press_offset

  -- Outer shadow
  love.graphics.setColor(0, 0, 0, 0.3)
  love.graphics.rectangle("fill", bx + 2, by + 3, bw, bh, 5, 5)

  -- Fill: vertical gradient (lighter top, darker bottom)
  local top_r, top_g, top_b = accent_r or 0.2, accent_g or 0.22, accent_b or 0.28
  local steps = 8
  for i = 0, steps - 1 do
    local frac = i / steps
    local sy = dy + frac * bh
    local sh = bh / steps + 1
    local dim = 1 - frac * 0.3
    if is_hov then dim = dim + 0.08 end
    if is_press then dim = dim - 0.1 end
    love.graphics.setColor(top_r * dim, top_g * dim, top_b * dim, 1.0)
    love.graphics.rectangle("fill", bx, sy, bw, sh, (i == 0 and 5 or 0), (i == 0 and 5 or 0))
  end
  -- Clean rounded rect on top to fix gradient corners
  love.graphics.setColor(top_r * 0.85, top_g * 0.85, top_b * 0.85, 1.0)
  love.graphics.rectangle("fill", bx, dy, bw, bh, 5, 5)
  -- Re-draw gradient inside
  love.graphics.setScissor(bx, dy, bw, bh)
  for i = 0, steps - 1 do
    local frac = i / steps
    local sy = dy + frac * bh
    local sh = bh / steps + 1
    local dim = 1 - frac * 0.3
    if is_hov then dim = dim + 0.08 end
    if is_press then dim = dim - 0.1 end
    love.graphics.setColor(top_r * dim, top_g * dim, top_b * dim, 1.0)
    love.graphics.rectangle("fill", bx, sy, bw, sh)
  end
  love.graphics.setScissor()

  -- Top highlight edge
  if not is_press then
    love.graphics.setColor(1, 1, 1, 0.1)
    love.graphics.rectangle("fill", bx + 2, dy + 1, bw - 4, 1)
  end
  -- Bottom shadow edge
  love.graphics.setColor(0, 0, 0, 0.25)
  love.graphics.rectangle("fill", bx + 2, dy + bh - 2, bw - 4, 1)

  -- Border
  love.graphics.setColor(top_r * 1.3, top_g * 1.3, top_b * 1.3, 0.6)
  love.graphics.rectangle("line", bx, dy, bw, bh, 5, 5)

  -- Hover glow
  if is_hov and not is_press then
    love.graphics.setColor(accent_r or 0.5, accent_g or 0.5, accent_b or 0.7, 0.12 + 0.05 * math.sin(t * 4))
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", bx - 1, dy - 1, bw + 2, bh + 2, 6, 6)
    love.graphics.setLineWidth(1)
  end

  -- Label text
  love.graphics.setColor(0.9, 0.91, 0.95, 1.0)
  love.graphics.setFont(util.get_font(13))
  local tw = util.get_font(13):getWidth(label)
  love.graphics.print(label, bx + (bw - tw) / 2, dy + (bh - 13) / 2)
end

function board.draw(game_state, drag, hover, mouse_down, display_resources, hand_state)
  -- Lazy-init textures on first draw (must happen during love.draw, not love.load)
  textures.init()

  local gw = love.graphics.getWidth()
  local gh = love.graphics.getHeight()
  local t = love.timer.getTime()

  -- Background gradient (dark navy to dark gray, top to bottom)
  local grad_steps = 32
  for i = 0, grad_steps - 1 do
    local frac = i / grad_steps
    local gy = frac * gh
    local step_h = gh / grad_steps + 1
    local r = 0.06 + frac * 0.04
    local g = 0.07 + frac * 0.03
    local b = 0.12 - frac * 0.02
    love.graphics.setColor(r, g, b, 1.0)
    love.graphics.rectangle("fill", 0, gy, gw, step_h)
  end

  -- Noise texture overlay on background
  textures.draw_tiled(textures.noise, 0, 0, gw, gh, 0.04)

  -- Radial warm glow behind active player's panel
  local active_pi = game_state.activePlayer
  local active_player = game_state.players[active_pi + 1]
  local active_accent = get_faction_color(active_player.faction)
  local apx, apy, apw, aph = board.panel_rect(active_pi)
  love.graphics.setColor(active_accent[1], active_accent[2], active_accent[3], 0.06)
  love.graphics.ellipse("fill", apx + apw / 2, apy + aph / 2, apw * 0.5, aph * 0.6)

  for pi = 0, 1 do
    local px, py, pw, ph = board.panel_rect(pi)
    local player = game_state.players[pi + 1]
    local base_def = cards.get_card_def(player.baseId)
    local is_active = (game_state.activePlayer == pi)
    local faction = player.faction
    local accent = get_faction_color(faction)

    -- Panel outer shadow
    love.graphics.setColor(0, 0, 0, 0.35)
    love.graphics.rectangle("fill", px + 3, py + 4, pw, ph, 8, 8)

    -- Panel bg (slightly dimmed if inactive)
    if is_active then
      love.graphics.setColor(0.11, 0.12, 0.15, 1.0)
    else
      love.graphics.setColor(0.09, 0.10, 0.12, 0.85)
    end
    love.graphics.rectangle("fill", px, py, pw, ph, 8, 8)

    -- Panel texture overlay
    love.graphics.setScissor(px, py, pw, ph)
    textures.draw_tiled(textures.panel, px, py, pw, ph, 0.06)
    love.graphics.setScissor()

    -- Inner shadow (4 edges)
    textures.draw_inner_shadow(px, py, pw, ph, 5, 0.2)

    -- Panel border
    love.graphics.setColor(0.18, 0.20, 0.25, 1.0)
    love.graphics.rectangle("line", px, py, pw, ph, 8, 8)

    -- Active panel: colored left+right accent border
    if is_active then
      love.graphics.setColor(accent[1], accent[2], accent[3], 0.7)
      love.graphics.rectangle("fill", px, py + 4, 3, ph - 8)
      love.graphics.rectangle("fill", px + pw - 3, py + 4, 3, ph - 8)
    end

    -- Accent line at top of panel
    love.graphics.setColor(accent[1], accent[2], accent[3], 0.5)
    love.graphics.rectangle("fill", px + 4, py + 1, pw - 8, 1)

    -- Shared variables for resource bar (drawn later)
    local max_workers = player.maxWorkers or 8
    local dr = display_resources and display_resources[pi + 1]

    -- Draw deck card: use card back image if present, else placeholder with label
    local function draw_deck_card(rx, ry, rw, rh, label, card_back_img)
      if card_back_img then
        deck_assets.draw_card_back(card_back_img, rx, ry, rw, rh, DECK_CARD_R)
      else
        love.graphics.setColor(0.15, 0.16, 0.2, 1.0)
        love.graphics.rectangle("fill", rx, ry, rw, rh, DECK_CARD_R, DECK_CARD_R)
        love.graphics.setColor(0.2, 0.22, 0.28, 1.0)
        love.graphics.rectangle("line", rx, ry, rw, rh, DECK_CARD_R, DECK_CARD_R)
        love.graphics.setColor(0.7, 0.72, 0.78, 1.0)
        love.graphics.setFont(util.get_font(10))
        love.graphics.printf(label, rx + 4, ry + rh/2 - 18, rw - 8, "center")
      end
    end
    local bx, by, bw, bh = board.blueprint_slot_rect(px, py, pw, ph)
    draw_deck_card(bx, by, bw, bh, "Blueprint\nDeck", deck_assets.get_blueprint_back())
    local ux, uy, uw, uh = board.unit_slot_rect(px, py, pw, ph)
    draw_deck_card(ux, uy, uw, uh, "Unit\nDeck", deck_assets.get_unit_back())

    -- Built structures: compact tiles with polish (inner shadow, texture, hover glow)
    if #player.board > 0 then
      local sax, say, saw, sah = board.structures_area_rect(px, py, pw, ph)
      for si, entry in ipairs(player.board) do
        local ok, sdef = pcall(cards.get_card_def, entry.card_id)
        if ok and sdef then
          local tx, ty, tw, th = board.structure_tile_rect(px, py, pw, ph, si - 1)
          if tx + tw <= sax + saw + 2 then
            local scale = (entry.scale == nil) and 1 or entry.scale
            local tile_cx, tile_cy = tx + tw / 2, ty + th / 2

            -- Check hover for glow
            local tile_hovered = hover and hover.kind == "structure" and hover.pi == pi and hover.idx == si

            if scale ~= 1 then
              love.graphics.push()
              love.graphics.translate(tile_cx, tile_cy)
              love.graphics.scale(scale)
              love.graphics.translate(-tile_cx, -tile_cy)
            end
            -- Hover: slight scale-up effect via glow
            if tile_hovered and scale == 1 then
              love.graphics.setColor(accent[1], accent[2], accent[3], 0.15 + 0.05 * math.sin(t * 4))
              love.graphics.rectangle("fill", tx - 2, ty - 2, tw + 4, th + 4, 6, 6)
            end
            -- Tile shadow
            love.graphics.setColor(0, 0, 0, 0.25)
            love.graphics.rectangle("fill", tx + 2, ty + 3, tw, th, 5, 5)
            -- Tile background
            if is_active then
              love.graphics.setColor(0.14, 0.15, 0.2, 1.0)
            else
              love.graphics.setColor(0.11, 0.12, 0.16, 0.85)
            end
            love.graphics.rectangle("fill", tx, ty, tw, th, 5, 5)
            -- Texture overlay on tile
            love.graphics.setScissor(tx, ty, tw, th)
            textures.draw_tiled(textures.panel, tx, ty, tw, th, 0.05)
            love.graphics.setScissor()
            -- Inner shadow
            textures.draw_inner_shadow(tx, ty, tw, th, 3, 0.15)
            -- Faction-colored left gradient strip
            for gi = 0, 5 do
              local ga = (is_active and 0.6 or 0.3) * (1 - gi / 6)
              love.graphics.setColor(accent[1], accent[2], accent[3], ga)
              love.graphics.rectangle("fill", tx + gi, ty + 3, 1, th - 6)
            end
            -- Border
            love.graphics.setColor(0.22, 0.24, 0.3, is_active and 1.0 or 0.6)
            love.graphics.rectangle("line", tx, ty, tw, th, 5, 5)
            -- Structure name (title font)
            love.graphics.setColor(1, 1, 1, is_active and 1.0 or 0.6)
            love.graphics.setFont(util.get_title_font(11))
            love.graphics.printf(sdef.name, tx + 8, ty + 5, tw - 12, "left")
            -- Kind label
            love.graphics.setColor(0.6, 0.62, 0.7, is_active and 0.8 or 0.5)
            love.graphics.setFont(util.get_font(9))
            love.graphics.print("Structure", tx + 8, ty + 22)
            -- Small ability hint
            local ab_hint = nil
            if sdef.abilities then
              for _, ab in ipairs(sdef.abilities) do
                if ab.type == "activated" then ab_hint = "ACT"; break
                elseif ab.type == "static" and ab.effect == "produce" then ab_hint = "PROD"; break
                elseif ab.type == "triggered" then ab_hint = "TRIG"; break
                end
              end
            end
            if ab_hint then
              local badge_w = 32
              love.graphics.setColor(accent[1], accent[2], accent[3], is_active and 0.3 or 0.15)
              love.graphics.rectangle("fill", tx + tw - badge_w - 4, ty + th - 18, badge_w, 14, 3, 3)
              love.graphics.setColor(accent[1], accent[2], accent[3], is_active and 0.9 or 0.5)
              love.graphics.setFont(util.get_font(8))
              love.graphics.printf(ab_hint, tx + tw - badge_w - 4, ty + th - 16, badge_w, "center")
            end
            if scale ~= 1 then
              love.graphics.pop()
            end
          end
        end
      end
    end

    -- Base card (with activated ability icon if applicable)
    local base_x, base_y = board.base_rect(px, py, pw, ph, pi)

    -- Build per-ability used/can_activate tables for the base
    local base_used_abs = {}
    local base_can_act_abs = {}
    if base_def.abilities then
      for ai, ab in ipairs(base_def.abilities) do
        if ab.type == "activated" then
          local key = tostring(pi) .. ":base:" .. ai
          local used = game_state.activatedUsedThisTurn and game_state.activatedUsedThisTurn[key]
          base_used_abs[ai] = used or false
          base_can_act_abs[ai] = (not used or not ab.once_per_turn) and abilities.can_pay_cost(player.resources, ab.cost) and pi == game_state.activePlayer
        end
      end
    end
    card_frame.draw(base_x, base_y, {
      title = base_def.name,
      faction = player.faction,
      kind = "Base",
      typeLine = player.faction .. " — Base",
      text = base_def.text,
      costs = base_def.costs,
      health = player.life,
      population = base_def.population,
      tier = base_def.tier,
      is_base = true,
      abilities_list = base_def.abilities,
      used_abilities = base_used_abs,
      can_activate_abilities = base_can_act_abs,
    })

    -- Resource nodes: title + placeholder only, centered in panel
    local res_left_title = (player.faction == "Human") and "Wood" or "Food"
    local res_left_resource = (player.faction == "Human") and "wood" or "food"
    local rl_x, rl_y, rl_w, rl_h = board.resource_left_rect(px, py, pw, ph, pi)

    -- Drop zone glow on resource nodes when dragging
    if drag and drag.player_index == pi then
      if drag.from ~= "left" then
        draw_drop_zone_glow(rl_x, rl_y, rl_w, rl_h, t)
      end
    end

    card_frame.draw_resource_node(rl_x, rl_y, res_left_title, player.faction)
    local n_left = player.workersOn[res_left_resource]
    if drag and drag.player_index == pi and drag.from == "left" and n_left > 0 then n_left = n_left - 1 end
    for i = 1, n_left do
      local wcx, wcy = board.worker_circle_center(px, py, pw, ph, "left", i, n_left, pi)
      draw_worker_circle(wcx, wcy, is_active, is_active)
    end

    local rr_x, rr_y, rr_w, rr_h = board.resource_right_rect(px, py, pw, ph, pi)

    -- Drop zone glow on right resource when dragging
    if drag and drag.player_index == pi then
      if drag.from ~= "right" then
        draw_drop_zone_glow(rr_x, rr_y, rr_w, rr_h, t)
      end
    end

    card_frame.draw_resource_node(rr_x, rr_y, "Stone", player.faction)
    local n_stone = player.workersOn.stone
    if drag and drag.player_index == pi and drag.from == "right" and n_stone > 0 then n_stone = n_stone - 1 end
    for i = 1, n_stone do
      local wcx, wcy = board.worker_circle_center(px, py, pw, ph, "right", i, n_stone, pi)
      draw_worker_circle(wcx, wcy, is_active, is_active)
    end

    -- Unassigned workers pool (centered); hide one if we're dragging from this pool
    local uax, uay, uaw, uah = board.unassigned_pool_rect(px, py, pw, ph, player)

    -- Drop zone glow on unassigned pool when dragging from a resource
    if drag and drag.player_index == pi and drag.from ~= "unassigned" then
      draw_drop_zone_glow(uax, uay, uaw, uah, t)
    end

    -- Unassigned pool background with depth
    love.graphics.setColor(0, 0, 0, 0.2)
    love.graphics.rectangle("fill", uax + 2, uay + 2, uaw, uah, 5, 5)
    love.graphics.setColor(0.09, 0.1, 0.13, 1.0)
    love.graphics.rectangle("fill", uax, uay, uaw, uah, 5, 5)
    textures.draw_inner_shadow(uax, uay, uaw, uah, 3, 0.15)
    love.graphics.setColor(0.2, 0.22, 0.28, 0.8)
    love.graphics.rectangle("line", uax, uay, uaw, uah, 5, 5)
    local unassigned = player.totalWorkers - player.workersOn.food - player.workersOn.wood - player.workersOn.stone
    local draw_count = unassigned
    if drag and drag.player_index == pi and drag.from == "unassigned" and unassigned > 0 then
      draw_count = unassigned - 1
    end
    local total_w = draw_count * (WORKER_R * 2 + 4) - 4
    if total_w < 0 then total_w = 0 end
    local start_x = uax + uaw / 2 - total_w / 2 + WORKER_R
    for i = 1, draw_count do
      local wcx = start_x + (i - 1) * (WORKER_R * 2 + 4)
      local wcy = uay + uah / 2
      draw_worker_circle(wcx, wcy, is_active, is_active)
    end

    -- Pass button (beveled style)
    local pbx, pby, pbw, pbh = board.pass_button_rect(px, py, pw, ph)
    local pass_hovered = is_hovered(hover, "pass", pi)
    local pass_pressed = pass_hovered and mouse_down
    draw_button(pbx, pby, pbw, pbh, "Pass", pass_hovered, pass_pressed, 0.2, 0.22, 0.28)

    -- End Turn button (beveled, with active accent)
    local ebx, eby, ebw, ebh = board.end_turn_button_rect(px, py, pw, ph)
    local et_hovered = is_hovered(hover, "end_turn", pi)
    local et_pressed = et_hovered and mouse_down
    if is_active then
      draw_button(ebx, eby, ebw, ebh, "End Turn", et_hovered, et_pressed, 0.14, 0.28, 0.22)
    else
      draw_button(ebx, eby, ebw, ebh, "End Turn", et_hovered, et_pressed, 0.2, 0.22, 0.28)
    end

    -- Resource bar (player only — below panel in the bottom margin)
    if pi == 0 then
      local rbx, rby, rbw, rbh = board.resource_bar_rect(pi)
      -- Background
      love.graphics.setColor(0.06, 0.07, 0.10, 0.92)
      love.graphics.rectangle("fill", rbx, rby, rbw, rbh, 5, 5)
      -- Accent line at top
      love.graphics.setColor(accent[1], accent[2], accent[3], 0.4)
      love.graphics.rectangle("fill", rbx + 4, rby, rbw - 8, 1)
      -- Subtle border
      love.graphics.setColor(0.18, 0.20, 0.25, 0.6)
      love.graphics.rectangle("line", rbx, rby, rbw, rbh, 5, 5)
      -- Resource badges (conditional: only show when count > 0)
      local badge_x = rbx + 8
      local badge_cy = rby + (rbh - 22) / 2
      for _, key in ipairs(config.resource_types) do
        local count = player.resources[key] or 0
        local display_val = dr and dr[key]
        if count > 0 or (display_val and display_val > 0.5) then
          local rdef = res_registry[key]
          if rdef then
            local rc, gc, bc = rdef.color[1], rdef.color[2], rdef.color[3]
            badge_x = badge_x + draw_resource_badge(badge_x, badge_cy, key, rdef.letter, count, rc, gc, bc, display_val)
          end
        end
      end
      draw_worker_badge(badge_x, badge_cy, player.totalWorkers, max_workers)
    end
  end

  -- =========================================================
  -- Hand cards (player 0 only, drawn on top of the board)
  -- =========================================================
  hand_state = hand_state or {}
  local player0 = game_state.players[1]
  local hand = player0.hand
  if #hand > 0 then
    local hover_idx = hand_state.hover_index
    local selected_idx = hand_state.selected_index
    local y_offsets = hand_state.y_offsets
    local rects = board.hand_card_rects(#hand, y_offsets)
    local accent0 = get_faction_color(player0.faction)

    -- Draw non-hovered cards first (left to right)
    for i = 1, #hand do
      if i ~= hover_idx then
        local r = rects[i]
        local ok, def = pcall(cards.get_card_def, hand[i])
        if ok and def then
          -- Card shadow
          love.graphics.setColor(0, 0, 0, 0.4)
          love.graphics.rectangle("fill", r.x + 2, r.y + 3, r.w, r.h, 5, 5)
          -- Draw scaled card using transform
          love.graphics.push()
          love.graphics.translate(r.x, r.y)
          love.graphics.scale(HAND_SCALE)
          card_frame.draw(0, 0, {
            title = def.name,
            faction = def.faction,
            kind = def.kind,
            typeLine = (def.subtypes and #def.subtypes > 0)
              and (def.faction .. " — " .. table.concat(def.subtypes, ", "))
              or (def.faction .. " — " .. def.kind),
            text = def.text,
            costs = def.costs,
            attack = def.attack,
            health = def.health,
            population = def.population,
            tier = def.tier,
            abilities_list = def.abilities,
          })
          love.graphics.pop()
          -- Selected glow
          if i == selected_idx then
            love.graphics.setColor(accent0[1], accent0[2], accent0[3], 0.5 + 0.15 * math.sin(t * 5))
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", r.x - 2, r.y - 2, r.w + 4, r.h + 4, 6, 6)
            love.graphics.setLineWidth(1)
          end
        end
      end
    end

    -- Draw hovered card last (on top, raised)
    if hover_idx and hover_idx >= 1 and hover_idx <= #hand then
      local r = rects[hover_idx]
      local ok, def = pcall(cards.get_card_def, hand[hover_idx])
      if ok and def then
        -- Larger shadow for lifted card
        love.graphics.setColor(0, 0, 0, 0.55)
        love.graphics.rectangle("fill", r.x + 4, r.y + 6, r.w, r.h, 5, 5)
        -- Subtle glow behind
        love.graphics.setColor(accent0[1], accent0[2], accent0[3], 0.2)
        love.graphics.rectangle("fill", r.x - 4, r.y - 4, r.w + 8, r.h + 8, 8, 8)
        -- Draw scaled card
        love.graphics.push()
        love.graphics.translate(r.x, r.y)
        love.graphics.scale(HAND_SCALE)
        card_frame.draw(0, 0, {
          title = def.name,
          faction = def.faction,
          kind = def.kind,
          typeLine = (def.subtypes and #def.subtypes > 0)
            and (def.faction .. " — " .. table.concat(def.subtypes, ", "))
            or (def.faction .. " — " .. def.kind),
          text = def.text,
          costs = def.costs,
          attack = def.attack,
          health = def.health,
          population = def.population,
          tier = def.tier,
          abilities_list = def.abilities,
        })
        love.graphics.pop()
        -- Bright hover border
        love.graphics.setColor(accent0[1], accent0[2], accent0[3], 0.8)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", r.x - 1, r.y - 1, r.w + 2, r.h + 2, 6, 6)
        love.graphics.setLineWidth(1)
        -- Selected indicator
        if hover_idx == selected_idx then
          love.graphics.setColor(1, 1, 1, 0.4 + 0.15 * math.sin(t * 5))
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", r.x - 3, r.y - 3, r.w + 6, r.h + 6, 7, 7)
          love.graphics.setLineWidth(1)
        end
      end
    end

    -- (Deck count shown via tooltip on hover -- see hit_test "unit_deck")
  end
end

-- Hit test: return "activate_base" | "blueprint" | "worker_*" | "resource_*" | "unassigned_pool" | "pass" | "end_turn" | "hand_card" | nil
function board.hit_test(mx, my, game_state, hand_y_offsets)
  -- Check hand cards first (drawn on top of everything; player 0 only)
  local player0 = game_state.players[1]
  if #player0.hand > 0 then
    local rects = board.hand_card_rects(#player0.hand, hand_y_offsets)
    -- Check in reverse order (rightmost / topmost card first)
    for i = #rects, 1, -1 do
      local r = rects[i]
      if util.point_in_rect(mx, my, r.x, r.y, r.w, r.h) then
        return "hand_card", 0, i
      end
    end
  end

  for pi = 0, 1 do
    local px, py, pw, ph = board.panel_rect(pi)
    local player = game_state.players[pi + 1]
    local res_left = (player.faction == "Human") and "wood" or "food"

    -- Pass and End turn on both panels (for testing either can end turn)
    local pbx, pby, pbw, pbh = board.pass_button_rect(px, py, pw, ph)
    if util.point_in_rect(mx, my, pbx, pby, pbw, pbh) then
      return "pass", pi
    end
    local ebx, eby, ebw, ebh = board.end_turn_button_rect(px, py, pw, ph)
    if util.point_in_rect(mx, my, ebx, eby, ebw, ebh) then
      return "end_turn", pi
    end

    -- Activate base ability (new: per-ability rects)
    local base_x, base_y = board.base_rect(px, py, pw, ph, pi)
    local base_def = cards.get_card_def(player.baseId)

    if base_def.abilities and pi == game_state.activePlayer then
      local ab_rects = card_frame.get_ability_rects(base_x, base_y, CARD_W, CARD_H, base_def.abilities)
      for _, ar in ipairs(ab_rects) do
        local ai = ar.ability_index
        local ab = base_def.abilities[ai]
        local key = tostring(pi) .. ":base:" .. ai
        local used = game_state.activatedUsedThisTurn and game_state.activatedUsedThisTurn[key]
        local can_act = (not ab.once_per_turn or not used) and abilities.can_pay_cost(player.resources, ab.cost)
        if can_act and util.point_in_rect(mx, my, ar.x, ar.y, ar.w, ar.h) then
          return "activate_ability", pi, { source = "base", ability_index = ai }
        end
      end
    end

    -- Built structures
    for si, entry in ipairs(player.board) do
      local tx, ty, tw, th = board.structure_tile_rect(px, py, pw, ph, si - 1)
      if util.point_in_rect(mx, my, tx, ty, tw, th) then
        return "structure", pi, si
      end
    end

    local bx, by, bw, bh = board.blueprint_slot_rect(px, py, pw, ph)
    if util.point_in_rect(mx, my, bx, by, bw, bh) then
      return "blueprint", pi
    end

    local udx, udy, udw, udh = board.unit_slot_rect(px, py, pw, ph)
    if util.point_in_rect(mx, my, udx, udy, udw, udh) then
      return "unit_deck", pi
    end

    local uax, uay, uaw, uah = board.unassigned_pool_rect(px, py, pw, ph, player)
    if util.point_in_rect(mx, my, uax, uay, uaw, uah) then
      local unassigned = player.totalWorkers - player.workersOn.food - player.workersOn.wood - player.workersOn.stone
      local total_w = unassigned * (WORKER_R * 2 + 4) - 4
      local start_x = uax + uaw / 2 - total_w / 2 + WORKER_R
      for i = 1, unassigned do
        local cx = start_x + (i - 1) * (WORKER_R * 2 + 4)
        local cy = uay + uah / 2
        if (mx - cx)^2 + (my - cy)^2 <= WORKER_R^2 then
          return "worker_unassigned", pi, nil
        end
      end
      return "unassigned_pool", pi
    end

    for i = 1, player.workersOn[res_left] do
      local cx, cy = board.worker_circle_center(px, py, pw, ph, "left", i, player.workersOn[res_left], pi)
      if (mx - cx)^2 + (my - cy)^2 <= WORKER_R^2 then
        return "worker_left", pi, i
      end
    end
    for i = 1, player.workersOn.stone do
      local cx, cy = board.worker_circle_center(px, py, pw, ph, "right", i, player.workersOn.stone, pi)
      if (mx - cx)^2 + (my - cy)^2 <= WORKER_R^2 then
        return "worker_right", pi, i
      end
    end

    local rl_x, rl_y, rl_w, rl_h = board.resource_left_rect(px, py, pw, ph, pi)
    if util.point_in_rect(mx, my, rl_x, rl_y, rl_w, rl_h) then
      return "resource_left", pi
    end
    local rr_x, rr_y, rr_w, rr_h = board.resource_right_rect(px, py, pw, ph, pi)
    if util.point_in_rect(mx, my, rr_x, rr_y, rr_w, rr_h) then
      return "resource_right", pi
    end
  end
  return nil
end

board.WORKER_R = WORKER_R
board.HAND_SCALE = HAND_SCALE
board.HAND_CARD_W = HAND_CARD_W
board.HAND_CARD_H = HAND_CARD_H
board.HAND_HOVER_RISE = HAND_HOVER_RISE

return board
