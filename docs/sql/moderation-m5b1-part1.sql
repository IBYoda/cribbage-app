-- Moderation, slice M5 (b1): GAME STATE AND PLAYS on the table's
-- server-pushed topic. PART 1 (the only part): ADD-ONLY (safe before any app
-- change). Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M5b1):
--   1. docs/sql/moderation-m5b1-precheck.sql      (read-only; no STOP rows,
--      state "before part 1")
--   2. docs/sql/moderation-m5b1-part1.sql         (THIS FILE)
--   3. docs/sql/moderation-m5b1-verification.sql  ("ALL n CHECKS PASSED")
--   4. the suites to re-run (moderation-m5b1-precheck.sql's header)
--   5. the app (a later step): re-read the game on each 'game' event, the
--      stale-plays fix; the old postgres_changes listeners stay one release
--   Rollback: docs/sql/moderation-m5b1-part1-rollback.sql.
--
-- WHAT WALT DECIDED (M5b1, 2026-11-26): every change to a game -- a deal, a
-- discard, a play or a go, a counting step, a Next Hand, a win claim, the
-- end of a game for any reason -- sends ONE event per transaction on the
-- table's private topic table:<table_id>, carrying ids and a version only:
--   { event: 'game', game_id, hand_no, state_version, last_play_seq }
-- (Realtime adds its own "id" to the stored copy). Never a card, a hand, the
-- crib or the deck: the client re-reads the game itself. Score changes
-- (table_members) are slice (b2), later. The old postgres_changes listeners
-- stay one more release: NOTHING leaves the supabase_realtime publication.
-- Computer tables get the same events (the one human is seated there, so
-- table_topic_allows lets them receive; the app joins in its next step).
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold): M5a is in
--      (table_topic_allows, _send_table_event, the table events policy);
--      realtime.send(jsonb, text, text, boolean) exists; games has no
--      state_version column yet; none of this file's three function names
--      or three trigger names exists; games_snapshot_result_on_win exists.
--      NOT RE-RUNNABLE BY DESIGN: a second run STOPs at the guard. A failed
--      run changes nothing.
--   1. public.games.state_version bigint not null default 0 (a metadata
--      change: no table rewrite).
--   2. Functions, all SECURITY DEFINER with search_path '', executable by
--      no client role:
--        _bump_game_state_version() trigger
--          BEFORE INSERT OR UPDATE on games: an INSERT starts at 0; every
--          UPDATE sets state_version to the stored value + 1, WHATEVER the
--          statement wrote -- so the admin page's force-end (a client UPDATE
--          under the admins-only policy) can't set or lower it either. Only
--          the row being written is touched: no other table, no lock.
--        _send_game_event(p_table_id uuid, p_payload jsonb) void
--          realtime.send(p_payload, 'game', 'table:<table_id>', true)
--          inside its own BEGIN ... EXCEPTION WHEN OTHERS THEN NULL block.
--        _game_event_at_commit() trigger
--          The deferred constraint triggers below call it at COMMIT. The
--          first call for a game in a transaction sets a transaction-local
--          flag (set_config('m5b1.sent_<game id, no dashes>', 'y', true))
--          and sends one event built from the FINAL committed-to-be state
--          (the games row and max(game_plays.seq) read at that moment);
--          every later call for that game in the same transaction sees the
--          flag and does nothing. Its whole body is inside its own
--          exception block: a deferred trigger that raised would abort the
--          COMMIT, so nothing in it may ever raise.
--   3. Three triggers:
--        games_state_version          BEFORE INSERT OR UPDATE on games, ROW
--        games_zz_game_event          CONSTRAINT TRIGGER AFTER INSERT OR UPDATE on games
--        game_plays_zz_game_event     CONSTRAINT TRIGGER AFTER INSERT OR DELETE on game_plays
--      both constraint triggers DEFERRABLE INITIALLY DEFERRED, FOR EACH ROW
--      (they fire at COMMIT, after every statement of the transaction, so
--      the event describes the final state; a rolled-back transaction or
--      subtransaction fires nothing). Named to sort after
--      games_snapshot_result_on_win (which stays an ordinary AFTER UPDATE
--      trigger and fires first, at its statement).
--
-- WHAT IS COVERED, with no function body changed: every write of a game
-- goes through games (an INSERT or UPDATE) and/or game_plays, so the
-- triggers see all of them -- the eight _as game functions and their
-- wrappers (including the computer_* ones), award_points' games update,
-- claim_win / clear_win_claim / confirm_win, leave_table,
-- leave_computer_table, kick_player, end_timed_out_sessions,
-- end_table_when_empty, end_empty_tables (several games in one transaction:
-- one event EACH), _one_table_rule, the admin's client UPDATE. A deal's
-- game_hands / game_cribs / game_decks writes always come with a games
-- write in the same transaction (start, acknowledge_deal_cut, next_hand,
-- discard_to_crib), so those secret tables need no trigger. next_hand's
-- DELETE of game_plays is covered (it also updates games: one event).
-- snapshot_game_result (games_snapshot_result_on_win) writes only
-- game_results; the win's own games UPDATE sends the event.
--
-- md5 of the new bodies (carriage returns removed; LF), and with CRLF line
-- ends (this file as committed):
--   _bump_game_state_version   35314b3677dd7b0b39a2ca32ee29e7c3 / 4f71b4ada67ffdca55e719d3c3ef42a4
--   _send_game_event           462c8068b6c7a183ca76fa18fa6b7264 / 0c46a770182717bfd6ac493fe037503b
--   _game_event_at_commit      cce9d688120f3dc2c155503270fe11ee / 196fb6e2ca35c7a72513b95dc078e7bf
--
-- NOT TOUCHED: every existing function body (no fingerprint changes: the
-- eight _as bodies and wrappers of computer-c1-verification.sql, the four
-- of end-empty-tables, M3's kick_player, M5a's five), every existing
-- trigger, policy and grant, the supabase_realtime publication, the tables
-- row (no roster_version bump: game events don't change the people).
--
-- ROLLBACK: docs/sql/moderation-m5b1-part1-rollback.sql.

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard.
-- ---------------------------------------------------------------------------
do $$
declare
  v_txt text;
begin
  -- M5a is in: the topic rule, its send helper and its receive policy.
  if to_regprocedure('public.table_topic_allows(text)') is null
     or to_regprocedure('public._send_table_event(uuid, text, bigint)') is null
     or not exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages'
                      and p.policyname = 'table events: people at the table receive') then
    raise exception 'STOP: moderation M5a part 1 is not in (table_topic_allows, _send_table_event, the table events policy). Nothing was changed.';
  end if;

  if to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null then
    raise exception 'STOP: realtime.send(jsonb, text, text, boolean) does not exist. Nothing was changed.';
  end if;

  if not exists (select 1 from pg_trigger tg where tg.tgrelid = 'public.games'::regclass
                   and tg.tgname = 'games_snapshot_result_on_win' and not tg.tgisinternal) then
    raise exception 'STOP: games_snapshot_result_on_win is missing (leaderboard-l1-game-results.sql). Nothing was changed.';
  end if;

  -- Not run before.
  if exists (select 1 from pg_attribute a where a.attrelid = 'public.games'::regclass and a.attname = 'state_version' and not a.attisdropped) then
    raise exception 'STOP: public.games.state_version already exists (this file already ran?). Nothing was changed.';
  end if;
  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname) into v_txt
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('_bump_game_state_version', '_send_game_event', '_game_event_at_commit');
  if v_txt is not null then
    raise exception 'STOP: these functions already exist: %. Nothing was changed.', v_txt;
  end if;
  select string_agg(tg.tgname::text, ', ' order by tg.tgname) into v_txt
  from pg_trigger tg
  where not tg.tgisinternal
    and tg.tgname in ('games_state_version', 'games_zz_game_event', 'game_plays_zz_game_event');
  if v_txt is not null then
    raise exception 'STOP: these triggers already exist: %. Nothing was changed.', v_txt;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. games.state_version.
-- ---------------------------------------------------------------------------
alter table public.games add column state_version bigint not null default 0;

comment on column public.games.state_version is
  'Moderation M5b1: 0 for a new game, then +1 on EVERY update of the row (the games_state_version BEFORE trigger, whatever the statement wrote: no client can set or lower it). Sent in every ''game'' event on table:<table_id>; a client keeps the highest it has seen per game and drops older events. See docs/sql/moderation-m5b1-part1.sql.';

-- ---------------------------------------------------------------------------
-- 2. The functions.
-- ---------------------------------------------------------------------------
create or replace function public._bump_game_state_version()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  -- Only this row: no other table, no lock. Whatever the statement wrote
  -- into state_version is replaced.
  if tg_op = 'INSERT' then
    new.state_version := 0;
  else
    new.state_version := old.state_version + 1;
  end if;
  return new;
end;
$$;

comment on function public._bump_game_state_version() is
  'Internal (moderation M5b1): the games_state_version BEFORE INSERT OR UPDATE trigger. A new game starts at state_version 0; every update sets it to the stored value + 1, whatever the statement wrote. No client role can execute it. See docs/sql/moderation-m5b1-part1.sql.';

revoke all on function public._bump_game_state_version() from public;
revoke all on function public._bump_game_state_version() from anon;
revoke all on function public._bump_game_state_version() from authenticated;
revoke all on function public._bump_game_state_version() from service_role;


create or replace function public._send_game_event(p_table_id uuid, p_payload jsonb)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  -- A private Realtime broadcast on the table's topic, event 'game'. Its
  -- own subtransaction: a failed send is dropped, never raised.
  begin
    perform realtime.send(p_payload, 'game', 'table:' || p_table_id::text, true);
  exception when others then
    null;
  end;
end;
$$;

comment on function public._send_game_event(uuid, jsonb) is
  'Internal (moderation M5b1): realtime.send(payload, ''game'', ''table:<table_id>'', true) inside its own exception block (a failed send is dropped). Called only by _game_event_at_commit. No client role can execute it. See docs/sql/moderation-m5b1-part1.sql.';

revoke all on function public._send_game_event(uuid, jsonb) from public;
revoke all on function public._send_game_event(uuid, jsonb) from anon;
revoke all on function public._send_game_event(uuid, jsonb) from authenticated;
revoke all on function public._send_game_event(uuid, jsonb) from service_role;


create or replace function public._game_event_at_commit()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_game_id uuid;
  v_flag text;
  v_game record;
  v_last integer;
begin
  -- Fired at COMMIT (deferred). NOTHING here may raise: a deferred trigger
  -- that raised would abort the commit of the play itself.
  begin
    if tg_table_name = 'games' then
      v_game_id := new.id;
    elsif tg_op = 'DELETE' then
      v_game_id := old.game_id;
    else
      v_game_id := new.game_id;
    end if;
    if v_game_id is null then
      return null;
    end if;

    -- ONE EVENT PER GAME PER TRANSACTION: the first call sets a
    -- transaction-local flag; the rest see it and stop.
    v_flag := 'm5b1.sent_' || replace(v_game_id::text, '-', '');
    if coalesce(pg_catalog.current_setting(v_flag, true), '') = 'y' then
      return null;
    end if;
    perform pg_catalog.set_config(v_flag, 'y', true);

    -- The FINAL state of this transaction: read now, at commit. A game
    -- deleted in the same transaction sends nothing.
    select g.table_id, g.hand_no, g.state_version
    into v_game
    from public.games g
    where g.id = v_game_id;
    if not found then
      return null;
    end if;
    select coalesce(max(gp.seq), 0)
    into v_last
    from public.game_plays gp
    where gp.game_id = v_game_id;

    -- Ids and the version ONLY.
    perform public._send_game_event(v_game.table_id, pg_catalog.jsonb_build_object(
      'event', 'game',
      'game_id', v_game_id,
      'hand_no', v_game.hand_no,
      'state_version', v_game.state_version,
      'last_play_seq', v_last));
  exception when others then
    null;
  end;
  return null;
end;
$$;

comment on function public._game_event_at_commit() is
  'Internal (moderation M5b1): the games_zz_game_event and game_plays_zz_game_event deferred constraint triggers. At COMMIT, the first call for a game sets a transaction-local flag (m5b1.sent_<game id without dashes>) and sends ONE ''game'' event {event, game_id, hand_no, state_version, last_play_seq} on table:<table_id>, read from the final state; later calls for the same game do nothing. Never raises (its whole body is inside an exception block). No client role can execute it. See docs/sql/moderation-m5b1-part1.sql.';

revoke all on function public._game_event_at_commit() from public;
revoke all on function public._game_event_at_commit() from anon;
revoke all on function public._game_event_at_commit() from authenticated;
revoke all on function public._game_event_at_commit() from service_role;

-- ---------------------------------------------------------------------------
-- 3. The triggers.
-- ---------------------------------------------------------------------------
create trigger games_state_version
  before insert or update on public.games
  for each row
  execute function public._bump_game_state_version();

create constraint trigger games_zz_game_event
  after insert or update on public.games
  deferrable initially deferred
  for each row
  execute function public._game_event_at_commit();

create constraint trigger game_plays_zz_game_event
  after insert or delete on public.game_plays
  deferrable initially deferred
  for each row
  execute function public._game_event_at_commit();

-- PostgREST: reload the schema cache now (the new column).
notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  exists (select 1 from pg_attribute a where a.attrelid = 'public.games'::regclass and a.attname = 'state_version' and not a.attisdropped) as state_version_column,
  (select count(*) from pg_trigger tg where not tg.tgisinternal
     and tg.tgname in ('games_state_version', 'games_zz_game_event', 'game_plays_zz_game_event')) as game_event_triggers,
  (select count(*) from pg_trigger tg where not tg.tgisinternal and tg.tgdeferrable and tg.tginitdeferred
     and tg.tgname in ('games_zz_game_event', 'game_plays_zz_game_event')) as deferred_at_commit,
  has_function_privilege('authenticated', 'public._game_event_at_commit()', 'EXECUTE') as trigger_fn_for_authenticated,
  (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages') as realtime_messages_policies;
