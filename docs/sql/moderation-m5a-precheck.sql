-- Moderation, slice M5 (a): PRECHECK for TABLE AND SPECTATOR EVENTS
-- (READ-ONLY). Run in the Supabase Dashboard -> SQL Editor before
-- docs/sql/moderation-m5a-part1.sql. ONE statement; it only reads the
-- catalog and counts rows. Paste the whole result back.
--
-- STATUS: written, NOT RUN yet.
--
-- UPDATED FOR MODERATION M7 (docs/sql/moderation-m7-part1.sql): the grants
-- row also accepts 61 with admin_report_chat (the 60 left by moderation
-- M5c1 c2 plus M7's admin RPC; never _report_table_chat).
--
-- Every row has a section, an item, a value and a note. A note starting
-- "STOP" means: do not run the next file; paste the result back. The first
-- row ("state") says where M5a stands:
--   before part 1       -> run moderation-m5a-part1.sql next
--   part 1 present      -> M5a is in (part 1 is the only part)
--   a mixed state       -> STOP
--
-- M5a REPLACES NO EXISTING FUNCTION. The fp section only proves the two
-- helpers the new receive rule calls (is_table_member,
-- is_current_spectator) are private-tables-part1.sql's bodies.
--
-- SUITES TO RE-BASELINE once part 1 is in (they pin what M5a changes; none
-- is changed by this slice's files):
--   * policies on realtime.messages (3 -> 4: the new "table events: people
--     at the table receive"), where an unknown policy is a FAIL or STOP:
--       moderation-m3-verification.sql K4, moderation-m3-precheck.sql
--       (realtime rows and the count), table-chat-verification.sql C3,
--       spectator-chat-verification.sql C4 (and their "(plus ...)" verdict
--       text), spectator-chat-precheck.sql (the count row),
--       moderation-catalog.sql section 01 (the policy notes and count);
--       table-chat-precheck.sql's count note is informational only.
--   * functions authenticated may execute (59 -> 60: table_topic_allows):
--       slice-e-grants-verification.sql X1 (and its SETUP count),
--       moderation-m1-precheck.sql, moderation-m3-precheck.sql and
--       moderation-m6-precheck.sql (their grants rows).
--   * unaffected (state-aware already): moderation-m6-verification.sql C19
--     (at least 59), phase3-hardening-grants-verification.sql I4 (every
--     tables column but the six is refused on INSERT: roster_version is
--     covered automatically), the trigger checks in end-empty-tables-*,
--     phase3-e1-seating-verification.sql and free-codes-* (they look for
--     their own triggers by name).
--
-- SECTIONS
--   state     the summary above.
--   fp        md5 of is_table_member and is_current_spectator; a reminder
--             row that M5a replaces nothing.
--   needs     M3 (kick_topic_allows) and M6 (player_reports);
--             realtime.messages (RLS on) and realtime.send; how many leaf
--             partitions realtime.messages has (none: the verification's
--             stored-event checks are skipped).
--   part1     tables.roster_version (absent before; after: bigint not null
--             default 0); the five functions (absent before; after: part
--             1's bodies, security definer, search_path '', who may execute
--             them); the three triggers (absent before; after: AFTER, ROW,
--             their events, enabled).
--   triggers  every user trigger on table_members, table_spectators and
--             tables, in firing order, with a STOP for any AFTER trigger
--             that would sort after part 1's.
--   realtime  every policy on realtime.messages (the two table-chat ones
--             and M3's kicks policy before; plus part 1's after; anything
--             else is a STOP); the three tables' place in the
--             supabase_realtime publication (they STAY in it).
--   grants    how many functions authenticated may execute in public: 59
--             before part 1, 60 after (plus table_topic_allows); 61 once
--             moderation M5c1 part 1 is in (plus send_table_message); 60
--             again after moderation M5c1 c2 (chat_topic_allows removed).
--   load      open tables, seats and spectator rows today, and how many
--             spectator heartbeats a minute would reach the trigger (none of
--             them send anything unless the spectator was stale).

with new_fns(o, name, sig, lf, client) as (
  values
    (1, '_send_table_event', 'public._send_table_event(uuid, text, bigint)', 'df40bb9eac9b778a8d733d2d18393865', false),
    (2, '_table_event_on_members', 'public._table_event_on_members()', '26f95e1c2dd4cb5cffbb8e784367cd92', false),
    (3, '_table_event_on_spectators', 'public._table_event_on_spectators()', 'f81c329f92115ea11038cff9f0ffc184', false),
    (4, '_table_event_on_tables', 'public._table_event_on_tables()', 'd950c48b22205b15e62e38411923fef5', false),
    (5, 'table_topic_allows', 'public.table_topic_allows(text)', '57908d750db883e7687b926cbea3ab4a', true)
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
new_trg(o, rel, name, fn, events) as (
  values
    (1, 'public.table_members', 'table_members_zz_table_event', 'public._table_event_on_members()', 'INSERT DELETE UPDATE'),
    (2, 'public.table_spectators', 'table_spectators_zz_table_event', 'public._table_event_on_spectators()', 'INSERT DELETE UPDATE'),
    (3, 'public.tables', 'tables_zz_table_event', 'public._table_event_on_tables()', 'UPDATE')
),
trg_desc as (
  select tg.oid, tg.tgrelid, tg.tgname, tg.tgfoid, tg.tgenabled, tg.tgtype,
         case when (tg.tgtype & 2) = 2 then 'BEFORE' when (tg.tgtype & 64) = 64 then 'INSTEAD OF' else 'AFTER' end as timing,
         trim(case when (tg.tgtype & 4) = 4 then 'INSERT ' else '' end
              || case when (tg.tgtype & 8) = 8 then 'DELETE ' else '' end
              || case when (tg.tgtype & 16) = 16 then 'UPDATE ' else '' end) as events,
         case when (tg.tgtype & 1) = 1 then 'ROW' else 'STATEMENT' end as level
  from pg_trigger tg
  where not tg.tgisinternal
    and tg.tgrelid in ('public.table_members'::regclass, 'public.table_spectators'::regclass, 'public.tables'::regclass)
),
new_trg_state as (
  select t.o, t.rel, t.name, t.fn, t.events,
         d.oid as tg_oid,
         d.timing = 'AFTER' and d.level = 'ROW' and d.events = t.events and d.tgenabled = 'O'
           and d.tgfoid = to_regprocedure(t.fn) and d.tgrelid = to_regclass(t.rel) as ok
  from new_trg t
  left join trg_desc d on d.tgname = t.name and d.tgrelid = to_regclass(t.rel)
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
    exists (select 1 from pg_attribute a where a.attrelid = 'public.tables'::regclass and a.attname = 'roster_version' and not a.attisdropped) as p1_col,
    (select count(*) from new_fn_state n where n.fn_oid is not null) as p1_fns,
    (select count(*) from new_trg_state t where t.tg_oid is not null) as p1_trg,
    exists (select 1 from rt_pol r where r.name = 'table events: people at the table receive') as p1_policy
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== state ====================================================================
  select 0 as s, 0 as o, 'state'::text as section, 'M5a state'::text as item,
         ('tables.roster_version ' || f.p1_col::text || ' | M5a functions ' || f.p1_fns::text || ' of 5 | triggers '
          || f.p1_trg::text || ' of 3 | table events policy ' || f.p1_policy::text)::text as value,
         (case
            when not f.p1_col and f.p1_fns = 0 and f.p1_trg = 0 and not f.p1_policy
              then 'before part 1: run docs/sql/moderation-m5a-part1.sql next (if no other row says STOP)'
            when f.p1_col and f.p1_fns = 5 and f.p1_trg = 3 and f.p1_policy
              then 'part 1 present: M5a is in; re-baseline the suites listed in this file''s header'
            else 'STOP: a mixed state (some of part 1 without the rest); paste the whole result back'
          end)::text as note
  from flags f

  union all
  -- ==== fp =======================================================================
  select 1, k.o, 'fp', k.fn || ': md5 of the live body',
         coalesce((select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(k.sig)), '(missing)'),
         case (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(k.sig))
              when k.lf then 'private-tables-part1.sql, LF: as expected (the receive rule calls it)'
              when k.crlf then 'private-tables-part1.sql, CRLF: as expected (the receive rule calls it)'
              else 'STOP: not private-tables-part1.sql''s text (or missing). Capture it first: select pg_get_functiondef(''' || k.sig || '''::regprocedure);' end
  from (values
          (1, 'is_table_member', 'public.is_table_member(uuid)', '29383c3018543a5e7faa045a1beee164', 'ef5eb3d1d03b3bee36d51ac7e4880191'),
          (2, 'is_current_spectator', 'public.is_current_spectator(uuid)', '0d6170b3543a18cb6bc71288e0f5edf6', '59ace7c42e8a998aa0a79a1dfa26e970')
       ) as k(o, fn, sig, lf, crlf)

  union all
  select 1, 9, 'fp', 'functions M5a replaces', '(none)',
         'M5a replaces no existing function: it adds a column, five functions, three triggers and one policy'

  union all
  -- ==== needs ====================================================================
  select 2, 1, 'needs', 'moderation M3 (kick_topic_allows) / M6 (player_reports)',
         (to_regprocedure('public.kick_topic_allows(text)') is not null)::text || ' / ' || (to_regclass('public.player_reports') is not null)::text,
         case when to_regprocedure('public.kick_topic_allows(text)') is not null and to_regclass('public.player_reports') is not null
                then 'as expected'
              else 'STOP: M5a builds on M3 and M6 (the policy and grant counts assume both)' end

  union all
  select 2, 2, 'needs', 'realtime.messages: exists / RLS on',
         case when to_regclass('realtime.messages') is null then '(missing)'
              else 'exists / ' || (select c.relrowsecurity::text from pg_class c where c.oid = to_regclass('realtime.messages')) end,
         case when to_regclass('realtime.messages') is null then 'STOP: Realtime Authorization is not set up'
              when not (select c.relrowsecurity from pg_class c where c.oid = to_regclass('realtime.messages')) then 'STOP: RLS is off'
              else 'as expected' end

  union all
  select 2, 3, 'needs', 'realtime.send(jsonb, text, text, boolean): exists / ' || current_user || ' may execute',
         case when to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null then '(missing)'
              else 'exists / ' || has_function_privilege(current_user, 'realtime.send(jsonb, text, text, boolean)', 'EXECUTE')::text end,
         case when to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null
                then 'STOP: the table events need realtime.send'
              when not has_function_privilege(current_user, 'realtime.send(jsonb, text, text, boolean)', 'EXECUTE')
                then 'STOP: this role (which will own the trigger functions) may not call realtime.send'
              else 'as expected' end

  union all
  select 2, 4, 'needs', 'leaf partitions of realtime.messages',
         (select count(*)::text from pg_partition_tree(to_regclass('realtime.messages')) pt where pt.isleaf),
         'INFO: none means realtime.send cannot store an event (the change still goes through: the send is caught); the verification then skips its stored-event checks'

  union all
  -- ==== part1: column ============================================================
  select 3, 1, 'part1', 'public.tables.roster_version',
         coalesce((select format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else ' nullable' end
                          || ' default ' || coalesce(pg_get_expr(ad.adbin, ad.adrelid), '(none)')
                   from pg_attribute a
                   left join pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
                   where a.attrelid = 'public.tables'::regclass and a.attname = 'roster_version' and not a.attisdropped), '(absent)'),
         case
           when not (select f.p1_col from flags f) then 'before part 1: absent, as expected'
           when (select format_type(a.atttypid, a.atttypmod) = 'bigint' and a.attnotnull
                 from pg_attribute a where a.attrelid = 'public.tables'::regclass and a.attname = 'roster_version' and not a.attisdropped)
             then 'after part 1: as part 1 wrote it'
           else 'STOP: a roster_version column part 1 did not write' end

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
  -- ==== part1: triggers ==========================================================
  select 3, 20 + t.o, 'part1', 'trigger ' || t.name || ' on ' || t.rel,
         case when t.tg_oid is null then '(absent)' else 'present, as part 1 wrote it: ' || coalesce(t.ok::text, 'false') end,
         case when t.tg_oid is null then 'before part 1: absent, as expected'
              when t.ok then 'after part 1: AFTER ' || t.events || ', FOR EACH ROW, enabled'
              else 'STOP: a trigger by that name that part 1 did not write' end
  from new_trg_state t

  union all
  -- ==== triggers =================================================================
  select 4, (row_number() over (order by d.tgrelid::regclass::text, d.timing desc, d.tgname))::int, 'triggers',
         d.tgrelid::regclass::text || ': ' || d.tgname::text,
         d.timing || ' ' || d.events || ' ' || d.level || ' -> ' || d.tgfoid::regprocedure::text
           || case when d.tgenabled = 'D' then ' (DISABLED)' else '' end,
         case
           when d.tgname in ('table_members_zz_table_event', 'table_spectators_zz_table_event', 'tables_zz_table_event') then 'part 1''s'
           when d.timing = 'AFTER'
                and ((d.tgrelid = 'public.table_members'::regclass and d.tgname::text > 'table_members_zz_table_event')
                     or (d.tgrelid = 'public.table_spectators'::regclass and d.tgname::text > 'table_spectators_zz_table_event')
                     or (d.tgrelid = 'public.tables'::regclass and d.tgname::text > 'tables_zz_table_event'))
             then 'STOP: this AFTER trigger would fire after part 1''s; part 1''s must sort last'
           else 'INFO: fires before part 1''s (BEFORE triggers are untouched)' end
  from trg_desc d

  union all
  -- ==== realtime =================================================================
  select 5, 10 + (row_number() over (order by r.name))::int, 'realtime', 'policy "' || r.name || '"',
         r.cmd || ' to ' || r.roles || ' | using: ' || coalesce(r.qual, '-') || ' | with check: ' || coalesce(r.with_check, '-'),
         case
           when r.name in ('table chat: members receive', 'table chat: members send') then 'table-chat.sql''s policy: expected'
           when r.name = 'table kicks: people at the table receive' then 'moderation M3''s policy: expected'
           when r.name = 'table events: people at the table receive' then 'part 1''s policy: expected after part 1'
           else 'STOP: unknown policy; policies are OR''ed, look at it first' end
  from rt_pol r

  union all
  select 5, 1, 'realtime', 'policies on realtime.messages (count)',
         (select count(*) from rt_pol)::text,
         case
           when (select count(*) from rt_pol) = 3 and not (select f.p1_policy from flags f)
             then 'before part 1: the two table-chat policies and M3''s kicks policy'
           when (select count(*) from rt_pol) = 4 and (select f.p1_policy from flags f)
             then 'after part 1: plus the table events policy'
           when (select count(*) from rt_pol) = 2 and (select f.p1_policy from flags f) and (to_regprocedure('public.chat_topic_allows(text, boolean)') is null and to_regprocedure('public.send_table_message(uuid, text)') is not null)
             then 'after part 1 and moderation M5c1 c2: the table-chat policies removed; kicks and table events remain'
           else 'STOP: expected 3 (before) or 4 (after; 2 after moderation M5c1 c2)' end

  union all
  select 5, 2, 'realtime', 'publication supabase_realtime: table_members / table_spectators / tables',
         (exists (select 1 from pg_publication_tables pt where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = 'table_members'))::text
           || ' / ' || (exists (select 1 from pg_publication_tables pt where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = 'table_spectators'))::text
           || ' / ' || (exists (select 1 from pg_publication_tables pt where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = 'tables'))::text,
         'INFO: they STAYED in the publication in this slice; the M5 final cleanup (moderation-m5-cleanup-part1.sql) takes table_members and tables out (false is then expected; table_spectators is never published)'

  union all
  -- ==== grants ===================================================================
  select 6, 1, 'grants', 'functions authenticated may execute in public (distinct names)',
         (select count(*) from client_fns)::text,
         case
           when (select count(*) from client_fns) = 61
                and exists (select 1 from client_fns cf where cf.name = 'admin_report_chat')
                and exists (select 1 from client_fns cf where cf.name = 'send_table_message')
                and not exists (select 1 from client_fns cf where cf.name in ('chat_topic_allows', '_report_table_chat'))
             then 'after moderation M7 part 1: the 60 (moderation M5c1 c2) plus admin_report_chat (61)'
           when (select count(*) from client_fns) = 59 and not exists (select 1 from client_fns cf where cf.name = 'table_topic_allows')
             then 'before part 1: 59 (slice E''s 49, M1''s 3, M2''s 1, M3''s 3, M6''s 3)'
           when (select count(*) from client_fns) = 60
                and not exists (select 1 from client_fns cf where cf.name = 'chat_topic_allows')
                and exists (select 1 from client_fns cf where cf.name = 'send_table_message')
             then 'after moderation M5c1 c2: the 61 without chat_topic_allows (60)'
           when (select count(*) from client_fns) = 60 and exists (select 1 from client_fns cf where cf.name = 'table_topic_allows')
             then 'after part 1: the 59 plus table_topic_allows'
           when (select count(*) from client_fns) = 61 and exists (select 1 from client_fns cf where cf.name = 'table_topic_allows')
                and exists (select 1 from client_fns cf where cf.name = 'send_table_message')
             then 'after part 1 and moderation M5c1 part 1: the 60 plus send_table_message'
           else 'STOP: neither 59, 60 nor 61 (or 61 with admin_report_chat once moderation M7 part 1 is in; slice-e-grants-verification.sql X1 would fail)' end

  union all
  -- ==== load =====================================================================
  select 7, 1, 'load', 'open tables / seats at them / spectator rows at them (current, removed)',
         (select count(*) from public.tables t where t.status = 'open')::text
           || ' / ' || (select count(*) from public.table_members tm join public.tables t on t.id = tm.table_id where t.status = 'open')::text
           || ' / ' || (select count(*) filter (where ts.removed_at is null and ts.last_seen_at > now() - interval '90 seconds')
                        from public.table_spectators ts join public.tables t on t.id = ts.table_id where t.status = 'open')::text
           || ', ' || (select count(*) filter (where ts.removed_at is not null)
                       from public.table_spectators ts join public.tables t on t.id = ts.table_id where t.status = 'open')::text,
         'INFO: every current spectator heartbeats about twice a minute; each one fires the spectators trigger, which returns at once (no update, no send) unless they were stale'
) z
order by z.s, z.o, z.item;
