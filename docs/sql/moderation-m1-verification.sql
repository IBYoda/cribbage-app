-- Moderation, slice M1: VERIFICATION of the Block List
-- (docs/sql/moderation-m1-part1.sql and moderation-m1-part2.sql).
--
-- Run in the Supabase Dashboard -> SQL Editor after part 1 (it then runs its
-- part-1 cases only) and again after part 2 (every case). The whole file is
-- ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M1): precheck -> part 1 -> THIS FILE (part-1 cases)
-- -> app deploy (PR) -> precheck again -> part 2 -> THIS FILE (all cases)
-- -> regression suites -> hand test.
--
-- It WRITES -- one temporary function in pg_temp (m1_as: runs one statement
-- as a client role and returns its result or its error), temporary accounts
-- in auth.users and their profiles (16 people and 101 Block List targets),
-- test tables, seats, spectator rows, blocks and attempt_log rows; it calls
-- block_player, unblock_player, get_my_blocks, join_table_by_code,
-- watch_table and spectator_heartbeat as those people -- and then
-- deliberately raises an exception at the very end, which rolls EVERY write
-- back. A check that fails raises its own exception at once, which rolls
-- everything back the same way. It always "fails": the message is the
-- verdict (the dashboard hides notices).
--   After part 2: "ALL 34 CHECKS PASSED (rolled back)." is a pass.
--   After part 1 only: "ALL 19 PART-1 CHECKS PASSED (rolled back; part 2 is
--   not in yet, so the 15 join/watch checks were skipped)." is a pass.
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives. now() is frozen inside a
-- DO block, so "an hour ago" is made by moving attempt_log.created_at back
-- as the owner. Impersonation: request.jwt.claims plus "set local role
-- authenticated" (or anon), inside m1_as; "reset role" to act as the owner.
--
-- PEOPLE: A (the blocker; creates TA, TP, TA2), B (blocked by A; creates
-- TB), C (creates TC), D, E (the cap), F (the hourly limit), G (unblock at
-- the limit), K (blocks B, then joins B's table), S (seated at TA2 before
-- A blocks them), W (watching TA before A blocks them), R (removed from
-- watching TA, then blocked), V and S2 (seated at the full table TF), V2
-- (seated at TB), P (seated at TP), X (deleted: the cascade), 101 targets.
-- Tables: TA (A's, public, spectators allowed, 3 seats; A seated), TP (A's,
-- private; P seated), TA2 (A's; S seated), TC (C's, spectators allowed; C
-- seated), TB (B's; V2 seated), TF (V's, 2 seats, full).
--
-- WHAT IT CHECKS -- PART 1 (always)
--   K1  public.blocks: columns, primary key, self check, both foreign keys
--       ON DELETE CASCADE to auth.users, the blocked_id index, RLS on, no
--       policies, NO privilege for PUBLIC, anon, authenticated or
--       service_role, not in supabase_realtime; attempt_log allows
--       block_change.
--   K2  the four functions: part 1's bodies, security definer, search_path
--       ''; block_player / unblock_player / get_my_blocks executable by
--       authenticated only; _is_blocked_from_table by no client role.
--   K3  unchanged: leave_table, end_timed_out_sessions, assign_table_seat,
--       table_host (fingerprinted), spectator_heartbeat, remove_spectator,
--       chat_topic_allows, _attempts_guard.
--   K4  no RPC names whose list it acts on: the only functions by those
--       names are block_player(p_nickname text), unblock_player(p_target
--       uuid) and get_my_blocks() -- every one acts on auth.uid()'s list.
--   B1  A blocks B by B's exact nickname: 'blocked', the row, 1
--       block_change row.
--   B2  case and spaces don't matter: A blocks D by '  ' || upper(nickname)
--       || '  ': 'blocked'; 2 block_change rows.
--   B3  a no-op counts nothing: A blocks B again (lower case):
--       'already_blocked'; still 2 rows and 2 blocks.
--   B4  an unknown nickname, a blank one and null: 'not_found' each,
--       nothing counted.
--   B5  A blocks A (own nickname) and the easy computer (its nickname):
--       'not_allowed' each; the computer account as the caller:
--       'not_allowed'; nothing counted, no row; and a self-row inserted as
--       the owner is refused by blocks_not_self (23514).
--   B6  get_my_blocks: A sees exactly D then B (newest first, B's row moved
--       a minute back), with their nicknames; B, who blocked nobody yet,
--       sees nothing.
--   B7  B as authenticated cannot read or write public.blocks at all: a
--       SELECT, an INSERT, an UPDATE and a DELETE are each refused with a
--       PERMISSION ERROR (42501) -- not zero rows; anon's SELECT too.
--   B8  B cannot touch A's list: unblock_player(B) and unblock_player(A)
--       as B are 'not_blocked' and A's row stays; B blocking D writes only
--       B's own row; get_my_blocks as B returns only D;
--       _is_blocked_from_table as B is refused (42501).
--   B9  A unblocks D: 'unblocked', the row gone, 3 block_change rows; again:
--       'not_blocked', still 3.
--   B10 THE CAP: E with 100 blocks: the 101st is 'limit' (no row, nothing
--       counted); one already there is still 'already_blocked'.
--   B11 THE HOURLY LIMIT: F's 15 blocks and 15 unblocks (30 real changes)
--       are allowed; the 31st (a block) is refused: P0001, detail
--       rate_limited, the message; no row; still 30 block_change rows.
--   B12 an unblock at the limit is refused too (G: 30 rows already), the
--       row stays; with the 30 rows moved 61 minutes back it is allowed.
--   B13 nobody logged in: block_player and unblock_player raise "You must
--       be logged in ..."; get_my_blocks returns no rows.
--   B14 _is_blocked_from_table (as the owner): true for (B, TA) and (B, TP);
--       false for (B, TC), (B, an unknown id), (null, TA), (D, TA) after
--       the unblock, and (A, TB) -- only the creator's list counts, one way.
--   B15 deleting an account (X: on A's list, and with A on X's) removes
--       both rows (ON DELETE CASCADE).
-- WHAT IT CHECKS -- PART 2 (once join_table_by_code and watch_table have
-- part 2's bodies)
--   K5  join_table_by_code and watch_table: part 2's bodies (or moderation
--       M3 part 2's, which are M1's plus the kick refusal), EXECUTE for
--       authenticated only.
--   J1  B, blocked by A, joining by TYPED CODE: TA (public) and TP
--       (private): "You can't join this table.", P0001, no detail, no hint,
--       no row returned; no seat.
--   J2  B joining TA BY ID (p_table_id, as the ?t= link and an Open Tables
--       row do): the same refusal.
--   J3  B's PREVIEW of TA, by code and by id (both confirm screens): the
--       same refusal -- no preview row, so no host name, avatar or seats.
--   J4  B WATCHING TA, by code and by id (the watch page, watch by link):
--       the same refusal; no spectator row.
--   J5  none of J1-J4 counted anything: B has NO attempt_log row with an
--       action a join or watch could log (join, watch, code_guess,
--       create_table, create_computer_table). B's one block_change row from
--       B8 (B blocking D, a real change) is not one of them and is left out.
--   J6  the refusal has exactly the shape of a plain refusal: D joining the
--       full table TF gets "This table is full." with the same SQLSTATE
--       (P0001), detail ('') and hint ('') as J1-J4.
--   J7  a WRONG code is still counted: B's join_table_by_code with an
--       unused code answers not_found and logs 1 code_guess; watch_table
--       with another unused code answers no row and logs a 2nd.
--   J8  the lockout still comes first: with 5 wrong codes, B joining TA is
--       told locked_out (detail locked_out), not the block refusal.
--   J9  a block does not remove someone SEATED: S, seated at TA2 before A
--       blocked them, is still seated, and join_table_by_code (by id, and
--       the preview) answers 'already_seated' with the table.
--   J10 a block does not remove someone WATCHING: W, a current spectator of
--       TA before A blocked them, refreshes through watch_table (a row comes
--       back) and spectator_heartbeat answers 'game_ended' (no live game);
--       the spectator row stays, not removed.
--   J11 a REMOVED watcher who is then blocked is still told "You were
--       removed from watching this table." (being blocked changes nothing
--       for someone with standing).
--   J12 a table created by someone else is unaffected: B watches C's TC
--       (a row) and then joins it ('joined').
--   J13 the blocker can still join the blocked person's table: K blocks B,
--       then joins B's TB ('joined').
--   J14 once unblocked, B joins normally: A unblocks B ('unblocked'); B's
--       preview of TA answers 'preview' with A's nickname as host; B watches
--       TA (a row) and joins it ('joined').
--
-- Expected message:
--   ALL 34 CHECKS PASSED (rolled back).

do $$
declare
  v_checks int := 0;
  v_p2 boolean;
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid();
  v_e uuid := gen_random_uuid();
  v_f uuid := gen_random_uuid();
  v_g uuid := gen_random_uuid();
  v_k uuid := gen_random_uuid();
  v_s uuid := gen_random_uuid();
  v_s2 uuid := gen_random_uuid();
  v_w uuid := gen_random_uuid();
  v_rm uuid := gen_random_uuid();
  v_v uuid := gen_random_uuid();
  v_v2 uuid := gen_random_uuid();
  v_p uuid := gen_random_uuid();
  v_x uuid := gen_random_uuid();
  v_targets uuid[] := '{}';
  v_people uuid[];
  v_pid uuid;
  v_comp uuid;
  v_comp_nick text;
  v_codes text[];
  v_ta uuid;
  v_tp uuid;
  v_ta2 uuid;
  v_tc uuid;
  v_tb uuid;
  v_tf uuid;
  v_rec record;
  v_txt text;
  v_bad text;
  v_n int;
  v_r text[];
  v_r2 text[];
  v_full text[];
  v_refusal text := 'You can''t join this table.';
  v_limit_msg text := 'You have changed your Block List 30 times in the last hour. Please try again a little later.';
begin
  -- ==== MODE ======================================================================
  -- Part 2 mode: M1 part 2's bodies, or moderation M3 part 2's (M1's plus
  -- the kick refusal, which none of these people meets), in pairs.
  select ((select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.join_table_by_code(text, boolean, uuid)'))
            in ('cf40593ee5afda235144a13e38d27f4a', 'c3ee9ced2e1033f9c068acd3325c5583')
          and (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.watch_table(text, uuid)'))
            in ('5bf6065de215d92a02af63d035c7f910', '2aa5f9c37d65271f3b4619e58c171ea0'))
      or ((select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.join_table_by_code(text, boolean, uuid)'))
            in ('297fa4f04a02e226691ebf3b5b135f83', 'fbf046f1582863cc5697b06f670481b2')
          and (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.watch_table(text, uuid)'))
            in ('bdebb2e1a8213baa2a04666bcad59adb', 'ea5c3bd739b2f7243b985c7ea1fd9f2a'))
  into v_p2;
  if not coalesce(v_p2, false)
     and not ((select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.join_table_by_code(text, boolean, uuid)'))
                in ('1a2ff167c6d09fef6acd17177493422d', '9f3cee04a063447d626a1354533fda51')
              and (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.watch_table(text, uuid)'))
                in ('43775b57dffaec98ee7c003304a0c951', 'df591fa16528afd81a13bfdc3e975538')) then
    raise exception 'SETUP: join_table_by_code / watch_table are neither today''s, M1 part 2''s nor M3 part 2''s bodies (or only one of them is part 2''s). Run docs/sql/moderation-m1-precheck.sql.';
  end if;
  v_p2 := coalesce(v_p2, false);
  if to_regclass('public.blocks') is null or to_regprocedure('public.block_player(text)') is null then
    raise exception 'SETUP: part 1 is not in (no public.blocks or block_player). Run docs/sql/moderation-m1-part1.sql first.';
  end if;

  -- m1_as(role, user, sql): runs one statement as that client role (the
  -- user as auth.uid(), or nobody when null) and returns
  -- {sqlstate, message, detail, hint, first column of the first row} --
  -- the error fields null when it worked. Rolled back with everything else.
  create function pg_temp.m1_as(p_role text, p_uid uuid, p_sql text)
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
  -- [K1] public.blocks.
  select string_agg(a.attname::text || ' ' || format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else '' end, ', ' order by a.attnum)
  into v_txt
  from pg_attribute a
  where a.attrelid = 'public.blocks'::regclass and a.attnum > 0 and not a.attisdropped;
  v_bad := '';
  if v_txt is distinct from 'blocker_id uuid not null, blocked_id uuid not null, created_at timestamp with time zone not null' then
    v_bad := v_bad || 'columns "' || coalesce(v_txt, '?') || '"; ';
  end if;
  if not exists (select 1 from pg_constraint con where con.conrelid = 'public.blocks'::regclass and con.contype = 'p'
                   and pg_get_constraintdef(con.oid) = 'PRIMARY KEY (blocker_id, blocked_id)') then
    v_bad := v_bad || 'primary key; ';
  end if;
  if not exists (select 1 from pg_constraint con where con.conrelid = 'public.blocks'::regclass and con.contype = 'c'
                   and con.conname = 'blocks_not_self' and pg_get_constraintdef(con.oid) = 'CHECK ((blocker_id <> blocked_id))') then
    v_bad := v_bad || 'blocks_not_self; ';
  end if;
  select count(*) into v_n
  from pg_constraint con
  where con.conrelid = 'public.blocks'::regclass and con.contype = 'f'
    and con.confrelid = 'auth.users'::regclass and con.confdeltype = 'c';
  if v_n <> 2 then
    v_bad := v_bad || v_n::text || ' cascading foreign key(s) to auth.users (want 2); ';
  end if;
  if not exists (select 1 from pg_index i where i.indexrelid = to_regclass('public.blocks_blocked_id_idx')
                   and i.indrelid = 'public.blocks'::regclass and pg_get_indexdef(i.indexrelid) ~ '\(blocked_id\)$') then
    v_bad := v_bad || 'blocks_blocked_id_idx; ';
  end if;
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.blocks'::regclass) then
    v_bad := v_bad || 'RLS off; ';
  end if;
  select count(*) into v_n from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'blocks';
  if v_n <> 0 then
    v_bad := v_bad || v_n::text || ' policies; ';
  end if;
  select string_agg(case a.grantee when 0 then 'PUBLIC' else pg_get_userbyid(a.grantee)::text end || ':' || a.privilege_type, ', ')
  into v_txt
  from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
  where c.oid = 'public.blocks'::regclass
    and (a.grantee = 0 or a.grantee in (select r.oid from pg_roles r where r.rolname in ('anon', 'authenticated', 'service_role')));
  if v_txt is not null then
    v_bad := v_bad || 'client privileges ' || v_txt || '; ';
  end if;
  if exists (select 1 from pg_publication_tables pt where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = 'blocks') then
    v_bad := v_bad || 'in supabase_realtime; ';
  end if;
  if not exists (select 1 from pg_constraint con where con.conrelid = 'public.attempt_log'::regclass
                   and con.conname = 'attempt_log_action_check' and pg_get_constraintdef(con.oid) ~ '''block_change''') then
    v_bad := v_bad || 'attempt_log does not allow block_change; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K1] public.blocks / attempt_log: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K2] The four functions.
  v_bad := '';
  for v_rec in
    select * from (values
      ('public.block_player(text)', '10f6b07a3224aff16e1326daa6af5759', true),
      ('public.unblock_player(uuid)', 'c0363d27028d621c0008654506bade75', true),
      ('public.get_my_blocks()', '3d50e2a273ca16b23f6d89348016d8de', true),
      ('public._is_blocked_from_table(uuid, uuid)', '162f914c3b209186c819c66d18a23a99', false)
    ) as t(fn, lf, client)
  loop
    if to_regprocedure(v_rec.fn) is null then
      v_bad := v_bad || v_rec.fn || ' missing; ';
      continue;
    end if;
    select case when md5(replace(p.prosrc, E'\r', '')) <> v_rec.lf then 'body md5 ' || md5(replace(p.prosrc, E'\r', '')) || ' ' else '' end
           || case when not p.prosecdef then 'invoker ' else '' end
           || case when not (coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']) then 'search_path ' else '' end
           || case when has_function_privilege('authenticated', p.oid, 'EXECUTE') <> v_rec.client then 'authenticated EXECUTE ' || (not v_rec.client)::text || ' ' else '' end
           || case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon EXECUTE ' else '' end
           || case when exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) then 'PUBLIC grant ' else '' end
           || case when exists (select 1 from pg_roles r where r.rolname = 'service_role')
                        and has_function_privilege('service_role', p.oid, 'EXECUTE') then 'service_role EXECUTE ' else '' end
    into v_txt
    from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt <> '' then
      v_bad := v_bad || v_rec.fn || ': ' || v_txt || '; ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [K2] %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K3] Bodies M1 must not change.
  for v_rec in
    select * from (values
      ('public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa'),
      ('public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c'),
      ('public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb'),
      ('public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d'),
      ('public.spectator_heartbeat(uuid)', '41d2ea0e865c2a9d5fa7203875a27ace', '6b7c271d78eb4f72c1aff3c851b578e1'),
      ('public.remove_spectator(uuid, uuid)', 'dafa688f1b8c194e4be575cd0625ba12', '9786b9a5e50245365a2598b18da5892e'),
      ('public.chat_topic_allows(text, boolean)', '0458d5122d68d511b2e0fbceafe84aae', 'c4e6eda360de7d7723c4069e60d95345'),
      ('public._attempts_guard(uuid, text, integer, interval, text)', 'b1b69dbbdf10d50f78655a0da3b3ac69', '9406938991e89dcd38d0686a279b432a')
    ) as t(fn, lf, crlf)
  loop
    select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is null or v_txt not in (v_rec.lf, v_rec.crlf) then
      raise exception 'FAIL [K3] % has body md5 %; expected % (LF) or % (CRLF).', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf, v_rec.crlf;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- [K4] No parameter names whose list: exactly these three signatures.
  select string_agg(p.proname::text || '(' || pg_get_function_arguments(p.oid) || ')', ', ' order by p.proname)
  into v_txt
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname in ('block_player', 'unblock_player', 'get_my_blocks');
  if v_txt is distinct from 'block_player(p_nickname text), get_my_blocks(), unblock_player(p_target uuid)' then
    raise exception 'FAIL [K4] the Block List RPCs are "%"; expected block_player(p_nickname text), get_my_blocks(), unblock_player(p_target uuid).', coalesce(v_txt, 'missing');
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner =========================================================
  for v_i in 1..101 loop
    v_targets := v_targets || gen_random_uuid();
  end loop;
  v_people := array[v_a, v_b, v_c, v_d, v_e, v_f, v_g, v_k, v_s, v_s2, v_w, v_rm, v_v, v_v2, v_p, v_x] || v_targets;
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'm1-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
      -- X gets no profile (it only needs to exist for the cascade).
      if v_pid = v_x then
        continue;
      end if;
      insert into public.profiles (id, nickname)
      values (v_pid, 'm1' || left(replace(v_pid::text, '-', ''), 12))
      on conflict (id) do update set nickname = excluded.nickname;
    end loop;
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts and profiles: % (%).', sqlerrm, sqlstate;
  end;

  select ca.user_id into v_comp from public.computer_accounts ca where ca.level = 'easy';
  select p.nickname into v_comp_nick from public.profiles p where p.id = v_comp;
  if v_comp is null or btrim(coalesce(v_comp_nick, '')) = '' then
    raise exception 'SETUP: no easy computer account with a nickname (computer-accounts-setup.sql).';
  end if;

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    -- Codes no OPEN table holds -- every table while tables_code_open_key
    -- doesn't exist (the predicate the other suites use).
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                        and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null))
    order by n
    limit 8
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 8 then
    raise exception 'SETUP: fewer than eight free table codes.';
  end if;

  begin
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[1], v_a, true, true, 3) returning id into v_ta;
    insert into public.table_members (table_id, user_id) values (v_ta, v_a);
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[2], v_a, false, false, 2) returning id into v_tp;
    insert into public.table_members (table_id, user_id) values (v_tp, v_p);
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[3], v_a, true, false, 2) returning id into v_ta2;
    insert into public.table_members (table_id, user_id) values (v_ta2, v_s);
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[4], v_c, true, true, 3) returning id into v_tc;
    insert into public.table_members (table_id, user_id) values (v_tc, v_c);
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[5], v_b, true, false, 2) returning id into v_tb;
    insert into public.table_members (table_id, user_id) values (v_tb, v_v2);
    insert into public.tables (code, created_by, is_public, allow_spectators, max_players)
    values (v_codes[6], v_v, true, false, 2) returning id into v_tf;
    insert into public.table_members (table_id, user_id) values (v_tf, v_v);
    insert into public.table_members (table_id, user_id) values (v_tf, v_s2);
    -- W watches TA (current); R was removed from watching TA.
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at)
    values (v_ta, v_w, now(), now());
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at, removed_at)
    values (v_ta, v_rm, now(), now(), now());
  exception when others then
    raise exception 'SETUP: could not create the test tables: % (%).', sqlerrm, sqlstate;
  end;

  -- ==== B: THE BLOCK LIST ===========================================================
  -- [B1] A blocks B by B's exact nickname.
  v_r := pg_temp.m1_as('authenticated', v_a, format('select public.block_player(%L)', 'm1' || left(replace(v_b::text, '-', ''), 12)));
  select count(*) into v_n from public.attempt_log al where al.user_id = v_a and al.action = 'block_change';
  if v_r[1] is not null or v_r[5] is distinct from 'blocked' or v_n <> 1
     or not exists (select 1 from public.blocks b where b.blocker_id = v_a and b.blocked_id = v_b) then
    raise exception 'FAIL [B1] A blocking B: % (error %: %), % block_change row(s); expected blocked, the row, 1.', v_r[5], coalesce(v_r[1], 'none'), coalesce(v_r[2], ''), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [B2] Case and surrounding spaces don't matter.
  v_r := pg_temp.m1_as('authenticated', v_a, format('select public.block_player(%L)', '  ' || upper('m1' || left(replace(v_d::text, '-', ''), 12)) || '  '));
  select count(*) into v_n from public.attempt_log al where al.user_id = v_a and al.action = 'block_change';
  if v_r[1] is not null or v_r[5] is distinct from 'blocked' or v_n <> 2
     or not exists (select 1 from public.blocks b where b.blocker_id = v_a and b.blocked_id = v_d) then
    raise exception 'FAIL [B2] A blocking D by "  UPPER  ": % (error %: %), % row(s); expected blocked, the row, 2.', v_r[5], coalesce(v_r[1], 'none'), coalesce(v_r[2], ''), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [B3] Blocking again is a no-op that counts nothing.
  v_r := pg_temp.m1_as('authenticated', v_a, format('select public.block_player(%L)', lower('m1' || left(replace(v_b::text, '-', ''), 12))));
  select count(*) into v_n from public.attempt_log al where al.user_id = v_a and al.action = 'block_change';
  if v_r[1] is not null or v_r[5] is distinct from 'already_blocked' or v_n <> 2
     or (select count(*) from public.blocks b where b.blocker_id = v_a) <> 2 then
    raise exception 'FAIL [B3] A blocking B again: % (error %), % row(s); expected already_blocked, 2, 2 blocks.', v_r[5], coalesce(v_r[1], 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [B4] Unknown, blank, null: not_found, nothing counted.
  v_txt := concat_ws(',',
    (pg_temp.m1_as('authenticated', v_a, format('select public.block_player(%L)', 'm1-no-such-' || left(md5(random()::text), 10))))[5],
    (pg_temp.m1_as('authenticated', v_a, 'select public.block_player(''   '')'))[5],
    (pg_temp.m1_as('authenticated', v_a, 'select public.block_player(null)'))[5]);
  select count(*) into v_n from public.attempt_log al where al.user_id = v_a and al.action = 'block_change';
  if v_txt is distinct from 'not_found,not_found,not_found' or v_n <> 2
     or (select count(*) from public.blocks b where b.blocker_id = v_a) <> 2 then
    raise exception 'FAIL [B4] unknown / blank / null nicknames: %, % row(s); expected not_found x3 and 2.', v_txt, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [B5] Yourself, a computer, a computer caller: not_allowed.
  v_txt := concat_ws(',',
    (pg_temp.m1_as('authenticated', v_a, format('select public.block_player(%L)', 'm1' || left(replace(v_a::text, '-', ''), 12))))[5],
    (pg_temp.m1_as('authenticated', v_a, format('select public.block_player(%L)', v_comp_nick)))[5],
    (pg_temp.m1_as('authenticated', v_comp, format('select public.block_player(%L)', 'm1' || left(replace(v_b::text, '-', ''), 12))))[5]);
  select count(*) into v_n from public.attempt_log al where al.user_id in (v_a, v_comp) and al.action = 'block_change';
  if v_txt is distinct from 'not_allowed,not_allowed,not_allowed' or v_n <> 2
     or exists (select 1 from public.blocks b where b.blocker_id = v_comp or b.blocked_id in (v_a, v_comp)) then
    raise exception 'FAIL [B5] self / computer / computer caller: %, % row(s); expected not_allowed x3, 2, no rows.', v_txt, v_n;
  end if;
  v_txt := null;
  begin
    insert into public.blocks (blocker_id, blocked_id) values (v_a, v_a);
  exception when others then
    v_txt := sqlstate;
  end;
  if v_txt is distinct from '23514' then
    raise exception 'FAIL [B5] a self-row inserted as the owner: %; expected 23514 (blocks_not_self).', coalesce(v_txt, 'allowed');
  end if;
  v_checks := v_checks + 1;

  -- [B6] get_my_blocks: the caller's own, newest first.
  update public.blocks set created_at = now() - interval '1 minute' where blocker_id = v_a and blocked_id = v_b;
  v_r := pg_temp.m1_as('authenticated', v_a,
    'select string_agg(x.user_id::text || ''='' || coalesce(x.nickname, ''?''), '','' order by x.n) from (select g.user_id, g.nickname, row_number() over () as n from public.get_my_blocks() g) x');
  v_r2 := pg_temp.m1_as('authenticated', v_b, 'select count(*)::text from public.get_my_blocks()');
  if v_r[1] is not null or v_r[5] is distinct from v_d::text || '=m1' || left(replace(v_d::text, '-', ''), 12) || ',' || v_b::text || '=m1' || left(replace(v_b::text, '-', ''), 12)
     or v_r2[1] is not null or v_r2[5] is distinct from '0' then
    raise exception 'FAIL [B6] get_my_blocks: A sees "%" (error %), B sees % row(s) (error %); expected D then B, and 0.', v_r[5], coalesce(v_r[1], 'none'), v_r2[5], coalesce(v_r2[1], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [B7] No client access to the table at all: permission errors, not zero rows.
  v_txt := concat_ws(',',
    (pg_temp.m1_as('authenticated', v_b, 'select count(*)::text from public.blocks'))[1],
    (pg_temp.m1_as('authenticated', v_b, format('insert into public.blocks (blocker_id, blocked_id) values (%L, %L) returning ''x''', v_b, v_c)))[1],
    (pg_temp.m1_as('authenticated', v_b, format('update public.blocks set created_at = now() where blocked_id = %L returning ''x''', v_b)))[1],
    (pg_temp.m1_as('authenticated', v_b, format('delete from public.blocks where blocked_id = %L returning ''x''', v_b)))[1],
    (pg_temp.m1_as('anon', null, 'select count(*)::text from public.blocks'))[1]);
  if v_txt is distinct from '42501,42501,42501,42501,42501'
     or not exists (select 1 from public.blocks b where b.blocker_id = v_a and b.blocked_id = v_b) then
    raise exception 'FAIL [B7] B''s select / insert / update / delete and anon''s select on blocks: % (sqlstates); expected 42501 x5 and A''s row untouched.', coalesce(v_txt, '(all allowed)');
  end if;
  v_checks := v_checks + 1;

  -- [B8] B cannot reach A's list.
  v_txt := concat_ws(',',
    (pg_temp.m1_as('authenticated', v_b, format('select public.unblock_player(%L)', v_b)))[5],
    (pg_temp.m1_as('authenticated', v_b, format('select public.unblock_player(%L)', v_a)))[5],
    (pg_temp.m1_as('authenticated', v_b, format('select public.block_player(%L)', 'm1' || left(replace(v_d::text, '-', ''), 12))))[5]);
  v_r := pg_temp.m1_as('authenticated', v_b, 'select string_agg(g.user_id::text, '','') from public.get_my_blocks() g');
  v_r2 := pg_temp.m1_as('authenticated', v_b, format('select public._is_blocked_from_table(%L, %L)::text', v_b, v_ta));
  if v_txt is distinct from 'not_blocked,not_blocked,blocked'
     or v_r[5] is distinct from v_d::text
     or v_r2[1] is distinct from '42501'
     or (select string_agg(b.blocked_id::text, ',' order by b.blocked_id) from public.blocks b where b.blocker_id = v_a)
        is distinct from (select string_agg(u::text, ',' order by u) from unnest(array[v_b, v_d]) u) then
    raise exception 'FAIL [B8] B''s unblock(B) / unblock(A) / block(D): %; B''s list "%"; B calling the helper: %; expected not_blocked, not_blocked, blocked; D only; 42501; A''s list unchanged.', v_txt, v_r[5], coalesce(v_r2[1], 'allowed');
  end if;
  v_checks := v_checks + 1;

  -- [B9] Unblock: a real change once, then a no-op.
  v_txt := concat_ws(',',
    (pg_temp.m1_as('authenticated', v_a, format('select public.unblock_player(%L)', v_d)))[5],
    (pg_temp.m1_as('authenticated', v_a, format('select public.unblock_player(%L)', v_d)))[5]);
  select count(*) into v_n from public.attempt_log al where al.user_id = v_a and al.action = 'block_change';
  if v_txt is distinct from 'unblocked,not_blocked' or v_n <> 3
     or exists (select 1 from public.blocks b where b.blocker_id = v_a and b.blocked_id = v_d) then
    raise exception 'FAIL [B9] A unblocking D twice: %, % row(s); expected unblocked,not_blocked and 3, the row gone.', v_txt, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [B10] The cap of 100.
  insert into public.blocks (blocker_id, blocked_id)
  select v_e, v_targets[i] from generate_series(1, 100) as i;
  v_txt := concat_ws(',',
    (pg_temp.m1_as('authenticated', v_e, format('select public.block_player(%L)', 'm1' || left(replace(v_targets[101]::text, '-', ''), 12))))[5],
    (pg_temp.m1_as('authenticated', v_e, format('select public.block_player(%L)', 'm1' || left(replace(v_targets[1]::text, '-', ''), 12))))[5]);
  select count(*) into v_n from public.attempt_log al where al.user_id = v_e and al.action = 'block_change';
  if v_txt is distinct from 'limit,already_blocked' or v_n <> 0
     or (select count(*) from public.blocks b where b.blocker_id = v_e) <> 100 then
    raise exception 'FAIL [B10] E at 100: %, % row(s); expected limit,already_blocked, 0, still 100.', v_txt, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [B11] 30 real changes an hour; the 31st refused.
  v_bad := '';
  for v_i in 1..15 loop
    v_r := pg_temp.m1_as('authenticated', v_f, format('select public.block_player(%L)', 'm1' || left(replace(v_targets[v_i]::text, '-', ''), 12)));
    if v_r[5] is distinct from 'blocked' then
      v_bad := v_bad || 'block ' || v_i || ': ' || coalesce(v_r[5], v_r[2]) || '; ';
    end if;
  end loop;
  for v_i in 1..15 loop
    v_r := pg_temp.m1_as('authenticated', v_f, format('select public.unblock_player(%L)', v_targets[v_i]));
    if v_r[5] is distinct from 'unblocked' then
      v_bad := v_bad || 'unblock ' || v_i || ': ' || coalesce(v_r[5], v_r[2]) || '; ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [B11] F''s first 30 changes: %expected all allowed.', v_bad;
  end if;
  v_r := pg_temp.m1_as('authenticated', v_f, format('select public.block_player(%L)', 'm1' || left(replace(v_targets[16]::text, '-', ''), 12)));
  select count(*) into v_n from public.attempt_log al where al.user_id = v_f and al.action = 'block_change';
  if v_r[1] is distinct from 'P0001' or v_r[3] is distinct from 'rate_limited' or v_r[2] is distinct from v_limit_msg
     or v_n <> 30 or exists (select 1 from public.blocks b where b.blocker_id = v_f) then
    raise exception 'FAIL [B11] F''s 31st change: % / % / "%", % row(s); expected P0001 / rate_limited / "%", 30, no blocks.', coalesce(v_r[1], 'no error'), coalesce(v_r[3], '-'), coalesce(v_r[2], ''), v_n, v_limit_msg;
  end if;
  v_checks := v_checks + 1;

  -- [B12] An unblock at the limit is refused; an hour later it is allowed.
  insert into public.blocks (blocker_id, blocked_id) values (v_g, v_targets[1]);
  insert into public.attempt_log (user_id, action, success)
  select v_g, 'block_change', true from generate_series(1, 30);
  v_r := pg_temp.m1_as('authenticated', v_g, format('select public.unblock_player(%L)', v_targets[1]));
  if v_r[1] is distinct from 'P0001' or v_r[3] is distinct from 'rate_limited'
     or not exists (select 1 from public.blocks b where b.blocker_id = v_g and b.blocked_id = v_targets[1]) then
    raise exception 'FAIL [B12] G''s unblock at the limit: % / %; expected P0001 / rate_limited and the row kept.', coalesce(v_r[1], 'no error'), coalesce(v_r[3], '-');
  end if;
  update public.attempt_log set created_at = created_at - interval '61 minutes' where user_id = v_g;
  v_r := pg_temp.m1_as('authenticated', v_g, format('select public.unblock_player(%L)', v_targets[1]));
  if v_r[1] is not null or v_r[5] is distinct from 'unblocked' then
    raise exception 'FAIL [B12] G''s unblock after the hour: % (error %: %); expected unblocked.', v_r[5], coalesce(v_r[1], 'none'), coalesce(v_r[2], '');
  end if;
  v_checks := v_checks + 1;

  -- [B13] Nobody logged in.
  v_r := pg_temp.m1_as('authenticated', null, format('select public.block_player(%L)', 'm1' || left(replace(v_b::text, '-', ''), 12)));
  v_r2 := pg_temp.m1_as('authenticated', null, format('select public.unblock_player(%L)', v_b));
  v_txt := (pg_temp.m1_as('authenticated', null, 'select count(*)::text from public.get_my_blocks()'))[5];
  if v_r[2] is distinct from 'You must be logged in to block a player.'
     or v_r2[2] is distinct from 'You must be logged in to unblock a player.'
     or v_txt is distinct from '0' then
    raise exception 'FAIL [B13] not logged in: block "%", unblock "%", get_my_blocks % row(s); expected the two log-in messages and 0.', coalesce(v_r[2], v_r[5]), coalesce(v_r2[2], v_r2[5]), v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [B14] The helper, as the owner: only the creator's list, one way.
  v_txt := concat_ws(',',
    public._is_blocked_from_table(v_b, v_ta)::text,
    public._is_blocked_from_table(v_b, v_tp)::text,
    public._is_blocked_from_table(v_b, v_tc)::text,
    public._is_blocked_from_table(v_b, gen_random_uuid())::text,
    coalesce(public._is_blocked_from_table(null, v_ta)::text, 'null'),
    public._is_blocked_from_table(v_d, v_ta)::text,
    public._is_blocked_from_table(v_a, v_tb)::text);
  if v_txt is distinct from 'true,true,false,false,false,false,false' then
    raise exception 'FAIL [B14] _is_blocked_from_table (B,TA) (B,TP) (B,TC) (B,unknown) (null,TA) (D,TA) (A,TB): %; expected true,true,false,false,false,false,false.', v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [B15] Deleting an account removes its rows both ways.
  insert into public.blocks (blocker_id, blocked_id) values (v_a, v_x), (v_x, v_a);
  delete from auth.users where id = v_x;
  if exists (select 1 from public.blocks b where v_x in (b.blocker_id, b.blocked_id)) then
    raise exception 'FAIL [B15] X''s rows survived the deletion of X''s account.';
  end if;
  v_checks := v_checks + 1;

  if not v_p2 then
    if v_checks <> 19 then
      raise exception 'FAIL: % part-1 checks ran, expected 19.', v_checks;
    end if;
    raise exception 'ALL % PART-1 CHECKS PASSED (rolled back; part 2 is not in yet, so the 15 join/watch checks were skipped).', v_checks;
  end if;

  -- ==== PART 2: JOIN AND WATCH ======================================================
  -- [K5] Part 2's bodies, authenticated only.
  for v_rec in
    select * from (values ('public.join_table_by_code(text, boolean, uuid)'), ('public.watch_table(text, uuid)')) as t(fn)
  loop
    if not has_function_privilege('authenticated', v_rec.fn, 'EXECUTE')
       or has_function_privilege('anon', v_rec.fn, 'EXECUTE')
       or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where p.oid = to_regprocedure(v_rec.fn) and a.grantee = 0) then
      raise exception 'FAIL [K5] % is not executable by authenticated only.', v_rec.fn;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- [J1] By typed code: TA (public) and TP (private).
  v_bad := '';
  foreach v_txt in array array[v_codes[1], v_codes[2]] loop
    v_r := pg_temp.m1_as('authenticated', v_b, format('select outcome from public.join_table_by_code(%L)', v_txt));
    if v_r[1] is distinct from 'P0001' or v_r[2] is distinct from v_refusal or v_r[3] is distinct from '' or v_r[4] is distinct from '' or v_r[5] is not null then
      v_bad := v_bad || v_txt || ': ' || coalesce(v_r[1], 'no error') || ' / "' || coalesce(v_r[2], v_r[5], '') || '" / detail "' || coalesce(v_r[3], '') || '" / hint "' || coalesce(v_r[4], '') || '"; ';
    end if;
  end loop;
  if v_bad <> '' or exists (select 1 from public.table_members tm where tm.user_id = v_b) then
    raise exception 'FAIL [J1] B joining A''s tables by typed code: %expected P0001 / "%" / no detail / no hint, and no seat.', v_bad, v_refusal;
  end if;
  v_checks := v_checks + 1;

  -- [J2] By id.
  v_r := pg_temp.m1_as('authenticated', v_b, format('select outcome from public.join_table_by_code(%L, false, %L)', v_codes[1], v_ta));
  if v_r[1] is distinct from 'P0001' or v_r[2] is distinct from v_refusal or v_r[3] is distinct from '' or v_r[4] is distinct from ''
     or exists (select 1 from public.table_members tm where tm.user_id = v_b) then
    raise exception 'FAIL [J2] B joining TA by id: % / "%" / "%" / "%"; expected P0001 / "%" / "" / "", no seat.', coalesce(v_r[1], 'no error'), coalesce(v_r[2], v_r[5], ''), coalesce(v_r[3], ''), coalesce(v_r[4], ''), v_refusal;
  end if;
  v_checks := v_checks + 1;

  -- [J3] The preview, by code and by id: no row at all.
  v_r := pg_temp.m1_as('authenticated', v_b, format('select host_nickname from public.join_table_by_code(%L, true)', v_codes[1]));
  v_r2 := pg_temp.m1_as('authenticated', v_b, format('select host_nickname from public.join_table_by_code(%L, true, %L)', v_codes[1], v_ta));
  if v_r[1] is distinct from 'P0001' or v_r[2] is distinct from v_refusal or v_r[3] is distinct from '' or v_r[4] is distinct from '' or v_r[5] is not null
     or v_r2[1] is distinct from 'P0001' or v_r2[2] is distinct from v_refusal or v_r2[3] is distinct from '' or v_r2[4] is distinct from '' or v_r2[5] is not null then
    raise exception 'FAIL [J3] B''s preview of TA: by code % / "%", by id % / "%"; expected P0001 / "%" twice, no row (no host name).', coalesce(v_r[1], 'no error'), coalesce(v_r[2], v_r[5], ''), coalesce(v_r2[1], 'no error'), coalesce(v_r2[2], v_r2[5], ''), v_refusal;
  end if;
  v_checks := v_checks + 1;

  -- [J4] Watching, by code and by id.
  v_r := pg_temp.m1_as('authenticated', v_b, format('select table_id::text from public.watch_table(%L)', v_codes[1]));
  v_r2 := pg_temp.m1_as('authenticated', v_b, format('select table_id::text from public.watch_table(%L, %L)', v_codes[1], v_ta));
  if v_r[1] is distinct from 'P0001' or v_r[2] is distinct from v_refusal or v_r[3] is distinct from '' or v_r[4] is distinct from ''
     or v_r2[1] is distinct from 'P0001' or v_r2[2] is distinct from v_refusal or v_r2[3] is distinct from '' or v_r2[4] is distinct from ''
     or exists (select 1 from public.table_spectators ts where ts.user_id = v_b) then
    raise exception 'FAIL [J4] B watching TA: by code % / "%", by id % / "%"; expected P0001 / "%" twice, no spectator row.', coalesce(v_r[1], 'no error'), coalesce(v_r[2], v_r[5], ''), coalesce(v_r2[1], 'no error'), coalesce(v_r2[2], v_r2[5], ''), v_refusal;
  end if;
  v_checks := v_checks + 1;

  -- [J5] Nothing counted for B by J1-J4. Only the actions a join or watch
  -- could log: B8's block_change row (B blocking D) is a real change made
  -- earlier on purpose, not something J1-J4 left.
  select count(*), string_agg(distinct al.action, ', ')
  into v_n, v_txt
  from public.attempt_log al
  where al.user_id = v_b
    and al.action in ('join', 'watch', 'code_guess', 'create_table', 'create_computer_table');
  if v_n <> 0 then
    raise exception 'FAIL [J5] B has % attempt_log row(s) after J1-J4 (actions: %); expected 0 (a found-but-refused table counts nothing).', v_n, v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [J6] The same shape as a plain refusal ("This table is full.").
  v_full := pg_temp.m1_as('authenticated', v_d, format('select outcome from public.join_table_by_code(%L, false, %L)', v_codes[6], v_tf));
  if v_full[2] is distinct from 'This table is full.'
     or v_full[1] is distinct from v_r[1] or v_full[3] is distinct from v_r[3] or v_full[4] is distinct from v_r[4] then
    raise exception 'FAIL [J6] the full-table refusal is % / "%" / "%" / "%"; the block refusal % / "%" / "%" / "%". Expected the same SQLSTATE, detail and hint.',
      coalesce(v_full[1], 'no error'), coalesce(v_full[2], v_full[5], ''), coalesce(v_full[3], ''), coalesce(v_full[4], ''),
      coalesce(v_r[1], ''), coalesce(v_r[2], ''), coalesce(v_r[3], ''), coalesce(v_r[4], '');
  end if;
  v_checks := v_checks + 1;

  -- [J7] A wrong code is still counted (join and watch).
  v_r := pg_temp.m1_as('authenticated', v_b, format('select outcome from public.join_table_by_code(%L)', v_codes[7]));
  v_r2 := pg_temp.m1_as('authenticated', v_b, format('select table_id::text from public.watch_table(%L)', v_codes[8]));
  select count(*) into v_n from public.attempt_log al where al.user_id = v_b and al.action = 'code_guess' and not al.success;
  if v_r[1] is not null or v_r[5] is distinct from 'not_found' or v_r2[1] is not null or v_r2[5] is not null or v_n <> 2 then
    raise exception 'FAIL [J7] B''s wrong codes: join % (error %), watch % (error %), % code_guess row(s); expected not_found, no row, 2.', v_r[5], coalesce(v_r[1], 'none'), coalesce(v_r2[5], 'no row'), coalesce(v_r2[1], 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [J8] The lockout still comes first.
  insert into public.attempt_log (user_id, action, success)
  select v_b, 'code_guess', false from generate_series(1, 3);
  v_r := pg_temp.m1_as('authenticated', v_b, format('select outcome from public.join_table_by_code(%L, false, %L)', v_codes[1], v_ta));
  if v_r[3] is distinct from 'locked_out' then
    raise exception 'FAIL [J8] B, locked out, joining TA: % / "%" / detail %; expected detail locked_out (the lockout before the block).', coalesce(v_r[1], 'no error'), coalesce(v_r[2], v_r[5], ''), coalesce(v_r[3], '-');
  end if;
  delete from public.attempt_log where user_id = v_b and action = 'code_guess';
  v_checks := v_checks + 1;

  -- [J9] A seated player stays: S at TA2, then blocked by A.
  insert into public.blocks (blocker_id, blocked_id) values (v_a, v_s);
  v_r := pg_temp.m1_as('authenticated', v_s, format('select outcome || '':'' || coalesce(seat::text, ''-'') || '':'' || coalesce(host_nickname, ''-'') from public.join_table_by_code(%L, false, %L)', v_codes[3], v_ta2));
  v_r2 := pg_temp.m1_as('authenticated', v_s, format('select outcome from public.join_table_by_code(%L, true, %L)', v_codes[3], v_ta2));
  if v_r[1] is not null or v_r[5] not like 'already_seated:1:%' or v_r2[5] is distinct from 'already_seated'
     or not exists (select 1 from public.table_members tm where tm.table_id = v_ta2 and tm.user_id = v_s) then
    raise exception 'FAIL [J9] S, seated at TA2 and then blocked: join % (error %: %), preview %; expected already_seated (seat 1) twice and still seated.', v_r[5], coalesce(v_r[1], 'none'), coalesce(v_r[2], ''), coalesce(v_r2[5], v_r2[2]);
  end if;
  v_checks := v_checks + 1;

  -- [J10] A watcher stays: W watching TA, then blocked by A.
  insert into public.blocks (blocker_id, blocked_id) values (v_a, v_w);
  v_r := pg_temp.m1_as('authenticated', v_w, format('select table_id::text from public.watch_table(%L, %L)', v_codes[1], v_ta));
  v_r2 := pg_temp.m1_as('authenticated', v_w, format('select public.spectator_heartbeat(%L)', v_ta));
  if v_r[1] is not null or v_r[5] is distinct from v_ta::text or v_r2[5] is distinct from 'game_ended'
     or not exists (select 1 from public.table_spectators ts where ts.table_id = v_ta and ts.user_id = v_w and ts.removed_at is null) then
    raise exception 'FAIL [J10] W, watching TA and then blocked: watch % (error %: %), heartbeat %; expected TA''s id, game_ended, the row kept.', v_r[5], coalesce(v_r[1], 'none'), coalesce(v_r[2], ''), coalesce(v_r2[5], v_r2[2]);
  end if;
  v_checks := v_checks + 1;

  -- [J11] A removed watcher, then blocked, still hears they were removed.
  insert into public.blocks (blocker_id, blocked_id) values (v_a, v_rm);
  v_r := pg_temp.m1_as('authenticated', v_rm, format('select table_id::text from public.watch_table(%L, %L)', v_codes[1], v_ta));
  if v_r[2] is distinct from 'You were removed from watching this table.' then
    raise exception 'FAIL [J11] R, removed and then blocked: % / "%"; expected "You were removed from watching this table.".', coalesce(v_r[1], 'no error'), coalesce(v_r[2], v_r[5], '');
  end if;
  v_checks := v_checks + 1;

  -- [J12] Someone else's table: B watches TC, then joins it.
  v_r := pg_temp.m1_as('authenticated', v_b, format('select table_id::text from public.watch_table(%L, %L)', v_codes[4], v_tc));
  v_r2 := pg_temp.m1_as('authenticated', v_b, format('select outcome from public.join_table_by_code(%L, false, %L)', v_codes[4], v_tc));
  if v_r[5] is distinct from v_tc::text or v_r2[5] is distinct from 'joined' then
    raise exception 'FAIL [J12] B at C''s TC: watch % (error %), join % (error %); expected TC''s id and joined.', coalesce(v_r[5], 'no row'), coalesce(v_r[2], 'none'), coalesce(v_r2[5], '-'), coalesce(v_r2[2], 'none');
  end if;
  -- B leaves TC (as the owner; C is still seated, so TC stays open).
  delete from public.table_members where table_id = v_tc and user_id = v_b;
  v_checks := v_checks + 1;

  -- [J13] The blocker joins the blocked person's table.
  v_r := pg_temp.m1_as('authenticated', v_k, format('select public.block_player(%L)', 'm1' || left(replace(v_b::text, '-', ''), 12)));
  v_r2 := pg_temp.m1_as('authenticated', v_k, format('select outcome from public.join_table_by_code(%L, false, %L)', v_codes[5], v_tb));
  if v_r[5] is distinct from 'blocked' or v_r2[5] is distinct from 'joined' then
    raise exception 'FAIL [J13] K blocks B (%), then joins B''s TB: % (error %); expected blocked and joined.', coalesce(v_r[5], v_r[2]), coalesce(v_r2[5], '-'), coalesce(v_r2[2], 'none');
  end if;
  v_checks := v_checks + 1;

  -- [J14] Unblocked, B previews, watches and joins TA normally.
  v_txt := (pg_temp.m1_as('authenticated', v_a, format('select public.unblock_player(%L)', v_b)))[5];
  v_r := pg_temp.m1_as('authenticated', v_b, format('select outcome || '':'' || coalesce(host_nickname, ''-'') from public.join_table_by_code(%L, true, %L)', v_codes[1], v_ta));
  v_r2 := pg_temp.m1_as('authenticated', v_b, format('select table_id::text from public.watch_table(%L, %L)', v_codes[1], v_ta));
  v_full := pg_temp.m1_as('authenticated', v_b, format('select outcome from public.join_table_by_code(%L, false, %L)', v_codes[1], v_ta));
  if v_txt is distinct from 'unblocked'
     or v_r[5] is distinct from 'preview:m1' || left(replace(v_a::text, '-', ''), 12)
     or v_r2[5] is distinct from v_ta::text
     or v_full[5] is distinct from 'joined'
     or not exists (select 1 from public.table_members tm where tm.table_id = v_ta and tm.user_id = v_b) then
    raise exception 'FAIL [J14] after A unblocks B (%): preview % (error %), watch % (error %), join % (error %); expected preview with A''s nickname, TA''s id, joined.',
      v_txt, coalesce(v_r[5], '-'), coalesce(v_r[2], 'none'), coalesce(v_r2[5], '-'), coalesce(v_r2[2], 'none'), coalesce(v_full[5], '-'), coalesce(v_full[2], 'none');
  end if;
  v_checks := v_checks + 1;

  if v_checks <> 34 then
    raise exception 'FAIL: % checks ran, expected 34.', v_checks;
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back).', v_checks;
end;
$$;
