-- Solo stats, S1: each player's record against each computer.
-- Run this in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: RUN in production on 2026-11-11 (PR #101); its verification
-- (solo-stats-verification.sql) passed the same day.
--
-- RUN ORDER:
--   1. docs/sql/solo-stats-precheck.sql      (read-only)
--   2. docs/sql/solo-stats.sql               (this file)
--   3. docs/sql/solo-stats-verification.sql  (read-only)
-- Needs, already live: leaderboard-l1-game-results.sql (game_results),
-- leaderboard-l3-hidden-accounts.sql (leaderboard_hidden),
-- computer-normie.sql (the 'casual' level) and god-wins.sql (the
-- verification compares against get_god_wins).
--
-- WHAT IT ADDS (and solo-stats-rollback.sql removes exactly this): three
-- read-only functions. No table, column, index or policy, and nothing stored:
-- every number is worked out from games each time, so it covers every past
-- game with no backfill and can't drift.
--   1. public._solo_results()            internal, NO client grant
--   2. public.get_solo_stats(uuid[])     authenticated only (Profile)
--   3. public.get_solo_leaderboard(text) authenticated only (the leaderboard's
--                                        per-computer filter)
--
-- NO NEW TABLE, so the AGENTS.md "New tables" grants rule does not apply.
-- NO ENGINE FUNCTION CHANGES (none of the eight _as game functions, nor
-- award_points, nor any computer_* function), so the md5 fingerprints in
-- computer-c1-verification.sql are unaffected.
--
-- THE RULES (Walt's decisions, PRD item 35)
--   * A SOLO GAME: a game with ended_reason = 'won' (finished with a winner;
--     never 'player_left', 'admin' or 'timeout') at a table with a
--     computer_level, not Muggins, with exactly two players: one human and
--     the computer account FOR THAT TABLE'S LEVEL. (The two-player /
--     right-computer test guards the odd case where the creator used plain
--     leave_table and another human took the freed seat.)
--   * WIN: winner_id is the human. LOSS: winner_id is the computer.
--   * PER LEVEL ONLY: easy (Shortbus), casual (Normie), medium (Rainman) and
--     hard (God). Rainman includes the games played when that level was
--     called Normie (same account, same 'medium' key). Skunks are per
--     opponent and are never summed across levels by these functions.
--   * SKUNKS, from game_results (so only games won since L1 was applied;
--     earlier games still count as a win or a loss). The loser's score:
--       under 61     a double skunk
--       61 to 90     a skunk
--       91 and up    neither
--     The human's win over a computer that finished 61-90 is a skunk, under
--     61 a double skunk. A loss where the human finished 90 or under is a
--     times_skunked (a double skunk is a times_skunked too). Identical to
--     get_leaderboard() (leaderboard-l3-hidden-accounts.sql); a null score
--     never counts.
--   * LEFT OUT: computer accounts and hidden accounts (leaderboard_hidden)
--     are never a row; a profile with a blank nickname is never a
--     leaderboard row.
--   * RANKING (get_solo_leaderboard): most wins, then fewest losses, then
--     nickname (case-insensitive), then user_id. Win % is display-only and
--     not computed here.
--
-- VISIBILITY: every signed-in player can read every player's solo stats --
-- the same exposure as get_leaderboard(). Totals only: no per-game rows, no
-- emails, nothing from auth.users. anon and PUBLIC have nothing.
--
-- SECURITY: the two public functions are security definer (they read
-- computer_accounts, leaderboard_hidden and game_results, which no client
-- can), stable, search_path public. _solo_results is NOT security definer:
-- it is only ever called from inside those two, and no role but its owner
-- can execute it (service_role included: nothing needs it).
--
-- RESULT SHAPE: get_solo_leaderboard returns the same columns, in the same
-- order, as get_leaderboard(), so the page can draw both with one row type.
-- beat_god is included so wings (always God-based) stay the same on every
-- filter. Changing a result type later needs DROP FUNCTION first.
--
-- PERFORMANCE: a scan of won games joined to tables, as get_leaderboard()
-- already does on every call. Fine at this app's size; no index. Revisit
-- (a partial index on games (table_id) where ended_reason = 'won', a GIN
-- index on games (players)) only if games grows past ~50k rows.
--
-- RE-RUNNABLE: "create or replace function" with the same signatures and
-- idempotent grants.
--
-- One transaction: if any statement fails, nothing is applied.

begin;

-- ===========================================================================
-- 1. _solo_results(): one row per human per finished solo game. INTERNAL.
-- ===========================================================================
create or replace function public._solo_results()
returns table (
  game_id uuid,
  user_id uuid,
  level text,
  won boolean,
  loser_score integer
)
language sql
stable
set search_path = public
as $$
  select g.id,
         h.uid,
         t.computer_level,
         (g.winner_id = h.uid),
         -- The loser's saved score: the one player who is not the winner.
         -- Null for a game won before L1 (no game_results rows), or if its
         -- snapshot failed -- then never a skunk either way.
         (select min(r.score)
          from public.game_results r
          where r.game_id = g.id
            and r.user_id <> g.winner_id)
  from public.games g
  join public.tables t on t.id = g.table_id
  -- The table's own computer is one of the two players.
  join public.computer_accounts ca
    on ca.level = t.computer_level
   and ca.user_id = any(g.players)
  cross join lateral unnest(g.players) as h(uid)
  where g.ended_reason = 'won'
    and t.computer_level is not null
    and not t.is_muggins
    and cardinality(g.players) = 2
    and g.winner_id = any(g.players)
    and h.uid <> ca.user_id
    and not exists (select 1 from public.computer_accounts c2 where c2.user_id = h.uid)
    and not exists (select 1 from public.leaderboard_hidden lh where lh.user_id = h.uid);
$$;

revoke all on function public._solo_results() from public;
revoke all on function public._solo_results() from anon;
revoke all on function public._solo_results() from authenticated;
revoke all on function public._solo_results() from service_role;


-- ===========================================================================
-- 2. get_solo_stats(): per-level records for up to 50 players (Profile).
-- ===========================================================================
-- One row per player per level they have FINISHED a game at; a level never
-- finished has no row (the app shows it as 0 - 0). Only the first 50 ids of
-- a call are read. skunk_tracking_since: the first saved game result (the
-- same on every row; null if none), as in get_leaderboard().
--
-- A SQL-language function: its body can't refer to its output columns, and
-- a column name always wins over a parameter name there, so no
-- #variable_conflict is needed (that directive is PL/pgSQL only).
create or replace function public.get_solo_stats(p_user_ids uuid[])
returns table (
  user_id uuid,
  level text,
  wins integer,
  losses integer,
  skunks integer,
  double_skunks integer,
  times_skunked integer,
  skunk_tracking_since timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select s.user_id,
         s.level,
         count(*) filter (where s.won)::int,
         count(*) filter (where not s.won)::int,
         count(*) filter (where s.won and s.loser_score between 61 and 90)::int,
         count(*) filter (where s.won and s.loser_score < 61)::int,
         count(*) filter (where not s.won and s.loser_score <= 90)::int,
         (select min(r.created_at) from public.game_results r)
  from public._solo_results() s
  where s.user_id = any(p_user_ids[1:50])
  group by s.user_id, s.level
  order by s.user_id,
           array_position(array['easy', 'casual', 'medium', 'hard'], s.level);
$$;

revoke all on function public.get_solo_stats(uuid[]) from public;
revoke all on function public.get_solo_stats(uuid[]) from anon;
revoke all on function public.get_solo_stats(uuid[]) from authenticated;
grant execute on function public.get_solo_stats(uuid[]) to authenticated;


-- ===========================================================================
-- 3. get_solo_leaderboard(): one level's ranking (the leaderboard filter).
-- ===========================================================================
-- Same columns and order as get_leaderboard(). Listed: players with a
-- non-blank nickname and at least one finished game at that level. Ranked by
-- that level's wins (most first), then its losses (fewest first). beat_god
-- is every player's God wins (for wings), whatever the level.
create or replace function public.get_solo_leaderboard(p_level text)
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
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if p_level is null or p_level not in ('easy', 'casual', 'medium', 'hard') then
    raise exception 'Unknown computer level.';
  end if;

  return query
  with lvl as (
    select s.user_id as uid,
           count(*) filter (where s.won) as w,
           count(*) filter (where not s.won) as l,
           count(*) filter (where s.won and s.loser_score between 61 and 90) as sk,
           count(*) filter (where s.won and s.loser_score < 61) as dsk,
           count(*) filter (where not s.won and s.loser_score <= 90) as tsk
    from public._solo_results() s
    where s.level = p_level
    group by s.user_id
  ),
  god as (
    select s.user_id as uid,
           count(*) as n
    from public._solo_results() s
    where s.level = 'hard'
      and s.won
    group by s.user_id
  )
  select pr.id,
         btrim(pr.nickname),
         pr.avatar_url,
         lvl.w::int,
         lvl.l::int,
         lvl.sk::int,
         lvl.dsk::int,
         lvl.tsk::int,
         coalesce(god.n, 0)::int,
         (select min(r.created_at) from public.game_results r)
  from lvl
  join public.profiles pr on pr.id = lvl.uid
  left join god on god.uid = lvl.uid
  where btrim(coalesce(pr.nickname, '')) <> ''
  order by lvl.w desc,
           lvl.l asc,
           lower(btrim(pr.nickname)) asc,
           pr.id asc;
end;
$$;

revoke all on function public.get_solo_leaderboard(text) from public;
revoke all on function public.get_solo_leaderboard(text) from anon;
revoke all on function public.get_solo_leaderboard(text) from authenticated;
grant execute on function public.get_solo_leaderboard(text) to authenticated;

commit;
