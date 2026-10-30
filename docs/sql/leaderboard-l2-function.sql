-- Leaderboard, L2: get_leaderboard()
-- Run this in the Supabase Dashboard -> SQL Editor, AFTER
-- leaderboard-l1-game-results.sql (live). Kept here for reference/history;
-- this project has no Supabase CLI/migrations set up yet.
--
-- WHAT IT ADDS (and leaderboard-l2-rollback.sql removes exactly this): one
-- read-only function, public.get_leaderboard(), returning one row of TOTALS
-- per listed player -- never a per-game row. No table, index or policy.
--
-- RETURNS (in this order):
--   user_id               uuid
--   nickname              text         (trimmed)
--   avatar_url            text         (null if none)
--   wins                  integer
--   losses                integer
--   skunks                integer
--   double_skunks         integer
--   times_skunked         integer
--   beat_god              integer
--   skunk_tracking_since  timestamptz  (min(game_results.created_at); the
--                                       same on every row; null if none)
-- ORDERED BY wins desc, losses asc, then nickname (case-insensitive), then
-- user_id (so ties always come back in the same order).
--
-- THE RULES
--   * A COUNTED GAME: games.ended_reason = 'won' on a HUMAN table
--     (tables.is_muggins = false and tables.computer_level is null), with
--     the winner in games.players. Abandoned games (player_left, admin,
--     timeout) and unfinished ones are never 'won', so never counted.
--   * WINS / LOSSES, from games alone (so every past won game counts): the
--     winner is winner_id; on a 4-player Teams table (max_players = 4,
--     team_mode = 'teams', 4 players) the winner's partner -- the same
--     seat_team of their position in games.players: 1 & 3 against 2 & 4 --
--     wins too and the other two lose. Any other table (2 or 3 players,
--     4-player Solo): only the winner wins, everyone else in players loses.
--   * SKUNKS, from game_results (so only games won since L1 was applied),
--     counted games only. Each game's LOSING SIDES: a player, or on a Teams
--     table a team (counted once; both partners hold the same score). A
--     side's score is its recorded score (rows with a null score ignored).
--       under 61     a double skunk
--       61 to 90     a skunk
--       91 and up    neither
--     Every winner of the game gets +1 skunk or +1 double_skunk per such
--     losing side; every member of that side gets +1 times_skunked (a
--     double skunk is a times_skunked too). Who won is the SAME rule as for
--     wins/losses; game_results.won is not read.
--   * BEAT GOD: games won by the player (winner_id) at a table with
--     computer_level = 'hard'. Computer games count ONLY here.
--   * LISTED: profiles with a non-blank nickname that are not computer
--     accounts (computer_accounts), with at least one counted game or a
--     Beat God. Computers never appear.
--
-- SECURITY: security definer (game_results and computer_accounts have no
-- client access), search_path public, stable. It returns only the columns
-- above -- no emails, nothing from auth.users. EXECUTE: authenticated only;
-- nothing for PUBLIC or anon.
--
-- PERFORMANCE: one set-based query over every won game. Fine at this
-- app's size (a friends app); no new index.
--
-- RE-RUNNABLE: "create or replace function" with the same signature, and
-- idempotent grants. (Changing the returned columns later needs a DROP
-- FUNCTION first: create or replace cannot change a function's result type.)
--
-- Checks: docs/sql/leaderboard-l2-verification.sql -- one rolled-back
-- walk-through.
--
-- One transaction: if any statement fails, nothing is applied.

begin;

create or replace function public.get_leaderboard()
returns table (
  user_id uuid,
  nickname text,
  avatar_url text,
  wins integer,
  losses integer,
  skunks integer,
  double_skunks integer,
  times_skunked integer,
  beat_god integer,
  skunk_tracking_since timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with counted as (
    -- Won human games, with the Teams test and the winner's position.
    select g.id as game_id,
           g.players,
           g.winner_id,
           (t.max_players = 4 and t.team_mode = 'teams'
            and coalesce(array_length(g.players, 1), 0) = 4) as teams,
           array_position(g.players, g.winner_id) as winner_pos
    from public.games g
    join public.tables t on t.id = g.table_id
    where g.ended_reason = 'won'
      and not t.is_muggins
      and t.computer_level is null
      and g.winner_id = any(g.players)
  ),
  seated as (
    -- One row per player of a counted game: their side and whether it won.
    -- A side is the team on a Teams table, otherwise the player's position.
    select c.game_id,
           p.uid as user_id,
           case when c.teams then public.seat_team(p.pos::int) else p.pos::int end as side,
           (p.uid = c.winner_id
            or (c.teams and public.seat_team(p.pos::int) = public.seat_team(c.winner_pos))) as won
    from counted c
    cross join lateral unnest(c.players) with ordinality as p(uid, pos)
  ),
  wl as (
    select s.user_id,
           count(*) filter (where s.won) as wins,
           count(*) filter (where not s.won) as losses
    from seated s
    group by s.user_id
  ),
  skunked_sides as (
    -- Each losing side of a game with saved scores, counted once, and its
    -- bucket. Partners share one score, so max() is that score.
    select x.game_id,
           x.side,
           (x.score < 61) as is_double
    from (
      select s.game_id, s.side, max(r.score) as score
      from seated s
      join public.game_results r on r.game_id = s.game_id and r.user_id = s.user_id
      where not s.won
        and r.score is not null
      group by s.game_id, s.side
    ) x
    where x.score <= 90
  ),
  winner_credit as (
    select s.user_id,
           count(*) filter (where not k.is_double) as skunks,
           count(*) filter (where k.is_double) as double_skunks
    from seated s
    join skunked_sides k on k.game_id = s.game_id
    where s.won
    group by s.user_id
  ),
  loser_debit as (
    select s.user_id,
           count(*) as times_skunked
    from seated s
    join skunked_sides k on k.game_id = s.game_id and k.side = s.side
    where not s.won
    group by s.user_id
  ),
  god as (
    select g.winner_id as user_id,
           count(*) as beat_god
    from public.games g
    join public.tables t on t.id = g.table_id
    where g.ended_reason = 'won'
      and t.computer_level = 'hard'
      and g.winner_id is not null
    group by g.winner_id
  )
  select pr.id,
         btrim(pr.nickname),
         pr.avatar_url,
         coalesce(wl.wins, 0)::int,
         coalesce(wl.losses, 0)::int,
         coalesce(wc.skunks, 0)::int,
         coalesce(wc.double_skunks, 0)::int,
         coalesce(ld.times_skunked, 0)::int,
         coalesce(gd.beat_god, 0)::int,
         (select min(r.created_at) from public.game_results r)
  from public.profiles pr
  left join wl on wl.user_id = pr.id
  left join winner_credit wc on wc.user_id = pr.id
  left join loser_debit ld on ld.user_id = pr.id
  left join god gd on gd.user_id = pr.id
  where btrim(coalesce(pr.nickname, '')) <> ''
    and not exists (select 1 from public.computer_accounts ca where ca.user_id = pr.id)
    and (coalesce(wl.wins, 0) + coalesce(wl.losses, 0) > 0 or coalesce(gd.beat_god, 0) > 0)
  order by coalesce(wl.wins, 0) desc,
           coalesce(wl.losses, 0) asc,
           lower(btrim(pr.nickname)) asc,
           pr.id asc;
$$;

revoke all on function public.get_leaderboard() from public;
revoke all on function public.get_leaderboard() from anon;
revoke all on function public.get_leaderboard() from authenticated;
grant execute on function public.get_leaderboard() to authenticated;

commit;
