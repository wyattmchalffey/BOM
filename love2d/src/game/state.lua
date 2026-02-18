-- Game state representation.
-- Uses data/factions.lua and data/config.lua for defaults.
-- create_initial_game_state() accepts an optional setup table so players
-- can eventually customize decks, starting resources, etc.

local cards = require("src.game.cards")
local factions = require("src.data.factions")
local config = require("src.data.config")

local state = {}

-- Kinds that go into the player's main (draw) deck
local DECK_KINDS = { Unit = true, Spell = true, Technology = true, Item = true, Artifact = true }

function state.empty_resources()
  local r = {}
  for _, key in ipairs(config.resource_types) do
    r[key] = 0
  end
  return r
end

-- Fisher-Yates shuffle (in-place)
local function shuffle(t)
  for i = #t, 2, -1 do
    local j = math.random(1, i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

-- Build a draw deck for a faction: collect all matching cards, each appearing `population` times
function state.build_deck(faction)
  local deck = {}
  for _, def in ipairs(cards.CARD_DEFS) do
    if def.faction == faction and (DECK_KINDS[def.kind] or def.deckable) then
      local copies = def.population or 1
      for _ = 1, copies do
        deck[#deck + 1] = def.id
      end
    end
  end
  shuffle(deck)
  return deck
end

-- Draw N cards from a player's deck into their hand
function state.draw_cards(player, count)
  count = count or 1
  local drawn = 0
  for _ = 1, count do
    if #player.deck == 0 then break end
    local card_id = table.remove(player.deck)
    player.hand[#player.hand + 1] = card_id
    drawn = drawn + 1
  end
  return drawn
end

-- Create a player state.
-- opts (optional): { faction, base_id, starting_workers, max_workers, starting_resources }
-- Anything not provided falls back to faction defaults, then global defaults.
function state.create_player_state(index, opts)
  opts = opts or {}
  local faction = opts.faction or config.default_factions[index + 1] or "Human"
  local fdata = factions[faction] or {}

  local base_id = opts.base_id or fdata.default_base_id
  local base_def = cards.get_card_def(base_id)
  local max_workers = opts.max_workers or fdata.default_max_workers or 8
  local starting_workers = opts.starting_workers or fdata.default_starting_workers or 2

  -- Starting resources: merge defaults with any overrides
  local resources = state.empty_resources()
  local src = opts.starting_resources or config.default_starting_resources
  for k, v in pairs(src) do
    resources[k] = v
  end

  -- Build the draw deck and draw a starting hand
  local deck = state.build_deck(faction)
  local p = {
    faction = faction,
    baseId = base_id,
    life = base_def.baseHealth or 30,
    resources = resources,
    totalWorkers = starting_workers,
    maxWorkers = max_workers,
    workersOn = { food = 0, wood = 0, stone = 0 },
    deck = deck,
    hand = {},
    board = {},
    graveyard = {},
    resourceNodes = {},
    specialWorkers = {},
  }
  -- Draw starting hand of 5 cards
  state.draw_cards(p, 5)
  return p
end

-- Create the full game state.
-- setup (optional): { first_player = 0, players = { [1] = { faction = "Human", ... }, [2] = { ... } } }
function state.create_initial_game_state(setup)
  setup = setup or {}
  local first_player = setup.first_player or config.default_first_player

  local player_setups = setup.players or {}
  return {
    players = {
      state.create_player_state(0, player_setups[1]),
      state.create_player_state(1, player_setups[2]),
    },
    activePlayer = first_player,
    turnNumber = 1,
    phase = "MAIN",
    priorityPlayer = first_player,
    pendingAction = nil,
    activatedUsedThisTurn = {},
  }
end

return state
