-- Phase 3 hardening: CLOSE THE DIRECT-INSERT HOLES -- VERIFICATION.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER
-- docs/sql/phase3-hardening-grants.sql, on the live state (every phase3-e*
-- step, the computer C1/C2 files with computer-accounts-setup.sql, and the
-- leaderboard files applied). The whole file is ONE DO block: run it as is.
--
-- It WRITES -- two temporary accounts, tables, seats and a game -- and then
-- deliberately raises an exception at the very end, which rolls EVERY write
-- back. A check that fails raises its own exception at once, which rolls
-- everything back the same way. It always "fails": the message is the
-- verdict. "ALL n CHECKS PASSED (rolled back) ..." is a pass; anything
-- starting "FAIL" or "SETUP" is not. Re-runnable, because nothing it does
-- survives. It creates no functions, tables or other schema objects, and
-- every write it makes is to its own test rows: tables it creates, seats at
-- them, and one game at one of them. The one existing row it reads is the
-- hard computer account (create_computer_table seats it at a test table).
--
-- Same impersonation as the other suites: request.jwt.claims plus "set
-- local role authenticated" (or anon) to act as a client, "reset role" to act
-- as the owner (to read back what a client's statement really did).
--
-- PLAYERS: A and B are temporary accounts created in auth.users inside this
-- transaction. A creates every table; B joins t1.
--
-- THE TABLES (A's), from free 4-digit codes:
--   codes 1-7  the seven inserts Start a Table makes (2, 3 and 4 players;
--              Teams and Solo; Self-Scoring with 2, 3 and 4);
--   code 1     also the join, rejoin and update/delete table (t1, 2 players);
--   code 8     the code every refused insert tries (never created);
--   code 9     the computer table (create_computer_table).
--
-- WHAT IT CHECKS
--   G  the grants: INSERT on exactly the listed columns for authenticated,
--      none for anon; SELECT kept, and the UPDATE Force-End needs.
--   I  tables, as a signed-in player: computer_level, a future created_at,
--      an ended status and every other ungranted column are refused (42501);
--      the exact Start a Table inserts work.
--   M  table_members, as a signed-in player: score, the last award and every
--      other ungranted column are refused (42501).
--   J  the join (table_id, user_id, ON CONFLICT DO NOTHING): seats by the
--      trigger; a repeat is quiet; a rejoin after leave_table works.
--   C  create_computer_table still sets computer_level.
--   A  anon can insert into neither table.
--   U  a signed-in player updating or deleting their own (or another
--      player's) seat, table or game is refused or changes nothing.
--
-- Expected message:
--   ALL 22 CHECKS PASSED (rolled back). A=... B=...

do $$
declare
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_codes text[];
  v_ids uuid[] := '{}';
  v_t1 uuid;
  v_t2 uuid;
  v_tc uuid;
  v_g uuid;
  v_id uuid;
  v_rec record;
  v_col text;
  v_n int;
  v_state text;
  v_state2 text;
  v_txt text;
  v_exp text;
  v_bad text;
  v_checks int := 0;
  -- The columns a client may insert (phase3-hardening-grants.sql).
  v_table_cols text[] := array['code', 'created_by', 'is_public', 'is_muggins', 'max_players', 'team_mode'];
  v_member_cols text[] := array['table_id', 'user_id'];
begin
  -- ---- Setup, as the owner ------------------------------------------------
  begin
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
      (v_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'hg-a-' || v_a || '@verification.invalid', now() - interval '2 minutes', now()),
      (v_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'hg-b-' || v_b || '@verification.invalid', now() - interval '1 minute', now());
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts A and B in auth.users: % (%).', sqlerrm, sqlstate;
  end;

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0'))
    order by n
    limit 9
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 9 then
    raise exception 'SETUP: fewer than nine unused table codes.';
  end if;

  if not exists (select 1 from public.computer_accounts where level = 'hard') then
    raise exception 'SETUP: no hard computer account (run computer-accounts-setup.sql first).';
  end if;

  -- ==== G: the grants =========================================================
  -- [G1] tables: authenticated has no table-wide INSERT, and INSERT on
  -- exactly code, created_by, is_public, is_muggins, max_players, team_mode.
  v_bad := null;
  if has_table_privilege('authenticated', 'public.tables', 'INSERT') then
    v_bad := 'table-wide INSERT';
  end if;
  for v_col in
    select a.attname from pg_attribute a
    where a.attrelid = 'public.tables'::regclass and a.attnum > 0 and not a.attisdropped
  loop
    if has_column_privilege('authenticated', 'public.tables', v_col, 'INSERT') <> (v_col = any(v_table_cols)) then
      v_bad := coalesce(v_bad || ', ', '') || v_col;
    end if;
  end loop;
  if v_bad is not null then
    raise exception 'FAIL [G1] authenticated INSERT on tables is wrong for: %.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [G2] table_members: authenticated has no table-wide INSERT, and INSERT
  -- on exactly table_id and user_id.
  v_bad := null;
  if has_table_privilege('authenticated', 'public.table_members', 'INSERT') then
    v_bad := 'table-wide INSERT';
  end if;
  for v_col in
    select a.attname from pg_attribute a
    where a.attrelid = 'public.table_members'::regclass and a.attnum > 0 and not a.attisdropped
  loop
    if has_column_privilege('authenticated', 'public.table_members', v_col, 'INSERT') <> (v_col = any(v_member_cols)) then
      v_bad := coalesce(v_bad || ', ', '') || v_col;
    end if;
  end loop;
  if v_bad is not null then
    raise exception 'FAIL [G2] authenticated INSERT on table_members is wrong for: %.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [G3] anon: INSERT on no column of either table.
  if has_any_column_privilege('anon', 'public.tables', 'INSERT')
     or has_any_column_privilege('anon', 'public.table_members', 'INSERT') then
    raise exception 'FAIL [G3] anon still has INSERT on tables (%) or table_members (%).',
      has_any_column_privilege('anon', 'public.tables', 'INSERT'),
      has_any_column_privilege('anon', 'public.table_members', 'INSERT');
  end if;
  v_checks := v_checks + 1;

  -- [G4] Untouched: authenticated still reads both tables (Open Tables, the
  -- table page, the conflict target of the join), and still has the UPDATE
  -- the admin Force-End uses on tables and games (its policy limits it to
  -- admins).
  if not has_table_privilege('authenticated', 'public.tables', 'SELECT')
     or not has_table_privilege('authenticated', 'public.table_members', 'SELECT')
     or not has_table_privilege('authenticated', 'public.tables', 'UPDATE')
     or not has_table_privilege('authenticated', 'public.games', 'UPDATE') then
    raise exception 'FAIL [G4] authenticated lost SELECT on tables/table_members or UPDATE on tables/games.';
  end if;
  v_checks := v_checks + 1;

  -- ==== I: tables, as A =======================================================
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);

  -- [I1] A regular table marked as a computer table: refused.
  v_state := null;
  begin
    insert into public.tables (code, created_by, is_public, is_muggins, max_players, computer_level)
    values (v_codes[8], v_a, false, false, 2, 'hard');
  exception when others then v_state := sqlstate; end;
  if v_state is distinct from '42501' then
    raise exception 'FAIL [I1] inserting a table with computer_level: %; expected 42501.', coalesce(v_state, 'accepted');
  end if;
  v_checks := v_checks + 1;

  -- [I2] A table dated a year ahead (out of the 12-hour sweep's reach):
  -- refused.
  v_state := null;
  begin
    insert into public.tables (code, created_by, is_public, is_muggins, max_players, created_at)
    values (v_codes[8], v_a, true, false, 2, now() + interval '1 year');
  exception when others then v_state := sqlstate; end;
  if v_state is distinct from '42501' then
    raise exception 'FAIL [I2] inserting a table with a future created_at: %; expected 42501.', coalesce(v_state, 'accepted');
  end if;
  v_checks := v_checks + 1;

  -- [I3] A table born ended (status, and with ended_reason): refused.
  v_state := null;
  begin
    insert into public.tables (code, created_by, is_public, is_muggins, max_players, status)
    values (v_codes[8], v_a, true, false, 2, 'ended');
  exception when others then v_state := sqlstate; end;
  v_state2 := null;
  begin
    insert into public.tables (code, created_by, is_public, is_muggins, max_players, status, ended_reason)
    values (v_codes[8], v_a, true, false, 2, 'ended', 'admin');
  exception when others then v_state2 := sqlstate; end;
  if v_state is distinct from '42501' or v_state2 is distinct from '42501' then
    raise exception 'FAIL [I3] inserting an ended table: status %, with ended_reason %; expected 42501 both.',
      coalesce(v_state, 'accepted'), coalesce(v_state2, 'accepted');
  end if;
  v_checks := v_checks + 1;

  -- [I4] EVERY column outside the six -- whatever columns the table has
  -- today -- is refused, even sent as DEFAULT.
  v_bad := null;
  v_txt := '';
  for v_col in
    select a.attname from pg_attribute a
    where a.attrelid = 'public.tables'::regclass and a.attnum > 0 and not a.attisdropped
      and a.attgenerated = '' and not (a.attname = any(v_table_cols))
    order by a.attnum
  loop
    v_txt := v_txt || v_col || ' ';
    v_state := null;
    begin
      execute format('insert into public.tables (code, created_by, %I) values ($1, $2, default)', v_col)
        using v_codes[8], v_a;
    exception when others then v_state := sqlstate; end;
    if v_state is distinct from '42501' then
      v_bad := coalesce(v_bad || ', ', '') || v_col || '=' || coalesce(v_state, 'accepted');
    end if;
  end loop;
  if v_bad is not null or v_txt = '' then
    raise exception 'FAIL [I4] ungranted tables columns (%): %; expected 42501 each.', v_txt, coalesce(v_bad, 'none tested');
  end if;
  v_checks := v_checks + 1;

  -- [I5] The exact inserts Start a Table makes (newTableFields): 2 and 3
  -- players with no team_mode, 4-player Teams and Solo, and Self-Scoring
  -- with 2 (no team_mode), 3 and 4 ('solo'). All accepted, RETURNING the
  -- code as the app reads it; read back as the owner, each has the sent
  -- values and the server's own status 'open', no computer_level, no
  -- ended_reason and a created_at of now.
  v_bad := null;
  begin
    insert into public.tables (code, created_by, is_public, is_muggins, max_players)
    values (v_codes[1], v_a, true, false, 2) returning id into v_id;
    v_ids := v_ids || v_id;
    insert into public.tables (code, created_by, is_public, is_muggins, max_players)
    values (v_codes[2], v_a, false, false, 3) returning id into v_id;
    v_ids := v_ids || v_id;
    insert into public.tables (code, created_by, is_public, is_muggins, max_players, team_mode)
    values (v_codes[3], v_a, true, false, 4, 'teams') returning id into v_id;
    v_ids := v_ids || v_id;
    insert into public.tables (code, created_by, is_public, is_muggins, max_players, team_mode)
    values (v_codes[4], v_a, true, false, 4, 'solo') returning id into v_id;
    v_ids := v_ids || v_id;
    insert into public.tables (code, created_by, is_public, is_muggins, max_players)
    values (v_codes[5], v_a, true, true, 2) returning id into v_id;
    v_ids := v_ids || v_id;
    insert into public.tables (code, created_by, is_public, is_muggins, max_players, team_mode)
    values (v_codes[6], v_a, true, true, 3, 'solo') returning id into v_id;
    v_ids := v_ids || v_id;
    insert into public.tables (code, created_by, is_public, is_muggins, max_players, team_mode)
    values (v_codes[7], v_a, false, true, 4, 'solo') returning id into v_id;
    v_ids := v_ids || v_id;
  exception when others then v_bad := sqlerrm || ' (' || sqlstate || ')'; end;
  execute 'reset role';
  if v_bad is not null then
    raise exception 'FAIL [I5] a Start a Table insert was refused: % (after % of 7).', v_bad, coalesce(array_length(v_ids, 1), 0);
  end if;
  select string_agg(
           t.code || ':' || t.is_public || '/' || t.is_muggins || '/' || t.max_players || '/' || t.team_mode
             || '/' || t.status || '/' || coalesce(t.computer_level, '-') || '/' || coalesce(t.ended_reason, '-')
             || '/' || (t.created_at between now() - interval '1 minute' and now() + interval '1 minute'),
           ' ' order by t.code)
  into v_txt
  from public.tables t
  where t.id = any(v_ids);
  v_exp := v_codes[1] || ':true/false/2/teams/open/-/-/true '
        || v_codes[2] || ':false/false/3/teams/open/-/-/true '
        || v_codes[3] || ':true/false/4/teams/open/-/-/true '
        || v_codes[4] || ':true/false/4/solo/open/-/-/true '
        || v_codes[5] || ':true/true/2/teams/open/-/-/true '
        || v_codes[6] || ':true/true/3/solo/open/-/-/true '
        || v_codes[7] || ':false/true/4/solo/open/-/-/true';
  if v_txt is distinct from v_exp then
    raise exception 'FAIL [I5] the Start a Table rows: %; expected %.', coalesce(v_txt, 'none'), v_exp;
  end if;
  v_t1 := v_ids[1];
  v_t2 := v_ids[2];
  v_checks := v_checks + 1;

  -- ==== M: table_members, as B, at t1 (B is not seated yet) ===================
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);

  -- [M1] Sitting down with a score: refused.
  v_state := null;
  begin
    insert into public.table_members (table_id, user_id, score) values (v_t1, v_b, 120);
  exception when others then v_state := sqlstate; end;
  if v_state is distinct from '42501' then
    raise exception 'FAIL [M1] inserting a seat with a score: %; expected 42501.', coalesce(v_state, 'accepted');
  end if;
  v_checks := v_checks + 1;

  -- [M2] Sitting down with a made-up last award: refused.
  v_state := null;
  begin
    insert into public.table_members (table_id, user_id, last_points, last_reason, last_awarded_at)
    values (v_t1, v_b, 29, 'perfect hand', now());
  exception when others then v_state := sqlstate; end;
  if v_state is distinct from '42501' then
    raise exception 'FAIL [M2] inserting a seat with a last award: %; expected 42501.', coalesce(v_state, 'accepted');
  end if;
  v_checks := v_checks + 1;

  -- [M3] EVERY column outside table_id and user_id (the seat, joined_at,
  -- the score and the last award included) is refused, even as DEFAULT.
  v_bad := null;
  v_txt := '';
  for v_col in
    select a.attname from pg_attribute a
    where a.attrelid = 'public.table_members'::regclass and a.attnum > 0 and not a.attisdropped
      and a.attgenerated = '' and not (a.attname = any(v_member_cols))
    order by a.attnum
  loop
    v_txt := v_txt || v_col || ' ';
    v_state := null;
    begin
      execute format('insert into public.table_members (table_id, user_id, %I) values ($1, $2, default)', v_col)
        using v_t1, v_b;
    exception when others then v_state := sqlstate; end;
    if v_state is distinct from '42501' then
      v_bad := coalesce(v_bad || ', ', '') || v_col || '=' || coalesce(v_state, 'accepted');
    end if;
  end loop;
  execute 'reset role';
  if v_bad is not null or v_txt = '' then
    raise exception 'FAIL [M3] ungranted table_members columns (%): %; expected 42501 each.', v_txt, coalesce(v_bad, 'none tested');
  end if;
  if exists (select 1 from public.table_members where table_id = v_t1) then
    raise exception 'FAIL [M3] a refused insert left a seat at t1.';
  end if;
  v_checks := v_checks + 1;

  -- ==== J: the join ===========================================================
  -- [J1] A, then B, take a seat at t1 exactly as the app does: (table_id,
  -- user_id) ON CONFLICT DO NOTHING. Both accepted; the trigger seats A 1
  -- and B 2; score 0, no last award, joined just now.
  v_bad := null;
  execute 'set local role authenticated';
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_a::text, true);
    insert into public.table_members (table_id, user_id) values (v_t1, v_a)
    on conflict (table_id, user_id) do nothing;
    perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_b::text, true);
    insert into public.table_members (table_id, user_id) values (v_t1, v_b)
    on conflict (table_id, user_id) do nothing;
  exception when others then v_bad := sqlerrm || ' (' || sqlstate || ')'; end;
  execute 'reset role';
  select string_agg(
           case tm.user_id when v_a then 'A' when v_b then 'B' else '?' end || tm.seat || '/' || tm.score
             || '/' || coalesce(tm.last_points::text, '-') || '/' || coalesce(tm.last_reason, '-')
             || '/' || (tm.joined_at between now() - interval '1 minute' and now() + interval '1 minute'),
           ' ' order by tm.seat)
  into v_txt
  from public.table_members tm
  where tm.table_id = v_t1;
  if v_bad is not null or v_txt is distinct from 'A1/0/-/-/true B2/0/-/-/true' then
    raise exception 'FAIL [J1] the join: refused %, seats %; expected A1/0/-/-/true B2/0/-/-/true.', coalesce(v_bad, 'nothing'), coalesce(v_txt, 'none');
  end if;
  v_checks := v_checks + 1;

  -- [J2] B's same upsert again (a refresh, a second tab): quiet, still one
  -- seat, still seat 2.
  v_bad := null;
  execute 'set local role authenticated';
  begin
    insert into public.table_members (table_id, user_id) values (v_t1, v_b)
    on conflict (table_id, user_id) do nothing;
  exception when others then v_bad := sqlerrm || ' (' || sqlstate || ')'; end;
  execute 'reset role';
  select count(*) as n, max(seat) as seat into v_rec from public.table_members where table_id = v_t1 and user_id = v_b;
  if v_bad is not null or v_rec.n <> 1 or v_rec.seat is distinct from 2 then
    raise exception 'FAIL [J2] the repeat upsert: refused %, % row(s), seat %.', coalesce(v_bad, 'nothing'), v_rec.n, v_rec.seat;
  end if;
  v_checks := v_checks + 1;

  -- [J3] B leaves (leave_table) and comes back with the same upsert: a fresh
  -- seat 2, score 0.
  v_bad := null;
  execute 'set local role authenticated';
  begin
    perform public.leave_table(v_t1);
    insert into public.table_members (table_id, user_id) values (v_t1, v_b)
    on conflict (table_id, user_id) do nothing;
  exception when others then v_bad := sqlerrm || ' (' || sqlstate || ')'; end;
  execute 'reset role';
  select count(*) as n, max(seat) as seat, max(score) as score into v_rec
  from public.table_members where table_id = v_t1 and user_id = v_b;
  if v_bad is not null or v_rec.n <> 1 or v_rec.seat is distinct from 2 or v_rec.score is distinct from 0 then
    raise exception 'FAIL [J3] the rejoin after leave_table: refused %, % row(s), seat %, score %.',
      coalesce(v_bad, 'nothing'), v_rec.n, v_rec.seat, v_rec.score;
  end if;
  v_checks := v_checks + 1;

  -- ==== C: the computer table =================================================
  -- [C1] A starts a hard computer table: create_computer_table (security
  -- definer) still writes computer_level, and seats A and the computer.
  v_bad := null;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  begin
    select ct.table_id into v_tc from public.create_computer_table('hard', v_codes[9]) ct;
  exception when others then v_bad := sqlerrm || ' (' || sqlstate || ')'; end;
  execute 'reset role';
  select t.computer_level, t.is_public, t.max_players,
         (select count(*) from public.table_members tm where tm.table_id = t.id) as seated
  into v_rec
  from public.tables t
  where t.id = v_tc;
  if v_bad is not null or v_rec.computer_level is distinct from 'hard' or v_rec.is_public or v_rec.seated <> 2 then
    raise exception 'FAIL [C1] create_computer_table: refused %, level %, public %, seated %; expected hard, false, 2.',
      coalesce(v_bad, 'nothing'), v_rec.computer_level, v_rec.is_public, v_rec.seated;
  end if;
  v_checks := v_checks + 1;

  -- ==== A: anon ===============================================================
  execute 'set local role anon';
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);

  -- [A1] anon creating a table: refused.
  v_state := null;
  begin
    insert into public.tables (code, created_by) values (v_codes[8], v_a);
  exception when others then v_state := sqlstate; end;

  -- [A2] anon taking a seat (at t2, where nobody sits): refused.
  v_state2 := null;
  begin
    insert into public.table_members (table_id, user_id) values (v_t2, v_a);
  exception when others then v_state2 := sqlstate; end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [A1] anon inserting a table: %; expected 42501.', coalesce(v_state, 'accepted');
  end if;
  v_checks := v_checks + 1;
  if v_state2 is distinct from '42501' then
    raise exception 'FAIL [A2] anon inserting a seat: %; expected 42501.', coalesce(v_state2, 'accepted');
  end if;
  v_checks := v_checks + 1;

  -- ==== U: updates and deletes, as A (not an admin) ===========================
  -- Each is either refused (42501, if the right is gone) or matches no row
  -- (no UPDATE/DELETE policy for a player); either way nothing changes,
  -- which is checked as the owner.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);

  -- [U1] A raising A's own score, and B's: nothing changes.
  v_bad := '';
  begin
    update public.table_members set score = 120, last_points = 29, last_reason = 'perfect hand'
    where table_id = v_t1 and user_id = v_a;
    get diagnostics v_n = row_count;
    if v_n <> 0 then v_bad := v_bad || 'own row updated; '; end if;
  exception when others then
    if sqlstate <> '42501' then v_bad := v_bad || 'own: ' || sqlstate || '; '; end if;
  end;
  begin
    update public.table_members set score = 0 where table_id = v_t1 and user_id = v_b;
    get diagnostics v_n = row_count;
    if v_n <> 0 then v_bad := v_bad || 'B''s row updated; '; end if;
  exception when others then
    if sqlstate <> '42501' then v_bad := v_bad || 'B: ' || sqlstate || '; '; end if;
  end;
  execute 'reset role';
  if v_bad <> '' or exists (
    select 1 from public.table_members where table_id = v_t1 and (score <> 0 or last_points is not null)
  ) then
    raise exception 'FAIL [U1] a player updating seats: %.', coalesce(nullif(v_bad, ''), 'a score changed');
  end if;
  v_checks := v_checks + 1;

  -- [U2] A rewriting A's own table: computer_level, created_at, status.
  v_bad := '';
  execute 'set local role authenticated';
  begin
    update public.tables
    set computer_level = 'hard', created_at = now() + interval '1 year', status = 'ended'
    where id = v_t1;
    get diagnostics v_n = row_count;
    if v_n <> 0 then v_bad := v_bad || 'row updated; '; end if;
  exception when others then
    if sqlstate <> '42501' then v_bad := v_bad || sqlstate || '; '; end if;
  end;
  execute 'reset role';
  if v_bad <> '' or exists (
    select 1 from public.tables
    where id = v_t1 and (computer_level is not null or status <> 'open' or created_at > now() + interval '1 minute')
  ) then
    raise exception 'FAIL [U2] a player updating their own table: %.', coalesce(nullif(v_bad, ''), 'the row changed');
  end if;
  v_checks := v_checks + 1;

  -- [U3] A deleting B's seat, A's own seat, and A's own empty table (t2):
  -- nothing goes.
  v_bad := '';
  execute 'set local role authenticated';
  begin
    delete from public.table_members where table_id = v_t1 and user_id in (v_a, v_b);
    get diagnostics v_n = row_count;
    if v_n <> 0 then v_bad := v_bad || 'seats deleted; '; end if;
  exception when others then
    if sqlstate <> '42501' then v_bad := v_bad || 'seats: ' || sqlstate || '; '; end if;
  end;
  begin
    delete from public.tables where id = v_t2;
    get diagnostics v_n = row_count;
    if v_n <> 0 then v_bad := v_bad || 'table deleted; '; end if;
  exception when others then
    if sqlstate <> '42501' then v_bad := v_bad || 'table: ' || sqlstate || '; '; end if;
  end;
  execute 'reset role';
  if v_bad <> ''
     or (select count(*) from public.table_members where table_id = v_t1) <> 2
     or not exists (select 1 from public.tables where id = v_t2) then
    raise exception 'FAIL [U3] a player deleting rows: %.', coalesce(nullif(v_bad, ''), 'a row is gone');
  end if;
  v_checks := v_checks + 1;

  -- [U4] A starts the game at t1, then tries to end it as won by A, and to
  -- delete it: nothing changes.
  v_bad := '';
  execute 'set local role authenticated';
  v_g := public.start_game_with_deal(v_t1);
  begin
    update public.games set status = 'ended', ended_reason = 'won', winner_id = v_a where id = v_g;
    get diagnostics v_n = row_count;
    if v_n <> 0 then v_bad := v_bad || 'game updated; '; end if;
  exception when others then
    if sqlstate <> '42501' then v_bad := v_bad || 'update: ' || sqlstate || '; '; end if;
  end;
  begin
    delete from public.games where id = v_g;
    get diagnostics v_n = row_count;
    if v_n <> 0 then v_bad := v_bad || 'game deleted; '; end if;
  exception when others then
    if sqlstate <> '42501' then v_bad := v_bad || 'delete: ' || sqlstate || '; '; end if;
  end;
  execute 'reset role';
  select status, ended_reason, winner_id into v_rec from public.games where id = v_g;
  if v_g is null or v_bad <> '' or v_rec.status is null or v_rec.status not in ('cutting', 'active')
     or v_rec.ended_reason is not null or v_rec.winner_id is not null then
    raise exception 'FAIL [U4] a player writing their own game: %, game % now %/%/%.',
      coalesce(nullif(v_bad, ''), 'nothing refused'), v_g, v_rec.status, v_rec.ended_reason, v_rec.winner_id;
  end if;
  v_checks := v_checks + 1;

  raise exception 'ALL % CHECKS PASSED (rolled back). A=% B=%.', v_checks, v_a, v_b;
end $$;
