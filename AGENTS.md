# Battles of Masadoria — Agent Instructions

## Cursor Cloud specific instructions

### Project overview

Two-component codebase:
- **`love2d/`** — LÖVE 2D game client (Lua). Run with `love love2d/` from repo root.
- **`relay/`** — Node.js WebSocket relay server for internet multiplayer. Run with `node relay/server.js` (listens on port 8080).

### Running smoke tests

27 Lua smoke tests live in `love2d/scripts/*_smoke.lua`. Run all from repo root:

```bash
for f in love2d/scripts/*_smoke.lua; do lua "$f"; done
```

Known environment-limited tests:
- `wss_real_connection_smoke.lua` requires optional Lua websocket/SSL modules (not installed by default).
- `deck_legality_smoke.lua` has a pre-existing assertion failure unrelated to environment.

### Running the game client

```bash
love love2d/
```

For headless local multiplayer (useful for testing without network):

```bash
BOM_MULTIPLAYER_MODE=headless love love2d/
```

ALSA audio warnings are expected in headless/cloud VMs and do not affect functionality.

### Running the relay server

```bash
cd relay && node server.js
```

Verify with `curl http://localhost:8080/` — should return `BOM Relay — 0 active rooms`.

### Non-obvious notes

- The `lua` binary is a symlink to `lua5.3` at `/usr/local/bin/lua`. Tests require Lua 5.3+.
- LÖVE 2D `love` is installed via apt. The dpkg post-install may emit errors about desktop integration — these are harmless and the binary still works.
- The game window is 1280x720. It requires a display (`$DISPLAY` must be set).
- Websocket multiplayer Lua modules (`lua-websockets`, `luasec`) are optional and only needed for networked multiplayer testing, not for core gameplay or smoke tests.
