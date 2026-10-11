-- TESTING HELPER -- not part of any slice's schema.
--
-- Batch 1 scoring needs specific card sequences to reach specific outcomes --
-- an exactly-31 final card, a mid-hand deadlock where only one go event is
-- logged -- and those shapes are rare enough that you could deal all evening
-- without seeing one. This forces them.
--
-- Run in the Supabase SQL Editor, which executes as the table owner and so
-- bypasses RLS. The app itself can never do any of this: game_hands.cards is
-- immutable after the discard precisely so that a client cannot rewrite a
-- hand mid-play.
--
-- WHAT IT DOES NOT CARE ABOUT
--   The forced cards may duplicate the starter or a crib card. Pegging reads
--   neither, so the scenarios are unaffected. Do not use a forced hand to
--   check hand/crib counting -- that is Batch 2 and needs a consistent deal.
--
-- HOW TO USE
--   0. Run query A to find the ids. Paste them into B, C or D.
--   1. Start a game, both players discard, and let the play phase BEGIN.
--      Do not play any card yet.
--   2. Run query B (reset) then C or D (the scenario you want).
--   3. Play the cards in the order given in
--      docs/batch1-manual-test-plan.md -- the expected points depend on it.


-- ---------------------------------------------------------------------------
-- A. FIND THE IDS. Set the table code; everything else is derived.
--
-- Returns one row per player with their user id, nickname, and whether they
-- are the dealer. The non-dealer (pone) leads.
-- ---------------------------------------------------------------------------

select g.id            as game_id,
       g.table_id,
       tm.user_id,
       p.nickname,
       (tm.user_id = g.dealer_id) as is_dealer,
       g.phase,
       gh.cards                   as current_hand
from public.games g
join public.tables t         on t.id = g.table_id
join public.table_members tm on tm.table_id = g.table_id
join public.profiles p       on p.id = tm.user_id
left join public.game_hands gh on gh.game_id = g.id and gh.user_id = tm.user_id
where t.code = '0000'                      -- <<< SET THE TABLE CODE
  and g.status = 'active'
order by is_dealer;


-- ---------------------------------------------------------------------------
-- B. RESET, so the expected point totals in the plan are the only ones.
--
-- Clears the play history AND both players' scores. Scores accumulate across
-- hands (there is no match concept yet), so without this you are checking a
-- delta against whatever the table had already.
-- ---------------------------------------------------------------------------

-- begin;
--
-- delete from public.game_plays where game_id = '<GAME_ID>';
--
-- update public.games
-- set play_count = 0,
--     play_segment = 0,
--     phase = 'play',
--     current_player = '<PONE_USER_ID>'   -- the NON-dealer leads
-- where id = '<GAME_ID>';
--
-- update public.table_members
-- set score = 0, last_points = null, last_reason = null, last_awarded_at = null
-- where table_id = '<TABLE_ID>';
--
-- commit;


-- ---------------------------------------------------------------------------
-- C. SCENARIO 1 -- reasons, runs, go attribution, and the last-card point.
--
-- Pone   4S 6D KH KS
-- Dealer 5H 7C QD QC
--
-- Covers, in one hand: a two-part reason string ("fifteen + run of 3"), a run
-- of 4, the go point landing on the player who played the LAST card rather
-- than the player whose go was logged (twice, once in each direction), and the
-- final card scoring 1 as "last card".
-- ---------------------------------------------------------------------------

-- update public.game_hands set cards = array['4S','6D','KH','KS']
-- where game_id = '<GAME_ID>' and user_id = '<PONE_USER_ID>';
--
-- update public.game_hands set cards = array['5H','7C','QD','QC']
-- where game_id = '<GAME_ID>' and user_id = '<DEALER_USER_ID>';


-- ---------------------------------------------------------------------------
-- D. SCENARIO 2 -- a final card that makes exactly 31.
--
-- Pone   TS KD TH KS
-- Dealer QH AC QD AD
--
-- Two segments, each ending on exactly 31, the second of them on the eighth
-- and final card of the hand. The point of the scenario: that last play must
-- score 2 and read "thirty-one" -- NOT 3, and NOT "thirty-one + last card".
-- The 31 replaces the last-card point rather than stacking with it.
--
-- Ranks are 10, Q, K and A deliberately: all the ten-value cards are
-- non-consecutive (10, 12, 13) so no run can form, and no two adjacent plays
-- share a rank so no pair can form. Every award in this hand is a clean 2.
-- ---------------------------------------------------------------------------

-- update public.game_hands set cards = array['TS','KD','TH','KS']
-- where game_id = '<GAME_ID>' and user_id = '<PONE_USER_ID>';
--
-- update public.game_hands set cards = array['QH','AC','QD','AD']
-- where game_id = '<GAME_ID>' and user_id = '<DEALER_USER_ID>';


-- ---------------------------------------------------------------------------
-- E. FORCE A JACK STARTER, for his heels.
--
-- Run this AFTER the deal but BEFORE the second player discards -- the starter
-- is cut inside discard_to_crib, the moment the last discard lands, and it
-- takes the top card of the deck.
--
-- Moves a jack that is already in the undealt deck to the top, so no duplicate
-- card is created. Returns the card that will be cut; if it returns no row,
-- every jack was dealt into a hand or the crib -- redeal and try again.
-- ---------------------------------------------------------------------------

-- with pick as (
--   select d.game_id, c as card
--   from public.game_decks d
--   cross join unnest(d.cards) as c
--   where d.game_id = '<GAME_ID>'
--     and substr(c, 1, 1) = 'J'
--   limit 1
-- )
-- update public.game_decks d
-- set cards = array_prepend(pick.card, array_remove(d.cards, pick.card))
-- from pick
-- where d.game_id = pick.game_id
-- returning d.cards[1] as starter_that_will_be_cut;
