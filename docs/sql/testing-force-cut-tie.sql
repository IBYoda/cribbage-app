-- TESTING HELPER -- not part of any slice's schema.
--
-- REWRITTEN for the on-demand cut. The previous version pre-wrote a whole
-- deal_cut history, which no longer matches how the cut works: cards are drawn
-- one at a time by draw_cut_card, and nothing exists before a player taps.
--
-- Ties are rare organically (~5.9%), so this rewrites the round that was JUST
-- completed into a tie, and clears the dealer that draw_cut_card set. Both
-- clients see the change over the existing realtime broadcast on games, so the
-- Redraw gate appears without a reload.
--
-- HOW TO USE
--   1. Set the table code below.
--   2. Start a game at a NEW table (an established table alternates the deal
--      and never cuts at all).
--   3. Have BOTH players tap the deck, so the round is complete. It will
--      almost certainly resolve as decisive -- that is fine.
--   4. Run this. The completed round becomes a tie and Redraw appears.
--   5. From there the flow is real again: both press Redraw, the server opens
--      a fresh round, and both tap the deck to draw genuinely random cards.
--
-- Run in the Supabase SQL Editor, which executes as the table owner and so
-- bypasses RLS -- the app itself can never do this.

update public.games g
set
  -- Overwrite the LAST round (the one in progress) with two matching ranks.
  deal_cut = jsonb_set(
    g.deal_cut,
    array[(jsonb_array_length(g.deal_cut) - 1)::text],
    jsonb_build_array(
      jsonb_build_object('user_id', g.players[1], 'card', '7H'),
      jsonb_build_object('user_id', g.players[2], 'card', '7S')
    )
  ),
  -- draw_cut_card will have set this when the round resolved as decisive.
  -- A tie means no dealer, and the client detects "tie" as exactly that:
  -- round complete, but dealer_id still null.
  dealer_id = null,
  -- Clear any acknowledgements so both players must press Redraw again.
  deal_cut_ack_by = '{}'
from public.tables t
where t.id = g.table_id
  and t.code = '0000'          -- <<< CHANGE ME to your table code
  and g.status = 'cutting'
  and g.players is not null
  and jsonb_array_length(g.deal_cut -> (jsonb_array_length(g.deal_cut) - 1)) = 2;


-- Check what happened -- expect a 2-card final round of matching ranks and a
-- null dealer:
-- select t.code,
--        g.status,
--        g.dealer_id,
--        jsonb_array_length(g.deal_cut) as rounds,
--        g.deal_cut -> (jsonb_array_length(g.deal_cut) - 1) as current_round,
--        g.deal_cut_ack_by
-- from public.games g
-- join public.tables t on t.id = g.table_id
-- where g.status = 'cutting';
