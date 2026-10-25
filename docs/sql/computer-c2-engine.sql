-- Computer opponent, C2: the engine
-- Run this in the Supabase Dashboard -> SQL Editor, AFTER
-- computer-c1-refactor.sql (and its verification). Kept here for
-- reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- WHAT IT IS FOR: a one-player mode. A computer opponent sits in seat 2 of
-- a normal 2-player table; the human's browser makes the computer's moves
-- through the "act as the computer" functions below, which only the one
-- human at a computer table can use. The computer accounts are three shared
-- accounts (easy, medium, hard), each able to sit at many tables at once
-- (nothing limits a player to one table). Every move still goes through the
-- unchanged game rules in the C1 "_as" functions, so the server decides
-- everything, exactly as for a human player.
--
-- WHAT IT ADDS (and computer-c2-rollback.sql removes exactly this):
--   1. TABLE public.computer_accounts (level, user_id): which auth users are
--      the computer. Row-level security on, NO policies, every privilege
--      revoked from PUBLIC, anon and authenticated: only the security definer
--      functions below read it (AGENTS.md, "New tables"). Not on profiles,
--      because players can write their own profile row.
--   2. COLUMN public.tables.computer_level ('easy' / 'medium' / 'hard', or
--      null). Informational only -- for the UI and for keeping computer
--      tables out of Open Tables, Admin and stats. NO guard trusts it: the
--      act-as guard uses computer_accounts membership.
--   3. Private helpers _computer_for_table(p_table_id) and
--      _computer_for_game(p_game_id): THE GUARD. They return the computer's
--      user id only when ALL of these hold, and raise a clear error
--      otherwise:
--        * auth.uid() is not null;
--        * the table is a 2-player table (max_players = 2);
--        * auth.uid() created the table (tables.created_by);
--        * auth.uid() is seated there;
--        * exactly one other player is seated, and that player is in
--          computer_accounts.
--      Not executable by PUBLIC, anon or authenticated.
--   4. Eight act-as wrappers, one per player action, each resolving the
--      computer through the guard and calling the matching C1 function as
--      the computer:
--        computer_start_game_with_deal(p_table_id)   (table id: the table guard)
--        computer_draw_cut_card(p_game_id)
--        computer_acknowledge_deal_cut(p_game_id)
--        computer_discard_to_crib(p_game_id, p_cards)
--        computer_play_card(p_game_id, p_card)
--        computer_show_crib(p_game_id)
--        computer_confirm_count(p_game_id, p_step)
--        computer_next_hand(p_game_id, p_hand_no)
--      Each has the same signature and return type as the player's own
--      function, so the client calls them the same way. A wrapper can only
--      ever act as the computer: the actor is the guard's answer, never an
--      argument.
--   5. computer_hand(p_game_id): the computer's hand, so the browser can
--      choose its moves. Same guard. Returns rows (user_id, cards) -- the
--      shape the client reads game_hands in today -- and only the
--      computer's row. Like game_hands, cards is the hand as dealt, then the
--      4 kept after the discard; cards already played stay in it (the client
--      subtracts game_plays, as for its own hand).
--   6. create_computer_table(p_level, p_code): makes a private, regular
--      (not Muggins), 2-player table with computer_level, created by the
--      caller, with the code the client chose; seats the caller and then the
--      computer, so the seat trigger gives them seats 1 and 2. A code
--      collision raises unique_violation (23505) exactly as the client's
--      direct insert does today, so the client's retry keeps working.
--      Returns (table_id, code).
--   7. leave_computer_table(p_table_id): the creator leaves their computer
--      table. Ends any live game the way leave_table does ('player_left'),
--      removes both seats, and closes the table (status 'ended'). leave_table
--      itself is NOT changed.
--
-- GRANTS: authenticated gets EXECUTE on the eleven public functions (4, 5,
-- 6, 7); anon and PUBLIC get nothing anywhere; the two helpers are
-- ungranted; computer_accounts has no privileges for any client role.
-- service_role: nothing needs it.
--
-- NOT HERE: the three computer accounts themselves. Create the users in the
-- dashboard, then run computer-accounts-setup.sql (after the C2
-- verification). Until then create_computer_table refuses every level
-- ("The easy computer is not set up yet.").
--
-- One transaction: if any statement fails, nothing is applied.

begin;

-- ===========================================================================
-- 1. public.computer_accounts
-- ===========================================================================
create table if not exists public.computer_accounts (
  level text primary key check (level in ('easy', 'medium', 'hard')),
  user_id uuid not null unique references auth.users (id)
);

comment on table public.computer_accounts is
  'The computer opponents: one shared auth user per level. Read only by security definer functions (the act-as guard, create_computer_table, leave_computer_table). No client role has any privilege on it, and RLS is on with no policies.';

-- Row-level security on, with NO policies: deny by default.
alter table public.computer_accounts enable row level security;

-- Grants, explicit (AGENTS.md "New tables", template appearance-settings.sql):
-- nothing for PUBLIC, anon or authenticated. Revoking everything also
-- removes any default grant the table picked up when it was created.
revoke all on table public.computer_accounts from public;
revoke all on table public.computer_accounts from anon;
revoke all on table public.computer_accounts from authenticated;

-- No policies: deliberately none.


-- ===========================================================================
-- 2. public.tables.computer_level
-- ===========================================================================
alter table public.tables
  add column if not exists computer_level text;

alter table public.tables drop constraint if exists tables_computer_level_check;
alter table public.tables
  add constraint tables_computer_level_check
  check (computer_level is null or computer_level in ('easy', 'medium', 'hard'));

comment on column public.tables.computer_level is
  'The computer opponent''s level at a computer table (set by create_computer_table), null at every other table. Informational -- for the UI and for keeping computer tables out of Open Tables, Admin and stats. Never trusted by a guard: the act-as guard checks computer_accounts.';


-- ===========================================================================
-- 3. The guard: _computer_for_table and _computer_for_game
-- ===========================================================================
create or replace function public._computer_for_table(p_table_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_table record;
  v_others uuid[];
  v_computer uuid;
begin
  if v_caller is null then
    raise exception 'You must be logged in to act for the computer.';
  end if;

  select t.id, t.created_by, t.max_players
  into v_table
  from public.tables t
  where t.id = p_table_id;

  if not found then
    raise exception 'Table not found.';
  end if;

  if v_table.max_players is distinct from 2 then
    raise exception 'Only a 2-player table can have a computer opponent.';
  end if;

  if v_table.created_by is distinct from v_caller then
    raise exception 'Only the player who created this table can act for its computer.';
  end if;

  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = p_table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not seated at this table.';
  end if;

  select array_agg(tm.user_id)
  into v_others
  from public.table_members tm
  where tm.table_id = p_table_id
    and tm.user_id <> v_caller;

  if coalesce(array_length(v_others, 1), 0) <> 1 then
    raise exception 'A computer table has exactly one other player, the computer.';
  end if;

  select ca.user_id
  into v_computer
  from public.computer_accounts ca
  where ca.user_id = v_others[1];

  if v_computer is null then
    raise exception 'The other player at this table is not a computer.';
  end if;

  return v_computer;
end;
$$;

revoke all on function public._computer_for_table(uuid) from public;
revoke all on function public._computer_for_table(uuid) from anon;
revoke all on function public._computer_for_table(uuid) from authenticated;


create or replace function public._computer_for_game(p_game_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_table_id uuid;
begin
  if auth.uid() is null then
    raise exception 'You must be logged in to act for the computer.';
  end if;

  select g.table_id
  into v_table_id
  from public.games g
  where g.id = p_game_id;

  if not found then
    raise exception 'Game not found.';
  end if;

  return public._computer_for_table(v_table_id);
end;
$$;

revoke all on function public._computer_for_game(uuid) from public;
revoke all on function public._computer_for_game(uuid) from anon;
revoke all on function public._computer_for_game(uuid) from authenticated;


-- ===========================================================================
-- 4. The act-as wrappers
-- ===========================================================================
create or replace function public.computer_start_game_with_deal(p_table_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.start_game_with_deal_as(public._computer_for_table(p_table_id), p_table_id);
end;
$$;

revoke all on function public.computer_start_game_with_deal(uuid) from public;
revoke all on function public.computer_start_game_with_deal(uuid) from anon;
grant execute on function public.computer_start_game_with_deal(uuid) to authenticated;


create or replace function public.computer_draw_cut_card(p_game_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.draw_cut_card_as(public._computer_for_game(p_game_id), p_game_id);
end;
$$;

revoke all on function public.computer_draw_cut_card(uuid) from public;
revoke all on function public.computer_draw_cut_card(uuid) from anon;
grant execute on function public.computer_draw_cut_card(uuid) to authenticated;


create or replace function public.computer_acknowledge_deal_cut(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.acknowledge_deal_cut_as(public._computer_for_game(p_game_id), p_game_id);
end;
$$;

revoke all on function public.computer_acknowledge_deal_cut(uuid) from public;
revoke all on function public.computer_acknowledge_deal_cut(uuid) from anon;
grant execute on function public.computer_acknowledge_deal_cut(uuid) to authenticated;


create or replace function public.computer_discard_to_crib(p_game_id uuid, p_cards text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.discard_to_crib_as(public._computer_for_game(p_game_id), p_game_id, p_cards);
end;
$$;

revoke all on function public.computer_discard_to_crib(uuid, text[]) from public;
revoke all on function public.computer_discard_to_crib(uuid, text[]) from anon;
grant execute on function public.computer_discard_to_crib(uuid, text[]) to authenticated;


create or replace function public.computer_play_card(p_game_id uuid, p_card text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.play_card_as(public._computer_for_game(p_game_id), p_game_id, p_card);
end;
$$;

revoke all on function public.computer_play_card(uuid, text) from public;
revoke all on function public.computer_play_card(uuid, text) from anon;
grant execute on function public.computer_play_card(uuid, text) to authenticated;


create or replace function public.computer_show_crib(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.show_crib_as(public._computer_for_game(p_game_id), p_game_id);
end;
$$;

revoke all on function public.computer_show_crib(uuid) from public;
revoke all on function public.computer_show_crib(uuid) from anon;
grant execute on function public.computer_show_crib(uuid) to authenticated;


create or replace function public.computer_confirm_count(p_game_id uuid, p_step int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.confirm_count_as(public._computer_for_game(p_game_id), p_game_id, p_step);
end;
$$;

revoke all on function public.computer_confirm_count(uuid, int) from public;
revoke all on function public.computer_confirm_count(uuid, int) from anon;
grant execute on function public.computer_confirm_count(uuid, int) to authenticated;


create or replace function public.computer_next_hand(p_game_id uuid, p_hand_no int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.next_hand_as(public._computer_for_game(p_game_id), p_game_id, p_hand_no);
end;
$$;

revoke all on function public.computer_next_hand(uuid, int) from public;
revoke all on function public.computer_next_hand(uuid, int) from anon;
grant execute on function public.computer_next_hand(uuid, int) to authenticated;


-- ===========================================================================
-- 5. computer_hand
-- ===========================================================================
create or replace function public.computer_hand(p_game_id uuid)
returns table (user_id uuid, cards text[])
language plpgsql
security definer
set search_path = public
as $$
declare
  v_computer uuid;
begin
  v_computer := public._computer_for_game(p_game_id);

  return query
  select gh.user_id, gh.cards
  from public.game_hands gh
  where gh.game_id = p_game_id
    and gh.user_id = v_computer;
end;
$$;

revoke all on function public.computer_hand(uuid) from public;
revoke all on function public.computer_hand(uuid) from anon;
grant execute on function public.computer_hand(uuid) to authenticated;


-- ===========================================================================
-- 6. create_computer_table
-- ===========================================================================
-- #variable_conflict use_column: the result columns are named table_id and
-- code, like the tables they describe, so inside the body a bare name means
-- the column; every reference below is qualified anyway.
create or replace function public.create_computer_table(p_level text, p_code text)
returns table (table_id uuid, code text)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_caller uuid := auth.uid();
  v_computer uuid;
  v_table_id uuid;
  v_code text;
begin
  if v_caller is null then
    raise exception 'You must be logged in to start a table.';
  end if;

  if p_level is null or p_level not in ('easy', 'medium', 'hard') then
    raise exception 'Unknown computer level "%": choose easy, medium or hard.', coalesce(p_level, '');
  end if;

  select ca.user_id
  into v_computer
  from public.computer_accounts ca
  where ca.level = p_level;

  if v_computer is null then
    raise exception 'The % computer is not set up yet.', p_level;
  end if;

  if v_computer = v_caller then
    raise exception 'A computer account cannot start a computer table.';
  end if;

  -- The code is the client's, as for a normal table: a collision raises
  -- unique_violation (23505) here, uncaught, exactly like the direct insert.
  insert into public.tables (code, created_by, is_public, is_muggins, max_players, computer_level)
  values (p_code, v_caller, false, false, 2, p_level)
  returning tables.id, tables.code into v_table_id, v_code;

  -- The human first, then the computer: the seat trigger
  -- (assign_table_seat) gives the lowest free seat, so seats 1 and 2.
  insert into public.table_members (table_id, user_id)
  values (v_table_id, v_caller);

  insert into public.table_members (table_id, user_id)
  values (v_table_id, v_computer);

  table_id := v_table_id;
  code := v_code;
  return next;
end;
$$;

revoke all on function public.create_computer_table(text, text) from public;
revoke all on function public.create_computer_table(text, text) from anon;
grant execute on function public.create_computer_table(text, text) to authenticated;


-- ===========================================================================
-- 7. leave_computer_table
-- ===========================================================================
-- Patterns from leave_table: the same refusal for a null caller, the live
-- game ended with status 'ended' / ended_reason 'player_left'. Added: the
-- tables row lock first (FOR NO KEY UPDATE, the lock start_game_with_deal
-- takes, so a leave and a start never interleave), both seats removed, and
-- the table closed. tables.ended_reason stays null: its check allows only
-- 'admin' and 'timeout', and C2 changes no existing constraint.
-- "A computer table" here: computer_level is set, the caller created it,
-- and nobody but computer accounts sits there besides the caller. The
-- caller need not still be seated, so a table can be cleaned up even after a
-- plain leave_table left the computer behind. A repeat call is quiet.
create or replace function public.leave_computer_table(p_table_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_table record;
begin
  if v_caller is null then
    raise exception 'You must be logged in to leave a table.';
  end if;

  select t.id, t.created_by, t.computer_level
  into v_table
  from public.tables t
  where t.id = p_table_id
  for no key update;

  if not found then
    raise exception 'Table not found.';
  end if;

  if v_table.computer_level is null or v_table.created_by is distinct from v_caller then
    raise exception 'Only the player who created this computer table can leave it this way.';
  end if;

  if exists (
    select 1
    from public.table_members tm
    where tm.table_id = p_table_id
      and tm.user_id <> v_caller
      and not exists (
        select 1
        from public.computer_accounts ca
        where ca.user_id = tm.user_id
      )
  ) then
    raise exception 'Another player is seated at this table.';
  end if;

  update public.games
  set status = 'ended', ended_reason = 'player_left'
  where table_id = p_table_id
    and status in ('cutting', 'active');

  delete from public.table_members
  where table_id = p_table_id;

  update public.tables
  set status = 'ended'
  where id = p_table_id
    and status = 'open';
end;
$$;

revoke all on function public.leave_computer_table(uuid) from public;
revoke all on function public.leave_computer_table(uuid) from anon;
grant execute on function public.leave_computer_table(uuid) to authenticated;

commit;
