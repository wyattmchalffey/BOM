-- Deck persistence helpers backed by settings.json.

local settings = require("src.settings")
local deck_validation = require("src.game.deck_validation")
local game_state = require("src.game.state")

local deck_profiles = {}

-- Fill these with your hand-tuned recommendations.
-- Supported formats per faction:
--   Human = { counts = { card_id = copies, ... } }
--   Orc = { cards = { "card_id_a", "card_id_a", "card_id_b", ... } }
-- You can also omit the wrapper and use a raw counts table or raw card-id array.
local RECOMMENDED_DECK_PRESETS = {
  Human = { counts = {
    ["HUMAN_WORKER_LOVING_FAMILY"] = 4,
    ["HUMAN_SPELL_ACID_BOMB"] = 3,
    ["HUMAN_STRUCTURE_GENERAL_WARES_SHOP"] = 1,
    ["HUMAN_STRUCTURE_STABLE"] = 1,
    ["HUMAN_TECHNOLOGY_MELEE_AGE_UP"] = 4,
    ["HUMAN_UNIT_HORSEMAN"] = 4,
    ["HUMAN_UNIT_PHILOSOPHER"] = 4,
    ["HUMAN_UNIT_QUARTER_MASTER"] = 6,
    ["HUMAN_UNIT_SOLDIER"] = 6,
    ["HUMAN_UNIT_YOUNG_ROOKIE"] = 4,
    ["NEUTRAL_STRUCTURE_DESERT_BAZAAR"] = 1,
    ["HUMAN_STRUCTURE_BANK"] = 1,
    ["HUMAN_STRUCTURE_INVENTORS_WORKSHOP"] = 1,
    ["HUMAN_STRUCTURE_ROYAL_THRONE"] = 1,
    ["HUMAN_UNIT_ALCHEMIST"] = 5,
    ["HUMAN_UNIT_CATAPULT"] = 3,
    ["HUMAN_UNIT_LANCER"] = 4,
    ["HUMAN_UNIT_PRINCE_OF_REASON"] = 3,
    ["HUMAN_UNIT_SHINOBI"] = 4,
    ["NEUTRAL_STRUCTURE_HOSPITAL"] = 0,
    ["HUMAN_STRUCTURE_TOME_OF_KNOWLEDGE"] = 1,
    ["HUMAN_UNIT_FLYING_MACHINE"] = 3,
    ["HUMAN_UNIT_KING_OF_MAN"] = 3,
    ["HUMAN_STRUCTURE_ALCHEMY_TABLE"] = 1,
    ["HUMAN_STRUCTURE_BARRACKS"] = 1,
    ["HUMAN_STRUCTURE_BLACKSMITH"] = 1,
    ["HUMAN_STRUCTURE_COMMAND_TOWER"] = 1,
    ["HUMAN_STRUCTURE_COTTAGE"] = 1,
    ["HUMAN_STRUCTURE_DOJO"] = 1,
    ["HUMAN_STRUCTURE_FARMLAND"] = 3,
    ["HUMAN_STRUCTURE_GRAIN_SILO"] = 1,
    ["HUMAN_STRUCTURE_LIBRARY"] = 1,
    ["HUMAN_STRUCTURE_MINT"] = 1,
    ["HUMAN_STRUCTURE_SALT_SMOKE_STACKS"] = 1,
    ["HUMAN_STRUCTURE_SMELTERY"] = 1,
    ["NEUTRAL_STRUCTURE_HONEYBEE_HIVE"] = 1,
  } },
  Orc = { counts = {
    ["ORC_UNIT_BRITTLE_SKELETON"] = 8,
    ["NEUTRAL_STRUCTURE_DESERT_BAZAAR"] = 0,
    ["ORC_STRUCTURE_MONUMENT_STAR_GOD"] = 1,
    ["ORC_UNIT_BLOOD_DIVINATOR"] = 6,
    ["ORC_UNIT_BONE_DADDY"] = 6,
    ["ORC_UNIT_BONE_MUNCHER"] = 5,
    ["ORC_UNIT_GARGOYLE"] = 5,
    ["NEUTRAL_STRUCTURE_HOSPITAL"] = 1,
    ["ORC_ARTIFACT_STONE_TALISMAN"] = 1,
    ["ORC_SPELL_BLOOD_BOIL"] = 2,
    ["ORC_SPELL_MORTAL_COIL"] = 3,
    ["ORC_SPELL_STONE_TOSS"] = 4,
    ["ORC_UNIT_BERSERKER"] = 4,
    ["ORC_UNIT_NECROMANCER"] = 5,
    ["ORC_UNIT_SKELIEUTENANT"] = 5,
    ["ORC_UNIT_STONE_GOLEM"] = 5,
    ["ORC_STRUCTURE_CARRION_PIT"] = 1,
    ["ORC_STRUCTURE_TEMPLE_OF_STARS"] = 1,
    ["ORC_UNIT_ANCIENT_GIANT"] = 3,
    ["NEUTRAL_STRUCTURE_HONEYBEE_HIVE"] = 0,
    ["ORC_STRUCTURE_BREEDING_PIT"] = 6,
    ["ORC_STRUCTURE_CRYPT"] = 1,
    ["ORC_STRUCTURE_FIGHTING_PITS"] = 1,
    ["ORC_STRUCTURE_HALL_OF_WARRIORS"] = 1,
    ["ORC_STRUCTURE_MAGIC_CAVE"] = 1,
    ["ORC_STRUCTURE_RAIDING_OUTPOST"] = 1,
    ["ORC_STRUCTURE_SACRIFICIAL_ALTAR"] = 1,
    ["ORC_STRUCTURE_TEMPLE"] = 1,
    ["ORC_STRUCTURE_TENT"] = 1,
  } },
}

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

local function preset_cards_array(preset)
  if type(preset) ~= "table" then
    return nil
  end
  if preset.cards ~= nil then
    return preset.cards
  end
  if #preset > 0 then
    return preset
  end
  return nil
end

local function preset_counts_table(preset)
  if type(preset) ~= "table" then
    return nil
  end
  if type(preset.counts) == "table" then
    return preset.counts
  end
  if preset.cards ~= nil then
    return nil
  end
  if #preset > 0 then
    return nil
  end
  return preset
end

function deck_profiles.has_recommended_deck(faction)
  return type(faction) == "string" and type(RECOMMENDED_DECK_PRESETS[faction]) == "table"
end

function deck_profiles.get_recommended_deck(faction)
  if not is_supported_faction(faction) then
    return { ok = false, reason = "unsupported_faction", meta = { faction = faction } }
  end

  local preset = RECOMMENDED_DECK_PRESETS[faction]
  if type(preset) ~= "table" then
    return { ok = false, reason = "no_recommended_preset", meta = { faction = faction } }
  end

  local deck_payload = preset_cards_array(preset)
  if not deck_payload then
    local counts = preset_counts_table(preset)
    if type(counts) ~= "table" then
      return { ok = false, reason = "invalid_recommended_preset", meta = { faction = faction } }
    end
    deck_payload = deck_profiles.build_deck_from_counts(faction, counts)
  end

  local validated = deck_validation.validate_decklist(faction, deck_payload)
  if not validated.ok then
    local meta = validated.meta or {}
    meta.faction = meta.faction or faction
    meta.recommended = true
    return { ok = false, reason = validated.reason, meta = meta }
  end

  local meta = validated.meta or {}
  meta.recommended = true
  return { ok = true, reason = "ok", deck = copy_array(validated.deck), meta = meta }
end

function deck_profiles.apply_recommended_deck(faction)
  local recommended = deck_profiles.get_recommended_deck(faction)
  if not recommended.ok then
    return recommended
  end
  return deck_profiles.set_deck(faction, recommended.deck)
end

return deck_profiles
