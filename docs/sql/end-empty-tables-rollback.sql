-- Step 3, slice C: ROLLBACK of docs/sql/end-empty-tables.sql.
-- Run in the Supabase Dashboard -> SQL Editor.
--
-- STATUS: written, NOT RUN yet. Kept for reference; run only if slice C has
-- to come out.
--
-- What it does, in one transaction:
--   1. unschedules the pg_cron job 'end-empty-tables' (if pg_cron and the job
--      exist; through EXECUTE, so this file parses without pg_cron);
--   2. drops the two triggers on table_members (table_members_end_when_empty,
--      table_members_require_open) and their functions
--      (end_table_when_empty, require_open_table);
--   3. drops end_empty_tables.
-- KEPT, on purpose:
--   * 'empty' in tables_ended_reason_check. Tables already ended as 'empty'
--     can't go back: removing the value would make the constraint fail on
--     them (or force rewriting their history). The app keeps reading 'empty'
--     ("Everyone left, so this table has closed.").
--   * Every table the migration's cleanup, the triggers or the sweep ended:
--     ended stays ended (nothing re-opens a table).
-- Nothing else was ever changed by slice C: leave_table,
-- end_timed_out_sessions, assign_table_seat and table_host were never
-- touched, so there is nothing to restore.
--
-- AFTER IT: the last player leaving leaves an open table with no seats again,
-- until the 12-hour timeout (the behavior before slice C).

begin;

-- 1. The job.
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed: no job to unschedule.';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'end-empty-tables') then
    execute $cron$select cron.unschedule('end-empty-tables')$cron$;
  end if;
end;
$$;

-- 2. The triggers, then their functions.
drop trigger if exists table_members_end_when_empty on public.table_members;
drop trigger if exists table_members_require_open on public.table_members;
drop function if exists public.end_table_when_empty();
drop function if exists public.require_open_table();

-- 3. The sweep.
drop function if exists public.end_empty_tables();

commit;
