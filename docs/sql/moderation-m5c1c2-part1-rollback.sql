-- Moderation, slice M5c1 (c2): ROLLBACK of PART 1
-- (docs/sql/moderation-m5c1c2-part1.sql). Run in the Supabase Dashboard ->
-- SQL Editor. Kept here for reference/history; this project has no Supabase
-- CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- WHAT IT RESTORES, EXACTLY:
--   * public.chat_topic_allows(text, boolean): spectator-chat.sql's text,
--     byte for byte (body md5 LF 0458d5122d68d511b2e0fbceafe84aae -- the
--     body below is copied from that file), its comment, and its grants
--     (EXECUTE for authenticated only; none for PUBLIC, anon, service_role).
--   * the two policies on realtime.messages, as table-chat.sql wrote them:
--     "table chat: members receive" (SELECT) and "table chat: members send"
--     (INSERT), for authenticated, broadcast only, calling
--     chat_topic_allows(topic, false / true).
--   Client-callable functions go back to 61; policies on realtime.messages
--   to 4.
--
-- WHEN: only to bring the OLD per-sender chat path back. The live app (PR
-- #141) never uses it: it chats through send_table_message, which this
-- file does not touch. An old open tab could then chat again with other old
-- tabs only.
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD: neither policy and no function named chat_topic_allows exists
--      (part 1 ran); else it raises and changes nothing. Not re-runnable.
--   1. The function, its comment, its grants.
--   2. The two policies.
--
-- NOT TOUCHED: everything moderation-m5c1c2-part1.sql did not drop.

begin;

do $$
begin
  if exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages'
               and p.policyname in ('table chat: members receive', 'table chat: members send')) then
    raise exception 'STOP: a table-chat policy already exists (part 1 did not run, or this file already ran). Nothing was changed.';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
               where ns.nspname = 'public' and p.proname = 'chat_topic_allows') then
    raise exception 'STOP: a function named chat_topic_allows already exists. Nothing was changed.';
  end if;
  if to_regprocedure('public.table_topic_allows(text)') is null or to_regclass('public.table_spectators') is null then
    raise exception 'STOP: the tables and functions this restores against are missing. Nothing was changed.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. chat_topic_allows, exactly as spectator-chat.sql left it.
-- ---------------------------------------------------------------------------
create function public.chat_topic_allows(p_topic text, p_send boolean)
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
-- 2. The two policies, exactly as table-chat.sql wrote them.
-- ---------------------------------------------------------------------------
create policy "table chat: members receive"
  on realtime.messages
  for select
  to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and (select public.chat_topic_allows((select realtime.topic()), false))
  );

create policy "table chat: members send"
  on realtime.messages
  for insert
  to authenticated
  with check (
    realtime.messages.extension = 'broadcast'
    and (select public.chat_topic_allows((select realtime.topic()), true))
  );

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  (select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure('public.chat_topic_allows(text, boolean)')) = '0458d5122d68d511b2e0fbceafe84aae' as function_restored_exactly,
  has_function_privilege('authenticated', 'public.chat_topic_allows(text, boolean)', 'EXECUTE') as authenticated_may_execute,
  has_function_privilege('anon', 'public.chat_topic_allows(text, boolean)', 'EXECUTE') as anon_may_execute,
  (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages') as realtime_messages_policies;
