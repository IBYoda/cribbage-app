-- Step 3, slice B, PART 2: FREE TABLE CODES (the partial unique index) and
-- the 24-hour reuse cooldown.
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- WHEN: LAST, only after
--   * docs/sql/free-codes-part1.sql ran and the verification passed, and
--   * the app build that holds table ids is LIVE (?t= links, the confirm
--     screens, p_table_id on joins and rewatches) -- give open tabs time to
--     reload (a deploy plus an hour is plenty; tabs reload on the next
--     visit). An old tab that resolves a reused code by code could land on
--     the new table: that is what the app of step 2 prevents.
-- Then run docs/sql/free-codes-precheck.sql first (its part-2 rows) and,
-- after this file, docs/sql/free-codes-verification.sql (its P checks run).
--
-- ONE-WAY: the moment any code is reused (two tables, one ended, share a
-- code), tables_code_key can never be put back. The rollback
-- (free-codes-part2-rollback.sql) restores the functions, and the unique key
-- only if no code has been reused yet.
--
-- WHAT THIS FILE DOES (one transaction):
--   1. Guard: part 1 is in (ended_at, its trigger, the new join/watch
--      signatures) and no two NON-ENDED tables share a code; else nothing
--      changes.
--   2. tables_code_open_key: UNIQUE (code) WHERE status <> 'ended' -- at most
--      one open table per code, any number of ended ones. tables_code_idx:
--      a plain index on code (every row: the cooldown's last-end lookup).
--      Then tables_code_key (UNIQUE across every table ever) is dropped.
--      The code's format check (tables_code_check) stays.
--   3. _pick_table_code(p_min_free DEFAULT 1000): the code picker, owner
--      only (like the slice A helpers). A random code that no open table
--      holds and that no table ended with in the last 24 hours, while at
--      least p_min_free such codes exist; below that, a free code with the
--      least recent end (never used first), random among the 20 least
--      recent. NULL only when every code is held by an open table.
--   4. create_table: its code pick is _pick_table_code (nothing else
--      changes: up to 5 tries for a race, the same messages).
--   5. create_computer_table: the SERVER picks the code too, with the same
--      cooldown; p_code is ignored (kept in the signature so every app still
--      calls it the same way; the app's 23505 retry is simply never reached).
--      Why: with the client picking, a single-player table could take a code
--      that ended a minute ago -- exactly the stale-link case the cooldown
--      exists for -- and the client can't see ended_at.
--
-- NOT TOUCHED: everything part 1 lists, and the join/watch functions (part
-- 1 already made them id-aware).

begin;

-- ---------------------------------------------------------------------------
-- 1. Guard.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.join_table_by_code(text, boolean, uuid)') is null
     or to_regprocedure('public.watch_table(text, uuid)') is null
     or not exists (select 1 from pg_attribute a
                    where a.attrelid = 'public.tables'::regclass and a.attname = 'ended_at' and not a.attisdropped)
     or not exists (select 1 from pg_trigger tg
                    where tg.tgrelid = 'public.tables'::regclass and tg.tgname = 'tables_set_ended_at') then
    raise exception 'STOP: free-codes-part1.sql has not run (ended_at, its trigger or the new join/watch signatures missing). Nothing was changed.';
  end if;
  if exists (select 1 from public.tables t where t.status <> 'ended'
             group by t.code having count(*) > 1) then
    raise exception 'STOP: two open tables share a code. Nothing was changed.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 2. The partial unique index replaces the unique key.
-- ---------------------------------------------------------------------------
create unique index if not exists tables_code_open_key
  on public.tables (code)
  where status <> 'ended';

create index if not exists tables_code_idx
  on public.tables (code);

alter table public.tables
  drop constraint if exists tables_code_key;


-- ---------------------------------------------------------------------------
-- 3. _pick_table_code.
-- ---------------------------------------------------------------------------
create or replace function public._pick_table_code(p_min_free integer default 1000)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_free integer;
  v_code text;
begin
  -- How many codes are free AND outside the cooldown: no open table holds
  -- them, and no table ended with them in the last 24 hours.
  select count(*)
  into v_free
  from generate_series(0, 9999) as n
  where not exists (
      select 1 from public.tables t
      where t.code = lpad(n::text, 4, '0') and t.status <> 'ended'
    )
    and not exists (
      select 1 from public.tables t
      where t.code = lpad(n::text, 4, '0') and t.status = 'ended'
        and t.ended_at > now() - interval '24 hours'
    );

  if v_free >= p_min_free then
    -- Plenty: a random one of them.
    select lpad(n::text, 4, '0')
    into v_code
    from generate_series(0, 9999) as n
    where not exists (
        select 1 from public.tables t
        where t.code = lpad(n::text, 4, '0') and t.status <> 'ended'
      )
      and not exists (
        select 1 from public.tables t
        where t.code = lpad(n::text, 4, '0') and t.status = 'ended'
          and t.ended_at > now() - interval '24 hours'
      )
    order by random()
    limit 1;
  else
    -- Fewer than p_min_free outside the cooldown: any free code, the least
    -- recently ended first (never used at all before any) -- a random one of
    -- the 20 least recent, so two creates at once rarely pick the same.
    select x.c
    into v_code
    from (
      select lpad(n::text, 4, '0') as c,
             (select max(t.ended_at) from public.tables t
              where t.code = lpad(n::text, 4, '0') and t.status = 'ended') as last_end
      from generate_series(0, 9999) as n
      where not exists (
        select 1 from public.tables t
        where t.code = lpad(n::text, 4, '0') and t.status <> 'ended'
      )
      order by last_end asc nulls first
      limit 20
    ) x
    order by random()
    limit 1;
  end if;

  return v_code;  -- NULL only when every code is held by an open table
end;
$$;

comment on function public._pick_table_code(integer) is
  'Internal (step 3, slice B): a free 4-digit table code. No open table holds it; while at least p_min_free (1,000) codes are outside the 24-hour reuse cooldown, none ended in the last 24 hours (tables.ended_at); below that, the least recently ended free code (never used first; random among the 20 least recent). NULL when every code is held by an open table. No client role can execute it. See docs/sql/free-codes-part2.sql.';

revoke all on function public._pick_table_code(integer) from public;
revoke all on function public._pick_table_code(integer) from anon;
revoke all on function public._pick_table_code(integer) from authenticated;
revoke all on function public._pick_table_code(integer) from service_role;


-- ---------------------------------------------------------------------------
-- 4. create_table: the pick is _pick_table_code.
-- ---------------------------------------------------------------------------
-- join-create.sql's body with only the code pick replaced.
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
    -- Slice B: a free code -- no open table holds it, and while at least
    -- 1,000 such codes exist, no table ended with it in the last 24 hours
    -- (else the least recently ended free codes): _pick_table_code.
    v_code := public._pick_table_code();

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
  'Start a Table (step 3, slices A and B): validates the options, applies one table at a time and 10 an hour, picks a free code (no open table holds it; the 24-hour reuse cooldown while at least 1,000 codes are outside it: _pick_table_code), makes the table and seats the creator. Returns (table_id, code). See docs/sql/join-create.sql and free-codes-part2.sql.';

revoke all on function public.create_table(boolean, boolean, integer, text, boolean) from public;
revoke all on function public.create_table(boolean, boolean, integer, text, boolean) from anon;
revoke all on function public.create_table(boolean, boolean, integer, text, boolean) from service_role;
grant execute on function public.create_table(boolean, boolean, integer, text, boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. create_computer_table: the server picks the code.
-- ---------------------------------------------------------------------------
-- join-create.sql's body (the live text plus J7) with only the insert
-- replaced by (B3). search_path stays "public", as live.
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
  v_pick text;
  v_try integer;
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

  -- ===== (B3) THE CODE IS THE SERVER'S (slice B, start) =====
  -- p_code is IGNORED (kept so the signature, and every app that sends it,
  -- still works): the server picks a free code with the same 24-hour reuse
  -- cooldown as create_table (_pick_table_code), so a single-player table
  -- can't take a code that just ended either. A code taken between the pick
  -- and the insert is retried, up to 5 times; the messages are
  -- create_table's. The client's 23505 retry is never reached any more.
  for v_try in 1..5 loop
    v_pick := public._pick_table_code();

    if v_pick is null then
      raise exception 'No table codes are free right now. Please try again in a few minutes.';
    end if;

    begin
      insert into public.tables (code, created_by, is_public, is_muggins, max_players, computer_level)
      values (v_pick, v_caller, false, false, 2, p_level)
      returning tables.id, tables.code into v_table_id, v_code;
      exit;
    exception when unique_violation then
      v_table_id := null;
    end;
  end loop;

  if v_table_id is null then
    raise exception 'Could not find a free table code. Please try again.';
  end if;
  -- ===== (B3) THE CODE IS THE SERVER'S (slice B, end) =====

  insert into public.table_members (table_id, user_id)
  values (v_table_id, v_caller);

  insert into public.table_members (table_id, user_id)
  values (v_table_id, v_computer);

  table_id := v_table_id;
  code := v_code;
  return next;
end;
$$;

-- Unchanged grants, restated (as live: service_role keeps its EXECUTE).
revoke all on function public.create_computer_table(text, text) from public;
revoke all on function public.create_computer_table(text, text) from anon;
grant execute on function public.create_computer_table(text, text) to authenticated;

notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  to_regclass('public.tables_code_open_key') is not null as partial_unique_index,
  not exists (select 1 from pg_constraint con where con.conrelid = 'public.tables'::regclass
              and con.conname = 'tables_code_key') as old_unique_key_gone,
  (select count(*) from generate_series(0, 9999) n
   where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0') and t.status <> 'ended')
     and not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0') and t.status = 'ended'
                       and t.ended_at > now() - interval '24 hours')) as codes_free_outside_cooldown,
  (select count(*) from generate_series(0, 9999) n
   where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0') and t.status <> 'ended')) as codes_free;
