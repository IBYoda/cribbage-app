-- Table visibility: a public/private flag on tables, for the lobby
-- ("Available tables").
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- WHAT IT DOES: adds ONE column, public.tables.is_public (boolean, NOT NULL,
-- default false). Nothing else: no policy, grant, trigger, index or Realtime
-- change.
--
-- WHY: the lobby will list tables whose creator chose Public. In this first
-- version "private" only means UNLISTED -- the table is not shown in the
-- lobby. Anyone with the 4-digit code can still look it up and join it,
-- exactly as today, because the SELECT policy is unchanged ("Tables are
-- viewable by any logged-in user", slice-3-tables.sql). Tightening reads to
-- "listed tables or your own" is a separate, later change (PRD Section 11.5,
-- "Broad read access").
--
-- EXISTING ROWS: the default is false, so every existing table becomes
-- private. Adding a NOT NULL column with a constant default is a catalog-only
-- change in Postgres 11+ (no table rewrite, no long lock).
--
-- WRITING IT: only on INSERT, by the creator. The existing INSERT policy
-- ("Users can create their own table": WITH CHECK auth.uid() = created_by)
-- does not look at other columns, and authenticated's INSERT privilege on
-- tables is table-level (Supabase's default; this project never made it
-- column-level), so a client insert of {code, created_by, is_public} works
-- with no grant or policy change.
--
-- CHANGING IT LATER: not possible for players. The only UPDATE policy on
-- tables is "Admins can force-end tables" (slice-7-admin.sql), so a
-- non-admin's UPDATE matches no row. BUT authenticated's UPDATE privilege is
-- also table-level, so an ADMIN can change is_public through the API. See
-- section 2 below: a proposed fix, NOT applied by this file.
--
-- REALTIME: tables is already in the supabase_realtime publication
-- (slice-7-admin.sql). The publication is not touched; table UPDATE events
-- will simply carry the new column too.
--
-- NO INDEX: tables holds a handful of rows (friends only, 12-hour timeout),
-- so the lobby query scans it in microseconds.
--
-- RE-RUNNABLE: "add column if not exists" and "comment on" are both safe to
-- repeat. Running it twice changes nothing.
--
-- ROLLBACK (removes the column and its comment; nothing else depends on it
-- until the app ships the lobby):
--   alter table public.tables drop column if exists is_public;
--
-- Checks: docs/sql/table-visibility-verification.sql -- a rolled-back
-- walk-through as two (or three) real players, plus catalog checks.


-- ---------------------------------------------------------------------------
-- 1. The column.
-- ---------------------------------------------------------------------------
alter table public.tables
  add column if not exists is_public boolean not null default false;

comment on column public.tables.is_public is
  'Listed in the lobby ("Available tables") when true. Private (false, the default) only means UNLISTED: anyone with the 4-digit code can still join. Set by the creator on insert; players cannot change it afterwards (only the admin UPDATE policy exists).';


-- ---------------------------------------------------------------------------
-- 2. PROPOSED, NOT APPLIED -- needs Walt's decision.
--
-- The admin UPDATE policy plus the table-level UPDATE grant mean an admin can
-- change ANY column of a table through the API, is_public included (and
-- code, created_by, created_at too -- that is true today already). The
-- narrowest fix is a column-level UPDATE grant: the client only ever updates
-- status and ended_reason (app/admin/page.tsx, the admin Force-End), and the
-- server-side writers (end_timed_out_sessions, leave_table) are security
-- definer, so they run as the owner and are unaffected by this grant.
--
-- To apply it, uncomment and run these two statements (re-runnable):
--
--   revoke update on table public.tables from authenticated;
--   grant update (status, ended_reason) on table public.tables to authenticated;
--
-- (anon's default UPDATE privilege can go the same way --
--   revoke update on table public.tables from anon;
-- -- anon already matches no UPDATE policy, so it changes nothing in
-- practice.)
--
-- The verification file reports which of the two states it found.
-- ---------------------------------------------------------------------------
