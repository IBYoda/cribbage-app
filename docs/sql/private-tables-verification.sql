-- Step 3, slice D: VERIFICATION of docs/sql/private-tables-part1.sql and
-- docs/sql/private-tables-part2.sql (the private-table read rules).
--
-- Run in the Supabase Dashboard -> SQL Editor after private-tables-part2.sql.
-- The whole file is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- It WRITES -- eleven temporary accounts in auth.users and their profiles, an
-- admin_users row, two test tables, seats, games, plays, hands, cribs, a deck,
-- spectator rows, and it calls join_table_by_code and watch_table -- and then
-- deliberately raises an exception at the very end, which rolls EVERY write
-- back. A check that fails raises its own exception at once, which rolls
-- everything back the same way. It always "fails": the message is the
-- verdict (the dashboard hides notices).
--   "ALL 21 CHECKS PASSED (rolled back)." is a pass.
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives.
-- Same impersonation as the other suites: request.jwt.claims plus "set
-- local role authenticated" (or anon), and "reset role" to act as the owner.
-- now() is frozen inside a DO block: a CURRENT spectator is seen at now(), a
-- LAPSED one five minutes before it.
-- SQL cannot test Realtime itself: these checks prove the row policies that
-- postgres_changes applies to each INSERT / UPDATE event per subscriber.
--
-- PEOPLE (temporary accounts):
--   A  host of the PRIVATE table TP, seated; plays G1 (won) and G2 (live).
--   M  seated at TP; plays G2 only.
--   F  a FORMER player: played G1 at TP, then left (seat deleted).
--   S  a STRANGER: never at TP.
--   C  a CURRENT spectator of TP (last_seen_at now).
--   L  a LAPSED spectator of TP (last_seen_at five minutes ago).
--   R  a REMOVED spectator of TP (removed_at set, seen now).
--   D  an ADMIN (an admin_users row, made here).
--   P  seated at the PUBLIC table TU (one ended game GU with one play).
--   J  joins TP by its code (join_table_by_code), at the end.
--   W  watches TP by its code (watch_table), at the end.
--   and the anon role.
-- TP: private, allows spectators, 4 seats; A and M seated. G1: ended 'won'
-- (players A, F; two plays, both hands, the crib). G2: active (players A, M;
-- one play, both hands, a crib, a deck).
--
-- WHAT IT CHECKS
--   C1  catalog: on tables, table_members, games, game_plays exactly ONE
--       SELECT policy each -- part 2's, to authenticated only; the four old
--       open policies are gone.
--   C2  the seven helpers: security definer, stable, empty search_path,
--       EXECUTE for authenticated, not anon, no PUBLIC grant.
--   C3  leave_table, end_timed_out_sessions, assign_table_seat, table_host:
--       body md5 unchanged (LF or CRLF).
--   C4  kept: the two admin UPDATE policies, game_hands (3), game_cribs (3),
--       table_spectators (1) by name; game_decks has no policy.
--   C5  no new policy reads a table itself (no FROM in its USING: helpers
--       only -- no 42P17 recursion).
--   C6  RLS enabled and not forced on the six tables the helpers read.
--   P1-P8  each person reads, of TP: the table row, the roster, its games,
--       their plays, G1, G2, G1's plays, G2's plays, G1's hands, G2's hands,
--       G1's crib, G2's crib, the decks, TP's spectator rows -- with NO error
--       (no 42P17, no permission error) -- and gets exactly:
--         S stranger         nothing (0 everywhere)
--         A member           all four tables; hands/cribs as before slice D
--         M member           all four tables; only its own G2 hand
--         C current spect.   all four tables; no hand, no crib
--         L lapsed spect.    nothing of TP (only its own spectator row)
--         R removed spect.   nothing of TP (only its own spectator row)
--         F former player    TP's row and roster, G1 and its plays, G1's
--                            hands and crib (a won game) -- never G2
--         D admin            all four tables (hands, cribs, decks and
--                            spectator rows as before: none)
--   P9  the stranger still reads the PUBLIC table TU: its row, roster, game
--       and play.
--   N1  anon reads 0 rows of TP and TU in all four tables, with NO error.
--   U1  the admin's UPDATE (Force-End's path) reaches TP's tables row and
--       G2's games row (an UPDATE needs the row through SELECT).
--   J1  the stranger's join_table_by_code PREVIEW of TP by code: outcome
--       preview, TP, the host's nickname (the confirm screen still shows the
--       host), 2 seated, a live game; and afterwards S still reads nothing.
--   J2  J joins TP by code (join_table_by_code): joined; J then reads TP
--       (row, roster of 3, both games).
--   J3  W watches TP by code (watch_table): TP; W, now a current spectator,
--       reads TP (row, roster, both games).
--   B1  the lobby, as the stranger: the open public tables include TU; no
--       open PRIVATE table, roster or game is visible.
--
-- Expected message:
--   ALL 21 CHECKS PASSED (rolled back).

do $$
declare
  v_checks int := 0;
  v_a uuid := gen_random_uuid();
  v_m uuid := gen_random_uuid();
  v_f uuid := gen_random_uuid();
  v_s uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid();
  v_l uuid := gen_random_uuid();
  v_r uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid();
  v_p uuid := gen_random_uuid();
  v_j uuid := gen_random_uuid();
  v_w uuid := gen_random_uuid();
  v_people uuid[];
  v_pid uuid;
  v_codes text[];
  v_tp uuid;
  v_tu uuid;
  v_g1 uuid;
  v_g2 uuid;
  v_gu uuid;
  v_tid uuid;
  v_rec record;
  v_got text;
  v_txt text;
  v_txt2 text;
  v_msg text;
  v_state text;
  v_n int;
  v_n2 int;
  v_ok boolean;
  v_out text;
  v_host text;
  v_seated int;
  v_live boolean;
begin
  -- ==== CATALOG ===================================================================
  if not exists (select 1 from pg_policies p
                 where p.schemaname = 'public' and p.tablename = 'games' and p.policyname = 'Games the caller may read') then
    raise exception 'SETUP: private-tables-part2.sql has not run (the policy "Games the caller may read" is missing).';
  end if;

  -- [C1] Exactly one SELECT policy on each of the four tables: part 2's, to
  --      authenticated; the old open ones gone.
  for v_rec in
    select * from (values
      ('tables', 'Public tables, or private ones the caller may read', 'Tables are viewable by any logged-in user'),
      ('table_members', 'Rosters of tables the caller may read', 'Table members are viewable by any logged-in user'),
      ('games', 'Games the caller may read', 'Games are viewable by any logged-in user'),
      ('game_plays', 'Plays of games the caller may read', 'Played cards are viewable by any logged-in user')
    ) as t(tbl, new_name, old_name)
  loop
    select count(*) into v_n
    from pg_policies p
    where p.schemaname = 'public' and p.tablename = v_rec.tbl and p.cmd in ('SELECT', 'ALL');
    select count(*) into v_n2
    from pg_policies p
    where p.schemaname = 'public' and p.tablename = v_rec.tbl and p.policyname = v_rec.new_name
      and p.cmd = 'SELECT' and p.permissive = 'PERMISSIVE' and p.roles = array['authenticated']::name[];
    if v_n <> 1 or v_n2 <> 1
       or exists (select 1 from pg_policies p
                  where p.schemaname = 'public' and p.tablename = v_rec.tbl and p.policyname = v_rec.old_name) then
      raise exception 'FAIL [C1] public.%: % SELECT/ALL policies, % matching "%" (to authenticated); expected exactly that one, and no "%".', v_rec.tbl, v_n, v_n2, v_rec.new_name, v_rec.old_name;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- [C2] The seven helpers.
  for v_rec in
    select * from (values
      ('public.is_table_member(uuid)'), ('public.is_current_spectator(uuid)'), ('public.is_admin()'),
      ('public.is_game_player(uuid)'), ('public.is_public_table(uuid)'), ('public.can_read_table(uuid)'),
      ('public.can_read_game(uuid)')
    ) as t(fn)
  loop
    select p.prosecdef
           and p.provolatile = 's'
           and coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']
           and has_function_privilege('authenticated', p.oid, 'EXECUTE')
           and not has_function_privilege('anon', p.oid, 'EXECUTE')
           and not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0)
    into v_ok
    from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_ok is not true then
      raise exception 'FAIL [C2] % is missing or not security definer / stable / search_path '''' / EXECUTE for authenticated only.', v_rec.fn;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- [C3] The four fingerprinted bodies, unchanged.
  for v_rec in
    select * from (values
      ('public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa'),
      ('public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c'),
      ('public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb'),
      ('public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d')
    ) as t(fn, lf, crlf)
  loop
    select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is null or v_txt not in (v_rec.lf, v_rec.crlf) then
      raise exception 'FAIL [C3] % has body md5 %; expected % (LF) or % (CRLF). Slice D must not change it.', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf, v_rec.crlf;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- [C4] The policies slice D keeps, by name; no policy on game_decks.
  select string_agg(x.tbl || ' "' || x.name || '"', '; ') into v_txt
  from (values
    ('tables', 'Admins can force-end tables', 'UPDATE'),
    ('games', 'Admins can force-end games', 'UPDATE'),
    ('game_hands', 'Players read their own hand, or a hand shown at their table', 'SELECT'),
    ('game_hands', 'Players read every hand once pegging is over', 'SELECT'),
    ('game_hands', 'Players of a won game read its hands', 'SELECT'),
    ('game_cribs', 'Players at the table read a shown crib', 'SELECT'),
    ('game_cribs', 'Players read the crib once it is up for counting', 'SELECT'),
    ('game_cribs', 'Players of a won game read its crib', 'SELECT'),
    ('table_spectators', 'Table members and the spectator read spectator rows', 'SELECT')
  ) as x(tbl, name, cmd)
  where not exists (select 1 from pg_policies p
                    where p.schemaname = 'public' and p.tablename = x.tbl and p.policyname = x.name and p.cmd = x.cmd);
  select count(*) into v_n from pg_policies p where p.schemaname = 'public' and p.tablename = 'game_decks';
  if v_txt is not null or v_n <> 0 then
    raise exception 'FAIL [C4] missing kept policies: %; game_decks policies: % (expected 0).', coalesce(v_txt, 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [C5] No new policy reads a table itself (helpers only).
  select string_agg(p.tablename::text || ' "' || p.policyname::text || '"', '; ') into v_txt
  from pg_policies p
  where p.schemaname = 'public'
    and p.tablename in ('tables', 'table_members', 'games', 'game_plays')
    and p.cmd = 'SELECT'
    and (p.qual ~* '\mfrom\M' or p.qual ~* '\mjoin\M');
  if v_txt is not null then
    raise exception 'FAIL [C5] these SELECT policies query a table directly (42P17 risk): %.', v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [C6] RLS enabled, not forced, where the helpers read as the owner.
  select string_agg(x.tbl, ', ') into v_txt
  from (values ('tables'), ('table_members'), ('games'), ('game_plays'), ('table_spectators'), ('admin_users')) as x(tbl)
  join pg_class c on c.oid = to_regclass('public.' || x.tbl)
  where not c.relrowsecurity or c.relforcerowsecurity;
  if v_txt is not null then
    raise exception 'FAIL [C6] RLS off or FORCED on: %.', v_txt;
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner =========================================================
  v_people := array[v_a, v_m, v_f, v_s, v_c, v_l, v_r, v_d, v_p, v_j, v_w];
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'pt-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      insert into public.profiles (id, nickname)
      values (v_pid, 'pt' || left(replace(v_pid::text, '-', ''), 12))
      on conflict (id) do update set nickname = excluded.nickname;
    end loop;
    insert into public.admin_users (user_id) values (v_d);
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts, profiles and admin row: % (%).', sqlerrm, sqlstate;
  end;

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    -- Codes no OPEN table holds -- every table while the old unique key
    -- exists (before step 3 slice B part 2 frees ended tables' codes).
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                        and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null))
    order by n
    limit 2
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 2 then
    raise exception 'SETUP: fewer than two free table codes.';
  end if;

  begin
    -- TP: private, spectators allowed, 4 seats. A and M seated; F seated,
    -- then leaves (A and M stay, so the table stays open).
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players, team_mode)
    values (v_codes[1], v_a, false, true, 4, 'solo') returning id into v_tp;
    insert into public.table_members (table_id, user_id) values (v_tp, v_a);
    insert into public.table_members (table_id, user_id) values (v_tp, v_m);
    insert into public.table_members (table_id, user_id) values (v_tp, v_f);

    -- G1: A beat F (ended, won), an hour ago; two plays, both hands, the crib.
    insert into public.games (table_id, created_by, status, ended_reason, players, winner_id, created_at)
    values (v_tp, v_a, 'ended', 'won', array[v_a, v_f], v_a, now() - interval '1 hour') returning id into v_g1;
    insert into public.game_plays (game_id, seq, segment, user_id, kind, card, count_after)
    values (v_g1, 1, 0, v_a, 'play', 'AS', 1), (v_g1, 2, 0, v_f, 'play', '2H', 3);
    insert into public.game_hands (game_id, user_id, cards)
    values (v_g1, v_a, array['3C', '4C', '5C', '6C']), (v_g1, v_f, array['7D', '8D', '9D', 'TD']);
    insert into public.game_cribs (game_id, cards) values (v_g1, array['JH', 'QH', 'KH', 'AH']);

    -- G2: A and M, live (active, the discard phase); one play, both hands,
    -- a crib and a deck.
    insert into public.games (table_id, created_by, status, players)
    values (v_tp, v_a, 'active', array[v_a, v_m]) returning id into v_g2;
    insert into public.game_plays (game_id, seq, segment, user_id, kind, card, count_after)
    values (v_g2, 1, 0, v_a, 'play', '3S', 3);
    insert into public.game_hands (game_id, user_id, cards)
    values (v_g2, v_a, array['2S', '4S', '5S', '6S']), (v_g2, v_m, array['7S', '8S', '9S', 'TS']);
    insert into public.game_cribs (game_id, cards) values (v_g2, array['2D', '3D', '4D', '5D']);
    insert into public.game_decks (game_id, cards) values (v_g2, array['6D', 'AD']);

    -- F leaves TP (A and M are still seated: the table stays open).
    delete from public.table_members where table_id = v_tp and user_id = v_f;

    -- TP's spectators: C current, L lapsed, R removed.
    insert into public.table_spectators (table_id, user_id, last_seen_at, removed_at)
    values (v_tp, v_c, now(), null),
           (v_tp, v_l, now() - interval '5 minutes', null),
           (v_tp, v_r, now(), now());

    -- TU: public; P seated; one ended game GU with one play.
    insert into public.tables (code, created_by, is_public) values (v_codes[2], v_p, true) returning id into v_tu;
    insert into public.table_members (table_id, user_id) values (v_tu, v_p);
    insert into public.games (table_id, created_by, status, ended_reason, players, winner_id, created_at)
    values (v_tu, v_p, 'ended', 'won', array[v_p, v_m], v_p, now() - interval '2 hours') returning id into v_gu;
    insert into public.game_plays (game_id, seq, segment, user_id, kind, card, count_after)
    values (v_gu, 1, 0, v_p, 'play', 'KS', 10);
  exception when others then
    raise exception 'SETUP: could not create the test tables, games and spectators: % (%).', sqlerrm, sqlstate;
  end;

  if (select t.status from public.tables t where t.id = v_tp) is distinct from 'open' then
    raise exception 'SETUP: TP is not open after F left (status %).', (select t.status from public.tables t where t.id = v_tp);
  end if;

  -- ==== P1-P8: what each person reads of TP ===================================
  -- tbl,roster,games,plays,G1,G2,G1plays,G2plays,G1hands,G2hands,G1crib,G2crib,decks,spectators
  for v_rec in
    select * from (values
      (1, 'S stranger',          v_s, '0,0,0,0,0,0,0,0,0,0,0,0,0,0'),
      (2, 'A member',            v_a, '1,2,2,3,1,1,2,1,2,1,1,0,0,3'),
      (3, 'M member',            v_m, '1,2,2,3,1,1,2,1,0,1,0,0,0,3'),
      (4, 'C current spectator', v_c, '1,2,2,3,1,1,2,1,0,0,0,0,0,1'),
      (5, 'L lapsed spectator',  v_l, '0,0,0,0,0,0,0,0,0,0,0,0,0,1'),
      (6, 'R removed spectator', v_r, '0,0,0,0,0,0,0,0,0,0,0,0,0,1'),
      (7, 'F former player',     v_f, '1,2,1,2,1,0,2,0,2,0,1,0,0,0'),
      (8, 'D admin',             v_d, '1,2,2,3,1,1,2,1,0,0,0,0,0,0')
    ) as t(o, who, uid, expect)
    order by 1
  loop
    v_got := null;
    v_state := null;
    v_msg := null;
    perform set_config('request.jwt.claims', json_build_object('sub', v_rec.uid, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      select concat_ws(',',
               (select count(*) from public.tables t where t.id = v_tp),
               (select count(*) from public.table_members tm where tm.table_id = v_tp),
               (select count(*) from public.games g where g.table_id = v_tp),
               (select count(*) from public.game_plays gp where gp.game_id in (v_g1, v_g2)),
               (select count(*) from public.games g where g.id = v_g1),
               (select count(*) from public.games g where g.id = v_g2),
               (select count(*) from public.game_plays gp where gp.game_id = v_g1),
               (select count(*) from public.game_plays gp where gp.game_id = v_g2),
               (select count(*) from public.game_hands h where h.game_id = v_g1),
               (select count(*) from public.game_hands h where h.game_id = v_g2),
               (select count(*) from public.game_cribs cr where cr.game_id = v_g1),
               (select count(*) from public.game_cribs cr where cr.game_id = v_g2),
               (select count(*) from public.game_decks dk where dk.game_id in (v_g1, v_g2)),
               (select count(*) from public.table_spectators ts where ts.table_id = v_tp))
      into v_got;
      execute 'reset role';
    exception when others then
      v_state := sqlstate;
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_state is not null then
      raise exception 'FAIL [P%] % reading TP raised % (%): %.', v_rec.o, v_rec.who, v_state,
        case v_state when '42P17' then 'infinite recursion in a policy' when '42501' then 'permission denied' else 'error' end, v_msg;
    end if;
    if v_got is distinct from v_rec.expect then
      raise exception 'FAIL [P%] % read % of TP (table,roster,games,plays,G1,G2,G1plays,G2plays,G1hands,G2hands,G1crib,G2crib,decks,spectators); expected %.', v_rec.o, v_rec.who, v_got, v_rec.expect;
    end if;
    v_checks := v_checks + 1;
  end loop;

  -- [P9] The stranger still reads the PUBLIC table TU: row, roster, game, play.
  v_got := null;
  v_state := null;
  perform set_config('request.jwt.claims', json_build_object('sub', v_s, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    select concat_ws(',',
             (select count(*) from public.tables t where t.id = v_tu),
             (select count(*) from public.table_members tm where tm.table_id = v_tu),
             (select count(*) from public.games g where g.table_id = v_tu),
             (select count(*) from public.game_plays gp where gp.game_id = v_gu))
    into v_got;
    execute 'reset role';
  exception when others then
    v_state := sqlstate;
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_state is not null or v_got is distinct from '1,1,1,1' then
    raise exception 'FAIL [P9] the stranger reading the public table TU: % (error %: %); expected 1,1,1,1.', coalesce(v_got, 'nothing'), coalesce(v_state, 'none'), coalesce(v_msg, '');
  end if;
  v_checks := v_checks + 1;

  -- [N1] anon: zero rows of TP and TU in all four tables, and NO error (the
  --      new policies are to authenticated only: anon evaluates nothing).
  v_got := null;
  v_state := null;
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  begin
    execute 'set local role anon';
    select concat_ws(',',
             (select count(*) from public.tables t where t.id in (v_tp, v_tu)),
             (select count(*) from public.table_members tm where tm.table_id in (v_tp, v_tu)),
             (select count(*) from public.games g where g.table_id in (v_tp, v_tu)),
             (select count(*) from public.game_plays gp where gp.game_id in (v_g1, v_g2, v_gu)))
    into v_got;
    execute 'reset role';
  exception when others then
    v_state := sqlstate;
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_state is not null or v_got is distinct from '0,0,0,0' then
    raise exception 'FAIL [N1] anon: % (error %: %); expected 0,0,0,0 and no error.', coalesce(v_got, 'nothing'), coalesce(v_state, 'none'), coalesce(v_msg, '');
  end if;
  v_checks := v_checks + 1;

  -- [U1] The admin's UPDATE reaches the private rows (Force-End's path: an
  --      UPDATE needs its row through SELECT too). No value changes.
  v_n := null;
  v_n2 := null;
  v_state := null;
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    update public.tables set status = status where id = v_tp;
    get diagnostics v_n = row_count;
    update public.games set status = status where id = v_g2;
    get diagnostics v_n2 = row_count;
    execute 'reset role';
  exception when others then
    v_state := sqlstate;
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_state is not null or v_n is distinct from 1 or v_n2 is distinct from 1 then
    raise exception 'FAIL [U1] the admin''s UPDATE of TP / G2: % / % row(s) (error %: %); expected 1 / 1.', v_n, v_n2, coalesce(v_state, 'none'), coalesce(v_msg, '');
  end if;
  v_checks := v_checks + 1;

  -- [J1] The stranger's PREVIEW by code (the confirm screen): it still finds
  --      the private table, with its host; and it seats nobody.
  v_out := null;
  v_tid := null;
  v_host := null;
  v_seated := null;
  v_live := null;
  v_got := null;
  v_state := null;
  perform set_config('request.jwt.claims', json_build_object('sub', v_s, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    select j.outcome, j.table_id, j.host_nickname, j.seated_count, j.game_live into v_out, v_tid, v_host, v_seated, v_live
    from public.join_table_by_code(v_codes[1], true) j;
    select concat_ws(',',
             (select count(*) from public.tables t where t.id = v_tp),
             (select count(*) from public.table_members tm where tm.table_id = v_tp),
             (select count(*) from public.games g where g.table_id = v_tp),
             (select count(*) from public.game_plays gp where gp.game_id in (v_g1, v_g2)))
    into v_got;
    execute 'reset role';
  exception when others then
    v_state := sqlstate;
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  select p.nickname into v_txt from public.profiles p where p.id = v_a;
  if v_state is not null then
    raise exception 'FAIL [J1] the stranger''s preview of TP raised % : %.', v_state, v_msg;
  end if;
  if v_out is distinct from 'preview' or v_tid is distinct from v_tp
     or v_host is distinct from v_txt or v_seated is distinct from 2
     or v_live is distinct from true or v_got is distinct from '0,0,0,0' then
    raise exception 'FAIL [J1] preview: outcome %, table % (TP %), host % (A is %), seated %, live %; then read % of TP. Expected preview, TP, A''s nickname, 2, true, then 0,0,0,0.',
      v_out, v_tid, v_tp, v_host, v_txt, v_seated, v_live, v_got;
  end if;
  v_checks := v_checks + 1;

  -- [J2] J joins TP by code: seated, J reads TP (row, roster of 3, both games).
  v_txt := null;
  v_got := null;
  v_state := null;
  perform set_config('request.jwt.claims', json_build_object('sub', v_j, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    select j.outcome into v_txt from public.join_table_by_code(v_codes[1]) j;
    select concat_ws(',',
             (select count(*) from public.tables t where t.id = v_tp),
             (select count(*) from public.table_members tm where tm.table_id = v_tp),
             (select count(*) from public.games g where g.table_id = v_tp))
    into v_got;
    execute 'reset role';
  exception when others then
    v_state := sqlstate;
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_state is not null or v_txt is distinct from 'joined' or v_got is distinct from '1,3,2' then
    raise exception 'FAIL [J2] J joining TP by code: outcome %, then read % (error %: %); expected joined, then 1,3,2.', coalesce(v_txt, 'none'), coalesce(v_got, 'nothing'), coalesce(v_state, 'none'), coalesce(v_msg, '');
  end if;
  v_checks := v_checks + 1;

  -- [J3] W watches TP by code: TP; W, a current spectator now, reads TP.
  v_tid := null;
  v_got := null;
  v_state := null;
  perform set_config('request.jwt.claims', json_build_object('sub', v_w, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    select w.table_id into v_tid from public.watch_table(v_codes[1]) w;
    select concat_ws(',',
             (select count(*) from public.tables t where t.id = v_tp),
             (select count(*) from public.table_members tm where tm.table_id = v_tp),
             (select count(*) from public.games g where g.table_id = v_tp))
    into v_got;
    execute 'reset role';
  exception when others then
    v_state := sqlstate;
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_state is not null or v_tid is distinct from v_tp or v_got is distinct from '1,3,2' then
    raise exception 'FAIL [J3] W watching TP by code: table % (TP %), then read % (error %: %); expected TP, then 1,3,2.', v_tid, v_tp, coalesce(v_got, 'nothing'), coalesce(v_state, 'none'), coalesce(v_msg, '');
  end if;
  v_checks := v_checks + 1;

  -- [B1] The lobby, as the stranger: TU among the open public tables; no
  --      open PRIVATE table, roster or game.
  v_got := null;
  v_state := null;
  perform set_config('request.jwt.claims', json_build_object('sub', v_s, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    select concat_ws(',',
             (select count(*) from public.tables t where t.status = 'open' and t.is_public and t.id = v_tu),
             (select count(*) from public.tables t where t.status = 'open' and not t.is_public),
             (select count(*) from public.table_members tm join public.tables t on t.id = tm.table_id
              where t.status = 'open' and not t.is_public),
             (select count(*) from public.games g join public.tables t on t.id = g.table_id
              where t.status = 'open' and not t.is_public))
    into v_got;
    execute 'reset role';
  exception when others then
    v_state := sqlstate;
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_state is not null or v_got is distinct from '1,0,0,0' then
    raise exception 'FAIL [B1] the stranger''s lobby: % (TU listed, open private tables, their rosters, their games; error %: %); expected 1,0,0,0.', coalesce(v_got, 'nothing'), coalesce(v_state, 'none'), coalesce(v_msg, '');
  end if;
  v_checks := v_checks + 1;

  if v_checks <> 21 then
    raise exception 'FAIL: % checks ran, expected 21.', v_checks;
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back).', v_checks;
end;
$$;
