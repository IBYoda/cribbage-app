-- Slice 7: Admin view
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.

create table public.admin_users (
  user_id uuid primary key references auth.users (id) on delete cascade,
  granted_at timestamptz not null default now()
);

alter table public.admin_users enable row level security;

-- You can only check your OWN admin status this way -- not list every admin.
-- Enough for the app to answer "am I an admin?" without exposing the full
-- admin roster to anyone who happens to be one.
create policy "Users can check their own admin status"
  on public.admin_users for select
  using (auth.uid() = user_id);

-- Deliberately no insert/update/delete policy for regular users. With RLS
-- enabled and no matching policy, Postgres denies by default -- so there is
-- no way to grant yourself (or anyone) admin through the app. The only way
-- to add an admin is a manual insert run directly in the SQL Editor, which
-- runs with elevated privileges that bypass RLS entirely.

-- Admins can force-end any table or game. (The existing SELECT policies from
-- Slices 3 and 5 already let any authenticated user read all tables/games --
-- neither table has ever had an UPDATE policy until now, so this is also the
-- first time *any* update to these rows is possible through the API at all.)
create policy "Admins can force-end tables"
  on public.tables for update
  using (exists (select 1 from public.admin_users a where a.user_id = auth.uid()))
  with check (exists (select 1 from public.admin_users a where a.user_id = auth.uid()));

create policy "Admins can force-end games"
  on public.games for update
  using (exists (select 1 from public.admin_users a where a.user_id = auth.uid()))
  with check (exists (select 1 from public.admin_users a where a.user_id = auth.uid()));

-- Needed so a connected player's table page notices live when an admin ends
-- the table they're sitting at. `games` was already added to this publication
-- in Slice 5 (and UPDATE events are already enabled at the publication level,
-- confirmed during Slice 4) -- `tables` was never added until now.
alter publication supabase_realtime add table public.tables;

-- ---------------------------------------------------------------------------
-- One-time manual step: make yourself an admin.
-- Run the SELECT first to find your user id, then use it in the INSERT below.
-- ---------------------------------------------------------------------------

-- select id, email from auth.users where email = 'you@example.com';

-- insert into public.admin_users (user_id) values ('paste-your-user-id-here');
