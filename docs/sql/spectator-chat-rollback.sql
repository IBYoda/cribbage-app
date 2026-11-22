-- Spectator chat, step 1: ROLLBACK of docs/sql/spectator-chat.sql.
-- Run in the Supabase Dashboard -> SQL Editor.
--
-- STATUS: written, NOT RUN yet. Kept for reference; run only if
-- spectator-chat.sql has to come out.
--
-- What it does, in one transaction:
--   1. puts chat_topic_allows back to the text table-chat.sql wrote (seated
--      players only; the body below is copied from table-chat.sql exactly,
--      so its md5 matches what spectator-chat-precheck.sql expects), with
--      the same grants and comment;
--   2. drops get_table_spectators.
-- The two policies on realtime.messages are not touched (spectator-chat.sql
-- never touched them).
--
-- SAFE WITH THE APP LIVE? Spectators lose chat at their next channel join
-- (their joins are refused again), and the app's get_table_spectators call
-- fails with "function does not exist": the spectator app half must treat
-- that as "no spectators listed" or be rolled back first. Seated players'
-- chat is unchanged either way.
--
-- AFTER IT: docs/sql/table-chat-verification.sql should still pass (68, or
-- 61 when its live-policy checks are skipped), exactly as on 2026-11-14.

begin;

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

revoke all on function public.chat_topic_allows(text, boolean) from public;
revoke all on function public.chat_topic_allows(text, boolean) from anon;
revoke all on function public.chat_topic_allows(text, boolean) from service_role;
grant execute on function public.chat_topic_allows(text, boolean) to authenticated;

drop function if exists public.get_table_spectators(uuid);

commit;
