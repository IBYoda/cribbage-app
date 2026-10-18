# Product Requirements Document (PRD)
## Nobs! — "Shared Deck" Cribbage Companion App

**Owner:** Yoda
**Name:** the app is called **Nobs!** (shipped in PR #25). The repo, the URL and internal names stay `cribbage-app`.
**Status:** Phase 2 complete and live. Two people can play whole 2-player matches at https://cribbage-app.vercel.app. Phase 3 (3 and 4 players) has not started.
**Last updated:** October 17, 2026
**Revision note:** Pivoted from "full virtual table" concept to a lighter "shared deck + hand display" companion app that keeps physical boards/pegging. See Section 2.5 for why. Platform confirmed as responsive web app (not native mobile) — see Section 5. Scoring flow confirmed — see Section 6, item 8. **October 2026:** Phase 2 finished and deployed (Section 5, Deployment). After live testing, the counting flow changed: every hand is face-up for everyone once pegging is over, and Show Hand / Show Crib left the screen (Section 6, item 8). New Game became a two-player ready gate and a win now leaves the final board on screen (Section 7). The app was renamed **Nobs!** and got a landing page, a signed-in main menu and a matching "card room" look on its simple pages (Section 6, item 14; PR #25). The first friends test ran on October 15: friends signed up and played, and email confirmation is off for now (Section 5, Deployment).

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
- Show cards to everyone as they're played during the pegging phase. Once pegging is over, put every hand face-up for everyone (and the crib when its count comes up) while the players count out loud.
- Support 2, 3, and 4-player games, played remotely, alongside Zoom and physical boards.
- Stay free and fully within your control (no subscriptions, no third-party app fees).

**Secondary goals (learning goals):**
- Serve as a structured way to build real skills with your stack (Next.js, Supabase, Git/GitHub, Vercel).
- Build good habits: small steps, regular commits, understanding *why* code works, not just copy-pasting.

**Non-goals (explicitly out of scope):**
- A visual/animated cribbage board with pegs — you're keeping your physical boards for this. (A simple numeric score display is still in scope — see Section 6 — to help everyone's physical boards stay in sync.)
- A virtual board with pegs, and any theming of one. (A personal look for the table surface and the card backs is a separate, small feature that IS in scope: Section 6, item 13.)
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

### Deployment (live as of October 2026)

- **Hosting:** Vercel (Hobby plan, personal account), project `cribbage-app`, Next.js preset. Every merge to `main` auto-deploys to production at **https://cribbage-app.vercel.app**. Deployment-specific URLs and preview deployments are login-protected by Vercel, so the production domain is the one to share with friends.
- **Environment variables (Production and Preview):** `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` only. The service-role key never goes in Vercel or the client.
- **Supabase auth config:** Site URL is the production domain. Allowed Redirect URLs: `https://cribbage-app.vercel.app/**` and `http://localhost:3000/**`.
- **One Supabase project is shared** by local development, previews and production (free plan, spend cap on). Anything run locally touches the same data players see.
- **Free-plan quirks:** the project pauses after about a week of inactivity (resume it from the Supabase dashboard), and the built-in sign-up email has a low rate limit, so a burst of sign-ups can get throttled.
- **Email and the friends test (October 15, 2026):** friends signed up and played on the live site. Finding: Supabase's built-in email sender allows **2 emails per hour for the whole project**, and Supabase has announced it may only deliver to addresses in the project's organization, so confirmation emails can't work for friends. **"Confirm email" is OFF** for the test: a new account is logged in straight away (Section 9, item 19). **Before a public or app-store release:** set up custom SMTP (or social sign-in) and turn confirmation back on.

---

## 6. Core Features (v1 scope)

1. **Accounts & profiles** — real accounts via Supabase Auth (email/password), not just a display name typed in each time. Each account has a persistent profile: a profile icon/image (optional — standard upload size/format limits apply, nothing custom needed), and a **game nickname** that can be changed per session if you want to play under something different than your account name.
2. **Table code / rooms** — a logged-in player can tap **"Start a Table"** to create a table, which generates a unique **4-digit Table Code**. Other logged-in players enter that code to join. A table can host **multiple games back-to-back** — a **"New Game"** button lets the group start a fresh game (new deal, score reset) without leaving the table or getting a new code. Multiple separate tables can run at the same time (e.g., two tables of 4 all on one big Zoom call), each fully independent with its own code, players, and games. The table code stops working once the table itself is ended — not automatically when a single game finishes, since the group can just tap "New Game" and keep going. (See item 12 for who can end a table and how.)
3. **Reconnection handling** — table/game state lives on the server (Supabase), not just in a player's browser. If someone's browser refreshes, their phone dies and comes back, or they lose connection, rejoining (same account, same table) drops them back into the current game exactly where it left off — hand, score, and turn all intact — rather than losing progress or restarting.
4. **Shared virtual deck** — one deck, shuffled once per hand, dealt fairly to every player's phone.
5. **Private hand display** — each player sees only their own cards on their own screen by default. No one else can see your hand until you play a card during pegging, or until pegging is over and counting begins, when every hand is shown to the table (see item 8). Before counting the server refuses to reveal a hand, because showing it during the discard would let the table deduce the crib.
6. **Real-time play reveal** — as each player plays a card during the pegging phase, it becomes visible to everyone (this is the shared "table" — just cards, not a board).
7. **Counting-time reveal** — once pegging is over, all hands are face-up for everyone, and the crib flips face-up when its count comes up. *(Originally hands were revealed one at a time under each player's control; live play showed that was too slow, see item 8.)*
8. **Counting: open hands, then "Confirm Count":** *(Changed in October 2026 after live play. The original Show Hand / Show Crib turn-by-turn reveal was too slow and is gone from the screen. The server functions still exist but the client no longer calls them.)*
   - **"Count hands" is a per-screen pause.** When pegging ends, the game is already in counting, but each player's screen waits behind a **Count hands** button. Tapping it only flips that player's own screen and writes nothing to the server, so each player moves at their own speed and one screen can flip before the other. This is safe because all eight cards were already played face-up during pegging, so seeing the hands tells nobody anything new.
   - **Every hand is face-up for the rest of the count.** Your own hand stays full size in your hand row, and the opponent's four cards sit face-up in the middle, labelled ("Counting: your hand", "[name]'s hand", "your crib", "[name]'s crib"). Only the crib is still a secret: it stays a face-down pile until the crib's count step, then it flips face-up for both players on its own. The database enforces both rules (hands readable only once pegging is over, crib only at its step).
   - **The count still runs one at a time, in order:** the pone's hand, then the dealer's hand, then the crib (dealer's). The player whose count is up counts out loud, then taps **"Confirm Count."** The button just validates what was said aloud, and the points are not shown until it is tapped, so players get the chance to count before the app tells them. The server calculates the score from the four kept cards and the starter (the client never supplies a card or a point value), adds it to the live score tracker (Section 6, item 11), and hands control to the next count. A zero-point count still registers as "+0 — nothing" so the table sees it was counted. A duplicate tap (double-click, retry, second tab) is ignored, never scored twice.
   - **"Confirm Count" stays turn-gated** — only the player whose count is up can confirm, so scores land in a clear, one-at-a-time sequence.
   - **Winning ends the game on the spot.** The score is capped at 121, and the instant anyone reaches it, whether from pegging, his heels, or a hand or crib count, the game ends with that player as winner. Nothing after the winning point counts: if the pone wins on their hand, the dealer's hand and the crib are never counted. The winner sees "You win!", the other player sees "[name] wins!", and both banners say what scored the winning points. What stays on screen after a win is described in Section 7.
   - **The dealer goes last,** and the crib is theirs alone (see the 4-player note below). The crib is unreadable to everyone, dealer included, until its step starts. At that step the screen flips it face-up automatically and the dealer counts it out loud and taps **"Confirm Count"**, which adds its score and closes out the round. After the crib is confirmed, everything stays face-up until the next hand is dealt.
   - **4-player teams note (revisit in Phase 3):** the open-hands rule above means everyone sees every hand once pegging is over, so partners' hands are visible to the whole table at counting. Before that there is no hand-sharing between teammates. Decide in Phase 3 whether that is what we want for teams.
   - **Full round sequence, for reference:** Deal → Discard to crib → Cut for starter card → Pegging/play phase (auto-scored, see item 9) → Count hands (each player's own screen) → pone's hand (count aloud → Confirm Count) → dealer's hand (count aloud → Confirm Count) → crib flips, dealer's crib (count aloud → Confirm Count) → both players tap Next Hand → next round, deal passes to the other player.
9. **Auto-scored pegging (play phase):**
   - During the pegging round (playing cards up to 31), the app automatically calculates points as they happen — fifteens, pairs, runs, "go"/last card, and hitting 31 — and adds them straight to the live score tracker in real time.
   - This is a change from a "manual by default" approach: pegging math has to happen fast, in the middle of active play, which is exactly the situation most likely to cause disputes or mistakes — so this one is automatic out of the box rather than an opt-in toggle.
   - The app still enforces/flags illegal plays (going over 31), since it's already tracking the running count to do the scoring.
10. **Support for 2, 3, and 4-player games** — including the different dealing/crib rules for each (detailed below).
11. **Live score tracker (numbers only, not a visual board)** — a simple, real-time number for each player's current score (e.g., "Yoda: 42 — Sam: 37"), synced across everyone's screens as points are logged. This is not an animated board with pegs — just a running number — but it means everyone can glance at their phone and confirm their physical peg is in the right spot, so there's no confusion or arguing about the score, especially a few drinks in. No visual board rendering or theming beyond this (see 2.5).
12. **Admin & table management (for you)** — your account gets an admin role that lets you see all active tables/games and force-end ("kill") any that have been abandoned, without needing to be a player in them. Every game also has a **hard 5-hour timeout** — after 5 hours, it auto-ends on its own, so a forgotten or abandoned session doesn't sit open forever even if no one manually cleans it up. Tables have their own outer limit too: a **hard 12-hour table timeout**, so a table nobody remembered to end (e.g., everyone logged off after a session) doesn't just sit open indefinitely, even across multiple back-to-back games.
13. **Personal appearance (table surface and card back)** — on the Profile page, each player picks their own **table surface** (Classic, Black, Green Felt, Blue Felt, Wood) and **card back** (Classic, Modern Metallic Black, Vintage, Oktoberfish, Plain Black, Standard Red, Standard Blue), with a live preview and its own Save button. The choice is **seen only on that player's own screen** (your cards and the whole table, in your look), is saved to the account so it follows you across devices, and never reaches the other players: it lives in its own owner-only table, `user_appearance`, which is not in Realtime. **Classic is the default** and is exactly the look the app had before this feature (the page's light or dark background, red striped backs); a missing row means Classic. Every non-Classic surface is dark (white text), swaps the green accents for violet, and keeps text contrast at 4.5:1 or better. The same section holds the personal **Hide counts** setting, which hides the hand and crib count numbers on that player's own screen (Section 9, item 25). Face-up card designs, custom uploads and per-table themes are out of scope for now (Section 12).
14. **Landing page and main menu (PR #25)** — the front door of the app, in a fixed "card room" look (green felt, brass and cream).
   - **Signed-out landing:** the Nobs! wordmark, a hero hand (a 29, with the 5 of spades as the starter, no label), rotating taglines, and **Log In** / **Sign Up** buttons in the lower third of a phone screen with a peg-style press effect. A footer with **About** (a native dialog), **Rules** (an external link to Bicycle Cards' cribbage rules) and **Contact** (plain text). A jack-of-spades icon. The site is marked noindex/nofollow, because the taglines are deliberately rude and the app is for friends only.
   - **Signed-in home (main menu):** a greeting (the time-of-day text is worked out on the player's device after the page loads; the server render says "Welcome back"), the player's avatar and nickname, **Start a Table**, an inline 4-digit **Join** field, and the **"Open Tables"** list (Section 9, item 21): the player's own table pinned first with a Rejoin button and its status ("Game in progress", "Between games · with" the other players' nicknames, or "Waiting for a second player"), then the public tables they could join. Small **Profile** and **Log out** links, and an **Admin** link only for admins (read from the player's own `admin_users` row).
   - **Restyled in the same card-room look:** Log In, Sign Up, Start a Table, Join a Table and Profile, all through one shared `CardRoomFrame` component. Styling only: auth and game logic are unchanged.
   - **Decided:** the card-room look is fixed and is **not** tied to the per-player Appearance setting (item 13). One shared table-code validator (`lib/tableCode.ts`) is used everywhere a code is typed. No database changes were made: the home page reads existing tables through the existing RLS.

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
- **New Game is a ready gate (PR #20):** after a won match, the first player to tap New Game is only marked ready (the other screen shows "X is ready"), and the tap that completes the set deals. One tap can no longer start the next match by itself. Readiness is stored on the won game (`games.ready_by`) and persists indefinitely, which is accepted.
- **The final board stays up after a win (PR #21):** a won game leaves the table on screen behind the banner: the starter, the last run of pegging cards, both hands and the crib, with the winning reason in the banner. A refresh rebuilds it from the database, and New Game clears it. Won-game reads are allowed to the players of that game only. A win on the dealer's hand or the crib has not yet been tested live.

**Resolved:** the first built version of cut-for-deal computed the dealer AND dealt all cards atomically in one step, then revealed the cut result as a ceremony layered on top afterward. This was corrected in Phase 2 Slice 5 (the "cut-before-deal" rework) — nothing is dealt until the cut genuinely resolves, drawn one card at a time on demand from a face-down spread, with ties handled via mandatory dual-redraw (Slice 4b). After a won match between the same two players, the loser deals the next match with no re-cut; every other ending cuts for deal again (see the next-hand and next-match notes above).

---

## 8. User Experience Requirements

- Mobile-first, thumb-friendly layout — this is meant to be held and used casually, often one-handed, while also on a Zoom call.
- Your own hand is always clearly visible and unmistakably private (no risk of accidentally showing your screen's contents to the room over Zoom screen-share, if that ever comes up — worth a design note but not a technical requirement).
- **"Count hands"** is the one tap that turns a player's own screen over to the count, and it is theirs alone. **"Confirm Count"** should be clearly visible but only actionable for whoever's turn it is in the counting order, and the UI should make that obvious at a glance (including a plain "[name] is counting" for the player who is waiting).
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

10. **Batch 2b (merged):** Next Hand with the two-player ready gate (dealer rotation and the full per-hand reset), the match loop, New Game as a new match (scores and tracker reset, loser deals after a won match, cut for deal otherwise), and a hardened client that always re-reads the game after any realtime event. Two people can play whole matches back to back.
11. **UI polish stages 1–3 (merged):** fixed-height one-screen table at phone width (nothing scrolls, card sizes stay constant), reworked table regions, and the opponent band as a fixed strip (showing only the top half of the opponent's cards is accepted). Landscape is not done.
12. **New Game ready gate (merged, PR #20):** both players must tap New Game after a win, plus a revoke of stray function grants (ten client-callable functions remain; the helper trigger from Supabase is left alone).
13. **Final board after a win (merged, PR #21):** starter, last run, both hands and the crib stay on screen behind the win banner, rebuilt from the database on refresh (Section 7).
14. **Deployment (done):** live on Vercel with Supabase auth redirects configured (Section 5, Deployment).
15. **Create-table redirect and waiting block (merged, PR #22):** creating a table drops you straight into it with a "Waiting for a second player" block showing the table code and a Copy button.
16. **Open hands in the count (merged, PR #23):** the redesigned counting flow in Section 6, item 8, with two new read policies and a rewritten counting view.
17. **Personal appearance (merged with this update):** table surfaces and card backs, picked on the Profile page and saved per account (Section 6, item 13). Built in three stages: the CSS surfaces (Wood is a cedar photo under a dark scrim), the six card backs (5:7 WebP in `public/cards/backs/`), then saving (`user_appearance` table, `AppearanceProvider` with a per-device cache keyed by user id, a head script so a refresh never flashes Classic, and the Appearance section with its own Save). Verified with two accounts: each sees only their own look at the same table.
18. **Landing page and main menu — DONE (PR #25, merged to main as 86f9ff4):** the Nobs! name, the signed-out landing page, the signed-in main menu with "Your tables", and the card-room restyle of Log In, Sign Up, Start a Table, Join a Table and Profile (Section 6, item 14). No database changes.
19. **Sign-up fix and plain pages — DONE (merged to main with this branch):** with "Confirm email" off, sign-up now returns a logged-in session, so the Sign Up page says "Account created. Taking you in..." and goes home after about a second, with a Continue link in case that is slow. If no session comes back (confirmation turned back on), it still shows the "check your email" message. Log In and Sign Up have autocomplete attributes (`email`, `current-password`, `new-password`) for password managers. The last plain pages moved to the card-room look: a 404 page (`app/not-found.tsx`), the table page's "not logged in" and "table not found / load failed" screens (Retry and "Try a different code" unchanged), and every Admin screen, with the Force-End buttons in light red on dark red so they read clearly and stay distinct from the normal buttons. The table's Loading screen and waiting view still follow the player's Appearance surface. Accounts are created and logged in exactly as before (the page only reacts to what Supabase returns), and there are no database changes.
20. **Table options on creation — PARTLY DONE (merged to main with this branch):** the Start a Table screen now shows all three groups, always visible, each as a fieldset that works by keyboard and screen reader. (a) **Public / Private is live**, default Public, with a one-line hint under it ("Listed in Open Tables" / "Only people with your code can join"). (b) **Scoring: Regular play or Muggins play — DONE (branch feature/muggins-mode):** default Regular; choosing Muggins asks for confirmation first (item 22). (c) **Players 2 / 3 / 4, with Team or Solo for 4 — NOT STARTED:** 2 is selected and the only usable choice; 3, 4 and Team / Solo are disabled and marked "Coming soon" (item 23). Nothing is stored for Players yet. The rest of creating a table is unchanged.
21. **Available tables list (lobby) and the Public / Private toggle — DONE (merged to main with this branch):** there is **no separate lobby page**. The home page has one list, **"Open Tables"**, in place of the old "Your tables" list (a player sits at one table at a time, so one list is enough). It shows two kinds of row, in the same design:
   - **The player's own table(s) first:** every open table they are seated at, public or private, pinned at the top with a subtle brass highlight, titled "Your table", with their own avatar, the status line ("Game in progress", "Between games · with" the other players, or "Waiting for a second player") and a **Rejoin** button.
   - **Then the public tables they could join:** the rule is seat-based: open, public, not one the viewer is seated at, and exactly one player seated -- at least one, so a table everyone has left (it stays open until the 12-hour timeout) or a brand-new one whose creator isn't seated yet is never listed, and fewer than 2, so it has a free seat. Who created the table doesn't matter: a table you created but left shows to you like it does to anyone else. Each shows the nickname and avatar of the seated player ("A player" if there is no profile), how long ago it was opened, and a brass **Join** button. Join and Rejoin both go to the table page, which does the join exactly as a typed code does. A table never appears twice.
   - **Behaviour:** the two reads (own tables, public tables) are independent -- if one fails, what loaded still shows, with a small "Couldn't load tables just now." line, and rows already on screen are never wiped. It refreshes every 15 seconds while the tab is visible, pauses while it is hidden and refreshes at once when it comes back, and has a small Refresh button on the heading line; one refresh at a time. States: "Looking for tables...", "No open tables right now. Start one below.", "Couldn't load tables just now." No Realtime.
   - **Layout:** the list is capped in height (about 2.5 rows at 375x667, the most that fits there; about 3.5 rows on taller screens) and scrolls inside itself, with a thin brass scrollbar and a fade over a part-shown last row when there is more below; it is keyboard-reachable (a Tab stop; arrow keys scroll it). Start a Table and the Join field stay in the lower third at 375x667, 390x844 and 1280x720 with any number of rows. Database: one new column, `tables.is_public` (`docs/sql/table-visibility.sql`), checked by `docs/sql/table-visibility-verification.sql`: **ALL 23 CHECKS PASSED (rolled back)**. No policy or grant changes. The lobby model query in that verification file still has a "not created by the viewer" clause; it is harmless (none of its checks depend on it) and was left alone on purpose.
   - **Decided:** the Start a Table form defaults to **Public** and always sends the choice. The **database column defaults to false**, so existing tables and any insert that forgets the field stay private. **"Private" means unlisted, not secret:** anyone with the code can still join. Visibility is set at creation only; players cannot change it afterwards. An admin can technically change it through the API (the admin UPDATE policy plus a table-level grant); accepted, since Walt is the only admin.
22. **Muggins mode — DONE (once branch feature/muggins-mode merges):** a **table option** chosen at creation, **Regular play** or **Muggins play**, on the Start a Table screen (item 20). SQL: `docs/sql/muggins-mode.sql`, checked by `docs/sql/muggins-mode-verification.sql` (60 checks).
   - **Choosing it:** Start with Muggins selected opens a confirmation (a native dialog, like About): "All scoring is turned off. The app only deals the cards, so you will NEED to keep your own score, on a physical board or a tracker of your choice." with **Go back** (the default, and Escape) / **Start Muggins table**. Only Start Muggins table creates it (`tables.is_muggins`, boolean, default false, fixed once created). A Muggins table carries a **"Muggins · no scoring"** tag in Open Tables and on the table page.
   - **At the table:** scoring still runs on the server, but nothing of it is shown to anyone: no score strip, no score flash, no hand or crib numbers (the recap just says "… counted"), and no score on the result. Pegging messages (Go, last card) stay. The personal Hide counts button (item 25) is locked, reading "Muggins: scoring is off", and saves nothing. **121 never ends the game:** `award_points` skips the win on Muggins tables (the score is still recorded, capped at 121).
   - **Ending a match, only by agreement:** the strip's place holds two buttons. **"I win"** is a toggle: it claims the win (`claim_win`), and while I hold the claim it reads "Waiting for <name>… (tap to cancel)" and takes it back (`clear_win_claim`). The other player then sees "<name> says they won", and **"Confirm loss"** (`confirm_win`, one tap, no extra dialog) ends the match with `ended_reason` 'won' and `winner_id` = the claimant (`games.win_claim_by` holds the claim). Then the normal New Game flow runs: every player taps New Game and the loser deals. Leaving, an admin Force-End and the timeout record **no winner**, so a future leaderboard counts only games with `ended_reason` 'won' and a `winner_id`.
   - **Phase 3 note:** for 3 and 4 players, `confirm_win` must require **every** other player's confirmation before the match ends. `next_hand` rotates the dealer in join order, not seating order.
23. **Phase 3: 3 and 4 players — NOT STARTED:** with Team or Solo for 4 players (see Phase 3 below).
24. **Game-available notifications (low priority) — NOT STARTED:** a Profile toggle to be notified when a game is available. Needs a delivery method first: browser push (awkward on iPhone) or email (which needs the email sender in Section 5, Deployment).
25. **Hide counts (personal) — DONE (merged with this branch):** a per-player display setting, saved on the account like the card back and table surface (`user_appearance.hide_counts`, boolean, default false; `docs/sql/hide-counts.sql`, checked by `docs/sql/hide-counts-verification.sql`: 20 checks). When it is on, that player's own screen hides the hand and crib **count numbers**: the count recap says only "Your hand counted" / "Elsa's crib counted", the score flash is skipped for count awards (pegging flashes and his heels still show), and a win on a count shows "You win! 121" with no breakdown. The **score strip stays and still moves** (accepted: the jump is the honest check). It changes nothing for other players and nothing on the server: scoring, awards and win detection are untouched. It is set in two places, both saving the same setting: a "Count numbers" switch in the Profile page's Appearance section (saved with Save Appearance), and a small **"Counts: shown / hidden"** toggle in the table header beside Leave, which saves at once. Off by default.

**Next up:** muggins mode (item 22), then Phase 3 (item 23), then notifications (item 24). Each fills in its "Coming soon" group on the Start a Table screen (item 20). Muggins mode comes before Phase 3 because it is small and Phase 3 is large.

Update this list as slices land rather than trusting memory of the original plan — it's already been wrong once.)*
- Shared deck + dealing logic
- Private hand display for each player
- Real-time reveal of played cards during the pegging phase
- Live score tracker (numeric only — Section 6, item 11)
- Auto-scored pegging during the play phase (Section 6, item 9)
- Counting-phase flow — Count hands, every hand face-up, count aloud, Confirm Count, repeated in order, ending with the crib (Section 6, item 8)
- Goal: two people can log into a shared table and play a full, correctly-scored 2-player game start to finish, with cards, pegging points, and hand scores all handled by the app, and physical boards kept accurately in sync

**Phase 3 — 3 and 4 player support:**
- Extend dealing/discard logic for 5-card hands + dealer's extra draw (3p) and shared crib (4p teams)
- Extend real-time sync, auto-scored pegging, and the Show Hand / Confirm Count counting flow to more players
- Confirm 4-player team hand-visibility behavior in practice (no auto-sharing between partners — see Section 6, item 8)
- Players are stored in join order, not seating order. Phase 3 needs real seating (left, right, top) behind the layout convention in Section 8
- 4 players: decide between teams and individual play (an option on the table), with score plates per team or per player; layout stage 5 covers the 3 and 4 seat screens

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
- [ ] After pegging every hand is face-up for both players, and "Confirm Count" (turn-gated) correctly calculates, logs, and advances scoring in order — ending with the crib.
- [ ] Pegging points (fifteens, pairs, runs, go/last card, 31) are calculated and added to the live score tracker automatically and correctly during play, with illegal plays (going over 31) flagged.
- [ ] As the admin, you can view all active tables/games and force-end an abandoned one; any game left running for 5 hours auto-ends, and any table left open for 12 hours auto-ends, on their own.
- [ ] The app works comfortably on a phone browser held in one hand during a Zoom call.
- [x] Each player can pick their own card back and table surface on the Profile page, sees it only on their own screen, and it follows them across devices (verified with two accounts, October 2026).
- [ ] You understand *how* the core pieces work (deck logic, realtime sync, scoring) well enough to explain them back, not just that they work.

---

## 11. Open Questions (to resolve before/during building)

*(None remaining — every open question raised during PRD review has been resolved in the sections above.)*

---

## 11.5 Tracked Polish Items (noticed during playtesting, not blocking current build)

Small UI/UX adjustments observed while actually playing, logged here so they aren't forgotten — not urgent, not scope changes, just real feedback waiting for a convenient slice to address:

- **DONE (polish stages 1–3; landscape still open) — the table must never outgrow the screen (layout rule for the whole polish pass):** this is mainly a shared deck and table space, used on a phone, so screen space is at a premium. Currently, when pegging starts a second row of played cards, the card sizes change and the page grows taller, forcing the player to scroll to reach their hand, the count or the scores. Rule: the whole table (both hands, the play area, the crib, the starter, the count and both scores) fits one screen with no scrolling, at phone width, even in the worst case of a full pegging round. The play area has a fixed height; more played cards overlap or fan out like a physical table instead of wrapping to a new row, and card size stays constant. Noticed while playing on a laptop during Batch 2b testing. Related to "Played cards should render in front of each player" below.
- **"Hand N" label (small):** show the hand number from `games.hand_no` as a tiny label near the table code, with no extra space taken. Optional.
- **Crib pile positioning:** currently rendered dead-center of the table. Preference is to move it off to the side — near/offset from the dealer's hand, not centered. Purely a layout change, no data/logic impact.
- **DONE (PR #22) — "Start a Table" should skip the extra step:** currently, creating a table requires then separately joining it, even though you're the creator. Preference: creating a table should immediately drop the creator into the table's waiting screen (same as if they'd joined), rather than requiring a manual join step for a table they just made. The table code is already visible in the corner for sharing with the other player — no need to make the creator copy/paste/re-enter it themselves.
- **DONE (PR #21) — after a win, keep the final board visible:** currently the play area is wiped when a game ends and only the win banner shows. A win on his heels in particular feels abrupt, because nobody can see the jack that caused it. Preference: keep the starter, the crib and the last cards played visible behind or beside the banner so the winning moment is readable. (The banner already says why the game ended, e.g. "fifteen (+2)" or "his heels (+2)".) Noticed during Batch 2a testing.
- **An opponent's shown hand appears in a different card order than its owner sees:** cosmetic, noticed during Batch 2a testing. Shown hands should use one consistent order on both screens.
- **Repeated GO rows (confirmed, harmless):** duplicate `go` rows can be logged for a player who is stuck while the other keeps playing. Turns, the running count and scoring are all correct. Clean the rows up in the manual Go batch below. Section 7's "exactly one go event" wording describes the intended design, not guaranteed behavior.
- **Remove the "[Name] said go" message during pegging (done in Batch 1):** noticed during Slice 7 testing that this message caused confusion around the deadlock/double-go case (only one player's go gets an explicit event logged — see Section 7's pegging notes — so the message reads as if the second stuck player's go was "missed" when the turn/count outcome is actually correct). The underlying `game_plays` go events stay recorded and functional either way; this is purely about removing a UI message that misleads more than it helps.
- **Sort button intermittently stuck (seen once, not reproduced):** after Next Hand in Batch 2b testing, one screen's Sort button did not work until a manual refresh. It did not recur in later runs. The same root cause as a separate bug (a screen sitting on an out-of-date snapshot of the game, after the page missed a realtime update) was fixed in Batch 2b by re-reading the game after every event, so this may already be fixed. Re-log here if it comes back.
- **Played cards stay in one shared play area (decided):** the earlier idea of putting each player's played cards in front of their own seat is dropped. The shared play area stays, and the "cards in front of each player" wording is retired.

**Queue (from live testing and review, October 2026):**

- **Manual, server-validated Go button:** its own batch. Includes cleaning up duplicate go rows.
- **Broad read access (existing, still to do):** any signed-in user can read `tables`, `table_members` and `games`. Tighten to "members, plus listed (public) tables for Open Tables". The join-by-code flow has to be redesigned first (for example a join function), because a non-member must look a table up by its code before they are a member. Do it as its own reviewed SQL change.
- **Stale public tables:** a player who closes the tab without leaving is still counted as seated, so their public table stays in Open Tables until the 12-hour timeout. Consider hiding tables older than a few hours, or tracking presence.
- **DONE (branch fix/table-sync) — a screen sometimes stopped updating until refreshed:** seen in live two-account tests as a waiting view that missed the joiner, and as a screen left showing its six dealt cards after a discard. Fixed on the table page: the four-card hand is always fetched after a discard, and an older hand read can never overwrite a newer one; the page catches up on every realtime subscribe, the first one included; a guard stops a slow members read from removing a player that a newer join just added; the page re-reads when the tab becomes visible or the device comes back online; and a light safety poll every 12 s (only while the tab is visible and no action is in flight) repairs anything a missed event left wrong and logs `[table-sync] poll repaired:` to the console. No database changes.
- **`/tables/join` is now redundant** with the Join field on the home page. Decide whether to keep it as a fallback or remove it.
- **Landscape layout (polish stage 4)** and **3 and 4 seat layout (stage 5, teams or individual, score plates per team or player).**
- **Duplicate waiting text:** the top band still says "Waiting for another player to join..." above the new WaitingForPlayer block. Remove the band text.
- **Opponent band shows only the top half of the cards:** accepted for now.
- **Count hands is per screen:** one player's screen can flip before the other's. Decided to keep, since each player controls when they look.
- **Optional idea:** tap-to-flip reveal of the opponent's hand.
- **Housekeeping:** delete the unused PlayerScore file; check the login page against `viewport-fit=cover`; update the handoff doc's function table (`start_game_with_deal` now lives in its own SQL file, the revoke is done, ten grants plus the Supabase `rls_auto_enable` trigger).
- **Contrast, existing and out of scope of the appearance work:** the white "D" on the amber dealer chip (about 2.1:1) and the "Your turn" pill (about 3.2:1 on Classic's green) are below 4.5:1. The pill passes in violet on the non-Classic surfaces. Fix both in one small pass. Also noted: the border of an unselected swatch in the Profile page's Appearance section is only 2.01:1. That is acceptable, since the selection is shown by the ring and the bold label.
- **Appearance ideas, later:** face-up card designs, more surfaces, custom uploads, a "Preview on a real table" button on the Profile page. Adding a back or a surface means changing `lib/appearance.ts`, its CSS, AND the CHECK on `user_appearance` (drop and re-add the named constraint).
- **Test live:** a win on the dealer's hand and a win on the crib (the pone's count win and the pegging wins have been tested).
- **Friend-testing risks:** the first friends test ran on October 15, and the email finding is recorded in Section 5, Deployment. The remaining risk is that the Supabase free-plan project pauses after about a week of inactivity.

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
- Face-up card designs, custom uploaded card backs, per-table themes, and showing your look to the other players (appearance v2; see Section 6, item 13)
- Spectator mode
- Native mobile app (iOS/Android app store install)
- Virtual board / animated peg tracking / visual theming (cut in this revision — see 2.5; a simple numeric score display remains in scope, see Section 6)

---

*This PRD is a living document — as we build and learn things, we'll come back and update it rather than let it go stale.*
