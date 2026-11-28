-- Moderation, slice M5 (c1): PRECHECK for CHAT THROUGH THE SERVER
-- (READ-ONLY). Run in the Supabase Dashboard -> SQL Editor before
-- docs/sql/moderation-m5c1-part1.sql, and again after it. ONE statement; it
-- only reads the catalog. Paste the whole result back.
--
-- STATUS: written, NOT RUN yet.
--
-- UPDATED FOR MODERATION M7 (docs/sql/moderation-m7-part1.sql): the grants
-- row also accepts 61 with admin_report_chat (the 60 left by moderation
-- M5c1 c2 plus M7's admin RPC; never _report_table_chat).
--
-- Every row has a section, an item, a value and a note. A note starting
-- "STOP" means: do not run the next file; paste the result back. "FLAG"
-- means: part 1 can run, but read the note. The first row ("state") says
-- where M5c1 stands:
--   before part 1       -> run moderation-m5c1-part1.sql next
--   part 1 present      -> M5c1 is in (part 1 is the only part)
--   a mixed state       -> STOP
--
-- M5c1 REPLACES NO EXISTING FUNCTION. The fp section shows, before AND
-- after part 1, that every body the existing suites fingerprint is still
-- what they expect: the eight _as game functions and their wrappers
-- (computer-c1-verification.sql, LF), the four end-empty-tables bodies (LF
-- or CRLF), M3's kick_player and _is_kicked_from_table, M5a's five, M5b1's
-- three, M5b2's two, and chat_topic_allows (spectator-chat.sql; its rule
-- is the one send_table_message writes out, and it stays as it is).
--
-- SUITES TO RE-RUN once part 1 is in:
--   moderation-m5c1-verification.sql (this slice's own);
--   slice-e-grants-verification.sql (X1: 61 names once send_table_message
--   exists -- re-baselined by this slice), and the re-baselined prechecks
--   if you want their grants rows green again (moderation-m1, -m3, -m6,
--   -m5a, -m5b1 and -m5b2-precheck.sql now accept 61 with
--   send_table_message), moderation-catalog.sql (section 10: 61);
--   table-chat-verification.sql and spectator-chat-verification.sql (still
--   4 policies on realtime.messages; no new function with "chat" in its
--   name; chat_topic_allows unchanged);
--   moderation-m5a-verification.sql (K2 "at least 60": still true),
--   moderation-m5b1-verification.sql, moderation-m5b2-verification.sql,
--   moderation-m3-verification.sql, moderation-m6-verification.sql,
--   computer-c1-verification.sql, computer-c2-verification.sql,
--   end-empty-tables-verification.sql (no body they fingerprint changed).
--   Not phase3-e1 / phase3-e4 (known stale, by design).
--   After moderation M5c1 c2 (moderation-m5c1c2-*.sql) this file still runs
--   green: it accepts chat_topic_allows and the table-chat pair as removed,
--   2 policies and 60 functions.
--
-- SECTIONS
--   state     the summary above.
--   fp        the fingerprinted bodies, unchanged.
--   needs     M5a and M3 part 1; computer_accounts; realtime.send; the
--             realtime.messages columns the count reads; whether this role
--             reads realtime.messages past its row-level security (the
--             function's count and read-back run as this role: without it
--             both would see nothing -- STOP); UPDATE on it (only the
--             verification needs that: it backdates its own rows); today's
--             partition (without it every send is refused "Couldn't send"
--             -- FLAG); the partial (topic, inserted_at) index on every
--             partition (FLAG where it is missing); computer accounts (the
--             verification uses one); the chat suite's C4 view.
--   part1     the two functions (bodies, definer, search_path '', TimeZone
--             UTC; EXECUTE: send_table_message for authenticated only,
--             _broadcast_table_message for no client role).
--   realtime  the policy count (4 before and after: part 1 adds none); the
--             two old chat policies (they STAY); the publication (INFO).
--   grants    functions authenticated may execute (60 before, 61 after).

with new_fns(o, name, sig, lf, want_auth) as (
  values
    (1, '_broadcast_table_message', 'public._broadcast_table_message(text, jsonb)', 'e5f16aebb3ca764c806e2567b68090fc', false),
    (2, 'send_table_message', 'public.send_table_message(uuid, text)', 'e3adcc4874c77c1c47530a807fefd815', true)
),
new_fn_state as (
  select n.o, n.name, n.sig, n.lf, n.want_auth,
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public' and p.proname = n.name) as overloads,
         p.oid as fn_oid,
         md5(replace(p.prosrc, E'\r', '')) as m,
         p.prosecdef as definer,
         coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path='''''] as empty_path,
         exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where lower(c) = 'timezone=utc') as utc,
         case when p.oid is null then null else has_function_privilege('authenticated', p.oid, 'EXECUTE') end as auth_x,
         case when p.oid is null then null
              else has_function_privilege('anon', p.oid, 'EXECUTE')
                   or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0)
                   or (exists (select 1 from pg_roles r where r.rolname = 'service_role') and has_function_privilege('service_role', p.oid, 'EXECUTE')) end as other_x
  from new_fns n
  left join pg_proc p on p.oid = to_regprocedure(n.sig)
),
fp_lf(o, fn, sig, lf, src) as (
  values
    (1, 'start_game_with_deal_as', 'public.start_game_with_deal_as(uuid, uuid)', '8b4528a51247b63a47b36bd703f81492', 'computer-c1-verification.sql as_md5'),
    (2, 'draw_cut_card_as', 'public.draw_cut_card_as(uuid, uuid)', 'e52f927759d991e13b55a6fa73d39781', 'computer-c1-verification.sql as_md5'),
    (3, 'acknowledge_deal_cut_as', 'public.acknowledge_deal_cut_as(uuid, uuid)', '1e6e9b06a58d59628ca8b4ae19e6605d', 'computer-c1-verification.sql as_md5'),
    (4, 'discard_to_crib_as', 'public.discard_to_crib_as(uuid, uuid, text[])', 'fe4d1bb43ee5d4c38dacac502a8817ab', 'computer-c1-verification.sql as_md5'),
    (5, 'play_card_as', 'public.play_card_as(uuid, uuid, text)', '39f2602ae2d547799f722ce434328b1c', 'computer-c1-verification.sql as_md5'),
    (6, 'show_crib_as', 'public.show_crib_as(uuid, uuid)', '46ff0cf6834ba0afae2178a6fc895da5', 'computer-c1-verification.sql as_md5'),
    (7, 'confirm_count_as', 'public.confirm_count_as(uuid, uuid, int)', '27d9a04b7810746bce691f01ec8feffa', 'computer-c1-verification.sql as_md5'),
    (8, 'next_hand_as', 'public.next_hand_as(uuid, uuid, int)', 'e08be4b22774ad656feed6b3852e0562', 'computer-c1-verification.sql as_md5'),
    (9, 'start_game_with_deal', 'public.start_game_with_deal(uuid)', 'f7df18aedee7d95216674a7687c405a0', 'computer-c1-verification.sql wrap_md5'),
    (10, 'draw_cut_card', 'public.draw_cut_card(uuid)', '0edacf243b6383d9a6977fedb4bd8392', 'computer-c1-verification.sql wrap_md5'),
    (11, 'acknowledge_deal_cut', 'public.acknowledge_deal_cut(uuid)', '3ca1514190fa9f57ebd1b78166c26f52', 'computer-c1-verification.sql wrap_md5'),
    (12, 'discard_to_crib', 'public.discard_to_crib(uuid, text[])', '325b1a01178582eba9a55d8117db0803', 'computer-c1-verification.sql wrap_md5'),
    (13, 'play_card', 'public.play_card(uuid, text)', 'b0434ffb08c301676a3d25722feba168', 'computer-c1-verification.sql wrap_md5'),
    (14, 'show_crib', 'public.show_crib(uuid)', '17821982fea29ef642fefa6a8d63c711', 'computer-c1-verification.sql wrap_md5'),
    (15, 'confirm_count', 'public.confirm_count(uuid, int)', '1d5baa992851570fae14dfcf5fda2853', 'computer-c1-verification.sql wrap_md5'),
    (16, 'next_hand', 'public.next_hand(uuid, int)', '692a77e35e328d7c83ad5de4af69fa51', 'computer-c1-verification.sql wrap_md5'),
    (17, 'kick_player', 'public.kick_player(uuid, uuid)', 'd859deb84acb67ec94a2cf65fb1f38f0', 'moderation-m3-part1.sql'),
    (18, '_is_kicked_from_table', 'public._is_kicked_from_table(uuid, uuid)', 'c8372af51a4537ca9cc079234487a414', 'moderation-m3-part1.sql'),
    (19, '_send_table_event', 'public._send_table_event(uuid, text, bigint)', 'df40bb9eac9b778a8d733d2d18393865', 'moderation-m5a-part1.sql'),
    (20, '_table_event_on_members', 'public._table_event_on_members()', '26f95e1c2dd4cb5cffbb8e784367cd92', 'moderation-m5a-part1.sql'),
    (21, '_table_event_on_spectators', 'public._table_event_on_spectators()', 'f81c329f92115ea11038cff9f0ffc184', 'moderation-m5a-part1.sql'),
    (22, '_table_event_on_tables', 'public._table_event_on_tables()', 'd950c48b22205b15e62e38411923fef5', 'moderation-m5a-part1.sql'),
    (23, 'table_topic_allows', 'public.table_topic_allows(text)', '57908d750db883e7687b926cbea3ab4a', 'moderation-m5a-part1.sql'),
    (24, '_bump_game_state_version', 'public._bump_game_state_version()', '35314b3677dd7b0b39a2ca32ee29e7c3', 'moderation-m5b1-part1.sql'),
    (25, '_send_game_event', 'public._send_game_event(uuid, jsonb)', '462c8068b6c7a183ca76fa18fa6b7264', 'moderation-m5b1-part1.sql'),
    (26, '_game_event_at_commit', 'public._game_event_at_commit()', 'cce9d688120f3dc2c155503270fe11ee', 'moderation-m5b1-part1.sql'),
    (27, '_send_scores_event', 'public._send_scores_event(uuid, jsonb)', 'cf9d6f31090605e8e42ca7a26aae1d7d', 'moderation-m5b2-part1.sql'),
    (28, '_scores_event_at_commit', 'public._scores_event_at_commit()', 'd06cc5e9fb12f0b0697dd4b4e43bd8a9', 'moderation-m5b2-part1.sql'),
    (29, 'chat_topic_allows', 'public.chat_topic_allows(text, boolean)', '0458d5122d68d511b2e0fbceafe84aae', 'spectator-chat.sql')
),
fp_raw(o, fn, sig, lf, crlf) as (
  values
    (31, 'leave_table', 'public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa'),
    (32, 'end_timed_out_sessions', 'public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c'),
    (33, 'assign_table_seat', 'public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb'),
    (34, 'table_host', 'public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d')
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
rt_leaves as (
  select pt.relid, c.relname::text as relname
  from pg_partition_tree(to_regclass('realtime.messages')) pt
  join pg_class c on c.oid = pt.relid
  where pt.isleaf
),
rt_att(col, attnum, typ) as (
  select a.attname::text, a.attnum, format_type(a.atttypid, a.atttypmod)
  from pg_attribute a
  where a.attrelid = to_regclass('realtime.messages') and a.attnum > 0 and not a.attisdropped
),
-- A leaf has the partial index when one of its indexes starts (topic,
-- inserted_at) and has a WHERE clause.
rt_indexed as (
  select l.relid
  from rt_leaves l
  where exists (
    select 1
    from pg_index ix
    join pg_attribute a1 on a1.attrelid = ix.indrelid and a1.attnum = ix.indkey[0]
    join pg_attribute a2 on a2.attrelid = ix.indrelid and a2.attnum = ix.indkey[1]
    where ix.indrelid = l.relid
      and a1.attname = 'topic' and a2.attname = 'inserted_at'
      and ix.indpred is not null)
),
flags as (
  select (select count(*) from new_fn_state n where n.fn_oid is not null) as p1_fns
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== state ====================================================================
  select 0 as s, 0 as o, 'state'::text as section, 'M5c1 state'::text as item,
         ('M5c1 functions ' || f.p1_fns::text || ' of 2')::text as value,
         (case
            when f.p1_fns = 0
              then 'before part 1: run docs/sql/moderation-m5c1-part1.sql next (if no other row says STOP)'
            when f.p1_fns = 2
              then 'part 1 present: M5c1 is in; re-run the suites listed in this file''s header'
            else 'STOP: a mixed state (one of part 1''s functions without the other); paste the whole result back'
          end)::text as note
  from flags f

  union all
  -- ==== fp =======================================================================
  select 1, k.o, 'fp', k.fn || ': md5 of the live body (carriage returns removed)',
         coalesce((select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure(k.sig)), '(missing)'),
         case when k.fn = 'chat_topic_allows' and (to_regprocedure('public.chat_topic_allows(text, boolean)') is null and to_regprocedure('public.send_table_message(uuid, text)') is not null)
                then 'removed by moderation M5c1 c2 (moderation-m5c1c2-part1.sql): expected'
              when (select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure(k.sig)) = k.lf
                then k.src || ': as expected (unchanged by M5c1)'
              else 'STOP: not ' || k.src || '''s fingerprint (or missing): that suite would fail. Capture it first: select pg_get_functiondef(''' || k.sig || '''::regprocedure);' end
  from fp_lf k

  union all
  select 1, k.o, 'fp', k.fn || ': md5 of the live body',
         coalesce((select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(k.sig)), '(missing)'),
         case (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(k.sig))
              when k.lf then 'end-empty-tables fingerprint, LF: as expected (unchanged by M5c1)'
              when k.crlf then 'end-empty-tables fingerprint, CRLF: as expected (unchanged by M5c1)'
              else 'STOP: not the fingerprinted body (or missing). Capture it first: select pg_get_functiondef(''' || k.sig || '''::regprocedure);' end
  from fp_raw k

  union all
  select 1, 99, 'fp', 'functions M5c1 replaces', '(none)',
         'M5c1 replaces no existing function: it adds two'

  union all
  -- ==== needs ====================================================================
  select 2, 1, 'needs', 'M5a part 1 (table_topic_allows, the table events policy) / M3 part 1 (_is_kicked_from_table)',
         (to_regprocedure('public.table_topic_allows(text)') is not null)::text || ' / '
           || (to_regprocedure('public._is_kicked_from_table(uuid, uuid)') is not null)::text,
         case when to_regprocedure('public.table_topic_allows(text)') is not null
                   and (exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages'
                                  and p.policyname = 'table events: people at the table receive'))
                   and to_regprocedure('public._is_kicked_from_table(uuid, uuid)') is not null
                then 'as expected (the chat events use M5a''s topic and receive rule; the kick check is M3''s)'
              else 'STOP: M5c1 builds on M5a and M3 part 1' end

  union all
  select 2, 2, 'needs', 'public.computer_accounts / chat_topic_allows(text, boolean)',
         (to_regclass('public.computer_accounts') is not null)::text || ' / '
           || (to_regprocedure('public.chat_topic_allows(text, boolean)') is not null)::text,
         case when to_regclass('public.computer_accounts') is not null and to_regprocedure('public.chat_topic_allows(text, boolean)') is not null
                then 'as expected'
              when to_regclass('public.computer_accounts') is not null and (to_regprocedure('public.chat_topic_allows(text, boolean)') is null and to_regprocedure('public.send_table_message(uuid, text)') is not null)
                then 'as expected after moderation M5c1 c2 (chat_topic_allows removed; part 1 already ran)'
              else 'STOP: part 1''s guard needs both' end

  union all
  select 2, 3, 'needs', 'realtime.send(jsonb, text, text, boolean): exists / ' || current_user || ' may execute',
         case when to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null then '(missing)'
              else 'exists / ' || has_function_privilege(current_user, 'realtime.send(jsonb, text, text, boolean)', 'EXECUTE')::text end,
         case when to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null then 'STOP: send_table_message needs realtime.send'
              when not has_function_privilege(current_user, 'realtime.send(jsonb, text, text, boolean)', 'EXECUTE')
                then 'STOP: this role (which will own send_table_message) may not call realtime.send'
              else 'as expected' end

  union all
  select 2, 4, 'needs', 'realtime.messages columns: topic, extension, private, inserted_at, payload, event, expires_at (type)',
         coalesce((select string_agg(r.col || ' ' || r.typ, ', ' order by r.attnum) from rt_att r
                   where r.col in ('topic', 'extension', 'private', 'inserted_at', 'payload', 'event', 'expires_at')), '(no table)'),
         case when (select count(*) from rt_att r where r.col in ('topic', 'extension', 'private', 'inserted_at', 'payload')) = 5
                then 'as expected (the count and the read-back use topic, extension, private, inserted_at and payload; send_table_message runs with TimeZone UTC, so a timestamp-without-time-zone inserted_at compares in UTC)'
              else 'STOP: a column the count reads is missing' end

  union all
  select 2, 5, 'needs', current_user || ' reads realtime.messages past its row-level security (SELECT / superuser, BYPASSRLS or owner)',
         case when to_regclass('realtime.messages') is null then '(no table)'
              else has_table_privilege(current_user, 'realtime.messages', 'SELECT')::text || ' / '
                   || ((select r.rolsuper or r.rolbypassrls from pg_roles r where r.rolname = current_user)
                       or (select c.relowner = (select r.oid from pg_roles r where r.rolname = current_user) from pg_class c where c.oid = to_regclass('realtime.messages')))::text end,
         case when to_regclass('realtime.messages') is not null
                   and has_table_privilege(current_user, 'realtime.messages', 'SELECT')
                   and ((select r.rolsuper or r.rolbypassrls from pg_roles r where r.rolname = current_user)
                        or (select c.relowner = (select r.oid from pg_roles r where r.rolname = current_user) from pg_class c where c.oid = to_regclass('realtime.messages')))
                then 'as expected (the count and the read-back run as this role and see every row)'
              else 'STOP: the count would always be 0 and the read-back would never find the row (every send refused); paste back' end

  union all
  select 2, 5, 'needs', 'realtime.messages.inserted_at: column default',
         coalesce((select coalesce(pg_get_expr(d.adbin, d.adrelid), '(no default)')
                   from pg_attribute a
                   left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                   where a.attrelid = to_regclass('realtime.messages') and a.attname = 'inserted_at' and not a.attisdropped), '(no column)'),
         'INFO: Walt saw timezone(''utc'', clock_timestamp()) on 2026-11-26: a stored message carries the real clock, a little after the call''s now(); the verification snaps its own rows back to its frozen now()'

  union all
  select 2, 6, 'needs', current_user || ' may UPDATE realtime.messages (verification only)',
         case when to_regclass('realtime.messages') is null then '(no table)'
              else has_table_privilege(current_user, 'realtime.messages', 'UPDATE')::text end,
         case when to_regclass('realtime.messages') is not null and has_table_privilege(current_user, 'realtime.messages', 'UPDATE')
                then 'INFO: the verification backdates its own stored messages (inside its rolled-back transaction) to test the rate limit'
              else 'FLAG: the verification cannot backdate its own rows and will stop at SETUP; part 1 does not need it' end

  union all
  select 2, 7, 'needs', 'realtime.messages leaf partitions / today''s (UTC) / with the partial (topic, inserted_at) index',
         (select count(*) from rt_leaves)::text || ' / '
           || (exists (select 1 from rt_leaves l where l.relname = 'messages_' || to_char(now() at time zone 'UTC', 'YYYY_MM_DD')))::text || ' / '
           || (select count(*) from rt_indexed)::text,
         case when not exists (select 1 from rt_leaves l where l.relname = 'messages_' || to_char(now() at time zone 'UTC', 'YYYY_MM_DD'))
                then 'FLAG: no partition named for today: realtime.send cannot store, so every send_table_message call would answer NBC05 "Couldn''t send" (by design) and the verification stops at SETUP. Realtime normally creates it itself'
              when (select count(*) from rt_indexed) < (select count(*) from rt_leaves)
                then 'FLAG: a partition without the partial index: the count would scan that partition (Walt''s plan had the index on every one)'
              else 'as expected (the count is an index scan of one topic''s last 10 seconds)' end

  union all
  select 2, 8, 'needs', 'computer accounts (public.computer_accounts rows)',
         coalesce((select count(*) from public.computer_accounts)::text, '0'),
         'INFO: send_table_message refuses them; the verification uses one (SETUP without any)'

  union all
  select 2, 9, 'needs', 'public functions with "chat" in the name besides chat_topic_allows (table-chat-verification.sql C4)',
         coalesce((select string_agg(p.proname::text, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows'), '(none)'),
         case when exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                           where n.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows')
                then 'STOP: C4 would already fail' else 'as expected before and after part 1 (its two names have no "chat" in them)' end

  union all
  -- ==== part1 ====================================================================
  select 3, 10 + n.o, 'part1', n.sig,
         case when n.fn_oid is null then '(absent)'
              else 'md5 ' || n.m || ', definer ' || n.definer::text || ', search_path '''' ' || n.empty_path::text
                   || ', TimeZone UTC ' || n.utc::text || ', authenticated EXECUTE ' || n.auth_x::text
                   || ', anon/PUBLIC/service_role EXECUTE ' || n.other_x::text end,
         case
           when n.overloads > 1 or (n.overloads = 1 and n.fn_oid is null) then 'STOP: another function by that name exists'
           when n.fn_oid is null then 'before part 1: absent, as expected'
           when n.m = n.lf and n.definer and n.empty_path and (n.utc or not n.want_auth)
                and n.auth_x = n.want_auth and not n.other_x
             then case when n.want_auth then 'after part 1: part 1''s body; EXECUTE for authenticated only'
                       else 'after part 1: part 1''s body; no client EXECUTE' end
           else 'STOP: not part 1''s body or settings, or the wrong roles may execute it' end
  from new_fn_state n

  union all
  -- ==== realtime =================================================================
  select 5, 1, 'realtime', 'policies on realtime.messages (count)',
         (select count(*) from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages')::text,
         case when (select count(*) from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages') = 4
                then 'as expected before and after part 1 (M5c1 adds none: nobody may insert on table: topics)'
              when (select count(*) from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages') = 2 and (to_regprocedure('public.chat_topic_allows(text, boolean)') is null and to_regprocedure('public.send_table_message(uuid, text)') is not null)
                then 'as expected after moderation M5c1 c2: the table-chat pair removed; kicks and table events remain'
              else 'STOP: expected 4 (2 after moderation M5c1 c2)' end

  union all
  select 5, 2, 'realtime', 'the old chat policies ("table chat: members receive" / "table chat: members send")',
         (exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages' and p.policyname = 'table chat: members receive'))::text
           || ' / ' || (exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages' and p.policyname = 'table chat: members send'))::text,
         case when exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages' and p.policyname = 'table chat: members receive')
                   and exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages' and p.policyname = 'table chat: members send')
                then 'as expected: they STAY until the c2 hard cut'
              when (to_regprocedure('public.chat_topic_allows(text, boolean)') is null and to_regprocedure('public.send_table_message(uuid, text)') is not null)
                and not exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages'
                                  and p.policyname in ('table chat: members receive', 'table chat: members send'))
                then 'gone: removed by moderation M5c1 c2, as planned'
              else 'STOP: an old chat policy is missing' end

  union all
  select 5, 3, 'realtime', 'publication supabase_realtime: tables',
         coalesce((select string_agg(pt.schemaname || '.' || pt.tablename, ', ' order by pt.schemaname, pt.tablename)
                   from pg_publication_tables pt where pt.pubname = 'supabase_realtime'), '(none)'),
         'INFO: part 1 does not change it'

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
           when (select count(*) from client_fns) = 60 and not exists (select 1 from client_fns cf where cf.name = 'send_table_message')
             then 'before part 1: 60 (slice E''s 49, M1''s 3, M2''s 1, M3''s 3, M6''s 3, M5a''s 1)'
           when (select count(*) from client_fns) = 61 and exists (select 1 from client_fns cf where cf.name = 'send_table_message')
             then 'after part 1: the 60 plus send_table_message'
           when (select count(*) from client_fns) = 60 and exists (select 1 from client_fns cf where cf.name = 'send_table_message')
                and not exists (select 1 from client_fns cf where cf.name = 'chat_topic_allows')
             then 'after part 1 and moderation M5c1 c2: 60 (send_table_message in, chat_topic_allows removed)'
           else 'STOP: neither 60 nor 61 (or 61 with admin_report_chat once moderation M7 part 1 is in; slice-e-grants-verification.sql X1 would fail)' end
) z
order by z.s, z.o, z.item;
