-- Wings: removes everything docs/sql/god-wins.sql added.
-- Safe with the app live: a failed read just means no wings (lib/godWins.ts).

begin;
drop function if exists public.get_god_wins(uuid[]);
commit;
