-- Spectator chat, step 1: the PRE-CHECK (read-only)
-- Run in the Supabase Dashboard -> SQL Editor before spectator-chat.sql. It
-- reads only; it changes nothing.
--
-- STATUS: written, NOT RUN yet.
--
-- RUN ORDER:
--   1. docs/sql/spectator-chat-precheck.sql      (this file, read-only)
--   2. docs/sql/spectator-chat.sql               (chat_topic_allows and
--                                                 get_table_spectators)
--   3. docs/sql/spectator-chat-verification.sql  (writes test rows, then
--                                                 rolls them all back)
--   4. docs/sql/table-chat-verification.sql      (the existing chat suite)
--   If it has to come out: docs/sql/spectator-chat-rollback.sql.
--
-- ONE query, so the editor shows every line in one result (it shows only the
-- last result of a multi-statement run). Columns: section, item, value, note.
-- A note starting with STOP means: do not run spectator-chat.sql yet; paste
-- the result back first.
--
-- WHAT IT LOOKS FOR
--   chat_fn     public.chat_topic_allows(text, boolean): exists, its shape
--               (returns boolean, security definer, stable, search_path ''),
--               the md5 of its live body and the body itself.
--               The body as table-chat.sql wrote it has md5
--                 dade7dde7ac1566b7eb4d04fb9aee0a4  (saved with LF line ends)
--                 f3b669b6990a8e66a5b794a5a291b3da  (saved with CRLF)
--               Either one: the live text is table-chat.sql's, as the
--               rollback assumes. Anything else: STOP and look (someone
--               changed it since; the rollback would put back the
--               table-chat.sql text, not the live one). If the body already
--               mentions table_spectators, spectator-chat.sql has run before
--               (a re-run is safe).
--   policies    every policy on realtime.messages (name, command, roles,
--               using, with check). Expected exactly the two table-chat
--               policies, each calling chat_topic_allows -- plus, once
--               moderation M3 part 1 is in, "table kicks: people at the
--               table receive" (SELECT, kick_topic_allows: kicks: topics
--               only). Policies are OR'ed, so any other policy could let
--               someone hear chat whatever chat_topic_allows says: STOP and
--               look.
--   spectators  every policy on public.table_spectators (expected ONE:
--               "Table members and the spectator read spectator rows", for
--               SELECT), its RLS (on), and its columns (removed_at and
--               last_seen_at are what "current" reads).
--   tables      tables.allow_spectators exists (rule 6 reads it).
--   partitions  how many partitions realtime.messages has. With none, the
--               verification's live-policy lines (and the existing chat
--               suite's P1-P7) say "skipped" and the rules are proven
--               through the functions and pg_policies only.
--   grants      authenticated's SELECT and INSERT on realtime.messages (the
--               live-policy lines need both).
--   clear       get_table_spectators (any schema): absent on a first run
--               ("PRESENT" on a re-run is expected; on a first run something
--               else uses the name: STOP). And any OTHER function in public
--               with "chat" in its name: expected none (the existing chat
--               suite's check C4 fails on one).
--   slices      watch_table without slice 1's "no game" refusal (slice 2,
--               spectators-join-or-watch.sql, live) and
--               spectator_heartbeat present: for the record. The
--               verification adds a live game at its tables, so it passes
--               either way.

select section, item, value, note
from (
  -- ---- chat_topic_allows -----------------------------------------------------
  select 1 as s, 1 as o, 'chat_fn' as section, 'public.chat_topic_allows(text, boolean)' as item,
         null::text as value,
         case when to_regprocedure('public.chat_topic_allows(text, boolean)') is null
              then 'STOP: missing (table-chat.sql not run?)' else 'exists' end as note

  union all
  select 1, 2, 'chat_fn', 'shape',
         (select p.prorettype::regtype::text
                 || case when p.prosecdef then ' definer ' else ' invoker ' end
                 || p.provolatile::text
                 || case when coalesce(p.proconfig, '{}') && array['search_path=""', 'search_path=''''']
                         then ' empty-path' else ' path:' || coalesce(p.proconfig::text, 'none') end
          from pg_proc p where p.oid = to_regprocedure('public.chat_topic_allows(text, boolean)')),
         'expected: boolean definer s empty-path'

  union all
  select 1, 3, 'chat_fn', 'md5 of the live body',
         (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.chat_topic_allows(text, boolean)')),
         case (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.chat_topic_allows(text, boolean)'))
              when 'dade7dde7ac1566b7eb4d04fb9aee0a4' then 'table-chat.sql''s text (LF): as expected'
              when 'f3b669b6990a8e66a5b794a5a291b3da' then 'table-chat.sql''s text (CRLF): as expected'
              else case when (select p.prosrc from pg_proc p
                              where p.oid = to_regprocedure('public.chat_topic_allows(text, boolean)')) ilike '%table_spectators%'
                        then 'already spectator-chat.sql''s (a re-run is safe)'
                        else 'STOP: not table-chat.sql''s text; look at the body below' end
         end

  union all
  select 1, 4, 'chat_fn', 'the live body', null,
         (select p.prosrc from pg_proc p where p.oid = to_regprocedure('public.chat_topic_allows(text, boolean)'))

  union all
  select 1, 5, 'chat_fn', 'execute grants',
         case when to_regprocedure('public.chat_topic_allows(text, boolean)') is null then null
              else 'authenticated ' || has_function_privilege('authenticated', 'public.chat_topic_allows(text, boolean)', 'execute')::text
                   || ', anon ' || has_function_privilege('anon', 'public.chat_topic_allows(text, boolean)', 'execute')::text
         end,
         'expected: authenticated true, anon false'

  union all
  -- ---- Policies on realtime.messages -----------------------------------------
  select 2, 0, 'policies', 'count on realtime.messages',
         (select count(*)::text from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages'),
         case when (select count(*) from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages') = 2
              then 'expected 2'
              when (select count(*) from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages') = 3
                   and exists (select 1 from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages'
                                 and p.policyname = 'table kicks: people at the table receive' and p.cmd = 'SELECT')
                   and to_regprocedure('public.kick_topic_allows(text)') is not null
              then 'expected 3: the two table-chat policies plus moderation M3''s kicks policy'
              else 'STOP: expected exactly the two table-chat policies (plus moderation M3''s kicks policy once M3 part 1 is in)' end

  union all
  select 2, row_number() over (order by p.policyname)::int, 'policies', p.policyname,
         p.cmd::text || ' to ' || p.roles::text,
         'using: ' || coalesce(p.qual, '-') || ' | with check: ' || coalesce(p.with_check, '-')
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'

  union all
  -- ---- table_spectators -----------------------------------------------------
  select 3, 0, 'spectators', 'public.table_spectators', null,
         case when to_regclass('public.table_spectators') is null then 'STOP: missing (spectators.sql not run?)'
              else 'exists, RLS ' || (select case when c.relrowsecurity then 'on' else 'OFF' end
                                      from pg_class c where c.oid = to_regclass('public.table_spectators')) end

  union all
  select 3, row_number() over (order by p.policyname)::int, 'spectators', 'policy: ' || p.policyname,
         p.cmd::text || ' to ' || p.roles::text,
         'using: ' || coalesce(p.qual, '-') || ' | with check: ' || coalesce(p.with_check, '-')
  from pg_policies p
  where p.schemaname = 'public' and p.tablename = 'table_spectators'

  union all
  select 3, 50, 'spectators', 'policy count',
         (select count(*)::text from pg_policies p where p.schemaname = 'public' and p.tablename = 'table_spectators'),
         'expected 1 (SELECT: members of the table, or your own row)'

  union all
  select 3, 100 + c.ordinal_position::int, 'spectators', 'column: ' || c.column_name::text,
         c.data_type::text || case when c.is_nullable = 'YES' then ', nullable' else ', not null' end,
         case when c.column_name in ('removed_at', 'last_seen_at') then 'read by "current"' else '' end
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'table_spectators'

  union all
  -- ---- tables.allow_spectators ----------------------------------------------
  select 4, 1, 'tables', 'tables.allow_spectators',
         coalesce((select c.data_type::text || case when c.is_nullable = 'YES' then ', nullable' else ', not null' end
                   from information_schema.columns c
                   where c.table_schema = 'public' and c.table_name = 'tables' and c.column_name = 'allow_spectators'),
                  'MISSING'),
         case when exists (select 1 from information_schema.columns c
                           where c.table_schema = 'public' and c.table_name = 'tables' and c.column_name = 'allow_spectators')
              then 'expected: boolean, not null' else 'STOP: missing' end

  union all
  -- ---- realtime.messages: partitions and grants ------------------------------
  select 5, 1, 'partitions', 'partitions of realtime.messages',
         (select count(*)::text from pg_inherits i where i.inhparent = to_regclass('realtime.messages')),
         'none: the live-policy lines in both verifications are skipped'

  union all
  select 5, 2, 'grants', 'authenticated on realtime.messages',
         case when to_regclass('realtime.messages') is null then null
              else 'SELECT ' || case when has_table_privilege('authenticated', 'realtime.messages', 'SELECT') then 'yes' else 'no' end
                   || ', INSERT ' || case when has_table_privilege('authenticated', 'realtime.messages', 'INSERT') then 'yes' else 'no' end
         end,
         'the live-policy lines need SELECT yes, INSERT yes (else skipped)'

  union all
  -- ---- Names ---------------------------------------------------------------
  select 6, 1, 'clear', 'get_table_spectators (any schema)',
         (select count(*)::text from pg_proc p where p.proname = 'get_table_spectators'),
         case when exists (select 1 from pg_proc p where p.proname = 'get_table_spectators')
              then 'PRESENT (expected only on a re-run)' else 'absent' end

  union all
  select 6, 2, 'clear', 'other public functions with "chat" in the name',
         coalesce((select string_agg(p.proname::text, ', ' order by p.proname)
                   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows'), '(none)'),
         case when exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                           where n.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows')
              then 'STOP: the existing chat suite''s C4 fails on any' else 'expected none' end

  union all
  -- ---- The spectator slices, for the record ----------------------------------
  select 7, 1, 'slices', 'watch_table',
         case when to_regprocedure('public.watch_table(text)') is null then 'missing'
              when (select p.prosrc from pg_proc p where p.oid = to_regprocedure('public.watch_table(text)')) ilike '%no game to watch%'
                   then 'slice 1 (refuses a table with no live game)'
              else 'slice 2 (accepts a table with no live game)' end,
         case when to_regprocedure('public.watch_table(text)') is null then 'STOP: spectators.sql not run?'
              else 'for the record; the verification works with either' end

  union all
  select 7, 2, 'slices', 'remove_spectator / spectator_heartbeat',
         case when to_regprocedure('public.remove_spectator(uuid, uuid)') is not null
                   and to_regprocedure('public.spectator_heartbeat(uuid)') is not null
              then 'both exist' else 'MISSING' end,
         case when to_regprocedure('public.remove_spectator(uuid, uuid)') is not null
                   and to_regprocedure('public.spectator_heartbeat(uuid)') is not null
              then 'the verification removes a spectator through remove_spectator'
              else 'STOP: spectators.sql not run?' end
) x
order by s, o;
