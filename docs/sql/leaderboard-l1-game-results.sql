-- Leaderboard, L1: the final scores of every won game
-- Run this in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- WHY: a game's final scores are stored nowhere today. The only score is
-- table_members.score, one row per SEAT at a TABLE, which the next game at
-- the table sets back to 0 (start_game_with_deal_as) and which leaving the
-- table deletes (leave_table, leave_computer_table). Skunks need the loser's
-- final score, so it has to be saved at the moment of the win. Wins, losses
-- and Beat God come from games itself (ended_reason 'won', winner_id,
-- players) and need nothing here.
--
-- WHAT IT ADDS (and leaderboard-l1-rollback.sql removes exactly this):
--   1. TABLE public.game_results: one row per player of a won game --
--      game_id, user_id, position (1-based index in games.players), score
--      (the seat's score at the moment of the win), won, created_at.
--      won = the winner, or on a 4-player Teams table the winner's partner.
--      Row-level security on, NO policies, every privilege revoked from
--      PUBLIC, anon and authenticated (AGENTS.md "New tables"): only
--      security definer functions read or write it. Not in the Realtime
--      publication.
--   2. FUNCTION public.snapshot_game_result(): the trigger function, security
--      definer, search_path public. Not executable by any client role.
--   3. TRIGGER games_snapshot_result_on_win: AFTER UPDATE on public.games,
--      once per row, only when ended_reason BECOMES 'won'.
--
-- WHEN THE SCORES ARE READ. Both ways a game is won write the games row
-- LAST, in the same transaction as the scores:
--   * award_points (phase3-e4-counting.sql): updates table_members.score
--     (the scorer's row, or both Teams partners' rows) first, then -- if the
--     new score reached 121 -- sets the games row 'ended' / 'won' /
--     winner_id. An AFTER UPDATE trigger on that statement therefore reads
--     the scores WITH the winning points (the winner's 121).
--   * confirm_win (muggins-mode.sql, Muggins only): changes no score at all;
--     it only ends the game. The snapshot holds whatever the seats held.
-- Nothing between the win and the trigger can change a seat: the trigger
-- runs inside the winning statement.
--
-- POSITIONS AND TEAMS. games.players is set once, when the game row is
-- inserted (start_game_with_deal_as: array_agg(tm.user_id order by tm.seat))
-- and nothing writes it afterwards. A table holds exactly max_players
-- players when a game starts, with unique seats 1 .. max_players, so on a
-- 4-player table position N IS seat N, and set_seat refuses to move anyone
-- while a game is live. Teams (max_players = 4 and team_mode = 'teams') are
-- seats -- so positions -- 1 and 3 against 2 and 4 (seat_team), the rule
-- the PRD gives for the winning team. Every table has team_mode 'teams' by
-- default, so the size is part of the test, as in award_points.
--
-- WHAT IS RECORDED: EVERY won game -- Muggins and computer games included.
-- The leaderboard function filters (is_muggins, computer_level) later.
-- NO BACKFILL: earlier games' final scores are already gone.
--
-- SAFETY: the function body runs in its own exception block. Any failure
-- (a constraint, a missing seat, anything) is reported as a WARNING and the
-- snapshot is skipped -- the win itself is never blocked or rolled back. A
-- won game with no game_results rows is the sign that a snapshot failed.
--
-- IDEMPOTENT: (game_id, user_id) is the primary key and the insert is
-- "on conflict do nothing", so a game that somehow becomes 'won' twice keeps
-- its FIRST snapshot.
--
-- user_id has no foreign key, on purpose: a results row must never block
-- deleting an account, and must not vanish with it either (the game's own
-- row may, through games.created_by's cascade -- and these rows go with
-- their game).
--
-- score is nullable: null only if a player of the game had no seat at the
-- moment of the win, which the game functions do not allow (leaving ends
-- the game first). It is recorded rather than refused.
--
-- GRANTS: none for any client role on the table or the function.
-- service_role: nothing needs it.
--
-- RE-RUNNABLE: "create table if not exists", "create or replace function",
-- the trigger dropped (if it exists) and created again, revokes idempotent.
--
-- Checks: docs/sql/leaderboard-l1-verification.sql -- one rolled-back
-- walk-through.
--
-- One transaction: if any statement fails, nothing is applied.

begin;

-- ===========================================================================
-- 1. public.game_results
-- ===========================================================================
create table if not exists public.game_results (
  game_id uuid not null references public.games (id) on delete cascade,
  user_id uuid not null,
  position smallint not null
    constraint game_results_position_check check (position between 1 and 4),
  score integer,
  won boolean not null,
  created_at timestamptz not null default now(),
  primary key (game_id, user_id)
);

comment on table public.game_results is
  'The final scores of every won game, one row per player, saved by the games trigger games_snapshot_result_on_win at the moment of the win. Read only by security definer functions (the leaderboard). No client role has any privilege on it, and RLS is on with no policies.';

-- Row-level security on, with NO policies: deny by default.
alter table public.game_results enable row level security;

-- Grants, explicit (AGENTS.md "New tables", template appearance-settings.sql):
-- nothing for PUBLIC, anon or authenticated. Revoking everything also
-- removes any default grant the table picked up when it was created.
revoke all on table public.game_results from public;
revoke all on table public.game_results from anon;
revoke all on table public.game_results from authenticated;

-- No policies: deliberately none. No Realtime: deliberately not added to the
-- supabase_realtime publication.


-- ===========================================================================
-- 2. The trigger function
-- ===========================================================================
create or replace function public.snapshot_game_result()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_teams boolean;
  v_winner_pos int;
begin
  -- Its own block: a failure here rolls back only this block's work (the
  -- insert), never the statement that won the game.
  begin
    -- Teams: exactly a 4-player table in team_mode 'teams', with 4 players.
    select (t.max_players = 4 and t.team_mode = 'teams')
    into v_teams
    from public.tables t
    where t.id = new.table_id;

    v_teams := coalesce(v_teams, false) and coalesce(array_length(new.players, 1), 0) = 4;
    v_winner_pos := array_position(new.players, new.winner_id);

    insert into public.game_results (game_id, user_id, position, score, won)
    select new.id,
           p.user_id,
           p.pos::smallint,
           tm.score,
           coalesce(
             p.user_id = new.winner_id
             or (v_teams and public.seat_team(p.pos::int) = public.seat_team(v_winner_pos)),
             false
           )
    from unnest(new.players) with ordinality as p(user_id, pos)
    left join public.table_members tm
      on tm.table_id = new.table_id
     and tm.user_id = p.user_id
    on conflict (game_id, user_id) do nothing;
  exception when others then
    raise warning 'game_results: no snapshot for won game % (% %).', new.id, sqlstate, sqlerrm;
  end;

  return null; -- AFTER trigger: the return value is ignored.
end;
$$;

revoke all on function public.snapshot_game_result() from public;
revoke all on function public.snapshot_game_result() from anon;
revoke all on function public.snapshot_game_result() from authenticated;


-- ===========================================================================
-- 3. The trigger: only when ended_reason BECOMES 'won' (award_points and
-- confirm_win), so later updates of a won game (its ready_by, the New Game
-- gate) never fire it.
-- ===========================================================================
drop trigger if exists games_snapshot_result_on_win on public.games;

create trigger games_snapshot_result_on_win
  after update on public.games
  for each row
  when (new.ended_reason = 'won' and old.ended_reason is distinct from 'won')
  execute function public.snapshot_game_result();

commit;
