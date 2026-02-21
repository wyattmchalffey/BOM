-- Deck construction and legality checks.
--
-- This module defines the playable card pool for each faction, validates
-- submitted decklists, and provides default decks for first-time profiles.

local cards = require("src.game.cards")
local config = require("src.data.config")

local deck_validation = {}

local DECK_KINDS = {
  Unit = true,
  Spell = true,
  Technology = true,
  Item = true,
  Artifact = true,
}

local function is_main_deck_card(def, faction)
  if not def or def.faction ~= faction then
    return false
  end
  return DECK_KINDS[def.kind] or def.deckable == true
end

local function copy_array(values)
  local out = {}
  for i = 1, #values do
    out[i] = values[i]
  end
  return out
end

function deck_validation.deck_entries_for_faction(faction)
  local entries = {}
  for _, def in ipairs(cards.CARD_DEFS) do
    if is_main_deck_card(def, faction) then
      entries[#entries + 1] = {
        card_id = def.id,
        name = def.name,
        max_copies = def.population or 1,
        tier = def.tier,
        kind = def.kind,
      }
    end
  end
  table.sort(entries, function(a, b)
    if a.tier ~= b.tier then
      return (a.tier or 99) < (b.tier or 99)
    end
    return a.card_id < b.card_id
  end)
  return entries
end

function deck_validation.deck_entry_map(faction)
  local entries = deck_validation.deck_entries_for_faction(faction)
  local by_id = {}
  for _, entry in ipairs(entries) do
    by_id[entry.card_id] = entry
  end
  return entries, by_id
end

function deck_validation.default_deck_for_faction(faction)
  local deck = {}
  local entries = deck_validation.deck_entries_for_faction(faction)
  for _, entry in ipairs(entries) do
    for _ = 1, entry.max_copies do
      deck[#deck + 1] = entry.card_id
    end
  end
  return deck
end

function deck_validation.deck_size_bounds(faction)
  local entries = deck_validation.deck_entries_for_faction(faction)
  local max_size = 0
  for _, entry in ipairs(entries) do
    max_size = max_size + (entry.max_copies or 0)
  end

  local configured_min = tonumber(config.deck_min_cards) or 8
  local min_size = math.min(configured_min, max_size)
  if min_size < 0 then min_size = 0 end
  return min_size, max_size
end

function deck_validation.normalize_deck_payload(deck_payload)
  if type(deck_payload) ~= "table" then
    return nil, "invalid_deck_payload"
  end

  local cards_list = deck_payload
  if deck_payload.cards ~= nil then
    if type(deck_payload.cards) ~= "table" then
      return nil, "invalid_deck_payload"
    end
    cards_list = deck_payload.cards
  end

  local out = {}
  local n = #cards_list
  if n <= 0 then
    return nil, "empty_deck"
  end

  for i = 1, n do
    local card_id = cards_list[i]
    if type(card_id) ~= "string" or card_id == "" then
      return nil, "invalid_deck_card_id"
    end
    out[i] = card_id
  end

  -- Reject sparse/hash-style payloads.
  for k, _ in pairs(cards_list) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 or k > n then
      return nil, "invalid_deck_payload"
    end
  end

  return out, nil
end

function deck_validation.validate_decklist(faction, deck_payload)
  if type(faction) ~= "string" or faction == "" then
    return { ok = false, reason = "invalid_faction", meta = {} }
  end

  local entries, by_id = deck_validation.deck_entry_map(faction)
  if #entries == 0 then
    return { ok = false, reason = "unsupported_faction", meta = { faction = faction } }
  end

  local deck, normalize_reason = deck_validation.normalize_deck_payload(deck_payload)
  if not deck then
    return { ok = false, reason = normalize_reason, meta = { faction = faction } }
  end

  local min_size, max_size = deck_validation.deck_size_bounds(faction)
  local deck_size = #deck
  if deck_size < min_size then
    return {
      ok = false,
      reason = "deck_too_small",
      meta = { faction = faction, deck_size = deck_size, min_size = min_size, max_size = max_size },
    }
  end
  if deck_size > max_size then
    return {
      ok = false,
      reason = "deck_too_large",
      meta = { faction = faction, deck_size = deck_size, min_size = min_size, max_size = max_size },
    }
  end

  local counts = {}
  for _, card_id in ipairs(deck) do
    local entry = by_id[card_id]
    if not entry then
      return {
        ok = false,
        reason = "deck_card_not_allowed",
        meta = { faction = faction, card_id = card_id },
      }
    end

    counts[card_id] = (counts[card_id] or 0) + 1
    if counts[card_id] > entry.max_copies then
      return {
        ok = false,
        reason = "deck_card_limit_exceeded",
        meta = { faction = faction, card_id = card_id, max_copies = entry.max_copies },
      }
    end
  end

  return {
    ok = true,
    reason = "ok",
    deck = copy_array(deck),
    meta = { faction = faction, deck_size = deck_size, min_size = min_size, max_size = max_size },
  }
end

return deck_validation
