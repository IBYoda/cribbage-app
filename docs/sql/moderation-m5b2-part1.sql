-- Moderation, slice M5 (b2): SCORES on the table's server-pushed topic.
-- PART 1 (the only part): ADD-ONLY (safe before any app change). Run in the
-- Supabase Dashboard -> SQL Editor. Kept here for reference/history; this
-- project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M5b2):
--   1. docs/sql/moderation-m5b2-precheck.sql      (read-only; no STOP rows,
--      state "before part 1")
--   2. docs/sql/moderation-m5b2-part1.sql         (THIS FILE)
--   3. docs/sql/moderation-m5b2-verification.sql  ("ALL n CHECKS PASSED")
--   4. the suites to re-run (moderation-m5b2-precheck.sql's header)
--   5. the app (a later step): REPAIR ONLY -- on a 'scores' event, wait about
--      1.5 s; if the screen still doesn't show that award, re-read the
--      roster. The old table_members listener stays the live path.
--   Rollback: docs/sql/moderation-m5b2-part1-rollback.sql.
--
-- WHAT WALT DECIDED (M5b2, 2026-11-26): a score change sends ONE 'scores'
-- event per table per transaction on the table's private topic
-- table:<table_id>:
--   { event: 'scores', game_id, award_ms, user_id, points, reason }
-- (Realtime adds its own "id" to the stored copy). No names, no cards.
--   game_id   the table's NEWEST game (by created_at): the live one -- or,
--             at the award that wins, the game that award just ended in the
--             same transaction -- or null when the table never had a game.
--             (A live-only game_id would be null on the winning award and
--             look like a reset; the newest game keeps it the same game.)
--             A DIFFERENT game_id is the reset signal.
--   award_ms  the newest last_awarded_at across the table's members, in
--             whole milliseconds since the epoch (rounded down, as a
--             browser's Date.parse reads the same time); 0 when none (after
--             a reset).
--   user_id, points, reason   the row holding that newest last_awarded_at:
--             the SCORER (award_points sets last_points, last_reason and
--             last_awarded_at on the scorer's row only; a Teams partner's
--             row gets the score only). null when none. For the later move
--             of the "19" splash and its sound off the old listener.
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold): M5a and M5b1 are
--      in (the table events policy, _game_event_at_commit and its two
--      triggers); realtime.send exists; none of this file's two function
--      names or its trigger name exists. NOT RE-RUNNABLE BY DESIGN: a second
--      run STOPs at the guard. A failed run changes nothing.
--   1. Functions, both SECURITY DEFINER with search_path '', executable by
--      no client role:
--        _send_scores_event(p_table_id uuid, p_payload jsonb) void
--          realtime.send(p_payload, 'scores', 'table:<table_id>', true)
--          inside its own BEGIN ... EXCEPTION WHEN OTHERS THEN NULL block.
--        _scores_event_at_commit() trigger
--          Called at COMMIT by the deferred trigger below. The first call
--          for a table in a transaction sets a transaction-local flag
--          (set_config('m5b2.sent_<table id, no dashes>', 'y', true)) and
--          sends one event built from the FINAL state (the newest game, the
--          newest award, read at that moment); later calls for that table in
--          the same transaction see the flag and do nothing. Its whole body
--          is inside its own exception block: a deferred trigger that raised
--          would abort the COMMIT of the award itself, so nothing in it may
--          ever raise. It only READS table_members and games: it writes no
--          table and takes no lock (and never touches the tables row).
--   2. One trigger:
--        table_members_zz_scores_event   CONSTRAINT TRIGGER
--          AFTER UPDATE OF score, last_points, last_reason, last_awarded_at
--          ON table_members, DEFERRABLE INITIALLY DEFERRED, FOR EACH ROW
--      It fires at COMMIT, after every statement of the transaction; a
--      rolled-back transaction or subtransaction fires nothing. Its name
--      sorts BEFORE M5a's table_members_zz_table_event (M5a's checks want
--      nothing AFTER sorting after theirs); deferred triggers fire at commit
--      anyway, after every immediate trigger.
--
-- WHO WRITES THOSE FOUR COLUMNS (and so sends a 'scores' event): only
-- award_points (every scoring play, his heels, every count step including a
-- 0-point "19", the win) and the score reset when a game starts
-- (start_game_with_deal_as: score 0, the three last_* null -- one event,
-- award_ms 0, user_id / points / reason null, game_id the NEW game). A seat
-- move (set_seat writes seat only), a join (INSERT), a leave or a kick
-- (DELETE) and a game change without points send none. The testing-force-*
-- scripts (owner tools) would send one too.
--
-- md5 of the new bodies (carriage returns removed; LF), and with CRLF line
-- ends (this file as committed):
--   _send_scores_event        cf9d6f31090605e8e42ca7a26aae1d7d / 5987acd250544278295ae292b85734e3
--   _scores_event_at_commit   d06cc5e9fb12f0b0697dd4b4e43bd8a9 / a36837ee0f0167d3fd240346b34987a7
--
-- NOT TOUCHED: every existing function body (no fingerprint changes: the
-- eight _as bodies and wrappers of computer-c1-verification.sql, the four
-- of end-empty-tables, M3's kick_player, M5a's five, M5b1's three,
-- award_points), every existing trigger, policy and grant, every column,
-- the supabase_realtime publication, the tables row.
--
-- ROLLBACK: docs/sql/moderation-m5b2-part1-rollback.sql.

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard.
-- ---------------------------------------------------------------------------
do $$
declare
  v_txt text;
begin
  if to_regprocedure('public.table_topic_allows(text)') is null
     or not exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages'
                      and p.policyname = 'table events: people at the table receive') then
    raise exception 'STOP: moderation M5a part 1 is not in (table_topic_allows, the table events policy). Nothing was changed.';
  end if;
  if to_regprocedure('public._game_event_at_commit()') is null
     or not exists (select 1 from pg_trigger tg where tg.tgrelid = 'public.games'::regclass and tg.tgname = 'games_zz_game_event' and not tg.tgisinternal) then
    raise exception 'STOP: moderation M5b1 part 1 is not in (_game_event_at_commit, games_zz_game_event). Nothing was changed.';
  end if;
  if to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null then
    raise exception 'STOP: realtime.send(jsonb, text, text, boolean) does not exist. Nothing was changed.';
  end if;
  if to_regprocedure('public.award_points(uuid, uuid, integer, text)') is null then
    raise exception 'STOP: public.award_points(uuid, uuid, integer, text) is missing. Nothing was changed.';
  end if;

  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname) into v_txt
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('_send_scores_event', '_scores_event_at_commit');
  if v_txt is not null then
    raise exception 'STOP: these functions already exist: %. This file already ran? Nothing was changed.', v_txt;
  end if;
  if exists (select 1 from pg_trigger tg where tg.tgname = 'table_members_zz_scores_event' and not tg.tgisinternal) then
    raise exception 'STOP: the trigger table_members_zz_scores_event already exists (this file already ran?). Nothing was changed.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The functions.
-- ---------------------------------------------------------------------------
create or replace function public._send_scores_event(p_table_id uuid, p_payload jsonb)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  -- A private Realtime broadcast on the table's topic, event 'scores'. Its
  -- own subtransaction: a failed send is dropped, never raised.
  begin
    perform realtime.send(p_payload, 'scores', 'table:' || p_table_id::text, true);
  exception when others then
    null;
  end;
end;
$$;

comment on function public._send_scores_event(uuid, jsonb) is
  'Internal (moderation M5b2): realtime.send(payload, ''scores'', ''table:<table_id>'', true) inside its own exception block (a failed send is dropped). Called only by _scores_event_at_commit. No client role can execute it. See docs/sql/moderation-m5b2-part1.sql.';

revoke all on function public._send_scores_event(uuid, jsonb) from public;
revoke all on function public._send_scores_event(uuid, jsonb) from anon;
revoke all on function public._send_scores_event(uuid, jsonb) from authenticated;
revoke all on function public._send_scores_event(uuid, jsonb) from service_role;


create or replace function public._scores_event_at_commit()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_table_id uuid;
  v_flag text;
  v_game_id uuid;
  v_user_id uuid;
  v_points integer;
  v_reason text;
  v_at timestamptz;
begin
  -- Fired at COMMIT (deferred). NOTHING here may raise: a deferred trigger
  -- that raised would abort the commit of the award itself.
  begin
    v_table_id := new.table_id;
    if v_table_id is null then
      return null;
    end if;

    -- ONE EVENT PER TABLE PER TRANSACTION: the first call sets a
    -- transaction-local flag; the rest see it and stop.
    v_flag := 'm5b2.sent_' || replace(v_table_id::text, '-', '');
    if coalesce(pg_catalog.current_setting(v_flag, true), '') = 'y' then
      return null;
    end if;
    perform pg_catalog.set_config(v_flag, 'y', true);

    -- The FINAL state of this transaction, read now, at commit: the
    -- table's newest game (live, or the one this transaction's winning
    -- award just ended), and the newest award (its scorer's row).
    select g.id
    into v_game_id
    from public.games g
    where g.table_id = v_table_id
    order by g.created_at desc, g.id desc
    limit 1;

    select tm.user_id, tm.last_points, tm.last_reason, tm.last_awarded_at
    into v_user_id, v_points, v_reason, v_at
    from public.table_members tm
    where tm.table_id = v_table_id
      and tm.last_awarded_at is not null
    order by tm.last_awarded_at desc, tm.user_id desc
    limit 1;

    -- Ids, numbers and the reason ONLY.
    perform public._send_scores_event(v_table_id, pg_catalog.jsonb_build_object(
      'event', 'scores',
      'game_id', v_game_id,
      'award_ms', coalesce(floor(extract(epoch from v_at) * 1000)::bigint, 0),
      'user_id', v_user_id,
      'points', v_points,
      'reason', v_reason));
  exception when others then
    null;
  end;
  return null;
end;
$$;

comment on function public._scores_event_at_commit() is
  'Internal (moderation M5b2): the table_members_zz_scores_event deferred constraint trigger. At COMMIT, the first call for a table sets a transaction-local flag (m5b2.sent_<table id without dashes>) and sends ONE ''scores'' event {event, game_id, award_ms, user_id, points, reason} on table:<table_id>, read from the final state (the newest game; the newest award and its scorer); later calls for the same table do nothing. Reads only; never raises. No client role can execute it. See docs/sql/moderation-m5b2-part1.sql.';

revoke all on function public._scores_event_at_commit() from public;
revoke all on function public._scores_event_at_commit() from anon;
revoke all on function public._scores_event_at_commit() from authenticated;
revoke all on function public._scores_event_at_commit() from service_role;

-- ---------------------------------------------------------------------------
-- 2. The trigger.
-- ---------------------------------------------------------------------------
create constraint trigger table_members_zz_scores_event
  after update of score, last_points, last_reason, last_awarded_at on public.table_members
  deferrable initially deferred
  for each row
  execute function public._scores_event_at_commit();

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  exists (select 1 from pg_trigger tg where tg.tgname = 'table_members_zz_scores_event' and not tg.tgisinternal
            and tg.tgdeferrable and tg.tginitdeferred) as scores_trigger_at_commit,
  has_function_privilege('authenticated', 'public._scores_event_at_commit()', 'EXECUTE') as trigger_fn_for_authenticated,
  has_function_privilege('authenticated', 'public._send_scores_event(uuid, jsonb)', 'EXECUTE') as send_fn_for_authenticated,
  (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages') as realtime_messages_policies;
