-- Tween engine: smoothly animates numeric properties on any Lua table over time.

local tween = {}

local _tweens = {}

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local _easings = {
  linear = function(t) return t end,
  quadout = function(t) return 1 - (1 - t) * (1 - t) end,
  cubicout = function(t) return 1 - (1 - t) * (1 - t) * (1 - t) end,
  backout = function(t)
    return 1 + 2.7 * (t - 1) * (t - 1) * (t - 1) + 1.7 * (t - 1) * (t - 1)
  end,
  elasticout = function(t)
    if t <= 0 then return 0 end
    if t >= 1 then return 1 end
    return 2^(-10 * t) * math.sin((t - 0.075) * 2 * math.pi / 0.3) + 1
  end,
}

local function create_handle(entry)
  local handle = {}
  function handle:ease(name)
    entry.easing = name or "linear"
    return self
  end
  function handle:oncomplete(fn)
    entry.on_complete = fn
    return self
  end
  return handle
end

function tween.to(obj, duration, targets)
  local entry = {
    obj = obj,
    duration = duration,
    elapsed = 0,
    targets = targets,
    starts = {},
    easing = "linear",
    on_complete = nil,
    started = false,
  }
  _tweens[#_tweens + 1] = entry
  return create_handle(entry)
end

function tween.update(dt)
  for i = #_tweens, 1, -1 do
    local t = _tweens[i]
    if not t.started then
      for k, v in pairs(t.targets) do
        t.starts[k] = t.obj[k]
        if t.starts[k] == nil then t.starts[k] = 0 end
      end
      t.started = true
    end
    t.elapsed = t.elapsed + dt
    local progress = clamp(t.elapsed / t.duration, 0, 1)
    local easing_fn = _easings[t.easing] or _easings.linear
    local eased = easing_fn(progress)
    for k, target_val in pairs(t.targets) do
      local start_val = t.starts[k] or 0
      t.obj[k] = start_val + (target_val - start_val) * eased
    end
    if t.elapsed >= t.duration then
      for k, target_val in pairs(t.targets) do
        t.obj[k] = target_val
      end
      if t.on_complete then t.on_complete() end
      table.remove(_tweens, i)
    end
  end
end

function tween.reset()
  _tweens = {}
end

return tween
