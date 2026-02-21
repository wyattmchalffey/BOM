-- Smoke test for server-side deck legality + using submitted decks at match start.
-- Run from repo root:
--   lua love2d/scripts/deck_legality_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local protocol = require("src.net.protocol")
local host_mod = require("src.net.host")
local config = require("src.data.config")
local deck_validation = require("src.game.deck_validation")

local function fail(msg)
  io.stderr:write(msg .. "\n")
  os.exit(1)
end

local function assert_ok(result, label)
  if not result.ok then
    fail(label .. " failed: " .. tostring(result.reason))
  end
end

local function make_join_payload(name, faction, deck)
  return protocol.handshake({
    rules_version = config.rules_version,
    content_version = config.content_version,
    player_name = name,
    faction = faction,
    deck = deck,
  })
end

local human_deck = {
  "HUMAN_UNIT_SOLDIER",
  "HUMAN_UNIT_SOLDIER",
  "HUMAN_UNIT_SOLDIER",
  "HUMAN_UNIT_SOLDIER",
  "HUMAN_UNIT_SOLDIER",
  "HUMAN_UNIT_SOLDIER",
  "HUMAN_UNIT_SOLDIER",
  "HUMAN_UNIT_SOLDIER",
}
local orc_deck = deck_validation.default_deck_for_faction("Orc")

local host = host_mod.new({
  match_id = "deck-smoke",
  host_player = {
    name = "Alice",
    faction = "Human",
    deck = human_deck,
  },
})

local bad_card = host:join(make_join_payload("bad-card", "Human", {
  "ORC_UNIT_BONE_MUNCHER",
  "ORC_UNIT_BONE_MUNCHER",
  "ORC_UNIT_BONE_MUNCHER",
  "ORC_UNIT_BONE_MUNCHER",
  "ORC_UNIT_BONE_MUNCHER",
  "ORC_UNIT_BONE_MUNCHER",
  "ORC_UNIT_BONE_MUNCHER",
  "ORC_UNIT_BONE_MUNCHER",
}))
if bad_card.ok or bad_card.reason ~= "deck_card_not_allowed" then
  fail("expected deck_card_not_allowed for cross-faction deck")
end

local too_many = host:join(make_join_payload("too-many", "Human", {
  "HUMAN_UNIT_SOLDIER",
  "HUMAN_UNIT_SOLDIER",
  "HUMAN_UNIT_SOLDIER",
  "HUMAN_UNIT_SOLDIER",
  "HUMAN_UNIT_SOLDIER",
  "HUMAN_UNIT_SOLDIER",
  "HUMAN_UNIT_SOLDIER",
  "HUMAN_UNIT_SOLDIER",
  "HUMAN_UNIT_SOLDIER",
}))
if too_many.ok or too_many.reason ~= "deck_card_limit_exceeded" then
  fail("expected deck_card_limit_exceeded for too many copies")
end

local too_small = host:join(make_join_payload("too-small", "Human", {
  "HUMAN_UNIT_SOLDIER",
}))
if too_small.ok or too_small.reason ~= "deck_too_small" then
  fail("expected deck_too_small for undersized deck")
end

local join = host:join(make_join_payload("Bob", "Orc", orc_deck))
assert_ok(join, "join")
if join.meta and join.meta.player_index ~= 1 then
  fail("invalid join attempts should not reserve the joiner slot")
end

local snapshot = host:get_state_snapshot()
if not snapshot or not snapshot.players or not snapshot.players[1] or not snapshot.players[2] then
  fail("missing game snapshot players")
end

local p1 = snapshot.players[1]
if p1.faction ~= "Human" then
  fail("expected player 1 faction Human")
end
if (#p1.hand + #p1.deck) ~= 8 then
  fail("expected human custom deck size 8 total")
end
for _, card_id in ipairs(p1.hand) do
  if card_id ~= "HUMAN_UNIT_SOLDIER" then
    fail("player 1 hand should only contain HUMAN_UNIT_SOLDIER")
  end
end
for _, card_id in ipairs(p1.deck) do
  if card_id ~= "HUMAN_UNIT_SOLDIER" then
    fail("player 1 deck should only contain HUMAN_UNIT_SOLDIER")
  end
end

local p2 = snapshot.players[2]
if p2.faction ~= "Orc" then
  fail("expected player 2 faction Orc")
end
if (#p2.hand + #p2.deck) ~= 8 then
  fail("expected orc custom deck size 8 total")
end
for _, card_id in ipairs(p2.hand) do
  if card_id ~= "ORC_UNIT_BONE_MUNCHER" then
    fail("player 2 hand should only contain ORC_UNIT_BONE_MUNCHER")
  end
end
for _, card_id in ipairs(p2.deck) do
  if card_id ~= "ORC_UNIT_BONE_MUNCHER" then
    fail("player 2 deck should only contain ORC_UNIT_BONE_MUNCHER")
  end
end

print("Deck legality smoke test passed")
