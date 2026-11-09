-- Computer opponents, Normie/Rainman: VERIFICATION.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER
-- docs/sql/computer-normie.sql. The whole file is ONE DO block: run it as is.
--
-- It WRITES (a test table, its seats, test rows that must be refused) and
-- then deliberately raises an exception at the very end, which rolls every
-- write back. It always "fails": the message is the verdict.
-- "ALL n CHECKS PASSED (rolled back) ..." is a pass; anything starting
-- "FAIL" or "SETUP" is not. Re-runnable, because nothing it does survives.
--
-- Same impersonation as the earlier verification scripts:
-- request.jwt.claims plus "set local role authenticated" (or anon) to act as
-- a client, and "reset role" to act as the owner between steps.
--
-- PLAYER: A is the OLDEST account that is neither an admin nor a computer
-- account. The REAL computer accounts are used (unlike
-- computer-c2-verification.sql, nothing here replaces them).
--
-- WHAT IT CHECKS
--   C  constraints: computer_accounts' and tables' level checks each list
--      exactly easy, casual, medium, hard; a 'casual' table row is accepted;
--      an 'expert' row is refused (23514) in both tables.
--   P  accounts: exactly four computer accounts, one per level;
--      get_computer_profiles(), called as A, returns them easiest first with
--      the nicknames Shortbus, Normie, Rainman, God.
--   T  create_computer_table('casual', ...) as A: a private, regular,
--      2-player 'casual' table, A in seat 1 and the casual account in
--      seat 2; the guard (_computer_for_table) answers the casual account;
--      'expert' is refused with the new four-level message.
--   G  grants unchanged: both functions executable by authenticated, not by
--      anon or PUBLIC.

do $$
declare
  v_a uuid;
  v_easy uuid;
  v_casual uuid;
  v_medium uuid;
  v_hard uuid;
  v_code text;
  v_code2 text;
  v_ct uuid;
  v_txt text;
  v_def text;
  v_msg text;
  v_state text;
  v_ids uuid[];
  v_levels text[];
  v_names text[];
  v_n int;
  v_fn text;
  v_checks int := 0;
begin
  -- ---- Setup, as the owner ------------------------------------------------
  select u.id into v_a from auth.users u
  where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
    and not exists (select 1 from public.computer_accounts ca where ca.user_id = u.id)
  order by u.created_at limit 1;
  if v_a is null then
    raise exception 'SETUP: the project needs an account that is neither an admin nor a computer account.';
  end if;

  select ca.user_id into v_easy from public.computer_accounts ca where ca.level = 'easy';
  select ca.user_id into v_casual from public.computer_accounts ca where ca.level = 'casual';
  select ca.user_id into v_medium from public.computer_accounts ca where ca.level = 'medium';
  select ca.user_id into v_hard from public.computer_accounts ca where ca.level = 'hard';
  if v_casual is null then
    raise exception 'SETUP: there is no casual computer account; run computer-normie.sql first.';
  end if;

  select min(lpad(n::text, 4, '0')) into v_code
  from generate_series(0, 9999) n
  where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0'));
  select min(lpad(n::text, 4, '0')) into v_code2
  from generate_series(0, 9999) n
  where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0'))
    and lpad(n::text, 4, '0') <> v_code;
  if v_code is null or v_code2 is null then
    raise exception 'SETUP: fewer than two unused table codes.';
  end if;

  -- ==== C: constraints =======================================================
  -- [C1] computer_accounts' level check lists the four levels.
  select pg_get_constraintdef(c.oid) into v_def
  from pg_constraint c
  where c.conrelid = 'public.computer_accounts'::regclass and c.contype = 'c'
    and c.conname = 'computer_accounts_level_check';
  select count(*) into v_n
  from pg_constraint c
  where c.conrelid = 'public.computer_accounts'::regclass and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ilike '%level%';
  if v_def is null or v_n <> 1
     or v_def not like '%''easy''%' or v_def not like '%''casual''%'
     or v_def not like '%''medium''%' or v_def not like '%''hard''%' then
    raise exception 'FAIL [C1] computer_accounts level check: % (% level checks); expected one, with easy, casual, medium, hard.',
      coalesce(v_def, 'missing'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [C2] tables' level check lists the four levels.
  select pg_get_constraintdef(c.oid) into v_def
  from pg_constraint c
  where c.conrelid = 'public.tables'::regclass and c.contype = 'c'
    and c.conname = 'tables_computer_level_check';
  if v_def is null
     or v_def not like '%''easy''%' or v_def not like '%''casual''%'
     or v_def not like '%''medium''%' or v_def not like '%''hard''%' then
    raise exception 'FAIL [C2] tables_computer_level_check: %; expected easy, casual, medium, hard.', coalesce(v_def, 'missing');
  end if;
  v_checks := v_checks + 1;

  -- [C3] A 'casual' table row is accepted (as the owner; rolled back).
  v_state := null;
  begin
    insert into public.tables (code, created_by, computer_level) values (v_code2, v_a, 'casual');
    delete from public.tables where code = v_code2;
  exception when others then v_state := sqlstate;
  end;
  if v_state is not null then
    raise exception 'FAIL [C3] a casual table row: %; expected accepted.', v_state;
  end if;
  v_checks := v_checks + 1;

  -- [C4] 'expert' is refused by both checks (23514). The check runs before
  -- the key and foreign-key checks, so a random id is enough here.
  v_state := null;
  begin
    insert into public.tables (code, created_by, computer_level) values (v_code2, v_a, 'expert');
  exception when others then v_state := sqlstate;
  end;
  v_msg := null;
  begin
    insert into public.computer_accounts (level, user_id) values ('expert', gen_random_uuid());
  exception when others then v_msg := sqlstate;
  end;
  if v_state is distinct from '23514' or v_msg is distinct from '23514' then
    raise exception 'FAIL [C4] expert: tables %, computer_accounts %; expected 23514 each.',
      coalesce(v_state, 'accepted'), coalesce(v_msg, 'accepted');
  end if;
  v_checks := v_checks + 1;

  -- ==== P: the four accounts ==================================================
  -- [P1] Exactly four computer accounts, one per level, all different users.
  select count(*) into v_n from public.computer_accounts;
  if v_n <> 4 or v_easy is null or v_medium is null or v_hard is null
     or (select count(distinct ca.user_id) from public.computer_accounts ca) <> 4 then
    raise exception 'FAIL [P1] % computer account(s) (easy %, casual %, medium %, hard %); expected four different users.',
      v_n, v_easy, v_casual, v_medium, v_hard;
  end if;
  v_checks := v_checks + 1;

  -- [P2] get_computer_profiles() as A: easiest first, the new names.
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  execute 'set local role authenticated';
  select array_agg(r.level order by r.ord), array_agg(r.nickname order by r.ord), array_agg(r.user_id order by r.ord)
  into v_levels, v_names, v_ids
  from public.get_computer_profiles() with ordinality as r(level, user_id, nickname, avatar_url, ord);
  execute 'reset role';
  if v_levels is distinct from array['easy', 'casual', 'medium', 'hard']
     or v_names is distinct from array['Shortbus', 'Normie', 'Rainman', 'God']
     or v_ids is distinct from array[v_easy, v_casual, v_medium, v_hard] then
    raise exception 'FAIL [P2] get_computer_profiles: levels %, names %; expected easy/casual/medium/hard and Shortbus/Normie/Rainman/God.',
      v_levels, v_names;
  end if;
  v_checks := v_checks + 1;

  -- ==== T: create_computer_table('casual') ====================================
  -- [T1] A makes a casual table: private, regular, 2-player, A in 1 and the
  -- casual computer in 2.
  execute 'set local role authenticated';
  select r.table_id, r.code into v_ct, v_txt from public.create_computer_table('casual', v_code) r;
  execute 'reset role';
  select count(*) into v_n from public.tables t
  where t.id = v_ct and t.code = v_code and t.created_by = v_a and t.status = 'open'
    and t.is_public = false and t.is_muggins = false and t.max_players = 2 and t.computer_level = 'casual';
  select array_agg(tm.user_id order by tm.seat) into v_ids from public.table_members tm where tm.table_id = v_ct;
  select array_agg(tm.seat order by tm.seat)::text into v_msg from public.table_members tm where tm.table_id = v_ct;
  if v_ct is null or v_txt is distinct from v_code or v_n <> 1
     or v_ids is distinct from array[v_a, v_casual] or v_msg is distinct from '{1,2}' then
    raise exception 'FAIL [T1] create_computer_table(casual): returned (%, %), table match %, seats % %; expected A in 1, Normie in 2.',
      v_ct, v_txt, v_n, v_ids, v_msg;
  end if;
  v_checks := v_checks + 1;

  -- [T2] The guard answers the casual computer for that table (as the owner,
  -- with A's claims still set: the helper reads auth.uid()).
  if public._computer_for_table(v_ct) is distinct from v_casual then
    raise exception 'FAIL [T2] _computer_for_table: %; expected the casual computer %.', public._computer_for_table(v_ct), v_casual;
  end if;
  v_checks := v_checks + 1;

  -- [T3] 'expert' is refused with the four-level message.
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.create_computer_table('expert', v_code2); exception when others then v_msg := sqlerrm; end;
  execute 'reset role';
  if v_msg is distinct from 'Unknown computer level "expert": choose easy, casual, medium or hard.' then
    raise exception 'FAIL [T3] expert: %; expected the four-level refusal.', coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- ==== G: grants unchanged ===================================================
  -- [G1] Both functions: EXECUTE for authenticated; none for anon or PUBLIC.
  foreach v_fn in array array['public.create_computer_table(text, text)', 'public.get_computer_profiles()'] loop
    select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = v_fn::regprocedure and a.grantee = 0 and a.privilege_type = 'EXECUTE';
    if not has_function_privilege('authenticated', v_fn, 'execute')
       or has_function_privilege('anon', v_fn, 'execute')
       or v_n <> 0 then
      raise exception 'FAIL [G1] %: authenticated %, anon %, PUBLIC grants %; expected true, false, 0.',
        v_fn, has_function_privilege('authenticated', v_fn, 'execute'), has_function_privilege('anon', v_fn, 'execute'), v_n;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- ---- Verdict ----------------------------------------------------------------
  if v_checks <> 10 then
    raise exception 'FAIL: % checks ran, expected 10.', v_checks;
  end if;

  raise exception 'ALL % CHECKS PASSED (rolled back). A=% Normie=% Rainman=%', v_checks, v_a, v_casual, v_medium;
end;
$$;
