-- Moderation, slice M3: KICK. PART 2: THE SWAP -- join and watch refuse a
-- kicked person. Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M3):
--   1. docs/sql/moderation-m3-precheck.sql       (read-only; no STOP rows)
--   2. docs/sql/moderation-m3-part1.sql          (add-only)
--   3. docs/sql/moderation-m3-verification.sql   (part-1 mode) and
--      slice-e-grants-verification.sql
--   4. the app (PR); old tabs reload
--   5. docs/sql/moderation-m3-precheck.sql again (state "part 1 present")
--   6. docs/sql/moderation-m3-part2.sql          (THIS FILE)
--   7. docs/sql/moderation-m3-verification.sql   (full mode)
--   8. the regression suites below
--   9. the hand test
--   Rollbacks, newest first: moderation-m3-part2-rollback.sql, then
--   moderation-m3-part1-rollback.sql.
--
-- WHEN: after part 1 AND after the M3 app is live (it already maps "You
-- can't join this table." -- M1's refusal -- to its plain screen; an old
-- tab shows the same, so nothing leaks either way).
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold): the four
--      fingerprinted bodies unchanged; spectator_heartbeat, remove_spectator
--      and chat_topic_allows unchanged; join_table_by_code and watch_table
--      are M1 part 2's or this file's (a re-run); part 1 is in
--      (public.table_kicks, _is_kicked_from_table with part 1's body, kick
--      allowed in attempt_log).
--   1. join_table_by_code(p_code, p_preview, p_table_id): M1 part 2's body,
--      byte for byte, plus ONE branch marked (M3), right after "already
--      seated" and before M1's Block List branch. Once the table is FOUND
--      and the caller is NOT seated there, a caller KICKED from this table
--      (table_kicks), or with a REMOVED spectator row there (a kick's or
--      remove_spectator's), is refused:
--        raise exception 'You can''t join this table.';
--      -- SQLSTATE P0001, no DETAIL, no HINT: exactly M1's refusal, before
--      the preview row, the host's name, the seat count, the one-table
--      rule, the hourly join limit and the seat. An exception undoes
--      everything, so it is NOT counted (not a wrong code, not a join).
--      Covers every join path: the typed code, the ?t= link, Open Tables,
--      Rejoin and the preview behind both confirm screens. (The removed-row
--      clause closes the old gap: before M3, a spectator removed by the
--      host could still take a free seat with the code.)
--   2. watch_table(p_code, p_table_id): M1 part 2's body, byte for byte,
--      plus ONE block marked (M3), right after the table is found and
--      locked, before M1's block and every other check: a KICKED caller
--      gets the same plain refusal, standing or not. Someone removed only by
--      remove_spectator (no kick row) falls through to today's rules and
--      still hears "You were removed from watching this table." (so
--      spectators-join-or-watch-verification's W4 and M1's J11 stand).
--   The grants are restated exactly (authenticated only). Both functions
--   keep their signatures, so the app's calls are unchanged.
--
-- md5 of the new bodies (LF / CRLF):
--   join_table_by_code  297fa4f04a02e226691ebf3b5b135f83 / fbf046f1582863cc5697b06f670481b2
--   watch_table         bdebb2e1a8213baa2a04666bcad59adb / ea5c3bd739b2f7243b985c7ea1fd9f2a
--
-- NOT CHANGED: leave_table, end_timed_out_sessions, assign_table_seat,
-- table_host (fingerprinted), spectator_heartbeat, remove_spectator,
-- stop_watching, chat_topic_allows, _one_table_rule, _code_guesses_check,
-- _code_guess_failed, _attempts_guard, _is_blocked_from_table, the eight
-- game functions and their _as bodies, every policy and table grant.
--
-- REGRESSION SUITES to re-run after this file (expected verdicts):
--   moderation-m3-verification.sql        ALL 26 CHECKS PASSED
--   moderation-m1-verification.sql        ALL 34 CHECKS PASSED (it accepts
--                                         M3's join/watch as part 2 mode)
--   moderation-m2-verification.sql        ALL 17 CHECKS PASSED
--   slice-e-grants-verification.sql       ALL 12 CHECKS PASSED (56 names)
--   slice-e-attempt-log-cleanup-verif.    ALL 5 (K3: nine actions)
--   join-create-verification.sql          ALL 47
--   free-codes-verification.sql           ALL 27
--   spectators-join-or-watch-verification ALL 32
--   spectator-chat-verification.sql       ALL 74 (other policies: 0, plus
--                                         M3's kicks policy)
--   table-chat-verification.sql           as before (the same note)
--   end-empty-tables-verification.sql     ALL 24
--   private-tables-verification.sql       ALL 21
--   computer-c1-verification.sql          ALL 120
--   computer-c2-verification.sql          ALL 81
--   None of the older ones kicks anyone, so their counts are unchanged.
--
-- RE-RUNNABLE: create or replace with the same signatures.
-- ROLLBACK: docs/sql/moderation-m3-part2-rollback.sql (restores M1 part 2's
-- bodies byte for byte and their comments).

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard.
-- ---------------------------------------------------------------------------
do $$
declare
  v_rec record;
  v_txt text;
begin
  -- The four fingerprinted bodies, unchanged (LF or CRLF), and the three
  -- spectator/chat bodies this file must not touch.
  for v_rec in
    select * from (values
      ('public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa'),
      ('public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c'),
      ('public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb'),
      ('public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d'),
      ('public.spectator_heartbeat(uuid)', '41d2ea0e865c2a9d5fa7203875a27ace', '6b7c271d78eb4f72c1aff3c851b578e1'),
      ('public.remove_spectator(uuid, uuid)', 'dafa688f1b8c194e4be575cd0625ba12', '9786b9a5e50245365a2598b18da5892e'),
      ('public.chat_topic_allows(text, boolean)', '0458d5122d68d511b2e0fbceafe84aae', 'c4e6eda360de7d7723c4069e60d95345')
    ) as t(fn, lf, crlf)
  loop
    select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is null or v_txt not in (v_rec.lf, v_rec.crlf) then
      raise exception 'STOP: % has body md5 %; expected % (LF) or % (CRLF). Nothing was changed.', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf, v_rec.crlf;
    end if;
  end loop;

  -- The two bodies this file replaces: M1 part 2's or this file's.
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

  -- Part 1 is in.
  if to_regclass('public.table_kicks') is null then
    raise exception 'STOP: public.table_kicks is missing. Run docs/sql/moderation-m3-part1.sql first. Nothing was changed.';
  end if;
  select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure('public._is_kicked_from_table(uuid, uuid)');
  if v_txt is distinct from 'c8372af51a4537ca9cc079234487a414' then
    raise exception 'STOP: _is_kicked_from_table has body md5 % (carriage returns removed); expected part 1''s c8372af51a4537ca9cc079234487a414. Run docs/sql/moderation-m3-part1.sql first. Nothing was changed.', coalesce(v_txt, 'missing');
  end if;
  if not exists (select 1 from pg_constraint con
                 where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check'
                   and pg_get_constraintdef(con.oid) ~ '''kick''') then
    raise exception 'STOP: attempt_log_action_check does not allow kick. Run docs/sql/moderation-m3-part1.sql first. Nothing was changed.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. join_table_by_code: refuse a kicked (or removed) caller once the table
--    is found.
-- ---------------------------------------------------------------------------
-- M1 part 2's body (moderation-m1-part2.sql), plus the (M3) branch.
create or replace function public.join_table_by_code(
  p_code text,
  p_preview boolean default false,
  p_table_id uuid default null
)
returns table (
  outcome text,
  table_id uuid,
  code text,
  status text,
  ended_reason text,
  is_public boolean,
  is_muggins boolean,
  allow_spectators boolean,
  created_by uuid,
  max_players smallint,
  team_mode text,
  computer_level text,
  seat smallint,
  seated_count integer,
  game_live boolean,
  game_id uuid,
  host_nickname text,
  host_avatar_url text
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_caller uuid := auth.uid();
  v_t record;
  v_seat smallint;
  v_outcome text;
  v_game uuid;
begin
  if v_caller is null then
    raise exception 'You must be logged in to join a table.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('one_table:' || v_caller::text, 0));
  perform public._code_guesses_check(v_caller);

  select t.id, t.code, t.status, t.ended_reason, t.is_public, t.is_muggins, t.allow_spectators,
         t.created_by, t.max_players, t.team_mode, t.computer_level
  into v_t
  from public.tables t
  where p_code ~ '^[0-9]{4}$'
    and t.code = p_code
    and t.status <> 'ended'
    -- Slice B: with the id the app already holds, only THAT table: a code
    -- now held by a different table never answers for it.
    and (p_table_id is null or t.id = p_table_id)
  order by t.created_at desc
  limit 1;

  if not found then
    -- Returned, not raised (an exception would undo the count). A bare code
    -- that matches no open table is a wrong guess and is counted; with
    -- p_table_id it is the app's own table that has ended (or whose code
    -- now belongs to another table), which is NOT counted.
    if p_table_id is null then
      perform public._code_guess_failed(v_caller);
    end if;
    outcome := 'not_found';
    return next;
    return;
  end if;

  select tm.seat
  into v_seat
  from public.table_members tm
  where tm.table_id = v_t.id
    and tm.user_id = v_caller;

  if found then
    v_outcome := 'already_seated';
  -- ===== (M3) CHANGED FOR MODERATION M3, KICK (start) =====
  -- The table is found and the caller is not seated there: someone KICKED
  -- from this table (public.table_kicks), or removed from watching it (a
  -- removed spectator row -- a kick's, or remove_spectator's), is refused
  -- here: the same plain refusal as the Block List's (P0001, no detail, no
  -- hint), before it and before anything about the table is returned.
  -- Raised, so nothing is counted (not a wrong code, not a join). Someone
  -- seated is never refused here (the branch above); a kick deletes the
  -- seat in the same transaction, so a kicked person is never seated.
  elsif public._is_kicked_from_table(v_caller, v_t.id)
        or exists (
          select 1
          from public.table_spectators ts
          where ts.table_id = v_t.id
            and ts.user_id = v_caller
            and ts.removed_at is not null
        ) then
    raise exception 'You can''t join this table.';
  -- ===== (M3) CHANGED FOR MODERATION M3, KICK (end) =====
  -- ===== (M1) CHANGED FOR MODERATION M1, THE BLOCK LIST (start) =====
  -- The table is found and the caller is not seated there: someone on the
  -- table CREATOR's Block List is refused here, before the preview row, the
  -- host's name and avatar, the one-table rule, the hourly join limit or a
  -- seat. A plain refusal (P0001, no detail, no hint), the same shape as
  -- "This table is full."; never says why. Raised, so nothing is counted
  -- (not a wrong code, not a join). Someone already seated is never refused
  -- (the branch above): a block does not remove anyone.
  elsif public._is_blocked_from_table(v_caller, v_t.id) then
    raise exception 'You can''t join this table.';
  -- ===== (M1) CHANGED FOR MODERATION M1, THE BLOCK LIST (end) =====
  elsif p_preview then
    perform public._one_table_rule(v_caller, v_t.id, false);
    v_outcome := 'preview';
  else
    perform public._one_table_rule(v_caller, v_t.id, true);
    perform public._attempts_guard(v_caller, 'join', 30, interval '1 hour',
      'You can join at most 30 tables an hour. Please try again later.');

    -- Through the seat trigger: full tables refused as today.
    insert into public.table_members (table_id, user_id)
    values (v_t.id, v_caller)
    returning table_members.seat into v_seat;

    -- A player now: their own watching of this table ends (unless removed).
    delete from public.table_spectators ts
    where ts.table_id = v_t.id
      and ts.user_id = v_caller
      and ts.removed_at is null;

    v_outcome := 'joined';
  end if;

  select g.id
  into v_game
  from public.games g
  where g.table_id = v_t.id
    and g.status in ('cutting', 'active')
  order by g.created_at desc
  limit 1;

  outcome := v_outcome;
  table_id := v_t.id;
  code := v_t.code;
  status := v_t.status;
  ended_reason := v_t.ended_reason;
  is_public := v_t.is_public;
  is_muggins := v_t.is_muggins;
  allow_spectators := v_t.allow_spectators;
  created_by := v_t.created_by;
  max_players := v_t.max_players;
  team_mode := v_t.team_mode;
  computer_level := v_t.computer_level;
  seat := v_seat;
  select count(*)::integer into seated_count from public.table_members tm where tm.table_id = v_t.id;
  game_id := v_game;
  game_live := v_game is not null;
  select p.nickname, p.avatar_url into host_nickname, host_avatar_url
  from public.profiles p
  where p.id = public.table_host(v_t.id);
  return next;
end;
$$;

comment on function public.join_table_by_code(text, boolean, uuid) is
  'Join by code (step 3, slices A and B; moderation M1 and M3): seats the caller at the non-ended table with this code -- with p_table_id, only if it is still that table -- or, with p_preview, only describes it (the confirm screens use the preview: it seats nobody, ends nothing and is not counted toward the joins an hour). One row: outcome joined / already_seated / preview / not_found, the table (TableView''s TableRow columns plus is_public), the seat, seated_count, the live game, the host''s nickname and avatar. A bare code that matches nothing counts toward the wrong-code lockout; a p_table_id mismatch does not. A caller on the table creator''s Block List who is not already seated there is refused "You can''t join this table." before anything about the table is returned, and is not counted (M1). So is anyone kicked from this table, or removed from watching it, who is not seated there (M3). One table at a time (DETAIL already_at_table), 30 joins an hour (rate_limited), 5 wrong codes in 10 minutes lock for 15 (locked_out); a full table is refused by the seat trigger. See docs/sql/join-create.sql, free-codes-part1.sql, moderation-m1-part2.sql and moderation-m3-part2.sql.';

revoke all on function public.join_table_by_code(text, boolean, uuid) from public;
revoke all on function public.join_table_by_code(text, boolean, uuid) from anon;
revoke all on function public.join_table_by_code(text, boolean, uuid) from service_role;
grant execute on function public.join_table_by_code(text, boolean, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. watch_table: refuse a kicked caller once the table is found.
-- ---------------------------------------------------------------------------
-- M1 part 2's body (moderation-m1-part2.sql), plus the (M3) block.
create or replace function public.watch_table(
  p_code text,
  p_table_id uuid default null
)
returns table (table_id uuid, code text, game_id uuid)
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_caller uuid := auth.uid();
  v_table record;
  v_game_id uuid;
  v_removed_at timestamptz;
  v_current int;
begin
  if v_caller is null then
    raise exception 'You must be logged in to watch a table.';
  end if;

  -- (J1) One person, one table: this person's actions are serialized (the
  -- person's lock is always taken before a table's).
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('one_table:' || v_caller::text, 0));

  -- (J2) The wrong-code lockout (shared with join_table_by_code).
  perform public._code_guesses_check(v_caller);

  -- THE ROW LOCK, the same one assign_table_seat (joining), set_seat and
  -- start_game_with_deal take: two watchers are serialized here, so the
  -- count below is final until this transaction ends.
  -- (B1) Only a NON-ENDED table with this code (slice B: an ended table's
  -- code may belong to another table soon) -- and, with p_table_id, only if
  -- it is still that table.
  select t.id, t.code, t.status, t.allow_spectators, t.computer_level
  into v_table
  from public.tables t
  where t.code = p_code
    and t.status <> 'ended'
    and (p_table_id is null or t.id = p_table_id)
  order by t.created_at desc
  limit 1
  for no key update;

  if not found then
    -- (J4, B2) NO ROW, never an exception (it would roll the count back). A
    -- bare code that matches no open table -- wrong, unknown or ended: "no
    -- such table" -- is counted toward the wrong-code lockout; with
    -- p_table_id it is the spectator's own table that has ended (or whose
    -- code moved on), which is NOT counted: the watch page shows it closed.
    if p_table_id is null then
      perform public._code_guess_failed(v_caller);
    end if;
    return;
  end if;

  -- ===== (M3) CHANGED FOR MODERATION M3, KICK (start) =====
  -- The table is found (and locked): someone KICKED from it is refused
  -- before every other check, standing or not -- the plain refusal (P0001,
  -- no detail, no hint), never why. Raised, so nothing is counted. Someone
  -- removed only by remove_spectator (no kick) falls through and still
  -- hears "You were removed from watching this table.".
  if public._is_kicked_from_table(v_caller, v_table.id) then
    raise exception 'You can''t join this table.';
  end if;
  -- ===== (M3) CHANGED FOR MODERATION M3, KICK (end) =====

  -- ===== (M1) CHANGED FOR MODERATION M1, THE BLOCK LIST (start) =====
  -- The table is found: someone on the table CREATOR's Block List who has
  -- no standing here -- no spectator row of theirs at this table (current,
  -- stale or removed) and no seat -- is refused before every other check,
  -- the one-table rule, the cap, the hourly watch limit and the spectator
  -- row. A plain refusal (P0001, no detail, no hint); never says why.
  -- Raised, so nothing is counted. Anyone with standing falls through to
  -- the rules below unchanged: a block does not remove a watcher (their
  -- refresh and spectator_heartbeat go on), a removed watcher still hears
  -- they were removed, a seated player still hears they are seated.
  if public._is_blocked_from_table(v_caller, v_table.id)
     and not exists (
       select 1
       from public.table_spectators ts
       where ts.table_id = v_table.id
         and ts.user_id = v_caller
     )
     and not exists (
       select 1
       from public.table_members tm
       where tm.table_id = v_table.id
         and tm.user_id = v_caller
     ) then
    raise exception 'You can''t join this table.';
  end if;
  -- ===== (M1) CHANGED FOR MODERATION M1, THE BLOCK LIST (end) =====

  if v_table.status is distinct from 'open' then
    raise exception 'This table has ended.';
  end if;

  -- Before allow_spectators, so a computer table gets its own message (the
  -- check constraint means it can never allow spectators anyway).
  if v_table.computer_level is not null then
    raise exception 'Computer tables cannot be watched.';
  end if;

  if not v_table.allow_spectators then
    raise exception 'This table does not allow spectators.';
  end if;

  -- A LIVE game, if there is one: the cut for deal or a game being played.
  -- NULL is fine now: the table is in its waiting room (or between games).
  select g.id
  into v_game_id
  from public.games g
  where g.table_id = v_table.id
    and g.status in ('cutting', 'active')
  order by g.created_at desc
  limit 1;

  if exists (
    select 1
    from public.table_members tm
    where tm.table_id = v_table.id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are seated at this table.';
  end if;

  -- (J5) An unfinished single-player game elsewhere ends quietly (as Leave
  -- does). Seated at ANOTHER non-ended table with other humans: refused,
  -- naming it. Watching any
  -- other table ends (a refusal below rolls that back too).
  perform public._one_table_rule(v_caller, v_table.id, true);

  select ts.removed_at
  into v_removed_at
  from public.table_spectators ts
  where ts.table_id = v_table.id
    and ts.user_id = v_caller;

  if v_removed_at is not null then
    raise exception 'You were removed from watching this table.';
  end if;

  -- THE CAP: 4 current spectators besides the caller (an already-current
  -- caller refreshing their place is never refused).
  select count(*)
  into v_current
  from public.table_spectators ts
  where ts.table_id = v_table.id
    and ts.user_id <> v_caller
    and ts.removed_at is null
    and ts.last_seen_at > now() - interval '90 seconds';

  if v_current >= 4 then
    raise exception 'Spectators full: this table already has 4 spectators.';
  end if;

  -- (J6) A NEW watch (no row of theirs at this table yet) counts toward 30
  -- an hour; refreshing a place they already have does not.
  if not exists (
    select 1
    from public.table_spectators ts
    where ts.table_id = v_table.id
      and ts.user_id = v_caller
  ) then
    perform public._attempts_guard(v_caller, 'watch', 30, interval '1 hour',
      'You can start watching at most 30 tables an hour. Please try again later.');
  end if;

  -- Insert, or refresh a row that is there (removed_at is null: checked
  -- above; the update never touches removed_at, so a removal that lands
  -- meanwhile still stands).
  insert into public.table_spectators as ts (table_id, user_id, joined_at, last_seen_at)
  values (v_table.id, v_caller, now(), now())
  on conflict on constraint table_spectators_pkey
  do update set last_seen_at = excluded.last_seen_at;

  table_id := v_table.id;
  code := v_table.code;
  game_id := v_game_id;   -- null while no game is live
  return next;
end;
$$;

comment on function public.watch_table(text, uuid) is
  'Spectator seat (PRD item 40, step 3 slices A and B; moderation M1 and M3): become or stay a spectator of the NON-ENDED table with this code -- with p_table_id, only if it is still that table -- whether or not a game is live. Refused with a message when not allowed: one table at a time (DETAIL already_at_table; watching another table ends), 30 new watches an hour (rate_limited), the wrong-code lockout (locked_out). A caller on the table creator''s Block List with no spectator row and no seat there is refused "You can''t join this table." before any other check, and is not counted (M1). Anyone kicked from this table is refused the same way before any other check (M3). No such open table returns NO row: counted as a wrong code for a bare code, not counted with p_table_id. Returns the table id, code and the live game id (null in the waiting room or between games).';

revoke all on function public.watch_table(text, uuid) from public;
revoke all on function public.watch_table(text, uuid) from anon;
revoke all on function public.watch_table(text, uuid) from service_role;
grant execute on function public.watch_table(text, uuid) to authenticated;

-- PostgREST: reload the schema cache now.
notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.join_table_by_code(text, boolean, uuid)')) as join_table_by_code_md5,
  (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.watch_table(text, uuid)')) as watch_table_md5,
  has_function_privilege('authenticated', 'public.join_table_by_code(text, boolean, uuid)', 'EXECUTE') as join_for_authenticated,
  has_function_privilege('authenticated', 'public.watch_table(text, uuid)', 'EXECUTE') as watch_for_authenticated;
