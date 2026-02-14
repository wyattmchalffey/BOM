# Multiplayer Migration Testing Guide

This guide covers practical test steps for the current multiplayer foundation.

## Prerequisites

1. Lua 5.3+ installed and available as `lua`.
2. (Optional) LÖVE 11.x for running the game client UI.

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
- client -> transport -> host command path,
- sequence progression and command acks,
- snapshot + checksum retrieval for resync workflows.
- checksum-mismatch handling via `resync_required` and client session auto-resync helper.

## 4) Manual protocol checks in REPL (optional)

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

## 5) Run game client (optional UI sanity)

From `love2d/`:

```bash
love .
```

This does not yet connect to remote transport, but confirms command-driven local flow still runs.

## Notes

- `src/net/protocol.lua` and `src/net/host.lua` are transport-agnostic foundations for future socket/websocket integration.
- For CI, add both smoke scripts as required checks once Lua is installed in the build environment.
