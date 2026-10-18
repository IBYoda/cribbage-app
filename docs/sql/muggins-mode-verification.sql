-- Muggins mode: VERIFICATION.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER docs/sql/muggins-mode.sql.
-- The whole file is ONE DO block: run it as is.
--
-- It WRITES -- it creates tables, members, games, hands and plays, scores
-- points, claims and confirms wins, starts matches and ends them every way a
-- game can end, as real players -- and then deliberately raises an exception
-- at the very end, which rolls every write back. It always "fails": the
-- message is the verdict. "ALL n CHECKS PASSED (rolled back) ..." is a pass;
-- anything starting "FAIL" or "SETUP" is not. Re-runnable, because nothing
-- it does survives. (Same pattern as table-visibility-verification.sql and
-- hide-counts-verification.sql: a DO block cannot COMMIT or ROLLBACK itself
-- in the SQL Editor, so the final exception IS the rollback.)
--
-- Same impersonation as the earlier verification scripts:
-- request.jwt.claims plus "set local role authenticated" (or anon) to act as
-- a client, and "reset role" to act as the owner between steps.
--
-- PLAYERS: A and B are the two OLDEST accounts that are NOT admins (an admin
-- would match the admin UPDATE policies). They are seated at three tables
-- created HERE -- one normal, two Muggins -- and every game, hand and play
-- below is created here too. A "stranger" is a random id that sits at no
-- table. The admin, if the project has one, performs the admin Force-End
-- (L2) exactly as the Admin page does; with no admin, the owner runs the
-- same UPDATE. Nothing about the real accounts or tables changes.
--
-- THE TIMEOUT CHECK (L3) calls the REAL end_timed_out_sessions(), so the
-- ended state is exactly what the job produces. That job also ends any REAL
-- game or table that happens to be past its timeout right now -- inside this
-- transaction, so it is rolled back with everything else.
--
-- THE FROZEN now(): a DO block is one transaction, so now() is the same
-- instant all the way through. start_game_with_deal finds "the previous
-- match" by created_at, so every game made here gets an explicit, strictly
-- increasing created_at (v_age counts down in minutes from 200, so every one
-- is under the 5-hour timeout until L3 needs one past it), all before now() --
-- and a game start_game_with_deal itself creates gets now(), the newest.
--
-- WHAT IT CHECKS
--   S  schema and catalog: tables.is_muggins (boolean, NOT NULL, default
--      false, commented); games.win_claim_by (nullable uuid, commented,
--      references auth.users on delete set null); the three tables policies
--      unchanged; no column-level grants on tables; every function's
--      signature, and no restart_game / change_dealer; THIRTEEN client
--      functions executable by authenticated and none by anon; award_points
--      still ungranted; start_game_with_deal byte-for-byte the version in
--      phase2-new-game-ready-gate.sql (md5 of its body); ended_reason still
--      has no 'restarted'.
--   I  inserts: is_muggins true and omitted (false); no table in another's
--      name; a non-admin can't change is_muggins.
--   W  award_points: NORMAL table, 121 still wins (direct, via play_card,
--      via confirm_count), score capped, last_points raw. MUGGINS table: 121
--      and well past it never end the game (direct, pegging via play_card,
--      count via confirm_count), no error, score capped at 121, last_points
--      / last_reason / last_awarded_at written.
--   C  claim_win: a player claims; a repeat is quiet; the other player's
--      claim, a stranger, a normal table, a cutting game, an ended game and
--      anon are refused.
--   X  clear_win_claim: the other player, a stranger and anon are refused;
--      the claimant cancels; with no claim, refused.
--   F  confirm_win: with no claim, by the claimant, by a stranger and by anon
--      refused; the other player's confirm ends the match 'won', winner =
--      the claimant, claim cleared, ready_by empty; then the EXISTING New
--      Game gate: first tap NULL, second starts an ACTIVE game, the LOSER
--      deals, two hands dealt, scores reset.
--   L  LEADERBOARD GUARANTEE, each with a claim pending: leave_table ends
--      'player_left' with no winner; an admin Force-End ends 'admin' with no
--      winner; the timeout ends 'timeout' with no winner.
--   N  normal regression: the New Game gate after a won match (both tap,
--      the loser deals) and after a timeout (one tap, a cut).
--
-- Expected message:
--   ALL 60 CHECKS PASSED (rolled back). A=... B=... (admin Force-End by: ...)

do $$
declare
  v_a uuid;
  v_b uuid;
  v_admin uuid;
  v_stranger uuid := gen_random_uuid();
  v_codes text[];
  v_norm uuid;
  v_mug uuid;
  v_mug2 uuid;
  v_t uuid;
  v_g uuid;
  v_g2 uuid;
  v_ret uuid;
  v_age int := 200;
  v_type text;
  v_nullable text;
  v_default text;
  v_n int;
  v_state text;
  v_msg text;
  v_bool boolean;
  v_rec record;
  v_expect int;
  v_fn text;
  v_status text;
  v_forced_by text;
  v_checks int := 0;
begin
  -- ---- Setup, as the owner ------------------------------------------------
  select u.id into v_a from auth.users u
  where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
  order by u.created_at limit 1;
  select u.id into v_b from auth.users u
  where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
  order by u.created_at offset 1 limit 1;
  if v_a is null or v_b is null then
    raise exception 'SETUP: the project needs at least two accounts that are not admins.';
  end if;
  select ad.user_id into v_admin from public.admin_users ad order by ad.granted_at limit 1;

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

  insert into public.tables (code, created_by) values (v_codes[1], v_a) returning id into v_norm;
  insert into public.tables (code, created_by, is_muggins) values (v_codes[2], v_a, true) returning id into v_mug;
  insert into public.tables (code, created_by, is_muggins) values (v_codes[3], v_a, true) returning id into v_mug2;
  insert into public.table_members (table_id, user_id, joined_at) values
    (v_norm, v_a, now() - interval '2 hours'), (v_norm, v_b, now() - interval '119 minutes'),
    (v_mug, v_a, now() - interval '2 hours'), (v_mug, v_b, now() - interval '119 minutes'),
    (v_mug2, v_a, now() - interval '2 hours'), (v_mug2, v_b, now() - interval '119 minutes');

  -- ==== S: schema and catalog, as the owner ==================================
  -- [S1] tables.is_muggins: boolean, NOT NULL, default false.
  select c.data_type, c.is_nullable, c.column_default into v_type, v_nullable, v_default
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'tables' and c.column_name = 'is_muggins';
  if v_type is distinct from 'boolean' or v_nullable is distinct from 'NO' or v_default is distinct from 'false' then
    raise exception 'FAIL [S1] tables.is_muggins is type % / nullable % / default %, expected boolean / NO / false.',
      coalesce(v_type, '(missing)'), v_nullable, v_default;
  end if;
  v_checks := v_checks + 1;

  -- [S2] ...commented.
  if col_description('public.tables'::regclass,
       (select attnum from pg_attribute where attrelid = 'public.tables'::regclass and attname = 'is_muggins')) is null then
    raise exception 'FAIL [S2] tables.is_muggins has no comment.';
  end if;
  v_checks := v_checks + 1;

  -- [S3] games.win_claim_by: uuid, nullable, no default.
  select c.data_type, c.is_nullable, c.column_default into v_type, v_nullable, v_default
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'games' and c.column_name = 'win_claim_by';
  if v_type is distinct from 'uuid' or v_nullable is distinct from 'YES' or v_default is not null then
    raise exception 'FAIL [S3] games.win_claim_by is type % / nullable % / default %, expected uuid / YES / none.',
      coalesce(v_type, '(missing)'), v_nullable, v_default;
  end if;
  v_checks := v_checks + 1;

  -- [S4] ...commented.
  if col_description('public.games'::regclass,
       (select attnum from pg_attribute where attrelid = 'public.games'::regclass and attname = 'win_claim_by')) is null then
    raise exception 'FAIL [S4] games.win_claim_by has no comment.';
  end if;
  v_checks := v_checks + 1;

  -- [S5] ...a foreign key to auth.users(id), ON DELETE SET NULL.
  select count(*) into v_n
  from pg_constraint con
  where con.conrelid = 'public.games'::regclass
    and con.contype = 'f'
    and con.confrelid = 'auth.users'::regclass
    and con.confdeltype = 'n'
    and con.conkey = array[(select attnum from pg_attribute
                            where attrelid = 'public.games'::regclass and attname = 'win_claim_by')];
  if v_n <> 1 then
    raise exception 'FAIL [S5] games.win_claim_by has % matching foreign key(s) to auth.users ON DELETE SET NULL, expected 1.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [S6] The tables policies are unchanged: exactly the three known ones.
  select count(*) into v_n from pg_policies where schemaname = 'public' and tablename = 'tables';
  if v_n <> 3
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'tables'
                    and cmd = 'SELECT' and policyname = 'Tables are viewable by any logged-in user')
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'tables'
                    and cmd = 'INSERT' and policyname = 'Users can create their own table')
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'tables'
                    and cmd = 'UPDATE' and policyname = 'Admins can force-end tables') then
    raise exception 'FAIL [S6] the tables policies are not exactly the three known ones (found %).', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [S7] No column of tables carries a grant of its own.
  select count(*) into v_n from pg_attribute
  where attrelid = 'public.tables'::regclass and attnum > 0 and not attisdropped and attacl is not null;
  if v_n <> 0 then
    raise exception 'FAIL [S7] % column(s) of tables have column-level grants.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [S8] Every function keeps its signature; the three new ones exist.
  foreach v_fn in array array[
    'public.start_game_with_deal(uuid)', 'public.draw_cut_card(uuid)', 'public.acknowledge_deal_cut(uuid)',
    'public.discard_to_crib(uuid, text[])', 'public.play_card(uuid, text)', 'public.leave_table(uuid)',
    'public.show_hand(uuid)', 'public.show_crib(uuid)', 'public.confirm_count(uuid, int)',
    'public.next_hand(uuid, int)', 'public.claim_win(uuid)', 'public.clear_win_claim(uuid)',
    'public.confirm_win(uuid)', 'public.award_points(uuid, uuid, int, text)', 'public.end_timed_out_sessions()'
  ] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL [S8] function % does not exist with that signature.', v_fn;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- [S9] The superseded design's functions do not exist.
  if to_regprocedure('public.restart_game(uuid)') is not null or to_regprocedure('public.change_dealer(uuid)') is not null then
    raise exception 'FAIL [S9] restart_game or change_dealer exists; this design has neither.';
  end if;
  v_checks := v_checks + 1;

  -- [S10] The THIRTEEN client functions: executable by authenticated, never
  -- by anon (has_function_privilege counts PUBLIC grants too).
  v_n := 0;
  foreach v_fn in array array[
    'public.start_game_with_deal(uuid)', 'public.draw_cut_card(uuid)', 'public.acknowledge_deal_cut(uuid)',
    'public.discard_to_crib(uuid, text[])', 'public.play_card(uuid, text)', 'public.leave_table(uuid)',
    'public.show_hand(uuid)', 'public.show_crib(uuid)', 'public.confirm_count(uuid, int)',
    'public.next_hand(uuid, int)', 'public.claim_win(uuid)', 'public.clear_win_claim(uuid)',
    'public.confirm_win(uuid)'
  ] loop
    if not has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'FAIL [S10] authenticated cannot execute %.', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'FAIL [S10] anon CAN execute %.', v_fn;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 13 then raise exception 'FAIL [S10] checked % client functions, expected 13.', v_n; end if;
  v_checks := v_checks + 1;

  -- [S11] award_points is still not client-callable.
  if has_function_privilege('authenticated', 'public.award_points(uuid, uuid, int, text)', 'execute')
     or has_function_privilege('anon', 'public.award_points(uuid, uuid, int, text)', 'execute') then
    raise exception 'FAIL [S11] award_points is executable by a client role.';
  end if;
  v_checks := v_checks + 1;

  -- [S12] start_game_with_deal is untouched: its body is byte-for-byte the
  -- one in phase2-new-game-ready-gate.sql (md5 of the function body, line
  -- endings normalised).
  select md5(replace(p.prosrc, E'\r', '')) into v_msg
  from pg_proc p
  where p.oid = 'public.start_game_with_deal(uuid)'::regprocedure;
  if v_msg is distinct from '014c7e1fe9683cdc76b65c8fe2cb0d1b' then
    raise exception 'FAIL [S12] start_game_with_deal''s body has md5 %, expected 014c7e1fe9683cdc76b65c8fe2cb0d1b (phase2-new-game-ready-gate.sql).', v_msg;
  end if;
  v_checks := v_checks + 1;

  -- [S13] ended_reason has no 'restarted' (this design adds none).
  v_state := null;
  begin
    insert into public.games (table_id, created_by, status, ended_reason, players)
    values (v_norm, v_a, 'ended', 'restarted', array[v_a, v_b]);
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '23514' then
    raise exception 'FAIL [S13] ended_reason ''restarted'': expected 23514 (check), got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- ==== I: inserts, as A ======================================================
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);

  -- [I1] A creates a Muggins table.
  insert into public.tables (code, created_by, is_muggins) values (v_codes[4], v_a, true)
  returning id, is_muggins into v_t, v_bool;
  if v_bool is distinct from true then raise exception 'FAIL [I1] is_muggins true was stored as %.', v_bool; end if;
  v_checks := v_checks + 1;

  -- [I2] ...and one without saying: a normal table.
  insert into public.tables (code, created_by) values (v_codes[5], v_a) returning is_muggins into v_bool;
  if v_bool is distinct from false then raise exception 'FAIL [I2] an omitted is_muggins reads %, expected false.', v_bool; end if;
  v_checks := v_checks + 1;

  -- [I3] Unchanged rule: no table in B's name.
  v_state := null;
  begin
    insert into public.tables (code, created_by, is_muggins) values (v_codes[6], v_b, true);
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '42501' then
    raise exception 'FAIL [I3] A creating a table as B: expected 42501 (RLS), got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [I4] A (not an admin) cannot switch their own table off Muggins.
  v_state := null; v_n := 0;
  begin
    update public.tables set is_muggins = false where id = v_t;
    get diagnostics v_n = row_count;
  exception when others then v_state := sqlstate;
  end;
  execute 'reset role';
  select is_muggins into v_bool from public.tables where id = v_t;
  if not (v_state = '42501' or (v_state is null and v_n = 0)) or v_bool is distinct from true then
    raise exception 'FAIL [I4] a non-admin update of is_muggins: % row(s), error %, now %.', v_n, coalesce(v_state, 'none'), v_bool;
  end if;
  v_checks := v_checks + 1;

  -- ==== W: award_points ======================================================
  -- ---- W1-W3: NORMAL table, direct call (as the owner, like the SQL Editor).
  insert into public.games (table_id, created_by, status, players, dealer_id, phase, created_at)
  values (v_norm, v_a, 'active', array[v_a, v_b], v_b, 'play', now() - make_interval(mins => v_age))
  returning id into v_g;
  v_age := v_age - 1;
  update public.table_members set score = 119 where table_id = v_norm and user_id = v_a;
  perform public.award_points(v_norm, v_a, 5, 'fifteen + pair');

  -- [W1] 121 still WINS on a normal table.
  select status, ended_reason, winner_id into v_rec from public.games where id = v_g;
  if v_rec.status is distinct from 'ended' or v_rec.ended_reason is distinct from 'won' or v_rec.winner_id is distinct from v_a then
    raise exception 'FAIL [W1] normal table at 121: game is % / % / winner %, expected ended / won / A.', v_rec.status, v_rec.ended_reason, v_rec.winner_id;
  end if;
  v_checks := v_checks + 1;

  -- [W2] ...the score is capped at 121...
  select score, last_points, last_reason into v_rec from public.table_members where table_id = v_norm and user_id = v_a;
  if v_rec.score <> 121 then raise exception 'FAIL [W2] normal score is %, expected 121 (capped).', v_rec.score; end if;
  v_checks := v_checks + 1;

  -- [W3] ...and last_points records the RAW award (5), not the capped 2.
  if v_rec.last_points is distinct from 5 or v_rec.last_reason is distinct from 'fifteen + pair' then
    raise exception 'FAIL [W3] normal last award is % / %, expected 5 / fifteen + pair.', v_rec.last_points, v_rec.last_reason;
  end if;
  v_checks := v_checks + 1;

  -- ---- W4-W8: MUGGINS table, direct call.
  insert into public.games (table_id, created_by, status, players, dealer_id, phase, created_at)
  values (v_mug, v_a, 'active', array[v_a, v_b], v_b, 'play', now() - make_interval(mins => v_age))
  returning id into v_g;
  v_age := v_age - 1;
  update public.table_members set score = 119 where table_id = v_mug and user_id = v_a;

  -- [W4] Reaching 121 raises no error...
  v_msg := null;
  begin
    perform public.award_points(v_mug, v_a, 5, 'fifteen + pair');
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg is not null then raise exception 'FAIL [W4] Muggins award to 121 raised: %.', v_msg; end if;
  v_checks := v_checks + 1;

  -- [W5] ...and does NOT end the game.
  select status, ended_reason, winner_id into v_rec from public.games where id = v_g;
  if v_rec.status is distinct from 'active' or v_rec.ended_reason is not null or v_rec.winner_id is not null then
    raise exception 'FAIL [W5] Muggins at 121: game is % / % / winner %, expected active / null / null.', v_rec.status, v_rec.ended_reason, v_rec.winner_id;
  end if;
  v_checks := v_checks + 1;

  -- [W6] Score still capped at 121; the last award written as usual.
  select score, last_points, last_reason, last_awarded_at into v_rec
  from public.table_members where table_id = v_mug and user_id = v_a;
  if v_rec.score <> 121 or v_rec.last_points is distinct from 5 or v_rec.last_reason is distinct from 'fifteen + pair'
     or v_rec.last_awarded_at is null then
    raise exception 'FAIL [W6] Muggins after the award: score % / last % / % / at %, expected 121 / 5 / fifteen + pair / set.',
      v_rec.score, v_rec.last_points, v_rec.last_reason, v_rec.last_awarded_at;
  end if;
  v_checks := v_checks + 1;

  -- [W7] Well past 121 (a count-sized award): still no error, still live.
  v_msg := null;
  begin
    perform public.award_points(v_mug, v_a, 29, 'hand: 15s 8 + pairs 12 + runs 9');
  exception when others then v_msg := sqlerrm;
  end;
  select status into v_status from public.games where id = v_g;
  if v_msg is not null or v_status is distinct from 'active' then
    raise exception 'FAIL [W7] Muggins award past 121: error % / game %.', coalesce(v_msg, 'none'), v_status;
  end if;
  v_checks := v_checks + 1;

  -- [W8] ...score still 121, last_points the raw 29.
  select score, last_points into v_rec from public.table_members where table_id = v_mug and user_id = v_a;
  if v_rec.score <> 121 or v_rec.last_points is distinct from 29 then
    raise exception 'FAIL [W8] Muggins past 121: score % / last %, expected 121 / 29.', v_rec.score, v_rec.last_points;
  end if;
  v_checks := v_checks + 1;

  -- ---- W9-W11: the PEGGING path (play_card), Muggins. B led a ten (count
  -- 10); A plays a five: fifteen for 2, taking A from 119 to 121.
  update public.games
  set phase = 'play', current_player = v_a, play_count = 10, play_segment = 0,
      starter_card = '9S', discarded_by = array[v_a, v_b]
  where id = v_g;
  insert into public.game_hands (game_id, user_id, cards) values
    (v_g, v_a, array['5H', '2C', '3C', '4C']), (v_g, v_b, array['TC', '2D', '3D', '4D']);
  insert into public.game_plays (game_id, seq, segment, user_id, kind, card, count_after)
  values (v_g, 1, 0, v_b, 'play', 'TC', 10);
  update public.table_members set score = 119 where table_id = v_mug and user_id = v_a;

  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin
    perform public.play_card(v_g, '5H');
  exception when others then v_msg := sqlerrm;
  end;
  execute 'reset role';

  -- [W9] play_card to 121 raises no error.
  if v_msg is not null then raise exception 'FAIL [W9] Muggins play_card to 121 raised: %.', v_msg; end if;
  v_checks := v_checks + 1;

  -- [W10] The game is still live, and the turn passed to B as normal.
  select status, current_player, play_count into v_rec from public.games where id = v_g;
  if v_rec.status is distinct from 'active' or v_rec.current_player is distinct from v_b or v_rec.play_count <> 15 then
    raise exception 'FAIL [W10] Muggins after the play: % / turn % / count %, expected active / B / 15.', v_rec.status, v_rec.current_player, v_rec.play_count;
  end if;
  v_checks := v_checks + 1;

  -- [W11] The fifteen was recorded like any other: 121, +2, "fifteen".
  select score, last_points, last_reason into v_rec from public.table_members where table_id = v_mug and user_id = v_a;
  if v_rec.score <> 121 or v_rec.last_points is distinct from 2 or v_rec.last_reason is distinct from 'fifteen' then
    raise exception 'FAIL [W11] Muggins pegging award: % / % / %, expected 121 / 2 / fifteen.', v_rec.score, v_rec.last_points, v_rec.last_reason;
  end if;
  v_checks := v_checks + 1;

  -- ---- W12-W14: the COUNT path (confirm_count), Muggins. A is the pone and
  -- counts first; the expected points come from score_hand itself.
  update public.games
  set phase = 'counting', count_step = 0, current_player = v_a, starter_card = '5S', revealed_by = '{}'
  where id = v_g;
  update public.game_hands set cards = array['5H', '5D', 'TS', 'JC'] where game_id = v_g and user_id = v_a;
  update public.table_members set score = 110 where table_id = v_mug and user_id = v_a;
  v_expect := (public.score_hand(array['5H', '5D', 'TS', 'JC'], '5S', false) ->> 'points')::int;

  execute 'set local role authenticated';
  v_msg := null;
  begin
    perform public.confirm_count(v_g, 0);
  exception when others then v_msg := sqlerrm;
  end;
  execute 'reset role';

  -- [W12] confirm_count past 121 raises no error.
  if v_msg is not null then raise exception 'FAIL [W12] Muggins confirm_count past 121 raised: %.', v_msg; end if;
  v_checks := v_checks + 1;

  -- [W13] The game is still live and the count moved on to the dealer.
  select status, count_step, current_player into v_rec from public.games where id = v_g;
  if v_rec.status is distinct from 'active' or v_rec.count_step <> 1 or v_rec.current_player is distinct from v_b then
    raise exception 'FAIL [W13] Muggins after the count: % / step % / turn %, expected active / 1 / B.', v_rec.status, v_rec.count_step, v_rec.current_player;
  end if;
  v_checks := v_checks + 1;

  -- [W14] Score capped at 121; last_points the full hand.
  select score, last_points, last_reason into v_rec from public.table_members where table_id = v_mug and user_id = v_a;
  if v_rec.score <> 121 or v_rec.last_points is distinct from v_expect or v_rec.last_reason not like 'hand: %' then
    raise exception 'FAIL [W14] Muggins count award: % / % / %, expected 121 / % / hand: ...', v_rec.score, v_rec.last_points, v_rec.last_reason, v_expect;
  end if;
  v_checks := v_checks + 1;

  -- ---- W15-W16: the same two real paths on a NORMAL table still WIN.
  insert into public.games (table_id, created_by, status, players, dealer_id, phase, current_player,
                            play_count, play_segment, starter_card, discarded_by, created_at)
  values (v_norm, v_a, 'active', array[v_a, v_b], v_b, 'play', v_a, 10, 0, '9S', array[v_a, v_b],
          now() - make_interval(mins => v_age))
  returning id into v_g2;
  v_age := v_age - 1;
  insert into public.game_hands (game_id, user_id, cards) values
    (v_g2, v_a, array['5H', '2C', '3C', '4C']), (v_g2, v_b, array['TC', '2D', '3D', '4D']);
  insert into public.game_plays (game_id, seq, segment, user_id, kind, card, count_after)
  values (v_g2, 1, 0, v_b, 'play', 'TC', 10);
  update public.table_members set score = 119 where table_id = v_norm and user_id = v_a;

  execute 'set local role authenticated';
  perform public.play_card(v_g2, '5H');
  execute 'reset role';

  -- [W15] Normal table, pegging to 121: won, exactly as before.
  select status, ended_reason, winner_id into v_rec from public.games where id = v_g2;
  if v_rec.status is distinct from 'ended' or v_rec.ended_reason is distinct from 'won' or v_rec.winner_id is distinct from v_a then
    raise exception 'FAIL [W15] normal pegging to 121: % / % / %, expected ended / won / A.', v_rec.status, v_rec.ended_reason, v_rec.winner_id;
  end if;
  v_checks := v_checks + 1;

  insert into public.games (table_id, created_by, status, players, dealer_id, phase, count_step, current_player,
                            starter_card, discarded_by, created_at)
  values (v_norm, v_a, 'active', array[v_a, v_b], v_b, 'counting', 0, v_a, '5S', array[v_a, v_b],
          now() - make_interval(mins => v_age))
  returning id into v_g2;
  v_age := v_age - 1;
  insert into public.game_hands (game_id, user_id, cards) values
    (v_g2, v_a, array['5H', '5D', 'TS', 'JC']), (v_g2, v_b, array['2D', '3D', '4D', '6D']);
  update public.table_members set score = 110 where table_id = v_norm and user_id = v_a;

  execute 'set local role authenticated';
  perform public.confirm_count(v_g2, 0);
  execute 'reset role';

  -- [W16] Normal table, a count to 121: won, frozen at the step that won.
  select status, ended_reason, winner_id, count_step into v_rec from public.games where id = v_g2;
  if v_rec.status is distinct from 'ended' or v_rec.ended_reason is distinct from 'won'
     or v_rec.winner_id is distinct from v_a or v_rec.count_step <> 0 then
    raise exception 'FAIL [W16] normal count to 121: % / % / % / step %, expected ended / won / A / 0.',
      v_rec.status, v_rec.ended_reason, v_rec.winner_id, v_rec.count_step;
  end if;
  v_checks := v_checks + 1;

  -- ==== C: claim_win ==========================================================
  -- v_g is the live Muggins game from W (active, counting). A live NORMAL
  -- game, for the refusals.
  insert into public.games (table_id, created_by, status, players, dealer_id, phase, created_at)
  values (v_norm, v_a, 'active', array[v_a, v_b], v_b, 'discard', now() - make_interval(mins => v_age))
  returning id into v_g2;
  v_age := v_age - 1;

  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);

  -- [C1] A claims the win.
  v_msg := null;
  begin perform public.claim_win(v_g); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  select win_claim_by, status into v_rec from public.games where id = v_g;
  if v_msg is not null or v_rec.win_claim_by is distinct from v_a or v_rec.status <> 'active' then
    raise exception 'FAIL [C1] A claiming: error % / claim % / %, expected none / A / active.', coalesce(v_msg, 'none'), v_rec.win_claim_by, v_rec.status;
  end if;
  v_checks := v_checks + 1;

  -- [C2] A claims again: quiet, still A.
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.claim_win(v_g); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  select win_claim_by into v_ret from public.games where id = v_g;
  if v_msg is not null or v_ret is distinct from v_a then
    raise exception 'FAIL [C2] a repeat claim: error % / claim %, expected none / A.', coalesce(v_msg, 'none'), v_ret;
  end if;
  v_checks := v_checks + 1;

  -- [C3] B claims too: refused, and A's claim stands.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.claim_win(v_g); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  select win_claim_by into v_ret from public.games where id = v_g;
  if v_msg is null or v_msg not like '%already claimed%' or v_ret is distinct from v_a then
    raise exception 'FAIL [C3] B claiming over A: %, claim %; expected a refusal and A.', coalesce(v_msg, 'no error'), v_ret;
  end if;
  v_checks := v_checks + 1;

  -- [C4] A stranger is refused.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_stranger::text, true);
  v_msg := null;
  begin perform public.claim_win(v_g); exception when others then v_msg := sqlerrm; end;
  if v_msg is null or v_msg not like '%not a member%' then
    raise exception 'FAIL [C4] a stranger claiming: %, expected "not a member".', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [C5] A normal table is refused.
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.claim_win(v_g2); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  select win_claim_by into v_ret from public.games where id = v_g2;
  if v_msg is null or v_msg not like '%Only a Muggins table%' or v_ret is not null then
    raise exception 'FAIL [C5] claiming on a normal table: %, claim %; expected a refusal and none.', coalesce(v_msg, 'no error'), v_ret;
  end if;
  v_checks := v_checks + 1;

  -- [C6] A game mid-CUT is refused. (v_mug2 is free: no game there yet.)
  insert into public.games (table_id, created_by, status, players, dealer_id, created_at)
  values (v_mug2, v_a, 'cutting', array[v_a, v_b], null, now() - make_interval(mins => v_age))
  returning id into v_t;
  v_age := v_age - 1;
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.claim_win(v_t); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is null or v_msg not like '%live game%' then
    raise exception 'FAIL [C6] claiming mid-cut: %, expected a refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [C7] An ENDED game is refused.
  update public.games set status = 'ended', ended_reason = 'admin' where id = v_t;
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.claim_win(v_t); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is null or v_msg not like '%live game%' then
    raise exception 'FAIL [C7] claiming an ended game: %, expected a refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [C8] anon cannot execute it at all.
  execute 'set local role anon';
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  v_state := null;
  begin perform public.claim_win(v_g); exception when others then v_state := sqlstate; end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [C8] anon claim_win: expected 42501, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- ==== X: clear_win_claim (A holds the claim on v_g) ==========================
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  -- [X1] B can't cancel A's claim.
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.clear_win_claim(v_g); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  select win_claim_by into v_ret from public.games where id = v_g;
  if v_msg is null or v_msg not like '%Only the player who claimed%' or v_ret is distinct from v_a then
    raise exception 'FAIL [X1] B cancelling A''s claim: %, claim %; expected a refusal and A.', coalesce(v_msg, 'no error'), v_ret;
  end if;
  v_checks := v_checks + 1;

  -- [X2] A stranger is refused.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_stranger::text, true);
  v_msg := null;
  begin perform public.clear_win_claim(v_g); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is null or v_msg not like '%not a member%' then
    raise exception 'FAIL [X2] a stranger cancelling: %, expected "not a member".', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [X3] anon cannot execute it at all.
  execute 'set local role anon';
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  v_state := null;
  begin perform public.clear_win_claim(v_g); exception when others then v_state := sqlstate; end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [X3] anon clear_win_claim: expected 42501, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [X4] A, the claimant, cancels.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin perform public.clear_win_claim(v_g); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  select win_claim_by, status into v_rec from public.games where id = v_g;
  if v_msg is not null or v_rec.win_claim_by is not null or v_rec.status <> 'active' then
    raise exception 'FAIL [X4] A cancelling: error % / claim % / %, expected none / null / active.', coalesce(v_msg, 'none'), v_rec.win_claim_by, v_rec.status;
  end if;
  v_checks := v_checks + 1;

  -- [X5] With no claim, cancelling is refused.
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.clear_win_claim(v_g); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is null or v_msg not like '%no win claim%' then
    raise exception 'FAIL [X5] cancelling with no claim: %, expected a refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- ==== F: confirm_win =========================================================
  -- [F1] With no claim, B's confirm is refused.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.confirm_win(v_g); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is null or v_msg not like '%Nobody has claimed%' then
    raise exception 'FAIL [F1] confirming with no claim: %, expected a refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- A claims again. The hand moves to 'done' with a Next Hand tap from B in
  -- ready_by -- it must NOT survive into the won game. The scores are made
  -- non-zero, so the reset can be seen.
  update public.games set phase = 'done', count_step = 2, current_player = null, ready_by = array[v_b] where id = v_g;
  update public.table_members set score = 88, last_points = 3, last_reason = 'pair royal' where table_id = v_mug;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  perform public.claim_win(v_g);

  -- [F2] A can't confirm their own claim.
  v_msg := null;
  begin perform public.confirm_win(v_g); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  select status, win_claim_by into v_rec from public.games where id = v_g;
  if v_msg is null or v_msg not like '%your own claim%' or v_rec.status <> 'active' or v_rec.win_claim_by is distinct from v_a then
    raise exception 'FAIL [F2] A confirming their own claim: %, % / claim %; expected a refusal, active, A.', coalesce(v_msg, 'no error'), v_rec.status, v_rec.win_claim_by;
  end if;
  v_checks := v_checks + 1;

  -- [F3] A stranger is refused.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_stranger::text, true);
  v_msg := null;
  begin perform public.confirm_win(v_g); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is null or v_msg not like '%not a member%' then
    raise exception 'FAIL [F3] a stranger confirming: %, expected "not a member".', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [F4] anon cannot execute it at all.
  execute 'set local role anon';
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  v_state := null;
  begin perform public.confirm_win(v_g); exception when others then v_state := sqlstate; end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [F4] anon confirm_win: expected 42501, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [F5] B confirms: no error.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.confirm_win(v_g); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is not null then raise exception 'FAIL [F5] B confirming A''s claim: %.', v_msg; end if;
  v_checks := v_checks + 1;

  -- [F6] The match ended exactly like a score win: ended / won / winner A --
  -- with the claim settled and ready_by empty (B's Next Hand tap gone).
  select status, ended_reason, winner_id, win_claim_by, ready_by into v_rec from public.games where id = v_g;
  if v_rec.status is distinct from 'ended' or v_rec.ended_reason is distinct from 'won' or v_rec.winner_id is distinct from v_a
     or v_rec.win_claim_by is not null or v_rec.ready_by is distinct from '{}'::uuid[] then
    raise exception 'FAIL [F6] after the confirm: % / % / winner % / claim % / ready %, expected ended / won / A / null / {}.',
      v_rec.status, v_rec.ended_reason, v_rec.winner_id, v_rec.win_claim_by, v_rec.ready_by;
  end if;
  v_checks := v_checks + 1;

  -- [F7] The EXISTING New Game gate: B (the loser) taps -- only recorded.
  -- (v_g is the newest game at v_mug: everything else there is older.)
  execute 'set local role authenticated';
  v_ret := public.start_game_with_deal(v_mug);
  execute 'reset role';
  select count(*) into v_n from public.games where table_id = v_mug and status in ('cutting', 'active');
  if v_ret is not null or v_n <> 0 then
    raise exception 'FAIL [F7] the first New Game tap: result % / % live game(s), expected NULL / 0.', v_ret, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [F8] A taps: the match starts at once -- active, the LOSER (B) deals, two
  -- six-card hands, scores reset.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_ret := public.start_game_with_deal(v_mug);
  execute 'reset role';
  select status, dealer_id into v_rec from public.games where id = v_ret;
  select count(*) into v_n from public.game_hands where game_id = v_ret and coalesce(array_length(cards, 1), 0) = 6;
  if v_ret is null or v_rec.status is distinct from 'active' or v_rec.dealer_id is distinct from v_b or v_n <> 2
     or (select count(*) from public.table_members where table_id = v_mug and score = 0 and last_points is null) <> 2 then
    raise exception 'FAIL [F8] the second tap: game % is % / dealer % / % hands, scores reset?; expected active / B / 2 / yes.',
      v_ret, v_rec.status, v_rec.dealer_id, v_n;
  end if;
  v_checks := v_checks + 1;

  -- ==== L: the LEADERBOARD GUARANTEE -- every other ending records no winner ===
  -- [L1] leave_table, with a claim pending: 'player_left', no winner.
  insert into public.games (table_id, created_by, status, players, dealer_id, phase, created_at)
  values (v_mug2, v_a, 'active', array[v_a, v_b], v_b, 'play', now() - make_interval(mins => v_age))
  returning id into v_t;
  v_age := v_age - 1;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  perform public.claim_win(v_t);
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  perform public.leave_table(v_mug2);
  execute 'reset role';
  select status, ended_reason, winner_id into v_rec from public.games where id = v_t;
  if v_rec.status is distinct from 'ended' or v_rec.ended_reason is distinct from 'player_left' or v_rec.winner_id is not null then
    raise exception 'FAIL [L1] leaving with a claim pending: % / % / winner %, expected ended / player_left / null.', v_rec.status, v_rec.ended_reason, v_rec.winner_id;
  end if;
  v_checks := v_checks + 1;

  -- [L2] An admin Force-End, with a claim pending: the Admin page's own
  -- UPDATE, run as the admin through RLS (as the owner if there is no admin).
  -- v_ret is the live game F8 started at v_mug.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  perform public.claim_win(v_ret);
  execute 'reset role';
  if v_admin is not null then
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_admin::text, true);
    update public.games set status = 'ended', ended_reason = 'admin' where id = v_ret;
    execute 'reset role';
    v_forced_by := 'the admin account';
  else
    update public.games set status = 'ended', ended_reason = 'admin' where id = v_ret;
    v_forced_by := 'the owner (no admin account)';
  end if;
  select status, ended_reason, winner_id into v_rec from public.games where id = v_ret;
  if v_rec.status is distinct from 'ended' or v_rec.ended_reason is distinct from 'admin' or v_rec.winner_id is not null then
    raise exception 'FAIL [L2] an admin Force-End with a claim pending: % / % / winner %, expected ended / admin / null.', v_rec.status, v_rec.ended_reason, v_rec.winner_id;
  end if;
  v_checks := v_checks + 1;

  -- [L3] The timeout, with a claim pending: the REAL end_timed_out_sessions()
  -- on a game six hours old.
  insert into public.games (table_id, created_by, status, players, dealer_id, phase, win_claim_by, created_at)
  values (v_mug, v_a, 'active', array[v_a, v_b], v_b, 'play', v_a, now() - interval '6 hours')
  returning id into v_t;
  perform public.end_timed_out_sessions();
  select status, ended_reason, winner_id into v_rec from public.games where id = v_t;
  if v_rec.status is distinct from 'ended' or v_rec.ended_reason is distinct from 'timeout' or v_rec.winner_id is not null then
    raise exception 'FAIL [L3] a timeout with a claim pending: % / % / winner %, expected ended / timeout / null.', v_rec.status, v_rec.ended_reason, v_rec.winner_id;
  end if;
  v_checks := v_checks + 1;

  -- ==== N: the NORMAL New Game gate is unchanged ===============================
  -- A WON match between A and B (A won): both must tap, then the loser deals.
  update public.games set status = 'ended', ended_reason = 'admin'
  where table_id = v_norm and status in ('cutting', 'active');
  insert into public.games (table_id, created_by, status, ended_reason, winner_id, players, dealer_id, ready_by, created_at)
  values (v_norm, v_a, 'ended', 'won', v_a, array[v_a, v_b], v_a, '{}', now() - make_interval(mins => v_age))
  returning id into v_g;
  v_age := v_age - 1;

  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_ret := public.start_game_with_deal(v_norm);

  -- [N1] After a win, the first tap only records (NULL).
  if v_ret is not null then raise exception 'FAIL [N1] the first tap after a win started game %.', v_ret; end if;
  v_checks := v_checks + 1;

  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_ret := public.start_game_with_deal(v_norm);
  execute 'reset role';

  -- [N2] The second tap starts the match at once: active, the LOSER (B)
  -- deals, two hands dealt.
  select status, dealer_id into v_rec from public.games where id = v_ret;
  select count(*) into v_n from public.game_hands where game_id = v_ret and coalesce(array_length(cards, 1), 0) = 6;
  if v_ret is null or v_rec.status is distinct from 'active' or v_rec.dealer_id is distinct from v_b or v_n <> 2 then
    raise exception 'FAIL [N2] after a won match: game % is % / dealer % / % hands, expected active / B / 2.', v_ret, v_rec.status, v_rec.dealer_id, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [N3] A TIMED-OUT match: one tap, a cut, no gate.
  update public.games set status = 'ended', ended_reason = 'timeout', created_at = now() - make_interval(mins => v_age)
  where id = v_ret;
  v_age := v_age - 1;
  execute 'set local role authenticated';
  v_ret := public.start_game_with_deal(v_norm);
  execute 'reset role';
  select status, dealer_id into v_rec from public.games where id = v_ret;
  if v_ret is null or v_rec.status is distinct from 'cutting' or v_rec.dealer_id is not null then
    raise exception 'FAIL [N3] after a timeout: game % is % / dealer %, expected cutting / null.', v_ret, v_rec.status, v_rec.dealer_id;
  end if;
  v_checks := v_checks + 1;

  raise exception 'ALL % CHECKS PASSED (rolled back). A=% B=% (admin Force-End by: %).', v_checks, v_a, v_b, v_forced_by;
end $$;
