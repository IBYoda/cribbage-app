-- Revoke client EXECUTE on card_rank_value and shuffled_deck
-- Run this in the Supabase Dashboard -> SQL Editor. Separate from the New
-- Game ready gate on purpose: independent, and safe to run before or after it.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- WHY: the 2a grants check found both granted to the client roles, although
-- the handoff lists them as not client-callable. Slice 6b left them open
-- deliberately (both are pure and leak nothing: one is arithmetic on a card
-- code, the other a random permutation that corresponds to nothing stored).
-- This closes them anyway, so the client can call exactly the ten game
-- functions and nothing else.
--
-- rls_auto_enable is NOT touched: this project's SQL never defines it, and it
-- appears to be Supabase's own. Query 1 shows its owner and return type so you
-- can decide separately.
--
-- WHAT DEPENDS ON THEM (checked before writing this):
--   * The app never calls either. The client makes exactly ten RPC calls --
--     the ten granted game functions. card_rank_value appears in lib/cards.ts
--     only in comments.
--   * In the database, both are called only from inside other functions:
--       card_rank_value: score_pegging, score_hand, discard_to_crib,
--                        draw_cut_card, acknowledge_deal_cut
--       shuffled_deck:   deal_cards_for_game, draw_cut_card
--     discard_to_crib, draw_cut_card and acknowledge_deal_cut are SECURITY
--     DEFINER (they run as the owner). score_pegging, score_hand and
--     deal_cards_for_game are plain functions called only from inside
--     security definer functions (play_card, confirm_count,
--     start_game_with_deal, acknowledge_deal_cut, next_hand) or from the SQL
--     Editor as the owner -- so the EXECUTE check on these two is always made
--     as the owner, never as a client. No game path changes.
--   * No column default, check constraint, view, trigger or RLS policy in the
--     repo's SQL references either function. The repo can't prove that about
--     the live database, which is what query 2 is for.
--
-- SIGNATURES: card_rank_value(text) and shuffled_deck(), as defined in
-- phase2-slice-4-cut-for-starter.sql. Query 1 shows them as the catalog has
-- them; if they differ, the REVOKE in section 3 fails loudly ("function does
-- not exist") rather than revoking the wrong thing -- stop and report.
--
-- Run 1 and 2 first (read-only), then 3, then 4.


-- ---------------------------------------------------------------------------
-- 1. READ-ONLY. The three functions as the catalog has them: exact signature,
-- return type, owner, and whether they run as their owner.
--
-- EXPECT:
--   card_rank_value(text)  returns integer   prosecdef false
--   shuffled_deck()        returns text[]    prosecdef false
--   rls_auto_enable(...)   -- its owner and return type are what to look at.
--                             A return type of event_trigger would confirm
--                             it is Supabase's automatic-RLS trigger
--                             function, not something the client should be
--                             calling at all.
-- ---------------------------------------------------------------------------

select p.oid::regprocedure                 as signature,
       pg_get_function_result(p.oid)       as returns,
       pg_get_userbyid(p.proowner)         as owner,
       p.prosecdef                         as security_definer,
       l.lanname                           as language
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
join pg_language l on l.oid = p.prolang
where n.nspname = 'public'
  and p.proname in ('card_rank_value', 'shuffled_deck', 'rls_auto_enable')
order by p.proname;


-- ---------------------------------------------------------------------------
-- 2. READ-ONLY. Does anything in the live database DEPEND on the two? Column
-- defaults, check constraints, views, triggers and RLS policies that use a
-- function in their expression are all recorded in pg_depend.
--
-- EXPECT 0 ROWS.
--
-- (Calls from inside other functions' bodies are NOT recorded there --
-- PL/pgSQL and plain-SQL bodies aren't parsed into dependencies. Those callers
-- are the ones listed in the header, all running as the owner.)
-- ---------------------------------------------------------------------------

-- select pg_describe_object(d.classid, d.objid, d.objsubid) as dependent_object,
--        d.deptype,
--        d.refobjid::regprocedure as depends_on
-- from pg_depend d
-- where d.refclassid = 'pg_proc'::regclass
--   and d.refobjid in (
--     select p.oid
--     from pg_proc p
--     join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public'
--       and p.proname in ('card_rank_value', 'shuffled_deck')
--   )
-- order by 1;


-- ---------------------------------------------------------------------------
-- 3. THE REVOKE. From PUBLIC as well as the two Supabase client roles:
-- "revoke ... from public" alone does not remove grants made directly to anon
-- and authenticated (the handoff's Slice 6b lesson).
--
-- The owner keeps EXECUTE (an owner's rights don't come from these grants),
-- which is what every caller listed above runs as.
-- ---------------------------------------------------------------------------

-- revoke execute on function public.card_rank_value(text) from public, anon, authenticated;
-- revoke execute on function public.shuffled_deck() from public, anon, authenticated;
--
-- -- PostgREST hides functions the calling role can't execute, from its cached
-- -- schema. Reload it so the change takes effect now.
-- notify pgrst, 'reload schema';


-- ---------------------------------------------------------------------------
-- 4. AFTER. Expect 0 rows: neither function is executable by anon or
-- authenticated any more.
--
-- Then re-run the grants check (phase2-new-game-ready-gate-verification.sql
-- query 1): 10 'ok' rows, and only rls_auto_enable left as
-- 'known pre-existing'.
--
-- A game smoke test is worth one hand too: the cut for deal (draw_cut_card),
-- the deal (deal_cards_for_game), a discard with the starter cut
-- (discard_to_crib), a pegging score (score_pegging) and a count
-- (score_hand) together exercise every caller.
-- ---------------------------------------------------------------------------

-- select routine_name, grantee, privilege_type
-- from information_schema.routine_privileges
-- where routine_schema = 'public'
--   and routine_name in ('card_rank_value', 'shuffled_deck')
--   and grantee in ('PUBLIC', 'anon', 'authenticated');
