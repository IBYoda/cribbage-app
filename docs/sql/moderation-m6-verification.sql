-- Moderation, slice M6: VERIFICATION of REPORTS
-- (docs/sql/moderation-m6-part1.sql).
--
-- Run in the Supabase Dashboard -> SQL Editor after part 1. The whole file
-- is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M6): precheck -> part 1 -> THIS FILE and
-- slice-e-grants-verification.sql -> regression suites -> app deploy (PR)
-- -> hand test.
--
-- It WRITES -- one temporary function in pg_temp (m6_as: runs one statement
-- as a client role and returns its result or its error), temporary accounts
-- in auth.users and their profiles, an admin_users row, a test table with
-- seats, avatar rows in storage.objects (rows only: no file is uploaded),
-- reports, attempt_log rows, a kick and a block; it calls report_player,
-- admin_list_reports, admin_delete_report, purge_old_reports, kick_player
-- and block_player_by_id -- and then deliberately raises an exception at the
-- very end, which rolls EVERY write back. A check that fails raises its own
-- exception at once, which rolls everything back the same way. It always
-- "fails": the message is the verdict.
--   "ALL 24 CHECKS PASSED (rolled back)." is a pass, possibly followed by
--   a note that the avatar date/size or the realtime.messages part of a
--   check could not be exercised here (the rest of that check still ran).
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives. now() is frozen inside a
-- DO block, so "an hour ago" / "a day ago" / "91 days ago" are made by
-- moving created_at back as the owner. Impersonation: request.jwt.claims
-- plus "set local role authenticated" (or anon), inside m6_as; "reset role"
-- to act as the owner.
--
-- STATE-AWARE: it checks only what M6 owns -- its table, its five
-- functions, its tenth attempt_log action (all ten present; a later slice
-- may add more), its cron job, its three client functions (the exact total
-- of 59 is slice-e-grants-verification.sql's job; here only "at least 59").
-- It fingerprints no other function: M3 and M1 are checked by behavior (a
-- kick and a block still work).
-- UPDATED FOR MODERATION M7 (moderation-m7-part1.sql): once
-- admin_report_chat(uuid) exists, K1 expects player_reports' twelve columns
-- plus chat, chat_status, chat_total, chat_kept, and K2 expects M7 part 1's
-- bodies of report_player (2dd85cea07caa56de74f5bfdef7d3b07) and admin_list_reports
-- (05e0e3809b944590a850ddc8ce259570); the other three are unchanged. Everything
-- else here holds as it is: report_player still mentions no realtime. (K3),
-- C13 reads admin_list_reports' columns by name, and these reports are filed
-- by people at no table (or as plain inserts), so their chat columns are
-- null or not_at_table.
--
-- PEOPLE: R (reports T, X, W), T (seated at T1, an avatar file), X (at no
-- table; avatar_url points into T's folder), W (an avatar file), U (a
-- second reporter; not an admin), AD (an admin), F (the hourly limit), D
-- (the daily cap), G (F's and D's target), H (T1's host) and K (seated at
-- T1; H kicks K), the easy computer account. T1: H's, public; H, T and K
-- seated.
--
-- WHAT IT CHECKS
--   K1  public.player_reports: columns, primary key (id), the reason, note
--       and not-self checks, NO foreign keys, the four indexes, RLS on, no
--       policies, NO privilege for PUBLIC, anon, authenticated or
--       service_role, not in supabase_realtime; attempt_log_action_check
--       allows all ten actions (report_filed included; at least ten).
--   K2  the five functions: part 1's bodies, security definer, search_path
--       ''; report_player, admin_list_reports, admin_delete_report
--       executable by authenticated only; _report_avatar_object and
--       purge_old_reports by no client role.
--   K3  the shapes the limits and "never broadcast" rely on: report_player
--       takes the lock key 'attempt_log:<reporter>:report_filed' and calls
--       _attempts_guard(v_actor, 'report_filed', 10, interval '1 hour', ...);
--       _attempts_guard still locks 'attempt_log:' || p_actor || ':' ||
--       p_action; no M6 body mentions realtime. or pg_notify.
--   C1  R reports T (behavior, from T1, a messy note): 'reported'; the row
--       (reporter, reported, reason, table T1, note cleaned to
--       "hi there x"); one report_filed row for R; NOTHING AUTOMATIC: no
--       block R->T, no kick of T, T still seated.
--   C2  C1's snapshot: R's and T's nicknames, T's avatar_url, and (when
--       storage rows can be written here) the avatar object's updated_at
--       and size 4321.
--   C3  the note and the avatar folder rule: R reports X with 250 "a"s ->
--       exactly 200; X's avatar_url points into T's folder -> no stamps. R
--       reports W with only spaces, a tab and a zero-width space -> null.
--   C4  the snapshot survives later changes: T's nickname, avatar_url and
--       avatar file change; C1's row keeps the old values.
--   C5  ONE A DAY PER PERSON: R reports T again (another reason, no table):
--       'already_reported', still one row, nothing counted. With C1's row
--       moved 25 hours back: 'reported' again.
--   C6  not_found: an unknown id; a null target. Nothing counted.
--   C7  not_allowed: R reports R; R reports the computer account; the
--       computer account reports T. Nothing counted, no row.
--   C8  errors: an unknown reason ('chat') and a null reason -> P0001
--       "Unknown report reason."; nobody logged in -> P0001 "You must be
--       logged in to report a player."; anon -> 42501. Nothing counted.
--   C9  a target at no table, and a table id that is no table: U reports X
--       with a random table id -> 'reported', table_id null. U reports T
--       from T1 (after C4) -> 'reported'.
--   C10 10 AN HOUR: F with 10 report_filed rows in the last hour -> 'limit',
--       no row, still 10; with the 10 moved 61 minutes back -> 'reported'.
--   C11 30 A DAY: D with 30 report_filed rows two hours ago (none in the
--       last hour) -> 'limit', no row; with one of them moved 25 hours back
--       (29 in the day) -> 'reported'.
--   C12 admin_list_reports access: U (not an admin) and nobody logged in ->
--       "Admins only."; anon -> 42501.
--   C13 admin_list_reports for AD: C1's row with R's snapshot and current
--       nickname, T's OLD snapshot nickname and NEW current nickname, T1's
--       code, picture_changed true (the url changed), R has filed 4, T has 3
--       against them; newest first (C1's row, 25 hours old, after U's
--       report on T); p_limit 0 gives one row.
--   C14 picture_changed: false for R->X (nothing changed) and for U->T
--       (taken after C4's change); for R->W true once W's avatar file has a
--       new date and size (when storage rows can be written here; otherwise
--       false).
--   C15 admin_delete_report: U -> "Admins only." (the row stays); AD
--       deletes U->X -> 'deleted', gone; again -> 'not_found'; null ->
--       'not_found'; U's report_filed rows stay.
--   C16 purge_old_reports (as the owner): a report filed 91 days ago is
--       deleted, one filed 89 days ago and today's stay; it returns at least
--       1; authenticated may not call it (42501).
--   C17 clients cannot touch public.player_reports: R's SELECT and INSERT
--       and anon's SELECT are each refused with 42501; R may not call
--       _report_avatar_object (42501).
--   C18 the pg_cron job report-purge: exactly one, '23 4 * * *', select
--       public.purge_old_reports();.
--   C19 EXECUTE: report_player, admin_list_reports, admin_delete_report for
--       authenticated; the helper and the purge for nobody; authenticated
--       may execute at least 59 functions in public.
--   C20 NEVER BROADCAST: no row in realtime.messages carries any test
--       reporter's or target's id (when this role can read it; K3 checks
--       the bodies regardless).
--   C21 M3 AND M1 STILL WORK: H kicks K at T1 -> 'kicked'; R blocks T with
--       block_player_by_id -> 'blocked'.

do $$
declare
  v_checks int := 0;
  v_expect int := 24;
  v_skips text := '';
  v_storage boolean := false;
  v_r uuid := gen_random_uuid();
  v_t uuid := gen_random_uuid();
  v_x uuid := gen_random_uuid();
  v_w uuid := gen_random_uuid();
  v_u uuid := gen_random_uuid();
  v_ad uuid := gen_random_uuid();
  v_f uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid();
  v_g uuid := gen_random_uuid();
  v_h uuid := gen_random_uuid();
  v_k uuid := gen_random_uuid();
  v_old_a uuid := gen_random_uuid();
  v_old_b uuid := gen_random_uuid();
  v_people uuid[];
  v_pid uuid;
  v_comp uuid;
  v_codes text[];
  v_t1 uuid;
  v_rep_c1 uuid;
  v_rep_rx uuid;
  v_rep_rw uuid;
  v_rep_ux uuid;
  v_rep_ut uuid;
  v_rep_old uuid;
  v_rep_young uuid;
  v_url_t text;
  v_url_t2 text;
  v_url_x text;
  v_url_w text;
  v_t_old_nick text;
  v_t_new_nick text;
  v_obj_at timestamptz;
  v_rec record;
  v_txt text;
  v_bad text;
  v_n int;
  v_n2 int;
  v_r1 text[];
  v_r2 text[];
  v_r3 text[];
  v_row text;
  v_row2 text;
begin
  -- ==== MODE ======================================================================
  if to_regclass('public.player_reports') is null or to_regprocedure('public.report_player(uuid, text, text, uuid)') is null then
    raise exception 'SETUP: part 1 is not in (no public.player_reports or report_player). Run docs/sql/moderation-m6-part1.sql first.';
  end if;

  -- m6_as(role, user, sql): runs one statement as that client role (the
  -- user as auth.uid(), or nobody when null) and returns
  -- {sqlstate, message, detail, hint, first column of the first row} --
  -- the error fields null when it worked. Rolled back with everything else.
  create function pg_temp.m6_as(p_role text, p_uid uuid, p_sql text)
  returns text[]
  language plpgsql
  as $f$
  declare
    v_res text;
    v_state text;
    v_msg text;
    v_detail text;
    v_hint text;
  begin
    perform set_config('request.jwt.claims',
      case when p_uid is null then json_build_object('role', p_role)::text
           else json_build_object('sub', p_uid, 'role', p_role)::text end, true);
    begin
      execute format('set local role %I', p_role);
      execute p_sql into v_res;
      execute 'reset role';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text,
                              v_detail = pg_exception_detail, v_hint = pg_exception_hint;
    end;
    execute 'reset role';
    return array[v_state, v_msg, v_detail, v_hint, v_res];
  end;
  $f$;

  -- ==== K: CATALOG ================================================================
  -- [K1] public.player_reports, and the ten attempt_log actions.
  v_bad := '';
  select string_agg(a.attname::text || ' ' || format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else '' end, ', ' order by a.attnum)
  into v_txt
  from pg_attribute a
  where a.attrelid = 'public.player_reports'::regclass and a.attnum > 0 and not a.attisdropped;
  if v_txt is distinct from 'id uuid not null, created_at timestamp with time zone not null, reporter_id uuid not null, reported_id uuid not null, reason text not null, note text, table_id uuid, reporter_nickname text, reported_nickname text, reported_avatar_url text, avatar_object_updated_at timestamp with time zone, avatar_object_size bigint'
                             || (case when to_regprocedure('public.admin_report_chat(uuid)') is not null
                                      then ', chat jsonb, chat_status text, chat_total integer, chat_kept integer' else '' end) then
    v_bad := v_bad || 'columns "' || coalesce(v_txt, '?') || '"; ';
  end if;
  if not exists (select 1 from pg_constraint con where con.conrelid = 'public.player_reports'::regclass and con.contype = 'p'
                   and pg_get_constraintdef(con.oid) = 'PRIMARY KEY (id)') then
    v_bad := v_bad || 'primary key; ';
  end if;
  if not exists (select 1 from pg_constraint con where con.conrelid = 'public.player_reports'::regclass and con.contype = 'c'
                   and con.conname = 'player_reports_reason_check'
                   and pg_get_constraintdef(con.oid) ~ '''nickname''' and pg_get_constraintdef(con.oid) ~ '''picture'''
                   and pg_get_constraintdef(con.oid) ~ '''behavior''') then
    v_bad := v_bad || 'player_reports_reason_check; ';
  end if;
  if not exists (select 1 from pg_constraint con where con.conrelid = 'public.player_reports'::regclass and con.contype = 'c'
                   and con.conname = 'player_reports_note_check' and pg_get_constraintdef(con.oid) ~ '200') then
    v_bad := v_bad || 'player_reports_note_check; ';
  end if;
  if not exists (select 1 from pg_constraint con where con.conrelid = 'public.player_reports'::regclass and con.contype = 'c'
                   and con.conname = 'player_reports_not_self' and pg_get_constraintdef(con.oid) = 'CHECK ((reporter_id <> reported_id))') then
    v_bad := v_bad || 'player_reports_not_self; ';
  end if;
  select count(*) into v_n from pg_constraint con where con.conrelid = 'public.player_reports'::regclass and con.contype = 'f';
  if v_n <> 0 then
    v_bad := v_bad || v_n::text || ' foreign key(s) (want none); ';
  end if;
  select count(*) into v_n
  from pg_index i
  where i.indrelid = 'public.player_reports'::regclass
    and i.indexrelid in (to_regclass('public.player_reports_created_at_idx'), to_regclass('public.player_reports_reported_idx'),
                         to_regclass('public.player_reports_reporter_idx'), to_regclass('public.player_reports_pair_idx'));
  if v_n <> 4 then
    v_bad := v_bad || v_n::text || ' of the four indexes; ';
  end if;
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.player_reports'::regclass) then
    v_bad := v_bad || 'RLS off; ';
  end if;
  select count(*) into v_n from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'player_reports';
  if v_n <> 0 then
    v_bad := v_bad || v_n::text || ' policies; ';
  end if;
  select string_agg(case a.grantee when 0 then 'PUBLIC' else pg_get_userbyid(a.grantee)::text end || ':' || a.privilege_type, ', ')
  into v_txt
  from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
  where c.oid = 'public.player_reports'::regclass
    and (a.grantee = 0 or a.grantee in (select r.oid from pg_roles r where r.rolname in ('anon', 'authenticated', 'service_role')));
  if v_txt is not null then
    v_bad := v_bad || 'client privileges ' || v_txt || '; ';
  end if;
  if exists (select 1 from pg_publication_tables pt where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = 'player_reports') then
    v_bad := v_bad || 'in supabase_realtime; ';
  end if;
  select pg_get_constraintdef(con.oid) into v_txt
  from pg_constraint con
  where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check';
  if v_txt is null or (length(v_txt) - length(replace(v_txt, '::text', ''))) / 6 < 10
     or v_txt !~ '''report_filed''' or v_txt !~ '''kick''' or v_txt !~ '''block_change''' or v_txt !~ '''follow_change'''
     or v_txt !~ '''game_start''' or v_txt !~ '''code_guess''' or v_txt !~ '''watch''' or v_txt !~ '''join'''
     or v_txt !~ '''create_computer_table''' or v_txt !~ '''create_table''' then
    v_bad := v_bad || 'attempt_log_action_check "' || coalesce(v_txt, 'missing') || '"; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K1] public.player_reports / attempt_log: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K2] The five functions.
  v_bad := '';
  for v_rec in
    select * from (values
      ('public._report_avatar_object(uuid, text)', '045267155656c63ce47b152cef6c9044', false),
      -- Moderation M7 part 1 replaces these two (STATE-AWARE).
      ('public.report_player(uuid, text, text, uuid)',
       case when to_regprocedure('public.admin_report_chat(uuid)') is not null then '2dd85cea07caa56de74f5bfdef7d3b07' else 'cbbe554a4e170379f8c6b7ac88b1cecc' end, true),
      ('public.admin_list_reports(integer)',
       case when to_regprocedure('public.admin_report_chat(uuid)') is not null then '05e0e3809b944590a850ddc8ce259570' else 'b2bcdc0cd74f7453e964ec3bc31c6998' end, true),
      ('public.admin_delete_report(uuid)', '77cd0a0d585977060ad7153baf64ff0f', true),
      ('public.purge_old_reports()', '62eaf1170d97a02e1783d7f0197a9767', false)
    ) as t(sig, lf, client)
  loop
    select v_rec.sig || ': '
           || case when md5(replace(p.prosrc, E'\r', '')) <> v_rec.lf then 'body md5 ' || md5(replace(p.prosrc, E'\r', '')) || ' ' else '' end
           || case when not p.prosecdef then 'not security definer ' else '' end
           || case when not (coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']) then 'search_path not empty ' else '' end
           || case when has_function_privilege('authenticated', p.oid, 'EXECUTE') <> v_rec.client then 'authenticated EXECUTE wrong ' else '' end
           || case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon EXECUTE ' else '' end
           || case when exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) then 'PUBLIC EXECUTE ' else '' end
           || case when exists (select 1 from pg_roles r where r.rolname = 'service_role')
                    and has_function_privilege('service_role', p.oid, 'EXECUTE') then 'service_role EXECUTE ' else '' end
    into v_txt
    from pg_proc p
    where p.oid = to_regprocedure(v_rec.sig);
    if v_txt is null then
      v_bad := v_bad || v_rec.sig || ' missing; ';
    elsif v_txt <> v_rec.sig || ': ' then
      v_bad := v_bad || v_txt || '; ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [K2] the M6 functions: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K3] The lock, the success row, and never a broadcast (the shapes).
  v_bad := '';
  select p.prosrc into v_txt from pg_proc p where p.oid = to_regprocedure('public.report_player(uuid, text, text, uuid)');
  if strpos(v_txt, 'pg_catalog.hashtextextended(''attempt_log:'' || v_actor::text || '':report_filed'', 0)') = 0 then
    v_bad := v_bad || 'report_player does not take the lock attempt_log:<reporter>:report_filed; ';
  end if;
  if strpos(v_txt, 'perform public._attempts_guard(v_actor, ''report_filed'', 10, interval ''1 hour'',') = 0 then
    v_bad := v_bad || 'report_player does not call _attempts_guard(v_actor, ''report_filed'', 10, interval ''1 hour'', ...); ';
  end if;
  select p.prosrc into v_txt from pg_proc p where p.oid = to_regprocedure('public._attempts_guard(uuid, text, integer, interval, text)');
  if v_txt is null or strpos(v_txt, '''attempt_log:'' || p_actor::text || '':'' || p_action') = 0 then
    v_bad := v_bad || '_attempts_guard no longer locks ''attempt_log:'' || p_actor || '':'' || p_action (report_player''s lock would not be the same); ';
  end if;
  select string_agg(p.proname::text, ', ' order by p.proname) into v_txt
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('_report_avatar_object', 'report_player', 'admin_list_reports', 'admin_delete_report', 'purge_old_reports')
    and (p.prosrc ilike '%realtime.%' or p.prosrc ilike '%pg_notify%');
  if v_txt is not null then
    v_bad := v_bad || 'these M6 bodies mention realtime. or pg_notify: ' || v_txt || '; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K3] %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner =========================================================
  v_people := array[v_r, v_t, v_x, v_w, v_u, v_ad, v_f, v_d, v_g, v_h, v_k];
  -- The project's own public avatars prefix: the live CHECK
  -- profiles_avatar_url_project_storage (spectators-join-or-watch.sql)
  -- allows only null, '' or an address under it with no "..".
  v_url_t := 'https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/avatars/' || v_t::text || '/avatar.png?t=1000';
  v_url_t2 := 'https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/avatars/' || v_t::text || '/avatar.png?t=2000';
  -- X's avatar_url points into T's folder: never looked up.
  v_url_x := 'https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/avatars/' || v_t::text || '/avatar.png?t=1000';
  v_url_w := 'https://forkgkkglcsvqoybdqcr.supabase.co/storage/v1/object/public/avatars/' || v_w::text || '/avatar.png?t=1000';
  v_t_old_nick := 'm6' || left(replace(v_t::text, '-', ''), 12);
  v_t_new_nick := 'm6new' || left(replace(v_t::text, '-', ''), 10);
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'm6-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      insert into public.profiles (id, nickname)
      values (v_pid, 'm6' || left(replace(v_pid::text, '-', ''), 12))
      on conflict (id) do update set nickname = excluded.nickname;
    end loop;
    update public.profiles set avatar_url = v_url_t where id = v_t;
    update public.profiles set avatar_url = v_url_x where id = v_x;
    update public.profiles set avatar_url = v_url_w where id = v_w;
    insert into public.admin_users (user_id) values (v_ad);
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts and profiles: % (%).', sqlerrm, sqlstate;
  end;

  select ca.user_id into v_comp from public.computer_accounts ca where ca.level = 'easy';
  if v_comp is null then
    raise exception 'SETUP: no easy computer account (computer-accounts-setup.sql).';
  end if;

  -- The avatar files (storage rows only). If this role can't write or read
  -- storage.objects here, the date/size parts of C2 and C14 are skipped.
  begin
    insert into storage.objects (bucket_id, name, metadata)
    values ('avatars', v_t::text || '/avatar.png', '{"size": 4321}'::jsonb),
           ('avatars', v_w::text || '/avatar.png', '{"size": 1111}'::jsonb);
    -- Read back as this role (the functions' owner): both rows must show.
    select count(*) into v_n
    from storage.objects o
    where o.bucket_id = 'avatars' and o.name in (v_t::text || '/avatar.png', v_w::text || '/avatar.png');
    v_storage := (v_n = 2);
    if not v_storage then
      v_skips := v_skips || ' Not checked here: the avatar date/size stamps (this role cannot read back storage.objects rows).';
    end if;
  exception when others then
    v_storage := false;
    v_skips := v_skips || ' Not checked here: the avatar date/size stamps (could not write test rows to storage.objects: ' || sqlerrm || ').';
  end;

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    -- Codes no OPEN table holds -- every table while tables_code_open_key
    -- doesn't exist (the predicate the other suites use).
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                        and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null))
    order by n
    limit 1
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 1 then
    raise exception 'SETUP: no free table code.';
  end if;

  begin
    -- T1: H's, public; H, T and K seated.
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[1], v_h, true, true, 4) returning id into v_t1;
    insert into public.table_members (table_id, user_id) values (v_t1, v_h);
    insert into public.table_members (table_id, user_id) values (v_t1, v_t);
    insert into public.table_members (table_id, user_id) values (v_t1, v_k);
  exception when others then
    raise exception 'SETUP: could not create the test table: % (%).', sqlerrm, sqlstate;
  end;

  -- ==== C: REPORT ===================================================================
  -- [C1] R reports T from T1, with a messy note.
  v_r1 := pg_temp.m6_as('authenticated', v_r, format('select public.report_player(%L, %L, %L, %L)',
            v_t, 'behavior', '  hi' || chr(10) || 'there' || chr(8238) || 'x  ', v_t1));
  select r.id into v_rep_c1 from public.player_reports r where r.reporter_id = v_r and r.reported_id = v_t;
  if v_r1[5] is distinct from 'reported'
     or (select count(*) from public.player_reports r where r.reporter_id = v_r and r.reported_id = v_t) <> 1
     or not exists (select 1 from public.player_reports r
                    where r.id = v_rep_c1 and r.reason = 'behavior' and r.table_id = v_t1 and r.note = 'hi there x')
     or (select count(*) from public.attempt_log al where al.user_id = v_r and al.action = 'report_filed') <> 1
     or exists (select 1 from public.blocks b where b.blocker_id = v_r and b.blocked_id = v_t)
     or exists (select 1 from public.table_kicks k where k.kicked_id = v_t)
     or not exists (select 1 from public.table_members tm where tm.table_id = v_t1 and tm.user_id = v_t) then
    raise exception 'FAIL [C1] R reporting T: % (error %), note "%"; expected reported, one row (behavior, T1, note "hi there x"), 1 report_filed row, and no block, no kick, T still seated.',
      coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none'), coalesce((select r.note from public.player_reports r where r.id = v_rep_c1), '-');
  end if;
  v_checks := v_checks + 1;

  -- [C2] C1's snapshot.
  -- (Inside IF, so storage.objects is only read when the setup could.)
  if v_storage then
    select o.updated_at into v_obj_at from storage.objects o where o.bucket_id = 'avatars' and o.name = v_t::text || '/avatar.png';
  end if;
  if not exists (
       select 1 from public.player_reports r
       where r.id = v_rep_c1
         and r.reporter_nickname = 'm6' || left(replace(v_r::text, '-', ''), 12)
         and r.reported_nickname = v_t_old_nick
         and r.reported_avatar_url = v_url_t
         and (not v_storage or (r.avatar_object_updated_at = v_obj_at and r.avatar_object_size = 4321)))
  then
    select concat_ws(' | ', r.reporter_nickname, r.reported_nickname, r.reported_avatar_url,
                     coalesce(r.avatar_object_updated_at::text, 'no date'), coalesce(r.avatar_object_size::text, 'no size'))
    into v_txt from public.player_reports r where r.id = v_rep_c1;
    raise exception 'FAIL [C2] C1''s snapshot is "%"; expected R''s and T''s nicknames, T''s avatar_url%.',
      coalesce(v_txt, '-'), case when v_storage then ', the object''s date and size 4321' else '' end;
  end if;
  v_checks := v_checks + 1;

  -- [C3] The note's 200-character cap, an all-blank note, and the folder rule.
  v_r1 := pg_temp.m6_as('authenticated', v_r, format('select public.report_player(%L, %L, %L, %L)', v_x, 'nickname', repeat('a', 250), null));
  v_r2 := pg_temp.m6_as('authenticated', v_r, format('select public.report_player(%L, %L, %L, %L)', v_w, 'picture',
            '   ' || chr(9) || chr(8203) || '  ', null));
  select r.id into v_rep_rx from public.player_reports r where r.reporter_id = v_r and r.reported_id = v_x;
  select r.id into v_rep_rw from public.player_reports r where r.reporter_id = v_r and r.reported_id = v_w;
  if v_r1[5] is distinct from 'reported' or v_r2[5] is distinct from 'reported'
     or not exists (select 1 from public.player_reports r
                    where r.id = v_rep_rx and r.note = repeat('a', 200) and r.table_id is null
                      and r.reported_avatar_url = v_url_x and r.avatar_object_updated_at is null and r.avatar_object_size is null)
     or not exists (select 1 from public.player_reports r where r.id = v_rep_rw and r.note is null and r.reason = 'picture')
     or (select count(*) from public.attempt_log al where al.user_id = v_r and al.action = 'report_filed') <> 3 then
    raise exception 'FAIL [C3] R reporting X (250 a''s) and W (blank note): % / % (errors % / %); expected reported twice, X''s note exactly 200 characters with no avatar stamps (the url is in T''s folder), W''s note null, 3 report_filed rows.',
      coalesce(v_r1[5], '-'), coalesce(v_r2[5], '-'), coalesce(v_r1[2], 'none'), coalesce(v_r2[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [C4] Later changes leave C1's snapshot alone.
  update public.profiles set nickname = v_t_new_nick, avatar_url = v_url_t2 where id = v_t;
  -- A new size as well as a new date: storage.objects' own update trigger
  -- may reset updated_at to now(), which is frozen in this block.
  if v_storage then
    update storage.objects o set updated_at = now() + interval '1 minute', metadata = '{"size": 5555}'::jsonb
    where o.bucket_id = 'avatars' and o.name = v_t::text || '/avatar.png';
  end if;
  if not exists (
       select 1 from public.player_reports r
       where r.id = v_rep_c1
         and r.reported_nickname = v_t_old_nick
         and r.reported_avatar_url = v_url_t
         and (not v_storage or (r.avatar_object_updated_at = v_obj_at and r.avatar_object_size = 4321))) then
    raise exception 'FAIL [C4] after T changed nickname and picture, C1''s snapshot changed too; it must keep the old values.';
  end if;
  v_checks := v_checks + 1;

  -- [C5] One a day per person, whatever the table.
  v_r1 := pg_temp.m6_as('authenticated', v_r, format('select public.report_player(%L, %L, %L, %L)', v_t, 'nickname', 'again', null));
  if v_r1[5] is distinct from 'already_reported'
     or (select count(*) from public.player_reports r where r.reporter_id = v_r and r.reported_id = v_t) <> 1
     or (select count(*) from public.attempt_log al where al.user_id = v_r and al.action = 'report_filed') <> 3 then
    raise exception 'FAIL [C5] R reporting T a second time within 24 hours: % (error %); expected already_reported, still one row, still 3 counted.',
      coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none');
  end if;
  update public.player_reports r set created_at = now() - interval '25 hours' where r.id = v_rep_c1;
  v_r1 := pg_temp.m6_as('authenticated', v_r, format('select public.report_player(%L, %L, %L, %L)', v_t, 'nickname', null, null));
  if v_r1[5] is distinct from 'reported'
     or (select count(*) from public.player_reports r where r.reporter_id = v_r and r.reported_id = v_t) <> 2
     or (select count(*) from public.attempt_log al where al.user_id = v_r and al.action = 'report_filed') <> 4 then
    raise exception 'FAIL [C5] R reporting T with the first report 25 hours old: % (error %); expected reported, 2 rows, 4 counted.',
      coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [C6] not_found.
  -- Rows filed by R or the computer account (never the whole table: real
  -- reports may arrive while this runs).
  select count(*) into v_n from public.player_reports r where r.reporter_id in (v_r, v_comp);
  v_r1 := pg_temp.m6_as('authenticated', v_r, format('select public.report_player(%L, %L, %L, %L)', gen_random_uuid(), 'behavior', null, null));
  v_r2 := pg_temp.m6_as('authenticated', v_r, format('select public.report_player(%L, %L, %L, %L)', null, 'behavior', null, null));
  if v_r1[5] is distinct from 'not_found' or v_r2[5] is distinct from 'not_found'
     or (select count(*) from public.player_reports r where r.reporter_id in (v_r, v_comp)) <> v_n
     or (select count(*) from public.attempt_log al where al.user_id = v_r and al.action = 'report_filed') <> 4 then
    raise exception 'FAIL [C6] unknown and null targets: % / % (errors % / %); expected not_found twice, nothing filed or counted.',
      coalesce(v_r1[5], '-'), coalesce(v_r2[5], '-'), coalesce(v_r1[2], 'none'), coalesce(v_r2[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [C7] not_allowed.
  v_r1 := pg_temp.m6_as('authenticated', v_r, format('select public.report_player(%L, %L, %L, %L)', v_r, 'behavior', null, null));
  v_r2 := pg_temp.m6_as('authenticated', v_r, format('select public.report_player(%L, %L, %L, %L)', v_comp, 'nickname', null, null));
  v_r3 := pg_temp.m6_as('authenticated', v_comp, format('select public.report_player(%L, %L, %L, %L)', v_t, 'behavior', null, null));
  if v_r1[5] is distinct from 'not_allowed' or v_r2[5] is distinct from 'not_allowed' or v_r3[5] is distinct from 'not_allowed'
     or (select count(*) from public.player_reports r where r.reporter_id in (v_r, v_comp)) <> v_n
     or (select count(*) from public.attempt_log al where al.user_id in (v_r, v_comp) and al.action = 'report_filed') <> 4 then
    raise exception 'FAIL [C7] yourself / a computer target / a computer caller: % / % / % (errors % / % / %); expected not_allowed three times, nothing filed or counted.',
      coalesce(v_r1[5], '-'), coalesce(v_r2[5], '-'), coalesce(v_r3[5], '-'), coalesce(v_r1[2], 'none'), coalesce(v_r2[2], 'none'), coalesce(v_r3[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [C8] Errors.
  v_bad := '';
  for v_rec in
    select * from (values
      ('reason chat', 'authenticated', v_r, 'chat', 'P0001', 'Unknown report reason.'),
      ('null reason', 'authenticated', v_r, null::text, 'P0001', 'Unknown report reason.'),
      ('nobody logged in', 'authenticated', null::uuid, 'behavior', 'P0001', 'You must be logged in to report a player.'),
      ('anon', 'anon', null::uuid, 'behavior', '42501', null::text)
    ) as t(label, role, who, reason, want_state, want_msg)
  loop
    v_r1 := pg_temp.m6_as(v_rec.role, v_rec.who, format('select public.report_player(%L, %L, %L, %L)', v_x, v_rec.reason, null, null));
    if v_r1[1] is distinct from v_rec.want_state or (v_rec.want_msg is not null and v_r1[2] is distinct from v_rec.want_msg) then
      v_bad := v_bad || v_rec.label || ': ' || coalesce(v_r1[1], 'ok') || ' ' || coalesce(v_r1[2], coalesce(v_r1[5], '-')) || '; ';
    end if;
  end loop;
  if v_bad <> ''
     or (select count(*) from public.player_reports r where r.reporter_id in (v_r, v_comp)) <> v_n
     or (select count(*) from public.attempt_log al where al.user_id = v_r and al.action = 'report_filed') <> 4 then
    raise exception 'FAIL [C8] errors: %expected P0001 "Unknown report reason." twice, P0001 "You must be logged in to report a player.", anon 42501; nothing filed or counted.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C9] A target at no table, a table id that is no table; and U reports T.
  v_r1 := pg_temp.m6_as('authenticated', v_u, format('select public.report_player(%L, %L, %L, %L)', v_x, 'behavior', 'left already', gen_random_uuid()));
  v_r2 := pg_temp.m6_as('authenticated', v_u, format('select public.report_player(%L, %L, %L, %L)', v_t, 'picture', null, v_t1));
  select r.id into v_rep_ux from public.player_reports r where r.reporter_id = v_u and r.reported_id = v_x;
  select r.id into v_rep_ut from public.player_reports r where r.reporter_id = v_u and r.reported_id = v_t;
  if v_r1[5] is distinct from 'reported' or v_r2[5] is distinct from 'reported'
     or not exists (select 1 from public.player_reports r where r.id = v_rep_ux and r.table_id is null and r.note = 'left already')
     or not exists (select 1 from public.player_reports r where r.id = v_rep_ut and r.table_id = v_t1
                      and r.reported_nickname = v_t_new_nick and r.reported_avatar_url = v_url_t2)
     or exists (select 1 from public.table_members tm where tm.user_id = v_x) then
    raise exception 'FAIL [C9] U reporting X (at no table; a random table id) and T: % / % (errors % / %); expected reported twice, X''s table_id null, T''s row with T1 and T''s new nickname and url.',
      coalesce(v_r1[5], '-'), coalesce(v_r2[5], '-'), coalesce(v_r1[2], 'none'), coalesce(v_r2[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [C10] 10 an hour.
  insert into public.attempt_log (user_id, action, success)
  select v_f, 'report_filed', true from generate_series(1, 10);
  v_r1 := pg_temp.m6_as('authenticated', v_f, format('select public.report_player(%L, %L, %L, %L)', v_g, 'behavior', null, null));
  if v_r1[5] is distinct from 'limit'
     or exists (select 1 from public.player_reports r where r.reporter_id = v_f)
     or (select count(*) from public.attempt_log al where al.user_id = v_f and al.action = 'report_filed') <> 10 then
    raise exception 'FAIL [C10] F''s 11th report in an hour: % (error %); expected limit, no row, still 10.', coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none');
  end if;
  update public.attempt_log al set created_at = now() - interval '61 minutes' where al.user_id = v_f and al.action = 'report_filed';
  v_r1 := pg_temp.m6_as('authenticated', v_f, format('select public.report_player(%L, %L, %L, %L)', v_g, 'behavior', null, null));
  if v_r1[5] is distinct from 'reported' then
    raise exception 'FAIL [C10] F''s report with the 10 moved 61 minutes back: % (error %); expected reported.', coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [C11] 30 a day.
  insert into public.attempt_log (user_id, action, success, created_at)
  select v_d, 'report_filed', true, now() - interval '2 hours' from generate_series(1, 30);
  v_r1 := pg_temp.m6_as('authenticated', v_d, format('select public.report_player(%L, %L, %L, %L)', v_g, 'nickname', null, null));
  if v_r1[5] is distinct from 'limit'
     or exists (select 1 from public.player_reports r where r.reporter_id = v_d)
     or (select count(*) from public.attempt_log al where al.user_id = v_d and al.action = 'report_filed') <> 30 then
    raise exception 'FAIL [C11] D''s 31st report in a day (none in the last hour): % (error %); expected limit, no row, still 30.', coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none');
  end if;
  update public.attempt_log al set created_at = now() - interval '25 hours'
  where al.id = (select a2.id from public.attempt_log a2 where a2.user_id = v_d and a2.action = 'report_filed' order by a2.id limit 1);
  v_r1 := pg_temp.m6_as('authenticated', v_d, format('select public.report_player(%L, %L, %L, %L)', v_g, 'nickname', null, null));
  if v_r1[5] is distinct from 'reported' then
    raise exception 'FAIL [C11] D''s report with 29 in the last 24 hours: % (error %); expected reported.', coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [C12] admin_list_reports: admins only.
  v_r1 := pg_temp.m6_as('authenticated', v_u, 'select count(*)::text from public.admin_list_reports(10)');
  v_r2 := pg_temp.m6_as('authenticated', null, 'select count(*)::text from public.admin_list_reports(10)');
  v_r3 := pg_temp.m6_as('anon', null, 'select count(*)::text from public.admin_list_reports(10)');
  if v_r1[2] is distinct from 'Admins only.' or v_r2[2] is distinct from 'Admins only.' or v_r3[1] is distinct from '42501' then
    raise exception 'FAIL [C12] admin_list_reports: non-admin %, nobody %, anon %; expected Admins only, Admins only, 42501.',
      coalesce(v_r1[2], coalesce(v_r1[5], '-')), coalesce(v_r2[2], coalesce(v_r2[5], '-')), coalesce(v_r3[1], 'ok');
  end if;
  v_checks := v_checks + 1;

  -- [C13] admin_list_reports: C1's row, the counts, newest first, the cap.
  v_row := (pg_temp.m6_as('authenticated', v_ad, format(
    'select concat_ws(''|'', coalesce(l.reporter_nickname, ''-''), coalesce(l.reporter_nickname_now, ''-''), coalesce(l.reported_nickname, ''-''), coalesce(l.reported_nickname_now, ''-''), coalesce(l.table_code, ''-''), coalesce(l.picture_changed::text, ''-''), l.reporter_report_count::text, l.reported_report_count::text, l.ordinality::text) from public.admin_list_reports(500) with ordinality l where l.id = %L',
    v_rep_c1)))[5];
  v_row2 := (pg_temp.m6_as('authenticated', v_ad, format(
    'select l.ordinality::text from public.admin_list_reports(500) with ordinality l where l.id = %L', v_rep_ut)))[5];
  v_r1 := pg_temp.m6_as('authenticated', v_ad, 'select count(*)::text from public.admin_list_reports(0)');
  v_r2 := pg_temp.m6_as('authenticated', v_ad, 'select bool_and(s.prev is null or s.prev >= s.created_at)::text from (select l.created_at, lag(l.created_at) over (order by l.ordinality) as prev from public.admin_list_reports(500) with ordinality l) s');
  if v_row is null
     or split_part(v_row, '|', 1) <> 'm6' || left(replace(v_r::text, '-', ''), 12)
     or split_part(v_row, '|', 2) <> 'm6' || left(replace(v_r::text, '-', ''), 12)
     or split_part(v_row, '|', 3) <> v_t_old_nick
     or split_part(v_row, '|', 4) <> v_t_new_nick
     or split_part(v_row, '|', 5) <> v_codes[1]
     or split_part(v_row, '|', 6) <> 'true'
     or split_part(v_row, '|', 7) <> '4'
     or split_part(v_row, '|', 8) <> '3'
     or v_row2 is null
     or split_part(v_row, '|', 9)::int <= v_row2::int
     or v_r1[5] is distinct from '1'
     or v_r2[5] is distinct from 'true' then
    raise exception 'FAIL [C13] admin_list_reports: C1''s row "%" (U->T at position %), p_limit 0 gave % row(s), newest first %; expected R|R|T old|T new|T1''s code|true|4|3|after U->T, 1 row, true.',
      coalesce(v_row, '(not listed)'), coalesce(v_row2, '-'), coalesce(v_r1[5], coalesce(v_r1[2], '-')), coalesce(v_r2[5], coalesce(v_r2[2], '-'));
  end if;
  v_checks := v_checks + 1;

  -- [C14] picture_changed. W's file gets a new size as well as a new date
  -- (storage.objects' own update trigger may reset updated_at to the frozen
  -- now(), so the date alone might not change).
  if v_storage then
    update storage.objects o set updated_at = now() + interval '2 minutes', metadata = '{"size": 2222}'::jsonb
    where o.bucket_id = 'avatars' and o.name = v_w::text || '/avatar.png';
  end if;
  v_bad := '';
  for v_rec in
    select * from (values
      ('R->X (nothing changed)', v_rep_rx, 'false'),
      ('U->T (taken after the change)', v_rep_ut, 'false'),
      ('R->W (the file got a new date and size)', v_rep_rw, case when v_storage then 'true' else 'false' end)
    ) as t(label, rid, want)
  loop
    v_txt := (pg_temp.m6_as('authenticated', v_ad, format(
      'select l.picture_changed::text from public.admin_list_reports(500) l where l.id = %L', v_rec.rid)))[5];
    if v_txt is distinct from v_rec.want then
      v_bad := v_bad || v_rec.label || ': ' || coalesce(v_txt, '(not listed)') || ' (want ' || v_rec.want || '); ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [C14] picture_changed: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C15] admin_delete_report.
  v_r1 := pg_temp.m6_as('authenticated', v_u, format('select public.admin_delete_report(%L)', v_rep_ux));
  v_n := (select count(*) from public.player_reports r where r.id = v_rep_ux);
  v_r2 := pg_temp.m6_as('authenticated', v_ad, format('select public.admin_delete_report(%L)', v_rep_ux));
  v_n2 := (select count(*) from public.player_reports r where r.id = v_rep_ux);
  v_r3 := pg_temp.m6_as('authenticated', v_ad, format('select public.admin_delete_report(%L)', v_rep_ux));
  v_txt := (pg_temp.m6_as('authenticated', v_ad, format('select public.admin_delete_report(%L)', null)))[5];
  if v_r1[2] is distinct from 'Admins only.' or v_n <> 1
     or v_r2[5] is distinct from 'deleted' or v_n2 <> 0
     or v_r3[5] is distinct from 'not_found' or v_txt is distinct from 'not_found'
     or (select count(*) from public.attempt_log al where al.user_id = v_u and al.action = 'report_filed') <> 2 then
    raise exception 'FAIL [C15] admin_delete_report: U % (row left %), AD % (left %), again %, null %; expected Admins only (1 left), deleted (0 left), not_found, not_found, U''s 2 report_filed rows kept.',
      coalesce(v_r1[2], coalesce(v_r1[5], '-')), v_n, coalesce(v_r2[5], coalesce(v_r2[2], '-')), v_n2, coalesce(v_r3[5], coalesce(v_r3[2], '-')), coalesce(v_txt, '-');
  end if;
  v_checks := v_checks + 1;

  -- [C16] purge_old_reports: 90 days. No foreign keys, so plain ids will do.
  insert into public.player_reports (reporter_id, reported_id, reason, created_at)
  values (v_old_a, v_old_b, 'behavior', now() - interval '91 days') returning id into v_rep_old;
  insert into public.player_reports (reporter_id, reported_id, reason, created_at)
  values (v_old_b, v_old_a, 'behavior', now() - interval '89 days') returning id into v_rep_young;
  v_r1 := pg_temp.m6_as('authenticated', v_ad, 'select public.purge_old_reports()::text');
  v_n := public.purge_old_reports();
  if v_n < 1
     or exists (select 1 from public.player_reports r where r.id = v_rep_old)
     or not exists (select 1 from public.player_reports r where r.id = v_rep_young)
     or not exists (select 1 from public.player_reports r where r.id = v_rep_ut)
     or not exists (select 1 from public.player_reports r where r.id = v_rep_c1)
     or v_r1[1] is distinct from '42501' then
    raise exception 'FAIL [C16] purge_old_reports returned % (want at least 1); the 91-day report gone %, the 89-day one kept %, today''s kept %; authenticated calling it: % (want 42501).',
      v_n, not exists (select 1 from public.player_reports r where r.id = v_rep_old),
      exists (select 1 from public.player_reports r where r.id = v_rep_young),
      exists (select 1 from public.player_reports r where r.id = v_rep_ut), coalesce(v_r1[1], 'ok');
  end if;
  v_checks := v_checks + 1;

  -- [C17] Clients cannot touch public.player_reports or the helper.
  v_bad := '';
  for v_rec in
    select * from (values
      ('R SELECT', 'authenticated', v_r, 'select count(*)::text from public.player_reports'),
      ('R INSERT', 'authenticated', v_r, format('insert into public.player_reports (reporter_id, reported_id, reason) values (%L, %L, ''behavior'') returning ''x''', v_r, v_x)),
      ('anon SELECT', 'anon', null::uuid, 'select count(*)::text from public.player_reports'),
      ('R _report_avatar_object', 'authenticated', v_r, format('select o_size::text from public._report_avatar_object(%L, %L)', v_t, v_url_t2))
    ) as t(label, role, who, stmt)
  loop
    v_r1 := pg_temp.m6_as(v_rec.role, v_rec.who, v_rec.stmt);
    if v_r1[1] is distinct from '42501' then
      v_bad := v_bad || v_rec.label || ': ' || coalesce(v_r1[1], 'allowed') || '; ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [C17] clients touching player_reports or the helper: %expected 42501 each.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C18] The cron job (read through EXECUTE: this file parses without
  -- pg_cron; part 1 refused to run without it).
  if to_regclass('cron.job') is null then
    raise exception 'FAIL [C18] pg_cron is not installed, so the report-purge job cannot exist.';
  end if;
  execute 'select count(*)::int from cron.job j where j.jobname::text = $1' into v_n using 'report-purge';
  execute 'select count(*)::int from cron.job j where j.jobname::text = $1 and j.schedule::text = $2 and j.command::text = $3'
    into v_n2 using 'report-purge', '23 4 * * *', 'select public.purge_old_reports();';
  if v_n <> 1 or v_n2 <> 1 then
    raise exception 'FAIL [C18] pg_cron job report-purge: % job(s), % exactly as part 1 scheduled it (want 1 and 1: ''23 4 * * *'', select public.purge_old_reports();).', v_n, v_n2;
  end if;
  v_checks := v_checks + 1;

  -- [C19] EXECUTE for authenticated.
  select count(distinct p.proname) into v_n
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.prokind in ('f', 'p')
    and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
    and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  if not has_function_privilege('authenticated', 'public.report_player(uuid, text, text, uuid)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.admin_list_reports(integer)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.admin_delete_report(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public._report_avatar_object(uuid, text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.purge_old_reports()', 'EXECUTE')
     or v_n < 59 then
    raise exception 'FAIL [C19] EXECUTE: authenticated may execute % functions in public (want at least 59), and must have report_player, admin_list_reports, admin_delete_report but not _report_avatar_object or purge_old_reports.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [C20] Never broadcast (K3 checked the bodies).
  begin
    select count(*) into v_n
    from realtime.messages m
    where m.payload::text like any (array[
      '%' || v_r::text || '%', '%' || v_t::text || '%', '%' || v_x::text || '%', '%' || v_w::text || '%',
      '%' || v_u::text || '%', '%' || v_f::text || '%', '%' || v_d::text || '%', '%' || v_g::text || '%'])
       or m.topic ilike '%report%';
  exception when others then
    v_n := -1;
    v_skips := v_skips || ' Not checked here: the realtime.messages part of C20 (this role cannot read it: ' || sqlstate || ').';
  end;
  if v_n > 0 then
    raise exception 'FAIL [C20] % realtime.messages row(s) carry a reporter''s or target''s id (or a report topic): reports must never be broadcast.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [C21] M3's kick and M1/M2's block still work.
  v_r1 := pg_temp.m6_as('authenticated', v_h, format('select public.kick_player(%L, %L)', v_t1, v_k));
  v_r2 := pg_temp.m6_as('authenticated', v_r, format('select public.block_player_by_id(%L)', v_t));
  if v_r1[5] is distinct from 'kicked' or v_r2[5] is distinct from 'blocked' then
    raise exception 'FAIL [C21] H kicking K: % (error %); R blocking T: % (error %); expected kicked and blocked.',
      coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none'), coalesce(v_r2[5], '-'), coalesce(v_r2[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- ==== VERDICT =====================================================================
  -- 3 catalog (K1-K3) + 21 behaviour (C1-C21).
  if v_checks <> v_expect then
    raise exception 'FAIL: % checks ran, expected %.', v_checks, v_expect;
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back).%', v_checks, v_skips;
end;
$$;
