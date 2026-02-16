# Multiplayer Roadmap — Battles of Masadoria

This document outlines what is needed to make the LÖVE prototype work with **network multiplayer** (two players on different machines).

---

## 1. Current State (Single-Player / Hot-Seat)

- **Game state** is fully local in `src/game/state.lua` and `src/state/game.lua`.
- **Two players** exist in memory (`players[1]`, `players[2]`) with `activePlayer` (0 or 1).
- **All actions** go through `src/game/actions.lua` and already enforce “only active player can do X.”
- **Input** is local only; there is no networking or serialization.

So the game is already **two-player in logic**; what’s missing is **splitting that across two machines** and **keeping state in sync**.

---

## 2. High-Level Architecture

Recommended: **host-authoritative**.

- **Host** = one player’s game instance. It owns the canonical game state and validates every action.
- **Client** = the other player. Sends “I want to do action X”; host applies it (if valid) and sends back updated state (or the action result).
- **Flow:** Client input → send action request → Host runs action → Host sends state (or delta) to both sides → both render the same state.

Alternative (more work): **lockstep** — both run the same simulation and only exchange **action commands**; both must be deterministic (same RNG, same order). Your current design fits **state sync** more easily.

---

## 3. What You Need to Add

### 3.1 Network Transport

LÖVE does not ship with networking. You need a library, e.g.:

| Option | Pros | Cons |
|--------|------|------|
| **lua-enet** | UDP, low latency, reliability channels; common in LÖVE games | Need to add .dll/.so or use a LÖVE library that bundles it |
| **LuaSockets** (TCP) | Simple, widely used | Higher latency than UDP; you handle framing (message boundaries) |
| **LÖVE 11.x** | No built-in sockets; use FFI or a C module loaded via `require` | — |

Practical path: use a LÖVE-friendly **enet** binding (e.g. **lua-enet** or a LÖVE-specific wrapper) so one machine can **host** and the other **connect** by IP.

### 3.2 Session / Connection Flow

- **Main menu** (new state/screen) with:
  - **Host game** — start listening, show “Waiting for player…” and your IP (or use a relay/lobby).
  - **Join game** — enter host IP (and port), connect.
- **Role assignment:** e.g. Host = player 0, Joiner = player 1 (or let host choose “I’m player 1” and send that to client).
- **Start game** — once both are connected, host creates `create_initial_game_state()` and sends initial state to client; both transition to the game screen.

So you need:

- A **menu state** (or overlay) for “Host” / “Join” / “Back”.
- A small **network layer** that can:
  - Host: `listen(port)`, accept one peer.
  - Client: `connect(host, port)`.
  - Both: `send(data)`, `receive()` (or non-blocking poll).

### 3.3 Serialization: Game State and Actions

Both **game state** and **actions** must be sent over the wire.

- **State:** The table from `create_initial_game_state()` plus everything that changes (players’ resources, workers, board, hand, deck, `activePlayer`, `turnNumber`, `phase`, `activatedUsedThisTurn`, etc.). You can:
  - **Full state:** Serialize the whole state each time (simpler, more bandwidth). Use a format like **JSON** (e.g. `dkjson` or `cjson` for Lua) and only send fields that the other side needs (e.g. no internal Lua functions).
  - **Deltas:** Send only what changed (e.g. “player 1 resources: +2 wood”). Fewer bytes, more code.
- **Actions:** Represent each action as a **message**. For example:
  - `{ type = "end_turn" }`
  - `{ type = "assign_worker", resource = "wood" }`
  - `{ type = "unassign_worker", resource = "stone" }`
  - `{ type = "build_structure", card_id = "HUMAN_BARRACKS" }`
  - `{ type = "activate_ability", source = "base" }` or `{ type = "activate_ability", source = "board", board_index = 2, ability_index = 1 }`

The **host** receives these, checks that it’s the active player and the action is legal, then calls the existing `actions.*` functions. After that, host sends the **updated state** (or a “state delta”) to the client so both have the same view.

Important: **Decide which fields are “network state.”** Hand, deck, board, resources, workers, life, turn, phase, etc. All of these must be serializable (numbers, strings, arrays, no functions).

### 3.4 Action Entry Points (What to Send Over the Wire)

Every place that currently calls into `actions.*` must, in multiplayer, become a **message** that the client sends to the host (and only the host applies it). The host then broadcasts state (or the action) to the client.

| Current call (in `state/game.lua` or elsewhere) | Message to send (client → host) |
|---------------------------------------------------|----------------------------------|
| `actions.end_turn(g)` then `actions.start_turn(g)` | `{ type = "end_turn" }` |
| `actions.assign_worker_to_resource(g, pi, res)`   | `{ type = "assign_worker", resource = "wood" }` (etc.) |
| `actions.unassign_worker_from_resource(g, pi, res)` | `{ type = "unassign_worker", resource = "stone" }` |
| `actions.build_structure(g, player_index, card_id)` | `{ type = "build_structure", card_id = "<id>" }` |
| `actions.activate_ability(g, pi, card_def, source_key, ability_index)` | `{ type = "activate_ability", source = "base" }` or `source = "board", board_index = N, ability_index = M` |

Host logic:

1. Receive message.
2. Check `message.player_index == g.activePlayer` (or infer from connection: e.g. connection 0 = player 0).
3. Call the corresponding `actions.*` with host’s `g`.
4. Send updated state (or action + result) back to client(s).

So you need a small **action dispatcher** on the host: “if type == 'end_turn' then actions.end_turn(g); actions.start_turn(g); elseif type == 'assign_worker' then …”.

### 3.5 Input Routing (Who Can Send What)

- **Local player:** Only send actions when `g.activePlayer` matches “my” player index. When it’s the opponent’s turn, you only receive state updates; you don’t send actions (or host ignores them).
- **UI:** You can grey out or hide “End turn” and worker drag when it’s not your turn, or let the host reject invalid actions and show an error.

So in `state/game.lua` (or a thin “multiplayer” wrapper):

- If **single-player / hot-seat:** keep current behavior (both players can click; `actions.*` already enforce active player).
- If **network client:** on click, instead of calling `actions.end_turn(g)` directly, **send** `{ type = "end_turn" }` to the host. When state updates arrive, replace local `game_state` with the one from the host.

### 3.6 State Sync and Rendering

- **Host:** Runs the real game state; on each action, updates state and sends it (or a delta) to the client.
- **Client:** Holds a copy of the state. When it receives a state update, it **replaces** its local `game_state` with the received state. Both host and client render from their (same) state.

So you need:

- **Serialization:** `state_to_table(g)` and `table_to_state(t)` (or merge `t` into `g`) that only touch the fields that matter for gameplay. Be careful with **deck order** if you care about determinism later (e.g. for replays).
- **Deserialization:** Client must rebuild or merge state from the table (hands, boards, resources, etc.) so that `board.draw(game_state, …)` and the rest of the UI work unchanged.

### 3.7 Determinism (If You Ever Do Lockstep)

Not required for host-authoritative state sync, but if you later want lockstep (e.g. for replays or P2P):

- **RNG:** Replace `math.random` with a seeded RNG and send seed at game start; both sides use the same seed and call order.
- **Order:** All random choices (shuffle, draw) must happen in the same order on both machines. Right now only the host runs logic, so this is optional.

### 3.8 Disconnect / Reconnect

- **Client disconnects:** Host can pause and show “Opponent disconnected,” or treat as forfeit after a timeout.
- **Host disconnects:** Client loses connection; show “Host disconnected” and return to menu.
- **Reconnect:** Optional; would require saving session id and last state on host so a reconnecting client can resume (more work).

### 3.9 Cheating and Validation

With host-authoritative design, the **host** is the source of truth. The host must:

- Validate every action (same checks as in `actions.lua`: correct player, phase, enough resources, etc.).
- Never trust the client’s state; only apply validated actions and then send the resulting state.

So no extra “anti-cheat” is needed beyond “client sends intent, host applies rules.”

---

## 4. Suggested Order of Implementation

1. **Menu + network layer**  
   Add a main menu and a small module that can host or join (e.g. enet: listen / connect, send / receive bytes or strings).

2. **Serialize state**  
   Implement `state_to_table(g)` and `table_to_state(t)` (or merge) using a JSON library. Test by saving/loading state to a file and re-running the game.

3. **Action messages**  
   Define the set of action message types and, on the host, a dispatcher that calls `actions.*` from messages. Test locally (e.g. host in one window, client in another, or a simple “fake client” that sends messages in a loop).

4. **Host loop**  
   Host: when it’s player 0’s turn, only accept actions from the connection that represents player 0; when it’s player 1’s turn, only from player 1. After each applied action, send full state (or delta) to the client.

5. **Client loop**  
   Client: on input, send action message to host; in `love.update`, poll for incoming state and replace local `game_state`. Ensure UI only allows sending when it’s your turn.

6. **Polish**  
   Show “Waiting for opponent…”, “Your turn” / “Opponent’s turn”, connection status, and handle disconnect.

---

## 5. Files / Modules to Add (Summary)

| Addition | Purpose |
|----------|--------|
| **Network library** | lua-enet or LuaSockets (or similar) for listen/connect/send/receive |
| **Menu state** | `src/state/menu.lua` (or similar) — Host / Join / Quit |
| **Serialization** | `src/game/serialize.lua` (or in state.lua) — state ↔ table ↔ JSON |
| **Network session** | `src/network/session.lua` (or similar) — hold peer, send/receive, parse messages |
| **Action protocol** | Same file or `src/network/protocol.lua` — action message types and host-side dispatcher |
| **Integration in game state** | In `state/game.lua`: if “network client,” send actions and receive state instead of calling `actions.*` directly |

---

## 6. What Stays the Same

- **Game rules** in `src/game/actions.lua` and `src/game/abilities.lua` — unchanged; only the “caller” changes (host calls them, client sends messages).
- **Rendering** — `board.draw(game_state, …)` and the rest of the UI can stay as-is; they just read from the (synced) `game_state`.
- **Card definitions, config, factions** — no change; both sides load the same data.

---

## 7. Summary Checklist

- [ ] Choose and integrate a network library (e.g. lua-enet).
- [ ] Add a main menu with Host / Join.
- [ ] Implement state serialization (state ↔ JSON or similar).
- [ ] Define action message format and host-side action dispatcher.
- [ ] Host: accept connection, run game state, validate and apply actions, send state to client.
- [ ] Client: send action messages, receive state, replace local state, restrict input to “my turn.”
- [ ] Handle disconnect and basic UX (waiting, whose turn, errors).

Once these are in place, your existing two-player, turn-based logic will run as a two-machine multiplayer game.
