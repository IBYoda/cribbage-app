-- Step 3, slice D: PRIVATE TABLES -- ROLLBACK of docs/sql/private-tables-part2.sql.
-- Run in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: written, NOT RUN yet. Only if the swap has to come out.
--
-- STEP 1 (this transaction): puts the four OPEN SELECT policies back EXACTLY
-- as they were live before part 2 (docs/sql/private-tables-catalog.sql,
-- 2026-11-24): the same names, "to public" (no TO clause), and the same
-- USING text, (auth.role() = 'authenticated'::text):
--   tables         "Tables are viewable by any logged-in user"         (slice-3-tables.sql)
--   table_members  "Table members are viewable by any logged-in user"  (slice-4-join-table.sql)
--   games          "Games are viewable by any logged-in user"          (slice-5-new-game.sql)
--   game_plays     "Played cards are viewable by any logged-in user"   (phase2-slice-7-pegging-turns.sql)
-- and drops part 2's four policies. Every signed-in user reads every table,
-- roster, game and play again, as before slice D. No row changes. The admin
-- UPDATE policies, game_hands, game_cribs and table_spectators were never
-- touched by part 2 and are not touched here.
--
-- The part 1 helpers STAY (nothing uses them once part 2's policies are
-- gone; harmless). Dropping them is STEP 2 below: OPTIONAL, commented out,
-- and only after step 1 -- part 2's policies call them, so a drop while
-- they exist fails.
--
-- After it: docs/sql/private-tables-precheck.sql should say "before part 2"
-- on its four select rows again. The app needs no change: the slice D build
-- (the by-id preview fallback, the awaited heartbeat) works with open reads
-- too -- the fallback simply never runs.
--
-- RE-RUNNABLE: drop if exists / create, in one transaction.

-- ===========================================================================
-- STEP 1: the four open policies back.
-- ===========================================================================
begin;

drop policy if exists "Public tables, or private ones the caller may read" on public.tables;
drop policy if exists "Rosters of tables the caller may read" on public.table_members;
drop policy if exists "Games the caller may read" on public.games;
drop policy if exists "Plays of games the caller may read" on public.game_plays;

drop policy if exists "Tables are viewable by any logged-in user" on public.tables;
create policy "Tables are viewable by any logged-in user"
  on public.tables for select
  using (auth.role() = 'authenticated');

drop policy if exists "Table members are viewable by any logged-in user" on public.table_members;
create policy "Table members are viewable by any logged-in user"
  on public.table_members for select
  using (auth.role() = 'authenticated');

drop policy if exists "Games are viewable by any logged-in user" on public.games;
create policy "Games are viewable by any logged-in user"
  on public.games for select
  using (auth.role() = 'authenticated');

drop policy if exists "Played cards are viewable by any logged-in user" on public.game_plays;
create policy "Played cards are viewable by any logged-in user"
  on public.game_plays for select
  using (auth.role() = 'authenticated');

commit;

-- ===========================================================================
-- STEP 2 (OPTIONAL, commented out): drop the part 1 helpers.
-- Only after step 1 has committed. Remove the leading "-- " from the nine
-- lines below and run them on their own.
-- ===========================================================================
-- begin;
-- drop function if exists public.can_read_game(uuid);
-- drop function if exists public.can_read_table(uuid);
-- drop function if exists public.is_public_table(uuid);
-- drop function if exists public.is_game_player(uuid);
-- drop function if exists public.is_admin();
-- drop function if exists public.is_current_spectator(uuid);
-- drop function if exists public.is_table_member(uuid);
-- commit;
