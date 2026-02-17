-- Settings persistence: load/save player preferences to JSON file.

local json = require("src.net.json_codec")

local settings = {}

local FILENAME = "settings.json"

local DEFAULTS = {
  player_name = "Player",
  sfx_volume = 1.0,
  fullscreen = false,
  faction = "Human",
}

-- Current values (initialized to defaults)
settings.values = {}
for k, v in pairs(DEFAULTS) do settings.values[k] = v end

function settings.load()
  local contents = love.filesystem.read(FILENAME)
  if contents then
    local ok, decoded = pcall(json.decode, contents)
    if ok and type(decoded) == "table" then
      for k, default in pairs(DEFAULTS) do
        if decoded[k] ~= nil and type(decoded[k]) == type(default) then
          settings.values[k] = decoded[k]
        else
          settings.values[k] = default
        end
      end
      return
    end
  end
  -- Reset to defaults if file missing or invalid
  for k, v in pairs(DEFAULTS) do settings.values[k] = v end
end

function settings.save()
  local encoded = json.encode(settings.values)
  love.filesystem.write(FILENAME, encoded)
end

return settings
