-- Moderation, slice M5 (b1): ROLLBACK of PART 1
-- (docs/sql/moderation-m5b1-part1.sql). Run in the Supabase Dashboard -> SQL
-- Editor. Kept here for reference/history; this project has no Supabase
-- CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- WHEN: roll the app back first if it already listens for 'game' events (an
-- old app keeps working throughout: this slice never touched the
-- postgres_changes listeners or the publication). And only while no later
-- slice uses part 1's functions (the guard checks every function body and
-- trigger in public).
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD: no function in public other than part 1's own calls
--      _send_game_event or _game_event_at_commit, and no trigger other than
--      part 1's three uses part 1's trigger functions; else it raises and
--      changes nothing.
--   1. Drops the three triggers.
--   2. Drops _game_event_at_commit, _send_game_event and
--      _bump_game_state_version.
--   3. Drops public.games.state_version. One-way only for the version
--      numbers themselves, which mean nothing once nothing sends them.
--      Delivered events (and Realtime's stored copies, ids and versions
--      only) are not touched; Realtime drops those on its own schedule.
--
-- NOT TOUCHED: everything moderation-m5b1-part1.sql did not create.

begin;

do $$
declare
  v_txt text;
begin
  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname) into v_txt
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and (strpos(p.prosrc, '_send_game_event') > 0 or strpos(p.prosrc, '_game_event_at_commit') > 0
         or strpos(p.prosrc, '_bump_game_state_version') > 0)
    and p.proname not in ('_send_game_event', '_game_event_at_commit', '_bump_game_state_version');
  if v_txt is not null then
    raise exception 'STOP: these functions use part 1''s functions: %. Roll back the slice that added them first. Nothing was changed.', v_txt;
  end if;

  select string_agg(tg.tgrelid::regclass::text || '.' || tg.tgname::text, ', ') into v_txt
  from pg_trigger tg
  where not tg.tgisinternal
    and tg.tgfoid in (coalesce(to_regprocedure('public._game_event_at_commit()')::oid, 0::oid),
                      coalesce(to_regprocedure('public._bump_game_state_version()')::oid, 0::oid))
    and tg.tgname not in ('games_state_version', 'games_zz_game_event', 'game_plays_zz_game_event');
  if v_txt is not null then
    raise exception 'STOP: other triggers use part 1''s trigger functions: %. Nothing was changed.', v_txt;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The triggers.
-- ---------------------------------------------------------------------------
drop trigger if exists games_zz_game_event on public.games;
drop trigger if exists game_plays_zz_game_event on public.game_plays;
drop trigger if exists games_state_version on public.games;

-- ---------------------------------------------------------------------------
-- 2. The functions.
-- ---------------------------------------------------------------------------
drop function if exists public._game_event_at_commit();
drop function if exists public._send_game_event(uuid, jsonb);
drop function if exists public._bump_game_state_version();

-- ---------------------------------------------------------------------------
-- 3. The column.
-- ---------------------------------------------------------------------------
alter table public.games drop column if exists state_version;

notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  not exists (select 1 from pg_attribute a where a.attrelid = 'public.games'::regclass and a.attname = 'state_version' and not a.attisdropped) as state_version_gone,
  (select count(*) from pg_trigger tg where not tg.tgisinternal
     and tg.tgname in ('games_state_version', 'games_zz_game_event', 'game_plays_zz_game_event')) as game_event_triggers_left,
  to_regprocedure('public._game_event_at_commit()') is null as commit_trigger_fn_gone;
