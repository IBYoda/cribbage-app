-- Phase 2, Slice 5: cut for deal happens BEFORE any cards are dealt
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- CORRECTION to slices 4/4b. Those computed the dealer and dealt every card in
-- one transaction, then replayed the cut as a ceremony on top. Per the official
-- rules (docs/CribbageBasics.pdf) the real order is: cut for deal -> shuffle ->
-- deal. Nothing may be dealt until the cut, including any tie redraws, has
-- fully resolved.
--
-- The cut is now drawn ON DEMAND: no card exists until a player taps the deck,
-- and no dealer is known until a round completes with a unique lowest card.
--
-- STATEMENT ORDER MATTERS in this file: the new function bodies must exist
-- before deal_cut_round is dropped at the end, or the old bodies would
-- reference a column that no longer exists.


-- ---------------------------------------------------------------------------
-- 1. Roster snapshot.
--
-- Needed because dealing now happens in a DIFFERENT function, LATER, than the
-- one that created the game. Re-reading table_members at deal time could pick
-- up a roster that changed in between.
--
-- It also solves a subtler problem: with rounds filled progressively, a round
-- in flight has fewer entries than there are players, so the round's own length
-- can no longer serve as the "how many players must act" denominator.
-- ---------------------------------------------------------------------------
alter table public.games
  add column players uuid[];

-- Backfill historical games from the hands actually dealt, so old rows are
-- consistent rather than half-populated. Nullable on purpose: a game that never
-- got as far as dealing has no hands to derive a roster from.
update public.games g
set players = sub.players
from (
  select gh.game_id, array_agg(gh.user_id order by gh.dealt_at) as players
  from public.game_hands gh
  group by gh.game_id
) sub
where sub.game_id = g.id
  and g.players is null;


-- ---------------------------------------------------------------------------
-- 2. A game mid-cut is LIVE, and must block a second "New Game" at the table.
--
-- games.status has no check constraint (Slice 5 created it as bare text), so
-- 'cutting' needs no constraint change -- but the unique index does. As it
-- stood it only covered status = 'active', so a game mid-cut would not have
-- blocked a second game being created at the same table.
-- ---------------------------------------------------------------------------
drop index if exists public.games_one_active_per_table;

create unique index games_one_live_per_table
  on public.games (table_id)
  where status in ('cutting', 'active');


-- ---------------------------------------------------------------------------
-- 3. Dealing, extracted.
--
-- Called from two places now: immediately at creation when the deal simply
-- alternates (no cut needed), and from acknowledge_deal_cut when a cut
-- resolves. Reads the roster from games.players rather than table_members --
-- see the note on that column above.
--
-- Deliberately NOT security definer and NOT granted to anyone: it is only ever
-- called from inside the security definer functions below, where it already
-- runs with the owner's privileges. Leaving it ungranted keeps PostgREST from
-- exposing it as a callable endpoint at all.
--
-- The ON CONFLICT clauses make it idempotent, so a retry can never double-deal.
-- ---------------------------------------------------------------------------
create or replace function public.deal_cards_for_game(p_game_id uuid)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_players uuid[];
  v_deck text[];
begin
  select g.players
  into v_players
  from public.games g
  where g.id = p_game_id;

  if v_players is null or array_length(v_players, 1) <> 2 then
    raise exception 'Cannot deal: game % does not have exactly 2 recorded players.', p_game_id;
  end if;

  v_deck := public.shuffled_deck();

  -- 6 cards each for 2-player cribbage (PRD Section 7).
  insert into public.game_hands (game_id, user_id, cards)
  values
    (p_game_id, v_players[1], v_deck[1:6]),
    (p_game_id, v_players[2], v_deck[7:12])
  on conflict (game_id, user_id) do nothing;

  -- The remaining 40. The starter is cut from here once both players discard.
  insert into public.game_decks (game_id, cards)
  values (p_game_id, v_deck[13:52])
  on conflict (game_id) do nothing;
end;
$$;

revoke all on function public.deal_cards_for_game(uuid) from public;


-- ---------------------------------------------------------------------------
-- 4. Starting a game.
--
-- NAMING NOTE: this is still called start_game_with_deal, but it now only
-- deals on the alternating path. On the cut path it creates a game in
-- 'cutting' with no cards and no dealer. Left renamed-for-later rather than
-- renaming now, which would mean a coordinated client change.
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
  v_prev_dealer uuid;
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

  -- CHANGED: skip games that never reached a dealer. dealer_id is now null for
  -- the whole 'cutting' phase, so an abandoned cut would otherwise be read as
  -- "the last dealer was nobody" and force a fresh cut instead of alternating.
  select g.dealer_id
  into v_prev_dealer
  from public.games g
  where g.table_id = p_table_id
    and g.dealer_id is not null
  order by g.created_at desc
  limit 1;

  if v_prev_dealer is not null and v_prev_dealer = any(v_players) then
    -- Subsequent game: the deal passes to whoever did not deal last. No cut is
    -- needed, so this path deals immediately and goes straight to 'active'.
    --
    -- KNOWN LIMITATION (unchanged): one games row is currently one HAND. When
    -- the multi-round loop is built, this lookup must move to "previous round
    -- within this game".
    select u
    into v_dealer
    from unnest(v_players) as u
    where u <> v_prev_dealer
    limit 1;

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
    -- First game at this table -- or the previous dealer has since left -- so
    -- the deal must be cut for.
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

  return v_game_id;
end;
$$;

revoke all on function public.start_game_with_deal(uuid) from public;
grant execute on function public.start_game_with_deal(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. THE DRAW. One card, decided at the instant the player taps the deck.
--
-- Why this cannot be client-side, in order of severity:
--
--   1. A client-chosen card is simply cheating -- pick an ace and always deal,
--      or a king and never deal. Worse than the client-shuffle problem from
--      slice 1, because it is a single card with a directly chosen outcome.
--   2. Recording it means UPDATE on games, and RLS is ROW-level: a policy
--      letting players write their game's row exposes every column on it,
--      including dealer_id and status.
--   3. The cards within one round must be DISTINCT -- two players cannot both
--      cut the 7H. Enforcing that means reading what has already been drawn and
--      excluding it: a read-then-write that is only safe under a lock.
--   4. The draw that fills the round is also what decides the dealer. Split
--      across statements, a failure between them leaves a complete round with
--      no verdict.
--
-- Returns the drawn card so the client can flip the tapped card to reveal it.
-- ---------------------------------------------------------------------------
create or replace function public.draw_cut_card(p_game_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
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

revoke all on function public.draw_cut_card(uuid) from public;
grant execute on function public.draw_cut_card(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 6. THE GATE. Both players must acknowledge a completed round before anything
-- moves -- and on a decisive round, that acknowledgement is what deals.
--
-- Reworked from slice 4b: it no longer walks a pre-computed history. It either
-- opens a fresh empty round (tie) or deals and goes live (decisive).
-- ---------------------------------------------------------------------------
create or replace function public.acknowledge_deal_cut(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
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

revoke all on function public.acknowledge_deal_cut(uuid) from public;
grant execute on function public.acknowledge_deal_cut(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 7. Leaving mid-cut must end the game too.
--
-- Only the status filter changed: without 'cutting', walking away during the
-- cut would leave a live game with a departed player, which nothing else would
-- ever clean up.
-- ---------------------------------------------------------------------------
create or replace function public.leave_table(p_table_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
begin
  if v_caller is null then
    raise exception 'You must be logged in to leave a table.';
  end if;

  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = p_table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not a member of this table.';
  end if;

  update public.games
  set status = 'ended', ended_reason = 'player_left'
  where table_id = p_table_id
    and status in ('cutting', 'active');

  delete from public.table_members
  where table_id = p_table_id
    and user_id = v_caller;
end;
$$;

revoke all on function public.leave_table(uuid) from public;
grant execute on function public.leave_table(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 8. The timeout sweep must reach cutting games.
--
-- Without this a game abandoned mid-cut -- one player walking away during a
-- tie, which is exactly the scenario the 5-hour timeout exists for -- would
-- never expire and would block that table's index slot forever.
-- ---------------------------------------------------------------------------
create or replace function public.end_timed_out_sessions()
returns void
language sql
security definer
set search_path = public
as $$
  update public.games
  set status = 'ended', ended_reason = 'timeout'
  where status in ('cutting', 'active')
    and created_at < now() - interval '5 hours';

  update public.tables
  set status = 'ended', ended_reason = 'timeout'
  where status = 'open'
    and created_at < now() - interval '12 hours';

  update public.games
  set status = 'ended', ended_reason = 'timeout'
  where status in ('cutting', 'active')
    and table_id in (select id from public.tables where status <> 'open');
$$;


-- ---------------------------------------------------------------------------
-- 9. Drop the now-redundant round pointer. LAST, so every function body above
-- has already been replaced with one that does not reference it.
--
-- The current round is always the final element of deal_cut, so a separate
-- index was duplicate state that could disagree with the history itself.
-- ---------------------------------------------------------------------------
alter table public.games
  drop column deal_cut_round;


-- ---------------------------------------------------------------------------
-- Optional checks.
-- ---------------------------------------------------------------------------

-- Expect exactly one index, games_one_live_per_table, covering cutting+active:
-- select indexname, indexdef from pg_indexes
-- where schemaname = 'public' and tablename = 'games';

-- Expect players populated on historical rows, deal_cut_round gone:
-- select id, status, dealer_id, players, jsonb_array_length(deal_cut) as cut_rounds
-- from public.games order by created_at desc limit 10;
