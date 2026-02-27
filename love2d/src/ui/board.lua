-- Board layout and drawing: two panels, slots, cards, worker tokens.
-- Exposes LAYOUT and draw(), hit_test() so state/game.lua can use the same geometry.

local card_frame = require("src.ui.card_frame")
local util = require("src.ui.util")
local deck_assets = require("src.ui.deck_assets")
local cards = require("src.game.cards")
local unit_stats = require("src.game.unit_stats")
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
local BTN_SIDE_PAD = 20
local BTN_BOTTOM_PAD = 12
local BTN_STACK_GAP = 8
local STRUCT_TILE_W = 90
local STRUCT_TILE_H_BASE = 50
local STRUCT_TILE_AB_H = 26
local STRUCT_TILE_GAP = 8
local BASE_CARD_H = 170
local RESOURCE_BAR_H = 34
local RESOURCE_BAR_LEFT_PAD = 10
local RESOURCE_BAR_MAX_COLS = 4
local RESOURCE_BAR_INNER_PAD_X = 8
local RESOURCE_BAR_INNER_PAD_Y = 6
local RESOURCE_BADGE_W = 48
local RESOURCE_BADGE_H = 24
local RESOURCE_BADGE_GAP_X = 6
local RESOURCE_BADGE_GAP_Y = 6

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

local function count_field_worker_cards(player)
  local total = 0
  for _, entry in ipairs(player.board) do
    local ok, def = pcall(cards.get_card_def, entry.card_id)
    if ok and def and def.kind == "Worker" then
      total = total + 1
    end
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

local function has_static_effect(card_def, effect_name)
  if not card_def or not card_def.abilities then return false end
  for _, ab in ipairs(card_def.abilities) do
    if ab.type == "static" and ab.effect == effect_name then
      return true
    end
  end
  return false
end

local function can_attack_multiple_times(card_def)
  return has_static_effect(card_def, "can_attack_multiple_times")
    or has_static_effect(card_def, "can_attack_twice")
end

local function can_stage_attack_target(game_state, attacker_pi, attacker_board_index, target_pi, target_index)
  local atk_player = game_state.players[attacker_pi + 1]
  local def_player = game_state.players[target_pi + 1]
  if not atk_player or not def_player then return false end

  local atk_entry = atk_player.board and atk_player.board[attacker_board_index]
  if not atk_entry then return false end
  local atk_ok, atk_def = pcall(cards.get_card_def, atk_entry.card_id)
  if not atk_ok or not atk_def then return false end
  if atk_def.kind ~= "Unit" and atk_def.kind ~= "Worker" then return false end

  local atk_state = atk_entry.state or {}
  if unit_stats.effective_attack(atk_def, atk_state, game_state, attacker_pi) <= 0 then return false end
  if atk_state.rested then return false end
  if atk_state.attacked_turn == game_state.turnNumber and not can_attack_multiple_times(atk_def) then
    return false
  end

  local immediate_attack = false
  for _, kw in ipairs(atk_def.keywords or {}) do
    local low = string.lower(kw)
    if low == "rush" or low == "haste" then
      immediate_attack = true
      break
    end
  end
  if atk_state.summoned_turn == game_state.turnNumber and not immediate_attack then
    return false
  end

  if target_index == 0 then
    return true
  end

  local target_entry = def_player.board and def_player.board[target_index]
  if not target_entry then return false end
  local tgt_ok, tgt_def = pcall(cards.get_card_def, target_entry.card_id)
  if not tgt_ok or not tgt_def then return false end
  if tgt_def.kind ~= "Unit" and tgt_def.kind ~= "Worker" and tgt_def.kind ~= "Structure" and tgt_def.kind ~= "Artifact" then
    return false
  end
  if (tgt_def.kind == "Structure" or tgt_def.kind == "Artifact") and tgt_def.health == nil then
    return false
  end

  if tgt_def.kind == "Unit" or tgt_def.kind == "Worker" then
    local target_state = target_entry.state or {}
    if target_state.rested then return true end
    return has_static_effect(atk_def, "can_attack_non_rested")
  end

  return true
end

local function is_worker_drag_source(from)
  return from == "unassigned"
    or from == "left"
    or from == "right"
    or from == "structure"
    or from == "special"
    or from == "special_field"
    or from == "unit_worker_card"
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
-- Panel 1 (opponent): resources/base at top (their backline), then back row,
-- then front row (closest to center).
function board.front_row_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local left_edge = panel_x + 20 + DECK_CARD_W + 16
  local right_edge = panel_x + panel_w - 20 - DECK_CARD_W - 16
  local area_w = right_edge - left_edge
  if panel_index == 0 then
    return left_edge, panel_y + 4, area_w, BFIELD_TILE_H
  else
    local opponent_back_y = panel_y + RESOURCE_NODE_H + 12
    local opponent_front_y = opponent_back_y + BFIELD_TILE_H + BFIELD_ROW_GAP
    return left_edge, opponent_front_y, area_w, BFIELD_TILE_H
  end
end

function board.back_row_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local left_edge = panel_x + 20 + DECK_CARD_W + 16
  local right_edge = panel_x + panel_w - 20 - DECK_CARD_W - 16
  local area_w = right_edge - left_edge
  if panel_index == 0 then
    return left_edge, panel_y + 4 + BFIELD_TILE_H + BFIELD_ROW_GAP, area_w, BFIELD_TILE_H
  else
    local opponent_back_y = panel_y + RESOURCE_NODE_H + 12
    return left_edge, opponent_back_y, area_w, BFIELD_TILE_H
  end
end

-- Base: centered horizontally, aligned with the resource-node row.
function board.base_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local x = panel_x + panel_w / 2 - BFIELD_TILE_W / 2
  local res_y
  if panel_index == 0 then
    res_y = panel_y + panel_h - RESOURCE_NODE_H - 8
  else
    res_y = panel_y + 8
  end
  local y = res_y + (RESOURCE_NODE_H - BFIELD_TILE_H) / 2
  return x, y, BFIELD_TILE_W, BFIELD_TILE_H
end

-- Resource nodes:
-- panel 0 (you): bottom edge
-- panel 1 (opponent): top edge (backline)
function board.resource_left_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local center_x = panel_x + panel_w * 0.25
  local x = center_x - RESOURCE_NODE_W / 2
  local y
  if panel_index == 0 then
    y = panel_y + panel_h - RESOURCE_NODE_H - 8
  else
    y = panel_y + 8
  end
  return x, y, RESOURCE_NODE_W, RESOURCE_NODE_H
end

function board.resource_right_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local center_x = panel_x + panel_w * 0.75
  local x = center_x - RESOURCE_NODE_W / 2
  local y
  if panel_index == 0 then
    y = panel_y + panel_h - RESOURCE_NODE_H - 8
  else
    y = panel_y + 8
  end
  return x, y, RESOURCE_NODE_W, RESOURCE_NODE_H
end

function board.blueprint_slot_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local panel = panel_index or 0
  local by
  if panel == 0 then
    by = panel_y + 8
  else
    by = panel_y + panel_h - DECK_CARD_H - 8
  end
  return panel_x + 20, by, DECK_CARD_W, DECK_CARD_H
end

function board.worker_slot_rect(panel_x, panel_y, panel_w, panel_h)
  return panel_x + 20, panel_y + 8 + DECK_CARD_H + 8, 120, SLOT_H
end

function board.unit_slot_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local _, back_y = board.back_row_rect(panel_x, panel_y, panel_w, panel_h, panel_index or 0)
  return panel_x + panel_w - 20 - DECK_CARD_W, back_y, DECK_CARD_W, DECK_CARD_H
end

-- Graveyard zone: mirrored by panel (local above deck, opponent below deck).
local GRAVEYARD_SLOT_H = 30
function board.graveyard_slot_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local panel = panel_index or 0
  local udx, udy, udw, udh = board.unit_slot_rect(panel_x, panel_y, panel_w, panel_h, panel)
  local gy
  if panel == 0 then
    gy = udy - GRAVEYARD_SLOT_H - 8
    if gy < panel_y + 4 then
      gy = panel_y + 4
    end
  else
    gy = udy + udh + 8
    local max_gy = panel_y + panel_h - GRAVEYARD_SLOT_H - 4
    if gy > max_gy then
      gy = max_gy
    end
  end
  return udx, gy, udw, GRAVEYARD_SLOT_H
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

-- Resource bar: local panel anchored at resource row; opponent panel anchored top-left.
function board.resource_bar_rect(panel_index)
  local px, py, pw, ph = board.panel_rect(panel_index)
  local bar_x = px + RESOURCE_BAR_LEFT_PAD
  local bar_w = pw - (RESOURCE_BAR_LEFT_PAD + 20)
  local min_w = RESOURCE_BADGE_W + RESOURCE_BAR_INNER_PAD_X * 2
  if bar_w < min_w then bar_w = min_w end

  if panel_index == 0 then
    local bar_bottom = py + ph - 8
    local ebx = board.end_turn_button_rect(px, py, pw, ph)
    bar_w = math.min(bar_w, ebx - bar_x - 12)
    local _, ry, _, rh = board.resource_left_rect(px, py, pw, ph, panel_index)
    -- Match visual bottoms: resource nodes render with a small +3 shadow.
    bar_bottom = ry + rh + 3
    return bar_x, bar_bottom - RESOURCE_BAR_H, bar_w, RESOURCE_BAR_H
  end

  return bar_x, py + 8, bar_w, RESOURCE_BAR_H
end

-- Pass button: stacked above End Turn on the local player's panel
function board.pass_button_rect(panel_x, panel_y, panel_w, panel_h)
  local etx, ety, etw = board.end_turn_button_rect(panel_x, panel_y, panel_w, panel_h)
  local pass_x = etx + math.floor((etw - PASS_BTN_W) / 2)
  return pass_x, ety - PASS_BTN_H - BTN_STACK_GAP, PASS_BTN_W, PASS_BTN_H
end

-- End turn button: bottom right of each player's panel
function board.end_turn_button_rect(panel_x, panel_y, panel_w, panel_h)
  return panel_x + panel_w - END_TURN_BTN_W - BTN_SIDE_PAD, panel_y + panel_h - END_TURN_BTN_H - BTN_BOTTOM_PAD, END_TURN_BTN_W, END_TURN_BTN_H
end

-- Unassigned workers pool: adjacent to the base (prefers right side, falls back left).
local UNASSIGNED_POOL_W = 100
local UNASSIGNED_POOL_H = 36

function board.unassigned_pool_rect(panel_x, panel_y, panel_w, panel_h, player, panel_index)
  local panel = panel_index or 0
  local gap = 8
  local bx, by, bw, bh = board.base_rect(panel_x, panel_y, panel_w, panel_h, panel)
  local rlx, _, rlw = board.resource_left_rect(panel_x, panel_y, panel_w, panel_h, panel)
  local rrx = board.resource_right_rect(panel_x, panel_y, panel_w, panel_h, panel)

  local left_bound = rlx + rlw + gap
  local right_bound = rrx - gap - UNASSIGNED_POOL_W
  local preferred_right_x = bx + bw + gap
  local preferred_left_x = bx - gap - UNASSIGNED_POOL_W

  local pool_x
  if preferred_right_x <= right_bound then
    pool_x = preferred_right_x
  elseif preferred_left_x >= left_bound then
    pool_x = preferred_left_x
  else
    pool_x = math.max(left_bound, math.min(preferred_right_x, right_bound))
  end

  local panel_min_x = panel_x + 20
  local panel_max_x = panel_x + panel_w - 20 - UNASSIGNED_POOL_W
  pool_x = math.max(panel_min_x, math.min(pool_x, panel_max_x))

  local pool_y = by + bh / 2 - UNASSIGNED_POOL_H / 2
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
  local badge_w = RESOURCE_BADGE_W
  local badge_h = RESOURCE_BADGE_H
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
  res_icons.draw(res_type, x + 3, icon_y, icon_size)
  -- Number text
  love.graphics.setFont(util.get_font(13))
  love.graphics.setColor(r, g, b, 1.0)
  love.graphics.print(tostring(math.floor(show + 0.5)), x + icon_size + 6, y + 4)

  -- Static upcoming upkeep indicator (inside the badge to avoid overlap when wrapped).
  if pending_upkeep and pending_upkeep > 0 then
    local up_text = "-" .. tostring(pending_upkeep)
    local up_font = util.get_font(8)
    love.graphics.setFont(up_font)
    love.graphics.setColor(0.95, 0.45, 0.45, 0.95)
    local tw = up_font:getWidth(up_text)
    love.graphics.print(up_text, x + badge_w - tw - 3, y + 1)
  end
  return badge_w + RESOURCE_BADGE_GAP_X
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

local function draw_turn_ownership_badges(px, py, pw, panel, is_active, accent, t)
  local turn_label
  if panel == 0 then
    turn_label = is_active and "YOUR TURN" or "WAITING"
  else
    turn_label = is_active and "OPPONENT TURN" or "WAITING"
  end

  local turn_font = util.get_title_font(12)
  local turn_w = turn_font:getWidth(turn_label) + 20
  local turn_h = turn_font:getHeight() + 8
  local turn_x = px + pw - turn_w - 8
  local turn_y = py + 6

  if is_active then
    love.graphics.setColor(accent[1], accent[2], accent[3], 0.34)
    love.graphics.rectangle("fill", turn_x - 2, turn_y - 2, turn_w + 4, turn_h + 4, 7, 7)
    love.graphics.setColor(0.08, 0.11, 0.16, 0.92)
    love.graphics.rectangle("fill", turn_x, turn_y, turn_w, turn_h, 6, 6)
    love.graphics.setColor(accent[1], accent[2], accent[3], 0.82)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", turn_x, turn_y, turn_w, turn_h, 6, 6)
    love.graphics.setLineWidth(1)
  else
    love.graphics.setColor(0.06, 0.08, 0.12, 0.82)
    love.graphics.rectangle("fill", turn_x, turn_y, turn_w, turn_h, 6, 6)
    love.graphics.setColor(0.45, 0.5, 0.62, 0.45)
    love.graphics.rectangle("line", turn_x, turn_y, turn_w, turn_h, 6, 6)
  end
  love.graphics.setFont(turn_font)
  love.graphics.setColor(0.90, 0.93, 0.98, is_active and 1.0 or 0.75)
  love.graphics.printf(turn_label, turn_x, turn_y + 4, turn_w, "center")
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
local function state_signature(v)
  local tv = type(v)
  if tv == "nil" then return "nil" end
  if tv == "number" or tv == "boolean" then return tostring(v) end
  if tv == "string" then return string.format("%q", v) end
  if tv ~= "table" then return "<" .. tv .. ">" end

  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)

  local parts = {"{"}
  for i, ks in ipairs(keys) do
    local key_val = v[ks]
    if key_val == nil then
      local as_num = tonumber(ks)
      if as_num ~= nil then key_val = v[as_num] end
    end
    parts[#parts + 1] = ks .. ":" .. state_signature(key_val)
    if i < #keys then parts[#parts + 1] = "," end
  end
  parts[#parts + 1] = "}"
  return table.concat(parts)
end

local function canonical_unit_state_for_stack(state)
  local st = {}
  if type(state) == "table" then
    for k, v in pairs(state) do
      st[k] = v
    end
  end

  -- Keep rest-state strictly boolean for cleanup consistency.
  if st.rested == nil then st.rested = false end
  if st.damage == 0 then st.damage = nil end

  return st
end

local function group_board_entries(player, kind_filter, forced_singletons)
  local groups = {}
  local group_map = {}
  forced_singletons = forced_singletons or {}
  for si, entry in ipairs(player.board) do
    local ok, def = pcall(cards.get_card_def, entry.card_id)
    if ok and def then
      local dominated = (kind_filter == "Structure") and (def.kind == "Structure" or def.kind == "Artifact")
      local is_unit = (kind_filter == "Unit") and (def.kind ~= "Structure" and def.kind ~= "Artifact")
      if dominated or is_unit then
        local key = entry.card_id
        if is_unit then
          local st = canonical_unit_state_for_stack(entry.state)
          local state_key = state_signature(st)
          if forced_singletons[si] then
            key = "single:" .. tostring(si)
          elseif st.stack_id ~= nil then
            -- Keep stack grouping card-specific so mixed-card stacks never collapse
            -- into a single clickable tile with the wrong board index/card identity.
            key = "stack:" .. tostring(st.stack_id) .. ":card:" .. tostring(entry.card_id) .. ":state:" .. state_key
          else
            key = "unit:" .. tostring(entry.card_id) .. ":state:" .. state_key
          end
        end

        if group_map[key] then
          local g = groups[group_map[key]]
          g.count = g.count + 1
          g.entries[#g.entries + 1] = si
        else
          group_map[key] = #groups + 1
          groups[#groups + 1] = { card_id = entry.card_id, count = 1, first_si = si, scale = entry.scale, entries = { si } }
        end
      end
    end
  end
  return groups
end

local function build_forced_singletons(pi, game_state, combat_ui, local_player_index)
  local forced = {}
  local c = game_state and game_state.pendingCombat
  if c then
    if c.attacker == pi then
      for _, a in ipairs(c.attackers or {}) do
        if a and a.board_index then forced[a.board_index] = true end
      end
    end
    if c.defender == pi then
      for _, b in ipairs(c.blockers or {}) do
        if b and b.blocker_board_index then forced[b.blocker_board_index] = true end
      end
      -- If a specific defender unit is being attacked, force it out of its stack
      -- so target selection/feedback reflects the exact chosen defender.
      for _, a in ipairs(c.attackers or {}) do
        if a and a.target and a.target.type == "board" and a.target.index then
          forced[a.target.index] = true
        end
      end
      -- During attack-trigger targeting, keep selected targets split from stacks.
      for _, trigger in ipairs(c.attack_triggers or {}) do
        if trigger and trigger.target_board_index and trigger.target_board_index > 0 then
          forced[trigger.target_board_index] = true
        end
      end
    end
  end

  if combat_ui and local_player_index == pi then
    for _, a in ipairs(combat_ui.pending_attack_declarations or {}) do
      if a and a.attacker_board_index then forced[a.attacker_board_index] = true end
    end
    for _, b in ipairs(combat_ui.pending_block_assignments or {}) do
      if b and b.blocker_board_index then forced[b.blocker_board_index] = true end
    end
  elseif combat_ui and local_player_index ~= pi then
    -- While staging local attack declarations, force currently targeted defender
    -- units out of stacks for clear target feedback.
    for _, a in ipairs(combat_ui.pending_attack_declarations or {}) do
      if a and a.target and a.target.type == "board" and a.target.index then
        forced[a.target.index] = true
      end
    end
    for _, item in ipairs(combat_ui.pending_attack_trigger_targets or {}) do
      if item and item.target_board_index and item.target_board_index > 0 then
        forced[item.target_board_index] = true
      end
    end
  end
  return forced
end

-- Draw a single battlefield tile (used for base, structures, and units)
local function draw_battlefield_tile(tx, ty, tw, th, group, sdef, pi, game_state, is_active, accent, hover, drag, t, player, is_base)
  local si = group.first_si
  local scale = (group.scale == nil) and 1 or group.scale
  local tile_cx, tile_cy = tx + tw / 2, ty + th / 2
  local tile_hovered = hover and hover.kind == "structure" and hover.pi == pi and hover.idx == si
  local entry = (not is_base and player.board and player.board[si]) and player.board[si] or nil
  local st = entry and entry.state or nil
  local tile_rested = (not is_base) and st and st.rested == true or false

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
  elseif (sdef.kind == "Structure" or sdef.kind == "Artifact") and sdef.health then
    local effective_health = unit_stats.effective_health(sdef, st, game_state, pi)
    local damage_taken = (st and st.damage) or 0
    local life = math.max(0, effective_health - damage_taken)
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
    if damage_taken > 0 then
      love.graphics.setColor(1.0, 0.8, 0.8, alpha)
    else
      love.graphics.setColor(1, 1, 1, alpha)
    end
    love.graphics.setFont(util.get_font(10))
    love.graphics.printf("HP " .. tostring(life), tx + 4, stat_y + stat_h / 2 - 6, badge_w, "center")
  elseif (sdef.kind == "Unit" or sdef.kind == "Worker") and sdef.attack and sdef.health then
    local attack_bonus = unit_stats.attack_bonus(st)
    local health_bonus = unit_stats.health_bonus(st)
    local effective_attack = unit_stats.effective_attack(sdef, st, game_state, pi)
    local effective_health = unit_stats.effective_health(sdef, st, game_state, pi)
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
    if attack_bonus > 0 then
      love.graphics.setColor(0.75, 1.0, 0.75, alpha)
    elseif attack_bonus < 0 then
      love.graphics.setColor(1.0, 0.75, 0.75, alpha)
    else
      love.graphics.setColor(1, 1, 1, alpha)
    end
    love.graphics.setFont(util.get_font(10))
    love.graphics.printf("ATK " .. tostring(effective_attack), tx + 4, stat_y + stat_h / 2 - 6, half_w, "center")
    -- HP badge (right)
    local right_x = tx + tw - 4 - half_w
    love.graphics.setColor(0.2, 0.35, 0.2, 0.35 * alpha)
    love.graphics.rectangle("fill", right_x, stat_y, half_w, stat_h, 3, 3)
    love.graphics.setColor(0.3, 0.55, 0.3, 0.5 * alpha)
    love.graphics.rectangle("line", right_x, stat_y, half_w, stat_h, 3, 3)
    love.graphics.setColor(1, 1, 1, 0.05)
    love.graphics.rectangle("fill", right_x + 1, stat_y + 1, half_w - 2, 1)
    if health_bonus > 0 then
      love.graphics.setColor(0.75, 1.0, 0.75, alpha)
    elseif health_bonus < 0 then
      love.graphics.setColor(1.0, 0.75, 0.75, alpha)
    else
      love.graphics.setColor(1, 1, 1, alpha)
    end
    love.graphics.setFont(util.get_font(10))
    love.graphics.printf("HP " .. tostring(effective_health), right_x, stat_y + stat_h / 2 - 6, half_w, "center")

    if attack_bonus ~= 0 or health_bonus ~= 0 then
      local mods = {}
      if attack_bonus ~= 0 then
        mods[#mods + 1] = (attack_bonus > 0 and "+" or "") .. tostring(attack_bonus) .. "ATK"
      end
      if health_bonus ~= 0 then
        mods[#mods + 1] = (health_bonus > 0 and "+" or "") .. tostring(health_bonus) .. "HP"
      end
      local mod_text = table.concat(mods, " ")
      local mod_font = util.get_font(8)
      local tag_w = math.min(tw - 8, mod_font:getWidth(mod_text) + 8)
      local tag_h = 12
      local tag_x = tx + 4
      local tag_y = ty + 20
      if attack_bonus > 0 or health_bonus > 0 then
        love.graphics.setColor(0.12, 0.28, 0.12, 0.92)
        love.graphics.rectangle("fill", tag_x, tag_y, tag_w, tag_h, 3, 3)
        love.graphics.setColor(0.55, 0.9, 0.55, 0.9)
        love.graphics.rectangle("line", tag_x, tag_y, tag_w, tag_h, 3, 3)
        love.graphics.setColor(0.9, 1.0, 0.9, 1.0)
      else
        love.graphics.setColor(0.32, 0.12, 0.12, 0.92)
        love.graphics.rectangle("fill", tag_x, tag_y, tag_w, tag_h, 3, 3)
        love.graphics.setColor(0.9, 0.55, 0.55, 0.9)
        love.graphics.rectangle("line", tag_x, tag_y, tag_w, tag_h, 3, 3)
        love.graphics.setColor(1.0, 0.9, 0.9, 1.0)
      end
      love.graphics.setFont(mod_font)
      love.graphics.printf(mod_text, tag_x, tag_y + 2, tag_w, "center")
    end
  end

  local alpha = is_active and 1.0 or 0.6
  local ab_btn_y = is_base and (ty + 36) or (ty + 34)
  local has_non_activated_hint = nil
  local _c_rnd = game_state.pendingCombat
  local _in_blocker_window_rnd = _c_rnd and _c_rnd.stage == "DECLARED"
    and (pi == _c_rnd.attacker or pi == _c_rnd.defender)
  if sdef.abilities then
    for ai, ab in ipairs(sdef.abilities) do
      if ab.type == "activated" then
        local source_key
        local source_ref
        if is_base then
          source_key = "base:" .. ai
          source_ref = { type = "base" }
        else
          source_key = "board:" .. si .. ":" .. ai
          source_ref = { type = "board", index = si }
        end
        local used = abilities.is_activated_ability_used_this_turn(game_state, pi, source_key, source_ref, ai)
        local source_entry = (not is_base) and player.board[si] or nil
        local can_pay_ab = abilities.can_pay_activated_ability_costs(player.resources, ab, {
          source_entry = source_entry,
          require_variable_min = true,
        })
        local can_act = (not used or not ab.once_per_turn) and can_pay_ab
          and (is_active or (ab.fast and _in_blocker_window_rnd))
          and (ab.effect ~= "play_spell" or #abilities.find_matching_spell_hand_indices(player, ab.effect_args or {}) > 0)
          and (ab.effect ~= "discard_draw" or #player.hand >= (ab.effect_args and ab.effect_args.discard or 2))
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

  -- Counter badges (below ability buttons, left-aligned)
  if st and unit_stats.has_counters(st) then
    local all_c = unit_stats.all_counters(st)
    if all_c then
      local counter_font = util.get_font(8)
      local counter_colors = {
        growth    = { bg = {0.15, 0.35, 0.12}, border = {0.45, 0.75, 0.35}, text = {0.85, 1.0, 0.8} },
        knowledge = { bg = {0.12, 0.18, 0.35}, border = {0.35, 0.50, 0.85}, text = {0.8, 0.88, 1.0} },
        wonder    = { bg = {0.35, 0.25, 0.12}, border = {0.85, 0.65, 0.25}, text = {1.0, 0.95, 0.75} },
        honor     = { bg = {0.30, 0.12, 0.12}, border = {0.75, 0.35, 0.35}, text = {1.0, 0.85, 0.85} },
      }
      local default_color = { bg = {0.2, 0.2, 0.25}, border = {0.5, 0.5, 0.6}, text = {0.9, 0.9, 0.95} }
      local counter_y = ab_btn_y + 2
      for name, count in pairs(all_c) do
        local colors = counter_colors[name] or default_color
        local label = tostring(count) .. " " .. name:sub(1, 1):upper() .. name:sub(2)
        local cw = math.min(tw - 8, counter_font:getWidth(label) + 8)
        local ch = 12
        local cx = tx + 4
        love.graphics.setColor(colors.bg[1], colors.bg[2], colors.bg[3], 0.92 * alpha)
        love.graphics.rectangle("fill", cx, counter_y, cw, ch, 3, 3)
        love.graphics.setColor(colors.border[1], colors.border[2], colors.border[3], 0.9 * alpha)
        love.graphics.rectangle("line", cx, counter_y, cw, ch, 3, 3)
        love.graphics.setColor(colors.text[1], colors.text[2], colors.text[3], alpha)
        love.graphics.setFont(counter_font)
        love.graphics.printf(label, cx, counter_y + 2, cw, "center")
        counter_y = counter_y + ch + 2
      end
    end
  end

  if tile_rested then
    -- Rested visual state: cool tint + subtle diagonal hatch + status tag.
    love.graphics.setColor(0.04, 0.07, 0.12, 0.42)
    love.graphics.rectangle("fill", tx, ty, tw, th, 5, 5)

    love.graphics.setScissor(tx, ty, tw, th)
    love.graphics.setColor(0.62, 0.76, 0.98, 0.22)
    love.graphics.setLineWidth(1)
    for stripe = -th, tw + th, 10 do
      love.graphics.line(tx + stripe, ty + th, tx + stripe + th, ty)
    end
    love.graphics.setScissor()

    love.graphics.setColor(0.70, 0.84, 1.0, is_active and 0.85 or 0.65)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", tx + 1, ty + 1, tw - 2, th - 2, 5, 5)
    love.graphics.setLineWidth(1)

    local tag_w, tag_h = 48, 14
    local tag_x, tag_y = tx + 4, ty + 4
    love.graphics.setColor(0.08, 0.14, 0.24, 0.92)
    love.graphics.rectangle("fill", tag_x, tag_y, tag_w, tag_h, 3, 3)
    love.graphics.setColor(0.60, 0.80, 1.0, 0.9)
    love.graphics.rectangle("line", tag_x, tag_y, tag_w, tag_h, 3, 3)
    love.graphics.setColor(0.90, 0.96, 1.0, 0.95)
    love.graphics.setFont(util.get_font(8))
    love.graphics.printf("RESTED", tag_x, tag_y + 2, tag_w, "center")
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
      love.graphics.setColor(accent[1], accent[2], accent[3], 0.16)
      love.graphics.rectangle("fill", px - 4, py - 4, pw + 8, ph + 8, 10, 10)
      love.graphics.setColor(accent[1], accent[2], accent[3], 0.7)
      love.graphics.rectangle("fill", px, py + 4, 3, ph - 8)
      love.graphics.rectangle("fill", px + pw - 3, py + 4, 3, ph - 8)
      love.graphics.setColor(accent[1], accent[2], accent[3], 0.68)
      love.graphics.setLineWidth(2.5)
      love.graphics.rectangle("line", px - 2, py - 2, pw + 4, ph + 4, 9, 9)
      love.graphics.setLineWidth(1)
    end

    -- Accent line at top of panel
    love.graphics.setColor(accent[1], accent[2], accent[3], 0.5)
    love.graphics.rectangle("fill", px + 4, py + 1, pw - 8, 1)

    draw_turn_ownership_badges(px, py, pw, panel, is_active, accent, t)

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
    local gx, gy, gwz, ghz = board.graveyard_slot_rect(px, py, pw, ph, panel)
    local gy_hover = is_hovered(hover, "graveyard", pi)
    love.graphics.setColor(0.09, 0.10, 0.14, gy_hover and 0.96 or 0.88)
    love.graphics.rectangle("fill", gx, gy, gwz, ghz, 5, 5)
    if gy_hover then
      love.graphics.setColor(accent[1], accent[2], accent[3], 0.65)
      love.graphics.setLineWidth(2)
      love.graphics.rectangle("line", gx - 1, gy - 1, gwz + 2, ghz + 2, 6, 6)
      love.graphics.setLineWidth(1)
    else
      love.graphics.setColor(0.25, 0.27, 0.33, 0.9)
      love.graphics.rectangle("line", gx, gy, gwz, ghz, 5, 5)
    end
    love.graphics.setColor(0.55, 0.58, 0.68, 0.9)
    love.graphics.setFont(util.get_font(9))
    love.graphics.printf("Graveyard", gx, gy + 4, gwz, "center")
    love.graphics.setColor(0.9, 0.92, 0.98, 1.0)
    love.graphics.setFont(util.get_title_font(11))
    love.graphics.printf(tostring(#(player.graveyard or {})), gx, gy + 15, gwz, "center")

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
    local forced_singletons = build_forced_singletons(pi, game_state, hand_state, local_player_index)
    local unit_groups = group_board_entries(player, "Unit", forced_singletons)
    local unit_start_x = centered_row_x(front_ax, front_aw, #unit_groups)
    for gi, group in ipairs(unit_groups) do
      local ok, udef = pcall(cards.get_card_def, group.card_id)
      if ok and udef then
        local tile_x = unit_start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        draw_battlefield_tile(tile_x, front_ay, BFIELD_TILE_W, BFIELD_TILE_H, group, udef, pi, game_state, is_active, accent, hover, drag, t, player, false)
      end
    end

    -- Attack declaration drag overlay: show legal enemy targets for the dragged attacker.
    if drag and drag.from == "attack_unit" and drag.player_index == local_player_index and pi == (1 - drag.player_index) then
      local attacker_pi = drag.player_index
      local attacker_board_index = drag.board_index
      local pulse = 0.35 + 0.25 * math.sin(t * 4)

      for gi, group in ipairs(struct_groups) do
        local tile_x = struct_start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        if can_stage_attack_target(game_state, attacker_pi, attacker_board_index, pi, group.first_si) then
          love.graphics.setColor(1.0, 0.82, 0.28, pulse)
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", tile_x - 2, back_ay - 2, BFIELD_TILE_W + 4, BFIELD_TILE_H + 4, 6, 6)
          love.graphics.setLineWidth(1)
        else
          love.graphics.setColor(0, 0, 0, 0.5)
          love.graphics.rectangle("fill", tile_x, back_ay, BFIELD_TILE_W, BFIELD_TILE_H, 5, 5)
        end
      end

      for gi, group in ipairs(unit_groups) do
        local tile_x = unit_start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        if can_stage_attack_target(game_state, attacker_pi, attacker_board_index, pi, group.first_si) then
          love.graphics.setColor(1.0, 0.82, 0.28, pulse)
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", tile_x - 2, front_ay - 2, BFIELD_TILE_W + 4, BFIELD_TILE_H + 4, 6, 6)
          love.graphics.setLineWidth(1)
        else
          love.graphics.setColor(0, 0, 0, 0.5)
          love.graphics.rectangle("fill", tile_x, front_ay, BFIELD_TILE_W, BFIELD_TILE_H, 5, 5)
        end
      end

      if can_stage_attack_target(game_state, attacker_pi, attacker_board_index, pi, 0) then
        love.graphics.setColor(1.0, 0.82, 0.28, pulse)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", base_bx - 2, base_by - 2, BFIELD_TILE_W + 4, BFIELD_TILE_H + 4, 6, 6)
        love.graphics.setLineWidth(1)
      else
        love.graphics.setColor(0, 0, 0, 0.5)
        love.graphics.rectangle("fill", base_bx, base_by, BFIELD_TILE_W, BFIELD_TILE_H, 5, 5)
      end

      love.graphics.setFont(util.get_font(12))
      love.graphics.setColor(1.0, 0.84, 0.35, 0.7 + 0.2 * math.sin(t * 3))
      love.graphics.printf("Select an attack target", px, front_ay - 20, pw, "center")
    end

    -- Sacrifice selection overlay: highlight eligible tiles, dim others
    local sac_indices = hand_state and hand_state.sacrifice_eligible_indices
    if sac_indices and panel == 0 then
      local allow_worker_sacrifice = true
      if hand_state.sacrifice_allow_workers ~= nil then
        allow_worker_sacrifice = hand_state.sacrifice_allow_workers
      end
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
      if allow_worker_sacrifice then
        -- Highlight all worker locations when workers are legal sacrifices.
        local sac_pulse = 0.3 + 0.2 * math.sin(t * 4)
        local uax, uay, uaw, uah = board.unassigned_pool_rect(px, py, pw, ph, player, panel)
        local unassigned = player.totalWorkers - player.workersOn.food - player.workersOn.wood - player.workersOn.stone - count_structure_workers(player) - count_field_worker_cards(player)
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
      end
      -- Prompt banner
      love.graphics.setFont(util.get_font(12))
      love.graphics.setColor(0.9, 0.3, 0.3, 0.7 + 0.2 * math.sin(t * 3))
      love.graphics.printf("Select an ally to sacrifice", px, front_ay - 20, pw, "center")
    end

    -- Monument selection overlay: highlight eligible monuments in gold, dim others
    local mon_indices = hand_state and hand_state.monument_eligible_indices
    if mon_indices and panel == 0 then
      local function is_mon_eligible(si)
        for _, ei in ipairs(mon_indices) do
          if ei == si then return true end
        end
        return false
      end
      -- Dim units
      for gi, group in ipairs(unit_groups) do
        local tile_x = unit_start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        love.graphics.setColor(0, 0, 0, 0.5)
        love.graphics.rectangle("fill", tile_x, front_ay, BFIELD_TILE_W, BFIELD_TILE_H, 5, 5)
      end
      -- Highlight eligible monuments, dim ineligible structures
      for gi, group in ipairs(struct_groups) do
        local tile_x = struct_start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        if is_mon_eligible(group.first_si) then
          local pulse = 0.3 + 0.2 * math.sin(t * 4)
          love.graphics.setColor(0.95, 0.78, 0.2, pulse)
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", tile_x - 2, back_ay - 2, BFIELD_TILE_W + 4, BFIELD_TILE_H + 4, 6, 6)
          love.graphics.setLineWidth(1)
        else
          love.graphics.setColor(0, 0, 0, 0.5)
          love.graphics.rectangle("fill", tile_x, back_ay, BFIELD_TILE_W, BFIELD_TILE_H, 5, 5)
        end
      end
      -- Prompt
      love.graphics.setFont(util.get_font(12))
      love.graphics.setColor(0.95, 0.78, 0.2, 0.7 + 0.2 * math.sin(t * 3))
      love.graphics.printf("Select a Monument", px, back_ay - 20, pw, "center")
    end

    -- Damage target overlay: highlight eligible enemy units/structures, dim others
    local dmg_indices = hand_state and hand_state.damage_target_eligible_indices
    local dmg_target_pi = hand_state and hand_state.damage_target_eligible_player_index
    if dmg_indices and dmg_target_pi == pi then
      local function is_dmg_eligible(si)
        for _, ei in ipairs(dmg_indices) do
          if ei == si then return true end
        end
        return false
      end
      local pulse = 0.3 + 0.2 * math.sin(t * 4)
      for gi, group in ipairs(struct_groups) do
        local tile_x = struct_start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        if is_dmg_eligible(group.first_si) then
          love.graphics.setColor(0.95, 0.3, 0.2, pulse)
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", tile_x - 2, back_ay - 2, BFIELD_TILE_W + 4, BFIELD_TILE_H + 4, 6, 6)
          love.graphics.setLineWidth(1)
        else
          love.graphics.setColor(0, 0, 0, 0.5)
          love.graphics.rectangle("fill", tile_x, back_ay, BFIELD_TILE_W, BFIELD_TILE_H, 5, 5)
        end
      end
      for gi, group in ipairs(unit_groups) do
        local tile_x = unit_start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        if is_dmg_eligible(group.first_si) then
          love.graphics.setColor(0.95, 0.3, 0.2, pulse)
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", tile_x - 2, front_ay - 2, BFIELD_TILE_W + 4, BFIELD_TILE_H + 4, 6, 6)
          love.graphics.setLineWidth(1)
        else
          love.graphics.setColor(0, 0, 0, 0.5)
          love.graphics.rectangle("fill", tile_x, front_ay, BFIELD_TILE_W, BFIELD_TILE_H, 5, 5)
        end
      end
      love.graphics.setFont(util.get_font(12))
      love.graphics.setColor(0.95, 0.3, 0.2, 0.7 + 0.2 * math.sin(t * 3))
      love.graphics.printf("Select a target", px, front_ay - 20, pw, "center")
    end

    -- Global damage target overlay (e.g. Catapult): both panels + bases
    local dmg_by_player = hand_state and hand_state.damage_target_board_indices_by_player
    local dmg_base_pis = hand_state and hand_state.damage_target_base_player_indices
    local dmg_global_indices = dmg_by_player and dmg_by_player[pi]
    local base_eligible = dmg_base_pis and dmg_base_pis[pi]
    if dmg_global_indices or base_eligible then
      local function is_global_eligible(si)
        if not dmg_global_indices then return false end
        for _, ei in ipairs(dmg_global_indices) do
          if ei == si then return true end
        end
        return false
      end
      local pulse = 0.3 + 0.2 * math.sin(t * 4)
      for gi, group in ipairs(struct_groups) do
        local tile_x = struct_start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        if is_global_eligible(group.first_si) then
          love.graphics.setColor(0.95, 0.3, 0.2, pulse)
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", tile_x - 2, back_ay - 2, BFIELD_TILE_W + 4, BFIELD_TILE_H + 4, 6, 6)
          love.graphics.setLineWidth(1)
        else
          love.graphics.setColor(0, 0, 0, 0.5)
          love.graphics.rectangle("fill", tile_x, back_ay, BFIELD_TILE_W, BFIELD_TILE_H, 5, 5)
        end
      end
      for gi, group in ipairs(unit_groups) do
        local tile_x = unit_start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        if is_global_eligible(group.first_si) then
          love.graphics.setColor(0.95, 0.3, 0.2, pulse)
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", tile_x - 2, front_ay - 2, BFIELD_TILE_W + 4, BFIELD_TILE_H + 4, 6, 6)
          love.graphics.setLineWidth(1)
        else
          love.graphics.setColor(0, 0, 0, 0.5)
          love.graphics.rectangle("fill", tile_x, front_ay, BFIELD_TILE_W, BFIELD_TILE_H, 5, 5)
        end
      end
      -- Base tile highlight
      if base_eligible then
        love.graphics.setColor(0.95, 0.3, 0.2, pulse)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", base_bx - 2, base_by - 2, BFIELD_TILE_W + 4, BFIELD_TILE_H + 4, 6, 6)
        love.graphics.setLineWidth(1)
      else
        love.graphics.setColor(0, 0, 0, 0.5)
        love.graphics.rectangle("fill", base_bx, base_by, BFIELD_TILE_W, BFIELD_TILE_H, 5, 5)
      end
      if panel == 0 then
        love.graphics.setFont(util.get_font(12))
        love.graphics.setColor(0.95, 0.3, 0.2, 0.7 + 0.2 * math.sin(t * 3))
        love.graphics.printf("Select a target", px, front_ay - 20, pw, "center")
      end
    end

    -- Counter placement target overlay: highlight eligible allies, dim others
    local ctr_indices = hand_state and hand_state.counter_target_eligible_indices
    if ctr_indices and panel == 0 then
      local function is_ctr_eligible(si)
        for _, ei in ipairs(ctr_indices) do
          if ei == si then return true end
        end
        return false
      end
      -- Dim structures
      for gi, group in ipairs(struct_groups) do
        local tile_x = struct_start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        love.graphics.setColor(0, 0, 0, 0.5)
        love.graphics.rectangle("fill", tile_x, back_ay, BFIELD_TILE_W, BFIELD_TILE_H, 5, 5)
      end
      -- Overlay units
      for gi, group in ipairs(unit_groups) do
        local tile_x = unit_start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        if is_ctr_eligible(group.first_si) then
          local pulse = 0.3 + 0.2 * math.sin(t * 4)
          love.graphics.setColor(0.35, 0.55, 0.95, pulse)
          love.graphics.setLineWidth(2)
          love.graphics.rectangle("line", tile_x - 2, front_ay - 2, BFIELD_TILE_W + 4, BFIELD_TILE_H + 4, 6, 6)
          love.graphics.setLineWidth(1)
        else
          love.graphics.setColor(0, 0, 0, 0.5)
          love.graphics.rectangle("fill", tile_x, front_ay, BFIELD_TILE_W, BFIELD_TILE_H, 5, 5)
        end
      end
      -- Prompt banner
      love.graphics.setFont(util.get_font(12))
      love.graphics.setColor(0.35, 0.65, 0.95, 0.7 + 0.2 * math.sin(t * 3))
      love.graphics.printf("Select an ally to place counters on", px, front_ay - 20, pw, "center")
    end

    -- Resource nodes: title + placeholder only, centered in panel
    local res_left_title = (player.faction == "Human") and "Wood" or "Food"
    local res_left_resource = (player.faction == "Human") and "wood" or "food"
    local rl_x, rl_y, rl_w, rl_h = board.resource_left_rect(px, py, pw, ph, panel)

    -- Drop zone glow on resource nodes when dragging
    if drag and drag.player_index == pi and is_worker_drag_source(drag.from) then
      if drag.from ~= "left" then
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
    if drag and drag.player_index == pi and is_worker_drag_source(drag.from) then
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

    -- Unassigned workers pool (next to base); hide one if we're dragging from this pool
    local uax, uay, uaw, uah = board.unassigned_pool_rect(px, py, pw, ph, player, panel)

    -- Drop zone glow on unassigned pool when dragging from a resource
    if drag and drag.player_index == pi and is_worker_drag_source(drag.from) and drag.from ~= "unassigned" then
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
    local unassigned = player.totalWorkers - player.workersOn.food - player.workersOn.wood - player.workersOn.stone - count_structure_workers(player) - count_field_worker_cards(player)
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
      local entries = {}
      for _, key in ipairs(config.resource_types) do
        local count = player.resources[key] or 0
        local display_val = dr and dr[key]
        local upkeep_due = pending_upkeep[key] or 0
        local rdef = res_registry[key]
        if rdef and (count > 0 or (display_val and display_val > 0.5) or upkeep_due > 0) then
          table.insert(entries, {
            key = key,
            rdef = rdef,
            count = count,
            display_val = display_val,
            upkeep_due = upkeep_due,
          })
        end
      end

      if #entries > 0 then
        local rbx, rby, max_rbw, min_h = board.resource_bar_rect(panel)
        local desired_cols = math.min(RESOURCE_BAR_MAX_COLS, #entries)
        local desired_w = RESOURCE_BAR_INNER_PAD_X * 2
          + desired_cols * RESOURCE_BADGE_W
          + (desired_cols - 1) * RESOURCE_BADGE_GAP_X
        local rbw = math.min(max_rbw, desired_w)
        local usable_w = math.max(RESOURCE_BADGE_W, rbw - RESOURCE_BAR_INNER_PAD_X * 2)
        local badges_per_row = math.max(1, math.min(
          RESOURCE_BAR_MAX_COLS,
          math.floor((usable_w + RESOURCE_BADGE_GAP_X) / (RESOURCE_BADGE_W + RESOURCE_BADGE_GAP_X))
        ))
        local row_count = math.ceil(#entries / badges_per_row)
        local content_h = row_count * RESOURCE_BADGE_H + (row_count - 1) * RESOURCE_BADGE_GAP_Y
        local bar_h = math.max(min_h, content_h + RESOURCE_BAR_INNER_PAD_Y * 2)

        if panel == 0 then
          -- Local panel: keep bottom anchored and grow upward as rows are added.
          rby = rby + (min_h - bar_h)
        end

        -- Background
        love.graphics.setColor(0.06, 0.07, 0.10, 0.92)
        love.graphics.rectangle("fill", rbx, rby, rbw, bar_h, 6, 6)
        -- Accent line at top
        love.graphics.setColor(accent[1], accent[2], accent[3], 0.4)
        love.graphics.rectangle("fill", rbx + 4, rby, rbw - 8, 1)
        -- Subtle border
        love.graphics.setColor(0.18, 0.20, 0.25, 0.6)
        love.graphics.rectangle("line", rbx, rby, rbw, bar_h, 6, 6)

        for i, entry in ipairs(entries) do
          local col = (i - 1) % badges_per_row
          local row
          if panel == 0 then
            local row_from_bottom = math.floor((i - 1) / badges_per_row)
            row = (row_count - 1) - row_from_bottom
          else
            row = math.floor((i - 1) / badges_per_row)
          end
          local badge_x = rbx + RESOURCE_BAR_INNER_PAD_X + col * (RESOURCE_BADGE_W + RESOURCE_BADGE_GAP_X)
          local badge_y = rby + RESOURCE_BAR_INNER_PAD_Y + row * (RESOURCE_BADGE_H + RESOURCE_BADGE_GAP_Y)
          local rc, gc, bc = entry.rdef.color[1], entry.rdef.color[2], entry.rdef.color[3]
          draw_resource_badge(badge_x, badge_y, entry.key, entry.rdef.letter, entry.count, rc, gc, bc, entry.display_val, entry.upkeep_due)
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
            subtypes = def.subtypes or {},
            text = def.text,
            costs = def.costs,
            upkeep = def.upkeep,
            tier = abilities.effective_tier_for_card(local_p, def),
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
          -- Discard selection: orange glow for selected-for-discard cards
          if hand_state.discard_selected_set and hand_state.discard_selected_set[i] then
            local pulse = 0.5 + 0.25 * math.sin(t * 4)
            love.graphics.setColor(0.9, 0.4, 0.1, pulse)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", r.x - 2, r.y - 2, r.w + 4, r.h + 4, 6, 6)
            love.graphics.setLineWidth(1)
          end
          -- Selected glow (normal mode only)
          if i == selected_idx and not eligible_set and not hand_state.discard_selected_set then
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
        -- Enlarged card dimensions: width fixed, height auto-sized to content
        local hover_w = math.floor(CARD_W * HAND_HOVER_SCALE)
        local hover_h = card_frame.measure_full_height({
          w = hover_w, faction = def.faction, upkeep = def.upkeep,
          abilities_list = def.abilities, text = def.text,
        })
        -- Anchor at center-bottom of the original rect so card grows upward
        local hx = r.x + r.w / 2 - hover_w / 2
        local hy = r.y + r.h - hover_h
        if hy < 4 then hy = 4 end  -- clamp to screen top
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
        -- Draw card (no scale transform needed since HAND_HOVER_SCALE = 1.0)
        card_frame.draw(hx, hy, {
          w = hover_w,
          h = hover_h,
          title = def.name,
          faction = def.faction,
          kind = def.kind,
          subtypes = def.subtypes or {},
          text = def.text,
          costs = def.costs,
          upkeep = def.upkeep,
          attack = def.attack,
          health = def.health or def.baseHealth,
          tier = abilities.effective_tier_for_card(local_p, def),
          abilities_list = def.abilities,
          show_ability_text = true,
        })
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
      local prompt_text = "Select a card to play"
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

-- Hit test: return "activate_base" | "blueprint" | "graveyard" | "worker_*"
-- | "resource_*" | "unassigned_pool" | "pass" | "end_turn" | "hand_card" | nil
function board.hit_test(mx, my, game_state, hand_y_offsets, local_player_index, combat_ui)
  local_player_index = local_player_index or 0
  local ignore_ability_buttons = type(combat_ui) == "table" and combat_ui.ignore_ability_buttons == true
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
      if not ignore_ability_buttons and base_def.abilities then
        local ab_btn_y = base_ty + 36
        for ai, ab in ipairs(base_def.abilities) do
          if ab.type == "activated" then
            if util.point_in_rect(mx, my, base_tx + 4, ab_btn_y, BFIELD_TILE_W - 8, 24) then
              local source_key = "base:" .. ai
              local used = abilities.is_activated_ability_used_this_turn(game_state, pi, source_key, { type = "base" }, ai)
              local _c_base = game_state.pendingCombat
              local _in_blk_base = _c_base and _c_base.stage == "DECLARED"
                and (pi == _c_base.attacker or pi == _c_base.defender)
              local can_pay_ab = abilities.can_pay_activated_ability_costs(player.resources, ab, {
                require_variable_min = true,
              })
              local sel_info = abilities.collect_activated_selection_cost_targets(game_state, pi, ab)
              local has_sel_targets = true
              if sel_info and sel_info.requires_selection then
                has_sel_targets = sel_info.has_any_target == true
              end
              local can_act = (pi == game_state.activePlayer or (ab.fast and _in_blk_base))
                and (not ab.once_per_turn or not used) and can_pay_ab and has_sel_targets
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
        if util.point_in_rect(mx, my, tx, row_ay, tw, th) then
          local si = group.first_si
          if (not ignore_ability_buttons) and s_ok and sdef and sdef.abilities then
            local ab_btn_y = row_ay + 34
            for ai, ab in ipairs(sdef.abilities) do
              if ab.type == "activated" then
                if util.point_in_rect(mx, my, tx + 4, ab_btn_y, tw - 8, 24) then
                  local source_key = "board:" .. si .. ":" .. ai
                  local used = abilities.is_activated_ability_used_this_turn(game_state, pi, source_key, { type = "board", index = si }, ai)
                  local board_entry = player.board[si]
                  local _c_brd = game_state.pendingCombat
                  local _in_blk_brd = _c_brd and _c_brd.stage == "DECLARED"
                    and (pi == _c_brd.attacker or pi == _c_brd.defender)
                  local can_pay_ab = abilities.can_pay_activated_ability_costs(player.resources, ab, {
                    source_entry = board_entry,
                    require_variable_min = true,
                  })
                  local sel_info = abilities.collect_activated_selection_cost_targets(game_state, pi, ab)
                  local has_sel_targets = true
                  if sel_info and sel_info.requires_selection then
                    has_sel_targets = sel_info.has_any_target == true
                  end
                  local can_act = (not ab.once_per_turn or not used) and can_pay_ab
                    and (pi == game_state.activePlayer or (ab.fast and _in_blk_brd))
                    and has_sel_targets
                    and (ab.effect ~= "play_spell" or #abilities.find_matching_spell_hand_indices(player, ab.effect_args or {}) > 0)
                    and (ab.effect ~= "discard_draw" or #player.hand >= (ab.effect_args and ab.effect_args.discard or 2))
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
    local forced_singletons = build_forced_singletons(pi, game_state, combat_ui, local_player_index)
    local unit_groups = group_board_entries(player, "Unit", forced_singletons)
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

    local gyx, gyy, gyw, gyh = board.graveyard_slot_rect(px, py, pw, ph, panel)
    if util.point_in_rect(mx, my, gyx, gyy, gyw, gyh) then
      return "graveyard", pi
    end

    local udx, udy, udw, udh = board.unit_slot_rect(px, py, pw, ph, panel)
    if util.point_in_rect(mx, my, udx, udy, udw, udh) then
      return "unit_deck", pi
    end

    local uax, uay, uaw, uah = board.unassigned_pool_rect(px, py, pw, ph, player, panel)
    if util.point_in_rect(mx, my, uax, uay, uaw, uah) then
      local unassigned = player.totalWorkers - player.workersOn.food - player.workersOn.wood - player.workersOn.stone - count_structure_workers(player) - count_field_worker_cards(player)
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


function board.base_center_for_player(panel_player_index, local_player_index)
  local_player_index = local_player_index or 0
  local panel = (local_player_index == 0) and panel_player_index or (1 - panel_player_index)
  local px, py, pw, ph = board.panel_rect(panel)
  local bx, by, bw, bh = board.base_rect(px, py, pw, ph, panel)
  return bx + bw / 2, by + bh / 2
end

function board.board_entry_center(game_state, panel_player_index, board_index, local_player_index, combat_ui)
  local_player_index = local_player_index or 0
  local panel = (local_player_index == 0) and panel_player_index or (1 - panel_player_index)
  local px, py, pw, ph = board.panel_rect(panel)
  local player = game_state.players[panel_player_index + 1]
  local entry = player and player.board and player.board[board_index]
  if not entry then return nil end
  local ok, def = pcall(cards.get_card_def, entry.card_id)
  if not ok or not def then return nil end

  local groups
  local row_ax, row_ay, row_aw
  if def.kind == "Structure" or def.kind == "Artifact" then
    groups = group_board_entries(player, "Structure")
    row_ax, row_ay, row_aw = board.back_row_rect(px, py, pw, ph, panel)
  else
    local forced_singletons = build_forced_singletons(panel_player_index, game_state, combat_ui, local_player_index)
    groups = group_board_entries(player, "Unit", forced_singletons)
    row_ax, row_ay, row_aw = board.front_row_rect(px, py, pw, ph, panel)
  end

  local start_x = centered_row_x(row_ax, row_aw, #groups)
  for gi, g in ipairs(groups) do
    for _, si in ipairs(g.entries or {}) do
      if si == board_index then
        local tx = start_x + (gi - 1) * (BFIELD_TILE_W + BFIELD_GAP)
        return tx + BFIELD_TILE_W / 2, row_ay + BFIELD_TILE_H / 2
      end
    end
  end
  return nil
end

return board
