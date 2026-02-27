# Siegecraft (LOVE / LÖVE 2D)

Authoritative multiplayer-ready card game prototype built in Lua + LÖVE.

## Run The Game

Install LÖVE 11.x, then from the `love2d/` folder run one of:

- PowerShell: `.\run.ps1`
- Command Prompt: `run.bat`
- If `love` is on PATH: `love .`

## Core Controls

- Mouse-driven play (cards, workers, attacks, abilities)
- `Esc`
  - closes prompts/modals where applicable
  - if nothing is pending, opens the in-game settings overlay
- In-game settings overlay (via `Esc`) includes:
  - `Export Replay JSON`
  - `SFX Volume`
  - `Fullscreen`
  - `Return to Menu` (when available)
- `F8` (debug/dev): add resources for the local player

## Replay Export

- Open in-game settings with `Esc` (when no prompt/selection is active)
- Click `Export Replay JSON`
- File is written to the LÖVE save directory under `replays/`

Replay logs are format `v2` and include deterministic post-state hash telemetry for desync/debugging workflows.

## Testing

### Engine regression tests (recommended)

From repo root:

```bash
lua love2d/tests/engine_regression_tests.lua
```

### Multiplayer smoke tests

See `docs/MULTIPLAYER_TESTING.md` for the full list of smoke tests and manual checks.

## Multiplayer Runtime Modes

Configured via environment variables (or via in-game menu flows):

- `BOM_MULTIPLAYER_MODE`
  - `off` (default)
  - `headless` (in-process authoritative host service)
  - `websocket` (single-thread websocket client)
  - `threaded_websocket` (threaded websocket client; recommended runtime path for remote play)
- `BOM_PLAYER_NAME`
- `BOM_MATCH_ID`
- `BOM_MULTIPLAYER_URL` (required for websocket modes)

Current compatibility gates (`src/data/config.lua`):

- `protocol_version = 2`
- `rules_version = 0.1.1`
- `content_version = 0.1.1`

Both players must run compatible builds.

## Multiplayer Features (Current)

- Host-authoritative command execution
- Session-token auth + reconnect support
- Snapshot/push resync flows
- Deterministic visible-state checksums
- Authoritative `state_seq` tracking
- Client-side optimistic hash comparison + desync-triggered resync/reconnect
- Improved disconnect cause reporting/reconnect diagnostics

## Websocket / Online Multiplayer Dependencies

See `docs/MULTIPLAYER_DEPENDENCIES.md` for installation and verification steps.

Non-technical setup guide:

- `docs/WINDOWS_MULTIPLAYER_SETUP_NON_TECHNICAL.md`

## Useful Scripts

From `love2d/`:

- `.\install_multiplayer_dependencies.ps1`
- `.\run_multiplayer.ps1 ...`
- `.\run_websocket_host.ps1 ...`
- `.\build_windows.ps1 -GameName "Siegecraft"`

From repo root:

- `lua love2d/scripts/host_smoke.lua`
- `lua love2d/scripts/runtime_multiplayer_smoke.lua`
- `lua love2d/scripts/websocket_host_service_smoke.lua`

## Documentation Map

- `PROJECT_OUTLINE.md` - historical MVP outline (now archived/reference)
- `docs/ALPHA_RULES_BRIEF.md` - short playtester rules summary for the current alpha build
- `docs/MULTIPLAYER_MIGRATION_PLAN.md` - migration history + current status notes
- `docs/MULTIPLAYER_ROADMAP.md` - roadmap archive + current focus
- `docs/GAME_DESIGN.md` - design target / rules intent (not exact implementation contract)
