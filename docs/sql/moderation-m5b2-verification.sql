-- Moderation, slice M5 (b2): VERIFICATION of SCORES EVENTS
-- (docs/sql/moderation-m5b2-part1.sql).
--
-- Run in the Supabase Dashboard -> SQL Editor after part 1. The whole file
-- is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- It WRITES -- temporary functions and a temporary table in pg_temp, a
-- temporary REPLACEMENT of _send_scores_event (first a recorder, then one
-- that always raises), temporary accounts in auth.users and their
-- profiles, four test tables with seats and a spectator, games played
-- through the REAL game functions (as the players, through the same
-- impersonation as the earlier suites), awards made with the real
-- award_points, and (when Realtime can store them) event rows in
-- realtime.messages -- and then deliberately raises an exception at the
-- very end, which rolls EVERY write back (the replaced function included:
-- DDL is transactional). A check that fails raises its own exception at
-- once, which rolls everything back the same way. It always "fails": the
-- message is the verdict.
--   "ALL 19 CHECKS PASSED (rolled back)." is a pass -- or "ALL 17 CHECKS
--   PASSED (rolled back). Skipped N1-N2 ..." when Realtime can't store the
--   events here (no realtime.messages partition for today, or this role
--   cannot read them).
--   Anything starting "FAIL" or "SETUP" is not a pass.
--
-- HOW "AT COMMIT" IS TESTED INSIDE ONE TRANSACTION (as M5b1's suite): after
-- each call, m5c_fire() runs SET CONSTRAINTS ALL IMMEDIATE (which fires
-- every pending deferred trigger now, exactly as a commit would), then SET
-- CONSTRAINTS ALL DEFERRED again, and clears the per-table "already sent"
-- flags (m5b2.sent_<table id without dashes>) a real commit would end. A
-- call that fails is rolled back to its savepoint, and its pending triggers
-- with it.
--
-- HOW EVENTS ARE COUNTED: after the catalog checks, _send_scores_event is
-- replaced by a RECORDER that writes each (topic, payload) to
-- pg_temp.m5c_sent and then calls realtime.send exactly as the real one
-- does; N1-N2 compare with what Realtime stored, when it can.
--
-- now() IS FROZEN in a DO block, so every award would carry the same
-- last_awarded_at. Before each counted call, the table's existing awards
-- are moved one hour back (m5c_age, its own "commit" before the count
-- starts), so the call's own award is the newest -- as in real play, where
-- every award is its own transaction. A call is EXPECTED to send one event
-- when it wrote any of the four score columns: when the table's score rows
-- (score, last_points, last_reason, last_awarded_at) differ after it, or
-- for a game start (its reset always writes them, even with the same
-- values).
--
-- PEOPLE AND TABLES:
--   T1 H's (H, G; S watches; O is nobody there): a full hand, its counts,
--      Next Hand, his heels; then the second hand with the send failing.
--   T2 a 4-player Teams table (P1..P4): one award, two rows, one event.
--   T3 W1's (W1, W2): a game, its end, a new game (a new game_id); then
--      (C13) that second game cut to active and won.
--   T4 J1's (J1, J2; J3 joins): a join, a seat move and a leave send none.
--
-- WHAT IT CHECKS
--   K1  the two functions: part 1's bodies, security definer, search_path
--       '', no client role may execute them.
--   K2  table_members_zz_scores_event: a CONSTRAINT trigger, AFTER UPDATE
--       OF score, last_points, last_reason, last_awarded_at, ROW,
--       DEFERRABLE INITIALLY DEFERRED, enabled, calling
--       _scores_event_at_commit; its name sorts before M5a's
--       table_members_zz_table_event.
--   K3  the shapes: _send_scores_event sends (payload, 'scores', 'table:' ||
--       id, true) inside its own exception block; _scores_event_at_commit
--       builds exactly {event, game_id, award_ms, user_id, points, reason},
--       sets its per-table flag before sending, keeps its whole body inside
--       an exception block; no M5b2 body (comments aside) writes any table,
--       takes a lock, reads public.tables or names a card, hand, crib or
--       deck.
--   K4  every fingerprint the older suites hold is unchanged: the eight _as
--       bodies and their wrappers, the four end-empty-tables bodies, M3's
--       kick_player, M5a's five, M5b1's three.
--   C1  a game start (H at T1): exactly one event -- the reset: game_id the
--       NEW game, award_ms 0, user_id / points / reason null.
--   C2  the cut and the deal (every draw and acknowledgement): none.
--   C3  each discard: one event when it scored (his heels), none otherwise.
--   C4  each play: exactly one event when it scored, none when it didn't --
--       at least one play scores (the last card always does); each event is
--       the newest award: its scorer, points, reason, award_ms, game_id.
--   C5  the crib shown: none; each count step: exactly one (a 0-point "19"
--       count included).
--   C6  his heels (award_points, 2 for G): exactly one, user_id G, points
--       2, reason "his heels", award_ms = now in whole milliseconds.
--   C7  Teams (T2): one award -> both partners' scores move, exactly ONE
--       event, user_id the scorer (not the partner), game_id null (T2 never
--       had a game).
--   C8  none for a join, a seat move or a leave (T4), nor for Next Hand
--       taps or a game change without points (T1).
--   C9  a rolled-back award sends nothing and moves no score.
--   C10 every recorded event: exactly the keys event, game_id, award_ms,
--       user_id, points, reason; event 'scores'; on table:<its table>.
--   C11 a new game gives a new game_id: T3's second game's reset event
--       carries the second game's id, award_ms 0.
--   C12 no write to the tables row: T1's row (ctid, roster_version) is the
--       same before the plays and after the counts.
--   N1  (when Realtime stores them) T1's stored 'scores' events match the
--       recorded ones; each private, broadcast, with only the six keys
--       plus Realtime's own uuid "id".
--   N2  (when Realtime stores them) who RECEIVES them under the live
--       policies: H (seated) and S (current spectator) see every one; O
--       sees none.
--   C13 A FAILING SEND NEVER UNDOES AN AWARD, A COUNT OR A WIN (run last):
--       with _send_scores_event replaced by one that always raises (proved
--       to raise), an award (his heels at T1), T1's second hand (discards,
--       plays, crib, every count step) and the winning award at T3 all go
--       through. The win rule (award_points, phase3-e4-counting.sql) ends
--       only an ACTIVE game at a non-Muggins table, so T3's second game is
--       cut to active first (m5c_cut, as W1 and W2); then the 121-point
--       award ends it 'won' (winner W1) with the score at 121.

do $$
declare
  v_checks int := 0;
  v_expect int;
  v_live boolean := false;
  v_skips text := '';
  v_h uuid := gen_random_uuid();
  v_g uuid := gen_random_uuid();
  v_s uuid := gen_random_uuid();
  v_o uuid := gen_random_uuid();
  v_p1 uuid := gen_random_uuid();
  v_p2 uuid := gen_random_uuid();
  v_p3 uuid := gen_random_uuid();
  v_p4 uuid := gen_random_uuid();
  v_w1 uuid := gen_random_uuid();
  v_w2 uuid := gen_random_uuid();
  v_j1 uuid := gen_random_uuid();
  v_j2 uuid := gen_random_uuid();
  v_j3 uuid := gen_random_uuid();
  v_people uuid[];
  v_pid uuid;
  v_codes text[];
  v_t1 uuid;
  v_t2 uuid;
  v_t3 uuid;
  v_t4 uuid;
  v_g1 uuid;
  v_g3 uuid;
  v_g3b uuid;
  v_tables uuid[];
  v_r text[];
  v_rec record;
  v_txt text;
  v_bad text;
  v_n int;
  v_n2 int;
  v_before int;
  v_hand int;
  v_ctid text;
  v_rv bigint;
  v_state text;
  v_topic text;
  v_last jsonb;
  v_seat int;
  v_partner uuid;
begin
  -- ==== MODE ======================================================================
  if to_regprocedure('public._scores_event_at_commit()') is null
     or not exists (select 1 from pg_trigger tg where tg.tgname = 'table_members_zz_scores_event' and not tg.tgisinternal) then
    raise exception 'SETUP: part 1 is not in (no _scores_event_at_commit or its trigger). Run docs/sql/moderation-m5b2-part1.sql first.';
  end if;
  if to_regprocedure('public.card_play_value(text)') is null then
    raise exception 'SETUP: public.card_play_value(text) is missing (the hand below picks legal cards with it).';
  end if;

  -- ==== K: CATALOG (before anything is replaced) =====================================
  -- [K1] The two functions.
  v_bad := '';
  for v_rec in
    select * from (values
      ('public._send_scores_event(uuid, jsonb)', 'cf9d6f31090605e8e42ca7a26aae1d7d'),
      ('public._scores_event_at_commit()', 'd06cc5e9fb12f0b0697dd4b4e43bd8a9')
    ) as t(sig, lf)
  loop
    select v_rec.sig || ': '
           || case when md5(replace(p.prosrc, E'\r', '')) <> v_rec.lf then 'body md5 ' || md5(replace(p.prosrc, E'\r', '')) || ' ' else '' end
           || case when not p.prosecdef then 'not security definer ' else '' end
           || case when not (coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']) then 'search_path not empty ' else '' end
           || case when has_function_privilege('authenticated', p.oid, 'EXECUTE') then 'authenticated EXECUTE ' else '' end
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
    raise exception 'FAIL [K1] the M5b2 functions: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K2] The trigger.
  select count(*) into v_n
  from pg_trigger tg
  where tg.tgrelid = 'public.table_members'::regclass
    and tg.tgname = 'table_members_zz_scores_event'
    and not tg.tgisinternal
    and tg.tgenabled = 'O'
    and tg.tgfoid = to_regprocedure('public._scores_event_at_commit()')
    and (tg.tgtype & 1) = 1
    and (tg.tgtype & 2) = 0
    and (tg.tgtype & 28) = 16
    and tg.tgdeferrable and tg.tginitdeferred and tg.tgconstraint <> 0
    and (select string_agg(a.attname::text, ',' order by a.attname)
         from pg_attribute a
         where a.attrelid = tg.tgrelid and a.attnum = any(tg.tgattr::int2[])) = 'last_awarded_at,last_points,last_reason,score';
  if v_n <> 1 or not ('table_members_zz_scores_event' < 'table_members_zz_table_event') then
    raise exception 'FAIL [K2] table_members_zz_scores_event is not the deferred AFTER UPDATE OF the four score columns part 1 wrote (or does not sort before M5a''s trigger).';
  end if;
  v_checks := v_checks + 1;

  -- [K3] The shapes (comments removed for the "no write, no lock, no cards" rule).
  v_bad := '';
  select replace(p.prosrc, E'\r', '') into v_txt from pg_proc p where p.oid = to_regprocedure('public._send_scores_event(uuid, jsonb)');
  if v_txt !~ E'begin\\n    perform realtime\\.send\\(p_payload, ''scores'', ''table:'' \\|\\| p_table_id::text, true\\);\\n  exception when others then\\n    null;\\n  end;' then
    v_bad := v_bad || '_send_scores_event does not send (payload, scores, table:<id>, true) inside its own exception block; ';
  end if;
  select replace(p.prosrc, E'\r', '') into v_txt from pg_proc p where p.oid = to_regprocedure('public._scores_event_at_commit()');
  if strpos(v_txt, '''event'', ''scores'',') = 0 or strpos(v_txt, '''game_id'', v_game_id,') = 0
     or strpos(v_txt, '''award_ms'', coalesce(floor(extract(epoch from v_at) * 1000)::bigint, 0),') = 0
     or strpos(v_txt, '''user_id'', v_user_id,') = 0 or strpos(v_txt, '''points'', v_points,') = 0
     or strpos(v_txt, '''reason'', v_reason));') = 0
     or (length(v_txt) - length(replace(v_txt, 'jsonb_build_object', ''))) / length('jsonb_build_object') <> 1 then
    v_bad := v_bad || '_scores_event_at_commit does not build exactly {event, game_id, award_ms, user_id, points, reason}; ';
  end if;
  if strpos(v_txt, 'perform pg_catalog.set_config(v_flag, ''y'', true);') = 0
     or strpos(v_txt, 'perform pg_catalog.set_config(v_flag, ''y'', true);') > strpos(v_txt, 'perform public._send_scores_event(')
     or strpos(v_txt, 'v_flag := ''m5b2.sent_'' || replace(v_table_id::text, ''-'', '''');') = 0 then
    v_bad := v_bad || '_scores_event_at_commit does not set its per-table flag before sending; ';
  end if;
  if v_txt !~ E'^\\ndeclare[\\s\\S]*\\nbegin\\n[^\\n]*\\n[^\\n]*\\n  begin\\n[\\s\\S]*\\n  exception when others then\\n    null;\\n  end;\\n  return null;\\nend;\\n$' then
    v_bad := v_bad || '_scores_event_at_commit''s body is not wholly inside its own exception block; ';
  end if;
  select string_agg(p.proname::text, ', ') into v_txt
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('_send_scores_event', '_scores_event_at_commit')
    and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~* '(\minsert\s+into\M|\mupdate\s+public\.|\mdelete\s+from\M|\mfor\s+(no\s+key\s+)?update\M|\mfor\s+share\M|\mlock\s+table\M|public\.tables\M|game_hands|game_cribs|game_decks|\mcards?\M|\mnickname\M)';
  if v_txt is not null then
    raise exception 'FAIL [K3] %these bodies write, lock, read public.tables or name cards or nicknames: %', v_bad, v_txt;
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K3] %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K4] The older suites' fingerprints, unchanged.
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
      ('public._send_table_event(uuid, text, bigint)', 'df40bb9eac9b778a8d733d2d18393865'),
      ('public._table_event_on_members()', '26f95e1c2dd4cb5cffbb8e784367cd92'),
      ('public._table_event_on_spectators()', 'f81c329f92115ea11038cff9f0ffc184'),
      ('public._table_event_on_tables()', 'd950c48b22205b15e62e38411923fef5'),
      ('public.table_topic_allows(text)', '57908d750db883e7687b926cbea3ab4a'),
      ('public._bump_game_state_version()', '35314b3677dd7b0b39a2ca32ee29e7c3'),
      ('public._send_game_event(uuid, jsonb)', '462c8068b6c7a183ca76fa18fa6b7264'),
      ('public._game_event_at_commit()', 'cce9d688120f3dc2c155503270fe11ee'),
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
    raise exception 'FAIL [K4] fingerprinted bodies changed (carriage returns removed): %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP: helpers, the recorder, people, tables =================================
  create temp table m5c_sent (n serial primary key, topic text, payload jsonb) on commit drop;

  -- m5c_as(role, user, sql): one statement as that client role; returns
  -- {sqlstate, message, detail, hint, first column of the first row}.
  create function pg_temp.m5c_as(p_role text, p_uid uuid, p_sql text)
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

  -- m5c_fire(tables): "commit" -- fire every pending deferred trigger now,
  -- defer again, and clear the per-table flags a real commit would end.
  create function pg_temp.m5c_fire(p_tables uuid[])
  returns void
  language plpgsql
  as $f$
  declare
    v_one uuid;
  begin
    execute 'set constraints all immediate';
    execute 'set constraints all deferred';
    foreach v_one in array coalesce(p_tables, '{}'::uuid[]) loop
      perform set_config('m5b2.sent_' || replace(v_one::text, '-', ''), '', true);
    end loop;
  end;
  $f$;

  -- Events recorded for a table.
  create function pg_temp.m5c_events(p_table uuid)
  returns int
  language sql
  as $f$
    select count(*)::int from pg_temp.m5c_sent s where s.topic = 'table:' || p_table::text
  $f$;

  -- The table's score rows, as one string (did a call write them?).
  create function pg_temp.m5c_sig(p_table uuid)
  returns text
  language sql
  as $f$
    select coalesce(string_agg(tm.user_id::text || ':' || coalesce(tm.score::text, '-') || ':' || coalesce(tm.last_points::text, '-')
                               || ':' || coalesce(tm.last_reason, '-') || ':' || coalesce(tm.last_awarded_at::text, '-'), ',' order by tm.user_id), '')
    from public.table_members tm where tm.table_id = p_table
  $f$;

  -- The event the table's state should produce now (the trigger's own rule).
  create function pg_temp.m5c_expected(p_table uuid)
  returns jsonb
  language sql
  as $f$
    select jsonb_build_object(
      'event', 'scores',
      'game_id', (select g.id from public.games g where g.table_id = p_table order by g.created_at desc, g.id desc limit 1),
      'award_ms', coalesce((select floor(extract(epoch from tm.last_awarded_at) * 1000)::bigint from public.table_members tm
                            where tm.table_id = p_table and tm.last_awarded_at is not null
                            order by tm.last_awarded_at desc, tm.user_id desc limit 1), 0),
      'user_id', (select tm.user_id from public.table_members tm where tm.table_id = p_table and tm.last_awarded_at is not null
                  order by tm.last_awarded_at desc, tm.user_id desc limit 1),
      'points', (select tm.last_points from public.table_members tm where tm.table_id = p_table and tm.last_awarded_at is not null
                 order by tm.last_awarded_at desc, tm.user_id desc limit 1),
      'reason', (select tm.last_reason from public.table_members tm where tm.table_id = p_table and tm.last_awarded_at is not null
                 order by tm.last_awarded_at desc, tm.user_id desc limit 1))
  $f$;

  -- m5c_age(table, tables): the table's awards one hour back, then "commit"
  -- (its own event, before any count starts), so the next award is newest.
  create function pg_temp.m5c_age(p_table uuid, p_tables uuid[])
  returns void
  language plpgsql
  as $f$
  begin
    update public.table_members tm set last_awarded_at = tm.last_awarded_at - interval '1 hour'
    where tm.table_id = p_table and tm.last_awarded_at is not null;
    perform pg_temp.m5c_fire(p_tables);
  end;
  $f$;

  -- m5c_step(table, user, sql, tables, check, label, expect): one call that
  -- must work. With check: expect = 1 or 0 events, or -1 for "1 when it
  -- wrote the score rows, else 0"; one event must be the expected payload.
  create function pg_temp.m5c_step(p_table uuid, p_uid uuid, p_sql text, p_tables uuid[], p_check boolean, p_label text, p_expect int)
  returns text
  language plpgsql
  as $f$
  declare
    v_before int;
    v_sig text;
    v_want int;
    v_got int;
    v_res text[];
    v_last jsonb;
  begin
    if p_check then
      perform pg_temp.m5c_age(p_table, p_tables);
    end if;
    v_before := pg_temp.m5c_events(p_table);
    v_sig := pg_temp.m5c_sig(p_table);
    v_res := pg_temp.m5c_as('authenticated', p_uid, p_sql);
    perform pg_temp.m5c_fire(p_tables);
    if v_res[1] is not null then
      return p_label || ' refused: ' || coalesce(v_res[2], v_res[1]) || '; ';
    end if;
    if not p_check then
      return '';
    end if;
    v_want := case when p_expect >= 0 then p_expect when pg_temp.m5c_sig(p_table) is distinct from v_sig then 1 else 0 end;
    v_got := pg_temp.m5c_events(p_table) - v_before;
    if v_got <> v_want then
      return p_label || ' sent ' || v_got::text || ' scores event(s) (want ' || v_want::text || '); ';
    end if;
    if v_want = 1 then
      select s.payload into v_last from pg_temp.m5c_sent s where s.topic = 'table:' || p_table::text order by s.n desc limit 1;
      if v_last is distinct from pg_temp.m5c_expected(p_table) then
        return p_label || ': the event ' || v_last::text || ' is not the newest award ' || pg_temp.m5c_expected(p_table)::text || '; ';
      end if;
    end if;
    return '';
  end;
  $f$;

  -- The cut, round by round, until active (every step: expect).
  create function pg_temp.m5c_cut(p_table uuid, p_game uuid, p_a uuid, p_b uuid, p_tables uuid[], p_check boolean)
  returns text
  language plpgsql
  as $f$
  declare
    v_round int := 0;
    v_bad text := '';
  begin
    loop
      v_round := v_round + 1;
      if v_round > 12 then
        return v_bad || 'no decisive cut in 12 rounds; ';
      end if;
      v_bad := v_bad || pg_temp.m5c_step(p_table, p_a, format('select public.draw_cut_card(%L)::text', p_game), p_tables, p_check, 'cut ' || v_round || ' (a)', 0);
      v_bad := v_bad || pg_temp.m5c_step(p_table, p_b, format('select public.draw_cut_card(%L)::text', p_game), p_tables, p_check, 'cut ' || v_round || ' (b)', 0);
      v_bad := v_bad || pg_temp.m5c_step(p_table, p_a, format('select ''ok'' from public.acknowledge_deal_cut(%L)', p_game), p_tables, p_check, 'ack ' || v_round || ' (a)', 0);
      v_bad := v_bad || pg_temp.m5c_step(p_table, p_b, format('select ''ok'' from public.acknowledge_deal_cut(%L)', p_game), p_tables, p_check, 'ack ' || v_round || ' (b)', 0);
      if v_bad <> '' then
        return v_bad;
      end if;
      exit when (select g.status from public.games g where g.id = p_game) = 'active';
    end loop;
    return v_bad;
  end;
  $f$;

  -- Both discards (first two cards each): an event only when it scored.
  create function pg_temp.m5c_discards(p_table uuid, p_game uuid, p_a uuid, p_b uuid, p_tables uuid[], p_check boolean)
  returns text
  language plpgsql
  as $f$
  declare
    v_bad text := '';
    v_who uuid;
    v_cards text[];
  begin
    foreach v_who in array array[p_a, p_b] loop
      select gh.cards[1:2] into v_cards from public.game_hands gh where gh.game_id = p_game and gh.user_id = v_who;
      v_bad := v_bad || pg_temp.m5c_step(p_table, v_who, format('select ''ok'' from public.discard_to_crib(%L, %L::text[])', p_game, v_cards), p_tables, p_check, 'discard', -1);
    end loop;
    return v_bad;
  end;
  $f$;

  -- Pegging to the end: an event exactly when a play scored.
  create function pg_temp.m5c_peg(p_table uuid, p_game uuid, p_tables uuid[], p_check boolean)
  returns text
  language plpgsql
  as $f$
  declare
    v_phase text;
    v_cp uuid;
    v_count int;
    v_card text;
    v_i int := 0;
    v_bad text := '';
  begin
    loop
      select g.phase, g.current_player, g.play_count into v_phase, v_cp, v_count from public.games g where g.id = p_game;
      exit when v_phase is distinct from 'play';
      v_i := v_i + 1;
      if v_i > 12 then
        return v_bad || 'pegging did not finish in 12 plays; ';
      end if;
      select c into v_card
      from unnest((select gh.cards from public.game_hands gh where gh.game_id = p_game and gh.user_id = v_cp)) as c
      where not exists (select 1 from public.game_plays gp
                        where gp.game_id = p_game and gp.user_id = v_cp and gp.kind = 'play' and gp.card = c)
        and public.card_play_value(c) + v_count <= 31
      order by c
      limit 1;
      if v_card is null then
        return v_bad || 'no legal card for the player whose turn it is at count ' || v_count::text || '; ';
      end if;
      v_bad := v_bad || pg_temp.m5c_step(p_table, v_cp, format('select ''ok'' from public.play_card(%L, %L)', p_game, v_card), p_tables, p_check, 'play ' || v_i, -1);
      if v_bad <> '' then
        return v_bad;
      end if;
    end loop;
    return v_bad;
  end;
  $f$;

  -- Counting to the end: the crib shown (none), each count step (exactly one).
  create function pg_temp.m5c_count(p_table uuid, p_game uuid, p_tables uuid[], p_check boolean)
  returns text
  language plpgsql
  as $f$
  declare
    v_phase text;
    v_step int;
    v_cp uuid;
    v_dealer uuid;
    v_shown boolean;
    v_i int := 0;
    v_bad text := '';
  begin
    loop
      select g.phase, g.count_step, g.current_player, g.dealer_id, g.crib_revealed
      into v_phase, v_step, v_cp, v_dealer, v_shown
      from public.games g where g.id = p_game;
      exit when v_phase is distinct from 'counting';
      v_i := v_i + 1;
      if v_i > 6 then
        return v_bad || 'counting did not finish in 6 steps; ';
      end if;
      if v_step = 2 and v_shown is not true then
        v_bad := v_bad || pg_temp.m5c_step(p_table, v_dealer, format('select ''ok'' from public.show_crib(%L)', p_game), p_tables, p_check, 'show_crib', 0);
      end if;
      v_bad := v_bad || pg_temp.m5c_step(p_table, v_cp, format('select ''ok'' from public.confirm_count(%L, %s)', p_game, v_step), p_tables, p_check, 'count step ' || v_step, 1);
      if v_bad <> '' then
        return v_bad;
      end if;
    end loop;
    return v_bad;
  end;
  $f$;

  -- THE RECORDER: _send_scores_event writes what it is given to
  -- pg_temp.m5c_sent, then sends it exactly as the real one does.
  execute $r$
    create or replace function public._send_scores_event(p_table_id uuid, p_payload jsonb)
    returns void
    language plpgsql
    volatile
    security definer
    set search_path = ''
    as $b$
    begin
      insert into pg_temp.m5c_sent (topic, payload) values ('table:' || p_table_id::text, p_payload);
      begin
        perform realtime.send(p_payload, 'scores', 'table:' || p_table_id::text, true);
      exception when others then
        null;
      end;
    end;
    $b$
  $r$;

  v_people := array[v_h, v_g, v_s, v_o, v_p1, v_p2, v_p3, v_p4, v_w1, v_w2, v_j1, v_j2, v_j3];
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'm5b2-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      insert into public.profiles (id, nickname)
      values (v_pid, 'm5c' || left(replace(v_pid::text, '-', ''), 12))
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
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[1], v_h, true, true, 2) returning id into v_t1;
    insert into public.table_members (table_id, user_id) values (v_t1, v_h);
    insert into public.table_members (table_id, user_id) values (v_t1, v_g);
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at) values (v_t1, v_s, now(), now());
    insert into public.tables (code, created_by, is_public, max_players, team_mode)
    values (v_codes[2], v_p1, true, 4, 'teams') returning id into v_t2;
    insert into public.table_members (table_id, user_id) values (v_t2, v_p1);
    insert into public.table_members (table_id, user_id) values (v_t2, v_p2);
    insert into public.table_members (table_id, user_id) values (v_t2, v_p3);
    insert into public.table_members (table_id, user_id) values (v_t2, v_p4);
    insert into public.tables (code, created_by, is_public, max_players)
    values (v_codes[3], v_w1, true, 2) returning id into v_t3;
    insert into public.table_members (table_id, user_id) values (v_t3, v_w1);
    insert into public.table_members (table_id, user_id) values (v_t3, v_w2);
    insert into public.tables (code, created_by, is_public, max_players)
    values (v_codes[4], v_j1, true, 4) returning id into v_t4;
    insert into public.table_members (table_id, user_id) values (v_t4, v_j1);
    insert into public.table_members (table_id, user_id) values (v_t4, v_j2);
  exception when others then
    raise exception 'SETUP: could not create the test tables: % (%).', sqlerrm, sqlstate;
  end;
  v_tables := array[v_t1, v_t2, v_t3, v_t4];
  v_topic := 'table:' || v_t1::text;
  perform pg_temp.m5c_fire(v_tables);
  if (select count(*) from pg_temp.m5c_sent) <> 0 then
    raise exception 'SETUP: seating sent % scores event(s); a join must send none.', (select count(*) from pg_temp.m5c_sent);
  end if;

  -- ==== C: ONE SCORES EVENT PER AWARD, THROUGH THE REAL FUNCTIONS ===================
  -- [C1] H starts T1's game: the reset.
  v_before := pg_temp.m5c_events(v_t1);
  v_r := pg_temp.m5c_as('authenticated', v_h, format('select public.start_game_with_deal(%L)::text', v_t1));
  perform pg_temp.m5c_fire(v_tables);
  v_g1 := v_r[5]::uuid;
  select s.payload into v_last from pg_temp.m5c_sent s where s.topic = v_topic order by s.n desc limit 1;
  if v_r[1] is not null or v_g1 is null or pg_temp.m5c_events(v_t1) - v_before <> 1
     or v_last is distinct from jsonb_build_object('event', 'scores', 'game_id', v_g1, 'award_ms', 0,
                                                    'user_id', null, 'points', null, 'reason', null) then
    raise exception 'FAIL [C1] H starting T1''s game: % (error %); % scores event(s), the last %; want one reset: the new game, award_ms 0, the rest null.',
      coalesce(v_r[5], '-'), coalesce(v_r[2], 'none'), pg_temp.m5c_events(v_t1) - v_before, coalesce(v_last::text, '-');
  end if;
  v_checks := v_checks + 1;

  -- [C2] The cut and the deal: none.
  v_bad := pg_temp.m5c_cut(v_t1, v_g1, v_h, v_g, v_tables, true);
  if v_bad <> '' then
    raise exception 'FAIL [C2] the cut and the deal at T1: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C3] The discards: one event only when it scored (his heels).
  v_bad := pg_temp.m5c_discards(v_t1, v_g1, v_h, v_g, v_tables, true);
  if v_bad <> '' or (select g.phase from public.games g where g.id = v_g1) is distinct from 'play' then
    raise exception 'FAIL [C3] the discards at T1: %(phase %).', v_bad, (select g.phase from public.games g where g.id = v_g1);
  end if;
  v_checks := v_checks + 1;

  -- T1's tables row before the plays (C12).
  select t.ctid::text, t.roster_version into v_ctid, v_rv from public.tables t where t.id = v_t1;

  -- [C4] Every play: an event exactly when it scored (checked play by play
  -- in m5c_step); and at least one play scores (the last card always does).
  select coalesce(sum(tm.score), 0) into v_before from public.table_members tm where tm.table_id = v_t1;
  v_bad := pg_temp.m5c_peg(v_t1, v_g1, v_tables, true);
  if v_bad <> '' or (select g.phase from public.games g where g.id = v_g1) is distinct from 'counting' then
    raise exception 'FAIL [C4] pegging at T1: %(phase %).', v_bad, (select g.phase from public.games g where g.id = v_g1);
  end if;
  if (select coalesce(sum(tm.score), 0) from public.table_members tm where tm.table_id = v_t1) <= v_before then
    raise exception 'FAIL [C4] no play at T1 scored (the last card always does), so no play''s event was tested.';
  end if;
  v_checks := v_checks + 1;

  -- [C5] The crib (none) and each count step (exactly one).
  v_bad := pg_temp.m5c_count(v_t1, v_g1, v_tables, true);
  if v_bad <> '' or (select g.phase from public.games g where g.id = v_g1) is distinct from 'done' then
    raise exception 'FAIL [C5] counting at T1: %(phase %).', v_bad, (select g.phase from public.games g where g.id = v_g1);
  end if;
  v_checks := v_checks + 1;

  -- [C12] (checked here, after the plays and the counts) The tables row untouched.
  if (select t.ctid::text from public.tables t where t.id = v_t1) is distinct from v_ctid
     or (select t.roster_version from public.tables t where t.id = v_t1) is distinct from v_rv then
    raise exception 'FAIL [C12] T1''s tables row changed during the plays and the counts (ctid % -> %, roster_version % -> %): the scores events must not write it.',
      v_ctid, (select t.ctid::text from public.tables t where t.id = v_t1), v_rv, (select t.roster_version from public.tables t where t.id = v_t1);
  end if;
  v_checks := v_checks + 1;

  -- [C8, T1 part] Next Hand taps (a game change without points): none.
  select g.hand_no into v_hand from public.games g where g.id = v_g1;
  v_bad := pg_temp.m5c_step(v_t1, v_h, format('select ''ok'' from public.next_hand(%L, %s)', v_g1, v_hand), v_tables, true, 'H''s Next Hand', 0);
  v_bad := v_bad || pg_temp.m5c_step(v_t1, v_g, format('select ''ok'' from public.next_hand(%L, %s)', v_g1, v_hand), v_tables, true, 'G''s Next Hand', 0);
  if v_bad <> '' then
    raise exception 'FAIL [C8] Next Hand at T1: %', v_bad;
  end if;

  -- [C6] His heels, for G.
  perform pg_temp.m5c_age(v_t1, v_tables);
  v_before := pg_temp.m5c_events(v_t1);
  perform public.award_points(v_t1, v_g, 2, 'his heels');
  perform pg_temp.m5c_fire(v_tables);
  select s.payload into v_last from pg_temp.m5c_sent s where s.topic = v_topic order by s.n desc limit 1;
  if pg_temp.m5c_events(v_t1) - v_before <> 1
     or v_last ->> 'user_id' is distinct from v_g::text or (v_last ->> 'points')::int is distinct from 2
     or v_last ->> 'reason' is distinct from 'his heels'
     or (v_last ->> 'award_ms')::bigint is distinct from floor(extract(epoch from now()) * 1000)::bigint
     or v_last ->> 'game_id' is distinct from v_g1::text then
    raise exception 'FAIL [C6] his heels for G: % event(s), the last %; want one: G, 2, his heels, now in ms, T1''s game.',
      pg_temp.m5c_events(v_t1) - v_before, coalesce(v_last::text, '-');
  end if;
  v_checks := v_checks + 1;

  -- [C7] Teams: one award, both partners' rows, ONE event, the scorer named.
  select tm.seat into v_seat from public.table_members tm where tm.table_id = v_t2 and tm.user_id = v_p1;
  select tm.user_id into v_partner from public.table_members tm
  where tm.table_id = v_t2 and tm.user_id <> v_p1 and tm.seat % 2 = v_seat % 2;
  v_before := pg_temp.m5c_events(v_t2);
  perform public.award_points(v_t2, v_p1, 2, 'pair');
  perform pg_temp.m5c_fire(v_tables);
  select s.payload into v_last from pg_temp.m5c_sent s where s.topic = 'table:' || v_t2::text order by s.n desc limit 1;
  if v_partner is null
     or (select tm.score from public.table_members tm where tm.table_id = v_t2 and tm.user_id = v_p1) is distinct from 2
     or (select tm.score from public.table_members tm where tm.table_id = v_t2 and tm.user_id = v_partner) is distinct from 2
     or pg_temp.m5c_events(v_t2) - v_before <> 1
     or v_last is distinct from jsonb_build_object('event', 'scores', 'game_id', null,
                                                    'award_ms', floor(extract(epoch from now()) * 1000)::bigint,
                                                    'user_id', v_p1, 'points', 2, 'reason', 'pair') then
    raise exception 'FAIL [C7] a Teams award at T2: partner %, scores % / %, % event(s), the last %; want both at 2, one event naming the scorer, game_id null.',
      coalesce(v_partner::text, '(none found)'),
      (select tm.score from public.table_members tm where tm.table_id = v_t2 and tm.user_id = v_p1),
      (select tm.score from public.table_members tm where tm.table_id = v_t2 and tm.user_id = v_partner),
      pg_temp.m5c_events(v_t2) - v_before, coalesce(v_last::text, '-');
  end if;
  v_checks := v_checks + 1;

  -- [C8] A join, a seat move and a leave at T4: none.
  v_before := pg_temp.m5c_events(v_t4);
  insert into public.table_members (table_id, user_id) values (v_t4, v_j3);
  perform pg_temp.m5c_fire(v_tables);
  select min(s.n) into v_seat from generate_series(1, 4) s(n)
  where not exists (select 1 from public.table_members tm where tm.table_id = v_t4 and tm.seat = s.n);
  update public.table_members tm set seat = v_seat where tm.table_id = v_t4 and tm.user_id = v_j1;
  perform pg_temp.m5c_fire(v_tables);
  v_r := pg_temp.m5c_as('authenticated', v_j2, format('select ''ok'' from public.leave_table(%L)', v_t4));
  perform pg_temp.m5c_fire(v_tables);
  if v_r[1] is not null or pg_temp.m5c_events(v_t4) - v_before <> 0
     or not exists (select 1 from public.table_members tm where tm.table_id = v_t4 and tm.user_id = v_j3)
     or exists (select 1 from public.table_members tm where tm.table_id = v_t4 and tm.user_id = v_j2) then
    raise exception 'FAIL [C8] a join, a seat move (to %) and a leave at T4: leave error %, % scores event(s); want none.',
      coalesce(v_seat::text, '-'), coalesce(v_r[2], 'none'), pg_temp.m5c_events(v_t4) - v_before;
  end if;
  v_checks := v_checks + 1;

  -- [C9] A rolled-back award sends nothing and moves no score.
  v_before := (select count(*) from pg_temp.m5c_sent);
  v_txt := pg_temp.m5c_sig(v_t1);
  begin
    perform public.award_points(v_t1, v_h, 5, 'rolled back');
    raise exception 'm5b2 verification: roll this back';
  exception when others then
    null;
  end;
  perform pg_temp.m5c_fire(v_tables);
  if (select count(*) from pg_temp.m5c_sent) <> v_before or pg_temp.m5c_sig(v_t1) is distinct from v_txt then
    raise exception 'FAIL [C9] a rolled-back award sent % event(s) or moved a score; want none.', (select count(*) from pg_temp.m5c_sent) - v_before;
  end if;
  v_checks := v_checks + 1;

  -- [C11] A new game gives a new game_id (T3: a game, its end, a new game).
  v_r := pg_temp.m5c_as('authenticated', v_w1, format('select public.start_game_with_deal(%L)::text', v_t3));
  perform pg_temp.m5c_fire(v_tables);
  v_g3 := v_r[5]::uuid;
  update public.games g set status = 'ended', ended_reason = 'admin', created_at = g.created_at - interval '1 minute' where g.id = v_g3;
  perform pg_temp.m5c_fire(v_tables);
  v_before := pg_temp.m5c_events(v_t3);
  v_r := pg_temp.m5c_as('authenticated', v_w1, format('select public.start_game_with_deal(%L)::text', v_t3));
  perform pg_temp.m5c_fire(v_tables);
  v_g3b := v_r[5]::uuid;
  select s.payload into v_last from pg_temp.m5c_sent s where s.topic = 'table:' || v_t3::text order by s.n desc limit 1;
  if v_g3 is null or v_g3b is null or v_g3b = v_g3 or pg_temp.m5c_events(v_t3) - v_before <> 1
     or v_last is distinct from jsonb_build_object('event', 'scores', 'game_id', v_g3b, 'award_ms', 0,
                                                    'user_id', null, 'points', null, 'reason', null) then
    raise exception 'FAIL [C11] T3''s second game (% after %, error %): % event(s), the last %; want one reset naming the NEW game.',
      coalesce(v_g3b::text, '-'), coalesce(v_g3::text, '-'), coalesce(v_r[2], 'none'), pg_temp.m5c_events(v_t3) - v_before, coalesce(v_last::text, '-');
  end if;
  v_checks := v_checks + 1;

  -- [C10] Every recorded event: exactly the six keys, its event and topic.
  select count(*) into v_n
  from pg_temp.m5c_sent s
  where (select string_agg(k, ',' order by k) from jsonb_object_keys(s.payload) as k) is distinct from 'award_ms,event,game_id,points,reason,user_id'
     or s.payload ->> 'event' is distinct from 'scores'
     or jsonb_typeof(s.payload -> 'award_ms') is distinct from 'number'
     or s.topic !~ '^table:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or substr(s.topic, 7)::uuid <> all(v_tables);
  if v_n <> 0 or (select count(*) from pg_temp.m5c_sent) = 0 then
    raise exception 'FAIL [C10] % recorded event(s) with other keys, event or topic (of %); sample %.', v_n, (select count(*) from pg_temp.m5c_sent),
      (select s.topic || ' ' || s.payload::text from pg_temp.m5c_sent s order by s.n limit 1);
  end if;
  v_checks := v_checks + 1;

  -- [N1] The stored copies, when Realtime can store them.
  begin
    select count(*) into v_n from realtime.messages m where m.topic = v_topic and m.event = 'scores';
  exception when others then
    v_n := -1;
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  if v_n = -1 then
    v_skips := ' Skipped N1-N2: this role cannot read realtime.messages (' || v_txt || ').';
  elsif v_n = 0 then
    v_skips := ' Skipped N1-N2: no scores event was stored (usually no realtime.messages partition for today; every award above still went through).';
  elsif not has_table_privilege('authenticated', 'realtime.messages', 'SELECT') then
    v_skips := ' Skipped N1-N2: authenticated lacks SELECT on realtime.messages.';
  else
    v_live := true;
    select count(*) into v_n2 from pg_temp.m5c_sent s where s.topic = v_topic;
    select count(*) into v_before
    from realtime.messages m
    where m.topic = v_topic and m.event = 'scores'
      and (m.private is distinct from true or m.extension is distinct from 'broadcast'
           or not (m.payload ?& array['event', 'game_id', 'award_ms', 'user_id', 'points', 'reason'])
           or exists (select 1 from jsonb_object_keys(m.payload) as pk(key)
                      where pk.key not in ('event', 'game_id', 'award_ms', 'user_id', 'points', 'reason', 'id'))
           or (m.payload ? 'id' and coalesce(m.payload ->> 'id', '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'));
    if v_n <> v_n2 or v_before <> 0 then
      raise exception 'FAIL [N1] % stored scores event(s) on T1''s topic, % recorded; % stored row(s) not private, not broadcast, or with other keys.', v_n, v_n2, v_before;
    end if;
    v_checks := v_checks + 1;
  end if;

  -- [N2] Who receives them.
  if v_live then
    select count(*) into v_n from realtime.messages m where m.topic = v_topic and m.event = 'scores';
    v_bad := '';
    for v_rec in
      select * from (values ('H (seated)', v_h, v_n), ('S (current spectator)', v_s, v_n), ('O (nobody there)', v_o, 0)) as t(label, who, want)
    loop
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.who, 'role', 'authenticated')::text, true);
      perform set_config('realtime.topic', v_topic, true);
      execute 'set local role authenticated';
      select count(*) into v_n2 from realtime.messages m where m.topic = v_topic and m.event = 'scores';
      execute 'reset role';
      if v_n2 <> v_rec.want then
        v_bad := v_bad || v_rec.label || ' saw ' || v_n2::text || ' (want ' || v_rec.want::text || '); ';
      end if;
    end loop;
    if v_bad <> '' then
      raise exception 'FAIL [N2] receiving T1''s scores events: %', v_bad;
    end if;
    v_checks := v_checks + 1;
  end if;

  -- [C13] A failing send never undoes an award, a count or a win (run last).
  execute $r$
    create or replace function public._send_scores_event(p_table_id uuid, p_payload jsonb)
    returns void
    language plpgsql
    volatile
    security definer
    set search_path = ''
    as $b$
    begin
      raise exception 'm5b2 verification: the send fails on purpose';
    end;
    $b$
  $r$;
  v_state := null;
  begin
    perform public._send_scores_event(v_t1, '{}'::jsonb);
  exception when others then
    v_state := sqlstate;
  end;
  v_bad := '';
  -- An award.
  v_txt := pg_temp.m5c_sig(v_t1);
  begin
    perform public.award_points(v_t1, v_h, 2, 'his heels');
    perform pg_temp.m5c_fire(v_tables);
  exception when others then
    v_bad := v_bad || 'the award: ' || sqlerrm || '; ';
  end;
  if pg_temp.m5c_sig(v_t1) is not distinct from v_txt then
    v_bad := v_bad || 'the award did not stand; ';
  end if;
  -- T1's second hand: discards, plays, the crib, every count step.
  v_bad := v_bad || pg_temp.m5c_discards(v_t1, v_g1, v_h, v_g, v_tables, false);
  v_bad := v_bad || pg_temp.m5c_peg(v_t1, v_g1, v_tables, false);
  v_bad := v_bad || pg_temp.m5c_count(v_t1, v_g1, v_tables, false);
  if (select g.phase from public.games g where g.id = v_g1) is distinct from 'done' then
    v_bad := v_bad || 'T1''s second hand did not finish counting (phase ' || coalesce((select g.phase from public.games g where g.id = v_g1), '-') || '); ';
  end if;
  -- The winning award at T3. The win rule ends only an ACTIVE game, so its
  -- second game (still cutting since C11) is cut to active first -- with
  -- the send still failing.
  v_txt := pg_temp.m5c_cut(v_t3, v_g3b, v_w1, v_w2, v_tables, false);
  if v_txt <> '' or (select g.status from public.games g where g.id = v_g3b) is distinct from 'active' then
    raise exception 'FAIL [C13] SETUP: T3''s second game did not reach active before the winning award (status %): %',
      coalesce((select g.status from public.games g where g.id = v_g3b), '-'), coalesce(nullif(v_txt, ''), 'no step refused');
  end if;
  begin
    perform public.award_points(v_t3, v_w1, 121, 'test win');
    perform pg_temp.m5c_fire(v_tables);
  exception when others then
    v_bad := v_bad || 'the winning award: ' || sqlerrm || '; ';
  end;
  if (select g.status || '/' || coalesce(g.ended_reason, '-') from public.games g where g.id = v_g3b) is distinct from 'ended/won'
     or (select tm.score from public.table_members tm where tm.table_id = v_t3 and tm.user_id = v_w1) is distinct from 121 then
    v_bad := v_bad || 'the win did not stand (T3''s game ' || coalesce((select g.status || '/' || coalesce(g.ended_reason, '-') from public.games g where g.id = v_g3b), '-') || '); ';
  end if;
  if v_state is null or v_bad <> '' then
    raise exception 'FAIL [C13] with the send failing (it raised: %): %', coalesce(v_state, 'NO -- the test send did not fail'), v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== VERDICT =====================================================================
  -- 4 catalog (K1-K4) + 13 behaviour (C1-C13) + 2 stored (N1-N2, only when
  -- Realtime stores the events). The expected count goes into a variable
  -- first (a CASE inside an IF condition is a syntax trap in PL/pgSQL).
  v_expect := 17 + (case when v_live then 2 else 0 end);
  if v_checks <> v_expect then
    raise exception 'FAIL: % checks ran, expected %.', v_checks, v_expect;
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back).%', v_checks, v_skips;
end;
$$;
