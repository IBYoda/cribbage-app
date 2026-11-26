-- Moderation, slice M3: KICK. PART 1: ADD-ONLY (safe before any app
-- change). Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M3):
--   1. docs/sql/moderation-m3-precheck.sql       (read-only; no STOP rows)
--   2. docs/sql/moderation-m3-part1.sql          (THIS FILE)
--   3. docs/sql/moderation-m3-verification.sql   (part-1 mode: "ALL n
--      PART-1 CHECKS PASSED ...") and docs/sql/slice-e-grants-verification.sql
--      (56 names, table_kicks known)
--   4. the app (PR): the real Kick, the unified confirm, the kick notice,
--      the kicked person's exit, the admin page's Recent kicks; old tabs
--      reload
--   5. docs/sql/moderation-m3-precheck.sql again (state "part 1 present")
--   6. docs/sql/moderation-m3-part2.sql          (the swap: join and watch)
--   7. docs/sql/moderation-m3-verification.sql   (full mode: "ALL n CHECKS
--      PASSED")
--   8. the regression suites (the list in moderation-m3-part2.sql's header)
--   9. the hand test
--   Rollbacks, newest first: moderation-m3-part2-rollback.sql, then
--   moderation-m3-part1-rollback.sql.
--
-- WHAT WALT DECIDED (M3, final): only the HOST (table_host()) kicks, never
-- themself; while the creator is seated the creator is the host, so nobody
-- can kick the creator then. A player OR a spectator, at any time (mid-game
-- the live game ends as player_left, exactly as when someone leaves). A
-- kick lasts for THAT table (the table id) only: the kicked person can never
-- join or watch it again and is told only "You can't join this table."
-- (part 2). Someone who left a moment before the kick lands is recorded
-- anyway (role 'absent'), so leaving can't dodge it. Every kick is logged
-- (host, target, table, time, whether a game was live), readable by admins
-- only; 20 kicks an hour per host. Everyone else at the table hears of the
-- kick at once (the notice below) and is asked whether to block.
--
-- WHAT THIS FILE DOES (one transaction; nothing here changes what join or
-- watch do -- part 2 does that):
--   0. GUARD (raises, changing nothing, unless all hold): the four
--      fingerprinted bodies (leave_table, end_timed_out_sessions,
--      assign_table_seat, table_host) and spectator_heartbeat,
--      remove_spectator, chat_topic_allows, _attempts_guard unchanged (LF or
--      CRLF); join_table_by_code and watch_table are M1 part 2's or M3
--      part 2's (a re-run); M1 part 1 and M2 part 1 are in;
--      attempt_log_action_check allows exactly the eight actions (or those
--      plus kick: a re-run); public.table_kicks absent or with this file's
--      columns; the five function names absent or holding exactly this
--      file's signature and body; realtime.messages exists with RLS on and
--      its policies are exactly the two table-chat ones (or those plus this
--      file's: a re-run); realtime.send(jsonb, text, text, boolean) exists.
--   1. attempt_log_action_check also allows 'kick'. Written only by
--      kick_player for a REAL kick (not 'already_kicked', not a refusal).
--   2. public.table_kicks: one row per kicked person per table (primary key
--      (table_id, kicked_id)), with the host, the kicked person's nickname
--      at that moment, their role ('player', 'spectator' or 'absent'),
--      whether a game was live and which. RLS ON with NO policies and ALL
--      privileges revoked from PUBLIC, anon, authenticated and service_role
--      (AGENTS.md "New tables": least privilege -- clients never touch it;
--      admins read it through admin_recent_kicks). Not in the
--      supabase_realtime publication.
--   3. Functions, all SECURITY DEFINER with search_path '':
--        _is_kicked_from_table(p_caller uuid, p_table_id uuid) boolean
--          INTERNAL (no client role): part 2's join and watch call it.
--        _send_kick_notice(p_table_id uuid, p_payload jsonb) void
--          INTERNAL: realtime.send(p_payload, 'kick', 'kicks:<table_id>',
--          true) -- a private Realtime broadcast on that table's kick topic.
--        kick_player(p_table_id uuid, p_target uuid) text   authenticated
--          The host kicks p_target. Returns 'kicked' or 'already_kicked';
--          raises a plain message otherwise (not logged in, yourself, no
--          such table, ended, a computer table, not the host, no such
--          person, a computer player) and, on the 21st real kick in an
--          hour, detail rate_limited. See the function's comments for the
--          locks.
--        kick_topic_allows(p_topic text) boolean             authenticated
--          May the signed-in person RECEIVE on kicks:<table_id>? Seated at
--          that open human table, or a current spectator of it (chat's
--          receive rule). Used only by the policy below.
--        admin_recent_kicks(p_limit integer) table           authenticated
--          Admins only ("Admins only." for anyone else): the newest kicks
--          with the table's code and both nicknames.
--   4. ONE policy on realtime.messages, "table kicks: people at the table
--      receive" (SELECT, to authenticated, broadcast, kick_topic_allows).
--      There is NO insert policy for kicks: no client can send on a kicks:
--      topic (the chat send policy refuses any topic that is not chat:...);
--      only kick_player can, through realtime.send. Neither the policy's
--      name nor any function name here contains "chat" (the chat suites'
--      C4/C5 rules).
--
-- THE NOTICE NEVER UNDOES A KICK: kick_player calls _send_kick_notice inside
-- its own BEGIN ... EXCEPTION WHEN OTHERS THEN NULL block (a
-- subtransaction). If the send fails for any reason (no realtime.messages
-- partition for today, Realtime not set up, anything), only that
-- subtransaction is rolled back: the kick, the game's end, the log row and
-- the attempt_log row stand. moderation-m3-verification.sql proves it by
-- making _send_kick_notice raise and kicking.
--
-- md5 of the new bodies (carriage returns removed; LF), and with CRLF line
-- ends (this file as committed):
--   _is_kicked_from_table   c8372af51a4537ca9cc079234487a414 / 81b8f7c08c58da52ffddf2ade938a6ee
--   _send_kick_notice       382554f98b1f199c20ca0b692fa0e6f2 / 5e24e0a9bfc0299486f50384d1f3b546
--   kick_player             d859deb84acb67ec94a2cf65fb1f38f0 / f1bacf2a984d30c7cadd74af220b327a
--   kick_topic_allows       48327bb75cf98b6ff91388a6db843d11 / 480429d8468d50b51ed268739180aed3
--   admin_recent_kicks      a5a60cc3950475e702423f740b30cf40 / ac4f02ebb6a999087007ed3540d01a00
--
-- NOT TOUCHED: join_table_by_code and watch_table (part 2), leave_table,
-- end_timed_out_sessions, assign_table_seat, table_host (fingerprinted),
-- spectator_heartbeat, remove_spectator (still granted; the app stops
-- calling it), stop_watching, chat_topic_allows and the two table-chat
-- policies, the end-when-empty and require-open triggers, every other
-- function, policy and grant.
--
-- RE-RUNNABLE: the constraint is dropped and re-added with the nine
-- actions; "create table / index if not exists"; "create or replace
-- function"; "drop policy if exists" then create; idempotent revokes and
-- grants.
-- ROLLBACK: docs/sql/moderation-m3-part1-rollback.sql (only after part 2 is
-- rolled back or was never run: part 2 calls _is_kicked_from_table).

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard.
-- ---------------------------------------------------------------------------
do $$
declare
  v_rec record;
  v_txt text;
  v_n integer;
begin
  -- The four fingerprinted bodies and the four others this file must not
  -- touch, unchanged (LF or CRLF).
  for v_rec in
    select * from (values
      ('public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa'),
      ('public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c'),
      ('public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb'),
      ('public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d'),
      ('public.spectator_heartbeat(uuid)', '41d2ea0e865c2a9d5fa7203875a27ace', '6b7c271d78eb4f72c1aff3c851b578e1'),
      ('public.remove_spectator(uuid, uuid)', 'dafa688f1b8c194e4be575cd0625ba12', '9786b9a5e50245365a2598b18da5892e'),
      ('public.chat_topic_allows(text, boolean)', '0458d5122d68d511b2e0fbceafe84aae', 'c4e6eda360de7d7723c4069e60d95345'),
      ('public._attempts_guard(uuid, text, integer, interval, text)', 'b1b69dbbdf10d50f78655a0da3b3ac69', '9406938991e89dcd38d0686a279b432a')
    ) as t(fn, lf, crlf)
  loop
    select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is null or v_txt not in (v_rec.lf, v_rec.crlf) then
      raise exception 'STOP: % has body md5 %; expected % (LF) or % (CRLF). Nothing was changed.', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf, v_rec.crlf;
    end if;
  end loop;

  -- join_table_by_code and watch_table: M1 part 2's or M3 part 2's (LF or
  -- CRLF each).
  for v_rec in
    select * from (values
      ('public.join_table_by_code(text, boolean, uuid)', 'cf40593ee5afda235144a13e38d27f4a', 'c3ee9ced2e1033f9c068acd3325c5583', '297fa4f04a02e226691ebf3b5b135f83', 'fbf046f1582863cc5697b06f670481b2'),
      ('public.watch_table(text, uuid)', '5bf6065de215d92a02af63d035c7f910', '2aa5f9c37d65271f3b4619e58c171ea0', 'bdebb2e1a8213baa2a04666bcad59adb', 'ea5c3bd739b2f7243b985c7ea1fd9f2a')
    ) as t(fn, m1_lf, m1_crlf, m3_lf, m3_crlf)
  loop
    select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is null or v_txt not in (v_rec.m1_lf, v_rec.m1_crlf, v_rec.m3_lf, v_rec.m3_crlf) then
      raise exception 'STOP: % has body md5 %; expected M1 part 2''s % / % or M3 part 2''s % / %. Capture it first: select pg_get_functiondef(''%''::regprocedure); Nothing was changed.', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.m1_lf, v_rec.m1_crlf, v_rec.m3_lf, v_rec.m3_crlf, v_rec.fn;
    end if;
  end loop;

  -- M1 part 1 and M2 part 1 are in.
  if to_regclass('public.blocks') is null
     or to_regprocedure('public._is_blocked_from_table(uuid, uuid)') is null
     or to_regprocedure('public.block_player_by_id(uuid)') is null then
    raise exception 'STOP: moderation M1 part 1 or M2 part 1 is not in (public.blocks, _is_blocked_from_table, block_player_by_id). Nothing was changed.';
  end if;

  -- The attempt_log check: the eight actions, or those plus kick (a re-run).
  select pg_get_constraintdef(con.oid) into v_txt
  from pg_constraint con
  where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check';
  v_n := (length(coalesce(v_txt, '')) - length(replace(coalesce(v_txt, ''), '::text', ''))) / 6;
  if v_txt is null
     or v_txt !~ '''create_table''' or v_txt !~ '''create_computer_table''' or v_txt !~ '''join'''
     or v_txt !~ '''watch''' or v_txt !~ '''code_guess''' or v_txt !~ '''game_start''' or v_txt !~ '''follow_change'''
     or v_txt !~ '''block_change'''
     or v_n not in (8, 9)
     or (v_n = 9 and v_txt !~ '''kick''') then
    raise exception 'STOP: attempt_log_action_check is "%"; expected exactly create_table, create_computer_table, join, watch, code_guess, game_start, follow_change, block_change (or those plus kick on a re-run). Nothing was changed.', coalesce(v_txt, 'missing');
  end if;

  -- public.table_kicks: absent, or this file's columns (a re-run).
  if to_regclass('public.table_kicks') is not null then
    select string_agg(a.attname::text || ' ' || format_type(a.atttypid, a.atttypmod), ', ' order by a.attnum) into v_txt
    from pg_attribute a
    where a.attrelid = 'public.table_kicks'::regclass and a.attnum > 0 and not a.attisdropped;
    if v_txt is distinct from 'table_id uuid, kicked_id uuid, host_id uuid, kicked_nickname text, kicked_role text, game_live boolean, game_id uuid, created_at timestamp with time zone' then
      raise exception 'STOP: public.table_kicks exists with columns "%"; expected this file''s eight (or no table). Nothing was changed.', v_txt;
    end if;
  end if;

  -- The five function names: absent, or exactly this file's signature and
  -- body (a re-run). md5 with carriage returns removed.
  for v_rec in
    select * from (values
      ('_is_kicked_from_table', 'public._is_kicked_from_table(uuid, uuid)', 'c8372af51a4537ca9cc079234487a414'),
      ('_send_kick_notice', 'public._send_kick_notice(uuid, jsonb)', '382554f98b1f199c20ca0b692fa0e6f2'),
      ('kick_player', 'public.kick_player(uuid, uuid)', 'd859deb84acb67ec94a2cf65fb1f38f0'),
      ('kick_topic_allows', 'public.kick_topic_allows(text)', '48327bb75cf98b6ff91388a6db843d11'),
      ('admin_recent_kicks', 'public.admin_recent_kicks(integer)', 'a5a60cc3950475e702423f740b30cf40')
    ) as t(name, sig, lf)
  loop
    select count(*) into v_n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.proname = v_rec.name;
    if v_n > 1 or (v_n = 1 and to_regprocedure(v_rec.sig) is null) then
      raise exception 'STOP: public.% already exists with another signature (% function(s) by that name); expected none or exactly %. Nothing was changed.', v_rec.name, v_n, v_rec.sig;
    end if;
    if v_n = 1 then
      select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.sig);
      if v_txt is distinct from v_rec.lf then
        raise exception 'STOP: % exists with body md5 % (carriage returns removed), not this file''s %. Capture it first: select pg_get_functiondef(''%''::regprocedure); Nothing was changed.', v_rec.sig, v_txt, v_rec.lf, v_rec.sig;
      end if;
    end if;
  end loop;

  -- Realtime: realtime.messages with RLS on; exactly the two table-chat
  -- policies, or those plus this file's (a re-run); realtime.send.
  if to_regclass('realtime.messages') is null
     or not (select c.relrowsecurity from pg_class c where c.oid = to_regclass('realtime.messages')) then
    raise exception 'STOP: realtime.messages is missing or its row-level security is off. Nothing was changed.';
  end if;
  select string_agg(p.policyname::text, ', ' order by p.policyname) into v_txt
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
    and p.policyname not in ('table chat: members receive', 'table chat: members send', 'table kicks: people at the table receive');
  if v_txt is not null then
    raise exception 'STOP: unknown policies on realtime.messages: %. Policies are OR''ed; look at them first. Nothing was changed.', v_txt;
  end if;
  select count(*) into v_n
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
    and p.policyname in ('table chat: members receive', 'table chat: members send');
  if v_n <> 2 then
    raise exception 'STOP: found % of the two table-chat policies on realtime.messages; expected 2. Nothing was changed.', v_n;
  end if;
  if to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null then
    raise exception 'STOP: realtime.send(jsonb, text, text, boolean) does not exist: the kick notice needs it (Realtime Broadcast from the database). Nothing was changed.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The new attempt_log action.
-- ---------------------------------------------------------------------------
alter table public.attempt_log drop constraint attempt_log_action_check;
alter table public.attempt_log
  add constraint attempt_log_action_check
  check (action in ('create_table', 'create_computer_table', 'join', 'watch', 'code_guess',
                    'game_start', 'follow_change', 'block_change', 'kick'));

comment on table public.attempt_log is
  'Rate limits (step 3, slices A and E; moderation M1 and M3): one row per counted action -- a table created (create_table), a computer game started (create_computer_table), a join, a new watch, a game started (game_start), a real follow or unfollow (follow_change), a real block or unblock (block_change), a real kick (kick) (success true), or a wrong table code (code_guess, success false). Read and written only by security definer functions through the _attempts_* / _code_guess* helpers. Rows older than 7 days are deleted hourly by cleanup_attempt_log() (pg_cron job attempt-log-cleanup). RLS on, no policies, no grants. See docs/sql/join-create.sql, slice-e-part1.sql, moderation-m1-part1.sql and moderation-m3-part1.sql.';

-- ---------------------------------------------------------------------------
-- 2. public.table_kicks (AGENTS.md "New tables": the template's order --
--    table, comment, RLS on, revokes, grants (none), policies (none)).
-- ---------------------------------------------------------------------------
create table if not exists public.table_kicks (
  table_id uuid not null references public.tables (id) on delete cascade,
  kicked_id uuid not null references auth.users (id) on delete cascade,
  -- Kept (set null) if the host's account is deleted: the log survives.
  host_id uuid references auth.users (id) on delete set null,
  -- The kicked person's nickname at that moment: the notice's name and the
  -- admin list's, after they have left the roster.
  kicked_nickname text,
  kicked_role text not null,
  game_live boolean not null,
  game_id uuid references public.games (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (table_id, kicked_id),
  constraint table_kicks_role_check check (kicked_role in ('player', 'spectator', 'absent')),
  constraint table_kicks_not_self check (host_id is distinct from kicked_id)
);

-- The primary key serves join/watch's lookup (this table, this caller) and
-- "already kicked". These serve the admin list and the two cascades.
create index if not exists table_kicks_created_at_idx on public.table_kicks (created_at desc);
create index if not exists table_kicks_kicked_id_idx on public.table_kicks (kicked_id);
create index if not exists table_kicks_host_id_idx on public.table_kicks (host_id);

comment on table public.table_kicks is
  'Moderation M3: one row per person kicked from a table (by its host, kick_player). A kicked person can never join or watch THAT table again (join_table_by_code / watch_table, moderation-m3-part2.sql) and is only told "You can''t join this table.". PRIVATE: no client role has any privilege on it and RLS is on with no policies; written only by kick_player, read by _is_kicked_from_table and by admins through admin_recent_kicks (security definer). See docs/sql/moderation-m3-part1.sql.';

-- Row-level security on, with NO policies: deny by default.
alter table public.table_kicks enable row level security;

-- No privileges for any client role (least privilege: the app never touches
-- the table directly; admins read it through admin_recent_kicks). Revoking
-- everything also removes anything the project's default privileges gave
-- the table when it was created. service_role too: nothing needs it.
revoke all on table public.table_kicks from public;
revoke all on table public.table_kicks from anon;
revoke all on table public.table_kicks from authenticated;
revoke all on table public.table_kicks from service_role;

-- No grants and no policies: deliberately none. No Realtime: deliberately
-- not added to the supabase_realtime publication (the notice is a
-- broadcast, below).

-- ---------------------------------------------------------------------------
-- 3. The functions.
-- ---------------------------------------------------------------------------
create or replace function public._is_kicked_from_table(p_caller uuid, p_table_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- True when p_caller was kicked from p_table_id (by its host, at any
  -- time). A null caller or an unknown table is never kicked.
  select exists (
    select 1
    from public.table_kicks k
    where k.table_id = p_table_id
      and k.kicked_id = p_caller
  );
$$;

comment on function public._is_kicked_from_table(uuid, uuid) is
  'Internal (moderation M3): true when p_caller was kicked from p_table_id (public.table_kicks). Called by join_table_by_code and watch_table (moderation-m3-part2.sql). No client role can execute it. See docs/sql/moderation-m3-part1.sql.';

revoke all on function public._is_kicked_from_table(uuid, uuid) from public;
revoke all on function public._is_kicked_from_table(uuid, uuid) from anon;
revoke all on function public._is_kicked_from_table(uuid, uuid) from authenticated;
revoke all on function public._is_kicked_from_table(uuid, uuid) from service_role;


create or replace function public._send_kick_notice(p_table_id uuid, p_payload jsonb)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  -- A private Realtime broadcast on the table's kick topic, lowercase
  -- (a uuid's text form is lowercase). Delivered only if the transaction
  -- commits. Who may receive it: kick_topic_allows (the policy).
  perform realtime.send(p_payload, 'kick', 'kicks:' || p_table_id::text, true);
end;
$$;

comment on function public._send_kick_notice(uuid, jsonb) is
  'Internal (moderation M3): sends the kick notice -- realtime.send(payload, ''kick'', ''kicks:<table_id>'', true). Called only by kick_player, inside its own exception block, so a failed send never undoes a kick. No client role can execute it. See docs/sql/moderation-m3-part1.sql.';

revoke all on function public._send_kick_notice(uuid, jsonb) from public;
revoke all on function public._send_kick_notice(uuid, jsonb) from anon;
revoke all on function public._send_kick_notice(uuid, jsonb) from authenticated;
revoke all on function public._send_kick_notice(uuid, jsonb) from service_role;


create or replace function public.kick_player(p_table_id uuid, p_target uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_table record;
  v_game uuid;
  v_role text;
  v_nickname text;
begin
  if v_actor is null then
    raise exception 'You must be logged in to kick a player.';
  end if;

  if p_target is not null and p_target = v_actor then
    raise exception 'You can''t kick yourself.';
  end if;

  -- THE TARGET'S PERSON LOCK, the one join_table_by_code, watch_table and
  -- create_table take first: a kick and the target's own join or watch run
  -- one after the other, so a join can never slip in beside a kick (part 2's
  -- refusal reads table_kicks after this lock is free).
  if p_target is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('one_table:' || p_target::text, 0));
  end if;

  -- GAMES THEN TABLES, leave_table's order (its UPDATE of the live game,
  -- then the end-when-empty trigger's tables lock): a kick and a leave at
  -- the same table never wait on each other in opposite orders.
  select g.id
  into v_game
  from public.games g
  where g.table_id = p_table_id
    and g.status in ('cutting', 'active')
  order by g.created_at desc
  limit 1
  for no key update;

  -- THE TABLES ROW LOCK, the one the seat trigger, set_seat, watch_table
  -- and start_game_with_deal take: joins, watches and seat moves wait, so
  -- the host read below holds until this transaction ends.
  select t.id, t.status, t.computer_level
  into v_table
  from public.tables t
  where t.id = p_table_id
  for no key update;

  if not found then
    raise exception 'Table not found.';
  end if;

  if v_table.status is distinct from 'open' then
    raise exception 'This table has ended.';
  end if;

  if v_table.computer_level is not null then
    raise exception 'You can''t kick anyone at a computer table.';
  end if;

  -- The host, by the existing rule (table_host: the creator while seated,
  -- otherwise the lowest seat). While the creator is seated they are the
  -- host, so kicking the creator then could only be kicking yourself,
  -- refused above.
  if public.table_host(p_table_id) is distinct from v_actor then
    raise exception 'Only the host can kick.';
  end if;

  if p_target is null or not exists (select 1 from auth.users u where u.id = p_target) then
    raise exception 'That player was not found.';
  end if;

  if exists (select 1 from public.computer_accounts ca where ca.user_id = p_target) then
    raise exception 'You can''t kick a computer player.';
  end if;

  -- Kicked before: nothing changes and nothing is counted.
  if exists (
    select 1
    from public.table_kicks k
    where k.table_id = p_table_id
      and k.kicked_id = p_target
  ) then
    return 'already_kicked';
  end if;

  -- What they are at this table right now. Someone who left a moment ago is
  -- 'absent' and is kicked all the same: leaving can't dodge a kick.
  if exists (
    select 1
    from public.table_members tm
    where tm.table_id = p_table_id
      and tm.user_id = p_target
  ) then
    v_role := 'player';
  elsif exists (
    select 1
    from public.table_spectators ts
    where ts.table_id = p_table_id
      and ts.user_id = p_target
      and ts.removed_at is null
  ) then
    v_role := 'spectator';
  else
    v_role := 'absent';
  end if;

  -- 20 real kicks an hour per host (raises with detail rate_limited).
  perform public._attempts_guard(v_actor, 'kick', 20, interval '1 hour',
    'You have kicked 20 people in the last hour. Please try again a little later.');

  select p.nickname
  into v_nickname
  from public.profiles p
  where p.id = p_target;

  insert into public.table_kicks (table_id, kicked_id, host_id, kicked_nickname, kicked_role, game_live, game_id)
  values (p_table_id, p_target, v_actor, v_nickname, v_role, v_game is not null, v_game);

  if v_role = 'player' then
    -- leave_table's two statements, for the target (leave_table itself is
    -- untouched): the live game ends as player_left, then the seat goes.
    -- The end-when-empty trigger runs as for any leave; the host is still
    -- seated, so the table stays open.
    update public.games
    set status = 'ended', ended_reason = 'player_left'
    where table_id = p_table_id
      and status in ('cutting', 'active');

    delete from public.table_members
    where table_id = p_table_id
      and user_id = p_target;
  end if;

  -- A spectator's place is marked removed (their heartbeat answers
  -- 'removed': "The host removed you from this table."). The row stays.
  update public.table_spectators ts
  set removed_at = now()
  where ts.table_id = p_table_id
    and ts.user_id = p_target
    and ts.removed_at is null;

  -- THE NOTICE, in its own subtransaction: if the send fails, only the send
  -- is undone -- never the kick, the game's end or the log rows.
  begin
    perform public._send_kick_notice(p_table_id, pg_catalog.jsonb_build_object(
      'kicked_id', p_target,
      'nickname', coalesce(v_nickname, ''),
      'at', (extract(epoch from now()) * 1000)::bigint));
  exception when others then
    null;
  end;

  return 'kicked';
end;
$$;

comment on function public.kick_player(uuid, uuid) is
  'Moderation M3: the table''s HOST (table_host) kicks p_target -- a player (the live game ends as player_left and the seat goes, as when someone leaves), a spectator (removed_at, as remove_spectator), or someone who just left (recorded as absent). One row in table_kicks; the kicked person can never join or watch that table again (part 2). Returns kicked or already_kicked; raises a plain message for yourself, no such table, an ended or computer table, not the host, no such person, a computer player; 20 real kicks an hour (detail rate_limited). Sends the kick notice on kicks:<table_id>; a failed send never undoes the kick. See docs/sql/moderation-m3-part1.sql.';

revoke all on function public.kick_player(uuid, uuid) from public;
revoke all on function public.kick_player(uuid, uuid) from anon;
revoke all on function public.kick_player(uuid, uuid) from service_role;
revoke all on function public.kick_player(uuid, uuid) from authenticated;
grant execute on function public.kick_player(uuid, uuid) to authenticated;


create or replace function public.kick_topic_allows(p_topic text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_caller uuid := auth.uid();
  v_table_id uuid;
begin
  -- The exact shape, lowercase only: "kicks:" (6 characters) and a uuid
  -- (36): 42 characters in all.
  if p_topic is null
     or p_topic !~ '^kicks:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;

  if v_caller is null then
    return false;
  end if;

  v_table_id := substr(p_topic, 7, 36)::uuid;

  -- Seated at that open, human table.
  if exists (
    select 1
    from public.table_members tm
    join public.tables t on t.id = tm.table_id
    where tm.table_id = v_table_id
      and tm.user_id = v_caller
      and t.status = 'open'
      and t.computer_level is null
  ) then
    return true;
  end if;

  -- Or a CURRENT spectator of it: not removed, seen in the last 90 seconds,
  -- the table open, human and allowing spectators (chat's receive rule).
  return exists (
    select 1
    from public.table_spectators ts
    join public.tables t on t.id = ts.table_id
    where ts.table_id = v_table_id
      and ts.user_id = v_caller
      and ts.removed_at is null
      and ts.last_seen_at > now() - interval '90 seconds'
      and t.status = 'open'
      and t.computer_level is null
      and t.allow_spectators is true
  );
end;
$$;

comment on function public.kick_topic_allows(text) is
  'Moderation M3: may the signed-in person RECEIVE on the Realtime broadcast topic kicks:<table_id>? Seated at that open human table, or a current spectator of it. Used only by the "table kicks: people at the table receive" policy on realtime.messages. Nobody may send on it (no insert policy); only kick_player does, through realtime.send. See docs/sql/moderation-m3-part1.sql.';

-- The policy runs as authenticated, so authenticated executes it (as with
-- chat_topic_allows); nobody else.
revoke all on function public.kick_topic_allows(text) from public;
revoke all on function public.kick_topic_allows(text) from anon;
revoke all on function public.kick_topic_allows(text) from service_role;
revoke all on function public.kick_topic_allows(text) from authenticated;
grant execute on function public.kick_topic_allows(text) to authenticated;


create or replace function public.admin_recent_kicks(p_limit integer default 50)
returns table (
  kicked_at timestamptz,
  table_id uuid,
  table_code text,
  host_id uuid,
  host_nickname text,
  kicked_id uuid,
  kicked_nickname text,
  kicked_role text,
  game_live boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if auth.uid() is null
     or not exists (select 1 from public.admin_users a where a.user_id = auth.uid()) then
    raise exception 'Admins only.';
  end if;

  return query
  select k.created_at, k.table_id, t.code, k.host_id, hp.nickname, k.kicked_id, k.kicked_nickname, k.kicked_role, k.game_live
  from public.table_kicks k
  join public.tables t on t.id = k.table_id
  left join public.profiles hp on hp.id = k.host_id
  order by k.created_at desc, k.kicked_id
  limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$$;

comment on function public.admin_recent_kicks(integer) is
  'Moderation M3: ADMINS ONLY (admin_users; "Admins only." for anyone else): the newest kicks (1 to 200, default 50) with the table''s code, the host''s current nickname and the kicked person''s nickname at the time. The admin page''s Recent kicks. See docs/sql/moderation-m3-part1.sql.';

revoke all on function public.admin_recent_kicks(integer) from public;
revoke all on function public.admin_recent_kicks(integer) from anon;
revoke all on function public.admin_recent_kicks(integer) from service_role;
revoke all on function public.admin_recent_kicks(integer) from authenticated;
grant execute on function public.admin_recent_kicks(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. The policy on realtime.messages: people at the table RECEIVE the kick
--    notice. No insert policy: nobody but kick_player sends on kicks:.
-- ---------------------------------------------------------------------------
drop policy if exists "table kicks: people at the table receive" on realtime.messages;
create policy "table kicks: people at the table receive"
  on realtime.messages
  for select
  to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and (select public.kick_topic_allows((select realtime.topic())))
  );

-- PostgREST: reload the schema cache now (the new RPCs).
notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  to_regclass('public.table_kicks') is not null as table_kicks_table,
  (select c.relrowsecurity from pg_class c where c.oid = to_regclass('public.table_kicks')) as table_kicks_rls_on,
  (select count(*) from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'table_kicks') as table_kicks_policies,
  has_function_privilege('authenticated', 'public.kick_player(uuid, uuid)', 'EXECUTE') as kick_player_for_authenticated,
  has_function_privilege('authenticated', 'public._is_kicked_from_table(uuid, uuid)', 'EXECUTE') as helper_for_authenticated,
  (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages') as realtime_messages_policies,
  (select pg_get_constraintdef(con.oid) ~ '''kick''' from pg_constraint con
   where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check') as attempt_log_allows_kick;
