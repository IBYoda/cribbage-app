-- Computer opponent, C1: VERIFICATION.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER
-- docs/sql/computer-c1-refactor.sql. The whole file is ONE DO block: run it
-- as is. It writes nothing that survives: it ends by raising an exception,
-- which is both the verdict and the rollback. "ALL n CHECKS PASSED (rolled
-- back) ..." is a pass; anything starting "FAIL" is not.
--
-- Same impersonation as the earlier verification scripts:
-- request.jwt.claims plus "set local role authenticated" (or anon) to act as
-- a client, and "reset role" to act as the owner between steps.
--
-- WHAT IT CHECKS, for each of the eight functions (15 checks each):
--   1  the wrapper exists with its exact signature;
--   2  the _as function exists: (uuid, <the same params>);
--   3  both return the same type as before;
--   4  both are plpgsql, security definer, search_path = public;
--   5  the wrapper's body is exactly the thin call (md5);
--   6  the _as body is the newest docs/sql body with ONLY the caller line
--      changed: put "auth.uid()" back in that one line and its md5 is the
--      one phase3-e4-counting-verification.sql expects for today's version;
--   7  the _as body reads no caller identity at all (no auth., jwt or
--      current_setting anywhere) and holds "v_caller uuid := p_actor;"
--      exactly once;
--   8  authenticated can execute the wrapper;
--   9  authenticated cannot execute the _as function (privilege check);
--  10  anon cannot execute the _as function (privilege check; it counts
--      PUBLIC grants too);
--  11  PUBLIC holds no grant on the _as function;
--  12  anon cannot execute the wrapper -- for the six functions whose newest
--      file revokes it from anon. draw_cut_card and acknowledge_deal_cut were
--      created before Slice 6b and their files never revoked anon, so anon
--      may still hold EXECUTE on them from Supabase's old default. C1 keeps
--      every wrapper's grants exactly, so for those two this only REPORTS
--      the state (in the final message). It is harmless: the body refuses a
--      null caller first, and anon has no caller.
--  13  a call to the wrapper with no logged-in user is refused with the same
--      text as before ("You must be logged in to ...");
--  14  authenticated calling the _as function is refused, 42501;
--  15  anon calling the _as function is refused, 42501.
--
-- Expected message:
--   ALL 120 CHECKS PASSED (rolled back). anon EXECUTE on the pre-6b
--   wrappers: draw_cut_card=..., acknowledge_deal_cut=...

do $$
declare
  v_rec record;
  v_w regprocedure;
  v_a regprocedure;
  v_src text;
  v_n int;
  v_msg text;
  v_state text;
  v_args text;
  v_anon_note text := '';
  v_checks int := 0;
begin
  for v_rec in
    select * from (values
    ('start_game_with_deal', 'uuid', 'uuid, uuid', 'uuid', '3feaa7508cf434b4a3f8d78a8ad9896a', '8d6ceb9ba00b9f2b6b9b8613e10609df', 'f7df18aedee7d95216674a7687c405a0', 'You must be logged in to start a game.', true),
    ('draw_cut_card', 'uuid', 'uuid, uuid', 'text', '2ca8d114de4e45861e21c23b2e4b65f8', 'e52f927759d991e13b55a6fa73d39781', '0edacf243b6383d9a6977fedb4bd8392', 'You must be logged in to cut for deal.', false),
    ('acknowledge_deal_cut', 'uuid', 'uuid, uuid', 'void', '5b06eec819234121db1bf802ea462c02', '1e6e9b06a58d59628ca8b4ae19e6605d', '3ca1514190fa9f57ebd1b78166c26f52', 'You must be logged in to continue.', false),
    ('discard_to_crib', 'uuid, text[]', 'uuid, uuid, text[]', 'void', '69ab74268ce6c799c40777436a8cfafd', 'fe4d1bb43ee5d4c38dacac502a8817ab', '325b1a01178582eba9a55d8117db0803', 'You must be logged in to discard.', true),
    ('play_card', 'uuid, text', 'uuid, uuid, text', 'void', 'cad9e43a7803fdb50eb4d3dd6b5c7210', '39f2602ae2d547799f722ce434328b1c', 'b0434ffb08c301676a3d25722feba168', 'You must be logged in to play a card.', true),
    ('show_crib', 'uuid', 'uuid, uuid', 'void', '0005309db8568708bac13aa169bd91b3', '46ff0cf6834ba0afae2178a6fc895da5', '17821982fea29ef642fefa6a8d63c711', 'You must be logged in to show the crib.', true),
    ('confirm_count', 'uuid, int', 'uuid, uuid, int', 'void', 'cc85c25a2a25fe4f91ab8ea39f3aab94', '27d9a04b7810746bce691f01ec8feffa', '1d5baa992851570fae14dfcf5fda2853', 'You must be logged in to confirm a count.', true),
    ('next_hand', 'uuid, int', 'uuid, uuid, int', 'void', '9007931d5f4cc4ac127c9c2dfd7c1178', 'e08be4b22774ad656feed6b3852e0562', '692a77e35e328d7c83ad5de4af69fa51', 'You must be logged in to deal the next hand.', true)
    ) as t(fn, sig, as_sig, ret, orig_md5, as_md5, wrap_md5, null_msg, anon_revoked)
  loop
    -- [1] The wrapper, exact signature.
    v_w := to_regprocedure('public.' || v_rec.fn || '(' || v_rec.sig || ')');
    if v_w is null then
      raise exception 'FAIL [1] public.%(%) is missing.', v_rec.fn, v_rec.sig;
    end if;
    v_checks := v_checks + 1;

    -- [2] The _as function, exact signature.
    v_a := to_regprocedure('public.' || v_rec.fn || '_as(' || v_rec.as_sig || ')');
    if v_a is null then
      raise exception 'FAIL [2] public.%_as(%) is missing.', v_rec.fn, v_rec.as_sig;
    end if;
    v_checks := v_checks + 1;

    -- [3] Both return the type the public function always returned.
    if pg_get_function_result(v_w) is distinct from v_rec.ret
       or pg_get_function_result(v_a) is distinct from v_rec.ret then
      raise exception 'FAIL [3] % returns % and its _as returns %, expected %.',
        v_rec.fn, pg_get_function_result(v_w), pg_get_function_result(v_a), v_rec.ret;
    end if;
    v_checks := v_checks + 1;

    -- [4] plpgsql, security definer, search_path = public -- both.
    select count(*) into v_n
    from pg_proc p
    join pg_language l on l.oid = p.prolang
    where p.oid in (v_w, v_a)
      and l.lanname = 'plpgsql'
      and p.prosecdef
      and p.proconfig = array['search_path=public'];
    if v_n <> 2 then
      raise exception 'FAIL [4] % and %_as: expected both plpgsql, security definer, search_path=public.', v_rec.fn, v_rec.fn;
    end if;
    v_checks := v_checks + 1;

    -- [5] The wrapper's body is exactly the thin call.
    select md5(replace(p.prosrc, E'\r', '')) into v_msg from pg_proc p where p.oid = v_w;
    if v_msg is distinct from v_rec.wrap_md5 then
      raise exception 'FAIL [5] the % wrapper body has md5 %, expected %.', v_rec.fn, v_msg, v_rec.wrap_md5;
    end if;
    v_checks := v_checks + 1;

    -- [6] The _as body is today's body with only the caller line changed.
    select replace(p.prosrc, E'\r', '') into v_src from pg_proc p where p.oid = v_a;
    if md5(v_src) is distinct from v_rec.as_md5
       or md5(replace(v_src, '  v_caller uuid := p_actor;', '  v_caller uuid := auth.uid();')) is distinct from v_rec.orig_md5 then
      raise exception 'FAIL [6] %_as is not today''s body with only the caller line changed (md5 %).', v_rec.fn, md5(v_src);
    end if;
    v_checks := v_checks + 1;

    -- [7] No caller-identity read left in the _as body; the p_actor line once.
    v_n := (length(v_src) - length(replace(v_src, 'v_caller uuid := p_actor;', '')))
           / length('v_caller uuid := p_actor;');
    if position('auth.' in v_src) > 0
       or position('jwt' in lower(v_src)) > 0
       or position('current_setting' in lower(v_src)) > 0
       or v_n <> 1 then
      raise exception 'FAIL [7] %_as still reads a caller identity, or holds the p_actor line % times.', v_rec.fn, v_n;
    end if;
    v_checks := v_checks + 1;

    -- [8] authenticated can execute the wrapper.
    if not has_function_privilege('authenticated', v_w, 'execute') then
      raise exception 'FAIL [8] authenticated cannot execute %.', v_rec.fn;
    end if;
    v_checks := v_checks + 1;

    -- [9] authenticated cannot execute the _as function.
    if has_function_privilege('authenticated', v_a, 'execute') then
      raise exception 'FAIL [9] authenticated CAN execute %_as.', v_rec.fn;
    end if;
    v_checks := v_checks + 1;

    -- [10] anon cannot execute the _as function.
    if has_function_privilege('anon', v_a, 'execute') then
      raise exception 'FAIL [10] anon CAN execute %_as.', v_rec.fn;
    end if;
    v_checks := v_checks + 1;

    -- [11] No PUBLIC grant on the _as function (grantee 0 in its ACL; a null
    -- ACL means the defaults, which include PUBLIC, so it is expanded).
    select count(*) into v_n
    from pg_proc p,
         aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = v_a
      and a.grantee = 0;
    if v_n <> 0 then
      raise exception 'FAIL [11] PUBLIC holds a grant on %_as.', v_rec.fn;
    end if;
    v_checks := v_checks + 1;

    -- [12] anon and the wrapper (see the header about the two pre-6b ones).
    if v_rec.anon_revoked then
      if has_function_privilege('anon', v_w, 'execute') then
        raise exception 'FAIL [12] anon CAN execute %.', v_rec.fn;
      end if;
    else
      v_anon_note := v_anon_note
        || case when v_anon_note = '' then '' else ', ' end
        || v_rec.fn || '=' || has_function_privilege('anon', v_w, 'execute')::text;
    end if;
    v_checks := v_checks + 1;

    -- The wrapper's arguments for the dynamic calls: a fresh random id first
    -- (no game or table has it), then a null of each further parameter type.
    select string_agg(format('null::%s', x.t), ', ' order by x.i)
    into v_args
    from unnest(string_to_array(v_rec.sig, ', ')) with ordinality as x(t, i)
    where x.i > 1;
    v_args := quote_literal(gen_random_uuid()::text) || '::uuid'
      || case when v_args is null then '' else ', ' || v_args end;

    -- [13] No logged-in user: refused with the same text as before.
    execute 'set local role authenticated';
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', '', true);
    v_msg := null;
    begin
      execute format('select public.%I(%s)', v_rec.fn, v_args);
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_msg is distinct from v_rec.null_msg then
      raise exception 'FAIL [13] % with no caller: %, expected "%".', v_rec.fn, coalesce(v_msg, 'no error'), v_rec.null_msg;
    end if;
    v_checks := v_checks + 1;

    -- [14] authenticated (a random user) calling the _as function: 42501.
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
    v_state := null;
    begin
      execute format('select public.%I(%s, %s)', v_rec.fn || '_as',
        quote_literal(gen_random_uuid()::text) || '::uuid', v_args);
    exception when others then
      v_state := sqlstate;
    end;
    execute 'reset role';
    if v_state is distinct from '42501' then
      raise exception 'FAIL [14] authenticated calling %_as: expected 42501, got %.', v_rec.fn, coalesce(v_state, 'no error');
    end if;
    v_checks := v_checks + 1;

    -- [15] anon calling the _as function: 42501.
    execute 'set local role anon';
    perform set_config('request.jwt.claim.role', 'anon', true);
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
    perform set_config('request.jwt.claim.sub', '', true);
    v_state := null;
    begin
      execute format('select public.%I(%s, %s)', v_rec.fn || '_as',
        quote_literal(gen_random_uuid()::text) || '::uuid', v_args);
    exception when others then
      v_state := sqlstate;
    end;
    execute 'reset role';
    if v_state is distinct from '42501' then
      raise exception 'FAIL [15] anon calling %_as: expected 42501, got %.', v_rec.fn, coalesce(v_state, 'no error');
    end if;
    v_checks := v_checks + 1;
  end loop;

  if v_checks <> 120 then
    raise exception 'FAIL: % checks ran, expected 120.', v_checks;
  end if;

  raise exception 'ALL % CHECKS PASSED (rolled back). anon EXECUTE on the pre-6b wrappers: %', v_checks, v_anon_note;
end;
$$;
