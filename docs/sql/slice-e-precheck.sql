-- Step 3, slice E: RATE LIMITS, ATTEMPT_LOG CLEANUP, GRANTS HARDENING.
-- The PRE-CHECK (read-only). Run in the Supabase Dashboard -> SQL Editor
-- before docs/sql/slice-e-part1.sql, AGAIN before part 2 and part 3, and any
-- time after. It reads only; it changes nothing: no writes, no DO block, no
-- temp table, no SET.
--
-- STATUS: written, NOT RUN yet.
--
-- ONE query, so the editor shows every row in one grid. Columns: section,
-- item, value, note (all text). A note starting with STOP means: do not run
-- the next slice E file; paste the result back first. Each part's rows say
-- "before" or "after" that part; anything else is a STOP. INFO rows are
-- facts, not blockers. pg_cron is read through query_to_xml (this parses
-- without it); storage and the step 3 tables are read directly.
--
-- WHAT IT LOOKS FOR
--   fp       the four bodies slice E must NOT change (leave_table,
--            end_timed_out_sessions, assign_table_seat, table_host: md5 of
--            the live body, LF or CRLF); computer-c1's sixteen bodies
--            (md5 with carriage returns removed) -- start_game_with_deal_as
--            may read today's 8d6ceb9ba00b9f2b6b9b8613e10609df (before part
--            2) or part 2's 8b4528a51247b63a47b36bd703f81492 (after); and
--            _follow_user_as / unfollow_user, today's or part 2's.
--   part1    attempt_log_action_check (5 actions before, 7 after);
--            profiles.nickname_changed_at; cleanup_attempt_log() (definer,
--            search_path '', no client EXECUTE); pg_cron and every job --
--            attempt-log-cleanup absent before, '17 * * * *' active after.
--   part2    the profiles_nickname_lock trigger; the two avatar write
--            policies (the folder rule only before; the fixed names after).
--   part3    the nine tables' privileges for anon and authenticated (Supabase
--            defaults before; slice E's matrix after); rls_auto_enable(): an
--            event-trigger function (STOP if not), its acl, and whether
--            anon / PUBLIC can execute it; postgres's GLOBAL default ACL for
--            functions (pg_default_acl, schema 0): absent before part 3
--            (the built-in default -- PUBLIC gets EXECUTE on every new
--            function), {postgres=X/postgres} after.
--   avatar   the avatars objects whose name is NOT one of the four fixed names
--            for their folder (avatar.png, avatar.jpg, avatar.jpeg,
--            avatar.webp): the folder replaced by the first 8 characters of
--            its md5, the file name, bytes, created. Left alone by slice E
--            (never delete storage.objects rows with SQL: it orphans the
--            files); listed so Walt can decide.
--   count    attempt_log rows per action; the most games one account
--            started in a single clock hour over the last 30 days (computer
--            games counted for the human who created the table) -- how close
--            real play comes to the cap of 30; profiles rows with a
--            nickname_changed_at.

with c1_fp(o, fn, sig, as_sig, as_md5, wrap_md5) as (
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
grant_target(o, tbl, auth_want, anon_want) as (
  values
    (1, 'tables', 'SELECT, UPDATE', 'SELECT'),
    (2, 'table_members', 'SELECT', 'SELECT'),
    (3, 'games', 'SELECT, UPDATE', 'SELECT'),
    (4, 'game_plays', 'SELECT', 'SELECT'),
    (5, 'game_hands', 'SELECT', 'SELECT'),
    (6, 'game_cribs', 'SELECT', 'SELECT'),
    (7, 'game_decks', 'SELECT', 'SELECT'),
    (8, 'profiles', 'INSERT, SELECT, UPDATE', 'SELECT'),
    (9, 'admin_users', 'SELECT', 'SELECT')
),
grant_state as (
  select g.o, g.tbl, g.auth_want, g.anon_want,
         coalesce((select string_agg(a.privilege_type, ', ' order by a.privilege_type)
                   from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
                   where c.oid = to_regclass('public.' || g.tbl)
                     and a.grantee = (select ro.oid from pg_roles ro where ro.rolname = 'authenticated')), '') as auth_has,
         coalesce((select string_agg(a.privilege_type, ', ' order by a.privilege_type)
                   from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
                   where c.oid = to_regclass('public.' || g.tbl)
                     and a.grantee = (select ro.oid from pg_roles ro where ro.rolname = 'anon')), '') as anon_has,
         coalesce((select string_agg(a.privilege_type, ', ' order by a.privilege_type)
                   from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
                   where c.oid = to_regclass('public.' || g.tbl)
                     and a.grantee = 0), '') as public_has
  from grant_target g
),
avatar_objects as (
  select o.name, o.created_at, coalesce((o.metadata ->> 'size')::bigint, 0) as bytes,
         (storage.foldername(o.name))[1] as folder
  from storage.objects o
  where o.bucket_id = 'avatars'
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== fp: the four fingerprinted bodies =======================================
  select 1 as s, x.o as o, ''::text as k, 'fp'::text as section, (x.fn || ': md5 of the live body')::text as item,
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
  -- ==== fp: computer-c1's sixteen bodies ========================================
  select 1, 10 + c.o, 'a', 'fp', c.fn || '(' || c.sig || '): C1 md5 (carriage returns removed)',
         coalesce((select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure('public.' || c.fn || '(' || c.sig || ')')), '(missing)'),
         case when (select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure('public.' || c.fn || '(' || c.sig || ')')) = c.wrap_md5
              then 'as expected (wrapper; slice E does not change it)'
              else 'STOP: expected ' || c.wrap_md5 end
  from c1_fp c

  union all
  select 1, 10 + c.o, 'b', 'fp', c.fn || '_as(' || c.as_sig || '): C1 md5 (carriage returns removed)',
         coalesce((select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure('public.' || c.fn || '_as(' || c.as_sig || ')')), '(missing)'),
         case (select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure('public.' || c.fn || '_as(' || c.as_sig || ')'))
              when c.as_md5 then case when c.fn = 'start_game_with_deal' then 'before part 2: today''s body, as expected' else 'as expected (slice E does not change it)' end
              when (case when c.fn = 'start_game_with_deal' then '8b4528a51247b63a47b36bd703f81492' end)
                then 'after part 2: the games cap (E1), as expected'
              else 'STOP: expected ' || c.as_md5 || case when c.fn = 'start_game_with_deal' then ' (before part 2) or 8b4528a51247b63a47b36bd703f81492 (after)' else '' end end
  from c1_fp c

  union all
  select 1, 30 + x.o, '', 'fp', x.sig || ': md5 (carriage returns removed)',
         coalesce((select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure(x.sig)), '(missing)'),
         case (select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure(x.sig))
              when x.before_md5 then 'before part 2: follows.sql''s body, as expected'
              when x.after_md5 then 'after part 2: the follow churn limit, as expected'
              else 'STOP: expected ' || x.before_md5 || ' (before part 2) or ' || x.after_md5 || ' (after)' end
  from (values
    (1, 'public._follow_user_as(uuid, uuid, integer)', '9c2f318761d3110a1f67de73eb5d9be8', '0996790bb0c497cdf8cb775a2fb3e22e'),
    (2, 'public.unfollow_user(uuid)', '82fe22965cc8a28cc3812f029b470404', 'be4ba2a18fb61605135205713be00f07')
  ) as x(o, sig, before_md5, after_md5)

  union all
  -- ==== part1 ======================================================================
  select 2, 1, '', 'part1', 'attempt_log_action_check',
         coalesce((select pg_get_constraintdef(con.oid) from pg_constraint con
                   where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check'), '(missing)'),
         case
           when (select pg_get_constraintdef(con.oid) from pg_constraint con
                 where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check') is null
             then 'STOP: the constraint is missing'
           when (select (length(d) - length(replace(d, '::text', ''))) / 6
                 from (select pg_get_constraintdef(con.oid) as d from pg_constraint con
                       where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check') q) = 5
             then 'before part 1: the five slice A actions'
           when (select d ~ '''game_start''' and d ~ '''follow_change''' and (length(d) - length(replace(d, '::text', ''))) / 6 = 7
                 from (select pg_get_constraintdef(con.oid) as d from pg_constraint con
                       where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check') q)
             then 'after part 1: plus game_start and follow_change'
           else 'STOP: neither the five slice A actions nor those plus game_start and follow_change' end

  union all
  select 2, 2, '', 'part1', 'profiles.nickname_changed_at',
         coalesce((select format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else ' nullable' end
                   from pg_attribute a
                   where a.attrelid = 'public.profiles'::regclass and a.attname = 'nickname_changed_at' and not a.attisdropped), '(absent)'),
         case when not exists (select 1 from pg_attribute a
                               where a.attrelid = 'public.profiles'::regclass and a.attname = 'nickname_changed_at' and not a.attisdropped)
              then 'before part 1'
              when exists (select 1 from pg_attribute a
                           where a.attrelid = 'public.profiles'::regclass and a.attname = 'nickname_changed_at' and not a.attisdropped
                             and format_type(a.atttypid, a.atttypmod) = 'timestamp with time zone' and not a.attnotnull)
              then 'after part 1'
              else 'STOP: expected a nullable timestamptz' end

  union all
  select 2, 3, '', 'part1', 'public.cleanup_attempt_log()',
         coalesce((select case when p.prosecdef then 'definer' else 'invoker' end || ' | ' || coalesce(array_to_string(p.proconfig, ' '), 'no config')
                          || ' | anon ' || has_function_privilege('anon', p.oid, 'EXECUTE')::text
                          || ', authenticated ' || has_function_privilege('authenticated', p.oid, 'EXECUTE')::text
                   from pg_proc p where p.oid = to_regprocedure('public.cleanup_attempt_log()')), '(absent)'),
         case when to_regprocedure('public.cleanup_attempt_log()') is null then 'before part 1'
              when (select p.prosecdef
                           and coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']
                           and not has_function_privilege('anon', p.oid, 'EXECUTE')
                           and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
                           and not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0)
                    from pg_proc p where p.oid = to_regprocedure('public.cleanup_attempt_log()'))
              then 'after part 1, as expected'
              else 'STOP: must be security definer, search_path '''', executable by no client role' end

  union all
  select 2, 4, '', 'part1', 'pg_cron extension version',
         coalesce((select e.extversion from pg_extension e where e.extname = 'pg_cron'), 'not installed'),
         case when not exists (select 1 from pg_extension e where e.extname = 'pg_cron')
              then 'STOP: no pg_cron -- the hourly cleanup needs it' else '' end

  union all
  select 2, 5, lpad(coalesce(j.jobid, ''), 6, '0'), 'part1', 'cron job ' || coalesce(j.jobid, '?') || ': ' || coalesce(j.jobname, '(no name)'),
         'schedule ' || coalesce(j.schedule, '?') || ' | active ' || coalesce(j.active, '?') || ' | ' || coalesce(j.command, ''),
         case when j.jobname = 'attempt-log-cleanup'
              then case when j.schedule = '17 * * * *' and j.active = 'true' and j.command ilike '%public.cleanup_attempt_log()%'
                        then 'after part 1, as expected' else 'STOP: expected 17 * * * *, active, select public.cleanup_attempt_log();' end
              when j.jobname in ('end-timed-out-sessions', 'end-empty-tables') then 'kept'
              else 'INFO: another job' end
  from xmltable('/table/row'
         passing (case when to_regclass('cron.job') is null then '<table/>'::xml
                       else query_to_xml('select jobid, jobname, schedule, active, command from cron.job order by jobid', false, false, '') end)
         columns jobid text path 'jobid', jobname text path 'jobname', schedule text path 'schedule',
                 active text path 'active', command text path 'command') j

  union all
  -- ==== part2 ======================================================================
  select 3, 1, '', 'part2', 'profiles triggers',
         coalesce((select string_agg(tg.tgname::text || ' -> ' || tg.tgfoid::regprocedure::text || ' (enabled ' || tg.tgenabled::text || ')', '; ')
                   from pg_trigger tg where tg.tgrelid = 'public.profiles'::regclass and not tg.tgisinternal), '(none)'),
         case when not exists (select 1 from pg_trigger tg where tg.tgrelid = 'public.profiles'::regclass and not tg.tgisinternal)
              then 'before part 2'
              when (select count(*) from pg_trigger tg where tg.tgrelid = 'public.profiles'::regclass and not tg.tgisinternal) = 1
                   and exists (select 1 from pg_trigger tg where tg.tgrelid = 'public.profiles'::regclass
                                 and tg.tgname = 'profiles_nickname_lock' and tg.tgenabled <> 'D')
              then 'after part 2'
              else 'STOP: profiles has a trigger slice E does not know' end

  union all
  select 3, 2, p.policyname::text, 'part2', 'storage.objects policy: ' || p.policyname::text,
         p.cmd || ' | ' || coalesce('using (' || p.qual || ')', '') || coalesce(' with check (' || p.with_check || ')', ''),
         case when p.cmd = 'SELECT' then 'kept by slice E'
              when coalesce(p.qual, '') || coalesce(p.with_check, '') ilike '%avatar.png%' then 'after part 2: the fixed names'
              else 'before part 2: any file name in the user''s folder' end
  from pg_policies p
  where p.schemaname = 'storage' and p.tablename = 'objects'
    and (coalesce(p.qual, '') ilike '%avatars%' or coalesce(p.with_check, '') ilike '%avatars%')

  union all
  -- ==== part3 ======================================================================
  select 4, gs.o, gs.tbl, 'part3', gs.tbl || ': authenticated / anon / PUBLIC',
         coalesce(nullif(gs.auth_has, ''), '(none)') || ' / ' || coalesce(nullif(gs.anon_has, ''), '(none)') || ' / ' || coalesce(nullif(gs.public_has, ''), '(none)'),
         case when gs.auth_has = gs.auth_want and gs.anon_has = gs.anon_want and gs.public_has = ''
                then 'after part 3: slice E''s matrix'
              when gs.anon_has ~ 'DELETE' and gs.auth_has ~ 'DELETE'
                then 'before part 3: the broad defaults (part 3 keeps ' || gs.auth_want || ' / ' || gs.anon_want || ')'
              else 'STOP: neither the broad defaults nor slice E''s matrix (' || gs.auth_want || ' / ' || gs.anon_want || ')' end
  from grant_state gs

  union all
  select 4, 20, '', 'part3', 'public.rls_auto_enable()',
         coalesce((select case when p.prosecdef then 'definer' else 'invoker' end || ' | owner ' || pg_get_userbyid(p.proowner)::text
                          || ' | returns ' || pg_get_function_result(p.oid)
                          || ' | event trigger(s): ' || coalesce((select string_agg(e.evtname::text || ' on ' || e.evtevent::text || ' (enabled ' || e.evtenabled::text || ')', '; ')
                                                                  from pg_event_trigger e where e.evtfoid = p.oid), 'none')
                          || ' | anon ' || has_function_privilege('anon', p.oid, 'EXECUTE')::text
                          || ', authenticated ' || has_function_privilege('authenticated', p.oid, 'EXECUTE')::text
                          || ' | acl ' || coalesce(p.proacl::text, '(null: default ACL)')
                   from pg_proc p where p.oid = to_regprocedure('public.rls_auto_enable()')), '(absent)'),
         case when to_regprocedure('public.rls_auto_enable()') is null then 'INFO: absent; part 3 skips it'
              when not exists (select 1 from pg_event_trigger e where e.evtfoid = to_regprocedure('public.rls_auto_enable()'))
                then 'STOP: no event trigger uses it; part 3 refuses to revoke its EXECUTE'
              when has_function_privilege('anon', to_regprocedure('public.rls_auto_enable()'), 'EXECUTE')
                then 'before part 3: executable by anon / PUBLIC (part 3 revokes it; keep this acl for its rollback)'
              else 'after part 3: no client EXECUTE' end

  union all
  select 4, 21, '', 'part3', 'postgres global default ACL for new functions (pg_default_acl, all schemas)',
         coalesce((select da.defaclacl::text from pg_default_acl da
                   where da.defaclrole = 'postgres'::regrole and da.defaclnamespace = 0 and da.defaclobjtype = 'f'),
                  '(no row: the built-in default, EXECUTE for PUBLIC)'),
         case (select da.defaclacl::text from pg_default_acl da
               where da.defaclrole = 'postgres'::regrole and da.defaclnamespace = 0 and da.defaclobjtype = 'f')
              when '{postgres=X/postgres}' then 'after part 3: deny by default'
              else case when not exists (select 1 from pg_default_acl da
                                         where da.defaclrole = 'postgres'::regrole and da.defaclnamespace = 0 and da.defaclobjtype = 'f')
                        then 'before part 3: new functions give PUBLIC EXECUTE (part 3 adds the global row)'
                        else 'STOP: a global row slice E did not write; part 3 refuses to change it' end end

  union all
  select 4, 22, coalesce(dns.nspname::text, '(all)'), 'part3',
         'postgres default ACL for functions in schema ' || coalesce(dns.nspname::text, '(all schemas)'),
         coalesce(da.defaclacl::text, '(null)'),
         'INFO: per-schema rows only ADD to the global default; slice E does not touch them'
  from pg_default_acl da
  left join pg_namespace dns on dns.oid = da.defaclnamespace
  where da.defaclrole = 'postgres'::regrole and da.defaclobjtype = 'f' and da.defaclnamespace <> 0

  union all
  -- ==== avatar extras ==============================================================
  select 5, 1, left(md5(coalesce(ao.folder, '(root)')), 8) || ao.name, 'avatar',
         'folder ' || left(md5(coalesce(ao.folder, '(root)')), 8) || ': ' || regexp_replace(ao.name, '^.*/', ''),
         ao.bytes::text || ' bytes, created ' || coalesce(ao.created_at::text, '?'),
         'INFO: not one of the four fixed names; left alone (decide separately; never delete storage.objects rows with SQL)'
  from avatar_objects ao
  where ao.name not in (coalesce(ao.folder, '') || '/avatar.png', coalesce(ao.folder, '') || '/avatar.jpg',
                        coalesce(ao.folder, '') || '/avatar.jpeg', coalesce(ao.folder, '') || '/avatar.webp')

  union all
  select 5, 2, 'zz', 'avatar', 'avatars objects: total / with a fixed name / other names',
         (select count(*)::text
                 || ' / ' || count(*) filter (where ao.name in (coalesce(ao.folder, '') || '/avatar.png', coalesce(ao.folder, '') || '/avatar.jpg',
                                                                coalesce(ao.folder, '') || '/avatar.jpeg', coalesce(ao.folder, '') || '/avatar.webp'))::text
                 || ' / ' || count(*) filter (where ao.name not in (coalesce(ao.folder, '') || '/avatar.png', coalesce(ao.folder, '') || '/avatar.jpg',
                                                                    coalesce(ao.folder, '') || '/avatar.jpeg', coalesce(ao.folder, '') || '/avatar.webp'))::text
          from avatar_objects ao),
         'INFO'

  union all
  -- ==== count ======================================================================
  select 6, 1, x.action || x.success::text, 'count', 'attempt_log rows: ' || x.action || ', success ' || x.success::text,
         x.n::text || ' (oldest ' || x.oldest::text || ')', 'INFO'
  from (select a.action, a.success, count(*) as n, min(a.created_at) as oldest
        from public.attempt_log a group by a.action, a.success) x

  union all
  select 6, 2, '', 'count', 'most games one account started in one clock hour (last 30 days)',
         coalesce((select max(q.n)::text from (
                     select case when exists (select 1 from public.computer_accounts ca where ca.user_id = g.created_by)
                                 then t.created_by else g.created_by end as account,
                            date_trunc('hour', g.created_at) as hr, count(*) as n
                     from public.games g
                     join public.tables t on t.id = g.table_id
                     where g.created_at > now() - interval '30 days'
                     group by 1, 2) q), '0'),
         'INFO: the cap is 30 in any rolling hour; a clock hour is a close stand-in'

  union all
  select 6, 3, '', 'count', 'profiles rows / with nickname_changed_at set',
         (select count(*)::text from public.profiles) || ' / '
           || case when exists (select 1 from pg_attribute a
                                where a.attrelid = 'public.profiles'::regclass and a.attname = 'nickname_changed_at' and not a.attisdropped)
                   then (xpath('/row/n/text()', query_to_xml('select count(*) as n from public.profiles where nickname_changed_at is not null', false, true, '')))[1]::text
                   else '(no column yet)' end,
         'INFO'
) z
order by z.s, z.o, z.k, z.item;
