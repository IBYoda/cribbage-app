# Cribbage App — Handoff Notes for Claude Code

**Purpose of this file:** Context for a fresh Claude Code session working in this repo. Drop this into the chat (or save as part of `AGENTS.md`) so it doesn't have to be re-explained.

---

## What this project is

A real-time multiplayer cribbage companion app for 2-4 players, playing remotely over Zoom with physical cribbage boards. The app handles the parts that are broken when everyone deals from their own physical deck — a shared virtual deck, private hands, and score tracking — while players keep their physical boards and pegs for the tactile part of the game.

**Full requirements live in the project's PRD** (`cribbage-app-prd.md` — ask the user for it if not already in this folder). Key decisions worth knowing without re-reading the whole thing:

- Responsive **web app** (not native mobile) — Next.js, works in a phone browser
- **Confirm Count** and **auto-scored pegging** calculate all scores automatically — nothing is typed in manually
- **Show Hand** is a voluntary, always-available reveal button (not turn-gated); **Confirm Count** is turn-gated
- Structure is **Table** (persistent room, 4-digit join code) → can host multiple **Games** (one match to 121) back to back via "New Game," without leaving the table
- Real accounts (Supabase Auth) with profile icon + editable game nickname
- Admin role for the project owner: view/kill abandoned tables & games; 5-hour game timeout, 12-hour table timeout, both automatic
- 4-player teams do **not** auto-share hands between partners
- Player stats ("19"s, skunks, stink holes, etc.) are an explicit **stretch goal**, deliberately not tracked in v1 — no need to build hand-level logging now

## Tech stack

- Next.js (App Router, TypeScript, Tailwind) — scaffolded via `create-next-app`
- Supabase — Auth, Postgres database, Realtime
- Vercel — hosting (not yet connected)
- This is a **completely separate** GitHub repo / Supabase project / Vercel project from the user's other app (Hello Fresh Helper). Nothing is shared between them.

## Current state

- **Phase 1:** complete.
- **Phase 2, Batch 1** (the scoring engines): merged to `main` as PR #16.
- **Phase 2, Batch 2a** (counting, crib scoring, win at 121): built on branch `feature/counting-and-rounds`, **not yet merged**.
  - **SQL:** `phase2-batch2a-counting.sql` is applied, and `phase2-batch2a-verification.sql` queries 1–7 pass.
  - **UI:** the counting UI in `app/tables/[code]/page.tsx` passes typecheck, lint and build, but has **not been browser-tested**. `docs/batch2a-manual-test-plan.md` is the plan.

A hand now plays from New Game through pegging and counting to `phase = 'done'`, and the first player to 121 wins on the spot. From `done` there is no way forward yet except Leave.

### In the database

All SQL lives in `docs/sql/` for history; there is **no Supabase CLI or migrations setup**. The user runs every file by hand in the Supabase SQL Editor. Where a function was redefined across slices, the **last file to define it is the live version**.

Tables: `profiles`, `tables`, `table_members`, `games`, `game_hands`, `game_decks`, `game_cribs`, `game_plays`, `admin_users`.

Functions, with the file holding the current definition:

| Function | Current definition | Client-callable |
|---|---|---|
| `card_rank_value` | `phase2-slice-4-cut-for-starter.sql` | no |
| `card_play_value` | `phase2-slice-7-pegging-turns.sql` | no |
| `shuffled_deck` | `phase2-slice-4-cut-for-starter.sql` | no |
| `has_legal_play` | `phase2-slice-7-pegging-turns.sql` | no |
| `award_points` | `phase2-batch2a-counting.sql` | no — capped at 121; reaching 121 ends the game as `won` |
| `score_pegging` | `phase2-batch1-scoring-engines.sql` | **no — deliberate** |
| `score_hand` | `phase2-batch1-scoring-engines.sql` | **no — deliberate** |
| `start_game_with_deal` | `phase2-slice-5-cut-before-deal.sql` | yes |
| `draw_cut_card` | `phase2-slice-5-cut-before-deal.sql` | yes |
| `acknowledge_deal_cut` | `phase2-slice-5-cut-before-deal.sql` | yes |
| `deal_cards_for_game` | `phase2-slice-5-cut-before-deal.sql` | no — internal, called by the cut functions |
| `discard_to_crib` | `phase2-batch1-scoring-engines.sql` | yes |
| `play_card` | `phase2-batch2a-counting.sql` | yes — region (H): entering counting sets `current_player` to the pone |
| `show_hand` | `phase2-batch2a-counting.sql` | yes — `counting`/`done` only |
| `show_crib` | `phase2-batch2a-counting.sql` | yes — dealer, step 2 only |
| `confirm_count` | `phase2-batch2a-counting.sql` | yes — `(game, p_step)`; scores with `score_hand` server-side |
| `leave_table` | `phase2-slice-5-cut-before-deal.sql` | yes |
| `end_timed_out_sessions` | `phase2-slice-5-cut-before-deal.sql` | no (pg_cron, every 15 min) |

**Live grants that disagree with this table.** 2a's grants check found `card_rank_value` and `shuffled_deck` granted to the client in the real database, although they are listed above as not client-callable, plus `rls_auto_enable`, which this project's SQL never defines and appears to come from the Supabase platform (not verified). `phase2-batch2a-verification.sql` query 3 tolerates all three so it can judge 2a on its own. Nothing secret is exposed: `card_rank_value` is a pure lookup, and `shuffled_deck` returns a fresh random deck, not the game's. They should still be revoked deliberately in a later slice. See Known loose ends.

`games` columns: `id`, `table_id`, `status`, `created_by`, `created_at`, `players`, `dealer_id`, `discarded_by`, `deal_cut`, `deal_cut_ack_by`, `starter_card`, `phase`, `current_player`, `play_count`, `play_segment`, `ended_reason`, `count_step`, `revealed_by`, `crib_revealed`, `winner_id`.

- `status`: `open` → `cutting` → `active` → `ended`. A partial unique index allows only one live game per table. `ended_reason` is `admin`, `timeout`, `player_left` or `won` (Batch 2a).
- `phase`: `discard` → `play` → `counting` → `done` (Batch 2a). In `counting`, `count_step` 0 is the pone's hand, 1 the dealer's hand, 2 the crib, and `current_player` names who acts. Nothing consumes `done` yet; `next_hand` is Batch 2b.
- **Check status before phase.** An ended game keeps whatever phase it had: a win on his heels leaves `play`, a win mid-count leaves `counting`.
- `revealed_by` / `crib_revealed` are the only record of what's shown. The `game_hands` and `game_cribs` read policies check them, and neither table is in the Realtime publication.

`table_members` carries the score: `score`, `last_points`, `last_reason`, `last_awarded_at`.

Exactly **nine** functions are meant to be granted to `authenticated`: `start_game_with_deal`, `draw_cut_card`, `acknowledge_deal_cut`, `discard_to_crib`, `play_card`, `leave_table`, `show_hand`, `show_crib`, `confirm_count`. Everything else is meant to be internal, reachable only from inside another function. The check is `docs/sql/phase2-batch2a-verification.sql` query 3, which lists every grant rather than naming a few. The three live exceptions are described under the table above.

### What Batch 1 added

- **`score_pegging(text[])`** — pure, immutable, ungranted. Fifteens, pairs/pair royal/double pair royal, runs of 3+. Returns `{points, reason}`; the reason feeds the score tracker's `+5 — fifteen + run of 3` flash.
- **`score_hand(text[], text, boolean)`** — pure, immutable, ungranted. Fifteens, pairs, runs including double/triple/double-double, flush (hand 4-or-5, crib 5 only), nobs. Returns a six-field breakdown. **Deliberately excludes his heels.**
- **`play_card`** — scoring wired in. One aggregated `award_points` call per play, after the resolve block, because the go point and whether the hand just ended are only known there. Changed from Slice 7 in six banner-marked regions `(A)`–`(F)`; all seven guards and the row lock unchanged.
- **`discard_to_crib`** — his heels (dealer +2 for a jack starter) at cut time, region `(G)`.

### In the repo

- `app/` — `login`, `signup`, `profile`, `admin`, `tables/new`, `tables/join`, `tables/[code]` (the main table page, ~1100 lines, one Realtime channel per table)
- `components/` — `PlayingCard.tsx`, `PlayerScore.tsx`, `PlayArea.tsx`, `CutForDealView.tsx`
- `lib/` — `supabase.ts`, `cards.ts` (`cardPlayValue`, `cardRankValue`, `sortHand`, rank/suit parsing), `scoring.ts`
- `scripts/` — `test-scoring.ts`, `ts-resolve.mjs`
- `docs/` — this file, `cribbage-app-prd.md`, `batch1-manual-test-plan.md`, `CribbageBasics.pdf`, `images/`, `sql/`

**`lib/scoring.ts`** mirrors both SQL scorers in TypeScript. It is **display-only**: the authoritative scorers stay in the database, so the client can never supply or influence a point value. Batch 2's Confirm Count must follow the same rule.

## What's next

1. **Finish Batch 2a.** Browser-test it (`docs/batch2a-manual-test-plan.md`), then merge.
2. **Batch 2b, designed but not built.** One `games` row is now one **match**, decided at the Batch 2 design checkpoint.
   - **`next_hand(game, p_hand_no)`:**
     - Either player can call it from `done`.
     - It deletes the hand's `game_hands`, `game_cribs`, `game_decks` and `game_plays` rows.
     - It resets the per-hand `games` columns, including `revealed_by` and `crib_revealed`, in the same transaction as the deal.
     - It rotates the dealer and bumps `hand_no`.
   - **Match loop:** scores persist across hands; the loser of a match deals first in the next one.
   - **Score reset at New Game,** inside `start_game_with_deal`. Until this lands, run `testing-force-near-win.sql` query B before a new game.
   - **The won → New Game flow.** The win banner itself already landed in 2a.

The double-award trap still applies: his heels is awarded only in `discard_to_crib` and never in `score_hand`, so a jack starter is worth 2 in total, not 4. `next_hand` must clear `starter_card` so each hand gets exactly one fresh cut.

## Hard-won technical lessons

Each of these cost real debugging time. The "why" is the part worth keeping.

- **RLS is deny-by-default, and `security definer` functions bypass it entirely.** They run as the owner (`postgres`, and `force_rls` is false), so they must do their own authorization — the internal guards are the only protection. Use `select ... for update` on the `games` row to serialize two players clicking at the same instant.
- **RLS is row-level, not column-level.** Granting UPDATE on a row exposes every column of it.
- **New functions are not client-executable by default — but only because the project was explicitly changed.** Supabase's bootstrap grants EXECUTE to `anon`/`authenticated`, and `revoke ... from public` does **not** remove those. Slice 6b added `alter default privileges in schema public revoke execute on functions from anon, authenticated`. Still write `revoke all ... from public` and grant nothing unless the client genuinely needs it: a forgotten revoke fails silently and dangerously, a forgotten grant fails loudly on first use.
- **`card_rank_value` and `card_play_value` must never be conflated.** Rank is the ordinal (A=1…K=13) and is what runs and cuts use; play value is the counting value (A=1, T/J/Q/K=10). Conflate them and J-Q-K stops being a run while three tens start looking like one.
- **`game_hands.cards` is immutable after the discard.** What a player still holds is derived by subtracting `game_plays`, which is also how `has_legal_play` works. A client that could rewrite a hand mid-play could cheat.
- **`award_points` overwrites `last_points`/`last_reason`, so make ONE aggregated call per action.** Two calls would leave the tracker flashing only the final component — a 6-point play reading `+2 — pair` is actively wrong. `last_*` is per-member, so it only ever shows the most recent award.
- **`text[] || 'literal'` fails at runtime with `22P02 malformed array literal`.** A bare quoted literal is of type `unknown`; with `text[]` on the left, Postgres resolves `||` to array concatenation and tries to *parse* the literal as an array. Use `array_append(arr, 'x'::text)`. Typed operands (`p_cards || p_starter`) are fine — it is specifically untyped literals that break.
- **PL/pgSQL expressions are not validated until first execution.** `create or replace function` succeeding proves nothing. The `22P02` above survived review and only surfaced on the first real call, which is why a cross-check must exercise *every* function it ships.
- **The go point is awarded from control flow, never by reading the go event's `user_id`.** In a deadlock exactly one go event is logged, and it belongs to the *other* player — the point goes to whoever played the last card of the segment. The `GO` chip in `PlayArea.tsx` is display-only.
- **A 31 scores 2 and no go or last-card point, even on the final card of the hand.** The 31 replaces the last-card point rather than stacking with it. This is the standard rule and the two code paths collide, so it needs a specific eight-card sequence to test.
- **Supabase Realtime is a live stream with no catch-up.** A client that was disconnected never learns what it missed, so reconnection needs an explicit resync. DELETE payloads carry only replica-identity (PK) columns.
- **`GAME_COLUMNS` in `app/tables/[code]/page.tsx` must stay ONE string literal.** Splitting it into `"a" + "b"` widens the type and supabase-js loses its inference, returning `GenericStringError`.
- **React lint rules here are strict.** No `setState` in an effect body, no impure calls during render (`Date.now()`), and state updaters must be pure because StrictMode double-invokes them.

## Workflow rules (please follow these)

- **Create the feature branch as the FIRST action of the session** — `git checkout -b feature/whatever`, before any code is written. Never build on `main`.
- **After that, run no git commands at all.** No add, commit, push, merge — not even read-only ones unless the user asks. The user runs all git themselves.
- **Never run SQL.** Write it to `docs/sql/` for the user to review and run in the Supabase SQL Editor. The same goes for verification queries.
- **Every SQL change is reviewed before it is run** — the user takes it to the PRD/review chat first. Expect to be asked for a `diff -u` of changed function bodies against the previous slice's file, with every changed line inside a marked region.
- **Design checkpoint before any SQL is written.** Describe the approach, get explicit approval, then write it.
- **Small, testable vertical slices** — one feature end-to-end and validated before the next. If something can't reasonably be split further, say so explicitly rather than quietly bundling extra things in.
- **Do a real reconnaissance pass** before touching the Supabase schema or anything external. Check the actual current structure; don't assume.
- **Explain the "why," not just the code** — the user is learning to direct AI-assisted development.
- **Give full end-to-end testing instructions**, and say plainly what could and could not be verified. Don't imply confidence that isn't there.
- **Audit against the CURRENT state of the app**, not against the slice description or an earlier assumption.
- User is on **PowerShell (Windows 11)** — quote paths containing `[` or `]`, e.g. `app/tables/[code]/page.tsx`.

## Test tooling

```bash
npm test             # all stages, ~35s (the exhaustive pass is 26M scorings)
npm run test:quick   # skips the exhaustive pass, ~2s
npm run test:sql-cases  # regenerates the VALUES list for the score_hand cross-check
```

`scripts/test-scoring.ts` needs no framework and no build step — Node 24 runs TypeScript directly. `scripts/ts-resolve.mjs` is a resolve hook that fills in the `.ts` extension Node's ESM resolver demands, so `lib/` can keep the extensionless imports the bundler uses.

Current status: **PASS, 124 assertions.** The exhaustive stage checks `lib/scoring.ts` against an independent brute-force scorer over all 12,994,800 hand-and-starter combinations, both as a hand and as a crib, with zero mismatches. It also asserts the cribbage facts neither implementation knows: reachable totals are exactly 0–29 except 19, 25, 26 and 27, and exactly four hands score 29.

- `docs/sql/phase2-batch1-verification.sql` — three read-only queries: the `score_pegging` cross-check (31 cases), the `score_hand` cross-check (22 hands × both `is_crib` values), and the grants check. All three passed in the real database. Each folds its verdict into a window function so an empty grid can't be misread as a pass.
- `docs/sql/testing-force-pegging-hands.sql` — forces the rare pegging shapes (an exactly-31 final card, a mid-hand deadlock) by rewriting `game_hands.cards` as the table owner. Testing only; the app can never do this.
- `docs/batch1-manual-test-plan.md` — the five things automation can't reach: the score flash, go attribution in a deadlock, 31 as the final card, the last-card point, and his heels.

**The test table used throughout was code `3026`.** The force-hands helper has `'0000'` as a placeholder; set it before running.

## Known loose ends

- **Possible repeated `GO` rows for one stuck player — UNVERIFIED.** If a player is stuck for several consecutive plays while the other keeps playing, `play_card` may log a go event each time, so the history could show several `GO` chips in one segment where one would read better. Never observed; noticed by reading the code. Worth a look before polishing the play area.
- **UI polish, not blocking:**
  - ~~Remove the "said go" message under the played cards~~ — **done in Batch 1** (the inline `GO` chip already said it, and it was the wrong place to explain a point).
  - Play area layout — several segments stack up on a phone.
  - Crib positioning — the crib has no visual home on the table yet.
  - Auto-join on create table — the creator currently has to join their own table.
- **Client grants that shouldn't exist.** `card_rank_value` and `shuffled_deck` are executable by the client in the live database, contrary to the function table. Low exposure (see the note under the table), but worth a deliberate `revoke` in a later slice. `rls_auto_enable` is also granted; it isn't defined by this project and appears to be Supabase's own.
- **No next-hand flow and no match concept yet.** Win detection landed in Batch 2a. A game now sits in `phase = 'done'` after the crib is counted, with no way forward except leaving. `next_hand`, the match loop and the score reset are Batch 2b.
- **Scores cannot be reset** except by leaving and rejoining the table. A `matches` entity would make this one `update ... set score = 0`.

## Slice numbering

Numbering note: Phase 1 used a single running count, Slices 1-8. Phase 2 restarted numbering at Slice 1 (per-phase, not global) — the deal-cards work is "Phase 2, Slice 1" in this document, even though its SQL file and early commits are labeled "slice-9" from before this was decided. All future Phase 2/3 work uses per-phase numbering.

Batch 1 was the first unit of work scoped as a **batch** rather than a slice: three related engines built together because splitting them would have meant shipping a scorer nothing called. Expect Batch 2 to be scoped the same way.
