-- Friends, F1: removes everything docs/sql/follows.sql added (five functions
-- and the follows table with its index and its rows; no other table or
-- function changed).
-- STATUS: NOT RUN. Kept for reference.
-- Safe with the app live as long as no deployed build calls follow_user,
-- unfollow_user or get_my_follows yet (F1 ships SQL only). It DELETES every
-- follow: once F2 is live, players would lose their lists.
-- The functions go first (follow_user calls _follow_user_as, which calls
-- _followable), then the table.

begin;
drop function if exists public.get_my_follows();
drop function if exists public.unfollow_user(uuid);
drop function if exists public.follow_user(uuid);
drop function if exists public._follow_user_as(uuid, uuid, int);
drop function if exists public._followable(uuid);
drop table if exists public.follows;
commit;
