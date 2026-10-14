# Phase 2, Batch 2b — manual test plan

Batch 2b adds the next hand, the match loop, and New Game as a new match.
`next_hand` deals the following hand from `done`. The dealer rotates every
hand. New Game resets both scores and clears the tracker, and the loser of a
won match deals first. Every other ending cuts for deal.

> **Status:** the 2b SQL is applied, and verification queries 1, 2, 4 and 5
> passed. The 2b UI is built: the Next Hand button, the reset when a new hand
> arrives, and New Game landing in a new match. It passes typecheck, lint and
> build, and Parts 3–4 describe it as built, but it has **not** been tried in
> a browser yet. Part 5 is the 2a carryover.

## What each part proves

| Part | What | How |
|---|---|---|
| 1 | Column, grants, 52-card integrity | `phase2-batch2b-verification.sql` queries 1–3, read-only |
| 2 | `next_hand` and `start_game_with_deal`, every path, as real players | Queries 4 and 5, rolled back |
| 3 | A full match across several hands, on two screens | Two browsers |
| 4 | The won → New Game flow | Two browsers + `testing-force-near-win.sql` |
| 5 | 2a carryover: the 2a checks that still need a person | Two browsers + `testing-force-near-win.sql` |
| 6 | Regression | Batch 1 / 2a cross-checks |

---

## Setup

1. Two browsers (or one plus an incognito window), signed in as two
   different accounts, both at the test table. Keep the SQL Editor open in a
   third tab.
2. Start with **New Game**. Since 2b it resets both scores itself.
   `testing-force-near-win.sql` query B is only needed to undo a forced score
   within a game.

---

## Part 1 — static checks (read-only)

| Query | Pass |
|---|---|
| 1 | `hand_no`, integer, NOT NULL, default 1 |
| 2 | 10 rows `ok` (2a's nine plus `next_hand`), up to 3 `known pre-existing`, verdict `PASS` on every row |
| 3 | Every live game: total 52, distinct 52, crib size 0/2/4, `ok` |

Run query 3 again at several points in Part 3: after a Next Hand, mid-discard
and after the cut. The invariant holds at every moment of a hand. A stale
hand, deck, crib or starter left over from `next_hand` would break it.

## Part 2 — the walk-throughs (rolled back)

**Query 4: next hand.** Play a hand to `done` (every count confirmed, crib
included) **without tapping Next Hand**, set the table code, run it.

**Pass:** `ALL 29 CHECKS PASSED (rolled back)`. It proves:

- A stranger, a hand number ahead of the game, a null hand number, and a
  call on an ended game are all refused.
- **The ready gate** (`phase2-batch2b-ready-gate.sql`):
  - the first player's tap succeeds but deals nothing: `hand_no`, phase and
    dealer are unchanged, `ready_by` is just that player, and they still
    hold their old four cards;
  - a repeat tap by the same player is quiet and changes nothing.
- The second player's tap does all of this:
  - moves `hand_no` on by exactly 1;
  - passes the deal to the old pone;
  - resets every per-hand column, `ready_by` included;
  - keeps status, players, the match clock, scores and the whole tracker.
- **Privacy:** each player can read only their own new hand. The reveals were
  cleared in the same transaction as the deal.
- No plays and no crib survive. Two 6-card hands plus a 40-card deck hold 52
  different cards.
- The other player's stale tap (the old hand number) is quiet, changes
  nothing, and does **not** redeal: the cards are identical before and after.
- Calling during the new hand's discard is refused.
- There's no starter yet, so his heels can't carry over.

**Query 5: New Game.** It works on any 2-member table that has had a game.
It ends whatever is live, as the table owner, and rolls everything back.

**Pass:** `ALL 15 CHECKS PASSED (rolled back)`. It proves:

- **A. Won match, same two players:**
  - the game starts `active` with the **loser** dealing, even though the
    winner tapped New Game;
  - it's in exactly the state a resolved cut leaves;
  - both scores are 0 and the tracker is cleared;
  - the hands are dealt;
  - a racing second New Game returns the same game, does **not** reset a
    score scored meanwhile, and does not deal again.
- **B. Previous game timed out:** the game starts `cutting` with no dealer and
  nothing dealt. Scores are still reset.
- **C. Won match, different roster:** the game starts `cutting`.

Both queries run as each player through the real grants, using the same
impersonation as 2a's queries 6 and 7. They also switch back to the table
owner (`reset role`) to inspect tables no player can read. That switch-back
is new in 2b and untested on this project. If either query fails with a
permission error on `game_decks` or `game_plays`, that switch-back is the
cause, not the functions.

## Part 3 — a match across hands

1. **Hand 1 to `done`.** After the dealer confirms the crib, both screens
   show:
   - in the counting banner, **"Every hand and the crib are counted."** with
     **"Next dealer: X"** below it, where X is the current pone. On X's own
     screen it reads **"Next dealer: you"**;
   - a **Next Hand** button, enabled on **both** screens;
   - both hands, the crib (with its breakdown) and the starter, still
     face-up.
2. **The first player taps Next Hand. Nothing is dealt yet.** Their button
   reads "Sending..." briefly. Then, without a refresh:
   - on **their** screen the button is greyed out, with
     **"Waiting for <other player>…"** beneath it;
   - on the **other** screen, **"<first player> is ready"** appears above a
     still-active Next Hand button;
   - everything from hand 1 stays face-up on both screens, and the scores
     don't move.
3. **Refresh the waiting player's browser.** It comes back in `done` with
   the button still greyed out and "Waiting for <other player>…". That state
   comes from `ready_by` in the database, not from the page.
4. **Double-click on the waiting screen.** Nothing extra happens and no error
   appears: the button is disabled, and the server treats a repeat tap as
   quiet anyway.
5. **The second player taps Next Hand. This deals.** On **both** screens,
   without a refresh:
   - the counting banner, the shown hands, every breakdown line, the crib
     and the starter are gone;
   - the middle reads **"Pick 2 cards for your crib"** on the new dealer's
     screen and **"Pick 2 cards for their crib"** on the other;
   - each player sees six new cards, unsorted (Sort is available again). The
     opponent's seat shows six face-down cards;
   - the "· dealer" label has moved to X;
   - scores are unchanged, and **no score flash** appears;
   - **no "ready" or "waiting" line** carries over into hand 2. Check this
     again when hand 2 reaches `done`: both buttons start enabled, with
     neither line showing.
6. **Both tap Next Hand at the same moment.** Exactly one new hand is dealt,
   and neither screen shows an error. Query 3 shows 52 distinct cards, and
   `hand_no` went up by 1, not 2.
7. **Play hand 2 through.**
   - Discard, cut, pegging and counting all behave as in hand 1.
   - The **new dealer's** opponent leads and counts first.
   - Nothing shown in hand 1 reappears.
8. **His heels in a later hand.**
   - Before the second discard of hand 2 or later, force a jack starter
     (`testing-force-pegging-hands.sql` query E).
   - The **current** dealer gets exactly +2 `his heels`, once.
   - The previous hand's dealer gets nothing.
   - After counting, the dealer's total is 2 + pegging + hand + crib, never 4
     for the jack.
9. **Refresh mid-hand-2**, once during discard and once during counting. The
   page comes back on hand 2 with:
   - the right dealer label;
   - your own hand;
   - the play history of hand 2 only;
   - no reveals left over from hand 1.
10. **Leave during `done`.**
   - One player taps **Leave → End game & leave**. Try it once while the
     other player is on "Waiting for …".
   - The other sees the amber notice **"A player left the table — the game
     was ended."**, the Next Hand button disappears with no error, and the
     New Game button comes back.
   - Query 3 shows no live game for the table, and no new hand was dealt.

## Part 4 — won → New Game

1. Win a match. The quickest way is `testing-force-near-win.sql` scenario C
   (set a player to 120 during play). Note who lost.
2. Both screens show the green win banner from 2a, e.g. **"You win! 121 —
   fifteen (+2)"** for the winner and **"<name> wins! 121 — …"** for the
   other, with the final scores and **New Game** beneath it.
3. **Either player taps New Game** (it reads "Dealing..." while pending). On
   **both** screens:
   - the banner disappears;
   - both scores read **0** with **no flash**;
   - **the loser** has the "· dealer" label straight away, with **no cut
     screen**;
   - each player holds six cards, and the middle reads "Pick 2 cards for …
     crib".
4. **Simultaneous New Game.** Win again, then tap New Game on **both**
   screens at the same moment.
   - One game starts, and both screens land in it: same dealer, 0–0, six
     cards each.
   - No error appears.
   - Run query 3: exactly one live game, with 52 distinct cards.
5. **Non-win ending → cut.**
   - Start a game, then have one player **Leave** and rejoin the table.
   - New Game opens the **cut for deal** screen, not a dealt game, and both
     scores are 0.
   - Do the same after an admin force-end from `/admin`.
6. **Reload after a win.** Refresh either browser while the win banner is
   showing. The banner comes back, with the winning reason. Tapping New Game
   from there behaves exactly as in step 3.

## Part 5 — 2a carryover

2a was merged before these could be run with two people. They need only the
2a UI. Use `testing-force-near-win.sql`: query A gives the ids and the scores
needed, and query B resets between scenarios.

1. **Near miss at 120.**
   - At counting step 0, set the pone to `score_for_exact_121` − 1.
   - The pone taps Confirm Count.
   - **Expect:** the pone on exactly 120, **no win banner**, the turn passing
     to the dealer, and the game still live (query H: `status active`).
2. **A crib win.**
   - After the dealer's hand is confirmed (step 2 -- the crib is already
     face-up on both screens, since phase2-open-hands-in-count), set the
     dealer to 121 − `crib_points`, keeping the pone low.
   - The dealer taps Confirm Count (it shows the crib, then counts it).
   - **Expect:** the win banner on both screens, reading like
     "<dealer> wins! 121 — crib: … (+n)". Query H: `won`, `count_step` 2,
     crib shown.
3. **A pone win mid-count.**
   - At step 0, set the pone to `score_for_exact_121`.
   - The pone taps Confirm Count.
   - **Expect:**
     - the banner straight away;
     - the dealer's hand and crib are never counted (the dealer's score is
       unchanged);
     - query H shows `count_step` 0 and the pone's hand in `revealed_by`.
4. **Double tap.**
   - Tap Confirm Count twice quickly.
   - **Expect:** one award, so the score rises once and the flash fires once.
     No error. The turn moves on once.
5. **Refresh mid-count.**
   - Refresh the pone's browser at step 1, and again at step 2.
   - **Expect:** the page comes back (no Count hands pause) with both hands
     face-up -- the pone's own in their hand row, the dealer's in the middle
     -- the crib a face-down pile at step 1 and a face-up fan at step 2, the
     right "Counting: …" headline, the recap lines for confirmed counts only,
     and Confirm Count only on the counting player's screen.
6. **The server refuses Show Hand during play.**
   - During the **play** phase, use `testing-force-near-win.sql` query I to
     call `show_hand` as either player.
   - **Expect:** *"Hands can only be shown once counting has begun."* The UI
     no longer has a Show Hand button at all (phase2-open-hands-in-count),
     but the function is still in the database, so this still checks the
     server.

## Part 6 — regression

1. `phase2-batch1-verification.sql` queries 1–2 still pass (scorers
   untouched).
2. `phase2-batch2a-verification.sql`:
   - queries 1, 2, 4, 4b and 5 still pass;
   - query 3 now reports `next_hand` as unexpected, which is expected; 2b's
     query 2 is the current grants check;
   - queries 6 and 7 still pass on a hand at counting step 0, in **any** hand
     of a match, not just the first.
3. A full first game at a fresh table still starts with the cut for deal.
