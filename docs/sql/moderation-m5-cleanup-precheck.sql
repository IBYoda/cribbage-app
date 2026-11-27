-- Moderation, M5 FINAL CLEANUP: PRECHECK for taking the old tables OUT of the
-- supabase_realtime publication (READ-ONLY). Run in the Supabase Dashboard
-- -> SQL Editor before docs/sql/moderation-m5-cleanup-part1.sql, and again
-- after it. ONE statement; it only reads the catalog. Paste the whole result
-- back.
--
-- STATUS: written, NOT RUN yet.
--
-- Every row has a section, an item, a value and a note. A note starting
-- "STOP" means: do not run the next file; paste the result back. The first
-- row ("state") says where the cleanup stands:
--   before part 1   (the five tables published, nothing else)  -> run part 1
--   part 1 present  (the publication empty)                     -> done
--   anything else                                               -> STOP
--
-- SUITES AFTER PART 1:
--   RE-RUN: moderation-m5-cleanup-verification.sql (this step's own);
--   table-visibility-verification.sql (S5 re-baselined: tables out of the
--   publication once the cleanup ran); moderation-m5c1c2-verification.sql,
--   moderation-m5b2-verification.sql, moderation-m5b1-verification.sql,
--   moderation-m5a-verification.sql (the events, unchanged);
--   spectators-verification.sql (C7: table_spectators still not published);
--   slice-e-grants-verification.sql; computer-c1 / computer-c2 /
--   end-empty-tables-verification.sql (nothing they check changes).
--   The m5a / m5b1 / m5b2 / m5c1 prechecks and moderation-catalog.sql show
--   the publication as INFO only.
--
-- SECTIONS
--   state        the summary above.
--   publication  supabase_realtime: exists, FOR ALL TABLES (must be false),
--                what it publishes (insert/update/delete/truncate), via
--                partition root -- part 1 leaves all of these alone.
--   tables       each of the five: published or not, its column list and
--                row filter (must be none, so the rollback restores it
--                exactly), its replica identity (INFO; untouched).
--   others       anything else in supabase_realtime (STOP), table_spectators
--                (STOP if published), every other publication (INFO:
--                Realtime's own for realtime.messages is not touched).
--   events       the event functions and triggers the live path runs on
--                (fingerprints unchanged; part 1 touches none).

with five(o, tbl) as (
  values (1, 'game_plays'), (2, 'games'), (3, 'profiles'), (4, 'table_members'), (5, 'tables')
),
pub as (
  select p.oid, p.puballtables, p.pubinsert, p.pubupdate, p.pubdelete, p.pubtruncate, p.pubviaroot
  from pg_publication p
  where p.pubname = 'supabase_realtime'
),
published as (
  select pt.schemaname::text as sch, pt.tablename::text as tbl
  from pg_publication_tables pt
  where pt.pubname = 'supabase_realtime'
),
filters as (
  select c.relname::text as tbl, pr.prattrs is not null as has_columns, pr.prqual is not null as has_filter
  from pg_publication_rel pr
  join pub p on p.oid = pr.prpubid
  join pg_class c on c.oid = pr.prrelid
),
fp(o, fn, sig, lf) as (
  values
    (1, '_send_table_event', 'public._send_table_event(uuid, text, bigint)', 'df40bb9eac9b778a8d733d2d18393865'),
    (2, '_table_event_on_members', 'public._table_event_on_members()', '26f95e1c2dd4cb5cffbb8e784367cd92'),
    (3, '_table_event_on_spectators', 'public._table_event_on_spectators()', 'f81c329f92115ea11038cff9f0ffc184'),
    (4, '_table_event_on_tables', 'public._table_event_on_tables()', 'd950c48b22205b15e62e38411923fef5'),
    (5, 'table_topic_allows', 'public.table_topic_allows(text)', '57908d750db883e7687b926cbea3ab4a'),
    (6, '_bump_game_state_version', 'public._bump_game_state_version()', '35314b3677dd7b0b39a2ca32ee29e7c3'),
    (7, '_send_game_event', 'public._send_game_event(uuid, jsonb)', '462c8068b6c7a183ca76fa18fa6b7264'),
    (8, '_game_event_at_commit', 'public._game_event_at_commit()', 'cce9d688120f3dc2c155503270fe11ee'),
    (9, '_send_scores_event', 'public._send_scores_event(uuid, jsonb)', 'cf9d6f31090605e8e42ca7a26aae1d7d'),
    (10, '_scores_event_at_commit', 'public._scores_event_at_commit()', 'd06cc5e9fb12f0b0697dd4b4e43bd8a9'),
    (11, 'send_table_message', 'public.send_table_message(uuid, text)', 'e3adcc4874c77c1c47530a807fefd815'),
    (12, '_broadcast_table_message', 'public._broadcast_table_message(text, jsonb)', 'e5f16aebb3ca764c806e2567b68090fc')
),
trg(o, rel, name) as (
  values
    (1, 'public.table_members', 'table_members_zz_table_event'),
    (2, 'public.table_spectators', 'table_spectators_zz_table_event'),
    (3, 'public.tables', 'tables_zz_table_event'),
    (4, 'public.games', 'games_state_version'),
    (5, 'public.games', 'games_zz_game_event'),
    (6, 'public.game_plays', 'game_plays_zz_game_event'),
    (7, 'public.table_members', 'table_members_zz_scores_event')
),
flags as (
  select
    (select count(*) from published pb join five f on pb.sch = 'public' and pb.tbl = f.tbl) as five_in,
    (select count(*) from published pb where not (pb.sch = 'public' and pb.tbl in (select f.tbl from five f))) as others_in
)
select z.section::text as section, z.item::text as item, z.value::text as value, z.note::text as note
from (
  -- ==== state ====================================================================
  select 0 as s, 0 as o, 'state'::text as section, 'cleanup state'::text as item,
         ('the five in supabase_realtime: ' || f.five_in::text || ' of 5 | anything else: ' || f.others_in::text)::text as value,
         (case
            when not exists (select 1 from pub) then 'STOP: the publication supabase_realtime does not exist'
            when f.five_in = 5 and f.others_in = 0 then 'before part 1: run docs/sql/moderation-m5-cleanup-part1.sql next (if no other row says STOP)'
            when f.five_in = 0 and f.others_in = 0 then 'part 1 present: the publication is empty; re-run the suites listed in this file''s header'
            else 'STOP: a mixed or unexpected state (only some of the five, or other tables published); paste the whole result back'
          end)::text as note
  from flags f

  union all
  -- ==== publication ==============================================================
  select 1, 1, 'publication', 'supabase_realtime: exists / FOR ALL TABLES',
         coalesce((select 'exists / ' || p.puballtables::text from pub p), '(missing)'),
         case when not exists (select 1 from pub) then 'STOP: missing'
              when (select p.puballtables from pub p) then 'STOP: FOR ALL TABLES; single tables cannot be dropped'
              else 'as expected (part 1 keeps the publication itself)' end

  union all
  select 1, 2, 'publication', 'publishes insert / update / delete / truncate / via partition root',
         coalesce((select p.pubinsert::text || ' / ' || p.pubupdate::text || ' / ' || p.pubdelete::text || ' / '
                          || p.pubtruncate::text || ' / ' || p.pubviaroot::text from pub p), '-'),
         'INFO: the publication''s own settings; part 1 and the rollback never change them'

  union all
  -- ==== tables ===================================================================
  select 2, f.o, 'tables', 'public.' || f.tbl || ': published / column list / row filter / replica identity',
         (exists (select 1 from published pb where pb.sch = 'public' and pb.tbl = f.tbl))::text
           || ' / ' || coalesce((select fl.has_columns::text from filters fl where fl.tbl = f.tbl), '-')
           || ' / ' || coalesce((select fl.has_filter::text from filters fl where fl.tbl = f.tbl), '-')
           || ' / ' || coalesce((select case c.relreplident when 'd' then 'default' when 'f' then 'full' when 'n' then 'nothing' when 'i' then 'index' end
                                 from pg_class c where c.oid = to_regclass('public.' || f.tbl)), '(no table)'),
         case when exists (select 1 from filters fl where fl.tbl = f.tbl and (fl.has_columns or fl.has_filter))
                then 'STOP: a column list or a row filter; the rollback would not restore it exactly'
              when exists (select 1 from published pb where pb.sch = 'public' and pb.tbl = f.tbl)
                then 'before part 1: published, all columns, every row (part 1 drops it; the rollback adds it back the same way)'
              else 'after part 1: not published, as expected' end
  from five f

  union all
  -- ==== others ===================================================================
  select 3, 1, 'others', 'anything else in supabase_realtime',
         coalesce((select string_agg(pb.sch || '.' || pb.tbl, ', ' order by pb.sch, pb.tbl) from published pb
                   where not (pb.sch = 'public' and pb.tbl in (select f.tbl from five f))), '(none)'),
         case when exists (select 1 from published pb where not (pb.sch = 'public' and pb.tbl in (select f.tbl from five f)))
                then 'STOP: an unexpected table is published; look at it first'
              else 'as expected' end

  union all
  select 3, 2, 'others', 'public.table_spectators in supabase_realtime',
         (exists (select 1 from published pb where pb.sch = 'public' and pb.tbl = 'table_spectators'))::text,
         case when exists (select 1 from published pb where pb.sch = 'public' and pb.tbl = 'table_spectators')
                then 'STOP: it must never be published (spectators-verification.sql C7)'
              else 'as expected: never published' end

  union all
  select 3, 3, 'others', 'every other publication: its tables',
         coalesce((select string_agg(pt.pubname || ': ' || pt.schemaname || '.' || pt.tablename, ', ' order by pt.pubname, pt.schemaname, pt.tablename)
                   from pg_publication_tables pt where pt.pubname <> 'supabase_realtime'), '(none)'),
         'INFO: not touched (Realtime delivers the broadcast topics from realtime.messages through its own replication, not through supabase_realtime)'

  union all
  -- ==== events ===================================================================
  select 4, k.o, 'events', k.fn || ': md5 of the live body (carriage returns removed)',
         coalesce((select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure(k.sig)), '(missing)'),
         case when (select md5(replace(p.prosrc, E'\r', '')) from pg_proc p where p.oid = to_regprocedure(k.sig)) = k.lf
                then 'as expected (unchanged; part 1 touches no function)'
              else 'STOP: not the fingerprinted body (or missing); the live event path is not what the suites expect' end
  from fp k

  union all
  select 4, 20 + t.o, 'events', 'trigger ' || t.name || ' on ' || t.rel,
         coalesce((select tg.tgenabled::text from pg_trigger tg where tg.tgrelid = to_regclass(t.rel) and tg.tgname = t.name and not tg.tgisinternal), '(missing)'),
         case when (select tg.tgenabled from pg_trigger tg where tg.tgrelid = to_regclass(t.rel) and tg.tgname = t.name and not tg.tgisinternal) = 'O'
                then 'as expected: enabled (the live event path)'
              else 'STOP: missing or disabled' end
  from trg t
) z
order by z.s, z.o, z.item;
