-- Phase 3 hardening: CLOSE THE DIRECT-INSERT HOLES on tables and table_members.
-- Run this in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
-- Checks: docs/sql/phase3-hardening-grants-verification.sql.
--
-- ROLLBACK (puts back the table-wide INSERT right these tables had before;
-- run as one transaction):
--   begin;
--   revoke insert on public.tables from authenticated;
--   revoke insert on public.table_members from authenticated;
--   grant insert on public.tables to anon, authenticated;
--   grant insert on public.table_members to anon, authenticated;
--   commit;
-- Before running THIS file, record what is live so the rollback can match it
-- exactly (Supabase's defaults gave anon and authenticated INSERT on every
-- table made before October 30, 2026):
--   select table_name, grantee, privilege_type
--   from information_schema.role_table_grants
--   where table_schema = 'public' and table_name in ('tables', 'table_members')
--     and grantee in ('anon', 'authenticated') and privilege_type = 'INSERT';
--
-- WHY. Both tables were made before Supabase stopped granting Data API access
-- to new tables, so anon and authenticated can INSERT into EVERY column; the
-- row-level policies only check whose row it is ("created_by = me", "user_id
-- = me"), never which columns are set. So a signed-in client could, with a
-- direct API insert:
--   * tables: set computer_level -- get_leaderboard trusts it: a regular
--     table marked 'hard' adds Beat God wins, and any level drops the table's
--     games from wins and losses; set created_at in the future -- the 12-hour
--     sweep (end_timed_out_sessions) never ends it; set status or
--     ended_reason;
--   * table_members: sit down with a made-up score, last award or joined_at
--     (only the seat is overridden, by the assign_table_seat trigger).
--
-- THE FIX: INSERT stays, but only on the columns the app sends.
--   * Start a Table (app/tables/new/page.tsx + newTableFields in
--     lib/newTable.ts) inserts code, created_by, is_public, is_muggins,
--     max_players and -- for 4 players, and for 3- or 4-player Self-Scoring
--     -- team_mode. Everything else takes its column default.
--   * Taking a seat (takeSeat in app/tables/[code]/page.tsx -- the first
--     join, the joiner, a rejoin, a refresh) is ONE upsert of table_id and
--     user_id with ignoreDuplicates, i.e. INSERT ... ON CONFLICT (table_id,
--     user_id) DO NOTHING. The conflict target needs SELECT on those columns,
--     which authenticated keeps.
--   * Nothing else in the app inserts into either table. Every SQL writer is
--     security definer (create_computer_table, assign_table_seat, leave_table,
--     ...) and runs as the owner, so these grants never apply to it;
--     award_points is not security definer but is granted to no client and is
--     only called from security-definer functions.
--
-- NOT TOUCHED, deliberately:
--   * SELECT, UPDATE, DELETE on both tables. A player cannot UPDATE or DELETE
--     either table directly today: the only UPDATE policy is the admins'
--     ("Admins can force-end tables", slice-7-admin.sql), which Force-End
--     needs, and there is no DELETE policy, so row-level security refuses
--     every other row. The same holds for games (admin-only UPDATE), and
--     game_hands, game_cribs, game_plays and game_decks have no UPDATE or
--     DELETE policy at all. So this file adds no update or delete section.
--   * The policies. "Users can create their own table" and "Users can add
--     themselves to a table" still decide WHOSE row; the grants now decide
--     WHICH columns.
--   * service_role and the table owner (the SQL Editor, every security-
--     definer function).
--   * Every function: no function body changes, so no fingerprint in any
--     verification suite moves.
--
-- RE-RUNNABLE: revoking a table-wide privilege also revokes it from every
-- column, and the grants then add exactly the listed columns back, so a
-- second run ends in the same state.

begin;

-- ---------------------------------------------------------------------------
-- 1. tables: INSERT only on the columns Start a Table sends.
-- ---------------------------------------------------------------------------
-- Takes away INSERT on every column from both client roles. anon never needs
-- to create a table (the "created_by = me" policy already refused it, as
-- auth.uid() is null), so it gets nothing back.
revoke insert on public.tables from anon, authenticated;

-- Gives signed-in players back exactly the six columns Start a Table sends.
-- id, status ('open'), created_at (now()), ended_reason and computer_level
-- (null) can no longer be set by a client; computer tables get theirs from
-- create_computer_table, which runs as the owner.
grant insert (code, created_by, is_public, is_muggins, max_players, team_mode)
  on public.tables to authenticated;


-- ---------------------------------------------------------------------------
-- 2. table_members: INSERT only on the two columns taking a seat sends.
-- ---------------------------------------------------------------------------
-- Takes away INSERT on every column from both client roles; anon gets
-- nothing back.
revoke insert on public.table_members from anon, authenticated;

-- Gives signed-in players back exactly table_id and user_id. joined_at
-- (now()), score (0) and the last award (null) take their defaults, and the
-- seat is set by the assign_table_seat trigger, as before.
grant insert (table_id, user_id)
  on public.table_members to authenticated;

commit;
