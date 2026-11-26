-- Moderation, slice M3: ROLLBACK of PART 1 (docs/sql/moderation-m3-part1.sql).
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- WHEN: only after docs/sql/moderation-m3-part2-rollback.sql (or if part 2
-- was never run): part 2's join_table_by_code and watch_table call
-- _is_kicked_from_table, which this file drops. The guard refuses
-- otherwise. Roll the app back first (it calls kick_player and listens on
-- kicks: topics; an old tab would just see its Kick fail).
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD: join_table_by_code and watch_table are M1 part 2's bodies
--      (part 2 is not in), else it raises and changes nothing.
--   1. Drops the "table kicks: people at the table receive" policy on
--      realtime.messages (the two table-chat policies stay).
--   2. Drops admin_recent_kicks, kick_topic_allows, kick_player,
--      _send_kick_notice and _is_kicked_from_table.
--   3. Drops public.table_kicks. ONE-WAY: its rows (who was kicked from
--      where) are gone, so the kicked could join and watch those tables
--      again -- except that a kicked SPECTATOR keeps removed_at (as after
--      remove_spectator), so they still can't watch; and a kicked player's
--      ended game stays ended.
--   4. attempt_log: deletes the 'kick' rows, then
--      attempt_log_action_check goes back to the eight actions (M1 part 1's
--      constraint and comment). The kick rows must go first or the
--      constraint can't be re-added.
--
-- NOT TOUCHED: everything moderation-m3-part1.sql did not create.

begin;

do $$
declare
  v_rec record;
  v_txt text;
begin
  for v_rec in
    select * from (values
      ('public.join_table_by_code(text, boolean, uuid)', 'cf40593ee5afda235144a13e38d27f4a', 'c3ee9ced2e1033f9c068acd3325c5583'),
      ('public.watch_table(text, uuid)', '5bf6065de215d92a02af63d035c7f910', '2aa5f9c37d65271f3b4619e58c171ea0')
    ) as t(fn, lf, crlf)
  loop
    select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is null or v_txt not in (v_rec.lf, v_rec.crlf) then
      raise exception 'STOP: % has body md5 %, not M1 part 2''s % / %. Run docs/sql/moderation-m3-part2-rollback.sql first (part 2 calls _is_kicked_from_table). Nothing was changed.', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf, v_rec.crlf;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The policy.
-- ---------------------------------------------------------------------------
drop policy if exists "table kicks: people at the table receive" on realtime.messages;

-- ---------------------------------------------------------------------------
-- 2. The functions.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_recent_kicks(integer);
drop function if exists public.kick_topic_allows(text);
drop function if exists public.kick_player(uuid, uuid);
drop function if exists public._send_kick_notice(uuid, jsonb);
drop function if exists public._is_kicked_from_table(uuid, uuid);

-- ---------------------------------------------------------------------------
-- 3. The table (ONE-WAY: its rows are gone).
-- ---------------------------------------------------------------------------
drop table if exists public.table_kicks;

-- ---------------------------------------------------------------------------
-- 4. attempt_log: M1 part 1's eight actions.
-- ---------------------------------------------------------------------------
delete from public.attempt_log
where action = 'kick';

alter table public.attempt_log drop constraint attempt_log_action_check;
alter table public.attempt_log
  add constraint attempt_log_action_check
  check (action in ('create_table', 'create_computer_table', 'join', 'watch', 'code_guess',
                    'game_start', 'follow_change', 'block_change'));

comment on table public.attempt_log is
  'Rate limits (step 3, slices A and E; moderation M1): one row per counted action -- a table created (create_table), a computer game started (create_computer_table), a join, a new watch, a game started (game_start), a real follow or unfollow (follow_change), a real block or unblock (block_change) (success true), or a wrong table code (code_guess, success false). Read and written only by security definer functions through the _attempts_* / _code_guess* helpers. Rows older than 7 days are deleted hourly by cleanup_attempt_log() (pg_cron job attempt-log-cleanup). RLS on, no policies, no grants. See docs/sql/join-create.sql, slice-e-part1.sql and moderation-m1-part1.sql.';

notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  to_regclass('public.table_kicks') is null as table_kicks_gone,
  to_regprocedure('public.kick_player(uuid, uuid)') is null as kick_player_gone,
  to_regprocedure('public._is_kicked_from_table(uuid, uuid)') is null as helper_gone,
  (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages') as realtime_messages_policies,
  (select pg_get_constraintdef(con.oid) from pg_constraint con
   where con.conrelid = 'public.attempt_log'::regclass and con.conname = 'attempt_log_action_check') as attempt_log_action_check;
