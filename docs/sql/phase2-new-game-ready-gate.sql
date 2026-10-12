-- New Game ready gate: every player taps New Game before the next match starts
-- Run this in the Supabase Dashboard -> SQL Editor, AFTER
-- phase2-batch2b-next-hand.sql and phase2-batch2b-ready-gate.sql.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- THE PROBLEM: after a won match, either player's New Game started the next
-- match at once -- the loser dealt immediately -- even while the other player
-- was still looking at the final board.
--
-- THE CHANGE: start_game_with_deal, REDEFINED in three marked regions,
-- (N1)-(N3), against the Batch 2b version in phase2-batch2b-next-hand.sql.
-- Every other line -- the four guards, (M1)-(M4), both unique_violation
-- handlers, the cut path, the score reset -- is byte-for-byte Batch 2b.
--
--   (N1) four declarations
--   (N2) the previous-match lookup also reads the game's id and ready_by
--   (N3) the gate, on the loser-deals path only, before anything is created
--
-- WHEN THE GATE APPLIES: only after a WON match between exactly the players
-- now at the table -- the one path that deals with no cut. Everything else
-- (the first game at a table; a game ended by a player leaving, an admin or
-- the timeout; a changed roster; an abandoned cut) is a cut for deal, which
-- already needs every player to draw, so it starts on the first tap as
-- before.
--
-- WHERE READINESS LIVES: the WON game's own games.ready_by. It is always
-- empty when a match is won (next_hand only fills it in 'done', and nothing
-- scores in 'done'), and nothing else writes it once the game has ended, so
-- it is free to reuse. It lapses by itself: the next match is a new row.
--
-- THE RETURN VALUE: still uuid -- the new game's id, as before -- or NULL,
-- meaning "your tap is recorded; waiting for the others". "create or replace"
-- with the same signature and the same return type keeps the function and its
-- grant; nothing about the grant changes (still ten client-callable
-- functions). The table page doesn't use the return value today; it re-reads
-- the table either way.
--
-- A PLAYER WHO LEAVES after the other has tapped: leave_table is untouched.
-- The tap stays recorded on the won game. If the same player rejoins, the
-- roster matches the won game again, so the gate still applies and their one
-- tap starts the match (the loser dealing). If someone else joins, the roster
-- differs: a cut for deal, and the old readiness is irrelevant.
--
-- WHAT IS UNCHANGED, once the gate passes or doesn't apply: the loser deals
-- with no cut after a won match between the same players; anything else cuts
-- for deal; the unique_violation handlers return the live game; scores and
-- the tracker reset only on a successful start.


-- ---------------------------------------------------------------------------
-- start_game_with_deal -- with the New Game ready gate.
--
-- Order of checks after this change:
--   logged in -> member -> table open -> exactly 2 players (all unchanged)
--   -> previous match (now with its id and ready_by) -> loser?
--   -> if the loser deals (a won match, same players):
--        LOCK the won game -> a live game exists? return it (a late tap)
--        -> already ready? return NULL -> record the tap
--        -> not everyone ready? return NULL
--        -> everyone ready: fall through
--   -> the unchanged insert (loser deals / cut for deal), the unchanged
--      unique_violation handlers, the unchanged score reset.
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
-- Checks: docs/sql/phase2-new-game-ready-gate-verification.sql -- the
-- rolled-back walk-through R1-R8, and the grants check (still ten).
-- ---------------------------------------------------------------------------
