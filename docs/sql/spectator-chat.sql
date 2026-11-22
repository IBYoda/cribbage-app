-- Spectator chat, step 1: spectators may send and hear table chat, and the
-- table's current spectators can be listed (PRD items 39 and 40).
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- RUN ORDER:
--   1. docs/sql/spectator-chat-precheck.sql      (read-only; one result)
--   2. docs/sql/spectator-chat.sql               (this file)
--   3. docs/sql/spectator-chat-verification.sql  (writes test rows, then
--                                                 rolls them all back; its
--                                                 final message is the
--                                                 verdict)
--   4. docs/sql/table-chat-verification.sql      (the existing chat suite,
--                                                 unchanged: it must still
--                                                 pass, see below)
--   If it has to come out: docs/sql/spectator-chat-rollback.sql.
-- Needs, already live: table-chat.sql (chat_topic_allows and the two
-- realtime.messages policies), spectators.sql (table_spectators,
-- tables.allow_spectators, watch_table, remove_spectator), and
-- spectators-join-or-watch.sql.
--
-- DEPLOY ORDER: this file can run before the app half. It only WIDENS chat
-- (a current spectator gains what a seated player has) and ADDS one read
-- function; nothing the app calls today changes its answer for a seated
-- player, and the app today never joins chat as a spectator (chatOn requires
-- a seat), so until the app half ships nobody uses the new rights.
--
-- THE DECISIONS (Walt, 2026-11-22)
--   * A CURRENT spectator -- their table_spectators row has removed_at null
--     and last_seen_at within the last 90 seconds, judged on the SERVER's
--     clock -- at an open, human table that allows spectators may SEND on
--     their own topic chat:<table_id>:<their user id> and LISTEN to any topic
--     of that table, exactly like a seated player.
--   * Everything else in chat_topic_allows stays: the topic's shape is
--     checked first, somebody must be signed in, a sender may only send on
--     their own topic, the table must be open and a human table. A seated
--     player gets exactly the answers they got before. A user who is neither
--     seated nor a current spectator still gets false; so does a removed or
--     stale spectator, at the moment they join a channel.
--   * The two policies on realtime.messages are NOT touched: they still call
--     chat_topic_allows((select realtime.topic()), false / true), which is
--     what the existing chat suite's check C3 matches.
--   * NEW public.get_table_spectators(table): the table's current spectators
--     (user_id, joined_at), oldest first, for a caller who is seated there
--     or is a current spectator there; zero rows for anyone else. Spectators
--     can't read each other's table_spectators rows (its policy allows only
--     your own row, or every row of a table you are seated at), and they
--     need the other spectators' ids to listen to their channels. Names and
--     avatars come from profiles, which every signed-in user can read.
--
-- WHAT REALTIME DOES WITH IT (unchanged by this file, and worth knowing)
--   Realtime asks the policies when a client JOINS a private channel (and
--   again when its login token is refreshed), not for every message. So:
--   * a spectator who goes stale or is removed AFTER joining keeps the
--     channels they already hold until they rejoin or their token is
--     refreshed (PRD item 39's caveat, which applies to players who leave
--     too). The app's answer is on the listeners' side: players and other
--     spectators stop listening to a spectator who is no longer listed by
--     get_table_spectators, and drop anything that still arrives from them.
--   * a spectator whose place lapsed (a hidden tab) and comes back is let
--     in again once spectator_heartbeat / watch_table has refreshed their
--     row, on their next join.
--
-- THE HARD CONSTRAINTS from table-chat-verification.sql (it must still
-- pass, 68 checks, or 61 if its live-policy checks are skipped):
--   C1  chat_topic_allows stays: returns boolean, security definer, STABLE,
--       search_path ''.
--   C3  the two policies' text, unchanged here.
--   C4  no OTHER function in public with "chat" in its name (hence the name
--       get_table_spectators), and chat_topic_allows' body -- comments
--       INCLUDED -- never contains realtime.send or the words for the three
--       write commands. Every comment in the body below is worded without
--       them; please keep it that way.
--   None of its 68 checks changes: its people C and D have no
--   table_spectators row, so every case that expects false still does.
--
-- WHAT THIS FILE CHANGES (and spectator-chat-rollback.sql undoes exactly this)
--   1. chat_topic_allows(text, boolean): one new rule after the seat check
--      (rule 6 below). Same signature, same return type, same volatility,
--      same security, so "create or replace" keeps its grants and the
--      policies that call it.
--   2. NEW get_table_spectators(uuid): stable, security definer, search_path
--      '', EXECUTE for authenticated only.
--   Nothing else: no table, column, policy, trigger or publication changes.
--   No table is created, so the AGENTS.md "New tables" grants rule doesn't
--   apply.
--
-- RE-RUNNABLE: "create or replace" for both functions; grants and revokes
-- are idempotent. One transaction: if any statement fails, nothing is
-- applied.

begin;

-- ---------------------------------------------------------------------------
-- 1. chat_topic_allows: seated players as before, plus current spectators.
-- ---------------------------------------------------------------------------
-- p_topic: the channel's topic, as realtime.topic() gives it.
-- p_send:  true for "may this caller SEND here", false for "may they
--          RECEIVE here".
-- Returns true or false, never null, never an error.
--
-- plpgsql, not plain SQL, on purpose: its IF runs strictly in order, so the
-- pattern check is sure to happen before the ::uuid casts.
create or replace function public.chat_topic_allows(p_topic text, p_send boolean)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_caller uuid := auth.uid();
  v_table_id uuid;
  v_sender_id uuid;
begin
  -- Rule 1: the exact shape, lowercase only. "chat:" (5 characters), a
  -- uuid (36), ":" , a uuid (36): 78 characters in all.
  if p_topic is null or p_send is null
     or p_topic !~ '^chat:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;

  -- Rule 2: signed in.
  if v_caller is null then
    return false;
  end if;

  -- Safe now: both pieces are well-formed uuids.
  v_table_id := substr(p_topic, 6, 36)::uuid;
  v_sender_id := substr(p_topic, 43, 36)::uuid;

  -- Rule 3: send only on your own channel. This holds for spectators too.
  -- (A server-side MUTE would be checked here too, for p_send only.)
  if p_send and v_sender_id <> v_caller then
    return false;
  end if;

  -- Rule 4 (and 5): seated at an open, human table. Unchanged.
  if exists (
    select 1
    from public.table_members tm
    join public.tables t on t.id = tm.table_id
    where tm.table_id = v_table_id
      and tm.user_id = v_caller
      and t.status = 'open'
      and t.computer_level is null
  ) then
    return true;
  end if;

  -- Rule 6: or a CURRENT spectator of that table, with a seated player's
  -- rights for both questions: send on their own channel (rule 3 above has
  -- already refused any other) and receive on any channel of the table.
  -- Current: not removed, and seen in the last 90 seconds by the server's
  -- own clock (the same test watch_table and get_spectator_reveals use).
  -- The table must be open, a human table, and allow spectators.
  return exists (
    select 1
    from public.table_spectators ts
    join public.tables t on t.id = ts.table_id
    where ts.table_id = v_table_id
      and ts.user_id = v_caller
      and ts.removed_at is null
      and ts.last_seen_at > now() - interval '90 seconds'
      and t.status = 'open'
      and t.computer_level is null
      and t.allow_spectators is true
  );
end;
$$;

comment on function public.chat_topic_allows(text, boolean) is
  'Table chat (PRD items 39 and 40): may the signed-in caller send (p_send true) or receive (false) on the Realtime broadcast topic chat:<table_id>:<sender_user_id>? Seated players, and current spectators (not removed, seen in the last 90 s) of an open human table that allows spectators. Used only by the two "table chat" policies on realtime.messages.';

-- Unchanged grants, restated (create or replace keeps them; this makes a
-- re-run on a project where they drifted end in the right state).
revoke all on function public.chat_topic_allows(text, boolean) from public;
revoke all on function public.chat_topic_allows(text, boolean) from anon;
revoke all on function public.chat_topic_allows(text, boolean) from service_role;
grant execute on function public.chat_topic_allows(text, boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- 2. get_table_spectators(table): who is watching, for those at the table.
-- ---------------------------------------------------------------------------
-- The table's CURRENT spectators (removed_at null, last_seen_at within 90
-- seconds by the server's clock), oldest joined_at first (user_id breaks a
-- tie), for a caller who is SEATED at that table or is a CURRENT spectator
-- of it. Anyone else -- nobody signed in, an outsider, a removed or stale
-- spectator, a null or unknown table -- gets zero rows. Never raises.
-- It reads table_spectators as the owner (security definer), which is how a
-- spectator sees the other spectators: their own policy would show them
-- only their own row. It does not look at the table's status: the app asks
-- only about the open table on its screen, and at an ended table the list
-- is simply whoever was still current.
create or replace function public.get_table_spectators(p_table_id uuid)
returns table (user_id uuid, joined_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select ts.user_id, ts.joined_at
  from public.table_spectators ts
  where ts.table_id = p_table_id
    and ts.removed_at is null
    and ts.last_seen_at > now() - interval '90 seconds'
    and (select auth.uid()) is not null
    and (
      exists (
        select 1
        from public.table_members tm
        where tm.table_id = p_table_id
          and tm.user_id = (select auth.uid())
      )
      or exists (
        select 1
        from public.table_spectators me
        where me.table_id = p_table_id
          and me.user_id = (select auth.uid())
          and me.removed_at is null
          and me.last_seen_at > now() - interval '90 seconds'
      )
    )
  order by ts.joined_at, ts.user_id;
$$;

comment on function public.get_table_spectators(uuid) is
  'Spectator seat (PRD item 40): the current spectators (not removed, seen in the last 90 s) of this table, oldest first, as (user_id, joined_at) -- for a caller seated there or currently watching it; zero rows for anyone else. Names and avatars come from profiles. See docs/sql/spectator-chat.sql.';

revoke all on function public.get_table_spectators(uuid) from public;
revoke all on function public.get_table_spectators(uuid) from anon;
revoke all on function public.get_table_spectators(uuid) from service_role;
grant execute on function public.get_table_spectators(uuid) to authenticated;

commit;
