-- NICKNAME RULES, part 1 ROLLBACK: removes the profiles_nickname_rules
-- trigger and its function, leaving profiles exactly as before part 1
-- (profiles_nickname_lock alone, untouched). Run in the Supabase Dashboard
-- -> SQL Editor, only to undo docs/sql/nickname-rules-part1.sql.
--
-- STATUS: written, NOT RUN.
--
-- Part 1 changed no data and no other object, so there is nothing else to
-- restore: no nickname was ever rewritten. Names saved while the rules were
-- in stay as they are (they pass today's checks too).
--
-- GUARD: STOPs (nothing changed) unless the trigger and the function exist
-- with part 1's body (md5 f3782effb78974e2ef65f1d8db04aa5a, carriage
-- returns removed) and profiles_nickname_lock is still
-- 215515390acc9b410afbd71b210d31e0. After: nickname-rules-precheck.sql shows
-- "before part 1".

begin;

do $$
declare
  v_txt text;
begin
  if current_user <> (select pg_get_userbyid(c.relowner)::text from pg_class c where c.oid = 'public.profiles'::regclass) then
    raise exception 'STOP: run this as the owner of public.profiles, not %. Nothing was changed.', current_user;
  end if;
  select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure('public.profiles_nickname_rules()');
  if v_txt is distinct from 'f3782effb78974e2ef65f1d8db04aa5a' then
    raise exception 'STOP: profiles_nickname_rules is "%" (expected part 1''s body, md5 f3782effb78974e2ef65f1d8db04aa5a). Nothing was changed.', coalesce(v_txt, 'missing');
  end if;
  if not exists (select 1 from pg_trigger tg
                 where tg.tgrelid = 'public.profiles'::regclass and tg.tgname = 'profiles_nickname_rules'
                   and tg.tgfoid = to_regprocedure('public.profiles_nickname_rules()')) then
    raise exception 'STOP: the profiles_nickname_rules trigger is missing. Nothing was changed.';
  end if;
  select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure('public.profiles_nickname_lock()');
  if v_txt is distinct from '215515390acc9b410afbd71b210d31e0' then
    raise exception 'STOP: profiles_nickname_lock is "%" (expected md5 215515390acc9b410afbd71b210d31e0). Nothing was changed.', coalesce(v_txt, 'missing');
  end if;
end;
$$;

drop trigger profiles_nickname_rules on public.profiles;
drop function public.profiles_nickname_rules();

do $$
declare
  v_txt text;
begin
  select string_agg(tg.tgname::text, ', ' order by tg.tgname) into v_txt
  from pg_trigger tg where tg.tgrelid = 'public.profiles'::regclass and not tg.tgisinternal;
  if v_txt is distinct from 'profiles_nickname_lock'
     or to_regprocedure('public.profiles_nickname_rules()') is not null
     or (select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure('public.profiles_nickname_lock()'))
        is distinct from '215515390acc9b410afbd71b210d31e0' then
    raise exception 'STOP: after the rollback profiles has the triggers "%" or the lock changed. Everything in this file is rolled back.', coalesce(v_txt, 'none');
  end if;
end;
$$;

commit;
