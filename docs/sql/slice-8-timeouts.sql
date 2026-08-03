-- Slice 8: Automatic timeouts (5-hour game, 12-hour table)
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.

-- Before running this file: enable pg_cron via Database -> Extensions in the
-- dashboard (the toggle you already found). No SQL needed for that step.

-- Records *why* a table/game ended, so a connected player can be shown a
-- distinct message for an admin force-end (Slice 7) vs. an automatic timeout.
alter table public.tables
  add column ended_reason text
  check (ended_reason is null or ended_reason in ('admin', 'timeout'));

alter table public.games
  add column ended_reason text
  check (ended_reason is null or ended_reason in ('admin', 'timeout'));

-- The actual sweep. security definer makes this run with the privileges of
-- whichever role creates it (you, via the SQL Editor, which owns these
-- tables) rather than the caller's -- required for correctness, not just best
-- practice: the existing UPDATE policies on tables/games only allow admins
-- (auth.uid() in admin_users), and a cron job has no authenticated user at
-- all (auth.uid() is null in that context), so without security definer
-- these updates would silently match zero rows, the same way Slice 7's RLS
-- test showed for a non-admin.
create or replace function public.end_timed_out_sessions()
returns void
language sql
security definer
set search_path = public
as $$
  -- Games older than 5 hours end on their own, independent of their table.
  update public.games
  set status = 'ended', ended_reason = 'timeout'
  where status = 'active'
    and created_at < now() - interval '5 hours';

  -- Tables older than 12 hours end on their own.
  update public.tables
  set status = 'ended', ended_reason = 'timeout'
  where status = 'open'
    and created_at < now() - interval '12 hours';

  -- Consistency sweep: a table that's no longer open shouldn't still have an
  -- "active" game (mirrors what Slice 7's admin force-end already does
  -- manually). This mostly catches games younger than 5 hours whose table
  -- just timed out above.
  update public.games
  set status = 'ended', ended_reason = 'timeout'
  where status = 'active'
    and table_id in (select id from public.tables where status <> 'open');
$$;

-- Runs every 15 minutes. Worst-case a timeout is enforced ~15 minutes late,
-- which is fine at these thresholds (hours, not minutes).
select cron.schedule(
  'end-timed-out-sessions',
  '*/15 * * * *',
  $$ select public.end_timed_out_sessions(); $$
);
