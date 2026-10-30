-- Leaderboard, L1 ROLLBACK
-- Run this in the Supabase Dashboard -> SQL Editor to undo
-- leaderboard-l1-game-results.sql. Kept here for reference/history.
--
-- WHAT IT DOES: drops everything L1 added, and nothing else --
--   * the trigger games_snapshot_result_on_win on public.games;
--   * the function public.snapshot_game_result();
--   * the table public.game_results (its rows go with it).
-- Every drop is IF EXISTS, so it is safe on a database where L1 was only
-- partly applied, or not at all. Games, seats and scores are untouched.
--
-- THE SAVED SCORES CANNOT BE REBUILT: once game_results is dropped, every
-- final score it held is gone for good (the seats' scores are reset by each
-- new game). So this file REFUSES to run while game_results has any rows,
-- and changes nothing. To drop it anyway, first copy the rows somewhere if
-- they matter, then run this whole file with this line added straight
-- after "begin;":
--   set local leaderboard.l1_drop_results = 'on';
--
-- One transaction: if any statement fails (the guard included), nothing is
-- applied.

begin;

do $$
declare
  v_rows bigint;
begin
  if to_regclass('public.game_results') is null then
    return;
  end if;

  execute 'select count(*) from public.game_results' into v_rows;

  if v_rows > 0 and coalesce(current_setting('leaderboard.l1_drop_results', true), '') <> 'on' then
    raise exception 'public.game_results holds % row(s) of saved final scores, which cannot be rebuilt. Nothing was dropped. See the header to drop it anyway.', v_rows;
  end if;

  if v_rows > 0 then
    raise warning 'Dropping public.game_results with % row(s) of saved final scores.', v_rows;
  end if;
end;
$$;

drop trigger if exists games_snapshot_result_on_win on public.games;

drop function if exists public.snapshot_game_result();

drop table if exists public.game_results;

commit;
