-- Slice 9 (Phase 2, first slice): shuffle and deal a 2-player hand
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.

-- Cards are stored as 2-character codes: rank (A,2-9,T,J,Q,K) + suit (S,H,D,C).
-- e.g. 'AS' = ace of spades, 'TD' = ten of diamonds, '7H' = seven of hearts.
-- Readable directly in the Table Editor, which matters more than compactness
-- at 52 cards.

-- Who deals. Unused this slice, but discarding to the crib and turn order both
-- need it, and adding a column now (while games are disposable) is easier than
-- backfilling later. Populated with a random pick of the two players for now --
-- real cribbage cuts for the lowest card, which is a deliberate future slice.
alter table public.games
  add column dealer_id uuid references auth.users (id);

-- One row per player per game. The cards a single player is holding.
create table public.game_hands (
  game_id uuid not null references public.games (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  cards text[] not null,
  dealt_at timestamptz not null default now(),
  primary key (game_id, user_id)
);

alter table public.game_hands enable row level security;

-- THE privacy guarantee for this slice. Note this is much stricter than every
-- previous SELECT policy in this project (all of which were
-- "auth.role() = 'authenticated'" -- any logged-in user reads everything).
-- This one filters per row: asking for another player's hand returns zero rows
-- rather than an error, the same silent-filter behaviour as the Slice 7 RLS test.
--
-- Future "Show Hand" (PRD Section 6, item 8) loosens this to something like
--   using (user_id = auth.uid() or revealed)
-- plus a boolean column -- deliberately kept to a one-line change.
create policy "Players can only read their own hand"
  on public.game_hands for select
  using (user_id = auth.uid());

-- No insert/update/delete policy: with RLS on and no matching policy, Postgres
-- denies by default. Only the security definer function below writes hands.

-- The undealt remainder of the deck. This is as sensitive as the hands
-- themselves: in a 2-player game 52 - 6 - 6 = 40 cards remain, so a player who
-- could read the remainder would subtract their own 6 and know their
-- opponent's hand exactly by elimination. That is why this cannot live on
-- public.games -- games has a permissive "any authenticated user can select"
-- policy from Slice 5, which would hand the whole remainder to both players.
create table public.game_decks (
  game_id uuid primary key references public.games (id) on delete cascade,
  cards text[] not null
);

alter table public.game_decks enable row level security;

-- Deliberately ZERO policies -- not even select. RLS on + no policy = deny by
-- default for every regular user (same lockdown used for admin_users writes in
-- Slice 7). Only security definer functions can reach this table.

-- Creating a game and dealing must be one atomic action, so a game can never
-- exist in a "created but no cards" state that reconnection, the admin view,
-- and every later Phase 2 slice would each have to defend against. Dropping
-- Slice 5's direct-insert policy makes this function the ONLY way to create a
-- game -- previously a player could insert a cardless game row via the API.
drop policy "Table members can start a game" on public.games;

-- security definer means this runs with the privileges of its owner (you, via
-- the SQL Editor) rather than the caller -- required, since it writes to
-- game_hands and game_decks, which deny writes to everyone. That elevated
-- privilege is exactly why the function must do its OWN authorization checks:
-- RLS is not protecting these statements, so the guards below are the only
-- thing standing between a caller and someone else's table.
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

  -- Random dealer for now. Cut-for-lowest-card is a real requirement but an
  -- explicitly separate slice.
  v_dealer := v_players[1 + floor(random() * 2)::int];

  -- Shuffle a full 52-card deck. The cross join builds all 13 x 4 combinations;
  -- "order by random()" inside array_agg assigns each row a fresh random sort
  -- key, producing a uniformly random permutation.
  select array_agg(c.card order by random())
  into v_deck
  from (
    select r.rank_code || s.suit_code as card
    from unnest(array['A','2','3','4','5','6','7','8','9','T','J','Q','K']) as r(rank_code)
    cross join unnest(array['S','H','D','C']) as s(suit_code)
  ) c;

  -- Create the game. If two players tap "New Game" at the same instant, one
  -- loses Slice 5's games_one_active_per_table unique index -- catch that and
  -- hand back the winner's game instead of erroring, matching the behaviour
  -- the client used to implement itself.
  begin
    insert into public.games (table_id, created_by, dealer_id)
    values (p_table_id, v_caller, v_dealer)
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

  -- The remaining 40 cards, kept for the future cut-for-starter and play phase.
  insert into public.game_decks (game_id, cards)
  values (v_game_id, v_deck[13:52]);

  return v_game_id;
end;
$$;

-- Postgres grants EXECUTE on new functions to PUBLIC by default. That matters
-- more than usual for a security definer function, so narrow it explicitly:
-- signed-out callers are already rejected by Guard 1, but there is no reason
-- to let them reach the function body at all.
revoke all on function public.start_game_with_deal(uuid) from public;
grant execute on function public.start_game_with_deal(uuid) to authenticated;
