-- Phase 2, Slice 7: the play (pegging) phase -- turns, legality, running count
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- DELIBERATELY NO SCORING. No points for fifteens, pairs, runs, go or 31.
-- This slice is "can players take turns playing cards correctly", not "do they
-- get points for it". The scoring slice will read the event log this creates.
--
-- NOTE ON GRANTS: this is the first slice built after Slice 6b flipped
-- schema public to deny-by-default for functions. An explicit
--     grant execute on function ... to authenticated;
-- is now REQUIRED for anything the client calls -- without it the function is
-- invisible to PostgREST. Internal helpers simply get no grant and are
-- unreachable by construction, which is the whole point of that change.


-- ---------------------------------------------------------------------------
-- 1. Card values for play.
--
-- Slice 4 left an explicit warning that card_rank_value (A=1 .. K=13, used to
-- compare cuts) is NOT a counting value. Pegging is the first thing that needs
-- the other one, so here it is. The two must never be conflated:
--
--   card_rank_value('KD') = 13   -- ordinal, for "who cut lower"
--   card_play_value('KD') = 10   -- counting value, for the run to 31
-- ---------------------------------------------------------------------------
create or replace function public.card_play_value(p_card text)
returns int
language sql
immutable
set search_path = public
as $$
  select case substr(p_card, 1, 1)
    when 'A' then 1
    when 'T' then 10
    when 'J' then 10
    when 'Q' then 10
    when 'K' then 10
    else substr(p_card, 1, 1)::int
  end;
$$;

-- No grant: the client computes card values in TypeScript for display, and the
-- only SQL caller is play_card below, which runs as owner.
revoke all on function public.card_play_value(text) from public;


-- ---------------------------------------------------------------------------
-- 2. The public record of what has been played.
--
-- This is the exact inverse of every other piece of card state in Phase 2.
-- game_hands, game_decks and game_cribs are secret, so each needed its own
-- table with restrictive or zero policies. A card on the table during play is
-- PUBLIC the instant it is played, so this one gets the permissive read policy
-- -- the same reasoning that put starter_card on games.
--
-- It is an event LOG, not just a list of cards: 'go' is recorded too. Without
-- that, the UI cannot explain why a turn bounced back (it would just look
-- broken), and the scoring slice needs it, since a go is worth a point.
-- ---------------------------------------------------------------------------
create table public.game_plays (
  game_id uuid not null references public.games (id) on delete cascade,
  -- Ordering within the whole phase. Assigned under the games row lock held by
  -- play_card, so there is no gap-or-collision race.
  seq int not null,
  -- Which run-to-31 this belongs to. Increments on every reset, so the client
  -- can lay out the current segment separately from earlier ones.
  segment int not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('play', 'go')),
  card text,
  -- The running count immediately after this event, so history can show the
  -- total beside each card without re-summing anything.
  count_after int not null,
  created_at timestamptz not null default now(),
  primary key (game_id, seq),
  constraint game_plays_card_matches_kind check (
    (kind = 'play' and card is not null) or (kind = 'go' and card is null)
  )
);

alter table public.game_plays enable row level security;

create policy "Played cards are viewable by any logged-in user"
  on public.game_plays for select
  using (auth.role() = 'authenticated');

-- No insert/update/delete policy: only play_card() writes here.

-- Live updates for both players as cards hit the table.
alter publication supabase_realtime add table public.game_plays;


-- ---------------------------------------------------------------------------
-- 3. Play state on games.
--
-- phase is a SEPARATE column from status, deliberately. status means "is this
-- game live" and is load-bearing in seven places (the whole cut-before-deal
-- touchpoint list); overloading it would reopen every one of those filters.
-- phase describes where WITHIN a live game we are, and nothing else reads it.
--
-- This reverses the Slice 4b decision not to add a phase column. That
-- reasoning held when there were two states and one was fully derivable from
-- discarded_by. There are now three, with counting sub-states right behind,
-- and without it the client would have to reimplement "have all eight cards
-- been played?" just to know what to render.
--
-- play_count and play_segment are stored rather than derived on the principle
-- that the CLIENT SHOULD BE A RENDERER, not a second implementation of the
-- rules. The server has to compute the count anyway to judge legality, and one
-- locked function owns every write, so drift is not possible.
-- ---------------------------------------------------------------------------
alter table public.games
  add column phase text not null default 'discard'
    check (phase in ('discard', 'play', 'counting')),
  -- Whose turn it is. Explicit rather than derived from "last player's
  -- opponent", because GO BREAKS ALTERNATION: after you go, your opponent may
  -- play several cards in a row. Derivation would be quietly wrong.
  add column current_player uuid references auth.users (id),
  add column play_count int not null default 0,
  add column play_segment int not null default 0;

-- Backfill existing rows. A live game that already has a starter card is, by
-- definition, past the discard phase.
update public.games
set phase = 'play'
where status = 'active'
  and starter_card is not null;

-- ...and give those games a turn holder, so an in-flight test game does not
-- land in the play phase with nobody able to act. The non-dealer leads.
update public.games g
set current_player = (
  select u
  from unnest(g.players) as u
  where u is distinct from g.dealer_id
  limit 1
)
where g.phase = 'play'
  and g.players is not null
  and g.current_player is null;


-- ---------------------------------------------------------------------------
-- 4. "Does this player have a legal card right now?"
--
-- THE BOUNDARY THIS ENCODES: auto-go fires only when this returns false --
-- i.e. ZERO legal cards. Having exactly one legal option is not a go; the
-- player still taps their own card. Nothing in this file ever selects or plays
-- a card on a player's behalf.
--
-- Called with p_count = 0 it answers a second question -- "do they hold any
-- unplayed cards at all?" -- since every card is playable onto an empty count.
-- ---------------------------------------------------------------------------
create or replace function public.has_legal_play(
  p_game_id uuid,
  p_user_id uuid,
  p_count int
)
returns boolean
language sql
stable
set search_path = public
as $$
  select exists (
    select 1
    from unnest((
      select gh.cards
      from public.game_hands gh
      where gh.game_id = p_game_id
        and gh.user_id = p_user_id
    )) as c(card)
    where public.card_play_value(c.card) <= 31 - p_count
      and not exists (
        select 1
        from public.game_plays gp
        where gp.game_id = p_game_id
          and gp.user_id = p_user_id
          and gp.kind = 'play'
          and gp.card = c.card
      )
  );
$$;

revoke all on function public.has_legal_play(uuid, uuid, int) from public;


-- ---------------------------------------------------------------------------
-- 5. Playing a card.
--
-- Same guard discipline and row lock as discard_to_crib. security definer
-- means RLS is not protecting any of these statements, so the guards are the
-- only thing between a caller and a corrupted game.
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

  -- -------------------------------------------------------------------------
  -- Resolve what happens next, in this same transaction.
  --
  -- No loop is needed, because a reset drops the count to 0 and every card is
  -- playable onto 0 -- so after a reset the only question left is who still
  -- holds cards.
  -- -------------------------------------------------------------------------

  if v_count = 31 then
    -- Exactly 31 ends the segment immediately. Nobody declares a go.
    -- (The 2 points for hitting 31 belong to the scoring slice.)
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
      -- (The 1 point for the go belongs to the scoring slice.)
      v_leader := v_opponent;
      v_count := 0;
      v_segment := v_segment + 1;
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
      update public.games
      set phase = 'counting',
          current_player = null,
          play_count = v_count,
          play_segment = v_segment
      where id = p_game_id;
      return;
    end if;
  end if;

  update public.games
  set current_player = v_leader,
      play_count = v_count,
      play_segment = v_segment
  where id = p_game_id;
end;
$$;

revoke all on function public.play_card(uuid, text) from public;
-- REQUIRED under the Slice 6b deny-by-default regime -- without this line the
-- client gets "Could not find the function".
grant execute on function public.play_card(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 6. Entering the play phase.
--
-- Identical to the Slice 4 version except for the block at the very end of the
-- "everyone has discarded" branch, plus dealer_id and players added to the
-- locked SELECT so the pone can be identified. All six guards, the row lock,
-- the crib shuffle and the starter cut are unchanged.
--
-- "create or replace" preserves the existing ACL, so this keeps its grant to
-- authenticated without needing one restated here.
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
-- Optional checks.
-- ---------------------------------------------------------------------------

-- Counting values -- expect A=1, 5=5, 9=9, T/J/Q/K all 10:
-- select c, public.card_play_value(c)
-- from unnest(array['AS','5H','9D','TC','JS','QH','KD']) as c;

-- Backfill result -- expect live games with a starter to be in 'play' with a
-- current_player set:
-- select id, status, phase, dealer_id, current_player, play_count, play_segment
-- from public.games order by created_at desc limit 10;

-- play_card must be callable by players; card_play_value and has_legal_play
-- must NOT be. Expect exactly one row, for play_card:
-- select routine_name, grantee, privilege_type
-- from information_schema.routine_privileges
-- where routine_schema = 'public'
--   and grantee = 'authenticated'
--   and routine_name in ('play_card', 'card_play_value', 'has_legal_play');
