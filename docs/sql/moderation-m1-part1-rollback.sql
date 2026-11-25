-- Moderation, slice M1: ROLLBACK of PART 1 (docs/sql/moderation-m1-part1.sql).
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- ONLY AFTER part 2 is rolled back (moderation-m1-part2-rollback.sql) or was
-- never run: part 2's join_table_by_code and watch_table call
-- _is_blocked_from_table. The guard refuses otherwise.
--
-- WHAT IT DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold): the four
--      fingerprinted bodies unchanged; join_table_by_code and watch_table
--      are today's (free-codes-part1.sql), NOT part 2's.
--   1. Drops get_my_blocks(), unblock_player(uuid), block_player(text) and
--      _is_blocked_from_table(uuid, uuid) (if they exist).
--   2. Drops public.blocks (if it exists), with its index and rows.
--   3. Deletes the attempt_log rows with action 'block_change' (they only
--      feed the hourly block/unblock limit), then puts
--      attempt_log_action_check back to slice E's seven actions and the
--      table comment back to slice E's text.
--
-- ONE-WAY (say so before running it): every Block List row is gone for
-- good (a re-run of part 1 starts everyone with an empty list), and so are
-- the block_change rows in attempt_log (harmless: the limit looks back one
-- hour). Nothing else is lost.
-- The app keeps working: the Profile page's Blocked players section shows
-- "Couldn't load your Block List." until part 1 is back.
--
-- RE-RUNNABLE: "drop ... if exists"; the constraint is dropped and re-added.

begin;

do $$
declare
  v_rec record;
  v_txt text;
begin
  for v_rec in
    select * from (values
      ('public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa'),
      ('public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c'),
      ('public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb'),
      ('public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d')
    ) as t(fn, lf, crlf)
  loop
    select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is null or v_txt not in (v_rec.lf, v_rec.crlf) then
      raise exception 'STOP: % has body md5 %; expected % (LF) or % (CRLF). Nothing was changed.', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf, v_rec.crlf;
    end if;
  end loop;

  for v_rec in
    select * from (values
      ('public.join_table_by_code(text, boolean, uuid)', '1a2ff167c6d09fef6acd17177493422d', '9f3cee04a063447d626a1354533fda51'),
      ('public.watch_table(text, uuid)', '43775b57dffaec98ee7c003304a0c951', 'df591fa16528afd81a13bfdc3e975538')
    ) as t(fn, lf, crlf)
  loop
    select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is null or v_txt not in (v_rec.lf, v_rec.crlf) then
      raise exception 'STOP: % has body md5 %, not free-codes-part1.sql''s % / %. Run docs/sql/moderation-m1-part2-rollback.sql first (part 2 calls _is_blocked_from_table). Nothing was changed.', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf, v_rec.crlf;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The functions.
-- ---------------------------------------------------------------------------
drop function if exists public.get_my_blocks();
drop function if exists public.unblock_player(uuid);
drop function if exists public.block_player(text);
drop function if exists public._is_blocked_from_table(uuid, uuid);

-- ---------------------------------------------------------------------------
-- 2. The table (ONE-WAY: its rows are gone).
-- ---------------------------------------------------------------------------
drop table if exists public.blocks;

-- ---------------------------------------------------------------------------
-- 3. attempt_log: slice E's seven actions.
-- ---------------------------------------------------------------------------
delete from public.attempt_log
where action = 'block_change';

alter table public.attempt_log drop constraint attempt_log_action_check;
alter table public.attempt_log
  add constraint attempt_log_action_check
  check (action in ('create_table', 'create_computer_table', 'join', 'watch', 'code_guess',
                    'game_start', 'follow_change'));

comment on table public.attempt_log is
  'Rate limits (step 3, slices A and E): one row per counted action -- a table created (create_table), a computer game started (create_computer_table), a join, a new watch, a game started (game_start), a real follow or unfollow (follow_change) (success true), or a wrong table code (code_guess, success false). Read and written only by security definer functions through the _attempts_* / _code_guess* helpers. Rows older than 7 days are deleted hourly by cleanup_attempt_log() (pg_cron job attempt-log-cleanup). RLS on, no policies, no grants. See docs/sql/join-create.sql and slice-e-part1.sql.';

notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  to_regclass('public.blocks') is null as blocks_gone,
  to_regprocedure('public.block_player(text)') is null as block_player_gone,
  to_regprocedure('public._is_blocked_from_table(uuid, uuid)') is null as helper_gone,
  (select pg_get_constraintdef(con.oid) from pg_constraint con
   where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check') as attempt_log_action_check;
