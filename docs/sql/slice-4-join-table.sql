-- Slice 4: "Join a Table"
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.

create table public.table_members (
  table_id uuid not null references public.tables (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (table_id, user_id)
);

alter table public.table_members enable row level security;

-- Any logged-in user can see who's at any table (needed so everyone at a
-- table can see the full roster, not just their own membership row).
create policy "Table members are viewable by any logged-in user"
  on public.table_members for select
  using (auth.role() = 'authenticated');

-- You can only add yourself to a table, not add other people.
create policy "Users can add themselves to a table"
  on public.table_members for insert
  with check (auth.uid() = user_id);

-- Required for the app's live-updating member list: adds this table to the
-- Realtime publication so Postgres INSERT events are broadcast to subscribed
-- clients. Without this, everything else works but nothing updates live.
alter publication supabase_realtime add table public.table_members;

-- NEW (added after initial testing): also broadcast profile UPDATEs, so a
-- nickname change shows up live for anyone already viewing a table roster,
-- not just on their next join/reload. This is the only new statement below
-- -- everything above this point was already run and doesn't need rerunning.
alter publication supabase_realtime add table public.profiles;
