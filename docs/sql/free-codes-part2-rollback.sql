-- Step 3, slice B: ROLLBACK of docs/sql/free-codes-part2.sql.
-- Run in the Supabase Dashboard -> SQL Editor.
--
-- STATUS: written, NOT RUN yet. Kept for reference; run only if part 2 has
-- to come out. Part 1 and the app can stay as they are (they work with
-- either key).
--
-- What it does, in one transaction:
--   1. create_table and create_computer_table back to join-create.sql's text
--      exactly (the client's code again for single player; create_table
--      picks a code no table at all uses -- stricter than needed, correct
--      with or without reused codes).
--   2. drops _pick_table_code.
--   3. THE UNIQUE KEY -- ONE-WAY ONCE A CODE IS REUSED. If no code is shared
--      by two tables yet, tables_code_key comes back and the two part-2
--      indexes go. If any code has been reused, the key CAN'T come back
--      (the old rows would violate it): the partial unique index stays (at
--      most one open table per code still holds), and a NOTICE says so.
--      Renumbering ended tables' codes to make room would rewrite history;
--      this file doesn't.

begin;

-- 1. The two creates, as join-create.sql has them.
create or replace function public.create_table(
  p_is_public boolean,
  p_is_muggins boolean,
  p_max_players integer,
  p_team_mode text,
  p_allow_spectators boolean
)
returns table (table_id uuid, code text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_caller uuid := auth.uid();
  v_is_public boolean := coalesce(p_is_public, false);
  v_is_muggins boolean := coalesce(p_is_muggins, false);
  v_max integer := coalesce(p_max_players, 2);
  v_team text := coalesce(p_team_mode, 'teams');
  v_spectators boolean := coalesce(p_allow_spectators, false);
  v_code text;
  v_table_id uuid;
  v_try integer;
begin
  if v_caller is null then
    raise exception 'You must be logged in to start a table.';
  end if;

  if v_max not in (2, 3, 4) then
    raise exception 'A table seats 2, 3 or 4 players.';
  end if;

  if v_team not in ('teams', 'solo') then
    raise exception 'Choose Teams or Solo for a 4-player table.';
  end if;

  if v_is_muggins and v_max = 4 and v_team <> 'solo' then
    raise exception 'A 4-player Self-Scoring table plays Solo.';
  end if;

  -- One person, one table (the person's lock first, then the rule).
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('one_table:' || v_caller::text, 0));
  perform public._one_table_rule(v_caller, null, true);

  perform public._attempts_guard(v_caller, 'create_table', 10, interval '1 hour',
    'You can start at most 10 tables an hour. Please try again later.');

  for v_try in 1..5 loop
    -- A random code no table uses (slice B: no NON-ENDED table).
    select c.code
    into v_code
    from (select lpad(n::text, 4, '0') as code from generate_series(0, 9999) as n) c
    where not exists (select 1 from public.tables t where t.code = c.code)
    order by random()
    limit 1;

    if v_code is null then
      raise exception 'No table codes are free right now. Please try again in a few minutes.';
    end if;

    begin
      insert into public.tables (code, created_by, is_public, is_muggins, max_players, team_mode, allow_spectators)
      values (v_code, v_caller, v_is_public, v_is_muggins, v_max, v_team, v_spectators)
      returning tables.id into v_table_id;
      exit;
    exception when unique_violation then
      -- Taken since the pick: try another.
      v_table_id := null;
    end;
  end loop;

  if v_table_id is null then
    raise exception 'Could not find a free table code. Please try again.';
  end if;

  -- The creator's seat, through the seat trigger (seat 1).
  insert into public.table_members (table_id, user_id)
  values (v_table_id, v_caller);

  table_id := v_table_id;
  code := v_code;
  return next;
end;
$$;

comment on function public.create_table(boolean, boolean, integer, text, boolean) is
  'Start a Table (step 3, slice A): creates a human table with a free random 4-digit code and seats the caller in it. One table at a time (refused when seated elsewhere: DETAIL already_at_table, HINT the code; watching elsewhere ends), at most 10 an hour (DETAIL rate_limited). NULL options take the column defaults. Returns (table_id, code). See docs/sql/join-create.sql.';

revoke all on function public.create_table(boolean, boolean, integer, text, boolean) from public;
revoke all on function public.create_table(boolean, boolean, integer, text, boolean) from anon;
revoke all on function public.create_table(boolean, boolean, integer, text, boolean) from service_role;
grant execute on function public.create_table(boolean, boolean, integer, text, boolean) to authenticated;

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

  if p_level is null or p_level not in ('easy', 'casual', 'medium', 'hard') then
    raise exception 'Unknown computer level "%": choose easy, casual, medium or hard.', coalesce(p_level, '');
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

  -- ===== (J7) ONE TABLE AT A TIME, 10 AN HOUR (start) =====
  -- An unfinished single-player game of the caller's is ended first (as
  -- Leave does); refused when seated at a non-ended table with other
  -- humans; watching ends. Then at most 10 started an hour.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('one_table:' || v_caller::text, 0));
  perform public._one_table_rule(v_caller, null, true);
  perform public._attempts_guard(v_caller, 'create_computer_table', 10, interval '1 hour',
    'You can start at most 10 single-player games an hour. Please try again later.');
  -- ===== (J7) ONE TABLE AT A TIME, 10 AN HOUR (end) =====

  insert into public.tables (code, created_by, is_public, is_muggins, max_players, computer_level)
  values (p_code, v_caller, false, false, 2, p_level)
  returning tables.id, tables.code into v_table_id, v_code;

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

-- 2. The picker.
drop function if exists public._pick_table_code(integer);

-- 3. The unique key, only if it still fits.
do $$
begin
  if exists (select 1 from public.tables t group by t.code having count(*) > 1) then
    raise notice 'A code has been reused: tables_code_key can not come back. The partial unique index tables_code_open_key stays.';
    return;
  end if;
  if not exists (select 1 from pg_constraint con
                 where con.conrelid = 'public.tables'::regclass and con.conname = 'tables_code_key') then
    alter table public.tables add constraint tables_code_key unique (code);
  end if;
  drop index if exists public.tables_code_open_key;
  drop index if exists public.tables_code_idx;
end;
$$;

notify pgrst, 'reload schema';

commit;
