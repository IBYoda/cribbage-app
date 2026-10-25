-- Computer opponent, C1: the "_as" refactor (NO behaviour change)
-- Run this in the Supabase Dashboard -> SQL Editor, AFTER every phase3-e*
-- file (live). Kept here for reference/history; this project has no
-- Supabase CLI/migrations set up yet.
--
-- WHAT IT DOES. For each of the eight functions a player calls during a
-- 2-player game, taken from its NEWEST definition (the file named below --
-- each body's md5 is the one phase3-e4-counting-verification.sql expects):
--   start_game_with_deal(uuid)             uuid  from phase3-e2-dealing.sql
--   draw_cut_card(uuid)                    text  from phase2-slice-5-cut-before-deal.sql
--   acknowledge_deal_cut(uuid)             void  from phase2-slice-5-cut-before-deal.sql
--   discard_to_crib(uuid, text[])          void  from phase3-e2-dealing.sql
--   play_card(uuid, text)                  void  from phase3-e3-pegging.sql
--   show_crib(uuid)                        void  from phase3-e4-counting.sql
--   confirm_count(uuid, int)               void  from phase3-e4-counting.sql
--   next_hand(uuid, int)                   void  from phase3-e2-dealing.sql
--
--   1. public.<name>_as(p_actor uuid, <the same params>): the existing body,
--      byte for byte, except the header (the new name and p_actor first) and
--      the ONE place the body reads the caller's identity:
--   start_game_with_deal_as    line 8 of 254: "v_caller uuid := auth.uid();" -> "v_caller uuid := p_actor;"
--   draw_cut_card_as           line 8 of 115: "v_caller uuid := auth.uid();" -> "v_caller uuid := p_actor;"
--   acknowledge_deal_cut_as    line 8 of 101: "v_caller uuid := auth.uid();" -> "v_caller uuid := p_actor;"
--   discard_to_crib_as         line 8 of 218: "v_caller uuid := auth.uid();" -> "v_caller uuid := p_actor;"
--   play_card_as               line 8 of 305: "v_caller uuid := auth.uid();" -> "v_caller uuid := p_actor;"
--   show_crib_as               line 8 of 79: "v_caller uuid := auth.uid();" -> "v_caller uuid := p_actor;"
--   confirm_count_as           line 8 of 231: "v_caller uuid := auth.uid();" -> "v_caller uuid := p_actor;"
--   next_hand_as               line 8 of 171: "v_caller uuid := auth.uid();" -> "v_caller uuid := p_actor;"
--      Every body was searched for auth.uid(), auth.role(), any jwt or
--      current_setting read, session_user and current_user: that declare line
--      is the only one in each, and nothing else changed. The functions they
--      call (award_points, deal_cards_for_game, table_host, has_legal_play,
--      score_hand, score_pegging, card_play_value, card_rank_value,
--      shuffled_deck) read no caller identity either -- they take the player
--      as an argument -- so nothing below them needs to change.
--      Internal: EXECUTE revoked from PUBLIC, anon and authenticated
--      (Postgres grants EXECUTE to PUBLIC on every new function, and Slice
--      6b's default-privilege change covers anon and authenticated only).
--      The owner, which the security definer wrappers run as, keeps it.
--
--   2. public.<name>(<params>): the SAME name, signature, return type,
--      language, security definer and search_path, now a thin wrapper that
--      calls <name>_as(auth.uid(), ...). A null caller is refused exactly as
--      before, with the same text, because the refusal is still the first
--      thing the body does ("You must be logged in to ..."). CREATE OR
--      REPLACE keeps each wrapper's owner and grants exactly as they are --
--      no grant or revoke touches them here.
--
-- NOTHING ELSE: no table, column, policy, trigger or other function changes.
-- One transaction: if any statement fails, nothing is applied.
--
-- ROLLBACK: docs/sql/computer-c1-rollback.sql (restores today's eight
-- definitions verbatim and drops the eight _as functions).
-- CHECKS: docs/sql/computer-c1-verification.sql.
--
-- KNOWN SIDE EFFECT ON THE OLD SUITES: the existing verification files
-- fingerprint function bodies (md5) in their first section. After this file
-- the eight public bodies are wrappers, so those fingerprint checks fail by
-- design (phase3-e4-counting-verification.sql at S2, S3 and S4). The C1
-- verification proves the bodies moved unchanged instead.

begin;

-- ===========================================================================
-- 1. start_game_with_deal (from phase3-e2-dealing.sql)
-- ===========================================================================
create or replace function public.start_game_with_deal_as(p_actor uuid, p_table_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := p_actor;
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

revoke all on function public.start_game_with_deal_as(uuid, uuid) from public;
revoke all on function public.start_game_with_deal_as(uuid, uuid) from anon;
revoke all on function public.start_game_with_deal_as(uuid, uuid) from authenticated;

create or replace function public.start_game_with_deal(p_table_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.start_game_with_deal_as(auth.uid(), p_table_id);
end;
$$;

-- ===========================================================================
-- 2. draw_cut_card (from phase2-slice-5-cut-before-deal.sql)
-- ===========================================================================
create or replace function public.draw_cut_card_as(p_actor uuid, p_game_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := p_actor;
  v_game record;
  v_round jsonb;
  v_round_index int;
  v_drawn text[];
  v_card text;
  v_player_count int;
  v_lowest_count int;
begin
  if v_caller is null then
    raise exception 'You must be logged in to cut for deal.';
  end if;

  -- THE ROW LOCK. Two players can tap at the same instant, and both append to
  -- the same round. Without this each could read the round pre-append, both
  -- write, and one draw would be lost -- and worse, both could be handed the
  -- same card, since the distinctness check below reads that same array.
  select g.id, g.table_id, g.status, g.deal_cut, g.players
  into v_game
  from public.games g
  where g.id = p_game_id
  for update;

  if not found then
    raise exception 'Game not found.';
  end if;

  if v_game.status <> 'cutting' then
    raise exception 'This game is not cutting for deal.';
  end if;

  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = v_game.table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not a member of this table.';
  end if;

  -- Checked against the roster snapshot, not current membership: only the
  -- players this game was created for may cut for its deal.
  if v_game.players is null or not (v_caller = any(v_game.players)) then
    raise exception 'You are not a player in this game.';
  end if;

  v_player_count := coalesce(array_length(v_game.players, 1), 0);

  -- The round in progress is always the last element -- there is no separate
  -- round pointer to drift out of sync with the history.
  v_round_index := jsonb_array_length(v_game.deal_cut) - 1;
  v_round := v_game.deal_cut -> v_round_index;

  if exists (
    select 1
    from jsonb_array_elements(v_round) e
    where (e ->> 'user_id')::uuid = v_caller
  ) then
    raise exception 'You have already cut for this round.';
  end if;

  select coalesce(array_agg(e ->> 'card'), '{}')
  into v_drawn
  from jsonb_array_elements(v_round) e;

  -- shuffled_deck() is a uniformly random permutation, so the first card not
  -- already taken this round is a uniform pick from what remains.
  select t.card
  into v_card
  from unnest(public.shuffled_deck()) as t(card)
  where not (t.card = any(v_drawn))
  limit 1;

  v_round := v_round || jsonb_build_object('user_id', v_caller, 'card', v_card);

  update public.games
  set deal_cut = jsonb_set(deal_cut, array[v_round_index::text], v_round)
  where id = p_game_id;

  -- If that filled the round, decide it now, in the same transaction.
  if jsonb_array_length(v_round) = v_player_count then
    -- "Decisive" means exactly one player holds the lowest rank. Written this
    -- way rather than comparing two cards so it stays correct for 3-4 players
    -- in Phase 3, where ties among the NON-lowest cards are irrelevant.
    select count(*)
    into v_lowest_count
    from jsonb_array_elements(v_round) e
    where public.card_rank_value(e ->> 'card') = (
      select min(public.card_rank_value(e2 ->> 'card'))
      from jsonb_array_elements(v_round) e2
    );

    if v_lowest_count = 1 then
      update public.games
      set dealer_id = (
        select (e ->> 'user_id')::uuid
        from jsonb_array_elements(v_round) e
        order by public.card_rank_value(e ->> 'card') asc
        limit 1
      )
      where id = p_game_id;
    end if;
    -- A tie leaves dealer_id null; acknowledge_deal_cut opens a fresh round.
  end if;

  return v_card;
end;
$$;

revoke all on function public.draw_cut_card_as(uuid, uuid) from public;
revoke all on function public.draw_cut_card_as(uuid, uuid) from anon;
revoke all on function public.draw_cut_card_as(uuid, uuid) from authenticated;

create or replace function public.draw_cut_card(p_game_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.draw_cut_card_as(auth.uid(), p_game_id);
end;
$$;

-- ===========================================================================
-- 3. acknowledge_deal_cut (from phase2-slice-5-cut-before-deal.sql)
-- ===========================================================================
create or replace function public.acknowledge_deal_cut_as(p_actor uuid, p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := p_actor;
  v_game record;
  v_round jsonb;
  v_round_index int;
  v_player_count int;
  v_acks uuid[];
  v_lowest_count int;
begin
  if v_caller is null then
    raise exception 'You must be logged in to continue.';
  end if;

  -- Same lock, same reason: two simultaneous acknowledgements would otherwise
  -- lose one append, leaving the round permanently one short of advancing and
  -- both players stuck with no way to self-correct.
  select g.id, g.table_id, g.status, g.deal_cut, g.deal_cut_ack_by, g.players
  into v_game
  from public.games g
  where g.id = p_game_id
  for update;

  if not found then
    raise exception 'Game not found.';
  end if;

  if v_game.status <> 'cutting' then
    raise exception 'This game is not cutting for deal.';
  end if;

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

  v_player_count := coalesce(array_length(v_game.players, 1), 0);
  v_round_index := jsonb_array_length(v_game.deal_cut) - 1;
  v_round := v_game.deal_cut -> v_round_index;

  -- Nothing to acknowledge until everyone has actually cut.
  if jsonb_array_length(v_round) <> v_player_count then
    raise exception 'Everyone must cut before this round can be resolved.';
  end if;

  -- Idempotent: a double-click or a retried request changes nothing.
  if v_caller = any(v_game.deal_cut_ack_by) then
    return;
  end if;

  v_acks := v_game.deal_cut_ack_by || v_caller;

  if coalesce(array_length(v_acks, 1), 0) < v_player_count then
    update public.games
    set deal_cut_ack_by = v_acks
    where id = p_game_id;
    return;
  end if;

  -- Everyone has acknowledged.
  select count(*)
  into v_lowest_count
  from jsonb_array_elements(v_round) e
  where public.card_rank_value(e ->> 'card') = (
    select min(public.card_rank_value(e2 ->> 'card'))
    from jsonb_array_elements(v_round) e2
  );

  if v_lowest_count = 1 then
    -- Decisive. THIS is the moment cards may finally be dealt -- and it happens
    -- in the same transaction as the acknowledgement, so a "cut resolved but
    -- nothing dealt" state cannot exist for anyone to reconnect into.
    perform public.deal_cards_for_game(p_game_id);

    update public.games
    set status = 'active',
        deal_cut_ack_by = '{}'
    where id = p_game_id;
  else
    -- Tie. Open a fresh empty round and clear the acks in one statement -- a
    -- leftover ack would let a single click advance the next round.
    update public.games
    set deal_cut = deal_cut || '[[]]'::jsonb,
        deal_cut_ack_by = '{}'
    where id = p_game_id;
  end if;
end;
$$;

revoke all on function public.acknowledge_deal_cut_as(uuid, uuid) from public;
revoke all on function public.acknowledge_deal_cut_as(uuid, uuid) from anon;
revoke all on function public.acknowledge_deal_cut_as(uuid, uuid) from authenticated;

create or replace function public.acknowledge_deal_cut(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.acknowledge_deal_cut_as(auth.uid(), p_game_id);
end;
$$;

-- ===========================================================================
-- 4. discard_to_crib (from phase3-e2-dealing.sql)
-- ===========================================================================
create or replace function public.discard_to_crib_as(p_actor uuid, p_game_id uuid, p_cards text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := p_actor;
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

revoke all on function public.discard_to_crib_as(uuid, uuid, text[]) from public;
revoke all on function public.discard_to_crib_as(uuid, uuid, text[]) from anon;
revoke all on function public.discard_to_crib_as(uuid, uuid, text[]) from authenticated;

create or replace function public.discard_to_crib(p_game_id uuid, p_cards text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.discard_to_crib_as(auth.uid(), p_game_id, p_cards);
end;
$$;

-- ===========================================================================
-- 5. play_card (from phase3-e3-pegging.sql)
-- ===========================================================================
create or replace function public.play_card_as(p_actor uuid, p_game_id uuid, p_card text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := p_actor;
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

revoke all on function public.play_card_as(uuid, uuid, text) from public;
revoke all on function public.play_card_as(uuid, uuid, text) from anon;
revoke all on function public.play_card_as(uuid, uuid, text) from authenticated;

create or replace function public.play_card(p_game_id uuid, p_card text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.play_card_as(auth.uid(), p_game_id, p_card);
end;
$$;

-- ===========================================================================
-- 6. show_crib (from phase3-e4-counting.sql)
-- ===========================================================================
create or replace function public.show_crib_as(p_actor uuid, p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := p_actor;
  v_game record;
  -- ===== (S1) CHANGED FOR PHASE 3 E4 (start) =====
  v_n int;
  -- ===== (S1) CHANGED FOR PHASE 3 E4 (end) =====
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to show the crib.';
  end if;

  -- THE ROW LOCK.
  select g.id, g.table_id, g.status, g.phase, g.players, g.dealer_id,
         g.count_step, g.crib_revealed
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

  -- Guard 3 (membership).
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

  -- Guard 4: the crib is the dealer's to show. Before the idempotency return,
  -- so a non-dealer gets a real error rather than a silent no-op.
  if v_game.dealer_id is distinct from v_caller then
    raise exception 'Only the dealer can show the crib.';
  end if;

  -- Idempotent.
  if v_game.crib_revealed then
    return;
  end if;

  -- ===== (S2) CHANGED FOR PHASE 3 E4 (start) =====
  -- Guard 5: only after every hand is counted -- the crib is step N, after
  -- the N hands (step 2 with 2 players, as before). The 2-player message is
  -- unchanged, word for word.
  v_n := coalesce(array_length(v_game.players, 1), 2);

  if v_game.phase <> 'counting' or v_game.count_step <> v_n then
    if v_n = 2 then
      raise exception 'The crib is shown after both hands have been counted.';
    end if;
    raise exception 'The crib is shown after every hand has been counted.';
  end if;
  -- ===== (S2) CHANGED FOR PHASE 3 E4 (end) =====

  update public.games
  set crib_revealed = true
  where id = p_game_id;
end;
$$;

revoke all on function public.show_crib_as(uuid, uuid) from public;
revoke all on function public.show_crib_as(uuid, uuid) from anon;
revoke all on function public.show_crib_as(uuid, uuid) from authenticated;

create or replace function public.show_crib(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.show_crib_as(auth.uid(), p_game_id);
end;
$$;

-- ===========================================================================
-- 7. confirm_count (from phase3-e4-counting.sql)
-- ===========================================================================
create or replace function public.confirm_count_as(p_actor uuid, p_game_id uuid, p_step int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := p_actor;
  v_game record;
  v_current_step int;
  v_is_crib boolean;
  v_cards text[];
  v_score jsonb;
  v_points int;
  v_parts text[] := '{}';
  v_reason text;
  -- ===== (K1) CHANGED FOR PHASE 3 E4 (start) =====
  -- N, the number of players: steps 0 .. N-1 are the N hands, step N the
  -- crib. And the dealer's place in players (seat order, clockwise).
  v_n int;
  v_dpos int;
  -- ===== (K1) CHANGED FOR PHASE 3 E4 (end) =====
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to confirm a count.';
  end if;

  -- ===== (K2) CHANGED FOR PHASE 3 E4 (start) =====
  -- Guard 2: a step that cannot exist in this game -- 0 .. N, the N hands
  -- and then the crib. Whether it is behind or ahead is judged later,
  -- against the locked row. N is read first, without the lock (the players
  -- array never changes once a game exists); a game that can't be found
  -- counts as 2-player, so every refusal a 2-player game gave before --
  -- message and order -- is unchanged (the same approach as E2's
  -- discard_to_crib).
  select coalesce(array_length(g.players, 1), 2)
  into v_n
  from public.games g
  where g.id = p_game_id;

  v_n := coalesce(v_n, 2);

  if p_step is null or p_step < 0 or p_step > v_n then
    raise exception 'Invalid count step %.', p_step;
  end if;
  -- ===== (K2) CHANGED FOR PHASE 3 E4 (end) =====

  -- THE ROW LOCK. Both players could act at once (the pone confirming while
  -- the dealer taps Show Crib, a double tap from either), and every check
  -- below reads state the update at the end depends on.
  select g.id, g.table_id, g.status, g.phase, g.players, g.dealer_id,
         g.starter_card, g.current_player, g.count_step, g.revealed_by,
         g.crib_revealed
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

  -- Guard 4 (membership).
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

  -- Guard 5: phase and step. 'done' counts as step 3 -- past every step -- so
  -- a late duplicate of the crib confirm is quiet, not an error.
  if v_game.phase = 'counting' then
    v_current_step := v_game.count_step;
  elsif v_game.phase = 'done' then
    -- ===== (K3) CHANGED FOR PHASE 3 E4 (start) =====
    -- Past every step: N + 1 (3 with 2 players, as before).
    v_current_step := v_n + 1;
    -- ===== (K3) CHANGED FOR PHASE 3 E4 (end) =====
  else
    raise exception 'This game is not in the counting phase.';
  end if;

  if p_step < v_current_step then
    return;
  end if;

  if p_step > v_current_step then
    raise exception 'That count is not up yet.';
  end if;

  -- From here on: phase = 'counting' and p_step = count_step.

  -- Guard 6 (turn enforcement): only the player whose count is up.
  if v_game.current_player is distinct from v_caller then
    raise exception 'It is not your turn to count.';
  end if;

  -- ===== (K4) CHANGED FOR PHASE 3 E4 (start) =====
  -- Guard 7 (defensive): current_player must agree with the counting order
  -- -- step k is the hand of the (k+1)-th player clockwise from the dealer,
  -- so the dealer's own hand is step N-1 and the crib (the dealer's) step N.
  -- Cannot fail if only these functions write the row; it is here to catch
  -- a bad backfill or a hand-edited test row before it scores the wrong
  -- cards. With 2 players the first two conditions are the old guard
  -- exactly (step 0 the pone, steps 1 and 2 the dealer) and the third never
  -- applies.
  v_dpos := array_position(v_game.players, v_game.dealer_id);

  if (v_game.count_step = 0 and v_caller = v_game.dealer_id)
     or (v_game.count_step >= v_n - 1 and v_caller is distinct from v_game.dealer_id)
     or (v_n > 2
         and v_game.count_step < v_n - 1
         and v_caller is distinct from v_game.players[((v_dpos + v_game.count_step) % v_n) + 1]) then
  -- ===== (K4) CHANGED FOR PHASE 3 E4 (end) =====
    raise exception 'Counting state is inconsistent: step % does not belong to this player.',
      v_game.count_step;
  end if;

  -- Guard 8: a count needs the starter.
  if v_game.starter_card is null then
    raise exception 'There is no starter card to count with.';
  end if;

  -- ===== (K5) CHANGED FOR PHASE 3 E4 (start) =====
  -- The crib is the last step, N (2 with 2 players, as before).
  v_is_crib := (v_game.count_step = v_n);
  -- ===== (K5) CHANGED FOR PHASE 3 E4 (end) =====

  if v_is_crib then
    -- Guard 9: the crib must have been shown first (show_crib).
    if not v_game.crib_revealed then
      raise exception 'Show the crib before confirming its count.';
    end if;

    select c.cards
    into v_cards
    from public.game_cribs c
    where c.game_id = p_game_id;
  else
    select gh.cards
    into v_cards
    from public.game_hands gh
    where gh.game_id = p_game_id
      and gh.user_id = v_caller;
  end if;

  -- Guard 10: exactly four cards -- see WHAT GETS SCORED above.
  if coalesce(array_length(v_cards, 1), 0) <> 4 then
    raise exception '% has % cards; a count needs exactly 4.',
      case when v_is_crib then 'The crib' else 'Your hand' end,
      coalesce(array_length(v_cards, 1), 0);
  end if;

  -- AUTO-REVEAL (design decision 8). Counting a hand shows it -- you cannot
  -- confirm a hand the table has not seen. The crib is already shown by
  -- Guard 9. Done before the award so a WINNING hand is still on the table.
  if not v_is_crib and not (v_caller = any(v_game.revealed_by)) then
    update public.games
    set revealed_by = array_append(revealed_by, v_caller)
    where id = p_game_id;
  end if;

  -- SCORE. p_is_crib changes only the flush rule (crib: 5-card flush only).
  v_score := public.score_hand(v_cards, v_game.starter_card, v_is_crib);
  v_points := (v_score ->> 'points')::int;

  -- The reason, e.g. "hand: 15s 4 · pairs 2 · runs 3" -- the tracker shows it
  -- as "+9 — hand: 15s 4 · pairs 2 · runs 3". Zero components are omitted;
  -- a hand worth nothing reads "hand: nothing". array_append throughout
  -- (Batch 1's 22P02 lesson).
  if (v_score ->> 'fifteens')::int > 0 then
    v_parts := array_append(v_parts, ('15s ' || (v_score ->> 'fifteens'))::text);
  end if;
  if (v_score ->> 'pairs')::int > 0 then
    v_parts := array_append(v_parts, ('pairs ' || (v_score ->> 'pairs'))::text);
  end if;
  if (v_score ->> 'runs')::int > 0 then
    v_parts := array_append(v_parts, ('runs ' || (v_score ->> 'runs'))::text);
  end if;
  if (v_score ->> 'flush')::int > 0 then
    v_parts := array_append(v_parts, ('flush ' || (v_score ->> 'flush'))::text);
  end if;
  if (v_score ->> 'nobs')::int > 0 then
    v_parts := array_append(v_parts, ('nobs ' || (v_score ->> 'nobs'))::text);
  end if;

  v_reason := (case when v_is_crib then 'crib: ' else 'hand: ' end)
              || coalesce(nullif(array_to_string(v_parts, ' · '), ''), 'nothing');

  -- THE SINGLE AWARD. To the caller: the hand's owner at steps 0 and 1, and
  -- the dealer -- who owns the crib in 2-player -- at step 2 (Guard 7).
  perform public.award_points(v_game.table_id, v_caller, v_points, v_reason);

  -- ADVANCE, only if that award did not just end the game. count_step,
  -- current_player and phase move together, in one statement each way.
  -- ===== (K6) CHANGED FOR PHASE 3 E4 (start) =====
  -- The next count is the next player clockwise -- and the dealer's for the
  -- dealer's own hand (step N-1) and the crib (step N). With 2 players both
  -- of those are the only next steps, so it is the dealer, as before.
  if v_game.count_step < v_n then
    update public.games
    set count_step = v_game.count_step + 1,
        current_player = case
          when v_game.count_step + 1 >= v_n - 1 then v_game.dealer_id
          else v_game.players[((v_dpos + v_game.count_step + 1) % v_n) + 1]
        end
    where id = p_game_id
      and status = 'active';
  -- ===== (K6) CHANGED FOR PHASE 3 E4 (end) =====
  else
    update public.games
    set phase = 'done',
        current_player = null
    where id = p_game_id
      and status = 'active';
  end if;
end;
$$;

revoke all on function public.confirm_count_as(uuid, uuid, int) from public;
revoke all on function public.confirm_count_as(uuid, uuid, int) from anon;
revoke all on function public.confirm_count_as(uuid, uuid, int) from authenticated;

create or replace function public.confirm_count(p_game_id uuid, p_step int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.confirm_count_as(auth.uid(), p_game_id, p_step);
end;
$$;

-- ===========================================================================
-- 8. next_hand (from phase3-e2-dealing.sql)
-- ===========================================================================
create or replace function public.next_hand_as(p_actor uuid, p_game_id uuid, p_hand_no int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := p_actor;
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

revoke all on function public.next_hand_as(uuid, uuid, int) from public;
revoke all on function public.next_hand_as(uuid, uuid, int) from anon;
revoke all on function public.next_hand_as(uuid, uuid, int) from authenticated;

create or replace function public.next_hand(p_game_id uuid, p_hand_no int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.next_hand_as(auth.uid(), p_game_id, p_hand_no);
end;
$$;

commit;
