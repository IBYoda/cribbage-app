-- Moderation, slice M6: PRECHECK for REPORTS (READ-ONLY).
-- Run in the Supabase Dashboard -> SQL Editor before
-- docs/sql/moderation-m6-part1.sql. ONE statement; it only reads the catalog
-- and counts rows. Paste the whole result back.
--
-- STATUS: written, NOT RUN yet.
--
-- Every row has a section, an item, a value and a note. A note starting
-- "STOP" means: do not run the next file; paste the result back. The first
-- row ("state") says where M6 stands:
--   before part 1       -> run moderation-m6-part1.sql next
--   part 1 present      -> M6 is in (part 1 is the only part)
--   a mixed state       -> STOP
--
-- M6 REPLACES NO EXISTING FUNCTION: there is no "swap" fingerprint here.
-- The fp section only proves _attempts_guard is slice A's body (part 1
-- relies on its lock key and its success row).
--
-- SECTIONS
--   state     the summary above.
--   fp        md5 of _attempts_guard's live body; a reminder row that M6
--             replaces nothing.
--   needs     moderation M3 part 1 (public.table_kicks, kick_player);
--             public.admin_users (and how many admins), public.profiles,
--             public.computer_accounts.
--   part1     attempt_log_action_check (M3's nine actions before, ten with
--             report_filed after); public.player_reports (absent before;
--             after: columns, no foreign keys, RLS on, no policies, no
--             client privileges); the five new functions (absent before;
--             after: part 1's bodies, security definer, search_path '', who
--             may execute them).
--   cron      pg_cron installed (part 1 STOPs without it); the job
--             report-purge (absent before; after: '23 4 * * *', select
--             public.purge_old_reports();); every job's name, for the
--             record.
--   storage   storage.objects exists and this role (which will own
--             report_player) may read it: informational -- without it the
--             avatar date and size in each snapshot are simply null.
--   grants    how many functions authenticated may execute in public: 56
--             before part 1 (slice E's 49, M1's 3, M2's 1, M3's 3), 59
--             after (plus report_player, admin_list_reports,
--             admin_delete_report), 60 once moderation M5a part 1 is in
--             (plus table_topic_allows).
--   names     anything already named like M6's objects ("report" in a
--             function, table, policy or cron job name).
--   count     player_reports rows and attempt_log report_filed rows (after
--             part 1).

with new_fns(o, name, sig, lf, client) as (
  values
    (1, '_report_avatar_object', 'public._report_avatar_object(uuid, text)', '045267155656c63ce47b152cef6c9044', false),
    (2, 'report_player', 'public.report_player(uuid, text, text, uuid)', 'cbbe554a4e170379f8c6b7ac88b1cecc', true),
    (3, 'admin_list_reports', 'public.admin_list_reports(integer)', 'b2bcdc0cd74f7453e964ec3bc31c6998', true),
    (4, 'admin_delete_report', 'public.admin_delete_report(uuid)', '77cd0a0d585977060ad7153baf64ff0f', true),
    (5, 'purge_old_reports', 'public.purge_old_reports()', '62eaf1170d97a02e1783d7f0197a9767', false)
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
           and cd.d ~ '''code_guess''' and cd.d ~ '''game_start''' and cd.d ~ '''follow_change''' and cd.d ~ '''block_change'''
           and cd.d ~ '''kick''' as has_nine,
         cd.d ~ '''report_filed''' as has_report
  from check_def cd
),
pr as (
  select c.oid, c.relowner, c.relacl, c.relrowsecurity
  from pg_class c
  where c.oid = to_regclass('public.player_reports')
),
pr_state as (
  select
    (select string_agg(a.attname::text || ' ' || format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else '' end, ', ' order by a.attnum)
     from pr t join pg_attribute a on a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped) as cols,
    (select count(*) from pr t join pg_constraint con on con.conrelid = t.oid and con.contype = 'f') as fks,
    (select t.relrowsecurity from pr t) as rls,
    (select count(*) from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'player_reports') as policies,
    (select coalesce(string_agg(case a.grantee when 0 then 'PUBLIC' else pg_get_userbyid(a.grantee)::text end || ':' || a.privilege_type, ', '
                                order by a.grantee, a.privilege_type), '')
     from pr t, aclexplode(coalesce(t.relacl, acldefault('r', t.relowner))) a
     where a.grantee = 0
        or a.grantee in (select r.oid from pg_roles r where r.rolname in ('anon', 'authenticated', 'service_role'))) as client_privs
),
-- pg_cron, read through query_to_xml so this statement parses where the
-- cron schema does not exist (the text runs only when cron.job is there).
cron_state as (
  select
    to_regclass('cron.job') is not null as installed,
    case when to_regclass('cron.job') is null then null
         else (xpath('/row/c/text()', query_to_xml(
                 'select count(*) as c from cron.job where jobname = ''report-purge''', false, true, '')))[1]::text::int end as purge_jobs,
    case when to_regclass('cron.job') is null then null
         else (xpath('/row/c/text()', query_to_xml(
                 'select count(*) as c from cron.job where jobname = ''report-purge'' and schedule = ''23 4 * * *'' and command = ''select public.purge_old_reports();''', false, true, '')))[1]::text::int end as purge_jobs_exact,
    case when to_regclass('cron.job') is null then null
         else (xpath('/row/c/text()', query_to_xml(
                 'select string_agg(jobname || '' ('' || schedule || '')'', '', '' order by jobname) as c from cron.job', false, true, '')))[1]::text end as all_jobs
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
    (select cs.has_report from check_state cs) as p1_check,
    to_regclass('public.player_reports') is not null as p1_table,
    (select count(*) from new_fn_state n where n.fn_oid is not null) as p1_fns,
    coalesce((select c.purge_jobs from cron_state c), 0) > 0 as p1_job
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== state ====================================================================
  select 0 as s, 0 as o, 'state'::text as section, 'M6 state'::text as item,
         ('attempt_log report_filed ' || coalesce(f.p1_check::text, '?') || ' | player_reports ' || f.p1_table::text
          || ' | M6 functions ' || f.p1_fns::text || ' of 5 | report-purge job ' || f.p1_job::text)::text as value,
         (case
            when f.p1_check is not true and not f.p1_table and f.p1_fns = 0 and not f.p1_job
              then 'before part 1: run docs/sql/moderation-m6-part1.sql next (if no other row says STOP)'
            when f.p1_check and f.p1_table and f.p1_fns = 5 and f.p1_job
              then 'part 1 present: M6 is in (part 1 is the only part)'
            else 'STOP: a mixed state (some of part 1 without the rest); paste the whole result back'
          end)::text as note
  from flags f

  union all
  -- ==== fp =======================================================================
  select 1, 1, 'fp', '_attempts_guard: md5 of the live body',
         coalesce((select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public._attempts_guard(uuid, text, integer, interval, text)')), '(missing)'),
         case (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public._attempts_guard(uuid, text, integer, interval, text)'))
              when 'b1b69dbbdf10d50f78655a0da3b3ac69' then 'join-create.sql, LF: as expected (report_player takes its lock and calls it)'
              when '9406938991e89dcd38d0686a279b432a' then 'join-create.sql, CRLF: as expected (report_player takes its lock and calls it)'
              else 'STOP: not join-create.sql''s text (or missing). Capture it first: select pg_get_functiondef(''public._attempts_guard(uuid, text, integer, interval, text)''::regprocedure);' end

  union all
  select 1, 2, 'fp', 'functions M6 replaces', '(none)',
         'M6 replaces no existing function: it only adds a table, five functions, an attempt_log action and a cron job'

  union all
  -- ==== needs ====================================================================
  select 2, 1, 'needs', 'moderation M3 part 1 (public.table_kicks, kick_player)',
         (to_regclass('public.table_kicks') is not null)::text || ' / ' || (to_regprocedure('public.kick_player(uuid, uuid)') is not null)::text,
         case when to_regclass('public.table_kicks') is not null and to_regprocedure('public.kick_player(uuid, uuid)') is not null
                then 'as expected'
              else 'STOP: run moderation M3 part 1 first' end

  union all
  select 2, 2, 'needs', 'public.admin_users exists / admins',
         case when to_regclass('public.admin_users') is null then '(missing)'
              else 'exists / ' || (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.admin_users', false, true, '')))[1]::text end,
         case when to_regclass('public.admin_users') is null then 'STOP: admin_list_reports and admin_delete_report check it'
              else 'as expected (admins read and delete reports)' end

  union all
  select 2, 3, 'needs', 'public.profiles / public.computer_accounts exist',
         (to_regclass('public.profiles') is not null)::text || ' / ' || (to_regclass('public.computer_accounts') is not null)::text,
         case when to_regclass('public.profiles') is not null and to_regclass('public.computer_accounts') is not null
                then 'as expected'
              else 'STOP: report_player reads both' end

  union all
  -- ==== part1: attempt_log =======================================================
  select 3, 1, 'part1', 'attempt_log_action_check',
         coalesce((select cs.d from check_state cs), '(missing)'),
         case
           when (select cs.has_nine and not cs.has_report and cs.n_actions = 9 from check_state cs)
             then 'before part 1: M3''s nine actions'
           when (select cs.has_nine and cs.has_report and cs.n_actions = 10 from check_state cs)
             then 'after part 1: plus report_filed (ten)'
           else 'STOP: neither M3''s nine actions nor those plus report_filed' end

  union all
  -- ==== part1: player_reports ====================================================
  select 3, 2, 'part1', 'public.player_reports: columns',
         coalesce((select t.cols from pr_state t), '(absent)'),
         case
           when to_regclass('public.player_reports') is null then 'before part 1: absent, as expected'
           when (select t.cols from pr_state t) = 'id uuid not null, created_at timestamp with time zone not null, reporter_id uuid not null, reported_id uuid not null, reason text not null, note text, table_id uuid, reporter_nickname text, reported_nickname text, reported_avatar_url text, avatar_object_updated_at timestamp with time zone, avatar_object_size bigint'
             then 'after part 1: as part 1 wrote it'
           else 'STOP: a table by that name with other columns' end

  union all
  select 3, 3, 'part1', 'public.player_reports: foreign keys / RLS / policies / client privileges',
         case when to_regclass('public.player_reports') is null then '(absent)'
              else coalesce((select t.fks::text || ' / ' || t.rls::text || ' / ' || t.policies::text || ' / ' || coalesce(nullif(t.client_privs, ''), 'none') from pr_state t), '?') end,
         case
           when to_regclass('public.player_reports') is null then ''
           when (select t.fks = 0 and t.rls and t.policies = 0 and t.client_privs = '' from pr_state t)
             then 'no foreign keys (deliberate), RLS on, no policies, no client privileges: as expected'
           else 'STOP: expected no foreign keys, RLS on, no policies and no privilege for PUBLIC, anon, authenticated or service_role' end

  union all
  -- ==== part1: functions =========================================================
  select 3, 10 + n.o, 'part1', n.sig,
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
  -- ==== cron =====================================================================
  select 4, 1, 'cron', 'pg_cron installed',
         (select c.installed::text from cron_state c),
         case when (select c.installed from cron_state c) then 'as expected'
              else 'STOP: part 1 needs pg_cron (the 90-day purge)' end

  union all
  select 4, 2, 'cron', 'job report-purge',
         case when not (select c.installed from cron_state c) then '(no pg_cron)'
              else (select c.purge_jobs::text || ' job(s), ' || c.purge_jobs_exact::text || ' exactly as part 1 schedules it' from cron_state c) end,
         case
           when not (select c.installed from cron_state c) then ''
           when (select c.purge_jobs from cron_state c) = 0 then 'before part 1: absent, as expected'
           when (select c.purge_jobs = 1 and c.purge_jobs_exact = 1 from cron_state c) then 'after part 1: ''23 4 * * *'', select public.purge_old_reports();'
           else 'STOP: a job by that name that part 1 did not schedule' end

  union all
  select 4, 3, 'cron', 'every pg_cron job (name and schedule)',
         coalesce((select c.all_jobs from cron_state c), '(none)'),
         'for the record (expected among them: attempt-log-cleanup, end-empty-tables, and after part 1 report-purge)'

  union all
  -- ==== storage ==================================================================
  select 5, 1, 'storage', 'storage.objects: exists / ' || current_user || ' may read it',
         case when to_regclass('storage.objects') is null then '(missing)'
              else 'exists / ' || coalesce(has_table_privilege(current_user, to_regclass('storage.objects'), 'SELECT'), false)::text end,
         -- The oid form: a missing table gives null (no error), never true.
         case when not coalesce(has_table_privilege(current_user, to_regclass('storage.objects'), 'SELECT'), false)
                then 'not a STOP: report_player still works, but each snapshot''s avatar date and size will be null'
              else 'as expected (the snapshot records the avatar file''s date and size)' end

  union all
  -- ==== grants ===================================================================
  select 6, 1, 'grants', 'functions authenticated may execute in public (distinct names)',
         (select count(*) from client_fns)::text,
         case
           when (select count(*) from client_fns) = 56
                and not exists (select 1 from client_fns cf where cf.name in ('report_player', 'admin_list_reports', 'admin_delete_report'))
             then 'before part 1: 56 (slice E''s 49, M1''s 3, M2''s 1, M3''s 3)'
           when (select count(*) from client_fns) = 59
                and (select count(*) from client_fns cf where cf.name in ('report_player', 'admin_list_reports', 'admin_delete_report')) = 3
             then 'after part 1: the 56 plus report_player, admin_list_reports, admin_delete_report'
           when (select count(*) from client_fns) = 60
                and (select count(*) from client_fns cf where cf.name in ('report_player', 'admin_list_reports', 'admin_delete_report')) = 3
                and exists (select 1 from client_fns cf where cf.name = 'table_topic_allows')
             then 'after part 1 and moderation M5a part 1: the 59 plus table_topic_allows'
           else 'STOP: neither 56, 59 nor 60 (slice-e-grants-verification.sql X1 would fail)' end

  union all
  -- ==== names ====================================================================
  select 7, 1, 'names', 'functions, tables, policies and cron jobs with "report" in the name',
         coalesce((select string_agg(x.n, ', ' order by x.n) from (
           select 'function ' || ns.nspname || '.' || p.proname as n
           from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
           where p.proname ilike '%report%' and ns.nspname not in ('pg_catalog', 'information_schema')
           union all
           select 'relation ' || ns.nspname || '.' || c.relname
           from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
           where c.relname ilike '%report%' and c.relkind in ('r', 'p', 'v', 'm', 'f')
             and ns.nspname not in ('pg_catalog', 'information_schema')
           union all
           select 'policy ' || pol.schemaname || '.' || pol.tablename || ' "' || pol.policyname || '"'
           from pg_policies pol where pol.policyname ilike '%report%'
           union all
           select 'cron job ' || j.n
           from unnest(string_to_array(coalesce((select c.all_jobs from cron_state c), ''), ', ')) as j(n)
           where j.n ilike '%report%') x), '(none)'),
         'before part 1: none expected; after part 1: part 1''s five functions, player_reports, the report-purge job'

  union all
  -- ==== count ====================================================================
  select 8, 1, 'count', 'player_reports rows / attempt_log report_filed rows (all time, last 24 hours)',
         -- Through query_to_xml, so the statement still parses while the
         -- table doesn't exist (the text runs only when the table is there).
         case when to_regclass('public.player_reports') is null then '(no table yet)'
              else (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.player_reports', false, true, '')))[1]::text end
         || ' / ' || (select count(*)::text from public.attempt_log a where a.action = 'report_filed')
         || ', ' || (select count(*)::text from public.attempt_log a where a.action = 'report_filed' and a.created_at > now() - interval '24 hours'),
         'for the record'
) z
order by z.s, z.o;
