-- Phase 3, step E4: counting for 2, 3 and 4 players, Teams scoring, and the win
-- Run this in the Supabase Dashboard -> SQL Editor, AFTER
-- phase3-e3-pegging.sql (live). Kept here for reference/history; this
-- project has no Supabase CLI/migrations set up yet.
--
-- WHAT IT DOES -- three functions redefined, each from its NEWEST version
-- with marked regions only, and ONE read policy's condition changed; no
-- table, column or grant changes:
--   1. award_points   (from muggins-mode.sql)
--        (T1)-(T3): on a 4-player Teams table the points go to BOTH
--        partners' rows (the team total), last_points / last_reason /
--        last_awarded_at to the scorer's row only, and the win reads the
--        scorer's new score. Every other table: the same single-row update.
--   2. confirm_count  (from phase2-batch2a-counting.sql)
--        (K1)-(K6): the counting order for N players -- step k is the hand
--        of the (k+1)-th player clockwise from the dealer, the dealer's own
--        hand at step N-1, the crib at step N; p_step 0 .. N.
--   3. show_crib      (from phase2-batch2a-counting.sql)
--        (S1)-(S2): the crib is shown at step N.
--   4. the game_cribs policy "Players read the crib once it is up for
--      counting" (from phase2-open-hands-in-count.sql): its count_step = 2
--      becomes count_step = array_length(g.players, 1). Nothing else in it,
--      and its name, command and roles are kept (ALTER POLICY, one
--      statement: there is no moment when it is missing or different).
--
-- THE RULES (approved E4 proposal, rules 1-8):
--   * Counting goes clockwise from the dealer's left; the dealer counts
--     their own hand LAST, then the crib, which is the dealer's.
--     current_player is the player whose count is up; only they may
--     confirm it ('It is not your turn to count.'). 'done' when the crib is
--     confirmed (current_player null; count_step stays at N).
--   * Each hand is scored with score_hand as today and the points go to the
--     hand's owner; the crib is scored with the crib flag and goes to the
--     dealer. Confirming a hand still shows it (revealed_by); the crib is
--     shown by show_crib at its step (crib_revealed), and readable by every
--     player of the game from its step on.
--   * 3 players score individually. 4 players in team_mode 'teams' play
--     TEAMS: seats 1 and 3 against 2 and 4 (seat_team), and partners share
--     ONE score -- see THE TEAM SCORE below. A 4-player 'solo' table scores
--     individually, like 3 players.
--   * The win: a total reaching 121 (a player's own score, or the team
--     total in Teams) ends the match on the spot -- in pegging, on his
--     heels, a hand or the crib -- with winner_id the player who scored the
--     winning points, the score capped at 121, as today. Every count still
--     to come is never made, as today.
--   * Muggins (always 2 players): unchanged -- a score never ends the match.
--
-- THE TEAM SCORE (Option A'): only for tables with max_players = 4 AND
-- team_mode = 'teams', read from the tables row inside award_points. Every
-- table has team_mode 'teams' by default -- 2- and 3-player ones too -- so
-- the size is part of the test. award_points adds the points (capped at
-- 121) to EVERY member of the scorer's team -- the rows whose
-- seat_team(seat) equals the scorer's -- in ONE update statement, inside the
-- games row lock its caller (play_card, discard_to_crib, confirm_count)
-- already holds; so both partners' rows always hold the same team total,
-- and the existing client reads keep working (a team's score is either
-- partner's row). last_points, last_reason and last_awarded_at are written
-- ONLY on the scorer's row, so the newest award at the table names who
-- scored it. The win check reads the scorer's new score. winner_id is the
-- scoring player; the winning team is the winner and their partner.
--
-- 2-PLAYER COUNTING IS UNCHANGED. With N = 2 every rule above is the old
-- one, step for step:
--   step 0                the pone's hand (seat(1), the dealer's left)
--   step 1                the dealer's hand (step N-1)
--   step 2                the crib (step N), the dealer's
--   'done'                past every step, 3 (N + 1)
--   p_step                0 .. 2, refused before the game is even looked up
--                         -- a game that doesn't exist counts as 2-player
--   current_player        the dealer after step 0 and after step 1
--   Guard 7               the old two conditions, word for word; the new
--                         third one applies only to 3 and 4 players
--   show_crib             at count_step 2, with the old message word for word
--   the crib policy       array_length(players) is 2
--   award_points          a 2-player table (Teams mode or not) and a Muggins
--                         table take the else branch: the old statement
-- This is PROVEN, not assumed: the verification creates the OLD
-- award_points, confirm_count and show_crib inside its transaction and runs
-- the same calls through old and new, side by side, comparing every row
-- after every call.
--
-- NOT CHANGED: show_hand (it has no 2-player assumption), score_hand (his
-- nobs is part of a hand's count, as before), play_card, discard_to_crib
-- (his heels: still one award_points call, so it goes to the dealer's
-- team), next_hand (its gate on 'done', its ready gate and its clockwise
-- rotation already work for any number), start_game_with_deal (every
-- player's New Game tap, the next seat clockwise from the winner deals --
-- with Teams always the losing team -- and every member's score back to
-- 0), claim_win, clear_win_claim, confirm_win, leave_table (one player
-- leaving still ends the match for everyone), end_timed_out_sessions, and
-- every E1 to E3 function. No other policy: game_hands' policies already
-- keep every hand private until its owner shows it or the count begins --
-- Teams partners included -- and every card is played face up before then.
--
-- NO NEW COLUMN: count_step (now 0 .. N), current_player, revealed_by,
-- crib_revealed, table_members.score / last_points / last_reason /
-- last_awarded_at and games.winner_id carry everything, so the live
-- 2-player client keeps working untouched.
--
-- WHAT A 3- AND 4-PLAYER GAME CAN DO AFTER E4: be played as a whole match
-- on the server -- cut, deal, peg, count, next hand, win and rematch. The
-- live client still only offers 2-player tables until the app stages.
--
-- CHARACTERS: confirm_count's body keeps, verbatim, the three non-ASCII
-- characters of phase2-batch2a-counting.sql: the middle dot (U+00B7) of the
-- reason's separator and, in two comment lines, that dot and an em dash. The
-- file is UTF-8, as that one is; the verification's md5 of the body checks
-- them.
--
-- GRANTS: unchanged ("create or replace" keeps them); restated below.
-- award_points stays internal (not client-callable); still fourteen
-- client-callable functions.
--
-- RE-RUNNABLE: "create or replace" with the same signatures, and ALTER
-- POLICY sets the same condition again.
--
-- ROLLBACK -- roll back only while no 3- or 4-player game is live (the old
-- functions count for 2 players only, and the old award_points scores one
-- partner's row). In any order, each as one statement:
--   1. the policy, back to its phase2-open-hands-in-count.sql condition:
--        alter policy "Players read the crib once it is up for counting"
--          on public.game_cribs
--          using (
--            exists (
--              select 1
--              from public.games g
--              where g.id = game_cribs.game_id
--                and g.status = 'active'
--                and ((g.phase = 'counting' and g.count_step = 2) or g.phase = 'done')
--                and auth.uid() = any(g.players)
--            )
--          );
--   2. show_crib and confirm_count: re-run their "create or replace
--      function" statements and the revoke/grant lines right after each,
--      from phase2-batch2a-counting.sql (sections 10 and 11).
--   3. award_points: re-run its "create or replace function" statement and
--      the revoke line after it from muggins-mode.sql (section 3).
--
-- Checks: docs/sql/phase3-e4-counting-verification.sql -- one rolled-back
-- walk-through as real players, with the side-by-side 2-player proof.


-- ---------------------------------------------------------------------------
-- 1. award_points -- the Teams score.
--
-- Still NOT security definer and still not client-callable: its callers
-- already run as the owner and hold the games row lock.
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
  -- ===== (T1) CHANGED FOR PHASE 3 E4 (start) =====
  -- A Teams table, and the scorer's team (seat_team: seats 1 and 3, 2 and 4).
  v_teams boolean;
  v_team int;
  -- ===== (T1) CHANGED FOR PHASE 3 E4 (end) =====
-- ===== (W1) CHANGED FROM SLICE 6 (end) =====
begin
  if p_points is null then
    raise exception 'award_points requires a point value (0 is allowed, null is not).';
  end if;

  -- ===== (T2) CHANGED FOR PHASE 3 E4 (start) =====
  -- TEAMS: a 4-player table in team_mode 'teams' (and ONLY that: every table
  -- has team_mode 'teams' by default, 2- and 3-player ones included, so the
  -- size is part of the test). Partners share ONE score, so the points go
  -- to EVERY member of the scorer's team, in ONE statement -- inside the
  -- games row lock every caller already holds, so the partners' rows can't
  -- drift apart. Both rows hold the team total; the cap applies to each.
  -- last_points, last_reason and last_awarded_at go on the SCORER's row only,
  -- so the newest award at the table still names who scored it (the flash,
  -- the win banner).
  --
  -- The win below reads the scorer's new score, read separately: UPDATE ...
  -- RETURNING INTO raises an error when two rows come back. If the scorer
  -- isn't seated, v_team is null, the update matches nothing, the read finds
  -- nothing, and the same 'No player' error fires as before.
  --
  -- Every other table -- 2 players, 3 players, Muggins (always 2 players),
  -- a 4-player 'solo' table -- takes the else branch: the statement that
  -- follows, unchanged.
  select (t.max_players = 4 and t.team_mode = 'teams')
  into v_teams
  from public.tables t
  where t.id = p_table_id;

  if coalesce(v_teams, false) then
    select public.seat_team(tm.seat)
    into v_team
    from public.table_members tm
    where tm.table_id = p_table_id
      and tm.user_id = p_user_id;

    update public.table_members
    set score = least(score + p_points, 121),
        last_points = case when user_id = p_user_id then p_points else last_points end,
        last_reason = case when user_id = p_user_id then p_reason else last_reason end,
        last_awarded_at = case when user_id = p_user_id then now() else last_awarded_at end
    where table_id = p_table_id
      and (user_id = p_user_id or public.seat_team(seat) = v_team);

    select tm.score
    into v_new_score
    from public.table_members tm
    where tm.table_id = p_table_id
      and tm.user_id = p_user_id;
  else
  -- ===== (T2) CHANGED FOR PHASE 3 E4 (end) =====

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

  -- ===== (T3) CHANGED FOR PHASE 3 E4 (start) =====
  end if;
  -- ===== (T3) CHANGED FOR PHASE 3 E4 (end) =====

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
revoke all on function public.award_points(uuid, uuid, int, text) from anon;
revoke all on function public.award_points(uuid, uuid, int, text) from authenticated;


-- ---------------------------------------------------------------------------
-- 2. confirm_count -- the counting order for 2, 3 and 4 players.
-- ---------------------------------------------------------------------------
create or replace function public.confirm_count(p_game_id uuid, p_step int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_game record;
  v_current_step int;
  v_is_crib boolean;
  v_cards text[];
  v_score jsonb;
  v_points int;
  v_parts text[] := '{}';
  v_reason text;
  -- ===== (K1) CHANGED FOR PHASE 3 E4 (start) =====
  -- N, the number of players: steps 0 .. N-1 are the N hands, step N the
  -- crib. And the dealer's place in players (seat order, clockwise).
  v_n int;
  v_dpos int;
  -- ===== (K1) CHANGED FOR PHASE 3 E4 (end) =====
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to confirm a count.';
  end if;

  -- ===== (K2) CHANGED FOR PHASE 3 E4 (start) =====
  -- Guard 2: a step that cannot exist in this game -- 0 .. N, the N hands
  -- and then the crib. Whether it is behind or ahead is judged later,
  -- against the locked row. N is read first, without the lock (the players
  -- array never changes once a game exists); a game that can't be found
  -- counts as 2-player, so every refusal a 2-player game gave before --
  -- message and order -- is unchanged (the same approach as E2's
  -- discard_to_crib).
  select coalesce(array_length(g.players, 1), 2)
  into v_n
  from public.games g
  where g.id = p_game_id;

  v_n := coalesce(v_n, 2);

  if p_step is null or p_step < 0 or p_step > v_n then
    raise exception 'Invalid count step %.', p_step;
  end if;
  -- ===== (K2) CHANGED FOR PHASE 3 E4 (end) =====

  -- THE ROW LOCK. Both players could act at once (the pone confirming while
  -- the dealer taps Show Crib, a double tap from either), and every check
  -- below reads state the update at the end depends on.
  select g.id, g.table_id, g.status, g.phase, g.players, g.dealer_id,
         g.starter_card, g.current_player, g.count_step, g.revealed_by,
         g.crib_revealed
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

  -- Guard 4 (membership).
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

  -- Guard 5: phase and step. 'done' counts as step 3 -- past every step -- so
  -- a late duplicate of the crib confirm is quiet, not an error.
  if v_game.phase = 'counting' then
    v_current_step := v_game.count_step;
  elsif v_game.phase = 'done' then
    -- ===== (K3) CHANGED FOR PHASE 3 E4 (start) =====
    -- Past every step: N + 1 (3 with 2 players, as before).
    v_current_step := v_n + 1;
    -- ===== (K3) CHANGED FOR PHASE 3 E4 (end) =====
  else
    raise exception 'This game is not in the counting phase.';
  end if;

  if p_step < v_current_step then
    return;
  end if;

  if p_step > v_current_step then
    raise exception 'That count is not up yet.';
  end if;

  -- From here on: phase = 'counting' and p_step = count_step.

  -- Guard 6 (turn enforcement): only the player whose count is up.
  if v_game.current_player is distinct from v_caller then
    raise exception 'It is not your turn to count.';
  end if;

  -- ===== (K4) CHANGED FOR PHASE 3 E4 (start) =====
  -- Guard 7 (defensive): current_player must agree with the counting order
  -- -- step k is the hand of the (k+1)-th player clockwise from the dealer,
  -- so the dealer's own hand is step N-1 and the crib (the dealer's) step N.
  -- Cannot fail if only these functions write the row; it is here to catch
  -- a bad backfill or a hand-edited test row before it scores the wrong
  -- cards. With 2 players the first two conditions are the old guard
  -- exactly (step 0 the pone, steps 1 and 2 the dealer) and the third never
  -- applies.
  v_dpos := array_position(v_game.players, v_game.dealer_id);

  if (v_game.count_step = 0 and v_caller = v_game.dealer_id)
     or (v_game.count_step >= v_n - 1 and v_caller is distinct from v_game.dealer_id)
     or (v_n > 2
         and v_game.count_step < v_n - 1
         and v_caller is distinct from v_game.players[((v_dpos + v_game.count_step) % v_n) + 1]) then
  -- ===== (K4) CHANGED FOR PHASE 3 E4 (end) =====
    raise exception 'Counting state is inconsistent: step % does not belong to this player.',
      v_game.count_step;
  end if;

  -- Guard 8: a count needs the starter.
  if v_game.starter_card is null then
    raise exception 'There is no starter card to count with.';
  end if;

  -- ===== (K5) CHANGED FOR PHASE 3 E4 (start) =====
  -- The crib is the last step, N (2 with 2 players, as before).
  v_is_crib := (v_game.count_step = v_n);
  -- ===== (K5) CHANGED FOR PHASE 3 E4 (end) =====

  if v_is_crib then
    -- Guard 9: the crib must have been shown first (show_crib).
    if not v_game.crib_revealed then
      raise exception 'Show the crib before confirming its count.';
    end if;

    select c.cards
    into v_cards
    from public.game_cribs c
    where c.game_id = p_game_id;
  else
    select gh.cards
    into v_cards
    from public.game_hands gh
    where gh.game_id = p_game_id
      and gh.user_id = v_caller;
  end if;

  -- Guard 10: exactly four cards -- see WHAT GETS SCORED above.
  if coalesce(array_length(v_cards, 1), 0) <> 4 then
    raise exception '% has % cards; a count needs exactly 4.',
      case when v_is_crib then 'The crib' else 'Your hand' end,
      coalesce(array_length(v_cards, 1), 0);
  end if;

  -- AUTO-REVEAL (design decision 8). Counting a hand shows it -- you cannot
  -- confirm a hand the table has not seen. The crib is already shown by
  -- Guard 9. Done before the award so a WINNING hand is still on the table.
  if not v_is_crib and not (v_caller = any(v_game.revealed_by)) then
    update public.games
    set revealed_by = array_append(revealed_by, v_caller)
    where id = p_game_id;
  end if;

  -- SCORE. p_is_crib changes only the flush rule (crib: 5-card flush only).
  v_score := public.score_hand(v_cards, v_game.starter_card, v_is_crib);
  v_points := (v_score ->> 'points')::int;

  -- The reason, e.g. "hand: 15s 4 · pairs 2 · runs 3" -- the tracker shows it
  -- as "+9 — hand: 15s 4 · pairs 2 · runs 3". Zero components are omitted;
  -- a hand worth nothing reads "hand: nothing". array_append throughout
  -- (Batch 1's 22P02 lesson).
  if (v_score ->> 'fifteens')::int > 0 then
    v_parts := array_append(v_parts, ('15s ' || (v_score ->> 'fifteens'))::text);
  end if;
  if (v_score ->> 'pairs')::int > 0 then
    v_parts := array_append(v_parts, ('pairs ' || (v_score ->> 'pairs'))::text);
  end if;
  if (v_score ->> 'runs')::int > 0 then
    v_parts := array_append(v_parts, ('runs ' || (v_score ->> 'runs'))::text);
  end if;
  if (v_score ->> 'flush')::int > 0 then
    v_parts := array_append(v_parts, ('flush ' || (v_score ->> 'flush'))::text);
  end if;
  if (v_score ->> 'nobs')::int > 0 then
    v_parts := array_append(v_parts, ('nobs ' || (v_score ->> 'nobs'))::text);
  end if;

  v_reason := (case when v_is_crib then 'crib: ' else 'hand: ' end)
              || coalesce(nullif(array_to_string(v_parts, ' · '), ''), 'nothing');

  -- THE SINGLE AWARD. To the caller: the hand's owner at steps 0 and 1, and
  -- the dealer -- who owns the crib in 2-player -- at step 2 (Guard 7).
  perform public.award_points(v_game.table_id, v_caller, v_points, v_reason);

  -- ADVANCE, only if that award did not just end the game. count_step,
  -- current_player and phase move together, in one statement each way.
  -- ===== (K6) CHANGED FOR PHASE 3 E4 (start) =====
  -- The next count is the next player clockwise -- and the dealer's for the
  -- dealer's own hand (step N-1) and the crib (step N). With 2 players both
  -- of those are the only next steps, so it is the dealer, as before.
  if v_game.count_step < v_n then
    update public.games
    set count_step = v_game.count_step + 1,
        current_player = case
          when v_game.count_step + 1 >= v_n - 1 then v_game.dealer_id
          else v_game.players[((v_dpos + v_game.count_step + 1) % v_n) + 1]
        end
    where id = p_game_id
      and status = 'active';
  -- ===== (K6) CHANGED FOR PHASE 3 E4 (end) =====
  else
    update public.games
    set phase = 'done',
        current_player = null
    where id = p_game_id
      and status = 'active';
  end if;
end;
$$;

revoke all on function public.confirm_count(uuid, int) from public;
revoke all on function public.confirm_count(uuid, int) from anon;
grant execute on function public.confirm_count(uuid, int) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. show_crib -- the crib is shown at step N.
-- ---------------------------------------------------------------------------
create or replace function public.show_crib(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_game record;
  -- ===== (S1) CHANGED FOR PHASE 3 E4 (start) =====
  v_n int;
  -- ===== (S1) CHANGED FOR PHASE 3 E4 (end) =====
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to show the crib.';
  end if;

  -- THE ROW LOCK.
  select g.id, g.table_id, g.status, g.phase, g.players, g.dealer_id,
         g.count_step, g.crib_revealed
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

  -- Guard 3 (membership).
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

  -- Guard 4: the crib is the dealer's to show. Before the idempotency return,
  -- so a non-dealer gets a real error rather than a silent no-op.
  if v_game.dealer_id is distinct from v_caller then
    raise exception 'Only the dealer can show the crib.';
  end if;

  -- Idempotent.
  if v_game.crib_revealed then
    return;
  end if;

  -- ===== (S2) CHANGED FOR PHASE 3 E4 (start) =====
  -- Guard 5: only after every hand is counted -- the crib is step N, after
  -- the N hands (step 2 with 2 players, as before). The 2-player message is
  -- unchanged, word for word.
  v_n := coalesce(array_length(v_game.players, 1), 2);

  if v_game.phase <> 'counting' or v_game.count_step <> v_n then
    if v_n = 2 then
      raise exception 'The crib is shown after both hands have been counted.';
    end if;
    raise exception 'The crib is shown after every hand has been counted.';
  end if;
  -- ===== (S2) CHANGED FOR PHASE 3 E4 (end) =====

  update public.games
  set crib_revealed = true
  where id = p_game_id;
end;
$$;

revoke all on function public.show_crib(uuid) from public;
revoke all on function public.show_crib(uuid) from anon;
grant execute on function public.show_crib(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. The crib read policy: "up for counting" means the crib's own step,
-- N. ONLY its count_step condition changes (was count_step = 2, which is
-- the dealer's hand with 3 players and the third hand with 4 -- the crib
-- would open early). Identical for 2 players. ALTER POLICY keeps the name,
-- the command (SELECT), the roles and permissiveness.
-- ---------------------------------------------------------------------------
alter policy "Players read the crib once it is up for counting"
  on public.game_cribs
  using (
    exists (
      select 1
      from public.games g
      where g.id = game_cribs.game_id
        and g.status = 'active'
        and ((g.phase = 'counting' and g.count_step = array_length(g.players, 1)) or g.phase = 'done')
        and auth.uid() = any(g.players)
    )
  );
