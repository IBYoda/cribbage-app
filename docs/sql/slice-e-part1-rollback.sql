-- Step 3, slice E: ROLLBACK of docs/sql/slice-e-part1.sql.
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet. Only if part 1 has to come out.
--
-- ORDER: roll back part 3 and part 2 FIRST (newest first). Part 2's trigger
-- writes profiles.nickname_changed_at and part 2's limits write the two new
-- attempt_log actions; the guard below stops if the trigger is still there.
--
-- WHAT IT DOES (one transaction):
--   0. GUARD: the profiles_nickname_lock trigger is gone (part 2 rolled back).
--   1. Unschedules the pg_cron job 'attempt-log-cleanup' (if it exists).
--   2. Drops public.cleanup_attempt_log().
--   3. DELETES the attempt_log rows with action 'game_start' or
--      'follow_change' (only part 2's limits wrote them; they decide nothing
--      once part 2 is gone) and puts attempt_log_action_check back to exactly
--      the five slice A actions. ONE-WAY for those rows.
--   4. Drops profiles.nickname_changed_at. ONE-WAY: the lock times are lost
--      (a later part 1 starts everyone at null: one free change each).
-- The rows the cleanup job already deleted (older than 7 days) stay deleted.
--
-- RE-RUNNABLE: if exists / if exists everywhere.

begin;

do $$
begin
  if exists (select 1 from pg_trigger tg
             where tg.tgrelid = 'public.profiles'::regclass and tg.tgname = 'profiles_nickname_lock') then
    raise exception 'STOP: the profiles_nickname_lock trigger still exists. Run docs/sql/slice-e-part2-rollback.sql first. Nothing was changed.';
  end if;
end;
$$;

-- 1. The cron job (through EXECUTE, so this file parses without pg_cron).
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed: no job to unschedule.';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'attempt-log-cleanup') then
    execute $cron$select cron.unschedule('attempt-log-cleanup')$cron$;
  end if;
end;
$$;

-- 2. The cleanup function.
drop function if exists public.cleanup_attempt_log();

-- 3. The two new actions out, and the slice A constraint back.
delete from public.attempt_log where action in ('game_start', 'follow_change');
alter table public.attempt_log drop constraint if exists attempt_log_action_check;
alter table public.attempt_log
  add constraint attempt_log_action_check
  check (action in ('create_table', 'create_computer_table', 'join', 'watch', 'code_guess'));

comment on table public.attempt_log is
  'Rate limits (step 3, slice A): one row per counted action -- a table created (create_table), a computer game started (create_computer_table), a join, a new watch (success true), or a wrong table code (code_guess, success false). Read and written only by security definer functions (create_table, join_table_by_code, watch_table, create_computer_table through the _attempts_* / _code_guess* helpers). RLS on, no policies, no grants. See docs/sql/join-create.sql.';

-- 4. The nickname lock column.
alter table public.profiles drop column if exists nickname_changed_at;

commit;
