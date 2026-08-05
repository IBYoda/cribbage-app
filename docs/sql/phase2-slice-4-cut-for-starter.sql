-- Phase 2, Slice 4: real dealer selection + cut for the starter card
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- Replaces two placeholders:
--   Part A -- the random dealer pick in start_game_with_deal (Phase 2 Slice 1)
--   Part B -- there was no starter card at all; the round went straight from
--             discard to nothing.


-- ---------------------------------------------------------------------------
-- Columns. BOTH of these are public information, which is exactly why they can
-- live on public.games: it already has a permissive "any logged-in user can
-- select" policy from Slice 5.
--
-- This is the mirror image of every other piece of card state in Phase 2.
-- game_hands, game_decks and game_cribs each needed their OWN table with
-- restrictive (or zero) policies precisely BECAUSE games is world-readable --
-- putting secret cards here would have handed them to everyone. The starter
-- card and the cut-for-deal result are meant to be seen by everyone, so the
-- policy that disqualified games for secrets is the correct one here.
--
-- No new RLS is needed for either column, and both ride the existing realtime
-- UPDATE broadcast on games with no new plumbing.
-- ---------------------------------------------------------------------------

-- The two cards drawn when cutting for first deal, e.g.
--   [{"user_id": "...", "card": "4D"}, {"user_id": "...", "card": "JS"}]
-- NULL for any game where the deal simply alternated (no cut happened).
-- jsonb rather than two columns so this scales unchanged to 3- and 4-player
-- tables in Phase 3.
alter table public.games
  add column deal_cut jsonb;

-- The starter/cut card, revealed to everyone after both players discard.
alter table public.games
  add column starter_card text;


-- ---------------------------------------------------------------------------
-- Helpers. Neither touches a table, so neither needs security definer, and
-- default EXECUTE grants are deliberately left in place: card_rank_value is
-- pure arithmetic on a string, and shuffled_deck returns a random permutation
-- that corresponds to nothing in the database. Narrowing them would add a
-- failure mode for future callers while protecting nothing.
-- ---------------------------------------------------------------------------

-- Extracted from start_game_with_deal so the deal and the cut-for-deal can
-- share one definition instead of duplicating the 13x4 cross join.
create or replace function public.shuffled_deck()
returns text[]
language sql
volatile
as $$
  select array_agg(c.card order by random())
  from (
    select r.rank_code || s.suit_code as card
    from unnest(array['A','2','3','4','5','6','7','8','9','T','J','Q','K']) as r(rank_code)
    cross join unnest(array['S','H','D','C']) as s(suit_code)
  ) c;
$$;

-- ORDINAL rank for comparison: A=1 .. K=13. Ace is LOW when cutting for deal.
--
-- Note this is NOT the same as a card's counting value for scoring, where
-- T/J/Q/K are all worth 10 and ace is 1. The scoring slice will need its own
-- separate helper -- these two must not be conflated.
create or replace function public.card_rank_value(p_card text)
returns int
language sql
immutable
as $$
  select array_position(
    array['A','2','3','4','5','6','7','8','9','T','J','Q','K'],
    substr(p_card, 1, 1)
  );
$$;


-- ---------------------------------------------------------------------------
-- PART A: real dealer selection.
--
-- Unchanged from the previous version except for the dealer block and the use
-- of shuffled_deck(). Guards 1-4 are identical.
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
  v_deck text[];
  v_prev_dealer uuid;
  v_cut_deck text[];
  v_cut_a text;
  v_cut_b text;
  v_deal_cut jsonb;
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to start a game.';
  end if;

  -- Guard 2 (the membership check): the caller must actually be sitting at
  -- this table. Without this, any logged-in user could deal into any table
  -- they had never joined, just by calling this function with its id.
  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = p_table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not a member of this table.';
  end if;

  -- Guard 3: the table itself must still be open (not admin-ended or timed out).
  if not exists (
    select 1
    from public.tables t
    where t.id = p_table_id
      and t.status = 'open'
  ) then
    raise exception 'This table is no longer open.';
  end if;

  -- Guard 4: this slice is 2-player only (3/4-player dealing is Phase 3).
  select array_agg(tm.user_id order by tm.joined_at)
  into v_players
  from public.table_members tm
  where tm.table_id = p_table_id;

  v_player_count := coalesce(array_length(v_players, 1), 0);

  if v_player_count <> 2 then
    raise exception 'A game needs exactly 2 players at the table (currently %).', v_player_count;
  end if;

  -- Who dealt most recently at this table? Any status -- the previous game has
  -- almost certainly ended by now.
  select g.dealer_id
  into v_prev_dealer
  from public.games g
  where g.table_id = p_table_id
  order by g.created_at desc
  limit 1;

  if v_prev_dealer is not null and v_prev_dealer = any(v_players) then
    -- Subsequent game at this table: standard cribbage passes the deal, so it
    -- goes to whoever did NOT deal last time. No cut.
    --
    -- KNOWN LIMITATION, worth being explicit about: one games row is currently
    -- one HAND, because there is no round loop yet. Real cribbage alternates
    -- the deal every hand within a match to 121, so "alternate between games"
    -- is doing the right thing only because game and hand are the same thing
    -- today. When the multi-round loop is built, this lookup must move to
    -- "previous round within this game" instead.
    select u
    into v_dealer
    from unnest(v_players) as u
    where u <> v_prev_dealer
    limit 1;

    v_deal_cut := null;
  else
    -- First game at this table -- or the previous dealer has since left, which
    -- makes "the other player" meaningless -- so cut for it: lowest card deals.
    --
    -- Rejection sampling: draw two cards, and on a tie draw again. That IS the
    -- cribbage rule ("cut again" -- suit does not break ties), and it keeps the
    -- result unbiased. ~5.9% chance of a tie, so this averages ~1.06 passes.
    --
    -- Note this deck is shuffled separately from the one dealt below, matching
    -- real play (you cut, then reshuffle and deal) and ensuring the cut cannot
    -- influence which cards anyone receives.
    loop
      v_cut_deck := public.shuffled_deck();
      v_cut_a := v_cut_deck[1];
      v_cut_b := v_cut_deck[2];
      exit when public.card_rank_value(v_cut_a) <> public.card_rank_value(v_cut_b);
    end loop;

    -- Ace low, so the smaller ordinal wins the deal.
    if public.card_rank_value(v_cut_a) < public.card_rank_value(v_cut_b) then
      v_dealer := v_players[1];
    else
      v_dealer := v_players[2];
    end if;

    v_deal_cut := jsonb_build_array(
      jsonb_build_object('user_id', v_players[1], 'card', v_cut_a),
      jsonb_build_object('user_id', v_players[2], 'card', v_cut_b)
    );
  end if;

  v_deck := public.shuffled_deck();

  -- Create the game. If two players tap "New Game" at the same instant, one
  -- loses Slice 5's games_one_active_per_table unique index -- catch that and
  -- hand back the winner's game instead of erroring.
  begin
    insert into public.games (table_id, created_by, dealer_id, deal_cut)
    values (p_table_id, v_caller, v_dealer, v_deal_cut)
    returning id into v_game_id;
  exception when unique_violation then
    select g.id into v_game_id
    from public.games g
    where g.table_id = p_table_id
      and g.status = 'active';
    return v_game_id;
  end;

  -- 6 cards each for 2-player cribbage (PRD Section 7).
  insert into public.game_hands (game_id, user_id, cards)
  values
    (v_game_id, v_players[1], v_deck[1:6]),
    (v_game_id, v_players[2], v_deck[7:12]);

  -- The remaining 40 cards. The starter is cut from here once both players
  -- have discarded (see discard_to_crib below).
  insert into public.game_decks (game_id, cards)
  values (v_game_id, v_deck[13:52]);

  return v_game_id;
end;
$$;

revoke all on function public.start_game_with_deal(uuid) from public;
grant execute on function public.start_game_with_deal(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- PART B: cut the starter card.
--
-- Unchanged from the previous version except for the new block at the end of
-- the "everyone has discarded" branch. All six guards and the row lock are
-- identical.
--
-- This happens here, server-side, rather than via a separate cut_starter RPC
-- the client calls on noticing completion: both clients would notice at the
-- same instant and both would call it, so that design would need its own race
-- guard and an extra round trip to do something the server already knows to do.
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
  -- to append to games.discarded_by and to the crib. Without this lock, two
  -- concurrent calls could each read the pre-update discarded_by and one
  -- append would be lost -- leaving a game that never reaches a complete crib.
  -- Locking the games row here serializes the two callers: the second waits
  -- until the first commits, then reads the updated value.
  --
  -- This lock now protects the starter cut too: it guarantees the completion
  -- branch below runs exactly once, so two simultaneous discards cannot cut
  -- two different starter cards.
  select g.id, g.table_id, g.status, g.discarded_by
  into v_game
  from public.games g
  where g.id = p_game_id
  for update;

  if not found then
    raise exception 'Game not found.';
  end if;

  -- Guard 3: the game must still be live (not admin-ended or timed out).
  if v_game.status <> 'active' then
    raise exception 'This game is no longer active.';
  end if;

  -- Guard 4 (the membership check): the caller must actually be sitting at the
  -- table this game belongs to.
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

  -- Guard 6 (the anti-cheat check): you can only discard cards you actually
  -- hold. RLS governs which ROWS you may write, not which VALUES are
  -- legitimate, so a direct update policy would have let a player rewrite
  -- their hand to any cards they liked. "<@" is array containment.
  if not (p_cards <@ v_hand) then
    raise exception 'You can only discard cards from your own hand.';
  end if;

  -- Remove the two discards, preserving the order of what remains.
  select coalesce(array_agg(t.c order by t.ord), '{}')
  into v_new_hand
  from unnest(v_hand) with ordinality as t(c, ord)
  where not (t.c = any(p_cards));

  update public.game_hands
  set cards = v_new_hand
  where game_id = p_game_id
    and user_id = v_caller;

  -- Append to the crib. Upsert rather than requiring the row to pre-exist.
  insert into public.game_cribs (game_id, cards)
  values (p_game_id, p_cards)
  on conflict (game_id) do update
  set cards = public.game_cribs.cards || excluded.cards;

  update public.games
  set discarded_by = discarded_by || v_caller
  where id = p_game_id;

  -- Count the hands dealt for THIS game rather than the table's current member
  -- count: a player joining the table mid-game would otherwise raise the
  -- denominator and the crib would never be considered complete.
  select count(*)
  into v_player_count
  from public.game_hands gh
  where gh.game_id = p_game_id;

  select g.discarded_by
  into v_discarded
  from public.games g
  where g.id = p_game_id;

  if coalesce(array_length(v_discarded, 1), 0) = v_player_count then
    -- Shuffle the crib so its order no longer reveals who contributed which
    -- cards.
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

    -- NEW: cut the starter card. The deck was already uniformly shuffled at
    -- deal time, so taking the top card is a fair cut -- no second randomiser
    -- needed.
    select d.cards
    into v_deck
    from public.game_decks d
    where d.game_id = p_game_id;

    if v_deck is not null and coalesce(array_length(v_deck, 1), 0) > 0 then
      v_starter := v_deck[1];

      -- Remove it from the deck: it genuinely is no longer in there. No
      -- privacy impact either way (game_decks has no read policy at all), but
      -- it keeps the data truthful for the future play phase.
      select array_agg(t.c order by t.ord)
      into v_new_deck
      from unnest(v_deck) with ordinality as t(c, ord)
      where t.c <> v_starter;

      update public.game_decks
      set cards = coalesce(v_new_deck, '{}')
      where game_id = p_game_id;

      -- "where starter_card is null" is belt-and-braces: the row lock above
      -- already guarantees this branch runs once, but this makes a double-cut
      -- impossible even if that ever changed.
      update public.games
      set starter_card = v_starter
      where id = p_game_id
        and starter_card is null;
    end if;
  end if;
end;
$$;

revoke all on function public.discard_to_crib(uuid, text[]) from public;
grant execute on function public.discard_to_crib(uuid, text[]) to authenticated;


-- ---------------------------------------------------------------------------
-- Deliberately NOT in this slice: "his heels" -- the dealer scoring 2 points
-- when the starter is a jack.
--
-- There is no score tracker, no scores table, and nowhere for those points to
-- go. Recording points that are never displayed would be worse than not
-- recording them: it is invisible state that could silently desync from the
-- physical board, which is the exact failure the PRD's score tracker exists to
-- prevent (Section 6, item 11; Section 8).
--
-- Deferring costs nothing because starter_card is stored: whenever the scoring
-- slice lands, "his heels" becomes a check for card_rank_value(starter_card)
-- = 11 and awarding the dealer 2. No information is lost by waiting.
-- ---------------------------------------------------------------------------
