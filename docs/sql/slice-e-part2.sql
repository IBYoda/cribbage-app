-- Step 3, slice E, PART 2: BEHAVIOR -- the new limits and the avatar names.
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- WHEN: after docs/sql/slice-e-part1.sql, AND after the slice E app build is
-- live (the friendly messages for the nickname lock and the follow limit,
-- and avatar uploads named avatar.png / avatar.jpg / avatar.webp) and old
-- tabs have reloaded. An old tab's upload named "avatar.PNG" or
-- "avatar.jpeg" from a ".JPEG" file would be refused by the new policy.
-- Run docs/sql/slice-e-precheck.sql first (no STOP rows). Then
-- docs/sql/slice-e-ratelimits-verification.sql and
-- docs/sql/computer-c1-verification.sql (its fingerprint for
-- start_game_with_deal_as is updated for this file).
-- To undo: docs/sql/slice-e-part2-rollback.sql (restores the three bodies
-- byte for byte, drops the trigger, puts the two avatar policies back).
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold): the four
--      fingerprinted bodies unchanged; start_game_with_deal_as,
--      _follow_user_as and unfollow_user are today's text (computer-c1 /
--      follows.sql) or this file's (a re-run); part 1 applied; the two avatar
--      policies exist by name; profiles has no other trigger.
--   1. THE GAMES CAP -- start_game_with_deal_as (the one function that
--      creates a game: the player's start_game_with_deal and the computer's
--      computer_start_game_with_deal both call it; next_hand deals within the
--      same game and creates none). One new block, (E1), just before the
--      score reset that only the call whose insert succeeded reaches.
--      WHAT COUNTS, exactly: a call that CREATES a game -- the first game at
--      a table or any game after one that ended without a winner (the cut
--      for deal; 3-4 players: the host's start), and the rematch after a won
--      game, counted ONCE, for the call whose ready tap completes the set.
--      What does NOT count: a ready tap that only records itself and waits,
--      a call that finds a game already live, a simultaneous start that lost
--      the race, next_hand, and any refused start. The count is per ACCOUNT:
--      the caller, or the human who created the computer table when the
--      computer's tap starts it. 30 in the last hour: refused with "You have started 30 games in the last hour. Please take a break and try again a little later."
--      (detail rate_limited), and the new game is undone. Logged as
--      attempt_log action 'game_start'.
--   2. THE NICKNAME LOCK -- a BEFORE INSERT OR UPDATE row trigger on
--      profiles, profiles_nickname_lock -> public.profiles_nickname_lock(),
--      so the app's direct upsert keeps working. For the client roles only
--      (authenticated, anon); the owner is never limited:
--        * INSERT (a new row): nickname_changed_at forced to null.
--        * UPDATE, including an upsert's DO UPDATE (BEFORE UPDATE fires with
--          OLD = the stored row and NEW = the proposed one):
--          nickname_changed_at is forced to the stored value (a client
--          cannot write it). A REAL change -- lower(btrim()) differs -- from a
--          NON-EMPTY nickname: refused while nickname_changed_at is within 7
--          days ("You can change your nickname again in N days.", detail
--          nickname_locked); otherwise allowed and stamped now(). The first
--          nickname (from '') is free and stamps nothing; the same nickname
--          in another case or spacing is not a change. Existing rows are null:
--          one free change each.
--        * Delete-and-reinsert cannot reset it: no DELETE policy exists on
--          profiles (a client delete matches no row), and part 3 revokes
--          DELETE too.
--   3. THE FOLLOW CHURN LIMIT -- _follow_user_as (block (E2), just before
--      the insert: only a real follow, after the cap of 50 and the
--      not-allowed checks have returned) and unfollow_user (block (E3): the
--      follower lock, then only a real unfollow). 30 real changes in an hour:
--      refused with "You have changed who you follow 30 times in the last hour. Please try again a little later." (detail rate_limited); nothing written.
--      Logged as attempt_log action 'follow_change'. follow_user is
--      unchanged (it passes auth.uid() and 50 to _follow_user_as).
--   4. THE AVATAR NAMES -- the storage.objects INSERT and UPDATE policies
--      "Users can upload their own avatar" / "Users can update their own
--      avatar" are replaced (same names) so a user may write only
--      '<their uid>/avatar.png', 'avatar.jpg', 'avatar.jpeg' or 'avatar.webp'
--      (exact, lower case) in the avatars bucket. The SELECT policy is kept.
--      Existing objects with other names are left alone (never delete
--      storage.objects rows with SQL: it orphans the files);
--      slice-e-precheck.sql lists them.
--
-- FUNCTIONS WHOSE BODIES CHANGE: start_game_with_deal_as, _follow_user_as,
-- unfollow_user. NEW: profiles_nickname_lock. Not changed: every wrapper
-- (start_game_with_deal, computer_start_game_with_deal, follow_user), the
-- four fingerprinted functions, _attempts_guard.
--
-- md5 of the new bodies (carriage returns removed): start_game_with_deal_as
-- 8b4528a51247b63a47b36bd703f81492 (computer-c1's as_md5; its orig_md5 becomes
-- 4f5e5a5dd5809d0d2f71d4c588197a71), _follow_user_as 0996790bb0c497cdf8cb775a2fb3e22e, unfollow_user
-- be4ba2a18fb61605135205713be00f07, profiles_nickname_lock 215515390acc9b410afbd71b210d31e0.
--
-- RE-RUNNABLE: create or replace; drop trigger / policy if exists, then
-- create.

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard.
-- ---------------------------------------------------------------------------
do $$
declare
  v_rec record;
  v_txt text;
begin
  -- The four fingerprinted bodies, unchanged.
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

  -- The three bodies this file replaces: today's text, or this file's (a
  -- re-run). md5 with carriage returns removed (computer-c1's method).
  for v_rec in
    select * from (values
      ('public.start_game_with_deal_as(uuid, uuid)', '8d6ceb9ba00b9f2b6b9b8613e10609df', '8b4528a51247b63a47b36bd703f81492'),
      ('public._follow_user_as(uuid, uuid, integer)', '9c2f318761d3110a1f67de73eb5d9be8', '0996790bb0c497cdf8cb775a2fb3e22e'),
      ('public.unfollow_user(uuid)', '82fe22965cc8a28cc3812f029b470404', 'be4ba2a18fb61605135205713be00f07')
    ) as t(fn, before_md5, after_md5)
  loop
    select md5(replace(p.prosrc, E'\r', '')) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is null or v_txt not in (v_rec.before_md5, v_rec.after_md5) then
      raise exception 'STOP: % has body md5 % (carriage returns removed); expected % (today) or % (slice E part 2). Capture it first: select pg_get_functiondef(''%''::regprocedure); Nothing was changed.', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.before_md5, v_rec.after_md5, v_rec.fn;
    end if;
  end loop;

  -- Part 1 applied: the two actions, the column, the cleanup function.
  select pg_get_constraintdef(con.oid) into v_txt
  from pg_constraint con
  where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check';
  if v_txt is null or v_txt !~ '''game_start''' or v_txt !~ '''follow_change''' then
    raise exception 'STOP: attempt_log_action_check does not allow game_start and follow_change. Run docs/sql/slice-e-part1.sql first. Nothing was changed.';
  end if;
  if not exists (select 1 from pg_attribute a
                 where a.attrelid = 'public.profiles'::regclass and a.attname = 'nickname_changed_at' and not a.attisdropped) then
    raise exception 'STOP: profiles.nickname_changed_at is missing. Run docs/sql/slice-e-part1.sql first. Nothing was changed.';
  end if;

  -- The avatar policies this file replaces exist (by name).
  if (select count(*) from pg_policies p
      where p.schemaname = 'storage' and p.tablename = 'objects'
        and ((p.policyname = 'Users can upload their own avatar' and p.cmd = 'INSERT')
             or (p.policyname = 'Users can update their own avatar' and p.cmd = 'UPDATE'))) <> 2 then
    raise exception 'STOP: storage.objects does not have exactly the policies "Users can upload their own avatar" (INSERT) and "Users can update their own avatar" (UPDATE). Nothing was changed.';
  end if;

  -- profiles has no trigger but (on a re-run) this file's.
  select string_agg(tg.tgname::text, ', ') into v_txt
  from pg_trigger tg
  where tg.tgrelid = 'public.profiles'::regclass and not tg.tgisinternal and tg.tgname <> 'profiles_nickname_lock';
  if v_txt is not null then
    raise exception 'STOP: profiles has other triggers (%); the nickname lock was designed for none. Nothing was changed.', v_txt;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The games cap: start_game_with_deal_as (block (E1)).
-- ---------------------------------------------------------------------------
create or replace function public.start_game_with_deal_as(p_actor uuid, p_table_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := p_actor;
  v_players uuid[];
  v_player_count int;
  v_game_id uuid;
  v_dealer uuid;
  -- ===== (M1) CHANGED FROM SLICE 5 (start) =====
  -- v_prev_dealer is gone: the deal no longer alternates from the last
  -- dealer. These describe the previous MATCH instead.
  v_prev_reason text;
  v_prev_winner uuid;
  v_prev_players uuid[];
  v_loser uuid;
  -- ===== (M1) CHANGED FROM SLICE 5 (end) =====
  -- ===== (N1) CHANGED FROM BATCH 2b (start) =====
  v_prev_id uuid;
  v_prev_ready uuid[];
  v_ready uuid[];
  v_live uuid;
  -- ===== (N1) CHANGED FROM BATCH 2b (end) =====
  -- ===== (D1) CHANGED FOR PHASE 3 E2 (start) =====
  v_status text;
  v_max smallint;
  v_winner_pos int;
  -- ===== (D1) CHANGED FOR PHASE 3 E2 (end) =====
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to start a game.';
  end if;

  -- ===== (D2) CHANGED FOR PHASE 3 E2 (start) =====
  -- THE TABLE LOCK, before anything is read: the same lock joining
  -- (assign_table_seat) and seat moves (set_seat) take, so a Start can never
  -- overlap a join, a leave's seat being retaken, or a seat move -- the
  -- roster and the seats read below are final until this transaction ends.
  -- It also serializes two simultaneous Starts at the table: the second
  -- waits here, then finds the first one's game exactly as it did before
  -- (the live-game handlers below). Nothing is checked yet, so the guards
  -- and their messages run in the same order as before; a table id that
  -- doesn't exist simply locks nothing.
  select t.status, t.max_players
  into v_status, v_max
  from public.tables t
  where t.id = p_table_id
  for no key update;
  -- ===== (D2) CHANGED FOR PHASE 3 E2 (end) =====

  -- Guard 2 (the membership check): the caller must actually be sitting at
  -- this table.
  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = p_table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not a member of this table.';
  end if;

  -- ===== (D3) CHANGED FOR PHASE 3 E2 (start) =====
  -- Guard 3: the table itself must still be open -- read from the row
  -- locked above (same message as before).
  if v_status is distinct from 'open' then
    raise exception 'This table is no longer open.';
  end if;

  -- Guard 4: exactly the table's size seated -- 2, 3 or 4 (tables.max_players;
  -- every table made before Phase 3 is a 2-player table, so this reads
  -- "exactly 2" for them, with the same message as before). An over-full
  -- table from before E1 is refused here too.
  --
  -- PLAYERS IN SEAT ORDER, not join order: seat 1, 2, 3, 4, which is
  -- clockwise. Everything that follows the players array -- the deal, the
  -- next dealer, who leads -- goes clockwise from it. In a 2-player game the
  -- order changes nothing (see the header).
  select array_agg(tm.user_id order by tm.seat)
  into v_players
  from public.table_members tm
  where tm.table_id = p_table_id;

  v_player_count := coalesce(array_length(v_players, 1), 0);

  if v_player_count <> coalesce(v_max, 2) then
    raise exception 'A game needs exactly % players at the table (currently %).', coalesce(v_max, 2), v_player_count;
  end if;
  -- ===== (D3) CHANGED FOR PHASE 3 E2 (end) =====

  -- ===== (M2) CHANGED FROM SLICE 5 (start) =====
  -- THE PREVIOUS MATCH: the most recent game at this table, whatever its
  -- status. Scalars rather than a record, so "no previous game" is simply
  -- three nulls and every test below reads false.
  -- ===== (N2) CHANGED FROM BATCH 2b (start) =====
  -- Also the previous game's id (the row the ready gate locks) and its
  -- ready_by. With no previous game, these are nulls too.
  select g.ended_reason, g.winner_id, g.players, g.id, g.ready_by
  into v_prev_reason, v_prev_winner, v_prev_players, v_prev_id, v_prev_ready
  -- ===== (N2) CHANGED FROM BATCH 2b (end) =====
  from public.games g
  where g.table_id = p_table_id
  order by g.created_at desc
  limit 1;

  -- The loser deals first -- but only after a WON match between exactly the
  -- two players who are here now (compared as sets, so join order does not
  -- matter). The loser is then necessarily still at the table, because
  -- v_players is the current roster. Any other ending leaves v_loser null and
  -- falls through to the cut.
  if v_prev_reason = 'won'
     and v_prev_winner is not null
     and v_prev_players is not null
     and (select array_agg(u order by u) from unnest(v_prev_players) as u)
         = (select array_agg(u order by u) from unnest(v_players) as u)
  then
    -- ===== (D4) CHANGED FOR PHASE 3 E2 (start) =====
    -- THE LOSER who deals: the player in the next seat clockwise from the
    -- winner. In 2 players that is simply the other player, as before. In 4
    -- (Teams) the next seat is always on the other team, whichever partner
    -- is recorded as the winner; in 3 it is the player on the winner's
    -- left. (A decision flagged for review: see the header.)
    v_winner_pos := array_position(v_players, v_prev_winner);
    v_loser := v_players[(v_winner_pos % v_player_count) + 1];
    -- ===== (D4) CHANGED FOR PHASE 3 E2 (end) =====
  end if;

  if v_loser is not null then
    -- A rematch: the loser deals the first hand. No cut is needed, so this
    -- path deals immediately and goes straight to 'active' -- the same state
    -- a resolved cut leaves (see the top of this file).
    v_dealer := v_loser;
  -- ===== (M2) CHANGED FROM SLICE 5 (end) =====

    -- ===== (N3) CHANGED FROM BATCH 2b (start) =====
    -- THE NEW GAME READY GATE. Only on this path -- a won match between the
    -- same players, which is the one path that would otherwise deal at once
    -- without the other player doing anything. Every other path is a cut
    -- for deal, which already needs both players to draw.
    --
    -- Every player in the WON game's players array must have tapped New
    -- Game ("players <@ ready_by", the same rule as next_hand) -- not a
    -- hard-coded 2.

    -- THE LOCK: the won game's row. Two taps arriving together are taken one
    -- at a time: the first records itself, the second sees it and (if that
    -- completes the set) starts the match. Re-reads ready_by under the lock,
    -- since the value read above may be stale.
    select g.ready_by
    into v_prev_ready
    from public.games g
    where g.id = v_prev_id
    for update;

    -- A tap that arrives after the match has started -- e.g. it waited on the
    -- lock while the other player's tap started it. Return that game; record
    -- nothing, reset nothing.
    select g.id
    into v_live
    from public.games g
    where g.table_id = p_table_id
      and g.status in ('cutting', 'active');

    if v_live is not null then
      return v_live;
    end if;

    -- Already ready: quiet. A double tap, a retry, a second tab.
    if v_caller = any(v_prev_ready) then
      return null;
    end if;

    v_ready := array_append(v_prev_ready, v_caller);

    update public.games
    set ready_by = v_ready
    where id = v_prev_id;

    -- Not everyone yet: return NULL -- "recorded, waiting". Nothing is
    -- created or dealt, and the scores stay where the match ended (the
    -- reset below is never reached).
    if not (v_prev_players <@ v_ready) then
      return null;
    end if;

    -- Everyone is ready: fall through to the unchanged start below. The won
    -- game keeps its full ready_by -- it's history, and it is no longer the
    -- table's most recent game once the new one is inserted.
    -- ===== (N3) CHANGED FROM BATCH 2b (end) =====

    begin
      insert into public.games (table_id, created_by, dealer_id, players, status, deal_cut)
      values (p_table_id, v_caller, v_dealer, v_players, 'active', null)
      returning id into v_game_id;
    exception when unique_violation then
      select g.id into v_game_id
      from public.games g
      where g.table_id = p_table_id
        and g.status in ('cutting', 'active');
      return v_game_id;
    end;

    perform public.deal_cards_for_game(v_game_id);
  else
    -- ===== (M3) CHANGED FROM SLICE 5 (start) =====
    -- No decisive previous result -- the first game at this table, a previous
    -- game that ended without a winner (admin, timeout, player_left), or a
    -- changed roster -- so the deal must be cut for.
    -- ===== (M3) CHANGED FROM SLICE 5 (end) =====
    --
    -- NOTHING is dealt here and no dealer is chosen. deal_cut starts as one
    -- empty round for players to draw into; every card and the dealer itself
    -- are decided later, by draw_cut_card, at the moment a player taps.

    -- ===== (D5) CHANGED FOR PHASE 3 E2 (start) =====
    -- 3 and 4 players: only the HOST starts a match that cuts for deal (the
    -- first game, or after one that ended without a winner). 2 players:
    -- anyone at the table, as before. A rematch after a win (the branch
    -- above) needs every player's tap instead, for any number of players.
    if coalesce(v_max, 2) > 2 and public.table_host(p_table_id) is distinct from v_caller then
      raise exception 'Only the host can start the game.';
    end if;
    -- ===== (D5) CHANGED FOR PHASE 3 E2 (end) =====
    begin
      insert into public.games (table_id, created_by, dealer_id, players, status, deal_cut)
      values (p_table_id, v_caller, null, v_players, 'cutting', '[[]]'::jsonb)
      returning id into v_game_id;
    exception when unique_violation then
      select g.id into v_game_id
      from public.games g
      where g.table_id = p_table_id
        and g.status in ('cutting', 'active');
      return v_game_id;
    end;
  end if;

  -- ===== (E1) CHANGED FOR STEP 3 SLICE E (start) =====
  -- THE GAMES CAP: 30 games started per hour per account. Reached only by
  -- the call whose insert just created the game (every path that returns
  -- earlier -- a ready tap still waiting, a game already live, a lost race
  -- -- creates nothing and counts nothing), so exactly one row per new game,
  -- in the same transaction: over the cap, the raise undoes the new game.
  -- Counted for the ACCOUNT: the caller, or -- when the computer's own tap
  -- (computer_start_game_with_deal) starts it -- the human who created the
  -- computer table. Over it: raised, detail 'rate_limited'.
  perform public._attempts_guard(
    case when exists (select 1 from public.computer_accounts ca where ca.user_id = v_caller)
         then (select t.created_by from public.tables t where t.id = p_table_id)
         else v_caller end,
    'game_start', 30, interval '1 hour',
    'You have started 30 games in the last hour. Please take a break and try again a little later.');
  -- ===== (E1) CHANGED FOR STEP 3 SLICE E (end) =====

  -- ===== (M4) CHANGED FROM SLICE 5 (start) =====
  -- NEW MATCH, NEW SCORES. Reached only by the call whose insert succeeded:
  -- both unique_violation handlers above return before this line, so a
  -- second, simultaneous New Game can never wipe a match already under way.
  update public.table_members
  set score = 0,
      last_points = null,
      last_reason = null,
      last_awarded_at = null
  where table_id = p_table_id;
  -- ===== (M4) CHANGED FROM SLICE 5 (end) =====

  return v_game_id;
end;
$$;

revoke all on function public.start_game_with_deal_as(uuid, uuid) from public;
revoke all on function public.start_game_with_deal_as(uuid, uuid) from anon;
revoke all on function public.start_game_with_deal_as(uuid, uuid) from authenticated;

-- ---------------------------------------------------------------------------
-- 2. The nickname lock.
-- ---------------------------------------------------------------------------
create or replace function public.profiles_nickname_lock()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_days integer;
begin
  -- The owner (the SQL Editor, a migration, a security definer function) is
  -- not limited, and may set nickname_changed_at itself -- to null to lift a
  -- lock. Only the client roles are.
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  -- A NEW row (the INSERT of an upsert that found none): never a change, and
  -- the lock time cannot be planted.
  if tg_op = 'INSERT' then
    new.nickname_changed_at := null;
    return new;
  end if;

  -- An UPDATE -- also the DO UPDATE of an upsert (INSERT ... ON CONFLICT (id)
  -- DO UPDATE fires BEFORE UPDATE with OLD = the stored row): the lock time
  -- is this trigger's alone, whatever the client sent.
  new.nickname_changed_at := old.nickname_changed_at;

  -- A REAL change: a different trimmed, lower-cased nickname, from a
  -- non-empty one. The first nickname (from '') is free and starts nothing;
  -- the same nickname again (any case or spacing) is not a change.
  if lower(btrim(coalesce(new.nickname, ''))) is distinct from lower(btrim(coalesce(old.nickname, '')))
     and btrim(coalesce(old.nickname, '')) <> '' then
    if old.nickname_changed_at is not null
       and old.nickname_changed_at > pg_catalog.now() - interval '7 days' then
      v_days := greatest(1, ceil(extract(epoch from (old.nickname_changed_at + interval '7 days' - pg_catalog.now())) / 86400)::integer);
      raise exception using
        message = format('You can change your nickname again in %s day%s.', v_days, case when v_days = 1 then '' else 's' end),
        detail = 'nickname_locked';
    end if;
    new.nickname_changed_at := pg_catalog.now();
  end if;

  return new;
end;
$$;

comment on function public.profiles_nickname_lock() is
  'Step 3 slice E: the profiles BEFORE INSERT OR UPDATE trigger. For the client roles: a new row''s nickname_changed_at is null; on an update the stored value is kept whatever the client sent, and a real nickname change (a different lower(btrim()) value, from a non-empty one) is refused within 7 days of the last (detail nickname_locked), else stamped now(). The owner is not limited. Executable by no client role (a trigger needs none). See docs/sql/slice-e-part2.sql.';

revoke all on function public.profiles_nickname_lock() from public;
revoke all on function public.profiles_nickname_lock() from anon;
revoke all on function public.profiles_nickname_lock() from authenticated;
revoke all on function public.profiles_nickname_lock() from service_role;

drop trigger if exists profiles_nickname_lock on public.profiles;
create trigger profiles_nickname_lock
  before insert or update on public.profiles
  for each row
  execute function public.profiles_nickname_lock();

-- ---------------------------------------------------------------------------
-- 3. The follow churn limit: _follow_user_as (block (E2)) and unfollow_user
--    (block (E3)).
-- ---------------------------------------------------------------------------
create or replace function public._follow_user_as(p_actor uuid, p_target uuid, p_limit int)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  if p_actor is null then
    raise exception 'You must be logged in to follow a player.';
  end if;

  if p_target is null or p_target = p_actor or not public._followable(p_target) then
    return 'not_allowed';
  end if;

  -- One follower at a time (until this transaction ends), so two quick taps
  -- can't both see 49 and both insert.
  perform pg_advisory_xact_lock(hashtextextended('follows:' || p_actor::text, 0));

  if exists (
    select 1 from public.follows f
    where f.follower_id = p_actor and f.followed_id = p_target
  ) then
    return 'following';
  end if;

  -- The cap counts follows of accounts that aren't hidden.
  select count(*) into v_count
  from public.follows f
  where f.follower_id = p_actor
    and not exists (select 1 from public.leaderboard_hidden h where h.user_id = f.followed_id);

  if v_count >= p_limit then
    return 'limit';
  end if;

  -- ===== (E2) CHANGED FOR STEP 3 SLICE E (start) =====
  -- THE CHURN LIMIT: only a REAL follow -- not one already there, not one
  -- refused at the cap or as not allowed (those returned above) -- counts
  -- toward 30 follow/unfollow changes an hour (unfollow_user counts the
  -- other half). Over it: raised, detail 'rate_limited'; nothing is written.
  perform public._attempts_guard(p_actor, 'follow_change', 30, interval '1 hour',
    'You have changed who you follow 30 times in the last hour. Please try again a little later.');
  -- ===== (E2) CHANGED FOR STEP 3 SLICE E (end) =====

  insert into public.follows (follower_id, followed_id)
  values (p_actor, p_target)
  on conflict do nothing;

  return 'following';
end;
$$;

comment on function public._follow_user_as(uuid, uuid, int) is
  'Internal: follow p_target as p_actor with a cap of p_limit. Returns following, limit or not_allowed; raises when p_actor is null, and (step 3 slice E) when a real follow would be the 31st follow/unfollow change in an hour (detail rate_limited). Called by follow_user (auth.uid(), 50) and by follows-verification.sql; no client role can execute it.';

create or replace function public.unfollow_user(p_target uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception 'You must be logged in to unfollow a player.';
  end if;

  -- ===== (E3) CHANGED FOR STEP 3 SLICE E (start) =====
  -- One follower at a time (the same lock as _follow_user_as), and only a
  -- REAL unfollow -- a row that is there -- counts toward the 30
  -- follow/unfollow changes an hour. Unfollowing someone not followed stays
  -- a quiet no-op that counts nothing. Over the limit: raised, detail
  -- 'rate_limited'; nothing is deleted.
  perform pg_advisory_xact_lock(hashtextextended('follows:' || v_actor::text, 0));

  if exists (
    select 1 from public.follows f
    where f.follower_id = v_actor and f.followed_id = p_target
  ) then
    perform public._attempts_guard(v_actor, 'follow_change', 30, interval '1 hour',
      'You have changed who you follow 30 times in the last hour. Please try again a little later.');

    delete from public.follows
    where follower_id = v_actor
      and followed_id = p_target;
  end if;
  -- ===== (E3) CHANGED FOR STEP 3 SLICE E (end) =====

  return 'not_following';
end;
$$;

comment on function public.unfollow_user(uuid) is
  'Stop following p_target as the signed-in player. Always returns not_following (idempotent). A real unfollow counts toward 30 follow/unfollow changes an hour (step 3 slice E; over it: raised, detail rate_limited); a no-op counts nothing. Raises when nobody is logged in.';

-- (Their grants are unchanged: create or replace keeps them.)

-- ---------------------------------------------------------------------------
-- 4. The avatar names: the INSERT and UPDATE policies on storage.objects.
-- ---------------------------------------------------------------------------
drop policy if exists "Users can upload their own avatar" on storage.objects;
create policy "Users can upload their own avatar"
  on storage.objects for insert
  with check (
    bucket_id = 'avatars'
    and auth.uid()::text = (storage.foldername(name))[1]
    and name in (auth.uid()::text || '/avatar.png',
                 auth.uid()::text || '/avatar.jpg',
                 auth.uid()::text || '/avatar.jpeg',
                 auth.uid()::text || '/avatar.webp')
  );

drop policy if exists "Users can update their own avatar" on storage.objects;
create policy "Users can update their own avatar"
  on storage.objects for update
  using (
    bucket_id = 'avatars'
    and auth.uid()::text = (storage.foldername(name))[1]
    and name in (auth.uid()::text || '/avatar.png',
                 auth.uid()::text || '/avatar.jpg',
                 auth.uid()::text || '/avatar.jpeg',
                 auth.uid()::text || '/avatar.webp')
  )
  with check (
    bucket_id = 'avatars'
    and auth.uid()::text = (storage.foldername(name))[1]
    and name in (auth.uid()::text || '/avatar.png',
                 auth.uid()::text || '/avatar.jpg',
                 auth.uid()::text || '/avatar.jpeg',
                 auth.uid()::text || '/avatar.webp')
  );

commit;
