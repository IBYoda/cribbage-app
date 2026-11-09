-- Computer opponents, Normie/Rainman: ROLLBACK of computer-normie.sql
-- Run this in the Supabase Dashboard -> SQL Editor only to undo
-- computer-normie.sql. NOT RUN YET. Kept here for reference/history.
--
-- WHAT IT DOES (one transaction: if any statement fails, nothing is applied):
--   1. Closes any OPEN Normie ('casual') table the way leave_computer_table
--      does: its live game ends as 'player_left', both seats go, the table is
--      'ended'. Ended games and tables are left exactly as they are.
--   2. Retires the new Normie account: its nickname becomes
--      "Retired computer" (freeing "Normie"), and its computer_accounts row
--      is deleted. Delete the auth user itself afterwards in the dashboard
--      (Authentication -> Users) if you want it gone.
--   3. Renames the medium computer back to "Normie" and gives it back the
--      old Normie picture (blue-guy.jpg), as before computer-normie.sql.
--   4. Restores computer_accounts' level check to the three values.
--      tables_computer_level_check deliberately KEEPS 'casual': ended Normie
--      tables still carry it, and rewriting their history to fit the old
--      check would be worse than a fourth value nothing can create any more
--      (create_computer_table refuses 'casual' again, step 5).
--   5. Restores create_computer_table and get_computer_profiles EXACTLY as in
--      computer-c2-engine.sql (section 6) and
--      nickname-unique-and-computer-profiles.sql, with their grants.
--
-- Deploy the app build without the 'casual' level in the same sitting.

begin;

-- 1. Close any open Normie table (leave_computer_table's three steps).
update public.games g
set status = 'ended', ended_reason = 'player_left'
from public.tables t
where t.id = g.table_id
  and t.computer_level = 'casual'
  and t.status = 'open'
  and g.status in ('cutting', 'active');

delete from public.table_members tm
using public.tables t
where t.id = tm.table_id
  and t.computer_level = 'casual'
  and t.status = 'open';

update public.tables
set status = 'ended'
where computer_level = 'casual'
  and status = 'open';

-- 2. Retire the new Normie (free its name, then drop it as a computer).
update public.profiles
set nickname = 'Retired computer',
    updated_at = now()
where id = (select ca.user_id from public.computer_accounts ca where ca.level = 'casual');

delete from public.computer_accounts
where level = 'casual';

-- 3. Rainman back to Normie, with the old Normie picture.
update public.profiles
set nickname = 'Normie',
    avatar_url = 'https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/avatars/computers/blue-guy.jpg',
    updated_at = now()
where id = (select ca.user_id from public.computer_accounts ca where ca.level = 'medium');

-- 4. computer_accounts back to three levels (tables keeps 'casual', above).
alter table public.computer_accounts drop constraint if exists computer_accounts_level_check;
alter table public.computer_accounts
  add constraint computer_accounts_level_check
  check (level in ('easy', 'medium', 'hard'));

-- 5a. create_computer_table, exactly as computer-c2-engine.sql section 6.
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

  if p_level is null or p_level not in ('easy', 'medium', 'hard') then
    raise exception 'Unknown computer level "%": choose easy, medium or hard.', coalesce(p_level, '');
  end if;

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

-- 5b. get_computer_profiles, exactly as nickname-unique-and-computer-profiles.sql.
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
