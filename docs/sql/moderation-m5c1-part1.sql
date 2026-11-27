-- Moderation, slice M5 (c1): CHAT THROUGH THE SERVER -- send_table_message.
-- PART 1 (the only part): ADD-ONLY (safe before any app change). Run in the
-- Supabase Dashboard -> SQL Editor. Kept here for reference/history; this
-- project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M5c1):
--   1. docs/sql/moderation-m5c1-precheck.sql      (read-only; no STOP rows,
--      state "before part 1")
--   2. docs/sql/moderation-m5c1-part1.sql         (THIS FILE)
--   3. docs/sql/moderation-m5c1-verification.sql  ("ALL n CHECKS PASSED")
--   4. the suites to re-run (moderation-m5c1-precheck.sql's header)
--   5. the app (a later step, c2): send through this RPC, listen for 'chat'
--      on the table's topic; then the HARD CUT of the old chat:<t>:<sender>
--      channels.
--   Rollback: docs/sql/moderation-m5c1-part1-rollback.sql.
--
-- WHAT WALT DECIDED (M5c, 2026-11-26): Plan A -- chat goes through an RPC
-- that checks who may send, cleans the text, limits the rate ON THE SERVER,
-- sets the sender itself, and broadcasts on the table's private topic
-- table:<table_id> (M5a's topic and receive rule):
--   { event: 'chat', id, sender_id, text, at }
--     id         a new uuid per message (realtime.send KEEPS a payload's own
--                "id"; the stored row's id column is a separate uuid).
--     sender_id  auth.uid(), set here: the caller cannot choose it.
--     text       cleaned exactly as the app's cleanChatText (lib/tableChat.ts).
--     at         the send time, whole milliseconds since the epoch.
-- Open human tables only; no history (nothing kept beyond Realtime's own
-- copies, which it drops after a few days); messages sent before a kick
-- still show.
--
-- send_table_message(p_table_id uuid, p_text text) returns jsonb {id, at}
--   SECURITY DEFINER, search_path '', TimeZone 'UTC' (realtime.messages'
--   inserted_at is compared with now(); one fixed zone for every sender).
--   EXECUTE for authenticated only.
--   THE CHECKS, IN THIS ORDER (each refusal raises; nothing is stored):
--     1. signed in                                         NBC01
--     2. not a computer account (public.computer_accounts) NBC02
--     3. seated at an OPEN HUMAN table, or a CURRENT spectator of an open
--        human table that allows spectators (not removed, seen within 90 s
--        by the server's clock) -- chat_topic_allows' rules 4-6, written
--        out here (chat_topic_allows itself is not called or changed)
--                                                          NBC02
--     4. not kicked from that table (_is_kicked_from_table) NBC02
--     5. the text, cleaned (below); nothing left           NBC03
--     6. THE RATE LIMIT, per sender per table: at most 1 message in any
--        2 seconds and 3 in any 10 (the app's CHAT_LIMITS: a message
--        exactly 2 s or 10 s old no longer counts)          NBC04
--     7. the send, then the READ-BACK of the stored row    NBC05
--   THE ERRORS (SQLSTATE, message), for the app to show:
--     NBC01  You must be logged in to chat.
--     NBC02  You can't chat at this table.
--     NBC03  Type a message first.
--     NBC04  Slow down: you're sending messages too fast.   ("too fast")
--     NBC05  Couldn't send. Please try again.               ("could not send")
--   anon gets 42501 (no EXECUTE), before any of the above.
--
-- THE TEXT: exactly cleanChatText -- every run of line breaks (with the
-- spaces around it) becomes one space; C0/C1 controls (tab included) and the
-- bidi overrides and isolates are removed; trimmed; cut to 140 characters
-- (code points); trimmed again. "Space" and "trim" mean JavaScript's \s set,
-- spelled out with chr() (so no regex class depends on the server's
-- locale). The input is first cut to 4000 characters (the app's box takes
-- 140): only a text whose first 4000 characters clean down to fewer than
-- 140 could differ from the app's, and the app never sends one.
--
-- THE RATE LIMIT is counted in realtime.messages itself (no table of our
-- own): a per-sender, per-table advisory lock (pg_advisory_xact_lock, held
-- to the end of the call, so two simultaneous sends run one after the other
-- and the second sees the first), then a count of this sender's 'chat' rows
-- on this topic in the last 10 seconds. Walt's plan (2026-11-26): each daily
-- partition has a PARTIAL index on (topic, inserted_at DESC,
-- COALESCE(expires_at, 'infinity')) WHERE extension = 'broadcast' AND
-- private = true; the count states exactly those, so it is an index scan of
-- this topic's last 10 seconds (6 buffers, 1.4 ms) with the old partitions
-- pruned; sender_id is filtered from those few rows. FAIL CLOSED: any error
-- from the count refuses the send (NBC05). A missing partition does not
-- make the count fail (it finds nothing); it makes the store fail, which
-- the read-back catches.
--
-- THE SEND: realtime.send(payload, 'chat', 'table:<id>', true) through
-- _broadcast_table_message. realtime.send NEVER raises: its insert sits
-- inside BEGIN ... EXCEPTION WHEN OTHERS THEN RAISE WARNING, so a failed
-- store (no partition for the day, ...) is only a warning. So after it, the
-- stored row is READ BACK (same topic, broadcast, private, the last 10
-- seconds, payload->>'id' = this message's id; a row is visible inside its
-- own transaction). Missing -> NBC05, and the whole call rolls back. A
-- stored row is broadcast only when the call commits.
--
-- _broadcast_table_message(p_topic text, p_payload jsonb) void
--   Internal: realtime.send(p_payload, 'chat', p_topic, true), nothing
--   else. A separate function only so the verification can replace it with
--   one that stores nothing (as a failed realtime.send does) and prove the
--   caller gets NBC05. Its name has no "chat" in it on purpose:
--   table-chat-verification.sql C4 allows no public function with "chat" in
--   its name besides chat_topic_allows (send_table_message has none either).
--   SECURITY DEFINER, search_path ''; no client role can execute it.
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold): M5a part 1 is in
--      (table_topic_allows and the table events policy: the receive rule);
--      M3 part 1 is in (_is_kicked_from_table); public.computer_accounts,
--      chat_topic_allows and realtime.send exist; realtime.messages has the
--      columns the count reads; neither function name exists. NOT
--      RE-RUNNABLE BY DESIGN: a second run STOPs at the guard.
--   1. The two functions, their comments and grants.
--
-- md5 of the new bodies (carriage returns removed; LF), and with CRLF line
-- ends (this file as committed):
--   _broadcast_table_message  e5f16aebb3ca764c806e2567b68090fc / 7291285ed02d17883fc4666240d9fcb7
--   send_table_message        e3adcc4874c77c1c47530a807fefd815 / 4aa16cd9a55ad50a7759b73c6f5c9a97
--
-- NOT TOUCHED: every existing function body (no fingerprint changes:
-- chat_topic_allows, the eight _as bodies and wrappers, the four
-- end-empty-tables bodies, kick_player, _is_kicked_from_table, M5a's five,
-- M5b1's three, M5b2's two), every policy (the two old chat policies
-- included: no new policy -- nobody may insert on table: topics), every
-- trigger and table, the tables row (nothing here writes it), the
-- supabase_realtime publication. No table is created, so the AGENTS.md "New
-- tables" grants rule does not apply. Client-callable functions: 60 -> 61.
--
-- ROLLBACK: docs/sql/moderation-m5c1-part1-rollback.sql.

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard.
-- ---------------------------------------------------------------------------
do $$
declare
  v_txt text;
begin
  if to_regprocedure('public.table_topic_allows(text)') is null
     or not exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages'
                      and p.policyname = 'table events: people at the table receive') then
    raise exception 'STOP: moderation M5a part 1 is not in (table_topic_allows, the table events policy). Nothing was changed.';
  end if;
  if to_regprocedure('public._is_kicked_from_table(uuid, uuid)') is null then
    raise exception 'STOP: moderation M3 part 1 is not in (_is_kicked_from_table). Nothing was changed.';
  end if;
  if to_regclass('public.computer_accounts') is null
     or to_regprocedure('public.chat_topic_allows(text, boolean)') is null then
    raise exception 'STOP: public.computer_accounts or chat_topic_allows is missing. Nothing was changed.';
  end if;
  if to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null then
    raise exception 'STOP: realtime.send(jsonb, text, text, boolean) does not exist. Nothing was changed.';
  end if;
  select string_agg(c.col, ', ') into v_txt
  from unnest(array['topic', 'extension', 'private', 'inserted_at', 'payload']) as c(col)
  where not exists (select 1 from pg_attribute a
                    where a.attrelid = to_regclass('realtime.messages') and a.attname = c.col
                      and a.attnum > 0 and not a.attisdropped);
  if v_txt is not null then
    raise exception 'STOP: realtime.messages lacks the column(s) %. Nothing was changed.', v_txt;
  end if;

  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname) into v_txt
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('send_table_message', '_broadcast_table_message');
  if v_txt is not null then
    raise exception 'STOP: these functions already exist: %. This file already ran? Nothing was changed.', v_txt;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The functions.
-- ---------------------------------------------------------------------------
create or replace function public._broadcast_table_message(p_topic text, p_payload jsonb)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  -- A private Realtime broadcast, event 'chat'. realtime.send never raises
  -- (a failed store is only a warning): send_table_message reads the row back.
  perform realtime.send(p_payload, 'chat', p_topic, true);
end;
$$;

comment on function public._broadcast_table_message(text, jsonb) is
  'Internal (moderation M5c1): realtime.send(payload, ''chat'', topic, true), nothing else. Called only by send_table_message, which reads the stored row back (realtime.send never raises). No client role can execute it. See docs/sql/moderation-m5c1-part1.sql.';

revoke all on function public._broadcast_table_message(text, jsonb) from public;
revoke all on function public._broadcast_table_message(text, jsonb) from anon;
revoke all on function public._broadcast_table_message(text, jsonb) from authenticated;
revoke all on function public._broadcast_table_message(text, jsonb) from service_role;


create or replace function public.send_table_message(p_table_id uuid, p_text text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
set timezone = 'UTC'
as $$
declare
  v_caller uuid := auth.uid();
  -- JavaScript's \s, spelled out: horizontal space (tab, vertical tab, form
  -- feed, space, no-break space, ogham space, U+2000-U+200A, narrow no-break
  -- space, medium math space, ideographic space, byte order mark) ...
  v_hsp text := chr(9) || chr(11) || chr(12) || chr(32) || chr(160) || chr(5760)
                || chr(8192) || '-' || chr(8202) || chr(8239) || chr(8287) || chr(12288) || chr(65279);
  -- ... and the line breaks (LF, CR, line separator, paragraph separator).
  v_brk text := chr(10) || chr(13) || chr(8232) || chr(8233);
  -- Removed: C0 and C1 controls, the bidi overrides and isolates.
  v_bad text := chr(1) || '-' || chr(31) || chr(127) || '-' || chr(159)
                || chr(8234) || '-' || chr(8238) || chr(8294) || '-' || chr(8297);
  -- Trimmed: the whole \s set, one character each.
  v_trim text := chr(9) || chr(10) || chr(11) || chr(12) || chr(13) || chr(32) || chr(160) || chr(5760)
                 || chr(8192) || chr(8193) || chr(8194) || chr(8195) || chr(8196) || chr(8197)
                 || chr(8198) || chr(8199) || chr(8200) || chr(8201) || chr(8202)
                 || chr(8232) || chr(8233) || chr(8239) || chr(8287) || chr(12288) || chr(65279);
  v_topic text;
  v_text text;
  v_recent2 integer;
  v_recent10 integer;
  v_id uuid;
  v_at bigint;
  v_stored boolean;
begin
  -- 1. Signed in.
  if v_caller is null then
    raise exception 'You must be logged in to chat.' using errcode = 'NBC01';
  end if;

  -- 2. Never a computer account.
  if exists (select 1 from public.computer_accounts ca where ca.user_id = v_caller) then
    raise exception 'You can''t chat at this table.' using errcode = 'NBC02';
  end if;

  -- 3. At the table (chat_topic_allows' rules 4-6): seated at an open human
  -- table, or a current spectator of an open human table that allows
  -- spectators.
  if p_table_id is null
     or not (
       exists (
         select 1
         from public.table_members tm
         join public.tables t on t.id = tm.table_id
         where tm.table_id = p_table_id
           and tm.user_id = v_caller
           and t.status = 'open'
           and t.computer_level is null)
       or exists (
         select 1
         from public.table_spectators ts
         join public.tables t on t.id = ts.table_id
         where ts.table_id = p_table_id
           and ts.user_id = v_caller
           and ts.removed_at is null
           and ts.last_seen_at > now() - interval '90 seconds'
           and t.status = 'open'
           and t.computer_level is null
           and t.allow_spectators is true)) then
    raise exception 'You can''t chat at this table.' using errcode = 'NBC02';
  end if;

  -- 4. Never someone kicked from this table.
  if public._is_kicked_from_table(v_caller, p_table_id) then
    raise exception 'You can''t chat at this table.' using errcode = 'NBC02';
  end if;

  -- 5. The text, exactly as the app's cleanChatText.
  v_text := pg_catalog.left(p_text, 4000);
  v_text := pg_catalog.regexp_replace(v_text, '[' || v_hsp || ']*[' || v_brk || ']+[' || v_hsp || v_brk || ']*', ' ', 'g');
  v_text := pg_catalog.regexp_replace(v_text, '[' || v_bad || ']', '', 'g');
  v_text := pg_catalog.btrim(v_text, v_trim);
  v_text := pg_catalog.btrim(pg_catalog.left(v_text, 140), v_trim);
  if v_text is null or v_text = '' then
    raise exception 'Type a message first.' using errcode = 'NBC03';
  end if;

  -- 6. The rate limit: this sender's lock for this table, then the count.
  v_topic := 'table:' || p_table_id::text;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('send_table_message:' || p_table_id::text || ':' || v_caller::text, 0));
  begin
    select count(*) filter (where m.inserted_at > now() - interval '2 seconds'),
           count(*)
    into v_recent2, v_recent10
    from realtime.messages m
    where m.extension = 'broadcast'
      and m.private = true
      and m.topic = v_topic
      and m.inserted_at > now() - interval '10 seconds'
      and m.payload ->> 'event' = 'chat'
      and m.payload ->> 'sender_id' = v_caller::text;
  exception when others then
    -- Fail closed: no count, no send.
    raise exception 'Couldn''t send. Please try again.' using errcode = 'NBC05';
  end;
  if v_recent2 > 0 or v_recent10 >= 3 then
    raise exception 'Slow down: you''re sending messages too fast.' using errcode = 'NBC04';
  end if;

  -- 7. The send, then the read-back (realtime.send never raises).
  v_id := pg_catalog.gen_random_uuid();
  v_at := pg_catalog.floor(extract(epoch from now()) * 1000)::bigint;
  begin
    perform public._broadcast_table_message(v_topic, pg_catalog.jsonb_build_object(
      'event', 'chat',
      'id', v_id,
      'sender_id', v_caller,
      'text', v_text,
      'at', v_at));
  exception when others then
    raise exception 'Couldn''t send. Please try again.' using errcode = 'NBC05';
  end;
  begin
    select exists (
      select 1
      from realtime.messages m
      where m.extension = 'broadcast'
        and m.private = true
        and m.topic = v_topic
        and m.inserted_at > now() - interval '10 seconds'
        and m.payload ->> 'id' = v_id::text)
    into v_stored;
  exception when others then
    v_stored := false;
  end;
  if v_stored is not true then
    raise exception 'Couldn''t send. Please try again.' using errcode = 'NBC05';
  end if;

  return pg_catalog.jsonb_build_object('id', v_id, 'at', v_at);
end;
$$;

comment on function public.send_table_message(uuid, text) is
  'Moderation M5c1: the signed-in person sends a chat message to table p_table_id. Checks, in order: signed in (NBC01); not a computer account, seated at an open human table or a current spectator of one that allows spectators, not kicked (NBC02); the text cleaned as the app''s cleanChatText, at most 140 characters, empty refused (NBC03); at most 1 message in 2 s and 3 in 10 s per sender per table, counted in realtime.messages under a per-sender lock (NBC04). Broadcasts {event: chat, id, sender_id (the caller), text, at (ms)} on table:<table_id> (private) and reads the stored row back (NBC05 when it is missing). Returns {id, at}. Writes no table. See docs/sql/moderation-m5c1-part1.sql.';

revoke all on function public.send_table_message(uuid, text) from public;
revoke all on function public.send_table_message(uuid, text) from anon;
revoke all on function public.send_table_message(uuid, text) from service_role;
revoke all on function public.send_table_message(uuid, text) from authenticated;
grant execute on function public.send_table_message(uuid, text) to authenticated;

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  has_function_privilege('authenticated', 'public.send_table_message(uuid, text)', 'EXECUTE') as send_for_authenticated,
  has_function_privilege('anon', 'public.send_table_message(uuid, text)', 'EXECUTE') as send_for_anon,
  has_function_privilege('authenticated', 'public._broadcast_table_message(text, jsonb)', 'EXECUTE') as helper_for_authenticated,
  (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages') as realtime_messages_policies;
