-- Computer opponent, C2 ROLLBACK
-- Run this in the Supabase Dashboard -> SQL Editor to undo
-- computer-c2-engine.sql. Kept here for reference/history.
--
-- WHAT IT DOES: drops everything C2 added, and nothing else --
--   * the eleven public functions (eight computer_* wrappers,
--     computer_hand, create_computer_table, leave_computer_table);
--   * the two guard helpers (_computer_for_table, _computer_for_game);
--   * the table public.computer_accounts (its rows go with it);
--   * the column public.tables.computer_level and its check constraint.
-- Every drop is IF EXISTS, so it is safe on a database where C2 was only
-- partly applied, or not at all. C1's "_as" functions stay: undo C1 with
-- computer-c1-rollback.sql AFTER this file, if wanted.
--
-- BEFORE RUNNING, decide what happens to computer tables still open: this
-- file leaves every table, seat and game as it is. Once computer_level and
-- computer_accounts are gone, an open computer table looks like any other
-- 2-player table with the computer account seated in it, and nothing can
-- act for that account. To close them first, run (as the owner):
--   update public.games set status = 'ended', ended_reason = 'player_left'
--   where status in ('cutting', 'active')
--     and table_id in (select id from public.tables
--                      where computer_level is not null and status = 'open');
--   delete from public.table_members
--   where table_id in (select id from public.tables
--                      where computer_level is not null and status = 'open');
--   update public.tables set status = 'ended'
--   where computer_level is not null and status = 'open';
--
-- One transaction: if any statement fails, nothing is applied.

begin;

drop function if exists public.computer_start_game_with_deal(uuid);
drop function if exists public.computer_draw_cut_card(uuid);
drop function if exists public.computer_acknowledge_deal_cut(uuid);
drop function if exists public.computer_discard_to_crib(uuid, text[]);
drop function if exists public.computer_play_card(uuid, text);
drop function if exists public.computer_show_crib(uuid);
drop function if exists public.computer_confirm_count(uuid, int);
drop function if exists public.computer_next_hand(uuid, int);
drop function if exists public.computer_hand(uuid);
drop function if exists public.create_computer_table(text, text);
drop function if exists public.leave_computer_table(uuid);

drop function if exists public._computer_for_game(uuid);
drop function if exists public._computer_for_table(uuid);

drop table if exists public.computer_accounts;

alter table public.tables drop constraint if exists tables_computer_level_check;
alter table public.tables drop column if exists computer_level;

commit;
