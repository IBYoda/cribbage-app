-- Moderation, slice M5 (b2): PRECHECK for SCORES EVENTS (READ-ONLY).
-- Run in the Supabase Dashboard -> SQL Editor before
-- docs/sql/moderation-m5b2-part1.sql, and again after it. ONE statement; it
-- only reads the catalog and counts rows. Paste the whole result back.
--
-- STATUS: written, NOT RUN yet.
--
-- Every row has a section, an item, a value and a note. A note starting
-- "STOP" means: do not run the next file; paste the result back. The first
-- row ("state") says where M5b2 stands:
--   before part 1       -> run moderation-m5b2-part1.sql next
--   part 1 present      -> M5b2 is in (part 1 is the only part)
--   a mixed state       -> STOP
--
-- M5b2 REPLACES NO EXISTING FUNCTION. The fp section shows, before AND
-- after part 1, that every body the existing suites fingerprint is still
-- what they expect (so none needs a new md5): the eight _as game functions
-- and their wrappers (computer-c1-verification.sql, LF), the four
-- end-empty-tables bodies (LF or CRLF), M3's kick_player, M5a's five and
-- M5b1's three (LF). award_points is shown for information: part 1 relies
-- only on it putting last_points / last_reason / last_awarded_at on the
-- SCORER's row.
--
-- SUITES TO RE-RUN once part 1 is in (none needs a new md5 or count; none
-- is changed by this slice):
--   moderation-m5b1-verification.sql, moderation-m5a-verification.sql
--   (K3: its trigger still sorts last among the IMMEDIATE AFTER triggers --
--   M5b2's name sorts before it), computer-c1-verification.sql,
--   computer-c2-verification.sql, end-empty-tables-verification.sql,
--   moderation-m3-verification.sql, moderation-m6-verification.sql,
--   phase3-e1-seating-verification.sql (S5, its seat trigger by name),
--   phase3-e4-counting-verification.sql and
--   phase3-muggins-multiplayer-verification.sql (awards, at a never-reached
--   commit), slice-e-grants-verification.sql (still 60 names: M5b2 grants
--   nothing), table-chat-verification.sql and
--   spectator-chat-verification.sql (still 4 policies: M5b2 adds none).
--   end-empty-tables-precheck.sql and the catalogs only LIST the triggers on
--   table_members (the new one appears as information).
-- A verification suite is ONE transaction that never commits, so the
-- deferred trigger never fires inside the older suites.
--
-- SECTIONS
--   state     the summary above.
--   fp        the fingerprinted bodies, unchanged; award_points (INFO).
--   needs     M5a and M5b1 part 1; realtime.send; award_points; leaf
--             partitions of realtime.messages (none: the verification's
--             stored-event checks are skipped).
--   part1     the two functions (bodies, definer, search_path '', no client
--             EXECUTE); the trigger (a CONSTRAINT trigger, AFTER UPDATE OF
--             the four score columns, ROW, DEFERRABLE INITIALLY DEFERRED).
--   triggers  every user trigger on table_members, and whether any
--             IMMEDIATE AFTER trigger sorts after M5a's (it must not).
--   realtime  the policy count (4 before and after); table_members in the
--             supabase_realtime publication (it STAYS).
--   grants    functions authenticated may execute (60 before and after;
--             61 once moderation M5c1 part 1 is in: send_table_message).

with new_fns(o, name, sig, lf) as (
  values
    (1, '_send_scores_event', 'public._send_scores_event(uuid, jsonb)', 'cf9d6f31090605e8e42ca7a26aae1d7d'),
    (2, '_scores_event_at_commit', 'public._scores_event_at_commit()', 'd06cc5e9fb12f0b0697dd4b4e43bd8a9')
),
new_fn_state as (
  select n.o, n.name, n.sig, n.lf,
         (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public' and p.proname = n.name) as overloads,
         p.oid as fn_oid,
         md5(replace(p.prosrc, E'\r', '')) as m,
         p.prosecdef as definer,
         coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path='''''] as empty_path,
         case when p.oid is null then null
              else has_function_privilege('authenticated', p.oid, 'EXECUTE') or has_function_privilege('anon', p.oid, 'EXECUTE')
                   or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0)
                   or (exists (select 1 from pg_roles r where r.rolname = 'service_role') and has_function_privilege('service_role', p.oid, 'EXECUTE')) end as client_x
  from new_fns n
  left join pg_proc p on p.oid = to_regprocedure(n.sig)
),
trg as (
  select tg.oid, tg.tgname, tg.tgfoid, tg.tgenabled, tg.tgdeferrable, tg.tginitdeferred, tg.tgconstraint, tg.tgattr,
         (tg.tgtype & 2) = 2 as is_before,
         (tg.tgtype & 1) = 1 as is_row,
         rtrim(case when (tg.tgtype & 4) = 4 then 'INSERT ' else '' end
               || case when (tg.tgtype & 8) = 8 then 'DELETE ' else '' end
               || case when (tg.tgtype & 16) = 16 then 'UPDATE ' else '' end) as events,
         (select string_agg(a.attname::text, ',' order by a.attname)
          from pg_attribute a
          where a.attrelid = tg.tgrelid and a.attnum = any(tg.tgattr::int2[])) as cols
  from pg_trigger tg
  where tg.tgrelid = 'public.table_members'::regclass and not tg.tgisinternal
),
new_trg as (
  select t.oid,
         not t.is_before and t.is_row and t.events = 'UPDATE' and t.tgenabled = 'O'
           and t.tgdeferrable and t.tginitdeferred and t.tgconstraint <> 0
           and t.tgfoid = to_regprocedure('public._scores_event_at_commit()')
           and t.cols = 'last_awarded_at,last_points,last_reason,score' as ok
  from trg t
  where t.tgname = 'table_members_zz_scores_event'
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
    (18, '_send_table_event', 'public._send_table_event(uuid, text, bigint)', 'df40bb9eac9b778a8d733d2d18393865', 'moderation-m5a-part1.sql'),
    (19, '_table_event_on_members', 'public._table_event_on_members()', '26f95e1c2dd4cb5cffbb8e784367cd92', 'moderation-m5a-part1.sql'),
    (20, '_table_event_on_spectators', 'public._table_event_on_spectators()', 'f81c329f92115ea11038cff9f0ffc184', 'moderation-m5a-part1.sql'),
    (21, '_table_event_on_tables', 'public._table_event_on_tables()', 'd950c48b22205b15e62e38411923fef5', 'moderation-m5a-part1.sql'),
    (22, 'table_topic_allows', 'public.table_topic_allows(text)', '57908d750db883e7687b926cbea3ab4a', 'moderation-m5a-part1.sql'),
    (23, '_bump_game_state_version', 'public._bump_game_state_version()', '35314b3677dd7b0b39a2ca32ee29e7c3', 'moderation-m5b1-part1.sql'),
    (24, '_send_game_event', 'public._send_game_event(uuid, jsonb)', '462c8068b6c7a183ca76fa18fa6b7264', 'moderation-m5b1-part1.sql'),
    (25, '_game_event_at_commit', 'public._game_event_at_commit()', 'cce9d688120f3dc2c155503270fe11ee', 'moderation-m5b1-part1.sql')
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
flags as (
  select
    (select count(*) from new_fn_state n where n.fn_oid is not null) as p1_fns,
    exists (select 1 from new_trg) as p1_trg
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== state ====================================================================
  select 0 as s, 0 as o, 'state'::text as section, 'M5b2 state'::text as item,
         ('M5b2 functions ' || f.p1_fns::text || ' of 2 | scores trigger ' || f.p1_trg::text)::text as value,
         (case
            when f.p1_fns = 0 and not f.p1_trg
              then 'before part 1: run docs/sql/moderation-m5b2-part1.sql next (if no other row says STOP)'
            when f.p1_fns = 2 and f.p1_trg
              then 'part 1 present: M5b2 is in; re-run the suites listed in this file''s header'
            else 'STOP: a mixed state (some of part 1 without the rest); paste the whole result back'
          end)::text as note
  from flags f

  union all
  -- ==== fp =======================================================================
  select 1, k.o, 'fp', k.fn || ': md5 of the live body (carriage returns removed)',
         coalesce((select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure(k.sig)), '(missing)'),
         case when (select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure(k.sig)) = k.lf
                then k.src || ': as expected (unchanged by M5b2)'
              else 'STOP: not ' || k.src || '''s fingerprint (or missing): that suite would fail. Capture it first: select pg_get_functiondef(''' || k.sig || '''::regprocedure);' end
  from fp_lf k

  union all
  select 1, k.o, 'fp', k.fn || ': md5 of the live body',
         coalesce((select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(k.sig)), '(missing)'),
         case (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(k.sig))
              when k.lf then 'end-empty-tables fingerprint, LF: as expected (unchanged by M5b2)'
              when k.crlf then 'end-empty-tables fingerprint, CRLF: as expected (unchanged by M5b2)'
              else 'STOP: not the fingerprinted body (or missing). Capture it first: select pg_get_functiondef(''' || k.sig || '''::regprocedure);' end
  from fp_raw k

  union all
  select 1, 40, 'fp', 'award_points: md5 of the live body (carriage returns removed)',
         coalesce((select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure('public.award_points(uuid, uuid, integer, text)')), '(missing)'),
         case when (select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure('public.award_points(uuid, uuid, integer, text)')) = '5da5163549f3c69f71aeec461fc49a73'
                then 'INFO: phase3-e4-counting.sql''s text (last_* on the scorer''s row only)'
              when to_regprocedure('public.award_points(uuid, uuid, integer, text)') is null
                then 'STOP: award_points is missing'
              else 'FLAG: not phase3-e4-counting.sql''s committed text; capture it (select pg_get_functiondef(''public.award_points(uuid, uuid, integer, text)''::regprocedure);) and confirm it still sets last_* on the scorer''s row only' end

  union all
  select 1, 99, 'fp', 'functions M5b2 replaces', '(none)',
         'M5b2 replaces no existing function: it adds two functions and one trigger'

  union all
  -- ==== needs ====================================================================
  select 2, 1, 'needs', 'M5a part 1 (table_topic_allows, the table events policy) / M5b1 part 1 (_game_event_at_commit, games_zz_game_event)',
         (to_regprocedure('public.table_topic_allows(text)') is not null)::text || ' / '
           || (to_regprocedure('public._game_event_at_commit()') is not null)::text,
         case when to_regprocedure('public.table_topic_allows(text)') is not null
                   and (exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages'
                                  and p.policyname = 'table events: people at the table receive'))
                   and to_regprocedure('public._game_event_at_commit()') is not null
                   and (exists (select 1 from pg_trigger tg where tg.tgrelid = 'public.games'::regclass and tg.tgname = 'games_zz_game_event' and not tg.tgisinternal))
                then 'as expected (the scores events use M5a''s topic and receive rule, and M5b1''s pattern)'
              else 'STOP: M5b2 builds on M5a and M5b1 part 1' end

  union all
  select 2, 2, 'needs', 'realtime.send(jsonb, text, text, boolean): exists / ' || current_user || ' may execute',
         case when to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null then '(missing)'
              else 'exists / ' || has_function_privilege(current_user, 'realtime.send(jsonb, text, text, boolean)', 'EXECUTE')::text end,
         case when to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null then 'STOP: the scores events need realtime.send'
              when not has_function_privilege(current_user, 'realtime.send(jsonb, text, text, boolean)', 'EXECUTE')
                then 'STOP: this role (which will own the trigger function) may not call realtime.send'
              else 'as expected' end

  union all
  select 2, 3, 'needs', 'leaf partitions of realtime.messages',
         (select count(*)::text from pg_partition_tree(to_regclass('realtime.messages')) pt where pt.isleaf),
         'INFO: none means realtime.send cannot store an event (the award still goes through: the send is caught); the verification then skips its stored-event checks'

  union all
  -- ==== part1 ====================================================================
  select 3, 10 + n.o, 'part1', n.sig,
         case when n.fn_oid is null then '(absent)'
              else 'md5 ' || n.m || ', definer ' || n.definer::text || ', search_path '''' ' || n.empty_path::text
                   || ', any client EXECUTE ' || n.client_x::text end,
         case
           when n.overloads > 1 or (n.overloads = 1 and n.fn_oid is null) then 'STOP: another function by that name exists'
           when n.fn_oid is null then 'before part 1: absent, as expected'
           when n.m = n.lf and n.definer and n.empty_path and not n.client_x then 'after part 1: part 1''s body, no client EXECUTE'
           else 'STOP: not part 1''s body, or a client may execute it' end
  from new_fn_state n

  union all
  select 3, 20, 'part1', 'trigger table_members_zz_scores_event',
         case when not exists (select 1 from new_trg) then '(absent)'
              else 'present, as part 1 wrote it: ' || coalesce((select t.ok::text from new_trg t), 'false') end,
         case when not exists (select 1 from new_trg) then 'before part 1: absent, as expected'
              when (select t.ok from new_trg t) then 'after part 1: CONSTRAINT trigger AFTER UPDATE OF score, last_points, last_reason, last_awarded_at, ROW, DEFERRABLE INITIALLY DEFERRED (at commit)'
              else 'STOP: a trigger by that name that part 1 did not write' end

  union all
  -- ==== triggers =================================================================
  select 4, (row_number() over (order by t.is_before desc, t.tgname))::int, 'triggers',
         'table_members: ' || t.tgname::text,
         (case when t.is_before then 'BEFORE ' else 'AFTER ' end) || t.events
           || case when t.cols is not null then ' OF ' || t.cols else '' end
           || case when t.is_row then ' ROW' else ' STATEMENT' end
           || case when t.tgdeferrable then ' DEFERRABLE' || case when t.tginitdeferred then ' INITIALLY DEFERRED' else '' end else '' end
           || ' -> ' || t.tgfoid::regprocedure::text || case when t.tgenabled = 'D' then ' (DISABLED)' else '' end,
         case when t.tgname = 'table_members_zz_scores_event' then 'part 1''s (deferred: fires at commit, after every immediate trigger)'
              when t.tgname = 'table_members_zz_table_event' then 'M5a''s'
              when not t.is_before and not t.tgdeferrable and t.tgname::text > 'table_members_zz_table_event'
                then 'STOP: an immediate AFTER trigger sorts after M5a''s (M5a''s K3 would fail)'
              else 'INFO' end
  from trg t

  union all
  -- ==== realtime =================================================================
  select 5, 1, 'realtime', 'policies on realtime.messages (count)',
         (select count(*) from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages')::text,
         case when (select count(*) from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages') = 4
                then 'as expected before and after part 1 (M5b2 adds none)'
              else 'STOP: expected 4' end

  union all
  select 5, 2, 'realtime', 'publication supabase_realtime: table_members',
         (exists (select 1 from pg_publication_tables pt where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = 'table_members'))::text,
         'INFO: it STAYS in the publication (the old listener is the live score path; the scores event only repairs)'

  union all
  -- ==== grants ===================================================================
  select 6, 1, 'grants', 'functions authenticated may execute in public (distinct names)',
         (select count(*) from client_fns)::text,
         case when (select count(*) from client_fns) = 60 and not exists (select 1 from client_fns cf where cf.name = 'send_table_message')
                then 'as expected before and after part 1 (M5b2 grants nothing to clients)'
              when (select count(*) from client_fns) = 61 and exists (select 1 from client_fns cf where cf.name = 'send_table_message')
                then 'as expected before and after part 1 (M5b2 grants nothing to clients): the 60 plus moderation M5c1''s send_table_message'
              else 'STOP: expected 60 (61 once moderation M5c1 part 1 is in; slice-e-grants-verification.sql X1 would fail)' end
) z
order by z.s, z.o, z.item;
