-- Hide counts: VERIFICATION.
--
-- Run in the Supabase Dashboard -> SQL Editor AFTER docs/sql/hide-counts.sql,
-- and BEFORE the app can set hide_counts (check S3 expects every existing
-- row to still be false). The whole file is ONE DO block: run it as is.
--
-- It WRITES -- it inserts and updates user_appearance rows as real players
-- and tries to reach another player's row -- and then deliberately raises an
-- exception at the very end, which rolls every write back. It always
-- "fails": the message is the verdict. "ALL n CHECKS PASSED (rolled back)
-- ..." is a pass; anything starting "FAIL" or "SETUP" is not. Re-runnable,
-- because nothing it does survives. (Same pattern as
-- appearance-settings-verification.sql and table-visibility-verification.sql:
-- a DO block cannot COMMIT or ROLLBACK itself in the SQL Editor, so the final
-- exception IS the rollback.)
--
-- Same impersonation as the earlier verification scripts:
-- request.jwt.claims plus "set local role authenticated" (or anon) to act as
-- a client, and "reset role" to act as the owner between steps.
--
-- PLAYERS: user_appearance.user_id references auth.users, so the players must
-- be real accounts. P1 is the oldest account that already HAS an appearance
-- row (a real "existing row"); if no account has one yet, P1 is the oldest
-- account and a row is created for it here, with no columns but user_id. P2
-- is the oldest other account; any row P2 has is removed first, so P2 can
-- insert a brand-new one. Everything is rolled back, so neither account's
-- real settings change.
--
-- WHAT IT CHECKS
--   S  the column: boolean, NOT NULL, default false, commented; no existing
--      row has it true; the policies and grants are unchanged and none is
--      column-level.
--   E  P1's existing row reads hide_counts = false, card_back and
--      table_surface as they were.
--   N  P2's brand-new row, inserted without the column, reads false.
--   O  P1 turns hide_counts on and off again on their own row.
--   X  P2 can neither read nor update P1's row (0 rows; P1's row unchanged).
--   A  anon can neither read nor update.
--   C  the existing columns still work: P1 updates card_back and
--      table_surface (hide_counts untouched), saves all three at once the way
--      the app's upsert does, and a bad card_back is still refused.
--
-- Expected message:
--   ALL 20 CHECKS PASSED (rolled back). P1 ... (existing row: real|created) P2 ...

do $$
declare
  v_p1 uuid;
  v_p2 uuid;
  v_existing text := 'real';
  v_orig_back text;
  v_orig_surface text;
  v_back text;
  v_surface text;
  v_hide boolean;
  v_type text;
  v_nullable text;
  v_default text;
  v_privs text[];
  v_n int;
  v_state text;
  v_checks int := 0;
begin
  -- ---- Setup, as the owner ------------------------------------------------
  -- P1: the oldest account that already has an appearance row.
  select u.id into v_p1
  from auth.users u
  where exists (select 1 from public.user_appearance a where a.user_id = u.id)
  order by u.created_at
  limit 1;
  if v_p1 is null then
    select u.id into v_p1 from auth.users u order by u.created_at limit 1;
    if v_p1 is null then
      raise exception 'SETUP: the project needs at least two accounts.';
    end if;
    insert into public.user_appearance (user_id) values (v_p1);
    v_existing := 'created';
  end if;

  -- P2: the oldest other account, with no row (removed here, rolled back).
  select u.id into v_p2 from auth.users u where u.id <> v_p1 order by u.created_at limit 1;
  if v_p2 is null then
    raise exception 'SETUP: the project needs at least two accounts.';
  end if;
  delete from public.user_appearance where user_id = v_p2;

  select card_back, table_surface into v_orig_back, v_orig_surface
  from public.user_appearance where user_id = v_p1;

  -- ==== S: the schema, as the owner ==========================================
  -- [S1] The column: boolean, NOT NULL, default false.
  select c.data_type, c.is_nullable, c.column_default into v_type, v_nullable, v_default
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'user_appearance' and c.column_name = 'hide_counts';
  if v_type is distinct from 'boolean' or v_nullable is distinct from 'NO' or v_default is distinct from 'false' then
    raise exception 'FAIL [S1] user_appearance.hide_counts is type % / nullable % / default %, expected boolean / NO / false.',
      coalesce(v_type, '(missing)'), v_nullable, v_default;
  end if;
  v_checks := v_checks + 1;

  -- [S2] ...and it has its comment.
  if col_description('public.user_appearance'::regclass,
       (select attnum from pg_attribute
        where attrelid = 'public.user_appearance'::regclass and attname = 'hide_counts')) is null then
    raise exception 'FAIL [S2] user_appearance.hide_counts has no comment.';
  end if;
  v_checks := v_checks + 1;

  -- [S3] Every existing row reads false (none was turned on by the migration).
  select count(*) into v_n from public.user_appearance where hide_counts;
  if v_n <> 0 then
    raise exception 'FAIL [S3] % existing row(s) have hide_counts = true; expected 0 (the default is false).', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [S4] The policies are unchanged: exactly SELECT, INSERT, UPDATE, each for
  -- authenticated only.
  select count(*) into v_n from pg_policies
  where schemaname = 'public' and tablename = 'user_appearance'
    and cmd in ('SELECT', 'INSERT', 'UPDATE') and roles = array['authenticated']::name[];
  if v_n <> 3 or exists (select 1 from pg_policies
                        where schemaname = 'public' and tablename = 'user_appearance'
                          and (cmd not in ('SELECT', 'INSERT', 'UPDATE') or roles <> array['authenticated']::name[])) then
    raise exception 'FAIL [S4] user_appearance policies are not exactly SELECT/INSERT/UPDATE for authenticated.';
  end if;
  v_checks := v_checks + 1;

  -- [S5] The grants are unchanged and table-level: authenticated holds
  -- exactly SELECT, INSERT, UPDATE; anon and PUBLIC nothing; and no column
  -- of the table carries a grant of its own.
  select array_agg(a.privilege_type::text order by a.privilege_type) into v_privs
  from pg_class c
  cross join lateral aclexplode(c.relacl) a
  join pg_roles r on r.oid = a.grantee
  where c.oid = 'public.user_appearance'::regclass and r.rolname = 'authenticated';
  if v_privs is distinct from array['INSERT', 'SELECT', 'UPDATE'] then
    raise exception 'FAIL [S5] authenticated holds %, expected {INSERT,SELECT,UPDATE}.', v_privs;
  end if;
  select count(*) into v_n
  from pg_class c
  cross join lateral aclexplode(c.relacl) a
  left join pg_roles r on r.oid = a.grantee
  where c.oid = 'public.user_appearance'::regclass
    and (r.rolname = 'anon' or a.grantee = 0);
  if v_n <> 0 then
    raise exception 'FAIL [S5] anon/PUBLIC hold % privilege(s) on user_appearance.', v_n;
  end if;
  select count(*) into v_n
  from pg_attribute
  where attrelid = 'public.user_appearance'::regclass and attnum > 0
    and not attisdropped and attacl is not null;
  if v_n <> 0 then
    raise exception 'FAIL [S5] % column(s) of user_appearance have column-level grants; expected none.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- ==== E: P1's existing row, as P1 =========================================
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_p1, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_p1::text, true);

  -- [E1] P1 reads their row: hide_counts false.
  select count(*), bool_or(hide_counts) into v_n, v_hide
  from public.user_appearance where user_id = v_p1;
  if v_n <> 1 or v_hide is distinct from false then
    raise exception 'FAIL [E1] P1 read % row(s) with hide_counts %, expected 1 row, false.', v_n, v_hide;
  end if;
  v_checks := v_checks + 1;

  -- [E2] ...and card_back / table_surface are what they were.
  select card_back, table_surface into v_back, v_surface
  from public.user_appearance where user_id = v_p1;
  if v_back is distinct from v_orig_back or v_surface is distinct from v_orig_surface then
    raise exception 'FAIL [E2] P1 reads % / %, expected % / %.', v_back, v_surface, v_orig_back, v_orig_surface;
  end if;
  v_checks := v_checks + 1;

  -- ==== N: P2's brand-new row, as P2 ========================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_p2, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_p2::text, true);

  -- [N1] P2 inserts a row WITHOUT the column (as today's app does).
  v_state := null;
  begin
    insert into public.user_appearance (user_id, card_back, table_surface)
    values (v_p2, 'classic', 'classic');
  exception when others then v_state := sqlstate;
  end;
  if v_state is not null then
    raise exception 'FAIL [N1] P2 could not insert their own row: %.', v_state;
  end if;
  v_checks := v_checks + 1;

  -- [N2] ...and reads it back with hide_counts false.
  select hide_counts into v_hide from public.user_appearance where user_id = v_p2;
  if v_hide is distinct from false then
    raise exception 'FAIL [N2] P2''s new row reads hide_counts %, expected false.', v_hide;
  end if;
  v_checks := v_checks + 1;

  -- ==== X: P2 cannot reach P1's row ==========================================
  -- [X1] P2 reads P1's row: nothing.
  select count(*) into v_n from public.user_appearance where user_id = v_p1;
  if v_n <> 0 then raise exception 'FAIL [X1] P2 read % row(s) of P1''s appearance.', v_n; end if;
  v_checks := v_checks + 1;

  -- [X2] P2 updates P1's hide_counts: 0 rows (the row isn't visible to them).
  update public.user_appearance set hide_counts = true where user_id = v_p1;
  get diagnostics v_n = row_count;
  if v_n <> 0 then raise exception 'FAIL [X2] P2''s update of P1''s hide_counts touched % row(s).', v_n; end if;
  v_checks := v_checks + 1;

  -- [X3] P1's row is untouched (checked as the owner).
  execute 'reset role';
  select hide_counts into v_hide from public.user_appearance where user_id = v_p1;
  if v_hide is distinct from false then
    raise exception 'FAIL [X3] P1''s hide_counts became % after P2''s update.', v_hide;
  end if;
  v_checks := v_checks + 1;

  -- ==== O: P1 turns it on and off ===========================================
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', v_p1, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_p1::text, true);

  -- [O1] On: exactly one row, and it reads true.
  update public.user_appearance set hide_counts = true where user_id = v_p1;
  get diagnostics v_n = row_count;
  select hide_counts into v_hide from public.user_appearance where user_id = v_p1;
  if v_n <> 1 or v_hide is distinct from true then
    raise exception 'FAIL [O1] P1 turning hide_counts on: % row(s), reads %.', v_n, v_hide;
  end if;
  v_checks := v_checks + 1;

  -- [O2] Off again: exactly one row, and it reads false.
  update public.user_appearance set hide_counts = false where user_id = v_p1;
  get diagnostics v_n = row_count;
  select hide_counts into v_hide from public.user_appearance where user_id = v_p1;
  if v_n <> 1 or v_hide is distinct from false then
    raise exception 'FAIL [O2] P1 turning hide_counts off: % row(s), reads %.', v_n, v_hide;
  end if;
  v_checks := v_checks + 1;

  -- ==== C: the existing columns still work, as P1 ===========================
  -- [C1] card_back and table_surface update as before; hide_counts untouched.
  update public.user_appearance set card_back = 'vintage', table_surface = 'wood' where user_id = v_p1;
  get diagnostics v_n = row_count;
  select card_back, table_surface, hide_counts into v_back, v_surface, v_hide
  from public.user_appearance where user_id = v_p1;
  if v_n <> 1 or v_back <> 'vintage' or v_surface <> 'wood' or v_hide is distinct from false then
    raise exception 'FAIL [C1] P1''s appearance update: % row(s), reads % / % / hide %.', v_n, v_back, v_surface, v_hide;
  end if;
  v_checks := v_checks + 1;

  -- [C2] All three saved at once, the way the app's Save will: an upsert on
  -- user_id (AppearanceProvider's save, with the new field).
  v_state := null;
  begin
    insert into public.user_appearance (user_id, card_back, table_surface, hide_counts, updated_at)
    values (v_p1, 'standard-blue', 'green-felt', true, now())
    on conflict (user_id) do update
      set card_back = excluded.card_back,
          table_surface = excluded.table_surface,
          hide_counts = excluded.hide_counts,
          updated_at = excluded.updated_at;
  exception when others then v_state := sqlstate;
  end;
  select card_back, table_surface, hide_counts into v_back, v_surface, v_hide
  from public.user_appearance where user_id = v_p1;
  if v_state is not null or v_back <> 'standard-blue' or v_surface <> 'green-felt' or v_hide is distinct from true then
    raise exception 'FAIL [C2] P1''s upsert: error %, reads % / % / hide %.', coalesce(v_state, 'none'), v_back, v_surface, v_hide;
  end if;
  v_checks := v_checks + 1;

  -- [C3] The card_back CHECK still refuses a bad value: 23514.
  v_state := null;
  begin
    update public.user_appearance set card_back = 'tie-dye' where user_id = v_p1;
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '23514' then
    raise exception 'FAIL [C3] card_back ''tie-dye'': expected 23514 (check), got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  -- ==== A: anon gets nothing ================================================
  execute 'reset role';
  execute 'set local role anon';
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);

  -- [A1] anon cannot read: no privilege (42501) -- or, at the very least, no
  -- rows.
  v_state := null; v_n := 0;
  begin
    select count(*) into v_n from public.user_appearance;
  exception when others then v_state := sqlstate;
  end;
  if not (v_state = '42501' or (v_state is null and v_n = 0)) then
    raise exception 'FAIL [A1] anon read: % row(s), error %.', v_n, coalesce(v_state, 'none');
  end if;
  v_checks := v_checks + 1;

  -- [A2] anon cannot update hide_counts: refused (42501) or no row touched.
  v_state := null; v_n := 0;
  begin
    update public.user_appearance set hide_counts = true where user_id = v_p1;
    get diagnostics v_n = row_count;
  exception when others then v_state := sqlstate;
  end;
  if not (v_state = '42501' or (v_state is null and v_n = 0)) then
    raise exception 'FAIL [A2] anon update: % row(s), error %.', v_n, coalesce(v_state, 'none');
  end if;
  v_checks := v_checks + 1;

  -- [A3] anon cannot insert a row.
  v_state := null;
  begin
    insert into public.user_appearance (user_id, hide_counts) values (v_p2, true);
  exception when others then v_state := sqlstate;
  end;
  if v_state is distinct from '42501' then
    raise exception 'FAIL [A3] anon insert: expected 42501, got %.', coalesce(v_state, 'no error');
  end if;
  v_checks := v_checks + 1;

  execute 'reset role';

  raise exception 'ALL % CHECKS PASSED (rolled back). P1 % (existing row: %), P2 %.',
    v_checks, v_p1, v_existing, v_p2;
end $$;
