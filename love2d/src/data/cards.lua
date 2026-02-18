-- Card definitions — pure data, no logic.
-- Migrated from Fabletale card designer project (Fields of Valor).
--
-- Fields:
--   id          (string)  Unique identifier: FACTION_KIND_NAME
--   name        (string)  Display name
--   faction     (string)  "Human" | "Orc" | "Elf" | "Gnome" | "Neutral"
--   kind        (string)  "Base" | "Structure" | "ResourceNode" | "Unit" | "Worker"
--                          | "Spell" | "Technology" | "Item" | "Artifact"
--   text        (string)  Rules text (display only)
--   costs       (table)   Build/play cost: { { type = "food"|..., amount = N }, ... }
--   baseHealth  (number?) Only for bases
--   population  (number?) Max copies per deck (from Fabletale ba2_backup field)
--   attack      (number?) For units
--   health      (number?) For units/structures with HP
--   tier        (number?) 0 / 1 / 2 / 3
--   keywords    (table?)  { "rush", "flying", ... } — references data/keywords.lua
--   subtypes    (table?)  { "Warrior", "Mounted", ... } — parsed from type line
--   upkeep      (table?)  End-of-turn upkeep cost for units: { { type = "food", amount = N } }
--                          Units that can't pay upkeep die.
--   abilities   (table?)  List of structured ability definitions (see below)
--
-- Ability structure:
--   type           (string)  "activated" | "triggered" | "static"
--   cost           (table)   Same format as card costs
--   effect         (string)  Effect key: "summon_worker", "produce", "draw_cards", etc.
--   effect_args    (table?)  Extra data for the effect
--   once_per_turn  (bool?)   Defaults to false
--   trigger        (string?) For triggered: "on_construct", "on_destroyed", "start_of_turn", "end_of_turn"

return {

  ---------------------------------------------------------
  -- BASES
  ---------------------------------------------------------

  -- Human Base
  {
    id = "HUMAN_BASE_CASTLE",
    name = "Castle",
    faction = "Human",
    kind = "Base",
    baseHealth = 30,
    population = 1,
    text = "Once per turn — 3 Food: Summon a Tier 0 Human Worker.",
    costs = {},
    abilities = {
      {
        type = "activated",
        cost = { { type = "food", amount = 3 } },
        effect = "summon_worker",
        effect_args = { amount = 1 },
        once_per_turn = true,
      },
    },
  },

  -- Orc Base
  {
    id = "ORC_BASE_ENCAMPMENT",
    name = "Encampment",
    faction = "Orc",
    kind = "Base",
    baseHealth = 27,
    population = 1,
    text = "Once per turn — 3 Food: Summon a Tier 0 Orc Worker. You do not draw at the start of your turn.",
    costs = {},
    abilities = {
      {
        type = "activated",
        cost = { { type = "food", amount = 3 } },
        effect = "summon_worker",
        effect_args = { amount = 1 },
        once_per_turn = true,
      },
      {
        type = "static",
        effect = "skip_draw",
      },
    },
  },

  ---------------------------------------------------------
  -- RESOURCE NODES (Neutral)
  ---------------------------------------------------------

  {
    id = "RESOURCE_NODE_FOOD",
    name = "Oat Fields",
    faction = "Neutral",
    kind = "ResourceNode",
    population = 2,
    text = "Assign Workers to produce Food.",
    costs = {},
    abilities = {
      {
        type = "static",
        effect = "produce",
        effect_args = { resource = "food", per_worker = 1 },
      },
    },
  },
  {
    id = "RESOURCE_NODE_WOOD",
    name = "Forest",
    faction = "Neutral",
    kind = "ResourceNode",
    population = 2,
    text = "Assign Workers to produce Wood.",
    costs = {},
    abilities = {
      {
        type = "static",
        effect = "produce",
        effect_args = { resource = "wood", per_worker = 1 },
      },
    },
  },
  {
    id = "RESOURCE_NODE_STONE",
    name = "Quarry",
    faction = "Neutral",
    kind = "ResourceNode",
    population = 2,
    text = "Assign Workers to produce Stone.",
    costs = {},
    abilities = {
      {
        type = "static",
        effect = "produce",
        effect_args = { resource = "stone", per_worker = 1 },
      },
    },
  },

  ---------------------------------------------------------
  -- HUMAN STRUCTURES
  ---------------------------------------------------------

  {
    id = "HUMAN_STRUCTURE_FARMLAND",
    name = "Farmland",
    faction = "Human",
    kind = "Structure",
    population = 4,
    text = "Assign a worker to produce 2 Food per turn.",
    costs = { { type = "wood", amount = 2 } },
    abilities = {
      {
        type = "static",
        effect = "produce",
        effect_args = { resource = "food", per_worker = 2, max_workers = 1 },
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_BARRACKS",
    name = "Barracks",
    faction = "Human",
    kind = "Structure",
    population = 1,
    text = "Action — 2 Wood: Play a Tier 1 Human Warrior from your hand.",
    costs = { { type = "stone", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "wood", amount = 2 } },
        effect = "play_unit",
        effect_args = { faction = "Human", subtypes = {"Warrior"}, tier = 1 },
      },
    },
  },

  ---------------------------------------------------------
  -- HUMAN WORKERS
  ---------------------------------------------------------

  {
    id = "HUMAN_WORKER_LOVING_FAMILY",
    name = "Loving Family",
    faction = "Human",
    kind = "Worker",
    population = 6,
    tier = 0,
    attack = 1,
    health = 4,
    deckable = true,
    text = "Sacrifice 2 Human Workers to play from Hand. Produces 2x Resources.",
    costs = {},
    upkeep = {},
    subtypes = {},
    abilities = {
      { type = "static", effect = "play_cost_sacrifice",
        effect_args = { sacrifice_count = 2 } },
      { type = "static", effect = "double_production" },
    },
  },

  {
    id = "HUMAN_WORKER_PEASANT",
    name = "Peasant",
    faction = "Human",
    kind = "Worker",
    population = 8,
    tier = 0,
    attack = 0,
    health = 2,
    text = "It ain't much, but it's honest work.",
    costs = {},
    upkeep = {},
    subtypes = {},
    abilities = {},
  },

  ---------------------------------------------------------
  -- HUMAN UNITS
  ---------------------------------------------------------

  {
    id = "HUMAN_UNIT_SOLDIER",
    name = "Soldier",
    faction = "Human",
    kind = "Unit",
    population = 8,
    tier = 1,
    attack = 1,
    health = 2,
    text = "",
    costs = {},
    upkeep = {},
    subtypes = { "Warrior" },
    abilities = {},
  },

  ---------------------------------------------------------
  -- ORC STRUCTURES
  ---------------------------------------------------------

  {
    id = "ORC_STRUCTURE_TENT",
    name = "Tent",
    faction = "Orc",
    kind = "Structure",
    population = 1,
    text = "Once per turn — 3 Food: Summon a Tier 0 Orc Worker.",
    costs = { { type = "food", amount = 3 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "food", amount = 3 } },
        effect = "summon_worker",
        effect_args = { amount = 1 },
        once_per_turn = true,
      },
    },
  },
  {
    id = "ORC_STRUCTURE_HALL_OF_WARRIORS",
    name = "Hall of Warriors",
    faction = "Orc",
    kind = "Structure",
    population = 1,
    text = "Action — 2 Food: Play a Tier 1 Orc Warrior from your hand.",
    costs = { { type = "stone", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "food", amount = 2 } },
        effect = "play_unit",
        effect_args = { faction = "Orc", subtypes = {"Warrior"}, tier = 1 },
      },
    },
  },

  ---------------------------------------------------------
  -- ORC WORKERS
  ---------------------------------------------------------

  {
    id = "ORC_WORKER_GRUNT",
    name = "Grunt",
    faction = "Orc",
    kind = "Worker",
    population = 12,
    tier = 0,
    attack = 1,
    health = 1,
    text = "Work Work.",
    costs = {},
    upkeep = {},
    subtypes = { "Warrior" },
    abilities = {},
  },

  ---------------------------------------------------------
  -- ORC UNITS
  ---------------------------------------------------------

  {
    id = "ORC_UNIT_BONE_MUNCHER",
    name = "Bone Muncher",
    faction = "Orc",
    kind = "Unit",
    population = 8,
    tier = 1,
    attack = 2,
    health = 3,
    text = "",
    costs = {},
    upkeep = {},
    subtypes = { "Warrior" },
    abilities = {},
  },
}
