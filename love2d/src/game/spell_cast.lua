local actions = require("src.game.actions")
local abilities = require("src.game.abilities")

local spell_cast = {}

local on_cast_effect_handlers = {}

local function handle_spell_on_cast_deal_damage(ctx, sab, args)
  if not ctx.target_board_index then
    return false
  end

  local damage = args.damage or 0
  actions.apply_damage_to_unit(ctx.g, ctx.target_player_index, ctx.target_board_index, damage)
  abilities.result_add_event(ctx.aggregate, {
    type = "damage_dealt",
    source = "spell_on_cast",
    effect = sab.effect,
    damage = damage,
    target_player_index = ctx.target_player_index,
    target_board_index = ctx.target_board_index,
  })
  return true
end

local function handle_spell_on_cast_deal_damage_aoe(ctx, sab, args)
  local damage = args.damage or 0
  if not (damage > 0 and ctx.g.pendingCombat and args.target == "attacking_units") then
    return false
  end

  local c = ctx.g.pendingCombat
  local atk_player = ctx.g.players[c.attacker + 1]
  if atk_player then
    local targets = {}
    for _, attacker in ipairs(c.attackers or {}) do
      if not attacker.invalidated and attacker.board_index and atk_player.board[attacker.board_index] then
        targets[#targets + 1] = attacker.board_index
      end
    end
    table.sort(targets, function(a, b) return a > b end)
    for _, bi in ipairs(targets) do
      actions.apply_damage_to_unit(ctx.g, c.attacker, bi, damage)
    end
    abilities.result_add_event(ctx.aggregate, {
      type = "damage_aoe_applied",
      source = "spell_on_cast",
      effect = sab.effect,
      damage = damage,
      target = args.target,
      affected = #targets,
    })
  end

  return true
end

local function handle_spell_on_cast_destroy_unit(ctx, sab)
  if not ctx.target_board_index then
    return false
  end

  local tp = ctx.g.players[ctx.target_player_index + 1]
  if tp and tp.board[ctx.target_board_index] then
    local destroyed = actions.destroy_board_entry_any(ctx.g, ctx.target_player_index, ctx.target_board_index)
    if destroyed then
      abilities.result_add_event(ctx.aggregate, {
        type = "unit_destroyed",
        source = "spell_on_cast",
        effect = sab.effect,
        target_player_index = ctx.target_player_index,
        target_board_index = ctx.target_board_index,
      })
    end
  end

  return true
end

function spell_cast.register_on_cast_effect_handler(effect, handler)
  if type(effect) ~= "string" or effect == "" then
    error("spell_cast.register_on_cast_effect_handler requires non-empty effect")
  end
  if type(handler) ~= "function" then
    error("spell_cast.register_on_cast_effect_handler requires handler function")
  end
  on_cast_effect_handlers[effect] = handler
  return handler
end

function spell_cast.resolve_on_cast(g, caster_player, caster_index, spell_def, target_player_index, target_board_index)
  local aggregate = abilities.new_resolve_result(nil, nil)
  local ctx = {
    g = g,
    caster_player = caster_player,
    caster_index = caster_index,
    target_player_index = target_player_index,
    target_board_index = target_board_index,
    aggregate = aggregate,
  }

  for _, sab in ipairs((spell_def and spell_def.abilities) or {}) do
    if sab.trigger == "on_cast" then
      local args = sab.effect_args or {}
      local handled = false
      local handler = on_cast_effect_handlers[sab.effect]
      if type(handler) == "function" then
        handled = handler(ctx, sab, args) == true
      end
      if not handled then
        abilities.merge_resolve_result(aggregate, abilities.resolve(sab, caster_player, g, {}))
      end
    end
  end

  return aggregate
end

-- Runs target validation and executes a spell-cast mutation callback with a
-- resolve_on_cast callback bound to the provided cast context.
-- Returns:
--   ok, reason, cast_info, failure_stage
-- where `failure_stage` is `target_validation` or `cast_action` on failure.
function spell_cast.perform_validated_cast(g, opts)
  opts = opts or {}
  local caster_player = opts.caster_player
  local caster_index = opts.caster_index
  local spell_def = opts.spell_def
  local target_player_index = opts.target_player_index
  local target_board_index = opts.target_board_index
  local cast_action = opts.cast_action

  if type(g) ~= "table"
    or type(caster_player) ~= "table"
    or type(caster_index) ~= "number"
    or type(spell_def) ~= "table"
    or type(cast_action) ~= "function"
  then
    return false, "invalid_spell_cast_request", nil, "invalid"
  end

  local target_ok, target_reason = abilities.validate_spell_on_cast_targets(
    g, spell_def, target_player_index, target_board_index, caster_index
  )
  if not target_ok then
    return false, target_reason or "invalid_spell_target", nil, "target_validation"
  end

  local cast_ok, cast_reason, cast_info = cast_action(function(cast_spell_def, cast_spell_id)
    return spell_cast.resolve_on_cast(
      g, caster_player, caster_index, cast_spell_def, target_player_index, target_board_index
    )
  end)
  if not cast_ok then
    return false, cast_reason, cast_info, "cast_action"
  end

  return true, nil, cast_info, nil
end

spell_cast.register_on_cast_effect_handler("deal_damage", handle_spell_on_cast_deal_damage)
spell_cast.register_on_cast_effect_handler("deal_damage_aoe", handle_spell_on_cast_deal_damage_aoe)
spell_cast.register_on_cast_effect_handler("destroy_unit", handle_spell_on_cast_destroy_unit)

return spell_cast
