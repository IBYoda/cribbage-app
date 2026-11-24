-- Step 3, slice C: END EMPTY TABLES. The PRE-CHECK (read-only). Run in the
-- Supabase Dashboard -> SQL Editor before docs/sql/end-empty-tables.sql. It
-- reads only; it changes nothing.
--
-- STATUS: written, NOT RUN yet.
--
-- RUN ORDER (slice C):
--   0. the app build with the 'empty' message (tableEndedMessage in
--      lib/oneTable.ts) is live FIRST: before it, a table ended as 'empty'
--      reads "This table has been ended by an admin." on a player's screen.
--   1. docs/sql/end-empty-tables-precheck.sql      (this file, read-only)
--   2. docs/sql/end-empty-tables.sql               (additive, one transaction)
--   3. docs/sql/end-empty-tables-verification.sql  (rolled back; the final
--                                                    message is the verdict)
--   4. docs/sql/end-empty-tables-manual-race-test.md (two SQL Editor tabs)
--   If it has to come out: docs/sql/end-empty-tables-rollback.sql.
--
-- ONE query, so the editor shows every line in one result. Columns: section,
-- item, value, note. A note starting with STOP means: do not run
-- end-empty-tables.sql; paste the result back first. A note starting with
-- LEGACY is information for the one-time cleanup, not a blocker.
--
-- WHAT IT LOOKS FOR
--   fn       the four bodies slice C must NOT change (it adds triggers beside
--            them instead), by the md5 of the LIVE body (pg_proc.prosrc),
--            against the committed texts, LF and CRLF:
--              leave_table             9c15b86bd236e9ffb108e9318251c5b8 (LF)
--                                      3ad133b3e6308ad008237fa64bdb7cfa (CRLF)
--                                      (phase2-slice-5-cut-before-deal.sql)
--              end_timed_out_sessions  d46b95e2f27b93f2707d050de560720f (LF)
--                                      7839dbdba9e2ff400430ed457743507c (CRLF)
--                                      (phase2-slice-5-cut-before-deal.sql)
--              assign_table_seat       5f2ea7a318c9f3a6dc7552f6bf7e0380 (LF)
--                                      ef28d7cadc8a1e0688d181b1af9c57bb (CRLF)
--                                      (phase3-e1-seating.sql)
--              table_host              fca691d91d3aadf74972906e75019646 (LF)
--                                      172b8403111f6b381e34eda706555f2d (CRLF)
--                                      (phase3-e1-seating.sql)
--            Anything else: STOP. The live body is not the file's (the lesson
--            of create_computer_table, slice A): capture it first with
--              select pg_get_functiondef('public.leave_table(uuid)'::regprocedure);
--            (the same for the others) and paste it back. The triggers'
--            design reads these bodies (what leave_table deletes, in which
--            order it locks), so it must be the text the design assumed.
--   names    the objects slice C adds are absent (PRESENT only on a re-run);
--            no other public function has "chat" in its name.
--   reason   tables_ended_reason_check's current text (expected: admin,
--            timeout); ended_reason values in use; status values in use
--            (expected only open/ended: the triggers read "open").
--   triggers every non-internal trigger on table_members, in firing order
--            (alphabetical within BEFORE / AFTER): the new BEFORE INSERT
--            trigger table_members_require_open must sort AFTER
--            table_members_assign_seat ('r' > 'a'), so it runs once the seat
--            trigger holds the tables row lock.
--   cron     pg_cron's extension version, whether cron.job exists, and the
--            jobs end-timed-out-sessions / end-empty-tables (read through
--            query_to_xml, so this query still parses without pg_cron).
--   computer computer_accounts exists (the triggers count only human seats).
--   legacy   open tables with no non-computer seat: how many, how many older
--            than 10 minutes (the one-time cleanup and the sweep end exactly
--            those), human vs computer tables, live games and spectator rows
--            on them.

select section, item, value, note
from (
  -- ---- The four bodies slice C must not change -------------------------------
  select 1 as s, x.o, 'fn' as section, x.fn || ': md5 of the live body' as item,
         coalesce((select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(x.sig)), '(missing)') as value,
         case (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure(x.sig))
              when x.lf then x.src || ' (LF): as expected'
              when x.crlf then x.src || ' (CRLF): as expected'
              else 'STOP: not ' || x.src || '''s text (or missing). Capture it first: select pg_get_functiondef(''' || x.sig || '''::regprocedure); and paste the result back'
         end as note
  from (values
    (1, 'leave_table', 'public.leave_table(uuid)', '9c15b86bd236e9ffb108e9318251c5b8', '3ad133b3e6308ad008237fa64bdb7cfa', 'phase2-slice-5-cut-before-deal.sql'),
    (2, 'end_timed_out_sessions', 'public.end_timed_out_sessions()', 'd46b95e2f27b93f2707d050de560720f', '7839dbdba9e2ff400430ed457743507c', 'phase2-slice-5-cut-before-deal.sql'),
    (3, 'assign_table_seat', 'public.assign_table_seat()', '5f2ea7a318c9f3a6dc7552f6bf7e0380', 'ef28d7cadc8a1e0688d181b1af9c57bb', 'phase3-e1-seating.sql'),
    (4, 'table_host', 'public.table_host(uuid)', 'fca691d91d3aadf74972906e75019646', '172b8403111f6b381e34eda706555f2d', 'phase3-e1-seating.sql')
  ) as x(o, fn, sig, lf, crlf, src)

  union all
  select 1, 5, 'fn', 'leave_table: settings and grants',
         (select case when p.prosecdef then 'definer' else 'invoker' end || ' | ' || coalesce(p.proconfig::text, 'no config')
                 || ' | authenticated ' || has_function_privilege('authenticated', p.oid, 'execute')::text
                 || ', anon ' || has_function_privilege('anon', p.oid, 'execute')::text
          from pg_proc p where p.oid = to_regprocedure('public.leave_table(uuid)')),
         'expected: definer | {search_path=public} | authenticated true, anon false (unchanged by slice C)'

  union all
  -- ---- Names slice C adds ---------------------------------------------------------
  select 2, 1, 'names', 'slice C objects already present',
         coalesce((select string_agg(n, ', ' order by n) from (
           select p.proname::text as n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
           where ns.nspname = 'public' and p.proname in ('end_empty_tables', 'end_table_when_empty', 'require_open_table')
           union all
           select tg.tgname::text from pg_trigger tg
           where tg.tgrelid = 'public.table_members'::regclass and tg.tgname in ('table_members_end_when_empty', 'table_members_require_open')
         ) y), '(none)'),
         'expected (none) on a first run; all five on a re-run (safe)'

  union all
  select 2, 2, 'names', 'other public functions with "chat" in the name',
         coalesce((select string_agg(p.proname::text, ', ' order by p.proname)
                   from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                   where ns.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows'), '(none)'),
         case when exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                           where ns.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows')
              then 'STOP: the chat suite''s C4 fails on any' else 'expected none (slice C adds none)' end

  union all
  -- ---- ended_reason and status ------------------------------------------------
  select 3, 1, 'reason', 'tables_ended_reason_check',
         coalesce((select pg_get_constraintdef(con.oid) from pg_constraint con
                   where con.conrelid = 'public.tables'::regclass and con.conname = 'tables_ended_reason_check'), '(missing)'),
         case when not exists (select 1 from pg_constraint con where con.conrelid = 'public.tables'::regclass and con.conname = 'tables_ended_reason_check')
              then 'STOP: the constraint is not named tables_ended_reason_check; the migration drops it by that name'
              when (select pg_get_constraintdef(con.oid) from pg_constraint con
                    where con.conrelid = 'public.tables'::regclass and con.conname = 'tables_ended_reason_check') ilike '%empty%'
              then 'already allows ''empty'' (a re-run is safe)'
              else 'expected: admin and timeout only (slice-8-timeouts.sql); the migration adds ''empty''' end

  union all
  select 3, 2, 'reason', 'tables.ended_reason values in use',
         coalesce((select string_agg(coalesce(x.r, 'NULL') || ': ' || x.n, ', ' order by x.r nulls first)
                   from (select t.ended_reason as r, count(*)::text as n from public.tables t group by t.ended_reason) x), '(no tables)'),
         'expected NULL, admin, timeout (and empty on a re-run)'

  union all
  select 3, 3, 'reason', 'tables.status values in use',
         coalesce((select string_agg(x.status || ': ' || x.n, ', ' order by x.status)
                   from (select t.status, count(*)::text as n from public.tables t group by t.status) x), '(no tables)'),
         case when exists (select 1 from public.tables t where t.status not in ('open', 'ended'))
              then 'STOP: a status other than open/ended exists; the triggers and the sweep read "open"'
              else 'expected only open and ended' end

  union all
  select 3, 4, 'reason', 'games_ended_reason_check (unchanged by slice C)',
         coalesce((select pg_get_constraintdef(con.oid) from pg_constraint con
                   where con.conrelid = 'public.games'::regclass and con.conname = 'games_ended_reason_check'), '(missing)'),
         case when (select pg_get_constraintdef(con.oid) from pg_constraint con
                    where con.conrelid = 'public.games'::regclass and con.conname = 'games_ended_reason_check') ilike '%player_left%'
              then 'expected: admin, timeout, player_left, won; the triggers write player_left'
              else 'STOP: games may not accept player_left' end

  union all
  -- ---- Triggers on table_members, in firing order ---------------------------------
  select 4, row_number() over (order by (tg.tgtype & 2) desc, tg.tgname)::int, 'triggers', tg.tgname::text,
         case when (tg.tgtype & 2) = 2 then 'BEFORE' else 'AFTER' end
         || case when (tg.tgtype & 4) = 4 then ' INSERT' else '' end
         || case when (tg.tgtype & 8) = 8 then ' DELETE' else '' end
         || case when (tg.tgtype & 16) = 16 then ' UPDATE' else '' end
         || case when (tg.tgtype & 1) = 1 then ' ROW' else ' STATEMENT' end
         || ' -> ' || tg.tgfoid::regprocedure::text
         || case when tg.tgenabled = 'D' then ' (DISABLED)' else '' end,
         case when tg.tgname = 'table_members_assign_seat' then 'the seat trigger (takes the tables row lock); the new BEFORE INSERT trigger must sort after it'
              when tg.tgname in ('table_members_end_when_empty', 'table_members_require_open') then 'slice C (a re-run)'
              else 'listed for the order; slice C does not touch it' end
  from pg_trigger tg
  where tg.tgrelid = 'public.table_members'::regclass and not tg.tgisinternal

  union all
  select 4, 99, 'triggers', 'table_members_assign_seat present and enabled',
         case when exists (select 1 from pg_trigger tg where tg.tgrelid = 'public.table_members'::regclass
                             and tg.tgname = 'table_members_assign_seat' and tg.tgenabled <> 'D') then 'yes' else 'no' end,
         case when exists (select 1 from pg_trigger tg where tg.tgrelid = 'public.table_members'::regclass
                             and tg.tgname = 'table_members_assign_seat' and tg.tgenabled <> 'D')
              then 'expected yes'
              else 'STOP: the "table must be open" check relies on the seat trigger''s row lock' end

  union all
  -- ---- pg_cron -------------------------------------------------------------------------
  select 5, 1, 'cron', 'pg_cron extension version',
         coalesce((select e.extversion from pg_extension e where e.extname = 'pg_cron'), 'not installed'),
         case when not exists (select 1 from pg_extension e where e.extname = 'pg_cron')
              then 'STOP: no pg_cron -- the migration skips the job (a NOTICE), so nothing would sweep; decide first'
              else 'the job uses the standard "*/5 * * * *" schedule, which every pg_cron version accepts' end

  union all
  select 5, 2, 'cron', 'jobs end-timed-out-sessions and end-empty-tables',
         case when to_regclass('cron.job') is null then 'cron.job does not exist'
              else query_to_xml(
                'select jobname, schedule, command, active from cron.job where jobname in (''end-timed-out-sessions'', ''end-empty-tables'') order by jobname',
                false, false, '')::text end,
         'expected end-timed-out-sessions (*/15 * * * *) only on a first run; end-empty-tables too on a re-run'

  union all
  -- ---- computer accounts ----------------------------------------------------------------
  select 6, 1, 'computer', 'computer_accounts (levels)',
         coalesce((select string_agg(ca.level, ', ' order by ca.level) from public.computer_accounts ca), '(none)'),
         'the triggers and the sweep count only seats that are NOT computer accounts'

  union all
  -- ---- LEGACY: open tables with no human seat --------------------------------------------
  select 7, 1, 'legacy', 'open tables with no non-computer seat (all / older than 10 minutes)',
         (select count(*)::text || ' / ' || count(*) filter (where t.created_at < now() - interval '10 minutes')::text
          from public.tables t
          where t.status = 'open'
            and not exists (select 1 from public.table_members tm where tm.table_id = t.id
                              and not exists (select 1 from public.computer_accounts ca where ca.user_id = tm.user_id))),
         'LEGACY: the migration''s one-time cleanup ends the ones older than 10 minutes as ''empty''; the sweep ends the rest within 15 minutes'

  union all
  select 7, 2, 'legacy', '  of those: human tables / computer tables',
         (select count(*) filter (where t.computer_level is null)::text || ' / ' || count(*) filter (where t.computer_level is not null)::text
          from public.tables t
          where t.status = 'open'
            and not exists (select 1 from public.table_members tm where tm.table_id = t.id
                              and not exists (select 1 from public.computer_accounts ca where ca.user_id = tm.user_id))),
         'LEGACY: a computer table here still has its computer seated (a human left without leave_computer_table)'

  union all
  select 7, 3, 'legacy', '  of those: with a live game (cutting/active) / with spectator rows',
         (select count(*) filter (where exists (select 1 from public.games g where g.table_id = t.id and g.status in ('cutting', 'active')))::text
                 || ' / ' || count(*) filter (where exists (select 1 from public.table_spectators ts where ts.table_id = t.id))::text
          from public.tables t
          where t.status = 'open'
            and not exists (select 1 from public.table_members tm where tm.table_id = t.id
                              and not exists (select 1 from public.computer_accounts ca where ca.user_id = tm.user_id))),
         'LEGACY: live games there end as player_left; spectator rows are kept (their heartbeat then answers table_ended)'

  union all
  select 7, 4, 'legacy', '  the oldest five (code, created, computer level)',
         coalesce((select string_agg(x.code || ' ' || to_char(x.created_at, 'YYYY-MM-DD HH24:MI') || coalesce(' ' || x.computer_level, ''), ', ' order by x.created_at)
                   from (select t.code, t.created_at, t.computer_level
                         from public.tables t
                         where t.status = 'open'
                           and not exists (select 1 from public.table_members tm where tm.table_id = t.id
                                             and not exists (select 1 from public.computer_accounts ca where ca.user_id = tm.user_id))
                         order by t.created_at
                         limit 5) x), '(none)'),
         'LEGACY'
) x
order by s, o;
