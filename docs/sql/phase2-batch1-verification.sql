-- Phase 2, Batch 1: VERIFICATION QUERIES. Read-only.
--
-- Run these in the Supabase Dashboard -> SQL Editor AFTER
-- docs/sql/phase2-batch1-scoring-engines.sql. Nothing here creates, alters or
-- writes anything -- they are pure SELECTs over the new pure functions.
--
-- The SQL Editor shows the result of the LAST statement only, so run each
-- numbered query on its own (select its text, then Run).
--
-- Why queries 1 and 2 work even though score_pegging and score_hand have no
-- client grant: the SQL Editor connects as the table owner, which has EXECUTE
-- regardless. A logged-in player in the browser does not -- that asymmetry is
-- the point, and query 3 is what proves it.


-- ---------------------------------------------------------------------------
-- 1. score_pegging CROSS-CHECK -- stratified, 31 cases.
--
-- Expected points and reasons were computed by an INDEPENDENT TypeScript
-- implementation (scratch generator, same rules, different algorithm: it
-- detects runs by sorting the suffix and requiring every adjacent rank
-- difference to be exactly 1, where the SQL uses a distinct-count + span
-- test). Agreement therefore means two separate implementations agree, not
-- that the SQL agrees with itself.
--
-- Strata covered: single cards; fifteen; thirty-one; pair / pair royal /
-- double pair royal; runs of 3, 4, 5 and 6 including out-of-order; J-Q-K as a
-- run; three tens as a pair royal and NOT a run; Q-K-A not wrapping; a run
-- broken by an intervening card; a pair broken by an intervening card; a
-- duplicate rank inside the suffix; and combined scores.
--
-- EXPECT: 31 rows, every one reading 'ok'. Any mismatch sorts to the top.
-- ---------------------------------------------------------------------------

with expected(segment, exp_points, exp_reason) as (
  values
    (array['7H']                         ,  0, ''),                        -- single card, nothing
    (array['TD']                         ,  0, ''),                        -- single card, a ten
    (array['7H','8S']                    ,  2, 'fifteen'),                 -- fifteen (7+8)
    (array['5C','TD']                    ,  2, 'fifteen'),                 -- fifteen (5+T)
    (array['7H','8S','5D']               ,  0, ''),                        -- only the CURRENT total counts: 7+8 made 15, now 20
    (array['TH','TS','AD','TC']          ,  2, 'thirty-one'),              -- thirty-one
    (array['9H','2S','TD','TC']          ,  4, 'thirty-one + pair'),       -- thirty-one plus pair
    (array['7H','7S']                    ,  2, 'pair'),                    -- pair
    (array['7H','7S','7D']               ,  6, 'pair royal'),              -- pair royal
    (array['7H','7S','7D','7C']          , 12, 'double pair royal'),       -- double pair royal
    (array['TH','TS','TD']               ,  6, 'pair royal'),              -- three tens -- pair royal, NOT a run
    (array['7H','3S','7D']               ,  0, ''),                        -- pair broken by an intervening card
    (array['2H','9S','9D','9C']          ,  6, 'pair royal'),              -- pair royal, longer segment
    (array['2H','3S','4D']               ,  3, 'run of 3'),                -- run of 3
    (array['5H','3S','4D']               ,  3, 'run of 3'),                -- run of 3, out of order
    (array['4H','5S','6D','7C']          ,  4, 'run of 4'),                -- run of 4
    (array['6H','4S','7D','5C']          ,  4, 'run of 4'),                -- run of 4, out of order
    (array['3H','4S','5D','6C','7H']     ,  5, 'run of 5'),                -- run of 5
    (array['5H','3S','7D','4C','6S']     ,  5, 'run of 5'),                -- run of 5, out of order
    (array['JH','QS','KD']               ,  3, 'run of 3'),                -- J-Q-K IS a run (ranks 11,12,13)
    (array['TH','JS','QD']               ,  3, 'run of 3'),                -- T-J-Q is a run by rank, not by value
    (array['QH','KS','AD']               ,  0, ''),                        -- Q-K-A does NOT wrap (ace is low)
    (array['4H','5S','9D','6C']          ,  0, ''),                        -- run broken by an intervening card
    (array['AH','2S','6D','3C','4H','5S'],  6, 'run of 6'),                -- longest suffix wins: run of 6
    (array['AH','2S','3D']               ,  3, 'run of 3'),                -- ace-low run of 3
    (array['3H','4S','4D','5C']          ,  0, ''),                        -- no run: duplicate rank inside the suffix
    (array['AH','7S','7D']               ,  4, 'fifteen + pair'),          -- fifteen + pair
    (array['5H','5S','5D']               ,  8, 'fifteen + pair royal'),    -- fifteen + pair royal
    (array['4H','5S','6D']               ,  5, 'fifteen + run of 3'),      -- fifteen + run of 3
    (array['AH','2S','3D','4C','5H']     ,  7, 'fifteen + run of 5'),      -- fifteen + run of 5
    (array['9H','TS','4D','3C','5H']     ,  5, 'thirty-one + run of 3')    -- thirty-one + run of 3
),
checked as (
  select e.segment,
         e.exp_points,
         e.exp_reason,
         (public.score_pegging(e.segment) ->> 'points')::int as got_points,
         (public.score_pegging(e.segment) ->> 'reason')      as got_reason
  from expected e
),
judged as (
  select *,
         (got_points = exp_points and got_reason = exp_reason) as agrees
  from checked
)
select case when agrees then 'ok' else '*** MISMATCH ***' end as result,
       array_to_string(segment, ' ')                          as segment,
       exp_points,
       got_points,
       exp_reason,
       got_reason,
       -- The verdict, carried on every row: one query, no second copy of the
       -- VALUES list to drift out of step, and no empty grid to misread as
       -- "passed" when it actually means "never ran".
       count(*) filter (where not agrees) over ()             as mismatches_total
from judged
-- false sorts first, so any disagreement lands at the top of the grid.
order by agrees, array_to_string(segment, ' ');


-- ---------------------------------------------------------------------------
-- 2. score_hand CROSS-CHECK -- stratified, 22 hands x both is_crib values.
--
-- Expected values GENERATED, not typed by hand:
--
--   npm run test:sql-cases
--
-- prints exactly the VALUES list below. They come from the independent
-- brute-force scorer in scripts/test-scoring.ts -- the one that finds runs by
-- enumerating every subset of the five cards and keeping those no other card
-- can extend -- NOT from lib/scoring.ts. So the chain is:
--
--   checker <-> lib/scoring.ts   exhaustive, all 12,994,800 hands (passing)
--   checker <-> score_hand()     stratified, this query
--
-- The SQL is never compared against anything derived from the SQL.
--
-- All six returned fields are compared, not just the total: a scorer that
-- counted a run as pairs would still total correctly on some hands.
--
-- Strata: no-score; runs of 3, 4 and 5; J-Q-K as a run; three tens as a pair
-- royal and not a run; ace-low run; Q-K-A not wrapping; double run of 3;
-- double run of 4; triple run; double-double run (twice, once with fifteens
-- suppressed and once the classic 24); no flush; hand four-flush scoring 4
-- while the IDENTICAL crib scores 0; five-flush scoring 5 in both; a
-- four-flush combined with a run; nobs present; nobs off-suit; a jack STARTER
-- scoring nothing here because his heels is awarded in discard_to_crib; two
-- jacks where nobs is still only 1; five-flush plus nobs; 29; 28.
--
-- EXPECT: 44 rows, every one 'ok', mismatches_total 0.
-- ---------------------------------------------------------------------------

with expected(
  hand, starter, is_crib,
  exp_points, exp_fifteens, exp_pairs, exp_runs, exp_flush, exp_nobs
) as (
  values
    (array['2S','4H','6D','8C'], 'KS', false,  0,  0,  0,  0, 0, 0),  -- no run, no anything (the 0 hand) [hand]
    (array['2S','4H','6D','8C'], 'KS', true ,  0,  0,  0,  0, 0, 0),  -- no run, no anything (the 0 hand) [crib]
    (array['JS','QH','KD','2C'], '7H', false,  3,  0,  0,  3, 0, 0),  -- run of 3, J-Q-K by rank [hand]
    (array['JS','QH','KD','2C'], '7H', true ,  3,  0,  0,  3, 0, 0),  -- run of 3, J-Q-K by rank [crib]
    (array['TS','TH','TD','2C'], '7H', false,  6,  0,  6,  0, 0, 0),  -- three tens: pair royal, NOT a run [hand]
    (array['TS','TH','TD','2C'], '7H', true ,  6,  0,  6,  0, 0, 0),  -- three tens: pair royal, NOT a run [crib]
    (array['JS','QH','KD','AC'], '7H', false,  3,  0,  0,  3, 0, 0),  -- Q-K-A does not wrap [hand]
    (array['JS','QH','KD','AC'], '7H', true ,  3,  0,  0,  3, 0, 0),  -- Q-K-A does not wrap [crib]
    (array['9S','TH','JD','QC'], '2H', false,  4,  0,  0,  4, 0, 0),  -- run of 4 [hand]
    (array['9S','TH','JD','QC'], '2H', true ,  4,  0,  0,  4, 0, 0),  -- run of 4 [crib]
    (array['AS','2H','3D','4C'], '5S', false,  7,  2,  0,  5, 0, 0),  -- run of 5, ace low [hand]
    (array['AS','2H','3D','4C'], '5S', true ,  7,  2,  0,  5, 0, 0),  -- run of 5, ace low [crib]
    (array['JS','QH','KD','KC'], '3H', false,  8,  0,  2,  6, 0, 0),  -- double run of 3 [hand]
    (array['JS','QH','KD','KC'], '3H', true ,  8,  0,  2,  6, 0, 0),  -- double run of 3 [crib]
    (array['4S','5H','6D','6C'], '7H', false, 14,  4,  2,  8, 0, 0),  -- double run of 4 [hand]
    (array['4S','5H','6D','6C'], '7H', true , 14,  4,  2,  8, 0, 0),  -- double run of 4 [crib]
    (array['JS','JH','JD','QC'], 'KC', false, 15,  0,  6,  9, 0, 0),  -- triple run of 3 [hand]
    (array['JS','JH','JD','QC'], 'KC', true , 15,  0,  6,  9, 0, 0),  -- triple run of 3 [crib]
    (array['JS','JH','QD','QC'], 'KD', false, 16,  0,  4, 12, 0, 0),  -- double-double run [hand]
    (array['JS','JH','QD','QC'], 'KD', true , 16,  0,  4, 12, 0, 0),  -- double-double run [crib]
    (array['4S','4H','5D','5C'], '6D', false, 24,  8,  4, 12, 0, 0),  -- double-double run, the classic 24 [hand]
    (array['4S','4H','5D','5C'], '6D', true , 24,  8,  4, 12, 0, 0),  -- double-double run, the classic 24 [crib]
    (array['2S','4S','6S','8S'], 'KH', false,  4,  0,  0,  0, 4, 0),  -- four-flush: 4 in hand, 0 in crib [hand]
    (array['2S','4S','6S','8S'], 'KH', true ,  0,  0,  0,  0, 0, 0),  -- four-flush: 4 in hand, 0 in crib [crib]
    (array['2S','4S','6S','8S'], 'KS', false,  5,  0,  0,  0, 5, 0),  -- five-flush: 5 in both [hand]
    (array['2S','4S','6S','8S'], 'KS', true ,  5,  0,  0,  0, 5, 0),  -- five-flush: 5 in both [crib]
    (array['2S','4S','6S','8H'], 'KS', false,  0,  0,  0,  0, 0, 0),  -- three of a suit plus starter: no flush [hand]
    (array['2S','4S','6S','8H'], 'KS', true ,  0,  0,  0,  0, 0, 0),  -- three of a suit plus starter: no flush [crib]
    (array['JS','QS','KS','2S'], '7H', false,  7,  0,  0,  3, 4, 0),  -- four-flush AND a run [hand]
    (array['JS','QS','KS','2S'], '7H', true ,  3,  0,  0,  3, 0, 0),  -- four-flush AND a run [crib]
    (array['JS','2H','4D','6C'], '8S', false,  1,  0,  0,  0, 0, 1),  -- nobs: jack matches the starter's suit [hand]
    (array['JS','2H','4D','6C'], '8S', true ,  1,  0,  0,  0, 0, 1),  -- nobs: jack matches the starter's suit [crib]
    (array['JH','2H','4D','6C'], '8S', false,  0,  0,  0,  0, 0, 0),  -- no nobs: jack is off-suit [hand]
    (array['JH','2H','4D','6C'], '8S', true ,  0,  0,  0,  0, 0, 0),  -- no nobs: jack is off-suit [crib]
    (array['2S','4H','6D','8C'], 'JS', false,  0,  0,  0,  0, 0, 0),  -- jack STARTER: his heels, so score_hand gives 0 [hand]
    (array['2S','4H','6D','8C'], 'JS', true ,  0,  0,  0,  0, 0, 0),  -- jack STARTER: his heels, so score_hand gives 0 [crib]
    (array['JS','JH','4D','6C'], '8S', false,  3,  0,  2,  0, 0, 1),  -- two jacks, one matching: nobs is 1, not 2 [hand]
    (array['JS','JH','4D','6C'], '8S', true ,  3,  0,  2,  0, 0, 1),  -- two jacks, one matching: nobs is 1, not 2 [crib]
    (array['JS','2S','4S','6S'], '8S', false,  6,  0,  0,  0, 5, 1),  -- five-flush plus nobs [hand]
    (array['JS','2S','4S','6S'], '8S', true ,  6,  0,  0,  0, 5, 1),  -- five-flush plus nobs [crib]
    (array['5S','5H','5D','JC'], '5C', false, 29, 16, 12,  0, 0, 1),  -- 29 [hand]
    (array['5S','5H','5D','JC'], '5C', true , 29, 16, 12,  0, 0, 1),  -- 29 [crib]
    (array['5S','5H','5D','5C'], 'TS', false, 28, 16, 12,  0, 0, 0),  -- 28 [hand]
    (array['5S','5H','5D','5C'], 'TS', true , 28, 16, 12,  0, 0, 0)   -- 28 [crib]
),
scored as (
  select e.*,
         public.score_hand(e.hand, e.starter, e.is_crib) as got
  from expected e
),
judged as (
  select hand, starter, is_crib,
         exp_points, exp_fifteens, exp_pairs, exp_runs, exp_flush, exp_nobs,
         (got ->> 'points')::int   as got_points,
         (got ->> 'fifteens')::int as got_fifteens,
         (got ->> 'pairs')::int    as got_pairs,
         (got ->> 'runs')::int     as got_runs,
         (got ->> 'flush')::int    as got_flush,
         (got ->> 'nobs')::int     as got_nobs
  from scored
),
verdict as (
  select *,
         (    got_points   = exp_points
          and got_fifteens = exp_fifteens
          and got_pairs    = exp_pairs
          and got_runs     = exp_runs
          and got_flush    = exp_flush
          and got_nobs     = exp_nobs) as agrees
  from judged
)
select case when agrees then 'ok' else '*** MISMATCH ***' end as result,
       -- Every ::text cast below is deliberate. A bare quoted literal is of
       -- type unknown, and letting Postgres resolve || against an untyped
       -- literal is what produced "malformed array literal" in score_pegging
       -- the first time this file was run.
       array_to_string(hand, ' ') || ' + ' || starter          as cards,
       case when is_crib then 'crib' else 'hand' end           as kind,
       exp_points,
       got_points,
       exp_fifteens::text || '/' || exp_pairs::text || '/' || exp_runs::text
         || '/' || exp_flush::text || '/' || exp_nobs::text    as exp_15_pr_run_fl_nob,
       got_fifteens::text || '/' || got_pairs::text || '/' || got_runs::text
         || '/' || got_flush::text || '/' || got_nobs::text    as got_15_pr_run_fl_nob,
       count(*) filter (where not agrees) over ()              as mismatches_total
from verdict
-- false sorts first, so any disagreement lands at the top of the grid.
order by agrees, array_to_string(hand, ' ') || ' + ' || starter, is_crib;


-- ---------------------------------------------------------------------------
-- 3. GRANTS CHECK.
--
-- EXPECT EXACTLY TWO ROWS, both granted to 'authenticated': play_card and
-- discard_to_crib. score_pegging and score_hand must not appear at all -- if
-- either does, a client could call the scorer directly.
--
-- (Also present, commented, at the bottom of the migration file.)
-- ---------------------------------------------------------------------------

-- select routine_name, grantee, privilege_type
-- from information_schema.routine_privileges
-- where routine_schema = 'public'
--   and grantee in ('anon', 'authenticated')
--   and routine_name in (
--     'score_pegging', 'score_hand', 'play_card', 'discard_to_crib'
--   )
-- order by routine_name, grantee;
