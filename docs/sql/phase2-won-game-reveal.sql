-- Won-game reveal: the players of a won match may read its hands and its crib
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- WHY: the final board. When a match is won, the table stays laid out as it
-- ended -- both hands face-up, the crib face-up, the starter, the last run.
-- Under the current read policies (phase2-batch2a-counting.sql, sections 5
-- and 6) a player can read the opponent's hand only once it has been shown
-- (revealed_by), and the crib only once crib_revealed is true. Most wins
-- happen before either: during pegging, on the last card, on his heels, or
-- mid-count before the other hand or the crib is shown.
--
-- WHAT THIS EXPOSES, TO WHOM, AND WHEN -- and nothing else:
--   * WHAT: the game_hands rows (each player's four kept cards) and the
--     game_cribs row (the four crib cards) of ONE game.
--   * TO WHOM: only the players of that game -- auth.uid() in games.players.
--     Not every member of the table: someone who joins the table after the
--     match, or a third account sitting on the roster, is not in players and
--     reads nothing new.
--   * WHEN: only after that game has ENDED with ended_reason 'won'. A live
--     game ('cutting' or 'active') is untouched: its hands and crib stay
--     exactly as private as before. A game ended by a player leaving, an
--     admin, or the timeout is also untouched -- it can end mid-deal (six-card
--     hands, no crib), and nothing needs to show it.
--   * game_decks (the undealt cards) is NOT touched: still no policy at all,
--     so still unreadable by every client.
--
-- HOW: two NEW permissive policies. Permissive policies on the same table and
-- command are OR'ed together, so the existing ones -- "Players read their own
-- hand, or a hand shown at their table" and "Players at the table read a
-- shown crib" -- keep working exactly as before and are not modified. These
-- only ADD rows that become readable.
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
-- Checks: docs/sql/phase2-won-game-reveal-verification.sql -- a rolled-back
-- walk-through proving the new reads AND that nothing else opened up.


-- ---------------------------------------------------------------------------
-- 1. Hands of a won game, readable by that game's players.
-- ---------------------------------------------------------------------------
drop policy if exists "Players of a won game read its hands" on public.game_hands;

create policy "Players of a won game read its hands"
  on public.game_hands for select
  using (
    exists (
      select 1
      from public.games g
      where g.id = game_hands.game_id
        and g.status = 'ended'
        and g.ended_reason = 'won'
        and auth.uid() = any(g.players)
    )
  );


-- ---------------------------------------------------------------------------
-- 2. The crib of a won game, readable by that game's players.
-- ---------------------------------------------------------------------------
drop policy if exists "Players of a won game read its crib" on public.game_cribs;

create policy "Players of a won game read its crib"
  on public.game_cribs for select
  using (
    exists (
      select 1
      from public.games g
      where g.id = game_cribs.game_id
        and g.status = 'ended'
        and g.ended_reason = 'won'
        and auth.uid() = any(g.players)
    )
  );
