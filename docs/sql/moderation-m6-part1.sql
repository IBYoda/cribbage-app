-- Moderation, slice M6: REPORTS. PART 1 (the only part): ADD-ONLY (safe
-- before any app change). Run in the Supabase Dashboard -> SQL Editor. Kept
-- here for reference/history; this project has no Supabase CLI/migrations
-- set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M6):
--   1. docs/sql/moderation-m6-precheck.sql       (read-only; no STOP rows,
--      state "before part 1")
--   2. docs/sql/moderation-m6-part1.sql          (THIS FILE)
--   3. docs/sql/moderation-m6-verification.sql   ("ALL n CHECKS PASSED")
--      and docs/sql/slice-e-grants-verification.sql (59 names,
--      player_reports known)
--   4. the regression suites (below)
--   5. the app (PR): the popup's Report, the eye list's Report, the report
--      dialog, the admin page's Reports list
--   6. the hand test
--   Rollback: docs/sql/moderation-m6-part1-rollback.sql.
--
-- REGRESSION SUITES to re-run after this file (each made state-aware for
-- M6 in the same slice): moderation-m3-verification.sql (K1 accepts the
-- tenth action), slice-e-attempt-log-cleanup-verification.sql (K3: ten
-- actions), slice-e-grants-verification.sql (59 names, player_reports with
-- no client privileges); the prechecks slice-e-precheck.sql,
-- moderation-m1-precheck.sql and moderation-m3-precheck.sql now accept the
-- ten actions and 59 functions.
--
-- WHAT WALT DECIDED (M6, 2026-11-25): anyone at a human table may report
-- another person for one of three things -- an offensive nickname, an
-- offensive picture, or behavior at a table -- with an optional note of up
-- to 200 characters. The person may have left the table already: they are
-- never required to be seated or watching. NOTHING AUTOMATIC HAPPENS to the
-- reported person, and a report is never broadcast or shown on anyone's
-- screen: admins read the list (newest first) and may delete any report.
-- Every report is deleted 90 days after it was filed (a daily pg_cron job).
-- Limits per reporter: 10 reports an hour, 30 a day, and at most ONE report
-- on the same person in 24 hours, whatever the table. Chat-message reports
-- wait for M5.
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold): moderation M3 part
--      1 is in (public.table_kicks, kick_player); attempt_log_action_check
--      allows exactly M3's nine actions; public.player_reports does not
--      exist; none of this file's five function names exists; pg_cron is
--      installed and has no job named 'report-purge'; public.admin_users,
--      public.profiles and public.computer_accounts exist; _attempts_guard
--      still takes the lock this file relies on (its body is slice A's, LF
--      or CRLF). NOT RE-RUNNABLE BY DESIGN: a second run STOPs at the guard
--      (the table, the tenth action, the functions or the job are already
--      there). A failed run changes nothing (one transaction).
--   1. attempt_log_action_check also allows 'report_filed' (TEN actions).
--      THE ONE-WAY-ISH PART: once real reports have been filed there are
--      report_filed rows, and the rollback must delete them before the
--      nine-action constraint can come back (it does so, and says so).
--      Written only by report_player for a REAL report (never for
--      already_reported, not_found, not_allowed, limit or an error).
--   2. public.player_reports: one row per report, with the server's own
--      snapshot taken at filing time (the reporter's and the reported
--      person's nicknames, the reported person's avatar_url, and the avatar
--      file's storage date and size when they can be read). The picture
--      itself is NOT copied. NO FOREIGN KEYS, deliberately (unlike blocks
--      and table_kicks): a report must outlive the reporter's account, the
--      reported person's account and the table. RLS ON with NO policies and
--      ALL privileges revoked from PUBLIC, anon, authenticated and
--      service_role (AGENTS.md "New tables": clients never touch it; admins
--      read it through admin_list_reports). Not in the supabase_realtime
--      publication.
--   3. Functions, all SECURITY DEFINER with search_path '':
--        _report_avatar_object(p_user uuid, p_url text,
--                              out o_updated_at timestamptz, out o_size bigint)
--          INTERNAL (no client role): the avatars bucket's object behind an
--          avatar_url, if the url points into p_user's own folder and the
--          object can be read; nulls otherwise (never raises).
--        report_player(p_target uuid, p_reason text, p_note text,
--                      p_table_id uuid) text               authenticated
--          Files a report. Returns 'reported', 'already_reported',
--          'not_found', 'not_allowed' or 'limit'; raises a plain message
--          when nobody is logged in or the reason is not one of the three.
--        admin_list_reports(p_limit integer) table         authenticated
--          Admins only ("Admins only." for anyone else): the newest reports
--          with both snapshots, both CURRENT nicknames, picture_changed and
--          the two counts.
--        admin_delete_report(p_id uuid) text               authenticated
--          Admins only: 'deleted' or 'not_found'.
--        purge_old_reports() integer
--          INTERNAL: deletes reports filed more than 90 days ago; returns
--          how many. Run by the pg_cron job below. No client role.
--   4. The pg_cron job 'report-purge', daily at 04:23 ('23 4 * * *': off
--      the :00 and :17 minutes of the other jobs).
--
-- THE LIMITS (report_player, in this order, all under ONE per-reporter
-- advisory lock -- the very lock _attempts_guard takes for this reporter
-- and 'report_filed' -- so two reports at once can't both slip past):
--   a. ONE A DAY PER PERSON: a report by this reporter on this person filed
--      in the last 24 hours -> 'already_reported' (counts nothing). Read
--      from player_reports, so a report an admin deleted no longer blocks.
--   b. 10 AN HOUR and 30 A DAY: this reporter's report_filed rows in
--      attempt_log within the last hour (>= 10) or the last 24 hours
--      (>= 30) -> 'limit' (counts nothing). Rolling windows. Read from
--      attempt_log, so an admin deleting reports never gives the reporter
--      more. attempt_log keeps 7 days (cleanup_attempt_log), so the 24-hour
--      window is always complete.
--   c. Then _attempts_guard(reporter, 'report_filed', 10, '1 hour', ...)
--      logs the success row. It counts the hour again under the same lock
--      (re-entrant), so it can't refuse here; its message exists only
--      because the helper needs one. _attempts_guard itself only knows one
--      window, so the daily cap is the count in b, not a second helper call.
--
-- md5 of the new bodies (carriage returns removed; LF), and with CRLF line
-- ends (this file as committed):
--   _report_avatar_object   045267155656c63ce47b152cef6c9044 / f2800cf4e9c734d7d8207d51bce7bdca
--   report_player           cbbe554a4e170379f8c6b7ac88b1cecc / e40baa89720caf90bc5bbc042c15c482
--   admin_list_reports      b2bcdc0cd74f7453e964ec3bc31c6998 / 98d5a52aef5700d7b1c021fbe70365a3
--   admin_delete_report     77cd0a0d585977060ad7153baf64ff0f / 27373e7cbb0b36afb6578e46239479ac
--   purge_old_reports       62eaf1170d97a02e1783d7f0197a9767 / 9e1553c176dd777888721303c9792346
--
-- NOT TOUCHED: every existing function body (this slice replaces NO
-- function), every existing policy, grant and cron job.
--
-- ROLLBACK: docs/sql/moderation-m6-part1-rollback.sql (ONE-WAY for the
-- data: the reports are gone).

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard.
-- ---------------------------------------------------------------------------
do $$
declare
  v_txt text;
  v_n integer;
begin
  -- _attempts_guard: slice A's body (LF or CRLF) -- the lock key and the
  -- success row report_player relies on.
  select md5(p.prosrc) into v_txt
  from pg_proc p
  where p.oid = to_regprocedure('public._attempts_guard(uuid, text, integer, interval, text)');
  if v_txt is null or v_txt not in ('b1b69dbbdf10d50f78655a0da3b3ac69', '9406938991e89dcd38d0686a279b432a') then
    raise exception 'STOP: public._attempts_guard has body md5 %; expected b1b69dbbdf10d50f78655a0da3b3ac69 (LF) or 9406938991e89dcd38d0686a279b432a (CRLF). Nothing was changed.', coalesce(v_txt, 'missing');
  end if;

  -- Moderation M3 part 1 is in.
  if to_regclass('public.table_kicks') is null
     or to_regprocedure('public.kick_player(uuid, uuid)') is null then
    raise exception 'STOP: moderation M3 part 1 is not in (public.table_kicks, kick_player). Nothing was changed.';
  end if;

  -- The tables this file reads.
  if to_regclass('public.admin_users') is null
     or to_regclass('public.profiles') is null
     or to_regclass('public.computer_accounts') is null then
    raise exception 'STOP: public.admin_users, public.profiles or public.computer_accounts is missing. Nothing was changed.';
  end if;

  -- The attempt_log check: exactly M3's nine actions (report_filed already
  -- there means this file ran: STOP).
  select pg_get_constraintdef(con.oid) into v_txt
  from pg_constraint con
  where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check';
  v_n := (length(coalesce(v_txt, '')) - length(replace(coalesce(v_txt, ''), '::text', ''))) / 6;
  if v_txt is null
     or v_txt !~ '''create_table''' or v_txt !~ '''create_computer_table''' or v_txt !~ '''join'''
     or v_txt !~ '''watch''' or v_txt !~ '''code_guess''' or v_txt !~ '''game_start''' or v_txt !~ '''follow_change'''
     or v_txt !~ '''block_change''' or v_txt !~ '''kick'''
     or v_txt ~ '''report_filed'''
     or v_n <> 9 then
    raise exception 'STOP: attempt_log_action_check is "%"; expected exactly create_table, create_computer_table, join, watch, code_guess, game_start, follow_change, block_change, kick (M3''s nine; report_filed there means this file already ran). Nothing was changed.', coalesce(v_txt, 'missing');
  end if;

  -- public.player_reports must not exist yet.
  if to_regclass('public.player_reports') is not null then
    raise exception 'STOP: public.player_reports already exists (this file already ran, or something else made it). Nothing was changed.';
  end if;

  -- None of the five function names exists, with any signature.
  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname) into v_txt
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('_report_avatar_object', 'report_player', 'admin_list_reports', 'admin_delete_report', 'purge_old_reports');
  if v_txt is not null then
    raise exception 'STOP: these functions already exist: %. This file already ran, or the names are taken. Nothing was changed.', v_txt;
  end if;

  -- pg_cron installed, and no job named report-purge yet (read through
  -- EXECUTE, so this file parses where the cron schema does not exist).
  if to_regclass('cron.job') is null then
    raise exception 'STOP: pg_cron is not installed; the 90-day report purge needs it. Nothing was changed.';
  end if;
  execute 'select count(*)::int from cron.job j where j.jobname::text = $1' into v_n using 'report-purge';
  if v_n <> 0 then
    raise exception 'STOP: a pg_cron job named report-purge already exists (this file already ran?). Nothing was changed.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The new attempt_log action (ten actions).
-- ---------------------------------------------------------------------------
alter table public.attempt_log drop constraint attempt_log_action_check;
alter table public.attempt_log
  add constraint attempt_log_action_check
  check (action in ('create_table', 'create_computer_table', 'join', 'watch', 'code_guess',
                    'game_start', 'follow_change', 'block_change', 'kick', 'report_filed'));

comment on table public.attempt_log is
  'Rate limits (step 3, slices A and E; moderation M1, M3 and M6): one row per counted action -- a table created (create_table), a computer game started (create_computer_table), a join, a new watch, a game started (game_start), a real follow or unfollow (follow_change), a real block or unblock (block_change), a real kick (kick), a real report filed (report_filed) (success true), or a wrong table code (code_guess, success false). Read and written only by security definer functions through the _attempts_* / _code_guess* helpers (report_player also counts report_filed rows for its daily cap). Rows older than 7 days are deleted hourly by cleanup_attempt_log() (pg_cron job attempt-log-cleanup). RLS on, no policies, no grants. See docs/sql/join-create.sql, slice-e-part1.sql, moderation-m1-part1.sql, moderation-m3-part1.sql and moderation-m6-part1.sql.';

-- ---------------------------------------------------------------------------
-- 2. public.player_reports (AGENTS.md "New tables": the template's order --
--    table, comment, RLS on, revokes, grants (none), policies (none)).
-- ---------------------------------------------------------------------------
create table public.player_reports (
  id uuid not null default gen_random_uuid() primary key,
  created_at timestamptz not null default now(),
  -- NO FOREIGN KEYS on reporter_id, reported_id or table_id, deliberately
  -- (unlike blocks and table_kicks, which cascade): a report must survive
  -- the reporter deleting their account, the reported person deleting
  -- theirs, and the table being deleted. They are plain ids.
  reporter_id uuid not null,
  reported_id uuid not null,
  reason text not null,
  -- Cleaned by report_player: control and invisible formatting characters
  -- replaced by spaces, runs of spaces made one, trimmed, at most 200
  -- characters; an empty note is null.
  note text,
  -- The table it was filed from, if any (null: none, or not a table that
  -- existed when the report was filed).
  table_id uuid,
  -- THE SNAPSHOT, taken by the server when the report was filed.
  reporter_nickname text,
  reported_nickname text,
  reported_avatar_url text,
  -- The avatars bucket's object behind reported_avatar_url, when it could
  -- be read: its updated_at and size in bytes (the picture is not copied;
  -- an upload overwrites the same file, so these show whether it changed).
  avatar_object_updated_at timestamptz,
  avatar_object_size bigint,
  constraint player_reports_reason_check check (reason in ('nickname', 'picture', 'behavior')),
  constraint player_reports_note_check check (note is null or char_length(note) between 1 and 200),
  constraint player_reports_not_self check (reporter_id <> reported_id)
);

-- The admin list (newest first) and the purge; the per-person count; the
-- per-reporter count; the one-a-day-per-person rule.
create index player_reports_created_at_idx on public.player_reports (created_at desc);
create index player_reports_reported_idx on public.player_reports (reported_id, created_at desc);
create index player_reports_reporter_idx on public.player_reports (reporter_id, created_at desc);
create index player_reports_pair_idx on public.player_reports (reporter_id, reported_id, created_at desc);

comment on table public.player_reports is
  'Moderation M6: one row per report filed by a player about another (reason nickname, picture or behavior; an optional note of up to 200 characters), with the server''s snapshot at filing time (both nicknames, the reported avatar_url and its storage object''s date and size). Nothing happens to the reported person automatically; reports are never broadcast. NO foreign keys, deliberately: a report outlives both accounts and the table. Deleted 90 days after filing (purge_old_reports, pg_cron job report-purge) or earlier by an admin (admin_delete_report). PRIVATE: no client role has any privilege on it and RLS is on with no policies; written only by report_player, read by admins through admin_list_reports (security definer). See docs/sql/moderation-m6-part1.sql.';

-- Row-level security on, with NO policies: deny by default.
alter table public.player_reports enable row level security;

-- No privileges for any client role (least privilege: the app never touches
-- the table directly). Revoking everything also removes anything the
-- project's default privileges gave the table when it was created.
-- service_role too: nothing needs it.
revoke all on table public.player_reports from public;
revoke all on table public.player_reports from anon;
revoke all on table public.player_reports from authenticated;
revoke all on table public.player_reports from service_role;

-- No grants and no policies: deliberately none. Not added to the
-- supabase_realtime publication: reports are never sent to any screen.

-- ---------------------------------------------------------------------------
-- 3. The functions.
-- ---------------------------------------------------------------------------
create or replace function public._report_avatar_object(
  p_user uuid,
  p_url text,
  out o_updated_at timestamptz,
  out o_size bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  -- The object name after ".../storage/v1/object/public/avatars/", up to
  -- any "?" or "#" (the app adds ?t=<ms> to bust caches). Only a name in
  -- p_user's own folder is looked up; anything else gives nulls.
  if p_user is null or p_url is null then
    return;
  end if;
  v_name := substring(p_url from '/storage/v1/object/public/avatars/([^?#]+)');
  if v_name is null
     or left(v_name, 37) is distinct from p_user::text || '/'
     or strpos(v_name, '..') > 0 then
    return;
  end if;

  -- Read the object, if storage exists and this role may read it. Never
  -- raises: a report is filed with null stamps rather than refused.
  begin
    select o.updated_at, (o.metadata ->> 'size')::bigint
    into o_updated_at, o_size
    from storage.objects o
    where o.bucket_id = 'avatars'
      and o.name = v_name;
  exception when others then
    o_updated_at := null;
    o_size := null;
  end;
end;
$$;

comment on function public._report_avatar_object(uuid, text) is
  'Internal (moderation M6): the avatars bucket''s object behind an avatar_url -- its updated_at and size (metadata size) -- when the url points into p_user''s own folder and the object can be read; nulls otherwise (never raises). Called by report_player (the snapshot) and admin_list_reports (picture_changed). No client role can execute it. See docs/sql/moderation-m6-part1.sql.';

revoke all on function public._report_avatar_object(uuid, text) from public;
revoke all on function public._report_avatar_object(uuid, text) from anon;
revoke all on function public._report_avatar_object(uuid, text) from authenticated;
revoke all on function public._report_avatar_object(uuid, text) from service_role;


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


create or replace function public.admin_delete_report(p_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  if auth.uid() is null
     or not exists (select 1 from public.admin_users a where a.user_id = auth.uid()) then
    raise exception 'Admins only.';
  end if;

  delete from public.player_reports r
  where r.id = p_id;
  get diagnostics v_n = row_count;

  if v_n = 0 then
    return 'not_found';
  end if;
  return 'deleted';
end;
$$;

comment on function public.admin_delete_report(uuid) is
  'Moderation M6: ADMINS ONLY (admin_users; "Admins only." for anyone else): deletes one report. Returns deleted or not_found. The reporter''s report_filed rows in attempt_log stay (deleting a report never gives back a limit). See docs/sql/moderation-m6-part1.sql.';

revoke all on function public.admin_delete_report(uuid) from public;
revoke all on function public.admin_delete_report(uuid) from anon;
revoke all on function public.admin_delete_report(uuid) from service_role;
revoke all on function public.admin_delete_report(uuid) from authenticated;
grant execute on function public.admin_delete_report(uuid) to authenticated;


create or replace function public.purge_old_reports()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  delete from public.player_reports r
  where r.created_at < now() - interval '90 days';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

comment on function public.purge_old_reports() is
  'Internal (moderation M6): deletes reports filed more than 90 days ago and returns how many. Run daily by the pg_cron job report-purge. Security definer, empty search_path, executable by no client role. See docs/sql/moderation-m6-part1.sql.';

revoke all on function public.purge_old_reports() from public;
revoke all on function public.purge_old_reports() from anon;
revoke all on function public.purge_old_reports() from authenticated;
revoke all on function public.purge_old_reports() from service_role;

-- ---------------------------------------------------------------------------
-- 4. The pg_cron job, daily at 04:23 (through EXECUTE, so this file parses
--    where the cron schema does not exist; the guard already stopped
--    there). The job runs as the role that schedules it (the dashboard's
--    postgres), which owns purge_old_reports.
-- ---------------------------------------------------------------------------
do $$
begin
  execute $cron$select cron.schedule('report-purge', '23 4 * * *', 'select public.purge_old_reports();')$cron$;
end;
$$;

-- PostgREST: reload the schema cache now (the new RPCs).
notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  to_regclass('public.player_reports') is not null as player_reports_table,
  (select c.relrowsecurity from pg_class c where c.oid = to_regclass('public.player_reports')) as player_reports_rls_on,
  (select count(*) from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'player_reports') as player_reports_policies,
  has_function_privilege('authenticated', 'public.report_player(uuid, text, text, uuid)', 'EXECUTE') as report_player_for_authenticated,
  has_function_privilege('authenticated', 'public.purge_old_reports()', 'EXECUTE') as purge_for_authenticated,
  (select pg_get_constraintdef(con.oid) ~ '''report_filed''' from pg_constraint con
   where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check') as attempt_log_allows_report_filed,
  (xpath('/row/c/text()', query_to_xml('select count(*) as c from cron.job where jobname = ''report-purge''', false, true, '')))[1]::text as report_purge_jobs;
