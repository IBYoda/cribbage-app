-- Moderation, slice M5 (a): VERIFICATION of TABLE AND SPECTATOR EVENTS
-- (docs/sql/moderation-m5a-part1.sql).
--
-- Run in the Supabase Dashboard -> SQL Editor after part 1. The whole file
-- is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- It WRITES -- one temporary function in pg_temp (m5_as: runs one statement
-- as a client role and returns its result or its error), a temporary
-- REPLACEMENT of _send_table_event (C10), temporary accounts in auth.users
-- and their profiles, test tables, seats, spectator rows, a kick, and
-- (when Realtime can store them) event rows in realtime.messages; it calls
-- leave_table, spectator_heartbeat, kick_player and table_topic_allows as
-- those people -- and then deliberately raises an exception at the very
-- end, which rolls EVERY write back (the replaced function included: DDL is
-- transactional). A check that fails raises its own exception at once,
-- which rolls everything back the same way. It always "fails": the message
-- is the verdict.
--   "ALL 17 CHECKS PASSED (rolled back)." is a pass -- or "ALL 15 CHECKS
--   PASSED (rolled back). Skipped N1-N2 ..." when Realtime can't store the
--   events here (no realtime.messages partition for today, or this role
--   cannot read them).
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives. now() is frozen inside a
-- DO block, so "stale" is made by moving last_seen_at back as the owner.
-- Impersonation: request.jwt.claims plus "set local role authenticated"
-- (or anon), inside m5_as; "reset role" to act as the owner. Seats and
-- spectator rows written as the owner fire the same triggers as the app's
-- functions do.
--
-- STATE-AWARE: it checks only what M5a owns -- its column, its five
-- functions, its three triggers, its policy, and that authenticated may
-- execute at least 60 functions (the exact total is
-- slice-e-grants-verification.sql's job). Other policies on
-- realtime.messages are not counted here.
--
-- PEOPLE AND TABLES: T1 (H's: public, spectators allowed, 4 seats; H and P
-- seated; Q joins, moves and leaves; S3 a current spectator; S and S2 come
-- and go; O is nobody there). T2 (L's: L alone, leaves -> the table ends).
-- T3 (F's: F and G seated; C10, the failing send).
--
-- WHAT IT CHECKS
--   K1  public.tables.roster_version: bigint not null default 0.
--   K2  the five functions: part 1's bodies, security definer, search_path
--       ''; table_topic_allows executable by authenticated only; the
--       helper and the three trigger functions by no client role;
--       authenticated may execute at least 60 functions in public.
--   K3  the three triggers: AFTER, FOR EACH ROW, the right events, enabled,
--       the right function; none of the three tables has an AFTER trigger
--       that sorts after part 1's.
--   K4  the policy exactly as part 1 wrote it (SELECT, to authenticated,
--       permissive, broadcast, table_topic_allows(realtime.topic())); no
--       write policy on realtime.messages but the chat send (or none); no
--       M5a name contains chat, kick or report.
--   K5  the shapes: _send_table_event sends exactly {event, table_id,
--       roster_version} on 'table:' || id, private, inside its own
--       exception block; each trigger function does its work inside its
--       own exception block; no M5a body (comments aside) names a hand,
--       crib, deck or the game_hands / game_cribs / game_decks tables.
--   C1  a seat taken (Q at T1): roster_version + 1.
--   C2  a seat moved: + 1; the same seat again: nothing; a score change:
--       nothing.
--   C3  leave_table (Q, as Q): it works, the seat is gone, + 1.
--   C4  spectators: added + 1; an ordinary heartbeat (spectator_heartbeat,
--       as S): nothing; current -> stale by a write: nothing; stale ->
--       current: + 1; removed: + 1; the row deleted: + 1.
--   C5  the table row: a no-op update sends nothing and bumps nothing; at
--       T2, L's leave_table ends the table as 'empty' (the end-when-empty
--       trigger still works) and bumps T2 by 1.
--   C6  kick_player (H kicks P): 'kicked', P's seat gone, + 1.
--   C7  require-open still holds: a seat at the ended T2 is refused, and
--       T2's version does not move.
--   C8  table_topic_allows: true for H (seated) and S3 (current
--       spectator); false for O, P (kicked), S2 (deleted), S (stale), nobody
--       logged in, an uppercase topic, a chat: or kicks: topic, a bad
--       uuid; anon may not call it (42501).
--   C9  clients cannot move roster_version: H updating it changes nothing.
--   N1  (when Realtime stores them) the events on table:<T1> after setup:
--       exactly the expected (event, roster_version) pairs; every stored
--       row private, broadcast, its event column equal to the payload's
--       event, the payload's table_id T1's, and its keys exactly event,
--       roster_version, table_id -- plus "id", which realtime.send itself
--       adds to the stored payload (a uuid, for Realtime's own message id)
--       and nothing else; no 'table' event at T1; one 'table' event at T2.
--       A failure names each condition's count and shows one stored row.
--   N2  (when Realtime stores them) who RECEIVES table:<T1> under the live
--       policies: H and S3 see every event; O and P see none; H inserting a
--       message on table:<T1> is refused (42501).
--   C10 A FAILING SEND NEVER BLOCKS (run last): with _send_table_event
--       replaced by one that always raises (proved to raise), at T3 a seat
--       taken, a spectator added, G's leave_table and the table's end all
--       go through; T3's version does not move (the bump and the send share
--       one subtransaction).

do $$
declare
  v_checks int := 0;
  v_expect int;
  v_live boolean := false;
  v_skips text := '';
  v_h uuid := gen_random_uuid();
  v_p uuid := gen_random_uuid();
  v_q uuid := gen_random_uuid();
  v_s uuid := gen_random_uuid();
  v_s2 uuid := gen_random_uuid();
  v_s3 uuid := gen_random_uuid();
  v_o uuid := gen_random_uuid();
  v_l uuid := gen_random_uuid();
  v_f uuid := gen_random_uuid();
  v_g uuid := gen_random_uuid();
  v_people uuid[];
  v_pid uuid;
  v_codes text[];
  v_t1 uuid;
  v_t2 uuid;
  v_t3 uuid;
  v_topic text;
  v_base bigint;
  v_v bigint;
  v_v2 bigint;
  v_seat int;
  v_want text := '';
  v_rec record;
  v_txt text;
  v_bad text;
  v_n int;
  v_n2 int;
  v_r text[];
  v_state text;
  v_c_private int;
  v_c_ext int;
  v_c_keys int;
  v_c_table int;
  v_c_event int;
  v_sample text;
begin
  -- ==== MODE ======================================================================
  if to_regprocedure('public._send_table_event(uuid, text, bigint)') is null
     or not exists (select 1 from pg_attribute a where a.attrelid = 'public.tables'::regclass and a.attname = 'roster_version' and not a.attisdropped) then
    raise exception 'SETUP: part 1 is not in (no _send_table_event or tables.roster_version). Run docs/sql/moderation-m5a-part1.sql first.';
  end if;

  -- m5_as(role, user, sql): runs one statement as that client role (the
  -- user as auth.uid(), or nobody when null) and returns
  -- {sqlstate, message, detail, hint, first column of the first row} --
  -- the error fields null when it worked. Rolled back with everything else.
  create function pg_temp.m5_as(p_role text, p_uid uuid, p_sql text)
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
  -- [K1] The column.
  select format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else ' nullable' end
         || ' default ' || coalesce(pg_get_expr(ad.adbin, ad.adrelid), '(none)')
  into v_txt
  from pg_attribute a
  left join pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
  where a.attrelid = 'public.tables'::regclass and a.attname = 'roster_version' and not a.attisdropped;
  if v_txt is distinct from 'bigint not null default 0' then
    raise exception 'FAIL [K1] public.tables.roster_version is "%"; expected bigint not null default 0.', coalesce(v_txt, 'missing');
  end if;
  v_checks := v_checks + 1;

  -- [K2] The five functions, and the client function count.
  v_bad := '';
  for v_rec in
    select * from (values
      ('public._send_table_event(uuid, text, bigint)', 'df40bb9eac9b778a8d733d2d18393865', false),
      ('public._table_event_on_members()', '26f95e1c2dd4cb5cffbb8e784367cd92', false),
      ('public._table_event_on_spectators()', 'f81c329f92115ea11038cff9f0ffc184', false),
      ('public._table_event_on_tables()', 'd950c48b22205b15e62e38411923fef5', false),
      ('public.table_topic_allows(text)', '57908d750db883e7687b926cbea3ab4a', true)
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
  select count(distinct p.proname) into v_n
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.prokind in ('f', 'p')
    and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
    and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  if v_n < 60 then
    v_bad := v_bad || 'authenticated may execute only ' || v_n::text || ' functions in public (want at least 60); ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K2] the M5a functions: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K3] The triggers, and that they sort last.
  v_bad := '';
  for v_rec in
    select * from (values
      ('public.table_members', 'table_members_zz_table_event', 'public._table_event_on_members()', 4 + 8 + 16),
      ('public.table_spectators', 'table_spectators_zz_table_event', 'public._table_event_on_spectators()', 4 + 8 + 16),
      ('public.tables', 'tables_zz_table_event', 'public._table_event_on_tables()', 16)
    ) as t(rel, name, fn, events)
  loop
    select count(*) into v_n
    from pg_trigger tg
    where tg.tgrelid = to_regclass(v_rec.rel)
      and tg.tgname::text = v_rec.name
      and not tg.tgisinternal
      and tg.tgenabled = 'O'
      and tg.tgfoid = to_regprocedure(v_rec.fn)
      and (tg.tgtype & 1) = 1          -- row
      and (tg.tgtype & 2) = 0          -- after
      and (tg.tgtype & 64) = 0         -- not instead of
      and (tg.tgtype & 28) = v_rec.events;
    if v_n <> 1 then
      v_bad := v_bad || v_rec.name || ' not found as AFTER ROW with its events; ';
    end if;
    select string_agg(tg.tgname::text, ', ') into v_txt
    from pg_trigger tg
    where tg.tgrelid = to_regclass(v_rec.rel) and not tg.tgisinternal
      and (tg.tgtype & 2) = 0 and tg.tgname::text > v_rec.name;
    if v_txt is not null then
      v_bad := v_bad || 'AFTER triggers sorting after ' || v_rec.name || ': ' || v_txt || '; ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [K3] %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K4] The policy; nobody may send on table:.
  select count(*) into v_n
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
    and p.policyname = 'table events: people at the table receive' and p.cmd = 'SELECT'
    and p.qual ilike '%extension = ''broadcast''%'
    and p.qual ilike '%table_topic_allows(%realtime.topic()%'
    and p.with_check is null
    and p.permissive = 'PERMISSIVE'
    and p.roles = array['authenticated']::name[];
  select string_agg(p.policyname::text || ' (' || p.cmd || ')', ', ') into v_txt
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
    and p.cmd in ('INSERT', 'ALL', 'UPDATE')
    and p.policyname <> 'table chat: members send';
  select count(*) into v_n2
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('_send_table_event', '_table_event_on_members', '_table_event_on_spectators', '_table_event_on_tables', 'table_topic_allows')
    and p.proname ~ '(chat|kick|report)';
  if v_n <> 1 or v_txt is not null or v_n2 <> 0 then
    raise exception 'FAIL [K4] the table events policy found % time(s) as part 1 wrote it (want 1); write policies other than the chat send: %; M5a names with chat/kick/report: %.',
      v_n, coalesce(v_txt, '(none)'), v_n2;
  end if;
  v_checks := v_checks + 1;

  -- [K5] The shapes (comments removed before looking for hands, cribs and decks).
  v_bad := '';
  select replace(p.prosrc, E'\r', '') into v_txt from pg_proc p where p.oid = to_regprocedure('public._send_table_event(uuid, text, bigint)');
  if strpos(v_txt, 'pg_catalog.jsonb_build_object(''event'', p_event, ''table_id'', p_table_id, ''roster_version'', p_roster_version),') = 0
     or strpos(v_txt, '''table:'' || p_table_id::text,') = 0
     or v_txt !~ E'perform realtime\\.send\\([\\s\\S]*true\\);\\n  exception when others then\\n    null;\\n  end;' then
    v_bad := v_bad || '_send_table_event does not send exactly {event, table_id, roster_version} on table:<id>, private, inside its own exception block; ';
  end if;
  for v_rec in
    select * from (values ('public._table_event_on_members()'), ('public._table_event_on_spectators()'), ('public._table_event_on_tables()')) as t(sig)
  loop
    select replace(p.prosrc, E'\r', '') into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.sig);
    if v_txt !~ E'perform public\\._send_table_event\\([^;]*\\);[\\s\\S]*exception when others then\\n    null;\\n  end;\\n  return null;\\nend;\\n$' then
      v_bad := v_bad || v_rec.sig || ' does not send inside its own exception block; ';
    end if;
  end loop;
  select string_agg(p.proname::text, ', ') into v_txt
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('_send_table_event', '_table_event_on_members', '_table_event_on_spectators', '_table_event_on_tables', 'table_topic_allows')
    and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~* '(\mhands?\M|\mcribs?\M|\mdecks?\M|game_hands|game_cribs|game_decks)';
  if v_txt is not null then
    v_bad := v_bad || 'these bodies name a hand, crib or deck: ' || v_txt || '; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K5] %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner =========================================================
  v_people := array[v_h, v_p, v_q, v_s, v_s2, v_s3, v_o, v_l, v_f, v_g];
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'm5a-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      insert into public.profiles (id, nickname)
      values (v_pid, 'm5' || left(replace(v_pid::text, '-', ''), 12))
      on conflict (id) do update set nickname = excluded.nickname;
    end loop;
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts and profiles: % (%).', sqlerrm, sqlstate;
  end;

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    -- Codes no OPEN table holds -- every table while tables_code_open_key
    -- doesn't exist (the predicate the other suites use).
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                        and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null))
    order by n
    limit 3
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 3 then
    raise exception 'SETUP: fewer than three free table codes.';
  end if;

  begin
    -- T1: H's, 4 seats; H and P seated; S3 a current spectator.
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[1], v_h, true, true, 4) returning id into v_t1;
    insert into public.table_members (table_id, user_id) values (v_t1, v_h);
    insert into public.table_members (table_id, user_id) values (v_t1, v_p);
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at) values (v_t1, v_s3, now(), now());
    -- T2: L's, L alone.
    insert into public.tables (code, created_by, is_public, max_players) values (v_codes[2], v_l, true, 2) returning id into v_t2;
    insert into public.table_members (table_id, user_id) values (v_t2, v_l);
    -- T3: F's; F and G seated.
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[3], v_f, true, true, 4) returning id into v_t3;
    insert into public.table_members (table_id, user_id) values (v_t3, v_f);
    insert into public.table_members (table_id, user_id) values (v_t3, v_g);
  exception when others then
    raise exception 'SETUP: could not create the test tables: % (%).', sqlerrm, sqlstate;
  end;
  v_topic := 'table:' || v_t1::text;
  select t.roster_version into v_base from public.tables t where t.id = v_t1;
  if v_base <> 3 then
    raise exception 'SETUP: T1''s roster_version after two seats and one spectator is %; expected 3 (the triggers did not bump).', v_base;
  end if;

  -- ==== C: EVENTS =====================================================================
  -- [C1] A seat taken.
  insert into public.table_members (table_id, user_id) values (v_t1, v_q);
  select t.roster_version into v_v from public.tables t where t.id = v_t1;
  if v_v <> v_base + 1 then
    raise exception 'FAIL [C1] after Q took a seat T1''s roster_version is % (want %).', v_v, v_base + 1;
  end if;
  v_want := v_want || 'members:' || v_v::text || ',';
  v_checks := v_checks + 1;

  -- [C2] A seat moved; the same seat again; a score change.
  select min(s.n) into v_seat
  from generate_series(1, 4) s(n)
  where not exists (select 1 from public.table_members tm where tm.table_id = v_t1 and tm.seat = s.n);
  update public.table_members tm set seat = v_seat where tm.table_id = v_t1 and tm.user_id = v_q;
  select t.roster_version into v_v from public.tables t where t.id = v_t1;
  update public.table_members tm set seat = v_seat where tm.table_id = v_t1 and tm.user_id = v_q;
  update public.table_members tm set score = coalesce(tm.score, 0) + 5 where tm.table_id = v_t1 and tm.user_id = v_q;
  select t.roster_version into v_v2 from public.tables t where t.id = v_t1;
  if v_seat is null or v_v <> v_base + 2 or v_v2 <> v_v then
    raise exception 'FAIL [C2] seat move to %: version % (want %); then the same seat and a score change: % (want unchanged %).',
      coalesce(v_seat::text, '(no free seat)'), v_v, v_base + 2, v_v2, v_v;
  end if;
  v_want := v_want || 'members:' || v_v::text || ',';
  v_checks := v_checks + 1;

  -- [C3] leave_table, as Q.
  v_r := pg_temp.m5_as('authenticated', v_q, format('select ''ok'' from public.leave_table(%L)', v_t1));
  select t.roster_version into v_v from public.tables t where t.id = v_t1;
  if v_r[1] is not null
     or exists (select 1 from public.table_members tm where tm.table_id = v_t1 and tm.user_id = v_q)
     or v_v <> v_base + 3 then
    raise exception 'FAIL [C3] Q''s leave_table: error % %; seat still there %; version % (want %).',
      coalesce(v_r[1], 'none'), coalesce(v_r[2], ''), exists (select 1 from public.table_members tm where tm.table_id = v_t1 and tm.user_id = v_q), v_v, v_base + 3;
  end if;
  v_want := v_want || 'members:' || v_v::text || ',';
  v_checks := v_checks + 1;

  -- [C4] Spectators.
  v_bad := '';
  insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at) values (v_t1, v_s, now(), now());
  select t.roster_version into v_v from public.tables t where t.id = v_t1;
  if v_v <> v_base + 4 then v_bad := v_bad || 'S added: ' || v_v::text || '; '; end if;
  v_want := v_want || 'spectators:' || (v_base + 4)::text || ',';
  v_r := pg_temp.m5_as('authenticated', v_s, format('select ''ok'' from public.spectator_heartbeat(%L)', v_t1));
  select t.roster_version into v_v from public.tables t where t.id = v_t1;
  if v_r[1] is not null then v_bad := v_bad || 'S''s heartbeat failed: ' || coalesce(v_r[2], '') || '; '; end if;
  if v_v <> v_base + 4 then v_bad := v_bad || 'after an ordinary heartbeat: ' || v_v::text || '; '; end if;
  -- S2: added stale (an insert is always an event), back to current, removed, deleted.
  insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at) values (v_t1, v_s2, now() - interval '10 minutes', now() - interval '5 minutes');
  select t.roster_version into v_v from public.tables t where t.id = v_t1;
  if v_v <> v_base + 5 then v_bad := v_bad || 'S2 added: ' || v_v::text || '; '; end if;
  v_want := v_want || 'spectators:' || (v_base + 5)::text || ',';
  update public.table_spectators ts set last_seen_at = now() where ts.table_id = v_t1 and ts.user_id = v_s2;
  select t.roster_version into v_v from public.tables t where t.id = v_t1;
  if v_v <> v_base + 6 then v_bad := v_bad || 'S2 stale -> current: ' || v_v::text || '; '; end if;
  v_want := v_want || 'spectators:' || (v_base + 6)::text || ',';
  update public.table_spectators ts set last_seen_at = now() - interval '5 minutes' where ts.table_id = v_t1 and ts.user_id = v_s;
  select t.roster_version into v_v from public.tables t where t.id = v_t1;
  if v_v <> v_base + 6 then v_bad := v_bad || 'S current -> stale (a write): ' || v_v::text || '; '; end if;
  update public.table_spectators ts set removed_at = now() where ts.table_id = v_t1 and ts.user_id = v_s2;
  select t.roster_version into v_v from public.tables t where t.id = v_t1;
  if v_v <> v_base + 7 then v_bad := v_bad || 'S2 removed: ' || v_v::text || '; '; end if;
  v_want := v_want || 'spectators:' || (v_base + 7)::text || ',';
  delete from public.table_spectators ts where ts.table_id = v_t1 and ts.user_id = v_s2;
  select t.roster_version into v_v from public.tables t where t.id = v_t1;
  if v_v <> v_base + 8 then v_bad := v_bad || 'S2''s row deleted: ' || v_v::text || '; '; end if;
  v_want := v_want || 'spectators:' || (v_base + 8)::text || ',';
  if v_bad <> '' then
    raise exception 'FAIL [C4] spectators (T1 started at %): %', v_base, v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C5] The table row: a no-op update; T2 ending when L leaves.
  update public.tables t set status = t.status where t.id = v_t1;
  select t.roster_version into v_v from public.tables t where t.id = v_t1;
  select t.roster_version into v_n from public.tables t where t.id = v_t2;
  v_r := pg_temp.m5_as('authenticated', v_l, format('select ''ok'' from public.leave_table(%L)', v_t2));
  select t.roster_version into v_v2 from public.tables t where t.id = v_t2;
  if v_v <> v_base + 8
     or v_r[1] is not null
     or (select t.status || '/' || coalesce(t.ended_reason, '-') from public.tables t where t.id = v_t2) is distinct from 'ended/empty'
     or v_v2 <> v_n + 1 then
    raise exception 'FAIL [C5] T1 after a no-op update: % (want %); L''s leave_table: error % %; T2 now %, version % (want %).',
      v_v, v_base + 8, coalesce(v_r[1], 'none'), coalesce(v_r[2], ''),
      (select t.status || '/' || coalesce(t.ended_reason, '-') from public.tables t where t.id = v_t2), v_v2, v_n + 1;
  end if;
  v_checks := v_checks + 1;

  -- [C6] The host kicks P.
  v_r := pg_temp.m5_as('authenticated', v_h, format('select public.kick_player(%L, %L)', v_t1, v_p));
  select t.roster_version into v_v from public.tables t where t.id = v_t1;
  if v_r[5] is distinct from 'kicked'
     or exists (select 1 from public.table_members tm where tm.table_id = v_t1 and tm.user_id = v_p)
     or v_v <> v_base + 9 then
    raise exception 'FAIL [C6] H kicking P: % (error %); P''s seat gone %; version % (want %).',
      coalesce(v_r[5], '-'), coalesce(v_r[2], 'none'), not exists (select 1 from public.table_members tm where tm.table_id = v_t1 and tm.user_id = v_p), v_v, v_base + 9;
  end if;
  v_want := v_want || 'members:' || v_v::text || ',';
  v_checks := v_checks + 1;

  -- [C7] A seat at the ended T2 is still refused (the require-open trigger).
  select t.roster_version into v_n from public.tables t where t.id = v_t2;
  v_state := null;
  begin
    insert into public.table_members (table_id, user_id) values (v_t2, v_o);
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is null or (select t.roster_version from public.tables t where t.id = v_t2) <> v_n then
    raise exception 'FAIL [C7] a seat at the ended T2: % (want refused), version % -> %.',
      coalesce(v_state, 'ALLOWED'), v_n, (select t.roster_version from public.tables t where t.id = v_t2);
  end if;
  v_checks := v_checks + 1;

  -- [C8] table_topic_allows.
  v_bad := '';
  for v_rec in
    select * from (values
      ('H (seated)', 'authenticated', v_h, v_topic, 'true'),
      ('S3 (current spectator)', 'authenticated', v_s3, v_topic, 'true'),
      ('O (nobody there)', 'authenticated', v_o, v_topic, 'false'),
      ('P (kicked)', 'authenticated', v_p, v_topic, 'false'),
      ('S2 (row deleted)', 'authenticated', v_s2, v_topic, 'false'),
      ('S (stale)', 'authenticated', v_s, v_topic, 'false'),
      ('nobody logged in', 'authenticated', null::uuid, v_topic, 'false'),
      ('H, uppercase topic', 'authenticated', v_h, upper(v_topic), 'false'),
      ('H, chat: topic', 'authenticated', v_h, 'chat:' || v_t1::text || ':' || v_h::text, 'false'),
      ('H, kicks: topic', 'authenticated', v_h, 'kicks:' || v_t1::text, 'false'),
      ('H, bad uuid', 'authenticated', v_h, 'table:not-a-uuid', 'false'),
      ('anon', 'anon', null::uuid, v_topic, '42501')
    ) as t(label, role, who, topic, want)
  loop
    v_r := pg_temp.m5_as(v_rec.role, v_rec.who, format('select public.table_topic_allows(%L)::text', v_rec.topic));
    if coalesce(v_r[5], v_r[1]) is distinct from v_rec.want then
      v_bad := v_bad || v_rec.label || ': ' || coalesce(v_r[5], v_r[1], '-') || ' (want ' || v_rec.want || '); ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [C8] table_topic_allows: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C9] A client cannot move roster_version.
  select t.roster_version into v_v from public.tables t where t.id = v_t1;
  v_r := pg_temp.m5_as('authenticated', v_h, format('update public.tables set roster_version = 999 where id = %L returning roster_version::text', v_t1));
  if (select t.roster_version from public.tables t where t.id = v_t1) <> v_v or v_r[5] is not null then
    raise exception 'FAIL [C9] H set T1''s roster_version: now %, the update said % (error %); want unchanged %.',
      (select t.roster_version from public.tables t where t.id = v_t1), coalesce(v_r[5], '-'), coalesce(v_r[1], 'none'), v_v;
  end if;
  v_checks := v_checks + 1;

  -- [N1] The stored events, when Realtime can store them (and this role can read them).
  begin
    select count(*) into v_n from realtime.messages m where m.topic = v_topic;
  exception when others then
    v_n := -1;
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  if v_n = -1 then
    v_skips := ' Skipped N1-N2: this role cannot read realtime.messages (' || v_txt || ').';
  elsif v_n = 0 then
    v_skips := ' Skipped N1-N2: no table event was stored (usually no realtime.messages partition for today; every change above still went through).';
  elsif not has_table_privilege('authenticated', 'realtime.messages', 'SELECT')
        or not has_table_privilege('authenticated', 'realtime.messages', 'INSERT') then
    v_skips := ' Skipped N1-N2: authenticated lacks SELECT or INSERT on realtime.messages.';
  else
    v_live := true;
    select string_agg(m.event || ':' || (m.payload ->> 'roster_version'), ',' order by (m.payload ->> 'roster_version')::bigint, m.event) || ','
    into v_txt
    from realtime.messages m
    where m.topic = v_topic and (m.payload ->> 'roster_version')::bigint > v_base;
    -- The five conditions, counted one by one so a failure names them.
    -- KEYS: realtime.send stores the payload with an "id" key of its own
    -- (a uuid, Realtime's message id) added when the payload has none, so
    -- the stored keys are ours (event, roster_version, table_id) plus "id".
    -- The rule: all three of ours present, and any other key is only that
    -- uuid "id".
    select count(*) filter (where m.private is distinct from true),
           count(*) filter (where m.extension is distinct from 'broadcast'),
           count(*) filter (where jsonb_typeof(m.payload) is distinct from 'object'
                              or not (m.payload ?& array['event', 'roster_version', 'table_id'])
                              or exists (select 1 from jsonb_object_keys(m.payload) as pk(key)
                                         where pk.key not in ('event', 'roster_version', 'table_id', 'id'))
                              or (m.payload ? 'id'
                                  and coalesce(m.payload ->> 'id', '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')),
           count(*) filter (where m.payload ->> 'table_id' is distinct from v_t1::text),
           count(*) filter (where m.event is distinct from m.payload ->> 'event')
    into v_c_private, v_c_ext, v_c_keys, v_c_table, v_c_event
    from realtime.messages m
    where m.topic = v_topic;
    -- One stored row, for the message.
    select 'private ' || coalesce(m.private::text, 'null') || ', extension ' || coalesce(m.extension, 'null')
           || ', event ' || coalesce(m.event, 'null')
           || ', keys ' || coalesce((select string_agg(pk.key, ',' order by pk.key)
                                     from jsonb_object_keys(case when jsonb_typeof(m.payload) = 'object' then m.payload else '{}'::jsonb end) as pk(key)), '-')
           || ', payload table_id ' || coalesce(m.payload ->> 'table_id', 'null')
           || ' (T1 ' || v_t1::text || ')'
    into v_sample
    from realtime.messages m
    where m.topic = v_topic
    order by (m.payload ->> 'roster_version')::bigint desc nulls last
    limit 1;
    v_n := v_c_private + v_c_ext + v_c_keys + v_c_table + v_c_event;
    select count(*) into v_n2
    from realtime.messages m
    where m.topic = 'table:' || v_t2::text and m.event = 'table';
    if v_txt is distinct from v_want or v_n <> 0 or v_n2 <> 1
       or exists (select 1 from realtime.messages m where m.topic = v_topic and m.event = 'table') then
      raise exception 'FAIL [N1] T1''s events after setup "%" (want "%"); rows failing: not private %, extension not broadcast %, keys not event/roster_version/table_id (+ Realtime''s id) %, payload table_id not T1''s %, event column not the payload''s event %; T2''s table events % (want 1); a table event at T1 %. Sample stored row: %.',
        coalesce(v_txt, '(none)'), v_want, v_c_private, v_c_ext, v_c_keys, v_c_table, v_c_event, v_n2,
        exists (select 1 from realtime.messages m where m.topic = v_topic and m.event = 'table'), coalesce(v_sample, '(none)');
    end if;
    v_checks := v_checks + 1;
  end if;

  -- [N2] Who RECEIVES table:<T1> under the live policies; nobody may send.
  if v_live then
    select count(*) into v_n from realtime.messages m where m.topic = v_topic;
    v_bad := '';
    for v_rec in
      select * from (values
        ('H (seated)', v_h, v_n),
        ('S3 (current spectator)', v_s3, v_n),
        ('O (nobody there)', v_o, 0),
        ('P (kicked)', v_p, 0)
      ) as t(label, who, want)
    loop
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.who, 'role', 'authenticated')::text, true);
      perform set_config('realtime.topic', v_topic, true);
      execute 'set local role authenticated';
      select count(*) into v_n2 from realtime.messages m where m.topic = v_topic;
      execute 'reset role';
      if v_n2 <> v_rec.want then
        v_bad := v_bad || v_rec.label || ' saw ' || v_n2::text || ' (want ' || v_rec.want::text || '); ';
      end if;
    end loop;
    perform set_config('request.jwt.claims', json_build_object('sub', v_h, 'role', 'authenticated')::text, true);
    perform set_config('realtime.topic', v_topic, true);
    v_state := null;
    execute 'set local role authenticated';
    begin
      insert into realtime.messages (topic, extension, event, payload, private)
      values (v_topic, 'broadcast', 'members', '{"event": "members"}'::jsonb, true);
    exception when others then
      v_state := sqlstate;
    end;
    execute 'reset role';
    if v_bad <> '' or v_state is distinct from '42501' then
      raise exception 'FAIL [N2] receiving table:<T1>: %; H sending on it: % (want 42501).', v_bad, coalesce(v_state, 'ALLOWED');
    end if;
    v_checks := v_checks + 1;
  end if;

  -- [C10] A failing send never blocks (run last; the replacement is rolled back).
  execute $r$
    create or replace function public._send_table_event(p_table_id uuid, p_event text, p_roster_version bigint)
    returns void
    language plpgsql
    volatile
    security definer
    set search_path = ''
    as $b$
    begin
      raise exception 'm5a verification: the send fails on purpose';
    end;
    $b$
  $r$;
  v_state := null;
  begin
    perform public._send_table_event(v_t3, 'members', 1);
  exception when others then
    v_state := sqlstate;
  end;
  select t.roster_version into v_n from public.tables t where t.id = v_t3;
  v_bad := '';
  begin
    insert into public.table_members (table_id, user_id) values (v_t3, v_o);
  exception when others then
    v_bad := v_bad || 'a seat taken: ' || sqlerrm || '; ';
  end;
  begin
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at) values (v_t3, v_s3, now(), now());
  exception when others then
    v_bad := v_bad || 'a spectator added: ' || sqlerrm || '; ';
  end;
  v_r := pg_temp.m5_as('authenticated', v_g, format('select ''ok'' from public.leave_table(%L)', v_t3));
  if v_r[1] is not null or exists (select 1 from public.table_members tm where tm.table_id = v_t3 and tm.user_id = v_g) then
    v_bad := v_bad || 'G''s leave_table: ' || coalesce(v_r[2], 'seat still there') || '; ';
  end if;
  begin
    update public.tables t set status = 'ended', ended_reason = 'admin' where t.id = v_t3;
  exception when others then
    v_bad := v_bad || 'the table''s end: ' || sqlerrm || '; ';
  end;
  if v_state is null or v_bad <> ''
     or (select t.status from public.tables t where t.id = v_t3) is distinct from 'ended'
     or not exists (select 1 from public.table_members tm where tm.table_id = v_t3 and tm.user_id = v_o)
     or (select t.roster_version from public.tables t where t.id = v_t3) <> v_n then
    raise exception 'FAIL [C10] with the send failing (it raised: %): %T3 now %, version % (want unchanged %).',
      coalesce(v_state, 'NO -- the test send did not fail'), v_bad,
      (select t.status from public.tables t where t.id = v_t3), (select t.roster_version from public.tables t where t.id = v_t3), v_n;
  end if;
  v_checks := v_checks + 1;

  -- ==== VERDICT =====================================================================
  -- 5 catalog (K1-K5) + 10 behaviour (C1-C10) + 2 stored (N1-N2, only when
  -- Realtime stores the events). The expected count goes into a variable
  -- first (a CASE inside an IF condition is a syntax trap in PL/pgSQL).
  v_expect := 15 + (case when v_live then 2 else 0 end);
  if v_checks <> v_expect then
    raise exception 'FAIL: % checks ran, expected %.', v_checks, v_expect;
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back).%', v_checks, v_skips;
end;
$$;
