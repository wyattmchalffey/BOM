-- Minimal JSON encoder/decoder for multiplayer transport framing.
-- Supports: object, array, string, number, boolean, null.

local json = {}

local function is_array(t)
  local n = #t
  for k, _ in pairs(t) do
    if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then
      return false
    end
  end
  return true
end

local function escape_str(s)
  local map = {
    ["\\"] = "\\\\",
    ["\""] = "\\\"",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
  }
  return (s:gsub('[%z\1-\31\\"]', function(ch)
    return map[ch] or string.format("\\u%04x", ch:byte())
  end))
end

local function encode_value(v)
  local tv = type(v)
  if tv == "nil" then return "null" end
  if tv == "boolean" then return v and "true" or "false" end
  if tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      error("invalid_number")
    end
    return tostring(v)
  end
  if tv == "string" then
    return '"' .. escape_str(v) .. '"'
  end
  if tv == "table" then
    if is_array(v) then
      local out = {}
      for i = 1, #v do out[i] = encode_value(v[i]) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local keys, out = {}, {}
    for k, _ in pairs(v) do
      if type(k) ~= "string" then error("non_string_object_key") end
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for i, k in ipairs(keys) do
      out[i] = '"' .. escape_str(k) .. '":' .. encode_value(v[k])
    end
    return "{" .. table.concat(out, ",") .. "}"
  end
  error("unsupported_type_" .. tv)
end

function json.encode(v)
  return encode_value(v)
end

local function decode_error(pos, msg)
  error(string.format("json_decode_error@%d:%s", pos, msg))
end

local function parser(str)
  local i = 1
  local len = #str

  local function skip_ws()
    while i <= len do
      local c = str:sub(i, i)
      if c == " " or c == "\n" or c == "\r" or c == "\t" then i = i + 1 else break end
    end
  end

  local parse_value

  local function parse_string()
    if str:sub(i, i) ~= '"' then decode_error(i, "expected_quote") end
    i = i + 1
    local out = {}
    while i <= len do
      local c = str:sub(i, i)
      if c == '"' then
        i = i + 1
        return table.concat(out)
      end
      if c == "\\" then
        i = i + 1
        local esc = str:sub(i, i)
        if esc == '"' or esc == "\\" or esc == "/" then out[#out + 1] = esc
        elseif esc == "b" then out[#out + 1] = "\b"
        elseif esc == "f" then out[#out + 1] = "\f"
        elseif esc == "n" then out[#out + 1] = "\n"
        elseif esc == "r" then out[#out + 1] = "\r"
        elseif esc == "t" then out[#out + 1] = "\t"
        elseif esc == "u" then
          local hex = str:sub(i + 1, i + 4)
          if not hex:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
            decode_error(i, "invalid_unicode_escape")
          end
          local code = tonumber(hex, 16)
          if code < 128 then
            out[#out + 1] = string.char(code)
          else
            -- Keep higher code points escaped to avoid utf8 dependency.
            out[#out + 1] = string.format("\\u%04x", code)
          end
          i = i + 4
        else
          decode_error(i, "invalid_escape")
        end
      else
        out[#out + 1] = c
      end
      i = i + 1
    end
    decode_error(i, "unterminated_string")
  end

  local function parse_number()
    local start = i
    if str:sub(i, i) == "-" then i = i + 1 end
    if str:sub(i, i):match("%d") then
      if str:sub(i, i) == "0" then i = i + 1
      else while str:sub(i, i):match("%d") do i = i + 1 end end
    else
      decode_error(i, "invalid_number")
    end
    if str:sub(i, i) == "." then
      i = i + 1
      if not str:sub(i, i):match("%d") then decode_error(i, "invalid_fraction") end
      while str:sub(i, i):match("%d") do i = i + 1 end
    end
    local e = str:sub(i, i)
    if e == "e" or e == "E" then
      i = i + 1
      local sign = str:sub(i, i)
      if sign == "+" or sign == "-" then i = i + 1 end
      if not str:sub(i, i):match("%d") then decode_error(i, "invalid_exponent") end
      while str:sub(i, i):match("%d") do i = i + 1 end
    end
    return tonumber(str:sub(start, i - 1))
  end

  local function parse_array()
    i = i + 1
    skip_ws()
    local arr = {}
    if str:sub(i, i) == "]" then i = i + 1 return arr end
    while true do
      arr[#arr + 1] = parse_value()
      skip_ws()
      local c = str:sub(i, i)
      if c == "]" then i = i + 1 return arr end
      if c ~= "," then decode_error(i, "expected_comma_or_end_array") end
      i = i + 1
      skip_ws()
    end
  end

  local function parse_object()
    i = i + 1
    skip_ws()
    local obj = {}
    if str:sub(i, i) == "}" then i = i + 1 return obj end
    while true do
      if str:sub(i, i) ~= '"' then decode_error(i, "expected_object_key") end
      local key = parse_string()
      skip_ws()
      if str:sub(i, i) ~= ":" then decode_error(i, "expected_colon") end
      i = i + 1
      skip_ws()
      obj[key] = parse_value()
      skip_ws()
      local c = str:sub(i, i)
      if c == "}" then i = i + 1 return obj end
      if c ~= "," then decode_error(i, "expected_comma_or_end_object") end
      i = i + 1
      skip_ws()
    end
  end

  function parse_value()
    skip_ws()
    local c = str:sub(i, i)
    if c == '"' then return parse_string() end
    if c == "{" then return parse_object() end
    if c == "[" then return parse_array() end
    if c == "-" or c:match("%d") then return parse_number() end
    if str:sub(i, i + 3) == "true" then i = i + 4 return true end
    if str:sub(i, i + 4) == "false" then i = i + 5 return false end
    if str:sub(i, i + 3) == "null" then i = i + 4 return nil end
    decode_error(i, "unexpected_token")
  end

  local value = parse_value()
  skip_ws()
  if i <= len then decode_error(i, "trailing_data") end
  return value
end

function json.decode(str)
  if type(str) ~= "string" then
    error("json_decode_requires_string")
  end
  return parser(str)
end

return json
