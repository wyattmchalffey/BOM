-- Deck construction and legality checks.
--
-- This module defines the playable card pool for each faction, validates
-- submitted decklists, and provides default decks for first-time profiles.

local cards = require("src.game.cards")

local deck_validation = {}

local function is_pool_card(def, faction)
  if not def or (def.faction ~= faction and def.faction ~= "Neutral") then
    return false
  end
  -- Bases are selected separately; all other faction cards are deckbuilder-eligible.
  if def.kind == "Base" then
    return false
  end
  -- Resource nodes are chosen as starting resources (color identity), not deck cards.
  if def.kind == "ResourceNode" then
    return false
  end
  -- Token workers (e.g., Peasant/Grunt) are not deckbuilder cards.
  if def.kind == "Worker" and def.deckable ~= true then
    return false
  end
  return true
end

local function max_copies_for_card(def)
  -- Unit, Structure, deckable Worker, and Spell population constrain copies.
  if def.kind == "Unit" or def.kind == "Structure" or def.kind == "Worker" or def.kind == "Artifact" or def.kind == "Spell" then
    return def.population or 1
  end
  return nil
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
    if is_pool_card(def, faction) then
      entries[#entries + 1] = {
        card_id = def.id,
        name = def.name,
        max_copies = max_copies_for_card(def),
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
    local copies = entry.max_copies or 1
    for _ = 1, copies do
      deck[#deck + 1] = entry.card_id
    end
  end
  return deck
end

function deck_validation.deck_size_bounds(faction)
  local _ = faction
  return 0, nil
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

  local deck_size = #deck

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
    if entry.max_copies and counts[card_id] > entry.max_copies then
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
    meta = { faction = faction, deck_size = deck_size, min_size = 0, max_size = nil },
  }
end

return deck_validation
