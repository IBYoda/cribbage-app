-- Step 3, slice E, PART 1: ADD-ONLY (safe before any app change).
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- RUN ORDER (slice E):
--   1. docs/sql/slice-e-precheck.sql                      (read-only)
--   2. docs/sql/slice-e-part1.sql                         (this file)
--   3. docs/sql/slice-e-attempt-log-cleanup-verification.sql
--   4. the app (friendly messages, avatar file names); old tabs reload
--   5. docs/sql/slice-e-precheck.sql again
--   6. docs/sql/slice-e-part2.sql                         (behavior)
--   7. docs/sql/slice-e-ratelimits-verification.sql, then the regression
--      suites (computer-c1 first)
--   8. docs/sql/slice-e-part3.sql                         (grants)
--   9. docs/sql/slice-e-grants-verification.sql, then the regression suites
--   Rollbacks: slice-e-part3-rollback.sql, slice-e-part2-rollback.sql,
--   slice-e-part1-rollback.sql -- in that order (newest first).
--
-- WHAT WALT DECIDED (slice E, final): keep every existing limit; 30 games
-- started per hour per account (part 2); nickname changes locked 7 days after
-- each real change, the first nickname free (part 2); 30 follow/unfollow
-- changes per hour on top of the cap of 50 (part 2); an hourly attempt_log
-- cleanup keeping 7 days (this file); avatar uploads to one fixed name per
-- type (part 2); revoke the unused broad table privileges and close
-- anon/PUBLIC EXECUTE (part 3).
--
-- WHAT THIS FILE DOES (one transaction; nothing here changes what a player
-- can do):
--   0. GUARD (raises, changing nothing, unless all hold): the four
--      fingerprinted bodies unchanged (leave_table, end_timed_out_sessions,
--      assign_table_seat, table_host; LF or CRLF); attempt_log_action_check
--      allows exactly the five slice A actions, or the seven of this file (a
--      re-run); profiles.nickname_changed_at absent, or a nullable timestamptz
--      (a re-run); pg_cron installed.
--   1. attempt_log_action_check also allows 'game_start' and 'follow_change'
--      (the two new limits in part 2 log them). Nothing writes them yet.
--   2. profiles.nickname_changed_at (timestamptz, nullable): when the
--      nickname last really changed. Every existing row is null (one free
--      change each). Nothing reads or writes it until part 2's trigger.
--   3. public.cleanup_attempt_log(): deletes attempt_log rows older than 7
--      days, returns how many. Security definer, search_path '', EXECUTE for
--      nobody (like end_empty_tables). Why 7 days: no limit looks back more
--      than one hour (the hourly limits) -- the lockout at most 25 minutes (5
--      wrong codes within 10 minutes, then 15 minutes) -- so anything older
--      never decides anything; a week of history is kept for looking into
--      abuse, and the table stays tiny (worst case about 2,400 rows a day per
--      abusive account).
--   4. The pg_cron job 'attempt-log-cleanup', hourly at minute 17
--      ('17 * * * *': off the :00 of the */5 and */15 jobs). cron.schedule by
--      name replaces an existing job of that name, so a re-run leaves one.
--      The job runs as the role that schedules it (the dashboard's postgres),
--      which owns cleanup_attempt_log.
--
-- NOT TOUCHED: every function body, policy and grant; the existing limits
-- and their messages; the two existing cron jobs.
--
-- RE-RUNNABLE: the constraint is dropped and re-added with the seven
-- actions; "add column if not exists"; "create or replace function";
-- cron.schedule by name.
-- ROLLBACK: docs/sql/slice-e-part1-rollback.sql (only after part 2 is rolled
-- back or was never run: part 2's trigger uses the new column).

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard.
-- ---------------------------------------------------------------------------
do $$
declare
  v_rec record;
  v_txt text;
  v_type text;
  v_notnull boolean;
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

  select pg_get_constraintdef(con.oid) into v_txt
  from pg_constraint con
  where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check';
  if v_txt is null
     or v_txt !~ '''create_table''' or v_txt !~ '''create_computer_table''' or v_txt !~ '''join'''
     or v_txt !~ '''watch''' or v_txt !~ '''code_guess'''
     or (length(v_txt) - length(replace(v_txt, '::text', ''))) / 6 not in (5, 7)
     or ((length(v_txt) - length(replace(v_txt, '::text', ''))) / 6 = 7
         and (v_txt !~ '''game_start''' or v_txt !~ '''follow_change''')) then
    raise exception 'STOP: attempt_log_action_check is "%"; expected exactly create_table, create_computer_table, join, watch, code_guess (or those plus game_start, follow_change on a re-run). Nothing was changed.', coalesce(v_txt, 'missing');
  end if;

  select format_type(a.atttypid, a.atttypmod), a.attnotnull into v_type, v_notnull
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass and a.attname = 'nickname_changed_at' and not a.attisdropped;
  if v_type is not null and (v_type <> 'timestamp with time zone' or v_notnull) then
    raise exception 'STOP: profiles.nickname_changed_at exists as % (not null %); expected a nullable timestamptz or no column. Nothing was changed.', v_type, v_notnull;
  end if;

  if to_regclass('cron.job') is null then
    raise exception 'STOP: pg_cron is not installed; the hourly attempt_log cleanup needs it. Nothing was changed.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. Two new attempt_log actions.
-- ---------------------------------------------------------------------------
alter table public.attempt_log drop constraint attempt_log_action_check;
alter table public.attempt_log
  add constraint attempt_log_action_check
  check (action in ('create_table', 'create_computer_table', 'join', 'watch', 'code_guess',
                    'game_start', 'follow_change'));

comment on table public.attempt_log is
  'Rate limits (step 3, slices A and E): one row per counted action -- a table created (create_table), a computer game started (create_computer_table), a join, a new watch, a game started (game_start), a real follow or unfollow (follow_change) (success true), or a wrong table code (code_guess, success false). Read and written only by security definer functions through the _attempts_* / _code_guess* helpers. Rows older than 7 days are deleted hourly by cleanup_attempt_log() (pg_cron job attempt-log-cleanup). RLS on, no policies, no grants. See docs/sql/join-create.sql and slice-e-part1.sql.';

-- ---------------------------------------------------------------------------
-- 2. profiles.nickname_changed_at.
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists nickname_changed_at timestamptz;

comment on column public.profiles.nickname_changed_at is
  'Step 3 slice E: when the nickname last really changed (a different lower(btrim()) value, from a non-empty one). Null: never changed since slice E, so the next change is free. Maintained only by the profiles_nickname_lock trigger (slice-e-part2.sql), which a client cannot override; the owner (SQL Editor) may set it to null to lift a lock.';

-- ---------------------------------------------------------------------------
-- 3. cleanup_attempt_log().
-- ---------------------------------------------------------------------------
create or replace function public.cleanup_attempt_log()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  delete from public.attempt_log a
  where a.created_at < pg_catalog.now() - interval '7 days';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

comment on function public.cleanup_attempt_log() is
  'Step 3 slice E: deletes attempt_log rows older than 7 days (no limit looks back more than one hour) and returns how many. Run hourly by the pg_cron job attempt-log-cleanup. Security definer, empty search_path, executable by no client role. See docs/sql/slice-e-part1.sql.';

revoke all on function public.cleanup_attempt_log() from public;
revoke all on function public.cleanup_attempt_log() from anon;
revoke all on function public.cleanup_attempt_log() from authenticated;
revoke all on function public.cleanup_attempt_log() from service_role;

-- ---------------------------------------------------------------------------
-- 4. The pg_cron job, hourly at minute 17 (through EXECUTE, so this file
--    parses where the cron schema does not exist; the guard already stopped
--    there).
-- ---------------------------------------------------------------------------
do $$
begin
  execute $cron$select cron.schedule('attempt-log-cleanup', '17 * * * *', 'select public.cleanup_attempt_log();')$cron$;
end;
$$;

commit;
