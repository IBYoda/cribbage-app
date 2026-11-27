-- Moderation and chat (roadmap steps 5c and 6): REPORTS, KEPT CHAT, HOST
-- MUTE AND KICK, PERSONAL HIDE, BLOCK LIST.
-- The CATALOG (read-only). Run in the Supabase Dashboard -> SQL Editor. It
-- reads only; it changes nothing: no writes, no DO block, no temp table, no
-- SET. Safe to run any time, as often as you like.
--
-- STATUS: run 2026-11-25 (before moderation M1).
--
-- UPDATED FOR MODERATION M1 (the Block List: moderation-m1-part1.sql and
-- moderation-m1-part2.sql), so it can be run again after M1 without false
-- STOPs: section 02 also accepts M1 part 2's join_table_by_code and
-- watch_table bodies; section 09 marks M1's own objects (public.blocks and
-- its indexes, block_player, unblock_player, get_my_blocks,
-- _is_blocked_from_table) as INFO instead of STOP; section 10 expects the
-- 52 names once public.blocks exists (49 before). Nothing else changed.
-- UPDATED FOR MODERATION M2 (moderation-m2-part1.sql): block_player_by_id
-- is INFO (M2's own) in section 09, and section 10 expects 53 names once it
-- exists.
-- UPDATED FOR MODERATION M5c1 (moderation-m5c1-part1.sql): section 01 has an
-- INFO row for send_table_message (chat through the server) and its helper
-- _broadcast_table_message; section 10 expects 61 names once
-- send_table_message exists (the 60 plus it; never the helper).
-- UPDATED FOR MODERATION M5c1 c2 (moderation-m5c1c2-part1.sql): the
-- table-chat policies and chat_topic_allows are removed. Section 01 then
-- expects exactly 2 policies (M3's kicks, M5a's table events) and shows an
-- INFO row for c2; section 02 marks chat_topic_allows INFO (removed) instead
-- of STOP; section 10 expects 60 names (the 61 without chat_topic_allows).
-- UPDATED FOR THE M5 FINAL CLEANUP (moderation-m5-cleanup-part1.sql): the
-- app listens to no table (App B, PR #144), and part 1 takes game_plays,
-- games, profiles, table_members and tables out of supabase_realtime. Section
-- 01's publication row then expects it empty, and an INFO row says so.
--
-- WHY: the moderation slices (kept chat messages for 3 days, reports, a
-- table-wide mute and a kick by the host, a personal hide, a Block List that
-- keeps a blocked person out of every table the blocker creates) must be
-- written against what is LIVE, not against the committed files. This file
-- only reports; paste the whole result back.
--
-- HOW TO RUN: paste the whole file into the SQL Editor and press Run, as the
-- dashboard's default role. ONE statement, so the editor shows every row in
-- one grid. Columns: section, item, value, note (all text), ordered so
-- related rows sit together. A note starting with STOP means: paste this
-- back before anything else is written. FLAG marks what a moderation slice
-- is expected to change (expected today, not a blocker). INFO is for the
-- record. ESTIMATE rows are arithmetic, not measurements. pg_cron is read
-- through query_to_xml, so this still parses where pg_cron is missing;
-- realtime.messages is read from the catalog only (its partitions' sizes and
-- row estimates), never queried, so no privilege on it is needed.
--
-- WHAT EACH SECTION RETURNS
--   01 realtime   the policies on realtime.messages (name, command, roles,
--                 USING and WITH CHECK in full) and their count (the chat
--                 prechecks STOP unless exactly the two table-chat ones);
--                 RLS on realtime.messages; its partitions, estimated rows
--                 and total size; whether realtime.send(jsonb, text, text,
--                 boolean) exists; the supabase_realtime publication's
--                 tables; table_members' replica identity; and the chat
--                 suite's C4 view: every relation in a non-system schema and
--                 every public function with "chat" in its name, and storage
--                 buckets with "chat" in their id or name.
--   02 fp         every function the moderation slices read or touch: the
--                 live body's md5 against the committed file's (LF and CRLF),
--                 how many overloads, definer/invoker, config, and EXECUTE
--                 for authenticated. leave_table, end_timed_out_sessions,
--                 assign_table_seat and table_host are FINGERPRINTED (they
--                 stay byte-for-byte; the values are slice-e-part1.sql's
--                 guard). STOP on any mismatch, with the line to paste back.
--   03 column     columns of tables, table_members, table_spectators,
--                 profiles and admin_users (type, not null, default).
--   04 constraint every constraint of tables, table_members,
--                 table_spectators, profiles, games and admin_users, in full
--                 (the ended_reason checks: a kick may need a new reason).
--   05 index      every index on those six.
--   06 trigger    every user trigger on those six, in full, enabled or not,
--                 in firing order (BEFORE INSERT triggers on table_members
--                 fire in name order: a new block/kick trigger must sort
--                 where it is meant to).
--   07 policy     every RLS policy on those six, in full, and whether RLS is
--                 on and forced.
--   08 grant      table privileges of anon, authenticated, service_role and
--                 PUBLIC on those six plus attempt_log, follows and
--                 computer_accounts; and authenticated's on realtime.messages.
--   09 existing   anything already named like a report, block, mute, kick,
--                 ban, hide or moderation object (relations in non-system
--                 schemas, public functions, public types, policies,
--                 triggers, storage buckets). Expected: none.
--   10 client fn  the functions authenticated may execute in public: the
--                 count, any not in slice E's 49, any of the 49 missing, and
--                 the full list (so new functions are counted).
--   11 cron       every pg_cron job: jobid, jobname, schedule, active,
--                 command.
--   12 attempt    attempt_log's action check (a report or chat rate limit
--                 widens it) and _attempts_guard's signature.
--   13 size       rows and total size of tables, table_members,
--                 table_spectators, profiles, games, attempt_log, follows,
--                 admin_users; the database's total size; the avatars
--                 bucket's objects and bytes; every storage bucket (id,
--                 public, size limit).
--   14 estimate   ESTIMATE: kept chat at 10,000 players x 50 messages a day
--                 for 3 days, at about 250 bytes a row including indexes,
--                 with the arithmetic shown.

with client_roles(o, rolname) as (
  values (1, 'anon'), (2, 'authenticated'), (3, 'service_role'), (4, 'PUBLIC')
),
mod_tables(o, relname, detail) as (
  values (1, 'tables', true), (2, 'table_members', true), (3, 'table_spectators', true),
         (4, 'profiles', true), (5, 'games', true), (6, 'admin_users', true),
         (7, 'attempt_log', false), (8, 'follows', false), (9, 'computer_accounts', false)
),
mod_rels as (
  select mt.o, mt.relname, mt.detail, c.oid, c.relowner, c.relacl, c.relrowsecurity, c.relforcerowsecurity
  from mod_tables mt
  join pg_class c on c.oid = to_regclass('public.' || mt.relname)
),
fp(o, fn, kind, lf, crlf, src) as (
  values
    (1, 'leave_table', 'fp', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa', 'phase2-slice-5-cut-before-deal.sql'),
    (2, 'end_timed_out_sessions', 'fp', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c', 'phase2-slice-5-cut-before-deal.sql'),
    (3, 'assign_table_seat', 'fp', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb', 'phase3-e1-seating.sql'),
    (4, 'table_host', 'fp', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d', 'phase3-e1-seating.sql'),
    (5, 'join_table_by_code', 'change', '1a2ff167c6d09fef6acd17177493422d', '9f3cee04a063447d626a1354533fda51', 'free-codes-part1.sql'),
    (6, 'watch_table', 'change', '43775b57dffaec98ee7c003304a0c951', 'df591fa16528afd81a13bfdc3e975538', 'free-codes-part1.sql'),
    (7, 'remove_spectator', 'change', 'dafa688f1b8c194e4be575cd0625ba12', '9786b9a5e50245365a2598b18da5892e', 'spectators.sql'),
    (8, 'spectator_heartbeat', 'change', '41d2ea0e865c2a9d5fa7203875a27ace', '6b7c271d78eb4f72c1aff3c851b578e1', 'spectators-join-or-watch.sql'),
    (9, 'chat_topic_allows', 'change', '0458d5122d68d511b2e0fbceafe84aae', 'c4e6eda360de7d7723c4069e60d95345', 'spectator-chat.sql'),
    (10, 'get_table_spectators', 'read', '0df2ddd114957a157cd688faa17ff209', '45eee8329fcfcca149897f6c4e1a18d1', 'spectator-chat.sql'),
    (11, 'stop_watching', 'read', '3a9e7735a410b538ece3beb9ae4d5c8b', 'b620e85b08578a784b348ddfa287e6e5', 'spectators.sql'),
    (12, 'get_spectator_reveals', 'read', '445469b0d430cd7faedd3234ff34ca6c', 'c2f76d880e46f1e410918f07dea13804', 'spectators.sql'),
    (13, 'end_empty_tables', 'read', '5ccfa4b83e7e8d5179c3d35b72f19c05', '5ab917dc44f3704ae76d9b17a8999122', 'end-empty-tables.sql'),
    (14, 'end_table_when_empty', 'read', '54c6c567b5f1033f5676726c11d86915', '6e0851cbaf45aa354d4deb67981519d2', 'end-empty-tables.sql'),
    (15, 'require_open_table', 'read', '37101d54f3689105e9c140d55ba58217', '595582f1710bc6327076a0671aa94fb5', 'end-empty-tables.sql'),
    (16, '_attempts_guard', 'read', 'b1b69dbbdf10d50f78655a0da3b3ac69', '9406938991e89dcd38d0686a279b432a', 'join-create.sql'),
    (17, '_one_table_rule', 'read', '30437ab489be968f83ae9ffd68266f0f', 'e456c651d5a66b5bcf9d7b59d8efab23', 'free-codes-part1.sql'),
    (18, '_code_guesses_check', 'read', '0043a0254323863d273f09145b293559', 'ecc82b14577a13d0edf2e9d1a950268d', 'join-create.sql'),
    (19, '_code_guess_failed', 'read', 'd4387df71753f02932beb9a2dd1e73e7', 'b2c7c4276512709f7c4a490f60b6d874', 'join-create.sql'),
    (20, 'is_admin', 'read', '20d867027c1e50b5747a5047d7809426', '918628e27b8950c4a5986c4a25cd21cd', 'private-tables-part1.sql'),
    (21, 'is_table_member', 'read', '29383c3018543a5e7faa045a1beee164', 'ef5eb3d1d03b3bee36d51ac7e4880191', 'private-tables-part1.sql'),
    (22, 'is_current_spectator', 'read', '0d6170b3543a18cb6bc71288e0f5edf6', '59ace7c42e8a998aa0a79a1dfa26e970', 'private-tables-part1.sql'),
    (23, 'set_seat', 'read', '9839026aa3f3b5d8d72281aeeac499d6', 'c2ad3ae6054072f6b37d740fb9b8f45b', 'phase3-e1-seating.sql')
),
-- Moderation M1 part 2's bodies of the two functions it changes (LF / CRLF).
m1_fp(fn, lf, crlf) as (
  values
    ('join_table_by_code', 'cf40593ee5afda235144a13e38d27f4a', 'c3ee9ced2e1033f9c068acd3325c5583'),
    ('watch_table', '5bf6065de215d92a02af63d035c7f910', '2aa5f9c37d65271f3b4619e58c171ea0')
),
-- The moderation slices' own objects (M1, M2, M3, M6): listed as INFO in
-- section 09, not STOP.
m1_names(name) as (
  values ('blocks'), ('blocks_pkey'), ('blocks_blocked_id_idx'),
         ('block_player'), ('unblock_player'), ('get_my_blocks'), ('_is_blocked_from_table'),
         ('block_player_by_id'),
         ('table_kicks'), ('table_kicks_pkey'), ('table_kicks_created_at_idx'), ('table_kicks_kicked_id_idx'),
         ('table_kicks_host_id_idx'), ('_is_kicked_from_table'), ('_send_kick_notice'), ('kick_player'),
         ('kick_topic_allows'), ('admin_recent_kicks'),
         ('player_reports'), ('player_reports_pkey'), ('player_reports_created_at_idx'), ('player_reports_reported_idx'),
         ('player_reports_reporter_idx'), ('player_reports_pair_idx'), ('_report_avatar_object'), ('report_player'),
         ('admin_list_reports'), ('admin_delete_report'), ('purge_old_reports')
),
fp_live as (
  select f.o, f.fn, f.kind, f.lf, f.crlf, f.src, l.n, l.sig, l.m, l.info
  from fp f
  cross join lateral (
    select count(*) as n,
           min(p.oid::regprocedure::text) as sig,
           min(md5(p.prosrc)) as m,
           min(case when p.prosecdef then 'definer' else 'invoker' end
               || ' | ' || coalesce(array_to_string(p.proconfig, ' '), 'no config')
               || ' | authenticated EXECUTE ' || has_function_privilege('authenticated', p.oid, 'EXECUTE')::text) as info
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public'
      and p.proname = f.fn
  ) l
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
expected_fns(name) as (
  -- Slice E's 49 (chat_topic_allows only while it exists: moderation M5c1
  -- c2 removed it).
  select e from unnest(array[
    'acknowledge_deal_cut', 'can_read_game', 'can_read_table', 'chat_topic_allows', 'claim_win',
    'clear_win_claim', 'computer_acknowledge_deal_cut', 'computer_confirm_count', 'computer_discard_to_crib',
    'computer_draw_cut_card', 'computer_hand', 'computer_next_hand', 'computer_play_card', 'computer_show_crib',
    'computer_start_game_with_deal', 'confirm_count', 'confirm_win', 'create_computer_table', 'create_table',
    'discard_to_crib', 'draw_cut_card', 'follow_user', 'get_computer_profiles', 'get_god_wins',
    'get_leaderboard', 'get_my_follows', 'get_solo_leaderboard', 'get_solo_stats', 'get_spectator_reveals',
    'get_table_spectators', 'is_admin', 'is_current_spectator', 'is_game_player', 'is_public_table',
    'is_table_member', 'join_table_by_code', 'leave_computer_table', 'leave_table', 'next_hand', 'play_card',
    'remove_spectator', 'set_seat', 'show_crib', 'show_hand', 'spectator_heartbeat', 'start_game_with_deal',
    'stop_watching', 'unfollow_user', 'watch_table']) as e
  where e <> 'chat_topic_allows' or to_regprocedure('public.chat_topic_allows(text, boolean)') is not null
  union all
  -- Moderation M1 part 1's three RPCs, once its table exists.
  select unnest(array['block_player', 'get_my_blocks', 'unblock_player'])
  where to_regclass('public.blocks') is not null
  union all
  -- Moderation M3 part 1's three, M6 part 1's three and M5a part 1's one,
  -- each once it exists.
  select unnest(array['admin_recent_kicks', 'kick_player', 'kick_topic_allows'])
  where to_regclass('public.table_kicks') is not null
  union all
  select unnest(array['admin_delete_report', 'admin_list_reports', 'report_player'])
  where to_regclass('public.player_reports') is not null
  union all
  select 'table_topic_allows'
  where to_regprocedure('public.table_topic_allows(text)') is not null
  union all
  -- Moderation M5c1 part 1's chat RPC, once it exists.
  select 'send_table_message'
  where to_regprocedure('public.send_table_message(uuid, text)') is not null
  union all
  -- Moderation M2 part 1's block by account id, once it exists.
  select 'block_player_by_id'
  where to_regprocedure('public.block_player_by_id(uuid)') is not null
),
rt_parts as (
  select pt.relid
  from pg_partition_tree(to_regclass('realtime.messages')) pt
  where pt.isleaf
),
mod_words(re) as (
  values ('(report|block|mute|kick|\mbans?\M|\mbanned\M|hide|hidden|moderat)')
),
avatar_objects as (
  select coalesce((o.metadata ->> 'size')::bigint, 0) as bytes
  from storage.objects o
  where o.bucket_id = 'avatars'
),
est(players, per_day, days, row_bytes) as (
  values (10000::bigint, 50::bigint, 3::bigint, 250::bigint)
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== 01. Realtime ==============================================================
  select 1 as s, 0 as o, pol.policyname::text as k, 0 as k2, 'realtime'::text as section,
         ('realtime.messages policy "' || pol.policyname || '" (' || pol.cmd || ', ' || pol.permissive
          || ', roles ' || array_to_string(pol.roles, ',') || ')')::text as item,
         ('USING ' || coalesce(pol.qual, '(none)') || ' | WITH CHECK ' || coalesce(pol.with_check, '(none)'))::text as value,
         (case when pol.policyname in ('table chat: members receive', 'table chat: members send')
               then 'FLAG: table-chat.sql''s policy; one table topic written through an RPC replaces or narrows it'
               when pol.policyname = 'table kicks: people at the table receive'
               then 'moderation M3''s kicks policy (kicks: topics only); the chat suites know it'
               when pol.policyname = 'table events: people at the table receive'
               then 'moderation M5a''s table events policy (table: topics only); the chat suites know it'
               else 'STOP: not a table-chat, M3 kicks or M5a table events policy; the chat prechecks expect exactly those' end)::text as note
  from pg_policies pol
  where pol.schemaname = 'realtime' and pol.tablename = 'messages'

  union all
  select 1, 1, '', 0, 'realtime', 'realtime.messages: policies / RLS on / forced',
         (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages')::text
           || ' / ' || coalesce((select c.relrowsecurity::text || ' / ' || c.relforcerowsecurity::text
                                 from pg_class c where c.oid = to_regclass('realtime.messages')), '(no realtime.messages)'),
         case when (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages') = 2
              then 'as the chat prechecks expect (exactly 2)'
              when (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages') = 3
                   and exists (select 1 from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages'
                                 and pol.policyname = 'table kicks: people at the table receive')
              then 'as the chat prechecks expect (the two plus moderation M3''s kicks policy)'
              when (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages') = 4
                   and exists (select 1 from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages'
                                 and pol.policyname = 'table kicks: people at the table receive')
                   and exists (select 1 from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages'
                                 and pol.policyname = 'table events: people at the table receive')
              then 'as the chat prechecks expect (the two plus moderation M3''s kicks policy and M5a''s table events policy)'
              when (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages') = 2
                   and (to_regprocedure('public.chat_topic_allows(text, boolean)') is null and to_regprocedure('public.send_table_message(uuid, text)') is not null)
                   and exists (select 1 from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages'
                                 and pol.policyname = 'table kicks: people at the table receive')
                   and exists (select 1 from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages'
                                 and pol.policyname = 'table events: people at the table receive')
              then 'as moderation M5c1 c2 left it: exactly M3''s kicks policy and M5a''s table events policy (both receive only)'
              else 'STOP: the chat prechecks expect exactly the two table-chat policies (plus M3''s kicks policy and M5a''s table events policy; only those two after moderation M5c1 c2)' end

  union all
  select 1, 2, '', 0, 'realtime', 'realtime.messages: kind / leaf partitions / estimated rows / total size',
         coalesce((select case c.relkind when 'p' then 'partitioned' when 'r' then 'table' else c.relkind::text end
                   from pg_class c where c.oid = to_regclass('realtime.messages')), '(missing)')
           || ' / ' || (select count(*) from rt_parts)::text
           || ' / ' || coalesce((select sum(greatest(c.reltuples, 0))::bigint from pg_class c join rt_parts rp on rp.relid = c.oid), 0)::text
           || ' / ' || pg_size_pretty(coalesce((select sum(pg_total_relation_size(rp.relid)) from rt_parts rp), 0)::bigint),
         'INFO: Realtime writes a row here for every broadcast sent from the database (realtime.send); estimated rows come from the planner statistics, not a count'

  union all
  select 1, 3, '', 0, 'realtime', 'realtime.messages: oldest / newest leaf partition',
         coalesce((select min(rp.relid::regclass::text) || ' / ' || max(rp.relid::regclass::text) from rt_parts rp), '(none)'),
         'INFO: Realtime keeps a few daily partitions and drops the old ones itself'

  union all
  select 1, 4, '', 0, 'realtime', 'realtime.send(jsonb, text, text, boolean) exists',
         (to_regprocedure('realtime.send(jsonb, text, text, boolean)') is not null)::text,
         case when to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null
              then 'STOP: no realtime.send; an RPC cannot broadcast from the server'
              else 'INFO: what a send-through-RPC chat would call after storing the row' end

  union all
  select 1, 4, '', 1, 'realtime', 'moderation M5c1: send_table_message(uuid, text) / _broadcast_table_message(text, jsonb) exist',
         (to_regprocedure('public.send_table_message(uuid, text)') is not null)::text || ' / '
           || (to_regprocedure('public._broadcast_table_message(text, jsonb)') is not null)::text,
         'INFO: moderation M5c1''s chat through the server (moderation-m5c1-part1.sql): checks the sender, cleans the text, limits 1 in 2 s and 3 in 10 s per sender per table (counted in realtime.messages), broadcasts {event chat, id, sender_id, text, at} on table:<id> through the helper, and reads the stored row back. No table, no policy; the old chat policies stay until the c2 hard cut'

  union all
  select 1, 4, '', 2, 'realtime', 'moderation M5c1 c2: the table-chat policies / chat_topic_allows removed',
         (not exists (select 1 from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages'
                        and pol.policyname in ('table chat: members receive', 'table chat: members send')))::text || ' / '
           || (to_regprocedure('public.chat_topic_allows(text, boolean)') is null)::text,
         'INFO: moderation-m5c1c2-part1.sql drops the old per-sender chat path (chat:<table>:<sender>): no client may send on any private topic afterwards; the rollback restores both policies and the function exactly'

  union all
  select 1, 5, '', 0, 'realtime', 'publication supabase_realtime: tables',
         coalesce((select string_agg(pt.schemaname || '.' || pt.tablename, ', ' order by pt.schemaname, pt.tablename)
                   from pg_publication_tables pt where pt.pubname = 'supabase_realtime'), '(none)'),
         case when (select count(*) from pg_publication_tables pt where pt.pubname = 'supabase_realtime') = 0
              then 'INFO: empty, as the M5 final cleanup left it (moderation-m5-cleanup-part1.sql): the app listens to no table'
              else 'INFO: postgres_changes reach clients only for these; the app listens to none since App B (the M5 final cleanup takes them out)' end

  union all
  select 1, 6, '', 0, 'realtime', 'table_members replica identity',
         coalesce((select case c.relreplident when 'd' then 'default (primary key)' when 'f' then 'full'
                                              when 'n' then 'nothing' when 'i' then 'index' end
                   from pg_class c where c.oid = to_regclass('public.table_members')), '(missing)'),
         'INFO: a kicked player''s screen learns of the kick from its DELETE event; RLS is not applied to DELETE events'

  union all
  select 1, 7, n.nspname::text || '.' || c.relname::text, 0, 'realtime',
         'C4 view: relation with "chat" in its name',
         n.nspname::text || '.' || c.relname::text || ' (' || c.relkind::text || ')',
         'FLAG: table-chat-verification.sql C4 fails on it; keeping messages 3 days (decision 2) ends C4''s "nothing stored" rule'
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where c.relname ilike '%chat%'
    and c.relkind in ('r', 'p', 'v', 'm', 'f')
    and n.nspname not in ('pg_catalog', 'information_schema')
    and n.nspname not like 'pg\_toast%'
    and n.nspname not like 'pg\_temp%'

  union all
  select 1, 8, '', 0, 'realtime', 'C4 view: relations with "chat" in the name / public functions with "chat" besides chat_topic_allows / buckets with "chat"',
         (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where c.relname ilike '%chat%' and c.relkind in ('r', 'p', 'v', 'm', 'f')
            and n.nspname not in ('pg_catalog', 'information_schema')
            and n.nspname not like 'pg\_toast%' and n.nspname not like 'pg\_temp%')::text
           || ' / ' || coalesce((select string_agg(p.proname::text, ', ' order by p.proname)
                                 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                 where n.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows'), '(none)')
           || ' / ' || (select count(*) from storage.buckets b where b.id ilike '%chat%' or b.name ilike '%chat%')::text,
         'C4 today expects 0 / (none) / 0'

  union all
  -- ==== 02. Function fingerprints =================================================
  select 2, fl.o, fl.fn, 0, 'fp',
         fl.fn || ' (' || coalesce(fl.sig, 'missing') || ')',
         coalesce(fl.m, '(missing)') || ' | overloads ' || fl.n::text || coalesce(' | ' || fl.info, ''),
         case when fl.n = 0 and fl.fn = 'chat_topic_allows' and to_regprocedure('public.send_table_message(uuid, text)') is not null
                then 'INFO: removed by moderation M5c1 c2 (moderation-m5c1c2-part1.sql), as planned'
              when fl.n = 0 then 'STOP: missing. Paste back: select proname, pg_get_function_identity_arguments(oid) from pg_proc where proname ilike ''%' || fl.fn || '%'';'
              when fl.n > 1 then 'STOP: ' || fl.n::text || ' overloads. Paste back: select pg_get_functiondef(oid) from pg_proc where proname = ''' || fl.fn || ''';'
              when fl.m in (fl.lf, fl.crlf) then
                case fl.kind
                  when 'fp' then 'as expected (' || fl.src || ', ' || case when fl.m = fl.lf then 'LF' else 'CRLF' end || '): FINGERPRINTED, stays byte-for-byte'
                  when 'change' then 'FLAG: as expected (' || fl.src || ', ' || case when fl.m = fl.lf then 'LF' else 'CRLF' end || '); a moderation slice is expected to change it'
                  else 'as expected (' || fl.src || ', ' || case when fl.m = fl.lf then 'LF' else 'CRLF' end || ')' end
              when fl.m in (select m.lf from m1_fp m where m.fn = fl.fn union all select m.crlf from m1_fp m where m.fn = fl.fn)
                then 'as expected after moderation M1 part 2 (moderation-m1-part2.sql: the Block List refusal)'
              else 'STOP: not ' || fl.src || '''s text. Paste back: select pg_get_functiondef(''public.' || fl.fn || '''::regproc);'
         end
  from fp_live fl

  union all
  -- ==== 03. Columns ===============================================================
  select 3, mr.o, mr.relname, att.attnum::int, 'column',
         mr.relname || '.' || att.attname::text,
         format_type(att.atttypid, att.atttypmod)
           || case when att.attnotnull then ' not null' else '' end
           || coalesce(' default ' || pg_get_expr(ad.adbin, ad.adrelid), ''),
         ''
  from mod_rels mr
  join pg_attribute att on att.attrelid = mr.oid and att.attnum > 0 and not att.attisdropped
  left join pg_attrdef ad on ad.adrelid = att.attrelid and ad.adnum = att.attnum
  where mr.relname in ('tables', 'table_members', 'table_spectators', 'profiles', 'admin_users')

  union all
  select 3, 99, mt.relname, 0, 'column', mt.relname || ': exists', 'false', 'STOP: missing'
  from mod_tables mt
  where mt.detail and to_regclass('public.' || mt.relname) is null

  union all
  -- ==== 04. Constraints ===========================================================
  select 4, mr.o, mr.relname, 0, 'constraint',
         mr.relname || ': ' || con.conname::text,
         pg_get_constraintdef(con.oid),
         case when con.conname::text like '%ended_reason%'
              then 'FLAG: a kick that ends the game may need its own reason here (or reuse player_left)'
              else '' end
  from mod_rels mr
  join pg_constraint con on con.conrelid = mr.oid
  where mr.detail

  union all
  -- ==== 05. Indexes ===============================================================
  select 5, mr.o, mr.relname, 0, 'index',
         mr.relname || ': ' || ic.relname::text,
         pg_get_indexdef(ix.indexrelid),
         ''
  from mod_rels mr
  join pg_index ix on ix.indrelid = mr.oid
  join pg_class ic on ic.oid = ix.indexrelid
  where mr.detail

  union all
  -- ==== 06. Triggers ==============================================================
  select 6, mr.o, mr.relname || ' ' || tg.tgname::text, 0, 'trigger',
         mr.relname || ': ' || tg.tgname::text || ' (enabled ' || tg.tgenabled::text || ')',
         pg_get_triggerdef(tg.oid),
         case when tg.tgname in ('table_members_zz_table_event', 'table_spectators_zz_table_event', 'tables_zz_table_event')
              then 'INFO: moderation M5a''s table event trigger (moderation-m5a-part1.sql)'
              when tg.tgname in ('games_state_version', 'games_zz_game_event')
              then 'INFO: moderation M5b1''s game event trigger (moderation-m5b1-part1.sql; games_zz_game_event fires at commit)'
              when tg.tgname = 'table_members_zz_scores_event'
              then 'INFO: moderation M5b2''s scores event trigger (moderation-m5b2-part1.sql; fires at commit, once per table)'
              when mr.relname = 'table_members'
              then 'FLAG: a block/kick check on a new seat would be a trigger beside these; BEFORE triggers fire in name order'
              else '' end
  from mod_rels mr
  join pg_trigger tg on tg.tgrelid = mr.oid and not tg.tgisinternal
  where mr.detail

  union all
  -- ==== 07. Policies ==============================================================
  select 7, mr.o, mr.relname, 0, 'policy',
         mr.relname || ': RLS on / forced',
         mr.relrowsecurity::text || ' / ' || mr.relforcerowsecurity::text,
         case when mr.relrowsecurity then '' else 'STOP: RLS is off' end
  from mod_rels mr
  where mr.detail

  union all
  select 7, mr.o, mr.relname || ' ' || pol.policyname::text, 1, 'policy',
         mr.relname || ': "' || pol.policyname || '" (' || pol.cmd || ', ' || pol.permissive
           || ', roles ' || array_to_string(pol.roles, ',') || ')',
         'USING ' || coalesce(pol.qual, '(none)') || ' | WITH CHECK ' || coalesce(pol.with_check, '(none)'),
         case when mr.relname = 'tables' and pol.cmd = 'SELECT'
              then 'FLAG: hiding a blocker''s tables from a blocked person''s Open Tables would go here or in the list''s read'
              else '' end
  from mod_rels mr
  join pg_policies pol on pol.schemaname = 'public' and pol.tablename = mr.relname
  where mr.detail

  union all
  -- ==== 08. Grants ================================================================
  select 8, mr.o, mr.relname, g.o, 'grant',
         mr.relname || ': ' || g.rolname,
         coalesce(nullif((select string_agg(a.privilege_type, ', ' order by a.privilege_type)
                          from aclexplode(coalesce(mr.relacl, acldefault('r', mr.relowner))) a
                          where a.grantee = case when g.rolname = 'PUBLIC' then 0::oid
                                                 else (select ro.oid from pg_roles ro where ro.rolname = g.rolname) end), ''),
                  '(none)'),
         ''
  from mod_rels mr
  cross join client_roles g

  union all
  select 8, 50, 'realtime.messages', 2, 'grant', 'realtime.messages: authenticated',
         coalesce((select nullif(string_agg(a.privilege_type, ', ' order by a.privilege_type), '')
                   from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
                   where c.oid = to_regclass('realtime.messages')
                     and a.grantee = (select ro.oid from pg_roles ro where ro.rolname = 'authenticated')), '(none)'),
         'INFO: the chat policies need SELECT (receive) and INSERT (send)'

  union all
  -- ==== 09. Existing moderation-like objects =====================================
  select 9, 0, n.nspname::text || '.' || c.relname::text, 0, 'existing',
         'relation ' || n.nspname::text || '.' || c.relname::text || ' (' || c.relkind::text || ')',
         'matches ' || (select re from mod_words),
         case when n.nspname = 'public' and c.relname in (select m.name from m1_names m)
              then 'INFO: a moderation slice''s own (moderation-m1-part1.sql, moderation-m3-part1.sql, moderation-m6-part1.sql)'
              else 'STOP: expected none; look at it before naming a new object' end
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where c.relname ~* (select re from mod_words)
    and c.relkind in ('r', 'p', 'v', 'm', 'f')
    and n.nspname not in ('pg_catalog', 'information_schema')
    and n.nspname not like 'pg\_toast%'
    and n.nspname not like 'pg\_temp%'
    and n.nspname not in ('auth', 'storage', 'realtime', 'extensions', 'graphql', 'graphql_public',
                          'pgsodium', 'pgsodium_masks', 'vault', 'supabase_functions', 'supabase_migrations',
                          'net', 'cron', 'pgbouncer')

  union all
  select 9, 1, p.oid::regprocedure::text, 0, 'existing',
         'function ' || p.oid::regprocedure::text,
         'matches ' || (select re from mod_words),
         case when p.proname in (select m.name from m1_names m)
              then 'INFO: a moderation slice''s own (moderation-m1-part1.sql, moderation-m2-part1.sql, moderation-m3-part1.sql, moderation-m6-part1.sql)'
              else 'STOP: expected none; look at it before naming a new function' end
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname ~* (select re from mod_words)

  union all
  select 9, 2, t.typname::text, 0, 'existing',
         'type public.' || t.typname::text,
         'matches ' || (select re from mod_words),
         'STOP: expected none'
  from pg_type t
  join pg_namespace n on n.oid = t.typnamespace
  where n.nspname = 'public'
    and t.typtype in ('e', 'd', 'c')
    and t.typname ~* (select re from mod_words)
    and not exists (select 1 from pg_class c where c.reltype = t.oid and c.relkind <> 'c')

  union all
  select 9, 3, pol.tablename::text || ' ' || pol.policyname::text, 0, 'existing',
         'policy "' || pol.policyname || '" on public.' || pol.tablename,
         'matches ' || (select re from mod_words),
         'STOP: expected none'
  from pg_policies pol
  where pol.schemaname = 'public'
    and pol.policyname ~* (select re from mod_words)

  union all
  select 9, 4, tg.tgname::text, 0, 'existing',
         'trigger ' || tg.tgname::text || ' on ' || tg.tgrelid::regclass::text,
         'matches ' || (select re from mod_words),
         'STOP: expected none'
  from pg_trigger tg
  join pg_class c on c.oid = tg.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where not tg.tgisinternal
    and n.nspname = 'public'
    and tg.tgname ~* (select re from mod_words)

  union all
  select 9, 5, b.id::text, 0, 'existing',
         'storage bucket ' || b.id::text,
         'matches ' || (select re from mod_words),
         'STOP: expected none'
  from storage.buckets b
  where b.id ~* (select re from mod_words) or b.name ~* (select re from mod_words)

  union all
  select 9, 9, 'zz', 0, 'existing', 'moderation-like objects found (all kinds above)',
         ((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where c.relname ~* (select re from mod_words) and c.relkind in ('r', 'p', 'v', 'm', 'f')
             and n.nspname not in ('pg_catalog', 'information_schema')
             and n.nspname not like 'pg\_toast%' and n.nspname not like 'pg\_temp%'
             and n.nspname not in ('auth', 'storage', 'realtime', 'extensions', 'graphql', 'graphql_public',
                                   'pgsodium', 'pgsodium_masks', 'vault', 'supabase_functions', 'supabase_migrations',
                                   'net', 'cron', 'pgbouncer'))
          + (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname ~* (select re from mod_words))
          + (select count(*) from pg_policies pol where pol.schemaname = 'public' and pol.policyname ~* (select re from mod_words))
          + (select count(*) from storage.buckets b where b.id ~* (select re from mod_words) or b.name ~* (select re from mod_words)))::text,
         'expected 0 before moderation M1, plus 5 after M1 part 1 (blocks and its four functions), plus 1 after M2 part 1 (block_player_by_id); types and triggers are listed above, not counted here'

  union all
  -- ==== 10. Client-executable functions ===========================================
  select 10, 0, '', 0, 'client fn', 'functions authenticated may execute in public (distinct names)',
         (select count(*) from client_fns)::text,
         case when (select count(*) from client_fns) = 49 and to_regclass('public.blocks') is null then 'as slice E left it (49)'
              when (select count(*) from client_fns) = 52 and to_regclass('public.blocks') is not null
                   and to_regprocedure('public.block_player_by_id(uuid)') is null then 'as moderation M1 part 1 left it (52)'
              when (select count(*) from client_fns) = 53 and to_regprocedure('public.block_player_by_id(uuid)') is not null
                   and to_regclass('public.table_kicks') is null then 'as moderation M2 part 1 left it (53)'
              when (select count(*) from client_fns) = 56 and to_regclass('public.table_kicks') is not null
                   and to_regclass('public.player_reports') is null then 'as moderation M3 part 1 left it (56)'
              when (select count(*) from client_fns) = 59 and to_regclass('public.player_reports') is not null
                   and to_regprocedure('public.table_topic_allows(text)') is null then 'as moderation M6 part 1 left it (59)'
              when (select count(*) from client_fns) = 60 and to_regprocedure('public.table_topic_allows(text)') is not null
                   and to_regprocedure('public.send_table_message(uuid, text)') is null
                then 'as moderation M5a part 1 left it (60)'
              when (select count(*) from client_fns) = 61 and to_regprocedure('public.send_table_message(uuid, text)') is not null
                then 'as moderation M5c1 part 1 left it (61)'
              when (select count(*) from client_fns) = 60 and (to_regprocedure('public.chat_topic_allows(text, boolean)') is null and to_regprocedure('public.send_table_message(uuid, text)') is not null)
                then 'as moderation M5c1 c2 left it (60: chat_topic_allows removed)'
              else 'FLAG: not 49 (52 after moderation M1 part 1, 53 after M2, 56 after M3, 59 after M6, 60 after M5a, 61 after M5c1, 60 after M5c1 c2); see the next two rows' end

  union all
  select 10, 1, '', 0, 'client fn', 'executable by authenticated but not in slice E''s 49 (plus M1''s 3 once public.blocks exists)',
         coalesce((select string_agg(cf.name, ', ' order by cf.name) from client_fns cf
                   where cf.name not in (select e.name from expected_fns e)), '(none)'),
         case when exists (select 1 from client_fns cf where cf.name not in (select e.name from expected_fns e))
              then 'STOP: paste back; slice-e-grants-verification.sql X1 would fail' else '' end

  union all
  select 10, 2, '', 0, 'client fn', 'in slice E''s 49 (plus M1''s 3 once public.blocks exists) but not executable by authenticated (or missing)',
         coalesce((select string_agg(e.name, ', ' order by e.name) from expected_fns e
                   where e.name not in (select cf.name from client_fns cf)), '(none)'),
         case when exists (select 1 from expected_fns e where e.name not in (select cf.name from client_fns cf))
              then 'STOP: paste back; slice-e-grants-verification.sql X1 would fail' else '' end

  union all
  select 10, 3, '', 0, 'client fn', 'the full list',
         (select string_agg(cf.name, ', ' order by cf.name) from client_fns cf),
         'INFO: each moderation slice that adds a client function adds it to X1''s list'

  union all
  -- ==== 11. pg_cron ===============================================================
  select 11, 0, lpad(coalesce(j.jobid, ''), 6, '0'), 0, 'cron',
         'job ' || coalesce(j.jobid, '?') || ' ' || coalesce(j.jobname, '(no name)'),
         'schedule ' || coalesce(j.schedule, '') || ' | active ' || coalesce(j.active, ''),
         'command: ' || coalesce(j.command, '')
  from xmltable('/table/row'
         passing (case when to_regclass('cron.job') is null then '<table/>'::xml
                       else query_to_xml('select jobid, jobname, schedule, active, command from cron.job order by jobid', false, false, '') end)
         columns jobid text path 'jobid', jobname text path 'jobname', schedule text path 'schedule',
                 active text path 'active', command text path 'command') j

  union all
  select 11, 1, 'zz', 0, 'cron', 'pg_cron installed',
         (to_regclass('cron.job') is not null)::text,
         case when to_regclass('cron.job') is null then 'STOP: no pg_cron; the 3-day chat cleanup needs it' else 'INFO: a chat cleanup job would sit beside these' end

  union all
  -- ==== 12. attempt_log ===========================================================
  select 12, 0, '', 0, 'attempt', 'attempt_log action check',
         coalesce((select pg_get_constraintdef(con.oid) from pg_constraint con
                   where con.conrelid = to_regclass('public.attempt_log') and con.conname = 'attempt_log_action_check'), '(missing)'),
         'INFO: moderation M3 added kick and M6 report_filed; a chat rate limit through _attempts_guard would widen this check again'

  union all
  select 12, 1, '', 0, 'attempt', '_attempts_guard signature',
         coalesce((select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = '_attempts_guard'), '(missing)'),
         ''

  union all
  -- ==== 13. Sizes =================================================================
  select 13, mr.o, mr.relname, 0, 'size', mr.relname || ': rows / total size',
         (xpath('/row/n/text()', query_to_xml('select count(*) as n from public.' || quote_ident(mr.relname), false, true, '')))[1]::text
           || ' / ' || pg_size_pretty(pg_total_relation_size(mr.oid))
           || ' (' || pg_total_relation_size(mr.oid)::text || ' bytes)',
         ''
  from mod_rels mr
  where mr.relname <> 'computer_accounts'

  union all
  select 13, 20, '', 0, 'size', 'database total size',
         pg_size_pretty(pg_database_size(current_database())) || ' (' || pg_database_size(current_database())::text || ' bytes)',
         'INFO: compare with your plan''s database quota'

  union all
  select 13, 21, '', 0, 'size', 'avatars bucket: objects / total bytes',
         (select count(*) from avatar_objects)::text || ' / ' || pg_size_pretty(coalesce((select sum(ao.bytes) from avatar_objects ao), 0)::bigint),
         'INFO: one fixed file per player, overwritten on change; a report cannot point at an old picture'

  union all
  select 13, 22, b.id::text, 0, 'size', 'storage bucket ' || b.id::text,
         'public ' || b.public::text || ' | file_size_limit ' || coalesce(b.file_size_limit::text, '(none)')
           || ' | allowed ' || coalesce(array_to_string(b.allowed_mime_types, ','), '(any)'),
         'INFO: an avatar report that keeps the picture would copy it into a private bucket'
  from storage.buckets b

  union all
  select 13, 30, '', 0, 'size', 'Postgres server_version',
         current_setting('server_version'),
         ''

  union all
  -- ==== 14. Estimate: kept chat ===================================================
  select 14, 0, '', 0, 'estimate', 'ESTIMATE: messages held over 3 days',
         e.players::text || ' players x ' || e.per_day::text || ' messages a day x ' || e.days::text || ' days = '
           || (e.players * e.per_day * e.days)::text || ' rows',
         'ESTIMATE: assumes all ' || e.players::text || ' players chat every day (an upper bound); it scales linearly'
  from est e

  union all
  select 14, 1, '', 0, 'estimate', 'ESTIMATE: table size at about 250 bytes a row including indexes',
         (e.players * e.per_day * e.days)::text || ' rows x ' || e.row_bytes::text || ' bytes = '
           || (e.players * e.per_day * e.days * e.row_bytes)::text || ' bytes = '
           || pg_size_pretty(e.players * e.per_day * e.days * e.row_bytes),
         'ESTIMATE: the steady state (3 days kept); 140-character messages fit the 250 bytes'
  from est e

  union all
  select 14, 2, '', 0, 'estimate', 'ESTIMATE: per 1,000 daily chatting players',
         '1000 x ' || e.per_day::text || ' x ' || e.days::text || ' x ' || e.row_bytes::text || ' bytes = '
           || (1000 * e.per_day * e.days * e.row_bytes)::text || ' bytes = '
           || pg_size_pretty(1000 * e.per_day * e.days * e.row_bytes),
         'ESTIMATE'
  from est e

  union all
  select 14, 3, '', 0, 'estimate', 'ESTIMATE: rows the hourly cleanup deletes',
         (e.players * e.per_day)::text || ' a day / 24 = about ' || ceil((e.players * e.per_day) / 24.0)::bigint::text || ' rows an hour',
         'ESTIMATE: deleted rows leave space that autovacuum reuses; the file does not shrink. Daily partitions would be dropped instead'
  from est e

  union all
  select 14, 4, '', 0, 'estimate', 'ESTIMATE: realtime.messages, if the server broadcasts with realtime.send',
         'up to about the same number of rows again, kept by Realtime for its own few days',
         'ESTIMATE: Realtime writes each database broadcast into realtime.messages (section 01 shows its size today)'
  from est e
) z
order by z.s, z.o, z.k, z.k2, z.item;
