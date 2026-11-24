-- Step 3, slice B, PART 1: id-carrying lookups, ended_at, the watch filter.
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- SLICE B, IN THREE STEPS (each safe against the state before it):
--   1. docs/sql/free-codes-precheck.sql, then THIS FILE (part 1). Codes are
--      still unique forever (tables_code_key stays), so nothing here can
--      make a code point at a new table. Every change is backward
--      compatible with the app that is live while it runs (slice A/C build):
--        * join_table_by_code and watch_table gain a LAST parameter,
--          p_table_id uuid DEFAULT NULL. The old signatures are DROPPED and
--          the new ones created in this same transaction, so there is never
--          an ambiguous overload, and a call without p_table_id (the live
--          app: rpc("join_table_by_code", { p_code }), rpc("watch_table",
--          { p_code })) resolves to the new function with the same meaning.
--        * join_table_by_code's result gains ONE column at the END
--          (host_avatar_url): supabase-js hands back objects, so the live
--          app, which reads outcome and the other columns by name, is
--          unaffected.
--        * watch_table only matches NON-ENDED tables. The live app sees an
--          ended table's code as "No table found with code NNNN." instead
--          of "This table has ended." (its watch page already treats no row
--          as not found): a wording change for the hours between this file
--          and the app deploy, nothing worse.
--        * the already_at_table HINT becomes "<code> <table id>". The live
--          app reads a HINT that isn't 4 digits by taking the code from the
--          message (lib/oneTable.ts rpcRefusal), so its "Go to table NNNN"
--          still works.
--        * tables.ended_at (new, nullable) and its trigger: nothing reads
--          it yet.
--      Then docs/sql/free-codes-verification.sql (part 2 skipped).
--   2. THE APP (holds table ids: ?t= links, preview + confirm screens,
--      p_table_id on every join/rewatch). It needs part 1 (p_table_id).
--   3. docs/sql/free-codes-part2.sql: the unique key becomes a partial
--      unique index (codes can be reused), and create_table /
--      create_computer_table pick codes with the 24-hour cooldown. LAST and
--      one-way once any code has been reused. It needs the app of step 2:
--      until every live client holds ids, a reused code could be resolved
--      to the wrong table by an old tab. Then the verification again (part 2
--      checks run).
--
-- WHAT THIS FILE DOES (one transaction):
--   1. tables.ended_at timestamptz (nullable): WHEN a table ended, for part
--      2's 24-hour reuse cooldown. Set by a BEFORE INSERT OR UPDATE row
--      trigger on tables (tables_set_ended_at -> set_table_ended_at()) the
--      moment status becomes 'ended' -- so EVERY way a table ends is covered
--      (leave_computer_table, the quiet close, slice C's last-leave trigger
--      and sweep, end_timed_out_sessions, the admin's Force-End, an owner's
--      update) without touching any of those functions (four of them are
--      fingerprinted). An explicit value is kept (the backfill below, and
--      the verification aging a row); an already-ended row keeps its stamp;
--      a row that is not ended has NULL.
--      BACKFILL: every table already ended gets ended_at = now() (the moment
--      this runs). Nothing recorded when they really ended, and an estimate
--      (the last game, created_at + 12 h for timeouts) could put a code that
--      ended an hour ago outside the cooldown. now() is the conservative
--      choice: every old code waits 24 hours from today before part 2 may
--      reuse it, and the 1,000-code fallback keeps create_table working if
--      the pool of never-used codes is small meanwhile (the precheck shows
--      it). An index on ended_at (ended tables only) serves the cooldown.
--   2. _one_table_rule: the already_at_table HINT carries the table id too
--      ("<code> <id>"); nothing else changes (the slice A body, with that).
--   3. join_table_by_code(p_code, p_preview DEFAULT false, p_table_id DEFAULT
--      NULL): with p_table_id, only that table; a mismatch answers
--      not_found and is NOT counted as a wrong guess. host_avatar_url added.
--      The preview (p_preview) is what both confirm screens use -- the join
--      confirm and the watch confirm: it seats nobody, ends nothing (not a
--      single-player game, not watching), is not counted toward the 30
--      joins an hour, and counts wrong codes.
--   4. watch_table(p_code, p_table_id DEFAULT NULL): only non-ended tables;
--      an ended or unknown code returns NO row and counts as a wrong guess
--      (Walt: it is just "no such table"); with p_table_id, a mismatch (the
--      spectator's own table ended) returns no row and is NOT counted.
--   The grants are restated exactly (authenticated only for the two RPCs;
--   nobody for the helpers).
--
-- NOT TOUCHED: create_table and create_computer_table (part 2), the
-- unique key (part 2), leave_table, end_timed_out_sessions,
-- assign_table_seat, table_host (fingerprinted: end-empty-tables-precheck
-- and -verification check them), the 8 game functions and _as bodies,
-- slice C's triggers and sweep, every policy and table grant. No new table.
-- No function name contains "chat".
--
-- RE-RUNNABLE: "add column if not exists", "create or replace", triggers and
-- indexes "if not exists"/dropped first, the old signatures dropped "if
-- exists", the backfill only fills NULLs.
--
-- UNDO: docs/sql/free-codes-part1-rollback.sql (after the app is back on its
-- slice A/C build, and only if part 2 is not in place).

begin;

-- ---------------------------------------------------------------------------
-- 1. tables.ended_at, its trigger, the backfill, the index.
-- ---------------------------------------------------------------------------
alter table public.tables
  add column if not exists ended_at timestamptz;

comment on column public.tables.ended_at is
  'When the table ended (status became ''ended''): set by the tables_set_ended_at trigger, NULL while open. Tables already ended before step 3 slice B carry the time slice B part 1 ran. Read by the 24-hour code-reuse cooldown (_pick_table_code). See docs/sql/free-codes-part1.sql.';

create or replace function public.set_table_ended_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'ended' then
    -- Stamped when the table BECOMES ended (an explicit value is kept: the
    -- backfill and the verification set one); an update of an already-ended
    -- row keeps whatever it has.
    if tg_op = 'INSERT' or old.status is distinct from 'ended' then
      new.ended_at := coalesce(new.ended_at, now());
    end if;
  else
    new.ended_at := null;  -- open (never re-opened by the app, but kept honest)
  end if;
  return new;
end;
$$;

comment on function public.set_table_ended_at() is
  'Step 3, slice B: BEFORE INSERT OR UPDATE trigger on tables. Stamps ended_at when a table becomes ended (keeps an explicit value), keeps it on later updates, NULL while open. See docs/sql/free-codes-part1.sql.';

revoke all on function public.set_table_ended_at() from public;
revoke all on function public.set_table_ended_at() from anon;
revoke all on function public.set_table_ended_at() from authenticated;
revoke all on function public.set_table_ended_at() from service_role;

drop trigger if exists tables_set_ended_at on public.tables;

create trigger tables_set_ended_at
  before insert or update on public.tables
  for each row
  execute function public.set_table_ended_at();

-- The backfill: every table already ended, as of now (see the header). The
-- trigger keeps this explicit value (the rows are already ended).
update public.tables
set ended_at = now()
where status = 'ended'
  and ended_at is null;

create index if not exists tables_ended_at_idx
  on public.tables (ended_at)
  where status = 'ended';


-- ---------------------------------------------------------------------------
-- 2. _one_table_rule: the already_at_table HINT carries the table id.
-- ---------------------------------------------------------------------------
-- join-create.sql's body (the live text; the precheck checked its md5) with
-- the refusal's select also reading t.id, and the HINT "<code> <id>".
create or replace function public._one_table_rule(p_actor uuid, p_target uuid, p_act boolean)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_code text;
  v_id uuid;
  v_solo uuid;
begin
  if p_actor is null then
    raise exception '_one_table_rule: no person given.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('one_table:' || p_actor::text, 0));

  -- 2. Single-player tables never block: end them (real actions only).
  if p_act then
    for v_solo in
      select t.id
      from public.table_members tm
      join public.tables t on t.id = tm.table_id
      where tm.user_id = p_actor
        and t.status <> 'ended'
        and t.computer_level is not null
        and t.created_by = p_actor
        and (p_target is null or t.id <> p_target)
        and not exists (
          select 1
          from public.table_members o
          where o.table_id = t.id
            and o.user_id <> p_actor
            and not exists (
              select 1
              from public.computer_accounts ca
              where ca.user_id = o.user_id
            )
        )
      order by t.id
    loop
      -- leave_computer_table's lock, then its three statements.
      perform 1
      from public.tables t
      where t.id = v_solo
      for no key update;

      update public.games
      set status = 'ended', ended_reason = 'player_left'
      where table_id = v_solo
        and status in ('cutting', 'active');

      delete from public.table_members
      where table_id = v_solo;

      update public.tables
      set status = 'ended'
      where id = v_solo
        and status = 'open';
    end loop;
  end if;

  -- 3. Any other non-ended table still refuses (a single-player table of
  -- theirs is skipped: a real action has just ended it; a preview must not).
  select t.code, t.id
  into v_code, v_id
  from public.table_members tm
  join public.tables t on t.id = tm.table_id
  where tm.user_id = p_actor
    and t.status <> 'ended'
    and (p_target is null or t.id <> p_target)
    and not (
      t.computer_level is not null
      and t.created_by = p_actor
      and not exists (
        select 1
        from public.table_members o
        where o.table_id = t.id
          and o.user_id <> p_actor
          and not exists (
            select 1
            from public.computer_accounts ca
            where ca.user_id = o.user_id
          )
      )
    )
  order by tm.joined_at desc
  limit 1;

  if v_code is not null then
    raise exception using
      message = format('You''re already at table %s. Rejoin it or leave it first.', v_code),
      detail = 'already_at_table',
      -- Slice B: "<code> <table id>", so the app's "Go to table NNNN" can
      -- carry the id (/tables/NNNN?t=<id>). An app that only knows a bare
      -- code reads the code from the message instead (lib/oneTable.ts).
      hint = v_code || ' ' || v_id::text;
  end if;

  -- 4. Watching elsewhere ends (real actions only).
  if p_act then
    delete from public.table_spectators ts
    using public.tables t
    where t.id = ts.table_id
      and ts.user_id = p_actor
      and ts.removed_at is null
      and t.status <> 'ended'
      and (p_target is null or ts.table_id <> p_target);
  end if;
end;
$$;

comment on function public._one_table_rule(uuid, uuid, boolean) is
  'Internal (step 3, slices A and B): one person, one table. In a real action (p_act) it first ends the person''s other single-player (computer) tables the way leave_computer_table does; then refuses (DETAIL already_at_table, HINT "<code> <table id>") when the person is seated at another non-ended table with other humans; then, in a real action, ends their watching of other tables. A preview (p_act false) changes nothing and is not refused by a single-player table. No client role can execute it. See docs/sql/join-create.sql and free-codes-part1.sql.';

revoke all on function public._one_table_rule(uuid, uuid, boolean) from public;
revoke all on function public._one_table_rule(uuid, uuid, boolean) from anon;
revoke all on function public._one_table_rule(uuid, uuid, boolean) from authenticated;
revoke all on function public._one_table_rule(uuid, uuid, boolean) from service_role;


-- ---------------------------------------------------------------------------
-- 3. join_table_by_code(p_code, p_preview, p_table_id).
-- ---------------------------------------------------------------------------
-- The old (text, boolean) signature goes first: a second overload would make
-- a call with two arguments ambiguous. Same transaction: no moment without
-- a join_table_by_code. join-create.sql's body with p_table_id, the
-- uncounted mismatch, and host_avatar_url.
drop function if exists public.join_table_by_code(text, boolean);

create or replace function public.join_table_by_code(
  p_code text,
  p_preview boolean default false,
  p_table_id uuid default null
)
returns table (
  outcome text,
  table_id uuid,
  code text,
  status text,
  ended_reason text,
  is_public boolean,
  is_muggins boolean,
  allow_spectators boolean,
  created_by uuid,
  max_players smallint,
  team_mode text,
  computer_level text,
  seat smallint,
  seated_count integer,
  game_live boolean,
  game_id uuid,
  host_nickname text,
  host_avatar_url text
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_caller uuid := auth.uid();
  v_t record;
  v_seat smallint;
  v_outcome text;
  v_game uuid;
begin
  if v_caller is null then
    raise exception 'You must be logged in to join a table.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('one_table:' || v_caller::text, 0));
  perform public._code_guesses_check(v_caller);

  select t.id, t.code, t.status, t.ended_reason, t.is_public, t.is_muggins, t.allow_spectators,
         t.created_by, t.max_players, t.team_mode, t.computer_level
  into v_t
  from public.tables t
  where p_code ~ '^[0-9]{4}$'
    and t.code = p_code
    and t.status <> 'ended'
    -- Slice B: with the id the app already holds, only THAT table: a code
    -- now held by a different table never answers for it.
    and (p_table_id is null or t.id = p_table_id)
  order by t.created_at desc
  limit 1;

  if not found then
    -- Returned, not raised (an exception would undo the count). A bare code
    -- that matches no open table is a wrong guess and is counted; with
    -- p_table_id it is the app's own table that has ended (or whose code
    -- now belongs to another table), which is NOT counted.
    if p_table_id is null then
      perform public._code_guess_failed(v_caller);
    end if;
    outcome := 'not_found';
    return next;
    return;
  end if;

  select tm.seat
  into v_seat
  from public.table_members tm
  where tm.table_id = v_t.id
    and tm.user_id = v_caller;

  if found then
    v_outcome := 'already_seated';
  elsif p_preview then
    perform public._one_table_rule(v_caller, v_t.id, false);
    v_outcome := 'preview';
  else
    perform public._one_table_rule(v_caller, v_t.id, true);
    perform public._attempts_guard(v_caller, 'join', 30, interval '1 hour',
      'You can join at most 30 tables an hour. Please try again later.');

    -- Through the seat trigger: full tables refused as today.
    insert into public.table_members (table_id, user_id)
    values (v_t.id, v_caller)
    returning table_members.seat into v_seat;

    -- A player now: their own watching of this table ends (unless removed).
    delete from public.table_spectators ts
    where ts.table_id = v_t.id
      and ts.user_id = v_caller
      and ts.removed_at is null;

    v_outcome := 'joined';
  end if;

  select g.id
  into v_game
  from public.games g
  where g.table_id = v_t.id
    and g.status in ('cutting', 'active')
  order by g.created_at desc
  limit 1;

  outcome := v_outcome;
  table_id := v_t.id;
  code := v_t.code;
  status := v_t.status;
  ended_reason := v_t.ended_reason;
  is_public := v_t.is_public;
  is_muggins := v_t.is_muggins;
  allow_spectators := v_t.allow_spectators;
  created_by := v_t.created_by;
  max_players := v_t.max_players;
  team_mode := v_t.team_mode;
  computer_level := v_t.computer_level;
  seat := v_seat;
  select count(*)::integer into seated_count from public.table_members tm where tm.table_id = v_t.id;
  game_id := v_game;
  game_live := v_game is not null;
  select p.nickname, p.avatar_url into host_nickname, host_avatar_url
  from public.profiles p
  where p.id = public.table_host(v_t.id);
  return next;
end;
$$;

comment on function public.join_table_by_code(text, boolean, uuid) is
  'Join by code (step 3, slices A and B): seats the caller at the non-ended table with this code -- with p_table_id, only if it is still that table -- or, with p_preview, only describes it (the confirm screens use the preview: it seats nobody, ends nothing and is not counted toward the joins an hour). One row: outcome joined / already_seated / preview / not_found, the table (TableView''s TableRow columns plus is_public), the seat, seated_count, the live game, the host''s nickname and avatar. A bare code that matches nothing counts toward the wrong-code lockout; a p_table_id mismatch does not. One table at a time (DETAIL already_at_table), 30 joins an hour (rate_limited), 5 wrong codes in 10 minutes lock for 15 (locked_out); a full table is refused by the seat trigger. See docs/sql/join-create.sql and free-codes-part1.sql.';

revoke all on function public.join_table_by_code(text, boolean, uuid) from public;
revoke all on function public.join_table_by_code(text, boolean, uuid) from anon;
revoke all on function public.join_table_by_code(text, boolean, uuid) from service_role;
grant execute on function public.join_table_by_code(text, boolean, uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. watch_table(p_code, p_table_id): non-ended tables only.
-- ---------------------------------------------------------------------------
-- The old (text) signature goes first, as above. join-create.sql's body with
-- (B1) the non-ended filter and p_table_id, (B2) the uncounted mismatch.
-- The "This table has ended." refusal below the lookup stays (a table that
-- ends while this waits for its row lock no longer matches the lookup, so
-- it is not normally reached).
drop function if exists public.watch_table(text);

create or replace function public.watch_table(
  p_code text,
  p_table_id uuid default null
)
returns table (table_id uuid, code text, game_id uuid)
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_caller uuid := auth.uid();
  v_table record;
  v_game_id uuid;
  v_removed_at timestamptz;
  v_current int;
begin
  if v_caller is null then
    raise exception 'You must be logged in to watch a table.';
  end if;

  -- (J1) One person, one table: this person's actions are serialized (the
  -- person's lock is always taken before a table's).
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('one_table:' || v_caller::text, 0));

  -- (J2) The wrong-code lockout (shared with join_table_by_code).
  perform public._code_guesses_check(v_caller);

  -- THE ROW LOCK, the same one assign_table_seat (joining), set_seat and
  -- start_game_with_deal take: two watchers are serialized here, so the
  -- count below is final until this transaction ends.
  -- (B1) Only a NON-ENDED table with this code (slice B: an ended table's
  -- code may belong to another table soon) -- and, with p_table_id, only if
  -- it is still that table.
  select t.id, t.code, t.status, t.allow_spectators, t.computer_level
  into v_table
  from public.tables t
  where t.code = p_code
    and t.status <> 'ended'
    and (p_table_id is null or t.id = p_table_id)
  order by t.created_at desc
  limit 1
  for no key update;

  if not found then
    -- (J4, B2) NO ROW, never an exception (it would roll the count back). A
    -- bare code that matches no open table -- wrong, unknown or ended: "no
    -- such table" -- is counted toward the wrong-code lockout; with
    -- p_table_id it is the spectator's own table that has ended (or whose
    -- code moved on), which is NOT counted: the watch page shows it closed.
    if p_table_id is null then
      perform public._code_guess_failed(v_caller);
    end if;
    return;
  end if;

  if v_table.status is distinct from 'open' then
    raise exception 'This table has ended.';
  end if;

  -- Before allow_spectators, so a computer table gets its own message (the
  -- check constraint means it can never allow spectators anyway).
  if v_table.computer_level is not null then
    raise exception 'Computer tables cannot be watched.';
  end if;

  if not v_table.allow_spectators then
    raise exception 'This table does not allow spectators.';
  end if;

  -- A LIVE game, if there is one: the cut for deal or a game being played.
  -- NULL is fine now: the table is in its waiting room (or between games).
  select g.id
  into v_game_id
  from public.games g
  where g.table_id = v_table.id
    and g.status in ('cutting', 'active')
  order by g.created_at desc
  limit 1;

  if exists (
    select 1
    from public.table_members tm
    where tm.table_id = v_table.id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are seated at this table.';
  end if;

  -- (J5) An unfinished single-player game elsewhere ends quietly (as Leave
  -- does). Seated at ANOTHER non-ended table with other humans: refused,
  -- naming it. Watching any
  -- other table ends (a refusal below rolls that back too).
  perform public._one_table_rule(v_caller, v_table.id, true);

  select ts.removed_at
  into v_removed_at
  from public.table_spectators ts
  where ts.table_id = v_table.id
    and ts.user_id = v_caller;

  if v_removed_at is not null then
    raise exception 'You were removed from watching this table.';
  end if;

  -- THE CAP: 4 current spectators besides the caller (an already-current
  -- caller refreshing their place is never refused).
  select count(*)
  into v_current
  from public.table_spectators ts
  where ts.table_id = v_table.id
    and ts.user_id <> v_caller
    and ts.removed_at is null
    and ts.last_seen_at > now() - interval '90 seconds';

  if v_current >= 4 then
    raise exception 'Spectators full: this table already has 4 spectators.';
  end if;

  -- (J6) A NEW watch (no row of theirs at this table yet) counts toward 30
  -- an hour; refreshing a place they already have does not.
  if not exists (
    select 1
    from public.table_spectators ts
    where ts.table_id = v_table.id
      and ts.user_id = v_caller
  ) then
    perform public._attempts_guard(v_caller, 'watch', 30, interval '1 hour',
      'You can start watching at most 30 tables an hour. Please try again later.');
  end if;

  -- Insert, or refresh a row that is there (removed_at is null: checked
  -- above; the update never touches removed_at, so a removal that lands
  -- meanwhile still stands).
  insert into public.table_spectators as ts (table_id, user_id, joined_at, last_seen_at)
  values (v_table.id, v_caller, now(), now())
  on conflict on constraint table_spectators_pkey
  do update set last_seen_at = excluded.last_seen_at;

  table_id := v_table.id;
  code := v_table.code;
  game_id := v_game_id;   -- null while no game is live
  return next;
end;
$$;

comment on function public.watch_table(text, uuid) is
  'Spectator seat (PRD item 40, step 3 slices A and B): become or stay a spectator of the NON-ENDED table with this code -- with p_table_id, only if it is still that table -- whether or not a game is live. Refused with a message when not allowed: one table at a time (DETAIL already_at_table; watching another table ends), 30 new watches an hour (rate_limited), the wrong-code lockout (locked_out). No such open table returns NO row: counted as a wrong code for a bare code, not counted with p_table_id. Returns the table id, code and the live game id (null in the waiting room or between games).';

revoke all on function public.watch_table(text, uuid) from public;
revoke all on function public.watch_table(text, uuid) from anon;
revoke all on function public.watch_table(text, uuid) from service_role;
grant execute on function public.watch_table(text, uuid) to authenticated;

-- PostgREST: reload the schema cache now (the new signatures).
notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  (select count(*) from public.tables t where t.status = 'ended' and t.ended_at is null) as ended_tables_without_ended_at,
  (select count(*) from public.tables t where t.status <> 'ended' and t.ended_at is not null) as open_tables_with_ended_at,
  to_regprocedure('public.join_table_by_code(text, boolean, uuid)') is not null as join_new_signature,
  to_regprocedure('public.join_table_by_code(text, boolean)') is null as join_old_signature_gone,
  to_regprocedure('public.watch_table(text, uuid)') is not null as watch_new_signature,
  to_regprocedure('public.watch_table(text)') is null as watch_old_signature_gone;
