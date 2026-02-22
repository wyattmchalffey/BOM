-- Subtype definitions — unit and structure tags referenced by cards.
-- Used for tooltip display, ability filtering, and card categorization.
--
-- Fields:
--   name  (string)  Display name
--   text  (string)  Tooltip / description text

return {
  -- Combat subtypes
  Warrior     = { name = "Warrior",     text = "A melee combatant." },
  Mounted     = { name = "Mounted",     text = "A cavalry or mounted combatant." },
  Undead      = { name = "Undead",      text = "A reanimated creature." },
  Ninja       = { name = "Ninja",       text = "A stealthy assassin." },
  Cleric      = { name = "Cleric",      text = "A holy healer and protector." },
  Mage        = { name = "Mage",        text = "A wielder of arcane magic." },
  Scholar     = { name = "Scholar",     text = "A learned researcher and strategist." },
  Royal       = { name = "Royal",       text = "A member of nobility or royalty." },
  Monster     = { name = "Monster",     text = "A wild or monstrous creature." },
  Elemental   = { name = "Elemental",   text = "A being of pure elemental energy." },
  Machine     = { name = "Machine",     text = "A mechanical construct." },

  -- Structure subtypes
  Enhancement = { name = "Enhancement", text = "Attaches to a resource node." },
}
