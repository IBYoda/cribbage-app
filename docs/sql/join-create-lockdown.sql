-- Step 3, slice A: the LOCKDOWN -- no more direct INSERTs into tables or
-- table_members by signed-in players. Run in the Supabase Dashboard -> SQL
-- Editor, LAST.
--
-- STATUS: written, NOT RUN yet.
--
-- WHEN: only after BOTH
--   * docs/sql/join-create.sql has run and its verification passed, and
--   * the app is live with Start a Table calling create_table and TableView
--     taking a seat through join_table_by_code (no direct insert or upsert
--     left in the app).
-- Running it earlier breaks Start a Table ("permission denied for table
-- tables") and joining ("permission denied for table table_members") at
-- once. Then re-run docs/sql/join-create-verification.sql: its L checks
-- (skipped until now) prove the lockdown.
--
-- WHAT IT DOES (one transaction):
--   1. tables: takes away authenticated's INSERT. A table-wide REVOKE also
--      removes every column grant, so this undoes both
--        grant insert (code, created_by, is_public, is_muggins, max_players,
--          team_mode) on public.tables to authenticated
--                                        (phase3-hardening-grants.sql), and
--        grant insert (allow_spectators) on public.tables to authenticated
--                                        (spectators-grant-insert.sql).
--   2. table_members: takes away authenticated's INSERT (undoes
--        grant insert (table_id, user_id) on public.table_members to
--          authenticated               (phase3-hardening-grants.sql)).
--   anon had no INSERT on either since phase3-hardening-grants.sql; it is
--   revoked again here so a drifted grant can't survive.
-- NOT touched: the INSERT policies ("Users can create their own table",
-- "Users can add themselves to a table") -- with no INSERT privilege they
-- can no longer be used, and the phase3-e1 / muggins suites still look for
-- them by name; SELECT/UPDATE/DELETE grants; every function.
--
-- WHAT STILL WRITES THOSE TABLES, AND HOW (none of it needs a client grant):
--   * create_table, join_table_by_code, create_computer_table: security
--     definer, run as the owner.
--   * leave_table, leave_computer_table, set_seat, the game functions, the
--     seat trigger: security definer (or the owner's trigger).
--   * the admin's Force-End: an UPDATE (its own policy and grant), not an
--     INSERT.
--   Nothing in the app inserts into either table directly once it uses the
--   two RPCs (checked against the code on 2026-11-23: the only direct
--   inserts were app/tables/new/page.tsx's .from("tables").insert(...) and
--   components/table/TableView.tsx takeSeat's .from("table_members")
--   .upsert(...)). Single player already uses create_computer_table.
--
-- WHAT THIS BREAKS THAT MUST CHANGE (tests, not players):
--   * docs/sql/phase3-hardening-grants-verification.sql G1/G2 expect exactly
--     those column grants; after this they fail by design (re-baseline them
--     to "no INSERT at all").
--   * Every verification suite that inserts into tables or table_members AS
--     authenticated ("set local role authenticated" then insert): muggins-
--     mode, phase3-e1..e4, phase3-hardening-grants, phase3-muggins-
--     multiplayer, phase3-solo, table-visibility. Their inserts get
--     "permission denied"; they would need to insert as the owner, or call
--     create_table / join_table_by_code. (Suites that insert as the owner are
--     unaffected.)
--   * scripts/test-phase3.ts "Start a Table: every column the insert sends
--     has a column-level INSERT grant in docs/sql" stays green (it only reads
--     grant statements, and this file has none), but it then describes a
--     path that no longer exists: retire it with the app switch.
--
-- RE-RUNNABLE: revokes are idempotent. The guard below refuses to run before
-- join-create.sql is in.
--
-- UNDO: docs/sql/join-create-rollback.sql section 1 gives the column grants
-- back (exactly the lists above).

begin;

-- Guard: the RPCs that replace the direct inserts must exist first.
do $$
begin
  if to_regprocedure('public.create_table(boolean, boolean, integer, text, boolean)') is null
     or to_regprocedure('public.join_table_by_code(text, boolean)') is null then
    raise exception 'STOP: join-create.sql has not run (create_table / join_table_by_code missing). Nothing was changed.';
  end if;
end;
$$;

-- 1. tables: no INSERT for players (table-wide, so the column grants go too).
revoke insert on public.tables from authenticated;
revoke insert on public.tables from anon;

-- 2. table_members: no INSERT for players.
revoke insert on public.table_members from authenticated;
revoke insert on public.table_members from anon;

commit;
