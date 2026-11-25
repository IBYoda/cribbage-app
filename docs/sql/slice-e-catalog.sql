-- Step 3, slice E: RATE LIMITS, ATTEMPT_LOG CLEANUP, GRANTS HARDENING.
-- The CATALOG (read-only). Run in the Supabase Dashboard -> SQL Editor. It
-- reads only; it changes nothing: no writes, no DO block, no temp table, no
-- SET. Safe to run any time, as often as you like.
--
-- STATUS: written, NOT RUN yet.
--
-- WHY: slice E's build (a cap of 30 games started per hour, the 7-day
-- nickname lock, follow/unfollow churn at 30 an hour, the hourly attempt_log
-- cleanup keeping 7 days, fixed avatar file names, revoking the unused broad
-- table privileges, closing anon/PUBLIC EXECUTE on functions) must be written
-- against what is LIVE, not against the committed files. This file only
-- reports; paste the whole result back.
--
-- HOW TO RUN: paste the whole file into the SQL Editor and press Run, as the
-- dashboard's default role. ONE statement, so the editor shows every row in
-- one grid. Columns: section, item, value, note (all text), ordered so
-- related rows sit together. A note starting with STOP means: paste this
-- back before the next slice E file. FLAG marks what slice E is meant to
-- change (expected today, not a blocker). pg_cron is read through
-- query_to_xml, so this still parses where pg_cron is missing; the storage
-- schema and the step 3 tables are read directly (they exist on this project).
--
-- WHAT EACH SECTION RETURNS
--   01 table      every relation in public (tables, partitions, views,
--                 materialized views, foreign tables): table-level privileges
--                 of anon, authenticated, service_role and PUBLIC (aclexplode
--                 of relacl, or the owner's default ACL where it is null);
--                 FLAG where anon or authenticated holds more than SELECT.
--      column    every column-level grant on those relations.
--   02 function  every function and procedure in public (extension-owned
--                ones left out): name(args), definer/invoker, volatility,
--                owner, search_path, and EXECUTE for anon, authenticated,
--                PUBLIC (grantee 0 in proacl or the default ACL) and
--                service_role. Anything executable by anon or PUBLIC sorts
--                first, with a FLAG note. Then a count row.
--   03 default    every pg_default_acl row: role, schema, object type, ACL --
--                what future tables, sequences and functions get.
--   04 attempt   attempt_log: rows, oldest / newest created_at, rows per
--                action, total size, the action check constraint, indexes.
--   05 storage   the avatars bucket (public, file_size_limit,
--                allowed_mime_types); every storage.objects policy that
--                mentions avatars (full text); the number of objects; the 5
--                owner folders with the most objects (the folder name
--                replaced by the first 8 characters of its md5 -- no ids, no
--                file names), each with its count and total bytes.
--   06 profiles  profiles and user_appearance: columns, constraints, indexes,
--                triggers (timing, event, function) with the live definition
--                of each trigger function, and policies.
--   07 follows   follows' constraints, indexes and triggers; follow_user,
--                unfollow_user and _follow_user_as: signature, md5 of the live
--                body, and where the cap of 50 is enforced.
--   08 cron      every pg_cron job: jobid, jobname, schedule, active, command.
--   09 fp        fingerprints. The four bodies slice E must not change
--                (leave_table, end_timed_out_sessions, assign_table_seat,
--                table_host: md5 of the live body against the LF and CRLF
--                values). The game-start functions and every other function
--                docs/sql/computer-c1-verification.sql hashes: its eight
--                wrappers and their eight _as functions, hashed the way C1
--                hashes them (md5 of the body with carriage returns removed)
--                against C1's expected values. STOP on a mismatch.
--                computer_start_game_with_deal (no expected value: INFO) and
--                computer_start_game_with_deal_as (expected NOT to exist: the
--                computer's start goes through start_game_with_deal_as).
--   10 size      rows and total size of games, game_plays, game_hands,
--                game_cribs, game_decks, game_results, table_spectators,
--                follows, profiles, tables, table_members; and the Postgres
--                version (MAINTAIN exists from 17, server_version_num 170000).

with client_roles(o, rolname) as (
  values (1, 'anon'), (2, 'authenticated'), (3, 'service_role'), (4, 'PUBLIC')
),
rels as (
  select c.oid, c.relname::text as relname, c.relkind, c.relowner, c.relacl
  from pg_class c
  join pg_namespace ns on ns.oid = c.relnamespace
  where ns.nspname = 'public'
    and c.relkind in ('r', 'p', 'v', 'm', 'f')
    and not exists (select 1 from pg_depend d
                    where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e')
),
rel_privs as (
  select r.oid, r.relname, r.relkind, g.o as role_o, g.rolname,
         coalesce((select string_agg(a.privilege_type, ', ' order by a.privilege_type)
                   from aclexplode(coalesce(r.relacl, acldefault('r', r.relowner))) a
                   where a.grantee = case when g.rolname = 'PUBLIC' then 0::oid
                                          else (select ro.oid from pg_roles ro where ro.rolname = g.rolname) end),
                  '') as privs
  from rels r
  cross join client_roles g
),
fns as (
  select p.oid,
         p.oid::regprocedure::text as sig,
         p.prosecdef,
         p.provolatile,
         p.prokind,
         pg_get_userbyid(p.proowner)::text as owner,
         coalesce(array_to_string(p.proconfig, ' '), 'no config') as config,
         has_function_privilege('anon', p.oid, 'EXECUTE') as anon_x,
         has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_x,
         exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) as public_x,
         case when exists (select 1 from pg_roles ro where ro.rolname = 'service_role')
              then has_function_privilege('service_role', p.oid, 'EXECUTE') end as service_x,
         coalesce(p.proacl::text, '(null: default ACL)') as acl
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.prokind in ('f', 'p')
    and not exists (select 1 from pg_depend d
                    where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
),
c1_fp(o, fn, sig, as_sig, as_md5, wrap_md5) as (
  values
    (1, 'start_game_with_deal', 'uuid', 'uuid, uuid', '8d6ceb9ba00b9f2b6b9b8613e10609df', 'f7df18aedee7d95216674a7687c405a0'),
    (2, 'draw_cut_card', 'uuid', 'uuid, uuid', 'e52f927759d991e13b55a6fa73d39781', '0edacf243b6383d9a6977fedb4bd8392'),
    (3, 'acknowledge_deal_cut', 'uuid', 'uuid, uuid', '1e6e9b06a58d59628ca8b4ae19e6605d', '3ca1514190fa9f57ebd1b78166c26f52'),
    (4, 'discard_to_crib', 'uuid, text[]', 'uuid, uuid, text[]', 'fe4d1bb43ee5d4c38dacac502a8817ab', '325b1a01178582eba9a55d8117db0803'),
    (5, 'play_card', 'uuid, text', 'uuid, uuid, text', '39f2602ae2d547799f722ce434328b1c', 'b0434ffb08c301676a3d25722feba168'),
    (6, 'show_crib', 'uuid', 'uuid, uuid', '46ff0cf6834ba0afae2178a6fc895da5', '17821982fea29ef642fefa6a8d63c711'),
    (7, 'confirm_count', 'uuid, int', 'uuid, uuid, int', '27d9a04b7810746bce691f01ec8feffa', '1d5baa992851570fae14dfcf5fda2853'),
    (8, 'next_hand', 'uuid, int', 'uuid, uuid, int', 'e08be4b22774ad656feed6b3852e0562', '692a77e35e328d7c83ad5de4af69fa51')
),
size_tables(o, relname) as (
  values (1, 'games'), (2, 'game_plays'), (3, 'game_hands'), (4, 'game_cribs'), (5, 'game_decks'),
         (6, 'game_results'), (7, 'table_spectators'), (8, 'follows'), (9, 'profiles'), (10, 'tables'),
         (11, 'table_members')
),
avatar_objects as (
  select o.name, coalesce((o.metadata ->> 'size')::bigint, 0) as bytes
  from storage.objects o
  where o.bucket_id = 'avatars'
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== 01. Table privileges =====================================================
  select 1 as s, 0 as o, rp.relname as k, rp.role_o as k2, 'table'::text as section,
         (rp.relname || ' (' || case rp.relkind when 'r' then 'table' when 'p' then 'partitioned' when 'v' then 'view'
                                                when 'm' then 'matview' else 'foreign' end || '): ' || rp.rolname)::text as item,
         coalesce(nullif(rp.privs, ''), '(none)')::text as value,
         (case when rp.rolname in ('anon', 'authenticated')
                    and rp.privs ~ '(INSERT|UPDATE|DELETE|TRUNCATE|REFERENCES|TRIGGER|MAINTAIN)'
               then 'FLAG: ' || rp.rolname || ' holds more than SELECT'
               else '' end)::text as note
  from rel_privs rp

  union all
  select 1, 1, r.relname, 99, 'column',
         r.relname || '.' || att.attname::text || ': column grants',
         coalesce((select string_agg(case a.grantee when 0 then 'PUBLIC' else pg_get_userbyid(a.grantee)::text end
                                     || ' ' || a.privilege_type, ', ' order by a.grantee, a.privilege_type)
                   from aclexplode(att.attacl) a), '(empty acl)'),
         'column level'
  from rels r
  join pg_attribute att on att.attrelid = r.oid and att.attnum > 0 and not att.attisdropped and att.attacl is not null

  union all
  select 1, 2, 'zz', 0, 'column', 'columns with a column-level grant (all relations above)',
         (select count(*) from rels r
          join pg_attribute att on att.attrelid = r.oid and att.attnum > 0 and not att.attisdropped and att.attacl is not null)::text,
         'each one is listed above as "<relation>.<column>: column grants"'

  union all
  -- ==== 02. Function EXECUTE ======================================================
  select 2, case when f.anon_x or f.public_x then 0 else 1 end, f.sig, 0, 'function',
         f.sig,
         case when f.prosecdef then 'definer' else 'invoker' end
           || ' | ' || case f.provolatile when 'i' then 'immutable' when 's' then 'stable' else 'volatile' end
           || case when f.prokind = 'p' then ' | procedure' else '' end
           || ' | owner ' || f.owner
           || ' | ' || f.config
           || ' | anon ' || f.anon_x::text
           || ', authenticated ' || f.auth_x::text
           || ', PUBLIC ' || f.public_x::text
           || ', service_role ' || coalesce(f.service_x::text, 'no role')
           || ' | acl ' || f.acl,
         case when f.public_x then 'FLAG: ' || f.sig || ' is executable by PUBLIC (so by anon and authenticated)'
              when f.anon_x then 'FLAG: ' || f.sig || ' is executable by anon'
              else '' end
  from fns f

  union all
  select 2, 2, 'zz', 0, 'function', 'COUNT: total / by anon / by PUBLIC / by authenticated only / by nobody of anon, authenticated, PUBLIC',
         (select count(*)::text
                 || ' / ' || count(*) filter (where f.anon_x)::text
                 || ' / ' || count(*) filter (where f.public_x)::text
                 || ' / ' || count(*) filter (where f.auth_x and not f.anon_x and not f.public_x)::text
                 || ' / ' || count(*) filter (where not f.auth_x and not f.anon_x and not f.public_x)::text
          from fns f),
         'anon counts PUBLIC grants too (has_function_privilege)'

  union all
  -- ==== 03. Default privileges ====================================================
  select 3, 0, da.defaclrole::regrole::text || ' ' || da.defaclobjtype::text || ' ' || coalesce(dns.nspname::text, '(all schemas)'), 0,
         'default',
         'role ' || da.defaclrole::regrole::text || ', schema ' || coalesce(dns.nspname::text, '(all schemas)')
           || ', for ' || case da.defaclobjtype when 'r' then 'tables' when 'S' then 'sequences' when 'f' then 'functions'
                                                when 'T' then 'types' when 'n' then 'schemas' else da.defaclobjtype::text end,
         coalesce(da.defaclacl::text, '(null)'),
         'what objects this role creates there get, on top of the built-in defaults'
  from pg_default_acl da
  left join pg_namespace dns on dns.oid = da.defaclnamespace

  union all
  select 3, 1, 'zz', 0, 'default', 'pg_default_acl rows', (select count(*) from pg_default_acl)::text, ''

  union all
  -- ==== 04. attempt_log ===========================================================
  select 4, 0, '', 0, 'attempt', 'attempt_log rows / oldest / newest',
         case when to_regclass('public.attempt_log') is null then '(missing)'
              else (select count(*)::text || ' / ' || coalesce(min(a.created_at)::text, '-') || ' / ' || coalesce(max(a.created_at)::text, '-')
                    from public.attempt_log a) end,
         case when to_regclass('public.attempt_log') is null then 'STOP: attempt_log is missing' else '' end

  union all
  select 4, 1, x.action, 0, 'attempt', 'attempt_log rows: action ' || x.action || ', success ' || x.success::text,
         x.n::text || ' (oldest ' || x.oldest::text || ')', ''
  from (select a.action, a.success, count(*) as n, min(a.created_at) as oldest
        from public.attempt_log a group by a.action, a.success) x

  union all
  select 4, 2, '', 0, 'attempt', 'attempt_log total size (table + indexes + toast)',
         pg_size_pretty(pg_total_relation_size('public.attempt_log'::regclass)) || ' (' || pg_total_relation_size('public.attempt_log'::regclass)::text || ' bytes)',
         ''

  union all
  select 4, 3, con.conname::text, 0, 'attempt', 'attempt_log constraint ' || con.conname::text,
         pg_get_constraintdef(con.oid),
         case when con.contype = 'c' then 'the action names that exist; a new limit needs its name added here' else '' end
  from pg_constraint con
  where con.conrelid = 'public.attempt_log'::regclass

  union all
  select 4, 4, i.indexname::text, 0, 'attempt', 'attempt_log index ' || i.indexname::text, i.indexdef, ''
  from pg_indexes i
  where i.schemaname = 'public' and i.tablename = 'attempt_log'

  union all
  -- ==== 05. Storage: the avatars bucket ===========================================
  select 5, 0, '', 0, 'storage', 'bucket avatars',
         coalesce((select 'public ' || b.public::text || ' | file_size_limit ' || coalesce(b.file_size_limit::text, 'none')
                          || ' | allowed_mime_types ' || coalesce(b.allowed_mime_types::text, 'any')
                   from storage.buckets b where b.id = 'avatars'), '(missing)'),
         'public true: every object URL is readable by anyone, signed in or not'

  union all
  select 5, 1, p.policyname::text, 0, 'storage', 'storage.objects policy: ' || p.policyname::text,
         p.cmd || ' | to ' || array_to_string(p.roles, ', ') || ' | ' || lower(p.permissive),
         'create policy ' || quote_ident(p.policyname::text) || ' on storage.objects as ' || lower(p.permissive)
           || ' for ' || lower(p.cmd) || ' to ' || array_to_string(p.roles, ', ')
           || coalesce(' using (' || p.qual || ')', '')
           || coalesce(' with check (' || p.with_check || ')', '')
  from pg_policies p
  where p.schemaname = 'storage' and p.tablename = 'objects'
    and (coalesce(p.qual, '') ilike '%avatars%' or coalesce(p.with_check, '') ilike '%avatars%')

  union all
  select 5, 2, '', 0, 'storage', 'avatars objects: count / total bytes / owner folders',
         (select count(*)::text || ' / ' || coalesce(sum(ao.bytes), 0)::text || ' / '
                 || count(distinct (storage.foldername(ao.name))[1])::text
          from avatar_objects ao),
         'the app writes "<user id>/avatar.<ext>": more objects than folders means extra file names'

  union all
  select 5, 3, lpad(x.rn::text, 2, '0'), 0, 'storage',
         'avatars folder #' || x.rn::text || ' (md5 ' || x.folder_hash || ')',
         x.n::text || ' object(s), ' || x.bytes::text || ' bytes',
         'top 5 folders by object count; the folder name is hashed'
  from (
    select left(md5(coalesce((storage.foldername(ao.name))[1], '(root)')), 8) as folder_hash,
           count(*) as n,
           sum(ao.bytes) as bytes,
           row_number() over (order by count(*) desc, sum(ao.bytes) desc) as rn
    from avatar_objects ao
    group by (storage.foldername(ao.name))[1]
  ) x
  where x.rn <= 5

  union all
  -- ==== 06. profiles and user_appearance ==========================================
  select 6, t.o * 10 + 0, lpad(col.attnum::text, 3, '0'), 0, 'profiles',
         t.relname || ' column ' || col.attname::text,
         format_type(col.atttypid, col.atttypmod) || case when col.attnotnull then ' not null' else '' end
           || coalesce(' default ' || pg_get_expr(def.adbin, def.adrelid), ''),
         ''
  from (values (1, 'profiles'), (2, 'user_appearance')) as t(o, relname)
  join pg_attribute col on col.attrelid = to_regclass('public.' || t.relname) and col.attnum > 0 and not col.attisdropped
  left join pg_attrdef def on def.adrelid = col.attrelid and def.adnum = col.attnum

  union all
  select 6, t.o * 10 + 1, con.conname::text, 0, 'profiles',
         t.relname || ' constraint ' || con.conname::text,
         pg_get_constraintdef(con.oid), ''
  from (values (1, 'profiles'), (2, 'user_appearance')) as t(o, relname)
  join pg_constraint con on con.conrelid = to_regclass('public.' || t.relname)

  union all
  select 6, t.o * 10 + 2, i.indexname::text, 0, 'profiles',
         t.relname || ' index ' || i.indexname::text, i.indexdef,
         case when i.indexdef ilike '%unique%' and i.indexdef ilike '%nickname%' then 'nickname uniqueness' else '' end
  from (values (1, 'profiles'), (2, 'user_appearance')) as t(o, relname)
  join pg_indexes i on i.schemaname = 'public' and i.tablename = t.relname

  union all
  select 6, t.o * 10 + 3, tg.tgname::text, 0, 'profiles',
         t.relname || ' trigger ' || tg.tgname::text,
         case when (tg.tgtype & 2) = 2 then 'BEFORE' when (tg.tgtype & 64) = 64 then 'INSTEAD OF' else 'AFTER' end
           || case when (tg.tgtype & 4) = 4 then ' INSERT' else '' end
           || case when (tg.tgtype & 8) = 8 then ' DELETE' else '' end
           || case when (tg.tgtype & 16) = 16 then ' UPDATE' else '' end
           || case when (tg.tgtype & 32) = 32 then ' TRUNCATE' else '' end
           || case when (tg.tgtype & 1) = 1 then ' ROW' else ' STATEMENT' end
           || ' | ' || tg.tgfoid::regprocedure::text || ' | enabled ' || tg.tgenabled::text,
         'function body: ' || pg_get_functiondef(tg.tgfoid)
  from (values (1, 'profiles'), (2, 'user_appearance')) as t(o, relname)
  join pg_trigger tg on tg.tgrelid = to_regclass('public.' || t.relname) and not tg.tgisinternal

  union all
  select 6, t.o * 10 + 4, '', 0, 'profiles', t.relname || ' triggers (count)',
         (select count(*) from pg_trigger tg where tg.tgrelid = to_regclass('public.' || t.relname) and not tg.tgisinternal)::text,
         case when t.relname = 'profiles'
                   and exists (select 1 from pg_attribute col
                               where col.attrelid = 'public.profiles'::regclass and col.attname = 'updated_at' and not col.attisdropped)
              then 'profiles has updated_at; a trigger above maintains it only if one is listed'
              when t.relname = 'profiles' then 'profiles has no updated_at column'
              else '' end
  from (values (1, 'profiles'), (2, 'user_appearance')) as t(o, relname)

  union all
  select 6, t.o * 10 + 5, p.policyname::text, 0, 'profiles',
         t.relname || ' policy ' || p.policyname::text,
         p.cmd || ' | to ' || array_to_string(p.roles, ', '),
         coalesce('using (' || p.qual || ')', '') || coalesce(' with check (' || p.with_check || ')', '')
  from (values (1, 'profiles'), (2, 'user_appearance')) as t(o, relname)
  join pg_policies p on p.schemaname = 'public' and p.tablename = t.relname

  union all
  -- ==== 07. follows ===============================================================
  select 7, 0, con.conname::text, 0, 'follows', 'follows constraint ' || con.conname::text,
         pg_get_constraintdef(con.oid), ''
  from pg_constraint con
  where con.conrelid = to_regclass('public.follows')

  union all
  select 7, 1, i.indexname::text, 0, 'follows', 'follows index ' || i.indexname::text, i.indexdef, ''
  from pg_indexes i
  where i.schemaname = 'public' and i.tablename = 'follows'

  union all
  select 7, 2, '', 0, 'follows', 'follows triggers (count)',
         (select count(*) from pg_trigger tg where tg.tgrelid = to_regclass('public.follows') and not tg.tgisinternal)::text,
         coalesce((select string_agg(tg.tgname::text || ' -> ' || tg.tgfoid::regprocedure::text, '; ')
                   from pg_trigger tg where tg.tgrelid = to_regclass('public.follows') and not tg.tgisinternal), '')

  union all
  select 7, 3, x.fn, 0, 'follows', x.fn,
         coalesce((select p.oid::regprocedure::text || ' returns ' || pg_get_function_result(p.oid)
                          || ' | md5 ' || md5(p.prosrc)
                   from pg_proc p where p.oid = to_regprocedure(x.sig)), '(missing)'),
         case when to_regprocedure(x.sig) is null then 'STOP: missing'
              when x.fn = 'follow_user' and (select p.prosrc from pg_proc p where p.oid = to_regprocedure(x.sig)) ~ '\m50\M'
                then 'the cap of 50 is passed here, to _follow_user_as'
              when x.fn = '_follow_user_as' and (select p.prosrc from pg_proc p where p.oid = to_regprocedure(x.sig)) ~* 'p_limit'
                then 'the cap is enforced here (count against p_limit)'
              else '' end
  from (values ('follow_user', 'public.follow_user(uuid)'),
               ('unfollow_user', 'public.unfollow_user(uuid)'),
               ('_follow_user_as', 'public._follow_user_as(uuid, uuid, integer)')) as x(fn, sig)

  union all
  -- ==== 08. pg_cron ===============================================================
  select 8, 0, '', 0, 'cron', 'pg_cron extension version',
         coalesce((select e.extversion from pg_extension e where e.extname = 'pg_cron'), 'not installed'),
         case when not exists (select 1 from pg_extension e where e.extname = 'pg_cron')
              then 'STOP: no pg_cron -- the hourly attempt_log cleanup needs it' else '' end

  union all
  select 8, 1, lpad(coalesce(j.jobid, ''), 6, '0'), 0, 'cron', 'job ' || coalesce(j.jobid, '?') || ': ' || coalesce(j.jobname, '(no name)'),
         'schedule ' || coalesce(j.schedule, '?') || ' | active ' || coalesce(j.active, '?'),
         'command: ' || coalesce(j.command, '')
  from xmltable('/table/row'
         passing (case when to_regclass('cron.job') is null then '<table/>'::xml
                       else query_to_xml('select jobid, jobname, schedule, active, command from cron.job order by jobid', false, false, '') end)
         columns jobid text path 'jobid', jobname text path 'jobname', schedule text path 'schedule',
                 active text path 'active', command text path 'command') j

  union all
  -- ==== 09. Fingerprints ==========================================================
  select 9, x.o, '', 0, 'fp', x.fn || ': md5 of the live body',
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
  select 9, 10 + c.o, 'a wrapper', 0, 'fp', c.fn || '(' || c.sig || '): C1 md5 (carriage returns removed)',
         coalesce((select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure('public.' || c.fn || '(' || c.sig || ')')), '(missing)')
           || ' | expected ' || c.wrap_md5,
         case when (select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure('public.' || c.fn || '(' || c.sig || ')')) = c.wrap_md5
              then 'as computer-c1-verification.sql expects (the wrapper)'
              else 'STOP: the live wrapper is not C1''s text (or missing)' end
  from c1_fp c

  union all
  select 9, 10 + c.o, 'b _as', 0, 'fp', c.fn || '_as(' || c.as_sig || '): C1 md5 (carriage returns removed)',
         coalesce((select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure('public.' || c.fn || '_as(' || c.as_sig || ')')), '(missing)')
           || ' | expected ' || c.as_md5,
         case when (select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure('public.' || c.fn || '_as(' || c.as_sig || ')')) = c.as_md5
              then 'as computer-c1-verification.sql expects (the _as body; a games cap changes start_game_with_deal_as and this value)'
              else 'STOP: the live _as body is not C1''s text (or missing)' end
  from c1_fp c

  union all
  select 9, 30, '', 0, 'fp', 'computer_start_game_with_deal(uuid): md5 of the live body',
         coalesce((select md5(p.prosrc) || ' | carriage returns removed ' || md5(replace(p.prosrc, E'\r', ''))
                   from pg_proc p where p.oid = to_regprocedure('public.computer_start_game_with_deal(uuid)')), '(missing)'),
         case when to_regprocedure('public.computer_start_game_with_deal(uuid)') is null then 'STOP: missing'
              else 'INFO: no suite fingerprints it; it calls start_game_with_deal_as for the computer (computer-c2-engine.sql)' end

  union all
  select 9, 31, '', 0, 'fp', 'computer_start_game_with_deal_as (any arguments)',
         coalesce((select string_agg(p.oid::regprocedure::text, ', ')
                   from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                   where ns.nspname = 'public' and p.proname = 'computer_start_game_with_deal_as'), '(none)'),
         case when exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                           where ns.nspname = 'public' and p.proname = 'computer_start_game_with_deal_as')
              then 'STOP: not expected -- the repo has no such function'
              else 'as expected: none (the computer''s start goes through start_game_with_deal_as)' end

  union all
  -- ==== 10. Sizes, counts, version ================================================
  select 10, st.o, '', 0, 'size', st.relname || ': rows / total size',
         case when to_regclass('public.' || st.relname) is null then '(missing)'
              else (xpath('/row/n/text()', query_to_xml('select count(*) as n from public.' || quote_ident(st.relname), false, true, '')))[1]::text
                   || ' / ' || pg_size_pretty(pg_total_relation_size(to_regclass('public.' || st.relname))) end,
         ''
  from size_tables st

  union all
  select 10, 20, '', 0, 'size', 'Postgres server_version_num / server_version',
         current_setting('server_version_num') || ' / ' || current_setting('server_version'),
         case when current_setting('server_version_num')::int >= 170000
              then 'MAINTAIN exists (17+): the revoke can include it'
              else 'MAINTAIN does not exist (before 17): leave it out of the revoke' end
) z
order by z.s, z.o, z.k, z.k2, z.item;
