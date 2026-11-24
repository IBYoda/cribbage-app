-- Step 3, slice B: VERIFICATION of docs/sql/free-codes-part1.sql and, once
-- it has run, docs/sql/free-codes-part2.sql.
--
-- Run in the Supabase Dashboard -> SQL Editor after part 1, and again after
-- part 2. The whole file is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- It WRITES -- fourteen temporary accounts in auth.users and their profiles,
-- test tables, seats, spectator rows, computer tables, attempt_log rows --
-- and then deliberately raises an exception at the very end, which rolls
-- EVERY write back. A check that fails raises its own exception at once,
-- which rolls everything back the same way. It always "fails": the message
-- is the verdict (the dashboard hides notices).
--   "ALL n CHECKS PASSED (rolled back). Part 2: ..." is a pass: n is 19 with
--   part 1 only, 27 once part 2 is in. A HALF-applied part 2 fails at P0.
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives. Same impersonation as the
-- other suites: request.jwt.claims plus "set local role authenticated", and
-- "reset role" to act as the owner. now() is frozen inside a DO block.
-- FREE CODES for the owner-made tables: codes no table holds -- while the old
-- unique key exists (before part 2), that means no table at all, ended ones
-- included; once part 2 is in, only no OPEN table (the same predicate every
-- older suite now uses).
--
-- PEOPLE (temporary accounts): A (host of T1, with an avatar), B (J1), C
-- (J2, has a computer game), D (J3/J4 at T2), E (J5), S (W1), V (W2-W4), Q
-- (W5, has a computer game and a spectator row), H (R1, seated at T4), G
-- (seated host of T2, T3, T5 and the ended TE), Z (E2, alone at TL), R (P4),
-- K (P7), M (P8).
--
-- WHAT IT CHECKS
--   CATALOG (part 1)
--   C1  tables.ended_at (timestamptz, nullable); the trigger
--       tables_set_ended_at BEFORE INSERT OR UPDATE FOR EACH ROW ->
--       set_table_ended_at(), enabled; the function invoker, search_path '',
--       executable by no client role; the index tables_ended_at_idx (ended
--       tables only).
--   C2  join_table_by_code(text, boolean, uuid): definer, volatile, search_path
--       ''; exactly "p_code text, p_preview boolean DEFAULT false, p_table_id
--       uuid DEFAULT NULL::uuid"; the slice A columns plus host_avatar_url at
--       the end; EXECUTE for authenticated only; the old (text, boolean) gone.
--   C3  watch_table(text, uuid): definer, volatile, search_path ''; exactly
--       "p_code text, p_table_id uuid DEFAULT NULL::uuid" -> TABLE(table_id
--       uuid, code text, game_id uuid); authenticated only; the old (text)
--       gone.
--   C4  _one_table_rule: still invoker, executable by no client role.
--   C5  the backfill: no ended table without ended_at, no open table with one.
--   C6  no public function with "chat" in its name but chat_topic_allows.
--   ENDED_AT
--   E1  ending a table stamps ended_at = now(); a later update of the ended
--       row keeps its stamp (an explicit older value survives an
--       ended_reason change); a table inserted already ended is stamped; an
--       open table has none.
--   E2  the last player leaving (slice C's trigger) stamps it too.
--   JOIN (backward compatibility, previews, ids)
--   J1  an OLD-STYLE call, join_table_by_code(code) with no other argument,
--       joins as before (B at T1: joined, seat 2).
--   J2  the PREVIEW (C at T1, before J1) changes nothing: outcome preview, no
--       seat, host_nickname and host_avatar_url are A's, seated_count 1; C not
--       seated, C's computer game still open, no join or wrong-code row.
--   J3  with the right p_table_id: joined (D at T2).
--   J4  with a WRONG p_table_id (T2's code, T1's id): not_found, D not seated,
--       and NOT counted as a wrong guess (run before J3).
--   J5  a bare code of an ENDED table: not_found, counted (one wrong guess).
--   WATCH
--   W1  an OLD-STYLE call, watch_table(code): S watches T3 (one row, T3's id).
--   W2  watch_table with an ended table's code: no row, no exception, counted.
--   W3  watch_table with T3's code and a WRONG p_table_id: no row, NOT counted.
--   W4  watch_table with the ended table's code AND its id (a spectator's
--       rewatch after the table closed): no row, NOT counted.
--   W5  the WATCH CONFIRM's preview (join_table_by_code with p_preview, by Q
--       at T3) changes nothing: Q's computer game still open, Q's spectator
--       row at T1 untouched, no attempt_log row for Q.
--   R1  the already_at_table HINT is "<code> <table id>" (H, seated at T4,
--       joining T5).
--   PART 2 (only once free-codes-part2.sql has run; skipped before, and the
--   verdict says so; HALF-applied fails at P0)
--   P1  tables_code_key gone; tables_code_open_key UNIQUE on code WHERE status
--       <> 'ended'; tables_code_idx present; _pick_table_code(integer) invoker,
--       search_path '', owner only; create_table / create_computer_table keep
--       their settings and grants.
--   P2  a REUSED code is allowed: TX1 (code X) ends, TX2 opens with code X.
--   P3  two OPEN tables with one code: refused (23505).
--   P4  a STALE id after reuse: join_table_by_code(X, false, TX1's id) is
--       not_found and not counted; the bare code previews TX2.
--   P5  the cooldown: 30 picks, none held by an open table and -- while at
--       least 1,000 codes are outside the cooldown -- none ended within 24
--       hours (else the fallback's rule, as P6).
--   P6  the fallback (_pick_table_code(100000) forces it): 10 picks, each free
--       and among the 20 least recently ended free codes.
--   P7  create_table (K) gets a code no other open table holds, outside the
--       cooldown while the pool allows.
--   P8  create_computer_table (M) IGNORES the client's code: given T1's code
--       (held by an open table) it still succeeds, with another code.

do $$
declare
  v_checks int := 0;
  v_part2 text;
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid();
  v_e uuid := gen_random_uuid();
  v_s uuid := gen_random_uuid();
  v_v uuid := gen_random_uuid();
  v_q uuid := gen_random_uuid();
  v_h uuid := gen_random_uuid();
  v_g uuid := gen_random_uuid();
  v_z uuid := gen_random_uuid();
  v_r uuid := gen_random_uuid();
  v_k uuid := gen_random_uuid();
  v_m uuid := gen_random_uuid();
  v_people uuid[];
  v_pid uuid;
  v_codes text[];
  v_free text;
  v_avatar text := 'https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/avatars/00000000-0000-0000-0000-000000000000/avatar.png';
  v_a_nick text;
  v_t1 uuid; v_t2 uuid; v_te uuid; v_tb uuid; v_t3 uuid; v_t4 uuid; v_t5 uuid; v_tl uuid;
  v_tx1 uuid; v_tx2 uuid;
  v_c_ct uuid; v_q_ct uuid;
  v_tid uuid;
  v_j record;
  v_rec record;
  v_msg text; v_state text; v_detail text; v_hint text; v_txt text; v_txt2 text;
  v_n int; v_n2 int;
  v_ts timestamptz;
  v_has_index boolean; v_key_gone boolean; v_has_pick boolean;
  v_pool int;
  v_i int;
begin
  -- ==== CATALOG ===================================================================
  if to_regprocedure('public.join_table_by_code(text, boolean, uuid)') is null
     or to_regprocedure('public.watch_table(text, uuid)') is null
     or to_regprocedure('public.set_table_ended_at()') is null then
    raise exception 'SETUP: free-codes-part1.sql has not run (join_table_by_code(text, boolean, uuid), watch_table(text, uuid) or set_table_ended_at missing).';
  end if;

  -- [C1] ended_at, its trigger, function and index.
  select format_type(a.atttypid, a.atttypmod) || ' ' || (not a.attnotnull)::text into v_txt
  from pg_attribute a
  where a.attrelid = 'public.tables'::regclass and a.attname = 'ended_at' and not a.attisdropped;
  select case when (tg.tgtype & 2) = 2 then 'BEFORE' else 'AFTER' end
         || case when (tg.tgtype & 4) = 4 then ' INSERT' else '' end
         || case when (tg.tgtype & 8) = 8 then ' DELETE' else '' end
         || case when (tg.tgtype & 16) = 16 then ' UPDATE' else '' end
         || case when (tg.tgtype & 1) = 1 then ' ROW' else ' STATEMENT' end
         || '|' || replace(tg.tgfoid::regprocedure::text, 'public.', '') || '|' || tg.tgenabled::text
  into v_txt2
  from pg_trigger tg
  where tg.tgrelid = 'public.tables'::regclass and tg.tgname::text = 'tables_set_ended_at' and not tg.tgisinternal;
  select count(*) into v_n
  from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where p.oid = to_regprocedure('public.set_table_ended_at()') and a.grantee = 0;
  if v_txt is distinct from 'timestamp with time zone true'
     or v_txt2 is distinct from 'BEFORE INSERT UPDATE ROW|set_table_ended_at()|O'
     or (select p.prosecdef from pg_proc p where p.oid = to_regprocedure('public.set_table_ended_at()'))
     or not (select coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path='''''] from pg_proc p where p.oid = to_regprocedure('public.set_table_ended_at()'))
     or v_n <> 0
     or has_function_privilege('authenticated', 'public.set_table_ended_at()', 'EXECUTE')
     or has_function_privilege('anon', 'public.set_table_ended_at()', 'EXECUTE')
     or not exists (select 1 from pg_indexes i where i.schemaname = 'public' and i.tablename = 'tables'
                      and i.indexname = 'tables_ended_at_idx' and i.indexdef ilike '%(ended_at)%' and i.indexdef ilike '%status = ''ended''%') then
    raise exception 'FAIL [C1] ended_at "%", trigger "%", PUBLIC grants %, or the index; expected "timestamp with time zone true", "BEFORE INSERT UPDATE ROW|set_table_ended_at()|O", invoker, empty path, owner only, tables_ended_at_idx.',
      coalesce(v_txt, 'missing'), coalesce(v_txt2, 'missing'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [C2] join_table_by_code(text, boolean, uuid).
  select p.prosecdef::text || ' ' || p.provolatile::text || ' '
         || case when coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path='''''] then 'empty-path'
                 else 'path:' || coalesce(p.proconfig::text, 'none') end,
         pg_get_function_arguments(p.oid) || ' -> ' || pg_get_function_result(p.oid)
  into v_txt, v_txt2
  from pg_proc p where p.oid = to_regprocedure('public.join_table_by_code(text, boolean, uuid)');
  select count(*) into v_n
  from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where p.oid = to_regprocedure('public.join_table_by_code(text, boolean, uuid)') and a.grantee = 0;
  if v_txt is distinct from 'true v empty-path'
     or v_txt2 is distinct from 'p_code text, p_preview boolean DEFAULT false, p_table_id uuid DEFAULT NULL::uuid -> TABLE(outcome text, table_id uuid, code text, status text, ended_reason text, is_public boolean, is_muggins boolean, allow_spectators boolean, created_by uuid, max_players smallint, team_mode text, computer_level text, seat smallint, seated_count integer, game_live boolean, game_id uuid, host_nickname text, host_avatar_url text)'
     or v_n <> 0
     or not has_function_privilege('authenticated', 'public.join_table_by_code(text, boolean, uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.join_table_by_code(text, boolean, uuid)', 'EXECUTE')
     or (exists (select 1 from pg_roles r where r.rolname = 'service_role')
         and has_function_privilege('service_role', 'public.join_table_by_code(text, boolean, uuid)', 'EXECUTE'))
     or to_regprocedure('public.join_table_by_code(text, boolean)') is not null then
    raise exception 'FAIL [C2] join_table_by_code is "%" with "%" (PUBLIC grants %), or the old (text, boolean) still exists.', v_txt, v_txt2, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [C3] watch_table(text, uuid).
  select p.prosecdef::text || ' ' || p.provolatile::text || ' '
         || case when coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path='''''] then 'empty-path'
                 else 'path:' || coalesce(p.proconfig::text, 'none') end,
         pg_get_function_arguments(p.oid) || ' -> ' || pg_get_function_result(p.oid)
  into v_txt, v_txt2
  from pg_proc p where p.oid = to_regprocedure('public.watch_table(text, uuid)');
  select count(*) into v_n
  from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where p.oid = to_regprocedure('public.watch_table(text, uuid)') and a.grantee = 0;
  if v_txt is distinct from 'true v empty-path'
     or v_txt2 is distinct from 'p_code text, p_table_id uuid DEFAULT NULL::uuid -> TABLE(table_id uuid, code text, game_id uuid)'
     or v_n <> 0
     or not has_function_privilege('authenticated', 'public.watch_table(text, uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.watch_table(text, uuid)', 'EXECUTE')
     or (exists (select 1 from pg_roles r where r.rolname = 'service_role')
         and has_function_privilege('service_role', 'public.watch_table(text, uuid)', 'EXECUTE'))
     or to_regprocedure('public.watch_table(text)') is not null then
    raise exception 'FAIL [C3] watch_table is "%" with "%" (PUBLIC grants %), or the old (text) still exists.', v_txt, v_txt2, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [C4] _one_table_rule: invoker, owner only.
  select count(*) into v_n
  from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where p.oid = to_regprocedure('public._one_table_rule(uuid, uuid, boolean)') and a.grantee = 0;
  if (select p.prosecdef from pg_proc p where p.oid = to_regprocedure('public._one_table_rule(uuid, uuid, boolean)')) is distinct from false
     or v_n <> 0
     or has_function_privilege('authenticated', 'public._one_table_rule(uuid, uuid, boolean)', 'EXECUTE')
     or has_function_privilege('anon', 'public._one_table_rule(uuid, uuid, boolean)', 'EXECUTE') then
    raise exception 'FAIL [C4] _one_table_rule is no longer invoker and owner-only (PUBLIC grants %).', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [C5] The backfill.
  select count(*) filter (where t.status = 'ended' and t.ended_at is null),
         count(*) filter (where t.status <> 'ended' and t.ended_at is not null)
  into v_n, v_n2
  from public.tables t;
  if v_n <> 0 or v_n2 <> 0 then
    raise exception 'FAIL [C5] % ended table(s) without ended_at, % open table(s) with one; expected 0 and 0.', v_n, v_n2;
  end if;
  v_checks := v_checks + 1;

  -- [C6] The chat suite's C4.
  select string_agg(p.proname::text, ', ') into v_txt
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows';
  if v_txt is not null then
    raise exception 'FAIL [C6] public functions with "chat" in the name: %.', v_txt;
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner =========================================================
  v_people := array[v_a, v_b, v_c, v_d, v_e, v_s, v_v, v_q, v_h, v_g, v_z, v_r, v_k, v_m];
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'fc-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      insert into public.profiles (id, nickname)
      values (v_pid, 'fc' || left(replace(v_pid::text, '-', ''), 12))
      on conflict (id) do update set nickname = excluded.nickname;
    end loop;
    update public.profiles set avatar_url = v_avatar where id = v_a;
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts and profiles: % (%).', sqlerrm, sqlstate;
  end;
  select p.nickname into v_a_nick from public.profiles p where p.id = v_a;

  if not exists (select 1 from public.computer_accounts ca where ca.level = 'easy') then
    raise exception 'SETUP: no easy computer account (run computer-accounts-setup.sql first).';
  end if;

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                        and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null))
    order by n
    limit 10
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 10 then
    raise exception 'SETUP: fewer than ten free table codes.';
  end if;

  begin
    -- T1: A (host, avatar), 2 seats, allows spectators.
    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[1], v_a, true, true) returning id into v_t1;
    insert into public.table_members (table_id, user_id) values (v_t1, v_a);
    -- T2: G, 2 seats.
    insert into public.tables (code, created_by, is_public) values (v_codes[2], v_g, true) returning id into v_t2;
    insert into public.table_members (table_id, user_id) values (v_t2, v_g);
    -- TE: G seated, then ENDED by the owner (as an admin's Force-End).
    insert into public.tables (code, created_by, is_public) values (v_codes[3], v_g, true) returning id into v_te;
    insert into public.table_members (table_id, user_id) values (v_te, v_g);
    update public.tables set status = 'ended', ended_reason = 'admin' where id = v_te;
    -- TB: inserted already ended.
    insert into public.tables (code, created_by, is_public, status, ended_reason) values (v_codes[4], v_g, true, 'ended', 'admin') returning id into v_tb;
    -- T3: G, 2 seats, allows spectators.
    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[5], v_g, true, true) returning id into v_t3;
    insert into public.table_members (table_id, user_id) values (v_t3, v_g);
    -- T4: H. T5: G, 2 seats.
    insert into public.tables (code, created_by, is_public) values (v_codes[6], v_h, true) returning id into v_t4;
    insert into public.table_members (table_id, user_id) values (v_t4, v_h);
    insert into public.tables (code, created_by, is_public) values (v_codes[7], v_g, true) returning id into v_t5;
    insert into public.table_members (table_id, user_id) values (v_t5, v_g);
    -- TL: Z alone.
    insert into public.tables (code, created_by, is_public) values (v_codes[8], v_z, true) returning id into v_tl;
    insert into public.table_members (table_id, user_id) values (v_tl, v_z);
    -- Q: a spectator row at T1 (the W5 preview must leave it alone).
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at) values (v_t1, v_q, now() - interval '30 seconds', now() - interval '30 seconds');
  exception when others then
    raise exception 'SETUP: could not create the test tables, seats and spectator rows: % (%).', sqlerrm, sqlstate;
  end;

  -- C and Q each start an easy computer game (through the real function).
  foreach v_pid in array array[v_c, v_q] loop
    select lpad(n::text, 4, '0') into v_free from generate_series(0, 9999) n
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                        and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null))
    order by n desc limit 1;
    perform set_config('request.jwt.claims', json_build_object('sub', v_pid, 'role', 'authenticated')::text, true);
    v_msg := null; v_tid := null;
    execute 'set local role authenticated';
    begin
      select r.table_id into v_tid from public.create_computer_table('easy', v_free) r;
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_msg is not null or v_tid is null then
      raise exception 'SETUP: % could not start a computer game: %.', v_pid, coalesce(v_msg, 'no table');
    end if;
    if v_pid = v_c then v_c_ct := v_tid; else v_q_ct := v_tid; end if;
  end loop;

  -- ==== ENDED_AT ======================================================================
  -- [E1] Stamped on end; kept on a later update; stamped on an ended insert; none while open.
  v_txt := (select (t.ended_at = now())::text from public.tables t where t.id = v_te);
  update public.tables set ended_at = now() - interval '1 hour' where id = v_te;
  update public.tables set ended_reason = 'timeout' where id = v_te;
  v_ts := (select t.ended_at from public.tables t where t.id = v_te);
  if v_txt is distinct from 'true'
     or v_ts is distinct from now() - interval '1 hour'
     or (select t.ended_at from public.tables t where t.id = v_tb) is distinct from now()
     or (select t.ended_at from public.tables t where t.id = v_t1) is not null then
    raise exception 'FAIL [E1] ended_at: stamped on end %, kept on update % (expected %), on an ended insert %, open table %.',
      v_txt, v_ts, now() - interval '1 hour',
      (select t.ended_at from public.tables t where t.id = v_tb), (select t.ended_at from public.tables t where t.id = v_t1);
  end if;
  update public.tables set ended_at = now() where id = v_te;  -- back to "just ended" for the checks below
  v_checks := v_checks + 1;

  -- [E2] The last player leaving stamps it too (slice C's trigger ends the table).
  perform set_config('request.jwt.claims', json_build_object('sub', v_z, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform public.leave_table(v_tl);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null
     or (select t.status || '/' || coalesce(t.ended_reason, '') || '/' || coalesce((t.ended_at = now())::text, 'null')
         from public.tables t where t.id = v_tl) is distinct from 'ended/empty/true' then
    raise exception 'FAIL [E2] the last leave: error %, table %; expected ended/empty/true (ended_at = now()).',
      coalesce(v_msg, 'none'),
      (select t.status || '/' || coalesce(t.ended_reason, '') || '/' || coalesce(t.ended_at::text, 'null') from public.tables t where t.id = v_tl);
  end if;
  v_checks := v_checks + 1;

  -- ==== JOIN ==========================================================================
  -- [J2] C previews T1 (named arguments): nothing changes.
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(p_code => v_codes[1], p_preview => true) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [J2] C''s preview of T1 raised: %.', v_msg;
  end if;
  if v_j.outcome is distinct from 'preview' or v_j.table_id is distinct from v_t1 or v_j.seat is not null
     or v_j.seated_count is distinct from 1 or v_j.host_nickname is distinct from v_a_nick
     or v_j.host_avatar_url is distinct from v_avatar
     or exists (select 1 from public.table_members tm where tm.table_id = v_t1 and tm.user_id = v_c)
     or (select t.status from public.tables t where t.id = v_c_ct) is distinct from 'open'
     or exists (select 1 from public.attempt_log al where al.user_id = v_c and al.action in ('join', 'code_guess')) then
    raise exception 'FAIL [J2] C''s preview of T1: got %; expected preview, no seat, seated_count 1, host % with the avatar, C''s computer game still open, nothing logged.', v_j, v_a_nick;
  end if;
  v_checks := v_checks + 1;

  -- [J1] B joins T1 with an OLD-STYLE call (the code only).
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_codes[1]) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [J1] B''s old-style join_table_by_code(code) raised: %.', v_msg;
  end if;
  if v_j.outcome is distinct from 'joined' or v_j.seat is distinct from 2::smallint or v_j.table_id is distinct from v_t1 then
    raise exception 'FAIL [J1] B''s old-style join: got %; expected joined, seat 2, T1.', v_j;
  end if;
  v_checks := v_checks + 1;

  -- [J4] D with T2's code but T1's id: not_found, not seated, NOT counted.
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_codes[2], false, v_t1) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [J4] D''s join with a wrong table id raised: %.', v_msg;
  end if;
  if v_j.outcome is distinct from 'not_found' or v_j.table_id is not null
     or exists (select 1 from public.table_members tm where tm.user_id = v_d)
     or exists (select 1 from public.attempt_log al where al.user_id = v_d and al.action = 'code_guess') then
    raise exception 'FAIL [J4] D''s join with T2''s code and T1''s id: got %; expected not_found, not seated, no wrong-code row.', v_j;
  end if;
  v_checks := v_checks + 1;

  -- [J3] D with T2's code and T2's id: joined.
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_codes[2], false, v_t2) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [J3] D''s join with the right table id raised: %.', v_msg;
  end if;
  if v_j.outcome is distinct from 'joined' or v_j.table_id is distinct from v_t2 or v_j.seat is distinct from 2::smallint then
    raise exception 'FAIL [J3] D''s join with T2''s id: got %; expected joined, T2, seat 2.', v_j;
  end if;
  v_checks := v_checks + 1;

  -- [J5] E with the ENDED table's code: not_found, counted.
  perform set_config('request.jwt.claims', json_build_object('sub', v_e, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_codes[3]) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [J5] E''s join with an ended table''s code raised: %.', v_msg;
  end if;
  if v_j.outcome is distinct from 'not_found'
     or (select count(*) from public.attempt_log al where al.user_id = v_e and al.action = 'code_guess' and not al.success) <> 1 then
    raise exception 'FAIL [J5] E''s join with an ended table''s code: got %; expected not_found and one wrong guess counted.', v_j;
  end if;
  v_checks := v_checks + 1;

  -- ==== WATCH =========================================================================
  -- [W1] S watches T3 with an OLD-STYLE call.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s, 'role', 'authenticated')::text, true);
  v_msg := null; v_tid := null;
  execute 'set local role authenticated';
  begin
    select w.table_id into v_tid from public.watch_table(v_codes[5]) w;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_tid is distinct from v_t3
     or not exists (select 1 from public.table_spectators ts where ts.table_id = v_t3 and ts.user_id = v_s) then
    raise exception 'FAIL [W1] S''s old-style watch_table(code): error %, table %; expected T3 and a spectator row.', coalesce(v_msg, 'none'), v_tid;
  end if;
  v_checks := v_checks + 1;

  -- [W2] V watches the ENDED table's code: no row, no exception, counted.
  perform set_config('request.jwt.claims', json_build_object('sub', v_v, 'role', 'authenticated')::text, true);
  v_msg := null; v_n := null;
  execute 'set local role authenticated';
  begin
    select count(*)::int into v_n from public.watch_table(v_codes[3]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_n is distinct from 0
     or (select count(*) from public.attempt_log al where al.user_id = v_v and al.action = 'code_guess' and not al.success) <> 1 then
    raise exception 'FAIL [W2] V watching an ended table''s code: error %, % row(s); expected no error, no row, one wrong guess counted.', coalesce(v_msg, 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [W3] V with T3's code and a WRONG id: no row, NOT counted.
  v_msg := null; v_n := null;
  execute 'set local role authenticated';
  begin
    select count(*)::int into v_n from public.watch_table(v_codes[5], v_t1);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_n is distinct from 0
     or (select count(*) from public.attempt_log al where al.user_id = v_v and al.action = 'code_guess') <> 1
     or exists (select 1 from public.table_spectators ts where ts.user_id = v_v) then
    raise exception 'FAIL [W3] V watching with a wrong table id: error %, % row(s); expected no row, no new wrong guess, no spectator row.', coalesce(v_msg, 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [W4] V with the ended table's code AND its id (a rewatch after it closed): no row, NOT counted.
  v_msg := null; v_n := null;
  execute 'set local role authenticated';
  begin
    select count(*)::int into v_n from public.watch_table(v_codes[3], v_te);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_n is distinct from 0
     or (select count(*) from public.attempt_log al where al.user_id = v_v and al.action = 'code_guess') <> 1 then
    raise exception 'FAIL [W4] V rewatching the closed table by its id: error %, % row(s); expected no row and no new wrong guess.', coalesce(v_msg, 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [W5] Q's watch-confirm preview of T3: nothing changes.
  select ts.last_seen_at into v_ts from public.table_spectators ts where ts.table_id = v_t1 and ts.user_id = v_q;
  perform set_config('request.jwt.claims', json_build_object('sub', v_q, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_codes[5], true) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [W5] Q''s watch preview raised: %.', v_msg;
  end if;
  if v_j.outcome is distinct from 'preview' or v_j.table_id is distinct from v_t3 or v_j.allow_spectators is distinct from true
     or (select t.status from public.tables t where t.id = v_q_ct) is distinct from 'open'
     or (select ts.last_seen_at from public.table_spectators ts where ts.table_id = v_t1 and ts.user_id = v_q) is distinct from v_ts
     or exists (select 1 from public.table_spectators ts where ts.table_id = v_t3 and ts.user_id = v_q)
     or exists (select 1 from public.attempt_log al where al.user_id = v_q and al.action <> 'create_computer_table') then
    raise exception 'FAIL [W5] Q''s watch preview of T3: got %; expected preview of T3 (spectators allowed), Q''s computer game open, Q''s place at T1 untouched, nothing new logged.', v_j;
  end if;
  v_checks := v_checks + 1;

  -- [R1] H (seated at T4) joins T5: the HINT is "<T4's code> <T4's id>".
  perform set_config('request.jwt.claims', json_build_object('sub', v_h, 'role', 'authenticated')::text, true);
  v_msg := null; v_detail := null; v_hint := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.join_table_by_code(v_codes[7]);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail, v_hint = pg_exception_hint;
  end;
  execute 'reset role';
  if v_detail is distinct from 'already_at_table' or v_hint is distinct from v_codes[6] || ' ' || v_t4::text
     or v_msg is distinct from format('You''re already at table %s. Rejoin it or leave it first.', v_codes[6]) then
    raise exception 'FAIL [R1] H''s refusal: "%" (%, hint %); expected the usual message, already_at_table, hint "% %".', coalesce(v_msg, 'joined'), v_detail, v_hint, v_codes[6], v_t4;
  end if;
  v_checks := v_checks + 1;

  -- ==== PART 2 (free-codes-part2.sql) =================================================
  -- [P0] Applied, half-applied or not yet?
  v_has_index := to_regclass('public.tables_code_open_key') is not null;
  v_key_gone := not exists (select 1 from pg_constraint con where con.conrelid = 'public.tables'::regclass and con.conname = 'tables_code_key');
  v_has_pick := to_regprocedure('public._pick_table_code(integer)') is not null;

  if not v_has_index and not v_key_gone and not v_has_pick then
    v_part2 := 'NOT applied yet (P checks skipped; codes are still unique forever)';
  elsif v_has_index and v_key_gone and v_has_pick then
    v_part2 := 'applied, P checks passed';

    -- [P1] Catalog.
    select pg_get_indexdef(i.indexrelid) into v_txt
    from pg_index i where i.indexrelid = 'public.tables_code_open_key'::regclass;
    select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = to_regprocedure('public._pick_table_code(integer)') and a.grantee = 0;
    if v_txt is null or v_txt not ilike 'CREATE UNIQUE INDEX%(code)%WHERE (status <> ''ended''::text)%'
       or to_regclass('public.tables_code_idx') is null
       or (select p.prosecdef::text || ' ' || pg_get_function_arguments(p.oid) || ' ' || p.prorettype::regtype::text
           from pg_proc p where p.oid = to_regprocedure('public._pick_table_code(integer)'))
          is distinct from 'false p_min_free integer DEFAULT 1000 text'
       or not (select coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path='''''] from pg_proc p where p.oid = to_regprocedure('public._pick_table_code(integer)'))
       or v_n <> 0
       or has_function_privilege('authenticated', 'public._pick_table_code(integer)', 'EXECUTE')
       or has_function_privilege('anon', 'public._pick_table_code(integer)', 'EXECUTE')
       or (select p.prosecdef from pg_proc p where p.oid = to_regprocedure('public.create_table(boolean, boolean, integer, text, boolean)')) is distinct from true
       or not has_function_privilege('authenticated', 'public.create_table(boolean, boolean, integer, text, boolean)', 'EXECUTE')
       or has_function_privilege('anon', 'public.create_table(boolean, boolean, integer, text, boolean)', 'EXECUTE')
       or (select p.prosecdef::text || ' ' || coalesce(p.proconfig::text, 'none') from pg_proc p
           where p.oid = to_regprocedure('public.create_computer_table(text, text)')) is distinct from 'true {search_path=public}'
       or not has_function_privilege('authenticated', 'public.create_computer_table(text, text)', 'EXECUTE')
       or has_function_privilege('anon', 'public.create_computer_table(text, text)', 'EXECUTE') then
      raise exception 'FAIL [P1] part 2''s catalog: index "%", tables_code_idx %, _pick_table_code (PUBLIC grants %), or the creates'' settings/grants changed.',
        coalesce(v_txt, 'missing'), to_regclass('public.tables_code_idx') is not null, v_n;
    end if;
    v_checks := v_checks + 1;

    -- [P2] A reused code: TX1 (code X) ends, TX2 opens with X.
    v_msg := null;
    begin
      insert into public.tables (code, created_by, is_public) values (v_codes[9], v_g, true) returning id into v_tx1;
      update public.tables set status = 'ended', ended_reason = 'admin' where id = v_tx1;
      insert into public.tables (code, created_by, is_public) values (v_codes[9], v_g, true) returning id into v_tx2;
    exception when others then
      v_msg := sqlerrm || ' (' || sqlstate || ')';
    end;
    if v_msg is not null or v_tx2 is null or v_tx2 = v_tx1 then
      raise exception 'FAIL [P2] reusing an ended table''s code: %; expected the new open table.', coalesce(v_msg, 'no table');
    end if;
    v_checks := v_checks + 1;

    -- [P3] Two OPEN tables with X: refused.
    v_state := null;
    begin
      insert into public.tables (code, created_by, is_public) values (v_codes[9], v_g, true);
    exception when others then
      v_state := sqlstate;
    end;
    if v_state is distinct from '23505' then
      raise exception 'FAIL [P3] a second open table with one code: %; expected 23505.', coalesce(v_state, 'accepted');
    end if;
    v_checks := v_checks + 1;

    -- [P4] R with X and TX1's (stale) id: not_found, not counted; the bare code previews TX2.
    perform set_config('request.jwt.claims', json_build_object('sub', v_r, 'role', 'authenticated')::text, true);
    v_msg := null;
    execute 'set local role authenticated';
    begin
      select j.* into v_j from public.join_table_by_code(v_codes[9], false, v_tx1) j;
      v_txt := v_j.outcome;
      select j.* into v_j from public.join_table_by_code(v_codes[9], true) j;
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_msg is not null or v_txt is distinct from 'not_found'
       or v_j.outcome is distinct from 'preview' or v_j.table_id is distinct from v_tx2
       or exists (select 1 from public.table_members tm where tm.user_id = v_r)
       or exists (select 1 from public.attempt_log al where al.user_id = v_r and al.action = 'code_guess') then
      raise exception 'FAIL [P4] a stale id after reuse: error %, stale-id outcome %, bare preview %; expected not_found (not counted), then a preview of TX2.', coalesce(v_msg, 'none'), v_txt, v_j;
    end if;
    v_checks := v_checks + 1;

    -- How many codes are free AND outside the cooldown right now (the picker's switch).
    select count(*)::int into v_pool
    from generate_series(0, 9999) n
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0') and t.status <> 'ended')
      and not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0') and t.status = 'ended'
                        and t.ended_at > now() - interval '24 hours');

    -- [P5] The cooldown: 30 picks.
    for v_i in 1 .. 30 loop
      v_txt := public._pick_table_code();
      if v_txt is null or v_txt !~ '^[0-9]{4}$'
         or exists (select 1 from public.tables t where t.code = v_txt and t.status <> 'ended') then
        raise exception 'FAIL [P5] pick % returned "%": missing, malformed, or held by an open table.', v_i, coalesce(v_txt, 'NULL');
      end if;
      if v_pool >= 1000 and exists (select 1 from public.tables t where t.code = v_txt and t.status = 'ended'
                                      and t.ended_at > now() - interval '24 hours') then
        raise exception 'FAIL [P5] pick % returned "%", which ended within 24 hours, with % codes outside the cooldown.', v_i, v_txt, v_pool;
      end if;
    end loop;
    -- The codes this run just ended (TE, TL, TX1's X is held by TX2) were never
    -- picked above while the pool allows: covered by the rule just checked.
    v_checks := v_checks + 1;

    -- [P6] The fallback: 10 picks, each free and among the 20 least recently ended.
    for v_i in 1 .. 10 loop
      v_txt := public._pick_table_code(100000);
      if v_txt is null or exists (select 1 from public.tables t where t.code = v_txt and t.status <> 'ended') then
        raise exception 'FAIL [P6] fallback pick % returned "%": missing or held by an open table.', v_i, coalesce(v_txt, 'NULL');
      end if;
      v_ts := (select max(t.ended_at) from public.tables t where t.code = v_txt and t.status = 'ended');
      if v_ts is not null then
        select count(*)::int into v_n
        from generate_series(0, 9999) n
        where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0') and t.status <> 'ended')
          and coalesce((select max(t.ended_at) from public.tables t where t.code = lpad(n::text, 4, '0') and t.status = 'ended'),
                       '-infinity'::timestamptz) < v_ts;
        if v_n >= 20 then
          raise exception 'FAIL [P6] fallback pick % ("%", last ended %) has % free codes ended less recently; expected fewer than 20.', v_i, v_txt, v_ts, v_n;
        end if;
      end if;
    end loop;
    v_checks := v_checks + 1;

    -- [P7] create_table (K): a code no other open table holds, outside the cooldown while the pool allows.
    perform set_config('request.jwt.claims', json_build_object('sub', v_k, 'role', 'authenticated')::text, true);
    v_msg := null; v_tid := null; v_txt := null;
    execute 'set local role authenticated';
    begin
      select r.table_id, r.code into v_tid, v_txt from public.create_table(true, false, 2, null, false) r;
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_msg is not null or v_tid is null
       or exists (select 1 from public.tables t where t.code = v_txt and t.status <> 'ended' and t.id <> v_tid)
       or (v_pool >= 1000 and exists (select 1 from public.tables t where t.code = v_txt and t.status = 'ended'
                                        and t.ended_at > now() - interval '24 hours')) then
      raise exception 'FAIL [P7] create_table: error %, code %; expected a code no other open table holds and (pool %) outside the cooldown.', coalesce(v_msg, 'none'), v_txt, v_pool;
    end if;
    v_checks := v_checks + 1;

    -- [P8] create_computer_table (M) ignores the client's code (T1's, held by an open table).
    perform set_config('request.jwt.claims', json_build_object('sub', v_m, 'role', 'authenticated')::text, true);
    v_msg := null; v_tid := null; v_txt := null;
    execute 'set local role authenticated';
    begin
      select r.table_id, r.code into v_tid, v_txt from public.create_computer_table('easy', v_codes[1]) r;
    exception when others then
      v_msg := sqlerrm || ' (' || sqlstate || ')';
    end;
    execute 'reset role';
    if v_msg is not null or v_tid is null or v_txt = v_codes[1]
       or not exists (select 1 from public.table_members tm where tm.table_id = v_tid and tm.user_id = v_m and tm.seat = 1) then
      raise exception 'FAIL [P8] create_computer_table with an open table''s code: error %, code %; expected success with a server-picked code other than %.', coalesce(v_msg, 'none'), v_txt, v_codes[1];
    end if;
    v_checks := v_checks + 1;
  else
    raise exception 'FAIL [P0] part 2 is half-applied: partial index %, tables_code_key gone %, _pick_table_code %.', v_has_index, v_key_gone, v_has_pick;
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back). Part 2: %.', v_checks, v_part2;
end;
$$;
