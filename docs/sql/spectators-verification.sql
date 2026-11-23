-- Spectator seat, slice 1: VERIFICATION of docs/sql/spectators.sql.
--
-- Run in the Supabase Dashboard -> SQL Editor after docs/sql/spectators.sql.
-- The whole file is ONE DO block.
--
-- STATUS: RUN in production on 2026-11-20: "ALL 134 CHECKS PASSED (rolled
-- back). Walk-through: 1 cut round(s), 2 discards, 8 plays, 4 counting
-- states, done." T3 ran (a computer account exists), so 134, not 133.
-- SLICE 2: docs/sql/spectators-join-or-watch.sql (live 2026-11-20) changes
-- watch_table (a table with no live game) and spectator_heartbeat (the place
-- kept between games); its own verification covers them. Re-run now, this
-- file stops at R7 and E3 (they expect slice 1's "There is no game to watch
-- at this table yet."): by design, not a regression.
-- STEP 3, SLICE A (docs/sql/join-create.sql), rewritten 2026-11-23, NOT RUN
-- since: T3 is called as N (A is seated at four tables here, and
-- create_computer_table now refuses a player seated at a table with other
-- humans: one table at a time); R2 and R3 (an unknown and a null code) now
-- expect NO ROW and no error (watch_table no longer raises for a wrong code,
-- so the count of wrong guesses survives). Still stops at R7 as above.
--
-- RUN ORDER:
--   1. docs/sql/spectators-precheck.sql      (read-only)
--   2. docs/sql/spectators.sql
--   3. docs/sql/spectators-verification.sql  (this file)
--
-- It WRITES -- eight temporary accounts in auth.users, test tables, their
-- seats, games played through the real game functions, spectator rows --
-- and then deliberately raises an exception at the very end, which rolls
-- EVERY write back. A check that fails raises its own exception at once,
-- which rolls everything back the same way. It always "fails": the message
-- is the verdict (the dashboard hides notices, so nothing is reported any
-- other way).
--   "ALL n CHECKS PASSED (rolled back) ..." is a pass; the message also lists
--   any "skipped: ..." lines.
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives. It creates no functions,
-- tables or other schema objects.
--
-- Same impersonation as the other suites: request.jwt.claims plus "set
-- local role authenticated" (or anon) to act as a client, and "reset role"
-- to act as the owner between steps. The game is driven AS THE OWNER through
-- the existing internal <name>_as(p_actor, ...) functions (computer-c1-
-- refactor.sql), which is exactly what the public wrappers call; nothing
-- about them is changed or redefined here.
--
-- THE FROZEN now(): a DO block is one transaction, so now() is one instant.
-- "Stale" (not seen for 90 s) is made by moving last_seen_at back 91
-- seconds, as the owner.
--
-- PEOPLE (temporary accounts, created here):
--   A, B    the players (A creates every table, so A is the host).
--   S1..S5  would-be spectators.
--   N       a signed-in user who never watches.
-- TABLES (A creates them, from free 4-digit codes; A and B seated):
--   X  open, PUBLIC, allows spectators: the walk-through table. Its game is
--      started with start_game_with_deal_as and played through a whole hand.
--   P  open, PRIVATE, allows spectators, a game in the cut: watched by code.
--   Z  open, public, does NOT allow spectators, a game in the cut.
--   W  open, allows spectators, NO game (the waiting room).
--   E  allows spectators, ENDED (admin), the way a Force-End leaves it.
--   K  a COMPUTER table (computer_level 'easy', allow_spectators default).
--
-- WHAT IT CHECKS
--   CATALOG
--   C1  tables.allow_spectators: boolean, not null, default false.
--   C2  check tables_spectators_human_only: computer_level is null or not
--       allow_spectators.
--   C3  table_spectators' columns and types, primary key (table_id, user_id).
--   C4  row-level security on table_spectators.
--   C5  table privileges: authenticated SELECT only (no INSERT, UPDATE,
--       DELETE, TRUNCATE, REFERENCES, TRIGGER); anon and service_role none;
--       no PUBLIC grant.
--   C6  exactly one policy: SELECT, permissive, to authenticated, reading
--       auth.uid() and table_members.
--   C7  table_spectators is NOT in the supabase_realtime publication.
--   C8  each of the five functions: return type, security definer, volatile
--       (get_spectator_reveals stable), search_path ''. (5 checks)
--   C9  each of the five: EXECUTE for authenticated; not anon, not
--       service_role, no PUBLIC grant. (5 checks)
--   C10 get_spectator_reveals' body never mentions game_decks and never
--       writes (no insert, update or delete).
--   C11 the C1/C2 fingerprints are still valid: the eight _as bodies and
--       their wrappers have the md5s computer-c1-verification.sql expects.
--   TABLE CREATION
--   T1  a computer table with allow_spectators true is refused (23514).
--   T2  a computer table with the default inserts (allow_spectators false).
--   T3  create_computer_table, called as N (seated nowhere), still works
--       and gives allow_spectators false (skipped if no computer account
--       exists).
--   REFUSALS
--   R1-R9  watch_table: nobody signed in; an unknown code; a null code; an
--       ended table; a computer table; a table without spectators; a table
--       with no live game; A (seated) at X; B (seated) at P -- each with its
--       exact message, except the unknown and the null code: no row and no
--       error (step 3 slice A).
--   U1-U4  nobody signed in: stop_watching and remove_spectator refused;
--       spectator_heartbeat 'not_watching'; get_spectator_reveals null.
--   A1-A5  anon cannot execute any of the five functions (42501).
--   WATCHING AND THE CAP (X's game in the cut)
--   M1  S1 watches X: the right table id, code and game id, a fresh row;
--       M2 the games row's md5 is unchanged.
--   M3  S1 watches P (private) by its code: P's id and P's game.
--   M4  S2, S3, S4 watch X: 4 current spectators.
--   M5  S5 is refused: "Spectators full: this table already has 4
--       spectators."
--   M6  S1 watching X again (already current, 4 current) is a refresh, not
--       refused.
--   M7  S4's row made stale: S5 now watches X.
--   M8  S4's heartbeat: 'not_watching' (stale, and the 4 places are taken);
--       M9 S4's get_spectator_reveals: null.
--   M10 S1's heartbeat: 'ok'.
--   HOST REMOVE
--   H1-H3  B, N and S1 cannot remove S3 ("Only the host can remove a
--       spectator.").
--   H4  A (the host) removes S3; H5 the games row's md5 is unchanged.
--   H6  S3 cannot watch again ("You were removed from watching this
--       table.").
--   H7  S3's heartbeat: 'removed'; H8 S3's get_spectator_reveals: null.
--   H9  S3's stop_watching leaves the removal in place.
--   H10 A removing N (not watching): "That player is not watching this
--       table."
--   H11 A removing S3 again: quiet.
--   STOP
--   S1  S2 stops watching: the row is gone; S2 the games row's md5 is
--       unchanged.
--   S3  S2's heartbeat: 'not_watching'; S4 S2's get_spectator_reveals: null.
--   S5  S2 can watch again (stopping is not a removal).
--   GAME ACTIONS BY A SPECTATOR
--   G1  S1 play_card: refused. G2 S1 leave_table: "You are not a member of
--       this table." G3 S1 set_seat: refused. G4 the games row's md5 is
--       unchanged and S1 is still not in table_members.
--   READS (RLS on table_spectators)
--   L1  A (seated at X) sees X's 5 spectator rows.
--   L2  S1 sees only S1's own 2 rows.
--   L3  N sees none.
--   L4-L6  S1 cannot insert, update or delete rows (42501).
--   L7  anon cannot select (42501).
--   THE WALK-THROUGH (X's game, a whole hand through the _as functions)
--   At EVERY state -- each cut round, each discard (none, then one
--   discarded), each pegging state (before each of the 8 plays), each
--   counting step (0, 1, 2 before the crib is shown, 2 after), and done --
--   three checks (the extra cut rounds of a tie are checked too, but counted
--   once):
--     a  S1's get_spectator_reveals: hands {} before counting and every
--        hand (equal to game_hands) from counting on; crib null before its
--        step (count_step >= players) and equal to game_cribs from it on.
--     b  THE LEAK SCAN: no deck card (game_decks) ever, no crib card before
--        the crib's step, and no hand card before counting, appears ANYWHERE
--        in S1's JSON (keys and values, as text). From the deal on the scan
--        must cover at least 39 cards, so it can't pass by scanning nothing.
--     c  N (never watched), S3 (removed) and S4 (stale) all get null.
--   W-tally  exactly 2 discard states, 8 pegging states, 4 counting states,
--       1 done state and at least 1 cut state were seen.
--   ENDINGS
--   E1  X's game WON (ended, 'won'): S1's get_spectator_reveals is null;
--       E2 S1's heartbeat is 'game_ended'; E3 watch_table: "There is no game
--       to watch at this table yet."
--   E4  B leaves P (leave_table: its game ends 'player_left'): S1's
--       get_spectator_reveals for P's game is null; E5 heartbeat
--       'game_ended'.
--   E6  X ENDED (admin): S1's heartbeat is 'table_ended'; E7 watch_table:
--       "This table has ended."; E8 A's remove_spectator: "This table has
--       ended."
--
-- Expected message:
--   ALL 134 CHECKS PASSED (rolled back). ...
--   (133 when T3 is skipped because no computer account exists.)

do $$
declare
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_s1 uuid := gen_random_uuid();
  v_s2 uuid := gen_random_uuid();
  v_s3 uuid := gen_random_uuid();
  v_s4 uuid := gen_random_uuid();
  v_s5 uuid := gen_random_uuid();
  v_nn uuid := gen_random_uuid();  -- N: signed in, never watches
  v_codes text[];
  v_x uuid;
  v_p uuid;
  v_z uuid;
  v_w uuid;
  v_e uuid;
  v_k uuid;
  v_g uuid;
  v_gp uuid;
  v_gz uuid;
  v_r_table uuid;
  v_r_code text;
  v_r_game uuid;
  v_md5 text;
  v_md5_after text;
  v_level text;
  v_t3_skipped boolean := false;
  v_rec record;
  v_fn text;
  v_txt text;
  v_txt2 text;
  v_msg text;
  v_state text;
  v_n int;
  v_n2 int;
  v_bool boolean;
  v_j jsonb;
  v_j2 jsonb;
  v_j3 jsonb;
  v_j4 jsonb;
  v_want_j jsonb;
  v_crib_j jsonb;
  -- the walk-through
  v_iter int := 0;
  v_status text;
  v_phase text;
  v_step int;
  v_cp uuid;
  v_dealer uuid;
  v_shown boolean;
  v_ids uuid[];
  v_np int;
  v_count int;
  v_hand text[];
  v_card text;
  v_label text;
  v_want_hands boolean;
  v_want_crib boolean;
  v_scan_n int;
  v_leak_n int;
  v_cut_states int := 0;
  v_discard_states int := 0;
  v_play_states int := 0;
  v_count_states int := 0;
  v_done_states int := 0;
  v_checks int := 0;
  v_skips text := '';
  v_expect int;
begin
  -- ==== CATALOG ===============================================================
  if to_regclass('public.table_spectators') is null
     or to_regprocedure('public.get_spectator_reveals(uuid)') is null then
    raise exception 'SETUP: table_spectators or get_spectator_reveals does not exist. Run docs/sql/spectators.sql first.';
  end if;

  -- [C1] tables.allow_spectators.
  select c.data_type || ' ' || c.is_nullable || ' ' || coalesce(c.column_default, 'none')
  into v_txt
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'tables' and c.column_name = 'allow_spectators';
  if v_txt is distinct from 'boolean NO false' then
    raise exception 'FAIL [C1] tables.allow_spectators is "%", expected "boolean NO false".', coalesce(v_txt, 'missing');
  end if;
  v_checks := v_checks + 1;

  -- [C2] The human-only check.
  select pg_get_constraintdef(c.oid) into v_txt
  from pg_constraint c
  where c.conrelid = 'public.tables'::regclass and c.conname = 'tables_spectators_human_only' and c.contype = 'c';
  if v_txt is null or v_txt not ilike '%computer_level is null%or%not allow_spectators%' then
    raise exception 'FAIL [C2] tables_spectators_human_only is "%"; expected CHECK (computer_level IS NULL OR NOT allow_spectators).', coalesce(v_txt, 'missing');
  end if;
  v_checks := v_checks + 1;

  -- [C3] Columns and the primary key.
  select string_agg(c.column_name || ':' || c.data_type || ':' || c.is_nullable, ',' order by c.ordinal_position)
  into v_txt
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'table_spectators';
  select string_agg(a.attname::text, ',' order by k.ord)
  into v_txt2
  from pg_constraint c
  cross join lateral unnest(c.conkey) with ordinality as k(attnum, ord)
  join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
  where c.conrelid = 'public.table_spectators'::regclass and c.contype = 'p';
  if v_txt is distinct from 'table_id:uuid:NO,user_id:uuid:NO,joined_at:timestamp with time zone:NO,last_seen_at:timestamp with time zone:NO,removed_at:timestamp with time zone:YES'
     or v_txt2 is distinct from 'table_id,user_id' then
    raise exception 'FAIL [C3] table_spectators columns "%", primary key "%".', v_txt, v_txt2;
  end if;
  v_checks := v_checks + 1;

  -- [C4] RLS on.
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.table_spectators'::regclass) then
    raise exception 'FAIL [C4] row-level security is OFF on table_spectators.';
  end if;
  v_checks := v_checks + 1;

  -- [C5] Table privileges.
  select string_agg(r.rolname || ' ' || p.priv, ', ' order by r.rolname, p.priv)
  into v_txt
  from (values ('authenticated'), ('anon'), ('service_role')) as r(rolname)
  cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) as p(priv)
  -- (CASE, so a role that doesn't exist is never asked about.)
  where case when exists (select 1 from pg_roles pr where pr.rolname = r.rolname)
             then has_table_privilege(r.rolname, 'public.table_spectators', p.priv)
             else false end;
  select count(*) into v_n
  from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
  where c.oid = 'public.table_spectators'::regclass and a.grantee = 0;
  if v_txt is distinct from 'authenticated SELECT' or v_n <> 0 then
    raise exception 'FAIL [C5] privileges on table_spectators: "%", PUBLIC grants %; expected "authenticated SELECT" and 0.', coalesce(v_txt, 'none'), v_n;
  end if;
  v_checks := v_checks + 1;

  -- [C6] The one policy.
  select count(*) into v_n
  from pg_policies p
  where p.schemaname = 'public' and p.tablename = 'table_spectators';
  select count(*) into v_n2
  from pg_policies p
  where p.schemaname = 'public' and p.tablename = 'table_spectators'
    and p.policyname = 'Table members and the spectator read spectator rows'
    and p.cmd = 'SELECT'
    and p.permissive = 'PERMISSIVE'
    and p.roles = array['authenticated']::name[]
    and p.qual ilike '%auth.uid()%'
    and p.qual ilike '%table_members%'
    and p.with_check is null;
  if v_n <> 1 or v_n2 <> 1 then
    raise exception 'FAIL [C6] table_spectators has % policies (% matching the read policy); expected exactly 1.', v_n, v_n2;
  end if;
  v_checks := v_checks + 1;

  -- [C7] Not in Realtime.
  if exists (select 1 from pg_publication_tables pt
             where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = 'table_spectators') then
    raise exception 'FAIL [C7] table_spectators is in the supabase_realtime publication; it must not be.';
  end if;
  v_checks := v_checks + 1;

  -- [C8] The five functions' shape, and [C9] their EXECUTE grants.
  -- (provolatile is type "char": cast it with ::text before joining it.)
  for v_rec in
    select * from (values
      ('public.watch_table(text)', 'record set definer v empty-path'),
      ('public.stop_watching(uuid)', 'void one definer v empty-path'),
      ('public.remove_spectator(uuid, uuid)', 'void one definer v empty-path'),
      ('public.spectator_heartbeat(uuid)', 'text one definer v empty-path'),
      ('public.get_spectator_reveals(uuid)', 'jsonb one definer s empty-path')
    ) as t(fn, want)
  loop
    select p.prorettype::regtype::text
           || case when p.proretset then ' set' else ' one' end
           || case when p.prosecdef then ' definer ' else ' invoker ' end
           || p.provolatile::text
           || case when coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']
                   then ' empty-path' else ' path:' || coalesce(p.proconfig::text, 'none') end
    into v_txt
    from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is distinct from v_rec.want then
      raise exception 'FAIL [C8] % is "%", expected "%".', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.want;
    end if;
    v_checks := v_checks + 1;

    select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = to_regprocedure(v_rec.fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE';
    select case when exists (select 1 from pg_roles where rolname = 'service_role')
                then has_function_privilege('service_role', v_rec.fn, 'execute')
                else false end
    into v_bool;
    if not has_function_privilege('authenticated', v_rec.fn, 'execute')
       or has_function_privilege('anon', v_rec.fn, 'execute')
       or v_n <> 0
       or v_bool then
      raise exception 'FAIL [C9] % execute: authenticated %, anon %, PUBLIC grants %, service_role %; expected true, false, 0, false.',
        v_rec.fn, has_function_privilege('authenticated', v_rec.fn, 'execute'),
        has_function_privilege('anon', v_rec.fn, 'execute'), v_n, v_bool;
    end if;
    v_checks := v_checks + 1;
  end loop;

  -- [C10] The reveals read never touches the deck and never writes.
  select p.prosrc into v_txt from pg_proc p where p.oid = to_regprocedure('public.get_spectator_reveals(uuid)');
  if v_txt ilike '%game_decks%' or v_txt ~* '\m(insert|update|delete)\M' then
    raise exception 'FAIL [C10] get_spectator_reveals'' body mentions game_decks or a write; it must only read hands and the crib.';
  end if;
  v_checks := v_checks + 1;

  -- [C11] The C1/C2 fingerprints (the md5s in computer-c1-verification.sql):
  -- spectators.sql must not have touched any _as function or its wrapper.
  for v_rec in
    select * from (values
      ('start_game_with_deal', 'uuid', 'uuid, uuid', '8d6ceb9ba00b9f2b6b9b8613e10609df', 'f7df18aedee7d95216674a7687c405a0'),
      ('draw_cut_card', 'uuid', 'uuid, uuid', 'e52f927759d991e13b55a6fa73d39781', '0edacf243b6383d9a6977fedb4bd8392'),
      ('acknowledge_deal_cut', 'uuid', 'uuid, uuid', '1e6e9b06a58d59628ca8b4ae19e6605d', '3ca1514190fa9f57ebd1b78166c26f52'),
      ('discard_to_crib', 'uuid, text[]', 'uuid, uuid, text[]', 'fe4d1bb43ee5d4c38dacac502a8817ab', '325b1a01178582eba9a55d8117db0803'),
      ('play_card', 'uuid, text', 'uuid, uuid, text', '39f2602ae2d547799f722ce434328b1c', 'b0434ffb08c301676a3d25722feba168'),
      ('show_crib', 'uuid', 'uuid, uuid', '46ff0cf6834ba0afae2178a6fc895da5', '17821982fea29ef642fefa6a8d63c711'),
      ('confirm_count', 'uuid, int', 'uuid, uuid, int', '27d9a04b7810746bce691f01ec8feffa', '1d5baa992851570fae14dfcf5fda2853'),
      ('next_hand', 'uuid, int', 'uuid, uuid, int', 'e08be4b22774ad656feed6b3852e0562', '692a77e35e328d7c83ad5de4af69fa51')
    ) as t(fn, sig, as_sig, as_md5, wrap_md5)
  loop
    select md5(replace(p.prosrc, E'\r', '')) into v_txt
    from pg_proc p where p.oid = to_regprocedure('public.' || v_rec.fn || '_as(' || v_rec.as_sig || ')');
    select md5(replace(p.prosrc, E'\r', '')) into v_txt2
    from pg_proc p where p.oid = to_regprocedure('public.' || v_rec.fn || '(' || v_rec.sig || ')');
    if v_txt is distinct from v_rec.as_md5 or v_txt2 is distinct from v_rec.wrap_md5 then
      raise exception 'FAIL [C11] % fingerprints: _as % (expected %), wrapper % (expected %). Run computer-c1-verification.sql.',
        v_rec.fn, coalesce(v_txt, 'missing'), v_rec.as_md5, coalesce(v_txt2, 'missing'), v_rec.wrap_md5;
    end if;
  end loop;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner ====================================================
  begin
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
      (v_a,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'spec-a-'  || v_a::text  || '@verification.invalid', now() - interval '8 minutes', now()),
      (v_b,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'spec-b-'  || v_b::text  || '@verification.invalid', now() - interval '7 minutes', now()),
      (v_s1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'spec-s1-' || v_s1::text || '@verification.invalid', now() - interval '6 minutes', now()),
      (v_s2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'spec-s2-' || v_s2::text || '@verification.invalid', now() - interval '5 minutes', now()),
      (v_s3, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'spec-s3-' || v_s3::text || '@verification.invalid', now() - interval '4 minutes', now()),
      (v_s4, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'spec-s4-' || v_s4::text || '@verification.invalid', now() - interval '3 minutes', now()),
      (v_s5, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'spec-s5-' || v_s5::text || '@verification.invalid', now() - interval '2 minutes', now()),
      (v_nn, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'spec-n-'  || v_nn::text || '@verification.invalid', now() - interval '1 minute', now());
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts in auth.users: % (%).', sqlerrm, sqlstate;
  end;

  -- Nine free codes: X, P, Z, W, E, K, the refused computer table (T1),
  -- create_computer_table (T3), and one left unused (an unknown code).
  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0'))
    order by n
    limit 9
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 9 then
    raise exception 'SETUP: fewer than nine unused table codes.';
  end if;

  begin
    -- Members one at a time, so the seat trigger seats them in order.
    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[1], v_a, true, true) returning id into v_x;
    insert into public.table_members (table_id, user_id) values (v_x, v_a);
    insert into public.table_members (table_id, user_id) values (v_x, v_b);

    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[2], v_a, false, true) returning id into v_p;
    insert into public.table_members (table_id, user_id) values (v_p, v_a);
    insert into public.table_members (table_id, user_id) values (v_p, v_b);

    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[3], v_a, true, false) returning id into v_z;
    insert into public.table_members (table_id, user_id) values (v_z, v_a);
    insert into public.table_members (table_id, user_id) values (v_z, v_b);

    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[4], v_a, true, true) returning id into v_w;
    insert into public.table_members (table_id, user_id) values (v_w, v_a);
    insert into public.table_members (table_id, user_id) values (v_w, v_b);

    -- Seated first, then ended: the way a Force-End leaves a table.
    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[5], v_a, true, true) returning id into v_e;
    insert into public.table_members (table_id, user_id) values (v_e, v_a);
    insert into public.table_members (table_id, user_id) values (v_e, v_b);
    update public.tables set status = 'ended', ended_reason = 'admin' where id = v_e;

    -- Games in the cut at P and Z (dated an hour back, as the other suites
    -- do, so nothing mistakes them for a game made by the functions now).
    insert into public.games (table_id, created_by, status, players, deal_cut, created_at)
    values (v_p, v_a, 'cutting', array[v_a, v_b], '[[]]'::jsonb, now() - interval '1 hour')
    returning id into v_gp;
    insert into public.games (table_id, created_by, status, players, deal_cut, created_at)
    values (v_z, v_a, 'cutting', array[v_a, v_b], '[[]]'::jsonb, now() - interval '1 hour')
    returning id into v_gz;

    -- X's game, through the real function (as A): a cut for deal.
    v_g := public.start_game_with_deal_as(v_a, v_x);
  exception when others then
    raise exception 'SETUP: could not create the test tables, seats and games: % (%).', sqlerrm, sqlstate;
  end;
  if v_g is null or (select g.status from public.games g where g.id = v_g) is distinct from 'cutting' then
    raise exception 'SETUP: X''s first game is not a cut for deal (game %, status %).',
      v_g, (select g.status from public.games g where g.id = v_g);
  end if;

  -- ==== TABLE CREATION =========================================================
  -- [T1] A computer table that allows spectators is refused.
  v_state := null;
  begin
    insert into public.tables (code, created_by, computer_level, allow_spectators) values (v_codes[7], v_a, 'easy', true);
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from '23514' then
    raise exception 'FAIL [T1] a computer table with allow_spectators true: %; expected 23514 (check violation).', coalesce(v_state, 'inserted');
  end if;
  v_checks := v_checks + 1;

  -- [T2] A computer table with the default inserts, not allowing spectators.
  begin
    insert into public.tables (code, created_by, computer_level) values (v_codes[6], v_a, 'easy') returning id into v_k;
    insert into public.table_members (table_id, user_id) values (v_k, v_a);
  exception when others then
    raise exception 'FAIL [T2] a computer table with the default could not be created: % (%).', sqlerrm, sqlstate;
  end;
  if (select t.allow_spectators from public.tables t where t.id = v_k) is distinct from false then
    raise exception 'FAIL [T2] the computer table''s allow_spectators is not false.';
  end if;
  v_checks := v_checks + 1;

  -- [T3] create_computer_table, as N (seated nowhere: A is seated at four
  -- tables, which one table at a time refuses), unchanged: allow_spectators
  -- false.
  select ca.level into v_level from public.computer_accounts ca order by ca.level limit 1;
  if v_level is null then
    v_t3_skipped := true;
    v_skips := v_skips || ' skipped T3: no computer account is set up.';
  else
    perform set_config('request.jwt.claims', json_build_object('sub', v_nn, 'role', 'authenticated')::text, true);
    v_msg := null;
    v_r_table := null;
    execute 'set local role authenticated';
    begin
      select c.table_id into v_r_table from public.create_computer_table(v_level, v_codes[8]) c;
    exception when others then
      v_msg := sqlstate || ' ' || sqlerrm;
    end;
    execute 'reset role';
    if v_msg is not null or v_r_table is null
       or (select t.allow_spectators from public.tables t where t.id = v_r_table) is distinct from false
       or (select t.computer_level from public.tables t where t.id = v_r_table) is distinct from v_level then
      raise exception 'FAIL [T3] create_computer_table(%): error %, table %; expected a computer table with allow_spectators false.',
        v_level, coalesce(v_msg, 'none'), v_r_table;
    end if;
    v_checks := v_checks + 1;
  end if;

  -- ==== REFUSALS ===============================================================
  -- [R1-R9] watch_table, each with its exact message.
  for v_rec in
    select * from (values
      ('R1 nobody signed in', null::uuid, v_codes[1], 'You must be logged in to watch a table.'),
      -- NULL want: no row and no error (a wrong code is answered with no row
      -- since step 3 slice A, docs/sql/join-create.sql).
      ('R2 an unknown code', v_s1, v_codes[9], null::text),
      ('R3 a null code', v_s1, null::text, null::text),
      ('R4 an ended table (E)', v_s1, v_codes[5], 'This table has ended.'),
      ('R5 a computer table (K)', v_s1, v_codes[6], 'Computer tables cannot be watched.'),
      ('R6 a table without spectators (Z)', v_s1, v_codes[3], 'This table does not allow spectators.'),
      ('R7 a table with no live game (W)', v_s1, v_codes[4], 'There is no game to watch at this table yet.'),
      ('R8 A, seated at X', v_a, v_codes[1], 'You are seated at this table.'),
      ('R9 B, seated at P', v_b, v_codes[2], 'You are seated at this table.')
    ) as t(label, actor, code, want)
  loop
    if v_rec.actor is null then
      perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
    else
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.actor, 'role', 'authenticated')::text, true);
    end if;
    v_msg := null;
    v_r_table := null;
    execute 'set local role authenticated';
    begin
      select w.table_id into v_r_table from public.watch_table(v_rec.code) w;
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_rec.want is null then
      if v_msg is not null or v_r_table is not null then
        raise exception 'FAIL [%] watch_table: error %, table %; expected no row and no error.', v_rec.label, coalesce('"' || v_msg || '"', 'none'), v_r_table;
      end if;
    elsif v_msg is distinct from v_rec.want then
      raise exception 'FAIL [%] watch_table: %; expected "%".', v_rec.label, coalesce('"' || v_msg || '"', 'allowed'), v_rec.want;
    end if;
    v_checks := v_checks + 1;
  end loop;
  if exists (select 1 from public.table_spectators ts where ts.user_id in (v_s1, v_a, v_b)) then
    raise exception 'FAIL [R] a refused watch_table left a table_spectators row.';
  end if;

  -- [U1-U4] Nobody signed in, the other four functions.
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.stop_watching(v_x); exception when others then v_msg := sqlerrm; end;
  v_txt := null;
  begin perform public.remove_spectator(v_x, v_s1); exception when others then v_txt := sqlerrm; end;
  v_txt2 := public.spectator_heartbeat(v_x);
  v_j := public.get_spectator_reveals(v_g);
  execute 'reset role';
  if v_msg is distinct from 'You must be logged in to stop watching.' then
    raise exception 'FAIL [U1] stop_watching with nobody signed in: %.', coalesce(v_msg, 'allowed');
  end if;
  v_checks := v_checks + 1;
  if v_txt is distinct from 'You must be logged in to remove a spectator.' then
    raise exception 'FAIL [U2] remove_spectator with nobody signed in: %.', coalesce(v_txt, 'allowed');
  end if;
  v_checks := v_checks + 1;
  if v_txt2 is distinct from 'not_watching' then
    raise exception 'FAIL [U3] spectator_heartbeat with nobody signed in: %; expected not_watching.', v_txt2;
  end if;
  v_checks := v_checks + 1;
  if v_j is not null then
    raise exception 'FAIL [U4] get_spectator_reveals with nobody signed in: %; expected null.', v_j;
  end if;
  v_checks := v_checks + 1;

  -- [A1-A5] anon cannot execute any of them.
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  for v_rec in
    select * from (values
      ('A1 watch_table', format('select * from public.watch_table(%L)', v_codes[1])),
      ('A2 stop_watching', format('select public.stop_watching(%L::uuid)', v_x)),
      ('A3 remove_spectator', format('select public.remove_spectator(%L::uuid, %L::uuid)', v_x, v_s1)),
      ('A4 spectator_heartbeat', format('select public.spectator_heartbeat(%L::uuid)', v_x)),
      ('A5 get_spectator_reveals', format('select public.get_spectator_reveals(%L::uuid)', v_g))
    ) as t(label, sql)
  loop
    v_state := null;
    execute 'set local role anon';
    begin
      execute v_rec.sql;
    exception when others then
      v_state := sqlstate;
    end;
    execute 'reset role';
    if v_state is distinct from '42501' then
      raise exception 'FAIL [%] anon: %; expected 42501 (permission denied).', v_rec.label, coalesce(v_state, 'it ran');
    end if;
    v_checks := v_checks + 1;
  end loop;

  -- ==== WATCHING AND THE CAP (X in the cut) ===================================
  -- [M1] S1 watches X; [M2] the game row is untouched.
  select md5(g::text) into v_md5 from public.games g where g.id = v_g;
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select w.table_id, w.code, w.game_id into v_r_table, v_r_code, v_r_game from public.watch_table(v_codes[1]) w;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_r_table is distinct from v_x or v_r_code is distinct from v_codes[1] or v_r_game is distinct from v_g
     or not exists (select 1 from public.table_spectators ts
                    where ts.table_id = v_x and ts.user_id = v_s1 and ts.removed_at is null and ts.last_seen_at = now()) then
    raise exception 'FAIL [M1] S1 watching X: error %, got (%, %, %); expected (%, %, %) and a fresh row.',
      coalesce(v_msg, 'none'), v_r_table, v_r_code, v_r_game, v_x, v_codes[1], v_g;
  end if;
  v_checks := v_checks + 1;
  select md5(g::text) into v_md5_after from public.games g where g.id = v_g;
  if v_md5_after is distinct from v_md5 then
    raise exception 'FAIL [M2] watch_table changed the games row.';
  end if;
  v_checks := v_checks + 1;

  -- [M3] S1 watches P (PRIVATE) by its code.
  v_msg := null;
  execute 'set local role authenticated';
  begin
    select w.table_id, w.game_id into v_r_table, v_r_game from public.watch_table(v_codes[2]) w;
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or v_r_table is distinct from v_p or v_r_game is distinct from v_gp then
    raise exception 'FAIL [M3] S1 watching private P by code: error %, got (%, %); expected (%, %).',
      coalesce(v_msg, 'none'), v_r_table, v_r_game, v_p, v_gp;
  end if;
  v_checks := v_checks + 1;

  -- [M4] S2, S3, S4 watch X: 4 current.
  foreach v_cp in array array[v_s2, v_s3, v_s4] loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_cp, 'role', 'authenticated')::text, true);
    v_msg := null;
    execute 'set local role authenticated';
    begin
      perform 1 from public.watch_table(v_codes[1]);
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_msg is not null then
      raise exception 'FAIL [M4] % watching X was refused: %.', v_cp, v_msg;
    end if;
  end loop;
  select count(*) into v_n from public.table_spectators ts
  where ts.table_id = v_x and ts.removed_at is null and ts.last_seen_at > now() - interval '90 seconds';
  if v_n <> 4 then
    raise exception 'FAIL [M4] X has % current spectators; expected 4.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [M5] The fifth is refused.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s5, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'Spectators full: this table already has 4 spectators.'
     or exists (select 1 from public.table_spectators ts where ts.table_id = v_x and ts.user_id = v_s5) then
    raise exception 'FAIL [M5] S5 as the fifth spectator: %; expected "Spectators full: this table already has 4 spectators." and no row.',
      coalesce(v_msg, 'allowed');
  end if;
  v_checks := v_checks + 1;

  -- [M6] S1 again: a refresh, not refused.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [M6] S1 (already watching, 4 current) watching X again: %; expected a refresh.', v_msg;
  end if;
  v_checks := v_checks + 1;

  -- [M7] S4 goes stale: S5 now gets in.
  update public.table_spectators set last_seen_at = now() - interval '91 seconds'
  where table_id = v_x and user_id = v_s4;
  perform set_config('request.jwt.claims', json_build_object('sub', v_s5, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'FAIL [M7] S5 watching X after S4 went stale: %; a stale row must not count toward the cap.', v_msg;
  end if;
  v_checks := v_checks + 1;

  -- [M8] S4's heartbeat: stale and the places are taken. [M9] S4 sees nothing.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s4, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_txt := public.spectator_heartbeat(v_x);
  v_j := public.get_spectator_reveals(v_g);
  execute 'reset role';
  if v_txt is distinct from 'not_watching'
     or (select ts.last_seen_at from public.table_spectators ts where ts.table_id = v_x and ts.user_id = v_s4) > now() - interval '90 seconds' then
    raise exception 'FAIL [M8] stale S4''s heartbeat with 4 current: %; expected not_watching and the row left stale.', v_txt;
  end if;
  v_checks := v_checks + 1;
  if v_j is not null then
    raise exception 'FAIL [M9] stale S4''s get_spectator_reveals: %; expected null.', v_j;
  end if;
  v_checks := v_checks + 1;

  -- [M10] S1's heartbeat.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_txt := public.spectator_heartbeat(v_x);
  execute 'reset role';
  if v_txt is distinct from 'ok' then
    raise exception 'FAIL [M10] S1''s heartbeat: %; expected ok.', v_txt;
  end if;
  v_checks := v_checks + 1;

  -- ==== HOST REMOVE ============================================================
  -- [H1-H3] Not the host: refused.
  for v_rec in
    select * from (values ('H1 B', v_b), ('H2 N', v_nn), ('H3 S1', v_s1)) as t(label, actor)
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_rec.actor, 'role', 'authenticated')::text, true);
    v_msg := null;
    execute 'set local role authenticated';
    begin
      perform public.remove_spectator(v_x, v_s3);
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_msg is distinct from 'Only the host can remove a spectator.' then
      raise exception 'FAIL [%] removing S3: %; expected "Only the host can remove a spectator."', v_rec.label, coalesce(v_msg, 'allowed');
    end if;
    v_checks := v_checks + 1;
  end loop;
  if exists (select 1 from public.table_spectators ts where ts.table_id = v_x and ts.removed_at is not null) then
    raise exception 'FAIL [H1-H3] a refused removal set removed_at.';
  end if;

  -- [H4] A, the host, removes S3. [H5] The game row is untouched.
  select md5(g::text) into v_md5 from public.games g where g.id = v_g;
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform public.remove_spectator(v_x, v_s3);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null
     or (select ts.removed_at from public.table_spectators ts where ts.table_id = v_x and ts.user_id = v_s3) is null then
    raise exception 'FAIL [H4] the host removing S3: %; expected removed_at set.', coalesce(v_msg, 'no error, but removed_at is null');
  end if;
  v_checks := v_checks + 1;
  select md5(g::text) into v_md5_after from public.games g where g.id = v_g;
  if v_md5_after is distinct from v_md5 then
    raise exception 'FAIL [H5] remove_spectator changed the games row.';
  end if;
  v_checks := v_checks + 1;

  -- [H6-H9] S3: can't watch again, heartbeat 'removed', sees nothing, and
  -- stop_watching doesn't lift the removal.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s3, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  v_txt := public.spectator_heartbeat(v_x);
  v_j := public.get_spectator_reveals(v_g);
  v_txt2 := null;
  begin
    perform public.stop_watching(v_x);
  exception when others then
    v_txt2 := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'You were removed from watching this table.' then
    raise exception 'FAIL [H6] removed S3 watching X again: %; expected "You were removed from watching this table."', coalesce(v_msg, 'allowed');
  end if;
  v_checks := v_checks + 1;
  if v_txt is distinct from 'removed' then
    raise exception 'FAIL [H7] removed S3''s heartbeat: %; expected removed.', v_txt;
  end if;
  v_checks := v_checks + 1;
  if v_j is not null then
    raise exception 'FAIL [H8] removed S3''s get_spectator_reveals: %; expected null.', v_j;
  end if;
  v_checks := v_checks + 1;
  if v_txt2 is not null
     or (select ts.removed_at from public.table_spectators ts where ts.table_id = v_x and ts.user_id = v_s3) is null then
    raise exception 'FAIL [H9] removed S3''s stop_watching: error %, or the removal was lifted.', coalesce(v_txt2, 'none');
  end if;
  v_checks := v_checks + 1;

  -- [H10] Removing someone who isn't watching. [H11] Removing S3 again.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  v_msg := null;
  v_txt := null;
  execute 'set local role authenticated';
  begin
    perform public.remove_spectator(v_x, v_nn);
  exception when others then
    v_msg := sqlerrm;
  end;
  begin
    perform public.remove_spectator(v_x, v_s3);
  exception when others then
    v_txt := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is distinct from 'That player is not watching this table.'
     or exists (select 1 from public.table_spectators ts where ts.user_id = v_nn) then
    raise exception 'FAIL [H10] removing N (not watching): %; expected "That player is not watching this table." and no row.', coalesce(v_msg, 'allowed');
  end if;
  v_checks := v_checks + 1;
  if v_txt is not null then
    raise exception 'FAIL [H11] removing S3 a second time: %; expected quiet.', v_txt;
  end if;
  v_checks := v_checks + 1;

  -- ==== STOP ===================================================================
  -- [S1] S2 stops: the row goes. [S2] The game row is untouched.
  select md5(g::text) into v_md5 from public.games g where g.id = v_g;
  perform set_config('request.jwt.claims', json_build_object('sub', v_s2, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform public.stop_watching(v_x);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null or exists (select 1 from public.table_spectators ts where ts.table_id = v_x and ts.user_id = v_s2) then
    raise exception 'FAIL [S1] S2 stopping: error %, or the row is still there.', coalesce(v_msg, 'none');
  end if;
  v_checks := v_checks + 1;
  select md5(g::text) into v_md5_after from public.games g where g.id = v_g;
  if v_md5_after is distinct from v_md5 then
    raise exception 'FAIL [S2] stop_watching changed the games row.';
  end if;
  v_checks := v_checks + 1;

  -- [S3] [S4] S2 after stopping. [S5] S2 watches again.
  execute 'set local role authenticated';
  v_txt := public.spectator_heartbeat(v_x);
  v_j := public.get_spectator_reveals(v_g);
  v_msg := null;
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_txt is distinct from 'not_watching' then
    raise exception 'FAIL [S3] S2''s heartbeat after stopping: %; expected not_watching.', v_txt;
  end if;
  v_checks := v_checks + 1;
  if v_j is not null then
    raise exception 'FAIL [S4] S2''s get_spectator_reveals after stopping: %; expected null.', v_j;
  end if;
  v_checks := v_checks + 1;
  if v_msg is not null then
    raise exception 'FAIL [S5] S2 watching again after stopping: %; stopping is not a removal.', v_msg;
  end if;
  v_checks := v_checks + 1;

  -- ==== GAME ACTIONS BY A SPECTATOR ===========================================
  select md5(g::text) into v_md5 from public.games g where g.id = v_g;
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_msg := null;
  begin perform public.play_card(v_g, 'AS'); exception when others then v_msg := sqlerrm; end;
  v_txt := null;
  begin perform public.leave_table(v_x); exception when others then v_txt := sqlerrm; end;
  v_txt2 := null;
  begin perform public.set_seat(v_x, v_s1, 1); exception when others then v_txt2 := sqlerrm; end;
  execute 'reset role';
  if v_msg is null then
    raise exception 'FAIL [G1] spectator S1''s play_card was allowed.';
  end if;
  v_checks := v_checks + 1;
  if v_txt is distinct from 'You are not a member of this table.' then
    raise exception 'FAIL [G2] spectator S1''s leave_table: %; expected "You are not a member of this table."', coalesce(v_txt, 'allowed');
  end if;
  v_checks := v_checks + 1;
  if v_txt2 is null then
    raise exception 'FAIL [G3] spectator S1''s set_seat was allowed.';
  end if;
  v_checks := v_checks + 1;
  select md5(g::text) into v_md5_after from public.games g where g.id = v_g;
  if v_md5_after is distinct from v_md5
     or exists (select 1 from public.table_members tm where tm.user_id = v_s1) then
    raise exception 'FAIL [G4] a spectator''s refused actions changed the games row or seated S1.';
  end if;
  v_checks := v_checks + 1;

  -- ==== READS (RLS on table_spectators) ========================================
  -- [L1] A, seated at X, sees X's five rows (S1, S2, S3 removed, S4 stale, S5).
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from public.table_spectators ts where ts.table_id = v_x;
  execute 'reset role';
  if v_n <> 5 then
    raise exception 'FAIL [L1] A (seated at X) sees % of X''s spectator rows; expected 5.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [L2] S1 sees only S1's own rows (X and P).
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*), count(*) filter (where ts.user_id <> v_s1) into v_n, v_n2 from public.table_spectators ts;
  execute 'reset role';
  if v_n <> 2 or v_n2 <> 0 then
    raise exception 'FAIL [L2] S1 sees % rows (% of other people); expected 2 and 0.', v_n, v_n2;
  end if;
  v_checks := v_checks + 1;

  -- [L3] N sees none.
  perform set_config('request.jwt.claims', json_build_object('sub', v_nn, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from public.table_spectators ts;
  execute 'reset role';
  if v_n <> 0 then
    raise exception 'FAIL [L3] N sees % spectator rows; expected 0.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- [L4-L6] S1 cannot write directly.
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  for v_rec in
    select * from (values
      ('L4 insert', format('insert into public.table_spectators (table_id, user_id) values (%L::uuid, %L::uuid)', v_w, v_s1)),
      ('L5 update', format('update public.table_spectators set removed_at = null, last_seen_at = now() where user_id = %L::uuid', v_s1)),
      ('L6 delete', format('delete from public.table_spectators where user_id = %L::uuid', v_s1))
    ) as t(label, sql)
  loop
    v_state := null;
    execute 'set local role authenticated';
    begin
      execute v_rec.sql;
    exception when others then
      v_state := sqlstate;
    end;
    execute 'reset role';
    if v_state is distinct from '42501' then
      raise exception 'FAIL [%] S1 writing table_spectators directly: %; expected 42501.', v_rec.label, coalesce(v_state, 'allowed');
    end if;
    v_checks := v_checks + 1;
  end loop;

  -- [L7] anon cannot read.
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  v_state := null;
  execute 'set local role anon';
  begin
    select count(*) into v_n from public.table_spectators;
  exception when others then
    v_state := sqlstate;
  end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [L7] anon reading table_spectators: %; expected 42501.', coalesce(v_state, 'allowed');
  end if;
  v_checks := v_checks + 1;

  -- ==== THE WALK-THROUGH =======================================================
  -- One state per turn of the loop: check (as S1, N, S3, S4), then move the
  -- game on by one action, as the owner, through the _as functions.
  loop
    v_iter := v_iter + 1;
    if v_iter > 60 then
      raise exception 'FAIL [W] the walk-through did not finish in 60 states.';
    end if;

    select g.status, g.phase, g.count_step, g.current_player, g.dealer_id, g.crib_revealed,
           coalesce(g.discarded_by, '{}'), coalesce(array_length(g.players, 1), 2), g.play_count
    into v_status, v_phase, v_step, v_cp, v_dealer, v_shown, v_ids, v_np, v_count
    from public.games g where g.id = v_g;

    if v_status is distinct from 'cutting' and v_status is distinct from 'active' then
      raise exception 'FAIL [W] X''s game is "%" mid-walk-through; expected cutting or active.', v_status;
    end if;

    if v_status = 'cutting' then
      v_label := 'cut, round ' || (v_cut_states + 1);
    elsif v_phase = 'discard' then
      v_label := 'discard, ' || coalesce(array_length(v_ids, 1), 0) || ' discarded';
    elsif v_phase = 'play' then
      v_label := 'pegging, ' || (select count(*) from public.game_plays gp where gp.game_id = v_g and gp.kind = 'play') || ' played';
    elsif v_phase = 'counting' then
      v_label := 'counting step ' || v_step;
      if v_shown then
        v_label := v_label || ', crib shown';
      end if;
    else
      v_label := coalesce(v_phase, '(no phase)');
    end if;

    v_want_hands := v_status = 'active' and v_phase in ('counting', 'done');
    v_want_crib := v_status = 'active' and (v_phase = 'done' or (v_phase = 'counting' and v_step >= v_np));

    -- What each one gets.
    perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_j := public.get_spectator_reveals(v_g);
    execute 'reset role';
    perform set_config('request.jwt.claims', json_build_object('sub', v_nn, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_j2 := public.get_spectator_reveals(v_g);
    execute 'reset role';
    perform set_config('request.jwt.claims', json_build_object('sub', v_s3, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_j3 := public.get_spectator_reveals(v_g);
    execute 'reset role';
    perform set_config('request.jwt.claims', json_build_object('sub', v_s4, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_j4 := public.get_spectator_reveals(v_g);
    execute 'reset role';

    -- The truth, as the owner.
    select coalesce(jsonb_object_agg(h.user_id::text, to_jsonb(h.cards)), '{}'::jsonb)
    into v_want_j
    from public.game_hands h where h.game_id = v_g;
    v_crib_j := null;
    select to_jsonb(c.cards) into v_crib_j from public.game_cribs c where c.game_id = v_g;

    -- [W a] S1's view.
    v_txt := case when v_want_hands then 'every hand' else '{}' end;
    v_txt2 := case when v_want_crib then 'the crib' else 'null' end;
    if v_j is null
       or (v_j ->> 'game_id') is distinct from v_g::text
       or (v_want_hands and (v_j -> 'hands') is distinct from v_want_j)
       or (v_want_hands and (select count(*) from jsonb_object_keys(v_j -> 'hands')) <> v_np)
       or (not v_want_hands and (v_j -> 'hands') is distinct from '{}'::jsonb)
       or (v_want_crib and (v_crib_j is null or (v_j -> 'crib') is distinct from v_crib_j))
       or (not v_want_crib and coalesce(v_j -> 'crib', 'null'::jsonb) is distinct from 'null'::jsonb) then
      raise exception 'FAIL [W a, %] S1 got %; expected hands % and crib %.', v_label, coalesce(v_j::text, 'null'), v_txt, v_txt2;
    end if;

    -- [W b] The leak scan: anywhere in S1's JSON, as text.
    select count(*),
           count(*) filter (where position('"' || f.c || '"' in coalesce(v_j::text, '')) > 0),
           string_agg(f.c, ',') filter (where position('"' || f.c || '"' in coalesce(v_j::text, '')) > 0)
    into v_scan_n, v_leak_n, v_msg
    from (
      select unnest(d.cards) as c from public.game_decks d where d.game_id = v_g
      union all
      select unnest(cr.cards) from public.game_cribs cr where cr.game_id = v_g and not v_want_crib
      union all
      select unnest(h.cards) from public.game_hands h where h.game_id = v_g and not v_want_hands
    ) f;
    if v_leak_n <> 0 then
      raise exception 'FAIL [W b, %] LEAK: S1''s JSON holds hidden card(s) %: %.', v_label, v_msg, v_j;
    end if;
    if v_status = 'active' and v_scan_n < 39 then
      raise exception 'FAIL [W b, %] the leak scan covered only % cards; expected at least 39 once dealt.', v_label, v_scan_n;
    end if;

    -- [W c] N (never watched), S3 (removed), S4 (stale): nothing.
    if v_j2 is not null or v_j3 is not null or v_j4 is not null then
      raise exception 'FAIL [W c, %] N got %, removed S3 got %, stale S4 got %; expected null for all three.',
        v_label, coalesce(v_j2::text, 'null'), coalesce(v_j3::text, 'null'), coalesce(v_j4::text, 'null');
    end if;

    -- Counted once per state (a tied cut's extra rounds are checked, not counted).
    if v_status <> 'cutting' or v_cut_states = 0 then
      v_checks := v_checks + 3;
    end if;

    -- Move the game on by one action, as the owner.
    begin
      if v_status = 'cutting' then
        v_cut_states := v_cut_states + 1;
        if v_cut_states > 12 then
          raise exception 'no decisive cut in 12 rounds';
        end if;
        perform public.draw_cut_card_as(v_a, v_g);
        perform public.draw_cut_card_as(v_b, v_g);
        perform public.acknowledge_deal_cut_as(v_a, v_g);
        perform public.acknowledge_deal_cut_as(v_b, v_g);
      elsif v_phase = 'discard' then
        v_discard_states := v_discard_states + 1;
        if not (v_a = any(v_ids)) then
          select gh.cards into v_hand from public.game_hands gh where gh.game_id = v_g and gh.user_id = v_a;
          perform public.discard_to_crib_as(v_a, v_g, v_hand[1:2]);
        else
          select gh.cards into v_hand from public.game_hands gh where gh.game_id = v_g and gh.user_id = v_b;
          perform public.discard_to_crib_as(v_b, v_g, v_hand[1:2]);
        end if;
      elsif v_phase = 'play' then
        v_play_states := v_play_states + 1;
        -- The first legal card of the player whose turn it is.
        v_card := null;
        select c into v_card
        from unnest((select gh.cards from public.game_hands gh where gh.game_id = v_g and gh.user_id = v_cp)) as c
        where not exists (
                select 1 from public.game_plays gp
                where gp.game_id = v_g and gp.user_id = v_cp and gp.kind = 'play' and gp.card = c)
          and public.card_play_value(c) + v_count <= 31
        order by c
        limit 1;
        if v_card is null then
          raise exception 'the player whose turn it is has no legal card at count %', v_count;
        end if;
        perform public.play_card_as(v_cp, v_g, v_card);
      elsif v_phase = 'counting' then
        v_count_states := v_count_states + 1;
        if v_step = v_np and not v_shown then
          perform public.show_crib_as(v_dealer, v_g);
        else
          perform public.confirm_count_as(v_cp, v_g, v_step);
        end if;
      elsif v_phase = 'done' then
        v_done_states := v_done_states + 1;
      else
        raise exception 'unexpected phase %', v_phase;
      end if;
    exception when others then
      raise exception 'SETUP [W, %] the game could not move on: % (%).', v_label, sqlerrm, sqlstate;
    end;

    exit when v_status = 'active' and v_phase = 'done';
  end loop;

  -- [W tally] Every kind of state was seen, as often as a 2-player hand has it.
  if v_cut_states < 1 or v_discard_states <> 2 or v_play_states <> 8 or v_count_states <> 4 or v_done_states <> 1 then
    raise exception 'FAIL [W tally] states seen: cut %, discard %, pegging %, counting %, done %; expected >=1, 2, 8, 4, 1.',
      v_cut_states, v_discard_states, v_play_states, v_count_states, v_done_states;
  end if;
  v_checks := v_checks + 1;

  -- ==== ENDINGS ================================================================
  -- [E1-E3] X's game is WON (as award_points would leave it). The win
  -- trigger's game_results row is rolled back with everything else.
  update public.games
  set status = 'ended', ended_reason = 'won', winner_id = v_a, current_player = null
  where id = v_g;
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_j := public.get_spectator_reveals(v_g);
  v_txt := public.spectator_heartbeat(v_x);
  v_msg := null;
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_j is not null then
    raise exception 'FAIL [E1] S1''s get_spectator_reveals for the WON game: %; expected null (no final board for spectators).', v_j;
  end if;
  v_checks := v_checks + 1;
  if v_txt is distinct from 'game_ended' then
    raise exception 'FAIL [E2] S1''s heartbeat after the win: %; expected game_ended.', v_txt;
  end if;
  v_checks := v_checks + 1;
  if v_msg is distinct from 'There is no game to watch at this table yet.' then
    raise exception 'FAIL [E3] watching X after the win: %; expected "There is no game to watch at this table yet."', coalesce(v_msg, 'allowed');
  end if;
  v_checks := v_checks + 1;

  -- [E4-E5] B leaves P through leave_table: P's game ends 'player_left'.
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.leave_table(v_p);
  execute 'reset role';
  if (select g.status || '/' || coalesce(g.ended_reason, '') from public.games g where g.id = v_gp) is distinct from 'ended/player_left' then
    raise exception 'SETUP [E4] P''s game did not end player_left after B left.';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_j := public.get_spectator_reveals(v_gp);
  v_txt := public.spectator_heartbeat(v_p);
  execute 'reset role';
  if v_j is not null then
    raise exception 'FAIL [E4] S1''s get_spectator_reveals for P''s ended game: %; expected null.', v_j;
  end if;
  v_checks := v_checks + 1;
  if v_txt is distinct from 'game_ended' then
    raise exception 'FAIL [E5] S1''s heartbeat at P after B left: %; expected game_ended.', v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [E6-E8] X ENDED, as an admin Force-End leaves it.
  update public.tables set status = 'ended', ended_reason = 'admin' where id = v_x;
  perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  v_txt := public.spectator_heartbeat(v_x);
  v_msg := null;
  begin
    perform 1 from public.watch_table(v_codes[1]);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  v_txt2 := null;
  execute 'set local role authenticated';
  begin
    perform public.remove_spectator(v_x, v_s1);
  exception when others then
    v_txt2 := sqlerrm;
  end;
  execute 'reset role';
  if v_txt is distinct from 'table_ended' then
    raise exception 'FAIL [E6] S1''s heartbeat at the ended table: %; expected table_ended.', v_txt;
  end if;
  v_checks := v_checks + 1;
  if v_msg is distinct from 'This table has ended.' then
    raise exception 'FAIL [E7] watching the ended table: %; expected "This table has ended."', coalesce(v_msg, 'allowed');
  end if;
  v_checks := v_checks + 1;
  if v_txt2 is distinct from 'This table has ended.' then
    raise exception 'FAIL [E8] the host removing a spectator at the ended table: %; expected "This table has ended."', coalesce(v_txt2, 'allowed');
  end if;
  v_checks := v_checks + 1;

  -- ---- Verdict ----------------------------------------------------------------
  -- 19 catalog + 3 creation (2 when T3 is skipped) + 9 watch refusals + 4 not
  -- signed in + 5 anon + 10 watching + 11 host remove + 5 stop + 4 game
  -- actions + 7 reads + 49 walk-through (16 states x 3, and the tally) + 8
  -- endings = 134 (133).
  -- The expected count goes into a variable first: PL/pgSQL ends an IF
  -- condition at the first THEN it meets, so a CASE ... THEN written inside
  -- the condition would cut it short (a syntax error before anything ran).
  v_expect := case when v_t3_skipped then 133 else 134 end;
  if v_checks <> v_expect then
    raise exception 'FAIL: % checks ran, expected %.', v_checks, v_expect;
  end if;

  raise exception 'ALL % CHECKS PASSED (rolled back).% Walk-through: % cut round(s), 2 discards, 8 plays, 4 counting states, done.',
    v_checks, v_skips, v_cut_states;
end;
$$;
