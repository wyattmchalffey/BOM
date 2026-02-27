# Siegecraft - Alpha Rules (Brief)

This is a short playtester-facing rules summary for the current alpha build.

If a card's text or the in-game UI behavior conflicts with this page, the in-game behavior is the authority for this alpha.

## Goal

- Reduce the enemy base to `0` life.
- Bases currently start at `30` life by default (some faction/base definitions may vary).

## What You Start With

- A faction base
- A shuffled draw deck (units/spells/tech/items)
- A blueprint deck (structures/artifacts)
- `5` cards in hand
- `2` workers (faction defaults can vary)

## Turn Structure (Alpha)

At the start of your turn, the game automatically:

- resets once-per-turn ability usage
- readies/restores rested combatants where applicable
- gains `+1` worker (up to your faction max)
- produces resources from assigned workers and production cards
- resolves start-of-turn triggers
- draws `1` card (unless a base/card effect says otherwise)

Then you take actions in your main phase (mouse-driven), in any order, until you end your turn.

At end of turn, upkeep/decay and end-of-turn cleanup resolve automatically.

## Workers and Resources

Regular workers can be assigned to the basic resource nodes:

- `Food`
- `Wood`
- `Stone`

Each assigned worker usually produces `1` of that resource at the start of your turn.

Cards can:

- produce extra resources
- create/use non-basic resources (for example `metal`, `gold`, `bones`, etc.)
- consume workers or resource counters as costs

## Playing Cards

- **Structures / Artifacts** are built from your blueprint deck (via the blueprint UI).
- **Units / Spells / Tech / Items** are played from your hand if you can pay their cost.
- Some cards require extra costs (sacrifices, counters, targets, etc.). The UI will prompt you when needed.

## Combat (Brief)

- You can declare one or more attackers on your turn.
- Attackers choose a target:
  - enemy base, or
  - an eligible enemy card on the board
- The defender assigns blockers.
- If an attacker is blocked by multiple blockers, the attacker chooses damage order.
- Combat then resolves automatically (including first strike / trample / deathtouch style interactions if card text grants them).

Important alpha notes:

- Newly summoned units usually cannot attack the same turn unless they have an immediate-attack keyword (for example `Rush` / `Haste`).
- Rested units/workers generally cannot attack or block until they are readied again.

## Abilities and Keywords

- Cards may have activated, triggered, or static abilities.
- Activated abilities may be:
  - once per turn
  - costed (resources / counters / sacrifices / rest)
  - targeted
- The UI will gray/mark unavailable actions and prompt for legal targets when required.

## Alpha / Testing Notes

- Balance is not final.
- Some mechanics may still be partial or disabled in alpha tests.
- Use the in-game pause menu (`Esc`) to:
  - export a replay JSON
  - open the bug report form and copy a formatted bug report for Discord

