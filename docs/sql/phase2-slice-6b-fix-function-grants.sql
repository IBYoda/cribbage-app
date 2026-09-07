-- Phase 2, Slice 6b: make internal functions genuinely unreachable
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- BUG FOUND DURING SLICE 6 TESTING. award_points() was supposed to be
-- internal-only, but a logged-in player could call it over PostgREST. It
-- failed -- its UPDATE hit table_members' missing UPDATE policy and affected
-- zero rows -- so no score was corrupted. But "safe when reached" is not
-- "unreachable", and the only thing standing between a player and the function
-- body was a second line of defence that happened to hold.
--
-- ROOT CAUSE
--   "revoke all on function ... from public" removes the grant held by the
--   PUBLIC pseudo-role. That was never the grant doing the work.
--
--   Supabase's project bootstrap runs, roughly:
--     alter default privileges in schema public
--       grant all on functions to postgres, anon, authenticated, service_role;
--
--   So every function created in schema public picks up a DIRECT execute grant
--   to anon and authenticated at creation time. Revoking from PUBLIC leaves
--   those direct grants completely untouched.
--
-- SCOPE -- three functions are affected, not one:
--   award_points            internal, reachable   (found in testing)
--   deal_cards_for_game     internal, reachable   (same bug, not yet hit)
--   end_timed_out_sessions  cron-only, reachable AND security definer, so it
--                           actually runs with owner privileges. It only ends
--                           sessions already past their timeout, so it cannot
--                           corrupt anything -- but it is an elevated endpoint
--                           exposed for no reason.
--
-- Every function that IS meant to be player-callable already has an explicit
-- "grant execute ... to authenticated", so nothing below can break them.


-- ---------------------------------------------------------------------------
-- BEFORE. Run this first to see the actual grants. Expect to see
-- 'authenticated' (and 'anon') listed as grantees for all three functions --
-- that is the bug, visible directly.
-- ---------------------------------------------------------------------------

-- select routine_name, grantee, privilege_type
-- from information_schema.routine_privileges
-- where routine_schema = 'public'
--   and routine_name in (
--     'award_points', 'deal_cards_for_game', 'end_timed_out_sessions'
--   )
-- order by routine_name, grantee;


-- ---------------------------------------------------------------------------
-- THE FIX. Revoke from the roles that actually hold the grant.
--
-- postgres (the owner) is deliberately untouched: it is how the security
-- definer functions call these internally, and how pg_cron runs the timeout
-- sweep -- the cron job's username is 'postgres', which we confirmed back in
-- Slice 8. service_role is left alone too; it is a trusted server-side key
-- this project does not currently use.
-- ---------------------------------------------------------------------------

revoke execute on function public.award_points(uuid, uuid, int, text)
  from anon, authenticated;

revoke execute on function public.deal_cards_for_game(uuid)
  from anon, authenticated;

revoke execute on function public.end_timed_out_sessions()
  from anon, authenticated;


-- ---------------------------------------------------------------------------
-- ROOT-CAUSE FIX. A deliberate project-wide behaviour change, decided when
-- this bug was found rather than assumed.
--
-- The three revokes above fix today's functions. They do nothing about the
-- next internal function written, which would pick up the same automatic grant
-- and reintroduce exactly this bug.
--
-- This flips the default for functions created in public by this role from
-- grant-by-default to deny-by-default. From here on, a function is callable by
-- players only if this project's SQL explicitly says so:
-- ---------------------------------------------------------------------------

alter default privileges in schema public
  revoke execute on functions from anon, authenticated;

-- WHAT THIS CHANGES: any function created in public from now on will NOT be
-- callable by players unless it gets an explicit
--     grant execute on function ... to authenticated;
--
-- That matches how this project already works -- every player-callable
-- function has that line -- and it makes the safer thing the default.
--
-- The failure modes are worth comparing, because it is the reason to prefer
-- this direction:
--   * Forget a REVOKE (today's behaviour): you silently ship a public
--     endpoint you did not intend. Nothing looks wrong.
--   * Forget a GRANT (after this change): the function returns "Could not
--     find the function" the first time you call it. Obvious, immediate, and
--     fixed in one line.
--
-- Existing functions keep whatever grants they already have -- default
-- privileges only apply to newly created objects. "create or replace function"
-- also preserves an existing ACL, so replacing a function later will not
-- silently drop its grant.
--
-- Deliberately NOT revoked: shuffled_deck() and card_rank_value(). Both are
-- pure and leak nothing (one is arithmetic on a string, the other returns a
-- random permutation corresponding to nothing in the database), and Slice 4
-- documented leaving them open on purpose. Left as-is rather than churned.


-- PostgREST decides what to expose from its cached schema, and it hides
-- functions the calling role cannot execute. Nudge it to reload so the change
-- takes effect immediately rather than at its next natural refresh.
notify pgrst, 'reload schema';


-- ---------------------------------------------------------------------------
-- AFTER. Re-run the BEFORE query -- 'anon' and 'authenticated' should now be
-- gone from all three functions, leaving only postgres (and service_role).
--
-- Then confirm the player-callable ones are untouched. Expect 'authenticated'
-- to still be present for every function listed here:
-- ---------------------------------------------------------------------------

-- select routine_name, grantee, privilege_type
-- from information_schema.routine_privileges
-- where routine_schema = 'public'
--   and routine_name in (
--     'start_game_with_deal', 'draw_cut_card', 'acknowledge_deal_cut',
--     'discard_to_crib', 'leave_table'
--   )
-- order by routine_name, grantee;
