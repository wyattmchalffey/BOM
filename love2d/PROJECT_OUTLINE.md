# Battles of Masadoria — Love2D MVP Outline

## 1. Prerequisites & Setup

- **Install LÖVE 11.x** (https://love2d.org/). On Windows: download installer, add to PATH if desired.
- **Run the project:** from the `love2d` folder run:
  ```bash
  love .
  ```
  Or drag the `love2d` folder onto `love.exe`.
- **Project root:** The folder containing `main.lua` and `conf.lua` is the game root. All `require()` paths are relative to that root.

---

## 2. Project Structure

```
love2d/
  conf.lua              # LÖVE config: window size, title, etc.
  main.lua              # Entry point: load, update, draw; delegates to current "state"
  PROJECT_OUTLINE.md    # This file

  src/
    state/
      game.lua          # In-game screen: holds game state, draws board, handles input
    game/
      state.lua         # Game state representation (players, resources, turn, workers)
      actions.lua       # Pure functions: start_turn, end_turn, assign_worker, unassign_worker
      cards.lua         # Card definitions (bases, resource nodes, structures)
    ui/
      card_frame.lua    # Draw one card (frame, title, type line, art box, text, stats, population)
      board.lua         # Draw both player panels, bases, resource nodes, worker tokens
      blueprint_modal.lua # Blueprint deck view (list of structure cards)
    util.lua            # Helpers: clamp, deep copy, etc.
```

- **conf.lua:** Window size (e.g. 1280x720), title "Battles of Masadoria".
- **main.lua:** On `love.load()` set current state to game state. In `love.update(dt)` and `love.draw()` call into current state. In `love.mousepressed`, `love.mousemoved`, etc., delegate to state so the game screen can handle clicks and drags.
- **game/state.lua:** Tables for game state: `players` (each with `faction`, `life`, `resources`, `totalWorkers`, `workersOn`, `baseId`), `activePlayer`, `turnNumber`, `phase`. Function `create_initial_game_state()`.
- **game/actions.lua:** `start_turn(state)`, `end_turn(state)`, `assign_worker_to_resource(state, player_idx, resource)`, `unassign_worker_from_resource(state, player_idx, resource)`. All return a new state (immutable-style) or mutate one state (your choice; MVP can mutate for simplicity).
- **game/cards.lua:** `CARD_DEFS` table: id, name, faction, kind, text, costs, population, baseHealth for bases. Include Human/Orc bases, Food/Wood/Stone resource nodes, and a few structures for blueprint view.
- **ui/card_frame.lua:** `draw_card_frame(x, y, params)` where `params` has title, faction, kind, type_line, text, costs, attack, health, population, is_base. Draw rounded rect, faction strip, title, costs, type line (+ "Max N per deck" if population), art box with placeholder icon, text box, stats bar (ATK / — / HP). Card size fixed (e.g. 160px wide).
- **ui/board.lua:** Given game state and which player is active, draw two player panels (left/right or top/bottom). Each panel: base card (center bottom), resource node cards (center left/right), worker deck slot, blueprint deck slot, unit deck slot. Draw worker tokens as circles in "unassigned" pool and on each resource node. Hit-test for click/drag: which token or which drop zone.
- **ui/blueprint_modal.lua:** When blueprint deck is clicked, set `show_blueprint_for_player = 0 or 1`. Draw fullscreen overlay; in the middle draw a grid of card frames for that faction’s structures (from CARD_DEFS). Close button or click outside to set `show_blueprint_for_player = nil`.
- **state/game.lua:** Holds `game_state` (from game.state), `show_blueprint_for_player`, and drag state (e.g. `dragging_worker = { player_idx, from_resource }`). In update: nothing heavy. In draw: call board.draw() and, if modal open, blueprint_modal.draw(). On mousepressed: if modal open, handle close or no-op; else hit-test board (blueprint deck click → open modal; worker token → start drag; empty slot → no-op). On mousereleased: if dragging, hit-test drop zones (unassigned or food/wood/stone for that player); if valid, call assign/unassign and clear drag. Only the active player can move workers. "End turn / Start next" button: call end_turn then start_turn for new active player (same as web).

---

## 3. Game Loop (LÖVE Callbacks)

- **love.load():** Create initial game state (Player 1 Human Wood+Stone, Player 2 Orc Food+Stone). Run start_turn for player 1 so they begin with +1 worker and production (0 on first turn). Set current screen to game screen (state/game.lua).
- **love.update(dt):** Current state’s `update(dt)`. Game screen can use dt for simple animations later; MVP can leave empty.
- **love.draw():** Current state’s `draw()`. Game screen draws board + modal if open.
- **love.mousepressed(x, y, button):** Current state’s `mousepressed(x, y, button)`. Used for: click blueprint deck, start worker drag, click "End turn".
- **love.mousemoved(x, y):** Optional: track mouse for hover and for drag offset; game state can store last mouse position when dragging.
- **love.mousereleased(x, y, button):** Current state’s `mousereleased(x, y, button)`. Used for: drop worker on a zone, close modal (click outside).
- **love.keypressed(key):** Optional: Escape to close modal.

---

## 4. State Machine (Screens)

- **MVP:** Single screen = game play (state/game.lua). No main menu; game starts immediately.
- **Later:** Add menu state (e.g. "New Game", "Quit"); on New Game push game state. For MVP, one global `current_state` table with `update(dt)`, `draw()`, `mousepressed(...)`, `mousereleased(...)` is enough.

---

## 5. Game Logic (Mirror of Web Engine)

- **Players:** Each player has:
  - `faction` ("Human" | "Orc")
  - `baseId` (string, e.g. "HUMAN_BASE_CASTLE")
  - `life` (number, from base’s baseHealth)
  - `resources` table: food, wood, stone, cash, metal, bones (all numbers)
  - `totalWorkers` (number)
  - `workersOn` table: food, wood, stone (numbers; only the two chosen resource types are used per faction)
- **Game state:** `activePlayer` (0 or 1), `turnNumber`, `phase` ("MAIN"), `players` (array of 2).
- **Start turn (active player):** +1 totalWorkers; add workersOn.food/wood/stone to resources.food/wood/stone; keep phase MAIN.
- **End turn:** Switch activePlayer to other; increment turnNumber; then run start_turn for the new active player.
- **Assign worker:** Only if current player; require unassigned workers (totalWorkers - sum(workersOn) > 0); increment workersOn[resource] for the chosen resource (food/wood/stone). Human: wood+stone only. Orc: food+stone only.
- **Unassign worker:** Only if current player; require workersOn[resource] > 0; decrement workersOn[resource].

---

## 6. UI Layout (Match Web)

- **Two panels** side by side (e.g. left = Player 1, right = Player 2). Each panel shows:
  - **Upper left:** Blueprint deck (clickable card/slot).
  - **Middle left:** Worker deck slot.
  - **Center left / center right:** Two resource node cards (Human: Wood + Stone; Orc: Food + Stone). Each node shows its card frame and a pool of worker circles on it.
  - **Bottom center:** Base card (card frame with title, type line, art placeholder, text, HP).
  - **Right:** Unit deck (60) slot.
- **Unassigned workers:** One pool per player (e.g. above or beside the resource nodes) with circles; draggable onto nodes or from nodes back to unassigned.
- **Bottom of screen:** Turn/phase label; "End turn / Start next" button. Only the active player can move workers; button can be used by either for passing turn.

---

## 7. Card Frame (Match Web)

- Same layout as web: header (faction strip + title + costs), type line + population ("Max N per deck"), art box (placeholder icon by kind: Base, Structure, Unit, Worker, ResourceNode), rules text, stats bar (ATK / special / HP). Base uses gold border and only HP. Faction colors: Human = blue tint, Orc = red tint, Neutral = gray.

---

## 8. MVP Scope Checklist

- [x] Project structure and conf.lua, main.lua
- [x] Game state: two players, Human (Wood+Stone) vs Orc (Food+Stone), bases, resources, workersOn, totalWorkers
- [x] Start turn: +1 worker, produce from workersOn
- [x] End turn then start next player’s turn
- [x] Assign worker to resource (only active player; only their two resources)
- [x] Unassign worker (drag back to unassigned)
- [x] Card frame drawing (title, costs, type line, population, art placeholder, text, stats)
- [x] Board: both panels, base card, two resource node cards, worker pools (unassigned + on nodes)
- [x] Drag worker from pool to node and node to unassigned (or node to node)
- [x] Blueprint deck click opens modal; modal shows list of structure cards for that faction; close by button or click outside
- [x] "End turn / Start next" button

---

## 9. Out of Scope for MVP

- Attacking and blocking
- Building structures from blueprint deck (only view)
- Unit deck / hand / playing units
- Priority and fast spells
- Saving/loading, settings, main menu
- Network play

---

## 10. File-by-File Summary

| File | Purpose |
|------|--------|
| conf.lua | Window 1280x720, title |
| main.lua | load: create state, set game screen. update/draw/mouse: delegate to current state |
| src/game/state.lua | create_initial_game_state(); player and game state tables |
| src/game/actions.lua | start_turn, end_turn, assign_worker_to_resource, unassign_worker_from_resource |
| src/game/cards.lua | CARD_DEFS, get_card_def(id) |
| src/ui/util.lua | clamp, copy helpers |
| src/ui/card_frame.lua | draw_card_frame(x, y, w, h, params) |
| src/ui/board.lua | draw_board(game_state, active_player); return hit-test info for mouse |
| src/ui/blueprint_modal.lua | draw_blueprint_modal(player_idx, game_state); hit-test for close |
| src/state/game.lua | game_state, show_blueprint_for_player, drag state; draw board + modal; handle input |

---

## 11. Running and Packaging

- **Run:** `love .` from `love2d` directory (or point love to it).
- **Distribute:** Create a .zip containing main.lua, conf.lua, and src/ (and assets/ if any). Users need LÖVE installed to run it. For a standalone .exe, use love-release or similar to bundle LÖVE with your game.
