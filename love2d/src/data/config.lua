-- Game constants — pure data, no logic.
-- Tweak numbers here instead of hunting through game code.

return {
  -- Resources gained per assigned worker per turn (base rate; cards can override)
  production_per_worker = 1,

  -- Workers gained at the start of each turn
  workers_gained_per_turn = 1,

  -- All resource types in the game (add new ones here and they propagate everywhere)
  resource_types = { "food", "wood", "stone", "cash", "metal", "bones" },

  -- Default starting resources (can be overridden per-player during setup)
  default_starting_resources = {
    food = 0, wood = 0, stone = 0,
    cash = 0, metal = 0, bones = 0,
  },

  -- Default player setup (used when no custom config is provided)
  default_factions = { "Human", "Orc" },
  default_first_player = 0,
}
