-- Phase 2, Batch 2b (follow-up): the ready gate -- both players tap Next Hand
-- Run this in the Supabase Dashboard -> SQL Editor, AFTER
-- phase2-batch2b-next-hand.sql (already applied).
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- WHY A SEPARATE FILE: phase2-batch2b-next-hand.sql has already been run.
-- Editing it would make the repo claim a history the database never had --
-- someone re-reading it would believe one tap of Next Hand was never live.
-- As everywhere else in docs/sql, the LAST file to define a function is the
-- live version: after this file, that is next_hand here.
--
-- What changes:
--   1. games.ready_by -- who has tapped Next Hand for the current hand
--   2. next_hand -- REDEFINED in four marked regions (R1)-(R4). Every guard,
--      in the same order, and the delete / reset / deal are unchanged. The
--      new gate sits after the phase check: a tap now records the player as
--      ready, and only the tap that completes the set deals.
--
-- WHAT ELSE TOUCHES ready_by: NOTHING, deliberately.
--   * start_game_with_deal -- a new game gets the column default '{}'. No
--     change needed.
--   * Anything that ends a game (award_points' win, leave_table, admin
--     force-end, end_timed_out_sessions) -- an ended game is never dealt on
--     again (next_hand's status guard), and the next game is a new row with
--     its own empty ready_by. A non-empty ready_by left on an ended row is
--     inert. No change needed.
--   * next_hand itself is the only writer: it appends in 'done' and clears in
--     the same UPDATE that leaves 'done'. So ready_by can only be non-empty
--     while phase = 'done'.
--   * show_hand / show_crib / confirm_count / play_card / discard_to_crib
--     never read or write it.
--
-- GRANTS: unchanged. next_hand keeps its grant through "create or replace"
-- (restated below anyway); still ten client-callable functions.
--
-- THE CLIENT is not updated in this file's slice: until it is, the first tap
-- succeeds silently with no visible "waiting for the other player", and only
-- the second player's tap moves both screens on.


-- ---------------------------------------------------------------------------
-- 1. ready_by.
--
-- Not null with an empty default, like discarded_by and revealed_by, so
-- "nobody yet" is '{}' rather than null and array tests need no coalesce.
-- Existing rows get '{}', which is right: no game has a pending tap.
-- ---------------------------------------------------------------------------
alter table public.games
  add column ready_by uuid[] not null default '{}';


-- ---------------------------------------------------------------------------
-- 2. next_hand -- deal the following hand once EVERY player is ready.
--
-- CHANGED FROM BATCH 2b (phase2-batch2b-next-hand.sql) in four marked
-- regions:
--   (R1) a declaration
--   (R2) the lock's select list gains ready_by (plus a comment)
--   (R3) the ready gate, straight after the phase check
--   (R4) ready_by = '{}' in the reset UPDATE
-- Every other line, comments included, is byte-for-byte Batch 2b.
--
-- Order of checks after this change:
--   logged in -> p_hand_no not null -> ROW LOCK -> active -> member and
--   player -> behind = quiet / ahead = error -> phase 'done' ->
--   already ready = quiet -> not everyone ready = record and return ->
--   everyone ready = delete, reset (ready_by cleared), deal
--
-- The behind/ahead rule still does its job: a tap carrying the OLD hand
-- number after the deal is quiet. Before the deal, both players' taps carry
-- the CURRENT hand number, so the gate -- not hand_no -- is what decides.
-- The row lock serializes the two taps: the second sees the first's
-- ready_by and is the one that deals, exactly once.
-- ---------------------------------------------------------------------------
create or replace function public.next_hand(p_game_id uuid, p_hand_no int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_game record;
  v_player_count int;
  v_dealer_pos int;
  v_next_dealer uuid;
  v_hands_dealt int;
  -- ===== (R1) CHANGED FROM BATCH 2b (start) =====
  v_ready uuid[];
  -- ===== (R1) CHANGED FROM BATCH 2b (end) =====
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to deal the next hand.';
  end if;

  -- Guard 2: the client must say which hand it is looking at.
  if p_hand_no is null then
    raise exception 'Which hand is this? p_hand_no is required.';
  end if;

  -- THE ROW LOCK. Both players can tap Next Hand at the same instant. The
  -- second waits here until the first commits, then sees the new hand_no and
  -- returns quietly below -- this lock is what makes "deal once" true.
  -- ===== (R2) CHANGED FROM BATCH 2b (start) =====
  -- With the ready gate (R3), two players tapping together for the SAME hand
  -- no longer race to deal: the first only marks itself ready, and the
  -- second -- after waiting here -- is the one that deals. The comment
  -- above still holds for any tap that arrives after the deal.
  --
  -- ready_by is read under the lock: it is read-modify-written below, and two
  -- players tapping together must not both see "only me so far".
  select g.id, g.table_id, g.status, g.phase, g.players, g.dealer_id, g.hand_no,
         g.ready_by
  -- ===== (R2) CHANGED FROM BATCH 2b (end) =====
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

  -- Guard 4 (membership): sitting at the table, and a player in this game.
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

  -- Guard 5 (idempotency): behind is quiet, ahead is an error.
  if v_game.hand_no > p_hand_no then
    return;
  end if;

  if v_game.hand_no < p_hand_no then
    raise exception 'Hand % has not been dealt yet.', p_hand_no;
  end if;

  -- Guard 6: only once every count, crib included, is in.
  if v_game.phase <> 'done' then
    raise exception 'This hand is not finished yet.';
  end if;

  -- ===== (R3) CHANGED FROM BATCH 2b (start) =====
  -- THE READY GATE. Every player must tap Next Hand before the hand is dealt.
  --
  -- Already ready: quiet, like a stale tap. A double tap, or a second tab.
  if v_caller = any(v_game.ready_by) then
    return;
  end if;

  v_ready := array_append(v_game.ready_by, v_caller);

  -- Not everyone yet: record this player as ready and stop. Nothing is
  -- deleted, dealt or reset; hand_no does not move, so the other player's
  -- tap still carries the right hand number.
  if not (v_game.players <@ v_ready) then
    update public.games
    set ready_by = v_ready
    where id = p_game_id;
    return;
  end if;

  -- Everyone is ready: fall through and deal. ready_by is cleared in the
  -- same reset UPDATE below, so the next hand's gate starts empty.
  -- ===== (R3) CHANGED FROM BATCH 2b (end) =====

  -- The next dealer: the player after the current dealer in players,
  -- wrapping round. In 2-player that simply swaps the deal; written this way
  -- so 3- and 4-player games (Phase 3) rotate without a rewrite -- though
  -- players is in JOIN order, not seating order, which Phase 3 must address.
  v_player_count := coalesce(array_length(v_game.players, 1), 0);
  v_dealer_pos := array_position(v_game.players, v_game.dealer_id);

  -- Guard 7 (defensive): cannot fail if only these functions write the row.
  if v_dealer_pos is null then
    raise exception 'The current dealer is not a player in this game.';
  end if;

  v_next_dealer := v_game.players[(v_dealer_pos % v_player_count) + 1];

  -- CLEAR THE FINISHED HAND. Every row is this game's only. game_hands,
  -- game_cribs and game_decks are not in the Realtime publication, so these
  -- deletes broadcast nothing; game_plays is, but the client listens only for
  -- INSERTs there and resets its play list on the hand_no change instead.
  delete from public.game_plays where game_id = p_game_id;
  delete from public.game_hands where game_id = p_game_id;
  delete from public.game_cribs where game_id = p_game_id;
  delete from public.game_decks where game_id = p_game_id;

  -- RESET THE HAND -- every per-hand column, explicitly, in one statement.
  update public.games
  set hand_no = hand_no + 1,
      -- ===== (R4) CHANGED FROM BATCH 2b (start) =====
      ready_by = '{}',
      -- ===== (R4) CHANGED FROM BATCH 2b (end) =====
      dealer_id = v_next_dealer,
      phase = 'discard',
      discarded_by = '{}',
      starter_card = null,
      current_player = null,
      play_count = 0,
      play_segment = 0,
      count_step = 0,
      revealed_by = '{}',
      crib_revealed = false
  where id = p_game_id;

  -- DEAL.
  perform public.deal_cards_for_game(p_game_id);

  -- Guard 8 (defensive): deal_cards_for_game's inserts are "on conflict do
  -- nothing", so if a hand had somehow survived the delete it would be kept
  -- silently. Count what is actually there rather than trust it.
  select count(*)
  into v_hands_dealt
  from public.game_hands gh
  where gh.game_id = p_game_id
    and coalesce(array_length(gh.cards, 1), 0) = 6;

  if v_hands_dealt <> v_player_count then
    raise exception 'Next hand dealt % full hands for % players.', v_hands_dealt, v_player_count;
  end if;
end;
$$;

revoke all on function public.next_hand(uuid, int) from public;
grant execute on function public.next_hand(uuid, int) to authenticated;


-- ---------------------------------------------------------------------------
-- Checks: docs/sql/phase2-batch2b-verification.sql -- query 1 (columns,
-- now including ready_by) and query 4 (the next-hand walk-through, now with
-- the two-tap gate). Query 2's grants are unchanged.
-- ---------------------------------------------------------------------------
