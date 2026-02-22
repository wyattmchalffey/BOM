-- Blueprint deck modal: thin adapter over deck_viewer.
-- Builds a config for the generic viewer with blueprint-specific overlays and actions.

local deck_viewer = require("src.ui.deck_viewer")
local cards = require("src.game.cards")
local abilities = require("src.game.abilities")
local factions_data = require("src.data.factions")
local util = require("src.ui.util")

local blueprint = {}

-- Count how many copies of card_id exist on a player's board
local function count_on_board(player, card_id)
  local n = 0
  for _, entry in ipairs(player.board) do
    if entry.card_id == card_id then n = n + 1 end
  end
  return n
end

local function count_in_blueprint_deck(player, card_id)
  local n = 0
  local deck = player and player.blueprintDeck
  if type(deck) ~= "table" then return 0 end
  for i = 1, #deck do
    if deck[i] == card_id then
      n = n + 1
    end
  end
  return n
end

local function blueprint_cards_for_player(player, faction)
  local counts = {}
  local order = {}
  local deck = player and player.blueprintDeck
  if type(deck) ~= "table" then
    return {}
  end

  for i = 1, #deck do
    local card_id = deck[i]
    if not counts[card_id] then
      counts[card_id] = 0
      order[#order + 1] = card_id
    end
    counts[card_id] = counts[card_id] + 1
  end

  local out = {}
  for _, card_id in ipairs(order) do
    local ok, def = pcall(cards.get_card_def, card_id)
    if ok and def and (def.faction == faction or def.faction == "Neutral") and def.kind == "Structure" then
      out[#out + 1] = def
    end
  end

  table.sort(out, function(a, b)
    local at = a.tier or 99
    local bt = b.tier or 99
    if at ~= bt then return at < bt end
    return a.id < b.id
  end)

  return out
end

-- Open the blueprint viewer for a specific player
function blueprint.open(player_index, game_state)
  local player = game_state.players[player_index + 1]
  local faction = player.faction
  local fdata = factions_data[faction] or {}
  local accent = fdata.color or { 0.55, 0.56, 0.83 }
  local is_active = (game_state.activePlayer == player_index)

  deck_viewer.open({
    title = "Player " .. (player_index + 1) .. " - " .. faction .. " Blueprint Deck",
    hint = is_active and "Click a card to build it" or nil,
    cards = blueprint_cards_for_player(player, faction),
    accent = accent,
    filters = { "All", "Affordable" },

    filter_fn = function(def, filter_name)
      if filter_name == "Affordable" then
        local remaining = count_in_blueprint_deck(player, def.id)
        local can_afford = is_active and abilities.can_pay_cost(player.resources, def.costs)
        local built = count_on_board(player, def.id)
        local at_max = def.population and built >= def.population
        return remaining > 0 and can_afford and not at_max
      end
      return true
    end,

    can_click_fn = function(def)
      if not is_active then return false end
      local remaining = count_in_blueprint_deck(player, def.id)
      local can_afford = abilities.can_pay_cost(player.resources, def.costs)
      local built = count_on_board(player, def.id)
      local at_max = def.population and built >= def.population
      return remaining > 0 and can_afford and not at_max
    end,

    card_overlay_fn = function(def, x, y, w, h)
      local remaining = count_in_blueprint_deck(player, def.id)
      local can_afford = is_active and abilities.can_pay_cost(player.resources, def.costs)
      local built = count_on_board(player, def.id)
      local at_max = def.population and built >= def.population
      local can_build = remaining > 0 and can_afford and not at_max

      if not can_build then
        -- Dim overlay
        love.graphics.setColor(0, 0, 0, 0.55)
        love.graphics.rectangle("fill", x, y, w, h, 6, 6)
        -- Status label
        love.graphics.setFont(util.get_font(11))
        if at_max then
          love.graphics.setColor(1, 0.5, 0.3, 0.9)
          love.graphics.printf(built .. "/" .. def.population .. " built", x, y + h / 2 - 6, w, "center")
        elseif remaining <= 0 then
          love.graphics.setColor(0.95, 0.4, 0.4, 0.9)
          love.graphics.printf("No copies left", x, y + h / 2 - 6, w, "center")
        elseif not is_active then
          love.graphics.setColor(0.6, 0.6, 0.7, 0.8)
          love.graphics.printf("Not your turn", x, y + h / 2 - 6, w, "center")
        else
          love.graphics.setColor(1, 0.4, 0.4, 0.9)
          love.graphics.printf("Can't afford", x, y + h / 2 - 6, w, "center")
        end
      end

      -- Remaining copies badge (bottom-right)
      if remaining > 0 then
        local bw, bh = 36, 16
        local bx = x + w - bw - 4
        local by = y + h - bh - 4
        love.graphics.setColor(0.08, 0.09, 0.12, 0.9)
        love.graphics.rectangle("fill", bx, by, bw, bh, 3, 3)
        love.graphics.setColor(0.7, 0.72, 0.8, 1)
        love.graphics.setFont(util.get_font(10))
        love.graphics.printf("x" .. tostring(remaining), bx, by + 2, bw, "center")
      end
    end,

    -- on_click is handled by game.lua (it needs access to game actions)
    on_click = nil,
  })
end

return blueprint
