-- Moderation, slice M7: VERIFICATION of CHAT ATTACHED TO BEHAVIOR REPORTS
-- (docs/sql/moderation-m7-part1.sql).
--
-- Run in the Supabase Dashboard -> SQL Editor after part 1. The whole file
-- is ONE DO block.
--
-- STATUS: RUN 2026-11-28: ALL 20 CHECKS PASSED (rolled back; nothing kept).
--
-- DEPLOY ORDER (slice M7): precheck -> part 1 -> THIS FILE and
-- slice-e-grants-verification.sql -> the regression suites -> the app (a
-- later step).
--
-- It WRITES -- one temporary function in pg_temp (m7_as: runs one statement
-- as a client role and returns its result or its error) and one more
-- (m7_chat: stores one chat message exactly as send_table_message does,
-- through realtime.send), temporary accounts in auth.users and their
-- profiles, an admin_users row, five test tables with seats and spectators,
-- about 3,600 test broadcasts in realtime.messages, reports and attempt_log
-- rows; it replaces _report_table_chat with one that raises (C16, the last
-- check) -- and then deliberately raises an exception at the very end, which
-- rolls EVERY write back (the real _report_table_chat included). A check that
-- fails raises its own exception at once, which rolls everything back the
-- same way. It always "fails": the message is the verdict.
--   "ALL 20 CHECKS PASSED (rolled back)." is a pass.
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives. now() is frozen inside a
-- DO block, so every report filed here has created_at = now() and "25
-- hours ago" / "91 days ago" are made by moving created_at back as the
-- owner. Impersonation: request.jwt.claims plus "set local role
-- authenticated" (or anon), inside m7_as; "reset role" to act as the owner.
--
-- NEEDS: Realtime able to store a broadcast today (a realtime.messages
-- partition for today) and this role able to read it back -- the same as
-- send_table_message needs for every send. It probes first and stops at
-- SETUP otherwise.
--
-- THE CAP, TESTED WITH THE REAL LIMITS (no smaller temporary limit, so the
-- shipped constants are what is proven): T2 gets 2,050 short messages (the
-- 2,000-message limit binds: 2,000 kept, the oldest 50 dropped); T3 gets
-- 1,500 messages of exactly 140 ASCII characters (210,000 bytes: the
-- 204,800-byte limit binds first: floor(204800 / 140) = 1,462 kept, the
-- oldest 38 dropped). Both are rolled back.
--
-- STATE-AWARE: it checks what M7 owns (the four columns and two
-- constraints, its two new functions, its block in report_player, the two
-- new admin_list_reports columns) and fingerprints the bodies it relies on
-- or leaves alone ("others": send_table_message, _report_avatar_object,
-- admin_delete_report, purge_old_reports). The exact count of 61 client
-- functions is slice-e-grants-verification.sql's job; here "at least 61".
--
-- PEOPLE: H (T1's host, seated), T (seated at T1; the usual target), R
-- (seated at T1; reports T), L (seated at T1, chats, then LEAVES; K reports
-- L), K (seated at T1 after L left), S (current spectator of T1; reports T),
-- Z (spectator of T1 last seen 2 minutes ago), Q (removed spectator of T1),
-- O (at no table), W (at no table; behavior report with no table), P
-- (current spectator of T1; nickname and picture reports), Y (current
-- spectator of T1; the refused second report), E (current spectator of T1;
-- the fail-open report), F (current spectator of T1; the hourly limit), D
-- (current spectator of T1; the daily cap), N (seated at T4, which has no
-- chat), C2 (seated at T2: 2,050 messages), C3 (seated at T3: 1,500 long
-- messages), U (not an admin), AD (an admin), the easy computer account; G
-- is only a sender id with NO account (a deleted account's old lines). T9
-- holds one chat line of another table.
--
-- WHAT IT CHECKS
--   K1  public.player_reports: M6's twelve columns plus chat jsonb,
--       chat_status text, chat_total integer, chat_kept integer (in that
--       order); player_reports_chat_status_check (the four values) and
--       player_reports_chat_check; still NO foreign keys, RLS on, no
--       policies, NO privilege for PUBLIC, anon, authenticated or
--       service_role, not in supabase_realtime.
--   K2  the bodies: report_player, admin_list_reports, admin_report_chat and
--       _report_table_chat are part 1's; the others are unchanged
--       (send_table_message M5c1's; _report_avatar_object, admin_delete_report,
--       purge_old_reports M6's); all security definer with search_path '';
--       EXECUTE for authenticated exactly on report_player,
--       admin_list_reports, admin_report_chat, send_table_message,
--       admin_delete_report; never anon, PUBLIC or service_role;
--       _report_table_chat runs with TimeZone UTC.
--   K3  the shapes: report_player with its one (M7) block removed is M6 part
--       1's body byte for byte (md5 cbbe554a4e170379f8c6b7ac88b1cecc); the
--       block appears once, after the insert and before "return 'reported'";
--       report_player never mentions realtime. (moderation-m6-verification
--       K3 still holds); admin_list_reports' result is M6's sixteen columns
--       plus chat_status text, chat_total integer; admin_report_chat's
--       result is chat_status, chat_total, chat_kept, chat; no M7 body calls
--       realtime.send or pg_notify; the helper reads realtime.messages with
--       the broadcast / private / topic / event / 5-day predicates and the
--       2,000 / 204,800 limits.
--   K4  EXECUTE: admin_report_chat for authenticated, _report_table_chat for
--       nobody; authenticated may execute at least 61 functions in public.
--   C1  THE COPY: R (seated at T1) reports T for behavior from T1 ->
--       'reported'; chat_status copied, chat_total 6, chat_kept 6; the lines
--       in "at" order (one was sent out of order), each with s and at; people
--       has T, L, R and S with their nicknames and G with null (no
--       account); one report_filed row for R.
--   C2  ONLY CHAT IS COPIED: none of T1's table, game or scores events, its
--       non-private chat, its malformed chat (an "at" that is not a number, a
--       141-character text, a sender that is not a uuid), nor T9's chat
--       appears in C1's copy.
--   C3  NICKNAMES AT FILING: T renames after C1; C1's people still has T's
--       old nickname.
--   C4  A SPECTATOR REPORTER: S (current spectator of T1) reports T ->
--       copied, the same six lines.
--   C5  THE REPORTED PERSON HAS LEFT: K (seated) reports L (who left T1) ->
--       'reported', copied, L's line included, L not seated.
--   C6  NOT AT THE TABLE: O (at no table), Z (last seen 2 minutes ago) and Q
--       (removed) each report T from T1; U reports L from a table id that is
--       no table; W reports T with no table -> 'reported' each, chat_status
--       not_at_table, the other three null; each counted once.
--   C7  NICKNAME AND PICTURE REPORTS: P (current spectator of T1) reports T
--       (nickname) and L (picture) from T1 -> the four chat columns null.
--   C8  NO CHAT STORED: N (seated at T4) reports T from T4 -> none, 0, 0,
--       chat null.
--   C9  THE MESSAGE CAP: C2 reports T from T2 (2,050 messages) -> total
--       2050, kept 2000, the first line is message 51 and the last 2050, in
--       ascending "at" order.
--   C10 THE BYTE CAP: C3 reports T from T3 (1,500 x 140 bytes) -> total 1500,
--       kept 1462, the first line is message 39 and the last 1500; the kept
--       text is 204,680 bytes (one more line would pass 204,800).
--   C11 admin_report_chat: U and nobody logged in -> "Admins only."; anon ->
--       42501; AD gets C1's status, counts and chat exactly as stored; P's
--       nickname report -> one row of nulls; an unknown id -> no row.
--   C12 admin_list_reports for AD: C1's row copied / 6, C9's copied / 2050,
--       C8's none / 0, O's not_at_table / null, P's nickname report null /
--       null.
--   C13 admin_delete_report removes the chat: AD deletes C5's report ->
--       'deleted'; no row with that id remains.
--   C14 purge_old_reports removes the chat: C4's report moved 91 days back
--       is purged; C1's stays.
--   C15 EVERY M6 LIMIT AND ANSWER UNCHANGED, AND A REFUSED REPORT COPIES
--       NOTHING: Y reports T (copied), then again -> 'already_reported', one
--       row, its chat unchanged, Y counted once; F with 10 report_filed rows
--       in the hour -> 'limit', no row (then moved 61 minutes back ->
--       'reported', copied); D with 30 in the day -> 'limit', no row;
--       not_found (unknown id, null), not_allowed (yourself, a computer
--       target, a computer caller), "Unknown report reason.", "You must be
--       logged in to report a player.", anon 42501 -- none filed or counted.
--   C16 FAIL OPEN (run last): _report_table_chat replaced with one that
--       raises; E (current spectator of T1) reports T -> 'reported', filed
--       with chat_status unavailable and the other three null, counted once.

do $$
declare
  v_checks int := 0;
  v_expect int := 20;
  v_h uuid := gen_random_uuid();
  v_t uuid := gen_random_uuid();
  v_r uuid := gen_random_uuid();
  v_l uuid := gen_random_uuid();
  v_k uuid := gen_random_uuid();
  v_s uuid := gen_random_uuid();
  v_z uuid := gen_random_uuid();
  v_q uuid := gen_random_uuid();
  v_o uuid := gen_random_uuid();
  v_w uuid := gen_random_uuid();
  v_p uuid := gen_random_uuid();
  v_y uuid := gen_random_uuid();
  v_e uuid := gen_random_uuid();
  v_f uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid();
  v_n uuid := gen_random_uuid();
  v_c2 uuid := gen_random_uuid();
  v_c3 uuid := gen_random_uuid();
  v_u uuid := gen_random_uuid();
  v_ad uuid := gen_random_uuid();
  v_g uuid := gen_random_uuid();
  v_people uuid[];
  v_pid uuid;
  v_comp uuid;
  v_codes text[];
  v_t1 uuid;
  v_t2 uuid;
  v_t3 uuid;
  v_t4 uuid;
  v_t9 uuid;
  v_base bigint;
  v_probe text;
  v_rep_c1 uuid;
  v_rep_s uuid;
  v_rep_k uuid;
  v_rep_p uuid;
  v_rep_n uuid;
  v_rep_o uuid;
  v_rep_c2 uuid;
  v_rep_y uuid;
  v_t_old_nick text;
  v_chat_before text;
  v_rec record;
  v_txt text;
  v_bad text;
  v_i int;
  v_c int;
  v_c2n int;
  v_r1 text[];
  v_r2 text[];
  v_r3 text[];
  v_row text;
begin
  -- ==== MODE ======================================================================
  if to_regprocedure('public.admin_report_chat(uuid)') is null
     or to_regprocedure('public._report_table_chat(uuid)') is null
     or not exists (select 1 from pg_attribute a where a.attrelid = to_regclass('public.player_reports') and a.attname = 'chat_status' and not a.attisdropped) then
    raise exception 'SETUP: part 1 is not in (no admin_report_chat, _report_table_chat or player_reports.chat_status). Run docs/sql/moderation-m7-part1.sql first.';
  end if;

  -- m7_as(role, user, sql): runs one statement as that client role (the
  -- user as auth.uid(), or nobody when null) and returns
  -- {sqlstate, message, detail, hint, first column of the first row} --
  -- the error fields null when it worked. Rolled back with everything else.
  create function pg_temp.m7_as(p_role text, p_uid uuid, p_sql text)
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

  -- m7_chat(table, sender, text, at): one chat message stored exactly as
  -- send_table_message stores it (realtime.send, event chat, private).
  create function pg_temp.m7_chat(p_table uuid, p_sender uuid, p_text text, p_at bigint)
  returns void
  language plpgsql
  as $f$
  begin
    perform realtime.send(jsonb_build_object('event', 'chat', 'id', gen_random_uuid(), 'sender_id', p_sender,
                                             'text', p_text, 'at', p_at),
                          'chat', 'table:' || p_table::text, true);
  end;
  $f$;

  -- ==== K: CATALOG ================================================================
  -- [K1] public.player_reports.
  v_bad := '';
  select string_agg(a.attname::text || ' ' || format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else '' end, ', ' order by a.attnum)
  into v_txt
  from pg_attribute a
  where a.attrelid = 'public.player_reports'::regclass and a.attnum > 0 and not a.attisdropped;
  if v_txt is distinct from 'id uuid not null, created_at timestamp with time zone not null, reporter_id uuid not null, reported_id uuid not null, reason text not null, note text, table_id uuid, reporter_nickname text, reported_nickname text, reported_avatar_url text, avatar_object_updated_at timestamp with time zone, avatar_object_size bigint, chat jsonb, chat_status text, chat_total integer, chat_kept integer' then
    v_bad := v_bad || 'columns "' || coalesce(v_txt, '?') || '"; ';
  end if;
  select pg_get_constraintdef(con.oid) into v_txt from pg_constraint con
  where con.conrelid = 'public.player_reports'::regclass and con.contype = 'c' and con.conname = 'player_reports_chat_status_check';
  if v_txt is null or v_txt !~ '''copied''' or v_txt !~ '''none''' or v_txt !~ '''not_at_table''' or v_txt !~ '''unavailable''' then
    v_bad := v_bad || 'player_reports_chat_status_check "' || coalesce(v_txt, 'missing') || '"; ';
  end if;
  select pg_get_constraintdef(con.oid) into v_txt from pg_constraint con
  where con.conrelid = 'public.player_reports'::regclass and con.contype = 'c' and con.conname = 'player_reports_chat_check';
  if v_txt is null or strpos(v_txt, '2000') = 0 or strpos(v_txt, 'behavior') = 0 or strpos(v_txt, 'chat_total >= chat_kept') = 0 then
    v_bad := v_bad || 'player_reports_chat_check "' || coalesce(v_txt, 'missing') || '"; ';
  end if;
  select count(*) into v_i from pg_constraint con where con.conrelid = 'public.player_reports'::regclass and con.contype = 'f';
  if v_i <> 0 then
    v_bad := v_bad || v_i::text || ' foreign key(s) (want none); ';
  end if;
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.player_reports'::regclass) then
    v_bad := v_bad || 'RLS off; ';
  end if;
  select count(*) into v_i from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'player_reports';
  if v_i <> 0 then
    v_bad := v_bad || v_i::text || ' policies; ';
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
  if v_bad <> '' then
    raise exception 'FAIL [K1] public.player_reports: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K2] The bodies (M7's four and the "others"), their settings and grants.
  v_bad := '';
  for v_rec in
    select * from (values
      ('public._report_table_chat(uuid)', 'ac6d3541b82212f87572fc729bf87359', false),
      ('public.report_player(uuid, text, text, uuid)', '2dd85cea07caa56de74f5bfdef7d3b07', true),
      ('public.admin_list_reports(integer)', '05e0e3809b944590a850ddc8ce259570', true),
      ('public.admin_report_chat(uuid)', '0c872a9e8da827c0b4289c9179d2dc3f', true),
      ('public.send_table_message(uuid, text)', 'e3adcc4874c77c1c47530a807fefd815', true),
      ('public._report_avatar_object(uuid, text)', '045267155656c63ce47b152cef6c9044', false),
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
  if not exists (select 1 from pg_proc p where p.oid = to_regprocedure('public._report_table_chat(uuid)')
                   and exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where lower(c) = 'timezone=utc')) then
    v_bad := v_bad || '_report_table_chat does not run with TimeZone UTC; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K2] the bodies: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K3] The shapes.
  v_bad := '';
  select replace(p.prosrc, E'\r', '') into v_txt from pg_proc p where p.oid = to_regprocedure('public.report_player(uuid, text, text, uuid)');
  if (length(v_txt) - length(replace(v_txt, '-- ==== (M7) ', ''))) / length('-- ==== (M7) ') <> 1
     or (length(v_txt) - length(replace(v_txt, '-- ==== end (M7) ====', ''))) / length('-- ==== end (M7) ====') <> 1 then
    v_bad := v_bad || 'report_player has not exactly one (M7) block; ';
  elsif md5(left(v_txt, strpos(v_txt, '  -- ==== (M7) ') - 1)
            || substr(v_txt, strpos(v_txt, '  -- ==== end (M7) ====' || chr(10) || chr(10)) + length('  -- ==== end (M7) ====') + 2))
        <> 'cbbe554a4e170379f8c6b7ac88b1cecc' then
    v_bad := v_bad || 'report_player without its (M7) block is not M6 part 1''s body (md5 cbbe554a4e170379f8c6b7ac88b1cecc); ';
  elsif not (strpos(v_txt, 'insert into public.player_reports (') < strpos(v_txt, '  -- ==== (M7) ')
             and strpos(v_txt, '  -- ==== end (M7) ====') < strpos(v_txt, '  return ''reported'';')) then
    v_bad := v_bad || 'the (M7) block is not between the insert and return ''reported''; ';
  end if;
  if v_txt ilike '%realtime.%' or v_txt ilike '%pg_notify%' then
    v_bad := v_bad || 'report_player mentions realtime. or pg_notify (moderation-m6-verification K3 would fail); ';
  end if;
  select pg_get_function_result(to_regprocedure('public.admin_list_reports(integer)')) into v_txt;
  if v_txt is distinct from 'TABLE(id uuid, created_at timestamp with time zone, reason text, note text, table_id uuid, table_code text, reporter_id uuid, reporter_nickname text, reporter_nickname_now text, reported_id uuid, reported_nickname text, reported_nickname_now text, reported_avatar_url text, picture_changed boolean, reporter_report_count integer, reported_report_count integer, chat_status text, chat_total integer)' then
    v_bad := v_bad || 'admin_list_reports returns "' || coalesce(v_txt, '?') || '"; ';
  end if;
  select pg_get_function_result(to_regprocedure('public.admin_report_chat(uuid)')) into v_txt;
  if v_txt is distinct from 'TABLE(chat_status text, chat_total integer, chat_kept integer, chat jsonb)' then
    v_bad := v_bad || 'admin_report_chat returns "' || coalesce(v_txt, '?') || '"; ';
  end if;
  select string_agg(p.proname::text, ', ' order by p.proname) into v_txt
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('_report_table_chat', 'report_player', 'admin_list_reports', 'admin_report_chat')
    and (p.prosrc ilike '%realtime.send%' or p.prosrc ilike '%pg_notify%');
  if v_txt is not null then
    v_bad := v_bad || 'these M7 bodies call realtime.send or pg_notify: ' || v_txt || '; ';
  end if;
  select replace(p.prosrc, E'\r', '') into v_txt from pg_proc p where p.oid = to_regprocedure('public._report_table_chat(uuid)');
  if strpos(v_txt, 'from realtime.messages m') = 0
     or strpos(v_txt, 'm.extension = ''broadcast''') = 0
     or strpos(v_txt, 'm.private = true') = 0
     or strpos(v_txt, 'm.topic = ''table:'' || p_table_id::text') = 0
     or strpos(v_txt, 'm.inserted_at > now() - interval ''5 days''') = 0
     or strpos(v_txt, 'm.payload ->> ''event'' = ''chat''') = 0
     or strpos(v_txt, 'r.rn <= 2000') = 0
     or strpos(v_txt, 'r.bytes <= 204800') = 0 then
    v_bad := v_bad || '_report_table_chat lacks one of its predicates or limits; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K3] %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K4] EXECUTE.
  select count(distinct p.proname) into v_i
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.prokind in ('f', 'p')
    and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
    and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  if not has_function_privilege('authenticated', 'public.admin_report_chat(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public._report_table_chat(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.admin_report_chat(uuid)', 'EXECUTE')
     or v_i < 61 then
    raise exception 'FAIL [K4] EXECUTE: authenticated may execute % functions in public (want at least 61), and must have admin_report_chat but not _report_table_chat (anon neither).', v_i;
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP: can Realtime store, and can this role read it back? ==============
  v_probe := 'table:' || gen_random_uuid()::text;
  begin
    perform realtime.send(jsonb_build_object('event', 'm7-probe'), 'm7-probe', v_probe, true);
    select count(*) into v_i from realtime.messages m where m.topic = v_probe and m.extension = 'broadcast' and m.private = true;
  exception when others then
    raise exception 'SETUP: could not send or read a test broadcast: % (%).', sqlerrm, sqlstate;
  end;
  if v_i <> 1 then
    raise exception 'SETUP: Realtime did not store a test broadcast (usually: no realtime.messages partition for today, or this role cannot read past its row-level security). While that lasts send_table_message refuses every message too. See moderation-m7-precheck.sql''s realtime rows.';
  end if;

  -- ==== SETUP: people and tables, as the owner =====================================
  select ca.user_id into v_comp from public.computer_accounts ca where ca.level = 'easy';
  if v_comp is null then
    raise exception 'SETUP: no easy computer account (computer-accounts-setup.sql).';
  end if;

  v_people := array[v_h, v_t, v_r, v_l, v_k, v_s, v_z, v_q, v_o, v_w, v_p, v_y, v_e, v_f, v_d, v_n, v_c2, v_c3, v_u, v_ad];
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'm7-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      insert into public.profiles (id, nickname)
      values (v_pid, 'm7' || left(replace(v_pid::text, '-', ''), 12))
      on conflict (id) do update set nickname = excluded.nickname;
    end loop;
    insert into public.admin_users (user_id) values (v_ad);
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts and profiles: % (%).', sqlerrm, sqlstate;
  end;
  v_t_old_nick := 'm7' || left(replace(v_t::text, '-', ''), 12);

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    -- Codes no OPEN table holds -- every table while tables_code_open_key
    -- doesn't exist (the predicate the other suites use).
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                        and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null))
    order by n
    limit 5
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 5 then
    raise exception 'SETUP: fewer than five free table codes.';
  end if;

  begin
    -- T1: H's, public, spectators allowed. H, T, L, R seated; L leaves; K
    -- takes the seat. S, P, Y, E, F, D current spectators; Z stale; Q removed.
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[1], v_h, true, true, 4) returning id into v_t1;
    insert into public.table_members (table_id, user_id) values (v_t1, v_h);
    insert into public.table_members (table_id, user_id) values (v_t1, v_t);
    insert into public.table_members (table_id, user_id) values (v_t1, v_l);
    insert into public.table_members (table_id, user_id) values (v_t1, v_r);
    foreach v_pid in array array[v_s, v_p, v_y, v_e, v_f, v_d] loop
      insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at) values (v_t1, v_pid, now(), now());
    end loop;
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at)
    values (v_t1, v_z, now() - interval '10 minutes', now() - interval '2 minutes');
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at, removed_at)
    values (v_t1, v_q, now() - interval '5 minutes', now(), now());
    -- T2 (C2's), T3 (C3's), T4 (N's): one seat each. T9: H's, no seat.
    insert into public.tables (code, created_by, is_public, max_players) values (v_codes[2], v_c2, true, 2) returning id into v_t2;
    insert into public.table_members (table_id, user_id) values (v_t2, v_c2);
    insert into public.tables (code, created_by, is_public, max_players) values (v_codes[3], v_c3, true, 2) returning id into v_t3;
    insert into public.table_members (table_id, user_id) values (v_t3, v_c3);
    insert into public.tables (code, created_by, is_public, max_players) values (v_codes[4], v_n, true, 2) returning id into v_t4;
    insert into public.table_members (table_id, user_id) values (v_t4, v_n);
    insert into public.tables (code, created_by, is_public, max_players) values (v_codes[5], v_h, true, 2) returning id into v_t9;
  exception when others then
    raise exception 'SETUP: could not create the test tables: % (%).', sqlerrm, sqlstate;
  end;

  -- ==== SETUP: the chat ============================================================
  -- T1: six chat lines (the fifth sent last, to prove "at" decides the
  -- order), from T, L, R, S and G (no account).
  v_base := floor(extract(epoch from now()) * 1000)::bigint - 600000;
  perform pg_temp.m7_chat(v_t1, v_t, 'hello from T', v_base + 1000);
  perform pg_temp.m7_chat(v_t1, v_l, 'L here before leaving', v_base + 2000);
  perform pg_temp.m7_chat(v_t1, v_r, 'R says hi', v_base + 3000);
  perform pg_temp.m7_chat(v_t1, v_s, 'spectator S', v_base + 4000);
  perform pg_temp.m7_chat(v_t1, v_t, 'T again', v_base + 6000);
  perform pg_temp.m7_chat(v_t1, v_g, 'ghost line', v_base + 5000);
  -- T1: what must NOT be copied.
  perform realtime.send(jsonb_build_object('event', 'table', 'table_id', v_t1, 'roster_version', 1, 'text', 'NOT CHAT table'), 'table', 'table:' || v_t1::text, true);
  perform realtime.send(jsonb_build_object('event', 'game', 'sender_id', v_t, 'text', 'NOT CHAT game', 'at', v_base + 1500), 'game', 'table:' || v_t1::text, true);
  perform realtime.send(jsonb_build_object('event', 'scores', 'sender_id', v_t, 'text', 'NOT CHAT scores', 'at', v_base + 1600), 'scores', 'table:' || v_t1::text, true);
  perform realtime.send(jsonb_build_object('event', 'chat', 'id', gen_random_uuid(), 'sender_id', v_t, 'text', 'NOT CHAT public', 'at', v_base + 1700),
                        'chat', 'table:' || v_t1::text, false);
  perform realtime.send(jsonb_build_object('event', 'chat', 'id', gen_random_uuid(), 'sender_id', v_t, 'text', 'NOT CHAT bad at', 'at', 'soon'),
                        'chat', 'table:' || v_t1::text, true);
  perform realtime.send(jsonb_build_object('event', 'chat', 'id', gen_random_uuid(), 'sender_id', v_t, 'text', 'NOT CHAT long ' || repeat('y', 127), 'at', v_base + 1800),
                        'chat', 'table:' || v_t1::text, true);
  perform realtime.send(jsonb_build_object('event', 'chat', 'id', gen_random_uuid(), 'sender_id', 'not-a-uuid', 'text', 'NOT CHAT bad sender', 'at', v_base + 1900),
                        'chat', 'table:' || v_t1::text, true);
  perform pg_temp.m7_chat(v_t9, v_h, 'NOT CHAT other table', v_base + 2500);
  -- T2: 2,050 short messages (m1 .. m2050), C2 and T in turn.
  for v_i in 1..2050 loop
    perform pg_temp.m7_chat(v_t2, case when v_i % 2 = 0 then v_c2 else v_t end, 'm' || v_i::text, v_base + v_i);
  end loop;
  -- T3: 1,500 messages of exactly 140 ASCII characters.
  for v_i in 1..1500 loop
    perform pg_temp.m7_chat(v_t3, case when v_i % 2 = 0 then v_c3 else v_t end, lpad(v_i::text, 140, 'x'), v_base + v_i);
  end loop;
  -- Everything stored? (L leaves only after its line is there.)
  select count(*) filter (where m.topic = 'table:' || v_t1::text and m.payload ->> 'event' = 'chat' and m.private),
         count(*) filter (where m.topic = 'table:' || v_t2::text),
         count(*) filter (where m.topic = 'table:' || v_t3::text and m.payload ->> 'event' = 'chat')
  into v_i, v_c2n, v_c
  from realtime.messages m
  where m.extension = 'broadcast' and m.topic in ('table:' || v_t1::text, 'table:' || v_t2::text, 'table:' || v_t3::text);
  if v_i <> 9 or v_c2n < 2050 or v_c <> 1500 then
    raise exception 'SETUP: the test chat was not all stored (T1 private chat rows %, want 9 with the three malformed; T2 rows %, want at least 2050; T3 chat rows %, want 1500).', v_i, v_c2n, v_c;
  end if;
  -- L leaves T1; K takes the seat.
  delete from public.table_members tm where tm.table_id = v_t1 and tm.user_id = v_l;
  insert into public.table_members (table_id, user_id) values (v_t1, v_k);

  -- ==== C: THE COPY ================================================================
  -- [C1] R reports T from T1.
  v_r1 := pg_temp.m7_as('authenticated', v_r, format('select public.report_player(%L, %L, %L, %L)', v_t, 'behavior', 'rude', v_t1));
  select r.id into v_rep_c1 from public.player_reports r where r.reporter_id = v_r and r.reported_id = v_t;
  select string_agg(e.v ->> 'text', '|' order by e.n) into v_txt
  from public.player_reports r, jsonb_array_elements(r.chat -> 'lines') with ordinality e(v, n)
  where r.id = v_rep_c1;
  if v_r1[5] is distinct from 'reported'
     or v_txt is distinct from 'hello from T|L here before leaving|R says hi|spectator S|ghost line|T again'
     or not exists (
       select 1 from public.player_reports r
       where r.id = v_rep_c1 and r.chat_status = 'copied' and r.chat_total = 6 and r.chat_kept = 6
         and r.chat -> 'lines' -> 0 ->> 's' = v_t::text
         and (r.chat -> 'lines' -> 0 ->> 'at')::bigint = v_base + 1000
         and r.chat -> 'lines' -> 4 ->> 's' = v_g::text
         and (r.chat -> 'lines' -> 5 ->> 'at')::bigint = v_base + 6000
         and (r.chat -> 'people') ->> v_t::text = v_t_old_nick
         and (r.chat -> 'people') ->> v_l::text = 'm7' || left(replace(v_l::text, '-', ''), 12)
         and (r.chat -> 'people') ->> v_r::text = 'm7' || left(replace(v_r::text, '-', ''), 12)
         and (r.chat -> 'people') ->> v_s::text = 'm7' || left(replace(v_s::text, '-', ''), 12)
         and (r.chat -> 'people') ? v_g::text
         and jsonb_typeof((r.chat -> 'people') -> v_g::text) = 'null'
         and (select count(*) from jsonb_object_keys(r.chat -> 'people')) = 5)
     or (select count(*) from public.attempt_log al where al.user_id = v_r and al.action = 'report_filed') <> 1 then
    select concat_ws(' | ', r.chat_status, r.chat_total::text, r.chat_kept::text, left(r.chat::text, 400)) into v_row
    from public.player_reports r where r.id = v_rep_c1;
    raise exception 'FAIL [C1] R reporting T from T1: % (error %); lines "%"; row "%". Expected reported, copied, 6 / 6, the six lines in "at" order with s and at, people T/L/R/S with nicknames and G null, 1 report_filed row.',
      coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none'), coalesce(v_txt, '-'), coalesce(v_row, '(no row)');
  end if;
  v_checks := v_checks + 1;

  -- [C2] Only chat: nothing else from T1, nor T9's chat.
  select r.chat::text into v_txt from public.player_reports r where r.id = v_rep_c1;
  if v_txt is null or strpos(v_txt, 'NOT CHAT') > 0 or strpos(v_txt, 'not-a-uuid') > 0 then
    raise exception 'FAIL [C2] C1''s copy holds something that is not T1''s chat (table/game/scores events, non-private or malformed chat, or T9''s chat): %', left(coalesce(v_txt, '(no chat)'), 600);
  end if;
  v_checks := v_checks + 1;

  -- [C3] Nicknames at filing.
  update public.profiles set nickname = 'm7new' || left(replace(v_t::text, '-', ''), 10) where id = v_t;
  if (select (r.chat -> 'people') ->> v_t::text from public.player_reports r where r.id = v_rep_c1) is distinct from v_t_old_nick then
    raise exception 'FAIL [C3] after T renamed, C1''s copy shows T as "%"; it must keep the nickname at filing (%).',
      (select (r.chat -> 'people') ->> v_t::text from public.player_reports r where r.id = v_rep_c1), v_t_old_nick;
  end if;
  v_checks := v_checks + 1;

  -- [C4] A spectator reporter.
  v_r1 := pg_temp.m7_as('authenticated', v_s, format('select public.report_player(%L, %L, %L, %L)', v_t, 'behavior', null, v_t1));
  select r.id into v_rep_s from public.player_reports r where r.reporter_id = v_s and r.reported_id = v_t;
  select string_agg(e.v ->> 'text', '|' order by e.n) into v_txt
  from public.player_reports r, jsonb_array_elements(r.chat -> 'lines') with ordinality e(v, n)
  where r.id = v_rep_s;
  if v_r1[5] is distinct from 'reported'
     or v_txt is distinct from 'hello from T|L here before leaving|R says hi|spectator S|ghost line|T again'
     or not exists (select 1 from public.player_reports r where r.id = v_rep_s and r.chat_status = 'copied' and r.chat_total = 6 and r.chat_kept = 6) then
    raise exception 'FAIL [C4] S (a current spectator) reporting T: % (error %), lines "%"; expected reported, copied, the same six lines.',
      coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none'), coalesce(v_txt, '-');
  end if;
  v_checks := v_checks + 1;

  -- [C5] The reported person has left.
  v_r1 := pg_temp.m7_as('authenticated', v_k, format('select public.report_player(%L, %L, %L, %L)', v_l, 'behavior', 'left already', v_t1));
  select r.id into v_rep_k from public.player_reports r where r.reporter_id = v_k and r.reported_id = v_l;
  if v_r1[5] is distinct from 'reported'
     or not exists (select 1 from public.player_reports r where r.id = v_rep_k and r.chat_status = 'copied' and r.chat_total = 6
                      and r.chat::text like '%L here before leaving%')
     or exists (select 1 from public.table_members tm where tm.table_id = v_t1 and tm.user_id = v_l) then
    raise exception 'FAIL [C5] K reporting L (who left T1): % (error %); expected reported, copied 6 with L''s line, L not seated.',
      coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [C6] Not at the table: the report is filed anyway, with no chat.
  v_bad := '';
  for v_rec in
    select * from (values
      ('O at no table', v_o, v_t, v_t1),
      ('Z last seen 2 minutes ago', v_z, v_t, v_t1),
      ('Q removed', v_q, v_t, v_t1),
      ('U, a table id that is no table', v_u, v_l, gen_random_uuid()),
      ('W, no table', v_w, v_t, null::uuid)
    ) as t(label, who, target, tbl)
  loop
    v_r1 := pg_temp.m7_as('authenticated', v_rec.who, format('select public.report_player(%L, %L, %L, %L)', v_rec.target, 'behavior', null, v_rec.tbl));
    if v_r1[5] is distinct from 'reported'
       or not exists (select 1 from public.player_reports r
                      where r.reporter_id = v_rec.who and r.reported_id = v_rec.target
                        and r.chat_status = 'not_at_table' and r.chat is null and r.chat_total is null and r.chat_kept is null)
       or (select count(*) from public.attempt_log al where al.user_id = v_rec.who and al.action = 'report_filed') <> 1 then
      v_bad := v_bad || v_rec.label || ': ' || coalesce(v_r1[5], '-') || ' (error ' || coalesce(v_r1[2], 'none') || ') status '
               || coalesce((select r.chat_status from public.player_reports r where r.reporter_id = v_rec.who and r.reported_id = v_rec.target), '(no row)') || '; ';
    end if;
  end loop;
  select r.id into v_rep_o from public.player_reports r where r.reporter_id = v_o and r.reported_id = v_t;
  if v_bad <> '' then
    raise exception 'FAIL [C6] not at the table: %expected reported, not_at_table with the other three null, counted once, each.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C7] Nickname and picture reports get no chat.
  v_r1 := pg_temp.m7_as('authenticated', v_p, format('select public.report_player(%L, %L, %L, %L)', v_t, 'nickname', null, v_t1));
  v_r2 := pg_temp.m7_as('authenticated', v_p, format('select public.report_player(%L, %L, %L, %L)', v_l, 'picture', null, v_t1));
  select r.id into v_rep_p from public.player_reports r where r.reporter_id = v_p and r.reported_id = v_t;
  if v_r1[5] is distinct from 'reported' or v_r2[5] is distinct from 'reported'
     or (select count(*) from public.player_reports r
         where r.reporter_id = v_p and r.chat is null and r.chat_status is null and r.chat_total is null and r.chat_kept is null) <> 2 then
    raise exception 'FAIL [C7] P''s nickname and picture reports: % / % (errors % / %); expected reported twice with all four chat columns null.',
      coalesce(v_r1[5], '-'), coalesce(v_r2[5], '-'), coalesce(v_r1[2], 'none'), coalesce(v_r2[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [C8] At a table with no chat.
  v_r1 := pg_temp.m7_as('authenticated', v_n, format('select public.report_player(%L, %L, %L, %L)', v_t, 'behavior', null, v_t4));
  select r.id into v_rep_n from public.player_reports r where r.reporter_id = v_n and r.reported_id = v_t;
  if v_r1[5] is distinct from 'reported'
     or not exists (select 1 from public.player_reports r
                    where r.id = v_rep_n and r.chat_status = 'none' and r.chat_total = 0 and r.chat_kept = 0 and r.chat is null) then
    raise exception 'FAIL [C8] N reporting T from T4 (no chat): % (error %); expected reported, none, 0, 0, chat null.', coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [C9] The 2,000-message cap.
  v_r1 := pg_temp.m7_as('authenticated', v_c2, format('select public.report_player(%L, %L, %L, %L)', v_t, 'behavior', null, v_t2));
  select r.id into v_rep_c2 from public.player_reports r where r.reporter_id = v_c2 and r.reported_id = v_t;
  select concat_ws('|', r.chat_status, r.chat_total::text, r.chat_kept::text, jsonb_array_length(r.chat -> 'lines')::text,
                   r.chat -> 'lines' -> 0 ->> 'text', r.chat -> 'lines' -> -1 ->> 'text',
                   (select bool_and(s.prev is null or s.prev < s.at)::text
                    from (select (e.v ->> 'at')::bigint as at, lag((e.v ->> 'at')::bigint) over (order by e.n) as prev
                          from jsonb_array_elements(r.chat -> 'lines') with ordinality e(v, n)) s))
  into v_row
  from public.player_reports r where r.id = v_rep_c2;
  if v_r1[5] is distinct from 'reported' or v_row is distinct from 'copied|2050|2000|2000|m51|m2050|true' then
    raise exception 'FAIL [C9] the message cap: % (error %), "%"; expected reported and copied|2050|2000|2000|m51|m2050|true (status|total|kept|lines|first|last|ascending).',
      coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none'), coalesce(v_row, '(no row)');
  end if;
  v_checks := v_checks + 1;

  -- [C10] The 204,800-byte cap.
  v_r1 := pg_temp.m7_as('authenticated', v_c3, format('select public.report_player(%L, %L, %L, %L)', v_t, 'behavior', null, v_t3));
  select concat_ws('|', r.chat_status, r.chat_total::text, r.chat_kept::text, jsonb_array_length(r.chat -> 'lines')::text,
                   ((r.chat -> 'lines' -> 0 ->> 'text') = lpad('39', 140, 'x'))::text,
                   ((r.chat -> 'lines' -> -1 ->> 'text') = lpad('1500', 140, 'x'))::text,
                   (select sum(octet_length(e.v ->> 'text'))::text from jsonb_array_elements(r.chat -> 'lines') e(v)))
  into v_row
  from public.player_reports r where r.reporter_id = v_c3 and r.reported_id = v_t;
  if v_r1[5] is distinct from 'reported' or v_row is distinct from 'copied|1500|1462|1462|true|true|204680' then
    raise exception 'FAIL [C10] the byte cap: % (error %), "%"; expected reported and copied|1500|1462|1462|true|true|204680 (status|total|kept|lines|first is message 39|last is 1500|bytes).',
      coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none'), coalesce(v_row, '(no row)');
  end if;
  v_checks := v_checks + 1;

  -- ==== C: THE ADMIN SIDE ==========================================================
  -- [C11] admin_report_chat.
  v_r1 := pg_temp.m7_as('authenticated', v_u, format('select count(*)::text from public.admin_report_chat(%L)', v_rep_c1));
  v_r2 := pg_temp.m7_as('authenticated', null, format('select count(*)::text from public.admin_report_chat(%L)', v_rep_c1));
  v_r3 := pg_temp.m7_as('anon', null, format('select count(*)::text from public.admin_report_chat(%L)', v_rep_c1));
  v_bad := '';
  if v_r1[2] is distinct from 'Admins only.' then v_bad := v_bad || 'non-admin ' || coalesce(v_r1[2], coalesce(v_r1[5], '-')) || '; '; end if;
  if v_r2[2] is distinct from 'Admins only.' then v_bad := v_bad || 'nobody ' || coalesce(v_r2[2], coalesce(v_r2[5], '-')) || '; '; end if;
  if v_r3[1] is distinct from '42501' then v_bad := v_bad || 'anon ' || coalesce(v_r3[1], 'allowed') || '; '; end if;
  v_row := (pg_temp.m7_as('authenticated', v_ad, format(
    'select concat_ws(''|'', c.chat_status, c.chat_total::text, c.chat_kept::text, md5(c.chat::text)) from public.admin_report_chat(%L) c', v_rep_c1)))[5];
  if v_row is distinct from (select concat_ws('|', r.chat_status, r.chat_total::text, r.chat_kept::text, md5(r.chat::text)) from public.player_reports r where r.id = v_rep_c1) then
    v_bad := v_bad || 'AD on C1 "' || coalesce(v_row, '(no row)') || '"; ';
  end if;
  v_row := (pg_temp.m7_as('authenticated', v_ad, format(
    'select count(*)::text || '':'' || coalesce(max(coalesce(c.chat_status, ''null'') || coalesce(c.chat_total::text, ''null'') || coalesce(c.chat::text, ''null'')), ''-'') from public.admin_report_chat(%L) c', v_rep_p)))[5];
  if v_row is distinct from '1:nullnullnull' then
    v_bad := v_bad || 'AD on P''s nickname report "' || coalesce(v_row, '-') || '" (want 1:nullnullnull); ';
  end if;
  v_row := (pg_temp.m7_as('authenticated', v_ad, format('select count(*)::text from public.admin_report_chat(%L)', gen_random_uuid())))[5];
  if v_row is distinct from '0' then
    v_bad := v_bad || 'AD on an unknown id: ' || coalesce(v_row, '-') || ' row(s); ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [C11] admin_report_chat: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C12] admin_list_reports' two new columns.
  v_bad := '';
  for v_rec in
    select * from (values
      ('C1', v_rep_c1, 'copied|6'),
      ('C9', v_rep_c2, 'copied|2050'),
      ('C8', v_rep_n, 'none|0'),
      ('O (not at the table)', v_rep_o, 'not_at_table|-'),
      ('P''s nickname report', v_rep_p, '-|-')
    ) as t(label, rid, want)
  loop
    v_txt := (pg_temp.m7_as('authenticated', v_ad, format(
      'select coalesce(l.chat_status, ''-'') || ''|'' || coalesce(l.chat_total::text, ''-'') from public.admin_list_reports(500) l where l.id = %L', v_rec.rid)))[5];
    if v_txt is distinct from v_rec.want then
      v_bad := v_bad || v_rec.label || ': ' || coalesce(v_txt, '(not listed)') || ' (want ' || v_rec.want || '); ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [C12] admin_list_reports chat_status|chat_total: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C13] Deleting a report removes its chat.
  v_r1 := pg_temp.m7_as('authenticated', v_ad, format('select public.admin_delete_report(%L)', v_rep_k));
  if v_r1[5] is distinct from 'deleted' or exists (select 1 from public.player_reports r where r.id = v_rep_k) then
    raise exception 'FAIL [C13] AD deleting C5''s report: % (error %), row left %; expected deleted and no row (its chat with it).',
      coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none'), exists (select 1 from public.player_reports r where r.id = v_rep_k);
  end if;
  v_checks := v_checks + 1;

  -- [C14] The purge removes the chat.
  update public.player_reports r set created_at = now() - interval '91 days' where r.id = v_rep_s;
  v_i := public.purge_old_reports();
  if v_i < 1
     or exists (select 1 from public.player_reports r where r.id = v_rep_s)
     or not exists (select 1 from public.player_reports r where r.id = v_rep_c1 and r.chat_status = 'copied') then
    raise exception 'FAIL [C14] purge_old_reports returned % (want at least 1); C4''s 91-day report gone %, C1''s kept %.',
      v_i, not exists (select 1 from public.player_reports r where r.id = v_rep_s),
      exists (select 1 from public.player_reports r where r.id = v_rep_c1);
  end if;
  v_checks := v_checks + 1;

  -- ==== C: M6 UNCHANGED ============================================================
  -- [C15] Every M6 limit and answer; a refused report copies nothing.
  v_bad := '';
  -- One a day per person: Y's second report on T is refused; the first's
  -- chat is untouched.
  v_r1 := pg_temp.m7_as('authenticated', v_y, format('select public.report_player(%L, %L, %L, %L)', v_t, 'behavior', null, v_t1));
  select r.id, md5(r.chat::text) into v_rep_y, v_chat_before from public.player_reports r where r.reporter_id = v_y and r.reported_id = v_t;
  v_r2 := pg_temp.m7_as('authenticated', v_y, format('select public.report_player(%L, %L, %L, %L)', v_t, 'behavior', 'again', v_t1));
  if v_r1[5] is distinct from 'reported' or v_chat_before is null
     or v_r2[5] is distinct from 'already_reported'
     or (select count(*) from public.player_reports r where r.reporter_id = v_y) <> 1
     or (select md5(r.chat::text) from public.player_reports r where r.id = v_rep_y) is distinct from v_chat_before
     or (select count(*) from public.attempt_log al where al.user_id = v_y and al.action = 'report_filed') <> 1 then
    v_bad := v_bad || 'one a day: ' || coalesce(v_r1[5], '-') || ' then ' || coalesce(v_r2[5], '-') || ' (want reported, copied, then already_reported, one row, chat unchanged, counted once); ';
  end if;
  -- 10 an hour (F), then allowed once the 10 are 61 minutes old.
  insert into public.attempt_log (user_id, action, success) select v_f, 'report_filed', true from generate_series(1, 10);
  v_r1 := pg_temp.m7_as('authenticated', v_f, format('select public.report_player(%L, %L, %L, %L)', v_t, 'behavior', null, v_t1));
  if v_r1[5] is distinct from 'limit' or exists (select 1 from public.player_reports r where r.reporter_id = v_f)
     or (select count(*) from public.attempt_log al where al.user_id = v_f and al.action = 'report_filed') <> 10 then
    v_bad := v_bad || 'hourly: ' || coalesce(v_r1[5], coalesce(v_r1[2], '-')) || ' (want limit, no row, still 10); ';
  end if;
  update public.attempt_log al set created_at = now() - interval '61 minutes' where al.user_id = v_f and al.action = 'report_filed';
  v_r1 := pg_temp.m7_as('authenticated', v_f, format('select public.report_player(%L, %L, %L, %L)', v_t, 'behavior', null, v_t1));
  if v_r1[5] is distinct from 'reported'
     or not exists (select 1 from public.player_reports r where r.reporter_id = v_f and r.chat_status = 'copied' and r.chat_total = 6) then
    v_bad := v_bad || 'hourly, 61 minutes later: ' || coalesce(v_r1[5], coalesce(v_r1[2], '-')) || ' (want reported, copied 6); ';
  end if;
  -- 30 a day (D).
  insert into public.attempt_log (user_id, action, success, created_at)
  select v_d, 'report_filed', true, now() - interval '2 hours' from generate_series(1, 30);
  v_r1 := pg_temp.m7_as('authenticated', v_d, format('select public.report_player(%L, %L, %L, %L)', v_t, 'behavior', null, v_t1));
  if v_r1[5] is distinct from 'limit' or exists (select 1 from public.player_reports r where r.reporter_id = v_d)
     or (select count(*) from public.attempt_log al where al.user_id = v_d and al.action = 'report_filed') <> 30 then
    v_bad := v_bad || 'daily: ' || coalesce(v_r1[5], coalesce(v_r1[2], '-')) || ' (want limit, no row, still 30); ';
  end if;
  -- not_found, not_allowed, the errors: nothing filed or counted (R has 1).
  select count(*) into v_c from public.player_reports r where r.reporter_id in (v_r, v_comp);
  for v_rec in
    select * from (values
      ('unknown target', 'authenticated', v_r, gen_random_uuid(), 'behavior', null::text, null::text, 'not_found'),
      ('null target', 'authenticated', v_r, null::uuid, 'behavior', null::text, null::text, 'not_found'),
      ('yourself', 'authenticated', v_r, v_r, 'behavior', null::text, null::text, 'not_allowed'),
      ('a computer target', 'authenticated', v_r, v_comp, 'behavior', null::text, null::text, 'not_allowed'),
      ('a computer caller', 'authenticated', v_comp, v_t, 'behavior', null::text, null::text, 'not_allowed'),
      ('reason chat', 'authenticated', v_r, v_l, 'chat', 'P0001', 'Unknown report reason.', null::text),
      ('null reason', 'authenticated', v_r, v_l, null::text, 'P0001', 'Unknown report reason.', null::text),
      ('nobody logged in', 'authenticated', null::uuid, v_l, 'behavior', 'P0001', 'You must be logged in to report a player.', null::text),
      ('anon', 'anon', null::uuid, v_l, 'behavior', '42501', null::text, null::text)
    ) as t(label, role, who, target, reason, want_state, want_msg, want_res)
  loop
    v_r1 := pg_temp.m7_as(v_rec.role, v_rec.who, format('select public.report_player(%L, %L, %L, %L)', v_rec.target, v_rec.reason, null, v_t1));
    if v_r1[1] is distinct from v_rec.want_state
       or (v_rec.want_msg is not null and v_r1[2] is distinct from v_rec.want_msg)
       or (v_rec.want_res is not null and v_r1[5] is distinct from v_rec.want_res) then
      v_bad := v_bad || v_rec.label || ': ' || coalesce(v_r1[1], 'ok') || ' ' || coalesce(v_r1[2], coalesce(v_r1[5], '-')) || '; ';
    end if;
  end loop;
  if (select count(*) from public.player_reports r where r.reporter_id in (v_r, v_comp)) <> v_c
     or (select count(*) from public.attempt_log al where al.user_id in (v_r, v_comp) and al.action = 'report_filed') <> 1 then
    v_bad := v_bad || 'a refused call filed or counted something; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [C15] M6''s limits and answers: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== C16: FAIL OPEN (run last: it replaces the helper until the rollback) ======
  execute $r$
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
    as $b$
    begin
      raise exception 'm7 verification: the copy fails on purpose';
    end;
    $b$
  $r$;
  v_r1 := pg_temp.m7_as('authenticated', v_e, format('select public.report_player(%L, %L, %L, %L)', v_t, 'behavior', 'fail open', v_t1));
  if v_r1[5] is distinct from 'reported'
     or not exists (select 1 from public.player_reports r
                    where r.reporter_id = v_e and r.reported_id = v_t and r.note = 'fail open'
                      and r.chat_status = 'unavailable' and r.chat is null and r.chat_total is null and r.chat_kept is null)
     or (select count(*) from public.attempt_log al where al.user_id = v_e and al.action = 'report_filed') <> 1 then
    raise exception 'FAIL [C16] E reporting T while the copy fails: % (error %), status %; expected reported, unavailable with the other three null, counted once.',
      coalesce(v_r1[5], '-'), coalesce(v_r1[2], 'none'),
      coalesce((select r.chat_status from public.player_reports r where r.reporter_id = v_e and r.reported_id = v_t), '(no row)');
  end if;
  v_checks := v_checks + 1;

  -- ==== VERDICT =====================================================================
  -- 4 catalog (K1-K4) + 16 behaviour (C1-C16).
  if v_checks <> v_expect then
    raise exception 'FAIL: % checks ran, expected %.', v_checks, v_expect;
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back).', v_checks;
end;
$$;
