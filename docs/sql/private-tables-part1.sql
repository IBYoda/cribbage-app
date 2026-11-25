-- Step 3, slice D: PRIVATE TABLES, PART 1 -- the read helpers (ADD-ONLY).
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- RUN ORDER (slice D):
--   0. The app build that reads a private table it isn't seated at through
--      join_table_by_code's preview BY ID (components/table/TableView.tsx:
--      the setup and the stale-tab check) and awaits a spectator's heartbeat
--      before reading is LIVE first. Give open tabs time to reload (a deploy
--      plus an hour is plenty).
--   1. docs/sql/private-tables-precheck.sql        (read-only; one result)
--   2. docs/sql/private-tables-part1.sql           (this file: add-only)
--   3. docs/sql/private-tables-precheck.sql again  (part 1 now PRESENT)
--   4. docs/sql/private-tables-part2.sql           (the policy swap)
--   5. docs/sql/private-tables-verification.sql    (rolled back; the final
--                                                    message is the verdict)
--   If the swap has to come out: docs/sql/private-tables-part2-rollback.sql.
--
-- WHAT WALT DECIDED (step 3, slice D):
--   * Public tables (is_public = true) stay readable by any signed-in user,
--     exactly as today. The lobby does not change.
--   * A PRIVATE table (is_public = false) is readable only by:
--       (a) a player seated there now (a table_members row);
--       (b) a CURRENT spectator (a table_spectators row, removed_at null,
--           last_seen_at within 90 seconds -- spectators.sql's "current");
--       (c) anyone in games.players of a game there: THAT game and its plays,
--           forever, plus the table row and the roster needed to show it;
--       (d) an admin (an admin_users row): everything.
--     Everyone else: zero rows.
--   * Private games still count on leaderboards (the leaderboard functions
--     are security definer: unchanged). Profiles stay readable by signed-in
--     users. No "unlisted" kind. join_table_by_code and watch_table stay as
--     slice B left them.
--
-- WHAT THIS FILE DOES (one transaction, ADD-ONLY): seven helper functions.
-- Each is LANGUAGE sql, STABLE, SECURITY DEFINER (it reads as the owner, so
-- it never meets the row policies it will serve -- no 42P17 recursion), with
-- an empty search_path (every name schema-qualified) and auth.uid() wrapped
-- as (select auth.uid()). EXECUTE: authenticated only (revoked from PUBLIC,
-- anon and service_role).
--   is_table_member(table)       the caller has a seat there now.
--   is_current_spectator(table)  the caller is a current, not-removed
--                                spectator there (seen in the last 90 s).
--   is_admin()                   the caller has an admin_users row.
--   is_game_player(game)         the caller is in that game's players.
--   is_public_table(table)       the table is public (so a policy never
--                                reads tables itself).
--   can_read_table(table)        public, OR (a) member, OR (b) current
--                                spectator, OR (d) admin, OR (c) the caller
--                                played in ANY game of that table -- the
--                                table row and the roster.
--   can_read_game(game)          that game's table is public, OR (a) / (b) /
--                                (d) at its table, OR (c) the caller is in
--                                THAT game's players -- a game and its plays.
--   A missing table or game reads as false everywhere.
--
-- NOTHING USES THEM YET: no policy, trigger, function or app code calls
-- them. Reads are exactly as before this file. part2 swaps the four open
-- SELECT policies onto them.
--
-- NOT TOUCHED: every policy, grant and table; chat_topic_allows; the four
-- fingerprinted functions (leave_table, end_timed_out_sessions,
-- assign_table_seat, table_host); join_table_by_code; watch_table.
--
-- RE-RUNNABLE: "create or replace function" with the same signatures and
-- idempotent revokes / grants. The guard stops (changing nothing) if a
-- function of one of these names exists with OTHER arguments, which a
-- policy could pick up by mistake.
--
-- ROLLBACK: nothing depends on them until part2. To remove them (only while
-- part2 is NOT applied -- its policies call them):
--   drop function if exists public.can_read_game(uuid);
--   drop function if exists public.can_read_table(uuid);
--   drop function if exists public.is_public_table(uuid);
--   drop function if exists public.is_game_player(uuid);
--   drop function if exists public.is_admin();
--   drop function if exists public.is_current_spectator(uuid);
--   drop function if exists public.is_table_member(uuid);
-- (docs/sql/private-tables-part2-rollback.sql has the same, as its optional
-- step 2.)

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard: no other overload of these names.
-- ---------------------------------------------------------------------------
do $$
declare
  v_other text;
begin
  select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
  into v_other
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('is_table_member', 'is_current_spectator', 'is_admin', 'is_game_player',
                      'is_public_table', 'can_read_table', 'can_read_game')
    and p.oid::regprocedure::text not in (
      'is_table_member(uuid)', 'is_current_spectator(uuid)', 'is_admin()', 'is_game_player(uuid)',
      'is_public_table(uuid)', 'can_read_table(uuid)', 'can_read_game(uuid)',
      'public.is_table_member(uuid)', 'public.is_current_spectator(uuid)', 'public.is_admin()',
      'public.is_game_player(uuid)', 'public.is_public_table(uuid)', 'public.can_read_table(uuid)',
      'public.can_read_game(uuid)');
  if v_other is not null then
    raise exception 'STOP: other functions with a slice D helper name exist: %. Nothing was changed.', v_other;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. is_table_member(table): (a) a seat there now.
-- ---------------------------------------------------------------------------
create or replace function public.is_table_member(p_table_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.table_members tm
    where tm.table_id = p_table_id
      and tm.user_id = (select auth.uid())
  );
$$;

comment on function public.is_table_member(uuid) is
  'Step 3 slice D (private tables): true when the caller has a table_members row (a seat) at this table now. Security definer, stable, empty search_path: used by the row policies without meeting them. See docs/sql/private-tables-part1.sql.';

revoke all on function public.is_table_member(uuid) from public;
revoke all on function public.is_table_member(uuid) from anon;
revoke all on function public.is_table_member(uuid) from service_role;
grant execute on function public.is_table_member(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. is_current_spectator(table): (b) watching now -- not removed, and seen
--    in the last 90 seconds (the same "current" as spectators.sql).
-- ---------------------------------------------------------------------------
create or replace function public.is_current_spectator(p_table_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.table_spectators ts
    where ts.table_id = p_table_id
      and ts.user_id = (select auth.uid())
      and ts.removed_at is null
      and ts.last_seen_at > pg_catalog.now() - interval '90 seconds'
  );
$$;

comment on function public.is_current_spectator(uuid) is
  'Step 3 slice D (private tables): true when the caller is a CURRENT spectator of this table -- a table_spectators row, removed_at null, last_seen_at within 90 seconds (spectators.sql). A lapsed or removed spectator is false. Security definer, stable, empty search_path. See docs/sql/private-tables-part1.sql.';

revoke all on function public.is_current_spectator(uuid) from public;
revoke all on function public.is_current_spectator(uuid) from anon;
revoke all on function public.is_current_spectator(uuid) from service_role;
grant execute on function public.is_current_spectator(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. is_admin(): (d) an admin_users row.
-- ---------------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.admin_users a
    where a.user_id = (select auth.uid())
  );
$$;

comment on function public.is_admin() is
  'Step 3 slice D (private tables): true when the caller has an admin_users row. Admins read every table, roster, game and play. Security definer, stable, empty search_path. See docs/sql/private-tables-part1.sql.';

revoke all on function public.is_admin() from public;
revoke all on function public.is_admin() from anon;
revoke all on function public.is_admin() from service_role;
grant execute on function public.is_admin() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. is_game_player(game): the caller is in that game's players.
-- ---------------------------------------------------------------------------
create or replace function public.is_game_player(p_game_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.games g
    where g.id = p_game_id
      and (select auth.uid()) = any(g.players)
  );
$$;

comment on function public.is_game_player(uuid) is
  'Step 3 slice D (private tables): true when the caller is listed in games.players of this game. Security definer, stable, empty search_path. See docs/sql/private-tables-part1.sql.';

revoke all on function public.is_game_player(uuid) from public;
revoke all on function public.is_game_player(uuid) from anon;
revoke all on function public.is_game_player(uuid) from service_role;
grant execute on function public.is_game_player(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. is_public_table(table): the table is public (a missing one is not).
-- ---------------------------------------------------------------------------
create or replace function public.is_public_table(p_table_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.tables t
    where t.id = p_table_id
      and t.is_public
  );
$$;

comment on function public.is_public_table(uuid) is
  'Step 3 slice D (private tables): true when this table is public (is_public = true). Lets the table_members / games / game_plays policies ask without reading tables themselves. Security definer, stable, empty search_path. See docs/sql/private-tables-part1.sql.';

revoke all on function public.is_public_table(uuid) from public;
revoke all on function public.is_public_table(uuid) from anon;
revoke all on function public.is_public_table(uuid) from service_role;
grant execute on function public.is_public_table(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. can_read_table(table): the TABLE ROW and the ROSTER.
--    public OR (a) member OR (b) current spectator OR (d) admin OR (c) the
--    caller played in any game of that table.
-- ---------------------------------------------------------------------------
create or replace function public.can_read_table(p_table_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_public_table(p_table_id)
      or public.is_table_member(p_table_id)
      or public.is_current_spectator(p_table_id)
      or public.is_admin()
      or exists (
           select 1
           from public.games g
           where g.table_id = p_table_id
             and (select auth.uid()) = any(g.players)
         );
$$;

comment on function public.can_read_table(uuid) is
  'Step 3 slice D (private tables): may the caller read this table''s row and roster? Public, or a seat there now, or a current spectator, or an admin, or a player of any game at that table (forever). Security definer, stable, empty search_path. See docs/sql/private-tables-part1.sql.';

revoke all on function public.can_read_table(uuid) from public;
revoke all on function public.can_read_table(uuid) from anon;
revoke all on function public.can_read_table(uuid) from service_role;
grant execute on function public.can_read_table(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. can_read_game(game): a GAME and its PLAYS.
--    its table public OR (a) / (b) / (d) at its table OR (c) the caller is in
--    THAT game's players (never another game of the same table).
-- ---------------------------------------------------------------------------
create or replace function public.can_read_game(p_game_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.games g
    where g.id = p_game_id
      and (
        public.is_public_table(g.table_id)
        or public.is_table_member(g.table_id)
        or public.is_current_spectator(g.table_id)
        or public.is_admin()
        or (select auth.uid()) = any(g.players)
      )
  );
$$;

comment on function public.can_read_game(uuid) is
  'Step 3 slice D (private tables): may the caller read this game and its plays? Its table is public, or the caller has a seat there now, is a current spectator there or an admin, or is in THIS game''s players (forever). Security definer, stable, empty search_path. See docs/sql/private-tables-part1.sql.';

revoke all on function public.can_read_game(uuid) from public;
revoke all on function public.can_read_game(uuid) from anon;
revoke all on function public.can_read_game(uuid) from service_role;
grant execute on function public.can_read_game(uuid) to authenticated;

commit;
