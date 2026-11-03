-- Phase 3: SELF-SCORING (MUGGINS) WITH 3 AND 4 PLAYERS -- VERIFICATION.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER
-- docs/sql/phase3-muggins-multiplayer.sql. The whole file is ONE DO block:
-- run it as is.
--
-- It WRITES -- five temporary accounts with profiles, tables, seats, games,
-- claims, confirmations and awards -- and then deliberately raises an
-- exception at the very end, which rolls EVERY write back. A check that
-- fails raises its own exception at once, which rolls everything back the
-- same way. It always "fails": the message is the verdict. "ALL n CHECKS
-- PASSED (rolled back) ..." is a pass; anything starting "FAIL" or "SETUP"
-- is not. Re-runnable, because nothing it does survives. It creates no
-- functions, tables or other schema objects, and touches no existing
-- account or table.
--
-- Same impersonation as the other suites: request.jwt.claims plus "set
-- local role authenticated" to act as a player, "reset role" to act as the
-- owner (to set a game live, set a score, and to read).
--
-- PLAYERS: A, B, C, D and E are ALL temporary accounts created in auth.users
-- inside this transaction, A-D with a profile (so the leaderboard can list
-- them). E never sits at a table (the non-member).
--
-- THE TABLES, each created by A (the host), seats in join order:
--   t2  2 players, Muggins (team_mode not sent: the default, as today)
--   t3  3 players, Muggins, team_mode 'solo'
--   t4  4 players, Muggins, team_mode 'solo'
--   tr  2 players, a REGULAR table (for the leaderboard check)
-- Each game is started by A for real, then set live ('active') by the
-- owner; every claim, withdrawal and confirmation is made by the real
-- player, as that player.
--
-- A game's state below reads status/ended_reason/winner/claimant/
-- confirmations, players as letters, confirmations in order: e.g.
-- 'active/-/-/A/B.C' is a live game with A's claim confirmed by B then C.
--
-- WHAT IT CHECKS
--   S  the migration: the three new bodies (md5), the new column, the
--      constraint swap.
--   M  creation: Muggins on 2, 3 and 4 players; a 4-player one must be
--      'solo' ('teams', or nothing sent, is refused).
--   Q  4 players: claim, a second claim refused, own confirmation and a
--      non-member refused, withdraw and reclaim resets confirmations, one or
--      two of three confirmations don't end it, a repeat is quiet, the last
--      ends it (winner = the claimant), nothing after.
--   L  the leaderboard snapshot: one winner; the leaderboard still skips
--      every Muggins game.
--   R  a rematch starts with no claim and no confirmations.
--   P  points still cap at 121 and never end a Muggins game; no partner
--      shares them.
--   T  3 players: a seated non-player refused, own confirmation refused,
--      ends on the second confirmation.
--   W  2 players: messages and the end on the FIRST confirmation, as before.
--
-- Expected message:
--   ALL 24 CHECKS PASSED (rolled back). A=... B=... C=... D=...

do $$
declare
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid();
  v_e uuid := gen_random_uuid();
  v_codes text[];
  v_names jsonb;
  v_t2 uuid;
  v_t3 uuid;
  v_t4 uuid;
  v_tr uuid;
  v_g2 uuid;
  v_g3 uuid;
  v_g4 uuid;
  v_g4b uuid;
  v_gr uuid;
  v_new uuid;
  v_player uuid;
  v_rec record;
  v_md5 text;
  v_msg text;
  v_msg2 text;
  v_state text;
  v_state2 text;
  v_scores text;
  v_bad text;
  v_checks int := 0;
  -- A game's state as a readable string ($1 the game, $2 the letters).
  v_stateq text := $q$
    select g.status || '/' || coalesce(g.ended_reason, '-') || '/' || coalesce($2 ->> g.winner_id::text, '-')
      || '/' || coalesce($2 ->> g.win_claim_by::text, '-')
      || '/' || coalesce((select string_agg($2 ->> u.x::text, '.' order by u.o)
                          from unnest(g.win_confirmed_by) with ordinality as u(x, o)), '')
    from public.games g
    where g.id = $1
  $q$;
begin
  -- ---- Setup, as the owner ------------------------------------------------
  begin
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
      (v_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'mmv-a-' || v_a || '@verification.invalid', now() - interval '5 minutes', now()),
      (v_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'mmv-b-' || v_b || '@verification.invalid', now() - interval '4 minutes', now()),
      (v_c, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'mmv-c-' || v_c || '@verification.invalid', now() - interval '3 minutes', now()),
      (v_d, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'mmv-d-' || v_d || '@verification.invalid', now() - interval '2 minutes', now()),
      (v_e, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'mmv-e-' || v_e || '@verification.invalid', now() - interval '1 minute', now());
    -- An upsert, as in the leaderboard suites, in case a profile row already
    -- came with the account.
    insert into public.profiles as pr (id, nickname) values
      (v_a, 'mmv-a-' || left(v_a::text, 8)),
      (v_b, 'mmv-b-' || left(v_b::text, 8)),
      (v_c, 'mmv-c-' || left(v_c::text, 8)),
      (v_d, 'mmv-d-' || left(v_d::text, 8))
    on conflict (id) do update set nickname = excluded.nickname;
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts A-E (and profiles A-D): % (%).', sqlerrm, sqlstate;
  end;
  v_names := jsonb_build_object(v_a::text, 'A', v_b::text, 'B', v_c::text, 'C', v_d::text, 'D', v_e::text, 'E');

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

  -- ==== S: the migration ======================================================
  -- [S1] The three functions are the phase3-muggins-multiplayer.sql bodies
  -- (md5 of the body between the dollar quotes, line endings normalised).
  v_bad := null;
  for v_rec in
    select * from (values
      ('public.claim_win(uuid)',       'f5a6705be011f11601c41a30cc44f426'),
      ('public.clear_win_claim(uuid)', 'bf320f7a8ba2d7a84cf9f40a2f00a84d'),
      ('public.confirm_win(uuid)',     'a6a406b1677f172a12be514c36055558')
    ) as x(key, md5)
  loop
    select md5(replace(p.prosrc, E'\r', '')) into v_md5
    from pg_proc p where p.oid = to_regprocedure(v_rec.key);
    if v_md5 is distinct from v_rec.md5 then
      v_bad := coalesce(v_bad || '; ', '') || v_rec.key || ' has ' || coalesce(v_md5, '(missing)');
    end if;
  end loop;
  if v_bad is not null then
    raise exception 'FAIL [S1] the claim functions are not the phase3-muggins-multiplayer.sql bodies: %.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [S2] games.win_confirmed_by: uuid[], NOT NULL, default '{}'.
  select format_type(a.atttypid, a.atttypmod), a.attnotnull, pg_get_expr(d.adbin, d.adrelid)
  into v_rec
  from pg_attribute a
  left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  where a.attrelid = 'public.games'::regclass and a.attname = 'win_confirmed_by' and not a.attisdropped;
  if v_rec is null or v_rec.format_type is distinct from 'uuid[]' or not v_rec.attnotnull
     or v_rec.pg_get_expr is distinct from '''{}''::uuid[]' then
    raise exception 'FAIL [S2] games.win_confirmed_by: %.', coalesce(v_rec::text, 'missing');
  end if;
  v_checks := v_checks + 1;

  -- [S3] The 2-player-only constraint is gone; the new one is there.
  if exists (select 1 from pg_constraint where conrelid = 'public.tables'::regclass and conname = 'tables_muggins_two_players')
     or not exists (select 1 from pg_constraint where conrelid = 'public.tables'::regclass and conname = 'tables_muggins_no_teams') then
    raise exception 'FAIL [S3] the constraints on tables: tables_muggins_two_players should be gone and tables_muggins_no_teams present.';
  end if;
  v_checks := v_checks + 1;

  -- ==== M: creation, as A =====================================================
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);

  -- [M1] 2 players, Muggins, no team_mode sent -- the insert Start a Table
  -- makes today: accepted.
  v_msg := null;
  begin
    insert into public.tables (code, created_by, max_players, is_muggins)
    values (v_codes[1], v_a, 2, true) returning id into v_t2;
  exception when others then v_msg := sqlerrm; end;
  if v_msg is not null or v_t2 is null then
    raise exception 'FAIL [M1] a 2-player Muggins table: %.', coalesce(v_msg, 'no table');
  end if;
  v_checks := v_checks + 1;

  -- [M2] 3 players, Muggins, 'solo': accepted.
  v_msg := null;
  begin
    insert into public.tables (code, created_by, max_players, is_muggins, team_mode)
    values (v_codes[2], v_a, 3, true, 'solo') returning id into v_t3;
  exception when others then v_msg := sqlerrm; end;
  if v_msg is not null or v_t3 is null then
    raise exception 'FAIL [M2] a 3-player Muggins table: %.', coalesce(v_msg, 'no table');
  end if;
  v_checks := v_checks + 1;

  -- [M3] 4 players, Muggins, 'solo': accepted.
  v_msg := null;
  begin
    insert into public.tables (code, created_by, max_players, is_muggins, team_mode)
    values (v_codes[3], v_a, 4, true, 'solo') returning id into v_t4;
  exception when others then v_msg := sqlerrm; end;
  if v_msg is not null or v_t4 is null then
    raise exception 'FAIL [M3] a 4-player Muggins table: %.', coalesce(v_msg, 'no table');
  end if;
  v_checks := v_checks + 1;

  -- [M4] 4 players, Muggins, 'teams' -- and with no team_mode sent (the
  -- default, 'teams') -- refused by tables_muggins_no_teams.
  v_msg := null;
  begin
    insert into public.tables (code, created_by, max_players, is_muggins, team_mode)
    values (v_codes[4], v_a, 4, true, 'teams');
  exception when others then v_msg := sqlstate; end;
  v_msg2 := null;
  begin
    insert into public.tables (code, created_by, max_players, is_muggins)
    values (v_codes[4], v_a, 4, true);
  exception when others then v_msg2 := sqlstate; end;
  if v_msg is distinct from '23514' or v_msg2 is distinct from '23514' then
    raise exception 'FAIL [M4] a 4-player Muggins Teams table: % / no team_mode: %; expected 23514 both.',
      coalesce(v_msg, 'accepted'), coalesce(v_msg2, 'accepted');
  end if;
  v_checks := v_checks + 1;

  -- The regular table for L2.
  insert into public.tables (code, created_by, max_players) values (v_codes[5], v_a, 2) returning id into v_tr;

  -- Everyone sits (seats in join order), and A starts each game.
  foreach v_player in array array[v_a, v_b, v_c, v_d] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    insert into public.table_members (table_id, user_id) values (v_t4, v_player);
    if v_player <> v_d then
      insert into public.table_members (table_id, user_id) values (v_t3, v_player);
    end if;
    if v_player in (v_a, v_b) then
      insert into public.table_members (table_id, user_id) values (v_t2, v_player);
      insert into public.table_members (table_id, user_id) values (v_tr, v_player);
    end if;
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_g2 := public.start_game_with_deal(v_t2);
  v_g3 := public.start_game_with_deal(v_t3);
  v_g4 := public.start_game_with_deal(v_t4);
  v_gr := public.start_game_with_deal(v_tr);
  execute 'reset role';
  -- Live, as a dealt game is (claims need 'active'; the cut is not under test).
  update public.games set status = 'active', phase = 'discard' where id in (v_g2, v_g3, v_g4, v_gr);

  -- ==== Q: 4 players ==========================================================
  -- [Q1] A claims: A holds the claim, nobody has confirmed.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin perform public.claim_win(v_g4); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  execute v_stateq into v_state using v_g4, v_names;
  if v_msg is not null or v_state is distinct from 'active/-/-/A/' then
    raise exception 'FAIL [Q1] A''s claim: refused %, state %; expected active/-/-/A/.', coalesce(v_msg, 'nothing'), v_state;
  end if;
  v_checks := v_checks + 1;

  -- [Q2] B's claim is refused ("Another player", 4 players); A's repeat
  -- claim is quiet; nothing changes.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.claim_win(v_g4); exception when others then v_msg := sqlerrm; end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg2 := null;
  begin perform public.claim_win(v_g4); exception when others then v_msg2 := sqlerrm; end;
  execute 'reset role';
  execute v_stateq into v_state using v_g4, v_names;
  if v_msg is distinct from 'Another player has already claimed the win. Confirm it, or wait for them to cancel it.'
     or v_msg2 is not null or v_state is distinct from 'active/-/-/A/' then
    raise exception 'FAIL [Q2] a second claim: B %, A again %, state %.', coalesce(v_msg, 'no error'), coalesce(v_msg2, 'quiet'), v_state;
  end if;
  v_checks := v_checks + 1;

  -- [Q3] A can't confirm A's own claim ("every other player", 4 players).
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.confirm_win(v_g4); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  execute v_stateq into v_state using v_g4, v_names;
  if v_msg is distinct from 'You can''t confirm your own claim; every other player has to.' or v_state is distinct from 'active/-/-/A/' then
    raise exception 'FAIL [Q3] the claimant confirming: %, state %.', coalesce(v_msg, 'no error'), v_state;
  end if;
  v_checks := v_checks + 1;

  -- [Q4] E, not at the table, can't confirm.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_e, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_e::text, true);
  v_msg := null;
  begin perform public.confirm_win(v_g4); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  execute v_stateq into v_state using v_g4, v_names;
  if v_msg is distinct from 'You are not a member of this table.' or v_state is distinct from 'active/-/-/A/' then
    raise exception 'FAIL [Q4] a non-member confirming: %, state %.', coalesce(v_msg, 'no error'), v_state;
  end if;
  v_checks := v_checks + 1;

  -- [Q5] B confirms: one of three -- recorded, the match goes on.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.confirm_win(v_g4); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  execute v_stateq into v_state using v_g4, v_names;
  if v_msg is not null or v_state is distinct from 'active/-/-/A/B' then
    raise exception 'FAIL [Q5] one confirmation of three: refused %, state %; expected active/-/-/A/B.', coalesce(v_msg, 'nothing'), v_state;
  end if;
  v_checks := v_checks + 1;

  -- [Q6] A withdraws: no claim, no confirmations. A claims again: B's
  -- earlier confirmation does NOT carry over.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin perform public.clear_win_claim(v_g4); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  execute v_stateq into v_state using v_g4, v_names;
  execute 'set local role authenticated';
  v_msg2 := null;
  begin perform public.claim_win(v_g4); exception when others then v_msg2 := sqlerrm; end;
  execute 'reset role';
  execute v_stateq into v_state2 using v_g4, v_names;
  if v_msg is not null or v_msg2 is not null or v_state is distinct from 'active/-/-/-/' or v_state2 is distinct from 'active/-/-/A/' then
    raise exception 'FAIL [Q6] withdraw and reclaim: refused % / %, states % then %; expected active/-/-/-/ then active/-/-/A/.',
      coalesce(v_msg, 'nothing'), coalesce(v_msg2, 'nothing'), v_state, v_state2;
  end if;
  v_checks := v_checks + 1;

  -- [Q7] B and C confirm (two of three), and C's repeat is quiet: the match
  -- goes on, B and C recorded once each.
  execute 'set local role authenticated';
  v_bad := '';
  foreach v_player in array array[v_b, v_c, v_c] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    begin perform public.confirm_win(v_g4); exception when others then v_bad := v_bad || (v_names ->> v_player::text) || ':' || sqlerrm || ' '; end;
  end loop;
  execute 'reset role';
  execute v_stateq into v_state using v_g4, v_names;
  if v_bad <> '' or v_state is distinct from 'active/-/-/A/B.C' then
    raise exception 'FAIL [Q7] two confirmations and a repeat: refused %, state %; expected active/-/-/A/B.C.', coalesce(nullif(v_bad, ''), 'nothing'), v_state;
  end if;
  v_checks := v_checks + 1;

  -- [Q8] D's confirmation is the last: the match is won by A, the claimant;
  -- the claim and its confirmations are settled, ready_by empty.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_d::text, true);
  v_msg := null;
  begin perform public.confirm_win(v_g4); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  execute v_stateq into v_state using v_g4, v_names;
  if v_msg is not null or v_state is distinct from 'ended/won/A/-/'
     or (select ready_by from public.games where id = v_g4) <> '{}' then
    raise exception 'FAIL [Q8] the last confirmation: refused %, state %; expected ended/won/A/-/ and ready_by {}.', coalesce(v_msg, 'nothing'), v_state;
  end if;
  v_checks := v_checks + 1;

  -- [Q9] Nothing after it: D's confirmation again is refused, and nothing
  -- changes.
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.confirm_win(v_g4); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  execute v_stateq into v_state2 using v_g4, v_names;
  if v_msg is distinct from 'The win can only be confirmed during a live game.' or v_state2 is distinct from v_state then
    raise exception 'FAIL [Q9] a confirmation after the win: %, state %.', coalesce(v_msg, 'no error'), v_state2;
  end if;
  v_checks := v_checks + 1;

  -- ==== L: the leaderboard snapshot ===========================================
  -- [L1] The snapshot of A's confirmed win: four rows, ONE winner -- A (on a
  -- 'solo' table nobody shares it).
  select string_agg((v_names ->> gr.user_id::text) || '=' || case when gr.won then 't' else 'f' end, ',' order by v_names ->> gr.user_id::text)
  into v_scores from public.game_results gr where gr.game_id = v_g4;
  if v_scores is distinct from 'A=t,B=f,C=f,D=f' then
    raise exception 'FAIL [L1] the snapshot of a 4-player Muggins win: %; expected A=t,B=f,C=f,D=f.', coalesce(v_scores, 'no rows');
  end if;
  v_checks := v_checks + 1;

  -- ==== R: the rematch ========================================================
  -- [R1] All four tap New Game: a NEW game (live or at the cut -- whichever
  -- the rematch starts in), with no claim and no confirmations; the won game
  -- keeps its settled (empty) claim.
  execute 'set local role authenticated';
  v_bad := '';
  foreach v_player in array array[v_a, v_b, v_c, v_d] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    v_new := public.start_game_with_deal(v_t4);
    v_bad := v_bad || coalesce(v_new::text, 'waiting') || ' ';
  end loop;
  execute 'reset role';
  v_g4b := v_new;
  execute v_stateq into v_state using v_g4b, v_names;
  execute v_stateq into v_state2 using v_g4, v_names;
  if v_g4b is null or v_g4b = v_g4 or v_bad not like 'waiting waiting waiting %'
     or v_state not in ('active/-/-/-/', 'cutting/-/-/-/') or v_state2 is distinct from 'ended/won/A/-/' then
    raise exception 'FAIL [R1] the rematch: taps %, new game % state %, old game state %; expected a new game with no claim.',
      v_bad, v_g4b, v_state, v_state2;
  end if;
  v_checks := v_checks + 1;

  -- ==== P: points on a Muggins table, as the owner ============================
  -- [P1] On the rematch: A scores 5 -- A only (C, A's partner on a Teams
  -- table, stays 0); A put at 118 scores 4 -- capped at 121, and the game
  -- does NOT end.
  update public.games set status = 'active' where id = v_g4b;
  update public.table_members set score = 0, last_points = null, last_reason = null, last_awarded_at = null
  where table_id = v_t4;
  perform public.award_points(v_t4, v_a, 5, 'five');
  select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score, ',' order by v_names ->> tm.user_id::text)
  into v_scores from public.table_members tm where tm.table_id = v_t4;
  update public.table_members set score = 118 where table_id = v_t4 and user_id = v_a;
  perform public.award_points(v_t4, v_a, 4, 'four');
  select score into v_rec from public.table_members where table_id = v_t4 and user_id = v_a;
  execute v_stateq into v_state using v_g4b, v_names;
  if v_scores is distinct from 'A=5,B=0,C=0,D=0' or v_rec.score <> 121 or v_state is distinct from 'active/-/-/-/' then
    raise exception 'FAIL [P1] Muggins points: after 5 %, after 118+4 A=% / %; expected A=5,B=0,C=0,D=0, 121, active/-/-/-/.',
      v_scores, v_rec.score, v_state;
  end if;
  v_checks := v_checks + 1;

  -- ==== T: 3 players ==========================================================
  -- [T1] A claims. D, seated at the table but not in this game (the owner
  -- makes room for a fourth seat, and takes it away again at once), can't
  -- confirm; nor can A ("every other player").
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  perform public.claim_win(v_g3);
  v_msg2 := null;
  begin perform public.confirm_win(v_g3); exception when others then v_msg2 := sqlerrm; end;
  execute 'reset role';
  update public.tables set max_players = 4 where id = v_t3;
  insert into public.table_members (table_id, user_id) values (v_t3, v_d);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_d::text, true);
  v_msg := null;
  begin perform public.confirm_win(v_g3); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  delete from public.table_members where table_id = v_t3 and user_id = v_d;
  update public.tables set max_players = 3 where id = v_t3;
  execute v_stateq into v_state using v_g3, v_names;
  if v_msg is distinct from 'You are not a player in this game.'
     or v_msg2 is distinct from 'You can''t confirm your own claim; every other player has to.'
     or v_state is distinct from 'active/-/-/A/' then
    raise exception 'FAIL [T1] 3-player refusals: seated non-player %, claimant %, state %.',
      coalesce(v_msg, 'no error'), coalesce(v_msg2, 'no error'), v_state;
  end if;
  v_checks := v_checks + 1;

  -- [T2] B confirms (one of two): the match goes on. C confirms: won by A.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  perform public.confirm_win(v_g3);
  execute 'reset role';
  execute v_stateq into v_state using v_g3, v_names;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  perform public.confirm_win(v_g3);
  execute 'reset role';
  execute v_stateq into v_state2 using v_g3, v_names;
  if v_state is distinct from 'active/-/-/A/B' or v_state2 is distinct from 'ended/won/A/-/' then
    raise exception 'FAIL [T2] 3-player confirmations: after B %, after C %; expected active/-/-/A/B then ended/won/A/-/.', v_state, v_state2;
  end if;
  v_checks := v_checks + 1;

  -- ==== W: 2 players, exactly as before =======================================
  -- [W1] A claims; B's claim and A's own confirmation are refused with the
  -- 2-player messages, word for word.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  perform public.claim_win(v_g2);
  v_msg2 := null;
  begin perform public.confirm_win(v_g2); exception when others then v_msg2 := sqlerrm; end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.claim_win(v_g2); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  execute v_stateq into v_state using v_g2, v_names;
  if v_msg is distinct from 'The other player has already claimed the win. Confirm it, or wait for them to cancel it.'
     or v_msg2 is distinct from 'You can''t confirm your own claim; the other player has to.'
     or v_state is distinct from 'active/-/-/A/' then
    raise exception 'FAIL [W1] 2-player messages: B''s claim %, A''s confirmation %, state %.',
      coalesce(v_msg, 'no error'), coalesce(v_msg2, 'no error'), v_state;
  end if;
  v_checks := v_checks + 1;

  -- [W2] B confirms: the FIRST confirmation ends it -- won by A, the claim
  -- settled, ready_by empty -- as before.
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.confirm_win(v_g2); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  execute v_stateq into v_state using v_g2, v_names;
  if v_msg is not null or v_state is distinct from 'ended/won/A/-/'
     or (select ready_by from public.games where id = v_g2) <> '{}' then
    raise exception 'FAIL [W2] the 2-player confirmation: refused %, state %; expected ended/won/A/-/.', coalesce(v_msg, 'nothing'), v_state;
  end if;
  v_checks := v_checks + 1;

  -- ==== L (continued): the leaderboard skips Muggins ==========================
  -- [L2] A wins the REGULAR table (a score of 121, as the owner). The
  -- leaderboard, read as A, lists A with 1 win and B with 1 loss, and
  -- nothing else of theirs: A's three Muggins wins (4, 3 and 2 players) and
  -- the Muggins losses of B, C and D are not counted; C and D, who played
  -- only Muggins, are not listed at all.
  perform public.award_points(v_tr, v_a, 121, 'test');
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  select string_agg((v_names ->> lb.user_id::text) || '=' || lb.wins || '/' || lb.losses, ',' order by v_names ->> lb.user_id::text)
  into v_scores
  from public.get_leaderboard() lb
  where lb.user_id in (v_a, v_b, v_c, v_d);
  execute 'reset role';
  if (select status || '/' || coalesce(v_names ->> winner_id::text, '-') from public.games where id = v_gr) is distinct from 'ended/A'
     or v_scores is distinct from 'A=1/0,B=0/1' then
    raise exception 'FAIL [L2] the leaderboard: regular game %, rows %; expected ended/A and A=1/0,B=0/1.',
      (select status || '/' || coalesce(v_names ->> winner_id::text, '-') from public.games where id = v_gr), coalesce(v_scores, 'none');
  end if;
  v_checks := v_checks + 1;

  raise exception 'ALL % CHECKS PASSED (rolled back). A=% B=% C=% D=%.', v_checks, v_a, v_b, v_c, v_d;
end $$;
