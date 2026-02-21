-- Game state representation.
-- Uses data/factions.lua and data/config.lua for defaults.
-- create_initial_game_state() accepts an optional setup table so players
-- can eventually customize decks, starting resources, etc.

local cards = require("src.game.cards")
local deck_validation = require("src.game.deck_validation")
local factions = require("src.data.factions")
local config = require("src.data.config")

local state = {}

-- Kinds that go into the player's main (draw) deck
local DECK_KINDS = { Unit = true, Spell = true, Technology = true, Item = true, Artifact = true }

local function has_valid_base(base_id)
  if type(base_id) ~= "string" or base_id == "" then
    return false
  end

  local ok_base, base_def = pcall(cards.get_card_def, base_id)
  return ok_base and type(base_def) == "table" and base_def.kind == "Base"
end

local function fallback_faction_for_index(index)
  local configured = config.default_factions[index + 1]
  if state.is_supported_player_faction and state.is_supported_player_faction(configured) then
    return configured
  end

  local supported = state.supported_player_factions and state.supported_player_factions() or {}
  if #supported > 0 then
    return supported[1]
  end
  return "Human"
end

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

local function is_main_deck_card(def)
  return (def and def.faction and (DECK_KINDS[def.kind] or def.deckable)) and true or false
end

local function is_blueprint_card(def)
  return def and def.kind == "Structure"
end

-- Build a draw deck for a faction.
-- If explicit_deck is provided (including empty), only main-deck cards from it are used.
function state.build_deck(faction, explicit_deck)
  local deck = {}
  if type(explicit_deck) == "table" then
    for i = 1, #explicit_deck do
      local card_id = explicit_deck[i]
      local ok, def = pcall(cards.get_card_def, card_id)
      if ok and def and def.faction == faction and is_main_deck_card(def) then
        deck[#deck + 1] = card_id
      end
    end
  else
    for _, def in ipairs(cards.CARD_DEFS) do
      if def.faction == faction and is_main_deck_card(def) then
        local copies = def.population or 1
        for _ = 1, copies do
          deck[#deck + 1] = def.id
        end
      end
    end
  end
  shuffle(deck)
  return deck
end

-- Build a blueprint deck for a faction.
-- If explicit_deck is provided (including empty), only structures from it are used.
function state.build_blueprint_deck(faction, explicit_deck)
  local deck = {}
  if type(explicit_deck) == "table" then
    for i = 1, #explicit_deck do
      local card_id = explicit_deck[i]
      local ok, def = pcall(cards.get_card_def, card_id)
      if ok and def and def.faction == faction and is_blueprint_card(def) then
        deck[#deck + 1] = card_id
      end
    end
    return deck
  end

  for _, def in ipairs(cards.CARD_DEFS) do
    if def.faction == faction and is_blueprint_card(def) then
      local copies = def.population or 1
      for _ = 1, copies do
        deck[#deck + 1] = def.id
      end
    end
  end
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

function state.is_supported_player_faction(faction)
  if type(faction) ~= "string" or faction == "" then
    return false
  end

  local fdata = factions[faction]
  if type(fdata) ~= "table" then
    return false
  end

  return has_valid_base(fdata.default_base_id)
end

function state.supported_player_factions()
  local out = {}
  for faction, _ in pairs(factions) do
    if state.is_supported_player_faction(faction) then
      out[#out + 1] = faction
    end
  end
  table.sort(out)
  return out
end

function state.supported_player_faction_set()
  local out = {}
  for _, faction in ipairs(state.supported_player_factions()) do
    out[faction] = true
  end
  return out
end

-- Create a player state.
-- opts (optional): { faction, base_id, starting_workers, max_workers, starting_resources }
-- Anything not provided falls back to faction defaults, then global defaults.
function state.create_player_state(index, opts)
  opts = opts or {}
  local faction = opts.faction
  if not state.is_supported_player_faction(faction) then
    faction = fallback_faction_for_index(index)
  end
  local fdata = factions[faction] or {}

  local base_id = opts.base_id or fdata.default_base_id
  if not has_valid_base(base_id) then
    base_id = fdata.default_base_id
  end
  if not has_valid_base(base_id) then
    faction = fallback_faction_for_index(index)
    fdata = factions[faction] or {}
    base_id = fdata.default_base_id
  end

  local base_def = cards.get_card_def(base_id)
  local max_workers = opts.max_workers or fdata.default_max_workers or 8
  local starting_workers = opts.starting_workers or fdata.default_starting_workers or 2

  -- Starting resources: merge defaults with any overrides
  local resources = state.empty_resources()
  local src = opts.starting_resources or config.default_starting_resources
  for k, v in pairs(src) do
    resources[k] = v
  end

  local explicit_deck = nil
  if opts.deck ~= nil then
    local validated = deck_validation.validate_decklist(faction, opts.deck)
    if validated.ok then
      explicit_deck = validated.deck
    end
  end

  -- Build the draw + blueprint decks and draw a starting hand
  local deck = state.build_deck(faction, explicit_deck)
  local blueprint_deck = state.build_blueprint_deck(faction, explicit_deck)
  local p = {
    faction = faction,
    baseId = base_id,
    life = base_def.baseHealth or 30,
    resources = resources,
    totalWorkers = starting_workers,
    maxWorkers = max_workers,
    workersOn = { food = 0, wood = 0, stone = 0 },
    deck = deck,
    blueprintDeck = blueprint_deck,
    hand = {},
    board = {},
    graveyard = {},
    resourceNodes = {},
    specialWorkers = {},
    workerStatePool = {},
  }
  -- Draw starting hand of 5 cards
  state.draw_cards(p, 5)
  return p
end

function state.compute_terminal_result(g)
  if not g or type(g.players) ~= "table" then
    return nil
  end

  local p1 = g.players[1]
  local p2 = g.players[2]
  if type(p1) ~= "table" or type(p2) ~= "table" then
    return nil
  end

  local p1_dead = (p1.life or 0) <= 0
  local p2_dead = (p2.life or 0) <= 0
  if not p1_dead and not p2_dead then
    return nil
  end

  local winner = nil
  local reason = "base_destroyed"
  if p1_dead and not p2_dead then
    winner = 1
  elseif p2_dead and not p1_dead then
    winner = 0
  else
    reason = "double_base_destroyed"
  end

  return {
    winner = winner,
    reason = reason,
    ended_at_turn = g.turnNumber or 0,
  }
end

function state.set_terminal(g, terminal)
  if not g or not terminal then
    return g
  end

  g.is_terminal = true
  g.winner = terminal.winner
  g.reason = terminal.reason
  g.ended_at_turn = terminal.ended_at_turn or g.turnNumber or 0
  return g
end

-- Create the full game state.
-- setup (optional): { first_player = 0, players = { [1] = { faction = "Human", ... }, [2] = { ... } } }
function state.create_initial_game_state(setup)
  setup = setup or {}
  local first_player = setup.first_player or config.default_first_player

  local player_setups = setup.players or {}
  local g = {
    players = {
      state.create_player_state(0, player_setups[1]),
      state.create_player_state(1, player_setups[2]),
    },
    activePlayer = first_player,
    turnNumber = 1,
    phase = "MAIN",
    priorityPlayer = first_player,
    pendingAction = nil,
    pendingCombat = nil,
    activatedUsedThisTurn = {},
    is_terminal = false,
    winner = nil,
    reason = nil,
    ended_at_turn = nil,
  }

  local terminal = state.compute_terminal_result(g)
  if terminal then
    state.set_terminal(g, terminal)
  end

  return g
end

return state
