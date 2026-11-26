-- Moderation, slice M5 (b1): VERIFICATION of GAME STATE AND PLAYS EVENTS
-- (docs/sql/moderation-m5b1-part1.sql).
--
-- Run in the Supabase Dashboard -> SQL Editor after part 1. The whole file
-- is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- It WRITES -- temporary functions and a temporary table in pg_temp, a
-- temporary REPLACEMENT of _send_game_event (first a recorder, then one
-- that always raises), temporary accounts in auth.users and their
-- profiles, an admin_users row, four test tables with seats and a
-- spectator, four games played through the REAL game functions (as the
-- players, through the same impersonation as the earlier suites), and
-- (when Realtime can store them) event rows in realtime.messages -- and
-- then deliberately raises an exception at the very end, which rolls EVERY
-- write back (the replaced function included: DDL is transactional). A
-- check that fails raises its own exception at once, which rolls
-- everything back the same way. It always "fails": the message is the
-- verdict.
--   "ALL 19 CHECKS PASSED (rolled back)." is a pass -- or "ALL 17 CHECKS
--   PASSED (rolled back). Skipped N1-N2 ..." when Realtime can't store the
--   events here (no realtime.messages partition for today, or this role
--   cannot read them).
--   Anything starting "FAIL" or "SETUP" is not a pass.
--
-- HOW "AT COMMIT" IS TESTED INSIDE ONE TRANSACTION: the game event triggers
-- are deferred to COMMIT, and this block never commits. So after each
-- player's call, m5b_fire() runs SET CONSTRAINTS ALL IMMEDIATE (which fires
-- every pending deferred trigger now, exactly as a commit would) and then
-- SET CONSTRAINTS ALL DEFERRED again -- one "commit" per call. It then
-- clears the per-game "already sent" flags (m5b1.sent_<game id without
-- dashes>), which a real commit ends with the transaction. A call that
-- fails is rolled back to its savepoint, and its pending triggers with it.
--
-- HOW EVENTS ARE COUNTED: after the catalog checks, _send_game_event is
-- replaced by a RECORDER that writes each (topic, payload) to
-- pg_temp.m5b_sent and then calls realtime.send exactly as the real one
-- does. So every count works even where Realtime can't store messages;
-- N1-N2 then compare with what Realtime stored, when it can.
--
-- PEOPLE AND TABLES (2-player human tables; nobody sits at two tables):
--   T1 H's: H and G play a full hand and the next deal; S watches; O is
--      nobody there.
--   T2 M1's Muggins table (M1, M2): the win claim (C13).
--   T3 KH's (KH, KP): the kick that ends a live game (C13).
--   T4 AH's (AH, AG): the admin's force-end (AD, an admin).
--
-- WHAT IT CHECKS
--   K1  public.games.state_version: bigint not null default 0.
--   K2  the three functions: part 1's bodies, security definer,
--       search_path '', no client role may execute them.
--   K3  the triggers: games_state_version BEFORE INSERT OR UPDATE, ROW;
--       games_zz_game_event (AFTER INSERT OR UPDATE on games) and
--       game_plays_zz_game_event (AFTER INSERT OR DELETE on game_plays),
--       both CONSTRAINT triggers, ROW, DEFERRABLE INITIALLY DEFERRED, all
--       enabled, each calling its function; both named after
--       games_snapshot_result_on_win.
--   K4  the shapes: _send_game_event sends (payload, 'game', 'table:' ||
--       id, true) inside its own exception block; _game_event_at_commit
--       builds exactly {event, game_id, hand_no, state_version,
--       last_play_seq}, sets the per-game flag before sending, and keeps
--       its whole body inside an exception block; no M5b1 body (comments
--       aside) writes any table, takes a lock, reads public.tables or names
--       a hand, crib or deck table.
--   C1  start_game_with_deal (H at T1): exactly one event, for the new
--       game, with its state_version.
--   C2  the cut, round by round (each draw and each acknowledgement:
--       exactly one event each), and the DEAL in the last acknowledgement
--       (hands, crib and deck written with it): still exactly one.
--   C3  each discard: exactly one event.
--   C4  each play (a go included): exactly one event; the event's
--       last_play_seq is the last play's seq, its state_version the row's.
--   C5  show_crib and each count step: exactly one event each.
--   C6  next_hand: H's tap one event; G's tap (the old plays deleted, hand
--       2 dealt) one event, with hand_no 2 and last_play_seq 0.
--   C7  state_version only moves up: T1's events in order carry a rising
--       state_version; the owner writing state_version = 0 gets the stored
--       value + 1 instead.
--   C8  the admin's force-end (AD, as a client, the admin page's UPDATE
--       with state_version = 0 added): the game ends, state_version is the
--       stored value + 1, exactly one event.
--   C9  a second game has its own id and versions; ONE statement changing
--       two games sends exactly two events, one per game.
--   C10 a rolled-back change sends nothing and moves no version.
--   C11 every event recorded has exactly the keys event, game_id,
--       hand_no, state_version, last_play_seq (event 'game', numbers
--       where numbers belong), on table:<the game's table>.
--   C12 no lock or write on the tables row: T1's row (its ctid and
--       roster_version) is the same before the plays and after the next
--       deal.
--   N1  (when Realtime stores them) T1's stored 'game' events match the
--       recorded ones one for one; each private, broadcast, and its keys
--       only the five plus Realtime's own uuid "id".
--   N2  (when Realtime stores them) who RECEIVES them under the live
--       policies: H (seated) and S (current spectator) see every one; O
--       sees none.
--   C13 A FAILING SEND NEVER UNDOES A GAME CHANGE (run last): with
--       _send_game_event replaced by one that always raises (proved to
--       raise), M1's win claim at T2, T1's second hand (both discards,
--       every play, the crib and every count step) and KH's kick of KP
--       (ending T3's live game as player_left) all go through.

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
  v_m1 uuid := gen_random_uuid();
  v_m2 uuid := gen_random_uuid();
  v_kh uuid := gen_random_uuid();
  v_kp uuid := gen_random_uuid();
  v_ah uuid := gen_random_uuid();
  v_ag uuid := gen_random_uuid();
  v_ad uuid := gen_random_uuid();
  v_people uuid[];
  v_pid uuid;
  v_codes text[];
  v_t1 uuid;
  v_t2 uuid;
  v_t3 uuid;
  v_t4 uuid;
  v_g1 uuid;
  v_g2 uuid;
  v_g3 uuid;
  v_g4 uuid;
  v_games uuid[] := '{}';
  v_r text[];
  v_rec record;
  v_txt text;
  v_bad text;
  v_n int;
  v_n2 int;
  v_before int;
  v_sv bigint;
  v_sv2 bigint;
  v_hand int;
  v_ctid text;
  v_rv bigint;
  v_state text;
  v_topic text;
begin
  -- ==== MODE ======================================================================
  if to_regprocedure('public._game_event_at_commit()') is null
     or not exists (select 1 from pg_attribute a where a.attrelid = 'public.games'::regclass and a.attname = 'state_version' and not a.attisdropped) then
    raise exception 'SETUP: part 1 is not in (no _game_event_at_commit or games.state_version). Run docs/sql/moderation-m5b1-part1.sql first.';
  end if;
  if to_regprocedure('public.card_play_value(text)') is null then
    raise exception 'SETUP: public.card_play_value(text) is missing (the hand below picks legal cards with it).';
  end if;

  -- ==== K: CATALOG (before anything is replaced) =====================================
  -- [K1] The column.
  select format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else ' nullable' end
         || ' default ' || coalesce(pg_get_expr(ad.adbin, ad.adrelid), '(none)')
  into v_txt
  from pg_attribute a
  left join pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
  where a.attrelid = 'public.games'::regclass and a.attname = 'state_version' and not a.attisdropped;
  if v_txt is distinct from 'bigint not null default 0' then
    raise exception 'FAIL [K1] public.games.state_version is "%"; expected bigint not null default 0.', coalesce(v_txt, 'missing');
  end if;
  v_checks := v_checks + 1;

  -- [K2] The three functions.
  v_bad := '';
  for v_rec in
    select * from (values
      ('public._bump_game_state_version()', '35314b3677dd7b0b39a2ca32ee29e7c3'),
      ('public._send_game_event(uuid, jsonb)', '462c8068b6c7a183ca76fa18fa6b7264'),
      ('public._game_event_at_commit()', 'cce9d688120f3dc2c155503270fe11ee')
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
    raise exception 'FAIL [K2] the M5b1 functions: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K3] The triggers.
  v_bad := '';
  for v_rec in
    select * from (values
      ('public.games', 'games_state_version', 'public._bump_game_state_version()', true, 4 + 16, false),
      ('public.games', 'games_zz_game_event', 'public._game_event_at_commit()', false, 4 + 16, true),
      ('public.game_plays', 'game_plays_zz_game_event', 'public._game_event_at_commit()', false, 4 + 8, true)
    ) as t(rel, name, fn, before, events, deferred)
  loop
    select count(*) into v_n
    from pg_trigger tg
    where tg.tgrelid = to_regclass(v_rec.rel)
      and tg.tgname::text = v_rec.name
      and not tg.tgisinternal
      and tg.tgenabled = 'O'
      and tg.tgfoid = to_regprocedure(v_rec.fn)
      and (tg.tgtype & 1) = 1
      and ((tg.tgtype & 2) = 2) = v_rec.before
      and (tg.tgtype & 28) = v_rec.events
      and tg.tgdeferrable = v_rec.deferred
      and tg.tginitdeferred = v_rec.deferred
      and (tg.tgconstraint <> 0) = v_rec.deferred;
    if v_n <> 1 then
      v_bad := v_bad || v_rec.name || ' not found as part 1 wrote it; ';
    end if;
  end loop;
  if not ('games_zz_game_event' > 'games_snapshot_result_on_win') then
    v_bad := v_bad || 'games_zz_game_event does not sort after games_snapshot_result_on_win; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K3] %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K4] The shapes (comments removed for the "no write, no lock, no cards" rule).
  v_bad := '';
  select replace(p.prosrc, E'\r', '') into v_txt from pg_proc p where p.oid = to_regprocedure('public._send_game_event(uuid, jsonb)');
  if v_txt !~ E'begin\\n    perform realtime\\.send\\(p_payload, ''game'', ''table:'' \\|\\| p_table_id::text, true\\);\\n  exception when others then\\n    null;\\n  end;' then
    v_bad := v_bad || '_send_game_event does not send (payload, game, table:<id>, true) inside its own exception block; ';
  end if;
  select replace(p.prosrc, E'\r', '') into v_txt from pg_proc p where p.oid = to_regprocedure('public._game_event_at_commit()');
  if strpos(v_txt, '''event'', ''game'',') = 0 or strpos(v_txt, '''game_id'', v_game_id,') = 0
     or strpos(v_txt, '''hand_no'', v_game.hand_no,') = 0 or strpos(v_txt, '''state_version'', v_game.state_version,') = 0
     or strpos(v_txt, '''last_play_seq'', v_last));') = 0
     or (length(v_txt) - length(replace(v_txt, 'jsonb_build_object', ''))) / length('jsonb_build_object') <> 1 then
    v_bad := v_bad || '_game_event_at_commit does not build exactly {event, game_id, hand_no, state_version, last_play_seq}; ';
  end if;
  if strpos(v_txt, 'perform pg_catalog.set_config(v_flag, ''y'', true);') = 0
     or strpos(v_txt, 'perform pg_catalog.set_config(v_flag, ''y'', true);') > strpos(v_txt, 'perform public._send_game_event(')
     or strpos(v_txt, 'v_flag := ''m5b1.sent_'' || replace(v_game_id::text, ''-'', '''');') = 0 then
    v_bad := v_bad || '_game_event_at_commit does not set its per-game flag before sending; ';
  end if;
  if v_txt !~ E'^\\ndeclare[\\s\\S]*\\nbegin\\n[^\\n]*\\n[^\\n]*\\n  begin\\n[\\s\\S]*\\n  exception when others then\\n    null;\\n  end;\\n  return null;\\nend;\\n$' then
    v_bad := v_bad || '_game_event_at_commit''s body is not wholly inside its own exception block; ';
  end if;
  select string_agg(p.proname::text, ', ') into v_txt
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('_bump_game_state_version', '_send_game_event', '_game_event_at_commit')
    and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~* '(\minsert\s+into\M|\mupdate\s+public\.|\mdelete\s+from\M|\mfor\s+(no\s+key\s+)?update\M|\mfor\s+share\M|\mlock\s+table\M|public\.tables\M|game_hands|game_cribs|game_decks|\mcards?\M)';
  if v_txt is not null then
    v_bad := v_bad || 'these bodies write, lock, read public.tables or name cards: ' || v_txt || '; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K4] %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP: helpers, the recorder, people, tables =================================
  create temp table m5b_sent (n serial primary key, topic text, payload jsonb) on commit drop;

  -- m5b_as(role, user, sql): one statement as that client role; returns
  -- {sqlstate, message, detail, hint, first column of the first row}.
  create function pg_temp.m5b_as(p_role text, p_uid uuid, p_sql text)
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

  -- m5b_fire(games): "commit" -- fire every pending deferred trigger now,
  -- defer again, and clear the per-game flags a real commit would end.
  create function pg_temp.m5b_fire(p_games uuid[])
  returns void
  language plpgsql
  as $f$
  declare
    v_one uuid;
  begin
    execute 'set constraints all immediate';
    execute 'set constraints all deferred';
    foreach v_one in array coalesce(p_games, '{}'::uuid[]) loop
      perform set_config('m5b1.sent_' || replace(v_one::text, '-', ''), '', true);
    end loop;
  end;
  $f$;

  -- m5b_step(user, sql, games): one player's call, then its "commit".
  create function pg_temp.m5b_step(p_uid uuid, p_sql text, p_games uuid[])
  returns text[]
  language plpgsql
  as $f$
  declare
    v_res text[];
  begin
    v_res := pg_temp.m5b_as('authenticated', p_uid, p_sql);
    perform pg_temp.m5b_fire(p_games);
    return v_res;
  end;
  $f$;

  -- How many events the recorder holds for a game.
  create function pg_temp.m5b_events(p_game uuid)
  returns int
  language sql
  as $f$
    select count(*)::int from pg_temp.m5b_sent s where s.payload ->> 'game_id' = p_game::text
  $f$;

  -- m5b_one(game, user, sql, games, check): one call that must work; with
  -- check, it must send exactly ONE event, whose state_version is the row's
  -- and only moves up. Returns '' or what went wrong.
  create function pg_temp.m5b_one(p_game uuid, p_uid uuid, p_sql text, p_games uuid[], p_check boolean, p_label text)
  returns text
  language plpgsql
  as $f$
  declare
    v_before int;
    v_after int;
    v_sv_before bigint;
    v_sv_after bigint;
    v_res text[];
    v_last jsonb;
  begin
    v_before := pg_temp.m5b_events(p_game);
    select g.state_version into v_sv_before from public.games g where g.id = p_game;
    v_res := pg_temp.m5b_step(p_uid, p_sql, p_games);
    if v_res[1] is not null then
      return p_label || ' refused: ' || coalesce(v_res[2], v_res[1]) || '; ';
    end if;
    if not p_check then
      return '';
    end if;
    v_after := pg_temp.m5b_events(p_game);
    select g.state_version into v_sv_after from public.games g where g.id = p_game;
    if v_after - v_before <> 1 then
      return p_label || ' sent ' || (v_after - v_before)::text || ' event(s) (want 1); ';
    end if;
    select s.payload into v_last from pg_temp.m5b_sent s where s.payload ->> 'game_id' = p_game::text order by s.n desc limit 1;
    if (v_last ->> 'state_version')::bigint is distinct from v_sv_after
       or v_sv_after <= v_sv_before
       or (v_last ->> 'hand_no')::int is distinct from (select g.hand_no from public.games g where g.id = p_game)
       or (v_last ->> 'last_play_seq')::int is distinct from (select coalesce(max(gp.seq), 0) from public.game_plays gp where gp.game_id = p_game) then
      return p_label || ': the event ' || v_last::text || ' is not the row''s state (state_version ' || v_sv_before::text || ' -> ' || v_sv_after::text || '); ';
    end if;
    return '';
  end;
  $f$;

  -- m5b_cut(game, a, b, games, check): the cut, round by round, until the
  -- game is active (the last acknowledgement deals).
  create function pg_temp.m5b_cut(p_game uuid, p_a uuid, p_b uuid, p_games uuid[], p_check boolean)
  returns text
  language plpgsql
  as $f$
  declare
    v_round int := 0;
    v_bad text := '';
    v_status text;
  begin
    loop
      v_round := v_round + 1;
      if v_round > 12 then
        return v_bad || 'no decisive cut in 12 rounds; ';
      end if;
      v_bad := v_bad || pg_temp.m5b_one(p_game, p_a, format('select public.draw_cut_card(%L)::text', p_game), p_games, p_check, 'cut ' || v_round || ' (a)');
      v_bad := v_bad || pg_temp.m5b_one(p_game, p_b, format('select public.draw_cut_card(%L)::text', p_game), p_games, p_check, 'cut ' || v_round || ' (b)');
      v_bad := v_bad || pg_temp.m5b_one(p_game, p_a, format('select ''ok'' from public.acknowledge_deal_cut(%L)', p_game), p_games, p_check, 'ack ' || v_round || ' (a)');
      v_bad := v_bad || pg_temp.m5b_one(p_game, p_b, format('select ''ok'' from public.acknowledge_deal_cut(%L)', p_game), p_games, p_check, 'ack ' || v_round || ' (b)');
      if v_bad <> '' then
        return v_bad;
      end if;
      select g.status into v_status from public.games g where g.id = p_game;
      exit when v_status = 'active';
    end loop;
    return v_bad;
  end;
  $f$;

  -- m5b_discards(game, a, b, games, check): each discards its first two cards.
  create function pg_temp.m5b_discards(p_game uuid, p_a uuid, p_b uuid, p_games uuid[], p_check boolean)
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
      v_bad := v_bad || pg_temp.m5b_one(p_game, v_who, format('select ''ok'' from public.discard_to_crib(%L, %L::text[])', p_game, v_cards), p_games, p_check, 'discard');
    end loop;
    return v_bad;
  end;
  $f$;

  -- m5b_peg(game, games, check): pegging to the end -- at each turn the
  -- first legal card of the player whose turn it is.
  create function pg_temp.m5b_peg(p_game uuid, p_games uuid[], p_check boolean)
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
      v_bad := v_bad || pg_temp.m5b_one(p_game, v_cp, format('select ''ok'' from public.play_card(%L, %L)', p_game, v_card), p_games, p_check, 'play ' || v_i);
      if v_bad <> '' then
        return v_bad;
      end if;
    end loop;
    return v_bad;
  end;
  $f$;

  -- m5b_count(game, games, check): counting to the end -- the dealer shows
  -- the crib at its step, each count by the player whose count it is.
  create function pg_temp.m5b_count(p_game uuid, p_games uuid[], p_check boolean)
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
        v_bad := v_bad || pg_temp.m5b_one(p_game, v_dealer, format('select ''ok'' from public.show_crib(%L)', p_game), p_games, p_check, 'show_crib');
      end if;
      v_bad := v_bad || pg_temp.m5b_one(p_game, v_cp, format('select ''ok'' from public.confirm_count(%L, %s)', p_game, v_step), p_games, p_check, 'count step ' || v_step);
      if v_bad <> '' then
        return v_bad;
      end if;
    end loop;
    return v_bad;
  end;
  $f$;

  -- THE RECORDER: _send_game_event writes what it is given to
  -- pg_temp.m5b_sent, then sends it exactly as the real one does.
  execute $r$
    create or replace function public._send_game_event(p_table_id uuid, p_payload jsonb)
    returns void
    language plpgsql
    volatile
    security definer
    set search_path = ''
    as $b$
    begin
      insert into pg_temp.m5b_sent (topic, payload) values ('table:' || p_table_id::text, p_payload);
      begin
        perform realtime.send(p_payload, 'game', 'table:' || p_table_id::text, true);
      exception when others then
        null;
      end;
    end;
    $b$
  $r$;

  v_people := array[v_h, v_g, v_s, v_o, v_m1, v_m2, v_kh, v_kp, v_ah, v_ag, v_ad];
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'm5b1-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      insert into public.profiles (id, nickname)
      values (v_pid, 'm5b' || left(replace(v_pid::text, '-', ''), 12))
      on conflict (id) do update set nickname = excluded.nickname;
    end loop;
    insert into public.admin_users (user_id) values (v_ad);
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
    insert into public.tables (code, created_by, is_public, max_players, is_muggins)
    values (v_codes[2], v_m1, true, 2, true) returning id into v_t2;
    insert into public.table_members (table_id, user_id) values (v_t2, v_m1);
    insert into public.table_members (table_id, user_id) values (v_t2, v_m2);
    insert into public.tables (code, created_by, is_public, max_players)
    values (v_codes[3], v_kh, true, 2) returning id into v_t3;
    insert into public.table_members (table_id, user_id) values (v_t3, v_kh);
    insert into public.table_members (table_id, user_id) values (v_t3, v_kp);
    insert into public.tables (code, created_by, is_public, max_players)
    values (v_codes[4], v_ah, true, 2) returning id into v_t4;
    insert into public.table_members (table_id, user_id) values (v_t4, v_ah);
    insert into public.table_members (table_id, user_id) values (v_t4, v_ag);
  exception when others then
    raise exception 'SETUP: could not create the test tables: % (%).', sqlerrm, sqlstate;
  end;
  v_topic := 'table:' || v_t1::text;
  perform pg_temp.m5b_fire(v_games);

  -- ==== C: ONE EVENT PER TRANSACTION, THROUGH THE REAL GAME FUNCTIONS ================
  -- [C1] H starts T1's game.
  v_r := pg_temp.m5b_step(v_h, format('select public.start_game_with_deal(%L)::text', v_t1), v_games);
  v_g1 := v_r[5]::uuid;
  if v_g1 is not null then
    v_games := v_games || v_g1;
    perform pg_temp.m5b_fire(v_games);
  end if;
  select g.state_version into v_sv from public.games g where g.id = v_g1;
  if v_r[1] is not null or v_g1 is null
     or pg_temp.m5b_events(v_g1) <> 1
     or (select (s.payload ->> 'state_version')::bigint from pg_temp.m5b_sent s where s.payload ->> 'game_id' = v_g1::text) is distinct from v_sv
     or (select s.topic from pg_temp.m5b_sent s where s.payload ->> 'game_id' = v_g1::text) is distinct from v_topic then
    raise exception 'FAIL [C1] H starting T1''s game: % (error %); % event(s) for it (want 1, on %, with state_version %).',
      coalesce(v_r[5], '-'), coalesce(v_r[2], 'none'), coalesce(pg_temp.m5b_events(v_g1), 0), v_topic, v_sv;
  end if;
  v_checks := v_checks + 1;

  -- [C2] The cut and the deal.
  v_bad := pg_temp.m5b_cut(v_g1, v_h, v_g, v_games, true);
  if v_bad <> '' or (select count(*) from public.game_hands gh where gh.game_id = v_g1) <> 2 then
    raise exception 'FAIL [C2] the cut and the deal at T1: %(hands dealt: %).', v_bad, (select count(*) from public.game_hands gh where gh.game_id = v_g1);
  end if;
  v_checks := v_checks + 1;

  -- [C3] The discards.
  v_bad := pg_temp.m5b_discards(v_g1, v_h, v_g, v_games, true);
  if v_bad <> '' or (select g.phase from public.games g where g.id = v_g1) is distinct from 'play' then
    raise exception 'FAIL [C3] the discards at T1: %(phase %).', v_bad, (select g.phase from public.games g where g.id = v_g1);
  end if;
  v_checks := v_checks + 1;

  -- T1's tables row before the plays (C12).
  select t.ctid::text, t.roster_version into v_ctid, v_rv from public.tables t where t.id = v_t1;

  -- [C4] Every play.
  v_bad := pg_temp.m5b_peg(v_g1, v_games, true);
  if v_bad <> '' or (select g.phase from public.games g where g.id = v_g1) is distinct from 'counting'
     or (select count(*) from public.game_plays gp where gp.game_id = v_g1 and gp.kind = 'play') <> 8 then
    raise exception 'FAIL [C4] pegging at T1: %(phase %, % plays).', v_bad,
      (select g.phase from public.games g where g.id = v_g1), (select count(*) from public.game_plays gp where gp.game_id = v_g1 and gp.kind = 'play');
  end if;
  v_checks := v_checks + 1;

  -- [C5] The crib and every count step.
  v_bad := pg_temp.m5b_count(v_g1, v_games, true);
  if v_bad <> '' or (select g.phase from public.games g where g.id = v_g1) is distinct from 'done' then
    raise exception 'FAIL [C5] counting at T1: %(phase %).', v_bad, (select g.phase from public.games g where g.id = v_g1);
  end if;
  v_checks := v_checks + 1;

  -- [C6] Next hand: two taps; the second deals hand 2 (the old plays deleted).
  select g.hand_no into v_hand from public.games g where g.id = v_g1;
  v_bad := pg_temp.m5b_one(v_g1, v_h, format('select ''ok'' from public.next_hand(%L, %s)', v_g1, v_hand), v_games, true, 'H''s Next Hand');
  v_bad := v_bad || pg_temp.m5b_one(v_g1, v_g, format('select ''ok'' from public.next_hand(%L, %s)', v_g1, v_hand), v_games, true, 'G''s Next Hand');
  select s.payload into v_txt from pg_temp.m5b_sent s where s.payload ->> 'game_id' = v_g1::text order by s.n desc limit 1;
  if v_bad <> '' or (v_txt::jsonb ->> 'hand_no')::int is distinct from v_hand + 1 or (v_txt::jsonb ->> 'last_play_seq')::int is distinct from 0
     or exists (select 1 from public.game_plays gp where gp.game_id = v_g1) then
    raise exception 'FAIL [C6] Next Hand at T1: %last event %; expected hand_no % and last_play_seq 0, no plays left.', v_bad, coalesce(v_txt, '-'), v_hand + 1;
  end if;
  v_checks := v_checks + 1;

  -- [C12] (checked here, after the plays and the deal) The tables row untouched.
  if (select t.ctid::text from public.tables t where t.id = v_t1) is distinct from v_ctid
     or (select t.roster_version from public.tables t where t.id = v_t1) is distinct from v_rv then
    raise exception 'FAIL [C12] T1''s tables row changed during the plays and the deal (ctid % -> %, roster_version % -> %): the game events must not write it.',
      v_ctid, (select t.ctid::text from public.tables t where t.id = v_t1), v_rv, (select t.roster_version from public.tables t where t.id = v_t1);
  end if;
  v_checks := v_checks + 1;

  -- [C7] state_version only moves up.
  select count(*) into v_n
  from (select (s.payload ->> 'state_version')::bigint as sv,
               lag((s.payload ->> 'state_version')::bigint) over (order by s.n) as prev
        from pg_temp.m5b_sent s where s.payload ->> 'game_id' = v_g1::text) x
  where x.prev is not null and x.sv <= x.prev;
  select g.state_version into v_sv from public.games g where g.id = v_g1;
  update public.games g set state_version = 0 where g.id = v_g1;
  select g.state_version into v_sv2 from public.games g where g.id = v_g1;
  perform pg_temp.m5b_fire(v_games);
  if v_n <> 0 or v_sv2 <> v_sv + 1 then
    raise exception 'FAIL [C7] % event(s) at T1 did not raise state_version; the owner writing 0 left % (want %).', v_n, v_sv2, v_sv + 1;
  end if;
  v_checks := v_checks + 1;

  -- [C8] The admin's force-end, as a client, with state_version = 0 added.
  v_r := pg_temp.m5b_step(v_ah, format('select public.start_game_with_deal(%L)::text', v_t4), v_games);
  v_g4 := v_r[5]::uuid;
  if v_g4 is null then
    raise exception 'SETUP: AH could not start T4''s game: %.', coalesce(v_r[2], '-');
  end if;
  v_games := v_games || v_g4;
  perform pg_temp.m5b_fire(v_games);
  select g.state_version into v_sv from public.games g where g.id = v_g4;
  v_before := pg_temp.m5b_events(v_g4);
  v_r := pg_temp.m5b_step(v_ad, format('update public.games set status = ''ended'', ended_reason = ''admin'', state_version = 0 where id = %L and status in (''cutting'', ''active'') returning state_version::text', v_g4), v_games);
  if v_r[1] is not null or v_r[5] is distinct from (v_sv + 1)::text
     or (select g.status || '/' || coalesce(g.ended_reason, '-') from public.games g where g.id = v_g4) is distinct from 'ended/admin'
     or pg_temp.m5b_events(v_g4) - v_before <> 1 then
    raise exception 'FAIL [C8] AD''s force-end of T4''s game: % (error %), now %, % event(s); expected state_version %, ended/admin, 1 event.',
      coalesce(v_r[5], '-'), coalesce(v_r[2], 'none'),
      (select g.status || '/' || coalesce(g.ended_reason, '-') from public.games g where g.id = v_g4), pg_temp.m5b_events(v_g4) - v_before, v_sv + 1;
  end if;
  v_checks := v_checks + 1;

  -- [C9] A second game: its own id and versions; one statement, two games, two events.
  select count(*) into v_n from pg_temp.m5b_sent s
  where s.payload ->> 'game_id' = v_g4::text and s.topic is distinct from 'table:' || v_t4::text;
  v_before := (select count(*) from pg_temp.m5b_sent);
  update public.games g set ready_by = g.ready_by where g.id in (v_g1, v_g4);
  perform pg_temp.m5b_fire(v_games);
  select count(*), count(distinct s.payload ->> 'game_id') into v_n2, v_sv
  from pg_temp.m5b_sent s where s.n > v_before;
  if v_n <> 0 or v_n2 <> 2 or v_sv <> 2
     or (select max((s.payload ->> 'state_version')::bigint) from pg_temp.m5b_sent s where s.payload ->> 'game_id' = v_g4::text)
        >= (select max((s.payload ->> 'state_version')::bigint) from pg_temp.m5b_sent s where s.payload ->> 'game_id' = v_g1::text) then
    raise exception 'FAIL [C9] T4''s events on another topic %; one statement over two games sent % event(s) for % game(s) (want 2 for 2); T4''s versions must be its own (lower than T1''s long run).', v_n, v_n2, v_sv;
  end if;
  v_checks := v_checks + 1;

  -- [C10] A rolled-back change sends nothing and moves no version.
  v_before := (select count(*) from pg_temp.m5b_sent);
  select g.state_version into v_sv from public.games g where g.id = v_g1;
  begin
    update public.games g set ready_by = g.ready_by where g.id = v_g1;
    raise exception 'm5b1 verification: roll this back';
  exception when others then
    null;
  end;
  perform pg_temp.m5b_fire(v_games);
  if (select count(*) from pg_temp.m5b_sent) <> v_before
     or (select g.state_version from public.games g where g.id = v_g1) <> v_sv then
    raise exception 'FAIL [C10] a rolled-back update sent % event(s) and moved state_version % -> %; want none.',
      (select count(*) from pg_temp.m5b_sent) - v_before, v_sv, (select g.state_version from public.games g where g.id = v_g1);
  end if;
  v_checks := v_checks + 1;

  -- [C11] Every recorded event: exactly the five keys, the right types and topic.
  select count(*) into v_n
  from pg_temp.m5b_sent s
  where (select string_agg(k, ',' order by k) from jsonb_object_keys(s.payload) as k) is distinct from 'event,game_id,hand_no,last_play_seq,state_version'
     or s.payload ->> 'event' is distinct from 'game'
     or jsonb_typeof(s.payload -> 'state_version') is distinct from 'number'
     or jsonb_typeof(s.payload -> 'last_play_seq') is distinct from 'number'
     or jsonb_typeof(s.payload -> 'hand_no') not in ('number', 'null')
     or s.topic is distinct from (select 'table:' || g.table_id::text from public.games g where g.id = (s.payload ->> 'game_id')::uuid);
  if v_n <> 0 or (select count(*) from pg_temp.m5b_sent) = 0 then
    raise exception 'FAIL [C11] % recorded event(s) with other keys, types or topic (of %); sample %.', v_n, (select count(*) from pg_temp.m5b_sent),
      (select s.topic || ' ' || s.payload::text from pg_temp.m5b_sent s order by s.n limit 1);
  end if;
  v_checks := v_checks + 1;

  -- [N1] The stored copies, when Realtime can store them.
  begin
    select count(*) into v_n from realtime.messages m where m.topic = v_topic and m.event = 'game';
  exception when others then
    v_n := -1;
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  if v_n = -1 then
    v_skips := ' Skipped N1-N2: this role cannot read realtime.messages (' || v_txt || ').';
  elsif v_n = 0 then
    v_skips := ' Skipped N1-N2: no game event was stored (usually no realtime.messages partition for today; every change above still went through).';
  elsif not has_table_privilege('authenticated', 'realtime.messages', 'SELECT') then
    v_skips := ' Skipped N1-N2: authenticated lacks SELECT on realtime.messages.';
  else
    v_live := true;
    select count(*) into v_n2 from pg_temp.m5b_sent s where s.topic = v_topic;
    select count(*) into v_before
    from realtime.messages m
    where m.topic = v_topic and m.event = 'game'
      and (m.private is distinct from true or m.extension is distinct from 'broadcast'
           or not (m.payload ?& array['event', 'game_id', 'hand_no', 'state_version', 'last_play_seq'])
           or exists (select 1 from jsonb_object_keys(m.payload) as pk(key)
                      where pk.key not in ('event', 'game_id', 'hand_no', 'state_version', 'last_play_seq', 'id'))
           or (m.payload ? 'id' and coalesce(m.payload ->> 'id', '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'));
    if v_n <> v_n2 or v_before <> 0 then
      raise exception 'FAIL [N1] % stored game event(s) on T1''s topic, % recorded; % stored row(s) not private, not broadcast, or with other keys.', v_n, v_n2, v_before;
    end if;
    v_checks := v_checks + 1;
  end if;

  -- [N2] Who receives them.
  if v_live then
    select count(*) into v_n from realtime.messages m where m.topic = v_topic and m.event = 'game';
    v_bad := '';
    for v_rec in
      select * from (values ('H (seated)', v_h, v_n), ('S (current spectator)', v_s, v_n), ('O (nobody there)', v_o, 0)) as t(label, who, want)
    loop
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.who, 'role', 'authenticated')::text, true);
      perform set_config('realtime.topic', v_topic, true);
      execute 'set local role authenticated';
      select count(*) into v_n2 from realtime.messages m where m.topic = v_topic and m.event = 'game';
      execute 'reset role';
      if v_n2 <> v_rec.want then
        v_bad := v_bad || v_rec.label || ' saw ' || v_n2::text || ' (want ' || v_rec.want::text || '); ';
      end if;
    end loop;
    if v_bad <> '' then
      raise exception 'FAIL [N2] receiving T1''s game events: %', v_bad;
    end if;
    v_checks := v_checks + 1;
  end if;

  -- [C13] A failing send never undoes a game change (run last).
  execute $r$
    create or replace function public._send_game_event(p_table_id uuid, p_payload jsonb)
    returns void
    language plpgsql
    volatile
    security definer
    set search_path = ''
    as $b$
    begin
      raise exception 'm5b1 verification: the send fails on purpose';
    end;
    $b$
  $r$;
  v_state := null;
  begin
    perform public._send_game_event(v_t1, '{}'::jsonb);
  exception when others then
    v_state := sqlstate;
  end;
  v_bad := '';
  -- M1's win claim at T2 (its game started and cut first).
  v_r := pg_temp.m5b_step(v_m1, format('select public.start_game_with_deal(%L)::text', v_t2), v_games);
  v_g2 := v_r[5]::uuid;
  if v_g2 is null then
    v_bad := v_bad || 'M1 starting T2''s game: ' || coalesce(v_r[2], '-') || '; ';
  else
    v_games := v_games || v_g2;
    perform pg_temp.m5b_fire(v_games);
    v_bad := v_bad || pg_temp.m5b_cut(v_g2, v_m1, v_m2, v_games, false);
    v_bad := v_bad || pg_temp.m5b_one(v_g2, v_m1, format('select ''ok'' from public.claim_win(%L)', v_g2), v_games, false, 'M1''s win claim');
    if (select g.win_claim_by from public.games g where g.id = v_g2) is distinct from v_m1 then
      v_bad := v_bad || 'the win claim did not stand; ';
    end if;
  end if;
  -- T1's second hand: discards, every play, the crib and every count step.
  v_bad := v_bad || pg_temp.m5b_discards(v_g1, v_h, v_g, v_games, false);
  v_bad := v_bad || pg_temp.m5b_peg(v_g1, v_games, false);
  v_bad := v_bad || pg_temp.m5b_count(v_g1, v_games, false);
  if (select g.phase from public.games g where g.id = v_g1) is distinct from 'done' then
    v_bad := v_bad || 'T1''s second hand did not finish counting (phase ' || coalesce((select g.phase from public.games g where g.id = v_g1), '-') || '); ';
  end if;
  -- KH kicks KP while T3's game is live.
  v_r := pg_temp.m5b_step(v_kh, format('select public.start_game_with_deal(%L)::text', v_t3), v_games);
  v_g3 := v_r[5]::uuid;
  if v_g3 is null then
    v_bad := v_bad || 'KH starting T3''s game: ' || coalesce(v_r[2], '-') || '; ';
  else
    v_games := v_games || v_g3;
    perform pg_temp.m5b_fire(v_games);
    v_r := pg_temp.m5b_step(v_kh, format('select public.kick_player(%L, %L)', v_t3, v_kp), v_games);
    if v_r[5] is distinct from 'kicked'
       or (select g.status || '/' || coalesce(g.ended_reason, '-') from public.games g where g.id = v_g3) is distinct from 'ended/player_left' then
      v_bad := v_bad || 'KH kicking KP: ' || coalesce(v_r[5], coalesce(v_r[2], '-')) || ', T3''s game '
               || coalesce((select g.status || '/' || coalesce(g.ended_reason, '-') from public.games g where g.id = v_g3), '-') || '; ';
    end if;
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
