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

local actions = require("src.game.actions")

local board = {}

local MARGIN = 20
local TOP_MARGIN = 10      -- less space above opponent's board
local GAP_BETWEEN_PANELS = 8
local MARGIN_BOTTOM = 85  -- room for hand strip below player's board
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
local STRUCT_TILE_H_BASE = 50
local STRUCT_TILE_AB_H = 26
local STRUCT_TILE_GAP = 8
local BASE_CARD_H = 170
local RESOURCE_BAR_H = 26

-- Battlefield layout: two-row system (structures in back, units in front)
local BFIELD_TILE_W = 85
local BFIELD_TILE_H = 95
local BFIELD_GAP = 8
local BFIELD_ROW_GAP = 8

-- Hand card display constants
local HAND_SCALE = 0.72
local HAND_CARD_W = math.floor(CARD_W * HAND_SCALE)   -- ~115
local HAND_CARD_H = math.floor(CARD_H * HAND_SCALE)   -- ~158
local HAND_VISIBLE_FRAC = 0.55   -- fraction of card height visible at rest
local HAND_HOVER_RISE = 100      -- pixels the hovered card rises above resting position
local HAND_GAP = 6               -- gap between cards when not overlapping
local HAND_MAX_TOTAL_W = 900     -- max total width; cards overlap when exceeding this
local HAND_HOVER_SCALE = 1.0     -- hovered card draws at full size (vs HAND_SCALE for resting)

-- Count total workers assigned to structures for a player
local function count_structure_workers(player)
  local total = 0
  for _, entry in ipairs(player.board) do
    total = total + (entry.workers or 0)
  end
  return total
end

-- Sum end-of-turn upkeep that would be charged from current board state.
-- Returns a map: { [resource_key] = amount_due }
local function pending_upkeep_by_resource(player)
  local due = {}
  for _, entry in ipairs(player.board) do
    local ok, card_def = pcall(cards.get_card_def, entry.card_id)
    if ok and card_def and card_def.kind == "Unit" and card_def.upkeep then
      for _, cost in ipairs(card_def.upkeep) do
        if cost.type and cost.amount and cost.amount > 0 then
          due[cost.type] = (due[cost.type] or 0) + cost.amount
        end
      end
    end
  end
  return due
end

-- Get max_workers from a card def's produce ability (0 if none)
local function get_max_workers(card_def)
  if not card_def or not card_def.abilities then return 0 end
  for _, ab in ipairs(card_def.abilities) do
    if ab.type == "static" and ab.effect == "produce" and ab.effect_args and ab.effect_args.per_worker then
      return ab.effect_args.max_workers or 99
    end
  end
  return 0
end

-- Count activated abilities on a card def
local function count_activated_abilities(card_def)
  if not card_def or not card_def.abilities then return 0 end
  local n = 0
  for _, ab in ipairs(card_def.abilities) do
    if ab.type == "activated" then n = n + 1 end
  end
  return n
end

-- Fixed tile height: all structure/unit tiles are the same size
local function struct_tile_height(activated_count)
  return STRUCT_TILE_H_BASE + STRUCT_TILE_AB_H  -- fixed 76px for all tiles
end

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

-- Battlefield row rects.
-- Panel 0 (you): front row (units) at top, back row (structures) below.
-- Panel 1 (opponent): back row at top, front row (units) below.
-- This places the two front rows facing each other across the center gap.
function board.front_row_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local left_edge = panel_x + 20 + DECK_CARD_W + 16
  local right_edge = panel_x + panel_w - 20 - DECK_CARD_W - 16
  local area_w = right_edge - left_edge
  if panel_index == 0 then
    return left_edge, panel_y + 4, area_w, BFIELD_TILE_H
  else
    return left_edge, panel_y + 4 + BFIELD_TILE_H + BFIELD_ROW_GAP, area_w, BFIELD_TILE_H
  end
end

function board.back_row_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local left_edge = panel_x + 20 + DECK_CARD_W + 16
  local right_edge = panel_x + panel_w - 20 - DECK_CARD_W - 16
  local area_w = right_edge - left_edge
  if panel_index == 0 then
    return left_edge, panel_y + 4 + BFIELD_TILE_H + BFIELD_ROW_GAP, area_w, BFIELD_TILE_H
  else
    return left_edge, panel_y + 4, area_w, BFIELD_TILE_H
  end
end

-- Base: centered horizontally, at resource-node y level (close to the player)
function board.base_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local x = panel_x + panel_w / 2 - BFIELD_TILE_W / 2
  local res_y = panel_y + panel_h - RESOURCE_NODE_H - 8
  local y = res_y + (RESOURCE_NODE_H - BFIELD_TILE_H) / 2
  return x, y, BFIELD_TILE_W, BFIELD_TILE_H
end

-- Resource nodes: always at the bottom edge of each panel.
function board.resource_left_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local center_x = panel_x + panel_w * 0.25
  local x = center_x - RESOURCE_NODE_W / 2
  local y = panel_y + panel_h - RESOURCE_NODE_H - 8
  return x, y, RESOURCE_NODE_W, RESOURCE_NODE_H
end

function board.resource_right_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local center_x = panel_x + panel_w * 0.75
  local x = center_x - RESOURCE_NODE_W / 2
  local y = panel_y + panel_h - RESOURCE_NODE_H - 8
  return x, y, RESOURCE_NODE_W, RESOURCE_NODE_H
end

function board.blueprint_slot_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local _, back_y = board.back_row_rect(panel_x, panel_y, panel_w, panel_h, panel_index or 0)
  return panel_x + 20, back_y, DECK_CARD_W, DECK_CARD_H
end

function board.worker_slot_rect(panel_x, panel_y, panel_w, panel_h)
  return panel_x + 20, panel_y + 8 + DECK_CARD_H + 8, 120, SLOT_H
end

function board.unit_slot_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local _, back_y = board.back_row_rect(panel_x, panel_y, panel_w, panel_h, panel_index or 0)
  return panel_x + panel_w - 20 - DECK_CARD_W, back_y, DECK_CARD_W, DECK_CARD_H
end

-- Backwards-compat wrapper: returns the back row rect
function board.structures_area_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  return board.back_row_rect(panel_x, panel_y, panel_w, panel_h, panel_index or 0)
end

-- Centered starting x for n tiles within a row area
local function centered_row_x(row_ax, row_aw, n)
  if n <= 0 then return row_ax end
  local total_w = n * BFIELD_TILE_W + (n - 1) * BFIELD_GAP
  return row_ax + (row_aw - total_w) / 2
end
board.centered_row_x = centered_row_x

-- Tile position within a row (0-based tile_index)
function board.structure_tile_rect(panel_x, panel_y, panel_w, panel_h, tile_index, card_def, panel_index)
  local ax, ay = board.back_row_rect(panel_x, panel_y, panel_w, panel_h, panel_index or 0)
  local tx = ax + tile_index * (BFIELD_TILE_W + BFIELD_GAP)
  return tx, ay, BFIELD_TILE_W, BFIELD_TILE_H
end

-- Resource bar: above buttons for local player, bottom of panel for opponent
function board.resource_bar_rect(panel_index)
  local px, py, pw, ph = board.panel_rect(panel_index)
  if panel_index == 0 then
    local btn_y = py + ph - PASS_BTN_H - 12
    return px + 20, btn_y - RESOURCE_BAR_H - 4, pw - 40, RESOURCE_BAR_H
  else
    return px + 20, py + ph - RESOURCE_BAR_H - 8, pw - 40, RESOURCE_BAR_H
  end
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
local function draw_resource_badge(x, y, res_type, letter, count, r, g, b, display_val, pending_upkeep)
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

  -- Static upcoming upkeep indicator (shown above current value).
  if pending_upkeep and pending_upkeep > 0 then
    local up_text = "-" .. tostring(pending_upkeep)
    local up_font = util.get_font(9)
    love.graphics.setFont(up_font)
    love.graphics.setColor(0.95, 0.45, 0.45, 0.95)
    local tw = up_font:getWidth(up_text)
    love.graphics.print(up_text, x + badge_w - tw - 4, y - 8)
  end
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

-- Draw special worker token with gold/amber ring and warm sphere shading
local function draw_special_worker_circle(cx, cy, is_active_panel, is_draggable, is_hovered_worker)
  local t = love.timer.getTime()
  local r = WORKER_R
  if is_draggable then
    r = WORKER_R + 0.8 * math.sin(t * 3)
  end
  local alpha = is_active_panel and 1.0 or 0.7
  -- Drop shadow
  love.graphics.setColor(0, 0, 0, 0.4 * alpha)
  love.graphics.circle("fill", cx + 2, cy + 3, r + 1)
  -- Hover glow (gold)
  if is_hovered_worker and is_active_panel then
    love.graphics.setColor(0.9, 0.7, 0.2, 0.25 + 0.1 * math.sin(t * 4))
    love.graphics.circle("fill", cx, cy, r + 4)
  end
  -- Radial gradient: warm gold tones
  local layers = 4
  for i = layers, 1, -1 do
    local frac = i / layers
    local lr = r * frac
    local offx = -r * 0.15 * (1 - frac)
    local offy = -r * 0.2 * (1 - frac)
    local brightness
    if is_active_panel then
      brightness = 0.55 + 0.45 * (1 - frac)
    else
      brightness = 0.4 + 0.3 * (1 - frac)
    end
    -- Gold/amber tones instead of blue/gray
    love.graphics.setColor(brightness * 1.1, brightness * 0.85, brightness * 0.3, alpha)
    love.graphics.circle("fill", cx + offx, cy + offy, lr)
  end
  -- Specular highlight
  love.graphics.setColor(1, 1, 0.8, 0.4 * alpha)
  love.graphics.circle("fill", cx - r * 0.25, cy - r * 0.25, r * 0.3)
  -- Gold rim outline
  if is_active_panel then
    love.graphics.setColor(0.85, 0.65, 0.1, 0.9)
  else
    love.graphics.setColor(0.6, 0.5, 0.2, 0.6)
  end
  love.graphics.setLineWidth(2)
  love.graphics.circle("line", cx, cy, r)
  love.graphics.setLineWidth(1)
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

-- Group board entries by card_id, filtered by kind ("Structure" or nil for units/other)
local function group_board_entries(player, kind_filter)
  local groups = {}
  local group_map = {}
  for si, entry in ipairs(player.board) do
    local ok, def = pcall(cards.get_card_def, entry.card_id)
    if ok and def then
      local dominated = (kind_filter == "Structure") and (def.kind == "Structure")
      local is_unit = (kind_filter == "Unit") and (def.kind ~= "Structure")
      if dominated or is_unit then
        if group_map[entry.card_id] then
          local g = groups[group_map[entry.card_id]]
          g.count = g.count + 1
          g.entries[#g.entries + 1] = si
        else
          group_map[entry.card_id] = #groups + 1
          groups[#groups + 1] = { card_id = entry.card_id, count = 1, first_si = si, scale = entry.scale, entries = { si } }
        end
      end
    end
  end
  return groups
end

-- Draw a single battlefield tile (used for base, structures, and units)
local function draw_battlefield_tile(tx, ty, tw, th, group, sdef, pi, game_state, is_active, accent, hover, drag, t, player, is_base)
  local si = group.first_si
  local scale = (group.scale == nil) and 1 or group.scale
  local tile_cx, tile_cy = tx + tw / 2, ty + th / 2
  local tile_hovered = hover and hover.kind == "structure" and hover.pi == pi and hover.idx == si

  if scale ~= 1 then
    love.graphics.push()
    love.graphics.translate(tile_cx, tile_cy)
    love.graphics.scale(scale)
    love.graphics.translate(-tile_cx, -tile_cy)
  end
  if tile_hovered and scale == 1 then
    love.graphics.setColor(accent[1], accent[2], accent[3], 0.15 + 0.05 * math.sin(t * 4))
    love.graphics.rectangle("fill", tx - 2, ty - 2, tw + 4, th + 4, 6, 6)
  end

  if group.count > 1 then
    local stack_layers = math.min(group.count - 1, 2)
    for layer = stack_layers, 1, -1 do
      local offset = layer * 3
      love.graphics.setColor(0.1, 0.1, 0.14, 0.5)
      love.graphics.rectangle("fill", tx + offset, ty - offset, tw, th, 5, 5)
      love.graphics.setColor(0.22, 0.24, 0.3, 0.4)
      love.graphics.rectangle("line", tx + offset, ty - offset, tw, th, 5, 5)
    end
  end

  love.graphics.setColor(0, 0, 0, 0.25)
  love.graphics.rectangle("fill", tx + 2, ty + 3, tw, th, 5, 5)
  if is_active then
    love.graphics.setColor(0.14, 0.15, 0.2, 1.0)
  else
    love.graphics.setColor(0.11, 0.12, 0.16, 0.85)
  end
  love.graphics.rectangle("fill", tx, ty, tw, th, 5, 5)
  love.graphics.setScissor(tx, ty, tw, th)
  textures.draw_tiled(textures.panel, tx, ty, tw, th, 0.05)
  love.graphics.setScissor()
  textures.draw_inner_shadow(tx, ty, tw, th, 3, 0.15)
  for gsi = 0, 5 do
    local ga = (is_active and 0.6 or 0.3) * (1 - gsi / 6)
    love.graphics.setColor(accent[1], accent[2], accent[3], ga)
    love.graphics.rectangle("fill", tx + gsi, ty + 3, 1, th - 6)
  end

  if is_base then
    love.graphics.setColor(0.85, 0.70, 0.25, is_active and 1.0 or 0.6)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", tx, ty, tw, th, 5, 5)
    love.graphics.setLineWidth(1)
  else
    love.graphics.setColor(0.22, 0.24, 0.3, is_active and 1.0 or 0.6)
    love.graphics.rectangle("line", tx, ty, tw, th, 5, 5)
  end

  love.graphics.setColor(1, 1, 1, is_active and 1.0 or 0.6)
  love.graphics.setFont(util.get_title_font(11))
  love.graphics.printf(sdef.name, tx + 8, ty + 4, tw - 16, "left")

  love.graphics.setColor(0.6, 0.62, 0.7, is_active and 0.8 or 0.5)
  love.graphics.setFont(util.get_font(9))
  if is_base then
    local life = player.life or 30
    local stat_h = 20
    local stat_y = ty + th - stat_h - 4
    local badge_w = tw - 8
    local alpha = is_active and 1.0 or 0.6
    love.graphics.setColor(0.2, 0.35, 0.2, 0.35 * alpha)
    love.graphics.rectangle("fill", tx + 4, stat_y, badge_w, stat_h, 3, 3)
    love.graphics.setColor(0.3, 0.55, 0.3, 0.5 * alpha)
    love.graphics.rectangle("line", tx + 4, stat_y, badge_w, stat_h, 3, 3)
    love.graphics.setColor(1, 1, 1, 0.05)
    love.graphics.rectangle("fill", tx + 5, stat_y + 1, badge_w - 2, 1)
    love.graphics.setColor(1, 1, 1, alpha)
    love.graphics.setFont(util.get_font(10))
    love.graphics.printf("HP " .. tostring(life), tx + 4, stat_y + stat_h / 2 - 6, badge_w, "center")
  elseif sdef.kind == "Unit" and sdef.attack and sdef.health then
    local stat_h = 20
    local stat_y = ty + th - stat_h - 4
    local half_w = (tw - 12) / 2
    local alpha = is_active and 1.0 or 0.6
    -- ATK badge (left)
    love.graphics.setColor(0.5, 0.2, 0.2, 0.35 * alpha)
    love.graphics.rectangle("fill", tx + 4, stat_y, half_w, stat_h, 3, 3)
    love.graphics.setColor(0.7, 0.3, 0.3, 0.5 * alpha)
    love.graphics.rectangle("line", tx + 4, stat_y, half_w, stat_h, 3, 3)
    love.graphics.setColor(1, 1, 1, 0.05)
    love.graphics.rectangle("fill", tx + 5, stat_y + 1, half_w - 2, 1)
    love.graphics.setColor(1, 1, 1, alpha)
    love.graphics.setFont(util.get_font(10))
    love.graphics.printf("ATK " .. tostring(sdef.attack), tx + 4, stat_y + stat_h / 2 - 6, half_w, "center")
    -- HP badge (right)
    local right_x = tx + tw - 4 - half_w
    love.graphics.setColor(0.2, 0.35, 0.2, 0.35 * alpha)
    love.graphics.rectangle("fill", right_x, stat_y, half_w, stat_h, 3, 3)
    love.graphics.setColor(0.3, 0.55, 0.3, 0.5 * alpha)
    love.graphics.rectangle("line", right_x, stat_y, half_w, stat_h, 3, 3)
    love.graphics.setColor(1, 1, 1, 0.05)
    love.graphics.rectangle("fill", right_x + 1, stat_y + 1, half_w - 2, 1)
    love.graphics.setColor(1, 1, 1, alpha)
    love.graphics.setFont(util.get_font(10))
    love.graphics.printf("HP " .. tostring(sdef.health), right_x, stat_y + stat_h / 2 - 6, half_w, "center")
  end

  local ab_btn_y = is_base and (ty + 36) or (ty + 34)
  local has_non_activated_hint = nil
  if sdef.abilities then
    for ai, ab in ipairs(sdef.abilities) do
      if ab.type == "activated" then
        local key
        if is_base then
          key = tostring(pi) .. ":base:" .. ai
        else
          key = tostring(pi) .. ":board:" .. si .. ":" .. ai
        end
        local used = game_state.activatedUsedThisTurn and game_state.activatedUsedThisTurn[key]
        local can_act = (not used or not ab.once_per_turn) and abilities.can_pay_cost(player.resources, ab.cost) and is_active
        local ab_hovered = hover and hover.kind == "activate_ability" and hover.pi == pi
          and type(hover.idx) == "table"
          and ((is_base and hover.idx.source == "base") or (not is_base and hover.idx.source == "board" and hover.idx.board_index == si))
          and hover.idx.ability_index == ai
        card_frame.draw_ability_button(ab, tx + 4, ab_btn_y, tw - 8, {
          can_activate = can_act,
          is_used = used and ab.once_per_turn,
          is_hovered = ab_hovered,
        })
        ab_btn_y = ab_btn_y + STRUCT_TILE_AB_H
      elseif ab.type == "static" and ab.effect == "produce" then
        has_non_activated_hint = has_non_activated_hint or "PROD"
      elseif ab.type == "triggered" then
        has_non_activated_hint = has_non_activated_hint or "TRIG"
      end
    end
  end
  if has_non_activated_hint and count_activated_abilities(sdef) == 0 then
    love.graphics.setColor(accent[1], accent[2], accent[3], is_active and 0.6 or 0.3)
    love.graphics.setFont(util.get_font(7))
    love.graphics.printf(has_non_activated_hint, tx + 4, ty + 38, tw - 8, "center")
  end

  if group.count > 1 then
    local badge_text = "x" .. group.count
    local badge_w = 22
    local badge_h = 14
    local bbx = tx + tw - badge_w - 3
    local bby = ty + 3
    love.graphics.setColor(accent[1], accent[2], accent[3], 0.85)
    love.graphics.rectangle("fill", bbx, bby, badge_w, badge_h, 3, 3)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setFont(util.get_font(9))
    love.graphics.printf(badge_text, bbx, bby + 1, badge_w, "center")
  end

  if not is_base then
    local max_w = get_max_workers(sdef)
    if max_w > 0 then
      local slot_filled = {}
      local total_slots = 0
      for _, esi in ipairs(group.entries) do
        local ew = player.board[esi].workers or 0
        if drag and drag.player_index == pi and drag.from == "structure" and drag.board_index == esi then
          ew = math.max(0, ew - 1)
        end
        local sw_count = actions.count_special_on_structure(player, esi)
        for w = 1, max_w do
          total_slots = total_slots + 1
          if w <= ew then
            slot_filled[total_slots] = "regular"
          elseif w <= ew + sw_count then
            slot_filled[total_slots] = "special"
          else
            slot_filled[total_slots] = false
          end
        end
      end
      local wr = 7
      local spacing = wr * 2 + 3
      local row_w = total_slots * spacing - 3
      local wcx_start = tx + tw - row_w - 4
      local wcy = ty + th - wr - 4
      if drag and drag.player_index == pi and (drag.from == "unassigned" or drag.from == "left" or drag.from == "right" or drag.from == "special") and tile_hovered then
        local pulse = 0.4 + 0.3 * math.sin(t * 4)
        love.graphics.setColor(0.3, 0.6, 1.0, pulse)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", tx - 3, ty - 3, tw + 6, th + 6, 6, 6)
        love.graphics.setLineWidth(1)
      end
      for slot = 1, total_slots do
        local scx = wcx_start + (slot - 1) * spacing + wr
        if slot_filled[slot] == "regular" then
          love.graphics.setColor(0, 0, 0, 0.3)
          love.graphics.circle("fill", scx + 1, wcy + 2, wr + 1)
          love.graphics.setColor(0.75, 0.75, 0.9, is_active and 1.0 or 0.6)
          love.graphics.circle("fill", scx, wcy, wr)
          love.graphics.setColor(1, 1, 1, 0.3)
          love.graphics.circle("fill", scx - wr * 0.2, wcy - wr * 0.2, wr * 0.3)
          love.graphics.setColor(0.45, 0.5, 0.9, 0.7)
          love.graphics.circle("line", scx, wcy, wr)
        elseif slot_filled[slot] == "special" then
          love.graphics.setColor(0, 0, 0, 0.3)
          love.graphics.circle("fill", scx + 1, wcy + 2, wr + 1)
          love.graphics.setColor(0.9, 0.75, 0.25, is_active and 1.0 or 0.6)
          love.graphics.circle("fill", scx, wcy, wr)
          love.graphics.setColor(1, 1, 0.8, 0.35)
          love.graphics.circle("fill", scx - wr * 0.2, wcy - wr * 0.2, wr * 0.3)
          love.graphics.setColor(0.85, 0.65, 0.1, 0.9)
          love.graphics.setLineWidth(1.5)
          love.graphics.circle("line", scx, wcy, wr)
          love.graphics.setLineWidth(1)
        else
          love.graphics.setColor(0.25, 0.27, 0.35, is_active and 0.6 or 0.3)
          love.graphics.circle("line", scx, wcy, wr)
        end
      end
    end
  end

  if scale ~= 1 then
    love.graphics.pop()
  end
end

function board.draw(game_state, drag, hover, mouse_down, display_resources, hand_state, local_player_index)
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
  local_player_index = local_player_index or 0
  local active_pi = game_state.activePlayer
  local active_player = game_state.players[active_pi + 1]
  local active_accent = get_faction_color(active_player.faction)
  local active_panel = (local_player_index == 0) and active_pi or (1 - active_pi)
  local apx, apy, apw, aph = board.panel_rect(active_panel)
  love.graphics.setColor(active_accent[1], active_accent[2], active_accent[3], 0.06)
  love.graphics.ellipse("fill", apx + apw / 2, apy + aph / 2, apw * 0.5, aph * 0.6)

  for panel = 0, 1 do
    local pi = (local_player_index == 0) and panel or (1 - panel)
    local px, py, pw, ph = board.panel_rect(panel)
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
    local bx, by, bw, bh = board.blueprint_slot_rect(px, py, pw, ph, panel)
    draw_deck_card(bx, by, bw, bh, "Blueprint\nDeck", deck_assets.get_blueprint_back())
    local ux, uy, uw, uh = board.unit_slot_rect(px, py, pw, ph, panel)
    draw_deck_card(ux, uy, uw, uh, "Unit\nDeck", deck_assets.get_unit_back())

    -- ── Battlefield: two-row layout ──
    -- Back row: base tile + structures.  Front row: units.
    local back_ax, back_ay, back_aw = board.back_row_rect(px, py, pw, ph, panel)
    local front_ax, front_ay, front_aw = board.front_row_rect(px, py, pw, ph, panel)

    -- Subtle row zone indicators (drawn behind tiles)
    love.graphics.setColor(accent[1], accent[2], accent[3], 0.04)
    love.graphics.rectangle("fill", back_ax, back_ay, back_aw, BFIELD_TILE_H, 4, 4)
    love.graphics.rectangle("fill", front_ax, front_ay, front_aw, BFIELD_TILE_H, 4, 4)
    love.graphics.setColor(0.2, 0.22, 0.28, 0.2)
    love.graphics.rectangle("line", back_ax, back_ay, back_aw, BFIELD_TILE_H, 4, 4)
    love.graphics.rectangle("line", front_ax, front_ay, front_aw, BFIELD_TILE_H, 4, 4)


    -- Draw base tile (centered, near resources)
    local base_bx, base_by = board.base_rect(px, py, pw, ph, panel)
    local base_group = { card_id = player.baseId, count = 1, first_si = 0, scale = 1, entries = {} }
    draw_battlefield_tile(base_bx, base_by, BFIELD_TILE_W, BFIELD_TILE_H, base_group, base_def, pi, game_state, is_active, accent, hover, drag, t, player, true)

    -- Draw structures in back row (centered)
    local struct_groups = group_board_entries(player, "Structure")
    local struct_start_x = centered_row_x(back_ax, back_aw, #struct_groups)
    for gi, group in ipairs(struct_groups) do
      local ok, sdef = pcall(cards.get_card_def, group.card_id)
      if ok and sdef then
        local tile_x = struct_start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        draw_battlefield_tile(tile_x, back_ay, BFIELD_TILE_W, BFIELD_TILE_H, group, sdef, pi, game_state, is_active, accent, hover, drag, t, player, false)
      end
    end

    -- Draw units in front row (centered)
    local unit_groups = group_board_entries(player, "Unit")
    local unit_start_x = centered_row_x(front_ax, front_aw, #unit_groups)
    for gi, group in ipairs(unit_groups) do
      local ok, udef = pcall(cards.get_card_def, group.card_id)
      if ok and udef then
        local tile_x = unit_start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        draw_battlefield_tile(tile_x, front_ay, BFIELD_TILE_W, BFIELD_TILE_H, group, udef, pi, game_state, is_active, accent, hover, drag, t, player, false)
      end
    end

    -- Sacrifice selection overlay: highlight eligible tiles, dim others
    local sac_indices = hand_state and hand_state.sacrifice_eligible_indices
    if sac_indices and panel == 0 then
      local function is_sac_eligible(si)
        for _, ei in ipairs(sac_indices) do
          if ei == si then return true end
        end
        return false
      end
      -- Dim structures (not eligible for sacrifice)
      for gi, group in ipairs(struct_groups) do
        local tile_x = struct_start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        love.graphics.setColor(0, 0, 0, 0.5)
        love.graphics.rectangle("fill", tile_x, back_ay, BFIELD_TILE_W, BFIELD_TILE_H, 5, 5)
      end
      -- Overlay units
      for gi, group in ipairs(unit_groups) do
        local tile_x = unit_start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        if is_sac_eligible(group.first_si) then
          local pulse = 0.3 + 0.2 * math.sin(t * 4)
          love.graphics.setColor(0.9, 0.2, 0.2, pulse)
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", tile_x - 2, front_ay - 2, BFIELD_TILE_W + 4, BFIELD_TILE_H + 4, 6, 6)
          love.graphics.setLineWidth(1)
        else
          love.graphics.setColor(0, 0, 0, 0.5)
          love.graphics.rectangle("fill", tile_x, front_ay, BFIELD_TILE_W, BFIELD_TILE_H, 5, 5)
        end
      end
      -- Highlight all worker locations (any workers can be sacrificed)
      local sac_pulse = 0.3 + 0.2 * math.sin(t * 4)
      local uax, uay, uaw, uah = board.unassigned_pool_rect(px, py, pw, ph, player)
      local unassigned = player.totalWorkers - player.workersOn.food - player.workersOn.wood - player.workersOn.stone - count_structure_workers(player)
      if unassigned > 0 then
        love.graphics.setColor(0.9, 0.2, 0.2, sac_pulse)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", uax - 2, uay - 2, uaw + 4, uah + 4, 6, 6)
        love.graphics.setLineWidth(1)
      end
      local srl_x, srl_y, srl_w, srl_h = board.resource_left_rect(px, py, pw, ph, panel)
      local res_left_key = (player.faction == "Human") and "wood" or "food"
      if (player.workersOn[res_left_key] or 0) > 0 then
        love.graphics.setColor(0.9, 0.2, 0.2, sac_pulse)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", srl_x - 2, srl_y - 2, srl_w + 4, srl_h + 4, 6, 6)
        love.graphics.setLineWidth(1)
      end
      local srr_x, srr_y, srr_w, srr_h = board.resource_right_rect(px, py, pw, ph, panel)
      if (player.workersOn.stone or 0) > 0 then
        love.graphics.setColor(0.9, 0.2, 0.2, sac_pulse)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", srr_x - 2, srr_y - 2, srr_w + 4, srr_h + 4, 6, 6)
        love.graphics.setLineWidth(1)
      end
      -- Prompt banner
      love.graphics.setFont(util.get_font(12))
      love.graphics.setColor(0.9, 0.3, 0.3, 0.7 + 0.2 * math.sin(t * 3))
      love.graphics.printf("Select an ally to sacrifice", px, front_ay - 20, pw, "center")
    end

    -- Resource nodes: title + placeholder only, centered in panel
    local res_left_title = (player.faction == "Human") and "Wood" or "Food"
    local res_left_resource = (player.faction == "Human") and "wood" or "food"
    local rl_x, rl_y, rl_w, rl_h = board.resource_left_rect(px, py, pw, ph, panel)

    -- Drop zone glow on resource nodes when dragging
    if drag and drag.player_index == pi then
      if drag.from ~= "left" or drag.from == "special" then
        draw_drop_zone_glow(rl_x, rl_y, rl_w, rl_h, t)
      end
    end

    card_frame.draw_resource_node(rl_x, rl_y, res_left_title, player.faction)
    local n_left = player.workersOn[res_left_resource]
    if drag and drag.player_index == pi and drag.from == "left" and n_left > 0 then n_left = n_left - 1 end
    local n_special_left = actions.count_special_on_resource(player, res_left_resource)
    local total_left_draw = n_left + n_special_left
    for i = 1, n_left do
      local wcx, wcy = board.worker_circle_center(px, py, pw, ph, "left", i, total_left_draw, panel)
      draw_worker_circle(wcx, wcy, is_active, is_active)
    end
    for i = 1, n_special_left do
      local wcx, wcy = board.worker_circle_center(px, py, pw, ph, "left", n_left + i, total_left_draw, panel)
      draw_special_worker_circle(wcx, wcy, is_active, is_active)
    end

    local rr_x, rr_y, rr_w, rr_h = board.resource_right_rect(px, py, pw, ph, panel)

    -- Drop zone glow on right resource when dragging
    if drag and drag.player_index == pi then
      if drag.from ~= "right" then
        draw_drop_zone_glow(rr_x, rr_y, rr_w, rr_h, t)
      end
    end

    card_frame.draw_resource_node(rr_x, rr_y, "Stone", player.faction)
    local n_stone = player.workersOn.stone
    if drag and drag.player_index == pi and drag.from == "right" and n_stone > 0 then n_stone = n_stone - 1 end
    local n_special_stone = actions.count_special_on_resource(player, "stone")
    local total_stone_draw = n_stone + n_special_stone
    for i = 1, n_stone do
      local wcx, wcy = board.worker_circle_center(px, py, pw, ph, "right", i, total_stone_draw, panel)
      draw_worker_circle(wcx, wcy, is_active, is_active)
    end
    for i = 1, n_special_stone do
      local wcx, wcy = board.worker_circle_center(px, py, pw, ph, "right", n_stone + i, total_stone_draw, panel)
      draw_special_worker_circle(wcx, wcy, is_active, is_active)
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
    local unassigned = player.totalWorkers - player.workersOn.food - player.workersOn.wood - player.workersOn.stone - count_structure_workers(player)
    local draw_count = unassigned
    if drag and drag.player_index == pi and drag.from == "unassigned" and unassigned > 0 then
      draw_count = unassigned - 1
    end
    -- Count unassigned special workers
    local special_unassigned_count = 0
    for _, sw in ipairs(player.specialWorkers) do
      if sw.assigned_to == nil then special_unassigned_count = special_unassigned_count + 1 end
    end
    local total_draw_pool = draw_count + special_unassigned_count
    local total_w = total_draw_pool * (WORKER_R * 2 + 4) - 4
    if total_w < 0 then total_w = 0 end
    local start_x = uax + uaw / 2 - total_w / 2 + WORKER_R
    for i = 1, draw_count do
      local wcx = start_x + (i - 1) * (WORKER_R * 2 + 4)
      local wcy = uay + uah / 2
      draw_worker_circle(wcx, wcy, is_active, is_active)
    end
    -- Draw unassigned special workers (gold) to the right of regular workers
    local sw_draw_idx = 0
    for swi, sw in ipairs(player.specialWorkers) do
      if sw.assigned_to == nil then
        sw_draw_idx = sw_draw_idx + 1
        local wcx = start_x + (draw_count + sw_draw_idx - 1) * (WORKER_R * 2 + 4)
        local wcy = uay + uah / 2
        draw_special_worker_circle(wcx, wcy, is_active, is_active)
      end
    end
    -- Worker count label (top-right corner of pool)
    local wcount_str = player.totalWorkers .. "/" .. max_workers
    local wcount_font = util.get_font(9)
    love.graphics.setFont(wcount_font)
    local wcount_tw = wcount_font:getWidth(wcount_str)
    local wcount_x = uax + uaw - wcount_tw - 4
    local wcount_y = uay + 2
    -- Small dark backing for readability
    love.graphics.setColor(0, 0, 0, 0.5)
    love.graphics.rectangle("fill", wcount_x - 3, wcount_y - 1, wcount_tw + 6, 13, 3, 3)
    love.graphics.setColor(0.75, 0.76, 0.88, is_active and 0.9 or 0.5)
    love.graphics.print(wcount_str, wcount_x, wcount_y)

    -- Pass and End Turn buttons (local player only)
    if panel == 0 then
      local pbx, pby, pbw, pbh = board.pass_button_rect(px, py, pw, ph)
      local pass_hovered = is_hovered(hover, "pass", pi)
      local pass_pressed = pass_hovered and mouse_down
      draw_button(pbx, pby, pbw, pbh, "Pass", pass_hovered, pass_pressed, 0.2, 0.22, 0.28)

      local ebx, eby, ebw, ebh = board.end_turn_button_rect(px, py, pw, ph)
      local et_hovered = is_hovered(hover, "end_turn", pi)
      local et_pressed = et_hovered and mouse_down
      if is_active then
        draw_button(ebx, eby, ebw, ebh, "End Turn", et_hovered, et_pressed, 0.14, 0.28, 0.22)
      else
        draw_button(ebx, eby, ebw, ebh, "End Turn", et_hovered, et_pressed, 0.2, 0.22, 0.28)
      end
    end

    -- Resource bar (both panels — dynamically sized, left-justified)
    do
      local pending_upkeep = pending_upkeep_by_resource(player)
      local rbx, rby, _, rbh = board.resource_bar_rect(panel)
      -- First pass: measure how wide the content is
      local content_w = 8  -- left padding
      for _, key in ipairs(config.resource_types) do
        local count = player.resources[key] or 0
        local display_val = dr and dr[key]
        if count > 0 or (display_val and display_val > 0.5) or (pending_upkeep[key] or 0) > 0 then
          content_w = content_w + 54  -- badge_w (50) + gap (4)
        end
      end
      -- Only draw if there are resources to show
      if content_w > 8 then
        local rbw = content_w + 4  -- right padding
        -- Background
        love.graphics.setColor(0.06, 0.07, 0.10, 0.92)
        love.graphics.rectangle("fill", rbx, rby, rbw, rbh, 5, 5)
        -- Accent line at top
        love.graphics.setColor(accent[1], accent[2], accent[3], 0.4)
        love.graphics.rectangle("fill", rbx + 4, rby, rbw - 8, 1)
        -- Subtle border
        love.graphics.setColor(0.18, 0.20, 0.25, 0.6)
        love.graphics.rectangle("line", rbx, rby, rbw, rbh, 5, 5)
        -- Resource badges
        local badge_x = rbx + 8
        local badge_cy = rby + (rbh - 22) / 2
        for _, key in ipairs(config.resource_types) do
          local count = player.resources[key] or 0
          local display_val = dr and dr[key]
          if count > 0 or (display_val and display_val > 0.5) or (pending_upkeep[key] or 0) > 0 then
            local rdef = res_registry[key]
            if rdef then
              local rc, gc, bc = rdef.color[1], rdef.color[2], rdef.color[3]
              badge_x = badge_x + draw_resource_badge(badge_x, badge_cy, key, rdef.letter, count, rc, gc, bc, display_val, pending_upkeep[key])
            end
          end
        end
      end
    end
  end

  -- =========================================================
  -- Hand cards (local player, drawn on top of the board)
  -- =========================================================
  hand_state = hand_state or {}
  local local_p = game_state.players[(local_player_index or 0) + 1]
  local hand = local_p.hand
  if #hand > 0 then
    local hover_idx = hand_state.hover_index
    local selected_idx = hand_state.selected_index
    local y_offsets = hand_state.y_offsets
    local eligible_set = nil  -- nil means no pending selection; table = set of eligible indices
    if hand_state.eligible_hand_indices then
      eligible_set = {}
      for _, ei in ipairs(hand_state.eligible_hand_indices) do
        eligible_set[ei] = true
      end
    end
    local rects = board.hand_card_rects(#hand, y_offsets)
    local accent0 = get_faction_color(local_p.faction)

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
            upkeep = def.upkeep,
            attack = def.attack,
            health = def.health,
            tier = def.tier,
            abilities_list = def.abilities,
            show_ability_text = true,
          })
          love.graphics.pop()
          -- Pending selection: dim non-eligible, glow eligible
          if eligible_set then
            if eligible_set[i] then
              local pulse = 0.45 + 0.25 * math.sin(t * 4)
              love.graphics.setColor(0.3, 0.9, 0.4, pulse)
              love.graphics.setLineWidth(2)
              love.graphics.rectangle("line", r.x - 2, r.y - 2, r.w + 4, r.h + 4, 6, 6)
              love.graphics.setLineWidth(1)
            else
              love.graphics.setColor(0, 0, 0, 0.55)
              love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, 5, 5)
            end
          end
          -- Selected glow (normal mode only)
          if i == selected_idx and not eligible_set then
            love.graphics.setColor(accent0[1], accent0[2], accent0[3], 0.5 + 0.15 * math.sin(t * 5))
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", r.x - 2, r.y - 2, r.w + 4, r.h + 4, 6, 6)
            love.graphics.setLineWidth(1)
          end
        end
      end
    end

    -- Draw hovered card last (on top, raised, enlarged)
    if hover_idx and hover_idx >= 1 and hover_idx <= #hand then
      local r = rects[hover_idx]
      local ok, def = pcall(cards.get_card_def, hand[hover_idx])
      if ok and def then
        local is_eligible_hover = (eligible_set == nil) or eligible_set[hover_idx]
        -- Enlarged card dimensions
        local hover_w = math.floor(CARD_W * HAND_HOVER_SCALE)
        local hover_h = math.floor(CARD_H * HAND_HOVER_SCALE)
        -- Anchor at center-bottom of the original rect so card grows upward
        local hx = r.x + r.w / 2 - hover_w / 2
        local hy = r.y + r.h - hover_h
        -- Larger shadow for lifted card
        love.graphics.setColor(0, 0, 0, 0.55)
        love.graphics.rectangle("fill", hx + 4, hy + 6, hover_w, hover_h, 5, 5)
        -- Subtle glow behind
        if eligible_set and is_eligible_hover then
          local pulse = 0.25 + 0.15 * math.sin(t * 4)
          love.graphics.setColor(0.3, 0.9, 0.4, pulse)
        else
          love.graphics.setColor(accent0[1], accent0[2], accent0[3], 0.2)
        end
        love.graphics.rectangle("fill", hx - 4, hy - 4, hover_w + 8, hover_h + 8, 8, 8)
        -- Draw card at hover scale
        love.graphics.push()
        love.graphics.translate(hx, hy)
        love.graphics.scale(HAND_HOVER_SCALE)
        card_frame.draw(0, 0, {
          title = def.name,
          faction = def.faction,
          kind = def.kind,
          typeLine = (def.subtypes and #def.subtypes > 0)
            and (def.faction .. " — " .. table.concat(def.subtypes, ", "))
            or (def.faction .. " — " .. def.kind),
          text = def.text,
          costs = def.costs,
          upkeep = def.upkeep,
          attack = def.attack,
          health = def.health,
          tier = def.tier,
          abilities_list = def.abilities,
          show_ability_text = true,
        })
        love.graphics.pop()
        -- Dim overlay for non-eligible hovered card
        if eligible_set and not eligible_set[hover_idx] then
          love.graphics.setColor(0, 0, 0, 0.55)
          love.graphics.rectangle("fill", hx, hy, hover_w, hover_h, 5, 5)
        end
        -- Bright hover border
        if eligible_set and is_eligible_hover then
          local pulse = 0.7 + 0.2 * math.sin(t * 4)
          love.graphics.setColor(0.3, 0.9, 0.4, pulse)
        else
          love.graphics.setColor(accent0[1], accent0[2], accent0[3], 0.8)
        end
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", hx - 1, hy - 1, hover_w + 2, hover_h + 2, 6, 6)
        love.graphics.setLineWidth(1)
        -- Selected indicator (normal mode only)
        if hover_idx == selected_idx and not eligible_set then
          love.graphics.setColor(1, 1, 1, 0.4 + 0.15 * math.sin(t * 5))
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", hx - 3, hy - 3, hover_w + 6, hover_h + 6, 7, 7)
          love.graphics.setLineWidth(1)
        end
      end
    end

    -- "Select a unit" prompt during pending selection
    if eligible_set then
      local prompt_font = util.get_font(14)
      local prompt_text = "Select a unit to play"
      local prompt_w = prompt_font:getWidth(prompt_text) + 24
      local prompt_h = prompt_font:getHeight() + 12
      local prompt_x = (gw - prompt_w) / 2
      local prompt_y = gh - HAND_CARD_H * HAND_VISIBLE_FRAC - HAND_HOVER_RISE - prompt_h - 8
      love.graphics.setColor(0.06, 0.08, 0.12, 0.88)
      love.graphics.rectangle("fill", prompt_x, prompt_y, prompt_w, prompt_h, 6, 6)
      love.graphics.setColor(0.3, 0.9, 0.4, 0.6 + 0.2 * math.sin(t * 3))
      love.graphics.rectangle("line", prompt_x, prompt_y, prompt_w, prompt_h, 6, 6)
      love.graphics.setFont(prompt_font)
      love.graphics.setColor(0.85, 0.95, 0.85, 1.0)
      love.graphics.printf(prompt_text, prompt_x, prompt_y + 6, prompt_w, "center")
    end

    -- (Deck count shown via tooltip on hover -- see hit_test "unit_deck")
  end
end

-- Hit test: return "activate_base" | "blueprint" | "worker_*" | "resource_*" | "unassigned_pool" | "pass" | "end_turn" | "hand_card" | nil
function board.hit_test(mx, my, game_state, hand_y_offsets, local_player_index)
  local_player_index = local_player_index or 0
  -- Check hand cards first (drawn on top of everything; local player only)
  local local_p = game_state.players[local_player_index + 1]
  if #local_p.hand > 0 then
    local rects = board.hand_card_rects(#local_p.hand, hand_y_offsets)
    -- Check in reverse order (rightmost / topmost card first)
    for i = #rects, 1, -1 do
      local r = rects[i]
      if util.point_in_rect(mx, my, r.x, r.y, r.w, r.h) then
        return "hand_card", local_player_index, i
      end
    end
  end

  for panel = 0, 1 do
    local pi = (local_player_index == 0) and panel or (1 - panel)
    local px, py, pw, ph = board.panel_rect(panel)
    local player = game_state.players[pi + 1]
    local res_left = (player.faction == "Human") and "wood" or "food"

    -- Pass and End Turn hit test (local player only)
    if panel == 0 then
      local pbx, pby, pbw, pbh = board.pass_button_rect(px, py, pw, ph)
      if util.point_in_rect(mx, my, pbx, pby, pbw, pbh) then
        return "pass", pi
      end
      local ebx, eby, ebw, ebh = board.end_turn_button_rect(px, py, pw, ph)
      if util.point_in_rect(mx, my, ebx, eby, ebw, ebh) then
        return "end_turn", pi
      end
    end

    -- ── Hit test: base tile (centered, near resources) ──
    local base_def = cards.get_card_def(player.baseId)
    local base_tx, base_ty = board.base_rect(px, py, pw, ph, panel)
    if util.point_in_rect(mx, my, base_tx, base_ty, BFIELD_TILE_W, BFIELD_TILE_H) then
      if base_def.abilities then
        local ab_btn_y = base_ty + 36
        for ai, ab in ipairs(base_def.abilities) do
          if ab.type == "activated" then
            if util.point_in_rect(mx, my, base_tx + 4, ab_btn_y, BFIELD_TILE_W - 8, 24) then
              local key = tostring(pi) .. ":base:" .. ai
              local used = game_state.activatedUsedThisTurn and game_state.activatedUsedThisTurn[key]
              local can_act = pi == game_state.activePlayer and (not ab.once_per_turn or not used) and abilities.can_pay_cost(player.resources, ab.cost)
              if can_act then
                return "activate_ability", pi, { source = "base", ability_index = ai }
              else
                return "ability_hover", pi, { source = "base", ability_index = ai }
              end
            end
            ab_btn_y = ab_btn_y + STRUCT_TILE_AB_H
          end
        end
      end
      return "structure", pi, 0
    end

    -- ── Hit test helper for a row of grouped tiles (centered) ──
    local function hit_test_row(row_ax, row_ay, row_aw, groups, source_type)
      local start_x = centered_row_x(row_ax, row_aw, #groups)
      for gi, group in ipairs(groups) do
        local s_ok, sdef = pcall(cards.get_card_def, group.card_id)
        local tx = start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        local tw, th = BFIELD_TILE_W, BFIELD_TILE_H
        if tx + tw > row_ax + row_aw + 2 then break end
        if util.point_in_rect(mx, my, tx, row_ay, tw, th) then
          local si = group.first_si
          if s_ok and sdef and sdef.abilities then
            local ab_btn_y = row_ay + 34
            for ai, ab in ipairs(sdef.abilities) do
              if ab.type == "activated" then
                if util.point_in_rect(mx, my, tx + 4, ab_btn_y, tw - 8, 24) then
                  local key = tostring(pi) .. ":board:" .. si .. ":" .. ai
                  local used = game_state.activatedUsedThisTurn and game_state.activatedUsedThisTurn[key]
                  local can_act = (not ab.once_per_turn or not used) and abilities.can_pay_cost(player.resources, ab.cost) and pi == game_state.activePlayer
                  if can_act then
                    return "activate_ability", pi, { source = "board", board_index = si, ability_index = ai }
                  else
                    return "ability_hover", pi, { source = "board", board_index = si, ability_index = ai }
                  end
                end
                ab_btn_y = ab_btn_y + STRUCT_TILE_AB_H
              end
            end
          end
          if s_ok and sdef then
            local max_w = get_max_workers(sdef)
            if max_w > 0 then
              local total_slots = max_w * group.count
              local wr = 7
              local spacing = wr * 2 + 3
              local row_w_px = total_slots * spacing - 3
              local wcx_start = tx + tw - row_w_px - 4
              local wcy = row_ay + th - wr - 4
              local slot_info = {}
              for _, esi in ipairs(group.entries) do
                local ew = player.board[esi].workers or 0
                local sw_count = actions.count_special_on_structure(player, esi)
                local sw_indices = {}
                for swi, sw in ipairs(player.specialWorkers) do
                  if sw.assigned_to == esi then sw_indices[#sw_indices + 1] = swi end
                end
                for w = 1, max_w do
                  if w <= ew then
                    slot_info[#slot_info + 1] = { board_index = esi, filled = "regular" }
                  elseif w <= ew + sw_count then
                    slot_info[#slot_info + 1] = { board_index = esi, filled = "special", sw_index = sw_indices[w - ew] }
                  else
                    slot_info[#slot_info + 1] = { board_index = esi, filled = false }
                  end
                end
              end
              for slot = 1, total_slots do
                local scx = wcx_start + (slot - 1) * spacing + wr
                if (mx - scx)^2 + (my - wcy)^2 <= (wr + 2)^2 then
                  local sinfo = slot_info[slot]
                  if sinfo.filled == "regular" then
                    return "structure_worker", pi, sinfo.board_index
                  elseif sinfo.filled == "special" then
                    return "special_worker_structure", pi, sinfo.sw_index
                  else
                    return "structure", pi, sinfo.board_index
                  end
                end
              end
            end
          end
          return "structure", pi, si
        end
      end
      return nil
    end

    -- Hit test structures (back row, after base)
    local back_ax, back_ay, back_aw = board.back_row_rect(px, py, pw, ph, panel)
    local struct_groups = group_board_entries(player, "Structure")
    do
      local sk, sp, se = hit_test_row(back_ax, back_ay, back_aw, struct_groups, "back")
      if sk then return sk, sp, se end
    end

    -- Hit test units (front row)
    local front_ax, front_ay, front_aw = board.front_row_rect(px, py, pw, ph, panel)
    local unit_groups = group_board_entries(player, "Unit")
    do
      local uk, up, ue = hit_test_row(front_ax, front_ay, front_aw, unit_groups, "front")
      if uk then return uk, up, ue end
    end
    if util.point_in_rect(mx, my, front_ax, front_ay, front_aw, BFIELD_TILE_H) then
      return "unit_row", pi
    end

    local bx, by, bw, bh = board.blueprint_slot_rect(px, py, pw, ph, panel)
    if util.point_in_rect(mx, my, bx, by, bw, bh) then
      return "blueprint", pi
    end

    local udx, udy, udw, udh = board.unit_slot_rect(px, py, pw, ph, panel)
    if util.point_in_rect(mx, my, udx, udy, udw, udh) then
      return "unit_deck", pi
    end

    local uax, uay, uaw, uah = board.unassigned_pool_rect(px, py, pw, ph, player)
    if util.point_in_rect(mx, my, uax, uay, uaw, uah) then
      local unassigned = player.totalWorkers - player.workersOn.food - player.workersOn.wood - player.workersOn.stone - count_structure_workers(player)
      -- Count unassigned special workers
      local special_unassigned = {}
      for swi, sw in ipairs(player.specialWorkers) do
        if sw.assigned_to == nil then special_unassigned[#special_unassigned + 1] = swi end
      end
      local total_pool = unassigned + #special_unassigned
      local total_w = total_pool * (WORKER_R * 2 + 4) - 4
      local start_x = uax + uaw / 2 - total_w / 2 + WORKER_R
      for i = 1, unassigned do
        local cx = start_x + (i - 1) * (WORKER_R * 2 + 4)
        local cy = uay + uah / 2
        if (mx - cx)^2 + (my - cy)^2 <= WORKER_R^2 then
          return "worker_unassigned", pi, nil
        end
      end
      -- Hit test special workers in pool
      for si, swi in ipairs(special_unassigned) do
        local cx = start_x + (unassigned + si - 1) * (WORKER_R * 2 + 4)
        local cy = uay + uah / 2
        if (mx - cx)^2 + (my - cy)^2 <= WORKER_R^2 then
          return "special_worker_unassigned", pi, swi
        end
      end
      return "unassigned_pool", pi
    end

    local n_left_reg = player.workersOn[res_left]
    local n_left_special = actions.count_special_on_resource(player, res_left)
    local total_left = n_left_reg + n_left_special
    for i = 1, n_left_reg do
      local cx, cy = board.worker_circle_center(px, py, pw, ph, "left", i, total_left, panel)
      if (mx - cx)^2 + (my - cy)^2 <= WORKER_R^2 then
        return "worker_left", pi, i
      end
    end
    -- Special workers on left resource
    local sw_left_idx = 0
    for swi, sw in ipairs(player.specialWorkers) do
      if sw.assigned_to == res_left then
        sw_left_idx = sw_left_idx + 1
        local cx, cy = board.worker_circle_center(px, py, pw, ph, "left", n_left_reg + sw_left_idx, total_left, panel)
        if (mx - cx)^2 + (my - cy)^2 <= WORKER_R^2 then
          return "special_worker_resource", pi, swi
        end
      end
    end
    local n_stone_reg = player.workersOn.stone
    local n_stone_special = actions.count_special_on_resource(player, "stone")
    local total_stone = n_stone_reg + n_stone_special
    for i = 1, n_stone_reg do
      local cx, cy = board.worker_circle_center(px, py, pw, ph, "right", i, total_stone, panel)
      if (mx - cx)^2 + (my - cy)^2 <= WORKER_R^2 then
        return "worker_right", pi, i
      end
    end
    -- Special workers on right resource (stone)
    local sw_right_idx = 0
    for swi, sw in ipairs(player.specialWorkers) do
      if sw.assigned_to == "stone" then
        sw_right_idx = sw_right_idx + 1
        local cx, cy = board.worker_circle_center(px, py, pw, ph, "right", n_stone_reg + sw_right_idx, total_stone, panel)
        if (mx - cx)^2 + (my - cy)^2 <= WORKER_R^2 then
          return "special_worker_resource", pi, swi
        end
      end
    end

    local rl_x, rl_y, rl_w, rl_h = board.resource_left_rect(px, py, pw, ph, panel)
    if util.point_in_rect(mx, my, rl_x, rl_y, rl_w, rl_h) then
      return "resource_left", pi
    end
    local rr_x, rr_y, rr_w, rr_h = board.resource_right_rect(px, py, pw, ph, panel)
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
board.BFIELD_TILE_W = BFIELD_TILE_W
board.BFIELD_TILE_H = BFIELD_TILE_H
board.BFIELD_GAP = BFIELD_GAP

return board
