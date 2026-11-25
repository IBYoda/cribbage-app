-- Step 3, slice E: VERIFICATION of the grants (docs/sql/slice-e-part3.sql)
-- and the avatar storage policies (docs/sql/slice-e-part2.sql).
--
-- Run in the Supabase Dashboard -> SQL Editor after slice-e-part3.sql.
-- The whole file is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
--
-- UPDATED FOR MODERATION M1 (docs/sql/moderation-m1-part1.sql): once
-- public.blocks exists, T1 expects it with NO privilege for any client role,
-- and X1 expects 52 names (the 49 plus block_player, unblock_player and
-- get_my_blocks). Before M1 part 1 it expects exactly what slice E left: no
-- blocks table and the 49. Re-run it after M1 part 1 and after part 2.
--
-- It WRITES -- one temporary function in public (X2), two temporary accounts
-- in auth.users, and a few storage.objects rows in the avatars bucket written
-- as one of them (rows only: no file is uploaded, and every row is rolled
-- back) -- and then deliberately raises an exception at the very end, which
-- rolls EVERY write back. A check that fails raises its own exception at
-- once, which rolls everything back the same way. It always "fails": the
-- message is the verdict.
--   "ALL 12 CHECKS PASSED (rolled back)." is a pass.
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives.
--
-- WHAT IT CHECKS
--   T1  every table in public, its exact table-level privileges for
--       authenticated, anon and PUBLIC (a table this suite doesn't know
--       fails it: add it here with its intended grants):
--         tables           SELECT, UPDATE           / SELECT / -
--         table_members    SELECT                   / SELECT / -
--         games            SELECT, UPDATE           / SELECT / -
--         game_plays, game_hands, game_cribs, game_decks
--                          SELECT                   / SELECT / -
--         profiles         INSERT, SELECT, UPDATE   / SELECT / -
--         admin_users      SELECT                   / SELECT / -
--         user_appearance  INSERT, SELECT, UPDATE   / -      / -
--         table_spectators SELECT                   / -      / -
--         attempt_log, computer_accounts, follows, game_results,
--         leaderboard_hidden, and blocks (once moderation M1 part 1 has
--         made it): nothing for any of the three.
--   T2  no column-level grant on any table in public.
--   X1  functions: none executable by anon, none granted to PUBLIC, and
--       authenticated may execute exactly these 49 (by name) -- 52 once
--       moderation M1 part 1 is in (plus block_player, unblock_player,
--       get_my_blocks; never _is_blocked_from_table): every RPC the
--       app calls, chat_topic_allows (Realtime evaluates it as the user), the
--       seven slice D helpers (the row policies evaluate them as the user),
--       and show_hand (granted since phase 2; the app no longer calls it --
--       kept as is by Walt's slice E decision). A function opened to a
--       client without being added here fails it.
--   X2  a NEW function created in public by the role running this (the
--       dashboard's postgres) is executable by neither anon nor
--       authenticated, and PUBLIC holds no grant on it: the default
--       privileges really are closed. Fails loudly before slice-e-part3.sql
--       (the built-in default gives PUBLIC EXECUTE); passes after it.
--   X4  postgres's GLOBAL default ACL for functions exists (pg_default_acl,
--       defaclnamespace 0, objtype 'f') and grants EXECUTE to nobody but
--       postgres -- no PUBLIC, anon or authenticated entry (part 3's
--       {postgres=X/postgres}).
--   X3  public.rls_auto_enable() (if it exists): no EXECUTE for anon,
--       authenticated or PUBLIC, and its event trigger is still enabled.
--   S1  avatars, as a signed-in user U: '<U>/avatar.png' and
--       '<U>/avatar.jpeg' can be written.
--   S2  another user's folder ('<V>/avatar.png'): refused (42501).
--   S3  another file name in U's folder ('photo.png', 'avatar.gif'):
--       refused.
--   S4  an upper-case extension ('<U>/avatar.PNG'): refused.
--   S5  renaming U's own avatar.png to 'evil.png' (UPDATE): refused.
--   C1  leave_table, end_timed_out_sessions, assign_table_seat, table_host:
--       body md5 unchanged.
--
-- Expected message:
--   ALL 12 CHECKS PASSED (rolled back).

do $$
declare
  v_checks int := 0;
  v_u uuid := gen_random_uuid();
  v_v uuid := gen_random_uuid();
  v_rec record;
  v_txt text;
  v_bad text;
  v_state text;
  v_msg text;
  v_n int;
  -- Moderation M1 part 1 is in when its table exists.
  v_m1 boolean := to_regclass('public.blocks') is not null;
  v_expected_fns text[] := array[
    'acknowledge_deal_cut', 'can_read_game', 'can_read_table', 'chat_topic_allows', 'claim_win',
    'clear_win_claim', 'computer_acknowledge_deal_cut', 'computer_confirm_count', 'computer_discard_to_crib',
    'computer_draw_cut_card', 'computer_hand', 'computer_next_hand', 'computer_play_card', 'computer_show_crib',
    'computer_start_game_with_deal', 'confirm_count', 'confirm_win', 'create_computer_table', 'create_table',
    'discard_to_crib', 'draw_cut_card', 'follow_user', 'get_computer_profiles', 'get_god_wins',
    'get_leaderboard', 'get_my_follows', 'get_solo_leaderboard', 'get_solo_stats', 'get_spectator_reveals',
    'get_table_spectators', 'is_admin', 'is_current_spectator', 'is_game_player', 'is_public_table',
    'is_table_member', 'join_table_by_code', 'leave_computer_table', 'leave_table', 'next_hand', 'play_card',
    'remove_spectator', 'set_seat', 'show_crib', 'show_hand', 'spectator_heartbeat', 'start_game_with_deal',
    'stop_watching', 'unfollow_user', 'watch_table'];
begin
  if array_length(v_expected_fns, 1) <> 49 then
    raise exception 'SETUP: the expected function list has % names; expected 49.', array_length(v_expected_fns, 1);
  end if;
  if v_m1 then
    v_expected_fns := v_expected_fns || array['block_player', 'get_my_blocks', 'unblock_player'];
    if array_length(v_expected_fns, 1) <> 52 then
      raise exception 'SETUP: the expected function list has % names after moderation M1 part 1; expected 52.', array_length(v_expected_fns, 1);
    end if;
  end if;

  -- ==== T: tables ===================================================================
  -- [T1] Every table's exact privileges for authenticated / anon / PUBLIC.
  with expected(tbl, auth_want, anon_want) as (
    values
      ('tables', 'SELECT, UPDATE', 'SELECT'),
      ('table_members', 'SELECT', 'SELECT'),
      ('games', 'SELECT, UPDATE', 'SELECT'),
      ('game_plays', 'SELECT', 'SELECT'),
      ('game_hands', 'SELECT', 'SELECT'),
      ('game_cribs', 'SELECT', 'SELECT'),
      ('game_decks', 'SELECT', 'SELECT'),
      ('profiles', 'INSERT, SELECT, UPDATE', 'SELECT'),
      ('admin_users', 'SELECT', 'SELECT'),
      ('user_appearance', 'INSERT, SELECT, UPDATE', ''),
      ('table_spectators', 'SELECT', ''),
      ('attempt_log', '', ''),
      ('computer_accounts', '', ''),
      ('follows', '', ''),
      ('game_results', '', ''),
      ('leaderboard_hidden', '', '')
    union all
    -- Moderation M1's Block List: no client privileges at all.
    select 'blocks', '', '' where v_m1
  ),
  actual as (
    select c.relname::text as tbl,
           coalesce((select string_agg(a.privilege_type, ', ' order by a.privilege_type)
                     from aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
                     where a.grantee = (select r.oid from pg_roles r where r.rolname = 'authenticated')), '') as auth_has,
           coalesce((select string_agg(a.privilege_type, ', ' order by a.privilege_type)
                     from aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
                     where a.grantee = (select r.oid from pg_roles r where r.rolname = 'anon')), '') as anon_has,
           coalesce((select string_agg(a.privilege_type, ', ' order by a.privilege_type)
                     from aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
                     where a.grantee = 0), '') as public_has
    from pg_class c
    join pg_namespace ns on ns.oid = c.relnamespace
    where ns.nspname = 'public' and c.relkind in ('r', 'p')
  )
  select string_agg(coalesce(a.tbl, e.tbl) || ' [' ||
                      case when a.tbl is null then 'missing'
                           when e.tbl is null then 'not known to this suite: authenticated ' || coalesce(nullif(a.auth_has, ''), 'none')
                                                   || ' / anon ' || coalesce(nullif(a.anon_has, ''), 'none')
                           else 'authenticated ' || coalesce(nullif(a.auth_has, ''), 'none') || ' (want ' || coalesce(nullif(e.auth_want, ''), 'none') || ')'
                                || ' / anon ' || coalesce(nullif(a.anon_has, ''), 'none') || ' (want ' || coalesce(nullif(e.anon_want, ''), 'none') || ')'
                                || ' / PUBLIC ' || coalesce(nullif(a.public_has, ''), 'none') end || ']', '; ')
  into v_bad
  from actual a
  full join expected e on e.tbl = a.tbl
  where a.tbl is null or e.tbl is null
     or a.auth_has <> e.auth_want or a.anon_has <> e.anon_want or a.public_has <> '';
  if v_bad is not null then
    raise exception 'FAIL [T1] table privileges differ: %.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [T2] No column-level grants.
  select string_agg(c.relname::text || '.' || att.attname::text, ', ') into v_bad
  from pg_class c
  join pg_namespace ns on ns.oid = c.relnamespace
  join pg_attribute att on att.attrelid = c.oid and att.attnum > 0 and not att.attisdropped and att.attacl is not null
  where ns.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'f');
  if v_bad is not null then
    raise exception 'FAIL [T2] column-level grants exist on: %.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== X: functions ================================================================
  -- [X1] anon: none; PUBLIC: none; authenticated: exactly the 49 names.
  select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text) into v_bad
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.prokind in ('f', 'p')
    and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
    and (has_function_privilege('anon', p.oid, 'EXECUTE')
         or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0));
  if v_bad is not null then
    raise exception 'FAIL [X1] executable by anon or granted to PUBLIC: %.', v_bad;
  end if;
  with open_fns as (
    select distinct p.proname::text as name
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.prokind in ('f', 'p')
      and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')
  )
  select concat_ws('; ',
           'not expected: ' || (select string_agg(o.name, ', ' order by o.name) from open_fns o where o.name <> all(v_expected_fns)),
           'expected but closed or missing: ' || (select string_agg(e.name, ', ' order by e.name) from unnest(v_expected_fns) as e(name)
                                                  where e.name not in (select o.name from open_fns o)))
  into v_bad;
  if v_bad <> '' then
    raise exception 'FAIL [X1] functions authenticated may execute differ from the expected % (49, or 52 after moderation M1 part 1): %.', array_length(v_expected_fns, 1), v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [X2] A new function made in public by this role is closed to clients.
  execute 'create function public.slice_e_probe_fn() returns integer language sql as ''select 1''';
  if has_function_privilege('anon', 'public.slice_e_probe_fn()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.slice_e_probe_fn()', 'EXECUTE')
     or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where p.oid = to_regprocedure('public.slice_e_probe_fn()') and a.grantee = 0) then
    select coalesce(p.proacl::text, '(null: the built-in default, EXECUTE for PUBLIC)') into v_txt
    from pg_proc p where p.oid = to_regprocedure('public.slice_e_probe_fn()');
    raise exception 'FAIL [X2] a new function created in public by % is open to clients (acl %): the default privileges are NOT closed. Run docs/sql/slice-e-part3.sql (its section 3); until then every new function must revoke from public, anon and authenticated itself.', current_user, v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [X4] postgres's global default ACL for functions: present, postgres only.
  select da.defaclacl::text into v_txt
  from pg_default_acl da
  where da.defaclrole = 'postgres'::regrole and da.defaclnamespace = 0 and da.defaclobjtype = 'f';
  if v_txt is null
     or exists (select 1 from pg_default_acl da, aclexplode(da.defaclacl) a
                where da.defaclrole = 'postgres'::regrole and da.defaclnamespace = 0 and da.defaclobjtype = 'f'
                  and a.grantee <> 'postgres'::regrole) then
    raise exception 'FAIL [X4] postgres''s global default ACL for functions is %; expected a row granting EXECUTE to postgres only ({postgres=X/postgres}). Run docs/sql/slice-e-part3.sql.', coalesce(v_txt, '(no row: PUBLIC gets EXECUTE on every new function)');
  end if;
  v_checks := v_checks + 1;

  -- [X3] rls_auto_enable(): closed, its event trigger still on.
  if to_regprocedure('public.rls_auto_enable()') is not null then
    if has_function_privilege('anon', 'public.rls_auto_enable()', 'EXECUTE')
       or has_function_privilege('authenticated', 'public.rls_auto_enable()', 'EXECUTE')
       or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                  where p.oid = to_regprocedure('public.rls_auto_enable()') and a.grantee = 0)
       or not exists (select 1 from pg_event_trigger e
                      where e.evtfoid = to_regprocedure('public.rls_auto_enable()') and e.evtenabled <> 'D') then
      raise exception 'FAIL [X3] rls_auto_enable(): a client can still execute it, or no enabled event trigger runs it.';
    end if;
  end if;
  v_checks := v_checks + 1;

  -- ==== S: the avatar storage policies ===============================================
  begin
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'seg-' || v_u::text || '@verification.invalid', now() - interval '1 hour', now()),
           (v_v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'seg-' || v_v::text || '@verification.invalid', now() - interval '1 hour', now());
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts: % (%).', sqlerrm, sqlstate;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u, 'role', 'authenticated')::text, true);

  -- [S1] U's own folder, the fixed names.
  v_state := null;
  begin
    execute 'set local role authenticated';
    insert into storage.objects (bucket_id, name) values ('avatars', v_u::text || '/avatar.png');
    insert into storage.objects (bucket_id, name) values ('avatars', v_u::text || '/avatar.jpeg');
    execute 'reset role';
  exception when others then
    v_state := sqlstate;
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_state is not null then
    raise exception 'FAIL [S1] U writing %/avatar.png and avatar.jpeg was refused: % (%).%', v_u, v_state, v_msg,
      case when v_state <> '42501' then ' Not a row-policy refusal: storage.objects may not accept a direct write in this project; check by hand.' else '' end;
  end if;
  v_checks := v_checks + 1;

  -- [S2] Another user's folder.
  v_state := null;
  begin
    execute 'set local role authenticated';
    insert into storage.objects (bucket_id, name) values ('avatars', v_v::text || '/avatar.png');
    execute 'reset role';
  exception when others then
    v_state := sqlstate;
  end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [S2] U writing into V''s folder: %; expected 42501.', coalesce(v_state, 'allowed');
  end if;
  v_checks := v_checks + 1;

  -- [S3] Other file names in U's folder.
  v_bad := '';
  for v_txt in select unnest(array['photo.png', 'avatar.gif', 'avatar.png.exe', 'sub/avatar.png'])
  loop
    v_state := null;
    begin
      execute 'set local role authenticated';
      insert into storage.objects (bucket_id, name) values ('avatars', v_u::text || '/' || v_txt);
      execute 'reset role';
    exception when others then
      v_state := sqlstate;
    end;
    execute 'reset role';
    if v_state is distinct from '42501' then
      v_bad := v_bad || v_txt || ': ' || coalesce(v_state, 'allowed') || '; ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [S3] other file names in U''s folder: %expected 42501 each.', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [S4] An upper-case extension.
  v_state := null;
  begin
    execute 'set local role authenticated';
    insert into storage.objects (bucket_id, name) values ('avatars', v_u::text || '/avatar.PNG');
    execute 'reset role';
  exception when others then
    v_state := sqlstate;
  end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [S4] U writing %/avatar.PNG: %; expected 42501.', v_u, coalesce(v_state, 'allowed');
  end if;
  v_checks := v_checks + 1;

  -- [S5] Renaming U's own avatar.png to another name.
  v_state := null;
  begin
    execute 'set local role authenticated';
    update storage.objects set name = v_u::text || '/evil.png'
    where bucket_id = 'avatars' and name = v_u::text || '/avatar.png';
    get diagnostics v_n = row_count;
    execute 'reset role';
  exception when others then
    v_state := sqlstate;
  end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [S5] U renaming avatar.png to evil.png: % (% row(s)); expected 42501.', coalesce(v_state, 'allowed'), coalesce(v_n, 0);
  end if;
  v_checks := v_checks + 1;

  -- ==== C: fingerprints ================================================================
  -- [C1] The four fingerprinted bodies, unchanged.
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
      raise exception 'FAIL [C1] % has body md5 %; expected % (LF) or % (CRLF).', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf, v_rec.crlf;
    end if;
  end loop;
  v_checks := v_checks + 1;

  if v_checks <> 12 then
    raise exception 'FAIL: % checks ran, expected 12.', v_checks;
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back).', v_checks;
end;
$$;
