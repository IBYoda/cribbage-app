-- Step 3, slice E: ROLLBACK of docs/sql/slice-e-part2.sql.
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet. Only if part 2 has to come out. Roll back
-- part 3 first if it was run (newest first).
--
-- WHAT IT DOES (one transaction) -- the exact state before part 2:
--   1. start_game_with_deal_as: today's body again, byte for byte
--      (docs/sql/computer-c1-refactor.sql; md5 8d6ceb9ba00b9f2b6b9b8613e10609df, the value
--      computer-c1-verification.sql expected before slice E -- put its two
--      start_game_with_deal values back to as_md5
--      8d6ceb9ba00b9f2b6b9b8613e10609df / orig_md5
--      3feaa7508cf434b4a3f8d78a8ad9896a), with its revokes.
--   2. Drops the profiles_nickname_lock trigger and its function.
--      profiles.nickname_changed_at stays (part 1's; its rollback drops it).
--   3. _follow_user_as and unfollow_user: today's bodies and comments again,
--      byte for byte (docs/sql/follows.sql; md5 9c2f318761d3110a1f67de73eb5d9be8 /
--      82fe22965cc8a28cc3812f029b470404). Their grants were never changed.
--   4. The two avatar policies back exactly as docs/sql/slice-2-profiles.sql
--      created them (the folder rule only; any file name).
-- The attempt_log rows part 2 wrote ('game_start', 'follow_change') stay;
-- they decide nothing once part 2 is gone, the cleanup job removes them
-- after 7 days, and part 1's rollback deletes them.
--
-- RE-RUNNABLE: create or replace; drop if exists.

begin;

-- 1. start_game_with_deal_as, as in computer-c1-refactor.sql.
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

-- 2. The nickname lock out.
drop trigger if exists profiles_nickname_lock on public.profiles;
drop function if exists public.profiles_nickname_lock();

-- 3. _follow_user_as and unfollow_user, as in follows.sql.
create or replace function public._follow_user_as(p_actor uuid, p_target uuid, p_limit int)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  if p_actor is null then
    raise exception 'You must be logged in to follow a player.';
  end if;

  if p_target is null or p_target = p_actor or not public._followable(p_target) then
    return 'not_allowed';
  end if;

  -- One follower at a time (until this transaction ends), so two quick taps
  -- can't both see 49 and both insert.
  perform pg_advisory_xact_lock(hashtextextended('follows:' || p_actor::text, 0));

  if exists (
    select 1 from public.follows f
    where f.follower_id = p_actor and f.followed_id = p_target
  ) then
    return 'following';
  end if;

  -- The cap counts follows of accounts that aren't hidden.
  select count(*) into v_count
  from public.follows f
  where f.follower_id = p_actor
    and not exists (select 1 from public.leaderboard_hidden h where h.user_id = f.followed_id);

  if v_count >= p_limit then
    return 'limit';
  end if;

  insert into public.follows (follower_id, followed_id)
  values (p_actor, p_target)
  on conflict do nothing;

  return 'following';
end;
$$;

comment on function public._follow_user_as(uuid, uuid, int) is
  'Internal: follow p_target as p_actor with a cap of p_limit. Returns following, limit or not_allowed; raises when p_actor is null. Called by follow_user (auth.uid(), 50) and by follows-verification.sql; no client role can execute it.';

create or replace function public.unfollow_user(p_target uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'You must be logged in to unfollow a player.';
  end if;

  delete from public.follows
  where follower_id = auth.uid()
    and followed_id = p_target;

  return 'not_following';
end;
$$;

comment on function public.unfollow_user(uuid) is
  'Stop following p_target as the signed-in player. Always returns not_following (idempotent). Raises when nobody is logged in.';

-- 4. The two avatar policies, as in slice-2-profiles.sql.
drop policy if exists "Users can upload their own avatar" on storage.objects;
create policy "Users can upload their own avatar"
  on storage.objects for insert
  with check (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);

drop policy if exists "Users can update their own avatar" on storage.objects;
create policy "Users can update their own avatar"
  on storage.objects for update
  using (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);

commit;
