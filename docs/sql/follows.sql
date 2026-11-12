-- Friends, F1: who each player follows (one-way, private, up to 50).
-- Run this in the Supabase Dashboard -> SQL Editor. Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- STATUS: RUN in production on 2026-11-11; its verification
-- (follows-verification.sql) passed the same day: 20 checks, W6 skipped (the
-- project has no nameless account).
--
-- RUN ORDER:
--   1. docs/sql/follows-precheck.sql      (read-only)
--   2. docs/sql/follows.sql               (this file)
--   3. docs/sql/follows-verification.sql  (writes test rows, then rolls them
--                                          all back; its final message is
--                                          the verdict)
-- Needs, already live: slice-2-profiles.sql (profiles),
-- computer-c2-engine.sql / computer-normie.sql (computer_accounts) and
-- leaderboard-l3-hidden-accounts.sql (leaderboard_hidden).
--
-- WHAT IT ADDS (and follows-rollback.sql removes exactly this):
--   1. TABLE public.follows (follower_id, followed_id, created_at), one row
--      per follow; primary key on the pair; no self-follow; an index on
--      followed_id for the delete cascade.
--   2. Five functions: _followable and _follow_user_as (internal, no client
--      grant), follow_user, unfollow_user and get_my_follows (signed-in
--      players only).
--
-- THE RULES (Walt's decisions, PRD item 36)
--   * One-way, no approval: anyone may follow anyone followable. Nobody is
--     told, and nobody can see who follows them.
--   * PRIVATE: a player can read only their own follow list
--     (get_my_follows). No function returns anyone else's list, and none
--     returns who follows a player.
--   * FOLLOWABLE: an account with a profile and a non-blank nickname that is
--     not a computer account and not hidden (leaderboard_hidden), and not
--     yourself. Every other target gets the same answer, 'not_allowed', so
--     the answer can't be used to tell a hidden account from a missing one.
--   * THE CAP: 50 follows, enforced here, on the server. Follows of hidden
--     accounts don't count (they are never on the leaderboard, so there
--     would be no star to unfollow them with). Un-hiding an account can put a
--     player at 51; the cap only applies when following someone new.
--   * IDEMPOTENT: following twice is 'following' both times (one row);
--     unfollowing someone you don't follow is quietly 'not_following'.
--   * A followed account that is DELETED loses its follows (on delete
--     cascade). One that is HIDDEN keeps its rows, but they drop out of
--     get_my_follows and the cap until it is shown again.
--
-- WRITES THROUGH THE FUNCTIONS ONLY. The table has row-level security ON
-- with NO policies and no privileges for any client role, like game_results
-- and leaderboard_hidden. So a client can't read, insert, update or delete a
-- row directly: a check constraint can't count rows for the cap, and only a
-- function can take the per-player lock that stops two quick taps both
-- passing it.
--
-- GRANTS: the AGENTS.md "New tables" rule applies (a new table in public),
-- and it is satisfied by explicit revokes from PUBLIC, anon and
-- authenticated and NO grants -- least privilege: the app never touches the
-- table directly. Since Oct 30, 2026 Supabase no longer grants new public
-- tables to the client roles by itself, but a project's own default
-- privileges can still do so (follows-precheck.sql shows them); the revokes
-- make the result the same either way. Functions: EXECUTE for authenticated
-- on follow_user, unfollow_user and get_my_follows only; nothing for anon or
-- PUBLIC; the two internals for nobody (service_role included).
--
-- REALTIME: not added to the supabase_realtime publication (the precheck
-- confirms the publication doesn't take every table automatically).
--
-- NO ENGINE FUNCTION CHANGES (none of the eight _as game functions, nor any
-- computer_* function), so the md5 fingerprints in
-- computer-c1-verification.sql are unaffected.
--
-- RE-RUNNABLE: "create table / index if not exists", idempotent revokes,
-- "create or replace function" with the same signatures, idempotent grants.
--
-- One transaction: if any statement fails, nothing is applied.

begin;

-- ===========================================================================
-- 1. public.follows
-- ===========================================================================
create table if not exists public.follows (
  follower_id uuid not null references auth.users (id) on delete cascade,
  followed_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, followed_id),
  constraint follows_not_self check (follower_id <> followed_id)
);

-- The primary key serves "my follows" (follower_id first). This one serves
-- the cascade when a FOLLOWED account is deleted.
create index if not exists follows_followed_id_idx on public.follows (followed_id);

comment on table public.follows is
  'Who each player follows: one-way, private, up to 50 (hidden accounts not counted). Written and read only through follow_user, unfollow_user and get_my_follows (security definer). RLS is on with no policies, and no client role has any privilege on it.';

-- Row-level security on, with NO policies: deny by default.
alter table public.follows enable row level security;

-- Grants, explicit (AGENTS.md "New tables", template appearance-settings.sql):
-- nothing for PUBLIC, anon or authenticated. Revoking everything also removes
-- any privilege the project's default privileges gave the table when it was
-- created.
revoke all on table public.follows from public;
revoke all on table public.follows from anon;
revoke all on table public.follows from authenticated;

-- No policies: deliberately none. No Realtime: deliberately not added to the
-- supabase_realtime publication.


-- ===========================================================================
-- 2. _followable(): may this account be followed? INTERNAL.
-- ===========================================================================
create or replace function public._followable(p_user uuid)
returns boolean
language sql
stable
set search_path = public
as $$
  select exists (
           select 1 from public.profiles p
           where p.id = p_user and btrim(coalesce(p.nickname, '')) <> ''
         )
     and not exists (select 1 from public.computer_accounts ca where ca.user_id = p_user)
     and not exists (select 1 from public.leaderboard_hidden h where h.user_id = p_user);
$$;

comment on function public._followable(uuid) is
  'Internal: true for an account with a non-blank nickname that is neither a computer account nor hidden. Called only by _follow_user_as; no client role can execute it.';


-- ===========================================================================
-- 3. _follow_user_as(): the rules, for a given actor and cap. INTERNAL.
-- ===========================================================================
-- The actor and the cap are parameters (the repo's _as pattern) so the
-- verification can test a cap of 2 on real accounts without a login.
-- follow_user passes auth.uid() and 50. Returns an outcome, never an error
-- for an expected case:
--   'following'    now following (or already was: one row either way)
--   'limit'        at the cap; nothing written
--   'not_allowed'  self, missing, nameless, computer or hidden (one answer
--                  for all)
-- Raises only when there is no actor (nobody logged in).
create or replace function public._follow_user_as(p_actor uuid, p_target uuid, p_limit int)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  if p_actor is null then
    raise exception 'You must be logged in to follow a player.';
  end if;

  if p_target is null or p_target = p_actor or not public._followable(p_target) then
    return 'not_allowed';
  end if;

  -- One follower at a time (until this transaction ends), so two quick taps
  -- can't both see 49 and both insert.
  perform pg_advisory_xact_lock(hashtextextended('follows:' || p_actor::text, 0));

  if exists (
    select 1 from public.follows f
    where f.follower_id = p_actor and f.followed_id = p_target
  ) then
    return 'following';
  end if;

  -- The cap counts follows of accounts that aren't hidden.
  select count(*) into v_count
  from public.follows f
  where f.follower_id = p_actor
    and not exists (select 1 from public.leaderboard_hidden h where h.user_id = f.followed_id);

  if v_count >= p_limit then
    return 'limit';
  end if;

  insert into public.follows (follower_id, followed_id)
  values (p_actor, p_target)
  on conflict do nothing;

  return 'following';
end;
$$;

comment on function public._follow_user_as(uuid, uuid, int) is
  'Internal: follow p_target as p_actor with a cap of p_limit. Returns following, limit or not_allowed; raises when p_actor is null. Called by follow_user (auth.uid(), 50) and by follows-verification.sql; no client role can execute it.';


-- ===========================================================================
-- 4. follow_user(): follow a player, as the signed-in player.
-- ===========================================================================
create or replace function public.follow_user(p_target uuid)
returns text
language sql
security definer
set search_path = public
as $$
  select public._follow_user_as(auth.uid(), p_target, 50);
$$;

comment on function public.follow_user(uuid) is
  'Follow p_target as the signed-in player (cap 50). Returns following (also when already following), limit or not_allowed. Raises when nobody is logged in.';


-- ===========================================================================
-- 5. unfollow_user(): stop following a player.
-- ===========================================================================
create or replace function public.unfollow_user(p_target uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'You must be logged in to unfollow a player.';
  end if;

  delete from public.follows
  where follower_id = auth.uid()
    and followed_id = p_target;

  return 'not_following';
end;
$$;

comment on function public.unfollow_user(uuid) is
  'Stop following p_target as the signed-in player. Always returns not_following (idempotent). Raises when nobody is logged in.';


-- ===========================================================================
-- 6. get_my_follows(): the signed-in player's own list.
-- ===========================================================================
-- Never anyone else's list, never who follows you, never a hidden account.
-- Nobody logged in: no rows.
create or replace function public.get_my_follows()
returns table (user_id uuid, created_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select f.followed_id, f.created_at
  from public.follows f
  where f.follower_id = auth.uid()
    and not exists (select 1 from public.leaderboard_hidden h where h.user_id = f.followed_id)
  order by f.created_at, f.followed_id;
$$;

comment on function public.get_my_follows() is
  'The signed-in player''s own follows (user_id, created_at), oldest first, leaving out hidden accounts. No rows when nobody is logged in.';


-- ===========================================================================
-- 7. Function grants
-- ===========================================================================
-- The internals: nobody (service_role too: nothing needs them).
revoke all on function public._followable(uuid) from public;
revoke all on function public._followable(uuid) from anon;
revoke all on function public._followable(uuid) from authenticated;
revoke all on function public._followable(uuid) from service_role;
revoke all on function public._follow_user_as(uuid, uuid, int) from public;
revoke all on function public._follow_user_as(uuid, uuid, int) from anon;
revoke all on function public._follow_user_as(uuid, uuid, int) from authenticated;
revoke all on function public._follow_user_as(uuid, uuid, int) from service_role;

-- The three public functions: authenticated only.
revoke all on function public.follow_user(uuid) from public;
revoke all on function public.follow_user(uuid) from anon;
revoke all on function public.follow_user(uuid) from authenticated;
grant execute on function public.follow_user(uuid) to authenticated;

revoke all on function public.unfollow_user(uuid) from public;
revoke all on function public.unfollow_user(uuid) from anon;
revoke all on function public.unfollow_user(uuid) from authenticated;
grant execute on function public.unfollow_user(uuid) to authenticated;

revoke all on function public.get_my_follows() from public;
revoke all on function public.get_my_follows() from anon;
revoke all on function public.get_my_follows() from authenticated;
grant execute on function public.get_my_follows() to authenticated;

commit;
