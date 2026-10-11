-- Phase 2, Batch 2a: the counting flow, crib scoring, and winning at 121
-- Run this in the Supabase Dashboard -> SQL Editor.
-- Kept here for reference/history; this project has no Supabase CLI/migrations set up yet.
--
-- What this adds, ending at phase 'done' (the next hand is Batch 2b):
--   1. games columns for counting: count_step, revealed_by, crib_revealed,
--      winner_id; 'done' added to phase, 'won' added to ended_reason
--   2. RLS: a shown hand / shown crib becomes readable by players at the table
--   3. award_points -- capped at 121, and reaching 121 ends the game (WIN)
--   4. play_card -- ONE marked region (H): entering counting sets
--      current_player to the pone instead of null
--   5. show_hand, show_crib, confirm_count -- new, granted to authenticated
--
-- One games row is now one MATCH (decided at the Batch 2 design checkpoint).
-- Nothing in 2a depends on that yet -- next_hand, which makes it true, is 2b.
--
-- UNCHANGED, deliberately: discard_to_crib (his heels stays at cut time, and
-- score_hand still excludes it -- see confirm_count), deal_cards_for_game,
-- has_legal_play, score_hand, score_pegging, leave_table,
-- end_timed_out_sessions, start_game_with_deal.
--
-- GRANTS: after this file, exactly NINE functions are client-callable --
-- the previous six plus show_hand, show_crib and confirm_count.
-- docs/sql/phase2-batch2a-verification.sql query 3 is the check.
--
-- STATEMENT ORDER: schema first, so every function body below refers to
-- columns that already exist. (PL/pgSQL does not check that at create time --
-- it would only fail on first call.)


-- ---------------------------------------------------------------------------
-- 1. Counting state on games.
--
-- count_step -- WHICH count is up, in a 2-player hand:
--     0 = the pone's hand, 1 = the dealer's hand, 2 = the crib (dealer)
--   Stored, not derived, on the same principle as play_count: the client is a
--   renderer, and one locked function (confirm_count) owns every write.
--   It stays at 2 once phase reaches 'done'; 'done' itself means "all three
--   counted".
--
-- current_player keeps meaning "whose action it is" across phases:
--     discard            null
--     play               whose turn it is
--     counting, step 0   the pone
--     counting, step 1   the dealer
--     counting, step 2   the dealer (the crib)
--     done               null
--     ended ('won')      left exactly as it was when the winning points landed
--   confirm_count writes count_step, current_player and phase in ONE update,
--   so they cannot disagree.
--
-- revealed_by -- whose hands are shown. THE single source of truth for hand
--   visibility: the game_hands read policy below reads it, and because it
--   lives on games it already streams to every client over Realtime. The
--   secret tables (game_hands, game_cribs) stay OUT of the Realtime
--   publication; clients refetch them when this changes.
--
-- crib_revealed -- the same, for the crib.
--
-- winner_id -- set by award_points, in the same statement that ends the game.
-- ---------------------------------------------------------------------------
alter table public.games
  add column count_step int not null default 0
    check (count_step >= 0),
  add column revealed_by uuid[] not null default '{}',
  add column crib_revealed boolean not null default false,
  add column winner_id uuid references auth.users (id);


-- ---------------------------------------------------------------------------
-- 2. phase gains 'done'.
--
-- Slice 7 created the phase check inline ("add column ... check (...)"), so
-- Postgres named it. Same approach as Slice 3 used for ended_reason: find the
-- check constraint by its definition rather than guessing its name. Raises if
-- it finds more than one, rather than dropping the wrong thing.
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[];
begin
  select array_agg(con.conname)
  into v_names
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  join pg_namespace nsp on nsp.oid = rel.relnamespace
  where nsp.nspname = 'public'
    and rel.relname = 'games'
    and con.contype = 'c'
    and pg_get_constraintdef(con.oid) ilike '%phase%discard%';

  if coalesce(array_length(v_names, 1), 0) > 1 then
    raise exception 'Expected one phase check on games, found: %', v_names;
  end if;

  if v_names is not null then
    execute format('alter table public.games drop constraint %I', v_names[1]);
  end if;
end $$;

alter table public.games
  add constraint games_phase_check
  check (phase in ('discard', 'play', 'counting', 'done'));


-- ---------------------------------------------------------------------------
-- 3. ended_reason gains 'won'. Slice 3 named this one explicitly.
-- ---------------------------------------------------------------------------
alter table public.games
  drop constraint games_ended_reason_check;

alter table public.games
  add constraint games_ended_reason_check
  check (ended_reason is null or ended_reason in ('admin', 'timeout', 'player_left', 'won'));


-- ---------------------------------------------------------------------------
-- 4. Backfill: live games ALREADY sitting in 'counting'.
--
-- Batch 1's play_card left current_player null on entering counting, and
-- nothing has consumed 'counting' since -- so any test game still parked there
-- would have nobody allowed to confirm and be stuck for good. Give it the pone,
-- exactly as the changed play_card now does. count_step is already 0 from the
-- column default.
-- ---------------------------------------------------------------------------
update public.games g
set current_player = (
  select u
  from unnest(g.players) as u
  where u is distinct from g.dealer_id
  limit 1
)
where g.status = 'active'
  and g.phase = 'counting'
  and g.current_player is null;


-- ---------------------------------------------------------------------------
-- 5. Reading a shown hand.
--
-- Replaces Slice 9's "own hand only" policy -- the loosening that comment
-- anticipated, with the two conditions agreed at the design checkpoint:
--
--   * It is the hand's OWNER who must be in revealed_by (game_hands.user_id),
--     not the reader. Testing the reader would let anyone who has shown their
--     own hand read everyone else's.
--   * The reader must be a member of that game's table. A shown hand is shown
--     to the table, not to every logged-in user of the app.
--
-- Your own hand stays readable in every phase, exactly as before.
--
-- The subquery runs under the reader's own RLS on games and table_members.
-- Both have "any authenticated user can select" policies, so it sees what it
-- needs -- it cannot widen access, only narrow it.
-- ---------------------------------------------------------------------------
drop policy "Players can only read their own hand" on public.game_hands;

create policy "Players read their own hand, or a hand shown at their table"
  on public.game_hands for select
  using (
    user_id = auth.uid()
    or exists (
      select 1
      from public.games g
      join public.table_members tm
        on tm.table_id = g.table_id
       and tm.user_id = auth.uid()
      where g.id = game_hands.game_id
        and game_hands.user_id = any(g.revealed_by)
    )
  );


-- ---------------------------------------------------------------------------
-- 6. Reading a shown crib.
--
-- game_cribs has had ZERO policies since Slice 2 -- not even the dealer can
-- read it. Now: readable once crib_revealed is true, by members of that
-- game's table. Before the reveal, still nobody, dealer included.
--
-- The explicit table-level SELECT grant is belt-and-braces. Supabase's
-- default table privileges should already give authenticated SELECT on every
-- public table (game_hands has always been read this way), but game_cribs
-- has never been read by a client, so that has never been proven -- and a
-- policy does nothing without the privilege underneath it. Granting SELECT
-- exposes nothing by itself: RLS is on, so this policy is still the only way
-- any row comes back. No insert/update/delete grant or policy -- only the
-- security definer functions write here.
-- ---------------------------------------------------------------------------
grant select on public.game_cribs to authenticated;

create policy "Players at the table read a shown crib"
  on public.game_cribs for select
  using (
    exists (
      select 1
      from public.games g
      join public.table_members tm
        on tm.table_id = g.table_id
       and tm.user_id = auth.uid()
      where g.id = game_cribs.game_id
        and g.crib_revealed
    )
  );


-- ---------------------------------------------------------------------------
-- 7. award_points -- capped at 121, and reaching it WINS.
--
-- CHANGED FROM SLICE 6 in four marked regions, (W1)-(W4). Every other line of
-- the body is byte-for-byte Slice 6, comments included.
--
-- Why here: this is the one function every point passes through -- pegging,
-- his heels, and now hand and crib counts. Win detection anywhere else would
-- need repeating in each caller, and the one that got missed would let a
-- score sail past 121.
--
-- NO LOCK OF ITS OWN, deliberately. Every caller (play_card, discard_to_crib,
-- confirm_count) already holds the games row lock for the whole transaction,
-- so the status flip below runs inside it. The SQL Editor, the only other
-- caller, is testing.
--
-- What a win leaves behind:
--   status 'ended', ended_reason 'won', winner_id set. phase, count_step,
--   current_player and revealed_by are untouched, so the final state reads as
--   "the game stopped exactly here". Every function that acts on a game
--   (discard_to_crib, play_card, show_hand, show_crib, confirm_count) checks
--   status = 'active' first, so nothing can score after the win -- and the
--   live-game unique index frees up, so New Game becomes available.
--
--   The callers write on after the award returns in different ways, and all
--   are fine:
--   * play_card awards LAST -- nothing follows.
--   * discard_to_crib awards his heels BEFORE it writes phase = 'play', so a
--     his-heels win leaves an ended game with phase 'play'. Accepted at the
--     design checkpoint: the UI checks status before phase.
--   * confirm_count awards, then advances only "where status = 'active'".
--
-- THE CAP: the stored score never exceeds 121, so the tracker matches a
-- physical board, which has no hole past 121. last_points still records the
-- FULL award -- "+6 — fifteen + run of 3" is what was scored, even if only 3
-- of it was needed.
--
-- 0 points is still accepted (Slice 6), and confirm_count now relies on it:
-- a hand worth nothing flashes "+0 — hand: nothing".
-- ---------------------------------------------------------------------------
create or replace function public.award_points(
  p_table_id uuid,
  p_user_id uuid,
  p_points int,
  p_reason text
)
returns void
language plpgsql
set search_path = public
as $$
-- ===== (W1) CHANGED FROM SLICE 6 (start) =====
declare
  v_new_score int;
-- ===== (W1) CHANGED FROM SLICE 6 (end) =====
begin
  if p_points is null then
    raise exception 'award_points requires a point value (0 is allowed, null is not).';
  end if;

  update public.table_members
  -- ===== (W2) CHANGED FROM SLICE 6 (start) =====
  -- Capped at 121 -- see THE CAP note above the function.
  set score = least(score + p_points, 121),
  -- ===== (W2) CHANGED FROM SLICE 6 (end) =====
      last_points = p_points,
      last_reason = p_reason,
      last_awarded_at = now()
  where table_id = p_table_id
  -- ===== (W3) CHANGED FROM SLICE 6 (start) =====
    and user_id = p_user_id
  returning score into v_new_score;
  -- ===== (W3) CHANGED FROM SLICE 6 (end) =====

  -- Fails loudly rather than silently scoring nobody. A future scoring slice
  -- passing a stale user id is a bug worth surfacing immediately.
  if not found then
    raise exception 'No player % at table %.', p_user_id, p_table_id;
  end if;

  -- ===== (W4) CHANGED FROM SLICE 6 (start) =====
  -- THE WIN. First to 121 ends the game on the spot -- mid-pegging, mid-count,
  -- or on his heels -- because nothing after the winning point counts.
  --
  -- Filtered to status = 'active', so it is a no-op when called from the SQL
  -- Editor against a table with no live game, and it can never re-end (or
  -- re-attribute) a game that has already ended. 'cutting' never reaches
  -- here: no points are awarded during the cut for deal.
  if v_new_score >= 121 then
    update public.games
    set status = 'ended',
        ended_reason = 'won',
        winner_id = p_user_id
    where table_id = p_table_id
      and status = 'active';
  end if;
  -- ===== (W4) CHANGED FROM SLICE 6 (end) =====
end;
$$;

revoke all on function public.award_points(uuid, uuid, int, text) from public;


-- ---------------------------------------------------------------------------
-- 8. play_card -- who counts first.
--
-- CHANGED FROM BATCH 1 in ONE marked region, (H), a single assignment inside
-- Batch 1's region (F): entering counting sets current_player to the pone
-- rather than null, because the pone counts first and confirm_count's turn
-- guard reads current_player.
--
-- The pone is computed from the ROW BEING UPDATED (games.players,
-- games.dealer_id) rather than from v_game, because the lock's select list
-- does not include dealer_id -- and widening it would mean touching the lock
-- statement, which stays byte-for-byte unchanged. Same expression
-- discard_to_crib uses to pick who leads.
--
-- Every other line is byte-for-byte Batch 1, comments included -- including
-- the (A)-(G) banners, which still describe Batch 1's changes from Slice 7.
-- ALL SEVEN GUARDS AND THE ROW LOCK ARE UNCHANGED. "create or replace"
-- preserves the ACL, but the grant is restated anyway, as Batch 1 did.
-- ---------------------------------------------------------------------------
create or replace function public.play_card(p_game_id uuid, p_card text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_game record;
  v_hand text[];
  v_opponent uuid;
  v_value int;
  v_count int;
  v_seq int;
  v_segment int;
  v_leader uuid;
  -- ===== (A) CHANGED FROM SLICE 7 (start) =====
  v_segment_cards text[];
  v_peg jsonb;
  v_points int := 0;
  v_reason text := '';
  v_go_point boolean := false;
  v_phase_over boolean := false;
  -- ===== (A) CHANGED FROM SLICE 7 (end) =====
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to play a card.';
  end if;

  -- THE ROW LOCK. Both players could tap at the same instant. Without this,
  -- each would read the same play_count and the same max(seq), and one play
  -- would either overwrite the other or push the count past 31 unnoticed.
  select g.id, g.table_id, g.status, g.phase, g.players,
         g.current_player, g.play_count, g.play_segment
  into v_game
  from public.games g
  where g.id = p_game_id
  for update;

  if not found then
    raise exception 'Game not found.';
  end if;

  -- Guard 2: the game must still be live.
  if v_game.status <> 'active' then
    raise exception 'This game is no longer active.';
  end if;

  -- Guard 3: and actually in the play phase.
  if v_game.phase <> 'play' then
    raise exception 'This game is not in the play phase.';
  end if;

  -- Guard 4 (membership): the caller must be sitting at this table, and be one
  -- of the players this game was dealt to.
  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = v_game.table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not a member of this table.';
  end if;

  if v_game.players is null or not (v_caller = any(v_game.players)) then
    raise exception 'You are not a player in this game.';
  end if;

  -- Guard 5 (turn enforcement): playing out of turn must be impossible
  -- server-side, not merely hidden in the UI.
  if v_game.current_player is distinct from v_caller then
    raise exception 'It is not your turn.';
  end if;

  -- Guard 6 (anti-cheat, two parts). game_hands.cards is now IMMUTABLE for the
  -- rest of the hand -- it is the four cards that get counted later -- so
  -- "still holding it" is "in my hand AND not already in the play log". The
  -- discard phase was the last thing allowed to rewrite that array.
  select gh.cards
  into v_hand
  from public.game_hands gh
  where gh.game_id = p_game_id
    and gh.user_id = v_caller;

  if v_hand is null then
    raise exception 'You do not have a hand in this game.';
  end if;

  if not (p_card = any(v_hand)) then
    raise exception 'You can only play cards from your own hand.';
  end if;

  if exists (
    select 1
    from public.game_plays gp
    where gp.game_id = p_game_id
      and gp.user_id = v_caller
      and gp.kind = 'play'
      and gp.card = p_card
  ) then
    raise exception 'You have already played that card.';
  end if;

  -- Guard 7: the count may never pass 31.
  v_value := public.card_play_value(p_card);
  v_count := v_game.play_count + v_value;

  if v_count > 31 then
    raise exception 'That card would take the count to %, past the limit of 31.', v_count;
  end if;

  v_segment := v_game.play_segment;

  v_opponent := (
    select u from unnest(v_game.players) as u where u <> v_caller limit 1
  );

  -- Record the card. seq is safe to compute this way because every writer to
  -- game_plays for this game passes through the lock taken above.
  select coalesce(max(gp.seq), 0) + 1
  into v_seq
  from public.game_plays gp
  where gp.game_id = p_game_id;

  insert into public.game_plays (game_id, seq, segment, user_id, kind, card, count_after)
  values (p_game_id, v_seq, v_segment, v_caller, 'play', p_card, v_count);

  -- ===== (B) CHANGED FROM SLICE 7 (start) =====
  -- Score the segment, now that the new card is in it. Filtered to THIS
  -- segment, so cards from a previous run to 31 can never contribute.
  -- v_segment is still the pre-resolve value here, which is the segment the
  -- card was actually played into.
  select array_agg(gp.card order by gp.seq)
  into v_segment_cards
  from public.game_plays gp
  where gp.game_id = p_game_id
    and gp.segment = v_segment
    and gp.kind = 'play';

  v_peg := public.score_pegging(v_segment_cards);
  v_points := (v_peg ->> 'points')::int;
  v_reason := v_peg ->> 'reason';
  -- ===== (B) CHANGED FROM SLICE 7 (end) =====

  -- -------------------------------------------------------------------------
  -- Resolve what happens next, in this same transaction.
  --
  -- No loop is needed, because a reset drops the count to 0 and every card is
  -- playable onto 0 -- so after a reset the only question left is who still
  -- holds cards.
  -- -------------------------------------------------------------------------

  if v_count = 31 then
    -- Exactly 31 ends the segment immediately. Nobody declares a go.
    -- ===== (C) CHANGED FROM SLICE 7 (start) -- comment only, no logic =====
    -- Slice 7 said "(The 2 points for hitting 31 belong to the scoring
    -- slice.)" -- they are now counted in (B) above, and they REPLACE the
    -- last-card point rather than stacking with it.
    -- ===== (C) CHANGED FROM SLICE 7 (end) =====
    v_leader := v_opponent;
    v_count := 0;
    v_segment := v_segment + 1;

  elsif public.has_legal_play(p_game_id, v_opponent, v_count) then
    -- Normal case: the turn simply passes.
    v_leader := v_opponent;

  else
    -- The opponent cannot play. Record a go -- but ONLY if they still hold
    -- cards. A player who has run out has nothing to "go" on, and logging one
    -- would put a phantom event in the history at the end of every hand.
    if public.has_legal_play(p_game_id, v_opponent, 0) then
      v_seq := v_seq + 1;
      insert into public.game_plays (game_id, seq, segment, user_id, kind, card, count_after)
      values (p_game_id, v_seq, v_segment, v_opponent, 'go', null, v_count);
    end if;

    if public.has_legal_play(p_game_id, v_caller, v_count) then
      -- After a go, the same player keeps playing. This is exactly why
      -- current_player cannot be derived as "last player's opponent".
      v_leader := v_caller;
    else
      -- THE DEADLOCK CASE: neither player can legally play, but the count is
      -- under 31. Nothing in "alternate turns" resolves this -- without an
      -- automatic reset here, play would stall with no legal action available
      -- to anybody. The segment ends and the player who did NOT play the last
      -- card leads the next one.
      -- ===== (D) CHANGED FROM SLICE 7 (start) =====
      -- Slice 7's "(The 1 point for the go belongs to the scoring slice.)"
      -- note is removed -- it is awarded below.
      -- ===== (D) CHANGED FROM SLICE 7 (end, resumes after the 3 unchanged
      -- assignments) =====
      v_leader := v_opponent;
      v_count := 0;
      v_segment := v_segment + 1;

      -- ===== (D) CHANGED FROM SLICE 7 (start, continued) =====
      -- The go point goes to v_caller -- the player who played the LAST card
      -- of the segment. Note that is NOT the player whose go event was just
      -- logged above; in a deadlock exactly one go event exists and it belongs
      -- to the other player. Attribution is from control flow ("I just played
      -- and the segment is closing"), never from reading the go event's user.
      v_go_point := true;
      -- ===== (D) CHANGED FROM SLICE 7 (end) =====
    end if;
  end if;

  -- Whoever is meant to lead may be out of cards; fall through to the other.
  -- If neither holds anything, all eight cards are down and the hand is over.
  if not public.has_legal_play(p_game_id, v_leader, 0) then
    if public.has_legal_play(
         p_game_id,
         (select u from unnest(v_game.players) as u where u <> v_leader limit 1),
         0
       ) then
      v_leader := (select u from unnest(v_game.players) as u where u <> v_leader limit 1);
    else
      -- ===== (E) CHANGED FROM SLICE 7 (start) =====
      -- Slice 7 updated games to 'counting' and RETURNED right here. That
      -- early return is replaced by a flag, because award_points must fire on
      -- this path too -- a final card that closes the hand still scores, and
      -- this is also the moment "go" becomes "last card".
      v_phase_over := true;
      -- ===== (E) CHANGED FROM SLICE 7 (end) =====
    end if;
  end if;

  -- ===== (F) CHANGED FROM SLICE 7 (start) =====
  if v_phase_over then
    update public.games
    set phase = 'counting',
        -- ===== (H) CHANGED FROM BATCH 1 (start) =====
        -- The pone counts first. Batch 1 set null here; confirm_count's turn
        -- guard needs a real player.
        current_player = (
          select u
          from unnest(games.players) as u
          where u is distinct from games.dealer_id
          limit 1
        ),
        -- ===== (H) CHANGED FROM BATCH 1 (end) =====
        play_count = v_count,
        play_segment = v_segment
    where id = p_game_id;
  else
    update public.games
    set current_player = v_leader,
        play_count = v_count,
        play_segment = v_segment
    where id = p_game_id;
  end if;

  -- THE SINGLE AWARD, last of all -- because only here are both the go point
  -- and whether the hand just ended known.
  --
  -- One call, not one per scoring type: award_points overwrites
  -- last_points/last_reason, so several calls would leave the score tracker
  -- flashing only the final component. A 6-point play reading "+2 - pair"
  -- would be actively wrong.
  if v_go_point then
    v_points := v_points + 1;
    -- Same point, different word depending on whether anything follows.
    v_reason := case
      when v_reason = '' then (case when v_phase_over then 'last card' else 'go' end)
      else v_reason || ' + ' || (case when v_phase_over then 'last card' else 'go' end)
    end;
  end if;

  -- Skipped entirely at zero, so a scoreless play does not flash "+0".
  if v_points > 0 then
    perform public.award_points(v_game.table_id, v_caller, v_points, v_reason);
  end if;
  -- ===== (F) CHANGED FROM SLICE 7 (end) =====
end;
$$;

revoke all on function public.play_card(uuid, text) from public;
grant execute on function public.play_card(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 9. show_hand -- reveal your own hand to the table.
--
-- Allowed only in 'counting' and 'done' (design decision 7) -- NOT "any time"
-- as PRD Section 6 item 8 currently reads. Showing six cards during the
-- discard would let the table deduce your crib discards; that, and keeping
-- the play phase honest, is why it waits for counting.
--
-- One-way for the rest of the hand: there is no un-show. revealed_by is reset
-- by next_hand (Batch 2b), in the same transaction that deals the new cards,
-- so a new hand can never inherit an old reveal.
--
-- Idempotent. A second tap, or a tap after confirm_count already revealed the
-- hand, changes nothing.
--
-- The row lock is the same discipline as every other writer: revealed_by is
-- appended to, and confirm_count appends to the same array.
-- ---------------------------------------------------------------------------
create or replace function public.show_hand(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_game record;
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to show your hand.';
  end if;

  -- THE ROW LOCK.
  select g.id, g.table_id, g.status, g.phase, g.players, g.revealed_by
  into v_game
  from public.games g
  where g.id = p_game_id
  for update;

  if not found then
    raise exception 'Game not found.';
  end if;

  -- Guard 2: the game must still be live.
  if v_game.status <> 'active' then
    raise exception 'This game is no longer active.';
  end if;

  -- Guard 3 (membership): sitting at the table, and a player in this game.
  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = v_game.table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not a member of this table.';
  end if;

  if v_game.players is null or not (v_caller = any(v_game.players)) then
    raise exception 'You are not a player in this game.';
  end if;

  -- Guard 4: only once counting has begun.
  if v_game.phase not in ('counting', 'done') then
    raise exception 'Hands can only be shown once counting has begun.';
  end if;

  -- Idempotent.
  if v_caller = any(v_game.revealed_by) then
    return;
  end if;

  -- Guard 5: there must be a hand to show.
  if not exists (
    select 1
    from public.game_hands gh
    where gh.game_id = p_game_id
      and gh.user_id = v_caller
  ) then
    raise exception 'You do not have a hand in this game.';
  end if;

  -- array_append, not ||: the habit from Batch 1's 22P02 lesson, even though
  -- v_caller is typed and || would resolve correctly here.
  update public.games
  set revealed_by = array_append(revealed_by, v_caller)
  where id = p_game_id;
end;
$$;

revoke all on function public.show_hand(uuid) from public;
grant execute on function public.show_hand(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 10. show_crib -- the dealer turns the crib over.
--
-- Only the dealer, only in 'counting', and only at step 2 -- after both hands
-- have been confirmed. Until then the crib stays unreadable to everyone,
-- dealer included, exactly as it has been since Slice 2.
--
-- A separate step from confirm_count on purpose (PRD Section 6 item 8):
-- "Show Crib", count it out loud, then "Confirm Count". confirm_count refuses
-- step 2 until this has happened.
-- ---------------------------------------------------------------------------
create or replace function public.show_crib(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_game record;
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to show the crib.';
  end if;

  -- THE ROW LOCK.
  select g.id, g.table_id, g.status, g.phase, g.players, g.dealer_id,
         g.count_step, g.crib_revealed
  into v_game
  from public.games g
  where g.id = p_game_id
  for update;

  if not found then
    raise exception 'Game not found.';
  end if;

  -- Guard 2: the game must still be live.
  if v_game.status <> 'active' then
    raise exception 'This game is no longer active.';
  end if;

  -- Guard 3 (membership).
  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = v_game.table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not a member of this table.';
  end if;

  if v_game.players is null or not (v_caller = any(v_game.players)) then
    raise exception 'You are not a player in this game.';
  end if;

  -- Guard 4: the crib is the dealer's to show. Before the idempotency return,
  -- so a non-dealer gets a real error rather than a silent no-op.
  if v_game.dealer_id is distinct from v_caller then
    raise exception 'Only the dealer can show the crib.';
  end if;

  -- Idempotent.
  if v_game.crib_revealed then
    return;
  end if;

  -- Guard 5: only after both hands are counted.
  if v_game.phase <> 'counting' or v_game.count_step <> 2 then
    raise exception 'The crib is shown after both hands have been counted.';
  end if;

  update public.games
  set crib_revealed = true
  where id = p_game_id;
end;
$$;

revoke all on function public.show_crib(uuid) from public;
grant execute on function public.show_crib(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 11. confirm_count -- score one hand (or the crib) and award it.
--
-- Computes AND awards inside one locked transaction, exactly like play_card.
-- The client supplies only which step it believes it is confirming -- never a
-- card, never a point value. score_hand runs here, server-side, ungranted.
--
-- WHAT GETS SCORED, read straight from the source tables:
--   hand: game_hands.cards -- the four cards KEPT at the discard. That array
--         has been immutable since discard_to_crib's last write, so it is the
--         whole original hand. Deliberately NOT "hand minus game_plays",
--         which is what you still HOLD during play -- by counting time that
--         is nothing at all.
--   crib: game_cribs.cards.
--   both: games.starter_card as the fifth card.
--   Exactly 4 cards is enforced on both. In 2-player play that is guaranteed
--   by discard_to_crib (2 players x exactly 2 cards), but checking it here
--   means a broken invariant -- a Phase 3 change, a force-state script --
--   fails loudly instead of quietly scoring 5 or 6 cards.
--
-- HIS HEELS is not scored here. score_hand excludes it, and this function
-- calls nothing else. It was awarded once, at cut time, by discard_to_crib.
--
-- p_step -- the step the client is confirming (0, 1 or 2):
--   behind the current step (or phase 'done') -> return quietly. A double
--     tap, a retried request, or a second open tab; the count already landed.
--   ahead of the current step -> error. Only a client bug can produce it.
--
-- ORDER: reveal, award, then advance "where status = 'active'". If the award
-- reaches 121, award_points has already ended the game, the advance matches
-- no row, and the ended game is frozen at the step that won -- with the
-- winning hand shown. The dealer's hand and crib are never counted, which is
-- the rule: the pone counts first and can win first.
--
-- ONE award_points call, even for 0 -- award_points overwrites
-- last_points/last_reason, and a hand worth nothing should still say so.
-- ---------------------------------------------------------------------------
create or replace function public.confirm_count(p_game_id uuid, p_step int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_game record;
  v_current_step int;
  v_is_crib boolean;
  v_cards text[];
  v_score jsonb;
  v_points int;
  v_parts text[] := '{}';
  v_reason text;
begin
  -- Guard 1: must be a logged-in user at all.
  if v_caller is null then
    raise exception 'You must be logged in to confirm a count.';
  end if;

  -- Guard 2: a step that cannot exist in a 2-player hand. Whether it is
  -- behind or ahead is judged later, against the locked row.
  if p_step is null or p_step < 0 or p_step > 2 then
    raise exception 'Invalid count step %.', p_step;
  end if;

  -- THE ROW LOCK. Both players could act at once (the pone confirming while
  -- the dealer taps Show Crib, a double tap from either), and every check
  -- below reads state the update at the end depends on.
  select g.id, g.table_id, g.status, g.phase, g.players, g.dealer_id,
         g.starter_card, g.current_player, g.count_step, g.revealed_by,
         g.crib_revealed
  into v_game
  from public.games g
  where g.id = p_game_id
  for update;

  if not found then
    raise exception 'Game not found.';
  end if;

  -- Guard 3: the game must still be live.
  if v_game.status <> 'active' then
    raise exception 'This game is no longer active.';
  end if;

  -- Guard 4 (membership).
  if not exists (
    select 1
    from public.table_members tm
    where tm.table_id = v_game.table_id
      and tm.user_id = v_caller
  ) then
    raise exception 'You are not a member of this table.';
  end if;

  if v_game.players is null or not (v_caller = any(v_game.players)) then
    raise exception 'You are not a player in this game.';
  end if;

  -- Guard 5: phase and step. 'done' counts as step 3 -- past every step -- so
  -- a late duplicate of the crib confirm is quiet, not an error.
  if v_game.phase = 'counting' then
    v_current_step := v_game.count_step;
  elsif v_game.phase = 'done' then
    v_current_step := 3;
  else
    raise exception 'This game is not in the counting phase.';
  end if;

  if p_step < v_current_step then
    return;
  end if;

  if p_step > v_current_step then
    raise exception 'That count is not up yet.';
  end if;

  -- From here on: phase = 'counting' and p_step = count_step.

  -- Guard 6 (turn enforcement): only the player whose count is up.
  if v_game.current_player is distinct from v_caller then
    raise exception 'It is not your turn to count.';
  end if;

  -- Guard 7 (defensive): current_player must agree with the 2-player order --
  -- step 0 the pone, steps 1 and 2 the dealer. Cannot fail if only these
  -- functions write the row; it is here to catch a bad backfill or a
  -- hand-edited test row before it scores the wrong cards.
  if (v_game.count_step = 0 and v_caller = v_game.dealer_id)
     or (v_game.count_step > 0 and v_caller is distinct from v_game.dealer_id) then
    raise exception 'Counting state is inconsistent: step % does not belong to this player.',
      v_game.count_step;
  end if;

  -- Guard 8: a count needs the starter.
  if v_game.starter_card is null then
    raise exception 'There is no starter card to count with.';
  end if;

  v_is_crib := (v_game.count_step = 2);

  if v_is_crib then
    -- Guard 9: the crib must have been shown first (show_crib).
    if not v_game.crib_revealed then
      raise exception 'Show the crib before confirming its count.';
    end if;

    select c.cards
    into v_cards
    from public.game_cribs c
    where c.game_id = p_game_id;
  else
    select gh.cards
    into v_cards
    from public.game_hands gh
    where gh.game_id = p_game_id
      and gh.user_id = v_caller;
  end if;

  -- Guard 10: exactly four cards -- see WHAT GETS SCORED above.
  if coalesce(array_length(v_cards, 1), 0) <> 4 then
    raise exception '% has % cards; a count needs exactly 4.',
      case when v_is_crib then 'The crib' else 'Your hand' end,
      coalesce(array_length(v_cards, 1), 0);
  end if;

  -- AUTO-REVEAL (design decision 8). Counting a hand shows it -- you cannot
  -- confirm a hand the table has not seen. The crib is already shown by
  -- Guard 9. Done before the award so a WINNING hand is still on the table.
  if not v_is_crib and not (v_caller = any(v_game.revealed_by)) then
    update public.games
    set revealed_by = array_append(revealed_by, v_caller)
    where id = p_game_id;
  end if;

  -- SCORE. p_is_crib changes only the flush rule (crib: 5-card flush only).
  v_score := public.score_hand(v_cards, v_game.starter_card, v_is_crib);
  v_points := (v_score ->> 'points')::int;

  -- The reason, e.g. "hand: 15s 4 · pairs 2 · runs 3" -- the tracker shows it
  -- as "+9 — hand: 15s 4 · pairs 2 · runs 3". Zero components are omitted;
  -- a hand worth nothing reads "hand: nothing". array_append throughout
  -- (Batch 1's 22P02 lesson).
  if (v_score ->> 'fifteens')::int > 0 then
    v_parts := array_append(v_parts, ('15s ' || (v_score ->> 'fifteens'))::text);
  end if;
  if (v_score ->> 'pairs')::int > 0 then
    v_parts := array_append(v_parts, ('pairs ' || (v_score ->> 'pairs'))::text);
  end if;
  if (v_score ->> 'runs')::int > 0 then
    v_parts := array_append(v_parts, ('runs ' || (v_score ->> 'runs'))::text);
  end if;
  if (v_score ->> 'flush')::int > 0 then
    v_parts := array_append(v_parts, ('flush ' || (v_score ->> 'flush'))::text);
  end if;
  if (v_score ->> 'nobs')::int > 0 then
    v_parts := array_append(v_parts, ('nobs ' || (v_score ->> 'nobs'))::text);
  end if;

  v_reason := (case when v_is_crib then 'crib: ' else 'hand: ' end)
              || coalesce(nullif(array_to_string(v_parts, ' · '), ''), 'nothing');

  -- THE SINGLE AWARD. To the caller: the hand's owner at steps 0 and 1, and
  -- the dealer -- who owns the crib in 2-player -- at step 2 (Guard 7).
  perform public.award_points(v_game.table_id, v_caller, v_points, v_reason);

  -- ADVANCE, only if that award did not just end the game. count_step,
  -- current_player and phase move together, in one statement each way.
  if v_game.count_step < 2 then
    update public.games
    set count_step = v_game.count_step + 1,
        current_player = v_game.dealer_id
    where id = p_game_id
      and status = 'active';
  else
    update public.games
    set phase = 'done',
        current_player = null
    where id = p_game_id
      and status = 'active';
  end if;
end;
$$;

revoke all on function public.confirm_count(uuid, int) from public;
grant execute on function public.confirm_count(uuid, int) to authenticated;


-- ---------------------------------------------------------------------------
-- Checks: see docs/sql/phase2-batch2a-verification.sql -- schema, policies,
-- the nine-function grants check, and two rolled-back walk-throughs that
-- execute every function this file defines.
-- ---------------------------------------------------------------------------
