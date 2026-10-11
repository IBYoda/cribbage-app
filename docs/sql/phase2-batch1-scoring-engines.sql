-- Phase 2, Batch 1: the scoring engines
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- Three things:
--   1. Pegging scoring wired into play_card (fifteens, pairs, runs, go, 31)
--   2. His heels (dealer +2 when the starter is a jack), in discard_to_crib
--   3. score_hand() -- the pure hand/crib scorer. NO counting UI; that's Batch 2.
--
-- NO SCHEMA CHANGES. award_points(), game_plays, and the columns play_card and
-- discard_to_crib already read are all that's needed.
--
-- DELIBERATELY NOT HERE: win detection at 121. It belongs in award_points() in
-- Batch 2, where ending a match has somewhere to go.
--
-- GRANTS: schema public denies client execute on new functions by default
-- (Slice 6b), so score_pegging and score_hand are unreachable from the client
-- simply by not granting them -- which is what we want. play_card and
-- discard_to_crib keep their existing grants through "create or replace",
-- which preserves an ACL.


-- ---------------------------------------------------------------------------
-- 1. THE PEGGING SCORER. Pure: cards in, points and reason out.
--
-- Takes the cards played IN THE CURRENT SEGMENT, in play order, with the card
-- just played last. Cards from an earlier segment are not passed in and can
-- never contribute -- that filtering is the caller's job (play_card filters on
-- segment), which keeps this function trivially testable.
--
-- Does NOT handle the go / last-card point: that depends on whether the
-- segment is closing, which is control flow, not cards. play_card adds it.
--
-- RANKS, NOT PLAY VALUES, FOR RUNS. This is the distinction the project has
-- warned about since Slice 4, and it bites in both directions here:
--   J-Q-K IS a run (ranks 11,12,13) though all three are worth 10
--   10-J-Q is a run by rank, not because they share a value
--   three tens are a pair royal, never a run
--   Q-K-A does NOT wrap: ace is low, so ranks 12,13,1 do not span 2
-- ---------------------------------------------------------------------------
create or replace function public.score_pegging(p_segment_cards text[])
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_len int;
  v_total int := 0;
  v_points int := 0;
  v_reasons text[] := '{}';
  v_streak int;
  v_i int;
  v_last_rank int;
  v_run_len int;
  v_distinct int;
  v_min int;
  v_max int;
begin
  v_len := coalesce(array_length(p_segment_cards, 1), 0);

  if v_len = 0 then
    return jsonb_build_object('points', 0, 'reason', '');
  end if;

  -- The running count is just the sum of the segment, by PLAY value.
  select sum(public.card_play_value(c))
  into v_total
  from unnest(p_segment_cards) as c;

  -- array_append, NOT the || operator, at all four append sites below.
  -- "v_reasons || 'fifteen'" fails at runtime with "malformed array literal":
  -- a bare quoted literal is of type unknown, and with text[] on the left
  -- Postgres resolves || to array-concatenation, so it tries to PARSE
  -- 'fifteen' as an array. array_append(..., <expr>::text) is unambiguous.
  if v_total = 15 then
    v_points := v_points + 2;
    v_reasons := array_append(v_reasons, 'fifteen'::text);
  elsif v_total = 31 then
    v_points := v_points + 2;
    v_reasons := array_append(v_reasons, 'thirty-one'::text);
  end if;

  -- Pairs: how many cards at the END of the segment share the just-played
  -- rank. k consecutive equal ranks score k*(k-1): 2, 6, 12.
  v_last_rank := public.card_rank_value(p_segment_cards[v_len]);
  v_streak := 1;
  v_i := v_len - 1;
  while v_i >= 1 and public.card_rank_value(p_segment_cards[v_i]) = v_last_rank loop
    v_streak := v_streak + 1;
    v_i := v_i - 1;
  end loop;

  if v_streak >= 2 then
    v_points := v_points + v_streak * (v_streak - 1);
    v_reasons := array_append(v_reasons, (case v_streak
      when 2 then 'pair'
      when 3 then 'pair royal'
      else 'double pair royal'
    end)::text);
  end if;

  -- Runs: the LONGEST suffix of length >= 3 whose ranks are all distinct and
  -- span exactly (length - 1). Order within the suffix does not matter --
  -- 5,3,4 is a run -- but the cards must be contiguous at the end, so an
  -- intervening card that breaks the sequence also breaks the run.
  for v_run_len in reverse v_len .. 3 loop
    select count(distinct public.card_rank_value(c)),
           min(public.card_rank_value(c)),
           max(public.card_rank_value(c))
    into v_distinct, v_min, v_max
    from unnest(p_segment_cards[v_len - v_run_len + 1 : v_len]) as c;

    if v_distinct = v_run_len and v_max - v_min = v_run_len - 1 then
      v_points := v_points + v_run_len;
      -- The inner || is text || int, which is ordinary string concatenation,
      -- not the array operator. Only the OUTER append needed changing.
      v_reasons := array_append(v_reasons, ('run of ' || v_run_len)::text);
      exit;
    end if;
  end loop;

  return jsonb_build_object(
    'points', v_points,
    'reason', array_to_string(v_reasons, ' + ')
  );
end;
$$;

-- Internal. Intentionally no grant -- see the GRANTS note at the top.
revoke all on function public.score_pegging(text[]) from public;


-- ---------------------------------------------------------------------------
-- 2. THE HAND / CRIB SCORER. Pure: four cards plus the starter in, a points
-- total and a breakdown out.
--
-- p_is_crib changes exactly one rule -- the flush:
--   hand: all four hand cards same suit = 4, and 5 if the starter matches
--   crib: ONLY all five same suit scores, for 5. A four-card crib flush is
--         worth nothing at all.
--
-- Does NOT score "his heels" (starter is a jack). That is the DEALER's 2
-- points, scored at cut time in discard_to_crib below -- counting it here too
-- would double-award it, which is a classic cribbage-app bug.
-- ---------------------------------------------------------------------------
create or replace function public.score_hand(
  p_cards text[],
  p_starter text,
  p_is_crib boolean
)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_all text[];
  v_n int;
  v_fifteens int := 0;
  v_pairs int := 0;
  v_runs int := 0;
  v_flush int := 0;
  v_nobs int := 0;
  v_counts int[] := array_fill(0, array[13]);
  v_rank int;
  v_card text;
  v_run_len int := 0;
  v_run_mult int := 1;
  v_r int;
  v_hand_suits int;
begin
  if p_cards is null or p_starter is null then
    raise exception 'score_hand needs both a hand and a starter card.';
  end if;

  v_all := p_cards || p_starter;
  v_n := array_length(v_all, 1);

  -- Fifteens: every non-empty subset summing to exactly 15, 2 points each.
  -- Brute force over bitmasks -- with 5 cards that is 31 subsets.
  select coalesce(count(*), 0) * 2
  into v_fifteens
  from generate_series(1, (1 << v_n) - 1) as mask
  where (
    select sum(public.card_play_value(v_all[b]))
    from generate_series(1, v_n) as b
    where (mask >> (b - 1)) & 1 = 1
  ) = 15;

  -- Pairs: every unordered same-rank pair, 2 points each. Three of a kind is
  -- 3 pairs (6), four of a kind is 6 pairs (12) -- this falls out of counting
  -- combinations rather than needing special cases.
  select coalesce(count(*), 0) * 2
  into v_pairs
  from generate_series(1, v_n) as i
  join generate_series(1, v_n) as j on j > i
  where public.card_rank_value(v_all[i]) = public.card_rank_value(v_all[j]);

  -- Runs: find each maximal block of consecutive ranks present. A block of
  -- length >= 3 scores (length x product of the counts of its ranks), which is
  -- how double, triple and double-double runs arise without special-casing.
  foreach v_card in array v_all loop
    v_rank := public.card_rank_value(v_card);
    v_counts[v_rank] := v_counts[v_rank] + 1;
  end loop;

  for v_r in 1 .. 13 loop
    if v_counts[v_r] > 0 then
      v_run_len := v_run_len + 1;
      v_run_mult := v_run_mult * v_counts[v_r];
    else
      if v_run_len >= 3 then
        v_runs := v_runs + v_run_len * v_run_mult;
      end if;
      v_run_len := 0;
      v_run_mult := 1;
    end if;
  end loop;

  -- A run ending at the king needs closing out after the loop. Ace is low and
  -- runs never wrap, so there is no king-to-ace case to handle.
  if v_run_len >= 3 then
    v_runs := v_runs + v_run_len * v_run_mult;
  end if;

  -- Flush.
  select count(distinct substr(c, 2))
  into v_hand_suits
  from unnest(p_cards) as c;

  if v_hand_suits = 1 then
    if substr(p_starter, 2) = substr(p_cards[1], 2) then
      v_flush := 5;
    elsif not p_is_crib then
      v_flush := 4;
    end if;
  end if;

  -- Nobs: holding the jack matching the starter's suit. Only counts from the
  -- hand/crib cards -- the starter being a jack is his heels, not nobs.
  select case when count(*) > 0 then 1 else 0 end
  into v_nobs
  from unnest(p_cards) as c
  where substr(c, 1, 1) = 'J'
    and substr(c, 2) = substr(p_starter, 2);

  return jsonb_build_object(
    'points', v_fifteens + v_pairs + v_runs + v_flush + v_nobs,
    'fifteens', v_fifteens,
    'pairs', v_pairs,
    'runs', v_runs,
    'flush', v_flush,
    'nobs', v_nobs
  );
end;
$$;

-- Internal, deliberately. Confirm Count in Batch 2 will be a server-side RPC
-- that computes AND awards inside one locked transaction, exactly like
-- play_card -- the client must never supply or influence a point value. The
-- TypeScript mirror in lib/scoring.ts covers client-side display without a
-- round trip; the cross-check test is what keeps the two honest.
revoke all on function public.score_hand(text[], text, boolean) from public;


-- ---------------------------------------------------------------------------
-- 3. play_card -- pegging scoring wired in.
--
-- CHANGED FROM SLICE 7 in six marked regions, flagged inline below:
--   (A) new declarations
--   (B) score the segment, straight after the card is recorded
--   (C) the exactly-31 branch -- COMMENT ONLY, no logic change
--   (D) the deadlock branch: a stale comment goes, and the go flag is set
--   (E) the hand-over branch: the early RETURN becomes a flag
--   (F) the tail: one branching update, then the single award_points call,
--       so scoring runs on BOTH the phase-continues and phase-ends paths
--
-- Every other line, comments included, is byte-for-byte Slice 7. Verified
-- with `diff -u` on the extracted bodies -- output pasted in the summary.
--
-- ALL SEVEN GUARDS AND THE ROW LOCK ARE BYTE-FOR-BYTE UNCHANGED.
-- ---------------------------------------------------------------------------
create or replace function public.play_card(p_game_id uuid, p_card text)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
        current_player = null,
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
$$;

revoke all on function public.play_card(uuid, text) from public;
grant execute on function public.play_card(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. discard_to_crib -- his heels.
--
-- CHANGED FROM SLICE 7 in ONE marked region (G), at the very end of the
-- "everyone has discarded" branch. ALL SIX GUARDS, THE ROW LOCK, THE CRIB
-- SHUFFLE, THE STARTER CUT AND THE PHASE ENTRY ARE UNCHANGED -- as is every
-- comment, verified with `diff -u` on the extracted bodies.
--
-- "create or replace" preserves the existing ACL, so the grant to
-- authenticated survives without being restated.
-- ---------------------------------------------------------------------------
create or replace function public.discard_to_crib(p_game_id uuid, p_cards text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_game record;
  v_hand text[];
  v_new_hand text[];
  v_crib text[];
  v_discarded uuid[];
  v_player_count int;
  v_deck text[];
  v_new_deck text[];
  v_starter text;
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to discard.';
  end if;

  -- Guard 2: exactly 2 distinct cards (2-player rules, PRD Section 7).
  if array_length(p_cards, 1) is distinct from 2 then
    raise exception 'You must discard exactly 2 cards.';
  end if;

  if p_cards[1] = p_cards[2] then
    raise exception 'You must discard 2 different cards.';
  end if;

  -- THE ROW LOCK. Both players can discard at the same instant, and both need
  -- to append to games.discarded_by and to the crib. It also guarantees the
  -- completion branch below runs exactly once, so two simultaneous discards
  -- cannot cut two different starter cards or enter the play phase twice.
  select g.id, g.table_id, g.status, g.discarded_by, g.dealer_id, g.players
  into v_game
  from public.games g
  where g.id = p_game_id
  for update;

  if not found then
    raise exception 'Game not found.';
  end if;

  -- Guard 3: the game must still be live.
  if v_game.status <> 'active' then
    raise exception 'This game is no longer active.';
  end if;

  -- Guard 4 (the membership check).
  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = v_game.table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not a member of this table.';
  end if;

  -- Guard 5: no discarding twice.
  if v_caller = any(v_game.discarded_by) then
    raise exception 'You have already discarded to the crib.';
  end if;

  select gh.cards
  into v_hand
  from public.game_hands gh
  where gh.game_id = p_game_id
    and gh.user_id = v_caller;

  if v_hand is null then
    raise exception 'You do not have a hand in this game.';
  end if;

  -- Guard 6 (the anti-cheat check): you can only discard cards you hold.
  if not (p_cards <@ v_hand) then
    raise exception 'You can only discard cards from your own hand.';
  end if;

  -- Remove the two discards, preserving the order of what remains. THIS IS THE
  -- LAST WRITE to game_hands.cards for the rest of the hand: from here it is
  -- the immutable four-card hand that gets counted after play, and play_card
  -- tracks what has been played separately in game_plays.
  select coalesce(array_agg(t.c order by t.ord), '{}')
  into v_new_hand
  from unnest(v_hand) with ordinality as t(c, ord)
  where not (t.c = any(p_cards));

  update public.game_hands
  set cards = v_new_hand
  where game_id = p_game_id
    and user_id = v_caller;

  insert into public.game_cribs (game_id, cards)
  values (p_game_id, p_cards)
  on conflict (game_id) do update
  set cards = public.game_cribs.cards || excluded.cards;

  update public.games
  set discarded_by = discarded_by || v_caller
  where id = p_game_id;

  select count(*)
  into v_player_count
  from public.game_hands gh
  where gh.game_id = p_game_id;

  select g.discarded_by
  into v_discarded
  from public.games g
  where g.id = p_game_id;

  if coalesce(array_length(v_discarded, 1), 0) = v_player_count then
    -- Shuffle the crib so its order no longer reveals who contributed what.
    select c.cards
    into v_crib
    from public.game_cribs c
    where c.game_id = p_game_id;

    select array_agg(x order by random())
    into v_crib
    from unnest(v_crib) as x;

    update public.game_cribs
    set cards = v_crib
    where game_id = p_game_id;

    -- Cut the starter. The deck was already uniformly shuffled at deal time,
    -- so taking the top card is a fair cut.
    select d.cards
    into v_deck
    from public.game_decks d
    where d.game_id = p_game_id;

    if v_deck is not null and coalesce(array_length(v_deck, 1), 0) > 0 then
      v_starter := v_deck[1];

      select array_agg(t.c order by t.ord)
      into v_new_deck
      from unnest(v_deck) with ordinality as t(c, ord)
      where t.c <> v_starter;

      update public.game_decks
      set cards = coalesce(v_new_deck, '{}')
      where game_id = p_game_id;

      update public.games
      set starter_card = v_starter
      where id = p_game_id
        and starter_card is null;

      -- ===== (G) CHANGED FROM SLICE 7 (start) =====
      -- HIS HEELS: the dealer takes 2 the moment a jack is turned as the
      -- starter. Deferred back in Slice 4 because there was no score tracker
      -- to put it on; there is now.
      --
      -- Scored here, at cut time, and NOT inside score_hand -- counting it in
      -- both places is how this ends up awarded twice.
      --
      -- Uses card_rank_value (jack = 11). card_play_value would be 10 and
      -- would match every ten, jack, queen and king.
      if public.card_rank_value(v_starter) = 11 and v_game.dealer_id is not null then
        perform public.award_points(v_game.table_id, v_game.dealer_id, 2, 'his heels');
      end if;
      -- ===== (G) CHANGED FROM SLICE 7 (end) =====
    end if;

    -- NEW: enter the play phase. Standard cribbage -- the NON-DEALER (pone)
    -- always leads the first card.
    --
    -- Outside the deck guard above on purpose: the phase must advance when the
    -- crib completes, even in the defensive case where the deck was somehow
    -- empty and no starter could be cut.
    update public.games
    set phase = 'play',
        current_player = (
          select u
          from unnest(v_game.players) as u
          where u is distinct from v_game.dealer_id
          limit 1
        ),
        play_count = 0,
        play_segment = 0
    where id = p_game_id;
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- GRANTS CHECK. Run after the rest of this file.
--
-- Expect EXACTLY two rows, both 'authenticated': play_card and
-- discard_to_crib. score_pegging and score_hand must not appear at all.
-- ---------------------------------------------------------------------------

-- select routine_name, grantee, privilege_type
-- from information_schema.routine_privileges
-- where routine_schema = 'public'
--   and grantee in ('anon', 'authenticated')
--   and routine_name in (
--     'score_pegging', 'score_hand', 'play_card', 'discard_to_crib'
--   )
-- order by routine_name, grantee;
