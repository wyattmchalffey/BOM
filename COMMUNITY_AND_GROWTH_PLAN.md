# Battles of Masadoria — Community, Art, and Growth Plan

This plan is designed for a solo developer with a working alpha (multiplayer card game, 2 factions, full game loop) and minimal budget. It prioritizes getting real players into the game fast, building a community around it, and finding art contributors through that community rather than spending money you don't have.

The core thesis: **your game is further along technically than most indie projects that already have communities.** The bottleneck isn't features — it's visibility and a playable first impression. Fix that and everything else follows.

---

## Phase 1: Make the Game Presentable Enough to Share (1–2 weeks)

You don't need finished art. You need *consistent, readable* visuals so playtesters can parse the board and understand what's happening. Right now you have resource icons and a font. That's not enough for someone to look at a screenshot and think "I want to try this."

### Art Direction on Zero Budget (No AI Art)

Since you'd prefer to avoid AI-generated art, here are the realistic options:

**Option A: Adopt a deliberate minimalist/abstract style.** Some of the most visually distinctive card games lean into graphic design rather than illustration. Think clean shapes, strong color coding per faction, readable iconography, and typographic identity. This is achievable with basic tools (Inkscape, GIMP, even Love2D's drawing primitives) and doesn't require illustration skill. Games like Slay the Spire started with programmer art that had strong *design logic* even when individual assets were rough.

What this looks like in practice:
- Faction color palettes (Orcs = deep reds/bone white, Elves = blue-green/amber, etc.)
- Card frame templates with clear type/cost/stat layout — even rectangles with colored borders
- Simple symbolic icons for keywords and card types (sword for attack, shield for defense, etc.)
- A consistent card back design

**Option B: Use free/open-source asset packs as a base.** Itch.io has free card game pixel art packs, and OpenGameArt.org has card and fantasy assets under open licenses. These won't match your specific factions, but they can give you a baseline look that's more polished than programmer art. You'd customize colors and add your own icons/text overlay.

Good starting points:
- itch.io: search "card game" filtered to free + pixel art — multiple packs with card frames, dice, and fantasy elements
- OpenGameArt.org: playing card packs in multiple sizes, fantasy icon sets
- CraftPix.net: free 2D game asset section

**Option C: Commission a small "identity kit" cheaply.** You don't need 100+ card illustrations right now. You need maybe 5–8 pieces: two faction card frame designs, a logo, a board background, and a couple of key unit illustrations to use in marketing. On Fiverr or through art school communities, this might cost $100–300 total for a stylized/simple look. This is the highest-impact small spend you could make.

### Minimum Playtest-Ready Visual Checklist

Before sharing, make sure the game has:
- [ ] Distinct card frames or borders per faction (even just color-coded rectangles)
- [ ] Readable card text layout (name, cost, type, stats, ability text)
- [ ] Resource icons that are visually distinct at a glance (you already have these)
- [ ] A board layout that a new player can parse without explanation
- [ ] A simple title screen or menu that looks intentional

---

## Phase 2: Set Up Your Online Presence (1 week, overlapping with Phase 1)

You made a Discord server last night. Good. Here's how to set it up and what else you need.

### Discord Server Setup

Keep it simple — over-structured servers with 30 empty channels are worse than a few active ones.

Channels to start with:
- **#announcements** — your devlog updates, patch notes, playtest calls (read-only for members)
- **#general** — main chat
- **#playtest-feedback** — structured feedback from testers (consider a pinned template: "What faction did you play? What felt good? What confused you? Any bugs?")
- **#bugs** — bug reports (you already have an in-game bug report form, so link this to Discord)
- **#card-discussion** — strategy talk, card ideas, balance opinions
- **#art-and-lore** — share lore snippets, discuss visual direction, post concept sketches (this channel also signals to artists that this project has creative depth)

Roles:
- @Playtester — anyone who's played a match
- @Artist / @Contributor — for future collaborators

### Itch.io Page

This is your public-facing home until you have a Steam page. Set up a free game page on itch.io with:
- A short description (elevator pitch: "Battles of Masadoria is a competitive multiplayer card game where asymmetric factions clash through resource management, combat, and unique faction mechanics")
- 2–3 screenshots of actual gameplay (even with placeholder art)
- A downloadable alpha build (Windows, since that's what your build scripts target)
- A devlog — even one post explaining what the game is and where it's headed
- A link to your Discord

Itch.io is important because it gives you a URL to share everywhere. "Come check out my game" needs a link.

### Reddit Presence (Don't Spam, Be a Community Member)

You said you're comfortable being public. Reddit is where your first 20–50 players will likely come from. The key is being a genuine participant, not a drive-by promoter.

Subreddits to engage in:
- **r/gamedev** — Screenshot Saturday (weekly), Feedback Friday. Post progress, not ads
- **r/indiegaming** — share your game with screenshots/GIFs
- **r/love2d** — the Love2D community is small and supportive; they'll actually try your game
- **r/cardgames** and **r/digitaltcg** — relevant to your genre specifically
- **r/playmygame** — explicitly for sharing playable games and getting feedback
- **r/DestroyMyGame** — if you want brutal honest feedback (valuable)

What works on Reddit:
- GIFs/short videos of actual gameplay moments (a combat sequence, a cool combo, a faction-specific mechanic)
- Devlog posts that tell a story ("I'm a solo dev building a multiplayer card game with necromantic orcs and civil-war elves — here's what the combat looks like")
- Asking genuine questions about your design challenges (the gamedev community responds well to vulnerability and specifics)

---

## Phase 3: Get Your First 10 Players (Weeks 2–4)

The goal here is not "build a community" — it's "get 10 real humans to play a match and tell you what happened." Everything else follows from this.

### Playtest Recruitment Strategy

1. **Personal network first.** Friends, family, coworkers, anyone who plays games. Even one person who plays regularly and gives you feedback is gold. Don't underestimate this.

2. **Reddit posts with a clear call to action.** "I'm looking for 5 playtesters for my multiplayer card game alpha. Matches take ~15 minutes. Here's a GIF of gameplay. Link to download. Join the Discord to find an opponent."

3. **Love2D community.** Post in the Love2D forums and r/love2d. Fellow Love2D devs are likely to try it out of curiosity and solidarity.

4. **Playtest swap communities.** r/playmygame and the Playcocola platform (browser-based playtesting tool for indie devs) let you tap into pools of people who actively want to try new games. Fellow indie devs often do feedback swaps.

5. **Screenshot Saturday consistency.** Post every week. Even if nobody comments the first few weeks, you're building a visual record of progress that compounds over time.

### What to Ask Playtesters

Don't just ask "what did you think?" — you'll get "it was cool" and nothing useful.

Ask:
- Did you understand how to play without help? Where did you get stuck?
- Which faction did you pick and why? Did the other faction interest you?
- Was there a moment where you felt clever or excited? When?
- Was there a moment where you felt confused or frustrated? When?
- Would you play again? What would make you want to?
- How did the multiplayer connection work for you? Any lag or disconnects?

---

## Phase 4: Find Art Contributors (Ongoing from Week 2)

This is the part most solo devs get wrong. They post "looking for artist, rev share" and wonder why nobody responds. Here's what actually works:

### Why Artists Join Projects

Artists get flooded with "I have an idea, I need art, revenue share" pitches. Yours has to be different. Your advantages:
- **The game already works.** This alone puts you ahead of 95% of rev-share postings. Most never get past a design doc.
- **The lore is compelling.** Your faction bible is genuinely interesting — desert necromancer orcs, civil-war elves, grief-engineer gnomes on a spirit turtle. Artists care about creative context.
- **You have multiplayer.** This is a real project, not a weekend prototype.

### Where to Find Artists

- **r/INAT (I Need A Team)** — the main subreddit for indie team formation. Post with screenshots of the working game, a link to your lore doc, and be specific about what you need (card frame design, unit illustrations, UI elements)
- **r/gameDevClassifieds** — similar, more transactional
- **Art school communities and portfolio-building discords** — student artists looking for portfolio pieces are often willing to contribute to interesting projects for credit and rev-share
- **DeviantArt / ArtStation forums** — some artists actively look for game projects to join
- **Your own Discord** — as your community grows, artists will find you if the project looks real and the lore is visible

### How to Pitch to Artists

Your pitch should include:
1. A link to the playable game (this is your strongest asset)
2. The faction lore bible (shows creative depth)
3. Specific art needs with quantities ("I need card frame designs for 2 factions, roughly 10 key unit illustrations to start, and a logo")
4. What you're offering (rev-share percentage, creative credit, portfolio use rights)
5. Screenshots of the game as-is (shows you're not asking someone to draw art for a fantasy)

### Revenue Share Structure

Be upfront and fair:
- If someone contributes substantial art (card illustrations, UI, branding), 15–25% rev-share is a reasonable starting point for a two-person split
- Put it in writing, even a simple agreement
- Let them retain rights to their art for portfolio use
- Be clear about what "revenue" means (net after platform fees, or gross?)

---

## Phase 5: Funding and Sustainability (Months 2–4)

Don't chase funding before you have players. A grant application with "50 active playtesters and growing Discord community" is vastly stronger than "I have a working prototype."

### Grant Opportunities

Several programs specifically fund indie/solo developers:

- **DANGEN Entertainment Indie Developer Grant** — $50,000 total pool, specifically for indie devs working on passion projects
- **Epic MegaGrants** — next submission window is June–September 2026; designed for smaller teams and solo developers; no equity taken
- **UK Games Fund** — up to £30,000 for early-stage projects (if you're UK-based)
- **Indie Fund** — investment fund specifically for indie games; they review playable builds
- **Outersloth (Innersloth/Among Us creators)** — indie game fund focused on unique projects

Most of these want to see a playable build and some evidence of community traction. You'll be in a strong position to apply after Phases 1–4.

### Early Access Revenue

Once you have a small but active community and the art is at least functional:
- **Itch.io paid alpha** — set a "pay what you want" or small price ($3–5) for the alpha. Some people will pay just to support you
- **Steam Early Access** — this is the bigger milestone; your early access readiness review already maps the path. Realistically this is 3–6 months out
- **Patreon / Ko-fi** — monthly supporter model works well for solo devs with active devlogs. Even $50–100/month from supporters helps fund small art commissions

### Crowdfunding (Later, Not Now)

Kickstarter works for card games, but you need:
- Compelling visuals (at least a few finished card illustrations and a trailer)
- An existing community to seed the campaign (your Discord + Reddit followers)
- A clear scope for what funding achieves ("$5,000 funds art for all 4 factions")

This is probably a Phase 6+ move, after you've validated the game with players and have some art direction established.

---

## Timeline Summary

| Week | Focus | Key Deliverables |
|------|-------|-----------------|
| 1–2 | Visual cleanup + online presence | Consistent card frames, itch.io page live, Discord set up, first Reddit post |
| 2–4 | First playtesters | 10+ people have played, feedback collected, first balance/UX insights |
| 3–6 | Art contributor search | r/INAT post with playable build, lore pitch to artists, first artist conversations |
| 4–8 | Community growth | Regular devlog posts, Screenshot Saturday presence, 50+ Discord members |
| 6–12 | Funding applications | Grant applications submitted with community traction data |
| 8–16 | Early Access prep | Paid itch.io alpha, Steam page setup, continued art development |

---

## Immediate Next Actions (This Week)

1. **Pick an art direction** — minimalist/abstract, asset pack base, or small commission. Decide today so you can start making card frames tomorrow.
2. **Set up Discord channels** — keep it to 5–6 channels max. Write a short welcome message explaining what the game is.
3. **Create your itch.io page** — even with current placeholder art. Get a URL you can share.
4. **Make a 15-second gameplay GIF** — one combat sequence or interesting card play. This is your Reddit ammunition.
5. **Write your first devlog post** — "I'm a solo dev building a multiplayer card game with necromantic desert orcs. Here's where I am." Post it on itch.io and cross-post to r/gamedev and r/love2d.
