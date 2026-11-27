-- Moderation, slice M5 (c1): ROLLBACK of PART 1
-- (docs/sql/moderation-m5c1-part1.sql). Run in the Supabase Dashboard -> SQL
-- Editor. Kept here for reference/history; this project has no Supabase
-- CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- WHEN: roll the app back first if it already sends through
-- send_table_message (an app that calls it after this rollback gets "could
-- not find the function" on every send). Before the c2 app ships nothing
-- calls it, and the old chat:<t>:<sender> channels were never touched. And
-- only while no later slice uses part 1's functions (the guard checks every
-- function body in public).
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD: no function in public other than part 1's own calls
--      send_table_message or _broadcast_table_message; else it raises and
--      changes nothing.
--   1. Drops send_table_message and _broadcast_table_message (their grants
--      go with them: client-callable functions 61 -> 60).
--   Nothing else: part 1 added no table, column, policy, trigger or
--   publication change. Messages already sent (and Realtime's stored
--   copies) are not touched; Realtime drops those on its own schedule.
--
-- NOT TOUCHED: everything moderation-m5c1-part1.sql did not create.

begin;

do $$
declare
  v_txt text;
begin
  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname) into v_txt
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and (strpos(p.prosrc, 'send_table_message') > 0 or strpos(p.prosrc, '_broadcast_table_message') > 0)
    and p.proname not in ('send_table_message', '_broadcast_table_message');
  if v_txt is not null then
    raise exception 'STOP: these functions use part 1''s functions: %. Roll back the slice that added them first. Nothing was changed.', v_txt;
  end if;
end;
$$;

drop function if exists public.send_table_message(uuid, text);
drop function if exists public._broadcast_table_message(text, jsonb);

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  to_regprocedure('public.send_table_message(uuid, text)') is null as send_fn_gone,
  to_regprocedure('public._broadcast_table_message(text, jsonb)') is null as helper_fn_gone,
  (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages') as realtime_messages_policies;
