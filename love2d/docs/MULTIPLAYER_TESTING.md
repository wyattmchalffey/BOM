# Multiplayer Testing Guide (Current)

Updated for the current authoritative multiplayer foundation, deterministic checksum/desync detection, and replay export tooling.

## Version Compatibility (Important)

Current compatibility gates (`src/data/config.lua`):

- `protocol_version = 2`
- `rules_version = 0.1.1`
- `content_version = 0.1.1`

Use matching builds on both machines when testing multiplayer.

## Recommended Test Order

1. Engine regression suite (fast, broad coverage)
2. Core smoke tests (host/session/runtime)
3. Websocket/relay smoke tests (if testing online transport)
4. Manual two-client playtest (including reconnect/desync scenarios)

## 1) Engine Regression Suite (Repo Root)

```bash
lua love2d/tests/engine_regression_tests.lua
```

What this covers (examples):

- effect args schema validation
- command/action regressions
- stable instance IDs / once-per-turn tracking across index shifts
- continuous buff recalculation
- deterministic checksum behavior
- replay hash telemetry
- host checksum/state sequence metadata behavior

## 2) Core Multiplayer Smoke Tests (Repo Root)

Run these first for host/session/adapter coverage:

```bash
lua love2d/scripts/replay_smoke.lua
lua love2d/scripts/host_smoke.lua
lua love2d/scripts/loopback_session_smoke.lua
lua love2d/scripts/headless_host_service_smoke.lua
lua love2d/scripts/authoritative_client_game_smoke.lua
lua love2d/scripts/runtime_multiplayer_smoke.lua
lua love2d/scripts/runtime_multiplayer_reconnect_smoke.lua
```

Useful additional correctness smokes:

```bash
lua love2d/scripts/hidden_info_redaction_smoke.lua
lua love2d/scripts/command_result_semantics_smoke.lua
lua love2d/scripts/terminal_state_smoke.lua
lua love2d/scripts/deck_legality_smoke.lua
lua love2d/scripts/upkeep_smoke.lua
lua love2d/scripts/summoning_sickness_smoke.lua
lua love2d/scripts/conflict_marker_smoke.lua
```

## 3) Websocket / Transport / Relay Smoke Tests (Repo Root)

Use these when validating websocket provider behavior, host services, or relay integration:

```bash
lua love2d/scripts/websocket_transport_smoke.lua
lua love2d/scripts/websocket_transport_error_smoke.lua
lua love2d/scripts/websocket_json_client_smoke.lua
lua love2d/scripts/websocket_provider_smoke.lua
lua love2d/scripts/websocket_provider_raw_fallback_smoke.lua
lua love2d/scripts/websocket_provider_secure_retry_smoke.lua
lua love2d/scripts/websocket_host_service_smoke.lua
lua love2d/scripts/relay_host_bridge_smoke.lua
lua love2d/scripts/relay_host_bridge_push_routing_smoke.lua
lua love2d/scripts/websocket_transport_relay_control_smoke.lua
```

Optional live `wss://` probe (requires network + SSL runtime support):

```bash
lua love2d/scripts/wss_real_connection_smoke.lua
```

## 4) Manual Two-Client Test (Recommended)

### Local Headless Authoritative (single machine / quick sanity)

From `love2d/`:

```powershell
.\run_multiplayer.ps1 -Mode headless -PlayerName "P1" -MatchId "smoke-headless"
```

### Websocket Host + Two Clients (LAN)

Host process (`love2d/`):

```powershell
.\run_websocket_host.ps1 -Host 0.0.0.0 -Port 8080 -MatchId "lan-test"
```

Clients (`love2d/`, separate terminals/machines):

```powershell
.\run_multiplayer.ps1 -Mode websocket -Url "ws://HOST_IP:8080" -PlayerName "P1" -MatchId "lan-test"
.\run_multiplayer.ps1 -Mode websocket -Url "ws://HOST_IP:8080" -PlayerName "P2" -MatchId "lan-test"
```

### What To Verify Manually

- Both clients connect with no version mismatch errors
- Turn flow works across both players
- Reconnect flow preserves disconnect cause text
- No random disconnects during longer idle and active play
- Active abilities / spell targeting work for both players
- `Esc` opens in-game settings when no prompt is pending
- `Export Replay JSON` writes a file under the LÖVE save directory

## Desync / Disconnect Debugging Checklist

If a client enters reconnect flow:

1. Capture the exact `Cause: ...` text from the reconnect status box.
2. Export replay JSON from both players (if possible) via `Esc -> Export Replay JSON`.
3. Note which command/action immediately preceded the issue.
4. Confirm both clients are on the same build (`protocol/rules/content`).

Current multiplayer instrumentation includes:

- deterministic visible-state checksums
- authoritative `state_seq`
- optimistic local-vs-authoritative hash mismatch detection
- push-payload checksum verification

## Notes

- Some docs in `docs/` are historical planning references. Use this file and `love2d/README.md` for current testing workflow.
- For dependency setup, see `docs/MULTIPLAYER_DEPENDENCIES.md`.
