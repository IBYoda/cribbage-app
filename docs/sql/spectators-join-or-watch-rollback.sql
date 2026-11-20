-- Rollback of docs/sql/spectators-join-or-watch.sql.
-- Run in the Supabase Dashboard -> SQL Editor.
--
-- STATUS: kept for reference; NOT run. The file it undoes was run in
-- Supabase on 2026-11-20 and verified (ALL 32 CHECKS PASSED, rolled back).
--
-- 1. The avatar address check comes out:
alter table public.profiles drop constraint if exists profiles_avatar_url_project_storage;

-- 2. watch_table and spectator_heartbeat go back to their slice-1 text:
--    re-run, from docs/sql/spectators.sql, section "3a. watch_table(code)"
--    and section "3d. spectator_heartbeat(table)" (each is one
--    "create or replace function ... $$;" plus its comment). Nothing else in
--    that file needs re-running; the grants stay as they are.
--    (Their header comments were corrected on 2026-11-20; the code is what
--    matters.)
--    (With the old text back, a table with no live game refuses watching with
--    "There is no game to watch at this table yet." and the heartbeat stops
--    refreshing the place while no game is live. The app tolerates both.)
