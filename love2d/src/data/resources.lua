-- Resource type registry — single source of truth for all resource types.
-- Used by UI (board, card_frame) and game logic (player init, display).
--
-- Fields:
--   letter  (string)  Short abbreviation for compact display
--   order   (number)  Display order in the resource bar
--   color   (table)   RGB color for badge/icon tinting

return {
  food      = { letter = "F",  order = 1,  color = {0.95, 0.85, 0.3} },
  wood      = { letter = "W",  order = 2,  color = {0.45, 0.75, 0.3} },
  stone     = { letter = "S",  order = 3,  color = {0.6,  0.6,  0.65} },
  metal     = { letter = "M",  order = 4,  color = {0.7,  0.7,  0.75} },
  gold      = { letter = "G",  order = 5,  color = {1.0,  0.85, 0.2} },
  bones     = { letter = "B",  order = 6,  color = {0.85, 0.8,  0.7} },
  blood     = { letter = "Bl", order = 7,  color = {0.8,  0.15, 0.15} },
  ectoplasm = { letter = "Ec", order = 8,  color = {0.4,  0.9,  0.6} },
  crystal   = { letter = "Cr", order = 9,  color = {0.6,  0.4,  0.95} },
  fire      = { letter = "Fi", order = 10, color = {1.0,  0.4,  0.1} },
  water     = { letter = "Wa", order = 11, color = {0.2,  0.5,  0.95} },
}
