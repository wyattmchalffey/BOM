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
local FULL_CARD_ASPECT_H_OVER_W = 3.5 / 2.5

-- love.graphics.setScissor expects screen-space coordinates, while card drawing
-- may run under a translate/scale transform (hand cards). Convert local rects.
local function set_local_scissor(x, y, w, h)
  local x1, y1 = x, y
  local x2, y2 = x + w, y + h
  if love.graphics.transformPoint then
    x1, y1 = love.graphics.transformPoint(x1, y1)
    x2, y2 = love.graphics.transformPoint(x2, y2)
  end
  local sx = math.floor(math.min(x1, x2) + 0.5)
  local sy = math.floor(math.min(y1, y2) + 0.5)
  local sw = math.max(0, math.floor(math.abs(x2 - x1) + 0.5))
  local sh = math.max(0, math.floor(math.abs(y2 - y1) + 0.5))
  love.graphics.setScissor(sx, sy, sw, sh)
end

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
-- Also draws a Fast indicator when ab.fast == true.
-- Returns width consumed (0 if neither applies).
local function draw_frequency_icon(ab, x, y, size, alpha)
  local consumed = 0
  if ab.fast then
    -- Small cyan diamond with "F" — indicates the ability is usable at Fast speed
    local cx = x + size / 2
    local cy = y + size / 2
    local r = size / 2
    love.graphics.setColor(0.2, 0.85, 0.95, alpha * 0.6)
    love.graphics.circle("fill", cx, cy, r)
    love.graphics.setColor(0.3, 0.95, 1.0, alpha * 0.9)
    love.graphics.circle("line", cx, cy, r)
    love.graphics.setColor(1, 1, 1, alpha)
    local font = util.get_font(8)
    love.graphics.setFont(font)
    local tw = font:getWidth("F")
    love.graphics.print("F", cx - tw / 2, cy - font:getHeight() / 2)
    x = x + size + 3
    consumed = consumed + size + 3
  end
  if ab.once_per_turn then
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
    consumed = consumed + size + 3
  end
  return consumed
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
    local sub = args.subtypes and table.concat(args.subtypes, "/") or (args.kind or "Unit")
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
    return "+" .. (args.amount or 1) .. " " .. (args.counter or "?") .. " counter"
  elseif e == "remove_counter_draw" then
    return "-" .. (args.remove or 1) .. " " .. (args.counter or "?") .. ": Draw " .. (args.draw or 1)
  elseif e == "remove_counter_play" then
    local sub = args.subtypes and table.concat(args.subtypes, "/") or "unit"
    return "-" .. (args.remove or 1) .. " " .. (args.counter or "?") .. ": Play " .. sub
  elseif e == "heal" then
    return "Heal " .. (args.amount or 0)
  elseif e == "deal_damage" then
    local tgt = args.target == "global" and "any target" or (args.target == "unit" and "target unit" or "target")
    return "Deal " .. (args.damage or args.amount or 0) .. " damage to " .. tgt
  elseif e == "deal_damage_x" then
    local res = args.resource or "resource"
    return "Spend X " .. res:sub(1,1):upper() .. res:sub(2) .. ": Deal X damage to target unit"
  elseif e == "discard_draw" then
    local d = args.discard or 1
    local dr = args.draw or 1
    return "Discard " .. d .. " card" .. (d > 1 and "s" or "") .. ", then draw " .. dr
  elseif e == "play_spell" then
    local sub = args.subtypes and table.concat(args.subtypes, "/") or "Spell"
    return "Play a T" .. (args.tier or "?") .. " " .. sub .. " Spell"
  elseif e == "sacrifice_produce" then
    local who = (args.condition == "non_undead") and "non-Undead ally" or "ally"
    return "Sacrifice " .. who .. ": Create " .. (args.amount or 1) .. " " .. (args.resource or "resource")
  elseif e == "sacrifice_upgrade" then
    local sub = args.subtypes and table.concat(args.subtypes, "/") or "unit"
    return "Sacrifice " .. sub .. ": Play +1 tier " .. sub
  end
  return ab.label or e or "?"
end

local function measure_ability_line_height(ab, max_w, show_ability_text)
  local icon_s = 16
  local line_h = 26

  if show_ability_text then
    local font = util.get_font(10)
    local effect_text = ab.text or ability_effect_text(ab)
    local left_w = 5 + ((ab.once_per_turn and 1 or 0) + (ab.fast and 1 or 0)) * (icon_s + 3) + measure_cost_cluster(ab.cost, icon_s)
    local sep_w = font:getWidth(":") + 4
    local remaining_w = math.max(20, max_w - left_w - sep_w - 4)
    local _, wrapped = font:getWrap(effect_text, remaining_w)
    local lines = math.max(1, #wrapped)
    local text_h = lines * font:getHeight()
    line_h = math.max(26, text_h + 8)
  end

  return line_h + 3
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
  local text_alpha = show_text and 1.0 or alpha
  local icon_alpha = show_text and 1.0 or alpha
  local line_h = 26
  local text_h_measured = 0

  local effect_text = show_text and (ab.text or ability_effect_text(ab)) or nil
  if show_text then
    local left_w = 5 + ((ab.once_per_turn and 1 or 0) + (ab.fast and 1 or 0)) * (icon_s + 3) + measure_cost_cluster(ab.cost, icon_s)
    local sep_w = font:getWidth(":") + 4
    local remaining_w = math.max(20, max_w - left_w - sep_w - 4)
    local _, wrapped = font:getWrap(effect_text, remaining_w)
    local lines = math.max(1, #wrapped)
    text_h_measured = lines * font:getHeight()
    line_h = math.max(26, text_h_measured + 8)
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
    local text_top = ab_y + (line_h - text_h_measured) / 2  -- vertically center the text block
    local cy_icon = ab_y + (line_h - icon_s) / 2            -- icons centered in button

    local freq_w = draw_frequency_icon(ab, cx, cy_icon, icon_s, icon_alpha)
    cx = cx + freq_w

    local cost_w = draw_cost_cluster(ab.cost, cx, cy_icon, icon_s, icon_alpha)
    cx = cx + cost_w

    -- Colon separator (aligned to first line of text)
    love.graphics.setColor(0.7, 0.72, 0.82, text_alpha)
    love.graphics.setFont(font)
    love.graphics.print(":", cx, text_top)
    cx = cx + font:getWidth(":") + 4

    -- Effect text (wrapped, vertically centered as a block)
    love.graphics.setColor(0.85, 0.87, 0.95, text_alpha)
    love.graphics.setFont(font)
    local remaining_w = max_w - (cx - ab_x) - 4
    love.graphics.printf(effect_text, cx, text_top, math.max(remaining_w, 20), "left")
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
  if is_used and not show_text then
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
    elseif trigger == "on_ally_death" then
      local cond = args.condition
      if cond == "non_undead_orc" then prefix = "Non-Undead Orc death: "
      elseif cond == "non_undead" then prefix = "Non-Undead ally death: "
      else prefix = "Ally death: "
      end
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
  local core_lc = string.lower(core)
  if KEYWORD_NAME_SET[core_lc] == true then
    return true
  end

  -- Keyword headers may list multiple keywords (for example: "Trample, Vigilance.").
  -- Treat comma- or "and"-separated keyword-only lines as keyword sentences.
  do
    local normalized = core_lc:gsub("%s+and%s+", ",")
    local parts = {}
    for token in normalized:gmatch("[^,]+") do
      local part = trim_text(token)
      if part ~= "" then
        parts[#parts + 1] = part
      end
    end
    if #parts >= 2 then
      local all_keywords = true
      for _, part in ipairs(parts) do
        if KEYWORD_NAME_SET[part] ~= true then
          all_keywords = false
          break
        end
      end
      if all_keywords then
        return true
      end
    end
  end

  -- Monument reminder cards commonly use a keyword header like "Monument 4."
  -- Treat this as a keyword line so it gets bolded + separated like other keywords.
  if core_lc:match("^monument%s+%d+$") or core_lc:match("^monument%s+x$") then
    return true
  end

  return false
end

local BOLD_TRIGGER_PREFIXES = {
  "on play:",
  "start of turn:",
  "end of turn:",
  "on attack:",
  "mass attack:",
  "base dmg:",
  "on death:",
  "after combat:",
  "fire dmg:",
  "ally death:",
  "non-undead ally death:",
  "non-undead orc death:",
}

local function split_bold_prefix(sentence)
  if type(sentence) ~= "string" then return nil, nil end
  local trimmed = trim_text(sentence)
  local lower = string.lower(trimmed)
  for _, prefix in ipairs(BOLD_TRIGGER_PREFIXES) do
    if lower:sub(1, #prefix) == prefix then
      local rest = trim_text(trimmed:sub(#prefix + 1))
      local display_prefix = trimmed:sub(1, #prefix)
      return display_prefix, rest
    end
    -- Support cards that format trigger headers as "On attack - ..."
    -- instead of "On attack: ...".
    if prefix:sub(-1) == ":" then
      local base = prefix:sub(1, -2)
      local dash_prefix = base .. " -"
      if lower:sub(1, #dash_prefix) == dash_prefix then
        local rest = trim_text(trimmed:sub(#dash_prefix + 1))
        local display_prefix = trimmed:sub(1, #dash_prefix)
        return display_prefix, rest
      end
    end
  end
  return nil, nil
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
        local bold_prefix, body = split_bold_prefix(clean)
        if bold_prefix then
          flush_normal_parts()
          segments[#segments + 1] = {
            text = body,
            bold = false,
            prefix_bold = bold_prefix,
          }
        else
          normal_parts[#normal_parts + 1] = clean
        end
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
    if seg.prefix_bold then
      if draw_y > max_y then
        return
      end

      local prefix = seg.prefix_bold
      local body = trim_text(seg.text or "")
      local full_text = prefix .. ((body ~= "") and (" " .. body) or "")
      local _, lines = font:getWrap(full_text, max_w)
      if #lines == 0 then
        lines = { full_text }
      end
      local seg_start_y = draw_y

      love.graphics.setFont(font)
      love.graphics.setColor(text_color[1], text_color[2], text_color[3], 0.9)
      for _, line in ipairs(lines) do
        if draw_y > max_y then
          return
        end
        love.graphics.print(line, x, draw_y)
        draw_y = draw_y + line_h
      end

      -- Re-draw prefix for bold emphasis while preserving natural wrapping.
      if seg_start_y <= max_y then
        love.graphics.print(prefix, x, seg_start_y)
        love.graphics.print(prefix, x + 0.7, seg_start_y)
      end
    else
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
-- Standard full-card height (fixed TCG-style aspect ratio).
-- Use this before drawing to determine the `h` param for enlarged/full views.
---------------------------------------------------------
local function measure_full_height(params)
  local w = (params and params.w) or CARD_W
  -- Full-card views should stay at a standard TCG-like aspect ratio.
  local standard_h = math.floor(w * FULL_CARD_ASPECT_H_OVER_W + 0.5)
  return math.max(CARD_H, standard_h)
end

card_frame.measure_full_height = measure_full_height
card_frame.FULL_CARD_ASPECT_H_OVER_W = FULL_CARD_ASPECT_H_OVER_W
card_frame.full_height_for_width = function(w)
  return measure_full_height({ w = w })
end

---------------------------------------------------------
-- Main card draw
-- params: title, faction, kind, typeLine, text, costs,
--         population, tier, is_base,
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
  local subtypes = params.subtypes
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
  set_local_scissor(x, y, w, h)
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

  -- ===================== TYPE LINE + TIER BADGE =====================
  local display_type_line
  local tier_badge_label = nil
  if subtypes ~= nil then
    -- New format: [T{tier} badge] {faction} - {subtype(s)/kind}
    local parts = {}
    if tier then
      tier_badge_label = "T" .. tostring(tier)
    end
    parts[#parts + 1] = faction
    if #subtypes > 0 then
      parts[#parts + 1] = table.concat(subtypes, "/")
    else
      parts[#parts + 1] = kind
    end
    display_type_line = table.concat(parts, " - ")
  else
    display_type_line = type_line
  end

  local type_font = util.get_font(9)
  local type_x = cx + 2
  local type_w = header_w - 4

  if tier_badge_label then
    local badge_font = util.get_font(8)
    local badge_text_w = badge_font:getWidth(tier_badge_label)
    local badge_w = badge_text_w + 10
    local badge_h = 12
    local badge_x = cx + 1
    local badge_y = cy

    -- Badge shadow
    love.graphics.setColor(0, 0, 0, 0.2)
    love.graphics.rectangle("fill", badge_x + 1, badge_y + 1, badge_w, badge_h, 3, 3)
    -- Badge body
    love.graphics.setColor(0.08, 0.1, 0.15, 0.95)
    love.graphics.rectangle("fill", badge_x, badge_y, badge_w, badge_h, 3, 3)
    -- Faction-tinted fill + border
    love.graphics.setColor(strip_color[1], strip_color[2], strip_color[3], 0.22)
    love.graphics.rectangle("fill", badge_x, badge_y, badge_w, badge_h, 3, 3)
    love.graphics.setColor(strip_color[1], strip_color[2], strip_color[3], 0.8)
    love.graphics.rectangle("line", badge_x, badge_y, badge_w, badge_h, 3, 3)
    -- Top highlight
    love.graphics.setColor(1, 1, 1, 0.08)
    love.graphics.rectangle("fill", badge_x + 1, badge_y + 1, badge_w - 2, 1, 2, 2)
    -- Badge text
    love.graphics.setFont(badge_font)
    love.graphics.setColor(0.96, 0.97, 1.0, 1.0)
    love.graphics.printf(tier_badge_label, badge_x, badge_y + 2, badge_w, "center")

    type_x = badge_x + badge_w + 5
    type_w = math.max(10, (cx + header_w) - type_x - 1)
  end

  love.graphics.setColor(muted)
  love.graphics.setFont(type_font)
  set_local_scissor(type_x, cy, type_w, type_font:getHeight() + 1)
  love.graphics.print(display_type_line, type_x, cy)
  love.graphics.setScissor()

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
  -- For base cards the art shrinks based on h; regular cards always use full 62px.
  local art_h = is_base and math.min(62, h - 130) or 62
  local art_w = header_w
  local art_y = cy
  -- Art background
  love.graphics.setColor(art_bg)
  love.graphics.rectangle("fill", cx, art_y, art_w, art_h, 4, 4)
  -- Art content (with scissor to clip to art box)
  set_local_scissor(cx, art_y, art_w, art_h)
  card_art.draw_card_art(cx, art_y, art_w, art_h, kind, is_base, title or faction)
  love.graphics.setScissor()  -- Clear scissor immediately after art
  -- Inner shadow on art box
  textures.draw_inner_shadow(cx, art_y, art_w, art_h, 3, 0.25)
  -- Art border
  love.graphics.setColor(0.15, 0.16, 0.2, 1)
  love.graphics.rectangle("line", cx, art_y, art_w, art_h, 4, 4)

  -- Overlay ATK/HP badges in the bottom corners for full-card previews.
  if attack ~= nil or health ~= nil then
    local stat_font = util.get_font(9)
    local badge_w = 52
    local badge_h = 20
    local corner_inset = 6
    local badge_y = y + h - badge_h - corner_inset
    local function draw_stat_badge(label, value, bx, bw, fill_rgb, border_rgb)
      love.graphics.setColor(0, 0, 0, 0.35)
      love.graphics.rectangle("fill", bx + 1, badge_y + 1, bw, badge_h, 5, 5)
      love.graphics.setColor(fill_rgb[1], fill_rgb[2], fill_rgb[3], 0.92)
      love.graphics.rectangle("fill", bx, badge_y, bw, badge_h, 5, 5)
      love.graphics.setColor(border_rgb[1], border_rgb[2], border_rgb[3], 0.95)
      love.graphics.rectangle("line", bx, badge_y, bw, badge_h, 5, 5)
      love.graphics.setFont(stat_font)
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.printf(label .. " " .. tostring(value), bx, badge_y + math.floor((badge_h - stat_font:getHeight()) / 2), bw, "center")
    end

    if attack ~= nil then
      draw_stat_badge("ATK", attack, x + corner_inset, badge_w, { 0.38, 0.14, 0.10 }, { 0.95, 0.45, 0.28 })
    end
    if health ~= nil then
      draw_stat_badge("HP", health, x + w - badge_w - corner_inset, badge_w, { 0.10, 0.28, 0.18 }, { 0.45, 0.95, 0.55 })
    end
  end

  cy = art_y + art_h + 4

  -- ===================== DIVIDER =====================
  love.graphics.setColor(strip_color[1], strip_color[2], strip_color[3], 0.25)
  love.graphics.rectangle("fill", cx + 4, cy - 2, art_w - 8, 1)

  -- ===================== ABILITIES / TEXT AREA =====================
  -- Calculate how much vertical space we have
  local text_area_bottom = y + h - pad - 2
  local text_area_h = math.max(1, text_area_bottom - cy)  -- Ensure positive height

  -- Note: Scissor clipping disabled for scaled cards (hand) as it uses screen coords
  -- Content will render without clipping - text overflow is handled by printf width limit

  -- Draw standardized ability lines (new system)
  local ab_y = cy
  local has_activated_abilities = false
  local ability_bottom_limit = y + h - pad - 22
  
  if abilities_list and #abilities_list > 0 then
    for ai, ab in ipairs(abilities_list) do
      if ab.type == "activated" then
        local consumed_est = measure_ability_line_height(ab, art_w, show_ability_text)
        if (ab_y + consumed_est - 3) > ability_bottom_limit then
          break
        end
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
    local consumed_est = measure_ability_line_height(activated_ability, art_w, show_ability_text)
    has_activated_abilities = true
    local is_used = ability_used_this_turn and activated_ability.once_per_turn
    local can_act = ability_can_activate and not is_used
    if (ab_y + consumed_est - 3) <= ability_bottom_limit then
      local consumed = draw_ability_line(activated_ability, cx, ab_y, art_w, {
        can_activate = can_act,
        is_used = is_used,
        show_ability_text = show_ability_text,
      })
      ab_y = ab_y + consumed
    end
  end

  -- Show rules text under ability lines without duplicating activated ability effect text.
  local display_text = text
  if has_activated_abilities then
    display_text = non_activated_text(abilities_list) or non_activated_text(activated_ability and { activated_ability } or nil)
  end
  if display_text and display_text ~= "" then
    local text_y = has_activated_abilities and (ab_y + 2) or (cy + 1)
    -- Ensure text doesn't overflow card bottom
    local max_text_y = y + h - pad - 20
    if text_y < max_text_y then
      draw_rules_text_with_keyword_emphasis(display_text, cx + 2, text_y, art_w - 4, max_text_y, text_color)
    end
  end

  -- Always clear scissor at end of text area
  love.graphics.setScissor()

  -- Counter display
  local counters = params.counters
  if type(counters) == "table" then
    local counter_colors = {
      growth    = { bg = {0.15, 0.35, 0.12}, border = {0.45, 0.75, 0.35}, text = {0.85, 1.0, 0.8} },
      knowledge = { bg = {0.12, 0.18, 0.35}, border = {0.35, 0.50, 0.85}, text = {0.8, 0.88, 1.0} },
      wonder    = { bg = {0.35, 0.25, 0.12}, border = {0.85, 0.65, 0.25}, text = {1.0, 0.95, 0.75} },
      honor     = { bg = {0.30, 0.12, 0.12}, border = {0.75, 0.35, 0.35}, text = {1.0, 0.85, 0.85} },
    }
    local default_color = { bg = {0.2, 0.2, 0.25}, border = {0.5, 0.5, 0.6}, text = {0.9, 0.9, 0.95} }
    local cfont = util.get_font(9)
    local counter_y = y + h - pad - 2
    for name, count in pairs(counters) do
      local colors = counter_colors[name] or default_color
      local label = tostring(count) .. " " .. name:sub(1, 1):upper() .. name:sub(2)
      local cw = math.min(art_w, cfont:getWidth(label) + 10)
      local ch = 14
      love.graphics.setColor(colors.bg[1], colors.bg[2], colors.bg[3], 0.92)
      love.graphics.rectangle("fill", cx, counter_y, cw, ch, 3, 3)
      love.graphics.setColor(colors.border[1], colors.border[2], colors.border[3], 0.9)
      love.graphics.rectangle("line", cx, counter_y, cw, ch, 3, 3)
      love.graphics.setColor(colors.text[1], colors.text[2], colors.text[3], 1.0)
      love.graphics.setFont(cfont)
      love.graphics.printf(label, cx, counter_y + 2, cw, "center")
      counter_y = counter_y + ch + 2
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
  local art_h = 62 + 4  -- regular cards always use 62px art
  local ab_y = card_y + pad + header_h + type_h + art_h
  local ab_w = card_w - pad * 2
  local line_h = 29  -- ability line height (26) + gap (3); variable-height buttons tracked below

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
