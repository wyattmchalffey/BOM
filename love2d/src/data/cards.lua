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
  -- NEUTRAL STRUCTURES
  ---------------------------------------------------------

  {
    id = "NEUTRAL_STRUCTURE_HONEYBEE_HIVE",
    name = "Honeybee Hive",
    faction = "Neutral",
    kind = "Structure",
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
      },
      {
        type = "activated",
        cost = { { type = "stone", amount = 2 } },
        effect = "convert_resource",
        effect_args = { output = "wood", amount = 1 },
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
    text = "Action — 2 Wood: Play a Tier 1 Human Warrior. Action — 1 Wood, 1 Metal: Play a Tier 2 Human Warrior.",
    costs = { { type = "stone", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "wood", amount = 2 } },
        effect = "play_unit",
        effect_args = { faction = "Human", subtypes = {"Warrior"}, tier = 1 },
      },
      {
        type = "activated",
        cost = { { type = "wood", amount = 1 }, { type = "metal", amount = 1 } },
        effect = "play_unit",
        effect_args = { faction = "Human", subtypes = {"Warrior"}, tier = 2 },
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_SMELTERY",
    name = "Smeltery",
    faction = "Human",
    kind = "Structure",
    population = 1,
    text = "1 Stone, 1 Wood: Create 1 Metal.",
    costs = { { type = "stone", amount = 1 }, { type = "wood", amount = 1 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "stone", amount = 1 }, { type = "wood", amount = 1 } },
        effect = "convert_resource",
        effect_args = { output = "metal", amount = 1 },
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
    population = 1,
    text = "1 Metal: Play a Tier 1 Ninja. 2 Metal: Play a Tier 2 Ninja.",
    costs = { { type = "stone", amount = 3 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "metal", amount = 1 } },
        effect = "play_unit",
        effect_args = { subtypes = {"Ninja"}, tier = 1 },
      },
      {
        type = "activated",
        cost = { { type = "metal", amount = 2 } },
        effect = "play_unit",
        effect_args = { subtypes = {"Ninja"}, tier = 2 },
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
      },
      {
        type = "activated",
        cost = { { type = "gold", amount = 3 } },
        effect = "play_unit",
        effect_args = { subtypes = {"Royal"}, tier = 3 },
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
      },
      {
        type = "activated",
        cost = { { type = "metal", amount = 3 } },
        effect = "play_unit",
        effect_args = { subtypes = {"Machine"}, tier = 2 },
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
      },
      {
        type = "activated",
        cost = { { type = "metal", amount = 1 } },
        effect = "play_unit",
        effect_args = { subtypes = {"Mounted"}, tier = 2 },
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
    text = "Action — 1 Blood, 1 Bones: Play a Tier 1 Orc Warrior. Action — 2 Blood, 2 Bones: Play a Tier 2 Orc Warrior.",
    costs = { { type = "stone", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "blood", amount = 1 }, { type = "bones", amount = 1 } },
        effect = "play_unit",
        effect_args = { faction = "Orc", subtypes = {"Warrior"}, tier = 1 },
      },
      {
        type = "activated",
        cost = { { type = "blood", amount = 2 }, { type = "bones", amount = 2 } },
        effect = "play_unit",
        effect_args = { faction = "Orc", subtypes = {"Warrior"}, tier = 2 },
      },
    },
  },
  {
    id = "ORC_STRUCTURE_BREEDING_PIT",
    name = "Breeding Pit",
    faction = "Orc",
    kind = "Structure",
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
      },
    },
  },
  {
    id = "ORC_STRUCTURE_SACRIFICIAL_ALTAR",
    name = "Sacrificial Altar",
    faction = "Orc",
    kind = "Structure",
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
      },
    },
  },

  {
    id = "ORC_STRUCTURE_FIGHTING_PITS",
    name = "Fighting Pits",
    faction = "Orc",
    kind = "Structure",
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
      },
    },
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
}
