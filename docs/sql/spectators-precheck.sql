-- Spectator seat, slice 1: the PRE-CHECK (read-only)
-- Run in the Supabase Dashboard -> SQL Editor before spectators.sql. It
-- reads only; it changes nothing.
--
-- STATUS: RUN in production on 2026-11-20: clean, no STOP lines (every name
-- free, the helpers and game functions as expected, tables.status only
-- 'open' / 'ended', the expected game statuses and phases, 0 policies on
-- game_decks).
--
-- RUN ORDER:
--   1. docs/sql/spectators-precheck.sql      (this file, read-only)
--   2. docs/sql/spectators.sql               (column, table, five functions)
--   3. docs/sql/spectators-verification.sql  (writes test rows, then rolls
--                                             them all back; its final
--                                             message is the verdict)
--   If it has to come out: docs/sql/spectators-rollback.sql.
--
-- ONE query, so the editor shows every line in one result (it shows only the
-- last result of a multi-statement run). Columns: section, item, value, note.
-- A note starting with STOP means: do not run spectators.sql yet; paste the
-- result back first.
--
-- WHAT IT LOOKS FOR (spectators.sql depends on each of these):
--   clear      the names spectators.sql creates are free: the column
--              tables.allow_spectators, the constraint
--              tables_spectators_human_only, the table table_spectators, its
--              policy, and the five functions (any schema). "PRESENT" on a
--              re-run is expected (the file is re-runnable); on a FIRST run
--              it means something else already uses the name: stop.
--   helpers    public.table_host(uuid) exists and still reads created_by and
--              the lowest seat (remove_spectator uses it); the seat trigger
--              table_members_assign_seat -> assign_table_seat() exists and
--              still takes "for no key update" on tables (watch_table takes
--              the same lock); auth.uid() exists.
--   game_fns   the eight _as game functions and their wrappers exist (the
--              verification drives a game through the _as functions and
--              re-checks the C1 fingerprints).
--   tables     the tables columns watch_table reads (id, code, status,
--              computer_level, created_by, is_public, max_players) and the
--              tables.status values in use. Only 'open' and 'ended' are
--              expected; any other value: STOP (watch_table allows 'open'
--              only).
--   games      the games columns get_spectator_reveals reads (table_id,
--              status, phase, count_step, players, hand_no, created_at), the
--              games.status and games.phase values in use and any check on
--              them. Expected status: cutting / active / ended; phase:
--              discard / play / counting / done. Any other: STOP.
--   members    every column of table_members: no spectator / watching flag
--              is expected (spectators are a separate table).
--   policies   every policy on game_hands and game_cribs, and the count on
--              game_decks (expected 0: nobody can read the deck). The crib
--              policy "Players read the crib once it is up for counting"
--              must use array_length(players) -- the crib step
--              get_spectator_reveals copies. The hand policy "Players read
--              every hand once pegging is over" must open at phase counting
--              / done.
--   realtime   which public tables are in the supabase_realtime publication
--              (for the record; table_spectators must never be in it).

select section, item, value, note
from (
  -- ---- Names spectators.sql will create --------------------------------------
  select 1 as s, 1 as o, 'clear' as section, 'column tables.allow_spectators' as item,
         null::text as value,
         case when exists (select 1 from information_schema.columns c
                           where c.table_schema = 'public' and c.table_name = 'tables'
                             and c.column_name = 'allow_spectators')
              then 'PRESENT' else 'absent' end as note

  union all
  select 1, 2, 'clear', 'constraint tables_spectators_human_only', null,
         case when exists (select 1 from pg_constraint c where c.conname = 'tables_spectators_human_only')
              then 'PRESENT' else 'absent' end

  union all
  select 1, 3, 'clear', 'relation table_spectators (any schema)',
         (select string_agg(n.nspname || '.' || c.relname, ', ')
          from pg_class c join pg_namespace n on n.oid = c.relnamespace
          where c.relname = 'table_spectators'),
         case when exists (select 1 from pg_class c where c.relname = 'table_spectators')
              then 'PRESENT' else 'absent' end

  union all
  select 1, 4, 'clear', 'policy "Table members and the spectator read spectator rows"', null,
         case when exists (select 1 from pg_policies p
                           where p.policyname = 'Table members and the spectator read spectator rows')
              then 'PRESENT' else 'absent' end

  union all
  select 1, 4 + f.ord, 'clear', 'function ' || f.name || ' (any schema)',
         (select count(*)::text from pg_proc p where p.proname = f.name),
         case when exists (select 1 from pg_proc p where p.proname = f.name)
              then 'PRESENT' else 'absent' end
  from (values ('watch_table', 1), ('stop_watching', 2), ('remove_spectator', 3),
               ('spectator_heartbeat', 4), ('get_spectator_reveals', 5)) as f(name, ord)

  union all
  -- ---- Helpers the new functions rely on -------------------------------------
  select 2, 1, 'helpers', 'public.table_host(uuid)',
         case when to_regprocedure('public.table_host(uuid)') is null then null
              else (select p.prorettype::regtype::text from pg_proc p
                    where p.oid = to_regprocedure('public.table_host(uuid)')) end,
         case when to_regprocedure('public.table_host(uuid)') is null then 'STOP: missing'
              when (select p.prosrc from pg_proc p where p.oid = to_regprocedure('public.table_host(uuid)'))
                     ilike '%created_by%'
                   and (select p.prosrc from pg_proc p where p.oid = to_regprocedure('public.table_host(uuid)'))
                     ilike '%order by tm.seat%'
                then 'exists: creator while seated, else lowest seat'
              else 'STOP: exists but its body no longer reads created_by and the lowest seat' end

  union all
  select 2, 2, 'helpers', 'public.assign_table_seat()',
         null,
         case when to_regprocedure('public.assign_table_seat()') is null then 'STOP: missing'
              when (select p.prosrc from pg_proc p where p.oid = to_regprocedure('public.assign_table_seat()'))
                     ilike '%for no key update%'
                then 'exists, locks the tables row "for no key update"'
              else 'STOP: exists but no longer takes "for no key update"' end

  union all
  select 2, 3, 'helpers', 'trigger table_members_assign_seat',
         (select p.proname::text from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
          where tg.tgrelid = 'public.table_members'::regclass and tg.tgname = 'table_members_assign_seat'),
         case when exists (select 1 from pg_trigger tg
                           where tg.tgrelid = 'public.table_members'::regclass
                             and tg.tgname = 'table_members_assign_seat')
              then 'exists' else 'STOP: missing' end

  union all
  select 2, 4, 'helpers', 'auth.uid()', null,
         case when to_regprocedure('auth.uid()') is null then 'STOP: missing' else 'exists' end

  union all
  -- ---- The game functions the verification drives ----------------------------
  select 3, f.ord, 'game_fns', f.name,
         case when to_regprocedure('public.' || f.name || '(' || f.as_sig || ')') is null then 'MISSING _as'
              else '_as ok' end
         || ' / '
         || case when to_regprocedure('public.' || f.wname || '(' || f.sig || ')') is null then 'MISSING wrapper'
                 else 'wrapper ok' end,
         case when to_regprocedure('public.' || f.name || '(' || f.as_sig || ')') is null
                or to_regprocedure('public.' || f.wname || '(' || f.sig || ')') is null
              then 'STOP: C1 (computer-c1-refactor.sql) not applied?' else 'ok' end
  from (values
    ('start_game_with_deal_as', 'start_game_with_deal', 'uuid', 'uuid, uuid', 1),
    ('draw_cut_card_as', 'draw_cut_card', 'uuid', 'uuid, uuid', 2),
    ('acknowledge_deal_cut_as', 'acknowledge_deal_cut', 'uuid', 'uuid, uuid', 3),
    ('discard_to_crib_as', 'discard_to_crib', 'uuid, text[]', 'uuid, uuid, text[]', 4),
    ('play_card_as', 'play_card', 'uuid, text', 'uuid, uuid, text', 5),
    ('show_crib_as', 'show_crib', 'uuid', 'uuid, uuid', 6),
    ('confirm_count_as', 'confirm_count', 'uuid, int', 'uuid, uuid, int', 7),
    ('next_hand_as', 'next_hand', 'uuid, int', 'uuid, uuid, int', 8)
  ) as f(name, wname, sig, as_sig, ord)

  union all
  select 3, 9, 'game_fns', 'public.leave_table(uuid) / public.set_seat(uuid, uuid, int)',
         case when to_regprocedure('public.leave_table(uuid)') is null then 'leave_table MISSING' else 'leave_table ok' end
         || ' / '
         || case when to_regprocedure('public.set_seat(uuid, uuid, integer)') is null then 'set_seat MISSING' else 'set_seat ok' end,
         'the verification calls both as a spectator (must be refused)'

  union all
  -- ---- tables ----------------------------------------------------------------
  select 4, c.ordinal_position::int, 'tables', 'column ' || c.column_name::text,
         c.data_type::text || case when c.is_nullable = 'YES' then ', nullable' else ', not null' end,
         coalesce('default ' || c.column_default::text, '')
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'tables'
    and c.column_name in ('id', 'code', 'status', 'computer_level', 'created_by', 'is_public', 'max_players', 'allow_spectators')

  union all
  select 4, 100 + row_number() over (order by t.status)::int, 'tables',
         'status ' || coalesce(t.status, '(null)'),
         count(*)::text,
         case when t.status in ('open', 'ended') then 'expected' else 'STOP: unexpected status' end
  from public.tables t
  group by t.status

  union all
  select 4, 200, 'tables', 'checks on tables',
         coalesce((select string_agg(c.conname || ': ' || pg_get_constraintdef(c.oid), ' ; ' order by c.conname)
                   from pg_constraint c
                   where c.conrelid = 'public.tables'::regclass and c.contype = 'c'), '(none)'),
         'for the record (computer_level''s check must allow null)'

  union all
  -- ---- games -----------------------------------------------------------------
  select 5, c.ordinal_position::int, 'games', 'column ' || c.column_name::text,
         c.data_type::text || case when c.is_nullable = 'YES' then ', nullable' else ', not null' end,
         coalesce('default ' || c.column_default::text, '')
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'games'
    and c.column_name in ('id', 'table_id', 'status', 'phase', 'count_step', 'players', 'hand_no',
                          'created_at', 'crib_revealed', 'dealer_id', 'current_player')

  union all
  select 5, 100 + row_number() over (order by g.status)::int, 'games',
         'status ' || coalesce(g.status, '(null)'),
         count(*)::text,
         case when g.status in ('cutting', 'active', 'ended') then 'expected' else 'STOP: unexpected status' end
  from public.games g
  group by g.status

  union all
  select 5, 200 + row_number() over (order by g.phase)::int, 'games',
         'phase ' || coalesce(g.phase, '(null)'),
         count(*)::text,
         case when g.phase in ('discard', 'play', 'counting', 'done') then 'expected' else 'STOP: unexpected phase' end
  from public.games g
  group by g.phase

  union all
  select 5, 300, 'games', 'checks on games',
         coalesce((select string_agg(c.conname || ': ' || pg_get_constraintdef(c.oid), ' ; ' order by c.conname)
                   from pg_constraint c
                   where c.conrelid = 'public.games'::regclass and c.contype = 'c'), '(none)'),
         'expected: the phase check lists discard, play, counting, done'

  union all
  -- ---- table_members' columns ------------------------------------------------
  select 6, c.ordinal_position::int, 'members', c.column_name::text,
         c.data_type::text || case when c.is_nullable = 'YES' then ', nullable' else ', not null' end,
         case when c.column_name ilike '%spectat%' or c.column_name ilike '%watch%'
              then 'STOP: a spectator flag on table_members?' else coalesce('default ' || c.column_default::text, '') end
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'table_members'

  union all
  -- ---- The hidden-card read policies -----------------------------------------
  select 7, row_number() over (order by p.tablename, p.policyname)::int, 'policies',
         p.tablename || ': ' || p.policyname,
         p.cmd::text || ' to ' || p.roles::text,
         'using: ' || coalesce(p.qual, '-')
  from pg_policies p
  where p.schemaname = 'public' and p.tablename in ('game_hands', 'game_cribs')

  union all
  select 7, 100, 'policies', 'crib step in "Players read the crib once it is up for counting"',
         null,
         case when exists (select 1 from pg_policies p
                           where p.schemaname = 'public' and p.tablename = 'game_cribs'
                             and p.policyname = 'Players read the crib once it is up for counting'
                             and p.qual ilike '%array_length(%players%')
              then 'uses array_length(players): the step get_spectator_reveals copies'
              else 'STOP: missing, or not the phase3-e4-counting.sql version' end

  union all
  select 7, 101, 'policies', 'hands in "Players read every hand once pegging is over"',
         null,
         case when exists (select 1 from pg_policies p
                           where p.schemaname = 'public' and p.tablename = 'game_hands'
                             and p.policyname = 'Players read every hand once pegging is over'
                             and p.qual ilike '%counting%' and p.qual ilike '%done%')
              then 'opens at counting / done: the rule get_spectator_reveals copies'
              else 'STOP: missing or changed' end

  union all
  select 7, 102, 'policies', 'policies on game_decks',
         (select count(*)::text from pg_policies p where p.schemaname = 'public' and p.tablename = 'game_decks'),
         case when exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = 'game_decks')
              then 'STOP: expected 0 (nobody may read the deck)' else 'expected 0' end

  union all
  -- ---- Realtime publication --------------------------------------------------
  select 8, 1, 'realtime', 'public tables in supabase_realtime',
         (select string_agg(pt.tablename::text, ', ' order by pt.tablename)
          from pg_publication_tables pt
          where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public'),
         'for the record; table_spectators must never be listed'

  union all
  select 8, 2, 'realtime', 'publication covers all tables?',
         coalesce((select case when pb.puballtables then 'FOR ALL TABLES' else 'listed tables only' end
                   from pg_publication pb where pb.pubname = 'supabase_realtime'), 'no such publication'),
         case when exists (select 1 from pg_publication pb where pb.pubname = 'supabase_realtime' and pb.puballtables)
              then 'STOP: a new table would be broadcast automatically' else 'expected' end
) x
order by s, o;
