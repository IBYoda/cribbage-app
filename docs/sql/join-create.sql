-- Step 3, slice A: server-side create and join, and ONE TABLE AT A TIME.
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- RUN ORDER:
--   1. docs/sql/join-create-precheck.sql       (read-only; one result)
--   2. docs/sql/join-create.sql                (this file)
--   3. docs/sql/join-create-verification.sql   (writes test rows, then rolls
--                                               them all back; its final
--                                               message is the verdict)
--   -- the app switches Start a Table to create_table and TableView's seat
--      to join_table_by_code --
--   4. docs/sql/join-create-lockdown.sql       (revokes the direct INSERTs)
--   5. docs/sql/join-create-verification.sql   again (its L checks run once
--                                               the lockdown is in)
--   If it has to come out: docs/sql/join-create-rollback.sql.
--
-- DEPLOY ORDER: this file can run BEFORE the app half. It only ADDS a table
-- and functions the app doesn't call yet, and changes two functions the app
-- does call (watch_table, create_computer_table) in the ways listed below.
-- Two of those are visible to today's app at once:
--   * the one-table rule (a person seated at a table with other humans is
--     refused a new computer game or watch elsewhere; today's app shows the
--     message; an unfinished single-player game is ended quietly instead);
--   * watch_table answers a WRONG/UNKNOWN code with NO ROW instead of the
--     exception "No table found with code ...": today's app then shows
--     "Couldn't start watching. Please try again." (lib/spectatorData.ts)
--     instead of the not-found text. See WHY NO EXCEPTION below.
-- Start a Table and joining still go through the direct inserts until the
-- app switches; those inserts bypass the rule (only the lockdown closes that).
--
-- THE RULE (Walt, step 3): a person is at ONE table at a time, as a player or
-- as a spectator. "At a table" = seated (a table_members row) at a table that
-- is not ended (status <> 'ended'), or a current spectator of one. Ended
-- tables don't count.
--   * SINGLE-PLAYER GAMES NEVER BLOCK (Walt): a seat at one's own computer
--     table (the kind leave_computer_table accepts: computer_level set,
--     created by the caller, nobody else seated but computer accounts) is
--     quietly ENDED by a real create, join, watch or new computer game,
--     exactly as pressing Leave on it does today (a live game there ends as
--     'player_left'; both seats go; the table ends with ended_reason NULL),
--     and the action goes on. In the same transaction: if the action is then
--     refused for any reason, the computer table is NOT ended. The preview
--     (join_table_by_code p_preview) neither ends nor is refused by one.
--   * Seated at any other non-ended table (one with other humans), and
--     creating, joining or watching another, or starting a computer game:
--     REFUSED, with the message
--       "You're already at table NNNN. Rejoin it or leave it first."
--     DETAIL 'already_at_table', HINT the code (so the app can offer Rejoin
--     without parsing the text). A seat is never left automatically: leaving
--     can end a live game.
--   * Only watching, and creating, joining, watching another or starting a
--     computer game: that watching ends (exactly what stop_watching does:
--     the caller's own row, unless they were removed) and the action goes on.
--   * Re-joining or re-watching the SAME table: a no-op success.
--   * New actions only: nobody already at two tables is moved. The precheck
--     lists them.
--   * One person's actions are serialized (a transaction-level advisory lock
--     on the person), so two tabs can't both pass the rule at once.
--
-- THE LIMITS (public.attempt_log, below):
--   create_table            10 created an hour
--   create_computer_table   10 started an hour
--   join_table_by_code      30 joins an hour (a rejoin of your own seat is
--                           not counted)
--   watch_table             30 NEW watches an hour (refreshing a place you
--                           already have -- following the next game, a
--                           return after a hidden tab -- is not counted)
--   wrong codes             5 wrong or unknown codes in 10 minutes, through
--                           join_table_by_code and watch_table TOGETHER (one
--                           count, 'code_guess', so the two can't be used to
--                           double the guesses), then a 15-minute lockout
--                           from the 5th. Successful lookups don't count.
-- A refused call (limit or lockout) is not itself logged. Every message is
-- one the app can show as is; DETAIL is 'rate_limited' or 'locked_out'.
--
-- WHY NO EXCEPTION FOR A WRONG CODE (where the request said "raise"): an RPC
-- runs in one transaction, and an exception rolls ALL of it back -- including
-- the attempt_log row that counts the wrong guess. A counted failure must be
-- a normal return. So join_table_by_code returns outcome 'not_found' (one
-- generic answer for a wrong code, an unknown code and an ended table -- the
-- lookup only ever sees non-ended tables), and watch_table returns no row.
-- A FULL table is not a wrong guess: the seat trigger refuses it exactly as
-- today ("This table is full."), and it is not counted against the person.
--
-- WHAT THIS FILE CHANGES
--   1. NEW table public.attempt_log (RLS on, no policies, nothing for anon,
--      authenticated or service_role: only the functions below write or read
--      it), with an index for "this person, this action, recently".
--   2. NEW internal helpers (EXECUTE for nobody but the owner; the security
--      definer functions below run as the owner):
--        _attempts_guard(person, action, max, window, message)
--        _code_guesses_check(person)      raises the lockout
--        _code_guess_failed(person)       counts a wrong code
--        _one_table_rule(person, target, act)   ends one's single-player
--                                         tables, refuses, ends watching
--   3. NEW create_table(is_public, is_muggins, max_players, team_mode,
--      allow_spectators) -> (table_id, code).
--   4. NEW join_table_by_code(code, preview default false) -> one row (see
--      its comment for the columns and why).
--   5. watch_table(code): the rule, the wrong-code count and lockout, the
--      30-an-hour cap on new watches; a wrong code returns no row. Every
--      other refusal keeps its order and its exact message.
--   6. create_computer_table(level, code): the rule and 10 an hour. Every
--      other behavior is unchanged (the code is still the client's; a
--      collision still raises 23505; search_path stays "public").
--   NOT touched: the 8 game functions and their _as bodies, leave_table,
--   leave_computer_table, end_timed_out_sessions, assign_table_seat (the seat
--   trigger: create_table and join seat THROUGH it), table_host, every
--   policy, every grant on tables/table_members (the lockdown file does
--   that), the Realtime publication, and every chat function.
--   No function name here contains "chat" (the chat suite's C4).
--
-- NEW TABLE, so AGENTS.md's "New tables" rule applies: RLS on, grants
-- written out in the appearance-settings.sql order (revoke all from PUBLIC,
-- anon, authenticated -- and service_role, which nothing needs), and the
-- verification checks them. Unlike the template, NOTHING is granted back:
-- the table is reached only through the security definer functions.
--
-- ATTEMPT_LOG CLEANUP (NOT in this slice): rows older than a day are never
-- read (the longest window is 1 hour). A later slice adds one statement to
-- the existing pg_cron job's function, end_timed_out_sessions():
--     delete from public.attempt_log where created_at < now() - interval '1 day';
-- That function is fingerprinted by the phase3-e* suites, which stop at
-- their fingerprint checks by design after C1, so its md5 moves then.
-- Until then the table grows by one small row per create, join, new watch
-- and wrong code.
--
-- SLICE B NOTE (codes freed when a table ends): create_table's free-code
-- query reads "no table at all with this code"; in slice B it becomes "no
-- NON-ENDED table with this code". join_table_by_code already looks up the
-- non-ended table only. watch_table prefers the non-ended table (identical
-- today, while codes are unique).
--
-- RE-RUNNABLE: "create table if not exists", "create index if not exists",
-- "create or replace" for every function, grants and revokes idempotent. One
-- transaction: if any statement fails, nothing is applied.

begin;

-- ---------------------------------------------------------------------------
-- 1. The attempt log.
-- ---------------------------------------------------------------------------
create table if not exists public.attempt_log (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  action text not null
    constraint attempt_log_action_check
    check (action in ('create_table', 'create_computer_table', 'join', 'watch', 'code_guess')),
  success boolean not null,
  created_at timestamptz not null default now()
);

comment on table public.attempt_log is
  'Rate limits (step 3, slice A): one row per counted action -- a table created (create_table), a computer game started (create_computer_table), a join, a new watch (success true), or a wrong table code (code_guess, success false). Read and written only by security definer functions (create_table, join_table_by_code, watch_table, create_computer_table through the _attempts_* / _code_guess* helpers). RLS on, no policies, no grants. See docs/sql/join-create.sql.';

-- "This person, this action, the last N minutes."
create index if not exists attempt_log_user_action_time_idx
  on public.attempt_log (user_id, action, created_at desc);

-- Row-level security: on. No policies, so even a role with a privilege
-- would see nothing; and no role has one (below).
alter table public.attempt_log enable row level security;

-- Grants, explicit (the appearance-settings.sql order): everything revoked,
-- nothing granted back. Only the owner (the security definer functions) can
-- touch it.
revoke all on table public.attempt_log from public;
revoke all on table public.attempt_log from anon;
revoke all on table public.attempt_log from authenticated;
revoke all on table public.attempt_log from service_role;

-- Its identity sequence too (Supabase's default privileges grant sequences
-- to anon and authenticated).
revoke all on sequence public.attempt_log_id_seq from public;
revoke all on sequence public.attempt_log_id_seq from anon;
revoke all on sequence public.attempt_log_id_seq from authenticated;
revoke all on sequence public.attempt_log_id_seq from service_role;


-- ---------------------------------------------------------------------------
-- 2. The internal helpers. Plain (invoker) functions with EXECUTE revoked
--    from everyone: only the owner -- which is who the security definer
--    functions below run as -- can call them.
-- ---------------------------------------------------------------------------

-- _attempts_guard: "at most p_max successful p_action in p_window". Counts
-- this person's recent successes; at the limit, raises p_message (DETAIL
-- 'rate_limited'); otherwise logs this one as a success. Called just BEFORE
-- the action's own write, so if the action then fails with an exception,
-- this row is rolled back with it: only completed actions count. Serialized
-- per person and action (advisory lock), so two calls at once can't both
-- squeeze under the limit.
create or replace function public._attempts_guard(
  p_actor uuid,
  p_action text,
  p_max integer,
  p_window interval,
  p_message text
)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_n integer;
begin
  if p_actor is null then
    raise exception '_attempts_guard: no person given.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('attempt_log:' || p_actor::text || ':' || p_action, 0)
  );

  select count(*)
  into v_n
  from public.attempt_log a
  where a.user_id = p_actor
    and a.action = p_action
    and a.success
    and a.created_at > now() - p_window;

  if v_n >= p_max then
    raise exception using message = p_message, detail = 'rate_limited';
  end if;

  insert into public.attempt_log (user_id, action, success)
  values (p_actor, p_action, true);
end;
$$;

comment on function public._attempts_guard(uuid, text, integer, interval, text) is
  'Internal (step 3, slice A): at most p_max successful p_action per p_window for this person; raises p_message (DETAIL rate_limited) at the limit, else logs a success. No client role can execute it. See docs/sql/join-create.sql.';


-- _code_guesses_check: the wrong-code lockout. LOCKED when this person's 5
-- most recent wrong codes all fall within 10 minutes (newest minus 5th
-- newest <= 10 minutes) and the newest was less than 15 minutes ago. Locked
-- calls are refused before any lookup and are not logged, so the lockout
-- ends 15 minutes after the 5th wrong code. Raises "Too many wrong table
-- codes. Please wait N minutes and try again." (DETAIL 'locked_out').
create or replace function public._code_guesses_check(p_actor uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
declare
  v_newest timestamptz;
  v_fifth timestamptz;
  v_until timestamptz;
  v_minutes integer;
begin
  if p_actor is null then
    raise exception '_code_guesses_check: no person given.';
  end if;

  select a.created_at
  into v_newest
  from public.attempt_log a
  where a.user_id = p_actor and a.action = 'code_guess' and not a.success
  order by a.created_at desc
  limit 1;

  if v_newest is null then
    return;
  end if;

  select a.created_at
  into v_fifth
  from public.attempt_log a
  where a.user_id = p_actor and a.action = 'code_guess' and not a.success
  order by a.created_at desc
  offset 4
  limit 1;

  if v_fifth is null or v_newest - v_fifth > interval '10 minutes' then
    return;
  end if;

  v_until := v_newest + interval '15 minutes';
  if now() >= v_until then
    return;
  end if;

  v_minutes := greatest(1, ceil(extract(epoch from (v_until - now())) / 60)::integer);
  raise exception using
    message = format('Too many wrong table codes. Please wait %s minute%s and try again.',
                     v_minutes, case when v_minutes = 1 then '' else 's' end),
    detail = 'locked_out';
end;
$$;

comment on function public._code_guesses_check(uuid) is
  'Internal (step 3, slice A): raises the wrong-code lockout (5 wrong codes within 10 minutes locks for 15 minutes from the 5th; DETAIL locked_out). No client role can execute it. See docs/sql/join-create.sql.';


-- _code_guess_failed: count one wrong or unknown code. The caller must then
-- RETURN normally (not raise), or this row is rolled back.
create or replace function public._code_guess_failed(p_actor uuid)
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  if p_actor is null then
    raise exception '_code_guess_failed: no person given.';
  end if;

  insert into public.attempt_log (user_id, action, success)
  values (p_actor, 'code_guess', false);
end;
$$;

comment on function public._code_guess_failed(uuid) is
  'Internal (step 3, slice A): logs one wrong table code (attempt_log action code_guess, success false). No client role can execute it. See docs/sql/join-create.sql.';


-- _one_table_rule: one person, one table.
--   p_target: the table being joined or watched (NULL when creating a table
--   or starting a computer game). A seat at p_target itself is the caller's
--   business (a rejoin, or watch_table's "You are seated at this table.").
--   1. Serializes this person's actions (advisory lock; the four entry points
--      take it first too, so the order is always person, then table).
--   2. p_act (a real action; false only for join_table_by_code's preview,
--      which changes nothing): quietly ENDS every OTHER non-ended
--      SINGLE-PLAYER table of this person (Walt: single-player games never
--      block). "Single-player table of this person" is exactly the table
--      leave_computer_table accepts from them: computer_level set, created
--      by them, and nobody seated there but them and computer accounts.
--      They must also be seated there (a table they already walked away
--      from doesn't put them "at" it). Each one ends with
--      leave_computer_table's own three statements, in its order, after its
--      row lock:
--        a live game (cutting/active) -> status 'ended', ended_reason
--          'player_left';
--        every seat deleted (theirs and the computer's);
--        the table -> status 'ended', ended_reason left NULL (the tables
--          check allows only 'admin' and 'timeout'; the same convention).
--      Reproduced here rather than called: leave_computer_table reads
--      auth.uid() (this helper is given the person), and it raises on
--      anything unexpected -- a raise there would refuse the whole new
--      action. The precheck fingerprints leave_computer_table's body, so a
--      change to it shows up before this file runs. Everything here is in
--      the caller's transaction: if anything later in the same call refuses
--      (the human-table refusal below, a full table, a limit), the ending
--      rolls back too, so a refused action never ends someone's game.
--   3. Seated at any OTHER non-ended table that is NOT a single-player table
--      of theirs (after step 2 none is left in a real action; a preview skips
--      them, because the real action would end them): raises "You're already
--      at table NNNN. Rejoin it or leave it first." (DETAIL already_at_table,
--      HINT the code; the most recently joined one, if there are several).
--   4. p_act: ends this person's watching of every OTHER non-ended table
--      (deletes their own rows unless removed -- what stop_watching does).
create or replace function public._one_table_rule(p_actor uuid, p_target uuid, p_act boolean)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_code text;
  v_solo uuid;
begin
  if p_actor is null then
    raise exception '_one_table_rule: no person given.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('one_table:' || p_actor::text, 0));

  -- 2. Single-player tables never block: end them (real actions only).
  if p_act then
    for v_solo in
      select t.id
      from public.table_members tm
      join public.tables t on t.id = tm.table_id
      where tm.user_id = p_actor
        and t.status <> 'ended'
        and t.computer_level is not null
        and t.created_by = p_actor
        and (p_target is null or t.id <> p_target)
        and not exists (
          select 1
          from public.table_members o
          where o.table_id = t.id
            and o.user_id <> p_actor
            and not exists (
              select 1
              from public.computer_accounts ca
              where ca.user_id = o.user_id
            )
        )
      order by t.id
    loop
      -- leave_computer_table's lock, then its three statements.
      perform 1
      from public.tables t
      where t.id = v_solo
      for no key update;

      update public.games
      set status = 'ended', ended_reason = 'player_left'
      where table_id = v_solo
        and status in ('cutting', 'active');

      delete from public.table_members
      where table_id = v_solo;

      update public.tables
      set status = 'ended'
      where id = v_solo
        and status = 'open';
    end loop;
  end if;

  -- 3. Any other non-ended table still refuses (a single-player table of
  -- theirs is skipped: a real action has just ended it; a preview must not).
  select t.code
  into v_code
  from public.table_members tm
  join public.tables t on t.id = tm.table_id
  where tm.user_id = p_actor
    and t.status <> 'ended'
    and (p_target is null or t.id <> p_target)
    and not (
      t.computer_level is not null
      and t.created_by = p_actor
      and not exists (
        select 1
        from public.table_members o
        where o.table_id = t.id
          and o.user_id <> p_actor
          and not exists (
            select 1
            from public.computer_accounts ca
            where ca.user_id = o.user_id
          )
      )
    )
  order by tm.joined_at desc
  limit 1;

  if v_code is not null then
    raise exception using
      message = format('You''re already at table %s. Rejoin it or leave it first.', v_code),
      detail = 'already_at_table',
      hint = v_code;
  end if;

  -- 4. Watching elsewhere ends (real actions only).
  if p_act then
    delete from public.table_spectators ts
    using public.tables t
    where t.id = ts.table_id
      and ts.user_id = p_actor
      and ts.removed_at is null
      and t.status <> 'ended'
      and (p_target is null or ts.table_id <> p_target);
  end if;
end;
$$;

comment on function public._one_table_rule(uuid, uuid, boolean) is
  'Internal (step 3, slice A): one person, one table. In a real action (p_act) it first ends the person''s other single-player (computer) tables the way leave_computer_table does; then refuses (DETAIL already_at_table, HINT the code) when the person is seated at another non-ended table with other humans; then, in a real action, ends their watching of other tables. A preview (p_act false) changes nothing and is not refused by a single-player table. No client role can execute it. See docs/sql/join-create.sql.';

revoke all on function public._attempts_guard(uuid, text, integer, interval, text) from public;
revoke all on function public._attempts_guard(uuid, text, integer, interval, text) from anon;
revoke all on function public._attempts_guard(uuid, text, integer, interval, text) from authenticated;
revoke all on function public._attempts_guard(uuid, text, integer, interval, text) from service_role;

revoke all on function public._code_guesses_check(uuid) from public;
revoke all on function public._code_guesses_check(uuid) from anon;
revoke all on function public._code_guesses_check(uuid) from authenticated;
revoke all on function public._code_guesses_check(uuid) from service_role;

revoke all on function public._code_guess_failed(uuid) from public;
revoke all on function public._code_guess_failed(uuid) from anon;
revoke all on function public._code_guess_failed(uuid) from authenticated;
revoke all on function public._code_guess_failed(uuid) from service_role;

revoke all on function public._one_table_rule(uuid, uuid, boolean) from public;
revoke all on function public._one_table_rule(uuid, uuid, boolean) from anon;
revoke all on function public._one_table_rule(uuid, uuid, boolean) from authenticated;
revoke all on function public._one_table_rule(uuid, uuid, boolean) from service_role;


-- ---------------------------------------------------------------------------
-- 3. create_table: Start a Table, on the server.
-- ---------------------------------------------------------------------------
-- The parameters are the five options the direct insert sends today
-- (lib/newTable.ts newTableFields): a NULL takes the column's default, as an
-- omitted column does now (is_public false, is_muggins false, max_players 2,
-- team_mode 'teams', allow_spectators false) -- the app omits team_mode for 2-
-- and 3-player regular tables. The same rules the direct insert meets, with
-- messages the app can show (the CHECK constraints still stand behind them):
--   max_players 2, 3 or 4            (tables_max_players_check)
--   team_mode 'teams' or 'solo'      (tables_team_mode_check)
--   4-player Self-Scoring is Solo    (tables_muggins_no_teams)
--   allow_spectators: human tables only (tables_spectators_human_only). This
--   function only ever makes human tables (computer_level stays null), so
--   the check always holds; computer tables come from create_computer_table.
-- Then: the one-table rule (an unfinished single-player game ends; refused
-- if seated with other humans; watching ends), at most 10 an
-- hour, a random free 4-digit code (up to 5 tries: a code taken between the
-- pick and the insert raises unique_violation, caught, and another is picked;
-- "No table codes are free right now..." when none is left), the table with
-- created_by = the caller, and the creator SEATED through the seat trigger
-- (assign_table_seat: seat 1 at a new table). Returns (table_id, code).
-- The creator's seat is written here, so Start a Table no longer needs
-- TableView to seat them.
create or replace function public.create_table(
  p_is_public boolean,
  p_is_muggins boolean,
  p_max_players integer,
  p_team_mode text,
  p_allow_spectators boolean
)
returns table (table_id uuid, code text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_caller uuid := auth.uid();
  v_is_public boolean := coalesce(p_is_public, false);
  v_is_muggins boolean := coalesce(p_is_muggins, false);
  v_max integer := coalesce(p_max_players, 2);
  v_team text := coalesce(p_team_mode, 'teams');
  v_spectators boolean := coalesce(p_allow_spectators, false);
  v_code text;
  v_table_id uuid;
  v_try integer;
begin
  if v_caller is null then
    raise exception 'You must be logged in to start a table.';
  end if;

  if v_max not in (2, 3, 4) then
    raise exception 'A table seats 2, 3 or 4 players.';
  end if;

  if v_team not in ('teams', 'solo') then
    raise exception 'Choose Teams or Solo for a 4-player table.';
  end if;

  if v_is_muggins and v_max = 4 and v_team <> 'solo' then
    raise exception 'A 4-player Self-Scoring table plays Solo.';
  end if;

  -- One person, one table (the person's lock first, then the rule).
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('one_table:' || v_caller::text, 0));
  perform public._one_table_rule(v_caller, null, true);

  perform public._attempts_guard(v_caller, 'create_table', 10, interval '1 hour',
    'You can start at most 10 tables an hour. Please try again later.');

  for v_try in 1..5 loop
    -- A random code no table uses (slice B: no NON-ENDED table).
    select c.code
    into v_code
    from (select lpad(n::text, 4, '0') as code from generate_series(0, 9999) as n) c
    where not exists (select 1 from public.tables t where t.code = c.code)
    order by random()
    limit 1;

    if v_code is null then
      raise exception 'No table codes are free right now. Please try again in a few minutes.';
    end if;

    begin
      insert into public.tables (code, created_by, is_public, is_muggins, max_players, team_mode, allow_spectators)
      values (v_code, v_caller, v_is_public, v_is_muggins, v_max, v_team, v_spectators)
      returning tables.id into v_table_id;
      exit;
    exception when unique_violation then
      -- Taken since the pick: try another.
      v_table_id := null;
    end;
  end loop;

  if v_table_id is null then
    raise exception 'Could not find a free table code. Please try again.';
  end if;

  -- The creator's seat, through the seat trigger (seat 1).
  insert into public.table_members (table_id, user_id)
  values (v_table_id, v_caller);

  table_id := v_table_id;
  code := v_code;
  return next;
end;
$$;

comment on function public.create_table(boolean, boolean, integer, text, boolean) is
  'Start a Table (step 3, slice A): creates a human table with a free random 4-digit code and seats the caller in it. One table at a time (refused when seated elsewhere: DETAIL already_at_table, HINT the code; watching elsewhere ends), at most 10 an hour (DETAIL rate_limited). NULL options take the column defaults. Returns (table_id, code). See docs/sql/join-create.sql.';

revoke all on function public.create_table(boolean, boolean, integer, text, boolean) from public;
revoke all on function public.create_table(boolean, boolean, integer, text, boolean) from anon;
revoke all on function public.create_table(boolean, boolean, integer, text, boolean) from service_role;
grant execute on function public.create_table(boolean, boolean, integer, text, boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. join_table_by_code: joining, on the server.
-- ---------------------------------------------------------------------------
-- p_code: the 4-digit code. p_preview: look only (see below).
--
-- RETURNS ONE ROW. Columns, and why each is there (TableView's setup,
-- components/table/TableView.tsx, reads all of these before or right after
-- taking the seat today):
--   outcome           'joined' (seated now), 'already_seated' (seated here
--                     already: nothing changed), 'preview' (looked only), or
--                     'not_found' (a wrong code, an unknown code or an ended
--                     table -- one answer; every other column is then NULL).
--   table_id, code    the table (TableView keys everything off the id).
--   status, ended_reason, is_muggins, created_by, max_players, team_mode,
--   computer_level, allow_spectators
--                     TableView's TableRow, the exact columns its setup
--                     selects from tables today ("id, code, status,
--                     ended_reason, is_muggins, created_by, max_players,
--                     team_mode, computer_level, allow_spectators"), so the
--                     app can set the table without reading tables (which
--                     private tables, slice C, won't allow). status is never
--                     'ended' here (ended tables are not_found); ended_reason
--                     is then always null, kept so the row is a whole TableRow.
--   is_public         for the future "Join table 1234 hosted by X?" step.
--   seat              the caller's seat (NULL for a preview).
--   seated_count      how many are seated (with max_players: whether the
--                     table is full, which TableView's Watch-instead offer,
--                     nickname gate and Muggins notice all read today).
--   game_live, game_id
--                     a game being cut for or played (the Watch-instead offer
--                     reads this before seating; the watch page follows it).
--   host_nickname     the host's nickname (table_host: the creator if seated,
--                     else the lowest seat), for "hosted by X".
-- WHY A PREVIEW: TableView asks three things BEFORE a seat is taken -- the
-- nickname step, the Muggins agreement for a joiner, and Play-or-Watch --
-- and each needs the table's options and fullness. With p_preview the app
-- gets the same row without being seated (outcome 'preview'), shows those
-- steps, then calls again without p_preview. A preview counts wrong codes
-- like a join (so it can't be used to guess codes), applies the refusal half
-- of the one-table rule (seated elsewhere with other humans: refused) but
-- ends nothing -- not watching, and not an unfinished single-player game,
-- which doesn't make it refuse either (the real join would end it) -- and is
-- not counted toward the 30 an hour.
--
-- ORDER: signed in; the person's lock; the wrong-code lockout; the lookup
-- ("the non-ended table with this code" -- still right when slice B frees
-- ended tables' codes); not found -> counted, outcome 'not_found', NO
-- exception; seated here already -> 'already_seated', no change, not counted;
-- preview -> 'preview'; otherwise the one-table rule (an unfinished
-- single-player game ends; seated elsewhere with other humans: refused;
-- watching elsewhere ends), 30 joins an hour, the seat through the
-- seat trigger (a full table is refused exactly as today: "This table is
-- full."; the single-player game ended above is then NOT ended: the refusal
-- rolls it back), and the caller's own watching of THIS table ends (they are a
-- player now). The lookup comes before the rule because a rejoin of the same
-- table must succeed, which needs to know which table the code is.
create or replace function public.join_table_by_code(p_code text, p_preview boolean default false)
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
  host_nickname text
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
  order by t.created_at desc
  limit 1;

  if not found then
    -- Counted, and returned (not raised: an exception would undo the count).
    perform public._code_guess_failed(v_caller);
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
  select p.nickname into host_nickname from public.profiles p where p.id = public.table_host(v_t.id);
  return next;
end;
$$;

comment on function public.join_table_by_code(text, boolean) is
  'Join by code (step 3, slice A): seats the caller at the non-ended table with this code (or, with p_preview, only describes it). One row: outcome joined / already_seated / preview / not_found (wrong, unknown or ended: one answer, counted toward the wrong-code lockout), the table (TableView''s TableRow columns plus is_public), the seat, seated_count, the live game and the host''s nickname. One table at a time (DETAIL already_at_table), 30 joins an hour (rate_limited), 5 wrong codes in 10 minutes lock for 15 (locked_out); a full table is refused by the seat trigger as before. See docs/sql/join-create.sql.';

revoke all on function public.join_table_by_code(text, boolean) from public;
revoke all on function public.join_table_by_code(text, boolean) from anon;
revoke all on function public.join_table_by_code(text, boolean) from service_role;
grant execute on function public.join_table_by_code(text, boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. watch_table(code): the rule, the wrong-code count, 30 new watches an hour.
-- ---------------------------------------------------------------------------
-- spectators-join-or-watch.sql's body with the changes marked (J1)..(J6).
-- Every other refusal keeps its order and exact message (lib/spectators.ts
-- watchRefusal matches them by text).
create or replace function public.watch_table(p_code text)
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
  -- (J3) The non-ended table with this code first (identical today, while
  -- codes are unique; right once slice B frees ended tables' codes).
  select t.id, t.code, t.status, t.allow_spectators, t.computer_level
  into v_table
  from public.tables t
  where t.code = p_code
  order by (t.status <> 'ended') desc, t.created_at desc
  limit 1
  for no key update;

  if not found then
    -- (J4) A wrong or unknown code: counted, and NO ROW returned instead of
    -- the old exception "No table found with code ..." (an exception would
    -- roll the count back).
    perform public._code_guess_failed(v_caller);
    return;
  end if;

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

comment on function public.watch_table(text) is
  'Spectator seat (PRD item 40): become or stay a spectator of the table with this code, whether or not a game is live. Refused with a message when not allowed (see docs/sql/spectators.sql, spectators-join-or-watch.sql and join-create.sql): one table at a time (DETAIL already_at_table; watching another table ends), 30 new watches an hour (rate_limited), the wrong-code lockout (locked_out). A wrong or unknown code returns NO row (counted). Returns the table id, code and the live game id (null in the waiting room or between games).';

-- Unchanged grants, restated (spectators.sql): authenticated only.
revoke all on function public.watch_table(text) from public;
revoke all on function public.watch_table(text) from anon;
revoke all on function public.watch_table(text) from service_role;
grant execute on function public.watch_table(text) to authenticated;


-- ---------------------------------------------------------------------------
-- 6. create_computer_table(level, code): the rule and 10 an hour.
-- ---------------------------------------------------------------------------
-- The LIVE body (captured 2026-11-23 in
-- docs/sql/computer-live-create_computer_table-2026-11-23.sql; the committed
-- computer-normie.sql is the same function with comments the live text
-- doesn't have) with (J7) added, and nothing else: the level list, every
-- message, the computer-account check, #variable_conflict, the insert order
-- (the human, then the computer), the return shape, security definer and
-- search_path "public" are all as live. The code is still the client's: a
-- collision still raises 23505 uncaught (and rolls back J7's work with it).
create or replace function public.create_computer_table(p_level text, p_code text)
returns table (table_id uuid, code text)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_caller uuid := auth.uid();
  v_computer uuid;
  v_table_id uuid;
  v_code text;
begin
  if v_caller is null then
    raise exception 'You must be logged in to start a table.';
  end if;

  if p_level is null or p_level not in ('easy', 'casual', 'medium', 'hard') then
    raise exception 'Unknown computer level "%": choose easy, casual, medium or hard.', coalesce(p_level, '');
  end if;

  select ca.user_id
  into v_computer
  from public.computer_accounts ca
  where ca.level = p_level;

  if v_computer is null then
    raise exception 'The % computer is not set up yet.', p_level;
  end if;

  if v_computer = v_caller then
    raise exception 'A computer account cannot start a computer table.';
  end if;

  -- ===== (J7) ONE TABLE AT A TIME, 10 AN HOUR (start) =====
  -- An unfinished single-player game of the caller's is ended first (as
  -- Leave does); refused when seated at a non-ended table with other
  -- humans; watching ends. Then at most 10 started an hour.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('one_table:' || v_caller::text, 0));
  perform public._one_table_rule(v_caller, null, true);
  perform public._attempts_guard(v_caller, 'create_computer_table', 10, interval '1 hour',
    'You can start at most 10 single-player games an hour. Please try again later.');
  -- ===== (J7) ONE TABLE AT A TIME, 10 AN HOUR (end) =====

  insert into public.tables (code, created_by, is_public, is_muggins, max_players, computer_level)
  values (p_code, v_caller, false, false, 2, p_level)
  returning tables.id, tables.code into v_table_id, v_code;

  insert into public.table_members (table_id, user_id)
  values (v_table_id, v_caller);

  insert into public.table_members (table_id, user_id)
  values (v_table_id, v_computer);

  table_id := v_table_id;
  code := v_code;
  return next;
end;
$$;

-- Unchanged grants, restated (as live: "create or replace" keeps the ACL, so
-- service_role keeps the EXECUTE it has live; nothing here revokes it).
revoke all on function public.create_computer_table(text, text) from public;
revoke all on function public.create_computer_table(text, text) from anon;
grant execute on function public.create_computer_table(text, text) to authenticated;

commit;
