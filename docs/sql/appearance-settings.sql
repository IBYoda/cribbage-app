-- Appearance settings: each player's own card back and table surface
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- WHAT IT STORES: one row per player -- the card back and table surface they
-- picked on the Profile page (lib/appearance.ts), so the choice follows them
-- across devices. Purely cosmetic, and only ever used on that player's OWN
-- screen.
--
-- WHY A TABLE OF ITS OWN, NOT COLUMNS ON profiles: profiles is readable by
-- every logged-in user and is in the Realtime publication (the table page
-- streams its updates to everyone at the table). A player's appearance must
-- never reach anyone else, so it lives here instead:
--   * readable and writable ONLY by its owner (RLS, below);
--   * NOT in the supabase_realtime publication -- this file never adds it,
--     and nothing else should;
--   * nothing about it touches the game tables.
--
-- A MISSING ROW MEANS CLASSIC: existing and new accounts have no row until
-- they first save, and the app treats "no row" exactly like
-- ('classic', 'classic') -- today's look. The first Save inserts the row
-- (an upsert); later saves update it.
--
-- THE ALLOWED VALUES are exactly the ids in lib/appearance.ts. Adding a back
-- or a surface later means changing BOTH that file and the CHECK here (drop
-- the named constraint, add it again with the new list).
--
-- updated_at: set by the client on every save (there is no trigger -- it is
-- informational only, nothing reads it).
--
-- RE-RUNNABLE: "create table if not exists", constraints named, grants and
-- revokes idempotent, each policy dropped (if it exists) before it is
-- created. Running it twice changes nothing.
--
-- Checks: docs/sql/appearance-settings-verification.sql -- a rolled-back
-- walk-through, plus catalog checks (grants, policies, publication).


-- ---------------------------------------------------------------------------
-- 1. The table.
-- ---------------------------------------------------------------------------
create table if not exists public.user_appearance (
  user_id uuid primary key references auth.users (id) on delete cascade,
  card_back text not null default 'classic'
    constraint user_appearance_card_back_check
    check (card_back in (
      'classic', 'metallic-black', 'vintage', 'oktoberfish',
      'plain-black', 'standard-red', 'standard-blue'
    )),
  table_surface text not null default 'classic'
    constraint user_appearance_table_surface_check
    check (table_surface in (
      'classic', 'black', 'green-felt', 'blue-felt', 'wood'
    )),
  updated_at timestamptz not null default now()
);


-- ---------------------------------------------------------------------------
-- 2. Row-level security: on. With RLS on, a role that has a table privilege
-- still sees and touches ONLY the rows a policy allows.
-- ---------------------------------------------------------------------------
alter table public.user_appearance enable row level security;


-- ---------------------------------------------------------------------------
-- 3. Grants, explicit rather than inherited from Supabase's defaults (which
-- grant every privilege on new public tables to anon and authenticated).
--   * PUBLIC and anon: nothing at all.
--   * authenticated: SELECT, INSERT, UPDATE -- and nothing else. No DELETE
--     (there is no delete path: a player who wants Classic back saves
--     Classic), no TRUNCATE, REFERENCES or TRIGGER.
-- Revoking everything first makes this idempotent and removes any default
-- grant the table picked up when it was created.
-- ---------------------------------------------------------------------------
revoke all on table public.user_appearance from public;
revoke all on table public.user_appearance from anon;
revoke all on table public.user_appearance from authenticated;

grant select, insert, update on table public.user_appearance to authenticated;


-- ---------------------------------------------------------------------------
-- 4. Policies -- all for authenticated, all limited to the caller's own row.
-- No DELETE policy (and no DELETE grant above).
-- ---------------------------------------------------------------------------

-- Read: only your own row.
drop policy if exists "Players read their own appearance" on public.user_appearance;

create policy "Players read their own appearance"
  on public.user_appearance for select
  to authenticated
  using (auth.uid() = user_id);

-- Insert: only a row keyed to yourself.
drop policy if exists "Players create their own appearance" on public.user_appearance;

create policy "Players create their own appearance"
  on public.user_appearance for insert
  to authenticated
  with check (auth.uid() = user_id);

-- Update: only your own row (USING), and the row must still be yours
-- afterwards (WITH CHECK) -- so it can never be re-keyed to someone else.
drop policy if exists "Players update their own appearance" on public.user_appearance;

create policy "Players update their own appearance"
  on public.user_appearance for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);


-- ---------------------------------------------------------------------------
-- 5. Realtime: deliberately NOTHING. The table is not added to the
-- supabase_realtime publication, so no change to it is ever broadcast.
-- (The verification file checks that it isn't there.)
-- ---------------------------------------------------------------------------
