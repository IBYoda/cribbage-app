-- Phase 3, step E2: dealing and the cut for 2, 3 and 4 players
-- Run this in the Supabase Dashboard -> SQL Editor, AFTER
-- phase3-e1-seating.sql (live). Kept here for reference/history; this
-- project has no Supabase CLI/migrations set up yet.
--
-- WHAT IT DOES -- four functions redefined, each from its NEWEST version
-- with marked regions only; no table, column, policy or grant changes:
--   1. start_game_with_deal  (from phase2-new-game-ready-gate.sql)
--        (D1)-(D5): takes the TABLE LOCK first; lists the players in SEAT
--        order; needs exactly tables.max_players seated; for 3 and 4
--        players only the host starts a match that cuts for deal; after a
--        won match the player in the next seat clockwise from the winner
--        deals (the other player, with 2).
--   2. deal_cards_for_game   (from phase2-slice-5-cut-before-deal.sql)
--        (C1)-(C2): 6 cards each for 2 players, 5 each for 3 and 4; with 3,
--        one more card goes face down into the crib.
--   3. discard_to_crib       (from phase2-batch1-scoring-engines.sql)
--        (X1)-(X3): 2 cards with 2 players, 1 card with 3 and 4; the
--        player on the dealer's left (next seat clockwise) leads.
--   4. next_hand             (from phase2-batch2b-ready-gate.sql)
--        (H1): its check that every hand was dealt counts 5 cards as a full
--        hand for 3 and 4 players. The gate on the counting being finished
--        and the rotation are untouched.
--
-- WHY: Phase 3 deals 3 and 4 player games. Seats (E1) replace join order:
-- clockwise is increasing seat, wrapping from the last seat back to 1, and
-- the dealer's "left" is the next seat clockwise.
--
-- NOT CHANGED, because they already work for any number of players:
--   * draw_cut_card and acknowledge_deal_cut. A cut round is a jsonb array
--     of {user_id, card} in games.deal_cut; it is full when every player in
--     games.players has drawn (each a distinct card from a fresh shuffle);
--     "decisive" means exactly ONE player holds the lowest rank (ties among
--     the others don't matter), and that player becomes the dealer. Once
--     every player has acknowledged a full round, a decisive round deals and
--     goes 'active'; a tie opens a fresh round for EVERY player. None of it
--     counts to 2.
--   * The privacy rules. A hand is readable by its owner, by anyone at the
--     table once it is shown, and by the game's players once pegging is over
--     or the match is won; the crib only from its count on (or a won
--     match); the deck by nobody. All are per player and per game, never
--     "the other player", so 3 and 4 player hands stay exactly as private.
--   * Everything else: play_card, has_legal_play, show_hand, show_crib,
--     confirm_count, award_points, claim_win, clear_win_claim, confirm_win,
--     leave_table, end_timed_out_sessions, and E1's set_seat, seat_team,
--     table_host and assign_table_seat.
--
-- 2-PLAYER GAMES ARE UNCHANGED: the same states, cards, messages and
-- order of checks. Every 2-player rule above is the old one (6 cards, 2
-- discards, "exactly 2 players", anyone may start, the other player
-- deals after a win, the non-dealer leads). Two things are different only
-- underneath:
--   * games.players is now in SEAT order rather than join order. They
--     differ only after a leave and a rejoin. Nothing in a 2-player game
--     depends on the order: the deal hands each player a random block of a
--     random shuffle, the rotation and the lead are "the other player"
--     either way, and the ready gate and the loser test compare players as
--     sets.
--   * Two simultaneous New Game taps now wait for each other on the table
--     lock instead of racing to the insert. The second still ends up with
--     the first one's game, as before.
--
-- THE TABLE LOCK: start_game_with_deal locks the tables row FOR NO KEY
-- UPDATE before it reads anything -- the same lock assign_table_seat (every
-- join) and set_seat take -- so a start, a join and a seat move at one
-- table run one at a time, and the roster and seats a game is made from
-- can't change underneath it. Lock order: tables row, then the previous
-- game's row (the ready gate), then the new game. No function takes a
-- games row and then the tables row, so this adds no deadlock; see the
-- verification header for the review.
--
-- WHAT A 3- AND 4-PLAYER GAME CAN DO AFTER E2: be started (by the host),
-- cut for, dealt and discarded to, reaching the play phase with the starter
-- cut. Pegging (E3) and counting (E4) are still 2-player, so a 3 or 4 player
-- game can't yet be played past the first card or to a second hand -- the
-- live client only offers 2-player tables until then. next_hand is ready
-- for them (H1) once E4 lets the count finish.
--
-- GRANTS: unchanged -- "create or replace" keeps each function's grants,
-- and the same revoke/grant lines are restated below. Still fourteen
-- client-callable functions.
--
-- RE-RUNNABLE: "create or replace" with the same signatures.
--
-- ROLLBACK: re-run the previous definition of each function -- only its
-- "create or replace function" statement and the revoke/grant lines right
-- after it -- from:
--   start_game_with_deal  phase2-new-game-ready-gate.sql
--   deal_cards_for_game   phase2-slice-5-cut-before-deal.sql
--   discard_to_crib       phase2-batch1-scoring-engines.sql
--   next_hand             phase2-batch2b-ready-gate.sql
-- in any order (they don't depend on each other's new behaviour). Roll
-- back only while no 3- or 4-player game is live: the old deal_cards_for_game
-- refuses them, and the old discard_to_crib wants 2 cards.
--
-- Checks: docs/sql/phase3-e2-dealing-verification.sql -- one rolled-back
-- walk-through as real players.


-- ---------------------------------------------------------------------------
-- 1. start_game_with_deal -- the table lock, seat order, table size, the
-- host, and who deals after a win.
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
  -- ===== (N1) CHANGED FROM BATCH 2b (start) =====
  v_prev_id uuid;
  v_prev_ready uuid[];
  v_ready uuid[];
  v_live uuid;
  -- ===== (N1) CHANGED FROM BATCH 2b (end) =====
  -- ===== (D1) CHANGED FOR PHASE 3 E2 (start) =====
  v_status text;
  v_max smallint;
  v_winner_pos int;
  -- ===== (D1) CHANGED FOR PHASE 3 E2 (end) =====
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to start a game.';
  end if;

  -- ===== (D2) CHANGED FOR PHASE 3 E2 (start) =====
  -- THE TABLE LOCK, before anything is read: the same lock joining
  -- (assign_table_seat) and seat moves (set_seat) take, so a Start can never
  -- overlap a join, a leave's seat being retaken, or a seat move -- the
  -- roster and the seats read below are final until this transaction ends.
  -- It also serializes two simultaneous Starts at the table: the second
  -- waits here, then finds the first one's game exactly as it did before
  -- (the live-game handlers below). Nothing is checked yet, so the guards
  -- and their messages run in the same order as before; a table id that
  -- doesn't exist simply locks nothing.
  select t.status, t.max_players
  into v_status, v_max
  from public.tables t
  where t.id = p_table_id
  for no key update;
  -- ===== (D2) CHANGED FOR PHASE 3 E2 (end) =====

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

  -- ===== (D3) CHANGED FOR PHASE 3 E2 (start) =====
  -- Guard 3: the table itself must still be open -- read from the row
  -- locked above (same message as before).
  if v_status is distinct from 'open' then
    raise exception 'This table is no longer open.';
  end if;

  -- Guard 4: exactly the table's size seated -- 2, 3 or 4 (tables.max_players;
  -- every table made before Phase 3 is a 2-player table, so this reads
  -- "exactly 2" for them, with the same message as before). An over-full
  -- table from before E1 is refused here too.
  --
  -- PLAYERS IN SEAT ORDER, not join order: seat 1, 2, 3, 4, which is
  -- clockwise. Everything that follows the players array -- the deal, the
  -- next dealer, who leads -- goes clockwise from it. In a 2-player game the
  -- order changes nothing (see the header).
  select array_agg(tm.user_id order by tm.seat)
  into v_players
  from public.table_members tm
  where tm.table_id = p_table_id;

  v_player_count := coalesce(array_length(v_players, 1), 0);

  if v_player_count <> coalesce(v_max, 2) then
    raise exception 'A game needs exactly % players at the table (currently %).', coalesce(v_max, 2), v_player_count;
  end if;
  -- ===== (D3) CHANGED FOR PHASE 3 E2 (end) =====

  -- ===== (M2) CHANGED FROM SLICE 5 (start) =====
  -- THE PREVIOUS MATCH: the most recent game at this table, whatever its
  -- status. Scalars rather than a record, so "no previous game" is simply
  -- three nulls and every test below reads false.
  -- ===== (N2) CHANGED FROM BATCH 2b (start) =====
  -- Also the previous game's id (the row the ready gate locks) and its
  -- ready_by. With no previous game, these are nulls too.
  select g.ended_reason, g.winner_id, g.players, g.id, g.ready_by
  into v_prev_reason, v_prev_winner, v_prev_players, v_prev_id, v_prev_ready
  -- ===== (N2) CHANGED FROM BATCH 2b (end) =====
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
    -- ===== (D4) CHANGED FOR PHASE 3 E2 (start) =====
    -- THE LOSER who deals: the player in the next seat clockwise from the
    -- winner. In 2 players that is simply the other player, as before. In 4
    -- (Teams) the next seat is always on the other team, whichever partner
    -- is recorded as the winner; in 3 it is the player on the winner's
    -- left. (A decision flagged for review: see the header.)
    v_winner_pos := array_position(v_players, v_prev_winner);
    v_loser := v_players[(v_winner_pos % v_player_count) + 1];
    -- ===== (D4) CHANGED FOR PHASE 3 E2 (end) =====
  end if;

  if v_loser is not null then
    -- A rematch: the loser deals the first hand. No cut is needed, so this
    -- path deals immediately and goes straight to 'active' -- the same state
    -- a resolved cut leaves (see the top of this file).
    v_dealer := v_loser;
  -- ===== (M2) CHANGED FROM SLICE 5 (end) =====

    -- ===== (N3) CHANGED FROM BATCH 2b (start) =====
    -- THE NEW GAME READY GATE. Only on this path -- a won match between the
    -- same players, which is the one path that would otherwise deal at once
    -- without the other player doing anything. Every other path is a cut
    -- for deal, which already needs both players to draw.
    --
    -- Every player in the WON game's players array must have tapped New
    -- Game ("players <@ ready_by", the same rule as next_hand) -- not a
    -- hard-coded 2.

    -- THE LOCK: the won game's row. Two taps arriving together are taken one
    -- at a time: the first records itself, the second sees it and (if that
    -- completes the set) starts the match. Re-reads ready_by under the lock,
    -- since the value read above may be stale.
    select g.ready_by
    into v_prev_ready
    from public.games g
    where g.id = v_prev_id
    for update;

    -- A tap that arrives after the match has started -- e.g. it waited on the
    -- lock while the other player's tap started it. Return that game; record
    -- nothing, reset nothing.
    select g.id
    into v_live
    from public.games g
    where g.table_id = p_table_id
      and g.status in ('cutting', 'active');

    if v_live is not null then
      return v_live;
    end if;

    -- Already ready: quiet. A double tap, a retry, a second tab.
    if v_caller = any(v_prev_ready) then
      return null;
    end if;

    v_ready := array_append(v_prev_ready, v_caller);

    update public.games
    set ready_by = v_ready
    where id = v_prev_id;

    -- Not everyone yet: return NULL -- "recorded, waiting". Nothing is
    -- created or dealt, and the scores stay where the match ended (the
    -- reset below is never reached).
    if not (v_prev_players <@ v_ready) then
      return null;
    end if;

    -- Everyone is ready: fall through to the unchanged start below. The won
    -- game keeps its full ready_by -- it's history, and it is no longer the
    -- table's most recent game once the new one is inserted.
    -- ===== (N3) CHANGED FROM BATCH 2b (end) =====

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

    -- ===== (D5) CHANGED FOR PHASE 3 E2 (start) =====
    -- 3 and 4 players: only the HOST starts a match that cuts for deal (the
    -- first game, or after one that ended without a winner). 2 players:
    -- anyone at the table, as before. A rematch after a win (the branch
    -- above) needs every player's tap instead, for any number of players.
    if coalesce(v_max, 2) > 2 and public.table_host(p_table_id) is distinct from v_caller then
      raise exception 'Only the host can start the game.';
    end if;
    -- ===== (D5) CHANGED FOR PHASE 3 E2 (end) =====
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
revoke all on function public.start_game_with_deal(uuid) from anon;
grant execute on function public.start_game_with_deal(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 2. deal_cards_for_game -- 6 cards each for 2 players, 5 for 3 and 4, and
-- the 3-player crib card. Still not client-callable: only
-- start_game_with_deal, acknowledge_deal_cut and next_hand call it.
-- ---------------------------------------------------------------------------
create or replace function public.deal_cards_for_game(p_game_id uuid)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_players uuid[];
  v_deck text[];
  -- ===== (C1) CHANGED FOR PHASE 3 E2 (start) =====
  v_count int;
  v_size int;
  v_dealt int;
  -- ===== (C1) CHANGED FOR PHASE 3 E2 (end) =====
begin
  select g.players
  into v_players
  from public.games g
  where g.id = p_game_id;

  -- ===== (C2) CHANGED FOR PHASE 3 E2 (start) =====
  -- 2, 3 or 4 players, in the order of the players array (seat order for
  -- every game made from E2 on).
  v_count := coalesce(array_length(v_players, 1), 0);

  if v_count not between 2 and 4 then
    raise exception 'Cannot deal: game % does not have 2 to 4 recorded players.', p_game_id;
  end if;

  v_deck := public.shuffled_deck();

  -- 6 cards each for 2 players; 5 each for 3 and 4 (PRD Section 7, item 23).
  -- Player i gets the i-th block of the shuffled deck -- for 2 players
  -- exactly the cards as before: v_deck[1:6] and v_deck[7:12].
  v_size := case when v_count = 2 then 6 else 5 end;

  for i in 1 .. v_count loop
    insert into public.game_hands (game_id, user_id, cards)
    values (p_game_id, v_players[i], v_deck[(i - 1) * v_size + 1 : i * v_size])
    on conflict (game_id, user_id) do nothing;
  end loop;

  v_dealt := v_count * v_size;

  -- 3 players: the next card goes face down into the crib, so the crib is
  -- 3 discards + 1 = 4. It sits in game_cribs like any crib card, under the
  -- same read rules (nobody until the crib's count); discard_to_crib appends
  -- the discards to it and shuffles the crib when it is complete.
  if v_count = 3 then
    insert into public.game_cribs (game_id, cards)
    values (p_game_id, array[v_deck[v_dealt + 1]])
    on conflict (game_id) do nothing;

    v_dealt := v_dealt + 1;
  end if;

  -- The rest (40 for 2 players, 36 for 3, 32 for 4). The starter is cut from
  -- here once everyone has discarded.
  insert into public.game_decks (game_id, cards)
  values (p_game_id, v_deck[v_dealt + 1 : 52])
  on conflict (game_id) do nothing;
  -- ===== (C2) CHANGED FOR PHASE 3 E2 (end) =====
end;
$$;

revoke all on function public.deal_cards_for_game(uuid) from public;
revoke all on function public.deal_cards_for_game(uuid) from anon;
revoke all on function public.deal_cards_for_game(uuid) from authenticated;


-- ---------------------------------------------------------------------------
-- 3. discard_to_crib -- 2 cards with 2 players, 1 with 3 and 4; the
-- player on the dealer's left leads.
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
  -- ===== (X1) CHANGED FOR PHASE 3 E2 (start) =====
  v_discards int;
  -- ===== (X1) CHANGED FOR PHASE 3 E2 (end) =====
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to discard.';
  end if;

  -- ===== (X2) CHANGED FOR PHASE 3 E2 (start) =====
  -- Guard 2: exactly 2 distinct cards with 2 players, exactly 1 with 3 or 4
  -- (PRD Section 7, item 23). The number of players is read first, without
  -- the lock (the players array never changes once a game exists); a game
  -- that can't be found counts as 2-player, so every refusal a 2-player
  -- game gave before -- message and order -- is unchanged.
  select coalesce(array_length(g.players, 1), 2)
  into v_discards
  from public.games g
  where g.id = p_game_id;

  v_discards := case when v_discards in (3, 4) then 1 else 2 end;

  if array_length(p_cards, 1) is distinct from v_discards then
    if v_discards = 1 then
      raise exception 'You must discard exactly 1 card.';
    end if;
    raise exception 'You must discard exactly 2 cards.';
  end if;

  if v_discards = 2 and p_cards[1] = p_cards[2] then
    raise exception 'You must discard 2 different cards.';
  end if;
  -- ===== (X2) CHANGED FOR PHASE 3 E2 (end) =====

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
        -- ===== (X3) CHANGED FOR PHASE 3 E2 (start) =====
        -- The player on the dealer's LEFT leads: the next seat clockwise,
        -- wrapping from the last seat back to the first. With 2 players that
        -- is the non-dealer, as before. (The old rule stays as the fallback
        -- for the defensive case of no dealer.)
        current_player = coalesce(
          v_game.players[(array_position(v_game.players, v_game.dealer_id)
                          % array_length(v_game.players, 1)) + 1],
          (
            select u
            from unnest(v_game.players) as u
            where u is distinct from v_game.dealer_id
            limit 1
          )
        ),
        -- ===== (X3) CHANGED FOR PHASE 3 E2 (end) =====
        play_count = 0,
        play_segment = 0
    where id = p_game_id;
  end if;
end;
$$;

revoke all on function public.discard_to_crib(uuid, text[]) from public;
revoke all on function public.discard_to_crib(uuid, text[]) from anon;
grant execute on function public.discard_to_crib(uuid, text[]) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. next_hand -- a full hand is 5 cards for 3 and 4 players.
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
  -- ===== (H1) CHANGED FOR PHASE 3 E2 (start) =====
  -- A full hand is 6 cards with 2 players, 5 with 3 or 4. (Nothing else in
  -- next_hand changes: the gate on the counting being done is E4's, and the
  -- rotation above already goes to the next player in the players array --
  -- which is SEAT order, i.e. clockwise, for every game started from E2 on.)
  select count(*)
  into v_hands_dealt
  from public.game_hands gh
  where gh.game_id = p_game_id
    and coalesce(array_length(gh.cards, 1), 0) = case when v_player_count = 2 then 6 else 5 end;
  -- ===== (H1) CHANGED FOR PHASE 3 E2 (end) =====

  if v_hands_dealt <> v_player_count then
    raise exception 'Next hand dealt % full hands for % players.', v_hands_dealt, v_player_count;
  end if;
end;
$$;

revoke all on function public.next_hand(uuid, int) from public;
revoke all on function public.next_hand(uuid, int) from anon;
grant execute on function public.next_hand(uuid, int) to authenticated;
