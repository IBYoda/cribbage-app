-- Computer opponent, C2: VERIFICATION.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER
-- docs/sql/computer-c2-engine.sql (C1 must be applied too). The whole file is
-- ONE DO block: run it as is.
--
-- It WRITES -- tables, seats, games, hands, plays, scores, as real players --
-- and then deliberately raises an exception at the very end, which rolls
-- every write back. It always "fails": the message is the verdict.
-- "ALL n CHECKS PASSED (rolled back) ..." is a pass; anything starting
-- "FAIL" or "SETUP" is not. Re-runnable, because nothing it does survives.
--
-- Same impersonation as the earlier verification scripts:
-- request.jwt.claims plus "set local role authenticated" (or anon) to act as
-- a client, and "reset role" to act as the owner between steps.
--
-- PLAYERS: A, B and C are the three OLDEST accounts that are neither admins
-- nor already computer accounts. For this run only, C is made THE computer:
-- computer_accounts is emptied and given one row, ('easy', C), so 'medium'
-- and 'hard' are deliberately missing. (Rolled back like everything else:
-- the real computer accounts, if set up already, are untouched afterwards.)
-- A is the human who creates the computer tables; B is another human; a
-- "stranger" is a random id that is no account at all.
--
-- THE CARDS are dealt at random, so the hand below is played by choosing,
-- at each turn, the first legal card of the player whose turn it is (as the
-- owner reads the hands) -- the computer's through the computer_* wrappers,
-- A's through A's own functions, all called as A.
--
-- THE FROZEN now(): a DO block is one transaction, so now() is one instant.
-- start_game_with_deal finds "the previous match" by created_at, so the
-- placeholder games made here are dated an hour back, and only games the
-- functions themselves create carry now().
--
-- WHAT IT CHECKS
--   S  catalog: computer_accounts has RLS on, no policies, and no privilege
--      for PUBLIC, anon or authenticated (table or column); computer_level
--      is a nullable text column whose check refuses other values; the
--      eleven public functions exist, run as definer with search_path
--      public, are executable by authenticated and not by anon; the two
--      helpers and the eight _as functions are executable by neither; as
--      authenticated and as anon, reading computer_accounts or calling a
--      helper or an _as function is refused (42501).
--   T  create_computer_table: seats A in 1 and the computer in 2 on a
--      private, regular, 2-player table with computer_level; refuses a bad
--      level, a level with no account, a code collision (23505, as a direct
--      insert), anon, the computer itself, and no caller; the computer sits
--      at two tables at once.
--   G  the guard, through computer_start_game_with_deal (table id) AND
--      computer_hand (game id): refused for the computer itself (a seated
--      non-creator), a non-member, a stranger, a normal 2-player table, a 3-
--      and a 4-player table, a table marked computer_level whose other
--      member is a human, a table with no other member, a creator who is not
--      seated, an unknown table or game, no caller, and anon.
--   W  a full hand through the wrappers, each acting ONLY as the computer:
--      the cut (one card for A, one for the computer), the acknowledgement,
--      computer_hand (only the computer's cards), the discard, pegging to
--      the end (every play recorded as the player whose turn it was),
--      show_crib by the dealer, every count, Next Hand (hand 2 dealt by the
--      other player); then a rematch after a won match (first tap waits,
--      the computer's tap deals, the loser deals, scores reset).
--   H  A's own functions never act for the computer: discarding the
--      computer's cards, playing on the computer's turn, confirming the
--      computer's count, showing a crib that is not A's.
--   L  leave_computer_table: refused for the computer, another human, anon,
--      no caller, a normal table and a table with a human seated; ends the
--      live game 'player_left', removes both seats and closes the table;
--      a repeat is quiet; it also cleans up a table the creator already
--      left.
--
-- Expected message:
--   ALL 81 CHECKS PASSED (rolled back). A=... B=... computer=...

do $$
declare
  v_a uuid;
  v_b uuid;
  v_c uuid;
  v_stranger uuid := gen_random_uuid();
  v_codes text[];
  v_ct uuid;
  v_ct2 uuid;
  v_norm uuid;
  v_t3 uuid;
  v_t4 uuid;
  v_fake uuid;
  v_alone uuid;
  v_gp uuid;
  v_gp2 uuid;
  v_g_norm uuid;
  v_g_t3 uuid;
  v_g_t4 uuid;
  v_g_fake uuid;
  v_g_alone uuid;
  v_g uuid;
  v_g2 uuid;
  v_ret uuid;
  v_ids uuid[];
  v_hand_a text[];
  v_hand_c text[];
  v_s1 text[];
  v_s2 text[];
  v_card text;
  v_txt text;
  v_msg text;
  v_msg2 text;
  v_state text;
  v_state2 text;
  v_status text;
  v_phase text;
  v_cp uuid;
  v_dealer uuid;
  v_dealer2 uuid;
  v_step int;
  v_count int;
  v_hand_no int;
  v_round int;
  v_i int;
  v_n int;
  v_n2 int;
  v_bool boolean;
  v_flag_h boolean;
  v_flag_c boolean;
  v_flag_s boolean;
  v_rec record;
  v_fn text;
  v_checks int := 0;
begin
  -- ---- Setup, as the owner ------------------------------------------------
  select u.id into v_a from auth.users u
  where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
    and not exists (select 1 from public.computer_accounts ca where ca.user_id = u.id)
  order by u.created_at limit 1;
  select u.id into v_b from auth.users u
  where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
    and not exists (select 1 from public.computer_accounts ca where ca.user_id = u.id)
  order by u.created_at offset 1 limit 1;
  select u.id into v_c from auth.users u
  where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
    and not exists (select 1 from public.computer_accounts ca where ca.user_id = u.id)
  order by u.created_at offset 2 limit 1;
  if v_a is null or v_b is null or v_c is null then
    raise exception 'SETUP: the project needs at least three accounts that are neither admins nor computer accounts.';
  end if;

  -- For this run, C is the computer ('easy'); 'medium' and 'hard' are absent.
  delete from public.computer_accounts;
  insert into public.computer_accounts (level, user_id) values ('easy', v_c);

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0'))
    order by n
    limit 8
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 8 then
    raise exception 'SETUP: fewer than eight unused table codes.';
  end if;

  -- Fixture tables (as the owner). Members are inserted one at a time so the
  -- seat trigger seats them in this order.
  insert into public.tables (code, created_by) values (v_codes[2], v_a) returning id into v_norm;
  insert into public.table_members (table_id, user_id) values (v_norm, v_a);
  insert into public.table_members (table_id, user_id) values (v_norm, v_b);

  insert into public.tables (code, created_by, max_players) values (v_codes[3], v_a, 3) returning id into v_t3;
  insert into public.table_members (table_id, user_id) values (v_t3, v_a);
  insert into public.table_members (table_id, user_id) values (v_t3, v_c);

  insert into public.tables (code, created_by, max_players) values (v_codes[4], v_a, 4) returning id into v_t4;
  insert into public.table_members (table_id, user_id) values (v_t4, v_a);
  insert into public.table_members (table_id, user_id) values (v_t4, v_c);

  insert into public.tables (code, created_by, computer_level) values (v_codes[5], v_a, 'easy') returning id into v_fake;
  insert into public.table_members (table_id, user_id) values (v_fake, v_a);
  insert into public.table_members (table_id, user_id) values (v_fake, v_b);

  insert into public.tables (code, created_by, computer_level) values (v_codes[6], v_a, 'easy') returning id into v_alone;
  insert into public.table_members (table_id, user_id) values (v_alone, v_a);

  -- A game at each, for the game-id guard (cutting, so each is "live").
  insert into public.games (table_id, created_by, status, players, deal_cut, created_at)
  values (v_norm, v_a, 'cutting', array[v_a, v_b], '[[]]'::jsonb, now() - interval '1 hour') returning id into v_g_norm;
  insert into public.games (table_id, created_by, status, players, deal_cut, created_at)
  values (v_t3, v_a, 'cutting', array[v_a, v_c], '[[]]'::jsonb, now() - interval '1 hour') returning id into v_g_t3;
  insert into public.games (table_id, created_by, status, players, deal_cut, created_at)
  values (v_t4, v_a, 'cutting', array[v_a, v_c], '[[]]'::jsonb, now() - interval '1 hour') returning id into v_g_t4;
  insert into public.games (table_id, created_by, status, players, deal_cut, created_at)
  values (v_fake, v_a, 'cutting', array[v_a, v_b], '[[]]'::jsonb, now() - interval '1 hour') returning id into v_g_fake;
  insert into public.games (table_id, created_by, status, players, deal_cut, created_at)
  values (v_alone, v_a, 'cutting', array[v_a], '[[]]'::jsonb, now() - interval '1 hour') returning id into v_g_alone;

  -- ==== S: catalog, as the owner ==============================================
  -- [S1] computer_accounts: RLS on, no policies.
  select c.relrowsecurity into v_bool from pg_class c where c.oid = 'public.computer_accounts'::regclass;
  select count(*) into v_n from pg_policies p where p.schemaname = 'public' and p.tablename = 'computer_accounts';
  if v_bool is distinct from true or v_n <> 0 then
    raise exception 'FAIL [S1] computer_accounts: RLS %, % policies; expected on and none.', v_bool, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [S2] No privilege on computer_accounts for PUBLIC, anon or authenticated:
  -- none in the table ACL, no column-level grants, and has_table_privilege
  -- false for every privilege.
  select count(*) into v_n
  from pg_class c,
       aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
  where c.oid = 'public.computer_accounts'::regclass
    and (a.grantee = 0 or a.grantee in (select r.oid from pg_roles r where r.rolname in ('anon', 'authenticated')));
  select count(*) into v_n2
  from pg_attribute at
  where at.attrelid = 'public.computer_accounts'::regclass
    and at.attnum > 0
    and at.attacl is not null;
  if v_n <> 0 or v_n2 <> 0
     or has_table_privilege('authenticated', 'public.computer_accounts', 'select, insert, update, delete, truncate, references, trigger')
     or has_table_privilege('anon', 'public.computer_accounts', 'select, insert, update, delete, truncate, references, trigger') then
    raise exception 'FAIL [S2] computer_accounts: % client grant(s), % column ACL(s); expected none.', v_n, v_n2;
  end if;
  v_checks := v_checks + 1;

  -- [S3] tables.computer_level: text, nullable, no default; the check refuses
  -- any other value (23514).
  select count(*) into v_n
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'tables' and c.column_name = 'computer_level'
    and c.data_type = 'text' and c.is_nullable = 'YES' and c.column_default is null;
  v_state := null;
  begin
    insert into public.tables (code, created_by, computer_level) values (v_codes[8], v_a, 'expert');
  exception when others then
    v_state := sqlstate;
  end;
  if v_n <> 1 or v_state is distinct from '23514' then
    raise exception 'FAIL [S3] tables.computer_level: column found %, bad value gave %; expected 1 and 23514.', v_n, coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [S4] The eleven public functions: exist, security definer, search_path
  -- public; authenticated can execute, anon cannot (has_function_privilege
  -- counts PUBLIC grants too).
  foreach v_fn in array array[
    'public.computer_start_game_with_deal(uuid)',
    'public.computer_draw_cut_card(uuid)',
    'public.computer_acknowledge_deal_cut(uuid)',
    'public.computer_discard_to_crib(uuid, text[])',
    'public.computer_play_card(uuid, text)',
    'public.computer_show_crib(uuid)',
    'public.computer_confirm_count(uuid, int)',
    'public.computer_next_hand(uuid, int)',
    'public.computer_hand(uuid)',
    'public.create_computer_table(text, text)',
    'public.leave_computer_table(uuid)'
  ] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL [S4] % is missing.', v_fn;
    end if;
    select count(*) into v_n from pg_proc p
    where p.oid = to_regprocedure(v_fn) and p.prosecdef and p.proconfig = array['search_path=public'];
    if v_n <> 1 then
      raise exception 'FAIL [S4] % is not security definer with search_path=public.', v_fn;
    end if;
    if not has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'FAIL [S4] authenticated cannot execute %.', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'FAIL [S4] anon CAN execute %.', v_fn;
    end if;
    v_checks := v_checks + 1;
  end loop;

  -- [S5] The helpers and the eight _as functions: executable by neither
  -- authenticated nor anon.
  foreach v_fn in array array[
    'public._computer_for_table(uuid)',
    'public._computer_for_game(uuid)',
    'public.start_game_with_deal_as(uuid, uuid)',
    'public.draw_cut_card_as(uuid, uuid)',
    'public.acknowledge_deal_cut_as(uuid, uuid)',
    'public.discard_to_crib_as(uuid, uuid, text[])',
    'public.play_card_as(uuid, uuid, text)',
    'public.show_crib_as(uuid, uuid)',
    'public.confirm_count_as(uuid, uuid, int)',
    'public.next_hand_as(uuid, uuid, int)'
  ] loop
    if to_regprocedure(v_fn) is null then
      raise exception 'FAIL [S5] % is missing.', v_fn;
    end if;
    if has_function_privilege('authenticated', v_fn, 'execute') or has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'FAIL [S5] a client role can execute %.', v_fn;
    end if;
    v_checks := v_checks + 1;
  end loop;

  -- [S6] As authenticated (A): reading computer_accounts, calling a helper,
  -- and calling an _as function are all refused (42501).
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_state := null;
  begin perform 1 from public.computer_accounts; exception when others then v_state := sqlstate; end;
  v_state2 := null;
  begin perform public._computer_for_table(v_norm); exception when others then v_state2 := sqlstate; end;
  v_txt := null;
  begin perform public.play_card_as(v_c, v_g_norm, 'AS'); exception when others then v_txt := sqlstate; end;
  execute 'reset role';
  if v_state is distinct from '42501' or v_state2 is distinct from '42501' or v_txt is distinct from '42501' then
    raise exception 'FAIL [S6] authenticated: computer_accounts %, helper %, _as %; expected 42501 each.',
      coalesce(v_state, 'no error'), coalesce(v_state2, 'no error'), coalesce(v_txt, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [S7] As anon: the same three, plus an act-as wrapper (42501 each).
  execute 'set local role anon';
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  v_state := null;
  begin perform 1 from public.computer_accounts; exception when others then v_state := sqlstate; end;
  v_state2 := null;
  begin perform public._computer_for_game(v_g_norm); exception when others then v_state2 := sqlstate; end;
  v_txt := null;
  begin perform public.next_hand_as(v_c, v_g_norm, 1); exception when others then v_txt := sqlstate; end;
  v_msg := null;
  begin perform public.computer_draw_cut_card(v_g_norm); exception when others then v_msg := sqlstate; end;
  execute 'reset role';
  if v_state is distinct from '42501' or v_state2 is distinct from '42501'
     or v_txt is distinct from '42501' or v_msg is distinct from '42501' then
    raise exception 'FAIL [S7] anon: computer_accounts %, helper %, _as %, wrapper %; expected 42501 each.',
      coalesce(v_state, 'no error'), coalesce(v_state2, 'no error'), coalesce(v_txt, 'no error'), coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- ==== T: create_computer_table ==============================================
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);

  -- [T1] A makes an 'easy' table: seats A in 1 and the computer in 2.
  execute 'set local role authenticated';
  select r.table_id, r.code into v_ct, v_txt from public.create_computer_table('easy', v_codes[1]) r;
  execute 'reset role';
  select count(*) into v_n from public.tables t
  where t.id = v_ct and t.code = v_codes[1] and t.created_by = v_a and t.status = 'open'
    and t.is_public = false and t.is_muggins = false and t.max_players = 2 and t.computer_level = 'easy';
  select array_agg(tm.user_id order by tm.seat) into v_ids from public.table_members tm where tm.table_id = v_ct;
  select array_agg(tm.seat order by tm.seat)::text into v_msg from public.table_members tm where tm.table_id = v_ct;
  if v_ct is null or v_txt is distinct from v_codes[1] or v_n <> 1
     or v_ids is distinct from array[v_a, v_c] or v_msg is distinct from '{1,2}' then
    raise exception 'FAIL [T1] create_computer_table: returned (%, %), table match %, seats % %; expected A in 1, computer in 2.',
      v_ct, v_txt, v_n, v_ids, v_msg;
  end if;
  v_checks := v_checks + 1;

  -- [T2] A bad level, and no level: refused.
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.create_computer_table('expert', v_codes[8]); exception when others then v_msg := sqlerrm; end;
  v_msg2 := null;
  begin perform public.create_computer_table(null, v_codes[8]); exception when others then v_msg2 := sqlerrm; end;
  execute 'reset role';
  if v_msg is null or v_msg not like 'Unknown computer level "expert"%'
     or v_msg2 is null or v_msg2 not like 'Unknown computer level%' then
    raise exception 'FAIL [T2] bad level: % / no level: %; expected refusals.', coalesce(v_msg, 'no error'), coalesce(v_msg2, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [T3] A level with no computer account ('medium'): refused.
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.create_computer_table('medium', v_codes[8]); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'The medium computer is not set up yet.' then
    raise exception 'FAIL [T3] missing account: %; expected "The medium computer is not set up yet."', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [T4] A code collision: unique_violation (23505), as a direct insert.
  execute 'set local role authenticated';
  v_state := null;
  begin perform public.create_computer_table('easy', v_codes[1]); exception when others then v_state := sqlstate; end;
  execute 'reset role';
  if v_state is distinct from '23505' then
    raise exception 'FAIL [T4] code collision: %; expected 23505.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [T5] The computer account itself cannot make one.
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.create_computer_table('easy', v_codes[8]); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'A computer account cannot start a computer table.' then
    raise exception 'FAIL [T5] the computer making a table: %; expected a refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [T6] No caller: refused.
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.create_computer_table('easy', v_codes[8]); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'You must be logged in to start a table.' then
    raise exception 'FAIL [T6] no caller: %; expected the log-in refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [T7] anon: 42501.
  execute 'set local role anon';
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  v_state := null;
  begin perform public.create_computer_table('easy', v_codes[8]); exception when others then v_state := sqlstate; end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [T7] anon create_computer_table: %; expected 42501.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [T8] A second computer table: the same computer sits at both at once.
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  execute 'set local role authenticated';
  select r.table_id into v_ct2 from public.create_computer_table('easy', v_codes[7]) r;
  execute 'reset role';
  select count(*) into v_n from public.table_members tm
  where tm.user_id = v_c and tm.seat = 2 and tm.table_id in (v_ct, v_ct2);
  if v_ct2 is null or v_n <> 2 then
    raise exception 'FAIL [T8] second computer table %: the computer holds seat 2 at % of the two.', v_ct2, v_n;
  end if;
  v_checks := v_checks + 1;

  -- Placeholder ENDED games at the two computer tables, dated an hour back,
  -- for the game-id guard (an ended game blocks nothing).
  insert into public.games (table_id, created_by, status, ended_reason, players, created_at)
  values (v_ct, v_a, 'ended', 'admin', array[v_a, v_c], now() - interval '1 hour') returning id into v_gp;
  insert into public.games (table_id, created_by, status, ended_reason, players, created_at)
  values (v_ct2, v_a, 'ended', 'admin', array[v_a, v_c], now() - interval '1 hour') returning id into v_gp2;
  -- The creator no longer seated at the second table (the computer still is).
  delete from public.table_members where table_id = v_ct2 and user_id = v_a;

  -- ==== G: the guard ==========================================================
  -- Each case through BOTH the table-id guard (computer_start_game_with_deal)
  -- and the game-id guard (computer_hand): two checks per case.
  for v_rec in
    select * from (values
      ('the computer itself (seated, not the creator)', v_c, v_ct, v_gp, 'Only the player who created this table can act for its computer.'),
      ('a non-member (B)', v_b, v_ct, v_gp, 'Only the player who created this table can act for its computer.'),
      ('a stranger', v_stranger, v_ct, v_gp, 'Only the player who created this table can act for its computer.'),
      ('a normal 2-player table', v_a, v_norm, v_g_norm, 'The other player at this table is not a computer.'),
      ('a 3-player table', v_a, v_t3, v_g_t3, 'Only a 2-player table can have a computer opponent.'),
      ('a 4-player table', v_a, v_t4, v_g_t4, 'Only a 2-player table can have a computer opponent.'),
      ('computer_level set, the other member a human', v_a, v_fake, v_g_fake, 'The other player at this table is not a computer.'),
      ('no other member', v_a, v_alone, v_g_alone, 'A computer table has exactly one other player, the computer.'),
      ('the creator, no longer seated', v_a, v_ct2, v_gp2, 'You are not seated at this table.')
    ) as t(label, actor, tbl, game, expect)
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_rec.actor, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_rec.actor::text, true);
    execute 'set local role authenticated';
    v_msg := null;
    begin perform public.computer_start_game_with_deal(v_rec.tbl); exception when others then v_msg := sqlerrm; end;
    v_msg2 := null;
    begin perform 1 from public.computer_hand(v_rec.game); exception when others then v_msg2 := sqlerrm; end;
    execute 'reset role';
    if v_msg is distinct from v_rec.expect then
      raise exception 'FAIL [G] % (table guard): %; expected "%".', v_rec.label, coalesce(v_msg, 'no error'), v_rec.expect;
    end if;
    v_checks := v_checks + 1;
    if v_msg2 is distinct from v_rec.expect then
      raise exception 'FAIL [G] % (game guard): %; expected "%".', v_rec.label, coalesce(v_msg2, 'no error'), v_rec.expect;
    end if;
    v_checks := v_checks + 1;
  end loop;

  -- [G10] An unknown table and an unknown game.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.computer_start_game_with_deal(gen_random_uuid()); exception when others then v_msg := sqlerrm; end;
  v_msg2 := null;
  begin perform 1 from public.computer_hand(gen_random_uuid()); exception when others then v_msg2 := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'Table not found.' or v_msg2 is distinct from 'Game not found.' then
    raise exception 'FAIL [G10] unknown table: % / unknown game: %.', coalesce(v_msg, 'no error'), coalesce(v_msg2, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [G11] No caller: refused by both guards.
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.computer_start_game_with_deal(v_ct); exception when others then v_msg := sqlerrm; end;
  v_msg2 := null;
  begin perform 1 from public.computer_hand(v_gp); exception when others then v_msg2 := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'You must be logged in to act for the computer.'
     or v_msg2 is distinct from 'You must be logged in to act for the computer.' then
    raise exception 'FAIL [G11] no caller: % / %.', coalesce(v_msg, 'no error'), coalesce(v_msg2, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [G12] anon: 42501 from both.
  execute 'set local role anon';
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  v_state := null;
  begin perform public.computer_start_game_with_deal(v_ct); exception when others then v_state := sqlstate; end;
  v_state2 := null;
  begin perform 1 from public.computer_hand(v_gp); exception when others then v_state2 := sqlstate; end;
  execute 'reset role';
  if v_state is distinct from '42501' or v_state2 is distinct from '42501' then
    raise exception 'FAIL [G12] anon: % / %; expected 42501.', coalesce(v_state, 'no error'), coalesce(v_state2, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- No game started anywhere by the refusals above.
  select count(*) into v_n from public.games g where g.table_id = v_ct and g.status in ('cutting', 'active');
  if v_n <> 0 then
    raise exception 'FAIL [G13] a refused call left % live game(s) at the computer table.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- ==== W and H: a full hand, everything called AS A ===========================
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);

  -- [W1] A starts the first game with A's own function: a cut.
  execute 'set local role authenticated';
  v_g := public.start_game_with_deal(v_ct);
  execute 'reset role';
  select g.status, g.players into v_status, v_ids from public.games g where g.id = v_g;
  if v_g is null or v_status is distinct from 'cutting' or v_ids is distinct from array[v_a, v_c] then
    raise exception 'FAIL [W1] first game: %, status %, players %; expected a cut for A and the computer.', v_g, v_status, v_ids;
  end if;
  v_checks := v_checks + 1;

  -- The cut, round by round until one is decisive.
  v_round := 0;
  loop
    v_round := v_round + 1;
    if v_round > 12 then
      raise exception 'FAIL [W2] no decisive cut in 12 rounds.';
    end if;

    execute 'set local role authenticated';
    perform public.draw_cut_card(v_g);
    perform public.computer_draw_cut_card(v_g);
    execute 'reset role';

    if v_round = 1 then
      -- [W2] The round holds one card for A and one for the computer -- the
      -- wrapper cut as the computer, not as A.
      select array_agg((e ->> 'user_id')::uuid order by (e ->> 'user_id'))
      into v_ids
      from public.games g,
           jsonb_array_elements(g.deal_cut -> (jsonb_array_length(g.deal_cut) - 1)) e
      where g.id = v_g;
      if v_ids is distinct from (select array_agg(u order by u::text) from unnest(array[v_a, v_c]) u) then
        raise exception 'FAIL [W2] the first cut round holds %; expected one card each for A and the computer.', v_ids;
      end if;
      v_checks := v_checks + 1;
    end if;

    execute 'set local role authenticated';
    perform public.acknowledge_deal_cut(v_g);
    execute 'reset role';

    if v_round = 1 then
      -- [W3] After A's acknowledgement only A has acknowledged.
      select g.deal_cut_ack_by into v_ids from public.games g where g.id = v_g;
      if v_ids is distinct from array[v_a] then
        raise exception 'FAIL [W3] after A''s acknowledgement: %; expected just A.', v_ids;
      end if;
      v_checks := v_checks + 1;
    end if;

    execute 'set local role authenticated';
    perform public.computer_acknowledge_deal_cut(v_g);
    execute 'reset role';

    select g.status into v_status from public.games g where g.id = v_g;
    exit when v_status = 'active';
  end loop;

  -- [W4] The computer's acknowledgement completed the cut: active, a dealer,
  -- two hands of six, discard phase.
  select g.dealer_id, g.phase into v_dealer, v_phase from public.games g where g.id = v_g;
  select count(*), min(array_length(gh.cards, 1)), max(array_length(gh.cards, 1))
  into v_n, v_n2, v_i
  from public.game_hands gh where gh.game_id = v_g and gh.user_id in (v_a, v_c);
  if v_dealer is null or v_dealer not in (v_a, v_c) or v_phase is distinct from 'discard'
     or v_n <> 2 or v_n2 <> 6 or v_i <> 6 then
    raise exception 'FAIL [W4] after the cut: dealer %, phase %, % hands of % to % cards.', v_dealer, v_phase, v_n, v_n2, v_i;
  end if;
  v_checks := v_checks + 1;

  -- [W5] computer_hand, as A: exactly one row -- the computer's -- with the
  -- computer's real cards; A's hand is not in it.
  select gh.cards into v_hand_a from public.game_hands gh where gh.game_id = v_g and gh.user_id = v_a;
  select gh.cards into v_s1 from public.game_hands gh where gh.game_id = v_g and gh.user_id = v_c;
  execute 'set local role authenticated';
  select count(*), min(h.user_id::text) into v_n, v_txt from public.computer_hand(v_g) h;
  select h.cards into v_hand_c from public.computer_hand(v_g) h;
  execute 'reset role';
  if v_n <> 1 or v_txt is distinct from v_c::text or v_hand_c is distinct from v_s1 then
    raise exception 'FAIL [W5] computer_hand: % row(s), user %, cards %; expected the computer''s one row %.', v_n, v_txt, v_hand_c, v_s1;
  end if;
  v_checks := v_checks + 1;

  -- [H1] A's own discard cannot discard the computer's cards.
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.discard_to_crib(v_g, v_hand_c[1:2]); exception when others then v_msg := sqlerrm; end;
  -- [W6] The computer's discard cannot take A's cards (it acts as the computer).
  v_msg2 := null;
  begin perform public.computer_discard_to_crib(v_g, v_hand_a[1:2]); exception when others then v_msg2 := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'You can only discard cards from your own hand.' then
    raise exception 'FAIL [H1] A discarding the computer''s cards: %; expected a refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;
  if v_msg2 is distinct from 'You can only discard cards from your own hand.' then
    raise exception 'FAIL [W6] the computer discarding A''s cards: %; expected a refusal.', coalesce(v_msg2, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- The discards: A's own, then the computer's through the wrapper.
  execute 'set local role authenticated';
  perform public.discard_to_crib(v_g, v_hand_a[1:2]);
  perform public.computer_discard_to_crib(v_g, v_hand_c[1:2]);
  execute 'reset role';

  -- [W7] Both discarded; each keeps exactly its own other four; the crib
  -- holds four; the starter is cut; play has begun.
  select array_agg(x order by x) into v_s1 from unnest(v_hand_c[3:6]) x;
  select array_agg(x order by x) into v_s2
  from unnest((select gh.cards from public.game_hands gh where gh.game_id = v_g and gh.user_id = v_c)) x;
  select g.phase, coalesce(array_length(g.discarded_by, 1), 0) into v_phase, v_n from public.games g where g.id = v_g;
  select coalesce(array_length(gc.cards, 1), 0) into v_n2 from public.game_cribs gc where gc.game_id = v_g;
  if v_s1 is distinct from v_s2 or v_phase is distinct from 'play' or v_n <> 2 or v_n2 <> 4
     or (select g.starter_card from public.games g where g.id = v_g) is null
     or not exists (select 1 from public.games g where g.id = v_g and v_c = any(g.discarded_by)) then
    raise exception 'FAIL [W7] after the discards: computer keeps % (expected %), phase %, % discarded, crib %.', v_s2, v_s1, v_phase, v_n, v_n2;
  end if;
  select array_agg(x order by x) into v_s1 from unnest(v_hand_a[3:6]) x;
  select array_agg(x order by x) into v_s2
  from unnest((select gh.cards from public.game_hands gh where gh.game_id = v_g and gh.user_id = v_a)) x;
  if v_s1 is distinct from v_s2 then
    raise exception 'FAIL [W7] A keeps %, expected %.', v_s2, v_s1;
  end if;
  v_checks := v_checks + 1;

  -- Pegging, to the end. At each turn: the first legal card of the player
  -- whose turn it is (read as the owner); the computer's through the wrapper.
  v_flag_h := false;
  v_flag_c := false;
  v_i := 0;
  loop
    select g.phase, g.current_player, g.play_count into v_phase, v_cp, v_count from public.games g where g.id = v_g;
    exit when v_phase is distinct from 'play';
    v_i := v_i + 1;
    if v_i > 12 then
      raise exception 'FAIL [W8] pegging did not finish in 12 plays.';
    end if;

    select c into v_card
    from unnest((select gh.cards from public.game_hands gh where gh.game_id = v_g and gh.user_id = v_cp)) as c
    where not exists (
            select 1 from public.game_plays gp
            where gp.game_id = v_g and gp.user_id = v_cp and gp.kind = 'play' and gp.card = c)
      and public.card_play_value(c) + v_count <= 31
    order by c
    limit 1;
    if v_card is null then
      raise exception 'FAIL [W8] the player whose turn it is (%) has no legal card at count %.', v_cp, v_count;
    end if;

    execute 'set local role authenticated';
    if v_cp = v_c then
      if not v_flag_h then
        -- [H2] A's own play_card on the computer's turn: refused.
        v_msg := null;
        begin perform public.play_card(v_g, v_card); exception when others then v_msg := sqlerrm; end;
        if v_msg is distinct from 'It is not your turn.' then
          execute 'reset role';
          raise exception 'FAIL [H2] A playing on the computer''s turn: %; expected "It is not your turn."', coalesce(v_msg, 'no error');
        end if;
        v_checks := v_checks + 1;
        v_flag_h := true;
      end if;
      perform public.computer_play_card(v_g, v_card);
    else
      if not v_flag_c then
        -- [W9] The computer's play on A's turn: refused (it acts as the computer).
        v_msg := null;
        begin perform public.computer_play_card(v_g, v_card); exception when others then v_msg := sqlerrm; end;
        if v_msg is distinct from 'It is not your turn.' then
          execute 'reset role';
          raise exception 'FAIL [W9] the computer playing on A''s turn: %; expected "It is not your turn."', coalesce(v_msg, 'no error');
        end if;
        v_checks := v_checks + 1;
        v_flag_c := true;
      end if;
      perform public.play_card(v_g, v_card);
    end if;
    execute 'reset role';

    -- Every play is recorded as the player whose turn it was.
    select gp.user_id, gp.card into v_ret, v_txt
    from public.game_plays gp
    where gp.game_id = v_g and gp.kind = 'play'
    order by gp.seq desc
    limit 1;
    if v_ret is distinct from v_cp or v_txt is distinct from v_card then
      raise exception 'FAIL [W8] play % recorded as % playing %; expected % playing %.', v_i, v_ret, v_txt, v_cp, v_card;
    end if;
  end loop;

  -- [W8] Pegging finished: eight plays, four by each, then counting.
  select count(*) filter (where gp.user_id = v_a), count(*) filter (where gp.user_id = v_c)
  into v_n, v_n2
  from public.game_plays gp where gp.game_id = v_g and gp.kind = 'play';
  if v_phase is distinct from 'counting' or v_n <> 4 or v_n2 <> 4 or not v_flag_h or not v_flag_c then
    raise exception 'FAIL [W8] after pegging: phase %, plays A % / computer %, both turns tested % %.', v_phase, v_n, v_n2, v_flag_h, v_flag_c;
  end if;
  v_checks := v_checks + 1;

  -- Counting, step by step: show_crib by the dealer at the crib's step, each
  -- count by the player whose count it is.
  v_flag_h := false;
  v_flag_c := false;
  v_flag_s := false;
  v_i := 0;
  loop
    select g.phase, g.count_step, g.current_player, g.dealer_id
    into v_phase, v_step, v_cp, v_dealer
    from public.games g where g.id = v_g;
    exit when v_phase is distinct from 'counting';
    v_i := v_i + 1;
    if v_i > 6 then
      raise exception 'FAIL [W12] counting did not finish in 6 steps.';
    end if;

    execute 'set local role authenticated';
    if v_step = 2 then
      if not v_flag_s then
        -- [W10] Whoever is NOT the dealer cannot show the crib: A's own
        -- show_crib when the computer deals, the wrapper when A deals.
        v_msg := null;
        if v_dealer = v_c then
          begin perform public.show_crib(v_g); exception when others then v_msg := sqlerrm; end;
        else
          begin perform public.computer_show_crib(v_g); exception when others then v_msg := sqlerrm; end;
        end if;
        if v_msg is distinct from 'Only the dealer can show the crib.' then
          execute 'reset role';
          raise exception 'FAIL [W10] the non-dealer showing the crib: %; expected a refusal.', coalesce(v_msg, 'no error');
        end if;
        v_checks := v_checks + 1;
        v_flag_s := true;
      end if;
      if v_dealer = v_c then
        perform public.computer_show_crib(v_g);
      else
        perform public.show_crib(v_g);
      end if;
    end if;

    if v_cp = v_c then
      if not v_flag_h then
        -- [H3] A's own confirm_count on the computer's count: refused.
        v_msg := null;
        begin perform public.confirm_count(v_g, v_step); exception when others then v_msg := sqlerrm; end;
        if v_msg is distinct from 'It is not your turn to count.' then
          execute 'reset role';
          raise exception 'FAIL [H3] A confirming the computer''s count: %; expected a refusal.', coalesce(v_msg, 'no error');
        end if;
        v_checks := v_checks + 1;
        v_flag_h := true;
      end if;
      perform public.computer_confirm_count(v_g, v_step);
    else
      if not v_flag_c then
        -- [W11] The computer's confirm on A's count: refused.
        v_msg := null;
        begin perform public.computer_confirm_count(v_g, v_step); exception when others then v_msg := sqlerrm; end;
        if v_msg is distinct from 'It is not your turn to count.' then
          execute 'reset role';
          raise exception 'FAIL [W11] the computer confirming A''s count: %; expected a refusal.', coalesce(v_msg, 'no error');
        end if;
        v_checks := v_checks + 1;
        v_flag_c := true;
      end if;
      perform public.confirm_count(v_g, v_step);
    end if;
    execute 'reset role';
  end loop;

  -- [W12] Counting done: phase 'done', the crib shown, both hands shown.
  select g.phase, g.crib_revealed, g.hand_no, g.dealer_id into v_phase, v_bool, v_hand_no, v_dealer
  from public.games g where g.id = v_g;
  if v_phase is distinct from 'done' or v_bool is distinct from true
     or not (select array[v_a, v_c] <@ g.revealed_by from public.games g where g.id = v_g)
     or not v_flag_h or not v_flag_c or not v_flag_s then
    raise exception 'FAIL [W12] after counting: phase %, crib shown %, checks run % % %.', v_phase, v_bool, v_flag_h, v_flag_c, v_flag_s;
  end if;
  v_checks := v_checks + 1;

  -- [W13] Next Hand: A taps (own function) -- only A is ready.
  execute 'set local role authenticated';
  perform public.next_hand(v_g, v_hand_no);
  execute 'reset role';
  select g.ready_by, g.phase into v_ids, v_phase from public.games g where g.id = v_g;
  if v_ids is distinct from array[v_a] or v_phase is distinct from 'done' then
    raise exception 'FAIL [W13] after A''s Next Hand: ready %, phase %; expected just A, still done.', v_ids, v_phase;
  end if;
  v_checks := v_checks + 1;

  -- [W14] The computer taps through the wrapper: hand 2 is dealt by the
  -- other player, ready_by is cleared, two hands of six.
  execute 'set local role authenticated';
  perform public.computer_next_hand(v_g, v_hand_no);
  execute 'reset role';
  select g.hand_no, g.phase, g.dealer_id, coalesce(array_length(g.ready_by, 1), 0)
  into v_n, v_phase, v_dealer2, v_n2
  from public.games g where g.id = v_g;
  select count(*) into v_i from public.game_hands gh
  where gh.game_id = v_g and gh.user_id in (v_a, v_c) and array_length(gh.cards, 1) = 6;
  if v_n is distinct from v_hand_no + 1 or v_phase is distinct from 'discard' or v_n2 <> 0
     or v_dealer2 is null or v_dealer2 = v_dealer or v_i <> 2 then
    raise exception 'FAIL [W14] after the computer''s Next Hand: hand %, phase %, dealer % (was %), % ready, % full hands.',
      v_n, v_phase, v_dealer2, v_dealer, v_n2, v_i;
  end if;
  v_checks := v_checks + 1;

  -- The match ends: A wins (as the owner, the way a win ends a game), with
  -- a score to show the rematch resets it.
  update public.games
  set status = 'ended', ended_reason = 'won', winner_id = v_a, current_player = null
  where id = v_g;
  update public.table_members set score = 121 where table_id = v_ct and user_id = v_a;

  -- [W15] Rematch, first tap -- A's own New Game: waits (null), A recorded.
  execute 'set local role authenticated';
  v_ret := public.start_game_with_deal(v_ct);
  execute 'reset role';
  select g.ready_by into v_ids from public.games g where g.id = v_g;
  if v_ret is not null or v_ids is distinct from array[v_a] then
    raise exception 'FAIL [W15] first New Game tap: returned %, ready %; expected null and just A.', v_ret, v_ids;
  end if;
  v_checks := v_checks + 1;

  -- [W16] The computer's tap through the wrapper deals the rematch: a new
  -- active game, the loser (the computer) deals, no cut, two hands of six,
  -- both recorded ready on the won game, scores reset.
  execute 'set local role authenticated';
  v_g2 := public.computer_start_game_with_deal(v_ct);
  execute 'reset role';
  select g.status, g.dealer_id, g.players into v_status, v_dealer, v_ids from public.games g where g.id = v_g2;
  select count(*) into v_i from public.game_hands gh
  where gh.game_id = v_g2 and array_length(gh.cards, 1) = 6;
  select coalesce(sum(tm.score), -1) into v_n from public.table_members tm where tm.table_id = v_ct;
  if v_g2 is null or v_status is distinct from 'active' or v_dealer is distinct from v_c
     or v_ids is distinct from array[v_a, v_c] or v_i <> 2 or v_n <> 0
     or not (select array[v_a, v_c] <@ g.ready_by from public.games g where g.id = v_g) then
    raise exception 'FAIL [W16] rematch: game %, status %, dealer % (expected the computer), players %, % hands, score total %.',
      v_g2, v_status, v_dealer, v_ids, v_i, v_n;
  end if;
  v_checks := v_checks + 1;

  -- ==== L: leave_computer_table ===============================================
  -- [L1] The computer, B, and no caller cannot.
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_c::text, true);
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.leave_computer_table(v_ct); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  execute 'set local role authenticated';
  v_msg2 := null;
  begin perform public.leave_computer_table(v_ct); exception when others then v_msg2 := sqlerrm; end;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role authenticated';
  v_txt := null;
  begin perform public.leave_computer_table(v_ct); exception when others then v_txt := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'Only the player who created this computer table can leave it this way.'
     or v_msg2 is distinct from 'Only the player who created this computer table can leave it this way.'
     or v_txt is distinct from 'You must be logged in to leave a table.' then
    raise exception 'FAIL [L1] the computer: % / B: % / no caller: %.', coalesce(v_msg, 'no error'), coalesce(v_msg2, 'no error'), coalesce(v_txt, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [L2] anon: 42501.
  execute 'set local role anon';
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  v_state := null;
  begin perform public.leave_computer_table(v_ct); exception when others then v_state := sqlstate; end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [L2] anon leave_computer_table: %; expected 42501.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [L3] A, on a normal table and on a table with a human seated: refused.
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.leave_computer_table(v_norm); exception when others then v_msg := sqlerrm; end;
  v_msg2 := null;
  begin perform public.leave_computer_table(v_fake); exception when others then v_msg2 := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'Only the player who created this computer table can leave it this way.'
     or v_msg2 is distinct from 'Another player is seated at this table.' then
    raise exception 'FAIL [L3] normal table: % / a human seated: %.', coalesce(v_msg, 'no error'), coalesce(v_msg2, 'no error');
  end if;
  select count(*) into v_n from public.table_members tm where tm.table_id in (v_norm, v_fake);
  if v_n <> 4 then
    raise exception 'FAIL [L3] the refused leaves changed seats: % left at the two tables, expected 4.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [L4] A leaves the computer table during the rematch: that game ends
  -- 'player_left', both seats go, the table is closed; the won game stays.
  execute 'set local role authenticated';
  perform public.leave_computer_table(v_ct);
  execute 'reset role';
  select g.status, g.ended_reason into v_status, v_txt from public.games g where g.id = v_g2;
  select count(*) into v_n from public.table_members tm where tm.table_id = v_ct;
  select t.status into v_msg from public.tables t where t.id = v_ct;
  select g.ended_reason into v_msg2 from public.games g where g.id = v_g;
  if v_status is distinct from 'ended' or v_txt is distinct from 'player_left' or v_n <> 0
     or v_msg is distinct from 'ended' or v_msg2 is distinct from 'won' then
    raise exception 'FAIL [L4] after leaving: game % %, % seat(s), table %, won game %.', v_status, v_txt, v_n, v_msg, v_msg2;
  end if;
  v_checks := v_checks + 1;

  -- [L5] A repeat is quiet, and acting for the computer there is refused.
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.leave_computer_table(v_ct); exception when others then v_msg := sqlerrm; end;
  v_msg2 := null;
  begin perform 1 from public.computer_hand(v_g2); exception when others then v_msg2 := sqlerrm; end;
  execute 'reset role';
  if v_msg is not null or v_msg2 is distinct from 'You are not seated at this table.' then
    raise exception 'FAIL [L5] repeat leave: % / computer_hand afterwards: %.', coalesce(v_msg, 'no error'), coalesce(v_msg2, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [L6] Cleanup after a plain leave: at the second table A is no longer
  -- seated but the computer is; A's leave_computer_table removes it and
  -- closes the table.
  execute 'set local role authenticated';
  perform public.leave_computer_table(v_ct2);
  execute 'reset role';
  select count(*) into v_n from public.table_members tm where tm.table_id = v_ct2;
  select t.status into v_msg from public.tables t where t.id = v_ct2;
  if v_n <> 0 or v_msg is distinct from 'ended' then
    raise exception 'FAIL [L6] cleanup: % seat(s) left, table %; expected none and ended.', v_n, v_msg;
  end if;
  v_checks := v_checks + 1;

  -- ---- Verdict ----------------------------------------------------------------
  if v_checks <> 81 then
    raise exception 'FAIL: % checks ran, expected 81.', v_checks;
  end if;

  raise exception 'ALL % CHECKS PASSED (rolled back). A=% B=% computer=%', v_checks, v_a, v_b, v_c;
end;
$$;
