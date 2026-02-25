-- Deterministic state hash helper.
--
-- Used for multiplayer desync detection between authoritative host and clients.
-- Hashes are computed over canonicalized Lua data and skip private/cache keys
-- (keys starting with "_") so runtime cache fields do not cause false mismatches.

local checksum = {}

checksum.VERSION = 2
checksum.ALGORITHM = "canon-djb2-32-v2"

local MOD32 = 4294967296

local function hash_init()
  return 5381
end

local function hash_byte(h, b)
  return (h * 33 + b) % MOD32
end

local function hash_str(h, s)
  s = tostring(s or "")
  for i = 1, #s do
    h = hash_byte(h, string.byte(s, i))
  end
  return h
end

local function hash_token(h, token)
  h = hash_str(h, token)
  return hash_byte(h, 124) -- "|"
end

local function format_number(n)
  if n ~= n then return "nan" end
  if n == math.huge then return "inf" end
  if n == -math.huge then return "-inf" end
  if n == 0 then return "0" end
  return string.format("%.17g", n)
end

local function key_type_rank(k)
  local tk = type(k)
  if tk == "number" then return 1 end
  if tk == "string" then return 2 end
  if tk == "boolean" then return 3 end
  return 4
end

local function key_less(a, b)
  local ra = key_type_rank(a)
  local rb = key_type_rank(b)
  if ra ~= rb then return ra < rb end

  local ta = type(a)
  if ta == "number" then return a < b end
  if ta == "string" then return a < b end
  if ta == "boolean" then return (a and 1 or 0) < (b and 1 or 0) end

  return tostring(a) < tostring(b)
end

local function is_private_key(k)
  return type(k) == "string" and k:sub(1, 1) == "_"
end

local function is_dense_array(t)
  local count = 0
  local max_i = 0
  for k, _ in pairs(t) do
    if is_private_key(k) then
      -- ignored
    elseif type(k) == "number" and k >= 1 and k % 1 == 0 then
      count = count + 1
      if k > max_i then max_i = k end
    else
      return false, 0
    end
  end
  if count == 0 then
    return true, 0
  end
  if max_i ~= count then
    return false, 0
  end
  return true, max_i
end

local function hash_value(h, v, seen)
  local tv = type(v)
  h = hash_token(h, tv)

  if tv == "nil" then
    return hash_token(h, "nil")
  end

  if tv == "boolean" then
    return hash_token(h, v and "1" or "0")
  end

  if tv == "number" then
    return hash_token(h, format_number(v))
  end

  if tv == "string" then
    return hash_token(h, v)
  end

  if tv ~= "table" then
    -- Unsupported runtime values (functions/userdata/thread) should not be in
    -- replicated state, but hash deterministically by stringified value.
    return hash_token(h, tostring(v))
  end

  if seen[v] then
    return hash_token(h, "<cycle>")
  end
  seen[v] = true

  local is_array, n = is_dense_array(v)
  if is_array then
    h = hash_token(h, "[")
    for i = 1, n do
      h = hash_value(h, v[i], seen)
    end
    h = hash_token(h, "]")
  else
    local keys = {}
    for k, _ in pairs(v) do
      if not is_private_key(k) then
        keys[#keys + 1] = k
      end
    end
    table.sort(keys, key_less)

    h = hash_token(h, "{")
    for _, k in ipairs(keys) do
      h = hash_value(h, k, seen)
      h = hash_value(h, v[k], seen)
    end
    h = hash_token(h, "}")
  end

  seen[v] = nil
  return h
end

local function to_hex32(n)
  local out = {}
  for i = 1, 8 do
    local nib = n % 16
    out[9 - i] = string.format("%x", nib)
    n = math.floor(n / 16)
  end
  return table.concat(out)
end

function checksum.game_state(g)
  local h = hash_init()
  h = hash_value(h, g, {})
  return table.concat({
    checksum.ALGORITHM,
    ":",
    to_hex32(h),
  })
end

return checksum
