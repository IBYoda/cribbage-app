# Product Requirements Document (PRD)
## Cribbage App — "Shared Deck" Companion App

**Owner:** Yoda
**Status:** Draft — not yet started (Hello Fresh Helper app comes first, for practice)
**Last updated:** September 26, 2026
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
- The app counting hands *for* players before they've counted. Pegging is auto-scored by default (Section 6, item 9), but hand and crib points are only calculated when a player taps Confirm Count — they still count out loud first, and the app doesn't show a breakdown until after they confirm (Section 6, item 8).

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
5. **Private hand display** — each player sees only their own cards on their own screen by default. No one else can see your hand unless you choose to play a card during pegging, or tap **"Show Hand"** — which is available to any player once counting begins (see item 8 for why it is not available earlier).
6. **Real-time play reveal** — as each player plays a card during the pegging phase, it becomes visible to everyone (this is the shared "table" — just cards, not a board).
7. **Sequenced counting-time reveal** — hands (and the crib) are revealed one at a time, controlled by each player, rather than all at once. Full flow detailed in item 8 below.
8. **Hand scoring via "Show Hand" → "Confirm Count":**
   - **"Show Hand" is available to any player once counting begins (the counting and done phases), and is not turn-gated.** *(Changed at the Phase 2 Batch 2 design checkpoint — this originally said "any time, any phase".)* Showing a hand during the discard would let the table deduce the crib discards, and during pegging it only hurts the player showing it, so the server refuses it before counting. Once counting starts, anyone can reveal their own hand whenever they want, including out of turn. Showing is one-way for the rest of the hand, purely voluntary, and has no effect on scoring or turn order by itself.
   - The formal counting phase happens **one hand at a time, in player order** (non-dealer first, then the dealer's hand, then the crib). If a player has already shown their hand, the counting phase just picks up from wherever their hand's visibility already is.
   - When it's a player's turn to count, they count their points out loud, then tap **"Confirm Count."** Confirming a hand **reveals it automatically**, so Show Hand first is optional. The server calculates the correct score from the four kept cards and the starter (the client never supplies a card or a point value), auto-adds it to the live score tracker (Section 6, item 11), and hands control to the next count in order. A zero-point hand still registers as "+0 — hand: nothing" so the table sees it was counted.
   - Unlike Show Hand, **"Confirm Count" stays turn-gated** — only the player whose count is up can confirm, so scores get logged in a clear, one-at-a-time sequence. A duplicate tap (double-click, retry, second tab) after the count has already landed is ignored, never scored twice.
   - **Winning ends the game on the spot.** The score is capped at 121, and the instant anyone reaches it, whether from pegging, his heels, or a hand or crib count, the game ends with that player as winner. Nothing after the winning point counts: if the pone wins on their hand, the dealer's hand and the crib are never counted. The winner sees "You win!", the other player sees "[name] wins!", and both banners say what scored the winning points.
   - The **dealer goes last**, and after their own hand, they get one additional step: **"Show Crib"** (reveals the crib — theirs alone, see the note on 4-player teams below), then counts it out loud and taps **"Confirm Count"** the same way, which adds the crib's score and closes out the round. The crib stays face-down and unreadable to everyone, dealer included, until Show Crib is tapped, and Confirm Count is refused until then. After the crib is confirmed, everything stays face-up until the next hand is dealt.
   - **4-player teams note:** partners do **not** automatically see each other's hands at any point — there's no built-in hand-sharing between teammates. If a partner wants to voluntarily Show Hand to their teammate (or the whole table) for help or fun, that's the same voluntary action any player can take; the app just doesn't do it for them automatically.
   - **Full round sequence, for reference:** Deal → Discard to crib → Cut for starter card → Pegging/play phase (auto-scored, see item 9) → Counting phase (count out loud → Confirm Count, which reveals the hand; Show Hand is an optional earlier reveal; repeated in order, non-dealers first) → Dealer's hand (Show Hand → count → Confirm Count) → Dealer's crib (Show Crib → count → Confirm Count) → next round, deal passes to the left.
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

**Pegging resolution notes (decided during Phase 2 Slice 7 / scoring Batch 1):**
- When neither player can play under 31 (a deadlock), exactly ONE `go` event is logged in `game_plays`: the player who couldn't answer. The player who played the last card has no go event. This is by design and matches the physical game, where only one "go" is ever spoken per segment.
- The go point belongs to whoever played the last card of the segment, which is NOT necessarily the player with the go event. Attribution comes from control flow ("I just played and the segment is closing"), never from looking up the go event's user.
- Hitting exactly 31 scores 2 and closes the segment with no go point. The final card of the hand scores 1 as "last card" (same point as go), unless that card makes exactly 31.
- His heels (starter is a jack, dealer scores 2) is scored at cut time, not in hand counting, so it is never double-counted at showtime.

**Counting, winning and match notes (decided at the Phase 2 Batch 2 design checkpoint):**
- **One `games` row is one match to 121**, not one hand. Scores accumulate on `table_members` across hands and reset when New Game starts the next match.
- **Counting order in a 2-player hand:** the pone's hand, then the dealer's hand, then the crib (dealer). The server tracks which count is up, and the hand and crib are always scored from the four kept cards (plus the starter), never from what is left in a player's hand after pegging.
- **The 121 cap:** a stored score never exceeds 121, so the tracker matches a physical board. The score flash still shows the full award (a 2-point play from 120 flashes "+2" and stores 121).
- **Winning is checked in the one place every point passes through,** so it is caught mid-pegging, on his heels, and mid-count alike. A game that ends on his heels is left with its phase as it was; the screen checks the game's status before its phase.
- **Next hand (Batch 2b):** when every count is in (the `done` state), **both players must tap Next Hand** before the next hand is dealt: the first tap only marks that player ready (the other player sees "X is ready", the first sees "Waiting for X…"), and the tap that completes the set deals. The deal rotates to the other player every hand, scores and the tracker carry over, and the 5-hour session clock keeps measuring from the start of the match.
- **Next match (Batch 2b):** New Game resets both scores and the tracker. After a **won** match between the same two players, the **loser deals first** and play starts at once with no cut. Any other ending (a player leaving, an admin ending the game, the 5-hour timeout, or a changed roster) means a **fresh cut for deal**.

**Resolved:** the first built version of cut-for-deal computed the dealer AND dealt all cards atomically in one step, then revealed the cut result as a ceremony layered on top afterward. This was corrected in Phase 2 Slice 5 (the "cut-before-deal" rework) — nothing is dealt until the cut genuinely resolves, drawn one card at a time on demand from a face-down spread, with ties handled via mandatory dual-redraw (Slice 4b). After a won match between the same two players, the loser deals the next match with no re-cut; every other ending cuts for deal again (see the next-hand and next-match notes above).

---

## 8. User Experience Requirements

- Mobile-first, thumb-friendly layout — this is meant to be held and used casually, often one-handed, while also on a Zoom call.
- Your own hand is always clearly visible and unmistakably private (no risk of accidentally showing your screen's contents to the room over Zoom screen-share, if that ever comes up — worth a design note but not a technical requirement).
- **"Show Hand"** should be visible and tappable for every player once counting begins (it's a voluntary, no-consequence action, and it is not offered earlier — see Section 6, item 8). **"Confirm Count"** should be clearly visible but only actionable for whoever's turn it is in the counting order — these have different availability rules and the UI should make that obvious at a glance.
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

Actual Phase 2 slice order, since it's drifted from the original plan once already:
1. Shuffle and deal
2. Discard to crib
3. Leave-table bug fix (inserted out of the original plan once discovered — not originally numbered as its own slice, but claimed "Slice 3" once built)
4. Cut for starter card + real cut-for-lowest-card dealer selection (first version — dealt cards before the cut fully resolved, see the resolved note in Section 7)
4b. Tie-visibility + mandatory dual-redraw for cut-for-deal ties
5. Cut-before-deal rework — the major correction making cut-for-deal a genuine two-phase, on-demand, draw-one-card-at-a-time flow before any cards are dealt (see Section 7)
6. Live score tracker
6b. Function-grant security fix (three internal functions were reachable by any authenticated client due to a Supabase default-privileges bootstrap behavior — closed, plus a project-wide default-privileges fix so newly created functions default to no client access)
7. Pegging/play phase — turn order, legal-play enforcement, running count to 31, automatic go/deadlock resolution
8. **Batch 1 (merged, PR #16):** the scoring engines — pegging scoring (fifteens, pairs, runs, go, last card, 31), his heels, and the pure hand/crib scorer, with an exhaustively verified TypeScript mirror
9. **Batch 2a (merged, PR #17):** the counting flow (Show Hand / Confirm Count / Show Crib, Section 6 item 8), crib scoring, the 121 cap, and winning the game at 121 — ending at a `done` state

10. **Batch 2b (built and tested, pending merge):** Next Hand with the two-player ready gate (dealer rotation and the full per-hand reset), the match loop, New Game as a new match (scores and tracker reset, loser deals after a won match, cut for deal otherwise), and a hardened client that always re-reads the game after any realtime event. This completes Phase 2's server and game loop: two people can now play whole matches back to back.

**Next up:** the UI-polish pass (Section 11.5), then Phase 3 (3 and 4 players).

Update this list as slices land rather than trusting memory of the original plan — it's already been wrong once.)*
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
- [ ] "Show Hand" is available to any player once counting begins and works purely as a voluntary reveal; "Confirm Count" remains turn-gated and correctly calculates, logs, and advances scoring in order — ending with the dealer's hand and Show Crib.
- [ ] Pegging points (fifteens, pairs, runs, go/last card, 31) are calculated and added to the live score tracker automatically and correctly during play, with illegal plays (going over 31) flagged.
- [ ] As the admin, you can view all active tables/games and force-end an abandoned one; any game left running for 5 hours auto-ends, and any table left open for 12 hours auto-ends, on their own.
- [ ] The app works comfortably on a phone browser held in one hand during a Zoom call.
- [ ] You understand *how* the core pieces work (deck logic, realtime sync, scoring) well enough to explain them back, not just that they work.

---

## 11. Open Questions (to resolve before/during building)

*(None remaining — every open question raised during PRD review has been resolved in the sections above.)*

---

## 11.5 Tracked Polish Items (noticed during playtesting, not blocking current build)

Small UI/UX adjustments observed while actually playing, logged here so they aren't forgotten — not urgent, not scope changes, just real feedback waiting for a convenient slice to address:

- **TOP PRIORITY — the table must never outgrow the screen (layout rule for the whole polish pass):** this is mainly a shared deck and table space, used on a phone, so screen space is at a premium. Currently, when pegging starts a second row of played cards, the card sizes change and the page grows taller, forcing the player to scroll to reach their hand, the count or the scores. Rule: the whole table (both hands, the play area, the crib, the starter, the count and both scores) fits one screen with no scrolling, at phone width, even in the worst case of a full pegging round. The play area has a fixed height; more played cards overlap or fan out like a physical table instead of wrapping to a new row, and card size stays constant. Noticed while playing on a laptop during Batch 2b testing. Related to "Played cards should render in front of each player" below.
- **"Hand N" label (small):** show the hand number from `games.hand_no` as a tiny label near the table code, with no extra space taken. Optional.
- **Crib pile positioning:** currently rendered dead-center of the table. Preference is to move it off to the side — near/offset from the dealer's hand, not centered. Purely a layout change, no data/logic impact.
- **"Start a Table" should skip the extra step:** currently, creating a table requires then separately joining it, even though you're the creator. Preference: creating a table should immediately drop the creator into the table's waiting screen (same as if they'd joined), rather than requiring a manual join step for a table they just made. The table code is already visible in the corner for sharing with the other player — no need to make the creator copy/paste/re-enter it themselves.
- **After a win, keep the final board visible:** currently the play area is wiped when a game ends and only the win banner shows. A win on his heels in particular feels abrupt, because nobody can see the jack that caused it. Preference: keep the starter, the crib and the last cards played visible behind or beside the banner so the winning moment is readable. (The banner already says why the game ended, e.g. "fifteen (+2)" or "his heels (+2)".) Noticed during Batch 2a testing.
- **An opponent's shown hand appears in a different card order than its owner sees:** cosmetic, noticed during Batch 2a testing. Shown hands should use one consistent order on both screens.
- **Possible repeated GO chips (unverified):** from reading the code, a player who is stuck while the other keeps playing may collect a GO chip on every play. Not yet seen in testing; log it here if it shows up, and correct the "exactly one go event" wording in Section 7 if so.
- **Remove the "[Name] said go" message during pegging (done in Batch 1):** noticed during Slice 7 testing that this message caused confusion around the deadlock/double-go case (only one player's go gets an explicit event logged — see Section 7's pegging notes — so the message reads as if the second stuck player's go was "missed" when the turn/count outcome is actually correct). The underlying `game_plays` go events stay recorded and functional either way; this is purely about removing a UI message that misleads more than it helps.
- **Sort button intermittently stuck (seen once, not reproduced):** after Next Hand in Batch 2b testing, one screen's Sort button did not work until a manual refresh. It did not recur in later runs. The same root cause as a separate bug (a screen sitting on an out-of-date snapshot of the game, after the page missed a realtime update) was fixed in Batch 2b by re-reading the game after every event, so this may already be fixed. Re-log here if it comes back.
- **Played cards should render in front of each player, not in a shared centered stack:** currently, pegging play renders all played cards together in one shared row/area in the middle of the table. Preference: each player's own played cards should appear in front of their own position instead, matching how a physical table actually looks. Noticed during Slice 7 testing; also contributing to a graphical layout glitch when a new segment starts a new row.

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
