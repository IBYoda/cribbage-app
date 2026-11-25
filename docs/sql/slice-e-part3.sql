-- Step 3, slice E, PART 3: GRANTS -- revoke the unused broad table
-- privileges and close anon/PUBLIC EXECUTE.
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- WHEN: after part 2 and its verification (or on its own: it does not depend
-- on parts 1 and 2). Separate so it can be rolled back on its own. Then run
-- docs/sql/slice-e-grants-verification.sql and the regression suites.
-- To undo: docs/sql/slice-e-part3-rollback.sql (the exact grants the
-- catalog of 2026-11-24/25 showed).
--
-- WHY: anon and authenticated still hold Supabase's default ALL on the step 3
-- tables (DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE,
-- UPDATE; INSERT already gone on tables and table_members since slice A).
-- The row policies already stop every write a client could send through the
-- API, and PostgREST has no TRUNCATE -- but TRUNCATE ignores row policies,
-- and nothing in the app or the RPCs needs any of it as the client role
-- (every RPC is security definer). Defense in depth, and a smaller GraphQL
-- surface.
--
-- WHAT THE APP WRITES AS THE CLIENT ROLE (checked 2026-11-25; the only
-- direct writes in lib/, components/, app/):
--   profiles        upsert (lib/profileNickname.ts) and update of avatar_url
--                   (app/profile/page.tsx): SELECT, INSERT, UPDATE kept.
--   user_appearance upsert (components/AppearanceProvider.tsx): not touched.
--   tables, games   the admin's Force-End UPDATEs (app/admin/page.tsx): UPDATE
--                   kept (the row policy allows admins only).
--   storage         the avatar upload: storage policies, not table grants.
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold): the four
--      fingerprinted bodies unchanged; the nine tables exist; if
--      public.rls_auto_enable() exists, it is an event-trigger function (an
--      event trigger runs it -- a caller's EXECUTE is never checked for it);
--      the role running this may alter postgres's default privileges (it is
--      postgres, or a member of it); and postgres has no global default row
--      for functions yet, or exactly this file's ({postgres=X/postgres}, a
--      re-run).
--   1. The nine tables, the exact privileges kept (everything else revoked
--      from anon, authenticated and PUBLIC: INSERT where unused, UPDATE where
--      unused, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN):
--        table          authenticated            anon
--        tables         SELECT, UPDATE           SELECT
--        table_members  SELECT                   SELECT
--        games          SELECT, UPDATE           SELECT
--        game_plays     SELECT                   SELECT
--        game_hands     SELECT                   SELECT
--        game_cribs     SELECT                   SELECT
--        game_decks     SELECT                   SELECT   (zero rows, not a
--                                                          permission error)
--        profiles       SELECT, INSERT, UPDATE   SELECT   (table-wide: the
--                                                          upsert writes id)
--        admin_users    SELECT                   SELECT
--      anon keeps SELECT so it gets zero rows (the row policies), not an
--      error: docs/sql/private-tables-verification.sql N1 depends on it.
--      service_role is not touched. user_appearance, table_spectators,
--      attempt_log, computer_accounts, follows, game_results and
--      leaderboard_hidden are already exact and not touched.
--   2. public.rls_auto_enable(): EXECUTE revoked from PUBLIC, anon and
--      authenticated (the only public function a client could execute
--      without being meant to). Its event trigger keeps running it.
--   Every other function's EXECUTE is already as intended (catalog
--   2026-11-25) and is not touched.
--   3. DENY BY DEFAULT for new functions:
--        alter default privileges for role postgres
--          revoke execute on functions from public;
--      WHY: Postgres's built-in default gives PUBLIC (so anon and
--      authenticated) EXECUTE on every new function. postgres's existing
--      default privileges are per-schema rows (public, storage), and a
--      per-schema row only ADDS to the built-in default -- it cannot take
--      PUBLIC away. Only a GLOBAL row (no "in schema") can, so this is the
--      global form. It creates pg_default_acl's global row for postgres /
--      functions: the built-in default minus PUBLIC ({postgres=X/postgres}).
--      WHAT IT AFFECTS: only functions (and procedures) that postgres
--      creates AFTER this, in ANY schema. Existing functions keep their
--      grants exactly. Nothing breaks: every app RPC, chat_topic_allows and
--      the seven slice D helpers already carry their own explicit "grant
--      execute ... to authenticated", and every repo SQL file already
--      revokes from public and grants to authenticated itself. From now on a
--      new client-callable function MUST grant EXECUTE to authenticated
--      itself (as every file already does), or no client can call it. The
--      per-schema rows (postgres + service_role in public; storage's) are
--      untouched, so service_role still gets EXECUTE on postgres's new
--      functions in public. Functions created by other roles
--      (supabase_admin, supabase_auth_admin, supabase_storage_admin, ...)
--      are not affected.
--
-- RE-RUNNABLE: revoke all + grant is idempotent, and so is the default
-- privileges revoke.

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard.
-- ---------------------------------------------------------------------------
do $$
declare
  v_rec record;
  v_txt text;
begin
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
      raise exception 'STOP: % has body md5 %; expected % (LF) or % (CRLF). Nothing was changed.', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf, v_rec.crlf;
    end if;
  end loop;

  select string_agg(x.tbl, ', ') into v_txt
  from (values ('tables'), ('table_members'), ('games'), ('game_plays'), ('game_hands'), ('game_cribs'),
               ('game_decks'), ('profiles'), ('admin_users')) as x(tbl)
  where to_regclass('public.' || x.tbl) is null;
  if v_txt is not null then
    raise exception 'STOP: missing tables: %. Nothing was changed.', v_txt;
  end if;

  if to_regprocedure('public.rls_auto_enable()') is not null
     and not exists (select 1 from pg_event_trigger e where e.evtfoid = to_regprocedure('public.rls_auto_enable()')) then
    raise exception 'STOP: public.rls_auto_enable() exists but no event trigger uses it; revoking its EXECUTE might break a caller. Nothing was changed.';
  end if;

  if not pg_has_role(current_user, 'postgres', 'MEMBER') then
    raise exception 'STOP: % is not postgres (or a member of it), so it cannot alter postgres''s default privileges. Run this as postgres. Nothing was changed.', current_user;
  end if;

  select da.defaclacl::text into v_txt
  from pg_default_acl da
  where da.defaclrole = 'postgres'::regrole and da.defaclnamespace = 0 and da.defaclobjtype = 'f';
  if v_txt is not null and v_txt <> '{postgres=X/postgres}' then
    raise exception 'STOP: postgres already has a global default ACL for functions (%), not the one this file writes ({postgres=X/postgres}). Paste it back. Nothing was changed.', v_txt;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The nine tables.
-- ---------------------------------------------------------------------------
revoke all on table public.tables from anon, authenticated, public;
grant select on table public.tables to anon, authenticated;
grant update on table public.tables to authenticated;

revoke all on table public.table_members from anon, authenticated, public;
grant select on table public.table_members to anon, authenticated;

revoke all on table public.games from anon, authenticated, public;
grant select on table public.games to anon, authenticated;
grant update on table public.games to authenticated;

revoke all on table public.game_plays from anon, authenticated, public;
grant select on table public.game_plays to anon, authenticated;

revoke all on table public.game_hands from anon, authenticated, public;
grant select on table public.game_hands to anon, authenticated;

revoke all on table public.game_cribs from anon, authenticated, public;
grant select on table public.game_cribs to anon, authenticated;

revoke all on table public.game_decks from anon, authenticated, public;
grant select on table public.game_decks to anon, authenticated;

revoke all on table public.profiles from anon, authenticated, public;
grant select on table public.profiles to anon, authenticated;
grant insert, update on table public.profiles to authenticated;

revoke all on table public.admin_users from anon, authenticated, public;
grant select on table public.admin_users to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. rls_auto_enable(): no client EXECUTE (an event trigger runs it).
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is null then
    raise notice 'public.rls_auto_enable() does not exist: nothing to revoke.';
    return;
  end if;
  execute 'revoke execute on function public.rls_auto_enable() from public, anon, authenticated';
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Deny by default: functions postgres creates from now on, in any
--    schema, give PUBLIC no EXECUTE (the global form: only a global row can
--    take away the built-in default's PUBLIC grant).
-- ---------------------------------------------------------------------------
alter default privileges for role postgres revoke execute on functions from public;

commit;
