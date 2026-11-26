-- Moderation, slice M3: VERIFICATION of KICK
-- (docs/sql/moderation-m3-part1.sql and moderation-m3-part2.sql).
--
-- Run in the Supabase Dashboard -> SQL Editor after part 1 (it then runs its
-- part-1 cases only) and again after part 2 (every case). The whole file is
-- ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M3): precheck -> part 1 -> THIS FILE (part-1 cases)
-- -> app deploy (PR) -> precheck again -> part 2 -> THIS FILE (all cases)
-- -> regression suites -> hand test.
--
-- It WRITES -- one temporary function in pg_temp (m3_as: runs one statement
-- as a client role and returns its result or its error), a temporary
-- REPLACEMENT of _send_kick_notice (C12), temporary accounts in auth.users
-- and their profiles, an admin_users row, test tables, seats, a game,
-- spectator rows, kicks, attempt_log rows and (when Realtime can store
-- them) notice rows in realtime.messages; it calls kick_player,
-- kick_topic_allows, admin_recent_kicks, spectator_heartbeat,
-- join_table_by_code and watch_table as those people -- and then
-- deliberately raises an exception at the very end, which rolls EVERY write
-- back (the replaced function included: DDL is transactional). A check that
-- fails raises its own exception at once, which rolls everything back the
-- same way. It always "fails": the message is the verdict.
--   After part 2: "ALL 26 CHECKS PASSED (rolled back)." is a pass -- or
--   "ALL 24 CHECKS PASSED (rolled back). Skipped N1-N2 ..." when Realtime
--   can't store the notice (no realtime.messages partition for today).
--   After part 1 only: "ALL 19 PART-1 CHECKS PASSED (rolled back; part 2 is
--   not in yet, so the 7 join/watch checks were skipped)." (17 with the
--   N1-N2 skip line) is a pass.
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives. now() is frozen inside a
-- DO block, so "an hour ago" is made by moving attempt_log.created_at back
-- as the owner. Impersonation: request.jwt.claims plus "set local role
-- authenticated" (or anon), inside m3_as; "reset role" to act as the owner.
--
-- PEOPLE AND TABLES: T1 (H's: public, spectators allowed, 4 seats; H, P, Q,
-- Y seated; a live game; S and S2 current spectators; R removed from
-- watching by the old path; Y also has an old removed spectator row). Z (no
-- relation: kicked while absent), O (no relation), AD (an admin). T2 (C2's;
-- C2 only watches it, H2 is seated: H2 is the host). T3 (C3's; C3 and X3
-- seated). T4 (H4's computer table). T5 (H5's, ended). T6 (F's: the hourly
-- limit; G1 the target). T7 (O2's: P joins it after being kicked from T1).
--
-- WHAT IT CHECKS -- PART 1 (always)
--   K1  public.table_kicks: columns, primary key, the role and self checks,
--       the four foreign keys (table and kicked person ON DELETE CASCADE,
--       host and game ON DELETE SET NULL), the three indexes, RLS on, no
--       policies, NO privilege for PUBLIC, anon, authenticated or
--       service_role, not in supabase_realtime; attempt_log allows exactly
--       the nine actions (kick included).
--   K2  the five functions: part 1's bodies, security definer, search_path
--       ''; kick_player, kick_topic_allows, admin_recent_kicks executable
--       by authenticated only; _is_kicked_from_table and _send_kick_notice
--       by no client role.
--   K3  unchanged: leave_table, end_timed_out_sessions, assign_table_seat,
--       table_host (fingerprinted), spectator_heartbeat, remove_spectator,
--       chat_topic_allows, _attempts_guard, and M1's four functions.
--   K4  realtime.messages: the kicks policy exactly as part 1 wrote it
--       (SELECT, to authenticated, permissive, broadcast,
--       kick_topic_allows(realtime.topic())); the policies are exactly the
--       two table-chat ones plus it (no insert policy for kicks); no policy
--       or function of M3's has "chat" in its name.
--   K5  THE NOTICE NEVER UNDOES A KICK (the shape): kick_player calls
--       _send_kick_notice inside its own BEGIN ... EXCEPTION WHEN OTHERS
--       THEN NULL block, after the log row, the game's end and the seat's
--       delete; _send_kick_notice calls realtime.send(payload, 'kick',
--       'kicks:' || table id, true). C12 proves the behaviour.
--   C1  H kicks P MID-GAME: 'kicked'; P's seat gone; the live game ended as
--       player_left; T1 still open; the table_kicks row (host H, role
--       player, game_live true, the game's id, P's nickname); 1 kick row in
--       attempt_log for H.
--   N1  (when Realtime stores it) exactly one notice on kicks:<T1>, event
--       'kick', private, broadcast, payload kicked_id P and P's nickname.
--   C2  H kicks S (a current spectator): 'kicked'; removed_at set; role
--       spectator, game_live false (C1 ended it); S's spectator_heartbeat
--       answers 'removed' (the app's "The host removed you from this
--       table.").
--   C3  H kicks Z, who isn't at the table (left a moment ago): 'kicked',
--       role absent.
--   N2  (when Realtime stores them) who RECEIVES kicks:<T1> under the live
--       policies: H (seated) and S2 (current spectator) see every notice;
--       O, P (kicked) and S (removed) see none; H inserting a message on
--       kicks:<T1> is refused (42501): nobody but kick_player sends.
--   C4  H kicks P again: 'already_kicked'; nothing new, nothing counted.
--   C5  refusals, none counted: Q (not the host) kicks Y; H kicks H; nobody
--       logged in; anon (42501, no EXECUTE); an unknown table; an unknown
--       person; the computer account.
--   C6  a computer table (T4) and an ended table (T5) are refused.
--   C7  THE CREATOR RULES: at T3 the seated creator C3 is the host, so X3
--       can't kick C3 and C3 can't kick C3; at T2 the creator C2 is only
--       watching, so the host H2 kicks C2 ('kicked', role spectator).
--   C8  THE HOURLY LIMIT: F with 20 kicks in the last hour is refused the
--       21st (P0001, detail rate_limited, the message), no row; with the 20
--       moved 61 minutes back it is 'kicked'.
--   C9  admin_recent_kicks: refused for a non-admin ("Admins only.") and for
--       nobody logged in; an admin sees T1's three kicks with T1's code,
--       H's nickname, each nickname and role.
--   C10 clients cannot read or write public.table_kicks: H's SELECT and
--       INSERT and anon's SELECT are each refused with 42501 (not zero
--       rows).
--   C11 kick_topic_allows: true for H (seated) and S2 (current spectator);
--       false for S (removed), P (kicked), O, nobody logged in, an
--       uppercase topic, a chat: topic, and H4 at the computer table; anon
--       may not call it (42501).
--   C12 A FAILING NOTICE DOES NOT UNDO A KICK (the behaviour): with
--       _send_kick_notice replaced by one that always raises (proved to
--       raise), H kicks Q: 'kicked'; Q's seat gone, the row there, H's kick
--       count up by one. (Run last; rolled back with everything.)
-- WHAT IT CHECKS -- PART 2 (once join_table_by_code and watch_table have
-- part 2's bodies)
--   K6  join_table_by_code and watch_table: part 2's bodies, EXECUTE for
--       authenticated only.
--   J1  P (kicked) joining T1 by typed code, by id, and the preview by code
--       and by id: "You can't join this table.", P0001, no detail, no hint,
--       no row; no seat.
--   J2  P, S (kicked spectator) and Z (kicked while absent) watching T1, by
--       code and by id: the same refusal (S no longer hears "You were
--       removed ..."); no new spectator row.
--   J3  none of J1-J2 counted anything for P, S or Z (no join, watch,
--       code_guess, create_table or create_computer_table row).
--   J4  R, removed by the OLD path (remove_spectator: a removed row, no
--       kick), can no longer take a seat (the refusal) but watching still
--       says "You were removed from watching this table.".
--   J5  Y, seated, with an old removed spectator row: still
--       'already_seated' (a seated person is never refused).
--   J6  per table only: O joins T1 ('joined'); P joins O2's T7 ('joined').

do $$
declare
  v_checks int := 0;
  v_expect int;
  v_p2 boolean;
  v_live boolean := false;
  v_skips text := '';
  v_h uuid := gen_random_uuid();
  v_p uuid := gen_random_uuid();
  v_q uuid := gen_random_uuid();
  v_y uuid := gen_random_uuid();
  v_s uuid := gen_random_uuid();
  v_s2 uuid := gen_random_uuid();
  v_rm uuid := gen_random_uuid();
  v_z uuid := gen_random_uuid();
  v_o uuid := gen_random_uuid();
  v_ad uuid := gen_random_uuid();
  v_c2 uuid := gen_random_uuid();
  v_h2 uuid := gen_random_uuid();
  v_c3 uuid := gen_random_uuid();
  v_x3 uuid := gen_random_uuid();
  v_h4 uuid := gen_random_uuid();
  v_h5 uuid := gen_random_uuid();
  v_f uuid := gen_random_uuid();
  v_g1 uuid := gen_random_uuid();
  v_o2 uuid := gen_random_uuid();
  v_people uuid[];
  v_pid uuid;
  v_comp uuid;
  v_codes text[];
  v_t1 uuid;
  v_t2 uuid;
  v_t3 uuid;
  v_t4 uuid;
  v_t5 uuid;
  v_t6 uuid;
  v_t7 uuid;
  v_game uuid;
  v_topic text;
  v_rec record;
  v_txt text;
  v_bad text;
  v_n int;
  v_n2 int;
  v_r text[];
  v_r2 text[];
  v_state text;
  v_refusal text := 'You can''t join this table.';
  v_limit_msg text := 'You have kicked 20 people in the last hour. Please try again a little later.';
begin
  -- ==== MODE ======================================================================
  select (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.join_table_by_code(text, boolean, uuid)'))
           in ('297fa4f04a02e226691ebf3b5b135f83', 'fbf046f1582863cc5697b06f670481b2')
     and (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.watch_table(text, uuid)'))
           in ('bdebb2e1a8213baa2a04666bcad59adb', 'ea5c3bd739b2f7243b985c7ea1fd9f2a')
  into v_p2;
  if not coalesce(v_p2, false)
     and not ((select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.join_table_by_code(text, boolean, uuid)'))
                in ('cf40593ee5afda235144a13e38d27f4a', 'c3ee9ced2e1033f9c068acd3325c5583')
              and (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.watch_table(text, uuid)'))
                in ('5bf6065de215d92a02af63d035c7f910', '2aa5f9c37d65271f3b4619e58c171ea0')) then
    raise exception 'SETUP: join_table_by_code / watch_table are neither M1 part 2''s nor M3 part 2''s bodies (or only one of them is M3''s). Run docs/sql/moderation-m3-precheck.sql.';
  end if;
  v_p2 := coalesce(v_p2, false);
  if to_regclass('public.table_kicks') is null or to_regprocedure('public.kick_player(uuid, uuid)') is null then
    raise exception 'SETUP: part 1 is not in (no public.table_kicks or kick_player). Run docs/sql/moderation-m3-part1.sql first.';
  end if;

  -- m3_as(role, user, sql): runs one statement as that client role (the
  -- user as auth.uid(), or nobody when null) and returns
  -- {sqlstate, message, detail, hint, first column of the first row} --
  -- the error fields null when it worked. Rolled back with everything else.
  create function pg_temp.m3_as(p_role text, p_uid uuid, p_sql text)
  returns text[]
  language plpgsql
  as $f$
  declare
    v_res text;
    v_state text;
    v_msg text;
    v_detail text;
    v_hint text;
  begin
    perform set_config('request.jwt.claims',
      case when p_uid is null then json_build_object('role', p_role)::text
           else json_build_object('sub', p_uid, 'role', p_role)::text end, true);
    begin
      execute format('set local role %I', p_role);
      execute p_sql into v_res;
      execute 'reset role';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text,
                              v_detail = pg_exception_detail, v_hint = pg_exception_hint;
    end;
    execute 'reset role';
    return array[v_state, v_msg, v_detail, v_hint, v_res];
  end;
  $f$;

  -- ==== K: CATALOG ================================================================
  -- [K1] public.table_kicks, and the nine attempt_log actions.
  v_bad := '';
  select string_agg(a.attname::text || ' ' || format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else '' end, ', ' order by a.attnum)
  into v_txt
  from pg_attribute a
  where a.attrelid = 'public.table_kicks'::regclass and a.attnum > 0 and not a.attisdropped;
  if v_txt is distinct from 'table_id uuid not null, kicked_id uuid not null, host_id uuid, kicked_nickname text, kicked_role text not null, game_live boolean not null, game_id uuid, created_at timestamp with time zone not null' then
    v_bad := v_bad || 'columns "' || coalesce(v_txt, '?') || '"; ';
  end if;
  if not exists (select 1 from pg_constraint con where con.conrelid = 'public.table_kicks'::regclass and con.contype = 'p'
                   and pg_get_constraintdef(con.oid) = 'PRIMARY KEY (table_id, kicked_id)') then
    v_bad := v_bad || 'primary key; ';
  end if;
  if not exists (select 1 from pg_constraint con where con.conrelid = 'public.table_kicks'::regclass and con.contype = 'c'
                   and con.conname = 'table_kicks_role_check'
                   and pg_get_constraintdef(con.oid) ~ 'player' and pg_get_constraintdef(con.oid) ~ 'spectator' and pg_get_constraintdef(con.oid) ~ 'absent') then
    v_bad := v_bad || 'table_kicks_role_check; ';
  end if;
  if not exists (select 1 from pg_constraint con where con.conrelid = 'public.table_kicks'::regclass and con.contype = 'c'
                   and con.conname = 'table_kicks_not_self' and pg_get_constraintdef(con.oid) = 'CHECK ((host_id IS DISTINCT FROM kicked_id))') then
    v_bad := v_bad || 'table_kicks_not_self; ';
  end if;
  select string_agg(a.attname::text || '->' || fn.nspname::text || '.' || fc.relname::text || ':' || con.confdeltype::text, ', ' order by a.attname)
  into v_txt
  from pg_constraint con
  join pg_attribute a on a.attrelid = con.conrelid and a.attnum = con.conkey[1]
  join pg_class fc on fc.oid = con.confrelid
  join pg_namespace fn on fn.oid = fc.relnamespace
  where con.conrelid = 'public.table_kicks'::regclass and con.contype = 'f';
  if v_txt is distinct from 'game_id->public.games:n, host_id->auth.users:n, kicked_id->auth.users:c, table_id->public.tables:c' then
    v_bad := v_bad || 'foreign keys "' || coalesce(v_txt, '?') || '"; ';
  end if;
  select count(*) into v_n
  from pg_index i
  where i.indrelid = 'public.table_kicks'::regclass
    and i.indexrelid in (to_regclass('public.table_kicks_created_at_idx'), to_regclass('public.table_kicks_kicked_id_idx'), to_regclass('public.table_kicks_host_id_idx'));
  if v_n <> 3 then
    v_bad := v_bad || v_n::text || ' of the three indexes; ';
  end if;
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.table_kicks'::regclass) then
    v_bad := v_bad || 'RLS off; ';
  end if;
  select count(*) into v_n from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'table_kicks';
  if v_n <> 0 then
    v_bad := v_bad || v_n::text || ' policies; ';
  end if;
  select string_agg(case a.grantee when 0 then 'PUBLIC' else pg_get_userbyid(a.grantee)::text end || ':' || a.privilege_type, ', ')
  into v_txt
  from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
  where c.oid = 'public.table_kicks'::regclass
    and (a.grantee = 0 or a.grantee in (select r.oid from pg_roles r where r.rolname in ('anon', 'authenticated', 'service_role')));
  if v_txt is not null then
    v_bad := v_bad || 'client privileges ' || v_txt || '; ';
  end if;
  if exists (select 1 from pg_publication_tables pt where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = 'table_kicks') then
    v_bad := v_bad || 'in supabase_realtime; ';
  end if;
  select pg_get_constraintdef(con.oid) into v_txt
  from pg_constraint con
  where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check';
  if v_txt is null or (length(v_txt) - length(replace(v_txt, '::text', ''))) / 6 <> 9
     or v_txt !~ '''kick''' or v_txt !~ '''block_change''' or v_txt !~ '''follow_change''' or v_txt !~ '''game_start'''
     or v_txt !~ '''code_guess''' or v_txt !~ '''watch''' or v_txt !~ '''join''' or v_txt !~ '''create_computer_table''' or v_txt !~ '''create_table''' then
    v_bad := v_bad || 'attempt_log_action_check "' || coalesce(v_txt, 'missing') || '"; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K1] public.table_kicks / attempt_log: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K2] The five functions.
  v_bad := '';
  for v_rec in
    select * from (values
      ('public._is_kicked_from_table(uuid, uuid)', 'c8372af51a4537ca9cc079234487a414', false),
      ('public._send_kick_notice(uuid, jsonb)', '382554f98b1f199c20ca0b692fa0e6f2', false),
      ('public.kick_player(uuid, uuid)', 'd859deb84acb67ec94a2cf65fb1f38f0', true),
      ('public.kick_topic_allows(text)', '48327bb75cf98b6ff91388a6db843d11', true),
      ('public.admin_recent_kicks(integer)', 'a5a60cc3950475e702423f740b30cf40', true)
    ) as t(sig, lf, client)
  loop
    select v_rec.sig || ': '
           || case when md5(replace(p.prosrc, E'\r', '')) <> v_rec.lf then 'body md5 ' || md5(replace(p.prosrc, E'\r', '')) || ' ' else '' end
           || case when not p.prosecdef then 'not security definer ' else '' end
           || case when not (coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']) then 'search_path not empty ' else '' end
           || case when has_function_privilege('authenticated', p.oid, 'EXECUTE') <> v_rec.client then 'authenticated EXECUTE wrong ' else '' end
           || case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon EXECUTE ' else '' end
           || case when exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) then 'PUBLIC EXECUTE ' else '' end
           || case when exists (select 1 from pg_roles r where r.rolname = 'service_role')
                    and has_function_privilege('service_role', p.oid, 'EXECUTE') then 'service_role EXECUTE ' else '' end
    into v_txt
    from pg_proc p
    where p.oid = to_regprocedure(v_rec.sig);
    if v_txt is null then
      v_bad := v_bad || v_rec.sig || ' missing; ';
    elsif v_txt <> v_rec.sig || ': ' then
      v_bad := v_bad || v_txt || '; ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [K2] the M3 functions: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K3] Unchanged bodies.
  v_bad := '';
  for v_rec in
    select * from (values
      ('public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa'),
      ('public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c'),
      ('public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb'),
      ('public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d'),
      ('public.spectator_heartbeat(uuid)', '41d2ea0e865c2a9d5fa7203875a27ace', '6b7c271d78eb4f72c1aff3c851b578e1'),
      ('public.remove_spectator(uuid, uuid)', 'dafa688f1b8c194e4be575cd0625ba12', '9786b9a5e50245365a2598b18da5892e'),
      ('public.chat_topic_allows(text, boolean)', '0458d5122d68d511b2e0fbceafe84aae', 'c4e6eda360de7d7723c4069e60d95345'),
      ('public._attempts_guard(uuid, text, integer, interval, text)', 'b1b69dbbdf10d50f78655a0da3b3ac69', '9406938991e89dcd38d0686a279b432a'),
      ('public.block_player(text)', '10f6b07a3224aff16e1326daa6af5759', 'c742c78f77f58a92e6f38753c84b9f16'),
      ('public.unblock_player(uuid)', 'c0363d27028d621c0008654506bade75', '279ac52fde07f39491f747656943d84f'),
      ('public.get_my_blocks()', '3d50e2a273ca16b23f6d89348016d8de', '687616ef777e677d23b58678e3e3fd1e'),
      ('public._is_blocked_from_table(uuid, uuid)', '162f914c3b209186c819c66d18a23a99', '69b02ade7e62cad1ff49c44ae302b805')
    ) as t(fn, lf, crlf)
  loop
    select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is null or v_txt not in (v_rec.lf, v_rec.crlf) then
      v_bad := v_bad || v_rec.fn || ' md5 ' || coalesce(v_txt, 'missing') || ' (want ' || v_rec.crlf || ' / ' || v_rec.lf || '); ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [K3] changed bodies: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K4] realtime.messages: the kicks policy, and nothing else new.
  select count(*) into v_n
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
    and p.policyname = 'table kicks: people at the table receive' and p.cmd = 'SELECT'
    and p.qual ilike '%extension = ''broadcast''%'
    and p.qual ilike '%kick_topic_allows(%realtime.topic()%'
    and p.with_check is null
    and p.permissive = 'PERMISSIVE'
    and p.roles = array['authenticated']::name[];
  select string_agg(p.policyname::text || ' (' || p.cmd || ')', ', ' order by p.policyname) into v_txt
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
    and p.policyname not in ('table chat: members receive', 'table chat: members send', 'table kicks: people at the table receive');
  select count(*) into v_n2
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
    and p.policyname in ('table chat: members receive', 'table chat: members send');
  if v_n <> 1 or v_txt is not null or v_n2 <> 2
     or exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages'
                  and p.cmd in ('INSERT', 'ALL', 'UPDATE') and p.policyname <> 'table chat: members send')
     or exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                  where ns.nspname = 'public' and p.proname ilike '%chat%'
                    and p.proname in ('_is_kicked_from_table', '_send_kick_notice', 'kick_player', 'kick_topic_allows', 'admin_recent_kicks')) then
    raise exception 'FAIL [K4] realtime.messages: the kicks policy found % time(s) as part 1 wrote it (want 1); the table-chat policies % (want 2); unknown policies: %; or a write policy other than the chat send.',
      v_n, v_n2, coalesce(v_txt, '(none)');
  end if;
  v_checks := v_checks + 1;

  -- [K5] The notice can't undo the kick: its own exception block, last.
  select replace(p.prosrc, E'\r', '') into v_txt from pg_proc p where p.oid = to_regprocedure('public.kick_player(uuid, uuid)');
  if v_txt !~ E'\n  begin\n    perform public\\._send_kick_notice\\(p_table_id, [^;]*\\);\n  exception when others then\n    null;\n  end;\n\n  return ''kicked'';\nend;\n$'
     or strpos(v_txt, 'insert into public.table_kicks') = 0
     or strpos(v_txt, 'perform public._send_kick_notice(') < strpos(v_txt, 'insert into public.table_kicks')
     or strpos(v_txt, 'perform public._send_kick_notice(') < strpos(v_txt, 'delete from public.table_members')
     or strpos(v_txt, 'perform public._send_kick_notice(') < strpos(v_txt, 'set status = ''ended'', ended_reason = ''player_left''')
     or (length(v_txt) - length(replace(v_txt, '_send_kick_notice', ''))) / length('_send_kick_notice') <> 1 then
    raise exception 'FAIL [K5] kick_player does not call _send_kick_notice exactly once, last, inside its own BEGIN ... EXCEPTION WHEN OTHERS THEN NULL block.';
  end if;
  select replace(p.prosrc, E'\r', '') into v_txt from pg_proc p where p.oid = to_regprocedure('public._send_kick_notice(uuid, jsonb)');
  if strpos(v_txt, 'perform realtime.send(p_payload, ''kick'', ''kicks:'' || p_table_id::text, true);') = 0 then
    raise exception 'FAIL [K5] _send_kick_notice does not call realtime.send(p_payload, ''kick'', ''kicks:'' || p_table_id::text, true).';
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner =========================================================
  v_people := array[v_h, v_p, v_q, v_y, v_s, v_s2, v_rm, v_z, v_o, v_ad, v_c2, v_h2, v_c3, v_x3, v_h4, v_h5, v_f, v_g1, v_o2];
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'm3-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      insert into public.profiles (id, nickname)
      values (v_pid, 'm3' || left(replace(v_pid::text, '-', ''), 12))
      on conflict (id) do update set nickname = excluded.nickname;
    end loop;
    insert into public.admin_users (user_id) values (v_ad);
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts and profiles: % (%).', sqlerrm, sqlstate;
  end;

  select ca.user_id into v_comp from public.computer_accounts ca where ca.level = 'easy';
  if v_comp is null then
    raise exception 'SETUP: no easy computer account (computer-accounts-setup.sql).';
  end if;

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    -- Codes no OPEN table holds -- every table while tables_code_open_key
    -- doesn't exist (the predicate the other suites use).
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                        and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null))
    order by n
    limit 8
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 8 then
    raise exception 'SETUP: fewer than eight free table codes.';
  end if;

  begin
    -- T1: H's, 4 seats: H, P, Q, Y; a live game; S, S2 watching; R removed;
    -- Y also has an old removed spectator row.
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[1], v_h, true, true, 4) returning id into v_t1;
    insert into public.table_members (table_id, user_id) values (v_t1, v_h);
    insert into public.table_members (table_id, user_id) values (v_t1, v_p);
    insert into public.table_members (table_id, user_id) values (v_t1, v_q);
    insert into public.table_members (table_id, user_id) values (v_t1, v_y);
    insert into public.games (table_id, created_by, status, players, deal_cut, created_at)
    values (v_t1, v_h, 'cutting', array[v_h, v_p, v_q, v_y], '[[]]'::jsonb, now() - interval '1 hour') returning id into v_game;
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at)
    values (v_t1, v_s, now(), now()), (v_t1, v_s2, now(), now());
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at, removed_at)
    values (v_t1, v_rm, now(), now(), now()), (v_t1, v_y, now(), now(), now());
    -- T2: C2's; H2 seated (the host: C2 only watches).
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[2], v_c2, true, true, 2) returning id into v_t2;
    insert into public.table_members (table_id, user_id) values (v_t2, v_h2);
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at) values (v_t2, v_c2, now(), now());
    -- T3: C3's; C3 and X3 seated.
    insert into public.tables (code, created_by, is_public, max_players)
    values (v_codes[3], v_c3, true, 2) returning id into v_t3;
    insert into public.table_members (table_id, user_id) values (v_t3, v_c3);
    insert into public.table_members (table_id, user_id) values (v_t3, v_x3);
    -- T4: H4's computer table.
    insert into public.tables (code, created_by, computer_level) values (v_codes[4], v_h4, 'easy') returning id into v_t4;
    insert into public.table_members (table_id, user_id) values (v_t4, v_h4);
    -- T5: H5's, ended.
    insert into public.tables (code, created_by, is_public) values (v_codes[5], v_h5, true) returning id into v_t5;
    insert into public.table_members (table_id, user_id) values (v_t5, v_h5);
    update public.tables set status = 'ended', ended_reason = 'empty' where id = v_t5;
    -- T6: F's (the hourly limit).
    insert into public.tables (code, created_by, is_public) values (v_codes[6], v_f, true) returning id into v_t6;
    insert into public.table_members (table_id, user_id) values (v_t6, v_f);
    -- T7: O2's (P joins it after the kick).
    insert into public.tables (code, created_by, is_public, max_players) values (v_codes[7], v_o2, true, 2) returning id into v_t7;
    insert into public.table_members (table_id, user_id) values (v_t7, v_o2);
  exception when others then
    raise exception 'SETUP: could not create the test tables: % (%).', sqlerrm, sqlstate;
  end;
  v_topic := 'kicks:' || v_t1::text;

  -- ==== C: KICK =====================================================================
  -- [C1] H kicks P mid-game.
  v_r := pg_temp.m3_as('authenticated', v_h, format('select public.kick_player(%L, %L)', v_t1, v_p));
  if v_r[5] is distinct from 'kicked'
     or exists (select 1 from public.table_members tm where tm.table_id = v_t1 and tm.user_id = v_p)
     or (select g.status || '/' || coalesce(g.ended_reason, '-') from public.games g where g.id = v_game) is distinct from 'ended/player_left'
     or (select t.status from public.tables t where t.id = v_t1) is distinct from 'open'
     or not exists (select 1 from public.table_kicks k
                    where k.table_id = v_t1 and k.kicked_id = v_p and k.host_id = v_h and k.kicked_role = 'player'
                      and k.game_live and k.game_id = v_game and k.kicked_nickname = 'm3' || left(replace(v_p::text, '-', ''), 12))
     or (select count(*) from public.attempt_log al where al.user_id = v_h and al.action = 'kick') <> 1 then
    raise exception 'FAIL [C1] H kicking P mid-game: % (error %); expected kicked, P''s seat gone, the game ended as player_left, T1 open, the row, 1 kick counted.',
      coalesce(v_r[5], '-'), coalesce(v_r[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [N1] The notice, when Realtime can store it (and this role can read it).
  begin
    select count(*) into v_n from realtime.messages m where m.topic = v_topic and m.event = 'kick';
  exception when others then
    v_n := -1;
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  if v_n = -1 then
    v_skips := ' Skipped N1-N2: this role cannot read realtime.messages (' || v_txt || ').';
  elsif v_n = 0 then
    v_skips := ' Skipped N1-N2: kick_player''s notice was not stored, or this role cannot see it (usually no realtime.messages partition for today; the kick itself stood, and C12 proves a failed send never undoes one).';
  elsif not has_table_privilege('authenticated', 'realtime.messages', 'SELECT')
        or not has_table_privilege('authenticated', 'realtime.messages', 'INSERT') then
    v_skips := ' Skipped N1-N2: authenticated lacks SELECT or INSERT on realtime.messages.';
  else
    v_live := true;
    if v_n <> 1 or not exists (
         select 1 from realtime.messages m
         where m.topic = v_topic and m.event = 'kick' and m.private and m.extension = 'broadcast'
           and m.payload ->> 'kicked_id' = v_p::text
           and m.payload ->> 'nickname' = 'm3' || left(replace(v_p::text, '-', ''), 12)
           and (m.payload ->> 'at') ~ '^[0-9]+$') then
      raise exception 'FAIL [N1] % notice(s) on % (want exactly 1: event kick, private, broadcast, kicked_id P, P''s nickname, at in ms).', v_n, v_topic;
    end if;
    v_checks := v_checks + 1;
  end if;

  -- [C2] H kicks S, a current spectator.
  v_r := pg_temp.m3_as('authenticated', v_h, format('select public.kick_player(%L, %L)', v_t1, v_s));
  v_r2 := pg_temp.m3_as('authenticated', v_s, format('select public.spectator_heartbeat(%L)', v_t1));
  if v_r[5] is distinct from 'kicked'
     or not exists (select 1 from public.table_spectators ts where ts.table_id = v_t1 and ts.user_id = v_s and ts.removed_at is not null)
     or not exists (select 1 from public.table_kicks k where k.table_id = v_t1 and k.kicked_id = v_s and k.kicked_role = 'spectator' and not k.game_live)
     or v_r2[5] is distinct from 'removed' then
    raise exception 'FAIL [C2] H kicking S: % (error %), heartbeat % (error %); expected kicked, removed_at set, role spectator, no live game, heartbeat removed.',
      coalesce(v_r[5], '-'), coalesce(v_r[2], 'none'), coalesce(v_r2[5], '-'), coalesce(v_r2[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [C3] H kicks Z, who is not at the table.
  v_r := pg_temp.m3_as('authenticated', v_h, format('select public.kick_player(%L, %L)', v_t1, v_z));
  if v_r[5] is distinct from 'kicked'
     or not exists (select 1 from public.table_kicks k where k.table_id = v_t1 and k.kicked_id = v_z and k.kicked_role = 'absent') then
    raise exception 'FAIL [C3] H kicking Z (absent): % (error %); expected kicked, role absent.', coalesce(v_r[5], '-'), coalesce(v_r[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [N2] Who receives kicks:<T1> (live policies), and nobody may send on it.
  if v_live then
    select count(*) into v_n from realtime.messages m where m.topic = v_topic and m.event = 'kick';
    v_bad := '';
    for v_rec in
      select * from (values
        ('H (seated)', v_h, v_n),
        ('S2 (current spectator)', v_s2, v_n),
        ('O (no relation)', v_o, 0),
        ('P (kicked)', v_p, 0),
        ('S (removed)', v_s, 0)
      ) as t(label, who, want)
    loop
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.who, 'role', 'authenticated')::text, true);
      perform set_config('realtime.topic', v_topic, true);
      execute 'set local role authenticated';
      select count(*) into v_n2 from realtime.messages m where m.topic = v_topic and m.event = 'kick';
      execute 'reset role';
      if v_n2 <> v_rec.want then
        v_bad := v_bad || v_rec.label || ' saw ' || v_n2::text || ' (want ' || v_rec.want::text || '); ';
      end if;
    end loop;
    perform set_config('request.jwt.claims', json_build_object('sub', v_h, 'role', 'authenticated')::text, true);
    perform set_config('realtime.topic', v_topic, true);
    v_state := null;
    execute 'set local role authenticated';
    begin
      insert into realtime.messages (topic, extension, event, payload, private)
      values (v_topic, 'broadcast', 'kick', jsonb_build_object('kicked_id', v_o::text, 'nickname', 'fake'), true);
    exception when others then
      v_state := sqlstate;
    end;
    execute 'reset role';
    if v_state is distinct from '42501' then
      v_bad := v_bad || 'H sending on ' || v_topic || ': ' || coalesce(v_state, 'allowed') || ' (want 42501); ';
    end if;
    if v_bad <> '' then
      raise exception 'FAIL [N2] the kicks policy: %', v_bad;
    end if;
    v_checks := v_checks + 1;
  end if;

  -- [C4] Already kicked: nothing changes, nothing counted.
  v_r := pg_temp.m3_as('authenticated', v_h, format('select public.kick_player(%L, %L)', v_t1, v_p));
  if v_r[5] is distinct from 'already_kicked'
     or (select count(*) from public.table_kicks k where k.table_id = v_t1) <> 3
     or (select count(*) from public.attempt_log al where al.user_id = v_h and al.action = 'kick') <> 3 then
    raise exception 'FAIL [C4] H kicking P again: % (error %); expected already_kicked, 3 kicks at T1, 3 counted for H.', coalesce(v_r[5], '-'), coalesce(v_r[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [C5] Refusals, none counted.
  v_bad := '';
  for v_rec in
    select * from (values
      ('Q (not the host) kicks Y', 'authenticated', v_q, format('select public.kick_player(%L, %L)', v_t1, v_y), 'P0001', 'Only the host can kick.'),
      ('H kicks H', 'authenticated', v_h, format('select public.kick_player(%L, %L)', v_t1, v_h), 'P0001', 'You can''t kick yourself.'),
      ('nobody logged in', 'authenticated', null::uuid, format('select public.kick_player(%L, %L)', v_t1, v_y), 'P0001', 'You must be logged in to kick a player.'),
      ('anon', 'anon', null::uuid, format('select public.kick_player(%L, %L)', v_t1, v_y), '42501', null),
      ('an unknown table', 'authenticated', v_h, format('select public.kick_player(%L, %L)', gen_random_uuid(), v_y), 'P0001', 'Table not found.'),
      ('an unknown person', 'authenticated', v_h, format('select public.kick_player(%L, %L)', v_t1, gen_random_uuid()), 'P0001', 'That player was not found.'),
      ('the computer account', 'authenticated', v_h, format('select public.kick_player(%L, %L)', v_t1, v_comp), 'P0001', 'You can''t kick a computer player.')
    ) as t(label, role, who, stmt, want_state, want_msg)
  loop
    v_r := pg_temp.m3_as(v_rec.role, v_rec.who, v_rec.stmt);
    if v_r[1] is distinct from v_rec.want_state or (v_rec.want_msg is not null and v_r[2] is distinct from v_rec.want_msg) then
      v_bad := v_bad || v_rec.label || ': ' || coalesce(v_r[1], 'ok') || ' ' || coalesce(v_r[2], coalesce(v_r[5], '-')) || '; ';
    end if;
  end loop;
  if (select count(*) from public.attempt_log al where al.user_id = v_h and al.action = 'kick') <> 3
     or exists (select 1 from public.attempt_log al where al.user_id = v_q and al.action = 'kick')
     or (select count(*) from public.table_kicks k where k.table_id = v_t1) <> 3
     or not exists (select 1 from public.table_members tm where tm.table_id = v_t1 and tm.user_id = v_y) then
    v_bad := v_bad || 'something was counted, logged or changed; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [C5] refusals: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C6] A computer table and an ended table.
  v_r := pg_temp.m3_as('authenticated', v_h4, format('select public.kick_player(%L, %L)', v_t4, v_z));
  v_r2 := pg_temp.m3_as('authenticated', v_h5, format('select public.kick_player(%L, %L)', v_t5, v_z));
  if v_r[2] is distinct from 'You can''t kick anyone at a computer table.' or v_r2[2] is distinct from 'This table has ended.'
     or exists (select 1 from public.table_kicks k where k.table_id in (v_t4, v_t5)) then
    raise exception 'FAIL [C6] computer table: % ; ended table: %; expected the two refusals and no row.', coalesce(v_r[2], coalesce(v_r[5], '-')), coalesce(v_r2[2], coalesce(v_r2[5], '-'));
  end if;
  v_checks := v_checks + 1;

  -- [C7] The creator rules.
  v_r := pg_temp.m3_as('authenticated', v_x3, format('select public.kick_player(%L, %L)', v_t3, v_c3));
  v_r2 := pg_temp.m3_as('authenticated', v_c3, format('select public.kick_player(%L, %L)', v_t3, v_c3));
  v_txt := (pg_temp.m3_as('authenticated', v_h2, format('select public.kick_player(%L, %L)', v_t2, v_c2)))[5];
  if v_r[2] is distinct from 'Only the host can kick.' or v_r2[2] is distinct from 'You can''t kick yourself.'
     or not exists (select 1 from public.table_members tm where tm.table_id = v_t3 and tm.user_id = v_c3)
     or v_txt is distinct from 'kicked'
     or not exists (select 1 from public.table_kicks k where k.table_id = v_t2 and k.kicked_id = v_c2 and k.host_id = v_h2 and k.kicked_role = 'spectator') then
    raise exception 'FAIL [C7] X3 kicks the seated creator C3: %; C3 kicks C3: %; H2 kicks the watching creator C2: %. Expected the two refusals (C3 still seated), then kicked.',
      coalesce(v_r[2], coalesce(v_r[5], '-')), coalesce(v_r2[2], coalesce(v_r2[5], '-')), coalesce(v_txt, '-');
  end if;
  v_checks := v_checks + 1;

  -- [C8] The hourly limit (real kicks only, 20 an hour).
  insert into public.attempt_log (user_id, action, success)
  select v_f, 'kick', true from generate_series(1, 20);
  v_r := pg_temp.m3_as('authenticated', v_f, format('select public.kick_player(%L, %L)', v_t6, v_g1));
  if v_r[1] is distinct from 'P0001' or v_r[2] is distinct from v_limit_msg or v_r[3] is distinct from 'rate_limited'
     or exists (select 1 from public.table_kicks k where k.table_id = v_t6)
     or (select count(*) from public.attempt_log al where al.user_id = v_f and al.action = 'kick') <> 20 then
    raise exception 'FAIL [C8] F''s 21st kick in an hour: % % (detail %); expected P0001, "%", detail rate_limited, no row, still 20.',
      coalesce(v_r[1], 'ok'), coalesce(v_r[2], coalesce(v_r[5], '-')), coalesce(v_r[3], '-'), v_limit_msg;
  end if;
  update public.attempt_log al set created_at = now() - interval '61 minutes' where al.user_id = v_f and al.action = 'kick';
  v_r := pg_temp.m3_as('authenticated', v_f, format('select public.kick_player(%L, %L)', v_t6, v_g1));
  if v_r[5] is distinct from 'kicked' then
    raise exception 'FAIL [C8] F''s kick with the 20 moved 61 minutes back: % (error %); expected kicked.', coalesce(v_r[5], '-'), coalesce(v_r[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [C9] admin_recent_kicks.
  v_r := pg_temp.m3_as('authenticated', v_h, 'select count(*)::text from public.admin_recent_kicks(10)');
  v_r2 := pg_temp.m3_as('authenticated', null, 'select count(*)::text from public.admin_recent_kicks(10)');
  v_txt := (pg_temp.m3_as('authenticated', v_ad, format(
    'select string_agg(table_code || '':'' || host_nickname || '':'' || kicked_nickname || '':'' || kicked_role, '','' order by kicked_role, kicked_nickname) from public.admin_recent_kicks(200) where table_id = %L',
    v_t1)))[5];
  if v_r[2] is distinct from 'Admins only.' or v_r2[2] is distinct from 'Admins only.'
     or v_txt is distinct from (
       select string_agg(v_codes[1] || ':m3' || left(replace(v_h::text, '-', ''), 12) || ':m3' || left(replace(x.id::text, '-', ''), 12) || ':' || x.role, ',' order by x.role, 'm3' || left(replace(x.id::text, '-', ''), 12))
       from (values (v_p, 'player'), (v_s, 'spectator'), (v_z, 'absent')) as x(id, role)) then
    raise exception 'FAIL [C9] admin_recent_kicks: non-admin %, nobody %, admin sees "%"; expected Admins only twice and T1''s three kicks.',
      coalesce(v_r[2], coalesce(v_r[5], '-')), coalesce(v_r2[2], coalesce(v_r2[5], '-')), coalesce(v_txt, '-');
  end if;
  v_checks := v_checks + 1;

  -- [C10] Clients cannot touch public.table_kicks.
  v_bad := '';
  for v_rec in
    select * from (values
      ('H SELECT', 'authenticated', v_h, 'select count(*)::text from public.table_kicks'),
      ('H INSERT', 'authenticated', v_h, format('insert into public.table_kicks (table_id, kicked_id, kicked_role, game_live) values (%L, %L, ''absent'', false) returning ''x''', v_t1, v_o)),
      ('anon SELECT', 'anon', null::uuid, 'select count(*)::text from public.table_kicks')
    ) as t(label, role, who, stmt)
  loop
    v_r := pg_temp.m3_as(v_rec.role, v_rec.who, v_rec.stmt);
    if v_r[1] is distinct from '42501' then
      v_bad := v_bad || v_rec.label || ': ' || coalesce(v_r[1], 'allowed (' || coalesce(v_r[5], '-') || ')') || '; ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [C10] public.table_kicks as a client (want 42501 each): %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C11] kick_topic_allows.
  v_bad := '';
  for v_rec in
    select * from (values
      ('H (seated)', 'authenticated', v_h, v_topic, 'true'),
      ('S2 (current spectator)', 'authenticated', v_s2, v_topic, 'true'),
      ('S (removed)', 'authenticated', v_s, v_topic, 'false'),
      ('P (kicked)', 'authenticated', v_p, v_topic, 'false'),
      ('O (no relation)', 'authenticated', v_o, v_topic, 'false'),
      ('nobody logged in', 'authenticated', null::uuid, v_topic, 'false'),
      ('an uppercase topic', 'authenticated', v_h, upper(v_topic), 'false'),
      ('a chat topic', 'authenticated', v_h, 'chat:' || v_t1::text || ':' || v_h::text, 'false'),
      ('H4 at the computer table', 'authenticated', v_h4, 'kicks:' || v_t4::text, 'false')
    ) as t(label, role, who, topic, want)
  loop
    v_r := pg_temp.m3_as(v_rec.role, v_rec.who, format('select public.kick_topic_allows(%L)::text', v_rec.topic));
    if v_r[5] is distinct from v_rec.want then
      v_bad := v_bad || v_rec.label || ': ' || coalesce(v_r[5], v_r[2]) || ' (want ' || v_rec.want || '); ';
    end if;
  end loop;
  v_r := pg_temp.m3_as('anon', null, format('select public.kick_topic_allows(%L)::text', v_topic));
  if v_r[1] is distinct from '42501' then
    v_bad := v_bad || 'anon: ' || coalesce(v_r[1], 'it ran') || ' (want 42501); ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [C11] kick_topic_allows: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== J: JOIN AND WATCH (part 2) ==================================================
  if v_p2 then
    -- [K6] Part 2's bodies, authenticated only.
    if not has_function_privilege('authenticated', 'public.join_table_by_code(text, boolean, uuid)', 'EXECUTE')
       or not has_function_privilege('authenticated', 'public.watch_table(text, uuid)', 'EXECUTE')
       or has_function_privilege('anon', 'public.join_table_by_code(text, boolean, uuid)', 'EXECUTE')
       or has_function_privilege('anon', 'public.watch_table(text, uuid)', 'EXECUTE') then
      raise exception 'FAIL [K6] join_table_by_code / watch_table EXECUTE is not authenticated-only.';
    end if;
    v_checks := v_checks + 1;

    -- [J1] P joining T1: code, id, preview by code and by id.
    v_bad := '';
    foreach v_txt in array array[
      format('select outcome from public.join_table_by_code(%L)', v_codes[1]),
      format('select outcome from public.join_table_by_code(%L, false, %L)', v_codes[1], v_t1),
      format('select outcome from public.join_table_by_code(%L, true)', v_codes[1]),
      format('select outcome from public.join_table_by_code(%L, true, %L)', v_codes[1], v_t1)]
    loop
      v_r := pg_temp.m3_as('authenticated', v_p, v_txt);
      if v_r[1] is distinct from 'P0001' or v_r[2] is distinct from v_refusal or v_r[3] is distinct from '' or v_r[4] is distinct from '' or v_r[5] is not null then
        v_bad := v_bad || v_txt || ': ' || coalesce(v_r[1], 'ok') || ' ' || coalesce(v_r[2], coalesce(v_r[5], '-')) || ' detail "' || coalesce(v_r[3], '?') || '" hint "' || coalesce(v_r[4], '?') || '"; ';
      end if;
    end loop;
    if exists (select 1 from public.table_members tm where tm.table_id = v_t1 and tm.user_id = v_p) then
      v_bad := v_bad || 'P is seated; ';
    end if;
    if v_bad <> '' then
      raise exception 'FAIL [J1] P (kicked) joining T1: %', v_bad;
    end if;
    v_checks := v_checks + 1;

    -- [J2] P, S and Z watching T1.
    v_bad := '';
    for v_rec in
      select * from (values
        ('P by code', v_p, format('select table_id::text from public.watch_table(%L)', v_codes[1])),
        ('P by id', v_p, format('select table_id::text from public.watch_table(%L, %L)', v_codes[1], v_t1)),
        ('S by code', v_s, format('select table_id::text from public.watch_table(%L)', v_codes[1])),
        ('S by id', v_s, format('select table_id::text from public.watch_table(%L, %L)', v_codes[1], v_t1)),
        ('Z by id', v_z, format('select table_id::text from public.watch_table(%L, %L)', v_codes[1], v_t1))
      ) as t(label, who, stmt)
    loop
      v_r := pg_temp.m3_as('authenticated', v_rec.who, v_rec.stmt);
      if v_r[1] is distinct from 'P0001' or v_r[2] is distinct from v_refusal or v_r[3] is distinct from '' or v_r[4] is distinct from '' then
        v_bad := v_bad || v_rec.label || ': ' || coalesce(v_r[1], 'ok') || ' ' || coalesce(v_r[2], coalesce(v_r[5], '-')) || '; ';
      end if;
    end loop;
    if exists (select 1 from public.table_spectators ts where ts.table_id = v_t1 and ts.user_id in (v_p, v_z)) then
      v_bad := v_bad || 'a spectator row for P or Z; ';
    end if;
    if v_bad <> '' then
      raise exception 'FAIL [J2] kicked people watching T1: %', v_bad;
    end if;
    v_checks := v_checks + 1;

    -- [J3] Nothing counted for P, S or Z.
    select count(*) into v_n
    from public.attempt_log al
    where al.user_id in (v_p, v_s, v_z)
      and al.action in ('join', 'watch', 'code_guess', 'create_table', 'create_computer_table');
    if v_n <> 0 then
      raise exception 'FAIL [J3] the refused joins and watches counted % attempt_log row(s); expected none.', v_n;
    end if;
    v_checks := v_checks + 1;

    -- [J4] R, removed by the old path: no seat, and watching still "removed".
    v_r := pg_temp.m3_as('authenticated', v_rm, format('select outcome from public.join_table_by_code(%L, false, %L)', v_codes[1], v_t1));
    v_r2 := pg_temp.m3_as('authenticated', v_rm, format('select table_id::text from public.watch_table(%L, %L)', v_codes[1], v_t1));
    if v_r[2] is distinct from v_refusal or v_r2[2] is distinct from 'You were removed from watching this table.'
       or exists (select 1 from public.table_members tm where tm.table_id = v_t1 and tm.user_id = v_rm) then
      raise exception 'FAIL [J4] R (removed, not kicked): join % ; watch %. Expected the refusal, then "You were removed from watching this table.".',
        coalesce(v_r[2], coalesce(v_r[5], '-')), coalesce(v_r2[2], coalesce(v_r2[5], '-'));
    end if;
    v_checks := v_checks + 1;

    -- [J5] Y, seated with an old removed spectator row: already_seated.
    v_r := pg_temp.m3_as('authenticated', v_y, format('select outcome from public.join_table_by_code(%L, true, %L)', v_codes[1], v_t1));
    if v_r[5] is distinct from 'already_seated' then
      raise exception 'FAIL [J5] Y (seated, old removed row) previewing T1: % (error %); expected already_seated.', coalesce(v_r[5], '-'), coalesce(v_r[2], 'none');
    end if;
    v_checks := v_checks + 1;

    -- [J6] Per table only.
    v_r := pg_temp.m3_as('authenticated', v_o, format('select outcome from public.join_table_by_code(%L, false, %L)', v_codes[1], v_t1));
    v_r2 := pg_temp.m3_as('authenticated', v_p, format('select outcome from public.join_table_by_code(%L, false, %L)', v_codes[7], v_t7));
    if v_r[5] is distinct from 'joined' or v_r2[5] is distinct from 'joined' then
      raise exception 'FAIL [J6] O joining T1: % (error %); P joining T7: % (error %). Expected joined twice.',
        coalesce(v_r[5], '-'), coalesce(v_r[2], 'none'), coalesce(v_r2[5], '-'), coalesce(v_r2[2], 'none');
    end if;
    v_checks := v_checks + 1;
  end if;

  -- ==== C12: A FAILING NOTICE DOES NOT UNDO A KICK (last) =============================
  -- The real send is replaced by one that always raises (rolled back with
  -- everything at the end), proved to raise, then H kicks Q.
  create or replace function public._send_kick_notice(p_table_id uuid, p_payload jsonb)
  returns void
  language plpgsql
  volatile
  security definer
  set search_path = ''
  as $f$
  begin
    raise exception 'm3 verification: the notice fails on purpose';
  end;
  $f$;
  v_state := null;
  begin
    perform public._send_kick_notice(v_t1, '{}'::jsonb);
  exception when others then
    v_state := sqlstate;
  end;
  v_r := pg_temp.m3_as('authenticated', v_h, format('select public.kick_player(%L, %L)', v_t1, v_q));
  if v_state is null
     or v_r[5] is distinct from 'kicked'
     or exists (select 1 from public.table_members tm where tm.table_id = v_t1 and tm.user_id = v_q)
     or not exists (select 1 from public.table_kicks k where k.table_id = v_t1 and k.kicked_id = v_q and k.kicked_role = 'player')
     or (select count(*) from public.attempt_log al where al.user_id = v_h and al.action = 'kick') <> 4 then
    raise exception 'FAIL [C12] with the notice failing (it raised: %), H kicking Q: % (error %); expected kicked, Q''s seat gone, the row there, 4 kicks counted for H.',
      coalesce(v_state, 'NO -- the test send did not fail'), coalesce(v_r[5], '-'), coalesce(v_r[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- ==== VERDICT =====================================================================
  -- 5 catalog + 12 kick (C1-C12) + 2 notice (N1-N2, only when Realtime can
  -- store the notice) + 7 join/watch (K6, J1-J6, part 2 only). The expected
  -- count goes into a variable first (a CASE inside an IF condition is a
  -- syntax trap in PL/pgSQL).
  v_expect := 17 + (case when v_live then 2 else 0 end) + (case when v_p2 then 7 else 0 end);
  if v_checks <> v_expect then
    raise exception 'FAIL: % checks ran, expected %.', v_checks, v_expect;
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  if v_p2 then
    raise exception 'ALL % CHECKS PASSED (rolled back).%', v_checks, v_skips;
  end if;
  raise exception 'ALL % PART-1 CHECKS PASSED (rolled back; part 2 is not in yet, so the 7 join/watch checks were skipped).%', v_checks, v_skips;
end;
$$;
