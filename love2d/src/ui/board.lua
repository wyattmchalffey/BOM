-- Board layout and drawing: two panels, slots, cards, worker tokens.
-- Exposes LAYOUT and draw(), hit_test() so state/game.lua can use the same geometry.

local card_frame = require("src.ui.card_frame")
local util = require("src.ui.util")
local deck_assets = require("src.ui.deck_assets")
local cards = require("src.game.cards")
local abilities = require("src.game.abilities")
local factions = require("src.data.factions")

local board = {}

local MARGIN = 20
local TOP_MARGIN = 10      -- less space above opponent's board
local GAP_BETWEEN_PANELS = 8
local MARGIN_BOTTOM = 36  -- less below your board; room for End turn + turn label
local CARD_W = card_frame.CARD_W
local CARD_H = card_frame.CARD_H
local RESOURCE_NODE_W = card_frame.RESOURCE_NODE_W
local RESOURCE_NODE_H = card_frame.RESOURCE_NODE_H
local RESOURCE_NODE_GAP = 24
local SLOT_H = 50
local WORKER_R = 10
-- Deck slots drawn as card-shaped (same aspect as CARD_W/CARD_H)
local DECK_CARD_W = 80
local DECK_CARD_H = 110
local DECK_CARD_R = 6
local PASS_BTN_W = 70
local PASS_BTN_H = 28
local END_TURN_BTN_W = 80
local END_TURN_BTN_H = 28
local STRUCT_TILE_W = 90
local STRUCT_TILE_H = 70
local STRUCT_TILE_GAP = 8

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

-- Resource nodes: pushed to lower portion of each panel, leaving upper area free for buildings/units.
-- Player 0 (you): resources sit just above the buttons at the bottom.
-- Player 1 (opponent): resources sit near the bottom of their panel (front of their board).
function board.resource_left_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local center_x = panel_x + panel_w * 0.25
  local x = center_x - RESOURCE_NODE_W / 2
  local y
  if panel_index == 1 then
    y = panel_y + panel_h - RESOURCE_NODE_H - 20
  else
    y = panel_y + panel_h - RESOURCE_NODE_H - 55
  end
  return x, y, RESOURCE_NODE_W, RESOURCE_NODE_H
end

function board.resource_right_rect(panel_x, panel_y, panel_w, panel_h, panel_index)
  local center_x = panel_x + panel_w * 0.75
  local x = center_x - RESOURCE_NODE_W / 2
  local y
  if panel_index == 1 then
    y = panel_y + panel_h - RESOURCE_NODE_H - 20
  else
    y = panel_y + panel_h - RESOURCE_NODE_H - 55
  end
  return x, y, RESOURCE_NODE_W, RESOURCE_NODE_H
end

function board.blueprint_slot_rect(panel_x, panel_y, panel_w, panel_h)
  -- Slight padding below the player resources line
  return panel_x + 20, panel_y + 28, DECK_CARD_W, DECK_CARD_H
end

function board.worker_slot_rect(panel_x, panel_y, panel_w, panel_h)
  return panel_x + 20, panel_y + 20 + DECK_CARD_H + 12, 120, SLOT_H
end

function board.unit_slot_rect(panel_x, panel_y, panel_w, panel_h)
  return panel_x + panel_w - 20 - DECK_CARD_W, panel_y + 20, DECK_CARD_W, DECK_CARD_H
end

-- Built structures area: horizontal row between the two deck slots in the upper-middle area
function board.structures_area_rect(panel_x, panel_y, panel_w, panel_h)
  local left_edge = panel_x + 20 + DECK_CARD_W + 16  -- right of blueprint deck
  local right_edge = panel_x + panel_w - 20 - DECK_CARD_W - 16  -- left of unit deck
  local area_w = right_edge - left_edge
  local area_h = STRUCT_TILE_H
  local area_y = panel_y + 28 + (DECK_CARD_H - STRUCT_TILE_H) / 2  -- vertically centered with deck slots
  return left_edge, area_y, area_w, area_h
end

-- Get rect for a specific structure tile by index (0-based)
function board.structure_tile_rect(panel_x, panel_y, panel_w, panel_h, tile_index)
  local ax, ay, aw, ah = board.structures_area_rect(panel_x, panel_y, panel_w, panel_h)
  local tx = ax + tile_index * (STRUCT_TILE_W + STRUCT_TILE_GAP)
  return tx, ay, STRUCT_TILE_W, STRUCT_TILE_H
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

-- Helper: check if hover matches a specific kind+panel
local function is_hovered(hover, kind, pi)
  return hover and hover.kind == kind and hover.pi == pi
end

-- Helper: draw a colored resource badge pill
local function draw_resource_badge(x, y, letter, count, r, g, b)
  local badge_w = 38
  local badge_h = 18
  -- Pill background
  love.graphics.setColor(r, g, b, 0.25)
  love.graphics.rectangle("fill", x, y, badge_w, badge_h, 4, 4)
  love.graphics.setColor(r, g, b, 0.6)
  love.graphics.rectangle("line", x, y, badge_w, badge_h, 4, 4)
  -- Text
  love.graphics.setFont(util.get_font(11))
  love.graphics.setColor(r, g, b, 1.0)
  love.graphics.print(letter .. ":" .. count, x + 6, y + 2)
  return badge_w + 6
end

-- Helper: draw a worker count badge
local function draw_worker_badge(x, y, current, max_w)
  local badge_w = 52
  local badge_h = 18
  love.graphics.setColor(0.6, 0.6, 0.75, 0.25)
  love.graphics.rectangle("fill", x, y, badge_w, badge_h, 4, 4)
  love.graphics.setColor(0.6, 0.6, 0.75, 0.6)
  love.graphics.rectangle("line", x, y, badge_w, badge_h, 4, 4)
  love.graphics.setFont(util.get_font(11))
  love.graphics.setColor(0.75, 0.76, 0.85, 1.0)
  love.graphics.print("W:" .. current .. "/" .. max_w, x + 6, y + 2)
  return badge_w + 6
end

-- Helper: draw pulsing drop zone glow around a rect
local function draw_drop_zone_glow(x, y, w, h, t)
  local pulse = 0.4 + 0.3 * math.sin(t * 4)
  love.graphics.setColor(0.3, 0.6, 1.0, pulse)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", x - 3, y - 3, w + 6, h + 6, 6, 6)
  love.graphics.setLineWidth(1)
end

-- Draw worker circle with optional pulse and dimming
local function draw_worker_circle(cx, cy, is_active_panel, is_draggable)
  local t = love.timer.getTime()
  local r = WORKER_R
  if is_draggable then
    -- Subtle pulse for draggable workers
    r = WORKER_R + 0.8 * math.sin(t * 3)
  end
  if is_active_panel then
    love.graphics.setColor(0.9, 0.9, 1.0, 1.0)
  else
    love.graphics.setColor(0.7, 0.7, 0.8, 0.7) -- dimmed for inactive
  end
  love.graphics.circle("fill", cx, cy, r)
  if is_active_panel then
    love.graphics.setColor(0.55, 0.58, 1.0, 1.0)
  else
    love.graphics.setColor(0.4, 0.42, 0.6, 0.7)
  end
  love.graphics.circle("line", cx, cy, r)
end

function board.draw(game_state, drag, hover, mouse_down)
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

  for pi = 0, 1 do
    local px, py, pw, ph = board.panel_rect(pi)
    local player = game_state.players[pi + 1]
    local base_def = cards.get_card_def(player.baseId)
    local is_active = (game_state.activePlayer == pi)
    local faction = player.faction
    local accent = get_faction_color(faction)

    -- Panel bg (slightly dimmed if inactive)
    if is_active then
      love.graphics.setColor(0.11, 0.12, 0.15, 1.0)
    else
      love.graphics.setColor(0.09, 0.10, 0.12, 0.85)
    end
    love.graphics.rectangle("fill", px, py, pw, ph, 8, 8)

    -- Panel border
    love.graphics.setColor(0.16, 0.18, 0.22, 1.0)
    love.graphics.rectangle("line", px, py, pw, ph, 8, 8)

    -- Active panel: colored left+right accent border
    if is_active then
      love.graphics.setColor(accent[1], accent[2], accent[3], 0.7)
      love.graphics.rectangle("fill", px, py + 4, 3, ph - 8)
      love.graphics.rectangle("fill", px + pw - 3, py + 4, 3, ph - 8)
    end

    -- Header: Player name + colored resource badges
    local title_suffix = (pi == 0) and " (you)" or " (opponent)"
    love.graphics.setColor(1, 1, 1, is_active and 1.0 or 0.7)
    love.graphics.setFont(util.get_font(12))
    local header_text = "Player " .. (pi + 1) .. " — " .. player.faction .. title_suffix
    love.graphics.print(header_text, px + 20, py + 5)

    -- Resource badges (right of player name)
    local max_workers = player.maxWorkers or 8
    local badge_x = px + 20 + util.get_font(12):getWidth(header_text) + 16
    local badge_y = py + 4
    badge_x = badge_x + draw_resource_badge(badge_x, badge_y, "F", player.resources.food, 0.9, 0.75, 0.2)
    badge_x = badge_x + draw_resource_badge(badge_x, badge_y, "W", player.resources.wood, 0.3, 0.75, 0.35)
    badge_x = badge_x + draw_resource_badge(badge_x, badge_y, "S", player.resources.stone, 0.6, 0.62, 0.68)
    draw_worker_badge(badge_x, badge_y, player.totalWorkers, max_workers)

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
    -- Worker count (no deck slot)
    local wx, wy, ww, wh = board.worker_slot_rect(px, py, pw, ph)
    love.graphics.setColor(0.7, 0.72, 0.78, is_active and 1.0 or 0.6)
    love.graphics.setFont(util.get_font(11))
    love.graphics.print("Workers: " .. player.totalWorkers .. "/" .. max_workers, wx, wy + wh/2 - 6)
    local ux, uy, uw, uh = board.unit_slot_rect(px, py, pw, ph)
    draw_deck_card(ux, uy, uw, uh, "Unit Deck\n(60)", deck_assets.get_unit_back())

    -- Built structures: compact tiles in the upper area between deck slots
    if #player.board > 0 then
      local sax, say, saw, sah = board.structures_area_rect(px, py, pw, ph)
      for si, entry in ipairs(player.board) do
        local ok, sdef = pcall(cards.get_card_def, entry.card_id)
        if ok and sdef then
          local tx, ty, tw, th = board.structure_tile_rect(px, py, pw, ph, si - 1)
          -- Only draw tiles that fit in the area
          if tx + tw <= sax + saw + 2 then
            -- Tile background
            if is_active then
              love.graphics.setColor(0.14, 0.15, 0.2, 1.0)
            else
              love.graphics.setColor(0.11, 0.12, 0.16, 0.85)
            end
            love.graphics.rectangle("fill", tx, ty, tw, th, 5, 5)
            -- Faction-colored left strip
            love.graphics.setColor(accent[1], accent[2], accent[3], is_active and 0.8 or 0.4)
            love.graphics.rectangle("fill", tx, ty + 3, 3, th - 6, 2, 2)
            -- Border
            love.graphics.setColor(0.22, 0.24, 0.3, is_active and 1.0 or 0.6)
            love.graphics.rectangle("line", tx, ty, tw, th, 5, 5)
            -- Structure name (wrap to fit)
            love.graphics.setColor(1, 1, 1, is_active and 1.0 or 0.6)
            love.graphics.setFont(util.get_font(10))
            love.graphics.printf(sdef.name, tx + 8, ty + 6, tw - 12, "left")
            -- Kind label
            love.graphics.setColor(0.6, 0.62, 0.7, is_active and 0.8 or 0.5)
            love.graphics.setFont(util.get_font(9))
            love.graphics.print("Structure", tx + 8, ty + 22)
            -- Small ability hint
            local ab_hint = nil
            if sdef.abilities then
              for _, ab in ipairs(sdef.abilities) do
                if ab.type == "activated" then
                  ab_hint = "ACT"
                  break
                elseif ab.type == "static" and ab.effect == "produce" then
                  ab_hint = "PROD"
                  break
                elseif ab.type == "triggered" then
                  ab_hint = "TRIG"
                  break
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
          end
        end
      end
    end

    -- Base card (with activated ability icon if applicable)
    local base_x, base_y = board.base_rect(px, py, pw, ph, pi)

    local base_ability = cards.get_activated_ability(base_def)
    local base_used = base_ability and game_state.activatedUsedThisTurn and game_state.activatedUsedThisTurn[tostring(pi) .. ":base"]
    local base_can_activate = base_ability and (not base_ability.once_per_turn or not base_used) and abilities.can_pay_cost(player.resources, base_ability.cost)
    card_frame.draw(base_x, base_y, {
      title = base_def.name,
      faction = player.faction,
      kind = "Base",
      typeLine = player.faction .. " — Structure — Base",
      text = base_def.text,
      costs = base_def.costs,
      health = player.life,
      population = base_def.population,
      is_base = true,
      activated_ability = base_ability,
      ability_used_this_turn = base_used,
      ability_can_activate = base_can_activate,
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
      local cx, cy = board.worker_circle_center(px, py, pw, ph, "left", i, n_left, pi)
      draw_worker_circle(cx, cy, is_active, is_active)
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
      local cx, cy = board.worker_circle_center(px, py, pw, ph, "right", i, n_stone, pi)
      draw_worker_circle(cx, cy, is_active, is_active)
    end

    -- Unassigned workers pool (centered); hide one if we're dragging from this pool
    local uax, uay, uaw, uah = board.unassigned_pool_rect(px, py, pw, ph, player)

    -- Drop zone glow on unassigned pool when dragging from a resource
    if drag and drag.player_index == pi and drag.from ~= "unassigned" then
      draw_drop_zone_glow(uax, uay, uaw, uah, t)
    end

    love.graphics.setColor(0.09, 0.1, 0.13, 1.0)
    love.graphics.rectangle("fill", uax, uay, uaw, uah, 4, 4)
    love.graphics.setColor(0.2, 0.22, 0.28, 1.0)
    love.graphics.rectangle("line", uax, uay, uaw, uah, 4, 4)
    local unassigned = player.totalWorkers - player.workersOn.food - player.workersOn.wood - player.workersOn.stone
    local draw_count = unassigned
    if drag and drag.player_index == pi and drag.from == "unassigned" and unassigned > 0 then
      draw_count = unassigned - 1
    end
    local total_w = draw_count * (WORKER_R * 2 + 4) - 4
    if total_w < 0 then total_w = 0 end
    local start_x = uax + uaw / 2 - total_w / 2 + WORKER_R
    for i = 1, draw_count do
      local cx = start_x + (i - 1) * (WORKER_R * 2 + 4)
      local cy = uay + uah / 2
      draw_worker_circle(cx, cy, is_active, is_active)
    end

    -- Pass button with hover/press states
    local pbx, pby, pbw, pbh = board.pass_button_rect(px, py, pw, ph)
    local pass_hovered = is_hovered(hover, "pass", pi)
    local pass_pressed = pass_hovered and mouse_down
    if pass_pressed then
      love.graphics.setColor(0.15, 0.16, 0.22, 1.0)
    elseif pass_hovered then
      love.graphics.setColor(0.28, 0.30, 0.38, 1.0)
    else
      love.graphics.setColor(0.2, 0.22, 0.28, 1.0)
    end
    love.graphics.rectangle("fill", pbx, pby, pbw, pbh, 4, 4)
    love.graphics.setColor(0.3, 0.32, 0.4, 1.0)
    love.graphics.rectangle("line", pbx, pby, pbw, pbh, 4, 4)
    love.graphics.setColor(0.85, 0.86, 0.9, 1.0)
    love.graphics.setFont(util.get_font(12))
    love.graphics.print("Pass", pbx + 20, pby + 6)

    -- End Turn button with hover/press + active accent
    local ebx, eby, ebw, ebh = board.end_turn_button_rect(px, py, pw, ph)
    local et_hovered = is_hovered(hover, "end_turn", pi)
    local et_pressed = et_hovered and mouse_down
    if et_pressed then
      if is_active then
        love.graphics.setColor(0.12, 0.22, 0.18, 1.0)
      else
        love.graphics.setColor(0.15, 0.16, 0.22, 1.0)
      end
    elseif et_hovered then
      if is_active then
        love.graphics.setColor(0.18, 0.32, 0.26, 1.0)
      else
        love.graphics.setColor(0.28, 0.30, 0.38, 1.0)
      end
    else
      if is_active then
        love.graphics.setColor(0.14, 0.26, 0.22, 1.0) -- subtle green tint for active
      else
        love.graphics.setColor(0.2, 0.22, 0.28, 1.0)
      end
    end
    love.graphics.rectangle("fill", ebx, eby, ebw, ebh, 4, 4)
    -- Border: accent colored for active player
    if is_active then
      love.graphics.setColor(0.25, 0.55, 0.4, 0.8)
    else
      love.graphics.setColor(0.3, 0.32, 0.4, 1.0)
    end
    love.graphics.rectangle("line", ebx, eby, ebw, ebh, 4, 4)
    love.graphics.setColor(0.85, 0.86, 0.9, 1.0)
    love.graphics.setFont(util.get_font(12))
    love.graphics.print("End turn", ebx + 12, eby + 6)
  end
end

-- Hit test: return "activate_base" | "blueprint" | "worker_*" | "resource_*" | "unassigned_pool" | "pass" | "end_turn" | nil
function board.hit_test(mx, my, game_state)
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

    -- Activate base ability icon (only active player can activate; must be able to pay)
    local base_x, base_y = board.base_rect(px, py, pw, ph, pi)
    local base_def = cards.get_card_def(player.baseId)

    local base_ability = cards.get_activated_ability(base_def)
    if base_ability and pi == game_state.activePlayer then
      local used = game_state.activatedUsedThisTurn and game_state.activatedUsedThisTurn[tostring(pi) .. ":base"]
      local can_act = (not base_ability.once_per_turn or not used) and abilities.can_pay_cost(player.resources, base_ability.cost)
      if can_act then
        local ix, iy, iw, ih = card_frame.activate_icon_rect(base_x, base_y, CARD_W, CARD_H)
        if util.point_in_rect(mx, my, ix, iy, iw, ih) then
          return "activate_base", pi
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

return board
