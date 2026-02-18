-- Deterministic state checksum helper.
--
-- Used for lightweight desync detection between authoritative host and clients.

local checksum = {}

local function collect_player_parts(p)
  local parts = {
    tostring(p.totalWorkers or 0),
    tostring(p.workersOn and p.workersOn.food or 0),
    tostring(p.workersOn and p.workersOn.wood or 0),
    tostring(p.workersOn and p.workersOn.stone or 0),
    tostring(p.resources and p.resources.food or 0),
    tostring(p.resources and p.resources.wood or 0),
    tostring(p.resources and p.resources.stone or 0),
    tostring(#(p.deck or {})),
    tostring(#(p.hand or {})),
    tostring(#(p.board or {})),
    tostring(#(p.graveyard or {})),
  }
  -- Include structure worker counts for desync detection
  for _, entry in ipairs(p.board or {}) do
    parts[#parts + 1] = tostring(entry.workers or 0)
  end
  return parts
end

function checksum.game_state(g)
  local p1 = g.players[1]
  local p2 = g.players[2]
  local parts = {
    tostring(g.turnNumber or 0),
    tostring(g.activePlayer or 0),
    tostring(g.phase or ""),
  }

  local p1_parts = collect_player_parts(p1)
  for i = 1, #p1_parts do parts[#parts + 1] = p1_parts[i] end
  local p2_parts = collect_player_parts(p2)
  for i = 1, #p2_parts do parts[#parts + 1] = p2_parts[i] end

  return table.concat(parts, "|")
end

return checksum
