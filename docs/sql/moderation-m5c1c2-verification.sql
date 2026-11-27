-- Moderation, slice M5c1 (c2): VERIFICATION of REMOVING THE OLD CHAT
-- PERMISSIONS (docs/sql/moderation-m5c1c2-part1.sql).
--
-- Run in the Supabase Dashboard -> SQL Editor after part 1. The whole file
-- is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- It WRITES -- temporary functions and a table in pg_temp, temporary
-- accounts in auth.users and their profiles, one test table with seats,
-- spectators and one kick row, real chat messages through the REAL
-- send_table_message (as the people, through the same impersonation as the
-- earlier suites), one owner-stored test row on an old chat:<table>:<user>
-- topic -- and then deliberately raises an exception at the very end, which
-- rolls EVERY write back (nothing commits, so nothing is broadcast). A check
-- that fails raises its own exception at once, which rolls everything back
-- the same way. It always "fails": the message is the verdict.
--   "ALL 8 CHECKS PASSED (rolled back)." is a pass.
--   Anything starting "FAIL" or "SETUP" is not a pass.
--
-- It NEEDS Realtime to store messages right now (today's realtime.messages
-- partition), this role to read past realtime.messages' row-level security,
-- and authenticated to have SELECT on it (moderation-m5c1-precheck.sql
-- shows them). It probes first and stops at SETUP otherwise.
--
-- THE CLOCK: realtime.messages.inserted_at defaults to timezone('utc',
-- clock_timestamp()) -- the real clock, a little after this block's frozen
-- now(). Each sent message is snapped back to the frozen now() right after
-- (as moderation-m5c1-verification.sql does). Each person sends at most
-- once here, so the rate limit never comes into it.
--
-- PEOPLE AND THE TABLE: T, H's open human table that allows spectators. H
-- and G seated; K seated with a kick row ("seated but kicked"); S a current
-- spectator; R a removed spectator; O nobody there.
--
-- WHAT IT CHECKS
--   K1  GONE: no policy named "table chat: members receive" or "table chat:
--       members send" on realtime.messages; no policy anywhere that calls
--       chat_topic_allows; no function named chat_topic_allows in public
--       (any arguments).
--   K2  WHAT REMAINS on realtime.messages is exactly two policies, both
--       PERMISSIVE SELECT for authenticated, broadcast only: "table kicks:
--       people at the table receive" (kick_topic_allows(realtime.topic()))
--       and "table events: people at the table receive"
--       (table_topic_allows(realtime.topic())). No INSERT, UPDATE, DELETE or
--       ALL policy. Row-level security still on.
--   K3  every body the suites fingerprint is unchanged: send_table_message
--       and its helper, table_topic_allows, kick_topic_allows, kick_player,
--       _is_kicked_from_table, get_table_spectators (it STAYS: the app's
--       spectator list), M5a's, M5b1's and M5b2's event functions, the
--       eight _as game functions and their wrappers, the four
--       end-empty-tables bodies.
--   K4  authenticated may execute exactly 60 functions in public:
--       send_table_message and get_table_spectators among them,
--       chat_topic_allows not.
--   C1  SEND_TABLE_MESSAGE STILL WORKS: H (seated) and S (current
--       spectator) send -- one stored 'chat' row each on table:<T>, sender
--       the caller; K (kicked), R (removed) and O (nobody there) get NBC02
--       and store nothing.
--   C2  THE OLD PATH IS CLOSED (table-chat-verification.sql's live checks
--       P1 and P3, inverted): as H with realtime.topic chat:<T>:<H> (and S on
--       chat:<T>:<S>), an INSERT into realtime.messages -- what Realtime does
--       to SEND -- is refused (42501); and a message the owner stored on
--       chat:<T>:<H> is seen by NOBODY at the table (H, G, S) -- a SELECT is
--       what Realtime does to JOIN and RECEIVE, so the channel can't be
--       joined.
--   C3  THE TABLE EVENTS POLICY STILL LETS THE TABLE RECEIVE: H and G
--       (seated) and S (current spectator) see every chat message on
--       table:<T>; R (removed) and O (nobody there) see none.
--   C4  chat_topic_allows can no longer be called by a signed-in client
--       (42883: no such function).

do $$
declare
  v_checks int := 0;
  v_h uuid := gen_random_uuid();
  v_g uuid := gen_random_uuid();
  v_k uuid := gen_random_uuid();
  v_s uuid := gen_random_uuid();
  v_r uuid := gen_random_uuid();
  v_o uuid := gen_random_uuid();
  v_people uuid[];
  v_pid uuid;
  v_code text;
  v_t uuid;
  v_topic text;
  v_old text;
  v_probe text;
  v_r1 text[];
  v_rec record;
  v_txt text;
  v_bad text;
  v_n int;
  v_n2 int;
  v_state text;
begin
  perform set_config('TimeZone', 'UTC', true);

  -- ==== MODE ======================================================================
  if to_regprocedure('public.send_table_message(uuid, text)') is null then
    raise exception 'SETUP: moderation M5c1 part 1 is not in (no send_table_message).';
  end if;
  if exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages'
               and p.policyname in ('table chat: members receive', 'table chat: members send'))
     and to_regprocedure('public.chat_topic_allows(text, boolean)') is not null then
    raise exception 'SETUP: part 1 is not in (the table-chat policies and chat_topic_allows are still there). Run docs/sql/moderation-m5c1c2-part1.sql first.';
  end if;

  -- ==== K: CATALOG ===================================================================
  -- [K1] Gone.
  v_bad := '';
  select string_agg(p.policyname::text, ', ') into v_txt
  from pg_policies p
  where (p.schemaname = 'realtime' and p.tablename = 'messages' and p.policyname in ('table chat: members receive', 'table chat: members send'))
     or coalesce(p.qual, '') ilike '%chat_topic_allows%' or coalesce(p.with_check, '') ilike '%chat_topic_allows%';
  if v_txt is not null then
    v_bad := v_bad || 'policies still there or still calling chat_topic_allows: ' || v_txt || '; ';
  end if;
  select string_agg(p.oid::regprocedure::text, ', ') into v_txt
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'chat_topic_allows';
  if v_txt is not null then
    v_bad := v_bad || 'functions still there: ' || v_txt || '; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K1] %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K2] What remains: exactly the two receive-only policies.
  select count(*) into v_n
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
    and p.cmd = 'SELECT' and p.permissive = 'PERMISSIVE' and p.roles = array['authenticated']::name[]
    and p.with_check is null
    and p.qual ilike '%extension = ''broadcast''%'
    and ((p.policyname = 'table kicks: people at the table receive' and p.qual ilike '%kick_topic_allows(%realtime.topic()%')
      or (p.policyname = 'table events: people at the table receive' and p.qual ilike '%table_topic_allows(%realtime.topic()%'));
  select count(*) into v_n2 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages';
  if v_n <> 2 or v_n2 <> 2
     or exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages' and p.cmd <> 'SELECT')
     or not coalesce((select c.relrowsecurity from pg_class c where c.oid = to_regclass('realtime.messages')), false) then
    raise exception 'FAIL [K2] realtime.messages: % of the two expected receive-only policies, % policies in all (want 2 and 2), or a write policy, or RLS off: %.',
      v_n, v_n2,
      (select string_agg(p.policyname::text || ' (' || p.cmd || ')', ', ' order by p.policyname)
       from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages');
  end if;
  v_checks := v_checks + 1;

  -- [K3] Fingerprints, unchanged (carriage returns removed).
  v_bad := '';
  for v_rec in
    select * from (values
      ('public.send_table_message(uuid, text)', 'e3adcc4874c77c1c47530a807fefd815'),
      ('public._broadcast_table_message(text, jsonb)', 'e5f16aebb3ca764c806e2567b68090fc'),
      ('public.table_topic_allows(text)', '57908d750db883e7687b926cbea3ab4a'),
      ('public.kick_topic_allows(text)', '48327bb75cf98b6ff91388a6db843d11'),
      ('public.kick_player(uuid, uuid)', 'd859deb84acb67ec94a2cf65fb1f38f0'),
      ('public._is_kicked_from_table(uuid, uuid)', 'c8372af51a4537ca9cc079234487a414'),
      ('public.get_table_spectators(uuid)', '0df2ddd114957a157cd688faa17ff209'),
      ('public._send_table_event(uuid, text, bigint)', 'df40bb9eac9b778a8d733d2d18393865'),
      ('public._table_event_on_members()', '26f95e1c2dd4cb5cffbb8e784367cd92'),
      ('public._table_event_on_spectators()', 'f81c329f92115ea11038cff9f0ffc184'),
      ('public._table_event_on_tables()', 'd950c48b22205b15e62e38411923fef5'),
      ('public._bump_game_state_version()', '35314b3677dd7b0b39a2ca32ee29e7c3'),
      ('public._send_game_event(uuid, jsonb)', '462c8068b6c7a183ca76fa18fa6b7264'),
      ('public._game_event_at_commit()', 'cce9d688120f3dc2c155503270fe11ee'),
      ('public._send_scores_event(uuid, jsonb)', 'cf9d6f31090605e8e42ca7a26aae1d7d'),
      ('public._scores_event_at_commit()', 'd06cc5e9fb12f0b0697dd4b4e43bd8a9'),
      ('public.start_game_with_deal_as(uuid, uuid)', '8b4528a51247b63a47b36bd703f81492'),
      ('public.draw_cut_card_as(uuid, uuid)', 'e52f927759d991e13b55a6fa73d39781'),
      ('public.acknowledge_deal_cut_as(uuid, uuid)', '1e6e9b06a58d59628ca8b4ae19e6605d'),
      ('public.discard_to_crib_as(uuid, uuid, text[])', 'fe4d1bb43ee5d4c38dacac502a8817ab'),
      ('public.play_card_as(uuid, uuid, text)', '39f2602ae2d547799f722ce434328b1c'),
      ('public.show_crib_as(uuid, uuid)', '46ff0cf6834ba0afae2178a6fc895da5'),
      ('public.confirm_count_as(uuid, uuid, int)', '27d9a04b7810746bce691f01ec8feffa'),
      ('public.next_hand_as(uuid, uuid, int)', 'e08be4b22774ad656feed6b3852e0562'),
      ('public.start_game_with_deal(uuid)', 'f7df18aedee7d95216674a7687c405a0'),
      ('public.draw_cut_card(uuid)', '0edacf243b6383d9a6977fedb4bd8392'),
      ('public.acknowledge_deal_cut(uuid)', '3ca1514190fa9f57ebd1b78166c26f52'),
      ('public.discard_to_crib(uuid, text[])', '325b1a01178582eba9a55d8117db0803'),
      ('public.play_card(uuid, text)', 'b0434ffb08c301676a3d25722feba168'),
      ('public.show_crib(uuid)', '17821982fea29ef642fefa6a8d63c711'),
      ('public.confirm_count(uuid, int)', '1d5baa992851570fae14dfcf5fda2853'),
      ('public.next_hand(uuid, int)', '692a77e35e328d7c83ad5de4af69fa51'),
      ('public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8'),
      ('public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f'),
      ('public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380'),
      ('public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646')
    ) as t(sig, lf)
  loop
    select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.sig);
    if v_txt is distinct from v_rec.lf then
      v_bad := v_bad || v_rec.sig || ' md5 ' || coalesce(v_txt, 'missing') || '; ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [K3] fingerprinted bodies changed: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K4] The client function count.
  select count(distinct p.proname) into v_n
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.prokind in ('f', 'p')
    and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
    and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  if v_n <> 60
     or not has_function_privilege('authenticated', 'public.send_table_message(uuid, text)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.get_table_spectators(uuid)', 'EXECUTE') then
    raise exception 'FAIL [K4] authenticated may execute % functions in public (want 60, with send_table_message and get_table_spectators).', v_n;
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP: helpers ===============================================================
  create temp table m5e_calls (n serial primary key, label text, who uuid, state text, msg text, res jsonb) on commit drop;

  -- m5e_as(role, user, sql): one statement as that client role; returns
  -- {sqlstate, message, detail, hint, first column of the first row}.
  create function pg_temp.m5e_as(p_role text, p_uid uuid, p_sql text)
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

  -- m5e_send(label, user, table, text): send_table_message as that person,
  -- recorded; a stored row is snapped back to the frozen now().
  create function pg_temp.m5e_send(p_label text, p_uid uuid, p_table uuid, p_text text)
  returns text[]
  language plpgsql
  as $f$
  declare
    v_r text[];
  begin
    v_r := pg_temp.m5e_as('authenticated', p_uid,
      format('select public.send_table_message(%L::uuid, %L::text)::text', p_table, p_text));
    insert into pg_temp.m5e_calls (label, who, state, msg, res)
    values (p_label, p_uid, v_r[1], v_r[2], case when v_r[1] is null then v_r[5]::jsonb end);
    if v_r[1] is null then
      update realtime.messages m set inserted_at = timezone('utc', now())
      where m.topic = 'table:' || p_table::text and m.extension = 'broadcast' and m.private = true
        and m.payload ->> 'event' = 'chat' and m.payload ->> 'sender_id' = p_uid::text
        and m.inserted_at > timezone('utc', now());
    end if;
    return v_r;
  end;
  $f$;

  -- How many rows on a topic (with a payload event) this person may SELECT,
  -- with realtime.topic set as Realtime sets it: what joining and
  -- receiving on that channel is allowed to see.
  create function pg_temp.m5e_sees(p_uid uuid, p_topic text, p_event text)
  returns int
  language plpgsql
  as $f$
  declare
    v_n int;
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    perform set_config('realtime.topic', p_topic, true);
    execute 'set local role authenticated';
    select count(*) into v_n from realtime.messages m where m.topic = p_topic and m.payload ->> 'event' = p_event;
    execute 'reset role';
    return v_n;
  end;
  $f$;

  -- ==== SETUP: can Realtime store? ===================================================
  v_probe := 'table:' || gen_random_uuid()::text;
  begin
    perform realtime.send(jsonb_build_object('event', 'm5c1c2-probe'), 'm5c1c2-probe', v_probe, true);
    select count(*) into v_n from realtime.messages m where m.topic = v_probe and m.extension = 'broadcast' and m.private = true;
  exception when others then
    raise exception 'SETUP: could not send or read a test broadcast: % (%).', sqlerrm, sqlstate;
  end;
  if v_n <> 1 then
    raise exception 'SETUP: Realtime did not store a test broadcast (usually: no realtime.messages partition for today, or this role cannot read past its row-level security); every send_table_message call answers NBC05 meanwhile, so there is nothing to test.';
  end if;
  if not has_table_privilege('authenticated', 'realtime.messages', 'SELECT') then
    raise exception 'SETUP: authenticated lacks SELECT on realtime.messages (C2 and C3 read as each person).';
  end if;

  -- ==== SETUP: people and the table =================================================
  v_people := array[v_h, v_g, v_k, v_s, v_r, v_o];
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'm5c1c2-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      insert into public.profiles (id, nickname)
      values (v_pid, 'm5e' || left(replace(v_pid::text, '-', ''), 12))
      on conflict (id) do update set nickname = excluded.nickname;
    end loop;
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts and profiles: % (%).', sqlerrm, sqlstate;
  end;

  -- A code no OPEN table holds -- every table while tables_code_open_key
  -- doesn't exist (the predicate the other suites use).
  select lpad(n::text, 4, '0') into v_code
  from generate_series(0, 9999) n
  where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                      and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null))
  order by n
  limit 1;
  if v_code is null then
    raise exception 'SETUP: no free table code.';
  end if;

  begin
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_code, v_h, true, true, 4) returning id into v_t;
    insert into public.table_members (table_id, user_id) values (v_t, v_h);
    insert into public.table_members (table_id, user_id) values (v_t, v_g);
    insert into public.table_members (table_id, user_id) values (v_t, v_k);
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at) values (v_t, v_s, now(), now());
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at, removed_at)
    values (v_t, v_r, now() - interval '5 minutes', now(), now());
    insert into public.table_kicks (table_id, kicked_id, host_id, kicked_nickname, kicked_role, game_live)
    values (v_t, v_k, v_h, 'm5e kicked', 'player', false);
  exception when others then
    raise exception 'SETUP: could not create the test table: % (%).', sqlerrm, sqlstate;
  end;
  v_topic := 'table:' || v_t::text;

  -- ==== C1: send_table_message still works ===========================================
  v_bad := '';
  for v_rec in
    select * from (values
      ('H seated', v_h, null::text),
      ('S current spectator', v_s, null),
      ('K seated but kicked', v_k, 'NBC02'),
      ('R removed spectator', v_r, 'NBC02'),
      ('O nobody there', v_o, 'NBC02')
    ) as t(label, who, want)
  loop
    v_r1 := pg_temp.m5e_send(v_rec.label, v_rec.who, v_t, 'hello from ' || v_rec.label);
    if v_r1[1] is distinct from v_rec.want then
      v_bad := v_bad || v_rec.label || ': ' || coalesce(v_r1[1] || ' ' || v_r1[2], 'sent') || ' (want ' || coalesce(v_rec.want, 'sent') || '); ';
    end if;
  end loop;
  -- One stored row per sent call, by its id, sender the caller; none for the refused.
  select count(*) into v_n
  from pg_temp.m5e_calls c
  where c.state is null
    and (select count(*) from realtime.messages m
         where m.topic = v_topic and m.payload ->> 'id' = c.res ->> 'id'
           and m.payload ->> 'event' = 'chat' and m.payload ->> 'sender_id' = c.who::text and m.private = true) = 1;
  select count(*) into v_n2 from realtime.messages m where m.topic = v_topic and m.payload ->> 'event' = 'chat';
  if v_n <> 2 or v_n2 <> 2 then
    v_bad := v_bad || v_n::text || ' of 2 sent calls with their one stored row; ' || v_n2::text || ' chat rows on the topic (want 2); ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [C1] send_table_message: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== C2: the old path is closed ===================================================
  v_bad := '';
  -- Sending: what Realtime does for a client's send on a private channel.
  for v_rec in
    select * from (values ('H (seated)', v_h), ('S (current spectator)', v_s)) as t(label, who)
  loop
    v_old := 'chat:' || v_t::text || ':' || v_rec.who::text;
    perform set_config('request.jwt.claims', json_build_object('sub', v_rec.who, 'role', 'authenticated')::text, true);
    perform set_config('realtime.topic', v_old, true);
    v_state := null;
    execute 'set local role authenticated';
    begin
      insert into realtime.messages (topic, extension, event, payload, private)
      values (v_old, 'broadcast', 'm5c1c2-old', jsonb_build_object('event', 'm5c1c2-old', 'text', 'old path'), true);
    exception when others then
      v_state := sqlstate;
    end;
    execute 'reset role';
    if v_state is distinct from '42501' then
      v_bad := v_bad || v_rec.label || ' sending on its own old chat topic: ' || coalesce(v_state, 'ALLOWED') || ' (want 42501); ';
    end if;
  end loop;
  -- Joining / receiving: a row the owner stored on H's old topic.
  v_old := 'chat:' || v_t::text || ':' || v_h::text;
  perform realtime.send(jsonb_build_object('event', 'm5c1c2-old', 'text', 'stored by the owner'), 'm5c1c2-old', v_old, true);
  select count(*) into v_n from realtime.messages m where m.topic = v_old and m.payload ->> 'event' = 'm5c1c2-old';
  if v_n <> 1 then
    v_bad := v_bad || 'the owner''s test row on the old topic was not stored (' || v_n::text || '); ';
  end if;
  for v_rec in
    select * from (values ('H (seated, its own topic)', v_h), ('G (seated)', v_g), ('S (current spectator)', v_s)) as t(label, who)
  loop
    v_n2 := pg_temp.m5e_sees(v_rec.who, v_old, 'm5c1c2-old');
    if v_n2 <> 0 then
      v_bad := v_bad || v_rec.label || ' can still receive on the old chat topic (' || v_n2::text || ' row); ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [C2] the old chat path: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== C3: the table events policy still lets the table receive ======================
  v_bad := '';
  for v_rec in
    select * from (values
      ('H (seated)', v_h, 2), ('G (seated)', v_g, 2), ('S (current spectator)', v_s, 2),
      ('R (removed spectator)', v_r, 0), ('O (nobody there)', v_o, 0)
    ) as t(label, who, want)
  loop
    v_n2 := pg_temp.m5e_sees(v_rec.who, v_topic, 'chat');
    if v_n2 <> v_rec.want then
      v_bad := v_bad || v_rec.label || ' saw ' || v_n2::text || ' (want ' || v_rec.want::text || '); ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [C3] receiving on table:<T>: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== C4: the old function can't be called ========================================
  v_r1 := pg_temp.m5e_as('authenticated', v_h,
    format('select public.chat_topic_allows(%L, true)::text', 'chat:' || v_t::text || ':' || v_h::text));
  if v_r1[1] is distinct from '42883' then
    raise exception 'FAIL [C4] calling chat_topic_allows as H: % (want 42883, no such function).', coalesce(v_r1[1] || ' ' || v_r1[2], 'it answered ' || coalesce(v_r1[5], 'null'));
  end if;
  v_checks := v_checks + 1;

  -- ==== VERDICT =====================================================================
  if v_checks <> 8 then
    raise exception 'FAIL: % checks ran, expected 8.', v_checks;
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back).', v_checks;
end;
$$;
