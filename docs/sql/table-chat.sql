-- Table chat, slice 1: who may send and hear chat at a table.
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: RUN in production on 2026-11-14: "Success. No rows returned."
-- (after the precheck, which matched everything this file assumes). Its
-- verification passed the same day: ALL 68 CHECKS PASSED, none skipped.
--
-- RUN ORDER (as run on 2026-11-14):
--   1. docs/sql/table-chat-precheck.sql      (read-only)
--   2. docs/sql/table-chat.sql               (this file)
--   3. docs/sql/table-chat-verification.sql  (writes test rows, then rolls
--                                             them all back; its final
--                                             message is the verdict)
--   If it has to come out: docs/sql/table-chat-rollback.sql.
-- Needs, already live: slice-3-tables.sql (tables), slice-4-join-table.sql
-- (table_members), computer-c2-engine.sql (tables.computer_level), and
-- Supabase Realtime with Authorization (realtime.messages, realtime.topic()).
--
-- HOW CHAT WORKS (the design report; PRD item 39)
--   Chat is Supabase Realtime BROADCAST on PRIVATE channels. Each player
--   sends on a channel of their own, with the topic
--       chat:<table_id>:<sender_user_id>
--   (both ids lowercase, as Postgres and supabase-js print them), and
--   listens to every other player's channel at the table. A message goes
--   from the sender's browser through Realtime straight to the listeners.
--   NOTHING IS STORED: no table, no history, no realtime.send(), no
--   function that broadcasts. A player who opens the table later sees no
--   earlier messages.
--
--   On a PRIVATE channel Realtime asks Postgres, once as the player joins
--   (and again when their login token is refreshed), whether this player
--   may listen and whether they may send. It does that by running a select
--   (= may RECEIVE) and an insert (= may SEND) on realtime.messages, as the
--   player, with the channel's topic in realtime.topic(). The two policies
--   below answer those questions, and both ask ONE function,
--   chat_topic_allows(topic, send). Every rule lives in that function, so
--   spectators and a server-side mute can be added there later without
--   touching the policies.
--
-- WHAT THE REPO SAYS (checked on 2026-11-14; the precheck confirms it live)
--   * tables.status has exactly two values in the repo:
--       'open'   the table is live. This covers its WHOLE life on the table
--                screen: the waiting room, the cut, every hand of a game,
--                the game-over board ("won") and the next game after it.
--                A game's own phase is in public.games.status ('cutting',
--                'active', 'ended'), never in tables.status.
--       'ended'  the table is over: an admin Force-End (ended_reason
--                'admin'), the 12-hour timeout ('timeout'), or a computer
--                table its player left. The table page then shows "this
--                table has ended" instead of the table (app/tables/[code]/
--                page.tsx: tableRow.status !== "open"), so nobody is on the
--                table screen any more.
--     There is no 'waiting', 'playing' or 'closed' value anywhere in the repo
--     (tables.status has no check constraint, so the precheck lists what is
--     really there).
--   * public.table_members: table_id, user_id (primary key on the pair),
--     joined_at, score, last_points, last_reason, last_awarded_at, seat. No
--     "left" or "active" flag.
--   * A player who LEAVES is DELETED from table_members (leave_table, last
--     defined in phase2-slice-5-cut-before-deal.sql; leave_computer_table
--     deletes every seat). A game that ends, or a new game, leaves the seats
--     where they are. An admin Force-End and the timeout leave the seats too
--     but set the table to 'ended'.
--   * A COMPUTER table has tables.computer_level set ('easy' / 'medium' /
--     'hard'); a human table has null.
--
-- THE RULES (chat_topic_allows; every "no" is false, never an error)
--   1. The topic must match EXACTLY  chat:<uuid>:<uuid>  with lowercase hex
--      and nothing before or after. It is checked BEFORE any cast to uuid,
--      so a malformed topic can never raise an error.
--   2. Somebody must be signed in (auth.uid() not null).
--   3. To SEND, the sender id in the topic must be the caller: a player
--      sends only on their own channel, so nobody can speak as somebody
--      else.
--   4. The caller must be SEATED at that table (a table_members row), and
--      the table must be 'open' (CHOSEN: an 'ended' table is refused, since
--      nobody is on its screen) and a human table (computer_level null).
--      A player who left has no row, so they are refused.
--   5. To RECEIVE, that is all: any member may listen to any member's
--      channel at the same table. (The sender in the topic is not checked
--      to be seated: a channel nobody seated can send on is just silent.)
--
-- WHAT THIS FILE ADDS (and table-chat-rollback.sql removes exactly this):
--   1. FUNCTION public.chat_topic_allows(text, boolean): security definer
--      (it reads table_members and tables whatever the caller's own access
--      is), search_path empty with every name written in full, stable.
--      EXECUTE for authenticated only.
--   2. Two policies on realtime.messages, for authenticated, broadcast only:
--        "table chat: members receive"  (select)
--        "table chat: members send"     (insert)
--   No table is created, so the AGENTS.md "New tables" grants rule doesn't
--   apply. Nothing is added to the supabase_realtime publication.
--
-- RE-RUNNABLE: "create or replace" for the function, each policy dropped (if
-- it exists) before it is created, grants and revokes idempotent.


begin;

-- ---------------------------------------------------------------------------
-- 1. The one function every chat rule lives in.
-- ---------------------------------------------------------------------------
-- p_topic: the channel's topic, as realtime.topic() gives it.
-- p_send:  true for "may this player SEND here", false for "may they
--          RECEIVE here".
-- Returns true or false, never null, never an error.
--
-- plpgsql, not plain SQL, on purpose: its IF runs strictly in order, so the
-- pattern check is sure to happen before the ::uuid casts. (In one SQL
-- expression Postgres may evaluate the parts of an AND in any order.)
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

  -- Rule 3: send only on your own channel.
  -- (A server-side MUTE would be checked here too, for p_send only.)
  if p_send and v_sender_id <> v_caller then
    return false;
  end if;

  -- Rule 4 (and 5): seated at an open, human table.
  -- (SPECTATORS would be an "or" here, for p_send = false only.)
  return exists (
    select 1
    from public.table_members tm
    join public.tables t on t.id = tm.table_id
    where tm.table_id = v_table_id
      and tm.user_id = v_caller
      and t.status = 'open'
      and t.computer_level is null
  );
end;
$$;

comment on function public.chat_topic_allows(text, boolean) is
  'Table chat (PRD item 39): may the signed-in player send (p_send true) or receive (false) on the Realtime broadcast topic chat:<table_id>:<sender_user_id>? Used only by the two "table chat" policies on realtime.messages.';

-- Postgres lets PUBLIC execute a new function by default, and this project's
-- default privileges may hand it to anon and service_role too: take it from
-- all of them, then give it to authenticated only (the role the policies run
-- as).
revoke all on function public.chat_topic_allows(text, boolean) from public;
revoke all on function public.chat_topic_allows(text, boolean) from anon;
revoke all on function public.chat_topic_allows(text, boolean) from service_role;
grant execute on function public.chat_topic_allows(text, boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- 2. The two policies on realtime.messages.
-- ---------------------------------------------------------------------------
-- "to authenticated": anon has no policy, so anon can neither listen nor send
-- on a private channel. extension = 'broadcast': these say nothing about
-- Presence, which stays closed unless another policy opens it.
-- The (select ...) wrappers let Postgres work each call out once per
-- statement instead of once per row (Supabase's advice for RLS).
drop policy if exists "table chat: members receive" on realtime.messages;
create policy "table chat: members receive"
  on realtime.messages
  for select
  to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and (select public.chat_topic_allows((select realtime.topic()), false))
  );

drop policy if exists "table chat: members send" on realtime.messages;
create policy "table chat: members send"
  on realtime.messages
  for insert
  to authenticated
  with check (
    realtime.messages.extension = 'broadcast'
    and (select public.chat_topic_allows((select realtime.topic()), true))
  );

commit;
