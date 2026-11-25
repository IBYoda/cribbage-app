-- Step 3, slice D: PRIVATE TABLES, PART 2 -- THE POLICY SWAP.
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- WHEN: LAST, only after
--   * the app build that reads a private table it isn't seated at through
--     join_table_by_code's preview BY ID, and awaits a spectator's heartbeat
--     before reading, is LIVE, and old tabs have reloaded (a deploy plus an
--     hour is plenty). An OLD tab still works for its players (seated, they
--     keep reading) -- what an old tab gets wrong is a NON-member's direct
--     read of a private table (Retry after the confirm screen; a copied ?t=
--     link): "This table has ended." instead of the confirm. Reloading fixes
--     it.
--   * docs/sql/private-tables-part1.sql ran, and
--   * docs/sql/private-tables-precheck.sql shows no STOP row (its helper rows
--     say "part 1 present").
-- Then run docs/sql/private-tables-verification.sql.
-- To undo: docs/sql/private-tables-part2-rollback.sql (puts the four open
-- policies back exactly; no data changes either way).
--
-- WHAT WALT DECIDED: see docs/sql/private-tables-part1.sql. In short: public
-- tables read as today; a PRIVATE table only by (a) its seated players,
-- (b) its CURRENT spectators, (c) the players of a game there -- that game,
-- its plays, the table row and the roster -- forever, (d) admins.
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold): the four
--      fingerprinted bodies unchanged (LF or CRLF); the seven part 1 helpers
--      present as security definer, stable, empty search_path, EXECUTE for
--      authenticated only; RLS enabled and NOT forced on tables,
--      table_members, games, game_plays, table_spectators, admin_users; no
--      client role can EXECUTE the seven SECURITY INVOKER functions; and on
--      each of the four tables the SELECT policies are exactly the old open
--      one (with the live text) or exactly this file's (a re-run).
--   1. The four OLD open SELECT policies are dropped:
--        tables         "Tables are viewable by any logged-in user"
--        table_members  "Table members are viewable by any logged-in user"
--        games          "Games are viewable by any logged-in user"
--        game_plays     "Played cards are viewable by any logged-in user"
--   2. Four NEW SELECT policies, all "to authenticated" ONLY (anon never
--      evaluates a helper it cannot execute: it simply gets zero rows):
--        tables         "Public tables, or private ones the caller may read"
--                       is_public OR can_read_table(id)
--        table_members  "Rosters of tables the caller may read"
--                       can_read_table(table_id)
--        games          "Games the caller may read"
--                       is_public_table(table_id) OR is_table_member(table_id)
--                       OR is_current_spectator(table_id) OR is_admin()
--                       OR (select auth.uid()) = any(players)
--        game_plays     "Plays of games the caller may read"
--                       can_read_game(game_id)
--      No policy queries its own table: every lookup goes through a part 1
--      helper (security definer, reading as the owner), so there is no 42P17
--      recursion. auth.uid() and is_admin() are wrapped in (select ...) so
--      Postgres works them out once per statement.
--
-- NOT TOUCHED (checked by the verification):
--   * "Admins can force-end tables" / "Admins can force-end games" (UPDATE):
--     kept. An UPDATE also needs its row through SELECT; is_admin() is in the
--     new policies, so Force-End works on private tables too.
--   * The INSERT policies on tables and table_members (unused since slice A).
--   * game_hands (3 SELECT policies) and game_cribs (3): their subqueries read
--     games and table_members UNDER THE CALLER'S policies. They still behave:
--       - "Players read their own hand, or a hand shown at their table" and
--         "Players at the table read a shown crib" join games to the caller's
--         OWN table_members row: a seated player still sees both (member).
--       - the other four check auth.uid() = any(games.players): the new games
--         policy always shows a game to its players.
--     So no change is needed; the verification proves it (H checks).
--   * game_decks: no policy, nobody reads it (unchanged).
--   * table_spectators "Table members and the spectator read spectator rows":
--     its subquery reads table_members for the caller's OWN seat, which the
--     new policy still shows them. No change needed.
--   * profiles, admin_users, chat_topic_allows, join_table_by_code,
--     watch_table, every function, every grant, the Realtime publication.
--   * leave_table, end_timed_out_sessions, assign_table_seat, table_host: byte
--     for byte (all security definer except table_host, which only definer
--     functions call -- they read as their owner, past every policy).
--
-- REALTIME: postgres_changes checks each INSERT / UPDATE event against the
-- subscriber's SELECT policy, so from this moment a non-member subscribed to
-- a private table's channel receives nothing. The app's channel filters
-- (table_id=eq / id=eq / game_id=eq) are unchanged and still apply on top.
--
-- ONE-WAY? No. The rollback restores the four open policies exactly; no row
-- changes either way. What cannot be undone is what was readable before.

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard.
-- ---------------------------------------------------------------------------
do $$
declare
  v_rec record;
  v_txt text;
  v_n int;
  v_ok boolean;
begin
  -- The four fingerprinted bodies, unchanged.
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

  -- The seven part 1 helpers.
  for v_rec in
    select * from (values
      ('public.is_table_member(uuid)'), ('public.is_current_spectator(uuid)'), ('public.is_admin()'),
      ('public.is_game_player(uuid)'), ('public.is_public_table(uuid)'), ('public.can_read_table(uuid)'),
      ('public.can_read_game(uuid)')
    ) as t(fn)
  loop
    select p.prosecdef
           and p.provolatile = 's'
           and coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']
           and has_function_privilege('authenticated', p.oid, 'EXECUTE')
           and not has_function_privilege('anon', p.oid, 'EXECUTE')
    into v_ok
    from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_ok is not true then
      raise exception 'STOP: % is missing or not security definer / stable / search_path '''' / EXECUTE for authenticated only. Run docs/sql/private-tables-part1.sql first. Nothing was changed.', v_rec.fn;
    end if;
  end loop;

  -- RLS on, not forced, where the helpers read as the owner.
  for v_rec in
    select * from (values ('tables'), ('table_members'), ('games'), ('game_plays'), ('table_spectators'), ('admin_users')) as t(tbl)
  loop
    select c.relrowsecurity and not c.relforcerowsecurity into v_ok
    from pg_class c where c.oid = to_regclass('public.' || v_rec.tbl);
    if v_ok is not true then
      raise exception 'STOP: public.% must have RLS enabled and NOT forced. Nothing was changed.', v_rec.tbl;
    end if;
  end loop;

  -- No client role calls the SECURITY INVOKER functions directly.
  for v_rec in
    select * from (values
      ('public._one_table_rule(uuid, uuid, boolean)'), ('public._pick_table_code(integer)'),
      ('public._solo_results()'), ('public.award_points(uuid, uuid, integer, text)'),
      ('public.deal_cards_for_game(uuid)'), ('public.has_legal_play(uuid, uuid, integer)'),
      ('public.table_host(uuid)')
    ) as t(fn)
  loop
    if to_regprocedure(v_rec.fn) is not null
       and (has_function_privilege('authenticated', to_regprocedure(v_rec.fn), 'EXECUTE')
            or has_function_privilege('anon', to_regprocedure(v_rec.fn), 'EXECUTE')) then
      raise exception 'STOP: a client role can EXECUTE % (security invoker): it would silently see fewer rows. Nothing was changed.', v_rec.fn;
    end if;
  end loop;

  -- The SELECT policies on the four tables: exactly the old open one (the
  -- live text), or exactly this file's (a re-run).
  for v_rec in
    select * from (values
      ('tables', 'Tables are viewable by any logged-in user', 'Public tables, or private ones the caller may read'),
      ('table_members', 'Table members are viewable by any logged-in user', 'Rosters of tables the caller may read'),
      ('games', 'Games are viewable by any logged-in user', 'Games the caller may read'),
      ('game_plays', 'Played cards are viewable by any logged-in user', 'Plays of games the caller may read')
    ) as t(tbl, old_name, new_name)
  loop
    select count(*) into v_n
    from pg_policies p
    where p.schemaname = 'public' and p.tablename = v_rec.tbl and p.cmd in ('SELECT', 'ALL');
    select exists (
             select 1 from pg_policies p
             where p.schemaname = 'public' and p.tablename = v_rec.tbl and p.policyname = v_rec.old_name
               and p.cmd = 'SELECT' and p.permissive = 'PERMISSIVE'
               and p.roles = array['public']::name[]
               and p.qual = '(auth.role() = ''authenticated''::text)'
               and p.with_check is null)
           or exists (
             select 1 from pg_policies p
             where p.schemaname = 'public' and p.tablename = v_rec.tbl and p.policyname = v_rec.new_name
               and p.cmd = 'SELECT')
    into v_ok;
    if v_n <> 1 or not v_ok then
      raise exception 'STOP: public.% has % SELECT/ALL policies; expected exactly "%" (to public, using (auth.role() = ''authenticated''::text)) or exactly "%". Nothing was changed.', v_rec.tbl, v_n, v_rec.old_name, v_rec.new_name;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The four old open SELECT policies.
-- ---------------------------------------------------------------------------
drop policy if exists "Tables are viewable by any logged-in user" on public.tables;
drop policy if exists "Table members are viewable by any logged-in user" on public.table_members;
drop policy if exists "Games are viewable by any logged-in user" on public.games;
drop policy if exists "Played cards are viewable by any logged-in user" on public.game_plays;

-- (A re-run replaces this file's own policies.)
drop policy if exists "Public tables, or private ones the caller may read" on public.tables;
drop policy if exists "Rosters of tables the caller may read" on public.table_members;
drop policy if exists "Games the caller may read" on public.games;
drop policy if exists "Plays of games the caller may read" on public.game_plays;

-- ---------------------------------------------------------------------------
-- 2. The new SELECT policies (to authenticated only).
-- ---------------------------------------------------------------------------

-- tables: a public table, or a private one the caller may read -- seated,
-- a current spectator, an admin, or a player of any game there.
create policy "Public tables, or private ones the caller may read"
  on public.tables
  for select
  to authenticated
  using (
    is_public
    or public.can_read_table(id)
  );

-- table_members: the roster of a table the caller may read (the same rule
-- as the table row).
create policy "Rosters of tables the caller may read"
  on public.table_members
  for select
  to authenticated
  using (
    public.can_read_table(table_id)
  );

-- games: a game at a public table; or at a table where the caller is seated,
-- a current spectator, or an admin; or a game the caller is a player of
-- (never another game of the same table).
create policy "Games the caller may read"
  on public.games
  for select
  to authenticated
  using (
    public.is_public_table(table_id)
    or public.is_table_member(table_id)
    or public.is_current_spectator(table_id)
    or (select public.is_admin())
    or (select auth.uid()) = any(players)
  );

-- game_plays: the plays of a game the caller may read (the games rule).
create policy "Plays of games the caller may read"
  on public.game_plays
  for select
  to authenticated
  using (
    public.can_read_game(game_id)
  );

commit;
