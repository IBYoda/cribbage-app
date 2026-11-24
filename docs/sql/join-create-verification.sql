-- Step 3, slice A: VERIFICATION of docs/sql/join-create.sql (and, once it
-- has run, docs/sql/join-create-lockdown.sql).
--
-- Run in the Supabase Dashboard -> SQL Editor after join-create.sql, and
-- again after the lockdown. The whole file is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- It WRITES -- twenty-six temporary accounts in auth.users, their profiles,
-- test tables, seats, spectator rows and attempt_log rows -- and then
-- deliberately raises an exception at the very end, which rolls EVERY write
-- back. A check that fails raises its own exception at once, which rolls
-- everything back the same way. It always "fails": the message is the
-- verdict (the dashboard hides notices).
--   "ALL n CHECKS PASSED (rolled back). Lockdown: ..." is a pass.
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives. It creates no functions,
-- tables or other schema objects. Same impersonation as the other suites:
-- request.jwt.claims plus "set local role authenticated" (or anon), and
-- "reset role" to act as the owner between steps. "now()" is frozen inside a
-- DO block, so a limit's window is crossed by moving attempt_log.created_at
-- back as the owner (as the other suites age last_seen_at).
--
-- PEOPLE (fresh accounts): A (creates a table: the host), B (joins it), C
-- (the create limit), D (wrong codes and the lockout), E (spread-out wrong
-- codes, the join limit), F (seated at an ENDED table), G (refused options,
-- then a 4-player Self-Scoring table), P (preview then join), S1..S4
-- (spectators), V (wrong code by watch, the watch limit), K (the computer
-- game limit), H (seated host of the owner-made tables), L (the lockdown),
-- M1..M10 (single-player games never block: each starts an easy computer
-- game through create_computer_table first; M2, M5, M6, M8, M9, M10 also
-- start a live game there with start_game_with_deal).
-- TABLES made by the owner first (free codes): W (open, 4 seats, allows
-- spectators, H seated: where S1..S4 watch), X (open, 4 seats, allows
-- spectators, H seated), Q (ended, F seated), J5, J6, J7, R6 (open, 2 seats,
-- H seated: one free seat each), Y (open, 2 seats, H seated; M6 is seated
-- there later, as the owner, after M6's computer game exists). Unknown codes and the computer games' codes
-- are picked just before use (create_table picks random free codes, so a
-- code chosen early might be taken by then).
--
-- WHAT IT CHECKS
--   CATALOG
--   C1  attempt_log: RLS on, no policies, no privilege at all for anon,
--       authenticated or service_role, nothing granted to PUBLIC, the
--       (user_id, action, created_at desc) index, not in Realtime; its
--       identity sequence: no privilege for anon or authenticated.
--   C2  create_table and join_table_by_code: security definer, volatile,
--       search_path '', EXECUTE for authenticated only; their exact
--       arguments and results.
--   C3  watch_table: definer, volatile, search_path '', authenticated only;
--       create_computer_table: definer, search_path public, authenticated
--       yes, anon no.
--   C4  the four helpers: not security definer; EXECUTE for nobody but the
--       owner (no PUBLIC, anon, authenticated, service_role).
--   C5  attempt_log can't be read or written as authenticated or as anon
--       (permission denied, 42501).
--   C6  no public function with "chat" in its name but chat_topic_allows.
--   CREATE
--   K1  A creates (public, regular, 2 seats, team_mode NULL, spectators):
--       one row back; the table has exactly those options (team_mode
--       'teams', the default), created_by A, open; A is SEATED in seat 1; the
--       code is 4 digits and no other table has it; one create_table row.
--   K2  G's refused options (5 seats; 4-player Self-Scoring as Teams; an
--       unknown team mode): each its own message; no table, no log row.
--   K3  G: 4-player Self-Scoring Solo is created (the constraint's case).
--   K4  C with 10 creates in the last hour: refused ("You can start at most
--       10 tables an hour. Please try again later.", DETAIL rate_limited), no
--       table; the 10 moved back 61 minutes: C creates.
--   K5  every code made by create_table in this run is distinct, and each
--       belongs to exactly one table.
--   JOIN
--   J1  B joins A's table: outcome 'joined' and every column as expected
--       (seat 2, seated_count 2, no game, host_nickname = A's nickname, ...);
--       B seated; one join row.
--   J2  B again (the same table): 'already_seated', seat 2, nothing changed,
--       still one join row.
--   J3  D joins A's (full) table: "This table is full.", not seated, nothing
--       logged for D.
--   J4  D: an unknown code, the ENDED table's code, and an unknown code as a
--       preview: each outcome 'not_found' with every other column NULL (one
--       answer for all three), each counted (3 wrong codes).
--   J5  D's 4th and 5th wrong codes still answer 'not_found'; then a VALID
--       code is refused: "Too many wrong table codes. Please wait 15 minutes
--       and try again." (DETAIL locked_out), not seated; watch_table is
--       locked too (one count); 14 minutes later still locked ("1 minute");
--       15 minutes later D joins J5.
--   J6  E: 5 wrong codes spread over 28 minutes is NOT a lockout (a preview
--       of J6 works).
--   J7  E with 30 joins in the last hour: refused ("You can join at most 30
--       tables an hour. Please try again later.", rate_limited); moved back 61
--       minutes: E joins J6.
--   J8  P previews J7: outcome 'preview', seat NULL, seated_count 1, not
--       seated, nothing logged; then joins: 'joined', seat 2.
--   THE ONE-TABLE RULE
--   R1  A (seated at their table) creates: refused "You're already at table
--       <A's code>. Rejoin it or leave it first." (DETAIL already_at_table,
--       HINT the code); no new table.
--   R2  A joins R6: refused, naming A's table; not seated at R6.
--   R3  A watches X: refused, naming A's table; no spectator row.
--   R4  A starts a computer game: refused, naming A's table.
--   R5  S1 watches W, then creates: created and seated; the W row is gone.
--   R6  S2 watches W, then joins R6: joined; the W row is gone.
--   R7  S3 watches W, then starts a computer game: started; the W row is gone.
--   R8  S4 watches W, then watches X: the W row is gone, the X row is there;
--       two watch rows (two NEW watches).
--   R9  S4 watches X again: a no-op success (same row, still two watch rows).
--   R10 F, seated only at the ENDED table Q, creates: created.
--   R11 A watching their own table: "You are seated at this table." (the
--       app's exact text), not the new message.
--   WATCH AND COMPUTER LIMITS
--   V1  V watches an unknown code: no exception, NO row, one wrong code.
--   V2  V with 30 watches in the last hour: refused ("You can start watching
--       at most 30 tables an hour. Please try again later."); moved back 61
--       minutes: V watches W.
--   V3  K with 10 computer games in the last hour: refused ("You can start
--       at most 10 single-player games an hour. Please try again later.");
--       moved back 61 minutes: K starts one (seats 1 and 2: K and the
--       computer).
--   SINGLE-PLAYER GAMES NEVER BLOCK (Walt): a real action ends the caller's
--   own computer table the way leave_computer_table does; a refusal rolls
--   that back; a preview changes nothing
--   SP1  M1 "joins" their own computer table's code: 'already_seated', the
--        table still open with both seats, no join row.
--   SP2  (a) M1 (computer table, NO live game) creates: created, seat 1; the
--        computer table is ended (status 'ended', ended_reason NULL) with no
--        seat left at it.
--   SP3  (b) M2 (computer table with a LIVE game) creates: created; that game
--        is 'ended' / 'player_left'; the computer table ended, no seat left.
--   SP4  (c) M3 (computer table) joins X: joined; the computer table ended.
--   SP5  (c) M4 (computer table) watches W: watching; the computer table
--        ended.
--   SP6  (c) M5 (computer table with a live game) starts a NEW computer game:
--        the old game 'player_left', the old table ended; the new table has
--        M5 in seat 1 and the computer in seat 2.
--   SP7  (d) M6 (computer table with a live game AND seated at Y with H)
--        creates: refused "You're already at table <Y's code>. ..." (DETAIL
--        already_at_table, HINT Y's code); no new table; the computer table
--        still open with both seats and its game still live (the refusal
--        rolled the quiet end back).
--   SP8  (e) M7 (computer table) previews X: outcome 'preview', no refusal;
--        the computer table still open with both seats; M7 not at X; no join
--        row.
--   SP9  (f) M8 (computer table with a live game) joins A's FULL table: "This
--        table is full."; not seated there; the computer table still open with
--        both seats and its game still live; no join row.
--   SP10 (g) M9 and M10 each start an easy computer game and a live game:
--        both tables open, both games live, the same computer seated at both
--        and at every other open easy table of this run: the computer's seats
--        never trip the rule, because the computer is never the caller (it
--        acts only through the computer_* functions and their guard; it never
--        calls create_table, join_table_by_code or watch_table).
--   THE LOCKDOWN (only once join-create-lockdown.sql has run; skipped before,
--   and the verdict says so; a HALF-applied lockdown fails at L0)
--   L0  authenticated has no INSERT (table-wide or on any column) on tables
--       or table_members, and neither has anon.
--   L1  L's direct insert into tables: 42501. L2 L's direct insert into
--       table_members: 42501.
--   L3  the RPCs still work under the lockdown: L creates a table and is
--       seated (every K/J/R/V check above also ran under it).

do $$
declare
  v_checks int := 0;
  v_lockdown text;
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid();
  v_e uuid := gen_random_uuid();
  v_f uuid := gen_random_uuid();
  v_g uuid := gen_random_uuid();
  v_p uuid := gen_random_uuid();
  v_s1 uuid := gen_random_uuid();
  v_s2 uuid := gen_random_uuid();
  v_s3 uuid := gen_random_uuid();
  v_s4 uuid := gen_random_uuid();
  v_v uuid := gen_random_uuid();
  v_k uuid := gen_random_uuid();
  v_h uuid := gen_random_uuid();
  v_l uuid := gen_random_uuid();
  v_m1 uuid := gen_random_uuid();
  v_m2 uuid := gen_random_uuid();
  v_m3 uuid := gen_random_uuid();
  v_m4 uuid := gen_random_uuid();
  v_m5 uuid := gen_random_uuid();
  v_m6 uuid := gen_random_uuid();
  v_m7 uuid := gen_random_uuid();
  v_m8 uuid := gen_random_uuid();
  v_m9 uuid := gen_random_uuid();
  v_m10 uuid := gen_random_uuid();
  v_ms uuid[];
  v_ct uuid[] := '{}';
  v_ct_code text[] := '{}';
  v_i int;
  v_game uuid;
  v_y uuid; v_y_code text;
  v_people uuid[];
  v_pid uuid;
  v_codes text[];
  v_free text;
  v_w uuid; v_x uuid; v_q uuid; v_j5 uuid; v_j6 uuid; v_j7 uuid; v_r6 uuid;
  v_a_table uuid; v_a_code text; v_a_nick text;
  v_tid uuid; v_code text;
  v_made text[] := '{}';
  v_j record;
  v_rec record;
  v_msg text; v_detail text; v_hint text; v_state text;
  v_txt text; v_txt2 text;
  v_n int; v_n2 int;
  v_seat smallint;
  v_comp uuid;
begin
  -- ==== CATALOG ===================================================================
  if to_regclass('public.attempt_log') is null
     or to_regprocedure('public.create_table(boolean, boolean, integer, text, boolean)') is null
     or (to_regprocedure('public.join_table_by_code(text, boolean)') is null
         and to_regprocedure('public.join_table_by_code(text, boolean, uuid)') is null) then
    raise exception 'SETUP: join-create.sql has not run (attempt_log, create_table or join_table_by_code missing).';
  end if;

  -- [C1] attempt_log: RLS, policies, privileges, index, Realtime, sequence.
  select c.relrowsecurity into strict v_txt from pg_class c where c.oid = 'public.attempt_log'::regclass;
  if v_txt is distinct from 'true' then
    raise exception 'FAIL [C1] attempt_log row-level security is %; expected on.', v_txt;
  end if;
  select count(*) into v_n from pg_policies p where p.schemaname = 'public' and p.tablename = 'attempt_log';
  if v_n <> 0 then
    raise exception 'FAIL [C1] attempt_log has % policies; expected none.', v_n;
  end if;
  foreach v_txt in array array['anon', 'authenticated', 'service_role'] loop
    if exists (select 1 from pg_roles r where r.rolname = v_txt)
       and has_table_privilege(v_txt, 'public.attempt_log', 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER') then
      raise exception 'FAIL [C1] % has a privilege on attempt_log; expected none.', v_txt;
    end if;
  end loop;
  select count(*) into v_n
  from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
  where c.oid = 'public.attempt_log'::regclass and a.grantee = 0;
  if v_n <> 0 then
    raise exception 'FAIL [C1] attempt_log has % grants to PUBLIC; expected none.', v_n;
  end if;
  if not exists (select 1 from pg_indexes i
                 where i.schemaname = 'public' and i.tablename = 'attempt_log'
                   and i.indexdef ilike '%(user_id, action, created_at DESC)%') then
    raise exception 'FAIL [C1] attempt_log has no (user_id, action, created_at desc) index.';
  end if;
  if exists (select 1 from pg_publication_tables pt
             where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = 'attempt_log') then
    raise exception 'FAIL [C1] attempt_log is in the supabase_realtime publication; expected not.';
  end if;
  if has_sequence_privilege('authenticated', 'public.attempt_log_id_seq', 'USAGE, SELECT, UPDATE')
     or has_sequence_privilege('anon', 'public.attempt_log_id_seq', 'USAGE, SELECT, UPDATE') then
    raise exception 'FAIL [C1] anon or authenticated has a privilege on attempt_log_id_seq; expected none.';
  end if;
  v_checks := v_checks + 1;

  -- [C2] create_table and join_table_by_code: shape and grants.
  for v_rec in
    select * from (values
      ('public.create_table(boolean, boolean, integer, text, boolean)',
       'p_is_public boolean, p_is_muggins boolean, p_max_players integer, p_team_mode text, p_allow_spectators boolean',
       'TABLE(table_id uuid, code text)'),
      -- Slice A's shape, or -- once step 3 slice B part 1 has run -- its own
      -- (p_table_id added last, host_avatar_url added last).
      ('public.join_table_by_code(' || case when to_regprocedure('public.join_table_by_code(text, boolean, uuid)') is not null then 'text, boolean, uuid' else 'text, boolean' end || ')',
       case when to_regprocedure('public.join_table_by_code(text, boolean, uuid)') is not null then 'p_code text, p_preview boolean DEFAULT false, p_table_id uuid DEFAULT NULL::uuid'
            else 'p_code text, p_preview boolean DEFAULT false' end,
       case when to_regprocedure('public.join_table_by_code(text, boolean, uuid)') is not null then 'TABLE(outcome text, table_id uuid, code text, status text, ended_reason text, is_public boolean, is_muggins boolean, allow_spectators boolean, created_by uuid, max_players smallint, team_mode text, computer_level text, seat smallint, seated_count integer, game_live boolean, game_id uuid, host_nickname text, host_avatar_url text)'
            else 'TABLE(outcome text, table_id uuid, code text, status text, ended_reason text, is_public boolean, is_muggins boolean, allow_spectators boolean, created_by uuid, max_players smallint, team_mode text, computer_level text, seat smallint, seated_count integer, game_live boolean, game_id uuid, host_nickname text)' end)
    ) as t(fn, args, result)
  loop
    select p.prosecdef::text || ' ' || p.provolatile::text || ' '
           || case when coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']
                   then 'empty-path' else 'path:' || coalesce(p.proconfig::text, 'none') end,
           pg_get_function_arguments(p.oid) || ' -> ' || pg_get_function_result(p.oid)
    into v_txt, v_txt2
    from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is distinct from 'true v empty-path' then
      raise exception 'FAIL [C2] % is "%"; expected "true v empty-path".', v_rec.fn, v_txt;
    end if;
    if v_txt2 is distinct from v_rec.args || ' -> ' || v_rec.result then
      raise exception 'FAIL [C2] % has "%"; expected "% -> %".', v_rec.fn, v_txt2, v_rec.args, v_rec.result;
    end if;
    select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = to_regprocedure(v_rec.fn) and a.grantee = 0;
    if v_n <> 0
       or not has_function_privilege('authenticated', to_regprocedure(v_rec.fn), 'EXECUTE')
       or has_function_privilege('anon', to_regprocedure(v_rec.fn), 'EXECUTE')
       or (exists (select 1 from pg_roles r where r.rolname = 'service_role')
           and has_function_privilege('service_role', to_regprocedure(v_rec.fn), 'EXECUTE')) then
      raise exception 'FAIL [C2] EXECUTE grants on % are wrong: expected authenticated only (PUBLIC grants: %).', v_rec.fn, v_n;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- [C3] watch_table and create_computer_table.
  select p.prosecdef::text || ' ' || p.provolatile::text || ' '
         || case when coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']
                 then 'empty-path' else 'path:' || coalesce(p.proconfig::text, 'none') end
  -- watch_table(text), or watch_table(text, uuid) once slice B part 1 has run.
  into v_txt from pg_proc p where p.oid = coalesce(to_regprocedure('public.watch_table(text, uuid)'), to_regprocedure('public.watch_table(text)'));
  if v_txt is distinct from 'true v empty-path'
     or not has_function_privilege('authenticated', coalesce(to_regprocedure('public.watch_table(text, uuid)'), to_regprocedure('public.watch_table(text)')), 'EXECUTE')
     or has_function_privilege('anon', coalesce(to_regprocedure('public.watch_table(text, uuid)'), to_regprocedure('public.watch_table(text)')), 'EXECUTE') then
    raise exception 'FAIL [C3] watch_table is "%" or its grants changed; expected definer, volatile, empty path, authenticated only.', v_txt;
  end if;
  select p.prosecdef::text || ' ' || coalesce(p.proconfig::text, 'none')
  into v_txt from pg_proc p where p.oid = to_regprocedure('public.create_computer_table(text, text)');
  if v_txt is distinct from 'true {search_path=public}'
     or not has_function_privilege('authenticated', 'public.create_computer_table(text, text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.create_computer_table(text, text)', 'EXECUTE') then
    raise exception 'FAIL [C3] create_computer_table is "%" or its grants changed; expected definer, search_path=public, authenticated yes, anon no.', v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [C4] The helpers: invoker, and nobody but the owner may execute them.
  for v_rec in
    select * from (values
      ('public._attempts_guard(uuid, text, integer, interval, text)'),
      ('public._code_guesses_check(uuid)'),
      ('public._code_guess_failed(uuid)'),
      ('public._one_table_rule(uuid, uuid, boolean)')
    ) as t(fn)
  loop
    if to_regprocedure(v_rec.fn) is null then
      raise exception 'FAIL [C4] % is missing.', v_rec.fn;
    end if;
    select p.prosecdef::text into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = to_regprocedure(v_rec.fn) and a.grantee = 0;
    if v_txt <> 'false' or v_n <> 0
       or has_function_privilege('authenticated', to_regprocedure(v_rec.fn), 'EXECUTE')
       or has_function_privilege('anon', to_regprocedure(v_rec.fn), 'EXECUTE')
       or (exists (select 1 from pg_roles r where r.rolname = 'service_role')
           and has_function_privilege('service_role', to_regprocedure(v_rec.fn), 'EXECUTE')) then
      raise exception 'FAIL [C4] % is definer=% or executable by a client role (PUBLIC grants: %); expected invoker, owner only.', v_rec.fn, v_txt, v_n;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- [C5] attempt_log as authenticated and as anon: permission denied.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  foreach v_txt in array array['authenticated', 'anon'] loop
    foreach v_txt2 in array array['select', 'insert'] loop
      v_state := null;
      execute format('set local role %I', v_txt);
      begin
        if v_txt2 = 'select' then
          perform 1 from public.attempt_log limit 1;
        else
          insert into public.attempt_log (user_id, action, success) values (v_a, 'join', true);
        end if;
      exception when others then
        v_state := sqlstate;
      end;
      execute 'reset role';
      if v_state is distinct from '42501' then
        raise exception 'FAIL [C5] % on attempt_log as %: %; expected 42501 (permission denied).', v_txt2, v_txt, coalesce(v_state, 'allowed');
      end if;
    end loop;
  end loop;
  v_checks := v_checks + 1;

  -- [C6] The chat suite's C4: no other "chat" function in public.
  select string_agg(p.proname::text, ', ') into v_txt
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows';
  if v_txt is not null then
    raise exception 'FAIL [C6] public functions with "chat" in the name: %.', v_txt;
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner =========================================================
  v_people := array[v_a, v_b, v_c, v_d, v_e, v_f, v_g, v_p, v_s1, v_s2, v_s3, v_s4, v_v, v_k, v_h, v_l,
                    v_m1, v_m2, v_m3, v_m4, v_m5, v_m6, v_m7, v_m8, v_m9, v_m10];
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'jc-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      insert into public.profiles (id, nickname)
      values (v_pid, 'jc' || left(replace(v_pid::text, '-', ''), 12))
      on conflict (id) do update set nickname = excluded.nickname;
    end loop;
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
    -- Codes no OPEN table holds -- every table while the old unique key
    -- exists (before step 3 slice B part 2 frees ended tables' codes).
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                        and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null))
    order by n
    limit 8
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 8 then
    raise exception 'SETUP: fewer than eight unused table codes.';
  end if;

  begin
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[1], v_h, true, true, 4) returning id into v_w;
    insert into public.table_members (table_id, user_id) values (v_w, v_h);

    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[2], v_h, true, true, 4) returning id into v_x;
    insert into public.table_members (table_id, user_id) values (v_x, v_h);

    -- Seated first, then ended (as a Force-End leaves a table).
    insert into public.tables (code, created_by, is_public) values (v_codes[3], v_f, true) returning id into v_q;
    insert into public.table_members (table_id, user_id) values (v_q, v_f);
    update public.tables set status = 'ended', ended_reason = 'admin' where id = v_q;

    insert into public.tables (code, created_by, is_public) values (v_codes[4], v_h, true) returning id into v_j5;
    insert into public.table_members (table_id, user_id) values (v_j5, v_h);
    insert into public.tables (code, created_by, is_public) values (v_codes[5], v_h, true) returning id into v_j6;
    insert into public.table_members (table_id, user_id) values (v_j6, v_h);
    insert into public.tables (code, created_by, is_public) values (v_codes[6], v_h, true) returning id into v_j7;
    insert into public.table_members (table_id, user_id) values (v_j7, v_h);
    insert into public.tables (code, created_by, is_public) values (v_codes[7], v_h, true) returning id into v_r6;
    insert into public.table_members (table_id, user_id) values (v_r6, v_h);
    insert into public.tables (code, created_by, is_public) values (v_codes[8], v_h, true) returning id into v_y;
    insert into public.table_members (table_id, user_id) values (v_y, v_h);
    v_y_code := v_codes[8];
  exception when others then
    raise exception 'SETUP: could not create the test tables and seats: % (%).', sqlerrm, sqlstate;
  end;

  -- ==== CREATE ========================================================================
  -- [K1] A creates a table.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  v_msg := null; v_tid := null; v_code := null;
  execute 'set local role authenticated';
  begin
    select r.table_id, r.code into v_tid, v_code from public.create_table(true, false, 2, null, true) r;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_tid is null then
    raise exception 'FAIL [K1] A''s create_table: %.', coalesce(v_msg, 'no row');
  end if;
  v_a_table := v_tid; v_a_code := v_code; v_made := v_made || v_code;
  select count(*) into v_n from public.tables t
  where t.id = v_tid and t.code = v_code and t.created_by = v_a and t.status = 'open'
    and t.is_public and not t.is_muggins and t.max_players = 2 and t.team_mode = 'teams'
    and t.allow_spectators and t.computer_level is null;
  select tm.seat into v_seat from public.table_members tm where tm.table_id = v_tid and tm.user_id = v_a;
  select count(*) into v_n2 from public.tables t where t.code = v_code and t.status <> 'ended';  -- slice B: one OPEN table per code
  if v_n <> 1 or v_seat is distinct from 1 or v_code !~ '^[0-9]{4}$' or v_n2 <> 1
     or (select count(*) from public.attempt_log al where al.user_id = v_a and al.action = 'create_table' and al.success) <> 1 then
    raise exception 'FAIL [K1] A''s table: options match %, A''s seat %, code "%" on % tables, create rows %; expected 1, 1, 4 digits on 1, 1.',
      v_n, v_seat, v_code, v_n2,
      (select count(*) from public.attempt_log al where al.user_id = v_a and al.action = 'create_table');
  end if;
  v_checks := v_checks + 1;

  -- [K2] Refused options, each with its message; nothing made or logged.
  perform set_config('request.jwt.claims', json_build_object('sub', v_g, 'role', 'authenticated')::text, true);
  for v_rec in
    select * from (values
      (5, false, null::text, 'A table seats 2, 3 or 4 players.'),
      (4, true, 'teams', 'A 4-player Self-Scoring table plays Solo.'),
      (4, false, 'pairs', 'Choose Teams or Solo for a 4-player table.')
    ) as t(seats, muggins, mode, expected)
  loop
    v_msg := null;
    execute 'set local role authenticated';
    begin
      perform 1 from public.create_table(true, v_rec.muggins, v_rec.seats, v_rec.mode, false);
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_msg is distinct from v_rec.expected then
      raise exception 'FAIL [K2] % seats, muggins %, mode %: "%"; expected "%".', v_rec.seats, v_rec.muggins, v_rec.mode, coalesce(v_msg, 'created'), v_rec.expected;
    end if;
  end loop;
  if exists (select 1 from public.tables t where t.created_by = v_g)
     or exists (select 1 from public.attempt_log al where al.user_id = v_g) then
    raise exception 'FAIL [K2] a refused create left a table or a log row behind.';
  end if;
  v_checks := v_checks + 1;

  -- [K3] 4-player Self-Scoring, Solo: allowed.
  v_msg := null; v_tid := null;
  execute 'set local role authenticated';
  begin
    select r.table_id, r.code into v_tid, v_code from public.create_table(false, true, 4, 'solo', false) r;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null
     or not exists (select 1 from public.tables t where t.id = v_tid and t.is_muggins and t.max_players = 4
                      and t.team_mode = 'solo' and not t.is_public and not t.allow_spectators) then
    raise exception 'FAIL [K3] 4-player Self-Scoring Solo: %.', coalesce(v_msg, 'wrong row');
  end if;
  v_made := v_made || v_code;
  v_checks := v_checks + 1;

  -- [K4] The create limit: 10 an hour.
  insert into public.attempt_log (user_id, action, success, created_at)
  select v_c, 'create_table', true, now() - interval '30 minutes' from generate_series(1, 10);
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  v_msg := null; v_detail := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.create_table(true, false, 2, null, false);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
  end;
  execute 'reset role';
  if v_msg is distinct from 'You can start at most 10 tables an hour. Please try again later.'
     or v_detail is distinct from 'rate_limited'
     or exists (select 1 from public.tables t where t.created_by = v_c) then
    raise exception 'FAIL [K4] the 11th create in an hour: "%" (%); expected the limit message (rate_limited) and no table.', coalesce(v_msg, 'created'), v_detail;
  end if;
  update public.attempt_log set created_at = now() - interval '61 minutes' where user_id = v_c and action = 'create_table';
  v_msg := null; v_tid := null;
  execute 'set local role authenticated';
  begin
    select r.table_id, r.code into v_tid, v_code from public.create_table(true, false, 2, null, false) r;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_tid is null then
    raise exception 'FAIL [K4] after the hour passed, C''s create: %; expected created.', coalesce(v_msg, 'no row');
  end if;
  v_made := v_made || v_code;
  v_checks := v_checks + 1;

  -- ==== JOIN ==========================================================================
  -- [J1] B joins A's table.
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_a_code) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [J1] B joining A''s table was refused: %.', v_msg;
  end if;
  if v_j.outcome is distinct from 'joined' or v_j.table_id is distinct from v_a_table
     or v_j.code is distinct from v_a_code or v_j.status is distinct from 'open' or v_j.ended_reason is not null
     or v_j.is_public is distinct from true or v_j.is_muggins is distinct from false
     or v_j.allow_spectators is distinct from true or v_j.created_by is distinct from v_a
     or v_j.max_players is distinct from 2::smallint or v_j.team_mode is distinct from 'teams'
     or v_j.computer_level is not null or v_j.seat is distinct from 2::smallint
     or v_j.seated_count is distinct from 2 or v_j.game_live is distinct from false or v_j.game_id is not null
     or v_j.host_nickname is distinct from v_a_nick then
    raise exception 'FAIL [J1] B joining A''s table: got %; expected joined, seat 2, seated_count 2, no game, host %.',
      v_j, v_a_nick;
  end if;
  if not exists (select 1 from public.table_members tm where tm.table_id = v_a_table and tm.user_id = v_b and tm.seat = 2)
     or (select count(*) from public.attempt_log al where al.user_id = v_b and al.action = 'join' and al.success) <> 1 then
    raise exception 'FAIL [J1] B is not seated in seat 2, or the join was not logged once.';
  end if;
  v_checks := v_checks + 1;

  -- [J2] B again: a no-op success.
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_a_code) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_j.outcome is distinct from 'already_seated' or v_j.seat is distinct from 2::smallint
     or v_j.seated_count is distinct from 2
     or (select count(*) from public.table_members tm where tm.table_id = v_a_table) <> 2
     or (select count(*) from public.attempt_log al where al.user_id = v_b and al.action = 'join') <> 1 then
    raise exception 'FAIL [J2] B rejoining: error %, got %; expected already_seated, seat 2, nothing changed, one join row.', coalesce(v_msg, 'none'), v_j;
  end if;
  v_checks := v_checks + 1;

  -- [J3] D joins A's full table: refused as today; nothing logged for D.
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.join_table_by_code(v_a_code);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'This table is full.'
     or exists (select 1 from public.table_members tm where tm.table_id = v_a_table and tm.user_id = v_d)
     or exists (select 1 from public.attempt_log al where al.user_id = v_d) then
    raise exception 'FAIL [J3] D joining a full table: "%"; expected "This table is full.", no seat, nothing logged.', coalesce(v_msg, 'joined');
  end if;
  v_checks := v_checks + 1;

  -- [J4] Unknown, ended and (preview) unknown: one answer, each counted.
  select lpad(n::text, 4, '0') into v_free from generate_series(0, 9999) n
  -- Codes no OPEN table holds -- every table while the old unique key
  -- exists (before step 3 slice B part 2 frees ended tables' codes).
  where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                      and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null)) order by n limit 1;
  for v_rec in
    select * from (values (v_free, false), (v_codes[3], false), (v_free, true)) as t(code, preview)
  loop
    v_msg := null;
    execute 'set local role authenticated';
    begin
      select j.* into v_j from public.join_table_by_code(v_rec.code, v_rec.preview) j;
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_msg is not null or v_j.outcome is distinct from 'not_found'
       or not (row(v_j.table_id, v_j.code, v_j.status, v_j.ended_reason, v_j.is_public, v_j.is_muggins, v_j.allow_spectators,
                   v_j.created_by, v_j.max_players, v_j.team_mode, v_j.computer_level, v_j.seat, v_j.seated_count,
                   v_j.game_live, v_j.game_id, v_j.host_nickname) is null) then
      raise exception 'FAIL [J4] code % (preview %): error %, got %; expected not_found with every other column NULL.',
        v_rec.code, v_rec.preview, coalesce(v_msg, 'none'), v_j;
    end if;
  end loop;
  select count(*) into v_n from public.attempt_log al where al.user_id = v_d and al.action = 'code_guess' and not al.success;
  if v_n <> 3 then
    raise exception 'FAIL [J4] D has % wrong codes counted; expected 3.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [J5] The 4th and 5th still answer; then locked (join and watch); expiry.
  for v_n in 1..2 loop
    execute 'set local role authenticated';
    select j.* into v_j from public.join_table_by_code(v_free) j;
    execute 'reset role';
    if v_j.outcome is distinct from 'not_found' then
      raise exception 'FAIL [J5] wrong code % of 5: %; expected not_found (not locked yet).', 3 + v_n, v_j.outcome;
    end if;
  end loop;
  v_msg := null; v_detail := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.join_table_by_code(v_codes[4]);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
  end;
  execute 'reset role';
  if v_msg is distinct from 'Too many wrong table codes. Please wait 15 minutes and try again.'
     or v_detail is distinct from 'locked_out'
     or exists (select 1 from public.table_members tm where tm.table_id = v_j5 and tm.user_id = v_d) then
    raise exception 'FAIL [J5] D after 5 wrong codes, a valid code: "%" (%); expected the 15-minute lockout, not seated.', coalesce(v_msg, 'joined'), v_detail;
  end if;
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'Too many wrong table codes. Please wait 15 minutes and try again.' then
    raise exception 'FAIL [J5] D watching while locked out: "%"; expected the lockout (one count for join and watch).', coalesce(v_msg, 'watched');
  end if;
  if (select count(*) from public.attempt_log al where al.user_id = v_d) <> 5 then
    raise exception 'FAIL [J5] D has % attempt rows; expected exactly the 5 wrong codes (locked calls are not logged).',
      (select count(*) from public.attempt_log al where al.user_id = v_d);
  end if;
  update public.attempt_log set created_at = created_at - interval '14 minutes' where user_id = v_d;
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.join_table_by_code(v_codes[4]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'Too many wrong table codes. Please wait 1 minute and try again.' then
    raise exception 'FAIL [J5] 14 minutes after the 5th wrong code: "%"; expected still locked, 1 minute.', coalesce(v_msg, 'joined');
  end if;
  update public.attempt_log set created_at = created_at - interval '1 minute' where user_id = v_d;
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_codes[4]) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_j.outcome is distinct from 'joined' or v_j.table_id is distinct from v_j5 then
    raise exception 'FAIL [J5] 15 minutes after the 5th wrong code: error %, outcome %; expected D joins J5.', coalesce(v_msg, 'none'), v_j.outcome;
  end if;
  v_checks := v_checks + 1;

  -- [J6] Five wrong codes spread over 28 minutes: no lockout.
  insert into public.attempt_log (user_id, action, success, created_at)
  select v_e, 'code_guess', false, now() - make_interval(mins => m)
  from unnest(array[30, 8, 6, 4, 2]) as m;
  perform set_config('request.jwt.claims', json_build_object('sub', v_e, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_codes[5], true) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_j.outcome is distinct from 'preview' then
    raise exception 'FAIL [J6] 5 wrong codes over 28 minutes: error %, outcome %; expected no lockout (preview).', coalesce(v_msg, 'none'), v_j.outcome;
  end if;
  v_checks := v_checks + 1;

  -- [J7] The join limit: 30 an hour.
  insert into public.attempt_log (user_id, action, success, created_at)
  select v_e, 'join', true, now() - interval '20 minutes' from generate_series(1, 30);
  v_msg := null; v_detail := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.join_table_by_code(v_codes[5]);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
  end;
  execute 'reset role';
  if v_msg is distinct from 'You can join at most 30 tables an hour. Please try again later.'
     or v_detail is distinct from 'rate_limited'
     or exists (select 1 from public.table_members tm where tm.table_id = v_j6 and tm.user_id = v_e) then
    raise exception 'FAIL [J7] the 31st join in an hour: "%" (%); expected the limit message, not seated.', coalesce(v_msg, 'joined'), v_detail;
  end if;
  update public.attempt_log set created_at = now() - interval '61 minutes' where user_id = v_e and action = 'join';
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_codes[5]) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_j.outcome is distinct from 'joined' then
    raise exception 'FAIL [J7] after the hour passed, E''s join: error %, outcome %; expected joined.', coalesce(v_msg, 'none'), v_j.outcome;
  end if;
  v_checks := v_checks + 1;

  -- [J8] P previews J7 (changes nothing), then joins.
  perform set_config('request.jwt.claims', json_build_object('sub', v_p, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_codes[6], true) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_j.outcome is distinct from 'preview' or v_j.table_id is distinct from v_j7
     or v_j.seat is not null or v_j.seated_count is distinct from 1 or v_j.max_players is distinct from 2::smallint
     or exists (select 1 from public.table_members tm where tm.table_id = v_j7 and tm.user_id = v_p)
     or exists (select 1 from public.attempt_log al where al.user_id = v_p) then
    raise exception 'FAIL [J8] P''s preview: error %, got %; expected preview, seat NULL, seated_count 1, not seated, nothing logged.', coalesce(v_msg, 'none'), v_j;
  end if;
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_codes[6]) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_j.outcome is distinct from 'joined' or v_j.seat is distinct from 2::smallint then
    raise exception 'FAIL [J8] P''s join after the preview: error %, got %; expected joined, seat 2.', coalesce(v_msg, 'none'), v_j;
  end if;
  v_checks := v_checks + 1;

  -- ==== THE ONE-TABLE RULE ==============================================================
  v_txt := format('You''re already at table %s. Rejoin it or leave it first.', v_a_code);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);

  -- [R1] A creates: refused, naming A's table.
  v_msg := null; v_detail := null; v_hint := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.create_table(true, false, 2, null, false);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail, v_hint = pg_exception_hint;
  end;
  execute 'reset role';
  if v_msg is distinct from v_txt or v_detail is distinct from 'already_at_table' or split_part(v_hint, ' ', 1) is distinct from v_a_code  -- slice B: HINT "<code> <id>"
     or (select count(*) from public.tables t where t.created_by = v_a) <> 1 then
    raise exception 'FAIL [R1] A (seated) creating: "%" (%, %); expected "%" (already_at_table, %), no new table.', coalesce(v_msg, 'created'), v_detail, v_hint, v_txt, v_a_code;
  end if;
  v_checks := v_checks + 1;

  -- [R2] A joins R6: refused.
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.join_table_by_code(v_codes[7]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from v_txt or exists (select 1 from public.table_members tm where tm.table_id = v_r6 and tm.user_id = v_a) then
    raise exception 'FAIL [R2] A (seated) joining another table: "%"; expected "%", not seated.', coalesce(v_msg, 'joined'), v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [R3] A watches X: refused.
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[2]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from v_txt or exists (select 1 from public.table_spectators ts where ts.user_id = v_a) then
    raise exception 'FAIL [R3] A (seated) watching another table: "%"; expected "%", no spectator row.', coalesce(v_msg, 'watched'), v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [R4] A starts a computer game: refused.
  select lpad(n::text, 4, '0') into v_free from generate_series(0, 9999) n
  -- Codes no OPEN table holds -- every table while the old unique key
  -- exists (before step 3 slice B part 2 frees ended tables' codes).
  where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                      and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null)) order by n limit 1;
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.create_computer_table('easy', v_free);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from v_txt or exists (select 1 from public.tables t where t.code = v_free and t.status <> 'ended') then
    raise exception 'FAIL [R4] A (seated) starting a computer game: "%"; expected "%", no table.', coalesce(v_msg, 'started'), v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [R11] A watching their own table: the app's exact text.
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_a_code);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'You are seated at this table.' then
    raise exception 'FAIL [R11] A watching their own table: "%"; expected "You are seated at this table.".', coalesce(v_msg, 'watched');
  end if;
  v_checks := v_checks + 1;

  -- S1..S4 watch W.
  foreach v_pid in array array[v_s1, v_s2, v_s3, v_s4] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_pid, 'role', 'authenticated')::text, true);
    v_msg := null;
    execute 'set local role authenticated';
    begin
      perform 1 from public.watch_table(v_codes[1]);
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_msg is not null or not exists (select 1 from public.table_spectators ts where ts.table_id = v_w and ts.user_id = v_pid) then
      raise exception 'SETUP: % could not watch W: %.', v_pid, coalesce(v_msg, 'no row');
    end if;
  end loop;

  -- [R5] S1 (watching W) creates: created, seated, the W row gone.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  v_msg := null; v_tid := null;
  execute 'set local role authenticated';
  begin
    select r.table_id, r.code into v_tid, v_code from public.create_table(true, false, 2, null, false) r;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null
     or not exists (select 1 from public.table_members tm where tm.table_id = v_tid and tm.user_id = v_s1 and tm.seat = 1)
     or exists (select 1 from public.table_spectators ts where ts.user_id = v_s1) then
    raise exception 'FAIL [R5] S1 (watching) creating: %; expected created and seated, watching ended.', coalesce(v_msg, 'see rows');
  end if;
  v_made := v_made || v_code;
  v_checks := v_checks + 1;

  -- [R6] S2 (watching W) joins R6: joined, the W row gone.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s2, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_codes[7]) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_j.outcome is distinct from 'joined'
     or exists (select 1 from public.table_spectators ts where ts.user_id = v_s2) then
    raise exception 'FAIL [R6] S2 (watching) joining: error %, outcome %; expected joined, watching ended.', coalesce(v_msg, 'none'), v_j.outcome;
  end if;
  v_checks := v_checks + 1;

  -- [R7] S3 (watching W) starts a computer game: started, the W row gone.
  select lpad(n::text, 4, '0') into v_free from generate_series(0, 9999) n
  -- Codes no OPEN table holds -- every table while the old unique key
  -- exists (before step 3 slice B part 2 frees ended tables' codes).
  where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                      and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null)) order by n limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_s3, 'role', 'authenticated')::text, true);
  v_msg := null; v_tid := null;
  execute 'set local role authenticated';
  begin
    select r.table_id into v_tid from public.create_computer_table('easy', v_free) r;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null
     or not exists (select 1 from public.table_members tm where tm.table_id = v_tid and tm.user_id = v_s3 and tm.seat = 1)
     or exists (select 1 from public.table_spectators ts where ts.user_id = v_s3) then
    raise exception 'FAIL [R7] S3 (watching) starting a computer game: %; expected started, watching ended.', coalesce(v_msg, 'see rows');
  end if;
  v_checks := v_checks + 1;

  -- [R8] S4 (watching W) watches X: moved; two NEW watches logged.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s4, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[2]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null
     or exists (select 1 from public.table_spectators ts where ts.table_id = v_w and ts.user_id = v_s4)
     or not exists (select 1 from public.table_spectators ts where ts.table_id = v_x and ts.user_id = v_s4 and ts.removed_at is null)
     or (select count(*) from public.attempt_log al where al.user_id = v_s4 and al.action = 'watch' and al.success) <> 2 then
    raise exception 'FAIL [R8] S4 moving from W to X: %; expected the W row gone, an X row, two watch rows.', coalesce(v_msg, 'see rows');
  end if;
  v_checks := v_checks + 1;

  -- [R9] S4 watches X again: a no-op success, not counted.
  v_msg := null; v_n := null;
  execute 'set local role authenticated';
  begin
    select count(*) into v_n from public.watch_table(v_codes[2]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_n <> 1
     or (select count(*) from public.table_spectators ts where ts.user_id = v_s4) <> 1
     or (select count(*) from public.attempt_log al where al.user_id = v_s4 and al.action = 'watch') <> 2 then
    raise exception 'FAIL [R9] S4 re-watching X: error %, rows %; expected one row back, the same place, still two watch rows.', coalesce(v_msg, 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [R10] F, seated only at the ENDED table Q, creates: allowed.
  perform set_config('request.jwt.claims', json_build_object('sub', v_f, 'role', 'authenticated')::text, true);
  v_msg := null; v_tid := null;
  execute 'set local role authenticated';
  begin
    select r.table_id, r.code into v_tid, v_code from public.create_table(true, false, 2, null, false) r;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_tid is null then
    raise exception 'FAIL [R10] F (seated only at an ended table) creating: %; expected created (ended tables don''t count).', coalesce(v_msg, 'no row');
  end if;
  v_made := v_made || v_code;
  v_checks := v_checks + 1;

  -- [K5] Every code create_table made: distinct, one table each.
  select count(*), count(distinct c) into v_n, v_n2 from unnest(v_made) c;
  if v_n <> v_n2
     or exists (select 1 from unnest(v_made) c where (select count(*) from public.tables t where t.code = c and t.status <> 'ended') <> 1) then
    raise exception 'FAIL [K5] create_table''s codes %: not distinct, or a code is on more than one table.', v_made;
  end if;
  v_checks := v_checks + 1;

  -- ==== WATCH AND COMPUTER LIMITS ==========================================================
  -- [V1] V watches an unknown code: no exception, no row, one wrong code.
  select lpad(n::text, 4, '0') into v_free from generate_series(0, 9999) n
  -- Codes no OPEN table holds -- every table while the old unique key
  -- exists (before step 3 slice B part 2 frees ended tables' codes).
  where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                      and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null)) order by n limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_v, 'role', 'authenticated')::text, true);
  v_msg := null; v_n := null;
  execute 'set local role authenticated';
  begin
    select count(*) into v_n from public.watch_table(v_free);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_n <> 0
     or (select count(*) from public.attempt_log al where al.user_id = v_v and al.action = 'code_guess' and not al.success) <> 1 then
    raise exception 'FAIL [V1] V watching an unknown code: error %, rows %; expected no error, no row, one wrong code counted.', coalesce(v_msg, 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [V2] The watch limit: 30 new watches an hour.
  insert into public.attempt_log (user_id, action, success, created_at)
  select v_v, 'watch', true, now() - interval '10 minutes' from generate_series(1, 30);
  v_msg := null; v_detail := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
  end;
  execute 'reset role';
  if v_msg is distinct from 'You can start watching at most 30 tables an hour. Please try again later.'
     or v_detail is distinct from 'rate_limited'
     or exists (select 1 from public.table_spectators ts where ts.user_id = v_v) then
    raise exception 'FAIL [V2] the 31st new watch in an hour: "%" (%); expected the limit message, no row.', coalesce(v_msg, 'watched'), v_detail;
  end if;
  update public.attempt_log set created_at = now() - interval '61 minutes' where user_id = v_v and action = 'watch';
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or not exists (select 1 from public.table_spectators ts where ts.table_id = v_w and ts.user_id = v_v) then
    raise exception 'FAIL [V2] after the hour passed, V''s watch: %; expected watching W.', coalesce(v_msg, 'no row');
  end if;
  v_checks := v_checks + 1;

  -- [V3] The computer game limit: 10 an hour.
  insert into public.attempt_log (user_id, action, success, created_at)
  select v_k, 'create_computer_table', true, now() - interval '5 minutes' from generate_series(1, 10);
  select lpad(n::text, 4, '0') into v_free from generate_series(0, 9999) n
  -- Codes no OPEN table holds -- every table while the old unique key
  -- exists (before step 3 slice B part 2 frees ended tables' codes).
  where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                      and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null)) order by n limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_k, 'role', 'authenticated')::text, true);
  v_msg := null; v_detail := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.create_computer_table('easy', v_free);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
  end;
  execute 'reset role';
  if v_msg is distinct from 'You can start at most 10 single-player games an hour. Please try again later.'
     or v_detail is distinct from 'rate_limited'
     or exists (select 1 from public.tables t where t.code = v_free and t.status <> 'ended') then
    raise exception 'FAIL [V3] the 11th computer game in an hour: "%" (%); expected the limit message, no table.', coalesce(v_msg, 'started'), v_detail;
  end if;
  update public.attempt_log set created_at = now() - interval '61 minutes' where user_id = v_k and action = 'create_computer_table';
  select ca.user_id into v_comp from public.computer_accounts ca where ca.level = 'easy';
  v_msg := null; v_tid := null;
  execute 'set local role authenticated';
  begin
    select r.table_id into v_tid from public.create_computer_table('easy', v_free) r;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null
     or (select string_agg(tm.user_id::text || '@' || tm.seat, ',' order by tm.seat) from public.table_members tm where tm.table_id = v_tid)
        is distinct from v_k::text || '@1,' || v_comp::text || '@2' then
    raise exception 'FAIL [V3] after the hour passed, K''s computer game: %; expected K in seat 1 and the computer in seat 2.', coalesce(v_msg, 'wrong seats');
  end if;
  v_checks := v_checks + 1;

  -- ==== SINGLE-PLAYER GAMES NEVER BLOCK ======================================================
  -- Setup: M1..M8 each start an easy computer game (the real path); M2, M5,
  -- M6 and M8 also start a live game there. Then M6 is seated at Y as the
  -- owner (through join_table_by_code that would end M6's computer game,
  -- which is not the state SP7 needs).
  v_ms := array[v_m1, v_m2, v_m3, v_m4, v_m5, v_m6, v_m7, v_m8];
  for v_i in 1 .. 8 loop
    select lpad(n::text, 4, '0') into v_free from generate_series(0, 9999) n
    -- Codes no OPEN table holds -- every table while the old unique key
    -- exists (before step 3 slice B part 2 frees ended tables' codes).
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                        and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null)) order by n limit 1;
    perform set_config('request.jwt.claims', json_build_object('sub', v_ms[v_i], 'role', 'authenticated')::text, true);
    v_msg := null; v_tid := null; v_game := null;
    execute 'set local role authenticated';
    begin
      -- The table's REAL code: since slice B part 2 the server picks it (the
      -- one sent is ignored).
      select r.table_id, r.code into v_tid, v_free from public.create_computer_table('easy', v_free) r;
      if v_i in (2, 5, 6, 8) then
        v_game := public.start_game_with_deal(v_tid);
      end if;
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_msg is not null or v_tid is null or (v_i in (2, 5, 6, 8) and v_game is null) then
      raise exception 'SETUP: M% could not start a computer game%: %.', v_i,
        case when v_i in (2, 5, 6, 8) then ' and a live game' else '' end, coalesce(v_msg, 'no table or game');
    end if;
    v_ct := v_ct || v_tid;
    v_ct_code := v_ct_code || v_free;
  end loop;
  begin
    insert into public.table_members (table_id, user_id) values (v_y, v_m6);
  exception when others then
    raise exception 'SETUP: could not seat M6 at Y: % (%).', sqlerrm, sqlstate;
  end;

  -- [SP1] M1 "joins" their own computer table's code: a no-op.
  perform set_config('request.jwt.claims', json_build_object('sub', v_m1, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_ct_code[1]) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [SP1] M1 joining their own computer table was refused: %.', v_msg;
  end if;
  if v_j.outcome is distinct from 'already_seated' or v_j.seat is distinct from 1::smallint
     or not exists (select 1 from public.tables t where t.id = v_ct[1] and t.status = 'open')
     or (select count(*) from public.table_members tm where tm.table_id = v_ct[1]) <> 2
     or exists (select 1 from public.attempt_log al where al.user_id = v_m1 and al.action = 'join') then
    raise exception 'FAIL [SP1] M1 joining their own computer table: got %; expected already_seated, seat 1, the table open with both seats, no join row.', v_j;
  end if;
  v_checks := v_checks + 1;

  -- [SP2] (a) M1, no live game, creates: the computer table ends quietly.
  v_msg := null; v_tid := null;
  execute 'set local role authenticated';
  begin
    select r.table_id into v_tid from public.create_table(true, false, 2, null, false) r;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null
     or not exists (select 1 from public.table_members tm where tm.table_id = v_tid and tm.user_id = v_m1 and tm.seat = 1)
     or not exists (select 1 from public.tables t where t.id = v_ct[1] and t.status = 'ended' and t.ended_reason is null)
     or exists (select 1 from public.table_members tm where tm.table_id = v_ct[1]) then
    raise exception 'FAIL [SP2] M1 (computer table, no live game) creating: %; expected created and seated, the computer table ended (reason NULL) with no seat left.', coalesce(v_msg, 'see rows');
  end if;
  v_checks := v_checks + 1;

  -- [SP3] (b) M2, LIVE game, creates: the game ends as player_left.
  perform set_config('request.jwt.claims', json_build_object('sub', v_m2, 'role', 'authenticated')::text, true);
  v_msg := null; v_tid := null;
  execute 'set local role authenticated';
  begin
    select r.table_id into v_tid from public.create_table(true, false, 2, null, false) r;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null
     or not exists (select 1 from public.table_members tm where tm.table_id = v_tid and tm.user_id = v_m2 and tm.seat = 1)
     or exists (select 1 from public.games g where g.table_id = v_ct[2] and g.status in ('cutting', 'active'))
     or not exists (select 1 from public.games g where g.table_id = v_ct[2] and g.status = 'ended' and g.ended_reason = 'player_left')
     or not exists (select 1 from public.tables t where t.id = v_ct[2] and t.status = 'ended' and t.ended_reason is null)
     or exists (select 1 from public.table_members tm where tm.table_id = v_ct[2]) then
    raise exception 'FAIL [SP3] M2 (computer table, live game) creating: %; expected created, the game ended player_left, the table ended, no seat left.', coalesce(v_msg, 'see rows');
  end if;
  v_checks := v_checks + 1;

  -- [SP4] (c) M3 joins X: joined; the computer table ends.
  perform set_config('request.jwt.claims', json_build_object('sub', v_m3, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_codes[2]) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [SP4] M3 (computer table) joining X was refused: %.', v_msg;
  end if;
  if v_j.outcome is distinct from 'joined'
     or not exists (select 1 from public.table_members tm where tm.table_id = v_x and tm.user_id = v_m3)
     or not exists (select 1 from public.tables t where t.id = v_ct[3] and t.status = 'ended')
     or exists (select 1 from public.table_members tm where tm.table_id = v_ct[3]) then
    raise exception 'FAIL [SP4] M3 (computer table) joining X: got %; expected joined, the computer table ended with no seat left.', v_j;
  end if;
  v_checks := v_checks + 1;

  -- [SP5] (c) M4 watches W: watching; the computer table ends.
  perform set_config('request.jwt.claims', json_build_object('sub', v_m4, 'role', 'authenticated')::text, true);
  v_msg := null; v_n := null;
  execute 'set local role authenticated';
  begin
    select count(*) into v_n from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_n <> 1
     or not exists (select 1 from public.table_spectators ts where ts.table_id = v_w and ts.user_id = v_m4 and ts.removed_at is null)
     or not exists (select 1 from public.tables t where t.id = v_ct[4] and t.status = 'ended')
     or exists (select 1 from public.table_members tm where tm.table_id = v_ct[4]) then
    raise exception 'FAIL [SP5] M4 (computer table) watching W: error %, rows %; expected watching W, the computer table ended with no seat left.', coalesce(v_msg, 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [SP6] (c) M5, live game, starts a NEW computer game: the old one ends.
  select lpad(n::text, 4, '0') into v_free from generate_series(0, 9999) n
  -- Codes no OPEN table holds -- every table while the old unique key
  -- exists (before step 3 slice B part 2 frees ended tables' codes).
  where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                      and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null)) order by n limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_m5, 'role', 'authenticated')::text, true);
  v_msg := null; v_tid := null;
  execute 'set local role authenticated';
  begin
    select r.table_id into v_tid from public.create_computer_table('easy', v_free) r;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null
     or (select string_agg(tm.user_id::text || '@' || tm.seat, ',' order by tm.seat) from public.table_members tm where tm.table_id = v_tid)
        is distinct from v_m5::text || '@1,' || v_comp::text || '@2'
     or not exists (select 1 from public.games g where g.table_id = v_ct[5] and g.status = 'ended' and g.ended_reason = 'player_left')
     or exists (select 1 from public.games g where g.table_id = v_ct[5] and g.status in ('cutting', 'active'))
     or not exists (select 1 from public.tables t where t.id = v_ct[5] and t.status = 'ended')
     or exists (select 1 from public.table_members tm where tm.table_id = v_ct[5]) then
    raise exception 'FAIL [SP6] M5 (computer table, live game) starting a new computer game: %; expected the new table with M5@1 and the computer@2, the old game player_left, the old table ended.', coalesce(v_msg, 'see rows');
  end if;
  v_checks := v_checks + 1;

  -- [SP7] (d) M6, computer table (live game) AND a seat at Y, creates:
  -- refused naming Y; the computer table and its game untouched.
  perform set_config('request.jwt.claims', json_build_object('sub', v_m6, 'role', 'authenticated')::text, true);
  v_txt := format('You''re already at table %s. Rejoin it or leave it first.', v_y_code);
  v_msg := null; v_detail := null; v_hint := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.create_table(true, false, 2, null, false);
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail, v_hint = pg_exception_hint;
  end;
  execute 'reset role';
  if v_msg is distinct from v_txt or v_detail is distinct from 'already_at_table' or split_part(v_hint, ' ', 1) is distinct from v_y_code  -- slice B: HINT "<code> <id>"
     or (select count(*) from public.tables t where t.created_by = v_m6) <> 1
     or not exists (select 1 from public.tables t where t.id = v_ct[6] and t.status = 'open')
     or (select count(*) from public.table_members tm where tm.table_id = v_ct[6]) <> 2
     or not exists (select 1 from public.games g where g.table_id = v_ct[6] and g.status in ('cutting', 'active')) then
    raise exception 'FAIL [SP7] M6 (computer table and Y) creating: "%" (%, %); expected "%" (already_at_table, %), no new table, the computer table open with both seats and a live game.', coalesce(v_msg, 'created'), v_detail, v_hint, v_txt, v_y_code;
  end if;
  v_checks := v_checks + 1;

  -- [SP8] (e) M7, computer table, previews X: nothing ends, no refusal.
  perform set_config('request.jwt.claims', json_build_object('sub', v_m7, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select j.* into v_j from public.join_table_by_code(v_codes[2], true) j;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [SP8] M7 (computer table) previewing X was refused: %.', v_msg;
  end if;
  if v_j.outcome is distinct from 'preview' or v_j.seat is not null
     or exists (select 1 from public.table_members tm where tm.table_id = v_x and tm.user_id = v_m7)
     or not exists (select 1 from public.tables t where t.id = v_ct[7] and t.status = 'open')
     or (select count(*) from public.table_members tm where tm.table_id = v_ct[7]) <> 2
     or exists (select 1 from public.attempt_log al where al.user_id = v_m7 and al.action = 'join') then
    raise exception 'FAIL [SP8] M7 (computer table) previewing X: got %; expected preview, not seated at X, the computer table open with both seats, no join row.', v_j;
  end if;
  v_checks := v_checks + 1;

  -- [SP9] (f) M8, computer table (live game), joins A's FULL table: refused,
  -- and the computer table and its game untouched.
  perform set_config('request.jwt.claims', json_build_object('sub', v_m8, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.join_table_by_code(v_a_code);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'This table is full.'
     or exists (select 1 from public.table_members tm where tm.table_id = v_a_table and tm.user_id = v_m8)
     or not exists (select 1 from public.tables t where t.id = v_ct[8] and t.status = 'open')
     or (select count(*) from public.table_members tm where tm.table_id = v_ct[8]) <> 2
     or not exists (select 1 from public.games g where g.table_id = v_ct[8] and g.status in ('cutting', 'active'))
     or exists (select 1 from public.attempt_log al where al.user_id = v_m8 and al.action = 'join') then
    raise exception 'FAIL [SP9] M8 (computer table, live game) joining a full table: "%"; expected "This table is full.", not seated, the computer table open with both seats and a live game, no join row.', coalesce(v_msg, 'joined');
  end if;
  v_checks := v_checks + 1;

  -- [SP10] (g) M9 and M10 play the same computer at once.
  v_ms := array[v_m9, v_m10];
  v_ct := '{}';
  for v_i in 1 .. 2 loop
    select lpad(n::text, 4, '0') into v_free from generate_series(0, 9999) n
    -- Codes no OPEN table holds -- every table while the old unique key
    -- exists (before step 3 slice B part 2 frees ended tables' codes).
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                        and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null)) order by n limit 1;
    perform set_config('request.jwt.claims', json_build_object('sub', v_ms[v_i], 'role', 'authenticated')::text, true);
    v_msg := null; v_tid := null; v_game := null;
    execute 'set local role authenticated';
    begin
      select r.table_id into v_tid from public.create_computer_table('easy', v_free) r;
      v_game := public.start_game_with_deal(v_tid);
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_msg is not null or v_tid is null or v_game is null then
      raise exception 'FAIL [SP10] M% starting an easy computer game and a live game while the computer is seated elsewhere: %.', 8 + v_i, coalesce(v_msg, 'no table or game');
    end if;
    v_ct := v_ct || v_tid;
  end loop;
  -- The easy computer's open seats now: K's, S3's, M5's new one, M6's, M7's,
  -- M8's, M9's and M10's tables (8 from this run alone).
  select count(*) into v_n
  from public.table_members tm join public.tables t on t.id = tm.table_id
  where tm.user_id = v_comp and t.status <> 'ended';
  if (select count(*) from public.tables t where t.id = any (v_ct) and t.status = 'open') <> 2
     or (select count(*) from public.games g where g.table_id = any (v_ct) and g.status in ('cutting', 'active')) <> 2
     or (select count(*) from public.table_members tm where tm.table_id = any (v_ct) and tm.user_id = v_comp) <> 2
     or v_n < 8 then
    raise exception 'FAIL [SP10] M9 and M10 against the same computer: both tables open %, both games live %, the computer at both %, the computer at % open tables (expected at least 8).',
      (select count(*) from public.tables t where t.id = any (v_ct) and t.status = 'open'),
      (select count(*) from public.games g where g.table_id = any (v_ct) and g.status in ('cutting', 'active')),
      (select count(*) from public.table_members tm where tm.table_id = any (v_ct) and tm.user_id = v_comp),
      v_n;
  end if;
  v_checks := v_checks + 1;

  -- ==== THE LOCKDOWN (join-create-lockdown.sql) ============================================
  -- [L0] Applied, half-applied or not yet?
  select count(*) into v_n
  from pg_attribute a
  where a.attrelid in ('public.tables'::regclass, 'public.table_members'::regclass) and a.attnum > 0 and not a.attisdropped
    and (has_column_privilege('authenticated', a.attrelid, a.attname::text, 'INSERT')
         or has_column_privilege('anon', a.attrelid, a.attname::text, 'INSERT'));
  if v_n = 0
     and not has_table_privilege('authenticated', 'public.tables', 'INSERT')
     and not has_table_privilege('authenticated', 'public.table_members', 'INSERT') then
    v_lockdown := 'applied, L checks passed';
    v_checks := v_checks + 1;

    -- [L1] [L2] Direct inserts: permission denied.
    select lpad(n::text, 4, '0') into v_free from generate_series(0, 9999) n
    -- Codes no OPEN table holds -- every table while the old unique key
    -- exists (before step 3 slice B part 2 frees ended tables' codes).
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                        and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null)) order by n limit 1;
    perform set_config('request.jwt.claims', json_build_object('sub', v_l, 'role', 'authenticated')::text, true);
    v_state := null;
    execute 'set local role authenticated';
    begin
      insert into public.tables (code, created_by) values (v_free, v_l);
    exception when others then
      v_state := sqlstate;
    end;
    execute 'reset role';
    if v_state is distinct from '42501' then
      raise exception 'FAIL [L1] L''s direct insert into tables: %; expected 42501.', coalesce(v_state, 'inserted');
    end if;
    v_checks := v_checks + 1;
    v_state := null;
    execute 'set local role authenticated';
    begin
      insert into public.table_members (table_id, user_id) values (v_w, v_l);
    exception when others then
      v_state := sqlstate;
    end;
    execute 'reset role';
    if v_state is distinct from '42501' then
      raise exception 'FAIL [L2] L''s direct insert into table_members: %; expected 42501.', coalesce(v_state, 'inserted');
    end if;
    v_checks := v_checks + 1;

    -- [L3] The RPCs still work (and every K/J/R check above already ran
    -- under the lockdown).
    v_msg := null; v_tid := null;
    execute 'set local role authenticated';
    begin
      select r.table_id into v_tid from public.create_table(true, false, 2, null, false) r;
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_msg is not null or not exists (select 1 from public.table_members tm where tm.table_id = v_tid and tm.user_id = v_l) then
      raise exception 'FAIL [L3] L''s create_table under the lockdown: %; expected created and seated.', coalesce(v_msg, 'no seat');
    end if;
    v_checks := v_checks + 1;
  elsif v_n > 0
        and not has_table_privilege('authenticated', 'public.tables', 'INSERT')
        and has_column_privilege('authenticated', 'public.tables', 'code', 'INSERT')
        and has_column_privilege('authenticated', 'public.table_members', 'user_id', 'INSERT') then
    v_lockdown := 'NOT applied yet (L checks skipped; the column INSERT grants are still there)';
  else
    raise exception 'FAIL [L0] the INSERT grants on tables/table_members are neither the pre-lockdown column grants nor none (% column grants left; table-wide on tables %, on table_members %): a half-applied lockdown?',
      v_n, has_table_privilege('authenticated', 'public.tables', 'INSERT'), has_table_privilege('authenticated', 'public.table_members', 'INSERT');
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back). Lockdown: %.', v_checks, v_lockdown;
end;
$$;
