-- Moderation, slice M5 (one server-pushed table channel; chat through an
-- RPC with retention): the CATALOG (READ-ONLY). Run in the Supabase
-- Dashboard -> SQL Editor. It reads only; it changes nothing: no writes, no
-- DO block, no temp table, no SET. ONE statement. Safe to run any time.
-- Paste the whole result back.
--
-- STATUS: written 2026-11-26, NOT RUN yet.
--
-- WHY: before M5 is designed in SQL we need to SEE how Realtime stores
-- broadcasts sent from the database (realtime.send, as M3's kick notice
-- does): whether a row stays in realtime.messages, with which topic, event,
-- private flag and payload, for how long, and whether the role that owns
-- our security definer functions may read or delete those rows. That
-- decides between
--   Plan A: keep recent chat in Realtime's own copy (realtime.messages),
--   Plan B: our own small message table, cleaned every ~10 minutes.
--
-- Every read of realtime.messages' DATA goes through query_to_xml, so the
-- statement still parses if a column is missing or named differently; such
-- a row then says "(not read)". Topics and payloads in the samples are
-- MASKED: every uuid becomes <uuid> and every "nickname" value becomes
-- <name>; payloads are cut to 160 characters.
--
-- SECTIONS (section / item / value / note)
--   01 messages   realtime.messages: kind (partitioned or not), persistence
--                 (logged/unlogged), RLS, owner; its columns; its indexes;
--                 every partition (bound, estimated rows, size); exact row
--                 count, oldest and newest inserted_at; rows by topic family
--                 (the part before the first ":"), event, extension and
--                 private; the newest five kick notices (masked) and the
--                 newest five rows of any other family (keys only).
--   02 policies   every policy on realtime.messages (command, roles,
--                 permissive, using, with check).
--   03 functions  every function in the realtime schema: signature,
--                 security definer, owner, EXECUTE for this role and for
--                 authenticated.
--   04 publish    the supabase_realtime publication: its operations, every
--                 table with its column list and row filter, and each
--                 table's replica identity.
--   05 cron       pg_cron installed; every job (name, schedule, command,
--                 active), flagging any that touch realtime.
--   06 access     this role's and the client roles' privileges on
--                 realtime.messages; the schemas PostgREST exposes (if set
--                 on the authenticator role).
--   07 versions   installed extensions and their versions; Realtime's own
--                 latest migration (realtime.schema_migrations).
--   08 dashboard  what SQL cannot show (read it in the dashboard instead).
--   09 verdict    what this means: Plan A viable? Plan B needed?

with rm as (
  select c.oid, c.relkind, c.relpersistence, c.relrowsecurity, c.relforcerowsecurity, c.relowner
  from pg_class c
  where c.oid = to_regclass('realtime.messages')
),
rm_cols as (
  select string_agg(a.attname::text || ' ' || format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else '' end,
                    ', ' order by a.attnum) as list,
         count(*) filter (where a.attname in ('topic', 'event', 'extension', 'payload', 'private', 'inserted_at')) = 6 as ok
  from rm
  join pg_attribute a on a.attrelid = rm.oid and a.attnum > 0 and not a.attisdropped
),
rm_ok as (
  select coalesce((select c.ok from rm_cols c), false)
         and coalesce(has_table_privilege(current_user, to_regclass('realtime.messages'), 'SELECT'), false) as ok
),
-- Exact count, oldest and newest, kicks.
rm_stats as (
  select case when (select ok from rm_ok) then query_to_xml($q$
           select count(*) as n,
                  coalesce(min(inserted_at)::text, '-') as oldest,
                  coalesce(max(inserted_at)::text, '-') as newest,
                  count(*) filter (where topic like 'kicks:%') as kicks,
                  coalesce(min(inserted_at) filter (where topic like 'kicks:%')::text, '-') as oldest_kick,
                  coalesce(max(inserted_at) filter (where topic like 'kicks:%')::text, '-') as newest_kick,
                  count(*) filter (where inserted_at < now() - interval '1 hour') as older_than_1h,
                  count(*) filter (where inserted_at < now() - interval '1 day') as older_than_1d
           from realtime.messages
         $q$, true, false, '') end as x
),
-- Rows by topic family, event, extension and private.
rm_families as (
  select case when (select ok from rm_ok) then query_to_xml($q$
           select split_part(topic, ':', 1) as fam, coalesce(event, '-') as ev, coalesce(extension, '-') as ext,
                  coalesce(private::text, '-') as priv, count(*) as n,
                  min(inserted_at)::text as oldest, max(inserted_at)::text as newest
           from realtime.messages
           group by 1, 2, 3, 4
           order by count(*) desc
           limit 20
         $q$, true, false, '') end as x
),
-- The newest five kick notices, masked.
rm_kicks as (
  select case when (select ok from rm_ok) then query_to_xml($q$
           select regexp_replace(topic, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<uuid>', 'g') as topic,
                  coalesce(event, '-') as ev, coalesce(extension, '-') as ext, coalesce(private::text, '-') as priv,
                  coalesce((select string_agg(k, ',' order by k)
                            from jsonb_object_keys(case when jsonb_typeof(payload::jsonb) = 'object' then payload::jsonb else '{}'::jsonb end) k), '-') as keys,
                  left(regexp_replace(regexp_replace(payload::text,
                         '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<uuid>', 'g'),
                         '"nickname": ?"[^"]*"', '"nickname": "<name>"', 'g'), 160) as body,
                  inserted_at::text as at
           from realtime.messages
           where topic like 'kicks:%'
           order by inserted_at desc
           limit 5
         $q$, true, false, '') end as x
),
-- The newest five rows of any other family: keys only, never the payload.
rm_others as (
  select case when (select ok from rm_ok) then query_to_xml($q$
           select regexp_replace(topic, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<uuid>', 'g') as topic,
                  coalesce(event, '-') as ev, coalesce(extension, '-') as ext, coalesce(private::text, '-') as priv,
                  coalesce((select string_agg(k, ',' order by k)
                            from jsonb_object_keys(case when jsonb_typeof(payload::jsonb) = 'object' then payload::jsonb else '{}'::jsonb end) k), '-') as keys,
                  inserted_at::text as at
           from realtime.messages
           where topic not like 'kicks:%'
           order by inserted_at desc
           limit 5
         $q$, true, false, '') end as x
),
rm_parts as (
  select pt.relid, pt.isleaf, c.relname, pg_get_expr(c.relpartbound, c.oid) as bound, c.reltuples,
         pg_total_relation_size(pt.relid) as bytes
  from pg_partition_tree(to_regclass('realtime.messages')) pt
  join pg_class c on c.oid = pt.relid
  where pt.isleaf
),
cron_jobs as (
  select case when to_regclass('cron.job') is not null then query_to_xml($q$
           select jobid, coalesce(jobname, '(no name)') as name, schedule, command, active::text as active
           from cron.job order by jobid
         $q$, true, false, '') end as x
),
rt_migr as (
  select case when to_regclass('realtime.schema_migrations') is not null then query_to_xml($q$
           select coalesce(max(version)::text, '-') as v, count(*) as n from realtime.schema_migrations
         $q$, true, false, '') end as x
),
xs as (
  select (xpath('/table/row/n/text()', s.x))[1]::text as n,
         (xpath('/table/row/oldest/text()', s.x))[1]::text as oldest,
         (xpath('/table/row/newest/text()', s.x))[1]::text as newest,
         (xpath('/table/row/kicks/text()', s.x))[1]::text as kicks,
         (xpath('/table/row/oldest_kick/text()', s.x))[1]::text as oldest_kick,
         (xpath('/table/row/newest_kick/text()', s.x))[1]::text as newest_kick,
         (xpath('/table/row/older_than_1h/text()', s.x))[1]::text as older_1h,
         (xpath('/table/row/older_than_1d/text()', s.x))[1]::text as older_1d
  from rm_stats s
),
facts as (
  select
    to_regclass('realtime.messages') is not null as has_table,
    (select ok from rm_ok) as readable,
    coalesce(has_table_privilege(current_user, to_regclass('realtime.messages'), 'DELETE'), false) as can_delete,
    coalesce((select x.kicks from xs x), '0') <> '0' as kicks_stored,
    to_regprocedure('realtime.send(jsonb, text, text, boolean)') is not null as has_send,
    (select count(*) from rm_parts) as leaves,
    (select r.relkind = 'p' from rm r) as partitioned
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== 01 messages ==============================================================
  select 1 as s, 0 as o, '01 messages'::text as section, 'realtime.messages: kind / persistence / RLS / forced / owner'::text as item,
         coalesce((select case r.relkind when 'p' then 'partitioned' when 'r' then 'regular table' else r.relkind::text end
                          || ' / ' || case r.relpersistence when 'u' then 'UNLOGGED' when 'p' then 'logged' else r.relpersistence::text end
                          || ' / RLS ' || r.relrowsecurity::text || ' / forced ' || r.relforcerowsecurity::text
                          || ' / owner ' || pg_get_userbyid(r.relowner)::text
                   from rm r), '(missing)')::text as value,
         case when to_regclass('realtime.messages') is null then 'STOP: no realtime.messages; Realtime Authorization is not set up'
              else 'INFO: Realtime (not our SQL) owns and manages this table' end::text as note

  union all
  select 1, 1, '01 messages', 'columns', coalesce((select c.list from rm_cols c), '(none)'),
         case when (select c.ok from rm_cols c) then 'INFO: topic, event, extension, payload, private and inserted_at present (the data rows below can be read)'
              else 'FLAG: one of topic, event, extension, payload, private, inserted_at is missing: the data rows say (not read)' end

  union all
  select 1, 2, '01 messages', 'index ' || i.indexname::text, i.indexdef::text, 'INFO'
  from pg_indexes i
  where i.schemaname = 'realtime' and i.tablename = 'messages'

  union all
  select 1, 10 + (row_number() over (order by p.relname))::int, '01 messages', 'partition ' || p.relname::text,
         coalesce(p.bound, '(not a partition)') || ' | est. rows ' || greatest(p.reltuples, 0)::bigint::text || ' | ' || pg_size_pretty(p.bytes),
         'INFO: Realtime creates and drops these itself (its own retention), not a pg_cron job of ours'
  from rm_parts p

  union all
  select 1, 3, '01 messages', 'partitions (leaf count) / total size',
         (select f.leaves::text from facts f) || ' / ' || pg_size_pretty(coalesce((select sum(p.bytes) from rm_parts p), 0)::bigint),
         'INFO: the oldest partition''s lower bound is how far back Realtime keeps messages today'

  union all
  select 1, 4, '01 messages', 'rows (exact) / oldest inserted_at / newest inserted_at',
         case when not (select ok from rm_ok) then '(not read: missing column or no SELECT for ' || current_user || ')'
              else (select x.n || ' / ' || x.oldest || ' / ' || x.newest from xs x) end,
         'INFO: newest minus oldest is how long a stored broadcast really stays'

  union all
  select 1, 5, '01 messages', 'rows older than 1 hour / older than 1 day',
         case when not (select ok from rm_ok) then '(not read)' else (select x.older_1h || ' / ' || x.older_1d from xs x) end,
         'INFO: Walt''s chat retention target is at most one hour'

  union all
  select 1, 6, '01 messages', 'kick notices stored (topic kicks:%) / oldest / newest',
         case when not (select ok from rm_ok) then '(not read)' else (select x.kicks || ' / ' || x.oldest_kick || ' / ' || x.newest_kick from xs x) end,
         case when not (select ok from rm_ok) then ''
              when (select f.kicks_stored from facts f) then 'INFO: realtime.send DOES leave a row (M3''s kick notices are stored)'
              else 'FLAG: no kick rows: either no kick happened yet, or they are already gone (compare with the oldest partition)' end

  union all
  select 1, 20 + (row_number() over ())::int, '01 messages', 'rows by family: ' || coalesce((xpath('/row/fam/text()', r))[1]::text, '') || ' / '
           || coalesce((xpath('/row/ev/text()', r))[1]::text, '') || ' / ' || coalesce((xpath('/row/ext/text()', r))[1]::text, '')
           || ' / private ' || coalesce((xpath('/row/priv/text()', r))[1]::text, ''),
         coalesce((xpath('/row/n/text()', r))[1]::text, '0') || ' rows, ' || coalesce((xpath('/row/oldest/text()', r))[1]::text, '-')
           || ' .. ' || coalesce((xpath('/row/newest/text()', r))[1]::text, '-'),
         'INFO: browser-to-browser chat (today''s chat:<table>:<sender>) is expected NOT to appear here'
  from rm_families f, unnest(xpath('/table/row', f.x)) r

  union all
  select 1, 50 + (row_number() over ())::int, '01 messages', 'kick sample: ' || coalesce((xpath('/row/topic/text()', r))[1]::text, ''),
         'event ' || coalesce((xpath('/row/ev/text()', r))[1]::text, '') || ' | extension ' || coalesce((xpath('/row/ext/text()', r))[1]::text, '')
           || ' | private ' || coalesce((xpath('/row/priv/text()', r))[1]::text, '') || ' | keys ' || coalesce((xpath('/row/keys/text()', r))[1]::text, '')
           || ' | at ' || coalesce((xpath('/row/at/text()', r))[1]::text, '') || ' | payload ' || coalesce((xpath('/row/body/text()', r))[1]::text, ''),
         'INFO: masked (uuids and nicknames), cut to 160 characters'
  from rm_kicks k, unnest(xpath('/table/row', k.x)) r

  union all
  select 1, 60 + (row_number() over ())::int, '01 messages', 'other sample: ' || coalesce((xpath('/row/topic/text()', r))[1]::text, ''),
         'event ' || coalesce((xpath('/row/ev/text()', r))[1]::text, '') || ' | extension ' || coalesce((xpath('/row/ext/text()', r))[1]::text, '')
           || ' | private ' || coalesce((xpath('/row/priv/text()', r))[1]::text, '') || ' | keys ' || coalesce((xpath('/row/keys/text()', r))[1]::text, '')
           || ' | at ' || coalesce((xpath('/row/at/text()', r))[1]::text, ''),
         'INFO: keys only, never the payload'
  from rm_others o, unnest(xpath('/table/row', o.x)) r

  union all
  -- ==== 02 policies ==============================================================
  select 2, (row_number() over (order by pol.policyname))::int, '02 policies', 'policy "' || pol.policyname || '"',
         pol.cmd || ' | ' || pol.permissive || ' | to ' || pol.roles::text || ' | using: ' || coalesce(pol.qual, '-')
           || ' | with check: ' || coalesce(pol.with_check, '-'),
         case when pol.policyname in ('table chat: members receive', 'table chat: members send') then 'INFO: table-chat.sql / spectator-chat.sql'
              when pol.policyname = 'table kicks: people at the table receive' then 'INFO: moderation M3'
              else 'FLAG: not one of ours; policies are OR''ed' end
  from pg_policies pol
  where pol.schemaname = 'realtime' and pol.tablename = 'messages'

  union all
  select 2, 0, '02 policies', 'policies on realtime.messages (count)',
         (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages')::text,
         'INFO: 3 expected today (two chat, one kicks); M5 adds its own and later retires the chat pair'

  union all
  -- ==== 03 functions =============================================================
  select 3, (row_number() over (order by p.oid::regprocedure::text))::int, '03 functions', p.oid::regprocedure::text,
         'returns ' || pg_get_function_result(p.oid) || ' | ' || case when p.prosecdef then 'security definer' else 'invoker' end
           || ' | owner ' || pg_get_userbyid(p.proowner)::text
           || ' | ' || current_user || ' EXECUTE ' || has_function_privilege(current_user, p.oid, 'EXECUTE')::text
           || ' | authenticated EXECUTE ' || coalesce(has_function_privilege('authenticated', p.oid, 'EXECUTE')::text, '?'),
         case when p.proname in ('send', 'broadcast_changes', 'topic') then 'INFO: M5 would use this' else 'INFO' end
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'realtime'

  union all
  -- ==== 04 publish ===============================================================
  select 4, 0, '04 publish', 'publication supabase_realtime: insert / update / delete / truncate / via root',
         coalesce((select pb.pubinsert::text || ' / ' || pb.pubupdate::text || ' / ' || pb.pubdelete::text || ' / ' || pb.pubtruncate::text
                          || ' / ' || pb.pubviaroot::text
                   from pg_publication pb where pb.pubname = 'supabase_realtime'), '(no publication)'),
         'INFO: postgres_changes reads this; M5 slice (a)/(b) would take tables OUT of it at the end'

  union all
  select 4, (row_number() over (order by pt.schemaname, pt.tablename))::int, '04 publish', 'table ' || pt.schemaname::text || '.' || pt.tablename::text,
         'columns ' || coalesce(array_to_string(pt.attnames, ','), '(all)') || ' | row filter ' || coalesce(pt.rowfilter, '(none)')
           || ' | replica identity ' || coalesce((select case c.relreplident when 'd' then 'default (primary key)' when 'f' then 'FULL'
                                                                         when 'n' then 'nothing' when 'i' then 'index' else c.relreplident::text end
                                                  from pg_class c where c.oid = (quote_ident(pt.schemaname) || '.' || quote_ident(pt.tablename))::regclass), '?'),
         case when pt.tablename = 'table_members' then 'INFO: its DELETE events carry (table_id, user_id) to any subscriber: RLS is not applied to deletes (the leak M5 removes)'
              when pt.tablename = 'profiles' then 'INFO: published, but the table screen has no profiles listener'
              else 'INFO' end
  from pg_publication_tables pt
  where pt.pubname = 'supabase_realtime'

  union all
  -- ==== 05 cron ==================================================================
  select 5, 0, '05 cron', 'pg_cron installed', (to_regclass('cron.job') is not null)::text,
         case when to_regclass('cron.job') is null then 'FLAG: Plan B''s cleanup job needs pg_cron' else 'INFO' end

  union all
  select 5, (row_number() over ())::int, '05 cron', 'job ' || coalesce((xpath('/row/jobid/text()', r))[1]::text, '?') || ' ' || coalesce((xpath('/row/name/text()', r))[1]::text, ''),
         coalesce((xpath('/row/schedule/text()', r))[1]::text, '') || ' | active ' || coalesce((xpath('/row/active/text()', r))[1]::text, '')
           || ' | ' || left(coalesce((xpath('/row/command/text()', r))[1]::text, ''), 160),
         case when coalesce((xpath('/row/command/text()', r))[1]::text, '') ilike '%realtime%' then 'FLAG: touches realtime'
              else 'INFO: does not touch realtime' end
  from cron_jobs j, unnest(xpath('/table/row', j.x)) r

  union all
  select 5, 99, '05 cron', 'a retention job for realtime.messages of OURS',
         case when to_regclass('cron.job') is null then '(no pg_cron)'
              else (select count(*)::text from unnest(xpath('/table/row/command/text()', (select j.x from cron_jobs j))) c(t) where c.t::text ilike '%realtime%') || ' job(s)' end,
         'INFO: none expected; Realtime drops its own old partitions (01 shows how far back they go)'

  union all
  -- ==== 06 access ================================================================
  select 6, 1, '06 access', current_user || ' on realtime.messages: SELECT / INSERT / UPDATE / DELETE / TRUNCATE',
         case when to_regclass('realtime.messages') is null then '(missing)'
              else has_table_privilege(current_user, to_regclass('realtime.messages'), 'SELECT')::text || ' / '
                   || has_table_privilege(current_user, to_regclass('realtime.messages'), 'INSERT')::text || ' / '
                   || has_table_privilege(current_user, to_regclass('realtime.messages'), 'UPDATE')::text || ' / '
                   || has_table_privilege(current_user, to_regclass('realtime.messages'), 'DELETE')::text || ' / '
                   || has_table_privilege(current_user, to_regclass('realtime.messages'), 'TRUNCATE')::text end,
         'INFO: this role owns our security definer functions; SELECT lets one read a stored broadcast, DELETE lets a job shorten retention'

  union all
  select 6, 0, '06 access', current_user || ': superuser / bypasses RLS / owns realtime.messages',
         (select r.rolsuper::text || ' / ' || r.rolbypassrls::text from pg_roles r where r.rolname = current_user)
           || ' / ' || coalesce((select (pg_get_userbyid(m.relowner) = current_user)::text from rm m), '?'),
         'INFO: if all three are false, RLS hides realtime.messages rows from this role (the policies are for authenticated), so 01''s counts read 0 even when rows exist -- read them as the owner instead'

  union all
  select 6, 2, '06 access', r.rolname::text || ' on realtime.messages: SELECT / INSERT / UPDATE / DELETE',
         case when to_regclass('realtime.messages') is null then '(missing)'
              else has_table_privilege(r.rolname, to_regclass('realtime.messages'), 'SELECT')::text || ' / '
                   || has_table_privilege(r.rolname, to_regclass('realtime.messages'), 'INSERT')::text || ' / '
                   || has_table_privilege(r.rolname, to_regclass('realtime.messages'), 'UPDATE')::text || ' / '
                   || has_table_privilege(r.rolname, to_regclass('realtime.messages'), 'DELETE')::text end,
         'INFO: authenticated needs SELECT (and INSERT for client sends) for Realtime Authorization; the policies decide the rows'
  from pg_roles r
  where r.rolname in ('anon', 'authenticated', 'service_role')

  union all
  select 6, 3, '06 access', 'authenticator role settings (PostgREST exposed schemas)',
         coalesce((select array_to_string(r.rolconfig, ' | ') from pg_roles r where r.rolname = 'authenticator'), '(none set on the role)'),
         'INFO: if pgrst.db_schemas is not listed here it is set in the dashboard (API settings); realtime must NOT be exposed, or clients could read realtime.messages through the Data API under these policies'

  union all
  -- ==== 07 versions ==============================================================
  select 7, (row_number() over (order by e.extname))::int, '07 versions', 'extension ' || e.extname::text, e.extversion::text, 'INFO'
  from pg_extension e

  union all
  select 7, 99, '07 versions', 'realtime.schema_migrations: latest version / count',
         coalesce((select (xpath('/table/row/v/text()', m.x))[1]::text || ' / ' || (xpath('/table/row/n/text()', m.x))[1]::text from rt_migr m), '(no table)'),
         'INFO: roughly which Realtime release set up this schema'

  union all
  select 7, 100, '07 versions', 'server version', current_setting('server_version'), 'INFO'

  union all
  -- ==== 08 dashboard ==============================================================
  select 8, 1, '08 dashboard', 'Realtime settings not visible from SQL',
         'read in Dashboard -> Project Settings -> Realtime',
         'INFO: "Allow public access" (private-only channels), max concurrent clients, max events per second per tenant, max channels per client, max joins per second, max bytes per second; and the plan''s spend cap (Pro: about 500 msg/s and 500 connections with the cap ON)'

  union all
  select 8, 2, '08 dashboard', 'how long Realtime keeps realtime.messages',
         'not a setting we can read here',
         'INFO: Realtime''s own janitor creates daily partitions and drops old ones; 01''s oldest partition and oldest inserted_at show the real figure on this project'

  union all
  -- ==== 09 verdict ===============================================================
  select 9, 1, '09 verdict', 'Plan A viable? (keep recent chat in realtime.messages)',
         case
           when not (select f.has_table from facts f) then 'NO: no realtime.messages'
           when not (select f.has_send from facts f) then 'NO: no realtime.send'
           when not (select f.readable from facts f) then 'NO (as things stand): ' || current_user || ' cannot read the rows (or a column is missing)'
           when not (select f.kicks_stored from facts f) then 'UNKNOWN: readable, but no stored kick notice to prove a realtime.send row stays'
           when not (select f.can_delete from facts f) then 'PARTLY: rows are stored and readable, but ' || current_user || ' cannot DELETE them, so retention cannot be cut to 1 hour'
           else 'POSSIBLE: rows are stored and readable, and ' || current_user || ' may DELETE them'
         end,
         'Sender and topic: only what realtime.send was given -- the topic, event and payload; Realtime adds no sender. So a chat RPC must put the sender id in the payload itself (set by the server, so it can be trusted). Retention: Realtime''s own (01: oldest vs newest), NOT one hour -- keeping chat to an hour would mean deleting from a table Realtime owns and manages, which may be refused or undone by upgrades. Every realtime.send stores its payload there whatever we choose.'

  union all
  select 9, 2, '09 verdict', 'Plan B needed? (our own message table, cleaned every ~10 minutes)',
         case
           when not (select f.readable from facts f) then 'YES: Plan A cannot even read the stored rows'
           when not (select f.can_delete from facts f) then 'YES: Plan A cannot meet the one-hour limit'
           else 'LIKELY: even where Plan A is possible, our own table gives us the retention, the indexes and the grants'
         end,
         'Either way realtime.send keeps a copy of each payload for Realtime''s own retention. To keep message TEXT for at most one hour, the broadcast should carry only the message id (and sender id, time, version) and clients fetch the text from our table through an RPC -- or we accept Realtime''s copy and say so in the privacy note. Decide before slice (c).'
) z
order by z.s, z.o, z.item;
