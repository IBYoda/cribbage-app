-- Muggins mode: a table option where the app shows no scoring, 121 never
-- ends the game, and a match ends when one player claims the win and the
-- other confirms it
-- Run this in the Supabase Dashboard -> SQL Editor, AFTER
-- phase2-batch2a-counting.sql and phase2-new-game-ready-gate.sql (both live).
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- WHAT IT DOES, in order -- and nothing else:
--   1. tables.is_muggins (boolean, NOT NULL, default false), set at creation.
--   2. games.win_claim_by (uuid, nullable): who has claimed the win of a live
--      Muggins match, waiting for the other player to confirm.
--   3. award_points -- REDEFINED in ONE marked region (X1) against
--      phase2-batch2a-counting.sql: on a Muggins table a score never ends
--      the game. Everything else in it is byte-for-byte the same.
--   4. claim_win, clear_win_claim, confirm_win -- NEW, client-callable,
--      Muggins tables only.
--
-- WHY: in a Muggins table players keep their own score (a physical board),
-- so the app must never end the match at 121. The players decide instead:
-- one claims the win, the other confirms the loss. confirm_win then ends the
-- match through the EXISTING 'won' path, with a recorded winner_id, so
-- everything that follows a win already works unchanged: the result screen,
-- the New Game ready gate in start_game_with_deal (every player taps, then
-- the LOSER deals), and later a leaderboard reading games.winner_id.
--
-- HOW A MUGGINS GAME CAN END, and the winner each way records:
--   * confirm_win ................... 'won', winner_id = the claimant
--   * leave_table ................... 'player_left', no winner
--   * an admin Force-End ............ 'admin', no winner
--   * end_timed_out_sessions ........ 'timeout', no winner
-- None of the last three is touched here; none of them writes winner_id
-- (see the verification file's leaderboard checks).
--
-- MUGGINS SCORING: award_points keeps adding to the score and keeps the 121
-- cap; only the win is skipped. The scoring UPDATE (score, last_points,
-- last_reason, last_awarded_at) is the very same statement for every table,
-- so pegging flashes keep working, and nothing constrains the values
-- (table_members.score is int NOT NULL default 0 with no CHECK; last_points
-- is a nullable int with no CHECK -- phase2-slice-6-score-tracker.sql). The
-- cap keeps a Muggins score at or under 121 however long the match runs.
-- The app hides the scores.
--
-- POLICIES AND GRANTS on tables: unchanged. INSERT stays "auth.uid() =
-- created_by" (it does not look at other columns, so a creator can set
-- is_muggins); UPDATE stays admin-only, so a player can't switch a table to
-- Muggins and back. No column-level grants exist on tables in this project's
-- SQL (checked: nothing in docs/sql creates one; the table-visibility
-- proposal for one was never applied), so authenticated's table-level INSERT
-- covers the new column. The verification file checks the live catalog too.
--
-- NOT TOUCHED, deliberately: start_game_with_deal, next_hand, confirm_count,
-- play_card, discard_to_crib, leave_table, end_timed_out_sessions. A pending
-- win claim is not cleared when a new hand is dealt (next_hand is not
-- redefined): a claim is about the MATCH, and the claimant can cancel it.
--
-- REALTIME: games is already in the supabase_realtime publication
-- (slice-5-new-game.sql, no column list), so win_claim_by reaches every
-- client subscribed to games UPDATEs with no other change.
--
-- GRANTS AFTER THIS FILE: thirteen client-callable functions -- the ten
-- before plus claim_win, clear_win_claim and confirm_win.
--
-- RE-RUNNABLE: "add column if not exists", "comment on", and "create or
-- replace" with the same signatures. Running it twice changes nothing.
--
-- ROLLBACK, in THIS order (award_points must stop reading is_muggins before
-- the column goes):
--   1. drop function if exists public.confirm_win(uuid);
--      drop function if exists public.clear_win_claim(uuid);
--      drop function if exists public.claim_win(uuid);
--   2. re-run award_points from phase2-batch2a-counting.sql (section 7).
--   3. alter table public.games drop column if exists win_claim_by;
--      alter table public.tables drop column if exists is_muggins;
--
-- Checks: docs/sql/muggins-mode-verification.sql -- one rolled-back
-- walk-through as real players.


-- ---------------------------------------------------------------------------
-- 1. tables.is_muggins.
-- ---------------------------------------------------------------------------
alter table public.tables
  add column if not exists is_muggins boolean not null default false;

comment on column public.tables.is_muggins is
  'Muggins table: chosen at creation, never changed by players. Scoring keeps running on the server but the app hides it; 121 never ends the game (award_points). A match ends when one player claims the win (claim_win) and the other confirms it (confirm_win), which records the winner through the normal won path.';


-- ---------------------------------------------------------------------------
-- 2. games.win_claim_by.
-- ---------------------------------------------------------------------------
alter table public.games
  add column if not exists win_claim_by uuid references auth.users (id) on delete set null;

comment on column public.games.win_claim_by is
  'Muggins: the player who has claimed the win of this LIVE match, waiting for the other player to confirm it (confirm_win). Only meaningful on a live game. A game ended by leave_table, an admin Force-End or the timeout may keep a stale value, which is harmless: nothing reads it on an ended game, and winner_id stays null.';


-- ---------------------------------------------------------------------------
-- 3. award_points -- no win on a Muggins table.
--
-- CHANGED FROM BATCH 2a (phase2-batch2a-counting.sql, section 7) in ONE
-- marked region, (X1): the win UPDATE also requires that the table is not a
-- Muggins table. Every other line, comments included, is byte-for-byte
-- Batch 2a. On a normal table the extra condition is always true, so the
-- function behaves exactly as before.
--
-- Still NOT security definer and still ungranted (its callers already run as
-- the owner); the revoke is restated as before.
-- ---------------------------------------------------------------------------
create or replace function public.award_points(
  p_table_id uuid,
  p_user_id uuid,
  p_points int,
  p_reason text
)
returns void
language plpgsql
set search_path = public
as $$
-- ===== (W1) CHANGED FROM SLICE 6 (start) =====
declare
  v_new_score int;
-- ===== (W1) CHANGED FROM SLICE 6 (end) =====
begin
  if p_points is null then
    raise exception 'award_points requires a point value (0 is allowed, null is not).';
  end if;

  update public.table_members
  -- ===== (W2) CHANGED FROM SLICE 6 (start) =====
  -- Capped at 121 -- see THE CAP note above the function.
  set score = least(score + p_points, 121),
  -- ===== (W2) CHANGED FROM SLICE 6 (end) =====
      last_points = p_points,
      last_reason = p_reason,
      last_awarded_at = now()
  where table_id = p_table_id
  -- ===== (W3) CHANGED FROM SLICE 6 (start) =====
    and user_id = p_user_id
  returning score into v_new_score;
  -- ===== (W3) CHANGED FROM SLICE 6 (end) =====

  -- Fails loudly rather than silently scoring nobody. A future scoring slice
  -- passing a stale user id is a bug worth surfacing immediately.
  if not found then
    raise exception 'No player % at table %.', p_user_id, p_table_id;
  end if;

  -- ===== (W4) CHANGED FROM SLICE 6 (start) =====
  -- THE WIN. First to 121 ends the game on the spot -- mid-pegging, mid-count,
  -- or on his heels -- because nothing after the winning point counts.
  --
  -- Filtered to status = 'active', so it is a no-op when called from the SQL
  -- Editor against a table with no live game, and it can never re-end (or
  -- re-attribute) a game that has already ended. 'cutting' never reaches
  -- here: no points are awarded during the cut for deal.
  if v_new_score >= 121 then
    update public.games
    set status = 'ended',
        ended_reason = 'won',
        winner_id = p_user_id
    where table_id = p_table_id
      and status = 'active'
      -- ===== (X1) CHANGED FOR MUGGINS (start) =====
      -- A Muggins table is never won by a score: the points above are still
      -- recorded (and still capped at 121), but the game stays live, so 121
      -- -- or any later award -- never ends it.
      and not exists (
        select 1
        from public.tables t
        where t.id = p_table_id
          and t.is_muggins
      )
      -- ===== (X1) CHANGED FOR MUGGINS (end) =====
      ;
  end if;
  -- ===== (W4) CHANGED FROM SLICE 6 (end) =====
end;
$$;

revoke all on function public.award_points(uuid, uuid, int, text) from public;


-- ---------------------------------------------------------------------------
-- 4. claim_win -- "I win" in a Muggins match.
--
-- Records the caller as the claimant. The other player then confirms
-- (confirm_win) or the claimant cancels (clear_win_claim).
--   * The caller already holds the claim: quiet, nothing changes (a double
--     tap, a retry, a second tab).
--   * The OTHER player holds it: refused -- confirm theirs, or wait for
--     them to cancel. Only one claim at a time.
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
    raise exception 'The other player has already claimed the win. Confirm it, or wait for them to cancel it.';
  end if;

  update public.games
  set win_claim_by = v_caller
  where id = p_game_id;
end;
$$;

revoke all on function public.claim_win(uuid) from public;
revoke all on function public.claim_win(uuid) from anon;
revoke all on function public.claim_win(uuid) from authenticated;
grant execute on function public.claim_win(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. clear_win_claim -- the claimant turns "I win" off again.
--
-- Only the claimant may cancel their own claim; anyone else is refused, and
-- so is a call with no claim to cancel. Same order of checks as claim_win.
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

  update public.games
  set win_claim_by = null
  where id = p_game_id;
end;
$$;

revoke all on function public.clear_win_claim(uuid) from public;
revoke all on function public.clear_win_claim(uuid) from anon;
revoke all on function public.clear_win_claim(uuid) from authenticated;
grant execute on function public.clear_win_claim(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 6. confirm_win -- the other player confirms the loss: the match is won.
--
-- Ends the match EXACTLY as award_points' win block does -- status 'ended',
-- ended_reason 'won', winner_id = the claimant -- so the result screen, the
-- New Game ready gate (the loser deals next) and a future leaderboard all
-- treat it like any other win. Two more columns are written, both on
-- purpose:
--   * win_claim_by = null: the claim is settled.
--   * ready_by = '{}': the New Game gate collects its taps in the WON game's
--     ready_by, and assumes it starts empty. A score-win can only happen
--     while ready_by is empty (next_hand fills it only in 'done', where
--     nothing scores), but a confirm can come in 'done' after a Next Hand
--     tap -- which must never count as a New Game tap.
-- Scores are not touched (the win block doesn't touch them either).
--
-- TWO PLAYERS TODAY: the caller is "the other player". Phase 3 (3 and 4
-- players) must require EVERY other player's confirmation before the match
-- ends -- e.g. a confirmed_by array, ended only when it holds them all.
--
-- Order of checks: as claim_win, then: a claim exists -> the caller is not
-- the claimant -> the claimant is still a player (defensive).
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
    raise exception 'The win can only be confirmed during a live game.';
  end if;

  -- Guard 5: a claim to confirm, by someone else.
  if v_game.win_claim_by is null then
    raise exception 'Nobody has claimed the win.';
  end if;

  if v_game.win_claim_by = v_caller then
    raise exception 'You can''t confirm your own claim; the other player has to.';
  end if;

  -- Guard 6 (defensive): the claimant must still be a player in this game.
  if not (v_game.win_claim_by = any(v_game.players)) then
    raise exception 'The win claim is not from a player in this game.';
  end if;

  -- THE WIN, as award_points writes it -- plus the settled claim and an
  -- empty ready_by for the New Game gate (see above).
  update public.games
  set status = 'ended',
      ended_reason = 'won',
      winner_id = v_game.win_claim_by,
      win_claim_by = null,
      ready_by = '{}'
  where id = p_game_id;
end;
$$;

revoke all on function public.confirm_win(uuid) from public;
revoke all on function public.confirm_win(uuid) from anon;
revoke all on function public.confirm_win(uuid) from authenticated;
grant execute on function public.confirm_win(uuid) to authenticated;
