-- NICKNAME RULES: VERIFICATION (docs/sql/nickname-rules-part1.sql).
--
-- Run in the Supabase Dashboard -> SQL Editor after part 1. The whole file
-- is ONE DO block.
--
-- STATUS: RUN 2026-11-28: ALL 19 CHECKS PASSED (rolled back; nothing kept).
--
-- DEPLOY ORDER: precheck -> part 1 -> precheck again -> THIS FILE -> the
-- regression suites (slice-e-ratelimits-verification.sql: its N4 is
-- state-aware for this slice; slice-e-grants-verification.sql;
-- slice-e-precheck.sql: its part2 row accepts the second trigger) -> the
-- app (a later step).
--
-- It WRITES -- temporary functions in pg_temp (nr_as: runs one statement as
-- a client role and returns its result or its error; nr_try: one upsert of
-- a nickname exactly as the app sends it, then compares the outcome),
-- temporary accounts in auth.users and their profiles; it re-saves D$'s own
-- nickname and gives the easy computer account two test nicknames -- and
-- then deliberately raises an exception at the very end, which rolls EVERY
-- write back (D$ and the computer included). A check that fails raises its
-- own exception at once, which rolls everything back the same way. It
-- always "fails": the message is the verdict.
--   "ALL 19 CHECKS PASSED (rolled back)." is a pass.
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives. Impersonation:
-- request.jwt.claims plus "set local role authenticated", inside nr_as;
-- "reset role" to act as the owner.
--
-- TEST NAMES: every name that must be SAVED starts with a random base of 8
-- letters from "bcdfghjkpqxz" (no letter the skeleton maps, so it can't
-- collide with a real player; checked at SETUP), shown below as <b>. Names
-- that must be refused for a reserved word need no base.
--
-- PEOPLE: A (holds <b>Walt), B (the usual tester, reset to '' with no lock
-- before most tries), C and D (hold <b>Walt2 / <b>Walt3), E (tries
-- <b>Walt!), G (an old name that breaks the rules, <b>' G$'), GE (an old
-- emoji name), GP1 / GP2 (an old look-alike pair, <b>Pal / <b>Pa1), L
-- (locked: changed_at now), N (a new account with no profile row), the easy
-- computer account, and the real D$ (61c4672c-18f3-45b6-b6bf-a8c014a59142).
--
-- WHAT IT CHECKS
--   K1  profiles_nickname_rules(): part 1's body (md5
--       f3782effb78974e2ef65f1d8db04aa5a), plpgsql, returns trigger,
--       security invoker, search_path '', executable by no role; the
--       trigger: enabled, BEFORE INSERT OR UPDATE FOR EACH ROW, no column
--       list, no WHEN; profiles' triggers are exactly profiles_nickname_lock,
--       profiles_nickname_rules (the lock sorts, and fires, first).
--   K2  untouched: profiles_nickname_lock's body (md5
--       215515390acc9b410afbd71b210d31e0) and trigger;
--       profiles_nickname_unique_idx; get_computer_profiles() security
--       definer and executable by authenticated.
--   K3  EXECUTE: profiles_nickname_rules for no client role; authenticated
--       may execute at least 61 functions in public (the exact list is
--       slice-e-grants-verification.sql's job).
--   C1  CHARACTERS: <b> plus an emoji, an accented letter, a Cyrillic a, a
--       zero-width space, a tab, a non-breaking space, $, @, #, |, and D$ ->
--       P0001 nickname_invalid "Nicknames can use letters, numbers, spaces
--       and . - _ ' ! only."; nothing saved.
--   C2  LENGTH, EMPTY, SPACING, LETTER: '' and '   ' (from a real name) ->
--       "Please enter a nickname."; 31 characters -> "Nicknames are at most
--       30 characters."; a leading, a trailing and a double space ->
--       "Nicknames can't start or end with a space or have two spaces in a
--       row."; '...', '!!!', '- _' -> "Nicknames need at least one letter or
--       number."; all nickname_invalid, nothing saved.
--   C3  ALLOWED: 30 characters; every allowed mark (<b> O'Neil-Smith_Jr.
--       Go!); digits -> saved exactly.
--   C4  LOOK-ALIKES of <b>Walt (held by A): <b>Wa1t, WaIt, Wal_t, Wa!t,
--       W a l t, VValt, WALT, walt -> P0001 nickname_taken "That nickname is
--       taken."; also from a non-empty name (B keeps it, no lock stamped).
--   C5  EXACT DUPLICATE: a client's <b>Walt -> P0001 nickname_taken (the
--       trigger, before the index); the owner's -> 23505 from
--       profiles_nickname_unique_idx (the backstop, still there).
--   C6  AN ADDED DIGIT IS ANOTHER NAME: <b>Walt1 (B), <b>Walt2 (C), <b>Walt3
--       (D) saved next to <b>Walt; all four coexist.
--   C7  "Walt!": E's <b>Walt! is refused while B holds <b>Walt1 (! and 1
--       both read as l), and saved once B has moved away -- next to <b>Walt,
--       <b>Walt2 and <b>Walt3.
--   C8  RESERVED: Admin, ADMIN, Adm1n, AdmIn, Adrnin, Admin Bob, TheAdmin,
--       Staff_Mike, Sup port, Supp0rt, Moderator, M0derator, Moderatorn,
--       Administrator, Official, 0ffic1al, Raynewood, Rayne Wood,
--       Raynevvood, Staff, Support, and Badminton (the accepted false
--       positive) -> P0001 nickname_unavailable "That nickname isn't
--       available."; nothing saved.
--   C9  NOT RESERVED: <b> Swollen Nobs, <b> Nobs, <b> Modern, <b> Model,
--       <b> Mod Squad, <b> Moderate, <b> Commode -> saved.
--   C10 THE SAME NICKNAME NEVER FAILS: G (<b> G$), GE (emoji), GP2 (<b>Pa1,
--       the look-alike of GP1's <b>Pal) and A re-save their own names
--       through the upsert; G also through the Profile page's upsert (with
--       avatar_url) and an avatar-only update; L (locked) re-saves its name
--       and its lock is unchanged -> all saved. G's case change (<b> g$) is
--       a change: refused nickname_invalid, G keeps <b> G$.
--   C11 D$: the real D$ re-saves "D$" through the upsert -> no error;
--       nickname and nickname_changed_at unchanged.
--   C12 THE INSERT PATH: N (no profile row) tries <b>Wa1t (taken), <b>x@y
--       (invalid) and Staff (unavailable) -> refused, still no row; then
--       <b>Newbie -> a new row, nickname_changed_at null.
--   C13 ORDER WITH THE LOCK: L (locked) tries <b>Wa1t and an emoji name ->
--       nickname_locked "You can change your nickname again in 7 days." (the
--       lock fires first), L's name unchanged; B's real change <b>Bee ->
--       <b>Bee2 passes the rules and the lock stamps it now().
--   C14 EXEMPT, THE OWNER: the SQL Editor sets C to <b> + emoji + Admin,
--       then to <b>WaIt (a look-alike of <b>Walt) -> both saved.
--   C15 EXEMPT, THE COMPUTER: the easy computer account (signed in as
--       itself) saves <b> Wa1t Staff$ and then <b>Wa1t -> both saved (a
--       person is refused both: C1/C4/C8).
--   C16 THE ADVISORY LOCK: after B saves <b>Lockcheck, this transaction
--       holds the advisory lock on hashtextextended('nickname:' ||
--       skeleton, 0).

do $$
declare
  v_checks int := 0;
  v_expect int := 19;
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid();
  v_e uuid := gen_random_uuid();
  v_g uuid := gen_random_uuid();
  v_ge uuid := gen_random_uuid();
  v_gp1 uuid := gen_random_uuid();
  v_gp2 uuid := gen_random_uuid();
  v_l uuid := gen_random_uuid();
  v_n uuid := gen_random_uuid();
  v_dollar uuid := '61c4672c-18f3-45b6-b6bf-a8c014a59142';
  v_comp uuid;
  v_people uuid[];
  v_pid uuid;
  v_base text;
  v_name text;
  v_skel text;
  v_key bigint;
  v_when timestamptz;
  v_when2 timestamptz;
  v_txt text;
  v_bad text;
  v_i int;
  v_r text[];
  m_chars constant text := 'Nicknames can use letters, numbers, spaces and . - _ '' ! only.';
  m_empty constant text := 'Please enter a nickname.';
  m_long constant text := 'Nicknames are at most 30 characters.';
  m_space constant text := 'Nicknames can''t start or end with a space or have two spaces in a row.';
  m_letter constant text := 'Nicknames need at least one letter or number.';
  m_taken constant text := 'That nickname is taken.';
  m_unavail constant text := 'That nickname isn''t available.';
  m_locked constant text := 'You can change your nickname again in 7 days.';
begin
  -- ==== MODE ======================================================================
  if to_regprocedure('public.profiles_nickname_rules()') is null
     or not exists (select 1 from pg_trigger tg where tg.tgrelid = 'public.profiles'::regclass and tg.tgname = 'profiles_nickname_rules') then
    raise exception 'SETUP: part 1 is not in (no profiles_nickname_rules function or trigger). Run docs/sql/nickname-rules-part1.sql first.';
  end if;

  -- nr_as(role, user, sql): runs one statement as that client role (the
  -- user as auth.uid(), or nobody when null) and returns
  -- {sqlstate, message, detail, hint, first column of the first row} --
  -- the error fields null when it worked. Rolled back with everything else.
  create function pg_temp.nr_as(p_role text, p_uid uuid, p_sql text)
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

  -- nr_try(user, name, detail, message, fresh): (fresh: first, as the owner,
  -- the user's nickname set to '' and the lock cleared) then the app's
  -- upsert of that name as the user. With a null detail the save must work
  -- and store the name exactly; otherwise it must fail with P0001, that
  -- detail and that message (or the lock's own SQLSTATE P0001 / detail),
  -- and leave the stored nickname as it was. Returns '' or what went wrong.
  create function pg_temp.nr_try(p_uid uuid, p_name text, p_detail text, p_msg text, p_fresh boolean)
  returns text
  language plpgsql
  as $f$
  declare
    v_before text;
    v_after text;
    v_r text[];
  begin
    if p_fresh then
      update public.profiles set nickname = '', nickname_changed_at = null where id = p_uid;
    end if;
    select pr.nickname into v_before from public.profiles pr where pr.id = p_uid;
    v_r := pg_temp.nr_as('authenticated', p_uid,
             format('insert into public.profiles as pr (id, nickname) values (%L, %L) '
                    'on conflict (id) do update set id = excluded.id, nickname = excluded.nickname returning pr.nickname',
                    p_uid, p_name));
    select pr.nickname into v_after from public.profiles pr where pr.id = p_uid;
    if p_detail is null then
      if v_r[1] is not null then
        return quote_literal(p_name) || ' refused ' || v_r[1] || '/' || coalesce(v_r[3], '-') || ' "' || coalesce(v_r[2], '') || '" (want saved); ';
      end if;
      if v_after is distinct from p_name then
        return quote_literal(p_name) || ' stored as ' || coalesce(quote_literal(v_after), 'no row') || '; ';
      end if;
      return '';
    end if;
    if v_r[1] is distinct from 'P0001' or v_r[3] is distinct from p_detail or v_r[2] is distinct from p_msg then
      return quote_literal(p_name) || ': ' || coalesce(v_r[1], 'saved') || '/' || coalesce(v_r[3], '-') || ' "' || coalesce(v_r[2], '') || '" (want P0001/' || p_detail || ' "' || p_msg || '"); ';
    end if;
    if v_after is distinct from v_before then
      return quote_literal(p_name) || ' refused but the nickname became ' || coalesce(quote_literal(v_after), 'no row') || '; ';
    end if;
    return '';
  end;
  $f$;

  -- ==== K: CATALOG ================================================================
  -- [K1] The new function and trigger.
  v_bad := '';
  select case when md5(replace(p.prosrc, E'\r', '')) <> 'f3782effb78974e2ef65f1d8db04aa5a' then 'body md5 ' || md5(replace(p.prosrc, E'\r', '')) || '; ' else '' end
         || case when l.lanname <> 'plpgsql' then 'language ' || l.lanname || '; ' else '' end
         || case when p.prorettype <> 'trigger'::regtype then 'does not return trigger; ' else '' end
         || case when p.prosecdef then 'security definer; ' else '' end
         || case when not (coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']) then 'search_path not empty; ' else '' end
         || case when has_function_privilege('authenticated', p.oid, 'EXECUTE') then 'authenticated EXECUTE; ' else '' end
         || case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon EXECUTE; ' else '' end
         || case when exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) then 'PUBLIC EXECUTE; ' else '' end
         || case when exists (select 1 from pg_roles r where r.rolname = 'service_role')
                  and has_function_privilege('service_role', p.oid, 'EXECUTE') then 'service_role EXECUTE; ' else '' end
  into v_txt
  from pg_proc p join pg_language l on l.oid = p.prolang
  where p.oid = to_regprocedure('public.profiles_nickname_rules()');
  v_bad := v_bad || coalesce(v_txt, 'function missing; ');
  if not exists (select 1 from pg_trigger tg
                 where tg.tgrelid = 'public.profiles'::regclass and tg.tgname = 'profiles_nickname_rules'
                   and not tg.tgisinternal and tg.tgenabled = 'O'
                   and tg.tgfoid = to_regprocedure('public.profiles_nickname_rules()')
                   and tg.tgtype = 1 + 2 + 4 + 16
                   and cardinality(tg.tgattr::int2[]) = 0
                   and tg.tgqual is null) then
    v_bad := v_bad || 'trigger not an enabled BEFORE INSERT OR UPDATE ROW trigger without columns or WHEN; ';
  end if;
  select string_agg(tg.tgname::text, ', ' order by tg.tgname) into v_txt
  from pg_trigger tg where tg.tgrelid = 'public.profiles'::regclass and not tg.tgisinternal;
  if v_txt is distinct from 'profiles_nickname_lock, profiles_nickname_rules' then
    v_bad := v_bad || 'profiles triggers "' || coalesce(v_txt, 'none') || '"; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K1] %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K2] What part 1 must leave alone.
  v_bad := '';
  select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure('public.profiles_nickname_lock()');
  if v_txt is distinct from '215515390acc9b410afbd71b210d31e0' then
    v_bad := v_bad || 'profiles_nickname_lock md5 ' || coalesce(v_txt, 'missing') || '; ';
  end if;
  if not exists (select 1 from pg_trigger tg
                 where tg.tgrelid = 'public.profiles'::regclass and tg.tgname = 'profiles_nickname_lock'
                   and not tg.tgisinternal and tg.tgenabled = 'O'
                   and tg.tgfoid = to_regprocedure('public.profiles_nickname_lock()')
                   and tg.tgtype = 1 + 2 + 4 + 16) then
    v_bad := v_bad || 'the lock trigger changed; ';
  end if;
  if not exists (select 1 from pg_index i where i.indexrelid = to_regclass('public.profiles_nickname_unique_idx')
                   and i.indisunique and i.indisvalid and strpos(pg_get_indexdef(i.indexrelid), 'lower(btrim(nickname))') > 0) then
    v_bad := v_bad || 'profiles_nickname_unique_idx missing or changed; ';
  end if;
  if to_regprocedure('public.get_computer_profiles()') is null
     or not (select p.prosecdef from pg_proc p where p.oid = to_regprocedure('public.get_computer_profiles()'))
     or not has_function_privilege('authenticated', 'public.get_computer_profiles()', 'EXECUTE') then
    v_bad := v_bad || 'get_computer_profiles() missing, not security definer or not executable by authenticated; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [K2] %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [K3] EXECUTE.
  select count(distinct p.proname) into v_i
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.prokind in ('f', 'p')
    and not exists (select 1 from pg_depend dp where dp.classid = 'pg_proc'::regclass and dp.objid = p.oid and dp.deptype = 'e')
    and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  if has_function_privilege('authenticated', 'public.profiles_nickname_rules()', 'EXECUTE')
     or has_function_privilege('anon', 'public.profiles_nickname_rules()', 'EXECUTE')
     or v_i < 61 then
    raise exception 'FAIL [K3] EXECUTE: authenticated may execute % functions in public (want at least 61), and profiles_nickname_rules must be executable by no client role.', v_i;
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner =========================================================
  select ca.user_id into v_comp from public.computer_accounts ca where ca.level = 'easy';
  if v_comp is null then
    raise exception 'SETUP: no easy computer account (computer-accounts-setup.sql).';
  end if;
  if not exists (select 1 from public.profiles pr where pr.id = v_dollar and pr.nickname = 'D$') then
    raise exception 'SETUP: D$ (61c4672c-18f3-45b6-b6bf-a8c014a59142) has no profile with the nickname "D$" any more (nickname-rules-precheck.sql, data row 600). Tell Walt before changing C11.';
  end if;

  -- The random base, and proof no real nickname's skeleton contains it.
  for v_i in 1 .. 20 loop
    select string_agg(substr('bcdfghjkpqxz', 1 + floor(random() * 12)::int, 1), '') into v_base from generate_series(1, 8);
    exit when not exists (
      select 1 from public.profiles pr
      where strpos(replace(replace(translate(translate(lower(translate(btrim(pr.nickname), 'I|1!', 'llll')), ' .-_''', ''), '0', 'o'), 'rn', 'm'), 'vv', 'w'), v_base) > 0);
    v_base := null;
  end loop;
  if v_base is null then
    raise exception 'SETUP: could not pick a test base no nickname contains (20 tries).';
  end if;

  v_people := array[v_a, v_b, v_c, v_d, v_e, v_g, v_ge, v_gp1, v_gp2, v_l, v_n];
  begin
    foreach v_pid in array v_people loop
      insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
      values (v_pid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
              'nr-' || v_pid::text || '@verification.invalid', now() - interval '1 hour', now());
    end loop;
    -- As the owner (exempt): old names that break today's rules are set
    -- directly, the way they exist in the live data. N gets no row at all
    -- (deleted, in case something creates one for a new account).
    foreach v_pid in array v_people loop
      insert into public.profiles (id, nickname)
      values (v_pid, case v_pid
                       when v_a then v_base || 'Walt'
                       when v_g then v_base || ' G$'
                       when v_ge then v_base || chr(128512)
                       when v_gp1 then v_base || 'Pal'
                       when v_gp2 then v_base || 'Pa1'
                       when v_l then v_base || 'Locked'
                       else '' end)
      on conflict (id) do update set nickname = excluded.nickname, nickname_changed_at = null;
    end loop;
    update public.profiles set nickname_changed_at = now() where id = v_l;
    delete from public.profiles where id = v_n;
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts and profiles: % (%).', sqlerrm, sqlstate;
  end;

  -- ==== C: THE RULES ================================================================
  -- [C1] Characters outside the set.
  v_bad := '';
  foreach v_name in array array[
    v_base || chr(128512), v_base || chr(233), v_base || 'W' || chr(1072) || 'lt', v_base || chr(8203),
    v_base || chr(9) || 'x', v_base || chr(160) || 'x', v_base || '$', v_base || '@x', v_base || '#',
    v_base || '|', 'D$'] loop
    v_bad := v_bad || pg_temp.nr_try(v_b, v_name, 'nickname_invalid', m_chars, true);
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [C1] characters: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C2] Length, empty, spacing, no letter or digit.
  v_bad := '';
  update public.profiles set nickname = v_base || 'Bee', nickname_changed_at = null where id = v_b;
  v_bad := v_bad || pg_temp.nr_try(v_b, '', 'nickname_invalid', m_empty, false);
  v_bad := v_bad || pg_temp.nr_try(v_b, '   ', 'nickname_invalid', m_empty, false);
  v_bad := v_bad || pg_temp.nr_try(v_b, v_base || repeat('x', 23), 'nickname_invalid', m_long, true);
  v_bad := v_bad || pg_temp.nr_try(v_b, ' ' || v_base, 'nickname_invalid', m_space, true);
  v_bad := v_bad || pg_temp.nr_try(v_b, v_base || ' ', 'nickname_invalid', m_space, true);
  v_bad := v_bad || pg_temp.nr_try(v_b, v_base || '  x', 'nickname_invalid', m_space, true);
  v_bad := v_bad || pg_temp.nr_try(v_b, '...', 'nickname_invalid', m_letter, true);
  v_bad := v_bad || pg_temp.nr_try(v_b, '!!!', 'nickname_invalid', m_letter, true);
  v_bad := v_bad || pg_temp.nr_try(v_b, '- _', 'nickname_invalid', m_letter, true);
  if v_bad <> '' then
    raise exception 'FAIL [C2] length / empty / spacing / letter: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C3] Allowed.
  v_bad := '';
  if char_length(v_base || repeat('x', 22)) <> 30 or char_length(v_base || ' O''Neil-Smith_Jr. Go!') > 30 then
    raise exception 'SETUP: the C3 test names are not the intended lengths.';
  end if;
  v_bad := v_bad || pg_temp.nr_try(v_b, v_base || repeat('x', 22), null, null, true);
  v_bad := v_bad || pg_temp.nr_try(v_b, v_base || ' O''Neil-Smith_Jr. Go!', null, null, true);
  v_bad := v_bad || pg_temp.nr_try(v_b, v_base || ' 42', null, null, true);
  if v_bad <> '' then
    raise exception 'FAIL [C3] allowed names: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C4] Look-alikes of <b>Walt (A).
  v_bad := '';
  foreach v_name in array array[
    v_base || 'Wa1t', v_base || 'WaIt', v_base || 'Wal_t', v_base || 'Wa!t', v_base || 'W a l t',
    v_base || 'VValt', v_base || 'WALT', v_base || 'walt'] loop
    v_bad := v_bad || pg_temp.nr_try(v_b, v_name, 'nickname_taken', m_taken, true);
  end loop;
  -- From a non-empty name: B keeps it, and no lock is stamped.
  update public.profiles set nickname = v_base || 'Bee', nickname_changed_at = null where id = v_b;
  v_bad := v_bad || pg_temp.nr_try(v_b, v_base || 'Wa1t', 'nickname_taken', m_taken, false);
  if (select pr.nickname_changed_at from public.profiles pr where pr.id = v_b) is not null then
    v_bad := v_bad || 'a refused change stamped nickname_changed_at; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [C4] look-alikes: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C5] An exact duplicate: the trigger for a client, the index for the owner.
  v_bad := pg_temp.nr_try(v_b, v_base || 'Walt', 'nickname_taken', m_taken, true);
  v_txt := null;
  begin
    update public.profiles set nickname = v_base || 'Walt' where id = v_c;
  exception when others then
    v_txt := sqlstate;
  end;
  if v_txt is distinct from '23505' then
    v_bad := v_bad || 'the owner''s exact duplicate gave ' || coalesce(v_txt, 'no error') || ' (want 23505 from profiles_nickname_unique_idx); ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [C5] exact duplicate: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C6] An added digit is another name.
  v_bad := '';
  v_bad := v_bad || pg_temp.nr_try(v_b, v_base || 'Walt1', null, null, true);
  v_bad := v_bad || pg_temp.nr_try(v_c, v_base || 'Walt2', null, null, true);
  v_bad := v_bad || pg_temp.nr_try(v_d, v_base || 'Walt3', null, null, true);
  select count(*) into v_i from public.profiles pr
  where pr.nickname in (v_base || 'Walt', v_base || 'Walt1', v_base || 'Walt2', v_base || 'Walt3');
  if v_i <> 4 then
    v_bad := v_bad || v_i::text || ' of Walt / Walt1 / Walt2 / Walt3 stored (want 4); ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [C6] added digits: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C7] "Walt!": refused next to Walt1 (its look-alike), saved next to Walt.
  v_bad := '';
  v_bad := v_bad || pg_temp.nr_try(v_e, v_base || 'Walt!', 'nickname_taken', m_taken, true);
  update public.profiles set nickname = '', nickname_changed_at = null where id = v_b;
  v_bad := v_bad || pg_temp.nr_try(v_e, v_base || 'Walt!', null, null, true);
  select count(*) into v_i from public.profiles pr
  where pr.nickname in (v_base || 'Walt', v_base || 'Walt!', v_base || 'Walt2', v_base || 'Walt3');
  if v_i <> 4 then
    v_bad := v_bad || v_i::text || ' of Walt / Walt! / Walt2 / Walt3 stored (want 4); ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [C7] Walt!: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C8] Reserved words (contains, look-alikes included).
  v_bad := '';
  foreach v_name in array array[
    'Admin', 'ADMIN', 'Adm1n', 'AdmIn', 'Adrnin', 'Admin Bob', 'TheAdmin', 'Staff_Mike', 'Sup port', 'Supp0rt',
    'Moderator', 'M0derator', 'Moderatorn', 'Administrator', 'Official', '0ffic1al', 'Raynewood', 'Rayne Wood',
    'Raynevvood', 'Staff', 'Support', 'Badminton'] loop
    v_bad := v_bad || pg_temp.nr_try(v_b, v_name, 'nickname_unavailable', m_unavail, true);
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [C8] reserved words: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C9] Not reserved: Nobs and the Mod words.
  v_bad := '';
  foreach v_name in array array[
    v_base || ' Swollen Nobs', v_base || ' Nobs', v_base || ' Modern', v_base || ' Model', v_base || ' Mod Squad',
    v_base || ' Moderate', v_base || ' Commode'] loop
    v_bad := v_bad || pg_temp.nr_try(v_b, v_name, null, null, true);
  end loop;
  if v_bad <> '' then
    raise exception 'FAIL [C9] not reserved: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C10] The same nickname never fails.
  v_bad := '';
  v_bad := v_bad || pg_temp.nr_try(v_g, v_base || ' G$', null, null, false);
  v_bad := v_bad || pg_temp.nr_try(v_ge, v_base || chr(128512), null, null, false);
  v_bad := v_bad || pg_temp.nr_try(v_gp2, v_base || 'Pa1', null, null, false);
  v_bad := v_bad || pg_temp.nr_try(v_a, v_base || 'Walt', null, null, false);
  -- The Profile page's upsert (with the picture) and an avatar-only update.
  v_r := pg_temp.nr_as('authenticated', v_g,
           format('insert into public.profiles as pr (id, nickname, avatar_url) values (%L, %L, null) '
                  'on conflict (id) do update set id = excluded.id, nickname = excluded.nickname, avatar_url = excluded.avatar_url returning pr.nickname',
                  v_g, v_base || ' G$'));
  if v_r[1] is not null or v_r[5] is distinct from v_base || ' G$' then
    v_bad := v_bad || 'G''s Profile page upsert: ' || coalesce(v_r[1], 'ok') || ' "' || coalesce(v_r[2], '') || '"; ';
  end if;
  v_r := pg_temp.nr_as('authenticated', v_g, format('update public.profiles set avatar_url = null where id = %L returning nickname', v_g));
  if v_r[1] is not null or v_r[5] is distinct from v_base || ' G$' then
    v_bad := v_bad || 'G''s avatar-only update: ' || coalesce(v_r[1], 'ok') || ' "' || coalesce(v_r[2], '') || '"; ';
  end if;
  -- L is locked: the same name is still no change, and the lock stays.
  select pr.nickname_changed_at into v_when from public.profiles pr where pr.id = v_l;
  v_bad := v_bad || pg_temp.nr_try(v_l, v_base || 'Locked', null, null, false);
  if (select pr.nickname_changed_at from public.profiles pr where pr.id = v_l) is distinct from v_when then
    v_bad := v_bad || 'L''s lock moved; ';
  end if;
  -- A case change of an old rule-breaking name IS a change.
  v_bad := v_bad || pg_temp.nr_try(v_g, v_base || ' g$', 'nickname_invalid', m_chars, false);
  if v_bad <> '' then
    raise exception 'FAIL [C10] the same nickname: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C11] D$ re-saves its own name.
  select pr.nickname_changed_at into v_when from public.profiles pr where pr.id = v_dollar;
  v_r := pg_temp.nr_as('authenticated', v_dollar,
           format('insert into public.profiles as pr (id, nickname) values (%L, %L) '
                  'on conflict (id) do update set id = excluded.id, nickname = excluded.nickname returning pr.nickname',
                  v_dollar, 'D$'));
  select pr.nickname, pr.nickname_changed_at into v_txt, v_when2 from public.profiles pr where pr.id = v_dollar;
  if v_r[1] is not null or v_r[5] is distinct from 'D$' or v_txt is distinct from 'D$' or v_when2 is distinct from v_when then
    raise exception 'FAIL [C11] D$ re-saving "D$": % "%" -> nickname %, changed_at % (was %); expected no error and nothing changed.',
      coalesce(v_r[1], 'ok'), coalesce(v_r[2], ''), coalesce(v_txt, 'no row'), coalesce(v_when2::text, 'null'), coalesce(v_when::text, 'null');
  end if;
  v_checks := v_checks + 1;

  -- [C12] The INSERT path: a new account with no profile row.
  v_bad := '';
  v_bad := v_bad || pg_temp.nr_try(v_n, v_base || 'Wa1t', 'nickname_taken', m_taken, false);
  v_bad := v_bad || pg_temp.nr_try(v_n, v_base || 'x@y', 'nickname_invalid', m_chars, false);
  v_bad := v_bad || pg_temp.nr_try(v_n, 'Staff', 'nickname_unavailable', m_unavail, false);
  if exists (select 1 from public.profiles pr where pr.id = v_n) then
    v_bad := v_bad || 'a refused insert left a row; ';
  end if;
  v_bad := v_bad || pg_temp.nr_try(v_n, v_base || 'Newbie', null, null, false);
  if not exists (select 1 from public.profiles pr where pr.id = v_n and pr.nickname_changed_at is null) then
    v_bad := v_bad || 'the new row is missing or has nickname_changed_at set; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [C12] the insert path: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C13] Order with the lock.
  v_bad := '';
  v_bad := v_bad || pg_temp.nr_try(v_l, v_base || 'Wa1t', 'nickname_locked', m_locked, false);
  v_bad := v_bad || pg_temp.nr_try(v_l, v_base || chr(128512) || 'x', 'nickname_locked', m_locked, false);
  update public.profiles set nickname = v_base || 'Bee', nickname_changed_at = null where id = v_b;
  v_bad := v_bad || pg_temp.nr_try(v_b, v_base || 'Bee2', null, null, false);
  if (select pr.nickname_changed_at from public.profiles pr where pr.id = v_b) is distinct from now() then
    v_bad := v_bad || 'B''s real change was not stamped now() by the lock; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [C13] order with the lock: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C14] Exempt: the owner (this session).
  v_bad := '';
  begin
    update public.profiles set nickname = v_base || chr(128512) || 'Admin' where id = v_c;
    if (select pr.nickname from public.profiles pr where pr.id = v_c) is distinct from v_base || chr(128512) || 'Admin' then
      v_bad := v_bad || 'the emoji + Admin name did not stick; ';
    end if;
    update public.profiles set nickname = v_base || 'WaIt' where id = v_c;
    if (select pr.nickname from public.profiles pr where pr.id = v_c) is distinct from v_base || 'WaIt' then
      v_bad := v_bad || 'the look-alike did not stick; ';
    end if;
  exception when others then
    v_bad := v_bad || 'refused: ' || sqlerrm || ' (' || sqlstate || '); ';
  end;
  if v_bad <> '' then
    raise exception 'FAIL [C14] the owner is exempt: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C15] Exempt: the computer account, signed in as itself.
  v_bad := '';
  update public.profiles set nickname_changed_at = null where id = v_comp;
  v_bad := v_bad || pg_temp.nr_try(v_comp, v_base || ' Wa1t Staff$', null, null, false);
  update public.profiles set nickname_changed_at = null where id = v_comp;
  v_bad := v_bad || pg_temp.nr_try(v_comp, v_base || 'Wa1t', null, null, false);
  if v_bad <> '' then
    raise exception 'FAIL [C15] the computer account is exempt: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- [C16] The advisory lock on the skeleton is held after a save.
  v_name := v_base || 'Lockcheck';
  v_bad := pg_temp.nr_try(v_b, v_name, null, null, true);
  v_skel := replace(replace(translate(translate(lower(translate(v_name, 'I|1!', 'llll')), ' .-_''', ''), '0', 'o'), 'rn', 'm'), 'vv', 'w');
  v_key := hashtextextended('nickname:' || v_skel, 0);
  if not exists (select 1 from pg_locks lk
                 where lk.locktype = 'advisory' and lk.pid = pg_backend_pid() and lk.granted
                   and lk.objsubid = 1
                   and lk.classid = ((v_key >> 32) & 4294967295)::oid
                   and lk.objid = (v_key & 4294967295)::oid) then
    v_bad := v_bad || 'no advisory lock held for skeleton ' || v_skel || '; ';
  end if;
  if v_bad <> '' then
    raise exception 'FAIL [C16] the advisory lock: %', v_bad;
  end if;
  v_checks := v_checks + 1;

  -- ==== VERDICT =====================================================================
  -- 3 catalog (K1-K3) + 16 behaviour (C1-C16).
  if v_checks <> v_expect then
    raise exception 'FAIL: % checks ran, expected %.', v_checks, v_expect;
  end if;

  -- Everything above is rolled back by this final exception: it is the verdict.
  raise exception 'ALL % CHECKS PASSED (rolled back).', v_checks;
end;
$$;
