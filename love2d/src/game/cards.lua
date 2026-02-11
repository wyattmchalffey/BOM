-- Card registry: loads data/cards.lua and builds fast lookup tables.

local card_data = require("src.data.cards")

local cards = {}

-- Build ID → def lookup once at load time
local _by_id = {}
for _, def in ipairs(card_data) do
  _by_id[def.id] = def
end

-- All card definitions (list, for iteration)
cards.CARD_DEFS = card_data

function cards.get_card_def(id)
  local def = _by_id[id]
  if not def then error("Unknown card id: " .. tostring(id)) end
  return def
end

-- List all card defs matching a filter (kind, faction, or both)
function cards.filter(opts)
  local out = {}
  for _, def in ipairs(card_data) do
    local match = true
    if opts.kind and def.kind ~= opts.kind then match = false end
    if opts.faction and def.faction ~= opts.faction then match = false end
    if match then out[#out + 1] = def end
  end
  return out
end

-- Shorthand: structures for a faction (used by blueprint modal)
function cards.structures_for_faction(faction)
  return cards.filter({ kind = "Structure", faction = faction })
end

-- Get the first activated ability on a card (convenience for base/structure activation)
function cards.get_activated_ability(card_def)
  if not card_def.abilities then return nil end
  for _, ab in ipairs(card_def.abilities) do
    if ab.type == "activated" then return ab end
  end
  return nil
end

return cards
