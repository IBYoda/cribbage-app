-- Table chat, slice 1: VERIFICATION of docs/sql/table-chat.sql.
--
-- Run in the Supabase Dashboard -> SQL Editor after docs/sql/table-chat.sql.
-- The whole file is ONE DO block.
--
-- STATUS: RUN in production on 2026-11-14: "ALL 68 CHECKS PASSED (rolled
-- back). Other policies on realtime.messages: 0." All 7 live policy checks
-- ran (none skipped). The first run had failed with a syntax error at the
-- verdict line (a CASE ... THEN inside an IF condition); fixed by computing
-- the expected count into v_expect first.
--
-- RUN ORDER (as run on 2026-11-14):
--   1. docs/sql/table-chat-precheck.sql      (read-only)
--   2. docs/sql/table-chat.sql
--   3. docs/sql/table-chat-verification.sql  (this file)
--
-- It WRITES -- five temporary accounts in auth.users, five tables, their
-- seats, one game, and (if it can) a few test rows in realtime.messages --
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
-- to act as the owner between steps. Realtime's topic is set the way
-- Realtime sets it: set_config('realtime.topic', <topic>, true).
--
-- HOW THE POLICIES ARE TESTED
--   The rules all live in public.chat_topic_allows, so the walk-through (W)
--   calls it directly, as a signed-in player, for every case. The policies
--   are then checked two ways:
--     C3  in pg_policies: both exist, for authenticated, with the right
--         command, broadcast only, and each calling chat_topic_allows with
--         the right "send" flag.
--     P   LIVE, the way Realtime itself asks: as a player, with
--         realtime.topic set, an INSERT into realtime.messages (= may send)
--         and a SELECT from it (= may receive). realtime.messages is split
--         into daily partitions that Realtime creates; if there is none for
--         today, or the client roles lack SELECT / INSERT on it, the insert
--         can't run inside this block. Then P1-P7 say "skipped: ..." (with
--         the reason) and the proof rests on W and C3.
--
-- PEOPLE (temporary accounts, created here):
--   A, B  seated at table X (A also at L).
--   C     seated at table Y only.
--   D     seated at table L, then leaves it (through public.leave_table).
-- TABLES (A creates them, from free 4-digit codes):
--   X  open, human, 2 players (A, B): the walk-through table. It goes
--      through the waiting room (no game), the cut, mid-game and game over.
--   Y  open, human (C).
--   K  a COMPUTER table (computer_level 'easy'), A and B seated directly.
--   E  an ENDED table (status 'ended', admin), A and B still seated, the way
--      a Force-End leaves it.
--   L  open, human (A, D): D leaves it.
-- Topics are written t:<table>:<sender>, e.g. X:A = chat:<X's id>:<A's id>.
--
-- WHAT IT CHECKS
--   CATALOG
--   C1  chat_topic_allows(text, boolean) returns boolean, is security
--       definer, stable, and has search_path set to ''.
--   C2  grants: authenticated can execute it; anon, service_role and PUBLIC
--       can't.
--   C3  the two policies on realtime.messages, as above. (Any OTHER policies
--       on realtime.messages are counted in the verdict, for the record.)
--   C4  nothing stored: no relation with "chat" in its name in any
--       non-system schema, no storage bucket (or object in one) with "chat"
--       in its name, no other "chat" function in public, and
--       chat_topic_allows' body has no realtime.send and no insert, update or
--       delete.
--   C5  row-level security is still on for realtime.messages.
--   WALK-THROUGH (chat_topic_allows, as a signed-in player; R = receive,
--   S = send)
--   W1  waiting room at X (no game): A R/S on X:A yes; A R on X:B yes; A S
--       on X:B NO; B S on X:B and R on X:A yes.
--       C (not seated at X): R X:A, S X:C, R X:C all NO.
--       A on table Y's topics: R Y:C, S Y:A NO; C on Y:C S yes.
--       computer table K: A R/S on K:A NO. Ended table E: A R/S on E:A NO.
--       D before leaving L: R/S on L:D yes.
--       a table id that doesn't exist: NO. Nobody signed in: R/S NO.
--       MALFORMED topics (A, who is seated at X, so only the shape is
--       wrong): empty, null topic, null send flag, an uppercase sender, an
--       uppercase table id, "Chat:", a trailing space, a trailing newline, a
--       leading space, "xchat:", ":extra" on the end, one hex digit too
--       many, one id only, "not-a-uuid", no hyphens, a "g" in an id, braces,
--       "room:", no sender: each NO, and none raises an error.
--   W2  X with a game in the CUT ('cutting'): A R/S on X:A, B R on X:A yes.
--   W3  X MID-GAME ('active', discard): the same, yes.
--   W4  X at GAME OVER ('ended', won -- the game-over board; the table is
--       still open): the same, yes.
--   W5  after D LEAVES L: D R/S on L:D NO, D R on L:A NO; A S on L:A yes;
--       A R on L:D yes (rule 5: listening to a channel nobody can send on
--       any more is harmless).
--   A1  anon can't call chat_topic_allows at all (42501).
--   LIVE POLICIES (or skipped, see above)
--   P1  A sends on X:A: the insert is allowed.
--   P2  B sends on X:A: refused (42501).
--   P3  B receives X:A: B's select sees A's test message.
--   P4  C (not seated at X) receives X:A: sees nothing.
--   P5  C sends on X:C: refused (42501).
--   P6  anon on X:A: the insert is refused, the select sees nothing.
--   P7  A sends a 'presence' message on X:A: refused (the policies are
--       broadcast only).

do $$
declare
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_c uuid := gen_random_uuid();
  v_d uuid := gen_random_uuid();
  v_e uuid := gen_random_uuid();  -- a random id: used as a table that doesn't exist
  v_codes text[];
  v_x uuid;
  v_y uuid;
  v_k uuid;
  v_ended uuid;
  v_l uuid;
  v_g uuid;
  v_xa text;
  v_xb text;
  v_fn constant text := 'public.chat_topic_allows(text, boolean)';
  v_rec record;
  v_phase int;
  v_got boolean;
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
  if to_regclass('realtime.messages') is null then
    raise exception 'SETUP: realtime.messages does not exist (Realtime Authorization is not set up).';
  end if;

  -- [C1] Return type, security definer, volatility, search_path.
  -- (provolatile is type "char": cast it with ::text before joining it to
  -- text, or Postgres can't pick the || operator.)
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

  -- [C2] Grants.
  select count(*) into v_n
  from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where p.oid = to_regprocedure(v_fn) and a.grantee = 0 and a.privilege_type = 'EXECUTE';
  if not has_function_privilege('authenticated', v_fn, 'execute')
     or has_function_privilege('anon', v_fn, 'execute')
     or v_n <> 0
     or (exists (select 1 from pg_roles where rolname = 'service_role')
         and has_function_privilege('service_role', v_fn, 'execute')) then
    raise exception 'FAIL [C2] execute: authenticated %, anon %, PUBLIC grants %, service_role %; expected true, false, 0, false.',
      has_function_privilege('authenticated', v_fn, 'execute'),
      has_function_privilege('anon', v_fn, 'execute'), v_n,
      (exists (select 1 from pg_roles where rolname = 'service_role')
       and has_function_privilege('service_role', v_fn, 'execute'));
  end if;
  v_checks := v_checks + 1;

  -- [C3] The two policies. pg_policies shows each rule as Postgres reprints
  -- it, e.g. ((extension = 'broadcast'::text) AND ( SELECT
  -- chat_topic_allows(( SELECT realtime.topic() ...), false) ...)).
  select count(*) into v_n
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
    and p.policyname = 'table chat: members receive'
    and p.cmd = 'SELECT'
    and p.permissive = 'PERMISSIVE'
    and p.roles = array['authenticated']::name[]
    and p.qual ilike '%extension = ''broadcast''%'
    and p.qual ilike '%chat_topic_allows(%realtime.topic()%false)%'
    and p.with_check is null;
  if v_n <> 1 then
    raise exception 'FAIL [C3] policy "table chat: members receive" (SELECT, to authenticated, broadcast, chat_topic_allows(topic, false)) found % time(s); expected 1. pg_policies says: %.',
      v_n, coalesce((select p.cmd::text || ' to ' || p.roles::text || ' using ' || coalesce(p.qual, '-')
                     from pg_policies p
                     where p.schemaname = 'realtime' and p.tablename = 'messages'
                       and p.policyname = 'table chat: members receive'), 'missing');
  end if;
  select count(*) into v_n
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
    and p.policyname = 'table chat: members send'
    and p.cmd = 'INSERT'
    and p.permissive = 'PERMISSIVE'
    and p.roles = array['authenticated']::name[]
    and p.with_check ilike '%extension = ''broadcast''%'
    and p.with_check ilike '%chat_topic_allows(%realtime.topic()%true)%'
    and p.qual is null;
  if v_n <> 1 then
    raise exception 'FAIL [C3] policy "table chat: members send" (INSERT, to authenticated, broadcast, chat_topic_allows(topic, true)) found % time(s); expected 1. pg_policies says: %.',
      v_n, coalesce((select p.cmd::text || ' to ' || p.roles::text || ' with check ' || coalesce(p.with_check, '-')
                     from pg_policies p
                     where p.schemaname = 'realtime' and p.tablename = 'messages'
                       and p.policyname = 'table chat: members send'), 'missing');
  end if;
  select count(*) into v_others
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
    and p.policyname not in ('table chat: members receive', 'table chat: members send');
  v_checks := v_checks + 1;

  -- [C4] Nothing stored.
  select string_agg(n.nspname::text || '.' || c.relname::text, ', ') into v_txt
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where c.relname ilike '%chat%'
    and c.relkind in ('r', 'p', 'v', 'm', 'f')
    and n.nspname not in ('pg_catalog', 'information_schema')
    and n.nspname not like 'pg\_toast%'
    and n.nspname not like 'pg\_temp%';
  if v_txt is not null then
    raise exception 'FAIL [C4] relation(s) with "chat" in the name: %; expected none (chat stores nothing).', v_txt;
  end if;
  if to_regclass('storage.buckets') is not null then
    execute 'select count(*) from storage.buckets where id ilike ''%chat%'' or name ilike ''%chat%''' into v_n;
    if v_n <> 0 then
      raise exception 'FAIL [C4] % storage bucket(s) with "chat" in the name; expected none.', v_n;
    end if;
  end if;
  if to_regclass('storage.objects') is not null then
    execute 'select count(*) from storage.objects where bucket_id ilike ''%chat%''' into v_n;
    if v_n <> 0 then
      raise exception 'FAIL [C4] % storage object(s) in a "chat" bucket; expected none.', v_n;
    end if;
  end if;
  select string_agg(p.proname::text, ', ') into v_txt
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows';
  if v_txt is not null then
    raise exception 'FAIL [C4] other chat function(s) in public: %; expected none.', v_txt;
  end if;
  select p.prosrc into v_txt from pg_proc p where p.oid = to_regprocedure(v_fn);
  if v_txt ilike '%realtime.send%' or v_txt ~* '\m(insert|update|delete)\M' then
    raise exception 'FAIL [C4] chat_topic_allows'' body mentions realtime.send or a write; it must only read.';
  end if;
  v_checks := v_checks + 1;

  -- [C5] RLS still on for realtime.messages.
  if not (select c.relrowsecurity from pg_class c where c.oid = to_regclass('realtime.messages')) then
    raise exception 'FAIL [C5] row-level security is OFF on realtime.messages: the policies would not apply.';
  end if;
  v_checks := v_checks + 1;

  -- ==== SETUP, as the owner ====================================================
  begin
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at) values
      (v_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'chat-a-' || v_a::text || '@verification.invalid', now() - interval '5 minutes', now()),
      (v_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'chat-b-' || v_b::text || '@verification.invalid', now() - interval '4 minutes', now()),
      (v_c, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'chat-c-' || v_c::text || '@verification.invalid', now() - interval '3 minutes', now()),
      (v_d, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'chat-d-' || v_d::text || '@verification.invalid', now() - interval '2 minutes', now());
  exception when others then
    raise exception 'SETUP: could not create the temporary accounts in auth.users: % (%).', sqlerrm, sqlstate;
  end;

  select array_agg(c) into v_codes from (
    select lpad(n::text, 4, '0') as c
    from generate_series(0, 9999) n
    where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0'))
    order by n
    limit 5
  ) free_codes;
  if coalesce(array_length(v_codes, 1), 0) < 5 then
    raise exception 'SETUP: fewer than five unused table codes.';
  end if;

  begin
    -- Members one at a time, so the seat trigger seats them in order.
    insert into public.tables (code, created_by) values (v_codes[1], v_a) returning id into v_x;
    insert into public.table_members (table_id, user_id) values (v_x, v_a);
    insert into public.table_members (table_id, user_id) values (v_x, v_b);

    insert into public.tables (code, created_by) values (v_codes[2], v_c) returning id into v_y;
    insert into public.table_members (table_id, user_id) values (v_y, v_c);

    insert into public.tables (code, created_by, computer_level) values (v_codes[3], v_a, 'easy') returning id into v_k;
    insert into public.table_members (table_id, user_id) values (v_k, v_a);
    insert into public.table_members (table_id, user_id) values (v_k, v_b);

    -- Seated first, then ended: the way a Force-End leaves a table.
    insert into public.tables (code, created_by) values (v_codes[4], v_a) returning id into v_ended;
    insert into public.table_members (table_id, user_id) values (v_ended, v_a);
    insert into public.table_members (table_id, user_id) values (v_ended, v_b);
    update public.tables set status = 'ended', ended_reason = 'admin' where id = v_ended;

    insert into public.tables (code, created_by) values (v_codes[5], v_a) returning id into v_l;
    insert into public.table_members (table_id, user_id) values (v_l, v_a);
    insert into public.table_members (table_id, user_id) values (v_l, v_d);
  exception when others then
    raise exception 'SETUP: could not create the test tables and seats: % (%).', sqlerrm, sqlstate;
  end;

  v_xa := 'chat:' || v_x::text || ':' || v_a::text;
  v_xb := 'chat:' || v_x::text || ':' || v_b::text;

  -- ==== WALK-THROUGH ===========================================================
  -- Five phases. At the start of each, the world moves on (as the owner);
  -- then every case for that phase is asked, as its player (authenticated),
  -- and must give exactly the expected answer without raising an error.
  for v_phase in 1..5 loop
    if v_phase = 2 then
      -- X: a game starts, in the cut.
      begin
        insert into public.games (table_id, created_by, status, players, deal_cut, created_at)
        values (v_x, v_a, 'cutting', array[v_a, v_b], '[[]]'::jsonb, now() - interval '1 hour')
        returning id into v_g;
      exception when others then
        raise exception 'SETUP [W2] could not start a game at X: % (%).', sqlerrm, sqlstate;
      end;
    elsif v_phase = 3 then
      -- X: mid-game.
      begin
        update public.games set status = 'active', phase = 'discard' where id = v_g;
      exception when others then
        raise exception 'SETUP [W3] could not move the game to active: % (%).', sqlerrm, sqlstate;
      end;
    elsif v_phase = 4 then
      -- X: the game is over (A won); the table stays open.
      begin
        update public.games
        set status = 'ended', ended_reason = 'won', winner_id = v_a, current_player = null
        where id = v_g;
      exception when others then
        raise exception 'SETUP [W4] could not end the game: % (%).', sqlerrm, sqlstate;
      end;
      if (select t.status from public.tables t where t.id = v_x) is distinct from 'open' then
        raise exception 'SETUP [W4] table X is no longer open after the game ended.';
      end if;
    elsif v_phase = 5 then
      -- L: D leaves, through the app's own leave_table.
      perform set_config('request.jwt.claims', json_build_object('sub', v_d, 'role', 'authenticated')::text, true);
      v_msg := null;
      execute 'set local role authenticated';
      begin
        perform public.leave_table(v_l);
      exception when others then
        v_msg := sqlerrm;
      end;
      execute 'reset role';
      if exists (select 1 from public.table_members tm where tm.table_id = v_l and tm.user_id = v_d) then
        raise exception 'SETUP [W5] D is still seated at L after leave_table (%).', coalesce(v_msg, 'no error');
      end if;
    end if;

    for v_rec in
      select *
      from (values
        -- phase, label, actor (null = nobody signed in), topic, send, expected
        (1, 'W1 A receives X:A', v_a, v_xa::text, false, true),
        (1, 'W1 A sends on X:A', v_a, v_xa, true, true),
        (1, 'W1 A receives X:B', v_a, v_xb, false, true),
        (1, 'W1 A sends on X:B (B''s channel)', v_a, v_xb, true, false),
        (1, 'W1 B sends on X:B', v_b, v_xb, true, true),
        (1, 'W1 B receives X:A', v_b, v_xa, false, true),
        (1, 'W1 C (not seated at X) receives X:A', v_c, v_xa, false, false),
        (1, 'W1 C sends on X:C', v_c, 'chat:' || v_x::text || ':' || v_c::text, true, false),
        (1, 'W1 C receives X:C', v_c, 'chat:' || v_x::text || ':' || v_c::text, false, false),
        (1, 'W1 A receives Y:C (another table)', v_a, 'chat:' || v_y::text || ':' || v_c::text, false, false),
        (1, 'W1 A sends on Y:A (another table)', v_a, 'chat:' || v_y::text || ':' || v_a::text, true, false),
        (1, 'W1 C sends on Y:C (C''s own table)', v_c, 'chat:' || v_y::text || ':' || v_c::text, true, true),
        (1, 'W1 A receives K:A (computer table)', v_a, 'chat:' || v_k::text || ':' || v_a::text, false, false),
        (1, 'W1 A sends on K:A (computer table)', v_a, 'chat:' || v_k::text || ':' || v_a::text, true, false),
        (1, 'W1 A receives E:A (ended table)', v_a, 'chat:' || v_ended::text || ':' || v_a::text, false, false),
        (1, 'W1 A sends on E:A (ended table)', v_a, 'chat:' || v_ended::text || ':' || v_a::text, true, false),
        (1, 'W1 D receives L:D (before leaving)', v_d, 'chat:' || v_l::text || ':' || v_d::text, false, true),
        (1, 'W1 D sends on L:D (before leaving)', v_d, 'chat:' || v_l::text || ':' || v_d::text, true, true),
        (1, 'W1 A on a table that does not exist', v_a, 'chat:' || v_e::text || ':' || v_a::text, false, false),
        (1, 'W1 nobody signed in receives X:A', null::uuid, v_xa, false, false),
        (1, 'W1 nobody signed in sends on X:A', null, v_xa, true, false),
        -- Malformed topics: A is seated at X, so only the shape is wrong.
        (1, 'W1 malformed: empty', v_a, '', false, false),
        (1, 'W1 malformed: null topic', v_a, null, false, false),
        (1, 'W1 malformed: null send flag', v_a, v_xa, null::boolean, false),
        (1, 'W1 malformed: uppercase sender (receive)', v_a, 'chat:' || v_x::text || ':' || upper(v_a::text), false, false),
        (1, 'W1 malformed: uppercase sender (send)', v_a, 'chat:' || v_x::text || ':' || upper(v_a::text), true, false),
        (1, 'W1 malformed: uppercase table id', v_a, 'chat:' || upper(v_x::text) || ':' || v_a::text, false, false),
        (1, 'W1 malformed: "Chat:"', v_a, 'Chat:' || v_x::text || ':' || v_a::text, false, false),
        (1, 'W1 malformed: trailing space', v_a, v_xa || ' ', false, false),
        (1, 'W1 malformed: trailing newline', v_a, v_xa || chr(10), false, false),
        (1, 'W1 malformed: leading space', v_a, ' ' || v_xa, false, false),
        (1, 'W1 malformed: "xchat:"', v_a, 'x' || v_xa, false, false),
        (1, 'W1 malformed: ":extra" on the end', v_a, v_xa || ':extra', false, false),
        (1, 'W1 malformed: one hex digit too many', v_a, v_xa || '0', false, false),
        (1, 'W1 malformed: one id only', v_a, 'chat:' || v_x::text, false, false),
        (1, 'W1 malformed: not a uuid', v_a, 'chat:not-a-uuid:' || v_a::text, false, false),
        (1, 'W1 malformed: no hyphens', v_a, 'chat:' || replace(v_x::text, '-', '') || ':' || v_a::text, false, false),
        (1, 'W1 malformed: a "g" in an id', v_a, 'chat:' || v_x::text || ':g' || substr(v_a::text, 2), false, false),
        (1, 'W1 malformed: braces', v_a, 'chat:{' || v_x::text || '}:' || v_a::text, false, false),
        (1, 'W1 malformed: "room:"', v_a, 'room:' || v_x::text || ':' || v_a::text, false, false),
        (1, 'W1 malformed: no sender', v_a, 'chat:' || v_x::text || ':', false, false),
        -- W2-W4: X through a game.
        (2, 'W2 cut: A receives X:A', v_a, v_xa, false, true),
        (2, 'W2 cut: A sends on X:A', v_a, v_xa, true, true),
        (2, 'W2 cut: B receives X:A', v_b, v_xa, false, true),
        (3, 'W3 mid-game: A receives X:A', v_a, v_xa, false, true),
        (3, 'W3 mid-game: A sends on X:A', v_a, v_xa, true, true),
        (3, 'W3 mid-game: B receives X:A', v_b, v_xa, false, true),
        (4, 'W4 game over: A receives X:A', v_a, v_xa, false, true),
        (4, 'W4 game over: A sends on X:A', v_a, v_xa, true, true),
        (4, 'W4 game over: B receives X:A', v_b, v_xa, false, true),
        -- W5: after D left L.
        (5, 'W5 D (left) receives L:D', v_d, 'chat:' || v_l::text || ':' || v_d::text, false, false),
        (5, 'W5 D (left) sends on L:D', v_d, 'chat:' || v_l::text || ':' || v_d::text, true, false),
        (5, 'W5 D (left) receives L:A', v_d, 'chat:' || v_l::text || ':' || v_a::text, false, false),
        (5, 'W5 A (still seated) sends on L:A', v_a, 'chat:' || v_l::text || ':' || v_a::text, true, true),
        (5, 'W5 A receives L:D (D''s silent channel)', v_a, 'chat:' || v_l::text || ':' || v_d::text, false, true)
      ) as t(phase, label, actor, topic, send, want)
      where t.phase = v_phase
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
  end loop;

  -- [A1] anon can't call it at all.
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  v_state := null;
  execute 'set local role anon';
  begin
    perform public.chat_topic_allows(v_xa, false);
  exception when others then
    v_state := sqlstate;
  end;
  execute 'reset role';
  if v_state is distinct from '42501' then
    raise exception 'FAIL [A1] anon calling chat_topic_allows: %; expected 42501 (permission denied).', coalesce(v_state, 'it ran');
  end if;
  v_checks := v_checks + 1;

  -- ==== LIVE POLICIES ==========================================================
  -- Exactly what Realtime does for a private channel: as the player, with
  -- realtime.topic set, an insert (may send?) and a select (may receive?).
  if not has_table_privilege('authenticated', 'realtime.messages', 'INSERT')
     or not has_table_privilege('authenticated', 'realtime.messages', 'SELECT') then
    v_live := 'authenticated lacks SELECT or INSERT on realtime.messages (see the precheck)';
  end if;

  -- [P1] A sends on X:A.
  if v_live is null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
    perform set_config('realtime.topic', v_xa, true);
    v_state := null;
    execute 'set local role authenticated';
    begin
      insert into realtime.messages (topic, extension, event, payload, private)
      values (v_xa, 'broadcast', 'chat-verification', jsonb_build_object('text', 'hello'), true);
    exception when others then
      v_state := sqlstate;
      v_msg := sqlerrm;
    end;
    execute 'reset role';
    if v_state = '42501' then
      raise exception 'FAIL [P1] A sending on A''s own topic at X was refused: %.', v_msg;
    elsif v_state is not null then
      -- Not a policy answer: the row couldn't be written at all (usually no
      -- daily partition for today).
      v_live := 'a test insert into realtime.messages failed with ' || v_state || ' ' || v_msg;
    else
      v_checks := v_checks + 1;
    end if;
  end if;

  if v_live is null then
    -- [P2] B sends on X:A: refused.
    perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
    perform set_config('realtime.topic', v_xa, true);
    v_state := null;
    execute 'set local role authenticated';
    begin
      insert into realtime.messages (topic, extension, event, payload, private)
      values (v_xa, 'broadcast', 'chat-verification', jsonb_build_object('text', 'as A?'), true);
    exception when others then
      v_state := sqlstate;
    end;
    execute 'reset role';
    if v_state is distinct from '42501' then
      raise exception 'FAIL [P2] B sending on A''s topic: %; expected 42501.', coalesce(v_state, 'allowed');
    end if;
    v_checks := v_checks + 1;

    -- [P3] B receives X:A: sees A's message.
    execute 'set local role authenticated';
    select count(*) into v_n from realtime.messages m
    where m.topic = v_xa and m.event = 'chat-verification';
    execute 'reset role';
    if v_n <> 1 then
      raise exception 'FAIL [P3] B receiving X:A saw % test message(s); expected 1.', v_n;
    end if;
    v_checks := v_checks + 1;

    -- [P4] C (not seated at X) receives X:A: sees nothing.
    perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
    perform set_config('realtime.topic', v_xa, true);
    execute 'set local role authenticated';
    select count(*) into v_n from realtime.messages m
    where m.topic = v_xa and m.event = 'chat-verification';
    execute 'reset role';
    if v_n <> 0 then
      raise exception 'FAIL [P4] C (not seated at X) receiving X:A saw % message(s); expected 0. Another policy on realtime.messages may be letting it through (% other policies).', v_n, v_others;
    end if;
    v_checks := v_checks + 1;

    -- [P5] C sends on X:C: refused.
    perform set_config('realtime.topic', 'chat:' || v_x::text || ':' || v_c::text, true);
    v_state := null;
    execute 'set local role authenticated';
    begin
      insert into realtime.messages (topic, extension, event, payload, private)
      values ('chat:' || v_x::text || ':' || v_c::text, 'broadcast', 'chat-verification', '{}'::jsonb, true);
    exception when others then
      v_state := sqlstate;
    end;
    execute 'reset role';
    if v_state is distinct from '42501' then
      raise exception 'FAIL [P5] C sending at X: %; expected 42501.', coalesce(v_state, 'allowed');
    end if;
    v_checks := v_checks + 1;

    -- [P6] anon on X:A: no send, nothing received.
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
    perform set_config('realtime.topic', v_xa, true);
    v_state := null;
    v_n := 0;
    execute 'set local role anon';
    begin
      insert into realtime.messages (topic, extension, event, payload, private)
      values (v_xa, 'broadcast', 'chat-verification', '{}'::jsonb, true);
    exception when others then
      v_state := sqlstate;
    end;
    begin
      select count(*) into v_n from realtime.messages m where m.topic = v_xa;
    exception when others then
      v_n := 0;  -- no SELECT privilege at all: refused, which is the point
    end;
    execute 'reset role';
    if v_state is distinct from '42501' or v_n <> 0 then
      raise exception 'FAIL [P6] anon on X:A: insert %, saw % message(s); expected 42501 and 0.', coalesce(v_state, 'allowed'), v_n;
    end if;
    v_checks := v_checks + 1;

    -- [P7] A sends a presence message on X:A: refused (broadcast only).
    perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
    perform set_config('realtime.topic', v_xa, true);
    v_state := null;
    execute 'set local role authenticated';
    begin
      insert into realtime.messages (topic, extension, event, payload, private)
      values (v_xa, 'presence', 'chat-verification', '{}'::jsonb, true);
    exception when others then
      v_state := sqlstate;
    end;
    execute 'reset role';
    if v_state is distinct from '42501' then
      raise exception 'FAIL [P7] A sending presence on X:A: %; expected 42501.', coalesce(v_state, 'allowed');
    end if;
    v_checks := v_checks + 1;
  else
    v_skips := v_skips || ' skipped P1-P7 (live policies): ' || v_live || '; the rules are proven by W and C3 only.';
  end if;

  -- ---- Verdict ----------------------------------------------------------------
  -- 5 catalog + 55 walk-through + 1 anon + 7 live (0 when skipped).
  -- The expected count goes into a variable first: PL/pgSQL ends an IF
  -- condition at the first THEN it meets, so a CASE ... THEN written inside
  -- the condition cut it short (a syntax error before anything ran).
  v_expect := case when v_live is null then 68 else 61 end;
  if v_checks <> v_expect then
    raise exception 'FAIL: % checks ran, expected %.', v_checks, v_expect;
  end if;

  raise exception 'ALL % CHECKS PASSED (rolled back).% Other policies on realtime.messages: %.',
    v_checks, v_skips, v_others;
end;
$$;
