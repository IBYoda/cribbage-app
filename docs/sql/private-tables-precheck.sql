-- Step 3, slice D: PRIVATE TABLES. The PRE-CHECK (read-only). Run in the
-- Supabase Dashboard -> SQL Editor before docs/sql/private-tables-part1.sql,
-- AGAIN before docs/sql/private-tables-part2.sql, and any time after. It
-- reads only; it changes nothing: no writes, no DO block, no temp table, no
-- SET.
--
-- STATUS: written, NOT RUN yet.
--
-- RUN ORDER (slice D):
--   0. the app build with the by-id preview (components/table/TableView.tsx)
--      and the awaited spectator heartbeat is LIVE first, and old tabs have
--      reloaded (a deploy plus an hour).
--   1. docs/sql/private-tables-precheck.sql        (this file)
--   2. docs/sql/private-tables-part1.sql           (add-only helpers)
--   3. docs/sql/private-tables-precheck.sql again  (part 1 PRESENT, no STOP)
--   4. docs/sql/private-tables-part2.sql           (the policy swap)
--   5. docs/sql/private-tables-verification.sql    (rolled back; verdict)
--   If the swap has to come out: docs/sql/private-tables-part2-rollback.sql.
--
-- ONE query, so the editor shows every row in one grid. Columns: section,
-- item, value, note (all text). A note starting with STOP means: do not run
-- the next slice D file; paste the result back first. INFO rows are facts,
-- not blockers.
--
-- WHAT IT LOOKS FOR
--   fn       the four bodies slice D must NOT change, by the md5 of the LIVE
--            body (pg_proc.prosrc), LF or CRLF (as end-empty-tables-precheck):
--              leave_table             9c15b86bd236e9ffb108e9318251c5b8 / 3ad133b3e6308ad008237fa64bdb7cfa
--              end_timed_out_sessions  d46b95e2f27b93f2707d050de560720f / 7839dbdba9e2ff400430ed457743507c
--              assign_table_seat       5f2ea7a318c9f3a6dc7552f6bf7e0380 / ef28d7cadc8a1e0688d181b1af9c57bb
--              table_host              fca691d91d3aadf74972906e75019646 / 172b8403111f6b381e34eda706555f2d
--   select   the SELECT policies on tables, table_members, games, game_plays.
--            Before part 2: exactly the one old open policy on each,
--              "to public using ((auth.role() = 'authenticated'::text))":
--                tables         "Tables are viewable by any logged-in user"
--                table_members  "Table members are viewable by any logged-in user"
--                games          "Games are viewable by any logged-in user"
--                game_plays     "Played cards are viewable by any logged-in user"
--            After part 2: exactly part 2's one policy on each (to
--            authenticated). Anything else, or a different text: STOP.
--   other    the policies the swap leans on, by name: the two admin UPDATE
--            policies (tables, games), game_hands (3), game_cribs (3),
--            table_spectators (1). Missing: STOP.
--   rls      RLS enabled and NOT forced on tables, table_members, games,
--            game_plays, table_spectators, admin_users (the helpers read them
--            as the owner; FORCE would make them meet the policies -- 42P17).
--   owner    the role running this (it will own the helpers) owns those six
--            tables, or bypasses RLS: else the definer helpers would meet the
--            policies. STOP otherwise.
--   grant    authenticated and anon hold table-level SELECT on the four
--            tables (without it a client gets "permission denied" instead of
--            zero rows; anon gets zero rows from the new policies, which are
--            "to authenticated" only).
--   helper   the seven part 1 helpers: all absent (before part 1) or all
--            present as definer, stable, search_path '', EXECUTE for
--            authenticated only. Half there, or wrong: STOP.
--   invoker  the seven SECURITY INVOKER functions that mention these tables
--            (_one_table_rule, _pick_table_code, _solo_results, award_points,
--            deal_cards_for_game, has_legal_play, table_host): a client role
--            that can EXECUTE one directly would read it under the new
--            policies and silently see fewer rows -- STOP. Any OTHER invoker
--            function in public mentioning the four tables: STOP (unknown).
--   realtime the four tables and profiles in supabase_realtime; replica
--            identity (INFO: DELETE events carry the primary key only).
--   count    tables by (is_public, status); open private tables; current
--            spectators; open private tables with a live game (INFO).

with old_policies(o, tbl, name) as (
  values
    (1, 'tables', 'Tables are viewable by any logged-in user'),
    (2, 'table_members', 'Table members are viewable by any logged-in user'),
    (3, 'games', 'Games are viewable by any logged-in user'),
    (4, 'game_plays', 'Played cards are viewable by any logged-in user')
),
new_policies(o, tbl, name) as (
  values
    (1, 'tables', 'Public tables, or private ones the caller may read'),
    (2, 'table_members', 'Rosters of tables the caller may read'),
    (3, 'games', 'Games the caller may read'),
    (4, 'game_plays', 'Plays of games the caller may read')
),
helpers(o, sig) as (
  values
    (1, 'public.is_table_member(uuid)'),
    (2, 'public.is_current_spectator(uuid)'),
    (3, 'public.is_admin()'),
    (4, 'public.is_game_player(uuid)'),
    (5, 'public.is_public_table(uuid)'),
    (6, 'public.can_read_table(uuid)'),
    (7, 'public.can_read_game(uuid)')
),
helper_state as (
  select h.o, h.sig, p.oid,
         p.oid is not null
           and p.prosecdef
           and p.provolatile = 's'
           and coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']
           and has_function_privilege('authenticated', p.oid, 'EXECUTE')
           and not has_function_privilege('anon', p.oid, 'EXECUTE')
           and not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0)
           as ok
  from helpers h
  left join pg_proc p on p.oid = to_regprocedure(h.sig)
),
invokers(o, sig) as (
  values
    (1, 'public._one_table_rule(uuid, uuid, boolean)'),
    (2, 'public._pick_table_code(integer)'),
    (3, 'public._solo_results()'),
    (4, 'public.award_points(uuid, uuid, integer, text)'),
    (5, 'public.deal_cards_for_game(uuid)'),
    (6, 'public.has_legal_play(uuid, uuid, integer)'),
    (7, 'public.table_host(uuid)')
),
six_tables(o, relname) as (
  values (1, 'tables'), (2, 'table_members'), (3, 'games'), (4, 'game_plays'),
         (5, 'table_spectators'), (6, 'admin_users')
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== fn: the four bodies slice D must not change ============================
  select 1 as s, x.o as o, 'fn'::text as section, (x.fn || ': md5 of the live body')::text as item,
         coalesce((select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(x.sig)), '(missing)')::text as value,
         (case (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(x.sig))
              when x.lf then x.src || ' (LF): as expected'
              when x.crlf then x.src || ' (CRLF): as expected'
              else 'STOP: not ' || x.src || '''s text (or missing). Capture it first: select pg_get_functiondef(''' || x.sig || '''::regprocedure); and paste the result back'
         end)::text as note
  from (values
    (1, 'leave_table', 'public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa', 'phase2-slice-5-cut-before-deal.sql'),
    (2, 'end_timed_out_sessions', 'public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c', 'phase2-slice-5-cut-before-deal.sql'),
    (3, 'assign_table_seat', 'public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb', 'phase3-e1-seating.sql'),
    (4, 'table_host', 'public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d', 'phase3-e1-seating.sql')
  ) as x(o, fn, sig, lf, crlf, src)

  union all
  -- ==== select: the SELECT policies on the four tables =========================
  select 2, op.o, 'select', op.tbl || ': SELECT policies',
         coalesce((select string_agg(p.policyname::text || ' [' || array_to_string(p.roles, ',') || '] ' || coalesce(p.qual, '(no using)'),
                                     ' || ' order by p.policyname)
                   from pg_policies p
                   where p.schemaname = 'public' and p.tablename = op.tbl and p.cmd in ('SELECT', 'ALL')), '(none)'),
         case
           -- before part 2: exactly the old open policy, with the exact text
           when (select count(*) from pg_policies p
                 where p.schemaname = 'public' and p.tablename = op.tbl and p.cmd in ('SELECT', 'ALL')) = 1
                and exists (select 1 from pg_policies p
                            where p.schemaname = 'public' and p.tablename = op.tbl and p.policyname = op.name
                              and p.cmd = 'SELECT' and p.permissive = 'PERMISSIVE'
                              and p.roles = array['public']::name[]
                              and p.qual = '(auth.role() = ''authenticated''::text)'
                              and p.with_check is null)
             then 'before part 2: the old open policy, as expected'
           -- after part 2: exactly the new policy, to authenticated
           when (select count(*) from pg_policies p
                 where p.schemaname = 'public' and p.tablename = op.tbl and p.cmd in ('SELECT', 'ALL')) = 1
                and exists (select 1 from new_policies np join pg_policies p
                              on p.schemaname = 'public' and p.tablename = np.tbl and p.policyname = np.name
                            where np.tbl = op.tbl and p.cmd = 'SELECT' and p.permissive = 'PERMISSIVE'
                              and p.roles = array['authenticated']::name[])
             then 'after part 2: part 2''s policy (to authenticated), as expected'
           else 'STOP: not exactly "' || op.name || '" (to public, using (auth.role() = ''authenticated''::text)) nor exactly part 2''s policy. Paste this row back'
         end
  from old_policies op

  union all
  -- ==== other: the policies the swap leans on ==================================
  select 3, x.o, 'other', x.tbl || ': ' || x.name,
         case when exists (select 1 from pg_policies p
                           where p.schemaname = 'public' and p.tablename = x.tbl and p.policyname = x.name and p.cmd = x.cmd)
              then 'present (' || x.cmd || ')' else '(missing)' end,
         case when exists (select 1 from pg_policies p
                           where p.schemaname = 'public' and p.tablename = x.tbl and p.policyname = x.name and p.cmd = x.cmd)
              then x.why
              else 'STOP: the swap and the verification expect this policy' end
  from (values
    (1, 'tables', 'Admins can force-end tables', 'UPDATE', 'kept; an UPDATE also needs the row through SELECT: is_admin() in the new policy'),
    (2, 'games', 'Admins can force-end games', 'UPDATE', 'kept; an UPDATE also needs the row through SELECT: is_admin() in the new policy'),
    (3, 'game_hands', 'Players read their own hand, or a hand shown at their table', 'SELECT', 'kept; its subquery reads games and table_members under the caller''s new policies (a member still sees both)'),
    (4, 'game_hands', 'Players read every hand once pegging is over', 'SELECT', 'kept; reads games: the caller is in players, so the new games policy shows it'),
    (5, 'game_hands', 'Players of a won game read its hands', 'SELECT', 'kept; reads games: the caller is in players'),
    (6, 'game_cribs', 'Players at the table read a shown crib', 'SELECT', 'kept; reads games and table_members (a member still sees both)'),
    (7, 'game_cribs', 'Players read the crib once it is up for counting', 'SELECT', 'kept; reads games: the caller is in players'),
    (8, 'game_cribs', 'Players of a won game read its crib', 'SELECT', 'kept; reads games: the caller is in players'),
    (9, 'table_spectators', 'Table members and the spectator read spectator rows', 'SELECT', 'kept; reads table_members: the caller''s own seat stays visible to them')
  ) as x(o, tbl, name, cmd, why)

  union all
  select 3, 20, 'other', 'game_decks: policies',
         (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = 'game_decks')::text,
         case when (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = 'game_decks') = 0
              then 'none, as expected: nobody reads a deck (unchanged)'
              else 'STOP: game_decks has a policy; the deck must stay unreadable' end

  union all
  -- ==== rls: enabled, not forced ===============================================
  select 4, t.o, 'rls', t.relname,
         coalesce((select 'enabled ' || c.relrowsecurity::text || ', forced ' || c.relforcerowsecurity::text
                   from pg_class c where c.oid = to_regclass('public.' || t.relname)), '(missing)'),
         case when (select c.relrowsecurity and not c.relforcerowsecurity
                    from pg_class c where c.oid = to_regclass('public.' || t.relname))
              then 'as expected'
              else 'STOP: RLS must be enabled and NOT forced (the definer helpers read this table as its owner)' end
  from six_tables t

  union all
  -- ==== owner: the helpers' owner reads past the policies ======================
  select 5, 1, 'owner', 'current_user (will own the part 1 helpers)',
         current_user::text || ' | superuser ' || (select r.rolsuper::text from pg_roles r where r.rolname = current_user)
           || ', bypassrls ' || (select r.rolbypassrls::text from pg_roles r where r.rolname = current_user),
         case when (select r.rolsuper or r.rolbypassrls from pg_roles r where r.rolname = current_user)
                   or not exists (select 1 from six_tables t join pg_class c on c.oid = to_regclass('public.' || t.relname)
                                  where c.relowner <> (select r.oid from pg_roles r where r.rolname = current_user))
              then 'as expected: owns all six tables, or bypasses RLS'
              else 'STOP: run part 1 as the owner of tables, table_members, games, game_plays, table_spectators and admin_users (owners: '
                   || (select string_agg(t.relname || '=' || pg_get_userbyid(c.relowner)::text, ', ' order by t.o)
                       from six_tables t join pg_class c on c.oid = to_regclass('public.' || t.relname)) || ')' end

  union all
  -- ==== grant: SELECT for the client roles =====================================
  select 6, op.o, 'grant', op.tbl || ': SELECT for authenticated / anon',
         has_table_privilege('authenticated', 'public.' || op.tbl, 'SELECT')::text || ' / '
           || has_table_privilege('anon', 'public.' || op.tbl, 'SELECT')::text,
         case when not has_table_privilege('authenticated', 'public.' || op.tbl, 'SELECT')
              then 'STOP: authenticated has no SELECT; every client read is "permission denied"'
              when not has_table_privilege('anon', 'public.' || op.tbl, 'SELECT')
              then 'INFO: anon has no SELECT, so anon gets "permission denied" (as today), not zero rows; the verification''s anon check expects zero rows'
              else 'as expected (the new policies return zero rows to anon: they are to authenticated only)' end
  from old_policies op

  union all
  -- ==== helper: the seven part 1 helpers =======================================
  select 7, hs.o, 'helper', hs.sig,
         case when hs.oid is null then '(absent)'
              else (select case when p.prosecdef then 'definer' else 'invoker' end
                           || ' | ' || case p.provolatile when 'i' then 'immutable' when 's' then 'stable' else 'volatile' end
                           || ' | ' || coalesce(p.proconfig::text, 'no config')
                           || ' | authenticated ' || has_function_privilege('authenticated', p.oid, 'EXECUTE')::text
                           || ', anon ' || has_function_privilege('anon', p.oid, 'EXECUTE')::text
                    from pg_proc p where p.oid = hs.oid) end,
         case when (select count(*) from helper_state where oid is not null) = 0 then 'absent: part 1 not run yet (expected before part 1)'
              when (select count(*) from helper_state where oid is null) > 0 then 'STOP: part 1 is half there (some helpers missing); re-run docs/sql/private-tables-part1.sql'
              when hs.ok then 'part 1 present, as expected'
              else 'STOP: must be security definer, stable, search_path '''', EXECUTE for authenticated only' end
  from helper_state hs

  union all
  -- ==== invoker: functions under the caller's RLS ==============================
  select 8, iv.o, 'invoker', iv.sig,
         coalesce((select case when p.prosecdef then 'definer' else 'invoker' end
                          || ' | authenticated ' || has_function_privilege('authenticated', p.oid, 'EXECUTE')::text
                          || ', anon ' || has_function_privilege('anon', p.oid, 'EXECUTE')::text
                   from pg_proc p where p.oid = to_regprocedure(iv.sig)), '(missing)'),
         case when to_regprocedure(iv.sig) is null then 'INFO: not in this database'
              when has_function_privilege('authenticated', to_regprocedure(iv.sig), 'EXECUTE')
                   or has_function_privilege('anon', to_regprocedure(iv.sig), 'EXECUTE')
              then 'STOP: a client can call it directly and would silently see fewer rows under the new policies'
              else 'as expected: no client EXECUTE; only definer functions call it, and they read as their owner' end
  from invokers iv

  union all
  select 8, 20, 'invoker', 'other SECURITY INVOKER functions in public mentioning the four tables',
         coalesce((select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
                   from pg_proc p
                   join pg_namespace pns on pns.oid = p.pronamespace
                   join pg_language l on l.oid = p.prolang
                   where pns.nspname = 'public'
                     and p.prokind in ('f', 'p')
                     and not p.prosecdef
                     and l.lanname in ('sql', 'plpgsql')
                     and not exists (select 1 from pg_depend d
                                     where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
                     and p.prosrc ~* '\m(tables|table_members|games|game_plays)\M'
                     and p.oid not in (select to_regprocedure(iv.sig)::oid from invokers iv where to_regprocedure(iv.sig) is not null)), '(none)'),
         case when exists (select 1
                           from pg_proc p
                           join pg_namespace pns on pns.oid = p.pronamespace
                           join pg_language l on l.oid = p.prolang
                           where pns.nspname = 'public'
                             and p.prokind in ('f', 'p')
                             and not p.prosecdef
                             and l.lanname in ('sql', 'plpgsql')
                             and not exists (select 1 from pg_depend d
                                             where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
                             and p.prosrc ~* '\m(tables|table_members|games|game_plays)\M'
                             and p.oid not in (select to_regprocedure(iv.sig)::oid from invokers iv where to_regprocedure(iv.sig) is not null))
              then 'STOP: an invoker function the slice D review did not cover; paste this row back'
              else 'as expected (the catalog of 2026-11-24 listed exactly the seven above)' end

  union all
  -- ==== realtime ===============================================================
  select 9, x.o, 'realtime', x.tbl,
         case when exists (select 1 from pg_publication_tables pt
                           where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = x.tbl)
              then 'in supabase_realtime' else 'not published' end
           || ' | replica identity '
           || coalesce((select case c.relreplident when 'd' then 'default (primary key)' when 'f' then 'full'
                                                   when 'n' then 'nothing' when 'i' then 'index' else c.relreplident::text end
                        from pg_class c where c.oid = to_regclass('public.' || x.tbl)), '(missing)'),
         'INFO: postgres_changes applies the SELECT policy to INSERT / UPDATE events per subscriber; a DELETE event carries the primary key only'
  from (values (1, 'tables'), (2, 'table_members'), (3, 'games'), (4, 'game_plays'), (5, 'profiles')) as x(o, tbl)

  union all
  -- ==== count ==================================================================
  select 10, 1, 'count', 'tables with is_public = ' || x.p || ', status = ' || x.st, x.n, 'INFO'
  from (
    select coalesce(t.is_public::text, 'NULL') as p, coalesce(t.status, 'NULL') as st, count(*)::text as n
    from public.tables t
    group by t.is_public, t.status
  ) x

  union all
  select 10, 2, 'count', 'OPEN private tables: human / computer',
         (select count(*) filter (where t.computer_level is null)::text
                 || ' / ' || count(*) filter (where t.computer_level is not null)::text
          from public.tables t where t.status = 'open' and not t.is_public),
         'INFO: their players keep reading them (seated); everyone else stops'

  union all
  select 10, 3, 'count', 'current spectators (removed_at null, last_seen_at within 90 s): all / at private tables',
         (select count(*)::text || ' / ' || count(*) filter (where not t.is_public)::text
          from public.table_spectators sp
          join public.tables t on t.id = sp.table_id
          where sp.removed_at is null and sp.last_seen_at > now() - interval '90 seconds'),
         'INFO: they keep reading while their heartbeat keeps them current'

  union all
  select 10, 4, 'count', 'OPEN private tables with a live game (cutting / active)',
         (select count(distinct t.id)::text
          from public.tables t
          join public.games g on g.table_id = t.id and g.status in ('cutting', 'active')
          where t.status = 'open' and not t.is_public),
         'INFO'
) z
order by z.s, z.o, z.item;
