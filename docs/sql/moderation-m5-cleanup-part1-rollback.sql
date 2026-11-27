-- Moderation, M5 FINAL CLEANUP: ROLLBACK of PART 1
-- (docs/sql/moderation-m5-cleanup-part1.sql). Run in the Supabase Dashboard
-- -> SQL Editor. Kept here for reference/history; this project has no
-- Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- WHAT IT RESTORES, EXACTLY: public.game_plays, public.games,
-- public.profiles, public.table_members and public.tables back in the
-- supabase_realtime publication, each with ALL columns and NO row filter --
-- how they were: part 1's guard (and the precheck's "filters" row) refused
-- to run unless none of the five had a column list or a row filter. The
-- publication's own settings (publish insert/update/delete/truncate,
-- publish_via_partition_root) belong to the publication, which part 1 never
-- touched; replica identity belongs to each table, likewise untouched.
--
-- WHEN: only if something still needs postgres_changes on these tables (the
-- app since App B, PR #144, does not). An old open tab gets its events back.
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD: the publication exists, is not FOR ALL TABLES, and holds none
--      of the five (part 1 ran); else it raises and changes nothing. Not
--      re-runnable: a second run STOPs at the guard.
--   1. alter publication supabase_realtime add table <the five>.

begin;

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
    raise exception 'STOP: supabase_realtime is FOR ALL TABLES. Nothing was changed.';
  end if;
  select string_agg(pt.tablename::text, ', ' order by pt.tablename) into v_txt
  from pg_publication_tables pt
  where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public'
    and pt.tablename in ('game_plays', 'games', 'profiles', 'table_members', 'tables');
  if v_txt is not null then
    raise exception 'STOP: supabase_realtime already holds %: part 1 did not run, or this file already ran. Nothing was changed.', v_txt;
  end if;
end;
$$;

alter publication supabase_realtime add table public.game_plays, public.games, public.profiles, public.table_members, public.tables;

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  (select string_agg(pt.schemaname || '.' || pt.tablename, ', ' order by pt.schemaname, pt.tablename)
   from pg_publication_tables pt where pt.pubname = 'supabase_realtime') as published,
  (select count(*) from pg_publication_rel pr join pg_publication p on p.oid = pr.prpubid
   where p.pubname = 'supabase_realtime' and (pr.prattrs is not null or pr.prqual is not null)) as with_a_filter;
