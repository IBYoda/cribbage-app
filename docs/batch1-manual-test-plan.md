# Phase 2, Batch 1 — manual test plan

One pass, three hands. Everything here is something automation genuinely
cannot reach: two real sessions over realtime, a flash that exists for two
seconds and is then overwritten, and point attribution that depends on which
player's click arrived last.

**What is already covered by `npm test` and the SQL cross-checks, and is
deliberately NOT retested here:** every hand and crib score (all 12,994,800
hand-and-starter combinations), every pegging reason string, run and flush
rule, and the grants. If a number below is wrong, the bug is in the wiring —
`play_card`'s segment filter, the award call, the attribution — not in the
scorers.

## Why these five things need a human

| What | Why automation can't do it |
|---|---|
| The score-tracker flash | `last_points`/`last_reason` hold only the MOST RECENT award. A query after the hand shows one row, not the sequence. The intermediate reasons exist only on screen. |
| Go attribution in a deadlock | Depends on which player's `play_card` call was the last one to land. The go *event* in the history belongs to the other player, so the database row and the correct recipient disagree by design. |
| Exactly 31 as the final card | Two end-of-hand code paths collide. Needs a specific eight-card sequence played in a specific order by two people. |
| The final-card "last card" point | Same, and it must be 1 point and not 2. |
| His heels | Fires inside `discard_to_crib` at cut time, triggered by the second player's discard arriving. |

---

## Setup

1. Two browsers (or one plus an incognito window), signed in as two different
   accounts. **Not** two tabs of the same session.
2. Both at the same table, both visible at once if you can manage it — several
   checks below are about what appears on the *other* screen.
3. Keep the Supabase SQL Editor open in a third tab.
4. Open `docs/sql/testing-force-pegging-hands.sql`. Run **query A** with your
   table code to get `game_id`, `table_id`, and which player is the dealer.
   The non-dealer (pone) leads every hand.

Two queries you will re-run throughout — keep them handy.

**Scores and the latest award:**

```sql
select p.nickname, tm.score, tm.last_points, tm.last_reason, tm.last_awarded_at
from public.table_members tm
join public.profiles p on p.id = tm.user_id
join public.tables t   on t.id = tm.table_id
where t.code = '0000'
order by p.nickname;
```

**The play history, including go events:**

```sql
select gp.seq, gp.segment, p.nickname, gp.kind, gp.card, gp.count_after
from public.game_plays gp
join public.profiles p on p.id = gp.user_id
where gp.game_id = '<GAME_ID>'
order by gp.seq;
```

---

## Test 1 — his heels

The dealer takes 2 the instant a jack is turned as the starter, before anyone
plays a card.

1. Start a new game. Let the cut for deal finish and the cards be dealt.
2. Have the **first** player discard two cards. Do not let the second discard
   yet.
3. Run **query E** from the testing helper. It moves a jack already sitting in
   the undealt deck to the top and returns the card that will be cut. If it
   returns no rows, every jack is in a hand or the crib — abandon this hand,
   start another, and try again.
4. Now have the **second** player discard.

**Expect:**

- The starter card revealed is the jack query E named.
- The **dealer's** score goes up by exactly **2**, on both screens, and the
  flash reads **`+2 — his heels`**.
- The pone's score does not move.
- This happens *before any card is played*.

**Then check the double-award trap.** His heels must be awarded here and
nowhere else — `score_hand` deliberately returns nothing for a jack starter.
Confirm the dealer's 2 did not land twice:

```sql
-- Expect exactly ONE his heels award for this table.
select p.nickname, tm.score, tm.last_points, tm.last_reason
from public.table_members tm
join public.profiles p on p.id = tm.user_id
join public.tables t   on t.id = tm.table_id
where t.code = '0000' and tm.last_reason = 'his heels';
```

> Batch 2 adds the Confirm Count flow. When it does, re-run this test: a jack
> starter must still be worth 2 in total, not 4.

---

## Test 2 — reasons, go attribution, and the last card

One hand covers four things. **Play the cards in exactly this order** — the
expected points depend on it.

Set it up: both players discard, let the play phase begin, play **nothing**,
then run the helper's **query B** (reset) followed by **query C** (deal the
forced hands). Both players reload if the new cards don't appear.

- **Pone:** 4♠ 6♦ K♥ K♠
- **Dealer:** 5♥ 7♣ Q♦ Q♣

| # | Who plays | Card | Count after | Expected award |
|---|---|---|---|---|
| 1 | Pone | 4♠ | 4 | — |
| 2 | Dealer | 5♥ | 9 | — |
| 3 | Pone | 6♦ | 15 | **Pone +5 — `fifteen + run of 3`** |
| 4 | Dealer | 7♣ | 22 | **Dealer +5 — `run of 4 + go`** |
| 5 | Pone | K♥ | 10 | — (new segment) |
| 6 | Dealer | Q♦ | 20 | — |
| 7 | Pone | K♠ | 30 | **Pone +1 — `go`** |
| 8 | Dealer | Q♣ | 10 | **Dealer +1 — `last card`** |

### What to watch, step by step

**Step 3 — the two-part reason.** The flash must read `+5 — fifteen + run of
3`, one award, not a `+2` followed by a `+3`. A single `award_points` call per
play is the whole reason the reason string exists: two calls would overwrite
each other and the tracker would show only the last component.

**Step 4 — the aggregated go, and the attribution trap.** After the dealer
plays 7♣ the count is 22 and *neither* player can play: the pone holds two
kings and the dealer two queens, all worth 10, and 22 + 10 = 32.

- A **GO chip appears in the segment attributed to the PONE** — they are the
  one who couldn't play.
- The **+1 goes to the DEALER**, because the dealer played the last card of
  the segment. The award and the go event belong to different players. This is
  the case to get wrong.
- The dealer's single flash reads **`+5 — run of 4 + go`**: the run and the go
  point arrive in one award, not two.
- Confirm in the history that there is exactly **one** go event for this
  segment, and that it is the pone's:

```sql
select gp.seq, gp.segment, p.nickname, gp.kind, gp.count_after
from public.game_plays gp
join public.profiles p on p.id = gp.user_id
where gp.game_id = '<GAME_ID>' and gp.kind = 'go'
order by gp.seq;
```

**Step 7 — the same trap, reversed.** The dealer holds Q♣ and cannot play onto
30; the pone has run out. The **GO chip is the DEALER's**, the **+1 is the
PONE's**. Reason: plain `go`, nothing else scored.

**Step 8 — the last card.** The dealer plays their final card. Count is 10,
nothing else scores, so: **+1, reason `last card`** — the word changes from
`go` to `last card` because the hand just ended. Not 2 points. Not `go`.

**Also check (the deleted message):** at every go in this hand, the inline
`GO` chip appears in the segment, and there is **no sentence** under the
played cards saying "Sam said go" or "You said go". That line is gone — it
duplicated the chip and, now that a go is worth a point, it was the wrong
place to explain one.

**Final totals:** Pone **6**, Dealer **6**.

```sql
-- Expect 6 and 6.
select p.nickname, tm.score
from public.table_members tm
join public.profiles p on p.id = tm.user_id
join public.tables t   on t.id = tm.table_id
where t.code = '0000'
order by p.nickname;
```

---

## Test 3 — a final card that makes exactly 31

The one case where two scoring rules compete. 31 is worth 2; the last card of
the hand is worth 1. When the same play is both, the 31 **replaces** the last
card point — it does not stack.

Set up as before: play phase begun, nothing played, then **query B** (reset)
then **query D**.

- **Pone:** 10♠ K♦ 10♥ K♠
- **Dealer:** Q♥ A♣ Q♦ A♦

| # | Who plays | Card | Count after | Expected award |
|---|---|---|---|---|
| 1 | Pone | 10♠ | 10 | — |
| 2 | Dealer | Q♥ | 20 | — |
| 3 | Pone | K♦ | 30 | — |
| 4 | Dealer | A♣ | 31 | **Dealer +2 — `thirty-one`** |
| 5 | Pone | 10♥ | 10 | — (new segment) |
| 6 | Dealer | Q♦ | 20 | — |
| 7 | Pone | K♠ | 30 | — |
| 8 | Dealer | A♦ | 31 | **Dealer +2 — `thirty-one`** |

### What to watch

**Step 4 — a mid-hand 31.** +2, reason `thirty-one`. The segment resets, the
count display returns to 0, the completed segment dims, and the **pone leads
the new segment** — the player who did *not* hit 31.

**Step 8 — the collision.** This play is simultaneously the 31 *and* the last
card of the hand. It must read **`+2 — thirty-one`**.

- If it reads `+3 — thirty-one + last card`, the two rules are stacking.
- If it reads `+1 — last card`, the 31 is being missed.
- There must be **no go event** anywhere in this hand — nobody was ever
  unable to play, and a 31 is not a go.

**Why this hand scores nothing else:** the ten-value cards used are 10, Q and
K — ranks 10, 12 and 13, which are not consecutive, so no run can form even
though every one of them counts 10. (If runs were computed from play values
instead of ranks, every segment here would look like a run of three tens.) And
no two consecutive plays share a rank, so no pair can form either. Every award
in this hand is a clean 2.

**Final totals:** Pone **0**, Dealer **4**.

```sql
-- Expect 0 and 4, and no 'go' rows.
select p.nickname, tm.score, tm.last_points, tm.last_reason
from public.table_members tm
join public.profiles p on p.id = tm.user_id
join public.tables t   on t.id = tm.table_id
where t.code = '0000'
order by p.nickname;

select count(*) as go_events
from public.game_plays
where game_id = '<GAME_ID>' and kind = 'go';
```

---

## Test 4 — the realtime half

Both of the above, but watching the *other* screen. Scoring is awarded
server-side inside `play_card`, so the opponent learns about it through the
`table_members` realtime stream, not from their own click.

While running tests 2 and 3, confirm on the screen of the player who did
**not** just play:

- Their opponent's score updates without a reload.
- The flash (`+5 — run of 4 + go`) appears there too, with the same number and
  the same reason.
- The GO chip and the running count stay in step on both screens.
- After a 31, both screens reset the count to 0 and agree on whose turn it is.

---

## After the eighth card

When the eighth card lands, `play_card` sets `phase = 'counting'` and
`current_player` to the pone, who counts first. (Batch 1 set it to null;
Batch 2a's region (H) changed it.) The play area gives way to the counting
banner (Batch 2a). After the crib is counted, **Next Hand** deals the
following hand (Batch 2b). So for these tests, either count the hand out or
tap Next Hand to get a fresh deal. You don't need to start a new game.

- **At 121 the game ends** (Batch 2a's win detection and 121 cap). The forced
  scenarios here assume low scores. If an earlier test left a player near
  121, reset with `testing-force-near-win.sql` query B, or a single pegging
  point will end the game.

---

## If something is wrong

Report the **reason string and the point value together** — they come from the
same `award_points` call, and the pair identifies which branch misfired:

| Symptom | Where to look |
|---|---|
| Right points, wrong player | region (D) of `play_card` — go attribution |
| `+3 — thirty-one + last card` | region (F) — the go flag is being set on the 31 path |
| Two flashes for one play | more than one `award_points` call survived |
| Reason has a component the count doesn't justify | `score_pegging`, but check the segment filter in region (B) first — a card from a previous segment leaking in looks exactly like this |
| `+0` flash | the `if v_points > 0` guard at the end of region (F) |

Score corruption is worth a direct look, since the scorers never see a
client-supplied number:

```sql
-- Every award ever made at this table, in order. Points must be positive and
-- must match a reason that can produce them.
select tm.score, tm.last_points, tm.last_reason, tm.last_awarded_at
from public.table_members tm
join public.tables t on t.id = tm.table_id
where t.code = '0000';
```
