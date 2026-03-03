-- Worker sprite loading, animation, and rendering.
-- Extracted from board.lua for modularity.

local worker_sprite = {}

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local WORKER_SPRITE_SIZE_MULT = 7
local HOVER_SCALE_BOOST = 1.08  -- subtle scale-up when hovered
local DRAG_SCALE_BOOST  = 1.15  -- slightly larger when being dragged

---------------------------------------------------------------------------
-- Internal state
---------------------------------------------------------------------------
local sprite_cache = {
  initialized = false,
  by_faction = {},
  fallback = {},
}

local anim_slot_state = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function dedupe_paths(paths)
  local out = {}
  local seen = {}
  for _, path in ipairs(paths or {}) do
    if type(path) == "string" and path ~= "" and not seen[path] then
      out[#out + 1] = path
      seen[path] = true
    end
  end
  return out
end

local function load_image(path)
  local ok, img = pcall(love.graphics.newImage, path)
  if ok and img then
    img:setFilter("nearest", "nearest")
    return img
  end
  return nil
end

local function build_anim_from_image(img, fps)
  if not img then return nil end
  local iw, ih = img:getWidth(), img:getHeight()
  if iw <= 0 or ih <= 0 then return nil end

  local frame_w, frame_h = iw, ih
  local frame_count = 1
  local vertical_strip = false

  local h_ratio = iw / ih
  local rounded_h = math.floor(h_ratio + 0.5)
  if h_ratio >= 1.9 and math.abs(h_ratio - rounded_h) < 0.08 then
    frame_count = math.max(1, rounded_h)
    frame_w = math.floor(iw / frame_count)
    frame_h = ih
  else
    local v_ratio = ih / iw
    local rounded_v = math.floor(v_ratio + 0.5)
    if v_ratio >= 1.9 and math.abs(v_ratio - rounded_v) < 0.08 then
      frame_count = math.max(1, rounded_v)
      frame_w = iw
      frame_h = math.floor(ih / frame_count)
      vertical_strip = true
    end
  end

  -- Guard: if frame dimensions ended up zero, bail out
  if frame_w <= 0 or frame_h <= 0 or frame_count < 1 then
    return nil
  end

  local quads = nil
  if frame_count > 1 then
    quads = {}
    for i = 1, frame_count do
      local qx = vertical_strip and 0 or (i - 1) * frame_w
      local qy = vertical_strip and (i - 1) * frame_h or 0
      quads[i] = love.graphics.newQuad(qx, qy, frame_w, frame_h, iw, ih)
    end
  end

  return {
    img = img,
    quads = quads,
    frame_w = frame_w,
    frame_h = frame_h,
    frame_count = frame_count,
    fps = fps or 8,
  }
end

local function load_first_anim(paths, fps)
  for _, path in ipairs(dedupe_paths(paths)) do
    local img = load_image(path)
    if img then
      local anim = build_anim_from_image(img, fps)
      if anim then
        anim.path = path
        return anim
      end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Pawn sprite sets
---------------------------------------------------------------------------
local function pawn_base_dir(color_name)
  return "assets/Tiny Swords (Free Pack)/Units/" .. color_name .. " Units/Pawn/"
end

local function load_pawn_anim_set(color_name)
  local base = pawn_base_dir(color_name)
  local set = {}
  set.idle = load_first_anim({
    base .. "Pawn_Idle.png",
    base .. "Pawn_Run.png",
  }, 7)
  set.harvest_wood = load_first_anim({
    base .. "Pawn_Interact Axe.png",
    base .. "Pawn_Idle Axe.png",
    base .. "Pawn_Run Axe.png",
    base .. "Pawn_Idle Wood.png",
    base .. "Pawn_Run Wood.png",
  }, 10)
  set.harvest_food = load_first_anim({
    base .. "Pawn_Interact Knife.png",
    base .. "Pawn_Idle Knife.png",
    base .. "Pawn_Run Knife.png",
    base .. "Pawn_Idle Meat.png",
    base .. "Pawn_Run Meat.png",
  }, 10)
  set.harvest_stone = load_first_anim({
    base .. "Pawn_Interact Pickaxe.png",
    base .. "Pawn_Idle Pickaxe.png",
    base .. "Pawn_Run Pickaxe.png",
  }, 10)
  set.work_structure = load_first_anim({
    base .. "Pawn_Interact Hammer.png",
    base .. "Pawn_Idle Hammer.png",
    base .. "Pawn_Run Hammer.png",
  }, 9)
  return set
end

local function with_set_fallbacks(primary, fallback)
  return {
    idle           = primary.idle or fallback.idle,
    harvest_wood   = primary.harvest_wood   or primary.idle or fallback.harvest_wood   or fallback.idle,
    harvest_food   = primary.harvest_food   or primary.idle or fallback.harvest_food   or fallback.idle,
    harvest_stone  = primary.harvest_stone  or primary.idle or fallback.harvest_stone  or fallback.idle,
    work_structure = primary.work_structure or primary.idle or fallback.work_structure or fallback.idle,
  }
end

---------------------------------------------------------------------------
-- Cache initialization  (lazy, called once on first draw)
---------------------------------------------------------------------------
local function init_cache()
  if sprite_cache.initialized then return end
  sprite_cache.initialized = true

  local fallback_idle = load_first_anim({
    "assets/worker_idle.png",
    "assets/worker.png",
    "assets/swordman.png",
  }, 7)
  local fallback_harvest = load_first_anim({
    "assets/worker_harvest.png",
    "assets/worker_gather.png",
    "assets/worker_mine.png",
    "assets/swordman.png",
  }, 9) or fallback_idle
  sprite_cache.fallback = {
    idle           = fallback_idle,
    harvest_wood   = fallback_harvest,
    harvest_food   = fallback_harvest,
    harvest_stone  = fallback_harvest,
    work_structure = fallback_harvest,
  }

  -- Human  -> Blue sprites
  local blue_set = with_set_fallbacks(load_pawn_anim_set("Blue"), sprite_cache.fallback)
  -- Orc    -> Red sprites
  local red_set  = with_set_fallbacks(load_pawn_anim_set("Red"),  sprite_cache.fallback)
  red_set.harvest_food = load_first_anim({
    pawn_base_dir("Red") .. "Pawn_Idle Meat.png",
    pawn_base_dir("Red") .. "Pawn_Run Meat.png",
  }, 7) or red_set.harvest_food
  -- Elf    -> Yellow sprites
  local yellow_set = with_set_fallbacks(load_pawn_anim_set("Yellow"), sprite_cache.fallback)
  -- Gnome  -> Purple sprites
  local purple_set = with_set_fallbacks(load_pawn_anim_set("Purple"), sprite_cache.fallback)
  -- Neutral -> Black sprites (fallback to Blue if missing)
  local black_set  = with_set_fallbacks(load_pawn_anim_set("Black"), sprite_cache.fallback)

  sprite_cache.by_faction.Human   = blue_set
  sprite_cache.by_faction.Orc     = red_set
  sprite_cache.by_faction.Elf     = yellow_set
  sprite_cache.by_faction.Gnome   = purple_set
  sprite_cache.by_faction.Neutral = black_set
  sprite_cache.by_faction.default = blue_set
end

---------------------------------------------------------------------------
-- Faction normalisation
---------------------------------------------------------------------------
local function normalize_faction(faction)
  if type(faction) ~= "string" then return "Human" end
  local low = string.lower(faction)
  if low == "orc"     then return "Orc"     end
  if low == "human"   then return "Human"   end
  if low == "elf"     then return "Elf"     end
  if low == "gnome"   then return "Gnome"   end
  if low == "neutral" then return "Neutral" end
  return "Human"
end

---------------------------------------------------------------------------
-- Animation selection
---------------------------------------------------------------------------
local function select_anim(opts)
  init_cache()
  local faction_key = normalize_faction(opts and opts.faction)
  local set = sprite_cache.by_faction[faction_key]
    or sprite_cache.by_faction.default
    or sprite_cache.fallback
  local task     = (opts and opts.task) or ((opts and opts.resource) and "harvest" or "idle")
  local resource = opts and opts.resource or nil
  if task == "harvest" then
    if resource == "wood"  then return set.harvest_wood  or set.idle end
    if resource == "food"  then return set.harvest_food  or set.idle end
    if resource == "stone" then return set.harvest_stone or set.idle end
    return set.harvest_wood or set.harvest_food or set.harvest_stone or set.idle
  end
  if task == "work" then
    return set.work_structure or set.idle
  end
  return set.idle
end

---------------------------------------------------------------------------
-- Phase / slot helpers
---------------------------------------------------------------------------
local function anim_phase(seed)
  local n = 0
  if type(seed) == "number" then
    n = seed
  elseif type(seed) == "string" then
    for i = 1, #seed do
      n = n * 131 + string.byte(seed, i)
    end
  end
  local x = math.sin(n * 12.9898 + 78.233) * 43758.5453
  return x - math.floor(x)
end

function worker_sprite.anim_started_at_for_slot(slot_key, signature, now)
  if type(slot_key) ~= "string" or slot_key == "" then
    return now
  end
  local entry = anim_slot_state[slot_key]
  if not entry or entry.signature ~= signature then
    anim_slot_state[slot_key] = {
      signature  = signature,
      started_at = now,
    }
    return now
  end
  return entry.started_at or now
end

---------------------------------------------------------------------------
-- Orb fallback (unchanged from original)
---------------------------------------------------------------------------
local function draw_orb_fallback(cx, cy, opts)
  local base_r = opts.radius or 12  -- WORKER_R default
  local r = base_r * (opts.scale or 1)
  local alpha = (opts.alpha ~= nil) and opts.alpha or (opts.active_panel and 1.0 or 0.7)
  local is_orc = normalize_faction(opts.faction) == "Orc"
  local orb_r, orb_g, orb_b = is_orc and 1.0 or 0.9, is_orc and 0.45 or 0.9, is_orc and 0.45 or 1.0

  love.graphics.setColor(0, 0, 0, 0.4 * alpha)
  love.graphics.circle("fill", cx + 2, cy + 3, r + 1)

  local layers = 4
  for i = layers, 1, -1 do
    local frac = i / layers
    local lr = r * frac
    local offx = -r * 0.15 * (1 - frac)
    local offy = -r * 0.2 * (1 - frac)
    local brightness = opts.active_panel and (0.55 + 0.45 * (1 - frac)) or (0.4 + 0.3 * (1 - frac))
    if opts.special then
      love.graphics.setColor(brightness * 1.1, brightness * 0.85, brightness * 0.3, alpha)
    else
      love.graphics.setColor(brightness * orb_r, brightness * orb_g, brightness * orb_b, alpha)
    end
    love.graphics.circle("fill", cx + offx, cy + offy, lr)
  end

  if opts.special then
    love.graphics.setColor(1, 1, 0.8, 0.4 * alpha)
  else
    love.graphics.setColor(1, 1, 1, 0.35 * alpha)
  end
  love.graphics.circle("fill", cx - r * 0.25, cy - r * 0.25, r * 0.3)

  if opts.special then
    love.graphics.setColor(opts.active_panel and 0.85 or 0.6, opts.active_panel and 0.65 or 0.5, opts.active_panel and 0.1 or 0.2, opts.active_panel and 0.9 or 0.6)
    love.graphics.setLineWidth(2)
    love.graphics.circle("line", cx, cy, r)
    love.graphics.setLineWidth(1)
  end
end

---------------------------------------------------------------------------
-- Main draw function
---------------------------------------------------------------------------
local function draw_sprite_token(cx, cy, opts)
  opts = opts or {}
  local anim = select_anim(opts)
  if not anim then
    draw_orb_fallback(cx, cy, opts)
    return
  end

  local base_r = opts.radius or 12  -- WORKER_R default
  local scale  = (opts.scale or 1)

  -- Hover / drag visual boost
  if opts.hovered and not opts.draggable then
    scale = scale * HOVER_SCALE_BOOST
  end
  if opts.draggable then
    scale = scale * DRAG_SCALE_BOOST
  end

  local draw_r = base_r * scale
  local alpha  = (opts.alpha ~= nil) and opts.alpha or (opts.active_panel and 1.0 or 0.7)

  -- Shadow ellipse
  love.graphics.setColor(0, 0, 0, 0.35 * alpha)
  love.graphics.ellipse("fill", cx + draw_r * 0.25, cy + draw_r * 0.56, draw_r * 0.9, draw_r * 0.4)

  -- Frame selection
  local frame_index = 1
  local fps = anim.fps or 8
  if anim.frame_count and anim.frame_count > 1 then
    local anim_time
    if type(opts.anim_started_at) == "number" then
      anim_time = math.max(0, love.timer.getTime() - opts.anim_started_at)
    else
      local seed = opts.anim_seed
      if seed == nil then
        seed = math.floor(cx) * 131 + math.floor(cy) * 137 + (opts.special and 17 or 0)
      end
      local phase = anim_phase(seed)
      local cycle = anim.frame_count / fps
      anim_time = love.timer.getTime() - phase * cycle
    end
    frame_index = (math.floor(anim_time * fps) % anim.frame_count) + 1
  end

  -- Tinting
  local tint_r, tint_g, tint_b = 1.0, 1.0, 1.0
  if opts.special then
    tint_r, tint_g, tint_b = 1.0, 0.92, 0.66
  end
  if not opts.active_panel then
    tint_r, tint_g, tint_b = tint_r * 0.86, tint_g * 0.86, tint_b * 0.86
  end

  -- Hover glow tint (slight warm brighten)
  if opts.hovered and opts.active_panel then
    tint_r = math.min(tint_r * 1.12, 1.0)
    tint_g = math.min(tint_g * 1.08, 1.0)
    tint_b = math.min(tint_b * 1.04, 1.0)
  end

  love.graphics.setColor(tint_r, tint_g, tint_b, alpha)

  -- Draw sprite
  local fw, fh = anim.frame_w, anim.frame_h
  local draw_scale_x = (draw_r * WORKER_SPRITE_SIZE_MULT) / fw
  local draw_scale_y = (draw_r * WORKER_SPRITE_SIZE_MULT) / fh
  local quad = anim.quads and anim.quads[frame_index] or nil
  if quad then
    love.graphics.draw(anim.img, quad, cx, cy, 0, draw_scale_x, draw_scale_y, fw / 2, fh / 2)
  else
    love.graphics.draw(anim.img, cx, cy, 0, draw_scale_x, draw_scale_y, fw / 2, fh / 2)
  end

  -- Hover outline glow
  if opts.hovered and opts.active_panel then
    love.graphics.setColor(1, 1, 0.85, 0.35 * alpha)
    love.graphics.setLineWidth(1.5)
    love.graphics.circle("line", cx, cy, draw_r * 0.95)
    love.graphics.setLineWidth(1)
  end

  -- Special worker gold ring
  if opts.special then
    love.graphics.setColor(0.88, 0.7, 0.2, 0.85 * alpha)
    love.graphics.setLineWidth(2)
    love.graphics.circle("line", cx, cy, draw_r)
    love.graphics.setLineWidth(1)
  end
end

---------------------------------------------------------------------------
-- Public API  (matches existing call signatures in board.lua)
---------------------------------------------------------------------------
function worker_sprite.draw_worker_circle(cx, cy, is_active_panel, is_draggable, is_hovered_worker, resource, faction, radius, alpha, scale, task, anim_seed, anim_started_at)
  draw_sprite_token(cx, cy, {
    special        = false,
    active_panel   = is_active_panel,
    draggable      = is_draggable,
    hovered        = is_hovered_worker,
    resource       = resource,
    faction        = faction,
    radius         = radius,
    alpha          = alpha,
    scale          = scale,
    task           = task,
    anim_seed      = anim_seed,
    anim_started_at = anim_started_at,
  })
end

function worker_sprite.draw_special_worker_circle(cx, cy, is_active_panel, is_draggable, is_hovered_worker, resource, faction, radius, alpha, scale, task, anim_seed, anim_started_at)
  draw_sprite_token(cx, cy, {
    special        = true,
    active_panel   = is_active_panel,
    draggable      = is_draggable,
    hovered        = is_hovered_worker,
    resource       = resource,
    faction        = faction,
    radius         = radius,
    alpha          = alpha,
    scale          = scale,
    task           = task,
    anim_seed      = anim_seed,
    anim_started_at = anim_started_at,
  })
end

function worker_sprite.draw_token(cx, cy, opts)
  opts = opts or {}
  if opts.special then
    worker_sprite.draw_special_worker_circle(
      cx, cy,
      opts.active_panel ~= false,
      opts.draggable == true,
      opts.hovered == true,
      opts.resource,
      opts.faction,
      opts.radius,
      opts.alpha,
      opts.scale,
      opts.task,
      opts.anim_seed,
      opts.anim_started_at
    )
  else
    worker_sprite.draw_worker_circle(
      cx, cy,
      opts.active_panel ~= false,
      opts.draggable == true,
      opts.hovered == true,
      opts.resource,
      opts.faction,
      opts.radius,
      opts.alpha,
      opts.scale,
      opts.task,
      opts.anim_seed,
      opts.anim_started_at
    )
  end
end

return worker_sprite
