# Multiplayer Roadmap (Current)

This roadmap replaces the older pre-networking concept write-up.

The project already has a host-authoritative multiplayer foundation. The roadmap below focuses on reliability, tooling, and production readiness.

## Current Baseline (Already Working)

- Authoritative host simulation with validated commands
- Join/reconnect flows with session tokens
- Snapshot + push-based sync
- Version compatibility gates (protocol/rules/content)
- Deterministic visible-state checksums and `state_seq`
- Client-side desync detection hooks and reconnect/resync behavior
- Multiplayer UI status/reconnect diagnostics

## Priority Roadmap (Next Major Improvements)

### 1. Desync Tooling / Replay Diffing

Goal: make multiplayer issues easy to diagnose.

- Compare exported replay logs from host/client
- Identify first divergent command/hash/event
- Generate compact desync reports for bug triage

### 2. Zone-Wide Stable Card Instance IDs

Goal: remove index-shift fragility outside the board.

- Add persistent IDs for hand/deck/graveyard cards
- Support ID-based command payloads (with index fallback during migration)
- Improve reconnect/replay robustness

### 3. Continuous Effects v2

Goal: support more card growth without stat logic drift.

- Layered/static effect evaluation beyond `global_buff`
- Deterministic ordering
- Centralized derived stat recompute/invalidation

### 4. Multiplayer Reliability / Recovery

Goal: reduce disruptive reconnects.

- In-place snapshot resync before reconnect fallback
- Better reconnect controls and UX affordances
- Optional desync/debug artifact export

### 5. Testing Expansion

Goal: protect the growing engine/networking surface.

- Golden replay/hash sequence tests
- Host/client sync tests
- Additional adversarial and fuzz-style cases for command/reconnect flows

## Longer-Term (Production / Early Access)

- Telemetry and observability (disconnects, desync frequency, command errors)
- Release build/version automation
- TLS/hosting hardening and operational playbooks
- Match service abuse controls / rate limiting

## Notes

- The older "how to add networking at all" roadmap is obsolete and has been retired in favor of this current-state roadmap.
- For current test execution, use `MULTIPLAYER_TESTING.md`.
