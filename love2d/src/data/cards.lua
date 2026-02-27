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
--   upkeep      (table?)  End-of-turn upkeep cost for units: { { type = "<resource>", amount = N }, ... }
--                          Units that can't pay upkeep die.
--   abilities   (table?)  List of structured ability definitions (see below)
--
-- Ability structure:
--   type           (string)  "activated" | "triggered" | "static"
--   cost           (table)   Same format as card costs
--   effect         (string)  Effect key: "summon_worker", "produce", "draw_cards", etc.
--   effect_args    (table?)  Extra data for the effect
--   once_per_turn  (bool?)   Defaults to false
--   trigger        (string?) For triggered: "on_play", "on_destroyed", "start_of_turn",
--                           "end_of_turn", "on_attack", ...

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
        text = "Summon a Tier 0 Human Worker",
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
        text = "Summon a Tier 0 Orc Worker",
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
  -- NEUTRAL STRUCTURES
  ---------------------------------------------------------

  {
    id = "NEUTRAL_STRUCTURE_HONEYBEE_HIVE",
    name = "Honeybee Hive",
    faction = "Neutral",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "Wood Enhancement. At the start of your turn, Generate 1 Food.",
    costs = { { type = "food", amount = 2 } },
    subtypes = { "Enhancement" },
    requires_resource = "wood",
    abilities = {
      {
        type = "static",
        effect = "produce",
        effect_args = { resource = "food", amount = 1 },
      },
    },
  },

  {
    id = "NEUTRAL_STRUCTURE_DESERT_BAZAAR",
    name = "Desert Bazaar",
    faction = "Neutral",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "Action — 2 Wood: Gain 1 Stone. Action — 2 Stone: Gain 1 Wood.",
    costs = { { type = "stone", amount = 1 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "wood", amount = 2 } },
        effect = "convert_resource",
        effect_args = { output = "stone", amount = 1 },
        text = "Gain 1 Stone",
      },
      {
        type = "activated",
        cost = { { type = "stone", amount = 2 } },
        effect = "convert_resource",
        effect_args = { output = "wood", amount = 1 },
        text = "Gain 1 Wood",
      },
    },
  },

  {
    id = "NEUTRAL_STRUCTURE_HOSPITAL",
    name = "Hospital",
    faction = "Neutral",
    kind = "Structure",
    tier = 2,
    population = 1,
    text = "Action — Discard 2 Cards: Draw 1.",
    costs = { { type = "stone", amount = 4 } },
    abilities = {
      {
        type = "activated",
        cost = {},
        effect = "discard_draw",
        effect_args = { discard = 2, draw = 1 },
        text = "Discard 2 cards, then draw 1",
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
    tier = 1,
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
    tier = 1,
    population = 1,
    text = "Action — 2 Wood: Play a Tier 1 Human Warrior. Action — 1 Wood, 1 Metal: Play a Tier 2 Human Warrior.",
    costs = { { type = "stone", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "wood", amount = 2 } },
        effect = "play_unit",
        effect_args = { faction = "Human", subtypes = {"Warrior"}, tier = 1 },
        text = "Play a T1 Human Warrior",
      },
      {
        type = "activated",
        cost = { { type = "wood", amount = 1 }, { type = "metal", amount = 1 } },
        effect = "play_unit",
        effect_args = { faction = "Human", subtypes = {"Warrior"}, tier = 2 },
        text = "Play a T2 Human Warrior",
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_SMELTERY",
    name = "Smeltery",
    faction = "Human",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "1 Stone, 1 Wood: Create 1 Metal.",
    costs = { { type = "stone", amount = 1 }, { type = "wood", amount = 1 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "stone", amount = 1 }, { type = "wood", amount = 1 } },
        effect = "convert_resource",
        effect_args = { output = "metal", amount = 1 },
        text = "Create 1 Metal",
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_GENERAL_WARES_SHOP",
    name = "General Wares Shop",
    faction = "Human",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "Action — 3 Gold: Draw a card.",
    costs = { { type = "wood", amount = 3 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "gold", amount = 3 } },
        effect = "draw_cards",
        effect_args = { amount = 1 },
        text = "Draw a card",
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_BANK",
    name = "Bank",
    faction = "Human",
    kind = "Structure",
    tier = 2,
    population = 1,
    text = "At the start of your turn, Generate 1 Gold.",
    costs = { { type = "stone", amount = 2 }, { type = "wood", amount = 2 } },
    abilities = {
      {
        type = "static",
        effect = "produce",
        effect_args = { resource = "gold", amount = 1 },
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_DOJO",
    name = "Dojo",
    faction = "Human",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "1 Metal: Play a Tier 1 Ninja. 2 Metal: Play a Tier 2 Ninja.",
    costs = { { type = "stone", amount = 3 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "metal", amount = 1 } },
        effect = "play_unit",
        effect_args = { subtypes = {"Ninja"}, tier = 1 },
        text = "Play a T1 Ninja",
      },
      {
        type = "activated",
        cost = { { type = "metal", amount = 2 } },
        effect = "play_unit",
        effect_args = { subtypes = {"Ninja"}, tier = 2 },
        text = "Play a T2 Ninja",
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_ROYAL_THRONE",
    name = "Royal Throne",
    faction = "Human",
    kind = "Structure",
    population = 1,
    tier = 2,
    text = "2 Gold: Play a Tier 2 Royal Human. 3 Gold: Play a Tier 3 Royal Human.",
    costs = { { type = "gold", amount = 3 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "gold", amount = 2 } },
        effect = "play_unit",
        effect_args = { subtypes = {"Royal"}, tier = 2 },
        text = "Play a T2 Royal",
      },
      {
        type = "activated",
        cost = { { type = "gold", amount = 3 } },
        effect = "play_unit",
        effect_args = { subtypes = {"Royal"}, tier = 3 },
        text = "Play a T3 Royal",
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_INVENTORS_WORKSHOP",
    name = "Inventors Workshop",
    faction = "Human",
    kind = "Structure",
    population = 1,
    tier = 2,
    text = "4 Wood: Play a Tier 1 Machine. 3 Metal: Play a Tier 2 Machine.",
    costs = { { type = "stone", amount = 4 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "wood", amount = 4 } },
        effect = "play_unit",
        effect_args = { subtypes = {"Machine"}, tier = 1 },
        text = "Play a T1 Machine",
      },
      {
        type = "activated",
        cost = { { type = "metal", amount = 3 } },
        effect = "play_unit",
        effect_args = { subtypes = {"Machine"}, tier = 2 },
        text = "Play a T2 Machine",
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_STABLE",
    name = "Stable",
    faction = "Human",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "Action — 2 Wood: Play a Tier 1 Mounted Unit. Action — 1 Metal: Play a Tier 2 Mounted Unit.",
    costs = { { type = "wood", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "wood", amount = 2 } },
        effect = "play_unit",
        effect_args = { subtypes = {"Mounted"}, tier = 1 },
        text = "Play a T1 Mounted Unit",
      },
      {
        type = "activated",
        cost = { { type = "metal", amount = 1 } },
        effect = "play_unit",
        effect_args = { subtypes = {"Mounted"}, tier = 2 },
        text = "Play a T2 Mounted Unit",
      },
    },
  },

  {
    id = "HUMAN_STRUCTURE_MINT",
    name = "Mint",
    faction = "Human",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "Assign Human Workers to produce Gold per turn.",
    costs = { { type = "metal", amount = 2 } },
    abilities = {
      {
        type = "static",
        effect = "produce",
        effect_args = { resource = "gold", per_worker = 1, max_workers = 3 },
      },
    },
  },

  {
    id = "HUMAN_STRUCTURE_ALCHEMY_TABLE",
    name = "Alchemy Table",
    faction = "Human",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "3 Wood: Play a Tier 2 Human Scholar. 2 Gold: Play a Tier 1 Science Spell.",
    costs = { { type = "gold", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "wood", amount = 3 } },
        effect = "play_unit",
        effect_args = { faction = "Human", subtypes = { "Scholar" }, tier = 2 },
        text = "Play a T2 Human Scholar",
      },
      {
        type = "activated",
        fast = true,
        cost = { { type = "gold", amount = 2 } },
        effect = "play_spell",
        effect_args = { subtypes = { "Science" }, tier = 1 },
        text = "Play a T1 Science Spell",
      },
    },
  },

  {
    id = "HUMAN_STRUCTURE_BLACKSMITH",
    name = "Blacksmith",
    faction = "Human",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "Action - 1 Metal: Research a Tier 1 Technology. 2 Metal: Tier 2. 4 Metal: Tier 3.",
    costs = { { type = "stone", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "metal", amount = 1 } },
        effect = "play_unit",
        effect_args = { kind = "Technology", tier = 1 },
        text = "Research a T1 Technology",
      },
      {
        type = "activated",
        cost = { { type = "metal", amount = 2 } },
        effect = "play_unit",
        effect_args = { kind = "Technology", tier = 2 },
        text = "Research a T2 Technology",
      },
      {
        type = "activated",
        cost = { { type = "metal", amount = 4 } },
        effect = "play_unit",
        effect_args = { kind = "Technology", tier = 3 },
        text = "Research a T3 Technology",
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_COTTAGE",
    name = "Cottage",
    faction = "Human",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "On Play: Draw 1 Card. Passive - Generate 1 extra resource for each 3 Peasants assigned.",
    costs = { { type = "wood", amount = 2 } },
    abilities = {
      {
        type = "triggered",
        trigger = "on_play",
        effect = "draw_cards",
        effect_args = { amount = 1 },
      },
      {
        type = "static",
        effect = "bonus_production",
        effect_args = { per_workers = 3, bonus = 1 },
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_LIBRARY",
    name = "Library",
    faction = "Human",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "2 Gold: Play a Tier 1 Scholar. 3 Gold: Place 2 Knowledge Counters on a target ally.",
    costs = { { type = "stone", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "gold", amount = 2 } },
        effect = "play_unit",
        effect_args = { subtypes = { "Scholar" }, tier = 1 },
        text = "Play a T1 Scholar",
      },
      {
        type = "activated",
        cost = { { type = "gold", amount = 3 } },
        effect = "place_counter_on_target",
        effect_args = { counter = "knowledge", amount = 2 },
        text = "Place 2 Knowledge counters on an ally",
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_TOME_OF_KNOWLEDGE",
    name = "Tome of Aggregate Knowledge",
    faction = "Human",
    kind = "Structure",
    population = 1,
    tier = 3,
    text = "Whenever a Human dies: Opt 1 for each Scholar you control +1.",
    costs = { { type = "wood", amount = 4 } },
    abilities = {
      {
        type = "triggered",
        trigger = "on_ally_death",
        effect = "opt",
        effect_args = { base = 1, per_subtype = "Scholar" },
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_GRAIN_SILO",
    name = "Grain Silo",
    faction = "Human",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "Prevent up to 8 Food from rotting at the end of turn.",
    costs = { { type = "stone", amount = 3 } },
    abilities = {
      {
        type = "static",
        effect = "prevent_rot",
        effect_args = { resource = "food", amount = 8 },
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_COMMAND_TOWER",
    name = "Command Tower",
    faction = "Human",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "Whenever 3 Humans attack at once, Unrest target Unit after combat.",
    costs = { { type = "wood", amount = 2 } },
    abilities = {
      {
        type = "triggered",
        trigger = "on_mass_attack",
        effect = "unrest_target",
        effect_args = { min_attackers = 3 },
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_SALT_SMOKE_STACKS",
    name = "Salt-Smoke Stacks",
    faction = "Human",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "Prevent up to 8 Food from rotting at the end of turn.",
    costs = { { type = "stone", amount = 3 } },
    abilities = {
      {
        type = "static",
        effect = "prevent_rot",
        effect_args = { resource = "food", amount = 8 },
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
    attack = 2,
    health = 2,
    text = "",
    costs = {},
    upkeep = {},
    subtypes = { "Warrior" },
    abilities = {},
  },
  {
    id = "HUMAN_UNIT_HORSEMAN",
    name = "Horseman",
    faction = "Human",
    kind = "Unit",
    population = 8,
    tier = 1,
    attack = 3,
    health = 4,
    text = "On Attack: Give 1 other attacking Unit +1/+0.",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Warrior", "Mounted" },
    abilities = {
      {
        type = "triggered",
        trigger = "on_attack",
        effect = "buff_ally_attacker",
        effect_args = { attack = 1, count = 1 },
      },
    },
  },
  {
    id = "HUMAN_UNIT_YOUNG_ROOKIE",
    name = "Young Rookie",
    faction = "Human",
    kind = "Unit",
    population = 8,
    tier = 1,
    attack = 4,
    health = 3,
    text = "First Strike.",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Ninja" },
    keywords = { "first_strike" },
    abilities = {},
  },
  {
    id = "HUMAN_UNIT_SHINOBI",
    name = "Shinobi",
    faction = "Human",
    kind = "Unit",
    population = 4,
    tier = 2,
    attack = 6,
    health = 4,
    text = "First Strike.",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Ninja" },
    keywords = { "first_strike" },
    abilities = {},
  },
  {
    id = "HUMAN_UNIT_QUARTER_MASTER",
    name = "Quarter Master",
    faction = "Human",
    kind = "Unit",
    population = 8,
    tier = 1,
    attack = 4,
    health = 3,
    text = "Vigilance.",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Warrior" },
    keywords = { "vigilance" },
    abilities = {},
  },
  {
    id = "HUMAN_UNIT_LANCER",
    name = "Lancer",
    faction = "Human",
    kind = "Unit",
    population = 8,
    tier = 2,
    attack = 4,
    health = 5,
    text = "Vigilance. On Attack: If attacking with another Mounted Unit, deal 2 Damage to Target Unit.",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Warrior", "Mounted" },
    keywords = { "vigilance" },
    abilities = {
      {
        type = "triggered",
        trigger = "on_attack",
        effect = "conditional_damage",
        effect_args = { condition = "allied_mounted_attacking", damage = 2, target = "unit" },
      },
    },
  },

  ---------------------------------------------------------
  -- ORC STRUCTURES
  ---------------------------------------------------------

  {
    id = "HUMAN_UNIT_ALCHEMIST",
    name = "Alchemist",
    faction = "Human",
    kind = "Unit",
    population = 6,
    tier = 2,
    attack = 3,
    health = 3,
    text = "Once per turn — 3 Gold: Deal 3 damage to target unit. Remove 3 Knowledge counters, Rest: Play a Machine from hand.",
    costs = { { type = "stone", amount = 4 } },
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Scholar" },
    abilities = {
      {
        type = "activated",
        cost = { { type = "gold", amount = 3 } },
        effect = "deal_damage",
        effect_args = { damage = 3, target = "unit" },
        once_per_turn = true,
        text = "Deal 3 damage to target unit",
      },
      {
        type = "activated",
        cost = {},
        rest = true,
        effect = "remove_counter_play",
        effect_args = { counter = "knowledge", remove = 3, subtypes = { "Machine" } },
        text = "Remove 3 Knowledge counters: play a Machine from hand",
      },
    },
  },

  {
    id = "HUMAN_UNIT_PRINCE_OF_REASON",
    name = "Prince of Reason",
    faction = "Human",
    kind = "Unit",
    population = 4,
    tier = 2,
    attack = 2,
    health = 5,
    text = "Rest: Place 2 Knowledge counters on any ally. 2 Gold, Rest: Search your deck for a Science Spell or Human Technology and add it to your hand.",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Royal", "Scholar" },
    abilities = {
      {
        type = "activated",
        cost = {},
        rest = true,
        effect = "place_counter_on_target",
        effect_args = { counter = "knowledge", amount = 2 },
        text = "Place 2 Knowledge counters on any ally",
      },
      {
        type = "activated",
        cost = { { type = "gold", amount = 2 } },
        rest = true,
        effect = "search_deck",
        effect_args = {
          search_criteria = {
            { kind = "Spell", subtypes = { "Science" } },
            { kind = "Technology", faction = "Human" },
          },
        },
        text = "Search your deck for a Science Spell or Human Technology",
      },
    },
  },

  {
    id = "HUMAN_UNIT_PHILOSOPHER",
    name = "Philosopher",
    faction = "Human",
    kind = "Unit",
    population = 4,
    tier = 1,
    attack = 0,
    health = 3,
    text = "Action — Remove a Knowledge counter: Draw a card.",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Scholar" },
    abilities = {
      {
        type = "activated",
        cost = {},
        effect = "remove_counter_draw",
        effect_args = { counter = "knowledge", remove = 1, draw = 1 },
        text = "Remove a Knowledge counter, draw a card",
      },
    },
  },

  {
    id = "HUMAN_UNIT_FLYING_MACHINE",
    name = "Flying Machine",
    faction = "Human",
    kind = "Unit",
    population = 4,
    tier = 3,
    attack = 4,
    health = 4,
    text = "Flying. Action — X Stone, Rest: Deal X damage to target Unit.",
    costs = {},
    upkeep = { { type = "food", amount = 2 } },
    subtypes = { "Machine" },
    keywords = { "flying" },
    abilities = {
      {
        type = "activated",
        cost = {},
        rest = true,
        effect = "deal_damage_x",
        effect_args = { resource = "stone", target = "unit" },
        text = "Spend X Stone: Deal X damage to target unit",
      },
    },
  },

  {
    id = "HUMAN_UNIT_CATAPULT",
    name = "Catapult",
    faction = "Human",
    kind = "Unit",
    population = 4,
    tier = 2,
    attack = 0,
    health = 3,
    text = "Action — 1 Stone: Deal 2 damage to any target.",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Machine" },
    abilities = {
      {
        type = "activated",
        cost = { { type = "stone", amount = 1 } },
        effect = "deal_damage",
        effect_args = { damage = 2, target = "global" },
        text = "Deal 2 damage to any target",
      },
    },
  },

  {
    id = "HUMAN_UNIT_KING_OF_MAN",
    name = "King of Man",
    faction = "Human",
    kind = "Unit",
    population = 4,
    tier = 3,
    attack = 5,
    health = 8,
    text = "Trample, Vigilance. On attack - 2 Gold: All attacking Warriors gain +1 Attack for each Scholar you control.",
    costs = {},
    upkeep = { { type = "food", amount = 2 } },
    subtypes = { "Warrior", "Royal" },
    keywords = { "trample", "vigilance" },
    abilities = {
      {
        type = "triggered",
        trigger = "on_attack",
        cost = { { type = "gold", amount = 2 } },
        effect = "buff_warriors_per_scholar",
        effect_args = { attack_per_scholar = 1 },
      },
    },
  },

  {
    id = "HUMAN_SPELL_ACID_BOMB",
    name = "Acid Bomb",
    faction = "Human",
    kind = "Spell",
    population = 4,
    tier = 1,
    costs = {},
    subtypes = { "Science" },
    text = "Deal 2 damage to each attacking Unit.",
    abilities = {
      {
        type = "triggered",
        trigger = "on_cast",
        effect = "deal_damage_aoe",
        effect_args = { damage = 2, target = "attacking_units" },
      },
    },
  },

  {
    id = "HUMAN_TECHNOLOGY_MELEE_AGE_UP",
    name = "Melee Age Up",
    faction = "Human",
    kind = "Technology",
    population = 8,
    tier = 1,
    dynamic_tier_mode = "owned_plus_one",
    text = "Rank is equal to the number of this Technology owned +1. All Warriors gain +1 Attack.",
    costs = {},
    subtypes = {},
    abilities = {
      {
        type = "static",
        effect = "global_buff",
        effect_args = { subtypes = { "Warrior" }, attack = 1 },
      },
    },
  },

  {
    id = "ORC_STRUCTURE_TENT",
    name = "Tent",
    faction = "Orc",
    kind = "Structure",
    tier = 1,
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
        text = "Summon a Tier 0 Orc Worker",
      },
    },
  },
  {
    id = "ORC_STRUCTURE_HALL_OF_WARRIORS",
    name = "Hall of Warriors",
    faction = "Orc",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "Action — 1 Blood, 1 Bones: Play a Tier 1 Orc Warrior. Action — 2 Blood, 2 Bones: Play a Tier 2 Orc Warrior.",
    costs = { { type = "stone", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "blood", amount = 1 }, { type = "bones", amount = 1 } },
        effect = "play_unit",
        effect_args = { faction = "Orc", subtypes = {"Warrior"}, tier = 1 },
        text = "Play a T1 Orc Warrior",
      },
      {
        type = "activated",
        cost = { { type = "blood", amount = 2 }, { type = "bones", amount = 2 } },
        effect = "play_unit",
        effect_args = { faction = "Orc", subtypes = {"Warrior"}, tier = 2 },
        text = "Play a T2 Orc Warrior",
      },
    },
  },
  {
    id = "ORC_STRUCTURE_BREEDING_PIT",
    name = "Breeding Pit",
    faction = "Orc",
    kind = "Structure",
    tier = 1,
    population = 6,
    health = 5,
    text = "On Play: Draw 3 Cards. Discard a random card when destroyed.",
    costs = { { type = "stone", amount = 2 } },
    abilities = {
      {
        type = "triggered",
        trigger = "on_play",
        effect = "draw_cards",
        effect_args = { amount = 3 },
      },
      {
        type = "triggered",
        trigger = "on_destroyed",
        effect = "discard_random",
        effect_args = { amount = 1 },
      },
    },
  },
  {
    id = "ORC_STRUCTURE_CRYPT",
    name = "Crypt",
    faction = "Orc",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "Whenever a non-Undead ally dies, create 1 Bones. 2 Bones: Play a Tier 0 Undead.",
    costs = { { type = "stone", amount = 3 } },
    abilities = {
      {
        type = "triggered",
        trigger = "on_ally_death",
        effect = "produce",
        effect_args = { resource = "bones", amount = 1, condition = "non_undead" },
      },
      {
        type = "activated",
        cost = { { type = "bones", amount = 2 } },
        effect = "play_unit",
        effect_args = { subtypes = {"Undead"}, tier = 0 },
        text = "Play a T0 Undead",
      },
    },
  },
  {
    id = "ORC_STRUCTURE_SACRIFICIAL_ALTAR",
    name = "Sacrificial Altar",
    faction = "Orc",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "Action — Sacrifice a non-Undead Ally: Create 1 Blood.",
    costs = { { type = "stone", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = {},
        effect = "sacrifice_produce",
        effect_args = { condition = "non_undead", resource = "blood", amount = 1 },
        label = "Sacrifice",
        text = "Sacrifice a non-Undead ally: Create 1 Blood",
      },
    },
  },

  {
    id = "ORC_STRUCTURE_FIGHTING_PITS",
    name = "Fighting Pits",
    faction = "Orc",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "Action — Sacrifice a Warrior: Play a Warrior one rank higher. Orc workers count as Rank 0 Warriors.",
    costs = { { type = "stone", amount = 3 } },
    abilities = {
      {
        type = "activated",
        cost = {},
        effect = "sacrifice_upgrade",
        effect_args = { subtypes = {"Warrior"} },
        label = "Sacrifice Upgrade",
        text = "Sacrifice a Warrior: play a Warrior one rank higher",
      },
    },
  },

  {
    id = "ORC_STRUCTURE_CARRION_PIT",
    name = "Carrion Pit",
    faction = "Orc",
    kind = "Structure",
    population = 1,
    tier = 3,
    text = "Start of turn: Generate 1 Bones.",
    costs = { { type = "bones", amount = 5 } },
    abilities = {
      {
        type = "static",
        effect = "produce",
        effect_args = { resource = "bones", amount = 1 },
      },
    },
  },

  {
    id = "ORC_STRUCTURE_RAIDING_OUTPOST",
    name = "Raiding Outpost",
    faction = "Orc",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "Once per turn, whenever an Orc deals damage to a Base, steal one resource. 20 Stone: Unrest each Unit; each may attack a 2nd time.",
    costs = { { type = "stone", amount = 2 } },
    abilities = {
      {
        type = "triggered",
        trigger = "on_base_damage",
        effect = "steal_resource",
        effect_args = { amount = 1 },
        once_per_turn = true,
      },
      {
        type = "activated",
        cost = { { type = "stone", amount = 20 } },
        effect = "mass_unrest",
        text = "Unrest each unit you control; they may attack again",
      },
    },
  },

  {
    id = "ORC_STRUCTURE_TEMPLE",
    name = "Temple",
    faction = "Orc",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "2 Stone: Play a Tier 1 Orc Cleric. 2 Blood: Play a Tier 2 Orc Cleric.",
    costs = { { type = "stone", amount = 3 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "stone", amount = 2 } },
        effect = "play_unit",
        effect_args = { faction = "Orc", subtypes = { "Cleric" }, tier = 1 },
        text = "Play a T1 Orc Cleric",
      },
      {
        type = "activated",
        cost = { { type = "blood", amount = 2 } },
        effect = "play_unit",
        effect_args = { faction = "Orc", subtypes = { "Cleric" }, tier = 2 },
        text = "Play a T2 Orc Cleric",
      },
    },
  },

  {
    id = "ORC_STRUCTURE_MAGIC_CAVE",
    name = "Magic Cave",
    faction = "Orc",
    kind = "Structure",
    tier = 1,
    population = 1,
    text = "2 Food: Play a Tier 1 Orc Mage. 3 Bones: Play a Tier 2 Orc Mage.",
    costs = { { type = "stone", amount = 3 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "food", amount = 2 } },
        effect = "play_unit",
        effect_args = { faction = "Orc", subtypes = { "Mage" }, tier = 1 },
        text = "Play a T1 Orc Mage",
      },
      {
        type = "activated",
        cost = { { type = "bones", amount = 3 } },
        effect = "play_unit",
        effect_args = { faction = "Orc", subtypes = { "Mage" }, tier = 2 },
        text = "Play a T2 Orc Mage",
      },
    },
  },

  {
    id = "ORC_STRUCTURE_TEMPLE_OF_STARS",
    name = "Temple of the Stars",
    faction = "Orc",
    kind = "Structure",
    population = 1,
    tier = 3,
    text = "Action — 3 Bones: Return target unit from your graveyard to your Hand.",
    costs = { { type = "stone", amount = 4 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "bones", amount = 3 } },
        effect = "return_from_graveyard",
        effect_args = { target = "unit", return_to = "hand" },
        text = "Return target unit from your graveyard to your hand",
      },
    },
  },

  {
    id = "ORC_STRUCTURE_MONUMENT_STAR_GOD",
    name = "Monument of the Star God",
    faction = "Orc",
    kind = "Structure",
    population = 2,
    tier = 1,
    text = "Monument. 2 Stone: Place a Wonder counter on this structure.",
    costs = {},
    keywords = { "monument" },
    abilities = {
      {
        type = "activated",
        cost = { { type = "stone", amount = 2 } },
        effect = "place_counter",
        effect_args = { counter = "wonder", amount = 1 },
        once_per_turn = true,
        text = "Place a Wonder counter on this structure",
      },
    },
  },

  ---------------------------------------------------------
  -- ORC ARTIFACTS
  ---------------------------------------------------------

  {
    id = "ORC_ARTIFACT_STONE_TALISMAN",
    name = "Stone Talisman of Honor",
    faction = "Orc",
    kind = "Artifact",
    population = 1,
    tier = 2,
    text = "Whenever a non-Undead Orc dies, place a Counter on this Artifact. Remove 3 Counters: Draw a Card.",
    costs = { { type = "stone", amount = 4 } },
    subtypes = {},
    abilities = {
      {
        type = "triggered",
        trigger = "on_ally_death",
        effect = "place_counter",
        effect_args = { counter = "honor", amount = 1, condition = "non_undead_orc" },
      },
      {
        type = "activated",
        cost = {},
        effect = "remove_counter_draw",
        effect_args = { counter = "honor", remove = 3, draw = 1 },
        text = "Remove 3 Honor counters: draw a card",
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
  -- ORC SPELLS
  ---------------------------------------------------------

  {
    id = "ORC_SPELL_STONE_TOSS",
    name = "Stone Toss",
    faction = "Orc",
    kind = "Spell",
    population = 4,
    tier = 2,
    costs = {},
    subtypes = {},
    text = "Monument 2. Deal 3 damage to target Unit.",
    abilities = {
      {
        type = "static",
        effect = "monument_cost",
        effect_args = { min_counters = 2 },
      },
      {
        type = "triggered",
        trigger = "on_cast",
        effect = "deal_damage",
        effect_args = { damage = 3, target = "unit" },
      },
    },
  },

  {
    id = "ORC_SPELL_MORTAL_COIL",
    name = "Mortal Coil",
    faction = "Orc",
    kind = "Spell",
    population = 4,
    tier = 2,
    costs = {},
    subtypes = { "Death" },
    text = "Destroy target non-Undead Unit.",
    abilities = {
      {
        type = "triggered",
        trigger = "on_cast",
        effect = "destroy_unit",
        effect_args = { condition = "non_undead" },
      },
    },
  },

  {
    id = "ORC_SPELL_BLOOD_BOIL",
    name = "Blood Boil",
    faction = "Orc",
    kind = "Spell",
    population = 4,
    tier = 2,
    costs = {},
    subtypes = { "Blood" },
    text = "Sacrifice X Orc Workers: Deal X damage to any target.",
    abilities = {
      {
        type = "triggered",
        trigger = "on_cast",
        effect = "sacrifice_x_damage",
        effect_args = { sacrifice_kind = "Worker", faction = "Orc", target = "any" },
      },
    },
  },

  ---------------------------------------------------------
  -- ORC UNITS
  ---------------------------------------------------------

  {
    id = "ORC_UNIT_BRITTLE_SKELETON",
    name = "Brittle Skeleton",
    faction = "Orc",
    kind = "Unit",
    population = 8,
    tier = 0,
    attack = 2,
    health = 1,
    text = "Rush. Decaying. (Can attack the turn it's summoned. Dies at the end of the turn.)",
    costs = {},
    upkeep = {},
    subtypes = { "Undead" },
    keywords = { "rush", "decaying" },
    abilities = {},
  },
  {
    id = "ORC_UNIT_BONE_DADDY",
    name = "Bone Daddy",
    faction = "Orc",
    kind = "Unit",
    population = 6,
    tier = 1,
    attack = 3,
    health = 4,
    text = "Whenever an ally Unit dies, you may rest this unit to gain 2 Bones.",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Warrior" },
    abilities = {
      {
        type = "triggered",
        trigger = "on_ally_death",
        effect = "produce",
        effect_args = { resource = "bones", amount = 2 },
      },
    },
  },
  {
    id = "ORC_UNIT_BLOOD_DIVINATOR",
    name = "Blood Divinator",
    faction = "Orc",
    kind = "Unit",
    population = 8,
    tier = 1,
    attack = 0,
    health = 3,
    text = "Action - Sacrifice this Unit: Deal 3 damage to any Unit. Action - 2 Blood, Rest: Cast an Orc Blood Spell.",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Cleric" },
    abilities = {
      {
        type = "activated",
        cost = {},
        effect = "deal_damage",
        effect_args = { damage = 3, target = "unit", sacrifice_self = true },
        text = "Sacrifice this unit: Deal 3 damage to target unit",
      },
      {
        type = "activated",
        cost = { { type = "blood", amount = 2 } },
        rest = true,
        effect = "play_spell",
        effect_args = { faction = "Orc", subtypes = { "Blood" } },
        text = "Cast an Orc Blood spell from hand",
      },
    },
  },
  {
    id = "ORC_UNIT_NECROMANCER",
    name = "Necromancer",
    faction = "Orc",
    kind = "Unit",
    population = 4,
    tier = 2,
    attack = 2,
    health = 3,
    text = "Action - Sacrifice a Unit, Rest: Cast a Death Spell. Action - 2 Blood, 5 Bones, Rest: Summon an Undead.",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Cleric" },
    abilities = {
      {
        type = "activated",
        cost = {},
        rest = true,
        effect = "sacrifice_cast_spell",
        effect_args = { subtypes = { "Death" } },
        text = "Sacrifice a unit: cast a Death spell from hand",
      },
      {
        type = "activated",
        cost = { { type = "blood", amount = 2 }, { type = "bones", amount = 5 } },
        rest = true,
        effect = "play_unit",
        effect_args = { subtypes = { "Undead" } },
        text = "Summon an Undead from hand",
      },
    },
  },
  {
    id = "ORC_UNIT_BONE_MUNCHER",
    name = "Bone Muncher",
    faction = "Orc",
    kind = "Unit",
    population = 8,
    tier = 1,
    attack = 2,
    health = 3,
    text = "Instant - 2 Bones: Gain +2 Attack until end of turn.",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Warrior" },
    abilities = {
      {
        type = "activated",
        cost = { { type = "bones", amount = 2 } },
        effect = "buff_self",
        effect_args = { attack = 2, duration = "end_of_turn" },
        text = "Gain +2 Attack until end of turn",
      },
    },
  },
  {
    id = "ORC_UNIT_ANCIENT_GIANT",
    name = "Ancient Giant",
    faction = "Orc",
    kind = "Unit",
    population = 4,
    tier = 3,
    attack = 8,
    health = 8,
    text = "Trample. (Excess damage harms structures.)",
    costs = {},
    upkeep = { { type = "food", amount = 2 } },
    subtypes = { "Undead" },
    keywords = { "trample" },
    abilities = {},
  },
  {
    id = "ORC_UNIT_BERSERKER",
    name = "Berserker",
    faction = "Orc",
    kind = "Unit",
    population = 4,
    tier = 2,
    attack = 7,
    health = 5,
    text = "Vigilance. On Attack - 2 Blood: Gain Trample until end of turn.",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Warrior" },
    keywords = { "vigilance" },
    abilities = {
      {
        type = "triggered",
        trigger = "on_attack",
        cost = { { type = "blood", amount = 2 } },
        effect = "gain_keyword",
        effect_args = { keyword = "trample", duration = "end_of_turn" },
      },
    },
  },
  {
    id = "ORC_UNIT_SKELIEUTENANT",
    name = "Skelieutenant",
    faction = "Orc",
    kind = "Unit",
    population = 6,
    tier = 2,
    attack = 1,
    health = 3,
    text = "Once per turn — 3 Bones: Summon up to 3 Tier 0 Undead from the Graveyard.",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Mage" },
    abilities = {
      {
        type = "activated",
        cost = { { type = "bones", amount = 3 } },
        effect = "return_from_graveyard",
        effect_args = { subtypes = { "Undead" }, tier = 0, count = 3 },
        once_per_turn = true,
        text = "Return up to 3 T0 Undead from your graveyard to the board",
      },
    },
  },
  {
    id = "ORC_UNIT_GARGOYLE",
    name = "Gargoyle",
    faction = "Orc",
    kind = "Unit",
    population = 8,
    tier = 1,
    attack = 2,
    health = 2,
    text = "Monument 1. (Remove a Wonder counter from a Monument with at least 1 to play.)",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Monster", "Stone" },
    keywords = { "monument" },
    abilities = {
      {
        type = "static",
        effect = "monument_cost",
        effect_args = { min_counters = 1 },
      },
    },
  },
  {
    id = "ORC_UNIT_STONE_GOLEM",
    name = "Stone Golem",
    faction = "Orc",
    kind = "Unit",
    population = 6,
    tier = 2,
    attack = 4,
    health = 7,
    text = "Monument 4. (Remove a Wonder counter from a Monument with at least 4 to play.)",
    costs = {},
    upkeep = { { type = "food", amount = 1 } },
    subtypes = { "Elemental", "Stone" },
    keywords = { "monument" },
    abilities = {
      {
        type = "static",
        effect = "monument_cost",
        effect_args = { min_counters = 4 },
      },
    },
  },
}
