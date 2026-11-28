-- Moderation, slice M7: CHAT ATTACHED TO BEHAVIOR REPORTS. PART 1 (the only
-- part). Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: RUN 2026-11-28. Result row: 4 chat columns, 2 constraints,
-- report_player md5 2dd85cea07caa56de74f5bfdef7d3b07, 61 callable.
-- Regression after part 1: slice-e-grants 12, moderation-m6 24, m5c1c2 8, catalog 61 callable (the three known stale rows unchanged).
--
-- DEPLOY ORDER (slice M7):
--   1. docs/sql/moderation-m7-precheck.sql       (read-only; no STOP rows,
--      state "before part 1")
--   2. docs/sql/moderation-m7-part1.sql          (THIS FILE)
--   3. docs/sql/moderation-m7-verification.sql   ("ALL n CHECKS PASSED")
--      and docs/sql/slice-e-grants-verification.sql (61 names)
--   4. the regression suites (moderation-m7-precheck.sql's header)
--   5. the app (a later step): the admin page's "View chat" (calls
--      admin_report_chat) and the report dialog's note. The app needs NO
--      change to keep filing reports: report_player keeps its arguments and
--      its answers.
--   Rollback: docs/sql/moderation-m7-part1-rollback.sql.
--
-- WHAT WALT DECIDED (M7, 2026-11-28): no new report reason. Every
-- "behavior" report copies the chat still stored for the table it was
-- reported from (Realtime keeps about 3 to 4 days) into the report; nickname
-- and picture reports get none. The copy keeps the most recent 2,000
-- messages and at most 200 KB of message text, whichever comes first,
-- dropping the oldest, and records how many were found (chat_total) and
-- kept (chat_kept). It is made only when the reporter is seated at, or a
-- current spectator of, that table (send_table_message's rule 3, without
-- needing the table open); otherwise the report is filed with chat_status
-- 'not_at_table'. The reported person may have left: that never matters.
-- FAIL OPEN: if the copy fails, the report is still filed, with
-- chat_status 'unavailable'. Admins read one report's chat through
-- admin_report_chat; the list (admin_list_reports) shows only its status
-- and count. The copy lives in the report's row, so the existing 90-day
-- purge and admin_delete_report remove it with the report.
--
-- THE COPY (_report_table_chat, below), from realtime.messages:
--   extension = 'broadcast', private = true, topic = 'table:<table_id>',
--   payload->>'event' = 'chat', inserted_at in the last 5 days (inserted_at
--   is a timestamp WITHOUT time zone that Realtime stamps in UTC, so the
--   helper runs with TimeZone 'UTC', as send_table_message does). Only rows
--   shaped as send_table_message writes them count: sender_id a lowercase
--   uuid, "at" whole milliseconds, text a string of 1 to 140 characters
--   (anything else is skipped and not counted). Order and display use the
--   payload's "at" (then inserted_at, then the payload's id), never the
--   row's own columns beyond the five send_table_message already reads.
--   THE CAP: newest first, a message is kept while it is among the newest
--   2,000 AND the running total of its text and every newer kept message's
--   text is at most 204,800 bytes (200 KB, octet_length of the UTF-8 text).
--   The kept messages are always the newest ones, oldest dropped.
--   chat = {people: {<sender id>: <nickname now, at filing; null when the
--   account is gone>}, lines: [{s: <sender id>, at: <ms>, text}]}, oldest
--   first. people has only the senders of kept lines. The reported person is
--   the report's reported_id (not stored again).
--
-- chat_status, chat_total, chat_kept, chat (one constraint keeps them
-- consistent):
--   null           nickname and picture reports, and every report filed
--                  before M7: all four null.
--   copied         chat found and copied: chat set, chat_kept 1..2000,
--                  chat_total >= chat_kept.
--   none           the reporter is at the table but no chat is stored:
--                  chat null, chat_total 0, chat_kept 0.
--   not_at_table   no table, or the reporter is neither seated at it nor a
--                  current spectator: the other three null.
--   unavailable    the copy failed (FAIL OPEN): the other three null.
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold): public.player_reports
--      has exactly M6's columns (no chat columns yet); report_player and
--      admin_list_reports have M6 part 1's bodies; send_table_message has
--      M5c1 part 1's body (the payload this copies); neither new function
--      name exists; report_player, send_table_message and the role running
--      this file are the same role, and it may SELECT realtime.messages
--      (send_table_message already reads it that way on every send);
--      realtime.messages has the five columns read; table_members and
--      table_spectators (removed_at, last_seen_at) exist. NOT RE-RUNNABLE BY
--      DESIGN: a second run STOPs at the guard (the columns are there).
--   1. public.player_reports: four new columns (chat jsonb, chat_status
--      text, chat_total integer, chat_kept integer), all null for existing
--      rows, two check constraints, column and table comments. No new
--      table, no foreign key, no index, no grant: the table's privileges
--      and policies are untouched (still none for any client role).
--   2. Functions, all SECURITY DEFINER with search_path '':
--        _report_table_chat(p_table_id uuid, out o_total integer,
--                           out o_kept integer, out o_chat jsonb)
--          NEW, INTERNAL (no client role): the copy above. TimeZone 'UTC'.
--          A separate function so the copy has one home and the
--          verification can replace it with one that raises (proving FAIL
--          OPEN), as moderation M5c1 did with _broadcast_table_message.
--        report_player(p_target, p_reason, p_note, p_table_id) text
--          REPLACED: M6 part 1's body byte for byte plus ONE block, between
--          "-- ==== (M7) CHAT COPY" and "-- ==== end (M7) ====", placed after
--          the insert and before "return 'reported'". Same arguments, same
--          answers, same limits in the same order; every refusal returns
--          before the block, so a refused report copies nothing. Owner,
--          grants and settings unchanged (CREATE OR REPLACE keeps them).
--        admin_list_reports(p_limit integer) table
--          DROPPED AND RECREATED (its result gains two columns at the end:
--          chat_status text, chat_total integer; never the chat itself).
--          M6's body plus those two select items; same grants (EXECUTE for
--          authenticated only).
--        admin_report_chat(p_id uuid) table (chat_status, chat_total,
--                          chat_kept, chat)
--          NEW, admins only ("Admins only." for anyone else): that one
--          report's chat; no row for an unknown id. EXECUTE for
--          authenticated only. Client-callable functions: 60 -> 61.
--
-- md5 of the new bodies (carriage returns removed; LF), and with CRLF line
-- ends (this file as committed):
--   _report_table_chat   ac6d3541b82212f87572fc729bf87359 / f05f82a4518714fbada5e0a32d06ccad
--   report_player        2dd85cea07caa56de74f5bfdef7d3b07 / c008229bedb7a64b3d52ebd646e7dc75
--   admin_list_reports   05e0e3809b944590a850ddc8ce259570 / c447d997303cff89d5846bf473e6425e
--   admin_report_chat    0c872a9e8da827c0b4289c9179d2dc3f / ae5da7f0fcba3c8567507f2a9e4372ea
--
-- NOT TOUCHED: _report_avatar_object, admin_delete_report,
-- purge_old_reports, the report-purge cron job, send_table_message and
-- _broadcast_table_message, attempt_log (no new action: a report is still
-- counted once, as report_filed), every policy, every other function body,
-- the supabase_realtime publication. Nothing here writes to
-- realtime.messages.
--
-- ROLLBACK: docs/sql/moderation-m7-part1-rollback.sql (ONE-WAY for the
-- data: every copied chat is deleted with the columns; the reports stay).

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard.
-- ---------------------------------------------------------------------------
do $$
declare
  v_txt text;
  v_owner text;
begin
  -- public.player_reports: exactly M6's columns (chat columns already there
  -- means this file ran: STOP).
  select string_agg(a.attname::text || ' ' || format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else '' end, ', ' order by a.attnum)
  into v_txt
  from pg_attribute a
  where a.attrelid = to_regclass('public.player_reports') and a.attnum > 0 and not a.attisdropped;
  if v_txt is distinct from 'id uuid not null, created_at timestamp with time zone not null, reporter_id uuid not null, reported_id uuid not null, reason text not null, note text, table_id uuid, reporter_nickname text, reported_nickname text, reported_avatar_url text, avatar_object_updated_at timestamp with time zone, avatar_object_size bigint' then
    raise exception 'STOP: public.player_reports has columns "%"; expected exactly M6 part 1''s (chat columns there means this file already ran). Nothing was changed.', coalesce(v_txt, 'missing');
  end if;

  -- The bodies this file replaces or relies on (LF; carriage returns removed).
  select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure('public.report_player(uuid, text, text, uuid)');
  if v_txt is distinct from 'cbbe554a4e170379f8c6b7ac88b1cecc' then
    raise exception 'STOP: public.report_player has body md5 % (LF); expected M6 part 1''s cbbe554a4e170379f8c6b7ac88b1cecc. Capture it first: select pg_get_functiondef(''public.report_player(uuid, text, text, uuid)''::regprocedure); Nothing was changed.', coalesce(v_txt, 'missing');
  end if;
  select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure('public.admin_list_reports(integer)');
  if v_txt is distinct from 'b2bcdc0cd74f7453e964ec3bc31c6998' then
    raise exception 'STOP: public.admin_list_reports has body md5 % (LF); expected M6 part 1''s b2bcdc0cd74f7453e964ec3bc31c6998. Nothing was changed.', coalesce(v_txt, 'missing');
  end if;
  select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure('public.send_table_message(uuid, text)');
  if v_txt is distinct from 'e3adcc4874c77c1c47530a807fefd815' then
    raise exception 'STOP: public.send_table_message has body md5 % (LF); expected moderation M5c1 part 1''s e3adcc4874c77c1c47530a807fefd815 (the chat payload this file copies). Nothing was changed.', coalesce(v_txt, 'missing');
  end if;

  -- One admin_list_reports only (it is dropped by its signature below).
  select string_agg(p.oid::regprocedure::text, ', ') into v_txt
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'admin_list_reports' and p.oid <> to_regprocedure('public.admin_list_reports(integer)');
  if v_txt is not null then
    raise exception 'STOP: another admin_list_reports exists: %. Nothing was changed.', v_txt;
  end if;

  -- Neither new name exists, with any signature.
  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname) into v_txt
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname in ('_report_table_chat', 'admin_report_chat');
  if v_txt is not null then
    raise exception 'STOP: these functions already exist: %. This file already ran, or the names are taken. Nothing was changed.', v_txt;
  end if;

  -- One owner: report_player's, send_table_message's and this session's
  -- role (the new helper must read realtime.messages exactly as
  -- send_table_message does).
  select pg_get_userbyid(p.proowner) into v_owner from pg_proc p where p.oid = to_regprocedure('public.report_player(uuid, text, text, uuid)');
  select pg_get_userbyid(p.proowner) into v_txt from pg_proc p where p.oid = to_regprocedure('public.send_table_message(uuid, text)');
  if v_owner is distinct from v_txt or v_owner is distinct from current_user then
    raise exception 'STOP: report_player is owned by %, send_table_message by %, and this session runs as %; all three must be the same role. Nothing was changed.', coalesce(v_owner, '?'), coalesce(v_txt, '?'), current_user;
  end if;

  -- realtime.messages: the five columns read, and SELECT for this role.
  if to_regclass('realtime.messages') is null then
    raise exception 'STOP: realtime.messages does not exist. Nothing was changed.';
  end if;
  select string_agg(c.col, ', ') into v_txt
  from unnest(array['topic', 'extension', 'private', 'inserted_at', 'payload']) as c(col)
  where not exists (select 1 from pg_attribute a
                    where a.attrelid = to_regclass('realtime.messages') and a.attname = c.col
                      and a.attnum > 0 and not a.attisdropped);
  if v_txt is not null then
    raise exception 'STOP: realtime.messages lacks the column(s) %. Nothing was changed.', v_txt;
  end if;
  if not has_table_privilege(current_user, to_regclass('realtime.messages'), 'SELECT') then
    raise exception 'STOP: % may not SELECT realtime.messages. Nothing was changed.', current_user;
  end if;

  -- Where the reporter must be.
  if to_regclass('public.table_members') is null
     or to_regclass('public.table_spectators') is null
     or not exists (select 1 from pg_attribute a where a.attrelid = to_regclass('public.table_spectators') and a.attname = 'removed_at' and not a.attisdropped)
     or not exists (select 1 from pg_attribute a where a.attrelid = to_regclass('public.table_spectators') and a.attname = 'last_seen_at' and not a.attisdropped) then
    raise exception 'STOP: public.table_members, public.table_spectators or its removed_at / last_seen_at is missing. Nothing was changed.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. public.player_reports: the chat columns (an existing table: its RLS,
--    revokes and the absence of any grant or policy stay exactly as M6 part 1
--    left them; adding columns grants nothing).
-- ---------------------------------------------------------------------------
alter table public.player_reports
  add column chat jsonb,
  add column chat_status text,
  add column chat_total integer,
  add column chat_kept integer;

alter table public.player_reports
  add constraint player_reports_chat_status_check
  check (chat_status is null or chat_status in ('copied', 'none', 'not_at_table', 'unavailable'));

alter table public.player_reports
  add constraint player_reports_chat_check
  check (
    (chat_status is null and chat is null and chat_total is null and chat_kept is null)
    or (chat_status = 'copied' and reason = 'behavior' and chat is not null and jsonb_typeof(chat) = 'object'
        and chat_kept between 1 and 2000 and chat_total >= chat_kept)
    or (chat_status = 'none' and reason = 'behavior' and chat is null and chat_total = 0 and chat_kept = 0)
    or (chat_status in ('not_at_table', 'unavailable') and reason = 'behavior'
        and chat is null and chat_total is null and chat_kept is null)
  );

comment on column public.player_reports.chat is
  'Moderation M7: for a behavior report, the copy of the table''s chat taken at filing: {people: {<sender id>: <nickname at filing, null if the account is gone>}, lines: [{s: <sender id>, at: <ms>, text}]}, oldest first; the newest 2,000 messages and at most 204,800 bytes of text. Null otherwise. Read by admins through admin_report_chat.';
comment on column public.player_reports.chat_status is
  'Moderation M7: copied, none (the reporter was at the table, no chat stored), not_at_table (no table, or the reporter was neither seated nor a current spectator), unavailable (the copy failed; the report was filed anyway). Null for nickname and picture reports and for reports filed before M7.';
comment on column public.player_reports.chat_total is
  'Moderation M7: how many chat messages were stored for the table at filing (copied: at least chat_kept; none: 0; otherwise null).';
comment on column public.player_reports.chat_kept is
  'Moderation M7: how many of them were copied into chat (at most 2,000; the oldest are dropped first).';

comment on table public.player_reports is
  'Moderation M6 and M7: one row per report filed by a player about another (reason nickname, picture or behavior; an optional note of up to 200 characters), with the server''s snapshot at filing time (both nicknames, the reported avatar_url and its storage object''s date and size) and, for a behavior report, a copy of the table''s chat (chat, chat_status, chat_total, chat_kept; see the column comments). Nothing happens to the reported person automatically; reports are never broadcast. NO foreign keys, deliberately: a report outlives both accounts and the table. Deleted 90 days after filing (purge_old_reports, pg_cron job report-purge) or earlier by an admin (admin_delete_report), the chat with it. PRIVATE: no client role has any privilege on it and RLS is on with no policies; written only by report_player, read by admins through admin_list_reports and admin_report_chat (security definer). See docs/sql/moderation-m6-part1.sql and moderation-m7-part1.sql.';

-- ---------------------------------------------------------------------------
-- 2. The functions.
-- ---------------------------------------------------------------------------
create or replace function public._report_table_chat(
  p_table_id uuid,
  out o_total integer,
  out o_kept integer,
  out o_chat jsonb
)
language plpgsql
stable
security definer
set search_path = ''
set timezone = 'UTC'
as $$
begin
  -- Nothing found: 0, 0, null.
  o_total := 0;
  o_kept := 0;
  o_chat := null;
  if p_table_id is null then
    return;
  end if;

  -- The table's chat as send_table_message stores it (the predicates its
  -- per-partition index covers, plus the last 5 days), newest first; kept
  -- while among the newest 2,000 and within 204,800 bytes of text in all.
  with found as (
    select m.payload ->> 'sender_id' as s,
           (m.payload ->> 'at')::bigint as at,
           m.payload ->> 'text' as txt,
           coalesce(m.payload ->> 'id', '') as mid,
           m.inserted_at
    from realtime.messages m
    where m.extension = 'broadcast'
      and m.private = true
      and m.topic = 'table:' || p_table_id::text
      and m.inserted_at > now() - interval '5 days'
      and m.payload ->> 'event' = 'chat'
      and (m.payload ->> 'sender_id') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      and (m.payload ->> 'at') ~ '^[0-9]{1,15}$'
      and pg_catalog.jsonb_typeof(m.payload -> 'text') = 'string'
      and pg_catalog.char_length(m.payload ->> 'text') between 1 and 140
  ),
  ranked as (
    select f.s, f.at, f.txt, f.mid, f.inserted_at,
           pg_catalog.row_number() over (order by f.at desc, f.inserted_at desc, f.mid desc) as rn,
           pg_catalog.sum(pg_catalog.octet_length(f.txt)) over (order by f.at desc, f.inserted_at desc, f.mid desc
                                                                rows between unbounded preceding and current row) as bytes
    from found f
  ),
  kept as (
    select r.s, r.at, r.txt, r.mid, r.inserted_at
    from ranked r
    where r.rn <= 2000
      and r.bytes <= 204800
  )
  select (select pg_catalog.count(*) from found)::integer,
         (select pg_catalog.count(*) from kept)::integer,
         case when exists (select 1 from kept) then
           pg_catalog.jsonb_build_object(
             'people', (select pg_catalog.jsonb_object_agg(d.s, p.nickname)
                        from (select distinct k.s from kept k) d
                        left join public.profiles p on p.id = d.s::uuid),
             'lines', (select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('s', k.s, 'at', k.at, 'text', k.txt)
                                                   order by k.at, k.inserted_at, k.mid)
                       from kept k))
         end
  into o_total, o_kept, o_chat;
end;
$$;

comment on function public._report_table_chat(uuid) is
  'Internal (moderation M7): the chat still stored in realtime.messages for table p_table_id (topic table:<id>, broadcast, private, event chat, the last 5 days, shaped as send_table_message writes it): o_total found, o_kept copied (the newest 2,000 and at most 204,800 bytes of text, oldest dropped), o_chat = {people: {<sender id>: <nickname now>}, lines: [{s, at, text}]} oldest first (null when nothing was found). TimeZone UTC (inserted_at has no time zone). Called only by report_player, inside its fail-open block. No client role can execute it. See docs/sql/moderation-m7-part1.sql.';

revoke all on function public._report_table_chat(uuid) from public;
revoke all on function public._report_table_chat(uuid) from anon;
revoke all on function public._report_table_chat(uuid) from authenticated;
revoke all on function public._report_table_chat(uuid) from service_role;


create or replace function public.report_player(
  p_target uuid,
  p_reason text,
  p_note text default null,
  p_table_id uuid default null
)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  -- Control characters (C0, DEL, C1) and invisible formatting characters
  -- (zero-width, line/paragraph separators, bidi embeddings, overrides and
  -- isolates, word joiner, byte order mark), as one bracket expression.
  -- Built with chr() so no backslash escape depends on server settings.
  v_bad_chars text := '[' || chr(1) || '-' || chr(31) || chr(127) || '-' || chr(159)
                      || chr(8203) || '-' || chr(8207) || chr(8232) || '-' || chr(8238)
                      || chr(8288) || '-' || chr(8297) || chr(65279) || ']';
  v_note text;
  v_table_id uuid;
  v_hour integer;
  v_day integer;
  v_reporter_nickname text;
  v_nickname text;
  v_avatar_url text;
  v_obj_updated_at timestamptz;
  v_obj_size bigint;
begin
  if v_actor is null then
    raise exception 'You must be logged in to report a player.';
  end if;

  if p_reason is null or p_reason not in ('nickname', 'picture', 'behavior') then
    raise exception 'Unknown report reason.';
  end if;

  if p_target is null then
    return 'not_found';
  end if;

  -- Never yourself; never by or about a computer account.
  if p_target = v_actor
     or exists (select 1 from public.computer_accounts ca where ca.user_id = v_actor) then
    return 'not_allowed';
  end if;

  if not exists (select 1 from public.profiles p where p.id = p_target) then
    return 'not_found';
  end if;

  if exists (select 1 from public.computer_accounts ca where ca.user_id = p_target) then
    return 'not_allowed';
  end if;

  -- THE REPORTER'S LOCK: exactly the key _attempts_guard takes for this
  -- reporter and 'report_filed' (re-entrant, so its own lock below is
  -- free). Two reports by one person run one after the other, so neither
  -- the one-a-day rule nor the limits can be slipped past.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('attempt_log:' || v_actor::text || ':report_filed', 0)
  );

  -- One report on the same person in 24 hours, whatever the table.
  if exists (
    select 1
    from public.player_reports r
    where r.reporter_id = v_actor
      and r.reported_id = p_target
      and r.created_at > now() - interval '24 hours'
  ) then
    return 'already_reported';
  end if;

  -- 10 an hour, 30 a day (rolling), real reports only.
  select count(*) filter (where a.created_at > now() - interval '1 hour'),
         count(*)
  into v_hour, v_day
  from public.attempt_log a
  where a.user_id = v_actor
    and a.action = 'report_filed'
    and a.success
    and a.created_at > now() - interval '24 hours';

  if v_hour >= 10 or v_day >= 30 then
    return 'limit';
  end if;

  -- The success row (the helper re-counts the hour under the same lock, so
  -- it cannot refuse here).
  perform public._attempts_guard(v_actor, 'report_filed', 10, interval '1 hour',
    'You have sent 10 reports in the last hour. Please try again a little later.');

  -- The note: bounded first, bad characters to spaces, spaces collapsed,
  -- trimmed, at most 200 characters, empty -> null.
  v_note := pg_catalog.left(coalesce(p_note, ''), 1000);
  v_note := pg_catalog.regexp_replace(v_note, v_bad_chars, ' ', 'g');
  v_note := pg_catalog.regexp_replace(v_note, ' {2,}', ' ', 'g');
  v_note := pg_catalog.btrim(v_note);
  v_note := pg_catalog.btrim(pg_catalog.left(v_note, 200));
  if v_note = '' then
    v_note := null;
  end if;

  -- The table: kept only if it is a real table (no foreign key: the report
  -- must outlive it).
  if p_table_id is not null and exists (select 1 from public.tables t where t.id = p_table_id) then
    v_table_id := p_table_id;
  end if;

  -- THE SNAPSHOT.
  select p.nickname into v_reporter_nickname from public.profiles p where p.id = v_actor;
  select p.nickname, p.avatar_url into v_nickname, v_avatar_url from public.profiles p where p.id = p_target;
  select a.o_updated_at, a.o_size
  into v_obj_updated_at, v_obj_size
  from public._report_avatar_object(p_target, v_avatar_url) a;

  insert into public.player_reports (
    reporter_id, reported_id, reason, note, table_id,
    reporter_nickname, reported_nickname, reported_avatar_url,
    avatar_object_updated_at, avatar_object_size)
  values (
    v_actor, p_target, p_reason, v_note, v_table_id,
    v_reporter_nickname, v_nickname, v_avatar_url,
    v_obj_updated_at, v_obj_size);

  -- ==== (M7) CHAT COPY: behavior reports only (moderation-m7-part1.sql) ====
  -- The report is filed above, and every refusal returned before it, so a
  -- refused report never copies anything. A behavior report gets the chat
  -- still stored for v_table_id (_report_table_chat), but only when the
  -- reporter is seated at that table or a current spectator of it
  -- (send_table_message's rule 3, without needing the table open); the
  -- reported person need not be there. FAIL OPEN: any error inside this
  -- block leaves the report filed with chat_status 'unavailable'. The row is
  -- found by reporter, reported person, reason and created_at = now(): under
  -- this reporter's lock the one-a-day rule above allows exactly one such
  -- row, the one just inserted. Nickname and picture reports skip the block
  -- (their four chat columns stay null).
  if p_reason = 'behavior' then
    declare
      v_chat_status text := 'not_at_table';
      v_chat_total integer;
      v_chat_kept integer;
      v_chat jsonb;
    begin
      if v_table_id is not null
         and (exists (select 1 from public.table_members tm
                      where tm.table_id = v_table_id and tm.user_id = v_actor)
              or exists (select 1 from public.table_spectators ts
                         where ts.table_id = v_table_id and ts.user_id = v_actor
                           and ts.removed_at is null
                           and ts.last_seen_at > now() - interval '90 seconds')) then
        select c.o_total, c.o_kept, c.o_chat
        into v_chat_total, v_chat_kept, v_chat
        from public._report_table_chat(v_table_id) c;
        if coalesce(v_chat_total, 0) = 0 then
          v_chat_status := 'none';
          v_chat_total := 0;
          v_chat_kept := 0;
          v_chat := null;
        else
          v_chat_status := 'copied';
        end if;
      end if;
      update public.player_reports r
      set chat_status = v_chat_status, chat_total = v_chat_total, chat_kept = v_chat_kept, chat = v_chat
      where r.reporter_id = v_actor and r.reported_id = p_target
        and r.reason = 'behavior' and r.created_at = now();
    exception when others then
      update public.player_reports r
      set chat_status = 'unavailable', chat_total = null, chat_kept = null, chat = null
      where r.reporter_id = v_actor and r.reported_id = p_target
        and r.reason = 'behavior' and r.created_at = now();
    end;
  end if;
  -- ==== end (M7) ====

  return 'reported';
end;
$$;

comment on function public.report_player(uuid, text, text, uuid) is
  'Moderation M6 and M7: the signed-in person reports p_target for p_reason (nickname, picture or behavior) with an optional note (cleaned, at most 200 characters) from table p_table_id (optional; kept only if it is a real table). The target need not be at any table. The server takes the snapshot (both nicknames, the avatar_url, the avatar object''s date and size). A behavior report also copies the table''s chat (M7: only when the reporter is seated at it or a current spectator of it; chat_status copied, none, not_at_table, or unavailable when the copy fails -- the report is filed either way). Returns reported, already_reported (the same reporter and person within 24 hours), not_found (no such profile), not_allowed (yourself, a computer account, a computer caller) or limit (10 an hour, 30 a day; real reports only); raises for nobody logged in or an unknown reason. Nothing happens to the reported person; nothing is broadcast. See docs/sql/moderation-m6-part1.sql and moderation-m7-part1.sql.';

-- Grants unchanged by CREATE OR REPLACE; restated so this file shows them.
revoke all on function public.report_player(uuid, text, text, uuid) from public;
revoke all on function public.report_player(uuid, text, text, uuid) from anon;
revoke all on function public.report_player(uuid, text, text, uuid) from service_role;
revoke all on function public.report_player(uuid, text, text, uuid) from authenticated;
grant execute on function public.report_player(uuid, text, text, uuid) to authenticated;


-- admin_list_reports: a new result type, so drop and recreate.
drop function public.admin_list_reports(integer);

create or replace function public.admin_list_reports(p_limit integer default 100)
returns table (
  id uuid,
  created_at timestamptz,
  reason text,
  note text,
  table_id uuid,
  table_code text,
  reporter_id uuid,
  reporter_nickname text,
  reporter_nickname_now text,
  reported_id uuid,
  reported_nickname text,
  reported_nickname_now text,
  reported_avatar_url text,
  picture_changed boolean,
  reporter_report_count integer,
  reported_report_count integer,
  chat_status text,
  chat_total integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if auth.uid() is null
     or not exists (select 1 from public.admin_users a where a.user_id = auth.uid()) then
    raise exception 'Admins only.';
  end if;

  -- picture_changed: the profile's avatar_url is no longer the snapshot's,
  -- or the object behind the snapshot's url now has another date or size
  -- than when the report was filed (an upload overwrites the same file).
  -- Compared only where the snapshot has a value. table_code: the table's
  -- CURRENT code (null once the table is gone; codes are reused after a
  -- table ends, so table_id is the real reference).
  return query
  select r.id, r.created_at, r.reason, r.note, r.table_id, t.code,
         r.reporter_id, r.reporter_nickname, rp.nickname,
         r.reported_id, r.reported_nickname, dp.nickname,
         r.reported_avatar_url,
         (r.reported_avatar_url is distinct from dp.avatar_url
          or (r.avatar_object_updated_at is not null and cur.o_updated_at is distinct from r.avatar_object_updated_at)
          or (r.avatar_object_size is not null and cur.o_size is distinct from r.avatar_object_size)),
         (select count(*) from public.player_reports x where x.reporter_id = r.reporter_id)::integer,
         (select count(*) from public.player_reports x where x.reported_id = r.reported_id)::integer,
         -- (M7) the chat copy's status and count; never the chat itself (admin_report_chat).
         r.chat_status, r.chat_total
  from public.player_reports r
  left join public.tables t on t.id = r.table_id
  left join public.profiles rp on rp.id = r.reporter_id
  left join public.profiles dp on dp.id = r.reported_id
  left join lateral public._report_avatar_object(r.reported_id, r.reported_avatar_url) cur on true
  order by r.created_at desc, r.id
  limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$$;

comment on function public.admin_list_reports(integer) is
  'Moderation M6 and M7: ADMINS ONLY (admin_users; "Admins only." for anyone else): the newest reports (1 to 500, default 100) with the reason, note, table (id and current code), both snapshot nicknames and both CURRENT nicknames, the snapshot avatar_url, picture_changed (the avatar_url or its storage object changed since the report), how many reports the reporter has filed and how many exist against the reported person, and (M7) the chat copy''s chat_status and chat_total -- never the chat itself (admin_report_chat reads one report''s). The admin page''s Reports. See docs/sql/moderation-m6-part1.sql and moderation-m7-part1.sql.';

revoke all on function public.admin_list_reports(integer) from public;
revoke all on function public.admin_list_reports(integer) from anon;
revoke all on function public.admin_list_reports(integer) from service_role;
revoke all on function public.admin_list_reports(integer) from authenticated;
grant execute on function public.admin_list_reports(integer) to authenticated;


create or replace function public.admin_report_chat(p_id uuid)
returns table (
  chat_status text,
  chat_total integer,
  chat_kept integer,
  chat jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if auth.uid() is null
     or not exists (select 1 from public.admin_users a where a.user_id = auth.uid()) then
    raise exception 'Admins only.';
  end if;

  -- One report's chat copy; no row for an unknown id.
  return query
  select r.chat_status, r.chat_total, r.chat_kept, r.chat
  from public.player_reports r
  where r.id = p_id;
end;
$$;

comment on function public.admin_report_chat(uuid) is
  'Moderation M7: ADMINS ONLY (admin_users; "Admins only." for anyone else): report p_id''s chat copy -- chat_status, chat_total, chat_kept and chat ({people, lines}, see public.player_reports.chat). No row for an unknown id. The admin page''s "View chat". See docs/sql/moderation-m7-part1.sql.';

revoke all on function public.admin_report_chat(uuid) from public;
revoke all on function public.admin_report_chat(uuid) from anon;
revoke all on function public.admin_report_chat(uuid) from service_role;
revoke all on function public.admin_report_chat(uuid) from authenticated;
grant execute on function public.admin_report_chat(uuid) to authenticated;

-- PostgREST: reload the schema cache now (the changed and new RPCs).
notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  (select count(*) from pg_attribute a where a.attrelid = 'public.player_reports'::regclass
     and a.attname in ('chat', 'chat_status', 'chat_total', 'chat_kept') and not a.attisdropped) as chat_columns,
  (select count(*) from pg_constraint con where con.conrelid = 'public.player_reports'::regclass
     and con.conname in ('player_reports_chat_status_check', 'player_reports_chat_check')) as chat_constraints,
  (select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure('public.report_player(uuid, text, text, uuid)')) as report_player_md5_lf,
  has_function_privilege('authenticated', 'public.admin_report_chat(uuid)', 'EXECUTE') as admin_report_chat_for_authenticated,
  has_function_privilege('authenticated', 'public._report_table_chat(uuid)', 'EXECUTE') as helper_for_authenticated,
  has_function_privilege('authenticated', 'public.admin_list_reports(integer)', 'EXECUTE') as admin_list_reports_for_authenticated,
  (select count(*) from public.player_reports r where r.chat_status is not null) as reports_with_chat_status;
