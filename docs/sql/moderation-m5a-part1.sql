-- Moderation, slice M5 (a): TABLE AND SPECTATOR EVENTS on one server-pushed
-- topic per table. PART 1 (the only part): ADD-ONLY (safe before any app
-- change). Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M5a):
--   1. docs/sql/moderation-m5a-precheck.sql      (read-only; no STOP rows,
--      state "before part 1")
--   2. docs/sql/moderation-m5a-part1.sql         (THIS FILE)
--   3. docs/sql/moderation-m5a-verification.sql  ("ALL n CHECKS PASSED")
--   4. the re-baselined suites (moderation-m5a-precheck.sql's header lists
--      them: policy counts and the client function count, 59 -> 60)
--   5. the app (a later step): listen on table:<id>, keep the old
--      listeners and the safety poll for now
--   Rollback: docs/sql/moderation-m5a-part1-rollback.sql.
--
-- WHAT WALT DECIDED (M5, 2026-11-26): ONE private Broadcast topic per
-- table, table:<uuid>, that only the SERVER sends on (database triggers
-- through realtime.send). Payloads carry ids and a version only -- never a
-- hand, crib or deck. Slice (a) covers the table and its people (seats and
-- spectators); (b) plays and game state; (c) chat through an RPC. The old
-- postgres_changes listeners keep working: nothing leaves the
-- supabase_realtime publication in this slice.
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold): M3 and M6 are in
--      (kick_topic_allows, player_reports); realtime.messages exists with RLS
--      on and realtime.send(jsonb, text, text, boolean) exists; the policies
--      on realtime.messages are exactly the two table-chat ones and M3's
--      kicks policy; is_table_member and is_current_spectator are
--      private-tables-part1.sql's bodies (LF or CRLF); tables has no
--      roster_version column yet; none of this file's five function names,
--      three trigger names or policy name exists. NOT RE-RUNNABLE BY DESIGN:
--      a second run STOPs at the guard. A failed run changes nothing.
--   1. public.tables.roster_version bigint not null default 0 (a metadata
--      change: no table rewrite). Bumped by +1 by the triggers below every
--      time the table's PEOPLE change; a client keeps the highest it has
--      seen and drops an event at or below it. No client may write it
--      (tables' UPDATE policy is admins-only; INSERT is limited to six
--      columns).
--   2. Functions, all SECURITY DEFINER with search_path '':
--        _send_table_event(p_table_id uuid, p_event text,
--                          p_roster_version bigint) void
--          INTERNAL: realtime.send({event, table_id, roster_version},
--          p_event, 'table:<table_id>', true), inside its own BEGIN ...
--          EXCEPTION WHEN OTHERS THEN NULL block.
--        _table_event_on_members() trigger                    INTERNAL
--          A seat taken (INSERT), left or kicked (DELETE), or moved (UPDATE
--          of seat to another value): bump roster_version, send 'members'.
--          Score changes are NOT table events (slice b).
--        _table_event_on_spectators() trigger                 INTERNAL
--          A watcher added (INSERT) or deleted (DELETE), removed or
--          un-removed (removed_at changes), or back after going stale (an
--          UPDATE that moves last_seen_at from older than 90 seconds to
--          within them): bump, send 'spectators'. An ordinary heartbeat
--          (current -> current) sends NOTHING.
--        _table_event_on_tables() trigger                     INTERNAL
--          Any change to the table row other than roster_version alone
--          (status, ended_reason, ...): send 'table' with the current
--          roster_version (no bump). The triggers' own bumps send nothing
--          here.
--        table_topic_allows(p_topic text) boolean             authenticated
--          May the signed-in person RECEIVE on table:<uuid>? Seated at that
--          table (is_table_member) or a current spectator of it
--          (is_current_spectator). Used only by the policy below.
--   3. Three AFTER ... FOR EACH ROW triggers, named to sort LAST among each
--      table's AFTER triggers (so table_members_end_when_empty runs first):
--        table_members_zz_table_event      AFTER INSERT OR DELETE OR UPDATE OF seat
--        table_spectators_zz_table_event   AFTER INSERT OR DELETE OR UPDATE OF removed_at, last_seen_at
--        tables_zz_table_event             AFTER UPDATE
--      Each trigger function does its bump and its send inside its own
--      BEGIN ... EXCEPTION WHEN OTHERS THEN NULL block: a failed bump or
--      send never blocks a join, leave, seat move, watch, heartbeat, kick
--      or table end. (A failed bump also sends nothing for that change; the
--      app's safety poll still repairs it.) The BEFORE INSERT triggers
--      (table_members_assign_seat, table_members_require_open) are not
--      touched and keep their order.
--   4. ONE policy on realtime.messages, "table events: people at the table
--      receive" (SELECT, to authenticated, broadcast,
--      table_topic_allows(realtime.topic())). There is NO insert policy for
--      table: topics: no client can send there (the chat send policy refuses
--      any topic that is not chat:...); only the triggers do.
--
-- WHY NOT can_read_table IN THE POLICY: it is true for ANY signed-in person
-- at a public table (and for anyone who ever played there), so anybody could
-- follow any public table's roster changes. The topic is for the people AT
-- the table: seated, or watching now.
--
-- LOCKS: the members and spectators triggers UPDATE the tables row. Every
-- path that writes table_members already holds that row's lock by then (the
-- seat trigger, set_seat, leave_table via the end-when-empty trigger,
-- kick_player), and watch_table locks it before writing table_spectators,
-- so no new lock order appears there. The one new order is a stale
-- spectator's HEARTBEAT that revives them (spectator row, then tables row);
-- see the precheck's notes.
--
-- md5 of the new bodies (carriage returns removed; LF), and with CRLF line
-- ends (this file as committed):
--   _send_table_event             df40bb9eac9b778a8d733d2d18393865 / 95a2e389640bc9ca432b33d8775a7e9b
--   _table_event_on_members       26f95e1c2dd4cb5cffbb8e784367cd92 / e3fae79d9935cffd3b3bde4879f6572d
--   _table_event_on_spectators    f81c329f92115ea11038cff9f0ffc184 / 25eaaed82c3708b79f29716da77917d9
--   _table_event_on_tables        d950c48b22205b15e62e38411923fef5 / 85b82edabdb2fb540ba58123388170ec
--   table_topic_allows            57908d750db883e7687b926cbea3ab4a / 472ddcd97480da6c52eeea7141bd668c
--
-- NOT TOUCHED: every existing function body (this slice replaces NO
-- function), every existing trigger, policy and grant, the
-- supabase_realtime publication.
--
-- ROLLBACK: docs/sql/moderation-m5a-part1-rollback.sql.

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard.
-- ---------------------------------------------------------------------------
do $$
declare
  v_rec record;
  v_txt text;
  v_n integer;
begin
  -- M3 and M6 are in.
  if to_regprocedure('public.kick_topic_allows(text)') is null
     or to_regclass('public.player_reports') is null then
    raise exception 'STOP: moderation M3 (kick_topic_allows) or M6 (player_reports) is not in. Nothing was changed.';
  end if;

  -- Realtime: the table with RLS on, and realtime.send.
  if to_regclass('realtime.messages') is null
     or not (select c.relrowsecurity from pg_class c where c.oid = to_regclass('realtime.messages')) then
    raise exception 'STOP: realtime.messages is missing or its row-level security is off. Nothing was changed.';
  end if;
  if to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null then
    raise exception 'STOP: realtime.send(jsonb, text, text, boolean) does not exist. Nothing was changed.';
  end if;

  -- The policies on realtime.messages: exactly the two table-chat ones and
  -- M3's kicks policy (ours already there means this file ran).
  select string_agg(p.policyname::text, ', ' order by p.policyname) into v_txt
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages'
    and p.policyname not in ('table chat: members receive', 'table chat: members send', 'table kicks: people at the table receive');
  if v_txt is not null then
    raise exception 'STOP: other policies on realtime.messages: % (this file already ran, or something else is there; policies are OR''ed). Nothing was changed.', v_txt;
  end if;
  select count(*) into v_n
  from pg_policies p
  where p.schemaname = 'realtime' and p.tablename = 'messages';
  if v_n <> 3 then
    raise exception 'STOP: % policies on realtime.messages; expected exactly the two table-chat ones and the kicks policy. Nothing was changed.', v_n;
  end if;

  -- The two helpers the receive rule calls: private-tables-part1.sql's.
  for v_rec in
    select * from (values
      ('public.is_table_member(uuid)', '29383c3018543a5e7faa045a1beee164', 'ef5eb3d1d03b3bee36d51ac7e4880191'),
      ('public.is_current_spectator(uuid)', '0d6170b3543a18cb6bc71288e0f5edf6', '59ace7c42e8a998aa0a79a1dfa26e970')
    ) as t(fn, lf, crlf)
  loop
    select md5(p.prosrc) into v_txt from pg_proc p where p.oid = to_regprocedure(v_rec.fn);
    if v_txt is null or v_txt not in (v_rec.lf, v_rec.crlf) then
      raise exception 'STOP: % has body md5 %; expected % (LF) or % (CRLF). Capture it first: select pg_get_functiondef(''%''::regprocedure); Nothing was changed.', v_rec.fn, coalesce(v_txt, 'missing'), v_rec.lf, v_rec.crlf, v_rec.fn;
    end if;
  end loop;

  -- Not run before: no roster_version, none of the names.
  if exists (select 1 from pg_attribute a where a.attrelid = 'public.tables'::regclass and a.attname = 'roster_version' and not a.attisdropped) then
    raise exception 'STOP: public.tables.roster_version already exists (this file already ran?). Nothing was changed.';
  end if;
  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname) into v_txt
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public'
    and p.proname in ('_send_table_event', '_table_event_on_members', '_table_event_on_spectators', '_table_event_on_tables', 'table_topic_allows');
  if v_txt is not null then
    raise exception 'STOP: these functions already exist: %. Nothing was changed.', v_txt;
  end if;
  select string_agg(tg.tgname::text, ', ' order by tg.tgname) into v_txt
  from pg_trigger tg
  where not tg.tgisinternal
    and tg.tgname in ('table_members_zz_table_event', 'table_spectators_zz_table_event', 'tables_zz_table_event');
  if v_txt is not null then
    raise exception 'STOP: these triggers already exist: %. Nothing was changed.', v_txt;
  end if;

  -- "Sorted last": no existing AFTER trigger on the three tables sorts after
  -- the names this file adds.
  select string_agg(tg.tgrelid::regclass::text || '.' || tg.tgname::text, ', ') into v_txt
  from pg_trigger tg
  where not tg.tgisinternal
    and (tg.tgtype & 2) = 0
    and ((tg.tgrelid = 'public.table_members'::regclass and tg.tgname::text > 'table_members_zz_table_event')
         or (tg.tgrelid = 'public.table_spectators'::regclass and tg.tgname::text > 'table_spectators_zz_table_event')
         or (tg.tgrelid = 'public.tables'::regclass and tg.tgname::text > 'tables_zz_table_event'));
  if v_txt is not null then
    raise exception 'STOP: AFTER triggers that would sort after this file''s: %. Nothing was changed.', v_txt;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. tables.roster_version.
-- ---------------------------------------------------------------------------
alter table public.tables add column roster_version bigint not null default 0;

comment on column public.tables.roster_version is
  'Moderation M5a: +1 every time this table''s people change (a seat taken, left, kicked or moved; a spectator added, removed, deleted or back after going stale), by the *_zz_table_event triggers. Sent in every table:<id> event; a client keeps the highest it has seen and drops older events. Written only by those triggers (and the SQL Editor). See docs/sql/moderation-m5a-part1.sql.';

-- ---------------------------------------------------------------------------
-- 2. The functions.
-- ---------------------------------------------------------------------------
create or replace function public._send_table_event(p_table_id uuid, p_event text, p_roster_version bigint)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  -- A private Realtime broadcast on the table's topic (a uuid's text form
  -- is lowercase). Ids and the version ONLY: never a card, hand, crib or
  -- deck. Delivered only if the transaction commits. Who may receive it:
  -- table_topic_allows (the policy). Its own subtransaction: a failed send
  -- is dropped, never raised.
  begin
    perform realtime.send(
      pg_catalog.jsonb_build_object('event', p_event, 'table_id', p_table_id, 'roster_version', p_roster_version),
      p_event,
      'table:' || p_table_id::text,
      true);
  exception when others then
    null;
  end;
end;
$$;

comment on function public._send_table_event(uuid, text, bigint) is
  'Internal (moderation M5a): realtime.send({event, table_id, roster_version}, event, ''table:<table_id>'', true) inside its own exception block (a failed send is dropped). Ids and the version only. Called by the *_zz_table_event trigger functions. No client role can execute it. See docs/sql/moderation-m5a-part1.sql.';

revoke all on function public._send_table_event(uuid, text, bigint) from public;
revoke all on function public._send_table_event(uuid, text, bigint) from anon;
revoke all on function public._send_table_event(uuid, text, bigint) from authenticated;
revoke all on function public._send_table_event(uuid, text, bigint) from service_role;


create or replace function public._table_event_on_members()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_table_id uuid;
  v_version bigint;
begin
  -- A seat taken, left or kicked, or moved to another seat. Score and
  -- award updates are not table events (slice b): skipped.
  if tg_op = 'UPDATE' and new.seat is not distinct from old.seat then
    return null;
  end if;
  if tg_op = 'DELETE' then
    v_table_id := old.table_id;
  else
    v_table_id := new.table_id;
  end if;

  -- The bump and the send in one subtransaction: if either fails, neither
  -- happens, and the join / leave / kick goes on.
  begin
    update public.tables t
    set roster_version = t.roster_version + 1
    where t.id = v_table_id
    returning t.roster_version into v_version;
    if found then
      perform public._send_table_event(v_table_id, 'members', v_version);
    end if;
  exception when others then
    null;
  end;
  return null;
end;
$$;

comment on function public._table_event_on_members() is
  'Internal (moderation M5a): the table_members_zz_table_event trigger. A seat taken (INSERT), left or kicked (DELETE) or moved (UPDATE of seat to another value): roster_version + 1, then a ''members'' event on table:<table_id>. Inside its own exception block: never blocks the change. No client role can execute it. See docs/sql/moderation-m5a-part1.sql.';

revoke all on function public._table_event_on_members() from public;
revoke all on function public._table_event_on_members() from anon;
revoke all on function public._table_event_on_members() from authenticated;
revoke all on function public._table_event_on_members() from service_role;


create or replace function public._table_event_on_spectators()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_table_id uuid;
  v_version bigint;
begin
  -- An ordinary heartbeat (current -> current, still not removed) is not an
  -- event. Removed or un-removed, or back after going stale (90 seconds,
  -- is_current_spectator's rule), is.
  if tg_op = 'UPDATE'
     and new.removed_at is not distinct from old.removed_at
     and not (old.last_seen_at <= now() - interval '90 seconds'
              and new.last_seen_at > now() - interval '90 seconds') then
    return null;
  end if;
  if tg_op = 'DELETE' then
    v_table_id := old.table_id;
  else
    v_table_id := new.table_id;
  end if;

  begin
    update public.tables t
    set roster_version = t.roster_version + 1
    where t.id = v_table_id
    returning t.roster_version into v_version;
    if found then
      perform public._send_table_event(v_table_id, 'spectators', v_version);
    end if;
  exception when others then
    null;
  end;
  return null;
end;
$$;

comment on function public._table_event_on_spectators() is
  'Internal (moderation M5a): the table_spectators_zz_table_event trigger. A watcher added or deleted, removed or un-removed, or back after going stale (last_seen_at from older than 90 seconds to within them): roster_version + 1, then a ''spectators'' event on table:<table_id>. An ordinary heartbeat sends nothing. Inside its own exception block: never blocks the change. No client role can execute it. See docs/sql/moderation-m5a-part1.sql.';

revoke all on function public._table_event_on_spectators() from public;
revoke all on function public._table_event_on_spectators() from anon;
revoke all on function public._table_event_on_spectators() from authenticated;
revoke all on function public._table_event_on_spectators() from service_role;


create or replace function public._table_event_on_tables()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  -- The triggers' own roster bumps (only roster_version changed), and an
  -- update that changes nothing, are not table events.
  if (pg_catalog.to_jsonb(new) - 'roster_version') is not distinct from (pg_catalog.to_jsonb(old) - 'roster_version') then
    return null;
  end if;

  begin
    perform public._send_table_event(new.id, 'table', new.roster_version);
  exception when others then
    null;
  end;
  return null;
end;
$$;

comment on function public._table_event_on_tables() is
  'Internal (moderation M5a): the tables_zz_table_event trigger. Any change to the table row other than roster_version alone (status, ended_reason, ...): a ''table'' event on table:<id> with the current roster_version (no bump). Inside its own exception block. No client role can execute it. See docs/sql/moderation-m5a-part1.sql.';

revoke all on function public._table_event_on_tables() from public;
revoke all on function public._table_event_on_tables() from anon;
revoke all on function public._table_event_on_tables() from authenticated;
revoke all on function public._table_event_on_tables() from service_role;


create or replace function public.table_topic_allows(p_topic text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_table_id uuid;
begin
  -- The exact shape, lowercase only: "table:" (6 characters) and a uuid
  -- (36): 42 characters in all.
  if p_topic is null
     or p_topic !~ '^table:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;

  if auth.uid() is null then
    return false;
  end if;

  v_table_id := substr(p_topic, 7, 36)::uuid;

  -- Seated there, or watching it now (not removed, seen in the last 90
  -- seconds). The helpers read auth.uid() themselves.
  return public.is_table_member(v_table_id) or public.is_current_spectator(v_table_id);
end;
$$;

comment on function public.table_topic_allows(text) is
  'Moderation M5a: may the signed-in person RECEIVE on the Realtime broadcast topic table:<table_id>? Seated at that table (is_table_member) or a current spectator of it (is_current_spectator). Used only by the "table events: people at the table receive" policy on realtime.messages. Nobody may send on it (no insert policy); only the *_zz_table_event triggers do, through realtime.send. See docs/sql/moderation-m5a-part1.sql.';

-- The policy runs as authenticated, so authenticated executes it (as with
-- chat_topic_allows and kick_topic_allows); nobody else.
revoke all on function public.table_topic_allows(text) from public;
revoke all on function public.table_topic_allows(text) from anon;
revoke all on function public.table_topic_allows(text) from service_role;
revoke all on function public.table_topic_allows(text) from authenticated;
grant execute on function public.table_topic_allows(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. The triggers (AFTER, FOR EACH ROW, named to sort last).
-- ---------------------------------------------------------------------------
create trigger table_members_zz_table_event
  after insert or delete or update of seat on public.table_members
  for each row
  execute function public._table_event_on_members();

create trigger table_spectators_zz_table_event
  after insert or delete or update of removed_at, last_seen_at on public.table_spectators
  for each row
  execute function public._table_event_on_spectators();

create trigger tables_zz_table_event
  after update on public.tables
  for each row
  execute function public._table_event_on_tables();

-- ---------------------------------------------------------------------------
-- 4. The policy on realtime.messages: people at the table RECEIVE. No insert
--    policy: nobody but the triggers sends on table:.
-- ---------------------------------------------------------------------------
create policy "table events: people at the table receive"
  on realtime.messages
  for select
  to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and (select public.table_topic_allows((select realtime.topic())))
  );

-- PostgREST: reload the schema cache now (the new column).
notify pgrst, 'reload schema';

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  exists (select 1 from pg_attribute a where a.attrelid = 'public.tables'::regclass and a.attname = 'roster_version' and not a.attisdropped) as roster_version_column,
  (select count(*) from pg_trigger tg where not tg.tgisinternal
     and tg.tgname in ('table_members_zz_table_event', 'table_spectators_zz_table_event', 'tables_zz_table_event')) as table_event_triggers,
  has_function_privilege('authenticated', 'public.table_topic_allows(text)', 'EXECUTE') as topic_rule_for_authenticated,
  has_function_privilege('authenticated', 'public._send_table_event(uuid, text, bigint)', 'EXECUTE') as send_helper_for_authenticated,
  (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages') as realtime_messages_policies;
