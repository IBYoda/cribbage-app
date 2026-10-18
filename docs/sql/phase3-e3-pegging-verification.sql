-- Phase 3, step E3: VERIFICATION.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER
-- docs/sql/phase3-e3-pegging.sql. The whole file is ONE DO block: run it as
-- is.
--
-- It WRITES -- it creates tables, seats players, starts and deals games,
-- plays whole hands of pegging, and (for the 2-player proof) creates a
-- temporary copy of the OLD play_card -- and then deliberately raises an
-- exception at the very end, which rolls every write back, the temporary
-- function included. It always "fails": the message is the verdict. "ALL n
-- CHECKS PASSED (rolled back) ..." is a pass; anything starting "FAIL" or
-- "SETUP" is not. Re-runnable, because nothing it does survives. (Same
-- pattern as phase3-e2-dealing-verification.sql.)
--
-- Same impersonation as before: request.jwt.claims plus "set local role
-- authenticated" to act as a player, "reset role" to act as the owner.
--
-- PLAYERS: A and B are the two OLDEST accounts that are NOT admins; C, D
-- and E are TEMPORARY accounts created in auth.users inside this
-- transaction, as in E1 and E2. E never sits at a table (the non-member).
--
-- THE TABLES: a 2-player table (g2) and its twin (g2o, for the old
-- play_card); a 3-player table seated A 1, C 2, B 3 (join order A, B, C --
-- the seat order is made different on purpose); a 4-player Teams table
-- seated A, B, C, D. The 3- and 4-player games are started, cut for and
-- dealt for real, and every player discards for real, so the play phase
-- they reach is E2's own (T0, F0).
--
-- KNOWN CARDS: every scripted hand is then SET BY THE OWNER -- the dealer,
-- the four (or fewer) cards in each hand, the scores -- with the play log
-- cleared, the count at 0 and the dealer's left to lead, exactly the state
-- discard_to_crib leaves. Then each card of the script is played by the
-- REAL player whose turn it is (current_player), as that player. Every
-- outcome is therefore deterministic.
--
-- THE SCENARIOS (the JSON below) carry, for each scripted hand, what the
-- whole hand must produce: the full play log (seq:segment:player:kind:card:
-- count_after, players as letters), the final state (phase/current player/
-- count/segment/count_step/status/winner), every player's score/last
-- points/last reason, and any refused plays. They were worked out from the
-- approved rules and are printed with the report, so each can be read by
-- hand.
--
-- THE 2-PLAYER PROOF (D1-D12): a copy of the OLD play_card (the body from
-- phase2-batch2a-counting.sql, verbatim) is created as play_card_old inside
-- this transaction. Each of twelve scripted 2-player hands is played on two
-- twin games -- the same hands, the same cards in the same order -- one
-- through play_card, one through play_card_old, and after EVERY card the
-- two are compared: every game_plays row (seq, segment, player, kind, card,
-- count_after), current_player, play_count, play_segment, phase, status,
-- winner, and every score, last_points and last_reason, plus any refusal.
-- The twelve cover a go, repeated go rows, deadlocks, 31s, an opponent out
-- of cards, the last card, every kind of pegging score, a 121 win, and two
-- owner-set short hands that reach the branches a dealt 2-player hand can't
-- (a 31, or a deadlock, with the opponent already out of cards).
--
-- WHAT IT CHECKS
--   S  catalog: play_card is the E3 body; every other function unchanged
--      (md5), E1's and E2's included; 14 client functions, none for anon;
--      the game_plays read policy unchanged.
--   R  2-player rules, each hand's full outcome; the four old refusals word
--      for word.
--   D  2-player equivalence, old vs new, card by card.
--   T  3 players; F 4 players (Teams).
--   P  play_card refusals with 3 players, a non-member, a non-player, a game
--      not in its play phase, and a repeated call.
--
-- Expected message:
--   ALL 43 CHECKS PASSED (rolled back). A=... B=...

do $$
declare
  v_a uuid;
  v_b uuid;
  v_c uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid();
  v_e uuid := gen_random_uuid();
  v_codes text[];
  v_t2 uuid;
  v_t2o uuid;
  v_t3 uuid;
  v_t4 uuid;
  v_g2 uuid;
  v_g2o uuid;
  v_g3 uuid;
  v_g4 uuid;
  v_letters jsonb;
  v_names jsonb;
  v_games jsonb;
  v_scenarios jsonb;
  v_sc jsonb;
  v_gid uuid;
  v_twin uuid;
  v_g uuid;
  v_pl uuid[];
  v_dealer uuid;
  v_who uuid;
  v_card text;
  v_key text;
  v_val jsonb;
  v_step int;
  v_err text;
  v_err2 text;
  v_log text;
  v_log2 text;
  v_state text;
  v_state2 text;
  v_scores text;
  v_scores2 text;
  v_rec record;
  v_n int;
  v_total int;
  v_msg text;
  v_fn text;
  v_bad text;
  v_md5 text;
  v_expected jsonb;
  v_player uuid;
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
      (v_c, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e3-c-' || v_c || '@verification.invalid', now(), now()),
      (v_d, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e3-d-' || v_d || '@verification.invalid', now(), now()),
      (v_e, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e3-e-' || v_e || '@verification.invalid', now(), now());
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts C, D and E in auth.users: % (%).', sqlerrm, sqlstate;
  end;

  -- Letters for the readable logs: A, B, C, D (E plays nothing).
  v_letters := jsonb_build_object('A', v_a, 'B', v_b, 'C', v_c, 'D', v_d);
  v_names := jsonb_build_object(v_a::text, 'A', v_b::text, 'B', v_c::text, 'C', v_d::text, 'D');

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0'))
    order by n
    limit 4
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 4 then
    raise exception 'SETUP: fewer than four unused table codes.';
  end if;

  -- ==== S: catalog, as the owner ==============================================
  -- [S1] play_card is the E3 body (md5 of the body between the dollar
  -- quotes, line endings normalised).
  select md5(replace(p.prosrc, E'\r', '')) into v_md5
  from pg_proc p where p.oid = 'public.play_card(uuid, text)'::regprocedure;
  if v_md5 is distinct from 'cad9e43a7803fdb50eb4d3dd6b5c7210' then
    raise exception 'FAIL [S1] play_card has md5 %, expected the phase3-e3-pegging.sql version cad9e43a7803fdb50eb4d3dd6b5c7210.', v_md5;
  end if;
  v_checks := v_checks + 1;

  -- [S2] Every other function is unchanged: its newest docs/sql body.
  v_expected := jsonb_build_object(
    'public.start_game_with_deal(uuid)',             '3feaa7508cf434b4a3f8d78a8ad9896a',  -- phase3-e2-dealing.sql
    'public.deal_cards_for_game(uuid)',              '1da0902352ffe6729ec663e6265374a2',  -- phase3-e2-dealing.sql
    'public.discard_to_crib(uuid, text[])',          '69ab74268ce6c799c40777436a8cfafd',  -- phase3-e2-dealing.sql
    'public.next_hand(uuid, int)',                   '9007931d5f4cc4ac127c9c2dfd7c1178',  -- phase3-e2-dealing.sql
    'public.draw_cut_card(uuid)',                    '2ca8d114de4e45861e21c23b2e4b65f8',  -- phase2-slice-5-cut-before-deal.sql
    'public.acknowledge_deal_cut(uuid)',             '5b06eec819234121db1bf802ea462c02',  -- phase2-slice-5-cut-before-deal.sql
    'public.has_legal_play(uuid, uuid, int)',        'a269d55520a89d4a8af9aff2a112aa4e',  -- phase2-slice-7-pegging-turns.sql
    'public.score_pegging(text[])',                  'f5259ad8cc24026bddeeda88b20b3b09',  -- phase2-batch1-scoring-engines.sql
    'public.card_play_value(text)',                  '50e1fc5f0404084b38fd6c9636e1fe2d',  -- phase2-slice-7-pegging-turns.sql
    'public.card_rank_value(text)',                  'e4d19acb78fef56594c4998e20bc1090',  -- phase2-slice-4-cut-for-starter.sql
    'public.score_hand(text[], text, boolean)',      '302855ebab0a54717110043ddff8564b',  -- phase2-batch1-scoring-engines.sql
    'public.shuffled_deck()',                        'edcf96f4c9cc19f59e9606b5867bc733',  -- phase2-slice-4-cut-for-starter.sql
    'public.award_points(uuid, uuid, int, text)',    '7234674b5e9be6beac60541661cd964a',  -- muggins-mode.sql
    'public.confirm_count(uuid, int)',               'cca65adc984ebd0fce2a7e8838379809',  -- phase2-batch2a-counting.sql
    'public.show_hand(uuid)',                        'ae5bd9553c21de7a395504f9d39977b6',  -- phase2-batch2a-counting.sql
    'public.show_crib(uuid)',                        'cab1efd1eb3cc00738f3ccef06c72cfe',  -- phase2-batch2a-counting.sql
    'public.leave_table(uuid)',                      '9c15b86bd236e9ffb108e9318251c5b8',  -- phase2-slice-5-cut-before-deal.sql
    'public.end_timed_out_sessions()',               'd46b95e2f27b93f2707d050de560720f',  -- phase2-slice-5-cut-before-deal.sql
    'public.claim_win(uuid)',                        'd95da0d7dc9477a460955749a36164bb',  -- muggins-mode.sql
    'public.clear_win_claim(uuid)',                  '0c4500259a1bb0fed638dce79944fab5',  -- muggins-mode.sql
    'public.confirm_win(uuid)',                      'ea2ec622a2cef0fffcc255257c816d94',  -- muggins-mode.sql
    'public.set_seat(uuid, uuid, int)',              '9839026aa3f3b5d8d72281aeeac499d6',  -- phase3-e1-seating.sql
    'public.seat_team(int)',                         '497c9983cf20d23e52da11ea79768605',  -- phase3-e1-seating.sql
    'public.table_host(uuid)',                       'fca691d91d3aadf74972906e75019646',  -- phase3-e1-seating.sql
    'public.assign_table_seat()',                    '5f2ea7a318c9f3a6dc7552f6bf7e0380'   -- phase3-e1-seating.sql
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
  -- client-callable.
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

  -- [S5] game_plays: still exactly the one read policy (any signed-in user
  -- reads played cards; nobody writes but play_card).
  select count(*) into v_n from pg_policies where schemaname = 'public' and tablename = 'game_plays';
  if v_n <> 1 or not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'game_plays' and cmd = 'SELECT'
      and policyname = 'Played cards are viewable by any logged-in user'
  ) then
    raise exception 'FAIL [S5] the game_plays policies changed (% found).', v_n;
  end if;
  v_checks := v_checks + 1;

  -- ---- The OLD play_card, for the 2-player proof (rolled back) -------------
  create function public.play_card_old(p_game_id uuid, p_card text)
  returns void
  language plpgsql
  security definer
  set search_path = public
  as $old_body$
declare
  v_caller uuid := auth.uid();
  v_game record;
  v_hand text[];
  v_opponent uuid;
  v_value int;
  v_count int;
  v_seq int;
  v_segment int;
  v_leader uuid;
  -- ===== (A) CHANGED FROM SLICE 7 (start) =====
  v_segment_cards text[];
  v_peg jsonb;
  v_points int := 0;
  v_reason text := '';
  v_go_point boolean := false;
  v_phase_over boolean := false;
  -- ===== (A) CHANGED FROM SLICE 7 (end) =====
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to play a card.';
  end if;

  -- THE ROW LOCK. Both players could tap at the same instant. Without this,
  -- each would read the same play_count and the same max(seq), and one play
  -- would either overwrite the other or push the count past 31 unnoticed.
  select g.id, g.table_id, g.status, g.phase, g.players,
         g.current_player, g.play_count, g.play_segment
  into v_game
  from public.games g
  where g.id = p_game_id
  for update;

  if not found then
    raise exception 'Game not found.';
  end if;

  -- Guard 2: the game must still be live.
  if v_game.status <> 'active' then
    raise exception 'This game is no longer active.';
  end if;

  -- Guard 3: and actually in the play phase.
  if v_game.phase <> 'play' then
    raise exception 'This game is not in the play phase.';
  end if;

  -- Guard 4 (membership): the caller must be sitting at this table, and be one
  -- of the players this game was dealt to.
  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = v_game.table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not a member of this table.';
  end if;

  if v_game.players is null or not (v_caller = any(v_game.players)) then
    raise exception 'You are not a player in this game.';
  end if;

  -- Guard 5 (turn enforcement): playing out of turn must be impossible
  -- server-side, not merely hidden in the UI.
  if v_game.current_player is distinct from v_caller then
    raise exception 'It is not your turn.';
  end if;

  -- Guard 6 (anti-cheat, two parts). game_hands.cards is now IMMUTABLE for the
  -- rest of the hand -- it is the four cards that get counted later -- so
  -- "still holding it" is "in my hand AND not already in the play log". The
  -- discard phase was the last thing allowed to rewrite that array.
  select gh.cards
  into v_hand
  from public.game_hands gh
  where gh.game_id = p_game_id
    and gh.user_id = v_caller;

  if v_hand is null then
    raise exception 'You do not have a hand in this game.';
  end if;

  if not (p_card = any(v_hand)) then
    raise exception 'You can only play cards from your own hand.';
  end if;

  if exists (
    select 1
    from public.game_plays gp
    where gp.game_id = p_game_id
      and gp.user_id = v_caller
      and gp.kind = 'play'
      and gp.card = p_card
  ) then
    raise exception 'You have already played that card.';
  end if;

  -- Guard 7: the count may never pass 31.
  v_value := public.card_play_value(p_card);
  v_count := v_game.play_count + v_value;

  if v_count > 31 then
    raise exception 'That card would take the count to %, past the limit of 31.', v_count;
  end if;

  v_segment := v_game.play_segment;

  v_opponent := (
    select u from unnest(v_game.players) as u where u <> v_caller limit 1
  );

  -- Record the card. seq is safe to compute this way because every writer to
  -- game_plays for this game passes through the lock taken above.
  select coalesce(max(gp.seq), 0) + 1
  into v_seq
  from public.game_plays gp
  where gp.game_id = p_game_id;

  insert into public.game_plays (game_id, seq, segment, user_id, kind, card, count_after)
  values (p_game_id, v_seq, v_segment, v_caller, 'play', p_card, v_count);

  -- ===== (B) CHANGED FROM SLICE 7 (start) =====
  -- Score the segment, now that the new card is in it. Filtered to THIS
  -- segment, so cards from a previous run to 31 can never contribute.
  -- v_segment is still the pre-resolve value here, which is the segment the
  -- card was actually played into.
  select array_agg(gp.card order by gp.seq)
  into v_segment_cards
  from public.game_plays gp
  where gp.game_id = p_game_id
    and gp.segment = v_segment
    and gp.kind = 'play';

  v_peg := public.score_pegging(v_segment_cards);
  v_points := (v_peg ->> 'points')::int;
  v_reason := v_peg ->> 'reason';
  -- ===== (B) CHANGED FROM SLICE 7 (end) =====

  -- -------------------------------------------------------------------------
  -- Resolve what happens next, in this same transaction.
  --
  -- No loop is needed, because a reset drops the count to 0 and every card is
  -- playable onto 0 -- so after a reset the only question left is who still
  -- holds cards.
  -- -------------------------------------------------------------------------

  if v_count = 31 then
    -- Exactly 31 ends the segment immediately. Nobody declares a go.
    -- ===== (C) CHANGED FROM SLICE 7 (start) -- comment only, no logic =====
    -- Slice 7 said "(The 2 points for hitting 31 belong to the scoring
    -- slice.)" -- they are now counted in (B) above, and they REPLACE the
    -- last-card point rather than stacking with it.
    -- ===== (C) CHANGED FROM SLICE 7 (end) =====
    v_leader := v_opponent;
    v_count := 0;
    v_segment := v_segment + 1;

  elsif public.has_legal_play(p_game_id, v_opponent, v_count) then
    -- Normal case: the turn simply passes.
    v_leader := v_opponent;

  else
    -- The opponent cannot play. Record a go -- but ONLY if they still hold
    -- cards. A player who has run out has nothing to "go" on, and logging one
    -- would put a phantom event in the history at the end of every hand.
    if public.has_legal_play(p_game_id, v_opponent, 0) then
      v_seq := v_seq + 1;
      insert into public.game_plays (game_id, seq, segment, user_id, kind, card, count_after)
      values (p_game_id, v_seq, v_segment, v_opponent, 'go', null, v_count);
    end if;

    if public.has_legal_play(p_game_id, v_caller, v_count) then
      -- After a go, the same player keeps playing. This is exactly why
      -- current_player cannot be derived as "last player's opponent".
      v_leader := v_caller;
    else
      -- THE DEADLOCK CASE: neither player can legally play, but the count is
      -- under 31. Nothing in "alternate turns" resolves this -- without an
      -- automatic reset here, play would stall with no legal action available
      -- to anybody. The segment ends and the player who did NOT play the last
      -- card leads the next one.
      -- ===== (D) CHANGED FROM SLICE 7 (start) =====
      -- Slice 7's "(The 1 point for the go belongs to the scoring slice.)"
      -- note is removed -- it is awarded below.
      -- ===== (D) CHANGED FROM SLICE 7 (end, resumes after the 3 unchanged
      -- assignments) =====
      v_leader := v_opponent;
      v_count := 0;
      v_segment := v_segment + 1;

      -- ===== (D) CHANGED FROM SLICE 7 (start, continued) =====
      -- The go point goes to v_caller -- the player who played the LAST card
      -- of the segment. Note that is NOT the player whose go event was just
      -- logged above; in a deadlock exactly one go event exists and it belongs
      -- to the other player. Attribution is from control flow ("I just played
      -- and the segment is closing"), never from reading the go event's user.
      v_go_point := true;
      -- ===== (D) CHANGED FROM SLICE 7 (end) =====
    end if;
  end if;

  -- Whoever is meant to lead may be out of cards; fall through to the other.
  -- If neither holds anything, all eight cards are down and the hand is over.
  if not public.has_legal_play(p_game_id, v_leader, 0) then
    if public.has_legal_play(
         p_game_id,
         (select u from unnest(v_game.players) as u where u <> v_leader limit 1),
         0
       ) then
      v_leader := (select u from unnest(v_game.players) as u where u <> v_leader limit 1);
    else
      -- ===== (E) CHANGED FROM SLICE 7 (start) =====
      -- Slice 7 updated games to 'counting' and RETURNED right here. That
      -- early return is replaced by a flag, because award_points must fire on
      -- this path too -- a final card that closes the hand still scores, and
      -- this is also the moment "go" becomes "last card".
      v_phase_over := true;
      -- ===== (E) CHANGED FROM SLICE 7 (end) =====
    end if;
  end if;

  -- ===== (F) CHANGED FROM SLICE 7 (start) =====
  if v_phase_over then
    update public.games
    set phase = 'counting',
        -- ===== (H) CHANGED FROM BATCH 1 (start) =====
        -- The pone counts first. Batch 1 set null here; confirm_count's turn
        -- guard needs a real player.
        current_player = (
          select u
          from unnest(games.players) as u
          where u is distinct from games.dealer_id
          limit 1
        ),
        -- ===== (H) CHANGED FROM BATCH 1 (end) =====
        play_count = v_count,
        play_segment = v_segment
    where id = p_game_id;
  else
    update public.games
    set current_player = v_leader,
        play_count = v_count,
        play_segment = v_segment
    where id = p_game_id;
  end if;

  -- THE SINGLE AWARD, last of all -- because only here are both the go point
  -- and whether the hand just ended known.
  --
  -- One call, not one per scoring type: award_points overwrites
  -- last_points/last_reason, so several calls would leave the score tracker
  -- flashing only the final component. A 6-point play reading "+2 - pair"
  -- would be actively wrong.
  if v_go_point then
    v_points := v_points + 1;
    -- Same point, different word depending on whether anything follows.
    v_reason := case
      when v_reason = '' then (case when v_phase_over then 'last card' else 'go' end)
      else v_reason || ' + ' || (case when v_phase_over then 'last card' else 'go' end)
    end;
  end if;

  -- Skipped entirely at zero, so a scoreless play does not flash "+0".
  if v_points > 0 then
    perform public.award_points(v_game.table_id, v_caller, v_points, v_reason);
  end if;
  -- ===== (F) CHANGED FROM SLICE 7 (end) =====
end;
$old_body$;
  grant execute on function public.play_card_old(uuid, text) to authenticated;

  -- ---- The tables and games -------------------------------------------------
  -- 2 players: A creates both twins; A and B sit; A taps New Game on each.
  -- (Each game is then set by the owner per scripted hand.)
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  insert into public.tables (code, created_by) values (v_codes[1], v_a) returning id into v_t2;
  insert into public.tables (code, created_by) values (v_codes[2], v_a) returning id into v_t2o;
  foreach v_player in array array[v_a, v_b] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    insert into public.table_members (table_id, user_id) values (v_t2, v_player) on conflict (table_id, user_id) do nothing;
    insert into public.table_members (table_id, user_id) values (v_t2o, v_player) on conflict (table_id, user_id) do nothing;
  end loop;
  v_g2 := public.start_game_with_deal(v_t2);
  v_g2o := public.start_game_with_deal(v_t2o);

  -- 3 players: A creates; A, B, C sit (join order A, B, C).
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  insert into public.tables (code, created_by, max_players) values (v_codes[3], v_a, 3) returning id into v_t3;
  foreach v_player in array array[v_a, v_b, v_c] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    insert into public.table_members (table_id, user_id) values (v_t3, v_player) on conflict (table_id, user_id) do nothing;
  end loop;

  -- 4 players (Teams): A creates; A, B, C, D sit.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  insert into public.tables (code, created_by, max_players, team_mode) values (v_codes[4], v_a, 4, 'teams') returning id into v_t4;
  foreach v_player in array array[v_a, v_b, v_c, v_d] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    insert into public.table_members (table_id, user_id) values (v_t4, v_player) on conflict (table_id, user_id) do nothing;
  end loop;
  execute 'reset role';

  -- The 3-player SEAT order differs from the join order: join A, B, C
  -- (explicit times), then A, the host, swaps C into seat 2 -- A 1, C 2, B 3.
  update public.table_members set joined_at = now() - interval '30 minutes' where table_id = v_t3 and user_id = v_a;
  update public.table_members set joined_at = now() - interval '20 minutes' where table_id = v_t3 and user_id = v_b;
  update public.table_members set joined_at = now() - interval '10 minutes' where table_id = v_t3 and user_id = v_c;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  perform public.set_seat(v_t3, v_c, 2);

  -- Both hosts start: the first game at each table cuts for deal.
  v_g3 := public.start_game_with_deal(v_t3);
  v_g4 := public.start_game_with_deal(v_t4);
  execute 'reset role';

  -- The cuts, set to known cards: A deals at the 3-player table, D at the
  -- 4-player one. Every player acknowledges; the last acknowledgement deals.
  update public.games
  set deal_cut = jsonb_build_array(jsonb_build_array(
        jsonb_build_object('user_id', v_a, 'card', 'AH'),
        jsonb_build_object('user_id', v_c, 'card', '9H'),
        jsonb_build_object('user_id', v_b, 'card', 'KH'))),
      dealer_id = v_a, deal_cut_ack_by = '{}'
  where id = v_g3;
  update public.games
  set deal_cut = jsonb_build_array(jsonb_build_array(
        jsonb_build_object('user_id', v_a, 'card', '9S'),
        jsonb_build_object('user_id', v_b, 'card', 'QS'),
        jsonb_build_object('user_id', v_c, 'card', '4S'),
        jsonb_build_object('user_id', v_d, 'card', 'AS'))),
      dealer_id = v_d, deal_cut_ack_by = '{}'
  where id = v_g4;
  execute 'set local role authenticated';
  foreach v_player in array array[v_a, v_c, v_b] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    perform public.acknowledge_deal_cut(v_g3);
  end loop;
  foreach v_player in array array[v_a, v_b, v_c, v_d] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_player::text, true);
    perform public.acknowledge_deal_cut(v_g4);
  end loop;
  execute 'reset role';

  -- Every player discards one card for real (each one's first card, read
  -- as the owner).
  foreach v_g in array array[v_g3, v_g4] loop
    select players into v_pl from public.games where id = v_g;
    foreach v_player in array v_pl loop
      select cards[1] into v_card from public.game_hands where game_id = v_g and user_id = v_player;
      execute 'set local role authenticated';
      perform set_config('request.jwt.claims', json_build_object('sub', v_player, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', v_player::text, true);
      perform public.discard_to_crib(v_g, array[v_card]);
      execute 'reset role';
    end loop;
  end loop;

  -- [T0] The 3-player game E2 hands over: the play phase, the players in
  -- SEAT order (A, C, B), the count at 0, and the dealer's left (C) to lead.
  select phase, players, current_player, play_count, play_segment into v_rec from public.games where id = v_g3;
  if v_rec.phase is distinct from 'play' or v_rec.players is distinct from array[v_a, v_c, v_b]
     or v_rec.current_player is distinct from v_c or v_rec.play_count <> 0 or v_rec.play_segment <> 0 then
    raise exception 'FAIL [T0] the 3-player play phase: % / players % / lead % / count % / segment %; expected play / {A,C,B} / C / 0 / 0.',
      v_rec.phase, v_rec.players, v_names ->> v_rec.current_player::text, v_rec.play_count, v_rec.play_segment;
  end if;
  v_checks := v_checks + 1;

  -- [F0] The 4-player game: the dealer sits in seat 4, so the lead WRAPS to
  -- seat 1 (A).
  select phase, players, current_player into v_rec from public.games where id = v_g4;
  if v_rec.phase is distinct from 'play' or v_rec.players is distinct from array[v_a, v_b, v_c, v_d]
     or v_rec.current_player is distinct from v_a then
    raise exception 'FAIL [F0] the 4-player play phase: % / players % / lead %; expected play / {A,B,C,D} / A.',
      v_rec.phase, v_rec.players, v_names ->> v_rec.current_player::text;
  end if;
  v_checks := v_checks + 1;

  v_games := jsonb_build_object('g2', v_g2, 'g2o', v_g2o, 'g3', v_g3, 'g4', v_g4);

  -- ==== R, D, T, F: the scripted hands =========================================
  -- One element per hand: id, game, mode ('expect': compare the whole hand
  -- with expect; 'diff': play it through play_card on g2 and play_card_old on
  -- g2o, comparing after every card), dealer, starting scores, hands, script;
  -- for 'diff', "refused" (the refusals the script must meet, none if absent);
  -- "win" marks the three hands that end in a 121 win.
  v_scenarios := '[
    {"id":"D1","game":"g2","mode":"diff","what":"alternation, a pair, a run, a go, a 31, the last card","dealer":"B","scores":{},"hands":{"A":["5H","6H","2H","3H"],"B":["5C","4C","7C","2C"]},"script":["5H","5C","6H","4C","2H","7C","2C","3H"]},
    {"id":"D2","game":"g2","mode":"diff","what":"a deadlock mid-hand (go point, the other player leads), a deadlock with cards left, the last card","dealer":"A","scores":{},"hands":{"A":["KH","5H","6H","4H"],"B":["KS","QS","9S","8S"]},"script":["KS","KH","QS","5H","9S","6H","8S","4H"]},
    {"id":"D3","game":"g2","mode":"diff","what":"repeated go rows while the opponent stays stuck; the opponent out of cards (no go row)","dealer":"A","scores":{},"hands":{"A":["KH","QH","JH","TH"],"B":["AS","2S","3S","4S"]},"script":["AS","KH","2S","QH","3S","4S","JH","TH"]},
    {"id":"D4","game":"g2","mode":"diff","what":"the hand ending on a 31 (no last-card point)","dealer":"B","scores":{},"hands":{"A":["KS","QS","JS","2S"],"B":["9D","8D","7D","6D"]},"script":["KS","9D","QS","2S","8D","JS","7D","6D"]},
    {"id":"D5","game":"g2","mode":"diff","what":"fifteens and a pair royal","dealer":"B","scores":{},"hands":{"A":["7S","7H","AS","4C"],"B":["8D","7D","KC","3C"]},"script":["7S","8D","7H","7D","AS","KC","4C","3C"]},
    {"id":"D6","game":"g2","mode":"diff","what":"runs of 3 and 5 across both players","dealer":"A","scores":{},"hands":{"A":["4C","6C","9C","TC"],"B":["3D","5D","7D","8D"]},"script":["3D","4C","5D","6C","7D","9C","8D","TC"]},
    {"id":"D7","game":"g2","mode":"diff","what":"a double pair royal","dealer":"B","scores":{},"hands":{"A":["5S","5D","KS","QS"],"B":["5H","5C","KD","QD"]},"script":["5S","5H","5D","5C","KS","KD","QS","QD"]},
    {"id":"D8","game":"g2","mode":"diff","what":"low cards, one long segment","dealer":"A","scores":{},"hands":{"A":["AH","2H","3H","4H"],"B":["AD","2D","3D","4D"]},"script":["AD","AH","2D","2H","3D","3H","4D","4H"]},
    {"id":"D9","game":"g2","mode":"diff","what":"a go, the caller plays twice to a 31, then a deadlock","dealer":"B","scores":{},"hands":{"A":["TS","KS","AS","5S"],"B":["KD","QD","9D","8D"]},"script":["TS","KD","KS","AS","QD","5S","9D","8D"]},
    {"id":"D10","game":"g2","mode":"diff","what":"a 121 win mid-pegging, then a refused play","dealer":"B","scores":{"B":119},"hands":{"A":["5H","9C","QS","KH"],"B":["5S","3D","8C","2C"]},"script":["5H","5S","9C"],"refused":"9C@A:This game is no longer active.","win":true},
    {"id":"D11","game":"g2","mode":"diff","what":"OWNER-SET uneven hands (A 1 card, B 4): a 31 with the opponent out of cards, so the caller leads","dealer":"B","scores":{},"hands":{"A":["TS"],"B":["QD","JD","AD","5D"]},"script":["TS","QD","JD","AD","5D"]},
    {"id":"D12","game":"g2","mode":"diff","what":"OWNER-SET short hand: a deadlock with the opponent out of cards, so the caller leads","dealer":"B","scores":{},"hands":{"A":["KS","QS"],"B":["KD","QD","JD","3D"]},"script":["KS","KD","QS","QD","JD","3D"]},
    {"id":"R1","game":"g2","mode":"expect","what":"alternation, a pair, a run, a go, a 31, the last card","dealer":"B","scores":{},"hands":{"A":["5H","6H","2H","3H"],"B":["5C","4C","7C","2C"]},"script":["5H","5C","6H","4C","2H","7C","2C","3H"],"expect":{"log":"1:0:A:play:5H:5|2:0:B:play:5C:10|3:0:A:play:6H:16|4:0:B:play:4C:20|5:0:A:play:2H:22|6:0:B:play:7C:29|7:0:A:go::29|8:0:B:play:2C:31|9:1:A:play:3H:3","state":"counting/A/0/2/0/active/-","scores":"A=1/1/last card,B=7/2/thirty-one","errors":""}},
    {"id":"R2","game":"g2","mode":"expect","what":"a deadlock mid-hand (go point, the other player leads), a deadlock with cards left, the last card","dealer":"A","scores":{},"hands":{"A":["KH","5H","6H","4H"],"B":["KS","QS","9S","8S"]},"script":["KS","KH","QS","5H","9S","6H","8S","4H"],"expect":{"log":"1:0:B:play:KS:10|2:0:A:play:KH:20|3:0:B:play:QS:30|4:0:A:go::30|5:1:A:play:5H:5|6:1:B:play:9S:14|7:1:A:play:6H:20|8:1:B:play:8S:28|9:1:A:go::28|10:2:A:play:4H:4","state":"counting/B/0/3/0/active/-","scores":"A=3/1/last card,B=2/1/go","errors":""}},
    {"id":"R3","game":"g2","mode":"expect","what":"repeated go rows while the opponent stays stuck; the opponent out of cards (no go row)","dealer":"A","scores":{},"hands":{"A":["KH","QH","JH","TH"],"B":["AS","2S","3S","4S"]},"script":["AS","KH","2S","QH","3S","4S","JH","TH"],"expect":{"log":"1:0:B:play:AS:1|2:0:A:play:KH:11|3:0:B:play:2S:13|4:0:A:play:QH:23|5:0:B:play:3S:26|6:0:A:go::26|7:0:B:play:4S:30|8:0:A:go::30|9:1:A:play:JH:10|10:1:A:play:TH:20","state":"counting/B/0/2/0/active/-","scores":"A=1/1/last card,B=1/1/go","errors":""}},
    {"id":"R4","game":"g2","mode":"expect","what":"the hand ending on a 31 (no last-card point)","dealer":"B","scores":{},"hands":{"A":["KS","QS","JS","2S"],"B":["9D","8D","7D","6D"]},"script":["KS","9D","QS","2S","8D","JS","7D","6D"],"expect":{"log":"1:0:A:play:KS:10|2:0:B:play:9D:19|3:0:A:play:QS:29|4:0:B:go::29|5:0:A:play:2S:31|6:1:B:play:8D:8|7:1:A:play:JS:18|8:1:B:play:7D:25|9:1:B:play:6D:31","state":"counting/A/0/2/0/active/-","scores":"A=2/2/thirty-one,B=2/2/thirty-one","errors":""}},
    {"id":"R5","game":"g2","mode":"expect","what":"fifteens and a pair royal","dealer":"B","scores":{},"hands":{"A":["7S","7H","AS","4C"],"B":["8D","7D","KC","3C"]},"script":["7S","8D","7H","7D","AS","KC","4C","3C"],"expect":{"log":"1:0:A:play:7S:7|2:0:B:play:8D:15|3:0:A:play:7H:22|4:0:B:play:7D:29|5:0:A:play:AS:30|6:0:B:go::30|7:1:B:play:KC:10|8:1:A:play:4C:14|9:1:B:play:3C:17","state":"counting/A/0/2/0/active/-","scores":"A=1/1/go,B=5/1/last card","errors":""}},
    {"id":"R6","game":"g2","mode":"expect","what":"OWNER-SET uneven hands (A 1 card, B 4): a 31 with the opponent out of cards, so the caller leads","dealer":"B","scores":{},"hands":{"A":["TS"],"B":["QD","JD","AD","5D"]},"script":["TS","QD","JD","AD","5D"],"expect":{"log":"1:0:A:play:TS:10|2:0:B:play:QD:20|3:0:B:play:JD:30|4:0:B:play:AD:31|5:1:B:play:5D:5","state":"counting/A/0/2/0/active/-","scores":"A=0//,B=6/1/last card","errors":""}},
    {"id":"R7","game":"g2","mode":"expect","what":"a 121 win mid-pegging, then a refused play","dealer":"B","scores":{"B":119},"hands":{"A":["5H","9C","QS","KH"],"B":["5S","3D","8C","2C"]},"script":["5H","5S","9C"],"win":true,"expect":{"log":"1:0:A:play:5H:5|2:0:B:play:5S:10","state":"play/A/10/0/0/ended/B","scores":"A=0//,B=121/2/pair","errors":"9C@A:This game is no longer active."}},
    {"id":"T1","game":"g3","mode":"expect","what":"clockwise by seat; a 31 by the middle seat, the next seat leads; two players stuck and nobody can play (go point, the next seat leads); a run completed across three players; 12 cards, the last card; the dealer''s left counts first","dealer":"A","scores":{},"hands":{"C":["9S","TS","2S","3S"],"B":["8H","KH","AH","4H"],"A":["4D","QD","6D","5D"]},"script":["9S","8H","4D","TS","KH","QD","2S","AH","6D","3S","4H","5D"],"expect":{"log":"1:0:C:play:9S:9|2:0:B:play:8H:17|3:0:A:play:4D:21|4:0:C:play:TS:31|5:1:B:play:KH:10|6:1:A:play:QD:20|7:1:C:play:2S:22|8:1:B:play:AH:23|9:1:A:play:6D:29|10:1:C:go::29|11:1:B:go::29|12:2:C:play:3S:3|13:2:B:play:4H:7|14:2:A:play:5D:12","state":"counting/C/0/3/0/active/-","scores":"A=5/4/run of 3 + last card,B=0//,C=2/2/thirty-one","errors":""}},
    {"id":"T2","game":"g3","mode":"expect","what":"a go that skips one player while the next plays; two players stuck while the last plays on (repeated go rows); a player out of cards early, then skipped silently","dealer":"A","scores":{},"hands":{"C":["KS","QS","JS","TS"],"B":["2H","3H","AH","AC"],"A":["KD","8D","QD","9D"]},"script":["KS","2H","KD","3H","AH","AC","8D","QS","QD","JS","9D","TS"],"expect":{"log":"1:0:C:play:KS:10|2:0:B:play:2H:12|3:0:A:play:KD:22|4:0:C:go::22|5:0:B:play:3H:25|6:0:A:go::25|7:0:C:go::25|8:0:B:play:AH:26|9:0:A:go::26|10:0:C:go::26|11:0:B:play:AC:27|12:0:A:go::27|13:0:C:go::27|14:1:A:play:8D:8|15:1:C:play:QS:18|16:1:A:play:QD:28|17:1:C:go::28|18:2:C:play:JS:10|19:2:A:play:9D:19|20:2:C:play:TS:29","state":"counting/C/0/3/0/active/-","scores":"A=3/3/pair + go,B=3/3/pair + go,C=4/4/run of 3 + last card","errors":""}},
    {"id":"T3","game":"g3","mode":"expect","what":"after a deadlock the next seat is out of cards: the lead skips it","dealer":"A","scores":{},"hands":{"A":["7H","QH","8D","4S"],"C":["9H","AS","8H","4C"],"B":["2H","AC","AH","JS"]},"script":["AS","JS","8D","9H","AC","AH","7H","4C","2H","4S","8H","QH"],"expect":{"log":"1:0:C:play:AS:1|2:0:B:play:JS:11|3:0:A:play:8D:19|4:0:C:play:9H:28|5:0:B:play:AC:29|6:0:A:go::29|7:0:C:go::29|8:0:B:play:AH:30|9:0:A:go::30|10:0:C:go::30|11:1:A:play:7H:7|12:1:C:play:4C:11|13:1:B:play:2H:13|14:1:A:play:4S:17|15:1:C:play:8H:25|16:1:A:go::25|17:2:A:play:QH:10","state":"counting/C/0/3/0/active/-","scores":"A=1/1/last card,B=3/3/pair + go,C=1/1/go","errors":""}},
    {"id":"F1","game":"g4","mode":"expect","what":"16 cards; the lead wraps from seat 4 to seat 1; a go that skips the caller''s partner; a deadlock; a 31; a player out early and skipped as the lead; a fifteen; the last card","dealer":"D","scores":{},"hands":{"A":["AS","5D","TC","KS"],"B":["6C","JS","JD","7S"],"C":["9H","9D","5C","QC"],"D":["KD","AC","7C","2S"]},"script":["TC","6C","9H","2S","AS","AC","KS","7S","9D","5D","JD","QC","7C","JS","5C","KD"],"expect":{"log":"1:0:A:play:TC:10|2:0:B:play:6C:16|3:0:C:play:9H:25|4:0:D:play:2S:27|5:0:A:play:AS:28|6:0:B:go::28|7:0:C:go::28|8:0:D:play:AC:29|9:0:A:go::29|10:0:B:go::29|11:0:C:go::29|12:1:A:play:KS:10|13:1:B:play:7S:17|14:1:C:play:9D:26|15:1:D:go::26|16:1:A:play:5D:31|17:2:B:play:JD:10|18:2:C:play:QC:20|19:2:D:play:7C:27|20:2:B:go::27|21:2:C:go::27|22:3:B:play:JS:10|23:3:C:play:5C:15|24:3:D:play:KD:25","state":"counting/A/0/4/0/active/-","scores":"A=2/2/thirty-one,B=0//,C=2/2/fifteen,D=5/1/last card","errors":""}},
    {"id":"F2","game":"g4","mode":"expect","what":"a pegging 121 by a non-dealer ends the match; the next play is refused","dealer":"D","scores":{"B":119},"hands":{"A":["5H","9C","QS","KH"],"B":["5S","3D","8C","2C"],"C":["4H","6C","7S","8S"],"D":["AH","2H","3H","4D"]},"script":["5H","5S","9C"],"win":true,"expect":{"log":"1:0:A:play:5H:5|2:0:B:play:5S:10","state":"play/C/10/0/0/ended/B","scores":"A=0//,B=121/2/pair,C=0//,D=0//","errors":"9C@C:This game is no longer active."}}
  ]'::jsonb;

  for v_sc in select value from jsonb_array_elements(v_scenarios) loop
    v_gid := (v_games ->> (v_sc ->> 'game'))::uuid;
    v_twin := case when v_sc ->> 'mode' = 'diff' then v_g2o end;

    -- Set the hand, as the owner: the play log cleared, the dealer, the
    -- dealer's left to lead, the count at 0, the known cards, the scores.
    foreach v_g in array array_remove(array[v_gid, v_twin], null) loop
      delete from public.game_plays where game_id = v_g;
      select players into v_pl from public.games where id = v_g;
      v_dealer := (v_letters ->> (v_sc ->> 'dealer'))::uuid;
      update public.games
      set status = 'active', ended_reason = null, winner_id = null, win_claim_by = null,
          phase = 'play', dealer_id = v_dealer,
          current_player = v_pl[(array_position(v_pl, v_dealer) % array_length(v_pl, 1)) + 1],
          play_count = 0, play_segment = 0, count_step = 0,
          revealed_by = '{}', crib_revealed = false, ready_by = '{}'
      where id = v_g;
      for v_key, v_val in select key, value from jsonb_each(v_sc -> 'hands') loop
        insert into public.game_hands (game_id, user_id, cards)
        values (v_g, (v_letters ->> v_key)::uuid, array(select jsonb_array_elements_text(v_val)))
        on conflict (game_id, user_id) do update set cards = excluded.cards;
      end loop;
      update public.table_members tm
      set score = coalesce((v_sc -> 'scores' ->> (v_names ->> tm.user_id::text))::int, 0),
          last_points = null, last_reason = null, last_awarded_at = null
      where tm.table_id = (select table_id from public.games where id = v_g);
    end loop;

    -- Play the script: each card by whoever's turn it is, as that player.
    v_err := '';
    v_err2 := '';
    v_step := 0;
    for v_card in select value from jsonb_array_elements_text(v_sc -> 'script') loop
      v_step := v_step + 1;

      select current_player into v_who from public.games where id = v_gid;
      execute 'set local role authenticated';
      perform set_config('request.jwt.claims', json_build_object('sub', v_who, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', v_who::text, true);
      begin
        perform public.play_card(v_gid, v_card);
      exception when others then
        v_err := v_err || case when v_err = '' then '' else '|' end || v_card || '@' || (v_names ->> v_who::text) || ':' || sqlerrm;
      end;
      execute 'reset role';

      if v_twin is not null then
        select current_player into v_who from public.games where id = v_twin;
        execute 'set local role authenticated';
        perform set_config('request.jwt.claims', json_build_object('sub', v_who, 'role', 'authenticated')::text, true);
        perform set_config('request.jwt.claim.sub', v_who::text, true);
        begin
          perform public.play_card_old(v_twin, v_card);
        exception when others then
          v_err2 := v_err2 || case when v_err2 = '' then '' else '|' end || v_card || '@' || (v_names ->> v_who::text) || ':' || sqlerrm;
        end;
        execute 'reset role';

        -- After EVERY card: the two games must be identical.
        select coalesce(string_agg(gp.seq || ':' || gp.segment || ':' || (v_names ->> gp.user_id::text) || ':' || gp.kind || ':' || coalesce(gp.card, '') || ':' || gp.count_after, '|' order by gp.seq), '')
        into v_log from public.game_plays gp where gp.game_id = v_gid;
        select coalesce(string_agg(gp.seq || ':' || gp.segment || ':' || (v_names ->> gp.user_id::text) || ':' || gp.kind || ':' || coalesce(gp.card, '') || ':' || gp.count_after, '|' order by gp.seq), '')
        into v_log2 from public.game_plays gp where gp.game_id = v_twin;
        select g.phase || '/' || coalesce(v_names ->> g.current_player::text, '-') || '/' || g.play_count || '/' || g.play_segment || '/' || g.count_step || '/' || g.status || '/' || coalesce(v_names ->> g.winner_id::text, '-')
        into v_state from public.games g where g.id = v_gid;
        select g.phase || '/' || coalesce(v_names ->> g.current_player::text, '-') || '/' || g.play_count || '/' || g.play_segment || '/' || g.count_step || '/' || g.status || '/' || coalesce(v_names ->> g.winner_id::text, '-')
        into v_state2 from public.games g where g.id = v_twin;
        select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score || '/' || coalesce(tm.last_points::text, '') || '/' || coalesce(tm.last_reason, ''), ',' order by v_names ->> tm.user_id::text)
        into v_scores from public.table_members tm join public.games g on g.table_id = tm.table_id
        where g.id = v_gid and tm.user_id = any(g.players);
        select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score || '/' || coalesce(tm.last_points::text, '') || '/' || coalesce(tm.last_reason, ''), ',' order by v_names ->> tm.user_id::text)
        into v_scores2 from public.table_members tm join public.games g on g.table_id = tm.table_id
        where g.id = v_twin and tm.user_id = any(g.players);

        if v_log is distinct from v_log2 or v_state is distinct from v_state2
           or v_scores is distinct from v_scores2 or v_err is distinct from v_err2 then
          raise exception 'FAIL [%] (%): the new and the old play_card differ after card % (%). NEW log % / state % / scores % / refused % -- OLD log % / state % / scores % / refused %.',
            v_sc ->> 'id', v_sc ->> 'what', v_step, v_card, v_log, v_state, v_scores, v_err, v_log2, v_state2, v_scores2, v_err2;
        end if;
      end if;
    end loop;

    -- 'expect': the whole hand against what the rules say it must produce.
    if v_sc ->> 'mode' = 'expect' then
      select coalesce(string_agg(gp.seq || ':' || gp.segment || ':' || (v_names ->> gp.user_id::text) || ':' || gp.kind || ':' || coalesce(gp.card, '') || ':' || gp.count_after, '|' order by gp.seq), '')
      into v_log from public.game_plays gp where gp.game_id = v_gid;
      select g.phase || '/' || coalesce(v_names ->> g.current_player::text, '-') || '/' || g.play_count || '/' || g.play_segment || '/' || g.count_step || '/' || g.status || '/' || coalesce(v_names ->> g.winner_id::text, '-')
      into v_state from public.games g where g.id = v_gid;
      select string_agg((v_names ->> tm.user_id::text) || '=' || tm.score || '/' || coalesce(tm.last_points::text, '') || '/' || coalesce(tm.last_reason, ''), ',' order by v_names ->> tm.user_id::text)
      into v_scores from public.table_members tm join public.games g on g.table_id = tm.table_id
      where g.id = v_gid and tm.user_id = any(g.players);

      if v_log is distinct from v_sc -> 'expect' ->> 'log' or v_state is distinct from v_sc -> 'expect' ->> 'state'
         or v_scores is distinct from v_sc -> 'expect' ->> 'scores' or v_err is distinct from v_sc -> 'expect' ->> 'errors' then
        raise exception 'FAIL [%] (%): log % / state % / scores % / refused % -- expected log % / state % / scores % / refused %.',
          v_sc ->> 'id', v_sc ->> 'what', v_log, v_state, v_scores, v_err,
          v_sc -> 'expect' ->> 'log', v_sc -> 'expect' ->> 'state', v_sc -> 'expect' ->> 'scores', v_sc -> 'expect' ->> 'errors';
      end if;
    end if;

    -- No scripted hand can pass vacuously. A mis-written script (a card
    -- played out of turn, or not held) would be refused by both versions
    -- alike, so: the refusals must be exactly the ones the scenario names
    -- (for 'expect', expect.errors above), and a hand that does not end in a
    -- win must be played to the end -- every card in the hands down, and
    -- the game at the count. Part of this scenario's check, not a new one.
    if v_sc ->> 'mode' = 'diff' then
      if v_err is distinct from coalesce(v_sc ->> 'refused', '') then
        raise exception 'FAIL [%] (%): play_card refused % (card@player:message) -- expected %.',
          v_sc ->> 'id', v_sc ->> 'what', coalesce(nullif(v_err, ''), 'nothing'), coalesce(nullif(v_sc ->> 'refused', ''), 'no refusal');
      end if;
      if v_err2 is distinct from coalesce(v_sc ->> 'refused', '') then
        raise exception 'FAIL [%] (%): play_card_old refused % (card@player:message) -- expected %.',
          v_sc ->> 'id', v_sc ->> 'what', coalesce(nullif(v_err2, ''), 'nothing'), coalesce(nullif(v_sc ->> 'refused', ''), 'no refusal');
      end if;
    end if;

    select count(*) into v_total
    from jsonb_each(v_sc -> 'hands') h, jsonb_array_elements(h.value) c;
    foreach v_g in array array_remove(array[v_gid, v_twin], null) loop
      select count(*) into v_n from public.game_plays gp where gp.game_id = v_g and gp.kind = 'play';
      select g.phase, g.status into v_rec from public.games g where g.id = v_g;
      if coalesce((v_sc ->> 'win')::boolean, false) then
        if v_rec.status is distinct from 'ended' then
          raise exception 'FAIL [%] (%): the hand should end in a win, but the game (%) is %.',
            v_sc ->> 'id', v_sc ->> 'what', case when v_g = v_twin then 'play_card_old' else 'play_card' end, v_rec.status;
        end if;
      elsif v_n <> v_total or v_rec.phase is distinct from 'counting' then
        raise exception 'FAIL [%] (%): the hand was not played to the end (%): % of % cards played, phase %.',
          v_sc ->> 'id', v_sc ->> 'what', case when v_g = v_twin then 'play_card_old' else 'play_card' end, v_n, v_total, v_rec.phase;
      end if;
    end loop;

    v_checks := v_checks + 1;
  end loop;

  -- ==== R (continued): the old 2-player refusals, word for word ===============
  -- g2 set to hand R1's cards (A leads: 5H 6H 2H 3H; B: 5C 4C 7C 2C).
  delete from public.game_plays where game_id = v_g2;
  update public.games
  set status = 'active', ended_reason = null, winner_id = null, win_claim_by = null,
      phase = 'play', dealer_id = v_b,
      current_player = v_a, play_count = 0, play_segment = 0, count_step = 0,
      revealed_by = '{}', crib_revealed = false, ready_by = '{}'
  where id = v_g2;
  -- The scores too, as the scripted-hand loop does: the hands above leave
  -- points behind (R7 leaves B at 121, so the next point would end the match).
  update public.table_members tm
  set score = 0, last_points = null, last_reason = null, last_awarded_at = null
  where tm.table_id = v_t2;
  update public.game_hands set cards = array['5H', '6H', '2H', '3H'] where game_id = v_g2 and user_id = v_a;
  update public.game_hands set cards = array['5C', '4C', '7C', '2C'] where game_id = v_g2 and user_id = v_b;

  -- [R8] B plays on A's turn.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.play_card(v_g2, '5C'); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'It is not your turn.' then
    raise exception 'FAIL [R8] playing out of turn: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [R9] A plays a card A doesn't hold.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin perform public.play_card(v_g2, '5C'); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'You can only play cards from your own hand.' then
    raise exception 'FAIL [R9] playing a card not held: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [R10] A plays 5H, B 5C; A plays 5H again.
  perform public.play_card(v_g2, '5H');
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  perform public.play_card(v_g2, '5C');
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin perform public.play_card(v_g2, '5H'); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'You have already played that card.' then
    raise exception 'FAIL [R10] playing a card twice: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [R11] At a count of 27 (set by the owner), A's 6H would make 33.
  execute 'reset role';
  update public.games set play_count = 27 where id = v_g2;
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.play_card(v_g2, '6H'); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'That card would take the count to 33, past the limit of 31.' then
    raise exception 'FAIL [R11] a play past 31: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- ==== P: play_card refusals with 3 players ==================================
  -- g3 set to hand T1's cards (dealer A; C leads: 9S TS 2S 3S; B: 8H KH AH
  -- 4H; A: 4D QD 6D 5D).
  delete from public.game_plays where game_id = v_g3;
  update public.games
  set status = 'active', ended_reason = null, winner_id = null, win_claim_by = null,
      phase = 'play', dealer_id = v_a,
      current_player = v_c, play_count = 0, play_segment = 0, count_step = 0,
      revealed_by = '{}', crib_revealed = false, ready_by = '{}'
  where id = v_g3;
  -- The scores too, as the scripted-hand loop does: the hands above leave
  -- points behind (T1-T3 here), and no leftover score may end the match.
  update public.table_members tm
  set score = 0, last_points = null, last_reason = null, last_awarded_at = null
  where tm.table_id = v_t3;
  update public.game_hands set cards = array['9S', 'TS', '2S', '3S'] where game_id = v_g3 and user_id = v_c;
  update public.game_hands set cards = array['8H', 'KH', 'AH', '4H'] where game_id = v_g3 and user_id = v_b;
  update public.game_hands set cards = array['4D', 'QD', '6D', '5D'] where game_id = v_g3 and user_id = v_a;

  -- [P1] B plays on C's turn.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.play_card(v_g3, '8H'); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'It is not your turn.' then
    raise exception 'FAIL [P1] a 3-player play out of turn: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P2] C plays a card C doesn't hold (A's).
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  v_msg := null;
  begin perform public.play_card(v_g3, '4D'); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'You can only play cards from your own hand.' then
    raise exception 'FAIL [P2] a 3-player play of a card not held: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P3] C 9S, B 8H, A 4D (clockwise); then C plays 9S again.
  perform public.play_card(v_g3, '9S');
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  perform public.play_card(v_g3, '8H');
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  perform public.play_card(v_g3, '4D');
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  v_msg := null;
  begin perform public.play_card(v_g3, '9S'); exception when others then v_msg := sqlerrm; end;
  if v_msg is distinct from 'You have already played that card.' then
    raise exception 'FAIL [P3] a 3-player card played twice: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P4] The count is 21: C's TS would make 31 (legal), but at 25 (set by
  -- the owner) it would make 35.
  execute 'reset role';
  update public.games set play_count = 25 where id = v_g3;
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.play_card(v_g3, 'TS'); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  update public.games set play_count = 21 where id = v_g3;
  if v_msg is distinct from 'That card would take the count to 35, past the limit of 31.' then
    raise exception 'FAIL [P4] a 3-player play past 31: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P5] E, not at the table: refused as a non-member.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_e, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_e::text, true);
  v_msg := null;
  begin perform public.play_card(v_g3, 'TS'); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'You are not a member of this table.' then
    raise exception 'FAIL [P5] a non-member playing: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P6] D, seated at the table but not one of this game's players (the
  -- owner makes room for a fourth seat): refused as a non-player.
  update public.tables set max_players = 4 where id = v_t3;
  insert into public.table_members (table_id, user_id) values (v_t3, v_d);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_d::text, true);
  v_msg := null;
  begin perform public.play_card(v_g3, 'TS'); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'You are not a player in this game.' then
    raise exception 'FAIL [P6] a seated non-player playing: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P7] Not in the play phase (set to counting by the owner): refused.
  update public.games set phase = 'counting' where id = v_g3;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  v_msg := null;
  begin perform public.play_card(v_g3, 'TS'); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  update public.games set phase = 'play' where id = v_g3;
  if v_msg is distinct from 'This game is not in the play phase.' then
    raise exception 'FAIL [P7] playing outside the play phase: %.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [P8] A second tab: C's TS makes 31 and is played; the very same call
  -- again is refused (it is B's lead now) and changes nothing.
  execute 'set local role authenticated';
  perform public.play_card(v_g3, 'TS');
  select count(*) into v_n from public.game_plays where game_id = v_g3;
  v_msg := null;
  begin perform public.play_card(v_g3, 'TS'); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  select current_player, play_count into v_rec from public.games where id = v_g3;
  if v_msg is distinct from 'It is not your turn.' or (select count(*) from public.game_plays where game_id = v_g3) <> v_n
     or v_rec.current_player is distinct from v_b or v_rec.play_count <> 0 then
    raise exception 'FAIL [P8] a repeated call: %, % play rows (were %), next %, count %; expected the turn refusal, nothing changed, B to lead at 0.',
      coalesce(v_msg, 'no error'), (select count(*) from public.game_plays where game_id = v_g3), v_n,
      v_names ->> v_rec.current_player::text, v_rec.play_count;
  end if;
  v_checks := v_checks + 1;

  raise exception 'ALL % CHECKS PASSED (rolled back). A=% B=%.', v_checks, v_a, v_b;
end $$;
