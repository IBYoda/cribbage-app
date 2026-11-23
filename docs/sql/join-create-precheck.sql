-- Step 3, slice A: server-side create and join, one table at a time.
-- The PRE-CHECK (read-only). Run in the Supabase Dashboard -> SQL Editor
-- before docs/sql/join-create.sql. It reads only; it changes nothing.
--
-- STATUS: written, NOT RUN yet.
--
-- RUN ORDER (slice A):
--   1. docs/sql/join-create-precheck.sql       (this file, read-only)
--   2. docs/sql/join-create.sql                (additive: attempt_log,
--                                               create_table,
--                                               join_table_by_code, and the
--                                               one-table rule in watch_table
--                                               and create_computer_table)
--   3. docs/sql/join-create-verification.sql   (writes test rows, then rolls
--                                               them all back; its final
--                                               message is the verdict)
--   -- the app switches to create_table / join_table_by_code --
--   4. docs/sql/join-create-lockdown.sql       (revokes the direct INSERTs)
--   5. docs/sql/join-create-verification.sql   again (its L checks run once
--                                               the lockdown is in)
--   If it has to come out: docs/sql/join-create-rollback.sql.
--
-- ONE query, so the editor shows every line in one result (it shows only the
-- last result of a multi-statement run). Columns: section, item, value, note.
-- A note starting with STOP means: do not run join-create.sql yet; paste the
-- result back first. A note starting with LEGACY is information for the
-- one-table rule, not a blocker.
--
-- WHAT IT LOOKS FOR
--   fn        watch_table(text) and create_computer_table(text, text): exist,
--             their shape, and the md5 of their live bodies. The rollback puts
--             back the text of spectators-join-or-watch.sql (watch_table) and
--             the LIVE create_computer_table captured on 2026-11-23
--             (computer-live-create_computer_table-2026-11-23.sql). Expected
--             (computed from the files, LF and CRLF):
--               watch_table            6c9dfb0cfb9987d318da595b2f9a3142 (LF)
--                                      a7720e04ab8ab714654d93343df15020 (CRLF)
--               create_computer_table, EITHER
--                 the live capture     7f804511bc76a0228d7158c544e1fdec (CRLF)
--                                      71f74319e76ab1cfe2a25d39e1d9d7ec (LF)
--                 or computer-normie.sql 27289949af432013613fbd97e3016b7a (LF)
--                                      ac124ae689b09c8c9fdfbc1fa2c0962a (CRLF)
--               (the two differ ONLY in comments: the rollback's live text
--               behaves identically to either).
--             Anything else: STOP (the live text was changed since; the
--             rollback would put back the file's text, not the live one).
--             Also table_host(uuid), which join_table_by_code calls, and the
--             md5 of leave_computer_table's live body: join-create.sql's
--             _one_table_rule reproduces its three statements to end a
--             single-player game quietly, so it must still be the text of
--             computer-c2-engine.sql (not changed by this slice):
--               leave_computer_table   0d1a2573029789f31ead030a52c47d5a (LF)
--                                      42010a59b76e935771bfd964a0f53516 (CRLF)
--             Anything else: STOP (re-read it and update the rule to match).
--   names     create_table, join_table_by_code, attempt_log and the three
--             internal helpers (_attempts_guard, _code_guesses_check,
--             _one_table_rule, _code_guess_failed): expected absent (PRESENT
--             only on a re-run). And any public function with "chat" in its
--             name other than chat_topic_allows (the chat suite's C4): none.
--   tables    the columns create_table writes, with their defaults, and the
--             CHECK constraints the old direct insert relied on; the status
--             values in use (expected only 'open' and 'ended': the rule reads
--             "not ended" as status <> 'ended'); the code constraint.
--   grants    authenticated's INSERT on tables (expected: the seven columns,
--             no table-wide INSERT) and on table_members (table_id, user_id).
--             The lockdown file revokes these later.
--   seat      the assign_table_seat trigger on table_members (create_table and
--             join seat through it).
--   computer  the 'easy' computer account (the verification starts a computer
--             game).
--   codes     how many 4-digit codes are still unused by ANY table (codes
--             are unique across every table, ended ones included, until slice
--             B); create_table picks from these.
--   legacy    people who are, TODAY, at more than one table (the rule applies
--             to new actions only; nobody is moved by this file):
--               * seated at more than one non-ended table. Their OWN
--                 single-player tables (computer_level set, created by them,
--                 nobody else seated but computer accounts) never block: the
--                 next real create/join/watch/computer game ends them quietly,
--                 as Leave does. Only people seated at 2+ tables WITH OTHER
--                 HUMANS stay refused until they leave all but one; the count
--                 shows them separately;
--               * seated at a non-ended table AND a current spectator of
--                 another;
--               * a current spectator of more than one table (harmless: their
--                 next watch ends the others);
--             and open COMPUTER tables per person: an unfinished single-player
--             game NO LONGER blocks (it is ended quietly by their next real
--             action); listed for information only.
--   cron      whether pg_cron is installed (the attempt_log cleanup will be
--             added to the existing job in a later slice).

select section, item, value, note
from (
  -- ---- The two functions this slice replaces --------------------------------
  select 1 as s, 1 as o, 'fn' as section, 'public.watch_table(text)' as item,
         (select p.prorettype::regtype::text || ' | ' || pg_get_function_result(p.oid)
                 || case when p.prosecdef then ' | definer' else ' | invoker' end
                 || ' | ' || coalesce(p.proconfig::text, 'no config')
          from pg_proc p where p.oid = to_regprocedure('public.watch_table(text)')) as value,
         case when to_regprocedure('public.watch_table(text)') is null then 'STOP: missing'
              else 'expected: TABLE(table_id uuid, code text, game_id uuid) | definer | search_path=""' end as note

  union all
  select 1, 2, 'fn', 'watch_table: md5 of the live body',
         (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.watch_table(text)')),
         case (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.watch_table(text)'))
              when '6c9dfb0cfb9987d318da595b2f9a3142' then 'spectators-join-or-watch.sql''s text (LF): as expected'
              when 'a7720e04ab8ab714654d93343df15020' then 'spectators-join-or-watch.sql''s text (CRLF): as expected'
              else case when (select p.prosrc from pg_proc p where p.oid = to_regprocedure('public.watch_table(text)')) ilike '%_one_table_rule%'
                        then 'already join-create.sql''s (a re-run is safe)'
                        else 'STOP: not spectators-join-or-watch.sql''s text; paste the result back' end
         end

  union all
  select 1, 3, 'fn', 'public.create_computer_table(text, text)',
         (select pg_get_function_result(p.oid)
                 || case when p.prosecdef then ' | definer' else ' | invoker' end
                 || ' | ' || coalesce(p.proconfig::text, 'no config')
          from pg_proc p where p.oid = to_regprocedure('public.create_computer_table(text, text)')),
         case when to_regprocedure('public.create_computer_table(text, text)') is null then 'STOP: missing'
              else 'expected: TABLE(table_id uuid, code text) | definer | search_path=public' end

  union all
  select 1, 4, 'fn', 'create_computer_table: md5 of the live body',
         (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.create_computer_table(text, text)')),
         case (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.create_computer_table(text, text)'))
              when '7f804511bc76a0228d7158c544e1fdec' then 'the live capture of 2026-11-23 (CRLF): as expected (differs from computer-normie.sql only in comments)'
              when '71f74319e76ab1cfe2a25d39e1d9d7ec' then 'the live capture of 2026-11-23 (LF): as expected (differs from computer-normie.sql only in comments)'
              when '27289949af432013613fbd97e3016b7a' then 'computer-normie.sql''s text (LF): as expected (differs from the live capture only in comments)'
              when 'ac124ae689b09c8c9fdfbc1fa2c0962a' then 'computer-normie.sql''s text (CRLF): as expected (differs from the live capture only in comments)'
              else case when (select p.prosrc from pg_proc p where p.oid = to_regprocedure('public.create_computer_table(text, text)')) ilike '%_one_table_rule%'
                        then 'already join-create.sql''s (a re-run is safe)'
                        else 'STOP: neither the live capture nor computer-normie.sql''s text; paste the result back' end
         end

  union all
  select 1, 5, 'fn', 'execute grants (watch_table, create_computer_table)',
         'watch_table: authenticated ' || coalesce(has_function_privilege('authenticated', 'public.watch_table(text)', 'execute')::text, '?')
         || ', anon ' || coalesce(has_function_privilege('anon', 'public.watch_table(text)', 'execute')::text, '?')
         || ' | create_computer_table: authenticated ' || coalesce(has_function_privilege('authenticated', 'public.create_computer_table(text, text)', 'execute')::text, '?')
         || ', anon ' || coalesce(has_function_privilege('anon', 'public.create_computer_table(text, text)', 'execute')::text, '?'),
         'expected: authenticated true, anon false for both ("create or replace" keeps them)'

  union all
  select 1, 6, 'fn', 'public.table_host(uuid)',
         case when to_regprocedure('public.table_host(uuid)') is null then 'missing' else 'exists' end,
         case when to_regprocedure('public.table_host(uuid)') is null then 'STOP: join_table_by_code reads the host through it'
              else 'join_table_by_code reads the host''s nickname through it' end

  union all
  select 1, 7, 'fn', 'leave_computer_table: md5 of the live body',
         (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.leave_computer_table(uuid)')),
         case (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.leave_computer_table(uuid)'))
              when '0d1a2573029789f31ead030a52c47d5a' then 'computer-c2-engine.sql''s text (LF): as expected'
              when '42010a59b76e935771bfd964a0f53516' then 'computer-c2-engine.sql''s text (CRLF): as expected'
              else 'STOP: not computer-c2-engine.sql''s text (or missing); _one_table_rule reproduces its effect, paste the result back' end

  union all
  -- ---- Names this slice adds ---------------------------------------------------
  select 2, 1, 'names', 'new objects already present',
         coalesce((select string_agg(x.n, ', ' order by x.n) from (
           select 'create_table' as n where exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                                                    where ns.nspname = 'public' and p.proname = 'create_table')
           union all select 'join_table_by_code' where exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                                                    where ns.nspname = 'public' and p.proname = 'join_table_by_code')
           union all select p.proname::text from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                     where ns.nspname = 'public' and p.proname in ('_attempts_guard', '_code_guesses_check', '_code_guess_failed', '_one_table_rule')
           union all select 'attempt_log (table)' where to_regclass('public.attempt_log') is not null
         ) x), '(none)'),
         'expected (none) on a first run; all of them on a re-run (safe)'

  union all
  select 2, 2, 'names', 'other public functions with "chat" in the name',
         coalesce((select string_agg(p.proname::text, ', ' order by p.proname)
                   from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                   where ns.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows'), '(none)'),
         case when exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                           where ns.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows')
              then 'STOP: the chat suite''s C4 fails on any' else 'expected none (this slice adds none)' end

  union all
  -- ---- tables: what create_table writes ----------------------------------------
  select 3, c.ordinal_position::int, 'tables', 'column: ' || c.column_name::text,
         c.data_type::text || case when c.is_nullable = 'YES' then ', nullable' else ', not null' end
         || coalesce(', default ' || c.column_default::text, ''),
         case c.column_name
           when 'code' then 'create_table picks it'
           when 'created_by' then 'create_table: the caller'
           when 'is_public' then 'expected default false'
           when 'is_muggins' then 'expected default false'
           when 'max_players' then 'expected smallint, default 2'
           when 'team_mode' then 'expected default ''teams'''
           when 'allow_spectators' then 'expected default false'
           when 'status' then 'expected default ''open'''
           else '' end
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'tables'

  union all
  select 4, row_number() over (order by con.conname)::int, 'tables', 'constraint: ' || con.conname::text,
         pg_get_constraintdef(con.oid),
         case when con.conname in ('tables_code_key') then 'codes unique across ALL tables (until slice B)'
              when con.conname in ('tables_max_players_check', 'tables_team_mode_check', 'tables_muggins_no_teams',
                                   'tables_spectators_human_only', 'tables_code_check', 'tables_computer_level_check',
                                   'tables_ended_reason_check')
                then 'still enforced on create_table''s insert'
              else '' end
  from pg_constraint con
  where con.conrelid = 'public.tables'::regclass and con.contype in ('c', 'u')

  union all
  select 5, 1, 'tables', 'status values in use',
         coalesce((select string_agg(x.status || ': ' || x.n, ', ' order by x.status)
                   from (select t.status, count(*)::text as n from public.tables t group by t.status) x), '(no tables)'),
         case when exists (select 1 from public.tables t where t.status not in ('open', 'ended'))
              then 'STOP: a status other than open/ended exists; the rule reads "not ended" as status <> ''ended'''
              else 'expected only open and ended' end

  union all
  -- ---- Grants the lockdown will take away later ---------------------------------
  select 6, 1, 'grants', 'authenticated INSERT on public.tables',
         case when has_table_privilege('authenticated', 'public.tables', 'INSERT') then 'TABLE-WIDE INSERT'
              else coalesce((select string_agg(a.attname::text, ', ' order by a.attnum)
                             from pg_attribute a
                             where a.attrelid = 'public.tables'::regclass and a.attnum > 0 and not a.attisdropped
                               and has_column_privilege('authenticated', 'public.tables', a.attname, 'INSERT')), '(none)') end,
         'expected: code, created_by, is_public, is_muggins, max_players, team_mode, allow_spectators (the lockdown revokes them)'

  union all
  select 6, 2, 'grants', 'authenticated INSERT on public.table_members',
         case when has_table_privilege('authenticated', 'public.table_members', 'INSERT') then 'TABLE-WIDE INSERT'
              else coalesce((select string_agg(a.attname::text, ', ' order by a.attnum)
                             from pg_attribute a
                             where a.attrelid = 'public.table_members'::regclass and a.attnum > 0 and not a.attisdropped
                               and has_column_privilege('authenticated', 'public.table_members', a.attname, 'INSERT')), '(none)') end,
         'expected: table_id, user_id (the lockdown revokes them)'

  union all
  select 6, 3, 'grants', 'anon INSERT on tables / table_members',
         'tables ' || has_table_privilege('anon', 'public.tables', 'INSERT')::text
         || ', table_members ' || has_table_privilege('anon', 'public.table_members', 'INSERT')::text,
         'expected false, false (phase3-hardening-grants.sql); column grants for anon are not listed here'

  union all
  -- ---- The seat trigger -----------------------------------------------------------
  select 7, 1, 'seat', 'table_members_assign_seat',
         coalesce((select tg.tgfoid::regprocedure::text || case when tg.tgenabled = 'D' then ' (DISABLED)' else '' end
                   from pg_trigger tg
                   where tg.tgrelid = 'public.table_members'::regclass and tg.tgname = 'table_members_assign_seat'), 'missing'),
         case when exists (select 1 from pg_trigger tg where tg.tgrelid = 'public.table_members'::regclass
                             and tg.tgname = 'table_members_assign_seat' and tg.tgenabled <> 'D')
              then 'expected assign_table_seat(): create_table and join seat through it'
              else 'STOP: the seat trigger is missing or disabled' end

  union all
  -- ---- The computer account the verification uses --------------------------------
  select 8, 1, 'computer', 'computer_accounts (easy)',
         coalesce((select ca.user_id::text from public.computer_accounts ca where ca.level = 'easy'), 'missing'),
         case when exists (select 1 from public.computer_accounts ca where ca.level = 'easy')
              then 'the verification starts an easy computer game' else 'STOP: the verification needs it' end

  union all
  -- ---- Codes ------------------------------------------------------------------------
  select 9, 1, 'codes', 'unused 4-digit codes (not used by ANY table)',
         (select count(*)::text from generate_series(0, 9999) n
          where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0'))),
         'of 10000; create_table picks among these until slice B frees ended tables'' codes'

  union all
  select 9, 2, 'codes', 'tables in all / non-ended',
         (select count(*)::text from public.tables) || ' / ' || (select count(*)::text from public.tables t where t.status <> 'ended'),
         ''

  union all
  -- ---- LEGACY: people already at more than one table --------------------------------
  select 10, 1, 'legacy', 'seated at more than one non-ended table (people)',
         (select count(*)::text from (
            select tm.user_id
            from public.table_members tm join public.tables t on t.id = tm.table_id
            where t.status <> 'ended'
              and not exists (select 1 from public.computer_accounts ca where ca.user_id = tm.user_id)
            group by tm.user_id having count(*) > 1) x)
         || ' (of them, seated at 2+ tables with other humans: '
         || (select count(*)::text from (
            select tm.user_id
            from public.table_members tm join public.tables t on t.id = tm.table_id
            where t.status <> 'ended'
              and not exists (select 1 from public.computer_accounts ca where ca.user_id = tm.user_id)
              and not (t.computer_level is not null and t.created_by = tm.user_id
                     and not exists (select 1 from public.table_members o where o.table_id = t.id and o.user_id <> tm.user_id
                                       and not exists (select 1 from public.computer_accounts ca where ca.user_id = o.user_id)))
            group by tm.user_id having count(*) > 1) x) || ')',
         'LEGACY: only the 2+ with other humans stay refused a new create/join/watch/computer game until they leave all but one; their own single-player tables end quietly on their next action (computer accounts left out)'

  union all
  select 10, 1 + row_number() over (order by x.n desc, x.user_id)::int, 'legacy',
         '  seated: ' || coalesce(p.nickname, '(no nickname)') || ' (' || x.user_id::text || ')',
         x.n::text || ' tables: ' || x.codes,
         'LEGACY'
  from (
    select tm.user_id, count(*) as n,
           string_agg(t.code || case when (t.computer_level is not null and t.created_by = tm.user_id
                     and not exists (select 1 from public.table_members o where o.table_id = t.id and o.user_id <> tm.user_id
                                       and not exists (select 1 from public.computer_accounts ca where ca.user_id = o.user_id))) then ' (single-player: ends quietly)'
                                     when t.computer_level is not null then ' (computer, not theirs alone: blocks)'
                                     else '' end
                      || ' ' || to_char(t.created_at, 'YYYY-MM-DD'), ', ' order by t.created_at desc) as codes
    from public.table_members tm join public.tables t on t.id = tm.table_id
    where t.status <> 'ended'
      and not exists (select 1 from public.computer_accounts ca where ca.user_id = tm.user_id)
    group by tm.user_id having count(*) > 1
  ) x
  left join public.profiles p on p.id = x.user_id

  union all
  select 11, 1, 'legacy', 'seated AND a current spectator of another non-ended table (people)',
         (select count(distinct tm.user_id)::text
          from public.table_members tm
          join public.tables t on t.id = tm.table_id and t.status <> 'ended'
          join public.table_spectators ts on ts.user_id = tm.user_id and ts.table_id <> tm.table_id
                                          and ts.removed_at is null and ts.last_seen_at > now() - interval '90 seconds'
          join public.tables t2 on t2.id = ts.table_id and t2.status <> 'ended'),
         'LEGACY: if the seat is at a table with other humans, refused a new action until they leave it; if it is their own single-player table, their next action ends it (and the watching)'

  union all
  select 11, 2, 'legacy', 'a current spectator of more than one non-ended table (people)',
         (select count(*)::text from (
            select ts.user_id
            from public.table_spectators ts join public.tables t on t.id = ts.table_id and t.status <> 'ended'
            where ts.removed_at is null and ts.last_seen_at > now() - interval '90 seconds'
            group by ts.user_id having count(*) > 1) x),
         'LEGACY, harmless: their next watch/create/join ends the others'

  union all
  select 11, 3, 'legacy', 'seated at a table AND a current spectator of the SAME table (rows)',
         (select count(*)::text
          from public.table_spectators ts
          join public.table_members tm on tm.table_id = ts.table_id and tm.user_id = ts.user_id
          where ts.removed_at is null and ts.last_seen_at > now() - interval '90 seconds'),
         'expected 0 (watch_table refuses a seated caller)'

  union all
  select 12, 1, 'legacy', 'open computer tables (people with at least one / tables)',
         (select count(distinct tm.user_id)::text || ' / ' || count(distinct t.id)::text
          from public.tables t
          join public.table_members tm on tm.table_id = t.id
          where t.status <> 'ended' and t.computer_level is not null
            and not exists (select 1 from public.computer_accounts ca where ca.user_id = tm.user_id)),
         'LEGACY, information only: an unfinished single-player game NO LONGER blocks; their next real create/join/watch/computer game ends it quietly (as Leave does)'

  union all
  select 12, 2, 'legacy', 'open computer tables older than 1 hour',
         (select count(*)::text from public.tables t
          where t.status <> 'ended' and t.computer_level is not null and t.created_at < now() - interval '1 hour'),
         'LEGACY, information only: most likely abandoned; each ends quietly on its player''s next action, or by the 12-hour timeout'

  union all
  -- ---- The cron job the cleanup will join later ---------------------------------------
  -- (Only whether pg_cron's job table exists: naming cron.job directly would
  -- make the whole query fail to parse on a project without pg_cron. To see
  -- the jobs: select jobname, schedule, command from cron.job;)
  select 13, 1, 'cron', 'pg_cron job table',
         case when to_regclass('cron.job') is null then 'pg_cron not installed' else 'present' end,
         'expected present (end-timed-out-sessions, every 15 min); nothing is added to it in this slice'
) x
order by s, o;
