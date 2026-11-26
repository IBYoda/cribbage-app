-- Moderation, slice M3: PRECHECK for KICK (READ-ONLY).
-- Run in the Supabase Dashboard -> SQL Editor before
-- docs/sql/moderation-m3-part1.sql, and again before part 2. ONE statement;
-- it only reads the catalog and counts rows. Paste the whole result back.
--
-- STATUS: written, NOT RUN yet.
--
-- Every row has a section, an item, a value and a note. A note starting
-- "STOP" means: do not run the next file; paste the result back. The first
-- row ("state") says where M3 stands:
--   before part 1       -> run moderation-m3-part1.sql next
--   part 1 present      -> after the app is live, run moderation-m3-part2.sql
--   part 2 present      -> M3 is fully in
--   a mixed state       -> STOP
--
-- SECTIONS
--   state     the summary above.
--   fp        md5 of the live bodies M3 must not change (the four
--             fingerprinted ones, spectator_heartbeat, remove_spectator,
--             chat_topic_allows, _attempts_guard) and of join_table_by_code
--             / watch_table (M1 part 2's before part 2, M3 part 2's after).
--   part1     attempt_log_action_check (eight actions before, nine with kick
--             after); public.table_kicks (absent before; after: columns,
--             RLS on, no policies, no client privileges); the five new
--             functions (absent before; after: part 1's bodies, security
--             definer, search_path '', who may execute them).
--   realtime  realtime.messages (exists, RLS on); every policy on it
--             (exactly the two table-chat ones before part 1, those plus
--             "table kicks: people at the table receive" after; anything
--             else is a STOP: policies are OR'ed); realtime.send(jsonb,
--             text, text, boolean) exists and this role may call it (the
--             kick notice needs it); how many partitions realtime.messages
--             has (none: the verification's notice and live-policy lines
--             are skipped).
--   grants    how many functions authenticated may execute in public: 53
--             before part 1 (slice E's 49, M1's 3, M2's 1), 56 after
--             (plus kick_player, kick_topic_allows, admin_recent_kicks).
--   names     anything already named like M3's objects ("kick" in a
--             function, table or policy name).
--   count     table_kicks rows and attempt_log kick rows (after part 1).

with fp_known(o, fn, sig, lf, crlf, src) as (
  values
    (1, 'leave_table', 'public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa', 'phase2-slice-5-cut-before-deal.sql (FINGERPRINTED)'),
    (2, 'end_timed_out_sessions', 'public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c', 'phase2-slice-5-cut-before-deal.sql (FINGERPRINTED)'),
    (3, 'assign_table_seat', 'public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb', 'phase3-e1-seating.sql (FINGERPRINTED)'),
    (4, 'table_host', 'public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d', 'phase3-e1-seating.sql (FINGERPRINTED)'),
    (5, 'spectator_heartbeat', 'public.spectator_heartbeat(uuid)', '41d2ea0e865c2a9d5fa7203875a27ace', '6b7c271d78eb4f72c1aff3c851b578e1', 'spectators-join-or-watch.sql (M3 leaves it alone)'),
    (6, 'remove_spectator', 'public.remove_spectator(uuid, uuid)', 'dafa688f1b8c194e4be575cd0625ba12', '9786b9a5e50245365a2598b18da5892e', 'spectators.sql (M3 leaves it alone; the app stops calling it)'),
    (7, 'chat_topic_allows', 'public.chat_topic_allows(text, boolean)', '0458d5122d68d511b2e0fbceafe84aae', 'c4e6eda360de7d7723c4069e60d95345', 'spectator-chat.sql (M3 leaves it alone)'),
    (8, '_attempts_guard', 'public._attempts_guard(uuid, text, integer, interval, text)', 'b1b69dbbdf10d50f78655a0da3b3ac69', '9406938991e89dcd38d0686a279b432a', 'join-create.sql (the kick limit uses it)')
),
swap_known(o, fn, sig, m1_lf, m1_crlf, m3_lf, m3_crlf) as (
  values
    (1, 'join_table_by_code', 'public.join_table_by_code(text, boolean, uuid)', 'cf40593ee5afda235144a13e38d27f4a', 'c3ee9ced2e1033f9c068acd3325c5583', '297fa4f04a02e226691ebf3b5b135f83', 'fbf046f1582863cc5697b06f670481b2'),
    (2, 'watch_table', 'public.watch_table(text, uuid)', '5bf6065de215d92a02af63d035c7f910', '2aa5f9c37d65271f3b4619e58c171ea0', 'bdebb2e1a8213baa2a04666bcad59adb', 'ea5c3bd739b2f7243b985c7ea1fd9f2a')
),
swap_state as (
  select s.o, s.fn, s.sig,
         (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(s.sig)) as m,
         s.m1_lf, s.m1_crlf, s.m3_lf, s.m3_crlf
  from swap_known s
),
new_fns(o, name, sig, lf, client) as (
  values
    (1, '_is_kicked_from_table', 'public._is_kicked_from_table(uuid, uuid)', 'c8372af51a4537ca9cc079234487a414', false),
    (2, '_send_kick_notice', 'public._send_kick_notice(uuid, jsonb)', '382554f98b1f199c20ca0b692fa0e6f2', false),
    (3, 'kick_player', 'public.kick_player(uuid, uuid)', 'd859deb84acb67ec94a2cf65fb1f38f0', true),
    (4, 'kick_topic_allows', 'public.kick_topic_allows(text)', '48327bb75cf98b6ff91388a6db843d11', true),
    (5, 'admin_recent_kicks', 'public.admin_recent_kicks(integer)', 'a5a60cc3950475e702423f740b30cf40', true)
),
new_fn_state as (
  select n.o, n.name, n.sig, n.lf, n.client,
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public' and p.proname = n.name) as overloads,
         p.oid as fn_oid,
         md5(replace(p.prosrc, E'\r', '')) as m,
         p.prosecdef as definer,
         coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path='''''] as empty_path,
         case when p.oid is null then null else has_function_privilege('authenticated', p.oid, 'EXECUTE') end as auth_x,
         case when p.oid is null then null else has_function_privilege('anon', p.oid, 'EXECUTE') end as anon_x,
         case when p.oid is null then null
              else exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) end as public_x,
         case when p.oid is null or not exists (select 1 from pg_roles r where r.rolname = 'service_role') then false
              else has_function_privilege('service_role', p.oid, 'EXECUTE') end as service_x
  from new_fns n
  left join pg_proc p on p.oid = to_regprocedure(n.sig)
),
check_def as (
  select pg_get_constraintdef(con.oid) as d
  from pg_constraint con
  where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check'
),
check_state as (
  select cd.d,
         (length(cd.d) - length(replace(cd.d, '::text', ''))) / 6 as n_actions,
         cd.d ~ '''create_table''' and cd.d ~ '''create_computer_table''' and cd.d ~ '''join''' and cd.d ~ '''watch'''
           and cd.d ~ '''code_guess''' and cd.d ~ '''game_start''' and cd.d ~ '''follow_change''' and cd.d ~ '''block_change''' as has_eight,
         cd.d ~ '''kick''' as has_kick
  from check_def cd
),
tk as (
  select c.oid, c.relowner, c.relacl, c.relrowsecurity
  from pg_class c
  where c.oid = to_regclass('public.table_kicks')
),
tk_state as (
  select
    (select string_agg(a.attname::text || ' ' || format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else '' end, ', ' order by a.attnum)
     from tk t join pg_attribute a on a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped) as cols,
    (select t.relrowsecurity from tk t) as rls,
    (select count(*) from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'table_kicks') as policies,
    (select coalesce(string_agg(case a.grantee when 0 then 'PUBLIC' else pg_get_userbyid(a.grantee)::text end || ':' || a.privilege_type, ', '
                                order by a.grantee, a.privilege_type), '')
     from tk t, aclexplode(coalesce(t.relacl, acldefault('r', t.relowner))) a
     where a.grantee = 0
        or a.grantee in (select r.oid from pg_roles r where r.rolname in ('anon', 'authenticated', 'service_role'))) as client_privs
),
rt_pol as (
  select p.policyname::text as name, p.cmd::text as cmd, p.roles::text as roles, p.qual, p.with_check
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
),
client_fns as (
  select distinct p.proname::text as name
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.prokind in ('f', 'p')
    and not exists (select 1 from pg_depend d
                    where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
    and has_function_privilege('authenticated', p.oid, 'EXECUTE')
),
flags as (
  select
    (select cs.has_kick from check_state cs) as p1_check,
    to_regclass('public.table_kicks') is not null as p1_table,
    (select count(*) from new_fn_state n where n.fn_oid is not null) as p1_fns,
    exists (select 1 from rt_pol r where r.name = 'table kicks: people at the table receive') as p1_policy,
    (select count(*) from swap_state s where s.m in (s.m1_lf, s.m1_crlf)) as swap_m1,
    (select count(*) from swap_state s where s.m in (s.m3_lf, s.m3_crlf)) as swap_m3
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== state ====================================================================
  select 0 as s, 0 as o, 'state'::text as section, 'M3 state'::text as item,
         ('attempt_log kick ' || coalesce(f.p1_check::text, '?') || ' | table_kicks ' || f.p1_table::text
          || ' | M3 functions ' || f.p1_fns::text || ' of 5 | kicks policy ' || f.p1_policy::text
          || ' | join/watch M1''s ' || f.swap_m1::text || ', M3''s ' || f.swap_m3::text)::text as value,
         (case
            when f.p1_check is not true and not f.p1_table and f.p1_fns = 0 and not f.p1_policy and f.swap_m1 = 2
              then 'before part 1: run docs/sql/moderation-m3-part1.sql next (if no other row says STOP)'
            when f.p1_check and f.p1_table and f.p1_fns = 5 and f.p1_policy and f.swap_m1 = 2
              then 'part 1 present (part 2 not yet): after the app is live, run docs/sql/moderation-m3-part2.sql (if no other row says STOP)'
            when f.p1_check and f.p1_table and f.p1_fns = 5 and f.p1_policy and f.swap_m3 = 2
              then 'part 2 present: M3 is fully in'
            else 'STOP: a mixed state (some of part 1 or part 2 without the rest); paste the whole result back'
          end)::text as note
  from flags f

  union all
  -- ==== fp =======================================================================
  select 1, k.o, 'fp', k.fn || ': md5 of the live body',
         coalesce((select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(k.sig)), '(missing)'),
         case (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(k.sig))
              when k.lf then k.src || ', LF: as expected'
              when k.crlf then k.src || ', CRLF: as expected'
              else 'STOP: not ' || k.src || '''s text (or missing). Capture it first: select pg_get_functiondef(''' || k.sig || '''::regprocedure); and paste the result back' end
  from fp_known k

  union all
  select 1, 10 + s.o, 'fp', s.fn || ': md5 of the live body',
         coalesce(s.m, '(missing)'),
         case
           when s.m in (s.m1_lf, s.m1_crlf) then 'before part 2: M1 part 2''s body (' || (case when s.m = s.m1_lf then 'LF' else 'CRLF' end) || '), as expected'
           when s.m in (s.m3_lf, s.m3_crlf) then 'after part 2: M3''s body (' || (case when s.m = s.m3_lf then 'LF' else 'CRLF' end) || '), as expected'
           else 'STOP: neither M1 part 2''s ' || s.m1_crlf || ' / ' || s.m1_lf || ' nor M3 part 2''s ' || s.m3_crlf || ' / ' || s.m3_lf
                || '. Capture it first: select pg_get_functiondef(''' || s.sig || '''::regprocedure);' end
  from swap_state s

  union all
  -- ==== part1: attempt_log =======================================================
  select 2, 1, 'part1', 'attempt_log_action_check',
         coalesce((select cs.d from check_state cs), '(missing)'),
         case
           when (select cs.has_eight and not cs.has_kick and cs.n_actions = 8 from check_state cs)
             then 'before part 1: the eight actions (slice A/E''s seven plus block_change)'
           when (select cs.has_eight and cs.has_kick and cs.n_actions = 9 from check_state cs)
             then 'after part 1: plus kick'
           else 'STOP: neither the eight actions nor those plus kick' end

  union all
  -- ==== part1: table_kicks =======================================================
  select 2, 2, 'part1', 'public.table_kicks: columns',
         coalesce((select t.cols from tk_state t), '(absent)'),
         case
           when to_regclass('public.table_kicks') is null then 'before part 1: absent, as expected'
           when (select t.cols from tk_state t) = 'table_id uuid not null, kicked_id uuid not null, host_id uuid, kicked_nickname text, kicked_role text not null, game_live boolean not null, game_id uuid, created_at timestamp with time zone not null'
             then 'after part 1: as part 1 wrote it'
           else 'STOP: a table by that name with other columns' end

  union all
  select 2, 3, 'part1', 'public.table_kicks: RLS / policies / client privileges',
         case when to_regclass('public.table_kicks') is null then '(absent)'
              else coalesce((select t.rls::text || ' / ' || t.policies::text || ' / ' || coalesce(nullif(t.client_privs, ''), 'none') from tk_state t), '?') end,
         case
           when to_regclass('public.table_kicks') is null then ''
           when (select t.rls and t.policies = 0 and t.client_privs = '' from tk_state t) then 'RLS on, no policies, no client privileges: as expected'
           else 'STOP: expected RLS on, no policies and no privilege for PUBLIC, anon, authenticated or service_role' end

  union all
  -- ==== part1: functions =========================================================
  select 2, 10 + n.o, 'part1', n.sig,
         case when n.fn_oid is null then '(absent)'
              else 'md5 ' || n.m || ', definer ' || n.definer::text || ', search_path '''' ' || n.empty_path::text
                   || ', authenticated ' || n.auth_x::text || ', anon ' || n.anon_x::text
                   || ', PUBLIC ' || n.public_x::text || ', service_role ' || n.service_x::text end,
         case
           when n.overloads > 1 or (n.overloads = 1 and n.fn_oid is null) then 'STOP: another function by that name exists'
           when n.fn_oid is null then 'before part 1: absent, as expected'
           when n.m = n.lf and n.definer and n.empty_path and not n.anon_x and not n.public_x and not n.service_x
                and n.auth_x = n.client
             then 'after part 1: part 1''s body and grants'
           else 'STOP: not part 1''s body, or the wrong grants' end
  from new_fn_state n

  union all
  -- ==== realtime =================================================================
  select 3, 1, 'realtime', 'realtime.messages: exists / RLS on',
         case when to_regclass('realtime.messages') is null then '(missing)'
              else 'exists / ' || (select c.relrowsecurity::text from pg_class c where c.oid = to_regclass('realtime.messages')) end,
         case when to_regclass('realtime.messages') is null then 'STOP: Realtime Authorization is not set up'
              when not (select c.relrowsecurity from pg_class c where c.oid = to_regclass('realtime.messages')) then 'STOP: RLS is off'
              else 'as expected' end

  union all
  select 3, 10 + (row_number() over (order by r.name))::int, 'realtime', 'policy "' || r.name || '"',
         r.cmd || ' to ' || r.roles || ' | using: ' || coalesce(r.qual, '-') || ' | with check: ' || coalesce(r.with_check, '-'),
         case
           when r.name in ('table chat: members receive', 'table chat: members send') then 'table-chat.sql''s policy: expected'
           when r.name = 'table kicks: people at the table receive' then 'part 1''s policy: expected after part 1'
           else 'STOP: unknown policy; policies are OR''ed, look at it first' end
  from rt_pol r

  union all
  select 3, 2, 'realtime', 'policies on realtime.messages (count)',
         (select count(*) from rt_pol)::text,
         case
           when (select count(*) from rt_pol) = 2
                and (select count(*) from rt_pol r where r.name in ('table chat: members receive', 'table chat: members send')) = 2
             then 'before part 1: exactly the two table-chat policies'
           when (select count(*) from rt_pol) = 3
                and (select count(*) from rt_pol r where r.name in ('table chat: members receive', 'table chat: members send', 'table kicks: people at the table receive')) = 3
             then 'after part 1: the two table-chat policies plus the kicks policy'
           else 'STOP: expected the two table-chat policies (plus the kicks policy after part 1)' end

  union all
  select 3, 3, 'realtime', 'realtime.send(jsonb, text, text, boolean): exists / ' || current_user || ' may execute',
         case when to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null then '(missing)'
              else 'exists / ' || has_function_privilege(current_user, 'realtime.send(jsonb, text, text, boolean)', 'EXECUTE')::text end,
         case when to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null
                then 'STOP: the kick notice needs realtime.send (Realtime Broadcast from the database)'
              when not has_function_privilege(current_user, 'realtime.send(jsonb, text, text, boolean)', 'EXECUTE')
                then 'STOP: this role (which will own kick_player) may not call realtime.send'
              else 'as expected (part 1 runs as this role, so kick_player may send)' end

  union all
  select 3, 4, 'realtime', 'partitions of realtime.messages',
         (select count(*)::text from pg_inherits i where i.inhparent = to_regclass('realtime.messages')),
         'none: realtime.send cannot store the notice (kick_player still kicks: the send is caught); the verification''s notice and live-policy lines are skipped'

  union all
  -- ==== grants ===================================================================
  select 4, 1, 'grants', 'functions authenticated may execute in public (distinct names)',
         (select count(*) from client_fns)::text,
         case
           when (select count(*) from client_fns) = 53
                and not exists (select 1 from client_fns cf where cf.name in ('kick_player', 'kick_topic_allows', 'admin_recent_kicks'))
             then 'before part 1: 53 (slice E''s 49, M1''s 3, M2''s block_player_by_id)'
           when (select count(*) from client_fns) = 56
                and (select count(*) from client_fns cf where cf.name in ('kick_player', 'kick_topic_allows', 'admin_recent_kicks')) = 3
             then 'after part 1: the 53 plus kick_player, kick_topic_allows, admin_recent_kicks'
           else 'STOP: neither 53 nor 56 (slice-e-grants-verification.sql X1 would fail)' end

  union all
  -- ==== names ====================================================================
  select 5, 1, 'names', 'functions, tables and policies with "kick" in the name',
         coalesce((select string_agg(x.n, ', ' order by x.n) from (
           select 'function ' || ns.nspname || '.' || p.proname as n
           from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
           where p.proname ilike '%kick%' and ns.nspname not in ('pg_catalog', 'information_schema')
           union all
           select 'relation ' || ns.nspname || '.' || c.relname
           from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
           where c.relname ilike '%kick%' and c.relkind in ('r', 'p', 'v', 'm', 'f')
             and ns.nspname not in ('pg_catalog', 'information_schema')
           union all
           select 'policy ' || pol.schemaname || '.' || pol.tablename || ' "' || pol.policyname || '"'
           from pg_policies pol where pol.policyname ilike '%kick%') x), '(none)'),
         'before part 1: none expected; after part 1: part 1''s five functions, table_kicks and its three indexes, the kicks policy'

  union all
  -- ==== count ====================================================================
  select 6, 1, 'count', 'table_kicks rows / attempt_log kick rows (all time, last hour)',
         -- Through query_to_xml, so the statement still parses while the
         -- table doesn't exist (the text runs only when the table is there).
         case when to_regclass('public.table_kicks') is null then '(no table yet)'
              else (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.table_kicks', false, true, '')))[1]::text end
         || ' / ' || (select count(*)::text from public.attempt_log a where a.action = 'kick')
         || ', ' || (select count(*)::text from public.attempt_log a where a.action = 'kick' and a.created_at > now() - interval '1 hour'),
         'for the record'
) z
order by z.s, z.o;
