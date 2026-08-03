-- Slice 3: "Start a Table"
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.

create table public.tables (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[0-9]{4}$'),
  status text not null default 'open',
  created_by uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.tables enable row level security;

-- Any logged-in user can read any table (needed so a player can look up a
-- table by its code to join it, in a later slice).
create policy "Tables are viewable by any logged-in user"
  on public.tables for select
  using (auth.role() = 'authenticated');

-- You can only create a table you're recorded as the creator of.
create policy "Users can create their own table"
  on public.tables for insert
  with check (auth.uid() = created_by);
