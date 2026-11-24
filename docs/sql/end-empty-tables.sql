-- Step 3, slice C: END EMPTY TABLES.
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- RUN ORDER:
--   0. The app build with the 'empty' message (tableEndedMessage,
--      lib/oneTable.ts: "Everyone left, so this table has closed.") is live
--      FIRST. Before it, a table ended as 'empty' falls through to "This table
--      has been ended by an admin." on a player's screen (the same account's
--      second tab, a reloaded old URL, the stale-tab check).
--   1. docs/sql/end-empty-tables-precheck.sql       (read-only; one result)
--   2. docs/sql/end-empty-tables.sql                (this file)
--   3. docs/sql/end-empty-tables-verification.sql   (rolled back; its final
--                                                    message is the verdict)
--   4. docs/sql/end-empty-tables-manual-race-test.md (the two races, by hand,
--                                                    in two SQL Editor tabs)
--   If it has to come out: docs/sql/end-empty-tables-rollback.sql.
--
-- WHAT WALT DECIDED (step 3, slice C):
--   * When the LAST seated person leaves a human table, the table ends at
--     once (ended_reason 'empty'). "Seated person" = a table_members row
--     whose user is NOT a computer account: a table with only computer seats
--     left is empty.
--   * A pg_cron sweep, every 5 minutes, ends any open table with no human
--     seat once it is more than 10 minutes old (tables.created_at): the
--     safety net for anything that slips past the trigger.
--   * Abandoned tables WITH people seated keep the 12-hour timeout
--     (end_timed_out_sessions, unchanged). No presence heartbeat.
--   * Spectators keep their rows; their heartbeat answers table_ended and the
--     watch page shows "This table has closed." (unchanged).
--   * leave_table, end_timed_out_sessions, assign_table_seat and table_host
--     are NOT changed (byte for byte; the precheck and the verification check
--     their md5s). Everything new sits BESIDE them, as two triggers on
--     table_members and one new function.
--
-- WHAT THIS FILE DOES (one transaction):
--   1. tables_ended_reason_check also allows 'empty'.
--   2. "END WHEN EMPTY": an AFTER DELETE row trigger on table_members
--      (table_members_end_when_empty -> public.end_table_when_empty()).
--      After a seat is deleted, on a HUMAN table (computer_level null): lock
--      the tables row, count the remaining non-computer seats, and if none
--      and the table is open: end any live game as 'player_left', then the
--      table as 'empty'. Spectator rows are kept.
--   3. "TABLE MUST BE OPEN": a BEFORE INSERT row trigger on table_members
--      (table_members_require_open -> public.require_open_table()). Its name
--      sorts after table_members_assign_seat, so it runs after the seat
--      trigger took the tables row lock; it locks the row too (a no-op when
--      the seat trigger already holds it) and raises "This table has ended."
--      when the table is not open. Covers every insert: create_table,
--      join_table_by_code, create_computer_table, an owner's insert.
--   4. public.end_empty_tables(): the sweep (security definer, empty
--      search_path, EXECUTE for nobody). Returns how many tables it ended.
--   5. The pg_cron job 'end-empty-tables' ('*/5 * * * *'), scheduled
--      idempotently; skipped (with a NOTICE) where pg_cron isn't installed.
--   6. THE ONE-TIME CLEANUP of the legacy empty open tables: the sweep, run
--      once now (the precheck showed the count).
--
-- COMPUTER TABLES (computer_level set): the "end when empty" trigger IGNORES
-- them, and the sweep handles them. Why:
--   * The two normal ways a computer table closes already end it, with
--     ended_reason NULL and the app's "This single-player game has ended.":
--     leave_computer_table (computer-c2-engine.sql) and the one-table rule's
--     quiet close (_one_table_rule, join-create.sql) -- both lock the table,
--     end its game, delete BOTH seats, then set status 'ended'. If the
--     trigger acted on those deletes it would end the table first, as
--     'empty', inside their own statement, and the later
--     "update ... where status = 'open'" would find nothing: the reason, and
--     so the message, would change. Ignoring computer tables leaves both
--     paths exactly as they are (the verification checks reason NULL).
--   * It also keeps the trigger from taking a second lock inside those two
--     paths (they already hold the tables row; a trigger that returns before
--     locking adds nothing).
--   * The odd path -- a plain leave_table on a computer table (only a
--     modified client sends it; the app uses leave_computer_table) -- removes
--     the human seat and leaves the computer's: the trigger ignores it, and
--     the sweep ends the table (no human seat, older than 10 minutes) as
--     'empty' within 5 minutes of the grace passing. Its game was already
--     ended by leave_table itself ('player_left').
--
-- LOCK ORDER (the row locks each path takes on games and tables):
--   * leave_table (unchanged): UPDATEs the live game (row lock on that games
--     row), DELETEs the seat; the trigger then locks the tables row. So:
--     GAMES THEN TABLES.
--   * start_game_with_deal_as, set_seat, leave_computer_table, the quiet
--     close, the sweep: TABLES THEN GAMES (the tables row first).
--   Opposite orders can deadlock only if a transaction holding the tables
--   row waits on the very games row a leave holds. Checked:
--   * start_game_with_deal_as locks the tables row, then only READS the live
--     game (no lock) -- a live game means it returns early -- and locks only
--     an ENDED won game (the rematch's ready gate). leave_table never locks
--     an ended game. No cycle.
--   * set_seat and the seat trigger never touch games. No cycle.
--   * leave_computer_table and the quiet close: computer tables only, which
--     the trigger leaves before locking anything. No cycle.
--   * The sweep: it locks a table, then re-counts human seats in a fresh
--     read; a leave in flight still has its own seat visible to that read
--     (uncommitted delete), so the sweep skips the table and never waits on
--     the leave's game row. No cycle.
--   * The game functions (play_card_as and the rest) lock the live game and
--     never the tables row. No cycle.
--   * end_timed_out_sessions (unchanged) updates games, then tables (older
--     than 12 hours), then games again. A leave at the same instant on a
--     table older than 12 hours could wait on that sweep's tables lock while
--     the sweep's third statement waits on the leave's game row: Postgres
--     detects the deadlock and aborts one of them (the leave's error is
--     shown; Leave can be tapped again; or the next 15-minute run ends it).
--     Accepted: rare (a 12-hour-old table, the same second), self-healing,
--     and avoiding it would mean changing leave_table or
--     end_timed_out_sessions, which this slice does not do.
--   The races these locks settle are tested by hand
--   (end-empty-tables-manual-race-test.md):
--   * two players leaving at once: both triggers lock the tables row; the
--     second waits, then counts in a FRESH read (each statement in a
--     volatile plpgsql function takes a new snapshot under READ COMMITTED),
--     sees the first one's committed delete, finds no one, and ends the
--     table. Without the lock both could count one seat left and neither
--     would end it (the sweep would, later).
--   * a join racing the last leave: join_table_by_code reads the table open,
--     then its insert's seat trigger waits on the tables row lock the leave's
--     trigger holds; once the leave commits (table ended), the seat trigger
--     goes on (it never checks status), and table_members_require_open,
--     reading the row afresh, refuses: "This table has ended." No one is
--     ever seated at an ended table.
--
-- NOT TOUCHED: leave_table, end_timed_out_sessions, assign_table_seat,
-- table_host (fingerprinted; checked unchanged), the 8 game functions and
-- their _as bodies, leave_computer_table, every slice A function, every
-- policy and grant, the Realtime publication, games_ended_reason_check (the
-- triggers write 'player_left', already allowed). No function name here
-- contains "chat". No new table (so AGENTS.md's "New tables" rule doesn't
-- apply).
--
-- RE-RUNNABLE: the constraint is dropped and re-added, functions are
-- "create or replace", triggers are dropped if they exist and re-created, the
-- job is scheduled by name (pg_cron replaces a job with the same name), the
-- cleanup only ends what is still empty.

begin;

-- ---------------------------------------------------------------------------
-- 1. 'empty' is a reason a table can end with.
-- ---------------------------------------------------------------------------
alter table public.tables
  drop constraint if exists tables_ended_reason_check;

alter table public.tables
  add constraint tables_ended_reason_check
  check (ended_reason is null or ended_reason in ('admin', 'timeout', 'empty'));


-- ---------------------------------------------------------------------------
-- 2. END WHEN EMPTY: after a seat is deleted.
-- ---------------------------------------------------------------------------
-- Security definer (as the owner): a seat can be deleted by a cascade run by
-- a role with no rights on tables or games -- an account deleted through
-- Supabase Auth runs as supabase_auth_admin -- and the trigger must still
-- end the table. Empty search_path, every name qualified.
create or replace function public.end_table_when_empty()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_level text;
  v_status text;
begin
  -- Computer tables: never here (see the header: leave_computer_table and the
  -- quiet close end them with reason NULL; the sweep takes the odd path).
  -- Read without a lock first: computer_level never changes, and a computer
  -- table must not be locked a second time inside those two paths.
  select t.computer_level
  into v_level
  from public.tables t
  where t.id = old.table_id;

  if not found or v_level is not null then
    return null;  -- the table is gone (a cascade from tables), or a computer table
  end if;

  -- THE LOCK: the tables row, the one the seat trigger, set_seat and
  -- start_game_with_deal take. Two leaves at once are taken one at a time,
  -- and a join waits here too.
  select t.status
  into v_status
  from public.tables t
  where t.id = old.table_id
  for no key update;

  if not found or v_status is distinct from 'open' then
    return null;  -- already ended (an admin, the timeout, the sweep, another leave)
  end if;

  -- Anyone left who is not a computer? A fresh read, now that the lock is
  -- held: it sees every committed delete and insert at this table.
  if exists (
    select 1
    from public.table_members tm
    where tm.table_id = old.table_id
      and not exists (
        select 1
        from public.computer_accounts ca
        where ca.user_id = tm.user_id
      )
  ) then
    return null;
  end if;

  -- Nobody: the live game, if any (leave_table normally ended it already:
  -- any leave ends the game), then the table. Spectator rows are KEPT, so a
  -- spectator's heartbeat answers table_ended and the watch page shows "This
  -- table has closed." (Deleting them would make it answer not_watching.)
  update public.games
  set status = 'ended', ended_reason = 'player_left'
  where table_id = old.table_id
    and status in ('cutting', 'active');

  update public.tables
  set status = 'ended', ended_reason = 'empty'
  where id = old.table_id
    and status = 'open';

  return null;  -- AFTER trigger: the value is ignored
end;
$$;

comment on function public.end_table_when_empty() is
  'Step 3, slice C: AFTER DELETE trigger on table_members. On a human table (computer_level null), when no non-computer seat is left and the table is open: ends any live game as player_left and the table as empty (tables row locked first). Spectator rows are kept. See docs/sql/end-empty-tables.sql.';

revoke all on function public.end_table_when_empty() from public;
revoke all on function public.end_table_when_empty() from anon;
revoke all on function public.end_table_when_empty() from authenticated;
revoke all on function public.end_table_when_empty() from service_role;

drop trigger if exists table_members_end_when_empty on public.table_members;

create trigger table_members_end_when_empty
  after delete on public.table_members
  for each row
  execute function public.end_table_when_empty();


-- ---------------------------------------------------------------------------
-- 3. TABLE MUST BE OPEN: before a seat is inserted.
-- ---------------------------------------------------------------------------
-- BEFORE row triggers fire in name order: table_members_assign_seat ('a')
-- first -- it takes the tables row lock, unless the person is already seated
-- there -- then table_members_require_open ('r'). This one locks the row
-- too: free when the seat trigger already holds it, and it keeps the check
-- under the lock in the "already seated" case as well. Then the status, read
-- afresh: a table that ended while this insert waited for the lock is
-- refused. A table that doesn't exist is left to the foreign key.
create or replace function public.require_open_table()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
begin
  select t.status
  into v_status
  from public.tables t
  where t.id = new.table_id
  for no key update;

  if found and v_status is distinct from 'open' then
    raise exception 'This table has ended.';
  end if;

  return new;
end;
$$;

comment on function public.require_open_table() is
  'Step 3, slice C: BEFORE INSERT trigger on table_members, after table_members_assign_seat (name order). Refuses a seat at a table that is not open ("This table has ended."), under the tables row lock. See docs/sql/end-empty-tables.sql.';

revoke all on function public.require_open_table() from public;
revoke all on function public.require_open_table() from anon;
revoke all on function public.require_open_table() from authenticated;
revoke all on function public.require_open_table() from service_role;

drop trigger if exists table_members_require_open on public.table_members;

create trigger table_members_require_open
  before insert on public.table_members
  for each row
  execute function public.require_open_table();


-- ---------------------------------------------------------------------------
-- 4. THE SWEEP: end_empty_tables().
-- ---------------------------------------------------------------------------
-- An open table with no non-computer seat, created more than 10 minutes ago
-- (a new table is never empty: create_table and create_computer_table seat
-- their creator in the same transaction, so created_at is a safe grace):
-- its live game ends as player_left, the table as 'empty'; spectator rows
-- are kept. Human and computer tables alike (the computer table with no
-- human seat -- the odd plain-leave path -- ends here, at the latest).
--
-- One table at a time: lock it, then re-check in a FRESH read (the loop's
-- own query used an older snapshot). A seat inserted since -- a join that
-- committed while this waited on the lock -- keeps the table open. TABLES
-- THEN GAMES, like start_game_with_deal_as.
create or replace function public.end_empty_tables()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_ended integer := 0;
begin
  for v_id in
    select t.id
    from public.tables t
    where t.status = 'open'
      and t.created_at < now() - interval '10 minutes'
      and not exists (
        select 1
        from public.table_members tm
        where tm.table_id = t.id
          and not exists (
            select 1
            from public.computer_accounts ca
            where ca.user_id = tm.user_id
          )
      )
    order by t.created_at
  loop
    perform 1
    from public.tables t
    where t.id = v_id
      and t.status = 'open'
    for no key update;

    if not found then
      continue;  -- ended meanwhile
    end if;

    if exists (
      select 1
      from public.table_members tm
      where tm.table_id = v_id
        and not exists (
          select 1
          from public.computer_accounts ca
          where ca.user_id = tm.user_id
        )
    ) then
      continue;  -- someone sat down meanwhile
    end if;

    update public.games
    set status = 'ended', ended_reason = 'player_left'
    where table_id = v_id
      and status in ('cutting', 'active');

    update public.tables
    set status = 'ended', ended_reason = 'empty'
    where id = v_id
      and status = 'open';

    v_ended := v_ended + 1;
  end loop;

  return v_ended;
end;
$$;

comment on function public.end_empty_tables() is
  'Step 3, slice C: the empty-table sweep (pg_cron job end-empty-tables, every 5 minutes). Ends every open table with no non-computer seat created more than 10 minutes ago: its live game as player_left, the table as empty; spectator rows kept. Returns how many it ended. No client role can execute it. See docs/sql/end-empty-tables.sql.';

revoke all on function public.end_empty_tables() from public;
revoke all on function public.end_empty_tables() from anon;
revoke all on function public.end_empty_tables() from authenticated;
revoke all on function public.end_empty_tables() from service_role;


-- ---------------------------------------------------------------------------
-- 5. The pg_cron job, every 5 minutes.
-- ---------------------------------------------------------------------------
-- Through EXECUTE, so this file still parses where the cron schema doesn't
-- exist; there it is skipped with a NOTICE (the precheck says STOP first).
-- cron.schedule(name, ...) replaces a job with the same name, so a re-run
-- leaves one job. The job runs as the role that schedules it (the dashboard's
-- postgres), which owns end_empty_tables.
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed: the end-empty-tables job was NOT scheduled.';
    return;
  end if;
  execute $cron$select cron.schedule('end-empty-tables', '*/5 * * * *', 'select public.end_empty_tables();')$cron$;
end;
$$;


-- ---------------------------------------------------------------------------
-- 6. THE ONE-TIME CLEANUP of the legacy empty open tables.
-- ---------------------------------------------------------------------------
-- Exactly the sweep, run once now: the same rule (no non-computer seat,
-- created more than 10 minutes ago), the same locking and the same results
-- (live games player_left, tables 'empty', spectator rows kept). The
-- precheck's "legacy" rows showed the count; anything younger than 10
-- minutes is left to the job's next runs.
select public.end_empty_tables() as legacy_empty_tables_ended;

commit;

-- After the commit, read-only: what the dashboard shows as this file's
-- result (it shows only the last statement's). Expected: 0 open tables with
-- no human seat older than 10 minutes, 'empty' allowed, both triggers, the job.
select
  (select count(*)
   from public.tables t
   where t.status = 'open'
     and t.created_at < now() - interval '10 minutes'
     and not exists (select 1 from public.table_members tm where tm.table_id = t.id
                       and not exists (select 1 from public.computer_accounts ca where ca.user_id = tm.user_id))
  ) as empty_open_tables_older_than_10_min,
  (select count(*) from public.tables t where t.ended_reason = 'empty') as tables_ended_empty,
  (select string_agg(tg.tgname::text, ', ' order by tg.tgname) from pg_trigger tg
   where tg.tgrelid = 'public.table_members'::regclass and not tg.tgisinternal) as table_members_triggers,
  (select pg_get_constraintdef(con.oid) from pg_constraint con
   where con.conrelid = 'public.tables'::regclass and con.conname = 'tables_ended_reason_check') as ended_reason_check,
  case when to_regclass('cron.job') is null then 'pg_cron not installed'
       else query_to_xml('select jobname, schedule from cron.job where jobname = ''end-empty-tables''', false, false, '')::text
  end as cron_job;
