-- Phase 2, Slice 3: leave a table (bug fix -- the "Leave" button was unwired UI)
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.

-- Leaving mid-game force-ends the game, so ended_reason needs a third value.
-- Slice 8 created this constraint inline via "add column ... check (...)", which
-- means Postgres auto-generated its name. Rather than guess that name, find and
-- drop whichever check constraint on games mentions ended_reason -- this works
-- regardless of what it ended up being called.
do $$
declare
  v_constraint_name text;
begin
  select con.conname
  into v_constraint_name
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  join pg_namespace nsp on nsp.oid = rel.relnamespace
  where nsp.nspname = 'public'
    and rel.relname = 'games'
    and con.contype = 'c'
    and pg_get_constraintdef(con.oid) ilike '%ended_reason%';

  if v_constraint_name is not null then
    execute format('alter table public.games drop constraint %I', v_constraint_name);
  end if;
end $$;

alter table public.games
  add constraint games_ended_reason_check
  check (ended_reason is null or ended_reason in ('admin', 'timeout', 'player_left'));

-- Why this is a function rather than a plain DELETE guarded by a new RLS policy:
--
--   1. Ending the game requires an UPDATE on public.games, and the only UPDATE
--      policy there is Slice 7's admin-only one. A regular player cannot end a
--      game through the API at all.
--   2. The two steps must be atomic. A failure between "end the game" and
--      "remove the member" would leave a live 2-player game with one player --
--      unfinishable, since the discard phase would wait forever on someone who
--      is no longer there.
--
-- Following the precedent from the deal slice (which DROPPED the direct
-- game-insert policy once a function existed), no DELETE policy is added to
-- table_members. A standalone policy would be a second, weaker path that lets a
-- player delete their membership while leaving a live game orphaned.
--
-- security definer runs this as the owner, bypassing RLS -- so, as always, the
-- guards below are the only protection.
create or replace function public.leave_table(p_table_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to leave a table.';
  end if;

  -- Guard 2 (the membership check): you can only remove yourself, and only
  -- from a table you are actually at.
  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = p_table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not a member of this table.';
  end if;

  -- End any active game. A 2-player cribbage game cannot continue with one
  -- player: there is no pause/resume or substitution concept, and the discard
  -- phase would block forever waiting on the departed player.
  --
  -- The table itself deliberately stays open, so the remaining player keeps
  -- the code and can start a fresh game when someone rejoins (the PRD's
  -- "one table hosts multiple games back-to-back" model). An abandoned empty
  -- table is already handled by Slice 8's 12-hour timeout.
  update public.games
  set status = 'ended', ended_reason = 'player_left'
  where table_id = p_table_id
    and status = 'active';

  delete from public.table_members
  where table_id = p_table_id
    and user_id = v_caller;

  -- No row lock here, deliberately -- unlike discard_to_crib, which locks the
  -- games row because two players appending to a shared discarded_by array
  -- could genuinely lose an update. Nothing here has that shape: if both
  -- players leave at the same instant, the UPDATE is naturally idempotent (the
  -- second matches zero rows because the game is already ended) and the two
  -- DELETEs touch different rows. Adding a lock would be ritual, not safety.
end;
$$;

-- Same narrowing as the other security definer functions: Postgres grants
-- EXECUTE to PUBLIC by default, which matters more than usual here.
revoke all on function public.leave_table(uuid) from public;
grant execute on function public.leave_table(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- Optional check. table_members was added to the realtime publication back in
-- Slice 4, and publication-level DELETE was confirmed enabled during Slice 4's
-- debugging -- so DELETE events should already broadcast with no change here.
--
-- One caveat worth knowing: Postgres only includes a deleted row's REPLICA
-- IDENTITY columns in the event payload, which defaults to the primary key.
-- table_members' PK is (table_id, user_id) -- exactly the two fields the client
-- listener needs (table_id for the subscription filter, user_id to know who
-- left), so the default is sufficient. If the DELETE listener turns out not to
-- fire during testing, the fix is:
--     alter table public.table_members replica identity full;
-- ---------------------------------------------------------------------------

-- select pubname, pubinsert, pubupdate, pubdelete from pg_publication
-- where pubname = 'supabase_realtime';

-- select schemaname, tablename from pg_publication_tables
-- where pubname = 'supabase_realtime' order by tablename;
