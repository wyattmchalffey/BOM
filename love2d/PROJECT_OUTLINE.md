# Siegecraft - Project Outline (Archived MVP Outline)

This file used to describe the original MVP implementation plan.

That MVP plan has been exceeded substantially (cards, combat, multiplayer foundation, replay logging, reconnect/resync, prompt system refactors, etc.), so the old file was no longer a reliable guide to the current codebase.

## Current Source-of-Truth Docs

- `README.md` - runtime setup, controls, testing entry points
- `docs/MULTIPLAYER_TESTING.md` - current smoke tests and multiplayer validation steps
- `docs/MULTIPLAYER_MIGRATION_PLAN.md` - migration history + current status summary
- `docs/MULTIPLAYER_ROADMAP.md` - longer-term multiplayer roadmap
- `docs/GAME_DESIGN.md` - design targets / rule intent (not implementation contract)

## Current High-Level Code Map (2026-02-25)

- `src/game/`
  - simulation state, actions, commands, combat
  - ability/effect resolution
  - effect specs, event bus, spell-cast helpers
  - replay logging and deterministic checksums
- `src/state/`
  - game screen, menu, prompt system, multiplayer UX/reconnect handling
- `src/ui/`
  - board rendering, card frames, deck viewer, overlays/tooltips
- `src/net/`
  - protocol, host, client session, adapters, websocket/headless services, relay bridge
- `tests/`
  - engine regression suite (`engine_regression_tests.lua`)

## Note

If you need the original MVP plan for historical reference, check git history for earlier revisions of this file.
