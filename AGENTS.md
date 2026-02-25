# AGENTS.md

## Cursor Cloud specific instructions

### Repository overview

**Battles of Masadoria** — a PvP card game prototype with two components:

| Component | Path | Technology | Purpose |
|---|---|---|---|
| Game client | `love2d/` | Lua + LÖVE 2D 11.x | Card game UI, simulation engine, tests |
| Relay server | `relay/` | Node.js + `ws` | WebSocket relay for online room-code matchmaking |

### Running tests

- **Engine regression tests** (fast, no GUI needed): `lua love2d/tests/engine_regression_tests.lua`
- **Smoke tests** (27 scripts): `lua love2d/scripts/<name>_smoke.lua` — all run headlessly via plain Lua
- See `love2d/README.md` → Testing section and `love2d/docs/MULTIPLAYER_TESTING.md` for the full list

### Running the game client

From the `love2d/` directory: `love .`

The game opens at 1280×720 and is mouse-driven. The main menu has: Play Online, Deck Builder, Settings, Quit. This is a PvP-only game — actual gameplay requires either two LÖVE clients or hosting + joining via the relay.

### Running the relay server

From the `relay/` directory: `node server.js`

Listens on port 8080 by default (override with `PORT` env var). Verify with `curl http://localhost:8080/` → `BOM Relay — 0 active rooms`.

### Gotchas

- The `node_modules/` directory under `relay/` is tracked in git. Running `npm install` is still recommended to ensure consistency.
- The `lua` command on Ubuntu points to `lua5.3` via alternatives. Tests and smoke scripts are compatible with Lua 5.3+.
- LÖVE 2D 11.5 is installed from the `ppa:bartbes/love-stable` PPA. The game's `conf.lua` targets version `11.4` but runs fine on 11.5.
- Multiplayer env vars (`BOM_MULTIPLAYER_MODE`, `BOM_MULTIPLAYER_URL`, etc.) are optional — the game starts in menu mode by default.
