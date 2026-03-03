SIEGECRAFT BOARD REDESIGN MOCKUP
=================================

FILE: mockup_board_redesign.html
SIZE: 480 KB
TYPE: Self-contained HTML5 document (no external dependencies)

OVERVIEW
--------
This mockup presents a comprehensive visual comparison of the Siegecraft board redesign,
showing the transition from card-based tiles to sprite-based graphics using the 
Tiny Swords (Free Pack) asset library.

KEY CHANGES VISUALIZED
----------------------

1. WORKERS
   - Current: Blue gradient orb circles
   - Proposed: Tiny Swords Pawn sprites with multiple animation states

2. STRUCTURES
   - Current: Card tiles with text labels
   - Proposed: Actual building sprites in a dynamic "city zone"

3. PLAYER DISTINCTION
   - Multiple faction colors: Blue, Red, Purple, Black
   - Each faction has unique building colors for clear player identification

CONTENT SECTIONS
----------------

SECTION 1: BOARD LAYOUT COMPARISON
  Left panel shows the current game board:
  - Structures row with card tiles (Barracks, Workshop, Tower)
  - Units row with card tiles (Militia, Archer)
  - Resources row with colored orb workers
  - Worker pool with unassigned orb workers

  Right panel shows the proposed redesign:
  - City zone with actual building sprites
  - Same unit row (cards remain)
  - Resources with Pawn sprites carrying resources
  - Worker pool with Pawn sprite animations

SECTION 2: WORKER ANIMATION STATES
  Displays all 6 pawn sprite configurations:
  - Idle State (unassigned worker)
  - Chopping (Axe) - wood harvesting
  - Mining (Pickaxe) - gold extraction
  - Carrying Wood - transport animation
  - Carrying Gold - treasure transport
  - Carrying Meat - food handling

SECTION 3: CITY GROWTH PROGRESSION
  Shows 4 stages of city expansion:
  - Stage 1: Empty Lot (no buildings)
  - Stage 2: 1 Building (initial castle)
  - Stage 3: 3 Buildings (castle, barracks, monastery)
  - Stage 4: 5+ Buildings (castle, barracks, tower, archery, house)

SECTION 4: FACTION DIFFERENTIATION
  Demonstrates faction colors:
  - Blue Faction: Castle and Barracks in blue
  - Red Faction: Castle and Barracks in red
  - Purple Faction: Castle and Barracks in purple
  - Black Faction: Castle and Barracks in black

DESIGN FEATURES
---------------
- Dark theme matching the game (navy/charcoal background)
- Gold accent color (#e0c878) for headers and UI elements
- Pixelated sprite rendering for authentic pixel-art display
- Responsive layout (works on desktop, tablet, mobile)
- Subtle hover effects and animations
- Professional polished appearance suitable for developer review

TECHNICAL DETAILS
-----------------
- All images are embedded as base64 data URIs
- No external files or network requests required
- Valid HTML5 with embedded CSS styling
- Cross-browser compatible
- File is self-contained and can be shared as a single file

SPRITE ASSETS USED
------------------
From Tiny Swords (Free Pack) - CC0 License

Buildings (8 blue variants):
  - Castle.png
  - Barracks.png
  - Tower.png
  - Monastery.png
  - Archery.png
  - House1.png, House2.png, House3.png

Factions (3 color variants):
  - Red: Castle, Barracks, Tower
  - Purple: Castle, Barracks, Tower
  - Black: Castle, Barracks

Pawns (6 sprite sheets):
  - Pawn_Idle.png
  - Pawn_Idle Axe.png (chopping animation)
  - Pawn_Idle Pickaxe.png (mining animation)
  - Pawn_Idle Wood.png (carrying wood)
  - Pawn_Idle Gold.png (carrying gold)
  - Pawn_Idle Meat.png (carrying food)

OPENING THE MOCKUP
------------------
Simply open mockup_board_redesign.html in any modern web browser:
- Double-click the file, or
- Right-click → Open With → Browser, or
- Drag and drop into browser window

No server or special tools required.

NEXT STEPS FOR DEVELOPMENT
---------------------------
1. Review the visual comparison in Section 1
2. Consider animation frame sequences shown in Section 2
3. Evaluate city growth progression in Section 3
4. Ensure faction colors work with game balance in Section 4
5. Plan sprite implementation in game engine
6. Consider animations and transitions for worker states

NOTES FOR DEVELOPER
-------------------
- Section 2 shows only the first frame of sprite sheets
  (Full animations are available in the original Tiny Swords asset pack)
- Building sizes can be adjusted during implementation
- Sprite placement in the city zone is modular for flexible layout
- All hexadecimal color codes are preserved for exact theme matching
- Responsive CSS ensures proper display across all screen sizes

For questions or modifications, refer to the HTML source code
which includes detailed CSS comments and semantic HTML structure.

Created: March 2, 2026
Status: Ready for Developer Review

