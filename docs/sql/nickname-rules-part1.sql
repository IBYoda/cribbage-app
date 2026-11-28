-- NICKNAME RULES, part 1 (the only part): the profiles_nickname_rules
-- trigger. Run in the Supabase Dashboard -> SQL Editor after
-- docs/sql/nickname-rules-precheck.sql shows "before part 1" and no STOP.
--
-- STATUS: RUN 2026-11-28.
--
-- DEPLOY ORDER: nickname-rules-precheck.sql -> THIS FILE ->
-- nickname-rules-precheck.sql again ("part 1 present") ->
-- nickname-rules-verification.sql -> the regression suites
-- (slice-e-ratelimits-verification.sql, slice-e-grants-verification.sql,
-- slice-e-precheck.sql) -> the app (a later step).
--
-- NOT RE-RUNNABLE BY DESIGN: the guard STOPs if the function or the trigger
-- already exists. To undo: docs/sql/nickname-rules-part1-rollback.sql.
--
-- WHAT IT ADDS (nothing else changes; no existing nickname is touched):
--   public.profiles_nickname_rules() -- a trigger function, SECURITY
--   INVOKER, search_path '', executable by no role (a trigger needs none),
--   so the client-callable count stays as it is (61) -- and the trigger
--   profiles_nickname_rules, BEFORE INSERT OR UPDATE FOR EACH ROW on
--   public.profiles. Postgres fires same-event triggers in name order, so
--   profiles_nickname_lock (the 7-day lock, untouched: md5
--   215515390acc9b410afbd71b210d31e0) runs first: a locked player hears
--   about the lock, and a refused name stamps nothing.
--
-- THE RULES, for the client roles only (authenticated, anon -- the same
-- test as profiles_nickname_lock; the owner, the SQL Editor and security
-- definer functions are not limited), and only for a NEW row or an UPDATE
-- whose nickname IS DISTINCT FROM the stored one. The INSERT of an upsert
-- fires before the conflict is found, so when the row already exists the
-- trigger leaves it to the DO UPDATE that follows: saving the same nickname
-- again never fails, whatever it is (D$ keeps working). The computer
-- accounts (get_computer_profiles(), which authenticated may already
-- execute) are exempt; checked only when a rule fails.
--   1. nickname_invalid, in this order:
--        empty after trimming     "Please enter a nickname."
--        a character outside A-Z a-z 0-9 space . - _ ' !
--                                 "Nicknames can use letters, numbers, spaces and . - _ ' ! only."
--        over 30 characters       "Nicknames are at most 30 characters."
--        a leading, trailing or double space (refused, never trimmed)
--                                 "Nicknames can't start or end with a space or have two spaces in a row."
--        no letter or digit       "Nicknames need at least one letter or number."
--   2. nickname_unavailable, "That nickname isn't available.": the LOOSE
--      skeleton (the strict one with i -> l) contains a reserved word's:
--      Admin admln, Administrator admlnlstrator, Moderator moderator,
--      Support support, Staff staff, Official offlclal, Raynewood raynewood.
--      Checked before AND after the rn -> m / vv -> w step, so neither
--      "Adrnin" nor "Moderatorn" gets through.
--   3. nickname_taken, "That nickname is taken.": another profile (any,
--      computer accounts and old names included) has the same STRICT
--      skeleton. Strict skeleton, in order: capital I, |, 1, ! -> l
--      (case-sensitive, before lower-casing); lower-case; remove space . - _
--      '; 0 -> o; rn -> m; vv -> w (as docs/sql/nickname-rules-audit.sql).
--      A transaction advisory lock on the skeleton is taken first, so two
--      players claiming look-alikes at once queue, and the second one's
--      lookup (a fresh snapshot under READ COMMITTED) sees the first.
--      An exact duplicate is refused here too (P0001 nickname_taken) before
--      profiles_nickname_unique_idx is reached; the index stays as the
--      backstop for the exempt paths (23505, which the app also shows as
--      "That nickname is taken.").
-- Every refusal: SQLSTATE P0001, the message above, detail = the code.
--
-- md5 of the new body (carriage returns removed): profiles_nickname_rules
-- f3782effb78974e2ef65f1d8db04aa5a.

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard.
-- ---------------------------------------------------------------------------
do $$
declare
  v_txt text;
  v_i int;
begin
  if to_regprocedure('public.profiles_nickname_rules()') is not null
     or exists (select 1 from pg_trigger tg where tg.tgrelid = 'public.profiles'::regclass and tg.tgname = 'profiles_nickname_rules') then
    raise exception 'STOP: profiles_nickname_rules already exists (part 1 has run). This file is not re-runnable; run nickname-rules-precheck.sql. Nothing was changed.';
  end if;

  if current_user <> (select pg_get_userbyid(c.relowner)::text from pg_class c where c.oid = 'public.profiles'::regclass) then
    raise exception 'STOP: run this as the owner of public.profiles (%), not %. Nothing was changed.',
      (select pg_get_userbyid(c.relowner)::text from pg_class c where c.oid = 'public.profiles'::regclass), current_user;
  end if;

  select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure('public.profiles_nickname_lock()');
  if v_txt is distinct from '215515390acc9b410afbd71b210d31e0' then
    raise exception 'STOP: profiles_nickname_lock''s body is "%" (expected md5 215515390acc9b410afbd71b210d31e0). Nothing was changed.', coalesce(v_txt, 'missing');
  end if;

  select string_agg(tg.tgname::text, ', ' order by tg.tgname) into v_txt
  from pg_trigger tg where tg.tgrelid = 'public.profiles'::regclass and not tg.tgisinternal;
  if v_txt is distinct from 'profiles_nickname_lock' then
    raise exception 'STOP: profiles has the triggers "%"; expected profiles_nickname_lock alone. Nothing was changed.', coalesce(v_txt, 'none');
  end if;
  if not exists (select 1 from pg_trigger tg
                 where tg.tgrelid = 'public.profiles'::regclass and tg.tgname = 'profiles_nickname_lock'
                   and tg.tgenabled = 'O' and tg.tgfoid = to_regprocedure('public.profiles_nickname_lock()')
                   and (tg.tgtype & 1) = 1 and (tg.tgtype & 2) = 2 and (tg.tgtype & 28) = 4 + 16) then
    raise exception 'STOP: profiles_nickname_lock is not an enabled BEFORE INSERT OR UPDATE ROW trigger. Nothing was changed.';
  end if;

  select format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else '' end into v_txt
  from pg_attribute a where a.attrelid = 'public.profiles'::regclass and a.attname = 'nickname' and not a.attisdropped;
  if v_txt is distinct from 'text not null' then
    raise exception 'STOP: profiles.nickname is "%" (expected text not null). Nothing was changed.', coalesce(v_txt, 'missing');
  end if;

  select pg_get_indexdef(i.indexrelid) into v_txt
  from pg_index i
  where i.indexrelid = to_regclass('public.profiles_nickname_unique_idx') and i.indisunique and i.indisvalid;
  if v_txt is null or strpos(v_txt, 'lower(btrim(nickname))') = 0 then
    raise exception 'STOP: profiles_nickname_unique_idx is "%"; expected a valid unique index on lower(btrim(nickname)). Nothing was changed.', coalesce(v_txt, 'missing');
  end if;

  -- The trigger reads every profile as the caller: it relies on exactly one
  -- SELECT policy (by meaning, not by name -- live it is "Profiles are
  -- viewable by authenticated users") letting any signed-in player read
  -- every row: permissive, cmd SELECT, using auth.role() = 'authenticated'.
  select string_agg(pol.policyname || ' | ' || pol.cmd || ' | ' || pol.permissive || ' | ' || coalesce(pol.qual, '-'), '; ') into v_txt
  from pg_policies pol
  where pol.schemaname = 'public' and pol.tablename = 'profiles' and pol.cmd in ('SELECT', 'ALL');
  if (select count(*) from pg_policies pol
      where pol.schemaname = 'public' and pol.tablename = 'profiles' and pol.cmd in ('SELECT', 'ALL')) <> 1
     or not exists (select 1 from pg_policies pol
                    where pol.schemaname = 'public' and pol.tablename = 'profiles'
                      and pol.cmd = 'SELECT' and pol.permissive = 'PERMISSIVE'
                      and strpos(pol.qual, 'auth.role()') > 0 and strpos(pol.qual, '''authenticated''') > 0) then
    raise exception 'STOP: profiles'' SELECT/ALL policies are "%"; expected exactly one, a permissive SELECT policy using auth.role() = ''authenticated'' (any signed-in player reads every profile). Nothing was changed.', coalesce(v_txt, 'none');
  end if;

  if to_regprocedure('public.get_computer_profiles()') is null
     or not (select p.prosecdef from pg_proc p where p.oid = to_regprocedure('public.get_computer_profiles()'))
     or not has_function_privilege('authenticated', 'public.get_computer_profiles()', 'EXECUTE') then
    raise exception 'STOP: get_computer_profiles() is missing, not security definer, or not executable by authenticated (the computer exemption calls it). Nothing was changed.';
  end if;
  select count(*) into v_i from public.get_computer_profiles() g
  where g.user_id in (select ca.user_id from public.computer_accounts ca);
  if v_i <> (select count(*) from public.computer_accounts) or v_i = 0 then
    raise exception 'STOP: get_computer_profiles() returns % of the % computer accounts. Nothing was changed.', v_i, (select count(*) from public.computer_accounts);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The rules.
-- ---------------------------------------------------------------------------
create function public.profiles_nickname_rules()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_name text := new.nickname;
  v_pre text;
  v_skel text;
  v_message text;
  v_detail text;
begin
  -- (1) WHO: only the client roles, the same test as profiles_nickname_lock.
  -- The owner (the SQL Editor, a migration, a security definer function) is
  -- not limited.
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- (2) WHEN: a new row, or a nickname that really changes. The INSERT of an
  -- upsert fires before the conflict is found; when the row already exists,
  -- the DO UPDATE decides (BEFORE UPDATE, with OLD = the stored row), so
  -- saving the same nickname again never fails here.
  if tg_op = 'INSERT' then
    if exists (select 1 from public.profiles p where p.id = new.id) then
      return new;
    end if;
  elsif new.nickname is not distinct from old.nickname then
    return new;
  end if;

  -- (3) THE CHARACTERS, LENGTH AND SPACING (refused, never trimmed).
  if v_name is null or btrim(v_name) = '' then
    v_message := 'Please enter a nickname.';
  elsif translate(v_name, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .-_''!', '') <> '' then
    v_message := 'Nicknames can use letters, numbers, spaces and . - _ '' ! only.';
  elsif char_length(v_name) > 30 then
    v_message := 'Nicknames are at most 30 characters.';
  elsif v_name <> btrim(v_name) or strpos(v_name, '  ') > 0 then
    v_message := 'Nicknames can''t start or end with a space or have two spaces in a row.';
  elsif translate(v_name, ' .-_''!', '') = '' then
    v_message := 'Nicknames need at least one letter or number.';
  end if;
  if v_message is not null then
    v_detail := 'nickname_invalid';
  end if;

  if v_detail is null then
    -- (4) THE STRICT SKELETON: capital I, |, 1, ! -> l (before lower-casing);
    -- lower-case; remove space . - _ '; 0 -> o (v_pre); rn -> m; vv -> w.
    v_pre := translate(translate(lower(translate(v_name, 'I|1!', 'llll')), ' .-_''', ''), '0', 'o');
    v_skel := replace(replace(v_pre, 'rn', 'm'), 'vv', 'w');

    -- (5) RESERVED: the loose skeleton (i -> l), before and after the rn / vv
    -- step, contains Admin, Administrator, Moderator, Support, Staff,
    -- Official or Raynewood (their loose skeletons below).
    if exists (select 1
               from unnest(array['admln', 'admlnlstrator', 'moderator', 'support', 'staff', 'offlclal', 'raynewood']) as w(word)
               where strpos(translate(v_skel, 'i', 'l'), w.word) > 0
                  or strpos(translate(v_pre, 'i', 'l'), w.word) > 0) then
      v_message := 'That nickname isn''t available.';
      v_detail := 'nickname_unavailable';
    else
      -- (6) TAKEN: another profile with the same strict skeleton. The lock
      -- makes two look-alike claims queue; the lookup after it sees the
      -- first one once it has committed.
      perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('nickname:' || v_skel, 0));
      if exists (select 1
                 from public.profiles p
                 where p.id <> new.id
                   and btrim(p.nickname) <> ''
                   and replace(replace(translate(translate(lower(translate(btrim(p.nickname), 'I|1!', 'llll')), ' .-_''', ''), '0', 'o'), 'rn', 'm'), 'vv', 'w') = v_skel) then
        v_message := 'That nickname is taken.';
        v_detail := 'nickname_taken';
      end if;
    end if;
  end if;

  if v_detail is null then
    return new;
  end if;

  -- (7) THE COMPUTER ACCOUNTS are exempt (asked only when a rule failed).
  if current_user = 'authenticated' then
    if exists (select 1 from public.get_computer_profiles() g where g.user_id = new.id) then
      return new;
    end if;
  end if;

  raise exception using errcode = 'P0001', message = v_message, detail = v_detail;
end;
$$;

comment on function public.profiles_nickname_rules() is
  'Nickname rules: the profiles BEFORE INSERT OR UPDATE trigger (fires after profiles_nickname_lock, by name). For the client roles only, on a new row or a nickname that IS DISTINCT FROM the stored one (an upsert of an existing row is left to its DO UPDATE): refuses bad characters, length or spacing (nickname_invalid), a reserved word in the loose skeleton (nickname_unavailable), and another profile''s strict skeleton (nickname_taken, under an advisory lock on the skeleton). Computer accounts and the owner are exempt; existing nicknames are never changed. Executable by no role. See docs/sql/nickname-rules-part1.sql.';

revoke all on function public.profiles_nickname_rules() from public;
revoke all on function public.profiles_nickname_rules() from anon;
revoke all on function public.profiles_nickname_rules() from authenticated;
revoke all on function public.profiles_nickname_rules() from service_role;

create trigger profiles_nickname_rules
  before insert or update on public.profiles
  for each row
  execute function public.profiles_nickname_rules();

-- ---------------------------------------------------------------------------
-- 2. After: the body as written, the lock untouched, the order, the grants.
-- ---------------------------------------------------------------------------
do $$
declare
  v_txt text;
begin
  select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure('public.profiles_nickname_rules()');
  if v_txt is distinct from 'f3782effb78974e2ef65f1d8db04aa5a' then
    raise exception 'STOP: profiles_nickname_rules'' body md5 is % (expected f3782effb78974e2ef65f1d8db04aa5a; the paste changed it?). Everything in this file is rolled back.', coalesce(v_txt, 'missing');
  end if;
  select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure('public.profiles_nickname_lock()');
  if v_txt is distinct from '215515390acc9b410afbd71b210d31e0' then
    raise exception 'STOP: profiles_nickname_lock changed (md5 %). Everything in this file is rolled back.', coalesce(v_txt, 'missing');
  end if;
  select string_agg(tg.tgname::text, ', ' order by tg.tgname) into v_txt
  from pg_trigger tg where tg.tgrelid = 'public.profiles'::regclass and not tg.tgisinternal;
  if v_txt is distinct from 'profiles_nickname_lock, profiles_nickname_rules' then
    raise exception 'STOP: profiles has the triggers "%" (expected profiles_nickname_lock, profiles_nickname_rules). Everything in this file is rolled back.', coalesce(v_txt, 'none');
  end if;
  if (select p.prosecdef from pg_proc p where p.oid = to_regprocedure('public.profiles_nickname_rules()'))
     or has_function_privilege('authenticated', 'public.profiles_nickname_rules()', 'EXECUTE')
     or has_function_privilege('anon', 'public.profiles_nickname_rules()', 'EXECUTE')
     or (exists (select 1 from pg_roles r where r.rolname = 'service_role')
         and has_function_privilege('service_role', 'public.profiles_nickname_rules()', 'EXECUTE'))
     or exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where p.oid = to_regprocedure('public.profiles_nickname_rules()') and a.grantee = 0) then
    raise exception 'STOP: profiles_nickname_rules is security definer or executable by a client role. Everything in this file is rolled back.';
  end if;
end;
$$;

commit;
