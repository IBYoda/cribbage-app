-- Friends, F1: VERIFICATION of docs/sql/follows.sql.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER docs/sql/follows.sql. The
-- whole file is ONE DO block: run it as is.
--
-- STATUS: RUN in production on 2026-11-11: "ALL 20 CHECKS PASSED (rolled
-- back)", with only W6 skipped (no nameless account). Fixed while running it:
-- check F1 now casts p.provolatile (type "char") with ::text, because
-- text || "char" failed with "operator is not unique".
--
-- It WRITES (test follows, some inserted directly as the owner) and then
-- deliberately raises an exception at the very end, which rolls every write
-- back. It always "fails": the message is the verdict (the dashboard hides
-- notices, so nothing is reported any other way).
--   "ALL n CHECKS PASSED (rolled back) ..." is a pass; the message also lists
--   any "skipped: ..." lines (a step the project has no accounts for).
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives.
--
-- Same impersonation as the earlier verification scripts:
-- request.jwt.claims plus "set local role authenticated" (or anon) to act as
-- a client, and "reset role" to act as the owner between steps.
--
-- ACCOUNTS (real ones; nothing is created):
--   A, B, C, D  the four OLDEST followable accounts (a non-blank nickname,
--               not a computer, not hidden). A acts; B, C and D are targets.
--   computer    any computer account.
--   hidden      any hidden account (leaderboard_hidden) that is a real user.
--   nameless    any non-computer account whose profile nickname is blank.
-- A step whose accounts don't exist says "skipped: ..." instead of passing;
-- it is never faked. Any follows A or B already have are deleted first
-- (rolled back with everything else).
--
-- WHAT IT CHECKS
--   READ-ONLY
--   T1  public.follows exists: its primary key is (follower_id, followed_id),
--       the self-follow check follows_not_self exists, and so does the
--       followed_id index.
--   T2  row-level security is enabled, with no policies.
--   T3  no table privilege at all (SELECT, INSERT, UPDATE, DELETE, TRUNCATE,
--       REFERENCES, TRIGGER) for anon or authenticated, and no grant to
--       PUBLIC.
--   T4  follows is not in the supabase_realtime publication.
--   F1  each function's settings: _followable invoker, stable;
--       _follow_user_as, follow_user, unfollow_user security definer,
--       volatile; get_my_follows security definer, stable; all with
--       search_path=public.
--   G1  grants: authenticated can execute follow_user, unfollow_user and
--       get_my_follows; nobody (authenticated, anon, PUBLIC, service_role)
--       can execute _followable or _follow_user_as; anon and PUBLIC have
--       nothing on any of the five.
--   WALK-THROUGH (_follow_user_as with a cap of 2, as the owner, unless said)
--   W1  A follows B: 'following', one row A->B.
--   W2  A follows B again: 'following', still one row (no change).
--   W3  self, a random (missing) id and null: each 'not_allowed', no row.
--   W4  a computer account: 'not_allowed', no row.
--   W5  a hidden account: 'not_allowed', no row.
--   W6  a nameless account: 'not_allowed', no row.
--   W7  hidden follows don't count toward the cap: with a direct row A->hidden
--       (as the owner) and A->B, A follows C: 'following' (2 visible).
--   W8  the cap: A follows D: 'limit', and no row A->D.
--   W9  get_my_follows, as A: exactly A's visible follows (B, C); as B: only
--       B's own row (B->C, inserted directly), never A's.
--   W10 get_my_follows never returns a hidden account (A->hidden exists).
--   W11 as A (authenticated), the table itself is closed: a direct SELECT and
--       a direct INSERT are both refused (42501).
--   W12 as A through the public functions: follow_user(B) 'following' (no
--       change), unfollow_user(B) 'not_following' and the row is gone,
--       unfollow_user(B) again 'not_following' (no error, no change).
--   W13 follow_user uses the real cap (50), not 2: as A, follow_user(D) is
--       'following'.
--   W14 nobody logged in (authenticated role, no user in the claims):
--       follow_user and unfollow_user raise "You must be logged in ...";
--       get_my_follows returns no rows.
--   W15 anon can't call follow_user at all (42501).

do $$
declare
  v_a uuid;
  v_b uuid;
  v_c uuid;
  v_d uuid;
  v_comp uuid;
  v_hidden uuid;
  v_nameless uuid;
  v_tbl constant regclass := to_regclass('public.follows');
  v_fn text;
  v_priv text;
  v_txt text;
  v_msg text;
  v_state text;
  v_n int;
  v_ids uuid[];
  v_want uuid[];
  v_checks int := 0;
  v_skips text := '';
begin
  -- ==== READ-ONLY ============================================================
  -- [T1] The table, its primary key, the self-follow check and the index.
  if v_tbl is null then
    raise exception 'SETUP: public.follows does not exist. Run docs/sql/follows.sql first.';
  end if;
  select pg_get_constraintdef(c.oid) into v_txt
  from pg_constraint c where c.conrelid = v_tbl and c.contype = 'p';
  if v_txt is distinct from 'PRIMARY KEY (follower_id, followed_id)' then
    raise exception 'FAIL [T1] primary key is %, expected PRIMARY KEY (follower_id, followed_id).', coalesce(v_txt, 'missing');
  end if;
  if not exists (select 1 from pg_constraint c
                 where c.conrelid = v_tbl and c.contype = 'c' and c.conname = 'follows_not_self') then
    raise exception 'FAIL [T1] the check constraint follows_not_self is missing.';
  end if;
  if to_regclass('public.follows_followed_id_idx') is null then
    raise exception 'FAIL [T1] the index follows_followed_id_idx is missing.';
  end if;
  v_checks := v_checks + 1;

  -- [T2] RLS on, no policies.
  select count(*) into v_n from pg_policies where schemaname = 'public' and tablename = 'follows';
  if not (select c.relrowsecurity from pg_class c where c.oid = v_tbl) or v_n <> 0 then
    raise exception 'FAIL [T2] RLS enabled %, policies %; expected true, 0.',
      (select c.relrowsecurity from pg_class c where c.oid = v_tbl), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [T3] No table privilege for anon or authenticated; nothing for PUBLIC.
  foreach v_priv in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] loop
    if has_table_privilege('anon', v_tbl, v_priv) or has_table_privilege('authenticated', v_tbl, v_priv) then
      raise exception 'FAIL [T3] % on follows: anon %, authenticated %; expected false, false.',
        v_priv, has_table_privilege('anon', v_tbl, v_priv), has_table_privilege('authenticated', v_tbl, v_priv);
    end if;
  end loop;
  select count(*) into v_n
  from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
  where c.oid = v_tbl and a.grantee = 0;
  if v_n <> 0 then
    raise exception 'FAIL [T3] PUBLIC has % privilege(s) on follows; expected 0.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [T4] Not broadcast by Realtime.
  if exists (select 1 from pg_publication_tables pt
             where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = 'follows')
     or exists (select 1 from pg_publication pb where pb.pubname = 'supabase_realtime' and pb.puballtables) then
    raise exception 'FAIL [T4] follows is in (or would be taken by) the supabase_realtime publication.';
  end if;
  v_checks := v_checks + 1;

  -- [F1] Function settings: name, security definer, volatility.
  for v_fn, v_txt in
    select * from (values
      ('public._followable(uuid)', 'invoker s'),
      ('public._follow_user_as(uuid, uuid, int)', 'definer v'),
      ('public.follow_user(uuid)', 'definer v'),
      ('public.unfollow_user(uuid)', 'definer v'),
      ('public.get_my_follows()', 'definer s')
    ) as t(fn, want)
  loop
    if to_regprocedure(v_fn) is null then
      raise exception 'SETUP: % does not exist. Run docs/sql/follows.sql first.', v_fn;
    end if;
    select (case when p.prosecdef then 'definer ' else 'invoker ' end) || p.provolatile::text
           || case when 'search_path=public' = any(coalesce(p.proconfig, '{}')) then '' else ' (no search_path=public)' end
    into v_msg
    from pg_proc p where p.oid = to_regprocedure(v_fn);
    if v_msg is distinct from v_txt then
      raise exception 'FAIL [F1] % is "%", expected "%" with search_path=public.', v_fn, v_msg, v_txt;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- [G1] Grants.
  foreach v_fn in array array['public.follow_user(uuid)', 'public.unfollow_user(uuid)', 'public.get_my_follows()'] loop
    if not has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception 'FAIL [G1] authenticated cannot execute %.', v_fn;
    end if;
  end loop;
  foreach v_fn in array array['public._followable(uuid)', 'public._follow_user_as(uuid, uuid, int)'] loop
    if has_function_privilege('authenticated', v_fn, 'execute')
       or (exists (select 1 from pg_roles where rolname = 'service_role')
           and has_function_privilege('service_role', v_fn, 'execute')) then
      raise exception 'FAIL [G1] a client role (authenticated or service_role) can execute %.', v_fn;
    end if;
  end loop;
  foreach v_fn in array array['public._followable(uuid)', 'public._follow_user_as(uuid, uuid, int)',
                              'public.follow_user(uuid)', 'public.unfollow_user(uuid)', 'public.get_my_follows()'] loop
    select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = v_fn::regprocedure and a.grantee = 0 and a.privilege_type = 'EXECUTE';
    if has_function_privilege('anon', v_fn, 'execute') or v_n <> 0 then
      raise exception 'FAIL [G1] %: anon %, PUBLIC grants %; expected false, 0.',
        v_fn, has_function_privilege('anon', v_fn, 'execute'), v_n;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner ==================================================
  select array_agg(x.id order by x.created_at, x.id) into v_ids
  from (
    select u.id, u.created_at
    from auth.users u
    join public.profiles p on p.id = u.id
    where btrim(coalesce(p.nickname, '')) <> ''
      and not exists (select 1 from public.computer_accounts ca where ca.user_id = u.id)
      and not exists (select 1 from public.leaderboard_hidden h where h.user_id = u.id)
    order by u.created_at, u.id
    limit 4
  ) x;
  v_a := v_ids[1];
  v_b := v_ids[2];
  v_c := v_ids[3];
  v_d := v_ids[4];
  select ca.user_id into v_comp from public.computer_accounts ca order by ca.level limit 1;
  select h.user_id into v_hidden
  from public.leaderboard_hidden h join auth.users u on u.id = h.user_id
  order by h.created_at, h.user_id limit 1;
  select p.id into v_nameless
  from public.profiles p join auth.users u on u.id = p.id
  where btrim(coalesce(p.nickname, '')) = ''
    and not exists (select 1 from public.computer_accounts ca where ca.user_id = p.id)
  order by u.created_at, p.id limit 1;

  if v_a is null or v_b is null then
    raise exception 'SETUP: the walk-through needs at least two followable accounts (found %).',
      coalesce(array_length(v_ids, 1), 0);
  end if;

  -- A clean start for A and B (rolled back at the end).
  delete from public.follows where follower_id in (v_a, v_b);

  -- ==== WALK-THROUGH =========================================================
  -- [W1] A follows B.
  v_txt := public._follow_user_as(v_a, v_b, 2);
  select count(*) into v_n from public.follows where follower_id = v_a and followed_id = v_b;
  if v_txt <> 'following' or v_n <> 1 then
    raise exception 'FAIL [W1] follow B: %, rows %; expected following, 1.', v_txt, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [W2] Again: no change.
  v_txt := public._follow_user_as(v_a, v_b, 2);
  select count(*) into v_n from public.follows where follower_id = v_a;
  if v_txt <> 'following' or v_n <> 1 then
    raise exception 'FAIL [W2] follow B again: %, A''s rows %; expected following, 1.', v_txt, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [W3] Self, missing, null.
  if public._follow_user_as(v_a, v_a, 2) <> 'not_allowed'
     or public._follow_user_as(v_a, gen_random_uuid(), 2) <> 'not_allowed'
     or public._follow_user_as(v_a, null, 2) <> 'not_allowed' then
    raise exception 'FAIL [W3] self, missing or null was not refused with not_allowed.';
  end if;
  select count(*) into v_n from public.follows where follower_id = v_a;
  if v_n <> 1 then
    raise exception 'FAIL [W3] A has % rows after the refusals; expected 1.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [W4] A computer account.
  if v_comp is null then
    v_skips := v_skips || ' skipped: W4 (no computer account);';
  else
    v_txt := public._follow_user_as(v_a, v_comp, 2);
    select count(*) into v_n from public.follows where follower_id = v_a and followed_id = v_comp;
    if v_txt <> 'not_allowed' or v_n <> 0 then
      raise exception 'FAIL [W4] computer: %, rows %; expected not_allowed, 0.', v_txt, v_n;
    end if;
    v_checks := v_checks + 1;
  end if;

  -- [W5] A hidden account.
  if v_hidden is null then
    v_skips := v_skips || ' skipped: W5 (no hidden account);';
  else
    v_txt := public._follow_user_as(v_a, v_hidden, 2);
    select count(*) into v_n from public.follows where follower_id = v_a and followed_id = v_hidden;
    if v_txt <> 'not_allowed' or v_n <> 0 then
      raise exception 'FAIL [W5] hidden: %, rows %; expected not_allowed, 0.', v_txt, v_n;
    end if;
    v_checks := v_checks + 1;
  end if;

  -- [W6] A nameless account.
  if v_nameless is null then
    v_skips := v_skips || ' skipped: W6 (no nameless account);';
  else
    v_txt := public._follow_user_as(v_a, v_nameless, 2);
    select count(*) into v_n from public.follows where follower_id = v_a and followed_id = v_nameless;
    if v_txt <> 'not_allowed' or v_n <> 0 then
      raise exception 'FAIL [W6] nameless: %, rows %; expected not_allowed, 0.', v_txt, v_n;
    end if;
    v_checks := v_checks + 1;
  end if;

  -- [W7] A hidden follow doesn't count: A->hidden (direct) + A->B, then C fits.
  if v_c is null then
    v_skips := v_skips || ' skipped: W7, W8 (fewer than three followable targets);';
  else
    if v_hidden is not null then
      insert into public.follows (follower_id, followed_id) values (v_a, v_hidden);
    end if;
    v_txt := public._follow_user_as(v_a, v_c, 2);
    if v_txt <> 'following' then
      raise exception 'FAIL [W7] follow C with B (and a hidden follow) at a cap of 2: %; expected following.', v_txt;
    end if;
    if v_hidden is null then
      v_skips := v_skips || ' skipped: W7''s hidden part (no hidden account; C followed plainly);';
    else
      v_checks := v_checks + 1;
    end if;

    -- [W8] The cap.
    if v_d is null then
      v_skips := v_skips || ' skipped: W8 (fewer than three followable targets);';
    else
      v_txt := public._follow_user_as(v_a, v_d, 2);
      select count(*) into v_n from public.follows where follower_id = v_a and followed_id = v_d;
      if v_txt <> 'limit' or v_n <> 0 then
        raise exception 'FAIL [W8] follow D at the cap: %, rows %; expected limit, 0.', v_txt, v_n;
      end if;
      v_checks := v_checks + 1;
    end if;
  end if;

  -- [W9] get_my_follows: only the caller's own (visible) rows.
  if v_c is not null then
    insert into public.follows (follower_id, followed_id) values (v_b, v_c);   -- B's own row
  end if;
  v_want := array(select x from unnest(array[v_b, v_c]) x where x is not null order by x);

  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select coalesce(array_agg(g.user_id order by g.user_id), '{}') into v_ids from public.get_my_follows() g;
  execute 'reset role';
  if v_ids is distinct from v_want then
    raise exception 'FAIL [W9] get_my_follows as A returned %, expected %.', v_ids, v_want;
  end if;
  if v_c is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select coalesce(array_agg(g.user_id order by g.user_id), '{}') into v_ids from public.get_my_follows() g;
    execute 'reset role';
    if v_ids is distinct from array[v_c] then
      raise exception 'FAIL [W9] get_my_follows as B returned %, expected only C (%).', v_ids, v_c;
    end if;
  else
    v_skips := v_skips || ' skipped: W9''s second follower (no account C);';
  end if;
  v_checks := v_checks + 1;

  -- [W10] Never a hidden account (A->hidden exists from W7).
  if v_hidden is null or v_c is null then
    v_skips := v_skips || ' skipped: W10 (no hidden account, or no A->hidden row);';
  else
    if not exists (select 1 from public.follows where follower_id = v_a and followed_id = v_hidden) then
      raise exception 'SETUP [W10] the A->hidden row is missing.';
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select count(*) into v_n from public.get_my_follows() g where g.user_id = v_hidden;
    execute 'reset role';
    if v_n <> 0 then
      raise exception 'FAIL [W10] get_my_follows returned the hidden account.';
    end if;
    v_checks := v_checks + 1;
  end if;

  -- [W11] The table itself is closed to a signed-in client.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_state := null;
  begin
    perform 1 from public.follows limit 1;
  exception when others then v_state := sqlstate;
  end;
  v_msg := null;
  begin
    insert into public.follows (follower_id, followed_id) values (v_a, v_b);
  exception when others then v_msg := sqlstate;
  end;
  execute 'reset role';
  if v_state is distinct from '42501' or v_msg is distinct from '42501' then
    raise exception 'FAIL [W11] direct SELECT gave %, direct INSERT gave %; expected 42501 for both.',
      coalesce(v_state, 'no error'), coalesce(v_msg, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- [W12] The public functions, as A: follow again (no change), unfollow twice.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_txt := public.follow_user(v_b);
  v_msg := public.unfollow_user(v_b);
  v_state := public.unfollow_user(v_b);
  execute 'reset role';
  select count(*) into v_n from public.follows where follower_id = v_a and followed_id = v_b;
  if v_txt <> 'following' or v_msg <> 'not_following' or v_state <> 'not_following' or v_n <> 0 then
    raise exception 'FAIL [W12] follow_user %, unfollow_user %, again %, rows A->B %; expected following, not_following, not_following, 0.',
      v_txt, v_msg, v_state, v_n;
  end if;
  v_checks := v_checks + 1;

  -- [W13] follow_user's cap is 50, not 2: A follows C (+ hidden), then D fits.
  if v_d is null then
    v_skips := v_skips || ' skipped: W13 (no account D);';
  else
    perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_txt := public.follow_user(v_d);
    execute 'reset role';
    select count(*) into v_n from public.follows where follower_id = v_a and followed_id = v_d;
    if v_txt <> 'following' or v_n <> 1 then
      raise exception 'FAIL [W13] follow_user(D): %, rows %; expected following, 1.', v_txt, v_n;
    end if;
    v_checks := v_checks + 1;
  end if;

  -- [W14] Nobody logged in.
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_txt := null;
  begin
    perform public.follow_user(v_b);
  exception when others then v_txt := sqlerrm;
  end;
  v_msg := null;
  begin
    perform public.unfollow_user(v_b);
  exception when others then v_msg := sqlerrm;
  end;
  select count(*) into v_n from public.get_my_follows();
  execute 'reset role';
  if v_txt is distinct from 'You must be logged in to follow a player.'
     or v_msg is distinct from 'You must be logged in to unfollow a player.'
     or v_n <> 0 then
    raise exception 'FAIL [W14] no user: follow_user "%", unfollow_user "%", get_my_follows % rows.',
      coalesce(v_txt, 'no error'), coalesce(v_msg, 'no error'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [W15] anon can't call it at all.
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  execute 'set local role anon';
  v_state := null;
  begin
    perform public.follow_user(v_b);
  exception when others then v_state := sqlstate;
  end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [W15] anon calling follow_user gave %, expected 42501.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- ---- Verdict ----------------------------------------------------------------
  raise exception 'ALL % CHECKS PASSED (rolled back). A=% B=% C=% D=%.%',
    v_checks, v_a, v_b, coalesce(v_c::text, '-'), coalesce(v_d::text, '-'),
    case when v_skips = '' then ' Nothing skipped.' else v_skips end;
end;
$$;
