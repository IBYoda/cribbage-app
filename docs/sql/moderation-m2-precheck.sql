-- Moderation, slice M2: BLOCK AND HIDE IN CHAT. The PRE-CHECK (read-only).
-- Run in the Supabase Dashboard -> SQL Editor before
-- docs/sql/moderation-m2-part1.sql, and any time after. It reads only; it
-- changes nothing: no writes, no DO block, no temp table, no SET.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M2): THIS FILE -> moderation-m2-part1.sql ->
-- moderation-m2-verification.sql -> slice-e-grants-verification.sql and
-- moderation-m1-verification.sql -> the app (PR) -> the hand test.
--
-- ONE query, so the editor shows every row in one grid. Columns: section,
-- item, value, note (all text). The FIRST row is the STATE: "before part 1"
-- or "part 1 present". A note starting with STOP means: do not run the next
-- M2 file; paste the result back first. INFO rows are facts, not blockers.
--
-- WHAT IT LOOKS FOR
--   state  the one-line summary (STOP when M1 is not fully in).
--   fp     leave_table, end_timed_out_sessions, assign_table_seat,
--          table_host (FINGERPRINTED), join_table_by_code and watch_table
--          (M1 part 2's: c3ee9ced... / 2aa5f9c3... with CRLF, cf40593e... /
--          5bf6065d... with LF), spectator_heartbeat, remove_spectator,
--          chat_topic_allows, _attempts_guard: md5 of the live body, LF or
--          CRLF. block_player, unblock_player, get_my_blocks,
--          _is_blocked_from_table: moderation-m1-part1.sql's bodies (md5
--          with carriage returns removed). M2 changes none of them.
--   m1     public.blocks present, RLS on, no policies, no client privileges;
--          attempt_log allows block_change.
--   part1  block_player_by_id(uuid): absent before; after: part 1's body,
--          security definer, search_path '', EXECUTE for authenticated
--          only. Any other function named block_player_by_id: STOP.
--   grants the client-executable functions: 52 before part 1 (slice E's 49
--          plus M1's three), 53 after (plus block_player_by_id).
--   count  blocks rows; profiles with a blank nickname (INFO: the chat
--          card's Block reaches them, the Profile page's box cannot).

with fp_known(o, fn, sig, lf, crlf) as (
  values
    (1, 'leave_table', 'public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa'),
    (2, 'end_timed_out_sessions', 'public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c'),
    (3, 'assign_table_seat', 'public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb'),
    (4, 'table_host', 'public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d'),
    (5, 'join_table_by_code', 'public.join_table_by_code(text, boolean, uuid)', 'cf40593ee5afda235144a13e38d27f4a', 'c3ee9ced2e1033f9c068acd3325c5583'),
    (6, 'watch_table', 'public.watch_table(text, uuid)', '5bf6065de215d92a02af63d035c7f910', '2aa5f9c37d65271f3b4619e58c171ea0'),
    (7, 'spectator_heartbeat', 'public.spectator_heartbeat(uuid)', '41d2ea0e865c2a9d5fa7203875a27ace', '6b7c271d78eb4f72c1aff3c851b578e1'),
    (8, 'remove_spectator', 'public.remove_spectator(uuid, uuid)', 'dafa688f1b8c194e4be575cd0625ba12', '9786b9a5e50245365a2598b18da5892e'),
    (9, 'chat_topic_allows', 'public.chat_topic_allows(text, boolean)', '0458d5122d68d511b2e0fbceafe84aae', 'c4e6eda360de7d7723c4069e60d95345'),
    (10, '_attempts_guard', 'public._attempts_guard(uuid, text, integer, interval, text)', 'b1b69dbbdf10d50f78655a0da3b3ac69', '9406938991e89dcd38d0686a279b432a')
),
m1_known(o, fn, sig, lf) as (
  values
    (1, 'block_player', 'public.block_player(text)', '10f6b07a3224aff16e1326daa6af5759'),
    (2, 'unblock_player', 'public.unblock_player(uuid)', 'c0363d27028d621c0008654506bade75'),
    (3, 'get_my_blocks', 'public.get_my_blocks()', '3d50e2a273ca16b23f6d89348016d8de'),
    (4, '_is_blocked_from_table', 'public._is_blocked_from_table(uuid, uuid)', '162f914c3b209186c819c66d18a23a99')
),
fp_state as (
  select k.o, k.fn, k.sig, k.lf, k.crlf,
         (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(k.sig)) as m
  from fp_known k
),
m1_state as (
  select k.o, k.fn, k.sig, k.lf,
         (select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure(k.sig)) as m
  from m1_known k
),
byid as (
  select p.oid,
         md5(replace(p.prosrc, E'\r', '')) as m,
         p.prosecdef as definer,
         coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path='''''] as empty_path,
         has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_x,
         has_function_privilege('anon', p.oid, 'EXECUTE') as anon_x,
         exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) as public_x,
         (exists (select 1 from pg_roles r where r.rolname = 'service_role')
          and has_function_privilege('service_role', p.oid, 'EXECUTE')) as service_x
  from pg_proc p
  where p.oid = to_regprocedure('public.block_player_by_id(uuid)')
),
byid_names as (
  select count(*) as n
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'block_player_by_id'
),
blk as (
  select c.oid, c.relowner, c.relacl, c.relrowsecurity
  from pg_class c
  where c.oid = to_regclass('public.blocks')
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
known_fns(name) as (
  select unnest(array[
    'acknowledge_deal_cut', 'can_read_game', 'can_read_table', 'chat_topic_allows', 'claim_win',
    'clear_win_claim', 'computer_acknowledge_deal_cut', 'computer_confirm_count', 'computer_discard_to_crib',
    'computer_draw_cut_card', 'computer_hand', 'computer_next_hand', 'computer_play_card', 'computer_show_crib',
    'computer_start_game_with_deal', 'confirm_count', 'confirm_win', 'create_computer_table', 'create_table',
    'discard_to_crib', 'draw_cut_card', 'follow_user', 'get_computer_profiles', 'get_god_wins',
    'get_leaderboard', 'get_my_follows', 'get_solo_leaderboard', 'get_solo_stats', 'get_spectator_reveals',
    'get_table_spectators', 'is_admin', 'is_current_spectator', 'is_game_player', 'is_public_table',
    'is_table_member', 'join_table_by_code', 'leave_computer_table', 'leave_table', 'next_hand', 'play_card',
    'remove_spectator', 'set_seat', 'show_crib', 'show_hand', 'spectator_heartbeat', 'start_game_with_deal',
    'stop_watching', 'unfollow_user', 'watch_table',
    'block_player', 'unblock_player', 'get_my_blocks'])
),
flags as (
  select
    (select count(*) from fp_state s where s.m in (s.lf, s.crlf)) as fp_ok,
    (select count(*) from m1_state s where s.m = s.lf) as m1_ok,
    to_regclass('public.blocks') is not null as has_blocks,
    exists (select 1 from pg_constraint con
            where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check'
              and pg_get_constraintdef(con.oid) ~ '''block_change''') as has_block_change,
    (select count(*) from byid) as byid_n
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== state ====================================================================
  select 0 as s, 0 as o, 'state'::text as section, 'M2 state'::text as item,
         ('unchanged bodies ' || f.fp_ok::text || ' of 10, M1 functions ' || f.m1_ok::text || ' of 4, blocks '
          || f.has_blocks::text || ', block_change ' || f.has_block_change::text
          || ', block_player_by_id ' || (f.byid_n > 0)::text)::text as value,
         (case
            when f.fp_ok <> 10 or f.m1_ok <> 4 or not f.has_blocks or not f.has_block_change
              then 'STOP: M1 is not fully in, or a body it fingerprints changed; see the rows below'
            when f.byid_n = 0 then 'before part 1: run docs/sql/moderation-m2-part1.sql next (if no other row says STOP)'
            else 'part 1 present: run docs/sql/moderation-m2-verification.sql (if no other row says STOP)'
          end)::text as note
  from flags f

  union all
  -- ==== fp =======================================================================
  select 1, s.o, 'fp', s.fn || ': md5 of the live body',
         coalesce(s.m, '(missing)'),
         case when s.m = s.lf then 'as expected (LF); M2 does not change it'
              when s.m = s.crlf then 'as expected (CRLF); M2 does not change it'
              else 'STOP: expected ' || s.crlf || ' (CRLF) or ' || s.lf || ' (LF). Capture it first: select pg_get_functiondef(''' || s.sig || '''::regprocedure);' end
  from fp_state s

  union all
  select 1, 20 + s.o, 'fp', s.fn || ': md5 (carriage returns removed)',
         coalesce(s.m, '(missing)'),
         case when s.m = s.lf then 'as expected: moderation-m1-part1.sql''s body; M2 does not change it'
              else 'STOP: expected ' || s.lf || ' (moderation-m1-part1.sql). Capture it first: select pg_get_functiondef(''' || s.sig || '''::regprocedure);' end
  from m1_state s

  union all
  -- ==== m1 =======================================================================
  select 2, 1, 'm1', 'public.blocks: RLS on / policies / privileges for PUBLIC, anon, authenticated, service_role',
         coalesce((select coalesce(b.relrowsecurity::text, '?')
                          || ' / ' || (select count(*) from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'blocks')::text
                          || ' / ' || coalesce((select string_agg(case a.grantee when 0 then 'PUBLIC' else pg_get_userbyid(a.grantee)::text end || ':' || a.privilege_type, ', ')
                                                from aclexplode(coalesce(b.relacl, acldefault('r', b.relowner))) a
                                                where a.grantee = 0
                                                   or a.grantee in (select r.oid from pg_roles r where r.rolname in ('anon', 'authenticated', 'service_role'))), '(none)')
                   from blk b), '(absent)'),
         case when to_regclass('public.blocks') is null then 'STOP: moderation M1 part 1 is not in'
              when (select b.relrowsecurity from blk b)
                   and not exists (select 1 from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'blocks')
                   and not exists (select 1 from blk b, aclexplode(coalesce(b.relacl, acldefault('r', b.relowner))) a
                                   where a.grantee = 0
                                      or a.grantee in (select r.oid from pg_roles r where r.rolname in ('anon', 'authenticated', 'service_role')))
                then 'as expected: RLS on, no policies, no client privileges'
              else 'STOP: expected RLS on, no policies and no client privileges (moderation-m1-part1.sql)' end

  union all
  select 2, 2, 'm1', 'attempt_log_action_check allows block_change',
         (select f.has_block_change::text from flags f),
         case when (select f.has_block_change from flags f) then 'as expected (moderation M1 part 1)'
              else 'STOP: moderation M1 part 1 is not in' end

  union all
  -- ==== part1 ====================================================================
  select 3, 1, 'part1', 'public.block_player_by_id(uuid)',
         coalesce((select 'md5 ' || b.m || ' | ' || case when b.definer then 'definer' else 'invoker' end
                          || ' | ' || case when b.empty_path then 'search_path ''''' else 'other config' end
                          || ' | authenticated ' || b.auth_x::text || ', anon ' || b.anon_x::text
                          || ', PUBLIC ' || b.public_x::text || ', service_role ' || b.service_x::text
                   from byid b), '(absent)'),
         case when (select n.n from byid_names n) = 0 then 'before part 1'
              when not exists (select 1 from byid) or (select n.n from byid_names n) > 1
                then 'STOP: a function named block_player_by_id with another signature exists; paste back: select pg_get_functiondef(oid) from pg_proc where proname = ''block_player_by_id'';'
              when (select b.m = 'c80a2bde62d206edbe1784b84c5d7b3b' and b.definer and b.empty_path and b.auth_x
                           and not b.anon_x and not b.public_x and not b.service_x from byid b)
                then 'after part 1, as expected (authenticated only)'
              else 'STOP: expected part 1''s body (c80a2bde62d206edbe1784b84c5d7b3b), security definer, search_path '''', EXECUTE for authenticated only' end

  union all
  -- ==== grants ===================================================================
  select 4, 1, 'grants', 'functions authenticated may execute in public (distinct names)',
         (select count(*) from client_fns)::text,
         case
           when (select count(*) from client_fns) = 52
                and not exists (select 1 from client_fns cf where cf.name not in (select k.name from known_fns k))
                and not exists (select 1 from known_fns k where k.name not in (select cf.name from client_fns cf))
             then 'before part 1: slice E''s 49 plus M1''s block_player, unblock_player, get_my_blocks'
           when (select count(*) from client_fns) = 53
                and not exists (select 1 from client_fns cf where cf.name not in (select k.name from known_fns k) and cf.name <> 'block_player_by_id')
                and not exists (select 1 from known_fns k where k.name not in (select cf.name from client_fns cf))
                and exists (select 1 from client_fns cf where cf.name = 'block_player_by_id')
             then 'after part 1: the 52 plus block_player_by_id'
           else 'STOP: neither 52 nor 53; see the next row (slice-e-grants-verification.sql X1 would fail)' end

  union all
  select 4, 2, 'grants', 'executable by authenticated but not known / known but not executable',
         coalesce((select string_agg(cf.name, ', ' order by cf.name) from client_fns cf
                   where cf.name not in (select k.name from known_fns k) and cf.name <> 'block_player_by_id'), '(none)')
           || ' / '
           || coalesce((select string_agg(k.name, ', ' order by k.name) from known_fns k
                        where k.name not in (select cf.name from client_fns cf)), '(none)'),
         case when exists (select 1 from client_fns cf where cf.name not in (select k.name from known_fns k) and cf.name <> 'block_player_by_id')
                or exists (select 1 from known_fns k where k.name not in (select cf.name from client_fns cf))
              then 'STOP: paste back' else 'as expected' end

  union all
  -- ==== count ====================================================================
  select 5, 1, 'count', 'blocks rows',
         case when to_regclass('public.blocks') is null then '(no table)'
              else (xpath('/row/v/text()', query_to_xml('select count(*)::text as v from public.blocks', false, true, '')))[1]::text end,
         'INFO'

  union all
  select 5, 2, 'count', 'profiles with a blank nickname',
         (select count(*)::text from public.profiles p where btrim(coalesce(p.nickname, '')) = ''),
         'INFO: the chat card''s Block (by account id) can block them; the Profile page''s box (by nickname) cannot'
) z
order by z.s, z.o, z.item;
