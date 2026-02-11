# Tier 1 Juice Implementation Plan — Battles of Masadoria

## Why This Matters

Right now every action in the game is instant and silent. You click "build" and a tile just *appears*. Resources change with no fanfare. Turns swap with a text banner. Balatro-level polish means every single interaction has feedback — things move, bounce, flash, and make sounds. These five systems are the foundation everything else builds on.

---

## System 1: Tween Engine (`src/fx/tween.lua`)

### What It Does
Smoothly animates numeric properties on any Lua table over time. Instead of `tile.scale = 1` happening instantly, you write `tween.to(tile, 0.25, {scale = 1})` and it interpolates from the current value to the target over 0.25 seconds with easing.

### API

```lua
local tween = require("src.fx.tween")

-- Basic: animate obj.x from current value to 200 over 0.5s
tween.to(obj, 0.5, { x = 200 })

-- With easing and callback
tween.to(obj, 0.3, { scale = 1.0 })
  :ease("backout")
  :oncomplete(function() print("done!") end)

-- Must call every frame
tween.update(dt)

-- Clear all active tweens (for screen transitions)
tween.reset()
```

### Internal Design

**Data structure per tween:**
```lua
{
  obj = <reference to table being tweened>,
  duration = 0.3,
  elapsed = 0,
  targets = { scale = 1.0 },         -- what we're animating toward
  starts = { scale = 0.0 },          -- captured on first tick
  easing = "linear",                  -- easing function name
  on_complete = nil,                  -- callback function or nil
  started = false,                    -- becomes true after first update
}
```

**Update loop (`tween.update(dt)`):**
1. Iterate all active tweens in reverse order (so removal is safe)
2. For each tween:
   - If `not started`: capture current values from `obj` into `starts`, set `started = true`
   - Advance `elapsed` by `dt`
   - Calculate `progress = clamp(elapsed / duration, 0, 1)`
   - Apply easing function to get `eased_progress`
   - For each key in `targets`: `obj[key] = starts[key] + (targets[key] - starts[key]) * eased_progress`
   - If `elapsed >= duration`: remove tween, fire `on_complete` callback

**Easing functions (5 needed):**

| Name | Formula | Feel |
|------|---------|------|
| `linear` | `t` | Constant speed |
| `quadout` | `1 - (1-t)^2` | Smooth deceleration |
| `cubicout` | `1 - (1-t)^3` | Snappier deceleration |
| `backout` | `1 + 2.7 * (t-1)^3 + 1.7 * (t-1)^2` | Overshoots then settles — great for "pop in" |
| `elasticout` | `2^(-10*t) * sin((t-0.075)*2*pi/0.3) + 1` | Springy bounce — use sparingly |

### Where It's Used
- Structure tile scales from 0 to 1 with `backout` easing when built (0.25s)
- Resource badge numbers tick smoothly when changing (display value tweens to actual value)
- Flash overlay alpha tweens from 0.6 to 0 on build (white flash that fades)
- Future: card slide-in, hand fan animations, damage shake on units

### Implementation Steps
1. Create `love2d/src/fx/` directory
2. Write `tween.lua` with:
   - Module-level `_tweens = {}` array
   - `tween.to(obj, duration, targets)` — creates tween, returns handle with `:ease()` and `:oncomplete()` chainable methods
   - `tween.update(dt)` — iterates and advances all tweens
   - `tween.reset()` — clears the array
   - Local `_easings` table mapping names to functions
3. ~120 lines total

---

## System 2: Floating Text Popups (`src/fx/popup.lua`)

### What It Does
Creates text that floats upward and fades out. When you spend 3 Food, a red "-3F" rises from the resource badge. When you build, a green "Built!" rises from the tile. This is the single most impactful juice system — it makes every action feel *real*.

### API

```lua
local popup = require("src.fx.popup")

-- Create a popup at world coordinates
popup.create("+1 Worker", x, y, {0.3, 0.9, 0.4})  -- green
popup.create("-3F", x, y, {1.0, 0.4, 0.3})          -- red/orange
popup.create("Built!", x, y, {0.4, 0.9, 1.0})       -- cyan

-- Call every frame
popup.update(dt)
popup.draw()
```

### Internal Design

**Data structure per popup:**
```lua
{
  text = "-3F",
  x = 400,                -- current x (may have slight random offset)
  y = 200,                -- current y (rises over time)
  color = {1, 0.4, 0.3},  -- RGB, alpha calculated from lifetime
  lifetime = 1.2,          -- seconds remaining
  max_lifetime = 1.2,      -- original duration (for progress calc)
  vy = -45,                -- vertical velocity (negative = upward)
  scale = 1.0,             -- current scale (starts at 1.2, settles to 1.0)
  font_size = 14,          -- configurable per popup
}
```

**Update loop (`popup.update(dt)`):**
1. Iterate in reverse for safe removal
2. For each popup:
   - `lifetime -= dt`
   - `y += vy * dt`
   - `vy *= 0.97` (slight deceleration so it doesn't fly away)
   - `scale` approaches 1.0 (if started larger, shrinks gently)
   - If `lifetime <= 0`: remove from array

**Draw (`popup.draw()`):**
1. For each popup:
   - Calculate `progress = lifetime / max_lifetime` (1.0 = just spawned, 0.0 = gone)
   - `alpha = 1.0` if progress > 0.3, else `progress / 0.3` (fade in last 30%)
   - Set color with alpha
   - Draw text centered at (x, y) with current scale using `love.graphics.push/scale/pop`
   - Use `util.get_font(popup.font_size)`
   - Optional: draw a subtle dark shadow behind text for readability (+1, +1 offset, black, alpha*0.5)

### Color Scheme

| Context | Color | Example |
|---------|-------|---------|
| Resource gain | Green `{0.3, 0.9, 0.4}` | "+2 Food", "+1 Worker" |
| Resource spent | Orange-red `{1.0, 0.5, 0.25}` | "-3F", "-2W 1S" |
| Positive event | Cyan `{0.4, 0.9, 1.0}` | "Built!" |
| Error/fail | Red `{1.0, 0.3, 0.3}` | "Can't afford" |
| Neutral | White `{0.9, 0.9, 0.95}` | Turn info |

### Spawn Positions
- **Resource cost popups**: Spawn at the resource badge positions in the panel header (the F:, W:, S: pills). Calculate from `board.panel_rect()` + badge offset.
- **"Built!" popup**: Spawn at the center of the newly placed structure tile in the structures area.
- **"+1 Worker" popup**: Spawn at the base card (since base ability summons workers).
- **Turn change**: Spawn at screen center.

### Implementation Steps
1. Write `popup.lua` with:
   - Module-level `_popups = {}` array
   - `popup.create(text, x, y, color, opts)` — opts allows overriding font_size, lifetime, vy
   - `popup.update(dt)` — advance and cull
   - `popup.draw()` — render all active popups
2. ~80 lines total

---

## System 3: Screen Shake (`src/fx/shake.lua`)

### What It Does
Briefly jolts the entire game view when something impactful happens (building, combat later). A subtle 3-pixel shake for 0.12 seconds makes building feel like you're placing something heavy. The camera oscillates rapidly and decays to zero.

### API

```lua
local shake = require("src.fx.shake")

-- Trigger a shake
shake.trigger(magnitude, duration)
-- e.g. shake.trigger(3, 0.12)  -- light thud
-- e.g. shake.trigger(6, 0.2)   -- heavy impact (for combat later)

-- Call every frame
shake.update(dt)

-- In draw, wrap your game content:
shake.apply()      -- love.graphics.push() + translate by offset
  -- draw game here
shake.release()    -- love.graphics.pop()
```

### Internal Design

**Module state:**
```lua
local _timer = 0          -- time remaining
local _duration = 0        -- total duration (for decay calc)
local _magnitude = 0       -- max pixel offset
local _offset_x = 0        -- current computed offset
local _offset_y = 0        -- current computed offset
```

**`shake.trigger(mag, dur)`:**
- Sets `_magnitude = mag`, `_duration = dur`, `_timer = dur`
- If a shake is already active, take the stronger magnitude (don't stack)

**`shake.update(dt)`:**
```
if _timer > 0 then
  _timer = _timer - dt
  if _timer <= 0 then
    _timer = 0
    _offset_x = 0
    _offset_y = 0
  else
    local progress = 1 - (_timer / _duration)
    local decay = 1 - progress  -- strongest at start, zero at end
    _offset_x = math.sin(_timer * 30) * _magnitude * decay
    _offset_y = math.cos(_timer * 23) * _magnitude * decay * 0.8
    -- Different frequencies on X vs Y makes it feel natural, not robotic
    -- Y is 0.8x magnitude because horizontal shake feels more natural
  end
end
```

**`shake.apply()` / `shake.release()`:**
```lua
function shake.apply()
  love.graphics.push()
  love.graphics.translate(_offset_x, _offset_y)
end

function shake.release()
  love.graphics.pop()
end
```

### Important: What Goes Inside vs Outside Shake
- **Inside shake** (between apply/release): Board, cards, structures, resources, blueprint modal — the "game world"
- **Outside shake** (after release): Floating popups, turn banner, tooltips, status bar — "HUD layer"

This prevents popups from jittering, which would look broken.

### Implementation Steps
1. Write `shake.lua` with the four functions
2. ~40 lines total

---

## System 4: Procedural Sound Effects (`src/fx/sound.lua`)

### What It Does
Generates all sound effects programmatically at load time — no audio files needed. Uses LÖVE's `love.sound.newSoundData` to create waveforms from sine waves and noise. This means the game has sound immediately.

### API

```lua
local sound = require("src.fx.sound")

sound.play("build")           -- play at full volume
sound.play("click", 0.5)      -- play at 50% volume
sound.play("coin")
```

### Sound Definitions

Each sound is defined by parameters that generate a waveform:

**1. `click` — UI interaction**
- Waveform: sine at 1200Hz
- Duration: 0.04s
- Envelope: instant attack, fast linear decay
- Character: sharp, tiny tick

**2. `build` — Structure placed**
- Waveform: sine at 180Hz + harmonic at 360Hz (half amplitude)
- Duration: 0.18s
- Envelope: instant attack, exponential decay (`e^(-t*15)`)
- Character: satisfying low thunk with body

**3. `error` — Invalid action**
- Waveform: sine at 150Hz + detuned sine at 183Hz (creates beating/dissonance)
- Duration: 0.12s
- Envelope: linear decay
- Character: buzzy, unpleasant (intentionally)

**4. `coin` — Resource gained**
- Waveform: sine with ascending frequency sweep (600Hz → 1200Hz)
- Duration: 0.1s
- Envelope: instant attack, linear decay
- Character: bright, sparkly ascending tone

**5. `spend` — Resource spent**
- Waveform: sine with descending frequency sweep (800Hz → 400Hz)
- Duration: 0.08s
- Envelope: linear decay
- Character: soft descending tone

**6. `whoosh` — Turn change**
- Waveform: filtered white noise (random samples, smoothed)
- Duration: 0.2s
- Envelope: attack over 0.03s, decay over remaining
- Character: breathy swoosh

**7. `pop` — Worker pickup/drop**
- Waveform: sine at 500Hz
- Duration: 0.03s
- Envelope: instant attack, instant decay
- Character: quick, clicky pop

### Internal Design

**Generator function:**
```lua
local SAMPLE_RATE = 44100

local function generate_sound(duration, generator_fn)
  local samples = math.floor(SAMPLE_RATE * duration)
  local data = love.sound.newSoundData(samples, SAMPLE_RATE, 16, 1)
  for i = 0, samples - 1 do
    local t = i / SAMPLE_RATE  -- time in seconds
    local progress = i / samples  -- 0 to 1
    local sample = generator_fn(t, progress)
    data:setSample(i, clamp(sample, -1, 1))
  end
  return data
end
```

**Each sound type has its own generator:**
```lua
-- Example: build sound
sounds.build = generate_sound(0.18, function(t, progress)
  local envelope = math.exp(-t * 15)
  local wave = math.sin(2 * math.pi * 180 * t)
             + 0.5 * math.sin(2 * math.pi * 360 * t)
  return wave * envelope * 0.3
end)
```

**Playback with overlapping support:**
Each sound has a small pool (4 sources). On `play()`, find the first non-playing source and use it. If all are playing, reuse the oldest. This prevents sounds from cutting each other off.

```lua
local _pools = {}  -- name -> { Source, Source, Source, Source }
local _pool_index = {}  -- name -> next index (round-robin)

function sound.play(name, volume)
  local pool = _pools[name]
  if not pool then return end
  local idx = _pool_index[name]
  local source = pool[idx]
  source:stop()
  source:setVolume(volume or 1.0)
  source:play()
  _pool_index[name] = (idx % #pool) + 1
end
```

### Implementation Steps
1. Write `sound.lua` with:
   - `generate_sound(duration, fn)` helper
   - Generator functions for each of the 7 sounds
   - `_init()` called on require: generates all SoundData, creates source pools
   - `sound.play(name, volume)` — round-robin from pool
2. ~120 lines total

---

## System 5: Structure Hover Tooltip

### What It Does
When the player hovers their mouse over a built structure tile on the board, a full card preview appears near the cursor. This lets players read the structure's abilities without opening the blueprint modal.

### Design
- Rendered in `game.lua:draw()` AFTER popups, so it's always on top
- Uses existing `card_frame.draw()` with the structure's card definition
- Positioned to the right of the cursor by default, flipped to left if near right edge
- Positioned below cursor, flipped above if near bottom edge
- Slight dark background pill behind the card for contrast
- Only shows when `hover.kind == "structure"` and modal is not open

### Implementation in `src/state/game.lua`

In the `draw()` function, after popups and before turn banner:
```lua
-- Structure tooltip
if self.hover and self.hover.kind == "structure" and not self.show_blueprint_for_player then
  local pi = self.hover.pi
  local si = self.hover.idx
  local player = self.game_state.players[pi + 1]
  local entry = player.board[si]
  if entry then
    local def = cards.get_card_def(entry.card_id)
    local mx, my = love.mouse.getPosition()
    local gw, gh = love.graphics.getDimensions()
    local tw, th = card_frame.CARD_W, card_frame.CARD_H
    -- Position: right of cursor, or left if near edge
    local tx = mx + 16
    local ty = my - th / 2
    if tx + tw > gw - 10 then tx = mx - tw - 16 end
    if ty < 10 then ty = 10 end
    if ty + th > gh - 10 then ty = gh - th - 10 end
    -- Dark backdrop
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", tx - 4, ty - 4, tw + 8, th + 8, 8, 8)
    -- Draw card
    card_frame.draw(tx, ty, {
      title = def.name,
      faction = def.faction,
      kind = def.kind,
      typeLine = def.faction .. " — " .. def.kind,
      text = def.text,
      costs = def.costs,
      population = def.population,
    })
  end
end
```

### Implementation Steps
1. Add `local cards = require("src.game.cards")` and `local card_frame = require("src.ui.card_frame")` to game.lua requires
2. Add tooltip drawing block in `draw()` after popup draw, before turn banner
3. ~25 lines added to game.lua

---

## Integration: Modifying `src/state/game.lua`

This is the main file that ties everything together. Here are all the changes:

### New requires (top of file)
```lua
local tween = require("src.fx.tween")
local popup = require("src.fx.popup")
local shake = require("src.fx.shake")
local sound = require("src.fx.sound")
local cards = require("src.game.cards")
local card_frame = require("src.ui.card_frame")
```

### `GameState:update(dt)` — add FX updates
```lua
function GameState:update(dt)
  tween.update(dt)
  popup.update(dt)
  shake.update(dt)
  -- existing turn_banner_timer code unchanged
end
```

### `GameState:draw()` — restructured draw order

**New draw order:**
1. `shake.apply()` — push transform
2. `board.draw(...)` — game world (existing)
3. Dragged worker (existing)
4. Blueprint modal if open (existing)
5. `shake.release()` — pop transform
6. `popup.draw()` — floating text (on top, no shake)
7. Structure tooltip (if hovering)
8. Status bar / hints (existing, moved outside shake)
9. Turn banner (existing)

### `GameState:mousepressed()` — add FX triggers

**Blueprint modal build:**
```lua
-- Current:
if card_id then
  local built = actions.build_structure(self.game_state, self.show_blueprint_for_player, card_id)
  if built then
    self.show_blueprint_for_player = nil
    return
  end
end

-- New:
if card_id then
  local built = actions.build_structure(self.game_state, self.show_blueprint_for_player, card_id)
  if built then
    sound.play("build")
    shake.trigger(3, 0.12)
    -- Cost popup (spawn at resource area)
    local def = cards.get_card_def(card_id)
    local px, py, pw, ph = board.panel_rect(self.show_blueprint_for_player)
    local cost_str = ""
    for _, c in ipairs(def.costs) do
      local letter = (c.type == "food") and "F" or (c.type == "wood") and "W" or (c.type == "stone") and "S" or "?"
      cost_str = cost_str .. "-" .. c.amount .. letter .. " "
    end
    popup.create(cost_str, px + pw * 0.5, py + 8, {1.0, 0.5, 0.25})
    -- "Built!" popup at structures area
    local sax, say = board.structures_area_rect(px, py, pw, ph)
    local tile_count = #self.game_state.players[self.show_blueprint_for_player + 1].board
    popup.create("Built!", sax + (tile_count - 1) * 98 + 45, say + 20, {0.4, 0.9, 1.0})
    self.show_blueprint_for_player = nil
    return
  else
    sound.play("error")
  end
end
```

**End turn:**
```lua
if kind == "end_turn" then
  sound.play("whoosh")
  -- existing end_turn + start_turn code
end
```

**Activate base ability:**
```lua
if kind == "activate_base" and pi == self.game_state.activePlayer then
  local before_workers = self.game_state.players[pi + 1].totalWorkers
  actions.activate_base_ability(self.game_state, pi)
  local after_workers = self.game_state.players[pi + 1].totalWorkers
  if after_workers > before_workers then
    sound.play("coin")
    local px, py, pw, ph = board.panel_rect(pi)
    popup.create("+1 Worker", px + pw/2, py + ph - 80, {0.3, 0.9, 0.4})
    popup.create("-3F", px + pw * 0.35, py + 8, {1.0, 0.5, 0.25})
  end
  return
end
```

**Open blueprint modal:**
```lua
if kind == "blueprint" then
  sound.play("click")
  self.show_blueprint_for_player = pi
  return
end
```

**Worker pickup:**
```lua
if kind == "worker_unassigned" or kind == "worker_left" or kind == "worker_right" then
  sound.play("pop")
  -- existing drag code
end
```

### `GameState:mousereleased()` — worker drop sound
```lua
-- After successful worker drop (resource assigned):
sound.play("pop")
```

---

## File-by-File Summary

| File | Action | Description |
|------|--------|-------------|
| `src/fx/tween.lua` | **CREATE** | Tween engine: `to()`, `update()`, `reset()`, 5 easings |
| `src/fx/popup.lua` | **CREATE** | Floating text: `create()`, `update()`, `draw()` |
| `src/fx/shake.lua` | **CREATE** | Screen shake: `trigger()`, `update()`, `apply()`, `release()` |
| `src/fx/sound.lua` | **CREATE** | Procedural SFX: 7 generated sounds, `play()` with source pooling |
| `src/state/game.lua` | **MODIFY** | Wire all 4 FX systems into update/draw/input |

**Total new code: ~360 lines across 4 new files + ~80 lines of changes to game.lua**

---

## Testing Checklist

After implementation, run `love .` from the `love2d` folder and verify:

### Sound
- [ ] Click blueprint deck slot → hear click
- [ ] Build a structure → hear build thunk
- [ ] End turn → hear whoosh
- [ ] Click unbuildable card in modal → hear error buzz
- [ ] Activate base ability → hear coin
- [ ] Pick up worker → hear pop
- [ ] Drop worker on resource → hear pop

### Floating Popups
- [ ] Build a structure → orange cost text floats up from header area (e.g. "-2W 1S")
- [ ] Build a structure → cyan "Built!" floats up from the structure tile
- [ ] Activate base ability → green "+1 Worker" floats up, orange "-3F" floats up
- [ ] Popups rise smoothly, fade out over ~1 second
- [ ] Multiple popups don't overlap badly (slight random X offset)

### Screen Shake
- [ ] Build a structure → screen briefly shakes (subtle, ~3px, ~0.12s)
- [ ] Shake decays smoothly to zero (no sudden stop)
- [ ] Popups and turn banner do NOT shake (rendered outside transform)
- [ ] Status bar does NOT shake

### Tooltips
- [ ] Hover over a built structure tile → full card preview appears near cursor
- [ ] Card preview shows correct structure info (name, costs, ability text)
- [ ] Preview doesn't go off-screen (clamped to window bounds)
- [ ] Moving mouse away from tile → preview disappears immediately
- [ ] Preview doesn't show when blueprint modal is open

### Tweens
- [ ] Build a structure → new tile animates in (scale 0→1 with bounce)
- [ ] Animation feels snappy (~0.25s)
- [ ] No visual glitches if multiple structures built rapidly

### No Regressions
- [ ] Worker drag-and-drop works exactly as before
- [ ] Blueprint modal opens/closes correctly
- [ ] Turn cycling works
- [ ] Resource production works
- [ ] All existing hover hints still appear
- [ ] Game doesn't crash on any action
