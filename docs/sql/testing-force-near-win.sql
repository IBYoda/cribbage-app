-- TESTING HELPER -- not part of any slice's schema.
--
-- Winning at 121 (Batch 2a) needs a score within a few points of 121, and a
-- real match takes the better part of an hour to get there. This puts a
-- player wherever you need them.
--
-- Run in the Supabase SQL Editor, which executes as the table owner and so
-- bypasses RLS. The app itself can never do this: table_members has no
-- UPDATE policy, and award_points -- the only thing that writes a score -- is
-- not client-callable.
--
-- Unlike testing-force-pegging-hands.sql, NOTHING here touches cards. Every
-- hand, crib and starter stays exactly as dealt, so hand and crib counts stay
-- honest. Only scores move (plus E, which reorders the undealt deck).
--
-- HOW TO USE
--   0. Run query A. It shows both players, their scores, and -- once the
--      starter is cut -- what each hand and the crib will score, plus the
--      score that makes each count land on exactly 121.
--   1. Paste the ids into the scenario you want (C-F), and run B first if you
--      want a clean slate.
--   2. Play on in the app. docs/batch2a-manual-test-plan.md says what to
--      expect for each scenario.
--
-- A scenario is a moment in the hand -- each says WHEN to run it. Running it
-- at the wrong moment just tests something else; nothing breaks.


-- ---------------------------------------------------------------------------
-- A. FIND THE IDS AND THE NUMBERS. Set the table code; everything else is
-- derived.
--
-- hand_points / crib_points are null until the starter is cut.
-- score_for_exact_121 = 121 - (what this player's NEXT count will add):
--   pone   -> their hand
--   dealer -> their hand + the crib (both still to come at step 1)
-- ---------------------------------------------------------------------------

select g.id                       as game_id,
       g.table_id,
       tm.user_id,
       p.nickname,
       (tm.user_id = g.dealer_id) as is_dealer,
       g.phase,
       g.count_step,
       g.starter_card,
       tm.score,
       case when g.starter_card is not null then
         (public.score_hand(gh.cards, g.starter_card, false) ->> 'points')::int
       end                        as hand_points,
       case when g.starter_card is not null and tm.user_id = g.dealer_id then
         (public.score_hand(c.cards, g.starter_card, true) ->> 'points')::int
       end                        as crib_points,
       case when g.starter_card is not null then
         121 - (public.score_hand(gh.cards, g.starter_card, false) ->> 'points')::int
             - case when tm.user_id = g.dealer_id
                    then (public.score_hand(c.cards, g.starter_card, true) ->> 'points')::int
                    else 0 end
       end                        as score_for_exact_121
from public.games g
join public.tables t           on t.id = g.table_id
join public.table_members tm   on tm.table_id = g.table_id
join public.profiles p         on p.id = tm.user_id
left join public.game_hands gh on gh.game_id = g.id and gh.user_id = tm.user_id
left join public.game_cribs c  on c.game_id = g.id
where t.code = '0000'                      -- <<< SET THE TABLE CODE
  and g.status = 'active'
order by is_dealer;


-- ---------------------------------------------------------------------------
-- B. RESET both scores to 0 and clear the tracker.
--
-- Also needed once after running the 2a migration on a table that was used
-- for Batch 1 testing: scores there may already be past 121, and with win
-- detection live, the very next award would end the game.
-- ---------------------------------------------------------------------------

-- update public.table_members
-- set score = 0, last_points = null, last_reason = null, last_awarded_at = null
-- where table_id = '<TABLE_ID>';


-- ---------------------------------------------------------------------------
-- C. WIN DURING PEGGING.
-- WHEN: any time during the play phase.
--
-- Puts a player on 120. Their next pegging point of any kind -- a fifteen, a
-- pair, a go, the last card -- wins, and the game ends on that play. A
-- 2-point play also proves the cap: 122 is stored as 121, and the tracker
-- still flashes the full +2.
-- ---------------------------------------------------------------------------

-- update public.table_members
-- set score = 120
-- where table_id = '<TABLE_ID>' and user_id = '<USER_ID>';


-- ---------------------------------------------------------------------------
-- D. WIN MID-COUNT, BY THE PONE.
-- WHEN: after pegging ends (phase 'counting', step 0), before anyone confirms.
--
-- Set the pone to their score_for_exact_121 from query A, or one higher to
-- overshoot and see the cap. The pone confirms and wins; the dealer's hand
-- and crib are never counted.
--
-- Pick a deal where the pone's hand_points is at least 1 -- a 0 hand cannot
-- win.
-- ---------------------------------------------------------------------------

-- update public.table_members
-- set score = <SCORE_FOR_EXACT_121>
-- where table_id = '<TABLE_ID>' and user_id = '<PONE_USER_ID>';


-- ---------------------------------------------------------------------------
-- E. WIN ON THE CRIB, BY THE DEALER.
-- WHEN: phase 'counting', step 2 -- after the dealer's own hand is confirmed,
-- before Show Crib.
--
-- At step 2 only the crib is still to come, so this sets the dealer to
-- 121 - crib_points (query A's crib_points column). Keep the pone's score
-- low so the pone's step-0 count cannot win first.
--
-- Needs crib_points of at least 1.
-- ---------------------------------------------------------------------------

-- update public.table_members
-- set score = 121 - <CRIB_POINTS>
-- where table_id = '<TABLE_ID>' and user_id = '<DEALER_USER_ID>';


-- ---------------------------------------------------------------------------
-- F. WIN ON HIS HEELS.
-- WHEN: after the deal, BEFORE the second player discards.
--
-- Two steps: put the dealer on 119, then move a jack to the top of the undealt
-- deck so it is cut as the starter (the same move as
-- testing-force-pegging-hands.sql query E). The game ends the moment the last
-- discard lands -- before a card is played -- and is left with phase 'play'.
-- That leftover phase is accepted (design decision 11).
--
-- If the second statement returns no row, every jack was dealt into a hand;
-- start a new game and try again.
-- ---------------------------------------------------------------------------

-- update public.table_members
-- set score = 119
-- where table_id = '<TABLE_ID>' and user_id = '<DEALER_USER_ID>';

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


-- ---------------------------------------------------------------------------
-- G. NEAR MISS -- must NOT win.
-- WHEN: phase 'counting', step 0.
--
-- One below D: the pone confirms and lands on exactly 120. The game must
-- carry on to the dealer's count. Proves the check is ">= 121", not "near".
-- ---------------------------------------------------------------------------

-- update public.table_members
-- set score = <SCORE_FOR_EXACT_121> - 1
-- where table_id = '<TABLE_ID>' and user_id = '<PONE_USER_ID>';


-- ---------------------------------------------------------------------------
-- H. CHECK AN ENDED GAME. The most recent game at the table, live or not.
-- Expect, after any win: status 'ended', ended_reason 'won', winner_id set,
-- and the winner's score exactly 121.
-- ---------------------------------------------------------------------------

-- select g.id, g.status, g.ended_reason, g.winner_id, g.phase, g.count_step,
--        g.current_player, g.revealed_by, g.crib_revealed,
--        (select array_agg(p.nickname || ' ' || tm.score order by tm.joined_at)
--           from public.table_members tm
--           join public.profiles p on p.id = tm.user_id
--          where tm.table_id = g.table_id) as scores
-- from public.games g
-- join public.tables t on t.id = g.table_id
-- where t.code = '0000'                    -- <<< SET THE TABLE CODE
-- order by g.created_at desc
-- limit 1;


-- ---------------------------------------------------------------------------
-- I. ACT AS A PLAYER -- call a counting function exactly as that player's
-- browser would, before the counting UI exists. Unlike verification queries
-- 6 and 7 this COMMITS: it is a real call with real effects.
--
-- The client's supabase object is not exposed on window, so the browser
-- console is not an option. This sets what auth.uid() reads and drops to the
-- 'authenticated' role, which is what PostgREST does for a browser request --
-- so every guard and the grant are exercised for real.
--
-- Swap the one call line for whichever you need:
--   select public.confirm_count('<GAME_ID>', <STEP>);   -- 0 pone, 1 dealer, 2 crib
--   select public.show_crib('<GAME_ID>');               -- dealer, at step 2
--   select public.show_hand('<GAME_ID>');               -- try it during play: must fail
-- ---------------------------------------------------------------------------

-- begin;
-- select set_config('request.jwt.claims',
--   json_build_object('sub', '<USER_ID>', 'role', 'authenticated')::text, true);
-- select set_config('request.jwt.claim.sub', '<USER_ID>', true);
-- select set_config('request.jwt.claim.role', 'authenticated', true);
-- set local role authenticated;
--
-- select public.confirm_count('<GAME_ID>', 0);
--
-- commit;
