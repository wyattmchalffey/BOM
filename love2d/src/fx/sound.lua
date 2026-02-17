-- Procedural sound effects: generated at load time, no audio files needed.

local sound = {}

local SAMPLE_RATE = 44100
local _master_volume = 1.0

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

local function generate_sound(duration, generator_fn)
  local samples = math.floor(SAMPLE_RATE * duration)
  local data = love.sound.newSoundData(samples, SAMPLE_RATE, 16, 1)
  for i = 0, samples - 1 do
    local t = i / SAMPLE_RATE
    local progress = i / samples
    local sample = generator_fn(t, progress)
    data:setSample(i, clamp(sample, -1, 1))
  end
  return data
end

local _pools = {}
local _pool_index = {}
local POOL_SIZE = 4

local function create_pool(sound_data)
  local pool = {}
  for _ = 1, POOL_SIZE do
    pool[#pool + 1] = love.audio.newSource(sound_data)
  end
  return pool
end

local function _init()
  -- click: UI interaction
  local click_data = generate_sound(0.04, function(t, progress)
    local envelope = 1 - progress
    return math.sin(2 * math.pi * 1200 * t) * envelope * 0.4
  end)

  -- build: structure placed
  local build_data = generate_sound(0.18, function(t, progress)
    local envelope = math.exp(-t * 15)
    local wave = math.sin(2 * math.pi * 180 * t)
             + 0.5 * math.sin(2 * math.pi * 360 * t)
    return wave * envelope * 0.3
  end)

  -- error: invalid action
  local error_data = generate_sound(0.12, function(t, progress)
    local envelope = 1 - progress
    local wave = math.sin(2 * math.pi * 150 * t)
             + 0.6 * math.sin(2 * math.pi * 183 * t)
    return wave * envelope * 0.25
  end)

  -- coin: resource gained
  local coin_data = generate_sound(0.1, function(t, progress)
    local freq = 600 + progress * 600
    local envelope = 1 - progress
    return math.sin(2 * math.pi * freq * t) * envelope * 0.35
  end)

  -- spend: resource spent
  local spend_data = generate_sound(0.08, function(t, progress)
    local freq = 800 - progress * 400
    local envelope = 1 - progress
    return math.sin(2 * math.pi * freq * t) * envelope * 0.3
  end)

  -- whoosh: turn change
  local whoosh_data = generate_sound(0.2, function(t, progress)
    local attack = (t < 0.03) and (t / 0.03) or 1
    local decay = 1 - progress
    local noise = (math.random() * 2 - 1) * attack * decay
    return noise * 0.4
  end)

  -- pop: worker pickup/drop
  local pop_data = generate_sound(0.03, function(t, progress)
    local envelope = 1 - progress
    return math.sin(2 * math.pi * 500 * t) * envelope * 0.5
  end)

  _pools.click = create_pool(click_data)
  _pools.build = create_pool(build_data)
  _pools.error = create_pool(error_data)
  _pools.coin = create_pool(coin_data)
  _pools.spend = create_pool(spend_data)
  _pools.whoosh = create_pool(whoosh_data)
  _pools.pop = create_pool(pop_data)

  for name, _ in pairs(_pools) do
    _pool_index[name] = 1
  end
end

function sound.set_master_volume(v)
  _master_volume = math.max(0, math.min(1, v))
end

function sound.play(name, volume)
  local pool = _pools[name]
  if not pool then return end
  local idx = _pool_index[name]
  local source = pool[idx]
  source:stop()
  source:setVolume((volume or 1.0) * _master_volume)
  source:play()
  _pool_index[name] = (idx % #pool) + 1
end

-- Initialize on require
_init()

return sound
