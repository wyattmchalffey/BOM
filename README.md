# Siegecraft

Siegecraft is a digital card game prototype built in LOVE (LÖVE 2D) with a Lua simulation core and an authoritative multiplayer stack.

## Where To Start

- Game setup and run instructions: `love2d/README.md`
- Core game docs and design references: `love2d/docs/`
- Relay server (internet room-code forwarding): `relay/README.md`

## Current Status (2026-02-25)

- Playable local and multiplayer prototype (host-authoritative command flow)
- Deterministic replay logging + replay JSON export from in-game settings (`Esc`)
- Deterministic state hashing + desync detection/resync hooks for multiplayer
- Engine regression test suite (`lua love2d/tests/engine_regression_tests.lua`)

## Repository Layout

- `love2d/` - game client, simulation, UI, docs, scripts, Windows build scripts
- `relay/` - Node.js websocket relay for room-code pairing
- `EARLY_ACCESS_READINESS_REVIEW.md` - point-in-time readiness review + current status update

## Notes

- `love2d/build/windows/` contains generated build artifacts (tracked in this repo).
- Some docs under `love2d/docs/` are design/roadmap references; they are now labeled where historical.
