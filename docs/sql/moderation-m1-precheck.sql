-- Moderation, slice M1: THE BLOCK LIST. The PRE-CHECK (read-only).
-- Run in the Supabase Dashboard -> SQL Editor before
-- docs/sql/moderation-m1-part1.sql, AGAIN before part 2, and any time after.
-- It reads only; it changes nothing: no writes, no DO block, no temp table,
-- no SET.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M1):
--   1. THIS FILE                                  (state "before part 1")
--   2. docs/sql/moderation-m1-part1.sql          (add-only)
--   3. docs/sql/moderation-m1-verification.sql   (part-1 cases) and
--      docs/sql/slice-e-grants-verification.sql
--   4. the app (PR); old tabs reload
--   5. THIS FILE again                            (state "part 1 present")
--   6. docs/sql/moderation-m1-part2.sql          (the swap)
--   7. docs/sql/moderation-m1-verification.sql   (all cases)
--   8. the regression suites (moderation-m1-part2.sql's header lists them)
--   9. the hand test
--
-- ONE query, so the editor shows every row in one grid. Columns: section,
-- item, value, note (all text). The FIRST row is the STATE: "before part
-- 1", "part 1 present (part 2 not yet)" or "part 2 present". A note
-- starting with STOP means: do not run the next M1 file; paste the result
-- back first. Rows that depend on the state say "before part 1", "after part
-- 1", "before part 2" or "after part 2". INFO rows are facts, not blockers.
--
-- WHAT IT LOOKS FOR
--   state    the one-line summary of the rows below (STOP when the pieces
--            disagree, e.g. the table without its functions).
--   fp       leave_table, end_timed_out_sessions, assign_table_seat,
--            table_host (FINGERPRINTED: md5 of the live body, LF or CRLF);
--            spectator_heartbeat, remove_spectator, chat_topic_allows (M1
--            must not change them); _attempts_guard (the block/unblock limit
--            uses it); join_table_by_code and watch_table: today's
--            (free-codes-part1.sql: 9f3cee04... / df591fa1... CRLF) before
--            part 2, part 2's after -- or moderation M3 part 2's (M1's
--            bodies plus the kick refusal), which counts as "part 2
--            present".
--   part1    attempt_log_action_check (the seven slice A/E actions before,
--            plus block_change after; plus kick too once moderation M3
--            part 1 is in; plus report_filed too once moderation M6 part 1
--            is in); public.blocks (absent before; after:
--            its columns, primary key, self check, both foreign keys ON
--            DELETE CASCADE, the blocked_id index, RLS on, no policies, no
--            privileges for PUBLIC, anon, authenticated or service_role);
--            the four functions (absent before; after: part 1's body,
--            security definer, search_path '', EXECUTE for authenticated
--            only -- none at all for the helper); the nickname unique index
--            the exact-nickname lookup relies on; computer_accounts.
--   names    any OTHER relation, function, trigger, policy or type in public
--            whose name contains "block" (expected none).
--   grants   the client-executable functions (49 before part 1, 52 after;
--            53 after moderation M2 part 1, 56 after M3 part 1, 59 after
--            M6 part 1);
--            postgres's global default ACL for new functions (INFO).
--   count    blocks rows, blockers, the longest list; attempt_log
--            block_change rows; profiles that cannot be blocked by nickname
--            (blank); nickname collisions under lower(btrim()) (STOP if any:
--            the unique index should make this 0); nicknames with characters
--            outside printable ASCII or with whitespace other than single
--            spaces (INFO: look-alike names a blocker may mistype).

with fp_known(o, fn, sig, lf, crlf, src) as (
  values
    (1, 'leave_table', 'public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa', 'phase2-slice-5-cut-before-deal.sql (FINGERPRINTED)'),
    (2, 'end_timed_out_sessions', 'public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c', 'phase2-slice-5-cut-before-deal.sql (FINGERPRINTED)'),
    (3, 'assign_table_seat', 'public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb', 'phase3-e1-seating.sql (FINGERPRINTED)'),
    (4, 'table_host', 'public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d', 'phase3-e1-seating.sql (FINGERPRINTED)'),
    (5, 'spectator_heartbeat', 'public.spectator_heartbeat(uuid)', '41d2ea0e865c2a9d5fa7203875a27ace', '6b7c271d78eb4f72c1aff3c851b578e1', 'spectators-join-or-watch.sql (M1 leaves it alone)'),
    (6, 'remove_spectator', 'public.remove_spectator(uuid, uuid)', 'dafa688f1b8c194e4be575cd0625ba12', '9786b9a5e50245365a2598b18da5892e', 'spectators.sql (M1 leaves it alone)'),
    (7, 'chat_topic_allows', 'public.chat_topic_allows(text, boolean)', '0458d5122d68d511b2e0fbceafe84aae', 'c4e6eda360de7d7723c4069e60d95345', 'spectator-chat.sql (M1 leaves it alone)'),
    (8, '_attempts_guard', 'public._attempts_guard(uuid, text, integer, interval, text)', 'b1b69dbbdf10d50f78655a0da3b3ac69', '9406938991e89dcd38d0686a279b432a', 'join-create.sql (the block/unblock limit uses it)')
),
swap_known(o, fn, sig, lf, crlf, m1_lf, m1_crlf, m3_lf, m3_crlf) as (
  values
    (1, 'join_table_by_code', 'public.join_table_by_code(text, boolean, uuid)', '1a2ff167c6d09fef6acd17177493422d', '9f3cee04a063447d626a1354533fda51', 'cf40593ee5afda235144a13e38d27f4a', 'c3ee9ced2e1033f9c068acd3325c5583', '297fa4f04a02e226691ebf3b5b135f83', 'fbf046f1582863cc5697b06f670481b2'),
    (2, 'watch_table', 'public.watch_table(text, uuid)', '43775b57dffaec98ee7c003304a0c951', 'df591fa16528afd81a13bfdc3e975538', '5bf6065de215d92a02af63d035c7f910', '2aa5f9c37d65271f3b4619e58c171ea0', 'bdebb2e1a8213baa2a04666bcad59adb', 'ea5c3bd739b2f7243b985c7ea1fd9f2a')
),
swap_state as (
  select s.o, s.fn, s.sig,
         (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(s.sig)) as m,
         s.lf, s.crlf, s.m1_lf, s.m1_crlf, s.m3_lf, s.m3_crlf
  from swap_known s
),
new_fns(o, name, sig, lf, client) as (
  values
    (1, 'block_player', 'public.block_player(text)', '10f6b07a3224aff16e1326daa6af5759', true),
    (2, 'unblock_player', 'public.unblock_player(uuid)', 'c0363d27028d621c0008654506bade75', true),
    (3, 'get_my_blocks', 'public.get_my_blocks()', '3d50e2a273ca16b23f6d89348016d8de', true),
    (4, '_is_blocked_from_table', 'public._is_blocked_from_table(uuid, uuid)', '162f914c3b209186c819c66d18a23a99', false)
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
           and cd.d ~ '''code_guess''' and cd.d ~ '''game_start''' and cd.d ~ '''follow_change''' as has_seven,
         cd.d ~ '''block_change''' as has_block,
         cd.d ~ '''kick''' as has_kick,
         cd.d ~ '''report_filed''' as has_report
  from check_def cd
),
blk as (
  select c.oid, c.relowner, c.relacl, c.relrowsecurity
  from pg_class c
  where c.oid = to_regclass('public.blocks')
),
blk_state as (
  select
    (select string_agg(a.attname::text || ' ' || format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else '' end
                       || coalesce(' default ' || pg_get_expr(ad.adbin, ad.adrelid), ''), ', ' order by a.attnum)
     from blk b
     join pg_attribute a on a.attrelid = b.oid and a.attnum > 0 and not a.attisdropped
     left join pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum) as cols,
    (select string_agg(con.contype::text || ':' || pg_get_constraintdef(con.oid), ' | ' order by con.contype, pg_get_constraintdef(con.oid))
     from blk b join pg_constraint con on con.conrelid = b.oid) as cons,
    (select string_agg(pg_get_indexdef(i.indexrelid), ' | ' order by pg_get_indexdef(i.indexrelid))
     from blk b join pg_index i on i.indrelid = b.oid) as idx,
    (select b.relrowsecurity from blk b) as rls,
    (select count(*) from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'blocks') as policies,
    (select coalesce(string_agg(case a.grantee when 0 then 'PUBLIC' else pg_get_userbyid(a.grantee)::text end || ':' || a.privilege_type, ', '
                                order by a.grantee, a.privilege_type), '')
     from blk b, aclexplode(coalesce(b.relacl, acldefault('r', b.relowner))) a
     where a.grantee = 0
        or a.grantee in (select r.oid from pg_roles r where r.rolname in ('anon', 'authenticated', 'service_role'))) as client_privs
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
slice_e_fns(name) as (
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
    'stop_watching', 'unfollow_user', 'watch_table'])
),
m1_fns(name) as (
  values ('block_player'), ('unblock_player'), ('get_my_blocks')
),
flags as (
  select
    (select cs.has_block from check_state cs) as p1_check,
    to_regclass('public.blocks') is not null as p1_table,
    (select count(*) from new_fn_state n where n.fn_oid is not null) as p1_fns,
    (select count(*) from swap_state s where s.m in (s.lf, s.crlf)) as swap_today,
    -- M3 part 2's bodies are M1's plus the kick refusal: they count as M1's.
    (select count(*) from swap_state s where s.m in (s.m1_lf, s.m1_crlf, s.m3_lf, s.m3_crlf)) as swap_m1
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== state ====================================================================
  select 0 as s, 0 as o, ''::text as k, 'state'::text as section, 'M1 state'::text as item,
         ('attempt_log block_change ' || coalesce(f.p1_check::text, '?') || ' | blocks table ' || f.p1_table::text
          || ' | M1 functions ' || f.p1_fns::text || ' of 4 | join/watch today''s ' || f.swap_today::text
          || ', part 2''s ' || f.swap_m1::text)::text as value,
         (case
            when f.p1_check is not true and not f.p1_table and f.p1_fns = 0 and f.swap_today = 2
              then 'before part 1: run docs/sql/moderation-m1-part1.sql next (if no other row says STOP)'
            when f.p1_check and f.p1_table and f.p1_fns = 4 and f.swap_today = 2
              then 'part 1 present (part 2 not yet): after the app is live, run docs/sql/moderation-m1-part2.sql (if no other row says STOP)'
            when f.p1_check and f.p1_table and f.p1_fns = 4 and f.swap_m1 = 2
              then 'part 2 present: M1 is fully in'
            else 'STOP: a mixed state (some of part 1 or part 2 without the rest); paste the whole result back'
          end)::text as note
  from flags f

  union all
  -- ==== fp =======================================================================
  select 1, k.o, '', 'fp', k.fn || ': md5 of the live body',
         coalesce((select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(k.sig)), '(missing)'),
         case (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(k.sig))
              when k.lf then k.src || ', LF: as expected'
              when k.crlf then k.src || ', CRLF: as expected'
              else 'STOP: not ' || k.src || '''s text (or missing). Capture it first: select pg_get_functiondef(''' || k.sig || '''::regprocedure); and paste the result back' end
  from fp_known k

  union all
  select 1, 10 + s.o, '', 'fp', s.fn || ': md5 of the live body',
         coalesce(s.m, '(missing)'),
         case
           when s.m in (s.lf, s.crlf) then 'before part 2: free-codes-part1.sql''s body (' || case when s.m = s.lf then 'LF' else 'CRLF' end || '), as expected'
           when s.m in (s.m1_lf, s.m1_crlf) then 'after part 2: M1''s body (' || case when s.m = s.m1_lf then 'LF' else 'CRLF' end || '), as expected'
           when s.m in (s.m3_lf, s.m3_crlf) then 'after part 2: moderation M3 part 2''s body (M1''s plus the kick refusal; ' || (case when s.m = s.m3_lf then 'LF' else 'CRLF' end) || '), as expected'
           else 'STOP: neither today''s ' || s.crlf || ' / ' || s.lf || ' nor part 2''s ' || s.m1_crlf || ' / ' || s.m1_lf
                || '. Capture it first: select pg_get_functiondef(''' || s.sig || '''::regprocedure);' end
  from swap_state s

  union all
  -- ==== part1: attempt_log =======================================================
  select 2, 1, '', 'part1', 'attempt_log_action_check',
         coalesce((select cs.d from check_state cs), '(missing)'),
         case
           when not exists (select 1 from check_state) then 'STOP: the constraint is missing'
           when (select cs.has_seven and not cs.has_block and cs.n_actions = 7 from check_state cs)
             then 'before part 1: the seven slice A/E actions'
           when (select cs.has_seven and cs.has_block and not cs.has_kick and cs.n_actions = 8 from check_state cs)
             then 'after part 1: plus block_change'
           when (select cs.has_seven and cs.has_block and cs.has_kick and not cs.has_report and cs.n_actions = 9 from check_state cs)
                and to_regclass('public.table_kicks') is not null
             then 'after part 1: plus block_change (and moderation M3''s kick)'
           when (select cs.has_seven and cs.has_block and cs.has_kick and cs.has_report and cs.n_actions = 10 from check_state cs)
                and to_regclass('public.table_kicks') is not null and to_regclass('public.player_reports') is not null
             then 'after part 1: plus block_change (and moderation M3''s kick and M6''s report_filed)'
           else 'STOP: neither the seven slice A/E actions nor those plus block_change (and kick, after M3; and report_filed, after M6)' end

  union all
  -- ==== part1: public.blocks =====================================================
  select 2, 2, '', 'part1', 'public.blocks: columns',
         coalesce((select bs.cols from blk_state bs), '(absent)'),
         case when to_regclass('public.blocks') is null then 'before part 1'
              when (select bs.cols from blk_state bs) = 'blocker_id uuid not null, blocked_id uuid not null, created_at timestamp with time zone not null default now()'
                then 'after part 1, as expected'
              else 'STOP: expected blocker_id uuid not null, blocked_id uuid not null, created_at timestamptz not null default now()' end

  union all
  select 2, 3, '', 'part1', 'public.blocks: constraints',
         coalesce((select bs.cons from blk_state bs), '(absent)'),
         case when to_regclass('public.blocks') is null then 'before part 1'
              when (select count(*) from pg_constraint con where con.conrelid = to_regclass('public.blocks')) = 4
                   and exists (select 1 from pg_constraint con where con.conrelid = to_regclass('public.blocks')
                                 and con.contype = 'p' and pg_get_constraintdef(con.oid) = 'PRIMARY KEY (blocker_id, blocked_id)')
                   and exists (select 1 from pg_constraint con where con.conrelid = to_regclass('public.blocks')
                                 and con.contype = 'c' and pg_get_constraintdef(con.oid) = 'CHECK ((blocker_id <> blocked_id))')
                   and exists (select 1 from pg_constraint con where con.conrelid = to_regclass('public.blocks')
                                 and con.contype = 'f' and pg_get_constraintdef(con.oid) = 'FOREIGN KEY (blocker_id) REFERENCES auth.users(id) ON DELETE CASCADE')
                   and exists (select 1 from pg_constraint con where con.conrelid = to_regclass('public.blocks')
                                 and con.contype = 'f' and pg_get_constraintdef(con.oid) = 'FOREIGN KEY (blocked_id) REFERENCES auth.users(id) ON DELETE CASCADE')
                then 'after part 1, as expected'
              else 'STOP: expected the self check, two ON DELETE CASCADE foreign keys to auth.users and the primary key (blocker_id, blocked_id)' end

  union all
  select 2, 4, '', 'part1', 'public.blocks: indexes',
         coalesce((select bs.idx from blk_state bs), '(absent)'),
         case when to_regclass('public.blocks') is null then 'before part 1'
              when (select bs.idx from blk_state bs) ~ 'blocks_blocked_id_idx ON public\.blocks USING btree \(blocked_id\)'
                   and (select bs.idx from blk_state bs) ~ 'blocks_pkey ON public\.blocks USING btree \(blocker_id, blocked_id\)'
                then 'after part 1, as expected'
              else 'STOP: expected blocks_pkey (blocker_id, blocked_id) and blocks_blocked_id_idx (blocked_id)' end

  union all
  select 2, 5, '', 'part1', 'public.blocks: RLS on / policies / privileges for PUBLIC, anon, authenticated, service_role',
         coalesce((select coalesce(bs.rls::text, '?') || ' / ' || bs.policies::text || ' / ' || coalesce(nullif(bs.client_privs, ''), '(none)')
                   from blk_state bs where to_regclass('public.blocks') is not null), '(absent)'),
         case when to_regclass('public.blocks') is null then 'before part 1'
              when (select bs.rls is true and bs.policies = 0 and bs.client_privs = '' from blk_state bs)
                then 'after part 1, as expected: RLS on, no policies, no client privileges'
              else 'STOP: expected RLS on, no policies and no privileges for any client role' end

  union all
  select 2, 6, '', 'part1', 'public.blocks: in the supabase_realtime publication',
         (exists (select 1 from pg_publication_tables pt
                  where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = 'blocks'))::text,
         case when exists (select 1 from pg_publication_tables pt
                           where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = 'blocks')
              then 'STOP: the Block List must not be published to Realtime' else 'as expected (not published)' end

  union all
  -- ==== part1: the four functions ================================================
  select 2, 10 + n.o, '', 'part1', n.sig,
         case when n.fn_oid is null then '(absent' || case when n.overloads > 0 then ', but ' || n.overloads::text || ' function(s) by that name' else '' end || ')'
              else 'md5 ' || n.m || ' | ' || case when n.definer then 'definer' else 'invoker' end
                   || ' | ' || case when n.empty_path then 'search_path ''''' else 'other config' end
                   || ' | authenticated ' || n.auth_x::text || ', anon ' || n.anon_x::text
                   || ', PUBLIC ' || n.public_x::text || ', service_role ' || n.service_x::text end,
         case when n.fn_oid is null and n.overloads = 0 then 'before part 1'
              when n.fn_oid is null then 'STOP: a function by this name with another signature exists; paste back: select pg_get_functiondef(oid) from pg_proc where proname = ''' || n.name || ''';'
              when n.overloads = 1 and n.m = n.lf and n.definer and n.empty_path
                   and n.auth_x = n.client and not n.anon_x and not n.public_x and not n.service_x
                then 'after part 1, as expected' || case when n.client then ' (authenticated only)' else ' (no client EXECUTE)' end
              else 'STOP: expected part 1''s body (' || n.lf || '), security definer, search_path '''', '
                   || case when n.client then 'EXECUTE for authenticated only' else 'no client EXECUTE' end end
  from new_fn_state n

  union all
  -- ==== part1: what the lookup relies on =========================================
  select 2, 20, '', 'part1', 'profiles_nickname_unique_idx',
         coalesce((select pg_get_indexdef(i.indexrelid) || ' | unique ' || i.indisunique::text || ', valid ' || i.indisvalid::text
                   from pg_index i where i.indexrelid = to_regclass('public.profiles_nickname_unique_idx')), '(missing)'),
         case when (select i.indisunique and i.indisvalid and pg_get_indexdef(i.indexrelid) ~* 'lower\(btrim\(nickname\)\)'
                    from pg_index i where i.indexrelid = to_regclass('public.profiles_nickname_unique_idx'))
              then 'as expected: at most one account per lower(btrim(nickname))'
              else 'STOP: block_player matches nicknames by lower(btrim()) and relies on this unique index' end

  union all
  select 2, 21, '', 'part1', 'public.computer_accounts',
         (to_regclass('public.computer_accounts') is not null)::text,
         case when to_regclass('public.computer_accounts') is not null then 'as expected' else 'STOP: missing' end

  union all
  -- ==== names: anything else called "block" =======================================
  select 3, 1, c.relname::text, 'names', 'relation public.' || c.relname::text || ' (' || c.relkind::text || ')',
         'contains "block"',
         case when c.relname in ('blocks', 'blocks_pkey', 'blocks_blocked_id_idx') then 'M1''s own (after part 1)'
              else 'STOP: not M1''s; look at it first' end
  from pg_class c
  join pg_namespace ns on ns.oid = c.relnamespace
  where ns.nspname = 'public' and c.relname ~* 'block'

  union all
  select 3, 2, p.oid::regprocedure::text, 'names', 'function ' || p.oid::regprocedure::text,
         'contains "block"',
         case when p.proname in ('block_player', 'unblock_player', 'get_my_blocks', '_is_blocked_from_table') then 'M1''s own (the part1 rows check it)'
              when p.proname = 'block_player_by_id' then 'INFO: moderation M2''s (moderation-m2-precheck.sql checks it)'
              else 'STOP: not M1''s; look at it first' end
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname ~* 'block'

  union all
  select 3, 3, tg.tgname::text, 'names', 'trigger ' || tg.tgname::text || ' on ' || tg.tgrelid::regclass::text,
         'contains "block" or "screen_entry"',
         'STOP: M1 adds no trigger (the backstop is only proposed)'
  from pg_trigger tg
  join pg_class c on c.oid = tg.tgrelid
  join pg_namespace ns on ns.oid = c.relnamespace
  where not tg.tgisinternal and ns.nspname = 'public' and tg.tgname ~* '(block|screen_entry)'

  union all
  select 3, 4, pol.tablename::text || pol.policyname::text, 'names', 'policy "' || pol.policyname || '" on public.' || pol.tablename,
         'contains "block" or is on blocks',
         'STOP: blocks must have no policies, and M1 adds none elsewhere'
  from pg_policies pol
  where pol.schemaname = 'public' and (pol.policyname ~* 'block' or pol.tablename = 'blocks')

  union all
  select 3, 5, t.typname::text, 'names', 'type public.' || t.typname::text,
         'contains "block"',
         'STOP: M1 adds no type'
  from pg_type t
  join pg_namespace ns on ns.oid = t.typnamespace
  where ns.nspname = 'public' and t.typname ~* 'block'
    and not exists (select 1 from pg_class c where c.reltype = t.oid)
    and t.typelem = 0

  union all
  -- ==== grants ===================================================================
  select 4, 1, '', 'grants', 'functions authenticated may execute in public (distinct names)',
         (select count(*) from client_fns)::text,
         case
           when (select count(*) from client_fns) = 49
                and not exists (select 1 from client_fns cf where cf.name not in (select e.name from slice_e_fns e))
             then 'before part 1: slice E''s 49'
           when (select count(*) from client_fns) = 52
                and not exists (select 1 from client_fns cf
                                where cf.name not in (select e.name from slice_e_fns e) and cf.name not in (select m.name from m1_fns m))
                and (select count(*) from client_fns cf where cf.name in (select m.name from m1_fns m)) = 3
             then 'after part 1: slice E''s 49 plus block_player, unblock_player, get_my_blocks'
           when (select count(*) from client_fns) = 53
                and to_regprocedure('public.block_player_by_id(uuid)') is not null
                and not exists (select 1 from client_fns cf
                                where cf.name not in (select e.name from slice_e_fns e) and cf.name not in (select m.name from m1_fns m)
                                  and cf.name <> 'block_player_by_id')
                and (select count(*) from client_fns cf where cf.name in (select m.name from m1_fns m)) = 3
             then 'after moderation M2 part 1: the 52 plus block_player_by_id'
           when (select count(*) from client_fns) = 56
                and to_regprocedure('public.block_player_by_id(uuid)') is not null
                and to_regclass('public.table_kicks') is not null
                and not exists (select 1 from client_fns cf
                                where cf.name not in (select e.name from slice_e_fns e) and cf.name not in (select m.name from m1_fns m)
                                  and cf.name not in ('block_player_by_id', 'kick_player', 'kick_topic_allows', 'admin_recent_kicks'))
                and (select count(*) from client_fns cf where cf.name in (select m.name from m1_fns m)) = 3
                and (select count(*) from client_fns cf where cf.name in ('kick_player', 'kick_topic_allows', 'admin_recent_kicks')) = 3
             then 'after moderation M3 part 1: the 53 plus kick_player, kick_topic_allows, admin_recent_kicks'
           when (select count(*) from client_fns) = 59
                and to_regprocedure('public.block_player_by_id(uuid)') is not null
                and to_regclass('public.table_kicks') is not null
                and to_regclass('public.player_reports') is not null
                and not exists (select 1 from client_fns cf
                                where cf.name not in (select e.name from slice_e_fns e) and cf.name not in (select m.name from m1_fns m)
                                  and cf.name not in ('block_player_by_id', 'kick_player', 'kick_topic_allows', 'admin_recent_kicks',
                                                      'report_player', 'admin_list_reports', 'admin_delete_report'))
                and (select count(*) from client_fns cf where cf.name in (select m.name from m1_fns m)) = 3
                and (select count(*) from client_fns cf where cf.name in ('kick_player', 'kick_topic_allows', 'admin_recent_kicks')) = 3
                and (select count(*) from client_fns cf where cf.name in ('report_player', 'admin_list_reports', 'admin_delete_report')) = 3
             then 'after moderation M6 part 1: the 56 plus report_player, admin_list_reports, admin_delete_report'
           else 'STOP: neither 49, 52, 53, 56 nor 59; see the next two rows (slice-e-grants-verification.sql X1 would fail)' end

  union all
  select 4, 2, '', 'grants', 'executable by authenticated but in neither list (M2''s block_player_by_id, M3''s three and M6''s three aside)',
         coalesce((select string_agg(cf.name, ', ' order by cf.name) from client_fns cf
                   where cf.name not in (select e.name from slice_e_fns e) and cf.name not in (select m.name from m1_fns m)
                     and cf.name not in ('block_player_by_id', 'kick_player', 'kick_topic_allows', 'admin_recent_kicks',
                                         'report_player', 'admin_list_reports', 'admin_delete_report')), '(none)'),
         case when exists (select 1 from client_fns cf
                           where cf.name not in (select e.name from slice_e_fns e) and cf.name not in (select m.name from m1_fns m)
                             and cf.name not in ('block_player_by_id', 'kick_player', 'kick_topic_allows', 'admin_recent_kicks',
                                                 'report_player', 'admin_list_reports', 'admin_delete_report'))
              then 'STOP: paste back' else '' end

  union all
  select 4, 3, '', 'grants', 'in slice E''s 49 but not executable by authenticated (or missing)',
         coalesce((select string_agg(e.name, ', ' order by e.name) from slice_e_fns e
                   where e.name not in (select cf.name from client_fns cf)), '(none)'),
         case when exists (select 1 from slice_e_fns e where e.name not in (select cf.name from client_fns cf))
              then 'STOP: paste back' else '' end

  union all
  select 4, 4, '', 'grants', 'postgres global default ACL for new functions (pg_default_acl, all schemas)',
         coalesce((select da.defaclacl::text from pg_default_acl da
                   where da.defaclrole = 'postgres'::regrole and da.defaclnamespace = 0 and da.defaclobjtype = 'f'),
                  '(no row: the built-in default, EXECUTE for PUBLIC)'),
         'INFO: part 1 revokes from PUBLIC on every new function itself either way (slice E part 3 should have left {postgres=X/postgres})'

  union all
  -- ==== count ====================================================================
  select 5, 1, '', 'count', 'blocks rows / blockers / the longest list',
         case when to_regclass('public.blocks') is null then '(no table yet)'
              else (xpath('/row/v/text()', query_to_xml(
                     'select count(*)::text || '' / '' || count(distinct b.blocker_id)::text || '' / '' || coalesce((select max(q.n) from (select count(*) as n from public.blocks g group by g.blocker_id) q), 0)::text as v from public.blocks b',
                     false, true, '')))[1]::text end,
         'INFO (the cap is 100)'

  union all
  select 5, 2, '', 'count', 'attempt_log block_change rows (all time / last hour)',
         (select count(*)::text || ' / ' || count(*) filter (where a.created_at > now() - interval '1 hour')::text
          from public.attempt_log a where a.action = 'block_change'),
         'INFO (0 before part 1)'

  union all
  select 5, 3, '', 'count', 'profiles with a blank nickname (cannot be blocked by nickname)',
         (select count(*)::text from public.profiles p where btrim(coalesce(p.nickname, '')) = ''),
         'INFO: such an account cannot be added in M1 (no nickname to type); M2/M3 add blocking from chat and kick by id'

  union all
  select 5, 4, '', 'count', 'nickname collisions under lower(btrim()) among non-blank nicknames',
         (select count(*)::text from (select lower(btrim(p.nickname)) from public.profiles p
                                      where btrim(p.nickname) <> '' group by 1 having count(*) > 1) d),
         case when exists (select 1 from public.profiles p where btrim(p.nickname) <> ''
                           group by lower(btrim(p.nickname)) having count(*) > 1)
              then 'STOP: two accounts share a name; block_player would answer not_found for it'
              else 'as expected (0)' end

  union all
  select 5, 5, '', 'count', 'nicknames with characters outside printable ASCII / with whitespace other than single spaces',
         (select count(*) filter (where p.nickname ~ '[^ -~]')::text || ' / '
                 || count(*) filter (where p.nickname ~ '[^ [:graph:]]' or p.nickname ~ '  ')::text
          from public.profiles p where btrim(p.nickname) <> ''),
         'INFO: look-alike or hard-to-type names; a blocker must type the exact name (case and outer spaces aside)'
) z
order by z.s, z.o, z.k, z.item;
