# Multiplayer Migration Plan (MVP -> Early Access)

## Goal

Evolve the existing Love2D foundation into an Early Access-ready multiplayer architecture without a full rewrite.

This plan assumes:
- Keep the current Love2D client/UI foundation.
- Introduce authoritative simulation boundaries now.
- Add networking incrementally after deterministic command/reducer flow is stable.

---

## Target Architecture

## Current implementation progress

- ✅ Added centralized command execution boundary (`src/game/commands.lua`).
- ✅ Routed key gameplay flows in `state/game.lua` through command dispatch.
- ✅ Added structured command results with `ok`, `reason`, `meta`, and `events` payloads.
- ✅ Added replay-log schema support (`src/game/replay.lua`) with versioned metadata and deterministic command capture.
- ✅ Added protocol scaffolding (`src/net/protocol.lua`) for version-checked handshake and command submission envelopes.
- ✅ Added a headless authoritative host foundation (`src/net/host.lua`) with join flow, sequence validation, command execution, and replay capture.
- ✅ Added smoke-test scripts (`scripts/replay_smoke.lua`, `scripts/host_smoke.lua`) and a dedicated testing guide.
- ✅ Added in-client command logging (`GameState.command_log`) using replay schema metadata to seed replay/network sync work.

---

## 1) Core principles

1. **Single source of truth for rules**
   - Game legality and state transitions live in a pure simulation core.
   - UI never mutates game state directly.

2. **Command-based flow**
   - Inputs become commands (player intent).
   - Commands are validated and reduced into state changes.
   - Reducer emits events for UI/audio feedback and replay logs.

3. **Determinism first**
   - Given the same initial state + seed + command stream, outcomes must match exactly.

4. **Server authority for multiplayer**
   - Multiplayer clients submit commands.
   - Authoritative host/server validates + applies.
   - Clients render snapshots/events.

## 2) Runtime components

- **Core simulation module** (`src/game/*`)
  - State model
  - Command validator/executor
  - Reducer/actions

- **Client presentation module** (`src/state/*`, `src/ui/*`, `src/fx/*`)
  - Input mapping (click/drag -> command)
  - Visuals/audio/animations
  - Local prediction (optional later)

- **Networking layer** (future)
  - Match session/lobby
  - Command transport
  - Snapshot + event replication
  - Reconnect handling

---

## Phased implementation plan

## Phase 0 — Immediate hardening (current sprint)

1. Add a central command executor in game logic.
2. Route existing gameplay intents through commands (start/end turn, worker assignment, structure build, activated ability).
3. Return structured command results (`ok`, `reason`, optional metadata).
4. Keep UI behavior unchanged (sound/popup effects still in presentation layer).

**Deliverable:** The client no longer directly calls mutating action functions for primary gameplay operations.

## Phase 1 — Full command coverage + event output

1. Add command types for all player-facing actions (future combat, deck/hand actions, etc.).
2. Standardize result payload:
   - `ok`
   - `reason`
   - `events` (e.g., `resource_spent`, `worker_assigned`, `turn_started`)
3. Move one-off validation from UI into command validation.
4. Add lightweight replay log format:
   - `initial_seed`
   - timestamped command stream
   - version metadata

**Deliverable:** Replay-able deterministic local matches from command logs.

## Phase 2 — Determinism and testing

1. Define deterministic ordering rules for all triggered effects.
2. Add deterministic RNG wrapper module (seeded, explicit call sites only).
3. Create automated tests:
   - command legality tests
   - reducer transition tests
   - replay consistency tests
4. Freeze simulation API surface for networking.

**Deliverable:** CI tests that fail on desync/regression risk.

## Phase 3 — Authoritative multiplayer host

1. Stand up a headless host process using the same core modules.
2. Define protocol messages:
   - `join_match`
   - `submit_command`
   - `command_result`
   - `state_snapshot`
   - `resync`
3. Implement turn timers and disconnect/reconnect grace windows.
4. Maintain command index/sequence numbers.

**Deliverable:** Playable online 1v1 with host authority and rejoin support.

## Phase 4 — Early Access operations

1. Add compatibility/version gates (client build vs rules version).
2. Add telemetry hooks (match duration, disconnect rates, desync detection).
3. Build live balance pipeline (data patches + migration strategy).
4. Add anti-cheat safeguards (server-side rule validation only).

**Deliverable:** Production-ready Early Access multiplayer loop.

---

## Data and protocol versioning requirements

Before public multiplayer:

1. Add `rules_version` and `content_version` fields to match setup.
2. Add command schema version.
3. Add replay format version.
4. Reject mismatched clients at connect time with clear messaging.

---

## Suggested file evolution

Current repository can evolve with minimal disruption:

- `src/game/state.lua` (state model)
- `src/game/actions.lua` (low-level mutation helpers)
- `src/game/commands.lua` (**new** command validation + execution boundary)
- `src/state/game.lua` (maps UI interactions to commands)
- `docs/MULTIPLAYER_MIGRATION_PLAN.md` (this document)

Future additions:
- `src/net/*` for transport/protocol
- `src/game/events.lua` for reducer-emitted domain events
- `tests/*` for deterministic command/replay tests

---


## Next implementation targets (short-term)

1. Add headless host loop that consumes `protocol.submit_command` payloads and executes `commands.execute` authoritatively.
2. Add replay smoke test that replays a captured command log and verifies final state checksum.
3. Add command sequence/ack handling to prevent duplicate or out-of-order application.

---

## Immediate coding tasks (next 1-2 iterations)

1. Expand command coverage to every existing state mutation path.
2. Introduce event emission in command results.
3. Add first deterministic replay smoke test.
4. Add one small host-authority prototype endpoint/process.

---

## Risks and mitigations

1. **Risk:** UI code bypasses command layer.
   - **Mitigation:** Ban direct action mutation calls from UI state handlers.

2. **Risk:** Hidden nondeterminism (timers/random/order).
   - **Mitigation:** Determinism tests + explicit RNG abstraction.

3. **Risk:** Scope explosion before vertical slice ships.
   - **Mitigation:** Keep current MVP visuals; prioritize command/reducer and host loop.

4. **Risk:** Version drift during frequent balance patches.
   - **Mitigation:** Enforce content/rules version checks in match handshake.

---

## Definition of done for "multiplayer-ready foundation"

A foundation is considered ready when:

1. All gameplay mutations are command-driven.
2. A headless host can run the same simulation core.
3. Local replay of command logs is deterministic.
4. Clients can reconnect and resync from authoritative snapshots.
5. Version mismatches are detected and handled gracefully.
