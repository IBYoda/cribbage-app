# Product Requirements Document (PRD)
## Cribbage App — "Shared Deck" Companion App

**Owner:** Yoda
**Status:** Draft — not yet started (Hello Fresh Helper app comes first, for practice)
**Last updated:** August 2, 2026
**Revision note:** Pivoted from "full virtual table" concept to a lighter "shared deck + hand display" companion app that keeps physical boards/pegging. See Section 2.5 for why. Platform confirmed as responsive web app (not native mobile) — see Section 5. Scoring flow confirmed — see Section 6, item 8.

---

## 1. What is a PRD, and why are we writing one?

A PRD (Product Requirements Document) is just a plan written down before you start coding. It answers three questions:
1. **What** are we building?
2. **Who** is it for, and what problem does it solve?
3. **How** will we know it's done (and done well)?

Writing this now means fewer "wait, what was I trying to do again?" moments later, and it gives us something to check new ideas against so we don't wander off track.

---

## 2. Problem Statement

You and your friends play cribbage over Zoom from different locations. You already have Zoom for seeing/talking to each other, and you each have a physical cribbage board you enjoy pegging on in real life. The actual broken piece is the **cards**: each person deals from their own separate physical deck, so there's no shared, verifiably-fair deal. This app solves *that specific problem* — one shared virtual deck, dealt fairly, with each player's hand private to them on their own phone.

### 2.5 Why we pivoted away from a full virtual table

The original plan (see revision history) included a fully virtual board with animated pegs and full visual customization. On reflection, that was solving a problem you don't actually have — your physical board already works great for pegging, and Zoom already handles the "seeing each other" part. Building a virtual board would have added a lot of complexity (canvas/SVG rendering, peg animation, theming system) for a feature that duplicates something already working. Dropping it means:
- Less to build overall (no board rendering, no animated peg-tracking, no customization phase) — though a simple numeric score display stays in scope, see Section 6
- You keep the tactile, real-life part of cribbage you actually enjoy
- The app stays focused on the one thing that was genuinely broken: fair, shared cards

---

## 3. Goals

**Primary goals:**
- Replace "everyone deals from their own deck" with one fair, shared virtual deck.
- Show each player their own hand privately on their own phone.
- Show cards to everyone as they're played during the pegging phase, and reveal each hand (then the crib) one at a time, in order, during counting.
- Support 2, 3, and 4-player games, played remotely, alongside Zoom and physical boards.
- Stay free and fully within your control (no subscriptions, no third-party app fees).

**Secondary goals (learning goals):**
- Serve as a structured way to build real skills with your stack (Next.js, Supabase, Git/GitHub, Vercel).
- Build good habits: small steps, regular commits, understanding *why* code works, not just copy-pasting.

**Non-goals (explicitly out of scope):**
- A visual/animated cribbage board with pegs — you're keeping your physical boards for this. (A simple numeric score display is still in scope — see Section 6 — to help everyone's physical boards stay in sync.)
- Board/visual theming or customization — no longer relevant now that there's no virtual board.
- Public matchmaking / playing with strangers.
- In-game voice/video chat (Zoom already handles this).
- Monetization of any kind.
- Automatic scoring or count-tracking running *at all times* by default — these exist only as optional, on-demand assists (see Section 6).

---

## 4. Users

- **Primary users:** You and your specific group of friends (a small, known, trusted group of 2–4 people), playing remotely over Zoom.
- **Not** designed for the general public — no need to plan for strangers, spam, or abuse-prevention systems a public app would need.

---

## 5. Tech Stack (already decided)

| Layer | Tool | Plain-English role |
|---|---|---|
| Frontend/Backend | Next.js | Builds both the pages you see and the server logic behind them |
| Database/Auth/Realtime | Supabase | Stores game data, handles login, and pushes live updates to all players (like a walkie-talkie between browsers) |
| Hosting | Vercel | Puts the app on the internet so your friends can open a link and play |
| IDE | Cursor (Windows 11) | Where you write the code |
| Version control | Git + GitHub (IBYoda) | Saves history of your code and backs it up online |

**Decided:** This is a **completely separate project** from Hello Fresh Helper — its own GitHub repo, its own Supabase project, and its own Vercel project. Nothing is shared between the two apps (not the codebase, not the database/user accounts, not the deployment). This keeps them fully isolated: no risk of cribbage code touching Hello Fresh Helper's data, no shared login between apps, and each stays on its own free-tier usage.

**Decided:** This will be a **responsive web app** — a website built with Next.js, designed to work well on a phone browser (open a link, no app store, no install). This keeps your entire existing stack valid and avoids app-store complexity (developer accounts, code signing, review process) that would add cost without teaching you the parts of this project that actually matter (game logic, real-time sync).

**Future option, not a v1 decision:** Once the game works, the app can be turned into a PWA (Progressive Web App) — a lightweight config change that lets players "Add to Home Screen" so it opens full-screen with its own icon, feeling like a native app without the app-store overhead. A "Donate" button (Ko-fi, Buy Me a Coffee, Stripe, etc.) would work identically on the web app as it would in a native app, without Apple/Google's in-app-payment rules — so native isn't required to support donation-based monetization down the road, if you decide to pursue that later.

---

## 6. Core Features (v1 scope)

1. **Accounts & profiles** — real accounts via Supabase Auth (email/password), not just a display name typed in each time. Each account has a persistent profile: a profile icon/image (optional — standard upload size/format limits apply, nothing custom needed), and a **game nickname** that can be changed per session if you want to play under something different than your account name.
2. **Table code / rooms** — a logged-in player can tap **"Start a Table"** to create a table, which generates a unique **4-digit Table Code**. Other logged-in players enter that code to join. A table can host **multiple games back-to-back** — a **"New Game"** button lets the group start a fresh game (new deal, score reset) without leaving the table or getting a new code. Multiple separate tables can run at the same time (e.g., two tables of 4 all on one big Zoom call), each fully independent with its own code, players, and games. The table code stops working once the table itself is ended — not automatically when a single game finishes, since the group can just tap "New Game" and keep going. (See item 12 for who can end a table and how.)
3. **Reconnection handling** — table/game state lives on the server (Supabase), not just in a player's browser. If someone's browser refreshes, their phone dies and comes back, or they lose connection, rejoining (same account, same table) drops them back into the current game exactly where it left off — hand, score, and turn all intact — rather than losing progress or restarting.
4. **Shared virtual deck** — one deck, shuffled once per hand, dealt fairly to every player's phone.
5. **Private hand display** — each player sees only their own cards on their own screen by default. No one else can see your hand unless you choose to play a card during pegging, or tap **"Show Hand"** — which is always available, any time, to any player (see item 8 for why).
6. **Real-time play reveal** — as each player plays a card during the pegging phase, it becomes visible to everyone (this is the shared "table" — just cards, not a board).
7. **Sequenced counting-time reveal** — hands (and the crib) are revealed one at a time, controlled by each player, rather than all at once. Full flow detailed in item 8 below.
8. **Hand scoring via "Show Hand" → "Confirm Count":**
   - **"Show Hand" is always available, to any player, at any point in the round** — not locked to turn order or the counting phase. Anyone can reveal their own hand whenever they want: to ask a friend for advice before discarding, to brag mid-game ("I'm sitting on 24, you're all screwed"), or just because the table's a few drinks in and nobody cares about the formalities. Showing your hand is purely voluntary and has no effect on scoring or turn order by itself.
   - The formal counting phase still happens **one hand at a time, in player order** (starting left of dealer, dealer last, then the crib). If a player already showed their hand earlier for fun, that's fine — the counting phase just picks up from wherever their hand's visibility already is.
   - When it's a player's turn to count, they count their points out loud (revealing via Show Hand first, if they haven't already), then tap **"Confirm Count."** This calculates the correct score for that hand, auto-adds it to the live score tracker (Section 6, item 11), and hands control to the next player in order.
   - Unlike Show Hand, **"Confirm Count" stays turn-gated** — only the current player in the counting order can confirm, so scores still get logged in a clear, one-at-a-time sequence even if hands were shown out of order earlier.
   - The **dealer goes last**, and after their own hand, they get one additional step: **"Show Crib"** (reveals the crib — theirs alone, see the note on 4-player teams below), then counts it out loud and taps **"Confirm Count"** the same way, which adds the crib's score and closes out the round.
   - **4-player teams note:** partners do **not** automatically see each other's hands at any point — there's no built-in hand-sharing between teammates. If a partner wants to voluntarily Show Hand to their teammate (or the whole table) for help or fun, that's the same voluntary action any player can take; the app just doesn't do it for them automatically.
   - **Full round sequence, for reference:** Deal → Discard to crib → Cut for starter card → Pegging/play phase (auto-scored, see item 9) → Counting phase (Show Hand, if not already shown → count out loud → Confirm Count, repeated in order, non-dealers first) → Dealer's hand (Show Hand → count → Confirm Count) → Dealer's crib (Show Crib → count → Confirm Count) → next round, deal passes to the left.
9. **Auto-scored pegging (play phase):**
   - During the pegging round (playing cards up to 31), the app automatically calculates points as they happen — fifteens, pairs, runs, "go"/last card, and hitting 31 — and adds them straight to the live score tracker in real time.
   - This is a change from a "manual by default" approach: pegging math has to happen fast, in the middle of active play, which is exactly the situation most likely to cause disputes or mistakes — so this one is automatic out of the box rather than an opt-in toggle.
   - The app still enforces/flags illegal plays (going over 31), since it's already tracking the running count to do the scoring.
10. **Support for 2, 3, and 4-player games** — including the different dealing/crib rules for each (detailed below).
11. **Live score tracker (numbers only, not a visual board)** — a simple, real-time number for each player's current score (e.g., "Yoda: 42 — Sam: 37"), synced across everyone's screens as points are logged. This is not an animated board with pegs — just a running number — but it means everyone can glance at their phone and confirm their physical peg is in the right spot, so there's no confusion or arguing about the score, especially a few drinks in. No visual board rendering or theming beyond this (see 2.5).
12. **Admin & table management (for you)** — your account gets an admin role that lets you see all active tables/games and force-end ("kill") any that have been abandoned, without needing to be a player in them. Every game also has a **hard 5-hour timeout** — after 5 hours, it auto-ends on its own, so a forgotten or abandoned session doesn't sit open forever even if no one manually cleans it up. Tables have their own outer limit too: a **hard 12-hour table timeout**, so a table nobody remembered to end (e.g., everyone logged off after a session) doesn't just sit open indefinitely, even across multiple back-to-back games.

---

## 7. Game Rules Reference (by player count)

This is here so the dealing/discard logic has one clear source of truth to build against.

### 2 Players
- 6 cards dealt to each player.
- Each player discards 2 into the crib (crib = 4 cards).
- Dealer owns the crib.
- First to 121 points wins.

### 3 Players
- 5 cards dealt to each player.
- Each player discards 1 into the crib.
- Dealer draws 1 extra card from the deck to bring the crib to 4 cards.
- Dealer owns the crib.
- First to 121 points wins.

### 4 Players (2 teams of 2)
- 5 cards dealt to each player.
- Each player discards 1 into the crib.
- Dealer and their partner **share** the crib.
- First to 121 points wins.

*(Confirmed: partners do not automatically see each other's hands — see Section 6, item 8.)*

**Order of operations (confirmed, per official cribbage rules — see docs/CribbageBasics.pdf):** cutting for deal must complete BEFORE any cards are dealt — this is a strict sequence, not simultaneous/pre-computed-then-revealed. The real order is: (1) cut for deal, lowest card deals; (2) dealer shuffles; (3) 6 cards dealt to each player; (4) each player discards 2 to the crib; (5) non-dealer cuts the remainder for the starter card (this part is already built correctly).

**Deliberately excluded:** the official rules' step where the non-dealer makes a mandatory cut of the deck before dealing is intentionally NOT implemented — it's a house-rule casualty of remote play (their group's tradition is a shot penalty for asking someone else to cut your deck, which the app makes physically impossible anyway). Not a gap to fill later.

**Known gap as of this note:** the first built version of cut-for-deal computed the dealer AND dealt all cards atomically in one step, then revealed the cut result as a ceremony layered on top afterward (chosen deliberately at the time, then found to feel wrong once actually played — a real "nothing is dealt until the cut resolves" two-phase flow is required instead). This needs correcting before Phase 2 is considered done. After the first game at a table, the deal alternates each hand as usual — no re-cut needed.

---

## 8. User Experience Requirements

- Mobile-first, thumb-friendly layout — this is meant to be held and used casually, often one-handed, while also on a Zoom call.
- Your own hand is always clearly visible and unmistakably private (no risk of accidentally showing your screen's contents to the room over Zoom screen-share, if that ever comes up — worth a design note but not a technical requirement).
- **"Show Hand"** should be visible and tappable for every player at all times (it's a voluntary, no-consequence action). **"Confirm Count"** should be clearly visible but only actionable for whoever's turn it is in the counting order — these have different availability rules and the UI should make that obvious at a glance.
- Auto-scored pegging points should appear on the live score tracker clearly enough that players can see *why* the number moved (e.g., briefly show "Sam +2 — pair" rather than just the number changing), so it doesn't feel like a mystery to whoever's watching their physical board.
- Big, legible cards and buttons — remember, intended use case includes "too drunk to count properly."
- No manual refresh needed — state changes appear instantly for all players.
- **Table layout (seating positions):** the game table is conceptually a square. Your own hand is **always at the bottom** of your own screen, regardless of player count — everyone sees themselves in the same spot. Other players fill in around the square as they're added: 2-player has one opponent, placed at the **top**. 3-player and 4-player add opponents to the **left** and **right** as well. This convention should be built into the UI from the first 2-player slice, even though 3/4-player support isn't built until Phase 3 — designing it this way now means adding more players later is just filling in empty seats, not restructuring the screen.

---

## 9. Build Order / Phased Roadmap

**Phase 0 (prerequisite):** Build the Hello Fresh Helper app first, to build foundational skills (Next.js + Supabase basics) on a simpler project before tackling real-time multiplayer complexity.

**Phase 1 — Accounts, tables & admin basics:**
- Supabase Auth accounts (email/password)
- Profile: icon/image (optional) + editable game nickname
- "Start a Table" → generates a 4-digit table code; others join via that code
- "New Game" button to start another game at the same table without a new code
- Support multiple independent tables running at once
- Server-side table/game state + reconnection handling, so a dropped/refreshed player rejoins where the current game currently is
- Admin role for you: view active tables/games, force-end an abandoned one; 5-hour hard timeout auto-ends any forgotten game, 12-hour hard timeout auto-ends any forgotten table
- Goal: players can log in, start or join a table by code, play multiple games at that table, and reconnect without losing their spot — before the actual cribbage logic exists yet

**Phase 2 — 2-player game (core):**

*(Numbering note: git/PR history for this phase started counting from "Slice 9" — a continuation of Phase 1's 1-8 — before switching to per-phase numbering to match this document. "Slice 9" in commit history = "Phase 2, Slice 1" here. All Phase 2 work going forward uses Phase 2's own numbering, starting at Slice 1.

Actual Phase 2 slice order, since it's drifted from the original plan once already: 1) Shuffle and deal, 2) Discard to crib, 3) Leave-table bug fix (inserted out of the original plan once discovered — not originally numbered as its own slice, but claimed "Slice 3" once built), 4) Cut for starter card + real cut-for-lowest-card dealer selection [next]. Update this list as slices land rather than trusting memory of the original plan — it's already been wrong once.)*
- Shared deck + dealing logic
- Private hand display for each player
- Real-time reveal of played cards during the pegging phase
- Live score tracker (numeric only — Section 6, item 11)
- Auto-scored pegging during the play phase (Section 6, item 9)
- Counting-phase flow — Show Hand, count, Confirm Count, repeated in order, ending with the dealer's hand and Show Crib (Section 6, item 8)
- Goal: two people can log into a shared table and play a full, correctly-scored 2-player game start to finish, with cards, pegging points, and hand scores all handled by the app, and physical boards kept accurately in sync

**Phase 3 — 3 and 4 player support:**
- Extend dealing/discard logic for 5-card hands + dealer's extra draw (3p) and shared crib (4p teams)
- Extend real-time sync, auto-scored pegging, and the Show Hand / Confirm Count counting flow to more players
- Confirm 4-player team hand-visibility behavior in practice (no auto-sharing between partners — see Section 6, item 8)

*(Note: what was "Phase 3 — Assist features" in an earlier draft has been folded into Phase 2, since Confirm Count and auto-scored pegging are no longer optional extras — they're how the score tracker gets its numbers at all. There's no longer a distinct "assist" phase.)*

---

## 10. Success Criteria

We'll consider v1 "done" when:
- [ ] Players can create accounts, set a profile icon/image and game nickname, start a table (getting a 4-digit table code), and join a table using someone else's code.
- [ ] A group can play multiple games back-to-back at the same table via "New Game," without leaving the table or needing a new code.
- [ ] Multiple separate tables can run at the same time without interfering with each other.
- [ ] A player who refreshes their browser or loses connection can rejoin the same table and pick up exactly where the current game left off — hand, score, and turn intact.
- [ ] Two players in different locations can play a complete 2-player game in real time, with the app fairly dealing and displaying cards, and hand/pegging scores calculated and logged automatically via Confirm Count and auto-scored pegging.
- [ ] 3-player and 4-player modes work with correct dealing/crib rules.
- [ ] "Show Hand" is available to any player at any time and works purely as a voluntary reveal; "Confirm Count" remains turn-gated and correctly calculates, logs, and advances scoring in order — ending with the dealer's hand and Show Crib.
- [ ] Pegging points (fifteens, pairs, runs, go/last card, 31) are calculated and added to the live score tracker automatically and correctly during play, with illegal plays (going over 31) flagged.
- [ ] As the admin, you can view all active tables/games and force-end an abandoned one; any game left running for 5 hours auto-ends, and any table left open for 12 hours auto-ends, on their own.
- [ ] The app works comfortably on a phone browser held in one hand during a Zoom call.
- [ ] You understand *how* the core pieces work (deck logic, realtime sync, scoring) well enough to explain them back, not just that they work.

---

## 11. Open Questions (to resolve before/during building)

*(None remaining — every open question raised during PRD review has been resolved in the sections above.)*

---

## 12. Out of Scope for Now (revisit later if desired)

- **Player stats / trash-talk leaderboard (stretch goal):** now that accounts and profiles exist, per-player stats become realistic to add later without much extra plumbing — the data (games, scores, who played) is already being generated by v1. Not in scope for v1 itself, but worth keeping in mind as a natural next step once the core game is solid. Specific stats to track, when this gets built:
  1. **Wins**
  2. **Losses**
  3. **Skunked** (won/lost before the loser reached 91 points)
  4. **Double Skunked** (won/lost before the loser reached 61 points)
  5. **Stink Holed** (lost the game while sitting at 120 points — one point from winning)
  6. **"19's"** (got a hand that scored zero points — nicknamed a "19" because that's an impossible actual score in cribbage)

  **Database note (decided):** hand-level logging won't be added in Phase 1/2 — it'll be built alongside the stats screen itself, whenever that happens. That means "19" tracking (and any other stat needing per-hand data) only starts counting from that point forward, not retroactively for games played before it existed. That's a fine, deliberate tradeoff — just noting it here so it's a known consequence, not a surprise later.
- Chat within the app (you're using Zoom)
- Spectator mode
- Native mobile app (iOS/Android app store install)
- Virtual board / animated peg tracking / visual theming (cut in this revision — see 2.5; a simple numeric score display remains in scope, see Section 6)

---

*This PRD is a living document — as we build and learn things, we'll come back and update it rather than let it go stale.*
