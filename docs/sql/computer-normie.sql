-- Computer opponents: the new Normie ('casual') and Rainman (today's Normie)
-- RUN in production on 2026-11-08 (Supabase Dashboard -> SQL Editor), as
-- recorded here. Kept for reference/history; this project has no Supabase
-- CLI/migrations set up yet. Do not run it again: section 4 refuses a second
-- run (the casual level and the new user are already set up).
--
-- ===========================================================================
-- HOW IT WAS RUN (2026-11-08), in order:
--
--   1. The read-only pre-check, docs/sql/computer-normie-precheck.sql, comes
--      before this file.
--   2. The new Normie account was created in the dashboard (Authentication
--      -> Users -> Add user) with the email normie@yodawood.com. Its user id,
--      14fec049-681d-47c5-81de-a176f9c59ed1, is written into section 4.
--   3. This file, with the medium computer's id
--      (740523b1-816f-4208-95c9-0d720238fd77) checked in section 4, and the
--      two computers' avatars set in the same block.
--   4. docs/sql/computer-normie-verification.sql: ALL 10 CHECKS PASSED.
-- ===========================================================================
--
-- THE LADDER after this file, easiest first:
--   easy    Shortbus  (unchanged)
--   casual  Normie    (NEW account)
--   medium  Rainman   (today's Normie: same account, same level value, same
--                      engine; only its nickname and picture change)
--   hard    God       (unchanged)
--
-- WHAT IT DOES (one transaction: if any statement fails, nothing is applied):
--   1. The 'casual' level is allowed in computer_accounts.level and
--      tables.computer_level (both check constraints re-created with the
--      four values).
--   2. create_computer_table accepts 'casual'. (N1) is the only change from
--      computer-c2-engine.sql: the level list and its error message.
--   3. get_computer_profiles sorts the four easiest first. (N2) is the only
--      change from nickname-unique-and-computer-profiles.sql: the sort order.
--      Grants on both functions are re-stated exactly as those files grant
--      them (revoke PUBLIC and anon, grant authenticated).
--   4. The medium account's nickname becomes "Rainman" (freeing "Normie",
--      since nicknames are unique) with its own picture, then the new user
--      gets a profile "Normie" with the old Normie's picture, and the
--      computer_accounts row ('casual').
--
-- EXISTING ROWS: the only existing row changed is the medium computer's
-- profile (nickname and avatar_url). No games, tables, seats or results change; old
-- 'medium' tables simply show Rainman, because every screen reads the name
-- from profiles by user id. Leaderboard and God wins are unaffected: they
-- leave every computer table out except 'hard' (Beat God).
--
-- NO NEW TABLE, so the AGENTS.md "New tables" grants rule does not apply.
-- No _as function or wrapper changes, so the computer-c1-verification.sql
-- fingerprints are unchanged.
--
-- Afterwards: docs/sql/computer-normie-verification.sql (passed, 10 checks,
-- 2026-11-08). computer-c2-verification.sql (create_computer_table changed)
-- was not re-run.
-- Rollback: docs/sql/computer-normie-rollback.sql.

begin;


-- ===========================================================================
-- 1. The 'casual' level in both check constraints
-- ===========================================================================
-- computer_accounts' check was written inline in computer-c2-engine.sql, so
-- Postgres named it computer_accounts_level_check (confirm with the
-- pre-check). If the live name differed, the drop would do nothing, the old
-- three-value check would stay, and step 4's insert would fail: safe.
alter table public.computer_accounts drop constraint if exists computer_accounts_level_check;
alter table public.computer_accounts
  add constraint computer_accounts_level_check
  check (level in ('easy', 'casual', 'medium', 'hard'));

alter table public.tables drop constraint if exists tables_computer_level_check;
alter table public.tables
  add constraint tables_computer_level_check
  check (computer_level is null or computer_level in ('easy', 'casual', 'medium', 'hard'));


-- ===========================================================================
-- 2. create_computer_table (computer-c2-engine.sql section 6, with (N1))
-- ===========================================================================
-- #variable_conflict use_column: the result columns are named table_id and
-- code, like the tables they describe, so inside the body a bare name means
-- the column; every reference below is qualified anyway.
create or replace function public.create_computer_table(p_level text, p_code text)
returns table (table_id uuid, code text)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_caller uuid := auth.uid();
  v_computer uuid;
  v_table_id uuid;
  v_code text;
begin
  if v_caller is null then
    raise exception 'You must be logged in to start a table.';
  end if;

  -- ===== (N1) CHANGED FOR NORMIE (start) =====
  -- The fourth level, 'casual' (Normie), between 'easy' and 'medium'.
  if p_level is null or p_level not in ('easy', 'casual', 'medium', 'hard') then
    raise exception 'Unknown computer level "%": choose easy, casual, medium or hard.', coalesce(p_level, '');
  end if;
  -- ===== (N1) CHANGED FOR NORMIE (end) =====

  select ca.user_id
  into v_computer
  from public.computer_accounts ca
  where ca.level = p_level;

  if v_computer is null then
    raise exception 'The % computer is not set up yet.', p_level;
  end if;

  if v_computer = v_caller then
    raise exception 'A computer account cannot start a computer table.';
  end if;

  -- The code is the client's, as for a normal table: a collision raises
  -- unique_violation (23505) here, uncaught, exactly like the direct insert.
  insert into public.tables (code, created_by, is_public, is_muggins, max_players, computer_level)
  values (p_code, v_caller, false, false, 2, p_level)
  returning tables.id, tables.code into v_table_id, v_code;

  -- The human first, then the computer: the seat trigger
  -- (assign_table_seat) gives the lowest free seat, so seats 1 and 2.
  insert into public.table_members (table_id, user_id)
  values (v_table_id, v_caller);

  insert into public.table_members (table_id, user_id)
  values (v_table_id, v_computer);

  table_id := v_table_id;
  code := v_code;
  return next;
end;
$$;

revoke all on function public.create_computer_table(text, text) from public;
revoke all on function public.create_computer_table(text, text) from anon;
grant execute on function public.create_computer_table(text, text) to authenticated;


-- ===========================================================================
-- 3. get_computer_profiles (nickname-unique-and-computer-profiles.sql, with (N2))
-- ===========================================================================
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
  -- ===== (N2) CHANGED FOR NORMIE (start) =====
  -- Easiest first: Shortbus, Normie, Rainman, God.
  order by case ca.level when 'easy' then 1 when 'casual' then 2 when 'medium' then 3 else 4 end;
  -- ===== (N2) CHANGED FOR NORMIE (end) =====
$$;

revoke all on function public.get_computer_profiles() from public;
revoke all on function public.get_computer_profiles() from anon;
grant execute on function public.get_computer_profiles() to authenticated;


-- ===========================================================================
-- 4. Rainman's nickname and avatar, and the new Normie account
-- ===========================================================================
-- The ids are fixed: the new Normie created in the dashboard on 2026-11-08
-- (normie@yodawood.com), and the medium computer as it was in production.
-- The new Normie takes over the old Normie's picture (blue-guy.jpg);
-- Rainman gets its own (Rainman.png). Both are in the avatars Storage bucket
-- under computers/.
do $$
declare
  v_new uuid := '14fec049-681d-47c5-81de-a176f9c59ed1';         -- the new Normie (casual)
  v_medium_expected uuid := '740523b1-816f-4208-95c9-0d720238fd77'; -- the medium computer (Rainman)
  v_rainman_avatar text := 'https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/avatars/computers/Rainman.png';
  v_normie_avatar text := 'https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/avatars/computers/blue-guy.jpg';

  v_medium uuid;
begin
  -- The medium computer (today's Normie) must exist, and be the expected one.
  select ca.user_id into v_medium
  from public.computer_accounts ca
  where ca.level = 'medium';
  if v_medium is null then
    raise exception 'SETUP: there is no medium computer account to rename.';
  end if;
  if v_medium is distinct from v_medium_expected then
    raise exception 'SETUP: the medium computer is %, expected %.', v_medium, v_medium_expected;
  end if;

  -- The new user: real, not already a computer, the casual level not taken,
  -- not an admin, not seated anywhere.
  if not exists (select 1 from auth.users u where u.id = v_new) then
    raise exception 'SETUP: no auth user has the id %.', v_new;
  end if;
  if exists (select 1 from public.computer_accounts ca where ca.user_id = v_new) then
    raise exception 'SETUP: % is already a computer account.', v_new;
  end if;
  if exists (select 1 from public.computer_accounts ca where ca.level = 'casual') then
    raise exception 'SETUP: the casual level is already set up.';
  end if;
  if exists (select 1 from public.admin_users ad where ad.user_id = v_new) then
    raise exception 'SETUP: % is an admin; use a fresh user.', v_new;
  end if;
  if exists (select 1 from public.table_members tm where tm.user_id = v_new) then
    raise exception 'SETUP: % is seated at a table; use a fresh user.', v_new;
  end if;

  -- Free "Normie" first: nicknames are unique (profiles_nickname_unique_idx),
  -- so if a human already held "Rainman" this would fail on 23505 and nothing
  -- would be applied -- the safe outcome. Rainman gets its own picture.
  update public.profiles
  set nickname = 'Rainman',
      avatar_url = v_rainman_avatar,
      updated_at = now()
  where id = v_medium;

  -- The new Normie, with the old Normie's picture (also on a conflict).
  insert into public.profiles (id, nickname, avatar_url, updated_at)
  values (v_new, 'Normie', v_normie_avatar, now())
  on conflict (id) do update
    set nickname = excluded.nickname,
        avatar_url = excluded.avatar_url,
        updated_at = now();

  insert into public.computer_accounts (level, user_id)
  values ('casual', v_new);
end;
$$;

commit;


-- ===========================================================================
-- AVATARS (set in section 4 when this ran, 2026-11-08)
-- ===========================================================================
-- Rainman (medium, 740523b1-816f-4208-95c9-0d720238fd77):
--   https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/avatars/computers/Rainman.png
-- Normie (casual, 14fec049-681d-47c5-81de-a176f9c59ed1), the old Normie's picture:
--   https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/avatars/computers/blue-guy.jpg
