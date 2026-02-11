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
