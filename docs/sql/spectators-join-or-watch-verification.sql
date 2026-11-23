-- Spectator seat, slice 2: VERIFICATION of docs/sql/spectators-join-or-watch.sql.
--
-- Run in the Supabase Dashboard -> SQL Editor after
-- docs/sql/spectators-join-or-watch.sql. The whole file is ONE DO block.
--
-- STATUS: run in Supabase on 2026-11-20; verified (ALL 32 CHECKS PASSED, rolled back).
-- W10 and E1 rewritten on 2026-11-23 for step 3 slice A (docs/sql/join-create.sql);
-- still 32 checks; NOT RUN since.
--
-- It WRITES -- eight temporary accounts in auth.users, test tables, their
-- seats, a game row, spectator rows, and a few UPDATEs of one existing
-- profile row (avatar_url, every one of them either refused or rolled back)
-- -- and then deliberately raises an exception at the very end, which rolls
-- EVERY write back. A check that fails raises its own exception at once,
-- which rolls everything back the same way. It always "fails": the message
-- is the verdict (the dashboard hides notices).
--   "ALL n CHECKS PASSED (rolled back)." is a pass.
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives. It creates no functions,
-- tables or other schema objects. Same impersonation as the other suites:
-- request.jwt.claims plus "set local role authenticated", and "reset role"
-- to act as the owner between steps. "now()" is frozen inside a DO block, so
-- "stale" (not seen for 90 s) is made by moving last_seen_at back 91
-- seconds as the owner, and "refreshed" means last_seen_at = now().
--
-- PEOPLE: A (creates every table; seated, so the host), B (seated), S1..S5
-- (would-be spectators), N (a sixth would-be spectator).
-- TABLES (codes are free 4-digit codes):
--   W  open, allows spectators, A and B seated, NO game  (the waiting room)
--   Z  open, does NOT allow spectators, no game
--   E  allows spectators, ENDED
--   K  a computer table
--   X  open, allows spectators, a game in the cut (the live-game path)
--
-- WHAT IT CHECKS
--   CATALOG
--   (SETUP guard, not counted: watch_table no longer has the "no game"
--       refusal; if it still does, the run stops with "SETUP".)
--   C1  both functions are still security definer, volatile, search_path '',
--       EXECUTE for authenticated only (not anon, not service_role, no
--       PUBLIC grant).
--   C2  profiles_avatar_url_project_storage exists and is validated.
--   THE WAITING ROOM (W, no game)
--   W1  S1 watches W: (W's id, its code, NULL game id) and a fresh row.
--   W2  S2, S3, S4 watch W: 4 current spectators.
--   W3  S5 is refused: "Spectators full: this table already has 4
--       spectators." and gets no row (the cap holds with no game).
--   W4  A (the host) removes S3; S3 cannot watch again ("You were removed
--       from watching this table.").
--   W5  S5 now watches W (a removed spectator doesn't count toward the cap).
--   W6  A (seated) watching W: "You are seated at this table."
--   W7  Z: "This table does not allow spectators." (no game)
--   W8  E: "This table has ended."   W9  K: "Computer tables cannot be
--       watched."   W10 an unknown code: NO ROW and no error, and one
--       wrong code counted (since step 3 slice A, docs/sql/join-create.sql:
--       an exception would undo the count; it used to raise "No table found
--       with code ...").
--   W11 nobody signed in: "You must be logged in to watch a table."
--   THE HEARTBEAT WITH NO GAME
--   H1  S1 (seen 60 s ago): 'game_ended', and last_seen_at refreshed.
--   H2  S4 stale, a place free: 'game_ended', refreshed (the place is back).
--   H3  S2 stale, N takes the place, 4 others current: S2's heartbeat is
--       'not_watching' and the row is NOT refreshed.
--   H4  S3 (removed): 'removed'.
--   H5  get_spectator_reveals(null) is null (no error).
--   THE LIVE-GAME PATH STILL WORKS (X)
--   L1  S1 watches X: the live game id.   L2 S1's heartbeat: 'ok'.
--   L3  X's game ends: S1 (seen 60 s ago) gets 'game_ended', refreshed.
--   L4  S2 can still watch X afterwards, with a NULL game id.
--   L5  get_spectator_reveals of the ended game is null.
--   ENDED TABLE
--   E1  W ends: S5's heartbeat is 'table_ended'; E2 watching W: "This table
--       has ended." (S5, not S1: since step 3 slice A, S1 watching X in L1
--       ended S1's watching of W -- one table at a time -- so S1's heartbeat
--       at W would be 'not_watching'.)
--   AVATAR ADDRESSES (on one existing profile row)
--   A1-A6  six bad addresses (another host, a look-alike host, http, a
--          javascript: address, another bucket, a ".." path) are refused
--          (23514).
--   A7  NULL, '', a project avatar address with ?t=, a computers/ one are
--       accepted.
--
-- Expected message:
--   ALL 32 CHECKS PASSED (rolled back).

do $$
declare
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_s1 uuid := gen_random_uuid();
  v_s2 uuid := gen_random_uuid();
  v_s3 uuid := gen_random_uuid();
  v_s4 uuid := gen_random_uuid();
  v_s5 uuid := gen_random_uuid();
  v_nn uuid := gen_random_uuid();
  v_codes text[];
  v_w uuid;
  v_z uuid;
  v_e uuid;
  v_k uuid;
  v_x uuid;
  v_gx uuid;
  v_r_table uuid;
  v_r_code text;
  v_r_game uuid;
  v_msg text;
  v_txt text;
  v_n int;
  v_j jsonb;
  v_pid uuid;
  v_state text;
  v_ls timestamptz;
  v_checks int := 0;
  v_rec record;
  v_bad text;
begin
  -- ==== CATALOG ===============================================================
  if to_regprocedure('public.watch_table(text)') is null
     or to_regprocedure('public.spectator_heartbeat(uuid)') is null then
    raise exception 'SETUP: the spectator functions do not exist. Run docs/sql/spectators.sql first.';
  end if;

  select p.prosrc into v_txt from pg_proc p where p.oid = to_regprocedure('public.watch_table(text)');
  if v_txt ilike '%no game to watch%' then
    raise exception 'SETUP: watch_table still has the old "no game" refusal. Run docs/sql/spectators-join-or-watch.sql first.';
  end if;

  -- [C1] Shape and grants of the two functions.
  for v_rec in
    select * from (values
      ('public.watch_table(text)'),
      ('public.spectator_heartbeat(uuid)')
    ) as t(fn)
  loop
    select p.prosecdef::text || ' ' || p.provolatile::text || ' '
           || case when coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']
                   then 'empty-path' else 'path:' || coalesce(p.proconfig::text, 'none') end
    into v_txt
    from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is distinct from 'true v empty-path' then
      raise exception 'FAIL [C1] % is "%"; expected "true v empty-path" (security definer, volatile, search_path empty).', v_rec.fn, v_txt;
    end if;

    select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = to_regprocedure(v_rec.fn) and a.grantee = 0;
    if v_n <> 0
       or not has_function_privilege('authenticated', to_regprocedure(v_rec.fn), 'EXECUTE')
       or has_function_privilege('anon', to_regprocedure(v_rec.fn), 'EXECUTE')
       or (exists (select 1 from pg_roles r where r.rolname = 'service_role')
           and has_function_privilege('service_role', to_regprocedure(v_rec.fn), 'EXECUTE')) then
      raise exception 'FAIL [C1] EXECUTE grants on % are wrong: expected authenticated only (PUBLIC grants: %).', v_rec.fn, v_n;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- [C2] The avatar check exists and is validated.
  select pg_get_constraintdef(c.oid) || ' validated=' || c.convalidated::text into v_txt
  from pg_constraint c
  where c.conrelid = 'public.profiles'::regclass and c.conname = 'profiles_avatar_url_project_storage' and c.contype = 'c';
  if v_txt is null or v_txt not ilike '%storage/v1/object/public/avatars/%' or v_txt not ilike '%validated=true' then
    raise exception 'FAIL [C2] profiles_avatar_url_project_storage is "%"; expected the avatars-path CHECK, validated.', coalesce(v_txt, 'missing');
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner ====================================================
  begin
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
      (v_a,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'jw-a-'  || v_a::text  || '@verification.invalid', now() - interval '8 minutes', now()),
      (v_b,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'jw-b-'  || v_b::text  || '@verification.invalid', now() - interval '7 minutes', now()),
      (v_s1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'jw-s1-' || v_s1::text || '@verification.invalid', now() - interval '6 minutes', now()),
      (v_s2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'jw-s2-' || v_s2::text || '@verification.invalid', now() - interval '5 minutes', now()),
      (v_s3, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'jw-s3-' || v_s3::text || '@verification.invalid', now() - interval '4 minutes', now()),
      (v_s4, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'jw-s4-' || v_s4::text || '@verification.invalid', now() - interval '3 minutes', now()),
      (v_s5, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'jw-s5-' || v_s5::text || '@verification.invalid', now() - interval '2 minutes', now()),
      (v_nn, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'jw-n-'  || v_nn::text || '@verification.invalid', now() - interval '1 minute', now());
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts in auth.users: % (%).', sqlerrm, sqlstate;
  end;

  -- Six free codes: W, Z, E, K, X, and one left unused (an unknown code).
  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0'))
    order by n
    limit 6
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 6 then
    raise exception 'SETUP: fewer than six unused table codes.';
  end if;

  begin
    -- Members one at a time, so the seat trigger seats them in order.
    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[1], v_a, true, true) returning id into v_w;
    insert into public.table_members (table_id, user_id) values (v_w, v_a);
    insert into public.table_members (table_id, user_id) values (v_w, v_b);

    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[2], v_a, true, false) returning id into v_z;
    insert into public.table_members (table_id, user_id) values (v_z, v_a);
    insert into public.table_members (table_id, user_id) values (v_z, v_b);

    -- Seated first, then ended: the way a Force-End leaves a table.
    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[3], v_a, true, true) returning id into v_e;
    insert into public.table_members (table_id, user_id) values (v_e, v_a);
    insert into public.table_members (table_id, user_id) values (v_e, v_b);
    update public.tables set status = 'ended', ended_reason = 'admin' where id = v_e;

    insert into public.tables (code, created_by, computer_level) values (v_codes[4], v_a, 'easy') returning id into v_k;
    insert into public.table_members (table_id, user_id) values (v_k, v_a);

    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[5], v_a, true, true) returning id into v_x;
    insert into public.table_members (table_id, user_id) values (v_x, v_a);
    insert into public.table_members (table_id, user_id) values (v_x, v_b);
    -- A game in the cut at X (dated an hour back, as the other suites do).
    insert into public.games (table_id, created_by, status, players, deal_cut, created_at)
    values (v_x, v_a, 'cutting', array[v_a, v_b], '[[]]'::jsonb, now() - interval '1 hour')
    returning id into v_gx;
  exception when others then
    raise exception 'SETUP: could not create the test tables, seats and game: % (%).', sqlerrm, sqlstate;
  end;

  -- ==== THE WAITING ROOM (W, no game) ===========================================
  -- [W1] S1 watches W: the table, its code, a NULL game id, a fresh row.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  v_msg := null; v_r_table := null; v_r_code := null; v_r_game := null;
  execute 'set local role authenticated';
  begin
    select w.table_id, w.code, w.game_id into v_r_table, v_r_code, v_r_game from public.watch_table(v_codes[1]) w;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_r_table is distinct from v_w or v_r_code is distinct from v_codes[1] or v_r_game is not null
     or not exists (select 1 from public.table_spectators ts
                    where ts.table_id = v_w and ts.user_id = v_s1 and ts.removed_at is null and ts.last_seen_at = now()) then
    raise exception 'FAIL [W1] S1 watching the waiting room: error %, got (%, %, %); expected (%, %, NULL) and a fresh row.',
      coalesce(v_msg, 'none'), v_r_table, v_r_code, v_r_game, v_w, v_codes[1];
  end if;
  v_checks := v_checks + 1;

  -- [W2] S2, S3, S4 watch W: 4 current.
  foreach v_pid in array array[v_s2, v_s3, v_s4] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_pid, 'role', 'authenticated')::text, true);
    v_msg := null;
    execute 'set local role authenticated';
    begin
      perform 1 from public.watch_table(v_codes[1]);
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_msg is not null then
      raise exception 'FAIL [W2] % watching the waiting room was refused: %.', v_pid, v_msg;
    end if;
  end loop;
  select count(*) into v_n from public.table_spectators ts
  where ts.table_id = v_w and ts.removed_at is null and ts.last_seen_at > now() - interval '90 seconds';
  if v_n <> 4 then
    raise exception 'FAIL [W2] W has % current spectators; expected 4.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [W3] The fifth is refused, with no row.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s5, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'Spectators full: this table already has 4 spectators.'
     or exists (select 1 from public.table_spectators ts where ts.table_id = v_w and ts.user_id = v_s5) then
    raise exception 'FAIL [W3] S5 as the fifth spectator with no game: %; expected "Spectators full: this table already has 4 spectators." and no row.',
      coalesce(v_msg, 'allowed');
  end if;
  v_checks := v_checks + 1;

  -- [W4] A (the host) removes S3; S3 cannot watch again.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform public.remove_spectator(v_w, v_s3);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [W4] A removing S3 at the waiting room: %.', v_msg;
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_s3, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'You were removed from watching this table.' then
    raise exception 'FAIL [W4] removed S3 watching W again: %; expected "You were removed from watching this table."', coalesce(v_msg, 'allowed');
  end if;
  v_checks := v_checks + 1;

  -- [W5] S5 now gets in (S3's removed row does not count toward the cap).
  perform set_config('request.jwt.claims', json_build_object('sub', v_s5, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [W5] S5 watching W after S3 was removed: %.', v_msg;
  end if;
  v_checks := v_checks + 1;

  -- [W6] A is seated at W: refused even with no game.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'You are seated at this table.' then
    raise exception 'FAIL [W6] seated A watching W: %; expected "You are seated at this table."', coalesce(v_msg, 'allowed');
  end if;
  v_checks := v_checks + 1;

  -- [W7]-[W9] The other refusals keep their messages (S1 asking each time).
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  for v_rec in
    select * from (values
      ('W7', v_codes[2], 'This table does not allow spectators.'),
      ('W8', v_codes[3], 'This table has ended.'),
      ('W9', v_codes[4], 'Computer tables cannot be watched.')
    ) as t(label, code, want)
  loop
    v_msg := null;
    execute 'set local role authenticated';
    begin
      perform 1 from public.watch_table(v_rec.code);
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_msg is distinct from v_rec.want then
      raise exception 'FAIL [%] watching code %: "%"; expected "%".', v_rec.label, v_rec.code, coalesce(v_msg, 'allowed'), v_rec.want;
    end if;
    v_checks := v_checks + 1;
  end loop;

  -- [W10] An unknown code: no row, no error, one wrong code counted (step 3
  -- slice A: watch_table returns nothing instead of raising, so the count
  -- survives; the app shows "No table found with code ...").
  v_msg := null; v_n := null;
  execute 'set local role authenticated';
  begin
    select count(*) into v_n from public.watch_table(v_codes[6]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_n is distinct from 0
     or (select count(*) from public.attempt_log al where al.user_id = v_s1 and al.action = 'code_guess' and not al.success) <> 1 then
    raise exception 'FAIL [W10] watching the unknown code %: error %, % row(s); expected no error, no row and one wrong code counted.',
      v_codes[6], coalesce(v_msg, 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [W11] Nobody signed in.
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'You must be logged in to watch a table.' then
    raise exception 'FAIL [W11] nobody signed in: "%"; expected "You must be logged in to watch a table."', coalesce(v_msg, 'allowed');
  end if;
  v_checks := v_checks + 1;

  -- ==== THE HEARTBEAT WITH NO GAME ==============================================
  -- [H1] S1, seen 60 s ago: 'game_ended', and the place is refreshed.
  update public.table_spectators set last_seen_at = now() - interval '60 seconds'
  where table_id = v_w and user_id = v_s1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_txt := public.spectator_heartbeat(v_w);
  execute 'reset role';
  select ts.last_seen_at into v_ls from public.table_spectators ts where ts.table_id = v_w and ts.user_id = v_s1;
  if v_txt is distinct from 'game_ended' or v_ls is distinct from now() then
    raise exception 'FAIL [H1] S1''s heartbeat with no game: % (last_seen_at %); expected game_ended and last_seen_at = now().', v_txt, v_ls;
  end if;
  v_checks := v_checks + 1;

  -- [H2] S4 stale, but a place is free (S1, S2, S5 current): 'game_ended', refreshed.
  update public.table_spectators set last_seen_at = now() - interval '91 seconds'
  where table_id = v_w and user_id = v_s4;
  perform set_config('request.jwt.claims', json_build_object('sub', v_s4, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_txt := public.spectator_heartbeat(v_w);
  execute 'reset role';
  select ts.last_seen_at into v_ls from public.table_spectators ts where ts.table_id = v_w and ts.user_id = v_s4;
  if v_txt is distinct from 'game_ended' or v_ls is distinct from now() then
    raise exception 'FAIL [H2] stale S4''s heartbeat with a free place and no game: % (last_seen_at %); expected game_ended and the place back.', v_txt, v_ls;
  end if;
  v_checks := v_checks + 1;

  -- [H3] S2 goes stale, N takes the place; S2's heartbeat: 'not_watching', not refreshed.
  update public.table_spectators set last_seen_at = now() - interval '91 seconds'
  where table_id = v_w and user_id = v_s2;
  perform set_config('request.jwt.claims', json_build_object('sub', v_nn, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [H3] N watching W after S2 went stale: %.', v_msg;
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_s2, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_txt := public.spectator_heartbeat(v_w);
  execute 'reset role';
  select ts.last_seen_at into v_ls from public.table_spectators ts where ts.table_id = v_w and ts.user_id = v_s2;
  if v_txt is distinct from 'not_watching' or v_ls > now() - interval '90 seconds' then
    raise exception 'FAIL [H3] stale S2''s heartbeat with 4 others current: % (last_seen_at %); expected not_watching and the row left stale.', v_txt, v_ls;
  end if;
  v_checks := v_checks + 1;

  -- [H4] S3 was removed.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s3, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_txt := public.spectator_heartbeat(v_w);
  execute 'reset role';
  if v_txt is distinct from 'removed' then
    raise exception 'FAIL [H4] removed S3''s heartbeat: %; expected removed.', v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [H5] get_spectator_reveals(null) is null, not an error.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    v_j := public.get_spectator_reveals(null);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_j is not null then
    raise exception 'FAIL [H5] get_spectator_reveals(null): error %, value %; expected null.', coalesce(v_msg, 'none'), v_j;
  end if;
  v_checks := v_checks + 1;

  -- ==== THE LIVE-GAME PATH STILL WORKS (X) ======================================
  -- [L1] S1 watches X: the live game id.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  v_msg := null; v_r_table := null; v_r_game := null;
  execute 'set local role authenticated';
  begin
    select w.table_id, w.game_id into v_r_table, v_r_game from public.watch_table(v_codes[5]) w;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_r_table is distinct from v_x or v_r_game is distinct from v_gx then
    raise exception 'FAIL [L1] S1 watching X with a live game: error %, got (%, %); expected (%, %).',
      coalesce(v_msg, 'none'), v_r_table, v_r_game, v_x, v_gx;
  end if;
  v_checks := v_checks + 1;

  -- [L2] S1's heartbeat at X: 'ok'.
  execute 'set local role authenticated';
  v_txt := public.spectator_heartbeat(v_x);
  execute 'reset role';
  if v_txt is distinct from 'ok' then
    raise exception 'FAIL [L2] S1''s heartbeat with a live game: %; expected ok.', v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [L3] X's game ends: S1 (seen 60 s ago) gets 'game_ended' and a refresh.
  update public.games set status = 'ended', ended_reason = 'admin' where id = v_gx;
  update public.table_spectators set last_seen_at = now() - interval '60 seconds'
  where table_id = v_x and user_id = v_s1;
  execute 'set local role authenticated';
  v_txt := public.spectator_heartbeat(v_x);
  execute 'reset role';
  select ts.last_seen_at into v_ls from public.table_spectators ts where ts.table_id = v_x and ts.user_id = v_s1;
  if v_txt is distinct from 'game_ended' or v_ls is distinct from now() then
    raise exception 'FAIL [L3] S1''s heartbeat after the game ended: % (last_seen_at %); expected game_ended and last_seen_at = now().', v_txt, v_ls;
  end if;
  v_checks := v_checks + 1;

  -- [L4] S2 can still watch X after the game, with a NULL game id.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s2, 'role', 'authenticated')::text, true);
  v_msg := null; v_r_game := gen_random_uuid();
  execute 'set local role authenticated';
  begin
    select w.game_id into v_r_game from public.watch_table(v_codes[5]) w;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_r_game is not null then
    raise exception 'FAIL [L4] S2 watching X after its game ended: error %, game id %; expected a row with a NULL game id.',
      coalesce(v_msg, 'none'), v_r_game;
  end if;
  v_checks := v_checks + 1;

  -- [L5] An ended game reveals nothing to a spectator.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_j := public.get_spectator_reveals(v_gx);
  execute 'reset role';
  if v_j is not null then
    raise exception 'FAIL [L5] get_spectator_reveals of an ended game returned %; expected null.', v_j;
  end if;
  v_checks := v_checks + 1;

  -- ==== ENDED TABLE ===============================================================
  update public.tables set status = 'ended', ended_reason = 'admin' where id = v_w;
  -- [E1] S5's heartbeat at W (S5 still has a place there; S1 moved to X).
  perform set_config('request.jwt.claims', json_build_object('sub', v_s5, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_txt := public.spectator_heartbeat(v_w);
  execute 'reset role';
  if v_txt is distinct from 'table_ended' then
    raise exception 'FAIL [E1] S5''s heartbeat at an ended table: %; expected table_ended.', v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [E2] Watching W now.
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'This table has ended.' then
    raise exception 'FAIL [E2] watching the ended table W: "%"; expected "This table has ended."', coalesce(v_msg, 'allowed');
  end if;
  v_checks := v_checks + 1;

  -- ==== AVATAR ADDRESSES (one existing profile row, as the owner) ================
  select p.id into v_pid from public.profiles p order by p.id limit 1;
  if v_pid is null then
    raise exception 'SETUP: no profile row exists to test the avatar check on.';
  end if;

  -- [A1]-[A6] Refused addresses.
  for v_rec in
    select * from (values
      ('A1', 'https://evil.example.com/a.png'),
      ('A2', 'https://forkgkkglcsvqoybdqcr.supabase.co.evil.com/storage/v1/object/public/avatars/a.png'),
      ('A3', 'http://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/avatars/a.png'),
      ('A4', 'javascript:alert(1)'),
      ('A5', 'https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/other-bucket/a.png'),
      ('A6', 'https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/avatars/../other-bucket/a.png')
    ) as t(label, url)
  loop
    v_state := null;
    begin
      update public.profiles set avatar_url = v_rec.url where id = v_pid;
    exception when others then
      v_state := sqlstate;
    end;
    if v_state is distinct from '23514' then
      raise exception 'FAIL [%] avatar_url "%": %; expected 23514 (check violation).', v_rec.label, v_rec.url, coalesce(v_state, 'accepted');
    end if;
    v_checks := v_checks + 1;
  end loop;

  -- [A7] Accepted values (all rolled back with everything else).
  for v_rec in
    select * from (values
      (null::text),
      (''),
      ('https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/avatars/00000000-0000-0000-0000-000000000000/avatar.png?t=1760000000000'),
      ('https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/avatars/computers/Rainman.png')
    ) as t(url)
  loop
    v_state := null;
    begin
      update public.profiles set avatar_url = v_rec.url where id = v_pid;
    exception when others then
      v_state := sqlstate;
    end;
    if v_state is not null then
      raise exception 'FAIL [A7] avatar_url "%" was refused: %; expected accepted.', coalesce(v_rec.url, 'NULL'), v_state;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back).', v_checks;
end;
$$;
