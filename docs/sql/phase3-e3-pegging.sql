-- Phase 3, step E3: pegging for 2, 3 and 4 players
-- Run this in the Supabase Dashboard -> SQL Editor, AFTER
-- phase3-e2-dealing.sql (live). Kept here for reference/history; this
-- project has no Supabase CLI/migrations set up yet.
--
-- WHAT IT DOES -- ONE function redefined, from its NEWEST version
-- (phase2-batch2a-counting.sql) with marked regions only; no table, column,
-- policy or grant changes:
--   play_card
--     (P1) declarations: v_opponent goes, the walk's variables come in.
--     (P2) the caller's place in games.players (seat order, clockwise).
--     (P3) what happens after a card -- the CLOCKWISE WALK -- replacing the
--          single-opponent branches and the leader fallback.
--     (P4) when pegging ends, the dealer's LEFT counts first.
--   Every guard, message, the row lock, the seq under the lock, the scoring
--   (A)/(B) and the one-award-call-last (F) are unchanged.
--
-- THE RULES (approved E3 proposal, rules 1-9):
--   * The dealer's left leads (E2 already sets it).
--   * After each card the turn goes to the FIRST player clockwise who can
--     legally play at the new count (count + card <= 31). A player passed
--     over who still holds cards but can't play gets a 'go' row -- each time
--     they are passed over, as the 2-player opponent always has; a player
--     with no cards left is skipped silently.
--   * Nobody else can play but the caller can: the caller plays again.
--   * Nobody can play at all: the player who played the LAST card gets 1
--     ("go", or "last card" when the hand ends) and the count resets.
--   * Exactly 31: 2 points ("thirty-one", from score_pegging), no go point,
--     and the count resets.
--   * After a reset the first player clockwise after the last card's player
--     who still holds a card leads (that player themself last).
--   * Pegging points (score_pegging on the current run, plus the go point)
--     go to the player who played the card, in one award_points call; 121
--     ends the match at once, as before.
--   * When nobody holds a card: phase 'counting', count 0, play_segment =
--     last + 1, count_step 0 (unchanged), and the dealer's LEFT is
--     current_player -- counting itself is E4's.
--   Go stays automatic. Points go to each scorer's own table_members row
--   (Team totals are E4's).
--
-- 2-PLAYER PEGGING IS UNCHANGED. With 2 players the walk visits exactly one
-- other player -- the old v_opponent -- so every branch is the old one:
--   the opponent can play           -> the turn passes, no go row
--   the opponent holds cards but
--     can't play, the caller can    -> a go row for the opponent; the caller again
--   the opponent has no cards,
--     the caller can play           -> no go row; the caller again
--   nobody can play                 -> the go row (if the opponent holds
--                                      cards), the go point to the caller,
--                                      the reset, the opponent leads (else
--                                      the caller, else the hand is over)
--   31                              -> the reset, the opponent leads (else
--                                      the caller, else the hand is over)
--   the hand ends                   -> the non-dealer counts first
-- This is PROVEN, not assumed: the verification plays twelve scripted
-- 2-player hands through this play_card and through a copy of the old one,
-- side by side, and compares every row and score after every card.
--
-- NOT CHANGED: has_legal_play, score_pegging, card_play_value, award_points,
-- confirm_count, show_hand, show_crib, and every other function (including
-- E1's and E2's). game_plays and its read policy are unchanged.
--
-- WHAT A 3- AND 4-PLAYER GAME CAN DO AFTER E3: be played through the whole
-- pegging, reaching the count with the dealer's left to count first.
-- Counting (E4) is still 2-player, so it can't yet be counted past the first
-- hand. The live client only offers 2-player tables until then.
--
-- GRANTS: unchanged ("create or replace" keeps them); restated below. Still
-- fourteen client-callable functions.
--
-- RE-RUNNABLE: "create or replace" with the same signature.
--
-- ROLLBACK: re-run the previous play_card -- its "create or replace function
-- public.play_card" statement and the revoke/grant lines right after it --
-- from phase2-batch2a-counting.sql. Roll back only while no 3- or 4-player
-- game is in its play phase: the old play_card deals with one opponent only.
--
-- Checks: docs/sql/phase3-e3-pegging-verification.sql -- one rolled-back
-- walk-through as real players, with the side-by-side 2-player proof.


-- ---------------------------------------------------------------------------
-- play_card -- the clockwise walk.
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
  -- ===== (P1) CHANGED FOR PHASE 3 E3 (start) =====
  -- v_opponent is gone: there is no single "other player" with 3 or 4.
  -- The players array (seat order, clockwise) is walked instead.
  v_n int;
  v_pos int;
  v_next uuid;
  v_reset boolean := false;
  -- ===== (P1) CHANGED FOR PHASE 3 E3 (end) =====
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

  -- ===== (P2) CHANGED FOR PHASE 3 E3 (start) =====
  -- Where the caller sits in the players array: the walk below starts at
  -- the next seat clockwise. players[((v_pos - 1 + i) % v_n) + 1] is the
  -- i-th player clockwise after the caller; i = v_n is the caller again.
  v_n := array_length(v_game.players, 1);
  v_pos := array_position(v_game.players, v_caller);
  -- ===== (P2) CHANGED FOR PHASE 3 E3 (end) =====

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

  -- ===== (P3) CHANGED FOR PHASE 3 E3 (start) =====
  -- THE CLOCKWISE WALK. The same decisions as the 2-player code it replaces,
  -- for 2, 3 or 4 players; with 2 the walk visits exactly one other player
  -- (the old v_opponent), so every branch below is the old one.
  if v_count = 31 then
    -- Exactly 31 ends the segment immediately. Nobody declares a go.
    -- (The 2 points for 31 are counted in (B) above, and they REPLACE the
    -- last-card point rather than stacking with it.)
    v_reset := true;

  else
    -- The turn goes to the FIRST player clockwise after the caller who can
    -- legally play at the new count. Every player passed over who still
    -- holds cards but cannot play gets a go row -- each time they are
    -- passed over, as the 2-player opponent always has -- and a player with
    -- no cards left is skipped silently: they have nothing to "go" on, and
    -- logging one would put a phantom event in the history at the end of
    -- every hand.
    v_leader := null;
    for i in 1 .. v_n - 1 loop
      v_next := v_game.players[((v_pos - 1 + i) % v_n) + 1];

      if public.has_legal_play(p_game_id, v_next, v_count) then
        v_leader := v_next;
        exit;
      end if;

      if public.has_legal_play(p_game_id, v_next, 0) then
        v_seq := v_seq + 1;
        insert into public.game_plays (game_id, seq, segment, user_id, kind, card, count_after)
        values (p_game_id, v_seq, v_segment, v_next, 'go', null, v_count);
      end if;
    end loop;

    if v_leader is null then
      if public.has_legal_play(p_game_id, v_caller, v_count) then
        -- Nobody else can play: the same player keeps playing. This is
        -- exactly why current_player cannot be derived from the last play.
        v_leader := v_caller;
      else
        -- THE DEADLOCK CASE: nobody can legally play, but the count is under
        -- 31. Without an automatic reset here play would stall with no legal
        -- action available to anybody.
        --
        -- The go point goes to v_caller -- the player who played the LAST
        -- card of the segment, not any player whose go row was just logged.
        -- Attribution is from control flow ("I just played and the segment
        -- is closing"), never from reading the go rows.
        v_reset := true;
        v_go_point := true;
      end if;
    end if;
  end if;

  -- THE NEXT SEGMENT (after a 31 or a deadlock): the count resets, and the
  -- first player clockwise after the one who played the last card who still
  -- holds a card leads -- the caller themself last, if only they hold any.
  -- With 2 players: the other player, else the caller (as before). If
  -- nobody holds anything, every card is down and the hand is over.
  --
  -- (Slice 7 updated games to 'counting' and RETURNED at that point; the
  -- early return is a flag instead, because award_points must fire on this
  -- path too -- a final card that closes the hand still scores, and this is
  -- also the moment "go" becomes "last card".)
  if v_reset then
    v_count := 0;
    v_segment := v_segment + 1;
    v_leader := null;

    for i in 1 .. v_n loop
      v_next := v_game.players[((v_pos - 1 + i) % v_n) + 1];

      if public.has_legal_play(p_game_id, v_next, 0) then
        v_leader := v_next;
        exit;
      end if;
    end loop;

    if v_leader is null then
      v_phase_over := true;
    end if;
  end if;
  -- ===== (P3) CHANGED FOR PHASE 3 E3 (end) =====

  -- ===== (F) CHANGED FROM SLICE 7 (start) =====
  if v_phase_over then
    update public.games
    set phase = 'counting',
        -- ===== (H) CHANGED FROM BATCH 1 (start) =====
        -- The pone counts first. Batch 1 set null here; confirm_count's turn
        -- guard needs a real player.
        -- ===== (P4) CHANGED FOR PHASE 3 E3 (start) =====
        -- The player on the dealer's LEFT counts first: the next seat
        -- clockwise. With 2 players that is the pone, as before. (The old
        -- rule stays as the fallback for the defensive case of no dealer.)
        current_player = coalesce(
          games.players[(array_position(games.players, games.dealer_id)
                         % array_length(games.players, 1)) + 1],
          (
            select u
            from unnest(games.players) as u
            where u is distinct from games.dealer_id
            limit 1
          )
        ),
        -- ===== (P4) CHANGED FOR PHASE 3 E3 (end) =====
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
$$;

revoke all on function public.play_card(uuid, text) from public;
revoke all on function public.play_card(uuid, text) from anon;
grant execute on function public.play_card(uuid, text) to authenticated;
