-- Computer accounts' login emails, yodawood.com -> raynewood.com:
-- VERIFICATION.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER
-- docs/sql/computer-emails-part1.sql. The whole file is ONE DO block: run it
-- as is.
--
-- STATUS: RUN on 2026-11-27 by Walt after part 1: ALL 11 CHECKS PASSED
-- (rolled back); the others fingerprints matched the precheck's. Afterwards
-- computer-normie-verification.sql passed 10 checks and
-- computer-c2-verification.sql 81.
--
-- It WRITES (four computer tables, their seats, attempt_log rows) and then
-- deliberately raises an exception at the very end, which rolls every write
-- back. It always "fails": the message is the verdict.
-- "ALL 11 CHECKS PASSED (rolled back) ..." is a pass; anything starting
-- "FAIL" or "SETUP" is not. Re-runnable, because nothing it does survives.
-- It reads auth.users and auth.identities only as the owner and never
-- prints a password, token or anyone else's email.
--
-- Same impersonation as the earlier verification scripts:
-- request.jwt.claims plus "set local role authenticated" to act as a
-- client, and "reset role" to act as the owner between steps.
--
-- PLAYER A (the computer-c2 / computer-normie kind of test account): the
-- OLDEST account that is neither an admin nor a computer account, AND -- so
-- create_computer_table cannot refuse it -- is seated at no table that has
-- not ended (the one-table rule refuses "You're already at table ..." for a
-- table with another human; a single-player table it would quietly end,
-- inside this rolled-back test only), AND made fewer than 7 computer tables
-- in the last hour (the limit is 10 an hour; this test makes 4). If no
-- account qualifies: SETUP (try again later, or leave the table you are at).
-- The REAL computer accounts are used; nothing replaces them.
--
-- WHAT IT CHECKS
--   E1  the four ids exist with exactly their raynewood.com emails, not SSO;
--       public.computer_accounts holds exactly these ids at easy, casual,
--       medium, hard (the ids are unchanged).
--   E2  each has exactly one identity: provider 'email', provider_id the user
--       id, identity_data's email the new one (sub, when present, the id),
--       and the generated auth.identities.email the new one (when the
--       column exists).
--   E3  raw_user_meta_data's email: absent, or the new one.
--   E4  no trace of an old email ANYWHERE: no auth user, no metadata, no
--       identity (identity_data or provider_id) holds any of the four
--       yodawood.com addresses.
--   E5  each new email belongs to exactly one user (its own) and one
--       identity (its own).
--   E6  still confirmed, nothing in flight: email_confirmed_at set (and
--       confirmed_at), email_change and its tokens empty, confirm status 0,
--       no confirmation/recovery/reauthentication token, no
--       auth.one_time_tokens row.
--   P1  get_computer_profiles(), called as A, still returns the four ids at
--       easy, casual, medium, hard with the names Shortbus, Normie, Rainman,
--       God.
--   T1-T4  create_computer_table(level) as A, for each level in turn: a
--       private, regular, 2-player table at that level, A in seat 1 and that
--       level's computer in seat 2; the guard (_computer_for_table) answers
--       that computer. (Each new table quietly ends A's previous
--       single-player table: the one-table rule.)
--   Then, NOT a check: the two "others" fingerprints (ids and emails of
--   every OTHER user and identity), in the verdict. Compare them with the
--   precheck's two "others" rows: equal means no other account's email
--   was touched (they also differ if someone signed up, or changed their
--   own email, in between -- then compare by hand).
--
-- The existing suites: none mentions these emails (checked 2026-11-27), so
-- none needs changing. Re-run computer-normie-verification.sql (it uses the
-- real computer accounts) and computer-c2-verification.sql as the computer
-- regression proof; both should pass exactly as before.

do $$
declare
  v_levels text[] := array['easy', 'casual', 'medium', 'hard'];
  v_names text[] := array['Shortbus', 'Normie', 'Rainman', 'God'];
  v_ids uuid[] := array[
    'aa89a842-ecf7-407a-9581-a794968c3aa2',
    '14fec049-681d-47c5-81de-a176f9c59ed1',
    '740523b1-816f-4208-95c9-0d720238fd77',
    '3acbe000-f905-4e6a-9f5c-de22d87efd50']::uuid[];
  v_old text[] := array['shortbus@yodawood.com', 'normie@yodawood.com', 'rainman@yodawood.com', 'god@yodawood.com'];
  v_new text[] := array['shortbus@raynewood.com', 'normie@raynewood.com', 'rainman@raynewood.com', 'god@raynewood.com'];
  v_a uuid;
  v_code text;
  v_ct uuid;
  v_txt text;
  v_n int;
  v_gen "char";
  v_got_levels text[];
  v_got_names text[];
  v_got_ids uuid[];
  v_seats uuid[];
  v_others_u text;
  v_others_i text;
  v_checks int := 0;
  i int;
begin
  -- ---- Setup, as the owner ------------------------------------------------
  select u.id into v_a from auth.users u
  where not exists (select 1 from public.admin_users ad where ad.user_id = u.id)
    and not exists (select 1 from public.computer_accounts ca where ca.user_id = u.id)
    and not exists (select 1 from public.table_members tm join public.tables t on t.id = tm.table_id
                    where tm.user_id = u.id and t.status <> 'ended')
    and (select count(*) from public.attempt_log al
         where al.user_id = u.id and al.action = 'create_computer_table' and al.success
           and al.created_at > now() - interval '1 hour') < 7
  order by u.created_at limit 1;
  if v_a is null then
    raise exception 'SETUP: no account is free to start computer tables (neither admin nor computer, at no table, under 7 computer tables this hour).';
  end if;

  -- A code no OPEN table holds -- every table while tables_code_open_key
  -- doesn't exist (create_computer_table ignores it after step 3 slice B
  -- part 2 and picks its own).
  select min(lpad(n::text, 4, '0')) into v_code
  from generate_series(0, 9999) n
  where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                      and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null));
  if v_code is null then
    raise exception 'SETUP: no unused table code.';
  end if;

  select att.attgenerated into v_gen
  from pg_attribute att
  where att.attrelid = 'auth.identities'::regclass and att.attname = 'email' and not att.attisdropped;

  -- ==== E: the emails ========================================================
  -- [E1] The four ids, exactly the new emails, not SSO; computer_accounts
  -- unchanged.
  select count(*) into v_n from auth.users u
  join unnest(v_ids, v_new) as x(id, em) on x.id = u.id
  where u.email = x.em and not coalesce(u.is_sso_user, false);
  if v_n <> 4 then
    raise exception 'FAIL [E1] % of the four ids have exactly their raynewood.com email (not SSO); expected 4.', v_n;
  end if;
  select count(*) into v_n from public.computer_accounts ca
  join unnest(v_levels, v_ids) as x(l, id) on x.l = ca.level and x.id = ca.user_id;
  if v_n <> 4 or (select count(*) from public.computer_accounts) <> 4 then
    raise exception 'FAIL [E1] computer_accounts does not hold exactly the four ids at easy, casual, medium, hard.';
  end if;
  v_checks := v_checks + 1;

  -- [E2] One current-format email identity each, with the new email.
  for i in 1 .. 4 loop
    select count(*) into v_n from auth.identities ii where ii.user_id = v_ids[i];
    if v_n <> 1 then
      raise exception 'FAIL [E2] % has % identities; expected 1.', v_levels[i], v_n;
    end if;
    select count(*) into v_n from auth.identities ii
    where ii.user_id = v_ids[i] and ii.provider = 'email' and ii.provider_id = v_ids[i]::text
      and ii.identity_data ->> 'email' = v_new[i]
      and (ii.identity_data ->> 'sub' is null or ii.identity_data ->> 'sub' = v_ids[i]::text);
    if v_n <> 1 then
      raise exception 'FAIL [E2] %''s identity is not provider email / provider_id the id / identity_data email %.', v_levels[i], v_new[i];
    end if;
    if v_gen = 's' then
      execute 'select count(*) from auth.identities ii where ii.user_id = $1 and ii.email = $2' into v_n using v_ids[i], v_new[i];
      if v_n <> 1 then
        raise exception 'FAIL [E2] the generated auth.identities.email for % is not %.', v_levels[i], v_new[i];
      end if;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- [E3] Metadata email: absent, or the new one.
  select count(*) into v_n from auth.users u
  join unnest(v_ids, v_new) as x(id, em) on x.id = u.id
  where u.raw_user_meta_data is null or not (u.raw_user_meta_data ? 'email') or u.raw_user_meta_data ->> 'email' = x.em;
  if v_n <> 4 then
    raise exception 'FAIL [E3] % of the four have a metadata email that is absent or the new one; expected 4.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [E4] No old email anywhere, on anyone.
  select count(*) into v_n from auth.users u
  where lower(u.email) = any (v_old) or lower(u.raw_user_meta_data ->> 'email') = any (v_old);
  if v_n <> 0 then
    raise exception 'FAIL [E4] % auth user(s) still hold a computer''s yodawood.com email (email or metadata).', v_n;
  end if;
  select count(*) into v_n from auth.identities ii
  where lower(ii.identity_data ->> 'email') = any (v_old) or lower(ii.provider_id) = any (v_old);
  if v_n <> 0 then
    raise exception 'FAIL [E4] % identit(ies) still name a computer''s yodawood.com email.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [E5] Each new email: exactly one user and one identity, its own.
  for i in 1 .. 4 loop
    select count(*) into v_n from auth.users u where lower(u.email) = v_new[i];
    if v_n <> 1 or not exists (select 1 from auth.users u where u.id = v_ids[i] and u.email = v_new[i]) then
      raise exception 'FAIL [E5] % is held by % auth users; expected exactly its own.', v_new[i], v_n;
    end if;
    select count(*) into v_n from auth.identities ii
    where lower(ii.identity_data ->> 'email') = v_new[i] or lower(ii.provider_id) = v_new[i];
    if v_n <> 1 or not exists (select 1 from auth.identities ii where ii.user_id = v_ids[i] and ii.identity_data ->> 'email' = v_new[i]) then
      raise exception 'FAIL [E5] % is named by % identities; expected exactly its own.', v_new[i], v_n;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- [E6] Still confirmed; nothing in flight.
  select count(*) into v_n from auth.users u
  where u.id = any (v_ids)
    and u.email_confirmed_at is not null
    and u.confirmed_at is not null
    and coalesce(u.email_change, '') = ''
    and coalesce(u.email_change_token_new, '') = ''
    and coalesce(u.email_change_token_current, '') = ''
    and coalesce(u.email_change_confirm_status, 0) = 0
    and u.email_change_sent_at is null
    and coalesce(u.confirmation_token, '') = ''
    and coalesce(u.recovery_token, '') = ''
    and coalesce(u.reauthentication_token, '') = '';
  if v_n <> 4 then
    raise exception 'FAIL [E6] % of the four are confirmed with nothing in flight; expected 4 (if the precheck showed one unconfirmed, this is why).', v_n;
  end if;
  if to_regclass('auth.one_time_tokens') is not null then
    execute 'select count(*) from auth.one_time_tokens t where t.user_id = any ($1)' into v_n using v_ids;
    if v_n <> 0 then
      raise exception 'FAIL [E6] % one-time token(s) exist for the four.', v_n;
    end if;
  end if;
  v_checks := v_checks + 1;

  -- ---- The others' fingerprints (printed in the verdict) ---------------------
  select count(*)::text || ' / ' || md5(coalesce(string_agg(u.id::text || '|' || coalesce(u.email, '') || '|' || coalesce(u.raw_user_meta_data ->> 'email', ''), E'\n' order by u.id), ''))
  into v_others_u
  from auth.users u where u.id <> all (v_ids);
  select count(*)::text || ' / ' || md5(coalesce(string_agg(ii.id::text || '|' || ii.user_id::text || '|' || ii.provider || '|' || coalesce(ii.provider_id, '') || '|' || coalesce(ii.identity_data ->> 'email', ''), E'\n' order by ii.id), ''))
  into v_others_i
  from auth.identities ii where ii.user_id <> all (v_ids);

  -- ==== P: the profiles =========================================================
  -- [P1] get_computer_profiles() as A: the same four, easiest first.
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  execute 'set local role authenticated';
  select array_agg(r.level order by r.ord), array_agg(r.nickname order by r.ord), array_agg(r.user_id order by r.ord)
  into v_got_levels, v_got_names, v_got_ids
  from public.get_computer_profiles() with ordinality as r(level, user_id, nickname, avatar_url, ord);
  execute 'reset role';
  if v_got_levels is distinct from v_levels or v_got_names is distinct from v_names or v_got_ids is distinct from v_ids then
    raise exception 'FAIL [P1] get_computer_profiles: levels %, names %, ids %; expected easy/casual/medium/hard, Shortbus/Normie/Rainman/God and the four ids.',
      v_got_levels, v_got_names, v_got_ids;
  end if;
  v_checks := v_checks + 1;

  -- ==== T: a computer table at every level ======================================
  -- [T1]-[T4] A starts a table at each level in turn (A's claims are still
  -- set; each call ends A's previous single-player table).
  for i in 1 .. 4 loop
    v_ct := null;
    execute 'set local role authenticated';
    select r.table_id into v_ct from public.create_computer_table(v_levels[i], v_code) r;
    execute 'reset role';
    select count(*) into v_n from public.tables t
    where t.id = v_ct and t.created_by = v_a and t.status = 'open'
      and t.is_public = false and t.is_muggins = false and t.max_players = 2 and t.computer_level = v_levels[i];
    select array_agg(tm.user_id order by tm.seat) into v_seats from public.table_members tm where tm.table_id = v_ct;
    select array_agg(tm.seat order by tm.seat)::text into v_txt from public.table_members tm where tm.table_id = v_ct;
    if v_ct is null or v_n <> 1 or v_seats is distinct from array[v_a, v_ids[i]] or v_txt is distinct from '{1,2}' then
      raise exception 'FAIL [T%] create_computer_table(%): table %, match %, seats % %; expected A in 1 and % in 2.',
        i, v_levels[i], v_ct, v_n, v_seats, v_txt, v_names[i];
    end if;
    -- The guard answers that level's computer (as the owner, with A's claims
    -- still set: the helper reads auth.uid()).
    if public._computer_for_table(v_ct) is distinct from v_ids[i] then
      raise exception 'FAIL [T%] _computer_for_table(% table) = %; expected %.', i, v_levels[i], public._computer_for_table(v_ct), v_ids[i];
    end if;
    v_checks := v_checks + 1;
  end loop;

  raise exception 'ALL % CHECKS PASSED (rolled back). Others: users % ; identities % -- compare with the precheck''s two "others" rows.',
    v_checks, v_others_u, v_others_i;
end
$$;
