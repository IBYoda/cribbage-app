-- Slice 5: "New Game" (stub -- no cribbage logic, just an active-game marker)
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.

create table public.games (
  id uuid primary key default gen_random_uuid(),
  table_id uuid not null references public.tables (id) on delete cascade,
  status text not null default 'active',
  created_by uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

-- Only one active game per table at a time. This is what actually prevents
-- a race (two people clicking "New Game" at once) from creating duplicates --
-- the app-side check (hiding the button) is a UX nicety, not the guarantee.
create unique index games_one_active_per_table
  on public.games (table_id)
  where status = 'active';

alter table public.games enable row level security;

-- Any logged-in user can see game state (needed so everyone at a table sees
-- "game in progress" live, not just the person who started it).
create policy "Games are viewable by any logged-in user"
  on public.games for select
  using (auth.role() = 'authenticated');

-- You can only start a game (as yourself) at a table you're actually a
-- member of -- stricter than the tables/table_members insert policies,
-- since this is an action taken *within* a table you've already joined.
create policy "Table members can start a game"
  on public.games for insert
  with check (
    auth.uid() = created_by
    and exists (
      select 1 from public.table_members tm
      where tm.table_id = games.table_id
        and tm.user_id = auth.uid()
    )
  );

-- Required for the app's live "game in progress" state: broadcasts INSERT
-- events so everyone at the table sees a new game appear without reloading.
alter publication supabase_realtime add table public.games;
