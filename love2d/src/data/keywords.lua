-- Keyword definitions — combat and ability keywords referenced by cards.
-- Used for tooltip display and future rules enforcement.
--
-- Fields:
--   name  (string)  Display name
--   text  (string)  Tooltip / rules reminder text

return {
  rush         = { name = "Rush",         text = "Can attack the turn it is summoned." },
  decaying     = { name = "Decaying",     text = "Dies at the end of the turn." },
  flying       = { name = "Flying",       text = "Can only be blocked by other Flying units." },
  first_strike = { name = "First Strike", text = "Deals combat damage first." },
  trample      = { name = "Trample",      text = "Excess damage hits structures." },
  vigilance    = { name = "Vigilance",    text = "Does not rest when attacking." },
  deathtouch   = { name = "Deathtouch",   text = "Destroys any unit it damages." },
  intercept    = { name = "Intercept",    text = "May block attacks directed at other targets." },
  crew         = { name = "Crew",         text = "Cannot attack unless a worker is committed to it." },
  monument     = { name = "Monument",     text = "Played by removing counters from a Monument structure." },
  haste        = { name = "Haste",        text = "Can act immediately when played." },
}
