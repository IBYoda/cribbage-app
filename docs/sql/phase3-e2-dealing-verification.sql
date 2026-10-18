-- Phase 3, step E2: VERIFICATION.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER
-- docs/sql/phase3-e2-dealing.sql. The whole file is ONE DO block: run it as
-- is.
--
-- It WRITES -- it creates tables, seats players, starts games, cuts, deals,
-- discards and deals a second hand, as real players -- and then deliberately
-- raises an exception at the very end, which rolls every write back. It
-- always "fails": the message is the verdict. "ALL n CHECKS PASSED (rolled
-- back) ..." is a pass; anything starting "FAIL" or "SETUP" is not.
-- Re-runnable, because nothing it does survives. (Same pattern as
-- phase3-e1-seating-verification.sql.)
--
-- Same impersonation as before: request.jwt.claims plus "set local role
-- authenticated" (or anon) to act as a client, "reset role" to act as the
-- owner between steps.
--
-- PLAYERS: A and B are the two OLDEST accounts that are NOT admins. C, D
-- and E are TEMPORARY accounts created in auth.users inside this
-- transaction (rolled back with everything else), as in E1. E never sits at
-- the 3- or 4-player table: it is the "non-member" for the privacy checks.
-- Every table, seat and game below is created here.
--
-- GAMES are only ever created by start_game_with_deal (none directly), so
-- there is no created_at to stage: each table has one game until a rematch,
-- and a rematch only reads the game before it.
--
-- RANDOM CARDS: the deal and a cut draw are random. Every check here holds
-- for ANY shuffle (counts, distinct cards, who holds what). Where the
-- outcome itself depends on the cards -- who deals, a tie -- the round is
-- set by the owner to known cards (as draw_cut_card would leave it) and then
-- acknowledged by the real players, so the tie and the decisive round are
-- each tested deterministically.
--
-- THE LOCK (start_game_with_deal under the table lock): one session can't
-- race itself, so the lock is checked in the function's source -- the
-- "for no key update" on the tables row comes before the first guard -- and
-- its effect is the E1 guarantee: joins and seat moves take the same lock.
--
-- WHAT IT CHECKS
--   S  catalog: the four redefined bodies are exactly the E2 ones; seventeen
--      other bodies unchanged (md5); 14 client functions, authenticated not
--      anon; only those 14 client-callable; the lock in the source; the hand,
--      crib and deck read policies unchanged.
--   R  2-player regression, the whole old flow: refusals and messages, the
--      cut, the deal (6 + 6, 40 in the deck), discards (2 each, the old
--      refusals), the crib of 4, the starter, the non-dealer leads; the New
--      Game gate after a win and the loser dealing with no cut.
--   T  3 players: host-only start, the size rule, seat order after a seat
--      move; the cut (draws, a forced tie, a forced decisive round); the
--      deal (5 + 5 + 5, 1 to the crib, 36 in the deck); 1-card discards and
--      their refusals; the crib of 4; the player on the dealer's left leads;
--      the next hand rotates clockwise; the rematch dealer.
--   P  privacy, 3 and 4 players: a player and a non-member read only what
--      they could before -- their own hand, never the crib early, never the
--      deck.
--   F  4 players (Teams): the size rule, seat order after a leave and a
--      rejoin, host-only start, the deal (5 x 4, no crib card, 32 in the
--      deck), 1-card discards, the crib is exactly the 4 discards, the lead
--      wraps from the last seat to the first.
--   M  the size rule on an over-full 2-player table.
--
-- Expected message:
--   ALL 46 CHECKS PASSED (rolled back). A=... B=...

do $$
declare
  v_a uuid;
  v_b uuid;
  v_c uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid();
  v_e uuid := gen_random_uuid();
  v_codes text[];
  v_t2 uuid;
  v_t2x uuid;
  v_t3 uuid;
  v_t3o uuid;
  v_t4 uuid;
  v_g uuid;
  v_g2 uuid;
  v_ret uuid;
  v_rec record;
  v_n int;
  v_n2 int;
  v_n3 int;
  v_state text;
  v_msg text;
  v_fn text;
  v_bad text;
  v_md5 text;
  v_expected jsonb;
  v_hand text[];
  v_cards text[];
  v_crib text[];
  v_deck text[];
  v_discards text[] := '{}';
  v_player uuid;
  v_players uuid[];
  v_client text[] := array[
    'public.start_game_with_deal(uuid)', 'public.draw_cut_card(uuid)', 'public.acknowledge_deal_cut(uuid)',
    'public.discard_to_crib(uuid, text[])', 'public.play_card(uuid, text)', 'public.leave_table(uuid)',
    'public.show_hand(uuid)', 'public.show_crib(uuid)', 'public.confirm_count(uuid, int)',
    'public.next_hand(uuid, int)', 'public.claim_win(uuid)', 'public.clear_win_claim(uuid)',
    'public.confirm_win(uuid)', 'public.set_seat(uuid, uuid, int)'
  ];
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

  begin
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
      (v_c, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e2-c-' || v_c || '@verification.invalid', now(), now()),
      (v_d, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e2-d-' || v_d || '@verification.invalid', now(), now()),
      (v_e, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e2-e-' || v_e || '@verification.invalid', now(), now());
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts C, D and E in auth.users: % (%).', sqlerrm, sqlstate;
  end;

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

  -- ==== S: catalog, as the owner ==============================================
  -- [S1] The four redefined functions are exactly the E2 versions (md5 of the
  -- body between the dollar quotes, line endings normalised).
  v_expected := jsonb_build_object(
    'public.start_game_with_deal(uuid)',     '3feaa7508cf434b4a3f8d78a8ad9896a',
    'public.deal_cards_for_game(uuid)',      '1da0902352ffe6729ec663e6265374a2',
    'public.discard_to_crib(uuid, text[])',  '69ab74268ce6c799c40777436a8cfafd',
    'public.next_hand(uuid, int)',           '9007931d5f4cc4ac127c9c2dfd7c1178'
  );
  v_bad := null;
  for v_rec in select key, value #>> '{}' as md5 from jsonb_each(v_expected) loop
    select md5(replace(p.prosrc, E'\r', '')) into v_md5
    from pg_proc p where p.oid = to_regprocedure(v_rec.key);
    if v_md5 is distinct from v_rec.md5 then
      v_bad := coalesce(v_bad || '; ', '') || v_rec.key || ' has ' || coalesce(v_md5, '(missing)');
    end if;
  end loop;
  if v_bad is not null then
    raise exception 'FAIL [S1] the redefined functions are not the phase3-e2-dealing.sql versions: %.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [S2] Every function out of scope is unchanged: its newest docs/sql body.
  v_expected := jsonb_build_object(
    'public.draw_cut_card(uuid)',                  '2ca8d114de4e45861e21c23b2e4b65f8',  -- phase2-slice-5-cut-before-deal.sql
    'public.acknowledge_deal_cut(uuid)',           '5b06eec819234121db1bf802ea462c02',  -- phase2-slice-5-cut-before-deal.sql
    'public.play_card(uuid, text)',                'a333d53a4a6ac971fbb4728d84487a14',  -- phase2-batch2a-counting.sql
    'public.has_legal_play(uuid, uuid, int)',      'a269d55520a89d4a8af9aff2a112aa4e',  -- phase2-slice-7-pegging-turns.sql
    'public.show_hand(uuid)',                      'ae5bd9553c21de7a395504f9d39977b6',  -- phase2-batch2a-counting.sql
    'public.show_crib(uuid)',                      'cab1efd1eb3cc00738f3ccef06c72cfe',  -- phase2-batch2a-counting.sql
    'public.confirm_count(uuid, int)',             'cca65adc984ebd0fce2a7e8838379809',  -- phase2-batch2a-counting.sql
    'public.award_points(uuid, uuid, int, text)',  '7234674b5e9be6beac60541661cd964a',  -- muggins-mode.sql
    'public.claim_win(uuid)',                      'd95da0d7dc9477a460955749a36164bb',  -- muggins-mode.sql
    'public.clear_win_claim(uuid)',                '0c4500259a1bb0fed638dce79944fab5',  -- muggins-mode.sql
    'public.confirm_win(uuid)',                    'ea2ec622a2cef0fffcc255257c816d94',  -- muggins-mode.sql
    'public.leave_table(uuid)',                    '9c15b86bd236e9ffb108e9318251c5b8',  -- phase2-slice-5-cut-before-deal.sql
    'public.end_timed_out_sessions()',             'd46b95e2f27b93f2707d050de560720f',  -- phase2-slice-5-cut-before-deal.sql
    'public.set_seat(uuid, uuid, int)',            '9839026aa3f3b5d8d72281aeeac499d6',  -- phase3-e1-seating.sql
    'public.seat_team(int)',                       '497c9983cf20d23e52da11ea79768605',  -- phase3-e1-seating.sql
    'public.table_host(uuid)',                     'fca691d91d3aadf74972906e75019646',  -- phase3-e1-seating.sql
    'public.assign_table_seat()',                  '5f2ea7a318c9f3a6dc7552f6bf7e0380'   -- phase3-e1-seating.sql
  );
  v_bad := null;
  for v_rec in select key, value #>> '{}' as md5 from jsonb_each(v_expected) loop
    select md5(replace(p.prosrc, E'\r', '')) into v_md5
    from pg_proc p where p.oid = to_regprocedure(v_rec.key);
    if v_md5 is distinct from v_rec.md5 then
      v_bad := coalesce(v_bad || '; ', '') || v_rec.key || ' has ' || coalesce(v_md5, '(missing)');
    end if;
  end loop;
  if v_bad is not null then
    raise exception 'FAIL [S2] function bodies differ from docs/sql: %.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [S3] The fourteen client functions: authenticated can execute, anon can't.
  v_n := 0;
  foreach v_fn in array v_client loop
    if to_regprocedure(v_fn) is null or not has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'FAIL [S3] authenticated cannot execute %.', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'FAIL [S3] anon CAN execute %.', v_fn;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 14 then raise exception 'FAIL [S3] checked % client functions, expected 14.', v_n; end if;
  v_checks := v_checks + 1;

  -- [S4] Of every function this project defines, exactly those fourteen are
  -- client-callable (deal_cards_for_game, among others, is not).
  select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text) into v_bad
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in (
      'acknowledge_deal_cut', 'award_points', 'card_play_value', 'card_rank_value', 'claim_win',
      'clear_win_claim', 'confirm_count', 'confirm_win', 'deal_cards_for_game', 'discard_to_crib',
      'draw_cut_card', 'end_timed_out_sessions', 'has_legal_play', 'leave_table', 'next_hand',
      'play_card', 'score_hand', 'score_pegging', 'show_crib', 'show_hand', 'shuffled_deck',
      'start_game_with_deal', 'assign_table_seat', 'seat_team', 'table_host', 'set_seat'
    )
    and (has_function_privilege('authenticated', p.oid, 'execute')
         or has_function_privilege('anon', p.oid, 'execute'))
    and p.oid not in (select to_regprocedure(x)::oid from unnest(v_client) x);
  if v_bad is not null then
    raise exception 'FAIL [S4] these functions are client-callable but should not be: %.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [S5] start_game_with_deal takes the table lock -- FOR NO KEY UPDATE on
  -- the tables row -- before its first guard reads anything.
  select replace(p.prosrc, E'\r', '') into v_msg
  from pg_proc p where p.oid = 'public.start_game_with_deal(uuid)'::regprocedure;
  if v_msg !~ 'from public\.tables t\s+where t\.id = p_table_id\s+for no key update'
     or strpos(v_msg, 'for no key update') > strpos(v_msg, 'Guard 2 (the membership check)') then
    raise exception 'FAIL [S5] start_game_with_deal does not lock the tables row before its guards.';
  end if;
  v_checks := v_checks + 1;

  -- [S6] The read rules for hands, cribs and the deck are unchanged: three
  -- policies each on game_hands and game_cribs, none on game_decks.
  select count(*) into v_n from pg_policies where schemaname = 'public' and tablename = 'game_hands';
  select count(*) into v_n2 from pg_policies where schemaname = 'public' and tablename = 'game_cribs';
  select count(*) into v_n3 from pg_policies where schemaname = 'public' and tablename = 'game_decks';
  if v_n <> 3 or v_n2 <> 3 or v_n3 <> 0
     or not exists (select 1 from pg_policies where tablename = 'game_hands' and policyname = 'Players read their own hand, or a hand shown at their table')
     or not exists (select 1 from pg_policies where tablename = 'game_hands' and policyname = 'Players read every hand once pegging is over')
     or not exists (select 1 from pg_policies where tablename = 'game_hands' and policyname = 'Players of a won game read its hands')
     or not exists (select 1 from pg_policies where tablename = 'game_cribs' and policyname = 'Players at the table read a shown crib')
     or not exists (select 1 from pg_policies where tablename = 'game_cribs' and policyname = 'Players read the crib once it is up for counting')
     or not exists (select 1 from pg_policies where tablename = 'game_cribs' and policyname = 'Players of a won game read its crib') then
    raise exception 'FAIL [S6] the hand / crib / deck policies changed (% / % / %).', v_n, v_n2, v_n3;
  end if;
  v_checks := v_checks + 1;

  -- ==== R: the 2-player game, exactly as before ===============================
  -- A creates a 2-player table and sits.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  insert into public.tables (code, created_by) values (v_codes[1], v_a) returning id into v_t2;
  insert into public.table_members (table_id, user_id) values (v_t2, v_a)
  on conflict (table_id, user_id) do nothing;

  -- [R1] Alone at the table: the old refusal, word for word.
  v_msg := null;
  begin perform public.start_game_with_deal(v_t2); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'A game needs exactly 2 players at the table (currently 1).' then
    raise exception 'FAIL [R1] starting alone: %, expected the old "exactly 2 players (currently 1)".', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [R2] Not seated at the table: the old refusal.
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  v_msg := null;
  begin perform public.start_game_with_deal(v_t2); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'You are not a member of this table.' then
    raise exception 'FAIL [R2] a non-member starting: %, expected the old membership refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- B sits; B taps New Game.
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  insert into public.table_members (table_id, user_id) values (v_t2, v_b)
  on conflict (table_id, user_id) do nothing;
  v_g := public.start_game_with_deal(v_t2);
  execute 'reset role';

  -- [R3] The first game cuts for deal: 'cutting', no dealer, one empty round,
  -- the two players (seat order: A, B), and nothing dealt.
  select status, dealer_id, deal_cut, players, deal_cut_ack_by into v_rec from public.games where id = v_g;
  if v_rec.status is distinct from 'cutting' or v_rec.dealer_id is not null or v_rec.deal_cut is distinct from '[[]]'::jsonb
     or v_rec.players is distinct from array[v_a, v_b] or v_rec.deal_cut_ack_by is distinct from '{}'::uuid[]
     or exists (select 1 from public.game_hands where game_id = v_g)
     or exists (select 1 from public.game_decks where game_id = v_g)
     or exists (select 1 from public.game_cribs where game_id = v_g) then
    raise exception 'FAIL [R3] a 2-player start: % / dealer % / cut % / players %, expected cutting / null / [[]] / {A,B}, nothing dealt.',
      v_rec.status, v_rec.dealer_id, v_rec.deal_cut, v_rec.players;
  end if;
  v_checks := v_checks + 1;

  -- [R4] A second New Game while it cuts hands back the same game.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_ret := public.start_game_with_deal(v_t2);
  execute 'reset role';
  select count(*) into v_n from public.games where table_id = v_t2;
  if v_ret is distinct from v_g or v_n <> 1 then
    raise exception 'FAIL [R4] a second tap while cutting: game %, % game(s), expected the same game and 1.', v_ret, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [R5] Both draw: two distinct cards, one each; the dealer is the unique
  -- lowest, or nobody yet on a tie.
  execute 'set local role authenticated';
  perform public.draw_cut_card(v_g);
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  perform public.draw_cut_card(v_g);
  execute 'reset role';
  select deal_cut, dealer_id into v_rec from public.games where id = v_g;
  select count(*), count(distinct e ->> 'card'), count(distinct e ->> 'user_id')
  into v_n, v_n2, v_n3
  from jsonb_array_elements(v_rec.deal_cut -> 0) e;
  if v_n <> 2 or v_n2 <> 2 or v_n3 <> 2
     or v_rec.dealer_id is distinct from (
       -- the one player holding the lowest rank, or null if several do
       select case when count(*) = 1 then min(e ->> 'user_id')::uuid end
       from jsonb_array_elements(v_rec.deal_cut -> 0) e
       where public.card_rank_value(e ->> 'card') = (
         select min(public.card_rank_value(e2 ->> 'card'))
         from jsonb_array_elements(v_rec.deal_cut -> 0) e2
       )
     ) then
    raise exception 'FAIL [R5] the 2-player cut: round % / dealer %.', v_rec.deal_cut, v_rec.dealer_id;
  end if;
  v_checks := v_checks + 1;

  -- A decisive round, set to known cards: B cut a 3, A a 9 -- B deals.
  update public.games
  set deal_cut = jsonb_build_array(jsonb_build_array(
        jsonb_build_object('user_id', v_a, 'card', '9H'),
        jsonb_build_object('user_id', v_b, 'card', '3C'))),
      dealer_id = v_b,
      deal_cut_ack_by = '{}'
  where id = v_g;

  -- [R6] A acknowledges: recorded, still cutting, nothing dealt.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  perform public.acknowledge_deal_cut(v_g);
  execute 'reset role';
  select status, deal_cut_ack_by into v_rec from public.games where id = v_g;
  if v_rec.status is distinct from 'cutting' or v_rec.deal_cut_ack_by is distinct from array[v_a]
     or exists (select 1 from public.game_hands where game_id = v_g) then
    raise exception 'FAIL [R6] the first acknowledgement: % / acks %, expected cutting / {A}, nothing dealt.', v_rec.status, v_rec.deal_cut_ack_by;
  end if;
  v_checks := v_checks + 1;

  -- [R7] B acknowledges: dealt -- 'active', phase 'discard', 6 cards each,
  -- 40 in the deck, no crib yet, and all 52 cards distinct.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  perform public.acknowledge_deal_cut(v_g);
  execute 'reset role';
  select status, phase, dealer_id, deal_cut_ack_by into v_rec from public.games where id = v_g;
  select count(*) into v_n from public.game_hands where game_id = v_g and coalesce(array_length(cards, 1), 0) = 6;
  select cards into v_deck from public.game_decks where game_id = v_g;
  select count(*), count(distinct c) into v_n2, v_n3 from (
    select unnest(cards) as c from public.game_hands where game_id = v_g
    union all select unnest(cards) from public.game_decks where game_id = v_g
  ) all_cards;
  if v_rec.status is distinct from 'active' or v_rec.phase is distinct from 'discard' or v_rec.dealer_id is distinct from v_b
     or v_rec.deal_cut_ack_by is distinct from '{}'::uuid[] or v_n <> 2 or coalesce(array_length(v_deck, 1), 0) <> 40
     or exists (select 1 from public.game_cribs where game_id = v_g) or v_n2 <> 52 or v_n3 <> 52 then
    raise exception 'FAIL [R7] the 2-player deal: % / % / dealer % / % six-card hands / deck % / % cards, % distinct.',
      v_rec.status, v_rec.phase, v_rec.dealer_id, v_n, coalesce(array_length(v_deck, 1), 0), v_n2, v_n3;
  end if;
  v_checks := v_checks + 1;

  -- The old discard refusals, as A.
  select cards into v_hand from public.game_hands where game_id = v_g and user_id = v_a;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);

  -- [R8] One card: "exactly 2 cards".
  v_msg := null;
  begin perform public.discard_to_crib(v_g, array[v_hand[1]]); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'You must discard exactly 2 cards.' then
    raise exception 'FAIL [R8] a 1-card discard in a 2-player game: %, expected the old "exactly 2 cards".', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [R9] The same card twice: "2 different cards".
  v_msg := null;
  begin perform public.discard_to_crib(v_g, array[v_hand[1], v_hand[1]]); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'You must discard 2 different cards.' then
    raise exception 'FAIL [R9] the same card twice: %, expected the old "2 different cards".', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [R10] A card A doesn't hold: the anti-cheat refusal.
  v_msg := null;
  begin
    perform public.discard_to_crib(v_g, array[v_hand[1], (select cards[1] from public.game_hands where game_id = v_g and user_id = v_b)]);
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg is distinct from 'You can only discard cards from your own hand.' then
    raise exception 'FAIL [R10] discarding a card not held: %, expected the old refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [R11] A discards two: 4 left, the crib holds 2, still the discard phase.
  perform public.discard_to_crib(v_g, v_hand[1:2]);
  execute 'reset role';
  select phase, discarded_by into v_rec from public.games where id = v_g;
  if (select array_length(cards, 1) from public.game_hands where game_id = v_g and user_id = v_a) <> 4
     or (select array_length(cards, 1) from public.game_cribs where game_id = v_g) <> 2
     or v_rec.phase is distinct from 'discard' or v_rec.discarded_by is distinct from array[v_a] then
    raise exception 'FAIL [R11] after the first 2-player discard: phase % / discarded %.', v_rec.phase, v_rec.discarded_by;
  end if;
  v_checks := v_checks + 1;

  -- [R12] B discards two: the crib is the 4 discards, 4 cards each, the
  -- starter is cut from the deck (39 left) and is nobody's, the play phase
  -- begins and the non-dealer (A) leads.
  v_discards := v_hand[1:2];
  select cards into v_hand from public.game_hands where game_id = v_g and user_id = v_b;
  v_discards := v_discards || v_hand[1:2];
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  perform public.discard_to_crib(v_g, v_hand[1:2]);
  execute 'reset role';
  select phase, current_player, starter_card, play_count into v_rec from public.games where id = v_g;
  select cards into v_crib from public.game_cribs where game_id = v_g;
  select cards into v_deck from public.game_decks where game_id = v_g;
  if v_rec.phase is distinct from 'play' or v_rec.current_player is distinct from v_a or v_rec.play_count <> 0
     or v_rec.starter_card is null
     or not (v_crib @> v_discards and v_discards @> v_crib) or array_length(v_crib, 1) <> 4
     or exists (select 1 from public.game_hands where game_id = v_g and array_length(cards, 1) <> 4)
     or v_rec.starter_card = any(v_crib) or v_rec.starter_card = any(v_deck)
     or exists (select 1 from public.game_hands where game_id = v_g and v_rec.starter_card = any(cards))
     or coalesce(array_length(v_deck, 1), 0) <> 39 then
    raise exception 'FAIL [R12] after both 2-player discards: % / lead % / starter % / crib % / deck %.',
      v_rec.phase, v_rec.current_player, v_rec.starter_card, v_crib, coalesce(array_length(v_deck, 1), 0);
  end if;
  v_checks := v_checks + 1;

  -- The match is won by A (as award_points would leave it), scores mid-match.
  update public.games set status = 'ended', ended_reason = 'won', winner_id = v_a where id = v_g;
  update public.table_members set score = 121 where table_id = v_t2 and user_id = v_a;
  update public.table_members set score = 87 where table_id = v_t2 and user_id = v_b;

  -- [R13] B taps New Game: only recorded (NULL), nothing starts.
  execute 'set local role authenticated';
  v_ret := public.start_game_with_deal(v_t2);
  execute 'reset role';
  if v_ret is not null or (select ready_by from public.games where id = v_g) is distinct from array[v_b]
     or exists (select 1 from public.games where table_id = v_t2 and status in ('cutting', 'active')) then
    raise exception 'FAIL [R13] the first New Game tap after a win: result %, expected NULL and B recorded.', v_ret;
  end if;
  v_checks := v_checks + 1;

  -- [R14] A taps: the rematch starts at once -- 'active', no cut, the LOSER
  -- (B) deals, 6 cards each, scores reset.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_g2 := public.start_game_with_deal(v_t2);
  execute 'reset role';
  select status, dealer_id, deal_cut, phase into v_rec from public.games where id = v_g2;
  select count(*) into v_n from public.game_hands where game_id = v_g2 and coalesce(array_length(cards, 1), 0) = 6;
  if v_g2 is null or v_rec.status is distinct from 'active' or v_rec.dealer_id is distinct from v_b or v_rec.deal_cut is not null
     or v_rec.phase is distinct from 'discard' or v_n <> 2
     or (select array_length(cards, 1) from public.game_decks where game_id = v_g2) <> 40
     or exists (select 1 from public.table_members where table_id = v_t2 and score <> 0) then
    raise exception 'FAIL [R14] the 2-player rematch: game % is % / dealer % / cut % / % hands, expected active / B / null / 2, scores 0.',
      v_g2, v_rec.status, v_rec.dealer_id, v_rec.deal_cut, v_n;
  end if;
  v_checks := v_checks + 1;

  -- ==== T: 3 players ==========================================================
  -- A creates a 3-player table; A and B sit.
  execute 'set local role authenticated';
  insert into public.tables (code, created_by, max_players) values (v_codes[2], v_a, 3) returning id into v_t3;
  insert into public.table_members (table_id, user_id) values (v_t3, v_a)
  on conflict (table_id, user_id) do nothing;
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  insert into public.table_members (table_id, user_id) values (v_t3, v_b)
  on conflict (table_id, user_id) do nothing;

  -- [T1] The host with only 2 of 3 seated: refused, naming the table's size.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin perform public.start_game_with_deal(v_t3); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'A game needs exactly 3 players at the table (currently 2).' then
    raise exception 'FAIL [T1] a 3-player start with 2 seated: %, expected "exactly 3 players (currently 2)".', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- C sits (the third seat).
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  insert into public.table_members (table_id, user_id) values (v_t3, v_c)
  on conflict (table_id, user_id) do nothing;

  -- [T2] B, seated but not the host: refused.
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.start_game_with_deal(v_t3); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'Only the host can start the game.' then
    raise exception 'FAIL [T2] a non-host starting a 3-player game: %, expected the host refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [T3] C, who hosts ANOTHER 3-player table, can't start this one either.
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  insert into public.tables (code, created_by, max_players) values (v_codes[3], v_c, 3) returning id into v_t3o;
  insert into public.table_members (table_id, user_id) values (v_t3o, v_c)
  on conflict (table_id, user_id) do nothing;
  v_msg := null;
  begin perform public.start_game_with_deal(v_t3); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'Only the host can start the game.' or public.table_host(v_t3o) is distinct from v_c then
    raise exception 'FAIL [T3] another table''s host starting this one: %, expected the host refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- JOIN order A, B, C (explicit times, as the owner); then A, the host,
  -- swaps C into seat 2: seats are now A 1, C 2, B 3.
  update public.table_members set joined_at = now() - interval '30 minutes' where table_id = v_t3 and user_id = v_a;
  update public.table_members set joined_at = now() - interval '20 minutes' where table_id = v_t3 and user_id = v_b;
  update public.table_members set joined_at = now() - interval '10 minutes' where table_id = v_t3 and user_id = v_c;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  perform public.set_seat(v_t3, v_c, 2);

  -- [T4] The host starts: a cut, and the players in SEAT order (A, C, B),
  -- not join order (A, B, C).
  v_g := public.start_game_with_deal(v_t3);
  execute 'reset role';
  select status, dealer_id, deal_cut, players into v_rec from public.games where id = v_g;
  if v_rec.status is distinct from 'cutting' or v_rec.dealer_id is not null or v_rec.deal_cut is distinct from '[[]]'::jsonb
     or v_rec.players is distinct from array[v_a, v_c, v_b] then
    raise exception 'FAIL [T4] a 3-player start: % / dealer % / cut % / players %, expected cutting / null / [[]] / {A,C,B}.',
      v_rec.status, v_rec.dealer_id, v_rec.deal_cut, v_rec.players;
  end if;
  v_checks := v_checks + 1;

  -- [T5] All three draw: three distinct cards, one each; the dealer is the
  -- unique lowest, or nobody yet on a tie.
  execute 'set local role authenticated';
  foreach v_player in array array[v_a, v_c, v_b] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    perform public.draw_cut_card(v_g);
  end loop;
  execute 'reset role';
  select deal_cut, dealer_id into v_rec from public.games where id = v_g;
  select count(*), count(distinct e ->> 'card'), count(distinct e ->> 'user_id')
  into v_n, v_n2, v_n3
  from jsonb_array_elements(v_rec.deal_cut -> 0) e;
  if v_n <> 3 or v_n2 <> 3 or v_n3 <> 3
     or v_rec.dealer_id is distinct from (
       -- the one player holding the lowest rank, or null if several do
       select case when count(*) = 1 then min(e ->> 'user_id')::uuid end
       from jsonb_array_elements(v_rec.deal_cut -> 0) e
       where public.card_rank_value(e ->> 'card') = (
         select min(public.card_rank_value(e2 ->> 'card'))
         from jsonb_array_elements(v_rec.deal_cut -> 0) e2
       )
     ) then
    raise exception 'FAIL [T5] the 3-player cut draws: round % / dealer %.', v_rec.deal_cut, v_rec.dealer_id;
  end if;
  v_checks := v_checks + 1;

  -- [T6] A TIE, set to known cards (A and C both cut a five): once all three
  -- acknowledge, a fresh empty round opens for everyone, the acks clear, and
  -- nothing is dealt.
  update public.games
  set deal_cut = jsonb_build_array(jsonb_build_array(
        jsonb_build_object('user_id', v_a, 'card', '5H'),
        jsonb_build_object('user_id', v_c, 'card', '5S'),
        jsonb_build_object('user_id', v_b, 'card', '9D'))),
      dealer_id = null,
      deal_cut_ack_by = '{}'
  where id = v_g;
  execute 'set local role authenticated';
  foreach v_player in array array[v_a, v_c, v_b] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    perform public.acknowledge_deal_cut(v_g);
  end loop;
  execute 'reset role';
  select status, deal_cut, dealer_id, deal_cut_ack_by into v_rec from public.games where id = v_g;
  if v_rec.status is distinct from 'cutting' or jsonb_array_length(v_rec.deal_cut) <> 2
     or v_rec.deal_cut -> 1 is distinct from '[]'::jsonb or v_rec.dealer_id is not null
     or v_rec.deal_cut_ack_by is distinct from '{}'::uuid[] or exists (select 1 from public.game_hands where game_id = v_g) then
    raise exception 'FAIL [T6] a 3-player tie: % / rounds % / dealer % / acks %, expected cutting / 2 with the last empty / null / {}.',
      v_rec.status, v_rec.deal_cut, v_rec.dealer_id, v_rec.deal_cut_ack_by;
  end if;
  v_checks := v_checks + 1;

  -- A decisive second round, set to known cards: C cut a 2, the lowest -- C
  -- deals (as draw_cut_card leaves it).
  update public.games
  set deal_cut = jsonb_build_array(deal_cut -> 0, jsonb_build_array(
        jsonb_build_object('user_id', v_a, 'card', 'KH'),
        jsonb_build_object('user_id', v_c, 'card', '2S'),
        jsonb_build_object('user_id', v_b, 'card', '9C'))),
      dealer_id = v_c
  where id = v_g;

  -- [T7] Two acknowledgements only record; the third deals.
  execute 'set local role authenticated';
  foreach v_player in array array[v_a, v_c] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    perform public.acknowledge_deal_cut(v_g);
  end loop;
  execute 'reset role';
  if (select status from public.games where id = v_g) is distinct from 'cutting'
     or exists (select 1 from public.game_hands where game_id = v_g) then
    raise exception 'FAIL [T7] two of three acknowledgements dealt the 3-player game.';
  end if;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  perform public.acknowledge_deal_cut(v_g);
  execute 'reset role';
  select status, phase, dealer_id into v_rec from public.games where id = v_g;
  if v_rec.status is distinct from 'active' or v_rec.phase is distinct from 'discard' or v_rec.dealer_id is distinct from v_c then
    raise exception 'FAIL [T7] the third acknowledgement: % / % / dealer %, expected active / discard / C.', v_rec.status, v_rec.phase, v_rec.dealer_id;
  end if;
  v_checks := v_checks + 1;

  -- [T8] The 3-player deal: 5 cards each, 1 card in the crib, 36 in the
  -- deck, and all 52 cards distinct.
  select count(*) into v_n from public.game_hands where game_id = v_g and coalesce(array_length(cards, 1), 0) = 5;
  select cards into v_crib from public.game_cribs where game_id = v_g;
  select cards into v_deck from public.game_decks where game_id = v_g;
  select count(*), count(distinct c) into v_n2, v_n3 from (
    select unnest(cards) as c from public.game_hands where game_id = v_g
    union all select unnest(cards) from public.game_cribs where game_id = v_g
    union all select unnest(cards) from public.game_decks where game_id = v_g
  ) all_cards;
  if v_n <> 3 or (select count(*) from public.game_hands where game_id = v_g) <> 3
     or coalesce(array_length(v_crib, 1), 0) <> 1 or coalesce(array_length(v_deck, 1), 0) <> 36
     or v_n2 <> 52 or v_n3 <> 52 then
    raise exception 'FAIL [T8] the 3-player deal: % five-card hands / crib % / deck % / % cards, % distinct; expected 3 / 1 / 36 / 52 / 52.',
      v_n, coalesce(array_length(v_crib, 1), 0), coalesce(array_length(v_deck, 1), 0), v_n2, v_n3;
  end if;
  v_checks := v_checks + 1;

  -- ==== P: privacy, 3 players, before the discards ============================
  -- [P1] B reads only B's own hand -- not the others', not the crib (with
  -- its extra card), not the deck. C (the dealer) can't read the crib either.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  select count(*), count(*) filter (where user_id = v_b) into v_n, v_n2 from public.game_hands where game_id = v_g;
  select count(*) into v_n3 from public.game_cribs where game_id = v_g;
  v_state := null;
  begin
    select count(*)::text into v_msg from public.game_decks where game_id = v_g;
  exception when others then v_state := sqlstate; v_msg := '0';  -- no privilege at all: nothing read
  end;
  if v_n <> 1 or v_n2 <> 1 or v_n3 <> 0 or v_msg <> '0' then
    raise exception 'FAIL [P1] B in a 3-player game read % hand(s) (% own), % crib row(s), % deck row(s); expected 1 / 1 / 0 / 0.', v_n, v_n2, v_n3, v_msg;
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  if (select count(*) from public.game_cribs where game_id = v_g) <> 0 then
    raise exception 'FAIL [P1] the 3-player dealer can read the crib before its count.';
  end if;
  v_checks := v_checks + 1;

  -- [P2] E, who is not at the table, reads nothing at all.
  perform set_config('request.jwt.claims', json_build_object('sub', v_e, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_e::text, true);
  select count(*) into v_n from public.game_hands where game_id = v_g;
  select count(*) into v_n2 from public.game_cribs where game_id = v_g;
  v_state := null;
  begin
    select count(*)::text into v_msg from public.game_decks where game_id = v_g;
  exception when others then v_state := sqlstate; v_msg := '0';  -- no privilege at all: nothing read
  end;
  execute 'reset role';
  if v_n <> 0 or v_n2 <> 0 or v_msg <> '0' then
    raise exception 'FAIL [P2] a non-member read % hand(s), % crib row(s), % deck row(s) of a 3-player game.', v_n, v_n2, v_msg;
  end if;
  v_checks := v_checks + 1;

  -- ==== T (continued): the 3-player discards ==================================
  select cards into v_hand from public.game_hands where game_id = v_g and user_id = v_b;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);

  -- [T9] No card, or two: "exactly 1 card".
  v_msg := null;
  begin perform public.discard_to_crib(v_g, '{}'::text[]); exception when others then v_msg := sqlerrm; end;
  v_state := null;
  begin perform public.discard_to_crib(v_g, v_hand[1:2]); exception when others then v_state := sqlerrm; end;
  if v_msg is distinct from 'You must discard exactly 1 card.' or v_state is distinct from 'You must discard exactly 1 card.' then
    raise exception 'FAIL [T9] a 3-player discard of 0 / 2 cards: % / %, expected "exactly 1 card" both times.', coalesce(v_msg, 'no error'), coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [T10] A card B doesn't hold: refused.
  v_msg := null;
  begin
    perform public.discard_to_crib(v_g, array[(select cards[1] from public.game_hands where game_id = v_g and user_id = v_a)]);
  exception when others then v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'You can only discard cards from your own hand.' then
    raise exception 'FAIL [T10] a 3-player discard of a card not held: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [T11] All three discard one card. Then: the crib is the extra card plus
  -- the 3 discards (4), 4 cards each, the starter is cut from the deck (35
  -- left) and is nobody's, the play phase begins, and the player on the
  -- dealer's LEFT leads -- the dealer C sits in seat 2, so B (seat 3).
  -- Each player's last card, read as the owner (a player can only read
  -- their own hand).
  v_players := array[v_a, v_c, v_b];
  v_cards := '{}';
  foreach v_player in array v_players loop
    v_cards := v_cards || (select cards[5] from public.game_hands where game_id = v_g and user_id = v_player);
  end loop;
  v_discards := (select cards from public.game_cribs where game_id = v_g) || v_cards;
  execute 'set local role authenticated';
  for i in 1 .. 3 loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_players[i], 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_players[i]::text, true);
    perform public.discard_to_crib(v_g, array[v_cards[i]]);
  end loop;
  execute 'reset role';
  select phase, current_player, starter_card into v_rec from public.games where id = v_g;
  select cards into v_crib from public.game_cribs where game_id = v_g;
  select cards into v_deck from public.game_decks where game_id = v_g;
  if v_rec.phase is distinct from 'play' or v_rec.current_player is distinct from v_b or v_rec.starter_card is null
     or array_length(v_crib, 1) <> 4 or not (v_crib @> v_discards and v_discards @> v_crib)
     or exists (select 1 from public.game_hands where game_id = v_g and array_length(cards, 1) <> 4)
     or v_rec.starter_card = any(v_crib) or v_rec.starter_card = any(v_deck)
     or exists (select 1 from public.game_hands where game_id = v_g and v_rec.starter_card = any(cards))
     or coalesce(array_length(v_deck, 1), 0) <> 35 then
    raise exception 'FAIL [T11] after the 3-player discards: % / lead % / starter % / crib % / deck %; expected play / B / set / 4 / 35.',
      v_rec.phase, v_rec.current_player, v_rec.starter_card, v_crib, coalesce(array_length(v_deck, 1), 0);
  end if;
  v_checks := v_checks + 1;

  -- [P3] In the play phase B still reads only B's own hand, and no crib.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  select count(*) into v_n from public.game_hands where game_id = v_g;
  select count(*) into v_n2 from public.game_cribs where game_id = v_g;
  execute 'reset role';
  if v_n <> 1 or v_n2 <> 0 then
    raise exception 'FAIL [P3] B in the 3-player play phase read % hand(s) and % crib row(s); expected 1 and 0.', v_n, v_n2;
  end if;
  v_checks := v_checks + 1;

  -- [T12] The next hand (the counting set to done, as the owner): every
  -- player taps; the deal rotates CLOCKWISE (C, seat 2 -> B, seat 3), and the
  -- new hand is 5 + 5 + 5 with 1 in the crib and 36 in the deck.
  update public.games set phase = 'done', count_step = 2, current_player = null where id = v_g;
  execute 'set local role authenticated';
  foreach v_player in array array[v_a, v_c, v_b] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    perform public.next_hand(v_g, 1);
  end loop;
  execute 'reset role';
  select hand_no, dealer_id, phase, ready_by into v_rec from public.games where id = v_g;
  select count(*) into v_n from public.game_hands where game_id = v_g and coalesce(array_length(cards, 1), 0) = 5;
  if v_rec.hand_no <> 2 or v_rec.dealer_id is distinct from v_b or v_rec.phase is distinct from 'discard'
     or v_rec.ready_by is distinct from '{}'::uuid[] or v_n <> 3
     or (select array_length(cards, 1) from public.game_cribs where game_id = v_g) <> 1
     or (select array_length(cards, 1) from public.game_decks where game_id = v_g) <> 36 then
    raise exception 'FAIL [T12] the second 3-player hand: hand % / dealer % / % / % five-card hands.', v_rec.hand_no, v_rec.dealer_id, v_rec.phase, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [T13] A rematch after A wins: A and B tap (recorded, NULL); C's tap
  -- starts it -- no cut, and the next seat clockwise from the winner (C,
  -- seat 2) deals, 5 cards each.
  update public.games set status = 'ended', ended_reason = 'won', winner_id = v_a where id = v_g;
  execute 'set local role authenticated';
  v_n := 0;
  foreach v_player in array array[v_a, v_b] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    if public.start_game_with_deal(v_t3) is not null then v_n := v_n + 1; end if;
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  v_g2 := public.start_game_with_deal(v_t3);
  execute 'reset role';
  select status, dealer_id, deal_cut into v_rec from public.games where id = v_g2;
  select count(*) into v_n2 from public.game_hands where game_id = v_g2 and coalesce(array_length(cards, 1), 0) = 5;
  if v_n <> 0 or v_g2 is null or v_rec.status is distinct from 'active' or v_rec.dealer_id is distinct from v_c
     or v_rec.deal_cut is not null or v_n2 <> 3 then
    raise exception 'FAIL [T13] the 3-player rematch: % early start(s) / game % is % / dealer % / % hands; expected 0 / active / C / 3.',
      v_n, v_g2, v_rec.status, v_rec.dealer_id, v_n2;
  end if;
  v_checks := v_checks + 1;

  -- ==== F: 4 players (Teams) ==================================================
  -- A creates a 4-player Teams table; A, B and C sit.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  insert into public.tables (code, created_by, max_players, team_mode) values (v_codes[4], v_a, 4, 'teams') returning id into v_t4;
  foreach v_player in array array[v_a, v_b, v_c] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    insert into public.table_members (table_id, user_id) values (v_t4, v_player)
    on conflict (table_id, user_id) do nothing;
  end loop;

  -- [F1] The host with 3 of 4 seated: refused.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin perform public.start_game_with_deal(v_t4); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'A game needs exactly 4 players at the table (currently 3).' then
    raise exception 'FAIL [F1] a 4-player start with 3 seated: %, expected "exactly 4 players (currently 3)".', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- D sits (seat 4). Join order A, B, C, D (explicit times); then B leaves and
  -- rejoins: B takes the freed seat 2 again, but now joined LAST.
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_d::text, true);
  insert into public.table_members (table_id, user_id) values (v_t4, v_d)
  on conflict (table_id, user_id) do nothing;
  execute 'reset role';
  update public.table_members set joined_at = now() - interval '40 minutes' where table_id = v_t4 and user_id = v_a;
  update public.table_members set joined_at = now() - interval '30 minutes' where table_id = v_t4 and user_id = v_b;
  update public.table_members set joined_at = now() - interval '20 minutes' where table_id = v_t4 and user_id = v_c;
  update public.table_members set joined_at = now() - interval '10 minutes' where table_id = v_t4 and user_id = v_d;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  perform public.leave_table(v_t4);
  insert into public.table_members (table_id, user_id) values (v_t4, v_b)
  on conflict (table_id, user_id) do nothing;
  execute 'reset role';

  -- [F2] B is back in seat 2 and is now the LAST to have joined.
  select array_agg(user_id order by joined_at) into v_players from public.table_members where table_id = v_t4;
  if (select seat from public.table_members where table_id = v_t4 and user_id = v_b) is distinct from 2
     or v_players is distinct from array[v_a, v_c, v_d, v_b] then
    raise exception 'FAIL [F2] after B left and rejoined: seat %, join order %; expected 2 and {A,C,D,B}.',
      (select seat from public.table_members where table_id = v_t4 and user_id = v_b), v_players;
  end if;
  v_checks := v_checks + 1;

  -- [F3] D, seated but not the host: refused.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_d::text, true);
  v_msg := null;
  begin perform public.start_game_with_deal(v_t4); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'Only the host can start the game.' then
    raise exception 'FAIL [F3] a non-host starting a 4-player game: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [F4] The host starts: the players in SEAT order (A, B, C, D), not join
  -- order (A, C, D, B).
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_g := public.start_game_with_deal(v_t4);
  execute 'reset role';
  select status, players into v_rec from public.games where id = v_g;
  if v_rec.status is distinct from 'cutting' or v_rec.players is distinct from array[v_a, v_b, v_c, v_d] then
    raise exception 'FAIL [F4] a 4-player start: % / players %, expected cutting / {A,B,C,D}.', v_rec.status, v_rec.players;
  end if;
  v_checks := v_checks + 1;

  -- [F5] A decisive round, set to known cards: D cut the ace -- D deals once
  -- all four acknowledge.
  update public.games
  set deal_cut = jsonb_build_array(jsonb_build_array(
        jsonb_build_object('user_id', v_a, 'card', '9H'),
        jsonb_build_object('user_id', v_b, 'card', 'QS'),
        jsonb_build_object('user_id', v_c, 'card', '4D'),
        jsonb_build_object('user_id', v_d, 'card', 'AC'))),
      dealer_id = v_d,
      deal_cut_ack_by = '{}'
  where id = v_g;
  execute 'set local role authenticated';
  foreach v_player in array array[v_a, v_b, v_c, v_d] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    perform public.acknowledge_deal_cut(v_g);
  end loop;
  execute 'reset role';
  select status, dealer_id into v_rec from public.games where id = v_g;
  if v_rec.status is distinct from 'active' or v_rec.dealer_id is distinct from v_d then
    raise exception 'FAIL [F5] the 4-player cut: % / dealer %, expected active / D.', v_rec.status, v_rec.dealer_id;
  end if;
  v_checks := v_checks + 1;

  -- [F6] The 4-player deal: 5 cards each, no crib card, 32 in the deck, all
  -- 52 cards distinct.
  select count(*) into v_n from public.game_hands where game_id = v_g and coalesce(array_length(cards, 1), 0) = 5;
  select count(*), count(distinct c) into v_n2, v_n3 from (
    select unnest(cards) as c from public.game_hands where game_id = v_g
    union all select unnest(cards) from public.game_decks where game_id = v_g
  ) all_cards;
  if v_n <> 4 or exists (select 1 from public.game_cribs where game_id = v_g)
     or (select array_length(cards, 1) from public.game_decks where game_id = v_g) <> 32
     or v_n2 <> 52 or v_n3 <> 52 then
    raise exception 'FAIL [F6] the 4-player deal: % five-card hands / % cards, % distinct; expected 4, no crib, 32 in the deck, 52 / 52.', v_n, v_n2, v_n3;
  end if;
  v_checks := v_checks + 1;

  -- [P4] C reads only C's own hand, no crib, no deck; E (not at the table)
  -- reads nothing.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  select count(*), count(*) filter (where user_id = v_c) into v_n, v_n2 from public.game_hands where game_id = v_g;
  v_state := null;
  begin
    select count(*)::text into v_msg from public.game_decks where game_id = v_g;
  exception when others then v_state := sqlstate; v_msg := '0';  -- no privilege at all: nothing read
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_e, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_e::text, true);
  select count(*) into v_n3 from public.game_hands where game_id = v_g;
  execute 'reset role';
  if v_n <> 1 or v_n2 <> 1 or v_msg <> '0' or v_n3 <> 0 then
    raise exception 'FAIL [P4] 4-player privacy: C read % hand(s) (% own) and % deck row(s); E read % hand(s).', v_n, v_n2, v_msg, v_n3;
  end if;
  v_checks := v_checks + 1;

  -- [F7] Two cards in a 4-player game: "exactly 1 card".
  select cards into v_hand from public.game_hands where game_id = v_g and user_id = v_a;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin perform public.discard_to_crib(v_g, v_hand[1:2]); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'You must discard exactly 1 card.' then
    raise exception 'FAIL [F7] a 2-card discard in a 4-player game: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [F8] All four discard one card: the crib is exactly those 4 discards, 4
  -- cards each, the starter is cut (31 left) and is nobody's, and the lead
  -- WRAPS from the dealer's seat 4 to seat 1 (A).
  -- Each player's first card, read as the owner.
  v_players := array[v_a, v_b, v_c, v_d];
  v_discards := '{}';
  foreach v_player in array v_players loop
    v_discards := v_discards || (select cards[1] from public.game_hands where game_id = v_g and user_id = v_player);
  end loop;
  execute 'set local role authenticated';
  for i in 1 .. 4 loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_players[i], 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_players[i]::text, true);
    perform public.discard_to_crib(v_g, array[v_discards[i]]);
  end loop;
  execute 'reset role';
  select phase, current_player, starter_card into v_rec from public.games where id = v_g;
  select cards into v_crib from public.game_cribs where game_id = v_g;
  select cards into v_deck from public.game_decks where game_id = v_g;
  if v_rec.phase is distinct from 'play' or v_rec.current_player is distinct from v_a or v_rec.starter_card is null
     or array_length(v_crib, 1) <> 4 or not (v_crib @> v_discards and v_discards @> v_crib)
     or exists (select 1 from public.game_hands where game_id = v_g and array_length(cards, 1) <> 4)
     or v_rec.starter_card = any(v_crib) or v_rec.starter_card = any(v_deck)
     or exists (select 1 from public.game_hands where game_id = v_g and v_rec.starter_card = any(cards))
     or coalesce(array_length(v_deck, 1), 0) <> 31 then
    raise exception 'FAIL [F8] after the 4-player discards: % / lead % / starter % / crib % / deck %; expected play / A / set / the 4 discards / 31.',
      v_rec.phase, v_rec.current_player, v_rec.starter_card, v_crib, coalesce(array_length(v_deck, 1), 0);
  end if;
  v_checks := v_checks + 1;

  -- ==== M: the size rule on an over-full 2-player table =======================
  -- A table seated with 3 and then (as the owner) made a 2-player table --
  -- the state an over-full table from before E1 is in.
  execute 'set local role authenticated';
  foreach v_player in array array[v_a, v_b, v_c] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    if v_player = v_a then
      insert into public.tables (code, created_by, max_players) values (v_codes[5], v_a, 3) returning id into v_t2x;
    end if;
    insert into public.table_members (table_id, user_id) values (v_t2x, v_player)
    on conflict (table_id, user_id) do nothing;
  end loop;
  execute 'reset role';
  update public.tables set max_players = 2 where id = v_t2x;

  -- [M1] Nobody can start it: "exactly 2 players (currently 3)", as before.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.start_game_with_deal(v_t2x); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'A game needs exactly 2 players at the table (currently 3).' then
    raise exception 'FAIL [M1] an over-full 2-player table: %, expected "exactly 2 players (currently 3)".', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  raise exception 'ALL % CHECKS PASSED (rolled back). A=% B=%.', v_checks, v_a, v_b;
end $$;
