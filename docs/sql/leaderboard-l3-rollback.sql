-- Leaderboard, L3 ROLLBACK
-- Run this in the Supabase Dashboard -> SQL Editor to undo
-- leaderboard-l3-hidden-accounts.sql. Kept here for reference/history.
--
-- WHAT IT DOES, and nothing else:
--   1. get_leaderboard() back to L2: its "create or replace function"
--      statement and grants, copied unchanged from
--      leaderboard-l2-function.sql (same signature, so the app keeps
--      working). Hidden accounts are then listed again, and their games
--      count again.
--   2. the table public.leaderboard_hidden dropped (its rows go with it).
-- The function is restored FIRST, so it never reads a table that is gone.
--
-- THE HIDDEN LIST IS LOST WHEN THE TABLE IS DROPPED. So this file REFUSES to
-- run while leaderboard_hidden has any rows, and changes nothing. To roll
-- back anyway, first note the rows if they matter, then run this whole file
-- with this line added straight after "begin;":
--   set local leaderboard.l3_drop_hidden = 'on';
--
-- One transaction: if any statement fails (the guard included), nothing is
-- applied.

begin;

do $$
declare
  v_rows bigint;
begin
  if to_regclass('public.leaderboard_hidden') is null then
    return;
  end if;

  execute 'select count(*) from public.leaderboard_hidden' into v_rows;

  if v_rows > 0 and coalesce(current_setting('leaderboard.l3_drop_hidden', true), '') <> 'on' then
    raise exception 'public.leaderboard_hidden holds % hidden account(s). Nothing was changed. See the header to roll back anyway.', v_rows;
  end if;

  if v_rows > 0 then
    raise warning 'Dropping public.leaderboard_hidden with % hidden account(s).', v_rows;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. get_leaderboard(), exactly as in leaderboard-l2-function.sql.
-- ---------------------------------------------------------------------------
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


-- ---------------------------------------------------------------------------
-- 2. The table.
-- ---------------------------------------------------------------------------
drop table if exists public.leaderboard_hidden;

commit;
