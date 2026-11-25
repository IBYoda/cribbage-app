-- Step 3, slice D: PRIVATE TABLES. The CATALOG (read-only). Run in the
-- Supabase Dashboard -> SQL Editor. It reads only; it changes nothing: no
-- writes, no DO block, no temp table, no SET. Safe to run any time, as often
-- as you like.
--
-- STATUS: written, NOT RUN yet.
--
-- WHY: slice D's policy swap must be written against what is LIVE, not
-- against the committed files (the lesson of create_computer_table: the live
-- text can differ). Walt's rules: public tables stay readable as today;
-- private tables (is_public = false) become readable only by seated players,
-- current spectators, anyone in games.players for that game (forever), and
-- admins (everything). This file does NOT design or apply that swap; it only
-- reports the ground it will stand on. Paste the whole result back.
--
-- HOW TO RUN: paste the whole file into the SQL Editor and press Run, as the
-- dashboard's default role (it reads public.tables and friends directly, and
-- the catalogs). ONE statement, so the editor shows every row in one grid.
-- Columns: section, item, value, note (all text), ordered so related rows
-- sit together. A note starting with STOP means: do not go on to the next
-- slice D file; paste the result back first.
--
-- WHAT EACH SECTION RETURNS
--   1 rls       per table: RLS enabled / forced (relrowsecurity,
--               relforcerowsecurity), or "(table missing)".
--   2 policy    every pg_policies row on those tables: cmd, roles,
--               permissive, and the full CREATE POLICY text rebuilt from
--               qual / with_check. A table with no policy gets one
--               "(no policies)" row.
--   3 grant     table-level privileges (aclexplode of relacl, or the
--               default ACL when relacl is null) for anon, authenticated,
--               service_role and PUBLIC; then every column-level grant, and
--               a count of columns that have one.
--   4 realtime  whether the supabase_realtime publication exists, and per
--               table: published or not, and its REPLICA IDENTITY.
--   5 count     tables by (is_public, status); open tables by public/private
--               and human/computer; allow_spectators true (all / open);
--               current spectators (removed_at null, last_seen_at within 90
--               seconds), all and at private tables; open tables with no
--               human seat.
--   6 fn        the four fingerprinted bodies slice D must NOT change, by the
--               md5 of the LIVE body (pg_proc.prosrc), LF and CRLF, taken
--               from docs/sql/end-empty-tables-precheck.sql:
--                 leave_table             9c15b86bd236e9ffb108e9318251c5b8 (LF)
--                                         3ad133b3e6308ad008237fa64bdb7cfa (CRLF)
--                 end_timed_out_sessions  d46b95e2f27b93f2707d050de560720f (LF)
--                                         7839dbdba9e2ff400430ed457743507c (CRLF)
--                 assign_table_seat       5f2ea7a318c9f3a6dc7552f6bf7e0380 (LF)
--                                         ef28d7cadc8a1e0688d181b1af9c57bb (CRLF)
--                 table_host              fca691d91d3aadf74972906e75019646 (LF)
--                                         172b8403111f6b381e34eda706555f2d (CRLF)
--               plus each one's definer/invoker, volatility and config.
--      helper   is_table_member, is_current_spectator, is_admin,
--               chat_topic_allows: every overload (arguments, definer or
--               invoker, volatility, owner), or "(absent)".
--   7 invoker   every other SQL / plpgsql function in public that is
--               SECURITY INVOKER and whose body mentions tables,
--               table_members, games or game_plays (a text match on the
--               body: a mention in a comment counts too). These run under
--               the caller's RLS, so the swap changes what they see.
--               Extension-owned functions are left out.
--   8 view      every view or materialized view (any schema) that selects
--               from tables, table_members, games or game_plays, or "(none)".

with our_tables(o, relname) as (
  values
    (1, 'tables'), (2, 'table_members'), (3, 'games'), (4, 'game_plays'),
    (5, 'game_hands'), (6, 'game_cribs'), (7, 'game_decks'), (8, 'table_spectators'),
    (9, 'profiles'), (10, 'game_results'), (11, 'attempt_log'), (12, 'leaderboard_hidden'),
    (13, 'admin_users'), (14, 'computer_accounts'), (15, 'follows')
),
rels as (
  select ot.o, ot.relname, c.oid, c.relowner, c.relacl,
         c.relrowsecurity, c.relforcerowsecurity, c.relreplident
  from our_tables ot
  left join pg_class c on c.oid = to_regclass('public.' || ot.relname)
),
client_roles(o, rolname) as (
  values (1, 'anon'), (2, 'authenticated'), (3, 'service_role'), (4, 'PUBLIC')
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== 1. RLS enabled / forced =================================================
  select 1 as s, r.o as o, ''::text as k, 'rls'::text as section, r.relname::text as item,
         case when r.oid is null then '(table missing)'
              else 'enabled ' || r.relrowsecurity::text || ', forced ' || r.relforcerowsecurity::text
         end::text as value,
         case when r.oid is null then 'not in this database'
              when not r.relrowsecurity then 'RLS OFF: every row is readable by any role with a grant'
              else ''
         end::text as note
  from rels r

  union all
  -- ==== 2. Policies ==============================================================
  select 2, r.o, p.policyname::text, 'policy',
         r.relname || ': ' || p.policyname::text,
         p.cmd || ' | to ' || array_to_string(p.roles, ', ') || ' | ' || lower(p.permissive),
         'create policy ' || quote_ident(p.policyname::text) || ' on public.' || quote_ident(r.relname)
           || ' as ' || lower(p.permissive) || ' for ' || lower(p.cmd)
           || ' to ' || array_to_string(p.roles, ', ')
           || coalesce(' using (' || p.qual || ')', '')
           || coalesce(' with check (' || p.with_check || ')', '')
  from rels r
  join pg_policies p on p.schemaname = 'public' and p.tablename = r.relname

  union all
  select 2, r.o, '', 'policy', r.relname || ': (no policies)', '0',
         case when r.relrowsecurity then 'RLS on and no policy: no client role reads or writes (definer functions only)'
              else 'RLS off: policies do not apply' end
  from rels r
  where r.oid is not null
    and not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = r.relname)

  union all
  -- ==== 3. Grants: table level ================================================
  select 3, r.o, g.o::text, 'grant', r.relname || ': ' || g.rolname,
         coalesce((select string_agg(a.privilege_type, ', ' order by a.privilege_type)
                   from aclexplode(coalesce(r.relacl, acldefault('r', r.relowner))) a
                   where a.grantee = case when g.rolname = 'PUBLIC' then 0::oid
                                          else (select ro.oid from pg_roles ro where ro.rolname = g.rolname) end),
                  '(none)'),
         case when r.relacl is null then 'table level; relacl is null, so this is the owner''s default ACL'
              else 'table level (SELECT / INSERT / UPDATE / DELETE / TRUNCATE / REFERENCES / TRIGGER as granted)' end
  from rels r
  cross join client_roles g
  where r.oid is not null

  union all
  -- ==== 3. Grants: column level ===============================================
  select 3, r.o, 'zcol ' || att.attname::text, 'grant',
         r.relname || '.' || att.attname::text || ': column grants',
         coalesce((select string_agg(case a.grantee when 0 then 'PUBLIC' else pg_get_userbyid(a.grantee)::text end
                                     || ' ' || a.privilege_type,
                                     ', ' order by a.grantee, a.privilege_type)
                   from aclexplode(att.attacl) a), '(empty acl)'),
         'column level'
  from rels r
  join pg_attribute att on att.attrelid = r.oid and att.attnum > 0 and not att.attisdropped and att.attacl is not null

  union all
  select 3, 99, '', 'grant', 'columns with a column-level grant (all tables above)',
         (select count(*) from rels r
          join pg_attribute att on att.attrelid = r.oid and att.attnum > 0 and not att.attisdropped and att.attacl is not null)::text,
         'each one is listed above as "<table>.<column>: column grants"'

  union all
  -- ==== 4. Realtime publication and replica identity =========================
  select 4, 0, '', 'realtime', 'supabase_realtime publication',
         case when exists (select 1 from pg_publication pb where pb.pubname = 'supabase_realtime')
              then 'exists' else '(missing)' end,
         coalesce((select 'puballtables ' || pb.puballtables::text || ', insert ' || pb.pubinsert::text
                          || ', update ' || pb.pubupdate::text || ', delete ' || pb.pubdelete::text
                   from pg_publication pb where pb.pubname = 'supabase_realtime'), '')

  union all
  select 4, r.o, '', 'realtime', r.relname,
         case when exists (select 1 from pg_publication_tables pt
                           where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = r.relname)
              then 'in supabase_realtime' else 'not published' end,
         'replica identity ' || case r.relreplident when 'd' then 'default (primary key)' when 'f' then 'full'
                                                    when 'n' then 'nothing' when 'i' then 'index'
                                                    else coalesce(r.relreplident::text, '?') end
  from rels r
  where r.oid is not null

  union all
  -- ==== 5. Counts =================================================================
  select 5, 1, x.k, 'count', 'tables with is_public = ' || x.p || ', status = ' || x.st, x.n, ''
  from (
    select coalesce(t.is_public::text, 'NULL') as p, coalesce(t.status, 'NULL') as st, count(*)::text as n,
           coalesce(t.is_public::text, 'NULL') || ' ' || coalesce(t.status, 'NULL') as k
    from public.tables t
    group by t.is_public, t.status
  ) x

  union all
  select 5, 2, '', 'count', 'OPEN tables: public human / public computer / private human / private computer',
         (select count(*) filter (where t.is_public and t.computer_level is null)::text
                 || ' / ' || count(*) filter (where t.is_public and t.computer_level is not null)::text
                 || ' / ' || count(*) filter (where not t.is_public and t.computer_level is null)::text
                 || ' / ' || count(*) filter (where not t.is_public and t.computer_level is not null)::text
          from public.tables t where t.status = 'open'),
         'private (is_public = false) is the default, so most tables are private'

  union all
  select 5, 3, '', 'count', 'tables with allow_spectators = true: all / open',
         (select count(*) filter (where t.allow_spectators)::text
                 || ' / ' || count(*) filter (where t.allow_spectators and t.status = 'open')::text
          from public.tables t),
         ''

  union all
  select 5, 4, '', 'count', 'current spectators (removed_at null, last_seen_at within 90 s): all / at private tables',
         (select count(*)::text
                 || ' / ' || count(*) filter (where not t.is_public)::text
          from public.table_spectators sp
          join public.tables t on t.id = sp.table_id
          where sp.removed_at is null
            and sp.last_seen_at > now() - interval '90 seconds'),
         'the "current spectator" rule slice D would read through'

  union all
  select 5, 5, '', 'count', 'open tables with no human seat: all / older than 10 minutes',
         (select count(*)::text
                 || ' / ' || count(*) filter (where t.created_at < now() - interval '10 minutes')::text
          from public.tables t
          where t.status = 'open'
            and not exists (select 1 from public.table_members tm
                            where tm.table_id = t.id
                              and not exists (select 1 from public.computer_accounts ca where ca.user_id = tm.user_id))),
         'slice C''s end_empty_tables() sweep ends the older ones every 5 minutes'

  union all
  -- ==== 6. The four fingerprinted bodies ======================================
  select 6, x.o, '', 'fn', x.fn || ': md5 of the live body',
         coalesce((select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(x.sig)), '(missing)'),
         case (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(x.sig))
              when x.lf then x.src || ' (LF): as expected'
              when x.crlf then x.src || ' (CRLF): as expected'
              else 'STOP: not ' || x.src || '''s text (or missing). Capture it first: select pg_get_functiondef(''' || x.sig || '''::regprocedure); and paste the result back'
         end
  from (values
    (1, 'leave_table', 'public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa', 'phase2-slice-5-cut-before-deal.sql'),
    (2, 'end_timed_out_sessions', 'public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c', 'phase2-slice-5-cut-before-deal.sql'),
    (3, 'assign_table_seat', 'public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb', 'phase3-e1-seating.sql'),
    (4, 'table_host', 'public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d', 'phase3-e1-seating.sql')
  ) as x(o, fn, sig, lf, crlf, src)

  union all
  select 6, 4 + x.o, '', 'fn', x.fn || ': security, volatility, config',
         coalesce((select case when p.prosecdef then 'definer' else 'invoker' end
                          || ' | ' || case p.provolatile when 'i' then 'immutable' when 's' then 'stable' else 'volatile' end
                          || ' | ' || coalesce(p.proconfig::text, 'no config')
                          || ' | owner ' || pg_get_userbyid(p.proowner)::text
                   from pg_proc p where p.oid = to_regprocedure(x.sig)), '(missing)'),
         x.expect
  from (values
    (1, 'leave_table', 'public.leave_table(uuid)', 'expected definer: RLS does not apply inside it'),
    (2, 'end_timed_out_sessions', 'public.end_timed_out_sessions()', 'expected definer: RLS does not apply inside it'),
    (3, 'assign_table_seat', 'public.assign_table_seat()', 'expected definer (the seat trigger): RLS does not apply inside it'),
    (4, 'table_host', 'public.table_host(uuid)', 'expected INVOKER: it reads under the caller''s RLS when a client calls it directly; inside definer functions it runs as their owner')
  ) as x(o, fn, sig, expect)

  union all
  -- ==== 6. Helper names slice D may add (or that exist) ======================
  select 6, 10 + h.o, coalesce(pg_get_function_identity_arguments(p.oid), ''), 'helper',
         h.n || '(' || coalesce(pg_get_function_identity_arguments(p.oid), '') || ')',
         case when p.oid is null then '(absent)'
              else (case when p.prosecdef then 'definer' else 'invoker' end)
                   || ' | ' || case p.provolatile when 'i' then 'immutable' when 's' then 'stable' else 'volatile' end
                   || ' | owner ' || pg_get_userbyid(p.proowner)::text
         end,
         case when h.n = 'chat_topic_allows' then 'expected present: definer, stable (table-chat.sql)'
              when p.oid is null then 'not there yet'
              else 'ALREADY EXISTS: slice D must reuse or replace it knowingly' end
  from (values (1, 'is_table_member'), (2, 'is_current_spectator'), (3, 'is_admin'), (4, 'chat_topic_allows')) as h(o, n)
  left join (pg_proc p join pg_namespace pns on pns.oid = p.pronamespace and pns.nspname = 'public')
    on p.proname = h.n

  union all
  -- ==== 7. Other SECURITY INVOKER functions that read the four tables ========
  select 7, 1, p.proname::text || '(' || pg_get_function_identity_arguments(p.oid) || ')', 'invoker',
         p.proname::text || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         l.lanname::text || ' | ' || case p.provolatile when 'i' then 'immutable' when 's' then 'stable' else 'volatile' end
           || ' | owner ' || pg_get_userbyid(p.proowner)::text,
         'body mentions: ' || concat_ws(', ',
           case when p.prosrc ~* '\mtables\M' then 'tables' end,
           case when p.prosrc ~* '\mtable_members\M' then 'table_members' end,
           case when p.prosrc ~* '\mgames\M' then 'games' end,
           case when p.prosrc ~* '\mgame_plays\M' then 'game_plays' end)
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

  union all
  select 7, 2, '', 'invoker', '(none)', '', 'no SECURITY INVOKER function in public mentions the four tables'
  where not exists (
    select 1
    from pg_proc p
    join pg_namespace pns on pns.oid = p.pronamespace
    join pg_language l on l.oid = p.prolang
    where pns.nspname = 'public'
      and p.prokind in ('f', 'p')
      and not p.prosecdef
      and l.lanname in ('sql', 'plpgsql')
      and not exists (select 1 from pg_depend d
                      where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
      and p.prosrc ~* '\m(tables|table_members|games|game_plays)\M')

  union all
  -- ==== 8. Views and materialized views over the four tables ================
  select 8, 1, vns.nspname::text || '.' || v.relname::text, 'view',
         vns.nspname::text || '.' || v.relname::text,
         case v.relkind when 'v' then 'view' else 'materialized view' end,
         'selects from: ' || string_agg(distinct t.relname::text, ', ')
  from pg_class v
  join pg_namespace vns on vns.oid = v.relnamespace
  join pg_rewrite rw on rw.ev_class = v.oid
  join pg_depend d on d.classid = 'pg_rewrite'::regclass and d.objid = rw.oid and d.refclassid = 'pg_class'::regclass
  join pg_class t on t.oid = d.refobjid
  where v.relkind in ('v', 'm')
    and t.oid <> v.oid
    and t.oid in (select r.oid from rels r where r.o <= 4 and r.oid is not null)
  group by vns.nspname, v.relname, v.relkind

  union all
  select 8, 2, '', 'view', '(none)', '', 'no view or materialized view selects from tables, table_members, games or game_plays'
  where not exists (
    select 1
    from pg_class v
    join pg_rewrite rw on rw.ev_class = v.oid
    join pg_depend d on d.classid = 'pg_rewrite'::regclass and d.objid = rw.oid and d.refclassid = 'pg_class'::regclass
    where v.relkind in ('v', 'm')
      and d.refobjid <> v.oid
      and d.refobjid in (select r.oid from rels r where r.o <= 4 and r.oid is not null))
) z
order by z.s, z.o, z.k, z.item;
