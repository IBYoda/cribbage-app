-- Step 3, slice B: ROLLBACK of docs/sql/free-codes-part1.sql.
-- Run in the Supabase Dashboard -> SQL Editor.
--
-- STATUS: written, NOT RUN yet. Kept for reference; run only if part 1 has
-- to come out.
--
-- BEFORE IT, in this order:
--   1. the app back on its slice A/C build: the slice B app calls
--      join_table_by_code and watch_table WITH p_table_id, which the old
--      signatures don't have ("function does not exist");
--   2. free-codes-part2-rollback.sql, if part 2 ever ran (part 2's picker
--      reads ended_at). The guard below refuses otherwise.
--
-- What it does, in one transaction:
--   1. _one_table_rule, join_table_by_code(text, boolean) and
--      watch_table(text) back to join-create.sql's text exactly, with their
--      comments and grants (the new signatures dropped first).
--   2. drops the tables_set_ended_at trigger, set_table_ended_at and the
--      ended_at index. KEEPS the ended_at column and its values (harmless,
--      and dropping it would lose when tables ended); drop it by hand if you
--      want: alter table public.tables drop column ended_at;
--
-- NOTE: the restored watch_table PREFERS the non-ended table with a code but
-- still finds an ended one ("This table has ended."). That is right while
-- codes are unique forever (part 2 not in place).

begin;

do $$
begin
  if to_regprocedure('public._pick_table_code(integer)') is not null then
    raise exception 'STOP: free-codes-part2.sql is in place (_pick_table_code exists). Run free-codes-part2-rollback.sql first. Nothing was changed.';
  end if;
end;
$$;

-- 1. The rule, join and watch, as join-create.sql has them.
create or replace function public._one_table_rule(p_actor uuid, p_target uuid, p_act boolean)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_code text;
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
  select t.code
  into v_code
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
      hint = v_code;
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
  'Internal (step 3, slice A): one person, one table. In a real action (p_act) it first ends the person''s other single-player (computer) tables the way leave_computer_table does; then refuses (DETAIL already_at_table, HINT the code) when the person is seated at another non-ended table with other humans; then, in a real action, ends their watching of other tables. A preview (p_act false) changes nothing and is not refused by a single-player table. No client role can execute it. See docs/sql/join-create.sql.';

revoke all on function public._one_table_rule(uuid, uuid, boolean) from public;
revoke all on function public._one_table_rule(uuid, uuid, boolean) from anon;
revoke all on function public._one_table_rule(uuid, uuid, boolean) from authenticated;
revoke all on function public._one_table_rule(uuid, uuid, boolean) from service_role;

drop function if exists public.join_table_by_code(text, boolean, uuid);

create or replace function public.join_table_by_code(p_code text, p_preview boolean default false)
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
  host_nickname text
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
  order by t.created_at desc
  limit 1;

  if not found then
    -- Counted, and returned (not raised: an exception would undo the count).
    perform public._code_guess_failed(v_caller);
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
  select p.nickname into host_nickname from public.profiles p where p.id = public.table_host(v_t.id);
  return next;
end;
$$;

comment on function public.join_table_by_code(text, boolean) is
  'Join by code (step 3, slice A): seats the caller at the non-ended table with this code (or, with p_preview, only describes it). One row: outcome joined / already_seated / preview / not_found (wrong, unknown or ended: one answer, counted toward the wrong-code lockout), the table (TableView''s TableRow columns plus is_public), the seat, seated_count, the live game and the host''s nickname. One table at a time (DETAIL already_at_table), 30 joins an hour (rate_limited), 5 wrong codes in 10 minutes lock for 15 (locked_out); a full table is refused by the seat trigger as before. See docs/sql/join-create.sql.';

revoke all on function public.join_table_by_code(text, boolean) from public;
revoke all on function public.join_table_by_code(text, boolean) from anon;
revoke all on function public.join_table_by_code(text, boolean) from service_role;
grant execute on function public.join_table_by_code(text, boolean) to authenticated;

drop function if exists public.watch_table(text, uuid);

create or replace function public.watch_table(p_code text)
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
  -- (J3) The non-ended table with this code first (identical today, while
  -- codes are unique; right once slice B frees ended tables' codes).
  select t.id, t.code, t.status, t.allow_spectators, t.computer_level
  into v_table
  from public.tables t
  where t.code = p_code
  order by (t.status <> 'ended') desc, t.created_at desc
  limit 1
  for no key update;

  if not found then
    -- (J4) A wrong or unknown code: counted, and NO ROW returned instead of
    -- the old exception "No table found with code ..." (an exception would
    -- roll the count back).
    perform public._code_guess_failed(v_caller);
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

comment on function public.watch_table(text) is
  'Spectator seat (PRD item 40): become or stay a spectator of the table with this code, whether or not a game is live. Refused with a message when not allowed (see docs/sql/spectators.sql, spectators-join-or-watch.sql and join-create.sql): one table at a time (DETAIL already_at_table; watching another table ends), 30 new watches an hour (rate_limited), the wrong-code lockout (locked_out). A wrong or unknown code returns NO row (counted). Returns the table id, code and the live game id (null in the waiting room or between games).';

revoke all on function public.watch_table(text) from public;
revoke all on function public.watch_table(text) from anon;
revoke all on function public.watch_table(text) from service_role;
grant execute on function public.watch_table(text) to authenticated;

-- 2. ended_at's trigger, function and index (the column stays).
drop trigger if exists tables_set_ended_at on public.tables;
drop function if exists public.set_table_ended_at();
drop index if exists public.tables_ended_at_idx;

notify pgrst, 'reload schema';

commit;
