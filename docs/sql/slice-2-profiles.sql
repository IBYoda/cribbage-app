-- Slice 2: Profiles
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.

-- One row per user, keyed by their auth.users id.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  nickname text not null default '',
  avatar_url text,
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Any logged-in user can read every profile (needed so opponents can see each
-- other's nickname/avatar at a table later) -- but only the owner can write their own row.
create policy "Profiles are viewable by everyone"
  on public.profiles for select
  using (auth.role() = 'authenticated');

create policy "Users can insert their own profile"
  on public.profiles for insert
  with check (auth.uid() = id);

create policy "Users can update their own profile"
  on public.profiles for update
  using (auth.uid() = id);

-- Storage bucket for avatar images. Public bucket (simplest option for a small
-- trusted friend group -- no sensitive data in an avatar, so no signed URLs needed).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;

-- Each user can only write inside a folder named after their own user id
-- (path convention used by the app: "<user_id>/avatar.<ext>").
create policy "Avatar images are publicly accessible"
  on storage.objects for select
  using (bucket_id = 'avatars' and auth.role() = 'authenticated');

create policy "Users can upload their own avatar"
  on storage.objects for insert
  with check (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);

create policy "Users can update their own avatar"
  on storage.objects for update
  using (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);
