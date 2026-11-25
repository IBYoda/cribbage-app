-- Step 3, slice E: ROLLBACK of docs/sql/slice-e-part3.sql.
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet. Only if part 3 has to come out.
--
-- WHAT IT DOES (one transaction): puts back exactly the grants the live
-- catalog showed before part 3 (docs/sql/slice-e-catalog.sql, 2026-11-25):
--   * admin_users, game_cribs, game_decks, game_hands, game_plays, games,
--     profiles: ALL (on Postgres 17: DELETE, INSERT, MAINTAIN, REFERENCES,
--     SELECT, TRIGGER, TRUNCATE, UPDATE) for anon and authenticated.
--   * tables, table_members: DELETE, MAINTAIN, REFERENCES, SELECT, TRIGGER,
--     TRUNCATE, UPDATE for anon and authenticated -- NOT INSERT (slice A's
--     lockdown took it, and this file must not give it back).
--   * public.rls_auto_enable(): EXECUTE for PUBLIC, anon and authenticated
--     again -- the catalog (2026-11-25) showed its acl as
--     {=X/postgres,postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres},
--     so the direct anon and authenticated grants are restored too, not only
--     PUBLIC (postgres and service_role were never revoked).
-- No grant to PUBLIC on the tables (the catalog showed none).
--   * The default privileges for new functions: "alter default privileges
--     for role postgres grant execute on functions to public" -- functions
--     postgres creates from then on give PUBLIC EXECUTE again (the built-in
--     default). The catalog's default section showed NO global row for
--     postgres before part 3 (only its per-schema rows for public and
--     storage). That IS exactly representable: part 3's global row is
--     {postgres=X/postgres}; granting PUBLIC back makes it equal to the
--     built-in default ({=X/postgres,postgres=X/postgres}), and Postgres
--     deletes a global pg_default_acl row that equals the built-in default
--     rather than keep it. The check after it raises if the row is still
--     there. Functions created while part 3 was in force keep the grants they
--     were created with (this changes defaults only).
--
-- RE-RUNNABLE: grants are idempotent.

begin;

grant all on table public.admin_users to anon, authenticated;
grant all on table public.game_cribs to anon, authenticated;
grant all on table public.game_decks to anon, authenticated;
grant all on table public.game_hands to anon, authenticated;
grant all on table public.game_plays to anon, authenticated;
grant all on table public.games to anon, authenticated;
grant all on table public.profiles to anon, authenticated;

grant select, update, delete, truncate, references, trigger, maintain on table public.tables to anon, authenticated;
grant select, update, delete, truncate, references, trigger, maintain on table public.table_members to anon, authenticated;

do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is null then
    raise notice 'public.rls_auto_enable() does not exist: nothing to grant.';
    return;
  end if;
  execute 'grant execute on function public.rls_auto_enable() to public';
  execute 'grant execute on function public.rls_auto_enable() to anon, authenticated';
end;
$$;

alter default privileges for role postgres grant execute on functions to public;

do $$
declare
  v_txt text;
begin
  select da.defaclacl::text into v_txt
  from pg_default_acl da
  where da.defaclrole = 'postgres'::regrole and da.defaclnamespace = 0 and da.defaclobjtype = 'f';
  if v_txt is not null then
    raise exception 'STOP: postgres still has a global default ACL for functions (%) after granting PUBLIC back; expected no row (the state before part 3). Everything in this rollback was undone.', v_txt;
  end if;
end;
$$;

commit;
