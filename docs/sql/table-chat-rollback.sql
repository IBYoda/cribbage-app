-- Table chat, slice 1: removes everything docs/sql/table-chat.sql added --
-- the two policies on realtime.messages and the function
-- public.chat_topic_allows -- and nothing else. No table or row is touched
-- (table chat stores nothing).
-- STATUS: Kept for reference; not run.
-- Safe with the app live: once it has run, every private chat channel is
-- refused (no policy allows it), so a deployed chat would go quiet, but
-- nothing else changes. The policies go first, because they call the
-- function.

begin;
drop policy if exists "table chat: members receive" on realtime.messages;
drop policy if exists "table chat: members send" on realtime.messages;
drop function if exists public.chat_topic_allows(text, boolean);
commit;
