-- Open hands in the count: both hands face-up for the whole count, and the
-- crib face-up from the moment its count is up
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- WHY: during the count, hands were revealed one at a time (Show Hand, then
-- Confirm Count) and cleared after each confirm, and the crib needed a Show
-- Crib tap. Players talking over a call couldn't see each other's cards. Now
-- both four-card hands stay face-up for both players through the whole count,
-- and the crib turns face-up by itself when its count is up.
--
-- WHAT THIS EXPOSES, TO WHOM, AND WHEN -- and nothing else:
--   * TO WHOM: only the players of that game -- auth.uid() in games.players.
--     Not every member of the table: a third account sitting on the roster,
--     or someone who joins later, is not in players and reads nothing new.
--   * HANDS (game_hands): every player's four kept cards, while the game is
--     LIVE (status 'active') and in phase 'counting' or 'done' -- that is,
--     once pegging is over, until next_hand deals the next hand.
--   * THE CRIB (game_cribs): its four cards, while the game is LIVE and the
--     count has reached the crib (phase 'counting' with count_step 2) or the
--     hand is 'done'. Never during the counts of the two hands.
--   * NEVER during 'cutting', 'discard' or 'play', and never on an ENDED game
--     (an ended game is the won-game policies' business, in
--     phase2-won-game-reveal.sql, and those are untouched).
--   * game_decks (the undealt cards) is NOT touched: still no policy at all,
--     so still unreadable by every client.
--
-- THE HANDS ADD NO INFORMATION. Counting starts only when the last card of
-- the hand has been played: play_card moves the phase to 'counting' in the
-- same transaction, and only once "neither holds anything, all eight cards are
-- down" (phase2-batch2a-counting.sql). So when these hands open, every one of
-- their cards has already been played face-up in pegging. game_hands.cards is
-- the four kept cards for the whole hand (play_card never removes a card from
-- it), so what opens is exactly what both players have already seen. The
-- crib, which nobody has seen, stays closed until its own count.
--
-- NO GAP AT THE NEXT HAND: next_hand deletes the finished hand's rows and
-- sets phase back to 'discard' in the same transaction that deals the new
-- hand, so these policies are closed before any new cards exist.
--
-- HOW: two NEW permissive policies. Permissive policies on the same table and
-- command are OR'ed together, so every existing policy keeps working exactly
-- as before and is not modified -- "Players read their own hand, or a hand
-- shown at their table", "Players at the table read a shown crib", and the
-- two won-game policies. show_hand, show_crib and confirm_count are not
-- redefined; revealed_by and crib_revealed keep their meaning (and
-- confirm_count still requires crib_revealed for the crib -- the client calls
-- show_crib just before it).
--
-- The subquery runs under the reader's own RLS on games, which has "Games are
-- viewable by any logged-in user" (slice-5-new-game.sql) -- so it sees the
-- game row it needs. It can only narrow access, never widen it.
--
-- NO GRANT CHANGES, because none are needed:
--   * game_hands has always been selected by the client (the player's own
--     hand since Slice 9), so authenticated already holds SELECT on it.
--   * game_cribs was given "grant select ... to authenticated" explicitly in
--     phase2-batch2a-counting.sql, section 6.
-- A policy only filters rows the role is already privileged to select; these
-- two need no privilege that isn't already there.
--
-- RE-RUNNABLE: each policy is dropped (if it exists) before it is created.
--
-- Checks: docs/sql/phase2-open-hands-in-count-verification.sql -- a
-- rolled-back walk-through proving what opens AND what stays closed.


-- ---------------------------------------------------------------------------
-- 1. Every hand, once pegging is over, readable by the game's players.
-- ---------------------------------------------------------------------------
drop policy if exists "Players read every hand once pegging is over" on public.game_hands;

create policy "Players read every hand once pegging is over"
  on public.game_hands for select
  using (
    exists (
      select 1
      from public.games g
      where g.id = game_hands.game_id
        and g.status = 'active'
        and g.phase in ('counting', 'done')
        and auth.uid() = any(g.players)
    )
  );


-- ---------------------------------------------------------------------------
-- 2. The crib, once its count is up, readable by the game's players.
-- ---------------------------------------------------------------------------
drop policy if exists "Players read the crib once it is up for counting" on public.game_cribs;

create policy "Players read the crib once it is up for counting"
  on public.game_cribs for select
  using (
    exists (
      select 1
      from public.games g
      where g.id = game_cribs.game_id
        and g.status = 'active'
        and ((g.phase = 'counting' and g.count_step = 2) or g.phase = 'done')
        and auth.uid() = any(g.players)
    )
  );
