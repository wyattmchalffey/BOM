local cards = require("src.game.cards")
local abilities = require("src.game.abilities")

local combat = {}

local function has_keyword(card_def, needle)
  if not card_def or not card_def.keywords then return false end
  local want = string.lower(needle)
  for _, kw in ipairs(card_def.keywords) do
    if string.lower(kw) == want then return true end
  end
  return false
end

local function has_subtype(card_def, needle)
  if not card_def or not card_def.subtypes then return false end
  for _, st in ipairs(card_def.subtypes) do
    if st == needle then return true end
  end
  return false
end

local function has_static_effect(card_def, effect_name)
  if not card_def or not card_def.abilities then return false end
  for _, ab in ipairs(card_def.abilities) do
    if ab.type == "static" and ab.effect == effect_name then return true end
  end
  return false
end

local function can_attack_multiple_times(card_def)
  return has_static_effect(card_def, "can_attack_multiple_times")
    or has_static_effect(card_def, "can_attack_twice")
end

local function ensure_state(entry)
  entry.state = entry.state or {}
  if entry.state.rested == nil then entry.state.rested = false end
  return entry.state
end

local function copy_table(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do
    out[k] = copy_table(v)
  end
  return out
end

local function is_undead(card_def)
  return has_subtype(card_def, "Undead")
end

local function fire_on_ally_death_triggers(player, g, dead_card_def)
  for _, entry in ipairs(player.board) do
    local ok, card_def = pcall(cards.get_card_def, entry.card_id)
    if ok and card_def and card_def.abilities then
      for _, ab in ipairs(card_def.abilities) do
        if ab.type == "triggered" and ab.trigger == "on_ally_death" then
          local args = ab.effect_args or {}
          local blocked = args.condition == "non_undead" and is_undead(dead_card_def)
          if not blocked then
            abilities.resolve(ab, player, g)
          end
        end
      end
    end
  end
end

local function destroy_board_entry(player, g, board_index)
  local target = player.board[board_index]
  if not target then return false end

  if target.workers and target.workers > 0 then
    target.workers = 0
  end
  for _, sw in ipairs(player.specialWorkers or {}) do
    if sw.assigned_to == board_index then
      sw.assigned_to = nil
    elseif type(sw.assigned_to) == "table" and sw.assigned_to.type == "field" and sw.assigned_to.board_index == board_index then
      sw.assigned_to = nil
    end
  end

  if target.special_worker_index and player.specialWorkers and player.specialWorkers[target.special_worker_index] then
    local ref = player.specialWorkers[target.special_worker_index]
    ref.state = copy_table(target.state or ref.state or {})
    ref.assigned_to = nil
  end

  local t_ok, t_def = pcall(cards.get_card_def, target.card_id)
  if t_ok and t_def and t_def.abilities then
    for _, ab in ipairs(t_def.abilities) do
      if ab.type == "triggered" and ab.trigger == "on_destroyed" then
        abilities.resolve(ab, player, g)
      end
    end
  end
  if t_ok and t_def then
    fire_on_ally_death_triggers(player, g, t_def)
  end

  player.graveyard[#player.graveyard + 1] = { card_id = target.card_id, state = copy_table(target.state or {}) }
  table.remove(player.board, board_index)

  for _, sw in ipairs(player.specialWorkers or {}) do
    if type(sw.assigned_to) == "number" and sw.assigned_to > board_index then
      sw.assigned_to = sw.assigned_to - 1
    elseif type(sw.assigned_to) == "table" and sw.assigned_to.type == "field" and sw.assigned_to.board_index and sw.assigned_to.board_index > board_index then
      sw.assigned_to.board_index = sw.assigned_to.board_index - 1
    end
  end

  return true
end

local function can_target_unit(attacker_def, target_entry)
  local tstate = ensure_state(target_entry)
  if tstate.rested then return true end
  return has_static_effect(attacker_def, "can_attack_non_rested")
end

local function get_attacker(combat_state, attacker_board_index)
  for _, a in ipairs(combat_state.attackers or {}) do
    if a.board_index == attacker_board_index then return a end
  end
  return nil
end

local function unstack_attack_group(combat_state, stack_id)
  if not stack_id then return end
  for _, a in ipairs(combat_state.attackers or {}) do
    if a.attack_stack_id == stack_id then
      a.attack_stack_id = nil
    end
  end
end

local function get_blockers_for_attacker(combat_state, attacker_board_index)
  local out = {}
  for _, b in ipairs(combat_state.blockers or {}) do
    if b.attacker_board_index == attacker_board_index then
      out[#out + 1] = b.blocker_board_index
    end
  end
  return out
end

local function get_attackers_with_multiple_blockers(combat_state)
  local counts = {}
  for _, b in ipairs(combat_state.blockers or {}) do
    counts[b.attacker_board_index] = (counts[b.attacker_board_index] or 0) + 1
  end
  local out = {}
  for attacker_index, count in pairs(counts) do
    if count > 1 then out[#out + 1] = attacker_index end
  end
  return out
end

local function queue_damage(q, side, board_index, amount, source_def)
  if amount <= 0 then return end
  q[#q + 1] = {
    side = side,
    board_index = board_index,
    amount = amount,
    deathtouch = has_keyword(source_def, "deathtouch"),
  }
end

local function apply_damage_queue(g, atk_player, def_player, q)
  for _, ev in ipairs(q) do
    local player = (ev.side == "atk") and atk_player or def_player
    local entry = player.board[ev.board_index]
    if entry then
      local st = ensure_state(entry)
      st.damage = (st.damage or 0) + ev.amount
      if ev.deathtouch then st.marked_for_death = true end
    end
  end
end

local function build_first_strike_flags(player)
  local flags = {}
  for i, entry in ipairs(player.board) do
    local ok, def = pcall(cards.get_card_def, entry.card_id)
    flags[i] = ok and def and has_keyword(def, "first_strike") or false
  end
  return flags
end

local function has_other_attacking_unit_with_subtype(combat_state, atk_player, source_board_index, subtype)
  if type(subtype) ~= "string" or subtype == "" then
    return true
  end
  for _, other in ipairs(combat_state.attackers or {}) do
    if other.board_index ~= source_board_index and not other.invalidated then
      local other_entry = atk_player.board[other.board_index]
      if other_entry then
        local ok_other, other_def = pcall(cards.get_card_def, other_entry.card_id)
        if ok_other and other_def and other_def.kind == "Unit" and has_subtype(other_def, subtype) then
          local other_state = ensure_state(other_entry)
          if not (has_keyword(other_def, "crew") and not other_state.crewed) then
            return true
          end
        end
      end
    end
  end
  return false
end

local function attack_trigger_condition_met(combat_state, atk_player, source_board_index, effect_args)
  local args = effect_args or {}
  local need_subtype = args.requires_another_attacker_subtype
  if not need_subtype and args.condition == "allied_mounted_attacking" then
    need_subtype = "Mounted"
  end
  return has_other_attacking_unit_with_subtype(combat_state, atk_player, source_board_index, need_subtype)
end

local function is_manual_on_attack_target_ability(ab)
  if not ab or ab.type ~= "triggered" or ab.trigger ~= "on_attack" then return false end
  local args = ab.effect_args or {}
  local amount = args.damage or args.amount or 0
  if amount <= 0 then return false end
  if ab.effect == "deal_damage_to_target_unit" then
    return true
  end
  if ab.effect == "conditional_damage" then
    return args.target == "unit" or args.target == "unit_row"
  end
  return false
end

local function build_attack_trigger_queue(pending, atk_player)
  local out = {}
  for _, attacker in ipairs(pending.attackers or {}) do
    local entry = atk_player.board[attacker.board_index]
    if entry then
      local ok_def, def = pcall(cards.get_card_def, entry.card_id)
      if ok_def and def and def.abilities then
        for ai, ab in ipairs(def.abilities) do
          if is_manual_on_attack_target_ability(ab) then
            local effect_args = copy_table(ab.effect_args or {})
            if attack_trigger_condition_met(pending, atk_player, attacker.board_index, effect_args) then
              out[#out + 1] = {
                attacker_board_index = attacker.board_index,
                ability_index = ai,
                effect = ab.effect,
                effect_args = effect_args,
                source_card_id = entry.card_id,
                target_board_index = nil,
                resolved = false,
                applied = false,
              }
            end
          end
        end
      end
    end
  end
  return out
end

local function collect_attack_trigger_unit_targets(def_player)
  local out = {}
  for i, entry in ipairs(def_player.board or {}) do
    local ok_def, def = pcall(cards.get_card_def, entry.card_id)
    -- Unit row only: units/workers on the battlefield front row.
    if ok_def and def and def.kind ~= "Structure" then
      out[#out + 1] = i
    end
  end
  return out
end

local function is_valid_attack_trigger_target(def_player, board_index)
  if type(board_index) ~= "number" then return false end
  local entry = def_player.board and def_player.board[board_index]
  if not entry then return false end
  local ok_def, def = pcall(cards.get_card_def, entry.card_id)
  return ok_def and def and def.kind ~= "Structure"
end

local function attacker_target_key(attacker_board_index, ability_index)
  return tostring(attacker_board_index) .. ":" .. tostring(ability_index)
end

local function condition_met_for_attack_trigger(combat_state, atk_player, trigger)
  return attack_trigger_condition_met(combat_state, atk_player, trigger.attacker_board_index, trigger.effect_args)
end

local function shift_defender_indices_after_destroy(combat_state, removed_index)
  for _, attacker in ipairs(combat_state.attackers or {}) do
    if attacker.target and attacker.target.type == "board" and type(attacker.target.index) == "number" then
      if attacker.target.index == removed_index then
        attacker.target.index = -1
      elseif attacker.target.index > removed_index then
        attacker.target.index = attacker.target.index - 1
      end
    end
  end

  for _, trigger in ipairs(combat_state.attack_triggers or {}) do
    local idx = trigger.target_board_index
    if type(idx) == "number" and idx > 0 then
      if idx == removed_index then
        trigger.target_board_index = -1
      elseif idx > removed_index then
        trigger.target_board_index = idx - 1
      end
    end
  end

  for i = #(combat_state.blockers or {}), 1, -1 do
    local blk = combat_state.blockers[i]
    if blk.blocker_board_index == removed_index then
      table.remove(combat_state.blockers, i)
    elseif blk.blocker_board_index > removed_index then
      blk.blocker_board_index = blk.blocker_board_index - 1
    end
  end
end

function combat.declare_attackers(g, player_index, declarations)
  if g.phase ~= "MAIN" then return false, "wrong_phase" end
  if player_index ~= g.activePlayer then return false, "not_active_player" end
  if g.pendingCombat then return false, "combat_already_pending" end
  if type(declarations) ~= "table" or #declarations == 0 then return false, "invalid_declarations" end

  local defender_index = (player_index == 0) and 1 or 0
  local atk_player = g.players[player_index + 1]
  local def_player = g.players[defender_index + 1]

  local pending = {
    attacker = player_index,
    defender = defender_index,
    attackers = {},
    blockers = {},
    stage = "DECLARED",
    attack_triggers = {},
  }

  local seen = {}
  for _, decl in ipairs(declarations) do
    local bi = decl.attacker_board_index
    if type(bi) ~= "number" or seen[bi] then return false, "invalid_attacker" end
    seen[bi] = true

    local entry = atk_player.board[bi]
    if not entry then return false, "missing_attacker" end

    local card_def = cards.get_card_def(entry.card_id)
    if not card_def or (card_def.kind ~= "Unit" and card_def.kind ~= "Worker") then
      return false, "attacker_not_unit"
    end
    if (card_def.attack or 0) <= 0 then
      return false, "attacker_has_no_attack"
    end

    local estate = ensure_state(entry)
    if estate.rested then return false, "attacker_rested" end
    if estate.attacked_turn == g.turnNumber and not can_attack_multiple_times(card_def) then
      return false, "attacker_already_attacked"
    end
    if has_keyword(card_def, "crew") and not estate.crewed then
      return false, "attacker_not_crewed"
    end
    local has_immediate_attack = has_keyword(card_def, "rush") or has_keyword(card_def, "haste")
    if estate.summoned_turn == g.turnNumber and not has_immediate_attack then
      return false, "summoning_sickness"
    end

    local target = decl.target
    if type(target) ~= "table" or (target.type ~= "base" and target.type ~= "board") then
      return false, "invalid_target"
    end

    if target.type == "board" then
      local target_entry = def_player.board[target.index]
      if not target_entry then return false, "missing_target" end
      local tdef = cards.get_card_def(target_entry.card_id)
      if not tdef then return false, "missing_target" end
      if tdef.kind ~= "Unit" and tdef.kind ~= "Worker" and tdef.kind ~= "Structure" then
        return false, "invalid_target_kind"
      end
      if tdef.kind == "Structure" and tdef.health == nil then
        return false, "invalid_target_kind"
      end
      if (tdef.kind == "Unit" or tdef.kind == "Worker") and not can_target_unit(card_def, target_entry) then
        return false, "target_unit_not_rested"
      end
    end

    local stack_id = estate.stack_id
    estate.stack_id = nil
    if not has_keyword(card_def, "vigilance") then
      estate.rested = true
    end
    estate.attacked_turn = g.turnNumber

    pending.attackers[#pending.attackers + 1] = {
      board_index = bi,
      target = { type = target.type, index = target.index },
      attack_stack_id = stack_id,
      invalidated = false,
    }
  end

  pending.attack_triggers = build_attack_trigger_queue(pending, atk_player)
  if #pending.attack_triggers > 0 then
    pending.stage = "AWAITING_ATTACK_TARGETS"
  end

  g.pendingCombat = pending
  return true, "ok"
end

function combat.assign_attack_trigger_targets(g, player_index, targets)
  local c = g.pendingCombat
  if not c or c.stage ~= "AWAITING_ATTACK_TARGETS" then return false, "no_pending_attack_targets" end
  if player_index ~= c.attacker then return false, "not_attacker" end
  if type(targets) ~= "table" then return false, "invalid_attack_trigger_targets" end

  local atk_player = g.players[c.attacker + 1]
  local def_player = g.players[c.defender + 1]
  if not atk_player or not def_player then return false, "invalid_combat_state" end

  local selected = {}
  for _, item in ipairs(targets) do
    if type(item) ~= "table" then
      return false, "invalid_attack_trigger_targets"
    end
    local attacker_board_index = item.attacker_board_index
    local ability_index = item.ability_index
    local target_board_index = item.target_board_index
    if type(attacker_board_index) ~= "number"
      or type(ability_index) ~= "number"
      or type(target_board_index) ~= "number" then
      return false, "invalid_attack_trigger_targets"
    end
    selected[attacker_target_key(attacker_board_index, ability_index)] = target_board_index
  end

  for _, trigger in ipairs(c.attack_triggers or {}) do
    if not trigger.resolved then
      local src_entry = atk_player.board[trigger.attacker_board_index]
      if not src_entry or not condition_met_for_attack_trigger(c, atk_player, trigger) then
        trigger.resolved = true
        trigger.target_board_index = nil
      else
        local legal_targets = collect_attack_trigger_unit_targets(def_player)
        if #legal_targets == 0 then
          trigger.resolved = true
          trigger.target_board_index = nil
        else
          local key = attacker_target_key(trigger.attacker_board_index, trigger.ability_index)
          local chosen = selected[key]
          if type(chosen) ~= "number" then
            return false, "missing_attack_trigger_target"
          end
          if not is_valid_attack_trigger_target(def_player, chosen) then
            return false, "invalid_attack_trigger_target"
          end
          trigger.target_board_index = chosen
          trigger.resolved = true
        end
      end
    end
  end

  -- Resolve trigger effects immediately, before blockers are declared.
  for _, trigger in ipairs(c.attack_triggers or {}) do
    if trigger.resolved and not trigger.applied then
      local args = trigger.effect_args or {}
      local amount = args.damage or args.amount or 0
      if amount > 0 and trigger.target_board_index and trigger.target_board_index > 0 then
        local src_entry = atk_player.board[trigger.attacker_board_index]
        local src_ok, src_def = false, nil
        if src_entry then
          src_ok, src_def = pcall(cards.get_card_def, src_entry.card_id)
        end
        if src_ok and src_def and condition_met_for_attack_trigger(c, atk_player, trigger) then
          local target_entry = def_player.board[trigger.target_board_index]
          if target_entry then
            local st = ensure_state(target_entry)
            st.damage = (st.damage or 0) + amount
          end
        end
      end
      trigger.applied = true
    end
  end

  local dead_def = {}
  for i, entry in ipairs(def_player.board) do
    local def = cards.get_card_def(entry.card_id)
    local st = ensure_state(entry)
    local lethal_by_damage = (def.health ~= nil) and ((def.health or 0) - (st.damage or 0) <= 0)
    if st.marked_for_death or lethal_by_damage then
      dead_def[#dead_def + 1] = i
    end
  end
  for i = #dead_def, 1, -1 do
    local removed_index = dead_def[i]
    destroy_board_entry(def_player, g, removed_index)
    shift_defender_indices_after_destroy(c, removed_index)
  end

  c.stage = "DECLARED"
  return true, "ok"
end

function combat.assign_blockers(g, player_index, assignments)
  local c = g.pendingCombat
  if not c or c.stage ~= "DECLARED" then return false, "no_pending_combat" end
  if player_index ~= c.defender then return false, "not_defender" end
  if type(assignments) ~= "table" then return false, "invalid_assignments" end

  local def_player = g.players[c.defender + 1]
  local atk_player = g.players[c.attacker + 1]
  local seen_blockers = {}

  for _, asn in ipairs(assignments) do
    local blocker_index = asn.blocker_board_index
    local attacker_index = asn.attacker_board_index
    if type(blocker_index) ~= "number" or type(attacker_index) ~= "number" then
      return false, "invalid_assignment"
    end
    if seen_blockers[blocker_index] then return false, "blocker_already_assigned" end
    seen_blockers[blocker_index] = true

    local blocker_entry = def_player.board[blocker_index]
    if not blocker_entry then return false, "missing_blocker" end
    local blocker_def = cards.get_card_def(blocker_entry.card_id)
    if not blocker_def or (blocker_def.kind ~= "Unit" and blocker_def.kind ~= "Worker") then
      return false, "invalid_blocker_kind"
    end

    local bstate = ensure_state(blocker_entry)
    if bstate.rested then return false, "blocker_rested" end

    local attacker = get_attacker(c, attacker_index)
    if not attacker then return false, "missing_attacker" end
    local attacker_entry = atk_player.board[attacker.board_index]
    if not attacker_entry then
      attacker.invalidated = true
    else
      local attacker_def = cards.get_card_def(attacker_entry.card_id)
      if has_keyword(attacker_def, "flying") and not has_keyword(blocker_def, "flying") then
        return false, "blocker_cannot_block_flying"
      end
    end

    bstate.stack_id = nil
    bstate.rested = true

    unstack_attack_group(c, attacker.attack_stack_id)

    c.blockers[#c.blockers + 1] = {
      blocker_board_index = blocker_index,
      attacker_board_index = attacker.board_index,
    }
  end

  local need_orders = get_attackers_with_multiple_blockers(c)
  if #need_orders > 0 then
    c.stage = "AWAITING_DAMAGE_ORDER"
    c.damage_orders = c.damage_orders or {}
    c.attackers_needing_order = need_orders
  else
    c.stage = "BLOCKERS_ASSIGNED"
  end
  return true, "ok"
end

function combat.assign_damage_order(g, player_index, orders)
  local c = g.pendingCombat
  if not c or c.stage ~= "AWAITING_DAMAGE_ORDER" then return false, "no_pending_combat" end
  if player_index ~= c.attacker then return false, "not_attacker" end
  if type(orders) ~= "table" then return false, "invalid_orders" end

  c.damage_orders = c.damage_orders or {}
  for _, order in ipairs(orders) do
    local attacker_index = order.attacker_board_index
    local blocker_indices = order.blocker_board_indices
    if type(attacker_index) ~= "number" or type(blocker_indices) ~= "table" then
      return false, "invalid_order"
    end

    local legal_blockers = get_blockers_for_attacker(c, attacker_index)
    if #legal_blockers < 2 then return false, "attacker_does_not_need_order" end

    local needed = {}
    for _, bi in ipairs(legal_blockers) do needed[bi] = true end
    local seen = {}

    for _, bi in ipairs(blocker_indices) do
      if not needed[bi] or seen[bi] then return false, "invalid_blocker_order_member" end
      seen[bi] = true
    end
    for bi, _ in pairs(needed) do
      if not seen[bi] then return false, "incomplete_blocker_order" end
    end

    c.damage_orders[attacker_index] = blocker_indices
  end

  for _, attacker_index in ipairs(c.attackers_needing_order or {}) do
    if not c.damage_orders[attacker_index] then
      return false, "missing_damage_order"
    end
  end

  c.stage = "BLOCKERS_ASSIGNED"
  return true, "ok"
end

function combat.resolve(g)
  local c = g.pendingCombat
  if not c then return false, "no_pending_combat" end
  if c.stage ~= "DECLARED" and c.stage ~= "BLOCKERS_ASSIGNED" then
    return false, "invalid_combat_stage"
  end

  local atk_player = g.players[c.attacker + 1]
  local def_player = g.players[c.defender + 1]
  local atk_first = build_first_strike_flags(atk_player)
  local def_first = build_first_strike_flags(def_player)

  local first_q, normal_q = {}, {}
  local base_damage_first = 0
  local base_damage_normal = 0

  for _, attacker in ipairs(c.attackers) do
    if not attacker.invalidated then
      local atk_entry = atk_player.board[attacker.board_index]
      if atk_entry then
        local atk_def = cards.get_card_def(atk_entry.card_id)
        local atk_state = ensure_state(atk_entry)
        if has_keyword(atk_def, "crew") and not atk_state.crewed then
          attacker.invalidated = true
        else
          local blockers = get_blockers_for_attacker(c, attacker.board_index)
          if c.damage_orders and c.damage_orders[attacker.board_index] then
            blockers = c.damage_orders[attacker.board_index]
          end
          local queue_for_attacker = atk_first[attacker.board_index] and first_q or normal_q

          if #blockers > 0 then
            local remaining_atk = atk_def.attack or 0
            for _, bi in ipairs(blockers) do
              local b_entry = def_player.board[bi]
              if b_entry then
                local b_def = cards.get_card_def(b_entry.card_id)
                local b_queue = def_first[bi] and first_q or normal_q
                local b_state = ensure_state(b_entry)
                if has_keyword(b_def, "crew") and not b_state.crewed then
                  -- crewless blocker deals no combat damage
                else
                  queue_damage(b_queue, "atk", attacker.board_index, b_def.attack or 0, b_def)
                end
                local bhp = b_def.health or 0
                if has_keyword(atk_def, "deathtouch") then bhp = 1 end
                local to_blocker = math.min(remaining_atk, bhp)
                queue_damage(queue_for_attacker, "def", bi, to_blocker, atk_def)
                remaining_atk = remaining_atk - to_blocker
              end
            end

            if remaining_atk > 0 and has_keyword(atk_def, "trample") then
              if attacker.target.type == "base" then
                if atk_first[attacker.board_index] then
                  base_damage_first = base_damage_first + remaining_atk
                else
                  base_damage_normal = base_damage_normal + remaining_atk
                end
              elseif attacker.target.type == "board" and def_player.board[attacker.target.index] then
                queue_damage(queue_for_attacker, "def", attacker.target.index, remaining_atk, atk_def)
              end
            end
          else
            if attacker.target.type == "base" then
              if atk_first[attacker.board_index] then
                base_damage_first = base_damage_first + (atk_def.attack or 0)
              else
                base_damage_normal = base_damage_normal + (atk_def.attack or 0)
              end
            elseif attacker.target.type == "board" then
              local te = def_player.board[attacker.target.index]
              if te then
                local tdef = cards.get_card_def(te.card_id)
                queue_damage(queue_for_attacker, "def", attacker.target.index, atk_def.attack or 0, atk_def)
                if tdef.kind == "Unit" or tdef.kind == "Worker" then
                  local tstate = ensure_state(te)
                  if not (has_keyword(tdef, "crew") and not tstate.crewed) then
                    local t_queue = def_first[attacker.target.index] and first_q or normal_q
                    queue_damage(t_queue, "atk", attacker.board_index, tdef.attack or 0, tdef)
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  apply_damage_queue(g, atk_player, def_player, first_q)
  def_player.life = math.max(0, (def_player.life or 0) - base_damage_first)

  local dead_atk, dead_def = {}, {}
  for i, e in ipairs(atk_player.board) do
    local d = cards.get_card_def(e.card_id)
    local st = ensure_state(e)
    local lethal_by_damage = (d.health ~= nil) and ((d.health or 0) - (st.damage or 0) <= 0)
    if st.marked_for_death or lethal_by_damage then
      dead_atk[#dead_atk + 1] = i
    end
  end
  for i, e in ipairs(def_player.board) do
    local d = cards.get_card_def(e.card_id)
    local st = ensure_state(e)
    local lethal_by_damage = (d.health ~= nil) and ((d.health or 0) - (st.damage or 0) <= 0)
    if st.marked_for_death or lethal_by_damage then
      dead_def[#dead_def + 1] = i
    end
  end
  for i = #dead_atk, 1, -1 do destroy_board_entry(atk_player, g, dead_atk[i]) end
  for i = #dead_def, 1, -1 do destroy_board_entry(def_player, g, dead_def[i]) end

  apply_damage_queue(g, atk_player, def_player, normal_q)
  def_player.life = math.max(0, (def_player.life or 0) - base_damage_normal)

  dead_atk, dead_def = {}, {}
  for i, e in ipairs(atk_player.board) do
    local d = cards.get_card_def(e.card_id)
    local st = ensure_state(e)
    local lethal_by_damage = (d.health ~= nil) and ((d.health or 0) - (st.damage or 0) <= 0)
    if st.marked_for_death or lethal_by_damage then
      dead_atk[#dead_atk + 1] = i
    end
  end
  for i, e in ipairs(def_player.board) do
    local d = cards.get_card_def(e.card_id)
    local st = ensure_state(e)
    local lethal_by_damage = (d.health ~= nil) and ((d.health or 0) - (st.damage or 0) <= 0)
    if st.marked_for_death or lethal_by_damage then
      dead_def[#dead_def + 1] = i
    end
  end
  for i = #dead_atk, 1, -1 do destroy_board_entry(atk_player, g, dead_atk[i]) end
  for i = #dead_def, 1, -1 do destroy_board_entry(def_player, g, dead_def[i]) end

  for _, p in ipairs({ atk_player, def_player }) do
    for _, e in ipairs(p.board) do
      local st = ensure_state(e)
      st.damage = nil
      st.marked_for_death = nil
    end
  end

  g.pendingCombat = nil
  return true, "ok"
end

return combat
