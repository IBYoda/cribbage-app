-- Step 3, slice E: VERIFICATION of the attempt_log cleanup
-- (docs/sql/slice-e-part1.sql).
--
-- Run in the Supabase Dashboard -> SQL Editor after slice-e-part1.sql.
-- The whole file is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- It WRITES -- one temporary account in auth.users and a few attempt_log rows
-- for it -- and calls cleanup_attempt_log() (inside this transaction it may
-- delete real rows older than 7 days too), then deliberately raises an
-- exception at the very end, which rolls EVERY write back. A check that
-- fails raises its own exception at once, which rolls everything back the
-- same way. It always "fails": the message is the verdict.
--   "ALL 5 CHECKS PASSED (rolled back). ..." is a pass.
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives. pg_cron is read through
-- EXECUTE, so this file parses without it (K2 then fails, as it should).
--
-- WHAT IT CHECKS
--   K1  cleanup_attempt_log(): security definer, search_path '', returns
--       integer; EXECUTE for no client role (anon, authenticated,
--       service_role) and no PUBLIC grant.
--   K2  the pg_cron job attempt-log-cleanup: exactly one, '17 * * * *',
--       active, running select public.cleanup_attempt_log();.
--   K3  attempt_log_action_check allows exactly the seven actions (the five
--       slice A ones plus game_start and follow_change) -- or, once
--       moderation M1 part 1 is in (public.blocks exists), exactly those
--       eight with block_change.
--   K4  the cleanup deletes rows older than 7 days and keeps the rest: of
--       the temporary account's rows at 8 days, 7 days and a minute, 6 days
--       and 23 hours, and now, the last two stay; afterwards no row older
--       than 7 days is left anywhere; it reports at least 2 deleted.
--   K5  a client cannot call it: as authenticated and as anon, 42501.
--
-- Expected message:
--   ALL 5 CHECKS PASSED (rolled back). deleted N row(s).

do $$
declare
  v_checks int := 0;
  v_u uuid := gen_random_uuid();
  v_txt text;
  v_n int;
  v_deleted int;
  v_ok boolean;
  v_state text;
  v_state2 text;
begin
  if to_regprocedure('public.cleanup_attempt_log()') is null then
    raise exception 'SETUP: slice-e-part1.sql has not run (cleanup_attempt_log() is missing).';
  end if;

  -- [K1] The function.
  select p.prosecdef
         and coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']
         and p.prorettype = 'integer'::regtype
         and not has_function_privilege('anon', p.oid, 'EXECUTE')
         and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
         and (not exists (select 1 from pg_roles r where r.rolname = 'service_role')
              or not has_function_privilege('service_role', p.oid, 'EXECUTE'))
         and not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0)
  into v_ok
  from pg_proc p where p.oid = to_regprocedure('public.cleanup_attempt_log()');
  if v_ok is not true then
    raise exception 'FAIL [K1] cleanup_attempt_log() must be security definer, search_path '''', return integer, and be executable by no client role.';
  end if;
  v_checks := v_checks + 1;

  -- [K2] The cron job.
  if to_regclass('cron.job') is null then
    raise exception 'FAIL [K2] pg_cron is not installed: no attempt-log-cleanup job.';
  end if;
  execute 'select count(*)::int from cron.job where jobname::text = $1 and schedule::text = $2 and active and command::text ilike $3'
  into v_n
  using 'attempt-log-cleanup'::text, '17 * * * *'::text, '%public.cleanup_attempt_log()%'::text;
  if v_n <> 1 then
    raise exception 'FAIL [K2] the pg_cron job attempt-log-cleanup (17 * * * *, active, select public.cleanup_attempt_log();) is missing or different (% matching).', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [K3] The seven actions -- eight with block_change once moderation M1
  -- part 1 is in (its table exists; slice-e-grants-verification.sql decides
  -- the same way).
  select pg_get_constraintdef(con.oid) into v_txt
  from pg_constraint con
  where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check';
  if v_txt is null
     or (length(v_txt) - length(replace(v_txt, '::text', ''))) / 6
          <> (case when to_regclass('public.blocks') is not null then 8 else 7 end)
     or v_txt !~ '''create_table''' or v_txt !~ '''create_computer_table''' or v_txt !~ '''join'''
     or v_txt !~ '''watch''' or v_txt !~ '''code_guess''' or v_txt !~ '''game_start''' or v_txt !~ '''follow_change'''
     or (to_regclass('public.blocks') is not null and v_txt !~ '''block_change''') then
    raise exception 'FAIL [K3] attempt_log_action_check is "%"; expected exactly %.', coalesce(v_txt, 'missing'),
      case when to_regclass('public.blocks') is not null
           then 'the eight actions (the seven slice A/E ones plus block_change: moderation M1 part 1 is in)'
           else 'the seven actions (the five slice A ones plus game_start and follow_change)' end;
  end if;
  v_checks := v_checks + 1;

  -- [K4] Old rows go, recent ones stay.
  begin
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'sec-' || v_u::text || '@verification.invalid', now() - interval '30 days', now());
  exception when others then
    raise exception 'SETUP: could not create the temporary account: % (%).', sqlerrm, sqlstate;
  end;
  insert into public.attempt_log (user_id, action, success, created_at) values
    (v_u, 'join', true, now() - interval '8 days'),
    (v_u, 'code_guess', false, now() - interval '7 days 1 minute'),
    (v_u, 'game_start', true, now() - interval '6 days 23 hours'),
    (v_u, 'follow_change', true, now());
  v_deleted := public.cleanup_attempt_log();
  select string_agg(a.action, ',' order by a.created_at) into v_txt from public.attempt_log a where a.user_id = v_u;
  select count(*) into v_n from public.attempt_log a where a.created_at < now() - interval '7 days';
  if v_txt is distinct from 'game_start,follow_change' or v_n <> 0 or v_deleted < 2 then
    raise exception 'FAIL [K4] after the cleanup: the account keeps "%" (expected game_start,follow_change), % row(s) older than 7 days remain, % deleted (expected at least 2).', coalesce(v_txt, 'nothing'), v_n, v_deleted;
  end if;
  v_checks := v_checks + 1;

  -- [K5] No client can call it.
  perform set_config('request.jwt.claims', json_build_object('sub', v_u, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    perform public.cleanup_attempt_log();
    execute 'reset role';
  exception when others then
    v_state := sqlstate;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  begin
    execute 'set local role anon';
    perform public.cleanup_attempt_log();
    execute 'reset role';
  exception when others then
    v_state2 := sqlstate;
  end;
  execute 'reset role';
  if v_state is distinct from '42501' or v_state2 is distinct from '42501' then
    raise exception 'FAIL [K5] calling cleanup_attempt_log(): authenticated %, anon %; expected 42501 both.', coalesce(v_state, 'allowed'), coalesce(v_state2, 'allowed');
  end if;
  v_checks := v_checks + 1;

  if v_checks <> 5 then
    raise exception 'FAIL: % checks ran, expected 5.', v_checks;
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back). deleted % row(s).', v_checks, v_deleted;
end;
$$;
