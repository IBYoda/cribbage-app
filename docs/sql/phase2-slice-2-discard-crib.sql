-- Phase 2, Slice 2: discard to the crib
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- (Filename uses the per-phase numbering agreed in cribbage-app-handoff.md.
-- The previous file is still named slice-9-deal-cards.sql, from before that.)

-- Who has discarded yet -- NOT what they discarded. Card content stays in
-- game_cribs below; this column only records that a player has acted, which is
-- public knowledge in a real game (you can watch someone put cards down).
--
-- This column exists because the UI genuinely cannot work without it: a player
-- has no other readable signal that their opponent has discarded. game_cribs is
-- unreadable (below), and the opponent's game_hands row is filtered out by that
-- table's per-user SELECT policy. It also rides the existing realtime
-- publication on games, so the waiting state propagates live with no new plumbing.
alter table public.games
  add column discarded_by uuid[] not null default '{}';

-- The crib: 4 cards for a 2-player game, owned by the dealer, revealed only at
-- counting time (a later slice).
--
-- Stored as ONE merged array with no per-player attribution, and shuffled once
-- complete. A per-player game_discards table would permanently record who
-- contributed which cards. In 2-player the dealer can always deduce the
-- opponent's two by elimination, so that part is inherent to cribbage -- but in
-- Phase 3's 3/4-player games, attribution would leak third-party information no
-- player should have. Unshuffled append order reconstructs the same thing, hence
-- the shuffle in the function below.
create table public.game_cribs (
  game_id uuid primary key references public.games (id) on delete cascade,
  cards text[] not null default '{}'
);

alter table public.game_cribs enable row level security;

-- Deliberately ZERO policies, exactly like game_decks in the previous slice.
-- RLS on + no policy = deny by default for every regular user, including the
-- dealer: the crib is not readable by anyone until the counting-phase reveal
-- slice adds a "revealed" flag and a policy for the dealer.

-- security definer: runs as the function owner (you, via the SQL Editor) rather
-- than the caller. Required, because game_cribs denies writes to everyone.
--
-- ON THE ROW LOCK AND RLS -- see "select ... for update" below.
--
-- The lock is NOT blocked or filtered by the RLS policies on public.games, for
-- one specific reason: a table's owner bypasses RLS unless the table has
-- FORCE ROW LEVEL SECURITY set, and this function executes as its owner (the
-- same role that owns these tables). We have never set FORCE RLS on any table
-- in this project, so policies simply do not apply inside this function body.
--
-- That is load-bearing, not incidental. If RLS *did* apply here, TWO statements
-- in this function would fail for an ordinary player:
--
--   1. "select ... for update" -- Postgres applies the UPDATE policy's USING
--      clause to locking selects, not just the SELECT policy, because taking a
--      row lock implies intent to update. The only UPDATE policy on games is
--      Slice 7's admin-only one, so a non-admin would lock zero rows.
--   2. "update public.games set discarded_by = ..." -- blocked by that same
--      admin-only UPDATE policy.
--
-- Both work here purely because ownership bypasses RLS. And because RLS is not
-- protecting any of this, the guards below are the ONLY thing standing between
-- a caller and a corrupted game.
--
-- You can verify both facts yourself -- see the two queries at the bottom of
-- this file.
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
  -- hold. This is the guard a client-side UPDATE could never provide -- RLS
  -- governs which ROWS you may write, not which VALUES are legitimate, so a
  -- direct update policy would have let a player rewrite their hand to any
  -- cards they liked. "<@" is array containment: every element of p_cards must
  -- appear in v_hand.
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

  -- Append to the crib. Upsert rather than requiring the row to pre-exist, so
  -- this also works for any game dealt before this slice was applied.
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

  -- Once everyone has discarded, shuffle the crib so its order no longer
  -- reveals who contributed which cards (see the table comment above).
  if coalesce(array_length(v_discarded, 1), 0) = v_player_count then
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
  end if;
end;
$$;

-- Same narrowing as start_game_with_deal: Postgres grants EXECUTE to PUBLIC by
-- default, which matters more than usual for a security definer function.
revoke all on function public.discard_to_crib(uuid, text[]) from public;
grant execute on function public.discard_to_crib(uuid, text[]) to authenticated;


-- ---------------------------------------------------------------------------
-- Verification for the RLS / row-lock claim above. Run these after the rest of
-- the file; they only read catalog metadata and change nothing.
-- ---------------------------------------------------------------------------

-- Expect: rowsecurity = true for all, force_rls = FALSE for all, and owner
-- identical to the function owner below. force_rls = false is what allows the
-- owner (and therefore the security definer function) to bypass the policies.
-- select
--   c.relname                      as table_name,
--   c.relrowsecurity               as rls_enabled,
--   c.relforcerowsecurity          as force_rls,
--   pg_get_userbyid(c.relowner)    as owner
-- from pg_class c
-- join pg_namespace n on n.oid = c.relnamespace
-- where n.nspname = 'public'
--   and c.relname in ('games', 'game_hands', 'game_decks', 'game_cribs')
-- order by c.relname;

-- Expect: prosecdef = true, and owner matching the table owner above.
-- select
--   p.proname                      as function_name,
--   p.prosecdef                    as security_definer,
--   pg_get_userbyid(p.proowner)    as owner
-- from pg_proc p
-- join pg_namespace n on n.oid = p.pronamespace
-- where n.nspname = 'public'
--   and p.proname in ('discard_to_crib', 'start_game_with_deal', 'end_timed_out_sessions')
-- order by p.proname;
