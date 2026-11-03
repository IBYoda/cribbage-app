-- Phase 3: 4-PLAYER SOLO -- VERIFICATION.
--
-- Run in the Supabase Dashboard -> SQL Editor, with every phase3-e*.sql step,
-- the computer-c1 refactor and leaderboard-l1-game-results.sql applied (the
-- live state). The whole file is ONE DO block: run it as is.
--
-- WHY: 4-player Solo (team_mode 'solo') has never been played. The engine has
-- no Solo-specific code -- dealing (E2) and pegging (E3) never read
-- team_mode, and the only branch on it (award_points, E4, and the
-- game_results trigger, L1) is "a 4-player table in team_mode 'teams'" --
-- so a Solo table should play exactly like a 3-player table, one score per
-- player, with the 4-player deal, order and rotation the Teams suites
-- already prove. This suite plays a whole 4-player Solo game through the
-- REAL functions to show it, before Solo is offered in Start a Table.
--
-- It WRITES -- it creates five temporary accounts, tables, seats, games,
-- plays and counts -- and then deliberately raises an exception at the very
-- end, which rolls EVERY write back. A check that fails raises its own
-- exception at once, which rolls everything back the same way. It always
-- "fails": the message is the verdict. "ALL n CHECKS PASSED (rolled back)
-- ..." is a pass; anything starting "FAIL" or "SETUP" is not. Re-runnable,
-- because nothing it does survives. It creates no functions, tables or
-- other schema objects, and touches no existing account or table.
--
-- Same impersonation as the other suites: request.jwt.claims plus "set
-- local role authenticated" to act as a player, "reset role" to act as the
-- owner (to set known cards and scores, and to read).
--
-- PLAYERS: A, B, C, D and E are ALL temporary accounts created in auth.users
-- inside this transaction (no real account is used). E never sits at a
-- table (the non-member).
--
-- THE SOLO TABLE: created by A (the host) with max_players 4 and team_mode
-- 'solo'; A, B, C, D sit in that order, so seat 1 A, 2 B, 3 C, 4 D, and the
-- game's players are {A,B,C,D}. Game g is the first game; g2 the rematch.
-- Four more tables (2 and 3 players, 'solo' and 'teams') for the X checks.
--
-- KNOWN CARDS: the first deal and discard are real (random cards, checked by
-- their shape). Every later hand is SET BY THE OWNER -- the dealer, each
-- player's cards, the crib, the starter, the scores -- with every leftover
-- reset, exactly the state the engine itself leaves at that point. Then
-- each tap is made by the REAL player (the one whose turn it is), as that
-- player. Hand totals below were worked out by hand from the standard rules
-- (15s 2, pairs 2, runs 1 a card); a FAIL prints what the engine did.
--
-- WHAT IT CHECKS
--   C  creation: a Solo table is accepted; an unknown team_mode is refused.
--   S  start: a Solo game needs all four seated (as Teams).
--   D  the deal: 5 cards each, one discard each, the crib is the four
--      discards, the dealer's left leads.
--   P  pegging with four players: Go, a deadlock, 31, the last card -- the
--      points to the individual player.
--   K  counting order and the crib to the dealer.
--   N  the dealer moves one seat clockwise on the next hand.
--   W  a win at 121 mid-count and mid-pegging by a non-dealer; nothing
--      scores after it.
--   L  the leaderboard snapshot names ONE winner.
--   R  the rematch.
--   X  'solo' on a 2- or 3-player table behaves exactly like 'teams' there
--      (both are one score per player, as before).
--
-- Expected message:
--   ALL 21 CHECKS PASSED (rolled back). A=... B=... C=... D=...

do $$
declare
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid();
  v_e uuid := gen_random_uuid();
  v_players uuid[];
  v_codes text[];
  v_names jsonb;
  v_t uuid;
  v_g uuid;
  v_g2 uuid;
  v_new uuid;
  v_tx uuid;
  v_ty uuid;
  v_tz uuid;
  v_gx uuid;
  v_gy uuid;
  v_player uuid;
  v_who uuid;
  v_card text;
  v_discards text[];
  v_crib text[];
  v_deck text[];
  v_script text[];
  v_rec record;
  v_n int;
  v_n2 int;
  v_n3 int;
  v_hand int;
  v_i int;
  v_size int;
  v_msg text;
  v_err text;
  v_log text;
  v_state text;
  v_state2 text;
  v_scores text;
  v_scores2 text;
  v_order text;
  v_bad text;
  v_exp text;
  v_checks int := 0;
begin
  -- ---- Setup, as the owner ------------------------------------------------
  begin
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
      (v_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'solo-a-' || v_a || '@verification.invalid', now() - interval '5 minutes', now()),
      (v_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'solo-b-' || v_b || '@verification.invalid', now() - interval '4 minutes', now()),
      (v_c, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'solo-c-' || v_c || '@verification.invalid', now() - interval '3 minutes', now()),
      (v_d, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'solo-d-' || v_d || '@verification.invalid', now() - interval '2 minutes', now()),
      (v_e, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'solo-e-' || v_e || '@verification.invalid', now() - interval '1 minute', now());
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts A-E in auth.users: % (%).', sqlerrm, sqlstate;
  end;
  v_names := jsonb_build_object(v_a::text, 'A', v_b::text, 'B', v_c::text, 'C', v_d::text, 'D', v_e::text, 'E');
  v_players := array[v_a, v_b, v_c, v_d];

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

  -- ==== C: creation ===========================================================
  -- [C1] A, as a signed-in player, creates a 4-player Solo table (the insert
  -- Start a Table will make): accepted, and it reads back as 4 / solo / not
  -- Muggins.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin
    insert into public.tables (code, created_by, max_players, team_mode)
    values (v_codes[1], v_a, 4, 'solo')
    returning id into v_t;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  select max_players, team_mode, is_muggins into v_rec from public.tables where id = v_t;
  if v_msg is not null or v_t is null or v_rec.max_players <> 4 or v_rec.team_mode <> 'solo' or v_rec.is_muggins then
    raise exception 'FAIL [C1] creating a 4-player Solo table: refused %, row % / % / muggins %.',
      coalesce(v_msg, 'nothing'), v_rec.max_players, v_rec.team_mode, v_rec.is_muggins;
  end if;
  v_checks := v_checks + 1;

  -- [C2] Any other team_mode is refused by the table check (tables_team_mode_check).
  execute 'set local role authenticated';
  v_msg := null;
  begin
    insert into public.tables (code, created_by, max_players, team_mode)
    values (v_codes[2], v_a, 4, 'pairs');
  exception when others then
    v_msg := sqlstate;
  end;
  execute 'reset role';
  if v_msg is distinct from '23514' then
    raise exception 'FAIL [C2] team_mode ''pairs'': %, expected a check violation (23514).', coalesce(v_msg, 'accepted');
  end if;
  v_checks := v_checks + 1;

  -- ==== S: start with three seated, then four =================================
  -- A, B and C sit (seats 1, 2, 3).
  execute 'set local role authenticated';
  foreach v_player in array array[v_a, v_b, v_c] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    insert into public.table_members (table_id, user_id) values (v_t, v_player);
  end loop;
  -- [S1] The host starts with three seated: refused, exactly as on a Teams
  -- table (E2 [F1]).
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin perform public.start_game_with_deal(v_t); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'A game needs exactly 4 players at the table (currently 3).' then
    raise exception 'FAIL [S1] a Solo start with 3 seated: %, expected "exactly 4 players (currently 3)".', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- D sits (seat 4); the host starts: the first game cuts for deal.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_d::text, true);
  insert into public.table_members (table_id, user_id) values (v_t, v_d);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_g := public.start_game_with_deal(v_t);
  execute 'reset role';

  -- [S2] The game: cutting, the players in seat order {A,B,C,D}.
  select status, players into v_rec from public.games where id = v_g;
  if v_g is null or v_rec.status is distinct from 'cutting' or v_rec.players is distinct from v_players then
    raise exception 'FAIL [S2] a Solo start with 4 seated: game %, % / players %; expected cutting / {A,B,C,D}.',
      v_g, v_rec.status, v_rec.players;
  end if;
  v_checks := v_checks + 1;

  -- ==== D: the deal ===========================================================
  -- The cut, set to known cards so D (seat 4) deals; every player
  -- acknowledges, and the last acknowledgement deals (as in E3's setup).
  update public.games
  set deal_cut = jsonb_build_array(jsonb_build_array(
        jsonb_build_object('user_id', v_a, 'card', '9S'),
        jsonb_build_object('user_id', v_b, 'card', 'QS'),
        jsonb_build_object('user_id', v_c, 'card', '4S'),
        jsonb_build_object('user_id', v_d, 'card', 'AS'))),
      dealer_id = v_d, deal_cut_ack_by = '{}'
  where id = v_g;
  execute 'set local role authenticated';
  foreach v_player in array v_players loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    perform public.acknowledge_deal_cut(v_g);
  end loop;
  execute 'reset role';

  -- [D1] The deal: active, discard phase, dealer D, FIVE cards to each of
  -- the four, no crib yet, 32 in the deck, all 52 cards distinct.
  select status, phase, dealer_id into v_rec from public.games where id = v_g;
  select count(*) into v_n from public.game_hands where game_id = v_g and coalesce(array_length(cards, 1), 0) = 5;
  select count(*), count(distinct c) into v_n2, v_n3 from (
    select unnest(cards) as c from public.game_hands where game_id = v_g
    union all select unnest(cards) from public.game_decks where game_id = v_g
  ) all_cards;
  if v_rec.status is distinct from 'active' or v_rec.phase is distinct from 'discard' or v_rec.dealer_id is distinct from v_d
     or v_n <> 4 or exists (select 1 from public.game_cribs where game_id = v_g)
     or (select array_length(cards, 1) from public.game_decks where game_id = v_g) <> 32
     or v_n2 <> 52 or v_n3 <> 52 then
    raise exception 'FAIL [D1] the Solo deal: % / % / dealer % / % five-card hands / % cards, % distinct; expected active / discard / D / 4, no crib, 32 in the deck, 52 / 52.',
      v_rec.status, v_rec.phase, v_names ->> v_rec.dealer_id::text, v_n, v_n2, v_n3;
  end if;
  v_checks := v_checks + 1;

  -- [D2] Each player discards ONE card (their first, read as the owner),
  -- for real, A, B, C then D: the crib is exactly those four, everyone keeps
  -- four, the starter is cut (31 left in the deck), the play phase starts
  -- with D's left (A, seat 1: the lead wraps). If the starter is a jack,
  -- his heels is 2 to the DEALER alone; every other score stays 0.
  v_discards := '{}';
  foreach v_player in array v_players loop
    v_discards := v_discards || (select cards[1] from public.game_hands where game_id = v_g and user_id = v_player);
  end loop;
  execute 'set local role authenticated';
  for v_i in 1 .. 4 loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_players[v_i], 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_players[v_i]::text, true);
    perform public.discard_to_crib(v_g, array[v_discards[v_i]]);
  end loop;
  execute 'reset role';
  select phase, current_player, starter_card into v_rec from public.games where id = v_g;
  select cards into v_crib from public.game_cribs where game_id = v_g;
  select cards into v_deck from public.game_decks where game_id = v_g;
  select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score, ',' order by v_names ->> tm.user_id::text)
  into v_scores from public.table_members tm where tm.table_id = v_t;
  v_exp := 'A=0,B=0,C=0,D=' || case when v_rec.starter_card like 'J%' then '2' else '0' end;
  if v_rec.phase is distinct from 'play' or v_rec.current_player is distinct from v_a or v_rec.starter_card is null
     or array_length(v_crib, 1) <> 4 or not (v_crib @> v_discards and v_discards @> v_crib)
     or exists (select 1 from public.game_hands where game_id = v_g and array_length(cards, 1) <> 4)
     or coalesce(array_length(v_deck, 1), 0) <> 31
     or v_scores is distinct from v_exp then
    raise exception 'FAIL [D2] after the Solo discards: % / lead % / starter % / crib % (discards %) / deck % / scores % (expected %).',
      v_rec.phase, v_names ->> v_rec.current_player::text, v_rec.starter_card, v_crib, v_discards,
      coalesce(array_length(v_deck, 1), 0), v_scores, v_exp;
  end if;
  v_checks := v_checks + 1;

  -- ==== P: pegging with four players ==========================================
  -- [P1] E3's own 4-player script (phase3-e3-pegging-verification.sql, F1:
  -- dealer D, 16 cards; the lead wraps to A; Go, a deadlock, a 31, a player
  -- out early, a fifteen, the last card), played by whoever's turn it is.
  -- On a Teams table each award goes to the team (A with C, B with D); on
  -- this Solo table every point stays with the player who scored it:
  -- A 2 (thirty-one), B 0, C 2 (fifteen), D 5 -- E3's individual result.
  delete from public.game_plays where game_id = v_g;
  update public.games
  set status = 'active', ended_reason = null, winner_id = null, win_claim_by = null,
      phase = 'play', dealer_id = v_d, current_player = v_a,
      play_count = 0, play_segment = 0, count_step = 0,
      revealed_by = '{}', crib_revealed = false, ready_by = '{}'
  where id = v_g;
  delete from public.game_hands where game_id = v_g;
  insert into public.game_hands (game_id, user_id, cards) values
    (v_g, v_a, array['AS', '5D', 'TC', 'KS']),
    (v_g, v_b, array['6C', 'JS', 'JD', '7S']),
    (v_g, v_c, array['9H', '9D', '5C', 'QC']),
    (v_g, v_d, array['KD', 'AC', '7C', '2S']);
  update public.table_members
  set score = 0, last_points = null, last_reason = null, last_awarded_at = null
  where table_id = v_t;
  v_script := array['TC', '6C', '9H', '2S', 'AS', 'AC', 'KS', '7S', '9D', '5D', 'JD', 'QC', '7C', 'JS', '5C', 'KD'];
  v_err := '';
  foreach v_card in array v_script loop
    select current_player into v_who from public.games where id = v_g;
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', json_build_object('sub', v_who, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_who::text, true);
    begin
      perform public.play_card(v_g, v_card);
    exception when others then
      v_err := v_err || case when v_err = '' then '' else '|' end || v_card || '@' || coalesce(v_names ->> v_who::text, '-') || ':' || sqlerrm;
    end;
    execute 'reset role';
  end loop;
  select coalesce(string_agg(gp.seq || ':' || gp.segment || ':' || (v_names ->> gp.user_id::text) || ':' || gp.kind || ':' || coalesce(gp.card, '') || ':' || gp.count_after, '|' order by gp.seq), '')
  into v_log from public.game_plays gp where gp.game_id = v_g;
  select g.phase || '/' || coalesce(v_names ->> g.current_player::text, '-') || '/' || g.play_count || '/' || g.play_segment || '/' || g.count_step || '/' || g.status || '/' || coalesce(v_names ->> g.winner_id::text, '-')
  into v_state from public.games g where g.id = v_g;
  select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score || '/' || coalesce(tm.last_points::text, '') || '/' || coalesce(tm.last_reason, ''), ',' order by v_names ->> tm.user_id::text)
  into v_scores from public.table_members tm where tm.table_id = v_t;
  if v_err <> ''
     or v_log is distinct from '1:0:A:play:TC:10|2:0:B:play:6C:16|3:0:C:play:9H:25|4:0:D:play:2S:27|5:0:A:play:AS:28|6:0:B:go::28|7:0:C:go::28|8:0:D:play:AC:29|9:0:A:go::29|10:0:B:go::29|11:0:C:go::29|12:1:A:play:KS:10|13:1:B:play:7S:17|14:1:C:play:9D:26|15:1:D:go::26|16:1:A:play:5D:31|17:2:B:play:JD:10|18:2:C:play:QC:20|19:2:D:play:7C:27|20:2:B:go::27|21:2:C:go::27|22:3:B:play:JS:10|23:3:C:play:5C:15|24:3:D:play:KD:25'
     or v_state is distinct from 'counting/A/0/4/0/active/-'
     or v_scores is distinct from 'A=2/2/thirty-one,B=0//,C=2/2/fifteen,D=5/1/last card' then
    raise exception 'FAIL [P1] 4-player Solo pegging: refused % / log % / state % / scores %; expected no refusals, E3 F1''s log, counting/A/0/4/0/active/-, A=2/2/thirty-one,B=0//,C=2/2/fifteen,D=5/1/last card.',
      coalesce(nullif(v_err, ''), 'nothing'), v_log, v_state, v_scores;
  end if;
  v_checks := v_checks + 1;

  -- ==== K: counting order, and the crib to the dealer =========================
  -- Dealer B (seat 2). Known cards, starter 2S, worked out by hand:
  --   C  3H 4C 9D KC   2+3+K, 2+4+9 = 4; run 2-3-4 = 3          -> 7
  --   D  6H 7C QD AS   6+7+2 = 2                                -> 2
  --   A  5H 5D TC KD   four 5+10s = 8; pair of 5s = 2           -> 10
  --   B  8H 9S 3C 4D   8+4+3, 9+4+2 = 4; run 2-3-4 = 3          -> 7
  --   crib 6D 7D 8C QS 7+8, 6+7+2 = 4; run 6-7-8 = 3            -> 7 (B's)
  -- No jacks, no flushes. Scores from 0: A 10, B 14, C 7, D 2.
  delete from public.game_plays where game_id = v_g;
  delete from public.game_hands where game_id = v_g;
  delete from public.game_cribs where game_id = v_g;
  update public.games
  set status = 'active', ended_reason = null, winner_id = null, win_claim_by = null, ready_by = '{}',
      phase = 'counting', dealer_id = v_b, current_player = v_c, play_count = 0, play_segment = 0,
      count_step = 0, revealed_by = '{}', crib_revealed = false, discarded_by = v_players,
      starter_card = '2S'
  where id = v_g;
  insert into public.game_hands (game_id, user_id, cards) values
    (v_g, v_c, array['3H', '4C', '9D', 'KC']),
    (v_g, v_d, array['6H', '7C', 'QD', 'AS']),
    (v_g, v_a, array['5H', '5D', 'TC', 'KD']),
    (v_g, v_b, array['8H', '9S', '3C', '4D']);
  insert into public.game_cribs (game_id, cards) values (v_g, array['6D', '7D', '8C', 'QS']);
  update public.table_members
  set score = 0, last_points = null, last_reason = null, last_awarded_at = null
  where table_id = v_t;

  -- [K1] Each hand is counted by the player it belongs to, in order from
  -- the dealer's left: C (step 0), D (1), A (2), then the dealer B (3); the
  -- crib's step (4) is then B's too. Each count's points go to that player
  -- alone.
  v_order := '';
  v_err := '';
  for v_i in 0 .. 3 loop
    select current_player, count_step into v_rec from public.games where id = v_g;
    v_order := v_order || coalesce(v_names ->> v_rec.current_player::text, '-') || v_rec.count_step || ' ';
    v_who := v_rec.current_player;
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', json_build_object('sub', v_who, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_who::text, true);
    begin
      perform public.confirm_count(v_g, v_i);
    exception when others then
      v_err := v_err || case when v_err = '' then '' else '|' end || 'step ' || v_i || '@' || coalesce(v_names ->> v_who::text, '-') || ':' || sqlerrm;
    end;
    execute 'reset role';
  end loop;
  select current_player, count_step into v_rec from public.games where id = v_g;
  v_order := v_order || coalesce(v_names ->> v_rec.current_player::text, '-') || v_rec.count_step;
  select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score || '/' || coalesce(tm.last_points::text, ''), ',' order by v_names ->> tm.user_id::text)
  into v_scores from public.table_members tm where tm.table_id = v_t;
  if v_err <> '' or v_order is distinct from 'C0 D1 A2 B3 B4'
     or v_scores is distinct from 'A=10/10,B=7/7,C=7/7,D=2/2' then
    raise exception 'FAIL [K1] the Solo counting order: refused % / order % / scores %; expected nothing / C0 D1 A2 B3 B4 / A=10/10,B=7/7,C=7/7,D=2/2.',
      coalesce(nullif(v_err, ''), 'nothing'), v_order, v_scores;
  end if;
  v_checks := v_checks + 1;

  -- [K2] The crib is the DEALER's: C may not show it; B shows it and
  -- confirms its count (step 4) -- 7 more to B (14) and nobody else -- and
  -- the hand is counted ('done').
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  v_msg := null;
  begin perform public.show_crib(v_g); exception when others then v_msg := sqlerrm; end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_err := '';
  begin
    perform public.show_crib(v_g);
    perform public.confirm_count(v_g, 4);
  exception when others then
    v_err := sqlerrm;
  end;
  execute 'reset role';
  select phase, status into v_rec from public.games where id = v_g;
  select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score || '/' || coalesce(tm.last_points::text, ''), ',' order by v_names ->> tm.user_id::text)
  into v_scores from public.table_members tm where tm.table_id = v_t;
  if v_msg is distinct from 'Only the dealer can show the crib.' or v_err <> ''
     or v_rec.phase is distinct from 'done' or v_rec.status is distinct from 'active'
     or v_scores is distinct from 'A=10/10,B=14/7,C=7/7,D=2/2' then
    raise exception 'FAIL [K2] the crib to the dealer: C showing it %, B %, then % / % / scores %; expected "Only the dealer can show the crib.", nothing, done / active / A=10/10,B=14/7,C=7/7,D=2/2.',
      coalesce(v_msg, 'no error'), coalesce(nullif(v_err, ''), 'nothing'), v_rec.phase, v_rec.status, v_scores;
  end if;
  v_checks := v_checks + 1;

  -- ==== N: the next hand ======================================================
  select hand_no into v_hand from public.games where id = v_g;
  execute 'set local role authenticated';
  foreach v_player in array array[v_a, v_b, v_c] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    perform public.next_hand(v_g, v_hand);
  end loop;
  execute 'reset role';

  -- [N1] Three Next Hand taps of four: nothing dealt, B still deals.
  select dealer_id, hand_no, phase into v_rec from public.games where id = v_g;
  if v_rec.dealer_id is distinct from v_b or v_rec.hand_no <> v_hand or v_rec.phase <> 'done' then
    raise exception 'FAIL [N1] after three of four Next Hand taps: dealer %, hand % (was %), phase %.',
      v_names ->> v_rec.dealer_id::text, v_rec.hand_no, v_hand, v_rec.phase;
  end if;
  v_checks := v_checks + 1;

  -- [N2] The fourth tap deals: the deal moves ONE seat clockwise, B (2) to
  -- C (3); four 5-card hands, no crib yet, the discard phase.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_d::text, true);
  perform public.next_hand(v_g, v_hand);
  execute 'reset role';
  select dealer_id, hand_no, phase, ready_by into v_rec from public.games where id = v_g;
  select count(*) into v_n from public.game_hands where game_id = v_g and array_length(cards, 1) = 5;
  select count(*) into v_n2 from public.game_cribs where game_id = v_g;
  if v_rec.dealer_id is distinct from v_c or v_rec.hand_no <> v_hand + 1 or v_rec.phase <> 'discard'
     or v_rec.ready_by <> '{}' or v_n <> 4 or v_n2 <> 0 then
    raise exception 'FAIL [N2] the next Solo hand: dealer %, hand %, phase %, ready %, % full hands, % crib rows; expected C, %, discard, {}, 4, 0.',
      v_names ->> v_rec.dealer_id::text, v_rec.hand_no, v_rec.phase, v_rec.ready_by, v_n, v_n2, v_hand + 1;
  end if;
  v_checks := v_checks + 1;

  -- ==== W: a win mid-count ====================================================
  -- The K hand again (dealer B, starter 2S), with A (a non-dealer, the third
  -- to count) at 113, B 100, C 50, D 90.
  delete from public.game_plays where game_id = v_g;
  delete from public.game_hands where game_id = v_g;
  delete from public.game_cribs where game_id = v_g;
  update public.games
  set status = 'active', ended_reason = null, winner_id = null, win_claim_by = null, ready_by = '{}',
      phase = 'counting', dealer_id = v_b, current_player = v_c, play_count = 0, play_segment = 0,
      count_step = 0, revealed_by = '{}', crib_revealed = false, discarded_by = v_players,
      starter_card = '2S'
  where id = v_g;
  insert into public.game_hands (game_id, user_id, cards) values
    (v_g, v_c, array['3H', '4C', '9D', 'KC']),
    (v_g, v_d, array['6H', '7C', 'QD', 'AS']),
    (v_g, v_a, array['5H', '5D', 'TC', 'KD']),
    (v_g, v_b, array['8H', '9S', '3C', '4D']);
  insert into public.game_cribs (game_id, cards) values (v_g, array['6D', '7D', '8C', 'QS']);
  update public.table_members
  set score = case user_id when v_a then 113 when v_b then 100 when v_c then 50 else 90 end,
      last_points = null, last_reason = null, last_awarded_at = null
  where table_id = v_t;

  -- [W1] C counts 7 (57), D 2 (92), then A's 10 takes A from 113 to 121
  -- (capped): the game is won by A at once, mid-count; B (the dealer) never
  -- counts. The other three end at three different scores.
  v_err := '';
  for v_i in 0 .. 2 loop
    select current_player into v_who from public.games where id = v_g;
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', json_build_object('sub', v_who, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_who::text, true);
    begin
      perform public.confirm_count(v_g, v_i);
    exception when others then
      v_err := v_err || case when v_err = '' then '' else '|' end || 'step ' || v_i || '@' || coalesce(v_names ->> v_who::text, '-') || ':' || sqlerrm;
    end;
    execute 'reset role';
  end loop;
  select g.status || '/' || coalesce(g.ended_reason, '-') || '/' || coalesce(v_names ->> g.winner_id::text, '-')
  into v_state from public.games g where g.id = v_g;
  select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score || '/' || coalesce(tm.last_points::text, ''), ',' order by v_names ->> tm.user_id::text)
  into v_scores from public.table_members tm where tm.table_id = v_t;
  if v_err <> '' or v_state is distinct from 'ended/won/A'
     or v_scores is distinct from 'A=121/10,B=100/,C=57/7,D=92/2' then
    raise exception 'FAIL [W1] a mid-count Solo win: refused % / % / scores %; expected nothing / ended/won/A / A=121/10,B=100/,C=57/7,D=92/2.',
      coalesce(nullif(v_err, ''), 'nothing'), v_state, v_scores;
  end if;
  v_checks := v_checks + 1;

  -- [W2] Nothing counts after the win: B's count (step 3) is refused, and
  -- the game and every score stay as they were.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.confirm_count(v_g, 3); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  select g.status || '/' || coalesce(g.ended_reason, '-') || '/' || coalesce(v_names ->> g.winner_id::text, '-')
  into v_state2 from public.games g where g.id = v_g;
  select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score || '/' || coalesce(tm.last_points::text, ''), ',' order by v_names ->> tm.user_id::text)
  into v_scores2 from public.table_members tm where tm.table_id = v_t;
  if v_msg is null or v_state2 is distinct from v_state or v_scores2 is distinct from v_scores then
    raise exception 'FAIL [W2] a count after the win: refused %, then % / %.', coalesce(v_msg, 'nothing'), v_state2, v_scores2;
  end if;
  v_checks := v_checks + 1;

  -- [L1] The leaderboard snapshot (game_results, written by the
  -- games_snapshot_result_on_win trigger): one row per player at their
  -- final score, and ONE winner -- A. (On a Teams table A's partner C would
  -- be a winner too.)
  select string_agg((v_names ->> gr.user_id::text) || '=' || gr.score || '/' || case when gr.won then 't' else 'f' end || '/' || gr.position,
                    ',' order by v_names ->> gr.user_id::text)
  into v_scores from public.game_results gr where gr.game_id = v_g;
  if v_scores is distinct from 'A=121/t/1,B=100/f/2,C=57/f/3,D=92/f/4' then
    raise exception 'FAIL [L1] the leaderboard snapshot of a Solo win: %; expected A=121/t/1,B=100/f/2,C=57/f/3,D=92/f/4.', coalesce(v_scores, 'no rows');
  end if;
  v_checks := v_checks + 1;

  -- ==== R: the rematch ========================================================
  -- [R1] A, B and C tap New Game: each is recorded and waits; nothing starts,
  -- and the scores stay where the match ended.
  execute 'set local role authenticated';
  v_bad := '';
  foreach v_player in array array[v_a, v_b, v_c] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    v_new := public.start_game_with_deal(v_t);
    v_bad := v_bad || coalesce(v_new::text, 'waiting') || ' ';
  end loop;
  execute 'reset role';
  select ready_by into v_rec from public.games where id = v_g;
  select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score, ',' order by v_names ->> tm.user_id::text)
  into v_scores from public.table_members tm where tm.table_id = v_t;
  if v_bad is distinct from 'waiting waiting waiting '
     or not (v_rec.ready_by @> array[v_a, v_b, v_c] and v_rec.ready_by <@ array[v_a, v_b, v_c])
     or exists (select 1 from public.games where table_id = v_t and status in ('cutting', 'active'))
     or v_scores is distinct from 'A=121,B=100,C=57,D=92' then
    raise exception 'FAIL [R1] three of four New Game taps: % / ready % / scores %.', v_bad, v_rec.ready_by, v_scores;
  end if;
  v_checks := v_checks + 1;

  -- [R2] D's tap starts it: B deals -- the next seat clockwise from the
  -- winner A -- with no cut; the same four players; four 5-card hands; every
  -- score back to 0.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_d::text, true);
  v_g2 := public.start_game_with_deal(v_t);
  execute 'reset role';
  select status, dealer_id, players, phase into v_rec from public.games where id = v_g2;
  select count(*) into v_n from public.game_hands where game_id = v_g2 and array_length(cards, 1) = 5;
  select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score || '/' || coalesce(tm.last_points::text, ''), ',' order by v_names ->> tm.user_id::text)
  into v_scores from public.table_members tm where tm.table_id = v_t;
  if v_g2 is null or v_g2 = v_g or v_rec.status is distinct from 'active' or v_rec.phase is distinct from 'discard'
     or v_rec.dealer_id is distinct from v_b or v_rec.players is distinct from v_players or v_n <> 4
     or v_scores is distinct from 'A=0/,B=0/,C=0/,D=0/' then
    raise exception 'FAIL [R2] the Solo rematch: game %, % / % / dealer % / players % / % full hands / scores %; expected a new game, active / discard / B / {A,B,C,D} / 4 / all 0.',
      v_g2, v_rec.status, v_rec.phase, v_names ->> v_rec.dealer_id::text, v_rec.players, v_n, v_scores;
  end if;
  v_checks := v_checks + 1;

  -- ==== W (continued): a win mid-pegging, on the rematch ======================
  -- Dealer D, so A (seat 1) leads. E3's F2 hands. B (a non-dealer) at 119,
  -- A 40, C 80, D 60 -- D sits opposite B, so on a Teams table D would be
  -- B's partner and move with B.
  delete from public.game_plays where game_id = v_g2;
  delete from public.game_hands where game_id = v_g2;
  delete from public.game_cribs where game_id = v_g2;
  update public.games
  set status = 'active', ended_reason = null, winner_id = null, win_claim_by = null, ready_by = '{}',
      phase = 'play', dealer_id = v_d, current_player = v_a, play_count = 0, play_segment = 0,
      count_step = 0, revealed_by = '{}', crib_revealed = false, discarded_by = v_players,
      starter_card = 'KD'
  where id = v_g2;
  insert into public.game_hands (game_id, user_id, cards) values
    (v_g2, v_a, array['5H', '9C', 'QS', 'KH']),
    (v_g2, v_b, array['5S', '3D', '8C', '2C']),
    (v_g2, v_c, array['4H', '6C', '7S', '8S']),
    (v_g2, v_d, array['AH', '2H', '3H', '4D']);
  insert into public.game_cribs (game_id, cards) values (v_g2, array['TD', 'JC', 'QH', 'TS']);
  update public.table_members
  set score = case user_id when v_a then 40 when v_b then 119 when v_c then 80 else 60 end,
      last_points = null, last_reason = null, last_awarded_at = null
  where table_id = v_t;

  -- [W3] A leads 5H; B pairs it with 5S: 2 for B, 121, and the match is won
  -- by B at once, mid-pegging; D does NOT move (no team); the other three
  -- at three different scores.
  v_err := '';
  foreach v_card in array array['5H', '5S'] loop
    select current_player into v_who from public.games where id = v_g2;
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', json_build_object('sub', v_who, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_who::text, true);
    begin
      perform public.play_card(v_g2, v_card);
    exception when others then
      v_err := v_err || case when v_err = '' then '' else '|' end || v_card || '@' || coalesce(v_names ->> v_who::text, '-') || ':' || sqlerrm;
    end;
    execute 'reset role';
  end loop;
  select g.status || '/' || coalesce(g.ended_reason, '-') || '/' || coalesce(v_names ->> g.winner_id::text, '-')
  into v_state from public.games g where g.id = v_g2;
  select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score || '/' || coalesce(tm.last_points::text, '') || '/' || coalesce(tm.last_reason, ''), ',' order by v_names ->> tm.user_id::text)
  into v_scores from public.table_members tm where tm.table_id = v_t;
  if v_err <> '' or v_state is distinct from 'ended/won/B'
     or v_scores is distinct from 'A=40//,B=121/2/pair,C=80//,D=60//' then
    raise exception 'FAIL [W3] a mid-pegging Solo win: refused % / % / scores %; expected nothing / ended/won/B / A=40//,B=121/2/pair,C=80//,D=60//.',
      coalesce(nullif(v_err, ''), 'nothing'), v_state, v_scores;
  end if;
  v_checks := v_checks + 1;

  -- [W4] Nothing scores after it: C's play is refused, word for word as in
  -- E3 [F2], and every score stays.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  v_msg := null;
  begin perform public.play_card(v_g2, '4H'); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score || '/' || coalesce(tm.last_points::text, '') || '/' || coalesce(tm.last_reason, ''), ',' order by v_names ->> tm.user_id::text)
  into v_scores2 from public.table_members tm where tm.table_id = v_t;
  if v_msg is distinct from 'This game is no longer active.' or v_scores2 is distinct from v_scores then
    raise exception 'FAIL [W4] a play after the win: %, scores % then %.', coalesce(v_msg, 'no error'), v_scores, v_scores2;
  end if;
  v_checks := v_checks + 1;

  -- [L2] The snapshot of the rematch: ONE winner, B; D (B's would-be
  -- partner on a Teams table) is not a winner.
  select string_agg((v_names ->> gr.user_id::text) || '=' || gr.score || '/' || case when gr.won then 't' else 'f' end || '/' || gr.position,
                    ',' order by v_names ->> gr.user_id::text)
  into v_scores from public.game_results gr where gr.game_id = v_g2;
  if v_scores is distinct from 'A=40/f/1,B=121/t/2,C=80/f/3,D=60/f/4' then
    raise exception 'FAIL [L2] the leaderboard snapshot of a pegging Solo win: %; expected A=40/f/1,B=121/t/2,C=80/f/3,D=60/f/4.', coalesce(v_scores, 'no rows');
  end if;
  v_checks := v_checks + 1;

  -- ==== X: 'solo' on 2- and 3-player tables, as before ========================
  -- [X1] 2 players and [X2] 3 players: twin tables, one 'solo' and one
  -- 'teams' (the default every live 2- and 3-player table has), each with a
  -- game (the owner marks it active). The same awards on both, as the owner:
  -- seat 1 scores 5, seat 2 scores 3, then seat 1 is put at 118 and scores
  -- 4 -- capped at 121, and the game won by seat 1. Both twins must end
  -- exactly alike, one score per player.
  for v_size in 2 .. 3 loop
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_a::text, true);
    insert into public.tables (code, created_by, max_players, team_mode)
    values (v_codes[1 + v_size], v_a, v_size, 'solo') returning id into v_tx;
    insert into public.tables (code, created_by, max_players, team_mode)
    values (v_codes[3 + v_size], v_a, v_size, 'teams') returning id into v_ty;
    foreach v_player in array v_players[1:v_size] loop
      perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', v_player::text, true);
      insert into public.table_members (table_id, user_id) values (v_tx, v_player);
      insert into public.table_members (table_id, user_id) values (v_ty, v_player);
    end loop;
    perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_a::text, true);
    v_gx := public.start_game_with_deal(v_tx);
    v_gy := public.start_game_with_deal(v_ty);
    execute 'reset role';
    update public.games set status = 'active', ended_reason = null, winner_id = null where id in (v_gx, v_gy);
    update public.table_members set score = 0, last_points = null, last_reason = null, last_awarded_at = null
    where table_id in (v_tx, v_ty);

    foreach v_tz in array array[v_tx, v_ty] loop
      perform public.award_points(v_tz, v_a, 5, 'five');
      perform public.award_points(v_tz, v_b, 3, 'three');
      update public.table_members set score = 118 where table_id = v_tz and user_id = v_a;
      perform public.award_points(v_tz, v_a, 4, 'four');
    end loop;
    select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score || '/' || coalesce(tm.last_points::text, '') || '/' || coalesce(tm.last_reason, ''), ',' order by v_names ->> tm.user_id::text)
    into v_scores from public.table_members tm where tm.table_id = v_tx;
    select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score || '/' || coalesce(tm.last_points::text, '') || '/' || coalesce(tm.last_reason, ''), ',' order by v_names ->> tm.user_id::text)
    into v_scores2 from public.table_members tm where tm.table_id = v_ty;
    select g.status || '/' || coalesce(g.ended_reason, '-') || '/' || coalesce(v_names ->> g.winner_id::text, '-')
    into v_state from public.games g where g.id = v_gx;
    select g.status || '/' || coalesce(g.ended_reason, '-') || '/' || coalesce(v_names ->> g.winner_id::text, '-')
    into v_state2 from public.games g where g.id = v_gy;
    v_exp := case v_size when 2 then 'A=121/4/four,B=3/3/three' else 'A=121/4/four,B=3/3/three,C=0//' end;
    if v_scores is distinct from v_scores2 or v_state is distinct from v_state2
       or v_scores is distinct from v_exp or v_state is distinct from 'ended/won/A' then
      raise exception 'FAIL [X%] % players, solo vs teams: solo % / % -- teams % / %; expected both % / ended/won/A.',
        v_size - 1, v_size, v_scores, v_state, v_scores2, v_state2, v_exp;
    end if;
    v_checks := v_checks + 1;
  end loop;

  raise exception 'ALL % CHECKS PASSED (rolled back). A=% B=% C=% D=%.', v_checks, v_a, v_b, v_c, v_d;
end $$;
