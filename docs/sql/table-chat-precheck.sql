-- Table chat, slice 1: the PRE-CHECK (read-only)
-- Run in the Supabase Dashboard -> SQL Editor before table-chat.sql. It
-- reads only; it changes nothing.
--
-- STATUS: RUN in production on 2026-11-14. Realtime Authorization present
-- (realtime.messages with RLS on, realtime.topic() exists); authenticated
-- has SELECT and INSERT on realtime.messages; 0 existing policies on it; 7
-- daily partitions; tables.status only 'open' and 'ended' (454 ended, 3 open
-- at the time); table_members has no left/active flag; the computer_level
-- check allows 'easy' / 'casual' / 'medium' / 'hard'.
--
-- RUN ORDER (as run on 2026-11-14):
--   1. docs/sql/table-chat-precheck.sql      (this file, read-only)
--   2. docs/sql/table-chat.sql               (the function and two policies)
--   3. docs/sql/table-chat-verification.sql  (writes test rows, then rolls
--                                             them all back; its final
--                                             message is the verdict)
--   If it has to come out: docs/sql/table-chat-rollback.sql.
--
-- ONE query, so the editor shows every line in one result (it shows only the
-- last result of a multi-statement run). Columns: section, item, value, note.
--
-- WHAT IT LOOKED FOR (table-chat.sql's rules depend on each of these; the
-- 2026-11-14 run matched them all, see STATUS):
--   realtime    realtime.messages "exists", RLS "on", realtime.topic()
--               "exists". If realtime.messages is missing, the project's
--               Realtime has no Authorization yet: stop.
--               grants: authenticated needs SELECT and INSERT on
--               realtime.messages (Realtime checks a private channel by
--               running a select / insert AS the player, under the
--               policies). "no" for either: stop.
--               partitions: how many daily partitions realtime.messages has.
--               With none, the verification's live-policy lines say
--               "skipped" (it then proves the rules through the function and
--               pg_policies only).
--   policies    every policy ALREADY on realtime.messages, with its command,
--               roles and rule. Expected: none. Policies are OR'ed together,
--               so an existing broad one (say "authenticated can read
--               everything") would let anyone hear any chat: stop and look.
--   clear       chat_topic_allows: "absent" in every schema, and neither
--               policy name taken. "PRESENT": stop and look first.
--   status      every tables.status value with its count (split by human /
--               computer table), its default and any check on it. The repo
--               says only 'open' and 'ended' exist (see table-chat.sql's
--               header). Any OTHER value: stop before running
--               table-chat.sql, because chat allows only 'open'.
--   ended_why   tables.ended_reason values, for the record.
--   members     every column of public.table_members. The repo says
--               table_id, user_id, joined_at, score, last_points,
--               last_reason, last_awarded_at, seat (plus any later ones) --
--               and NO "left" / "active" flag: a player who leaves is
--               DELETED. A column like left_at / active / removed: stop
--               (the rule would have to check it).
--   computer    tables.computer_level: text, nullable, with a check of
--               'easy' / 'medium' / 'hard'; null means a human table.

select section, item, value, note
from (
  -- ---- Realtime Authorization's own pieces ----------------------------------
  select 1 as s, 1 as o, 'realtime' as section, 'realtime.messages' as item,
         null::text as value,
         case when to_regclass('realtime.messages') is null then 'MISSING' else 'exists' end as note

  union all
  select 1, 2, 'realtime', 'RLS on realtime.messages', null,
         coalesce((select case when c.relrowsecurity then 'on' else 'OFF' end
                   from pg_class c where c.oid = to_regclass('realtime.messages')), 'n/a')

  union all
  select 1, 3, 'realtime', 'realtime.topic()', null,
         case when exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                           where ns.nspname = 'realtime' and p.proname = 'topic')
              then 'exists' else 'MISSING' end

  union all
  -- The client roles' table privileges on realtime.messages.
  select 1, 3 + r.ord, 'realtime', 'grants: ' || r.rolname || ' on realtime.messages',
         case when to_regclass('realtime.messages') is null then null
              else 'SELECT ' || case when has_table_privilege(r.rolname, 'realtime.messages', 'SELECT') then 'yes' else 'no' end
                   || ', INSERT ' || case when has_table_privilege(r.rolname, 'realtime.messages', 'INSERT') then 'yes' else 'no' end
         end,
         case when r.rolname = 'authenticated' then 'needs SELECT yes, INSERT yes'
              else 'for the record (no anon policy, so anon gets nothing)' end
  from (values ('authenticated', 1), ('anon', 2)) as r(rolname, ord)

  union all
  select 1, 6, 'realtime', 'partitions of realtime.messages',
         (select count(*)::text from pg_inherits i where i.inhparent = to_regclass('realtime.messages')),
         'none: the verification''s live-policy lines are skipped'

  union all
  -- ---- Policies already on realtime.messages ---------------------------------
  select 2, row_number() over (order by p.policyname)::int, 'policies', p.policyname,
         p.cmd::text || ' to ' || p.roles::text,
         'using: ' || coalesce(p.qual, '-') || ' | with check: ' || coalesce(p.with_check, '-')
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'

  union all
  select 2, 0, 'policies', 'count on realtime.messages',
         (select count(*)::text from pg_policies p where p.schemaname = 'realtime' and p.tablename = 'messages'),
         'expected 0'

  union all
  -- ---- Names table-chat.sql will create --------------------------------------
  select 3, 1, 'clear', 'chat_topic_allows (any schema)',
         (select count(*)::text from pg_proc p where p.proname = 'chat_topic_allows'),
         case when exists (select 1 from pg_proc p where p.proname = 'chat_topic_allows')
              then 'PRESENT' else 'absent' end

  union all
  select 3, 1 + n.ord, 'clear', 'policy "' || n.name || '"', null,
         case when exists (select 1 from pg_policies p
                           where p.schemaname = 'realtime' and p.tablename = 'messages' and p.policyname = n.name)
              then 'PRESENT' else 'absent' end
  from (values ('table chat: members receive', 1), ('table chat: members send', 2)) as n(name, ord)

  union all
  -- ---- tables.status ---------------------------------------------------------
  select 4, row_number() over (order by t.status, t.computer_level is null)::int, 'status',
         coalesce(t.status, '(null)') || case when t.computer_level is null then ' / human table' else ' / computer table' end,
         count(*)::text,
         'tables'
  from public.tables t
  group by t.status, t.computer_level is null

  union all
  select 4, 100, 'status', 'tables.status default',
         (select c.column_default::text from information_schema.columns c
          where c.table_schema = 'public' and c.table_name = 'tables' and c.column_name = 'status'),
         'expected ''open''::text'

  union all
  select 4, 101, 'status', 'check on tables.status',
         coalesce((select string_agg(pg_get_constraintdef(c.oid), ' ; ')
                   from pg_constraint c
                   where c.conrelid = 'public.tables'::regclass and c.contype = 'c'
                     and pg_get_constraintdef(c.oid) ilike '%status%'), '(none)'),
         'the repo adds none'

  union all
  select 5, row_number() over (order by t.ended_reason)::int, 'ended_why',
         coalesce(t.ended_reason, '(null)'), count(*)::text, 'ended tables'
  from public.tables t
  where t.status <> 'open'
  group by t.ended_reason

  union all
  -- ---- table_members' columns ------------------------------------------------
  select 6, c.ordinal_position::int, 'members', c.column_name::text,
         c.data_type::text || case when c.is_nullable = 'YES' then ', nullable' else ', not null' end,
         coalesce('default ' || c.column_default::text, '')
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'table_members'

  union all
  -- ---- tables.computer_level -------------------------------------------------
  select 7, 1, 'computer', 'tables.computer_level',
         coalesce((select c.data_type::text || case when c.is_nullable = 'YES' then ', nullable' else ', not null' end
                   from information_schema.columns c
                   where c.table_schema = 'public' and c.table_name = 'tables' and c.column_name = 'computer_level'),
                  'MISSING'),
         coalesce((select string_agg(pg_get_constraintdef(c.oid), ' ; ')
                   from pg_constraint c
                   where c.conrelid = 'public.tables'::regclass and c.contype = 'c'
                     and pg_get_constraintdef(c.oid) ilike '%computer_level%'), '(no check)')
) x
order by s, o;
