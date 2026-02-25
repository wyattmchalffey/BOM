# Multiplayer Migration Plan (History + Current Status)

This document originally tracked the migration from local-only gameplay to a host-authoritative multiplayer foundation.

That migration has advanced substantially. This file now serves as:

- a summary of what is already completed
- a snapshot of what remains for production-quality multiplayer

## Current Foundation Status (2026-02-25)

### Completed (Major)

- Command-driven simulation boundary (`src/game/commands.lua`)
- Host-authoritative multiplayer flow (`src/net/host.lua`)
- Protocol versioning + compatibility gates (`src/net/protocol.lua`, `src/data/config.lua`)
- Client session + reconnect/resync flow (`src/net/client_session.lua`)
- Authoritative client adapters (`src/net/authoritative_client_game.lua`, threaded adapter)
- Websocket/headless host service boundaries
- Replay logging + replay export (in-game settings)
- Deterministic canonical state hashing for desync checks
- Authoritative `state_seq` tracking
- Client desync detection hooks (optimistic hash mismatch + push hash mismatch)
- Improved disconnect cause reporting + reconnect UX diagnostics
- Engine regression test suite (`love2d/tests/engine_regression_tests.lua`)

### Completed (Engine Refactor / Scalability)

- Effect metadata/spec registry (`src/game/effect_specs.lua`)
- Typed event bus foundation (`src/game/events.lua`)
- Structured `abilities.resolve(...)` results
- Spell `on_cast` registry (`src/game/spell_cast.lua`)
- Prompt system refactor in `src/state/game.lua`
- Stable board instance IDs + improved once-per-turn tracking
- Continuous effect cache foundation in `src/game/unit_stats.lua`

## What This Means

The project is no longer in the "migration plan" phase for multiplayer basics.

The remaining work is mostly about:

- production hardening
- tooling and observability
- deeper engine normalization
- content/mechanics completion

## Remaining High-Impact Multiplayer/Engine Work

1. Zone-wide stable card instance IDs (hand/deck/graveyard, not just board)
2. Continuous effects v2 (more than `global_buff`)
3. Replay/desync diff tooling (first-divergence analysis between logs)
4. Further event/command normalization for debugging/replay consumers
5. Expanded automated sync/golden replay tests
6. Softer desync recovery (in-place snapshot resync before reconnect fallback)

## Historical Note

If you need the original step-by-step migration checklist, check git history for earlier revisions of this file.

## Related Docs

- `MULTIPLAYER_TESTING.md` - current test execution guide
- `MULTIPLAYER_ROADMAP.md` - longer-term roadmap (current priorities)
- `../README.md` - runtime setup and controls
