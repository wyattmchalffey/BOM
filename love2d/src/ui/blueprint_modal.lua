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
    cards = cards.structures_for_faction(faction),
    accent = accent,
    filters = { "All", "Affordable" },

    filter_fn = function(def, filter_name)
      if filter_name == "Affordable" then
        local can_afford = is_active and abilities.can_pay_cost(player.resources, def.costs)
        local built = count_on_board(player, def.id)
        local at_max = def.population and built >= def.population
        return can_afford and not at_max
      end
      return true
    end,

    can_click_fn = function(def)
      if not is_active then return false end
      local can_afford = abilities.can_pay_cost(player.resources, def.costs)
      local built = count_on_board(player, def.id)
      local at_max = def.population and built >= def.population
      return can_afford and not at_max
    end,

    card_overlay_fn = function(def, x, y, w, h)
      local can_afford = is_active and abilities.can_pay_cost(player.resources, def.costs)
      local built = count_on_board(player, def.id)
      local at_max = def.population and built >= def.population
      local can_build = can_afford and not at_max

      if not can_build then
        -- Dim overlay
        love.graphics.setColor(0, 0, 0, 0.55)
        love.graphics.rectangle("fill", x, y, w, h, 6, 6)
        -- Status label
        love.graphics.setFont(util.get_font(11))
        if at_max then
          love.graphics.setColor(1, 0.5, 0.3, 0.9)
          love.graphics.printf(built .. "/" .. def.population .. " built", x, y + h / 2 - 6, w, "center")
        elseif not is_active then
          love.graphics.setColor(0.6, 0.6, 0.7, 0.8)
          love.graphics.printf("Not your turn", x, y + h / 2 - 6, w, "center")
        else
          love.graphics.setColor(1, 0.4, 0.4, 0.9)
          love.graphics.printf("Can't afford", x, y + h / 2 - 6, w, "center")
        end
      end

      -- Build count badge (bottom-right)
      if def.population and built > 0 then
        local bw, bh = 36, 16
        local bx = x + w - bw - 4
        local by = y + h - bh - 4
        love.graphics.setColor(0.08, 0.09, 0.12, 0.9)
        love.graphics.rectangle("fill", bx, by, bw, bh, 3, 3)
        love.graphics.setColor(0.7, 0.72, 0.8, 1)
        love.graphics.setFont(util.get_font(10))
        love.graphics.printf(built .. "/" .. def.population, bx, by + 2, bw, "center")
      end
    end,

    -- on_click is handled by game.lua (it needs access to game actions)
    on_click = nil,
  })
end

return blueprint
