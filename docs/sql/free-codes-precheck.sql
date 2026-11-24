-- Step 3, slice B: FREE TABLE CODES. The PRE-CHECK (read-only). Run in the
-- Supabase Dashboard -> SQL Editor before docs/sql/free-codes-part1.sql, AND
-- again before docs/sql/free-codes-part2.sql. It reads only; it changes
-- nothing.
--
-- STATUS: written, NOT RUN yet.
--
-- ONE query, so the editor shows every line in one result. Columns: phase,
-- section, item, value, note. phase says which run a row matters for:
-- "part 1" rows before part 1, "part 2" rows before part 2, "both" always.
-- A note starting with STOP means: do not run the next file; paste the
-- result back first.
--
-- THE FUNCTIONS SLICE B REPLACES, by the md5 of the LIVE body (pg_proc.prosrc),
-- against the committed texts (LF and CRLF) -- the lesson of
-- create_computer_table: the live text may not be the file's.
--   before part 1 (join-create.sql's text, slice A):
--     _one_table_rule      432da2f645b040f231bc94a9bf59f193 / 897da4be39185f470900fda2a389c287
--     join_table_by_code   fd0d36e399b6cec1f5411080ddf536d1 / 54edb54394387ea3c5260d210891f92a
--     watch_table          cf51f6fa98e9f65332eaed6df91a1ae7 / ecea3524022f106a3525c93885a09f2d
--   after part 1 (free-codes-part1.sql's text):
--     _one_table_rule      30437ab489be968f83ae9ffd68266f0f / e456c651d5a66b5bcf9d7b59d8efab23
--     join_table_by_code   1a2ff167c6d09fef6acd17177493422d / 9f3cee04a063447d626a1354533fda51
--     watch_table          43775b57dffaec98ee7c003304a0c951 / df591fa16528afd81a13bfdc3e975538
--     set_table_ended_at   a0d6d38177b6ac53bcdd1a12a055fa40 / 5b0f39b0b4b603e280dc4ef49633454f
--   before part 2 (join-create.sql's text):
--     create_table         d1f3a2c02bfc3cf127e246d5cb84f967 / 131dbe8201d2e515457819abc18a31a1
--     create_computer_table af252001689df4b15046eb3c84f17184 / c40f456c21e0934083f918dc0973d302
--   after part 2 (free-codes-part2.sql's text):
--     create_table         50f115191df0b179df7b7db12e94b4f2 / e45369e10a5a264114ed4d827d6c51c6
--     create_computer_table 070e848f871022ec4ca4bac766cd12af / 205bac8b7208f22ab8cd20a85473e6dd
--     _pick_table_code     c01d4b4e05a6dea4856a6bbf2889b830 / a81f90900357848f03cec5e2e6a0140c
-- Anything else: STOP, and capture the live body first, e.g.
--   select pg_get_functiondef('public.watch_table(text)'::regprocedure);
--
-- ALSO: tables_code_key and anything that depends on it (a foreign key to
-- tables(code)), every index and trigger on tables, two open tables sharing
-- a code (must be 0), the code counts (open tables, ever used, never used),
-- and -- once part 1 is in -- ended_at's backfill, the codes in the 24-hour
-- cooldown and the free pool outside it (part 2's picker falls back below
-- 1,000).

with
  fns(o, fn, sig, a_lf, a_crlf, b_lf, b_crlf, a_src, b_src, b_marker) as (
    values
      (1, '_one_table_rule', 'public._one_table_rule(uuid, uuid, boolean)',
       '432da2f645b040f231bc94a9bf59f193', '897da4be39185f470900fda2a389c287',
       '30437ab489be968f83ae9ffd68266f0f', 'e456c651d5a66b5bcf9d7b59d8efab23', 'join-create.sql', 'free-codes-part1.sql', 'part 1'),
      (2, 'join_table_by_code', null,
       'fd0d36e399b6cec1f5411080ddf536d1', '54edb54394387ea3c5260d210891f92a',
       '1a2ff167c6d09fef6acd17177493422d', '9f3cee04a063447d626a1354533fda51', 'join-create.sql', 'free-codes-part1.sql', 'part 1'),
      (3, 'watch_table', null,
       'cf51f6fa98e9f65332eaed6df91a1ae7', 'ecea3524022f106a3525c93885a09f2d',
       '43775b57dffaec98ee7c003304a0c951', 'df591fa16528afd81a13bfdc3e975538', 'join-create.sql', 'free-codes-part1.sql', 'part 1'),
      (4, 'create_table', 'public.create_table(boolean, boolean, integer, text, boolean)',
       'd1f3a2c02bfc3cf127e246d5cb84f967', '131dbe8201d2e515457819abc18a31a1',
       '50f115191df0b179df7b7db12e94b4f2', 'e45369e10a5a264114ed4d827d6c51c6', 'join-create.sql', 'free-codes-part2.sql', 'part 2'),
      (5, 'create_computer_table', 'public.create_computer_table(text, text)',
       'af252001689df4b15046eb3c84f17184', 'c40f456c21e0934083f918dc0973d302',
       '070e848f871022ec4ca4bac766cd12af', '205bac8b7208f22ab8cd20a85473e6dd', 'join-create.sql', 'free-codes-part2.sql', 'part 2')
  ),
  live as (
    select f.*,
           (select md5(p.prosrc) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
            where ns.nspname = 'public' and p.proname = f.fn
              and (f.sig is null or p.oid = to_regprocedure(f.sig))
            order by p.oid desc limit 1) as md5_now,
           (select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
            where ns.nspname = 'public' and p.proname = f.fn) as signatures
    from fns f
  )
select phase, section, item, value, note
from (
  -- ---- The functions slice B replaces -------------------------------------------
  select 1 as s, l.o as o, 'both' as phase, 'fn' as section, l.fn || ': live body md5' as item,
         coalesce(l.md5_now, '(missing)') || ' | ' || coalesce(l.signatures, '(none)') as value,
         case when l.md5_now in (l.a_lf, l.a_crlf) then l.a_src || '''s text (slice A): ready for ' || l.b_marker
              when l.md5_now in (l.b_lf, l.b_crlf) then l.b_src || '''s text: ' || l.b_marker || ' is already in'
              else 'STOP: neither ' || l.a_src || '''s nor ' || l.b_src || '''s text. Capture it first (pg_get_functiondef) and paste it back' end as note
  from live l

  union all
  select 1, 6, 'both', 'fn', 'set_table_ended_at: live body md5',
         coalesce((select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.set_table_ended_at()')), '(missing)'),
         case (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public.set_table_ended_at()'))
              when 'a0d6d38177b6ac53bcdd1a12a055fa40' then 'free-codes-part1.sql''s text: part 1 is in'
              when '5b0f39b0b4b603e280dc4ef49633454f' then 'free-codes-part1.sql''s text: part 1 is in'
              else case when to_regprocedure('public.set_table_ended_at()') is null then 'expected missing before part 1'
                        else 'STOP: an unknown set_table_ended_at exists' end end

  union all
  select 1, 7, 'part 2', 'fn', '_pick_table_code: live body md5',
         coalesce((select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public._pick_table_code(integer)')), '(missing)'),
         case (select md5(p.prosrc) from pg_proc p where p.oid = to_regprocedure('public._pick_table_code(integer)'))
              when 'c01d4b4e05a6dea4856a6bbf2889b830' then 'free-codes-part2.sql''s text: part 2 is in'
              when 'a81f90900357848f03cec5e2e6a0140c' then 'free-codes-part2.sql''s text: part 2 is in'
              else case when to_regprocedure('public._pick_table_code(integer)') is null then 'expected missing before part 2'
                        else 'STOP: an unknown _pick_table_code exists' end end

  union all
  select 1, 8, 'both', 'fn', 'other public functions with "chat" in the name',
         coalesce((select string_agg(p.proname::text, ', ' order by p.proname)
                   from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                   where ns.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows'), '(none)'),
         case when exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                           where ns.nspname = 'public' and p.proname ilike '%chat%' and p.proname <> 'chat_topic_allows')
              then 'STOP: the chat suite''s C4 fails on any' else 'expected none (slice B adds none)' end

  union all
  -- ---- The unique key, its dependents, indexes and triggers ------------------------
  select 2, 1, 'part 2', 'key', 'tables_code_key',
         coalesce((select pg_get_constraintdef(con.oid) from pg_constraint con
                   where con.conrelid = 'public.tables'::regclass and con.conname = 'tables_code_key'), '(gone)'),
         case when exists (select 1 from pg_constraint con where con.conrelid = 'public.tables'::regclass and con.conname = 'tables_code_key')
              then 'present: part 2 replaces it with tables_code_open_key'
              else 'gone: part 2 is in (or the key had another name -- then STOP)' end

  union all
  select 2, 2, 'part 2', 'key', 'foreign keys referencing tables(code)',
         (select count(*)::text from pg_constraint con
          where con.contype = 'f' and con.confrelid = 'public.tables'::regclass
            and (select a.attnum from pg_attribute a where a.attrelid = 'public.tables'::regclass and a.attname = 'code') = any (con.confkey)),
         case when exists (select 1 from pg_constraint con
                           where con.contype = 'f' and con.confrelid = 'public.tables'::regclass
                             and (select a.attnum from pg_attribute a where a.attrelid = 'public.tables'::regclass and a.attname = 'code') = any (con.confkey))
              then 'STOP: a foreign key depends on tables(code); dropping the key would fail'
              else 'expected 0 (nothing references a table by code)' end

  union all
  select 2, 3, 'both', 'key', 'indexes on tables',
         (select string_agg(i.indexname || ': ' || i.indexdef, ' | ' order by i.indexname)
          from pg_indexes i where i.schemaname = 'public' and i.tablename = 'tables'),
         'part 1 adds tables_ended_at_idx; part 2 adds tables_code_open_key and tables_code_idx and drops tables_code_key'

  union all
  select 2, 4, 'both', 'key', 'triggers on tables',
         coalesce((select string_agg(tg.tgname::text || ' -> ' || tg.tgfoid::regprocedure::text
                                     || case when tg.tgenabled::text = 'D' then ' (DISABLED)' else '' end, ', ' order by tg.tgname)
                   from pg_trigger tg where tg.tgrelid = 'public.tables'::regclass and not tg.tgisinternal), '(none)'),
         'part 1 adds tables_set_ended_at (BEFORE INSERT OR UPDATE: stamps ended_at); any other BEFORE UPDATE trigger here is listed for review'

  union all
  -- ---- Codes ---------------------------------------------------------------------------
  select 3, 1, 'both', 'codes', 'two OPEN tables sharing a code',
         (select count(*)::text from (select t.code from public.tables t where t.status <> 'ended' group by t.code having count(*) > 1) x),
         case when exists (select 1 from public.tables t where t.status <> 'ended' group by t.code having count(*) > 1)
              then 'STOP: the partial unique index can''t be built' else 'expected 0' end

  union all
  select 3, 2, 'both', 'codes', 'tables: all / open / ended',
         (select count(*)::text || ' / ' || count(*) filter (where t.status <> 'ended')::text
                 || ' / ' || count(*) filter (where t.status = 'ended')::text from public.tables t),
         'the open count is the codes held right now'

  union all
  select 3, 3, 'both', 'codes', 'codes ever used / never used (of 10000)',
         (select count(distinct t.code)::text from public.tables t) || ' / '
         || (select count(*)::text from generate_series(0, 9999) n
             where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, '0'))),
         'right after part 1 every ended table is stamped "ended now", so for 24 hours the pool outside the cooldown is the never-used codes; below 1,000, part 2''s picker uses its fallback (least recently ended) -- still correct'

  union all
  select 3, 4, 'both', 'codes', 'shared codes among ALL tables (a code reused)',
         (select count(*)::text from (select t.code from public.tables t group by t.code having count(*) > 1) x),
         'expected 0 until part 2 runs; after it, any count here makes part 2 one-way (tables_code_key can''t come back)'

  union all
  -- ---- ended_at (after part 1) -----------------------------------------------------------
  select 4, 1, 'part 2', 'ended_at', 'ended_at present / ended tables without it / open tables with it',
         case when not exists (select 1 from pg_attribute a where a.attrelid = 'public.tables'::regclass and a.attname = 'ended_at' and not a.attisdropped)
              then 'no ended_at column yet'
              else query_to_xml('select count(*) filter (where status = ''ended'' and ended_at is null) as ended_without, count(*) filter (where status <> ''ended'' and ended_at is not null) as open_with from public.tables', false, false, '')::text end,
         case when not exists (select 1 from pg_attribute a where a.attrelid = 'public.tables'::regclass and a.attname = 'ended_at' and not a.attisdropped)
              then 'expected before part 1; STOP before part 2 (part 1 has not run)'
              else 'expected 0 and 0 (the backfill and the trigger)' end

  union all
  select 4, 2, 'part 2', 'ended_at', 'codes in the 24-hour cooldown / free codes outside it',
         case when not exists (select 1 from pg_attribute a where a.attrelid = 'public.tables'::regclass and a.attname = 'ended_at' and not a.attisdropped)
              then 'no ended_at column yet'
              else query_to_xml(
                'select (select count(distinct code) from public.tables where status = ''ended'' and ended_at > now() - interval ''24 hours'') as in_cooldown, '
                || '(select count(*) from generate_series(0, 9999) n where not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, ''0'') and t.status <> ''ended'') '
                || 'and not exists (select 1 from public.tables t where t.code = lpad(n::text, 4, ''0'') and t.status = ''ended'' and t.ended_at > now() - interval ''24 hours'')) as free_outside_cooldown',
                false, false, '')::text end,
         'free_outside_cooldown below 1000: the picker uses its fallback (any free code, least recently ended first) until codes age out'
) x
order by s, o;
