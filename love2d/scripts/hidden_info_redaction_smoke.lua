-- Smoke test for hidden-information redaction on multiplayer state payloads.
-- Run from repo root:
--   lua love2d/scripts/hidden_info_redaction_smoke.lua

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local host_mod = require("src.net.host")
local loopback_transport = require("src.net.loopback_transport")
local client_session = require("src.net.client_session")

local function assert_ok(result, label)
  if not result.ok then
    io.stderr:write(label .. " failed: " .. tostring(result.reason) .. "\n")
    os.exit(1)
  end
end

local function assert_true(cond, message)
  if not cond then
    io.stderr:write(message .. "\n")
    os.exit(1)
  end
end

local HIDDEN = "__HIDDEN_CARD__"

local host = host_mod.new({ match_id = "redaction-smoke" })
local transport = loopback_transport.new(host)

local client_a = client_session.new({ transport = transport, player_name = "Alice" })
local client_b = client_session.new({ transport = transport, player_name = "Bob" })

assert_ok(client_a:connect(), "client_a connect")
assert_ok(client_b:connect(), "client_b connect")

local snap_a = client_a:request_snapshot()
assert_ok(snap_a, "client_a snapshot")
local state_a = snap_a.meta and snap_a.meta.state
assert_true(type(state_a) == "table", "expected snapshot state")

local a_self_hand = state_a.players[1].hand or {}
local a_opp_hand = state_a.players[2].hand or {}
local a_opp_deck = state_a.players[2].deck or {}

assert_true(#a_self_hand > 0, "expected local hand cards to be visible")
assert_true(#a_opp_hand > 0, "expected opponent hand count to be present")
assert_true(#a_opp_deck > 0, "expected opponent deck count to be present")

for i, card_id in ipairs(a_opp_hand) do
  assert_true(card_id == HIDDEN, "opponent hand card " .. tostring(i) .. " was not redacted")
end
for i, card_id in ipairs(a_opp_deck) do
  assert_true(card_id == HIDDEN, "opponent deck card " .. tostring(i) .. " was not redacted")
end

local submit_a = client_a:submit({ type = "ASSIGN_WORKER", resource = "wood" })
assert_ok(submit_a, "client_a submit")

local submit_state_a = submit_a.meta and submit_a.meta.state
assert_true(type(submit_state_a) == "table", "expected submit ack state payload")
for i, card_id in ipairs(submit_state_a.players[2].hand or {}) do
  assert_true(card_id == HIDDEN, "submit ack leaked opponent hand at index " .. tostring(i))
end

print("Hidden info redaction smoke test passed")
