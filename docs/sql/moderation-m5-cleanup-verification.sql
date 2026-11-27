-- Moderation, M5 FINAL CLEANUP: VERIFICATION of taking the old tables out of
-- the supabase_realtime publication (docs/sql/moderation-m5-cleanup-part1.sql).
--
-- Run in the Supabase Dashboard -> SQL Editor after part 1. The whole file
-- is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- It WRITES -- temporary functions in pg_temp, temporary accounts in
-- auth.users and their profiles, one test table with two players and a
-- spectator, a game played through the REAL game functions up to its first
-- play (as the players, through the same impersonation as the earlier
-- suites), one award, one chat message, and the event rows Realtime stores
-- for them in realtime.messages -- and then deliberately raises an exception
-- at the very end, which rolls EVERY write back (nothing commits, so nothing
-- is broadcast). A check that fails raises its own exception at once, which
-- rolls everything back the same way. It always "fails": the message is the
-- verdict.
--   "ALL 8 CHECKS PASSED (rolled back)." is a pass.
--   Anything starting "FAIL" or "SETUP" is not a pass.
--
-- It NEEDS Realtime to store messages right now (today's realtime.messages
-- partition) and authenticated to have SELECT on realtime.messages; it
-- probes first and stops at SETUP otherwise.
--
-- AT COMMIT, INSIDE ONE TRANSACTION (as the M5b1/M5b2 suites): the game and
-- scores events come from DEFERRED triggers. m6_fire runs SET CONSTRAINTS
-- ALL IMMEDIATE (which fires them now, exactly as a commit would), then
-- DEFERRED again, and clears their per-game / per-table "already sent"
-- flags (m5b1.sent_<game>, m5b2.sent_<table>) as a real commit would. The
-- table events (M5a) and chat are sent at once anyway.
--
-- WHAT IT CHECKS
--   K1  THE PUBLICATION: supabase_realtime still exists and is not FOR ALL
--       TABLES; none of public.game_plays, games, profiles, table_members,
--       tables is in it; public.table_spectators is not in it either.
--   K2  THE LIVE PATH IS UNCHANGED: the event functions' bodies (M5a's
--       five, M5b1's three, M5b2's two, send_table_message and its helper)
--       match their fingerprints, and their seven triggers are enabled.
--   K3  realtime.messages still has exactly its two receive-only policies
--       (kicks, table events).
--   C1  A SEAT CHANGE still sends a 'members' event on table:<T>: H and G
--       swap seats and swap back (one statement each, as set_seat does --
--       seats are NOT NULL, 1-4 and unique per table, the unique check
--       deferred to the end of the statement), four seat changes -> four
--       'members' events, the highest roster_version the table's own; the
--       seats end exactly as they started.
--   C2  A PLAY (play_card, as the player whose turn it is) still sends a
--       'game' event at commit, its last_play_seq the play's seq.
--   C3  A SCORE (award_points) still sends ONE 'scores' event at commit:
--       the scorer and the points.
--   C4  A CHAT MESSAGE (send_table_message, as a player) still sends one
--       'chat' event, its sender the caller.
--   C5  THEY STILL REACH THE TABLE: under the live policies, G (seated) and
--       S (current spectator) see every one of those events on table:<T>;
--       O (nobody there) sees none.

do $$
declare
  v_checks int := 0;
  v_h uuid := gen_random_uuid();
  v_g uuid := gen_random_uuid();
  v_s uuid := gen_random_uuid();
  v_o uuid := gen_random_uuid();
  v_pid uuid;
  v_code text;
  v_t uuid;
  v_game uuid;
  v_topic text;
  v_probe text;
  v_r text[];
  v_rec record;
  v_txt text;
  v_bad text;
  v_n int;
  v_n2 int;
  v_before int;
  v_round int;
  v_who uuid;
  v_cards text[];
  v_cp uuid;
  v_count int;
  v_card text;
  v_seq int;
  v_last jsonb;
begin
  -- ==== K: CATALOG ===================================================================
  -- [K1] The publication.
  v_bad := '';
  if not exists (select 1 from pg_publication p where p.pubname = 'supabase_realtime') then
    v_bad := v_bad || 'supabase_realtime is gone; ';
  elsif (select p.puballtables from pg_publication p where p.pubname = 'supabase_realtime') then
    v_bad := v_bad || 'supabase_realtime is FOR ALL TABLES; ';
  end if;
  select string_agg(pt.tablename::text, ', ' order by pt.tablename) into v_txt
  from pg_publication_tables pt
  where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public'
    and pt.tablename in ('game_plays', 'games', 'profiles', 'table_members', 'tables', 'table_spectators');
  if v_txt is not null then
    v_bad := v_bad || 'still published: ' || v_txt || '; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K1] %(run docs/sql/moderation-m5-cleanup-part1.sql first?)', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K2] The live event path, unchanged.
  v_bad := '';
  for v_rec in
    select * from (values
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
      ('public.send_table_message(uuid, text)', 'e3adcc4874c77c1c47530a807fefd815'),
      ('public._broadcast_table_message(text, jsonb)', 'e5f16aebb3ca764c806e2567b68090fc')
    ) as t(sig, lf)
  loop
    select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.sig);
    if v_txt is distinct from v_rec.lf then
      v_bad := v_bad || v_rec.sig || ' md5 ' || coalesce(v_txt, 'missing') || '; ';
    end if;
  end loop;
  for v_rec in
    select * from (values
      ('public.table_members', 'table_members_zz_table_event'),
      ('public.table_spectators', 'table_spectators_zz_table_event'),
      ('public.tables', 'tables_zz_table_event'),
      ('public.games', 'games_state_version'),
      ('public.games', 'games_zz_game_event'),
      ('public.game_plays', 'game_plays_zz_game_event'),
      ('public.table_members', 'table_members_zz_scores_event')
    ) as t(rel, name)
  loop
    if not exists (select 1 from pg_trigger tg where tg.tgrelid = to_regclass(v_rec.rel) and tg.tgname = v_rec.name
                     and not tg.tgisinternal and tg.tgenabled = 'O') then
      v_bad := v_bad || 'trigger ' || v_rec.name || ' missing or disabled; ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [K2] the live event path changed: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K3] realtime.messages: the two receive-only policies.
  select count(*) into v_n from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages';
  select count(*) into v_n2 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages' and p.cmd = 'SELECT'
    and p.policyname in ('table kicks: people at the table receive', 'table events: people at the table receive');
  if v_n <> 2 or v_n2 <> 2 then
    raise exception 'FAIL [K3] realtime.messages has % policies, % of the two receive-only ones (want 2 and 2).', v_n, v_n2;
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP: helpers ===============================================================
  -- m6_as(role, user, sql): one statement as that client role; returns
  -- {sqlstate, message, detail, hint, first column of the first row}.
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

  -- m6_fire(table, game): "commit" -- fire every pending deferred trigger
  -- now, defer again, and clear the "already sent" flags a commit would end.
  create function pg_temp.m6_fire(p_table uuid, p_game uuid)
  returns void
  language plpgsql
  as $f$
  begin
    execute 'set constraints all immediate';
    execute 'set constraints all deferred';
    perform set_config('m5b2.sent_' || replace(p_table::text, '-', ''), '', true);
    if p_game is not null then
      perform set_config('m5b1.sent_' || replace(p_game::text, '-', ''), '', true);
    end if;
  end;
  $f$;

  -- Stored events of one kind on a topic (as the owner).
  create function pg_temp.m6_count(p_topic text, p_kind text)
  returns int
  language sql
  as $f$
    select count(*)::int from realtime.messages m
    where m.topic = p_topic and m.extension = 'broadcast' and m.private = true and m.payload ->> 'event' = p_kind
  $f$;

  -- What a person may SELECT on a topic, with realtime.topic set as Realtime
  -- sets it (what joining and receiving there may see), of one kind.
  create function pg_temp.m6_sees(p_uid uuid, p_topic text, p_kind text)
  returns int
  language plpgsql
  as $f$
  declare
    v_n int;
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    perform set_config('realtime.topic', p_topic, true);
    execute 'set local role authenticated';
    select count(*) into v_n from realtime.messages m where m.topic = p_topic and m.payload ->> 'event' = p_kind;
    execute 'reset role';
    return v_n;
  end;
  $f$;

  -- ==== SETUP: can Realtime store? ===================================================
  v_probe := 'table:' || gen_random_uuid()::text;
  begin
    perform realtime.send(jsonb_build_object('event', 'm5-cleanup-probe'), 'm5-cleanup-probe', v_probe, true);
    select count(*) into v_n from realtime.messages m where m.topic = v_probe;
  exception when others then
    raise exception 'SETUP: could not send or read a test broadcast: % (%).', sqlerrm, sqlstate;
  end;
  if v_n <> 1 then
    raise exception 'SETUP: Realtime did not store a test broadcast (usually: no realtime.messages partition for today, or this role cannot read past its row-level security). Nothing can be checked meanwhile.';
  end if;
  if not has_table_privilege('authenticated', 'realtime.messages', 'SELECT') then
    raise exception 'SETUP: authenticated lacks SELECT on realtime.messages (C5 reads as each person).';
  end if;
  if to_regprocedure('public.card_play_value(text)') is null then
    raise exception 'SETUP: public.card_play_value(text) is missing (the play below picks a legal card with it).';
  end if;

  -- ==== SETUP: people and the table =================================================
  begin
    foreach v_pid in array array[v_h, v_g, v_s, v_o] loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'm5-cleanup-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      insert into public.profiles (id, nickname)
      values (v_pid, 'm6' || left(replace(v_pid::text, '-', ''), 12))
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
    values (v_code, v_h, true, true, 2) returning id into v_t;
    insert into public.table_members (table_id, user_id) values (v_t, v_h);
    insert into public.table_members (table_id, user_id) values (v_t, v_g);
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at) values (v_t, v_s, now(), now());
  exception when others then
    raise exception 'SETUP: could not create the test table: % (%).', sqlerrm, sqlstate;
  end;
  v_topic := 'table:' || v_t::text;
  perform pg_temp.m6_fire(v_t, null);

  -- ==== C1: a seat change -> a 'members' event =======================================
  -- H and G SWAP seats, then swap back -- each swap ONE statement, the way
  -- set_seat does it: table_members.seat is NOT NULL, between 1 and 4, and
  -- unique per table (table_members_table_id_seat_key, DEFERRABLE INITIALLY
  -- IMMEDIATE: checked at the end of the statement, so a one-statement swap
  -- is allowed). At this 2-seat table both seats are taken, so a swap is the
  -- only seat change that stays inside the table's size. Each row moved is
  -- one 'members' event (UPDATE OF seat to another value): 2 per swap, 4 in
  -- all. The table ends exactly as it started (seats as assigned), so the
  -- game below seats both players as before.
  select tm.seat into v_n2 from public.table_members tm where tm.table_id = v_t and tm.user_id = v_h;
  select tm.seat into v_n from public.table_members tm where tm.table_id = v_t and tm.user_id = v_g;
  if v_n2 is null or v_n is null or v_n2 = v_n then
    raise exception 'SETUP: H and G do not hold two seats (H %, G %).', v_n2, v_n;
  end if;
  v_before := pg_temp.m6_count(v_topic, 'members');
  begin
    update public.table_members tm
    set seat = case when tm.user_id = v_h then v_n else v_n2 end
    where tm.table_id = v_t and tm.user_id in (v_h, v_g);
    update public.table_members tm
    set seat = case when tm.user_id = v_h then v_n2 else v_n end
    where tm.table_id = v_t and tm.user_id in (v_h, v_g);
  exception when others then
    raise exception 'SETUP: could not swap H''s and G''s seats: % (%).', sqlerrm, sqlstate;
  end;
  if (select tm.seat from public.table_members tm where tm.table_id = v_t and tm.user_id = v_h) is distinct from v_n2
     or (select tm.seat from public.table_members tm where tm.table_id = v_t and tm.user_id = v_g) is distinct from v_n then
    raise exception 'SETUP: the seats did not come back as they were.';
  end if;
  -- The newest roster_version sent (the highest) is the table's own.
  select jsonb_build_object('roster_version', max((m.payload ->> 'roster_version')::bigint)) into v_last
  from realtime.messages m
  where m.topic = v_topic and m.payload ->> 'event' = 'members';
  if pg_temp.m6_count(v_topic, 'members') - v_before <> 4
     or (v_last ->> 'roster_version')::bigint is distinct from (select t.roster_version from public.tables t where t.id = v_t) then
    raise exception 'FAIL [C1] two seat swaps (four seat changes) sent % members event(s) (want 4); the last %; the table''s roster_version %.',
      pg_temp.m6_count(v_topic, 'members') - v_before, coalesce(v_last::text, '-'), (select t.roster_version from public.tables t where t.id = v_t);
  end if;
  v_checks := v_checks + 1;

  -- ==== C2: a play -> a 'game' event at commit ======================================
  -- The game through the real functions: H starts it, the cut until it is
  -- active, both discards, then one play by the player whose turn it is.
  v_r := pg_temp.m6_as('authenticated', v_h, format('select public.start_game_with_deal(%L)::text', v_t));
  perform pg_temp.m6_fire(v_t, null);
  v_game := v_r[5]::uuid;
  if v_r[1] is not null or v_game is null then
    raise exception 'SETUP: H could not start a game: % (%).', coalesce(v_r[2], '-'), coalesce(v_r[1], '-');
  end if;
  perform pg_temp.m6_fire(v_t, v_game);
  v_round := 0;
  loop
    v_round := v_round + 1;
    if v_round > 12 then
      raise exception 'SETUP: no decisive cut in 12 rounds.';
    end if;
    foreach v_who in array array[v_h, v_g] loop
      v_r := pg_temp.m6_as('authenticated', v_who, format('select public.draw_cut_card(%L)::text', v_game));
      perform pg_temp.m6_fire(v_t, v_game);
    end loop;
    foreach v_who in array array[v_h, v_g] loop
      v_r := pg_temp.m6_as('authenticated', v_who, format('select ''ok'' from public.acknowledge_deal_cut(%L)', v_game));
      perform pg_temp.m6_fire(v_t, v_game);
    end loop;
    exit when (select g.status from public.games g where g.id = v_game) = 'active';
  end loop;
  foreach v_who in array array[v_h, v_g] loop
    select gh.cards[1:2] into v_cards from public.game_hands gh where gh.game_id = v_game and gh.user_id = v_who;
    v_r := pg_temp.m6_as('authenticated', v_who, format('select ''ok'' from public.discard_to_crib(%L, %L::text[])', v_game, v_cards));
    perform pg_temp.m6_fire(v_t, v_game);
    if v_r[1] is not null then
      raise exception 'SETUP: a discard was refused: %.', v_r[2];
    end if;
  end loop;
  select g.current_player, g.play_count into v_cp, v_count from public.games g where g.id = v_game and g.phase = 'play';
  if v_cp is null then
    raise exception 'SETUP: the game did not reach the play (phase %).', (select g.phase from public.games g where g.id = v_game);
  end if;
  select c into v_card
  from unnest((select gh.cards from public.game_hands gh where gh.game_id = v_game and gh.user_id = v_cp)) as c
  where public.card_play_value(c) + coalesce(v_count, 0) <= 31
  order by c
  limit 1;
  v_before := pg_temp.m6_count(v_topic, 'game');
  v_r := pg_temp.m6_as('authenticated', v_cp, format('select ''ok'' from public.play_card(%L, %L)', v_game, v_card));
  perform pg_temp.m6_fire(v_t, v_game);
  select max(gp.seq) into v_seq from public.game_plays gp where gp.game_id = v_game;
  select m.payload into v_last from realtime.messages m
  where m.topic = v_topic and m.payload ->> 'event' = 'game' order by m.inserted_at desc, m.id desc limit 1;
  if v_r[1] is not null or pg_temp.m6_count(v_topic, 'game') - v_before <> 1
     or v_last ->> 'game_id' is distinct from v_game::text or (v_last ->> 'last_play_seq')::int is distinct from v_seq then
    raise exception 'FAIL [C2] the play (%) sent % game event(s) (want 1); the last % (want game %, last_play_seq %).',
      coalesce(v_r[2], 'ok'), pg_temp.m6_count(v_topic, 'game') - v_before, coalesce(v_last::text, '-'), v_game, v_seq;
  end if;
  v_checks := v_checks + 1;

  -- ==== C3: a score -> one 'scores' event at commit ==================================
  v_before := pg_temp.m6_count(v_topic, 'scores');
  perform public.award_points(v_t, v_h, 2, 'his heels');
  perform pg_temp.m6_fire(v_t, v_game);
  select m.payload into v_last from realtime.messages m
  where m.topic = v_topic and m.payload ->> 'event' = 'scores' order by m.inserted_at desc, m.id desc limit 1;
  if pg_temp.m6_count(v_topic, 'scores') - v_before <> 1
     or v_last ->> 'user_id' is distinct from v_h::text or (v_last ->> 'points')::int is distinct from 2 then
    raise exception 'FAIL [C3] an award sent % scores event(s) (want 1); the last % (want H, 2 points).',
      pg_temp.m6_count(v_topic, 'scores') - v_before, coalesce(v_last::text, '-');
  end if;
  v_checks := v_checks + 1;

  -- ==== C4: a chat message -> one 'chat' event =======================================
  v_before := pg_temp.m6_count(v_topic, 'chat');
  v_r := pg_temp.m6_as('authenticated', v_h, format('select public.send_table_message(%L::uuid, %L)::text', v_t, 'still here after the cleanup'));
  select m.payload into v_last from realtime.messages m
  where m.topic = v_topic and m.payload ->> 'event' = 'chat' order by m.inserted_at desc, m.id desc limit 1;
  if v_r[1] is not null or pg_temp.m6_count(v_topic, 'chat') - v_before <> 1 or v_last ->> 'sender_id' is distinct from v_h::text then
    raise exception 'FAIL [C4] send_table_message: % (%); % chat event(s) (want 1); the last %.',
      coalesce(v_r[2], 'ok'), coalesce(v_r[1], '-'), pg_temp.m6_count(v_topic, 'chat') - v_before, coalesce(v_last::text, '-');
  end if;
  v_checks := v_checks + 1;

  -- ==== C5: they still reach the table ===============================================
  v_bad := '';
  for v_rec in
    select * from (values ('members'), ('game'), ('scores'), ('chat')) as t(kind)
  loop
    v_n := pg_temp.m6_count(v_topic, v_rec.kind);
    if v_n < 1 then
      v_bad := v_bad || 'no ' || v_rec.kind || ' event stored; ';
    end if;
    if pg_temp.m6_sees(v_g, v_topic, v_rec.kind) <> v_n then
      v_bad := v_bad || 'G (seated) sees ' || pg_temp.m6_sees(v_g, v_topic, v_rec.kind)::text || ' of ' || v_n::text || ' ' || v_rec.kind || '; ';
    end if;
    if pg_temp.m6_sees(v_s, v_topic, v_rec.kind) <> v_n then
      v_bad := v_bad || 'S (current spectator) sees ' || pg_temp.m6_sees(v_s, v_topic, v_rec.kind)::text || ' of ' || v_n::text || ' ' || v_rec.kind || '; ';
    end if;
    if pg_temp.m6_sees(v_o, v_topic, v_rec.kind) <> 0 then
      v_bad := v_bad || 'O (nobody there) sees ' || v_rec.kind || '; ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [C5] receiving on table:<T>: %', v_bad;
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
