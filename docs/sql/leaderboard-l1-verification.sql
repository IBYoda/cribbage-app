-- Leaderboard, L1: VERIFICATION.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER
-- docs/sql/leaderboard-l1-game-results.sql. The whole file is ONE DO block:
-- run it as is.
--
-- It WRITES -- tables, seats, games, scores and game_results rows -- and
-- then deliberately raises an exception at the very end, which rolls every
-- write back (the test constraint of F included). It always "fails": the
-- message is the verdict. "ALL n CHECKS PASSED (rolled back) ..." is a pass;
-- anything starting "FAIL" or "SETUP" is not. A FAIL or SETUP is raised as
-- an exception too, so it rolls everything back the same way: nothing this
-- file does can survive it. Re-runnable for the same reason.
--
-- Same impersonation as the earlier verification scripts:
-- request.jwt.claims plus "set local role authenticated" (or anon) to act as
-- a client, and "reset role" to act as the owner between steps.
--
-- PLAYERS: A, B, C and D are the four OLDEST accounts that are neither
-- admins nor computer accounts. Every table here is made fresh, with unused
-- codes; the players are seated one at a time, so the seat trigger gives
-- them seats 1, 2, 3, 4 in that order. Games are inserted 'active' by the
-- owner, and won through the REAL paths: award_points (as the game
-- functions call it) and confirm_win (called as a player).
--
-- WHAT IT CHECKS
--   S  catalog: game_results has RLS on, no policies, no privilege for
--      PUBLIC, anon or authenticated (table or column), and is not in the
--      supabase_realtime publication; snapshot_game_result is security
--      definer with search_path public, executable by neither anon nor
--      authenticated; the trigger is AFTER UPDATE, FOR EACH ROW, enabled,
--      calls that function, and has the "becomes 'won'" condition.
--   W  a won game gets one row per player, in games.players order, with
--      each seat's score AT the win (the winner's 121 included) and the
--      right won flags:
--        W1 2 players                      (only the winner won)
--        W2 4 players, Teams               (winner and partner: 1&3 v 2&4)
--        W3 4 players, Solo                (only the winner won)
--        W4 3 players                      (only the winner won)
--        W5 Muggins: 121 does not end it (no rows); confirm_win does (rows,
--           with the scores as they stand)
--   I  idempotent: a later update of a won game (ready_by) adds nothing;
--      a game that becomes 'won' again keeps its FIRST snapshot.
--   E  no rows for a game ended any other way: player_left (through
--      leave_table), admin, timeout -- and none at all for a non-won game.
--   F  a snapshot that fails (a test constraint refuses every row) does NOT
--      block the win: no error, the game is 'ended' / 'won' with its winner
--      and score, and simply has no rows.
--   R  as a signed-in client (a player of the won game) game_results can be
--      neither read nor written; as anon it cannot be read; nobody can call
--      the trigger function (all 42501).
--
-- Expected message:
--   ALL 21 CHECKS PASSED (rolled back). A=... B=... C=... D=...

do $$
declare
  v_a uuid;
  v_b uuid;
  v_c uuid;
  v_d uuid;
  v_codes text[];
  v_t2 uuid;
  v_t4 uuid;
  v_t4s uuid;
  v_t3 uuid;
  v_tm uuid;
  v_tx uuid;
  v_tf uuid;
  v_g2 uuid;
  v_g4 uuid;
  v_g4s uuid;
  v_g3 uuid;
  v_gm uuid;
  v_gx uuid;
  v_gx2 uuid;
  v_gx3 uuid;
  v_gf uuid;
  v_txt text;
  v_status text;
  v_reason text;
  v_winner uuid;
  v_state text;
  v_n int;
  v_n2 int;
  v_score int;
  v_bool boolean;
  v_checks int := 0;
begin
  -- ---- Setup, as the owner ------------------------------------------------
  select u.id into v_a from auth.users u
  where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
    and not exists (select 1 from public.computer_accounts ca where ca.user_id = u.id)
  order by u.created_at limit 1;
  select u.id into v_b from auth.users u
  where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
    and not exists (select 1 from public.computer_accounts ca where ca.user_id = u.id)
  order by u.created_at offset 1 limit 1;
  select u.id into v_c from auth.users u
  where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
    and not exists (select 1 from public.computer_accounts ca where ca.user_id = u.id)
  order by u.created_at offset 2 limit 1;
  select u.id into v_d from auth.users u
  where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
    and not exists (select 1 from public.computer_accounts ca where ca.user_id = u.id)
  order by u.created_at offset 3 limit 1;
  if v_a is null or v_b is null or v_c is null or v_d is null then
    raise exception 'SETUP: the project needs at least four accounts that are neither admins nor computer accounts.';
  end if;
  if to_regclass('public.game_results') is null then
    raise exception 'SETUP: public.game_results does not exist -- run leaderboard-l1-game-results.sql first.';
  end if;

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0'))
    order by n
    limit 7
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 7 then
    raise exception 'SETUP: fewer than seven unused table codes.';
  end if;

  -- Fixture tables (as the owner). Members one at a time: seats 1, 2, 3, 4.
  -- 2 players, regular.
  insert into public.tables (code, created_by) values (v_codes[1], v_a) returning id into v_t2;
  insert into public.table_members (table_id, user_id) values (v_t2, v_a);
  insert into public.table_members (table_id, user_id) values (v_t2, v_b);

  -- 4 players, Teams (team_mode defaults to 'teams').
  insert into public.tables (code, created_by, max_players) values (v_codes[2], v_a, 4) returning id into v_t4;
  insert into public.table_members (table_id, user_id) values (v_t4, v_a);
  insert into public.table_members (table_id, user_id) values (v_t4, v_b);
  insert into public.table_members (table_id, user_id) values (v_t4, v_c);
  insert into public.table_members (table_id, user_id) values (v_t4, v_d);

  -- 4 players, Solo.
  insert into public.tables (code, created_by, max_players, team_mode) values (v_codes[3], v_a, 4, 'solo') returning id into v_t4s;
  insert into public.table_members (table_id, user_id) values (v_t4s, v_a);
  insert into public.table_members (table_id, user_id) values (v_t4s, v_b);
  insert into public.table_members (table_id, user_id) values (v_t4s, v_c);
  insert into public.table_members (table_id, user_id) values (v_t4s, v_d);

  -- 3 players.
  insert into public.tables (code, created_by, max_players) values (v_codes[4], v_a, 3) returning id into v_t3;
  insert into public.table_members (table_id, user_id) values (v_t3, v_a);
  insert into public.table_members (table_id, user_id) values (v_t3, v_b);
  insert into public.table_members (table_id, user_id) values (v_t3, v_c);

  -- Muggins (always 2 players).
  insert into public.tables (code, created_by, is_muggins) values (v_codes[5], v_a, true) returning id into v_tm;
  insert into public.table_members (table_id, user_id) values (v_tm, v_a);
  insert into public.table_members (table_id, user_id) values (v_tm, v_b);

  -- The other endings, and the forced failure: 2 players each.
  insert into public.tables (code, created_by) values (v_codes[6], v_a) returning id into v_tx;
  insert into public.table_members (table_id, user_id) values (v_tx, v_a);
  insert into public.table_members (table_id, user_id) values (v_tx, v_b);

  insert into public.tables (code, created_by) values (v_codes[7], v_a) returning id into v_tf;
  insert into public.table_members (table_id, user_id) values (v_tf, v_a);
  insert into public.table_members (table_id, user_id) values (v_tf, v_b);

  -- The players arrays in seat order, as start_game_with_deal_as writes them.
  insert into public.games (table_id, created_by, status, players)
  values (v_t2, v_a, 'active', array[v_a, v_b]) returning id into v_g2;
  insert into public.games (table_id, created_by, status, players)
  values (v_t4, v_a, 'active', array[v_a, v_b, v_c, v_d]) returning id into v_g4;
  insert into public.games (table_id, created_by, status, players)
  values (v_t4s, v_a, 'active', array[v_a, v_b, v_c, v_d]) returning id into v_g4s;
  insert into public.games (table_id, created_by, status, players)
  values (v_t3, v_a, 'active', array[v_a, v_b, v_c]) returning id into v_g3;
  insert into public.games (table_id, created_by, status, players, win_claim_by)
  values (v_tm, v_a, 'active', array[v_a, v_b], null) returning id into v_gm;
  insert into public.games (table_id, created_by, status, players)
  values (v_tf, v_a, 'active', array[v_a, v_b]) returning id into v_gf;

  -- ==== S: catalog, as the owner ==============================================
  -- [S1] game_results: RLS on, no policies, no client privilege (table ACL,
  -- column ACLs, has_table_privilege), not in the Realtime publication.
  select c.relrowsecurity into v_bool from pg_class c where c.oid = 'public.game_results'::regclass;
  select count(*) into v_n from pg_policies p where p.schemaname = 'public' and p.tablename = 'game_results';
  select count(*) into v_n2
  from pg_class c,
       aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
  where c.oid = 'public.game_results'::regclass
    and (a.grantee = 0 or a.grantee in (select r.oid from pg_roles r where r.rolname in ('anon', 'authenticated')));
  if v_bool is distinct from true or v_n <> 0 or v_n2 <> 0
     or exists (select 1 from pg_attribute at
                where at.attrelid = 'public.game_results'::regclass and at.attnum > 0 and at.attacl is not null)
     or has_table_privilege('authenticated', 'public.game_results', 'select, insert, update, delete, truncate, references, trigger')
     or has_table_privilege('anon', 'public.game_results', 'select, insert, update, delete, truncate, references, trigger')
     or exists (select 1 from pg_publication_tables pt
                where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = 'game_results') then
    raise exception 'FAIL [S1] game_results: RLS %, % policies, % client grant(s), or column grants / Realtime; expected on, none, none.', v_bool, v_n, v_n2;
  end if;
  v_checks := v_checks + 1;

  -- [S2] snapshot_game_result: security definer, search_path public, not
  -- executable by anon or authenticated (has_function_privilege counts
  -- PUBLIC grants too).
  select count(*) into v_n from pg_proc p
  where p.oid = to_regprocedure('public.snapshot_game_result()')
    and p.prosecdef and p.proconfig = array['search_path=public'];
  if v_n <> 1
     or has_function_privilege('authenticated', 'public.snapshot_game_result()', 'execute')
     or has_function_privilege('anon', 'public.snapshot_game_result()', 'execute') then
    raise exception 'FAIL [S2] snapshot_game_result: definer/search_path found %, or executable by a client role.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [S3] The trigger: on games, enabled, AFTER UPDATE FOR EACH ROW, calling
  -- snapshot_game_result, with the "becomes 'won'" condition.
  select pg_get_triggerdef(t.oid) into v_txt
  from pg_trigger t
  where t.tgrelid = 'public.games'::regclass
    and t.tgname = 'games_snapshot_result_on_win'
    and not t.tgisinternal
    and t.tgenabled = 'O'
    and t.tgfoid = to_regprocedure('public.snapshot_game_result()');
  if v_txt is null
     or v_txt not like '%AFTER UPDATE ON %games FOR EACH ROW%'
     or v_txt not like '%new.ended_reason = ''won''%'
     or v_txt not like '%old.ended_reason IS DISTINCT FROM ''won''%' then
    raise exception 'FAIL [S3] trigger: %.', coalesce(v_txt, 'missing or disabled');
  end if;
  v_checks := v_checks + 1;

  -- ==== W: won games ===========================================================
  -- Each row as "position:score:won", and how many rows are NOT the player
  -- at their position in games.players (must be 0).

  -- [W1] 2 players: A at 115 scores 6 and wins at 121; B is on 80.
  update public.table_members set score = 115 where table_id = v_t2 and user_id = v_a;
  update public.table_members set score = 80 where table_id = v_t2 and user_id = v_b;
  perform public.award_points(v_t2, v_a, 6, 'verify: winning points');
  select g.status, g.ended_reason, g.winner_id into v_status, v_reason, v_winner from public.games g where g.id = v_g2;
  select string_agg(r.position || ':' || coalesce(r.score::text, 'null') || ':' || case when r.won then 't' else 'f' end, ',' order by r.position),
         count(*) filter (where r.user_id is distinct from g.players[r.position]),
         count(*) filter (where r.created_at is null)
  into v_txt, v_n, v_n2
  from public.game_results r join public.games g on g.id = r.game_id
  where r.game_id = v_g2;
  if v_status is distinct from 'ended' or v_reason is distinct from 'won' or v_winner is distinct from v_a
     or v_txt is distinct from '1:121:t,2:80:f' or v_n <> 0 or v_n2 <> 0 then
    raise exception 'FAIL [W1] 2-player win: game %/%/%, rows %, % misplaced, % without created_at; expected ended/won/A and 1:121:t,2:80:f.', v_status, v_reason, v_winner, coalesce(v_txt, 'none'), v_n, v_n2;
  end if;
  v_checks := v_checks + 1;

  -- [W2] 4 players, Teams: A & C (seats 1, 3) on 118, B & D (2, 4) on 70.
  -- C scores 3: both partners' rows reach 121, C is the winner, A won too.
  update public.table_members set score = 118 where table_id = v_t4 and user_id in (v_a, v_c);
  update public.table_members set score = 70 where table_id = v_t4 and user_id in (v_b, v_d);
  perform public.award_points(v_t4, v_c, 3, 'verify: winning points');
  select g.winner_id into v_winner from public.games g where g.id = v_g4 and g.ended_reason = 'won';
  select string_agg(r.position || ':' || coalesce(r.score::text, 'null') || ':' || case when r.won then 't' else 'f' end, ',' order by r.position),
         count(*) filter (where r.user_id is distinct from g.players[r.position])
  into v_txt, v_n
  from public.game_results r join public.games g on g.id = r.game_id
  where r.game_id = v_g4;
  if v_winner is distinct from v_c or v_txt is distinct from '1:121:t,2:70:f,3:121:t,4:70:f' or v_n <> 0 then
    raise exception 'FAIL [W2] Teams win: winner % (expected C), rows %, % misplaced; expected 1:121:t,2:70:f,3:121:t,4:70:f.', v_winner, coalesce(v_txt, 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [W3] 4 players, Solo: A 50, B 60, C 118, D 40; C scores 5 and wins.
  -- Only C won -- position 1 is NOT C's partner on a Solo table.
  update public.table_members set score = 50 where table_id = v_t4s and user_id = v_a;
  update public.table_members set score = 60 where table_id = v_t4s and user_id = v_b;
  update public.table_members set score = 118 where table_id = v_t4s and user_id = v_c;
  update public.table_members set score = 40 where table_id = v_t4s and user_id = v_d;
  perform public.award_points(v_t4s, v_c, 5, 'verify: winning points');
  select string_agg(r.position || ':' || coalesce(r.score::text, 'null') || ':' || case when r.won then 't' else 'f' end, ',' order by r.position),
         count(*) filter (where r.user_id is distinct from g.players[r.position])
  into v_txt, v_n
  from public.game_results r join public.games g on g.id = r.game_id
  where r.game_id = v_g4s;
  if v_txt is distinct from '1:50:f,2:60:f,3:121:t,4:40:f' or v_n <> 0 then
    raise exception 'FAIL [W3] Solo win: rows %, % misplaced; expected 1:50:f,2:60:f,3:121:t,4:40:f.', coalesce(v_txt, 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [W4] 3 players: A 30, B 120, C 89; B scores 2 (capped at 121) and wins.
  update public.table_members set score = 30 where table_id = v_t3 and user_id = v_a;
  update public.table_members set score = 120 where table_id = v_t3 and user_id = v_b;
  update public.table_members set score = 89 where table_id = v_t3 and user_id = v_c;
  perform public.award_points(v_t3, v_b, 2, 'verify: winning points');
  select string_agg(r.position || ':' || coalesce(r.score::text, 'null') || ':' || case when r.won then 't' else 'f' end, ',' order by r.position),
         count(*) filter (where r.user_id is distinct from g.players[r.position])
  into v_txt, v_n
  from public.game_results r join public.games g on g.id = r.game_id
  where r.game_id = v_g3;
  if v_txt is distinct from '1:30:f,2:121:t,3:89:f' or v_n <> 0 then
    raise exception 'FAIL [W4] 3-player win: rows %, % misplaced; expected 1:30:f,2:121:t,3:89:f.', coalesce(v_txt, 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [W5a] Muggins: A at 115 scores 10 -- recorded (capped at 121) but the
  -- game stays live, so no rows.
  update public.table_members set score = 115 where table_id = v_tm and user_id = v_a;
  update public.table_members set score = 30 where table_id = v_tm and user_id = v_b;
  perform public.award_points(v_tm, v_a, 10, 'verify: no win on Muggins');
  select g.status into v_status from public.games g where g.id = v_gm;
  select count(*) into v_n from public.game_results r where r.game_id = v_gm;
  if v_status is distinct from 'active' or v_n <> 0 then
    raise exception 'FAIL [W5a] Muggins 121: game %, % row(s); expected active and none.', v_status, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [W5b] Muggins: A claims, B confirms (as B, through confirm_win): rows
  -- with the scores as they stand, A won.
  update public.games set win_claim_by = v_a where id = v_gm;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  perform public.confirm_win(v_gm);
  execute 'reset role';
  select g.ended_reason, g.winner_id into v_reason, v_winner from public.games g where g.id = v_gm;
  select string_agg(r.position || ':' || coalesce(r.score::text, 'null') || ':' || case when r.won then 't' else 'f' end, ',' order by r.position)
  into v_txt
  from public.game_results r
  where r.game_id = v_gm;
  if v_reason is distinct from 'won' or v_winner is distinct from v_a or v_txt is distinct from '1:121:t,2:30:f' then
    raise exception 'FAIL [W5b] Muggins confirm_win: game %/%, rows %; expected won/A and 1:121:t,2:30:f.', v_reason, v_winner, coalesce(v_txt, 'none');
  end if;
  v_checks := v_checks + 1;

  -- ==== I: idempotent ==========================================================
  -- [I1] A later update of the won game (the New Game gate's ready_by) does
  -- not fire the trigger: still the same two rows.
  update public.games set ready_by = array[v_a] where id = v_g2;
  select count(*) into v_n from public.game_results r where r.game_id = v_g2;
  if v_n <> 2 then
    raise exception 'FAIL [I1] update of a won game: % row(s); expected 2.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [I2] The seats reset (as a new game would), then the game made 'won'
  -- again (away and back): the trigger fires, but the FIRST snapshot stays.
  update public.table_members set score = 0 where table_id = v_t2;
  update public.games set ended_reason = 'admin' where id = v_g2;
  update public.games set ended_reason = 'won' where id = v_g2;
  select string_agg(r.position || ':' || coalesce(r.score::text, 'null') || ':' || case when r.won then 't' else 'f' end, ',' order by r.position)
  into v_txt
  from public.game_results r
  where r.game_id = v_g2;
  if v_txt is distinct from '1:121:t,2:80:f' then
    raise exception 'FAIL [I2] won twice: rows %; expected the first snapshot 1:121:t,2:80:f.', coalesce(v_txt, 'none');
  end if;
  v_checks := v_checks + 1;

  -- ==== E: other endings, no rows ==============================================
  -- [E1] player_left, through leave_table as B.
  update public.table_members set score = 100 where table_id = v_tx;
  insert into public.games (table_id, created_by, status, players)
  values (v_tx, v_a, 'active', array[v_a, v_b]) returning id into v_gx;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  perform public.leave_table(v_tx);
  execute 'reset role';
  select g.status, g.ended_reason into v_status, v_reason from public.games g where g.id = v_gx;
  select count(*) into v_n from public.game_results r where r.game_id = v_gx;
  if v_status is distinct from 'ended' or v_reason is distinct from 'player_left' or v_n <> 0 then
    raise exception 'FAIL [E1] player_left: game %/%, % row(s); expected ended/player_left and none.', v_status, v_reason, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [E2] admin (an admin's force-end writes exactly this).
  insert into public.games (table_id, created_by, status, players)
  values (v_tx, v_a, 'active', array[v_a, v_b]) returning id into v_gx2;
  update public.games set status = 'ended', ended_reason = 'admin' where id = v_gx2;
  select count(*) into v_n from public.game_results r where r.game_id = v_gx2;
  if v_n <> 0 then
    raise exception 'FAIL [E2] admin end: % row(s); expected none.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [E3] timeout (end_timed_out_sessions writes exactly this).
  insert into public.games (table_id, created_by, status, players)
  values (v_tx, v_a, 'active', array[v_a, v_b]) returning id into v_gx3;
  update public.games set status = 'ended', ended_reason = 'timeout' where id = v_gx3;
  select count(*) into v_n from public.game_results r where r.game_id = v_gx3;
  if v_n <> 0 then
    raise exception 'FAIL [E3] timeout: % row(s); expected none.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [E4] Across this run, rows only ever belong to won games.
  select count(*) into v_n
  from public.game_results r join public.games g on g.id = r.game_id
  where g.table_id in (v_t2, v_t4, v_t4s, v_t3, v_tm, v_tx, v_tf)
    and g.ended_reason is distinct from 'won';
  if v_n <> 0 then
    raise exception 'FAIL [E4] % row(s) for games that were not won.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- ==== F: a failing snapshot never blocks the win =============================
  -- A test constraint (NOT VALID: existing rows are not checked) refuses
  -- every new row, so the snapshot's insert fails inside its own block.
  alter table public.game_results add constraint l1_verify_force_fail check (false) not valid;

  -- [F1] A wins on 121 with no error raised; the game is ended/won/A.
  update public.table_members set score = 119 where table_id = v_tf and user_id = v_a;
  update public.table_members set score = 40 where table_id = v_tf and user_id = v_b;
  v_state := null;
  begin
    perform public.award_points(v_tf, v_a, 2, 'verify: winning points, snapshot fails');
  exception when others then
    v_state := sqlstate || ' ' || sqlerrm;
  end;
  select g.status, g.ended_reason, g.winner_id into v_status, v_reason, v_winner from public.games g where g.id = v_gf;
  if v_state is not null or v_status is distinct from 'ended' or v_reason is distinct from 'won' or v_winner is distinct from v_a then
    raise exception 'FAIL [F1] failing snapshot: error %, game %/%/%; expected no error and ended/won/A.', coalesce(v_state, 'none'), v_status, v_reason, v_winner;
  end if;
  v_checks := v_checks + 1;

  -- [F2] The win's score stands, and the game simply has no rows.
  select tm.score into v_score from public.table_members tm where tm.table_id = v_tf and tm.user_id = v_a;
  select count(*) into v_n from public.game_results r where r.game_id = v_gf;
  if v_score is distinct from 121 or v_n <> 0 then
    raise exception 'FAIL [F2] after the failed snapshot: A on %, % row(s); expected 121 and none.', v_score, v_n;
  end if;
  v_checks := v_checks + 1;

  alter table public.game_results drop constraint l1_verify_force_fail;

  -- ==== R: no client access ====================================================
  -- As A, a player of every won game above.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);

  -- [R1] Read: refused.
  v_state := null;
  begin
    select count(*) into v_n from public.game_results;
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from '42501' then
    execute 'reset role';
    raise exception 'FAIL [R1] authenticated reading game_results: expected 42501, got %.', coalesce(v_state, 'no error -- ' || v_n || ' row(s) visible');
  end if;
  v_checks := v_checks + 1;

  -- [R2] Write: refused.
  v_state := null;
  begin
    insert into public.game_results (game_id, user_id, position, score, won) values (v_gx, v_a, 1, 121, true);
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from '42501' then
    execute 'reset role';
    raise exception 'FAIL [R2] authenticated inserting into game_results: expected 42501, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [R3] Calling the trigger function: refused.
  v_state := null;
  begin
    perform public.snapshot_game_result();
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from '42501' then
    execute 'reset role';
    raise exception 'FAIL [R3] authenticated calling snapshot_game_result: expected 42501, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [R4] anon: read refused too.
  execute 'reset role';
  execute 'set local role anon';
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  v_state := null;
  begin
    select count(*) into v_n from public.game_results;
  exception when others then
    v_state := sqlstate;
  end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [R4] anon reading game_results: expected 42501, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- ---- Verdict ----------------------------------------------------------------
  if v_checks <> 21 then
    raise exception 'FAIL: % checks ran, expected 21.', v_checks;
  end if;

  raise exception 'ALL % CHECKS PASSED (rolled back). A=% B=% C=% D=%', v_checks, v_a, v_b, v_c, v_d;
end;
$$;
