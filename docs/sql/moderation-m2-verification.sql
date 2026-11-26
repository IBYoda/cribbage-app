-- Moderation, slice M2: VERIFICATION of block_player_by_id
-- (docs/sql/moderation-m2-part1.sql).
--
-- Run in the Supabase Dashboard -> SQL Editor after part 1. The whole file
-- is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M2): precheck -> part 1 -> THIS FILE ->
-- slice-e-grants-verification.sql and moderation-m1-verification.sql -> the
-- app (PR) -> the hand test.
--
-- It WRITES -- one temporary function in pg_temp (m2_as: runs one statement
-- as a client role and returns its result or its error), temporary accounts
-- in auth.users and their profiles (8 people and 101 Block List targets), a
-- test table and its seat, blocks and attempt_log rows; it calls
-- block_player_by_id, block_player, unblock_player, get_my_blocks,
-- join_table_by_code and watch_table as those people -- and then
-- deliberately raises an exception at the very end, which rolls EVERY write
-- back. A check that fails raises its own exception at once, which rolls
-- everything back the same way. It always "fails": the message is the
-- verdict (the dashboard hides notices).
--   "ALL 17 CHECKS PASSED (rolled back)." is a pass.
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives. now() is frozen inside a
-- DO block, so "an hour ago" is made by moving attempt_log.created_at back
-- as the owner.
--
-- PEOPLE: A (the blocker; creates table TA, seated), B (a target with a
-- nickname; then the blocked person who tries to join and watch TA), N (a
-- target with a BLANK nickname), E (the cap), F (the hourly limit), X (an
-- account with NO profile), the easy computer account, 101 targets.
--
-- WHAT IT CHECKS
--   K1  block_player_by_id(p_target uuid): part 1's body, security definer,
--       search_path '', EXECUTE for authenticated only (not anon, PUBLIC or
--       service_role); the only function by that name.
--   K2  unchanged, byte for byte (md5): block_player, unblock_player,
--       get_my_blocks, _is_blocked_from_table (moderation-m1-part1.sql),
--       join_table_by_code and watch_table (moderation-m1-part2.sql, or
--       moderation M3 part 2's: M1's plus the kick refusal),
--       leave_table, end_timed_out_sessions, assign_table_seat, table_host
--       (fingerprinted), _attempts_guard, spectator_heartbeat,
--       remove_spectator, chat_topic_allows.
--   K3  authenticated may execute block_player_by_id and still the three M1
--       RPCs, and still NOT _is_blocked_from_table. (The exact count, 53, is
--       slice-e-grants-verification.sql's X1, which knows the state.)
--   I1  A blocks B by id: 'blocked', the row, 1 block_change row.
--   I2  again: 'already_blocked'; still 1 row and 1 block.
--   I3  not_found, nothing counted: an unknown id, X (an account with no
--       profile), null.
--   I4  not_allowed, nothing counted, no row: A blocks A, A blocks the
--       computer, the computer (as the caller) blocks B.
--   I5  a target with a BLANK nickname (N) is blockable: 'blocked', and
--       get_my_blocks lists N.
--   I6  THE CAP: E with 100 blocks: blocking the 101st by id is 'limit' (no
--       row, nothing counted); one already there is 'already_blocked'.
--   I7  THE HOURLY LIMIT, real changes only: F's 15 blocks by id and 15
--       unblocks are allowed; the 31st (a block by id) is refused: P0001,
--       detail rate_limited, block_player's message; no row; still 30 rows.
--       The counter is shared: F's block_player by nickname is refused the
--       same way; with the 30 rows moved 61 minutes back, the block by id is
--       allowed.
--   I8  unblock_player undoes a block by id: A unblocks B: 'unblocked', the
--       row gone, A now has 3 block_change rows (I1, I5, this).
--   I9  a block by id keeps the person out of the blocker's tables: A blocks
--       B by id again; B joining TA by typed code and by id, and B's preview
--       of TA, are refused "You can't join this table." (P0001, no detail,
--       no hint, no row); no seat.
--   I10 B watching TA by code and by id: the same refusal; no spectator row.
--   I11 none of I9-I10 counted anything for B: no join, watch, code_guess,
--       create_table or create_computer_table row (B has no block_change
--       rows either: B blocked nobody).
--   I12 nobody logged in: block_player_by_id raises "You must be logged in
--       to block a player.".
--   I13 the target learns nothing: B's get_my_blocks is empty and B reading
--       public.blocks is refused (42501).
--   I14 block_player_by_id acts only on the caller's own list: after B calls
--       it on A, A's list is unchanged and B's list is exactly A.
--
-- Expected message:
--   ALL 17 CHECKS PASSED (rolled back).

do $$
declare
  v_checks int := 0;
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_nb uuid := gen_random_uuid();
  v_e uuid := gen_random_uuid();
  v_f uuid := gen_random_uuid();
  v_x uuid := gen_random_uuid();
  v_targets uuid[] := '{}';
  v_people uuid[];
  v_pid uuid;
  v_comp uuid;
  v_code text;
  v_ta uuid;
  v_rec record;
  v_txt text;
  v_bad text;
  v_n int;
  v_r text[];
  v_r2 text[];
  v_refusal text := 'You can''t join this table.';
  v_limit_msg text := 'You have changed your Block List 30 times in the last hour. Please try again a little later.';
begin
  -- ==== SETUP CHECK ================================================================
  if to_regprocedure('public.block_player_by_id(uuid)') is null then
    raise exception 'SETUP: block_player_by_id(uuid) does not exist. Run docs/sql/moderation-m2-part1.sql first.';
  end if;
  if to_regclass('public.blocks') is null then
    raise exception 'SETUP: public.blocks does not exist (moderation M1 part 1 is not in).';
  end if;

  -- m2_as(role, user, sql): runs one statement as that client role (the
  -- user as auth.uid(), or nobody when null) and returns
  -- {sqlstate, message, detail, hint, first column of the first row} --
  -- the error fields null when it worked. Rolled back with everything else.
  create function pg_temp.m2_as(p_role text, p_uid uuid, p_sql text)
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
  -- [K1] The new function.
  select case when md5(replace(p.prosrc, E'\r', '')) <> 'c80a2bde62d206edbe1784b84c5d7b3b' then 'body md5 ' || md5(replace(p.prosrc, E'\r', '')) || ' ' else '' end
         || case when not p.prosecdef then 'invoker ' else '' end
         || case when not (coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']) then 'search_path ' else '' end
         || case when not has_function_privilege('authenticated', p.oid, 'EXECUTE') then 'no authenticated EXECUTE ' else '' end
         || case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon EXECUTE ' else '' end
         || case when exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) then 'PUBLIC grant ' else '' end
         || case when exists (select 1 from pg_roles r where r.rolname = 'service_role')
                      and has_function_privilege('service_role', p.oid, 'EXECUTE') then 'service_role EXECUTE ' else '' end
         || case when pg_get_function_arguments(p.oid) <> 'p_target uuid' then 'arguments "' || pg_get_function_arguments(p.oid) || '" ' else '' end
         || case when pg_get_function_result(p.oid) <> 'text' then 'returns ' || pg_get_function_result(p.oid) || ' ' else '' end
  into v_txt
  from pg_proc p where p.oid = to_regprocedure('public.block_player_by_id(uuid)');
  select count(*) into v_n
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'block_player_by_id';
  if v_txt <> '' or v_n <> 1 then
    raise exception 'FAIL [K1] block_player_by_id: %(% function(s) by that name); expected part 1''s body, definer, search_path '''', authenticated only, one function.', v_txt, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [K2] Unchanged bodies.
  v_bad := '';
  for v_rec in
    select * from (values
      ('public.block_player(text)', '10f6b07a3224aff16e1326daa6af5759', 'c742c78f77f58a92e6f38753c84b9f16'),
      ('public.unblock_player(uuid)', 'c0363d27028d621c0008654506bade75', '279ac52fde07f39491f747656943d84f'),
      ('public.get_my_blocks()', '3d50e2a273ca16b23f6d89348016d8de', '687616ef777e677d23b58678e3e3fd1e'),
      ('public._is_blocked_from_table(uuid, uuid)', '162f914c3b209186c819c66d18a23a99', '69b02ade7e62cad1ff49c44ae302b805'),
      ('public.join_table_by_code(text, boolean, uuid)', 'cf40593ee5afda235144a13e38d27f4a', 'c3ee9ced2e1033f9c068acd3325c5583'),
      ('public.watch_table(text, uuid)', '5bf6065de215d92a02af63d035c7f910', '2aa5f9c37d65271f3b4619e58c171ea0'),
      ('public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa'),
      ('public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c'),
      ('public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb'),
      ('public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d'),
      ('public._attempts_guard(uuid, text, integer, interval, text)', 'b1b69dbbdf10d50f78655a0da3b3ac69', '9406938991e89dcd38d0686a279b432a'),
      ('public.spectator_heartbeat(uuid)', '41d2ea0e865c2a9d5fa7203875a27ace', '6b7c271d78eb4f72c1aff3c851b578e1'),
      ('public.remove_spectator(uuid, uuid)', 'dafa688f1b8c194e4be575cd0625ba12', '9786b9a5e50245365a2598b18da5892e'),
      ('public.chat_topic_allows(text, boolean)', '0458d5122d68d511b2e0fbceafe84aae', 'c4e6eda360de7d7723c4069e60d95345')
    ) as t(fn, lf, crlf)
  loop
    select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    -- join_table_by_code / watch_table may also be moderation M3 part 2's
    -- bodies (M1's plus the kick refusal).
    if v_txt is null
       or (v_txt not in (v_rec.lf, v_rec.crlf)
           and not (v_rec.fn = 'public.join_table_by_code(text, boolean, uuid)' and v_txt in ('297fa4f04a02e226691ebf3b5b135f83', 'fbf046f1582863cc5697b06f670481b2'))
           and not (v_rec.fn = 'public.watch_table(text, uuid)' and v_txt in ('bdebb2e1a8213baa2a04666bcad59adb', 'ea5c3bd739b2f7243b985c7ea1fd9f2a'))) then
      v_bad := v_bad || v_rec.fn || ' md5 ' || coalesce(v_txt, 'missing') || ' (want ' || v_rec.crlf || ' / ' || v_rec.lf || '); ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [K2] changed bodies: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K3] Who may execute what (membership, not the count).
  if not has_function_privilege('authenticated', 'public.block_player_by_id(uuid)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.block_player(text)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.unblock_player(uuid)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.get_my_blocks()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public._is_blocked_from_table(uuid, uuid)', 'EXECUTE') then
    raise exception 'FAIL [K3] authenticated must execute block_player_by_id, block_player, unblock_player, get_my_blocks, and must not execute _is_blocked_from_table.';
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner =========================================================
  for v_i in 1..101 loop
    v_targets := v_targets || gen_random_uuid();
  end loop;
  v_people := array[v_a, v_b, v_nb, v_e, v_f, v_x] || v_targets;
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'm2-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      -- N has a BLANK nickname; X gets no profile at all (deleted after
      -- any signup trigger made one).
      if v_pid = v_x then
        continue;
      end if;
      insert into public.profiles (id, nickname)
      values (v_pid, case when v_pid = v_nb then '' else 'm2' || left(replace(v_pid::text, '-', ''), 12) end)
      on conflict (id) do update set nickname = excluded.nickname;
    end loop;
    delete from public.profiles where id = v_x;
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts and profiles: % (%).', sqlerrm, sqlstate;
  end;

  select ca.user_id into v_comp from public.computer_accounts ca where ca.level = 'easy';
  if v_comp is null then
    raise exception 'SETUP: no easy computer account (computer-accounts-setup.sql).';
  end if;

  select c into v_code from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    -- A code no OPEN table holds -- every table while tables_code_open_key
    -- doesn't exist (the predicate the other suites use).
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                        and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null))
    order by n
    limit 1
  ) free_code;
  if v_code is null then
    raise exception 'SETUP: no free table code.';
  end if;
  begin
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_code, v_a, true, true, 3) returning id into v_ta;
    insert into public.table_members (table_id, user_id) values (v_ta, v_a);
  exception when others then
    raise exception 'SETUP: could not create the test table: % (%).', sqlerrm, sqlstate;
  end;

  -- ==== I: BLOCK BY ID ==============================================================
  -- [I1] A blocks B by id.
  v_r := pg_temp.m2_as('authenticated', v_a, format('select public.block_player_by_id(%L)', v_b));
  select count(*) into v_n from public.attempt_log al where al.user_id = v_a and al.action = 'block_change';
  if v_r[1] is not null or v_r[5] is distinct from 'blocked' or v_n <> 1
     or not exists (select 1 from public.blocks b where b.blocker_id = v_a and b.blocked_id = v_b) then
    raise exception 'FAIL [I1] A blocking B by id: % (error %: %), % block_change row(s); expected blocked, the row, 1.', v_r[5], coalesce(v_r[1], 'none'), coalesce(v_r[2], ''), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [I2] Again: a no-op.
  v_r := pg_temp.m2_as('authenticated', v_a, format('select public.block_player_by_id(%L)', v_b));
  select count(*) into v_n from public.attempt_log al where al.user_id = v_a and al.action = 'block_change';
  if v_r[1] is not null or v_r[5] is distinct from 'already_blocked' or v_n <> 1
     or (select count(*) from public.blocks b where b.blocker_id = v_a) <> 1 then
    raise exception 'FAIL [I2] A blocking B by id again: % (error %), % row(s); expected already_blocked, 1, 1 block.', v_r[5], coalesce(v_r[1], 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [I3] not_found: unknown, no profile, null.
  v_txt := concat_ws(',',
    (pg_temp.m2_as('authenticated', v_a, format('select public.block_player_by_id(%L)', gen_random_uuid())))[5],
    (pg_temp.m2_as('authenticated', v_a, format('select public.block_player_by_id(%L)', v_x)))[5],
    (pg_temp.m2_as('authenticated', v_a, 'select public.block_player_by_id(null)'))[5]);
  select count(*) into v_n from public.attempt_log al where al.user_id = v_a and al.action = 'block_change';
  if v_txt is distinct from 'not_found,not_found,not_found' or v_n <> 1
     or (select count(*) from public.blocks b where b.blocker_id = v_a) <> 1 then
    raise exception 'FAIL [I3] unknown id / no-profile account / null: %, % row(s); expected not_found x3 and 1.', v_txt, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [I4] not_allowed: yourself, a computer target, a computer caller.
  v_txt := concat_ws(',',
    (pg_temp.m2_as('authenticated', v_a, format('select public.block_player_by_id(%L)', v_a)))[5],
    (pg_temp.m2_as('authenticated', v_a, format('select public.block_player_by_id(%L)', v_comp)))[5],
    (pg_temp.m2_as('authenticated', v_comp, format('select public.block_player_by_id(%L)', v_b)))[5]);
  select count(*) into v_n from public.attempt_log al where al.user_id in (v_a, v_comp) and al.action = 'block_change';
  if v_txt is distinct from 'not_allowed,not_allowed,not_allowed' or v_n <> 1
     or exists (select 1 from public.blocks b where b.blocker_id = v_comp or b.blocked_id in (v_a, v_comp)) then
    raise exception 'FAIL [I4] self / computer target / computer caller: %, % row(s); expected not_allowed x3, 1, no rows.', v_txt, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [I5] A blank-nickname target is blockable.
  v_r := pg_temp.m2_as('authenticated', v_a, format('select public.block_player_by_id(%L)', v_nb));
  v_r2 := pg_temp.m2_as('authenticated', v_a, format('select count(*)::text from public.get_my_blocks() g where g.user_id = %L', v_nb));
  if v_r[1] is not null or v_r[5] is distinct from 'blocked' or v_r2[5] is distinct from '1'
     or not exists (select 1 from public.blocks b where b.blocker_id = v_a and b.blocked_id = v_nb) then
    raise exception 'FAIL [I5] A blocking N (blank nickname): % (error %: %), listed % time(s); expected blocked and listed once.', v_r[5], coalesce(v_r[1], 'none'), coalesce(v_r[2], ''), v_r2[5];
  end if;
  v_checks := v_checks + 1;

  -- [I6] The cap of 100.
  insert into public.blocks (blocker_id, blocked_id)
  select v_e, v_targets[i] from generate_series(1, 100) as i;
  v_txt := concat_ws(',',
    (pg_temp.m2_as('authenticated', v_e, format('select public.block_player_by_id(%L)', v_targets[101])))[5],
    (pg_temp.m2_as('authenticated', v_e, format('select public.block_player_by_id(%L)', v_targets[1])))[5]);
  select count(*) into v_n from public.attempt_log al where al.user_id = v_e and al.action = 'block_change';
  if v_txt is distinct from 'limit,already_blocked' or v_n <> 0
     or (select count(*) from public.blocks b where b.blocker_id = v_e) <> 100 then
    raise exception 'FAIL [I6] E at 100: %, % row(s); expected limit,already_blocked, 0, still 100.', v_txt, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [I7] 30 real changes an hour, shared with block_player.
  v_bad := '';
  for v_i in 1..15 loop
    v_r := pg_temp.m2_as('authenticated', v_f, format('select public.block_player_by_id(%L)', v_targets[v_i]));
    if v_r[5] is distinct from 'blocked' then
      v_bad := v_bad || 'block ' || v_i || ': ' || coalesce(v_r[5], v_r[2]) || '; ';
    end if;
  end loop;
  for v_i in 1..15 loop
    v_r := pg_temp.m2_as('authenticated', v_f, format('select public.unblock_player(%L)', v_targets[v_i]));
    if v_r[5] is distinct from 'unblocked' then
      v_bad := v_bad || 'unblock ' || v_i || ': ' || coalesce(v_r[5], v_r[2]) || '; ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [I7] F''s first 30 changes: %expected all allowed.', v_bad;
  end if;
  v_r := pg_temp.m2_as('authenticated', v_f, format('select public.block_player_by_id(%L)', v_targets[16]));
  v_r2 := pg_temp.m2_as('authenticated', v_f, format('select public.block_player(%L)', 'm2' || left(replace(v_targets[17]::text, '-', ''), 12)));
  select count(*) into v_n from public.attempt_log al where al.user_id = v_f and al.action = 'block_change';
  if v_r[1] is distinct from 'P0001' or v_r[3] is distinct from 'rate_limited' or v_r[2] is distinct from v_limit_msg
     or v_r2[1] is distinct from 'P0001' or v_r2[3] is distinct from 'rate_limited'
     or v_n <> 30 or exists (select 1 from public.blocks b where b.blocker_id = v_f) then
    raise exception 'FAIL [I7] F''s 31st change: by id % / % / "%", by nickname % / %; % row(s). Expected P0001 / rate_limited / "%" both ways, 30 rows, no blocks.',
      coalesce(v_r[1], 'no error'), coalesce(v_r[3], '-'), coalesce(v_r[2], v_r[5], ''), coalesce(v_r2[1], 'no error'), coalesce(v_r2[3], '-'), v_n, v_limit_msg;
  end if;
  update public.attempt_log set created_at = created_at - interval '61 minutes' where user_id = v_f;
  v_r := pg_temp.m2_as('authenticated', v_f, format('select public.block_player_by_id(%L)', v_targets[16]));
  if v_r[1] is not null or v_r[5] is distinct from 'blocked' then
    raise exception 'FAIL [I7] F''s block by id after the hour: % (error %: %); expected blocked.', v_r[5], coalesce(v_r[1], 'none'), coalesce(v_r[2], '');
  end if;
  v_checks := v_checks + 1;

  -- [I8] unblock_player undoes a block by id.
  v_r := pg_temp.m2_as('authenticated', v_a, format('select public.unblock_player(%L)', v_b));
  select count(*) into v_n from public.attempt_log al where al.user_id = v_a and al.action = 'block_change';
  if v_r[1] is not null or v_r[5] is distinct from 'unblocked' or v_n <> 3
     or exists (select 1 from public.blocks b where b.blocker_id = v_a and b.blocked_id = v_b) then
    raise exception 'FAIL [I8] A unblocking B: % (error %: %), % block_change row(s); expected unblocked, the row gone, 3.', v_r[5], coalesce(v_r[1], 'none'), coalesce(v_r[2], ''), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [I9] Blocked by id, B cannot join A's table (code, id, preview).
  v_r := pg_temp.m2_as('authenticated', v_a, format('select public.block_player_by_id(%L)', v_b));
  if v_r[5] is distinct from 'blocked' then
    raise exception 'SETUP [I9] A re-blocking B by id answered % (error %: %).', v_r[5], coalesce(v_r[1], 'none'), coalesce(v_r[2], '');
  end if;
  v_bad := '';
  for v_txt in
    select unnest(array[
      format('select outcome from public.join_table_by_code(%L)', v_code),
      format('select outcome from public.join_table_by_code(%L, false, %L)', v_code, v_ta),
      format('select host_nickname from public.join_table_by_code(%L, true)', v_code),
      format('select host_nickname from public.join_table_by_code(%L, true, %L)', v_code, v_ta)])
  loop
    v_r := pg_temp.m2_as('authenticated', v_b, v_txt);
    if v_r[1] is distinct from 'P0001' or v_r[2] is distinct from v_refusal
       or v_r[3] is distinct from '' or v_r[4] is distinct from '' or v_r[5] is not null then
      v_bad := v_bad || '[' || v_txt || '] ' || coalesce(v_r[1], 'no error') || ' / "' || coalesce(v_r[2], v_r[5], '') || '"; ';
    end if;
  end loop;
  if v_bad <> '' or exists (select 1 from public.table_members tm where tm.user_id = v_b) then
    raise exception 'FAIL [I9] B joining or previewing TA after a block by id: %expected P0001 / "%" / no detail / no hint each, and no seat.', v_bad, v_refusal;
  end if;
  v_checks := v_checks + 1;

  -- [I10] ... nor watch it (code, id).
  v_r := pg_temp.m2_as('authenticated', v_b, format('select table_id::text from public.watch_table(%L)', v_code));
  v_r2 := pg_temp.m2_as('authenticated', v_b, format('select table_id::text from public.watch_table(%L, %L)', v_code, v_ta));
  if v_r[1] is distinct from 'P0001' or v_r[2] is distinct from v_refusal or v_r[3] is distinct from '' or v_r[4] is distinct from ''
     or v_r2[1] is distinct from 'P0001' or v_r2[2] is distinct from v_refusal or v_r2[3] is distinct from '' or v_r2[4] is distinct from ''
     or exists (select 1 from public.table_spectators ts where ts.user_id = v_b) then
    raise exception 'FAIL [I10] B watching TA after a block by id: by code % / "%", by id % / "%"; expected P0001 / "%" twice, no spectator row.', coalesce(v_r[1], 'no error'), coalesce(v_r[2], v_r[5], ''), coalesce(v_r2[1], 'no error'), coalesce(v_r2[2], v_r2[5], ''), v_refusal;
  end if;
  v_checks := v_checks + 1;

  -- [I11] Nothing counted for B by I9-I10.
  select count(*), string_agg(distinct al.action, ', ')
  into v_n, v_txt
  from public.attempt_log al
  where al.user_id = v_b
    and al.action in ('join', 'watch', 'code_guess', 'create_table', 'create_computer_table');
  if v_n <> 0 then
    raise exception 'FAIL [I11] B has % attempt_log row(s) after I9-I10 (actions: %); expected 0.', v_n, v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [I12] Nobody logged in.
  v_r := pg_temp.m2_as('authenticated', null, format('select public.block_player_by_id(%L)', v_b));
  if v_r[2] is distinct from 'You must be logged in to block a player.' then
    raise exception 'FAIL [I12] not logged in: % / "%"; expected "You must be logged in to block a player.".', coalesce(v_r[1], 'no error'), coalesce(v_r[2], v_r[5], '');
  end if;
  v_checks := v_checks + 1;

  -- [I13] The target learns nothing.
  v_r := pg_temp.m2_as('authenticated', v_b, 'select count(*)::text from public.get_my_blocks()');
  v_r2 := pg_temp.m2_as('authenticated', v_b, 'select count(*)::text from public.blocks');
  if v_r[5] is distinct from '0' or v_r2[1] is distinct from '42501' then
    raise exception 'FAIL [I13] B''s get_my_blocks: % row(s) (error %); B reading blocks: %. Expected 0 and 42501.', coalesce(v_r[5], '-'), coalesce(v_r[1], 'none'), coalesce(v_r2[1], 'allowed');
  end if;
  v_checks := v_checks + 1;

  -- [I14] Only the caller's own list.
  v_r := pg_temp.m2_as('authenticated', v_b, format('select public.block_player_by_id(%L)', v_a));
  if v_r[5] is distinct from 'blocked'
     or (select string_agg(b.blocked_id::text, ',' order by b.blocked_id) from public.blocks b where b.blocker_id = v_a)
        is distinct from (select string_agg(u::text, ',' order by u) from unnest(array[v_b, v_nb]) u)
     or (select string_agg(b.blocked_id::text, ',') from public.blocks b where b.blocker_id = v_b) is distinct from v_a::text then
    raise exception 'FAIL [I14] B blocking A by id: % (error %); expected blocked, A''s list still B and N, B''s list exactly A.', coalesce(v_r[5], '-'), coalesce(v_r[2], 'none');
  end if;
  v_checks := v_checks + 1;

  if v_checks <> 17 then
    raise exception 'FAIL: % checks ran, expected 17.', v_checks;
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back).', v_checks;
end;
$$;
