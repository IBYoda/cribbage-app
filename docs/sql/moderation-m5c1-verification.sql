-- Moderation, slice M5 (c1): VERIFICATION of CHAT THROUGH THE SERVER
-- (docs/sql/moderation-m5c1-part1.sql).
--
-- Run in the Supabase Dashboard -> SQL Editor after part 1. The whole file
-- is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- It WRITES -- temporary functions and tables in pg_temp, a temporary
-- REPLACEMENT of _broadcast_table_message (C9: first one that stores
-- nothing, then one that raises), temporary accounts in auth.users and
-- their profiles, four test tables with seats, spectators and one kick row,
-- real chat messages through the REAL send_table_message (as the people,
-- through the same impersonation as the earlier suites), so real rows in
-- realtime.messages, which it then BACKDATES (UPDATE, its own rows only) to
-- test the rate limit -- and then deliberately raises an exception at the
-- very end, which rolls EVERY write back (the replaced function and every
-- stored message included: nothing is ever broadcast, because nothing
-- commits). A check that fails raises its own exception at once, which
-- rolls everything back the same way. It always "fails": the message is the
-- verdict.
--   "ALL 13 CHECKS PASSED (rolled back)." is a pass (it may add a note on
--   an optional case it could not set up; it always ends with an INFO note
--   of realtime.messages.inserted_at's column default).
--   Anything starting "FAIL" or "SETUP" is not a pass.
--
-- It NEEDS Realtime to store messages right now (today's realtime.messages
-- partition) and this role to read past realtime.messages' row-level
-- security and UPDATE it (moderation-m5c1-precheck.sql shows all three).
-- It probes first and stops at SETUP otherwise. Without today's partition
-- every real send_table_message call answers NBC05 "Couldn't send" -- by
-- design -- so there is no success path to test.
--
-- now() IS FROZEN in a DO block, but the STORED TIMES USE THE REAL CLOCK:
-- realtime.messages.inserted_at defaults to timezone('utc',
-- clock_timestamp()), so each stored message lands a little AFTER the
-- frozen now() that send_table_message's windows (and this file's shifts)
-- measure from. So m5d_send SNAPS each newly stored row back to exactly the
-- frozen now() right after a sent call; from then on every message stored
-- here sits at the frozen now() and would all count as "within 2 s". The
-- rate limit is then tested by BACKDATING the sender's earlier rows
-- (m5d_shift: exactly 2, 2, 2 and 4 seconds), so "exactly 2 s / 10 s old no
-- longer counts" is exact; the cleaning cases (one sender, many messages)
-- move that sender's rows 30 seconds back before each send (m5d_clear). The
-- verdict ends with inserted_at's column default as read here, so a change
-- in Realtime shows. The block runs with TimeZone UTC, as
-- send_table_message does. (Run within the
-- first minute after midnight UTC, a backdated row may move to yesterday's
-- partition; that is still correct, or SETUP-stops if there is none.)
--
-- PEOPLE AND TABLES:
--   T1 H's, open, allows spectators: H, G and K seated (K also has a kick
--      row, so is "seated but kicked"); S a current spectator; Z a stale
--      one (seen 2 minutes ago); R a removed one; O is nobody there.
--   T2 E's, ended (E still seated).
--   T3 C's computer table (C seated).
--   T4 Q's, open, does NOT allow spectators: Q and S seated; N a current
--      spectator row (if the database lets the setup write one); X, a real
--      computer account, seated (if it lets the setup seat one; else X
--      calls unseated).
--
-- WHAT IT CHECKS
--   K1  the two functions: part 1's bodies; security definer; search_path
--       ''; send_table_message also TimeZone UTC, (p_table_id uuid, p_text
--       text) returns jsonb, volatile, EXECUTE for authenticated only;
--       _broadcast_table_message no client EXECUTE.
--   K2  the shapes: the helper is only realtime.send(p_payload, 'chat',
--       p_topic, true); send_table_message checks in the stated order
--       (signed in, computer account, seat or spectator, kick, text, lock,
--       count, send, read-back, return), counts with extension, private,
--       topic, the 10-second window and sender_id, refuses at "> 0 in 2 s or
--       >= 3 in 10 s", builds exactly {event, id, sender_id, text, at},
--       raises each of NBC01-NBC05, never calls realtime.send itself, and
--       (comments aside) writes no table, takes no row or table lock and
--       sets no setting.
--   K3  every fingerprint the older suites hold is unchanged (the eight _as
--       bodies and wrappers, the four end-empty-tables bodies, kick_player,
--       _is_kicked_from_table, M5a's five, M5b1's three, M5b2's two,
--       chat_topic_allows).
--   K4  still 4 policies on realtime.messages, the two old chat ones among
--       them; no public function with "chat" in its name besides
--       chat_topic_allows; authenticated may execute exactly 61 functions
--       in public, send_table_message among them.
--   C1  WHO MAY SEND: H, G (seated), S (current spectator) and Q (seated at
--       T4) may; Z (stale), R (removed), O (nobody there), K (kicked), E
--       (ended table), C (computer table), N (spectator where spectators
--       are not allowed), X (a computer account), H at a null, unknown or
--       other table get NBC02 "You can't chat at this table."; signed in as
--       nobody, NBC01 "You must be logged in to chat."; anon, 42501. Each
--       answer (K and X aside: stricter on purpose) agrees with
--       chat_topic_allows('chat:<table>:<them>', true).
--   C2  THE CLEANING: 14 texts come back stored exactly as cleanChatText
--       gives them (line breaks, tabs, controls, bidi, \s spaces kept or
--       trimmed, zero-width and BOM kept inside, 140 code points, emoji);
--       6 empty ones ('', spaces, line breaks only, a bidi mark only,
--       controls only, null) get NBC03 "Type a message first." and store
--       nothing.
--   C3  THE RATE LIMIT (G at T1): a second message at once -> NBC04
--       "Slow down: you're sending messages too fast."; one exactly 2 s
--       later -> sent; a third and a fourth within 10 s -> sent, refused
--       (NBC04, the 10-second rule alone); once the oldest is exactly 10 s
--       old -> sent. Another sender at once (H) -> sent; the same sender at
--       another table (S at T4, right after S at T1) -> sent, and again at
--       once -> NBC04. Every refused call stored nothing.
--   C4  ONE EVENT PER CALL, EXACT: each sent call has exactly one stored
--       row (by its id) on table:<its table>, private, broadcast, event
--       'chat', payload keys exactly at, event, id, sender_id, text; the
--       call returned exactly {id, at}, the same id and at; at is now in
--       whole milliseconds.
--   C5  SENDER_ID IS FORCED: there is no sender parameter; every stored
--       sender_id is the caller (four different senders); a text that
--       spells out another sender_id changes nothing.
--   C6  NOTHING STORED FOR A REFUSAL: the test tables' chat rows are exactly
--       the sent calls.
--   C7  WHO RECEIVES (the live policies, as each person): H, G and S see
--       every chat message on T1's topic; Z, R, O and E see none.
--   C8  NO WRITE TO THE TABLES ROW: T1's and T4's rows (ctid, xmin,
--       roster_version) are as they were before the first message.
--   C9  A FAILED SEND IS AN ERROR, NEVER A FALSE SUCCESS (run last): with
--       _broadcast_table_message replaced by one that stores nothing (as
--       realtime.send does when it cannot store: it only warns), H's call
--       gets NBC05 "Couldn't send. Please try again."; with it replaced by
--       one that raises, NBC05 too; neither stored a row.

do $$
declare
  v_checks int := 0;
  v_skips text := '';
  v_h uuid := gen_random_uuid();
  v_g uuid := gen_random_uuid();
  v_k uuid := gen_random_uuid();
  v_s uuid := gen_random_uuid();
  v_z uuid := gen_random_uuid();
  v_r uuid := gen_random_uuid();
  v_o uuid := gen_random_uuid();
  v_e uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid();
  v_np uuid := gen_random_uuid();
  v_q uuid := gen_random_uuid();
  v_x uuid;
  v_x_level text;
  v_x_seated boolean := false;
  v_n_ok boolean := false;
  v_people uuid[];
  v_pid uuid;
  v_codes text[];
  v_t1 uuid;
  v_t2 uuid;
  v_t3 uuid;
  v_t4 uuid;
  v_tables uuid[];
  v_topic text;
  v_probe text;
  v_r1 text[];
  v_rec record;
  v_txt text;
  v_bad text;
  v_n int;
  v_n2 int;
  v_before int;
  v_snap1 text;
  v_snap4 text;
  v_sql text;
  v_m int[];
  v_default text;
begin
  perform set_config('TimeZone', 'UTC', true);

  -- ==== MODE ======================================================================
  if to_regprocedure('public.send_table_message(uuid, text)') is null
     or to_regprocedure('public._broadcast_table_message(text, jsonb)') is null then
    raise exception 'SETUP: part 1 is not in (no send_table_message or _broadcast_table_message). Run docs/sql/moderation-m5c1-part1.sql first.';
  end if;

  -- ==== K: CATALOG (before anything is replaced) =====================================
  -- [K1] The two functions.
  v_bad := '';
  for v_rec in
    select * from (values
      ('public._broadcast_table_message(text, jsonb)', 'e5f16aebb3ca764c806e2567b68090fc', false),
      ('public.send_table_message(uuid, text)', 'e3adcc4874c77c1c47530a807fefd815', true)
    ) as t(sig, lf, client)
  loop
    select v_rec.sig || ': '
           || case when md5(replace(p.prosrc, E'\r', '')) <> v_rec.lf then 'body md5 ' || md5(replace(p.prosrc, E'\r', '')) || ' ' else '' end
           || case when not p.prosecdef then 'not security definer ' else '' end
           || case when not (coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']) then 'search_path not empty ' else '' end
           || case when v_rec.client and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where lower(c) = 'timezone=utc') then 'TimeZone not UTC ' else '' end
           || case when v_rec.client and pg_get_function_identity_arguments(p.oid) <> 'p_table_id uuid, p_text text' then 'arguments ' || pg_get_function_identity_arguments(p.oid) || ' ' else '' end
           || case when v_rec.client and p.prorettype <> 'jsonb'::regtype then 'returns ' || p.prorettype::regtype::text || ' ' else '' end
           || case when p.provolatile <> 'v' then 'not volatile ' else '' end
           || case when has_function_privilege('authenticated', p.oid, 'EXECUTE') <> v_rec.client
                   then 'authenticated EXECUTE ' || has_function_privilege('authenticated', p.oid, 'EXECUTE')::text || ' ' else '' end
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
    raise exception 'FAIL [K1] the M5c1 functions: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K2] The shapes (comment lines removed).
  v_bad := '';
  select regexp_replace(replace(p.prosrc, E'\r', ''), E'\\n[ \\t]*--[^\\n]*', '', 'g') into v_txt
  from pg_proc p where p.oid = to_regprocedure('public._broadcast_table_message(text, jsonb)');
  if v_txt is distinct from E'\nbegin\n  perform realtime.send(p_payload, ''chat'', p_topic, true);\nend;\n' then
    v_bad := v_bad || '_broadcast_table_message is not just realtime.send(p_payload, chat, p_topic, true); ';
  end if;
  select regexp_replace(replace(p.prosrc, E'\r', ''), E'\\n[ \\t]*--[^\\n]*', '', 'g') into v_txt
  from pg_proc p where p.oid = to_regprocedure('public.send_table_message(uuid, text)');
  v_m := array[
    strpos(v_txt, 'if v_caller is null then'),
    strpos(v_txt, 'from public.computer_accounts ca'),
    strpos(v_txt, 'from public.table_members tm'),
    strpos(v_txt, 'from public.table_spectators ts'),
    strpos(v_txt, 'if public._is_kicked_from_table(v_caller, p_table_id) then'),
    strpos(v_txt, 'pg_catalog.regexp_replace('),
    strpos(v_txt, 'pg_catalog.pg_advisory_xact_lock('),
    strpos(v_txt, 'from realtime.messages m'),
    strpos(v_txt, 'perform public._broadcast_table_message(v_topic, pg_catalog.jsonb_build_object('),
    strpos(v_txt, 'and m.payload ->> ''id'' = v_id::text)'),
    strpos(v_txt, 'return pg_catalog.jsonb_build_object(''id'', v_id, ''at'', v_at);')];
  for v_n in 1 .. array_length(v_m, 1) loop
    if v_m[v_n] = 0 or (v_n > 1 and v_m[v_n] <= v_m[v_n - 1]) then
      v_bad := v_bad || 'step ' || v_n::text || ' of the order (signed in, computer, seat, spectator, kick, text, lock, count, send, read-back, return) is missing or out of order; ';
      exit;
    end if;
  end loop;
  if strpos(v_txt, 'hashtextextended(''send_table_message:'' || p_table_id::text || '':'' || v_caller::text, 0)') = 0 then
    v_bad := v_bad || 'the lock is not per table and sender; ';
  end if;
  if strpos(v_txt, E'    where m.extension = ''broadcast''\n      and m.private = true\n      and m.topic = v_topic\n      and m.inserted_at > now() - interval ''10 seconds''\n      and m.payload ->> ''event'' = ''chat''\n      and m.payload ->> ''sender_id'' = v_caller::text;') = 0
     or strpos(v_txt, 'select count(*) filter (where m.inserted_at > now() - interval ''2 seconds''),') = 0
     or strpos(v_txt, 'if v_recent2 > 0 or v_recent10 >= 3 then') = 0 then
    v_bad := v_bad || 'the count is not broadcast, private, topic, 10 s, chat, sender_id with the 1-in-2-s / 3-in-10-s rule; ';
  end if;
  if strpos(v_txt, E'      ''event'', ''chat'',\n      ''id'', v_id,\n      ''sender_id'', v_caller,\n      ''text'', v_text,\n      ''at'', v_at));') = 0
     or (length(v_txt) - length(replace(v_txt, 'jsonb_build_object', ''))) / length('jsonb_build_object') <> 2 then
    v_bad := v_bad || 'the payload is not exactly {event, id, sender_id, text, at}; ';
  end if;
  if (length(v_txt) - length(replace(v_txt, 'using errcode = ''NBC01''', ''))) / length('using errcode = ''NBC01''') <> 1
     or (length(v_txt) - length(replace(v_txt, 'using errcode = ''NBC02''', ''))) / length('using errcode = ''NBC02''') <> 3
     or (length(v_txt) - length(replace(v_txt, 'using errcode = ''NBC03''', ''))) / length('using errcode = ''NBC03''') <> 1
     or (length(v_txt) - length(replace(v_txt, 'using errcode = ''NBC04''', ''))) / length('using errcode = ''NBC04''') <> 1
     or (length(v_txt) - length(replace(v_txt, 'using errcode = ''NBC05''', ''))) / length('using errcode = ''NBC05''') <> 3 then
    v_bad := v_bad || 'not NBC01 once, NBC02 three times, NBC03 once, NBC04 once, NBC05 three times; ';
  end if;
  if strpos(v_txt, 'realtime.send') > 0 then
    v_bad := v_bad || 'send_table_message calls realtime.send itself (only through the helper); ';
  end if;
  if v_txt ~* '(\minsert\s+into\M|\mupdate\s+(public|realtime)\.|\mdelete\s+from\M|\mfor\s+(no\s+key\s+)?update\M|\mfor\s+share\M|\mlock\s+table\M|set_config|\mset\s+local\M)' then
    v_bad := v_bad || 'send_table_message writes, locks a row or table, or sets a setting; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K2] %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K3] The older suites' fingerprints, unchanged.
  v_bad := '';
  for v_rec in
    select * from (values
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
      ('public.kick_player(uuid, uuid)', 'd859deb84acb67ec94a2cf65fb1f38f0'),
      ('public._is_kicked_from_table(uuid, uuid)', 'c8372af51a4537ca9cc079234487a414'),
      ('public._send_table_event(uuid, text, bigint)', 'df40bb9eac9b778a8d733d2d18393865'),
      ('public._table_event_on_members()', '26f95e1c2dd4cb5cffbb8e784367cd92'),
      ('public._table_event_on_spectators()', 'f81c329f92115ea11038cff9f0ffc184'),
      ('public._table_event_on_tables()', 'd950c48b22205b15e62e38411923fef5'),
      ('public.table_topic_allows(text)', '57908d750db883e7687b926cbea3ab4a'),
      ('public._bump_game_state_version()', '35314b3677dd7b0b39a2ca32ee29e7c3'),
      ('public._send_game_event(uuid, jsonb)', '462c8068b6c7a183ca76fa18fa6b7264'),
      ('public._game_event_at_commit()', 'cce9d688120f3dc2c155503270fe11ee'),
      ('public._send_scores_event(uuid, jsonb)', 'cf9d6f31090605e8e42ca7a26aae1d7d'),
      ('public._scores_event_at_commit()', 'd06cc5e9fb12f0b0697dd4b4e43bd8a9'),
      ('public.chat_topic_allows(text, boolean)', '0458d5122d68d511b2e0fbceafe84aae'),
      -- The four end-empty-tables bodies, LF (CRLF accepted below).
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
    raise exception 'FAIL [K3] fingerprinted bodies changed (carriage returns removed): %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K4] Policies, names, the client function count.
  v_bad := '';
  select count(*) into v_n from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages';
  if v_n <> 4 then
    v_bad := v_bad || v_n::text || ' policies on realtime.messages (want 4); ';
  end if;
  if (select count(*) from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages'
        and p.policyname in ('table chat: members receive', 'table chat: members send')) <> 2 then
    v_bad := v_bad || 'an old chat policy is missing; ';
  end if;
  select string_agg(p.proname::text, ', ') into v_txt
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows';
  if v_txt is not null then
    v_bad := v_bad || 'public functions with "chat" in the name: ' || v_txt || '; ';
  end if;
  select count(distinct p.proname) into v_n
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.prokind in ('f', 'p')
    and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
    and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  if v_n <> 61 then
    v_bad := v_bad || 'authenticated may execute ' || v_n::text || ' functions in public (want 61); ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K4] %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP: helpers ===============================================================
  create temp table m5d_calls (n serial primary key, label text, who uuid, tbl uuid, state text, msg text, res jsonb) on commit drop;

  -- m5d_as(role, user, sql): one statement as that client role; returns
  -- {sqlstate, message, detail, hint, first column of the first row}.
  create function pg_temp.m5d_as(p_role text, p_uid uuid, p_sql text)
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

  -- m5d_send(label, user, table, text): send_table_message as that person,
  -- recorded in m5d_calls. After a sent call, THE SNAP: realtime.messages
  -- stamps inserted_at with the REAL clock (its default is
  -- timezone('utc', clock_timestamp())), a little after the frozen now()
  -- the function and the shifts measure from; the new row is moved back to
  -- exactly the frozen now(). Only rows later than the frozen now() move: a
  -- fresh row is, a backdated or cleared one never is.
  create function pg_temp.m5d_send(p_label text, p_uid uuid, p_table uuid, p_text text)
  returns text[]
  language plpgsql
  as $f$
  declare
    v_r text[];
  begin
    v_r := pg_temp.m5d_as('authenticated', p_uid,
      format('select public.send_table_message(%L::uuid, %L::text)::text', p_table, p_text));
    insert into pg_temp.m5d_calls (label, who, tbl, state, msg, res)
    values (p_label, p_uid, p_table, v_r[1], v_r[2], case when v_r[1] is null then v_r[5]::jsonb end);
    if v_r[1] is null then
      update realtime.messages m set inserted_at = timezone('utc', now())
      where m.topic = 'table:' || p_table::text and m.extension = 'broadcast' and m.private = true
        and m.payload ->> 'event' = 'chat' and m.payload ->> 'sender_id' = p_uid::text
        and m.inserted_at > timezone('utc', now());
    end if;
    return v_r;
  end;
  $f$;

  -- A person's stored chat rows at a table.
  create function pg_temp.m5d_rows(p_table uuid, p_uid uuid)
  returns int
  language sql
  as $f$
    select count(*)::int from realtime.messages m
    where m.topic = 'table:' || p_table::text and m.extension = 'broadcast' and m.private = true
      and m.payload ->> 'event' = 'chat' and m.payload ->> 'sender_id' = p_uid::text
  $f$;

  -- m5d_shift(table, user, seconds): that person's rows at that table that
  -- many seconds older. Returns how many rows moved.
  create function pg_temp.m5d_shift(p_table uuid, p_uid uuid, p_secs numeric)
  returns int
  language plpgsql
  as $f$
  declare
    v_n int;
  begin
    update realtime.messages m set inserted_at = m.inserted_at - make_interval(secs => p_secs)
    where m.topic = 'table:' || p_table::text and m.extension = 'broadcast' and m.private = true
      and m.payload ->> 'event' = 'chat' and m.payload ->> 'sender_id' = p_uid::text;
    get diagnostics v_n = row_count;
    return v_n;
  end;
  $f$;

  -- m5d_clear(table, user): that person's recent rows at that table moved
  -- to 30 seconds ago (out of both windows).
  create function pg_temp.m5d_clear(p_table uuid, p_uid uuid)
  returns void
  language sql
  as $f$
    update realtime.messages m set inserted_at = now() - interval '30 seconds'
    where m.topic = 'table:' || p_table::text and m.extension = 'broadcast' and m.private = true
      and m.payload ->> 'event' = 'chat' and m.payload ->> 'sender_id' = p_uid::text
      and m.inserted_at > now() - interval '30 seconds'
  $f$;

  -- ==== SETUP: can Realtime store, can this role read and backdate? ===============
  v_probe := 'table:' || gen_random_uuid()::text;
  begin
    perform realtime.send(jsonb_build_object('event', 'm5c1-probe'), 'm5c1-probe', v_probe, true);
    select count(*) into v_n from realtime.messages m where m.topic = v_probe and m.extension = 'broadcast' and m.private = true;
  exception when others then
    raise exception 'SETUP: could not send or read a test broadcast: % (%).', sqlerrm, sqlstate;
  end;
  if v_n <> 1 then
    raise exception 'SETUP: Realtime did not store a test broadcast (usually: no realtime.messages partition for today, or this role cannot read past its row-level security). While that lasts every send_table_message call answers NBC05 "Couldn''t send" (by design), so there is no success path to test. See moderation-m5c1-precheck.sql''s needs rows.';
  end if;
  begin
    update realtime.messages m set inserted_at = m.inserted_at - interval '1 second' where m.topic = v_probe;
    get diagnostics v_n = row_count;
  exception when others then
    raise exception 'SETUP: this role cannot backdate realtime.messages rows (needed to test the rate limit): % (%).', sqlerrm, sqlstate;
  end;
  if v_n <> 1 then
    raise exception 'SETUP: backdating the test broadcast moved % rows (want 1): this role cannot UPDATE past realtime.messages'' row-level security.', v_n;
  end if;
  -- What stamps inserted_at (INFO, in the verdict): the snap in m5d_send
  -- assumes a clock at or after the frozen now().
  select coalesce(pg_get_expr(d.adbin, d.adrelid), '(no default)') into v_default
  from pg_attribute a
  left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  where a.attrelid = to_regclass('realtime.messages') and a.attname = 'inserted_at' and not a.attisdropped;
  if not has_table_privilege('authenticated', 'realtime.messages', 'SELECT') then
    raise exception 'SETUP: authenticated lacks SELECT on realtime.messages (C7 receives as each person; Realtime Authorization needs it too).';
  end if;

  -- ==== SETUP: people and tables ====================================================
  select ca.user_id, ca.level into v_x, v_x_level from public.computer_accounts ca order by ca.level limit 1;
  if v_x is null then
    raise exception 'SETUP: public.computer_accounts has no rows (C1 calls as a computer account).';
  end if;

  v_people := array[v_h, v_g, v_k, v_s, v_z, v_r, v_o, v_e, v_c, v_np, v_q];
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'm5c1-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      insert into public.profiles (id, nickname)
      values (v_pid, 'm5d' || left(replace(v_pid::text, '-', ''), 12))
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
    limit 4
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 4 then
    raise exception 'SETUP: fewer than four free table codes.';
  end if;

  begin
    -- T1: H's, open, allows spectators.
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[1], v_h, true, true, 4) returning id into v_t1;
    insert into public.table_members (table_id, user_id) values (v_t1, v_h);
    insert into public.table_members (table_id, user_id) values (v_t1, v_g);
    insert into public.table_members (table_id, user_id) values (v_t1, v_k);
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at) values (v_t1, v_s, now(), now());
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at)
    values (v_t1, v_z, now() - interval '10 minutes', now() - interval '2 minutes');
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at, removed_at)
    values (v_t1, v_r, now() - interval '5 minutes', now(), now());
    insert into public.table_kicks (table_id, kicked_id, host_id, kicked_nickname, kicked_role, game_live)
    values (v_t1, v_k, v_h, 'm5d kicked', 'player', false);
    -- T2: E's, then ended.
    insert into public.tables (code, created_by, is_public, max_players) values (v_codes[2], v_e, true, 2) returning id into v_t2;
    insert into public.table_members (table_id, user_id) values (v_t2, v_e);
    update public.tables t set status = 'ended', ended_reason = 'admin' where t.id = v_t2;
    -- T3: C's computer table.
    insert into public.tables (code, created_by, computer_level) values (v_codes[3], v_c, v_x_level) returning id into v_t3;
    insert into public.table_members (table_id, user_id) values (v_t3, v_c);
    -- T4: Q's, open, no spectators allowed; S seated there too.
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[4], v_q, true, false, 4) returning id into v_t4;
    insert into public.table_members (table_id, user_id) values (v_t4, v_q);
    insert into public.table_members (table_id, user_id) values (v_t4, v_s);
  exception when others then
    raise exception 'SETUP: could not create the test tables: % (%).', sqlerrm, sqlstate;
  end;
  -- Optional: N's spectator row at T4, X's seat at T4.
  begin
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at) values (v_t4, v_np, now(), now());
    v_n_ok := true;
  exception when others then
    v_skips := v_skips || ' N (a spectator where spectators are not allowed) not set up: ' || sqlerrm || '.';
  end;
  begin
    insert into public.table_members (table_id, user_id) values (v_t4, v_x);
    v_x_seated := true;
  exception when others then
    v_skips := v_skips || ' X (the computer account) calls unseated: ' || sqlerrm || '.';
  end;
  v_tables := array[v_t1, v_t2, v_t3, v_t4];
  v_topic := 'table:' || v_t1::text;

  -- The tables rows before the first message.
  select t.ctid::text || '/' || t.xmin::text || '/' || coalesce(t.roster_version::text, '-') into v_snap1 from public.tables t where t.id = v_t1;
  select t.ctid::text || '/' || t.xmin::text || '/' || coalesce(t.roster_version::text, '-') into v_snap4 from public.tables t where t.id = v_t4;

  -- ==== C1: who may send ============================================================
  v_bad := '';
  for v_rec in
    select * from (values
      ('H seated', v_h, v_t1, null::text, true),
      ('G seated', v_g, v_t1, null, true),
      ('S current spectator', v_s, v_t1, null, true),
      ('Q seated at T4', v_q, v_t4, null, true),
      ('Z stale spectator', v_z, v_t1, 'NBC02', true),
      ('R removed spectator', v_r, v_t1, 'NBC02', true),
      ('O nobody there', v_o, v_t1, 'NBC02', true),
      ('K seated but kicked', v_k, v_t1, 'NBC02', false),
      ('E at an ended table', v_e, v_t2, 'NBC02', true),
      ('C at a computer table', v_c, v_t3, 'NBC02', true),
      ('N spectator where not allowed', v_np, v_t4, 'NBC02', true),
      ('X a computer account', v_x, v_t4, 'NBC02', false),
      ('H at a null table', v_h, null, 'NBC02', false),
      ('H at an unknown table', v_h, gen_random_uuid(), 'NBC02', false),
      ('H at another table (T4)', v_h, v_t4, 'NBC02', true)
    ) as t(label, who, tbl, want, compare)
  loop
    if v_rec.who = v_np and not v_n_ok then
      continue;
    end if;
    v_r1 := pg_temp.m5d_send(v_rec.label, v_rec.who, v_rec.tbl, 'hello from ' || v_rec.label);
    if v_r1[1] is distinct from v_rec.want then
      v_bad := v_bad || v_rec.label || ': ' || coalesce(v_r1[1] || ' ' || v_r1[2], 'sent') || ' (want ' || coalesce(v_rec.want, 'sent') || '); ';
    elsif v_rec.want = 'NBC02' and v_r1[2] is distinct from 'You can''t chat at this table.' then
      v_bad := v_bad || v_rec.label || ': message "' || coalesce(v_r1[2], '') || '"; ';
    end if;
    if v_rec.compare then
      v_r1 := pg_temp.m5d_as('authenticated', v_rec.who,
        format('select public.chat_topic_allows(%L, true)::text', 'chat:' || v_rec.tbl::text || ':' || v_rec.who::text));
      if v_r1[1] is not null or v_r1[5] is distinct from (v_rec.want is null)::text then
        v_bad := v_bad || v_rec.label || ': chat_topic_allows says ' || coalesce(v_r1[5], v_r1[2]) || '; ';
      end if;
    end if;
  end loop;
  -- Signed in as nobody; anon.
  v_r1 := pg_temp.m5d_as('authenticated', null, format('select public.send_table_message(%L::uuid, %L)::text', v_t1, 'hi'));
  if v_r1[1] is distinct from 'NBC01' or v_r1[2] is distinct from 'You must be logged in to chat.' then
    v_bad := v_bad || 'nobody signed in: ' || coalesce(v_r1[1] || ' ' || v_r1[2], 'sent') || ' (want NBC01); ';
  end if;
  insert into pg_temp.m5d_calls (label, who, tbl, state, msg) values ('nobody signed in', null, v_t1, v_r1[1], v_r1[2]);
  v_r1 := pg_temp.m5d_as('anon', null, format('select public.send_table_message(%L::uuid, %L)::text', v_t1, 'hi'));
  if v_r1[1] is distinct from '42501' then
    v_bad := v_bad || 'anon: ' || coalesce(v_r1[1] || ' ' || v_r1[2], 'sent') || ' (want 42501); ';
  end if;
  insert into pg_temp.m5d_calls (label, who, tbl, state, msg) values ('anon', null, v_t1, v_r1[1], v_r1[2]);
  if v_bad <> '' then
    raise exception 'FAIL [C1] who may send: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== C2: the cleaning (H at T1) ===================================================
  create temp table m5d_vec (n int primary key, input text, want text) on commit drop;
  insert into pg_temp.m5d_vec (n, input, want) values
    (1, '  hello  ', 'hello'),
    (2, 'a' || chr(13) || chr(10) || chr(13) || chr(10) || '  b', 'a b'),
    (3, 'a ' || chr(9) || chr(10) || chr(9) || ' b', 'a b'),
    (4, 'a' || chr(9) || 'b', 'ab'),
    (5, 'a' || chr(8238) || 'b' || chr(8294) || 'c', 'abc'),
    (6, 'x' || chr(8232) || 'y', 'x y'),
    (7, chr(160) || 'hi' || chr(160) || 'there' || chr(12288), 'hi' || chr(160) || 'there'),
    (8, 'a' || chr(127) || chr(133) || chr(159) || 'b', 'ab'),
    (9, 'a' || chr(8203) || 'b', 'a' || chr(8203) || 'b'),
    (10, 'a' || chr(65279) || 'b', 'a' || chr(65279) || 'b'),
    (11, 'a' || chr(11) || chr(10) || 'b', 'a b'),
    (12, 'x' || repeat(' ', 139) || 'y', 'x'),
    (13, repeat(chr(128512), 150), repeat(chr(128512), 140)),
    (14, '{"sender_id":"' || v_g::text || '"} it''s <b>ok</b>', '{"sender_id":"' || v_g::text || '"} it''s <b>ok</b>'),
    (15, '', null),
    (16, '   ', null),
    (17, chr(10) || chr(10), null),
    (18, chr(8238), null),
    (19, chr(9) || chr(1), null),
    (20, null, null);
  v_bad := '';
  for v_rec in select * from pg_temp.m5d_vec order by n loop
    perform pg_temp.m5d_clear(v_t1, v_h);
    v_before := pg_temp.m5d_rows(v_t1, v_h);
    v_r1 := pg_temp.m5d_send('clean ' || v_rec.n::text, v_h, v_t1, v_rec.input);
    if v_rec.want is null then
      if v_r1[1] is distinct from 'NBC03' or v_r1[2] is distinct from 'Type a message first.' then
        v_bad := v_bad || 'text ' || v_rec.n::text || ': ' || coalesce(v_r1[1] || ' ' || v_r1[2], 'sent') || ' (want NBC03); ';
      elsif pg_temp.m5d_rows(v_t1, v_h) <> v_before then
        v_bad := v_bad || 'text ' || v_rec.n::text || ': refused but stored; ';
      end if;
    else
      if v_r1[1] is not null then
        v_bad := v_bad || 'text ' || v_rec.n::text || ': refused ' || v_r1[1] || ' ' || v_r1[2] || '; ';
      else
        select m.payload ->> 'text' into v_txt
        from realtime.messages m
        where m.topic = v_topic and m.payload ->> 'id' = (v_r1[5]::jsonb) ->> 'id';
        if v_txt is distinct from v_rec.want then
          v_bad := v_bad || 'text ' || v_rec.n::text || ' stored as ' || coalesce(quote_literal(v_txt), 'nothing') || ' (want ' || quote_literal(v_rec.want) || '); ';
        end if;
      end if;
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [C2] the cleaning: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== C3: the rate limit ===========================================================
  v_bad := '';
  perform pg_temp.m5d_clear(v_t1, v_g);
  -- One message, then another at once: refused by the 2-second rule.
  v_r1 := pg_temp.m5d_send('rate g1', v_g, v_t1, 'g1');
  if v_r1[1] is not null then v_bad := v_bad || 'g1 refused ' || v_r1[1] || '; '; end if;
  v_before := pg_temp.m5d_rows(v_t1, v_g);
  v_r1 := pg_temp.m5d_send('rate g2', v_g, v_t1, 'g2');
  if v_r1[1] is distinct from 'NBC04' or v_r1[2] is distinct from 'Slow down: you''re sending messages too fast.' then
    v_bad := v_bad || 'g2 (at once): ' || coalesce(v_r1[1] || ' ' || v_r1[2], 'sent') || ' (want NBC04); ';
  end if;
  if pg_temp.m5d_rows(v_t1, v_g) <> v_before then v_bad := v_bad || 'g2 refused but stored; '; end if;
  -- Exactly 2 s later: sent.
  perform pg_temp.m5d_shift(v_t1, v_g, 2);
  v_r1 := pg_temp.m5d_send('rate g3', v_g, v_t1, 'g3');
  if v_r1[1] is not null then v_bad := v_bad || 'g3 (2 s after g1) refused ' || v_r1[1] || '; '; end if;
  -- 2 s later again: the third in 10 s, sent.
  perform pg_temp.m5d_shift(v_t1, v_g, 2);
  v_r1 := pg_temp.m5d_send('rate g4', v_g, v_t1, 'g4');
  if v_r1[1] is not null then v_bad := v_bad || 'g4 (third in 10 s) refused ' || v_r1[1] || '; '; end if;
  -- 2 s later again: a fourth in 10 s, none in 2 s -> the 10-second rule.
  perform pg_temp.m5d_shift(v_t1, v_g, 2);
  v_before := pg_temp.m5d_rows(v_t1, v_g);
  v_r1 := pg_temp.m5d_send('rate g5', v_g, v_t1, 'g5');
  if v_r1[1] is distinct from 'NBC04' then
    v_bad := v_bad || 'g5 (fourth in 10 s): ' || coalesce(v_r1[1] || ' ' || v_r1[2], 'sent') || ' (want NBC04); ';
  end if;
  if pg_temp.m5d_rows(v_t1, v_g) <> v_before then v_bad := v_bad || 'g5 refused but stored; '; end if;
  -- 4 s later: the oldest is exactly 10 s old and no longer counts.
  perform pg_temp.m5d_shift(v_t1, v_g, 4);
  v_r1 := pg_temp.m5d_send('rate g6', v_g, v_t1, 'g6');
  if v_r1[1] is not null then v_bad := v_bad || 'g6 (oldest exactly 10 s old) refused ' || v_r1[1] || '; '; end if;
  -- Another sender at once: their own limit.
  perform pg_temp.m5d_clear(v_t1, v_h);
  v_r1 := pg_temp.m5d_send('rate h', v_h, v_t1, 'h right after g6');
  if v_r1[1] is not null then v_bad := v_bad || 'H right after G refused ' || v_r1[1] || '; '; end if;
  -- The same sender at another table: that table's own limit (S sent at
  -- T1 in C1, just now in the frozen clock).
  if pg_temp.m5d_rows(v_t1, v_s) <> 1 then v_bad := v_bad || 'S has no message at T1 to start from; '; end if;
  v_r1 := pg_temp.m5d_send('rate s4a', v_s, v_t4, 's at T4');
  if v_r1[1] is not null then v_bad := v_bad || 'S at T4 (after S at T1) refused ' || v_r1[1] || '; '; end if;
  v_before := pg_temp.m5d_rows(v_t4, v_s);
  v_r1 := pg_temp.m5d_send('rate s4b', v_s, v_t4, 's at T4 again');
  if v_r1[1] is distinct from 'NBC04' then
    v_bad := v_bad || 'S at T4 again at once: ' || coalesce(v_r1[1] || ' ' || v_r1[2], 'sent') || ' (want NBC04); ';
  end if;
  if pg_temp.m5d_rows(v_t4, v_s) <> v_before then v_bad := v_bad || 'S''s refused T4 message stored; '; end if;
  if v_bad <> '' then
    raise exception 'FAIL [C3] the rate limit: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== C4: one event per call, exact ===============================================
  select count(*) into v_n from pg_temp.m5d_calls c where c.state is null;
  select count(*) into v_n2
  from pg_temp.m5d_calls c
  where c.state is null
    and (
      (select string_agg(k, ',' order by k) from jsonb_object_keys(c.res) as k) is distinct from 'at,id'
      or jsonb_typeof(c.res -> 'at') is distinct from 'number'
      or (c.res ->> 'at')::numeric <> floor(extract(epoch from now()) * 1000)
      or (select count(*) from realtime.messages m
          where m.topic = 'table:' || c.tbl::text and m.payload ->> 'id' = c.res ->> 'id') <> 1
      or exists (
        select 1 from realtime.messages m
        where m.topic = 'table:' || c.tbl::text and m.payload ->> 'id' = c.res ->> 'id'
          and (m.private is distinct from true
               or m.extension is distinct from 'broadcast'
               or m.event is distinct from 'chat'
               or (select string_agg(k, ',' order by k) from jsonb_object_keys(m.payload) as k) is distinct from 'at,event,id,sender_id,text'
               or m.payload ->> 'event' is distinct from 'chat'
               or m.payload -> 'at' is distinct from c.res -> 'at'
               or m.payload -> 'id' is distinct from c.res -> 'id'
               or jsonb_typeof(m.payload -> 'text') is distinct from 'string')));
  if v_n < 10 or v_n2 <> 0 then
    raise exception 'FAIL [C4] % of % sent call(s) without exactly one matching stored row {at, event, id, sender_id, text} (private, broadcast, event chat) or without the same {id, at} returned; sample: %.',
      v_n2, v_n, (select c.label || ' ' || coalesce(c.res::text, '-') from pg_temp.m5d_calls c where c.state is null order by c.n limit 1);
  end if;
  v_checks := v_checks + 1;

  -- ==== C5: sender_id is forced ======================================================
  v_bad := '';
  if exists (select 1 from pg_proc p where p.proname = 'send_table_message'
               and pg_get_function_arguments(p.oid) <> 'p_table_id uuid, p_text text') then
    v_bad := v_bad || 'send_table_message takes other arguments; ';
  end if;
  select count(*) into v_n
  from pg_temp.m5d_calls c
  join realtime.messages m on m.topic = 'table:' || c.tbl::text and m.payload ->> 'id' = c.res ->> 'id'
  where c.state is null and m.payload ->> 'sender_id' is distinct from c.who::text;
  if v_n <> 0 then
    v_bad := v_bad || v_n::text || ' stored row(s) whose sender_id is not the caller; ';
  end if;
  select count(distinct c.who) into v_n from pg_temp.m5d_calls c where c.state is null;
  if v_n < 4 then
    v_bad := v_bad || 'only ' || v_n::text || ' different senders sent (want H, G, S, Q); ';
  end if;
  select m.payload ->> 'sender_id' into v_txt
  from pg_temp.m5d_calls c
  join realtime.messages m on m.topic = 'table:' || c.tbl::text and m.payload ->> 'id' = c.res ->> 'id'
  where c.label = 'clean 14' and c.state is null;
  if v_txt is distinct from v_h::text then
    v_bad := v_bad || 'the text naming G''s sender_id was stored with sender ' || coalesce(v_txt, 'nothing') || ' (want H); ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [C5] sender_id: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== C6: nothing stored for a refusal ============================================
  select count(*) into v_n
  from realtime.messages m
  where m.topic in (select 'table:' || t::text from unnest(v_tables) as t)
    and m.payload ->> 'event' = 'chat';
  select count(*) into v_n2 from pg_temp.m5d_calls c where c.state is null;
  select count(*) into v_before from pg_temp.m5d_calls c where c.state is not null;
  if v_n <> v_n2 or v_before < 20 then
    raise exception 'FAIL [C6] % chat row(s) stored on the test tables'' topics for % sent call(s) (% refused).', v_n, v_n2, v_before;
  end if;
  v_checks := v_checks + 1;

  -- ==== C7: who receives (the live policies) ========================================
  select count(*) into v_n from realtime.messages m where m.topic = v_topic and m.payload ->> 'event' = 'chat';
  v_bad := '';
  for v_rec in
    select * from (values
      ('H (seated)', v_h, v_n), ('G (seated)', v_g, v_n), ('S (current spectator)', v_s, v_n),
      ('Z (stale spectator)', v_z, 0), ('R (removed spectator)', v_r, 0), ('O (nobody there)', v_o, 0),
      ('E (another table)', v_e, 0)
    ) as t(label, who, want)
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_rec.who, 'role', 'authenticated')::text, true);
    perform set_config('realtime.topic', v_topic, true);
    execute 'set local role authenticated';
    select count(*) into v_n2 from realtime.messages m where m.topic = v_topic and m.payload ->> 'event' = 'chat';
    execute 'reset role';
    if v_n2 <> v_rec.want then
      v_bad := v_bad || v_rec.label || ' saw ' || v_n2::text || ' (want ' || v_rec.want::text || '); ';
    end if;
  end loop;
  if v_n < 10 or v_bad <> '' then
    raise exception 'FAIL [C7] receiving T1''s % chat message(s): %', v_n, v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== C8: no write to the tables row ==============================================
  select t.ctid::text || '/' || t.xmin::text || '/' || coalesce(t.roster_version::text, '-') into v_txt from public.tables t where t.id = v_t1;
  if v_txt is distinct from v_snap1 then
    raise exception 'FAIL [C8] T1''s tables row changed during the sends: % -> %.', v_snap1, v_txt;
  end if;
  select t.ctid::text || '/' || t.xmin::text || '/' || coalesce(t.roster_version::text, '-') into v_txt from public.tables t where t.id = v_t4;
  if v_txt is distinct from v_snap4 then
    raise exception 'FAIL [C8] T4''s tables row changed during the sends: % -> %.', v_snap4, v_txt;
  end if;
  v_checks := v_checks + 1;

  -- ==== C9: a failed send is an error (run last) ====================================
  v_bad := '';
  -- (a) Stores nothing and only warns -- what realtime.send does when it
  -- cannot store.
  execute $r$
    create or replace function public._broadcast_table_message(p_topic text, p_payload jsonb)
    returns void
    language plpgsql
    volatile
    security definer
    set search_path = ''
    as $b$
    begin
      raise warning 'm5c1 verification: the store fails on purpose (as realtime.send only warns)';
    end;
    $b$
  $r$;
  perform pg_temp.m5d_clear(v_t1, v_h);
  v_before := pg_temp.m5d_rows(v_t1, v_h);
  v_r1 := pg_temp.m5d_send('failed store', v_h, v_t1, 'this one is never stored');
  if v_r1[1] is distinct from 'NBC05' or v_r1[2] is distinct from 'Couldn''t send. Please try again.' then
    v_bad := v_bad || 'nothing stored: ' || coalesce(v_r1[1] || ' ' || v_r1[2], 'a FALSE SUCCESS ' || coalesce(v_r1[5], '')) || ' (want NBC05); ';
  end if;
  if pg_temp.m5d_rows(v_t1, v_h) <> v_before then v_bad := v_bad || 'a row appeared; '; end if;
  -- (b) Raises.
  execute $r$
    create or replace function public._broadcast_table_message(p_topic text, p_payload jsonb)
    returns void
    language plpgsql
    volatile
    security definer
    set search_path = ''
    as $b$
    begin
      raise exception 'm5c1 verification: the send fails on purpose';
    end;
    $b$
  $r$;
  v_r1 := pg_temp.m5d_send('failed send', v_h, v_t1, 'this one fails');
  if v_r1[1] is distinct from 'NBC05' or v_r1[2] is distinct from 'Couldn''t send. Please try again.' then
    v_bad := v_bad || 'a raising send: ' || coalesce(v_r1[1] || ' ' || v_r1[2], 'a FALSE SUCCESS ' || coalesce(v_r1[5], '')) || ' (want NBC05); ';
  end if;
  if pg_temp.m5d_rows(v_t1, v_h) <> v_before then v_bad := v_bad || 'a row appeared after the raising send; '; end if;
  if v_bad <> '' then
    raise exception 'FAIL [C9] a failed send: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== VERDICT =====================================================================
  -- 4 catalog (K1-K4) + 9 behaviour (C1-C9).
  if v_checks <> 13 then
    raise exception 'FAIL: % checks ran, expected 13.', v_checks;
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back).% INFO: realtime.messages.inserted_at default: %.', v_checks, v_skips, coalesce(v_default, '(column not found)');
end;
$$;
