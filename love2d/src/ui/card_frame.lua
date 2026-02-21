-- Draw a single card frame (mirror of web CardFrame)

local util = require("src.ui.util")
local card_art = require("src.ui.card_art")
local factions = require("src.data.factions")
local keywords_data = require("src.data.keywords")
local res_registry = require("src.data.resources")
local textures = require("src.fx.textures")
local res_icons = require("src.ui.res_icons")

local card_frame = {}

local CARD_W = 160
local CARD_H = 220

-- Get faction strip color (RGBA) from centralized data
local function get_strip_color(faction)
  local f = factions[faction or "Neutral"]
  if f and f.color then
    return { f.color[1], f.color[2], f.color[3], 1.0 }
  end
  return { 0.55, 0.56, 0.83, 1.0 }
end

---------------------------------------------------------
-- Shared: draw a cost cluster (icon + number pairs)
-- Returns total width drawn.
---------------------------------------------------------
local function draw_cost_cluster(cost_list, x, y, icon_size, alpha)
  if not cost_list or #cost_list == 0 then return 0 end
  alpha = alpha or 1
  local start_x = x
  local font = util.get_font(10)
  for _, c in ipairs(cost_list) do
    res_icons.draw_or_fallback(c.type, x, y, icon_size, alpha)
    x = x + icon_size + 1
    love.graphics.setColor(0.85, 0.87, 0.95, alpha)
    love.graphics.setFont(font)
    love.graphics.print(tostring(c.amount), x, y + 1)
    x = x + font:getWidth(tostring(c.amount)) + 4
  end
  return x - start_x
end

-- Measure cost cluster width without drawing
local function measure_cost_cluster(cost_list, icon_size)
  if not cost_list or #cost_list == 0 then return 0 end
  local w = 0
  local font = util.get_font(10)
  for _, c in ipairs(cost_list) do
    w = w + icon_size + 1 + font:getWidth(tostring(c.amount)) + 4
  end
  return w
end

---------------------------------------------------------
-- Draw a standardized activated ability line:
--   [cost icons] : [effect description]
-- Returns the height consumed.
---------------------------------------------------------
---------------------------------------------------------
-- Draw a once-per-turn or repeatable indicator icon
-- Returns width consumed.
---------------------------------------------------------
-- Draw a once-per-turn indicator (only shown for once_per_turn abilities).
-- Returns width consumed (0 if not once-per-turn).
local function draw_frequency_icon(ab, x, y, size, alpha)
  if not ab.once_per_turn then return 0 end
  local cx = x + size / 2
  local cy = y + size / 2
  local r = size / 2
  -- Circle with "1" inside, muted gold
  love.graphics.setColor(0.85, 0.75, 0.4, alpha * 0.6)
  love.graphics.circle("fill", cx, cy, r)
  love.graphics.setColor(0.85, 0.75, 0.4, alpha * 0.9)
  love.graphics.circle("line", cx, cy, r)
  love.graphics.setColor(1, 1, 1, alpha)
  local font = util.get_font(8)
  love.graphics.setFont(font)
  local tw = font:getWidth("1")
  love.graphics.print("1", cx - tw / 2, cy - font:getHeight() / 2)
  return size + 3
end

---------------------------------------------------------
-- Generate a short effect description from ability data
---------------------------------------------------------
local function ability_effect_text(ab)
  local e = ab.effect
  local args = ab.effect_args or {}
  if e == "summon_worker" then
    return "Summon " .. (args.amount or 1) .. " Worker"
  elseif e == "draw_cards" then
    return "Draw " .. (args.amount or 1) .. " Card" .. ((args.amount or 1) > 1 and "s" or "")
  elseif e == "play_unit" then
    local sub = args.subtypes and table.concat(args.subtypes, "/") or "Unit"
    return "Play T" .. (args.tier or "?") .. " " .. sub
  elseif e == "research" then
    return "Research T" .. (args.tier or "?")
  elseif e == "convert_resource" then
    return "Create " .. (args.amount or 1) .. " " .. (args.output or "?")
  elseif e == "buff_attack" then
    return "+" .. (args.amount or 0) .. " ATK"
  elseif e == "buff_self" then
    local atk = args.attack or args.amount or 0
    local hp = args.health or 0
    local parts = {}
    if atk ~= 0 then
      parts[#parts + 1] = (atk > 0 and "+" or "") .. tostring(atk) .. " ATK"
    end
    if hp ~= 0 then
      parts[#parts + 1] = (hp > 0 and "+" or "") .. tostring(hp) .. " HP"
    end
    if #parts == 0 then
      parts[#parts + 1] = "Self buff"
    end
    local text = "Gain " .. table.concat(parts, ", ")
    if args.duration == "end_of_turn" then
      text = text .. " until end of turn"
    end
    return text
  elseif e == "place_counter" then
    return (args.amount or 1) .. " " .. (args.counter or "?") .. " counters"
  elseif e == "heal" then
    return "Heal " .. (args.amount or 0)
  elseif e == "deal_damage" then
    return "Deal " .. (args.amount or 0) .. " dmg"
  elseif e == "sacrifice_produce" then
    local who = (args.condition == "non_undead") and "non-Undead ally" or "ally"
    return "Sacrifice " .. who .. ": Create " .. (args.amount or 1) .. " " .. (args.resource or "resource")
  elseif e == "sacrifice_upgrade" then
    local sub = args.subtypes and table.concat(args.subtypes, "/") or "unit"
    return "Sacrifice " .. sub .. ": Play +1 tier " .. sub
  end
  return ab.label or e or "?"
end

local function draw_ability_line(ab, ab_x, ab_y, max_w, opts)
  opts = opts or {}
  local can_activate = opts.can_activate ~= false
  local is_used = opts.is_used or false
  local is_hov = opts.is_hovered or false
  local alpha = (can_activate and not is_used) and 1.0 or 0.45
  local icon_s = 16
  local r = 4

  local show_text = opts.show_ability_text
  local font = show_text and util.get_font(10) or util.get_font(9)
  local line_h = 26

  local effect_text = show_text and ability_effect_text(ab) or nil
  if show_text then
    local left_w = 5 + (ab.once_per_turn and (icon_s + 3) or 0) + measure_cost_cluster(ab.cost, icon_s)
    local sep_w = font:getWidth(":") + 4
    local remaining_w = math.max(20, max_w - left_w - sep_w - 4)
    local _, wrapped = font:getWrap(effect_text, remaining_w)
    local lines = math.max(1, #wrapped)
    local text_h = lines * font:getHeight()
    line_h = math.max(26, text_h + 8)
  end

  -- Background: subtle gradient-like two-layer fill
  local bar_alpha = (can_activate and not is_used) and 0.22 or 0.08
  if is_hov and can_activate and not is_used then bar_alpha = 0.38 end
  love.graphics.setColor(0.15, 0.18, 0.32, bar_alpha)
  love.graphics.rectangle("fill", ab_x, ab_y, max_w, line_h, r, r)
  -- Lighter inner highlight at top
  love.graphics.setColor(0.3, 0.35, 0.55, bar_alpha * 0.5)
  love.graphics.rectangle("fill", ab_x + 1, ab_y + 1, max_w - 2, math.max(1, line_h * 0.4), r, r)
  -- Left accent mark
  local accent_a = (can_activate and not is_used) and 0.8 or 0.2
  love.graphics.setColor(0.35, 0.6, 1.0, accent_a)
  love.graphics.rectangle("fill", ab_x, ab_y + 2, 3, line_h - 4, 1, 1)
  -- Border
  if is_hov and can_activate and not is_used then
    love.graphics.setColor(0.45, 0.65, 1.0, 0.5)
    love.graphics.rectangle("line", ab_x, ab_y, max_w, line_h, r, r)
  else
    love.graphics.setColor(0.25, 0.28, 0.4, alpha * 0.35)
    love.graphics.rectangle("line", ab_x, ab_y, max_w, line_h, r, r)
  end

  if show_text then
    -- Left-aligned layout: icons then effect text
    local cx = ab_x + 5
    local cy_icon = ab_y + (line_h - icon_s) / 2

    local freq_w = draw_frequency_icon(ab, cx, cy_icon, icon_s, alpha)
    cx = cx + freq_w

    local cost_w = draw_cost_cluster(ab.cost, cx, cy_icon, icon_s, alpha)
    cx = cx + cost_w

    -- Colon separator
    love.graphics.setColor(0.7, 0.72, 0.82, alpha)
    love.graphics.setFont(font)
    love.graphics.print(":", cx, ab_y + (line_h - font:getHeight()) / 2)
    cx = cx + font:getWidth(":") + 4

    -- Effect text
    love.graphics.setColor(0.85, 0.87, 0.95, alpha)
    love.graphics.setFont(font)
    local remaining_w = max_w - (cx - ab_x) - 4
    love.graphics.printf(effect_text, cx, ab_y + (line_h - font:getHeight()) / 2, math.max(remaining_w, 20), "left")
  else
    -- Centered icons only (compact mode)
    local freq_w_est = draw_frequency_icon(ab, -1000, -1000, icon_s, 0)
    local cost_w_est = draw_cost_cluster(ab.cost, -1000, -1000, icon_s, 0)
    local total_content_w = freq_w_est + cost_w_est
    local cx = ab_x + (max_w - total_content_w) / 2
    local cy_icon = ab_y + (line_h - icon_s) / 2

    local freq_w = draw_frequency_icon(ab, cx, cy_icon, icon_s, alpha)
    cx = cx + freq_w
    draw_cost_cluster(ab.cost, cx, cy_icon, icon_s, alpha)
  end

  -- "Used" overlay
  if is_used then
    love.graphics.setColor(0, 0, 0, 0.35)
    love.graphics.rectangle("fill", ab_x, ab_y, max_w, line_h, r, r)
    love.graphics.setColor(0.6, 0.3, 0.3, 0.8)
    love.graphics.setFont(font)
    love.graphics.printf("USED", ab_x, ab_y + (line_h - font:getHeight()) / 2, max_w, "center")
  end

  return line_h + 3
end

---------------------------------------------------------
-- Generate a short description for a single non-activated ability
---------------------------------------------------------
local function passive_ability_text(ab)
  local e = ab.effect
  local args = ab.effect_args or {}
  local trigger = ab.trigger

  if ab.type == "static" then
    if e == "produce" then
      local res = args.resource or "?"
      if args.per_worker then
        local cap = args.max_workers and (" (max " .. args.max_workers .. ")") or ""
        return "Produce " .. args.per_worker .. " " .. res .. "/worker" .. cap
      end
      return "Produce " .. (args.amount or 1) .. " " .. res
    elseif e == "skip_draw" then
      return "You do not draw at the start of your turn"
    elseif e == "bonus_production" then
      return "+" .. (args.bonus or 1) .. " resource per " .. (args.per_workers or 3) .. " workers"
    elseif e == "prevent_rot" then
      return "Prevent " .. (args.amount or 0) .. " " .. (args.resource or "?") .. " rot"
    elseif e == "double_production" then
      return "Double production"
    elseif e == "global_buff" then
      local sub = args.subtypes and table.concat(args.subtypes, "/") or "units"
      return "+" .. (args.attack or 0) .. " ATK to " .. sub
    elseif e == "sacrifice_upgrade" then
      local sub = args.subtypes and table.concat(args.subtypes, "/") or "units"
      return "Sacrifice " .. sub .. " to upgrade"
    elseif e == "monument_cost" then
      return "Monument (" .. (args.min_counters or "?") .. " counters)"
    elseif e == "water_level" then
      return "Water Level +" .. (args.amount or 0)
    elseif e == "double_gain" then
      return "Double " .. (args.resource or "?") .. " gain"
    elseif e == "play_cost_sacrifice" then
      return "Sacrifice to play"
    elseif e == "can_attack_non_rested" then
      return "Can attack without resting"
    elseif e == "stats_equal_resource" then
      return "Stats = " .. (args.resource or "?") .. " count"
    elseif e == "double_end_of_turn_triggers" then
      return "End of turn triggers twice"
    end
    return e or "?"
  end

  if ab.type == "triggered" then
    local prefix = ""
    if trigger == "end_of_turn" then prefix = "End of turn: "
    elseif trigger == "start_of_turn" then prefix = "Start of turn: "
    elseif trigger == "on_play" or trigger == "on_construct" then prefix = "On Play: "
    elseif trigger == "on_ally_death" then prefix = "Ally death: "
    elseif trigger == "on_attack" then prefix = "On attack: "
    elseif trigger == "on_mass_attack" then prefix = "Mass attack: "
    elseif trigger == "on_base_damage" then prefix = "Base dmg: "
    elseif trigger == "on_destroyed" then prefix = "On death: "
    elseif trigger == "after_combat" then prefix = "After combat: "
    elseif trigger == "on_fire_structure_damage" then prefix = "Fire dmg: "
    end

    if e == "produce" then
      return prefix .. "Create " .. (args.amount or 1) .. " " .. (args.resource or "?")
    elseif e == "draw_cards" then
      return prefix .. "Draw " .. (args.amount or 1)
    elseif e == "place_counter" then
      return prefix .. "+" .. (args.amount or 1) .. " " .. (args.counter or "?") .. " counter"
    elseif e == "opt" then
      return prefix .. "Opt " .. (args.base or 1)
    elseif e == "buff_ally_attacker" then
      return prefix .. "+" .. (args.attack or 0) .. " ATK to ally"
    elseif e == "conditional_damage" then
      local body = "Deal " .. (args.damage or 0) .. " dmg"
      if args.target == "unit" then
        body = body .. " to target unit"
      end
      if args.condition == "allied_mounted_attacking" then
        body = "If another Mounted unit attacks, " .. body
      end
      return prefix .. body
    elseif e == "deal_damage_to_target_unit" then
      local amount = args.amount or args.damage or 0
      local body = "Deal " .. amount .. " dmg to target unit"
      if args.requires_another_attacker_subtype then
        body = "If another " .. tostring(args.requires_another_attacker_subtype) .. " unit attacks, " .. body
      end
      return prefix .. body
    elseif e == "buff_warriors_per_scholar" then
      return prefix .. "Buff warriors per scholar"
    elseif e == "grant_keyword" or e == "gain_keyword" then
      local body = "Gain " .. (args.keyword or "?")
      if args.duration == "end_of_turn" then
        body = body .. " until end of turn"
      end
      if ab.cost and #ab.cost > 0 then
        local cost_parts = {}
        for _, c in ipairs(ab.cost) do
          cost_parts[#cost_parts + 1] = tostring(c.amount or 0) .. " " .. tostring(c.type or "?")
        end
        body = "Pay " .. table.concat(cost_parts, ", ") .. ": " .. body
      end
      return prefix .. body
    elseif e == "unrest_target" then
      return prefix .. "Cause unrest"
    elseif e == "steal_resource" then
      return prefix .. "Steal " .. (args.amount or 1) .. " resource"
    elseif e == "discard_random" then
      return prefix .. "Discard " .. (args.amount or 1)
    elseif e == "return_from_graveyard" then
      return prefix .. "Return " .. (args.kind or "card") .. " from graveyard"
    elseif e == "return_to_hand" then
      return prefix .. "Return to hand"
    elseif e == "destroy_all_units" then
      return prefix .. "Destroy all units"
    elseif e == "worker_deal_damage" then
      return prefix .. "Worker deals " .. (args.damage or 0) .. " dmg"
    elseif e == "double_resource" then
      return prefix .. "Double " .. (args.resource or "?")
    end
    return prefix .. (e or "?")
  end

  return e or "?"
end

---------------------------------------------------------
-- Build display text from only the non-activated abilities
---------------------------------------------------------
local function non_activated_text(abilities_list)
  if not abilities_list or #abilities_list == 0 then return nil end
  local parts = {}
  for _, ab in ipairs(abilities_list) do
    if ab.type ~= "activated" then
      parts[#parts + 1] = passive_ability_text(ab)
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, ". ") .. "."
end

local function trim_text(s)
  if type(s) ~= "string" then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function build_keyword_name_set()
  local out = {}
  for _, kd in pairs(keywords_data or {}) do
    if type(kd) == "table" and type(kd.name) == "string" and kd.name ~= "" then
      out[string.lower(kd.name)] = true
    end
  end
  return out
end

local KEYWORD_NAME_SET = build_keyword_name_set()

local function split_rule_sentences(raw_text)
  local out = {}
  if type(raw_text) ~= "string" or raw_text == "" then
    return out
  end

  local i = 1
  local n = #raw_text
  while i <= n do
    while i <= n and raw_text:sub(i, i):match("%s") do
      i = i + 1
    end
    if i > n then break end

    local j = i
    while j <= n and not raw_text:sub(j, j):match("[%.!?]") do
      j = j + 1
    end

    if j > n then
      out[#out + 1] = raw_text:sub(i)
      break
    end

    local k = j
    while k + 1 <= n and raw_text:sub(k + 1, k + 1):match("[%.!?]") do
      k = k + 1
    end

    out[#out + 1] = raw_text:sub(i, k)
    i = k + 1
  end

  return out
end

local function is_keyword_sentence(sentence)
  local core = trim_text(sentence)
  if core == "" then return false end
  core = core:gsub("[%.!?:]+$", "")
  return KEYWORD_NAME_SET[string.lower(core)] == true
end

local function build_rule_segments_with_keywords(display_text)
  local sentences = split_rule_sentences(display_text)
  local segments = {}
  local normal_parts = {}

  local function flush_normal_parts()
    if #normal_parts > 0 then
      segments[#segments + 1] = {
        text = table.concat(normal_parts, " "),
        bold = false,
      }
      normal_parts = {}
    end
  end

  for _, sentence in ipairs(sentences) do
    local clean = trim_text(sentence)
    if clean ~= "" then
      if is_keyword_sentence(clean) then
        flush_normal_parts()
        segments[#segments + 1] = { text = clean, bold = true }
      else
        normal_parts[#normal_parts + 1] = clean
      end
    end
  end

  flush_normal_parts()
  return segments
end

local function draw_rules_text_with_keyword_emphasis(display_text, x, y, max_w, max_y, text_color)
  local segments = build_rule_segments_with_keywords(display_text)
  if #segments == 0 then return end

  local font = util.get_font(9)
  local line_h = font:getHeight()
  local draw_y = y

  for _, seg in ipairs(segments) do
    local _, lines = font:getWrap(seg.text, max_w)
    if #lines == 0 then
      lines = { seg.text }
    end

    for _, line in ipairs(lines) do
      if draw_y > max_y then
        return
      end
      love.graphics.setFont(font)
      love.graphics.setColor(text_color[1], text_color[2], text_color[3], 0.9)
      if seg.bold then
        -- Faux-bold for keyword lines using two close draws.
        love.graphics.print(line, x, draw_y)
        love.graphics.print(line, x + 0.7, draw_y)
      else
        love.graphics.print(line, x, draw_y)
      end
      draw_y = draw_y + line_h
    end

    -- Force a visual break after keyworded ability lines.
    if seg.bold then
      draw_y = draw_y + 1
    end
  end
end

---------------------------------------------------------
-- Compact ability button for structure tiles on the board.
-- Fits in ~82x18px with same visual language as ability lines.
-- opts: can_activate, is_used, is_hovered, effect_text
-- Returns height consumed.
---------------------------------------------------------
function card_frame.draw_ability_button(ab, bx, by, bw, opts)
  opts = opts or {}
  local can_activate = opts.can_activate ~= false
  local is_used = opts.is_used or false
  local is_hov = opts.is_hovered or false
  local alpha = (can_activate and not is_used) and 1.0 or 0.4
  local btn_h = 24
  local icon_s = 14
  local r = 4

  -- Button background: two-layer fill for depth
  local bg_alpha = (can_activate and not is_used) and 0.28 or 0.1
  if is_hov and can_activate and not is_used then bg_alpha = 0.45 end
  love.graphics.setColor(0.12, 0.16, 0.3, bg_alpha)
  love.graphics.rectangle("fill", bx, by, bw, btn_h, r, r)
  -- Lighter inner highlight at top
  love.graphics.setColor(0.25, 0.3, 0.5, bg_alpha * 0.4)
  love.graphics.rectangle("fill", bx + 1, by + 1, bw - 2, btn_h * 0.4, r, r)

  -- Left accent
  local accent_a = (can_activate and not is_used) and 0.7 or 0.15
  love.graphics.setColor(0.35, 0.6, 1.0, accent_a)
  love.graphics.rectangle("fill", bx, by + 2, 3, btn_h - 4, 1, 1)

  -- Border
  if is_hov and can_activate and not is_used then
    love.graphics.setColor(0.45, 0.65, 1.0, 0.55)
    love.graphics.rectangle("line", bx, by, bw, btn_h, r, r)
  else
    love.graphics.setColor(0.25, 0.28, 0.4, alpha * 0.4)
    love.graphics.rectangle("line", bx, by, bw, btn_h, r, r)
  end

  if ab.label then
    love.graphics.setColor(1, 1, 1, alpha)
    love.graphics.setFont(util.get_font(9))
    love.graphics.printf(ab.label, bx, by + (btn_h - 10) / 2, bw, "center")
  else
    -- Measure content width to center icons
    local freq_w_est = draw_frequency_icon(ab, -1000, -1000, icon_s, 0)
    local cost_w_est = draw_cost_cluster(ab.cost, -1000, -1000, icon_s, 0)
    local total_w = freq_w_est + cost_w_est
    local cx = bx + (bw - total_w) / 2
    local cy = by + (btn_h - icon_s) / 2

    -- Frequency icon
    local freq_w = draw_frequency_icon(ab, cx, cy, icon_s, alpha)
    cx = cx + freq_w

    -- Cost icons
    draw_cost_cluster(ab.cost, cx, cy, icon_s, alpha)
  end

  -- "Used" overlay
  if is_used then
    love.graphics.setColor(0, 0, 0, 0.35)
    love.graphics.rectangle("fill", bx, by, bw, btn_h, r, r)
    love.graphics.setColor(0.6, 0.3, 0.3, 0.8)
    love.graphics.setFont(util.get_font(8))
    love.graphics.printf("USED", bx, by + (btn_h - 10) / 2, bw, "center")
  end

  return btn_h
end

---------------------------------------------------------
-- Main card draw
-- params: title, faction, kind, typeLine, text, costs,
--         attack, health, population, tier, is_base,
--         abilities_list, used_abilities, can_activate_abilities
---------------------------------------------------------
function card_frame.draw(x, y, params)
  local w, h = params.w or CARD_W, params.h or CARD_H
  local title = params.title or "?"
  local faction = params.faction or "Neutral"
  local kind = params.kind or "Structure"
  local type_line = params.typeLine or ""
  local text = params.text or ""
  local costs = params.costs or {}
  local upkeep = params.upkeep or {}
  local attack = params.attack
  local health = params.health
  local tier = params.tier
  local is_base = params.is_base or false
  -- New: full abilities list for standardized rendering
  local abilities_list = params.abilities_list  -- array of ability defs
  local used_abilities = params.used_abilities or {}  -- { [ability_index] = true }
  local can_activate_abilities = params.can_activate_abilities or {}  -- { [ability_index] = true }
  -- Legacy compat (single activated ability)
  local activated_ability = params.activated_ability
  local ability_used_this_turn = params.ability_used_this_turn
  local ability_can_activate = params.ability_can_activate ~= false
  local show_ability_text = params.show_ability_text or false

  local strip_color = get_strip_color(faction)
  local bg_dark = { 0.08, 0.09, 0.13, 1.0 }
  local bg_card = { 0.15, 0.17, 0.22, 1.0 }
  local border = { 0.22, 0.24, 0.3, 1.0 }
  local gold_border = { 0.96, 0.78, 0.42, 1.0 }
  local text_color = { 0.82, 0.83, 0.88, 1.0 }
  local muted = { 0.58, 0.6, 0.68, 1.0 }
  local art_bg = { 0.1, 0.11, 0.15, 1.0 }

  local pad = 6

  -- ===================== CARD SHADOW =====================
  if is_base then
    -- Warm golden shadow for bases
    love.graphics.setColor(0.2, 0.15, 0.05, 0.45)
    love.graphics.rectangle("fill", x + 4, y + 5, w + 2, h + 2, 8, 8)
  else
    love.graphics.setColor(0, 0, 0, 0.45)
    love.graphics.rectangle("fill", x + 3, y + 4, w, h, 8, 8)
  end

  -- ===================== CARD BODY =====================
  love.graphics.setColor(bg_card)
  love.graphics.rectangle("fill", x, y, w, h, 6, 6)

  -- Parchment texture overlay
  love.graphics.setScissor(x, y, w, h)
  textures.draw_tiled(textures.card, x, y, w, h, 0.06)
  love.graphics.setScissor()

  -- Subtle inner glow at top
  love.graphics.setColor(1, 1, 1, 0.04)
  love.graphics.rectangle("fill", x + 3, y + 2, w - 6, 2)

  -- ===================== BORDER =====================
  love.graphics.setLineWidth(2)
  if is_base then
    -- Double border for bases: outer gold, inner dark
    love.graphics.setColor(gold_border[1], gold_border[2], gold_border[3], 0.5)
    love.graphics.rectangle("line", x - 1, y - 1, w + 2, h + 2, 7, 7)
    love.graphics.setColor(gold_border)
    love.graphics.rectangle("line", x, y, w, h, 6, 6)
  else
    love.graphics.setColor(border)
    love.graphics.rectangle("line", x, y, w, h, 6, 6)
  end
  love.graphics.setLineWidth(1)

  -- ===================== FACTION STRIP (left edge) =====================
  for i = 0, 3 do
    local a = 0.5 * (1 - i / 4)
    love.graphics.setColor(strip_color[1], strip_color[2], strip_color[3], a)
    love.graphics.rectangle("fill", x + i + 1, y + 6, 1, h - 12)
  end

  local cx, cy = x + pad, y + pad

  -- ===================== HEADER =====================
  local header_h = 22
  local header_w = w - pad * 2

  -- Header background (dark recessed bar)
  love.graphics.setColor(0.06, 0.07, 0.1, 0.8)
  love.graphics.rectangle("fill", cx, cy, header_w, header_h, 3, 3)
  -- Faction-colored top edge on header
  love.graphics.setColor(strip_color[1], strip_color[2], strip_color[3], 0.6)
  love.graphics.rectangle("fill", cx + 2, cy, header_w - 4, 2, 1, 1)

  -- Title text
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(util.get_title_font(12))
  love.graphics.print(title, cx + 5, cy + 4)

  -- Build cost icons (right-aligned in header)
  if #costs > 0 then
    local icon_s = 12
    local cost_w = measure_cost_cluster(costs, icon_s)
    local cost_x = cx + header_w - cost_w - 4
    local cost_y = cy + (header_h - icon_s) / 2
    draw_cost_cluster(costs, cost_x, cost_y, icon_s)
  end

  cy = cy + header_h + 3

  -- ===================== TYPE LINE + TIER =====================
  love.graphics.setColor(muted)
  love.graphics.setFont(util.get_font(9))
  love.graphics.print(type_line, cx + 2, cy)
  -- Tier badge (right-aligned)
  if tier and tier > 0 then
    local tier_font = util.get_font(9)
    local tier_label = "T" .. tostring(tier)
    local tw_text = tier_font:getWidth(tier_label)
    -- Small pill badge
    local pill_w = tw_text + 8
    local pill_h = 12
    local pill_x = cx + header_w - pill_w - 1
    local pill_y = cy
    love.graphics.setColor(strip_color[1], strip_color[2], strip_color[3], 0.2)
    love.graphics.rectangle("fill", pill_x, pill_y, pill_w, pill_h, 3, 3)
    love.graphics.setColor(strip_color[1], strip_color[2], strip_color[3], 0.8)
    love.graphics.setFont(tier_font)
    love.graphics.printf(tier_label, pill_x, pill_y + 1, pill_w, "center")
  end

  -- Upkeep strip for units/resources that must be paid at end of turn.
  if upkeep and #upkeep > 0 then
    local up_h = 14
    love.graphics.setColor(0.28, 0.12, 0.12, 0.45)
    love.graphics.rectangle("fill", cx, cy + 12, header_w, up_h, 3, 3)
    love.graphics.setColor(0.8, 0.35, 0.35, 0.65)
    love.graphics.rectangle("line", cx, cy + 12, header_w, up_h, 3, 3)
    love.graphics.setFont(util.get_font(8))
    love.graphics.setColor(0.95, 0.75, 0.75, 0.95)
    love.graphics.print("Upkeep", cx + 4, cy + 15)
    local icon_s = 10
    local cost_w = measure_cost_cluster(upkeep, icon_s)
    local ux = cx + header_w - cost_w - 4
    local uy = cy + 14
    draw_cost_cluster(upkeep, ux, uy, icon_s, 0.95)
    cy = cy + 28
  else
    cy = cy + 13
  end

  cy = cy + 2

  -- ===================== ART BOX =====================
  local art_h = math.min(62, h - 130)  -- scales down for shorter cards (e.g. bases)
  local art_w = header_w
  -- Art background
  love.graphics.setColor(art_bg)
  love.graphics.rectangle("fill", cx, cy, art_w, art_h, 4, 4)
  -- Art content (with scissor to clip to art box)
  love.graphics.setScissor(cx, cy, art_w, art_h)
  card_art.draw_card_art(cx, cy, art_w, art_h, kind, is_base, title or faction)
  love.graphics.setScissor()  -- Clear scissor immediately after art
  -- Inner shadow on art box
  textures.draw_inner_shadow(cx, cy, art_w, art_h, 3, 0.25)
  -- Art border
  love.graphics.setColor(0.15, 0.16, 0.2, 1)
  love.graphics.rectangle("line", cx, cy, art_w, art_h, 4, 4)
  cy = cy + art_h + 4

  -- ===================== DIVIDER =====================
  love.graphics.setColor(strip_color[1], strip_color[2], strip_color[3], 0.25)
  love.graphics.rectangle("fill", cx + 4, cy - 2, art_w - 8, 1)

  -- ===================== ABILITIES / TEXT AREA =====================
  -- Calculate how much vertical space we have before the stat bar
  local stat_bar_h = ((attack ~= nil or health ~= nil) and 24 or 0)
  local text_area_bottom = y + h - pad - stat_bar_h - 2
  local text_area_h = math.max(1, text_area_bottom - cy)  -- Ensure positive height

  -- Note: Scissor clipping disabled for scaled cards (hand) as it uses screen coords
  -- Content will render without clipping - text overflow is handled by printf width limit

  -- Draw standardized ability lines (new system)
  local ab_y = cy
  local has_activated_abilities = false
  
  if abilities_list and #abilities_list > 0 then
    for ai, ab in ipairs(abilities_list) do
      if ab.type == "activated" then
        has_activated_abilities = true
        local is_used = used_abilities[ai] or false
        local can_act = can_activate_abilities[ai] or false
        local consumed = draw_ability_line(ab, cx, ab_y, art_w, {
          can_activate = can_act,
          is_used = is_used,
          show_ability_text = show_ability_text,
        })
        ab_y = ab_y + consumed
      end
    end
  elseif activated_ability then
    -- Legacy: single activated ability rendering
    has_activated_abilities = true
    local is_used = ability_used_this_turn and activated_ability.once_per_turn
    local can_act = ability_can_activate and not is_used
    local consumed = draw_ability_line(activated_ability, cx, ab_y, art_w, {
      can_activate = can_act,
      is_used = is_used,
      show_ability_text = show_ability_text,
    })
    ab_y = ab_y + consumed
  end

  -- Show rules text under ability lines without duplicating activated ability effect text.
  local display_text = text
  if has_activated_abilities then
    display_text = non_activated_text(abilities_list) or non_activated_text(activated_ability and { activated_ability } or nil)
  end
  if display_text and display_text ~= "" then
    local text_y = has_activated_abilities and (ab_y + 2) or (cy + 1)
    -- Ensure text doesn't go below the stat bar
    local max_text_y = y + h - pad - stat_bar_h - 20
    if text_y < max_text_y then
      draw_rules_text_with_keyword_emphasis(display_text, cx + 2, text_y, art_w - 4, max_text_y, text_color)
    end
  end

  -- Always clear scissor at end of text area
  love.graphics.setScissor()

  -- ===================== STAT BAR =====================
  if attack ~= nil or health ~= nil then
    local stat_y = y + h - pad - stat_bar_h
    local stat_h = 20

    if attack ~= nil then
      -- ATK badge (left)
      local sw = (art_w - 4) / 2
      love.graphics.setColor(0.5, 0.2, 0.2, 0.35)
      love.graphics.rectangle("fill", cx, stat_y, sw, stat_h, 3, 3)
      love.graphics.setColor(0.7, 0.3, 0.3, 0.5)
      love.graphics.rectangle("line", cx, stat_y, sw, stat_h, 3, 3)
      -- Bevel
      love.graphics.setColor(1, 1, 1, 0.05)
      love.graphics.rectangle("fill", cx + 1, stat_y + 1, sw - 2, 1)
      love.graphics.setColor(text_color)
      love.graphics.setFont(util.get_font(10))
      love.graphics.printf("ATK " .. tostring(attack), cx, stat_y + stat_h/2 - 6, sw, "center")
    end

    if health ~= nil then
      -- HP badge (right)
      local sw = (art_w - 4) / 2
      local right_x = cx + art_w - sw
      love.graphics.setColor(0.2, 0.35, 0.2, 0.35)
      love.graphics.rectangle("fill", right_x, stat_y, sw, stat_h, 3, 3)
      love.graphics.setColor(0.3, 0.55, 0.3, 0.5)
      love.graphics.rectangle("line", right_x, stat_y, sw, stat_h, 3, 3)
      -- Bevel
      love.graphics.setColor(1, 1, 1, 0.05)
      love.graphics.rectangle("fill", right_x + 1, stat_y + 1, sw - 2, 1)
      love.graphics.setColor(text_color)
      love.graphics.setFont(util.get_font(10))
      love.graphics.printf("HP " .. tostring(health), right_x, stat_y + stat_h/2 - 6, sw, "center")
    end
  end
end

---------------------------------------------------------
-- Resource node card (compact, full-art style)
---------------------------------------------------------
local RESOURCE_NODE_W = 120
local RESOURCE_NODE_H = 90
local RESOURCE_TITLE_BAR_H = 18

function card_frame.draw_resource_node(x, y, title, faction)
  local w, h = RESOURCE_NODE_W, RESOURCE_NODE_H
  local strip_color = get_strip_color(faction)
  local border = { 0.16, 0.18, 0.22, 1.0 }
  local text_color = { 0.82, 0.83, 0.88, 1.0 }
  local art_bg = { 0.12, 0.13, 0.18, 1.0 }

  -- Shadow
  love.graphics.setColor(0, 0, 0, 0.3)
  love.graphics.rectangle("fill", x + 3, y + 3, w, h, 6, 6)

  -- Background
  local art_h = h - RESOURCE_TITLE_BAR_H
  love.graphics.setColor(art_bg)
  love.graphics.rectangle("fill", x, y, w, h, 5, 5)
  love.graphics.setColor(border)
  love.graphics.rectangle("line", x, y, w, h, 5, 5)

  -- Draw the resource icon centered in the art area
  local t = (title or ""):lower()
  local res_type = "food"
  if t:match("wood") or t:match("forest") then res_type = "wood"
  elseif t:match("stone") or t:match("quarry") then res_type = "stone" end

  local icon_size = math.min(art_h - 12, w - 24)
  local icon_x = x + (w - icon_size) / 2
  local icon_y = y + (art_h - icon_size) / 2
  if not res_icons.draw(res_type, icon_x, icon_y, icon_size, 0.9) then
    local card_art_mod = require("src.ui.card_art")
    card_art_mod.draw_resource_art(x, y, w, art_h, title)
  end

  -- Minimal title bar at bottom
  local bar_y = y + h - RESOURCE_TITLE_BAR_H
  love.graphics.setColor(0.08, 0.09, 0.12, 0.95)
  love.graphics.rectangle("fill", x, bar_y, w, RESOURCE_TITLE_BAR_H)
  love.graphics.setColor(strip_color)
  love.graphics.rectangle("fill", x, bar_y, 3, RESOURCE_TITLE_BAR_H)
  love.graphics.setColor(text_color)
  love.graphics.setFont(util.get_font(10))
  love.graphics.print(title or "?", x + 10, bar_y + 4)
end

---------------------------------------------------------
-- Ability activation hit-test rectangles
-- Returns an array of { x, y, w, h, ability_index } for
-- all activated abilities on a card at (card_x, card_y).
---------------------------------------------------------
card_frame.ACTIVATE_ICON_SIZE = 22  -- kept for legacy compat

function card_frame.get_ability_rects(card_x, card_y, card_w, card_h, abilities_list)
  if not abilities_list then return {} end
  local rects = {}
  local pad = 6
  local header_h = 22 + 3  -- header + gap
  local type_h = 13 + 2    -- type line + gap
  local art_h = math.min(62, card_h - 130) + 4  -- matches draw's dynamic art_h + gap
  local ab_y = card_y + pad + header_h + type_h + art_h
  local ab_w = card_w - pad * 2
  local line_h = 29  -- ability line height (26) + gap (3)

  for ai, ab in ipairs(abilities_list) do
    if ab.type == "activated" then
      rects[#rects + 1] = { x = card_x + pad, y = ab_y, w = ab_w, h = 26, ability_index = ai }
      ab_y = ab_y + line_h
    end
  end
  return rects
end

-- Legacy: rect for single activate icon (for base cards using old system)
function card_frame.activate_icon_rect(card_x, card_y, card_w, card_h)
  local pad = 6
  local header_h = 22 + 3
  local type_h = 13 + 2
  local art_h = math.min(62, card_h - 130) + 4
  local ab_y = card_y + pad + header_h + type_h + art_h
  local ab_w = card_w - pad * 2
  return card_x + pad, ab_y, ab_w, 26
end

card_frame.CARD_W = CARD_W
card_frame.CARD_H = CARD_H
card_frame.RESOURCE_NODE_W = RESOURCE_NODE_W
card_frame.RESOURCE_NODE_H = RESOURCE_NODE_H

-- Exported helpers for external use
card_frame.ability_effect_text = ability_effect_text
card_frame.draw_cost_cluster = draw_cost_cluster

return card_frame
