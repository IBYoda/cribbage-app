-- Step 3, slice A: ROLLBACK of docs/sql/join-create.sql (and of
-- docs/sql/join-create-lockdown.sql, if it ran).
-- Run in the Supabase Dashboard -> SQL Editor.
--
-- STATUS: written, NOT RUN yet. Kept for reference; run only if slice A has
-- to come out.
--
-- !!! AFTER STEP 3 SLICE B, DO NOT RUN THIS FILE AS IT IS. !!!
--   * Once slice B part 1 (docs/sql/free-codes-part1.sql) is in,
--     join_table_by_code and watch_table have new signatures; section 2a
--     below re-creates watch_table(text) BESIDE watch_table(text, uuid)
--     (two overloads: calls with one argument become ambiguous) and section
--     3's "drop function ... join_table_by_code(text, boolean)" misses the
--     new one. Roll slice B back first: free-codes-part2-rollback.sql (if
--     part 2 ran), then free-codes-part1-rollback.sql, which restore exactly
--     the slice A functions this file expects.
--   * Once slice B part 2 (docs/sql/free-codes-part2.sql) has run and any
--     code has been REUSED, two tables share a code. Section 2a's
--     watch_table (spectators-join-or-watch.sql's text) looks a table up by
--     code with NO status filter and no order -- it could pick the ended
--     table, or the wrong one -- and tables_code_key can never come back.
--     Then slice A should not be rolled back at all: keep slice B's
--     watch_table and fix forward.
--
-- BEFORE IT: the app must be back on the direct inserts (Start a Table's
-- insert into tables, TableView's upsert into table_members). An app that
-- calls create_table or join_table_by_code breaks the moment this runs
-- ("function does not exist").
--
-- What it does, in one transaction:
--   1. undoes the lockdown: gives authenticated back exactly the column
--      INSERT grants phase3-hardening-grants.sql and spectators-grant-
--      insert.sql gave (idempotent: harmless if the lockdown never ran);
--   2. puts watch_table back to spectators-join-or-watch.sql's text, with its
--      comment and grants (spectators.sql's), and create_computer_table back
--      to the LIVE text captured on 2026-11-23
--      (computer-live-create_computer_table-2026-11-23.sql; NOT
--      computer-normie.sql's, which has comments the live text doesn't),
--      with its grants. Both bodies below are copied exactly, so their md5s
--      are ones join-create-precheck.sql accepts:
--        watch_table            6c9dfb0cfb9987d318da595b2f9a3142 (LF)
--                               a7720e04ab8ab714654d93343df15020 (CRLF)
--        create_computer_table  7f804511bc76a0228d7158c544e1fdec (CRLF: as
--                               live; keep this file's CRLF line ends)
--                               71f74319e76ab1cfe2a25d39e1d9d7ec (LF)
--   3. drops create_table, join_table_by_code, the four helpers and the
--      attempt_log table (its rows go with it: they are only rate-limit
--      counts).
-- Nothing else: policies, the seat trigger and every game function were
-- never touched by slice A.
--
-- AFTER IT: spectators-join-or-watch-verification.sql and
-- computer-c2-verification.sql describe the restored behavior again.

begin;

-- ---------------------------------------------------------------------------
-- 1. The lockdown, undone (the column grants as phase3-hardening-grants.sql
--    and spectators-grant-insert.sql wrote them).
-- ---------------------------------------------------------------------------
grant insert (code, created_by, is_public, is_muggins, max_players, team_mode)
  on public.tables to authenticated;
grant insert (allow_spectators) on public.tables to authenticated;
grant insert (table_id, user_id)
  on public.table_members to authenticated;


-- ---------------------------------------------------------------------------
-- 2a. watch_table: spectators-join-or-watch.sql's text, exactly.
-- ---------------------------------------------------------------------------
create or replace function public.watch_table(p_code text)
returns table (table_id uuid, code text, game_id uuid)
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_caller uuid := auth.uid();
  v_table record;
  v_game_id uuid;
  v_removed_at timestamptz;
  v_current int;
begin
  if v_caller is null then
    raise exception 'You must be logged in to watch a table.';
  end if;

  -- THE ROW LOCK, the same one assign_table_seat (joining), set_seat and
  -- start_game_with_deal take: two watchers are serialized here, so the
  -- count below is final until this transaction ends.
  select t.id, t.code, t.status, t.allow_spectators, t.computer_level
  into v_table
  from public.tables t
  where t.code = p_code
  for no key update;

  if not found then
    raise exception 'No table found with code %.', coalesce(p_code, '');
  end if;

  if v_table.status is distinct from 'open' then
    raise exception 'This table has ended.';
  end if;

  -- Before allow_spectators, so a computer table gets its own message (the
  -- check constraint means it can never allow spectators anyway).
  if v_table.computer_level is not null then
    raise exception 'Computer tables cannot be watched.';
  end if;

  if not v_table.allow_spectators then
    raise exception 'This table does not allow spectators.';
  end if;

  -- A LIVE game, if there is one: the cut for deal or a game being played.
  -- NULL is fine now: the table is in its waiting room (or between games).
  select g.id
  into v_game_id
  from public.games g
  where g.table_id = v_table.id
    and g.status in ('cutting', 'active')
  order by g.created_at desc
  limit 1;

  if exists (
    select 1
    from public.table_members tm
    where tm.table_id = v_table.id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are seated at this table.';
  end if;

  select ts.removed_at
  into v_removed_at
  from public.table_spectators ts
  where ts.table_id = v_table.id
    and ts.user_id = v_caller;

  if v_removed_at is not null then
    raise exception 'You were removed from watching this table.';
  end if;

  -- THE CAP: 4 current spectators besides the caller (an already-current
  -- caller refreshing their place is never refused).
  select count(*)
  into v_current
  from public.table_spectators ts
  where ts.table_id = v_table.id
    and ts.user_id <> v_caller
    and ts.removed_at is null
    and ts.last_seen_at > now() - interval '90 seconds';

  if v_current >= 4 then
    raise exception 'Spectators full: this table already has 4 spectators.';
  end if;

  -- Insert, or refresh a row that is there (removed_at is null: checked
  -- above; the update never touches removed_at, so a removal that lands
  -- meanwhile still stands).
  insert into public.table_spectators as ts (table_id, user_id, joined_at, last_seen_at)
  values (v_table.id, v_caller, now(), now())
  on conflict on constraint table_spectators_pkey
  do update set last_seen_at = excluded.last_seen_at;

  table_id := v_table.id;
  code := v_table.code;
  game_id := v_game_id;   -- null while no game is live
  return next;
end;
$$;

comment on function public.watch_table(text) is
  'Spectator seat (PRD item 40): become or stay a spectator of the table with this code, whether or not a game is live. Refused with a message when not allowed (see docs/sql/spectators.sql and spectators-join-or-watch.sql). Returns the table id, code and the live game id (null in the waiting room or between games).';

revoke all on function public.watch_table(text) from public;
revoke all on function public.watch_table(text) from anon;
revoke all on function public.watch_table(text) from service_role;
grant execute on function public.watch_table(text) to authenticated;


-- ---------------------------------------------------------------------------
-- 2b. create_computer_table: the LIVE text of 2026-11-23, exactly
--     (computer-live-create_computer_table-2026-11-23.sql).
-- ---------------------------------------------------------------------------
create or replace function public.create_computer_table(p_level text, p_code text)
returns table (table_id uuid, code text)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_caller uuid := auth.uid();
  v_computer uuid;
  v_table_id uuid;
  v_code text;
begin
  if v_caller is null then
    raise exception 'You must be logged in to start a table.';
  end if;

  if p_level is null or p_level not in ('easy', 'casual', 'medium', 'hard') then
    raise exception 'Unknown computer level "%": choose easy, casual, medium or hard.', coalesce(p_level, '');
  end if;

  select ca.user_id
  into v_computer
  from public.computer_accounts ca
  where ca.level = p_level;

  if v_computer is null then
    raise exception 'The % computer is not set up yet.', p_level;
  end if;

  if v_computer = v_caller then
    raise exception 'A computer account cannot start a computer table.';
  end if;

  insert into public.tables (code, created_by, is_public, is_muggins, max_players, computer_level)
  values (p_code, v_caller, false, false, 2, p_level)
  returning tables.id, tables.code into v_table_id, v_code;

  insert into public.table_members (table_id, user_id)
  values (v_table_id, v_caller);

  insert into public.table_members (table_id, user_id)
  values (v_table_id, v_computer);

  table_id := v_table_id;
  code := v_code;
  return next;
end;
$$;

-- Grants as live ("create or replace" keeps the ACL, so service_role keeps
-- its EXECUTE; nothing here revokes it).
revoke all on function public.create_computer_table(text, text) from public;
revoke all on function public.create_computer_table(text, text) from anon;
grant execute on function public.create_computer_table(text, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. What slice A added.
-- ---------------------------------------------------------------------------
drop function if exists public.join_table_by_code(text, boolean);
drop function if exists public.create_table(boolean, boolean, integer, text, boolean);
drop function if exists public._one_table_rule(uuid, uuid, boolean);
drop function if exists public._code_guess_failed(uuid);
drop function if exists public._code_guesses_check(uuid);
drop function if exists public._attempts_guard(uuid, text, integer, interval, text);
drop table if exists public.attempt_log;

commit;
