# Battles of Masadoria — Love2D MVP

Same game loop and UI as the web prototype: two players (Human Wood+Stone vs Orc Food+Stone), bases, resource nodes, worker assignment via drag-and-drop, blueprint deck view, End turn / Start next.

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

### Websocket provider note

Websocket mode expects a runtime Lua module named `websocket` that exposes `client.sync()` and a connection with `connect/send/receive`. Startup now validates provider compatibility and falls back to local mode with an explicit reason when unavailable.


### Host process helper (LAN / online)

For a networked authoritative host process, use:

```bash
BOM_HOST=0.0.0.0 BOM_PORT=8080 lua love2d/scripts/run_websocket_host.lua
```

Then point clients at `BOM_MULTIPLAYER_URL=ws://<host-ip>:8080`.
