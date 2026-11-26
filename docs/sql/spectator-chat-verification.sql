-- Spectator chat, step 1: VERIFICATION of docs/sql/spectator-chat.sql.
--
-- Run in the Supabase Dashboard -> SQL Editor after
-- docs/sql/spectator-chat.sql. The whole file is ONE DO block.
--
-- STATUS: written, NOT RUN yet.
-- (S1's place at E made a crafted row on 2026-11-23 for step 3 slice A.)
--
-- It WRITES -- nine temporary accounts in auth.users, five tables, their
-- seats, live games, spectator rows (through the real watch_table and
-- remove_spectator, plus two crafted as the owner) and, if it can, a few test
-- rows in realtime.messages -- and then deliberately raises an exception at
-- the very end, which rolls EVERY write back. A check that fails raises its
-- own exception at once, which rolls everything back the same way. It always
-- "fails": the message is the verdict (the dashboard hides notices).
--   "ALL 74 CHECKS PASSED (rolled back). ..." is a pass, or "ALL 67 ..." with
--   a "skipped: ..." line when the live-policy checks can't run.
--   Anything starting "FAIL" or "SETUP" is not a pass.
-- Re-runnable, because nothing it does survives. It creates no functions,
-- tables or other schema objects.
--
-- Same impersonation as the other suites: request.jwt.claims plus "set
-- local role authenticated" (or anon) to act as a client, and "reset role"
-- to act as the owner between steps. Realtime's topic is set the way
-- Realtime sets it: set_config('realtime.topic', <topic>, true). "now()" is
-- frozen inside a DO block, so "stale" (not seen for 90 s) is made by moving
-- last_seen_at back 91 seconds as the owner, and the joined_at order by
-- setting joined_at as the owner.
--
-- AFTER THIS ONE: re-run the existing chat suite,
-- docs/sql/table-chat-verification.sql, unchanged. Expected verdict, as on
-- 2026-11-14: "ALL 68 CHECKS PASSED (rolled back). Other policies on
-- realtime.messages: 0." (or 61 with its "skipped P1-P7" line if
-- realtime.messages has no partition for today). None of its checks needs
-- updating: its people C and D have no table_spectators row, so every case
-- it expects false still is; C1 (boolean, definer, stable, search_path ''),
-- C3 (the policy text) and C4 (no other "chat" function, no write words in
-- the body) all still hold by design.
--
-- PEOPLE (temporary accounts, created here):
--   A, B  seated at X (A created it: the host). B also seated at Y and E.
--   C     seated at Y (created it).
--   S1    a CURRENT spectator of X (watch_table). Also a current spectator
--         of E (a crafted row made while E was open, then E ended: since
--         step 3 slice A a real watch_table of E would end S1's place at X),
--         and crafted rows at Z and K (impossible through the app; made as
--         the owner to prove the table checks).
--   S2    a CURRENT spectator of X, joined BEFORE S1 (joined_at set).
--   S3    a STALE spectator of X (last_seen_at moved back 91 s).
--   S4    a REMOVED spectator of X (A removes S4 through remove_spectator).
--   S5    a current spectator of Y only (ANOTHER table).
--   O     no relation to anything.
-- TABLES (from free 4-digit codes; each has a live game in the cut, so
-- watch_table lets spectators in under slice 1 or slice 2):
--   X  open, human, allows spectators: A, B.
--   Y  open, human, allows spectators: C, B.
--   Z  open, human, does NOT allow spectators: A (S1's crafted row).
--   E  allows spectators, A and B seated, then ENDED (admin).
--   K  a COMPUTER table (computer_level 'easy'): A (S1's crafted row).
-- Topics are written t:<table>:<sender>, e.g. X:S1.
--
-- WHAT IT CHECKS (74)
--   CATALOG (7)
--   C1  chat_topic_allows: boolean, security definer, stable, search_path ''.
--   C2  its EXECUTE: authenticated only (not anon, service_role or PUBLIC).
--   C3  its body reads table_spectators, the 90-second rule and
--       allow_spectators, and never mentions realtime.send or a write
--       command (the existing suite's C4 rule).
--   C4  the two realtime.messages policies are unchanged (each calls
--       chat_topic_allows(topic, false / true), broadcast only), and no
--       UNKNOWN policy is on realtime.messages (moderation M3's
--       "table kicks: people at the table receive" is known once
--       kick_topic_allows exists, and moderation M5a's "table events:
--       people at the table receive" once table_topic_allows exists; the
--       verdict names them).
--   C5  no other function in public has "chat" in its name.
--   C6  get_table_spectators: returns TABLE(user_id uuid, joined_at
--       timestamptz), security definer, stable, search_path ''.
--   C7  its EXECUTE: authenticated only.
--   CHAT RULES (W1-W44, chat_topic_allows as each person)
--     a current spectator: sends on their own topic yes; on a player's or
--     another spectator's topic NO; receives a player's, another
--     spectator's, their own and a silent topic yes. Players: unchanged,
--     and they hear spectators. Stale and removed spectators: NO for both.
--     A spectator row at a table that doesn't allow spectators, at an ended
--     table, at a computer table: NO. A spectator of ANOTHER table: NO at X,
--     yes at their own. Seated elsewhere, no relation, nobody signed in,
--     malformed topics: NO.
--   SPECTATOR LIST (G1-G14, get_table_spectators as each person)
--     A, B (seated) and S1, S2 (current spectators) get [S2, S1] in joined_at
--     order -- S3 (stale) and S4 (removed) left out; S3, S4, S5 (watching
--     another table), C (seated elsewhere), O and nobody signed in get zero
--     rows at X; S5 and C get [S5] at Y; a null table gives zero rows; none
--     raises. G14: the joined_at values come back as set.
--   ANON (A1, A2): anon can't call either function (42501).
--   LIVE POLICIES (L1-L7, or skipped)
--   L1  S1 sends on X:S1: allowed.        L2  A receives X:S1: sees it.
--   L3  S2 receives X:S1: sees it.        L4  S3 (stale) receives: nothing.
--   L5  S4 (removed) sends on X:S4: 42501.
--   L6  O receives X:S1: nothing.         L7  S1 sends on X:A: 42501.

do $$
declare
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid();
  v_s1 uuid := gen_random_uuid();
  v_s2 uuid := gen_random_uuid();
  v_s3 uuid := gen_random_uuid();
  v_s4 uuid := gen_random_uuid();
  v_s5 uuid := gen_random_uuid();
  v_o uuid := gen_random_uuid();
  v_codes text[];
  v_x uuid;
  v_y uuid;
  v_z uuid;
  v_e uuid;
  v_k uuid;
  v_fn constant text := 'public.chat_topic_allows(text, boolean)';
  v_gs constant text := 'public.get_table_spectators(uuid)';
  v_x_a text;
  v_x_b text;
  v_x_s1 text;
  v_x_s2 text;
  v_x_s3 text;
  v_x_s4 text;
  v_x_s5 text;
  v_x_o text;
  v_rec record;
  v_got boolean;
  v_ids uuid[];
  v_txt text;
  v_msg text;
  v_state text;
  v_n int;
  v_live text;   -- null: the live policy checks can run; else why not
  v_checks int := 0;
  v_skips text := '';
  v_others int;
  v_expect int;
begin
  -- ==== CATALOG ===============================================================
  if to_regprocedure(v_fn) is null then
    raise exception 'SETUP: % does not exist. Run docs/sql/table-chat.sql first.', v_fn;
  end if;
  if to_regprocedure(v_gs) is null then
    raise exception 'SETUP: % does not exist. Run docs/sql/spectator-chat.sql first.', v_gs;
  end if;
  if to_regclass('public.table_spectators') is null or coalesce(to_regprocedure('public.watch_table(text, uuid)'), to_regprocedure('public.watch_table(text)')) is null then
    raise exception 'SETUP: the spectator tables and functions do not exist. Run docs/sql/spectators.sql first.';
  end if;

  -- [C1] chat_topic_allows' shape, unchanged.
  select p.prorettype::regtype::text
         || case when p.prosecdef then ' definer ' else ' invoker ' end
         || p.provolatile::text
         || case when coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']
                 then ' empty-path' else ' path:' || coalesce(p.proconfig::text, 'none') end
  into v_txt
  from pg_proc p where p.oid = to_regprocedure(v_fn);
  if v_txt is distinct from 'boolean definer s empty-path' then
    raise exception 'FAIL [C1] % is "%", expected "boolean definer s empty-path".', v_fn, v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [C2] and [C7] EXECUTE: authenticated only.
  for v_rec in select * from (values ('C2', v_fn), ('C7', v_gs)) as t(label, fn) loop
    select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = to_regprocedure(v_rec.fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE';
    if not has_function_privilege('authenticated', v_rec.fn, 'execute')
       or has_function_privilege('anon', v_rec.fn, 'execute')
       or v_n <> 0
       or (exists (select 1 from pg_roles where rolname = 'service_role')
           and has_function_privilege('service_role', v_rec.fn, 'execute')) then
      raise exception 'FAIL [%] execute on %: authenticated %, anon %, PUBLIC grants %; expected true, false, 0 (and no service_role).',
        v_rec.label, v_rec.fn,
        has_function_privilege('authenticated', v_rec.fn, 'execute'),
        has_function_privilege('anon', v_rec.fn, 'execute'), v_n;
    end if;
    v_checks := v_checks + 1;
  end loop;

  -- [C3] The body: the spectator rule is there, and nothing writes.
  select p.prosrc into v_txt from pg_proc p where p.oid = to_regprocedure(v_fn);
  if v_txt not ilike '%public.table_spectators%'
     or v_txt not ilike '%interval ''90 seconds''%'
     or v_txt not ilike '%allow_spectators%'
     or v_txt not ilike '%removed_at is null%' then
    raise exception 'FAIL [C3] chat_topic_allows'' body has no current-spectator rule (table_spectators, removed_at, 90 seconds, allow_spectators). Run docs/sql/spectator-chat.sql.';
  end if;
  if v_txt ilike '%realtime.send%' or v_txt ~* '\m(insert|update|delete)\M' then
    raise exception 'FAIL [C3] chat_topic_allows'' body mentions realtime.send or a write command (comments count): the existing chat suite''s C4 would fail.';
  end if;
  v_checks := v_checks + 1;

  -- [C4] The two policies, as the existing suite's C3 matches them.
  select count(*) into v_n
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
    and ((p.policyname = 'table chat: members receive' and p.cmd = 'SELECT'
          and p.qual ilike '%extension = ''broadcast''%'
          and p.qual ilike '%chat_topic_allows(%realtime.topic()%false)%'
          and p.with_check is null)
      or (p.policyname = 'table chat: members send' and p.cmd = 'INSERT'
          and p.with_check ilike '%extension = ''broadcast''%'
          and p.with_check ilike '%chat_topic_allows(%realtime.topic()%true)%'
          and p.qual is null))
    and p.permissive = 'PERMISSIVE'
    and p.roles = array['authenticated']::name[];
  if v_n <> 2 then
    raise exception 'FAIL [C4] found % of the two table-chat policies as table-chat.sql wrote them; expected 2.', v_n;
  end if;
  -- UNKNOWN policies: anything but the two table-chat ones -- and, once
  -- moderation M3 part 1 is in (kick_topic_allows exists), its one SELECT
  -- policy for kicks: topics, and once moderation M5a part 1 is in
  -- (table_topic_allows exists), its one SELECT policy for table: topics;
  -- neither can match a chat topic. Policies are OR'ed, so an unknown one
  -- fails here.
  select count(*) into v_others
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
    and p.policyname not in ('table chat: members receive', 'table chat: members send')
    and not (p.policyname = 'table kicks: people at the table receive'
             and p.cmd = 'SELECT'
             and to_regprocedure('public.kick_topic_allows(text)') is not null)
    and not (p.policyname = 'table events: people at the table receive'
             and p.cmd = 'SELECT'
             and to_regprocedure('public.table_topic_allows(text)') is not null);
  if v_others <> 0 then
    raise exception 'FAIL [%] % unknown polic(ies) on realtime.messages: %.', 'C4', v_others,
      (select string_agg(p.policyname::text, ', ' order by p.policyname)
       from pg_policies p
       where p.schemaname = 'realtime' and p.tablename = 'messages'
         and p.policyname not in ('table chat: members receive', 'table chat: members send', 'table kicks: people at the table receive',
                                  'table events: people at the table receive'));
  end if;
  v_checks := v_checks + 1;

  -- [C5] No other "chat" function in public.
  select string_agg(p.proname::text, ', ') into v_txt
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows';
  if v_txt is not null then
    raise exception 'FAIL [C5] other chat function(s) in public: %; the existing chat suite''s C4 would fail.', v_txt;
  end if;
  v_checks := v_checks + 1;

  -- [C6] get_table_spectators' shape.
  select pg_get_function_result(p.oid)
         || case when p.prosecdef then ' definer ' else ' invoker ' end
         || p.provolatile::text
         || case when coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']
                 then ' empty-path' else ' path:' || coalesce(p.proconfig::text, 'none') end
  into v_txt
  from pg_proc p where p.oid = to_regprocedure(v_gs);
  if v_txt is distinct from 'TABLE(user_id uuid, joined_at timestamp with time zone) definer s empty-path' then
    raise exception 'FAIL [C6] % is "%", expected "TABLE(user_id uuid, joined_at timestamp with time zone) definer s empty-path".', v_gs, v_txt;
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner ====================================================
  begin
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
      (v_a,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'sc-a-'  || v_a::text  || '@verification.invalid', now() - interval '9 minutes', now()),
      (v_b,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'sc-b-'  || v_b::text  || '@verification.invalid', now() - interval '8 minutes', now()),
      (v_c,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'sc-c-'  || v_c::text  || '@verification.invalid', now() - interval '7 minutes', now()),
      (v_s1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'sc-s1-' || v_s1::text || '@verification.invalid', now() - interval '6 minutes', now()),
      (v_s2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'sc-s2-' || v_s2::text || '@verification.invalid', now() - interval '5 minutes', now()),
      (v_s3, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'sc-s3-' || v_s3::text || '@verification.invalid', now() - interval '4 minutes', now()),
      (v_s4, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'sc-s4-' || v_s4::text || '@verification.invalid', now() - interval '3 minutes', now()),
      (v_s5, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'sc-s5-' || v_s5::text || '@verification.invalid', now() - interval '2 minutes', now()),
      (v_o,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'sc-o-'  || v_o::text  || '@verification.invalid', now() - interval '1 minute', now());
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts in auth.users: % (%).', sqlerrm, sqlstate;
  end;

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    -- Codes no OPEN table holds -- every table while the old unique key
    -- exists (before step 3 slice B part 2 frees ended tables' codes).
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0')
                        and (t.status <> 'ended' or to_regclass('public.tables_code_open_key') is null))
    order by n
    limit 5
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 5 then
    raise exception 'SETUP: fewer than five unused table codes.';
  end if;

  begin
    -- Members one at a time, so the seat trigger seats them in order.
    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[1], v_a, true, true) returning id into v_x;
    insert into public.table_members (table_id, user_id) values (v_x, v_a);
    insert into public.table_members (table_id, user_id) values (v_x, v_b);

    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[2], v_c, true, true) returning id into v_y;
    insert into public.table_members (table_id, user_id) values (v_y, v_c);
    insert into public.table_members (table_id, user_id) values (v_y, v_b);

    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[3], v_a, true, false) returning id into v_z;
    insert into public.table_members (table_id, user_id) values (v_z, v_a);

    insert into public.tables (code, created_by, is_public, allow_spectators) values (v_codes[4], v_a, true, true) returning id into v_e;
    insert into public.table_members (table_id, user_id) values (v_e, v_a);
    insert into public.table_members (table_id, user_id) values (v_e, v_b);

    insert into public.tables (code, created_by, computer_level) values (v_codes[5], v_a, 'easy') returning id into v_k;
    insert into public.table_members (table_id, user_id) values (v_k, v_a);

    -- A game in the cut at X, Y and E (dated an hour back, as the other
    -- suites do), so slice 1's watch_table lets spectators in too.
    insert into public.games (table_id, created_by, status, players, deal_cut, created_at) values
      (v_x, v_a, 'cutting', array[v_a, v_b], '[[]]'::jsonb, now() - interval '1 hour'),
      (v_y, v_c, 'cutting', array[v_c, v_b], '[[]]'::jsonb, now() - interval '1 hour'),
      (v_e, v_a, 'cutting', array[v_a, v_b], '[[]]'::jsonb, now() - interval '1 hour');
  exception when others then
    raise exception 'SETUP: could not create the test tables, seats and games: % (%).', sqlerrm, sqlstate;
  end;

  -- The spectators, through the REAL watch_table, as themselves.
  for v_rec in
    select * from (values
      ('S1 at X', v_s1, v_codes[1]),
      ('S2 at X', v_s2, v_codes[1]),
      ('S3 at X', v_s3, v_codes[1]),
      ('S4 at X', v_s4, v_codes[1]),
      ('S5 at Y', v_s5, v_codes[2])
    ) as t(label, who, code)
  loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_rec.who, 'role', 'authenticated')::text, true);
    v_msg := null;
    execute 'set local role authenticated';
    begin
      perform 1 from public.watch_table(v_rec.code);
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_msg is not null then
      raise exception 'SETUP: watch_table for % was refused: %.', v_rec.label, v_msg;
    end if;
  end loop;

  -- A (the host of X: its creator, seated) removes S4, through the real function.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  v_msg := null;
  execute 'set local role authenticated';
  begin
    perform public.remove_spectator(v_x, v_s4);
  exception when others then
    v_msg := sqlerrm;
  end;
  execute 'reset role';
  if v_msg is not null then
    raise exception 'SETUP: A removing S4 at X was refused: %.', v_msg;
  end if;

  begin
    -- The joined_at order: S2 first, then S1.
    update public.table_spectators set joined_at = now() - interval '120 seconds' where table_id = v_x and user_id = v_s2;
    update public.table_spectators set joined_at = now() - interval '60 seconds' where table_id = v_x and user_id = v_s1;
    -- S3 goes stale.
    update public.table_spectators set last_seen_at = now() - interval '91 seconds' where table_id = v_x and user_id = v_s3;
    -- Crafted rows (the app can't make these): S1 "watching" Z (does not
    -- allow spectators) and K (a computer table), current -- and E too,
    -- crafted since step 3 slice A (docs/sql/join-create.sql): a real
    -- watch_table of E would END S1's place at X (one table at a time).
    insert into public.table_spectators (table_id, user_id, joined_at, last_seen_at) values
      (v_z, v_s1, now(), now()),
      (v_k, v_s1, now(), now()),
      (v_e, v_s1, now(), now());
    -- E ends (an admin Force-End), with S1 still a current spectator there.
    update public.tables set status = 'ended', ended_reason = 'admin' where id = v_e;
  exception when others then
    raise exception 'SETUP: could not age, order or craft the spectator rows: % (%).', sqlerrm, sqlstate;
  end;

  if (select count(*) from public.table_spectators ts
      where ts.table_id = v_x and ts.removed_at is null and ts.last_seen_at > now() - interval '90 seconds') <> 2
     or (select ts.removed_at from public.table_spectators ts where ts.table_id = v_x and ts.user_id = v_s4) is null then
    raise exception 'SETUP: X should have exactly 2 current spectators (S1, S2) and S4 removed.';
  end if;

  v_x_a  := 'chat:' || v_x::text || ':' || v_a::text;
  v_x_b  := 'chat:' || v_x::text || ':' || v_b::text;
  v_x_s1 := 'chat:' || v_x::text || ':' || v_s1::text;
  v_x_s2 := 'chat:' || v_x::text || ':' || v_s2::text;
  v_x_s3 := 'chat:' || v_x::text || ':' || v_s3::text;
  v_x_s4 := 'chat:' || v_x::text || ':' || v_s4::text;
  v_x_s5 := 'chat:' || v_x::text || ':' || v_s5::text;
  v_x_o  := 'chat:' || v_x::text || ':' || v_o::text;

  -- ==== CHAT RULES (chat_topic_allows, as each person) =========================
  for v_rec in
    select *
    from (values
      -- label, actor (null = nobody signed in), topic, send, expected
      ('W1 S1 sends on X:S1 (own)', v_s1, v_x_s1, true, true),
      ('W2 S1 sends on X:A (a player''s)', v_s1, v_x_a, true, false),
      ('W3 S1 sends on X:S2 (another spectator''s)', v_s1, v_x_s2, true, false),
      ('W4 S1 receives X:A', v_s1, v_x_a, false, true),
      ('W5 S1 receives X:B', v_s1, v_x_b, false, true),
      ('W6 S1 receives X:S2', v_s1, v_x_s2, false, true),
      ('W7 S1 receives X:S1 (own)', v_s1, v_x_s1, false, true),
      ('W8 S1 receives X:O (a silent channel)', v_s1, v_x_o, false, true),
      ('W9 S2 sends on X:S2', v_s2, v_x_s2, true, true),
      ('W10 S2 receives X:S1', v_s2, v_x_s1, false, true),
      ('W11 A (seated) sends on X:A', v_a, v_x_a, true, true),
      ('W12 A receives X:S1 (hears a spectator)', v_a, v_x_s1, false, true),
      ('W13 B receives X:S2', v_b, v_x_s2, false, true),
      ('W14 A sends on X:S1 (a spectator''s)', v_a, v_x_s1, true, false),
      ('W15 B sends on X:B', v_b, v_x_b, true, true),
      ('W16 S3 (stale) sends on X:S3', v_s3, v_x_s3, true, false),
      ('W17 S3 (stale) receives X:A', v_s3, v_x_a, false, false),
      ('W18 S3 (stale) receives X:S1', v_s3, v_x_s1, false, false),
      ('W19 S4 (removed) sends on X:S4', v_s4, v_x_s4, true, false),
      ('W20 S4 (removed) receives X:A', v_s4, v_x_a, false, false),
      ('W21 S4 (removed) receives X:S1', v_s4, v_x_s1, false, false),
      ('W22 S1 at Z (no spectators allowed) sends on Z:S1', v_s1, 'chat:' || v_z::text || ':' || v_s1::text, true, false),
      ('W23 S1 at Z receives Z:A', v_s1, 'chat:' || v_z::text || ':' || v_a::text, false, false),
      ('W24 S1 at E (ended) sends on E:S1', v_s1, 'chat:' || v_e::text || ':' || v_s1::text, true, false),
      ('W25 S1 at E receives E:A', v_s1, 'chat:' || v_e::text || ':' || v_a::text, false, false),
      ('W26 A (seated) at E sends on E:A (unchanged: ended)', v_a, 'chat:' || v_e::text || ':' || v_a::text, true, false),
      ('W27 S1 at K (computer table) sends on K:S1', v_s1, 'chat:' || v_k::text || ':' || v_s1::text, true, false),
      ('W28 S1 at K receives K:A', v_s1, 'chat:' || v_k::text || ':' || v_a::text, false, false),
      ('W29 S5 (watching Y) receives X:A', v_s5, v_x_a, false, false),
      ('W30 S5 sends on X:S5', v_s5, v_x_s5, true, false),
      ('W31 S5 receives X:S1', v_s5, v_x_s1, false, false),
      ('W32 S5 sends on Y:S5 (own table)', v_s5, 'chat:' || v_y::text || ':' || v_s5::text, true, true),
      ('W33 S5 receives Y:C', v_s5, 'chat:' || v_y::text || ':' || v_c::text, false, true),
      ('W34 C (seated at Y) receives X:A', v_c, v_x_a, false, false),
      ('W35 C receives X:S1', v_c, v_x_s1, false, false),
      ('W36 C receives Y:S5 (hears Y''s spectator)', v_c, 'chat:' || v_y::text || ':' || v_s5::text, false, true),
      ('W37 O (no relation) receives X:A', v_o, v_x_a, false, false),
      ('W38 O sends on X:O', v_o, v_x_o, true, false),
      ('W39 O receives X:S1', v_o, v_x_s1, false, false),
      ('W40 nobody signed in receives X:S1', null::uuid, v_x_s1, false, false),
      ('W41 nobody signed in sends on X:S1', null, v_x_s1, true, false),
      ('W42 S1 malformed: uppercase own id (send)', v_s1, 'chat:' || v_x::text || ':' || upper(v_s1::text), true, false),
      ('W43 S1 malformed: trailing space (receive)', v_s1, v_x_a || ' ', false, false),
      ('W44 S1 malformed: null send flag', v_s1, v_x_s1, null::boolean, false)
    ) as t(label, actor, topic, send, want)
  loop
    if v_rec.actor is null then
      perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
    else
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.actor, 'role', 'authenticated')::text, true);
    end if;
    v_got := null;
    v_msg := null;
    execute 'set local role authenticated';
    begin
      v_got := public.chat_topic_allows(v_rec.topic, v_rec.send);
    exception when others then
      v_msg := sqlstate || ' ' || sqlerrm;
    end;
    execute 'reset role';
    if v_msg is not null then
      raise exception 'FAIL [%] raised an error: %; expected %, never an error.', v_rec.label, v_msg, v_rec.want;
    end if;
    if v_got is distinct from v_rec.want then
      raise exception 'FAIL [%] gave %, expected %.', v_rec.label, coalesce(v_got::text, 'null'), v_rec.want;
    end if;
    v_checks := v_checks + 1;
  end loop;

  -- ==== SPECTATOR LIST (get_table_spectators, as each person) ==================
  for v_rec in
    select *
    from (values
      -- label, actor (null = nobody signed in), table, expected ids in order
      ('G1 A (seated) at X', v_a, v_x, array[v_s2, v_s1]),
      ('G2 B (seated) at X', v_b, v_x, array[v_s2, v_s1]),
      ('G3 S1 (current spectator) at X', v_s1, v_x, array[v_s2, v_s1]),
      ('G4 S2 (current spectator) at X', v_s2, v_x, array[v_s2, v_s1]),
      ('G5 S3 (stale) at X', v_s3, v_x, array[]::uuid[]),
      ('G6 S4 (removed) at X', v_s4, v_x, array[]::uuid[]),
      ('G7 S5 (watching Y) at X', v_s5, v_x, array[]::uuid[]),
      ('G8 S5 at Y', v_s5, v_y, array[v_s5]),
      ('G9 C (seated) at Y', v_c, v_y, array[v_s5]),
      ('G10 C (seated at Y) at X', v_c, v_x, array[]::uuid[]),
      ('G11 O (no relation) at X', v_o, v_x, array[]::uuid[]),
      ('G12 nobody signed in at X', null::uuid, v_x, array[]::uuid[]),
      ('G13 A with a null table', v_a, null::uuid, array[]::uuid[])
    ) as t(label, actor, tbl, want)
  loop
    if v_rec.actor is null then
      perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
    else
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.actor, 'role', 'authenticated')::text, true);
    end if;
    v_ids := null;
    v_msg := null;
    execute 'set local role authenticated';
    begin
      select coalesce(array_agg(g.user_id order by g.ord), array[]::uuid[])
      into v_ids
      from public.get_table_spectators(v_rec.tbl) with ordinality as g(user_id, joined_at, ord);
    exception when others then
      v_msg := sqlstate || ' ' || sqlerrm;
    end;
    execute 'reset role';
    if v_msg is not null then
      raise exception 'FAIL [%] raised an error: %; expected rows, never an error.', v_rec.label, v_msg;
    end if;
    if v_ids is distinct from v_rec.want then
      raise exception 'FAIL [%] gave %, expected % (S1 %, S2 %, S5 %).', v_rec.label, v_ids, v_rec.want, v_s1, v_s2, v_s5;
    end if;
    v_checks := v_checks + 1;
  end loop;

  -- [G14] The joined_at values come back as set (A asking at X).
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n
  from public.get_table_spectators(v_x) g
  where (g.user_id = v_s2 and g.joined_at = now() - interval '120 seconds')
     or (g.user_id = v_s1 and g.joined_at = now() - interval '60 seconds');
  execute 'reset role';
  if v_n <> 2 then
    raise exception 'FAIL [G14] % of S1''s and S2''s joined_at came back as set; expected 2.', v_n;
  end if;
  v_checks := v_checks + 1;

  -- ==== ANON ====================================================================
  -- [A1] anon can't call get_table_spectators.
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  v_state := null;
  execute 'set local role anon';
  begin
    perform 1 from public.get_table_spectators(v_x);
  exception when others then
    v_state := sqlstate;
  end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [A1] anon calling get_table_spectators: %; expected 42501 (permission denied).', coalesce(v_state, 'it ran');
  end if;
  v_checks := v_checks + 1;

  -- [A2] anon can't call chat_topic_allows.
  v_state := null;
  execute 'set local role anon';
  begin
    perform public.chat_topic_allows(v_x_a, false);
  exception when others then
    v_state := sqlstate;
  end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [A2] anon calling chat_topic_allows: %; expected 42501 (permission denied).', coalesce(v_state, 'it ran');
  end if;
  v_checks := v_checks + 1;

  -- ==== LIVE POLICIES ==========================================================
  -- Exactly what Realtime does for a private channel: as the person, with
  -- realtime.topic set, an insert (may send?) and a select (may receive?).
  if not has_table_privilege('authenticated', 'realtime.messages', 'INSERT')
     or not has_table_privilege('authenticated', 'realtime.messages', 'SELECT') then
    v_live := 'authenticated lacks SELECT or INSERT on realtime.messages (see the precheck)';
  end if;

  -- [L1] S1 sends on X:S1.
  if v_live is null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_s1, 'role', 'authenticated')::text, true);
    perform set_config('realtime.topic', v_x_s1, true);
    v_state := null;
    execute 'set local role authenticated';
    begin
      insert into realtime.messages (topic, extension, event, payload, private)
      values (v_x_s1, 'broadcast', 'spectator-chat-verification', jsonb_build_object('text', 'hello from the rail'), true);
    exception when others then
      v_state := sqlstate;
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_state = '42501' then
      raise exception 'FAIL [L1] S1 (a current spectator) sending on S1''s own topic at X was refused: %.', v_msg;
    elsif v_state is not null then
      -- Not a policy answer: the row couldn't be written at all (usually no
      -- daily partition for today).
      v_live := 'a test insert into realtime.messages failed with ' || v_state || ' ' || v_msg;
    else
      v_checks := v_checks + 1;
    end if;
  end if;

  if v_live is null then
    -- [L2] [L3] [L4] [L6] Who receives X:S1.
    for v_rec in
      select * from (values
        ('L2 A (seated) receives X:S1', v_a, 1),
        ('L3 S2 (current spectator) receives X:S1', v_s2, 1),
        ('L4 S3 (stale) receives X:S1', v_s3, 0),
        ('L6 O (no relation) receives X:S1', v_o, 0)
      ) as t(label, who, want)
    loop
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.who, 'role', 'authenticated')::text, true);
      perform set_config('realtime.topic', v_x_s1, true);
      execute 'set local role authenticated';
      select count(*) into v_n from realtime.messages m
      where m.topic = v_x_s1 and m.event = 'spectator-chat-verification';
      execute 'reset role';
      if v_n <> v_rec.want then
        raise exception 'FAIL [%] saw % test message(s); expected %. (% other policies on realtime.messages.)', v_rec.label, v_n, v_rec.want, v_others;
      end if;
      v_checks := v_checks + 1;
    end loop;

    -- [L5] S4 (removed) sends on X:S4; [L7] S1 sends on X:A. Both refused.
    for v_rec in
      select * from (values
        ('L5 S4 (removed) sends on X:S4', v_s4, v_x_s4),
        ('L7 S1 sends on X:A (a player''s topic)', v_s1, v_x_a)
      ) as t(label, who, topic)
    loop
      perform set_config('request.jwt.claims', json_build_object('sub', v_rec.who, 'role', 'authenticated')::text, true);
      perform set_config('realtime.topic', v_rec.topic, true);
      v_state := null;
      execute 'set local role authenticated';
      begin
        insert into realtime.messages (topic, extension, event, payload, private)
        values (v_rec.topic, 'broadcast', 'spectator-chat-verification', '{}'::jsonb, true);
      exception when others then
        v_state := sqlstate;
      end;
      execute 'reset role';
      if v_state is distinct from '42501' then
        raise exception 'FAIL [%]: %; expected 42501.', v_rec.label, coalesce(v_state, 'allowed');
      end if;
      v_checks := v_checks + 1;
    end loop;
  else
    v_skips := v_skips || ' skipped L1-L7 (live policies): ' || v_live || '; the rules are proven by W, G and C4 only.';
  end if;

  -- ---- Verdict ----------------------------------------------------------------
  -- 7 catalog + 44 chat rules + 14 spectator list + 2 anon + 7 live (0 when
  -- skipped). The expected count goes into a variable first (a CASE inside
  -- an IF condition is a syntax trap in PL/pgSQL).
  v_expect := case when v_live is null then 74 else 67 end;
  if v_checks <> v_expect then
    raise exception 'FAIL: % checks ran, expected %.', v_checks, v_expect;
  end if;

  raise exception 'ALL % CHECKS PASSED (rolled back).% Other policies on realtime.messages: %.',
    v_checks, v_skips, v_others::text
    || (case when exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages'
                         and p.policyname = 'table kicks: people at the table receive')
          then ' (plus moderation M3''s kicks policy)' else '' end)
    || (case when exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages'
                         and p.policyname = 'table events: people at the table receive')
          then ' (plus moderation M5a''s table events policy)' else '' end);
end;
$$;
