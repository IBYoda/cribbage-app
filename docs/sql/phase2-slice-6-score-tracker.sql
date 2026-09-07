-- Phase 2, Slice 6: live score tracker (PRD Section 6, item 11)
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- Just the running number and the "why" behind the last change. No scoring
-- logic feeds it yet -- pegging and Confirm Count are later slices, and they
-- are what will call award_points() below.


-- ---------------------------------------------------------------------------
-- 1. Where the score lives, and why it is here.
--
-- table_members is already keyed exactly (table_id, user_id) -- one row per
-- player per table, which is precisely the grain a running score needs. A
-- separate scores table would duplicate that key for nothing.
--
-- It also arrives with exactly the right RLS already in place, unmodified:
--   * select using (auth.role() = 'authenticated')  -> everyone reads every
--     score, which is the entire point of a shared tracker
--   * insert with check (auth.uid() = user_id)      -> joining only
--   * NO update policy                              -> deny by default, so a
--     player CANNOT write their own score. Only award_points() can.
--
-- And it was added to the realtime publication back in Slice 4, with
-- publication-level UPDATE already enabled -- so live propagation needs no SQL
-- here at all, only a client-side UPDATE listener.
--
-- KNOWN LIMITATION, stated plainly rather than discovered later: real cribbage
-- plays to 121 across many hands, but one games row is currently one HAND and
-- there is no "match" entity (the same gap flagged in start_game_with_deal's
-- dealer-alternation comment). So this score accumulates across every hand
-- played at the table, which is the correct match score only while a table
-- hosts a single match. Consequences:
--   * There is currently NO way to reset a score. The PRD's "New Game -> score
--     reset" means a new MATCH, which does not exist yet.
--   * leave_table DELETEs the table_members row, so leaving discards your
--     score and rejoining starts at 0. Defensible, since leaving already
--     force-ends the game -- but it is a real behaviour, not an accident.
-- When a matches entity arrives, resetting becomes one UPDATE ... SET score = 0.
-- ---------------------------------------------------------------------------
alter table public.table_members
  add column score int not null default 0,
  -- The last award, kept so the tracker can show WHY a number moved --
  -- "Sam +2 — pair" rather than a number silently changing. PRD Section 8
  -- calls this out specifically. Nullable: a player who has not scored yet has
  -- no last award to describe.
  add column last_points int,
  add column last_reason text,
  add column last_awarded_at timestamptz;


-- ---------------------------------------------------------------------------
-- 2. The one way points are ever awarded.
--
-- Deliberately NOT granted to anyone -- same treatment as deal_cards_for_game.
-- This is the important part: ANY player-callable award function is a direct
-- cheat vector ("award me 121"). Leaving it ungranted means PostgREST never
-- exposes it as an endpoint at all.
--
-- Callers are:
--   * future scoring slices (auto-scored pegging, Confirm Count), which are
--     themselves security definer functions running as owner, so they can call
--     this without a grant
--   * the SQL Editor, for testing now -- it runs as the table owner
--
-- Plain rather than security definer, for the same reason deal_cards_for_game
-- is: every legitimate caller already runs as the owner, and the owner bypasses
-- RLS (no table here has FORCE ROW LEVEL SECURITY). Adding security definer
-- would grant nothing extra and would only make the function look callable.
--
-- p_points is deliberately unconstrained beyond being non-null:
--   * 0 is legitimate -- a hand worth nothing is a real cribbage outcome (the
--     "19"), and it should still update last_reason so the tracker can say so
--   * negatives are left possible for future penalty/muggins rules
-- There is deliberately no cap at 121 and no win detection. Clamping without
-- win detection would be half a rule, and worse, it would silently swallow
-- points -- exactly the kind of thing that would hide a real bug in the pegging
-- slice. Both belong to the same future slice.
-- ---------------------------------------------------------------------------
create or replace function public.award_points(
  p_table_id uuid,
  p_user_id uuid,
  p_points int,
  p_reason text
)
returns void
language plpgsql
set search_path = public
as $$
begin
  if p_points is null then
    raise exception 'award_points requires a point value (0 is allowed, null is not).';
  end if;

  update public.table_members
  set score = score + p_points,
      last_points = p_points,
      last_reason = p_reason,
      last_awarded_at = now()
  where table_id = p_table_id
    and user_id = p_user_id;

  -- Fails loudly rather than silently scoring nobody. A future scoring slice
  -- passing a stale user id is a bug worth surfacing immediately.
  if not found then
    raise exception 'No player % at table %.', p_user_id, p_table_id;
  end if;
end;
$$;

revoke all on function public.award_points(uuid, uuid, int, text) from public;


-- ---------------------------------------------------------------------------
-- TESTING. There is no scoring logic yet, so this is how points get awarded
-- until pegging and Confirm Count exist. Run from the SQL Editor, which
-- executes as the table owner -- the app itself can never call this.
--
-- Award 2 points to the FIRST player to have joined a table:
-- ---------------------------------------------------------------------------

-- select public.award_points(
--   (select id from public.tables where code = '0000'),        -- <<< table code
--   (select user_id from public.table_members
--     where table_id = (select id from public.tables where code = '0000')
--     order by joined_at limit 1),
--   2,
--   'pair'
-- );

-- ...and 3 to the second player:
-- select public.award_points(
--   (select id from public.tables where code = '0000'),
--   (select user_id from public.table_members
--     where table_id = (select id from public.tables where code = '0000')
--     order by joined_at offset 1 limit 1),
--   3,
--   'run of three'
-- );

-- Check the result:
-- select tm.user_id, p.nickname, tm.score, tm.last_points, tm.last_reason, tm.last_awarded_at
-- from public.table_members tm
-- left join public.profiles p on p.id = tm.user_id
-- where tm.table_id = (select id from public.tables where code = '0000')
-- order by tm.joined_at;

-- Confirm a PLAYER cannot write their own score (should affect 0 rows -- there
-- is no update policy on table_members). Run this from the browser console as
-- a logged-in player, not here; see the slice's testing instructions.
