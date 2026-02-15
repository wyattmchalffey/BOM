# Multiplayer Migration Testing Guide

This guide covers practical test steps for the current multiplayer foundation.

## Prerequisites

1. Lua 5.3+ installed and available as `lua`.
2. (Optional) LÖVE 11.x for running the game client UI.
3. For websocket-mode tests and runtime checks, install websocket Lua modules:
   - client side: module `websocket` with `client.sync()`
   - host side: module `websocket.server.sync` with `listen()`

## 0) Preflight multiplayer setup sanity check

From repository root, confirm no obvious merge artifacts are present in docs/scripts:

```bash
rg -n "^(<<<<<<<|=======|>>>>>>>|@@ )" love2d
```

Expected output: no matches.

## 1) Run deterministic replay smoke test

From repository root:

```bash
lua love2d/scripts/replay_smoke.lua
```

Expected output:

```text
Replay smoke test passed
```

This validates:
- command log creation,
- replay re-execution,
- final state checksum consistency for a known sequence.

## 2) Run authoritative host smoke test

From repository root:

```bash
lua love2d/scripts/host_smoke.lua
```

Expected output:

```text
Host smoke test passed
```

This validates:
- handshake version compatibility,
- player slot join flow,
- sequence-checked command submission,
- out-of-order sequence rejection,
- replay entry capture on host side.

## 3) Run loopback client-session smoke test

From repository root:

```bash
lua love2d/scripts/loopback_session_smoke.lua
```

Expected output:

```text
Loopback session smoke test passed
```

This validates:
- client session handshake, join assignment, and reconnect via session token,
- sequence continuity across reconnect (no seq reset to 1),
- client -> transport -> host command path,
- sequence progression and command acks,
- snapshot + checksum retrieval for resync workflows,
- checksum-mismatch handling via `resync_required` and client session auto-resync helper.

## 4) Run websocket-ready transport smoke test

From repository root:

```bash
lua love2d/scripts/websocket_transport_smoke.lua
```

Expected output:

```text
Websocket transport smoke test passed
```

This validates:
- host gateway request routing (`connect`, `reconnect`, `submit`, `snapshot`),
- websocket-ready transport request/response contract,
- compatibility with `client_session` reconnect + resync helpers over a transport boundary.

## 5) Run websocket JSON + client-wrapper smoke test

From repository root:

```bash
lua love2d/scripts/websocket_json_client_smoke.lua
```

Expected output:

```text
Websocket JSON client smoke test passed
```

This validates:
- JSON encode/decode framing around transport request/response payloads,
- `websocket_client` provider wrapper compatibility with `websocket_transport`,
- end-to-end connect/submit/resync/retry flow using framed payloads.

## 6) Run websocket transport error-handling smoke test

From repository root:

```bash
lua love2d/scripts/websocket_transport_error_smoke.lua
```

Expected output:

```text
Websocket transport error smoke test passed
```

This validates:
- encode/send/receive/decode failure normalization to protocol `error` messages,
- non-crashing behavior for transport boundary failures,
- explicit `reason` codes for client-session level handling/logging.

## 7) Run headless host service smoke test

From repository root:

```bash
lua love2d/scripts/headless_host_service_smoke.lua
```

Expected output:

```text
Headless host service smoke test passed
```

This validates:
- framed JSON service boundary (`headless_host_service`) over host gateway,
- client-session compatibility across a process/network-style request/response boundary,
- connect/submit/resync/retry flow without direct in-process host calls.

## 8) Run authoritative client adapter smoke test

From repository root:

```bash
lua love2d/scripts/authoritative_client_game_smoke.lua
```

Expected output:

```text
Authoritative client game smoke test passed
```

This validates:
- a client-facing authoritative adapter that syncs host snapshots after command submit,
- compatibility between `client_session` and process/network-style host service boundaries,
- command submission + resync-required retry handling while maintaining a client-side snapshot cache.

## 9) Run runtime multiplayer wiring smoke test

From repository root:

```bash
lua love2d/scripts/runtime_multiplayer_smoke.lua
```

Expected output:

```text
Runtime multiplayer smoke test passed
```

This validates:
- runtime builder wiring for in-process headless authoritative mode,
- end-to-end connect + submit through `runtime_multiplayer`-constructed adapter,
- client snapshot availability after authoritative command execution.

## 10) Run websocket provider compatibility smoke test

From repository root:

```bash
lua love2d/scripts/websocket_provider_smoke.lua
```

Expected output:

```text
Websocket provider smoke test passed
```

This validates:
- websocket provider contract normalization (`send`/`receive` or `send_text`/`receive_text`),
- module-based provider resolution path used by runtime startup wiring.

## 11) Run runtime reconnect smoke test

From repository root:

```bash
lua love2d/scripts/runtime_multiplayer_reconnect_smoke.lua
```

Expected output:

```text
Runtime multiplayer reconnect smoke test passed
```

This validates:
- runtime-built authoritative adapter reconnect behavior,
- reconnect after local session disconnect without rebuilding transport wiring,
- command submission continuity after reconnect.

## 12) Run websocket host service smoke test

From repository root:

```bash
lua love2d/scripts/websocket_host_service_smoke.lua
```

Expected output:

```text
Websocket host service smoke test passed
```

This validates:
- network host loop provider contract (`listen`/`accept`/`receive_text`/`send_text`),
- frame dispatch from websocket host boundary into authoritative frame handler.

## 13) Run conflict-marker smoke test

From repository root:

```bash
lua love2d/scripts/conflict_marker_smoke.lua
```

Expected output:

```text
Conflict marker smoke test passed
```

This validates:
- no unresolved Git merge markers are present in `.lua` and `.md` files under `love2d/`,
- branch merges did not leave conflict artifacts that break Lua parsing.

## 14) Manual protocol checks in REPL (optional)

Open Lua REPL in repo root:

```bash
lua
```

Then:

```lua
package.path = table.concat({
  "love2d/?.lua",
  "love2d/?/init.lua",
  "love2d/src/?.lua",
  "love2d/src/?/init.lua",
  package.path,
}, ";")

local protocol = require("src.net.protocol")

print(protocol.validate_submit_command({
  type = "submit_command",
  protocol_version = protocol.VERSION,
  match_id = "m1",
  seq = 1,
  command = { type = "END_TURN" },
}).ok)
```

Expected output: `true`.

## 15) Run game client (optional UI sanity)

From `love2d/`:

```bash
love .
```

This confirms command-driven local flow; set `BOM_MULTIPLAYER_MODE=headless` for local authoritative wiring or `BOM_MULTIPLAYER_MODE=websocket` + `BOM_MULTIPLAYER_URL=ws://...` for remote wiring (requires a websocket provider module at runtime).

## Notes

- `src/net/websocket_transport.lua` is adapter-based: inject a real websocket client and encode/decode functions (for example JSON) to move from in-memory smoke to real network transport.
- `src/net/websocket_client.lua` wraps provider-specific websocket connections behind the transport client contract.
- `src/net/json_codec.lua` provides minimal JSON framing utilities for transport payloads.
- `src/net/headless_host_service.lua` exposes host/gateway as framed JSON for process/network boundaries.
- `scripts/run_headless_host.lua` runs the headless host service over stdin/stdout lines.
- `src/net/websocket_host_service.lua` provides a provider-driven network host loop for websocket frame handling.
- `scripts/run_websocket_host.lua` runs a websocket-facing authoritative host process (requires websocket server module).
- `src/net/authoritative_client_game.lua` is a client adapter that keeps local state in sync via authoritative snapshots.
- `src/net/runtime_multiplayer.lua` builds authoritative adapters for runtime headless/websocket mode selection.
- `src/net/protocol.lua` and `src/net/host.lua` are transport-agnostic foundations for future socket/websocket integration.
- For CI, add all smoke scripts as required checks once Lua is installed in the build environment.
