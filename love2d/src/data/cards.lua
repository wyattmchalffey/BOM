-- Card definitions — pure data, no logic.
-- Add new cards by adding entries to this table.
--
-- Fields:
--   id          (string)  Unique identifier
--   name        (string)  Display name
--   faction     (string)  "Human" | "Orc" | "Neutral"
--   kind        (string)  "Base" | "Structure" | "ResourceNode" | "Unit" | "Worker"
--   text        (string)  Rules text (display only — abilities are in the abilities field)
--   costs       (table)   List of { type = "food"|"wood"|"stone"|"metal"|"bones", amount = N }
--   baseHealth  (number?) Only for bases
--   population  (number?) Max copies per deck
--   attack      (number?) For units
--   health      (number?) For units/structures (non-base)
--   abilities   (table?)  List of structured ability definitions (see below)
--
-- Ability structure:
--   type           (string)  "activated" | "triggered" | "static"
--   cost           (table)   Same format as card costs: { { type = "food", amount = 3 } }
--   effect         (string)  Effect key: "summon_worker", "produce", "draw_cards", etc.
--   effect_args    (table?)  Extra data for the effect, e.g. { amount = 1, resource = "food" }
--   once_per_turn  (bool?)   Defaults to false
--   trigger        (string?) For triggered abilities: "on_construct", "on_destroyed", "start_of_turn"

return {
  ---------------------------------------------------------
  -- Bases
  ---------------------------------------------------------
  {
    id = "HUMAN_BASE_CASTLE",
    name = "Castle",
    faction = "Human",
    kind = "Base",
    baseHealth = 30,
    population = 1,
    text = "Once per turn: 3 Food — Summon a Tier 0 Human Worker.",
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
  {
    id = "ORC_BASE_ENCAMPMENT",
    name = "Encampment",
    faction = "Orc",
    kind = "Base",
    baseHealth = 27,
    population = 1,
    text = "Once per turn: 3 Food — Summon a Tier 0 Orc Worker. You do not draw at the start of your turn.",
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
  -- Resource Nodes
  ---------------------------------------------------------
  {
    id = "RESOURCE_NODE_FOOD",
    name = "Oat Fields",
    faction = "Neutral",
    kind = "ResourceNode",
    population = 2,
    text = "Assign up to 3 Workers to produce Food.",
    costs = {},
    abilities = {
      {
        type = "static",
        effect = "produce",
        effect_args = { resource = "food", per_worker = 1, max_workers = 3 },
      },
    },
  },
  {
    id = "RESOURCE_NODE_WOOD",
    name = "Forest",
    faction = "Neutral",
    kind = "ResourceNode",
    population = 2,
    text = "Assign up to 3 Workers to produce Wood.",
    costs = {},
    abilities = {
      {
        type = "static",
        effect = "produce",
        effect_args = { resource = "wood", per_worker = 1, max_workers = 3 },
      },
    },
  },
  {
    id = "RESOURCE_NODE_STONE",
    name = "Quarry",
    faction = "Neutral",
    kind = "ResourceNode",
    population = 2,
    text = "Assign up to 3 Workers to produce Stone.",
    costs = {},
    abilities = {
      {
        type = "static",
        effect = "produce",
        effect_args = { resource = "stone", per_worker = 1, max_workers = 3 },
      },
    },
  },

  ---------------------------------------------------------
  -- Human Structures
  ---------------------------------------------------------
  {
    id = "HUMAN_STRUCTURE_FARMLAND",
    name = "Farmland",
    faction = "Human",
    kind = "Structure",
    population = 3,
    text = "Assign up to 1 Human Worker to produce 2 Food.",
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
    population = 2,
    text = "Action — pay wood/stone: Play a Human Warrior from your unit deck.",
    costs = { { type = "stone", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = {},  -- TODO: define exact activation cost
        effect = "play_unit",
        effect_args = { faction = "Human", tier_max = 1 },
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_BLACKSMITH",
    name = "Blacksmith",
    faction = "Human",
    kind = "Structure",
    population = 1,
    text = "Action — pay resources: Research Tier 1-3 technologies.",
    costs = { { type = "stone", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = {},  -- TODO: define exact activation cost
        effect = "research",
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_SMELTERY",
    name = "Smeltery",
    faction = "Human",
    kind = "Structure",
    population = 2,
    text = "Convert stone and wood into metal bars.",
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
    id = "HUMAN_STRUCTURE_STABLE",
    name = "Stable",
    faction = "Human",
    kind = "Structure",
    population = 2,
    text = "Once per turn — 2 Food: Summon a Tier 0 Human Worker.",
    costs = { { type = "wood", amount = 3 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "food", amount = 2 } },
        effect = "summon_worker",
        effect_args = { amount = 1 },
        once_per_turn = true,
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_COTTAGE",
    name = "Cottage",
    faction = "Human",
    kind = "Structure",
    population = 3,
    text = "Construct: Draw 2 cards.",
    costs = { { type = "wood", amount = 2 }, { type = "stone", amount = 1 } },
    abilities = {
      {
        type = "triggered",
        trigger = "on_construct",
        effect = "draw_cards",
        effect_args = { amount = 2 },
      },
    },
  },
  {
    id = "HUMAN_STRUCTURE_BANK",
    name = "Bank",
    faction = "Human",
    kind = "Structure",
    population = 1,
    text = "Once per turn — 2 Stone: Gain 3 Food and 2 Wood.",
    costs = { { type = "stone", amount = 3 }, { type = "wood", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "stone", amount = 2 } },
        effect = "produce_multiple",
        effect_args = { { resource = "food", amount = 3 }, { resource = "wood", amount = 2 } },
        once_per_turn = true,
      },
    },
  },

  ---------------------------------------------------------
  -- Orc Structures
  ---------------------------------------------------------
  {
    id = "ORC_STRUCTURE_TENT",
    name = "Tent",
    faction = "Orc",
    kind = "Structure",
    population = 3,
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
    population = 2,
    text = "Action — Bones & Chemicals: Play an Orc Warrior of Tier 1-2.",
    costs = { { type = "stone", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = {},  -- TODO: define exact activation cost
        effect = "play_unit",
        effect_args = { faction = "Orc", tier_max = 2 },
      },
    },
  },
  {
    id = "ORC_STRUCTURE_BREEDING_PIT",
    name = "Breeding Pit",
    faction = "Orc",
    kind = "Structure",
    population = 1,
    text = "Construct: Draw 3 cards. When destroyed, discard a random card.",
    costs = { { type = "stone", amount = 2 } },
    abilities = {
      {
        type = "triggered",
        trigger = "on_construct",
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
    id = "ORC_STRUCTURE_DESERT_BAZAAR",
    name = "Desert Bazaar",
    faction = "Orc",
    kind = "Structure",
    population = 2,
    text = "Once per turn — 2 Wood: Gain 3 Food and 1 Stone.",
    costs = { { type = "wood", amount = 2 }, { type = "food", amount = 2 } },
    abilities = {
      {
        type = "activated",
        cost = { { type = "wood", amount = 2 } },
        effect = "produce_multiple",
        effect_args = { { resource = "food", amount = 3 }, { resource = "stone", amount = 1 } },
        once_per_turn = true,
      },
    },
  },
  {
    id = "ORC_STRUCTURE_CRYPT",
    name = "Crypt",
    faction = "Orc",
    kind = "Structure",
    population = 1,
    text = "Construct: Draw 2 cards. Once per turn — 1 Food: Summon a Tier 0 Orc Worker.",
    costs = { { type = "stone", amount = 2 }, { type = "food", amount = 1 } },
    abilities = {
      {
        type = "triggered",
        trigger = "on_construct",
        effect = "draw_cards",
        effect_args = { amount = 2 },
      },
      {
        type = "activated",
        cost = { { type = "food", amount = 1 } },
        effect = "summon_worker",
        effect_args = { amount = 1 },
        once_per_turn = true,
      },
    },
  },
  {
    id = "ORC_STRUCTURE_GRAIN_SILO",
    name = "Grain Silo",
    faction = "Orc",
    kind = "Structure",
    population = 2,
    text = "Assign up to 2 Orc Workers to produce 2 Food each.",
    costs = { { type = "wood", amount = 3 } },
    abilities = {
      {
        type = "static",
        effect = "produce",
        effect_args = { resource = "food", per_worker = 2, max_workers = 2 },
      },
    },
  },
}
