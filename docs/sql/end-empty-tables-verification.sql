-- Step 3, slice C: VERIFICATION of docs/sql/end-empty-tables.sql.
--
-- Run in the Supabase Dashboard -> SQL Editor after end-empty-tables.sql.
-- The whole file is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- It WRITES -- thirteen temporary accounts in auth.users and their profiles,
-- test tables, seats, games, spectator rows, three computer tables, and it
-- DELETES one of its own temporary accounts (the cascade check) -- and then
-- deliberately raises an exception at the very end, which rolls EVERY write
-- back. A check that fails raises its own exception at once, which rolls
-- everything back the same way. It always "fails": the message is the
-- verdict (the dashboard hides notices).
--   "ALL n CHECKS PASSED (rolled back). ..." is a pass: n is 24, or 23 where
--   pg_cron isn't installed (C5 skipped, and the verdict says so).
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives. It also calls
-- end_empty_tables() (W checks): inside this transaction it may end real
-- legacy empty tables too -- rolled back with everything else.
-- Same impersonation as the other suites: request.jwt.claims plus "set
-- local role authenticated", and "reset role" to act as the owner. now() is
-- frozen inside a DO block, so the sweep's 10-minute grace is crossed by
-- moving tables.created_at back as the owner.
-- The two RACES (two leaves at once; a join racing the last leave) need two
-- sessions: docs/sql/end-empty-tables-manual-race-test.md.
--
-- PEOPLE (temporary accounts): A, B (the 2-player table T2), C, D, E (the
-- 3-player table T3, C its creator), S (a spectator of T2), H (joins: refused
-- at the ended T2, seated at the open T5), F (alone at T4, created by X; F's
-- account is deleted), X (T4's creator, never seated), K (leave_computer_table),
-- M (the quiet close), N (the plain leave_table on a computer table), P
-- (creator of the sweep's tables and T5, seated at T5 and W3).
--
-- WHAT IT CHECKS
--   CATALOG
--   C1  tables_ended_reason_check allows NULL, admin, timeout and empty (and
--       nothing else: 'bogus' is refused, 23514).
--   C2  the two triggers exist, are enabled, and fire as designed:
--       table_members_end_when_empty AFTER DELETE FOR EACH ROW ->
--       end_table_when_empty(); table_members_require_open BEFORE INSERT FOR
--       EACH ROW -> require_open_table(), sorting after
--       table_members_assign_seat.
--   C3  end_table_when_empty, require_open_table and end_empty_tables:
--       security definer, search_path '', EXECUTE for nobody (no PUBLIC grant,
--       not anon, authenticated or service_role); end_empty_tables returns
--       integer.
--   C4  the four fingerprinted bodies are unchanged (md5 of the live body is
--       the committed text, LF or CRLF): leave_table, end_timed_out_sessions,
--       assign_table_seat, table_host.
--   C5  the pg_cron job end-empty-tables exists, '*/5 * * * *', calling
--       end_empty_tables() (skipped where pg_cron isn't installed).
--   C6  no public function with "chat" in its name but chat_topic_allows.
--   LEAVING (the "end when empty" trigger)
--   L1  T2 (A, B, a live game): B leaves -- the game ends player_left (the
--       first leaver ends it, as leave_table always did); T2 stays open.
--   L2  A, the last, leaves: T2 is ended, ended_reason 'empty'.
--   L3  S's spectator row at T2 is KEPT, and S's heartbeat answers
--       table_ended.
--   L4  T3 (C, D, E; C created it): C leaves -- T3 stays open, and the host
--       (table_host) is now D, the lowest seat left.
--   L5  D leaves: open; E, the last, leaves: ended 'empty'.
--   L6  H's join_table_by_code with T2's code: outcome not_found (the lookup
--       never sees an ended table), H not seated.
--   L7  the owner's insert of a seat at T2 (ended): refused, "This table has
--       ended." (the "table must be open" trigger).
--   L8  H's join_table_by_code at T5 (open, one of two seats free): joined,
--       seat 2 -- the new trigger lets a normal join through.
--   L9  T4 (F alone, created by X): deleting F's account (the cascade
--       deletes the seat) ends T4 as 'empty'.
--   COMPUTER TABLES (the trigger ignores them)
--   L10 K's computer game, then leave_computer_table: the table ends with
--       ended_reason NULL (unchanged), no seat left.
--   L11 M's computer game, then M starts a table (create_table): the quiet
--       close ends the computer table with ended_reason NULL (unchanged), and
--       M's new table exists, M seated.
--   L12 N's computer game, then a plain leave_table on it (the odd path): the
--       table stays OPEN, the computer still seated (the trigger ignored it).
--   L13 ...and once it is 11 minutes old, end_empty_tables() ends it as
--       'empty'.
--   THE SWEEP (end_empty_tables)
--   W1  an empty human table, 11 minutes old, with a live game: ended
--       'empty', its game ended player_left.
--   W2  an empty human table, 9 minutes old: still open.
--   W3  a table with P seated, 11 minutes old: untouched (open).
--   W4  a spectator-only table (no seat, one spectator row), 11 minutes old:
--       ended 'empty', the spectator row kept.
--   W5  afterwards no open table with no human seat older than 10 minutes is
--       left anywhere (the legacy count is 0).

do $$
declare
  v_checks int := 0;
  v_cron text;
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid();
  v_e uuid := gen_random_uuid();
  v_s uuid := gen_random_uuid();
  v_h uuid := gen_random_uuid();
  v_f uuid := gen_random_uuid();
  v_x uuid := gen_random_uuid();
  v_k uuid := gen_random_uuid();
  v_m uuid := gen_random_uuid();
  v_nn uuid := gen_random_uuid();
  v_p uuid := gen_random_uuid();
  v_people uuid[];
  v_pid uuid;
  v_codes text[];
  v_free text;
  v_t2 uuid; v_t3 uuid; v_t4 uuid; v_t5 uuid;
  v_w1 uuid; v_w2 uuid; v_w3 uuid; v_w4 uuid;
  v_g2 uuid; v_gw1 uuid;
  v_ct uuid;
  v_tid uuid;
  v_j record;
  v_rec record;
  v_msg text; v_state text; v_txt text;
  v_n int;
  v_comp uuid;
begin
  -- ==== CATALOG ===================================================================
  if to_regprocedure('public.end_empty_tables()') is null
     or to_regprocedure('public.end_table_when_empty()') is null
     or to_regprocedure('public.require_open_table()') is null then
    raise exception 'SETUP: end-empty-tables.sql has not run (end_empty_tables, end_table_when_empty or require_open_table missing).';
  end if;

  -- [C1] The constraint allows exactly NULL, admin, timeout, empty.
  select pg_get_constraintdef(con.oid) into v_txt
  from pg_constraint con
  where con.conrelid = 'public.tables'::regclass and con.conname = 'tables_ended_reason_check';
  if v_txt is null or v_txt not ilike '%''admin''%' or v_txt not ilike '%''timeout''%' or v_txt not ilike '%''empty''%' then
    raise exception 'FAIL [C1] tables_ended_reason_check is "%"; expected admin, timeout and empty.', coalesce(v_txt, 'missing');
  end if;
  v_checks := v_checks + 1;
  -- (its refusal of anything else is checked once a table exists, below)

  -- [C2] The two triggers.
  for v_rec in
    select * from (values
      ('table_members_end_when_empty', 'public.end_table_when_empty()', 'AFTER DELETE ROW'),
      ('table_members_require_open', 'public.require_open_table()', 'BEFORE INSERT ROW')
    ) as t(name, fn, kind)
  loop
    select case when (tg.tgtype & 2) = 2 then 'BEFORE' else 'AFTER' end
           || case when (tg.tgtype & 4) = 4 then ' INSERT' else '' end
           || case when (tg.tgtype & 8) = 8 then ' DELETE' else '' end
           || case when (tg.tgtype & 16) = 16 then ' UPDATE' else '' end
           || case when (tg.tgtype & 1) = 1 then ' ROW' else ' STATEMENT' end
           || '|' || tg.tgfoid::regprocedure::text || '|' || tg.tgenabled
    into v_txt
    from pg_trigger tg
    where tg.tgrelid = 'public.table_members'::regclass and tg.tgname = v_rec.name and not tg.tgisinternal;
    if v_txt is distinct from v_rec.kind || '|' || replace(v_rec.fn, 'public.', '') || '|O'
       and v_txt is distinct from v_rec.kind || '|' || v_rec.fn || '|O' then
      raise exception 'FAIL [C2] trigger % is "%"; expected "%|%|O" (enabled).', v_rec.name, coalesce(v_txt, 'missing'), v_rec.kind, v_rec.fn;
    end if;
  end loop;
  if not ('table_members_require_open' > 'table_members_assign_seat')
     or not exists (select 1 from pg_trigger tg where tg.tgrelid = 'public.table_members'::regclass
                      and tg.tgname = 'table_members_assign_seat' and tg.tgenabled <> 'D') then
    raise exception 'FAIL [C2] table_members_require_open must fire after an enabled table_members_assign_seat.';
  end if;
  v_checks := v_checks + 1;

  -- [C3] The three functions: definer, empty path, nobody may execute them.
  for v_rec in
    select * from (values
      ('public.end_table_when_empty()', 'trigger'),
      ('public.require_open_table()', 'trigger'),
      ('public.end_empty_tables()', 'integer')
    ) as t(fn, rettype)
  loop
    select p.prosecdef::text || ' '
           || case when coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']
                   then 'empty-path' else 'path:' || coalesce(p.proconfig::text, 'none') end
           || ' ' || p.prorettype::regtype::text
    into v_txt
    from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = to_regprocedure(v_rec.fn) and a.grantee = 0;
    if v_txt is distinct from 'true empty-path ' || v_rec.rettype or v_n <> 0
       or has_function_privilege('authenticated', to_regprocedure(v_rec.fn), 'EXECUTE')
       or has_function_privilege('anon', to_regprocedure(v_rec.fn), 'EXECUTE')
       or (exists (select 1 from pg_roles r where r.rolname = 'service_role')
           and has_function_privilege('service_role', to_regprocedure(v_rec.fn), 'EXECUTE')) then
      raise exception 'FAIL [C3] % is "%" (PUBLIC grants: %); expected "true empty-path %", executable by no client role.', v_rec.fn, v_txt, v_n, v_rec.rettype;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- [C4] The four fingerprinted bodies, unchanged.
  for v_rec in
    select * from (values
      ('public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa'),
      ('public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c'),
      ('public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb'),
      ('public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d')
    ) as t(fn, lf, crlf)
  loop
    select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is null or v_txt not in (v_rec.lf, v_rec.crlf) then
      raise exception 'FAIL [C4] % has body md5 %; expected % (LF) or % (CRLF). Slice C must not change it.', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf, v_rec.crlf;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- [C5] The cron job (read through EXECUTE: this file parses without pg_cron).
  if to_regclass('cron.job') is null then
    v_cron := 'pg_cron not installed: C5 skipped';
  else
    execute 'select count(*) from cron.job where jobname = $1 and schedule = $2 and command ilike $3'
    into v_n
    using 'end-empty-tables', '*/5 * * * *', '%public.end_empty_tables()%';
    if v_n <> 1 then
      raise exception 'FAIL [C5] the pg_cron job end-empty-tables (*/5 * * * *, select public.end_empty_tables();) is missing or different (% matching).', v_n;
    end if;
    v_cron := 'pg_cron job checked';
    v_checks := v_checks + 1;
  end if;

  -- [C6] The chat suite's C4: no other "chat" function in public.
  select string_agg(p.proname::text, ', ') into v_txt
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows';
  if v_txt is not null then
    raise exception 'FAIL [C6] public functions with "chat" in the name: %.', v_txt;
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner =========================================================
  v_people := array[v_a, v_b, v_c, v_d, v_e, v_s, v_h, v_f, v_x, v_k, v_m, v_nn, v_p];
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'ee-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      insert into public.profiles (id, nickname)
      values (v_pid, 'ee' || left(replace(v_pid::text, '-', ''), 12))
      on conflict (id) do update set nickname = excluded.nickname;
    end loop;
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts and profiles: % (%).', sqlerrm, sqlstate;
  end;

  select ca.user_id into v_comp from public.computer_accounts ca where ca.level = 'easy';
  if v_comp is null then
    raise exception 'SETUP: no easy computer account (run computer-accounts-setup.sql first).';
  end if;

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0'))
    order by n
    limit 8
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 8 then
    raise exception 'SETUP: fewer than eight unused table codes.';
  end if;

  begin
    -- T2: A, B; allows spectators; a live game (dated an hour back, as the
    -- other suites do); S a current spectator.
    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[1], v_a, true, true) returning id into v_t2;
    insert into public.table_members (table_id, user_id) values (v_t2, v_a);
    insert into public.table_members (table_id, user_id) values (v_t2, v_b);
    insert into public.games (table_id, created_by, status, players, deal_cut, created_at)
    values (v_t2, v_a, 'cutting', array[v_a, v_b], '[[]]'::jsonb, now() - interval '1 hour') returning id into v_g2;
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at) values (v_t2, v_s, now(), now());

    -- T3: C, D, E (seats 1, 2, 3), created by C.
    insert into public.tables (code, created_by, is_public, max_players) values (v_codes[2], v_c, true, 3) returning id into v_t3;
    insert into public.table_members (table_id, user_id) values (v_t3, v_c);
    insert into public.table_members (table_id, user_id) values (v_t3, v_d);
    insert into public.table_members (table_id, user_id) values (v_t3, v_e);

    -- T4: F alone, created by X (so deleting F does not delete the table).
    insert into public.tables (code, created_by, is_public) values (v_codes[3], v_x, true) returning id into v_t4;
    insert into public.table_members (table_id, user_id) values (v_t4, v_f);

    -- T5: P seated, one seat free.
    insert into public.tables (code, created_by, is_public) values (v_codes[4], v_p, true) returning id into v_t5;
    insert into public.table_members (table_id, user_id) values (v_t5, v_p);

    -- The sweep's tables (P's), aged below.
    insert into public.tables (code, created_by, is_public) values (v_codes[5], v_p, true) returning id into v_w1;
    insert into public.games (table_id, created_by, status, players, deal_cut, created_at)
    values (v_w1, v_p, 'cutting', array[v_p], '[[]]'::jsonb, now() - interval '1 hour') returning id into v_gw1;
    insert into public.tables (code, created_by, is_public) values (v_codes[6], v_p, true) returning id into v_w2;
    insert into public.tables (code, created_by, is_public) values (v_codes[7], v_p, true) returning id into v_w3;
    insert into public.table_members (table_id, user_id) values (v_w3, v_p);
    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[8], v_p, true, true) returning id into v_w4;
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at) values (v_w4, v_s, now(), now());
    update public.tables set created_at = now() - interval '11 minutes' where id in (v_w1, v_w3, v_w4);
    update public.tables set created_at = now() - interval '9 minutes' where id = v_w2;
  exception when others then
    raise exception 'SETUP: could not create the test tables, seats, games and spectator rows: % (%).', sqlerrm, sqlstate;
  end;

  -- (C1, continued) anything but NULL, admin, timeout, empty is refused.
  v_state := null;
  begin
    update public.tables set status = 'ended', ended_reason = 'bogus' where id = v_w2;
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from '23514' then
    raise exception 'FAIL [C1] ended_reason ''bogus'': %; expected a check violation (23514).', coalesce(v_state, 'accepted');
  end if;

  -- ==== LEAVING ===================================================================
  -- [L1] B leaves T2: the game ends player_left; T2 stays open.
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform public.leave_table(v_t2);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null
     or (select g.status || '/' || coalesce(g.ended_reason, '') from public.games g where g.id = v_g2) is distinct from 'ended/player_left'
     or (select t.status from public.tables t where t.id = v_t2) is distinct from 'open'
     or exists (select 1 from public.table_members tm where tm.table_id = v_t2 and tm.user_id = v_b) then
    raise exception 'FAIL [L1] B leaving T2: error %, game %, table %; expected the game ended/player_left and T2 open.',
      coalesce(v_msg, 'none'),
      (select g.status || '/' || coalesce(g.ended_reason, '') from public.games g where g.id = v_g2),
      (select t.status from public.tables t where t.id = v_t2);
  end if;
  v_checks := v_checks + 1;

  -- [L2] A, the last, leaves: T2 ended 'empty'.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform public.leave_table(v_t2);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null
     or (select t.status || '/' || coalesce(t.ended_reason, '') from public.tables t where t.id = v_t2) is distinct from 'ended/empty'
     or exists (select 1 from public.table_members tm where tm.table_id = v_t2) then
    raise exception 'FAIL [L2] A, the last, leaving T2: error %, table %; expected ended/empty and no seat.',
      coalesce(v_msg, 'none'), (select t.status || '/' || coalesce(t.ended_reason, '') from public.tables t where t.id = v_t2);
  end if;
  v_checks := v_checks + 1;

  -- [L3] S's spectator row is kept; S's heartbeat: table_ended.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_txt := public.spectator_heartbeat(v_t2);
  execute 'reset role';
  if not exists (select 1 from public.table_spectators ts where ts.table_id = v_t2 and ts.user_id = v_s)
     or v_txt is distinct from 'table_ended' then
    raise exception 'FAIL [L3] S at the emptied T2: row kept %, heartbeat %; expected the row kept and table_ended.',
      exists (select 1 from public.table_spectators ts where ts.table_id = v_t2 and ts.user_id = v_s), v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [L4] C (the creator) leaves T3: open, and the host is now D (lowest seat).
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.leave_table(v_t3);
  execute 'reset role';
  if (select t.status from public.tables t where t.id = v_t3) is distinct from 'open'
     or public.table_host(v_t3) is distinct from v_d then
    raise exception 'FAIL [L4] after the creator C left T3: table %, host %; expected open and D (%).',
      (select t.status from public.tables t where t.id = v_t3), public.table_host(v_t3), v_d;
  end if;
  v_checks := v_checks + 1;

  -- [L5] D leaves: open; E, the last, leaves: ended 'empty'.
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.leave_table(v_t3);
  execute 'reset role';
  v_txt := (select t.status from public.tables t where t.id = v_t3);
  perform set_config('request.jwt.claims', json_build_object('sub', v_e, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.leave_table(v_t3);
  execute 'reset role';
  if v_txt is distinct from 'open'
     or (select t.status || '/' || coalesce(t.ended_reason, '') from public.tables t where t.id = v_t3) is distinct from 'ended/empty' then
    raise exception 'FAIL [L5] T3 after D left: %; after E (the last) left: %; expected open, then ended/empty.',
      v_txt, (select t.status || '/' || coalesce(t.ended_reason, '') from public.tables t where t.id = v_t3);
  end if;
  v_checks := v_checks + 1;

  -- [L6] H joins with T2's code: not_found, not seated.
  perform set_config('request.jwt.claims', json_build_object('sub', v_h, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_codes[1]) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [L6] H joining the ended T2 by its code raised: %; expected outcome not_found.', v_msg;
  end if;
  if v_j.outcome is distinct from 'not_found' or exists (select 1 from public.table_members tm where tm.table_id = v_t2) then
    raise exception 'FAIL [L6] H joining the ended T2 by its code: %; expected not_found and no seat.', v_j;
  end if;
  v_checks := v_checks + 1;

  -- [L7] The owner seating someone at the ended T2: refused.
  v_msg := null; v_state := null;
  begin
    insert into public.table_members (table_id, user_id) values (v_t2, v_h);
  exception when others then
    v_msg := sqlerrm; v_state := sqlstate;
  end;
  if v_msg is distinct from 'This table has ended.' or exists (select 1 from public.table_members tm where tm.table_id = v_t2) then
    raise exception 'FAIL [L7] a seat inserted at the ended T2: "%" (%); expected "This table has ended." and no seat.', coalesce(v_msg, 'inserted'), v_state;
  end if;
  v_checks := v_checks + 1;

  -- [L8] H joins T5 (open, a seat free): joined, seat 2.
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_codes[4]) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [L8] H joining the open T5 was refused: %.', v_msg;
  end if;
  if v_j.outcome is distinct from 'joined' or v_j.seat is distinct from 2::smallint then
    raise exception 'FAIL [L8] H joining the open T5: %; expected joined, seat 2.', v_j;
  end if;
  v_checks := v_checks + 1;

  -- [L9] F's account is deleted: the cascade deletes F's seat, T4 ends 'empty'.
  v_msg := null;
  begin
    delete from auth.users where id = v_f;
  exception when others then
    v_msg := sqlerrm || ' (' || sqlstate || ')';
  end;
  if v_msg is not null
     or exists (select 1 from public.table_members tm where tm.table_id = v_t4)
     or (select t.status || '/' || coalesce(t.ended_reason, '') from public.tables t where t.id = v_t4) is distinct from 'ended/empty' then
    raise exception 'FAIL [L9] deleting F''s account: error %, T4 %; expected the seat gone and T4 ended/empty.',
      coalesce(v_msg, 'none'), (select t.status || '/' || coalesce(t.ended_reason, '') from public.tables t where t.id = v_t4);
  end if;
  v_checks := v_checks + 1;

  -- ==== COMPUTER TABLES ===========================================================
  -- [L10] K: a computer game, then leave_computer_table -- reason NULL, no seat.
  select lpad(n::text, 4, '0') into v_free from generate_series(0, 9999) n
  where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')) order by n limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_k, 'role', 'authenticated')::text, true);
  v_msg := null; v_ct := null;
  execute 'set local role authenticated';
  begin
    select r.table_id into v_ct from public.create_computer_table('easy', v_free) r;
    perform public.leave_computer_table(v_ct);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_ct is null
     or (select t.status || '/' || coalesce(t.ended_reason, 'NULL') from public.tables t where t.id = v_ct) is distinct from 'ended/NULL'
     or exists (select 1 from public.table_members tm where tm.table_id = v_ct) then
    raise exception 'FAIL [L10] K''s leave_computer_table: error %, table %; expected ended/NULL and no seat.',
      coalesce(v_msg, 'none'), (select t.status || '/' || coalesce(t.ended_reason, 'NULL') from public.tables t where t.id = v_ct);
  end if;
  v_checks := v_checks + 1;

  -- [L11] M: a computer game, then create_table -- the quiet close, reason NULL.
  select lpad(n::text, 4, '0') into v_free from generate_series(0, 9999) n
  where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')) order by n limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_m, 'role', 'authenticated')::text, true);
  v_msg := null; v_ct := null; v_tid := null;
  execute 'set local role authenticated';
  begin
    select r.table_id into v_ct from public.create_computer_table('easy', v_free) r;
    select r.table_id into v_tid from public.create_table(true, false, 2, null, false) r;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_ct is null
     or (select t.status || '/' || coalesce(t.ended_reason, 'NULL') from public.tables t where t.id = v_ct) is distinct from 'ended/NULL'
     or exists (select 1 from public.table_members tm where tm.table_id = v_ct)
     or not exists (select 1 from public.table_members tm where tm.table_id = v_tid and tm.user_id = v_m and tm.seat = 1) then
    raise exception 'FAIL [L11] M''s quiet close: error %, computer table %; expected ended/NULL, no seat there, and M seated at the new table.',
      coalesce(v_msg, 'none'), (select t.status || '/' || coalesce(t.ended_reason, 'NULL') from public.tables t where t.id = v_ct);
  end if;
  v_checks := v_checks + 1;

  -- [L12] N: a computer game, then a plain leave_table on it (the odd path):
  -- still open, the computer still seated.
  select lpad(n::text, 4, '0') into v_free from generate_series(0, 9999) n
  where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')) order by n limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_nn, 'role', 'authenticated')::text, true);
  v_msg := null; v_ct := null;
  execute 'set local role authenticated';
  begin
    select r.table_id into v_ct from public.create_computer_table('easy', v_free) r;
    perform public.leave_table(v_ct);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_ct is null
     or (select t.status from public.tables t where t.id = v_ct) is distinct from 'open'
     or (select string_agg(tm.user_id::text, ',') from public.table_members tm where tm.table_id = v_ct) is distinct from v_comp::text then
    raise exception 'FAIL [L12] N''s plain leave_table on a computer table: error %, table %; expected still open with only the computer seated.',
      coalesce(v_msg, 'none'), (select t.status from public.tables t where t.id = v_ct);
  end if;
  v_checks := v_checks + 1;

  -- [L13] ...11 minutes later, the sweep ends it as 'empty'.
  update public.tables set created_at = now() - interval '11 minutes' where id = v_ct;
  perform public.end_empty_tables();
  if (select t.status || '/' || coalesce(t.ended_reason, '') from public.tables t where t.id = v_ct) is distinct from 'ended/empty' then
    raise exception 'FAIL [L13] the sweep on N''s abandoned computer table: %; expected ended/empty.',
      (select t.status || '/' || coalesce(t.ended_reason, '') from public.tables t where t.id = v_ct);
  end if;
  v_checks := v_checks + 1;

  -- ==== THE SWEEP ===================================================================
  -- (The sweep already ran in L13; it is run again here, as the job would.)
  perform public.end_empty_tables();

  -- [W1] Empty, 11 minutes old, a live game: ended 'empty', game player_left.
  if (select t.status || '/' || coalesce(t.ended_reason, '') from public.tables t where t.id = v_w1) is distinct from 'ended/empty'
     or (select g.status || '/' || coalesce(g.ended_reason, '') from public.games g where g.id = v_gw1) is distinct from 'ended/player_left' then
    raise exception 'FAIL [W1] the sweep on an empty 11-minute-old table with a live game: table %, game %; expected ended/empty and ended/player_left.',
      (select t.status || '/' || coalesce(t.ended_reason, '') from public.tables t where t.id = v_w1),
      (select g.status || '/' || coalesce(g.ended_reason, '') from public.games g where g.id = v_gw1);
  end if;
  v_checks := v_checks + 1;

  -- [W2] Empty, 9 minutes old: still open.
  if (select t.status from public.tables t where t.id = v_w2) is distinct from 'open' then
    raise exception 'FAIL [W2] the sweep ended an empty table only 9 minutes old.';
  end if;
  v_checks := v_checks + 1;

  -- [W3] P seated, 11 minutes old: untouched.
  if (select t.status from public.tables t where t.id = v_w3) is distinct from 'open'
     or not exists (select 1 from public.table_members tm where tm.table_id = v_w3 and tm.user_id = v_p) then
    raise exception 'FAIL [W3] the sweep touched a table with a player seated.';
  end if;
  v_checks := v_checks + 1;

  -- [W4] Spectator-only, 11 minutes old: ended 'empty', the row kept.
  if (select t.status || '/' || coalesce(t.ended_reason, '') from public.tables t where t.id = v_w4) is distinct from 'ended/empty'
     or not exists (select 1 from public.table_spectators ts where ts.table_id = v_w4 and ts.user_id = v_s) then
    raise exception 'FAIL [W4] the sweep on a spectator-only table: %, spectator row kept %; expected ended/empty and kept.',
      (select t.status || '/' || coalesce(t.ended_reason, '') from public.tables t where t.id = v_w4),
      exists (select 1 from public.table_spectators ts where ts.table_id = v_w4 and ts.user_id = v_s);
  end if;
  v_checks := v_checks + 1;

  -- [W5] No open table with no human seat older than 10 minutes is left.
  select count(*) into v_n
  from public.tables t
  where t.status = 'open'
    and t.created_at < now() - interval '10 minutes'
    and not exists (select 1 from public.table_members tm where tm.table_id = t.id
                      and not exists (select 1 from public.computer_accounts ca where ca.user_id = tm.user_id));
  if v_n <> 0 then
    raise exception 'FAIL [W5] % open table(s) with no human seat, older than 10 minutes, are left after the sweep.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back). %.', v_checks, v_cron;
end;
$$;
