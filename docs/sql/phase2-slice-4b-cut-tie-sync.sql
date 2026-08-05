-- Phase 2, Slice 4b: cut-for-deal round history + synchronised tie redraws
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- Two changes, both to the cut-for-deal work from slice 4:
--
--   1. Tied rounds are now RECORDED rather than discarded. The previous
--      generator looped until it drew two different ranks and stored only the
--      winning pair -- every tie was drawn, compared and thrown away, so
--      players never saw one. deal_cut now holds the full round history.
--
--   2. A tie round only advances once BOTH players have hit Redraw. That needs
--      server-synced state, because two independent browsers otherwise have no
--      way to agree on which round they are looking at.
--
-- What has NOT changed: the whole sequence is still resolved atomically inside
-- start_game_with_deal, and the dealer is still decided at that moment. Redraw
-- is a synchronisation gate over an already-decided outcome, never a new draw.


-- ---------------------------------------------------------------------------
-- SHAPE CHANGE + MIGRATION -- read before running.
--
-- deal_cut changes from a single pair:
--     [{"user_id": "...", "card": "4D"}, {"user_id": "...", "card": "JS"}]
-- to an array of rounds, the last of which is the decisive one:
--     [[{...},{...}],            <- tied round
--      [{...},{...}]]            <- decisive round
--
-- Any deal_cut already in the table is in the OLD shape and must be wrapped in
-- one more array level, or the client will read a round where it expects a
-- list of rounds.
--
-- The update below detects the old shape structurally rather than by date or
-- id: in the old shape the first element is a JSON *object*; in the new shape
-- it is an *array*. That also makes this statement safe to re-run -- after it
-- has applied once, nothing matches it again.
--
-- In practice this only touches a handful of test games, and only an ACTIVE
-- game would ever be rendered (refreshTableState fetches active games only) --
-- but leaving two shapes in one column is the kind of thing that produces a
-- confusing bug months later, so it is worth normalising now.
-- ---------------------------------------------------------------------------

update public.games
set deal_cut = jsonb_build_array(deal_cut)
where deal_cut is not null
  and jsonb_typeof(deal_cut -> 0) = 'object';


-- Which round of the cut both clients are currently showing (0-based index
-- into deal_cut). Advances only when every player has acknowledged.
alter table public.games
  add column deal_cut_round int not null default 0;

-- Who has hit Redraw on THAT round -- not what they drew. Deliberately the
-- same uuid[] shape as discarded_by, which already solves this exact problem
-- ("who has acted, readable by everyone, carries no card data") and is proven
-- in this codebase.
--
-- Kept in its own column rather than folded into deal_cut so that deal_cut is
-- strictly immutable after game creation: mixing the decided history with
-- mutable acknowledgements would mean rewriting the whole history blob on every
-- click, giving a bug the chance to silently rewrite what cards were cut.
alter table public.games
  add column deal_cut_ack_by uuid[] not null default '{}';


-- ---------------------------------------------------------------------------
-- start_game_with_deal -- now records every round, including ties.
--
-- Identical to the slice-4 version except for the cut block. Guards 1-4, the
-- alternation branch, the deal itself and the unique-violation handling are
-- all unchanged.
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
  v_rounds jsonb := '[]'::jsonb;
  v_attempts int := 0;
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

  -- Guard 4: this slice is 2-player only (3/4-player dealing is Phase 3).
  select array_agg(tm.user_id order by tm.joined_at)
  into v_players
  from public.table_members tm
  where tm.table_id = p_table_id;

  v_player_count := coalesce(array_length(v_players, 1), 0);

  if v_player_count <> 2 then
    raise exception 'A game needs exactly 2 players at the table (currently %).', v_player_count;
  end if;

  select g.dealer_id
  into v_prev_dealer
  from public.games g
  where g.table_id = p_table_id
  order by g.created_at desc
  limit 1;

  if v_prev_dealer is not null and v_prev_dealer = any(v_players) then
    -- Subsequent game at this table: the deal passes to whoever did NOT deal
    -- last time. No cut, so deal_cut stays null and no overlay is shown.
    --
    -- KNOWN LIMITATION (unchanged): one games row is currently one HAND,
    -- because there is no round loop yet. When the multi-round loop is built,
    -- this lookup must move to "previous round within this game".
    select u
    into v_dealer
    from unnest(v_players) as u
    where u <> v_prev_dealer
    limit 1;

    v_deal_cut := null;
  else
    -- First game at this table -- or the previous dealer has since left --
    -- so cut for it: lowest card deals, ace low.
    --
    -- CHANGED: every round is now appended to v_rounds, including tied ones.
    -- The append happens BEFORE the exit test, so the decisive round is the
    -- last element and any ties precede it in draw order.
    loop
      v_attempts := v_attempts + 1;

      -- Unreachable in practice -- 50 consecutive ties is roughly a 1-in-10^61
      -- event -- but an unbounded loop inside a transaction is worth a ceiling.
      if v_attempts > 50 then
        raise exception 'Could not resolve the cut for deal after % attempts.', v_attempts;
      end if;

      v_cut_deck := public.shuffled_deck();
      v_cut_a := v_cut_deck[1];
      v_cut_b := v_cut_deck[2];

      v_rounds := v_rounds || jsonb_build_array(
        jsonb_build_array(
          jsonb_build_object('user_id', v_players[1], 'card', v_cut_a),
          jsonb_build_object('user_id', v_players[2], 'card', v_cut_b)
        )
      );

      -- Rejection sampling: a tie means "cut again", which is the actual
      -- cribbage rule (suit does not break ties) and keeps this unbiased.
      exit when public.card_rank_value(v_cut_a) <> public.card_rank_value(v_cut_b);
    end loop;

    -- v_cut_a / v_cut_b still hold the decisive (last, non-tied) pair.
    if public.card_rank_value(v_cut_a) < public.card_rank_value(v_cut_b) then
      v_dealer := v_players[1];
    else
      v_dealer := v_players[2];
    end if;

    v_deal_cut := v_rounds;
  end if;

  v_deck := public.shuffled_deck();

  -- deal_cut_round and deal_cut_ack_by rely on their column defaults (0, '{}').
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

  insert into public.game_hands (game_id, user_id, cards)
  values
    (v_game_id, v_players[1], v_deck[1:6]),
    (v_game_id, v_players[2], v_deck[7:12]);

  insert into public.game_decks (game_id, cards)
  values (v_game_id, v_deck[13:52]);

  return v_game_id;
end;
$$;

revoke all on function public.start_game_with_deal(uuid) from public;
grant execute on function public.start_game_with_deal(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- acknowledge_deal_cut -- the synchronisation gate.
--
-- Why security definer rather than an RLS-guarded UPDATE, given there is no
-- secret data here: RLS is ROW-level, not column-level. games currently has no
-- player-facing UPDATE policy at all (only Slice 7's admin-only one), and
-- adding "a player may update their own game's row" would grant write access to
-- EVERY column on it -- dealer_id, status, starter_card, discarded_by,
-- ended_reason. The acknowledgement is innocuous; the mechanism needed to allow
-- it client-side is not.
--
-- It also needs two dependent writes to be atomic: record the ack, and if that
-- was the last one, advance the round and clear the acks.
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
  v_acks uuid[];
  v_player_count int;
  v_total_rounds int;
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to redraw.';
  end if;

  -- THE ROW LOCK. Both players can hit Redraw at the same instant, and both
  -- need to append to deal_cut_ack_by. Without this, each could read the
  -- pre-update array, both append their own id, and one write would be lost --
  -- leaving one ack recorded, the round never advancing, and BOTH players
  -- stuck permanently with no way to self-correct. That is a harder failure
  -- than the discard race, which only stalled the crib.
  select g.id, g.table_id, g.status, g.deal_cut, g.deal_cut_round, g.deal_cut_ack_by
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

  -- Guard 3 (the membership check): the caller must be sitting at this table.
  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = v_game.table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not a member of this table.';
  end if;

  -- Guard 4: nothing to acknowledge on a game whose deal simply alternated.
  if v_game.deal_cut is null then
    raise exception 'This game had no cut for deal.';
  end if;

  v_total_rounds := jsonb_array_length(v_game.deal_cut);

  -- The final round is the decisive one -- there is no next round to advance
  -- to, so acknowledging it is a no-op rather than an error. Returning quietly
  -- keeps a double-click or a stale client harmless.
  if v_game.deal_cut_round >= v_total_rounds - 1 then
    return;
  end if;

  -- Idempotent: clicking twice, or a retried request, changes nothing.
  if v_caller = any(v_game.deal_cut_ack_by) then
    return;
  end if;

  v_acks := v_game.deal_cut_ack_by || v_caller;

  -- Count hands dealt for THIS game rather than current table members, for the
  -- same reason discard_to_crib does: someone joining the table mid-game must
  -- not raise the denominator and strand the sequence.
  select count(*)
  into v_player_count
  from public.game_hands gh
  where gh.game_id = p_game_id;

  if coalesce(array_length(v_acks, 1), 0) >= v_player_count then
    -- Everyone has redrawn. Advancing the round and clearing the acks MUST be
    -- one statement -- a leftover ack would otherwise carry into the next round
    -- and let a single click advance it.
    update public.games
    set deal_cut_round = deal_cut_round + 1,
        deal_cut_ack_by = '{}'
    where id = p_game_id;
  else
    update public.games
    set deal_cut_ack_by = v_acks
    where id = p_game_id;
  end if;
end;
$$;

revoke all on function public.acknowledge_deal_cut(uuid) from public;
grant execute on function public.acknowledge_deal_cut(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- Optional check: confirm the migration produced a uniform shape. Every
-- non-null deal_cut should report 'array' for its first element.
-- ---------------------------------------------------------------------------

-- select id,
--        jsonb_typeof(deal_cut -> 0) as first_element_type,  -- expect 'array'
--        jsonb_array_length(deal_cut) as rounds,
--        deal_cut_round,
--        deal_cut_ack_by
-- from public.games
-- where deal_cut is not null
-- order by created_at desc;
