-- Run a headless host service over stdin/stdout JSON frames.
--
-- Example:
--   lua love2d/scripts/run_headless_host.lua
-- Then write one JSON request per line to stdin and read one JSON response per line.

package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local service_mod = require("src.net.headless_host_service")

local service = service_mod.new({ match_id = "headless-match" })

while true do
  local line = io.read("*l")
  if not line then break end
  if line ~= "" then
    local out = service:handle_frame(line)
    io.write(out .. "\n")
    io.flush()
  end
end
