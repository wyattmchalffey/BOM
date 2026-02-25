local cards = require("src.game.cards")
local abilities = require("src.game.abilities")

local events = {}

local handlers_by_type = {}

local function new_emit_result(event)
  local result = abilities.new_resolve_result(nil, nil)
  result.event_type = type(event) == "table" and event.type or nil
  return result
end

local function has_subtype(card_def, needle)
  if not card_def or type(card_def.subtypes) ~= "table" then return false end
  for _, st in ipairs(card_def.subtypes) do
    if st == needle then return true end
  end
  return false
end

local function is_undead(card_def)
  return has_subtype(card_def, "Undead")
end

local function first_unrest_target_index(player, effect_args)
  for si, entry in ipairs((player and player.board) or {}) do
    local ok, def = pcall(cards.get_card_def, entry.card_id)
    if ok and def and (def.kind == "Unit" or def.kind == "Worker") then
      local matches = true
      local args = effect_args or {}
      if type(args.subtypes) == "table" and #args.subtypes > 0 then
        matches = false
        for _, req in ipairs(args.subtypes) do
          if has_subtype(def, req) then
            matches = true
            break
          end
        end
      end
      if matches then return si end
    end
  end
  return nil
end

function events.on(event_type, handler)
  if type(event_type) ~= "string" or event_type == "" then
    error("events.on requires non-empty event_type")
  end
  if type(handler) ~= "function" then
    error("events.on requires handler function")
  end
  local list = handlers_by_type[event_type]
  if not list then
    list = {}
    handlers_by_type[event_type] = list
  end
  list[#list + 1] = handler
  return handler
end

function events.emit(game_state, event)
  local aggregate = new_emit_result(event)
  if type(event) ~= "table" or type(event.type) ~= "string" then
    return false, "invalid_event", aggregate
  end
  local handlers = handlers_by_type[event.type]
  if type(handlers) ~= "table" or #handlers == 0 then
    return false, "unhandled_event_type", aggregate
  end
  for _, handler in ipairs(handlers) do
    local ret = handler(game_state, event)
    if type(ret) == "table" then
      abilities.merge_resolve_result(aggregate, ret)
    end
  end
  return true, nil, aggregate
end

events.on("card_played", function(game_state, ev)
  local player = ev.player
  if type(player) ~= "table" then return end

  local card_def = ev.card_def
  if not card_def and type(ev.card_id) == "string" then
    local ok, def = pcall(cards.get_card_def, ev.card_id)
    if ok then card_def = def end
  end
  if not card_def then return end

  local triggers = ev.triggers or { "on_play", "on_construct" }
  return abilities.dispatch_card_triggers(card_def, player, game_state, triggers, ev.context)
end)

events.on("ally_died", function(game_state, ev)
  local player = ev.player
  local dead_card_def = ev.dead_card_def
  if type(player) ~= "table" or type(player.board) ~= "table" then return end
  if type(dead_card_def) ~= "table" then return end

  return abilities.dispatch_board_trigger_event(player, game_state, {
    trigger = "on_ally_death",
    player_index = ev.player_index,
    should_resolve = function(entry, card_def, ab, si, ai)
      local args = ab.effect_args or {}
      if args.condition == "non_undead" and is_undead(dead_card_def) then
        return false
      end
      if args.condition == "non_undead_orc" then
        if is_undead(dead_card_def) or dead_card_def.faction ~= "Orc" then
          return false
        end
      end
      return true
    end,
  })
end)

events.on("card_destroyed", function(game_state, ev)
  local player = ev.player
  if type(player) ~= "table" then return end

  local card_def = ev.card_def
  if not card_def and type(ev.card_id) == "string" then
    local ok, def = pcall(cards.get_card_def, ev.card_id)
    if ok then card_def = def end
  end
  if not card_def then return end

  local aggregate = abilities.dispatch_card_triggers(card_def, player, game_state, "on_destroyed", ev.context)
  if ev.emit_ally_death ~= false then
    local _, _, nested = events.emit(game_state, {
      type = "ally_died",
      player = player,
      player_index = ev.player_index,
      dead_card_def = card_def,
    })
    if type(nested) == "table" then
      abilities.merge_resolve_result(aggregate, nested)
    end
  end
  return aggregate
end)

events.on("base_damaged", function(game_state, ev)
  local damage = tonumber(ev.damage) or 0
  local owner_player = ev.owner_player
  local opponent_player = ev.opponent_player
  if damage <= 0 or type(owner_player) ~= "table" or type(opponent_player) ~= "table" then return end

  return abilities.dispatch_board_trigger_event(owner_player, game_state, {
    trigger = "on_base_damage",
    player_index = ev.owner_player_index,
    build_context = function(entry, card_def, ab, si, ai)
      return {
        source_entry = entry,
        source_board_index = si,
        opponent_player = opponent_player,
        damage_to_base = damage,
      }
    end,
  })
end)

events.on("mass_attack_post_combat", function(game_state, ev)
  local c = ev.combat_state
  local atk_player = ev.attacker_player
  local def_player = ev.defender_player
  if type(c) ~= "table" or type(atk_player) ~= "table" or type(def_player) ~= "table" then return end

  return abilities.dispatch_board_trigger_event(atk_player, game_state, {
    trigger = "on_mass_attack",
    player_index = c.attacker,
    should_resolve = function(entry, card_def, ab, si, ai)
      local args = ab.effect_args or {}
      local min_attackers = tonumber(args.min_attackers) or 0
      return #((c and c.attackers) or {}) >= min_attackers
    end,
    resolve = function(ab, entry, card_def, si, ai, context)
      local args = ab.effect_args or {}
      if ab.effect == "unrest_target" then
        local target_index = first_unrest_target_index(def_player, args)
        if not target_index then return false end
        return abilities.resolve(ab, atk_player, game_state, {
          source_entry = entry,
          source_board_index = si,
          target_entry = def_player.board[target_index],
          target_board_index = target_index,
          combat_state = c,
          opponent_player = def_player,
        })
      end

      return abilities.resolve(ab, atk_player, game_state, {
        source_entry = entry,
        source_board_index = si,
        combat_state = c,
        opponent_player = def_player,
      })
    end,
  })
end)

return events
