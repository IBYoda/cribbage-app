-- Solo stats: removes everything docs/sql/solo-stats.sql added (three
-- read-only functions; no table, column, index or policy was added, and no
-- other function changed).
-- Safe with the app live as long as no deployed build calls get_solo_stats
-- or get_solo_leaderboard yet (S1 ships SQL only).
-- The two public functions go first: they call _solo_results.

begin;
drop function if exists public.get_solo_leaderboard(text);
drop function if exists public.get_solo_stats(uuid[]);
drop function if exists public._solo_results();
commit;
