-- Spectator seat, slice 2: join-or-watch (PRD item 40, follow-up).
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: run in Supabase on 2026-11-20; verified (ALL 32 CHECKS PASSED, rolled back).
-- The apply file ran clean: "Success. No rows returned."
--
-- DEPLOY ORDER (history): the APP half of this slice (it accepts a NULL game
-- id from watch_table and shows the waiting room) had to be live before this
-- file ran, because the slice-1 app treated a null game id as an error. It
-- was: the app half shipped first (PR #117), then this file ran. The new app
-- also works with the old SQL, so app first was always safe.
--
-- RUN ORDER:
--   1. docs/sql/spectators-join-or-watch.sql               (this file)
--   2. docs/sql/spectators-join-or-watch-verification.sql  (writes test rows,
--      then rolls them all back; its final message is the verdict)
--   If it has to come out: docs/sql/spectators-join-or-watch-rollback.sql.
-- Needs, already live: docs/sql/spectators.sql and
-- docs/sql/spectators-grant-insert.sql. The read-only precheck of
-- 2026-11-20 (profiles privileges, constraints and triggers; every existing
-- avatar address; the avatars bucket) is its input: all 14 existing
-- avatar_url values are inside the project's avatars storage path.
--
-- WHAT THIS FILE CHANGES (three things, nothing else)
--   1. watch_table(code): a table with NO live game can now be watched. A
--      spectator can sit in the waiting room (and between games) of an open,
--      human table that allows spectators. It returns a NULL game_id then.
--      Every other refusal is unchanged and keeps its order and its exact
--      message: not signed in, no such table, ended, computer table, does not
--      allow spectators, seated, removed, "Spectators full". The cap and the
--      tables row lock (for no key update) are exactly as before, so the
--      4-place cap now also holds at an idle table.
--      Removed: the refusal "There is no game to watch at this table yet."
--   2. spectator_heartbeat(table): the place is now refreshed when no game
--      is live too, and the stale-row cap re-check applies there as well.
--      Returns 'game_ended' (as before: "open table, no live game") AFTER
--      refreshing last_seen_at, so a spectator who stays at the table between
--      games keeps the place. 'removed' and 'table_ended' still refresh
--      nothing; 'not_watching' is unchanged (and, as before, a stale row
--      with 4 other current spectators is NOT refreshed).
--   3. profiles.avatar_url: CHECK profiles_avatar_url_project_storage --
--      empty, '' or an address inside this project's public avatars storage
--      (and containing no ".." segment)
--      (https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/
--      avatars/...). Keeps other people's browsers from being pointed at an
--      arbitrary address. Added VALIDATED: the precheck showed all 14 existing
--      values already comply, and the ADD fails (nothing applied) if one
--      doesn't. Profile uploads and the computer accounts' addresses are
--      all inside that path.
--   NOT touched: get_spectator_reveals (still null for any game that is not
--   live), stop_watching, remove_spectator, table_spectators, its policy and
--   grants, the grants on the two functions (create or replace keeps them),
--   and every game function.
--
-- RE-RUNNABLE: "create or replace" for the functions; the constraint dropped
-- (if it exists) before it is added. One transaction: if any statement fails,
-- nothing is applied.

begin;

-- ---------------------------------------------------------------------------
-- 1. watch_table(code): the "no game yet" refusal is gone.
-- ---------------------------------------------------------------------------
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

  -- THE ROW LOCK, the same one assign_table_seat (joining), set_seat and
  -- start_game_with_deal take: two watchers are serialized here, so the
  -- count below is final until this transaction ends.
  select t.id, t.code, t.status, t.allow_spectators, t.computer_level
  into v_table
  from public.tables t
  where t.code = p_code
  for no key update;

  if not found then
    raise exception 'No table found with code %.', coalesce(p_code, '');
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
  'Spectator seat (PRD item 40): become or stay a spectator of the table with this code, whether or not a game is live. Refused with a message when not allowed (see docs/sql/spectators.sql and spectators-join-or-watch.sql). Returns the table id, code and the live game id (null in the waiting room or between games).';


-- ---------------------------------------------------------------------------
-- 2. spectator_heartbeat(table): keep the place between games.
-- ---------------------------------------------------------------------------
create or replace function public.spectator_heartbeat(p_table_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_caller uuid := auth.uid();
  v_removed_at timestamptz;
  v_last_seen timestamptz;
  v_status text;
  v_live boolean;
  v_current int;
begin
  if v_caller is null then
    return 'not_watching';
  end if;

  select ts.removed_at, ts.last_seen_at
  into v_removed_at, v_last_seen
  from public.table_spectators ts
  where ts.table_id = p_table_id
    and ts.user_id = v_caller;

  if not found then
    return 'not_watching';
  end if;

  if v_removed_at is not null then
    return 'removed';
  end if;

  select t.status
  into v_status
  from public.tables t
  where t.id = p_table_id;

  if v_status is distinct from 'open' then
    return 'table_ended';
  end if;

  if exists (
    select 1
    from public.table_members tm
    where tm.table_id = p_table_id
      and tm.user_id = v_caller
  ) then
    return 'not_watching';
  end if;

  select exists (
    select 1
    from public.games g
    where g.table_id = p_table_id
      and g.status in ('cutting', 'active')
  )
  into v_live;

  -- A STALE row (not seen for 90 seconds) no longer holds a place, so
  -- coming back is a rejoin: take the same lock as watch_table and check
  -- the cap again. (Now also while no game is live.)
  if v_last_seen <= now() - interval '90 seconds' then
    perform 1
    from public.tables t
    where t.id = p_table_id
    for no key update;

    select count(*)
    into v_current
    from public.table_spectators ts
    where ts.table_id = p_table_id
      and ts.user_id <> v_caller
      and ts.removed_at is null
      and ts.last_seen_at > now() - interval '90 seconds';

    if v_current >= 4 then
      return 'not_watching';
    end if;
  end if;

  -- Refresh the place, with or without a live game.
  update public.table_spectators ts
  set last_seen_at = now()
  where ts.table_id = p_table_id
    and ts.user_id = v_caller
    and ts.removed_at is null;

  if not v_live then
    return 'game_ended';
  end if;

  return 'ok';
end;
$$;

comment on function public.spectator_heartbeat(uuid) is
  'Spectator seat (PRD item 40): refresh the caller''s place as a spectator of this table. Returns ok (a game is live), game_ended (the table is open but no game is live; the place is still refreshed, so a spectator can wait for the next game), removed, table_ended or not_watching. Only removed, table_ended and not_watching take the app away from the table; see docs/sql/spectators-join-or-watch.sql.';


-- ---------------------------------------------------------------------------
-- 3. profiles.avatar_url: only this project's own avatars storage.
-- ---------------------------------------------------------------------------
alter table public.profiles drop constraint if exists profiles_avatar_url_project_storage;

alter table public.profiles
  add constraint profiles_avatar_url_project_storage
  check (
    avatar_url is null
    or avatar_url = ''
    or (
      avatar_url like 'https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/avatars/%'
      and avatar_url not like '%..%'
    )
  );

comment on constraint profiles_avatar_url_project_storage on public.profiles is
  'Avatar addresses may only point into this project''s public avatars storage (or be empty), so nobody can point other players'' browsers at an arbitrary address. See docs/sql/spectators-join-or-watch.sql.';

commit;
