-- Spectator seat, slice 1: the database side (PRD item 40).
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: RUN in production on 2026-11-20: "Success. No rows returned."
-- (after the precheck, which was clean). Its verification passed the same
-- day: ALL 134 CHECKS PASSED, T3 included (none skipped).
-- SLICE 2: docs/sql/spectators-join-or-watch.sql (live 2026-11-20) replaces
-- watch_table (accepts a table with no live game) and spectator_heartbeat
-- (refreshes the place between games); the text below is slice 1's.
--
-- RUN ORDER:
--   1. docs/sql/spectators-precheck.sql      (read-only; one result)
--   2. docs/sql/spectators.sql               (this file)
--   3. docs/sql/spectators-verification.sql  (writes test rows, then rolls
--                                             them all back; its final
--                                             message is the verdict)
--   If it has to come out: docs/sql/spectators-rollback.sql.
-- Needs, already live: slice-3-tables.sql (tables), slice-4-join-table.sql
-- (table_members), phase3-e1-seating.sql (seats, table_host,
-- assign_table_seat), computer-c2-engine.sql (tables.computer_level), the
-- game tables (games, game_hands, game_cribs) as last defined by
-- phase3-e4-counting.sql.
--
-- WHAT A SPECTATOR IS (the design, PRD item 40)
--   Someone who watches a live game at a MULTIPLAYER table whose host ticked
--   "Allow spectators" when creating it. A spectator is NEVER a
--   table_members row: every game rule, the seat trigger, leave_table,
--   table_host, the start count and chat all count table_members only, so a
--   spectator can neither trigger nor block any of them. Up to 4 CURRENT
--   spectators per table; the host can remove one, for good.
--
--   What a spectator sees: the public game state -- tables, table_members,
--   games, game_plays and profiles are already readable by every signed-in
--   user and already reach the table page through its public realtime
--   channel. The ONLY hidden card data are game_hands and game_cribs (and
--   game_decks, which no user can ever read). This file adds one read for
--   those, get_spectator_reveals, gated by phase exactly as the players'
--   own read policies are:
--     * hands: every hand from the start of counting on (phase 'counting'
--       or 'done' of a LIVE game). Every card of every hand has already been
--       played in pegging by then, so nothing new is revealed.
--     * the crib: only from its counting step on (count_step >= the number
--       of players) or phase 'done'.
--     * a game that has ended (won, left, admin, timeout): NOTHING. A
--       spectator stays on the table through the game's end (the result
--       screen) and a return to the waiting room, but never receives a
--       hidden card of an ended game: the won-mid-pegging reveal path (where
--       players see unplayed cards and an unshown crib) is never open to a
--       spectator.
--     * the deck: never. get_spectator_reveals does not mention game_decks.
--
-- THE RULES
--   watch_table(code) -- become (or stay) a spectator. Refused, each with a
--     clear message, when: nobody is signed in; no table has that code; the
--     table is not open; it is a computer table; it does not allow
--     spectators; it has no LIVE game (status 'cutting' -- the cut for deal
--     -- or 'active'); the caller is seated there; the caller was removed
--     from watching it (permanent for that table); 4 other current
--     spectators are already there ("Spectators full"). CURRENT means not
--     removed and seen in the last 90 seconds (last_seen_at). It takes the
--     tables row lock exactly as assign_table_seat does (for no key update),
--     so two people can never both take the 4th slot. Returns the table id,
--     its code and the live game id, for the app to route to the watch page.
--   stop_watching(table) -- deletes the caller's own row, unless they were
--     removed (the removal must stick). Quiet when there is nothing to do.
--   remove_spectator(table, user) -- the host only (public.table_host: the
--     creator while seated, otherwise the lowest seat). Sets removed_at;
--     a second removal is quiet. Refused for anyone else, for a table that
--     has ended, and for someone not watching.
--   spectator_heartbeat(table) -- the app calls it on its safety poll. It
--     refreshes last_seen_at and returns ONE word:
--       'ok'           watching; last_seen_at refreshed.
--       'removed'      the host removed the caller.
--       'table_ended'  the table is no longer open.
--       'game_ended'   the table is open but no game is live.
--       'not_watching' no row (never watched, or stopped), nobody signed
--                      in, the caller is now seated there, or the row had
--                      gone stale and the 4 places were taken meanwhile.
--     The app: 'ok' and 'game_ended' stay on the table (a game end and a
--     return to waiting included); 'removed' sends the spectator home;
--     'table_ended' shows a closed-table screen; 'not_watching' asks
--     watch_table again, quietly.
--   get_spectator_reveals(game) -- see above. Returns NULL (never an error)
--     whenever the caller may see nothing: nobody signed in, no such game,
--     the game is not live, the table is not open / not human / does not
--     allow spectators, the caller is seated there, or the caller is not a
--     current, non-removed spectator of that table. Otherwise:
--       {"game_id": <uuid>, "hand_no": <int>,
--        "hands": {"<user id>": [cards], ...}   -- {} before counting
--        "crib": [cards] | null}                -- null before its step
--     Read-only (STABLE): it never writes, so it can't touch the game.
--
-- WHAT THIS FILE ADDS (and spectators-rollback.sql removes exactly this):
--   1. COLUMN public.tables.allow_spectators boolean not null default false,
--      and CHECK tables_spectators_human_only: computer_level is null or not
--      allow_spectators. Existing rows get false (catalog-only change).
--      create_computer_table lists its insert columns, so it gets the
--      default and keeps working unchanged. Players can't change it after
--      creation (the only UPDATE policy on tables is the admin one).
--   2. TABLE public.table_spectators (table_id, user_id, joined_at,
--      last_seen_at, removed_at; primary key (table_id, user_id)). RLS on.
--      Grants in the order of docs/sql/appearance-settings.sql: revoke all
--      from public, anon and authenticated (and service_role: nothing needs
--      it), then authenticated SELECT only. One read policy: members of the
--      table, or the spectator's own row. No write policy: only the
--      functions below write. NOT added to the supabase_realtime
--      publication.
--   3. FIVE FUNCTIONS: watch_table, stop_watching, remove_spectator,
--      spectator_heartbeat, get_spectator_reveals. Security definer,
--      search_path '' with every name written in full, EXECUTE for
--      authenticated only (revoked from public, anon and service_role).
--   NOTHING ELSE: no existing function (the eight _as game functions
--   included, so the C1/C2 fingerprints stay valid), policy, trigger or
--   publication is touched.
--
-- RE-RUNNABLE: "add column / create table if not exists", the constraint
-- dropped (if it exists) before it is added, "create or replace" for the
-- functions, the policy dropped (if it exists) before it is created, grants
-- and revokes idempotent. One transaction: if any statement fails, nothing
-- is applied.


begin;

-- ---------------------------------------------------------------------------
-- 1. tables.allow_spectators, and computer tables can never have it.
-- ---------------------------------------------------------------------------
alter table public.tables
  add column if not exists allow_spectators boolean not null default false;

alter table public.tables drop constraint if exists tables_spectators_human_only;
alter table public.tables
  add constraint tables_spectators_human_only
  check (computer_level is null or not allow_spectators);

comment on column public.tables.allow_spectators is
  'Spectator seat (PRD item 40): when true, up to 4 people may watch a live game here (watch_table) without being seated. Chosen by the creator on insert (default false); players cannot change it afterwards (only the admin UPDATE policy exists). Never true at a computer table (tables_spectators_human_only).';


-- ---------------------------------------------------------------------------
-- 2. The spectators table.
-- ---------------------------------------------------------------------------
create table if not exists public.table_spectators (
  table_id uuid not null references public.tables (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  joined_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  removed_at timestamptz,
  primary key (table_id, user_id)
);

comment on table public.table_spectators is
  'Spectator seat (PRD item 40): who is watching which table. NOT table_members: a spectator never plays and never counts for any game rule. Current = removed_at is null and last_seen_at within 90 seconds; at most 4 current per table. removed_at is set by the host (remove_spectator) and is permanent for that table. Written only by the spectator functions; not in Realtime.';

-- Row-level security: on.
alter table public.table_spectators enable row level security;

-- Grants, explicit (the appearance-settings.sql order): nothing for PUBLIC,
-- anon or service_role; authenticated may SELECT (under the policy below)
-- and nothing else. Every write goes through the security definer functions.
revoke all on table public.table_spectators from public;
revoke all on table public.table_spectators from anon;
revoke all on table public.table_spectators from authenticated;
revoke all on table public.table_spectators from service_role;

grant select on table public.table_spectators to authenticated;

-- Read: the players seated at that table (so the host can see whom to
-- remove), or the spectator's own row. table_members is readable by every
-- signed-in user, so the subquery sees what it needs; it can only narrow.
drop policy if exists "Table members and the spectator read spectator rows" on public.table_spectators;

create policy "Table members and the spectator read spectator rows"
  on public.table_spectators for select
  to authenticated
  using (
    user_id = (select auth.uid())
    or exists (
      select 1
      from public.table_members tm
      where tm.table_id = table_spectators.table_id
        and tm.user_id = (select auth.uid())
    )
  );

-- Realtime: deliberately NOTHING. table_spectators is not added to the
-- supabase_realtime publication. (The verification checks it isn't there.)


-- ---------------------------------------------------------------------------
-- 3a. watch_table(code)
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

  -- A LIVE game: the cut for deal or a game being played.
  select g.id
  into v_game_id
  from public.games g
  where g.table_id = v_table.id
    and g.status in ('cutting', 'active')
  order by g.created_at desc
  limit 1;

  if v_game_id is null then
    raise exception 'There is no game to watch at this table yet.';
  end if;

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
  game_id := v_game_id;
  return next;
end;
$$;

comment on function public.watch_table(text) is
  'Spectator seat (PRD item 40): become or stay a spectator of the live game at the table with this code. Refused with a message when not allowed (see docs/sql/spectators.sql). Returns the table id, code and live game id.';


-- ---------------------------------------------------------------------------
-- 3b. stop_watching(table)
-- ---------------------------------------------------------------------------
create or replace function public.stop_watching(p_table_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_caller uuid := auth.uid();
begin
  if v_caller is null then
    raise exception 'You must be logged in to stop watching.';
  end if;

  -- A removed row stays: the removal is permanent for that table.
  delete from public.table_spectators ts
  where ts.table_id = p_table_id
    and ts.user_id = v_caller
    and ts.removed_at is null;
end;
$$;

comment on function public.stop_watching(uuid) is
  'Spectator seat (PRD item 40): stop watching this table (deletes the caller''s own row unless they were removed). Quiet when there is nothing to do.';


-- ---------------------------------------------------------------------------
-- 3c. remove_spectator(table, user)
-- ---------------------------------------------------------------------------
create or replace function public.remove_spectator(p_table_id uuid, p_user_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_caller uuid := auth.uid();
  v_status text;
begin
  if v_caller is null then
    raise exception 'You must be logged in to remove a spectator.';
  end if;

  select t.status
  into v_status
  from public.tables t
  where t.id = p_table_id;

  if not found then
    raise exception 'Table not found.';
  end if;

  if v_status is distinct from 'open' then
    raise exception 'This table has ended.';
  end if;

  -- The host, worked out by the existing rule (phase3-e1-seating.sql): the
  -- creator while seated, otherwise the player in the lowest seat.
  if public.table_host(p_table_id) is distinct from v_caller then
    raise exception 'Only the host can remove a spectator.';
  end if;

  update public.table_spectators ts
  set removed_at = now()
  where ts.table_id = p_table_id
    and ts.user_id = p_user_id
    and ts.removed_at is null;

  if not found and not exists (
    select 1
    from public.table_spectators ts
    where ts.table_id = p_table_id
      and ts.user_id = p_user_id
  ) then
    raise exception 'That player is not watching this table.';
  end if;
end;
$$;

comment on function public.remove_spectator(uuid, uuid) is
  'Spectator seat (PRD item 40): the host removes a spectator from this table, for good (removed_at). Quiet if already removed.';


-- ---------------------------------------------------------------------------
-- 3d. spectator_heartbeat(table)
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

  if not exists (
    select 1
    from public.games g
    where g.table_id = p_table_id
      and g.status in ('cutting', 'active')
  ) then
    return 'game_ended';
  end if;

  -- A STALE row (not seen for 90 seconds) no longer holds a place, so
  -- coming back is a rejoin: take the same lock as watch_table and check
  -- the cap again.
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

  update public.table_spectators ts
  set last_seen_at = now()
  where ts.table_id = p_table_id
    and ts.user_id = v_caller
    and ts.removed_at is null;

  return 'ok';
end;
$$;

comment on function public.spectator_heartbeat(uuid) is
  'Spectator seat (PRD item 40): refresh the caller''s place as a spectator of this table. Returns ok, removed, table_ended, game_ended or not_watching; anything but ok sends the app to the lobby.';


-- ---------------------------------------------------------------------------
-- 3e. get_spectator_reveals(game)
-- ---------------------------------------------------------------------------
create or replace function public.get_spectator_reveals(p_game_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_caller uuid := auth.uid();
  v_game record;
  v_table record;
  v_hands jsonb := '{}'::jsonb;
  v_crib jsonb;
begin
  if v_caller is null or p_game_id is null then
    return null;
  end if;

  select g.id, g.table_id, g.status, g.phase, g.count_step, g.players, g.hand_no
  into v_game
  from public.games g
  where g.id = p_game_id;

  if not found then
    return null;
  end if;

  -- A LIVE game only. An ended game (won, left, admin, timeout) shows a
  -- spectator nothing: they go to the lobby instead of seeing its board.
  if v_game.status is distinct from 'cutting' and v_game.status is distinct from 'active' then
    return null;
  end if;

  select t.status, t.allow_spectators, t.computer_level
  into v_table
  from public.tables t
  where t.id = v_game.table_id;

  if not found
     or v_table.status is distinct from 'open'
     or v_table.computer_level is not null
     or v_table.allow_spectators is not true then
    return null;
  end if;

  -- Seated players read their table through their own policies, never here.
  if exists (
    select 1
    from public.table_members tm
    where tm.table_id = v_game.table_id
      and tm.user_id = v_caller
  ) then
    return null;
  end if;

  -- A CURRENT spectator of this table: not removed, seen in the last 90 s.
  if not exists (
    select 1
    from public.table_spectators ts
    where ts.table_id = v_game.table_id
      and ts.user_id = v_caller
      and ts.removed_at is null
      and ts.last_seen_at > now() - interval '90 seconds'
  ) then
    return null;
  end if;

  -- HANDS: from the start of counting on (every card already played in
  -- pegging), every hand, as the players get them.
  if v_game.status = 'active' and v_game.phase in ('counting', 'done') then
    select coalesce(jsonb_object_agg(h.user_id::text, to_jsonb(h.cards)), '{}'::jsonb)
    into v_hands
    from public.game_hands h
    where h.game_id = v_game.id
      and h.user_id = any(v_game.players);
  end if;

  -- THE CRIB: only from its own counting step (after every hand) or 'done'.
  if v_game.status = 'active'
     and (v_game.phase = 'done'
          or (v_game.phase = 'counting'
              and v_game.count_step >= coalesce(array_length(v_game.players, 1), 2))) then
    select to_jsonb(c.cards)
    into v_crib
    from public.game_cribs c
    where c.game_id = v_game.id;
  end if;

  return jsonb_build_object(
    'game_id', v_game.id,
    'hand_no', v_game.hand_no,
    'hands', v_hands,
    'crib', v_crib
  );
end;
$$;

comment on function public.get_spectator_reveals(uuid) is
  'Spectator seat (PRD item 40): for a current spectator of this LIVE game''s table, the hands from counting on and the crib from its step on ({"game_id","hand_no","hands","crib"}). NULL whenever the caller may see nothing, and always for an ended game. Never reads the deck.';


-- ---------------------------------------------------------------------------
-- 4. EXECUTE: authenticated only. Postgres lets PUBLIC execute a new
-- function by default and this project's default privileges may give it to
-- anon and service_role too: take it from all of them first.
-- ---------------------------------------------------------------------------
revoke all on function public.watch_table(text) from public;
revoke all on function public.watch_table(text) from anon;
revoke all on function public.watch_table(text) from service_role;
grant execute on function public.watch_table(text) to authenticated;

revoke all on function public.stop_watching(uuid) from public;
revoke all on function public.stop_watching(uuid) from anon;
revoke all on function public.stop_watching(uuid) from service_role;
grant execute on function public.stop_watching(uuid) to authenticated;

revoke all on function public.remove_spectator(uuid, uuid) from public;
revoke all on function public.remove_spectator(uuid, uuid) from anon;
revoke all on function public.remove_spectator(uuid, uuid) from service_role;
grant execute on function public.remove_spectator(uuid, uuid) to authenticated;

revoke all on function public.spectator_heartbeat(uuid) from public;
revoke all on function public.spectator_heartbeat(uuid) from anon;
revoke all on function public.spectator_heartbeat(uuid) from service_role;
grant execute on function public.spectator_heartbeat(uuid) to authenticated;

revoke all on function public.get_spectator_reveals(uuid) from public;
revoke all on function public.get_spectator_reveals(uuid) from anon;
revoke all on function public.get_spectator_reveals(uuid) from service_role;
grant execute on function public.get_spectator_reveals(uuid) to authenticated;

commit;
