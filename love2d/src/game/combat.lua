local cards = require("src.game.cards")

local combat = {}

local function has_keyword(card_def, needle)
  if not card_def or not card_def.keywords then return false end
  local want = string.lower(needle)
  for _, kw in ipairs(card_def.keywords) do
    if string.lower(kw) == want then return true end
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

local function ensure_state(entry)
  entry.state = entry.state or {}
  return entry.state
end

local function get_attacker(g, combat_state, attacker_board_index)
  for _, a in ipairs(combat_state.attackers or {}) do
    if a.board_index == attacker_board_index then return a end
  end
  return nil
end

local function can_target_unit(attacker_def, target_entry, target_def)
  local tstate = ensure_state(target_entry)
  if tstate.rested then return true end
  return has_static_effect(attacker_def, "can_attack_non_rested")
end

function combat.declare_attackers(g, player_index, declarations)
  if g.phase ~= "MAIN" then return false, "wrong_phase" end
  if player_index ~= g.activePlayer then return false, "not_active_player" end
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
  }

  local seen = {}
  for _, decl in ipairs(declarations) do
    local bi = decl.attacker_board_index
    if type(bi) ~= "number" or seen[bi] then return false, "invalid_attacker" end
    seen[bi] = true
    local entry = atk_player.board[bi]
    if not entry then return false, "missing_attacker" end
    local card_def = cards.get_card_def(entry.card_id)
    if not card_def or (card_def.kind ~= "Unit" and card_def.kind ~= "Worker") then return false, "attacker_not_unit" end

    local estate = ensure_state(entry)
    if estate.rested then return false, "attacker_rested" end

    local target = decl.target
    if type(target) ~= "table" or (target.type ~= "base" and target.type ~= "board") then
      return false, "invalid_target"
    end

    if target.type == "board" then
      local te = def_player.board[target.index]
      if not te then return false, "missing_target" end
      local tdef = cards.get_card_def(te.card_id)
      if not tdef then return false, "missing_target" end
      if tdef.kind ~= "Unit" and tdef.kind ~= "Worker" and tdef.kind ~= "Structure" then
        return false, "invalid_target_kind"
      end
      if (tdef.kind == "Unit" or tdef.kind == "Worker") and not can_target_unit(card_def, te, tdef) then
        return false, "target_unit_not_rested"
      end
    end

    -- Move out of board stacks when declared.
    local stack_id = estate.stack_id
    estate.stack_id = nil

    if not has_keyword(card_def, "vigilance") then
      estate.rested = true
    end

    pending.attackers[#pending.attackers + 1] = {
      board_index = bi,
      target = { type = target.type, index = target.index },
      attack_stack_id = stack_id,
      invalidated = false,
    }
  end

  g.pendingCombat = pending
  return true, "ok"
end

function combat.assign_blockers(g, player_index, assignments)
  local c = g.pendingCombat
  if not c or c.stage ~= "DECLARED" then return false, "no_pending_combat" end
  if player_index ~= c.defender then return false, "not_defender" end
  if type(assignments) ~= "table" then return false, "invalid_assignments" end

  local def_player = g.players[c.defender + 1]
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

    local attacker = get_attacker(g, c, attacker_index)
    if not attacker then return false, "missing_attacker" end

    local atk_player = g.players[c.attacker + 1]
    local attacker_entry = atk_player.board[attacker.board_index]
    if not attacker_entry then
      attacker.invalidated = true
    else
      local attacker_def = cards.get_card_def(attacker_entry.card_id)
      if has_keyword(attacker_def, "flying") and not has_keyword(blocker_def, "flying") then
        return false, "blocker_cannot_block_flying"
      end
    end

    -- Blockers from stacks also unstack.
    bstate.stack_id = nil
    bstate.rested = true

    -- If blocker is assigned to one attacker from declaration stack, pull it out of visual stack.
    attacker.attack_stack_id = nil

    c.blockers[#c.blockers + 1] = {
      blocker_board_index = blocker_index,
      attacker_board_index = attacker.board_index,
    }
  end

  c.stage = "BLOCKERS_ASSIGNED"
  return true, "ok"
end

local function get_blockers_for_attacker(c, attacker_board_index)
  local out = {}
  for _, b in ipairs(c.blockers or {}) do
    if b.attacker_board_index == attacker_board_index then
      out[#out + 1] = b.blocker_board_index
    end
  end
  return out
end

local function schedule_damage(damage_events, side, board_index, amount, source_has_deathtouch)
  if amount <= 0 then return end
  damage_events[#damage_events + 1] = {
    side = side,
    board_index = board_index,
    amount = amount,
    deathtouch = source_has_deathtouch,
  }
end

local function apply_board_damage(player, board_index, amount)
  local entry = player.board[board_index]
  if not entry then return end
  local state = ensure_state(entry)
  state.damage = (state.damage or 0) + amount
end

function combat.resolve(g)
  local c = g.pendingCombat
  if not c then return false, "no_pending_combat" end
  if c.stage ~= "DECLARED" and c.stage ~= "BLOCKERS_ASSIGNED" then return false, "invalid_combat_stage" end

  local atk_player = g.players[c.attacker + 1]
  local def_player = g.players[c.defender + 1]

  local damage_queue = {}
  local base_damage = 0

  for _, attacker in ipairs(c.attackers) do
    if not attacker.invalidated then
      local atk_entry = atk_player.board[attacker.board_index]
      if atk_entry then
        local atk_def = cards.get_card_def(atk_entry.card_id)
        local atk_state = ensure_state(atk_entry)
        local atk_hp = (atk_def.health or 0) - (atk_state.damage or 0)
        if atk_hp > 0 then
          local blockers = get_blockers_for_attacker(c, attacker.board_index)
          if #blockers > 0 then
            local remaining_atk = atk_def.attack or 0
            for _, bi in ipairs(blockers) do
              local b_entry = def_player.board[bi]
              if b_entry then
                local b_def = cards.get_card_def(b_entry.card_id)
                local b_state = ensure_state(b_entry)
                local b_hp = (b_def.health or 0) - (b_state.damage or 0)
                if b_hp > 0 then
                  local to_blocker = math.min(remaining_atk, b_hp)
                  schedule_damage(damage_queue, "def", bi, to_blocker, has_keyword(atk_def, "deathtouch"))
                  remaining_atk = remaining_atk - to_blocker
                  schedule_damage(damage_queue, "atk", attacker.board_index, b_def.attack or 0, has_keyword(b_def, "deathtouch"))
                end
              end
            end
            if remaining_atk > 0 and has_keyword(atk_def, "trample") then
              if attacker.target.type == "base" then
                base_damage = base_damage + remaining_atk
              elseif attacker.target.type == "board" then
                local te = def_player.board[attacker.target.index]
                if te then
                  schedule_damage(damage_queue, "def", attacker.target.index, remaining_atk, has_keyword(atk_def, "deathtouch"))
                end
              end
            end
          else
            if attacker.target.type == "base" then
              base_damage = base_damage + (atk_def.attack or 0)
            elseif attacker.target.type == "board" then
              local te = def_player.board[attacker.target.index]
              if te then
                local tdef = cards.get_card_def(te.card_id)
                schedule_damage(damage_queue, "def", attacker.target.index, atk_def.attack or 0, has_keyword(atk_def, "deathtouch"))
                if tdef.kind == "Unit" or tdef.kind == "Worker" then
                  schedule_damage(damage_queue, "atk", attacker.board_index, tdef.attack or 0, has_keyword(tdef, "deathtouch"))
                end
              end
            end
          end
        end
      end
    end
  end

  for _, ev in ipairs(damage_queue) do
    local player = (ev.side == "atk") and atk_player or def_player
    apply_board_damage(player, ev.board_index, ev.amount)
    if ev.deathtouch then
      local e = player.board[ev.board_index]
      if e then
        local st = ensure_state(e)
        st.marked_for_death = true
      end
    end
  end

  def_player.life = math.max(0, (def_player.life or 0) - base_damage)

  local deaths = { atk = {}, def = {} }
  for i, e in ipairs(atk_player.board) do
    local def = cards.get_card_def(e.card_id)
    local st = ensure_state(e)
    local hp = (def.health or 0) - (st.damage or 0)
    if st.marked_for_death or hp <= 0 then deaths.atk[#deaths.atk + 1] = i end
  end
  for i, e in ipairs(def_player.board) do
    local def = cards.get_card_def(e.card_id)
    local st = ensure_state(e)
    local hp = (def.health or 0) - (st.damage or 0)
    if st.marked_for_death or hp <= 0 then deaths.def[#deaths.def + 1] = i end
  end

  for i = #deaths.atk, 1, -1 do
    local bi = deaths.atk[i]
    if atk_player.board[bi] then
      local entry = table.remove(atk_player.board, bi)
      atk_player.graveyard[#atk_player.graveyard + 1] = { card_id = entry.card_id, state = entry.state }
    end
  end
  for i = #deaths.def, 1, -1 do
    local bi = deaths.def[i]
    if def_player.board[bi] then
      local entry = table.remove(def_player.board, bi)
      def_player.graveyard[#def_player.graveyard + 1] = { card_id = entry.card_id, state = entry.state }
    end
  end

  -- Clear transient markers/damage on survivors each combat (no persistent wounds in current ruleset).
  for _, p in ipairs({ atk_player, def_player }) do
    for _, e in ipairs(p.board) do
      local st = ensure_state(e)
      st.damage = 0
      st.marked_for_death = nil
    end
  end

  g.pendingCombat = nil
  return true, "ok"
end

return combat
