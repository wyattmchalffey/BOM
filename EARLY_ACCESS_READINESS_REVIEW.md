# Battles of Masadoria - Early Access Readiness Review

Date: 2026-02-20  
Scope reviewed: `love2d/`, `relay/`, root build/deploy docs/scripts

## Status Update (2026-02-25)

This document is a point-in-time review from 2026-02-20. Several items listed below have already been addressed or partially addressed since then.

### Confirmed Progress Since This Review

- Hidden-information redaction is implemented in the host snapshot/push/submit flow (the original `C1` finding is no longer current).
- Submit identity is session-token bound in the host/protocol flow (the original `C2` finding is no longer current).
- `START_TURN` is host-internal and command/auth flow has been hardened (the original `C3` exploit path is no longer current).
- Terminal match flow/UI exists (`is_terminal`, winner/reason handling in gameplay + UI).
- Deterministic canonical state hashing replaced the earlier weak checksum implementation.
- Replay logs now include deterministic state hash telemetry, and replay export is available in-game (`Esc -> Settings -> Export Replay JSON`).
- Multiplayer reconnect diagnostics and desync detection are significantly improved (`state_seq`, visible-state checksums, optimistic/push hash mismatch detection).

### Still Useful In This Review

- Production readiness framing and milestone guidance
- TLS verification concerns for internet play
- Operational hardening recommendations (telemetry, abuse controls, CI breadth)
- Release/build pipeline and Early Access launch process guidance

Use this document as a strategic review reference, not a current bug list.

## Executive Summary

The project is moving in the right architectural direction for a PvP TCG:
- command-driven simulation boundary exists
- host-authoritative multiplayer foundation exists
- reconnect/resync scaffolding exists
- smoke-test culture exists

The current build is **not yet ready** for Steam Early Access multiplayer because there are critical competitive integrity and security blockers.

---

## Review Method

- Static code review of gameplay, networking, menu/runtime wiring, and deployment files.
- Verification against existing smoke tests (`love2d/scripts/*_smoke.lua`).
- Additional targeted exploit checks (session spoofing, turn flow abuse, hidden info leakage).

Smoke tests currently pass for happy-path flow, but critical adversarial cases are not covered.

---

## Full Findings

## Critical Findings (must fix before any public competitive release)

### C1. Hidden Information Leak (opponent hand/deck/secret state)

- Problem:
  - Full authoritative state is returned in submit ACKs, snapshots, and pushes.
  - Any client can inspect opponent hidden zones directly.
- Why it matters:
  - This is a game-breaking cheat vector for a TCG.
- Evidence:
  - `love2d/src/net/host.lua:285`
  - `love2d/src/net/host.lua:333`
  - `love2d/src/net/host.lua:345`
- Required fix:
  - Build `redact_state_for_player(state, player_index)` and only send redacted views.
  - Keep full state server-side only.
  - Never transmit opponent hand/deck order unless revealed by rules.

### C2. Command Authentication Not Bound to Session Identity

- Problem:
  - Submit path trusts `player_index` from request framing.
  - Session token is used for reconnect but not enforced on submit.
  - A crafted client can submit as another player.
- Why it matters:
  - Player impersonation and turn theft are possible.
- Evidence:
  - `love2d/src/net/host_gateway.lua:45`
  - `love2d/src/net/protocol.lua:71`
  - `love2d/src/net/host.lua:217`
- Required fix:
  - Bind connection/session identity server-side.
  - Remove client-controlled submit `player_index` as authority source.
  - Validate submit against authenticated session token.

### C3. Command Surface Exploits (turn/economy cheating)

- Problem:
  - `START_TURN` can be submitted repeatedly for repeated worker/resource gain.
  - `END_TURN` path does not enforce active player in command layer.
  - `DEBUG_ADD_RESOURCE` is reachable and also mapped to `F8`.
- Why it matters:
  - Direct game-state cheating with minimal effort.
- Evidence:
  - `love2d/src/game/commands.lua:72`
  - `love2d/src/game/commands.lua:83`
  - `love2d/src/game/commands.lua:116`
  - `love2d/src/state/game.lua:2316`
- Required fix:
  - Make `START_TURN` server-internal only.
  - Enforce active-player check for `END_TURN` in command validation.
  - Remove `DEBUG_ADD_RESOURCE` in non-dev builds (and ideally from production command schema entirely).

---

## High Findings (should be fixed before Early Access launch candidate)

### H1. Invalid Faction Payload Can Break/Poison Lobby Start

- Problem:
  - Host stores client faction input without strict validation.
  - Invalid faction can cause game start failure and leave lobby in bad state.
- Evidence:
  - `love2d/src/net/host.lua:145`
  - `love2d/src/net/host.lua:160`
  - `love2d/src/game/state.lua:65`
  - `love2d/src/game/cards.lua:18`
- Required fix:
  - Whitelist faction values at handshake and reject invalid payloads cleanly.
  - Add robust error return path (do not partially reserve slot on invalid config).

### H2. TLS Verification Disabled (`verify = "none"`)

- Problem:
  - Multiple network paths disable cert verification.
- Why it matters:
  - Susceptible to MITM and traffic tampering.
- Evidence:
  - `love2d/src/net/websocket_provider.lua:107`
  - `love2d/src/net/threaded_client_adapter.lua:67`
  - `love2d/src/net/threaded_relay.lua:79`
  - `love2d/src/net/room_list_fetcher.lua:46`
- Required fix:
  - Enable proper certificate verification in production builds.
  - Keep insecure mode only for explicit local/dev override.

### H3. No Explicit Match-End/Winner Flow

- Problem:
  - Base life is reduced in combat, but no clear game-over state machine and UX flow was found.
- Evidence:
  - `love2d/src/game/combat.lua:461`
  - `love2d/src/game/combat.lua:484`
- Required fix:
  - Add terminal match state (`winner`, `reason`, `ended_at_turn`).
  - Block further command mutation after terminal state.
  - Add post-game UI flow.

---

## Medium Findings (important for production quality and scale)

### M1. Checksum Too Weak for Reliable Desync Detection

- Problem:
  - Checksum mostly includes counts, not full card identity/order/state fidelity.
  - Distinct game states can collide.
- Evidence:
  - `love2d/src/game/checksum.lua`
- Required fix:
  - Use canonical serialized state hashing (for relevant zones/fields).
  - Include deck/hand/board identities and relevant per-card state.

### M2. Some Commands Can Return Success Without Mutation

- Problem:
  - Certain command paths return `ok` even if action function no-ops.
- Evidence:
  - `love2d/src/game/commands.lua:262`
  - `love2d/src/game/commands.lua:270`
  - `love2d/src/game/actions.lua:370`
  - `love2d/src/game/actions.lua:400`
- Required fix:
  - Return explicit failure when no legal mutation occurred.
  - Ensure UI/network semantics are consistent.

### M3. Deck Builder / Collection Loop Not Yet a Real TCG Flow

- Problem:
  - UI currently selects faction only; no robust deck construction/validation flow.
  - Server still builds deck from faction pool defaults.
- Evidence:
  - `love2d/src/state/menu.lua:273`
  - `love2d/src/net/host.lua:176`
  - `love2d/src/game/state.lua:81`
- Required fix:
  - Implement decklist persistence, legality rules, and server-side validation.

---

## Low Findings (cleanup and maintainability)

### L1. Repo Hygiene and Build Artifacts in Source

- Problem:
  - Tracked binaries and vendored dependencies increase churn/noise.
- Evidence:
  - `.gitignore`
  - tracked `love2d/build/windows/*`
  - tracked `relay/node_modules/*`
- Required fix:
  - Improve ignore/release artifact policy and CI artifact publishing.

---

## What Is Already Good (keep and build on this)

- Command boundary exists (`src/game/commands.lua`) and is broadly wired.
- Host-authoritative headless service and gateway are in place.
- Replay/log/checksum structure exists.
- Reconnect/resync paths exist.
- Many smoke tests already cover core happy-path networking behavior.

---

## Step-by-Step Implementation Guide to Early Access

This sequence is ordered to reduce risk and avoid rework.

## Phase 0 - Security and Competitive Integrity Lockdown

Goal: remove all trivial cheating vectors first.

### Step 1. Lock submit identity to authenticated session

- Implement:
  - Add session token requirement on submit path.
  - Map submit requests to server-side session identity.
  - Ignore any client-provided `player_index` as an authority source.
- Files:
  - `love2d/src/net/protocol.lua`
  - `love2d/src/net/host_gateway.lua`
  - `love2d/src/net/host.lua`
  - `love2d/src/net/client_session.lua`
- Done when:
  - Forged submit-as-opponent test fails as expected.
  - Valid session submits continue working.

### Step 2. Redact authoritative state per viewer

- Implement:
  - Add `redact_state_for_player(state, viewer_index)`.
  - Apply redaction for submit ACK payloads, snapshots, and pushes.
- Files:
  - `love2d/src/net/host.lua`
  - `love2d/src/net/headless_host_service.lua` (if needed for wrapper payload shaping)
- Done when:
  - A client cannot inspect opponent hand/deck from any protocol message.
  - Gameplay still functions correctly.

### Step 3. Remove/guard debug mutation paths

- Implement:
  - Remove `DEBUG_ADD_RESOURCE` from production command handling.
  - Gate any debug command behind compile-time or explicit dev flag.
  - Remove `F8` debug hotkey in production.
- Files:
  - `love2d/src/game/commands.lua`
  - `love2d/src/state/game.lua`
- Done when:
  - Debug economy mutation cannot be triggered in release builds.

### Step 4. Seal turn/match mutation rules

- Implement:
  - Make `START_TURN` host-internal only.
  - Require active player for `END_TURN`.
  - Audit all command paths for player/phase legality.
- Files:
  - `love2d/src/game/commands.lua`
  - `love2d/src/net/host.lua`
- Done when:
  - Repeated `START_TURN` exploit fails.
  - Non-active player `END_TURN` fails.

---

## Phase 1 - Core Match Completeness

Goal: complete minimum viable competitive loop.

### Step 5. Add robust match terminal state (win/loss/draw)

- Implement:
  - Add game-over state in simulation (`is_terminal`, `winner`, `reason`).
  - Prevent any non-allowed commands after terminal.
  - Add in-game result screen and return flow.
- Files:
  - `love2d/src/game/state.lua`
  - `love2d/src/game/combat.lua`
  - `love2d/src/game/commands.lua`
  - `love2d/src/state/game.lua`
- Done when:
  - Base reaches 0 -> deterministic winner flow -> no further gameplay commands.

### Step 6. Faction/deck payload validation

- Implement:
  - Strict faction whitelist and deck schema validation on connect.
  - Reject invalid setup cleanly without reserving slot.
- Files:
  - `love2d/src/net/host.lua`
  - `love2d/src/net/protocol.lua`
  - `love2d/src/game/state.lua`
- Done when:
  - Invalid faction/deck cannot poison match startup.

### Step 7. Implement actual deck builder + deck legality

- Implement:
  - Save/load decklists per faction/profile.
  - Enforce population and rules legality server-side.
  - Join/start uses submitted legal decklist, not auto-generated faction pool only.
- Files:
  - `love2d/src/state/menu.lua`
  - `love2d/src/game/state.lua`
  - `love2d/src/net/host.lua`
  - new modules under `love2d/src/game/` for deck validation
- Done when:
  - Player can build/select deck, server validates it, match starts with that deck.

### Step 8. Harden command result semantics

- Implement:
  - Ensure commands fail when no state mutation occurs.
  - Standardize result reasons/events for UX and debugging.
- Files:
  - `love2d/src/game/commands.lua`
  - `love2d/src/game/actions.lua`
- Done when:
  - Command outcomes are unambiguous and testable.

---

## Phase 2 - Determinism, Testing, and Anti-Cheat Operations

Goal: make online matches trustworthy under load and adversarial behavior.

### Step 9. Upgrade desync checksum fidelity

- Implement:
  - Canonical serialization + stable hash across relevant state.
  - Include hidden-zone identity/order on server side (for desync checks), with redacted transport view.
- Files:
  - `love2d/src/game/checksum.lua`
  - possibly new `love2d/src/game/serialize.lua`
- Done when:
  - Intentionally altered hidden card identity changes checksum.

### Step 10. Add adversarial test suite

- Implement tests for:
  - submit impersonation attempt
  - repeated `START_TURN`
  - non-active `END_TURN`
  - hidden-info leak checks
  - invalid faction/deck handshake
  - reconnect with stale seq/checksum
- Files:
  - add scripts under `love2d/scripts/` or move to formal test runner
- Done when:
  - These tests fail on old behavior and pass on fixed behavior.

### Step 11. Add CI pipeline

- Implement:
  - Automated run of all smoke + adversarial tests on push/PR.
  - Fail build on regression.
- Files:
  - add `.github/workflows/` (or your CI system equivalent)
- Done when:
  - Every change is validated before merge.

### Step 12. Add rate limits/timeouts/abuse controls

- Implement:
  - Per-client submit rate limits.
  - Invalid-command strike handling.
  - Connection idle and reconnect grace windows.
- Files:
  - `love2d/src/net/host.lua`
  - `relay/server.js`
- Done when:
  - Basic flood/abuse does not destabilize match service.

---

## Phase 3 - Production Networking and Client Reliability

Goal: internet-safe operation for real users.

### Step 13. Fix TLS verification strategy

- Implement:
  - Production default must verify certificates.
  - Add explicit local-dev insecure override flag only.
- Files:
  - `love2d/src/net/websocket_provider.lua`
  - `love2d/src/net/threaded_client_adapter.lua`
  - `love2d/src/net/threaded_relay.lua`
  - `love2d/src/net/room_list_fetcher.lua`
- Done when:
  - Production cannot connect with invalid cert chain.

### Step 14. Improve reconnect UX and match continuity

- Implement:
  - Clear reconnect states and countdowns in UI.
  - Rejoin token lifecycle and timeout policy.
  - Optional forfeit on extended disconnect.
- Files:
  - `love2d/src/state/game.lua`
  - `love2d/src/net/client_session.lua`
  - `love2d/src/net/host.lua`
- Done when:
  - Expected reconnect flow is predictable and user-visible.

### Step 15. Telemetry and observability

- Implement:
  - Match metrics: duration, disconnect rates, command error rates, desync frequency.
  - Relay/host logs with correlation ids (match_id, player_index/session).
- Files:
  - `love2d/src/net/host.lua`
  - `relay/server.js`
- Done when:
  - You can answer "what failed?" with production data.

---

## Phase 4 - Steam Early Access Productization

Goal: ship-ready distribution and live ops.

### Step 16. Build/release pipeline hardening

- Implement:
  - Reproducible build scripts for target platforms.
  - Separate release artifacts from source control history.
  - Version stamping (client build, rules version, content version).
- Files:
  - `love2d/build_windows.ps1`
  - release scripts + CI pipeline
- Done when:
  - One command/tag can generate release artifacts consistently.

### Step 17. Steam integration plan

- Implement:
  - Steam app bootstrap, depots, and branch strategy.
  - At minimum: account identity linkage, crash handling, patch rollout process.
  - Optional but high value: Steam invites/lobbies if replacing custom browse UX later.
- Done when:
  - Internal Steam branch supports install/update/play/report loop.

### Step 18. Policy/compliance readiness

- Implement:
  - Privacy policy and telemetry disclosure.
  - EULA / Terms and moderation/reporting policy for online play.
- Done when:
  - Store page and in-game policy references are complete and accurate.

### Step 19. Closed beta gate before EA

- Implement:
  - Small external test cohort.
  - Track crash-free session %, match completion %, reconnect success %.
- Done when:
  - Metrics hit your launch thresholds for at least 1-2 weeks.

### Step 20. Early Access launch checklist

- Required green checks:
  - no known command/auth cheat path
  - hidden info redaction complete
  - deterministic terminal match flow
  - automated CI test coverage for critical paths
  - production TLS verification
  - telemetry and incident response playbook

---

## Suggested Milestone Order (Practical)

1. Milestone A (2-3 weeks): C1/C2/C3 + H1 fixed, adversarial tests added.
2. Milestone B (2-4 weeks): terminal match flow, deck legality/builder baseline.
3. Milestone C (2-3 weeks): TLS hardening, reconnect UX, observability.
4. Milestone D (2-4 weeks): release automation + Steam branch dry run + closed beta.

---

## Recommended Immediate Backlog (start next)

1. Implement submit auth binding and state redaction.
2. Remove debug command/hotkey from production path.
3. Add exploit tests proving those fixes.
4. Add terminal match-state flow.
5. Add faction/deck handshake validation and safe failure handling.
