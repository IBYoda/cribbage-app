-- Spectator seat, slice 1: removes everything docs/sql/spectators.sql added
-- -- the five functions, the table public.table_spectators (with its policy,
-- grants and every spectator row), the check tables_spectators_human_only
-- and the column tables.allow_spectators -- and nothing else.
-- STATUS: Kept for reference; not run.
-- Safe with the app live as long as no deployed app reads allow_spectators
-- or calls the spectator functions: once it has run, a Watch button or
-- watch page would get "column does not exist" / "function does not exist".
-- No game, seat or score is touched (spectators never were table_members).
-- The functions go first (nothing depends on them), then the table (its
-- policy goes with it), then the check, then the column it reads.

begin;
drop function if exists public.get_spectator_reveals(uuid);
drop function if exists public.spectator_heartbeat(uuid);
drop function if exists public.remove_spectator(uuid, uuid);
drop function if exists public.stop_watching(uuid);
drop function if exists public.watch_table(text);
drop table if exists public.table_spectators;
alter table public.tables drop constraint if exists tables_spectators_human_only;
alter table public.tables drop column if exists allow_spectators;
commit;
