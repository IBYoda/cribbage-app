-- Hide counts: a personal display setting on each player's appearance row
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- WHAT IT DOES: adds ONE column, public.user_appearance.hide_counts
-- (boolean, NOT NULL, default false). Nothing else: no policy, grant,
-- trigger, index or Realtime change.
--
-- WHY: a player can choose to hide the hand and crib count numbers on their
-- OWN screen (so they count for themselves). It is a display setting like
-- the card back and table surface, so it lives with them in
-- user_appearance (docs/sql/appearance-settings.sql), which is:
--   * readable and writable ONLY by its owner (RLS: SELECT, INSERT and
--     UPDATE, each "auth.uid() = user_id", whole rows, no column lists);
--   * granted to authenticated as table-level SELECT, INSERT, UPDATE (no
--     column-level grants), and nothing to anon or PUBLIC;
--   * NOT in the supabase_realtime publication.
-- So the new column is covered by the existing grants and policies as it
-- stands, and never reaches another player.
--
-- EXISTING ROWS: the default is false, so every existing row reads "counts
-- shown" -- today's behaviour. A missing row still means all defaults (the
-- app treats no row as Classic, and now also as hide_counts = false).
-- Adding a NOT NULL column with a constant default is a catalog-only change
-- in Postgres 11+ (no table rewrite, no long lock).
--
-- RE-RUNNABLE: "add column if not exists" and "comment on" are both safe to
-- repeat. Running it twice changes nothing.
--
-- ROLLBACK (removes the column and its comment; nothing depends on it until
-- the app reads it):
--   alter table public.user_appearance drop column if exists hide_counts;
--
-- Checks: docs/sql/hide-counts-verification.sql -- a rolled-back walk-through
-- as two real players, plus catalog checks.


alter table public.user_appearance
  add column if not exists hide_counts boolean not null default false;

comment on column public.user_appearance.hide_counts is
  'Personal display setting: when true, hides the hand and crib count numbers on this player''s own screen. Never reaches other players (user_appearance is owner-only and not in Realtime).';
