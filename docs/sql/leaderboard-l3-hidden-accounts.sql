-- Leaderboard, L3: hidden (test) accounts
-- Run this in the Supabase Dashboard -> SQL Editor, AFTER
-- leaderboard-l2-function.sql (live). Kept here for reference/history; this
-- project has no Supabase CLI/migrations set up yet.
--
-- WHY: test accounts play test games. Listed, they clutter the leaderboard;
-- worse, a real player who beats a test account gets a padded record. So a
-- hidden account is never listed, AND every game it played in counts for
-- nobody -- not for it, not for the real players at that table.
--
-- WHAT IT ADDS (and leaderboard-l3-rollback.sql removes exactly this):
--   1. TABLE public.leaderboard_hidden (user_id, reason, created_at): the
--      hidden accounts. Managed by hand in the SQL Editor (no app screen).
--      Row-level security on, NO policies, every privilege revoked from
--      PUBLIC, anon and authenticated (AGENTS.md "New tables", the same
--      pattern as game_results): only get_leaderboard() (security definer)
--      reads it. No foreign key, on purpose: a row never blocks deleting an
--      account. Not in the Realtime publication.
--   2. get_leaderboard(), replaced with the SAME signature, columns, order,
--      security definer, search_path, stable and grants as L2, and exactly
--      two changes, each marked (H1) / (H2) below:
--        (H1) a COUNTED GAME also has no hidden account anywhere in
--             games.players. Such a game counts for nobody: no win, loss,
--             skunk, double skunk or times skunked for anyone in it.
--             Beat God is unchanged: it reads games of its own (a human
--             against the hard computer), and a hidden account is never
--             listed anyway.
--        (H2) a hidden account is never a row.
--      Everything else is L2's text, unchanged.
--
-- HIDING AN ACCOUNT (as the owner, in the SQL Editor). The placeholder id
-- below is NOT a real account -- put the account's id in its place:
--   insert into public.leaderboard_hidden (user_id, reason)
--   values ('00000000-0000-0000-0000-000000000000', 'test account')
--   on conflict (user_id) do nothing;
-- Showing it again: delete its row. Either takes effect on the next read --
-- the leaderboard is computed fresh every time, nothing is stored.
--
-- GRANTS: none for any client role on the table; get_leaderboard() keeps
-- EXECUTE for authenticated only. service_role: nothing needs it.
--
-- RE-RUNNABLE: "create table if not exists", idempotent revokes, "create or
-- replace function" with the same signature, idempotent grants.
--
-- Checks: docs/sql/leaderboard-l3-verification.sql -- one rolled-back
-- walk-through (it supersedes leaderboard-l2-verification.sql once this file
-- is applied).
--
-- One transaction: if any statement fails, nothing is applied.

begin;

-- ===========================================================================
-- 1. public.leaderboard_hidden
-- ===========================================================================
create table if not exists public.leaderboard_hidden (
  user_id uuid primary key,
  reason text,
  created_at timestamptz not null default now()
);

comment on table public.leaderboard_hidden is
  'Accounts kept off the leaderboard (test accounts), managed by hand in the SQL Editor. A hidden account is never listed, and every game it played in counts for nobody. Read only by get_leaderboard() (security definer). No client role has any privilege on it, and RLS is on with no policies.';

-- Row-level security on, with NO policies: deny by default.
alter table public.leaderboard_hidden enable row level security;

-- Grants, explicit (AGENTS.md "New tables", template appearance-settings.sql):
-- nothing for PUBLIC, anon or authenticated. Revoking everything also
-- removes any default grant the table picked up when it was created.
revoke all on table public.leaderboard_hidden from public;
revoke all on table public.leaderboard_hidden from anon;
revoke all on table public.leaderboard_hidden from authenticated;

-- No policies: deliberately none. No Realtime: deliberately not added to the
-- supabase_realtime publication.


-- ===========================================================================
-- 2. get_leaderboard() -- L2's function with (H1) and (H2).
-- ===========================================================================
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
      -- ===== (H1) CHANGED FOR L3 (start) =====
      -- No hidden account anywhere in the game: such a game counts for
      -- nobody.
      and not exists (
        select 1
        from public.leaderboard_hidden h
        where h.user_id = any(g.players)
      )
      -- ===== (H1) CHANGED FOR L3 (end) =====
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
    -- ===== (H2) CHANGED FOR L3 (start) =====
    -- A hidden account is never a row.
    and not exists (select 1 from public.leaderboard_hidden h where h.user_id = pr.id)
    -- ===== (H2) CHANGED FOR L3 (end) =====
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
