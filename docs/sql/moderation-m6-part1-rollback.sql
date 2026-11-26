-- Moderation, slice M6: ROLLBACK of PART 1 (docs/sql/moderation-m6-part1.sql).
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- WHEN: roll the app back first (it calls report_player, admin_list_reports
-- and admin_delete_report; an old tab would just see its Report fail).
--
-- ONE-WAY FOR THE DATA: every report in public.player_reports is deleted
-- with the table, and every report_filed row in attempt_log is deleted
-- (they must go before the nine-action constraint can come back). Neither
-- can be restored. If the reports matter, export them first, for example:
--   select * from public.player_reports order by created_at;
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD: attempt_log_action_check allows exactly M6's ten actions or
--      M3's nine (M6 never ran, or a half-rolled-back state): anything else
--      means a later slice changed it -- roll that slice back first. It
--      raises and changes nothing otherwise. It records how many reports
--      and report_filed rows there are (the result row shows them).
--   1. Removes the pg_cron job 'report-purge' (if pg_cron is installed and
--      the job exists).
--   2. Drops purge_old_reports, admin_delete_report, admin_list_reports,
--      report_player and _report_avatar_object.
--   3. Drops public.player_reports (ONE-WAY: the reports are gone).
--   4. attempt_log: DELETES the report_filed rows (only if there are any),
--      then attempt_log_action_check goes back to M3's nine actions (M3
--      part 1's constraint and comment).
--
-- NOT TOUCHED: everything moderation-m6-part1.sql did not create.

begin;

-- How many rows this rollback deletes (shown in the result row). A temp
-- table: this session only.
drop table if exists pg_temp.m6_rollback_counts;
create temp table m6_rollback_counts (reports bigint, report_filed_rows bigint) on commit preserve rows;

do $$
declare
  v_txt text;
  v_n integer;
begin
  select pg_get_constraintdef(con.oid) into v_txt
  from pg_constraint con
  where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check';
  v_n := (length(coalesce(v_txt, '')) - length(replace(coalesce(v_txt, ''), '::text', ''))) / 6;
  if v_txt is null
     or v_txt !~ '''create_table''' or v_txt !~ '''create_computer_table''' or v_txt !~ '''join'''
     or v_txt !~ '''watch''' or v_txt !~ '''code_guess''' or v_txt !~ '''game_start''' or v_txt !~ '''follow_change'''
     or v_txt !~ '''block_change''' or v_txt !~ '''kick'''
     or v_n not in (9, 10)
     or (v_n = 10 and v_txt !~ '''report_filed''') then
    raise exception 'STOP: attempt_log_action_check is "%"; expected M6''s ten actions (M3''s nine plus report_filed) or M3''s nine. A later slice changed it: roll that slice back first. Nothing was changed.', coalesce(v_txt, 'missing');
  end if;

  insert into m6_rollback_counts (reports, report_filed_rows)
  select (case when to_regclass('public.player_reports') is null then 0
               else (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.player_reports', false, true, '')))[1]::text::bigint end),
         (select count(*) from public.attempt_log a where a.action = 'report_filed');
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The pg_cron job (through EXECUTE, so this file parses without pg_cron).
-- ---------------------------------------------------------------------------
do $$
declare
  v_n integer;
begin
  if to_regclass('cron.job') is null then
    return;
  end if;
  execute 'select count(*)::int from cron.job j where j.jobname::text = $1' into v_n using 'report-purge';
  if v_n > 0 then
    execute $cron$select cron.unschedule('report-purge')$cron$;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. The functions.
-- ---------------------------------------------------------------------------
drop function if exists public.purge_old_reports();
drop function if exists public.admin_delete_report(uuid);
drop function if exists public.admin_list_reports(integer);
drop function if exists public.report_player(uuid, text, text, uuid);
drop function if exists public._report_avatar_object(uuid, text);

-- ---------------------------------------------------------------------------
-- 3. The table (ONE-WAY: the reports are gone).
-- ---------------------------------------------------------------------------
drop table if exists public.player_reports;

-- ---------------------------------------------------------------------------
-- 4. attempt_log: M3 part 1's nine actions. The report_filed rows must go
--    first, or the constraint can't be re-added (the count is in the
--    result row).
-- ---------------------------------------------------------------------------
delete from public.attempt_log
where action = 'report_filed';

alter table public.attempt_log drop constraint attempt_log_action_check;
alter table public.attempt_log
  add constraint attempt_log_action_check
  check (action in ('create_table', 'create_computer_table', 'join', 'watch', 'code_guess',
                    'game_start', 'follow_change', 'block_change', 'kick'));

comment on table public.attempt_log is
  'Rate limits (step 3, slices A and E; moderation M1 and M3): one row per counted action -- a table created (create_table), a computer game started (create_computer_table), a join, a new watch, a game started (game_start), a real follow or unfollow (follow_change), a real block or unblock (block_change), a real kick (kick) (success true), or a wrong table code (code_guess, success false). Read and written only by security definer functions through the _attempts_* / _code_guess* helpers. Rows older than 7 days are deleted hourly by cleanup_attempt_log() (pg_cron job attempt-log-cleanup). RLS on, no policies, no grants. See docs/sql/join-create.sql, slice-e-part1.sql, moderation-m1-part1.sql and moderation-m3-part1.sql.';

notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  to_regclass('public.player_reports') is null as player_reports_gone,
  to_regprocedure('public.report_player(uuid, text, text, uuid)') is null as report_player_gone,
  to_regprocedure('public.purge_old_reports()') is null as purge_gone,
  (select c.reports from m6_rollback_counts c) as reports_deleted,
  (select c.report_filed_rows from m6_rollback_counts c) as report_filed_rows_deleted,
  (select pg_get_constraintdef(con.oid) from pg_constraint con
   where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check') as attempt_log_action_check,
  case when to_regclass('cron.job') is null then 'pg_cron not installed'
       else (xpath('/row/c/text()', query_to_xml('select count(*) as c from cron.job where jobname = ''report-purge''', false, true, '')))[1]::text end as report_purge_jobs_left;
