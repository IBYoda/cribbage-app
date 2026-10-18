-- Phase 3, step E1: VERIFICATION.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER
-- docs/sql/phase3-e1-seating.sql. The whole file is ONE DO block: run it as
-- is.
--
-- It WRITES -- it creates tables, seats players, moves them, starts and
-- ends games and scores points, as real players -- and then deliberately
-- raises an exception at the very end, which rolls every write back. It
-- always "fails": the message is the verdict. "ALL n CHECKS PASSED (rolled
-- back) ..." is a pass; anything starting "FAIL" or "SETUP" is not.
-- Re-runnable, because nothing it does survives. (Same pattern as
-- muggins-mode-verification.sql: a DO block cannot COMMIT or ROLLBACK itself
-- in the SQL Editor, so the final exception IS the rollback.)
--
-- Same impersonation as the earlier verification scripts:
-- request.jwt.claims plus "set local role authenticated" (or anon) to act as
-- a client, and "reset role" to act as the owner between steps.
--
-- PLAYERS: A and B are the two OLDEST accounts that are NOT admins. A 3- and
-- a 4-player table need more people than this project may have, so C, D
-- and E are TEMPORARY accounts created in auth.users inside this
-- transaction (rolled back with everything else; nothing in this project's
-- SQL triggers on auth.users). Every table, seat and game below is created
-- here. A "stranger" is a random id that sits at no table and has no
-- account. Nothing about the real accounts or tables changes.
--
-- JOINING exactly as the client does: the table page upserts
-- { table_id, user_id } with onConflict "table_id,user_id" and
-- ignoreDuplicates, i.e.
--   insert into table_members (table_id, user_id) values (...)
--   on conflict (table_id, user_id) do nothing
-- -- the statement used below (with a seat added once, to show it is
-- ignored).
--
-- THE FROZEN now(): a DO block is one transaction, so now() is the same
-- instant all the way through. Every game made here directly gets an
-- explicit, strictly increasing created_at (v_age counts down in minutes,
-- all under the 5-hour timeout); a game start_game_with_deal itself creates
-- gets now(), the newest.
--
-- WHAT IT CHECKS
--   S  schema and catalog: the three columns (type, NOT NULL, default,
--      comment); the unique seat (deferrable) and the trigger; the policies
--      on tables (3) and table_members (2) unchanged; no column-level grants
--      on either; the helper signatures; FOURTEEN client functions,
--      executable by authenticated and never anon; seat_team, table_host
--      and the trigger function not client-callable; every untouched
--      function's body byte-for-byte its newest docs/sql version (md5).
--   C  constraints: max_players 1 and 5, team_mode 'pairs', a 3-player
--      Muggins table, seat 5, a repeated seat -- all refused.
--   I  inserts: a creator makes 3- and 4-player tables; the defaults; a
--      non-admin can't change max_players; no seat in someone else's name.
--   J  joining: seats 1 and 2; a client-sent seat ignored; a third player
--      refused with "This table is full."; a seated player's repeat upsert at
--      a FULL table quiet and seat kept; after leave_table the next player
--      takes the freed LOWEST seat; 3- and 4-player tables fill with distinct
--      seats and refuse the next.
--   H  set_seat and the host: move to an empty seat, swap two, a no-op;
--      refused for a non-host, a stranger, anon, a player not at the table,
--      seat 0, a seat above max_players, during a live game; who the host is.
--   T  seat_team.
--   R  2-player regression: two players join and start_game_with_deal starts
--      a cut as before; award_points to 121 still wins a normal table;
--      claim_win / confirm_win still end a Muggins match.
--
-- Expected message:
--   ALL 48 CHECKS PASSED (rolled back). A=... B=...

do $$
declare
  v_a uuid;
  v_b uuid;
  v_c uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid();
  v_e uuid := gen_random_uuid();
  v_stranger uuid := gen_random_uuid();
  v_codes text[];
  v_t2 uuid;
  v_t3 uuid;
  v_t4 uuid;
  v_tr uuid;
  v_tm uuid;
  v_g uuid;
  v_age int := 200;
  v_type text;
  v_nullable text;
  v_default text;
  v_n int;
  v_state text;
  v_msg text;
  v_seat int;
  v_seats int[];
  v_ret uuid;
  v_rec record;
  v_fn text;
  v_bad text;
  v_md5 text;
  v_expected jsonb;
  v_client text[] := array[
    'public.start_game_with_deal(uuid)', 'public.draw_cut_card(uuid)', 'public.acknowledge_deal_cut(uuid)',
    'public.discard_to_crib(uuid, text[])', 'public.play_card(uuid, text)', 'public.leave_table(uuid)',
    'public.show_hand(uuid)', 'public.show_crib(uuid)', 'public.confirm_count(uuid, int)',
    'public.next_hand(uuid, int)', 'public.claim_win(uuid)', 'public.clear_win_claim(uuid)',
    'public.confirm_win(uuid)', 'public.set_seat(uuid, uuid, int)'
  ];
  v_checks int := 0;
begin
  -- ---- Setup, as the owner ------------------------------------------------
  select u.id into v_a from auth.users u
  where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
  order by u.created_at limit 1;
  select u.id into v_b from auth.users u
  where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
  order by u.created_at offset 1 limit 1;
  if v_a is null or v_b is null then
    raise exception 'SETUP: the project needs at least two accounts that are not admins.';
  end if;

  begin
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
      (v_c, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e1-c-' || v_c || '@verification.invalid', now(), now()),
      (v_d, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e1-d-' || v_d || '@verification.invalid', now(), now()),
      (v_e, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e1-e-' || v_e || '@verification.invalid', now(), now());
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts C, D and E in auth.users: % (%).', sqlerrm, sqlstate;
  end;

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0'))
    order by n
    limit 12
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 12 then
    raise exception 'SETUP: fewer than twelve unused table codes.';
  end if;

  -- ==== S: schema and catalog, as the owner ==================================
  -- [S1] tables.max_players: smallint, NOT NULL, default 2, commented.
  select c.data_type, c.is_nullable, c.column_default into v_type, v_nullable, v_default
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'tables' and c.column_name = 'max_players';
  if v_type is distinct from 'smallint' or v_nullable is distinct from 'NO' or v_default is distinct from '2'
     or col_description('public.tables'::regclass,
          (select attnum from pg_attribute where attrelid = 'public.tables'::regclass and attname = 'max_players')) is null then
    raise exception 'FAIL [S1] tables.max_players is % / nullable % / default % (or has no comment), expected smallint / NO / 2.',
      coalesce(v_type, '(missing)'), v_nullable, v_default;
  end if;
  v_checks := v_checks + 1;

  -- [S2] tables.team_mode: text, NOT NULL, default 'teams', commented.
  select c.data_type, c.is_nullable, c.column_default into v_type, v_nullable, v_default
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'tables' and c.column_name = 'team_mode';
  if v_type is distinct from 'text' or v_nullable is distinct from 'NO' or v_default is distinct from '''teams''::text'
     or col_description('public.tables'::regclass,
          (select attnum from pg_attribute where attrelid = 'public.tables'::regclass and attname = 'team_mode')) is null then
    raise exception 'FAIL [S2] tables.team_mode is % / nullable % / default % (or has no comment), expected text / NO / ''teams''.',
      coalesce(v_type, '(missing)'), v_nullable, v_default;
  end if;
  v_checks := v_checks + 1;

  -- [S3] table_members.seat: smallint, NOT NULL, no default, commented.
  select c.data_type, c.is_nullable, c.column_default into v_type, v_nullable, v_default
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'table_members' and c.column_name = 'seat';
  if v_type is distinct from 'smallint' or v_nullable is distinct from 'NO' or v_default is not null
     or col_description('public.table_members'::regclass,
          (select attnum from pg_attribute where attrelid = 'public.table_members'::regclass and attname = 'seat')) is null then
    raise exception 'FAIL [S3] table_members.seat is % / nullable % / default % (or has no comment), expected smallint / NO / none.',
      coalesce(v_type, '(missing)'), v_nullable, v_default;
  end if;
  v_checks := v_checks + 1;

  -- [S4] The unique seat per table exists and is deferrable, initially
  -- immediate.
  select count(*) into v_n
  from pg_constraint con
  where con.conrelid = 'public.table_members'::regclass
    and con.contype = 'u'
    and con.condeferrable
    and not con.condeferred
    and con.conkey = array[
      (select attnum from pg_attribute where attrelid = 'public.table_members'::regclass and attname = 'table_id'),
      (select attnum from pg_attribute where attrelid = 'public.table_members'::regclass and attname = 'seat')
    ]::smallint[];
  if v_n <> 1 then
    raise exception 'FAIL [S4] found % deferrable unique (table_id, seat) constraint(s), expected 1.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [S5] The trigger: BEFORE INSERT, FOR EACH ROW, enabled, calling
  -- assign_table_seat.
  select count(*) into v_n
  from pg_trigger tg
  where tg.tgrelid = 'public.table_members'::regclass
    and tg.tgname = 'table_members_assign_seat'
    and not tg.tgisinternal
    and tg.tgenabled = 'O'
    and tg.tgfoid = 'public.assign_table_seat()'::regprocedure
    and (tg.tgtype & 1) = 1      -- row
    and (tg.tgtype & 2) = 2      -- before
    and (tg.tgtype & 4) = 4;     -- insert
  if v_n <> 1 then
    raise exception 'FAIL [S5] the BEFORE INSERT row trigger table_members_assign_seat was not found (or is disabled).';
  end if;
  v_checks := v_checks + 1;

  -- [S6] The tables policies are unchanged: exactly the three known ones.
  select count(*) into v_n from pg_policies where schemaname = 'public' and tablename = 'tables';
  if v_n <> 3
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'tables'
                    and cmd = 'SELECT' and policyname = 'Tables are viewable by any logged-in user')
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'tables'
                    and cmd = 'INSERT' and policyname = 'Users can create their own table')
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'tables'
                    and cmd = 'UPDATE' and policyname = 'Admins can force-end tables') then
    raise exception 'FAIL [S6] the tables policies are not exactly the three known ones (found %).', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [S7] The table_members policies are unchanged: exactly the two known ones
  -- (no UPDATE or DELETE policy -- seats change only through set_seat).
  select count(*) into v_n from pg_policies where schemaname = 'public' and tablename = 'table_members';
  if v_n <> 2
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'table_members'
                    and cmd = 'SELECT' and policyname = 'Table members are viewable by any logged-in user')
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'table_members'
                    and cmd = 'INSERT' and policyname = 'Users can add themselves to a table') then
    raise exception 'FAIL [S7] the table_members policies are not exactly the two known ones (found %).', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [S8] No column of tables or table_members carries a grant of its own.
  select count(*) into v_n from pg_attribute
  where attrelid in ('public.tables'::regclass, 'public.table_members'::regclass)
    and attnum > 0 and not attisdropped and attacl is not null;
  if v_n <> 0 then
    raise exception 'FAIL [S8] % column(s) of tables / table_members have column-level grants.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [S9] The new functions exist with these signatures.
  foreach v_fn in array array[
    'public.assign_table_seat()', 'public.seat_team(int)', 'public.table_host(uuid)', 'public.set_seat(uuid, uuid, int)'
  ] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL [S9] function % does not exist with that signature.', v_fn;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- [S10] The FOURTEEN client functions: executable by authenticated, never
  -- by anon (has_function_privilege counts PUBLIC grants too).
  v_n := 0;
  foreach v_fn in array v_client loop
    if to_regprocedure(v_fn) is null or not has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'FAIL [S10] authenticated cannot execute %.', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'FAIL [S10] anon CAN execute %.', v_fn;
    end if;
    v_n := v_n + 1;
  end loop;
  if v_n <> 14 then raise exception 'FAIL [S10] checked % client functions, expected 14.', v_n; end if;
  v_checks := v_checks + 1;

  -- [S11] Of every function this project's SQL defines, EXACTLY those
  -- fourteen are callable by a signed-in player: not the helpers, not the
  -- trigger, not the internal game functions.
  select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text) into v_bad
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in (
      'acknowledge_deal_cut', 'award_points', 'card_play_value', 'card_rank_value', 'claim_win',
      'clear_win_claim', 'confirm_count', 'confirm_win', 'deal_cards_for_game', 'discard_to_crib',
      'draw_cut_card', 'end_timed_out_sessions', 'has_legal_play', 'leave_table', 'next_hand',
      'play_card', 'score_hand', 'score_pegging', 'show_crib', 'show_hand', 'shuffled_deck',
      'start_game_with_deal', 'assign_table_seat', 'seat_team', 'table_host', 'set_seat'
    )
    and (has_function_privilege('authenticated', p.oid, 'execute')
         or has_function_privilege('anon', p.oid, 'execute'))
    and p.oid not in (select to_regprocedure(x)::oid from unnest(v_client) x);
  if v_bad is not null then
    raise exception 'FAIL [S11] these functions are client-callable but should not be: %.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [S12] Every untouched function is byte-for-byte its newest docs/sql
  -- version: md5 of the body (the text between the dollar quotes), line
  -- endings normalised. A mismatch names the function and the md5 found.
  v_expected := jsonb_build_object(
    'public.start_game_with_deal(uuid)',            '014c7e1fe9683cdc76b65c8fe2cb0d1b',  -- phase2-new-game-ready-gate.sql
    'public.draw_cut_card(uuid)',                   '2ca8d114de4e45861e21c23b2e4b65f8',  -- phase2-slice-5-cut-before-deal.sql
    'public.acknowledge_deal_cut(uuid)',            '5b06eec819234121db1bf802ea462c02',  -- phase2-slice-5-cut-before-deal.sql
    'public.discard_to_crib(uuid, text[])',         'd07cf0a9697e65857eae3036ee471517',  -- phase2-batch1-scoring-engines.sql
    'public.play_card(uuid, text)',                 'a333d53a4a6ac971fbb4728d84487a14',  -- phase2-batch2a-counting.sql
    'public.show_hand(uuid)',                       'ae5bd9553c21de7a395504f9d39977b6',  -- phase2-batch2a-counting.sql
    'public.show_crib(uuid)',                       'cab1efd1eb3cc00738f3ccef06c72cfe',  -- phase2-batch2a-counting.sql
    'public.confirm_count(uuid, int)',              'cca65adc984ebd0fce2a7e8838379809',  -- phase2-batch2a-counting.sql
    'public.next_hand(uuid, int)',                  'dfaacf1f321759f21144f1f26e99f5ba',  -- phase2-batch2b-ready-gate.sql
    'public.award_points(uuid, uuid, int, text)',   '7234674b5e9be6beac60541661cd964a',  -- muggins-mode.sql
    'public.leave_table(uuid)',                     '9c15b86bd236e9ffb108e9318251c5b8',  -- phase2-slice-5-cut-before-deal.sql
    'public.end_timed_out_sessions()',              'd46b95e2f27b93f2707d050de560720f',  -- phase2-slice-5-cut-before-deal.sql
    'public.claim_win(uuid)',                       'd95da0d7dc9477a460955749a36164bb',  -- muggins-mode.sql
    'public.clear_win_claim(uuid)',                 '0c4500259a1bb0fed638dce79944fab5',  -- muggins-mode.sql
    'public.confirm_win(uuid)',                     'ea2ec622a2cef0fffcc255257c816d94'   -- muggins-mode.sql
  );
  v_bad := null;
  for v_rec in select key, value #>> '{}' as md5 from jsonb_each(v_expected) loop
    select md5(replace(p.prosrc, E'\r', '')) into v_md5
    from pg_proc p where p.oid = to_regprocedure(v_rec.key);
    if v_md5 is distinct from v_rec.md5 then
      v_bad := coalesce(v_bad || '; ', '') || v_rec.key || ' has ' || coalesce(v_md5, '(missing)');
    end if;
  end loop;
  if v_bad is not null then
    raise exception 'FAIL [S12] function bodies differ from docs/sql: %.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== C: constraints, as the owner =========================================
  -- [C1] max_players 1 is refused (check).
  v_state := null;
  begin
    insert into public.tables (code, created_by, max_players) values (v_codes[1], v_a, 1);
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '23514' then
    raise exception 'FAIL [C1] max_players 1: expected 23514, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [C2] max_players 5 is refused.
  v_state := null;
  begin
    insert into public.tables (code, created_by, max_players) values (v_codes[1], v_a, 5);
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '23514' then
    raise exception 'FAIL [C2] max_players 5: expected 23514, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [C3] team_mode 'pairs' is refused.
  v_state := null;
  begin
    insert into public.tables (code, created_by, max_players, team_mode) values (v_codes[1], v_a, 4, 'pairs');
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '23514' then
    raise exception 'FAIL [C3] team_mode pairs: expected 23514, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [C4] A Muggins table must be a 2-player table.
  v_state := null;
  begin
    insert into public.tables (code, created_by, max_players, is_muggins) values (v_codes[1], v_a, 3, true);
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '23514' then
    raise exception 'FAIL [C4] a 3-player Muggins table: expected 23514, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- ==== I: inserts, as A ======================================================
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);

  -- [I1] A creates a 3-player table.
  insert into public.tables (code, created_by, max_players) values (v_codes[2], v_a, 3)
  returning id, max_players into v_t3, v_n;
  if v_n is distinct from 3 then raise exception 'FAIL [I1] a 3-player table stored max_players %.', v_n; end if;
  v_checks := v_checks + 1;

  -- [I2] ...and a 4-player Teams table.
  insert into public.tables (code, created_by, max_players, team_mode) values (v_codes[3], v_a, 4, 'teams')
  returning id, max_players into v_t4, v_n;
  if v_n is distinct from 4 then raise exception 'FAIL [I2] a 4-player table stored max_players %.', v_n; end if;
  v_checks := v_checks + 1;

  -- [I3] A table that says nothing is a 2-player Teams-default table.
  insert into public.tables (code, created_by) values (v_codes[4], v_a)
  returning id into v_t2;
  select max_players, team_mode into v_rec from public.tables where id = v_t2;
  if v_rec.max_players is distinct from 2 or v_rec.team_mode is distinct from 'teams' then
    raise exception 'FAIL [I3] defaults are % / %, expected 2 / teams.', v_rec.max_players, v_rec.team_mode;
  end if;
  v_checks := v_checks + 1;

  -- [I4] A (not an admin) cannot change their table's size afterwards.
  v_state := null; v_n := 0;
  begin
    update public.tables set max_players = 4 where id = v_t2;
    get diagnostics v_n = row_count;
  exception when others then v_state := sqlstate;
  end;
  execute 'reset role';
  select max_players into v_seat from public.tables where id = v_t2;
  if not (v_state = '42501' or (v_state is null and v_n = 0)) or v_seat is distinct from 2 then
    raise exception 'FAIL [I4] a non-admin update of max_players: % row(s), error %, now %.', v_n, coalesce(v_state, 'none'), v_seat;
  end if;
  v_checks := v_checks + 1;

  -- [I5] Unchanged rule: A cannot seat B.
  execute 'set local role authenticated';
  v_state := null;
  begin
    insert into public.table_members (table_id, user_id) values (v_t2, v_b)
    on conflict (table_id, user_id) do nothing;
  exception when others then v_state := sqlstate;
  end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [I5] A seating B: expected 42501 (RLS), got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- ==== J: joining, the client's own upsert ===================================
  -- [J1] A joins A's 2-player table: seat 1.
  execute 'set local role authenticated';
  insert into public.table_members (table_id, user_id) values (v_t2, v_a)
  on conflict (table_id, user_id) do nothing;
  execute 'reset role';
  select seat into v_seat from public.table_members where table_id = v_t2 and user_id = v_a;
  if v_seat is distinct from 1 then raise exception 'FAIL [J1] the first player got seat %, expected 1.', v_seat; end if;
  v_checks := v_checks + 1;

  -- [J2] B joins, asking for seat 4: gets seat 2 (the seat sent is ignored).
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  insert into public.table_members (table_id, user_id, seat) values (v_t2, v_b, 4)
  on conflict (table_id, user_id) do nothing;
  execute 'reset role';
  select seat into v_seat from public.table_members where table_id = v_t2 and user_id = v_b;
  if v_seat is distinct from 2 then raise exception 'FAIL [J2] the second player got seat %, expected 2.', v_seat; end if;
  v_checks := v_checks + 1;

  -- [J3] C joins the full 2-player table: refused, with the message.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  v_msg := null;
  begin
    insert into public.table_members (table_id, user_id) values (v_t2, v_c)
    on conflict (table_id, user_id) do nothing;
  exception when others then v_msg := sqlerrm;
  end;
  execute 'reset role';
  select count(*) into v_n from public.table_members where table_id = v_t2;
  if v_msg is distinct from 'This table is full.' or v_n <> 2 then
    raise exception 'FAIL [J3] a third player at a 2-player table: %, % seated; expected "This table is full." and 2.', coalesce(v_msg, 'no error'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [J4] B's page refreshes: the same upsert at the FULL table is quiet, and
  -- B keeps seat 2.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin
    insert into public.table_members (table_id, user_id) values (v_t2, v_b)
    on conflict (table_id, user_id) do nothing;
  exception when others then v_msg := sqlerrm;
  end;
  execute 'reset role';
  select seat into v_seat from public.table_members where table_id = v_t2 and user_id = v_b;
  select count(*) into v_n from public.table_members where table_id = v_t2;
  if v_msg is not null or v_seat is distinct from 2 or v_n <> 2 then
    raise exception 'FAIL [J4] a seated player''s repeat upsert at a full table: error % / seat % / % seated, expected none / 2 / 2.', coalesce(v_msg, 'none'), v_seat, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [J5] A leaves (the real leave_table): seat 1 is free, and C, joining
  -- next, takes it -- the lowest free seat, not seat 3.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  perform public.leave_table(v_t2);
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  insert into public.table_members (table_id, user_id) values (v_t2, v_c)
  on conflict (table_id, user_id) do nothing;
  execute 'reset role';
  select seat into v_seat from public.table_members where table_id = v_t2 and user_id = v_c;
  if v_seat is distinct from 1 then raise exception 'FAIL [J5] the next player after a leave got seat %, expected the freed seat 1.', v_seat; end if;
  v_checks := v_checks + 1;

  -- [J6] The 3-player table fills A, B, C: seats 1, 2, 3.
  execute 'set local role authenticated';
  foreach v_ret in array array[v_a, v_b, v_c] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_ret, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_ret::text, true);
    insert into public.table_members (table_id, user_id) values (v_t3, v_ret)
    on conflict (table_id, user_id) do nothing;
  end loop;
  execute 'reset role';
  select array_agg(seat order by seat) into v_seats from public.table_members where table_id = v_t3;
  if v_seats is distinct from array[1, 2, 3] then
    raise exception 'FAIL [J6] the 3-player table seats are %, expected {1,2,3}.', v_seats;
  end if;
  v_checks := v_checks + 1;

  -- [J7] ...and refuses D.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_d::text, true);
  v_msg := null;
  begin
    insert into public.table_members (table_id, user_id) values (v_t3, v_d)
    on conflict (table_id, user_id) do nothing;
  exception when others then v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'This table is full.' then
    raise exception 'FAIL [J7] a fourth player at a 3-player table: %, expected "This table is full.".', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [J8] The 4-player table fills A, B, C, D: seats 1, 2, 3, 4.
  execute 'set local role authenticated';
  foreach v_ret in array array[v_a, v_b, v_c, v_d] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_ret, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_ret::text, true);
    insert into public.table_members (table_id, user_id) values (v_t4, v_ret)
    on conflict (table_id, user_id) do nothing;
  end loop;
  execute 'reset role';
  select array_agg(seat order by seat) into v_seats from public.table_members where table_id = v_t4;
  if v_seats is distinct from array[1, 2, 3, 4] then
    raise exception 'FAIL [J8] the 4-player table seats are %, expected {1,2,3,4}.', v_seats;
  end if;
  v_checks := v_checks + 1;

  -- [J9] ...and refuses E.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_e, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_e::text, true);
  v_msg := null;
  begin
    insert into public.table_members (table_id, user_id) values (v_t4, v_e)
    on conflict (table_id, user_id) do nothing;
  exception when others then v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'This table is full.' then
    raise exception 'FAIL [J9] a fifth player at a 4-player table: %, expected "This table is full.".', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- ---- The seat constraints, now that there are seats (as the owner) --------
  -- [C5] Seat 5 is refused (check).
  v_state := null;
  begin
    update public.table_members set seat = 5 where table_id = v_t4 and user_id = v_d;
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '23514' then
    raise exception 'FAIL [C5] seat 5: expected 23514, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [C6] Two players in one seat is refused (unique).
  v_state := null;
  begin
    update public.table_members set seat = 1 where table_id = v_t4 and user_id = v_b;
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '23505' then
    raise exception 'FAIL [C6] a repeated seat: expected 23505, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- ==== H: set_seat and the host ==============================================
  -- [H1] The host is the creator while seated: A at the 4-player table.
  if public.table_host(v_t4) is distinct from v_a then
    raise exception 'FAIL [H1] table_host of the 4-player table is %, expected A.', public.table_host(v_t4);
  end if;
  v_checks := v_checks + 1;

  -- [H2] ...and the lowest seat once the creator has left: C (seat 1) at the
  -- 2-player table A left in J5.
  if public.table_host(v_t2) is distinct from v_c then
    raise exception 'FAIL [H2] table_host after the creator left is %, expected C (seat 1).', public.table_host(v_t2);
  end if;
  v_checks := v_checks + 1;

  -- D leaves the 4-player table: seat 4 is empty.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_d::text, true);
  perform public.leave_table(v_t4);

  -- [H3] A (host) moves B from seat 2 to the empty seat 4.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin perform public.set_seat(v_t4, v_b, 4); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  select array_agg(user_id::text || ':' || seat order by seat) into v_bad
  from public.table_members where table_id = v_t4;
  if v_msg is not null
     or (select seat from public.table_members where table_id = v_t4 and user_id = v_b) is distinct from 4
     or exists (select 1 from public.table_members where table_id = v_t4 and seat = 2) then
    raise exception 'FAIL [H3] moving B to the empty seat 4: error %, seats now %.', coalesce(v_msg, 'none'), v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [H4] A swaps C (seat 3) with B (seat 4), in one call.
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.set_seat(v_t4, v_c, 4); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is not null
     or (select seat from public.table_members where table_id = v_t4 and user_id = v_c) is distinct from 4
     or (select seat from public.table_members where table_id = v_t4 and user_id = v_b) is distinct from 3 then
    raise exception 'FAIL [H4] swapping C and B: error %, C % / B %, expected none / 4 / 3.', coalesce(v_msg, 'none'),
      (select seat from public.table_members where table_id = v_t4 and user_id = v_c),
      (select seat from public.table_members where table_id = v_t4 and user_id = v_b);
  end if;
  v_checks := v_checks + 1;

  -- [H5] Moving a player to the seat they hold: quiet, nothing changes.
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.set_seat(v_t4, v_a, 1); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is not null or (select seat from public.table_members where table_id = v_t4 and user_id = v_a) is distinct from 1 then
    raise exception 'FAIL [H5] moving A to A''s own seat: %.', coalesce(v_msg, 'seat changed');
  end if;
  v_checks := v_checks + 1;

  -- [H6] B, seated but not the host: refused.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_msg := null;
  begin perform public.set_seat(v_t4, v_b, 2); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'Only the host can move players between seats.' then
    raise exception 'FAIL [H6] a non-host moving a player: %, expected the host refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [H7] A stranger: refused.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_stranger::text, true);
  v_msg := null;
  begin perform public.set_seat(v_t4, v_b, 2); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'Only the host can move players between seats.' then
    raise exception 'FAIL [H7] a stranger moving a player: %, expected the host refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [H8] anon cannot execute it at all.
  execute 'set local role anon';
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  v_state := null;
  begin perform public.set_seat(v_t4, v_b, 2); exception when others then v_state := sqlstate; end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [H8] anon set_seat: expected 42501, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [H9] The host moving a player who is not at the table (D left): refused.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin perform public.set_seat(v_t4, v_d, 2); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'That player is not seated at this table.' then
    raise exception 'FAIL [H9] moving a player who is not seated: %, expected the not-seated refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [H10] Seat 0: refused.
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.set_seat(v_t4, v_b, 0); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is null or v_msg not like 'There is no seat 0 at this table%' then
    raise exception 'FAIL [H10] seat 0: %, expected the no-such-seat refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [H11] Seat 4 at a 3-player table (above max_players): refused.
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.set_seat(v_t3, v_b, 4); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is null or v_msg not like 'There is no seat 4 at this table (seats 1 to 3)%' then
    raise exception 'FAIL [H11] seat 4 at a 3-player table: %, expected the no-such-seat refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [H12] A live game at the table: refused, and nobody moves.
  insert into public.games (table_id, created_by, status, players, dealer_id, created_at)
  values (v_t4, v_a, 'cutting', array[v_a, v_b], null, now() - make_interval(mins => v_age))
  returning id into v_g;
  v_age := v_age - 1;
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.set_seat(v_t4, v_b, 2); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'Seats can only change before the game starts.'
     or (select seat from public.table_members where table_id = v_t4 and user_id = v_b) is distinct from 3 then
    raise exception 'FAIL [H12] moving a player during a live game: %, expected the before-the-game refusal.', coalesce(v_msg, 'no error');
  end if;
  update public.games set status = 'ended', ended_reason = 'admin' where id = v_g;
  v_checks := v_checks + 1;

  -- ==== T: seat_team ==========================================================
  -- [T1] Teams mode: seats 1 and 3 against 2 and 4; anything else null.
  if public.seat_team(1) is distinct from 1 or public.seat_team(3) is distinct from 1
     or public.seat_team(2) is distinct from 2 or public.seat_team(4) is distinct from 2
     or public.seat_team(0) is not null or public.seat_team(5) is not null then
    raise exception 'FAIL [T1] seat_team gives % % % % (and % % for 0 and 5), expected 1 2 1 2 (null null).',
      public.seat_team(1), public.seat_team(2), public.seat_team(3), public.seat_team(4), public.seat_team(0), public.seat_team(5);
  end if;
  v_checks := v_checks + 1;

  -- ==== R: the 2-player game is unchanged =====================================
  -- [R1] A and B open a new 2-player table, as the client does; B taps New
  -- Game: the first game at a table starts as a CUT, between the two.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  insert into public.tables (code, created_by) values (v_codes[5], v_a) returning id into v_tr;
  insert into public.table_members (table_id, user_id) values (v_tr, v_a)
  on conflict (table_id, user_id) do nothing;
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  insert into public.table_members (table_id, user_id) values (v_tr, v_b)
  on conflict (table_id, user_id) do nothing;
  v_msg := null; v_ret := null;
  begin
    v_ret := public.start_game_with_deal(v_tr);
  exception when others then v_msg := sqlerrm;
  end;
  execute 'reset role';
  select status, players, dealer_id into v_rec from public.games where id = v_ret;
  if v_msg is not null or v_ret is null or v_rec.status is distinct from 'cutting' or v_rec.dealer_id is not null
     or (select array_agg(u order by u) from unnest(v_rec.players) u)
        is distinct from (select array_agg(u order by u) from unnest(array[v_a, v_b]) u) then
    raise exception 'FAIL [R1] a 2-player start: error % / game % is % with players %, expected a cut between A and B.',
      coalesce(v_msg, 'none'), v_ret, v_rec.status, v_rec.players;
  end if;
  v_checks := v_checks + 1;

  -- [R2] On a normal table, 121 still wins: the game is dealt (as the owner)
  -- and A is awarded the winning points.
  update public.games set status = 'active', dealer_id = v_b, phase = 'play' where id = v_ret;
  update public.table_members set score = 119 where table_id = v_tr and user_id = v_a;
  perform public.award_points(v_tr, v_a, 5, 'fifteen + pair');
  select status, ended_reason, winner_id into v_rec from public.games where id = v_ret;
  if v_rec.status is distinct from 'ended' or v_rec.ended_reason is distinct from 'won' or v_rec.winner_id is distinct from v_a then
    raise exception 'FAIL [R2] a normal table at 121: % / % / winner %, expected ended / won / A.', v_rec.status, v_rec.ended_reason, v_rec.winner_id;
  end if;
  v_checks := v_checks + 1;

  -- [R3] A Muggins table still ends by agreement: A claims, B confirms.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  insert into public.tables (code, created_by, is_muggins) values (v_codes[6], v_a, true) returning id into v_tm;
  insert into public.table_members (table_id, user_id) values (v_tm, v_a)
  on conflict (table_id, user_id) do nothing;
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  insert into public.table_members (table_id, user_id) values (v_tm, v_b)
  on conflict (table_id, user_id) do nothing;
  execute 'reset role';
  insert into public.games (table_id, created_by, status, players, dealer_id, phase, created_at)
  values (v_tm, v_a, 'active', array[v_a, v_b], v_b, 'play', now() - make_interval(mins => v_age))
  returning id into v_g;
  v_age := v_age - 1;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_msg := null;
  begin
    perform public.claim_win(v_g);
    perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_b::text, true);
    perform public.confirm_win(v_g);
  exception when others then v_msg := sqlerrm;
  end;
  execute 'reset role';
  select status, ended_reason, winner_id, win_claim_by into v_rec from public.games where id = v_g;
  if v_msg is not null or v_rec.status is distinct from 'ended' or v_rec.ended_reason is distinct from 'won'
     or v_rec.winner_id is distinct from v_a or v_rec.win_claim_by is not null then
    raise exception 'FAIL [R3] a Muggins claim and confirm: error % / % / % / winner % / claim %, expected none / ended / won / A / null.',
      coalesce(v_msg, 'none'), v_rec.status, v_rec.ended_reason, v_rec.winner_id, v_rec.win_claim_by;
  end if;
  v_checks := v_checks + 1;

  raise exception 'ALL % CHECKS PASSED (rolled back). A=% B=%.', v_checks, v_a, v_b;
end $$;
