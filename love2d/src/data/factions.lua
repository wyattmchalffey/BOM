-- Faction definitions — pure data, no logic.
-- All faction-specific values live here: colors, defaults, base IDs.
--
-- "defaults" are used when creating a new game. Eventually players will
-- customize their decks and starting resources, so these serve as fallbacks.

return {
  Human = {
    color = { 0.31, 0.55, 1.0 },  -- accent / strip color (RGB, no alpha)
    default_base_id = "HUMAN_BASE_CASTLE",
    default_max_workers = 8,
    default_starting_workers = 2,
  },
  Orc = {
    color = { 1.0, 0.35, 0.24 },
    default_base_id = "ORC_BASE_ENCAMPMENT",
    default_max_workers = 12,
    default_starting_workers = 3,
  },
  Elf = {
    color = { 0.2, 0.75, 0.35 },   -- green accent
    default_base_id = "ELF_BASE_ENCAMPMENT",
    default_max_workers = 8,
    default_starting_workers = 2,
  },
  Gnome = {
    color = { 0.7, 0.45, 0.9 },    -- purple accent
    default_base_id = "GNOME_BASE_REIKI",
    default_max_workers = 6,
    default_starting_workers = 2,
  },
  Neutral = {
    color = { 0.55, 0.56, 0.83 },
  },
}
