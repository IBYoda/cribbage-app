-- Phase 2, Batch 2b: next hand, the match loop, and New Game as a new match
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- What this adds:
--   1. games.hand_no -- which hand of the match this is (1, 2, 3, ...)
--   2. next_hand(game, p_hand_no) -- NEW, granted: from 'done', clear the
--      finished hand and deal the next one, dealer rotating
--   3. start_game_with_deal -- REDEFINED in four marked regions (M1)-(M4):
--      New Game starts a new MATCH: both scores and the tracker reset, and
--      the loser of a won match deals first; anything else cuts for deal
--
-- One games row is one MATCH to 121 (decided at the Batch 2 design
-- checkpoint). Before this file, nothing could move a game past 'done'; now
-- next_hand does, and the same row carries every hand until someone wins.
--
-- UNCHANGED, deliberately: deal_cards_for_game, discard_to_crib, play_card,
-- award_points, show_hand, show_crib, confirm_count, leave_table,
-- end_timed_out_sessions. The 5-hour timeout keeps measuring from
-- games.created_at, which is now the start of the MATCH (design decision 4).
--
-- GRANTS: after this file, TEN functions are meant to be client-callable --
-- 2a's nine plus next_hand. docs/sql/phase2-batch2b-verification.sql query 2
-- is the check (it still tolerates the three known pre-existing grants).
--
--
-- ===========================================================================
-- WHAT deal_cards_for_game ASSUMES (design addition (a))
-- ===========================================================================
--
-- deal_cards_for_game (Slice 5, unchanged) shuffles one deck, inserts two
-- 6-card game_hands rows for players[1] and players[2], and inserts the
-- remaining 40 cards as the game_decks row. Both inserts are
-- "on conflict do nothing". It reads games.players and nothing else.
--
-- What it assumes, and how each caller meets it:
--
--   P1. games.players holds exactly 2 players.
--       It checks this itself and raises otherwise.
--       * loser-deals path: the insert sets players = v_players, which Guard 4
--         has just proved is exactly 2.
--       * next_hand: players is never written after a game is created; it is
--         the same 2 the match started with.
--
--   P2. NO game_hands rows already exist for the game. This is the dangerous
--       one: "on conflict do nothing" means an existing row is SILENTLY KEPT,
--       so a stale hand would survive into the new deal with no error at all.
--       * loser-deals path: the game was inserted a statement earlier, so no
--         row can reference it.
--       * next_hand: deletes them first, then checks afterwards that exactly
--         one fresh hand exists per player, and raises if not.
--
--   P3. NO game_decks row already exists. Same silent-keep risk: an old deck
--       would be cut from, and could hand out cards already dealt.
--       * loser-deals path: new game, none can exist.
--       * next_hand: deletes it first.
--
--   Not read by deal_cards_for_game, but assumed by what runs after it:
--
--   P4. NO game_cribs row (discard_to_crib APPENDS to an existing row, so a
--       leftover crib would grow to 6 or 8 cards).
--       * loser-deals: none can exist.  * next_hand: deleted.
--
--   P5. NO game_plays rows (has_legal_play and play_card read them by game;
--       an old play would count as "already played" in the new hand).
--       * loser-deals: none can exist.  * next_hand: deleted.
--
--   P6. dealer_id is set, and is one of the players (discard_to_crib picks
--       the pone, and awards his heels, from it).
--       * loser-deals: set to the loser, who is in v_players.
--       * next_hand: set to the player after the current dealer in players.
--
--   P7. The per-hand columns are at their start-of-hand values:
--       phase 'discard', discarded_by '{}', starter_card null,
--       current_player null, play_count 0, play_segment 0, count_step 0,
--       revealed_by '{}', crib_revealed false, and status 'active'.
--       * loser-deals: every one of these is the column DEFAULT, and the
--         insert sets status 'active' explicitly.
--       * next_hand: writes every one of them explicitly, in one UPDATE.
--
-- THE LOSER-DEALS PATH LEAVES THE GAME IN EXACTLY THE POST-CUT STATE.
-- After a cut resolves, acknowledge_deal_cut calls deal_cards_for_game and
-- sets status 'active' and deal_cut_ack_by '{}' on a row whose every other
-- column still has its default, plus the dealer draw_cut_card chose. The
-- loser-deals path produces the same row -- status 'active', dealer set,
-- hand_no 1, everything in P7 at its default, deal_cut_ack_by '{}' (default)
-- -- with ONE difference: deal_cut is null instead of the cut's history. Only
-- the cut screen reads deal_cut, and only while status = 'cutting', which
-- this game never is; the alternating path that Slice 5 already shipped has
-- always created games this way. discard_to_crib reads status,
-- discarded_by, dealer_id and players -- identical on both paths.


-- ---------------------------------------------------------------------------
-- 1. hand_no.
--
-- Which hand of the match this is. Starts at 1; next_hand increments it in
-- the same UPDATE that resets the hand.
--
-- Two jobs:
--   * the client compares it to the last one it handled -- a change means a
--     new hand was dealt, so it drops its plays, selection and reveals and
--     fetches its new cards
--   * next_hand's idempotency key: the client sends the hand it is looking
--     at, so a second tap for the same hand cannot deal twice
--
-- Existing rows get 1 from the default, which is correct: before this file
-- no game could get past its first hand.
-- ---------------------------------------------------------------------------
alter table public.games
  add column hand_no int not null default 1
    check (hand_no >= 1);


-- ---------------------------------------------------------------------------
-- 2. next_hand -- deal the following hand.
--
-- Either player may call it, from phase 'done' (design decision: either
-- player taps Next Hand).
--
-- p_hand_no is the hand the client is looking at:
--   behind the game (hand_no > p_hand_no) -> return quietly. The next hand
--     is already dealt -- a double tap, the other player's tap landing first,
--     or a second tab. The row lock below makes the second of two
--     simultaneous taps wait for the first to commit, then see the higher
--     hand_no -- so two taps can never deal two hands.
--   ahead of the game (hand_no < p_hand_no) -> error. Only a client bug can
--     ask for a hand that has not been dealt.
-- The behind/ahead check comes BEFORE the phase check: once the first tap has
-- dealt, the phase is 'discard', and a late duplicate must be quiet, not an
-- error about the phase.
--
-- ONE TRANSACTION, in this order:
--   delete  game_plays, game_hands, game_cribs, game_decks (this game only)
--   update  games: hand_no + 1, the next dealer, and every per-hand column
--           back to its start-of-hand value (P7 above)
--   deal    deal_cards_for_game, then a check that it really dealt
--
-- revealed_by is cleared in the SAME transaction that creates the new hands,
-- so there is no moment at which the shown-hand read policy could expose a
-- freshly dealt hand.
--
-- PERSISTS: scores, last_points/last_reason/last_awarded_at, players,
-- status, created_at (the match's 5-hour clock), deal_cut, winner_id.
--
-- HIS HEELS: starter_card is cleared and the deck replaced, so the new hand's
-- cut happens fresh inside discard_to_crib when the second discard lands --
-- its "where starter_card is null" succeeds, and his heels is judged once,
-- against the NEW starter. Nothing from the previous hand can re-award it.
--
-- NO WIN CAN HAPPEN HERE: nothing awards points in 'done'. A leave, admin
-- force-end or timeout racing this call is serialized by the row lock (their
-- UPDATE takes the same lock): if they land first, status is 'ended' and this
-- raises; if this lands first, the new hand is dealt and then the game ends.
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
  select g.id, g.table_id, g.status, g.phase, g.players, g.dealer_id, g.hand_no
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
-- 3. start_game_with_deal -- New Game starts a new MATCH.
--
-- CHANGED FROM SLICE 5 in four marked regions, (M1)-(M4). Every other line,
-- comments included, is byte-for-byte Slice 5 -- including the four guards
-- and both unique_violation handlers. "create or replace" preserves the ACL;
-- the grant is restated anyway.
--
-- WHO DEALS FIRST (design decision 1):
--   * The previous game at this table ended 'won', it was between the SAME
--     two players who are here now -> the LOSER deals, no cut. The game is
--     created 'active' and dealt at once, exactly like Slice 5's alternating
--     path (see "THE LOSER-DEALS PATH" at the top of this file).
--   * Anything else -> cut for deal: no previous game, a previous game ended
--     by 'admin', 'timeout' or 'player_left', an abandoned cut, or a changed
--     roster. This REPLACES Slice 5's "alternate from the last dealer", which
--     after a player_left would have had a newcomer deal against someone they
--     never cut with.
--   "The previous game" is simply the most recent one at the table. There is
--   no live game to confuse it with: if one existed, the insert below would
--   hit the one-live-game index and return it unchanged.
--
-- THE SCORE RESET (design decision 3): every table_members row at this table
-- goes to score 0 with last_points/last_reason/last_awarded_at cleared, on
-- BOTH paths. It runs only after THIS call's insert has succeeded: both
-- unique_violation handlers return early, before it. That matters -- two
-- players tapping New Game together means the slower one is handed the game
-- the faster one created, possibly after points have already been scored in
-- it, and must not wipe them. Clearing last_* means no stale "+2 — his
-- heels" from the last match: PlayerScore shows no flash when last_points is
-- null.
-- ---------------------------------------------------------------------------
create or replace function public.start_game_with_deal(p_table_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_players uuid[];
  v_player_count int;
  v_game_id uuid;
  v_dealer uuid;
  -- ===== (M1) CHANGED FROM SLICE 5 (start) =====
  -- v_prev_dealer is gone: the deal no longer alternates from the last
  -- dealer. These describe the previous MATCH instead.
  v_prev_reason text;
  v_prev_winner uuid;
  v_prev_players uuid[];
  v_loser uuid;
  -- ===== (M1) CHANGED FROM SLICE 5 (end) =====
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to start a game.';
  end if;

  -- Guard 2 (the membership check): the caller must actually be sitting at
  -- this table.
  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = p_table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not a member of this table.';
  end if;

  -- Guard 3: the table itself must still be open.
  if not exists (
    select 1
    from public.tables t
    where t.id = p_table_id
      and t.status = 'open'
  ) then
    raise exception 'This table is no longer open.';
  end if;

  -- Guard 4: 2-player only (3/4-player is Phase 3).
  select array_agg(tm.user_id order by tm.joined_at)
  into v_players
  from public.table_members tm
  where tm.table_id = p_table_id;

  v_player_count := coalesce(array_length(v_players, 1), 0);

  if v_player_count <> 2 then
    raise exception 'A game needs exactly 2 players at the table (currently %).', v_player_count;
  end if;

  -- ===== (M2) CHANGED FROM SLICE 5 (start) =====
  -- THE PREVIOUS MATCH: the most recent game at this table, whatever its
  -- status. Scalars rather than a record, so "no previous game" is simply
  -- three nulls and every test below reads false.
  select g.ended_reason, g.winner_id, g.players
  into v_prev_reason, v_prev_winner, v_prev_players
  from public.games g
  where g.table_id = p_table_id
  order by g.created_at desc
  limit 1;

  -- The loser deals first -- but only after a WON match between exactly the
  -- two players who are here now (compared as sets, so join order does not
  -- matter). The loser is then necessarily still at the table, because
  -- v_players is the current roster. Any other ending leaves v_loser null and
  -- falls through to the cut.
  if v_prev_reason = 'won'
     and v_prev_winner is not null
     and v_prev_players is not null
     and (select array_agg(u order by u) from unnest(v_prev_players) as u)
         = (select array_agg(u order by u) from unnest(v_players) as u)
  then
    select u
    into v_loser
    from unnest(v_players) as u
    where u <> v_prev_winner
    limit 1;
  end if;

  if v_loser is not null then
    -- A rematch: the loser deals the first hand. No cut is needed, so this
    -- path deals immediately and goes straight to 'active' -- the same state
    -- a resolved cut leaves (see the top of this file).
    v_dealer := v_loser;
  -- ===== (M2) CHANGED FROM SLICE 5 (end) =====

    begin
      insert into public.games (table_id, created_by, dealer_id, players, status, deal_cut)
      values (p_table_id, v_caller, v_dealer, v_players, 'active', null)
      returning id into v_game_id;
    exception when unique_violation then
      select g.id into v_game_id
      from public.games g
      where g.table_id = p_table_id
        and g.status in ('cutting', 'active');
      return v_game_id;
    end;

    perform public.deal_cards_for_game(v_game_id);
  else
    -- ===== (M3) CHANGED FROM SLICE 5 (start) =====
    -- No decisive previous result -- the first game at this table, a previous
    -- game that ended without a winner (admin, timeout, player_left), or a
    -- changed roster -- so the deal must be cut for.
    -- ===== (M3) CHANGED FROM SLICE 5 (end) =====
    --
    -- NOTHING is dealt here and no dealer is chosen. deal_cut starts as one
    -- empty round for players to draw into; every card and the dealer itself
    -- are decided later, by draw_cut_card, at the moment a player taps.
    begin
      insert into public.games (table_id, created_by, dealer_id, players, status, deal_cut)
      values (p_table_id, v_caller, null, v_players, 'cutting', '[[]]'::jsonb)
      returning id into v_game_id;
    exception when unique_violation then
      select g.id into v_game_id
      from public.games g
      where g.table_id = p_table_id
        and g.status in ('cutting', 'active');
      return v_game_id;
    end;
  end if;

  -- ===== (M4) CHANGED FROM SLICE 5 (start) =====
  -- NEW MATCH, NEW SCORES. Reached only by the call whose insert succeeded:
  -- both unique_violation handlers above return before this line, so a
  -- second, simultaneous New Game can never wipe a match already under way.
  update public.table_members
  set score = 0,
      last_points = null,
      last_reason = null,
      last_awarded_at = null
  where table_id = p_table_id;
  -- ===== (M4) CHANGED FROM SLICE 5 (end) =====

  return v_game_id;
end;
$$;

revoke all on function public.start_game_with_deal(uuid) from public;
grant execute on function public.start_game_with_deal(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- Checks: see docs/sql/phase2-batch2b-verification.sql -- the column, the
-- ten-function grants check, the 52-card integrity check, and two
-- rolled-back walk-throughs that execute next_hand and start_game_with_deal
-- (every path, including the racing second New Game).
-- ---------------------------------------------------------------------------
