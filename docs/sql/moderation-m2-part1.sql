-- Moderation, slice M2: BLOCK AND HIDE IN CHAT. PART 1: ADD-ONLY -- block a
-- chat sender by account id. Run in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase
-- CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M2):
--   1. docs/sql/moderation-m2-precheck.sql       (read-only; no STOP rows;
--      state "before part 1")
--   2. docs/sql/moderation-m2-part1.sql          (THIS FILE; nothing calls
--      the new function until the app deploys)
--   3. docs/sql/moderation-m2-verification.sql   ("ALL 17 CHECKS PASSED")
--   4. docs/sql/slice-e-grants-verification.sql  ("ALL 12 CHECKS PASSED",
--      53 names) and docs/sql/moderation-m1-verification.sql ("ALL 34")
--   5. the app (PR): the chat card's "..." menu (Hide / Block), the
--      "Hidden in chat" panel in Settings
--   6. the hand test
--   Rollback: docs/sql/moderation-m2-part1-rollback.sql.
--
-- WHAT WALT DECIDED (M2): a chat card gets a menu with "Hide <name>" and
-- "Block <name>". Hide is personal and browser-only (no SQL). Block adds the
-- sender to the existing Block List (moderation M1) and hides their chat
-- everywhere. From a chat card the app passes the sender's ACCOUNT ID
-- silently: nobody types or sees an id, no email is exposed, and a sender
-- with a blank or look-alike nickname is still the right account. The
-- Profile page keeps blocking by exact nickname (block_player, unchanged).
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold): the four
--      fingerprinted bodies unchanged (leave_table, end_timed_out_sessions,
--      assign_table_seat, table_host; LF or CRLF); M1 is in and unchanged
--      -- block_player, unblock_player, get_my_blocks and
--      _is_blocked_from_table have moderation-m1-part1.sql's bodies,
--      join_table_by_code and watch_table have moderation-m1-part2.sql's,
--      public.blocks exists and attempt_log allows block_change;
--      _attempts_guard is join-create.sql's; block_player_by_id is absent,
--      or exactly this file's signature and body (a re-run).
--   1. public.block_player_by_id(p_target uuid) returns text. The same
--      outcomes, cap, lock and rate limit as block_player -- only the
--      target is given by id instead of found by nickname:
--        not_found        p_target null, or no profile (and account) with
--                         that id; counts nothing
--        not_allowed      yourself, a computer account, or the caller is a
--                         computer account: a plain refusal, counts nothing
--        already_blocked  already on the list: a no-op, counts nothing
--        limit            already 100 on the list: counts nothing
--        blocked          a new row: counts toward block_change
--      and raises (detail rate_limited) on the 31st REAL block/unblock
--      change in an hour, with block_player's message -- the counter is
--      the same attempt_log action, so the two ways of blocking and
--      unblock_player share one limit. A target with a BLANK nickname is
--      blockable (it has a profile). It takes the same advisory lock,
--      'blocks:<caller>', so a block by id, a block by nickname and an
--      unblock can never race past the cap or the limit together.
--      SECURITY DEFINER, search_path ''; EXECUTE for authenticated only
--      (revoked from PUBLIC, anon and service_role explicitly). It acts on
--      auth.uid()'s own list only; nothing about the target is returned.
--
-- md5 of the new body (LF / CRLF, this file as committed):
--   block_player_by_id  c80a2bde62d206edbe1784b84c5d7b3b / 38bd1c6cc89b94eff6e19d7d42d3e3b9
--
-- NOT TOUCHED: every M1 function (block_player, unblock_player,
-- get_my_blocks, _is_blocked_from_table, join_table_by_code, watch_table),
-- public.blocks and its grants, attempt_log and its check, every other body,
-- policy and grant. No function name contains "chat".
--
-- RE-RUNNABLE: create or replace with the same signature; idempotent revokes
-- and grant.
-- ROLLBACK: docs/sql/moderation-m2-part1-rollback.sql (drops the function).

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
  -- The four fingerprinted bodies, M1's two swapped bodies, and the helpers
  -- this file relies on: md5 of the live body, LF or CRLF.
  for v_rec in
    select * from (values
      ('public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa'),
      ('public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c'),
      ('public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb'),
      ('public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d'),
      ('public.join_table_by_code(text, boolean, uuid)', 'cf40593ee5afda235144a13e38d27f4a', 'c3ee9ced2e1033f9c068acd3325c5583'),
      ('public.watch_table(text, uuid)', '5bf6065de215d92a02af63d035c7f910', '2aa5f9c37d65271f3b4619e58c171ea0'),
      ('public._attempts_guard(uuid, text, integer, interval, text)', 'b1b69dbbdf10d50f78655a0da3b3ac69', '9406938991e89dcd38d0686a279b432a')
    ) as t(fn, lf, crlf)
  loop
    select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is null or v_txt not in (v_rec.lf, v_rec.crlf) then
      raise exception 'STOP: % has body md5 %; expected % (LF) or % (CRLF). Capture it first: select pg_get_functiondef(''%''::regprocedure); Nothing was changed.', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf, v_rec.crlf, v_rec.fn;
    end if;
  end loop;

  -- M1's four functions: moderation-m1-part1.sql's bodies (md5 with
  -- carriage returns removed).
  for v_rec in
    select * from (values
      ('public.block_player(text)', '10f6b07a3224aff16e1326daa6af5759'),
      ('public.unblock_player(uuid)', 'c0363d27028d621c0008654506bade75'),
      ('public.get_my_blocks()', '3d50e2a273ca16b23f6d89348016d8de'),
      ('public._is_blocked_from_table(uuid, uuid)', '162f914c3b209186c819c66d18a23a99')
    ) as t(fn, lf)
  loop
    select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is distinct from v_rec.lf then
      raise exception 'STOP: % has body md5 % (carriage returns removed); expected moderation-m1-part1.sql''s %. Nothing was changed.', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf;
    end if;
  end loop;

  if to_regclass('public.blocks') is null then
    raise exception 'STOP: public.blocks is missing: moderation M1 part 1 is not in. Nothing was changed.';
  end if;
  if not exists (select 1 from pg_constraint con
                 where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check'
                   and pg_get_constraintdef(con.oid) ~ '''block_change''') then
    raise exception 'STOP: attempt_log_action_check does not allow block_change: moderation M1 part 1 is not in. Nothing was changed.';
  end if;
  if to_regclass('public.computer_accounts') is null then
    raise exception 'STOP: public.computer_accounts is missing. Nothing was changed.';
  end if;

  -- block_player_by_id: absent, or exactly this file's signature and body.
  select count(*) into v_n
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'block_player_by_id';
  if v_n > 1 or (v_n = 1 and to_regprocedure('public.block_player_by_id(uuid)') is null) then
    raise exception 'STOP: public.block_player_by_id exists with another signature (% function(s) by that name). Nothing was changed.', v_n;
  end if;
  if v_n = 1 then
    select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure('public.block_player_by_id(uuid)');
    if v_txt is distinct from 'c80a2bde62d206edbe1784b84c5d7b3b' then
      raise exception 'STOP: block_player_by_id exists with body md5 % (carriage returns removed), not this file''s c80a2bde62d206edbe1784b84c5d7b3b. Capture it first: select pg_get_functiondef(''public.block_player_by_id(uuid)''::regprocedure); Nothing was changed.', v_txt;
    end if;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. block_player_by_id.
-- ---------------------------------------------------------------------------
create or replace function public.block_player_by_id(p_target uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_count integer;
begin
  if v_actor is null then
    raise exception 'You must be logged in to block a player.';
  end if;

  -- A computer account never blocks anyone.
  if exists (select 1 from public.computer_accounts ca where ca.user_id = v_actor) then
    return 'not_allowed';
  end if;

  if p_target is null then
    return 'not_found';
  end if;

  -- Not yourself: a plain refusal.
  if p_target = v_actor then
    return 'not_allowed';
  end if;

  -- THE ACCOUNT: a profile row (a blank nickname is fine) with an account
  -- behind it. Anything else is not_found.
  if not exists (
    select 1
    from public.profiles p
    join auth.users u on u.id = p.id
    where p.id = p_target
  ) then
    return 'not_found';
  end if;

  -- Not a computer account: a plain refusal.
  if exists (select 1 from public.computer_accounts ca where ca.user_id = p_target) then
    return 'not_allowed';
  end if;

  -- block_player's lock: one blocker at a time, whichever way they block or
  -- unblock, so two quick taps can't both pass the cap or the hourly limit.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('blocks:' || v_actor::text, 0));

  if exists (
    select 1 from public.blocks b
    where b.blocker_id = v_actor and b.blocked_id = p_target
  ) then
    return 'already_blocked';
  end if;

  select count(*) into v_count
  from public.blocks b
  where b.blocker_id = v_actor;

  if v_count >= 100 then
    return 'limit';
  end if;

  -- Only a REAL block counts toward the 30 block/unblock changes an hour --
  -- the same attempt_log action as block_player and unblock_player, so the
  -- three share one limit. Over it: raised, detail rate_limited; nothing is
  -- written.
  perform public._attempts_guard(v_actor, 'block_change', 30, interval '1 hour',
    'You have changed your Block List 30 times in the last hour. Please try again a little later.');

  insert into public.blocks (blocker_id, blocked_id)
  values (v_actor, p_target)
  on conflict do nothing;

  return 'blocked';
end;
$$;

comment on function public.block_player_by_id(uuid) is
  'Moderation M2: the signed-in player adds the account p_target to their own Block List -- the chat card''s Block, which passes the sender''s account id (a blank nickname is fine). Returns blocked, already_blocked, not_found (no such profile/account), not_allowed (yourself, a computer account, or a computer caller) or limit (100 already); raises when nobody is logged in, and on the 31st real block/unblock change in an hour (detail rate_limited; the counter, lock and cap are block_player''s). Returns nothing about the other person. See docs/sql/moderation-m2-part1.sql.';

revoke all on function public.block_player_by_id(uuid) from public;
revoke all on function public.block_player_by_id(uuid) from anon;
revoke all on function public.block_player_by_id(uuid) from service_role;
revoke all on function public.block_player_by_id(uuid) from authenticated;
grant execute on function public.block_player_by_id(uuid) to authenticated;

-- PostgREST: reload the schema cache now (the new RPC).
notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  to_regprocedure('public.block_player_by_id(uuid)') is not null as block_player_by_id_exists,
  has_function_privilege('authenticated', 'public.block_player_by_id(uuid)', 'EXECUTE') as for_authenticated,
  has_function_privilege('anon', 'public.block_player_by_id(uuid)', 'EXECUTE') as for_anon,
  (select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure('public.block_player_by_id(uuid)')) as body_md5_lf;
