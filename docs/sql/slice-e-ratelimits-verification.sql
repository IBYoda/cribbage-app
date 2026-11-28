-- Step 3, slice E: VERIFICATION of the new limits (docs/sql/slice-e-part2.sql):
-- the games cap, the nickname lock and the follow churn limit.
--
-- Run in the Supabase Dashboard -> SQL Editor after slice-e-part2.sql.
-- The whole file is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
-- Re-run 2026-11-28 after nickname rules: 20 / 12 / clean (slice-e-ratelimits / slice-e-grants / slice-e-precheck).
-- STATE-AWARE EDIT (nickname rules, 2026-11-28): N4. Once
-- docs/sql/nickname-rules-part1.sql is in, a nickname with leading or
-- trailing spaces is refused (nickname_invalid) and never trimmed, so N4
-- sends the re-cased name without the added spaces, and also checks the
-- spaced one is refused and changes nothing. Before that slice, N4 is as it
-- was. Still 20 checks.
--
-- It WRITES -- temporary accounts in auth.users and their profiles (58 of
-- them: 51 are follow targets), test tables, seats, games, follows and
-- attempt_log rows; it calls start_game_with_deal(_as),
-- computer_start_game_with_deal, create_computer_table, follow_user and
-- unfollow_user -- and then deliberately raises an exception at the very
-- end, which rolls EVERY write back. A check that fails raises its own
-- exception at once, which rolls everything back the same way. It always
-- "fails": the message is the verdict (the dashboard hides notices).
--   "ALL 20 CHECKS PASSED (rolled back)." is a pass.
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives. now() is frozen inside a
-- DO block, so "an hour ago" and "7 days ago" are made by moving
-- attempt_log.created_at and profiles.nickname_changed_at back as the owner.
-- Same impersonation as the other suites: request.jwt.claims plus "set
-- local role authenticated", and "reset role" to act as the owner.
--
-- PEOPLE (temporary accounts): A and B (the 2-player table T1), A2 and B2
-- (the rematch table T2), H (a computer table), N and N2 (nicknames), X, Y,
-- Z and Q (follows), and 51 follow targets with nicknames.
--
-- WHAT IT CHECKS
--   C1  part 2 is in: start_game_with_deal_as, _follow_user_as and
--       unfollow_user have part 2's bodies; profiles_nickname_lock is an
--       enabled BEFORE INSERT OR UPDATE row trigger whose function no client
--       role can execute; attempt_log allows game_start and follow_change.
--   C2  leave_table, end_timed_out_sessions, assign_table_seat, table_host:
--       body md5 unchanged.
--   G1  A starts 30 games at T1 (each ended as the owner before the next):
--       all allowed; 30 game_start rows for A.
--   G2  A's 31st start, through start_game_with_deal as A: refused, SQLSTATE
--       P0001, detail rate_limited, the friendly message; no game created,
--       still 30 rows.
--   G3  B, at the same table, is not affected: B's start is allowed.
--   G4  A's 30 rows moved back 61 minutes: A may start again.
--   G5  a computer game: H's computer table; with 30 game_start rows for H in
--       the last hour, the computer's own tap (computer_start_game_with_deal
--       as H) is refused rate_limited; with 29 it is allowed, H then has 30,
--       and the computer account got no row.
--   G6  only a call that CREATES a game counts: after a won game at T2, A2's
--       ready tap (recorded, waiting) counts nothing; B2's tap starts the
--       rematch and counts once, for B2.
--   N1  the first nickname (from '') through the app's upsert: allowed, and
--       nickname_changed_at stays null.
--   N2  the next real change (null lock): allowed, stamped now().
--   N3  the next real change within 7 days: refused through the upsert,
--       SQLSTATE P0001, detail nickname_locked, "You can change your nickname
--       again in 7 days."; the nickname is unchanged.
--   N4  the same nickname in another case and spacing: allowed, not counted
--       (nickname_changed_at unchanged). With the nickname rules in: the
--       same nickname in another case only; the spaced one is refused
--       (nickname_invalid), nickname and changed_at unchanged.
--   N5  the client cannot rewrite nickname_changed_at (a direct update, and
--       an upsert sending an old date with a new nickname: still refused).
--   N6  nickname_changed_at moved back 7 days and a minute (as the owner):
--       the change is allowed and stamped now().
--   N7  a brand-new row through the upsert's INSERT path, sending a
--       nickname_changed_at: stored as null.
--   N8  the owner (the SQL Editor) is not limited: it changes a locked
--       nickname.
--   F1  the cap of 50: with 50 follows, X's 51st follow_user returns limit
--       and counts nothing.
--   F2  30 real changes (15 follows, 15 unfollows) by Y are allowed; the 31st
--       (a follow) is refused rate_limited and writes no follow.
--   F3  a real unfollow at the limit is refused too (Q, 30 rows already): the
--       follow stays.
--   F4  no-ops count nothing: Z follows T1 (1), follows T1 again, unfollows
--       T2 (not followed), follows itself (not_allowed): 1 row.
--
-- Expected message:
--   ALL 20 CHECKS PASSED (rolled back).

do $$
declare
  v_checks int := 0;
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_a2 uuid := gen_random_uuid();
  v_b2 uuid := gen_random_uuid();
  v_h uuid := gen_random_uuid();
  v_n uuid := gen_random_uuid();
  v_n2 uuid := gen_random_uuid();
  v_x uuid := gen_random_uuid();
  v_y uuid := gen_random_uuid();
  v_z uuid := gen_random_uuid();
  v_q uuid := gen_random_uuid();
  v_targets uuid[] := '{}';
  v_people uuid[];
  v_pid uuid;
  v_codes text[];
  v_t1 uuid;
  v_t2 uuid;
  v_ct uuid;
  v_g uuid;
  v_comp uuid;
  v_rec record;
  v_txt text;
  v_msg text;
  v_state text;
  v_detail text;
  v_n_rows int;
  v_n2_rows int;
  v_when timestamptz;
  v_rules boolean := to_regprocedure('public.profiles_nickname_rules()') is not null;
  v_games_msg text := 'You have started 30 games in the last hour. Please take a break and try again a little later.';
  v_follow_msg text := 'You have changed who you follow 30 times in the last hour. Please try again a little later.';
begin
  -- ==== CATALOG ===================================================================
  -- [C1] Part 2 is in.
  select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure('public.start_game_with_deal_as(uuid, uuid)');
  if v_txt is distinct from '8b4528a51247b63a47b36bd703f81492' then
    raise exception 'SETUP: start_game_with_deal_as is not slice-e-part2.sql''s body (md5 %). Run part 2 first.', coalesce(v_txt, 'missing');
  end if;
  select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure('public._follow_user_as(uuid, uuid, integer)');
  select md5(replace(p.prosrc, E'\r', '')) into v_msg from pg_proc p where p.oid = to_regprocedure('public.unfollow_user(uuid)');
  if v_txt is distinct from '0996790bb0c497cdf8cb775a2fb3e22e' or v_msg is distinct from 'be4ba2a18fb61605135205713be00f07' then
    raise exception 'FAIL [C1] _follow_user_as / unfollow_user md5 % / %; expected part 2''s 0996790bb0c497cdf8cb775a2fb3e22e / be4ba2a18fb61605135205713be00f07.', v_txt, v_msg;
  end if;
  select case when (tg.tgtype & 2) = 2 then 'BEFORE' else 'AFTER' end
         || case when (tg.tgtype & 4) = 4 then ' INSERT' else '' end
         || case when (tg.tgtype & 16) = 16 then ' UPDATE' else '' end
         || case when (tg.tgtype & 1) = 1 then ' ROW' else ' STATEMENT' end
         || '|' || tg.tgfoid::regprocedure::text || '|' || tg.tgenabled::text
  into v_txt
  from pg_trigger tg
  where tg.tgrelid = 'public.profiles'::regclass and tg.tgname = 'profiles_nickname_lock' and not tg.tgisinternal;
  if v_txt not in ('BEFORE INSERT UPDATE ROW|profiles_nickname_lock()|O', 'BEFORE INSERT UPDATE ROW|public.profiles_nickname_lock()|O')
     or v_txt is null
     or has_function_privilege('authenticated', 'public.profiles_nickname_lock()', 'EXECUTE')
     or has_function_privilege('anon', 'public.profiles_nickname_lock()', 'EXECUTE')
     or not exists (select 1 from pg_constraint con
                    where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check'
                      and pg_get_constraintdef(con.oid) ~ '''game_start''' and pg_get_constraintdef(con.oid) ~ '''follow_change''') then
    raise exception 'FAIL [C1] the nickname trigger is "%" (expected an enabled BEFORE INSERT UPDATE ROW trigger on profiles_nickname_lock(), no client EXECUTE), or attempt_log lacks game_start / follow_change.', coalesce(v_txt, 'missing');
  end if;
  v_checks := v_checks + 1;

  -- [C2] The four fingerprinted bodies, unchanged.
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
      raise exception 'FAIL [C2] % has body md5 %; expected % (LF) or % (CRLF).', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf, v_rec.crlf;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner =========================================================
  for v_i in 1..51 loop
    v_targets := v_targets || gen_random_uuid();
  end loop;
  v_people := array[v_a, v_b, v_a2, v_b2, v_h, v_n, v_n2, v_x, v_y, v_z, v_q] || v_targets;
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'se-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      -- N2 gets no profile (N7 creates it); N starts with no nickname.
      if v_pid = v_n2 then
        continue;
      end if;
      insert into public.profiles (id, nickname)
      values (v_pid, case when v_pid = v_n then '' else 'se' || left(replace(v_pid::text, '-', ''), 12) end)
      on conflict (id) do update set nickname = excluded.nickname;
    end loop;
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
    -- Codes no OPEN table holds -- every table while the old unique key
    -- exists (before step 3 slice B part 2 frees ended tables' codes).
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                        and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null))
    order by n
    limit 3
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 3 then
    raise exception 'SETUP: fewer than three free table codes.';
  end if;

  begin
    insert into public.tables (code, created_by, is_public) values (v_codes[1], v_a, false) returning id into v_t1;
    insert into public.table_members (table_id, user_id) values (v_t1, v_a);
    insert into public.table_members (table_id, user_id) values (v_t1, v_b);
    insert into public.tables (code, created_by, is_public) values (v_codes[2], v_a2, false) returning id into v_t2;
    insert into public.table_members (table_id, user_id) values (v_t2, v_a2);
    insert into public.table_members (table_id, user_id) values (v_t2, v_b2);
  exception when others then
    raise exception 'SETUP: could not create the test tables: % (%).', sqlerrm, sqlstate;
  end;

  -- ==== G: the games cap ============================================================
  -- [G1] 30 starts by A, each game ended (admin) before the next.
  for v_i in 1..30 loop
    v_g := public.start_game_with_deal_as(v_a, v_t1);
    if v_g is null then
      raise exception 'FAIL [G1] start % by A created no game.', v_i;
    end if;
    update public.games set status = 'ended', ended_reason = 'admin' where id = v_g;
  end loop;
  select count(*) into v_n_rows from public.attempt_log al where al.user_id = v_a and al.action = 'game_start';
  if v_n_rows <> 30 then
    raise exception 'FAIL [G1] A has % game_start rows after 30 starts; expected 30.', v_n_rows;
  end if;
  v_checks := v_checks + 1;

  -- [G2] The 31st, through the player's wrapper as A: refused.
  v_state := null; v_msg := null; v_detail := null;
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    perform public.start_game_with_deal(v_t1);
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
  end;
  execute 'reset role';
  select count(*) into v_n_rows from public.attempt_log al where al.user_id = v_a and al.action = 'game_start';
  select count(*) into v_n2_rows from public.games g where g.table_id = v_t1 and g.status in ('cutting', 'active');
  if v_state is distinct from 'P0001' or v_detail is distinct from 'rate_limited' or v_msg is distinct from v_games_msg
     or v_n_rows <> 30 or v_n2_rows <> 0 then
    raise exception 'FAIL [G2] A''s 31st start: % / % / "%"; % rows, % live game(s). Expected P0001 / rate_limited / "%"; 30 rows, 0 live games.',
      coalesce(v_state, 'no error'), coalesce(v_detail, '-'), coalesce(v_msg, ''), v_n_rows, v_n2_rows, v_games_msg;
  end if;
  v_checks := v_checks + 1;

  -- [G3] B, at the same table: not affected.
  begin
    v_g := public.start_game_with_deal_as(v_b, v_t1);
  exception when others then
    raise exception 'FAIL [G3] B''s start was refused: %.', sqlerrm;
  end;
  if v_g is null then
    raise exception 'FAIL [G3] B''s start created no game.';
  end if;
  update public.games set status = 'ended', ended_reason = 'admin' where id = v_g;
  v_checks := v_checks + 1;

  -- [G4] The window moves on: A's rows an hour and a minute old.
  update public.attempt_log set created_at = now() - interval '61 minutes'
  where user_id = v_a and action = 'game_start';
  begin
    v_g := public.start_game_with_deal_as(v_a, v_t1);
  exception when others then
    raise exception 'FAIL [G4] A''s start after the window was refused: %.', sqlerrm;
  end;
  select count(*) into v_n_rows from public.attempt_log al
  where al.user_id = v_a and al.action = 'game_start' and al.created_at > now() - interval '1 hour';
  if v_g is null or v_n_rows <> 1 then
    raise exception 'FAIL [G4] after the window: game %, % row(s) in the last hour; expected a game and 1.', v_g, v_n_rows;
  end if;
  update public.games set status = 'ended', ended_reason = 'admin' where id = v_g;
  v_checks := v_checks + 1;

  -- [G5] A computer game counts for the human who created the table.
  v_ct := null;
  perform set_config('request.jwt.claims', json_build_object('sub', v_h, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    select r.table_id into v_ct from public.create_computer_table('easy', v_codes[3]) r;
    execute 'reset role';
  exception when others then
    raise exception 'SETUP: H could not create a computer table: % (%).', sqlerrm, sqlstate;
  end;
  execute 'reset role';
  if v_ct is null then
    raise exception 'SETUP: create_computer_table returned no table for H.';
  end if;
  insert into public.attempt_log (user_id, action, success)
  select v_h, 'game_start', true from generate_series(1, 30);
  select count(*) into v_n2_rows from public.attempt_log al where al.user_id = v_comp and al.action = 'game_start';
  v_state := null; v_detail := null;
  perform set_config('request.jwt.claims', json_build_object('sub', v_h, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    perform public.computer_start_game_with_deal(v_ct);
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
  end;
  execute 'reset role';
  if v_state is distinct from 'P0001' or v_detail is distinct from 'rate_limited' then
    raise exception 'FAIL [G5] the computer''s start with H at 30: % / % (%); expected P0001 / rate_limited.', coalesce(v_state, 'no error'), coalesce(v_detail, '-'), coalesce(v_msg, '');
  end if;
  delete from public.attempt_log
  where id = (select min(al.id) from public.attempt_log al where al.user_id = v_h and al.action = 'game_start');
  v_g := null; v_state := null;
  begin
    execute 'set local role authenticated';
    v_g := public.computer_start_game_with_deal(v_ct);
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  execute 'reset role';
  select count(*) into v_n_rows from public.attempt_log al where al.user_id = v_h and al.action = 'game_start';
  if v_state is not null or v_g is null or v_n_rows <> 30
     or (select count(*) from public.attempt_log al where al.user_id = v_comp and al.action = 'game_start') <> v_n2_rows then
    raise exception 'FAIL [G5] the computer''s start with H at 29: error % (%), game %, H rows %, computer rows % (was %). Expected a game, H 30, the computer unchanged.',
      coalesce(v_state, 'none'), coalesce(v_msg, ''), v_g, v_n_rows,
      (select count(*) from public.attempt_log al where al.user_id = v_comp and al.action = 'game_start'), v_n2_rows;
  end if;
  v_checks := v_checks + 1;

  -- [G6] Only a call that creates a game counts: the rematch after a win.
  insert into public.games (table_id, created_by, status, ended_reason, players, winner_id, created_at)
  values (v_t2, v_a2, 'ended', 'won', array[v_a2, v_b2], v_a2, now() - interval '5 minutes');
  v_g := public.start_game_with_deal_as(v_a2, v_t2);
  select count(*) into v_n_rows from public.attempt_log al where al.user_id = v_a2 and al.action = 'game_start';
  if v_g is not null or v_n_rows <> 0 then
    raise exception 'FAIL [G6] A2''s ready tap: game %, % row(s); expected no game (waiting) and 0.', v_g, v_n_rows;
  end if;
  v_g := public.start_game_with_deal_as(v_b2, v_t2);
  select count(*) into v_n_rows from public.attempt_log al where al.user_id = v_b2 and al.action = 'game_start';
  select count(*) into v_n2_rows from public.attempt_log al where al.user_id = v_a2 and al.action = 'game_start';
  if v_g is null or v_n_rows <> 1 or v_n2_rows <> 0 then
    raise exception 'FAIL [G6] B2''s completing tap: game %, B2 % row(s), A2 %; expected the rematch, 1, 0.', v_g, v_n_rows, v_n2_rows;
  end if;
  v_checks := v_checks + 1;

  -- ==== N: the nickname lock (as N, through the app's upsert) =======================
  -- [N1] The first nickname, from '': free; nothing stamped.
  v_state := null;
  perform set_config('request.jwt.claims', json_build_object('sub', v_n, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    insert into public.profiles as pr (id, nickname) values (v_n, 'senick1' || left(v_n::text, 6))
    on conflict (id) do update set id = excluded.id, nickname = excluded.nickname;
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  execute 'reset role';
  select p.nickname, p.nickname_changed_at into v_txt, v_when from public.profiles p where p.id = v_n;
  if v_state is not null or v_txt is distinct from 'senick1' || left(v_n::text, 6) or v_when is not null then
    raise exception 'FAIL [N1] the first nickname: error % (%), nickname %, changed_at %; expected it saved and changed_at null.', coalesce(v_state, 'none'), coalesce(v_msg, ''), v_txt, v_when;
  end if;
  v_checks := v_checks + 1;

  -- [N2] The next real change: allowed (no lock yet) and stamped.
  v_state := null;
  begin
    execute 'set local role authenticated';
    insert into public.profiles as pr (id, nickname) values (v_n, 'senick2' || left(v_n::text, 6))
    on conflict (id) do update set id = excluded.id, nickname = excluded.nickname;
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  execute 'reset role';
  select p.nickname, p.nickname_changed_at into v_txt, v_when from public.profiles p where p.id = v_n;
  if v_state is not null or v_txt is distinct from 'senick2' || left(v_n::text, 6) or v_when is distinct from now() then
    raise exception 'FAIL [N2] the first real change: error % (%), nickname %, changed_at %; expected it saved and stamped now().', coalesce(v_state, 'none'), coalesce(v_msg, ''), v_txt, v_when;
  end if;
  v_checks := v_checks + 1;

  -- [N3] Another real change within 7 days: refused, through the upsert.
  v_state := null; v_msg := null; v_detail := null;
  begin
    execute 'set local role authenticated';
    insert into public.profiles as pr (id, nickname) values (v_n, 'senick3' || left(v_n::text, 6))
    on conflict (id) do update set id = excluded.id, nickname = excluded.nickname;
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
  end;
  execute 'reset role';
  select p.nickname into v_txt from public.profiles p where p.id = v_n;
  if v_state is distinct from 'P0001' or v_detail is distinct from 'nickname_locked'
     or v_msg is distinct from 'You can change your nickname again in 7 days.'
     or v_txt is distinct from 'senick2' || left(v_n::text, 6) then
    raise exception 'FAIL [N3] a second change within 7 days: % / % / "%", nickname now %. Expected P0001 / nickname_locked / "You can change your nickname again in 7 days.", unchanged.',
      coalesce(v_state, 'no error'), coalesce(v_detail, '-'), coalesce(v_msg, ''), v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [N4] The same nickname, another case and spacing: not a change.
  --      With the nickname rules in (v_rules), added spaces are refused, so
  --      the re-cased name goes without them; the spaced one is tried after.
  v_state := null;
  begin
    execute 'set local role authenticated';
    if v_rules then
      update public.profiles set nickname = upper('senick2' || left(v_n::text, 6)) where id = v_n;
    else
      update public.profiles set nickname = '  ' || upper('senick2' || left(v_n::text, 6)) || ' ' where id = v_n;
    end if;
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  execute 'reset role';
  select p.nickname_changed_at into v_when from public.profiles p where p.id = v_n;
  if v_state is not null or v_when is distinct from now() then
    raise exception 'FAIL [N4] the same nickname re-cased: error % (%), changed_at %; expected allowed, changed_at unchanged.', coalesce(v_state, 'none'), coalesce(v_msg, ''), v_when;
  end if;
  if v_rules then
    v_state := null; v_detail := null;
    begin
      execute 'set local role authenticated';
      update public.profiles set nickname = '  ' || upper('senick2' || left(v_n::text, 6)) || ' ' where id = v_n;
      execute 'reset role';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
    end;
    execute 'reset role';
    select p.nickname, p.nickname_changed_at into v_txt, v_when from public.profiles p where p.id = v_n;
    if v_state is distinct from 'P0001' or v_detail is distinct from 'nickname_invalid'
       or v_txt is distinct from upper('senick2' || left(v_n::text, 6)) or v_when is distinct from now() then
      raise exception 'FAIL [N4] (nickname rules in) the re-cased name with added spaces: % / %, nickname now %, changed_at %; expected P0001 / nickname_invalid and nothing changed.',
        coalesce(v_state, 'no error'), coalesce(v_detail, '-'), v_txt, v_when;
    end if;
  end if;
  v_checks := v_checks + 1;

  -- [N5] The client cannot move the lock: a direct update of the column, and
  --      an upsert sending an old date with a new nickname.
  v_state := null;
  begin
    execute 'set local role authenticated';
    update public.profiles set nickname_changed_at = now() - interval '30 days' where id = v_n;
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  execute 'reset role';
  select p.nickname_changed_at into v_when from public.profiles p where p.id = v_n;
  if v_state is not null or v_when is distinct from now() then
    raise exception 'FAIL [N5] a direct write of nickname_changed_at: error % (%), now %; expected no error and the value unchanged.', coalesce(v_state, 'none'), coalesce(v_msg, ''), v_when;
  end if;
  v_detail := null;
  begin
    execute 'set local role authenticated';
    insert into public.profiles as pr (id, nickname, nickname_changed_at)
    values (v_n, 'senick3' || left(v_n::text, 6), now() - interval '30 days')
    on conflict (id) do update set id = excluded.id, nickname = excluded.nickname, nickname_changed_at = excluded.nickname_changed_at;
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail;
  end;
  execute 'reset role';
  if v_detail is distinct from 'nickname_locked' then
    raise exception 'FAIL [N5] an upsert sending an old nickname_changed_at: %; expected refused (nickname_locked).', coalesce(v_detail, 'accepted');
  end if;
  v_checks := v_checks + 1;

  -- [N6] Seven days and a minute later (moved back as the owner): allowed.
  update public.profiles set nickname_changed_at = now() - interval '7 days 1 minute' where id = v_n;
  v_state := null;
  begin
    execute 'set local role authenticated';
    insert into public.profiles as pr (id, nickname) values (v_n, 'senick3' || left(v_n::text, 6))
    on conflict (id) do update set id = excluded.id, nickname = excluded.nickname;
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  execute 'reset role';
  select p.nickname, p.nickname_changed_at into v_txt, v_when from public.profiles p where p.id = v_n;
  if v_state is not null or v_txt is distinct from 'senick3' || left(v_n::text, 6) or v_when is distinct from now() then
    raise exception 'FAIL [N6] a change after 7 days: error % (%), nickname %, changed_at %; expected saved and stamped now().', coalesce(v_state, 'none'), coalesce(v_msg, ''), v_txt, v_when;
  end if;
  v_checks := v_checks + 1;

  -- [N7] A brand-new row through the upsert's INSERT path, sending a date.
  v_state := null;
  perform set_config('request.jwt.claims', json_build_object('sub', v_n2, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    insert into public.profiles as pr (id, nickname, nickname_changed_at)
    values (v_n2, 'senew' || left(v_n2::text, 6), now() - interval '30 days')
    on conflict (id) do update set id = excluded.id, nickname = excluded.nickname;
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  execute 'reset role';
  select p.nickname, p.nickname_changed_at into v_txt, v_when from public.profiles p where p.id = v_n2;
  if v_state is not null or v_txt is distinct from 'senew' || left(v_n2::text, 6) or v_when is not null then
    raise exception 'FAIL [N7] a new row via the upsert: error % (%), nickname %, changed_at %; expected saved, changed_at null.', coalesce(v_state, 'none'), coalesce(v_msg, ''), v_txt, v_when;
  end if;
  v_checks := v_checks + 1;

  -- [N8] The owner is not limited (N is locked again since N6).
  begin
    update public.profiles set nickname = 'senick4' || left(v_n::text, 6) where id = v_n;
  exception when others then
    raise exception 'FAIL [N8] the owner''s change of a locked nickname was refused: %.', sqlerrm;
  end;
  if (select p.nickname from public.profiles p where p.id = v_n) is distinct from 'senick4' || left(v_n::text, 6) then
    raise exception 'FAIL [N8] the owner''s change did not stick.';
  end if;
  v_checks := v_checks + 1;

  -- ==== F: follows ==================================================================
  -- [F1] The cap of 50: X follows 50 (made as the owner); the 51st is 'limit'
  --      and counts nothing.
  insert into public.follows (follower_id, followed_id)
  select v_x, v_targets[i] from generate_series(1, 50) as i;
  v_txt := null; v_state := null;
  perform set_config('request.jwt.claims', json_build_object('sub', v_x, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    v_txt := public.follow_user(v_targets[51]);
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  execute 'reset role';
  select count(*) into v_n_rows from public.attempt_log al where al.user_id = v_x and al.action = 'follow_change';
  if v_state is not null or v_txt is distinct from 'limit' or v_n_rows <> 0
     or (select count(*) from public.follows f where f.follower_id = v_x) <> 50 then
    raise exception 'FAIL [F1] X''s 51st follow: % (error %: %), % follow_change row(s); expected limit, no error, 0, 50 follows.', v_txt, coalesce(v_state, 'none'), coalesce(v_msg, ''), v_n_rows;
  end if;
  v_checks := v_checks + 1;

  -- [F2] Y: 15 follows and 15 unfollows (30 changes) allowed; the 31st refused.
  v_state := null;
  perform set_config('request.jwt.claims', json_build_object('sub', v_y, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    for v_i in 1..15 loop
      v_txt := public.follow_user(v_targets[v_i]);
      if v_txt is distinct from 'following' then
        raise exception 'follow % answered %', v_i, v_txt;
      end if;
    end loop;
    for v_i in 1..15 loop
      v_txt := public.unfollow_user(v_targets[v_i]);
    end loop;
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  execute 'reset role';
  if v_state is not null then
    raise exception 'FAIL [F2] Y''s first 30 changes: % (%); expected all allowed.', v_state, v_msg;
  end if;
  v_state := null; v_detail := null; v_msg := null;
  begin
    execute 'set local role authenticated';
    perform public.follow_user(v_targets[16]);
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_detail = pg_exception_detail;
  end;
  execute 'reset role';
  select count(*) into v_n_rows from public.attempt_log al where al.user_id = v_y and al.action = 'follow_change';
  if v_state is distinct from 'P0001' or v_detail is distinct from 'rate_limited' or v_msg is distinct from v_follow_msg
     or v_n_rows <> 30 or exists (select 1 from public.follows f where f.follower_id = v_y) then
    raise exception 'FAIL [F2] Y''s 31st change: % / % / "%", % rows, follows %. Expected P0001 / rate_limited / "%", 30 rows, none.',
      coalesce(v_state, 'no error'), coalesce(v_detail, '-'), coalesce(v_msg, ''), v_n_rows,
      (select count(*) from public.follows f where f.follower_id = v_y), v_follow_msg;
  end if;
  v_checks := v_checks + 1;

  -- [F3] A real unfollow at the limit is refused too: the follow stays.
  insert into public.follows (follower_id, followed_id) values (v_q, v_targets[1]);
  insert into public.attempt_log (user_id, action, success)
  select v_q, 'follow_change', true from generate_series(1, 30);
  v_state := null; v_detail := null;
  perform set_config('request.jwt.claims', json_build_object('sub', v_q, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    perform public.unfollow_user(v_targets[1]);
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
  end;
  execute 'reset role';
  if v_state is distinct from 'P0001' or v_detail is distinct from 'rate_limited'
     or not exists (select 1 from public.follows f where f.follower_id = v_q and f.followed_id = v_targets[1]) then
    raise exception 'FAIL [F3] Q''s unfollow at the limit: % / %; expected P0001 / rate_limited and the follow kept.', coalesce(v_state, 'no error'), coalesce(v_detail, '-');
  end if;
  v_checks := v_checks + 1;

  -- [F4] No-ops count nothing.
  v_state := null;
  perform set_config('request.jwt.claims', json_build_object('sub', v_z, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    v_txt := public.follow_user(v_targets[1]);
    v_txt := v_txt || ',' || public.follow_user(v_targets[1]);
    v_txt := v_txt || ',' || public.unfollow_user(v_targets[2]);
    v_txt := v_txt || ',' || public.follow_user(v_z);
    execute 'reset role';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  execute 'reset role';
  select count(*) into v_n_rows from public.attempt_log al where al.user_id = v_z and al.action = 'follow_change';
  if v_state is not null or v_txt is distinct from 'following,following,not_following,not_allowed' or v_n_rows <> 1 then
    raise exception 'FAIL [F4] Z''s follow, re-follow, stray unfollow, self-follow: % (error %: %), % row(s); expected following,following,not_following,not_allowed and 1.',
      v_txt, coalesce(v_state, 'none'), coalesce(v_msg, ''), v_n_rows;
  end if;
  v_checks := v_checks + 1;

  if v_checks <> 20 then
    raise exception 'FAIL: % checks ran, expected 20.', v_checks;
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back).', v_checks;
end;
$$;
