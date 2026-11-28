-- Moderation, slice M7: PRECHECK for CHAT ATTACHED TO BEHAVIOR REPORTS
-- (READ-ONLY). Run in the Supabase Dashboard -> SQL Editor before
-- docs/sql/moderation-m7-part1.sql. ONE statement; it only reads the catalog
-- and counts rows. Paste the whole result back.
--
-- STATUS: RUN 2026-11-28, no STOP rows: state "before part 1" before part 1
-- ran, and again after it: state "part 1 present".
--
-- Every row has a section, an item, a value and a note. A note starting
-- "STOP" means: do not run the next file; paste the result back. The first
-- row ("state") says where M7 stands:
--   before part 1       -> run moderation-m7-part1.sql next
--   part 1 present      -> M7 is in (part 1 is the only part)
--   a mixed state       -> STOP
--
-- SECTIONS
--   state     the summary above.
--   fp        md5 of the live bodies (LF: carriage returns removed):
--             report_player and admin_list_reports (M6 part 1's before, M7
--             part 1's after), send_table_message (moderation M5c1 part 1's,
--             both states: the payload M7 copies), and the M6 functions M7
--             leaves alone (_report_avatar_object, admin_delete_report,
--             purge_old_reports).
--   owner     report_player's and send_table_message's owner (must be one
--             role), the role running this (part 1 must run as that role),
--             its SELECT on realtime.messages, and whether it bypasses
--             row-level security (INFO: send_table_message already reads
--             realtime.messages as it on every send).
--   realtime  realtime.messages: EVERY live column with its type (whether
--             expires_at or any other column exists: INFO), the five columns
--             M7 reads (STOP if one is missing), inserted_at's type, the
--             leaf partitions (count, oldest, newest), and the chat stored
--             right now (how many messages, at how many tables, the biggest
--             table's count and text bytes: the sizes the 2,000 / 200 KB cap
--             works on).
--   part1     public.player_reports: M6's twelve columns (before) or those
--             plus chat, chat_status, chat_total, chat_kept (after); the two
--             chat constraints; no foreign keys, RLS on, no policies, no
--             client privileges (both states); the two new functions (absent
--             before; after: part 1's bodies and grants).
--   grants    functions authenticated may execute in public (distinct
--             names): 60 before part 1 (with send_table_message, without
--             chat_topic_allows: moderation M5c1 c2 is in), 61 after (plus
--             admin_report_chat; _report_table_chat is for no client role).
--   count     player_reports rows by reason, and by chat_status after part 1.
--
-- SUITES TO RE-RUN AFTER PART 1 (each made state-aware for M7 in this slice):
--   moderation-m7-verification.sql, slice-e-grants-verification.sql (X1: 61
--   names with admin_report_chat), moderation-m6-verification.sql (K1: the
--   chat columns; K2: report_player's and admin_list_reports' M7 bodies),
--   moderation-m5c1c2-verification.sql (K4: 61 once M7 is in); the
--   prechecks m1, m3, m5a, m5b1, m5b2, m5c1, m5c1c2 and m6 (their grants
--   rows accept 61 with admin_report_chat), moderation-catalog.sql
--   (section 10).

with fns(o, name, sig, before_lf, after_lf, client) as (
  values
    (1, 'report_player', 'public.report_player(uuid, text, text, uuid)', 'cbbe554a4e170379f8c6b7ac88b1cecc', '2dd85cea07caa56de74f5bfdef7d3b07', true),
    (2, 'admin_list_reports', 'public.admin_list_reports(integer)', 'b2bcdc0cd74f7453e964ec3bc31c6998', '05e0e3809b944590a850ddc8ce259570', true),
    (3, 'send_table_message', 'public.send_table_message(uuid, text)', 'e3adcc4874c77c1c47530a807fefd815', 'e3adcc4874c77c1c47530a807fefd815', true),
    (4, '_report_avatar_object', 'public._report_avatar_object(uuid, text)', '045267155656c63ce47b152cef6c9044', '045267155656c63ce47b152cef6c9044', false),
    (5, 'admin_delete_report', 'public.admin_delete_report(uuid)', '77cd0a0d585977060ad7153baf64ff0f', '77cd0a0d585977060ad7153baf64ff0f', true),
    (6, 'purge_old_reports', 'public.purge_old_reports()', '62eaf1170d97a02e1783d7f0197a9767', '62eaf1170d97a02e1783d7f0197a9767', false),
    -- The two new ones: absent before.
    (7, '_report_table_chat', 'public._report_table_chat(uuid)', null, 'ac6d3541b82212f87572fc729bf87359', false),
    (8, 'admin_report_chat', 'public.admin_report_chat(uuid)', null, '0c872a9e8da827c0b4289c9179d2dc3f', true)
),
fn_state as (
  select f.o, f.name, f.sig, f.before_lf, f.after_lf, f.client,
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public' and p.proname = f.name) as overloads,
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
  from fns f
  left join pg_proc p on p.oid = to_regprocedure(f.sig)
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
    (select count(*) from pr t join pg_attribute a on a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped
     where a.attname in ('chat', 'chat_status', 'chat_total', 'chat_kept')) as chat_cols,
    (select count(*) from pr t join pg_constraint con on con.conrelid = t.oid
     where con.conname in ('player_reports_chat_status_check', 'player_reports_chat_check')) as chat_cons,
    (select count(*) from pr t join pg_constraint con on con.conrelid = t.oid and con.contype = 'f') as fks,
    (select t.relrowsecurity from pr t) as rls,
    (select count(*) from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'player_reports') as policies,
    (select coalesce(string_agg(case a.grantee when 0 then 'PUBLIC' else pg_get_userbyid(a.grantee)::text end || ':' || a.privilege_type, ', '
                                order by a.grantee, a.privilege_type), '')
     from pr t, aclexplode(coalesce(t.relacl, acldefault('r', t.relowner))) a
     where a.grantee = 0
        or a.grantee in (select r.oid from pg_roles r where r.rolname in ('anon', 'authenticated', 'service_role'))) as client_privs
),
owners as (
  select
    (select pg_get_userbyid(p.proowner)::text from pg_proc p where p.oid = to_regprocedure('public.report_player(uuid, text, text, uuid)')) as rp_owner,
    (select pg_get_userbyid(p.proowner)::text from pg_proc p where p.oid = to_regprocedure('public.send_table_message(uuid, text)')) as stm_owner
),
rm as (
  select c.oid, c.relkind, c.relowner from pg_class c where c.oid = to_regclass('realtime.messages')
),
rm_state as (
  select
    (select string_agg(a.attname::text || ' ' || format_type(a.atttypid, a.atttypmod), ', ' order by a.attnum)
     from rm r join pg_attribute a on a.attrelid = r.oid and a.attnum > 0 and not a.attisdropped) as cols,
    (select string_agg(c.col, ', ') from unnest(array['topic', 'extension', 'private', 'inserted_at', 'payload']) as c(col)
     where not exists (select 1 from rm r join pg_attribute a on a.attrelid = r.oid
                       where a.attname = c.col and a.attnum > 0 and not a.attisdropped)) as missing,
    (select format_type(a.atttypid, a.atttypmod) from rm r join pg_attribute a on a.attrelid = r.oid
     where a.attname = 'inserted_at' and not a.attisdropped) as inserted_at_type,
    (select a.attname is not null from rm r left join pg_attribute a on a.attrelid = r.oid and a.attname = 'expires_at' and not a.attisdropped) as has_expires_at,
    (select count(*) from pg_partition_tree(to_regclass('realtime.messages')) pt where pt.isleaf and pt.relid <> to_regclass('realtime.messages')) as leaves,
    (select min(pt.relid::regclass::text) from pg_partition_tree(to_regclass('realtime.messages')) pt where pt.isleaf and pt.relid <> to_regclass('realtime.messages')) as oldest_leaf,
    (select max(pt.relid::regclass::text) from pg_partition_tree(to_regclass('realtime.messages')) pt where pt.isleaf and pt.relid <> to_regclass('realtime.messages')) as newest_leaf
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
    (select t.chat_cols from pr_state t) as p1_cols,
    (select t.chat_cons from pr_state t) as p1_cons,
    (select count(*) from fn_state f where f.o in (7, 8) and f.fn_oid is not null) as p1_fns,
    (select f.m from fn_state f where f.o = 1) as rp_m,
    (select f.m from fn_state f where f.o = 2) as alr_m
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== state ====================================================================
  select 0 as s, 0 as o, 'state'::text as section, 'M7 state'::text as item,
         ('chat columns ' || coalesce(f.p1_cols, 0)::text || ' of 4 | chat constraints ' || coalesce(f.p1_cons, 0)::text || ' of 2 | new functions '
          || f.p1_fns::text || ' of 2 | report_player ' || case f.rp_m when 'cbbe554a4e170379f8c6b7ac88b1cecc' then 'M6' when '2dd85cea07caa56de74f5bfdef7d3b07' then 'M7' else 'other' end
          || ' | admin_list_reports ' || case f.alr_m when 'b2bcdc0cd74f7453e964ec3bc31c6998' then 'M6' when '05e0e3809b944590a850ddc8ce259570' then 'M7' else 'other' end)::text as value,
         (case
            when coalesce(f.p1_cols, 0) = 0 and coalesce(f.p1_cons, 0) = 0 and f.p1_fns = 0
                 and f.rp_m = 'cbbe554a4e170379f8c6b7ac88b1cecc' and f.alr_m = 'b2bcdc0cd74f7453e964ec3bc31c6998'
              then 'before part 1: run docs/sql/moderation-m7-part1.sql next (if no other row says STOP)'
            when f.p1_cols = 4 and f.p1_cons = 2 and f.p1_fns = 2
                 and f.rp_m = '2dd85cea07caa56de74f5bfdef7d3b07' and f.alr_m = '05e0e3809b944590a850ddc8ce259570'
              then 'part 1 present: M7 is in (part 1 is the only part)'
            else 'STOP: a mixed state (some of part 1 without the rest, or a body that is neither M6''s nor M7''s); paste the whole result back'
          end)::text as note
  from flags f

  union all
  -- ==== fp =======================================================================
  select 1, f.o, 'fp', f.sig,
         case when f.fn_oid is null then '(absent)'
              else 'md5 ' || f.m || ', definer ' || f.definer::text || ', search_path '''' ' || f.empty_path::text
                   || ', authenticated ' || f.auth_x::text || ', anon ' || f.anon_x::text
                   || ', PUBLIC ' || f.public_x::text || ', service_role ' || f.service_x::text end,
         case
           when f.overloads > 1 or (f.overloads = 1 and f.fn_oid is null) then 'STOP: another function by that name exists'
           when f.fn_oid is null and f.before_lf is null then 'before part 1: absent, as expected'
           when f.fn_oid is null then 'STOP: missing (M6 part 1 / M5c1 part 1 must be in)'
           when not (f.definer and f.empty_path and not f.anon_x and not f.public_x and not f.service_x and f.auth_x = f.client)
             then 'STOP: not security definer with search_path '''', or the wrong grants'
           when f.m = f.before_lf and f.m = f.after_lf then 'as expected (M7 leaves it alone)'
           when f.m = f.before_lf then 'before part 1: M6 part 1''s body, as expected'
           when f.m = f.after_lf then 'after part 1: M7 part 1''s body'
           else 'STOP: neither the expected before nor after body. Capture it first: select pg_get_functiondef(''' || f.sig || '''::regprocedure);' end
  from fn_state f

  union all
  select 1, 9, 'fp', 'public._report_table_chat(uuid): TimeZone setting',
         coalesce((select array_to_string(p.proconfig, ', ') from pg_proc p where p.oid = to_regprocedure('public._report_table_chat(uuid)')), '(absent)'),
         case when to_regprocedure('public._report_table_chat(uuid)') is null then 'before part 1: absent'
              when (select exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where lower(c) = 'timezone=utc') from pg_proc p where p.oid = to_regprocedure('public._report_table_chat(uuid)'))
                then 'after part 1: TimeZone UTC (inserted_at has no time zone)'
              else 'STOP: the helper must run with TimeZone UTC' end

  union all
  -- ==== owner ====================================================================
  select 2, 1, 'owner', 'owner of report_player / of send_table_message / this session''s role',
         coalesce(w.rp_owner, '?') || ' / ' || coalesce(w.stm_owner, '?') || ' / ' || current_user,
         case when w.rp_owner is null or w.stm_owner is null then 'STOP: report_player or send_table_message is missing'
              when w.rp_owner <> w.stm_owner then 'STOP: two different owners; the copy must read realtime.messages as send_table_message does'
              when w.rp_owner <> current_user then 'STOP: run part 1 as ' || w.rp_owner || ' (CREATE OR REPLACE needs the owner; the new functions get this role as owner)'
              else 'as expected (one role)' end
  from owners w

  union all
  select 2, 2, 'owner', 'that role: SELECT on realtime.messages / bypasses row-level security / owns realtime.messages',
         case when to_regclass('realtime.messages') is null then '(no realtime.messages)'
              else coalesce(has_table_privilege(w.rp_owner, to_regclass('realtime.messages'), 'SELECT')::text, '?') || ' / '
                   || coalesce((select r.rolbypassrls::text from pg_roles r where r.rolname = w.rp_owner), '?') || ' / '
                   || coalesce((select (pg_get_userbyid(m.relowner)::text = w.rp_owner)::text from rm m), '?') end,
         case when to_regclass('realtime.messages') is null then 'STOP: no realtime.messages'
              when not coalesce(has_table_privilege(w.rp_owner, to_regclass('realtime.messages'), 'SELECT'), false)
                then 'STOP: the owner may not SELECT realtime.messages'
              else 'as expected (SELECT). If it neither bypasses RLS nor owns the table, its reads see only what a policy lets it see -- but send_table_message reads the same rows as this role on every send and chat works, so the copy will too' end
  from owners w

  union all
  -- ==== realtime =================================================================
  select 3, 1, 'realtime', 'realtime.messages: every column (name type)',
         coalesce((select r.cols from rm_state r), '(missing)'),
         'INFO: for the record; M7 reads only topic, extension, private, inserted_at, payload'

  union all
  select 3, 2, 'realtime', 'realtime.messages: expires_at column / columns M7 needs but missing',
         coalesce((select r.has_expires_at::text from rm_state r), '?') || ' / ' || coalesce((select r.missing from rm_state r), '(none)'),
         case when (select r.missing from rm_state r) is not null then 'STOP: M7 reads these columns'
              else 'as expected (expires_at is INFO only: M7 does not read it)' end

  union all
  select 3, 3, 'realtime', 'realtime.messages: inserted_at type',
         coalesce((select r.inserted_at_type from rm_state r), '(missing)'),
         'INFO: expected timestamp without time zone (stamped in UTC); the helper runs with TimeZone UTC either way'

  union all
  select 3, 4, 'realtime', 'realtime.messages: leaf partitions / oldest / newest',
         coalesce((select r.leaves::text || ' / ' || coalesce(r.oldest_leaf, '-') || ' / ' || coalesce(r.newest_leaf, '-') from rm_state r), '(missing)'),
         'INFO: Realtime creates and drops these itself (expected about 7 daily partitions, about 3 to 4 days kept); the copy reads the last 5 days'

  union all
  select 3, 5, 'realtime', 'chat stored now: messages / tables / biggest table''s messages / its text bytes',
         case when to_regclass('realtime.messages') is null or not coalesce(has_table_privilege(current_user, to_regclass('realtime.messages'), 'SELECT'), false)
                then '(cannot read)'
              else (xpath('/row/c/text()', query_to_xml(
                     'select concat_ws('' / '', coalesce(sum(x.n), 0), count(*), coalesce(max(x.n), 0),
                                       coalesce((select y.b from (select m.topic, sum(octet_length(m.payload ->> ''text'')) as b, count(*) as n
                                                                  from realtime.messages m
                                                                  where m.extension = ''broadcast'' and m.private = true and m.topic like ''table:%''
                                                                    and m.payload ->> ''event'' = ''chat''
                                                                  group by m.topic order by count(*) desc limit 1) y), 0)) as c
                      from (select m.topic, count(*) as n
                            from realtime.messages m
                            where m.extension = ''broadcast'' and m.private = true and m.topic like ''table:%''
                              and m.payload ->> ''event'' = ''chat''
                            group by m.topic) x', false, true, '')))[1]::text end,
         'INFO: the cap is 2,000 messages and 204,800 bytes of text per report; a table above either keeps only its newest messages'

  union all
  -- ==== part1 ====================================================================
  select 4, 1, 'part1', 'public.player_reports: columns',
         coalesce((select t.cols from pr_state t), '(absent)'),
         case
           when to_regclass('public.player_reports') is null then 'STOP: no public.player_reports (moderation M6 part 1 must be in)'
           when (select t.cols from pr_state t) = 'id uuid not null, created_at timestamp with time zone not null, reporter_id uuid not null, reported_id uuid not null, reason text not null, note text, table_id uuid, reporter_nickname text, reported_nickname text, reported_avatar_url text, avatar_object_updated_at timestamp with time zone, avatar_object_size bigint'
             then 'before part 1: M6''s twelve columns, as expected'
           when (select t.cols from pr_state t) = 'id uuid not null, created_at timestamp with time zone not null, reporter_id uuid not null, reported_id uuid not null, reason text not null, note text, table_id uuid, reporter_nickname text, reported_nickname text, reported_avatar_url text, avatar_object_updated_at timestamp with time zone, avatar_object_size bigint, chat jsonb, chat_status text, chat_total integer, chat_kept integer'
             then 'after part 1: plus chat, chat_status, chat_total, chat_kept'
           else 'STOP: neither M6''s columns nor M6''s plus the four chat columns' end

  union all
  select 4, 2, 'part1', 'public.player_reports: chat constraints / foreign keys / RLS / policies / client privileges',
         case when to_regclass('public.player_reports') is null then '(absent)'
              else coalesce((select t.chat_cons::text || ' / ' || t.fks::text || ' / ' || t.rls::text || ' / ' || t.policies::text || ' / ' || coalesce(nullif(t.client_privs, ''), 'none') from pr_state t), '?') end,
         case
           when to_regclass('public.player_reports') is null then ''
           when (select t.fks = 0 and t.rls and t.policies = 0 and t.client_privs = '' and t.chat_cons in (0, 2) from pr_state t)
             then 'as expected (0 chat constraints before part 1, 2 after; no foreign keys, RLS on, no policies, no client privileges)'
           else 'STOP: expected no foreign keys, RLS on, no policies, no privilege for PUBLIC, anon, authenticated or service_role, and 0 or 2 chat constraints' end

  union all
  -- ==== grants ===================================================================
  select 5, 1, 'grants', 'functions authenticated may execute in public (distinct names)',
         (select count(*) from client_fns)::text,
         case
           when (select count(*) from client_fns) = 60
                and exists (select 1 from client_fns cf where cf.name = 'send_table_message')
                and not exists (select 1 from client_fns cf where cf.name in ('chat_topic_allows', 'admin_report_chat', '_report_table_chat'))
             then 'before part 1: 60 (moderation M5c1 c2 is in: send_table_message, no chat_topic_allows)'
           when (select count(*) from client_fns) = 61
                and exists (select 1 from client_fns cf where cf.name = 'send_table_message')
                and exists (select 1 from client_fns cf where cf.name = 'admin_report_chat')
                and not exists (select 1 from client_fns cf where cf.name in ('chat_topic_allows', '_report_table_chat'))
             then 'after part 1: the 60 plus admin_report_chat'
           else 'STOP: neither 60 (before) nor 61 with admin_report_chat (after); slice-e-grants-verification.sql X1 would fail' end

  union all
  -- ==== count ====================================================================
  select 6, 1, 'count', 'player_reports rows: nickname / picture / behavior',
         case when to_regclass('public.player_reports') is null then '(no table)'
              else (xpath('/row/c/text()', query_to_xml(
                     'select concat_ws('' / '', count(*) filter (where reason = ''nickname''), count(*) filter (where reason = ''picture''), count(*) filter (where reason = ''behavior'')) as c from public.player_reports',
                     false, true, '')))[1]::text end,
         'for the record'

  union all
  select 6, 2, 'count', 'player_reports by chat_status: copied / none / not_at_table / unavailable / null',
         case when (select coalesce(t.chat_cols, 0) from pr_state t) <> 4 then '(no chat columns yet)'
              else (xpath('/row/c/text()', query_to_xml(
                     'select concat_ws('' / '', count(*) filter (where chat_status = ''copied''), count(*) filter (where chat_status = ''none''), count(*) filter (where chat_status = ''not_at_table''), count(*) filter (where chat_status = ''unavailable''), count(*) filter (where chat_status is null)) as c from public.player_reports',
                     false, true, '')))[1]::text end,
         'for the record (after part 1)'
) z
order by z.s, z.o;
