# Battles of Masadoria (LÖVE 2D)

Same game loop and UI as the web prototype: two players (Human Wood+Stone vs Orc Food+Stone), turn-based worker assignment, and structure building.

## Run

1. Install [LÖVE 11.x](https://love2d.org/) (Windows: use the installer; default path is `C:\Program Files\LOVE\`).
2. From this folder (`love2d`) run **one** of:
   - **PowerShell:** `.\run.ps1`
   - **Command prompt:** `run.bat`
   - **If `love` is in your PATH:** `love .`
   - **Or** drag the `love2d` folder onto `love.exe` in `C:\Program Files\LOVE\`.

## Controls

- **Click "Blueprint Deck"** on a player panel to open that faction’s structure cards. Click **Close** or outside the box (or press Escape) to close.
- **Drag a worker** (circle) from the unassigned pool onto a resource node to assign; drag from a node back to the unassigned pool (or onto the other node) to move.
- Only the **active player** can move workers.
- **"End turn / Start next"** ends the current turn and starts the next player’s turn (they gain 1 worker and produce resources from current assignments).

## Project outline

See [PROJECT_OUTLINE.md](PROJECT_OUTLINE.md) for the full MVP plan and file layout.

## Multiplayer migration testing

See [docs/MULTIPLAYER_TESTING.md](docs/MULTIPLAYER_TESTING.md) for replay and host smoke-test steps.

## Runtime multiplayer environment variables

- `BOM_MULTIPLAYER_MODE`: `off` (default), `headless`, or `websocket`.
- `BOM_PLAYER_NAME`: optional display name sent during handshake.
- `BOM_MATCH_ID`: optional match identifier override for local/headless setup.
- `BOM_MULTIPLAYER_URL`: required for websocket mode (e.g. `ws://127.0.0.1:8080`).

## Required runtime dependencies for websocket mode

Websocket multiplayer depends on Lua websocket modules in **both** places below:

1. **Client runtime (LÖVE app):** a module named `websocket` with `client.sync()` and a connection object that supports `connect`, `send`, and `receive`.
2. **Host runtime (`lua` process):** a module named `websocket.server.sync` exposing `listen(host, port)`.

If either dependency is missing:
- the client startup wiring falls back to local mode with an explicit reason, or
- the host launcher exits with `websocket_server_module_not_found`.

On Windows host startup, if you see `failed to start websocket host: websocket_server_module_not_found`, first try `luarocks install websocket`. If LuaRocks says no results for your current Lua, run `luarocks install websocket --check-lua-versions`, then install for a Lua version you actually have (for example `luarocks --lua-version=5.3 install websocket`). If LuaRocks reports `Could not find Lua <version> in PATH`, set it explicitly (example: `luarocks --lua-version=5.3 --local config variables.LUA C:\path\to\lua.exe`) and retry. Then verify: `lua -e "require('websocket.server.sync')"`.

### Host process helper (LAN / online)

For a networked authoritative host process, use:

```bash
BOM_HOST=0.0.0.0 BOM_PORT=8080 lua love2d/scripts/run_websocket_host.lua
```

Then point clients at `BOM_MULTIPLAYER_URL=ws://<host-ip>:8080`.

## Non-technical Windows guide

If you want a click-by-click setup for players/testers, use:

- [docs/WINDOWS_MULTIPLAYER_SETUP_NON_TECHNICAL.md](docs/WINDOWS_MULTIPLAYER_SETUP_NON_TECHNICAL.md)

## Windows multiplayer quick setup

### 1) Launch a multiplayer client from PowerShell

From the `love2d` folder:

```powershell
# Local authoritative host in-process
.\run_multiplayer.ps1 -Mode headless -PlayerName "PlayerA" -MatchId "lan-test"

# Remote websocket host
.\run_multiplayer.ps1 -Mode websocket -Url "ws://192.168.1.25:8080" -PlayerName "PlayerA" -MatchId "lan-test"
```

### 2) Launch a websocket host

From the `love2d` folder:

```powershell
# PowerShell
.\run_websocket_host.ps1 -Host 0.0.0.0 -Port 8080 -MatchId "lan-test"

# Command Prompt-safe wrapper (use this if `.ps1` opens in Notepad)
run_websocket_host.bat -Host 0.0.0.0 -Port 8080 -MatchId "lan-test"
```

### 3) Build a distributable Windows folder

From the `love2d` folder:

```powershell
.\build_windows.ps1 -GameName "BattlesOfMasadoria"
```

This creates `build/windows/` with:
- `BattlesOfMasadoria.love`
- `BattlesOfMasadoria.exe` (fused executable)
- required LÖVE runtime `.dll` files copied next to the executable.

## Remaining multiplayer setup checklist

To run reliable LAN/online matches outside local smoke tests, these items are still recommended:

- Install and package a websocket **client** Lua module for each target platform build (Windows/macOS/Linux).
- Install and package a websocket **server** Lua module for the host runtime used by `scripts/run_websocket_host.lua`.
- For internet play, run behind TLS/reverse proxy (`wss://`) and configure firewall/port-forwarding for the host endpoint.
- Add clear reconnect UX affordances (manual retry button + richer disconnected-state messaging).
- Add multiplayer session details UI (match id, player id/name, reconnect attempt telemetry).
- Finish command/event coverage + deterministic replay validation before broad online rollout.
