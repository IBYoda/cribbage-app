-- Moderation, slice M7: ROLLBACK of PART 1 (docs/sql/moderation-m7-part1.sql).
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: NOT RUN (reference only). M7 part 1 is live since 2026-11-28.
--
-- WHEN: roll the app back first if it already calls admin_report_chat (an
-- old admin page would just see "View chat" fail). Filing reports never
-- needs the app rolled back: report_player keeps its arguments and answers.
--
-- ONE-WAY FOR THE DATA: every chat copy (chat, chat_status, chat_total,
-- chat_kept) is deleted with the four columns. The reports themselves stay,
-- exactly as M6 keeps them. If the copies matter, export them first, e.g.:
--   select id, created_at, reporter_id, reported_id, table_id, chat_status,
--          chat_total, chat_kept, chat
--   from public.player_reports where chat_status is not null order by created_at;
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold): the four chat
--      columns exist; report_player and admin_list_reports have M7 part 1's
--      bodies; admin_report_chat and _report_table_chat exist. It records how
--      many reports carry a chat status (the result row shows it).
--   1. report_player back to M6 part 1's body exactly (CREATE OR REPLACE:
--      owner, grants and settings kept), with M6's comment and grants.
--   2. admin_list_reports dropped and recreated as M6 part 1 wrote it (its
--      old result type), with M6's comment and grants.
--   3. Drops admin_report_chat and _report_table_chat.
--   4. player_reports: drops the two chat constraints and the four columns
--      (ONE-WAY), and puts back M6 part 1's table comment.
--
-- NOT TOUCHED: everything moderation-m7-part1.sql did not change (the
-- reports, attempt_log, the cron job, the other M6 functions).

begin;

-- How many chat copies this rollback deletes (shown in the result row). A
-- temp table: this session only.
drop table if exists pg_temp.m7_rollback_counts;
create temp table m7_rollback_counts (with_status bigint, copied bigint) on commit preserve rows;

do $$
declare
  v_txt text;
  v_n integer;
begin
  select count(*) into v_n from pg_attribute a
  where a.attrelid = to_regclass('public.player_reports')
    and a.attname in ('chat', 'chat_status', 'chat_total', 'chat_kept') and a.attnum > 0 and not a.attisdropped;
  if v_n <> 4 then
    raise exception 'STOP: public.player_reports has % of the four chat columns (want 4): M7 part 1 is not in, or only partly. Nothing was changed.', v_n;
  end if;

  select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure('public.report_player(uuid, text, text, uuid)');
  if v_txt is distinct from '2dd85cea07caa56de74f5bfdef7d3b07' then
    raise exception 'STOP: public.report_player has body md5 % (LF); expected M7 part 1''s 2dd85cea07caa56de74f5bfdef7d3b07. A later slice changed it: roll that slice back first. Nothing was changed.', coalesce(v_txt, 'missing');
  end if;
  select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure('public.admin_list_reports(integer)');
  if v_txt is distinct from '05e0e3809b944590a850ddc8ce259570' then
    raise exception 'STOP: public.admin_list_reports has body md5 % (LF); expected M7 part 1''s 05e0e3809b944590a850ddc8ce259570. A later slice changed it: roll that slice back first. Nothing was changed.', coalesce(v_txt, 'missing');
  end if;
  if to_regprocedure('public.admin_report_chat(uuid)') is null or to_regprocedure('public._report_table_chat(uuid)') is null then
    raise exception 'STOP: admin_report_chat(uuid) or _report_table_chat(uuid) is missing: M7 part 1 is only partly in. Nothing was changed.';
  end if;

  execute 'select count(*) filter (where chat_status is not null), count(*) filter (where chat_status = ''copied'') from public.player_reports'
    into v_n, v_txt;
  insert into m7_rollback_counts (with_status, copied) values (v_n, v_txt::bigint);
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. report_player: M6 part 1's body, comment and grants.
-- ---------------------------------------------------------------------------
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

  return 'reported';
end;
$$;

comment on function public.report_player(uuid, text, text, uuid) is
  'Moderation M6: the signed-in person reports p_target for p_reason (nickname, picture or behavior) with an optional note (cleaned, at most 200 characters) from table p_table_id (optional; kept only if it is a real table). The target need not be at any table. The server takes the snapshot (both nicknames, the avatar_url, the avatar object''s date and size). Returns reported, already_reported (the same reporter and person within 24 hours), not_found (no such profile), not_allowed (yourself, a computer account, a computer caller) or limit (10 an hour, 30 a day; real reports only); raises for nobody logged in or an unknown reason. Nothing happens to the reported person; nothing is broadcast. See docs/sql/moderation-m6-part1.sql.';

revoke all on function public.report_player(uuid, text, text, uuid) from public;
revoke all on function public.report_player(uuid, text, text, uuid) from anon;
revoke all on function public.report_player(uuid, text, text, uuid) from service_role;
revoke all on function public.report_player(uuid, text, text, uuid) from authenticated;
grant execute on function public.report_player(uuid, text, text, uuid) to authenticated;



-- ---------------------------------------------------------------------------
-- 2. admin_list_reports: M6 part 1's result type, body, comment and grants.
-- ---------------------------------------------------------------------------
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
  reported_report_count integer
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
         (select count(*) from public.player_reports x where x.reported_id = r.reported_id)::integer
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
  'Moderation M6: ADMINS ONLY (admin_users; "Admins only." for anyone else): the newest reports (1 to 500, default 100) with the reason, note, table (id and current code), both snapshot nicknames and both CURRENT nicknames, the snapshot avatar_url, picture_changed (the avatar_url or its storage object changed since the report), and how many reports the reporter has filed and how many exist against the reported person. The admin page''s Reports. See docs/sql/moderation-m6-part1.sql.';

revoke all on function public.admin_list_reports(integer) from public;
revoke all on function public.admin_list_reports(integer) from anon;
revoke all on function public.admin_list_reports(integer) from service_role;
revoke all on function public.admin_list_reports(integer) from authenticated;
grant execute on function public.admin_list_reports(integer) to authenticated;



-- ---------------------------------------------------------------------------
-- 3. The new functions.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_report_chat(uuid);
drop function if exists public._report_table_chat(uuid);

-- ---------------------------------------------------------------------------
-- 4. player_reports: the chat columns (ONE-WAY) and M6's table comment.
-- ---------------------------------------------------------------------------
alter table public.player_reports drop constraint if exists player_reports_chat_check;
alter table public.player_reports drop constraint if exists player_reports_chat_status_check;
alter table public.player_reports
  drop column chat,
  drop column chat_status,
  drop column chat_total,
  drop column chat_kept;

comment on table public.player_reports is
  'Moderation M6: one row per report filed by a player about another (reason nickname, picture or behavior; an optional note of up to 200 characters), with the server''s snapshot at filing time (both nicknames, the reported avatar_url and its storage object''s date and size). Nothing happens to the reported person automatically; reports are never broadcast. NO foreign keys, deliberately: a report outlives both accounts and the table. Deleted 90 days after filing (purge_old_reports, pg_cron job report-purge) or earlier by an admin (admin_delete_report). PRIVATE: no client role has any privilege on it and RLS is on with no policies; written only by report_player, read by admins through admin_list_reports (security definer). See docs/sql/moderation-m6-part1.sql.';

notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  (select count(*) from pg_attribute a where a.attrelid = 'public.player_reports'::regclass
     and a.attname in ('chat', 'chat_status', 'chat_total', 'chat_kept') and not a.attisdropped) as chat_columns_left,
  (select md5(replace(p.prosrc, E'\r', '')) = 'cbbe554a4e170379f8c6b7ac88b1cecc' from pg_proc p
   where p.oid = to_regprocedure('public.report_player(uuid, text, text, uuid)')) as report_player_is_m6,
  (select md5(replace(p.prosrc, E'\r', '')) = 'b2bcdc0cd74f7453e964ec3bc31c6998' from pg_proc p
   where p.oid = to_regprocedure('public.admin_list_reports(integer)')) as admin_list_reports_is_m6,
  has_function_privilege('authenticated', 'public.admin_list_reports(integer)', 'EXECUTE') as admin_list_reports_for_authenticated,
  to_regprocedure('public.admin_report_chat(uuid)') is null as admin_report_chat_gone,
  to_regprocedure('public._report_table_chat(uuid)') is null as helper_gone,
  (select c.with_status from m7_rollback_counts c) as chat_statuses_deleted,
  (select c.copied from m7_rollback_counts c) as chat_copies_deleted;
