-- Table visibility: VERIFICATION.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER
-- docs/sql/table-visibility.sql. The whole file is ONE DO block: run it as
-- is.
--
-- It WRITES -- it creates tables and memberships as real players and tries
-- to change is_public -- and then deliberately raises an exception at the
-- very end, which rolls every write back. It always "fails": the message is
-- the verdict. "ALL n CHECKS PASSED (rolled back) ..." is a pass; anything
-- starting "FAIL" or "SETUP" is not. Re-runnable, because nothing it does
-- survives. (Same pattern as appearance-settings-verification.sql: a DO block
-- cannot COMMIT or ROLLBACK itself in the SQL Editor, so the final exception
-- IS the rollback.)
--
-- Same impersonation as the earlier verification scripts:
-- request.jwt.claims plus "set local role authenticated" (or anon) to act as
-- a client, and "reset role" to act as the owner between steps.
--
-- PLAYERS: tables.created_by and table_members.user_id reference auth.users,
-- so the players must be real accounts. A and B are the two OLDEST accounts
-- that are NOT admins (an admin matches the admin UPDATE policy, which would
-- muddy the "players can't change is_public" checks). C is any third
-- account, used only to fill a table. The admin, if there is one, is used
-- only for the informational admin check (U5). None of these accounts is
-- changed; every table and membership below is created here and rolled back.
--
-- WHAT IT CHECKS
--   S  the column: boolean, NOT NULL, default false, commented; no existing
--      row is public; the tables policies are still exactly the three known
--      ones; tables is still in the supabase_realtime publication.
--   I  A creates a public table, a private one, and one that leaves is_public
--      out (-> false); A reads all three; A still cannot create a table in
--      B's name.
--   L  the lobby query, as B (open, is_public, not B's own, fewer than 2
--      members): shows A's public table only -- not A's private one, not B's
--      own public one, not a full public one.
--   R  existing behaviour: B still finds A's PRIVATE table by its code, and
--      can still join it.
--   U  neither A (the creator) nor B can change is_public with an UPDATE;
--      both tables keep their value. Plus an informational report of what an
--      ADMIN can do (see table-visibility.sql, section 2).
--   N  anon can neither read nor create tables.
--
-- Expected message (n is 23 with three or more accounts, 22 with exactly
-- two -- the full-table check L4 needs a third):
--   ALL 23 CHECKS PASSED (rolled back). ... Admin update of is_public: ...

do $$
declare
  v_a uuid;
  v_b uuid;
  v_c uuid;
  v_admin uuid;
  v_codes text[];
  v_t_pub uuid;
  v_t_priv uuid;
  v_t_default uuid;
  v_t_bpub uuid;
  v_t_full uuid;
  v_fixtures uuid[];
  v_lobby uuid[];
  v_pub boolean;
  v_n int;
  v_state text;
  v_type text;
  v_nullable text;
  v_default text;
  v_admin_result text := 'not tested (no admin account)';
  v_col_grants text;
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
  select u.id into v_c from auth.users u
  where u.id not in (v_a, v_b)
  order by u.created_at limit 1;
  select ad.user_id into v_admin from public.admin_users ad order by ad.granted_at limit 1;

  -- Six 4-digit codes no table uses yet (tables.code is unique across every
  -- table ever created, open or ended).
  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0'))
    order by n
    limit 6
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 6 then
    raise exception 'SETUP: fewer than six unused table codes.';
  end if;

  -- ==== S: the schema, as the owner ==========================================
  -- [S1] The column: boolean, NOT NULL, default false.
  select c.data_type, c.is_nullable, c.column_default into v_type, v_nullable, v_default
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'tables' and c.column_name = 'is_public';
  if v_type is distinct from 'boolean' or v_nullable is distinct from 'NO' or v_default is distinct from 'false' then
    raise exception 'FAIL [S1] tables.is_public is type % / nullable % / default %, expected boolean / NO / false.',
      coalesce(v_type, '(missing)'), v_nullable, v_default;
  end if;
  v_checks := v_checks + 1;

  -- [S2] ...and it has its comment.
  if col_description('public.tables'::regclass,
       (select attnum from pg_attribute where attrelid = 'public.tables'::regclass and attname = 'is_public')) is null then
    raise exception 'FAIL [S2] tables.is_public has no comment.';
  end if;
  v_checks := v_checks + 1;

  -- [S3] No existing table was made public (before any test insert).
  select count(*) into v_n from public.tables where is_public;
  if v_n <> 0 then
    raise exception 'FAIL [S3] % existing table(s) are public; expected 0 (the default is false).', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [S4] The tables policies are unchanged: exactly SELECT, INSERT and the
  -- admin UPDATE, by their known names.
  select count(*) into v_n from pg_policies
  where schemaname = 'public' and tablename = 'tables';
  if v_n <> 3
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'tables'
                    and cmd = 'SELECT' and policyname = 'Tables are viewable by any logged-in user')
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'tables'
                    and cmd = 'INSERT' and policyname = 'Users can create their own table')
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'tables'
                    and cmd = 'UPDATE' and policyname = 'Admins can force-end tables') then
    raise exception 'FAIL [S4] the tables policies are not exactly the three known ones (found %).', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [S5] tables is still in the supabase_realtime publication (untouched).
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'tables') then
    raise exception 'FAIL [S5] tables is NOT in the supabase_realtime publication any more.';
  end if;
  v_checks := v_checks + 1;

  -- For the report: does any column of tables carry its own grant?
  select coalesce(string_agg(attname || '=' || attacl::text, '; '), 'none')
  into v_col_grants
  from pg_attribute
  where attrelid = 'public.tables'::regclass and attnum > 0 and not attisdropped and attacl is not null;

  -- ==== I: A creates tables, as the real client does ========================
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);

  -- [I1] A public table: {code, created_by, is_public: true}.
  v_state := null;
  begin
    insert into public.tables (code, created_by, is_public)
    values (v_codes[1], v_a, true)
    returning id, is_public into v_t_pub, v_pub;
  exception when others then v_state := sqlstate;
  end;
  if v_state is not null or v_pub is distinct from true then
    raise exception 'FAIL [I1] A could not create a public table: error %, is_public %.', coalesce(v_state, 'none'), v_pub;
  end if;
  v_checks := v_checks + 1;

  -- [I2] A private table: is_public: false, sent explicitly.
  v_state := null; v_pub := null;
  begin
    insert into public.tables (code, created_by, is_public)
    values (v_codes[2], v_a, false)
    returning id, is_public into v_t_priv, v_pub;
  exception when others then v_state := sqlstate;
  end;
  if v_state is not null or v_pub is distinct from false then
    raise exception 'FAIL [I2] A could not create a private table: error %, is_public %.', coalesce(v_state, 'none'), v_pub;
  end if;
  v_checks := v_checks + 1;

  -- [I3] Today's client insert, {code, created_by} only: private by default.
  v_state := null; v_pub := null;
  begin
    insert into public.tables (code, created_by)
    values (v_codes[3], v_a)
    returning id, is_public into v_t_default, v_pub;
  exception when others then v_state := sqlstate;
  end;
  if v_state is not null or v_pub is distinct from false then
    raise exception 'FAIL [I3] today''s insert (no is_public): error %, is_public %, expected false.', coalesce(v_state, 'none'), v_pub;
  end if;
  v_checks := v_checks + 1;

  -- [I4] A reads all three back.
  select count(*) into v_n from public.tables where id in (v_t_pub, v_t_priv, v_t_default);
  if v_n <> 3 then raise exception 'FAIL [I4] A reads % of their 3 new tables.', v_n; end if;
  v_checks := v_checks + 1;

  -- [I5] Existing rule, unchanged: A cannot create a table in B's name.
  v_state := null;
  begin
    insert into public.tables (code, created_by, is_public) values (v_codes[4], v_b, true);
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '42501' then
    raise exception 'FAIL [I5] A creating a table as B: expected 42501 (RLS), got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- A sits at their public and private tables, as the table page does.
  insert into public.table_members (table_id, user_id) values (v_t_pub, v_a), (v_t_priv, v_a);

  -- A full public table (A plus C), when there is a third account.
  if v_c is not null then
    insert into public.tables (code, created_by, is_public)
    values (v_codes[5], v_a, true)
    returning id into v_t_full;
    insert into public.table_members (table_id, user_id) values (v_t_full, v_a);
  end if;

  -- ---- B's own public table, and C's seat ----------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  insert into public.tables (code, created_by, is_public)
  values (v_codes[4], v_b, true)
  returning id into v_t_bpub;
  insert into public.table_members (table_id, user_id) values (v_t_bpub, v_b);

  if v_c is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_c::text, true);
    insert into public.table_members (table_id, user_id) values (v_t_full, v_c);
  end if;

  v_fixtures := array_remove(array[v_t_pub, v_t_priv, v_t_default, v_t_bpub, v_t_full], null);

  -- ==== L: the lobby, as B ===================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_b::text, true);

  -- The lobby query shape: open, public, not B's own (created or seated),
  -- fewer than 2 players. Only this test's tables are looked at.
  select coalesce(array_agg(t.id), '{}') into v_lobby
  from public.tables t
  where t.id = any (v_fixtures)
    and t.status = 'open'
    and t.is_public
    and t.created_by <> v_b
    and not exists (select 1 from public.table_members m where m.table_id = t.id and m.user_id = v_b)
    and (select count(*) from public.table_members m where m.table_id = t.id) < 2;

  -- [L1] A's public table is listed.
  if not (v_t_pub = any (v_lobby)) then raise exception 'FAIL [L1] B''s lobby does not list A''s public table.'; end if;
  v_checks := v_checks + 1;

  -- [L2] A's private tables (explicit and default) are not.
  if v_t_priv = any (v_lobby) or v_t_default = any (v_lobby) then
    raise exception 'FAIL [L2] B''s lobby lists one of A''s PRIVATE tables.';
  end if;
  v_checks := v_checks + 1;

  -- [L3] B's own public table is not.
  if v_t_bpub = any (v_lobby) then raise exception 'FAIL [L3] B''s lobby lists B''s own table.'; end if;
  v_checks := v_checks + 1;

  -- [L4] A full public table (2 players) is not. Needs a third account.
  if v_t_full is not null then
    if v_t_full = any (v_lobby) then raise exception 'FAIL [L4] B''s lobby lists a full (2-player) table.'; end if;
    v_checks := v_checks + 1;
  end if;

  -- [L5] Exactly one of this test's tables is listed.
  if coalesce(array_length(v_lobby, 1), 0) <> 1 then
    raise exception 'FAIL [L5] B''s lobby lists % of the test tables, expected exactly 1.', coalesce(array_length(v_lobby, 1), 0);
  end if;
  v_checks := v_checks + 1;

  -- ==== R: join by code still works for a private table ======================
  -- [R1] B looks A's private table up by its code, exactly as the table page
  -- does.
  select count(*) into v_n from public.tables where code = v_codes[2] and status = 'open';
  if v_n <> 1 then raise exception 'FAIL [R1] B finds % row(s) for A''s private table''s code, expected 1.', v_n; end if;
  v_checks := v_checks + 1;

  -- [R2] ...and can still join it.
  v_state := null;
  begin
    insert into public.table_members (table_id, user_id) values (v_t_priv, v_b);
  exception when others then v_state := sqlstate;
  end;
  if v_state is not null then raise exception 'FAIL [R2] B could not join A''s private table: %.', v_state; end if;
  v_checks := v_checks + 1;

  -- ==== U: nobody but an admin can change is_public ==========================
  -- [U1] B tries to make A's private table public: refused (42501) or no row
  -- touched. Anything else means players CAN change it -- loud failure.
  v_state := null; v_n := 0;
  begin
    update public.tables set is_public = true where id = v_t_priv;
    get diagnostics v_n = row_count;
  exception when others then v_state := sqlstate;
  end;
  if not (v_state = '42501' or (v_state is null and v_n = 0)) then
    raise exception 'FAIL [U1] B CHANGED is_public on A''s table (% row(s), error %). Players must not be able to.', v_n, coalesce(v_state, 'none');
  end if;
  v_checks := v_checks + 1;

  -- [U2] A, the creator, tries both directions: also refused or no row.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_state := null; v_n := 0;
  begin
    update public.tables set is_public = true where id = v_t_priv;
    get diagnostics v_n = row_count;
  exception when others then v_state := sqlstate;
  end;
  if not (v_state = '42501' or (v_state is null and v_n = 0)) then
    raise exception 'FAIL [U2] A CHANGED is_public on their private table (% row(s), error %). Players must not be able to.', v_n, coalesce(v_state, 'none');
  end if;
  v_checks := v_checks + 1;

  v_state := null; v_n := 0;
  begin
    update public.tables set is_public = false where id = v_t_pub;
    get diagnostics v_n = row_count;
  exception when others then v_state := sqlstate;
  end;
  if not (v_state = '42501' or (v_state is null and v_n = 0)) then
    raise exception 'FAIL [U3] A CHANGED is_public on their public table (% row(s), error %). Players must not be able to.', v_n, coalesce(v_state, 'none');
  end if;
  v_checks := v_checks + 1;

  -- [U4] Both tables kept their value (checked as the owner).
  execute 'reset role';
  if (select is_public from public.tables where id = v_t_priv) is distinct from false
     or (select is_public from public.tables where id = v_t_pub) is distinct from true then
    raise exception 'FAIL [U4] after the update attempts, is_public changed on A''s tables.';
  end if;
  v_checks := v_checks + 1;

  -- [U5] INFORMATIONAL, not a pass/fail check: can an ADMIN change it?
  -- Expected today: yes (the admin UPDATE policy plus the table-level UPDATE
  -- grant). After the proposed column-level grant in table-visibility.sql,
  -- section 2: no (42501).
  if v_admin is not null then
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_admin::text, true);
    v_state := null; v_n := 0;
    begin
      update public.tables set is_public = true where id = v_t_priv;
      get diagnostics v_n = row_count;
    exception when others then v_state := sqlstate;
    end;
    v_admin_result := case
      when v_state = '42501' then 'BLOCKED (42501 -- the column-level grant is in place)'
      when v_state is null and v_n = 1 then 'ALLOWED (an admin can change is_public -- see table-visibility.sql section 2)'
      else format('unexpected: %s row(s), error %s', v_n, coalesce(v_state, 'none'))
    end;
    execute 'reset role';
  end if;

  -- ==== N: anon gets nothing ================================================
  execute 'set local role anon';
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);

  -- [N1] anon cannot read tables: no privilege (42501) or no rows.
  v_state := null; v_n := 0;
  begin
    select count(*) into v_n from public.tables;
  exception when others then v_state := sqlstate;
  end;
  if not (v_state = '42501' or (v_state is null and v_n = 0)) then
    raise exception 'FAIL [N1] anon read % table row(s), error %.', v_n, coalesce(v_state, 'none');
  end if;
  v_checks := v_checks + 1;

  -- [N2] anon cannot create a table.
  v_state := null;
  begin
    insert into public.tables (code, created_by, is_public) values (v_codes[6], v_a, true);
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '42501' then
    raise exception 'FAIL [N2] anon insert: expected 42501, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  execute 'reset role';

  raise exception 'ALL % CHECKS PASSED (rolled back). Players A=% B=% C=%. Admin update of is_public: %. Column-level grants on tables: %.',
    v_checks, v_a, v_b, coalesce(v_c::text, 'none (L4 skipped)'), v_admin_result, v_col_grants;
end $$;
