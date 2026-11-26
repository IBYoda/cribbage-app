-- Moderation, slice M5 (a): ROLLBACK of PART 1
-- (docs/sql/moderation-m5a-part1.sql). Run in the Supabase Dashboard -> SQL
-- Editor. Kept here for reference/history; this project has no Supabase
-- CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- WHEN: roll the app back first if it already listens on table:<id> (an
-- old app keeps working throughout: this slice never touched the
-- postgres_changes listeners or the publication). And only while no later
-- slice uses _send_table_event (the guard checks every function body in
-- public).
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD: no function in public other than part 1's own calls
--      _send_table_event, and no trigger other than part 1's three calls a
--      part 1 trigger function; else it raises and changes nothing.
--   1. Drops the "table events: people at the table receive" policy on
--      realtime.messages (the two table-chat policies and M3's kicks policy
--      stay).
--   2. Drops the three triggers.
--   3. Drops table_topic_allows, the three trigger functions and
--      _send_table_event.
--   4. Drops public.tables.roster_version. One-way only for the version
--      numbers themselves, which mean nothing once nothing sends them. The
--      table events already delivered (and Realtime's stored copies of them,
--      which hold only ids and versions) are not touched; Realtime drops
--      those on its own schedule.
--
-- NOT TOUCHED: everything moderation-m5a-part1.sql did not create.

begin;

do $$
declare
  v_txt text;
begin
  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname) into v_txt
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and strpos(p.prosrc, '_send_table_event') > 0
    and p.proname not in ('_send_table_event', '_table_event_on_members', '_table_event_on_spectators', '_table_event_on_tables');
  if v_txt is not null then
    raise exception 'STOP: these functions call _send_table_event: %. Roll back the slice that added them first. Nothing was changed.', v_txt;
  end if;

  select string_agg(tg.tgrelid::regclass::text || '.' || tg.tgname::text, ', ') into v_txt
  from pg_trigger tg
  where not tg.tgisinternal
    and tg.tgfoid in (coalesce(to_regprocedure('public._table_event_on_members()')::oid, 0::oid),
                      coalesce(to_regprocedure('public._table_event_on_spectators()')::oid, 0::oid),
                      coalesce(to_regprocedure('public._table_event_on_tables()')::oid, 0::oid))
    and tg.tgname not in ('table_members_zz_table_event', 'table_spectators_zz_table_event', 'tables_zz_table_event');
  if v_txt is not null then
    raise exception 'STOP: other triggers use part 1''s trigger functions: %. Nothing was changed.', v_txt;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The policy.
-- ---------------------------------------------------------------------------
drop policy if exists "table events: people at the table receive" on realtime.messages;

-- ---------------------------------------------------------------------------
-- 2. The triggers.
-- ---------------------------------------------------------------------------
drop trigger if exists table_members_zz_table_event on public.table_members;
drop trigger if exists table_spectators_zz_table_event on public.table_spectators;
drop trigger if exists tables_zz_table_event on public.tables;

-- ---------------------------------------------------------------------------
-- 3. The functions.
-- ---------------------------------------------------------------------------
drop function if exists public.table_topic_allows(text);
drop function if exists public._table_event_on_members();
drop function if exists public._table_event_on_spectators();
drop function if exists public._table_event_on_tables();
drop function if exists public._send_table_event(uuid, text, bigint);

-- ---------------------------------------------------------------------------
-- 4. The column.
-- ---------------------------------------------------------------------------
alter table public.tables drop column if exists roster_version;

notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  not exists (select 1 from pg_attribute a where a.attrelid = 'public.tables'::regclass and a.attname = 'roster_version' and not a.attisdropped) as roster_version_gone,
  (select count(*) from pg_trigger tg where not tg.tgisinternal
     and tg.tgname in ('table_members_zz_table_event', 'table_spectators_zz_table_event', 'tables_zz_table_event')) as table_event_triggers_left,
  to_regprocedure('public.table_topic_allows(text)') is null as topic_rule_gone,
  (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages') as realtime_messages_policies;
