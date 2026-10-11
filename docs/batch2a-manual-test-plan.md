# Phase 2, Batch 2a — manual test plan

Batch 2a covers counting, crib scoring and winning at 121, and stops at
`phase = 'done'`. Dealing the next hand, the match loop and the score reset
are Batch 2b. The win banner was pulled forward into 2a, because a win can
happen mid-count and the old client dropped the game with no message.

> **Status:** the 2a SQL has been applied. Verification queries 1–7 passed on
> their first run. Query 3 needed its expected list widened (see Part 1), and
> query 6 now checks the full reason strings, so re-run it once to see 32
> checks. Part 4 below is written against the counting UI as built, but that
> UI has **not** been tried in a browser yet.

**Already covered elsewhere, so NOT retested here:** every hand and crib
score (`npm test`, and the `score_hand` cross-check in
`phase2-batch1-verification.sql`), and every pegging rule. If a number below
is wrong, the problem is in the wiring: which cards were read, who was
awarded, or the order of steps. It is not in `score_hand`.

## What each part proves

| Part | What | How |
|---|---|---|
| 1 | Schema, constraints, grants, policies, RLS on | `phase2-batch2a-verification.sql` queries 1–5, read-only |
| 2 | Every new function, run as each player and as a stranger | Verification query 6, rolled back |
| 3 | The win, the cap, and the frozen end state | Verification query 7 (rolled back), plus `testing-force-near-win.sql` for real wins |
| 4 | What two people actually see | Two browsers |
| 5 | Nothing in Batch 1 regressed | Batch 1 cross-checks and the his-heels check |

---

## Setup

1. Two browsers (or one plus an incognito window), signed in as two
   different accounts.
2. Both at the test table. Keep the SQL Editor open in a third tab.
3. Since Batch 2b, New Game resets both scores itself, and **Next Hand**
   moves on from `done`. `testing-force-near-win.sql` query B is only needed
   to undo a forced score between scenarios within one game.

---

## Part 1 — static checks (read-only)

Run verification queries 1–5 one at a time.

| Query | Pass |
|---|---|
| 1 | 4 columns with the types and defaults in the comment |
| 2 | 3 check constraints; `games_phase_check` includes `done`, `games_ended_reason_check` includes `won` |
| 3 | 9 rows `ok`, up to 3 rows `known pre-existing` (`card_rank_value`, `shuffled_deck`, `rls_auto_enable`), verdict `PASS` on every row |
| 4 | Exactly the 2 new policies; the old "own hand only" policy is gone |
| 4b | `game_hands` and `game_cribs` both `rls_enabled = true`, `rls_forced = false`, `ok` |
| 5 | No check constraint on `table_members`; 5b shows every live crib at 4 cards |

Query 3's tolerated grants are older than 2a. Two of them contradict the
handoff's function table, and they're logged there as a loose end. The query
explains why it tolerates them, and a fourth unexpected grant still fails it.

## Part 2 — the counting walk-through (rolled back)

1. Start a game and play the hand through pegging. Stop when the eighth card
   lands and the counting banner appears. **Don't tap anything in the banner.**
   Query 6 needs step 0 with nothing shown.
2. Set the table code in verification query 6, uncomment it and run it.
3. **Pass:** the error banner reads `ALL 32 CHECKS PASSED (rolled back)`,
   followed by the hand, crib and starter values. Any message starting
   `FAIL [..]` names the exact check. `SETUP:` means the game was not in the
   required state.
4. Run it a second time. It must pass again, which proves the first run left
   nothing behind.

`C1b`, `C3c` and `C4b` now compare the **whole** reason string, for example
`hand: 15s 4 · runs 3`, against one the query builds a different way. Before
this change they checked only the `hand: ` / `crib: ` prefix.

## Part 3 — winning

**3a. Rolled back.** With the same game still at counting step 0, run
verification query 7. **Pass:** `ALL 9 CHECKS PASSED (rolled back)`.

**3b. Real wins, through the UI.** Use `testing-force-near-win.sql`. Query A
gives the ids and the scores needed. After each win, check three things:

- **Both screens** show the green banner: **"You win!"** on the winner's
  screen, **"<name> wins!"** on the other, with both scores, and the New Game
  button beneath it.
- **Refresh one browser.** The banner must come back. It's reloaded from the
  last game, not kept in memory.
- **`testing-force-near-win.sql` query H** shows `status ended`,
  `ended_reason won`, the right `winner_id`, and the winner on exactly 121.

Then run query B before the next scenario.

| Scenario | Set up | Then | Also expect |
|---|---|---|---|
| C — pegging | During play, set a player to 120 | That player scores any pegging point | Banner straight after the play. A +2 flashes `+2` but the score reads 121 |
| D — pone mid-count | At counting step 0, pone to `score_for_exact_121` | Pone taps Confirm Count | Banner; the dealer never counts |
| G — near miss | At counting step 0, pone to `score_for_exact_121` − 1 | Pone taps Confirm Count | Pone on 120, **no banner**, turn passes to the dealer |
| E — crib | At step 2 (after the dealer's hand), dealer to 121 − `crib_points` | Dealer taps Show Crib, then Confirm Count | Banner |
| F — his heels | Dealer to 119, force a jack starter, then the second discard | — | Banner the moment the starter is cut, before any card is played |

F is the "status before phase" case. The ended game is left with
`phase = 'play'`, and the screen must show the banner, not a play area.

**Server-side Show Hand refusal.** Using `testing-force-near-win.sql` query I,
call `show_hand` during the **play** phase. It must fail with *"Hands can only
be shown once counting has begun."* The UI never offers the button then, so
this is the only way to check the server.

## Part 4 — two people, two screens

Play one normal hand to `done` with scores reset, watching both screens.

1. **Pegging ends.**
   - Both screens show the counting banner. The pone's reads **"Your count"**
     with **Confirm Count** enabled. The dealer's reads
     **"<pone> is counting their hand"**, and their Confirm Count is visible
     but greyed out.
   - Both players get **Show Hand** next to Sort.
   - Both cribs are still face-down.
2. **No Show Hand before counting.** During discard and play, there is no
   Show Hand button on either screen (decision 7).
3. **Pone taps Show Hand.**
   - The pone's cards turn face-up at their seat on the dealer's screen,
     without a refresh.
   - The pone's button becomes "Shown to the table".
   - No breakdown is shown yet: the player is meant to count out loud before
     the app does.
   - The dealer's hand stays face-down on the pone's screen.
4. **Pone taps Confirm Count.**
   - The flash on both screens reads like `+7 — hand: 15s 4 · runs 3`.
   - A breakdown line, `Hand: 7 — 15s 4 · runs 3`, appears under the pone's
     cards on both screens. Its number matches the flash.
   - The turn passes to the dealer: the banner flips on both screens.
5. **Double tap.** On the next confirm, tap Confirm Count twice quickly.
   Nothing extra is scored and no error appears. The button is disabled while
   the first call is in flight, and the server treats a late duplicate as a
   stale step.
6. **Dealer taps Confirm Count without tapping Show Hand.** Their hand turns
   face-up on the pone's screen anyway (auto-reveal), and the flash and
   breakdown follow.
7. **The crib.**
   - The dealer's banner reads **"Your crib — Show the crib, count it out loud,
     then Confirm Count."**
   - Show Crib appears, and Confirm Count stays greyed out until it's tapped.
   - The pone's screen reads "<dealer> is about to show the crib".
   - After Show Crib, the crib turns face-up on **both** screens.
   - Confirm Count then scores it as `crib: …`.
8. **`done`.**
   - The banner reads "Every hand and the crib are counted."
   - Both hands, the crib (now with its breakdown) and the starter stay
     face-up on both screens.
   - Nobody has a counting button.
9. **Zero hand.** When a hand scores 0, the flash reads `+0 — hand: nothing`
   and the breakdown reads `Hand: 0 — nothing`.
10. **Reconnect mid-count.**
    - Refresh the pone's browser at step 1. It must come back showing:
      - the pone's own four cards;
      - any shown hands face-up;
      - "<dealer> is counting their hand";
      - the right button states.
    - Refresh at `done`: everything is still face-up.

## Part 5 — regression

1. **Batch 1 cross-checks.** Re-run `phase2-batch1-verification.sql` queries
   1 and 2. Both must still pass, because `score_hand` and `score_pegging` are
   untouched.
2. **His heels: no double award.**
   - Force a jack starter (`testing-force-pegging-hands.sql` query E) with
     scores reset.
   - Right after the cut, the dealer is exactly +2, reading `his heels`.
   - After the crib is confirmed, the dealer's total must equal 2, plus their
     pegging points, plus `score_hand(dealer hand)`, plus `score_hand(crib)`.
     That's 2 for his heels, never 4.
   - Query A in `testing-force-near-win.sql` shows both `score_hand` values,
     and the on-screen breakdowns show the same numbers.
3. **Pegging still works end to end.** Play a full hand. Cards, the running
   count, GO chips and flashes all behave as in Batch 1. The table page's hand
   fetch changed in 2a: it now filters by `user_id`, because a shown hand is
   readable too. A broken fetch would show up as an empty hand after dealing.
