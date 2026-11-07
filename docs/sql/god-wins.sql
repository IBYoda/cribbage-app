-- Wings: get_god_wins(), how many times each player has beaten God.
-- Run this in the Supabase Dashboard -> SQL Editor, AFTER
-- leaderboard-l3-hidden-accounts.sql (live). Kept here for reference/history;
-- this project has no Supabase CLI/migrations set up yet.
--
-- WHAT IT ADDS (and god-wins-rollback.sql removes exactly this): one read-only
-- function. No table, column, index or policy, and nothing stored: the count is
-- worked out from games each time, so it can't be forged and can't drift.
--
-- THE RULES: a won game (ended_reason 'won') at a table against God
-- (computer_level 'hard'), won by a human. Computer accounts and hidden test
-- accounts are left out. A God table is always 2-player, private and not
-- Muggins, so Teams never applies. Abandoned games are never 'won'.
--
-- RLS: security definer, so it reads computer_accounts and leaderboard_hidden,
-- which no client can. It returns only a count per user, which get_leaderboard()
-- already gives every signed-in player, and it reads at most 50 ids a call.
--
-- GRANTS: EXECUTE for authenticated only. anon and PUBLIC have none.
--
-- Checks: docs/sql/god-wins-verification.sql. The app runs fine before this
-- file does: a failed read just means no wings (lib/godWins.ts).

begin;
create or replace function public.get_god_wins(p_user_ids uuid[])
returns table (user_id uuid, god_wins integer)
language sql stable security definer set search_path = public
as $$
  select g.winner_id, count(*)::int
  from public.games g
  join public.tables t on t.id = g.table_id
  where g.ended_reason = 'won'
    and t.computer_level = 'hard'
    and g.winner_id = any(p_user_ids[1:50])
    and not exists (select 1 from public.computer_accounts ca where ca.user_id = g.winner_id)
    and not exists (select 1 from public.leaderboard_hidden h where h.user_id = g.winner_id)
  group by g.winner_id;
$$;
revoke all on function public.get_god_wins(uuid[]) from public;
revoke all on function public.get_god_wins(uuid[]) from anon;
revoke all on function public.get_god_wins(uuid[]) from authenticated;
grant execute on function public.get_god_wins(uuid[]) to authenticated;
commit;
