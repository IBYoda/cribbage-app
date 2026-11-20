-- Spectators follow-up: the Start a Table form inserts allow_spectators, and authenticated only had column-level INSERT on a fixed list of columns.
grant insert (allow_spectators) on public.tables to authenticated;
-- Rollback: revoke insert (allow_spectators) on public.tables from authenticated;
