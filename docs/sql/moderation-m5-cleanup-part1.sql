-- Moderation, M5 FINAL CLEANUP: take the old tables OUT of the
-- supabase_realtime publication. PART 1 (the only part). Run in the Supabase
-- Dashboard -> SQL Editor. Kept here for reference/history; this project has
-- no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- WHY NOW: the app listens to no table any more. App B (PR #144) removed every
-- postgres_changes listener; the table's private broadcast topic
-- table:<table_id> (moderation M5a/M5b1/M5b2/M5c1 -- realtime.send from
-- database triggers and from send_table_message) is the only live path, and
-- the offline fix (PR #145) is live. Every row change to a published table
-- still costs Realtime work (it decodes the WAL change and checks it against
-- every postgres_changes subscription); with nobody subscribed that is waste.
-- Decisions (Walt): all five tables, profiles included (nothing listens to
-- it). An OLD open tab (the app before App B) loses its postgres_changes
-- events: its own M5 table channel and safety poll keep it working, with
-- fewer sounds (a reload fixes it). The reload banner is a later step.
--
-- DEPLOY ORDER:
--   1. docs/sql/moderation-m5-cleanup-precheck.sql      (read-only; no STOP
--      rows, state "before part 1")
--   2. docs/sql/moderation-m5-cleanup-part1.sql         (THIS FILE)
--   3. docs/sql/moderation-m5-cleanup-verification.sql  ("ALL n CHECKS PASSED")
--   4. the suites to re-run (moderation-m5-cleanup-precheck.sql's header)
--   Rollback: docs/sql/moderation-m5-cleanup-part1-rollback.sql.
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold): the publication
--      supabase_realtime exists and is not FOR ALL TABLES; it holds EXACTLY
--      public.game_plays, public.games, public.profiles,
--      public.table_members and public.tables -- nothing else, and not
--      table_spectators; none of the five has a column list or a row filter
--      (so the rollback's plain ADD TABLE restores them exactly).
--      NOT RE-RUNNABLE BY DESIGN: a second run STOPs at the guard (the five
--      are gone).
--   1. alter publication supabase_realtime drop table <the five>.
--
-- NOT TOUCHED: the publication itself (it stays, empty) and its settings
-- (publish insert/update/delete/truncate, publish_via_partition_root); any
-- other publication (Realtime's own for realtime.messages included: the
-- broadcast topics do not use supabase_realtime); the tables, their replica
-- identity, triggers, policies and grants; every function; realtime.messages
-- and its two policies.

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard.
-- ---------------------------------------------------------------------------
do $$
declare
  v_txt text;
  v_all boolean;
begin
  select p.puballtables into v_all from pg_publication p where p.pubname = 'supabase_realtime';
  if v_all is null then
    raise exception 'STOP: the publication supabase_realtime does not exist. Nothing was changed.';
  end if;
  if v_all then
    raise exception 'STOP: supabase_realtime is FOR ALL TABLES; dropping single tables is not possible. Nothing was changed.';
  end if;

  select string_agg(pt.schemaname || '.' || pt.tablename, ', ' order by pt.schemaname, pt.tablename) into v_txt
  from pg_publication_tables pt
  where pt.pubname = 'supabase_realtime';
  if v_txt is distinct from 'public.game_plays, public.games, public.profiles, public.table_members, public.tables' then
    raise exception 'STOP: supabase_realtime holds "%", not exactly the five tables (game_plays, games, profiles, table_members, tables). This file already ran, or something else changed it. Nothing was changed.', coalesce(v_txt, '(nothing)');
  end if;

  -- A column list (prattrs) or a row filter (prqual) is stored per table in
  -- pg_publication_rel; null means "all columns, every row".
  select string_agg(c.relname::text, ', ' order by c.relname) into v_txt
  from pg_publication_rel pr
  join pg_publication p on p.oid = pr.prpubid
  join pg_class c on c.oid = pr.prrelid
  where p.pubname = 'supabase_realtime'
    and (pr.prattrs is not null or pr.prqual is not null);
  if v_txt is not null then
    raise exception 'STOP: these tables are published with a column list or a row filter: %. The rollback would not restore them exactly. Nothing was changed.', v_txt;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The five tables out of the publication.
-- ---------------------------------------------------------------------------
alter publication supabase_realtime drop table public.game_plays, public.games, public.profiles, public.table_members, public.tables;

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  exists (select 1 from pg_publication p where p.pubname = 'supabase_realtime') as publication_still_exists,
  (select count(*) from pg_publication_tables pt where pt.pubname = 'supabase_realtime') as tables_in_it,
  (select count(*) from pg_publication_tables pt where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public' and pt.tablename = 'table_spectators') as table_spectators_in_it;
