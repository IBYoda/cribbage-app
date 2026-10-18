-- Phase 3, step E1: table size, seats and joining
-- Run this in the Supabase Dashboard -> SQL Editor, AFTER muggins-mode.sql
-- (live). Kept here for reference/history; this project has no Supabase
-- CLI/migrations set up yet.
--
-- WHAT IT DOES, in order -- and nothing else:
--   0. A pre-check: stops the whole run if any table already has more than
--      four players seated (seats are numbered 1 to 4).
--   1. tables.max_players (smallint, NOT NULL, default 2, 2 to 4) and
--      tables.team_mode (text, NOT NULL, default 'teams', 'teams' or
--      'solo'), and a check that a Muggins table is a 2-player table.
--   2. table_members.seat (smallint, 1 to 4), unique per table, backfilled
--      by join order, then NOT NULL.
--   3. assign_table_seat(): a BEFORE INSERT trigger on table_members that
--      gives every new player the lowest free seat, refuses a full table,
--      and lets a player who is already seated through untouched.
--   4. seat_team(int): the team of a seat in Teams mode (1 and 3 vs 2 and 4).
--   5. table_host(uuid) and set_seat(uuid, uuid, int): the host moves a
--      player to another seat (or swaps two) before the game starts.
--
-- WHY: Phase 3 adds 3 and 4 player games. The creator picks the table size
-- at creation; seats follow join order, and the host can rearrange them
-- before the start. This step is ONLY table size, seats and joining. Every
-- 2-player table keeps max_players = 2 (the default), so 2-player play is
-- unchanged -- with ONE deliberate difference: a third player opening a
-- full 2-player table is now refused ("This table is full.") instead of
-- being seated beside a game they can't join. Nothing refused that before
-- did not already fail to play.
--
-- NOT TOUCHED, deliberately (E2 to E4): start_game_with_deal, draw_cut_card,
-- acknowledge_deal_cut, discard_to_crib, play_card, show_hand, show_crib,
-- confirm_count, next_hand, award_points, leave_table, end_timed_out_sessions,
-- claim_win, clear_win_claim, confirm_win. They still build the player list
-- in JOIN order (joined_at); moving to SEAT order is E2's job.
--
-- POLICIES AND GRANTS: unchanged. tables: INSERT stays "auth.uid() =
-- created_by" (so a creator sets max_players and team_mode), UPDATE stays
-- admin-only (so no player can change them later). table_members: SELECT
-- for any signed-in user, INSERT only for yourself; there is still no
-- UPDATE or DELETE policy, so a player cannot change a seat directly -- only
-- through set_seat. Column-level grants: checked -- nothing in docs/sql
-- grants per column on tables or table_members (the table-visibility
-- proposal for one was never applied), and the verification file checks
-- the live catalog.
--
-- HOW A PLAYER IS SEATED TODAY (unchanged client): the table page upserts
-- { table_id, user_id } with onConflict "table_id,user_id" and
-- ignoreDuplicates, i.e. INSERT ... ON CONFLICT (table_id, user_id) DO
-- NOTHING. In Postgres the BEFORE INSERT trigger, and then the NOT NULL and
-- CHECK constraints, run BEFORE the ON CONFLICT check -- for every attempted
-- row, including one that already exists. So the trigger must recognise an
-- already-seated player first and hand back a row that passes every
-- constraint (it copies their current seat into NEW); the ON CONFLICT then
-- skips it. That is the refresh / Rejoin case, and it works at a full table.
--
-- CONCURRENCY: the trigger locks the tables row (FOR NO KEY UPDATE) before
-- counting, so joins to one table run one at a time and two players can
-- never take the same seat or overfill it. NO KEY UPDATE, not UPDATE: it
-- conflicts with itself (joins, set_seat) but not with the key-share locks
-- foreign keys take, so inserting games or plays at the table is never held
-- up. The trigger is SECURITY DEFINER because a player cannot lock a tables
-- row themselves (the admin-only UPDATE policy hides it from FOR UPDATE).
--
-- THE UNIQUE SEAT is DEFERRABLE INITIALLY IMMEDIATE: checked at the end of
-- each statement instead of per row, so set_seat swaps two players in ONE
-- UPDATE. It is never an ON CONFLICT arbiter (deferrable constraints can't
-- be): the client names (table_id, user_id), which is the primary key.
--
-- REALTIME: table_members is in the supabase_realtime publication
-- (slice-4-join-table.sql) with the default replica identity (the primary
-- key). A set_seat move arrives as an UPDATE whose new row carries the seat;
-- today's client merges only the score fields from such an UPDATE, so a
-- move shows after its next read. Nothing calls set_seat until the app
-- stages.
--
-- GRANTS AFTER THIS FILE: fourteen client-callable functions -- the
-- thirteen before plus set_seat. seat_team, table_host and the trigger
-- function are not client-callable.
--
-- RE-RUNNABLE: "add column if not exists", constraints dropped and re-added,
-- "create or replace", "drop trigger if exists". The backfill only fills
-- empty seats. Running it twice changes nothing.
--
-- The SQL Editor runs the whole file as one transaction: if any statement
-- fails (the pre-check included), nothing is applied.
--
-- ROLLBACK, in THIS order:
--   1. drop function if exists public.set_seat(uuid, uuid, int);
--      drop function if exists public.table_host(uuid);
--      drop function if exists public.seat_team(int);
--   2. drop trigger if exists table_members_assign_seat on public.table_members;
--      drop function if exists public.assign_table_seat();
--   3. alter table public.table_members
--        drop constraint if exists table_members_table_id_seat_key,
--        drop constraint if exists table_members_seat_check,
--        drop column if exists seat;
--   4. alter table public.tables
--        drop constraint if exists tables_muggins_two_players,
--        drop constraint if exists tables_team_mode_check,
--        drop constraint if exists tables_max_players_check,
--        drop column if exists team_mode,
--        drop column if exists max_players;
--
-- Checks: docs/sql/phase3-e1-seating-verification.sql -- one rolled-back
-- walk-through as real players.


-- ---------------------------------------------------------------------------
-- 0. PRE-CHECK. Seats are 1 to 4, so a table with more than four players
-- seated can't be numbered. Nothing has ever limited the number of players
-- at a table, so look before numbering. If this stops the run, the message
-- names the tables; end them or remove the extra players, then run again.
-- (Tables with 3 or 4 players at a 2-player table are fine: they keep seats
-- 3 and 4, and the table counts as full.)
-- ---------------------------------------------------------------------------
do $$
declare
  v_over text;
begin
  select string_agg(t.code || ' (' || n.players || ' players)', ', ')
  into v_over
  from (
    select tm.table_id, count(*) as players
    from public.table_members tm
    group by tm.table_id
    having count(*) > 4
  ) n
  join public.tables t on t.id = n.table_id;

  if v_over is not null then
    raise exception 'Phase 3 E1 not applied: these tables have more than 4 players seated: %.', v_over;
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 1. tables.max_players and tables.team_mode.
-- ---------------------------------------------------------------------------
alter table public.tables
  add column if not exists max_players smallint not null default 2,
  add column if not exists team_mode text not null default 'teams';

alter table public.tables drop constraint if exists tables_max_players_check;
alter table public.tables
  add constraint tables_max_players_check check (max_players between 2 and 4);

alter table public.tables drop constraint if exists tables_team_mode_check;
alter table public.tables
  add constraint tables_team_mode_check check (team_mode in ('teams', 'solo'));

-- Muggins is 2-player only.
alter table public.tables drop constraint if exists tables_muggins_two_players;
alter table public.tables
  add constraint tables_muggins_two_players check (not is_muggins or max_players = 2);

comment on column public.tables.max_players is
  'Table size, chosen at creation: 2, 3 or 4 players. Never changed by players. Joining stops at this many (assign_table_seat). A Muggins table is always 2.';

comment on column public.tables.team_mode is
  'For a 4-player table: teams (seats 1 and 3 against 2 and 4, partners opposite; see seat_team) or solo (everyone for themselves; not offered yet). Ignored for 2 and 3 players.';


-- ---------------------------------------------------------------------------
-- 2. table_members.seat.
-- ---------------------------------------------------------------------------
alter table public.table_members
  add column if not exists seat smallint;

-- BACKFILL: every player already seated gets a seat by join order, per
-- table (1, 2, ...). Ties on joined_at fall back to user_id, so the result
-- is always the same. Only empty seats are filled, so a re-run does nothing.
update public.table_members tm
set seat = s.seat
from (
  select table_id,
         user_id,
         row_number() over (partition by table_id order by joined_at, user_id) as seat
  from public.table_members
) s
where tm.table_id = s.table_id
  and tm.user_id = s.user_id
  and tm.seat is null;

alter table public.table_members drop constraint if exists table_members_seat_check;
alter table public.table_members
  add constraint table_members_seat_check check (seat between 1 and 4);

-- One player per seat per table. Deferrable, so set_seat can swap two
-- players in one statement (see the header).
alter table public.table_members drop constraint if exists table_members_table_id_seat_key;
alter table public.table_members
  add constraint table_members_table_id_seat_key unique (table_id, seat)
  deferrable initially immediate;

-- NOT NULL is safe now: every existing row was just numbered, and every new
-- row gets its seat from the trigger below before the constraint is checked.
alter table public.table_members
  alter column seat set not null;

comment on column public.table_members.seat is
  'Seat 1 to 4 at the table, unique per table. Given by assign_table_seat on joining (the lowest free seat; anything the client sends is ignored), changed only by the host through set_seat before the game starts. Seats go clockwise; in Teams mode seats 1 and 3 are partners against 2 and 4 (seat_team).';


-- ---------------------------------------------------------------------------
-- 3. assign_table_seat() -- the BEFORE INSERT trigger.
--
-- Order:
--   a. Already seated at this table: copy their seat into NEW and let it
--      through. The ON CONFLICT (table_id, user_id) DO NOTHING then skips
--      the row. Checked first and without the lock, so a refresh or Rejoin
--      at a FULL table never waits and never fails.
--   b. THE ROW LOCK on the tables row: joins to one table serialize here.
--   c. Already seated, checked again under the lock: a second tab of the
--      same player may have seated them while this one waited.
--   d. Full: "This table is full." when the players seated already reach
--      max_players (>=, so a table that was over-full before this file also
--      counts as full).
--   e. Otherwise: the lowest free seat from 1 to max_players, whatever seat
--      the client sent.
-- A table id that doesn't exist gets seat 1, so the foreign key refuses it
-- exactly as before (23503) rather than NOT NULL.
-- ---------------------------------------------------------------------------
create or replace function public.assign_table_seat()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seat smallint;
  v_max smallint;
  v_seated int;
begin
  -- a. Already seated: keep the seat.
  select tm.seat
  into v_seat
  from public.table_members tm
  where tm.table_id = new.table_id
    and tm.user_id = new.user_id;

  if found then
    new.seat := v_seat;
    return new;
  end if;

  -- b. THE ROW LOCK.
  select t.max_players
  into v_max
  from public.tables t
  where t.id = new.table_id
  for no key update;

  if not found then
    new.seat := 1;
    return new;
  end if;

  -- c. Already seated, now that the lock is held.
  select tm.seat
  into v_seat
  from public.table_members tm
  where tm.table_id = new.table_id
    and tm.user_id = new.user_id;

  if found then
    new.seat := v_seat;
    return new;
  end if;

  -- d. Full.
  select count(*)
  into v_seated
  from public.table_members tm
  where tm.table_id = new.table_id;

  if v_seated >= v_max then
    raise exception 'This table is full.';
  end if;

  -- e. The lowest free seat.
  select min(s)::smallint
  into v_seat
  from generate_series(1, v_max) as s
  where not exists (
    select 1
    from public.table_members tm
    where tm.table_id = new.table_id
      and tm.seat = s
  );

  if v_seat is null then
    -- Defensive: only reachable if seats above max_players are taken (a
    -- table that was over-full before this file).
    raise exception 'This table is full.';
  end if;

  new.seat := v_seat;
  return new;
end;
$$;

revoke all on function public.assign_table_seat() from public;
revoke all on function public.assign_table_seat() from anon;
revoke all on function public.assign_table_seat() from authenticated;

drop trigger if exists table_members_assign_seat on public.table_members;
create trigger table_members_assign_seat
  before insert on public.table_members
  for each row
  execute function public.assign_table_seat();


-- ---------------------------------------------------------------------------
-- 4. seat_team(seat) -- Teams mode (4 players): seats 1 and 3 are one team,
-- 2 and 4 the other, so partners sit opposite each other. Null for any
-- other number. Not client-callable (the app can compute it); for E2 to E4.
-- ---------------------------------------------------------------------------
create or replace function public.seat_team(p_seat int)
returns int
language sql
immutable
set search_path = public
as $$
  select case
    when p_seat in (1, 3) then 1
    when p_seat in (2, 4) then 2
  end;
$$;

revoke all on function public.seat_team(int) from public;
revoke all on function public.seat_team(int) from anon;
revoke all on function public.seat_team(int) from authenticated;


-- ---------------------------------------------------------------------------
-- 5a. table_host(table) -- who may arrange the seats: the creator while they
-- are seated, otherwise the player in the lowest seat. Null for a table
-- nobody is seated at. Not client-callable (the app has created_by and the
-- seats already); used by set_seat.
-- ---------------------------------------------------------------------------
create or replace function public.table_host(p_table_id uuid)
returns uuid
language sql
stable
set search_path = public
as $$
  select coalesce(
    (
      select t.created_by
      from public.tables t
      where t.id = p_table_id
        and exists (
          select 1
          from public.table_members tm
          where tm.table_id = t.id
            and tm.user_id = t.created_by
        )
    ),
    (
      select tm.user_id
      from public.table_members tm
      where tm.table_id = p_table_id
      order by tm.seat
      limit 1
    )
  );
$$;

revoke all on function public.table_host(uuid) from public;
revoke all on function public.table_host(uuid) from anon;
revoke all on function public.table_host(uuid) from authenticated;


-- ---------------------------------------------------------------------------
-- 5b. set_seat(table, player, seat) -- the host moves a player before the
-- game starts.
--
--   * The seat is empty: the player moves there.
--   * Another player holds it: the two swap, in ONE UPDATE (the deferrable
--     unique seat is checked at the end of the statement).
--   * The player is already in that seat: quiet, nothing changes.
--
-- Order of checks: logged in -> ROW LOCK on the tables row (the same lock
-- joins take, so nobody can take the target seat mid-move) -> table exists
-- -> table open -> caller is the host -> no live game ('cutting' or
-- 'active') -> seat between 1 and max_players -> the player is seated
-- here. Everything else is refused with a message.
-- ---------------------------------------------------------------------------
create or replace function public.set_seat(p_table_id uuid, p_user_id uuid, p_seat int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_table record;
  v_from smallint;
  v_holder uuid;
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to move a player.';
  end if;

  -- THE ROW LOCK.
  select t.id, t.status, t.max_players
  into v_table
  from public.tables t
  where t.id = p_table_id
  for no key update;

  if not found then
    raise exception 'Table not found.';
  end if;

  -- Guard 2: an open table.
  if v_table.status <> 'open' then
    raise exception 'This table has ended.';
  end if;

  -- Guard 3: only the host.
  if public.table_host(p_table_id) is distinct from v_caller then
    raise exception 'Only the host can move players between seats.';
  end if;

  -- Guard 4: before the game starts.
  if exists (
    select 1
    from public.games g
    where g.table_id = p_table_id
      and g.status in ('cutting', 'active')
  ) then
    raise exception 'Seats can only change before the game starts.';
  end if;

  -- Guard 5: a seat that exists at this table.
  if p_seat is null or p_seat < 1 or p_seat > v_table.max_players then
    raise exception 'There is no seat % at this table (seats 1 to %).', p_seat, v_table.max_players;
  end if;

  -- Guard 6: the player is seated here.
  select tm.seat
  into v_from
  from public.table_members tm
  where tm.table_id = p_table_id
    and tm.user_id = p_user_id;

  if not found then
    raise exception 'That player is not seated at this table.';
  end if;

  -- Already there: quiet.
  if v_from = p_seat then
    return;
  end if;

  select tm.user_id
  into v_holder
  from public.table_members tm
  where tm.table_id = p_table_id
    and tm.seat = p_seat;

  if v_holder is null then
    update public.table_members
    set seat = p_seat
    where table_id = p_table_id
      and user_id = p_user_id;
  else
    update public.table_members
    set seat = case when user_id = p_user_id then p_seat else v_from end
    where table_id = p_table_id
      and user_id in (p_user_id, v_holder);
  end if;
end;
$$;

revoke all on function public.set_seat(uuid, uuid, int) from public;
revoke all on function public.set_seat(uuid, uuid, int) from anon;
revoke all on function public.set_seat(uuid, uuid, int) from authenticated;
grant execute on function public.set_seat(uuid, uuid, int) to authenticated;
