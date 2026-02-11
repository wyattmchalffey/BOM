-- Blueprint deck modal: list of structure cards for a faction
-- Click an affordable card to build it.

local card_frame = require("src.ui.card_frame")
local util = require("src.ui.util")
local cards = require("src.game.cards")
local abilities = require("src.game.abilities")
local factions_data = require("src.data.factions")

local modal = {}

local PAD = 24
local CARD_W = card_frame.CARD_W
local CARD_H = card_frame.CARD_H
local GRID_PAD = 12

-- Stored each frame so hit_test_card can use them
modal.card_rects = {}

-- Count how many copies of card_id exist on a player's board
local function count_on_board(player, card_id)
  local n = 0
  for _, entry in ipairs(player.board) do
    if entry.card_id == card_id then n = n + 1 end
  end
  return n
end

-- Format a cost list into a short string like "2W 1S"
local function cost_label(costs)
  local parts = {}
  for _, c in ipairs(costs) do
    local letter = (c.type == "food") and "F" or (c.type == "wood") and "W" or (c.type == "stone") and "S" or (c.type == "metal") and "M" or "B"
    parts[#parts + 1] = tostring(c.amount) .. letter
  end
  return table.concat(parts, " ")
end

function modal.draw(player_index, game_state, hover, mouse_down)
  local player = game_state.players[player_index + 1]
  local faction = player.faction
  local structure_defs = cards.structures_for_faction(faction)
  local fdata = factions_data[faction] or factions_data.Neutral or {}
  local accent = fdata.color or { 0.55, 0.56, 0.83 }
  local is_active = (game_state.activePlayer == player_index)

  local gw, gh = love.graphics.getDimensions()
  -- Darker, more opaque backdrop
  love.graphics.setColor(0, 0, 0, 0.8)
  love.graphics.rectangle("fill", 0, 0, gw, gh)

  local box_w = math.min(700, gw - 80)
  local box_h = math.min(500, gh - 80)
  local box_x = (gw - box_w) / 2
  local box_y = (gh - box_h) / 2

  -- Modal shadow
  love.graphics.setColor(0, 0, 0, 0.5)
  love.graphics.rectangle("fill", box_x + 6, box_y + 8, box_w, box_h, 10, 10)

  -- Modal box
  love.graphics.setColor(0.11, 0.12, 0.15, 1.0)
  love.graphics.rectangle("fill", box_x, box_y, box_w, box_h, 8, 8)
  love.graphics.setColor(0.2, 0.22, 0.28, 1.0)
  love.graphics.rectangle("line", box_x, box_y, box_w, box_h, 8, 8)

  -- Title
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(util.get_font(16))
  local title_text = "Player " .. (player_index + 1) .. " — " .. faction .. " Blueprint Deck"
  love.graphics.print(title_text, box_x + PAD, box_y + PAD)

  -- Faction-colored underline below title
  local title_w = util.get_font(16):getWidth(title_text)
  love.graphics.setColor(accent[1], accent[2], accent[3], 0.8)
  love.graphics.rectangle("fill", box_x + PAD, box_y + PAD + 22, title_w, 2)

  -- Hint text
  if is_active then
    love.graphics.setColor(0.5, 0.7, 1.0, 0.8)
    love.graphics.setFont(util.get_font(11))
    love.graphics.print("Click a card to build it", box_x + PAD + title_w + 16, box_y + PAD + 4)
  end

  local cols = math.floor((box_w - 2 * PAD + GRID_PAD) / (CARD_W + GRID_PAD))
  local row = 0
  local col = 0
  local mx, my = love.mouse.getPosition()

  -- Reset card rects for this frame
  modal.card_rects = {}

  for _, def in ipairs(structure_defs) do
    local cx = box_x + PAD + col * (CARD_W + GRID_PAD)
    local cy = box_y + 48 + row * (CARD_H + GRID_PAD)

    -- Check affordability and population
    local can_afford = is_active and abilities.can_pay_cost(player.resources, def.costs)
    local built_count = count_on_board(player, def.id)
    local at_max = def.population and built_count >= def.population
    local can_build = can_afford and not at_max

    -- Store rect for hit testing
    modal.card_rects[#modal.card_rects + 1] = {
      id = def.id,
      x = cx, y = cy,
      w = CARD_W, h = CARD_H,
      can_build = can_build,
    }

    -- Draw the card
    card_frame.draw(cx, cy, {
      title = def.name,
      faction = def.faction,
      kind = def.kind,
      typeLine = def.faction .. " — " .. def.kind,
      text = def.text,
      costs = def.costs,
      population = def.population,
    })

    -- Overlay for unaffordable/maxed cards
    if not can_build then
      -- Dim overlay
      love.graphics.setColor(0, 0, 0, 0.55)
      love.graphics.rectangle("fill", cx, cy, CARD_W, CARD_H, 6, 6)
      -- Status label
      love.graphics.setFont(util.get_font(11))
      if at_max then
        love.graphics.setColor(1, 0.5, 0.3, 0.9)
        love.graphics.printf(built_count .. "/" .. def.population .. " built", cx, cy + CARD_H / 2 - 6, CARD_W, "center")
      elseif not is_active then
        love.graphics.setColor(0.6, 0.6, 0.7, 0.8)
        love.graphics.printf("Not your turn", cx, cy + CARD_H / 2 - 6, CARD_W, "center")
      else
        love.graphics.setColor(1, 0.4, 0.4, 0.9)
        love.graphics.printf("Can't afford", cx, cy + CARD_H / 2 - 6, CARD_W, "center")
      end
    else
      -- Green highlight border for affordable cards
      local card_hovered = util.point_in_rect(mx, my, cx, cy, CARD_W, CARD_H)
      if card_hovered then
        love.graphics.setColor(0.2, 0.8, 0.4, 0.5)
        love.graphics.setLineWidth(3)
        love.graphics.rectangle("line", cx - 2, cy - 2, CARD_W + 4, CARD_H + 4, 7, 7)
        love.graphics.setLineWidth(1)
      else
        love.graphics.setColor(0.2, 0.7, 0.35, 0.4)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", cx - 1, cy - 1, CARD_W + 2, CARD_H + 2, 7, 7)
        love.graphics.setLineWidth(1)
      end
    end

    -- Build count badge (bottom-right of card)
    if def.population and built_count > 0 then
      local badge_w, badge_h = 36, 16
      local bx = cx + CARD_W - badge_w - 4
      local by = cy + CARD_H - badge_h - 4
      love.graphics.setColor(0.08, 0.09, 0.12, 0.9)
      love.graphics.rectangle("fill", bx, by, badge_w, badge_h, 3, 3)
      love.graphics.setColor(0.7, 0.72, 0.8, 1)
      love.graphics.setFont(util.get_font(10))
      love.graphics.printf(built_count .. "/" .. def.population, bx, by + 2, badge_w, "center")
    end

    col = col + 1
    if col >= cols then col = 0; row = row + 1 end
  end

  -- Close button with hover highlight
  modal.close_button_rect = { box_x + box_w - 100, box_y + box_h - 44, 80, 28 }
  local cb = modal.close_button_rect
  local close_hovered = util.point_in_rect(mx, my, cb[1], cb[2], cb[3], cb[4])
  local close_pressed = close_hovered and mouse_down

  if close_pressed then
    love.graphics.setColor(0.15, 0.16, 0.20, 1.0)
  elseif close_hovered then
    love.graphics.setColor(0.28, 0.30, 0.38, 1.0)
  else
    love.graphics.setColor(0.2, 0.22, 0.28, 1.0)
  end
  love.graphics.rectangle("fill", cb[1], cb[2], cb[3], cb[4], 4, 4)
  love.graphics.setColor(0.35, 0.37, 0.45, 1.0)
  love.graphics.rectangle("line", cb[1], cb[2], cb[3], cb[4], 4, 4)
  love.graphics.setColor(0.85, 0.86, 0.9, 1.0)
  love.graphics.setFont(util.get_font(12))
  love.graphics.print("Close", cb[1] + 22, cb[2] + 6)
end

-- Hit test: returns card_id if mouse is over a buildable card, nil otherwise
function modal.hit_test_card(mx, my)
  for _, rect in ipairs(modal.card_rects) do
    if rect.can_build and util.point_in_rect(mx, my, rect.x, rect.y, rect.w, rect.h) then
      return rect.id
    end
  end
  return nil
end

function modal.hit_test_close(mx, my)
  if not modal.close_button_rect then return false end
  local cb = modal.close_button_rect
  return util.point_in_rect(mx, my, cb[1], cb[2], cb[3], cb[4])
end

-- Click outside box to close
function modal.hit_test_backdrop(mx, my)
  local gw, gh = love.graphics.getDimensions()
  local box_w = math.min(700, gw - 80)
  local box_h = math.min(500, gh - 80)
  local box_x = (gw - box_w) / 2
  local box_y = (gh - box_h) / 2
  return not util.point_in_rect(mx, my, box_x, box_y, box_w, box_h)
end

return modal
