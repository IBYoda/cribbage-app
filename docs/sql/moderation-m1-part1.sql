-- Moderation, slice M1: THE BLOCK LIST. PART 1: ADD-ONLY (safe before any
-- app change). Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M1):
--   1. docs/sql/moderation-m1-precheck.sql       (read-only; no STOP rows)
--   2. docs/sql/moderation-m1-part1.sql          (THIS FILE)
--   3. docs/sql/moderation-m1-verification.sql   (it runs only its part-1
--      cases while part 2 is not in: "ALL 19 PART-1 CHECKS PASSED ...")
--      and docs/sql/slice-e-grants-verification.sql (52 names, blocks known)
--   4. the app (PR): the Profile page's Blocked players section, and the
--      plain refusal "You can't join this table." on the join and watch
--      screens; old tabs reload
--   5. docs/sql/moderation-m1-precheck.sql again (state "part 1 present")
--   6. docs/sql/moderation-m1-part2.sql          (the swap: join and watch)
--   7. docs/sql/moderation-m1-verification.sql   ("ALL 34 CHECKS PASSED")
--   8. the regression suites (the list in moderation-m1-part2.sql's header)
--   9. the hand test
--   Rollbacks, newest first: moderation-m1-part2-rollback.sql, then
--   moderation-m1-part1-rollback.sql.
--
-- WHAT WALT DECIDED (M1, final): a Block List under the player's profile, at
-- most 100 people, Unblock on the Profile page, add by EXACT nickname only
-- (no chat menu or kick prompt yet). A blocked person cannot join or watch
-- any table the blocker CREATED (tables.created_by), and is told only "You
-- can't join this table." (part 2). Nobody can learn they are blocked or
-- read anyone's list. 30 block/unblock changes an hour. Computer accounts
-- cannot block or be blocked; nobody can block themselves.
--
-- WHAT THIS FILE DOES (one transaction; nothing here changes what a player
-- can do at a table -- join_table_by_code and watch_table are untouched
-- until part 2):
--   0. GUARD (raises, changing nothing, unless all hold): the four
--      fingerprinted bodies unchanged (leave_table, end_timed_out_sessions,
--      assign_table_seat, table_host; LF or CRLF); join_table_by_code and
--      watch_table are today's (free-codes-part1.sql) or part 2's (a re-run
--      after part 2); attempt_log_action_check allows exactly the seven
--      slice A/E actions, or those plus block_change (a re-run);
--      _attempts_guard is join-create.sql's; the nickname unique index
--      exists (the exact-nickname lookup relies on it); public.blocks absent
--      or with this file's columns (a re-run); the four function names
--      absent or holding exactly this file's signature and body (a re-run).
--   1. attempt_log_action_check also allows 'block_change'. Written only by
--      block_player / unblock_player for a REAL change.
--   2. public.blocks (blocker_id, blocked_id, created_at): primary key
--      (blocker_id, blocked_id) -- it also serves "my list" and the cap
--      count; blocks_not_self (blocker <> blocked); both ids reference
--      auth.users ON DELETE CASCADE (a deleted account's list and every row
--      naming it go with it); blocks_blocked_id_idx for that cascade. RLS
--      ON with NO policies, and ALL privileges revoked from PUBLIC, anon,
--      authenticated and service_role (AGENTS.md "New tables": least
--      privilege -- nothing uses the table but the functions below, which
--      run as their owner). Not added to the supabase_realtime publication.
--   3. Four functions, all SECURITY DEFINER with search_path '', each
--      revoking from PUBLIC itself (the slice E rule; postgres's global
--      default ACL also closes new functions since slice E part 3):
--        block_player(p_nickname text) returns text      authenticated only
--          The signed-in player blocks the account whose nickname matches
--          p_nickname by lower(btrim()) -- the same expression as
--          profiles_nickname_unique_idx, so case and surrounding spaces do
--          not matter and at most one account can match. Outcomes:
--            blocked          a new row (counts toward block_change)
--            already_blocked  already on the list: a no-op, counts nothing
--            not_found        no such nickname (or a blank one): counts
--                             nothing
--            not_allowed      yourself, a computer account, or the caller
--                             is a computer account: a plain refusal (not
--                             a silent no-op), counts nothing
--            limit            already 100 on the list: counts nothing
--          and raises (detail rate_limited) on the 31st real change in an
--          hour: "You have changed your Block List 30 times in the last
--          hour. Please try again a little later." Nothing about the other
--          person is returned (no id, no avatar, no stats).
--        unblock_player(p_target uuid) returns text     authenticated only
--          Removes p_target from the CALLER's list: 'unblocked' (a real
--          change, counted), or 'not_blocked' (not on the list: a quiet
--          no-op, counts nothing). Rate limited the same way.
--        get_my_blocks() returns (user_id, nickname, avatar_url, created_at)
--          The CALLER's list only, newest first.          authenticated only
--        _is_blocked_from_table(p_caller uuid, p_table_id uuid) returns
--          boolean: true when the table's creator (tables.created_by) has
--          p_caller on their list. INTERNAL: no client role can execute it;
--          part 2's join_table_by_code and watch_table call it.
--      block_player and unblock_player take the per-account advisory lock
--      'blocks:<caller>' (the _follow_user_as pattern), so two quick taps
--      cannot both pass the cap or the rate limit; the rate limit is
--      _attempts_guard (action block_change, 30 per rolling hour).
--      There is NO parameter naming whose list to read or change: every
--      function acts on auth.uid()'s own list.
--
-- md5 of the new bodies (carriage returns removed; LF), and with CRLF line
-- ends (this file as committed):
--   block_player            10f6b07a3224aff16e1326daa6af5759 / c742c78f77f58a92e6f38753c84b9f16
--   unblock_player          c0363d27028d621c0008654506bade75 / 279ac52fde07f39491f747656943d84f
--   get_my_blocks           3d50e2a273ca16b23f6d89348016d8de / 687616ef777e677d23b58678e3e3fd1e
--   _is_blocked_from_table  162f914c3b209186c819c66d18a23a99 / 69b02ade7e62cad1ff49c44ae302b805
--
-- NOT TOUCHED: join_table_by_code and watch_table (part 2), every other
-- function body, policy and grant; the four fingerprinted functions,
-- spectator_heartbeat, remove_spectator, chat_topic_allows; the lobby read;
-- chat and Realtime. No function name contains "chat".
--
-- RE-RUNNABLE: the constraint is dropped and re-added with the eight
-- actions; "create table / index if not exists"; "create or replace
-- function"; idempotent revokes and grants.
-- ROLLBACK: docs/sql/moderation-m1-part1-rollback.sql (only after part 2 is
-- rolled back or was never run: part 2 calls _is_blocked_from_table).

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
  -- The four fingerprinted bodies, unchanged (LF or CRLF).
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

  -- join_table_by_code and watch_table: today's (free-codes-part1.sql) or
  -- M1 part 2's (LF or CRLF each).
  for v_rec in
    select * from (values
      ('public.join_table_by_code(text, boolean, uuid)', '1a2ff167c6d09fef6acd17177493422d', '9f3cee04a063447d626a1354533fda51', 'cf40593ee5afda235144a13e38d27f4a', 'c3ee9ced2e1033f9c068acd3325c5583'),
      ('public.watch_table(text, uuid)', '43775b57dffaec98ee7c003304a0c951', 'df591fa16528afd81a13bfdc3e975538', '5bf6065de215d92a02af63d035c7f910', '2aa5f9c37d65271f3b4619e58c171ea0')
    ) as t(fn, lf, crlf, m1_lf, m1_crlf)
  loop
    select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is null or v_txt not in (v_rec.lf, v_rec.crlf, v_rec.m1_lf, v_rec.m1_crlf) then
      raise exception 'STOP: % has body md5 %; expected today''s % / % or M1 part 2''s % / %. Capture it first: select pg_get_functiondef(''%''::regprocedure); Nothing was changed.', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf, v_rec.crlf, v_rec.m1_lf, v_rec.m1_crlf, v_rec.fn;
    end if;
  end loop;

  -- The attempt_log check: the seven slice A/E actions, or those plus
  -- block_change (a re-run).
  select pg_get_constraintdef(con.oid) into v_txt
  from pg_constraint con
  where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check';
  if v_txt is null
     or v_txt !~ '''create_table''' or v_txt !~ '''create_computer_table''' or v_txt !~ '''join'''
     or v_txt !~ '''watch''' or v_txt !~ '''code_guess''' or v_txt !~ '''game_start''' or v_txt !~ '''follow_change'''
     or (length(v_txt) - length(replace(v_txt, '::text', ''))) / 6 not in (7, 8)
     or ((length(v_txt) - length(replace(v_txt, '::text', ''))) / 6 = 8 and v_txt !~ '''block_change''') then
    raise exception 'STOP: attempt_log_action_check is "%"; expected exactly create_table, create_computer_table, join, watch, code_guess, game_start, follow_change (or those plus block_change on a re-run). Nothing was changed.', coalesce(v_txt, 'missing');
  end if;

  -- _attempts_guard: join-create.sql's body (the rate limit below uses it).
  select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure('public._attempts_guard(uuid, text, integer, interval, text)');
  if v_txt is null or v_txt not in ('b1b69dbbdf10d50f78655a0da3b3ac69', '9406938991e89dcd38d0686a279b432a') then
    raise exception 'STOP: _attempts_guard has body md5 %; expected join-create.sql''s b1b69dbbdf10d50f78655a0da3b3ac69 (LF) or 9406938991e89dcd38d0686a279b432a (CRLF). Nothing was changed.', coalesce(v_txt, 'missing');
  end if;

  -- The nickname unique index: at most one account per lower(btrim()) name.
  select pg_get_indexdef(i.indexrelid) into v_txt
  from pg_index i
  where i.indexrelid = to_regclass('public.profiles_nickname_unique_idx');
  if v_txt is null or not (select i.indisunique and i.indisvalid from pg_index i where i.indexrelid = to_regclass('public.profiles_nickname_unique_idx'))
     or v_txt !~* 'lower\(btrim\(nickname\)\)' then
    raise exception 'STOP: profiles_nickname_unique_idx is "%"; expected a valid unique index on lower(btrim(nickname)). Blocking by exact nickname relies on it. Nothing was changed.', coalesce(v_txt, 'missing');
  end if;

  if to_regclass('public.computer_accounts') is null then
    raise exception 'STOP: public.computer_accounts is missing. Nothing was changed.';
  end if;

  -- public.blocks: absent, or this file's three columns (a re-run).
  if to_regclass('public.blocks') is not null then
    select string_agg(a.attname::text || ' ' || format_type(a.atttypid, a.atttypmod), ', ' order by a.attnum) into v_txt
    from pg_attribute a
    where a.attrelid = 'public.blocks'::regclass and a.attnum > 0 and not a.attisdropped;
    if v_txt is distinct from 'blocker_id uuid, blocked_id uuid, created_at timestamp with time zone' then
      raise exception 'STOP: public.blocks exists with columns "%"; expected blocker_id uuid, blocked_id uuid, created_at timestamptz (or no table). Nothing was changed.', v_txt;
    end if;
  end if;

  -- The four function names: absent, or exactly this file's signature and
  -- body (a re-run). md5 with carriage returns removed.
  for v_rec in
    select * from (values
      ('block_player', 'public.block_player(text)', '10f6b07a3224aff16e1326daa6af5759'),
      ('unblock_player', 'public.unblock_player(uuid)', 'c0363d27028d621c0008654506bade75'),
      ('get_my_blocks', 'public.get_my_blocks()', '3d50e2a273ca16b23f6d89348016d8de'),
      ('_is_blocked_from_table', 'public._is_blocked_from_table(uuid, uuid)', '162f914c3b209186c819c66d18a23a99')
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
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The new attempt_log action.
-- ---------------------------------------------------------------------------
alter table public.attempt_log drop constraint attempt_log_action_check;
alter table public.attempt_log
  add constraint attempt_log_action_check
  check (action in ('create_table', 'create_computer_table', 'join', 'watch', 'code_guess',
                    'game_start', 'follow_change', 'block_change'));

comment on table public.attempt_log is
  'Rate limits (step 3, slices A and E; moderation M1): one row per counted action -- a table created (create_table), a computer game started (create_computer_table), a join, a new watch, a game started (game_start), a real follow or unfollow (follow_change), a real block or unblock (block_change) (success true), or a wrong table code (code_guess, success false). Read and written only by security definer functions through the _attempts_* / _code_guess* helpers. Rows older than 7 days are deleted hourly by cleanup_attempt_log() (pg_cron job attempt-log-cleanup). RLS on, no policies, no grants. See docs/sql/join-create.sql, slice-e-part1.sql and moderation-m1-part1.sql.';

-- ---------------------------------------------------------------------------
-- 2. public.blocks (AGENTS.md "New tables": the template's order -- table,
--    comment, RLS on, revokes, grants (none), policies (none)).
-- ---------------------------------------------------------------------------
create table if not exists public.blocks (
  blocker_id uuid not null references auth.users (id) on delete cascade,
  blocked_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint blocks_not_self check (blocker_id <> blocked_id)
);

-- The primary key serves the blocker's list, the cap count and the lookup
-- join/watch make (blocker = the table's creator, blocked = the caller).
-- This one serves the cascade when a BLOCKED account is deleted.
create index if not exists blocks_blocked_id_idx on public.blocks (blocked_id);

comment on table public.blocks is
  'Moderation M1: each player''s Block List (blocker_id blocks blocked_id), at most 100 per blocker. A blocked person cannot join or watch any table the blocker created (join_table_by_code / watch_table, moderation-m1-part2.sql) and is only told "You can''t join this table.". PRIVATE: no client role has any privilege on it and RLS is on with no policies; written and read only through block_player, unblock_player, get_my_blocks and _is_blocked_from_table (security definer). Nobody can read who blocked them. See docs/sql/moderation-m1-part1.sql.';

-- Row-level security on, with NO policies: deny by default.
alter table public.blocks enable row level security;

-- No privileges for any client role (least privilege: the app never touches
-- the table directly). Revoking everything also removes anything the
-- project's default privileges gave the table when it was created.
-- service_role too: nothing needs it.
revoke all on table public.blocks from public;
revoke all on table public.blocks from anon;
revoke all on table public.blocks from authenticated;
revoke all on table public.blocks from service_role;

-- No grants and no policies: deliberately none. No Realtime: deliberately
-- not added to the supabase_realtime publication.

-- ---------------------------------------------------------------------------
-- 3. The functions.
-- ---------------------------------------------------------------------------
create or replace function public._is_blocked_from_table(p_caller uuid, p_table_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- True when the table's CREATOR has p_caller on their Block List. Only
  -- the creator's list counts (Walt's rule): not the host's, not another
  -- seated player's. A null caller or an unknown table is never blocked.
  select exists (
    select 1
    from public.tables t
    join public.blocks b on b.blocker_id = t.created_by
    where t.id = p_table_id
      and b.blocked_id = p_caller
  );
$$;

comment on function public._is_blocked_from_table(uuid, uuid) is
  'Internal (moderation M1): true when the creator (tables.created_by) of p_table_id has p_caller on their Block List. Called by join_table_by_code and watch_table (moderation-m1-part2.sql). No client role can execute it. See docs/sql/moderation-m1-part1.sql.';

revoke all on function public._is_blocked_from_table(uuid, uuid) from public;
revoke all on function public._is_blocked_from_table(uuid, uuid) from anon;
revoke all on function public._is_blocked_from_table(uuid, uuid) from authenticated;
revoke all on function public._is_blocked_from_table(uuid, uuid) from service_role;


create or replace function public.block_player(p_nickname text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_name text := lower(btrim(coalesce(p_nickname, '')));
  v_target uuid;
  v_matches integer;
  v_count integer;
begin
  if v_actor is null then
    raise exception 'You must be logged in to block a player.';
  end if;

  -- A computer account never blocks anyone.
  if exists (select 1 from public.computer_accounts ca where ca.user_id = v_actor) then
    return 'not_allowed';
  end if;

  if v_name = '' then
    return 'not_found';
  end if;

  -- THE EXACT NICKNAME: the unique index's own expression (lower(btrim())),
  -- so case and surrounding spaces don't matter and at most one account can
  -- match. Blank nicknames are never matched (the index exempts them).
  select count(*), min(p.id::text)::uuid
  into v_matches, v_target
  from public.profiles p
  where lower(btrim(p.nickname)) = v_name
    and btrim(p.nickname) <> '';

  if v_matches <> 1 then
    return 'not_found';
  end if;

  -- Not yourself, not a computer account: a plain refusal.
  if v_target = v_actor
     or exists (select 1 from public.computer_accounts ca where ca.user_id = v_target) then
    return 'not_allowed';
  end if;

  -- One blocker at a time (until this transaction ends), so two quick taps
  -- can't both see 99 and both insert, or both pass the hourly limit.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('blocks:' || v_actor::text, 0));

  if exists (
    select 1 from public.blocks b
    where b.blocker_id = v_actor and b.blocked_id = v_target
  ) then
    return 'already_blocked';
  end if;

  select count(*) into v_count
  from public.blocks b
  where b.blocker_id = v_actor;

  if v_count >= 100 then
    return 'limit';
  end if;

  -- Only a REAL block counts toward 30 block/unblock changes an hour (the
  -- no-ops and refusals above returned first). Over it: raised, detail
  -- rate_limited; nothing is written.
  perform public._attempts_guard(v_actor, 'block_change', 30, interval '1 hour',
    'You have changed your Block List 30 times in the last hour. Please try again a little later.');

  insert into public.blocks (blocker_id, blocked_id)
  values (v_actor, v_target)
  on conflict do nothing;

  return 'blocked';
end;
$$;

comment on function public.block_player(text) is
  'Moderation M1: the signed-in player adds the account whose nickname matches p_nickname (lower(btrim()), the unique index''s expression) to their own Block List. Returns blocked, already_blocked, not_found, not_allowed (yourself, a computer account, or a computer caller) or limit (100 already); raises when nobody is logged in, and on the 31st real block/unblock change in an hour (detail rate_limited). Returns nothing about the other person. See docs/sql/moderation-m1-part1.sql.';

revoke all on function public.block_player(text) from public;
revoke all on function public.block_player(text) from anon;
revoke all on function public.block_player(text) from service_role;
revoke all on function public.block_player(text) from authenticated;
grant execute on function public.block_player(text) to authenticated;


create or replace function public.unblock_player(p_target uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception 'You must be logged in to unblock a player.';
  end if;

  -- The same lock as block_player; only a REAL unblock -- a row that is
  -- there -- counts toward the 30 changes an hour. Unblocking someone not
  -- on the list is a quiet no-op that counts nothing.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('blocks:' || v_actor::text, 0));

  if exists (
    select 1 from public.blocks b
    where b.blocker_id = v_actor and b.blocked_id = p_target
  ) then
    perform public._attempts_guard(v_actor, 'block_change', 30, interval '1 hour',
      'You have changed your Block List 30 times in the last hour. Please try again a little later.');

    delete from public.blocks b
    where b.blocker_id = v_actor
      and b.blocked_id = p_target;

    return 'unblocked';
  end if;

  return 'not_blocked';
end;
$$;

comment on function public.unblock_player(uuid) is
  'Moderation M1: removes p_target from the signed-in player''s OWN Block List. Returns unblocked (a real change, counted toward 30 an hour; over it: raised, detail rate_limited) or not_blocked (a no-op, counts nothing). Raises when nobody is logged in. See docs/sql/moderation-m1-part1.sql.';

revoke all on function public.unblock_player(uuid) from public;
revoke all on function public.unblock_player(uuid) from anon;
revoke all on function public.unblock_player(uuid) from service_role;
revoke all on function public.unblock_player(uuid) from authenticated;
grant execute on function public.unblock_player(uuid) to authenticated;


create or replace function public.get_my_blocks()
returns table (user_id uuid, nickname text, avatar_url text, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select b.blocked_id, p.nickname, p.avatar_url, b.created_at
  from public.blocks b
  left join public.profiles p on p.id = b.blocked_id
  where b.blocker_id = auth.uid()
  order by b.created_at desc, b.blocked_id;
$$;

comment on function public.get_my_blocks() is
  'Moderation M1: the signed-in player''s OWN Block List (user_id, nickname, avatar_url, created_at), newest first. No rows when nobody is logged in. No function returns anyone else''s list or who blocked a player. See docs/sql/moderation-m1-part1.sql.';

revoke all on function public.get_my_blocks() from public;
revoke all on function public.get_my_blocks() from anon;
revoke all on function public.get_my_blocks() from service_role;
revoke all on function public.get_my_blocks() from authenticated;
grant execute on function public.get_my_blocks() to authenticated;

-- PostgREST: reload the schema cache now (the three new RPCs).
notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  to_regclass('public.blocks') is not null as blocks_table,
  (select c.relrowsecurity from pg_class c where c.oid = to_regclass('public.blocks')) as blocks_rls_on,
  (select count(*) from pg_policies pol where pol.schemaname = 'public' and pol.tablename = 'blocks') as blocks_policies,
  has_function_privilege('authenticated', 'public.block_player(text)', 'EXECUTE') as block_player_for_authenticated,
  has_function_privilege('authenticated', 'public._is_blocked_from_table(uuid, uuid)', 'EXECUTE') as helper_for_authenticated,
  (select pg_get_constraintdef(con.oid) ~ '''block_change''' from pg_constraint con
   where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check') as attempt_log_allows_block_change;
