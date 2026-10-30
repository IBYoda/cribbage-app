-- Leaderboard, L2: VERIFICATION.
--
-- SUPERSEDED once leaderboard-l3-hidden-accounts.sql is applied: run
-- docs/sql/leaderboard-l3-verification.sql instead, which keeps every check
-- below that still applies and adds the hidden-account checks.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER
-- docs/sql/leaderboard-l2-function.sql (L1 applied too). The whole file is
-- ONE DO block: run it as is.
--
-- It WRITES -- tables, games, game_results rows, profile nicknames, maybe a
-- computer_accounts row, and two helper functions in pg_temp -- and then
-- deliberately raises an exception at the very end, which rolls every write
-- back. It always "fails": the message is the verdict. "ALL n CHECKS PASSED
-- (rolled back) ..." is a pass; anything starting "FAIL" or "SETUP" is not.
-- A FAIL or SETUP is raised as an exception too, so it rolls everything back
-- the same way: nothing this file does can survive it. Re-runnable for the
-- same reason.
--
-- Same impersonation as the earlier verification scripts:
-- request.jwt.claims plus "set local role authenticated" (or anon) to act as
-- a client, and "reset role" to act as the owner between steps.
--
-- MEASURED AS CHANGES. get_leaderboard() counts EVERY game in the database,
-- and the players here are real accounts that may have real games. So each
-- step takes a snapshot of the players' six totals before, adds its games,
-- and checks the CHANGE (wins, losses, skunks, double_skunks,
-- times_skunked, beat_god), written "w,l,s,ds,ts,bg".
--
-- PLAYERS: A, B, C and D are the four OLDEST accounts that are neither
-- admins nor computer accounts; any of them with a blank nickname gets one
-- for this run. GOD is the 'hard' computer account; if none is set up, the
-- fifth such account is made 'hard' for this run.
--
-- FIXTURES: fresh tables with unused codes, and games INSERTED straight as
-- they end ('ended' / 'won', winner, players), dated an hour back. Inserted,
-- not updated, so L1's trigger does NOT fire: each game's game_results rows
-- (or none) are written here, exactly as the step needs them. game_results'
-- won column is filled but not read (get_leaderboard decides who won from
-- games).
--
-- WHAT IT CHECKS
--   S1  catalog: security definer, search_path public, stable, the exact
--       result columns and types; EXECUTE for authenticated, not anon or
--       PUBLIC.
--   W1  a 2-player win and loss (91+: no skunk).
--   K1-4  the skunk boundaries: loser on 91 (neither), 90 and 61 (skunk),
--       60 (double skunk; a times_skunked too).
--   R1  a won game with NO game_results rows (as before L1): wins/losses,
--       no skunk. R2: a loser's null score is ignored.
--   T1  4-player Teams: both partners win, both opponents lose; a skunked
--       team counts ONCE for each winner and gives both losers a
--       times_skunked.
--   O1  4-player Solo: only the winner wins; a double skunk, a skunk and a
--       loser on 100 in one game. O2: 3 players, two skunked losers give the
--       winner +2.
--   X1-4  not counted at all: Muggins, an easy-computer game, games ended
--       player_left / admin / timeout (even with a winner and scores set),
--       and an unfinished game.
--   G1  a win at a hard-computer table: beat_god only (no W/L, and its
--       scores never make a skunk). G2: God winning there counts for
--       nobody listed.
--   C1  no computer account is ever a row (God included).
--   N1  a blank nickname is not listed. N2: every row has a counted game or
--       a Beat God.
--   Z1  skunk_tracking_since is min(game_results.created_at), on every row.
--   O3  rows come back ordered wins desc, losses asc, nickname.
--   P1  anon cannot execute it (42501). P2: a signed-in player can.
--
-- Expected message:
--   ALL 24 CHECKS PASSED (rolled back). A=... B=... C=... D=... God=...

do $$
declare
  v_a uuid;
  v_b uuid;
  v_c uuid;
  v_d uuid;
  v_e uuid;
  v_god uuid;
  v_ids uuid[];
  v_codes text[];
  v_t2 uuid;
  v_t3 uuid;
  v_t4 uuid;
  v_t4s uuid;
  v_tmug uuid;
  v_teasy uuid;
  v_thard uuid;
  v_tlive uuid;
  v_before jsonb;
  v_after jsonb;
  v_zero text := '0,0,0,0,0,0';
  v_txt text;
  v_state text;
  v_n int;
  v_n2 int;
  v_min timestamptz;
  v_checks int := 0;
begin
  -- ---- Setup, as the owner ------------------------------------------------
  if to_regprocedure('public.get_leaderboard()') is null or to_regclass('public.game_results') is null then
    raise exception 'SETUP: run leaderboard-l1-game-results.sql and leaderboard-l2-function.sql first.';
  end if;

  select array_agg(x.id order by x.created_at) into v_ids
  from (
    select u.id, u.created_at from auth.users u
    where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
      and not exists (select 1 from public.computer_accounts ca where ca.user_id = u.id)
    order by u.created_at
    limit 5
  ) x;
  v_a := v_ids[1];
  v_b := v_ids[2];
  v_c := v_ids[3];
  v_d := v_ids[4];
  v_e := v_ids[5];
  if v_d is null then
    raise exception 'SETUP: the project needs at least four accounts that are neither admins nor computer accounts.';
  end if;

  select ca.user_id into v_god from public.computer_accounts ca where ca.level = 'hard';
  if v_god is null then
    if v_e is null then
      raise exception 'SETUP: no hard computer account, and no fifth account to stand in for it.';
    end if;
    insert into public.computer_accounts (level, user_id) values ('hard', v_e);
    v_god := v_e;
  end if;

  -- Everyone here gets a non-blank nickname (kept if they have one), so
  -- only the rules decide who is listed.
  insert into public.profiles as pr (id, nickname)
  select x.id, 'L2 Verify ' || left(x.id::text, 8)
  from unnest(array[v_a, v_b, v_c, v_d, v_god]) as x(id)
  on conflict (id) do update
    set nickname = case when btrim(pr.nickname) = '' then excluded.nickname
                        else pr.nickname end;

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

  insert into public.tables (code, created_by) values (v_codes[1], v_a) returning id into v_t2;
  insert into public.tables (code, created_by, max_players) values (v_codes[2], v_a, 3) returning id into v_t3;
  insert into public.tables (code, created_by, max_players, team_mode) values (v_codes[3], v_a, 4, 'teams') returning id into v_t4;
  insert into public.tables (code, created_by, max_players, team_mode) values (v_codes[4], v_a, 4, 'solo') returning id into v_t4s;
  insert into public.tables (code, created_by, is_muggins) values (v_codes[5], v_a, true) returning id into v_tmug;
  insert into public.tables (code, created_by, computer_level) values (v_codes[6], v_a, 'easy') returning id into v_teasy;
  insert into public.tables (code, created_by, computer_level) values (v_codes[7], v_a, 'hard') returning id into v_thard;
  insert into public.tables (code, created_by) values (v_codes[8], v_a) returning id into v_tlive;

  -- Helpers (pg_temp, rolled back with everything else).
  -- l2_snap: each listed player's six totals, keyed by user id.
  create function pg_temp.l2_snap(p_ids uuid[]) returns jsonb
  language sql
  as $f$
    select coalesce(jsonb_object_agg(l.user_id::text,
             jsonb_build_array(l.wins, l.losses, l.skunks, l.double_skunks, l.times_skunked, l.beat_god)),
             '{}'::jsonb)
    from public.get_leaderboard() l
    where l.user_id = any(p_ids);
  $f$;

  -- l2_delta: one player's change between two snapshots, "w,l,s,ds,ts,bg";
  -- 'absent' if they are not listed afterwards.
  create function pg_temp.l2_delta(p_before jsonb, p_after jsonb, p_id uuid) returns text
  language sql
  as $f$
    select case
      when p_after ? p_id::text then
        (select string_agg((((p_after -> (p_id::text)) ->> i)::int
                            - coalesce(((p_before -> (p_id::text)) ->> i)::int, 0))::text, ',' order by i)
         from generate_series(0, 5) as i)
      else 'absent'
    end;
  $f$;

  -- l2_game: a game inserted as it ended, plus its game_results rows when
  -- p_scores is given (one per player, by position; null = no score).
  create function pg_temp.l2_game(p_table uuid, p_by uuid, p_players uuid[], p_status text,
                                  p_reason text, p_winner uuid, p_scores int[]) returns uuid
  language plpgsql
  as $f$
  declare
    v_id uuid;
  begin
    insert into public.games (table_id, created_by, status, ended_reason, players, winner_id, created_at)
    values (p_table, p_by, p_status, p_reason, p_players, p_winner, now() - interval '1 hour')
    returning id into v_id;
    if p_scores is not null then
      insert into public.game_results (game_id, user_id, position, score, won)
      select v_id, x.uid, x.pos::smallint, p_scores[x.pos::int], coalesce(x.uid = p_winner, false)
      from unnest(p_players) with ordinality as x(uid, pos);
    end if;
    return v_id;
  end;
  $f$;

  v_ids := array[v_a, v_b, v_c, v_d, v_god];

  -- ==== S1: catalog ===========================================================
  select pg_get_function_result(p.oid) into v_txt
  from pg_proc p
  where p.oid = to_regprocedure('public.get_leaderboard()')
    and p.prosecdef and p.proconfig = array['search_path=public'] and p.provolatile = 's';
  select count(*) into v_n
  from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where p.oid = to_regprocedure('public.get_leaderboard()') and a.grantee = 0;
  if v_txt is distinct from 'TABLE(user_id uuid, nickname text, avatar_url text, wins integer, losses integer, skunks integer, double_skunks integer, times_skunked integer, beat_god integer, skunk_tracking_since timestamp with time zone)'
     or v_n <> 0
     or not has_function_privilege('authenticated', 'public.get_leaderboard()', 'execute')
     or has_function_privilege('anon', 'public.get_leaderboard()', 'execute') then
    raise exception 'FAIL [S1] get_leaderboard: result %, % PUBLIC grant(s), or wrong EXECUTE / definer / search_path / stable.', coalesce(v_txt, '(not found as definer, search_path public, stable)'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- ==== W, K: 2 players ========================================================
  -- [W1] A beats B, B on 95: a plain win and loss.
  v_before := pg_temp.l2_snap(v_ids);
  perform pg_temp.l2_game(v_t2, v_a, array[v_a, v_b], 'ended', 'won', v_a, array[121, 95]);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_a) <> '1,0,0,0,0,0' or pg_temp.l2_delta(v_before, v_after, v_b) <> '0,1,0,0,0,0' then
    raise exception 'FAIL [W1] 2-player win: A %, B %; expected 1,0,0,0,0,0 and 0,1,0,0,0,0.', pg_temp.l2_delta(v_before, v_after, v_a), pg_temp.l2_delta(v_before, v_after, v_b);
  end if;
  v_checks := v_checks + 1;

  -- [K1] B beats A, A on 91: neither.
  v_before := v_after;
  perform pg_temp.l2_game(v_t2, v_a, array[v_a, v_b], 'ended', 'won', v_b, array[91, 121]);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_b) <> '1,0,0,0,0,0' or pg_temp.l2_delta(v_before, v_after, v_a) <> '0,1,0,0,0,0' then
    raise exception 'FAIL [K1] loser on 91: B %, A %; expected 1,0,0,0,0,0 and 0,1,0,0,0,0.', pg_temp.l2_delta(v_before, v_after, v_b), pg_temp.l2_delta(v_before, v_after, v_a);
  end if;
  v_checks := v_checks + 1;

  -- [K2] A beats B, B on 90: a skunk.
  v_before := v_after;
  perform pg_temp.l2_game(v_t2, v_a, array[v_a, v_b], 'ended', 'won', v_a, array[121, 90]);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_a) <> '1,0,1,0,0,0' or pg_temp.l2_delta(v_before, v_after, v_b) <> '0,1,0,0,1,0' then
    raise exception 'FAIL [K2] loser on 90: A %, B %; expected 1,0,1,0,0,0 and 0,1,0,0,1,0.', pg_temp.l2_delta(v_before, v_after, v_a), pg_temp.l2_delta(v_before, v_after, v_b);
  end if;
  v_checks := v_checks + 1;

  -- [K3] A beats B, B on 61: a skunk.
  v_before := v_after;
  perform pg_temp.l2_game(v_t2, v_a, array[v_a, v_b], 'ended', 'won', v_a, array[121, 61]);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_a) <> '1,0,1,0,0,0' or pg_temp.l2_delta(v_before, v_after, v_b) <> '0,1,0,0,1,0' then
    raise exception 'FAIL [K3] loser on 61: A %, B %; expected 1,0,1,0,0,0 and 0,1,0,0,1,0.', pg_temp.l2_delta(v_before, v_after, v_a), pg_temp.l2_delta(v_before, v_after, v_b);
  end if;
  v_checks := v_checks + 1;

  -- [K4] A beats B, B on 60: a double skunk (and a times_skunked).
  v_before := v_after;
  perform pg_temp.l2_game(v_t2, v_a, array[v_a, v_b], 'ended', 'won', v_a, array[121, 60]);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_a) <> '1,0,0,1,0,0' or pg_temp.l2_delta(v_before, v_after, v_b) <> '0,1,0,0,1,0' then
    raise exception 'FAIL [K4] loser on 60: A %, B %; expected 1,0,0,1,0,0 and 0,1,0,0,1,0.', pg_temp.l2_delta(v_before, v_after, v_a), pg_temp.l2_delta(v_before, v_after, v_b);
  end if;
  v_checks := v_checks + 1;

  -- ==== R: no saved scores ======================================================
  -- [R1] A beats B with NO game_results rows (a game won before L1): W/L
  -- only, even though nothing says B wasn't skunked.
  v_before := v_after;
  perform pg_temp.l2_game(v_t2, v_a, array[v_a, v_b], 'ended', 'won', v_a, null);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_a) <> '1,0,0,0,0,0' or pg_temp.l2_delta(v_before, v_after, v_b) <> '0,1,0,0,0,0' then
    raise exception 'FAIL [R1] no game_results: A %, B %; expected 1,0,0,0,0,0 and 0,1,0,0,0,0.', pg_temp.l2_delta(v_before, v_after, v_a), pg_temp.l2_delta(v_before, v_after, v_b);
  end if;
  v_checks := v_checks + 1;

  -- [R2] A beats B, B's saved score null: ignored, W/L only.
  v_before := v_after;
  perform pg_temp.l2_game(v_t2, v_a, array[v_a, v_b], 'ended', 'won', v_a, array[121, null]);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_a) <> '1,0,0,0,0,0' or pg_temp.l2_delta(v_before, v_after, v_b) <> '0,1,0,0,0,0' then
    raise exception 'FAIL [R2] null score: A %, B %; expected 1,0,0,0,0,0 and 0,1,0,0,0,0.', pg_temp.l2_delta(v_before, v_after, v_a), pg_temp.l2_delta(v_before, v_after, v_b);
  end if;
  v_checks := v_checks + 1;

  -- ==== T, O: 4 and 3 players ===================================================
  -- [T1] Teams, seats A B C D: C (seat 3) wins, so A & C beat B & D, who are
  -- on 70 -- ONE skunked team: +1 skunk each for A and C (not +2), and a
  -- times_skunked each for B and D.
  v_before := v_after;
  perform pg_temp.l2_game(v_t4, v_a, array[v_a, v_b, v_c, v_d], 'ended', 'won', v_c, array[121, 70, 121, 70]);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_a) <> '1,0,1,0,0,0' or pg_temp.l2_delta(v_before, v_after, v_c) <> '1,0,1,0,0,0'
     or pg_temp.l2_delta(v_before, v_after, v_b) <> '0,1,0,0,1,0' or pg_temp.l2_delta(v_before, v_after, v_d) <> '0,1,0,0,1,0' then
    raise exception 'FAIL [T1] Teams: A %, B %, C %, D %; expected 1,0,1,0,0,0 / 0,1,0,0,1,0 / 1,0,1,0,0,0 / 0,1,0,0,1,0.',
      pg_temp.l2_delta(v_before, v_after, v_a), pg_temp.l2_delta(v_before, v_after, v_b),
      pg_temp.l2_delta(v_before, v_after, v_c), pg_temp.l2_delta(v_before, v_after, v_d);
  end if;
  v_checks := v_checks + 1;

  -- [O1] Solo, seats A B C D: C wins; A on 50 (double), B on 75 (skunk), D on
  -- 100 (neither). Only C wins -- A is not C's partner on a Solo table.
  v_before := v_after;
  perform pg_temp.l2_game(v_t4s, v_a, array[v_a, v_b, v_c, v_d], 'ended', 'won', v_c, array[50, 75, 121, 100]);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_c) <> '1,0,1,1,0,0' or pg_temp.l2_delta(v_before, v_after, v_a) <> '0,1,0,0,1,0'
     or pg_temp.l2_delta(v_before, v_after, v_b) <> '0,1,0,0,1,0' or pg_temp.l2_delta(v_before, v_after, v_d) <> '0,1,0,0,0,0' then
    raise exception 'FAIL [O1] Solo: A %, B %, C %, D %; expected 0,1,0,0,1,0 / 0,1,0,0,1,0 / 1,0,1,1,0,0 / 0,1,0,0,0,0.',
      pg_temp.l2_delta(v_before, v_after, v_a), pg_temp.l2_delta(v_before, v_after, v_b),
      pg_temp.l2_delta(v_before, v_after, v_c), pg_temp.l2_delta(v_before, v_after, v_d);
  end if;
  v_checks := v_checks + 1;

  -- [O2] 3 players, A B C: B wins; A on 80 and C on 85, both skunked: B +2.
  v_before := v_after;
  perform pg_temp.l2_game(v_t3, v_a, array[v_a, v_b, v_c], 'ended', 'won', v_b, array[80, 121, 85]);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_b) <> '1,0,2,0,0,0' or pg_temp.l2_delta(v_before, v_after, v_a) <> '0,1,0,0,1,0'
     or pg_temp.l2_delta(v_before, v_after, v_c) <> '0,1,0,0,1,0' or pg_temp.l2_delta(v_before, v_after, v_d) <> v_zero then
    raise exception 'FAIL [O2] 3 players: A %, B %, C %, D %; expected 0,1,0,0,1,0 / 1,0,2,0,0,0 / 0,1,0,0,1,0 / no change.',
      pg_temp.l2_delta(v_before, v_after, v_a), pg_temp.l2_delta(v_before, v_after, v_b),
      pg_temp.l2_delta(v_before, v_after, v_c), pg_temp.l2_delta(v_before, v_after, v_d);
  end if;
  v_checks := v_checks + 1;

  -- ==== X: not counted =========================================================
  -- [X1] Muggins: A beats B, B on 10 -- nothing for either.
  v_before := v_after;
  perform pg_temp.l2_game(v_tmug, v_a, array[v_a, v_b], 'ended', 'won', v_a, array[121, 10]);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_a) <> v_zero or pg_temp.l2_delta(v_before, v_after, v_b) <> v_zero then
    raise exception 'FAIL [X1] Muggins counted: A %, B %; expected no change.', pg_temp.l2_delta(v_before, v_after, v_a), pg_temp.l2_delta(v_before, v_after, v_b);
  end if;
  v_checks := v_checks + 1;

  -- [X2] An easy-computer table: A beats God, God on 10 -- nothing (not
  -- even beat_god: it isn't the hard level).
  v_before := v_after;
  perform pg_temp.l2_game(v_teasy, v_a, array[v_a, v_god], 'ended', 'won', v_a, array[121, 10]);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_a) <> v_zero then
    raise exception 'FAIL [X2] easy computer counted: A %; expected no change.', pg_temp.l2_delta(v_before, v_after, v_a);
  end if;
  v_checks := v_checks + 1;

  -- [X3] Ended player_left, admin and timeout -- each with a winner_id and
  -- saved scores set, to prove ended_reason alone decides: nothing.
  v_before := v_after;
  perform pg_temp.l2_game(v_t2, v_a, array[v_a, v_b], 'ended', 'player_left', v_a, array[121, 10]);
  perform pg_temp.l2_game(v_t2, v_a, array[v_a, v_b], 'ended', 'admin', v_a, array[121, 10]);
  perform pg_temp.l2_game(v_t2, v_a, array[v_a, v_b], 'ended', 'timeout', v_a, array[121, 10]);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_a) <> v_zero or pg_temp.l2_delta(v_before, v_after, v_b) <> v_zero then
    raise exception 'FAIL [X3] abandoned games counted: A %, B %; expected no change.', pg_temp.l2_delta(v_before, v_after, v_a), pg_temp.l2_delta(v_before, v_after, v_b);
  end if;
  v_checks := v_checks + 1;

  -- [X4] An unfinished game (still 'active'), winner and scores set: nothing.
  v_before := v_after;
  perform pg_temp.l2_game(v_tlive, v_a, array[v_a, v_b], 'active', null, v_a, array[121, 10]);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_a) <> v_zero or pg_temp.l2_delta(v_before, v_after, v_b) <> v_zero then
    raise exception 'FAIL [X4] unfinished game counted: A %, B %; expected no change.', pg_temp.l2_delta(v_before, v_after, v_a), pg_temp.l2_delta(v_before, v_after, v_b);
  end if;
  v_checks := v_checks + 1;

  -- ==== G: Beat God ============================================================
  -- [G1] A beats God at a hard table, God on 20 (a double skunk, if it
  -- counted): beat_god +1 and nothing else.
  v_before := v_after;
  perform pg_temp.l2_game(v_thard, v_a, array[v_a, v_god], 'ended', 'won', v_a, array[121, 20]);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_a) <> '0,0,0,0,0,1' then
    raise exception 'FAIL [G1] Beat God: A %; expected 0,0,0,0,0,1.', pg_temp.l2_delta(v_before, v_after, v_a);
  end if;
  v_checks := v_checks + 1;

  -- [G2] God beats A there: nothing for A, and God is not listed.
  v_before := v_after;
  perform pg_temp.l2_game(v_thard, v_a, array[v_a, v_god], 'ended', 'won', v_god, array[40, 121]);
  v_after := pg_temp.l2_snap(v_ids);
  if pg_temp.l2_delta(v_before, v_after, v_a) <> v_zero or pg_temp.l2_delta(v_before, v_after, v_god) <> 'absent' then
    raise exception 'FAIL [G2] God wins: A %, God %; expected no change and absent.', pg_temp.l2_delta(v_before, v_after, v_a), pg_temp.l2_delta(v_before, v_after, v_god);
  end if;
  v_checks := v_checks + 1;

  -- ==== C, N: who is listed =====================================================
  -- [C1] No computer account is a row.
  select count(*) into v_n
  from public.get_leaderboard() l
  join public.computer_accounts ca on ca.user_id = l.user_id;
  if v_n <> 0 then
    raise exception 'FAIL [C1] % computer account(s) listed.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [N1] D's nickname made blank (spaces only): D is no longer listed.
  update public.profiles set nickname = '   ' where id = v_d;
  select count(*) into v_n from public.get_leaderboard() l where l.user_id = v_d;
  if v_n <> 0 then
    raise exception 'FAIL [N1] a blank nickname is listed.';
  end if;
  v_checks := v_checks + 1;

  -- [N2] Every row has a counted game or a Beat God, and a non-blank,
  -- trimmed nickname.
  select count(*) into v_n
  from public.get_leaderboard() l
  where l.wins + l.losses + l.beat_god = 0
     or l.nickname is distinct from btrim(l.nickname)
     or l.nickname = '';
  if v_n <> 0 then
    raise exception 'FAIL [N2] % row(s) with no counted game and no Beat God, or an untrimmed / blank nickname.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- ==== Z, O: the tracking date and the order ===================================
  -- [Z1] skunk_tracking_since: min(game_results.created_at), the same on
  -- every row.
  select min(r.created_at) into v_min from public.game_results r;
  select count(*), count(*) filter (where l.skunk_tracking_since is distinct from v_min)
  into v_n, v_n2
  from public.get_leaderboard() l;
  if v_min is null or v_n = 0 or v_n2 <> 0 then
    raise exception 'FAIL [Z1] skunk_tracking_since: % of % row(s) differ from %.', v_n2, v_n, v_min;
  end if;
  v_checks := v_checks + 1;

  -- [O3] Each row is in order after the one before it: wins desc, then
  -- losses asc, then nickname (case-insensitive).
  with l as (
    select * from public.get_leaderboard() with ordinality
      as x(user_id, nickname, avatar_url, wins, losses, skunks, double_skunks, times_skunked, beat_god, since, ord)
  )
  select count(*) into v_n
  from l a
  join l b on b.ord = a.ord + 1
  where a.wins < b.wins
     or (a.wins = b.wins and a.losses > b.losses)
     or (a.wins = b.wins and a.losses = b.losses and lower(a.nickname) > lower(b.nickname));
  if v_n <> 0 then
    raise exception 'FAIL [O3] % row(s) out of order.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- ==== P: who may call it ======================================================
  -- [P1] anon: refused.
  execute 'set local role anon';
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  v_state := null;
  begin
    perform 1 from public.get_leaderboard();
  exception when others then
    v_state := sqlstate;
  end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [P1] anon calling get_leaderboard: expected 42501, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P2] A, signed in: allowed, and A is listed.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_state := null;
  begin
    select count(*) into v_n from public.get_leaderboard() l where l.user_id = v_a;
  exception when others then
    v_state := sqlstate || ' ' || sqlerrm;
  end;
  execute 'reset role';
  if v_state is not null or v_n <> 1 then
    raise exception 'FAIL [P2] signed-in call: error %, A listed % time(s); expected no error and 1.', coalesce(v_state, 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- ---- Verdict ----------------------------------------------------------------
  if v_checks <> 24 then
    raise exception 'FAIL: % checks ran, expected 24.', v_checks;
  end if;

  raise exception 'ALL % CHECKS PASSED (rolled back). A=% B=% C=% D=% God=%', v_checks, v_a, v_b, v_c, v_d, v_god;
end;
$$;
