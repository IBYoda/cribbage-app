-- Moderation, slice M5 (b2): ROLLBACK of PART 1
-- (docs/sql/moderation-m5b2-part1.sql). Run in the Supabase Dashboard -> SQL
-- Editor. Kept here for reference/history; this project has no Supabase
-- CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- WHEN: roll the app back first if it already listens for 'scores' events
-- (an old app keeps working throughout: this slice never touched the
-- postgres_changes listeners or the publication). And only while no later
-- slice uses part 1's functions (the guard checks every function body and
-- trigger in public).
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD: no function in public other than part 1's own calls
--      _send_scores_event or _scores_event_at_commit, and no trigger other
--      than table_members_zz_scores_event uses _scores_event_at_commit; else
--      it raises and changes nothing.
--   1. Drops the trigger.
--   2. Drops _scores_event_at_commit and _send_scores_event.
--   Nothing else: part 1 added no column, policy or grant. Delivered events
--   (and Realtime's stored copies) are not touched; Realtime drops those on
--   its own schedule.
--
-- NOT TOUCHED: everything moderation-m5b2-part1.sql did not create.

begin;

do $$
declare
  v_txt text;
begin
  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname) into v_txt
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and (strpos(p.prosrc, '_send_scores_event') > 0 or strpos(p.prosrc, '_scores_event_at_commit') > 0)
    and p.proname not in ('_send_scores_event', '_scores_event_at_commit');
  if v_txt is not null then
    raise exception 'STOP: these functions use part 1''s functions: %. Roll back the slice that added them first. Nothing was changed.', v_txt;
  end if;

  select string_agg(tg.tgrelid::regclass::text || '.' || tg.tgname::text, ', ') into v_txt
  from pg_trigger tg
  where not tg.tgisinternal
    and tg.tgfoid = coalesce(to_regprocedure('public._scores_event_at_commit()')::oid, 0::oid)
    and tg.tgname <> 'table_members_zz_scores_event';
  if v_txt is not null then
    raise exception 'STOP: other triggers use _scores_event_at_commit: %. Nothing was changed.', v_txt;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The trigger.
-- ---------------------------------------------------------------------------
drop trigger if exists table_members_zz_scores_event on public.table_members;

-- ---------------------------------------------------------------------------
-- 2. The functions.
-- ---------------------------------------------------------------------------
drop function if exists public._scores_event_at_commit();
drop function if exists public._send_scores_event(uuid, jsonb);

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  not exists (select 1 from pg_trigger tg where tg.tgname = 'table_members_zz_scores_event' and not tg.tgisinternal) as scores_trigger_gone,
  to_regprocedure('public._scores_event_at_commit()') is null as trigger_fn_gone,
  to_regprocedure('public._send_scores_event(uuid, jsonb)') is null as send_fn_gone;
