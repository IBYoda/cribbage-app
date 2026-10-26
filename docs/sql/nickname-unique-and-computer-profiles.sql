-- Unique nicknames, and the computer profiles by account id
-- ALREADY APPLIED LIVE (the index and the function) -- recorded here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
-- Idempotent: "if not exists" and "create or replace", so re-running it
-- changes nothing.
--
-- WHY:
--   * profiles_nickname_unique_idx: nicknames are unique, case-insensitive
--     and ignoring surrounding spaces (empty nicknames are exempt), so no
--     player can take a computer's name (Shortbus, Normie, God) -- or anyone
--     else's -- and be mistaken for it. The app shows "That nickname is
--     taken." on the unique violation (23505).
--   * get_computer_profiles(): the computer opponents' profiles (level,
--     account id, nickname, avatar), found by account id through
--     computer_accounts. That table has no client access, so the app can't
--     join it itself; this security definer function returns just these
--     three public profile rows, to signed-in users only.

begin;

create unique index if not exists profiles_nickname_unique_idx
  on public.profiles (lower(btrim(nickname)))
  where btrim(nickname) <> '';

create or replace function public.get_computer_profiles()
returns table (level text, user_id uuid, nickname text, avatar_url text)
language sql
stable
security definer
set search_path = public
as $$
  select ca.level, ca.user_id, p.nickname, p.avatar_url
  from public.computer_accounts ca
  join public.profiles p on p.id = ca.user_id
  order by case ca.level when 'easy' then 1 when 'medium' then 2 else 3 end;
$$;

revoke all on function public.get_computer_profiles() from public;
revoke all on function public.get_computer_profiles() from anon;
grant execute on function public.get_computer_profiles() to authenticated;

commit;
