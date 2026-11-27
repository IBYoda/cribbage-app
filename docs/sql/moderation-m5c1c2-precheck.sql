-- Moderation, slice M5c1 (c2): PRECHECK for REMOVING THE OLD CHAT
-- PERMISSIONS (READ-ONLY). Run in the Supabase Dashboard -> SQL Editor
-- before docs/sql/moderation-m5c1c2-part1.sql, and again after it. ONE
-- statement; it only reads the catalog. Paste the whole result back.
--
-- STATUS: written, NOT RUN yet.
--
-- Every row has a section, an item, a value and a note. A note starting
-- "STOP" means: do not run the next file; paste the result back. The first
-- row ("state") says where c2 stands:
--   before part 1   -> run moderation-m5c1c2-part1.sql next
--   part 1 present  -> c2 is in (part 1 is the only part)
--   a mixed state   -> STOP
--
-- WHAT PART 1 REMOVES: the policies "table chat: members receive" and
-- "table chat: members send" on realtime.messages (table-chat.sql) and
-- public.chat_topic_allows(text, boolean) (spectator-chat.sql's body). The
-- target section shows, before part 1, that they are exactly the files'
-- (so the rollback restores them exactly) and that nothing else uses the
-- function.
--
-- SUITES AFTER PART 1:
--   RE-RUN: moderation-m5c1c2-verification.sql (this slice's own);
--   slice-e-grants-verification.sql (X1: 60 names, chat_topic_allows gone);
--   moderation-m1-verification.sql, moderation-m2-verification.sql and
--   moderation-m3-verification.sql (their fingerprint lists skip
--   chat_topic_allows once c2 is in; M3's K4 then wants no table-chat
--   policy); moderation-m5a-verification.sql, -m5b1-, -m5b2-verification.sql,
--   computer-c1 / computer-c2 / end-empty-tables-verification.sql (no body
--   they fingerprint changes); the re-baselined prechecks (moderation-m3,
--   -m5a, -m5b1, -m5b2, -m5c1-precheck.sql) and moderation-catalog.sql if you
--   want their rows green (2 policies, 60 functions).
--   RETIRED (they test the removed path; they now stop at SETUP):
--   table-chat-verification.sql, table-chat-precheck.sql,
--   spectator-chat-verification.sql, spectator-chat-precheck.sql.
--   SUPERSEDED: moderation-m5c1-verification.sql (it compares with
--   chat_topic_allows; it now stops at SETUP and points here).
--   Not phase3-e1 / phase3-e4 (known stale, by design).
--
-- SECTIONS
--   state     the summary above.
--   fp        bodies other suites fingerprint, unchanged by c2.
--   needs     moderation M5c1 part 1 (send_table_message) and its helper.
--   target    the two policies (as table-chat.sql wrote them), the
--             function (spectator-chat.sql's body, its grants), and anything
--             else that uses it (expected: nothing) -- a function counts
--             only if its body, comments removed, CALLS chat_topic_allows(.
--   realtime  every policy on realtime.messages, with what it should be
--             after part 1; the count (4 before, 2 after); write policies.
--   grants    functions authenticated may execute (61 before, 60 after).

with fp_lf(o, fn, sig, lf, src) as (
  values
    (1, 'send_table_message', 'public.send_table_message(uuid, text)', 'e3adcc4874c77c1c47530a807fefd815', 'moderation-m5c1-part1.sql'),
    (2, '_broadcast_table_message', 'public._broadcast_table_message(text, jsonb)', 'e5f16aebb3ca764c806e2567b68090fc', 'moderation-m5c1-part1.sql'),
    (3, 'table_topic_allows', 'public.table_topic_allows(text)', '57908d750db883e7687b926cbea3ab4a', 'moderation-m5a-part1.sql'),
    (4, 'kick_topic_allows', 'public.kick_topic_allows(text)', '48327bb75cf98b6ff91388a6db843d11', 'moderation-m3-part1.sql'),
    (5, 'kick_player', 'public.kick_player(uuid, uuid)', 'd859deb84acb67ec94a2cf65fb1f38f0', 'moderation-m3-part1.sql'),
    (6, '_is_kicked_from_table', 'public._is_kicked_from_table(uuid, uuid)', 'c8372af51a4537ca9cc079234487a414', 'moderation-m3-part1.sql'),
    (7, 'get_table_spectators', 'public.get_table_spectators(uuid)', '0df2ddd114957a157cd688faa17ff209', 'spectator-chat.sql (STAYS: the app''s spectator list)'),
    (8, '_send_table_event', 'public._send_table_event(uuid, text, bigint)', 'df40bb9eac9b778a8d733d2d18393865', 'moderation-m5a-part1.sql'),
    (9, '_game_event_at_commit', 'public._game_event_at_commit()', 'cce9d688120f3dc2c155503270fe11ee', 'moderation-m5b1-part1.sql'),
    (10, '_scores_event_at_commit', 'public._scores_event_at_commit()', 'd06cc5e9fb12f0b0697dd4b4e43bd8a9', 'moderation-m5b2-part1.sql')
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
rt_pol as (
  select p.policyname::text as name, p.cmd::text as cmd, array_to_string(p.roles, ',') as roles,
         p.permissive::text as permissive, p.qual, p.with_check
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
),
old_pol as (
  select count(*) filter (where r.name = 'table chat: members receive' and r.cmd = 'SELECT' and r.roles = 'authenticated'
                            and r.qual ilike '%extension = ''broadcast''%' and r.qual ilike '%chat_topic_allows(%realtime.topic()%false)%'
                            and r.with_check is null) as receive_ok,
         count(*) filter (where r.name = 'table chat: members send' and r.cmd = 'INSERT' and r.roles = 'authenticated'
                            and r.with_check ilike '%extension = ''broadcast''%' and r.with_check ilike '%chat_topic_allows(%realtime.topic()%true)%'
                            and r.qual is null) as send_ok,
         count(*) filter (where r.name in ('table chat: members receive', 'table chat: members send')) as named
  from rt_pol r
),
ctafn as (
  select p.oid, md5(p.prosrc) as m
  from pg_proc p
  where p.oid = to_regprocedure('public.chat_topic_allows(text, boolean)')
),
flags as (
  select (select o.named from old_pol o) as old_n,
         exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                 where ns.nspname = 'public' and p.proname = 'chat_topic_allows') as fn_there
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== state ====================================================================
  select 0 as s, 0 as o, 'state'::text as section, 'c2 state'::text as item,
         ('table-chat policies ' || f.old_n::text || ' of 2 | chat_topic_allows ' || case when f.fn_there then 'present' else 'gone' end)::text as value,
         (case
            when f.old_n = 2 and f.fn_there then 'before part 1: run docs/sql/moderation-m5c1c2-part1.sql next (if no other row says STOP)'
            when f.old_n = 0 and not f.fn_there then 'part 1 present: c2 is in; re-run the suites listed in this file''s header'
            else 'STOP: a mixed state (a policy without the function, or the reverse); paste the whole result back'
          end)::text as note
  from flags f

  union all
  -- ==== fp =======================================================================
  select 1, k.o, 'fp', k.fn || ': md5 of the live body (carriage returns removed)',
         coalesce((select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure(k.sig)), '(missing)'),
         case when (select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure(k.sig)) = k.lf
                then k.src || ': as expected (unchanged by c2)'
              else 'STOP: not ' || k.src || '''s fingerprint (or missing). Capture it first: select pg_get_functiondef(''' || k.sig || '''::regprocedure);' end
  from fp_lf k

  union all
  -- ==== needs ====================================================================
  select 2, 1, 'needs', 'moderation M5c1 part 1: send_table_message / _broadcast_table_message (EXECUTE for authenticated / none)',
         (to_regprocedure('public.send_table_message(uuid, text)') is not null)::text || ' / '
           || (to_regprocedure('public._broadcast_table_message(text, jsonb)') is not null)::text,
         case when to_regprocedure('public.send_table_message(uuid, text)') is not null
                   and to_regprocedure('public._broadcast_table_message(text, jsonb)') is not null
                   and has_function_privilege('authenticated', 'public.send_table_message(uuid, text)', 'EXECUTE')
                   and not has_function_privilege('authenticated', 'public._broadcast_table_message(text, jsonb)', 'EXECUTE')
                then 'as expected: chat goes through the server; the app (PR #141) no longer uses the old path'
              else 'STOP: M5c1 part 1 must be in first' end

  union all
  -- ==== target ===================================================================
  select 3, 1, 'target', 'policy "table chat: members receive": SELECT, authenticated, broadcast, chat_topic_allows(topic, false)',
         (select o.receive_ok from old_pol o)::text,
         case when (select f.old_n from flags f) = 0 then 'after part 1: gone, as expected'
              when (select o.receive_ok from old_pol o) = 1 then 'before part 1: as table-chat.sql wrote it (the rollback restores this)'
              else 'STOP: not as table-chat.sql wrote it; the rollback would not restore it exactly. Paste back: select * from pg_policies where policyname like ''table chat%'';' end

  union all
  select 3, 2, 'target', 'policy "table chat: members send": INSERT, authenticated, broadcast, chat_topic_allows(topic, true)',
         (select o.send_ok from old_pol o)::text,
         case when (select f.old_n from flags f) = 0 then 'after part 1: gone, as expected'
              when (select o.send_ok from old_pol o) = 1 then 'before part 1: as table-chat.sql wrote it (the rollback restores this)'
              else 'STOP: not as table-chat.sql wrote it; the rollback would not restore it exactly' end

  union all
  select 3, 3, 'target', 'chat_topic_allows(text, boolean): md5 of the live body / overloads / authenticated EXECUTE',
         coalesce((select c.m from ctafn c), '(missing)') || ' / '
           || (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'chat_topic_allows')::text
           || ' / ' || coalesce((select has_function_privilege('authenticated', c.oid, 'EXECUTE')::text from ctafn c), '-'),
         case when not (select f.fn_there from flags f) then 'after part 1: gone, as expected'
              when (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'chat_topic_allows') <> 1
                then 'STOP: more than one function named chat_topic_allows'
              when (select c.m from ctafn c) in ('0458d5122d68d511b2e0fbceafe84aae', 'c4e6eda360de7d7723c4069e60d95345')
                   and (select has_function_privilege('authenticated', c.oid, 'EXECUTE') from ctafn c)
                then 'before part 1: spectator-chat.sql''s body (LF 0458d512... / CRLF c4e6eda3...), EXECUTE for authenticated: the rollback restores exactly this'
              else 'STOP: not spectator-chat.sql''s body, or not granted as it left it; capture it first: select pg_get_functiondef(''public.chat_topic_allows(text, boolean)''::regprocedure);' end

  union all
  -- A function "uses" it only when its body, comments removed (-- to the
  -- end of the line, /* ... */), CALLS it: chat_topic_allows followed by
  -- "(". A mention in a comment (send_table_message's "chat_topic_allows'
  -- rules 4-6") is not a use.
  select 3, 4, 'target', 'anything else that uses chat_topic_allows (policies, functions that call it, dependencies)',
         coalesce(
           (select string_agg(x, ', ') from (
              select 'policy ' || p.schemaname || '.' || p.tablename || ' "' || p.policyname || '"' as x
              from pg_policies p
              where (coalesce(p.qual, '') ilike '%chat_topic_allows%' or coalesce(p.with_check, '') ilike '%chat_topic_allows%')
                and not (p.schemaname = 'realtime' and p.tablename = 'messages' and p.policyname in ('table chat: members receive', 'table chat: members send'))
              union all
              select 'function ' || p.oid::regprocedure::text
              from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public' and p.proname <> 'chat_topic_allows'
                and regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', '', 'g'), '--[^\n]*', '', 'g') ~* '\mchat_topic_allows\s*\('
              union all
              select 'depends: ' || d.classid::regclass::text || ' ' || d.objid::text
              from pg_depend d
              where d.refclassid = 'pg_proc'::regclass and d.refobjid = coalesce((select c.oid from ctafn c), 0::oid)
                and d.classid <> 'pg_policy'::regclass and d.deptype in ('n', 'a')) u), '(none)'),
         case when coalesce(
           (select count(*) from pg_policies p
            where (coalesce(p.qual, '') ilike '%chat_topic_allows%' or coalesce(p.with_check, '') ilike '%chat_topic_allows%')
              and not (p.schemaname = 'realtime' and p.tablename = 'messages' and p.policyname in ('table chat: members receive', 'table chat: members send'))), 0)
           + (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public' and p.proname <> 'chat_topic_allows'
                and regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', '', 'g'), '--[^\n]*', '', 'g') ~* '\mchat_topic_allows\s*\(') = 0
                then 'as expected: only the two table-chat policies use it (get_table_spectators STAYS: the app''s spectator list)'
              else 'STOP: something else still uses chat_topic_allows; part 1 would refuse' end

  union all
  -- ==== realtime =================================================================
  select 4, 10 + (row_number() over (order by r.name))::int, 'realtime', 'policy "' || r.name || '"',
         r.cmd || ' to ' || r.roles || ' | using: ' || coalesce(r.qual, '-') || ' | with check: ' || coalesce(r.with_check, '-'),
         case
           when r.name in ('table chat: members receive', 'table chat: members send') then 'part 1 DROPS it'
           when r.name = 'table kicks: people at the table receive' and r.cmd = 'SELECT' then 'STAYS (moderation M3: kicks: topics, receive only)'
           when r.name = 'table events: people at the table receive' and r.cmd = 'SELECT' then 'STAYS (moderation M5a: table: topics, receive only; chat, game and scores events ride it)'
           else 'STOP: unknown policy; policies are OR''ed, look at it first' end
  from rt_pol r

  union all
  select 4, 1, 'realtime', 'policies on realtime.messages (count) / RLS on',
         (select count(*) from rt_pol)::text || ' / '
           || coalesce((select c.relrowsecurity::text from pg_class c where c.oid = to_regclass('realtime.messages')), '(no table)'),
         case
           when not coalesce((select c.relrowsecurity from pg_class c where c.oid = to_regclass('realtime.messages')), false)
             then 'STOP: RLS is off on realtime.messages'
           when (select count(*) from rt_pol) = 4 and (select f.old_n from flags f) = 2
                and (select count(*) from rt_pol r where r.name in ('table kicks: people at the table receive', 'table events: people at the table receive')) = 2
             then 'before part 1: the two table-chat policies, M3''s kicks and M5a''s table events'
           when (select count(*) from rt_pol) = 2
                and (select count(*) from rt_pol r where r.name in ('table kicks: people at the table receive', 'table events: people at the table receive') and r.cmd = 'SELECT') = 2
             then 'after part 1: exactly the kicks and table events policies (receive only)'
           else 'STOP: expected 4 before or 2 after' end

  union all
  select 4, 2, 'realtime', 'write policies on realtime.messages (INSERT / UPDATE / DELETE / ALL)',
         coalesce((select string_agg(r.name || ' (' || r.cmd || ')', ', ') from rt_pol r where r.cmd <> 'SELECT'), '(none)'),
         case when not exists (select 1 from rt_pol r where r.cmd <> 'SELECT') then 'after part 1: none, as expected -- no client can send on any private topic'
              when (select string_agg(r.name, ',') from rt_pol r where r.cmd <> 'SELECT') = 'table chat: members send' then 'before part 1: only the chat send, which part 1 drops'
              else 'STOP: an unexpected write policy' end

  union all
  -- ==== grants ===================================================================
  select 5, 1, 'grants', 'functions authenticated may execute in public (distinct names)',
         (select count(*) from client_fns)::text,
         case
           when (select count(*) from client_fns) = 61 and exists (select 1 from client_fns cf where cf.name = 'chat_topic_allows')
                and exists (select 1 from client_fns cf where cf.name = 'send_table_message')
             then 'before part 1: 61 (with chat_topic_allows and send_table_message)'
           when (select count(*) from client_fns) = 60 and not exists (select 1 from client_fns cf where cf.name = 'chat_topic_allows')
                and exists (select 1 from client_fns cf where cf.name = 'send_table_message')
             then 'after part 1: 60 (chat_topic_allows gone)'
           else 'STOP: neither 61 nor 60 (slice-e-grants-verification.sql X1 would fail)' end
) z
order by z.s, z.o, z.item;
