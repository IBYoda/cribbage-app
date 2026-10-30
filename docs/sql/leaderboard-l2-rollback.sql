-- Leaderboard, L2 ROLLBACK
-- Run this in the Supabase Dashboard -> SQL Editor to undo
-- leaderboard-l2-function.sql. Kept here for reference/history.
--
-- WHAT IT DOES: drops public.get_leaderboard(), and nothing else. It holds
-- no data, so nothing is lost: L1's game_results and its trigger stay (undo
-- them with leaderboard-l1-rollback.sql AFTER this file, if wanted). IF
-- EXISTS, so it is safe where L2 was never applied. The app's leaderboard
-- page stops working until the function is back.
--
-- One transaction.

begin;

drop function if exists public.get_leaderboard();

commit;
