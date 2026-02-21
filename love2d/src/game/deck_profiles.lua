-- Deck persistence helpers backed by settings.json.

local settings = require("src.settings")
local deck_validation = require("src.game.deck_validation")
local game_state = require("src.game.state")

local deck_profiles = {}

local function copy_array(values)
  local out = {}
  for i = 1, #values do
    out[i] = values[i]
  end
  return out
end

local function ensure_storage()
  if type(settings.values.decks) ~= "table" then
    settings.values.decks = {}
  end
  return settings.values.decks
end

local function first_supported_faction()
  local factions = game_state.supported_player_factions()
  if #factions > 0 then
    return factions[1]
  end
  return "Human"
end

local function is_supported_faction(faction)
  return game_state.is_supported_player_faction(faction)
end

function deck_profiles.ensure_defaults()
  local changed = false
  local decks = ensure_storage()

  local supported = game_state.supported_player_factions()
  for _, faction in ipairs(supported) do
    local current = decks[faction]
    local valid = current and deck_validation.validate_decklist(faction, current) or nil
    if not valid or not valid.ok then
      decks[faction] = deck_validation.default_deck_for_faction(faction)
      changed = true
    end
  end

  if not is_supported_faction(settings.values.faction) then
    settings.values.faction = first_supported_faction()
    changed = true
  end

  if changed then
    settings.save()
  end
end

function deck_profiles.get_deck(faction)
  if not is_supported_faction(faction) then
    return nil
  end

  local decks = ensure_storage()
  local stored = decks[faction]
  local validated = stored and deck_validation.validate_decklist(faction, stored) or nil
  if validated and validated.ok then
    return copy_array(validated.deck)
  end

  local default_deck = deck_validation.default_deck_for_faction(faction)
  decks[faction] = copy_array(default_deck)
  settings.save()
  return default_deck
end

function deck_profiles.set_deck(faction, deck_payload)
  if not is_supported_faction(faction) then
    return { ok = false, reason = "unsupported_faction", meta = { faction = faction } }
  end

  local validated = deck_validation.validate_decklist(faction, deck_payload)
  if not validated.ok then
    return validated
  end

  local decks = ensure_storage()
  decks[faction] = copy_array(validated.deck)
  settings.save()
  return { ok = true, reason = "ok", deck = copy_array(validated.deck), meta = validated.meta }
end

function deck_profiles.build_counts(faction, deck_payload)
  local entries = deck_validation.deck_entries_for_faction(faction)
  local counts = {}
  for _, entry in ipairs(entries) do
    counts[entry.card_id] = 0
  end

  local normalized = deck_payload and deck_validation.normalize_deck_payload(deck_payload) or nil
  local deck = normalized and normalized or {}
  for _, card_id in ipairs(deck) do
    if counts[card_id] ~= nil then
      counts[card_id] = counts[card_id] + 1
    end
  end

  return counts
end

function deck_profiles.build_deck_from_counts(faction, counts)
  local deck = {}
  local entries = deck_validation.deck_entries_for_faction(faction)
  for _, entry in ipairs(entries) do
    local requested = type(counts) == "table" and tonumber(counts[entry.card_id]) or 0
    local amount = math.floor(math.max(0, requested or 0))
    if entry.max_copies and amount > entry.max_copies then
      amount = entry.max_copies
    end
    for _ = 1, amount do
      deck[#deck + 1] = entry.card_id
    end
  end
  return deck
end

return deck_profiles
