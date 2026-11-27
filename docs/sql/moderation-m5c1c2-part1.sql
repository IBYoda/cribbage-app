-- Moderation, slice M5c1 (c2): REMOVE THE OLD CHAT PERMISSIONS.
-- PART 1 (the only part). Run in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase
-- CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet.
--
-- DEPLOY ORDER (slice M5c1 c2):
--   0. The app's chat through the server (PR #141) is live: no tab of the
--      new app joins or sends on chat:<table>:<sender> any more. Old open
--      tabs stop chatting at once (accepted, Walt 2026-11-26: friends
--      refresh); their join is refused, nothing else breaks.
--   1. docs/sql/moderation-m5c1c2-precheck.sql       (read-only; no STOP
--      rows, state "before part 1")
--   2. docs/sql/moderation-m5c1c2-part1.sql          (THIS FILE)
--   3. docs/sql/moderation-m5c1c2-verification.sql   ("ALL n CHECKS PASSED")
--   4. the suites to re-run (moderation-m5c1c2-precheck.sql's header)
--   Rollback: docs/sql/moderation-m5c1c2-part1-rollback.sql (restores the
--   two policies and the function exactly).
--
-- WHAT THIS FILE DOES (one transaction):
--   0. GUARD (raises, changing nothing, unless all hold):
--        * moderation M5c1 part 1 is in (send_table_message): chat no
--          longer needs the old path;
--        * the two policies "table chat: members receive" (SELECT) and
--          "table chat: members send" (INSERT) exist on realtime.messages,
--          each calling chat_topic_allows -- as table-chat.sql wrote them;
--        * chat_topic_allows(text, boolean) is spectator-chat.sql's body
--          (LF 0458d5122d68d511b2e0fbceafe84aae or CRLF
--          c4e6eda360de7d7723c4069e60d95345), so the rollback restores it
--          exactly;
--        * nothing else uses it: no other policy, no function in public
--          that CALLS it (its body, comments removed, has
--          "chat_topic_allows(" -- a mention in a comment, as in
--          send_table_message's "chat_topic_allows' rules 4-6", is not a
--          use), no view or trigger depends on it.
--      NOT RE-RUNNABLE BY DESIGN: a second run STOPs at the guard (the
--      policies are gone).
--   1. drop policy "table chat: members receive" on realtime.messages;
--      drop policy "table chat: members send" on realtime.messages;
--   2. drop function public.chat_topic_allows(text, boolean) (RESTRICT: if
--      anything still depended on it the drop fails and nothing changes).
--
-- NOTHING ELSE used only chat_topic_allows: get_table_spectators (from the
-- same spectator-chat.sql) is the app's spectator list and STAYS; the
-- table_spectators / table_members / tables it read are everyone's.
--
-- AFTERWARDS on realtime.messages: exactly two policies, both SELECT (receive
-- only), for authenticated, broadcast only:
--   "table kicks: people at the table receive"   kick_topic_allows (M3)
--   "table events: people at the table receive"  table_topic_allows (M5a)
-- No INSERT policy at all: no client can send on any private topic; every
-- broadcast comes from the database (realtime.send). A chat:<table>:<user>
-- topic can no longer be joined (no SELECT policy matches it) or sent on.
-- Client-callable functions: 61 -> 60 (chat_topic_allows was granted to
-- authenticated).
--
-- NOT TOUCHED: every other function body (no fingerprint changes), every
-- other policy, table, trigger and grant, the publication, the tables row.

begin;

-- ---------------------------------------------------------------------------
-- 0. Guard.
-- ---------------------------------------------------------------------------
do $$
declare
  v_txt text;
  v_oid oid := to_regprocedure('public.chat_topic_allows(text, boolean)');
begin
  if to_regprocedure('public.send_table_message(uuid, text)') is null then
    raise exception 'STOP: moderation M5c1 part 1 is not in (send_table_message): chat still needs the old path. Nothing was changed.';
  end if;
  if (select count(*) from pg_policies p
      where p.schemaname = 'realtime' and p.tablename = 'messages'
        and ((p.policyname = 'table chat: members receive' and p.cmd = 'SELECT'
              and p.qual ilike '%chat_topic_allows(%realtime.topic()%false)%')
          or (p.policyname = 'table chat: members send' and p.cmd = 'INSERT'
              and p.with_check ilike '%chat_topic_allows(%realtime.topic()%true)%'))) <> 2 then
    raise exception 'STOP: the two table-chat policies are not both there as table-chat.sql wrote them (this file already ran?). Nothing was changed.';
  end if;
  if v_oid is null then
    raise exception 'STOP: public.chat_topic_allows(text, boolean) is missing. Nothing was changed.';
  end if;
  select md5(p.prosrc) into v_txt from pg_proc p where p.oid = v_oid;
  if v_txt not in ('0458d5122d68d511b2e0fbceafe84aae', 'c4e6eda360de7d7723c4069e60d95345') then
    raise exception 'STOP: chat_topic_allows has body md5 %, not spectator-chat.sql''s; the rollback could not restore it exactly. Capture it first: select pg_get_functiondef(''public.chat_topic_allows(text, boolean)''::regprocedure); Nothing was changed.', v_txt;
  end if;
  select string_agg(p.policyname::text, ', ') into v_txt
  from pg_policies p
  where (coalesce(p.qual, '') ilike '%chat_topic_allows%' or coalesce(p.with_check, '') ilike '%chat_topic_allows%')
    and not (p.schemaname = 'realtime' and p.tablename = 'messages'
             and p.policyname in ('table chat: members receive', 'table chat: members send'));
  if v_txt is not null then
    raise exception 'STOP: other policies call chat_topic_allows: %. Nothing was changed.', v_txt;
  end if;
  select string_agg(p.oid::regprocedure::text, ', ') into v_txt
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.oid <> v_oid
    -- A real call only: comments (-- to the end of the line, /* ... */)
    -- removed, then chat_topic_allows followed by "(".
    and regexp_replace(regexp_replace(p.prosrc, '/\*.*?\*/', '', 'g'), '--[^\n]*', '', 'g') ~* '\mchat_topic_allows\s*\(';
  if v_txt is not null then
    raise exception 'STOP: these functions call chat_topic_allows: %. Nothing was changed.', v_txt;
  end if;
  select string_agg(d.classid::regclass::text || ' ' || d.objid::text, ', ') into v_txt
  from pg_depend d
  where d.refclassid = 'pg_proc'::regclass and d.refobjid = v_oid
    and d.classid <> 'pg_policy'::regclass
    and d.deptype in ('n', 'a');
  if v_txt is not null then
    raise exception 'STOP: other objects depend on chat_topic_allows (%). Nothing was changed.', v_txt;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The two policies.
-- ---------------------------------------------------------------------------
drop policy "table chat: members receive" on realtime.messages;
drop policy "table chat: members send" on realtime.messages;

-- ---------------------------------------------------------------------------
-- 2. The function (RESTRICT: fails, changing nothing, if anything still
-- depends on it).
-- ---------------------------------------------------------------------------
drop function public.chat_topic_allows(text, boolean) restrict;

commit;

-- After the commit, read-only: what the dashboard shows as this file's result.
select
  (select count(*) from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages') as realtime_messages_policies,
  (select string_agg(pol.policyname::text || ' (' || pol.cmd || ')', ', ' order by pol.policyname)
   from pg_policies pol where pol.schemaname = 'realtime' and pol.tablename = 'messages') as remaining,
  to_regprocedure('public.chat_topic_allows(text, boolean)') is null as chat_topic_allows_gone;
