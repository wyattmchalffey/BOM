-- Game constants — pure data, no logic.
-- Tweak numbers here instead of hunting through game code.

return {
  -- Resources gained per assigned worker per turn (base rate; cards can override)
  production_per_worker = 1,

  -- Workers gained at the start of each turn
  workers_gained_per_turn = 1,

  -- All resource types in the game (add new ones here and they propagate everywhere)
  resource_types = { "food", "wood", "stone", "metal", "gold", "bones", "blood", "ectoplasm", "crystal", "fire", "water" },

  -- Default starting resources (can be overridden per-player during setup)
  default_starting_resources = {
    food = 0, wood = 0, stone = 0,
    metal = 0, gold = 0, bones = 0,
    blood = 0, ectoplasm = 0, crystal = 0,
    fire = 0, water = 0,
  },

  -- Default player setup (used when no custom config is provided)

  -- Version gates for multiplayer compatibility checks
  protocol_version = 2,
  rules_version = "0.1.1",
  content_version = "0.1.1",
  default_factions = { "Human", "Orc" },
  default_first_player = 0,
}
