-- Phase 3: SELF-SCORING (MUGGINS) WITH 3 AND 4 PLAYERS
-- Run this in the Supabase Dashboard -> SQL Editor, AFTER muggins-mode.sql
-- and every phase3-e*.sql step (all live). Kept here for reference/history;
-- this project has no Supabase CLI/migrations set up yet.
-- Checks: docs/sql/phase3-muggins-multiplayer-verification.sql.
--
-- WHAT IT DOES, in order -- and nothing else:
--   1. tables: the 2-player-only rule for Muggins (tables_muggins_two_players)
--      is replaced by tables_muggins_no_teams -- a Muggins table may have 2,
--      3 or 4 players, and a 4-player one must be team_mode 'solo'.
--   2. games.win_confirmed_by (uuid[], NOT NULL, default '{}'): who has
--      confirmed the open win claim.
--   3. claim_win, clear_win_claim, confirm_win -- REDEFINED (same signatures,
--      security definer, search_path and grants as muggins-mode.sql). Each
--      change is marked (M1)-(M5) below; everything else is byte-for-byte
--      muggins-mode.sql, comments included.
--
-- WHY: Self-Scoring is a shared deck and nothing more -- no Teams, no Solo.
-- With 3 or 4 players a claimed win needs EVERY other player's confirmation
-- before the match ends; with 2 that is one confirmation, "the other
-- player's", so 2-player behaviour and every 2-player message stay exactly
-- as they are.
--
-- WHY 'solo' FOR 4 PLAYERS: tables.team_mode defaults to 'teams', and two
-- functions treat "max_players = 4 and team_mode = 'teams'" as a Teams
-- table -- award_points (partners share points) and the leaderboard snapshot
-- trigger (the winner's partner is a winner too). A 4-player Muggins table
-- stored as 'solo' never takes either branch, so neither function changes.
-- The app sends 'solo' for 3- and 4-player Muggins tables; for 3 players
-- team_mode is ignored everywhere, so only 4 is enforced.
--
-- NOT TOUCHED, deliberately: award_points (a Muggins score still never ends
-- the game, at any size), snapshot_game_result, get_leaderboard (still skips
-- every Muggins game), start_game_with_deal, next_hand, leave_table,
-- end_timed_out_sessions. Policies and grants on tables and games are
-- unchanged.
--
-- A NEW GAME NEVER INHERITS A CLAIM: every game -- the first, a rematch, the
-- game after a leave -- is a NEW games row, so it starts with the column
-- defaults: win_claim_by null and win_confirmed_by '{}'. Within a game a
-- claim lasts until it is withdrawn or settled (next_hand does not clear it:
-- a claim is about the MATCH), and its confirmations last with it; every
-- path that starts or settles a claim resets them (M2, M3, M5).
--
-- REALTIME: games is in the supabase_realtime publication with no column
-- list, so win_confirmed_by reaches every subscribed client with no change.
--
-- RE-RUNNABLE: "drop constraint if exists" then add, "add column if not
-- exists", "create or replace" with the same signatures.
--
-- ROLLBACK, in THIS order:
--   1. re-run sections 4-6 of muggins-mode.sql (the three functions);
--   2. alter table public.games drop column if exists win_confirmed_by;
--   3. only once no Muggins table has more than 2 players:
--      alter table public.tables drop constraint if exists tables_muggins_no_teams;
--      alter table public.tables add constraint tables_muggins_two_players
--        check (not is_muggins or max_players = 2);

begin;

-- ---------------------------------------------------------------------------
-- 1. tables: Muggins on 2, 3 or 4 players; never Teams.
-- ---------------------------------------------------------------------------
alter table public.tables drop constraint if exists tables_muggins_two_players;
alter table public.tables drop constraint if exists tables_muggins_no_teams;
alter table public.tables
  add constraint tables_muggins_no_teams check (not is_muggins or max_players <> 4 or team_mode = 'solo');

comment on column public.tables.max_players is
  'Table size, chosen at creation: 2, 3 or 4 players. Never changed by players. Joining stops at this many (assign_table_seat). A Muggins table may be any size; a 4-player Muggins table is team_mode ''solo'' (tables_muggins_no_teams).';

comment on column public.tables.is_muggins is
  'Muggins (Self-Scoring) table: chosen at creation, never changed by players. Scoring keeps running on the server but the app hides it; 121 never ends the game (award_points). A match ends when one player claims the win (claim_win) and every other player confirms it (confirm_win), which records the winner through the normal won path.';


-- ---------------------------------------------------------------------------
-- 2. games.win_confirmed_by.
-- ---------------------------------------------------------------------------
alter table public.games
  add column if not exists win_confirmed_by uuid[] not null default '{}';

comment on column public.games.win_confirmed_by is
  'Muggins: the players who have confirmed the open win claim (win_claim_by) of this LIVE match. The match is won when it holds every player but the claimant (confirm_win). Emptied whenever a claim starts, is withdrawn or is settled; a new game starts empty.';

comment on column public.games.win_claim_by is
  'Muggins: the player who has claimed the win of this LIVE match, waiting for every other player to confirm it (confirm_win, win_confirmed_by). Only meaningful on a live game. A game ended by leave_table, an admin Force-End or the timeout may keep a stale value, which is harmless: nothing reads it on an ended game, and winner_id stays null.';


-- ---------------------------------------------------------------------------
-- 3. claim_win -- "I win" in a Muggins match.
--
-- Records the caller as the claimant. The other player then confirms
-- (confirm_win) or the claimant cancels (clear_win_claim).
--   * The caller already holds the claim: quiet, nothing changes (a double
--     tap, a retry, a second tab).
--   * The OTHER player holds it: refused -- confirm theirs, or wait for
--     them to cancel. Only one claim at a time.
--
-- (M1) With 3 or 4 players the refusal says "Another player": there is no
-- single "other player". With 2 the message is unchanged.
-- (M2) A new claim starts with no confirmations (win_confirmed_by = '{}'),
-- so a confirmation of an earlier, withdrawn claim never counts for it.
--
-- Order of checks (the same for all three functions): logged in -> ROW LOCK
-- -> game exists -> seated at the game's table -> a player in this game ->
-- Muggins table -> game 'active'. The lock is taken first, so every check
-- reads the row as it is, and claims serialize with each other and with
-- every other function that writes the game row.
-- ---------------------------------------------------------------------------
create or replace function public.claim_win(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_game record;
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to claim the win.';
  end if;

  -- THE ROW LOCK.
  select g.id, g.table_id, g.status, g.players, g.win_claim_by
  into v_game
  from public.games g
  where g.id = p_game_id
  for update;

  if not found then
    raise exception 'Game not found.';
  end if;

  -- Guard 2 (membership): sitting at the game's table, and a player in it.
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

  -- Guard 3: Muggins tables only.
  if not exists (
    select 1
    from public.tables t
    where t.id = v_game.table_id
      and t.is_muggins
  ) then
    raise exception 'Only a Muggins table has win claims.';
  end if;

  -- Guard 4: a live, dealt game -- not mid-cut, not ended.
  if v_game.status <> 'active' then
    raise exception 'The win can only be claimed during a live game.';
  end if;

  -- Already mine: quiet.
  if v_game.win_claim_by = v_caller then
    return;
  end if;

  -- Someone else's: refused.
  if v_game.win_claim_by is not null then
    -- ===== (M1) 3 AND 4 PLAYERS (start) =====
    if coalesce(array_length(v_game.players, 1), 0) > 2 then
      raise exception 'Another player has already claimed the win. Confirm it, or wait for them to cancel it.';
    end if;
    -- ===== (M1) 3 AND 4 PLAYERS (end) =====
    raise exception 'The other player has already claimed the win. Confirm it, or wait for them to cancel it.';
  end if;

  -- ===== (M2) A NEW CLAIM, NO CONFIRMATIONS (start) =====
  update public.games
  set win_claim_by = v_caller,
      win_confirmed_by = '{}'
  where id = p_game_id;
  -- ===== (M2) A NEW CLAIM, NO CONFIRMATIONS (end) =====
end;
$$;

revoke all on function public.claim_win(uuid) from public;
revoke all on function public.claim_win(uuid) from anon;
revoke all on function public.claim_win(uuid) from authenticated;
grant execute on function public.claim_win(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. clear_win_claim -- the claimant turns "I win" off again.
--
-- Only the claimant may cancel their own claim; anyone else is refused, and
-- so is a call with no claim to cancel. Same order of checks as claim_win.
--
-- (M3) The claim's confirmations go with it (win_confirmed_by = '{}'), so a
-- later claim -- by anyone -- starts from none.
-- ---------------------------------------------------------------------------
create or replace function public.clear_win_claim(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_game record;
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to cancel a win claim.';
  end if;

  -- THE ROW LOCK.
  select g.id, g.table_id, g.status, g.players, g.win_claim_by
  into v_game
  from public.games g
  where g.id = p_game_id
  for update;

  if not found then
    raise exception 'Game not found.';
  end if;

  -- Guard 2 (membership): sitting at the game's table, and a player in it.
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

  -- Guard 3: Muggins tables only.
  if not exists (
    select 1
    from public.tables t
    where t.id = v_game.table_id
      and t.is_muggins
  ) then
    raise exception 'Only a Muggins table has win claims.';
  end if;

  -- Guard 4: a live, dealt game.
  if v_game.status <> 'active' then
    raise exception 'A win claim can only be cancelled during a live game.';
  end if;

  -- Guard 5: there must be a claim, and it must be the caller's.
  if v_game.win_claim_by is null then
    raise exception 'There is no win claim to cancel.';
  end if;

  if v_game.win_claim_by <> v_caller then
    raise exception 'Only the player who claimed the win can cancel the claim.';
  end if;

  -- ===== (M3) THE CONFIRMATIONS GO WITH THE CLAIM (start) =====
  update public.games
  set win_claim_by = null,
      win_confirmed_by = '{}'
  where id = p_game_id;
  -- ===== (M3) THE CONFIRMATIONS GO WITH THE CLAIM (end) =====
end;
$$;

revoke all on function public.clear_win_claim(uuid) from public;
revoke all on function public.clear_win_claim(uuid) from anon;
revoke all on function public.clear_win_claim(uuid) from authenticated;
grant execute on function public.clear_win_claim(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. confirm_win -- every other player confirms the loss: the match is won.
--
-- Ends the match EXACTLY as award_points' win block does -- status 'ended',
-- ended_reason 'won', winner_id = the claimant -- so the result screen, the
-- New Game ready gate (the loser deals next) and the leaderboard all treat it
-- like any other win. Three more columns are written, all on purpose:
--   * win_claim_by = null: the claim is settled.
--   * win_confirmed_by = '{}': so are its confirmations (M5).
--   * ready_by = '{}': the New Game gate collects its taps in the WON game's
--     ready_by, and assumes it starts empty. A score-win can only happen
--     while ready_by is empty (next_hand fills it only in 'done', where
--     nothing scores), but a confirm can come in 'done' after a Next Hand
--     tap -- which must never count as a New Game tap.
-- Scores are not touched (the win block doesn't touch them either).
--
-- (M4) The row lock now also reads win_confirmed_by: it is read under the
-- lock, so two players confirming at the same moment serialize -- the second
-- reads the first's confirmation, and neither is lost.
-- (M5) EVERY other player must confirm. A confirmation is recorded in
-- win_confirmed_by; a repeat by the same player does nothing; the
-- confirmation that completes the set (every player but the claimant) ends
-- the match. With 2 players the first confirmation completes it, so the
-- match ends on it exactly as before. With 3 or 4 the refusal of the
-- claimant's own confirmation says "every other player".
--
-- Order of checks: as claim_win, then: a claim exists -> the caller is not
-- the claimant -> the claimant is still a player (defensive) -> already
-- confirmed (quiet).
-- ---------------------------------------------------------------------------
create or replace function public.confirm_win(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_game record;
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to confirm the win.';
  end if;

  -- THE ROW LOCK.
  -- ===== (M4) THE CONFIRMATIONS, READ UNDER THE LOCK (start) =====
  select g.id, g.table_id, g.status, g.players, g.win_claim_by, g.win_confirmed_by
  into v_game
  from public.games g
  where g.id = p_game_id
  for update;
  -- ===== (M4) THE CONFIRMATIONS, READ UNDER THE LOCK (end) =====

  if not found then
    raise exception 'Game not found.';
  end if;

  -- Guard 2 (membership): sitting at the game's table, and a player in it.
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

  -- Guard 3: Muggins tables only.
  if not exists (
    select 1
    from public.tables t
    where t.id = v_game.table_id
      and t.is_muggins
  ) then
    raise exception 'Only a Muggins table has win claims.';
  end if;

  -- Guard 4: a live, dealt game.
  if v_game.status <> 'active' then
    raise exception 'The win can only be confirmed during a live game.';
  end if;

  -- Guard 5: a claim to confirm, by someone else.
  if v_game.win_claim_by is null then
    raise exception 'Nobody has claimed the win.';
  end if;

  if v_game.win_claim_by = v_caller then
    -- ===== (M5) 3 AND 4 PLAYERS: THE MESSAGE (start) =====
    if coalesce(array_length(v_game.players, 1), 0) > 2 then
      raise exception 'You can''t confirm your own claim; every other player has to.';
    end if;
    -- ===== (M5) 3 AND 4 PLAYERS: THE MESSAGE (end) =====
    raise exception 'You can''t confirm your own claim; the other player has to.';
  end if;

  -- Guard 6 (defensive): the claimant must still be a player in this game.
  if not (v_game.win_claim_by = any(v_game.players)) then
    raise exception 'The win claim is not from a player in this game.';
  end if;

  -- ===== (M5) EVERY OTHER PLAYER CONFIRMS (start) =====
  -- Already confirmed: quiet (a double tap, a retry, a second tab).
  if v_caller = any(v_game.win_confirmed_by) then
    return;
  end if;

  -- Not the last confirmation: record it, and the match goes on.
  if exists (
    select 1
    from unnest(v_game.players) as p(user_id)
    where p.user_id <> v_game.win_claim_by
      and p.user_id <> v_caller
      and not (p.user_id = any(v_game.win_confirmed_by))
  ) then
    update public.games
    set win_confirmed_by = v_game.win_confirmed_by || v_caller
    where id = p_game_id;
    return;
  end if;
  -- ===== (M5) EVERY OTHER PLAYER CONFIRMS (end) =====

  -- THE WIN, as award_points writes it -- plus the settled claim, its
  -- confirmations (M5) and an empty ready_by for the New Game gate (see
  -- above).
  update public.games
  set status = 'ended',
      ended_reason = 'won',
      winner_id = v_game.win_claim_by,
      win_claim_by = null,
      win_confirmed_by = '{}',
      ready_by = '{}'
  where id = p_game_id;
end;
$$;

revoke all on function public.confirm_win(uuid) from public;
revoke all on function public.confirm_win(uuid) from anon;
revoke all on function public.confirm_win(uuid) from authenticated;
grant execute on function public.confirm_win(uuid) to authenticated;

commit;
